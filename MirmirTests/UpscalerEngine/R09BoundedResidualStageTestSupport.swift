import CoreMedia
import CoreVideo
@testable import Mirmir
struct R09StageFixture {
    let request: R09ResidualRequest
    let appleFrame: AppleUpscaleProcessedFrame
    let originalBytes: R09StagePixelBytes
}

struct R09StagePixelBytes: Equatable {
    let luma: [UInt8]
    let chroma: [UInt8]
}

private struct R09StageIdentityFixture {
    let identity: R09ResidualRequestIdentity
    let processingIdentity: AppleUpscaleProcessingIdentity
    let scaler: R09AppleScalerIdentity
    let authorization: R09ResidualAuthorizationIdentity
    let model: R09ResidualModelIdentity
}

actor R09StageSuspendingService: R09CoreAIResidualService {
    private let gate: R09ResidualTestGate
    private let disposition: R09ResidualDisposition

    init(gate: R09ResidualTestGate, disposition: R09ResidualDisposition) {
        self.gate = gate
        self.disposition = disposition
    }

    func predictResidual(for _: R09ResidualRequest) async -> R09ResidualDisposition {
        await gate.pause()
        return disposition
    }
}

private enum R09StageTestError: Error {
    case pixelBufferCreation(CVReturn)
    case pixelBufferLock(CVReturn)
    case unexpectedOutcome
}

enum R09StageTestSupport {}

extension R09StageTestSupport {
    static func fixture(
        protectedLumaIndices: Set<Int> = [],
        ashApprovalQ15: Int64 = R09MaskPlaneQ15.maximumSample,
        hallucinationRiskQ15: Int64 = 0,
        maximumAllowedHallucinationRiskQ15: Int64 = 16_384
    ) async throws -> R09StageFixture {
        let pixelBuffer = try preparedPixelBuffer()
        let current = try R09NV12PlanarCodec.decode(pixelBuffer)
        let reference = try offset(current, by: 1_028)
        let identities = try identityFixture()
        let approval = try mask(for: current, value: ashApprovalQ15)
        let protection = try protectedMask(
            for: current,
            lumaIndices: protectedLumaIndices
        )
        let sourceReference = try R09ResidualReferenceFrame(
            kind: .source,
            frameID: "r09.source.12",
            shotID: identities.identity.shotID,
            streamID: identities.identity.streamID,
            stateGeneration: identities.identity.stateGeneration,
            frameOrdinal: identities.identity.frameOrdinal,
            frame: reference
        )
        let temporalReference = try R09ResidualReferenceFrame(
            kind: .alignedTemporal,
            frameID: "r09.temporal.11",
            shotID: identities.identity.shotID,
            streamID: identities.identity.streamID,
            stateGeneration: identities.identity.stateGeneration,
            frameOrdinal: identities.identity.frameOrdinal - 1,
            frame: reference
        )
        let limits = try limits(for: current)
        let confidenceBudget = try R09ResidualConfidenceBudget(
            ashEligibilityQ15: 24_576,
            sourceReferenceQ15: 24_576,
            temporalReferenceQ15: 24_576,
            minimumRequiredQ15: 16_384
        )
        let resourceBudget = try R09ResidualResourceBudget(
            maximumWorkingSetBytes: 8_192,
            maximumElapsedMicroseconds: 2_000
        )
        let safetySignal = try R09ResidualSafetySignal(
            hallucinationRiskQ15: hallucinationRiskQ15,
            maximumAllowedHallucinationRiskQ15: maximumAllowedHallucinationRiskQ15
        )
        let authorizationInput = try await R09ResidualTestSupport.authorizationInput(
            R09ResidualAuthorizationFixture(
                identity: identities.identity,
                authorization: identities.authorization,
                scalerIdentity: identities.scaler,
                modelIdentity: identities.model,
                postScalerFrame: current,
                ashRequestedLumaMask: approval.luma,
                protectedLumaMask: protection.luma,
                limits: limits,
                sourceReference: sourceReference,
                temporalReference: temporalReference,
                confidenceBudget: confidenceBudget,
                resourceBudget: resourceBudget,
                safetySignal: safetySignal
            )
        )
        let outcome = R09ASHResidualAuthorizer.authorize(authorizationInput)
        guard case .authorized(let request) = outcome else {
            throw R09StageTestError.unexpectedOutcome
        }
        let processedFrame = try appleFrame(
            pixelBuffer: pixelBuffer,
            frameID: identities.identity.frameID,
            processingIdentity: identities.processingIdentity
        )
        return try R09StageFixture(
            request: request,
            appleFrame: processedFrame,
            originalBytes: activeBytes(pixelBuffer)
        )
    }

    private static func identityFixture() throws -> R09StageIdentityFixture {
        let identity = try R09ResidualRequestIdentity(
            frameID: "r09.frame.12",
            shotID: "r09.shot.1",
            streamID: "r09.stream.1",
            frameOrdinal: 12,
            stateGeneration: 3,
            ioContractSHA256: R09ResidualRequestIdentity.ioContractSHA256
        )
        let primaryProcessingIdentity = try processingIdentity()
        let scaler = try R09AppleScalerIdentity(
            backendID: R09BoundedResidualStage.deterministicPrimaryBackendID,
            implementationVersion: R09BoundedResidualStage.deterministicPrimaryBackendVersion,
            processingIdentity: primaryProcessingIdentity,
            outputFrameID: identity.frameID,
            kind: .metalPerformanceShaders,
            scaleNumerator: 2,
            scaleDenominator: 1,
            executionMode: .deterministicFixtureSimulation,
            nativeExecution: .notObserved
        )
        return try R09StageIdentityFixture(
            identity: identity,
            processingIdentity: primaryProcessingIdentity,
            scaler: scaler,
            authorization: R09ResidualAuthorizationIdentity(
                authorizationID: "operator.r09.functional-simulation.2026-07-22",
                referencedR08AcceptanceSHA256:
                    R09BoundedResidualStage.acceptedR08FunctionalAcceptanceSHA256,
                scope: .deterministicSimulationOnly,
                frameID: identity.frameID,
                shotID: identity.shotID,
                streamID: identity.streamID,
                stateGeneration: identity.stateGeneration,
                sourceReferenceFrameID: "r09.source.12",
                sourceReferenceFrameOrdinal: identity.frameOrdinal,
                temporalReferenceFrameID: "r09.temporal.11",
                temporalReferenceFrameOrdinal: identity.frameOrdinal - 1,
                primaryBackendID: scaler.backendID,
                primaryProcessingIdentity: scaler.processingIdentity
            ),
            model: R09ResidualModelIdentity(
                modelID: R09BoundedResidualStage.deterministicModelID,
                modelVersion: R09BoundedResidualStage.deterministicModelVersion,
                artifactKind: .deterministicSimulationContract,
                contentSHA256: R09ResidualModelIdentity.deterministicProviderSHA256,
                preprocessingIdentity:
                    R09ResidualModelIdentity.deterministicPreprocessingIdentity,
                postprocessingIdentity:
                    R09ResidualModelIdentity.deterministicPostprocessingIdentity,
                residualContractIdentity:
                    R09ResidualModelIdentity.deterministicResidualContractIdentity
            )
        )
    }
    static func output(
        request: R09ResidualRequest,
        luma: [Int64]
    ) throws -> R09ResidualOutput {
        let residual = try R09PlanarResidualQ16(
            planes: R09ResidualPlaneID.allCases.map { id in
                let plane = request.postScalerFrame[id]
                return try R09SignedResidualPlaneQ16(
                    id: id,
                    width: plane.width,
                    height: plane.height,
                    samplesQ16: id == .luma
                        ? luma
                        : [Int64](repeating: 0, count: plane.samplesQ16.count)
                )
            }
        )
        return try output(request: request, residual: residual)
    }

    static func output(
        request: R09ResidualRequest,
        residual: R09PlanarResidualQ16,
        confidenceQ15: Int64 = 24_576,
        workingSetBytes: Int64 = 4_096,
        elapsedMicroseconds: Int64 = 1_000,
        executionIdentity: R09ResidualExecutionIdentity = .deterministicSimulationV1
    ) throws -> R09ResidualOutput {
        try R09ResidualTestingOutputFactory.output(
            requestIdentity: request.identity,
            authorization: request.authorization,
            scalerIdentity: request.scalerIdentity,
            modelIdentity: request.modelIdentity,
            executionIdentity: executionIdentity,
            residual: residual,
            confidenceQ15: confidenceQ15,
            resourceMeasurement: try R09ResidualResourceMeasurement(
                workingSetBytes: workingSetBytes,
                elapsedMicroseconds: elapsedMicroseconds
            )
        )
    }

    static func bypassReason(
        output: R09ResidualOutput,
        fixture: R09StageFixture
    ) async throws -> R09ResidualApplicationBypassReason {
        try bypass(
            await R09BoundedResidualStage().process(
                request: fixture.request,
                appleOnlyFrame: fixture.appleFrame,
                service: R09StageFixedService(disposition: .produced(output))
            )
        ).reason
    }

    static func bypass(
        _ outcome: R09ResidualApplicationOutcome
    ) throws -> R09BypassedResidualFrame {
        guard case .bypassed(let bypass) = outcome else {
            throw R09StageTestError.unexpectedOutcome
        }
        return bypass
    }

    static func appleFrame(
        pixelBuffer: CVPixelBuffer,
        frameID: String,
        processingIdentity: AppleUpscaleProcessingIdentity
    ) throws -> AppleUpscaleProcessedFrame {
        try AppleUpscaleProcessedFrame(
            sequenceNumber: 12,
            pixelBuffer: pixelBuffer,
            presentationTimestamp: CMTime(value: 12, timescale: 24),
            duration: CMTime(value: 1, timescale: 24),
            colorDescription: AppleUpscaleColorDescription(
                colorPrimaries: "ITU_R_709_2",
                transferFunction: "ITU_R_709_2",
                matrix: "ITU_R_709_2",
                chromaSiting: "left",
                range: .video
            ),
            metadataIdentity: AppleUpscaleMetadataIdentity(frameID),
            resourceLifetimeToken: AppleUpscaleResourceLifetimeToken(
                identity: "r09.stage.\(frameID)",
                releaseAction: {}
            ),
            processingIdentity: processingIdentity
        )
    }

    static func activeBytes(_ pixelBuffer: CVPixelBuffer) throws -> R09StagePixelBytes {
        let status = CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        guard status == kCVReturnSuccess else {
            throw R09StageTestError.pixelBufferLock(status)
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        return try R09StagePixelBytes(
            luma: readPlane(pixelBuffer, plane: 0),
            chroma: readPlane(pixelBuffer, plane: 1)
        )
    }
}

extension R09StageTestSupport {
    static func preparedPixelBuffer() throws -> CVPixelBuffer {
        let buffer = try pixelBuffer()
        try write(
            buffer,
            bytes: R09StagePixelBytes(
                luma: [UInt8](repeating: 120, count: 16),
                chroma: Array(repeating: [UInt8(126), UInt8(130)], count: 4)
                    .flatMap { $0 }
            )
        )
        CVBufferSetAttachment(
            buffer,
            kCVImageBufferColorPrimariesKey,
            kCVImageBufferColorPrimaries_ITU_R_709_2,
            .shouldPropagate
        )
        return buffer
    }

    static func processingIdentity(
        configurationIdentity: String = "r09.fixture.configuration"
    ) throws -> AppleUpscaleProcessingIdentity {
        try AppleUpscaleProcessingIdentity(
            route: AppleUpscaleRouteIdentity(
                backend: AppleUpscaleBackendIdentity(
                    backendID: R09BoundedResidualStage.deterministicPrimaryBackendID,
                    backendRevision:
                        R09BoundedResidualStage.deterministicPrimaryBackendVersion,
                    modelAssetsIdentity: .notRequired
                ),
                configurationIdentity: configurationIdentity,
                policyIdentity: "r09.fixture.policy",
                materialDecisionIdentity: "r09.fixture.decision"
            ),
            fallbackHistory: []
        )
    }

    static func mask(
        for frame: R09PlanarFrameQ16,
        value: Int64
    ) throws -> R09PlanarMaskQ15 {
        try R09PlanarMaskQ15(
            planes: frame.orderedPlanes.map { plane in
                try R09MaskPlaneQ15(
                    id: plane.id,
                    width: plane.width,
                    height: plane.height,
                    samplesQ15: [Int64](repeating: value, count: plane.samplesQ16.count)
                )
            }
        )
    }

    static func protectedMask(
        for frame: R09PlanarFrameQ16,
        lumaIndices: Set<Int>
    ) throws -> R09PlanarMaskQ15 {
        try R09PlanarMaskQ15(
            planes: frame.orderedPlanes.map { plane in
                try R09MaskPlaneQ15(
                    id: plane.id,
                    width: plane.width,
                    height: plane.height,
                    samplesQ15: plane.samplesQ16.indices.map { index in
                        plane.id == .luma && lumaIndices.contains(index)
                            ? R09MaskPlaneQ15.maximumSample
                            : 0
                    }
                )
            }
        )
    }

    static func limits(for frame: R09PlanarFrameQ16) throws -> R09ResidualLimits {
        R09ResidualLimits(
            perPlane: try R09PerPlaneResidualLimitsQ16(
                limits: R09ResidualPlaneID.allCases.map { id in
                    try R09PlaneResidualLimitQ16(id: id, maximumMagnitudeQ16: 1_028)
                }
            ),
            content: try R09ContentResidualLimitQ16(
                contentClass: .mixed,
                maximumMagnitudeQ16: 1_028
            ),
            edge: try R09PlanarEdgeLimitsQ16(
                planes: frame.orderedPlanes.map { plane in
                    try R09EdgeLimitPlaneQ16(
                        id: plane.id,
                        width: plane.width,
                        height: plane.height,
                        maximumMagnitudesQ16: [Int64](
                            repeating: 1_028,
                            count: plane.samplesQ16.count
                        )
                    )
                }
            ),
            consistency: try R09ConsistencyLimitsQ16(
                sourceMaximumMagnitudeQ16: 1_028,
                temporalMaximumMagnitudeQ16: 1_028
            )
        )
    }

    static func offset(
        _ frame: R09PlanarFrameQ16,
        by delta: Int64
    ) throws -> R09PlanarFrameQ16 {
        try R09PlanarFrameQ16(
            planes: frame.orderedPlanes.map { plane in
                try R09UnsignedPlaneQ16(
                    id: plane.id,
                    width: plane.width,
                    height: plane.height,
                    samplesQ16: plane.samplesQ16.map { $0 + delta }
                )
            }
        )
    }

    static func pixelBuffer() throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            4,
            4,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw R09StageTestError.pixelBufferCreation(status)
        }
        return pixelBuffer
    }

    static func write(
        _ pixelBuffer: CVPixelBuffer,
        bytes: R09StagePixelBytes
    ) throws {
        let status = CVPixelBufferLockBaseAddress(pixelBuffer, [])
        guard status == kCVReturnSuccess else {
            throw R09StageTestError.pixelBufferLock(status)
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        try writePlane(pixelBuffer, plane: 0, bytes: bytes.luma)
        try writePlane(pixelBuffer, plane: 1, bytes: bytes.chroma)
    }

    static func writePlane(
        _ pixelBuffer: CVPixelBuffer,
        plane: Int,
        bytes: [UInt8]
    ) throws {
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, plane)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
        let activeWidth = plane == 0 ? width : width * 2
        guard bytes.count == activeWidth * height,
              let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane) else {
            throw R09StageTestError.unexpectedOutcome
        }
        let pointer = base.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
        for row in 0..<height {
            for column in 0..<activeWidth {
                pointer[row * stride + column] = bytes[row * activeWidth + column]
            }
        }
    }

    static func readPlane(
        _ pixelBuffer: CVPixelBuffer,
        plane: Int
    ) throws -> [UInt8] {
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, plane)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
        let activeWidth = plane == 0 ? width : width * 2
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane) else {
            throw R09StageTestError.unexpectedOutcome
        }
        let pointer = base.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
        return (0..<height).flatMap { row in
            (0..<activeWidth).map { column in
                pointer[row * stride + column]
            }
        }
    }
}
