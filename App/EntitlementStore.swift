import Foundation
import Observation
import StoreKit
import UIKit

/// Corres Pro, through StoreKit 2 only: no server of ours decides who has
/// Pro. Apple's signed transactions on the device are the record, so a
/// purchase, a redeemed offer code (including gifted lifetime access), a
/// Family Sharing grant, or a restore on a new iPhone all arrive the same
/// way, through `Transaction.currentEntitlements` and `Transaction.updates`.
///
/// Prices, the 14-day free trial and offer codes are configured in App
/// Store Connect, not here; changing them needs no app update.
@MainActor @Observable
final class EntitlementStore {
    enum ProductID {
        static let monthly = "studio.anwarcreative.corres.pro.monthly"
        static let annual = "studio.anwarcreative.corres.pro.annual"
        static let lifetime = "studio.anwarcreative.corres.pro.lifetime"
        static let all = [annual, monthly, lifetime]
    }

    enum Plan: Equatable {
        case none
        case monthly(renews: Date?, inTrial: Bool)
        case annual(renews: Date?, inTrial: Bool)
        case lifetime(familyShared: Bool)

        var title: String {
            switch self {
            case .none: "Free"
            case .monthly: "Corres Pro · Monthly"
            case .annual: "Corres Pro · Annual"
            case .lifetime: "Corres Pro · Lifetime"
            }
        }
    }

    private(set) var plan: Plan = .none
    private(set) var products: [Product] = []
    private(set) var isEligibleForTrial = true
    /// False until the first entitlement check finishes, so the app doesn't
    /// flash a lock at a subscriber on launch.
    private(set) var hasLoaded = false
    private(set) var isPurchasing = false
    var errorMessage: String?

    var isPro: Bool { plan != .none || (hasBetaAccess && !previewAsFree) }

    // MARK: Beta access
    //
    // Testers get Pro without buying it, so they test the mail, not a
    // payment sheet (TestFlight purchases also lapse after a week of daily
    // renewals). Two locks, both required, so App Store customers can never
    // get Pro free:
    // 1. Compiled in only by Scripts/testflight.sh (`-D CORRES_BETA`).
    //    App Store submissions are built by Scripts/appstore.sh, without it,
    //    and that script refuses to finish if the flag got in.
    // 2. Even then, only when the app wasn't installed from the App Store
    //    (`AppTransaction.environment` is sandbox or Xcode). So a beta
    //    build released by mistake would still charge App Store customers.
    // App Review also runs in the sandbox, which is why lock 1 exists: a
    // reviewer handed free Pro never sees a working paywall (guideline 2.1).

    #if CORRES_BETA
    static let isBetaBuild = true
    /// Checked in the built app by Scripts/testflight.sh and appstore.sh.
    static let buildKind = "CORRES_BETA_BUILD"
    #else
    static let isBetaBuild = false
    static let buildKind = "CORRES_APPSTORE_BUILD"
    #endif

    /// Beta build, installed from TestFlight or Xcode.
    private(set) var hasBetaAccess = false

    /// Settings → Beta → Preview as free user: the beta shows the locked
    /// app and paywall, for testing them.
    var previewAsFree = UserDefaults.standard.bool(forKey: EntitlementStore.previewAsFreeKey) {
        didSet { UserDefaults.standard.set(previewAsFree, forKey: Self.previewAsFreeKey) }
    }
    static let previewAsFreeKey = "corres.beta.previewAsFree"

    /// Fails closed: anything short of a definite non-App Store install
    /// keeps the paywall.
    private static func qualifiesForBetaAccess() async -> Bool {
        guard isBetaBuild, let result = try? await AppTransaction.shared else { return false }
        let transaction: AppTransaction
        switch result {
        case .verified(let verified): transaction = verified
        case .unverified: return false
        }
        return transaction.environment == .sandbox || transaction.environment == .xcode
    }

    private var updatesTask: Task<Void, Never>?

    init() {
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                if case .verified(let transaction) = update { await transaction.finish() }
                await self?.refresh()
            }
        }
        Task { await self.start() }
    }

    func start() async {
        hasBetaAccess = await Self.qualifiesForBetaAccess()
        await refresh()
        await loadProducts()
    }

    func product(_ id: String) -> Product? { products.first { $0.id == id } }

    /// Whether the last attempt to load the plans came back empty or
    /// failed, so the paywall can say so and offer to try again instead
    /// of spinning forever (no network, or the App Store not yet serving
    /// the products).
    private(set) var productsUnavailable = false
    private(set) var isLoadingProducts = false

    func loadProducts() async {
        guard products.isEmpty, !isLoadingProducts else { return }
        isLoadingProducts = true
        defer { isLoadingProducts = false }
        productsUnavailable = false
        if let loaded = try? await Product.products(for: ProductID.all) {
            products = ProductID.all.compactMap { id in loaded.first { $0.id == id } }
        }
        productsUnavailable = products.isEmpty
        if let annual = product(ProductID.annual), let subscription = annual.subscription {
            isEligibleForTrial = await subscription.isEligibleForIntroOffer
        }
    }

    /// Recomputes the plan from Apple's current, verified entitlements.
    /// Lifetime wins over a subscription; annual over monthly.
    func refresh() async {
        var best: Plan = .none
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result, transaction.revocationDate == nil else { continue }
            switch transaction.productID {
            case ProductID.lifetime:
                best = .lifetime(familyShared: transaction.ownershipType == .familyShared)
            case ProductID.annual where !isLifetime(best):
                best = .annual(renews: transaction.expirationDate, inTrial: Self.isTrial(transaction))
            case ProductID.monthly where best == .none:
                best = .monthly(renews: transaction.expirationDate, inTrial: Self.isTrial(transaction))
            default:
                break
            }
        }
        plan = best
        hasLoaded = true
    }

    func purchase(_ product: Product) async {
        guard !isPurchasing else { return }
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            switch try await product.purchase() {
            case .success(let verification):
                if case .verified(let transaction) = verification { await transaction.finish() }
                await refresh()
            case .pending:
                errorMessage = "Your purchase is waiting for approval. Corres Pro unlocks as soon as it's approved."
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            errorMessage = "The purchase didn't go through. Please try again."
        }
    }

    /// Apple's Redeem Code sheet, presented from the app's own window
    /// rather than from inside another sheet: stacked on top of the
    /// paywall or Settings, iOS laid it out with its close button over
    /// the header.
    func presentRedeemSheet() async {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else { return }
        do {
            try await AppStore.presentOfferCodeRedeemSheet(in: scene)
            await refresh()
        } catch {
            errorMessage = "Couldn't open the Redeem Code sheet. You can also redeem in the App Store under your account."
        }
    }

    /// Restore: asks the App Store to re-sync this Apple Account's purchases.
    func restore() async {
        do {
            try await AppStore.sync()
            await refresh()
            if !isPro { errorMessage = "No Corres Pro purchase was found for this Apple Account." }
        } catch {
            errorMessage = "Couldn't reach the App Store to restore purchases. Please try again."
        }
    }

    private func isLifetime(_ plan: Plan) -> Bool {
        if case .lifetime = plan { return true }
        return false
    }

    private static func isTrial(_ transaction: Transaction) -> Bool {
        if #available(iOS 17.2, *) {
            return transaction.offer?.paymentMode == .freeTrial
        }
        return false
    }
}
