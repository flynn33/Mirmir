import XCTest
@testable import ForsettiPlatform
@testable import ForsettiCore

final class EntitlementProviderFactoryTests: XCTestCase {
    func testMakeDebugWithNoParametersUnlocksAll() async {
        let provider = ForsettiEntitlementProviderFactory.makeDebug()

        let freeModule = await provider.isUnlocked(moduleID: "com.test.free", productID: nil)
        XCTAssertTrue(freeModule)

        let paidModule = await provider.isUnlocked(
            moduleID: "com.test.paid",
            productID: "com.test.iap.paid"
        )
        XCTAssertTrue(paidModule)

        let unknownModule = await provider.isUnlocked(
            moduleID: "com.test.unknown",
            productID: "com.test.iap.unknown"
        )
        XCTAssertTrue(unknownModule)
    }

    func testMakeDebugWithProductIDsUnlocksSelectively() async {
        let provider = ForsettiEntitlementProviderFactory.makeDebug(
            unlockedProductIDs: ["com.test.iap.premium"]
        )

        let unlocked = await provider.isUnlocked(
            moduleID: "com.test.premium",
            productID: "com.test.iap.premium"
        )
        XCTAssertTrue(unlocked)

        let locked = await provider.isUnlocked(
            moduleID: "com.test.other",
            productID: "com.test.iap.other"
        )
        XCTAssertFalse(locked)

        let freeModule = await provider.isUnlocked(moduleID: "com.test.free", productID: nil)
        XCTAssertTrue(freeModule)
    }

    func testMakeDebugWithModuleIDsUnlocksSelectively() async {
        let provider = ForsettiEntitlementProviderFactory.makeDebug(
            unlockedModuleIDs: ["com.test.module.special"]
        )

        let unlocked = await provider.isUnlocked(
            moduleID: "com.test.module.special",
            productID: "com.test.iap.special"
        )
        XCTAssertTrue(unlocked)

        let locked = await provider.isUnlocked(
            moduleID: "com.test.module.other",
            productID: "com.test.iap.other"
        )
        XCTAssertFalse(locked)
    }
}
