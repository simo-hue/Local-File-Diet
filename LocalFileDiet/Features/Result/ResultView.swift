import SwiftUI

struct ResultView: View {
    @State private var showShareSheet = false
    @State private var showExporter = false
    @State private var photoSaveMessage: String?
    @State private var isSavingToPhotos = false

    let input: CompressionInput
    let result: CompressionResult
    let settings: CompressionSettings
    let onTryAgain: (CompressionInput) -> Void
    let onStartNewImport: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                statusHeader
                FilePreviewView(url: result.outputURL, kind: input.fileKind)
                metrics
                warnings
                actions
                footerNote
            }
            .padding()
        }
        .navigationTitle("Result")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(activityItems: [result.outputURL])
        }
        .sheet(isPresented: $showExporter) {
            DocumentExporter(urls: [result.outputURL]) {
                showExporter = false
            }
        }
        .alert("Photos", isPresented: Binding(
            get: { photoSaveMessage != nil },
            set: { if !$0 { photoSaveMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(photoSaveMessage ?? "")
        }
    }

    private var statusHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(result.targetReached ? "Target reached" : "Target not reached", systemImage: result.targetReached ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.title2.weight(.bold))
                .foregroundStyle(result.targetReached ? .green : .orange)
            Text(result.outputFilename)
                .font(.headline)
                .lineLimit(2)
        }
    }

    private var metrics: some View {
        VStack(spacing: 14) {
            MetricRow(title: "Original", value: FileSizeFormat.string(from: result.originalSizeBytes), systemImage: "doc")
            MetricRow(title: "Compressed", value: FileSizeFormat.string(from: result.compressedSizeBytes), systemImage: "arrow.down.doc")
            MetricRow(title: "Reduction", value: FileSizeFormat.percent(result.reductionPercent), systemImage: "chart.line.downtrend.xyaxis")
            MetricRow(title: "Time", value: String(format: "%.1fs", result.durationSeconds), systemImage: "timer")
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private var warnings: some View {
        if !result.warnings.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Notes")
                    .font(.headline)
                ForEach(result.warnings) { warning in
                    Label {
                        Text(warning.message)
                            .font(.subheadline)
                    } icon: {
                        Image(systemName: warning.severity == .info ? "info.circle" : "exclamationmark.triangle")
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 12) {
            Button {
                showShareSheet = true
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button {
                showExporter = true
            } label: {
                Label("Save to Files", systemImage: "folder.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            if input.fileKind == .image || input.fileKind == .video {
                Button {
                    saveToPhotos()
                } label: {
                    Label(isSavingToPhotos ? "Saving..." : "Save to Photos", systemImage: "photo.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(isSavingToPhotos)
            }

            HStack {
                Button("Try Smaller") {
                    onTryAgain(input)
                }
                .buttonStyle(.bordered)

                Button("Better Quality") {
                    onTryAgain(input)
                }
                .buttonStyle(.bordered)
            }

            Button {
                onStartNewImport()
            } label: {
                Label("Start New Import", systemImage: "house")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }

    private var footerNote: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Everything was processed locally on your iPhone.", systemImage: "lock.shield")
            Label("Original file was not changed.", systemImage: "doc.badge.ellipsis")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    private func saveToPhotos() {
        isSavingToPhotos = true
        Task {
            do {
                try await PhotoLibrarySaver.save(url: result.outputURL, kind: input.fileKind)
                await MainActor.run {
                    isSavingToPhotos = false
                    photoSaveMessage = "Saved to Photos."
                }
            } catch {
                await MainActor.run {
                    isSavingToPhotos = false
                    photoSaveMessage = "Could not save to Photos."
                }
            }
        }
    }
}

private struct MetricRow: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        HStack {
            Label(title, systemImage: systemImage)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.headline)
        }
    }
}
