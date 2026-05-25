import UIKit
import XCTest
@testable import LocalFileDiet

final class ImageCompressionEngineTests: XCTestCase {
    func testJPEGCompressionWritesReadableOutputBelowOriginal() async throws {
        let sourceURL = try makeFixtureJPEG()
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let originalSize = FileManager.default.fileSize(at: sourceURL)
        let input = CompressionInput(
            id: UUID(),
            originalURL: sourceURL,
            workingURL: sourceURL,
            originalFilename: "fixture.jpg",
            fileExtension: "jpg",
            detectedTypeIdentifier: "public.jpeg",
            fileKind: .image,
            originalSizeBytes: originalSize,
            createdAt: Date()
        )
        let store = TemporaryFileStore()
        defer { Task { try? await store.clearAll() } }
        let engine = ImageCompressionEngine(store: store)
        var settings = CompressionSettings.balanced
        settings.targetSizeBytes = Int64(Double(originalSize) * 0.85)

        let result = try await engine.compress(input: input, settings: settings) { _ in }

        XCTAssertTrue(FileManager.default.fileExists(atPath: result.outputURL.path))
        XCTAssertLessThan(result.compressedSizeBytes, originalSize)
        XCTAssertNotNil(UIImage(contentsOfFile: result.outputURL.path))
    }

    private func makeFixtureJPEG() throws -> URL {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 1200))
        let image = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1200, height: 1200))
            for index in 0..<120 {
                let color = UIColor(
                    hue: CGFloat(index) / 120,
                    saturation: 0.7,
                    brightness: 0.85,
                    alpha: 1
                )
                color.setFill()
                context.fill(CGRect(x: index * 10, y: 0, width: 8, height: 1200))
            }
            let text = "Local File Diet test image"
            text.draw(at: CGPoint(x: 80, y: 580), withAttributes: [
                .font: UIFont.boldSystemFont(ofSize: 64),
                .foregroundColor: UIColor.black
            ])
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fixture-\(UUID().uuidString).jpg")
        try XCTUnwrap(image.jpegData(compressionQuality: 0.98)).write(to: url)
        return url
    }
}
