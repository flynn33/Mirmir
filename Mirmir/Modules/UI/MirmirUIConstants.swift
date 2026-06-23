import Foundation
import ForsettiCore

enum MirmirUIConstants {
    static let moduleID = "com.mirmir.app.ui"
    static let displayName = "Mirmir UI"
    static let entryPoint = "MirmirUIModule"
    static let primaryViewID = "com.mirmir.app.ui.workspace-root"
    static let primarySlot = "module.workspace"
    static let moduleVersion = SemVer(major: 1, minor: 0, patch: 0)
}

enum MirmirMetalConstants {
    static let moduleID = "com.mirmir.app.metal"
    static let displayName = "Metal Rendering"
    static let entryPoint = "MetalRenderingServiceModule"
    static let moduleVersion = SemVer(major: 1, minor: 0, patch: 0)
}

enum MirmirModelAssetsConstants {
    static let moduleID = "com.mirmir.app.model-assets"
    static let displayName = "Model Assets"
    static let entryPoint = "ModelAssetsServiceModule"
    static let moduleVersion = SemVer(major: 1, minor: 0, patch: 0)
}

enum MirmirMediaPipelineConstants {
    static let moduleID = "com.mirmir.app.media-pipeline"
    static let displayName = "Media Pipeline"
    static let entryPoint = "MediaPipelineServiceModule"
    static let moduleVersion = SemVer(major: 1, minor: 0, patch: 0)
}

enum MirmirUpscalerEngineConstants {
    static let moduleID = "com.mirmir.app.upscaler-engine"
    static let displayName = "Upscaler Engine"
    static let entryPoint = "UpscalerEngineServiceModule"
    static let moduleVersion = SemVer(major: 1, minor: 0, patch: 0)
}

enum MirmirForsettiConstants {
    static let minForsettiVersion = SemVer(major: 0, minor: 1, patch: 4)
    static let manifestSubdirectory = "ForsettiManifests"
    static let allowedCapabilities: Set<Capability> = [
        .viewInjection,
        .storage,
        .telemetry,
        .fileExport
    ]
    static let allModuleIDs: Set<String> = [
        MirmirUIConstants.moduleID,
        MirmirMetalConstants.moduleID,
        MirmirModelAssetsConstants.moduleID,
        MirmirMediaPipelineConstants.moduleID,
        MirmirUpscalerEngineConstants.moduleID
    ]
}
