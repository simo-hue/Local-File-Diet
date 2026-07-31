import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ImageCompressionEngine: CompressionEngine {
    private let store: TemporaryFileStoring
    private let fileManager: FileManager

    init(store: TemporaryFileStoring, fileManager: FileManager = .default) {
        self.store = store
        self.fileManager = fileManager
    }

    // MARK: - Estimate

    func estimate(input: CompressionInput, settings: CompressionSettings) async throws -> CompressionEstimate {
        guard let source = CGImageSourceCreateWithURL(input.workingURL as CFURL, nil) else {
            throw AppError.corruptFile
        }
        let sourceProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = sourceProperties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = sourceProperties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let megapixels = Double(width * height) / 1_000_000
        let sourceLongEdge = imageLongEdge(properties: sourceProperties)

        // The output decision (including what happens to an alpha channel) is made
        // exactly the same way here as in `compress`, so the Plan section tells the
        // truth before anything is written.
        let plan = outputPlan(
            for: settings,
            sourceHasAlpha: sourceHasAlpha(source: source, properties: sourceProperties)
        )

        var warnings: [CompressionWarning] = []
        var operations: [CompressionOperation] = [.reencode, .verifyOutput]
        let target = settings.targetSizeBytes

        if settings.stripMetadata {
            operations.insert(.stripMetadata, at: 0)
        }
        let plannedEdge = plannedLongEdge(settings: settings, sourceLongEdge: sourceLongEdge)
        let willDownscale = plannedEdge < sourceLongEdge
            || (settings.allowResolutionDownscale && (megapixels > 12 || (target != nil && input.originalSizeBytes > (target ?? 0) * 3)))
        if willDownscale {
            operations.append(.downsample)
        }
        if input.originalSizeBytes < 800_000 || (target != nil && input.originalSizeBytes <= (target ?? 0)) {
            warnings.append(.alreadyOptimized)
        }
        if plan.utType.conforms(to: .heic) {
            warnings.append(.heicCompatibility)
        }
        if plan.warnsAboutFlattening {
            warnings.append(.transparencyFlattened)
        }

        let projection = projectedSize(
            source: source,
            plan: plan,
            settings: settings,
            input: input,
            sourceWidth: width,
            sourceHeight: height
        )
        if projection.exceedsTarget {
            warnings.append(.targetMayBeUnrealistic)
        }

        return CompressionEstimate(
            estimatedSizeBytes: projection.estimatedSizeBytes,
            estimatedReductionPercent: CompressionMath.estimatedReduction(
                original: input.originalSizeBytes,
                estimated: projection.estimatedSizeBytes
            ),
            predictedQuality: predictedQuality(for: settings, warnings: warnings),
            warnings: warnings,
            plannedOperations: operations
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

        guard let source = CGImageSourceCreateWithURL(input.workingURL as CFURL, nil) else {
            throw AppError.corruptFile
        }
        progress(CompressionProgress(phase: .analyzing, fractionCompleted: 0.08, message: "Reading image"))

        let sourceProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let plan = outputPlan(
            for: settings,
            sourceHasAlpha: sourceHasAlpha(source: source, properties: sourceProperties)
        )
        let outputExtension = extensionForOutput(plan: plan)
        let outputURL = try await store.makeOutputURL(originalFilename: input.originalFilename, extension: outputExtension)
        let target = settings.targetSizeBytes
        var warnings: [CompressionWarning] = []
        var operations: [CompressionOperation] = [.reencode, .verifyOutput]
        if settings.stripMetadata {
            operations.insert(.stripMetadata, at: 0)
        }
        if plan.utType.conforms(to: .heic) {
            warnings.append(.heicCompatibility)
        }
        if plan.warnsAboutFlattening {
            warnings.append(.transparencyFlattened)
        }

        let sourceLongEdge = imageLongEdge(properties: sourceProperties)
        // Metadata travels only when the user asked to keep it.
        let metadataProperties = settings.stripMetadata ? nil : sourceProperties

        let finalCandidate: EncodedCandidate
        if let target {
            finalCandidate = try searchForTarget(
                source: source,
                plan: plan,
                settings: settings,
                target: target,
                sourceLongEdge: sourceLongEdge,
                metadataProperties: metadataProperties,
                progress: progress
            )
        } else {
            finalCandidate = try encodeAtNominalSettings(
                source: source,
                plan: plan,
                settings: settings,
                sourceLongEdge: sourceLongEdge,
                metadataProperties: metadataProperties,
                progress: progress
            )
        }

        if finalCandidate.maxDimension < sourceLongEdge {
            operations.append(.downsample)
        }
        if let target, finalCandidate.size > target {
            warnings.append(.targetMayBeUnrealistic)
        }

        progress(CompressionProgress(phase: .writing, fractionCompleted: 0.88, message: "Writing compressed image"))
        try finalCandidate.data.write(to: outputURL, options: [.atomic])
        try Task.checkCancellation()

        progress(CompressionProgress(phase: .verifying, fractionCompleted: 0.94, message: "Checking the result"))
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
        if resolved.keptOriginal {
            warnings = OutputGuard.warningsAfterKeepingOriginal(warnings, finalSize: finalSize, target: target)
        }

        progress(CompressionProgress(phase: .completed, fractionCompleted: 1, message: "Image ready"))
        return CompressionResult(
            outputURL: resolved.url,
            outputFilename: resolved.url.lastPathComponent,
            originalSizeBytes: input.originalSizeBytes,
            compressedSizeBytes: finalSize,
            targetReached: CompressionMath.targetReached(size: finalSize, target: target),
            reductionPercent: CompressionMath.reductionPercent(original: input.originalSizeBytes, compressed: finalSize),
            warnings: warnings,
            operationsApplied: operations.unique(),
            durationSeconds: Date().timeIntervalSince(start)
        )
    }

    // MARK: - Encoding strategies

    /// No target size: one deliberate encode at the quality mode's nominal
    /// quality and nominal long edge.
    ///
    /// The old code fell out of the binary search on its first iteration, which
    /// meant "no size limit" produced a single full-resolution encode at whatever
    /// the middle of the quality range happened to be — often barely smaller than
    /// the original.
    private func encodeAtNominalSettings(
        source: CGImageSource,
        plan: OutputPlan,
        settings: CompressionSettings,
        sourceLongEdge: Int,
        metadataProperties: [CFString: Any]?,
        progress: @escaping @Sendable (CompressionProgress) -> Void
    ) throws -> EncodedCandidate {
        let longEdge = plannedLongEdge(settings: settings, sourceLongEdge: sourceLongEdge)
        if longEdge < sourceLongEdge {
            progress(CompressionProgress(
                phase: .downsampling,
                fractionCompleted: 0.3,
                message: "Reducing image dimensions"
            ))
        }
        try Task.checkCancellation()
        let image = preparedImage(try resampledImage(source: source, maxDimension: longEdge), plan: plan)
        try Task.checkCancellation()

        progress(CompressionProgress(phase: .encoding, fractionCompleted: 0.55, message: "Encoding image"))
        let quality = plan.supportsQuality ? nominalEncode(for: settings.qualityMode).quality : 1
        let data = try encodeImageData(
            image: image,
            plan: plan,
            quality: quality,
            metadataProperties: metadataProperties
        )
        return EncodedCandidate(data: data, quality: quality, maxDimension: longEdge)
    }

    /// Target size: walk candidate dimensions from large to small, and at each
    /// dimension binary-search the quality.
    ///
    /// The image is decoded and resampled ONCE per dimension; the quality trials
    /// re-encode that same `CGImage`, so a nine-step search costs one decode
    /// rather than nine.
    private func searchForTarget(
        source: CGImageSource,
        plan: OutputPlan,
        settings: CompressionSettings,
        target: Int64,
        sourceLongEdge: Int,
        metadataProperties: [CFString: Any]?,
        progress: @escaping @Sendable (CompressionProgress) -> Void
    ) throws -> EncodedCandidate {
        let qualityRange = settings.qualityMode.compressionQualityRange
        let ceiling = min(settings.maxDimension ?? sourceLongEdge, sourceLongEdge)
        var candidateDimensions = [ceiling]
        if settings.allowResolutionDownscale {
            candidateDimensions += settings.qualityMode.imageLongEdgeSequence.filter { $0 < ceiling }
        }
        candidateDimensions = candidateDimensions.unique().sorted(by: >)

        var bestUnderTarget: EncodedCandidate?
        var bestCandidate: EncodedCandidate?

        for (dimensionIndex, maxDimension) in candidateDimensions.enumerated() {
            try Task.checkCancellation()
            if dimensionIndex > 0 {
                progress(CompressionProgress(
                    phase: .downsampling,
                    fractionCompleted: min(0.2 + Double(dimensionIndex) * 0.08, 0.55),
                    message: "Reducing image dimensions"
                ))
            }

            let image = preparedImage(try resampledImage(source: source, maxDimension: maxDimension), plan: plan)
            let candidate = try sweepQuality(
                image: image,
                plan: plan,
                maxDimension: maxDimension,
                qualityRange: qualityRange,
                target: target,
                metadataProperties: metadataProperties,
                progress: progress
            )
            bestCandidate = chooseBetter(lhs: bestCandidate, rhs: candidate, target: target)
            if candidate.size <= target {
                bestUnderTarget = chooseHighestQuality(lhs: bestUnderTarget, rhs: candidate)
                // Close enough to the target, or a mode that should not trade away
                // resolution for a few extra kilobytes.
                if Double(target - candidate.size) / Double(target) < 0.08 || settings.qualityMode == .bestQuality {
                    break
                }
            }
        }

        if let bestUnderTarget {
            return bestUnderTarget
        }
        guard let bestCandidate else {
            throw AppError.exportFailed
        }
        return bestCandidate
    }

    /// Binary search over encoder quality for one already-resampled image.
    private func sweepQuality(
        image: CGImage,
        plan: OutputPlan,
        maxDimension: Int,
        qualityRange: ClosedRange<Double>,
        target: Int64,
        metadataProperties: [CFString: Any]?,
        progress: @escaping @Sendable (CompressionProgress) -> Void
    ) throws -> EncodedCandidate {
        // PNG has no quality knob, so there is exactly one encode to make.
        let iterations = plan.supportsQuality ? 9 : 1
        var low = qualityRange.lowerBound
        var high = qualityRange.upperBound
        var bestUnderTarget: EncodedCandidate?
        var best: EncodedCandidate?

        for index in 0..<iterations {
            try Task.checkCancellation()
            let quality = plan.supportsQuality ? (low + high) / 2 : 1
            progress(CompressionProgress(
                phase: .encoding,
                fractionCompleted: 0.45 + Double(index) * 0.04,
                message: "Finding best quality"
            ))

            let data = try encodeImageData(
                image: image,
                plan: plan,
                quality: quality,
                metadataProperties: metadataProperties
            )
            let candidate = EncodedCandidate(data: data, quality: quality, maxDimension: maxDimension)
            best = chooseBetter(lhs: best, rhs: candidate, target: target)

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
        guard let best else {
            throw AppError.exportFailed
        }
        return best
    }

    // MARK: - Encoding

    private func encodeImageData(
        image: CGImage,
        plan: OutputPlan,
        quality: Double,
        metadataProperties: [CFString: Any]?
    ) throws -> Data {
        if plan.isPDF {
            return try encodePDFPage(image: image, jpegQuality: quality)
        }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, plan.utType.identifier as CFString, 1, nil) else {
            throw AppError.exportFailed
        }

        var properties: [CFString: Any] = [:]
        if plan.supportsQuality {
            properties[kCGImageDestinationLossyCompressionQuality] = quality
        }
        // The resample baked the source orientation into the pixels, so the file
        // must always declare "up". Writing the original value would rotate the
        // image a second time when it is viewed.
        properties[kCGImagePropertyOrientation] = 1
        if let metadataProperties {
            for (key, value) in preservedMetadata(from: metadataProperties, width: image.width, height: image.height) {
                properties[key] = value
            }
        }

        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw AppError.exportFailed
        }
        return data as Data
    }

    /// Photo to PDF: one page, image embedded as JPEG so the quality search still
    /// has a knob that moves the final byte count.
    private func encodePDFPage(image: CGImage, jpegQuality: Double) throws -> Data {
        let pageSize = pdfPageSize(for: image)
        // A PDF page is opaque, so the image reaching this point is already
        // flattened; encoding it as JPEG is what makes the page size controllable.
        let pageImage = try PDFImageEncoder.jpegBackedImage(image, quality: jpegQuality)
        let bounds = CGRect(origin: .zero, size: pageSize)

        let writer = try PDFPageWriter(documentInfo: [kCGPDFContextCreator: "Local File Diet"])
        writer.writePage(mediaBox: bounds) { context in
            context.draw(pageImage, in: bounds)
        }
        guard let data = writer.finish(), !data.isEmpty else {
            throw AppError.exportFailed
        }
        return data
    }

    /// A `CGImage` carries no dpi, so one pixel becomes one point (72 dpi) and the
    /// page opens at natural size. Very large photos are scaled down so the page
    /// stays a sane document size rather than a wall-sized poster.
    private func pdfPageSize(for image: CGImage) -> CGSize {
        var width = CGFloat(max(image.width, 1))
        var height = CGFloat(max(image.height, 1))
        let maxPageLongEdge: CGFloat = 2000
        let longEdge = max(width, height)
        if longEdge > maxPageLongEdge {
            let scale = maxPageLongEdge / longEdge
            width *= scale
            height *= scale
        }
        return CGSize(width: max(width.rounded(), 1), height: max(height.rounded(), 1))
    }

    /// Only the descriptive metadata dictionaries survive a re-encode.
    ///
    /// Merging the whole source property dictionary would carry the ORIGINAL pixel
    /// dimensions, the embedded thumbnail and the original orientation into a file
    /// that has just been resampled and transform-baked.
    private func preservedMetadata(from source: [CFString: Any], width: Int, height: Int) -> [CFString: Any] {
        var preserved: [CFString: Any] = [:]
        if var exif = source[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            // These two describe the pixels, and the pixels just changed.
            exif[kCGImagePropertyExifPixelXDimension] = width
            exif[kCGImagePropertyExifPixelYDimension] = height
            preserved[kCGImagePropertyExifDictionary] = exif
        }
        if var tiff = source[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            // The rotation is already in the pixels.
            tiff[kCGImagePropertyTIFFOrientation] = 1
            preserved[kCGImagePropertyTIFFDictionary] = tiff
        }
        if let gps = source[kCGImagePropertyGPSDictionary] as? [CFString: Any] {
            preserved[kCGImagePropertyGPSDictionary] = gps
        }
        if let iptc = source[kCGImagePropertyIPTCDictionary] as? [CFString: Any] {
            preserved[kCGImagePropertyIPTCDictionary] = iptc
        }
        return preserved
    }

    // MARK: - Pixels

    private func resampledImage(source: CGImageSource, maxDimension: Int) throws -> CGImage {
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(maxDimension, 1)
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            throw AppError.corruptFile
        }
        return image
    }

    private func preparedImage(_ image: CGImage, plan: OutputPlan) -> CGImage {
        guard plan.flattensTransparency else { return image }
        return flattenedOntoWhite(image)
    }

    /// Composites onto opaque white. Handing an image with alpha straight to a
    /// JPEG encoder turns every transparent pixel BLACK, which looks like the file
    /// was destroyed.
    private func flattenedOntoWhite(_ image: CGImage) -> CGImage {
        let width = max(image.width, 1)
        let height = max(image.height, 1)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            return image
        }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(rect)
        context.draw(image, in: rect)
        return context.makeImage() ?? image
    }

    private func sourceHasAlpha(source: CGImageSource, properties: [CFString: Any]?) -> Bool {
        if let flag = properties?[kCGImagePropertyHasAlpha] as? Bool, flag {
            return true
        }
        if let number = properties?[kCGImagePropertyHasAlpha] as? NSNumber, number.boolValue {
            return true
        }
        // The property is missing from plenty of real files, so ask the image
        // itself. `shouldCache: false` keeps this from holding a full bitmap.
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary) else {
            return false
        }
        switch image.alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast:
            return true
        default:
            return false
        }
    }

    // MARK: - Output planning

    private struct OutputPlan {
        let utType: UTType
        let isPDF: Bool
        /// Whether the encoder reacts to a quality value at all.
        let supportsQuality: Bool
        /// Whether transparent pixels must be composited onto white first.
        let flattensTransparency: Bool
        /// Whether that flattening happened against the user's wishes.
        let warnsAboutFlattening: Bool
    }

    private func outputPlan(for settings: CompressionSettings, sourceHasAlpha: Bool) -> OutputPlan {
        let type = outputType(for: settings, sourceHasAlpha: sourceHasAlpha)
        let isPDF = settings.outputFormat == .pdf
        // PDF pages are opaque, so a PDF can never carry an alpha channel either.
        let carriesAlpha = !isPDF && (type.conforms(to: .png) || type.conforms(to: .heic))
        let flattens = sourceHasAlpha && (!carriesAlpha || !settings.preserveTransparency)
        return OutputPlan(
            utType: type,
            isPDF: isPDF,
            supportsQuality: isPDF || !type.conforms(to: .png),
            flattensTransparency: flattens,
            // Only worth a warning when the user asked to keep transparency and the
            // format cannot. Turning the toggle off is an explicit choice.
            warnsAboutFlattening: flattens && settings.preserveTransparency
        )
    }

    private func outputType(for settings: CompressionSettings, sourceHasAlpha: Bool) -> UTType {
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
            // No explicit format was demanded, so an alpha channel must not be
            // silently destroyed. HEIC is both lossy and alpha-capable, so it can
            // still chase a size target; PNG is the fallback.
            if sourceHasAlpha, settings.preserveTransparency {
                return canEncodeHEIC ? UTType.heic : .png
            }
            if settings.preferHEICWhenAvailable, canEncodeHEIC {
                return UTType.heic
            }
            return .jpeg
        case .mp4, .mov, .zip:
            // Unreachable for images; a harmless fallback.
            return .jpeg
        }
    }

    private var canEncodeHEIC: Bool {
        guard let identifiers = CGImageDestinationCopyTypeIdentifiers() as? [String] else {
            return false
        }
        return identifiers.contains(UTType.heic.identifier)
    }

    private func extensionForOutput(plan: OutputPlan) -> String {
        if plan.isPDF {
            return "pdf"
        }
        if plan.utType.conforms(to: .heic) {
            return "heic"
        }
        if plan.utType.conforms(to: .png) {
            return "png"
        }
        return "jpg"
    }

    // MARK: - Sizing plan

    /// What a quality mode means when nothing else constrains the encode.
    private struct NominalEncode {
        let quality: Double
        /// `nil` keeps every pixel.
        let longEdgeCap: Int?
    }

    private func nominalEncode(for mode: QualityMode) -> NominalEncode {
        switch mode {
        case .bestQuality:
            return NominalEncode(quality: 0.88, longEdgeCap: nil)
        case .balanced:
            return NominalEncode(quality: 0.72, longEdgeCap: 3072)
        case .smallestFile:
            return NominalEncode(quality: 0.55, longEdgeCap: 2048)
        }
    }

    /// Long edge of the first — and, without a target, the only — encode attempt.
    private func plannedLongEdge(settings: CompressionSettings, sourceLongEdge: Int) -> Int {
        let ceiling = min(settings.maxDimension ?? sourceLongEdge, sourceLongEdge)
        // With a target the search starts at full size and steps down only if it
        // has to, so the nominal cap does not apply.
        guard settings.targetSizeBytes == nil else { return ceiling }
        guard settings.allowResolutionDownscale, let cap = nominalEncode(for: settings.qualityMode).longEdgeCap else {
            return ceiling
        }
        return min(ceiling, cap)
    }

    /// Smallest long edge the target-driven search is willing to try.
    private func smallestLongEdge(settings: CompressionSettings, sourceLongEdge: Int) -> Int {
        let ceiling = min(settings.maxDimension ?? sourceLongEdge, sourceLongEdge)
        guard settings.allowResolutionDownscale else { return ceiling }
        return settings.qualityMode.imageLongEdgeSequence.filter { $0 < ceiling }.min() ?? ceiling
    }

    private struct SizeProjection {
        let estimatedSizeBytes: Int64
        let exceedsTarget: Bool
    }

    /// A real, cheap probe instead of a promise.
    ///
    /// Encodes the image once at 512 px, measures bytes per pixel, and extrapolates
    /// to the pixel count the real encode will use. If even the smallest resolution
    /// the search would try lands above the target, the target is reported as
    /// unrealistic and the extrapolated size is shown — not the target.
    private func projectedSize(
        source: CGImageSource,
        plan: OutputPlan,
        settings: CompressionSettings,
        input: CompressionInput,
        sourceWidth: Int,
        sourceHeight: Int
    ) -> SizeProjection {
        let original = max(input.originalSizeBytes, 1)
        let target = settings.targetSizeBytes

        // Used when the probe cannot run at all (unreadable pixels, encoder refusal).
        func fallback() -> SizeProjection {
            let estimated = Int64(Double(original) * estimatedRatio(for: settings.qualityMode))
            guard let target else {
                return SizeProjection(estimatedSizeBytes: estimated, exceedsTarget: false)
            }
            let exceeds = original > target * 8
            return SizeProjection(
                estimatedSizeBytes: exceeds ? estimated : min(estimated, Int64(Double(target) * 0.96)),
                exceedsTarget: exceeds
            )
        }

        guard sourceWidth > 0, sourceHeight > 0 else { return fallback() }
        let sourceLongEdge = max(sourceWidth, sourceHeight)
        guard let probe = try? resampledImage(source: source, maxDimension: 512) else { return fallback() }
        let prepared = preparedImage(probe, plan: plan)
        let probePixels = Double(prepared.width * prepared.height)
        guard probePixels > 0 else { return fallback() }
        let probeQuality = plan.supportsQuality ? nominalEncode(for: settings.qualityMode).quality : 1
        guard let probeData = try? encodeImageData(
            image: prepared,
            plan: plan,
            quality: probeQuality,
            metadataProperties: nil
        ), !probeData.isEmpty else {
            return fallback()
        }
        let bytesPerPixel = Double(probeData.count) / probePixels

        // Pixels per (long edge)², so any long edge can be turned into a pixel count.
        let pixelsPerSquaredEdge = Double(sourceWidth * sourceHeight) / Double(sourceLongEdge * sourceLongEdge)
        func pixels(longEdge: Int) -> Double {
            pixelsPerSquaredEdge * Double(longEdge) * Double(longEdge)
        }
        func clampedBytes(_ value: Double) -> Int64 {
            Int64(min(max(value, Double(original) * 0.02), Double(original)))
        }

        let atPlanned = clampedBytes(bytesPerPixel * pixels(longEdge: plannedLongEdge(settings: settings, sourceLongEdge: sourceLongEdge)))
        guard let target else {
            return SizeProjection(estimatedSizeBytes: atPlanned, exceedsTarget: false)
        }

        let atSmallest = clampedBytes(bytesPerPixel * pixels(longEdge: smallestLongEdge(settings: settings, sourceLongEdge: sourceLongEdge)))
        if atSmallest > target {
            return SizeProjection(estimatedSizeBytes: atSmallest, exceedsTarget: true)
        }
        // The search maximises quality under the target, so the result normally
        // lands just below it — unless the plain encode is already smaller.
        return SizeProjection(
            estimatedSizeBytes: min(atPlanned, Int64(Double(target) * 0.96)),
            exceedsTarget: false
        )
    }

    // MARK: - Helpers

    private func imageLongEdge(properties: [CFString: Any]?) -> Int {
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 2048
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 2048
        return max(width, height, 1)
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
