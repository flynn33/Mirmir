import CoreVideo
import Foundation
@preconcurrency import Metal
import os.lock

enum ASHMetalSpatialRuntimeErrorV3: Error, Equatable, Sendable {
    case configurationMismatch
    case defaultLibraryUnavailable
    case functionUnavailable(String)
    case pipelineCreationFailed(function: String, reason: String)
    case immutableBufferAllocationFailed(label: String, length: Int)
    case invalidPixelFormat(expected: OSType, observed: OSType)
    case invalidPlaneGeometry
    case routeGeometryMismatch
    case codeRangeMismatch
    case chromaSitingMismatch
    case arithmeticOverflow
    case textureCreationFailed(plane: Int, status: CVReturn)
    case textureUnavailable(plane: Int)
    case commandBufferCreationFailed(frameIndex: Int)
    case encoderCreationFailed(stage: String)
    case commandExecutionFailed(status: String, reason: String?)
    case fatalNumericalFault(count: UInt32)
}

/// The small, runtime-only input surface consumed by the Metal kernels.
/// Release-locked artifact loaders may adapt into this type, while the product
/// preview constructs it directly from the checked-in P05 development values.
struct ASHMetalRuntimeMappingV3: Equatable, Sendable {
    let analyzerConfiguration: ASHVideoAnalyzerV2DevelopmentConfiguration
    let codeRange: ASHVideoCodeRange8Bit
    let chromaSiting: ASHChromaSitingV2
    let boundaryMode: ASHSpatialBoundaryModeV2
    let direct2xAnalysisGridSourceStep: UInt8
    let direct3Over2AnalysisGridSourceStep: UInt8

    func analysisGridSourceStep(for route: ASHSpatialRouteV2) -> UInt8 {
        switch route {
        case .direct2x: direct2xAnalysisGridSourceStep
        case .direct3Over2: direct3Over2AnalysisGridSourceStep
        }
    }
}

struct ASHMetalRuntimeOperatorParametersV3: Equatable, Sendable {
    let minimumAnisotropicMagnitudeUNorm15: UInt16
    let minimumAnisotropicCoherenceUNorm15: UInt16
    let detailGainQ12: UInt16
    let relaxedLimiterAlphaQ12: UInt16
    let riskSuppressionUNorm15: UInt16
    let lowPassRadiusQ8x8: UInt16
    let weightEpsilonF32Bits: UInt32

    init(_ locked: ASHLUTLockedOperatorParametersV3) {
        minimumAnisotropicMagnitudeUNorm15 =
            locked.minimumAnisotropicMagnitudeUNorm15
        minimumAnisotropicCoherenceUNorm15 =
            locked.minimumAnisotropicCoherenceUNorm15
        detailGainQ12 = locked.detailGainQ12
        relaxedLimiterAlphaQ12 = locked.relaxedLimiterAlphaQ12
        riskSuppressionUNorm15 = locked.riskSuppressionUNorm15
        lowPassRadiusQ8x8 = locked.lowPassRadiusQ8x8
        weightEpsilonF32Bits = locked.weightEpsilonF32Bits
    }

    init(
        minimumAnisotropicMagnitudeUNorm15: UInt16,
        minimumAnisotropicCoherenceUNorm15: UInt16,
        detailGainQ12: UInt16,
        relaxedLimiterAlphaQ12: UInt16,
        riskSuppressionUNorm15: UInt16,
        lowPassRadiusQ8x8: UInt16,
        weightEpsilonF32Bits: UInt32
    ) {
        self.minimumAnisotropicMagnitudeUNorm15 =
            minimumAnisotropicMagnitudeUNorm15
        self.minimumAnisotropicCoherenceUNorm15 =
            minimumAnisotropicCoherenceUNorm15
        self.detailGainQ12 = detailGainQ12
        self.relaxedLimiterAlphaQ12 = relaxedLimiterAlphaQ12
        self.riskSuppressionUNorm15 = riskSuppressionUNorm15
        self.lowPassRadiusQ8x8 = lowPassRadiusQ8x8
        self.weightEpsilonF32Bits = weightEpsilonF32Bits
    }
}

struct ASHMetalRuntimeRouteSelectionV3: Equatable, Sendable {
    /// Nil means the development source has no release policy identifier.
    let spatialPolicyID: UInt8?
    let lumaAnisotropyMode: ASHLUTAnisotropyModeV3
    let chromaAnisotropyMode: ASHLUTAnisotropyModeV3
    let lumaCoordinatePolicy: ASHSpatialCoordinatePolicyV2
    let chromaCoordinatePolicy: ASHSpatialCoordinatePolicyV2
    let analysisGridSourceStep: UInt8

    func anisotropyMode(
        for planeRole: ASHLUTPlaneRoleV3
    ) -> ASHLUTAnisotropyModeV3 {
        switch planeRole {
        case .luma: lumaAnisotropyMode
        case .chroma: chromaAnisotropyMode
        }
    }
}

struct ASHMetalRuntimeConfigurationV3: Equatable, Sendable {
    let boundaryMode: ASHSpatialBoundaryModeV2
    let operatorParameters: ASHMetalRuntimeOperatorParametersV3
    let direct2x: ASHMetalRuntimeRouteSelectionV3
    let direct3Over2: ASHMetalRuntimeRouteSelectionV3

    func routeSelection(
        for route: ASHSpatialRouteV2
    ) -> ASHMetalRuntimeRouteSelectionV3 {
        switch route {
        case .direct2x: direct2x
        case .direct3Over2: direct3Over2
        }
    }
}

extension ASHLUTLockedConfigurationV3 {
    var metalRuntimeConfigurationV3: ASHMetalRuntimeConfigurationV3 {
        func selection(
            _ locked: ASHLUTLockedRouteSelectionV3
        ) -> ASHMetalRuntimeRouteSelectionV3 {
            ASHMetalRuntimeRouteSelectionV3(
                spatialPolicyID: locked.spatialPolicyID,
                lumaAnisotropyMode: locked.lumaAnisotropyMode,
                chromaAnisotropyMode: locked.chromaAnisotropyMode,
                lumaCoordinatePolicy: locked.lumaCoordinatePolicy,
                chromaCoordinatePolicy: locked.chromaCoordinatePolicy,
                analysisGridSourceStep: locked.analysisGridSourceStep
            )
        }
        return ASHMetalRuntimeConfigurationV3(
            boundaryMode: boundaryMode,
            operatorParameters: ASHMetalRuntimeOperatorParametersV3(
                operatorParameters
            ),
            direct2x: selection(routes.direct2x),
            direct3Over2: selection(routes.direct3Over2)
        )
    }
}

/// Immutable bytes and dimensions needed by the GPU. This deliberately does
/// not imply that the bytes came from a release-lock package.
struct ASHMetalRuntimeLUTV3: Equatable, Sendable {
    let route: ASHSpatialRouteV2
    let configuration: ASHMetalRuntimeConfigurationV3
    let immutableBytes: Data
    let parameterCount: Int
    let runtimeTreeGenerationCount: Int

    init(
        route: ASHSpatialRouteV2,
        configuration: ASHMetalRuntimeConfigurationV3,
        immutableBytes: Data,
        parameterCount: Int,
        runtimeTreeGenerationCount: Int = 0
    ) throws {
        guard immutableBytes.count >= ASHLUTBinaryContractV3.headerSize,
              parameterCount > 0,
              ASHLUTLittleEndianV3.uint16(immutableBytes, at: 16)
                == ASHLUTBinaryContractV3.routeID(route),
              ASHLUTLittleEndianV3.uint32(immutableBytes, at: 36)
                == UInt32(parameterCount),
              ASHLUTLittleEndianV3.uint32(immutableBytes, at: 296)
                == UInt32(immutableBytes.count) else {
            throw ASHMetalSpatialRuntimeErrorV3.configurationMismatch
        }
        self.route = route
        self.configuration = configuration
        self.immutableBytes = immutableBytes
        self.parameterCount = parameterCount
        self.runtimeTreeGenerationCount = runtimeTreeGenerationCount
    }

    init(_ loaded: ASHLUTLoadedV3) throws {
        try self.init(
            route: loaded.route,
            configuration: loaded.configuration.metalRuntimeConfigurationV3,
            immutableBytes: loaded.immutableBytes,
            parameterCount: loaded.parameters.count,
            runtimeTreeGenerationCount: loaded.runtimeTreeGenerationCount
        )
    }
}

struct ASHMetalStateSampleABIV3: Equatable, Sendable {
    var state: UInt16 = 0
    var flags: UInt16 = 0
    var orientationQ15: Int16 = 0
    var magnitudeQ15: UInt16 = 0
    var coherenceQ15: UInt16 = 0
    var textureQ15: UInt16 = 0
    var riskQ15: UInt16 = 0
    var temporalConfidenceQ15: UInt16 = 0
    var chromaAlignmentQ15: UInt16 = 0
    var localMinimum: UInt16 = 0
    var localMaximum: UInt16 = 0
    var motionXQ8x8: Int16 = 0
    var motionYQ8x8: Int16 = 0
    var reserved0: UInt16 = 0
    var reserved1: UInt32 = 0
}

struct ASHMetalDispatchABIV3: Equatable, Sendable {
    var primaryAffineState: UInt16 = 0
    var secondaryAffineState: UInt16 = 0
    var primaryDescriptor: UInt8 = 0
    var secondaryDescriptor: UInt8 = 0
    var primaryMessage: UInt8 = 0
    var secondaryMessage: UInt8 = 0
    var primaryWeightQ16: UInt16 = 0
    var secondaryWeightQ16: UInt16 = 0
    var marginQ16: UInt16 = 0
    var flags: UInt16 = 0
    var parameterIndex: UInt32 = 0
    var provenanceCRC32: UInt32 = 0
}

struct ASHMetalRuntimeConstructionCountersV3: Equatable, Sendable {
    let pipelineCreationCount: Int
    let immutableLUTBufferCreationCount: Int
    let immutableDecoderBufferCreationCount: Int
    let textureCacheCreationCount: Int
    let runtimeTreeGenerationCount: Int
    let runtimeJSONLoadCount: Int
}

enum ASHMetalCommandCompletionModeV3: String, Equatable, Sendable {
    case asynchronousCompletionHandler = "asynchronous_completion_handler"
    case unverified = "unverified"
}

struct ASHMetalRuntimeDiagnosticsV3: Equatable, Sendable {
    let ring: ASHMetalFrameResourceRingSnapshotV3
    let commandCompletionMode: ASHMetalCommandCompletionModeV3
    let submissionCount: UInt64
    let completionCount: UInt64
    let failureCount: UInt64
    let currentGPUFrameCount: Int
    let peakGPUFrameCount: Int
}

struct ASHMetalFrameSummaryV3: Equatable, Sendable {
    let stateHistogram: [UInt32]
    let messageHistogram: [UInt32]
    let operatorHistogram: [UInt32]
    let exactDecodeCount: UInt32
    let correctedDecodeCount: UInt32
    let rejectedDecodeCount: UInt32
    let oneCandidateDispatchCount: UInt32
    let twoCandidateDispatchCount: UInt32
    let dispatchCount: UInt32
    let actualOperatorInvocationCount: UInt32
    let actualLumaOperatorInvocationCount: UInt32
    let actualChromaOperatorInvocationCount: UInt32
    let numericalFallbackCount: UInt32
    let lumaNumericalFallbackCount: UInt32
    let chromaNumericalFallbackCount: UInt32
    let affineFallbackCount: UInt32
    let parityRecomputationCount: UInt32
    let sourceAlignedPreservationCount: UInt32
    let lumaOutputCount: UInt32
    let chromaOutputCount: UInt32
    let fatalFaultCount: UInt32
    let analysisCellCount: UInt32
}

struct ASHMetalFrameContextV3: Equatable, Sendable {
    let frameIndex: Int
    let presentationTimestampValue: Int64?
    let presentationTimestampTimescale: Int32?

    init(
        frameIndex: Int,
        presentationTimestampValue: Int64? = nil,
        presentationTimestampTimescale: Int32? = nil
    ) {
        self.frameIndex = frameIndex
        self.presentationTimestampValue = presentationTimestampValue
        self.presentationTimestampTimescale = presentationTimestampTimescale
    }
}

final class ASHMetalCompletedFrameV3: ASHUpscaleFrameCompletion, @unchecked Sendable {
    let summary: ASHMetalFrameSummaryV3
    let gpuElapsedSeconds: Double?

    private struct State {
        var lease: ASHMetalFrameResourceLeaseV3?
    }

    private let ring: ASHMetalFrameResourceRingV3
    private let telemetry: any ASHTelemetryRecording
    private let state: OSAllocatedUnfairLock<State>
    private let stateSamples: MTLBuffer
    private let analysisCellCount: Int

    init(
        summary: ASHMetalFrameSummaryV3,
        ring: ASHMetalFrameResourceRingV3,
        lease: ASHMetalFrameResourceLeaseV3,
        stateSamples: MTLBuffer,
        analysisCellCount: Int,
        telemetry: any ASHTelemetryRecording,
        gpuElapsedSeconds: Double?
    ) {
        self.summary = summary
        self.gpuElapsedSeconds = gpuElapsedSeconds
        self.ring = ring
        self.telemetry = telemetry
        self.state = OSAllocatedUnfairLock(initialState: State(lease: lease))
        self.stateSamples = stateSamples
        self.analysisCellCount = analysisCellCount
    }

    /// Test-only parity access to the GPU analysis-grid state words. The
    /// production call graph consumes only the fixed-size reduction buffer.
    func developmentParityStateValues() -> [UInt16] {
        telemetry.increment(.fullFrameGPUReadbacks)
        let bytes = stateSamples.contents().bindMemory(
            to: UInt8.self,
            capacity: analysisCellCount * 32
        )
        return (0..<analysisCellCount).map { index in
            let offset = index * 32
            return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
        }
    }

    func finishAfterAppend() {
        let lease = state.withLock { state -> ASHMetalFrameResourceLeaseV3? in
            defer { state.lease = nil }
            return state.lease
        }
        if let lease {
            ring.release(lease)
        }
    }

    deinit {
        finishAfterAppend()
    }
}

struct ASHMetalTexturePlaneV3: @unchecked Sendable {
    let reference: CVMetalTexture
    let texture: MTLTexture
}

protocol ASHMetalTextureCreatingV3: Sendable {
    func makeTexture(
        cache: CVMetalTextureCache,
        pixelBuffer: CVPixelBuffer,
        pixelFormat: MTLPixelFormat,
        width: Int,
        height: Int,
        plane: Int,
        usage: MTLTextureUsage
    ) throws -> ASHMetalTexturePlaneV3
}

struct ASHDefaultMetalTextureCreatorV3: ASHMetalTextureCreatingV3 {
    func makeTexture(
        cache: CVMetalTextureCache,
        pixelBuffer: CVPixelBuffer,
        pixelFormat: MTLPixelFormat,
        width: Int,
        height: Int,
        plane: Int,
        usage: MTLTextureUsage
    ) throws -> ASHMetalTexturePlaneV3 {
        var reference: CVMetalTexture?
        let attributes = [
            kCVMetalTextureUsage: NSNumber(value: usage.rawValue)
        ] as CFDictionary
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            pixelBuffer,
            attributes,
            pixelFormat,
            width,
            height,
            plane,
            &reference
        )
        guard status == kCVReturnSuccess, let reference else {
            throw ASHMetalSpatialRuntimeErrorV3.textureCreationFailed(
                plane: plane,
                status: status
            )
        }
        guard let texture = CVMetalTextureGetTexture(reference) else {
            throw ASHMetalSpatialRuntimeErrorV3.textureUnavailable(plane: plane)
        }
        return ASHMetalTexturePlaneV3(reference: reference, texture: texture)
    }
}

protocol ASHMetalCommandCompletingV3: Sendable {
    var completionMode: ASHMetalCommandCompletionModeV3 { get }

    func commitAndComplete(
        _ submission: any MetalCommandBufferSubmitting,
        retaining resources: MetalCommandBufferRetainedResources
    ) async throws -> MetalCommandBufferCompletion
}

extension ASHMetalCommandCompletingV3 {
    var completionMode: ASHMetalCommandCompletionModeV3 { .unverified }
}

struct ASHDefaultMetalCommandCompleterV3: ASHMetalCommandCompletingV3 {
    private let bridge = MetalCommandBufferCompletionBridge()
    let completionMode = ASHMetalCommandCompletionModeV3.asynchronousCompletionHandler

    func commitAndComplete(
        _ submission: any MetalCommandBufferSubmitting,
        retaining resources: MetalCommandBufferRetainedResources
    ) async throws -> MetalCommandBufferCompletion {
        try await bridge.commitAndWait(submission, retaining: resources)
    }
}
