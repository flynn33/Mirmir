enum BackendGroup: String, CaseIterable, Sendable {
    case mirmir = "Mirmir"
    case appleSuperResolution = "Apple Super Resolution"
    case smoothMotion = "Smooth Motion + Upscale"
    case appleGPUAndFilter = "Apple GPU and Filter Scaling"
    case appleCPUAndSystem = "Apple CPU and System Scaling"
    case automatic = "Automatic"
}

enum BackendOperationClass: String, Sendable {
    case selectionPolicy = "Selection policy"
    case deterministicReference = "Mirmir deterministic reference"
    case deterministicGPU = "Mirmir deterministic GPU"
    case machineLearningSuperResolution = "Machine-learning super resolution"
    case combinedTemporalSpatial = "Combined temporal and spatial effect"
    case gpuSpatialScaling = "GPU spatial scaling"
    case gpuResampling = "GPU resampling"
    case imageFilterResampling = "Image-filter resampling"
    case cpuResampling = "CPU resampling"
    case systemPixelTransfer = "System pixel transfer"
}

struct BackendDescriptor: Equatable, Sendable {
    let id: UpscaleBackendID
    let title: String
    let summary: String
    let group: BackendGroup
    let operationClass: BackendOperationClass
    let isAutomaticEligible: Bool

    static let all: [BackendDescriptor] = [
        BackendDescriptor(
            id: .mirmirDeterministicCPU,
            title: "Mirmir Deterministic — CPU Reference (Preview)",
            summary: "Mirmir's fixed custom reference pipeline. Explicit selection, supported routes and formats only, with no hidden fallback.",
            group: .mirmir,
            operationClass: .deterministicReference,
            isAutomaticEligible: false
        ),
        BackendDescriptor(
            id: .mirmirDeterministicMetal,
            title: "Mirmir Deterministic — Metal Accelerated (Preview)",
            summary: "Mirmir's existing Metal V3 engine using deterministic in-memory P05 development inputs. Explicit selection only; no release-lock claim or hidden fallback.",
            group: .mirmir,
            operationClass: .deterministicGPU,
            isAutomaticEligible: false
        ),
        BackendDescriptor(
            id: .videoToolboxSuperResolutionQuality,
            title: "VideoToolbox Super Resolution — Quality",
            summary: "Apple machine-learning super resolution for compatible video. It may require a system model download.",
            group: .appleSuperResolution,
            operationClass: .machineLearningSuperResolution,
            isAutomaticEligible: true
        ),
        BackendDescriptor(
            id: .videoToolboxSuperResolutionLowLatency,
            title: "VideoToolbox Super Resolution — Low Latency",
            summary: "Apple lightweight machine-learning super resolution optimized for low-latency processing.",
            group: .appleSuperResolution,
            operationClass: .machineLearningSuperResolution,
            isAutomaticEligible: true
        ),
        BackendDescriptor(
            id: .videoToolboxInterpolationWithSpatialScale,
            title: "VideoToolbox Smooth Motion + Spatial Upscale",
            summary: "Apple low-latency 2× frame interpolation combined with 2× spatial upscaling. The first reference uses a disclosed VideoToolbox pixel-transfer boundary scale; playback duration is unchanged.",
            group: .smoothMotion,
            operationClass: .combinedTemporalSpatial,
            isAutomaticEligible: false
        ),
        BackendDescriptor(
            id: .metalFXSpatial,
            title: "MetalFX Spatial",
            summary: "Apple GPU spatial texture upscaling with explicit video color conversion.",
            group: .appleGPUAndFilter,
            operationClass: .gpuSpatialScaling,
            isAutomaticEligible: true
        ),
        BackendDescriptor(
            id: .mpsLanczos,
            title: "MPS Lanczos",
            summary: "Apple GPU Lanczos resampling.",
            group: .appleGPUAndFilter,
            operationClass: .gpuResampling,
            isAutomaticEligible: true
        ),
        BackendDescriptor(
            id: .mpsBilinear,
            title: "MPS Bilinear",
            summary: "Apple GPU bilinear resampling.",
            group: .appleGPUAndFilter,
            operationClass: .gpuResampling,
            isAutomaticEligible: false
        ),
        BackendDescriptor(
            id: .coreImageLanczos,
            title: "Core Image Lanczos",
            summary: "Apple Core Image Lanczos filter resampling.",
            group: .appleGPUAndFilter,
            operationClass: .imageFilterResampling,
            isAutomaticEligible: true
        ),
        BackendDescriptor(
            id: .coreImageBicubic,
            title: "Core Image Bicubic",
            summary: "Apple Core Image bicubic filter resampling.",
            group: .appleGPUAndFilter,
            operationClass: .imageFilterResampling,
            isAutomaticEligible: false
        ),
        BackendDescriptor(
            id: .vImageHighQuality,
            title: "Accelerate/vImage High Quality",
            summary: "Apple Accelerate CPU resampling with the high-quality resampling flag.",
            group: .appleCPUAndSystem,
            operationClass: .cpuResampling,
            isAutomaticEligible: true
        ),
        BackendDescriptor(
            id: .vImageStandard,
            title: "Accelerate/vImage Standard",
            summary: "Apple Accelerate CPU resampling without the high-quality resampling flag.",
            group: .appleCPUAndSystem,
            operationClass: .cpuResampling,
            isAutomaticEligible: false
        ),
        BackendDescriptor(
            id: .videoToolboxPixelTransfer,
            title: "VideoToolbox Pixel Transfer",
            summary: "Apple VideoToolbox pixel conversion and scaling.",
            group: .appleCPUAndSystem,
            operationClass: .systemPixelTransfer,
            isAutomaticEligible: true
        ),
        BackendDescriptor(
            id: .automatic,
            title: "Automatic",
            summary: "Mirmir's fixed, transparent policy for selecting an available spatial backend.",
            group: .automatic,
            operationClass: .selectionPolicy,
            isAutomaticEligible: false
        )
    ]

    static let concrete: [BackendDescriptor] = all.filter(\.id.isConcreteBackend)

    static func descriptor(for id: UpscaleBackendID) -> BackendDescriptor? {
        all.first { $0.id == id }
    }
}
