import Foundation
import XCTest
@testable import ForsettiCore

@MainActor
final class CapabilityEnforcementTests: XCTestCase {
    func testModuleWithoutStorageCapabilityCannotResolveStorageServiceAndLogsWarning() async throws {
        StorageProbeModule.reset()

        let logger = CapabilityRecordingLogger()
        let manager = try makeManager(
            manifests: [StorageProbeModule.moduleManifest(capabilities: [])],
            registrations: [
                StorageProbeModule.Constants.entryPoint: { StorageProbeModule() }
            ],
            services: makeServices(),
            logger: logger
        )

        try await manager.activateModule(moduleID: StorageProbeModule.Constants.moduleID)

        XCTAssertFalse(StorageProbeModule.didResolveStorage)
        XCTAssertTrue(logger.entries.contains { entry in
            entry.level == .warning &&
                entry.message.contains("Denied service resolution") &&
                entry.message.contains("StorageService")
        })
    }

    func testModuleWithStorageCapabilityCanResolveStorageService() async throws {
        StorageProbeModule.reset()

        let manager = try makeManager(
            manifests: [StorageProbeModule.moduleManifest(capabilities: [.storage])],
            registrations: [
                StorageProbeModule.Constants.entryPoint: { StorageProbeModule() }
            ],
            services: makeServices()
        )

        try await manager.activateModule(moduleID: StorageProbeModule.Constants.moduleID)

        XCTAssertTrue(StorageProbeModule.didResolveStorage)
    }

    func testModuleWithoutSecureStorageCapabilityCannotResolveSecureStorageService() async throws {
        SecureStorageProbeModule.reset()

        let manager = try makeManager(
            manifests: [SecureStorageProbeModule.moduleManifest(capabilities: [])],
            registrations: [
                SecureStorageProbeModule.Constants.entryPoint: { SecureStorageProbeModule() }
            ],
            services: makeServices()
        )

        try await manager.activateModule(moduleID: SecureStorageProbeModule.Constants.moduleID)

        XCTAssertFalse(SecureStorageProbeModule.didResolveSecureStorage)
    }

    func testToolbarContributionRequiresToolbarCapability() async throws {
        let manager = try makeManager(
            manifests: [ToolbarOnlyUIModule.moduleManifest(capabilities: [])],
            registrations: [
                ToolbarOnlyUIModule.Constants.entryPoint: { ToolbarOnlyUIModule() }
            ]
        )

        do {
            try await manager.activateModule(moduleID: ToolbarOnlyUIModule.Constants.moduleID)
            XCTFail("Expected missingCapability error.")
        } catch {
            guard case let ModuleManagerError.missingCapability(moduleID, capability, _) = error else {
                return XCTFail("Expected missingCapability, received \(error).")
            }
            XCTAssertEqual(moduleID, ToolbarOnlyUIModule.Constants.moduleID)
            XCTAssertEqual(capability, .toolbarItems)
        }
    }

    func testViewInjectionContributionRequiresViewInjectionCapability() async throws {
        let manager = try makeManager(
            manifests: [ViewInjectionOnlyUIModule.moduleManifest(capabilities: [])],
            registrations: [
                ViewInjectionOnlyUIModule.Constants.entryPoint: { ViewInjectionOnlyUIModule() }
            ]
        )

        do {
            try await manager.activateModule(moduleID: ViewInjectionOnlyUIModule.Constants.moduleID)
            XCTFail("Expected missingCapability error.")
        } catch {
            guard case let ModuleManagerError.missingCapability(_, capability, _) = error else {
                return XCTFail("Expected missingCapability, received \(error).")
            }
            XCTAssertEqual(capability, .viewInjection)
        }
    }

    func testOverlayContributionRequiresRoutingOverlayCapability() async throws {
        let manager = try makeManager(
            manifests: [OverlayOnlyUIModule.moduleManifest(capabilities: [])],
            registrations: [
                OverlayOnlyUIModule.Constants.entryPoint: { OverlayOnlyUIModule() }
            ]
        )

        do {
            try await manager.activateModule(moduleID: OverlayOnlyUIModule.Constants.moduleID)
            XCTFail("Expected missingCapability error.")
        } catch {
            guard case let ModuleManagerError.missingCapability(_, capability, _) = error else {
                return XCTFail("Expected missingCapability, received \(error).")
            }
            XCTAssertEqual(capability, .routingOverlay)
        }
    }

    func testScopedContextPreventsFrameworkEventSourceSpoofing() async throws {
        SourceSpoofingEventModule.reset()
        let eventBus = InMemoryEventBus()
        let expectation = expectation(description: "Published event received")
        let eventBox = CapabilityEventBox()

        let token = eventBus.subscribe(eventType: "capability.spoof.event") { event in
            eventBox.event = event
            expectation.fulfill()
        }
        defer { token.cancel() }

        let manager = try makeManager(
            manifests: [SourceSpoofingEventModule.moduleManifest],
            registrations: [
                SourceSpoofingEventModule.Constants.entryPoint: { SourceSpoofingEventModule() }
            ],
            eventBus: eventBus
        )

        try await manager.activateModule(moduleID: SourceSpoofingEventModule.Constants.moduleID)
        await fulfillment(of: [expectation], timeout: 1)

        XCTAssertEqual(eventBox.event?.sourceModuleID, SourceSpoofingEventModule.Constants.moduleID)
    }

    func testScopedContextRejectsModuleMessageSourceSpoofing() async throws {
        SourceSpoofingMessageModule.reset()

        let logger = CapabilityRecordingLogger()
        let manager = try makeManager(
            manifests: [SourceSpoofingMessageModule.moduleManifest],
            registrations: [
                SourceSpoofingMessageModule.Constants.entryPoint: { SourceSpoofingMessageModule() }
            ],
            logger: logger
        )

        try await manager.activateModule(moduleID: SourceSpoofingMessageModule.Constants.moduleID)

        XCTAssertNotNil(SourceSpoofingMessageModule.capturedError)
        XCTAssertTrue(logger.entries.contains { entry in
            entry.level == .error &&
                entry.message.contains("Blocked module source identity spoofing")
        })
    }

    private func makeManager(
        manifests: [ModuleManifest],
        registrations: [String: ModuleFactory],
        services: any ForsettiServiceProviding = ForsettiServiceContainer(),
        logger: any ForsettiLogger = CapabilityRecordingLogger(),
        eventBus: ForsettiEventBus = InMemoryEventBus()
    ) throws -> ModuleManager {
        let testBundle = try CapabilityTestBundle(manifests: manifests)
        let registry = ModuleRegistry()
        for (entryPoint, factory) in registrations {
            registry.register(entryPoint: entryPoint, factory: factory)
        }

        let manager = ModuleManager(
            manifestLoader: ManifestLoader(),
            moduleRegistry: registry,
            compatibilityChecker: CompatibilityChecker(
                runtimePlatform: .macOS,
                forsettiVersion: ForsettiVersion.current,
                capabilityPolicy: AllowAllCapabilityPolicy()
            ),
            activationStore: CapabilityActivationStore(),
            entitlementProvider: StaticEntitlementProvider(),
            uiSurfaceManager: UISurfaceManager(),
            context: ForsettiContext(
                eventBus: eventBus,
                services: services,
                logger: logger,
                router: NoopOverlayRouter()
            )
        )

        _ = try manager.discoverModules(bundle: testBundle.bundle, subdirectory: "ForsettiManifests")
        return manager
    }

    private func makeServices() -> ForsettiServiceContainer {
        let services = ForsettiServiceContainer()
        services.register(StorageService.self, service: CapabilityStorageService())
        services.register(SecureStorageService.self, service: CapabilitySecureStorageService())
        return services
    }
}

private final class StorageProbeModule: ForsettiModule {
    enum Constants {
        static let moduleID = "com.forsetti.tests.storage-probe"
        static let entryPoint = "StorageProbeModule"
    }

    static var didResolveStorage = false

    static func reset() {
        didResolveStorage = false
    }

    static func moduleManifest(capabilities: [Capability]) -> ModuleManifest {
        ModuleManifest(
            schemaVersion: ModuleManifest.supportedSchemaVersion,
            moduleID: Constants.moduleID,
            displayName: "Storage Probe",
            moduleVersion: SemVer(major: 1, minor: 0, patch: 0),
            moduleType: .service,
            supportedPlatforms: [.iOS, .macOS],
            minForsettiVersion: ForsettiVersion.current,
            capabilitiesRequested: capabilities,
            entryPoint: Constants.entryPoint
        )
    }

    let descriptor = ModuleDescriptor(
        moduleID: Constants.moduleID,
        displayName: "Storage Probe",
        moduleVersion: SemVer(major: 1, minor: 0, patch: 0),
        moduleType: .service
    )

    let manifest = StorageProbeModule.moduleManifest(capabilities: [])

    func start(context: ForsettiContext) throws {
        Self.didResolveStorage = context.services.resolve(StorageService.self) != nil
    }

    func stop(context _: ForsettiContext) {}
}

private final class SecureStorageProbeModule: ForsettiModule {
    enum Constants {
        static let moduleID = "com.forsetti.tests.secure-storage-probe"
        static let entryPoint = "SecureStorageProbeModule"
    }

    static var didResolveSecureStorage = false

    static func reset() {
        didResolveSecureStorage = false
    }

    static func moduleManifest(capabilities: [Capability]) -> ModuleManifest {
        ModuleManifest(
            schemaVersion: ModuleManifest.supportedSchemaVersion,
            moduleID: Constants.moduleID,
            displayName: "Secure Storage Probe",
            moduleVersion: SemVer(major: 1, minor: 0, patch: 0),
            moduleType: .service,
            supportedPlatforms: [.iOS, .macOS],
            minForsettiVersion: ForsettiVersion.current,
            capabilitiesRequested: capabilities,
            entryPoint: Constants.entryPoint
        )
    }

    let descriptor = ModuleDescriptor(
        moduleID: Constants.moduleID,
        displayName: "Secure Storage Probe",
        moduleVersion: SemVer(major: 1, minor: 0, patch: 0),
        moduleType: .service
    )

    let manifest = SecureStorageProbeModule.moduleManifest(capabilities: [])

    func start(context: ForsettiContext) throws {
        Self.didResolveSecureStorage = context.services.resolve(SecureStorageService.self) != nil
    }

    func stop(context _: ForsettiContext) {}
}

private final class ToolbarOnlyUIModule: ForsettiUIModule {
    enum Constants {
        static let moduleID = "com.forsetti.tests.toolbar-ui"
        static let entryPoint = "ToolbarOnlyUIModule"
    }

    static func moduleManifest(capabilities: [Capability]) -> ModuleManifest {
        uiManifest(
            moduleID: Constants.moduleID,
            displayName: "Toolbar UI",
            capabilities: capabilities,
            entryPoint: Constants.entryPoint
        )
    }

    let descriptor = uiDescriptor(moduleID: Constants.moduleID, displayName: "Toolbar UI")
    let manifest = ToolbarOnlyUIModule.moduleManifest(capabilities: [])
    let uiContributions = UIContributions(
        toolbarItems: [
            ToolbarItemDescriptor(
                itemID: "toolbar.action",
                title: "Toolbar Action",
                action: .publishEvent(type: "toolbar.action", payload: nil)
            )
        ]
    )

    func start(context _: ForsettiContext) throws {}
    func stop(context _: ForsettiContext) {}
}

private final class ViewInjectionOnlyUIModule: ForsettiUIModule {
    enum Constants {
        static let moduleID = "com.forsetti.tests.view-injection-ui"
        static let entryPoint = "ViewInjectionOnlyUIModule"
    }

    static func moduleManifest(capabilities: [Capability]) -> ModuleManifest {
        uiManifest(
            moduleID: Constants.moduleID,
            displayName: "View Injection UI",
            capabilities: capabilities,
            entryPoint: Constants.entryPoint
        )
    }

    let descriptor = uiDescriptor(moduleID: Constants.moduleID, displayName: "View Injection UI")
    let manifest = ViewInjectionOnlyUIModule.moduleManifest(capabilities: [])
    let uiContributions = UIContributions(
        viewInjections: [
            ViewInjectionDescriptor(
                injectionID: "injection",
                slot: "module.workspace",
                viewID: "view",
                priority: 1
            )
        ]
    )

    func start(context _: ForsettiContext) throws {}
    func stop(context _: ForsettiContext) {}
}

private final class OverlayOnlyUIModule: ForsettiUIModule {
    enum Constants {
        static let moduleID = "com.forsetti.tests.overlay-ui"
        static let entryPoint = "OverlayOnlyUIModule"
    }

    static func moduleManifest(capabilities: [Capability]) -> ModuleManifest {
        uiManifest(
            moduleID: Constants.moduleID,
            displayName: "Overlay UI",
            capabilities: capabilities,
            entryPoint: Constants.entryPoint
        )
    }

    let descriptor = uiDescriptor(moduleID: Constants.moduleID, displayName: "Overlay UI")
    let manifest = OverlayOnlyUIModule.moduleManifest(capabilities: [])
    let uiContributions = UIContributions(
        overlaySchema: OverlaySchema(
            schemaID: "overlay",
            pointers: [],
            routes: [
                OverlayRoute(
                    routeID: "route",
                    path: "/route",
                    destination: .base(destinationID: "home", parameters: nil)
                )
            ]
        )
    )

    func start(context _: ForsettiContext) throws {}
    func stop(context _: ForsettiContext) {}
}

private final class SourceSpoofingEventModule: ForsettiModule {
    enum Constants {
        static let moduleID = "com.forsetti.tests.source-event"
        static let entryPoint = "SourceSpoofingEventModule"
    }

    static let moduleManifest = serviceManifest(
        moduleID: Constants.moduleID,
        displayName: "Source Event",
        entryPoint: Constants.entryPoint
    )

    static func reset() {}

    let descriptor = serviceDescriptor(moduleID: Constants.moduleID, displayName: "Source Event")
    let manifest = SourceSpoofingEventModule.moduleManifest

    func start(context: ForsettiContext) throws {
        context.publishFrameworkEvent(
            type: "capability.spoof.event",
            payload: [:],
            sourceModuleID: "com.forsetti.tests.spoofed"
        )
    }

    func stop(context _: ForsettiContext) {}
}

private final class SourceSpoofingMessageModule: ForsettiModule {
    enum Constants {
        static let moduleID = "com.forsetti.tests.source-message"
        static let entryPoint = "SourceSpoofingMessageModule"
    }

    static var capturedError: Error?
    static let moduleManifest = serviceManifest(
        moduleID: Constants.moduleID,
        displayName: "Source Message",
        entryPoint: Constants.entryPoint
    )

    static func reset() {
        capturedError = nil
    }

    let descriptor = serviceDescriptor(moduleID: Constants.moduleID, displayName: "Source Message")
    let manifest = SourceSpoofingMessageModule.moduleManifest

    func start(context: ForsettiContext) throws {
        do {
            try context.sendModuleMessage(
                from: "com.forsetti.tests.spoofed",
                to: "com.forsetti.tests.target",
                type: "capability.message",
                payload: [:]
            )
        } catch {
            Self.capturedError = error
        }
    }

    func stop(context _: ForsettiContext) {}
}

private func serviceDescriptor(moduleID: String, displayName: String) -> ModuleDescriptor {
    ModuleDescriptor(
        moduleID: moduleID,
        displayName: displayName,
        moduleVersion: SemVer(major: 1, minor: 0, patch: 0),
        moduleType: .service
    )
}

private func serviceManifest(moduleID: String, displayName: String, entryPoint: String) -> ModuleManifest {
    ModuleManifest(
        schemaVersion: ModuleManifest.supportedSchemaVersion,
        moduleID: moduleID,
        displayName: displayName,
        moduleVersion: SemVer(major: 1, minor: 0, patch: 0),
        moduleType: .service,
        supportedPlatforms: [.iOS, .macOS],
        minForsettiVersion: ForsettiVersion.current,
        capabilitiesRequested: [],
        entryPoint: entryPoint
    )
}

private func uiDescriptor(moduleID: String, displayName: String) -> ModuleDescriptor {
    ModuleDescriptor(
        moduleID: moduleID,
        displayName: displayName,
        moduleVersion: SemVer(major: 1, minor: 0, patch: 0),
        moduleType: .ui
    )
}

private func uiManifest(
    moduleID: String,
    displayName: String,
    capabilities: [Capability],
    entryPoint: String
) -> ModuleManifest {
    ModuleManifest(
        schemaVersion: ModuleManifest.supportedSchemaVersion,
        moduleID: moduleID,
        displayName: displayName,
        moduleVersion: SemVer(major: 1, minor: 0, patch: 0),
        moduleType: .ui,
        supportedPlatforms: [.iOS, .macOS],
        minForsettiVersion: ForsettiVersion.current,
        capabilitiesRequested: capabilities,
        entryPoint: entryPoint
    )
}

private final class CapabilityStorageService: StorageService {
    func set(_ value: String, forKey key: String) {}
    func value(forKey key: String) -> String? { nil }
    func removeValue(forKey key: String) {}
}

private final class CapabilitySecureStorageService: SecureStorageService {
    func set(_ value: Data, forKey key: String) throws {}
    func value(forKey key: String) throws -> Data? { nil }
    func removeValue(forKey key: String) throws {}
}

private final class CapabilityRecordingLogger: ForsettiLogger, @unchecked Sendable {
    struct Entry {
        let level: LogLevel
        let message: String
    }

    private let lock = NSLock()
    private var storedEntries: [Entry] = []

    var entries: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return storedEntries
    }

    func log(_ level: LogLevel, message: String) {
        lock.lock()
        storedEntries.append(Entry(level: level, message: message))
        lock.unlock()
    }
}

private final class CapabilityActivationStore: ActivationStore, @unchecked Sendable {
    private var state = ActivationState()

    func loadState() -> ActivationState {
        state
    }

    func saveState(_ state: ActivationState) {
        self.state = state
    }
}

private final class CapabilityEventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedEvent: ForsettiEvent?

    var event: ForsettiEvent? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedEvent
        }
        set {
            lock.lock()
            storedEvent = newValue
            lock.unlock()
        }
    }
}

private final class CapabilityTestBundle {
    let rootURL: URL
    let bundleURL: URL
    let bundle: Bundle

    init(manifests: [ModuleManifest]) throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ForsettiCapabilityTests-\(UUID().uuidString)", isDirectory: true)
        bundleURL = rootURL.appendingPathComponent("CapabilityTests.bundle", isDirectory: true)

        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try Self.writeInfoPlist(at: bundleURL.appendingPathComponent("Info.plist"))

        let manifestsURL = bundleURL.appendingPathComponent("ForsettiManifests", isDirectory: true)
        try FileManager.default.createDirectory(at: manifestsURL, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        for manifest in manifests {
            try encoder.encode(manifest).write(
                to: manifestsURL.appendingPathComponent("\(manifest.moduleID).json"),
                options: .atomic
            )
        }

        guard let resolvedBundle = Bundle(url: bundleURL) else {
            throw NSError(
                domain: "CapabilityEnforcementTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Unable to initialize temporary capability test bundle."]
            )
        }

        bundle = resolvedBundle
    }

    deinit {
        try? FileManager.default.removeItem(at: rootURL)
    }

    private static func writeInfoPlist(at url: URL) throws {
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.forsetti.tests.capabilitybundle",
            "CFBundleName": "CapabilityTests",
            "CFBundleVersion": "1",
            "CFBundleShortVersionString": "1.0"
        ]

        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: url, options: .atomic)
    }
}
