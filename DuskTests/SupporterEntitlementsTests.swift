import Foundation
import Testing
@testable import Dusk

/// Pure entitlement rules: which level is in force, what counts as support,
/// and when a Director's Cut icon has to go.
@Suite("Supporter entitlements")
struct SupporterEntitlementsTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 86_400

    private func record(
        _ product: SupporterProduct,
        purchased: TimeInterval = -30,
        expires: TimeInterval? = 3,
        revoked: Bool = false,
        upgraded: Bool = false,
        quantity: Int = 1
    ) -> SupporterTransactionRecord {
        SupporterTransactionRecord(
            productID: product.rawValue,
            originalPurchaseDate: now.addingTimeInterval(purchased * day),
            expirationDate: product.isSubscription ? expires.map { now.addingTimeInterval($0 * day) } : nil,
            revocationDate: revoked ? now.addingTimeInterval(-day) : nil,
            isUpgraded: upgraded,
            purchasedQuantity: quantity
        )
    }

    // MARK: Catalog

    @Test func catalogMapsProductsToLevels() {
        #expect(SupporterProduct.monthly.tier == .frontRow)
        #expect(SupporterProduct.yearly.tier == .frontRow)
        #expect(SupporterProduct.directorsCutMonthly.tier == .directorsCut)
        #expect(SupporterProduct.directorsCutYearly.tier == .directorsCut)
        #expect(SupporterProduct.tipPatron.tier == nil)
        #expect(SupporterProduct.directorsCutMonthly.rawValue == "directorscut.monthly")
        #expect(SupporterProduct.directorsCutYearly.rawValue == "directorscut.yearly")
        #expect(SupporterTier.directorsCut > SupporterTier.frontRow)
        #expect(SupporterProduct.allCases.map(\.sortOrder) == Array(0..<SupporterProduct.allCases.count))
    }

    // MARK: Active level

    @Test func nothingPurchased() {
        let result = SupporterEntitlements.resolve(current: [], history: [], now: now)
        #expect(result.activeTier == nil)
        #expect(!result.hasAnySupport)
        #expect(result.historyWasEmpty)
    }

    @Test func frontRowActive() {
        let fr = record(.monthly)
        let result = SupporterEntitlements.resolve(current: [fr], history: [fr], now: now)
        #expect(result.activeTier == .frontRow)
        #expect(result.activeProductID == "supporter.monthly")
        #expect(result.hasAnySupport)
        #expect(result.latestDirectorsCutExpiration == nil)
    }

    @Test func directorsCutActive() {
        let dc = record(.directorsCutYearly, expires: 200)
        let result = SupporterEntitlements.resolve(current: [dc], history: [dc], now: now)
        #expect(result.activeTier == .directorsCut)
        #expect(result.activeProductID == "directorscut.yearly")
        #expect(result.latestDirectorsCutExpiration == now.addingTimeInterval(200 * day))
    }

    @Test func upgradeReplacesFrontRowImmediately() {
        let fr = record(.yearly, expires: 100, upgraded: true)
        let dc = record(.directorsCutMonthly, purchased: -1, expires: 29)
        let result = SupporterEntitlements.resolve(current: [fr, dc], history: [fr, dc], now: now)
        #expect(result.activeTier == .directorsCut)
        #expect(result.activeProductID == "directorscut.monthly")
    }

    @Test func upgradedTransactionAloneGrantsNothing() {
        let fr = record(.monthly, upgraded: true)
        let result = SupporterEntitlements.resolve(current: [fr], history: [fr], now: now)
        #expect(result.activeTier == nil)
        #expect(result.hasAnySupport)
    }

    @Test func higherLevelWinsWhenBothAreCurrent() {
        let fr = record(.yearly, expires: 300)
        let dc = record(.directorsCutMonthly, expires: 10)
        let result = SupporterEntitlements.resolve(current: [fr, dc], history: [fr, dc], now: now)
        #expect(result.activeTier == .directorsCut)
    }

    @Test func pendingDowngradeKeepsDirectorsCutUntilRenewal() {
        let dc = record(.directorsCutMonthly, expires: 12)
        let result = SupporterEntitlements.resolve(current: [dc], history: [dc], now: now)
        #expect(result.activeTier == .directorsCut)

        let plan = SupporterRenewalPlan(
            nextProductID: SupporterProduct.monthly.rawValue,
            willAutoRenew: true,
            renewalDate: now.addingTimeInterval(12 * day)
        )
        #expect(plan.pendingDowngrade(from: result.activeTier) == .frontRow)
        #expect(!SupporterEntitlements.shouldRevertExclusiveIcon(
            activeTier: result.activeTier,
            lastKnownDirectorsCutExpiration: result.latestDirectorsCutExpiration,
            now: now
        ))
    }

    @Test func downgradeTakesEffectAtRenewal() {
        let dcExpired = record(.directorsCutMonthly, purchased: -40, expires: -10)
        let fr = record(.monthly, purchased: -40, expires: 20)
        let result = SupporterEntitlements.resolve(current: [fr], history: [dcExpired, fr], now: now)
        #expect(result.activeTier == .frontRow)
        #expect(SupporterEntitlements.shouldRevertExclusiveIcon(
            activeTier: result.activeTier,
            lastKnownDirectorsCutExpiration: result.latestDirectorsCutExpiration,
            now: now
        ))
    }

    @Test func renewalPlanOnlyReportsRealDowngrades() {
        let toFrontRow = SupporterRenewalPlan(nextProductID: "supporter.yearly", willAutoRenew: true, renewalDate: now)
        #expect(toFrontRow.pendingDowngrade(from: .frontRow) == nil) // crossgrade
        #expect(toFrontRow.pendingDowngrade(from: nil) == nil)

        let cancelled = SupporterRenewalPlan(nextProductID: "supporter.monthly", willAutoRenew: false, renewalDate: now)
        #expect(cancelled.pendingDowngrade(from: .directorsCut) == nil)

        let upgrade = SupporterRenewalPlan(nextProductID: "directorscut.yearly", willAutoRenew: true, renewalDate: now)
        #expect(upgrade.pendingDowngrade(from: .frontRow) == nil)
        #expect(upgrade.nextTier == .directorsCut)
    }

    // MARK: Lapse & refunds

    @Test func lapsedDirectorsCutKeepsSupporterButLocksExclusives() {
        let dc = record(.directorsCutMonthly, purchased: -60, expires: -2)
        // Expired transactions can still show up in a stale current read.
        let result = SupporterEntitlements.resolve(current: [dc], history: [dc], now: now)
        #expect(result.activeTier == nil)
        #expect(result.hasAnySupport)
        #expect(result.earliestPurchase == now.addingTimeInterval(-60 * day))
        #expect(SupporterEntitlements.shouldRevertExclusiveIcon(
            activeTier: result.activeTier,
            lastKnownDirectorsCutExpiration: result.latestDirectorsCutExpiration,
            now: now
        ))
    }

    @Test func refundedDirectorsCutGrantsNothing() {
        let dc = record(.directorsCutMonthly, expires: 20, revoked: true)
        let result = SupporterEntitlements.resolve(current: [dc], history: [dc], now: now)
        #expect(result.activeTier == nil)
        #expect(!result.hasAnySupport)
        #expect(!result.historyWasEmpty)
        #expect(result.latestDirectorsCutExpiration == nil)
    }

    @Test func tipsCountTowardSupportButNoLevel() {
        let tips = [record(.tipCoffee), record(.tipPatron, quantity: 2)]
        let result = SupporterEntitlements.resolve(current: [], history: tips, now: now)
        #expect(result.activeTier == nil)
        #expect(result.hasAnySupport)
        #expect(result.tipCount == 3)
    }

    @Test func revertRuleWaitsForTheKnownPeriodToEnd() {
        let future = now.addingTimeInterval(5 * day)
        let past = now.addingTimeInterval(-day)
        #expect(!SupporterEntitlements.shouldRevertExclusiveIcon(activeTier: .directorsCut, lastKnownDirectorsCutExpiration: past, now: now))
        #expect(!SupporterEntitlements.shouldRevertExclusiveIcon(activeTier: nil, lastKnownDirectorsCutExpiration: future, now: now))
        #expect(SupporterEntitlements.shouldRevertExclusiveIcon(activeTier: nil, lastKnownDirectorsCutExpiration: past, now: now))
        #expect(SupporterEntitlements.shouldRevertExclusiveIcon(activeTier: .frontRow, lastKnownDirectorsCutExpiration: nil, now: now))
    }

    // MARK: Icons

    @Test func iconAccessByLevel() {
        for icon in DuskAppIcon.allCases {
            #expect(icon.isUnlocked(isSupporter: false, hasDirectorsCut: false) == (icon == .dusk))
            #expect(icon.isUnlocked(isSupporter: true, hasDirectorsCut: false) == !icon.requiresDirectorsCut)
            #expect(icon.isUnlocked(isSupporter: true, hasDirectorsCut: true))
        }
        #expect(DuskAppIcon.directorsCutIcons == [.eclipse, .velvet])
        #expect(DuskAppIcon.supporterIcons.count == 7)
        #expect(DuskAppIcon.supporterIcons.first == .dusk)
    }

    @Test func iconNamesAreUnique() {
        let alternates = DuskAppIcon.allCases.compactMap(\.alternateIconName)
        #expect(Set(alternates).count == DuskAppIcon.allCases.count - 1)
        #expect(Set(DuskAppIcon.allCases.map(\.previewImageName)).count == DuskAppIcon.allCases.count)
        #expect(DuskAppIcon.eclipse.alternateIconName == "DuskIconEclipse")
        #expect(DuskAppIcon.velvet.alternateIconName == "DuskIconVelvet")
    }
}

/// The store's cache rules on top of the snapshots: supporter status is
/// monotonic, the active level follows the latest snapshot.
@Suite("Supporter store cache")
@MainActor
struct SupporterStoreCacheTests {
    private let now = Date()
    private let day: TimeInterval = 86_400

    private func makeStore() -> SupporterStore {
        let suite = "SupporterStoreCacheTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return SupporterStore(defaults: defaults)
    }

    private func entitlements(
        tier: SupporterTier?,
        dcExpiration: Date? = nil,
        history: Bool = true,
        tips: Int = 0
    ) -> SupporterEntitlements {
        var value = SupporterEntitlements()
        value.activeTier = tier
        value.activeProductID = switch tier {
        case .frontRow: SupporterProduct.monthly.rawValue
        case .directorsCut: SupporterProduct.directorsCutMonthly.rawValue
        case nil: nil
        }
        value.activeExpirationDate = tier == .directorsCut ? dcExpiration : nil
        value.hasAnySupport = history
        value.historyWasEmpty = !history
        value.earliestPurchase = history ? now.addingTimeInterval(-90 * day) : nil
        value.latestDirectorsCutExpiration = history ? dcExpiration : nil
        value.tipCount = tips
        return value
    }

    @Test func supporterStatusSurvivesLapseAndEmptyReads() {
        let store = makeStore()
        store.apply(entitlements(tier: .directorsCut, dcExpiration: now.addingTimeInterval(20 * day), tips: 2))
        #expect(store.isSupporter)
        #expect(store.hasDirectorsCut)

        store.apply(entitlements(tier: nil, history: false))
        #expect(store.isSupporter)
        #expect(store.tipCount == 2)
        #expect(store.supporterSince != nil)
        #expect(store.activeTier == nil)
    }

    @Test func transientEmptyReadDoesNotRevertIconMidPeriod() {
        let store = makeStore()
        store.apply(entitlements(tier: .directorsCut, dcExpiration: now.addingTimeInterval(20 * day)))
        store.apply(entitlements(tier: nil, history: false))
        #expect(!store.shouldRevertExclusiveIcon(now: now))
        #expect(store.shouldRevertExclusiveIcon(now: now.addingTimeInterval(21 * day)))
    }

    @Test func lapseRevertsOnceThePeriodIsOver() {
        let store = makeStore()
        store.apply(entitlements(tier: .directorsCut, dcExpiration: now.addingTimeInterval(-day)))
        store.apply(entitlements(tier: nil, dcExpiration: now.addingTimeInterval(-day)))
        #expect(store.isSupporter)
        #expect(!store.hasDirectorsCut)
        #expect(store.shouldRevertExclusiveIcon(now: now))
    }

    @Test func downgradeToFrontRowLocksExclusives() {
        let store = makeStore()
        store.apply(entitlements(tier: .directorsCut, dcExpiration: now.addingTimeInterval(-60)))
        store.apply(entitlements(tier: .frontRow, dcExpiration: now.addingTimeInterval(-60)))
        #expect(store.activeTier == .frontRow)
        #expect(store.hasActiveSubscription)
        #expect(!store.hasDirectorsCut)
        #expect(store.shouldRevertExclusiveIcon(now: now))
        #expect(store.isUnlocked(.goldenHour))
        #expect(!store.isUnlocked(.eclipse))
    }

    @Test func refundReadOverridesCachedPeriod() {
        let store = makeStore()
        store.apply(entitlements(tier: .directorsCut, dcExpiration: now.addingTimeInterval(20 * day)))
        // History present but the Director's Cut transaction was revoked.
        var refunded = entitlements(tier: nil)
        refunded.latestDirectorsCutExpiration = nil
        store.apply(refunded)
        #expect(store.shouldRevertExclusiveIcon(now: now))
    }

    @Test func cacheIsRestoredOnRelaunch() {
        let suite = "SupporterStoreCacheTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let expiration = now.addingTimeInterval(10 * day)

        let first = SupporterStore(defaults: defaults)
        first.apply(entitlements(tier: .directorsCut, dcExpiration: expiration, tips: 1))

        let relaunched = SupporterStore(defaults: defaults)
        #expect(relaunched.isSupporter)
        #expect(relaunched.tipCount == 1)
        #expect(relaunched.lastKnownDirectorsCutExpiration == expiration)
        // The level itself is never cached: it waits for a live read.
        #expect(relaunched.activeTier == nil)
        #expect(!relaunched.shouldRevertExclusiveIcon(now: now))
    }
}
