import CoreGraphics
import CoreText
import Foundation
import ImageIO
import PDFKit
import XCTest
@testable import LocalFileDiet

final class PDFCompressionEngineTests: XCTestCase {
    // MARK: - Text PDFs are never rasterised

    func testTextOnlyPDFKeepsEveryWordAndIsNotRebuilt() async throws {
        let sourceURL = try PDFFixtures.textDocument(pages: 10)
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let originalSize = FileManager.default.fileSize(at: sourceURL)

        var settings = CompressionSettings.balanced
        settings.targetSizeBytes = originalSize / 2

        let result = try await compress(sourceURL, settings: settings)

        XCTAssertTrue(
            result.warnings.contains { $0.id == "pdfTextOnly" },
            "A text PDF should say there is nothing to shrink"
        )
        XCTAssertFalse(
            result.operationsApplied.contains { $0.id == CompressionOperation.pdfRasterRebuild.id },
            "A text PDF must not be rebuilt as images"
        )
        try assertTextSurvives(in: result.outputURL, pages: 10)
    }

    /// P2 regression: `.smallestFile` used to rasterise everything, text or not.
    func testSmallestFileStillDoesNotRasteriseATextPDF() async throws {
        let sourceURL = try PDFFixtures.textDocument(pages: 10)
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let originalSize = FileManager.default.fileSize(at: sourceURL)

        var settings = CompressionSettings.balanced
        settings.qualityMode = .smallestFile
        settings.targetSizeBytes = originalSize / 4

        let result = try await compress(sourceURL, settings: settings)

        XCTAssertFalse(
            result.operationsApplied.contains { $0.id == CompressionOperation.pdfRasterRebuild.id },
            "Smallest file must not turn a text PDF into pictures"
        )
        let warning = try XCTUnwrap(result.warnings.first { $0.id == "pdfTextOnly" })
        XCTAssertTrue(
            warning.message.contains("Smallest file"),
            "The warning should explain what smallest file would have cost"
        )
        try assertTextSurvives(in: result.outputURL, pages: 10)
    }

    // MARK: - The hybrid pass

    func testMixedDocumentShrinksPhotoPagesAndKeepsTextPages() async throws {
        let sourceURL = try PDFFixtures.mixedDocument(textPages: 4, photoPages: 2)
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let originalSize = FileManager.default.fileSize(at: sourceURL)

        var settings = CompressionSettings.balanced
        settings.targetSizeBytes = originalSize / 3

        let result = try await compress(sourceURL, settings: settings)

        XCTAssertLessThan(
            result.compressedSizeBytes,
            Int64(Double(originalSize) * 0.7),
            "Expected a real reduction, got \(result.compressedSizeBytes) of \(originalSize)"
        )
        let document = try XCTUnwrap(PDFDocument(url: result.outputURL))
        XCTAssertEqual(document.pageCount, 6)
        // The text pages come first in the fixture.
        for index in 0..<4 {
            let text = try XCTUnwrap(document.page(at: index)?.string)
            XCTAssertTrue(
                text.contains(PDFFixtures.marker(page: index)),
                "Page \(index + 1) lost its text: \(text.prefix(80))"
            )
        }
        XCTAssertTrue(result.warnings.contains { $0.id == CompressionWarning.rasterizesPDF.id })
    }

    func testScanLikeDocumentReachesAMeaningfulReduction() async throws {
        let sourceURL = try PDFFixtures.scanDocument(pages: 6)
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let originalSize = FileManager.default.fileSize(at: sourceURL)

        var settings = CompressionSettings.balanced
        settings.targetSizeBytes = originalSize / 3

        let result = try await compress(sourceURL, settings: settings)

        XCTAssertLessThan(
            result.compressedSizeBytes,
            Int64(Double(originalSize) * 0.6),
            "A scan should compress hard: \(result.compressedSizeBytes) of \(originalSize)"
        )
        let document = try XCTUnwrap(PDFDocument(url: result.outputURL))
        XCTAssertEqual(document.pageCount, 6)
    }

    /// A scanned-then-OCRed document has real photos in it, but every one of them
    /// sits under searchable text. Nothing can be rebuilt, and the warning has to
    /// say that rather than claiming there are no pictures inside.
    func testOCRedScanKeepsItsTextLayerAndExplainsItself() async throws {
        let sourceURL = try PDFFixtures.scannedThenOCRedDocument(pages: 3)
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        var settings = CompressionSettings.balanced
        settings.targetSizeBytes = FileManager.default.fileSize(at: sourceURL) / 3

        let result = try await compress(sourceURL, settings: settings)

        let warning = try XCTUnwrap(result.warnings.first { $0.id == "pdfTextOnly" })
        XCTAssertTrue(
            warning.message.contains("pages with pictures"),
            "The warning should not claim a scan has no pictures: \(warning.message)"
        )
        try assertTextSurvives(in: result.outputURL, pages: 3)
    }

    // MARK: - Early exits

    func testFileAlreadyUnderTargetIsReturnedUntouched() async throws {
        let sourceURL = try PDFFixtures.textDocument(pages: 4)
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let originalSize = FileManager.default.fileSize(at: sourceURL)

        var settings = CompressionSettings.balanced
        settings.targetSizeBytes = originalSize * 2

        let result = try await compress(sourceURL, settings: settings)

        XCTAssertEqual(result.compressedSizeBytes, originalSize)
        XCTAssertTrue(result.targetReached)
        XCTAssertTrue(result.warnings.contains { $0.id == CompressionWarning.alreadyOptimized.id })
        XCTAssertTrue(result.warnings.contains { $0.id == CompressionWarning.keptOriginal.id })
        try assertTextSurvives(in: result.outputURL, pages: 4)
    }

    // MARK: - Cancellation

    func testCancellationPropagates() async throws {
        let sourceURL = try PDFFixtures.scanDocument(pages: 8)
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let store = TemporaryFileStore()
        defer { Task { try? await store.clearAll() } }
        var settings = CompressionSettings.balanced
        settings.targetSizeBytes = FileManager.default.fileSize(at: sourceURL) / 4
        let input = Self.makeInput(url: sourceURL)

        // The engine is built inside the task: it holds a store existential, so
        // it is not `Sendable` and must not cross into the task from outside.
        let task = Task {
            try await PDFCompressionEngine(store: store).compress(input: input, settings: settings) { _ in }
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            XCTAssertTrue(true)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Estimate

    func testEstimateOnlyPromisesARebuildWhenThereArePhotoPages() async throws {
        let textURL = try PDFFixtures.textDocument(pages: 6)
        let mixedURL = try PDFFixtures.mixedDocument(textPages: 4, photoPages: 2)
        defer {
            try? FileManager.default.removeItem(at: textURL)
            try? FileManager.default.removeItem(at: mixedURL)
        }
        let store = TemporaryFileStore()
        defer { Task { try? await store.clearAll() } }
        let engine = PDFCompressionEngine(store: store)
        var settings = CompressionSettings.balanced

        // The target has to be under each file's own size, otherwise the estimate
        // short-circuits on "this already fits" and says nothing about rebuilds.
        settings.targetSizeBytes = FileManager.default.fileSize(at: textURL) / 3
        let textEstimate = try await engine.estimate(input: Self.makeInput(url: textURL), settings: settings)
        XCTAssertFalse(textEstimate.warnings.contains { $0.id == CompressionWarning.rasterizesPDF.id })
        XCTAssertFalse(textEstimate.plannedOperations.contains { $0.id == CompressionOperation.pdfRasterRebuild.id })
        XCTAssertTrue(textEstimate.warnings.contains { $0.id == "pdfTextOnly" })

        settings.targetSizeBytes = FileManager.default.fileSize(at: mixedURL) / 3
        let mixedEstimate = try await engine.estimate(input: Self.makeInput(url: mixedURL), settings: settings)
        let rebuild = try XCTUnwrap(mixedEstimate.warnings.first { $0.id == CompressionWarning.rasterizesPDF.id })
        XCTAssertTrue(rebuild.message.contains("2 of 6"), "Expected a page count in: \(rebuild.message)")
        XCTAssertTrue(mixedEstimate.plannedOperations.contains { $0.id == CompressionOperation.pdfRasterRebuild.id })
    }

    // MARK: - Helpers

    private func compress(_ url: URL, settings: CompressionSettings) async throws -> CompressionResult {
        let store = TemporaryFileStore()
        defer { Task { try? await store.clearAll() } }
        let engine = PDFCompressionEngine(store: store)
        return try await engine.compress(input: Self.makeInput(url: url), settings: settings) { _ in }
    }

    private func assertTextSurvives(in url: URL, pages: Int, file: StaticString = #filePath, line: UInt = #line) throws {
        let document = try XCTUnwrap(PDFDocument(url: url), file: file, line: line)
        XCTAssertEqual(document.pageCount, pages, file: file, line: line)
        for index in 0..<pages {
            let text = document.page(at: index)?.string ?? ""
            XCTAssertTrue(
                text.contains(PDFFixtures.marker(page: index)),
                "Page \(index + 1) lost its text: \(text.prefix(80))",
                file: file,
                line: line
            )
        }
    }

    static func makeInput(url: URL) -> CompressionInput {
        CompressionInput(
            id: UUID(),
            originalURL: url,
            workingURL: url,
            originalFilename: url.lastPathComponent,
            fileExtension: "pdf",
            detectedTypeIdentifier: "com.adobe.pdf",
            fileKind: .pdf,
            originalSizeBytes: FileManager.default.fileSize(at: url),
            createdAt: Date()
        )
    }
}

// MARK: - Fixtures (shared verbatim with the macOS verification harness)

/// PDF fixtures built with Core Graphics and Core Text.
///
/// Text pages are drawn with `CTLineDraw`, so they carry real text operators and
/// an embedded font: if the engine ever rasterises one, `PDFPage.string` stops
/// returning the words and the test fails. Photo pages embed a JPEG of a
/// gradient plus grain, which behaves like a scan under an encoder.
enum PDFFixtures {
    enum FixtureError: Error {
        case couldNotBuildImage
        case couldNotWriteDocument
    }

    static let pageBox = CGRect(x: 0, y: 0, width: 595, height: 842)

    /// The words each text page is expected to keep.
    static func marker(page index: Int) -> String {
        "Diet fixture page \(index + 1)"
    }

    static func textDocument(pages: Int, at url: URL? = nil) throws -> URL {
        let url = url ?? temporaryURL(prefix: "text")
        let writer = try PDFPageWriter(url: url, documentInfo: [kCGPDFContextCreator: "Fixture"])
        for index in 0..<pages {
            writer.writePage(mediaBox: pageBox) { context in
                fill(context, box: pageBox, gray: 1)
                draw(lines(for: index), in: context, box: pageBox)
            }
        }
        writer.finish()
        return try verified(url)
    }

    static func scanDocument(pages: Int, at url: URL? = nil) throws -> URL {
        let url = url ?? temporaryURL(prefix: "scan")
        let writer = try PDFPageWriter(url: url, documentInfo: [kCGPDFContextCreator: "Fixture"])
        for index in 0..<pages {
            let photo = try photograph(seed: UInt64(index + 1))
            writer.writePage(mediaBox: pageBox) { context in
                context.draw(photo, in: pageBox)
            }
        }
        writer.finish()
        return try verified(url)
    }

    /// Text pages first, photo pages after, so a test can point at a page index
    /// and know what should be there.
    static func mixedDocument(textPages: Int, photoPages: Int, at url: URL? = nil) throws -> URL {
        let url = url ?? temporaryURL(prefix: "mixed")
        let writer = try PDFPageWriter(url: url, documentInfo: [kCGPDFContextCreator: "Fixture"])
        for index in 0..<textPages {
            writer.writePage(mediaBox: pageBox) { context in
                fill(context, box: pageBox, gray: 1)
                draw(lines(for: index), in: context, box: pageBox)
            }
        }
        for index in 0..<photoPages {
            let photo = try photograph(seed: UInt64(100 + index))
            writer.writePage(mediaBox: pageBox) { context in
                context.draw(photo, in: pageBox)
            }
        }
        writer.finish()
        return try verified(url)
    }

    /// A scan that was later OCRed: a full-page photo with a searchable text
    /// layer over it. Every page carries text, so no page can be rebuilt without
    /// destroying it.
    static func scannedThenOCRedDocument(pages: Int, at url: URL? = nil) throws -> URL {
        let url = url ?? temporaryURL(prefix: "ocr")
        let writer = try PDFPageWriter(url: url, documentInfo: [kCGPDFContextCreator: "Fixture"])
        for index in 0..<pages {
            let photo = try photograph(seed: UInt64(200 + index))
            writer.writePage(mediaBox: pageBox) { context in
                context.draw(photo, in: pageBox)
                draw(lines(for: index), in: context, box: pageBox)
            }
        }
        writer.finish()
        return try verified(url)
    }

    // MARK: Page content

    static func lines(for index: Int) -> [String] {
        var lines = [marker(page: index)]
        for line in 0..<28 {
            lines.append("Line \(line + 1): local compression keeps this sentence selectable and searchable.")
        }
        return lines
    }

    private static func fill(_ context: CGContext, box: CGRect, gray: CGFloat) {
        context.setFillColor(gray: gray, alpha: 1)
        context.fill(box)
    }

    private static func draw(_ lines: [String], in context: CGContext, box: CGRect) {
        let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
        ]
        var y = box.maxY - 64
        for text in lines {
            guard y > box.minY + 48 else { break }
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: text, attributes: attributes)
            )
            context.textPosition = CGPoint(x: box.minX + 56, y: y)
            CTLineDraw(line, context)
            y -= 22
        }
    }

    /// A gradient with grain, encoded as a JPEG and handed back as a
    /// JPEG-backed image so the page really carries photographic bytes.
    static func photograph(
        seed: UInt64,
        width: Int = 1654,
        height: Int = 2339,
        quality: Double = 0.9
    ) throws -> CGImage {
        var value = seed &* 0x9e37_79b9_7f4a_7c15 | 1
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let cell = 4
        for row in 0..<height {
            for column in stride(from: 0, to: width, by: cell) {
                value = nextRandom(value)
                let noise = Double(value % 1000) / 1000
                let horizontal = Double(column) / Double(width)
                let vertical = Double(row) / Double(height)
                let red = UInt8(max(0, min(255, 40 + 170 * horizontal + noise * 45)))
                let green = UInt8(max(0, min(255, 30 + 160 * vertical + noise * 50)))
                let blue = UInt8(max(0, min(255, 70 + 120 * (1 - horizontal) + noise * 40)))
                for offset in 0..<cell where column + offset < width {
                    let index = (row * width + column + offset) * 4
                    pixels[index] = red
                    pixels[index + 1] = green
                    pixels[index + 2] = blue
                    pixels[index + 3] = 255
                }
            }
        }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmap: CGImage? = pixels.withUnsafeMutableBytes { buffer in
            CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )?.makeImage()
        }
        guard let bitmap else { throw FixtureError.couldNotBuildImage }
        return try PDFImageEncoder.jpegBackedImage(bitmap, quality: quality)
    }

    // MARK: Plumbing

    private static func verified(_ url: URL) throws -> URL {
        guard FileManager.default.fileSize(at: url) > 0 else {
            throw FixtureError.couldNotWriteDocument
        }
        return url
    }

    static func temporaryURL(prefix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString).pdf")
    }

    static func nextRandom(_ seed: UInt64) -> UInt64 {
        var value = seed
        value ^= value << 13
        value ^= value >> 7
        value ^= value << 17
        return value
    }
}
