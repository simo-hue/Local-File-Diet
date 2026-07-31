import CoreGraphics
import Foundation
import PDFKit

// MARK: - Analysis

/// What a single page is made of, and therefore what can be done to it.
enum PDFPageKind: String, Sendable, Hashable, Codable {
    /// Text, vectors, forms: nothing here re-encodes to fewer bytes, so the page
    /// is copied across untouched.
    case textual
    /// A photo or a scan wearing a page as a costume. Rebuilding it as a JPEG at
    /// a lower resolution is where all of a PDF's savings come from.
    case imageDominant
}

/// One page, measured rather than guessed.
struct PDFPageProfile: Sendable, Hashable, Codable {
    let pageIndex: Int
    let kind: PDFPageKind
    /// Characters PDFKit could actually extract from the page.
    let textCharacters: Int
    /// Sum of the raw (still compressed) bytes of the page's image XObjects.
    let imageBytes: Int64
    /// Sum of width x height of those images.
    let imagePixels: Int64
    let hasAnnotations: Bool
}

/// A sampled read of a document, cheap enough to run while the user is looking
/// at the file list.
///
/// `extractedTextCharacters` and `hasAnnotations` describe the SAMPLED pages
/// only — walking 500 pages to fill in a preview would be the exact stall this
/// rewrite exists to remove. `compress` profiles every page instead.
struct PDFAnalysis: Sendable, Hashable, Codable {
    let pageCount: Int
    let extractedTextCharacters: Int
    let hasAnnotations: Bool
    let sampledPages: [PDFPageProfile]
    /// Bytes of the whole file, carried so the estimate can split image bytes
    /// from everything else.
    let fileSizeBytes: Int64

    var sampledPageCount: Int { sampledPages.count }

    var imageDominantSampleCount: Int {
        sampledPages.count { $0.kind == .imageDominant }
    }

    /// Whether there is anything in this document worth re-encoding at all.
    var hasImageDominantPages: Bool { imageDominantSampleCount > 0 }

    /// The sample projected onto the whole document, rounded up so a document
    /// with one photo page never reports "0 pages will be rebuilt".
    var estimatedImageDominantPageCount: Int {
        guard sampledPageCount > 0, imageDominantSampleCount > 0 else { return 0 }
        let projected = Double(imageDominantSampleCount) / Double(sampledPageCount) * Double(pageCount)
        return min(pageCount, max(1, Int(projected.rounded())))
    }

    /// Every sampled page is a photo: the classic phone-scan-of-a-contract.
    var isLikelyScanned: Bool {
        sampledPageCount > 0 && imageDominantSampleCount == sampledPageCount
    }

    /// Image bytes across the whole document, projected from the sample and
    /// never allowed to exceed the file itself.
    var estimatedImageBytes: Int64 {
        guard sampledPageCount > 0, pageCount > 0 else { return 0 }
        let sampled = sampledPages.reduce(Int64(0)) { $0 + $1.imageBytes }
        let projected = Double(sampled) / Double(sampledPageCount) * Double(pageCount)
        return Int64(min(max(projected, 0), Double(max(fileSizeBytes, 0))))
    }
}

/// Reads what is actually inside a PDF: the image XObjects on each page and the
/// text PDFKit can extract from it.
///
/// The old heuristic ("more than 450 KB per page and almost no text") was a
/// guess about file size, not about content. A scan saved at 150 KB a page read
/// as a text document and got no compression at all, and a text report with one
/// oversized photo read as a scan and got rasterised end to end.
struct PDFAnalyzer {
    // MARK: Thresholds
    //
    // These three numbers decide whether a page is rebuilt as a picture, so they
    // are deliberately conservative: the cost of a wrong `.textual` verdict is a
    // file that did not shrink, while the cost of a wrong `.imageDominant`
    // verdict is text the user can no longer select or search.
    //
    // * `minimumImageByteShare` 0.70 — measured on the harness fixtures, a
    //   full-page photo carries 97-99% of its page's share of the file and a
    //   drawn-text page carries 0%. Anything from 0.5 to 0.9 separates them;
    //   0.70 keeps a page that mixes a photo with a headline on the image side
    //   without promoting a page whose only picture is a letterhead.
    // * `maximumTextCharacters` 100 — a rasterised page yields 0 extractable
    //   characters. 100 characters is roughly two lines of a real sentence, so a
    //   page carrying an actual paragraph is never rasterised, while a caption
    //   or a page number does not save a photo page from being rebuilt.
    // * `minimumPixelsPerPagePoint` 0.5 — the page's images must carry at least
    //   half as many pixels as the page has square points, i.e. about a full page
    //   at 51 dpi. A logo (200x100 = 20k pixels against an A4 page's 485k square
    //   points) is two orders of magnitude below that and cannot drag a text page
    //   into the raster path.
    // * `minimumImageBytes` 24 KB — an escape hatch for the share test, which
    //   compares a page against the document's AVERAGE page and therefore breaks
    //   down when page costs are wildly uneven. Measured on the harness's "five
    //   postcard photo pages next to one A0 poster" fixture: the postcards carry
    //   ~80 KB of photo each, fell under 70% of the 1.5 MB average, and were
    //   called textual despite holding nothing but a photograph. A page with no
    //   text, an image covering it, and at least this many image bytes is a photo
    //   page whatever the rest of the document looks like — and under 24 KB there
    //   was never anything worth re-encoding.
    static let minimumImageByteShare = 0.70
    static let maximumTextCharacters = 100
    static let minimumPixelsPerPagePoint = 0.5
    static let minimumImageBytes: Int64 = 24_576

    /// Sampling budget for `analyze`: the first pages plus a couple from deeper
    /// in, which is enough to tell a scan from a report without touching page 400.
    static let maximumSampledPages = 10

    /// Nested form XObjects are followed this deep. Real documents wrap page
    /// content in one form; the cap also stops a self-referencing file from
    /// recursing forever.
    static let maximumFormDepth = 3

    /// Sampled read for the estimate screen.
    func analyze(document: PDFDocument, fileSize: Int64) -> PDFAnalysis {
        let pageCount = document.pageCount
        guard pageCount > 0 else {
            return PDFAnalysis(
                pageCount: 0,
                extractedTextCharacters: 0,
                hasAnnotations: false,
                sampledPages: [],
                fileSizeBytes: fileSize
            )
        }
        let share = Self.averagePageShare(fileSize: fileSize, pageCount: pageCount)
        let profiles = Self.sampleIndices(pageCount: pageCount).compactMap {
            profile(document: document, index: $0, averagePageShare: share)
        }
        return PDFAnalysis(
            pageCount: pageCount,
            extractedTextCharacters: profiles.reduce(0) { $0 + $1.textCharacters },
            hasAnnotations: profiles.contains { $0.hasAnnotations },
            sampledPages: profiles,
            fileSizeBytes: fileSize
        )
    }

    /// Every page, because `compress` needs a verdict per page. Still cheap: this
    /// reads page dictionaries and extracted text, and decodes no pixels.
    func profileAllPages(document: PDFDocument, fileSize: Int64) -> [PDFPageProfile] {
        let pageCount = document.pageCount
        guard pageCount > 0 else { return [] }
        let share = Self.averagePageShare(fileSize: fileSize, pageCount: pageCount)
        return (0..<pageCount).compactMap {
            profile(document: document, index: $0, averagePageShare: share)
        }
    }

    // MARK: Per page

    private func profile(document: PDFDocument, index: Int, averagePageShare: Double) -> PDFPageProfile? {
        guard let page = document.page(at: index) else { return nil }
        let text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines).count ?? 0
        let images = Self.imageStats(page: document.documentRef?.page(at: index + 1))
        let bounds = page.bounds(for: .mediaBox)
        let areaPoints = max(Double(bounds.width) * Double(bounds.height), 1)

        let carriesTheFile = Double(images.bytes) >= Self.minimumImageByteShare * averagePageShare
            || images.bytes >= Self.minimumImageBytes
        let coversThePage = Double(images.pixels) >= Self.minimumPixelsPerPagePoint * areaPoints
        let readable = text >= Self.maximumTextCharacters
        let kind: PDFPageKind = (carriesTheFile && coversThePage && !readable) ? .imageDominant : .textual

        return PDFPageProfile(
            pageIndex: index,
            kind: kind,
            textCharacters: text,
            imageBytes: images.bytes,
            imagePixels: images.pixels,
            hasAnnotations: !page.annotations.isEmpty
        )
    }

    private static func averagePageShare(fileSize: Int64, pageCount: Int) -> Double {
        guard pageCount > 0 else { return 0 }
        return Double(max(fileSize, 0)) / Double(pageCount)
    }

    /// The first pages, plus two from further in so a document that starts with a
    /// cover letter and continues with 300 scanned pages is not misread.
    static func sampleIndices(pageCount: Int) -> [Int] {
        guard pageCount > 0 else { return [] }
        var indices = Array(0..<min(8, pageCount))
        if pageCount > 8 {
            indices.append(pageCount / 2)
            indices.append(pageCount * 3 / 4)
        }
        return Array(Set(indices)).sorted().prefix(maximumSampledPages).map { $0 }
    }

    // MARK: Image inventory

    /// Walks `/Resources` -> `/XObject` and adds up the image streams.
    ///
    /// Nothing is decoded: the raw stream length is what the image costs in the
    /// file, and width x height is what it costs on the page.
    static func imageStats(page: CGPDFPage?) -> (bytes: Int64, pixels: Int64) {
        guard let page, let pageDictionary = page.dictionary else { return (0, 0) }
        var resources: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(pageDictionary, "Resources", &resources),
              let resources else {
            return (0, 0)
        }
        let scan = PDFImageScan()
        scanXObjects(in: resources, scan: scan)
        return (scan.bytes, scan.pixels)
    }

    fileprivate static func scanXObjects(in resources: CGPDFDictionaryRef, scan: PDFImageScan) {
        var xobjects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects), let xobjects else { return }
        CGPDFDictionaryApplyFunction(xobjects, { _, value, info in
            guard let info else { return }
            let scan = Unmanaged<PDFImageScan>.fromOpaque(info).takeUnretainedValue()
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(value, .stream, &stream),
                  let stream,
                  let dictionary = CGPDFStreamGetDictionary(stream) else {
                return
            }

            var subtype: UnsafePointer<Int8>?
            CGPDFDictionaryGetName(dictionary, "Subtype", &subtype)
            let name = subtype.map { String(cString: $0) } ?? ""

            switch name {
            case "Image":
                var width = 0
                var height = 0
                CGPDFDictionaryGetInteger(dictionary, "Width", &width)
                CGPDFDictionaryGetInteger(dictionary, "Height", &height)

                // `/Length` is required by the spec and costs nothing to read.
                // Copying the stream is the slow road to the same number, kept
                // only for files that have been rebuilt badly.
                var length = 0
                if !CGPDFDictionaryGetInteger(dictionary, "Length", &length) || length <= 0 {
                    var format = CGPDFDataFormat.raw
                    if let raw = CGPDFStreamCopyData(stream, &format) {
                        length = CFDataGetLength(raw)
                    }
                }
                scan.bytes += Int64(max(length, 0))
                scan.pixels += Int64(max(width, 0)) * Int64(max(height, 0))
            case "Form":
                // A page whose content is wrapped in a form XObject keeps its
                // images one level down. Stopping here would report "no images".
                guard scan.depth < PDFAnalyzer.maximumFormDepth else { return }
                var nested: CGPDFDictionaryRef?
                guard CGPDFDictionaryGetDictionary(dictionary, "Resources", &nested), let nested else { return }
                scan.depth += 1
                PDFAnalyzer.scanXObjects(in: nested, scan: scan)
                scan.depth -= 1
            default:
                return
            }
        }, Unmanaged.passUnretained(scan).toOpaque())
    }
}

/// Mutable tally passed through Core Graphics' C applier, which cannot capture.
fileprivate final class PDFImageScan {
    var bytes: Int64 = 0
    var pixels: Int64 = 0
    var depth = 0
}

// MARK: - Engine

/// Compresses PDFs page by page instead of document by document.
///
/// The old engine had two modes and both were wrong. "Conservative" handed the
/// document to PDFKit and wrote it straight back out, which recompresses exactly
/// nothing. "Rasterise" turned every page of every document into a picture,
/// destroying selectable text on documents that were mostly text, and did it in
/// up to twelve full-document render passes.
///
/// This one classifies each page and makes one output pass: photo pages are
/// re-encoded as JPEGs at a measured resolution, and every other page is copied
/// across with its text, vectors and links intact.
struct PDFCompressionEngine: CompressionEngine {
    /// Full render passes allowed after the one-page probe. Probe + 3 passes
    /// means no page is ever rendered more than four times, against the old
    /// engine's fixed twelve.
    private static let maximumRenderPasses = 3

    /// Hard ceiling on one page's raster, whatever DPI the search asked for.
    /// 4 MP is an A4 page at ~170 dpi and costs ~16 MB as RGBA, and exactly one
    /// such bitmap is alive at a time.
    private static let maximumPagePixels: Double = 4_000_000

    private let store: TemporaryFileStoring
    private let analyzer: PDFAnalyzer
    private let fileManager: FileManager

    init(store: TemporaryFileStoring, analyzer: PDFAnalyzer = PDFAnalyzer(), fileManager: FileManager = .default) {
        self.store = store
        self.analyzer = analyzer
        self.fileManager = fileManager
    }

    // MARK: Estimate

    func estimate(input: CompressionInput, settings: CompressionSettings) async throws -> CompressionEstimate {
        let document = try openDocument(input.workingURL)
        let sourceSize = sourceSize(input: input)
        let analysis = analyzer.analyze(document: document, fileSize: sourceSize)

        // Nothing to promise when the file already fits.
        if let target = settings.targetSizeBytes, sourceSize <= target {
            return CompressionEstimate(
                estimatedSizeBytes: sourceSize,
                estimatedReductionPercent: 0,
                predictedQuality: .excellent,
                warnings: [.alreadyOptimized],
                plannedOperations: [.verifyOutput]
            )
        }

        // No photo pages means no lever. Saying so is more useful than promising
        // a percentage the engine cannot deliver.
        guard analysis.hasImageDominantPages else {
            var warnings: [CompressionWarning] = [
                .pdfTextOnly(
                    smallestFileRequested: settings.qualityMode == .smallestFile,
                    imagesUnderText: Self.imagesSitUnderText(imageBytes: analysis.estimatedImageBytes, fileSize: sourceSize)
                )
            ]
            if settings.targetSizeBytes != nil {
                warnings.append(.targetMayBeUnrealistic)
            }
            return CompressionEstimate(
                estimatedSizeBytes: sourceSize,
                estimatedReductionPercent: 0,
                predictedQuality: .excellent,
                warnings: warnings,
                plannedOperations: [.verifyOutput]
            )
        }

        var warnings: [CompressionWarning] = [
            .pdfPagesRebuilt(imageDominantPages: analysis.estimatedImageDominantPageCount, of: analysis.pageCount)
        ]
        var operations: [CompressionOperation] = [.pdfRasterRebuild, .reencode, .verifyOutput]
        if settings.stripMetadata {
            operations.insert(.stripMetadata, at: 0)
        }
        if analysis.hasAnnotations {
            warnings.append(.pdfAnnotations)
        }

        let imageBytes = analysis.estimatedImageBytes
        let fixedBytes = max(sourceSize - imageBytes, 0)
        let estimated = fixedBytes + Int64(Double(imageBytes) * Self.expectedImageRatio(for: settings.qualityMode))
        if let target = settings.targetSizeBytes,
           fixedBytes + Int64(Double(imageBytes) * Self.floorImageRatio) > target {
            // Even at the floor DPI the untouched pages alone overshoot.
            warnings.append(.targetMayBeUnrealistic)
        }

        return CompressionEstimate(
            estimatedSizeBytes: min(estimated, sourceSize),
            estimatedReductionPercent: CompressionMath.estimatedReduction(
                original: input.originalSizeBytes,
                estimated: min(estimated, sourceSize)
            ),
            predictedQuality: Self.predictedQuality(for: settings, analysis: analysis),
            warnings: warnings,
            plannedOperations: operations
        )
    }

    // MARK: Compress

    func compress(
        input: CompressionInput,
        settings: CompressionSettings,
        progress: @escaping @Sendable (CompressionProgress) -> Void
    ) async throws -> CompressionResult {
        let start = Date()
        progress(.preparing)
        try Task.checkCancellation()

        let document = try openDocument(input.workingURL)
        let sourceSize = sourceSize(input: input)

        // P6: the file already satisfies the target, so every byte of work below
        // would be spent proving the answer is "keep what you have".
        if let target = settings.targetSizeBytes, sourceSize <= target {
            return try await finishKeepingOriginal(
                input: input,
                settings: settings,
                warnings: [.alreadyOptimized],
                operations: [.verifyOutput],
                start: start,
                progress: progress
            )
        }

        progress(CompressionProgress(phase: .analyzing, fractionCompleted: 0.06, message: "Looking at the pages"))
        let profiles = analyzer.profileAllPages(document: document, fileSize: sourceSize)
        try Task.checkCancellation()
        let imageDominant = profiles.filter { $0.kind == .imageDominant }

        // A text or vector PDF has nothing this engine can re-encode. Rendering
        // it would burn the time AND lose the text, so it does not happen — not
        // even for `.smallestFile`, which is where the old engine did its worst
        // damage.
        guard !imageDominant.isEmpty else {
            var warnings: [CompressionWarning] = [
                .pdfTextOnly(
                    smallestFileRequested: settings.qualityMode == .smallestFile,
                    imagesUnderText: Self.imagesSitUnderText(
                        imageBytes: profiles.reduce(Int64(0)) { $0 + $1.imageBytes },
                        fileSize: sourceSize
                    )
                )
            ]
            // The early exit above already ruled out "the file fits", so a target
            // that is still set is a target this engine cannot reach.
            if settings.targetSizeBytes != nil {
                warnings.append(.targetMayBeUnrealistic)
            }
            return try await finishKeepingOriginal(
                input: input,
                settings: settings,
                warnings: warnings,
                operations: [.verifyOutput],
                start: start,
                progress: progress
            )
        }

        guard let cgDocument = document.documentRef ?? CGPDFDocument(input.workingURL as CFURL) else {
            throw AppError.corruptFile
        }

        var warnings: [CompressionWarning] = [
            .pdfPagesRebuilt(imageDominantPages: imageDominant.count, of: profiles.count)
        ]
        var operations: [CompressionOperation] = [.pdfRasterRebuild, .reencode, .verifyOutput]
        if settings.stripMetadata {
            operations.insert(.stripMetadata, at: 0)
        }
        if profiles.contains(where: \.hasAnnotations) {
            warnings.append(.pdfAnnotations)
        }

        let documentInfo = outputDocumentInfo(document: document, settings: settings)
        let workDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("PDF-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workDirectory) }

        let bestURL = try searchForBestPass(
            cgDocument: cgDocument,
            profiles: profiles,
            imageDominant: imageDominant,
            settings: settings,
            sourceSize: sourceSize,
            documentInfo: documentInfo,
            workDirectory: workDirectory,
            progress: progress
        )

        let outputURL = try await store.makeOutputURL(originalFilename: input.originalFilename, extension: "pdf")
        if fileManager.fileExists(atPath: outputURL.path) {
            try? fileManager.removeItem(at: outputURL)
        }
        try fileManager.copyItem(at: bestURL, to: outputURL)

        try Task.checkCancellation()
        if let target = settings.targetSizeBytes, fileManager.fileSize(at: outputURL) > target {
            warnings.append(.targetMayBeUnrealistic)
        }

        return try await finish(
            candidateURL: outputURL,
            input: input,
            settings: settings,
            warnings: warnings,
            operations: operations,
            start: start,
            progress: progress
        )
    }

    // MARK: Search

    /// Probe once, then correct at most `maximumRenderPasses` times.
    ///
    /// The old engine walked a fixed ladder of four DPI values x three qualities
    /// and rendered every page of the document twelve times when the target was
    /// unreachable. This renders ONE page to learn the document's real bytes per
    /// page, picks a starting DPI from that measurement, and then adjusts by the
    /// measured ratio — stopping the moment the target is met.
    private func searchForBestPass(
        cgDocument: CGPDFDocument,
        profiles: [PDFPageProfile],
        imageDominant: [PDFPageProfile],
        settings: CompressionSettings,
        sourceSize: Int64,
        documentInfo: [CFString: Any],
        workDirectory: URL,
        progress: @escaping @Sendable (CompressionProgress) -> Void
    ) throws -> URL {
        var raster = Self.nominalRaster(for: settings.qualityMode)
        // Bytes the passes cannot touch: text pages, fonts, the file structure.
        let fixedBytes = max(sourceSize - imageDominant.reduce(Int64(0)) { $0 + $1.imageBytes }, 0)

        if let target = settings.targetSizeBytes {
            progress(CompressionProgress(
                phase: .analyzing,
                fractionCompleted: 0.12,
                message: "Measuring one page"
            ))
            if let probed = try probeRaster(
                cgDocument: cgDocument,
                imageDominant: imageDominant,
                settings: settings,
                target: target,
                fixedBytes: fixedBytes
            ) {
                raster = probed
            }
        }

        let passLimit = settings.targetSizeBytes == nil ? 1 : Self.maximumRenderPasses
        let span = 0.72 / Double(passLimit)
        var best: (url: URL, size: Int64)?

        for pass in 0..<passLimit {
            try Task.checkCancellation()
            let passURL = workDirectory.appendingPathComponent("pass-\(pass).pdf")
            try renderDocument(
                to: passURL,
                cgDocument: cgDocument,
                profiles: profiles,
                raster: raster,
                documentInfo: documentInfo,
                progressBase: 0.18 + Double(pass) * span,
                progressSpan: span,
                progress: progress
            )
            let size = fileManager.fileSize(at: passURL)
            guard size > 0 else { throw AppError.exportFailed }
            if best == nil || size < best!.size {
                best = (passURL, size)
            }

            guard let target = settings.targetSizeBytes, size > target else { break }
            guard pass + 1 < passLimit else { break }
            guard let next = Self.adjusted(
                raster,
                measured: size,
                target: target,
                fixedBytes: fixedBytes,
                mode: settings.qualityMode
            ) else {
                // Already at the floor: another pass would render the same file.
                break
            }
            raster = next
        }

        guard let best else { throw AppError.exportFailed }
        return best.url
    }

    /// Renders a single representative page to learn what a page really costs,
    /// then solves for the DPI and quality that would land on the target.
    private func probeRaster(
        cgDocument: CGPDFDocument,
        imageDominant: [PDFPageProfile],
        settings: CompressionSettings,
        target: Int64,
        fixedBytes: Int64
    ) throws -> RasterSettings? {
        // The median photo page, not the biggest one: the biggest would make
        // every estimate pessimistic and start the search far too low.
        let sorted = imageDominant.sorted { $0.imageBytes < $1.imageBytes }
        guard let representative = sorted[safe: sorted.count / 2],
              let page = cgDocument.page(at: representative.pageIndex + 1) else {
            return nil
        }

        let nominal = Self.nominalRaster(for: settings.qualityMode)
        let geometry = PageGeometry(page: page)
        let probeBytes = try autoreleasepool { () -> Int in
            let bitmap = try renderBitmap(page: page, geometry: geometry, dpi: nominal.dpi)
            return try PDFImageEncoder.jpegData(bitmap, quality: nominal.quality).count
        }
        guard probeBytes > 0 else { return nil }

        let budget = Double(target) * 0.95 - Double(fixedBytes)
        let perPageBudget = budget / Double(imageDominant.count)
        return Self.solve(
            from: nominal,
            ratio: perPageBudget / Double(probeBytes),
            mode: settings.qualityMode
        )
    }

    /// Where a mode starts when nothing has been measured yet.
    private static func nominalRaster(for mode: QualityMode) -> RasterSettings {
        switch mode {
        case .bestQuality: RasterSettings(dpi: 200, quality: 0.85)
        case .balanced: RasterSettings(dpi: 150, quality: 0.70)
        case .smallestFile: RasterSettings(dpi: 110, quality: 0.50)
        }
    }

    /// Turns "the output must be `ratio` times smaller" into a DPI and a quality.
    ///
    /// The model is crude on purpose — JPEG bytes roughly track pixel count
    /// (i.e. dpi²) and roughly track quality in the 0.3-0.9 band. It only has to
    /// pick a sensible starting point; the passes measure the truth and correct.
    /// Quality is spent first because dropping from 0.85 to 0.55 costs far less
    /// legibility than halving the resolution of a scan.
    private static func solve(from raster: RasterSettings, ratio: Double, mode: QualityMode) -> RasterSettings {
        guard ratio.isFinite else { return raster }
        let dpiRange = mode.pdfDPIRange
        let qualityRange = mode.compressionQualityRange
        guard ratio > 0 else {
            return RasterSettings(dpi: dpiRange.lowerBound, quality: qualityRange.lowerBound)
        }
        guard ratio < 1 else {
            return RasterSettings(
                dpi: min(raster.dpi, dpiRange.upperBound),
                quality: min(raster.quality, qualityRange.upperBound)
            )
        }

        let quality = max(qualityRange.lowerBound, raster.quality * ratio)
        let deliveredByQuality = quality / raster.quality
        let remaining = min(1, ratio / max(deliveredByQuality, 0.0001))
        let dpi = max(dpiRange.lowerBound, min(dpiRange.upperBound, raster.dpi * CGFloat(remaining.squareRoot())))
        return RasterSettings(dpi: dpi, quality: quality)
    }

    /// The correction between two full passes, using the size that was actually
    /// written. Returns `nil` when there is nothing left to give.
    private static func adjusted(
        _ raster: RasterSettings,
        measured: Int64,
        target: Int64,
        fixedBytes: Int64,
        mode: QualityMode
    ) -> RasterSettings? {
        let floorRaster = RasterSettings(dpi: mode.pdfDPIRange.lowerBound, quality: mode.compressionQualityRange.lowerBound)
        if raster.isEssentially(floorRaster) { return nil }

        // Only the rebuilt pages respond to the knobs, so the fixed bytes come
        // out of both sides before the ratio is taken.
        let fixed = min(Double(fixedBytes), Double(measured) * 0.9)
        let wanted = Double(target) * 0.95 - fixed
        let current = max(Double(measured) - fixed, 1)
        let next = solve(from: raster, ratio: wanted / current, mode: mode)
        return next.isEssentially(raster) ? nil : next
    }

    // MARK: Rendering

    /// One output pass over the whole document.
    ///
    /// Photo pages become JPEGs; every other page is replayed into the new file
    /// with `drawPDFPage`, which copies its content stream — text stays text,
    /// vectors stay vectors, and the page costs nothing to "compress".
    private func renderDocument(
        to url: URL,
        cgDocument: CGPDFDocument,
        profiles: [PDFPageProfile],
        raster: RasterSettings,
        documentInfo: [CFString: Any],
        progressBase: Double,
        progressSpan: Double,
        progress: @escaping @Sendable (CompressionProgress) -> Void
    ) throws {
        let writer = try PDFPageWriter(url: url, documentInfo: documentInfo)
        let pageCount = max(profiles.count, 1)

        for (position, profile) in profiles.enumerated() {
            try Task.checkCancellation()
            try autoreleasepool {
                guard let page = cgDocument.page(at: profile.pageIndex + 1) else { return }
                let geometry = PageGeometry(page: page)
                switch profile.kind {
                case .textual:
                    writer.writePage(mediaBox: geometry.outputBox) { context in
                        context.concatenate(geometry.transform)
                        context.drawPDFPage(page)
                    }
                case .imageDominant:
                    // The bitmap dies inside `rasterizedImage`; only the small
                    // JPEG-backed image survives to the draw call.
                    let image = try rasterizedImage(page: page, geometry: geometry, raster: raster)
                    writer.writePage(mediaBox: geometry.outputBox) { context in
                        context.interpolationQuality = .high
                        context.draw(image, in: geometry.outputBox)
                    }
                }
            }
            progress(CompressionProgress(
                phase: profile.kind == .imageDominant ? .encoding : .writing,
                fractionCompleted: progressBase + progressSpan * (Double(position + 1) / Double(pageCount)),
                message: profile.kind == .imageDominant
                    ? "Rebuilding page \(profile.pageIndex + 1) of \(pageCount)"
                    : "Keeping text on page \(profile.pageIndex + 1) of \(pageCount)"
            ))
        }

        writer.finish()
    }

    private func rasterizedImage(page: CGPDFPage, geometry: PageGeometry, raster: RasterSettings) throws -> CGImage {
        try autoreleasepool {
            let bitmap = try renderBitmap(page: page, geometry: geometry, dpi: raster.dpi)
            return try PDFImageEncoder.jpegBackedImage(bitmap, quality: raster.quality)
        }
    }

    /// Draws one page into one bitmap, capped at `maximumPagePixels`.
    ///
    /// There is no second decode and no `UIImage`: the bitmap goes straight to
    /// the JPEG encoder, so a single page never holds more than one full-size
    /// buffer.
    private func renderBitmap(page: CGPDFPage, geometry: PageGeometry, dpi: CGFloat) throws -> CGImage {
        let size = geometry.outputBox.size
        let scale = Self.rasterScale(size: size, dpi: dpi)
        let width = max(Int((size.width * scale).rounded()), 1)
        let height = max(Int((size.height * scale).rounded()), 1)
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
            throw AppError.exportFailed
        }
        // PDF pages are opaque and a scan's paper is white; without this the page
        // would be rebuilt on black.
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.scaleBy(x: scale, y: scale)
        context.concatenate(geometry.transform)
        context.drawPDFPage(page)
        guard let image = context.makeImage() else { throw AppError.exportFailed }
        return image
    }

    /// Pixels per point, clamped so no page can exceed the pixel budget however
    /// high the requested DPI or however large the page.
    static func rasterScale(size: CGSize, dpi: CGFloat) -> CGFloat {
        let area = max(Double(size.width) * Double(size.height), 1)
        let requested = max(Double(dpi) / 72, 0.1)
        let ceiling = (maximumPagePixels / area).squareRoot()
        return CGFloat(min(requested, ceiling))
    }

    // MARK: Document plumbing

    private func openDocument(_ url: URL) throws -> PDFDocument {
        guard let document = PDFDocument(url: url) else {
            throw AppError.corruptFile
        }
        if document.isLocked {
            throw AppError.protectedPDF
        }
        return document
    }

    private func sourceSize(input: CompressionInput) -> Int64 {
        let onDisk = fileManager.fileSize(at: input.workingURL)
        return onDisk > 0 ? onDisk : input.originalSizeBytes
    }

    /// Carries the document's own description into the rebuilt file.
    ///
    /// "Remove metadata" is a privacy switch — an author name is exactly what it
    /// exists to drop — so the descriptive fields ride along only when the user
    /// turned it off. The creator is always ours, because the file genuinely was
    /// written here.
    private func outputDocumentInfo(document: PDFDocument, settings: CompressionSettings) -> [CFString: Any] {
        var info: [CFString: Any] = [kCGPDFContextCreator: "Local File Diet"]
        guard !settings.stripMetadata, let attributes = document.documentAttributes else { return info }

        func copy(_ attribute: PDFDocumentAttribute, to key: CFString) {
            if let value = attributes[attribute] as? String, !value.isEmpty {
                info[key] = value
            }
        }
        copy(.titleAttribute, to: kCGPDFContextTitle)
        copy(.authorAttribute, to: kCGPDFContextAuthor)
        copy(.subjectAttribute, to: kCGPDFContextSubject)

        if let keywords = attributes[PDFDocumentAttribute.keywordsAttribute] {
            if let list = keywords as? [String], !list.isEmpty {
                info[kCGPDFContextKeywords] = list.joined(separator: ", ")
            } else if let text = keywords as? String, !text.isEmpty {
                info[kCGPDFContextKeywords] = text
            }
        }
        return info
    }

    // MARK: Finishing

    /// Hands the untouched original back through the same guard the real passes
    /// use, so the "original kept" bookkeeping is identical everywhere.
    private func finishKeepingOriginal(
        input: CompressionInput,
        settings: CompressionSettings,
        warnings: [CompressionWarning],
        operations: [CompressionOperation],
        start: Date,
        progress: @escaping @Sendable (CompressionProgress) -> Void
    ) async throws -> CompressionResult {
        let outputURL = try await store.makeOutputURL(originalFilename: input.originalFilename, extension: "pdf")
        if fileManager.fileExists(atPath: outputURL.path) {
            try? fileManager.removeItem(at: outputURL)
        }
        try fileManager.copyItem(at: input.workingURL, to: outputURL)
        return try await finish(
            candidateURL: outputURL,
            input: input,
            settings: settings,
            warnings: warnings,
            operations: operations,
            start: start,
            progress: progress
        )
    }

    private func finish(
        candidateURL: URL,
        input: CompressionInput,
        settings: CompressionSettings,
        warnings: [CompressionWarning],
        operations: [CompressionOperation],
        start: Date,
        progress: @escaping @Sendable (CompressionProgress) -> Void
    ) async throws -> CompressionResult {
        progress(CompressionProgress(phase: .verifying, fractionCompleted: 0.94, message: "Checking the result"))
        var warnings = warnings
        let resolved = try await OutputGuard.resolve(
            candidateURL: candidateURL,
            input: input,
            store: store,
            fileManager: fileManager
        )
        let finalSize = fileManager.fileSize(at: resolved.url)
        guard finalSize > 0 else {
            throw AppError.exportFailed
        }
        if resolved.keptOriginal {
            warnings = OutputGuard.warningsAfterKeepingOriginal(
                warnings,
                finalSize: finalSize,
                target: settings.targetSizeBytes
            )
        }

        progress(CompressionProgress(phase: .completed, fractionCompleted: 1, message: "PDF ready"))
        return CompressionResult(
            outputURL: resolved.url,
            outputFilename: resolved.url.lastPathComponent,
            originalSizeBytes: input.originalSizeBytes,
            compressedSizeBytes: finalSize,
            targetReached: CompressionMath.targetReached(size: finalSize, target: settings.targetSizeBytes),
            reductionPercent: CompressionMath.reductionPercent(original: input.originalSizeBytes, compressed: finalSize),
            warnings: warnings,
            operationsApplied: operations.unique(),
            durationSeconds: Date().timeIntervalSince(start)
        )
    }

    // MARK: Estimate maths

    /// What a rebuilt photo page is worth, as a fraction of the image bytes it
    /// started with. Measured against the harness fixtures, where a 200 dpi
    /// scan page re-encodes to roughly a third of its original size at balanced.
    private static func expectedImageRatio(for mode: QualityMode) -> Double {
        switch mode {
        case .bestQuality: 0.62
        case .balanced: 0.38
        case .smallestFile: 0.20
        }
    }

    /// The best the raster path can ever do, used to spot an impossible target.
    private static let floorImageRatio = 0.08

    /// Whether a document with no rebuildable page nonetheless carries real
    /// pictures — the shape of a scan that was later OCRed, where every photo
    /// sits under a layer of searchable text.
    ///
    /// Nothing can be rebuilt either way, but telling that user "no photos or
    /// scans inside" would be plainly wrong, so the warning changes its wording.
    /// Threshold: a third of the file, which no letterhead or chart ever reaches.
    private static func imagesSitUnderText(imageBytes: Int64, fileSize: Int64) -> Bool {
        fileSize > 0 && Double(imageBytes) >= 0.30 * Double(fileSize)
    }

    private static func predictedQuality(for settings: CompressionSettings, analysis: PDFAnalysis) -> PredictedQuality {
        // Only the rebuilt pages lose anything; a document that is mostly text
        // comes out essentially untouched.
        guard analysis.isLikelyScanned else {
            return settings.qualityMode == .smallestFile ? .good : .excellent
        }
        switch settings.qualityMode {
        case .bestQuality: return .excellent
        case .balanced: return .good
        case .smallestFile: return .acceptable
        }
    }
}

// MARK: - Supporting types

/// One page's DPI and JPEG quality.
struct RasterSettings: Sendable, Hashable {
    var dpi: CGFloat
    var quality: Double

    /// Two settings close enough that another pass would produce the same file.
    func isEssentially(_ other: RasterSettings) -> Bool {
        abs(dpi - other.dpi) < 2 && abs(quality - other.quality) < 0.02
    }
}

/// Where a source page has to be drawn, and how big the output page must be.
///
/// `getDrawingTransform` is doing the real work: it maps the page's box into the
/// output rectangle and applies the page's own `/Rotate`, so landscape scans and
/// pages with a non-zero box origin come out the right way up.
struct PageGeometry {
    let outputBox: CGRect
    let transform: CGAffineTransform

    init(page: CGPDFPage) {
        var box = page.getBoxRect(.cropBox)
        if box.isEmpty || box.isNull || box.isInfinite {
            box = page.getBoxRect(.mediaBox)
        }
        if box.isEmpty || box.isNull || box.isInfinite {
            box = CGRect(x: 0, y: 0, width: 612, height: 792)
        }
        let rotation = ((Int(page.rotationAngle) % 360) + 360) % 360
        let size = (rotation == 90 || rotation == 270)
            ? CGSize(width: box.height, height: box.width)
            : box.size
        outputBox = CGRect(
            origin: .zero,
            size: CGSize(width: max(size.width, 1), height: max(size.height, 1))
        )
        transform = page.getDrawingTransform(.cropBox, rect: outputBox, rotate: 0, preserveAspectRatio: true)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
