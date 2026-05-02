import XCTest
@testable import ForsettiPlatform

#if canImport(StoreKit)
final class StoreKit2EntitlementProviderTests: XCTestCase {
    func testRefreshEntitlementsUnlocksMatchingProduct() async {
        let state = TestStoreKitState(productIDs: [])
        let provider = StoreKit2EntitlementProvider(
            fetchCurrentEntitlements: { await state.currentProductIDs() },
            syncAction: { await state.recordSyncCall() },
            observeTransactionUpdates: false
        )

        let initiallyUnlocked = await provider.isUnlocked(
            moduleID: "com.forsetti.module.example-ui",
            productID: "com.forsetti.iap.example-ui"
        )
        XCTAssertFalse(initiallyUnlocked)

        await state.setProductIDs(["com.forsetti.iap.example-ui"])
        await provider.refreshEntitlements()

        let unlockedAfterRefresh = await provider.isUnlocked(
            moduleID: "com.forsetti.module.example-ui",
            productID: "com.forsetti.iap.example-ui"
        )
        XCTAssertTrue(unlockedAfterRefresh)
    }

    func testRestorePurchasesInvokesSyncAndRefresh() async throws {
        let state = TestStoreKitState(productIDs: [])
        let provider = StoreKit2EntitlementProvider(
            fetchCurrentEntitlements: { await state.currentProductIDs() },
            syncAction: {
                await state.recordSyncCall()
                await state.setProductIDs(["com.forsetti.iap.example-ui"])
            },
            observeTransactionUpdates: false
        )

        try await provider.restorePurchases()

        let syncCalls = await state.syncCalls()
        XCTAssertEqual(syncCalls, 1)

        let unlocked = await provider.isUnlocked(
            moduleID: "com.forsetti.module.example-ui",
            productID: "com.forsetti.iap.example-ui"
        )
        XCTAssertTrue(unlocked)
    }
}

actor TestStoreKitState {
    private var productIDs: Set<String>
    private var syncCallCount = 0

    init(productIDs: Set<String>) {
        self.productIDs = productIDs
    }

    func currentProductIDs() -> Set<String> {
        productIDs
    }

    func setProductIDs(_ productIDs: Set<String>) {
        self.productIDs = productIDs
    }

    func recordSyncCall() {
        syncCallCount += 1
    }

    func syncCalls() -> Int {
        syncCallCount
    }
}
#endif
