import Compression
import Darwin
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

    // MARK: - Refusing to unpack more than a phone can take

    /// Asserts the reader turns `url` away, and names the reason it gave.
    private func assertRefuses(
        _ url: URL,
        _ expected: ArchiveRefusal,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try SimpleZIPReader.read(url: url), line: line) { error in
            guard let zipError = error as? ZIPError, case .refused(let refusal) = zipError else {
                return XCTFail("expected ZIPError.refused, got \(error)", line: line)
            }
            XCTAssertEqual(refusal, expected, line: line)
        }
    }

    func testRefusesAnEntryThatUnpacksBeyondThePerEntryCap() throws {
        // A hand-made bomb: a couple of kilobytes claiming to be well over the
        // per-entry cap. The payload is never even looked at - the claim alone
        // has to be enough to stop us, because allocating it is what used to get
        // the app killed by jetsam.
        let declared = SimpleZIPReader.maxEntryUncompressedBytes + 1
        let bombURL = scratchURL.appendingPathComponent("bomb.zip")
        try Self.makeArchive(entries: [
            (name: "zeros.bin",
             method: ZIPFormat.methodDeflate,
             payload: Data(repeating: 0x5A, count: 2048),
             crc: 0,
             uncompressedSize: UInt32(declared))
        ]).write(to: bombURL)

        assertRefuses(
            bombURL,
            .entryTooLarge(declaredBytes: declared, limit: SimpleZIPReader.maxEntryUncompressedBytes)
        )
    }

    func testRefusesAnArchiveWhoseEntriesTogetherExceedTheUnpackBudget() throws {
        // Neither entry is big enough to be refused on its own. Together they
        // are, and that has to be settled from the index rather than noticed
        // part way through.
        let half = SimpleZIPReader.minimumExpansionAllowance * 3 / 4
        let real = Data(count: half)
        let archiveURL = scratchURL.appendingPathComponent("two-halves.zip")
        let archive = Self.makeArchive(entries: [
            (name: "first.bin",
             method: ZIPFormat.methodDeflate,
             payload: Self.deflated(real),
             crc: CRC32.checksum(real),
             uncompressedSize: UInt32(half)),
            (name: "second.bin",
             method: ZIPFormat.methodDeflate,
             payload: Data(repeating: 0x5A, count: 2048),
             crc: 0,
             uncompressedSize: UInt32(half))
        ])
        try archive.write(to: archiveURL)

        assertRefuses(
            archiveURL,
            .unpacksTooLarge(declaredBytes: 2 * half, budget: Self.unpackBudget(forArchiveOf: archive.count))
        )
    }

    /// The budget has to be settled from the central directory before anything
    /// is unpacked, not while the entries go by.
    ///
    /// The first entry's payload is deliberately corrupt. If the reader gets as
    /// far as decoding it, the error says "could not inflate entry" - which is
    /// exactly what it used to say, after having spent the time and the scratch
    /// space. A refusal proves nothing was decoded.
    func testRefusesFromTheIndexBeforeUnpackingAnything() throws {
        let entryBytes = SimpleZIPReader.minimumExpansionAllowance * 3 / 4
        let real = Data(count: entryBytes)
        var corrupt = Self.deflated(real)
        corrupt[corrupt.index(corrupt.startIndex, offsetBy: corrupt.count / 2)] ^= 0xFF

        let archiveURL = scratchURL.appendingPathComponent("corrupt-first.zip")
        let archive = Self.makeArchive(entries: [
            (name: "first.bin",
             method: ZIPFormat.methodDeflate,
             payload: corrupt,
             crc: CRC32.checksum(real),
             uncompressedSize: UInt32(entryBytes)),
            (name: "second.bin",
             method: ZIPFormat.methodDeflate,
             payload: Data(repeating: 0x5A, count: 2048),
             crc: 0,
             uncompressedSize: UInt32(entryBytes))
        ])
        try archive.write(to: archiveURL)

        assertRefuses(
            archiveURL,
            .unpacksTooLarge(declaredBytes: 2 * entryBytes, budget: Self.unpackBudget(forArchiveOf: archive.count))
        )
        // Nothing was unpacked, so nothing spilled to a scratch file either.
        XCTAssertTrue(Self.strayScratchFiles().isEmpty, "left behind \(Self.strayScratchFiles())")
    }

    /// Size caps say nothing about how many pieces the bytes arrive in. An
    /// archive of very many tiny entries clears all three and still costs a
    /// great deal, so the count is bounded too - and refused from the end of
    /// central directory record, before the directory is even walked.
    func testRefusesAnArchiveWithMoreEntriesThanWeWalk() throws {
        let count = SimpleZIPReader.maxEntryCount + 1
        let body = Data("tiny entry payload\n".utf8)
        let packed = Self.deflated(body)
        var specs: [(name: String, method: UInt16, payload: Data, crc: UInt32, uncompressedSize: UInt32)] = []
        specs.reserveCapacity(count)
        // Entry 0 is corrupt on purpose: reaching it would be reported as a
        // damaged stream, so a clean refusal proves the count was checked first.
        specs.append((name: "corrupt.bin",
                      method: ZIPFormat.methodDeflate,
                      payload: Data(repeating: 0x5A, count: 64),
                      crc: 0,
                      uncompressedSize: 4096))
        for index in 1..<count {
            specs.append((name: "e-\(index).txt",
                          method: ZIPFormat.methodDeflate,
                          payload: packed,
                          crc: CRC32.checksum(body),
                          uncompressedSize: UInt32(body.count)))
        }
        let archiveURL = scratchURL.appendingPathComponent("too-many.zip")
        try Self.makeArchive(entries: specs).write(to: archiveURL)

        assertRefuses(archiveURL, .tooManyEntries(count: count, limit: SimpleZIPReader.maxEntryCount))
        XCTAssertTrue(Self.strayScratchFiles().isEmpty, "left behind \(Self.strayScratchFiles())")
    }

    /// And an archive sitting exactly on the bound is still read in full, so the
    /// cap refuses too much rather than merely a lot.
    func testAnArchiveAtTheEntryBoundIsStillRead() throws {
        let count = SimpleZIPReader.maxEntryCount
        let body = Data("tiny entry payload\n".utf8)
        let packed = Self.deflated(body)
        let specs = (0..<count).map { index in
            (name: "e-\(index).txt",
             method: ZIPFormat.methodDeflate,
             payload: packed,
             crc: CRC32.checksum(body),
             uncompressedSize: UInt32(body.count))
        }
        let archiveURL = scratchURL.appendingPathComponent("at-the-bound.zip")
        try Self.makeArchive(entries: specs).write(to: archiveURL)

        let entries = try SimpleZIPReader.read(url: archiveURL)
        XCTAssertEqual(entries.count, count)
        XCTAssertEqual(entries.first?.data, body)
        XCTAssertEqual(entries.last?.data, body)
    }

    /// Directory markers carry no payload, so they must not count against the
    /// budget - only against the entry bound, which they legitimately do.
    func testDirectoryMarkersDoNotCountTowardsTheUnpackBudget() throws {
        let body = Data(String(repeating: "real ", count: 1000).utf8)
        let archiveURL = scratchURL.appendingPathComponent("markers.zip")
        try Self.makeArchive(entries: [
            (name: "folder/", method: ZIPFormat.methodStore, payload: Data(), crc: 0, uncompressedSize: 0),
            (name: "folder/real.txt",
             method: ZIPFormat.methodDeflate,
             payload: Self.deflated(body),
             crc: CRC32.checksum(body),
             uncompressedSize: UInt32(body.count))
        ]).write(to: archiveURL)

        let entries = try SimpleZIPReader.read(url: archiveURL)
        XCTAssertEqual(entries.map(\.name), ["folder/real.txt"])
        XCTAssertEqual(entries.first?.data, body)
    }

    // MARK: - Saying which refusal it was

    func testEachRefusalNamesItsOwnCause() throws {
        let body = Data("hello".utf8)
        let packed = Self.deflated(body)
        func fixture(_ name: String, flags: UInt16, method: UInt16 = ZIPFormat.methodDeflate) throws -> URL {
            let url = scratchURL.appendingPathComponent(name)
            try Self.makeArchive(
                entries: [(name: "notes.txt",
                           method: method,
                           payload: packed,
                           crc: CRC32.checksum(body),
                           uncompressedSize: UInt32(body.count))],
                flags: flags
            ).write(to: url)
            return url
        }

        // Bit 0 is encryption, bit 3 is a trailing data descriptor. The second is
        // what every ZIP written as a stream looks like - `ditto` and Finder both
        // produce them - and it is by far the most common reason a re-pack is
        // skipped, which is why it cannot be described as encryption.
        assertRefuses(try fixture("encrypted.zip", flags: 0x0801), .encrypted)
        assertRefuses(try fixture("descriptor.zip", flags: 0x0808), .dataDescriptor)
        assertRefuses(try fixture("bzip2.zip", flags: 0x0800, method: 12), .method(12))
    }

    func testTheEngineClassifiesWhatItCouldNotRepack() {
        XCTAssertEqual(ArchiveRefusal.from(ZIPError.refused(.dataDescriptor)), .dataDescriptor)
        XCTAssertEqual(ArchiveRefusal.from(ZIPError.refused(.encrypted)), .encrypted)
        XCTAssertEqual(ArchiveRefusal.from(ZIPError.malformed("truncated")), .damaged)
        XCTAssertEqual(ArchiveRefusal.from(ZIPError.unsupported("something")), .unreadable)
        XCTAssertEqual(ArchiveRefusal.from(AppError.exportFailed), .unreadable)
        XCTAssertEqual(ArchiveRefusal.from(CancellationError()), .unreadable)

        // The log line must never carry a filename or any other content.
        XCTAssertEqual(ArchiveRefusal.dataDescriptor.logName, "dataDescriptor")
        XCTAssertEqual(ArchiveRefusal.method(12).logName, "method12")
        XCTAssertEqual(ArchiveRefusal.entryTooLarge(declaredBytes: 9, limit: 8).logName, "entryTooLarge")
        XCTAssertEqual(ArchiveRefusal.tooManyEntries(count: 9, limit: 8).logName, "tooManyEntries")
    }

    /// Runs one archive through the engine and hands the result to `inspect`.
    ///
    /// The store is cleared only after `inspect` returns, because clearing it
    /// deletes the very output the assertions need to read.
    private func withCompressedArchive(
        named name: String,
        bytes: Data,
        inspect: (CompressionResult) throws -> Void
    ) async throws {
        let sourceURL = scratchURL.appendingPathComponent(name)
        try bytes.write(to: sourceURL)
        let store = TemporaryFileStore()
        let engine = ArchiveCompressionEngine(store: store)
        let input = CompressionInput(
            id: UUID(),
            originalURL: sourceURL,
            workingURL: sourceURL,
            originalFilename: name,
            fileExtension: "zip",
            detectedTypeIdentifier: "public.zip-archive",
            fileKind: .archive,
            originalSizeBytes: FileManager.default.fileSize(at: sourceURL),
            createdAt: Date()
        )
        let result = try await engine.compress(input: input, settings: .balanced) { _ in }
        // The writer builds beside its destination, which is the store's outputs
        // directory rather than this test's scratch directory.
        let outputs = try FileManager.default.contentsOfDirectory(
            atPath: result.outputURL.deletingLastPathComponent().path
        )
        XCTAssertTrue(outputs.allSatisfy { !$0.hasSuffix(".part") }, "\(name) left behind \(outputs)")
        do {
            try inspect(result)
        } catch {
            try? await store.clearAll()
            throw error
        }
        try await store.clearAll()
    }

    /// A refused archive that is worth wrapping: big enough and compressible
    /// enough that the wrap really is smaller, so the engine returns a ZIP.
    ///
    /// The payload is STORED, so the archive on disk is as large as its contents
    /// and wrapping it can shrink it. A refused archive of a few hundred bytes
    /// cannot be wrapped smaller and comes back as the kept original instead,
    /// which is a different outcome with a different warning - see
    /// `testEngineKeepsARefusedArchiveThatCannotBeWrappedSmaller`.
    private static func refusableArchive(flags: UInt16, method: UInt16 = ZIPFormat.methodStore) -> Data {
        let body = Data(String(repeating: "refused archive payload ", count: 12_000).utf8)
        return makeArchive(
            entries: [(name: "notes.txt",
                       method: method,
                       payload: body,
                       crc: CRC32.checksum(body),
                       uncompressedSize: UInt32(body.count))],
            flags: flags
        )
    }

    /// Every refusal has to degrade to the same thing: the archive wrapped as it
    /// stands, in a ZIP that really opens, with the original bytes intact.
    ///
    /// Bit 0 is encryption and bit 3 is a trailing data descriptor; method 12 is
    /// bzip2. Each reaches the fallback for its own reason, and all of them have
    /// to come out the other side as a readable ZIP.
    func testEngineWrapsEveryArchiveItRefusesToUnpack() async throws {
        let cases: [(name: String, archive: Data)] = [
            ("engine-bomb.zip", Self.makeArchive(entries: [
                (name: "zeros.bin",
                 method: ZIPFormat.methodDeflate,
                 payload: Data(repeating: 0x5A, count: 2048),
                 crc: 0,
                 uncompressedSize: UInt32(SimpleZIPReader.maxEntryUncompressedBytes + 1))
            ])),
            ("engine-descriptor.zip", Self.refusableArchive(flags: 0x0808)),
            ("engine-encrypted.zip", Self.refusableArchive(flags: 0x0801)),
            ("engine-method.zip", Self.refusableArchive(flags: 0x0800, method: 12)),
            ("engine-damaged.zip", Data(repeating: 0x41, count: 4096))
        ]

        for testCase in cases {
            try await withCompressedArchive(named: testCase.name, bytes: testCase.archive) { result in
                // Every one of these must actually produce a ZIP, so the wrap
                // branch is under test rather than the kept-original branch.
                XCTAssertFalse(
                    result.warnings.contains { $0.id == CompressionWarning.keptOriginal.id },
                    "\(testCase.name) should have been wrapped smaller, not kept"
                )
                XCTAssertTrue(
                    result.warnings.contains { $0.id == CompressionWarning.zipCouldNotRepackID },
                    "\(testCase.name)"
                )
                XCTAssertFalse(
                    result.warnings.contains { $0.id == CompressionWarning.zipRepacked.id },
                    "\(testCase.name)"
                )
                XCTAssertGreaterThan(result.compressedSizeBytes, 0, "\(testCase.name)")
                XCTAssertEqual(result.operationsApplied, [.zip, .verifyOutput], "\(testCase.name)")

                // Wrapped, not re-packed: one entry, the archive itself, unchanged.
                let wrapped = try SimpleZIPReader.read(url: result.outputURL)
                XCTAssertEqual(wrapped.count, 1, "\(testCase.name)")
                XCTAssertEqual(wrapped.first?.name, testCase.name, "\(testCase.name)")
                XCTAssertEqual(wrapped.first?.data, testCase.archive, "\(testCase.name)")
            }
        }

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: scratchURL.path)
        XCTAssertTrue(leftovers.allSatisfy { !$0.hasSuffix(".part") }, "left behind \(leftovers)")
        XCTAssertTrue(Self.strayScratchFiles().isEmpty, "left behind \(Self.strayScratchFiles())")
    }

    /// The other half of the refusal fallback. A refused archive of a couple of
    /// hundred bytes cannot be wrapped into anything smaller, so `OutputGuard`
    /// hands the untouched original back.
    ///
    /// Nothing was wrapped in that case, so the warning that says it was has to
    /// be gone: `zipCouldNotRepack` describes work that was discarded, and
    /// telling the user their archive "was wrapped as-is" next to "Original
    /// kept" is exactly the contradiction `describesDiscardedWork` exists to
    /// prevent.
    func testEngineKeepsARefusedArchiveThatCannotBeWrappedSmaller() async throws {
        let body = Data("hello".utf8)
        let packed = Self.deflated(body)
        let tiny = Self.makeArchive(
            entries: [(name: "notes.txt",
                       method: ZIPFormat.methodDeflate,
                       payload: packed,
                       crc: CRC32.checksum(body),
                       uncompressedSize: UInt32(body.count))],
            flags: 0x0808
        )
        XCTAssertLessThan(tiny.count, 1024, "this fixture only works while it is too small to wrap smaller")

        try await withCompressedArchive(named: "tiny-descriptor.zip", bytes: tiny) { result in
            XCTAssertTrue(result.warnings.contains { $0.id == CompressionWarning.keptOriginal.id })
            XCTAssertFalse(
                result.warnings.contains { $0.id == CompressionWarning.zipCouldNotRepackID },
                "a kept original was never wrapped, so it must not claim it was"
            )
            XCTAssertFalse(result.warnings.contains { $0.id == CompressionWarning.zipRepacked.id })
            let returned = try Data(contentsOf: result.outputURL)
            XCTAssertEqual(returned, tiny)
            XCTAssertEqual(result.compressedSizeBytes, Int64(tiny.count))
        }
    }

    /// An archive with nothing but directory markers has nothing to re-pack, and
    /// that is a refusal like any other rather than a failed compression. It is
    /// also far too small to wrap smaller, so it comes back as the original.
    func testEngineWrapsAnArchiveThatHoldsOnlyFolders() async throws {
        let foldersOnly = Self.makeArchive(entries: [
            (name: "folder/", method: ZIPFormat.methodStore, payload: Data(), crc: 0, uncompressedSize: 0)
        ])
        // The reader drops directory markers, so this archive reads as no files
        // at all - which is what the engine turns into `.noFiles`.
        let insideFolders = try SimpleZIPReader.read(archive: foldersOnly)
        XCTAssertEqual(insideFolders.count, 0)

        try await withCompressedArchive(named: "folders-only.zip", bytes: foldersOnly) { result in
            XCTAssertGreaterThan(result.compressedSizeBytes, 0)
            XCTAssertTrue(result.warnings.contains { $0.id == CompressionWarning.keptOriginal.id })
            XCTAssertFalse(result.warnings.contains { $0.id == CompressionWarning.zipRepacked.id })
            let returned = try Data(contentsOf: result.outputURL)
            XCTAssertEqual(returned, foldersOnly)
        }
    }

    /// A folders-only archive big enough to be worth wrapping takes the other
    /// branch, so `.noFiles` is covered on the wrap path too.
    func testEngineWrapsALargeArchiveThatHoldsOnlyFolders() async throws {
        let markers = (0..<400).map { index in
            (name: "some/reasonably/long/folder/path/number-\(index)/",
             method: ZIPFormat.methodStore,
             payload: Data(),
             crc: UInt32(0),
             uncompressedSize: UInt32(0))
        }
        let foldersOnly = Self.makeArchive(entries: markers)
        let insideFolders = try SimpleZIPReader.read(archive: foldersOnly)
        XCTAssertEqual(insideFolders.count, 0)

        try await withCompressedArchive(named: "many-folders.zip", bytes: foldersOnly) { result in
            XCTAssertFalse(result.warnings.contains { $0.id == CompressionWarning.keptOriginal.id })
            XCTAssertTrue(result.warnings.contains { $0.id == CompressionWarning.zipCouldNotRepackID })
            let wrapped = try SimpleZIPReader.read(url: result.outputURL)
            XCTAssertEqual(wrapped.count, 1)
            XCTAssertEqual(wrapped.first?.data, foldersOnly)
        }
    }

    /// The refusals that only the engine can reach, because they need an archive
    /// too large or too crowded to be worth building twice.
    func testEngineWrapsAnArchiveWithMoreEntriesThanWeWalk() async throws {
        let body = Data("tiny entry payload\n".utf8)
        let packed = Self.deflated(body)
        let specs = (0..<(SimpleZIPReader.maxEntryCount + 1)).map { index in
            (name: "e-\(index).txt",
             method: ZIPFormat.methodDeflate,
             payload: packed,
             crc: CRC32.checksum(body),
             uncompressedSize: UInt32(body.count))
        }
        let crowded = Self.makeArchive(entries: specs)

        try await withCompressedArchive(named: "crowded.zip", bytes: crowded) { result in
            XCTAssertTrue(result.warnings.contains { $0.id == CompressionWarning.zipCouldNotRepackID })
            XCTAssertFalse(result.warnings.contains { $0.id == CompressionWarning.zipRepacked.id })
            let wrapped = try SimpleZIPReader.read(url: result.outputURL)
            XCTAssertEqual(wrapped.count, 1)
            XCTAssertEqual(wrapped.first?.data, crowded)
            XCTAssertTrue(Self.strayScratchFiles().isEmpty, "left behind \(Self.strayScratchFiles())")
        }
    }

    // MARK: - Headers still agree after the streamed write

    func testLocalHeadersAgreeWithTheCentralDirectory() throws {
        var generator = SystemRandomNumberGenerator()
        let entries = [
            ZIPEntrySource(name: "deflated.txt", data: Data(String(repeating: "A", count: 200_000).utf8)),
            ZIPEntrySource(name: "stored.bin", data: Data((0..<80_000).map { _ in UInt8.random(in: 0...255, using: &generator) })),
            ZIPEntrySource(name: "empty.txt", data: Data()),
            ZIPEntrySource(name: "deep/nested/name.txt", data: Data(String(repeating: "banana ", count: 9_000).utf8))
        ]
        let archiveURL = scratchURL.appendingPathComponent("headers.zip")
        try SimpleZIPWriter.write(entries: entries, to: archiveURL)
        let archive = try Data(contentsOf: archiveURL)

        let headers = try Self.centralDirectoryHeaders(in: archive)
        XCTAssertEqual(headers.count, entries.count)
        var sawDeflate = false
        var sawStore = false
        for header in headers {
            // The local header is written twice - once as a placeholder, once for
            // real - so every field the second pass touches has to match.
            XCTAssertEqual(archive.readUInt32(at: header.localOffset), ZIPFormat.localHeaderSignature, "\(header.name)")
            XCTAssertEqual(archive.readUInt16(at: header.localOffset + 6), ZIPFormat.utf8NameFlag, "\(header.name)")
            XCTAssertEqual(archive.readUInt16(at: header.localOffset + 8), header.method, "\(header.name)")
            XCTAssertEqual(archive.readUInt16(at: header.localOffset + 10), header.time, "\(header.name)")
            XCTAssertEqual(archive.readUInt16(at: header.localOffset + 12), header.date, "\(header.name)")
            XCTAssertEqual(archive.readUInt32(at: header.localOffset + 14), header.crc, "\(header.name)")
            XCTAssertEqual(archive.readUInt32(at: header.localOffset + 18), header.compressedSize, "\(header.name)")
            XCTAssertEqual(archive.readUInt32(at: header.localOffset + 22), header.uncompressedSize, "\(header.name)")
            XCTAssertEqual(Int(archive.readUInt16(at: header.localOffset + 26)), header.name.utf8.count, "\(header.name)")
            XCTAssertEqual(archive.readUInt16(at: header.localOffset + 28), 0, "\(header.name)")
            // The DOS date always carries a day and a month, so it is never zero
            // for a real timestamp. The DOS *time* legitimately is zero in the
            // first two seconds after midnight, which is why it is checked
            // against a fixed date in its own test rather than here.
            XCTAssertNotEqual(header.date, 0, "\(header.name) should carry a real DOS date")
            if header.method == ZIPFormat.methodDeflate {
                sawDeflate = true
                XCTAssertLessThan(header.compressedSize, header.uncompressedSize, "\(header.name)")
            } else {
                sawStore = true
                XCTAssertEqual(header.compressedSize, header.uncompressedSize, "\(header.name)")
            }
        }
        XCTAssertTrue(sawDeflate, "the compressible entry should have been deflated")
        XCTAssertTrue(sawStore, "the random entry should have fallen back to store")
    }

    /// The timestamp check the header test cannot make: a fixed modification
    /// date has to come back out of both headers exactly.
    func testDOSTimestampsComeFromTheFileModificationDate() throws {
        var components = DateComponents()
        components.year = 2026
        components.month = 3
        components.day = 4
        components.hour = 13
        components.minute = 45
        components.second = 23
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let modified = try XCTUnwrap(calendar.date(from: components))

        let fileURL = scratchURL.appendingPathComponent("stamped.txt")
        try Data(String(repeating: "stamped ", count: 20_000).utf8).write(to: fileURL)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: fileURL.path)

        let archiveURL = scratchURL.appendingPathComponent("stamped.zip")
        try SimpleZIPWriter.write(files: [fileURL], to: archiveURL)
        let archive = try Data(contentsOf: archiveURL)

        // 13:45:23 -> seconds are stored in two-second units, so 23 becomes 11.
        let expectedTime = UInt16((13 << 11) | (45 << 5) | 11)
        let expectedDate = UInt16(((2026 - 1980) << 9) | (3 << 5) | 4)
        let header = try XCTUnwrap(Self.centralDirectoryHeaders(in: archive).first)
        XCTAssertEqual(header.time, expectedTime)
        XCTAssertEqual(header.date, expectedDate)
        XCTAssertEqual(archive.readUInt16(at: header.localOffset + 10), expectedTime)
        XCTAssertEqual(archive.readUInt16(at: header.localOffset + 12), expectedDate)
        XCTAssertEqual(ZIPFormat.dosDateTime(from: modified).time, expectedTime)
        XCTAssertEqual(ZIPFormat.dosDateTime(from: modified).date, expectedDate)
    }

    /// Why the header test above checks the date and not the time: a DOS time of
    /// zero is a correct answer for midnight, so asserting it is never zero fails
    /// for two seconds a day.
    func testDOSTimeIsLegitimatelyZeroAtMidnight() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 1

        for second in [0, 1] {
            components.hour = 0
            components.minute = 0
            components.second = second
            let midnight = try XCTUnwrap(calendar.date(from: components))
            let stamp = ZIPFormat.dosDateTime(from: midnight)
            XCTAssertEqual(stamp.time, 0, "00:00:0\(second) really is DOS time 0")
            XCTAssertEqual(stamp.date, UInt16(((2026 - 1980) << 9) | (8 << 5) | 1))
        }

        // Two seconds later it is no longer zero, which is the whole window.
        components.second = 2
        let later = try XCTUnwrap(calendar.date(from: components))
        XCTAssertEqual(ZIPFormat.dosDateTime(from: later).time, 1)
    }

    func testCancellingTheWriterLeavesNoHalfWrittenFileBehind() async throws {
        let outputURL = scratchURL.appendingPathComponent("cancelled.zip")
        let entries = (0..<300).map {
            ZIPEntrySource(name: "e-\($0).bin", data: Data(String(repeating: "z", count: 300_000).utf8))
        }
        // Cancel once the writer is demonstrably running, so this covers
        // cancellation part way through rather than before the first byte.
        let (ticks, continuation) = AsyncStream<Double>.makeStream()
        let task = Task.detached {
            defer { continuation.finish() }
            try SimpleZIPWriter.write(entries: entries, to: outputURL) { continuation.yield($0) }
        }
        var iterator = ticks.makeAsyncIterator()
        _ = await iterator.next()
        task.cancel()
        let outcome = await task.result

        // Every assertion is outside the `if case`: if cancellation ever stops
        // throwing, this test has to notice rather than quietly pass.
        switch outcome {
        case .success:
            XCTFail("a cancelled write must throw, not return an archive")
        case .failure(let error):
            XCTAssertTrue(error is CancellationError, "expected CancellationError, got \(error)")
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: outputURL.path),
            "a cancelled write must not leave an archive behind"
        )
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: scratchURL.path)
        XCTAssertTrue(leftovers.allSatisfy { !$0.hasSuffix(".part") }, "left behind \(leftovers)")
    }

    /// The other way out: the write fails part way through. The scratch file has
    /// to go with it, and the destination must be left exactly as it was.
    func testAFailedWriteLeavesNeitherAScratchFileNorADestination() throws {
        let outputURL = scratchURL.appendingPathComponent("doomed.zip")
        // A name longer than a ZIP header can describe: the writer gets as far as
        // creating its scratch file, then gives up on the first entry.
        let entries = [
            ZIPEntrySource(name: "fine.txt", data: Data("fine".utf8)),
            ZIPEntrySource(name: String(repeating: "x", count: Int(UInt16.max) + 1), data: Data("too long".utf8))
        ]

        XCTAssertThrowsError(try SimpleZIPWriter.write(entries: entries, to: outputURL))

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: outputURL.path),
            "a failed write must not leave an archive behind"
        )
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: scratchURL.path)
        XCTAssertTrue(leftovers.allSatisfy { !$0.hasSuffix(".part") }, "left behind \(leftovers)")
    }

    /// The scratch file used to be "<destination>.zip.part", which pushed a
    /// 251-byte destination name past the 255-byte limit and failed a write that
    /// had always worked.
    func testADestinationWithAMaximumLengthNameStillWrites() throws {
        for nameLength in [250, 251, 255] {
            let outputURL = scratchURL
                .appendingPathComponent(String(repeating: "n", count: nameLength - 4) + ".zip")
            XCTAssertEqual(outputURL.lastPathComponent.utf8.count, nameLength)

            let payload = Data(String(repeating: "long name ", count: 5_000).utf8)
            try SimpleZIPWriter.write(entries: [ZIPEntrySource(name: "a.txt", data: payload)], to: outputURL)

            XCTAssertTrue(
                FileManager.default.fileExists(atPath: outputURL.path),
                "a \(nameLength)-byte destination name should still be writable"
            )
            let readBack = try SimpleZIPReader.read(url: outputURL)
            XCTAssertEqual(readBack.first?.data, payload)
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: scratchURL.path)
        XCTAssertTrue(leftovers.allSatisfy { !$0.hasSuffix(".part") }, "left behind \(leftovers)")
    }

    /// An entry that will not deflate used to have its whole deflate stream
    /// written out and then truncated away, so the payload reached the disk
    /// twice. It is now decided before anything is written.
    func testAnIncompressibleEntryIsOnlyWrittenToDiskOnce() throws {
        let entryBytes = 48 * 1024 * 1024
        var generator = SystemRandomNumberGenerator()
        var payload = Data(count: entryBytes)
        payload.withUnsafeMutableBytes { raw in
            guard let base = raw.bindMemory(to: UInt64.self).baseAddress else { return }
            for index in 0..<(entryBytes / 8) {
                base[index] = UInt64.random(in: 0...UInt64.max, using: &generator)
            }
        }
        let archiveURL = scratchURL.appendingPathComponent("write-once.zip")

        let before = Self.diskBytesWritten()
        try XCTSkipIf(before < 0, "this platform does not report per-process disk writes")
        try SimpleZIPWriter.write(entries: [ZIPEntrySource(name: "random.bin", data: payload)], to: archiveURL)
        let written = Self.diskBytesWritten() - before

        // Measured on this fixture: writing the deflate stream out and then
        // truncating it came to 2.00x the entry, deciding first comes to 1.00x.
        XCTAssertLessThan(
            written, Int64(Double(entryBytes) * 1.5),
            "the deflate stream was written out and then thrown away"
        )
        // And it still has to be a correct stored entry.
        let headers = try Self.centralDirectoryHeaders(in: try Data(contentsOf: archiveURL))
        XCTAssertEqual(headers.first?.method, ZIPFormat.methodStore)
        let readBack = try SimpleZIPReader.read(url: archiveURL)
        XCTAssertEqual(readBack.first?.data, payload)
    }

    // MARK: - Memory

    /// The regression test for the two blockers: a file far bigger than anything
    /// the writer used to survive goes in and comes back out without either side
    /// ever holding it. The old writer peaked at three times the input and the
    /// old reader kept every decoded entry in one allocation.
    func testALargeFileSurvivesTheWriterAndReaderWithoutBeingHeldInMemory() throws {
        let megabytes = (SimpleZIPReader.maxDecodedBytesInMemory / (1024 * 1024)) + 8
        let sourceURL = try makeCompressibleFile(named: "big.log", megabytes: megabytes)
        let sourceSize = Int(FileManager.default.fileSize(at: sourceURL))
        let sourceChecksum = CRC32.checksum(try Data(contentsOf: sourceURL, options: [.mappedIfSafe]))
        let budget = 48 * 1024 * 1024
        let archiveURL = scratchURL.appendingPathComponent("big.zip")

        // The progress callback fires throughout the deflate, so it doubles as a
        // sampler for the peak the writer actually reaches.
        let beforeWrite = Self.physFootprintBytes()
        var writePeak = beforeWrite
        try SimpleZIPWriter.write(files: [sourceURL], to: archiveURL) { _ in
            writePeak = max(writePeak, Self.physFootprintBytes())
        }
        XCTAssertLessThan(
            Int(writePeak) - Int(beforeWrite), budget,
            "the writer buffered the archive instead of streaming it"
        )

        let beforeRead = Self.physFootprintBytes()
        let entries = try SimpleZIPReader.read(url: archiveURL)
        let afterRead = Self.physFootprintBytes()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.name, "big.log")
        XCTAssertEqual(entries.first?.data.count, sourceSize)
        XCTAssertEqual(CRC32.checksum(entries.first?.data ?? Data()), sourceChecksum)
        XCTAssertLessThan(
            Int(afterRead) - Int(beforeRead), budget,
            "the reader kept the decoded entry in memory instead of spilling it"
        )

        // Entries too big for memory go through a scratch file; none may survive.
        let temporaryDirectory = FileManager.default.temporaryDirectory
        let strays = (try? FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path)) ?? []
        XCTAssertTrue(strays.allSatisfy { !$0.hasPrefix("zip-unpack-") }, "left behind \(strays)")
    }

    // MARK: - Helpers

    private func makeCompressibleFile(named name: String, megabytes: Int) throws -> URL {
        let url = scratchURL.appendingPathComponent(name)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw AppError.exportFailed
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var block = Data()
        var line = 0
        while block.count < 1024 * 1024 {
            block.append(Data("2026-07-31 line \(line) of log output for the archive memory test\n".utf8))
            line += 1
        }
        for _ in 0..<megabytes {
            try handle.write(contentsOf: block)
        }
        return url
    }

    /// `phys_footprint` is the number jetsam kills on, so it is the number these
    /// tests watch.
    private static func physFootprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let outcome = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        return outcome == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
    }

    /// Raw DEFLATE, so a fixture can carry a payload that really does unpack to
    /// the size its header claims.
    private static func deflated(_ data: Data) -> Data {
        var output = Data(count: max(1024, data.count / 2))
        let capacity = output.count
        let written: Int = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress,
                      let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else {
                    return 0
                }
                return compression_encode_buffer(destinationBase, capacity, sourceBase, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        return Data(output.prefix(written))
    }

    private struct CentralHeader {
        let name: String
        let method: UInt16
        let time: UInt16
        let date: UInt16
        let crc: UInt32
        let compressedSize: UInt32
        let uncompressedSize: UInt32
        let localOffset: Int
    }

    private static func centralDirectoryHeaders(in archive: Data) throws -> [CentralHeader] {
        let end = archive.count - ZIPFormat.endOfCentralDirectoryLength
        XCTAssertEqual(archive.readUInt32(at: end), ZIPFormat.endOfCentralDirectorySignature)
        let total = Int(archive.readUInt16(at: end + 10))
        var cursor = Int(archive.readUInt32(at: end + 16))
        var headers: [CentralHeader] = []
        for _ in 0..<total {
            XCTAssertEqual(archive.readUInt32(at: cursor), ZIPFormat.centralHeaderSignature)
            let nameLength = Int(archive.readUInt16(at: cursor + 28))
            let extraLength = Int(archive.readUInt16(at: cursor + 30))
            let commentLength = Int(archive.readUInt16(at: cursor + 32))
            let nameStart = archive.startIndex + cursor + ZIPFormat.centralHeaderLength
            headers.append(CentralHeader(
                name: String(decoding: archive[nameStart..<(nameStart + nameLength)], as: UTF8.self),
                method: archive.readUInt16(at: cursor + 10),
                time: archive.readUInt16(at: cursor + 12),
                date: archive.readUInt16(at: cursor + 14),
                crc: archive.readUInt32(at: cursor + 16),
                compressedSize: archive.readUInt32(at: cursor + 20),
                uncompressedSize: archive.readUInt32(at: cursor + 24),
                localOffset: Int(archive.readUInt32(at: cursor + 42))
            ))
            cursor += ZIPFormat.centralHeaderLength + nameLength + extraLength + commentLength
        }
        return headers
    }

    /// The budget the reader works out for an archive of a given size, so a test
    /// can name the number it expects to be refused against.
    private static func unpackBudget(forArchiveOf byteCount: Int) -> Int {
        min(
            SimpleZIPReader.maxTotalUncompressedBytes,
            max(SimpleZIPReader.minimumExpansionAllowance, byteCount * SimpleZIPReader.maxExpansionRatio)
        )
    }

    /// Entries too big for memory go through a scratch file in the temporary
    /// directory; none may survive, and a refusal must not create one at all.
    private static func strayScratchFiles() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(
            atPath: FileManager.default.temporaryDirectory.path
        )) ?? []
        return names.filter { $0.hasPrefix("zip-unpack-") }
    }

    /// Bytes this process has written to disk. `phys_footprint` answers "was it
    /// held in memory"; this answers "was it written out twice".
    private static func diskBytesWritten() -> Int64 {
#if os(macOS)
        var info = rusage_info_v4()
        let outcome = withUnsafeMutablePointer(to: &info) { pointer -> Int32 in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, rebound)
            }
        }
        return outcome == 0 ? Int64(info.ri_diskio_byteswritten) : -1
#else
        return -1
#endif
    }

    /// Builds a ZIP byte for byte, so a fixture can claim whatever it likes about
    /// its own contents. `flags` goes into both the local and the central header,
    /// which is how a fixture says "encrypted" or "written with a data
    /// descriptor" without having to be either.
    private static func makeArchive(
        entries: [(name: String, method: UInt16, payload: Data, crc: UInt32, uncompressedSize: UInt32)],
        flags: UInt16 = 0x0800
    ) -> Data {
        var archive = Data()
        var centralDirectory = Data()
        for entry in entries {
            let nameData = Data(entry.name.utf8)
            let offset = UInt32(archive.count)
            var local = Data()
            local.testAppendUInt32LE(0x04034b50)
            local.testAppendUInt16LE(20)
            local.testAppendUInt16LE(flags)
            local.testAppendUInt16LE(entry.method)
            local.testAppendUInt16LE(0)
            local.testAppendUInt16LE(33)
            local.testAppendUInt32LE(entry.crc)
            local.testAppendUInt32LE(UInt32(entry.payload.count))
            local.testAppendUInt32LE(entry.uncompressedSize)
            local.testAppendUInt16LE(UInt16(nameData.count))
            local.testAppendUInt16LE(0)
            local.append(nameData)
            archive.append(local)
            archive.append(entry.payload)

            var central = Data()
            central.testAppendUInt32LE(0x02014b50)
            central.testAppendUInt16LE(20)
            central.testAppendUInt16LE(20)
            central.testAppendUInt16LE(flags)
            central.testAppendUInt16LE(entry.method)
            central.testAppendUInt16LE(0)
            central.testAppendUInt16LE(33)
            central.testAppendUInt32LE(entry.crc)
            central.testAppendUInt32LE(UInt32(entry.payload.count))
            central.testAppendUInt32LE(entry.uncompressedSize)
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
    func readUInt16(at offset: Int) -> UInt16 {
        let start = startIndex + offset
        return UInt16(self[start]) | (UInt16(self[start + 1]) << 8)
    }

    func readUInt32(at offset: Int) -> UInt32 {
        let start = startIndex + offset
        return UInt32(self[start])
            | (UInt32(self[start + 1]) << 8)
            | (UInt32(self[start + 2]) << 16)
            | (UInt32(self[start + 3]) << 24)
    }

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
