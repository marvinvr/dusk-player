import Foundation
import StoreKit

/// The supporter-tier product catalog. Everything in Dusk stays free; these
/// exist purely so people can chip in. Tips are consumables so they can be
/// bought again at any time; subscriptions live in one App Store group so a
/// user can switch between monthly and yearly.
enum SupporterProduct: String, CaseIterable {
    case monthly = "supporter.monthly"
    case yearly = "supporter.yearly"
    case tipCoffee = "tip.coffee"
    case tipGenerous = "tip.generous"
    case tipLegendary = "tip.legendary"
    case tipPatron = "tip.patron"

    static var allIDs: [String] { allCases.map(\.rawValue) }

    var isSubscription: Bool {
        switch self {
        case .monthly, .yearly: true
        case .tipCoffee, .tipGenerous, .tipLegendary, .tipPatron: false
        }
    }

    /// Stable display order within the purchase sheet.
    var sortOrder: Int {
        switch self {
        case .monthly: 0
        case .yearly: 1
        case .tipCoffee: 2
        case .tipGenerous: 3
        case .tipLegendary: 4
        case .tipPatron: 5
        }
    }
}

/// Owns all StoreKit 2 state for the supporter tier.
///
/// Supporter status is intentionally monotonic: any verified purchase — one
/// tip or one month of subscription, ever — makes the user a supporter
/// permanently, even after the subscription lapses. Tips are consumables, so
/// reinstall survival relies on `SKIncludeConsumableInAppPurchaseHistory`
/// (set in both Info.plists) which makes finished consumables appear in
/// `Transaction.all`. The last-known status is cached in UserDefaults so the
/// settings UI renders correctly offline, and the cache is never downgraded
/// from `true` to `false` by a transient empty history.
@MainActor
@Observable
final class SupporterStore {
    private enum Keys {
        static let isSupporter = "supporterIsSupporter"
        static let supporterSince = "supporterSince"
        static let tipCount = "supporterTipCount"
    }

    /// Subscription products in display order (monthly, yearly). Empty until loaded.
    private(set) var subscriptionProducts: [Product] = []
    /// One-time tip products in ascending price order. Empty until loaded.
    private(set) var tipProducts: [Product] = []
    /// True when product loading was attempted and returned nothing usable.
    private(set) var productsUnavailable = false

    private(set) var isSupporter: Bool
    private(set) var supporterSince: Date?
    private(set) var tipCount: Int
    private(set) var hasActiveSubscription = false

    /// Product ID of an in-flight purchase, for per-row spinners.
    private(set) var purchasingProductID: String?
    private(set) var isRestoring = false
    /// Increments after every successful purchase so views can celebrate.
    private(set) var completedPurchaseCount = 0
    private(set) var lastErrorMessage: String?

    private var updatesTask: Task<Void, Never>?
    private var started = false
    private let analytics: AnalyticsClient?

    init(analytics: AnalyticsClient? = nil) {
        self.analytics = analytics
        let defaults = UserDefaults.standard
        isSupporter = defaults.bool(forKey: Keys.isSupporter)
        supporterSince = defaults.object(forKey: Keys.supporterSince) as? Date
        tipCount = defaults.integer(forKey: Keys.tipCount)
    }

    /// Kicks off the transaction listener, loads products, and reconciles
    /// entitlements. Safe to call once from the app root's `.task`.
    func start() async {
        guard !started else { return }
        started = true

        startTransactionListener()
        await finishUnfinishedTransactions()
        await refreshEntitlements()
        await loadProducts()
    }

    // MARK: - Products

    func loadProducts() async {
        do {
            let products = try await Product.products(for: SupporterProduct.allIDs)
            let ordered = products.sorted { lhs, rhs in
                let lhsOrder = SupporterProduct(rawValue: lhs.id)?.sortOrder ?? .max
                let rhsOrder = SupporterProduct(rawValue: rhs.id)?.sortOrder ?? .max
                return lhsOrder < rhsOrder
            }
            subscriptionProducts = ordered.filter { SupporterProduct(rawValue: $0.id)?.isSubscription == true }
            tipProducts = ordered.filter { SupporterProduct(rawValue: $0.id)?.isSubscription == false }
            productsUnavailable = ordered.isEmpty
        } catch {
            productsUnavailable = subscriptionProducts.isEmpty && tipProducts.isEmpty
        }
    }

    // MARK: - Purchasing

    func purchase(_ product: Product) async {
        guard purchasingProductID == nil else { return }
        purchasingProductID = product.id
        lastErrorMessage = nil
        defer { purchasingProductID = nil }

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try verified(verification)
                await transaction.finish()
                await refreshEntitlements()
                completedPurchaseCount += 1
                analytics?.record(AnalyticsEvent(.supporterPurchaseCompleted, [
                    "product": .string(product.id)
                ]))
            case .userCancelled, .pending:
                analytics?.record(AnalyticsEvent(.supporterPurchaseCancelled, [
                    "product": .string(product.id)
                ]))
            @unknown default:
                break
            }
        } catch {
            lastErrorMessage = "The purchase could not be completed. Nothing was charged unless the App Store says otherwise."
            analytics?.record(AnalyticsEvent(.supporterPurchaseFailed, [
                "product": .string(product.id)
            ]))
        }
    }

    /// Explicit restore for the sheet's footer button. `AppStore.sync()` may
    /// prompt for App Store credentials, so only call it from a user action.
    func restorePurchases() async {
        isRestoring = true
        defer { isRestoring = false }
        try? await AppStore.sync()
        await refreshEntitlements()
    }

    // MARK: - Entitlements

    /// Recomputes supporter status from the App Store transaction history.
    func refreshEntitlements() async {
        var activeSubscription = false
        for await result in Transaction.currentEntitlements {
            guard let transaction = try? verified(result),
                  let product = SupporterProduct(rawValue: transaction.productID),
                  product.isSubscription,
                  transaction.revocationDate == nil else { continue }
            activeSubscription = true
        }

        var anySupport = false
        var earliestPurchase: Date?
        var tips = 0
        for await result in Transaction.all {
            guard let transaction = try? verified(result),
                  let product = SupporterProduct(rawValue: transaction.productID),
                  transaction.revocationDate == nil else { continue }
            anySupport = true
            let purchaseDate = transaction.originalPurchaseDate
            earliestPurchase = min(earliestPurchase ?? purchaseDate, purchaseDate)
            if !product.isSubscription {
                tips += max(transaction.purchasedQuantity, 1)
            }
        }

        hasActiveSubscription = activeSubscription
        // Once a supporter, always a supporter — never downgrade the cached
        // flag just because the history read came back empty (offline, sandbox
        // hiccups). New evidence only ever adds.
        if anySupport || activeSubscription {
            isSupporter = true
        }
        if let earliestPurchase {
            supporterSince = min(supporterSince ?? earliestPurchase, earliestPurchase)
        }
        tipCount = max(tipCount, tips)

        persistCache()
    }

    private func persistCache() {
        let defaults = UserDefaults.standard
        defaults.set(isSupporter, forKey: Keys.isSupporter)
        defaults.set(supporterSince, forKey: Keys.supporterSince)
        defaults.set(tipCount, forKey: Keys.tipCount)
    }

    // MARK: - Transaction plumbing

    private func startTransactionListener() {
        guard updatesTask == nil else { return }
        updatesTask = Task { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                if let transaction = try? self.verified(result) {
                    await transaction.finish()
                }
                await self.refreshEntitlements()
            }
        }
    }

    /// Consumables must be finished or they stay pending forever; sweep
    /// anything a previous run left behind (e.g. a crash mid-purchase).
    private func finishUnfinishedTransactions() async {
        for await result in Transaction.unfinished {
            guard let transaction = try? verified(result) else { continue }
            await transaction.finish()
        }
    }

    private func verified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let value):
            return value
        case .unverified:
            throw StoreKitError.notEntitled
        }
    }
}
