import Foundation

extension QualityMode {
    /// One notch toward a smaller file, or `nil` when there is nowhere left to go.
    var oneNotchSmaller: QualityMode? {
        switch self {
        case .bestQuality: .balanced
        case .balanced: .smallestFile
        case .smallestFile: nil
        }
    }

    /// One notch toward a better-looking file, or `nil` at the top.
    var oneNotchBetter: QualityMode? {
        switch self {
        case .smallestFile: .balanced
        case .balanced: .bestQuality
        case .bestQuality: nil
        }
    }
}

/// The two "give it another go" moves offered on the result screen.
///
/// They used to be two buttons calling the same closure with the same input,
/// which re-opened the review screen with the saved defaults — so they were
/// identical to each other and to doing nothing. They are transforms of the
/// settings that were actually used, so the next run genuinely differs.
extension CompressionSettings {
    /// Halving a target below this stops meaning anything: it is no longer a
    /// size the user wants, it is a size no format can produce.
    static let smallestUsefulTargetBytes: Int64 = 100_000

    /// How much a "Better Quality" retry relaxes an existing target.
    static let betterQualityTargetFactor: Double = 1.5

    var canTrySmaller: Bool {
        if let target = targetSizeBytes {
            return target / 2 >= Self.smallestUsefulTargetBytes
        }
        return qualityMode.oneNotchSmaller != nil
    }

    var canTryBetterQuality: Bool {
        qualityMode.oneNotchBetter != nil
    }

    /// Roughly half the target; with no target, one notch harder on quality.
    /// `nil` when neither move is available, which is the signal to hide the
    /// button rather than show one that does nothing.
    func trySmaller() -> CompressionSettings? {
        guard canTrySmaller else { return nil }
        var next = self
        if let target = targetSizeBytes {
            next.targetSizeBytes = max(target / 2, Self.smallestUsefulTargetBytes)
        } else if let mode = qualityMode.oneNotchSmaller {
            next.qualityMode = mode
        }
        return next == self ? nil : next
    }

    /// One notch better on quality, plus a little more room if a target was set.
    func betterQuality() -> CompressionSettings? {
        guard let mode = qualityMode.oneNotchBetter else { return nil }
        var next = self
        next.qualityMode = mode
        if let target = targetSizeBytes {
            next.targetSizeBytes = Int64(Double(target) * Self.betterQualityTargetFactor)
        }
        return next == self ? nil : next
    }
}
