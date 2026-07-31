import SwiftUI

struct FileReviewView: View {
    @Environment(\.appEnvironment) private var environment
    @Environment(HistoryStore.self) private var historyStore
    @State private var settings: CompressionSettings
    @State private var targetSelection: TargetSelectionState
    @State private var estimate: CompressionEstimate?
    @State private var isEstimating = false
    /// Guards against a slow estimate landing after a newer one. Every run takes
    /// a token; only the run still holding the current token may publish.
    @State private var estimateToken = 0
    @State private var progress: CompressionProgress?
    @State private var compressionTask: Task<Void, Never>?
    @State private var errorMessage: String?

    let input: CompressionInput
    let onResult: (CompressionResult, CompressionSettings) -> Void

    /// Estimating now costs real work — a probe encode for images, a content
    /// parse for PDFs — so it waits for the controls to stop moving.
    private static let estimateDebounceNanoseconds: UInt64 = 300_000_000

    init(
        input: CompressionInput,
        startingSettings: CompressionSettings? = nil,
        onResult: @escaping (CompressionResult, CompressionSettings) -> Void
    ) {
        self.input = input
        self.onResult = onResult
        if let startingSettings {
            // Arrived from "Try Smaller" / "Better Quality": the picker has to
            // show the target that was handed to us, not the saved default.
            _settings = State(initialValue: startingSettings)
            _targetSelection = State(initialValue: TargetSelectionState(targetBytes: startingSettings.targetSizeBytes))
        } else {
            let selection = TargetSelectionState.fromDefaults()
            var defaults = CompressionSettings.fromDefaults()
            defaults.targetSizeBytes = selection.targetSizeBytes
            _settings = State(initialValue: defaults)
            _targetSelection = State(initialValue: selection)
        }
    }

    var body: some View {
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    FilePreviewView(url: input.workingURL, kind: input.fileKind)
                    metadataSection
                    TargetSizeSection(selection: $targetSelection)
                    QualitySection(qualityMode: $settings.qualityMode)
                    OutputSection(settings: $settings, kinds: [input.fileKind])
                    AdvancedSettingsSection(settings: $settings)
                    estimateSection
                    compressButton
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(progress != nil)

            if let progress {
                Color.black.opacity(0.22)
                    .ignoresSafeArea()
                CompressionProgressView(progress: progress) {
                    compressionTask?.cancel()
                }
            }
        }
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: targetSelection.targetSizeBytes) { _, newValue in
            settings.targetSizeBytes = newValue
        }
        .task(id: settings) {
            await debouncedEstimate()
        }
        .alert("Compression failed", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .onDisappear {
            compressionTask?.cancel()
        }
    }

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(input.originalFilename)
                .font(.title3.weight(.semibold))
                .lineLimit(2)
            HStack {
                Label(FileSizeFormat.string(from: input.originalSizeBytes), systemImage: "internaldrive")
                Spacer()
                Label(input.fileKind.displayName, systemImage: input.fileKind.symbolName)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    /// The video engine's planned resolution and codec, promoted out of the
    /// warning list: it is the most useful thing on this screen for a video and
    /// it belongs before the compression, not after it.
    private var videoPlanWarning: CompressionWarning? {
        estimate?.warnings.first { $0.isVideoOutputPlan }
    }

    private var otherWarnings: [CompressionWarning] {
        (estimate?.warnings ?? []).filter { !$0.isVideoOutputPlan }
    }

    @ViewBuilder
    private var estimateSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Plan")
                    .font(.headline)
                Spacer()
                if isEstimating {
                    ProgressView()
                }
            }

            if let estimate {
                if let videoPlanWarning {
                    VideoOutputPlanRow(warning: videoPlanWarning)
                }

                HStack {
                    Label(estimate.predictedQuality.title, systemImage: "sparkle.magnifyingglass")
                    Spacer()
                    if let estimatedSize = estimate.estimatedSizeBytes {
                        Text(FileSizeFormat.string(from: estimatedSize))
                            .font(.subheadline.weight(.semibold))
                    }
                }
                .font(.subheadline)

                ForEach(estimate.plannedOperations) { operation in
                    Label(operation.title, systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ForEach(otherWarnings) { warning in
                    WarningRow(warning: warning)
                }
            } else {
                Text("Estimate will appear here before compression.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var compressButton: some View {
        Button {
            startCompression()
        } label: {
            Label("Compress", systemImage: "arrow.down.circle.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(progress != nil || input.fileKind == .unsupported)
        .accessibilityIdentifier("compress-button")
    }

    /// Waits for the controls to settle, then estimates — and refuses to publish
    /// if a newer run has started in the meantime.
    private func debouncedEstimate() async {
        estimateToken &+= 1
        let token = estimateToken
        do {
            try await Task.sleep(nanoseconds: Self.estimateDebounceNanoseconds)
        } catch {
            return // superseded or the view went away
        }
        guard !Task.isCancelled, token == estimateToken else { return }

        isEstimating = true
        defer {
            if token == estimateToken {
                isEstimating = false
            }
        }
        let next = try? await environment.compressionRouter.estimate(input: input, settings: settings)
        guard !Task.isCancelled, token == estimateToken else { return }
        estimate = next
    }

    private func startCompression() {
        compressionTask?.cancel()
        progress = .preparing
        compressionTask = Task {
            do {
                let result = try await environment.compressionRouter.compress(input: input, settings: settings) { update in
                    Task { @MainActor in
                        progress = ProgressPresentation.smoothed(current: progress, next: update)
                    }
                }
                await MainActor.run {
                    progress = nil
                    historyStore.add(input: input, result: result)
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    onResult(result, settings)
                }
            } catch is CancellationError {
                await MainActor.run {
                    progress = nil
                    UINotificationFeedbackGenerator().notificationOccurred(.warning)
                }
            } catch {
                await MainActor.run {
                    progress = nil
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                    errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
    }
}
