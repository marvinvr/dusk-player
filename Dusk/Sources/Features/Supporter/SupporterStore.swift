import Foundation
import StoreKit

/// The supporter-tier product catalog. Everything in Dusk stays free; these
/// exist purely so people can chip in. Tips are consumables so they can be
/// bought again at any time. The one subscription ("Dusk Supporter") has a
/// monthly and a yearly plan on the same level of one App Store group, so
/// StoreKit handles switching between them. These are the product IDs that
/// shipped in 1.6, so existing subscribers keep everything.
enum SupporterProduct: String, CaseIterable {
    case monthly = "supporter.monthly"
    case yearly = "supporter.yearly"
    case tipCoffee = "tip.coffee"
    case tipGenerous = "tip.generous"
    case tipLegendary = "tip.legendary"
    case tipPatron = "tip.patron"

    static var allIDs: [String] { allCases.map(\.rawValue) }

    var isSubscription: Bool {
        self == .monthly || self == .yearly
    }

    /// A tip big enough to include the six classic alternate icons for good
    /// (Generous and up). The Coffee tip is a thank-you only.
    var isIconTip: Bool {
        switch self {
        case .tipGenerous, .tipLegendary, .tipPatron: true
        default: false
        }
    }

    var isYearly: Bool { self == .yearly }

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

/// Whether this process is a TestFlight install.
///
/// TestFlight never sees the buyer's real App Store subscription — StoreKit
/// reports the sandbox — so supporter icons would stay locked for every
/// tester. Resolved once, before the first entitlement read. A verified
/// `AppTransaction` whose environment is `.sandbox` counts; if that read
/// fails, the on-disk receipt named `sandboxReceipt` does. Production
/// (`.production`) and Xcode StoreKit testing (`.xcode`) do not, so App
/// Store installs and ordinary Debug/simulator runs keep the real rules.
@MainActor
enum TestFlightInstall {
    /// True only after `resolveOnce()` has seen a sandbox install.
    private(set) static var isTestFlight = false
    private static var didResolve = false

    static func resolveOnce() async {
        guard !didResolve else { return }
        didResolve = true
        isTestFlight = await detect()
    }

    private static func detect() async -> Bool {
        if let result = try? await AppTransaction.shared {
            if case .verified(let transaction) = result {
                // A verified Xcode or production transaction is authoritative.
                // Don't let a leftover receipt URL override it.
                return transaction.environment == .sandbox
            }
        }
        return hasSandboxReceipt()
    }

    /// `Bundle.appStoreReceiptURL` is deprecated for Swift. The selector is
    /// that property: TestFlight's receipt file is named `sandboxReceipt`,
    /// production's is `receipt`. The file has to exist so a simulator path
    /// with that name and no receipt is not treated as TestFlight.
    private static func hasSandboxReceipt() -> Bool {
        let selector = NSSelectorFromString("appStoreReceiptURL")
        guard let object = Bundle.main.perform(selector)?.takeUnretainedValue(),
              let url = (object as? NSURL).map({ $0 as URL }),
              url.lastPathComponent == "sandboxReceipt"
        else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }
}

/// Owns all StoreKit 2 state for the supporter tier.
///
/// Supporter status (the thank-you title, no more supporter prompts) is
/// monotonic: any verified purchase — one tip or one month of the
/// subscription — sets it, and a lapse doesn't clear it. Tips are
/// consumables, so reinstall survival relies on
/// `SKIncludeConsumableInAppPurchaseHistory` (set in both Info.plists) which
/// makes finished consumables appear in `Transaction.all`. The last-known
/// status is cached in UserDefaults so the settings UI renders correctly
/// offline, and the cache is never downgraded from `true` to `false` by a
/// transient empty history.
///
/// Perks are *not* monotonic: subscription icons only stay unlocked while the
/// subscription is active (`hasActiveSubscription`) — the classic alternates
/// and Velvet/Emerald/Gilded alike. Tips from Generous up are
/// one-time purchases that unlock the classic alternates for good
/// (`hasIconTip`); the Coffee tip unlocks nothing. A TestFlight install
/// (`TestFlightInstall`) unlocks every icon for the process and does not
/// revert one.
@MainActor
@Observable
final class SupporterStore {
    private enum Keys {
        static let isSupporter = "supporterIsSupporter"
        static let supporterSince = "supporterSince"
        static let tipCount = "supporterTipCount"
        static let hasIconTip = "supporterHasIconTip"
        static let lastTipDate = "supporterLastTipDate"
        static let subscriptionExpiration = "supporterSubscriptionExpiration"
        static let launchLogo = "supporterLaunchLogo"
    }

    /// Monthly then yearly subscription product. Empty until loaded.
    private(set) var subscriptionProducts: [Product] = []
    /// One-time tip products in ascending price order. Empty until loaded.
    private(set) var tipProducts: [Product] = []
    /// True when product loading was attempted and returned nothing usable.
    private(set) var productsUnavailable = false

    private(set) var isSupporter: Bool
    private(set) var supporterSince: Date?
    private(set) var tipCount: Int
    /// A tip from Generous up was ever bought (monotonic, like `tipCount`).
    private(set) var hasIconTip: Bool
    /// Most recent tip, cached; snoozes the supporter prompt for a year.
    private(set) var lastTipDate: Date?
    /// The subscription plan currently in force; nil when none is.
    private(set) var activeProductID: String?
    private(set) var activeExpirationDate: Date?
    /// Renewal info for the active subscription (plan switch, cancelled).
    private(set) var renewalPlan: SupporterRenewalPlan?
    /// Last known end of a subscription period, cached so a transient empty
    /// history read can't make the icon check think it lapsed.
    private(set) var lastKnownSubscriptionExpiration: Date?

    /// tvOS only: the icon whose logo the launch splash shows. Apple TV can't
    /// apply alternate icons, so picking one there sets this instead. Follows
    /// the same unlock rules as the icons and goes back to the default with
    /// them (`enforceLaunchLogoAccess`). Always `.dusk` on iOS, where the
    /// splash follows the applied icon.
    private(set) var launchLogo: DuskAppIcon

    var hasActiveSubscription: Bool { activeProductID != nil }
    /// The classic alternate icons are unlocked: a tip from Generous up, or an
    /// active subscription.
    var hasIconAccess: Bool { hasIconTip || hasActiveSubscription }

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
        hasIconTip = defaults.bool(forKey: Keys.hasIconTip)
        lastTipDate = defaults.object(forKey: Keys.lastTipDate) as? Date
        lastKnownSubscriptionExpiration = defaults.object(forKey: Keys.subscriptionExpiration) as? Date
        launchLogo = Self.storedLaunchLogo(in: defaults)
    }

    /// The launch logo as last saved, read straight from the defaults so the
    /// splash can use it before the store exists. Like the system's applied
    /// icon on iOS, it only changes once a revert actually went through.
    nonisolated static func storedLaunchLogo(in defaults: UserDefaults = .standard) -> DuskAppIcon {
        defaults.string(forKey: Keys.launchLogo).flatMap(DuskAppIcon.init(rawValue:)) ?? .dusk
    }

    /// Sets the tvOS launch logo. Locked icons are ignored.
    func selectLaunchLogo(_ icon: DuskAppIcon) {
        guard isUnlocked(icon), icon != launchLogo else { return }
        launchLogo = icon
        defaults.set(icon.rawValue, forKey: Keys.launchLogo)
    }

    /// Puts the launch logo back to the default under the same rule that
    /// switches a lapsed app icon back (`shouldRevertIcon`), so a transient
    /// empty read mid-period never flips it and TestFlight never does.
    func enforceLaunchLogoAccess(now: Date = Date()) {
        guard launchLogo != .dusk, shouldRevertIcon(launchLogo, now: now) else { return }
        launchLogo = .dusk
        defaults.removeObject(forKey: Keys.launchLogo)
    }

    /// Kicks off the transaction listener, loads products, and reconciles
    /// entitlements. Safe to call once from the app root's `.task`.
    func start() async {
        guard !started else { return }
        // Stay unstarted across this await so a foreground refresh cannot
        // revert an icon before the TestFlight result is known.
        await TestFlightInstall.resolveOnce()
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
        enforceIconAccess()
    }

    /// Folds one entitlement snapshot into the cached status. Supporter status
    /// only ever gains evidence; the active plan always follows the snapshot.
    func apply(_ entitlements: SupporterEntitlements) {
        activeProductID = entitlements.activeProductID
        activeExpirationDate = entitlements.activeExpirationDate

        // Once a supporter, always a supporter — never downgrade the cached
        // flag just because the history read came back empty (offline, sandbox
        // hiccups). New evidence only ever adds.
        if entitlements.hasAnySupport || entitlements.hasActiveSubscription {
            isSupporter = true
        }
        if let earliestPurchase = entitlements.earliestPurchase {
            supporterSince = min(supporterSince ?? earliestPurchase, earliestPurchase)
        }
        tipCount = max(tipCount, entitlements.tipCount)
        hasIconTip = hasIconTip || entitlements.hasIconTip
        if let latestTip = entitlements.latestTipPurchase {
            lastTipDate = max(lastTipDate ?? latestTip, latestTip)
        }

        // A non-empty history is authoritative for the subscription period
        // (it reflects refunds); an empty one keeps the cached value.
        if !entitlements.historyWasEmpty {
            lastKnownSubscriptionExpiration = entitlements.latestSubscriptionExpiration
        }
        if let expiration = entitlements.activeExpirationDate {
            lastKnownSubscriptionExpiration = max(lastKnownSubscriptionExpiration ?? expiration, expiration)
        }

        persistCache()
    }

    /// True when `icon`, if set, is no longer covered and must go back to the
    /// default. Never on TestFlight: the sandbox has no real subscription,
    /// and a tester's chosen icon must survive entitlement reads.
    func shouldRevertIcon(_ icon: DuskAppIcon, now: Date = Date()) -> Bool {
        if TestFlightInstall.isTestFlight { return false }
        return SupporterEntitlements.shouldRevertIcon(
            icon,
            hasActiveSubscription: hasActiveSubscription,
            hasIconTip: hasIconTip,
            lastKnownSubscriptionExpiration: lastKnownSubscriptionExpiration,
            now: now
        )
    }

    /// Switches back to the default icon (on tvOS the launch logo) once the
    /// subscription that unlocked it has lapsed. Runs after every entitlement read: at
    /// launch, on every return to the foreground and on transaction updates. iOS shows its own "You have changed
    /// the icon" alert for any icon change; there is no in-app UI for this.
    /// Not awaited: the system call only returns once that alert is dismissed,
    /// which would stall every entitlement refresh behind it. If the app isn't
    /// active the switch fails and is retried on the next activation.
    private func enforceIconAccess() {
        #if os(iOS)
        guard shouldRevertIcon(DuskAppIcon.current) else { return }
        Task { try? await DuskAppIcon.select(.dusk) }
        #else
        enforceLaunchLogoAccess()
        #endif
    }

    /// Re-reads entitlements right after the active period ends so a lapse
    /// while the app is open locks its icons without a relaunch.
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
        defaults.set(hasIconTip, forKey: Keys.hasIconTip)
        defaults.set(lastTipDate, forKey: Keys.lastTipDate)
        defaults.set(lastKnownSubscriptionExpiration, forKey: Keys.subscriptionExpiration)
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
