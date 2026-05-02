import Foundation
import XCTest
@testable import ForsettiCore

@MainActor
final class ModuleLoggingTests: XCTestCase {
    func testReportModuleErrorRoutesThroughFrameworkLogger() {
        let logger = RecordingForsettiLogger()
        let context = makeContext(logger: logger)

        context.reportModuleError(
            moduleID: "com.forsetti.module.test",
            message: "Credential refresh failed",
            error: ModuleLoggingTestError.refreshFailed,
            metadata: ["operation": "credential_refresh"]
        )

        let errorEntry = logger.entries.first { $0.level == .error }
        XCTAssertNotNil(errorEntry)
        XCTAssertTrue(errorEntry?.message.contains("module=com.forsetti.module.test") == true)
        XCTAssertTrue(errorEntry?.message.contains("operation=credential_refresh") == true)
        XCTAssertTrue(errorEntry?.message.contains("errorType=ModuleLoggingTestError") == true)
        XCTAssertTrue(errorEntry?.message.contains("Credential refresh failed") == true)
    }

    func testModuleStartFailureIsForwardedToFrameworkLogger() async throws {
        let moduleID = "com.forsetti.module.failing-service"
        let entryPoint = "FailingServiceModule"

        let manifest = ModuleManifest(
            schemaVersion: ModuleManifest.supportedSchemaVersion,
            moduleID: moduleID,
            displayName: "Failing Service",
            moduleVersion: SemVer(major: 1, minor: 0, patch: 0),
            moduleType: .service,
            supportedPlatforms: [.iOS, .macOS],
            minForsettiVersion: ForsettiVersion.current,
            maxForsettiVersion: nil,
            capabilitiesRequested: [.secureStorage],
            iapProductID: nil,
            entryPoint: entryPoint
        )

        let testBundle = try LoggingTestBundle(manifests: ["FailingService.json": manifest])
        let logger = RecordingForsettiLogger()
        let registry = ModuleRegistry()
        registry.register(entryPoint: entryPoint) {
            FailingServiceModule()
        }

        let manager = ModuleManager(
            manifestLoader: ManifestLoader(),
            moduleRegistry: registry,
            compatibilityChecker: CompatibilityChecker(
                runtimePlatform: .macOS,
                forsettiVersion: ForsettiVersion.current,
                capabilityPolicy: AllowAllCapabilityPolicy()
            ),
            activationStore: LoggingActivationStore(),
            entitlementProvider: StaticEntitlementProvider(unlockedModuleIDs: [moduleID]),
            uiSurfaceManager: UISurfaceManager(),
            context: makeContext(logger: logger)
        )

        _ = try manager.discoverModules(bundle: testBundle.bundle, subdirectory: "ForsettiManifests")

        do {
            try await manager.activateModule(moduleID: moduleID)
            XCTFail("Expected module start to fail.")
        } catch let error as ModuleLoggingTestError {
            XCTAssertEqual(error, .refreshFailed)
        } catch {
            XCTFail("Expected ModuleLoggingTestError, received \(error).")
        }

        let errorEntry = logger.entries.first { $0.level == .error && $0.message.contains("module=\(moduleID)") }
        XCTAssertNotNil(errorEntry)
        XCTAssertTrue(errorEntry?.message.contains("Module failed to start") == true)
        XCTAssertTrue(errorEntry?.message.contains("moduleType=service") == true)
    }

    private func makeContext(logger: any ForsettiLogger) -> ForsettiContext {
        ForsettiContext(
            eventBus: InMemoryEventBus(),
            services: ForsettiServiceContainer(),
            logger: logger,
            router: NoopOverlayRouter()
        )
    }
}

private enum ModuleLoggingTestError: Error, Equatable {
    case refreshFailed
}

private final class FailingServiceModule: ForsettiModule {
    let descriptor = ModuleDescriptor(
        moduleID: "com.forsetti.module.failing-service",
        displayName: "Failing Service",
        moduleVersion: SemVer(major: 1, minor: 0, patch: 0),
        moduleType: .service
    )

    let manifest = ModuleManifest(
        schemaVersion: ModuleManifest.supportedSchemaVersion,
        moduleID: "com.forsetti.module.failing-service",
        displayName: "Failing Service",
        moduleVersion: SemVer(major: 1, minor: 0, patch: 0),
        moduleType: .service,
        supportedPlatforms: [.iOS, .macOS],
        minForsettiVersion: ForsettiVersion.current,
        maxForsettiVersion: nil,
        capabilitiesRequested: [.secureStorage],
        iapProductID: nil,
        entryPoint: "FailingServiceModule"
    )

    func start(context _: ForsettiContext) throws {
        throw ModuleLoggingTestError.refreshFailed
    }

    func stop(context _: ForsettiContext) {}
}

private final class LoggingActivationStore: ActivationStore, @unchecked Sendable {
    private var state = ActivationState()

    func loadState() -> ActivationState {
        state
    }

    func saveState(_ state: ActivationState) {
        self.state = state
    }
}

private final class RecordingForsettiLogger: ForsettiLogger, @unchecked Sendable {
    struct Entry: Equatable {
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
        storedEntries.append(.init(level: level, message: message))
        lock.unlock()
    }
}

private final class LoggingTestBundle {
    let rootURL: URL
    let bundleURL: URL
    let bundle: Bundle

    init(manifests: [String: ModuleManifest]) throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ForsettiLoggingTests-\(UUID().uuidString)", isDirectory: true)
        bundleURL = rootURL.appendingPathComponent("LoggingTests.bundle", isDirectory: true)

        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try Self.writeInfoPlist(at: bundleURL.appendingPathComponent("Info.plist"))

        let manifestsURL = bundleURL.appendingPathComponent("ForsettiManifests", isDirectory: true)
        try FileManager.default.createDirectory(at: manifestsURL, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        for (fileName, manifest) in manifests {
            try encoder.encode(manifest).write(
                to: manifestsURL.appendingPathComponent(fileName),
                options: .atomic
            )
        }

        guard let resolvedBundle = Bundle(url: bundleURL) else {
            throw NSError(
                domain: "ModuleLoggingTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Unable to initialize temporary logging test bundle."]
            )
        }

        bundle = resolvedBundle
    }

    deinit {
        try? FileManager.default.removeItem(at: rootURL)
    }

    private static func writeInfoPlist(at url: URL) throws {
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.forsetti.tests.loggingbundle",
            "CFBundleName": "LoggingTests",
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
