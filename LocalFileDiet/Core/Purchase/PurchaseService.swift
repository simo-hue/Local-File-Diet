import Foundation
import Observation
import StoreKit

@Observable
final class PurchaseService: @unchecked Sendable {
    private(set) var products: [Product] = []
    private(set) var isUnlocked = false
    private(set) var isLoading = false
    var lastErrorMessage: String?
    private(set) var usedCompressionCount: Int

    let freeLimit = 20
    private let productIDs = ["localfilediet.lifetime"]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.usedCompressionCount = defaults.integer(forKey: "usedCompressionCount")
        self.isUnlocked = defaults.bool(forKey: "lifetimeUnlocked")
    }

    var remainingFreeCompressions: Int {
        max(0, freeLimit - usedCompressionCount)
    }

    var isCompressionAllowed: Bool {
        #if DEBUG
        true
        #else
        isUnlocked || usedCompressionCount < freeLimit
        #endif
    }

    var lifetimeProduct: Product? {
        products.first
    }

    @MainActor
    func loadProducts() async {
        guard products.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            products = try await Product.products(for: productIDs)
            await updatePurchasedProducts()
        } catch {
            lastErrorMessage = "Purchases are not available right now."
            AppLogger.purchase.error("storekit_load_failed")
        }
    }

    @MainActor
    func purchaseLifetime() async throws {
        guard let product = lifetimeProduct else {
            throw AppError.purchaseUnavailable
        }
        let result = try await product.purchase()
        switch result {
        case .success(let verification):
            let transaction = try checkVerified(verification)
            await transaction.finish()
            setUnlocked(true)
        case .pending, .userCancelled:
            break
        @unknown default:
            break
        }
    }

    @MainActor
    func restorePurchases() async {
        do {
            try await AppStore.sync()
            await updatePurchasedProducts()
        } catch {
            lastErrorMessage = "Could not restore purchases."
        }
    }

    @MainActor
    func recordCompression() {
        guard !isUnlocked else { return }
        usedCompressionCount += 1
        defaults.set(usedCompressionCount, forKey: "usedCompressionCount")
    }

    @MainActor
    private func updatePurchasedProducts() async {
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result,
               productIDs.contains(transaction.productID),
               transaction.revocationDate == nil {
                setUnlocked(true)
                return
            }
        }
    }

    @MainActor
    private func setUnlocked(_ value: Bool) {
        isUnlocked = value
        defaults.set(value, forKey: "lifetimeUnlocked")
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let safe):
            safe
        case .unverified:
            throw AppError.purchaseUnavailable
        }
    }
}
