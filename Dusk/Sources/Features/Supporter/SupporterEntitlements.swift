import Foundation

/// The two subscription levels in the "Dusk Supporter" App Store group.
/// A higher raw value is the higher level of service. (App Store Connect
/// numbers levels the other way round: Director's Cut is level 1, Front Row
/// level 2.) StoreKit applies a move up immediately as an upgrade and a move
/// down at the next renewal.
enum SupporterTier: Int, CaseIterable, Comparable, Identifiable {
    case frontRow = 1
    case directorsCut = 2

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .frontRow: "Front Row"
        case .directorsCut: "Director's Cut"
        }
    }

    static func < (lhs: SupporterTier, rhs: SupporterTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

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
/// This is a snapshot, not supporter status: the monotonic "supporter
/// forever" rule lives in `SupporterStore`, which only ever lets a snapshot
/// add evidence on top of its cache.
struct SupporterEntitlements: Equatable {
    /// The highest subscription level currently in force, if any.
    var activeTier: SupporterTier?
    var activeProductID: String?
    var activeExpirationDate: Date?
    /// Any verified, unrevoked supporter purchase exists in the history.
    var hasAnySupport = false
    var earliestPurchase: Date?
    var tipCount = 0
    /// Latest expiration among unrevoked Director's Cut transactions in the
    /// history. Nil when the history has none (or none survived a refund).
    var latestDirectorsCutExpiration: Date?
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

        // Within a group StoreKit keeps the upgraded-from transaction around
        // with `isUpgraded`; it no longer grants access. A pending downgrade
        // is not a transaction yet, so the higher level stays in force until
        // it renews into the lower one.
        let active = current.filter { record in
            guard SupporterProduct(rawValue: record.productID)?.tier != nil else { return false }
            if record.revocationDate != nil || record.isUpgraded { return false }
            if let expiration = record.expirationDate, expiration <= now { return false }
            return true
        }
        let best = active.max { lhs, rhs in
            let lhsTier = SupporterProduct(rawValue: lhs.productID)?.tier ?? .frontRow
            let rhsTier = SupporterProduct(rawValue: rhs.productID)?.tier ?? .frontRow
            if lhsTier != rhsTier { return lhsTier < rhsTier }
            return (lhs.expirationDate ?? .distantFuture) < (rhs.expirationDate ?? .distantFuture)
        }
        if let best {
            result.activeTier = SupporterProduct(rawValue: best.productID)?.tier
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
            if product.tier == nil {
                result.tipCount += max(record.purchasedQuantity, 1)
            }
            if product.tier == .directorsCut, let expiration = record.expirationDate {
                result.latestDirectorsCutExpiration = max(
                    result.latestDirectorsCutExpiration ?? expiration,
                    expiration
                )
            }
        }

        return result
    }

    /// Whether an exclusive (Director's Cut) app icon must be switched back to
    /// the default. Only once the App Store no longer shows Director's Cut
    /// *and* the last known Director's Cut period has run out, so a transient
    /// empty entitlement read mid-period never flips someone's icon.
    static func shouldRevertExclusiveIcon(
        activeTier: SupporterTier?,
        lastKnownDirectorsCutExpiration: Date?,
        now: Date = Date()
    ) -> Bool {
        guard activeTier != .directorsCut else { return false }
        guard let lastKnownDirectorsCutExpiration else { return true }
        return lastKnownDirectorsCutExpiration <= now
    }
}

/// What happens to the active subscription at its next renewal, from the
/// subscription status' renewal info.
struct SupporterRenewalPlan: Equatable {
    /// Product the subscription renews into (differs from the active product
    /// after a downgrade or a monthly/yearly switch).
    var nextProductID: String?
    var willAutoRenew: Bool
    var renewalDate: Date?

    var nextTier: SupporterTier? {
        nextProductID.flatMap { SupporterProduct(rawValue: $0)?.tier }
    }

    /// A move to a lower level that starts at the next renewal.
    func pendingDowngrade(from activeTier: SupporterTier?) -> SupporterTier? {
        guard willAutoRenew, let activeTier, let nextTier, nextTier < activeTier else { return nil }
        return nextTier
    }
}
