import Foundation
import XCTest
@testable import LocalFileDiet

final class ArchiveCompressionEngineTests: XCTestCase {
    private var scratchURL: URL!

    override func setUpWithError() throws {
        scratchURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("zip-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratchURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratchURL)
        scratchURL = nil
    }

    // MARK: - Round trip

    func testWriteThenReadRoundTripsEveryEntryByteForByte() throws {
        let entries = [
            ZIPEntrySource(name: "first.txt", data: Data(String(repeating: "A", count: 200_000).utf8)),
            ZIPEntrySource(name: "second.txt", data: Data(String(repeating: "banana ", count: 20_000).utf8)),
            ZIPEntrySource(name: "nested/deep/third.txt", data: Data(String(repeating: "C", count: 50_000).utf8))
        ]
        let archiveURL = scratchURL.appendingPathComponent("roundtrip.zip")

        try SimpleZIPWriter.write(entries: entries, to: archiveURL)
        let readBack = try SimpleZIPReader.read(url: archiveURL)

        XCTAssertEqual(readBack.count, entries.count)
        for (expected, actual) in zip(entries, readBack) {
            XCTAssertEqual(actual.name, expected.name)
            XCTAssertEqual(actual.data, expected.data)
        }
    }

    func testFileBasedAPIRoundTrips() throws {
        let payload = Data(String(repeating: "round trip ", count: 20_000).utf8)
        let fileURL = scratchURL.appendingPathComponent("payload.txt")
        try payload.write(to: fileURL)
        let archiveURL = scratchURL.appendingPathComponent("files.zip")

        try SimpleZIPWriter.write(files: [fileURL], to: archiveURL)
        let readBack = try SimpleZIPReader.read(url: archiveURL)

        XCTAssertEqual(readBack.count, 1)
        XCTAssertEqual(readBack.first?.name, "payload.txt")
        XCTAssertEqual(readBack.first?.data, payload)
    }

    // MARK: - Actually compressing

    func testCompressibleContentProducesArchiveMuchSmallerThanTheRawBytes() throws {
        let entries = (0..<3).map { index in
            ZIPEntrySource(
                name: "entry-\(index).txt",
                data: Data(String(repeating: "A", count: 200_000).utf8)
            )
        }
        let rawTotal = entries.reduce(0) { $0 + $1.data.count }
        let archiveURL = scratchURL.appendingPathComponent("compressible.zip")

        try SimpleZIPWriter.write(entries: entries, to: archiveURL)

        let archiveSize = Int(FileManager.default.fileSize(at: archiveURL))
        XCTAssertGreaterThan(archiveSize, 0)
        XCTAssertLessThan(archiveSize, rawTotal / 2)
    }

    func testIncompressibleContentFallsBackToStoreWithMinimalOverhead() throws {
        var generator = SystemRandomNumberGenerator()
        let random = Data((0..<120_000).map { _ in UInt8.random(in: 0...255, using: &generator) })
        let archiveURL = scratchURL.appendingPathComponent("random.zip")

        try SimpleZIPWriter.write(entries: [ZIPEntrySource(name: "random.bin", data: random)], to: archiveURL)

        let archiveSize = Int(FileManager.default.fileSize(at: archiveURL))
        let readBack = try SimpleZIPReader.read(url: archiveURL)
        XCTAssertLessThanOrEqual(archiveSize, random.count + 512)
        XCTAssertEqual(readBack.first?.data, random)
    }

    func testRepackingAStoredArchiveProducesASmallerFile() throws {
        let entries = [
            ZIPEntrySource(name: "notes.txt", data: Data(String(repeating: "stored payload ", count: 15_000).utf8)),
            ZIPEntrySource(name: "more.txt", data: Data(String(repeating: "B", count: 120_000).utf8))
        ]
        let storedURL = scratchURL.appendingPathComponent("stored.zip")
        try Self.makeStoredArchive(entries: entries).write(to: storedURL)
        let storedSize = FileManager.default.fileSize(at: storedURL)

        let readBack = try SimpleZIPReader.read(url: storedURL)
        XCTAssertEqual(readBack.map(\.name), entries.map(\.name))
        XCTAssertEqual(readBack.map(\.data), entries.map(\.data))

        let repackedURL = scratchURL.appendingPathComponent("repacked.zip")
        try SimpleZIPWriter.write(entries: readBack, to: repackedURL)
        let repackedSize = FileManager.default.fileSize(at: repackedURL)
        let repackedEntries = try SimpleZIPReader.read(url: repackedURL)

        XCTAssertLessThan(repackedSize, storedSize)
        XCTAssertEqual(repackedEntries.map(\.data), entries.map(\.data))
    }

    func testWriterReportsProgressPerEntry() throws {
        let entries = (0..<4).map { ZIPEntrySource(name: "e-\($0).txt", data: Data("payload".utf8)) }
        let archiveURL = scratchURL.appendingPathComponent("progress.zip")
        var ticks: [Double] = []

        try SimpleZIPWriter.write(entries: entries, to: archiveURL) { ticks.append($0) }

        XCTAssertGreaterThanOrEqual(ticks.count, entries.count)
        XCTAssertEqual(ticks.last, 1)
        XCTAssertEqual(ticks, ticks.sorted())
    }

    // MARK: - Entry name hygiene

    func testEntryNamesAreNormalisedWhenWriting() throws {
        let entries = [
            ZIPEntrySource(name: "/leading/slash.txt", data: Data("one".utf8)),
            ZIPEntrySource(name: "../../escape.txt", data: Data("two".utf8)),
            ZIPEntrySource(name: "a/../b/./c.txt", data: Data("three".utf8))
        ]
        let archiveURL = scratchURL.appendingPathComponent("names.zip")

        try SimpleZIPWriter.write(entries: entries, to: archiveURL)
        let readBack = try SimpleZIPReader.read(url: archiveURL)

        XCTAssertEqual(readBack.map(\.name), ["leading/slash.txt", "escape.txt", "a/b/c.txt"])
        XCTAssertEqual(readBack.map(\.data), entries.map(\.data))
    }

    // MARK: - Failure handling

    func testReadingGarbageThrowsZIPError() throws {
        let garbageURL = scratchURL.appendingPathComponent("garbage.zip")
        try Data(repeating: 0x41, count: 4096).write(to: garbageURL)

        XCTAssertThrowsError(try SimpleZIPReader.read(url: garbageURL)) { error in
            XCTAssertTrue(error is ZIPError, "expected ZIPError, got \(error)")
        }
    }

    func testReadingTruncatedArchiveThrowsZIPError() throws {
        let archiveURL = scratchURL.appendingPathComponent("full.zip")
        try SimpleZIPWriter.write(
            entries: [ZIPEntrySource(name: "payload.txt", data: Data(String(repeating: "D", count: 40_000).utf8))],
            to: archiveURL
        )
        // Cutting the archive in half removes the end of central directory record.
        let full = try Data(contentsOf: archiveURL)
        let truncatedURL = scratchURL.appendingPathComponent("truncated.zip")
        try Data(full.prefix(full.count / 2)).write(to: truncatedURL)

        XCTAssertThrowsError(try SimpleZIPReader.read(url: truncatedURL)) { error in
            XCTAssertTrue(error is ZIPError, "expected ZIPError, got \(error)")
        }
    }

    func testReadingTooSmallFileThrowsZIPError() throws {
        let tinyURL = scratchURL.appendingPathComponent("tiny.zip")
        try Data([0x50, 0x4B]).write(to: tinyURL)

        XCTAssertThrowsError(try SimpleZIPReader.read(url: tinyURL)) { error in
            XCTAssertTrue(error is ZIPError, "expected ZIPError, got \(error)")
        }
    }

    // MARK: - Engine

    func testEngineRepacksAStoredArchiveIntoASmallerOne() async throws {
        let entries = [
            ZIPEntrySource(name: "report.txt", data: Data(String(repeating: "engine payload ", count: 20_000).utf8))
        ]
        let storedURL = scratchURL.appendingPathComponent("engine-stored.zip")
        try Self.makeStoredArchive(entries: entries).write(to: storedURL)
        let originalSize = FileManager.default.fileSize(at: storedURL)

        let store = TemporaryFileStore()
        let engine = ArchiveCompressionEngine(store: store)
        let input = CompressionInput(
            id: UUID(),
            originalURL: storedURL,
            workingURL: storedURL,
            originalFilename: "engine-stored.zip",
            fileExtension: "zip",
            detectedTypeIdentifier: "public.zip-archive",
            fileKind: .archive,
            originalSizeBytes: originalSize,
            createdAt: Date()
        )

        let result = try await engine.compress(input: input, settings: .balanced) { _ in }
        let repackedEntries = try SimpleZIPReader.read(url: result.outputURL)

        XCTAssertLessThan(result.compressedSizeBytes, originalSize)
        XCTAssertGreaterThan(result.reductionPercent, 0)
        XCTAssertFalse(result.warnings.contains { $0.id == CompressionWarning.keptOriginal.id })
        XCTAssertEqual(repackedEntries.map(\.data), entries.map(\.data))
        try await store.clearAll()
    }

    func testEngineKeepsTheOriginalWhenZippingCannotHelp() async throws {
        var generator = SystemRandomNumberGenerator()
        let random = Data((0..<80_000).map { _ in UInt8.random(in: 0...255, using: &generator) })
        let sourceURL = scratchURL.appendingPathComponent("photo.jpg")
        try random.write(to: sourceURL)
        let originalSize = FileManager.default.fileSize(at: sourceURL)

        let store = TemporaryFileStore()
        let engine = ArchiveCompressionEngine(store: store)
        let input = CompressionInput(
            id: UUID(),
            originalURL: sourceURL,
            workingURL: sourceURL,
            originalFilename: "photo.jpg",
            fileExtension: "jpg",
            detectedTypeIdentifier: "public.jpeg",
            fileKind: .image,
            originalSizeBytes: originalSize,
            createdAt: Date()
        )

        let result = try await engine.compress(input: input, settings: .balanced) { _ in }
        let outputData = try Data(contentsOf: result.outputURL)

        XCTAssertEqual(result.compressedSizeBytes, originalSize)
        XCTAssertEqual(result.reductionPercent, 0)
        XCTAssertEqual(result.outputURL.pathExtension, "jpg")
        XCTAssertTrue(result.warnings.contains { $0.id == CompressionWarning.keptOriginal.id })
        XCTAssertEqual(outputData, random)
        try await store.clearAll()
    }

    // MARK: - Helpers

    /// Builds a valid ZIP where every entry uses method 0 (STORE), i.e. what the
    /// old writer produced and what `zip -0` produces.
    private static func makeStoredArchive(entries: [ZIPEntrySource]) -> Data {
        var archive = Data()
        var centralDirectory = Data()

        for entry in entries {
            let nameData = Data(entry.name.utf8)
            let crc = CRC32.checksum(entry.data)
            let size = UInt32(entry.data.count)
            let offset = UInt32(archive.count)

            var local = Data()
            local.testAppendUInt32LE(0x04034b50)
            local.testAppendUInt16LE(20)
            local.testAppendUInt16LE(0x0800)
            local.testAppendUInt16LE(0) // stored
            local.testAppendUInt16LE(0)
            local.testAppendUInt16LE(33)
            local.testAppendUInt32LE(crc)
            local.testAppendUInt32LE(size)
            local.testAppendUInt32LE(size)
            local.testAppendUInt16LE(UInt16(nameData.count))
            local.testAppendUInt16LE(0)
            local.append(nameData)
            archive.append(local)
            archive.append(entry.data)

            var central = Data()
            central.testAppendUInt32LE(0x02014b50)
            central.testAppendUInt16LE(20)
            central.testAppendUInt16LE(20)
            central.testAppendUInt16LE(0x0800)
            central.testAppendUInt16LE(0) // stored
            central.testAppendUInt16LE(0)
            central.testAppendUInt16LE(33)
            central.testAppendUInt32LE(crc)
            central.testAppendUInt32LE(size)
            central.testAppendUInt32LE(size)
            central.testAppendUInt16LE(UInt16(nameData.count))
            central.testAppendUInt16LE(0)
            central.testAppendUInt16LE(0)
            central.testAppendUInt16LE(0)
            central.testAppendUInt16LE(0)
            central.testAppendUInt32LE(0)
            central.testAppendUInt32LE(offset)
            central.append(nameData)
            centralDirectory.append(central)
        }

        let centralDirectoryOffset = UInt32(archive.count)
        archive.append(centralDirectory)
        archive.testAppendUInt32LE(0x06054b50)
        archive.testAppendUInt16LE(0)
        archive.testAppendUInt16LE(0)
        archive.testAppendUInt16LE(UInt16(entries.count))
        archive.testAppendUInt16LE(UInt16(entries.count))
        archive.testAppendUInt32LE(UInt32(centralDirectory.count))
        archive.testAppendUInt32LE(centralDirectoryOffset)
        archive.testAppendUInt16LE(0)
        return archive
    }
}

private extension Data {
    mutating func testAppendUInt16LE(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func testAppendUInt32LE(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}
