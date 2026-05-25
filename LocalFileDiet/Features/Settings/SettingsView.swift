import SwiftUI

struct SettingsView: View {
    @Environment(\.appEnvironment) private var environment
    @Environment(PurchaseService.self) private var purchaseService
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppDefaults.defaultTargetPresetKey) private var defaultTargetPreset = TargetSizePreset.forms.rawValue
    @AppStorage(AppDefaults.defaultQualityModeKey) private var defaultQualityMode = QualityMode.balanced.rawValue
    @AppStorage(AppDefaults.stripMetadataKey) private var stripMetadata = true
    @AppStorage(AppDefaults.preferHEICKey) private var preferHEIC = false
    @State private var showPaywall = false
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

                Section("Storage") {
                    Button {
                        clearTemporaryFiles()
                    } label: {
                        Label("Clear temporary files", systemImage: "trash")
                    }
                }

                Section("Purchase") {
                    HStack {
                        Label(purchaseService.isUnlocked ? "Lifetime unlocked" : "Free trial", systemImage: purchaseService.isUnlocked ? "checkmark.seal" : "timer")
                        Spacer()
                        if !purchaseService.isUnlocked {
                            Text("\(purchaseService.remainingFreeCompressions) left")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button("Unlock unlimited compression") {
                        showPaywall = true
                    }
                    .disabled(purchaseService.isUnlocked)
                    Button("Restore purchases") {
                        Task { await purchaseService.restorePurchases() }
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showPaywall) {
                PaywallView()
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
