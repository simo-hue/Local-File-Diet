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

    let onImported: (CompressionInput) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                importPanel
                recentSection
                privacyNote
            }
            .padding()
        }
        .navigationTitle("Local File Diet")
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
            if let input = try? await environment.fileImportService.importSharedFileIfAvailable() {
                onImported(input)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image("Logo")
                .resizable()
                .scaledToFit()
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            Text("Make files smaller. Everything stays on your iPhone.")
                .font(.title2.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text("Compress images, PDFs, videos, and ZIP packages locally. Originals are never changed.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var importPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(spacing: 10) {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 38, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.accentColor)
                Text(isImporting ? "Importing..." : "Choose a file to compress")
                    .font(.headline)
                Text("PDF, image, video, or ZIP")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            Button {
                showDocumentPicker = true
            } label: {
                Label("Import from Files", systemImage: "folder")
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
        }
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

                ForEach(historyStore.items.prefix(3)) { item in
                    RecentFileRow(item: item)
                        .swipeActions {
                            Button("Delete", role: .destructive) {
                                historyStore.delete(item)
                            }
                        }
                }
            }
        }
    }

    private var privacyNote: some View {
        Label("No uploads. No account. No tracking.", systemImage: "lock.shield")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func importURLs(_ urls: [URL]) {
        guard let url = urls.first else { return }
        isImporting = true
        Task {
            defer { Task { @MainActor in isImporting = false } }
            do {
                let input = try await environment.fileImportService.importFile(from: url)
                await MainActor.run {
                    onImported(input)
                }
            } catch {
                await MainActor.run {
                    errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
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
                    errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
    }
}

private struct RecentFileRow: View {
    let item: CompressionHistoryItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .frame(width: 30)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.outputFilename)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text("\(FileSizeFormat.string(from: item.originalSizeBytes)) → \(FileSizeFormat.string(from: item.compressedSizeBytes))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(FileSizeFormat.percent(item.reductionPercent))
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

    private var icon: String {
        switch item.fileKind {
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .video: "video"
        case .archive: "archivebox"
        case .unsupported: "questionmark.document"
        }
    }
}
