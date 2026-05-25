import SwiftUI

struct PaywallView: View {
    @Environment(PurchaseService.self) private var purchaseService
    @Environment(\.dismiss) private var dismiss
    @State private var isPurchasing = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    Image("Logo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    Text("Unlock unlimited local compression")
                        .font(.title.bold())
                    Text("Keep files private and compress without limits on this device.")
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 14) {
                    PaywallBullet(title: "Unlimited files", systemImage: "infinity")
                    PaywallBullet(title: "Batch and ZIP workflows", systemImage: "archivebox")
                    PaywallBullet(title: "Custom presets", systemImage: "slider.horizontal.3")
                    PaywallBullet(title: "No account. No uploads.", systemImage: "lock.shield")
                    PaywallBullet(title: "One-time purchase", systemImage: "checkmark.seal")
                }

                Spacer()

                Button {
                    Task { await buy() }
                } label: {
                    Label(priceTitle, systemImage: "creditcard")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isPurchasing)

                Button("Restore Purchases") {
                    Task {
                        await purchaseService.restorePurchases()
                        if purchaseService.isUnlocked { dismiss() }
                    }
                }
                .frame(maxWidth: .infinity)

                Button("Not now") {
                    dismiss()
                }
                .frame(maxWidth: .infinity)
                .foregroundStyle(.secondary)
            }
            .padding()
            .navigationTitle("Local File Diet Pro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await purchaseService.loadProducts() }
        }
    }

    private var priceTitle: String {
        if isPurchasing { return "Purchasing..." }
        if let product = purchaseService.lifetimeProduct {
            return "Buy Lifetime - \(product.displayPrice)"
        }
        return "Buy Lifetime"
    }

    private func buy() async {
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            try await purchaseService.purchaseLifetime()
            if purchaseService.isUnlocked { dismiss() }
        } catch {
            purchaseService.lastErrorMessage = error.localizedDescription
        }
    }
}

private struct PaywallBullet: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
            .foregroundStyle(.primary)
    }
}
