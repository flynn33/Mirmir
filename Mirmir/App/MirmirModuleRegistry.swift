import Foundation
import ForsettiCore

struct MirmirServices: Sendable {
    let metal: MetalRenderingService
    let modelAssets: ModelAssetsService
    let media: MediaPipelineService
    let upscaler: UpscalerEngineService
}

enum MirmirModuleRegistry {
    static func registerAll(into registry: ModuleRegistry, services: MirmirServices) throws {
        let metal = services.metal
        let modelAssets = services.modelAssets
        let media = services.media
        let upscaler = services.upscaler

        try registry.register(entryPoint: MirmirMetalConstants.entryPoint) { @Sendable in
            MetalRenderingServiceModule(service: metal)
        }
        try registry.register(entryPoint: MirmirModelAssetsConstants.entryPoint) { @Sendable in
            ModelAssetsServiceModule(service: modelAssets)
        }
        try registry.register(entryPoint: MirmirMediaPipelineConstants.entryPoint) { @Sendable in
            MediaPipelineServiceModule(service: media)
        }
        try registry.register(entryPoint: MirmirUpscalerEngineConstants.entryPoint) { @Sendable in
            UpscalerEngineServiceModule(service: upscaler)
        }
        try registry.register(entryPoint: MirmirUIConstants.entryPoint) { @Sendable in
            MirmirUIModule()
        }
    }
}
