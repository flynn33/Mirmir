import SwiftUI
import XCTest
@testable import Mirmir

@MainActor
final class MirmirViewRegistryTests: XCTestCase {
    func test_registryResolvesRegisteredViewAndSortsIDs() throws {
        let registry = MirmirViewRegistry()
        try registry.register(viewID: "z-view") { Text("Z") }
        try registry.register(viewID: MirmirUIConstants.primaryViewID) { Text("Workspace") }

        XCTAssertEqual(
            registry.registeredViewIDs,
            [MirmirUIConstants.primaryViewID, "z-view"]
        )
        XCTAssertNotNil(registry.resolve(viewID: MirmirUIConstants.primaryViewID))
        XCTAssertNil(registry.resolve(viewID: "missing"))
    }

    func test_registryRejectsEmptyAndDuplicateViewIDs() throws {
        let registry = MirmirViewRegistry()
        XCTAssertThrowsError(try registry.register(viewID: " ") { EmptyView() }) { error in
            XCTAssertEqual(error as? MirmirViewRegistryError, .invalidViewID)
        }

        try registry.register(viewID: MirmirUIConstants.primaryViewID) { EmptyView() }
        XCTAssertThrowsError(
            try registry.register(viewID: MirmirUIConstants.primaryViewID) { EmptyView() }
        ) { error in
            XCTAssertEqual(
                error as? MirmirViewRegistryError,
                .duplicateViewID(MirmirUIConstants.primaryViewID)
            )
        }
    }
}
