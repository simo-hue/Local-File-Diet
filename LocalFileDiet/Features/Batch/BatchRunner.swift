import Foundation
import Observation

/// The single thing the batch needs from the compression stack.
///
/// Injecting it keeps `BatchRunner` — the part with the sequencing, failure and
/// cancellation rules — testable without a real image, PDF or video on disk.
protocol BatchFileCompressing: Sendable {
    func compress(
        input: CompressionInput,
        settings: CompressionSettings,
        progress: @escaping @Sendable (CompressionProgress) -> Void
    ) async throws -> CompressionResult
}

/// The live implementation: the same router the single-file flow uses.
struct RouterBatchCompressor: BatchFileCompressing, @unchecked Sendable {
    private let router: CompressionRouter

    init(router: CompressionRouter) {
        self.router = router
    }

    func compress(
        input: CompressionInput,
        settings: CompressionSettings,
        progress: @escaping @Sendable (CompressionProgress) -> Void
    ) async throws -> CompressionResult {
        try await router.compress(input: input, settings: settings, progress: progress)
    }
}

/// Where finished files are remembered. `HistoryStore` is the live one; tests
/// pass a fake so a batch run never touches Application Support.
protocol BatchHistoryRecording: AnyObject {
    @MainActor func add(input: CompressionInput, result: CompressionResult)
}

extension HistoryStore: BatchHistoryRecording {}

/// Everything the result screen needs, and nothing that cannot be put in a
/// navigation path: `Hashable` and `Sendable` all the way down, which is why a
/// failure is carried as its message rather than as an `Error`.
struct BatchOutcome: Hashable, Sendable {
    struct Entry: Hashable, Sendable, Identifiable {
        let input: CompressionInput
        let result: CompressionResult?
        let failureMessage: String?
        let wasCancelled: Bool

        var id: UUID { input.id }
        var succeeded: Bool { result != nil }
    }

    let entries: [Entry]
    let settings: CompressionSettings

    var succeeded: [Entry] { entries.filter { $0.succeeded } }
    var failed: [Entry] { entries.filter { $0.result == nil && !$0.wasCancelled } }
    var cancelled: [Entry] { entries.filter { $0.result == nil && $0.wasCancelled } }

    /// Sizes are summed over the files that actually produced an output, so the
    /// headline number is bytes the user really saved.
    var totalOriginalBytes: Int64 { succeeded.reduce(0) { $0 + ($1.result?.originalSizeBytes ?? 0) } }
    var totalCompressedBytes: Int64 { succeeded.reduce(0) { $0 + ($1.result?.compressedSizeBytes ?? 0) } }
    var totalSavedBytes: Int64 { max(0, totalOriginalBytes - totalCompressedBytes) }
    var totalReductionPercent: Double {
        CompressionMath.reductionPercent(original: totalOriginalBytes, compressed: totalCompressedBytes)
    }

    var outputURLs: [URL] { succeeded.compactMap { $0.result?.outputURL } }
}

/// Compresses a pile of files one after another.
///
/// Sequential on purpose. The PDF and video engines hold whole pages and whole
/// sample buffers in memory; running four of those at once on a phone is how a
/// batch feature turns into a jetsam report. One file failing is recorded and
/// stepped over — a bad PDF in the middle must not cost the user the other nine.
@MainActor
@Observable
final class BatchRunner {
    enum ItemState: Equatable, Sendable {
        case pending
        case running(fraction: Double)
        case succeeded(CompressionResult)
        case failed(message: String)
        case cancelled

        var isFinished: Bool {
            switch self {
            case .pending, .running: false
            case .succeeded, .failed, .cancelled: true
            }
        }
    }

    struct Item: Identifiable, Sendable {
        let input: CompressionInput
        var state: ItemState

        var id: UUID { input.id }
    }

    enum Phase: Equatable, Sendable {
        case idle
        case running
        case finished
    }

    private(set) var items: [Item]
    private(set) var phase: Phase = .idle
    let settings: CompressionSettings

    @ObservationIgnored private let compressor: BatchFileCompressing
    @ObservationIgnored private let history: (any BatchHistoryRecording)?
    @ObservationIgnored private var runTask: Task<Void, Never>?

    init(
        inputs: [CompressionInput],
        settings: CompressionSettings,
        compressor: BatchFileCompressing,
        history: (any BatchHistoryRecording)? = nil
    ) {
        self.items = inputs.map { Item(input: $0, state: .pending) }
        self.settings = settings
        self.compressor = compressor
        self.history = history
    }

    // MARK: - Progress

    var completedCount: Int { items.filter { $0.state.isFinished }.count }

    var totalCount: Int { items.count }

    /// Completed files plus however far the current one has got.
    var overallProgress: Double {
        guard !items.isEmpty else { return 1 }
        let running = items.compactMap { item -> Double? in
            if case .running(let fraction) = item.state { return fraction }
            return nil
        }.first ?? 0
        return min(1, (Double(completedCount) + running) / Double(items.count))
    }

    var currentItem: Item? {
        items.first { if case .running = $0.state { return true } else { return false } }
    }

    var isRunning: Bool { phase == .running }

    var outcome: BatchOutcome {
        BatchOutcome(
            entries: items.map { item in
                switch item.state {
                case .succeeded(let result):
                    BatchOutcome.Entry(input: item.input, result: result, failureMessage: nil, wasCancelled: false)
                case .failed(let message):
                    BatchOutcome.Entry(input: item.input, result: nil, failureMessage: message, wasCancelled: false)
                case .cancelled:
                    BatchOutcome.Entry(input: item.input, result: nil, failureMessage: nil, wasCancelled: true)
                case .pending, .running:
                    BatchOutcome.Entry(input: item.input, result: nil, failureMessage: nil, wasCancelled: true)
                }
            },
            settings: settings
        )
    }

    // MARK: - Running

    func start() {
        guard phase == .idle else { return }
        phase = .running
        runTask = Task { [weak self] in
            await self?.run()
        }
    }

    /// Stops the whole run promptly: the file in flight is cancelled through the
    /// task, and everything still queued is marked cancelled so nothing else
    /// starts even if the engine takes a moment to unwind.
    func cancel() {
        runTask?.cancel()
        for index in items.indices where items[index].state == .pending {
            items[index].state = .cancelled
        }
        if phase == .idle {
            phase = .finished
        }
    }

    private func run() async {
        for index in items.indices {
            if Task.isCancelled {
                cancelRemaining(from: index)
                break
            }
            guard items[index].state == .pending else { continue }

            let input = items[index].input
            items[index].state = .running(fraction: 0)

            do {
                let result = try await compressor.compress(
                    input: input,
                    settings: settings
                ) { [weak self] update in
                    let fraction = Self.fraction(of: update)
                    Task { @MainActor [weak self] in
                        self?.updateFraction(fraction, for: input.id)
                    }
                }
                items[index].state = .succeeded(result)
                history?.add(input: input, result: result)
            } catch is CancellationError {
                cancelRemaining(from: index)
                break
            } catch AppError.cancelled {
                cancelRemaining(from: index)
                break
            } catch {
                items[index].state = .failed(message: Self.message(for: error))
            }
        }
        phase = .finished
        runTask = nil
    }

    private func cancelRemaining(from index: Int) {
        for cursor in items.indices where cursor >= index && !items[cursor].state.isFinished {
            items[cursor].state = .cancelled
        }
    }

    private func updateFraction(_ fraction: Double, for id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        guard case .running(let current) = items[index].state else { return }
        items[index].state = .running(fraction: max(current, fraction))
    }

    /// `nonisolated` because it is called from the engines' progress callback,
    /// which arrives on whatever thread the engine is using.
    private nonisolated static func fraction(of update: CompressionProgress) -> Double {
        if update.phase == .completed { return 1 }
        return min(max(update.fractionCompleted ?? 0, 0), 1)
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
