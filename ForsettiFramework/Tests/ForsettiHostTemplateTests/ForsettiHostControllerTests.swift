import XCTest
@testable import ForsettiCore
@testable import ForsettiModulesExample
@testable import ForsettiHostTemplate

final class ForsettiHostControllerTests: XCTestCase {
    @MainActor
    func testBootLoadsServiceAndUIModuleLists() async {
        let controller = makeController(
            unlockedModules: [
                "com.forsetti.module.example-service"
            ],
            unlockedProducts: [
                "com.forsetti.iap.example-ui"
            ]
        )

        await controller.boot(restoreActivationState: false)

        XCTAssertEqual(controller.serviceModules.count, 1)
        XCTAssertEqual(controller.uiModules.count, 1)
        XCTAssertTrue(controller.enabledServiceModuleIDs.isEmpty)
        XCTAssertTrue(controller.enabledUIModuleIDs.isEmpty)
        XCTAssertTrue(controller.errorMessage == nil)
    }

    @MainActor
    func testBootCanExplicitlyActivateAllEligibleModulesForDevelopment() async {
        let controller = makeController(
            unlockedModules: [
                "com.forsetti.module.example-service"
            ],
            unlockedProducts: [
                "com.forsetti.iap.example-ui"
            ]
        )

        await controller.boot(
            restoreActivationState: false,
            activationStrategy: .activateAllEligibleForDevelopment
        )

        XCTAssertTrue(controller.enabledServiceModuleIDs.contains("com.forsetti.module.example-service"))
        XCTAssertTrue(controller.enabledUIModuleIDs.contains("com.forsetti.module.example-ui"))
        XCTAssertEqual(controller.activeUIModuleID, "com.forsetti.module.example-ui")

        controller.shutdown()
    }

    @MainActor
    func testBootCanActivateExplicitModuleIDs() async {
        let controller = makeController(
            unlockedModules: [
                "com.forsetti.module.example-service"
            ],
            unlockedProducts: [
                "com.forsetti.iap.example-ui"
            ]
        )

        await controller.boot(
            restoreActivationState: false,
            activationStrategy: .activate(moduleIDs: ["com.forsetti.module.example-ui"])
        )

        XCTAssertFalse(controller.enabledServiceModuleIDs.contains("com.forsetti.module.example-service"))
        XCTAssertEqual(controller.activeUIModuleID, "com.forsetti.module.example-ui")
        XCTAssertEqual(controller.enabledUIModuleIDs, ["com.forsetti.module.example-ui"])

        controller.shutdown()
    }

    @MainActor
    func testServiceToggleAndUIModuleSelection() async {
        let controller = makeController(
            unlockedModules: [
                "com.forsetti.module.example-service"
            ],
            unlockedProducts: [
                "com.forsetti.iap.example-ui"
            ]
        )

        await controller.boot(restoreActivationState: false)
        await controller.setServiceModuleEnabled(moduleID: "com.forsetti.module.example-service", isEnabled: true)
        await controller.setUIModuleEnabled(moduleID: "com.forsetti.module.example-ui", isEnabled: true)

        XCTAssertTrue(controller.enabledServiceModuleIDs.contains("com.forsetti.module.example-service"))
        XCTAssertTrue(controller.enabledUIModuleIDs.contains("com.forsetti.module.example-ui"))

        await controller.selectUIModule(moduleID: "com.forsetti.module.example-ui")
        XCTAssertEqual(controller.activeUIModuleID, "com.forsetti.module.example-ui")
        XCTAssertEqual(controller.selectedModuleID, "com.forsetti.module.example-ui")

        await controller.selectUIModule(moduleID: nil)
        XCTAssertNil(controller.selectedModuleID)
        XCTAssertNil(controller.activeUIModuleID)
        XCTAssertFalse(controller.enabledUIModuleIDs.contains("com.forsetti.module.example-ui"))

        controller.shutdown()
    }

    @MainActor
    func testLockedModuleCannotActivate() async {
        let controller = makeController(
            unlockedModules: [
                "com.forsetti.module.example-service"
            ]
        )

        await controller.boot(restoreActivationState: false)
        await controller.selectUIModule(moduleID: "com.forsetti.module.example-ui")

        XCTAssertNil(controller.activeUIModuleID)
        XCTAssertFalse(controller.enabledUIModuleIDs.contains("com.forsetti.module.example-ui"))
        XCTAssertNotNil(controller.errorMessage)

        let uiModule = controller.uiModules.first { $0.moduleID == "com.forsetti.module.example-ui" }
        XCTAssertNotNil(uiModule)
        XCTAssertEqual(uiModule?.availability, .locked(productID: "com.forsetti.iap.example-ui"))

        controller.shutdown()
    }

    @MainActor
    func testProductionTemplateDoesNotRenderModuleBeforeActivationSucceeds() throws {
        let templateURL = packageRootURL
            .appendingPathComponent("XcodeTemplates")
            .appendingPathComponent("Project Templates")
            .appendingPathComponent("Forsetti")
            .appendingPathComponent("Forsetti App.xctemplate")
            .appendingPathComponent("ContentView-Forsetti.swift")
        let template = try String(contentsOf: templateURL, encoding: .utf8)

        XCTAssertTrue(template.contains("___PACKAGENAME:identifier___ProductionRootView"))
        XCTAssertTrue(template.contains("case .ready:"))
        XCTAssertTrue(template.contains("___PACKAGENAME:identifier___AppModuleView()"))
        let directProductionRender = [
            "case .production:",
            "                ___PACKAGENAME:identifier___AppModuleView()"
        ].joined(separator: "\n")
        XCTAssertFalse(template.contains(directProductionRender))
    }

    @MainActor
    func testRestorePurchasesUnlocksUIModule() async {
        let registry = ModuleRegistry()
        ExampleModuleRegistry.registerAll(into: registry)

        let entitlements = StaticEntitlementProvider(
            unlockedModuleIDs: ["com.forsetti.module.example-service"],
            unlockedProductIDs: []
        )
        let runtime = ForsettiRuntime(
            platform: .macOS,
            services: ForsettiServiceContainer(),
            entitlementProvider: entitlements,
            activationStore: InMemoryActivationStore(),
            moduleRegistry: registry
        )
        let controller = ForsettiHostController(
            runtime: runtime,
            entitlementProvider: entitlements,
            manifestsBundle: ExampleModuleResources.bundle
        )

        await controller.boot(restoreActivationState: false)
        await controller.selectUIModule(moduleID: "com.forsetti.module.example-ui")
        XCTAssertFalse(controller.enabledUIModuleIDs.contains("com.forsetti.module.example-ui"))

        entitlements.setUnlockedProducts(["com.forsetti.iap.example-ui"])
        await controller.restorePurchases()

        await controller.selectUIModule(moduleID: "com.forsetti.module.example-ui")
        XCTAssertEqual(controller.activeUIModuleID, "com.forsetti.module.example-ui")
        XCTAssertTrue(controller.enabledUIModuleIDs.contains("com.forsetti.module.example-ui"))
        XCTAssertNotNil(controller.runtime.moduleManager.manifestsByID["com.forsetti.module.example-ui"])

        controller.shutdown()
    }

    @MainActor
    func testToolbarRouteActionUsesHostOverlayRouterResolution() async {
        let registry = ModuleRegistry()
        ExampleModuleRegistry.registerAll(into: registry)

        let controller = ForsettiHostTemplateBootstrap.makeController(
            manifestsBundle: ExampleModuleResources.bundle,
            moduleRegistry: registry,
            entitlementProvider: StaticEntitlementProvider(
                unlockedModuleIDs: ["com.forsetti.module.example-service"],
                unlockedProductIDs: ["com.forsetti.iap.example-ui"]
            ),
            activationStore: InMemoryActivationStore()
        )

        await controller.boot(restoreActivationState: false)
        await controller.selectUIModule(moduleID: "com.forsetti.module.example-ui")

        controller.handleToolbarAction(.openOverlay(routeID: "example-overlay"))

        XCTAssertEqual(
            controller.lastToolbarActionDescription,
            "Route 'example-overlay' resolved to overlay slot 'overlay.main'."
        )

        controller.shutdown()
    }

    @MainActor
    private func makeController(
        unlockedModules: Set<String>,
        unlockedProducts: Set<String> = []
    ) -> ForsettiHostController {
        let registry = ModuleRegistry()
        ExampleModuleRegistry.registerAll(into: registry)

        let entitlements = StaticEntitlementProvider(
            unlockedModuleIDs: unlockedModules,
            unlockedProductIDs: unlockedProducts
        )
        let runtime = ForsettiRuntime(
            platform: .macOS,
            services: ForsettiServiceContainer(),
            entitlementProvider: entitlements,
            activationStore: InMemoryActivationStore(),
            moduleRegistry: registry
        )

        return ForsettiHostController(
            runtime: runtime,
            entitlementProvider: entitlements,
            manifestsBundle: ExampleModuleResources.bundle
        )
    }

    private var packageRootURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private final class InMemoryActivationStore: ActivationStore, @unchecked Sendable {
    private var state = ActivationState()

    func loadState() -> ActivationState {
        state
    }

    func saveState(_ state: ActivationState) {
        self.state = state
    }
}
