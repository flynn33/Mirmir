struct AutomaticBackendSelector: Sendable {
    static let orderedBackendIDs: [UpscaleBackendID] = [
        .videoToolboxSuperResolutionQuality,
        .videoToolboxSuperResolutionLowLatency,
        .metalFXSpatial,
        .mpsLanczos,
        .coreImageLanczos,
        .vImageHighQuality,
        .videoToolboxPixelTransfer
    ]

    func proposedBackend(
        from availabilityByID: [UpscaleBackendID: BackendAvailability],
        requiresDeterministicAlpha: Bool = false
    ) -> UpscaleBackendID? {
        let ordered = requiresDeterministicAlpha
            ? [
                UpscaleBackendID.mirmirDeterministicMetal,
                .mirmirDeterministicCPU
            ]
            : Self.orderedBackendIDs
        return ordered.first {
            availabilityByID[$0] == .available
        }
    }
}
