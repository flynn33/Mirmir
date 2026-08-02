import CoreMedia
import CoreVideo
import Foundation
import Metal

struct DeterministicMetalBackend: UpscaleBackend {
    private static let requiredMetalFunctions = [
        "ash_v3_analyze_luma",
        "ash_v3_analyze_chroma_and_pack_state",
        "ash_v3_decode_dispatch",
        "ash_v3_reconstruct_luma",
        "ash_v3_reconstruct_chroma",
        "ash_v3_finalize_reduction"
    ]

    let descriptor: BackendDescriptor

    init?(descriptor: BackendDescriptor) {
        guard descriptor.id == .mirmirDeterministicMetal else { return nil }
        self.descriptor = descriptor
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
        guard let library = MirmirDefaultMetalLibrary.make(on: device) else {
            return .unavailable(reason: .appleAPIUnsupported(
                details: "the app's default Metal library could not be loaded"
            ))
        }
        let missing = Self.requiredMetalFunctions.filter {
            library.makeFunction(name: $0) == nil
        }
        guard missing.isEmpty else {
            return .unavailable(reason: .sdkAdapterNotCompiled(
                requiredSymbol: missing.joined(separator: ", ")
            ))
        }
        return .available
    }

    func prepare(
        request: BackendPreparationRequest,
        environment _: RuntimeEnvironment
    ) async throws -> any PreparedFrameUpscaler {
        let prepared: DeterministicMetalPreparedConfiguration
        switch validatedConfiguration(
            source: request.source,
            targetSize: request.targetSize
        ) {
        case .success(let value):
            prepared = value
        case .failure(let reason):
            throw BackendPreparationError.unavailable(descriptor.id, reason)
        }
        do {
            let lut = try ASHMetalDevelopmentRuntimeFactoryV3.makeLUT(
                route: prepared.route
            )
            let metal = try DefaultMetalRenderingService()
            try metal.start()
            return PreparedDeterministicMetalUpscaler(
                configuration: prepared,
                lut: lut,
                metal: metal
            )
        } catch {
            throw BackendPreparationError.unavailable(
                descriptor.id,
                .appleAPIUnsupported(
                    details: "the deterministic Metal runtime could not be prepared: \(error)"
                )
            )
        }
    }

    private func validatedConfiguration(
        source: VideoInfo,
        targetSize: CGSize
    ) -> Result<DeterministicMetalPreparedConfiguration, BackendUnavailableReason> {
        if let fieldCount = source.color.fieldCount, fieldCount != 1 {
            return .failure(.unsupportedPixelFormatOrBitDepth(
                details: "Mirmir Deterministic Metal has no deinterlace stage; the source reports \(fieldCount) fields"
            ))
        }
        if source.color.fieldDetail != nil {
            return .failure(.unsupportedPixelFormatOrBitDepth(
                details: "Mirmir Deterministic Metal supports progressive video only; the source carries interlaced field detail"
            ))
        }
        let nv12: NV12ScalerConfiguration
        switch NV12ScalerConfiguration.validate(
            source: source,
            targetSize: targetSize,
            backendID: descriptor.id
        ) {
        case .valid(let value):
            nv12 = value
        case .unavailable(let reason):
            return .failure(reason)
        }
        guard let route = ASHSpatialRouteV2.allCases.first(where: { route in
            guard let width = try? route.destinationExtent(for: nv12.sourceWidth),
                  let height = try? route.destinationExtent(for: nv12.sourceHeight) else {
                return false
            }
            return width == nv12.targetWidth && height == nv12.targetHeight
        }) else {
            return .failure(.unsupportedScaleFactor(
                details: "the Metal preview exposes only exact 2× and 3:2 ASH routes"
            ))
        }
        return .success(DeterministicMetalPreparedConfiguration(
            nv12: nv12,
            route: route,
            publicConfiguration: DeterministicConfiguration(
                implementationVersion:
                    ASHMetalDevelopmentRuntimeFactoryV3.implementationVersion,
                scaleRoute: route.rawValue,
                sourcePixelFormat: nv12.pixelFormat,
                destinationPixelFormat: nv12.pixelFormat,
                stateInputEnabled: true,
                mappingSchemaVersion: ASHSpatialRuntimeConfigurationV2
                    .developmentP05.mappingSchemaVersion,
                operatorBankSchemaVersion: ASHSpatialRuntimeConfigurationV2
                    .developmentP05.operatorBankSchemaVersion
            )
        ))
    }
}

private struct DeterministicMetalPreparedConfiguration: Sendable {
    let nv12: NV12ScalerConfiguration
    let route: ASHSpatialRouteV2
    let publicConfiguration: DeterministicConfiguration
}

actor PreparedDeterministicMetalUpscaler: PreparedFrameUpscaler {
    nonisolated let sourcePixelBufferAttributes: PixelBufferAttributes
    nonisolated let destinationPixelBufferAttributes: PixelBufferAttributes
    nonisolated let actualBackendID = UpscaleBackendID.mirmirDeterministicMetal
    nonisolated let deterministicConfiguration: DeterministicConfiguration

    private let configuration: NV12ScalerConfiguration
    private let route: ASHSpatialRouteV2
    private let lut: ASHMetalRuntimeLUTV3
    private let metal: DefaultMetalRenderingService
    private var runtime: ASHMetalSpatialRuntimeV3?
    private var runtimeCodeRange: ASHVideoCodeRange8Bit?
    private var runtimeChromaSiting: ASHChromaSitingV2?
    private var lastFrameSummary: ASHMetalFrameSummaryV3?
    private var finished = false

    fileprivate init(
        configuration prepared: DeterministicMetalPreparedConfiguration,
        lut: ASHMetalRuntimeLUTV3,
        metal: DefaultMetalRenderingService
    ) {
        configuration = prepared.nv12
        route = prepared.route
        self.lut = lut
        self.metal = metal
        deterministicConfiguration = prepared.publicConfiguration
        sourcePixelBufferAttributes = prepared.nv12.attributes(
            width: prepared.nv12.sourceWidth,
            height: prepared.nv12.sourceHeight,
            metalCompatible: true
        )
        destinationPixelBufferAttributes = prepared.nv12.attributes(
            width: prepared.nv12.targetWidth,
            height: prepared.nv12.targetHeight,
            metalCompatible: true
        )
    }

    func process(
        source: FramePixelBuffer,
        destination: FramePixelBuffer,
        timing: FrameTiming
    ) async throws {
        let sourceBuffer = source.value
        let destinationBuffer = destination.value
        do {
            guard !finished else {
                throw configuration.processingError(
                    "the prepared deterministic Metal adapter is already finished",
                    frameIndex: timing.frameIndex
                )
            }
            try Task.checkCancellation()
            try configuration.validate(sourceBuffer, source: true)
            try configuration.validate(destinationBuffer, source: false)
            let codeRange = try ASHNV12FrameCodec.codeRange(for: sourceBuffer)
            let chromaSiting = try ASHNV12FrameCodec.chromaSiting(for: sourceBuffer)
            guard runtimeCodeRange == nil || runtimeCodeRange == codeRange,
                  runtimeChromaSiting == nil || runtimeChromaSiting == chromaSiting else {
                throw configuration.processingError(
                    "the decoded stream changed NV12 range or chroma siting after Metal preparation",
                    frameIndex: timing.frameIndex
                )
            }
            NV12FrameAttachments.copy(from: sourceBuffer, to: destinationBuffer)
            let activeRuntime: ASHMetalSpatialRuntimeV3
            if let runtime {
                activeRuntime = runtime
            } else {
                activeRuntime = try makeRuntime(
                    codeRange: codeRange,
                    chromaSiting: chromaSiting
                )
            }
            let completion = try await activeRuntime.process(
                source: sourceBuffer,
                into: destinationBuffer,
                context: ASHMetalFrameContextV3(
                    frameIndex: timing.frameIndex,
                    presentationTimestampValue: timing.presentationTime.value,
                    presentationTimestampTimescale: timing.presentationTime.timescale
                )
            )
            lastFrameSummary = completion.summary
            completion.finishAfterAppend()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as MirmirError {
            throw error
        } catch {
            throw configuration.processingError(
                "the ASH Metal V3 preview failed: \(String(describing: error))",
                frameIndex: timing.frameIndex
            )
        }
    }

    func finish() async throws {
        guard !finished else { return }
        try Task.checkCancellation()
        runtime = nil
        metal.stop()
        finished = true
    }

    /// Internal test evidence from the GPU reduction buffer. Product code does
    /// not read full-frame GPU state back to the CPU.
    func developmentLastFrameSummary() -> ASHMetalFrameSummaryV3? {
        lastFrameSummary
    }

    private func makeRuntime(
        codeRange: ASHVideoCodeRange8Bit,
        chromaSiting: ASHChromaSitingV2
    ) throws -> ASHMetalSpatialRuntimeV3 {
        let value = try ASHMetalDevelopmentRuntimeFactoryV3.makeRuntime(
            route: route,
            lut: lut,
            codeRange: codeRange,
            chromaSiting: chromaSiting,
            metal: metal
        )
        runtime = value
        runtimeCodeRange = codeRange
        runtimeChromaSiting = chromaSiting
        return value
    }
}
