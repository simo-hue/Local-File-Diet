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
                    Label("Files stay on your iPhone", systemImage: "iphone")
                    Text("The app stores only local compression history metadata. File names and paths are not logged.")
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
