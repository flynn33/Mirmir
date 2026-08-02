import CoreMedia
import CoreVideo
import Foundation

struct DeterministicConfiguration: Equatable, Sendable {
    let implementationVersion: String
    let scaleRoute: String
    let sourcePixelFormat: OSType
    let destinationPixelFormat: OSType
    let stateInputEnabled: Bool
    let mappingSchemaVersion: String
    let operatorBankSchemaVersion: String
}

struct DeterministicCPUBackend: UpscaleBackend {
    let descriptor: BackendDescriptor

    init?(descriptor: BackendDescriptor) {
        guard descriptor.id == .mirmirDeterministicCPU else { return nil }
        self.descriptor = descriptor
    }

    func availability(
        for source: VideoInfo,
        targetSize: CGSize,
        environment _: RuntimeEnvironment
    ) async -> BackendAvailability {
        switch validatedConfiguration(source: source, targetSize: targetSize) {
        case .success:
            return .available
        case .failure(let reason):
            return .unavailable(reason: reason)
        }
    }

    func prepare(
        request: BackendPreparationRequest,
        environment _: RuntimeEnvironment
    ) async throws -> any PreparedFrameUpscaler {
        switch validatedConfiguration(
            source: request.source,
            targetSize: request.targetSize
        ) {
        case .success(let prepared):
            return PreparedDeterministicCPUUpscaler(configuration: prepared)
        case .failure(let reason):
            throw BackendPreparationError.unavailable(descriptor.id, reason)
        }
    }

    private func validatedConfiguration(
        source: VideoInfo,
        targetSize: CGSize
    ) -> Result<DeterministicPreparedConfiguration, BackendUnavailableReason> {
        if let fieldCount = source.color.fieldCount, fieldCount != 1 {
            return .failure(.unsupportedPixelFormatOrBitDepth(
                details: "Mirmir Deterministic has no deinterlace stage; the source reports \(fieldCount) fields"
            ))
        }
        if source.color.fieldDetail != nil {
            return .failure(.unsupportedPixelFormatOrBitDepth(
                details: "Mirmir Deterministic supports progressive video only; the source carries interlaced field detail"
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
            guard let expectedWidth = try? route.destinationExtent(for: nv12.sourceWidth),
                  let expectedHeight = try? route.destinationExtent(for: nv12.sourceHeight) else {
                return false
            }
            return expectedWidth == nv12.targetWidth && expectedHeight == nv12.targetHeight
        }) else {
            return .failure(.unsupportedScaleFactor(
                details: "the CPU reference exposes only exact 2× and 3:2 ASH routes"
            ))
        }

        return .success(DeterministicPreparedConfiguration(
            nv12: nv12,
            route: route,
            publicConfiguration: DeterministicConfiguration(
                implementationVersion: "ash-p05-cpu-reference-preview",
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

private struct DeterministicPreparedConfiguration: Sendable {
    let nv12: NV12ScalerConfiguration
    let route: ASHSpatialRouteV2
    let publicConfiguration: DeterministicConfiguration
}

final class PreparedDeterministicCPUUpscaler: PreparedFrameUpscaler, @unchecked Sendable {
    let sourcePixelBufferAttributes: PixelBufferAttributes
    let destinationPixelBufferAttributes: PixelBufferAttributes
    let actualBackendID = UpscaleBackendID.mirmirDeterministicCPU
    let deterministicConfiguration: DeterministicConfiguration

    private let configuration: NV12ScalerConfiguration
    private let engine: ASHDeterministicUpscaleBackend

    fileprivate init(configuration prepared: DeterministicPreparedConfiguration) {
        configuration = prepared.nv12
        deterministicConfiguration = prepared.publicConfiguration
        sourcePixelBufferAttributes = prepared.nv12.attributes(
            width: prepared.nv12.sourceWidth,
            height: prepared.nv12.sourceHeight
        )
        destinationPixelBufferAttributes = prepared.nv12.attributes(
            width: prepared.nv12.targetWidth,
            height: prepared.nv12.targetHeight
        )
        engine = ASHDeterministicUpscaleBackend(
            route: prepared.route,
            runtimeConfiguration: .developmentP05,
            operatorParameters: .p05DevelopmentOnly,
            stateInputEnabled: true,
            telemetry: ASHNoopTelemetryRecorder.shared
        )
        engine.reset()
    }

    func process(
        source: FramePixelBuffer,
        destination: FramePixelBuffer,
        timing: FrameTiming
    ) async throws {
        let source = source.value
        let destination = destination.value
        try Task.checkCancellation()
        do {
            try configuration.validate(source, source: true)
            try configuration.validate(destination, source: false)
            try validateProgressiveChromaLocation(source)
            NV12FrameAttachments.copy(from: source, to: destination)
            let completion = try await engine.process(
                source: source,
                into: destination,
                context: ASHUpscaleFrameContext(
                    frameIndex: timing.frameIndex,
                    presentationTimestampValue: timing.presentationTime.value,
                    presentationTimestampTimescale: timing.presentationTime.timescale
                )
            )
            completion.finishAfterAppend()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw configuration.processingError(
                "the fixed ASH CPU reference failed: \(String(describing: error))",
                frameIndex: timing.frameIndex
            )
        }
    }

    func finish() async throws {
        try Task.checkCancellation()
    }

    private func validateProgressiveChromaLocation(_ buffer: CVPixelBuffer) throws {
        guard let rawLocation = CVBufferCopyAttachment(
            buffer,
            kCVImageBufferChromaLocationTopFieldKey,
            nil
        ) as? String else {
            throw configuration.processingError(
                "the source frame has no explicit progressive chroma location"
            )
        }
        let supported = [
            kCVImageBufferChromaLocation_Center,
            kCVImageBufferChromaLocation_Left,
            kCVImageBufferChromaLocation_TopLeft,
            kCVImageBufferChromaLocation_Top,
            kCVImageBufferChromaLocation_BottomLeft,
            kCVImageBufferChromaLocation_Bottom
        ].map { $0 as String }
        guard supported.contains(rawLocation) else {
            throw configuration.processingError(
                "the source chroma location \(rawLocation) is not represented by the ASH reference"
            )
        }
    }
}
