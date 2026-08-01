import Combine
import Foundation

@MainActor
final class MirmirAppComposition: ObservableObject {
    enum State {
        case ready(MirmirAppBootstrap)
        case failed(String)
    }

    @Published private(set) var state: State

    let diagnosticStore: MirmirDiagnosticStore
    private let bootstrapFactory:
        (MirmirDiagnosticStore) throws -> MirmirAppBootstrap

    init(
        diagnostics: MirmirDiagnosticStore = .application,
        bootstrapFactory:
            @escaping (MirmirDiagnosticStore) throws
                -> MirmirAppBootstrap = {
                try MirmirAppBootstrap.makeProduction(
                    diagnostics: $0
                )
            }
    ) {
        self.diagnosticStore = diagnostics
        self.bootstrapFactory = bootstrapFactory
        do {
            state = .ready(try bootstrapFactory(diagnosticStore))
        } catch {
            state = .failed(MirmirAppBootstrap.describe(error))
            recordCompositionFailure(error)
        }
    }

    func retry() {
        guard case .failed = state else { return }
        recordCompositionEvent(
            severity: .info,
            code: "app_composition_retry_started"
        )

        do {
            state = .ready(try bootstrapFactory(diagnosticStore))
            recordCompositionEvent(
                severity: .info,
                code: "app_composition_retry_succeeded"
            )
        } catch {
            state = .failed(MirmirAppBootstrap.describe(error))
            recordCompositionFailure(error)
        }
    }

    private func recordCompositionFailure(_ error: Error) {
        recordCompositionEvent(
            severity: .critical,
            code: "app_composition_failed",
            error: error
        )
    }

    private func recordCompositionEvent(
        severity: MirmirDiagnosticSeverity,
        code: String,
        error: Error? = nil
    ) {
        MirmirDiagnosticRecorder(store: diagnosticStore).enqueue(
            severity: severity,
            subsystem: "application",
            operation: "composition",
            code: code,
            error: error
        )
    }
}

@MainActor
final class MirmirAppBootstrap: ObservableObject {
    enum ProductionState: Equatable {
        case idle
        case booting
        case ready
        case failed(String)
    }

    struct ProductionStorage {
        let preferencesStore: MirmirPreferencesStore
        let workHistoryStore: MirmirWorkHistoryStore
        let pendingWorkQueue: MirmirPendingWorkQueue
        let cacheLocationStore: R13CacheLocationStore
    }

    let moduleHost: MirmirModuleHost
    let viewRegistry: MirmirViewRegistry
    let viewModel: MirmirViewModel
    let diagnostics: MirmirDiagnosticStore

    @Published private(set) var productionState: ProductionState = .idle

    static func makeProduction(
        diagnostics: MirmirDiagnosticStore = .application
    ) throws -> MirmirAppBootstrap {
        let services = try makeProductionServices(
            diagnostics: diagnostics,
            cacheLocationStore: R13CacheLocationStore()
        )
        return try MirmirAppBootstrap(
            services: services,
            diagnostics: diagnostics,
            preferencesStore: MirmirPreferencesStore(),
            workHistoryStore: try MirmirWorkHistoryStore.production(),
            pendingWorkQueue: try MirmirPendingWorkQueue.production()
        )
    }

    static func makeProduction(
        diagnostics: MirmirDiagnosticStore,
        storage: ProductionStorage
    ) throws -> MirmirAppBootstrap {
        try MirmirAppBootstrap(
            services: makeProductionServices(
                diagnostics: diagnostics,
                cacheLocationStore: storage.cacheLocationStore
            ),
            diagnostics: diagnostics,
            preferencesStore: storage.preferencesStore,
            workHistoryStore: storage.workHistoryStore,
            pendingWorkQueue: storage.pendingWorkQueue
        )
    }

    init(
        services: MirmirServices,
        diagnostics: MirmirDiagnosticStore? = nil,
        preferencesStore: MirmirPreferencesStore? = nil,
        workHistoryStore: MirmirWorkHistoryStore? = nil,
        pendingWorkQueue: MirmirPendingWorkQueue? = nil,
        workHistoryBookmarkResolver:
            any MirmirWorkHistoryBookmarkResolving =
                MirmirFoundationWorkBookmarkResolver()
    ) throws {
        let registry = try MirmirModuleRegistry.makeRegistry(services: services)
        let moduleHost = try MirmirModuleHost(registry: registry)
        let diagnosticStore = diagnostics
            ?? MirmirDiagnosticStore(inMemoryWith: .production)
        let viewModel = MirmirViewModel(
            mediaPipeline: services.media,
            upscalerEngine: services.upscaler,
            modelAssets: services.modelAssets,
            diagnostics: diagnosticStore,
            preferencesStore: preferencesStore,
            workHistoryStore: workHistoryStore,
            pendingWorkQueue: pendingWorkQueue,
            workHistoryBookmarkResolver:
                workHistoryBookmarkResolver
        )
        let viewRegistry = MirmirViewRegistry()
        try viewRegistry.register(viewID: MirmirUIConstants.primaryViewID) {
            MirmirRootView(viewModel: viewModel)
        }

        self.moduleHost = moduleHost
        self.viewRegistry = viewRegistry
        self.viewModel = viewModel
        self.diagnostics = diagnosticStore
    }

    func bootForProduction() {
        guard productionState == .idle else { return }
        productionState = .booting
        recordBootstrapEvent(
            severity: .info,
            code: "app_boot_started"
        )

        do {
            try moduleHost.start()
            guard moduleHost.isActive(moduleID: MirmirModuleCatalog.ui.moduleID) else {
                moduleHost.stop()
                productionState = .failed("UI module did not activate")
                recordBootstrapEvent(
                    severity: .critical,
                    code: "app_boot_ui_module_inactive"
                )
                return
            }
            guard viewRegistry.registeredViewIDs.contains(MirmirUIConstants.primaryViewID) else {
                moduleHost.stop()
                productionState = .failed(
                    "UI view \(MirmirUIConstants.primaryViewID) is not registered"
                )
                recordBootstrapEvent(
                    severity: .critical,
                    code: "app_boot_root_view_missing"
                )
                return
            }
            productionState = .ready
            recordBootstrapEvent(
                severity: .info,
                code: "app_boot_succeeded"
            )
        } catch {
            productionState = .failed(Self.describe(error))
            recordBootstrapEvent(
                severity: .critical,
                code: "app_boot_failed",
                error: error
            )
        }
    }

    func retryProductionBoot() {
        switch productionState {
        case .failed:
            break
        case .ready:
            moduleHost.stop()
        case .idle, .booting:
            return
        }

        recordBootstrapEvent(
            severity: .info,
            code: "app_boot_retry_started"
        )
        productionState = .idle
        bootForProduction()
    }

    private func recordBootstrapEvent(
        severity: MirmirDiagnosticSeverity,
        code: String,
        error: Error? = nil
    ) {
        let recorder = MirmirDiagnosticRecorder(store: diagnostics)
        recorder.enqueue(
            severity: severity,
            subsystem: "application",
            operation: "bootstrap",
            code: code,
            error: error
        )
    }

    private static func makeProductionServices(
        diagnostics: MirmirDiagnosticStore,
        cacheLocationStore: R13CacheLocationStore
    ) throws -> MirmirServices {
        let metalService = try DefaultMetalRenderingService()
        let modelAssetsService = DefaultModelAssetsService()
        let mediaPipelineService = AVFoundationMediaPipeline(
            metal: metalService,
            diagnostics: diagnostics
        )
        let upscalerEngineService = R13ReleaseUpscalerEngineService(
            media: mediaPipelineService,
            cacheLocationStore: cacheLocationStore,
            diagnostics: diagnostics
        )

        return MirmirServices(
            metal: metalService,
            modelAssets: modelAssetsService,
            media: mediaPipelineService,
            upscaler: upscalerEngineService
        )
    }

    static func describe(_ error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription {
            return description
        }
        return String(describing: error)
    }
}
