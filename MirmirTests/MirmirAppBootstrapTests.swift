import CoreVideo
import Foundation
import Metal
import XCTest
@testable import Mirmir

@MainActor
final class MirmirAppBootstrapTests: XCTestCase {
    func testAppProcessContextRecognizesHostedUnitTests() {
        XCTAssertTrue(
            MirmirAppProcessContext.isHostedByXCTest(),
            "The unit-test host must not open Mirmir's production stores."
        )
    }

    func testAppProcessContextRequiresAConcreteXCTestHostSignal() {
        XCTAssertFalse(
            MirmirAppProcessContext.isHostedByXCTest(environment: [:])
        )
        XCTAssertFalse(
            MirmirAppProcessContext.isHostedByXCTest(
                environment: [
                    "XCTestConfigurationFilePath": "",
                    "XCInjectBundleInto": ""
                ]
            )
        )
        XCTAssertTrue(
            MirmirAppProcessContext.isHostedByXCTest(
                environment: [
                    "XCTestConfigurationFilePath":
                        "/tmp/mirmir-tests.xctestconfiguration"
                ]
            )
        )
        XCTAssertTrue(
            MirmirAppProcessContext.isHostedByXCTest(
                environment: [
                    "XCInjectBundleInto":
                        "/tmp/Mirmir.app/Contents/MacOS/Mirmir"
                ]
            )
        )
    }

    func test_injectedBootstrapBootsExactRuntimeAndRegistersWorkspaceView() throws {
        let diagnostics = MirmirDiagnosticStore(inMemoryWith: .production)
        let bootstrap = try MirmirAppBootstrap(services: MirmirServices(
            metal: NoopMetalRenderingService(),
            modelAssets: NoopModelAssetsService(),
            media: NoopMediaPipelineService(),
            upscaler: NoopUpscalerEngineService()
        ), diagnostics: diagnostics)

        XCTAssertEqual(bootstrap.productionState, .idle)
        XCTAssertTrue(bootstrap.diagnostics === diagnostics)
        bootstrap.bootForProduction()
        bootstrap.bootForProduction()

        XCTAssertEqual(bootstrap.productionState, .ready)
        XCTAssertEqual(bootstrap.moduleHost.state, .active)
        XCTAssertEqual(
            bootstrap.moduleHost.records.map(\.descriptor),
            MirmirModuleCatalog.activationOrder
        )
        XCTAssertEqual(
            bootstrap.moduleHost.records.map(\.lifecycleState),
            Array(repeating: .active, count: 5)
        )
        XCTAssertNotNil(
            bootstrap.viewRegistry.resolve(viewID: MirmirUIConstants.primaryViewID)
        )
    }

    func test_defaultBootstrapExposesAllReleaseModesAndDefersModelBinding()
        async throws {
        let storage = try IsolatedProductionStorage()
        let diagnostics = MirmirDiagnosticStore(
            inMemoryWith: .production
        )
        let bootstrap = try MirmirAppBootstrap.makeProduction(
            diagnostics: diagnostics,
            storage: storage.productionStorage
        )

        XCTAssertTrue(bootstrap.diagnostics === diagnostics)
        XCTAssertEqual(diagnostics.storageKind, .memoryOnly)
        XCTAssertTrue(
            FileURLIdentity.refersToSameFile(
                URL(
                    fileURLWithPath:
                        bootstrap.viewModel.cacheLocationPath,
                    isDirectory: true
                ),
                storage.jobsRootURL
            )
        )
        XCTAssertEqual(bootstrap.viewModel.engineAvailability, .available)
        XCTAssertEqual(bootstrap.viewModel.selectedMode, .deterministic)
        XCTAssertEqual(bootstrap.viewModel.selectedModeAvailability, .available)
        XCTAssertEqual(
            bootstrap.viewModel.engineSelectionText,
            "Apple MPS Lanczos"
        )

        bootstrap.viewModel.selectedMode = .auto
        XCTAssertEqual(
            bootstrap.viewModel.selectedModeAvailability,
            .available
        )
        XCTAssertEqual(
            bootstrap.viewModel.engineSelectionText,
            "ASH Multi-Engine Routing"
        )

        for _ in 0..<100 {
            await Task.yield()
        }
        XCTAssertEqual(bootstrap.viewModel.modelStatus, .unknown)
        XCTAssertEqual(
            bootstrap.viewModel.modelAssetsStatusText,
            "Model asset status unknown"
        )
        XCTAssertEqual(
            bootstrap.viewModel.modelAssetsBinding,
            .unresolved
        )

        try await waitForInitialStorageLoads(
            in: bootstrap.viewModel
        )
        XCTAssertNil(bootstrap.viewModel.cacheLocationError)
        XCTAssertNil(bootstrap.viewModel.recoveryError)
        XCTAssertNil(bootstrap.viewModel.workHistoryError)
        XCTAssertNil(bootstrap.viewModel.pendingQueueError)
        XCTAssertEqual(
            bootstrap.viewModel.recoveryRejectedEntryCount,
            0
        )
        try storage.cleanup()
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: storage.rootURL.path
            )
        )
    }

    func test_successfulCompositionPreservesBootstrapIdentity() throws {
        let diagnostics = MirmirDiagnosticStore(
            inMemoryWith: .production
        )
        let expected = try MirmirAppBootstrap(
            services: MirmirServices(
                metal: NoopMetalRenderingService(),
                modelAssets: NoopModelAssetsService(),
                media: NoopMediaPipelineService(),
                upscaler: NoopUpscalerEngineService()
            ),
            diagnostics: diagnostics
        )
        var factoryInvocationCount = 0

        let composition = MirmirAppComposition(
            diagnostics: diagnostics
        ) { receivedDiagnostics in
            factoryInvocationCount += 1
            XCTAssertTrue(receivedDiagnostics === diagnostics)
            return expected
        }

        guard case .ready(let actual) = composition.state else {
            return XCTFail("Expected successful composition.")
        }
        XCTAssertTrue(actual === expected)
        XCTAssertEqual(factoryInvocationCount, 1)
    }

    func test_compositionFailureIsVisibleAndRecorded() async throws {
        let diagnostics = MirmirDiagnosticStore(
            inMemoryWith: .production
        )

        let composition = MirmirAppComposition(
            diagnostics: diagnostics
        ) { _ in
            throw InjectedCompositionError()
        }

        guard case .failed(let reason) = composition.state else {
            return XCTFail("Expected failed composition.")
        }
        XCTAssertEqual(reason, InjectedCompositionError.message)
        XCTAssertTrue(composition.diagnosticStore === diagnostics)

        let snapshot = try await diagnostics.snapshot()
        XCTAssertEqual(
            snapshot.records.map(\.event.code.rawValue),
            ["app_composition_failed"]
        )
        XCTAssertEqual(
            snapshot.records.first?.event.operation.rawValue,
            "composition"
        )
    }

    func test_transientCompositionFailureSucceedsOnRetryAndRecordsRecovery()
        async throws {
        let diagnostics = MirmirDiagnosticStore(
            inMemoryWith: .production
        )
        let expected = try makeInjectedBootstrap(
            diagnostics: diagnostics
        )
        var factoryInvocationCount = 0
        let composition = MirmirAppComposition(
            diagnostics: diagnostics
        ) { _ in
            factoryInvocationCount += 1
            if factoryInvocationCount == 1 {
                throw InjectedCompositionError()
            }
            return expected
        }

        guard case .failed = composition.state else {
            return XCTFail("Expected the initial composition to fail.")
        }

        composition.retry()

        guard case .ready(let actual) = composition.state else {
            return XCTFail("Expected composition retry to succeed.")
        }
        XCTAssertTrue(actual === expected)
        XCTAssertEqual(factoryInvocationCount, 2)

        let snapshot = try await diagnostics.snapshot()
        XCTAssertEqual(
            snapshot.records.map(\.event.code.rawValue),
            [
                "app_composition_failed",
                "app_composition_retry_started",
                "app_composition_retry_succeeded"
            ]
        )
    }

    func test_transientBootstrapFailureSucceedsOnRetryAndRecordsRecovery()
        async throws {
        let diagnostics = MirmirDiagnosticStore(
            inMemoryWith: .production
        )
        let metal = FailOnceMetalRenderingService()
        let bootstrap = try MirmirAppBootstrap(
            services: MirmirServices(
                metal: metal,
                modelAssets: NoopModelAssetsService(),
                media: NoopMediaPipelineService(),
                upscaler: NoopUpscalerEngineService()
            ),
            diagnostics: diagnostics
        )

        bootstrap.bootForProduction()

        guard case .failed(let reason) = bootstrap.productionState else {
            return XCTFail("Expected the initial bootstrap to fail.")
        }
        XCTAssertTrue(reason.contains(InjectedBootstrapError.message))

        bootstrap.retryProductionBoot()

        XCTAssertEqual(bootstrap.productionState, .ready)
        XCTAssertEqual(metal.startInvocationCount, 2)
        XCTAssertEqual(bootstrap.moduleHost.state, .active)

        let snapshot = try await diagnostics.snapshot()
        XCTAssertEqual(
            snapshot.records.map(\.event.code.rawValue),
            [
                "app_boot_started",
                "app_boot_failed",
                "app_boot_retry_started",
                "app_boot_started",
                "app_boot_succeeded"
            ]
        )
    }

    func test_bootstrapRecompositionReloadsPersistedUserPreferences()
        throws {
        let suiteName =
            "com.mirmir.tests.bootstrap-preferences.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName)
        )
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let keys = MirmirPreferencesKeys.namespaced(
            "com.mirmir.tests.bootstrap-preferences"
        )
        let diagnostics = MirmirDiagnosticStore(
            inMemoryWith: .production
        )
        let first = try makeInjectedBootstrap(
            diagnostics: diagnostics,
            preferencesStore: MirmirPreferencesStore(
                defaults: defaults,
                keys: keys
            )
        )

        XCTAssertTrue(
            first.viewModel.selectAppearanceMode(.midnightNordic)
        )
        XCTAssertTrue(first.viewModel.selectDefaultMode(.fast))
        XCTAssertTrue(first.viewModel.selectDefaultOutputCodec(.h264))
        XCTAssertTrue(
            first.viewModel.selectDefaultEngine(.mpsBilinear)
        )
        XCTAssertTrue(
            first.viewModel.selectDefaultStrategy(.adaptive)
        )
        XCTAssertTrue(
            first.viewModel.setDefaultTemporalConsistency(false)
        )
        XCTAssertTrue(
            first.viewModel.selectDefaultEdgeFidelity(.high)
        )
        XCTAssertTrue(
            first.viewModel.selectDefaultDetailRecovery(.low)
        )

        let second = try makeInjectedBootstrap(
            diagnostics: diagnostics,
            preferencesStore: MirmirPreferencesStore(
                defaults: try XCTUnwrap(
                    UserDefaults(suiteName: suiteName)
                ),
                keys: keys
            )
        )

        XCTAssertEqual(second.viewModel.appearanceMode, .midnightNordic)
        XCTAssertEqual(second.viewModel.selectedMode, .fast)
        XCTAssertEqual(second.viewModel.codec, .h264)
        XCTAssertEqual(second.viewModel.enginePreference, .mpsBilinear)
        XCTAssertEqual(second.viewModel.strategyPreference, .adaptive)
        XCTAssertFalse(second.viewModel.temporalConsistencyEnabled)
        XCTAssertEqual(second.viewModel.edgeFidelityLevel, .high)
        XCTAssertEqual(second.viewModel.detailRecoveryLevel, .low)
    }

    func test_developerRootContainsNoModuleMutationControls() throws {
        let source = try String(
            contentsOf: repoRootURL().appendingPathComponent(
                "Mirmir/App/MirmirDeveloperRootView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertFalse(source.contains("host.stop"))
        XCTAssertFalse(source.contains("deactivate"))
        XCTAssertFalse(source.contains("Toggle("))
    }

    private func repoRootURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func makeInjectedBootstrap(
        diagnostics: MirmirDiagnosticStore,
        preferencesStore: MirmirPreferencesStore? = nil
    ) throws -> MirmirAppBootstrap {
        try MirmirAppBootstrap(
            services: MirmirServices(
                metal: NoopMetalRenderingService(),
                modelAssets: NoopModelAssetsService(),
                media: NoopMediaPipelineService(),
                upscaler: NoopUpscalerEngineService()
            ),
            diagnostics: diagnostics,
            preferencesStore: preferencesStore
        )
    }

    private func waitForInitialStorageLoads(
        in viewModel: MirmirViewModel
    ) async throws {
        if let recoveryTask = viewModel.recoveryTask {
            await recoveryTask.value
        }
        if let releaseDiagnosticsTask = viewModel.releaseDiagnosticsTask {
            await releaseDiagnosticsTask.value
        }
        for _ in 0..<200 {
            if !viewModel.workHistoryIsLoading,
               !viewModel.pendingQueueIsLoading {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw IsolatedProductionStorageError.initialLoadTimedOut
    }
}

private struct InjectedCompositionError: LocalizedError {
    static let message = "Injected production composition failure."

    var errorDescription: String? {
        Self.message
    }
}

private struct InjectedBootstrapError: LocalizedError {
    static let message = "Injected transient bootstrap failure."

    var errorDescription: String? {
        Self.message
    }
}

private final class IsolatedProductionStorage {
    let rootURL: URL
    let jobsRootURL: URL
    let preferencesStore: MirmirPreferencesStore
    let workHistoryStore: MirmirWorkHistoryStore
    let pendingWorkQueue: MirmirPendingWorkQueue
    let cacheLocationStore: R13CacheLocationStore

    private let defaults: UserDefaults
    private let defaultsSuiteName: String

    var productionStorage: MirmirAppBootstrap.ProductionStorage {
        MirmirAppBootstrap.ProductionStorage(
            preferencesStore: preferencesStore,
            workHistoryStore: workHistoryStore,
            pendingWorkQueue: pendingWorkQueue,
            cacheLocationStore: cacheLocationStore
        )
    }

    init() throws {
        let identifier = UUID().uuidString
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "mirmir-production-bootstrap-tests-\(identifier)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: false
        )
        jobsRootURL = rootURL
            .appendingPathComponent("Mirmir", isDirectory: true)
            .appendingPathComponent("Jobs", isDirectory: true)
        defaultsSuiteName =
            "com.mirmir.tests.production-bootstrap.\(identifier)"
        guard let defaults = UserDefaults(suiteName: defaultsSuiteName) else {
            throw IsolatedProductionStorageError.userDefaultsUnavailable
        }
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        self.defaults = defaults
        preferencesStore = MirmirPreferencesStore(
            defaults: defaults,
            keys: .namespaced(defaultsSuiteName)
        )
        let fileSystem = try R13LocalRestartFileSystem(
            trustedRootURL: rootURL
        )
        workHistoryStore = MirmirWorkHistoryStore(
            directoryURL: rootURL.appendingPathComponent(
                "WorkHistory",
                isDirectory: true
            ),
            fileSystem: fileSystem
        )
        pendingWorkQueue = MirmirPendingWorkQueue(
            directoryURL: rootURL.appendingPathComponent(
                "PendingWork",
                isDirectory: true
            ),
            fileSystem: fileSystem
        )
        cacheLocationStore = R13CacheLocationStore(
            defaults: defaults,
            preferenceKey:
                "com.mirmir.tests.production-bootstrap.cache-location",
            defaultRootProvider: { [rootURL] in rootURL }
        )
    }

    func cleanup() throws {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        if FileManager.default.fileExists(atPath: rootURL.path) {
            try FileManager.default.removeItem(at: rootURL)
        }
    }
}

private enum IsolatedProductionStorageError: Error {
    case userDefaultsUnavailable
    case initialLoadTimedOut
}

private final class FailOnceMetalRenderingService:
    MetalRenderingService,
    @unchecked Sendable {
    private let base = NoopMetalRenderingService()

    private(set) var startInvocationCount = 0

    var device: MTLDevice { base.device }
    var commandQueue: MTLCommandQueue { base.commandQueue }
    var textureCache: CVMetalTextureCache { base.textureCache }

    func start() throws {
        startInvocationCount += 1
        guard startInvocationCount > 1 else {
            throw InjectedBootstrapError()
        }
        try base.start()
    }

    func stop() {
        base.stop()
    }
}
