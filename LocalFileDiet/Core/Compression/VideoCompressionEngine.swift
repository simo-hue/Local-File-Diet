import AVFoundation
import Foundation

struct VideoBitratePlanner {
    static func targetBitrateBitsPerSecond(targetSizeBytes: Int64, durationSeconds: Double, audioBitrate: Double = 128_000) -> Double {
        guard durationSeconds > 0 else { return 0 }
        return max(250_000, (Double(targetSizeBytes) * 8 / durationSeconds) - audioBitrate)
    }

    static func quality(for bitrate: Double) -> PredictedQuality {
        switch bitrate {
        case 4_000_000...:
            .excellent
        case 1_600_000..<4_000_000:
            .good
        case 750_000..<1_600_000:
            .acceptable
        default:
            .low
        }
    }
}

struct VideoCompressionEngine: CompressionEngine {
    private let store: TemporaryFileStoring
    private let fileManager: FileManager

    init(store: TemporaryFileStoring, fileManager: FileManager = .default) {
        self.store = store
        self.fileManager = fileManager
    }

    func estimate(input: CompressionInput, settings: CompressionSettings) async throws -> CompressionEstimate {
        let asset = AVURLAsset(url: input.workingURL)
        let duration = try await asset.load(.duration)
        let seconds = max(CMTimeGetSeconds(duration), 1)
        let targetBitrate = settings.targetSizeBytes.map {
            VideoBitratePlanner.targetBitrateBitsPerSecond(targetSizeBytes: $0, durationSeconds: seconds)
        }
        var warnings: [CompressionWarning] = [.videoPrecision]
        if let target = settings.targetSizeBytes, input.originalSizeBytes > target * 12 {
            warnings.append(.targetMayBeUnrealistic)
        }
        let estimated = settings.targetSizeBytes.map { Int64(Double($0) * 1.05) }
            ?? Int64(Double(input.originalSizeBytes) * estimatedRatio(for: settings.qualityMode))

        return CompressionEstimate(
            estimatedSizeBytes: estimated,
            estimatedReductionPercent: CompressionMath.estimatedReduction(original: input.originalSizeBytes, estimated: estimated),
            predictedQuality: targetBitrate.map(VideoBitratePlanner.quality(for:)) ?? predictedQuality(for: settings.qualityMode),
            warnings: warnings,
            plannedOperations: [.videoExport, .verifyOutput]
        )
    }

    func compress(
        input: CompressionInput,
        settings: CompressionSettings,
        progress: @escaping @Sendable (CompressionProgress) -> Void
    ) async throws -> CompressionResult {
        let start = Date()
        progress(.preparing)
        let asset = AVURLAsset(url: input.workingURL)
        let outputExtension = settings.outputFormat == .mov ? "mov" : "mp4"
        let outputURL = try await store.makeOutputURL(originalFilename: input.originalFilename, extension: outputExtension)
        let target = settings.targetSizeBytes
        let presets = presetsFor(settings: settings, asset: asset)
        var warnings: [CompressionWarning] = [.videoPrecision]
        var bestURL: URL?
        var bestSize = Int64.max
        let tempDirectory = fileManager.temporaryDirectory.appendingPathComponent("Video-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDirectory) }

        for (index, preset) in presets.prefix(3).enumerated() {
            try Task.checkCancellation()
            let attemptURL = tempDirectory.appendingPathComponent("attempt-\(index).\(outputExtension)")
            progress(CompressionProgress(phase: .encoding, fractionCompleted: Double(index) / 3, message: "Exporting video"))
            try await export(asset: asset, preset: preset, outputURL: attemptURL, outputExtension: outputExtension, progress: progress)
            let size = fileManager.fileSize(at: attemptURL)
            if size < bestSize {
                bestSize = size
                bestURL = attemptURL
            }
            if let target, size <= target {
                try fileManager.copyItem(at: attemptURL, to: outputURL)
                return try makeResult(
                    input: input,
                    outputURL: outputURL,
                    target: target,
                    warnings: warnings,
                    start: start,
                    progress: progress
                )
            }
        }

        guard let bestURL else {
            throw AppError.exportFailed
        }
        try fileManager.copyItem(at: bestURL, to: outputURL)
        if let target, fileManager.fileSize(at: outputURL) > target {
            warnings.append(.targetMayBeUnrealistic)
        }
        return try makeResult(
            input: input,
            outputURL: outputURL,
            target: target,
            warnings: warnings,
            start: start,
            progress: progress
        )
    }

    private func export(
        asset: AVURLAsset,
        preset: String,
        outputURL: URL,
        outputExtension: String,
        progress: @escaping @Sendable (CompressionProgress) -> Void
    ) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw AppError.exportFailed
        }
        session.outputURL = outputURL
        session.outputFileType = outputExtension == "mov" ? .mov : .mp4
        if session.supportedFileTypes.contains(.mp4), outputExtension == "mp4" {
            session.outputFileType = .mp4
        } else if session.supportedFileTypes.contains(.mov) {
            session.outputFileType = .mov
        }
        session.shouldOptimizeForNetworkUse = true
        let sessionBox = ExportSessionBox(session: session)

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let progressTask = Task {
                    while sessionBox.status == .waiting || sessionBox.status == .exporting {
                        progress(CompressionProgress(
                            phase: .encoding,
                            fractionCompleted: Double(sessionBox.progress),
                            message: "Exporting video"
                        ))
                        try? await Task.sleep(for: .milliseconds(250))
                    }
                }
                sessionBox.export {
                    progressTask.cancel()
                    switch sessionBox.status {
                    case .completed:
                        continuation.resume()
                    case .cancelled:
                        continuation.resume(throwing: CancellationError())
                    case .failed:
                        continuation.resume(throwing: sessionBox.error ?? AppError.exportFailed)
                    default:
                        continuation.resume(throwing: AppError.exportFailed)
                    }
                }
            }
        } onCancel: {
            sessionBox.cancel()
        }
    }

    private func presetsFor(settings: CompressionSettings, asset: AVAsset) -> [String] {
        let available = Set(AVAssetExportSession.exportPresets(compatibleWith: asset))
        let requested = settings.videoResolutionPreset ?? .auto
        let ordered: [String]
        switch requested {
        case .keepResolution:
            ordered = [AVAssetExportPresetHighestQuality, AVAssetExportPresetMediumQuality, AVAssetExportPresetLowQuality]
        case .p1080:
            ordered = [AVAssetExportPreset1920x1080, AVAssetExportPreset1280x720, AVAssetExportPresetMediumQuality]
        case .p720:
            ordered = [AVAssetExportPreset1280x720, AVAssetExportPreset960x540, AVAssetExportPresetMediumQuality]
        case .p540:
            ordered = [AVAssetExportPreset960x540, AVAssetExportPreset640x480, AVAssetExportPresetLowQuality]
        case .p480:
            ordered = [AVAssetExportPreset640x480, AVAssetExportPresetLowQuality]
        case .auto:
            switch settings.qualityMode {
            case .bestQuality:
                ordered = [AVAssetExportPresetHighestQuality, AVAssetExportPreset1920x1080, AVAssetExportPreset1280x720, AVAssetExportPresetMediumQuality]
            case .balanced:
                ordered = [AVAssetExportPreset1280x720, AVAssetExportPreset960x540, AVAssetExportPresetMediumQuality, AVAssetExportPresetLowQuality]
            case .smallestFile:
                ordered = [AVAssetExportPreset960x540, AVAssetExportPreset640x480, AVAssetExportPresetLowQuality]
            }
        }
        let filtered = ordered.filter { available.contains($0) }
        return filtered.isEmpty ? [AVAssetExportPresetMediumQuality, AVAssetExportPresetLowQuality].filter { available.contains($0) } : filtered
    }

    private func makeResult(
        input: CompressionInput,
        outputURL: URL,
        target: Int64?,
        warnings: [CompressionWarning],
        start: Date,
        progress: @escaping @Sendable (CompressionProgress) -> Void
    ) throws -> CompressionResult {
        let finalSize = fileManager.fileSize(at: outputURL)
        guard finalSize > 0 else {
            throw AppError.exportFailed
        }
        progress(CompressionProgress(phase: .completed, fractionCompleted: 1, message: "Video ready"))
        return CompressionResult(
            outputURL: outputURL,
            outputFilename: outputURL.lastPathComponent,
            originalSizeBytes: input.originalSizeBytes,
            compressedSizeBytes: finalSize,
            targetReached: CompressionMath.targetReached(size: finalSize, target: target),
            reductionPercent: CompressionMath.reductionPercent(original: input.originalSizeBytes, compressed: finalSize),
            warnings: warnings,
            operationsApplied: [.videoExport, .verifyOutput],
            durationSeconds: Date().timeIntervalSince(start)
        )
    }

    private func estimatedRatio(for mode: QualityMode) -> Double {
        switch mode {
        case .bestQuality: 0.80
        case .balanced: 0.55
        case .smallestFile: 0.32
        }
    }

    private func predictedQuality(for mode: QualityMode) -> PredictedQuality {
        switch mode {
        case .bestQuality: .excellent
        case .balanced: .good
        case .smallestFile: .acceptable
        }
    }
}

private final class ExportSessionBox: @unchecked Sendable {
    private let session: AVAssetExportSession

    init(session: AVAssetExportSession) {
        self.session = session
    }

    var status: AVAssetExportSession.Status {
        session.status
    }

    var progress: Float {
        session.progress
    }

    var error: Error? {
        session.error
    }

    func export(completion: @escaping @Sendable () -> Void) {
        session.exportAsynchronously(completionHandler: completion)
    }

    func cancel() {
        session.cancelExport()
    }
}
