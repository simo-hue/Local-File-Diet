import ImageIO
import PDFKit
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import LocalFileDiet

final class ImageCompressionEngineTests: XCTestCase {
    func testJPEGCompressionWritesReadableOutputBelowOriginal() async throws {
        let sourceURL = try makeFixtureJPEG()
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let originalSize = FileManager.default.fileSize(at: sourceURL)
        let input = makeInput(url: sourceURL, filename: "fixture.jpg")
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

    // MARK: - Transparency

    func testAutomaticOutputKeepsAlphaWhenTransparencyIsPreserved() async throws {
        let sourceURL = try makeFixturePNGWithAlpha()
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let store = TemporaryFileStore()
        defer { Task { try? await store.clearAll() } }
        let engine = ImageCompressionEngine(store: store)
        var settings = CompressionSettings.balanced
        settings.targetSizeBytes = nil
        settings.outputFormat = .automatic
        settings.preserveTransparency = true

        let result = try await engine.compress(
            input: makeInput(url: sourceURL, filename: "fixture-alpha.png"),
            settings: settings
        ) { _ in }

        let output = try loadOutput(result.outputURL)
        XCTAssertTrue(
            output.type.conforms(to: .png) || output.type.conforms(to: .heic),
            "Expected an alpha-capable format, got \(output.type.identifier)"
        )
        let pixel = try samplePixel(output.image, x: 30, y: 30)
        XCTAssertLessThan(pixel.a, 64, "The transparent corner should still be transparent")
        XCTAssertFalse(result.warnings.contains { $0.id == CompressionWarning.transparencyFlattened.id })
    }

    func testExplicitJPEGFlattensTransparencyToWhiteNotBlack() async throws {
        let sourceURL = try makeFixturePNGWithAlpha()
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let store = TemporaryFileStore()
        defer { Task { try? await store.clearAll() } }
        let engine = ImageCompressionEngine(store: store)
        var settings = CompressionSettings.balanced
        settings.targetSizeBytes = nil
        settings.outputFormat = .jpeg
        settings.preserveTransparency = true

        let result = try await engine.compress(
            input: makeInput(url: sourceURL, filename: "fixture-alpha.png"),
            settings: settings
        ) { _ in }

        let output = try loadOutput(result.outputURL)
        XCTAssertTrue(output.type.conforms(to: .jpeg), "Expected JPEG, got \(output.type.identifier)")
        let pixel = try samplePixel(output.image, x: 30, y: 30)
        XCTAssertGreaterThan(pixel.r, 240)
        XCTAssertGreaterThan(pixel.g, 240)
        XCTAssertGreaterThan(pixel.b, 240)
        XCTAssertTrue(result.warnings.contains { $0.id == CompressionWarning.transparencyFlattened.id })
    }

    func testTransparencyOffFlattensToWhiteWithoutWarning() async throws {
        let sourceURL = try makeFixturePNGWithAlpha()
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let store = TemporaryFileStore()
        defer { Task { try? await store.clearAll() } }
        let engine = ImageCompressionEngine(store: store)
        var settings = CompressionSettings.balanced
        settings.targetSizeBytes = nil
        settings.outputFormat = .automatic
        settings.preserveTransparency = false

        let result = try await engine.compress(
            input: makeInput(url: sourceURL, filename: "fixture-alpha.png"),
            settings: settings
        ) { _ in }

        let output = try loadOutput(result.outputURL)
        let pixel = try samplePixel(output.image, x: 30, y: 30)
        XCTAssertGreaterThan(pixel.r, 240)
        XCTAssertGreaterThan(pixel.g, 240)
        XCTAssertGreaterThan(pixel.b, 240)
        XCTAssertFalse(result.warnings.contains { $0.id == CompressionWarning.transparencyFlattened.id })
    }

    // MARK: - PDF output

    func testPDFOutputProducesSinglePageDocument() async throws {
        let sourceURL = try makeFixtureLargePhotoJPEG()
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let originalSize = FileManager.default.fileSize(at: sourceURL)
        let store = TemporaryFileStore()
        defer { Task { try? await store.clearAll() } }
        let engine = ImageCompressionEngine(store: store)
        var settings = CompressionSettings.balanced
        settings.outputFormat = .pdf
        settings.qualityMode = .smallestFile
        settings.targetSizeBytes = originalSize / 4

        let result = try await engine.compress(
            input: makeInput(url: sourceURL, filename: "fixture-photo.jpg"),
            settings: settings
        ) { _ in }

        let data = try Data(contentsOf: result.outputURL)
        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "%PDF")
        let document = try XCTUnwrap(PDFDocument(url: result.outputURL))
        XCTAssertEqual(document.pageCount, 1)
    }

    // MARK: - No target size

    func testNoTargetSmallestFileStillCompresses() async throws {
        let sourceURL = try makeFixtureLargePhotoJPEG()
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let originalSize = FileManager.default.fileSize(at: sourceURL)
        let store = TemporaryFileStore()
        defer { Task { try? await store.clearAll() } }
        let engine = ImageCompressionEngine(store: store)
        var settings = CompressionSettings.balanced
        settings.targetSizeBytes = nil
        settings.qualityMode = .smallestFile
        settings.outputFormat = .jpeg

        let result = try await engine.compress(
            input: makeInput(url: sourceURL, filename: "fixture-photo.jpg"),
            settings: settings
        ) { _ in }

        XCTAssertGreaterThanOrEqual(
            result.reductionPercent,
            25,
            "No-target compression only reached \(result.compressedSizeBytes) of \(originalSize) bytes"
        )
    }

    // MARK: - Metadata

    func testKeepingMetadataWritesTheNewPixelDimensions() async throws {
        let sourceURL = try makeFixturePhotoWithEXIF()
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let store = TemporaryFileStore()
        defer { Task { try? await store.clearAll() } }
        let engine = ImageCompressionEngine(store: store)
        var settings = CompressionSettings.balanced
        settings.targetSizeBytes = nil
        settings.qualityMode = .smallestFile
        settings.outputFormat = .jpeg
        settings.stripMetadata = false
        settings.allowResolutionDownscale = true

        let result = try await engine.compress(
            input: makeInput(url: sourceURL, filename: "fixture-exif.jpg"),
            settings: settings
        ) { _ in }

        let output = try loadOutput(result.outputURL)
        let declaredWidth = output.properties[kCGImagePropertyPixelWidth] as? Int
        let declaredHeight = output.properties[kCGImagePropertyPixelHeight] as? Int
        XCTAssertEqual(declaredWidth, output.image.width)
        XCTAssertEqual(declaredHeight, output.image.height)
        XCTAssertNotEqual(declaredWidth, Self.photoWidth, "The file still advertises the original width")

        let exif = output.properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        XCTAssertNotNil(exif?[kCGImagePropertyExifUserComment], "Metadata was supposed to be kept")
        XCTAssertEqual(exif?[kCGImagePropertyExifPixelXDimension] as? Int, output.image.width)
        XCTAssertEqual(output.properties[kCGImagePropertyOrientation] as? Int, 1)
    }

    // MARK: - Estimate

    func testEstimateDoesNotPromiseAnUnreachableTarget() async throws {
        let sourceURL = try makeFixtureLargePhotoJPEG()
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let store = TemporaryFileStore()
        defer { Task { try? await store.clearAll() } }
        let engine = ImageCompressionEngine(store: store)
        var settings = CompressionSettings.balanced
        settings.targetSizeBytes = 1024
        settings.outputFormat = .jpeg

        let estimate = try await engine.estimate(
            input: makeInput(url: sourceURL, filename: "fixture-photo.jpg"),
            settings: settings
        )

        let estimated = try XCTUnwrap(estimate.estimatedSizeBytes)
        XCTAssertGreaterThan(estimated, 10_000, "The estimate is still just the target with a haircut")
        XCTAssertTrue(estimate.warnings.contains { $0.id == CompressionWarning.targetMayBeUnrealistic.id })
    }

    // MARK: - Fixtures

    private static let photoWidth = 2400
    private static let photoHeight = 1800

    private func makeInput(url: URL, filename: String) -> CompressionInput {
        CompressionInput(
            id: UUID(),
            originalURL: url,
            workingURL: url,
            originalFilename: filename,
            fileExtension: url.pathExtension,
            detectedTypeIdentifier: nil,
            fileKind: .image,
            originalSizeBytes: FileManager.default.fileSize(at: url),
            createdAt: Date()
        )
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

    /// 1000x1000 PNG whose top-left quadrant is fully transparent. The opaque part
    /// carries per-pixel grain so the PNG stays large and a JPEG of it is
    /// comfortably smaller — otherwise `OutputGuard` would hand the original back
    /// and the test would be measuring the wrong file.
    private func makeFixturePNGWithAlpha(size: Int = 1000) throws -> URL {
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        var seed: UInt64 = 0x2f6e_1a35_c7d9_0b41
        for row in 0..<size {
            for column in 0..<size {
                // Row 0 of a bitmap context's buffer is the TOP row of the image,
                // so this leaves the top-left quadrant fully transparent.
                if row < size / 2, column < size / 2 { continue }
                seed = Self.nextRandom(seed)
                let noise = Double(seed % 1000) / 1000
                let horizontal = Double(column) / Double(size)
                let vertical = Double(row) / Double(size)
                let index = (row * size + column) * 4
                pixels[index] = UInt8(max(0, min(255, 40 + 170 * horizontal + noise * 40)))
                pixels[index + 1] = UInt8(max(0, min(255, 30 + 160 * vertical + noise * 40)))
                pixels[index + 2] = UInt8(max(0, min(255, 70 + 120 * (1 - horizontal) + noise * 40)))
                pixels[index + 3] = 255
            }
        }
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let cgImage: CGImage? = pixels.withUnsafeMutableBytes { buffer in
            CGContext(
                data: buffer.baseAddress,
                width: size,
                height: size,
                bitsPerComponent: 8,
                bytesPerRow: size * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )?.makeImage()
        }
        let image = UIImage(cgImage: try XCTUnwrap(cgImage))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fixture-alpha-\(UUID().uuidString).png")
        try XCTUnwrap(image.pngData()).write(to: url)
        return url
    }

    private func makeFixtureLargePhotoJPEG() throws -> URL {
        let image = makePhotographicImage()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fixture-photo-\(UUID().uuidString).jpg")
        try XCTUnwrap(image.jpegData(compressionQuality: 0.95)).write(to: url)
        return url
    }

    private func makeFixturePhotoWithEXIF() throws -> URL {
        let image = makePhotographicImage()
        let cgImage = try XCTUnwrap(image.cgImage)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fixture-exif-\(UUID().uuidString).jpg")
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        )
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.95,
            kCGImagePropertyOrientation: 1,
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifPixelXDimension: cgImage.width,
                kCGImagePropertyExifPixelYDimension: cgImage.height,
                kCGImagePropertyExifUserComment: "Local File Diet fixture"
            ] as [CFString: Any],
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "Local File Diet",
                kCGImagePropertyTIFFOrientation: 1
            ] as [CFString: Any]
        ]
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    /// Gradient plus grain, which behaves like a photo under a JPEG encoder.
    private func makePhotographicImage() -> UIImage {
        let width = Self.photoWidth
        let height = Self.photoHeight
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        var seed: UInt64 = 0x9e37_79b9_7f4a_7c15
        return renderer.image { context in
            let cell = 10
            for row in 0..<(height / cell) {
                for column in 0..<(width / cell) {
                    seed = Self.nextRandom(seed)
                    let noise = CGFloat(seed % 1000) / 1000
                    let horizontal = CGFloat(column) / CGFloat(width / cell)
                    let vertical = CGFloat(row) / CGFloat(height / cell)
                    UIColor(
                        red: min(1, 0.15 + horizontal * 0.7 + noise * 0.15),
                        green: min(1, 0.12 + vertical * 0.6 + noise * 0.2),
                        blue: min(1, 0.25 + (1 - horizontal) * 0.5 + noise * 0.18),
                        alpha: 1
                    ).setFill()
                    context.fill(CGRect(x: column * cell, y: row * cell, width: cell, height: cell))
                }
            }
        }
    }

    private static func nextRandom(_ seed: UInt64) -> UInt64 {
        var value = seed
        value ^= value << 13
        value ^= value >> 7
        value ^= value << 17
        return value
    }

    // MARK: - Output inspection

    private func loadOutput(_ url: URL) throws -> (image: CGImage, type: UTType, properties: [CFString: Any]) {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let identifier = try XCTUnwrap(CGImageSourceGetType(source) as String?)
        let type = try XCTUnwrap(UTType(identifier))
        let properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return (image, type, properties)
    }

    /// Samples one pixel as straight RGBA, with `y` measured from the top edge.
    private func samplePixel(_ image: CGImage, x: Int, y: Int) throws -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        var pixel = [UInt8](repeating: 0, count: 4)
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        pixel.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return
            }
            context.clear(CGRect(x: 0, y: 0, width: 1, height: 1))
            context.draw(
                image,
                in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height)
            )
        }
        return (pixel[0], pixel[1], pixel[2], pixel[3])
    }
}
