import Foundation

/// Everything the video engine decides BEFORE it touches AVFoundation.
///
/// The engine used to ask `AVAssetExportSession` for a named preset and hope.
/// Presets carry fixed internal bitrates, so "under 5 MB" was luck: the only
/// lever was to export the whole asset two or three times and keep whichever
/// came out smallest. Aiming at a size instead means computing a bitrate, and a
/// bitrate is arithmetic — so all of it lives here, in plain numbers, with no
/// AVFoundation type in any signature. That makes the interesting half of the
/// engine testable in milliseconds without a single frame of video.

// MARK: - Codec

enum VideoPlanCodec: String, Codable, Sendable, Hashable {
    case h264
    case hevc

    var displayName: String {
        switch self {
        case .h264: "H.264"
        case .hevc: "HEVC"
        }
    }

    /// Bits per pixel per frame this codec needs at the 720p reference frame
    /// size before the picture starts visibly falling apart.
    ///
    /// H.264 wants roughly 0.07–0.10 bpp for everyday camera footage. HEVC
    /// reaches the same picture for roughly half the bits, which is why it is
    /// worth offering — but it is markedly less portable (older Windows
    /// machines, plenty of web upload forms and some Android handsets still
    /// refuse it), so H.264 stays the default and HEVC is opt-in.
    var referenceBitsPerPixelPerFrame: Double {
        switch self {
        case .h264: 0.09
        case .hevc: 0.045
        }
    }
}

// MARK: - Source facts

/// The handful of numbers the planner needs about the input video.
///
/// `width`/`height` are the track's NATURAL size, i.e. the size of the decoded
/// buffers, not the size the viewer sees. Rotation lives in the track's
/// transform and is carried through the encoder untouched, so the planner never
/// has to reason about it.
struct VideoSourceFacts: Sendable, Hashable {
    var width: Int
    var height: Int
    var frameRate: Double
    var durationSeconds: Double
    /// The track's estimated data rate in bits per second. Zero when unknown;
    /// only used when the user did not ask for a target size.
    var videoBitrate: Double
    var hasAudio: Bool

    init(
        width: Int,
        height: Int,
        frameRate: Double,
        durationSeconds: Double,
        videoBitrate: Double = 0,
        hasAudio: Bool
    ) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.durationSeconds = durationSeconds
        self.videoBitrate = videoBitrate
        self.hasAudio = hasAudio
    }
}

// MARK: - Plan

struct VideoEncodingPlan: Sendable, Hashable {
    /// Encoder output width, in natural (untransformed) coordinates. Always even.
    let width: Int
    /// Encoder output height, in natural (untransformed) coordinates. Always even.
    let height: Int
    let frameRate: Double
    /// Video bitrate in bits per second.
    let videoBitrate: Double
    /// Audio bitrate in bits per second; zero when the source has no audio.
    let audioBitrate: Double
    let codec: VideoPlanCodec
    /// What this plan is expected to weigh on disk, container overhead included.
    let predictedBytes: Int64
    /// True when the target was so small that the video bitrate had to be
    /// clamped to the readability floor. The target is then unreachable and the
    /// caller should say so rather than pretend.
    let clampedToFloor: Bool

    var totalBitrate: Double { videoBitrate + audioBitrate }
    var resolutionDescription: String { "\(width)x\(height)" }
}

// MARK: - Planner

enum VideoEncodingPlanner {
    /// MP4 muxing is not free: sample tables, the `moov` atom and per-sample
    /// headers all cost bytes that no bitrate setting accounts for. Budgeting
    /// 98% of the target for the media itself lands the file just UNDER the
    /// number the user typed instead of just over it, which is the whole point
    /// of a limit like "under 10 MB".
    static let containerEfficiency: Double = 0.98

    /// Hardware H.264/HEVC rate control treats `AVVideoAverageBitRateKey` as a
    /// rate to hover around, not a ceiling, and on detailed footage it hovers
    /// above it. Measured on real encodes (1080p30 and 4K30, ten seconds, AAC
    /// audio, targets from 1 MB to 10 MB): with container overhead alone the
    /// first pass landed 0.6% to 7.8% OVER the target, and a 5 MB target
    /// produced a 5.07 MB file — which fails the only test the user cares
    /// about. Holding a further 4% back, together with the hard data-rate limit
    /// below, brings every measured case to 0.94-0.97 of the target.
    static let rateControlHeadroom: Double = 0.96

    /// The share of the target that the media data is allowed to occupy.
    static var budgetEfficiency: Double { containerEfficiency * rateControlHeadroom }

    /// Sliding window, in seconds, for the encoder's hard data-rate limit.
    static let dataRateWindowSeconds: Double = 2

    /// How much the encoder may exceed the average rate inside one window.
    /// This is a ceiling, not a target: VideoToolbox steers well clear of it, so
    /// a value near 1.0 starves the encoder (measured: a 1.1x ceiling produced
    /// files at 0.75x the target — a quarter of the quality budget thrown away)
    /// while a value that is too generous stops constraining anything. 1.6 was
    /// picked by measurement; see the sweep in the verification notes.
    static let dataRateLimitFactor: Double = 1.6

    /// Below this the video stops being a video. A target that would need less
    /// gets this instead, and the caller reports the target as unreachable.
    static let minimumVideoBitrate: Double = 150_000

    /// Standard long edges, largest first. The source's own long edge is added
    /// on top of this at planning time, and nothing above it is ever considered
    /// — upscaling costs bits and adds no detail.
    static let resolutionLadder = [1920, 1280, 960, 854, 640, 480]

    /// Reference frame size for `referenceBitsPerPixelPerFrame`.
    static let referencePixels: Double = 1280 * 720

    /// Bits-per-pixel requirements are not flat across frame sizes: a 4K frame
    /// carries far more spatial redundancy per pixel than a 480p frame, so it
    /// looks acceptable at a lower bpp. A quarter-power law fits the usual
    /// streaming ladders well enough for this decision and, more importantly,
    /// stops the planner from concluding that a 4K source at 20 Mbps should be
    /// downscaled (it should not) while still rejecting 480p at 1 Mbps on a 4K
    /// source (it should).
    static let resolutionExponent: Double = 0.25

    // MARK: Audio

    /// Audio is a fixed cost that has to come out of the budget before the
    /// video gets any of it — on a 2 MB target for a 60 s clip, 128 kbps of
    /// audio is nearly half the file.
    static func audioBitrate(mode: QualityMode, hasAudio: Bool) -> Double {
        guard hasAudio else { return 0 }
        switch mode {
        case .bestQuality: return 128_000
        case .balanced: return 96_000
        case .smallestFile: return 64_000
        }
    }

    // MARK: Video bitrate

    /// `(targetBytes * 8 * budgetEfficiency / duration) - audioBitrate`, floored
    /// so the result stays watchable rather than going to zero or negative on an
    /// impossible target.
    static func videoBitrate(
        targetBytes: Int64,
        durationSeconds: Double,
        audioBitrate: Double
    ) -> (bitsPerSecond: Double, clampedToFloor: Bool) {
        guard durationSeconds > 0, targetBytes > 0 else {
            return (minimumVideoBitrate, true)
        }
        let budget = Double(targetBytes) * 8 * budgetEfficiency / durationSeconds
        let forVideo = budget - audioBitrate
        if forVideo < minimumVideoBitrate {
            return (minimumVideoBitrate, true)
        }
        return (forVideo, false)
    }

    /// Bitrate to use when the user set no target at all: shrink relative to
    /// what the source already spends, or — when the source rate is unknown —
    /// relative to what this frame size would need for a good picture.
    static func qualityBitrate(
        source: VideoSourceFacts,
        codec: VideoPlanCodec,
        mode: QualityMode
    ) -> Double {
        let fps = max(frameRate(sourceFrameRate: source.frameRate, mode: mode), 1)
        let reference = source.videoBitrate > 0
            ? source.videoBitrate
            : requiredBitrate(width: source.width, height: source.height, frameRate: fps, codec: .h264)
        let modeFactor: Double
        switch mode {
        case .bestQuality: modeFactor = 0.75
        case .balanced: modeFactor = 0.50
        case .smallestFile: modeFactor = 0.30
        }
        // HEVC buys the same picture for fewer bits, so spend fewer of them.
        let codecFactor = codec == .hevc ? 0.65 : 1.0
        return max(minimumVideoBitrate, reference * modeFactor * codecFactor)
    }

    // MARK: Frame rate

    /// High-frame-rate footage costs bits linearly. Halving 120 fps to 30 fps is
    /// the single cheapest saving available, but it changes how the video LOOKS,
    /// so it only happens when the user explicitly asked for the smallest file.
    static func frameRate(sourceFrameRate: Double, mode: QualityMode) -> Double {
        let source = sourceFrameRate > 0 ? sourceFrameRate : 30
        if source > 60, mode == .smallestFile {
            return 30
        }
        return source
    }

    // MARK: Codec

    /// The review screen labels this toggle "Prefer smaller modern format", so
    /// it governs video as well as stills.
    static func codec(preferModernFormat: Bool) -> VideoPlanCodec {
        preferModernFormat ? .hevc : .h264
    }

    // MARK: Resolution

    /// Bits per pixel per frame required for an acceptable picture at this frame
    /// size, scaled off the 720p reference by `resolutionExponent`.
    static func requiredBitsPerPixelPerFrame(width: Int, height: Int, codec: VideoPlanCodec) -> Double {
        let pixels = Double(max(width * height, 1))
        let scale = pow(referencePixels / pixels, resolutionExponent)
        return codec.referenceBitsPerPixelPerFrame * scale
    }

    /// Bitrate this frame size and frame rate would need to look acceptable.
    static func requiredBitrate(width: Int, height: Int, frameRate: Double, codec: VideoPlanCodec) -> Double {
        let pixels = Double(max(width * height, 1))
        return requiredBitsPerPixelPerFrame(width: width, height: height, codec: codec)
            * pixels
            * max(frameRate, 1)
    }

    /// The largest output size whose bits-per-pixel clears the codec's
    /// threshold at `videoBitrate`. Explicit user presets pin the long edge
    /// instead, and nothing ever goes above the source.
    static func outputSize(
        sourceWidth: Int,
        sourceHeight: Int,
        frameRate: Double,
        videoBitrate: Double,
        codec: VideoPlanCodec,
        preset: VideoResolutionPreset
    ) -> (width: Int, height: Int) {
        guard sourceWidth > 0, sourceHeight > 0 else { return (0, 0) }
        let sourceLongEdge = max(sourceWidth, sourceHeight)

        let pinned: Int?
        switch preset {
        case .keepResolution: pinned = sourceLongEdge
        case .p1080: pinned = 1920
        case .p720: pinned = 1280
        case .p540: pinned = 960
        case .p480: pinned = 640
        case .auto: pinned = nil
        }
        if let pinned {
            // `dimensions` clamps to the source, so 720p never upscales a
            // 640x480 clip into a blurrier, bigger 720p one.
            return dimensions(sourceWidth: sourceWidth, sourceHeight: sourceHeight, longEdge: pinned)
        }

        var candidates = [sourceLongEdge]
        for rung in resolutionLadder where rung < sourceLongEdge {
            candidates.append(rung)
        }
        let fps = max(frameRate, 1)
        for candidate in candidates {
            let size = dimensions(sourceWidth: sourceWidth, sourceHeight: sourceHeight, longEdge: candidate)
            let pixels = Double(max(size.width * size.height, 1))
            let bitsPerPixelPerFrame = videoBitrate / (pixels * fps)
            if bitsPerPixelPerFrame >= requiredBitsPerPixelPerFrame(width: size.width, height: size.height, codec: codec) {
                return size
            }
        }
        // Nothing clears the bar: take the smallest rung and let the caller warn.
        return dimensions(
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            longEdge: candidates.last ?? sourceLongEdge
        )
    }

    /// Aspect-preserving, never-upscaling, always-even dimensions.
    /// H.264 and HEVC both require even width and height for 4:2:0 chroma.
    ///
    /// Rounding to even can round UP, so an odd source (999x999, or any track
    /// with an odd edge) would otherwise be encoded one pixel larger than it
    /// started. Each edge is therefore also capped at the largest even number
    /// that fits inside the source.
    static func dimensions(sourceWidth: Int, sourceHeight: Int, longEdge: Int) -> (width: Int, height: Int) {
        guard sourceWidth > 0, sourceHeight > 0 else { return (0, 0) }
        let sourceLongEdge = max(sourceWidth, sourceHeight)
        let clamped = max(2, min(longEdge, sourceLongEdge))
        let widthCeiling = evenFloored(sourceWidth)
        let heightCeiling = evenFloored(sourceHeight)
        if sourceWidth >= sourceHeight {
            let width = min(evenRounded(Double(clamped)), widthCeiling)
            let ideal = Double(width) * Double(sourceHeight) / Double(sourceWidth)
            return (width, min(evenRounded(ideal), heightCeiling))
        }
        let height = min(evenRounded(Double(clamped)), heightCeiling)
        let ideal = Double(height) * Double(sourceWidth) / Double(sourceHeight)
        return (min(evenRounded(ideal), widthCeiling), height)
    }

    static func evenRounded(_ value: Double) -> Int {
        guard value.isFinite else { return 2 }
        return max(2, Int((value / 2).rounded()) * 2)
    }

    /// The largest even number that is not bigger than `value`, floored at 2 —
    /// a 1-pixel-wide track cannot be encoded at all.
    static func evenFloored(_ value: Int) -> Int {
        max(2, value - (value % 2))
    }

    // MARK: Size prediction

    /// What these bitrates actually weigh: the media itself plus the container
    /// overhead. Note this divides by `containerEfficiency` only, NOT by the
    /// full budget — the rate-control headroom is deliberately not added back,
    /// because the whole point of holding it in reserve is that the file should
    /// come out below the target. Predicting the target instead would overstate
    /// the result by 4%; predicting this matched real encodes to within 0.6%.
    static func predictedBytes(videoBitrate: Double, audioBitrate: Double, durationSeconds: Double) -> Int64 {
        guard durationSeconds > 0 else { return 0 }
        let payload = (videoBitrate + audioBitrate) * durationSeconds / 8
        return Int64((payload / containerEfficiency).rounded())
    }

    // MARK: Composition

    static func plan(
        source: VideoSourceFacts,
        targetBytes: Int64?,
        mode: QualityMode,
        resolutionPreset: VideoResolutionPreset,
        preferModernFormat: Bool
    ) -> VideoEncodingPlan {
        let codec = codec(preferModernFormat: preferModernFormat)
        let fps = frameRate(sourceFrameRate: source.frameRate, mode: mode)
        let audio = audioBitrate(mode: mode, hasAudio: source.hasAudio)

        let video: Double
        let clamped: Bool
        if let targetBytes {
            let computed = videoBitrate(
                targetBytes: targetBytes,
                durationSeconds: source.durationSeconds,
                audioBitrate: audio
            )
            video = computed.bitsPerSecond
            clamped = computed.clampedToFloor
        } else {
            video = qualityBitrate(source: source, codec: codec, mode: mode)
            clamped = false
        }

        return finish(
            source: source,
            videoBitrate: video,
            audioBitrate: audio,
            frameRate: fps,
            codec: codec,
            resolutionPreset: resolutionPreset,
            clampedToFloor: clamped
        )
    }

    /// Second and final pass. Pass one measures how far the encoder's rate
    /// control actually landed from the request; this converts that measurement
    /// into a corrected bitrate. Returns nil when pass one is already close
    /// enough, which is the common case and the reason the engine is bounded at
    /// two encodes instead of the old three.
    static func refinedPlan(
        after plan: VideoEncodingPlan,
        source: VideoSourceFacts,
        measuredBytes: Int64,
        targetBytes: Int64,
        tolerance: Double,
        resolutionPreset: VideoResolutionPreset
    ) -> VideoEncodingPlan? {
        guard targetBytes > 0, measuredBytes > 0, source.durationSeconds > 0 else { return nil }
        guard Double(measuredBytes) > Double(targetBytes) * tolerance else { return nil }

        // Audio is a fixed cost and did not overshoot; only the video track's
        // share needs correcting, so the correction is computed on that share.
        let audioBytes = plan.audioBitrate * source.durationSeconds / 8
        let measuredVideoBytes = max(Double(measuredBytes) * containerEfficiency - audioBytes, 1)
        let targetVideoBytes = Double(targetBytes) * budgetEfficiency - audioBytes
        guard targetVideoBytes > 0 else {
            return finish(
                source: source,
                videoBitrate: minimumVideoBitrate,
                audioBitrate: plan.audioBitrate,
                frameRate: plan.frameRate,
                codec: plan.codec,
                resolutionPreset: resolutionPreset,
                clampedToFloor: true
            )
        }
        // The extra 3% is deliberate undershoot: there is no third pass, so
        // landing slightly small beats landing slightly over the limit.
        let factor = min(1, max(0.2, targetVideoBytes / measuredVideoBytes)) * 0.97
        let corrected = plan.videoBitrate * factor
        let floored = max(minimumVideoBitrate, corrected)

        return finish(
            source: source,
            videoBitrate: floored,
            audioBitrate: plan.audioBitrate,
            frameRate: plan.frameRate,
            codec: plan.codec,
            resolutionPreset: resolutionPreset,
            clampedToFloor: corrected < minimumVideoBitrate
        )
    }

    private static func finish(
        source: VideoSourceFacts,
        videoBitrate: Double,
        audioBitrate: Double,
        frameRate: Double,
        codec: VideoPlanCodec,
        resolutionPreset: VideoResolutionPreset,
        clampedToFloor: Bool
    ) -> VideoEncodingPlan {
        let size = outputSize(
            sourceWidth: source.width,
            sourceHeight: source.height,
            frameRate: frameRate,
            videoBitrate: videoBitrate,
            codec: codec,
            preset: resolutionPreset
        )
        return VideoEncodingPlan(
            width: size.width,
            height: size.height,
            frameRate: frameRate,
            videoBitrate: videoBitrate,
            audioBitrate: audioBitrate,
            codec: codec,
            predictedBytes: predictedBytes(
                videoBitrate: videoBitrate,
                audioBitrate: audioBitrate,
                durationSeconds: source.durationSeconds
            ),
            clampedToFloor: clampedToFloor
        )
    }

    /// How the picture is expected to hold up: the ratio between the bits the
    /// plan actually spends per pixel and the bits that frame size wants.
    static func predictedQuality(for plan: VideoEncodingPlan) -> PredictedQuality {
        let pixels = Double(max(plan.width * plan.height, 1))
        let actual = plan.videoBitrate / (pixels * max(plan.frameRate, 1))
        let required = requiredBitsPerPixelPerFrame(width: plan.width, height: plan.height, codec: plan.codec)
        guard required > 0 else { return .acceptable }
        switch actual / required {
        case 1.6...: return .excellent
        case 1.0..<1.6: return .good
        case 0.6..<1.0: return .acceptable
        default: return .low
        }
    }
}

// MARK: - Legacy surface

/// Kept for the existing call sites and tests. The real planning now lives in
/// `VideoEncodingPlanner`; these two functions are the thin bits of it that the
/// rest of the app already knew about.
struct VideoBitratePlanner {
    static func targetBitrateBitsPerSecond(
        targetSizeBytes: Int64,
        durationSeconds: Double,
        audioBitrate: Double = 128_000
    ) -> Double {
        guard durationSeconds > 0 else { return 0 }
        return VideoEncodingPlanner.videoBitrate(
            targetBytes: targetSizeBytes,
            durationSeconds: durationSeconds,
            audioBitrate: audioBitrate
        ).bitsPerSecond
    }

    static func quality(for bitrate: Double) -> PredictedQuality {
        switch bitrate {
        case 4_000_000...:
            .excellent
        case 1_600_000..<4_000_000:
            .good
        case 750_000..<1_600_000:
            .acceptable
        default:
            .low
        }
    }
}
