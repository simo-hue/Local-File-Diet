import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import VideoToolbox

/// Re-encodes video at a bitrate computed from the user's target size.
///
/// The previous version of this engine asked `AVAssetExportSession` for a named
/// preset (`AVAssetExportPreset1280x720`, `…MediumQuality`, …). Presets have
/// fixed internal bitrates, so there was no relationship at all between "under
/// 5 MB" and what came out; the engine papered over that by exporting the whole
/// asset up to three times and keeping whichever attempt happened to be
/// smallest. That is the slowest and most battery-hungry thing this app does,
/// run three times, for a result that was still luck.
///
/// This version reads the asset with `AVAssetReader` and writes it with
/// `AVAssetWriter`, which lets it set `AVVideoAverageBitRateKey` directly.
/// One pass is normally enough; a second pass only happens when the encoder's
/// rate control overshot the target by more than `refinementTolerance`, and
/// there is never a third — see `maximumEncodePasses`.
struct VideoCompressionEngine: CompressionEngine {
    /// Hard bound on how many times the video is encoded, ever. Pass one aims
    /// at the computed bitrate; pass two corrects it using the measured
    /// overshoot. Anything beyond that is guessing with the user's battery.
    static let maximumEncodePasses = 2

    /// How far over the target pass one is allowed to land before pass two is
    /// worth its cost. 8% of a 10 MB target is 800 KB — enough to matter for a
    /// hard upload limit, not so tight that ordinary rate-control jitter
    /// triggers a full re-encode.
    static let refinementTolerance = 1.08

    /// The progress bar is split into two disjoint sub-ranges so it can only
    /// ever move forwards. The old engine reported `index / 3` from the outer
    /// loop while the inner export reported its own 0…1, so the bar visibly
    /// reset on every attempt.
    private static let firstPassRange: ClosedRange<Double> = 0...0.75
    private static let secondPassRange: ClosedRange<Double> = 0.75...0.95

    private let store: TemporaryFileStoring
    private let fileManager: FileManager

    init(store: TemporaryFileStoring, fileManager: FileManager = .default) {
        self.store = store
        self.fileManager = fileManager
    }

    // MARK: - Estimate

    func estimate(input: CompressionInput, settings: CompressionSettings) async throws -> CompressionEstimate {
        let asset = AVURLAsset(url: input.workingURL)
        guard let source = try? await SourceDescription(asset: asset) else {
            // The tracks cannot be inspected at all — protected content, or a
            // container AVFoundation will only hand to an export session. The
            // engine will fall back to a preset, so promise a preset's honesty
            // rather than inventing a resolution nobody can know yet.
            let estimated = settings.targetSizeBytes.map { min($0, input.originalSizeBytes) }
                ?? Int64(Double(input.originalSizeBytes) * Self.presetRatio(for: settings.qualityMode))
            return CompressionEstimate(
                estimatedSizeBytes: estimated,
                estimatedReductionPercent: CompressionMath.estimatedReduction(
                    original: input.originalSizeBytes,
                    estimated: estimated
                ),
                predictedQuality: Self.presetQuality(for: settings.qualityMode),
                warnings: [.videoPresetFallback],
                plannedOperations: [.videoExport, .verifyOutput]
            )
        }
        let plan = VideoEncodingPlanner.plan(
            source: source.facts,
            targetBytes: settings.targetSizeBytes,
            mode: settings.qualityMode,
            resolutionPreset: settings.videoResolutionPreset ?? .auto,
            preferModernFormat: settings.preferHEICWhenAvailable
        )

        // The plan is expressed in encoder (natural) coordinates; the user
        // thinks in what they see, so rotate it back before showing it.
        let display = Self.displaySize(width: plan.width, height: plan.height, transform: source.transform)

        var warnings: [CompressionWarning] = [
            .videoOutputPlan(width: display.width, height: display.height, codec: plan.codec.displayName),
            .videoPrecision
        ]
        if plan.codec == .hevc {
            warnings.append(.videoModernCodec)
        }
        if let target = settings.targetSizeBytes, plan.clampedToFloor || plan.predictedBytes > target {
            warnings.append(.targetMayBeUnrealistic)
        }

        // The estimate is now the PLANNED output, not `target * 1.05`: the
        // bitrate, the audio budget and the container overhead are all known
        // before a single frame is encoded. It is capped at the original
        // because `OutputGuard` hands the original back when a pass would make
        // the file bigger.
        let estimated = min(plan.predictedBytes, input.originalSizeBytes)

        return CompressionEstimate(
            estimatedSizeBytes: estimated,
            estimatedReductionPercent: CompressionMath.estimatedReduction(
                original: input.originalSizeBytes,
                estimated: estimated
            ),
            predictedQuality: VideoEncodingPlanner.predictedQuality(for: plan),
            warnings: warnings,
            plannedOperations: [.videoExport, .verifyOutput]
        )
    }

    // MARK: - Compress

    func compress(
        input: CompressionInput,
        settings: CompressionSettings,
        progress: @escaping @Sendable (CompressionProgress) -> Void
    ) async throws -> CompressionResult {
        let start = Date()
        progress(.preparing)
        try Task.checkCancellation()

        let asset = AVURLAsset(url: input.workingURL)
        let outputExtension = settings.outputFormat == .mov ? "mov" : "mp4"
        let fileType: AVFileType = outputExtension == "mov" ? .mov : .mp4
        let outputURL = try await store.makeOutputURL(
            originalFilename: input.originalFilename,
            extension: outputExtension
        )
        let target = settings.targetSizeBytes

        let workDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("Video-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        // Covers success, failure and cancellation: no partial encode survives.
        defer { try? fileManager.removeItem(at: workDirectory) }

        // A source that cannot even be inspected still deserves an attempt: it
        // goes down the same fallback road as a source that fails mid-encode.
        let source = try? await SourceDescription(asset: asset)
        var plan = source.map {
            VideoEncodingPlanner.plan(
                source: $0.facts,
                targetBytes: target,
                mode: settings.qualityMode,
                resolutionPreset: settings.videoResolutionPreset ?? .auto,
                preferModernFormat: settings.preferHEICWhenAvailable
            )
        } ?? Self.blindPlan(settings: settings)

        var warnings: [CompressionWarning] = [.videoPrecision]
        if plan.codec == .hevc, source != nil {
            warnings.append(.videoModernCodec)
        }

        let candidateURL: URL
        do {
            guard let source else { throw AppError.unsupportedFileType }
            candidateURL = try await encode(
                asset: asset,
                source: source,
                plan: &plan,
                target: target,
                resolutionPreset: settings.videoResolutionPreset ?? .auto,
                workDirectory: workDirectory,
                outputExtension: outputExtension,
                fileType: fileType,
                progress: progress
            )
            let display = Self.displaySize(width: plan.width, height: plan.height, transform: source.transform)
            warnings.append(
                .videoOutputPlan(width: display.width, height: display.height, codec: plan.codec.displayName)
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Protected content, an unsupported source codec, an encoder that
            // refuses these settings: fall back to ONE preset export. Not the
            // old three-attempt sweep — the point of this rewrite was to stop
            // exporting the same video over and over.
            try Task.checkCancellation()
            let fallbackURL = workDirectory.appendingPathComponent("fallback.\(outputExtension)")
            try await exportWithPreset(
                asset: asset,
                plan: plan,
                outputURL: fallbackURL,
                fileType: fileType,
                progress: progress
            )
            candidateURL = fallbackURL
            warnings.append(.videoPresetFallback)
        }

        if fileManager.fileExists(atPath: outputURL.path) {
            try? fileManager.removeItem(at: outputURL)
        }
        try fileManager.copyItem(at: candidateURL, to: outputURL)

        if let target, fileManager.fileSize(at: outputURL) > target {
            warnings.append(.targetMayBeUnrealistic)
        }

        return try await makeResult(
            input: input,
            outputURL: outputURL,
            target: target,
            warnings: warnings,
            start: start,
            progress: progress
        )
    }

    /// Runs pass one, and pass two when pass one overshot. Updates `plan` to
    /// whichever plan produced the file it returns, so the warnings describe
    /// what was actually written.
    private func encode(
        asset: AVURLAsset,
        source: SourceDescription,
        plan: inout VideoEncodingPlan,
        target: Int64?,
        resolutionPreset: VideoResolutionPreset,
        workDirectory: URL,
        outputExtension: String,
        fileType: AVFileType,
        progress: @escaping @Sendable (CompressionProgress) -> Void
    ) async throws -> URL {
        let firstURL = workDirectory.appendingPathComponent("pass-1.\(outputExtension)")
        try await transcode(
            asset: asset,
            source: source,
            plan: plan,
            outputURL: firstURL,
            fileType: fileType,
            range: Self.firstPassRange,
            progress: progress
        )
        let firstSize = fileManager.fileSize(at: firstURL)
        guard firstSize > 0 else { throw AppError.exportFailed }

        guard
            Self.maximumEncodePasses > 1,
            let target,
            let refined = VideoEncodingPlanner.refinedPlan(
                after: plan,
                source: source.facts,
                measuredBytes: firstSize,
                targetBytes: target,
                tolerance: Self.refinementTolerance,
                resolutionPreset: resolutionPreset
            )
        else {
            return firstURL
        }

        try Task.checkCancellation()
        let secondURL = workDirectory.appendingPathComponent("pass-2.\(outputExtension)")
        try await transcode(
            asset: asset,
            source: source,
            plan: refined,
            outputURL: secondURL,
            fileType: fileType,
            range: Self.secondPassRange,
            progress: progress
        )
        let secondSize = fileManager.fileSize(at: secondURL)

        // Pass two is only kept when it actually helped. It normally does — it
        // asks for less — but a smaller request that somehow produced a bigger
        // file is not worth shipping.
        guard secondSize > 0, secondSize < firstSize else {
            try? fileManager.removeItem(at: secondURL)
            return firstURL
        }
        plan = refined
        try? fileManager.removeItem(at: firstURL)
        return secondURL
    }

    // MARK: - Reader/writer pipeline

    private func transcode(
        asset: AVURLAsset,
        source: SourceDescription,
        plan: VideoEncodingPlan,
        outputURL: URL,
        fileType: AVFileType,
        range: ClosedRange<Double>,
        progress: @escaping @Sendable (CompressionProgress) -> Void
    ) async throws {
        if fileManager.fileExists(atPath: outputURL.path) {
            try? fileManager.removeItem(at: outputURL)
        }

        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: fileType)
        writer.shouldOptimizeForNetworkUse = true

        // 32BGRA is accepted by every hardware encoder on Apple platforms and
        // by every decoder that AVFoundation can read, which keeps this path
        // working for oddities like ProRes or 10-bit HEVC sources.
        let videoOutput = AVAssetReaderTrackOutput(
            track: source.videoTrack,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw AppError.exportFailed }
        reader.add(videoOutput)

        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: Self.videoOutputSettings(plan: plan, writer: writer)
        )
        videoInput.expectsMediaDataInRealTime = false
        // The classic hand-rolled-pipeline bug: decoded buffers are in natural
        // orientation, and the rotation lives only in the track's transform.
        // Drop it and every portrait phone video comes out sideways.
        videoInput.transform = source.transform
        guard writer.canAdd(videoInput) else { throw AppError.exportFailed }
        writer.add(videoInput)

        var audioOutput: AVAssetReaderTrackOutput?
        var audioInput: AVAssetWriterInput?
        if let audioTrack = source.audioTrack, plan.audioBitrate > 0 {
            let output = AVAssetReaderTrackOutput(
                track: audioTrack,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsNonInterleaved: false
                ]
            )
            output.alwaysCopiesSampleData = false
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: source.audioSampleRate,
                AVNumberOfChannelsKey: source.audioChannels,
                AVEncoderBitRateKey: Int(plan.audioBitrate.rounded())
            ]
            if reader.canAdd(output), writer.canApply(outputSettings: settings, forMediaType: .audio) {
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
                input.expectsMediaDataInRealTime = false
                if writer.canAdd(input) {
                    reader.add(output)
                    writer.add(input)
                    audioOutput = output
                    audioInput = input
                }
            }
        }

        // Only drop frames when the plan actually asked for a lower rate.
        let capsFrameRate = plan.frameRate > 0 && plan.frameRate < source.facts.frameRate - 0.5
        let pipeline = TranscodePipeline(
            reader: reader,
            writer: writer,
            videoOutput: videoOutput,
            videoInput: videoInput,
            audioOutput: audioOutput,
            audioInput: audioInput,
            durationSeconds: source.facts.durationSeconds,
            minimumFrameInterval: capsFrameRate ? 1 / plan.frameRate : 0
        ) { fraction in
            let mapped = range.lowerBound + (range.upperBound - range.lowerBound) * fraction
            progress(CompressionProgress(phase: .encoding, fractionCompleted: mapped, message: "Encoding video"))
        }

        progress(CompressionProgress(
            phase: .encoding,
            fractionCompleted: range.lowerBound,
            message: "Encoding video"
        ))
        do {
            try await pipeline.run()
        } catch {
            try? fileManager.removeItem(at: outputURL)
            throw error
        }
    }

    // MARK: - Fallback

    /// One preset export, chosen from the plan's resolution. Used only when the
    /// reader/writer path could not run at all.
    private func exportWithPreset(
        asset: AVURLAsset,
        plan: VideoEncodingPlan,
        outputURL: URL,
        fileType: AVFileType,
        progress: @escaping @Sendable (CompressionProgress) -> Void
    ) async throws {
        if fileManager.fileExists(atPath: outputURL.path) {
            try? fileManager.removeItem(at: outputURL)
        }
        let longEdge = max(plan.width, plan.height)
        let preferred: [String]
        switch longEdge {
        case 1920...: preferred = [AVAssetExportPreset1920x1080, AVAssetExportPreset1280x720]
        case 1280..<1920: preferred = [AVAssetExportPreset1280x720, AVAssetExportPreset960x540]
        case 960..<1280: preferred = [AVAssetExportPreset960x540, AVAssetExportPreset640x480]
        default: preferred = [AVAssetExportPreset640x480, AVAssetExportPresetLowQuality]
        }
        let candidates = (preferred + [AVAssetExportPresetMediumQuality, AVAssetExportPresetLowQuality]).unique()

        // `exportPresets(compatibleWith:)` has been deprecated since iOS 16, and
        // the app's deployment target is above that, so compatibility is asked
        // for one preset at a time with the current API instead.
        var chosen: String?
        for candidate in candidates {
            let compatible = await AVAssetExportSession.compatibility(
                ofExportPreset: candidate,
                with: asset,
                outputFileType: fileType
            )
            if compatible {
                chosen = candidate
                break
            }
        }
        guard let preset = chosen,
              let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw AppError.exportFailed
        }
        session.shouldOptimizeForNetworkUse = true
        let box = ExportSessionBox(session: session)

        progress(CompressionProgress(
            phase: .encoding,
            fractionCompleted: Self.firstPassRange.lowerBound,
            message: "Exporting video"
        ))

        try await withTaskCancellationHandler {
            if #available(iOS 18, macOS 15, *) {
                try await box.exportModern(to: outputURL, as: fileType) { fraction in
                    progress(CompressionProgress(
                        phase: .encoding,
                        fractionCompleted: Self.firstPassRange.lowerBound
                            + (Self.secondPassRange.upperBound - Self.firstPassRange.lowerBound) * fraction,
                        message: "Exporting video"
                    ))
                }
            } else {
                try await box.exportLegacy(to: outputURL, as: fileType) { fraction in
                    progress(CompressionProgress(
                        phase: .encoding,
                        fractionCompleted: Self.firstPassRange.lowerBound
                            + (Self.secondPassRange.upperBound - Self.firstPassRange.lowerBound) * fraction,
                        message: "Exporting video"
                    ))
                }
            }
        } onCancel: {
            box.cancel()
        }
    }

    // MARK: - Result

    /// Single funnel for every path out of `compress`, so the output guard runs
    /// exactly once per compression.
    private func makeResult(
        input: CompressionInput,
        outputURL: URL,
        target: Int64?,
        warnings: [CompressionWarning],
        start: Date,
        progress: @escaping @Sendable (CompressionProgress) -> Void
    ) async throws -> CompressionResult {
        progress(CompressionProgress(phase: .verifying, fractionCompleted: 0.96, message: "Checking the result"))
        let resolved = try await OutputGuard.resolve(
            candidateURL: outputURL,
            input: input,
            store: store,
            fileManager: fileManager
        )
        let finalSize = fileManager.fileSize(at: resolved.url)
        guard finalSize > 0 else {
            throw AppError.exportFailed
        }
        let finalWarnings = resolved.keptOriginal
            ? OutputGuard.warningsAfterKeepingOriginal(warnings, finalSize: finalSize, target: target)
            : warnings
        progress(CompressionProgress(phase: .completed, fractionCompleted: 1, message: "Video ready"))
        return CompressionResult(
            outputURL: resolved.url,
            outputFilename: resolved.url.lastPathComponent,
            originalSizeBytes: input.originalSizeBytes,
            compressedSizeBytes: finalSize,
            targetReached: CompressionMath.targetReached(size: finalSize, target: target),
            reductionPercent: CompressionMath.reductionPercent(original: input.originalSizeBytes, compressed: finalSize),
            warnings: finalWarnings,
            operationsApplied: [.videoExport, .verifyOutput],
            durationSeconds: Date().timeIntervalSince(start)
        )
    }

    // MARK: - Settings

    /// Some encoders reject a profile level, and invalid writer settings raise
    /// an Objective-C exception rather than throwing, so every dictionary is run
    /// past `canApply` before it reaches an `AVAssetWriterInput`.
    static func videoOutputSettings(plan: VideoEncodingPlan, writer: AVAssetWriter) -> [String: Any] {
        let keyFrameInterval = max(1, Int((plan.frameRate * 2).rounded()))
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: Int(plan.videoBitrate.rounded()),
            AVVideoExpectedSourceFrameRateKey: Int(max(1, plan.frameRate.rounded())),
            AVVideoMaxKeyFrameIntervalKey: keyFrameInterval,
            AVVideoMaxKeyFrameIntervalDurationKey: 2.0,
            AVVideoAllowFrameReorderingKey: true
        ]

        func settings(with compression: [String: Any]) -> [String: Any] {
            [
                AVVideoCodecKey: plan.codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
                AVVideoWidthKey: plan.width,
                AVVideoHeightKey: plan.height,
                // The plan preserves the source aspect ratio to within a pixel,
                // so "fill" crops nothing meaningful and avoids a hairline
                // letterbox from the even-number rounding.
                AVVideoScalingModeKey: AVVideoScalingModeResizeAspectFill,
                AVVideoCompressionPropertiesKey: compression
            ]
        }

        /// Optional keys are added one at a time and kept only if the writer
        /// accepts them. Invalid writer settings raise an Objective-C exception
        /// instead of throwing, so guessing is not an option.
        func add(_ key: String, _ value: Any) {
            var candidate = compression
            candidate[key] = value
            if writer.canApply(outputSettings: settings(with: candidate), forMediaType: .video) {
                compression = candidate
            }
        }

        add(
            AVVideoProfileLevelKey,
            plan.codec == .hevc
                ? kVTProfileLevel_HEVC_Main_AutoLevel as String
                : AVVideoProfileLevelH264HighAutoLevel
        )
        // A hard ceiling to go with the average. `AVVideoAverageBitRateKey` is
        // only a rate to aim at; the data-rate limit caps how many bytes may be
        // emitted inside a sliding window, which is what stops one detailed
        // passage from spending the whole file's budget.
        let windowSeconds = VideoEncodingPlanner.dataRateWindowSeconds
        let windowBytes = plan.videoBitrate / 8 * windowSeconds * VideoEncodingPlanner.dataRateLimitFactor
        add(
            kVTCompressionPropertyKey_DataRateLimits as String,
            [Int(windowBytes.rounded()), windowSeconds] as [Any]
        )

        let full = settings(with: compression)
        if writer.canApply(outputSettings: full, forMediaType: .video) {
            return full
        }
        return settings(with: [AVVideoAverageBitRateKey: Int(plan.videoBitrate.rounded())])
    }

    /// A stand-in plan for a source whose tracks could not be read. Nothing here
    /// reaches an encoder — it only picks which export preset the fallback asks
    /// for, so an explicit resolution choice is honoured and everything else
    /// defaults to 720p.
    static func blindPlan(settings: CompressionSettings) -> VideoEncodingPlan {
        let longEdge: Int
        switch settings.videoResolutionPreset ?? .auto {
        case .keepResolution, .p1080: longEdge = 1920
        case .auto, .p720: longEdge = 1280
        case .p540: longEdge = 960
        case .p480: longEdge = 640
        }
        return VideoEncodingPlan(
            width: longEdge,
            height: longEdge * 9 / 16,
            frameRate: 30,
            videoBitrate: VideoEncodingPlanner.minimumVideoBitrate,
            audioBitrate: VideoEncodingPlanner.audioBitrate(mode: settings.qualityMode, hasAudio: true),
            codec: .h264,
            predictedBytes: 0,
            clampedToFloor: false
        )
    }

    /// Rough ratios for the estimate when nothing about the source is knowable:
    /// what an Apple preset typically leaves behind.
    static func presetRatio(for mode: QualityMode) -> Double {
        switch mode {
        case .bestQuality: 0.80
        case .balanced: 0.55
        case .smallestFile: 0.32
        }
    }

    static func presetQuality(for mode: QualityMode) -> PredictedQuality {
        switch mode {
        case .bestQuality: .excellent
        case .balanced: .good
        case .smallestFile: .acceptable
        }
    }

    /// The rendered size the viewer sees, i.e. the encoder size with the track's
    /// rotation applied.
    static func displaySize(width: Int, height: Int, transform: CGAffineTransform) -> (width: Int, height: Int) {
        let rect = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)).applying(transform)
        return (max(2, Int(abs(rect.width).rounded())), max(2, Int(abs(rect.height).rounded())))
    }
}

// MARK: - Source description

/// Everything read off the asset once, up front, so nothing has to be loaded
/// again between the two encode passes.
private struct SourceDescription {
    let videoTrack: AVAssetTrack
    let audioTrack: AVAssetTrack?
    let transform: CGAffineTransform
    let audioSampleRate: Double
    let audioChannels: Int
    let facts: VideoSourceFacts

    init(asset: AVURLAsset) async throws {
        let duration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds > 0 else { throw AppError.corruptFile }

        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw AppError.unsupportedFileType
        }
        let (naturalSize, transform, nominalFrameRate, dataRate) = try await videoTrack.load(
            .naturalSize,
            .preferredTransform,
            .nominalFrameRate,
            .estimatedDataRate
        )
        let width = Int(abs(naturalSize.width).rounded())
        let height = Int(abs(naturalSize.height).rounded())
        guard width > 0, height > 0 else { throw AppError.corruptFile }

        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        var sampleRate: Double = 44_100
        var channels = 2
        if let audioTrack,
           let description = try await audioTrack.load(.formatDescriptions).first,
           let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
            if basic.mSampleRate > 0 { sampleRate = basic.mSampleRate }
            // AAC beyond stereo needs an explicit channel layout and buys the
            // user nothing on a file they are about to email, so cap at 2.
            channels = min(2, max(1, Int(basic.mChannelsPerFrame)))
        }

        self.videoTrack = videoTrack
        self.audioTrack = audioTrack
        self.transform = transform
        self.audioSampleRate = sampleRate
        self.audioChannels = channels
        self.facts = VideoSourceFacts(
            width: width,
            height: height,
            frameRate: Double(nominalFrameRate),
            durationSeconds: seconds,
            videoBitrate: Double(max(dataRate, 0)),
            hasAudio: audioTrack != nil
        )
    }
}

// MARK: - Pipeline

/// Owns one reader/writer pair for the length of one encode pass.
///
/// `AVAssetReader` and `AVAssetWriter` are not `Sendable`, and
/// `requestMediaDataWhenReady(on:using:)` hands work to a plain dispatch queue,
/// so the whole pair is confined to this box. Everything mutable behind it is
/// guarded by one lock, and the only things that cross out of it are a `Double`
/// progress fraction and the final `Result`.
private final class TranscodePipeline: @unchecked Sendable {
    private let reader: AVAssetReader
    private let writer: AVAssetWriter
    private let videoOutput: AVAssetReaderTrackOutput
    private let videoInput: AVAssetWriterInput
    private let audioOutput: AVAssetReaderTrackOutput?
    private let audioInput: AVAssetWriterInput?
    private let durationSeconds: Double
    /// Seconds between kept frames; zero when no frame-rate cap is in effect.
    private let minimumFrameInterval: Double
    private let report: @Sendable (Double) -> Void

    private let videoQueue = DispatchQueue(label: "com.localfilediet.video.encode.video")
    private let audioQueue = DispatchQueue(label: "com.localfilediet.video.encode.audio")

    private let lock = NSLock()
    private var pendingInputs: Int
    private var continuation: CheckedContinuation<Void, Error>?
    private var settled: Result<Void, Error>?
    private var didSettle = false
    private var isCancelled = false
    private var lastKeptSeconds = -Double.greatestFiniteMagnitude
    private var lastReportedFraction: Double = 0

    init(
        reader: AVAssetReader,
        writer: AVAssetWriter,
        videoOutput: AVAssetReaderTrackOutput,
        videoInput: AVAssetWriterInput,
        audioOutput: AVAssetReaderTrackOutput?,
        audioInput: AVAssetWriterInput?,
        durationSeconds: Double,
        minimumFrameInterval: Double,
        report: @escaping @Sendable (Double) -> Void
    ) {
        self.reader = reader
        self.writer = writer
        self.videoOutput = videoOutput
        self.videoInput = videoInput
        self.audioOutput = audioOutput
        self.audioInput = audioInput
        self.durationSeconds = durationSeconds
        self.minimumFrameInterval = minimumFrameInterval
        self.report = report
        self.pendingInputs = (audioInput == nil) ? 1 : 2
    }

    func run() async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                begin(continuation)
            }
        } onCancel: {
            cancel()
        }
    }

    // MARK: Lifecycle

    private func begin(_ continuation: CheckedContinuation<Void, Error>) {
        guard attach(continuation) else { return }
        guard writer.startWriting() else {
            settle(.failure(writer.error ?? AppError.exportFailed))
            return
        }
        guard reader.startReading() else {
            writer.cancelWriting()
            settle(.failure(reader.error ?? AppError.exportFailed))
            return
        }
        writer.startSession(atSourceTime: .zero)

        pump(isVideo: true)
        if audioInput != nil, audioOutput != nil {
            pump(isVideo: false)
        }
    }

    /// Cancellation arrives from the task, not from the media queues, so it is
    /// recorded as a flag that the sample loops check. `cancelReading` and
    /// `cancelWriting` make `copyNextSampleBuffer` return nil promptly so the
    /// loops wind down even if they are mid-append.
    private func cancel() {
        lock.lock()
        if isCancelled {
            lock.unlock()
            return
        }
        isCancelled = true
        lock.unlock()

        reader.cancelReading()
        if writer.status == .writing {
            writer.cancelWriting()
        }
        settle(.failure(CancellationError()))
    }

    private var cancellationRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCancelled
    }

    private func attach(_ continuation: CheckedContinuation<Void, Error>) -> Bool {
        lock.lock()
        if let settled {
            lock.unlock()
            continuation.resume(with: settled)
            return false
        }
        if didSettle {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    private func settle(_ outcome: Result<Void, Error>) {
        lock.lock()
        if didSettle {
            lock.unlock()
            return
        }
        didSettle = true
        let waiting = continuation
        continuation = nil
        if waiting == nil { settled = outcome }
        lock.unlock()
        waiting?.resume(with: outcome)
    }

    // MARK: Sample pumps

    /// The reader output and writer input are read off `self` inside the
    /// callback rather than captured: they are not `Sendable`, and this box is
    /// the thing that vouches for them.
    private func pump(isVideo: Bool) {
        let input = isVideo ? videoInput : audioInput
        let queue = isVideo ? videoQueue : audioQueue
        guard let input else { return }
        input.requestMediaDataWhenReady(on: queue) { [self] in
            guard let input = isVideo ? videoInput : audioInput,
                  let output = isVideo ? videoOutput : audioOutput else { return }
            while input.isReadyForMoreMediaData {
                if cancellationRequested {
                    input.markAsFinished()
                    settle(.failure(CancellationError()))
                    return
                }
                guard let sample = output.copyNextSampleBuffer() else {
                    input.markAsFinished()
                    switch reader.status {
                    case .failed:
                        settle(.failure(reader.error ?? AppError.exportFailed))
                    case .cancelled:
                        settle(.failure(CancellationError()))
                    default:
                        inputDidFinish()
                    }
                    return
                }
                if isVideo, shouldDrop(sample) {
                    continue
                }
                guard input.append(sample) else {
                    input.markAsFinished()
                    if writer.status == .cancelled {
                        settle(.failure(CancellationError()))
                    } else {
                        settle(.failure(writer.error ?? AppError.exportFailed))
                    }
                    return
                }
                if isVideo {
                    reportProgress(for: sample)
                }
            }
        }
    }

    private func inputDidFinish() {
        lock.lock()
        pendingInputs -= 1
        let allDone = pendingInputs <= 0
        lock.unlock()
        guard allDone else { return }

        writer.finishWriting { [self] in
            switch writer.status {
            case .completed:
                report(1)
                settle(.success(()))
            case .cancelled:
                settle(.failure(CancellationError()))
            default:
                settle(.failure(writer.error ?? AppError.exportFailed))
            }
        }
    }

    /// Frame-rate capping. Samples arrive in presentation order from a track
    /// output, so keeping the first frame past each interval is enough; the
    /// timestamps of the frames that survive are left untouched, which keeps the
    /// clip the same length.
    private func shouldDrop(_ sample: CMSampleBuffer) -> Bool {
        guard minimumFrameInterval > 0 else { return false }
        let seconds = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
        guard seconds.isFinite else { return false }
        lock.lock()
        defer { lock.unlock() }
        if seconds - lastKeptSeconds < minimumFrameInterval - 0.001 {
            return true
        }
        lastKeptSeconds = seconds
        return false
    }

    /// One monotonic 0…1, derived from the presentation timestamp of the video
    /// samples that have actually been appended.
    private func reportProgress(for sample: CMSampleBuffer) {
        guard durationSeconds > 0 else { return }
        let seconds = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
        guard seconds.isFinite else { return }
        let fraction = min(1, max(0, seconds / durationSeconds))
        lock.lock()
        guard fraction > lastReportedFraction + 0.002 else {
            lock.unlock()
            return
        }
        lastReportedFraction = fraction
        lock.unlock()
        report(fraction)
    }
}

// MARK: - Export session box (fallback path only)

private final class ExportSessionBox: @unchecked Sendable {
    private let session: AVAssetExportSession

    init(session: AVAssetExportSession) {
        self.session = session
    }

    @available(iOS 18, macOS 15, *)
    func exportModern(
        to outputURL: URL,
        as fileType: AVFileType,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [self] in
                try await runModernExport(to: outputURL, as: fileType)
            }
            group.addTask { [self] in
                await observeModernStates(progress)
            }
            try await group.waitForAll()
        }
    }

    @available(iOS 18, macOS 15, *)
    private func runModernExport(to outputURL: URL, as fileType: AVFileType) async throws {
        try await session.export(to: outputURL, as: fileType)
    }

    @available(iOS 18, macOS 15, *)
    private func observeModernStates(_ progress: @escaping @Sendable (Double) -> Void) async {
        for await state in session.states(updateInterval: 0.25) {
            if Task.isCancelled { return }
            if case .exporting(let sessionProgress) = state {
                progress(sessionProgress.fractionCompleted)
            }
        }
    }

    /// iOS 17 path. `status`, `progress` and `exportAsynchronously` are all
    /// deprecated as of iOS 18, which is why the modern path above exists; they
    /// are still the only option below it.
    func exportLegacy(
        to outputURL: URL,
        as fileType: AVFileType,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        session.outputURL = outputURL
        session.outputFileType = fileType
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let poller = Task { [self] in
                while isRunning {
                    progress(legacyProgress)
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            startLegacyExport { [self] in
                poller.cancel()
                continuation.resume(with: legacyOutcome)
            }
        }
    }

    private var isRunning: Bool {
        session.status == .waiting || session.status == .exporting
    }

    private var legacyProgress: Double {
        Double(session.progress)
    }

    private var legacyOutcome: Result<Void, Error> {
        switch session.status {
        case .completed: .success(())
        case .cancelled: .failure(CancellationError())
        case .failed: .failure(session.error ?? AppError.exportFailed)
        default: .failure(AppError.exportFailed)
        }
    }

    private func startLegacyExport(completion: @escaping @Sendable () -> Void) {
        session.exportAsynchronously(completionHandler: completion)
    }

    func cancel() {
        session.cancelExport()
    }
}
