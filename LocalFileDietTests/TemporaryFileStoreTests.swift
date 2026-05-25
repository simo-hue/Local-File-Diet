import Foundation
import XCTest
@testable import LocalFileDiet

final class TemporaryFileStoreTests: XCTestCase {
    func testCopyIntoWorkingDirectoryPreservesOriginal() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("source-\(UUID().uuidString).txt")
        try Data("hello".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let store = TemporaryFileStore()
        let copy = try await store.copyIntoWorkingDirectory(from: source, preferredFilename: "demo.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path))
        try await store.clearAll()
    }
}

