import Foundation
import Metal

struct DeterministicMetalBackend: UpscaleBackend {
    let descriptor: BackendDescriptor
    private let runtimeProvider: ASHP06RuntimeProviderV4

    init?(
        descriptor: BackendDescriptor,
        runtimeProvider: ASHP06RuntimeProviderV4 = .production()
    ) {
        guard descriptor.id == .mirmirDeterministicMetal else { return nil }
        self.descriptor = descriptor
        self.runtimeProvider = runtimeProvider
    }

    func availability(
        for source: VideoInfo,
        targetSize: CGSize,
        environment _: RuntimeEnvironment
    ) async -> BackendAvailability {
        switch validatedConfiguration(source: source, targetSize: targetSize) {
        case .failure(let reason):
            return .unavailable(reason: reason)
        case .success:
            break
        }
        guard let device = MTLCreateSystemDefaultDevice() else {
            return .unavailable(reason: .noMetalDevice)
        }
        do {
            let runtime = try runtimeProvider.load()
            let library = try ASHP06MetalLibraryFactoryV4.makeLibrary(
                runtime: runtime,
                device: device
            )
            guard library.makeFunction(name: "ashFixedPointScaleV4") != nil else {
                return .unavailable(reason: .sdkAdapterNotCompiled(
                    requiredSymbol: "ashFixedPointScaleV4"
                ))
            }
            return .available
        } catch {
            return .unavailable(reason: .deterministicAssetsIncomplete(
                details: "P06 Metal verification failed: \(error)"
            ))
        }
    }

    func prepare(
        request: BackendPreparationRequest,
        environment _: RuntimeEnvironment
    ) async throws -> any PreparedFrameUpscaler {
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
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw BackendPreparationError.unavailable(
                descriptor.id,
                .noMetalDevice
            )
        }
        do {
            let runtime = try runtimeProvider.load()
            let library = try ASHP06MetalLibraryFactoryV4.makeLibrary(
                runtime: runtime,
                device: device
            )
            return try PreparedDeterministicV4Upscaler(
                configuration: configuration,
                runtime: runtime,
                metalDevice: device,
                metalLibrary: library
            )
        } catch {
            throw BackendPreparationError.unavailable(
                descriptor.id,
                .deterministicAssetsIncomplete(
                    details: "the release-qualified P06 Metal runtime could "
                        + "not be prepared: \(String(describing: error))"
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
            executionBackend: .metal
        )
    }
}
