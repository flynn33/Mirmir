import XCTest
@testable import ForsettiCore
@testable import ForsettiModulesExample

final class ForsettiCoreBootstrapTests: XCTestCase {
    func testSemVerComparison() throws {
        let stable = SemVer(major: 1, minor: 2, patch: 3)
        let prerelease = SemVer(major: 1, minor: 2, patch: 3, prerelease: "beta.1")
        let nextPatch = SemVer(major: 1, minor: 2, patch: 4)

        XCTAssertTrue(prerelease < stable)
        XCTAssertTrue(stable < nextPatch)
    }

    func testManifestLoaderLoadsExampleManifests() throws {
        let loader = ManifestLoader()
        let manifests = try loader.loadManifests(bundle: ExampleModuleResources.bundle, subdirectory: "ForsettiManifests")

        XCTAssertEqual(manifests.count, 2)
        XCTAssertNotNil(manifests["com.forsetti.module.example-service"])
        XCTAssertNotNil(manifests["com.forsetti.module.example-ui"])
    }

    @MainActor
    func testModuleManagerActivatesServiceAndUI() async throws {
        let manifestLoader = ManifestLoader()
        let registry = ModuleRegistry()
        ExampleModuleRegistry.registerAll(into: registry)

        let checker = CompatibilityChecker(
            runtimePlatform: .macOS,
            forsettiVersion: ForsettiVersion.current,
            capabilityPolicy: AllowAllCapabilityPolicy()
        )

        let activationStore = InMemoryActivationStore()
        let entitlementProvider = StaticEntitlementProvider(
            unlockedModuleIDs: [
                "com.forsetti.module.example-service"
            ],
            unlockedProductIDs: [
                "com.forsetti.iap.example-ui"
            ]
        )

        let manager = ModuleManager(
            manifestLoader: manifestLoader,
            moduleRegistry: registry,
            compatibilityChecker: checker,
            activationStore: activationStore,
            entitlementProvider: entitlementProvider,
            uiSurfaceManager: UISurfaceManager(),
            context: ForsettiContext(
                eventBus: InMemoryEventBus(),
                services: ForsettiServiceContainer(),
                logger: ConsoleForsettiLogger(),
                router: NoopOverlayRouter()
            )
        )

        _ = try manager.discoverModules(bundle: ExampleModuleResources.bundle, subdirectory: "ForsettiManifests")
        try await manager.activateModule(moduleID: "com.forsetti.module.example-service")
        try await manager.activateModule(moduleID: "com.forsetti.module.example-ui")

        XCTAssertTrue(manager.enabledServiceModuleIDs.contains("com.forsetti.module.example-service"))
        XCTAssertEqual(manager.activeUIModuleID, "com.forsetti.module.example-ui")

        try manager.deactivateModule(moduleID: "com.forsetti.module.example-service")
        XCTAssertFalse(manager.enabledServiceModuleIDs.contains("com.forsetti.module.example-service"))
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
