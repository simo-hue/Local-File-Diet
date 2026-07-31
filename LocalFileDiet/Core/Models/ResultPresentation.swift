import Foundation

/// The headline of the result screen, decided from the result rather than from
/// a single boolean.
///
/// `result.targetReached ? "Target reached" : "Target not reached"` was wrong in
/// two directions. When the engine kept the original because nothing could be
/// improved, it shouted "Target not reached" under a warning triangle, which
/// reads as a bug rather than as the honest answer it is. And when the user asks
/// for no size limit there is no target to reach or miss, so both halves of that
/// sentence are meaningless.
extension CompressionWarning {
    /// The engines' video planner emits this before a frame is encoded, so the
    /// review screen can promise a resolution instead of revealing one
    /// afterwards. The id has to match what `videoOutputPlan(width:height:codec:)`
    /// builds.
    static let videoOutputPlanID = "videoOutputPlan"

    var isVideoOutputPlan: Bool { id == Self.videoOutputPlanID }
}

enum ResultStatus: Equatable, Sendable {
    /// The engine could not beat the original, so the original was handed back.
    case keptOriginal
    /// No target was set; the only honest number is the reduction achieved.
    case reduced(percent: Double)
    case targetReached
    case targetMissed

    enum Tone: Equatable, Sendable {
        case success
        case neutral
        case caution
    }

    static func make(result: CompressionResult, targetSizeBytes: Int64?) -> ResultStatus {
        if result.warnings.contains(where: { $0.id == CompressionWarning.keptOriginal.id }) {
            return .keptOriginal
        }
        guard targetSizeBytes != nil else {
            return .reduced(percent: result.reductionPercent)
        }
        return result.targetReached ? .targetReached : .targetMissed
    }

    var title: String {
        switch self {
        case .keptOriginal:
            "Already as small as it gets"
        case .reduced(let percent):
            percent < 0.5 ? "No smaller than the original" : "\(FileSizeFormat.percent(percent)) smaller"
        case .targetReached:
            "Target reached"
        case .targetMissed:
            "Target not reached"
        }
    }

    var detail: String? {
        switch self {
        case .keptOriginal:
            "Your original file was kept, unchanged."
        case .reduced(let percent):
            percent < 0.5 ? "This file was already about as small as it gets." : nil
        case .targetReached:
            nil
        case .targetMissed:
            "This is the smallest we could get without destroying the file. Try Smaller pushes harder."
        }
    }

    var systemImage: String {
        switch self {
        case .keptOriginal: "checkmark.shield.fill"
        case .reduced(let percent): percent < 0.5 ? "info.circle.fill" : "checkmark.seal.fill"
        case .targetReached: "checkmark.seal.fill"
        case .targetMissed: "exclamationmark.triangle.fill"
        }
    }

    var tone: Tone {
        switch self {
        case .keptOriginal: .neutral
        case .reduced(let percent): percent < 0.5 ? .neutral : .success
        case .targetReached: .success
        case .targetMissed: .caution
        }
    }
}
