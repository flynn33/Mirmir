import Foundation
import XCTest
@testable import ForsettiCore

final class ModuleIdentityValidationTests: XCTestCase {
    @MainActor
    func testActivationRejectsFactoryReturningWrongModuleIDBeforeStart() async throws {
        MismatchServiceModule.startInvocationCount = 0

        let testBundle = try RuntimeTestBundle()
        let mismatchManifest = ModuleManifest(
            schemaVersion: ModuleManifest.supportedSchemaVersion,
            moduleID: "com.forsetti.module.mismatch-ui",
            displayName: "Mismatch UI",
            moduleVersion: SemVer(major: 1, minor: 0, patch: 0),
            moduleType: .ui,
            supportedPlatforms: [.iOS, .macOS],
            minForsettiVersion: ForsettiVersion.current,
            maxForsettiVersion: nil,
            capabilitiesRequested: [],
            iapProductID: nil,
            entryPoint: "MismatchServiceModule"
        )
        try testBundle.writeManifest(mismatchManifest, fileName: "Mismatch.json")

        let registry = ModuleRegistry()
        registry.register(entryPoint: "MismatchServiceModule") { MismatchServiceModule() }
        let manager = makeManager(registry: registry)

        _ = try manager.discoverModules(bundle: testBundle.bundle, subdirectory: "ForsettiManifests")

        do {
            try await manager.activateModule(moduleID: mismatchManifest.moduleID)
            XCTFail("Expected moduleIdentityMismatch error.")
        } catch let error as ModuleManagerError {
            guard case let .moduleIdentityMismatch(moduleID, field, expected, actual) = error else {
                return XCTFail("Expected moduleIdentityMismatch error, received \(error).")
            }
            XCTAssertEqual(moduleID, mismatchManifest.moduleID)
            XCTAssertEqual(field, "descriptor.moduleID")
            XCTAssertEqual(expected, mismatchManifest.moduleID)
            XCTAssertEqual(actual, "com.forsetti.module.mismatch-service")
        }

        XCTAssertEqual(MismatchServiceModule.startInvocationCount, 0)
    }

    @MainActor
    func testActivationRejectsFactoryReturningWrongModuleTypeBeforeStart() async throws {
        WrongTypeUIModule.startInvocationCount = 0

        let testBundle = try RuntimeTestBundle()
        let discoveredManifest = WrongTypeUIModule.moduleManifest(
            moduleType: .ui,
            entryPoint: WrongTypeUIModule.Constants.entryPoint
        )
        try testBundle.writeManifest(discoveredManifest, fileName: "WrongTypeUI.json")

        let registry = ModuleRegistry()
        registry.register(entryPoint: WrongTypeUIModule.Constants.entryPoint) {
            WrongTypeUIModule()
        }
        let manager = makeManager(registry: registry)

        _ = try manager.discoverModules(bundle: testBundle.bundle, subdirectory: "ForsettiManifests")

        do {
            try await manager.activateModule(moduleID: WrongTypeUIModule.Constants.moduleID)
            XCTFail("Expected moduleIdentityMismatch error.")
        } catch let error as ModuleManagerError {
            guard case let .moduleIdentityMismatch(_, field, expected, actual) = error else {
                return XCTFail("Expected moduleIdentityMismatch error, received \(error).")
            }
            XCTAssertEqual(field, "descriptor.moduleType")
            XCTAssertEqual(expected, ModuleType.ui.rawValue)
            XCTAssertEqual(actual, ModuleType.service.rawValue)
        }

        XCTAssertEqual(WrongTypeUIModule.startInvocationCount, 0)
    }

    @MainActor
    func testActivationRejectsFactoryReturningWrongManifestEntryPointBeforeStart() async throws {
        WrongEntryPointUIModule.startInvocationCount = 0

        let testBundle = try RuntimeTestBundle()
        let discoveredManifest = WrongEntryPointUIModule.moduleManifest(
            entryPoint: WrongEntryPointUIModule.Constants.expectedEntryPoint
        )
        try testBundle.writeManifest(discoveredManifest, fileName: "WrongEntryPointUI.json")

        let registry = ModuleRegistry()
        registry.register(entryPoint: WrongEntryPointUIModule.Constants.expectedEntryPoint) {
            WrongEntryPointUIModule()
        }
        let manager = makeManager(registry: registry)

        _ = try manager.discoverModules(bundle: testBundle.bundle, subdirectory: "ForsettiManifests")

        do {
            try await manager.activateModule(moduleID: WrongEntryPointUIModule.Constants.moduleID)
            XCTFail("Expected moduleIdentityMismatch error.")
        } catch let error as ModuleManagerError {
            guard case let .moduleIdentityMismatch(_, field, expected, actual) = error else {
                return XCTFail("Expected moduleIdentityMismatch error, received \(error).")
            }
            XCTAssertEqual(field, "manifest.entryPoint")
            XCTAssertEqual(expected, WrongEntryPointUIModule.Constants.expectedEntryPoint)
            XCTAssertEqual(actual, WrongEntryPointUIModule.Constants.actualEntryPoint)
        }

        XCTAssertEqual(WrongEntryPointUIModule.startInvocationCount, 0)
    }

    @MainActor
    private func makeManager(registry: ModuleRegistry) -> ModuleManager {
        ModuleManager(
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
    }
}

private final class MismatchServiceModule: ForsettiModule {
    static var startInvocationCount = 0

    let descriptor = ModuleDescriptor(
        moduleID: "com.forsetti.module.mismatch-service",
        displayName: "Mismatch Service",
        moduleVersion: SemVer(major: 1, minor: 0, patch: 0),
        moduleType: .service
    )

    let manifest = ModuleManifest(
        schemaVersion: ModuleManifest.supportedSchemaVersion,
        moduleID: "com.forsetti.module.mismatch-service",
        displayName: "Mismatch Service",
        moduleVersion: SemVer(major: 1, minor: 0, patch: 0),
        moduleType: .service,
        supportedPlatforms: [.iOS, .macOS],
        minForsettiVersion: ForsettiVersion.current,
        maxForsettiVersion: nil,
        capabilitiesRequested: [],
        iapProductID: nil,
        entryPoint: "MismatchServiceModule"
    )

    func start(context _: ForsettiContext) throws {
        Self.startInvocationCount += 1
    }

    func stop(context _: ForsettiContext) {}
}

private final class WrongTypeUIModule: ForsettiUIModule {
    enum Constants {
        static let moduleID = "com.forsetti.module.wrong-type-ui"
        static let entryPoint = "WrongTypeUIModule"
    }

    static var startInvocationCount = 0

    static func moduleManifest(moduleType: ModuleType, entryPoint: String) -> ModuleManifest {
        ModuleManifest(
            schemaVersion: ModuleManifest.supportedSchemaVersion,
            moduleID: Constants.moduleID,
            displayName: "Wrong Type UI",
            moduleVersion: SemVer(major: 1, minor: 0, patch: 0),
            moduleType: moduleType,
            supportedPlatforms: [.iOS, .macOS],
            minForsettiVersion: ForsettiVersion.current,
            maxForsettiVersion: nil,
            capabilitiesRequested: [],
            iapProductID: nil,
            entryPoint: entryPoint
        )
    }

    let descriptor = ModuleDescriptor(
        moduleID: Constants.moduleID,
        displayName: "Wrong Type UI",
        moduleVersion: SemVer(major: 1, minor: 0, patch: 0),
        moduleType: .service
    )

    let manifest = WrongTypeUIModule.moduleManifest(moduleType: .service, entryPoint: Constants.entryPoint)
    let uiContributions = UIContributions.empty

    func start(context _: ForsettiContext) throws {
        Self.startInvocationCount += 1
    }

    func stop(context _: ForsettiContext) {}
}

private final class WrongEntryPointUIModule: ForsettiUIModule {
    enum Constants {
        static let moduleID = "com.forsetti.module.wrong-entry-ui"
        static let expectedEntryPoint = "ExpectedWrongEntryPointUIModule"
        static let actualEntryPoint = "ActualWrongEntryPointUIModule"
    }

    static var startInvocationCount = 0

    static func moduleManifest(entryPoint: String) -> ModuleManifest {
        ModuleManifest(
            schemaVersion: ModuleManifest.supportedSchemaVersion,
            moduleID: Constants.moduleID,
            displayName: "Wrong Entry UI",
            moduleVersion: SemVer(major: 1, minor: 0, patch: 0),
            moduleType: .ui,
            supportedPlatforms: [.iOS, .macOS],
            minForsettiVersion: ForsettiVersion.current,
            maxForsettiVersion: nil,
            capabilitiesRequested: [],
            iapProductID: nil,
            entryPoint: entryPoint
        )
    }

    let descriptor = ModuleDescriptor(
        moduleID: Constants.moduleID,
        displayName: "Wrong Entry UI",
        moduleVersion: SemVer(major: 1, minor: 0, patch: 0),
        moduleType: .ui
    )

    let manifest = WrongEntryPointUIModule.moduleManifest(entryPoint: Constants.actualEntryPoint)
    let uiContributions = UIContributions.empty

    func start(context _: ForsettiContext) throws {
        Self.startInvocationCount += 1
    }

    func stop(context _: ForsettiContext) {}
}
