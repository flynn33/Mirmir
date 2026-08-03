import Foundation

struct DeterministicConfiguration: Equatable, Sendable {
    let implementationVersion: String
    let scaleRoute: String
    let sourcePixelFormat: OSType
    let destinationPixelFormat: OSType
    let stateInputEnabled: Bool
    let mappingSchemaVersion: String
    let operatorBankSchemaVersion: String
    let runtimeManifestSHA256: String
    let fixedPointKernelID: String
    let temporalPolicyID: String
}

struct DeterministicCPUBackend: UpscaleBackend {
    let descriptor: BackendDescriptor
    private let runtimeProvider: ASHP06RuntimeProviderV4

    init?(
        descriptor: BackendDescriptor,
        runtimeProvider: ASHP06RuntimeProviderV4 = .production()
    ) {
        guard descriptor.id == .mirmirDeterministicCPU else { return nil }
        self.descriptor = descriptor
        self.runtimeProvider = runtimeProvider
    }

    func availability(
        for source: VideoInfo,
        targetSize: CGSize,
        environment _: RuntimeEnvironment
    ) async -> BackendAvailability {
        if source.color.alphaModel != .none {
            switch validatedAlphaConfiguration(
                source: source,
                targetSize: targetSize
            ) {
            case .failure(let reason):
                return .unavailable(reason: reason)
            case .success:
                do {
                    let runtime = try runtimeProvider.load()
                    _ = try runtime.measurementContract()
                    _ = try runtime.branchProgram()
                    return .available
                } catch {
                    return .unavailable(reason: .deterministicAssetsIncomplete(
                        details: "P06 verification failed: \(error)"
                    ))
                }
            }
        }
        switch validatedConfiguration(source: source, targetSize: targetSize) {
        case .failure(let reason):
            return .unavailable(reason: reason)
        case .success:
            do {
                let runtime = try runtimeProvider.load()
                _ = try runtime.measurementContract()
                _ = try runtime.branchProgram()
                return .available
            } catch {
                return .unavailable(reason: .deterministicAssetsIncomplete(
                    details: "P06 verification failed: \(error)"
                ))
            }
        }
    }

    func prepare(
        request: BackendPreparationRequest,
        environment _: RuntimeEnvironment
    ) async throws -> any PreparedFrameUpscaler {
        if request.source.color.alphaModel != .none {
            let configuration: DeterministicAlphaPreparedConfigurationV4
            switch validatedAlphaConfiguration(
                source: request.source,
                targetSize: request.targetSize
            ) {
            case .success(let value): configuration = value
            case .failure(let reason):
                throw BackendPreparationError.unavailable(descriptor.id, reason)
            }
            do {
                return try PreparedDeterministicAlphaPlanningBackendV4(
                    configuration: configuration,
                    runtime: runtimeProvider.load()
                )
            } catch {
                throw BackendPreparationError.unavailable(
                    descriptor.id,
                    .deterministicAssetsIncomplete(
                        details: "the release-qualified P06 runtime could not be prepared: \(error)"
                    )
                )
            }
        }
        let configuration: DeterministicPreparedConfigurationV4
        switch validatedConfiguration(
            source: request.source,
            targetSize: request.targetSize
        ) {
        case .success(let value):
            configuration = value
        case .failure(let reason):
            throw BackendPreparationError.unavailable(descriptor.id, reason)
        }
        do {
            return try PreparedDeterministicV4Upscaler(
                configuration: configuration,
                runtime: runtimeProvider.load()
            )
        } catch {
            throw BackendPreparationError.unavailable(
                descriptor.id,
                .deterministicAssetsIncomplete(
                    details: "the release-qualified P06 runtime could not be "
                        + "prepared: \(String(describing: error))"
                )
            )
        }
    }

    private func validatedConfiguration(
        source: VideoInfo,
        targetSize: CGSize
    ) -> Result<DeterministicPreparedConfigurationV4, BackendUnavailableReason> {
        DeterministicConfigurationValidatorV4.validate(
            source: source,
            targetSize: targetSize,
            backendID: descriptor.id,
            executionBackend: .cpu
        )
    }

    private func validatedAlphaConfiguration(
        source: VideoInfo,
        targetSize: CGSize
    ) -> Result<DeterministicAlphaPreparedConfigurationV4,
        BackendUnavailableReason> {
        DeterministicAlphaConfigurationValidatorV4.validate(
            source: source,
            targetSize: targetSize,
            backendID: descriptor.id,
            executionBackend: .cpu
        )
    }
}
