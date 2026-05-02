import XCTest
@testable import ForsettiCore

final class EntitlementProviderTests: XCTestCase {
    func testStaticProviderTreatsModulesWithoutProductIDAsUnlocked() async {
        let provider = StaticEntitlementProvider()

        let unlocked = await provider.isUnlocked(
            moduleID: "com.forsetti.module.free",
            productID: nil
        )

        XCTAssertTrue(unlocked)
    }

    func testStaticProviderUsesUnlockedProductIDsForPaidModules() async {
        let provider = StaticEntitlementProvider(
            unlockedProductIDs: ["com.forsetti.iap.example-ui"]
        )

        let unlocked = await provider.isUnlocked(
            moduleID: "com.forsetti.module.example-ui",
            productID: "com.forsetti.iap.example-ui"
        )

        XCTAssertTrue(unlocked)
    }

    func testStaticProviderRejectsUnknownProductID() async {
        let provider = StaticEntitlementProvider(unlockedProductIDs: [])

        let unlocked = await provider.isUnlocked(
            moduleID: "com.forsetti.module.example-ui",
            productID: "com.forsetti.iap.example-ui"
        )

        XCTAssertFalse(unlocked)
    }
}
