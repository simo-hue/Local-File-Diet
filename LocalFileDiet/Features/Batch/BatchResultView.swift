import SwiftUI

struct BatchResultView: View {
    @Environment(\.appEnvironment) private var environment

    @State private var showShareSheet = false
    @State private var showExporter = false
    @State private var archiveURL: URL?
    @State private var isBuildingArchive = false
    @State private var archiveProgress: Double = 0
    @State private var archiveError: String?

    let outcome: BatchOutcome
    let onStartNewImport: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                headline
                fileList
                failures
                actions
                footerNote
            }
            .padding()
        }
        .navigationTitle("Result")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(activityItems: outcome.outputURLs)
        }
        .sheet(isPresented: $showExporter) {
            DocumentExporter(urls: outcome.outputURLs) {
                showExporter = false
            }
        }
        .sheet(item: Binding(
            get: { archiveURL.map(ArchiveTarget.init(url:)) },
            set: { if $0 == nil { archiveURL = nil } }
        )) { target in
            ShareSheet(activityItems: [target.url])
        }
        .alert("Could not build the ZIP", isPresented: Binding(
            get: { archiveError != nil },
            set: { if !$0 { archiveError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(archiveError ?? "")
        }
    }

    // MARK: - Headline

    private var headline: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(FileSizeFormat.string(from: outcome.totalSavedBytes))
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(outcome.totalSavedBytes > 0 ? Color.green : Color.primary)
                .accessibilityIdentifier("batch-total-saved")
            Text("saved across \(outcome.succeeded.count) of \(outcome.entries.count) files")
                .font(.headline)
            Text("\(FileSizeFormat.string(from: outcome.totalOriginalBytes)) → \(FileSizeFormat.string(from: outcome.totalCompressedBytes)) (\(FileSizeFormat.percent(outcome.totalReductionPercent)) smaller)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Per file

    private var fileList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Files")
                .font(.headline)
            ForEach(outcome.succeeded) { entry in
                if let result = entry.result {
                    HStack(spacing: 12) {
                        Image(systemName: entry.input.fileKind.symbolName)
                            .font(.title3)
                            .frame(width: 30)
                            .foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(result.outputFilename)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Text("\(FileSizeFormat.string(from: result.originalSizeBytes)) → \(FileSizeFormat.string(from: result.compressedSizeBytes))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Text(FileSizeFormat.percent(result.reductionPercent))
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color(.tertiarySystemFill))
                            .clipShape(Capsule())
                    }
                    .padding(12)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
    }

    @ViewBuilder
    private var failures: some View {
        let failed = outcome.failed
        let cancelled = outcome.cancelled
        if !failed.isEmpty || !cancelled.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Not compressed")
                    .font(.headline)
                ForEach(failed) { entry in
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.input.originalFilename)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Text(entry.failureMessage ?? "This file could not be compressed.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
                ForEach(cancelled) { entry in
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.input.originalFilename)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Text("Cancelled before this file was compressed.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "xmark.circle")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(spacing: 12) {
            Button {
                showShareSheet = true
            } label: {
                Label("Share all", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(outcome.outputURLs.isEmpty)

            Button {
                showExporter = true
            } label: {
                Label("Save all to Files", systemImage: "folder.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(outcome.outputURLs.isEmpty)

            Button {
                buildArchive()
            } label: {
                Label(isBuildingArchive ? "Building ZIP..." : "Save all as ZIP", systemImage: "archivebox")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(outcome.outputURLs.isEmpty || isBuildingArchive)
            .accessibilityIdentifier("batch-zip-button")

            if isBuildingArchive {
                ProgressView(value: archiveProgress)
                    .progressViewStyle(.linear)
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
            Label("Original files were not changed.", systemImage: "doc.badge.ellipsis")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    // MARK: - ZIP

    /// Reading and deflating happens inside `BatchArchive`, which is a plain
    /// `async` function and therefore runs off the main actor: the UI keeps
    /// drawing the progress bar while a pile of files is packed.
    private func buildArchive() {
        let entries = outcome.succeeded.compactMap { entry -> BatchArchive.Entry? in
            guard let result = entry.result else { return nil }
            return BatchArchive.Entry(filename: result.outputFilename, url: result.outputURL)
        }
        guard !entries.isEmpty else { return }

        isBuildingArchive = true
        archiveProgress = 0
        Task {
            do {
                let destination = try await environment.temporaryFileStore.makeOutputURL(
                    originalFilename: BatchArchive.archiveName(for: entries),
                    extension: "zip"
                )
                let url = try await BatchArchive.writeOffMainActor(entries: entries, to: destination) { fraction in
                    Task { @MainActor in
                        archiveProgress = fraction
                    }
                }
                await MainActor.run {
                    isBuildingArchive = false
                    archiveProgress = 1
                    archiveURL = url
                }
            } catch {
                await MainActor.run {
                    isBuildingArchive = false
                    archiveError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
    }
}

/// `sheet(item:)` needs something identifiable; a bare URL is not.
private struct ArchiveTarget: Identifiable {
    let url: URL
    var id: String { url.path }
}
