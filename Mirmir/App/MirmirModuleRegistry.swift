struct MirmirServices: Sendable {
    let metal: MetalRenderingService
    let modelAssets: ModelAssetsService
    let media: MediaPipelineService
    let upscaler: UpscalerEngineService
}

@MainActor
enum MirmirModuleRegistry {
    static func makeRegistry(services: MirmirServices) throws -> MirmirModuleFactoryRegistry {
        let registry = MirmirModuleFactoryRegistry()
        try registerAll(into: registry, services: services)
        return registry
    }

    static func registerAll(
        into registry: MirmirModuleFactoryRegistry,
        services: MirmirServices
    ) throws {
        let metal = services.metal
        let modelAssets = services.modelAssets
        let media = services.media
        let upscaler = services.upscaler

        try registry.register(descriptor: MirmirModuleCatalog.metalRendering) {
            MetalRenderingServiceModule(service: metal)
        }
        try registry.register(descriptor: MirmirModuleCatalog.modelAssets) {
            ModelAssetsServiceModule(service: modelAssets)
        }
        try registry.register(descriptor: MirmirModuleCatalog.mediaPipeline) {
            MediaPipelineServiceModule(service: media)
        }
        try registry.register(descriptor: MirmirModuleCatalog.upscalerEngine) {
            UpscalerEngineServiceModule(service: upscaler)
        }
        try registry.register(descriptor: MirmirModuleCatalog.ui) {
            MirmirUIModule()
        }
    }
}
