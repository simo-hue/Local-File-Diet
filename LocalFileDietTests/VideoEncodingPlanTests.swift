import XCTest
@testable import LocalFileDiet

/// The video engine's decisions are arithmetic, and arithmetic does not need a
/// camera. Everything here runs in milliseconds against `VideoEncodingPlanner`,
/// which is why it can afford to check the edges: impossible targets, portrait
/// sources, odd pixel counts, both codecs.
final class VideoEncodingPlanTests: XCTestCase {
    private func facts(
        width: Int = 1920,
        height: Int = 1080,
        frameRate: Double = 30,
        durationSeconds: Double = 60,
        videoBitrate: Double = 8_000_000,
        hasAudio: Bool = false
    ) -> VideoSourceFacts {
        VideoSourceFacts(
            width: width,
            height: height,
            frameRate: frameRate,
            durationSeconds: durationSeconds,
            videoBitrate: videoBitrate,
            hasAudio: hasAudio
        )
    }

    // MARK: - 1. Bitrate comes from the target

    func testVideoBitrateIsDerivedFromTheTargetMinusContainerOverhead() {
        let plan = VideoEncodingPlanner.plan(
            source: facts(durationSeconds: 60, hasAudio: false),
            targetBytes: 10_000_000,
            mode: .balanced,
            resolutionPreset: .auto,
            preferModernFormat: false
        )

        let expected = 10_000_000.0 * 8 * VideoEncodingPlanner.budgetEfficiency / 60
        XCTAssertEqual(plan.videoBitrate, expected, accuracy: 1)
        XCTAssertEqual(plan.audioBitrate, 0)

        // The naive number ignores the bytes the MP4 container itself costs,
        // which is exactly how a file lands at 10.2 MB against a 10 MB limit.
        let naive = 10_000_000.0 * 8 / 60
        XCTAssertLessThan(plan.videoBitrate, naive)

        // The predicted size is deliberately BELOW the target: the rate-control
        // headroom is held back on purpose and is not added back in.
        XCTAssertLessThan(plan.predictedBytes, 10_000_000)
        XCTAssertEqual(
            Double(plan.predictedBytes),
            10_000_000 * VideoEncodingPlanner.rateControlHeadroom,
            accuracy: 2
        )
        XCTAssertFalse(plan.clampedToFloor)
    }

    // MARK: - 2. Audio is a real cost

    func testAudioBudgetIsSubtractedAndVariesByQualityMode() {
        XCTAssertEqual(VideoEncodingPlanner.audioBitrate(mode: .bestQuality, hasAudio: true), 128_000)
        XCTAssertEqual(VideoEncodingPlanner.audioBitrate(mode: .balanced, hasAudio: true), 96_000)
        XCTAssertEqual(VideoEncodingPlanner.audioBitrate(mode: .smallestFile, hasAudio: true), 64_000)
        XCTAssertEqual(VideoEncodingPlanner.audioBitrate(mode: .bestQuality, hasAudio: false), 0)

        for mode in QualityMode.allCases {
            let withAudio = VideoEncodingPlanner.plan(
                source: facts(hasAudio: true),
                targetBytes: 10_000_000,
                mode: mode,
                resolutionPreset: .auto,
                preferModernFormat: false
            )
            let withoutAudio = VideoEncodingPlanner.plan(
                source: facts(hasAudio: false),
                targetBytes: 10_000_000,
                mode: mode,
                resolutionPreset: .auto,
                preferModernFormat: false
            )
            XCTAssertEqual(
                withAudio.videoBitrate + withAudio.audioBitrate,
                withoutAudio.videoBitrate,
                accuracy: 1,
                "\(mode.rawValue): the audio budget must come out of the same total"
            )
            XCTAssertLessThan(withAudio.videoBitrate, withoutAudio.videoBitrate)
        }

        // Smallest file spends the least on audio, so it has the most left for
        // the picture.
        let best = VideoEncodingPlanner.plan(
            source: facts(hasAudio: true), targetBytes: 10_000_000,
            mode: .bestQuality, resolutionPreset: .auto, preferModernFormat: false
        )
        let smallest = VideoEncodingPlanner.plan(
            source: facts(hasAudio: true), targetBytes: 10_000_000,
            mode: .smallestFile, resolutionPreset: .auto, preferModernFormat: false
        )
        XCTAssertGreaterThan(smallest.videoBitrate, best.videoBitrate)
    }

    // MARK: - 3. Impossible targets clamp instead of going negative

    func testTinyTargetOnALongVideoClampsToTheFloor() {
        let plan = VideoEncodingPlanner.plan(
            source: facts(durationSeconds: 600, hasAudio: true),
            targetBytes: 500_000,
            mode: .balanced,
            resolutionPreset: .auto,
            preferModernFormat: false
        )

        XCTAssertEqual(plan.videoBitrate, VideoEncodingPlanner.minimumVideoBitrate)
        XCTAssertTrue(plan.clampedToFloor)
        XCTAssertGreaterThan(plan.videoBitrate, 0)
        // Being honest about it matters: the predicted size is above the target,
        // which is what makes the engine warn instead of promising.
        XCTAssertGreaterThan(plan.predictedBytes, 500_000)
    }

    func testZeroDurationDoesNotProduceNaNOrInfinity() {
        let plan = VideoEncodingPlanner.plan(
            source: facts(durationSeconds: 0),
            targetBytes: 1_000_000,
            mode: .balanced,
            resolutionPreset: .auto,
            preferModernFormat: false
        )
        XCTAssertTrue(plan.videoBitrate.isFinite)
        XCTAssertEqual(plan.videoBitrate, VideoEncodingPlanner.minimumVideoBitrate)
        XCTAssertEqual(plan.predictedBytes, 0)
    }

    // MARK: - 4. The resolution ladder

    func testFourKSourceDropsToASmallLadderRungWhenTheBudgetIsTiny() {
        let size = VideoEncodingPlanner.outputSize(
            sourceWidth: 3840,
            sourceHeight: 2160,
            frameRate: 30,
            videoBitrate: 1_000_000,
            codec: .h264,
            preset: .auto
        )
        XCTAssertTrue(
            [640, 480].contains(max(size.width, size.height)),
            "1 Mbps cannot carry 4K; expected a 640 or 480 long edge, got \(size)"
        )
    }

    func testFourKSourceKeepsFourKWhenTheBudgetIsGenerous() {
        let size = VideoEncodingPlanner.outputSize(
            sourceWidth: 3840,
            sourceHeight: 2160,
            frameRate: 30,
            videoBitrate: 20_000_000,
            codec: .h264,
            preset: .auto
        )
        XCTAssertEqual(size.width, 3840)
        XCTAssertEqual(size.height, 2160)
    }

    func testTheLadderIsMonotonicInBitrate() {
        var previous = 0
        for bitrate in stride(from: 300_000.0, through: 24_000_000.0, by: 300_000.0) {
            let size = VideoEncodingPlanner.outputSize(
                sourceWidth: 3840, sourceHeight: 2160, frameRate: 30,
                videoBitrate: bitrate, codec: .h264, preset: .auto
            )
            XCTAssertGreaterThanOrEqual(
                max(size.width, size.height), previous,
                "more bits should never buy a smaller frame (at \(bitrate) bps)"
            )
            previous = max(size.width, size.height)
        }
    }

    // MARK: - 5. Explicit presets

    func testResolutionPresetsAreHonouredAndNeverUpscale() {
        let keep = VideoEncodingPlanner.outputSize(
            sourceWidth: 640, sourceHeight: 480, frameRate: 30,
            videoBitrate: 200_000, codec: .h264, preset: .keepResolution
        )
        XCTAssertEqual(keep.width, 640)
        XCTAssertEqual(keep.height, 480)

        // 720p on a 640x480 source would be a bigger, blurrier file.
        let upscaleAttempt = VideoEncodingPlanner.outputSize(
            sourceWidth: 640, sourceHeight: 480, frameRate: 30,
            videoBitrate: 8_000_000, codec: .h264, preset: .p720
        )
        XCTAssertEqual(upscaleAttempt.width, 640)
        XCTAssertEqual(upscaleAttempt.height, 480)

        let p720 = VideoEncodingPlanner.outputSize(
            sourceWidth: 1920, sourceHeight: 1080, frameRate: 30,
            videoBitrate: 400_000, codec: .h264, preset: .p720
        )
        XCTAssertEqual(p720.width, 1280)
        XCTAssertEqual(p720.height, 720)

        // Pinning wins even when the bitrate cannot really support it: the user
        // asked for it, and the plan says so out loud via predictedQuality.
        let plan = VideoEncodingPlanner.plan(
            source: facts(durationSeconds: 60, hasAudio: false),
            targetBytes: 2_000_000,
            mode: .balanced,
            resolutionPreset: .keepResolution,
            preferModernFormat: false
        )
        XCTAssertEqual(plan.width, 1920)
        XCTAssertEqual(plan.height, 1080)
        XCTAssertEqual(VideoEncodingPlanner.predictedQuality(for: plan), .low)
    }

    // MARK: - 6. Geometry

    func testOutputDimensionsAreEvenAndPreserveAspectRatio() {
        let sources = [(1920, 1080), (1080, 1920), (1234, 567), (999, 999), (4096, 2160), (640, 480), (3, 7)]
        for (sourceWidth, sourceHeight) in sources {
            for longEdge in [4096, 1920, 1280, 960, 854, 640, 480, 321, 2] {
                let size = VideoEncodingPlanner.dimensions(
                    sourceWidth: sourceWidth,
                    sourceHeight: sourceHeight,
                    longEdge: longEdge
                )
                XCTAssertEqual(size.width % 2, 0, "width \(size.width) is odd for \(sourceWidth)x\(sourceHeight)@\(longEdge)")
                XCTAssertEqual(size.height % 2, 0, "height \(size.height) is odd for \(sourceWidth)x\(sourceHeight)@\(longEdge)")
                XCTAssertGreaterThanOrEqual(size.width, 2)
                XCTAssertGreaterThanOrEqual(size.height, 2)
                // Rounding to even must never round PAST the source, on either
                // edge — an odd 999x999 source must not become 1000x1000.
                XCTAssertLessThanOrEqual(
                    size.width, sourceWidth,
                    "never upscale: \(sourceWidth)x\(sourceHeight) @ \(longEdge) -> \(size)"
                )
                XCTAssertLessThanOrEqual(
                    size.height, sourceHeight,
                    "never upscale: \(sourceWidth)x\(sourceHeight) @ \(longEdge) -> \(size)"
                )

                // The derived edge must be within one pixel of the exact ratio.
                // Once an edge bottoms out at the 2-pixel minimum no even frame
                // can hold the ratio any more, so that case is exempt.
                guard size.width > 2, size.height > 2 else { continue }
                if sourceWidth >= sourceHeight {
                    let ideal = Double(size.width) * Double(sourceHeight) / Double(sourceWidth)
                    XCTAssertLessThanOrEqual(abs(Double(size.height) - ideal), 1.0 + 1e-9)
                } else {
                    let ideal = Double(size.height) * Double(sourceWidth) / Double(sourceHeight)
                    XCTAssertLessThanOrEqual(abs(Double(size.width) - ideal), 1.0 + 1e-9)
                }
            }
        }
    }

    // MARK: - 7. Codec

    func testHEVCNeedsALowerBitrateThanH264ForTheSameFrame() {
        let h264 = VideoEncodingPlanner.requiredBitrate(width: 1280, height: 720, frameRate: 30, codec: .h264)
        let hevc = VideoEncodingPlanner.requiredBitrate(width: 1280, height: 720, frameRate: 30, codec: .hevc)
        XCTAssertLessThan(hevc, h264)
        XCTAssertEqual(hevc / h264, 0.5, accuracy: 0.01)

        // Same budget, same source: HEVC therefore keeps a larger frame.
        func chosenLongEdge(_ codec: VideoPlanCodec) -> Int {
            let size = VideoEncodingPlanner.outputSize(
                sourceWidth: 3840, sourceHeight: 2160, frameRate: 30,
                videoBitrate: 1_000_000, codec: codec, preset: .auto
            )
            return max(size.width, size.height)
        }
        XCTAssertGreaterThan(chosenLongEdge(.hevc), chosenLongEdge(.h264))

        XCTAssertEqual(VideoEncodingPlanner.codec(preferModernFormat: true), .hevc)
        XCTAssertEqual(VideoEncodingPlanner.codec(preferModernFormat: false), .h264)
    }

    // MARK: - Frame rate

    func testFrameRateIsOnlyCappedForHighRateSourcesInSmallestFileMode() {
        XCTAssertEqual(VideoEncodingPlanner.frameRate(sourceFrameRate: 120, mode: .smallestFile), 30)
        XCTAssertEqual(VideoEncodingPlanner.frameRate(sourceFrameRate: 120, mode: .balanced), 120)
        XCTAssertEqual(VideoEncodingPlanner.frameRate(sourceFrameRate: 60, mode: .smallestFile), 60)
        XCTAssertEqual(VideoEncodingPlanner.frameRate(sourceFrameRate: 30, mode: .smallestFile), 30)
        // A track that reports no frame rate must not produce a zero divisor.
        XCTAssertEqual(VideoEncodingPlanner.frameRate(sourceFrameRate: 0, mode: .balanced), 30)
    }

    // MARK: - Refinement

    func testRefinementOnlyHappensWhenPassOneOvershoots() {
        let source = facts(durationSeconds: 60, hasAudio: true)
        let first = VideoEncodingPlanner.plan(
            source: source, targetBytes: 10_000_000,
            mode: .balanced, resolutionPreset: .auto, preferModernFormat: false
        )

        XCTAssertNil(
            VideoEncodingPlanner.refinedPlan(
                after: first, source: source, measuredBytes: 10_400_000,
                targetBytes: 10_000_000, tolerance: 1.08, resolutionPreset: .auto
            ),
            "4% over is inside tolerance; a whole second encode is not worth it"
        )

        let refined = VideoEncodingPlanner.refinedPlan(
            after: first, source: source, measuredBytes: 13_000_000,
            targetBytes: 10_000_000, tolerance: 1.08, resolutionPreset: .auto
        )
        XCTAssertNotNil(refined)
        XCTAssertLessThan(refined?.videoBitrate ?? .infinity, first.videoBitrate)
        XCTAssertEqual(refined?.audioBitrate, first.audioBitrate)
        XCTAssertEqual(refined?.frameRate, first.frameRate)
        XCTAssertEqual(refined?.codec, first.codec)
    }

    func testRefinementNeverGoesBelowTheFloor() {
        let source = facts(durationSeconds: 600, hasAudio: true)
        let first = VideoEncodingPlanner.plan(
            source: source, targetBytes: 800_000,
            mode: .balanced, resolutionPreset: .auto, preferModernFormat: false
        )
        let refined = VideoEncodingPlanner.refinedPlan(
            after: first, source: source, measuredBytes: 20_000_000,
            targetBytes: 800_000, tolerance: 1.08, resolutionPreset: .auto
        )
        XCTAssertGreaterThanOrEqual(refined?.videoBitrate ?? 0, VideoEncodingPlanner.minimumVideoBitrate)
    }

    // MARK: - Legacy surface

    func testLegacyBitratePlannerStillAnswersTheSameWay() {
        let bitrate = VideoBitratePlanner.targetBitrateBitsPerSecond(
            targetSizeBytes: 10_000_000,
            durationSeconds: 20
        )
        XCTAssertGreaterThan(bitrate, 3_000_000)
        XCTAssertEqual(VideoBitratePlanner.targetBitrateBitsPerSecond(targetSizeBytes: 1_000, durationSeconds: 0), 0)
        XCTAssertEqual(VideoBitratePlanner.quality(for: 5_000_000), .excellent)
        XCTAssertEqual(VideoBitratePlanner.quality(for: 100_000), .low)
    }

    // MARK: - No target at all

    func testWithoutATargetTheBitrateFollowsTheQualityMode() {
        let source = facts(videoBitrate: 12_000_000)
        var previous = Double.infinity
        for mode in [QualityMode.bestQuality, .balanced, .smallestFile] {
            let plan = VideoEncodingPlanner.plan(
                source: source, targetBytes: nil,
                mode: mode, resolutionPreset: .auto, preferModernFormat: false
            )
            XCTAssertLessThan(plan.videoBitrate, 12_000_000)
            XCTAssertLessThan(plan.videoBitrate, previous)
            XCTAssertFalse(plan.clampedToFloor)
            previous = plan.videoBitrate
        }
    }
}
