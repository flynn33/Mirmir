enum UpscaleBackendID: String, Codable, CaseIterable, Sendable {
    case automatic
    case mirmirDeterministicCPU
    case mirmirDeterministicMetal
    case videoToolboxSuperResolutionQuality
    case videoToolboxSuperResolutionLowLatency
    case videoToolboxInterpolationWithSpatialScale
    case metalFXSpatial
    case mpsLanczos
    case mpsBilinear
    case coreImageLanczos
    case coreImageBicubic
    case vImageHighQuality
    case vImageStandard
    case videoToolboxPixelTransfer

    var isConcreteBackend: Bool {
        self != .automatic
    }
}
