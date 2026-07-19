enum MirmirModuleCatalog {
    static let metalRendering = MirmirModuleDescriptor(
        moduleID: "com.mirmir.app.metal",
        displayName: "Metal Rendering",
        versionString: "1.0.0",
        entryPoint: "MetalRenderingServiceModule",
        kind: .service
    )

    static let modelAssets = MirmirModuleDescriptor(
        moduleID: "com.mirmir.app.model-assets",
        displayName: "Model Assets",
        versionString: "1.0.0",
        entryPoint: "ModelAssetsServiceModule",
        kind: .service
    )

    static let mediaPipeline = MirmirModuleDescriptor(
        moduleID: "com.mirmir.app.media-pipeline",
        displayName: "Media Pipeline",
        versionString: "1.0.0",
        entryPoint: "MediaPipelineServiceModule",
        kind: .service
    )

    static let upscalerEngine = MirmirModuleDescriptor(
        moduleID: "com.mirmir.app.upscaler-engine",
        displayName: "Upscaler Engine",
        versionString: "1.0.0",
        entryPoint: "UpscalerEngineServiceModule",
        kind: .service
    )

    static let ui = MirmirModuleDescriptor(
        moduleID: "com.mirmir.app.ui",
        displayName: "Mirmir UI",
        versionString: "1.0.0",
        entryPoint: "MirmirUIModule",
        kind: .ui
    )

    static let activationOrder: [MirmirModuleDescriptor] = [
        metalRendering,
        modelAssets,
        mediaPipeline,
        upscalerEngine,
        ui
    ]
}
