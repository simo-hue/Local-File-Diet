import SwiftUI

struct SettingsView: View {
    @Environment(\.appEnvironment) private var environment
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppDefaults.defaultTargetPresetKey) private var defaultTargetPreset = TargetSizePreset.forms.rawValue
    @AppStorage(AppDefaults.defaultQualityModeKey) private var defaultQualityMode = QualityMode.balanced.rawValue
    @AppStorage(AppDefaults.stripMetadataKey) private var stripMetadata = true
    @AppStorage(AppDefaults.preferHEICKey) private var preferHEIC = false
    @State private var clearMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Defaults") {
                    Picker("Target size", selection: $defaultTargetPreset) {
                        ForEach(TargetSizePreset.allCases) { preset in
                            Text(preset.title).tag(preset.rawValue)
                        }
                    }
                    Picker("Quality", selection: $defaultQualityMode) {
                        ForEach(QualityMode.allCases) { mode in
                            Text(mode.fullTitle).tag(mode.rawValue)
                        }
                    }
                    Toggle("Remove metadata", isOn: $stripMetadata)
                    Toggle("Prefer HEIC", isOn: $preferHEIC)
                }

                Section("Privacy") {
                    Label("No account", systemImage: "person.crop.circle.badge.xmark")
                    Label("No uploads", systemImage: "icloud.slash")
                    // "Files stay on your iPhone" full stop was more than the app
                    // delivers: every result screen offers a share sheet. The
                    // qualifier matches what privacy.html already says.
                    Label("Files stay on your iPhone unless you share them", systemImage: "iphone")
                    // This used to say file names and paths were not logged, which
                    // the app itself disproves: `HistoryStore` writes both to
                    // Application Support and the home screen shows the names back.
                    // The copy now describes what is actually written, including
                    // the part a reader would otherwise miss - an output is named
                    // "<original name>-compressed-<id>.<ext>", so keeping output
                    // names means keeping the originals' names too.
                    Text("Recent history stays on this iPhone. The last 25 compressions are kept with the output file's name, where it sits in the app's own storage, the file type, the sizes before and after, and the date. Output names are built from your original file names, so those are kept too. Clear, next to Recent on the home screen, erases the list; Clear temporary files below deletes the files it points at.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("App Store") {
                    Link(destination: WebsiteLinks.privacyPolicy) {
                        Label("Privacy Policy", systemImage: "hand.raised")
                    }
                    Link(destination: WebsiteLinks.support) {
                        Label("Support", systemImage: "questionmark.circle")
                    }
                    Link(destination: WebsiteLinks.terms) {
                        Label("Terms of Use", systemImage: "doc.text")
                    }
                }

                Section("Storage") {
                    Button {
                        clearTemporaryFiles()
                    } label: {
                        Label("Clear temporary files", systemImage: "trash")
                    }
                }
                Section("Access") {
                    Label("Unlimited compressions included", systemImage: "infinity")
                    Text("Local File Diet is a paid app. After download, every compression feature is available without accounts, trials, subscriptions, or in-app purchases.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Temporary files", isPresented: Binding(
                get: { clearMessage != nil },
                set: { if !$0 { clearMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(clearMessage ?? "")
            }
        }
    }

    private func clearTemporaryFiles() {
        Task {
            do {
                try await environment.temporaryFileStore.clearAll()
                await MainActor.run {
                    clearMessage = "Temporary files cleared."
                }
            } catch {
                await MainActor.run {
                    clearMessage = "Could not clear temporary files."
                }
            }
        }
    }
}

private enum WebsiteLinks {
    static let privacyPolicy = URL(string: "https://simo-hue.github.io/Local-File-Diet/privacy.html")!
    static let support = URL(string: "https://simo-hue.github.io/Local-File-Diet/support.html")!
    static let terms = URL(string: "https://simo-hue.github.io/Local-File-Diet/terms.html")!
}
