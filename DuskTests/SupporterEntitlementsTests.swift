import Foundation
import Testing
@testable import Dusk

/// Pure entitlement rules: whether the subscription is in force, what counts
/// as support, and when a subscription icon has to go.
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

    /// Whether `icon`, if set, would be switched back to the default.
    private func reverts(_ icon: DuskAppIcon, _ result: SupporterEntitlements) -> Bool {
        SupporterEntitlements.shouldRevertIcon(
            icon,
            hasActiveSubscription: result.hasActiveSubscription,
            hasIconTip: result.hasIconTip,
            lastKnownSubscriptionExpiration: result.latestSubscriptionExpiration,
            now: now
        )
    }

    // MARK: Catalog

    @Test func catalogIsOneSubscriptionPlusTips() {
        // The subscription IDs are the ones that shipped in 1.6: existing
        // subscribers resolve without any migration.
        #expect(SupporterProduct.monthly.rawValue == "supporter.monthly")
        #expect(SupporterProduct.yearly.rawValue == "supporter.yearly")
        #expect(SupporterProduct.allCases.filter(\.isSubscription) == [.monthly, .yearly])
        #expect(SupporterProduct.allCases.filter(\.isYearly) == [.yearly])
        #expect(SupporterProduct.allCases.filter(\.isIconTip) == [.tipGenerous, .tipLegendary, .tipPatron])
        #expect(SupporterProduct.allCases.map(\.sortOrder) == Array(0..<SupporterProduct.allCases.count))
    }

    // MARK: Active subscription

    @Test func nothingPurchased() {
        let result = SupporterEntitlements.resolve(current: [], history: [], now: now)
        #expect(!result.hasActiveSubscription)
        #expect(!result.hasAnySupport)
        #expect(result.historyWasEmpty)
    }

    @Test func activeSubscriptionKeepsEveryIcon() {
        for plan in [SupporterProduct.monthly, .yearly] {
            let sub = record(plan, expires: 200)
            let result = SupporterEntitlements.resolve(current: [sub], history: [sub], now: now)
            #expect(result.hasActiveSubscription)
            #expect(result.activeProductID == plan.rawValue)
            #expect(result.hasAnySupport)
            #expect(result.latestSubscriptionExpiration == now.addingTimeInterval(200 * day))
            for icon in DuskAppIcon.allCases {
                #expect(!reverts(icon, result))
            }
        }
    }

    @Test func grandfatheredSubscriberFromBefore17GetsEverything() {
        // Subscribed in 1.6 (at the old price), auto-renewing ever since.
        let original = record(.monthly, purchased: -400, expires: 12)
        let result = SupporterEntitlements.resolve(current: [original], history: [original], now: now)
        #expect(result.hasActiveSubscription)
        #expect(result.earliestPurchase == now.addingTimeInterval(-400 * day))
        #expect(!reverts(.gilded, result))
        #expect(!reverts(.neon, result))
    }

    @Test func upgradedTransactionAloneGrantsNothing() {
        let sub = record(.monthly, upgraded: true)
        let result = SupporterEntitlements.resolve(current: [sub], history: [sub], now: now)
        #expect(!result.hasActiveSubscription)
        #expect(result.hasAnySupport)
    }

    @Test func planSwitchTakesEffectAtRenewal() {
        // Monthly ran out, yearly took over at the renewal.
        let monthly = record(.monthly, purchased: -40, expires: -10)
        let yearly = record(.yearly, purchased: -40, expires: 355)
        let result = SupporterEntitlements.resolve(current: [yearly], history: [monthly, yearly], now: now)
        #expect(result.activeProductID == "supporter.yearly")
        #expect(!reverts(.gilded, result))
    }

    // MARK: Lapse & refunds

    @Test func lapsedSubscriptionKeepsSupporterButLocksAllIcons() {
        let sub = record(.monthly, purchased: -60, expires: -2)
        // Expired transactions can still show up in a stale current read.
        let result = SupporterEntitlements.resolve(current: [sub], history: [sub], now: now)
        #expect(!result.hasActiveSubscription)
        #expect(result.hasAnySupport)
        #expect(result.earliestPurchase == now.addingTimeInterval(-60 * day))
        #expect(result.latestSubscriptionExpiration == now.addingTimeInterval(-2 * day))
        #expect(reverts(.gilded, result))
        #expect(reverts(.neon, result))
        #expect(!reverts(.dusk, result))
    }

    @Test func generousTipKeepsClassicIconsAfterALapse() {
        let sub = record(.yearly, purchased: -400, expires: -30)
        let tip = record(.tipGenerous, purchased: -90)
        let result = SupporterEntitlements.resolve(current: [], history: [sub, tip], now: now)
        #expect(!reverts(.aurora, result))
        #expect(reverts(.velvet, result))
    }

    @Test func coffeeTipDoesNotKeepIconsAfterALapse() {
        let sub = record(.monthly, purchased: -60, expires: -30)
        let tip = record(.tipCoffee, purchased: -90)
        let result = SupporterEntitlements.resolve(current: [], history: [sub, tip], now: now)
        #expect(reverts(.aurora, result))
    }

    @Test func refundedSubscriptionGrantsNothing() {
        let sub = record(.monthly, expires: 20, revoked: true)
        let result = SupporterEntitlements.resolve(current: [sub], history: [sub], now: now)
        #expect(!result.hasActiveSubscription)
        #expect(!result.hasAnySupport)
        #expect(!result.historyWasEmpty)
        #expect(result.latestSubscriptionExpiration == nil)
        #expect(reverts(.gilded, result))
    }

    @Test func tipsCountTowardSupportButNoSubscription() {
        let tips = [record(.tipCoffee), record(.tipPatron, quantity: 2)]
        let result = SupporterEntitlements.resolve(current: [], history: tips, now: now)
        #expect(!result.hasActiveSubscription)
        #expect(result.hasAnySupport)
        #expect(result.tipCount == 3)
        #expect(result.hasIconTip)
    }

    @Test func coffeeTipAloneUnlocksNoIcons() {
        let result = SupporterEntitlements.resolve(current: [], history: [record(.tipCoffee, quantity: 3)], now: now)
        #expect(result.hasAnySupport)
        #expect(!result.hasIconTip)
        #expect(reverts(.neon, result))
        #expect(reverts(.velvet, result))
    }

    @Test func generousTipKeepsClassicIconsButNeverExclusives() {
        for tip in [SupporterProduct.tipGenerous, .tipLegendary, .tipPatron] {
            let result = SupporterEntitlements.resolve(current: [], history: [record(tip, purchased: -900)], now: now)
            #expect(result.hasIconTip)
            #expect(!reverts(.neon, result))
            #expect(reverts(.gilded, result))
        }
    }

    @Test func refundedGenerousTipUnlocksNothing() {
        let result = SupporterEntitlements.resolve(current: [], history: [record(.tipGenerous, revoked: true)], now: now)
        #expect(!result.hasIconTip)
    }

    @Test func revertRuleWaitsForTheKnownPeriodToEnd() {
        let future = now.addingTimeInterval(5 * day)
        let past = now.addingTimeInterval(-day)
        func reverts(_ icon: DuskAppIcon, active: Bool = false, iconTip: Bool = false, expiration: Date?) -> Bool {
            SupporterEntitlements.shouldRevertIcon(
                icon,
                hasActiveSubscription: active,
                hasIconTip: iconTip,
                lastKnownSubscriptionExpiration: expiration,
                now: now
            )
        }
        // Exclusives follow the subscription only.
        #expect(!reverts(.gilded, active: true, expiration: past))
        #expect(!reverts(.gilded, expiration: future))
        #expect(reverts(.gilded, expiration: past))
        #expect(reverts(.gilded, expiration: nil))
        #expect(reverts(.gilded, iconTip: true, expiration: nil))
        // Classic alternates follow the subscription, or a tip from Generous up.
        #expect(!reverts(.neon, active: true, expiration: past))
        #expect(!reverts(.neon, expiration: future))
        #expect(reverts(.neon, expiration: past))
        #expect(reverts(.neon, expiration: nil))
        #expect(!reverts(.neon, iconTip: true, expiration: past))
        // The primary icon never reverts.
        #expect(!reverts(.dusk, expiration: nil))
    }

    // MARK: Icons

    @Test func iconAccess() {
        for icon in DuskAppIcon.allCases {
            #expect(icon.isUnlocked(hasIconAccess: false, hasActiveSubscription: false) == (icon == .dusk))
            #expect(icon.isUnlocked(hasIconAccess: true, hasActiveSubscription: false) == !icon.requiresSubscription)
            #expect(icon.isUnlocked(hasIconAccess: true, hasActiveSubscription: true))
        }
        #expect(DuskAppIcon.subscriptionIcons == [.velvet, .emerald, .gilded])
        #expect(DuskAppIcon.supporterIcons.count == 7)
        #expect(DuskAppIcon.supporterIcons.first == .dusk)
    }

    @Test func iconNamesAreUnique() {
        let alternates = DuskAppIcon.allCases.compactMap(\.alternateIconName)
        #expect(Set(alternates).count == DuskAppIcon.allCases.count - 1)
        #expect(Set(DuskAppIcon.allCases.map(\.previewImageName)).count == DuskAppIcon.allCases.count)
        #expect(DuskAppIcon.emerald.alternateIconName == "DuskIconEmerald")
        #expect(DuskAppIcon.gilded.alternateIconName == "DuskIconGilded")
        #expect(DuskAppIcon.velvet.alternateIconName == "DuskIconVelvet")
    }
}

/// The store's cache rules on top of the snapshots: supporter status is
/// monotonic, the active subscription and its icons follow the latest
/// snapshot.
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
        active: Bool,
        expiration: Date? = nil,
        history: Bool = true,
        tips: Int = 0,
        iconTip: Bool = false
    ) -> SupporterEntitlements {
        var value = SupporterEntitlements()
        value.activeProductID = active ? SupporterProduct.monthly.rawValue : nil
        value.activeExpirationDate = active ? expiration : nil
        value.hasAnySupport = history
        value.historyWasEmpty = !history
        value.earliestPurchase = history ? now.addingTimeInterval(-90 * day) : nil
        value.latestSubscriptionExpiration = history ? expiration : nil
        value.tipCount = tips
        value.hasIconTip = iconTip
        return value
    }

    @Test func supporterStatusSurvivesLapseAndEmptyReads() {
        let store = makeStore()
        store.apply(entitlements(active: true, expiration: now.addingTimeInterval(20 * day), tips: 2))
        #expect(store.isSupporter)
        #expect(store.hasActiveSubscription)

        store.apply(entitlements(active: false, history: false))
        #expect(store.isSupporter)
        #expect(store.tipCount == 2)
        #expect(store.supporterSince != nil)
        #expect(!store.hasActiveSubscription)
    }

    @Test func transientEmptyReadDoesNotRevertIconMidPeriod() {
        let store = makeStore()
        store.apply(entitlements(active: true, expiration: now.addingTimeInterval(20 * day)))
        store.apply(entitlements(active: false, history: false))
        #expect(!store.shouldRevertIcon(.gilded, now: now))
        #expect(!store.shouldRevertIcon(.neon, now: now))
        #expect(store.shouldRevertIcon(.gilded, now: now.addingTimeInterval(21 * day)))
        #expect(store.shouldRevertIcon(.neon, now: now.addingTimeInterval(21 * day)))
    }

    @Test func lapseRevertsOnceThePeriodIsOver() {
        let store = makeStore()
        store.apply(entitlements(active: true, expiration: now.addingTimeInterval(-day)))
        #expect(store.isUnlocked(.gilded))
        store.apply(entitlements(active: false, expiration: now.addingTimeInterval(-day)))
        #expect(store.isSupporter)
        #expect(!store.hasIconAccess)
        #expect(!store.isUnlocked(.gilded))
        #expect(!store.isUnlocked(.neon))
        #expect(store.shouldRevertIcon(.gilded, now: now))
        #expect(store.shouldRevertIcon(.neon, now: now))
    }

    @Test func coffeeTipAloneUnlocksNoIcons() {
        let store = makeStore()
        store.apply(entitlements(active: false, tips: 2))
        #expect(store.isSupporter)
        #expect(!store.hasIconAccess)
        #expect(!store.isUnlocked(.neon))
        #expect(store.shouldRevertIcon(.neon, now: now))
    }

    @Test func generousTipKeepsClassicIconsAfterALapse() {
        let store = makeStore()
        store.apply(entitlements(active: true, expiration: now.addingTimeInterval(-day), tips: 1, iconTip: true))
        store.apply(entitlements(active: false, expiration: now.addingTimeInterval(-day), tips: 1, iconTip: true))
        #expect(store.hasIconAccess)
        #expect(store.isUnlocked(.neon))
        #expect(!store.shouldRevertIcon(.neon, now: now))
        #expect(!store.isUnlocked(.velvet))
        #expect(store.shouldRevertIcon(.velvet, now: now))
    }

    @Test func refundReadOverridesCachedPeriod() {
        let store = makeStore()
        store.apply(entitlements(active: true, expiration: now.addingTimeInterval(20 * day)))
        // History present but the subscription transaction was revoked.
        store.apply(entitlements(active: false))
        #expect(store.shouldRevertIcon(.gilded, now: now))
        #expect(store.shouldRevertIcon(.neon, now: now))
    }

    @Test func cacheIsRestoredOnRelaunch() {
        let suite = "SupporterStoreCacheTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let expiration = now.addingTimeInterval(10 * day)

        let first = SupporterStore(defaults: defaults)
        first.apply(entitlements(active: true, expiration: expiration, tips: 1, iconTip: true))

        let relaunched = SupporterStore(defaults: defaults)
        #expect(relaunched.isSupporter)
        #expect(relaunched.tipCount == 1)
        #expect(relaunched.hasIconTip)
        #expect(relaunched.lastKnownSubscriptionExpiration == expiration)
        // The subscription itself is never cached: it waits for a live read,
        // but the cached period keeps the icon in the meantime.
        #expect(!relaunched.hasActiveSubscription)
        #expect(!relaunched.shouldRevertIcon(.gilded, now: now))
    }
}
