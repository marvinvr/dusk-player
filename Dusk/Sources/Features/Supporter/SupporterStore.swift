import Foundation
import StoreKit

/// The supporter-tier product catalog. Everything in Dusk stays free; these
/// exist purely so people can chip in. Tips are consumables so they can be
/// bought again at any time; subscriptions live in one App Store group
/// ("Dusk Supporter") with two levels — Front Row and the higher Director's
/// Cut — so StoreKit handles upgrades, downgrades and monthly/yearly switches.
enum SupporterProduct: String, CaseIterable {
    case monthly = "supporter.monthly"
    case yearly = "supporter.yearly"
    case directorsCutMonthly = "directorscut.monthly"
    case directorsCutYearly = "directorscut.yearly"
    case tipCoffee = "tip.coffee"
    case tipGenerous = "tip.generous"
    case tipLegendary = "tip.legendary"
    case tipPatron = "tip.patron"

    static var allIDs: [String] { allCases.map(\.rawValue) }

    /// Subscription level; nil for tips.
    var tier: SupporterTier? {
        switch self {
        case .monthly, .yearly: .frontRow
        case .directorsCutMonthly, .directorsCutYearly: .directorsCut
        case .tipCoffee, .tipGenerous, .tipLegendary, .tipPatron: nil
        }
    }

    var isSubscription: Bool { tier != nil }

    var isYearly: Bool {
        self == .yearly || self == .directorsCutYearly
    }

    /// Stable display order within the purchase sheet.
    var sortOrder: Int {
        switch self {
        case .monthly: 0
        case .yearly: 1
        case .directorsCutMonthly: 2
        case .directorsCutYearly: 3
        case .tipCoffee: 4
        case .tipGenerous: 5
        case .tipLegendary: 6
        case .tipPatron: 7
        }
    }
}

/// Owns all StoreKit 2 state for the supporter tier.
///
/// Supporter status is intentionally monotonic: any verified purchase — one
/// tip or one month of either subscription level, ever — makes the user a
/// supporter permanently, even after the subscription lapses. Tips are
/// consumables, so reinstall survival relies on
/// `SKIncludeConsumableInAppPurchaseHistory` (set in both Info.plists) which
/// makes finished consumables appear in `Transaction.all`. The last-known
/// status is cached in UserDefaults so the settings UI renders correctly
/// offline, and the cache is never downgraded from `true` to `false` by a
/// transient empty history.
///
/// Director's Cut is the one thing that is *not* monotonic: its exclusive app
/// icons only stay unlocked while that level is active (`activeTier`).
@MainActor
@Observable
final class SupporterStore {
    private enum Keys {
        static let isSupporter = "supporterIsSupporter"
        static let supporterSince = "supporterSince"
        static let tipCount = "supporterTipCount"
        static let directorsCutExpiration = "supporterDirectorsCutExpiration"
    }

    /// Subscription products of both levels in display order. Empty until loaded.
    private(set) var subscriptionProducts: [Product] = []
    /// One-time tip products in ascending price order. Empty until loaded.
    private(set) var tipProducts: [Product] = []
    /// True when product loading was attempted and returned nothing usable.
    private(set) var productsUnavailable = false

    private(set) var isSupporter: Bool
    private(set) var supporterSince: Date?
    private(set) var tipCount: Int
    /// Highest subscription level currently in force; nil when none is.
    private(set) var activeTier: SupporterTier?
    private(set) var activeProductID: String?
    private(set) var activeExpirationDate: Date?
    /// Renewal info for the active subscription (pending downgrade, cancelled).
    private(set) var renewalPlan: SupporterRenewalPlan?
    /// Last known end of a Director's Cut period, cached so a transient empty
    /// history read can't make the exclusive-icon check think it lapsed.
    private(set) var lastKnownDirectorsCutExpiration: Date?

    var hasActiveSubscription: Bool { activeTier != nil }
    var hasDirectorsCut: Bool { activeTier == .directorsCut }
    /// Director's Cut is active but set to renew into Front Row.
    var pendingDowngradeTier: SupporterTier? { renewalPlan?.pendingDowngrade(from: activeTier) }

    /// Product ID of an in-flight purchase, for per-row spinners.
    private(set) var purchasingProductID: String?
    private(set) var isRestoring = false
    /// Increments after every successful purchase so views can celebrate.
    private(set) var completedPurchaseCount = 0
    private(set) var lastErrorMessage: String?

    private var updatesTask: Task<Void, Never>?
    private var expirationTask: Task<Void, Never>?
    private var started = false
    private let analytics: AnalyticsClient?
    private let defaults: UserDefaults

    init(analytics: AnalyticsClient? = nil, defaults: UserDefaults = .standard) {
        self.analytics = analytics
        self.defaults = defaults
        isSupporter = defaults.bool(forKey: Keys.isSupporter)
        supporterSince = defaults.object(forKey: Keys.supporterSince) as? Date
        tipCount = defaults.integer(forKey: Keys.tipCount)
        lastKnownDirectorsCutExpiration = defaults.object(forKey: Keys.directorsCutExpiration) as? Date
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

    /// Subscriptions can lapse while the app is in the background without a
    /// transaction update, so re-read entitlements whenever the app returns.
    func sceneDidBecomeActive() async {
        guard started else { return }
        await refreshEntitlements()
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

    /// Monthly then yearly product of one subscription level.
    func products(for tier: SupporterTier) -> [Product] {
        subscriptionProducts.filter { SupporterProduct(rawValue: $0.id)?.tier == tier }
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
        var current: [SupporterTransactionRecord] = []
        var currentTransactions: [String: Transaction] = [:]
        for await result in Transaction.currentEntitlements {
            guard let transaction = try? verified(result),
                  SupporterProduct(rawValue: transaction.productID)?.isSubscription == true else { continue }
            current.append(Self.record(for: transaction))
            currentTransactions[transaction.productID] = transaction
        }

        var history: [SupporterTransactionRecord] = []
        for await result in Transaction.all {
            guard let transaction = try? verified(result),
                  SupporterProduct(rawValue: transaction.productID) != nil else { continue }
            history.append(Self.record(for: transaction))
        }

        let entitlements = SupporterEntitlements.resolve(current: current, history: history)
        apply(entitlements)

        var plan: SupporterRenewalPlan?
        if let productID = entitlements.activeProductID,
           let status = await currentTransactions[productID]?.subscriptionStatus,
           case .verified(let renewalInfo) = status.renewalInfo {
            plan = SupporterRenewalPlan(
                nextProductID: renewalInfo.autoRenewPreference,
                willAutoRenew: renewalInfo.willAutoRenew,
                renewalDate: renewalInfo.renewalDate ?? entitlements.activeExpirationDate
            )
        }
        renewalPlan = plan

        scheduleExpirationRefresh()
        enforceExclusiveIconAccess()
    }

    /// Folds one entitlement snapshot into the cached status. Supporter status
    /// only ever gains evidence; the active level always follows the snapshot.
    func apply(_ entitlements: SupporterEntitlements) {
        activeTier = entitlements.activeTier
        activeProductID = entitlements.activeProductID
        activeExpirationDate = entitlements.activeExpirationDate

        // Once a supporter, always a supporter — never downgrade the cached
        // flag just because the history read came back empty (offline, sandbox
        // hiccups). New evidence only ever adds.
        if entitlements.hasAnySupport || entitlements.activeTier != nil {
            isSupporter = true
        }
        if let earliestPurchase = entitlements.earliestPurchase {
            supporterSince = min(supporterSince ?? earliestPurchase, earliestPurchase)
        }
        tipCount = max(tipCount, entitlements.tipCount)

        // A non-empty history is authoritative for the Director's Cut period
        // (it reflects refunds); an empty one keeps the cached value.
        if !entitlements.historyWasEmpty {
            lastKnownDirectorsCutExpiration = entitlements.latestDirectorsCutExpiration
        }
        if entitlements.activeTier == .directorsCut, let expiration = entitlements.activeExpirationDate {
            lastKnownDirectorsCutExpiration = max(lastKnownDirectorsCutExpiration ?? expiration, expiration)
        }

        persistCache()
    }

    /// True when an exclusive Director's Cut icon is no longer covered.
    func shouldRevertExclusiveIcon(now: Date = Date()) -> Bool {
        SupporterEntitlements.shouldRevertExclusiveIcon(
            activeTier: activeTier,
            lastKnownDirectorsCutExpiration: lastKnownDirectorsCutExpiration,
            now: now
        )
    }

    /// Switches back to the default icon once Director's Cut has lapsed while
    /// one of its exclusive icons is set. iOS shows its own "You have changed
    /// the icon" alert for any icon change; there is no in-app UI for this.
    /// Not awaited: the system call only returns once that alert is dismissed,
    /// which would stall every entitlement refresh behind it. If the app isn't
    /// active the switch fails and is retried on the next activation.
    private func enforceExclusiveIconAccess() {
        #if os(iOS)
        guard DuskAppIcon.current.requiresDirectorsCut, shouldRevertExclusiveIcon() else { return }
        Task { try? await DuskAppIcon.select(.dusk) }
        #endif
    }

    /// Re-reads entitlements right after the active period ends so a lapse
    /// while the app is open locks the exclusive icons without a relaunch.
    private func scheduleExpirationRefresh() {
        expirationTask?.cancel()
        guard let expiration = activeExpirationDate else { return }
        let delay = expiration.timeIntervalSinceNow + 1
        guard delay > 0, delay < 60 * 60 * 24 * 2 else { return }
        expirationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.refreshEntitlements()
        }
    }

    private func persistCache() {
        defaults.set(isSupporter, forKey: Keys.isSupporter)
        defaults.set(supporterSince, forKey: Keys.supporterSince)
        defaults.set(tipCount, forKey: Keys.tipCount)
        defaults.set(lastKnownDirectorsCutExpiration, forKey: Keys.directorsCutExpiration)
    }

    private static func record(for transaction: Transaction) -> SupporterTransactionRecord {
        SupporterTransactionRecord(
            productID: transaction.productID,
            originalPurchaseDate: transaction.originalPurchaseDate,
            expirationDate: transaction.expirationDate,
            revocationDate: transaction.revocationDate,
            isUpgraded: transaction.isUpgraded,
            purchasedQuantity: transaction.purchasedQuantity
        )
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
