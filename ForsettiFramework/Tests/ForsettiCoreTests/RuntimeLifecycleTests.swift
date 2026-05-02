import Foundation
import XCTest
@testable import ForsettiCore
@testable import ForsettiModulesExample

final class RuntimeLifecycleTests: XCTestCase {
    @MainActor
    func testRestorePersistedActivationActuallyStartsAndLoadsServiceModules() async throws {
        CountingServiceModule.reset()

        let moduleID = CountingServiceModule.Constants.moduleID
        let activationStore = SharedInMemoryActivationStore(
            state: ActivationState(enabledServiceModuleIDs: [moduleID])
        )
        let testBundle = try RuntimeTestBundle()
        try testBundle.writeManifest(CountingServiceModule.moduleManifest, fileName: "CountingService.json")

        let registry = ModuleRegistry()
        registry.register(entryPoint: CountingServiceModule.Constants.entryPoint) {
            CountingServiceModule()
        }

        let runtime = ForsettiRuntime(
            platform: .macOS,
            services: ForsettiServiceContainer(),
            entitlementProvider: StaticEntitlementProvider(unlockedModuleIDs: [moduleID]),
            activationStore: activationStore,
            moduleRegistry: registry
        )

        _ = try await runtime.boot(bundle: testBundle.bundle, restoreActivationState: true)

        XCTAssertEqual(CountingServiceModule.startInvocationCount, 1)
        XCTAssertTrue(runtime.moduleManager.enabledServiceModuleIDs.contains(moduleID))
        XCTAssertNotNil(runtime.moduleManager.loadedModules[moduleID])
        XCTAssertTrue(activationStore.loadState().enabledServiceModuleIDs.contains(moduleID))
    }

    @MainActor
    func testRestorePersistedActivationActuallyStartsLoadsAndReappliesUIModuleContributions() async throws {
        CountingUIModule.reset()

        let moduleID = CountingUIModule.Constants.moduleID
        let activationStore = SharedInMemoryActivationStore(
            state: ActivationState(enabledUIModuleIDs: [moduleID], selectedUIModuleID: moduleID)
        )
        let testBundle = try RuntimeTestBundle()
        try testBundle.writeManifest(CountingUIModule.moduleManifest, fileName: "CountingUI.json")

        let registry = ModuleRegistry()
        registry.register(entryPoint: CountingUIModule.Constants.entryPoint) {
            CountingUIModule()
        }

        let uiSurfaceManager = UISurfaceManager()
        let runtime = ForsettiRuntime(
            platform: .macOS,
            services: ForsettiServiceContainer(),
            entitlementProvider: StaticEntitlementProvider(unlockedModuleIDs: [moduleID]),
            activationStore: activationStore,
            moduleRegistry: registry,
            uiSurfaceManager: uiSurfaceManager
        )

        _ = try await runtime.boot(bundle: testBundle.bundle, restoreActivationState: true)

        XCTAssertEqual(CountingUIModule.startInvocationCount, 1)
        XCTAssertEqual(runtime.moduleManager.activeUIModuleID, moduleID)
        XCTAssertEqual(runtime.moduleManager.enabledUIModuleIDs, [moduleID])
        XCTAssertNotNil(runtime.moduleManager.loadedModules[moduleID])
        XCTAssertEqual(uiSurfaceManager.toolbarItems.map(\.itemID), ["counting-ui.action"])
    }

    @MainActor
    func testFailedRestoreDoesNotLeaveFalseEnabledModuleID() async throws {
        let moduleID = CountingServiceModule.Constants.moduleID
        let activationStore = SharedInMemoryActivationStore(
            state: ActivationState(enabledServiceModuleIDs: [moduleID])
        )
        let testBundle = try RuntimeTestBundle()
        try testBundle.writeManifest(CountingServiceModule.moduleManifest, fileName: "CountingService.json")

        let runtime = ForsettiRuntime(
            platform: .macOS,
            services: ForsettiServiceContainer(),
            entitlementProvider: StaticEntitlementProvider(unlockedModuleIDs: [moduleID]),
            activationStore: activationStore,
            moduleRegistry: ModuleRegistry()
        )

        _ = try await runtime.boot(bundle: testBundle.bundle, restoreActivationState: true)

        XCTAssertFalse(runtime.moduleManager.enabledServiceModuleIDs.contains(moduleID))
        XCTAssertNil(runtime.moduleManager.loadedModules[moduleID])
        XCTAssertFalse(activationStore.loadState().enabledServiceModuleIDs.contains(moduleID))
    }

    @MainActor
    func testRuntimeShutdownDoesNotClearPersistedActivationState() async throws {
        let serviceModuleID = "com.forsetti.module.example-service"
        let uiModuleID = "com.forsetti.module.example-ui"
        let uiProductID = "com.forsetti.iap.example-ui"

        let activationStore = SharedInMemoryActivationStore()
        let entitlementProvider = StaticEntitlementProvider(
            unlockedModuleIDs: [serviceModuleID],
            unlockedProductIDs: [uiProductID]
        )

        let firstRegistry = ModuleRegistry()
        ExampleModuleRegistry.registerAll(into: firstRegistry)

        let firstRuntime = ForsettiRuntime(
            platform: .macOS,
            services: ForsettiServiceContainer(),
            entitlementProvider: entitlementProvider,
            activationStore: activationStore,
            moduleRegistry: firstRegistry
        )

        _ = try await firstRuntime.boot(
            bundle: ExampleModuleResources.bundle,
            restoreActivationState: false
        )
        try await firstRuntime.moduleManager.activateModule(moduleID: serviceModuleID)
        try await firstRuntime.moduleManager.activateModule(moduleID: uiModuleID)
        firstRuntime.shutdown()

        let storedStateAfterShutdown = activationStore.loadState()
        XCTAssertTrue(storedStateAfterShutdown.enabledServiceModuleIDs.contains(serviceModuleID))
        XCTAssertTrue(storedStateAfterShutdown.enabledUIModuleIDs.contains(uiModuleID))
        XCTAssertEqual(storedStateAfterShutdown.activeUIModuleID, uiModuleID)

        let secondRegistry = ModuleRegistry()
        ExampleModuleRegistry.registerAll(into: secondRegistry)

        let secondRuntime = ForsettiRuntime(
            platform: .macOS,
            services: ForsettiServiceContainer(),
            entitlementProvider: entitlementProvider,
            activationStore: activationStore,
            moduleRegistry: secondRegistry
        )

        _ = try await secondRuntime.boot(bundle: ExampleModuleResources.bundle, restoreActivationState: true)

        XCTAssertTrue(secondRuntime.moduleManager.enabledServiceModuleIDs.contains(serviceModuleID))
        XCTAssertEqual(secondRuntime.moduleManager.activeUIModuleID, uiModuleID)

        secondRuntime.shutdown()
    }

    @MainActor
    func testActivatingSecondUIModuleDeactivatesFirstAndKeepsOnlyActiveContributions() async throws {
        let moduleAID = "com.forsetti.module.ui.a"
        let moduleBID = "com.forsetti.module.ui.b"

        let testBundle = try RuntimeTestBundle()
        let manifestsDirectory = testBundle.bundleURL.appendingPathComponent("ForsettiManifests", isDirectory: true)
        try FileManager.default.createDirectory(at: manifestsDirectory, withIntermediateDirectories: true)

        let manifestA = ModuleManifest(
            schemaVersion: ModuleManifest.supportedSchemaVersion,
            moduleID: moduleAID,
            displayName: "UI A",
            moduleVersion: SemVer(major: 1, minor: 0, patch: 0),
            moduleType: .ui,
            supportedPlatforms: [.iOS, .macOS],
            minForsettiVersion: ForsettiVersion.current,
            maxForsettiVersion: nil,
            capabilitiesRequested: [.toolbarItems],
            iapProductID: nil,
            entryPoint: "TestUIModuleA"
        )

        let manifestB = ModuleManifest(
            schemaVersion: ModuleManifest.supportedSchemaVersion,
            moduleID: moduleBID,
            displayName: "UI B",
            moduleVersion: SemVer(major: 1, minor: 0, patch: 0),
            moduleType: .ui,
            supportedPlatforms: [.iOS, .macOS],
            minForsettiVersion: ForsettiVersion.current,
            maxForsettiVersion: nil,
            capabilitiesRequested: [.toolbarItems],
            iapProductID: nil,
            entryPoint: "TestUIModuleB"
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifestA).write(
            to: manifestsDirectory.appendingPathComponent("UIA.json"),
            options: .atomic
        )
        try encoder.encode(manifestB).write(
            to: manifestsDirectory.appendingPathComponent("UIB.json"),
            options: .atomic
        )

        let registry = ModuleRegistry()
        registry.register(entryPoint: "TestUIModuleA") { TestUIModuleA() }
        registry.register(entryPoint: "TestUIModuleB") { TestUIModuleB() }

        let manager = ModuleManager(
            manifestLoader: ManifestLoader(),
            moduleRegistry: registry,
            compatibilityChecker: CompatibilityChecker(
                runtimePlatform: .macOS,
                forsettiVersion: ForsettiVersion.current,
                capabilityPolicy: AllowAllCapabilityPolicy()
            ),
            activationStore: SharedInMemoryActivationStore(),
            entitlementProvider: StaticEntitlementProvider(),
            uiSurfaceManager: UISurfaceManager(),
            context: ForsettiContext(
                eventBus: InMemoryEventBus(),
                services: ForsettiServiceContainer(),
                logger: ConsoleForsettiLogger(),
                router: NoopOverlayRouter()
            )
        )

        _ = try manager.discoverModules(bundle: testBundle.bundle, subdirectory: "ForsettiManifests")

        TestUIModuleA.reset()
        TestUIModuleB.reset()

        try await manager.activateModule(moduleID: moduleAID)
        XCTAssertEqual(manager.enabledUIModuleIDs, [moduleAID])
        XCTAssertEqual(manager.activeUIModuleID, moduleAID)
        XCTAssertTrue(manager.isActive(moduleID: moduleAID))

        try await manager.activateModule(moduleID: moduleBID)

        XCTAssertEqual(manager.enabledUIModuleIDs, [moduleBID])
        XCTAssertFalse(manager.isActive(moduleID: moduleAID))
        XCTAssertTrue(manager.isActive(moduleID: moduleBID))
        XCTAssertEqual(manager.activeUIModuleID, moduleBID)
        XCTAssertEqual(TestUIModuleA.stopInvocationCount, 1)
        XCTAssertNil(manager.uiContributions(for: moduleAID))
        XCTAssertEqual(manager.uiContributions(for: moduleBID)?.toolbarItems.map(\.itemID), ["ui.b.action"])

        try manager.deactivateModule(moduleID: moduleBID)
        XCTAssertTrue(manager.enabledUIModuleIDs.isEmpty)
        XCTAssertNil(manager.activeUIModuleID)
    }

    @MainActor
    func testServiceModulesRemainConcurrentlyActive() async throws {
        let moduleAID = CountingServiceModule.Constants.moduleID
        let moduleBID = SecondCountingServiceModule.Constants.moduleID

        let testBundle = try RuntimeTestBundle()
        try testBundle.writeManifest(CountingServiceModule.moduleManifest, fileName: "CountingService.json")
        try testBundle.writeManifest(SecondCountingServiceModule.moduleManifest, fileName: "SecondCountingService.json")

        let registry = ModuleRegistry()
        registry.register(entryPoint: CountingServiceModule.Constants.entryPoint) {
            CountingServiceModule()
        }
        registry.register(entryPoint: SecondCountingServiceModule.Constants.entryPoint) {
            SecondCountingServiceModule()
        }

        let manager = ModuleManager(
            manifestLoader: ManifestLoader(),
            moduleRegistry: registry,
            compatibilityChecker: CompatibilityChecker(
                runtimePlatform: .macOS,
                forsettiVersion: ForsettiVersion.current,
                capabilityPolicy: AllowAllCapabilityPolicy()
            ),
            activationStore: SharedInMemoryActivationStore(),
            entitlementProvider: StaticEntitlementProvider(),
            uiSurfaceManager: UISurfaceManager(),
            context: ForsettiContext(
                eventBus: InMemoryEventBus(),
                services: ForsettiServiceContainer(),
                logger: ConsoleForsettiLogger(),
                router: NoopOverlayRouter()
            )
        )

        _ = try manager.discoverModules(bundle: testBundle.bundle, subdirectory: "ForsettiManifests")

        try await manager.activateModule(moduleID: moduleAID)
        try await manager.activateModule(moduleID: moduleBID)

        XCTAssertEqual(manager.enabledServiceModuleIDs, [moduleAID, moduleBID])
        XCTAssertTrue(manager.isActive(moduleID: moduleAID))
        XCTAssertTrue(manager.isActive(moduleID: moduleBID))
    }

}

final class SharedInMemoryActivationStore: ActivationStore, @unchecked Sendable {
    private var state: ActivationState

    init(state: ActivationState = ActivationState()) {
        self.state = state
    }

    func loadState() -> ActivationState {
        state
    }

    func saveState(_ state: ActivationState) {
        self.state = state
    }
}

private final class TestUIModuleA: ForsettiUIModule {
    static var stopInvocationCount = 0

    static func reset() {
        stopInvocationCount = 0
    }

    let descriptor = ModuleDescriptor(
        moduleID: "com.forsetti.module.ui.a",
        displayName: "UI A",
        moduleVersion: SemVer(major: 1, minor: 0, patch: 0),
        moduleType: .ui
    )

    let manifest = ModuleManifest(
        schemaVersion: ModuleManifest.supportedSchemaVersion,
        moduleID: "com.forsetti.module.ui.a",
        displayName: "UI A",
        moduleVersion: SemVer(major: 1, minor: 0, patch: 0),
        moduleType: .ui,
        supportedPlatforms: [.iOS, .macOS],
        minForsettiVersion: ForsettiVersion.current,
        maxForsettiVersion: nil,
        capabilitiesRequested: [.toolbarItems],
        iapProductID: nil,
        entryPoint: "TestUIModuleA"
    )

    let uiContributions = UIContributions(
        toolbarItems: [
            ToolbarItemDescriptor(
                itemID: "ui.a.action",
                title: "A Action",
                action: .publishEvent(type: "ui.a.action", payload: nil)
            )
        ]
    )

    func start(context _: ForsettiContext) throws {}
    func stop(context _: ForsettiContext) {
        Self.stopInvocationCount += 1
    }
}

private final class TestUIModuleB: ForsettiUIModule {
    static var stopInvocationCount = 0

    static func reset() {
        stopInvocationCount = 0
    }

    let descriptor = ModuleDescriptor(
        moduleID: "com.forsetti.module.ui.b",
        displayName: "UI B",
        moduleVersion: SemVer(major: 1, minor: 0, patch: 0),
        moduleType: .ui
    )

    let manifest = ModuleManifest(
        schemaVersion: ModuleManifest.supportedSchemaVersion,
        moduleID: "com.forsetti.module.ui.b",
        displayName: "UI B",
        moduleVersion: SemVer(major: 1, minor: 0, patch: 0),
        moduleType: .ui,
        supportedPlatforms: [.iOS, .macOS],
        minForsettiVersion: ForsettiVersion.current,
        maxForsettiVersion: nil,
        capabilitiesRequested: [.toolbarItems],
        iapProductID: nil,
        entryPoint: "TestUIModuleB"
    )

    let uiContributions = UIContributions(
        toolbarItems: [
            ToolbarItemDescriptor(
                itemID: "ui.b.action",
                title: "B Action",
                action: .publishEvent(type: "ui.b.action", payload: nil)
            )
        ]
    )

    func start(context _: ForsettiContext) throws {}
    func stop(context _: ForsettiContext) {
        Self.stopInvocationCount += 1
    }
}

private final class CountingServiceModule: ForsettiModule {
    enum Constants {
        static let moduleID = "com.forsetti.module.counting-service"
        static let entryPoint = "CountingServiceModule"
    }

    static var startInvocationCount = 0

    static func reset() {
        startInvocationCount = 0
    }

    static let moduleManifest = ModuleManifest(
        schemaVersion: ModuleManifest.supportedSchemaVersion,
        moduleID: Constants.moduleID,
        displayName: "Counting Service",
        moduleVersion: SemVer(major: 1, minor: 0, patch: 0),
        moduleType: .service,
        supportedPlatforms: [.iOS, .macOS],
        minForsettiVersion: ForsettiVersion.current,
        maxForsettiVersion: nil,
        capabilitiesRequested: [],
        iapProductID: nil,
        entryPoint: Constants.entryPoint
    )

    let descriptor = ModuleDescriptor(
        moduleID: Constants.moduleID,
        displayName: "Counting Service",
        moduleVersion: SemVer(major: 1, minor: 0, patch: 0),
        moduleType: .service
    )

    let manifest = CountingServiceModule.moduleManifest

    func start(context _: ForsettiContext) throws {
        Self.startInvocationCount += 1
    }

    func stop(context _: ForsettiContext) {}
}
private final class SecondCountingServiceModule: ForsettiModule {
    enum Constants {
        static let moduleID = "com.forsetti.module.second-counting-service"
        static let entryPoint = "SecondCountingServiceModule"
    }

    static let moduleManifest = ModuleManifest(
        schemaVersion: ModuleManifest.supportedSchemaVersion,
        moduleID: Constants.moduleID,
        displayName: "Second Counting Service",
        moduleVersion: SemVer(major: 1, minor: 0, patch: 0),
        moduleType: .service,
        supportedPlatforms: [.iOS, .macOS],
        minForsettiVersion: ForsettiVersion.current,
        maxForsettiVersion: nil,
        capabilitiesRequested: [],
        iapProductID: nil,
        entryPoint: Constants.entryPoint
    )

    let descriptor = ModuleDescriptor(
        moduleID: Constants.moduleID,
        displayName: "Second Counting Service",
        moduleVersion: SemVer(major: 1, minor: 0, patch: 0),
        moduleType: .service
    )

    let manifest = SecondCountingServiceModule.moduleManifest

    func start(context _: ForsettiContext) throws {}
    func stop(context _: ForsettiContext) {}
}

private final class CountingUIModule: ForsettiUIModule {
    enum Constants {
        static let moduleID = "com.forsetti.module.counting-ui"
        static let entryPoint = "CountingUIModule"
    }

    static var startInvocationCount = 0

    static func reset() {
        startInvocationCount = 0
    }

    static let moduleManifest = ModuleManifest(
        schemaVersion: ModuleManifest.supportedSchemaVersion,
        moduleID: Constants.moduleID,
        displayName: "Counting UI",
        moduleVersion: SemVer(major: 1, minor: 0, patch: 0),
        moduleType: .ui,
        supportedPlatforms: [.iOS, .macOS],
        minForsettiVersion: ForsettiVersion.current,
        maxForsettiVersion: nil,
        capabilitiesRequested: [.toolbarItems],
        iapProductID: nil,
        entryPoint: Constants.entryPoint
    )

    let descriptor = ModuleDescriptor(
        moduleID: Constants.moduleID,
        displayName: "Counting UI",
        moduleVersion: SemVer(major: 1, minor: 0, patch: 0),
        moduleType: .ui
    )

    let manifest = CountingUIModule.moduleManifest
    let uiContributions = UIContributions(
        toolbarItems: [
            ToolbarItemDescriptor(
                itemID: "counting-ui.action",
                title: "Counting Action",
                action: .publishEvent(type: "counting.action", payload: nil)
            )
        ]
    )

    func start(context _: ForsettiContext) throws {
        Self.startInvocationCount += 1
    }

    func stop(context _: ForsettiContext) {}
