import Foundation

/// The StoreKit fields entitlement resolution needs, copied out of a verified
/// `Transaction` so the rules can be exercised without the App Store.
struct SupporterTransactionRecord: Equatable {
    var productID: String
    var originalPurchaseDate: Date
    var expirationDate: Date?
    var revocationDate: Date?
    var isUpgraded: Bool = false
    var purchasedQuantity: Int = 1
}

/// What the App Store says the user has, resolved from one read of
/// `Transaction.currentEntitlements` and one of `Transaction.all`.
///
/// This is a snapshot, not supporter status: the monotonic supporter flag
/// lives in `SupporterStore`, which only ever lets a snapshot add evidence on
/// top of its cache. Icon access is not monotonic (see `shouldRevertIcon`).
struct SupporterEntitlements: Equatable {
    /// The subscription currently in force, if any.
    var activeProductID: String?
    var activeExpirationDate: Date?
    /// Any verified, unrevoked supporter purchase exists in the history.
    var hasAnySupport = false
    var earliestPurchase: Date?
    var tipCount = 0
    /// A tip from Generous up exists in the history (`SupporterProduct.isIconTip`).
    var hasIconTip = false
    /// Most recent unrevoked tip purchase (snoozes the supporter prompt).
    var latestTipPurchase: Date?
    /// Latest expiration among unrevoked subscription transactions in the
    /// history. Nil when the history has none (or none survived a refund).
    var latestSubscriptionExpiration: Date?
    /// True when the history read produced no recognised transactions at all.
    /// An empty read is indistinguishable from an offline/transient failure,
    /// so callers must not let it erase cached knowledge.
    var historyWasEmpty = true

    static func resolve(
        current: [SupporterTransactionRecord],
        history: [SupporterTransactionRecord],
        now: Date = Date()
    ) -> SupporterEntitlements {
        var result = SupporterEntitlements()

        // StoreKit can keep an upgraded-from transaction around with
        // `isUpgraded`; it no longer grants access.
        let active = current.filter { record in
            guard SupporterProduct(rawValue: record.productID)?.isSubscription == true else { return false }
            if record.revocationDate != nil || record.isUpgraded { return false }
            if let expiration = record.expirationDate, expiration <= now { return false }
            return true
        }
        let best = active.max { lhs, rhs in
            (lhs.expirationDate ?? .distantFuture) < (rhs.expirationDate ?? .distantFuture)
        }
        if let best {
            result.activeProductID = best.productID
            result.activeExpirationDate = best.expirationDate
        }

        for record in history {
            guard let product = SupporterProduct(rawValue: record.productID) else { continue }
            result.historyWasEmpty = false
            guard record.revocationDate == nil else { continue }
            result.hasAnySupport = true
            let purchaseDate = record.originalPurchaseDate
            result.earliestPurchase = min(result.earliestPurchase ?? purchaseDate, purchaseDate)
            if !product.isSubscription {
                result.tipCount += max(record.purchasedQuantity, 1)
                // Every consumable purchase is its own transaction, so the
                // original purchase date is that tip's date.
                result.latestTipPurchase = max(result.latestTipPurchase ?? purchaseDate, purchaseDate)
            }
            if product.isIconTip {
                result.hasIconTip = true
            }
            if product.isSubscription, let expiration = record.expirationDate {
                result.latestSubscriptionExpiration = max(
                    result.latestSubscriptionExpiration ?? expiration,
                    expiration
                )
            }
        }

        return result
    }

    var hasActiveSubscription: Bool { activeProductID != nil }

    /// Whether the app icon that is currently set must be switched back to
    /// the default. Subscription perks only last while the subscription does:
    /// Velvet, Emerald, Gilded and Sapphire need it, a classic alternate needs it or a
    /// tip from Generous up (one-time, kept). Only reverts once the App Store
    /// no longer shows a subscription *and* the last known period has run
    /// out, so a transient empty entitlement read mid-period never flips
    /// someone's icon.
    static func shouldRevertIcon(
        _ icon: DuskAppIcon,
        hasActiveSubscription: Bool,
        hasIconTip: Bool,
        lastKnownSubscriptionExpiration: Date?,
        now: Date = Date()
    ) -> Bool {
        guard icon.requiresSupporter, !hasActiveSubscription else { return false }
        if !icon.requiresSubscription, hasIconTip { return false }
        return lastKnownSubscriptionExpiration.map { $0 <= now } ?? true
    }
}

/// What happens to the active subscription at its next renewal, from the
/// subscription status' renewal info.
struct SupporterRenewalPlan: Equatable {
    /// Product the subscription renews into (differs from the active product
    /// after a monthly/yearly switch).
    var nextProductID: String?
    var willAutoRenew: Bool
    var renewalDate: Date?
}
