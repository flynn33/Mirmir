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
        from availabilityByID: [UpscaleBackendID: BackendAvailability]
    ) -> UpscaleBackendID? {
        Self.orderedBackendIDs.first {
            availabilityByID[$0] == .available
        }
    }
}
