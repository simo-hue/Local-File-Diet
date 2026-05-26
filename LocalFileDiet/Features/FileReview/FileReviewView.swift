import SwiftUI

struct FileReviewView: View {
    @Environment(\.appEnvironment) private var environment
    @Environment(HistoryStore.self) private var historyStore
    @State private var settings = CompressionSettings.fromDefaults()
    @State private var selectedPreset: TargetSizePreset = .forms
    @State private var customTarget = ""
    @State private var customUnit: SizeUnit = .mb
    @State private var estimate: CompressionEstimate?
    @State private var isEstimating = false
    @State private var progress: CompressionProgress?
    @State private var compressionTask: Task<Void, Never>?
    @State private var errorMessage: String?

    let input: CompressionInput
    let onResult: (CompressionResult, CompressionSettings) -> Void

    var body: some View {
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    FilePreviewView(url: input.workingURL, kind: input.fileKind)
                    metadataSection
                    targetSection
                    qualitySection
                    outputSection
                    advancedSection
                    estimateSection
                    compressButton
                }
                .padding()
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
        .task(id: settings) {
            await updateEstimate()
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
                Label(input.fileKind.displayName, systemImage: kindIcon)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    private var targetSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Target size")
                .font(.headline)
            Picker("Preset", selection: $selectedPreset) {
                ForEach(TargetSizePreset.allCases) { preset in
                    Text(preset.title).tag(preset)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: selectedPreset) { _, preset in
                settings.targetSizeBytes = preset.bytes
            }

            HStack {
                TextField("Custom size", text: $customTarget)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(applyCustomTarget)
                    .onChange(of: customTarget) { _, _ in applyCustomTarget() }
                Picker("Unit", selection: $customUnit) {
                    ForEach(SizeUnit.allCases) { unit in
                        Text(unit.rawValue).tag(unit)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 120)
                .onChange(of: customUnit) { _, _ in applyCustomTarget() }
            }
            Text("Current target: \(settings.targetSizeBytes.map(FileSizeFormat.string(from:)) ?? "No limit")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var qualitySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quality")
                .font(.headline)
            Picker("Quality", selection: $settings.qualityMode) {
                ForEach(QualityMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Output")
                .font(.headline)
            Picker("Format", selection: $settings.outputFormat) {
                ForEach(availableOutputFormats) { format in
                    Text(format.title).tag(format)
                }
            }
            .pickerStyle(.menu)

            if input.fileKind == .video {
                Picker("Resolution", selection: Binding(
                    get: { settings.videoResolutionPreset ?? .auto },
                    set: { settings.videoResolutionPreset = $0 }
                )) {
                    ForEach(VideoResolutionPreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
    }

    private var advancedSection: some View {
        DisclosureGroup("Advanced") {
            VStack(spacing: 14) {
                Toggle("Remove metadata", isOn: $settings.stripMetadata)
                Toggle("Preserve transparency when possible", isOn: $settings.preserveTransparency)
                Toggle("Prefer smaller modern format", isOn: $settings.preferHEICWhenAvailable)
                Toggle("Allow resolution downscale", isOn: $settings.allowResolutionDownscale)
            }
            .font(.subheadline)
            .padding(.top, 8)
        }
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

                ForEach(estimate.warnings) { warning in
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

    private var kindIcon: String {
        switch input.fileKind {
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .video: "video"
        case .archive: "archivebox"
        case .unsupported: "questionmark.document"
        }
    }

    private var availableOutputFormats: [OutputFormat] {
        switch input.fileKind {
        case .image:
            [.automatic, .jpeg, .heic, .png, .pdf]
        case .pdf:
            [.automatic, .pdf]
        case .video:
            [.automatic, .mp4, .mov]
        case .archive:
            [.zip]
        case .unsupported:
            [.automatic]
        }
    }

    private func applyCustomTarget() {
        if let parsed = TargetSizeParser.parse(customTarget, unit: customUnit) {
            settings.targetSizeBytes = parsed
        }
    }

    private func updateEstimate() async {
        isEstimating = true
        defer { isEstimating = false }
        do {
            estimate = try await environment.compressionRouter.estimate(input: input, settings: settings)
        } catch {
            estimate = nil
        }
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

private struct WarningRow: View {
    let warning: CompressionWarning

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(warning.title)
                    .font(.caption.weight(.semibold))
                Text(warning.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: warning.severity == .blocking ? "xmark.octagon" : "exclamationmark.triangle")
                .foregroundStyle(warning.severity == .info ? Color.secondary : Color.orange)
        }
        .padding(10)
        .background(Color(.tertiarySystemFill))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
