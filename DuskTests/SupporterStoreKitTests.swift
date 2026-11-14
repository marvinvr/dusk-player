import Foundation
import StoreKit
import StoreKitTest
import Testing
@testable import Dusk

/// End-to-end purchase flows against the local `Dusk.storekit` configuration:
/// buy, switch plans, lapse, restore, refund. Serialized because the StoreKit
/// test environment is shared process state.
@Suite("Supporter StoreKit flows", .serialized, .timeLimit(.minutes(1)))
@MainActor
final class SupporterStoreKitTests {
    private let session: SKTestSession
    private let suiteName = "SupporterStoreKitTests.\(UUID().uuidString)"

    init() throws {
        session = try SKTestSession(configurationFileNamed: "Dusk")
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
    }

    deinit {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }

    private func makeStore() async -> SupporterStore {
        let store = SupporterStore(defaults: UserDefaults(suiteName: suiteName)!)
        await store.loadProducts()
        return store
    }

    private func product(_ id: SupporterProduct, in store: SupporterStore) throws -> Product {
        try #require((store.subscriptionProducts + store.tipProducts).first { $0.id == id.rawValue })
    }

    /// The CLI prepares the local session in a separate catalog-only launch.
    /// StoreKit chooses its environment at process startup on a fresh simulator;
    /// installing SKTestSession afterward cannot change that process's receipt.
    private func purchase(_ id: SupporterProduct, in store: SupporterStore) async throws {
        let receipt: VerificationResult<AppTransaction>
        do { receipt = try await AppTransaction.shared }
        catch { throw StoreKitFixtureError.needsPreparation }
        guard case .verified(let app) = receipt, app.environment == .xcode else {
            throw StoreKitFixtureError.needsPreparation
        }
        await store.purchase(try product(id, in: store))
    }

    /// StoreKit applies expirations and renewals asynchronously; poll briefly.
    private func refresh(
        _ store: SupporterStore,
        until condition: (SupporterStore) -> Bool
    ) async -> Bool {
        for _ in 0..<40 {
            await store.refreshEntitlements()
            if condition(store) { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
    }

    /// Lets a subscription run out: auto-renew off, then expire it. Expiring
    /// alone leaves an auto-renewing test subscription in force.
    private func lapse(_ productID: String) throws {
        for transaction in session.allTransactions() where transaction.productIdentifier == productID {
            try? session.disableAutoRenewForTransaction(identifier: transaction.identifier)
        }
        try session.expireSubscription(productIdentifier: productID)
    }

    @Test func catalogHasOneSubscriptionWithTwoPlans() async throws {
        let store = await makeStore()
        #expect(!store.productsUnavailable)
        #expect(store.subscriptionProducts.map(\.id) == ["supporter.monthly", "supporter.yearly"])
        #expect(store.subscriptionProducts.map(\.price) == [Decimal(string: "2.99"), Decimal(string: "24.99")])
        #expect(store.tipProducts.count == 4)

        let monthly = try product(.monthly, in: store)
        let yearly = try product(.yearly, in: store)
        #expect(monthly.displayName == "Dusk Supporter Monthly")
        // Same group, same level: monthly <-> yearly is a crossgrade.
        #expect(monthly.subscription?.subscriptionGroupID == yearly.subscription?.subscriptionGroupID)
        #expect(monthly.subscription?.groupLevel == 1)
        #expect(yearly.subscription?.groupLevel == 1)
        // Family Sharing stays off, as for the plans that shipped in 1.6.
        #expect(!monthly.isFamilyShareable)
        #expect(!yearly.isFamilyShareable)
    }

    @Test func subscriptionUnlocksEveryIconAndSwitchesPlanAtRenewal() async throws {
        let store = await makeStore()
        #expect(!store.isSupporter)
        #expect(!store.isUnlocked(.neon))

        try await purchase(.monthly, in: store)
        #expect(store.hasActiveSubscription)
        #expect(store.isSupporter)
        #expect(store.isUnlocked(.neon))
        #expect(store.isUnlocked(.gilded))

        // Switching to yearly is scheduled for the next renewal.
        try await purchase(.yearly, in: store)
        #expect(await refresh(store) { $0.renewalPlan?.nextProductID == "supporter.yearly" })
        #expect(store.activeProductID == "supporter.monthly")
        #expect(!store.shouldRevertIcon(.gilded))

        try session.forceRenewalOfSubscription(productIdentifier: "supporter.monthly")
        #expect(await refresh(store) { $0.activeProductID == "supporter.yearly" })
        #expect(store.isUnlocked(.velvet))
    }

    @Test func lapseLocksIconsAndOnlyAGenerousTipBringsTheClassicsBack() async throws {
        let store = await makeStore()
        try await purchase(.yearly, in: store)
        #expect(!store.shouldRevertIcon(.gilded))

        try lapse("supporter.yearly")
        #expect(await refresh(store) { !$0.hasActiveSubscription })
        #expect(store.isSupporter)
        #expect(!store.isUnlocked(.gilded))
        #expect(!store.isUnlocked(.neon))
        #expect(store.shouldRevertIcon(.gilded))
        #expect(store.shouldRevertIcon(.neon))

        // The Coffee tip is a thank-you only.
        try await purchase(.tipCoffee, in: store)
        #expect(store.tipCount == 1)
        #expect(!store.isUnlocked(.neon))

        // Generous and up are one-time purchases that keep the classic icons,
        // never the subscriber exclusives.
        try await purchase(.tipGenerous, in: store)
        #expect(store.hasIconTip)
        #expect(store.isUnlocked(.neon))
        #expect(!store.shouldRevertIcon(.neon))
        #expect(!store.isUnlocked(.velvet))
        #expect(store.shouldRevertIcon(.velvet))
    }

    @Test func restoreRecoversStatusOnAFreshInstall() async throws {
        let buyer = await makeStore()
        try await purchase(.monthly, in: buyer)
        try await purchase(.tipCoffee, in: buyer)
        #expect(buyer.tipCount == 1)

        // A fresh install: empty cache, same App Store account.
        let freshSuite = "SupporterStoreKitTests.fresh.\(UUID().uuidString)"
        let freshDefaults = UserDefaults(suiteName: freshSuite)!
        defer { freshDefaults.removePersistentDomain(forName: freshSuite) }
        let fresh = SupporterStore(defaults: freshDefaults)
        #expect(!fresh.isSupporter)

        await fresh.restorePurchases()
        #expect(fresh.isSupporter)
        #expect(fresh.activeProductID == "supporter.monthly")
        #expect(fresh.isUnlocked(.emerald))
        #expect(fresh.tipCount == 1)
        #expect(fresh.supporterSince != nil)
    }

    @Test func refundRemovesTheSubscription() async throws {
        let store = await makeStore()
        try await purchase(.monthly, in: store)
        let transaction = try #require(session.allTransactions().first { $0.productIdentifier == "supporter.monthly" })

        try session.refundTransaction(identifier: UInt(transaction.identifier))
        #expect(await refresh(store) { !$0.hasActiveSubscription })
        #expect(store.shouldRevertIcon(.gilded))
        #expect(store.shouldRevertIcon(.neon))
    }
}

private enum StoreKitFixtureError: LocalizedError {
    case needsPreparation
    var errorDescription: String? {
        "StoreKit is not using the local Xcode environment. Run scripts/test_units.py to prepare it before the purchase suite."
    }
}
