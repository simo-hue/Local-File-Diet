import SwiftUI

/// One set of controls, many files.
///
/// The document picker has always allowed multiple selection; the app then threw
/// away everything but the first file. This is the screen that was missing.
struct BatchReviewView: View {
    @Environment(\.appEnvironment) private var environment
    @Environment(HistoryStore.self) private var historyStore

    @State private var inputs: [CompressionInput]
    @State private var settings: CompressionSettings
    @State private var targetSelection: TargetSelectionState
    @State private var estimates: [UUID: CompressionEstimate] = [:]
    @State private var isEstimating = false
    @State private var estimateToken = 0
    @State private var runner: BatchRunner?

    let onFinished: (BatchOutcome) -> Void

    private static let estimateDebounceNanoseconds: UInt64 = 400_000_000

    init(inputs: [CompressionInput], onFinished: @escaping (BatchOutcome) -> Void) {
        _inputs = State(initialValue: inputs)
        let selection = TargetSelectionState.fromDefaults()
        var defaults = CompressionSettings.fromDefaults()
        defaults.targetSizeBytes = selection.targetSizeBytes
        _settings = State(initialValue: defaults)
        _targetSelection = State(initialValue: selection)
        self.onFinished = onFinished
    }

    var body: some View {
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    filesSection
                    TargetSizeSection(selection: $targetSelection)
                    QualitySection(qualityMode: $settings.qualityMode)
                    OutputSection(settings: $settings, kinds: inputs.map(\.fileKind))
                    AdvancedSettingsSection(settings: $settings)
                    totalsSection
                    compressButton
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(runner?.isRunning == true)

            if let runner, runner.isRunning {
                Color.black.opacity(0.22)
                    .ignoresSafeArea()
                BatchProgressOverlay(runner: runner) {
                    runner.cancel()
                }
            }
        }
        .navigationTitle("\(inputs.count) files")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: targetSelection.targetSizeBytes) { _, newValue in
            settings.targetSizeBytes = newValue
        }
        .task(id: EstimateKey(settings: settings, ids: inputs.map(\.id))) {
            await debouncedEstimate()
        }
        .onChange(of: runner?.phase) { _, phase in
            guard phase == .finished, let runner else { return }
            let outcome = runner.outcome
            if outcome.succeeded.isEmpty {
                // Everything was cancelled before it produced anything; there is
                // nothing to show on a result screen.
                self.runner = nil
            } else {
                onFinished(outcome)
            }
        }
    }

    // MARK: - Files

    private var filesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Files")
                .font(.headline)
            ForEach(inputs) { input in
                BatchFileRow(
                    input: input,
                    estimate: estimates[input.id],
                    canRemove: inputs.count > 1
                ) {
                    remove(input)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func remove(_ input: CompressionInput) {
        inputs.removeAll { $0.id == input.id }
        estimates[input.id] = nil
    }

    // MARK: - Totals

    private var totalOriginalBytes: Int64 {
        inputs.reduce(0) { $0 + $1.originalSizeBytes }
    }

    /// Files without an estimate yet count as themselves, so the total only ever
    /// improves as the estimates land instead of jumping around.
    private var estimatedTotalBytes: Int64 {
        inputs.reduce(0) { total, input in
            total + (estimates[input.id]?.estimatedSizeBytes ?? input.originalSizeBytes)
        }
    }

    private var totalsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Total")
                    .font(.headline)
                Spacer()
                if isEstimating {
                    ProgressView()
                }
            }
            HStack {
                Label(FileSizeFormat.string(from: totalOriginalBytes), systemImage: "internaldrive")
                Spacer()
                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(FileSizeFormat.string(from: estimatedTotalBytes))
                    .font(.subheadline.weight(.semibold))
            }
            .font(.subheadline)
            Text(estimates.count == inputs.count
                 ? "Estimated across all \(inputs.count) files."
                 : "Estimating \(estimates.count) of \(inputs.count)...")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var compressButton: some View {
        Button {
            startBatch()
        } label: {
            Label(
                inputs.count == 1 ? "Compress 1 file" : "Compress \(inputs.count) files",
                systemImage: "arrow.down.circle.fill"
            )
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(inputs.isEmpty || runner?.isRunning == true)
        .accessibilityIdentifier("batch-compress-button")
    }

    // MARK: - Work

    /// The id for the estimate task: the settings plus which files are still in
    /// the batch. Removing a file must re-total, changing a toggle must re-plan.
    private struct EstimateKey: Equatable {
        let settings: CompressionSettings
        let ids: [UUID]
    }

    private func debouncedEstimate() async {
        estimateToken &+= 1
        let token = estimateToken
        do {
            try await Task.sleep(nanoseconds: Self.estimateDebounceNanoseconds)
        } catch {
            return
        }
        guard !Task.isCancelled, token == estimateToken else { return }

        isEstimating = true
        defer {
            if token == estimateToken {
                isEstimating = false
            }
        }
        estimates = [:]
        // Sequential on purpose, for the same reason the run itself is: these
        // estimates now do real work.
        for input in inputs {
            guard !Task.isCancelled, token == estimateToken else { return }
            let value = try? await environment.compressionRouter.estimate(input: input, settings: settings)
            guard !Task.isCancelled, token == estimateToken else { return }
            if let value {
                estimates[input.id] = value
            }
        }
    }

    private func startBatch() {
        let runner = BatchRunner(
            inputs: inputs,
            settings: settings,
            compressor: RouterBatchCompressor(router: environment.compressionRouter),
            history: historyStore
        )
        self.runner = runner
        runner.start()
    }
}

// MARK: - Rows

private struct BatchFileRow: View {
    let input: CompressionInput
    let estimate: CompressionEstimate?
    let canRemove: Bool
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: input.fileKind.symbolName)
                .font(.title3)
                .frame(width: 30)
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 4) {
                Text(input.originalFilename)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let plan = estimate?.warnings.first(where: { $0.isVideoOutputPlan }) {
                    Text(plan.title)
                        .font(.caption2)
                        .foregroundStyle(Color.accentColor)
                }
            }

            Spacer(minLength: 0)

            if canRemove {
                Button(role: .destructive) {
                    onRemove()
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Remove \(input.originalFilename)")
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var detailText: String {
        let original = FileSizeFormat.string(from: input.originalSizeBytes)
        guard let estimated = estimate?.estimatedSizeBytes else { return original }
        return "\(original) → about \(FileSizeFormat.string(from: estimated))"
    }
}

// MARK: - Progress

private struct BatchProgressOverlay: View {
    let runner: BatchRunner
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Text("Compressing \(runner.totalCount) files")
                .font(.title3.weight(.semibold))

            ProgressView(value: runner.overallProgress)
                .progressViewStyle(.linear)

            Text("\(runner.completedCount) of \(runner.totalCount) done")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let current = runner.currentItem {
                Text(current.input.originalFilename)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Label("Your original files stay untouched.", systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button(role: .cancel) {
                onCancel()
            } label: {
                Label("Cancel", systemImage: "xmark.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .padding(24)
        .frame(maxWidth: 360)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadow(color: .black.opacity(0.22), radius: 28, y: 12)
        .padding()
    }
}
