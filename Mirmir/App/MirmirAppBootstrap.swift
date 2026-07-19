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

    @Published private(set) var productionState: ProductionState = .idle

    convenience init() {
        do {
            try self.init(services: Self.makeProductionServices())
        } catch {
            preconditionFailure("Failed to compose Mirmir: \(Self.describe(error))")
        }
    }

    init(services: MirmirServices) throws {
        let registry = try MirmirModuleRegistry.makeRegistry(services: services)
        let moduleHost = try MirmirModuleHost(registry: registry)
        let viewModel = MirmirViewModel(
            mediaPipeline: services.media,
            upscalerEngine: services.upscaler,
            modelAssets: services.modelAssets
        )
        let viewRegistry = MirmirViewRegistry()
        try viewRegistry.register(viewID: MirmirUIConstants.primaryViewID) {
            MirmirRootView(viewModel: viewModel)
        }

        self.moduleHost = moduleHost
        self.viewRegistry = viewRegistry
        self.viewModel = viewModel
    }

    func bootForProduction() {
        guard productionState == .idle else { return }
        productionState = .booting

        do {
            try moduleHost.start()
            guard moduleHost.isActive(moduleID: MirmirModuleCatalog.ui.moduleID) else {
                moduleHost.stop()
                productionState = .failed("UI module did not activate")
                return
            }
            guard viewRegistry.registeredViewIDs.contains(MirmirUIConstants.primaryViewID) else {
                moduleHost.stop()
                productionState = .failed(
                    "UI view \(MirmirUIConstants.primaryViewID) is not registered"
                )
                return
            }
            productionState = .ready
        } catch {
            productionState = .failed(Self.describe(error))
        }
    }

    private static func makeProductionServices() throws -> MirmirServices {
        guard #available(macOS 15.4, *) else {
            preconditionFailure("Mirmir requires macOS 15.4 or later.")
        }

        let metalService = try DefaultMetalRenderingService()
        let modelAssetsService = RoadmapTransitionModelAssetsService()
        let mediaPipelineService = AVFoundationMediaPipeline(metal: metalService)
        let upscalerEngineService = UnavailableUpscalerEngineService()

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
