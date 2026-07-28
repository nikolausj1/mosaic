// Sources/App/Store/StoreService.swift
// B8's StoreKit 2 service: loads the single non-consumable ("remove
// watermark"), drives purchase/restore, and derives entitlement from
// Transaction.currentEntitlement (the source of truth - already reflects
// refunds/family-sharing/revocations). UserDefaults only caches the
// last-known answer so the export path and the picker's gear icon have an
// instant, synchronous answer at cold launch, before StoreKit has had a
// chance to answer for real - `start()` reconciles it against the real
// entitlement shortly after.
import Foundation
import StoreKit

@Observable
@MainActor
final class StoreService {
    static let productID = "com.levelup.mosaic.removewatermark"
    private static let cachedUnlockKey = "storeService.isUnlocked.cache"

    private(set) var product: Product?
    private(set) var isUnlocked: Bool
    private(set) var isPurchasing = false
    var purchaseError: String?

    private var updatesTask: Task<Void, Never>?

    init() {
        isUnlocked = UserDefaults.standard.bool(forKey: Self.cachedUnlockKey)
    }

    /// Call once at launch (ContentView's `.task`). Starts the long-lived
    /// `Transaction.updates` listener - which catches entitlement changes
    /// that happen while the app is already running (a pending purchase
    /// clearing, a refund, a family-sharing change) - then does the initial
    /// product load and entitlement reconciliation.
    func start() async {
        if updatesTask == nil {
            updatesTask = Task { [weak self] in
                for await update in Transaction.updates {
                    await self?.handle(updateResult: update)
                }
            }
        }
        await loadProduct()
        #if DEBUG
        // Debug-only verification hook (Justin, 2026-07-28): "-forceUnlocked"
        // forces the unlocked state so the purchased-state UI (SettingsSheet's
        // "Watermark removed" row, the save sheet's no-watermark path) can be
        // screenshotted/verified without a real sandbox purchase - StoreKit
        // Testing normally needs launching through Xcode's own scheme (which
        // has `Mosaic.storekit` wired into its Run action), not a bare
        // `simctl launch`. Returns before `reconcileEntitlement()` so the real
        // (empty) entitlement check never overwrites the forced value.
        if ProcessInfo.processInfo.arguments.contains("-forceUnlocked") {
            setUnlocked(true)
            return
        }
        #endif
        await reconcileEntitlement()
    }

    func loadProduct() async {
        guard product == nil else { return }
        product = try? await Product.products(for: [Self.productID]).first
    }

    /// "Unlock - $X.XX" (or a bare "Unlock" before the product has loaded
    /// or if the store fetch failed) - shared between PaywallSheet's primary
    /// button and SettingsSheet's watermark upsell card (Justin, 2026-07-28)
    /// so the two purchase surfaces can never drift onto different copy.
    var unlockButtonTitle: String {
        guard let product else { return "Unlock" }
        return "Unlock - \(product.displayPrice)"
    }

    /// Walks the CURRENT entitlement (not the transaction history) for the
    /// one product this app sells - the correct question is "does the user
    /// own this right now", not "did they ever buy it".
    func reconcileEntitlement() async {
        guard let result = await Transaction.currentEntitlement(for: Self.productID) else {
            setUnlocked(false)
            return
        }
        guard let transaction = verified(result) else {
            setUnlocked(false)
            return
        }
        setUnlocked(transaction.revocationDate == nil)
    }

    func purchase() async {
        guard let product else { return }
        isPurchasing = true
        purchaseError = nil
        defer { isPurchasing = false }

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                guard let transaction = verified(verification) else {
                    purchaseError = "Your purchase couldn't be verified. Please try again."
                    return
                }
                setUnlocked(true)
                await transaction.finish()
            case .userCancelled:
                break
            case .pending:
                // Awaiting Ask to Buy / Screen Time approval - no entitlement
                // yet; Transaction.updates picks it up if/when it resolves.
                break
            @unknown default:
                break
            }
        } catch {
            purchaseError = error.localizedDescription
        }
    }

    /// "Restore Purchase": StoreKit 2 has no separate restore API - syncing
    /// with the App Store and re-walking current entitlements IS the
    /// restore (per Apple's guidance for non-consumables).
    func restore() async {
        purchaseError = nil
        do {
            try await AppStore.sync()
        } catch {
            purchaseError = error.localizedDescription
        }
        await reconcileEntitlement()
    }

    // MARK: - Transaction.updates

    private func handle(updateResult: VerificationResult<Transaction>) async {
        guard let transaction = verified(updateResult), transaction.productID == Self.productID else { return }
        setUnlocked(transaction.revocationDate == nil)
        await transaction.finish()
    }

    private func verified<T>(_ result: VerificationResult<T>) -> T? {
        switch result {
        case .verified(let value): return value
        case .unverified: return nil // Failed StoreKit's local signature check - never trusted.
        }
    }

    private func setUnlocked(_ value: Bool) {
        isUnlocked = value
        UserDefaults.standard.set(value, forKey: Self.cachedUnlockKey)
    }
}
