import XCTest
@testable import ForsettiCore

final class UISurfaceManagerTests: XCTestCase {
    @MainActor
    func testApplyRemoveAndClearRebuildsSurfaceState() {
        let manager = UISurfaceManager()

        manager.apply(
            moduleID: "com.forsetti.module.a",
            contributions: UIContributions(
                themeMask: ThemeMask(themeID: "theme.a", tokens: [ThemeToken(key: "accentColor", value: "#111111")]),
                toolbarItems: [
                    ToolbarItemDescriptor(
                        itemID: "toolbar.a",
                        title: "A",
                        action: .publishEvent(type: "a", payload: nil)
                    )
                ],
                viewInjections: [
                    ViewInjectionDescriptor(
                        injectionID: "injection.a",
                        slot: "home.banner",
                        viewID: "view.a",
                        priority: 10
                    )
                ],
                overlaySchema: OverlaySchema(schemaID: "schema.a", pointers: [], routes: [])
            )
        )

        manager.apply(
            moduleID: "com.forsetti.module.b",
            contributions: UIContributions(
                themeMask: ThemeMask(themeID: "theme.b", tokens: [ThemeToken(key: "accentColor", value: "#222222")]),
                toolbarItems: [
                    ToolbarItemDescriptor(
                        itemID: "toolbar.b",
                        title: "B",
                        action: .publishEvent(type: "b", payload: nil)
                    )
                ],
                viewInjections: [
                    ViewInjectionDescriptor(
                        injectionID: "injection.b",
                        slot: "home.banner",
                        viewID: "view.b",
                        priority: 99
                    )
                ],
                overlaySchema: OverlaySchema(schemaID: "schema.b", pointers: [], routes: [])
            )
        )

        XCTAssertEqual(manager.themeMask?.themeID, "theme.b")
        XCTAssertEqual(manager.overlaySchema?.schemaID, "forsetti.overlay.composite")
        XCTAssertEqual(manager.toolbarItems.map(\.itemID), ["toolbar.a", "toolbar.b"])
        XCTAssertEqual(manager.viewInjectionsBySlot["home.banner"]?.map(\.viewID), ["view.b", "view.a"])

        manager.remove(moduleID: "com.forsetti.module.b")

        XCTAssertEqual(manager.themeMask?.themeID, "theme.a")
        XCTAssertEqual(manager.overlaySchema?.schemaID, "forsetti.overlay.composite")
        XCTAssertEqual(manager.toolbarItems.map(\.itemID), ["toolbar.a"])
        XCTAssertEqual(manager.viewInjectionsBySlot["home.banner"]?.map(\.viewID), ["view.a"])

        manager.clear()

        XCTAssertNil(manager.themeMask)
        XCTAssertNil(manager.overlaySchema)
        XCTAssertTrue(manager.toolbarItems.isEmpty)
        XCTAssertTrue(manager.viewInjectionsBySlot.isEmpty)
    }
}
