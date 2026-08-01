import PhotosUI
import SwiftUI

struct HomeView: View {
    @Environment(\.appEnvironment) private var environment
    @Environment(HistoryStore.self) private var historyStore
    @State private var showDocumentPicker = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var isImporting = false
    @State private var errorMessage: String?
    @State private var showSettings = false
    @State private var shareTarget: RecentShareTarget?

    let onImported: (CompressionInput) -> Void
    let onImportedBatch: ([CompressionInput]) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .center, spacing: 28) {
                header
                importPanel
                recentSection
                privacyNote
            }
            .padding()
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
            }
        }
        .sheet(isPresented: $showDocumentPicker) {
            DocumentPicker(allowsMultipleSelection: true) { urls in
                showDocumentPicker = false
                importURLs(urls)
            } onCancel: {
                showDocumentPicker = false
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(item: $shareTarget) { target in
            ShareSheet(activityItems: [target.url])
        }
        .alert("Import failed", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .onChange(of: selectedPhotoItem) { _, item in
            guard let item else { return }
            importPhoto(item)
        }
        .task {
            let inputs = (try? await environment.fileImportService.importSharedFilesIfAvailable()) ?? []
            deliver(inputs)
        }
    }

    private var header: some View {
        VStack(spacing: 18) {
            Image("Logo")
                .resizable()
                .scaledToFit()
                .frame(width: 190, height: 190)
                .accessibilityLabel("Local File Diet")

            Text("Compress images, PDFs, and videos to the size you need.")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            // Kept in step with the Settings > Privacy wording. The unqualified
            // "everything stays on your iPhone" was more than the app delivers,
            // because every result screen offers a share sheet.
            Text("Compression happens on your iPhone, and nothing is uploaded. Originals are never changed.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
    }

    private var importPanel: some View {
        VStack(spacing: 12) {
            Button {
                showDocumentPicker = true
            } label: {
                Label(isImporting ? "Importing..." : "Import from Files", systemImage: "folder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isImporting)

            PhotosPicker(selection: $selectedPhotoItem, matching: .any(of: [.images, .videos])) {
                Label("Pick Photo or Video", systemImage: "photo.on.rectangle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(isImporting)

            Text("PDF, image, video, or ZIP. Pick several files to compress them all in one go.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var recentSection: some View {
        if !historyStore.items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Recent")
                        .font(.headline)
                    Spacer()
                    Button("Clear") {
                        historyStore.clear()
                    }
                    .font(.subheadline)
                }

                // `.swipeActions` used to live here, which does nothing outside a
                // `List`: swipe-to-delete on this screen had never worked. Each
                // row now carries a visible delete control and a context menu.
                ForEach(historyStore.items.prefix(3)) { item in
                    RecentFileRow(item: item) {
                        guard let url = item.availableOutputURL else { return }
                        shareTarget = RecentShareTarget(id: item.id, url: url)
                    } onDelete: {
                        historyStore.delete(item)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var privacyNote: some View {
        Label("No uploads. No account. No tracking.", systemImage: "lock.shield")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Import

    private func importURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        isImporting = true
        Task {
            var imported: [CompressionInput] = []
            var firstError: Error?
            for url in urls {
                do {
                    imported.append(try await environment.fileImportService.importFile(from: url))
                } catch {
                    firstError = firstError ?? error
                }
            }
            await MainActor.run {
                isImporting = false
                if imported.isEmpty {
                    errorMessage = firstError.map(Self.message(for:)) ?? AppError.importFailed.errorDescription
                    return
                }
                if imported.count < urls.count {
                    // Filenames and paths are never logged; the count is enough
                    // to tell a partial import from a clean one.
                    AppLogger.importFlow.error("batch_import_partial failed=\(urls.count - imported.count, privacy: .public)")
                }
                deliver(imported)
            }
        }
    }

    /// One file behaves exactly as it always has. Several files go to the batch
    /// screen instead of being silently thrown away.
    private func deliver(_ inputs: [CompressionInput]) {
        guard !inputs.isEmpty else { return }
        if inputs.count == 1, let input = inputs.first {
            onImported(input)
        } else {
            onImportedBatch(inputs)
        }
    }

    private func importPhoto(_ item: PhotosPickerItem) {
        isImporting = true
        Task {
            defer { Task { @MainActor in isImporting = false; selectedPhotoItem = nil } }
            do {
                guard let media = try await item.loadTransferable(type: PickedMediaFile.self) else {
                    throw AppError.importFailed
                }
                let input = try await environment.fileImportService.importPhotoFile(from: media.url, suggestedName: media.suggestedFilename)
                await MainActor.run {
                    onImported(input)
                }
            } catch {
                await MainActor.run {
                    errorMessage = Self.message(for: error)
                }
            }
        }
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

private struct RecentShareTarget: Identifiable {
    let id: UUID
    let url: URL
}

extension CompressionHistoryItem {
    /// Outputs live in Caches and are pruned after 24 hours, so a history row can
    /// easily point at a file that is no longer there. The UI has to check
    /// before it offers to share it.
    var availableOutputURL: URL? {
        guard let sandboxURL, FileManager.default.fileExists(atPath: sandboxURL.path) else { return nil }
        return sandboxURL
    }
}

private struct RecentFileRow: View {
    let item: CompressionHistoryItem
    let onShare: () -> Void
    let onDelete: () -> Void

    private var isAvailable: Bool { item.availableOutputURL != nil }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onShare) {
                HStack(spacing: 12) {
                    Image(systemName: item.fileKind.symbolName)
                        .font(.title3)
                        .frame(width: 30)
                        .foregroundStyle(isAvailable ? Color.accentColor : Color.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.outputFilename)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        if isAvailable {
                            Text("\(FileSizeFormat.string(from: item.originalSizeBytes)) → \(FileSizeFormat.string(from: item.compressedSizeBytes))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("File no longer available")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                    Text(FileSizeFormat.percent(item.reductionPercent))
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(.tertiarySystemFill))
                        .clipShape(Capsule())
                    if isAvailable {
                        Image(systemName: "square.and.arrow.up")
                            .font(.footnote)
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!isAvailable)
            .accessibilityLabel(isAvailable
                                ? "Share \(item.outputFilename)"
                                : "\(item.outputFilename), file no longer available")

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .font(.footnote)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Delete \(item.outputFilename)")
            .accessibilityIdentifier("recent-delete-button")
        }
        .padding(12)
        .opacity(isAvailable ? 1 : 0.55)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contextMenu {
            if isAvailable {
                Button {
                    onShare()
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}
