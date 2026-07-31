import AVFoundation
import PDFKit
import XCTest
@testable import LocalFileDiet

final class CoreUtilityTests: XCTestCase {
    func testTargetSizeParsing() {
        XCTAssertEqual(TargetSizeParser.parse("2.5", unit: .mb), 2_500_000)
        XCTAssertEqual(TargetSizeParser.parse("800", unit: .kb), 800_000)
        XCTAssertNil(TargetSizeParser.parse("abc", unit: .mb))
    }

    func testByteFormattingProducesValue() {
        XCTAssertFalse(FileSizeFormat.string(from: 1_500_000).isEmpty)
    }

    func testQualityModeRangesAreOrdered() {
        for mode in QualityMode.allCases {
            XCTAssertLessThan(mode.compressionQualityRange.lowerBound, mode.compressionQualityRange.upperBound)
        }
    }

    func testOutputFilenameGeneration() {
        XCTAssertEqual(OutputFilename.make(original: "scan.pdf", outputExtension: "jpg"), "scan-compressed.jpg")
    }

    func testVideoBitrateEstimate() {
        let bitrate = VideoBitratePlanner.targetBitrateBitsPerSecond(targetSizeBytes: 10_000_000, durationSeconds: 20)
        XCTAssertGreaterThan(bitrate, 3_000_000)
    }

    /// The fallback exists for files the reader/writer pipeline cannot handle
    /// (protected content, exotic source codecs). When it fires the size stops
    /// being aimed, so the user has to be told — and told in plain language,
    /// not as a blocking error.
    func testVideoPresetFallbackWarningExplainsTheApproximateSize() {
        let warning = CompressionWarning.videoPresetFallback
        XCTAssertEqual(warning.id, "videoPresetFallback")
        XCTAssertEqual(warning.severity, .caution)
        XCTAssertTrue(warning.message.lowercased().contains("preset"))
        XCTAssertTrue(warning.message.lowercased().contains("approximate"))
        // It must not be phrased as a failure: a file was still produced.
        XCTAssertNotEqual(warning.severity, .blocking)
    }

    /// The review screen shows this before anything is encoded, so it has to
    /// name the frame size and codec the engine actually intends to use.
    func testVideoOutputPlanWarningNamesTheResolutionAndCodec() {
        let warning = CompressionWarning.videoOutputPlan(width: 1280, height: 720, codec: "H.264")
        XCTAssertEqual(warning.id, "videoOutputPlan")
        XCTAssertEqual(warning.severity, .info)
        XCTAssertTrue(warning.title.contains("1280x720"))
        XCTAssertTrue(warning.message.contains("H.264"))
    }

    /// Orientation is the classic hand-rolled-pipeline bug: the decoded frames
    /// stay in natural (landscape) coordinates and the rotation lives in the
    /// track transform, so what the user sees is the transformed size.
    func testVideoDisplaySizeAppliesTheTrackRotation() {
        let upright = VideoCompressionEngine.displaySize(width: 1280, height: 720, transform: .identity)
        XCTAssertEqual(upright.width, 1280)
        XCTAssertEqual(upright.height, 720)

        let rotated = VideoCompressionEngine.displaySize(
            width: 1280,
            height: 720,
            transform: CGAffineTransform(rotationAngle: .pi / 2)
        )
        XCTAssertEqual(rotated.width, 720)
        XCTAssertEqual(rotated.height, 1280)
    }

    /// The encoder settings are where the whole rewrite pays off: a real
    /// average bitrate, a real frame size, and a keyframe every two seconds.
    func testVideoWriterSettingsCarryThePlannedBitrateAndSize() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("settings-probe-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        let plan = VideoEncodingPlanner.plan(
            source: VideoSourceFacts(
                width: 1920,
                height: 1080,
                frameRate: 30,
                durationSeconds: 60,
                videoBitrate: 8_000_000,
                hasAudio: true
            ),
            targetBytes: 10_000_000,
            mode: .balanced,
            resolutionPreset: .p720,
            preferModernFormat: false
        )
        let settings = VideoCompressionEngine.videoOutputSettings(plan: plan, writer: writer)

        XCTAssertEqual(settings[AVVideoWidthKey] as? Int, 1280)
        XCTAssertEqual(settings[AVVideoHeightKey] as? Int, 720)
        XCTAssertEqual(settings[AVVideoCodecKey] as? AVVideoCodecType, .h264)
        let compression = try XCTUnwrap(settings[AVVideoCompressionPropertiesKey] as? [String: Any])
        XCTAssertEqual(compression[AVVideoAverageBitRateKey] as? Int, Int(plan.videoBitrate.rounded()))
        XCTAssertEqual(compression[AVVideoMaxKeyFrameIntervalKey] as? Int, 60)
        writer.cancelWriting()
    }

    func testProgressPresentationDoesNotMoveBackwards() {
        let current = CompressionProgress(
            phase: .encoding,
            fractionCompleted: 0.72,
            message: "Encoding"
        )
        let next = CompressionProgress(
            phase: .optimizing,
            fractionCompleted: 0.38,
            message: "Trying a better pass"
        )

        let smoothed = ProgressPresentation.smoothed(current: current, next: next)

        XCTAssertEqual(smoothed.fractionCompleted, 0.72)
        XCTAssertEqual(smoothed.phase, .optimizing)
        XCTAssertEqual(smoothed.message, "Trying a better pass")
    }

    func testOutputGuardKeepsOriginalWhenCandidateIsBigger() async throws {
        let context = try OutputGuardContext(
            originalFilename: "holiday.png",
            originalBytes: 5_000,
            candidateExtension: "jpg",
            candidateBytes: 9_000
        )
        defer { context.cleanUp() }

        let resolved = try await OutputGuard.resolve(
            candidateURL: context.candidateURL,
            input: context.input,
            store: context.store,
            fileManager: .default
        )

        let keptData = try Data(contentsOf: resolved.url)
        XCTAssertTrue(resolved.keptOriginal)
        XCTAssertEqual(resolved.url.pathExtension, "png")
        XCTAssertEqual(keptData, context.originalData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.candidateURL.path))
        try await context.store.clearAll()
    }

    func testOutputGuardKeepsOriginalWhenCandidateIsExactlyTheSameSize() async throws {
        let context = try OutputGuardContext(
            originalFilename: "holiday.png",
            originalBytes: 4_096,
            candidateExtension: "jpg",
            candidateBytes: 4_096
        )
        defer { context.cleanUp() }

        let resolved = try await OutputGuard.resolve(
            candidateURL: context.candidateURL,
            input: context.input,
            store: context.store,
            fileManager: .default
        )

        XCTAssertTrue(resolved.keptOriginal)
        XCTAssertEqual(resolved.url.pathExtension, "png")
        try await context.store.clearAll()
    }

    func testOutputGuardKeepsCandidateWhenItIsSmaller() async throws {
        let context = try OutputGuardContext(
            originalFilename: "holiday.png",
            originalBytes: 9_000,
            candidateExtension: "jpg",
            candidateBytes: 5_000
        )
        defer { context.cleanUp() }

        let resolved = try await OutputGuard.resolve(
            candidateURL: context.candidateURL,
            input: context.input,
            store: context.store,
            fileManager: .default
        )

        XCTAssertFalse(resolved.keptOriginal)
        XCTAssertEqual(resolved.url, context.candidateURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: context.candidateURL.path))
    }

    func testOutputGuardThrowsWhenCandidateIsEmpty() async throws {
        let context = try OutputGuardContext(
            originalFilename: "holiday.png",
            originalBytes: 9_000,
            candidateExtension: "jpg",
            candidateBytes: 0
        )
        defer { context.cleanUp() }

        do {
            _ = try await OutputGuard.resolve(
                candidateURL: context.candidateURL,
                input: context.input,
                store: context.store,
                fileManager: .default
            )
            XCTFail("expected an export failure for an empty candidate")
        } catch {
            XCTAssertEqual(error as? AppError, .exportFailed)
        }
    }

    func testOutputGuardThrowsWhenCandidateIsMissing() async throws {
        let context = try OutputGuardContext(
            originalFilename: "holiday.png",
            originalBytes: 9_000,
            candidateExtension: "jpg",
            candidateBytes: nil
        )
        defer { context.cleanUp() }

        do {
            _ = try await OutputGuard.resolve(
                candidateURL: context.candidateURL,
                input: context.input,
                store: context.store,
                fileManager: .default
            )
            XCTFail("expected an export failure for a missing candidate")
        } catch {
            XCTAssertEqual(error as? AppError, .exportFailed)
        }
    }

    func testOutputGuardDropsUnrealisticTargetWarningOnlyWhenTheOriginalMeetsIt() {
        let warnings: [CompressionWarning] = [.alreadyOptimized, .targetMayBeUnrealistic]

        let meetingTarget = OutputGuard.warningsAfterKeepingOriginal(warnings, finalSize: 1_000, target: 2_000)
        XCTAssertFalse(meetingTarget.contains { $0.id == CompressionWarning.targetMayBeUnrealistic.id })
        XCTAssertTrue(meetingTarget.contains { $0.id == CompressionWarning.keptOriginal.id })

        let missingTarget = OutputGuard.warningsAfterKeepingOriginal(warnings, finalSize: 3_000, target: 2_000)
        XCTAssertTrue(missingTarget.contains { $0.id == CompressionWarning.targetMayBeUnrealistic.id })
        XCTAssertTrue(missingTarget.contains { $0.id == CompressionWarning.keptOriginal.id })
    }
}

/// Fixture for the `OutputGuard` tests: an original file on disk, a candidate
/// output next to it, and a matching `CompressionInput`.
private struct OutputGuardContext {
    let directoryURL: URL
    let workingURL: URL
    let candidateURL: URL
    let originalData: Data
    let input: CompressionInput
    let store: TemporaryFileStore

    /// A nil `candidateBytes` means the candidate file is never created.
    init(originalFilename: String, originalBytes: Int, candidateExtension: String, candidateBytes: Int?) throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("output-guard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        originalData = Data(repeating: 0x2A, count: originalBytes)
        workingURL = directoryURL.appendingPathComponent(originalFilename)
        try originalData.write(to: workingURL)

        candidateURL = directoryURL.appendingPathComponent("candidate.\(candidateExtension)")
        if let candidateBytes {
            try Data(repeating: 0x5B, count: candidateBytes).write(to: candidateURL)
        }

        store = TemporaryFileStore()
        input = CompressionInput(
            id: UUID(),
            originalURL: workingURL,
            workingURL: workingURL,
            originalFilename: originalFilename,
            fileExtension: URL(fileURLWithPath: originalFilename).pathExtension,
            detectedTypeIdentifier: nil,
            fileKind: .image,
            originalSizeBytes: Int64(originalBytes),
            createdAt: Date()
        )
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
