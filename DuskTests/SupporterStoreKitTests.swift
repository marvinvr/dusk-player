import Foundation
import StoreKit
import StoreKitTest
import Testing
@testable import Dusk

/// End-to-end purchase flows against the local `Dusk.storekit` configuration:
/// buy, upgrade, downgrade, lapse, restore. Serialized because the StoreKit
/// test environment is shared process state.
@Suite("Supporter StoreKit flows", .serialized)
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

    @Test func catalogLoadsBothLevels() async throws {
        let store = await makeStore()
        #expect(!store.productsUnavailable)
        #expect(store.products(for: .frontRow).map(\.id) == ["supporter.monthly", "supporter.yearly"])
        #expect(store.products(for: .directorsCut).map(\.id) == ["directorscut.monthly", "directorscut.yearly"])
        #expect(store.products(for: .directorsCut).map(\.price) == [Decimal(string: "4.99"), Decimal(string: "39.99")])
        #expect(store.tipProducts.count == 4)

        let frontRow = try product(.monthly, in: store)
        let directorsCut = try product(.directorsCutMonthly, in: store)
        #expect(frontRow.subscription?.subscriptionGroupID == directorsCut.subscription?.subscriptionGroupID)
        #expect(frontRow.displayName == "Front Row Monthly")
        // App Store levels count down: Director's Cut (1) outranks Front Row (2).
        #expect(directorsCut.subscription?.groupLevel == 1)
        #expect(frontRow.subscription?.groupLevel == 2)
        // Family Sharing: on for Director's Cut, off for Front Row (as in App Store Connect).
        #expect(directorsCut.isFamilyShareable)
        #expect(!frontRow.isFamilyShareable)
    }

    @Test func buyUpgradeAndDowngrade() async throws {
        let store = await makeStore()
        #expect(!store.isSupporter)

        // Buy Front Row.
        await store.purchase(try product(.monthly, in: store))
        #expect(store.activeTier == .frontRow)
        #expect(store.isSupporter)
        #expect(!store.hasDirectorsCut)

        // Upgrade: Director's Cut applies immediately.
        await store.purchase(try product(.directorsCutMonthly, in: store))
        #expect(await refresh(store) { $0.activeTier == .directorsCut })
        #expect(store.activeProductID == "directorscut.monthly")
        #expect(store.isUnlocked(.eclipse))

        // Downgrade: scheduled for the next renewal, Director's Cut stays.
        await store.purchase(try product(.monthly, in: store))
        #expect(await refresh(store) { $0.pendingDowngradeTier == .frontRow })
        #expect(store.activeTier == .directorsCut)
        #expect(!store.shouldRevertExclusiveIcon())

        // Renewal moves to Front Row and locks the exclusives.
        try session.forceRenewalOfSubscription(productIdentifier: "directorscut.monthly")
        #expect(await refresh(store) { $0.activeTier == .frontRow })
        #expect(!store.isUnlocked(.velvet))
        #expect(store.isUnlocked(.neon))
    }

    @Test func directorsCutLapseRevertsExclusives() async throws {
        let store = await makeStore()
        await store.purchase(try product(.directorsCutYearly, in: store))
        #expect(store.activeTier == .directorsCut)
        #expect(!store.shouldRevertExclusiveIcon())

        try lapse("directorscut.yearly")
        #expect(await refresh(store) { $0.activeTier == nil })
        #expect(store.isSupporter)
        #expect(!store.isUnlocked(.eclipse))
        #expect(store.isUnlocked(.aurora))
        #expect(store.shouldRevertExclusiveIcon())
    }

    @Test func restoreRecoversStatusOnAFreshInstall() async throws {
        let buyer = await makeStore()
        await buyer.purchase(try product(.directorsCutMonthly, in: buyer))
        await buyer.purchase(try product(.tipCoffee, in: buyer))
        #expect(buyer.tipCount == 1)

        // A fresh install: empty cache, same App Store account.
        let freshSuite = "SupporterStoreKitTests.fresh.\(UUID().uuidString)"
        let freshDefaults = UserDefaults(suiteName: freshSuite)!
        defer { freshDefaults.removePersistentDomain(forName: freshSuite) }
        let fresh = SupporterStore(defaults: freshDefaults)
        #expect(!fresh.isSupporter)

        await fresh.restorePurchases()
        #expect(fresh.isSupporter)
        #expect(fresh.activeTier == .directorsCut)
        #expect(fresh.tipCount == 1)
        #expect(fresh.supporterSince != nil)
    }

    @Test func refundRemovesDirectorsCut() async throws {
        let store = await makeStore()
        await store.purchase(try product(.directorsCutMonthly, in: store))
        let transaction = try #require(session.allTransactions().first { $0.productIdentifier == "directorscut.monthly" })

        try session.refundTransaction(identifier: UInt(transaction.identifier))
        #expect(await refresh(store) { $0.activeTier == nil })
        #expect(store.shouldRevertExclusiveIcon())
    }
}
