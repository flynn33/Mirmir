import Foundation
import SwiftUI
import ForsettiCore
import ForsettiPlatform
import ForsettiHostTemplate

@MainActor
final class MirmirForsettiBootstrap: ObservableObject {

    let controller: ForsettiHostController
    let injectionRegistry: ForsettiViewInjectionRegistry
    let viewModel: MirmirViewModel

    @Published private(set) var productionState: ProductionState = .idle

    enum ProductionState: Equatable {
        case idle
        case booting
        case ready
        case failed(String)
    }

    init() {
        // Concrete service implementations.
        let metalService: MetalRenderingService
        do {
            metalService = try DefaultMetalRenderingService()
        } catch {
            preconditionFailure("Mirmir requires a Metal-capable Mac: \(error)")
        }

        let modelAssetsService: ModelAssetsService
        if #available(macOS 15.4, *) {
            modelAssetsService = DefaultModelAssetsService()
        } else {
            preconditionFailure("Mirmir requires macOS 15.4 or later for VTFrameProcessor super-resolution.")
        }

        let mediaPipelineService: MediaPipelineService = AVFoundationMediaPipeline(metal: metalService)

        let upscalerEngineService: UpscalerEngineService
        if #available(macOS 15.4, *) {
            upscalerEngineService = DefaultUpscalerEngineService(
                media: mediaPipelineService,
                metal: metalService,
                modelAssets: modelAssetsService,
                telemetryFactory: { DefaultASHTelemetryRecorder() }
            )
        } else {
            preconditionFailure("Mirmir requires macOS 15.4 or later.")
        }

        let services = MirmirServices(
            metal: metalService,
            modelAssets: modelAssetsService,
            media: mediaPipelineService,
            upscaler: upscalerEngineService
        )

        // Forsetti service container — pre-populated with the standard
        // platform services (Storage, FileExport, Telemetry, etc.). The
        // capability-scoped resolver only resolves these standard contracts
        // for modules; Mirmir's custom services are wired through the module
        // registry's factory closures (see `MirmirModuleRegistry`).
        let platform = DefaultForsettiPlatformServices()
        let serviceContainer = platform.container

        // Module registry: factories capture the concrete services so each
        // module instance receives its dependency by constructor injection.
        let registry = ModuleRegistry()
        do {
            try MirmirModuleRegistry.registerAll(into: registry, services: services)
        } catch {
            preconditionFailure("Failed to register Mirmir modules: \(error.localizedDescription)")
        }

        let viewModel = MirmirViewModel(
            mediaPipeline: mediaPipelineService,
            upscalerEngine: upscalerEngineService,
            modelAssets: modelAssetsService
        )
        self.viewModel = viewModel

        // Build the runtime + host controller manually. We can't use
        // `ForsettiHostTemplateBootstrap.makeController(...)` because that
        // helper constructs its own `DefaultForsettiPlatformServices` and
        // gives us no way to inject our service container.
        let logger: any ForsettiLogger = OSLogForsettiLogger(
            subsystem: Bundle.main.bundleIdentifier ?? "com.mirmir.app",
            category: "Forsetti"
        )
        let entitlementProvider: any ForsettiEntitlementProvider = ForsettiEntitlementProviderFactory.makeDefault()
        let activationStore: any ActivationStore = UserDefaultsActivationStore()
        let capabilityPolicy: any CapabilityPolicy = FixedCapabilityPolicy(
            allowedCapabilities: MirmirForsettiConstants.allowedCapabilities
        )
        let uiSurfaceManager = UISurfaceManager()
        let router: any OverlayRouting = ForsettiHostOverlayRouter(
            uiSurfaceManager: uiSurfaceManager,
            baseDestinationIDs: BaseDestinationCatalog.all,
            slotIDs: SlotCatalog.all
        )
        let runtime = ForsettiRuntime(
            services: serviceContainer,
            entitlementProvider: entitlementProvider,
            capabilityPolicy: capabilityPolicy,
            activationStore: activationStore,
            logger: logger,
            router: router,
            moduleRegistry: registry,
            uiSurfaceManager: uiSurfaceManager
        )
        self.controller = ForsettiHostController(
            runtime: runtime,
            entitlementProvider: entitlementProvider,
            manifestsBundle: .main,
            manifestsSubdirectory: MirmirForsettiConstants.manifestSubdirectory
        )

        let injection = ForsettiViewInjectionRegistry()
        injection.register(viewID: MirmirUIConstants.primaryViewID) {
            MirmirRootView(viewModel: viewModel)
        }
        self.injectionRegistry = injection
    }

    /// Production boot path: activates exactly Mirmir's modules, requires the
    /// UI module to be the active one, and surfaces a hard failure if any
    /// step fails. The development path (`ForsettiHostRootView`) drives
    /// activation itself via its `launchActivationStrategy`.
    func bootForProduction() async {
        guard productionState == .idle else { return }
        productionState = .booting

        await controller.bootIfNeeded(
            restoreActivationState: false,
            activationStrategy: .activate(moduleIDs: MirmirForsettiConstants.allModuleIDs)
        )

        if controller.activeUIModuleID == MirmirUIConstants.moduleID {
            productionState = .ready
        } else if let message = controller.errorMessage {
            productionState = .failed(message)
        } else {
            productionState = .failed("UI module did not activate")
        }
    }
}
