import Foundation
import ImageIO
import MobileCoreServices
import UniformTypeIdentifiers
import UIKit

struct ImageCompressionEngine: CompressionEngine {
    private let store: TemporaryFileStoring
    private let fileManager: FileManager

    init(store: TemporaryFileStoring, fileManager: FileManager = .default) {
        self.store = store
        self.fileManager = fileManager
    }

    func estimate(input: CompressionInput, settings: CompressionSettings) async throws -> CompressionEstimate {
        guard let source = CGImageSourceCreateWithURL(input.workingURL as CFURL, nil) else {
            throw AppError.corruptFile
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let megapixels = Double(width * height) / 1_000_000

        var warnings: [CompressionWarning] = []
        var operations: [CompressionOperation] = [.reencode, .verifyOutput]
        let target = settings.targetSizeBytes

        if settings.stripMetadata {
            operations.insert(.stripMetadata, at: 0)
        }
        if settings.allowResolutionDownscale, megapixels > 12 || (target != nil && input.originalSizeBytes > (target ?? 0) * 3) {
            operations.append(.downsample)
        }
        if input.originalSizeBytes < 800_000 || (target != nil && input.originalSizeBytes <= (target ?? 0)) {
            warnings.append(.alreadyOptimized)
        }
        if let target, input.originalSizeBytes > target * 8 {
            warnings.append(.targetMayBeUnrealistic)
        }
        if outputType(for: input, settings: settings).conforms(to: .heic) {
            warnings.append(.heicCompatibility)
        }

        let estimated = target.map { min(input.originalSizeBytes, Int64(Double($0) * 0.96)) }
            ?? Int64(Double(input.originalSizeBytes) * estimatedRatio(for: settings.qualityMode))

        return CompressionEstimate(
            estimatedSizeBytes: estimated,
            estimatedReductionPercent: CompressionMath.estimatedReduction(original: input.originalSizeBytes, estimated: estimated),
            predictedQuality: predictedQuality(for: settings, warnings: warnings),
            warnings: warnings,
            plannedOperations: operations
        )
    }

    func compress(
        input: CompressionInput,
        settings: CompressionSettings,
        progress: @escaping @Sendable (CompressionProgress) -> Void
    ) async throws -> CompressionResult {
        let start = Date()
        progress(.preparing)
        try Task.checkCancellation()

        guard let source = CGImageSourceCreateWithURL(input.workingURL as CFURL, nil) else {
            throw AppError.corruptFile
        }
        progress(CompressionProgress(phase: .analyzing, fractionCompleted: 0.08, message: "Reading image"))

        let outputUTType = outputType(for: input, settings: settings)
        let outputExtension = extensionForOutput(type: outputUTType, settings: settings)
        let outputURL = try await store.makeOutputURL(originalFilename: input.originalFilename, extension: outputExtension)
        let target = settings.targetSizeBytes
        var warnings: [CompressionWarning] = []
        var operations: [CompressionOperation] = [.reencode, .verifyOutput]
        if settings.stripMetadata {
            operations.insert(.stripMetadata, at: 0)
        }
        if outputUTType.conforms(to: .heic) {
            warnings.append(.heicCompatibility)
        }

        let qualityRange = settings.qualityMode.compressionQualityRange
        let initialMaxDimension = settings.maxDimension ?? imageLongEdge(source: source)
        var candidateDimensions = [initialMaxDimension]
        if settings.allowResolutionDownscale {
            candidateDimensions += settings.qualityMode.imageLongEdgeSequence.filter { $0 < initialMaxDimension }
        }
        candidateDimensions = Array(Set(candidateDimensions)).sorted(by: >)

        var bestUnderTarget: EncodedCandidate?
        var bestCandidate: EncodedCandidate?

        for (dimensionIndex, maxDimension) in candidateDimensions.enumerated() {
            try Task.checkCancellation()
            if dimensionIndex > 0 {
                operations.append(.downsample)
                progress(CompressionProgress(
                    phase: .downsampling,
                    fractionCompleted: min(0.2 + Double(dimensionIndex) * 0.08, 0.55),
                    message: "Reducing image dimensions"
                ))
            }

            let candidate = try encodeWithBinarySearch(
                source: source,
                outputUTType: outputUTType,
                maxDimension: maxDimension,
                qualityRange: qualityRange,
                target: target,
                stripMetadata: settings.stripMetadata,
                progress: progress
            )
            bestCandidate = chooseBetter(lhs: bestCandidate, rhs: candidate, target: target)
            if let target, candidate.size <= target {
                bestUnderTarget = chooseHighestQuality(lhs: bestUnderTarget, rhs: candidate)
                if Double(target - candidate.size) / Double(target) < 0.08 || settings.qualityMode == .bestQuality {
                    break
                }
            } else if target == nil {
                bestUnderTarget = chooseHighestQuality(lhs: bestUnderTarget, rhs: candidate)
                break
            }
        }

        let finalCandidate = bestUnderTarget ?? bestCandidate
        guard let finalCandidate else {
            throw AppError.corruptFile
        }
        if let target, finalCandidate.size > target {
            warnings.append(.targetMayBeUnrealistic)
        }

        progress(CompressionProgress(phase: .writing, fractionCompleted: 0.88, message: "Writing compressed image"))
        try finalCandidate.data.write(to: outputURL, options: [.atomic])
        try Task.checkCancellation()
        let finalSize = fileManager.fileSize(at: outputURL)
        guard finalSize > 0 else {
            throw AppError.exportFailed
        }

        progress(CompressionProgress(phase: .completed, fractionCompleted: 1, message: "Image ready"))
        return CompressionResult(
            outputURL: outputURL,
            outputFilename: outputURL.lastPathComponent,
            originalSizeBytes: input.originalSizeBytes,
            compressedSizeBytes: finalSize,
            targetReached: CompressionMath.targetReached(size: finalSize, target: target),
            reductionPercent: CompressionMath.reductionPercent(original: input.originalSizeBytes, compressed: finalSize),
            warnings: warnings,
            operationsApplied: operations.unique(),
            durationSeconds: Date().timeIntervalSince(start)
        )
    }

    private func encodeWithBinarySearch(
        source: CGImageSource,
        outputUTType: UTType,
        maxDimension: Int,
        qualityRange: ClosedRange<Double>,
        target: Int64?,
        stripMetadata: Bool,
        progress: @escaping @Sendable (CompressionProgress) -> Void
    ) throws -> EncodedCandidate {
        var low = qualityRange.lowerBound
        var high = qualityRange.upperBound
        var bestUnderTarget: EncodedCandidate?
        var best: EncodedCandidate?
        let iterations = outputUTType.conforms(to: .png) ? 1 : 9

        for index in 0..<iterations {
            try Task.checkCancellation()
            let quality = outputUTType.conforms(to: .png) ? 1 : (low + high) / 2
            progress(CompressionProgress(
                phase: .encoding,
                fractionCompleted: 0.45 + Double(index) * 0.04,
                message: "Finding best quality"
            ))

            let data = try encode(
                source: source,
                outputUTType: outputUTType,
                maxDimension: maxDimension,
                quality: quality,
                stripMetadata: stripMetadata
            )
            let candidate = EncodedCandidate(data: data, quality: quality, maxDimension: maxDimension)
            best = chooseBetter(lhs: best, rhs: candidate, target: target)

            guard let target else {
                bestUnderTarget = candidate
                break
            }

            if candidate.size <= target {
                bestUnderTarget = chooseHighestQuality(lhs: bestUnderTarget, rhs: candidate)
                low = quality
                if Double(target - candidate.size) / Double(target) < 0.03 {
                    break
                }
            } else {
                high = quality
            }
        }

        if let bestUnderTarget {
            return bestUnderTarget
        }
        if let best {
            return best
        }
        let data = try encode(
            source: source,
            outputUTType: outputUTType,
            maxDimension: maxDimension,
            quality: qualityRange.lowerBound,
            stripMetadata: stripMetadata
        )
        return EncodedCandidate(data: data, quality: qualityRange.lowerBound, maxDimension: maxDimension)
    }

    private func encode(
        source: CGImageSource,
        outputUTType: UTType,
        maxDimension: Int,
        quality: Double,
        stripMetadata: Bool
    ) throws -> Data {
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            throw AppError.corruptFile
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, outputUTType.identifier as CFString, 1, nil) else {
            throw AppError.exportFailed
        }

        var properties: [CFString: Any] = [:]
        if !outputUTType.conforms(to: .png) {
            properties[kCGImageDestinationLossyCompressionQuality] = quality
        }
        if stripMetadata {
            properties[kCGImagePropertyOrientation] = 1
        } else if let sourceProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            properties.merge(sourceProperties) { _, new in new }
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw AppError.exportFailed
        }
        return data as Data
    }

    private func outputType(for input: CompressionInput, settings: CompressionSettings) -> UTType {
        switch settings.outputFormat {
        case .jpeg:
            return .jpeg
        case .heic:
            return canEncodeHEIC ? UTType.heic : .jpeg
        case .png:
            return .png
        case .pdf:
            return .pdf
        case .automatic, .original:
            if settings.preferHEICWhenAvailable, canEncodeHEIC {
                return UTType.heic
            }
            return .jpeg
        case .mp4, .mov, .zip:
            return .jpeg
        }
    }

    private var canEncodeHEIC: Bool {
        guard let identifiers = CGImageDestinationCopyTypeIdentifiers() as? [String] else {
            return false
        }
        return identifiers.contains(UTType.heic.identifier)
    }

    private func extensionForOutput(type: UTType, settings: CompressionSettings) -> String {
        if settings.outputFormat == .pdf {
            return "pdf"
        }
        if type.conforms(to: .heic) {
            return "heic"
        }
        if type.conforms(to: .png) {
            return "png"
        }
        return "jpg"
    }

    private func imageLongEdge(source: CGImageSource) -> Int {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 2048
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 2048
        return max(width, height)
    }

    private func estimatedRatio(for mode: QualityMode) -> Double {
        switch mode {
        case .bestQuality: 0.72
        case .balanced: 0.52
        case .smallestFile: 0.35
        }
    }

    private func predictedQuality(for settings: CompressionSettings, warnings: [CompressionWarning]) -> PredictedQuality {
        if warnings.contains(where: { $0.id == CompressionWarning.targetMayBeUnrealistic.id }) {
            return settings.qualityMode == .smallestFile ? .acceptable : .low
        }
        switch settings.qualityMode {
        case .bestQuality:
            return .excellent
        case .balanced:
            return .good
        case .smallestFile:
            return .acceptable
        }
    }

    private func chooseBetter(lhs: EncodedCandidate?, rhs: EncodedCandidate, target: Int64?) -> EncodedCandidate {
        guard let lhs else { return rhs }
        guard let target else {
            return rhs.quality > lhs.quality ? rhs : lhs
        }
        let lhsDistance = abs(lhs.size - target)
        let rhsDistance = abs(rhs.size - target)
        if rhs.size <= target, lhs.size > target { return rhs }
        if lhs.size <= target, rhs.size > target { return lhs }
        if rhsDistance == lhsDistance {
            return rhs.quality > lhs.quality ? rhs : lhs
        }
        return rhsDistance < lhsDistance ? rhs : lhs
    }

    private func chooseHighestQuality(lhs: EncodedCandidate?, rhs: EncodedCandidate) -> EncodedCandidate {
        guard let lhs else { return rhs }
        if rhs.quality == lhs.quality {
            return rhs.maxDimension > lhs.maxDimension ? rhs : lhs
        }
        return rhs.quality > lhs.quality ? rhs : lhs
    }
}

private struct EncodedCandidate {
    let data: Data
    let quality: Double
    let maxDimension: Int

    var size: Int64 { Int64(data.count) }
}
