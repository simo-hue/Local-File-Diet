import CoreGraphics
import Foundation
import PDFKit
import XCTest
@testable import LocalFileDiet

final class PDFAnalyzerTests: XCTestCase {
    func testTextDocumentHasNoImageDominantPages() throws {
        let url = try PDFFixtures.textDocument(pages: 6)
        defer { try? FileManager.default.removeItem(at: url) }
        let analysis = try analyze(url)

        XCTAssertEqual(analysis.pageCount, 6)
        XCTAssertFalse(analysis.hasImageDominantPages)
        XCTAssertFalse(analysis.isLikelyScanned)
        XCTAssertEqual(analysis.estimatedImageDominantPageCount, 0)
        XCTAssertGreaterThan(analysis.extractedTextCharacters, 50)
        XCTAssertTrue(analysis.sampledPages.allSatisfy { $0.kind == .textual })
        XCTAssertFalse(analysis.hasAnnotations)
    }

    func testScanDocumentIsAllImageDominant() throws {
        let url = try PDFFixtures.scanDocument(pages: 5)
        defer { try? FileManager.default.removeItem(at: url) }
        let analysis = try analyze(url)

        XCTAssertTrue(analysis.isLikelyScanned)
        XCTAssertEqual(analysis.imageDominantSampleCount, 5)
        XCTAssertEqual(analysis.estimatedImageDominantPageCount, 5)
        XCTAssertLessThan(analysis.extractedTextCharacters, PDFAnalyzer.maximumTextCharacters)
        XCTAssertGreaterThan(analysis.sampledPages.first?.imagePixels ?? 0, 1_000_000)
    }

    /// The heuristic the old `averageBytesPerPage > 450_000` rule got wrong in
    /// both directions: here the photo pages must be found without dragging the
    /// text pages along with them.
    func testMixedDocumentIsClassifiedPageByPage() throws {
        let url = try PDFFixtures.mixedDocument(textPages: 4, photoPages: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try XCTUnwrap(PDFDocument(url: url))
        let size = FileManager.default.fileSize(at: url)

        let profiles = PDFAnalyzer().profileAllPages(document: document, fileSize: size)
        XCTAssertEqual(profiles.count, 6)
        XCTAssertEqual(profiles.prefix(4).map(\.kind), Array(repeating: .textual, count: 4))
        XCTAssertEqual(profiles.suffix(2).map(\.kind), Array(repeating: .imageDominant, count: 2))
        XCTAssertEqual(profiles.prefix(4).reduce(Int64(0)) { $0 + $1.imageBytes }, 0)
        XCTAssertGreaterThan(profiles[4].imageBytes, 100_000)
        XCTAssertLessThan(profiles[4].textCharacters, PDFAnalyzer.maximumTextCharacters)
        XCTAssertGreaterThan(profiles[0].textCharacters, PDFAnalyzer.maximumTextCharacters)
    }

    /// A moderately compressed scan at ~150 KB a page used to be classified as a
    /// text document and therefore got no compression at all.
    func testModeratelyCompressedScanIsStillRecognised() throws {
        let url = PDFFixtures.temporaryURL(prefix: "light-scan")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try PDFPageWriter(url: url, documentInfo: [:])
        for index in 0..<4 {
            // 100 dpi at middling quality: the shape of a scan that has already
            // been through one compressor, which is what the old rule missed.
            let photo = try PDFFixtures.photograph(seed: UInt64(index + 7), width: 827, height: 1170, quality: 0.5)
            writer.writePage(mediaBox: PDFFixtures.pageBox) { context in
                context.draw(photo, in: PDFFixtures.pageBox)
            }
        }
        writer.finish()

        let size = FileManager.default.fileSize(at: url)
        let analysis = try analyze(url)
        XCTAssertLessThan(size / 4, 450_000, "Fixture is meant to be a lightly compressed scan")
        XCTAssertTrue(analysis.isLikelyScanned)
    }

    /// Long documents must not be walked end to end just to draw an estimate.
    func testSamplingIsCappedForLongDocuments() {
        XCTAssertEqual(PDFAnalyzer.sampleIndices(pageCount: 3), [0, 1, 2])
        XCTAssertEqual(PDFAnalyzer.sampleIndices(pageCount: 8), Array(0..<8))
        let sample = PDFAnalyzer.sampleIndices(pageCount: 500)
        XCTAssertLessThanOrEqual(sample.count, PDFAnalyzer.maximumSampledPages)
        XCTAssertEqual(sample.prefix(8), ArraySlice(0..<8))
        XCTAssertTrue(sample.contains(250))
        XCTAssertTrue(sample.contains(375))
    }

    private func analyze(_ url: URL) throws -> PDFAnalysis {
        let document = try XCTUnwrap(PDFDocument(url: url))
        return PDFAnalyzer().analyze(document: document, fileSize: FileManager.default.fileSize(at: url))
    }
}
