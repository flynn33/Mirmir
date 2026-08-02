import Foundation

struct BackendAvailabilityEntry: Equatable, Sendable {
    let descriptor: BackendDescriptor
    let availability: BackendAvailability
}

struct BackendSelectionResolution: Equatable, Sendable {
    let requestedBackendID: UpscaleBackendID
    let actualBackendID: UpscaleBackendID?
    let availability: BackendAvailability
}

struct BackendCatalogSnapshot: Equatable, Sendable {
    let entries: [BackendAvailabilityEntry]
    let automaticProposal: UpscaleBackendID?

    func entry(for id: UpscaleBackendID) -> BackendAvailabilityEntry? {
        entries.first { $0.descriptor.id == id }
    }

    func resolution(
        for requestedBackendID: UpscaleBackendID
    ) -> BackendSelectionResolution {
        let availability = entry(for: requestedBackendID)?.availability
            ?? .unavailable(
                reason: .sdkAdapterNotCompiled(
                    requiredSymbol: requestedBackendID.rawValue
                )
            )
        if requestedBackendID == .automatic {
            return BackendSelectionResolution(
                requestedBackendID: .automatic,
                actualBackendID: automaticProposal,
                availability: availability
            )
        }
        return BackendSelectionResolution(
            requestedBackendID: requestedBackendID,
            actualBackendID: requestedBackendID,
            availability: availability
        )
    }
}

actor UpscaleBackendCatalog {
    private let backendsByID: [UpscaleBackendID: any UpscaleBackend]
    private let automaticSelector: AutomaticBackendSelector

    init(
        backends: [any UpscaleBackend],
        automaticSelector: AutomaticBackendSelector = AutomaticBackendSelector()
    ) {
        var mapped: [UpscaleBackendID: any UpscaleBackend] = [:]
        for backend in backends where backend.descriptor.id.isConcreteBackend {
            mapped[backend.descriptor.id] = backend
        }
        backendsByID = mapped
        self.automaticSelector = automaticSelector
    }

    static func live() -> UpscaleBackendCatalog {
        UpscaleBackendCatalog(
            backends: BackendDescriptor.concrete.map { descriptor in
                if let backend = VImageBackend(descriptor: descriptor) {
                    return backend as any UpscaleBackend
                }
                if let backend = MPSBackend(descriptor: descriptor) {
                    return backend as any UpscaleBackend
                }
                if let backend = CoreImageBackend(descriptor: descriptor) {
                    return backend as any UpscaleBackend
                }
                if let backend = VTPixelTransferBackend(descriptor: descriptor) {
                    return backend as any UpscaleBackend
                }
                if let backend = MetalFXBackend(descriptor: descriptor) {
                    return backend as any UpscaleBackend
                }
                if let backend = VTHighQualitySuperResolutionBackend(descriptor: descriptor) {
                    return backend as any UpscaleBackend
                }
                if let backend = VTLowLatencySuperResolutionBackend(descriptor: descriptor) {
                    return backend as any UpscaleBackend
                }
                if let backend = VTInterpolationSpatialBackend(descriptor: descriptor) {
                    return backend as any UpscaleBackend
                }
                if let backend = DeterministicCPUBackend(descriptor: descriptor) {
                    return backend as any UpscaleBackend
                }
                if let backend = DeterministicMetalBackend(descriptor: descriptor) {
                    return backend as any UpscaleBackend
                }
                return PlannedBackend(descriptor: descriptor)
                    as any UpscaleBackend
            }
        )
    }

    func availability(
        for backendID: UpscaleBackendID,
        source: VideoInfo,
        targetSize: CGSize,
        environment: RuntimeEnvironment
    ) async -> BackendAvailability {
        guard backendID.isConcreteBackend else {
            return .unavailable(reason: .noCompatibleAutomaticBackend)
        }
        guard let backend = backendsByID[backendID] else {
            return .unavailable(
                reason: .sdkAdapterNotCompiled(
                    requiredSymbol: backendID.rawValue
                )
            )
        }
        return await backend.availability(
            for: source,
            targetSize: targetSize,
            environment: environment
        )
    }

    func prepare(
        backendID: UpscaleBackendID,
        request: BackendPreparationRequest,
        environment: RuntimeEnvironment
    ) async throws -> any PreparedFrameUpscaler {
        guard backendID.isConcreteBackend,
              let backend = backendsByID[backendID] else {
            throw BackendPreparationError.unavailable(
                backendID,
                .sdkAdapterNotCompiled(requiredSymbol: backendID.rawValue)
            )
        }
        return try await backend.prepare(
            request: request,
            environment: environment
        )
    }

    func downloadModel(
        backendID: UpscaleBackendID,
        request: BackendPreparationRequest,
        environment: RuntimeEnvironment,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard let backend = backendsByID[backendID] as? any ModelDownloadableBackend else {
            throw BackendPreparationError.unavailable(
                backendID,
                .modelUnavailable(details: "this backend has no downloadable model action")
            )
        }
        try await backend.downloadModel(
            request: request,
            environment: environment,
            progress: progress
        )
    }

    func snapshot(
        for source: VideoInfo,
        targetSize: CGSize,
        environment: RuntimeEnvironment
    ) async -> BackendCatalogSnapshot {
        let backends = backendsByID
        let availabilityByID = await withTaskGroup(
            of: (UpscaleBackendID, BackendAvailability).self,
            returning: [UpscaleBackendID: BackendAvailability].self
        ) { group in
            for descriptor in BackendDescriptor.concrete {
                guard let backend = backends[descriptor.id] else {
                    continue
                }
                group.addTask {
                    let availability = await backend.availability(
                        for: source,
                        targetSize: targetSize,
                        environment: environment
                    )
                    return (descriptor.id, availability)
                }
            }

            var values: [UpscaleBackendID: BackendAvailability] = [:]
            for await (id, availability) in group {
                values[id] = availability
            }
            return values
        }

        let automaticProposal = automaticSelector.proposedBackend(
            from: availabilityByID
        )
        let automaticAvailability: BackendAvailability = automaticProposal == nil
            ? .unavailable(reason: .noCompatibleAutomaticBackend)
            : .available

        let entries = BackendDescriptor.all.map { descriptor in
            BackendAvailabilityEntry(
                descriptor: descriptor,
                availability: descriptor.id == .automatic
                    ? automaticAvailability
                    : availabilityByID[descriptor.id]
                        ?? .unavailable(
                            reason: .sdkAdapterNotCompiled(
                                requiredSymbol: descriptor.id.rawValue
                            )
                        )
            )
        }
        return BackendCatalogSnapshot(
            entries: entries,
            automaticProposal: automaticProposal
        )
    }
}

private struct PlannedBackend: UpscaleBackend {
    let descriptor: BackendDescriptor

    func availability(
        for source: VideoInfo,
        targetSize: CGSize,
        environment: RuntimeEnvironment
    ) async -> BackendAvailability {
        let nativeAvailability = await environment.capabilityProbe.availability(
            for: descriptor.id,
            source: source,
            targetSize: targetSize
        )
        switch nativeAvailability {
        case .unavailable:
            return nativeAvailability
        case .available, .modelDownloadRequired:
            return .unavailable(
                reason: .processingAdapterNotImplemented(
                    backendID: descriptor.id
                )
            )
        }
    }

    func prepare(
        request: BackendPreparationRequest,
        environment: RuntimeEnvironment
    ) async throws -> any PreparedFrameUpscaler {
        throw BackendPreparationError.unavailable(
            descriptor.id,
            .processingAdapterNotImplemented(backendID: descriptor.id)
        )
    }
}
