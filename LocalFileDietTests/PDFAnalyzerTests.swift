import PDFKit
import UIKit
import XCTest
@testable import LocalFileDiet

final class PDFAnalyzerTests: XCTestCase {
    func testVectorPDFHeuristicAvoidsScanCompression() throws {
        let url = try makeTextPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try XCTUnwrap(PDFDocument(url: url))
        let size = FileManager.default.fileSize(at: url)

        let analysis = PDFAnalyzer().analyze(document: document, fileSize: size)
        XCTAssertFalse(analysis.isLikelyScanned)
        XCTAssertGreaterThan(analysis.extractedTextCharacters, 50)
    }

    private func makeTextPDF() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vector-\(UUID().uuidString).pdf")
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        let data = renderer.pdfData { context in
            context.beginPage()
            let text = "Local File Diet keeps text PDFs readable and avoids rasterizing vector documents by default."
            text.draw(at: CGPoint(x: 72, y: 72), withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
        }
        try data.write(to: url)
        return url
    }
}

