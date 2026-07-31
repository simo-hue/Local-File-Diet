import Foundation
import XCTest
@testable import LocalFileDiet

@MainActor
final class BatchRunnerTests: XCTestCase {

    // MARK: - Everything works

    func testEveryFileSucceedsAndIsRecorded() async throws {
        let inputs = (0..<3).map { BatchFixtures.input(index: $0, bytes: 1_000_000) }
        let compressor = StubBatchCompressor()
        let history = FakeBatchHistory()
        let runner = BatchRunner(
            inputs: inputs,
            settings: .balanced,
            compressor: compressor,
            history: history
        )

        runner.start()
        try await waitUntil { runner.phase == .finished }

        XCTAssertEqual(runner.outcome.succeeded.count, 3)
        XCTAssertEqual(runner.outcome.failed.count, 0)
        XCTAssertEqual(runner.overallProgress, 1, accuracy: 0.0001)
        XCTAssertEqual(runner.completedCount, 3)
        XCTAssertEqual(history.addedIDs, inputs.map(\.id))
        XCTAssertEqual(compressor.startedIDs, inputs.map(\.id))
        XCTAssertEqual(runner.outcome.totalOriginalBytes, 3_000_000)
        XCTAssertGreaterThan(runner.outcome.totalSavedBytes, 0)
    }

    func testFilesAreCompressedOneAfterAnother() async throws {
        let inputs = (0..<4).map { BatchFixtures.input(index: $0, bytes: 500_000) }
        let compressor = StubBatchCompressor()
        let runner = BatchRunner(inputs: inputs, settings: .balanced, compressor: compressor)

        runner.start()
        try await waitUntil { runner.phase == .finished }

        XCTAssertEqual(compressor.maximumConcurrent, 1, "the batch must never run two engines at once")
        XCTAssertEqual(compressor.startedIDs, inputs.map(\.id), "and must keep the user's order")
    }

    // MARK: - One bad file

    func testOneFailureDoesNotStopTheRest() async throws {
        let inputs = (0..<3).map { BatchFixtures.input(index: $0, bytes: 1_000_000) }
        let compressor = StubBatchCompressor()
        compressor.setBehaviour(.fail(AppError.corruptFile), for: inputs[1].id)
        let history = FakeBatchHistory()
        let runner = BatchRunner(inputs: inputs, settings: .balanced, compressor: compressor, history: history)

        runner.start()
        try await waitUntil { runner.phase == .finished }

        XCTAssertEqual(compressor.startedIDs.count, 3, "the run continues past the failure")
        XCTAssertEqual(runner.outcome.succeeded.map(\.id), [inputs[0].id, inputs[2].id])
        XCTAssertEqual(runner.outcome.failed.map(\.id), [inputs[1].id])
        XCTAssertEqual(
            runner.outcome.failed.first?.failureMessage,
            AppError.corruptFile.errorDescription
        )
        XCTAssertEqual(history.addedIDs, [inputs[0].id, inputs[2].id], "a failure is not history")
    }

    // MARK: - Cancellation

    func testCancellationStopsTheRunAndMarksTheRemainder() async throws {
        let inputs = (0..<4).map { BatchFixtures.input(index: $0, bytes: 1_000_000) }
        let compressor = StubBatchCompressor()
        compressor.setBehaviour(.slow(nanoseconds: 2_000_000_000), for: inputs[1].id)
        let runner = BatchRunner(inputs: inputs, settings: .balanced, compressor: compressor)

        runner.start()
        try await waitUntil { compressor.startedIDs.count == 2 }
        runner.cancel()
        try await waitUntil { runner.phase == .finished }

        XCTAssertEqual(compressor.startedIDs.count, 2, "nothing after the cancelled file is started")
        XCTAssertEqual(runner.outcome.succeeded.map(\.id), [inputs[0].id])
        XCTAssertEqual(
            runner.outcome.cancelled.map(\.id),
            [inputs[1].id, inputs[2].id, inputs[3].id]
        )
        XCTAssertTrue(runner.outcome.failed.isEmpty, "a cancelled file is not a failed file")
    }

    // MARK: - Archive

    func testArchiveNamesAreMadeUnique() {
        let names = BatchArchive.uniqueNames(for: [
            "photo-compressed.jpg",
            "photo-compressed.jpg",
            "scan-compressed.pdf",
            "photo-compressed.jpg"
        ])
        XCTAssertEqual(names, [
            "photo-compressed.jpg",
            "photo-compressed-2.jpg",
            "scan-compressed.pdf",
            "photo-compressed-3.jpg"
        ])
        XCTAssertEqual(Set(names).count, names.count)
    }

    func testArchiveWritesEveryOutputAndReadsBack() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("batch-zip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var entries: [BatchArchive.Entry] = []
        var payloads: [String: Data] = [:]
        for index in 0..<3 {
            let payload = Data(String(repeating: "batch \(index) ", count: 5_000).utf8)
            let url = directory.appendingPathComponent("file-\(index).txt")
            try payload.write(to: url)
            entries.append(BatchArchive.Entry(filename: "file-\(index).txt", url: url))
            payloads["file-\(index).txt"] = payload
        }

        let archiveURL = directory.appendingPathComponent("all.zip")
        let observed = ProgressBox()
        _ = try await BatchArchive.writeOffMainActor(entries: entries, to: archiveURL) { fraction in
            observed.record(fraction)
        }

        let readBack = try SimpleZIPReader.read(url: archiveURL)
        XCTAssertEqual(readBack.count, 3)
        for entry in readBack {
            XCTAssertEqual(entry.data, payloads[entry.name])
        }
        XCTAssertEqual(observed.last, 1, accuracy: 0.0001)
        let archiveSize = FileManager.default.fileSize(at: archiveURL)
        let rawSize = payloads.values.reduce(0) { $0 + Int64($1.count) }
        XCTAssertLessThan(archiveSize, rawSize / 2, "the ZIP writer deflates for real")
    }

    // MARK: - Helpers

    private func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("timed out waiting for the batch to reach the expected state")
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

// MARK: - Fixtures

enum BatchFixtures {
    static func input(index: Int, bytes: Int64) -> CompressionInput {
        let url = URL(fileURLWithPath: "/tmp/local-file-diet-tests/file-\(index).jpg")
        return CompressionInput(
            id: UUID(),
            originalURL: url,
            workingURL: url,
            originalFilename: "file-\(index).jpg",
            fileExtension: "jpg",
            detectedTypeIdentifier: "public.jpeg",
            fileKind: .image,
            originalSizeBytes: bytes,
            createdAt: Date()
        )
    }

    static func result(for input: CompressionInput, compressedBytes: Int64) -> CompressionResult {
        CompressionResult(
            outputURL: URL(fileURLWithPath: "/tmp/local-file-diet-tests/out-\(input.id.uuidString).jpg"),
            outputFilename: OutputFilename.make(original: input.originalFilename, outputExtension: "jpg"),
            originalSizeBytes: input.originalSizeBytes,
            compressedSizeBytes: compressedBytes,
            targetReached: true,
            reductionPercent: CompressionMath.reductionPercent(
                original: input.originalSizeBytes,
                compressed: compressedBytes
            ),
            warnings: [],
            operationsApplied: [.reencode],
            durationSeconds: 0.01
        )
    }
}

/// A compressor that never touches a file, so the runner's sequencing, failure
/// and cancellation behaviour can be tested on its own.
final class StubBatchCompressor: BatchFileCompressing, @unchecked Sendable {
    enum Behaviour: Sendable {
        case succeed
        case fail(AppError)
        /// Sleeps, which means it throws `CancellationError` the moment the run
        /// is cancelled — exactly like the real engines.
        case slow(nanoseconds: UInt64)
    }

    private let lock = NSLock()
    private var behaviours: [UUID: Behaviour] = [:]
    private var started: [UUID] = []
    private var concurrent = 0
    private var peakConcurrent = 0

    func setBehaviour(_ behaviour: Behaviour, for id: UUID) {
        lock.withLock { behaviours[id] = behaviour }
    }

    var startedIDs: [UUID] {
        lock.withLock { started }
    }

    var maximumConcurrent: Int {
        lock.withLock { peakConcurrent }
    }

    /// Synchronous on purpose: `NSLock.lock()` is unavailable from an async
    /// context, so the locking happens inside these instead of inside `compress`.
    private func begin(_ id: UUID) -> Behaviour {
        lock.withLock {
            started.append(id)
            concurrent += 1
            peakConcurrent = max(peakConcurrent, concurrent)
            return behaviours[id] ?? .succeed
        }
    }

    private func end() {
        lock.withLock { concurrent -= 1 }
    }

    func compress(
        input: CompressionInput,
        settings: CompressionSettings,
        progress: @escaping @Sendable (CompressionProgress) -> Void
    ) async throws -> CompressionResult {
        let behaviour = begin(input.id)
        defer { end() }

        progress(CompressionProgress(phase: .encoding, fractionCompleted: 0.5, message: "Encoding"))

        switch behaviour {
        case .succeed:
            break
        case .fail(let error):
            throw error
        case .slow(let nanoseconds):
            try await Task.sleep(nanoseconds: nanoseconds)
        }

        progress(CompressionProgress(phase: .completed, fractionCompleted: 1, message: "Done"))
        return BatchFixtures.result(for: input, compressedBytes: input.originalSizeBytes / 2)
    }
}

/// A `@Sendable` progress callback cannot write to a captured `var`.
final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double = -1

    func record(_ fraction: Double) {
        lock.withLock { value = fraction }
    }

    var last: Double {
        lock.withLock { value }
    }
}

@MainActor
final class FakeBatchHistory: BatchHistoryRecording {
    private(set) var addedIDs: [UUID] = []
    private(set) var results: [CompressionResult] = []

    func add(input: CompressionInput, result: CompressionResult) {
        addedIDs.append(input.id)
        results.append(result)
    }
}
