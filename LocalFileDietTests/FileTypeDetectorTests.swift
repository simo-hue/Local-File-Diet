import Foundation
import XCTest
@testable import LocalFileDiet

final class FileTypeDetectorTests: XCTestCase {
    private let detector = FileTypeDetector()

    func testDetectsPDFByMagicBytesWithoutExtension() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("%PDF-1.7\n".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let detection = detector.detect(url: url)
        XCTAssertEqual(detection.kind, .pdf)
    }

    func testDetectsPNGByMagicBytes() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("image.bin")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let detection = detector.detect(url: url)
        XCTAssertEqual(detection.kind, .image)
    }
}

