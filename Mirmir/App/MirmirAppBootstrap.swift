import Combine
import Foundation

@MainActor
final class MirmirAppBootstrap: ObservableObject {
    enum ProductionState: Equatable {
        case idle
        case booting
        case ready
        case failed(String)
    }

    let moduleHost: MirmirModuleHost
    let viewRegistry: MirmirViewRegistry
    let viewModel: MirmirViewModel
    let diagnostics: MirmirDiagnosticStore

    @Published private(set) var productionState: ProductionState = .idle

    convenience init() {
        let diagnostics = MirmirDiagnosticStore.application
        do {
            try self.init(
                services: Self.makeProductionServices(
                    diagnostics: diagnostics
                ),
                diagnostics: diagnostics
            )
        } catch {
            preconditionFailure("Failed to compose Mirmir: \(Self.describe(error))")
        }
    }

    init(
        services: MirmirServices,
        diagnostics: MirmirDiagnosticStore? = nil
    ) throws {
        let registry = try MirmirModuleRegistry.makeRegistry(services: services)
        let moduleHost = try MirmirModuleHost(registry: registry)
        let diagnosticStore = diagnostics
            ?? MirmirDiagnosticStore(inMemoryWith: .production)
        let viewModel = MirmirViewModel(
            mediaPipeline: services.media,
            upscalerEngine: services.upscaler,
            modelAssets: services.modelAssets,
            diagnostics: diagnosticStore
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
        diagnostics: MirmirDiagnosticStore
    ) throws -> MirmirServices {
        guard #available(macOS 15.4, *) else {
            preconditionFailure("Mirmir requires macOS 15.4 or later.")
        }

        let metalService = try DefaultMetalRenderingService()
        let modelAssetsService = NotRequiredModelAssetsService()
        let mediaPipelineService = AVFoundationMediaPipeline(
            metal: metalService,
            diagnostics: diagnostics
        )
        let upscalerEngineService = R13ReleaseUpscalerEngineService(
            media: mediaPipelineService,
            cacheLocationStore: R13CacheLocationStore(),
            diagnostics: diagnostics
        )

        return MirmirServices(
            metal: metalService,
            modelAssets: modelAssetsService,
            media: mediaPipelineService,
            upscaler: upscalerEngineService
        )
    }

    private static func describe(_ error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription {
            return description
        }
        return String(describing: error)
    }
}
