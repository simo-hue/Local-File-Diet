import AVFoundation
import CoreMedia
import CoreVideo
import XCTest
@testable import LocalFileDiet

/// Tapping Cancel during a video compression used to crash the app.
///
/// `TranscodePipeline.cancel()` runs on whichever thread tapped the button — the
/// main actor, in both places the app offers it — and it moved the reader
/// straight to `.cancelled` there and then. If `begin()` had not yet reached
/// `reader.startReading()`, that call arrived at an already-cancelled reader,
/// and AVFoundation answers that by RAISING an Objective-C exception, which
/// Swift cannot catch and no `guard` can see. The window is a few tens of
/// milliseconds wide and it opens twice, once per encode pass, so these tests
/// walk a real encode's cancel across the whole of it.
///
/// A regression here does not fail politely: it takes the test process down.
final class VideoCancellationTests: XCTestCase {
    /// The width and position of the start window track how long AVFoundation
    /// takes to open the reader, which tracks the number of samples in the
    /// source. Measured against the unfixed engine, a 30-second 720p clip puts
    /// pass one's window at 60-120 ms and pass two's at 12-28 ms; a 12-second
    /// clip is small enough that pass two's window closes before a test can aim
    /// at it. Hence 30, not something cheaper.
    private static let fixtureSeconds = 30
    /// Far below anything a clip this noisy can reach, so pass one always
    /// overshoots and the refinement pass always runs.
    private static let targetSizeBytes: Int64 = 200_000

    /// 0 lands before the pipeline exists, 60-130 lands inside `begin()` — which
    /// is where the crash lived — and the last two land well into the sample
    /// pumps.
    private static let cancelDelays: [Int] =
        [0, 1, 2, 5, 10, 20, 40, 55, 60, 70, 80, 90, 100, 110, 120, 130, 150, 200]

    private var scratchURL = FileManager.default.temporaryDirectory
    private var sourceURL = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratchURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoCancellationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratchURL, withIntermediateDirectories: true)
        sourceURL = scratchURL.appendingPathComponent("source.mp4")
        try Self.writeNoisyVideo(to: sourceURL, seconds: Self.fixtureSeconds)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratchURL)
        try super.tearDownWithError()
    }

    // MARK: - 1. The start window, pass one

    @MainActor
    func testCancellingAnywhereInTheStartWindowThrowsCancellationError() async throws {
        for delay in Self.cancelDelays {
            for repetition in 1...2 {
                let outcome = await runAndCancel(afterMilliseconds: delay, duringSecondPass: false)
                XCTAssertEqual(
                    outcome.description,
                    "CancellationError",
                    "cancel \(delay) ms in, repetition \(repetition)"
                )
            }
        }
    }

    // MARK: - 2. The start window, pass two

    /// The refinement pass builds a second reader and a second writer around
    /// 75% progress, which opens the same window all over again. The wait below
    /// keys off 0.75 exactly: that is the fraction pass one reports when it
    /// finishes writing, and it is the fraction pass two reports before its
    /// pipeline starts, so the delay walks across pass two's own start.
    @MainActor
    func testCancellingDuringTheRefinementPassThrowsCancellationError() async throws {
        for delay in [10, 12, 14, 16, 18, 20, 24, 28, 34] {
            let outcome = await runAndCancel(afterMilliseconds: delay, duringSecondPass: true)
            XCTAssertTrue(
                outcome.reachedSecondPass,
                "the refinement pass never ran, so this delay proved nothing"
            )
            XCTAssertEqual(outcome.description, "CancellationError", "cancel \(delay) ms into pass two")
        }
    }

    // MARK: - 3. Cancelling leaves nothing behind

    @MainActor
    func testCancellingLeavesNoPartialFileBehind() async throws {
        for delay in [0, 20, 80, 150] {
            let outcome = await runAndCancel(afterMilliseconds: delay, duringSecondPass: false)
            XCTAssertEqual(outcome.description, "CancellationError", "cancel \(delay) ms in")
            XCTAssertEqual(outcome.leftovers, [], "cancel \(delay) ms in left files behind")
        }
    }

    // MARK: - 4. Cancelling does not block the caller

    /// `cancelWriting()` on a live writer has been measured at anywhere from 8
    /// to 584 ms depending on how much the encoder had buffered. That used to
    /// run on the thread that tapped Cancel — the main thread — so the UI froze
    /// for as long as it took. It now runs on the encode queue, and the delays
    /// below are late enough that the writer really is live.
    @MainActor
    func testCancellingReturnsToTheCallerImmediately() async throws {
        for delay in [200, 400, 700] {
            let outcome = await runAndCancel(afterMilliseconds: delay, duringSecondPass: false)
            XCTAssertLessThan(
                outcome.cancelBlockedSeconds,
                0.05,
                "cancel \(delay) ms in blocked the caller for \(outcome.cancelBlockedSeconds)s"
            )
        }
    }

    // MARK: - 5. The uncancelled path still works

    /// Without this the four tests above would all pass on an engine that threw
    /// `CancellationError` unconditionally.
    @MainActor
    func testAnUncancelledCompressionStillProducesAnOutput() async throws {
        let store = TemporaryFileStore()
        let engine = VideoCompressionEngine(store: store)
        let workBefore = Self.workDirectories()
        var settings = CompressionSettings.balanced
        settings.targetSizeBytes = Self.targetSizeBytes

        let result = try await engine.compress(input: makeInput(), settings: settings) { _ in }

        XCTAssertTrue(FileManager.default.fileExists(atPath: result.outputURL.path))
        XCTAssertGreaterThan(result.compressedSizeBytes, 0)
        XCTAssertEqual(
            Self.workDirectories().subtracting(workBefore).sorted(),
            [],
            "the encode scratch directory was not cleaned up"
        )
        try? FileManager.default.removeItem(at: result.outputURL)
        try await store.clearAll()
    }

    // MARK: - Driving one cancellation

    private struct CancelOutcome {
        /// "CancellationError", "completed", or the description of whatever else
        /// came out — so a failure message says what actually happened.
        let description: String
        let cancelBlockedSeconds: Double
        let reachedSecondPass: Bool
        let leftovers: [String]
    }

    @MainActor
    private func runAndCancel(afterMilliseconds delay: Int, duringSecondPass: Bool) async -> CancelOutcome {
        let store = TemporaryFileStore()
        let outputsBefore = await Self.outputsDirectoryContents(of: store)
        let workBefore = Self.workDirectories()
        let progress = ProgressRecorder()
        let recorder = OutcomeRecorder()
        let input = makeInput()
        var settings = CompressionSettings.balanced
        settings.targetSizeBytes = Self.targetSizeBytes

        let task = Task.detached {
            let engine = VideoCompressionEngine(store: store)
            do {
                _ = try await engine.compress(input: input, settings: settings) { update in
                    progress.record(update.fractionCompleted ?? 0)
                }
                recorder.record("completed")
            } catch is CancellationError {
                recorder.record("CancellationError")
            } catch {
                recorder.record("\(error)")
            }
        }

        var reachedSecondPass = true
        if duringSecondPass {
            reachedSecondPass = await Self.waitForSecondPass(progress: progress, recorder: recorder)
        }
        try? await Task.sleep(for: .milliseconds(delay))

        let cancelStart = Date()
        task.cancel()
        let cancelBlockedSeconds = Date().timeIntervalSince(cancelStart)

        // Polled rather than awaited: a regression that never resumes the
        // continuation has to fail this test, not hang the whole suite.
        let deadline = Date().addingTimeInterval(60)
        while recorder.outcome == nil, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        let description = recorder.outcome ?? "never finished"

        var leftovers = Self.workDirectories().subtracting(workBefore).sorted()
        let outputsAfter = await Self.outputsDirectoryContents(of: store)
        leftovers += outputsAfter.subtracting(outputsBefore).sorted()
        try? await store.clearAll()

        return CancelOutcome(
            description: description,
            cancelBlockedSeconds: cancelBlockedSeconds,
            reachedSecondPass: reachedSecondPass,
            leftovers: leftovers
        )
    }

    /// Waits for the fraction that pass one reports when it finishes writing.
    private static func waitForSecondPass(progress: ProgressRecorder, recorder: OutcomeRecorder) async -> Bool {
        let deadline = Date().addingTimeInterval(60)
        while progress.fraction < 0.7499, recorder.outcome == nil, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        return progress.fraction >= 0.7499 && recorder.outcome == nil
    }

    private func makeInput() -> CompressionInput {
        CompressionInput(
            id: UUID(),
            originalURL: sourceURL,
            workingURL: sourceURL,
            originalFilename: "source.mp4",
            fileExtension: "mp4",
            detectedTypeIdentifier: "public.mpeg-4",
            fileKind: .video,
            originalSizeBytes: FileManager.default.fileSize(at: sourceURL),
            createdAt: Date()
        )
    }

    /// The engine encodes into `Video-<uuid>` under the temporary directory and
    /// removes it on the way out, whichever way it leaves. Compared before and
    /// after rather than expected to be empty: a run that crashed the test
    /// process leaves one behind, and that must not fail the NEXT run.
    private static func workDirectories() -> Set<String> {
        let temporary = FileManager.default.temporaryDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: temporary.path)) ?? []
        return Set(names.filter { $0.hasPrefix("Video-") })
    }

    private static func outputsDirectoryContents(of store: TemporaryFileStore) async -> Set<String> {
        guard let directory = try? await store.outputsDirectory(),
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        return Set(names)
    }

    // MARK: - Fixture

    /// A clip of pure noise, so the encoder has real work to do and the encode
    /// lasts long enough for a cancel to land inside it.
    private static func writeNoisyVideo(to url: URL, seconds: Int) throws {
        let width = 1280, height = 720, frameRate = 30
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 12_000_000]
            ]
        )
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
        )
        guard writer.canAdd(input) else { throw AppError.exportFailed }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? AppError.exportFailed }
        writer.startSession(atSourceTime: .zero)

        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ] as CFDictionary, &pool)
        guard let pool else { throw AppError.exportFailed }

        var seed: UInt64 = 0x2545_F491_4F6C_DD1D
        for frame in 0..<(seconds * frameRate) {
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw AppError.exportFailed }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                let words = CVPixelBufferGetBytesPerRow(buffer) * height / 8
                let pixels = base.assumingMemoryBound(to: UInt64.self)
                for index in 0..<words {
                    seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                    pixels[index] = seed
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            while !input.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.001)
            }
            adaptor.append(
                buffer,
                withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(frameRate))
            )
        }
        input.markAsFinished()

        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        finished.wait()
        guard writer.status == .completed else { throw writer.error ?? AppError.exportFailed }
    }
}

// MARK: - Recorders

/// The engine reports progress from its encode queues, so both recorders are
/// written from one thread and read from another.
private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var highest: Double = 0

    var fraction: Double {
        lock.lock()
        defer { lock.unlock() }
        return highest
    }

    func record(_ value: Double) {
        lock.lock()
        highest = max(highest, value)
        lock.unlock()
    }
}

private final class OutcomeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    var outcome: String? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func record(_ description: String) {
        lock.lock()
        value = description
        lock.unlock()
    }
}
