import Foundation
@testable import Mirmir

struct R09ResidualTestRequestOptions {
    var frameID = "r09.frame.12"
    var shotID = "r09.shot.1"
    var streamID = "r09.stream.1"
    var frameOrdinal: Int64 = 12
    var stateGeneration: Int64 = 3
    var authorizationFrameID: String?
    var authorizationShotID: String?
    var authorizationStreamID: String?
    var authorizationStateGeneration: Int64?
    var authorizationBackendID: String?
    var authorizationProcessingIdentity: AppleUpscaleProcessingIdentity?
    var scalerBackendID = R09AppleScalerIdentity.deterministicPrimaryBackendID
    var scalerImplementationVersion =
        R09AppleScalerIdentity.deterministicPrimaryBackendVersion
    var modelIdentity: R09ResidualModelIdentity?
    var ashApprovedSamplesQ15 = [Int64](repeating: 32_767, count: 4)
    var protectedSamplesQ15: [Int64] = [0, 0, 32_767, 0]
    var sourceSamplesQ16: [Int64] = [34_000, 26_000, 30_000, 35_000]
    var temporalSamplesQ16: [Int64] = [35_000, 25_000, 30_000, 34_000]
    var ashEligibilityQ15: Int64 = 24_576
    var sourceReferenceQ15: Int64 = 24_576
    var temporalReferenceQ15: Int64 = 24_576
    var minimumRequiredQ15: Int64 = 16_384
    var maximumWorkingSetBytes: Int64 = 8_192
    var maximumElapsedMicroseconds: Int64 = 2_000
    var hallucinationRiskQ15: Int64 = 8_192
    var maximumAllowedHallucinationRiskQ15: Int64 = 16_384
}

struct R09ResidualAuthorizationFixture {
    let identity: R09ResidualRequestIdentity
    let authorization: R09ResidualAuthorizationIdentity
    let scalerIdentity: R09AppleScalerIdentity
    let modelIdentity: R09ResidualModelIdentity
    let postScalerFrame: R09PlanarFrameQ16
    let ashRequestedLumaMask: R09MaskPlaneQ15
    let protectedLumaMask: R09MaskPlaneQ15
    let limits: R09ResidualLimits
    let sourceReference: R09ResidualReferenceFrame
    let temporalReference: R09ResidualReferenceFrame
    let confidenceBudget: R09ResidualConfidenceBudget
    let resourceBudget: R09ResidualResourceBudget
    let safetySignal: R09ResidualSafetySignal
}

enum R09ResidualTestSupport {
    static let r08AcceptanceSHA256 =
        "0d81917a93cf56cae867c11b7c65fb3c85e53b7596929cf9eec2ef09c24634b0"
    static let currentSamplesQ16: [Int64] = [30_000, 30_000, 30_000, 30_000]
}

extension R09ResidualTestSupport {
    static func request(
        _ options: R09ResidualTestRequestOptions = R09ResidualTestRequestOptions()
    ) async throws -> R09ResidualRequest {
        let outcome = try await authorizationOutcome(options)
        guard case .authorized(let request) = outcome else {
            throw R09ResidualTestError.expectedAuthorized
        }
        return request
    }

    static func authorizationOutcome(
        _ options: R09ResidualTestRequestOptions = R09ResidualTestRequestOptions()
    ) async throws -> R09ASHResidualAuthorizationOutcome {
        R09ASHResidualAuthorizer.authorize(try await authorizationInput(options))
    }

    static func authorizationInput(
        _ options: R09ResidualTestRequestOptions = R09ResidualTestRequestOptions()
    ) async throws -> R09ASHResidualAuthorizationInput {
        let identity = try R09ResidualRequestIdentity(
            frameID: options.frameID,
            shotID: options.shotID,
            streamID: options.streamID,
            frameOrdinal: options.frameOrdinal,
            stateGeneration: options.stateGeneration,
            ioContractSHA256: R09ResidualRequestIdentity.ioContractSHA256
        )
        let scaler = try R09AppleScalerIdentity(
            backendID: options.scalerBackendID,
            implementationVersion: options.scalerImplementationVersion,
            processingIdentity: processingIdentity(
                backendID: options.scalerBackendID,
                backendRevision: options.scalerImplementationVersion
            ),
            outputFrameID: options.frameID,
            kind: .metalPerformanceShaders,
            scaleNumerator: 2,
            scaleDenominator: 1,
            executionMode: .deterministicFixtureSimulation,
            nativeExecution: .notObserved
        )
        let authorizationBackendID = options.authorizationBackendID ?? scaler.backendID
        let authorization = try R09ResidualAuthorizationIdentity(
            authorizationID: "operator.r09.functional-simulation.2026-07-22",
            referencedR08AcceptanceSHA256: r08AcceptanceSHA256,
            scope: .deterministicSimulationOnly,
            frameID: options.authorizationFrameID ?? options.frameID,
            shotID: options.authorizationShotID ?? options.shotID,
            streamID: options.authorizationStreamID ?? options.streamID,
            stateGeneration: options.authorizationStateGeneration ?? options.stateGeneration,
            sourceReferenceFrameID: "r09.source.12",
            sourceReferenceFrameOrdinal: options.frameOrdinal,
            temporalReferenceFrameID: "r09.temporal.11",
            temporalReferenceFrameOrdinal: options.frameOrdinal - 1,
            primaryBackendID: authorizationBackendID,
            primaryProcessingIdentity: try options.authorizationProcessingIdentity
                ?? processingIdentity(
                    backendID: authorizationBackendID,
                    backendRevision: scaler.implementationVersion
                )
        )
        let model = try options.modelIdentity ?? R09ResidualModelIdentity(
            modelID: "r09.deterministic-local-residual", modelVersion: "1",
            artifactKind: .deterministicSimulationContract,
            contentSHA256: R09ResidualModelIdentity.deterministicProviderSHA256,
            preprocessingIdentity:
                R09ResidualModelIdentity.deterministicPreprocessingIdentity,
            postprocessingIdentity:
                R09ResidualModelIdentity.deterministicPostprocessingIdentity,
            residualContractIdentity:
                R09ResidualModelIdentity.deterministicResidualContractIdentity
        )
        let postScalerFrame = try nv12Frame(samplesQ16: currentSamplesQ16)
        let ashApprovedMask = try nv12Mask(samplesQ15: options.ashApprovedSamplesQ15)
        let protectedMask = try nv12Mask(samplesQ15: options.protectedSamplesQ15)
        let sourceReference = try R09ResidualReferenceFrame(
            kind: .source, frameID: "r09.source.12",
            shotID: options.shotID,
            streamID: options.streamID,
            stateGeneration: options.stateGeneration,
            frameOrdinal: options.frameOrdinal,
            frame: nv12Frame(samplesQ16: options.sourceSamplesQ16)
        )
        let temporalReference = try R09ResidualReferenceFrame(
            kind: .alignedTemporal, frameID: "r09.temporal.11",
            shotID: options.shotID,
            streamID: options.streamID,
            stateGeneration: options.stateGeneration,
            frameOrdinal: options.frameOrdinal - 1,
            frame: nv12Frame(samplesQ16: options.temporalSamplesQ16)
        )
        return try await authorizationInput(R09ResidualAuthorizationFixture(
            identity: identity,
            authorization: authorization,
            scalerIdentity: scaler,
            modelIdentity: model,
            postScalerFrame: postScalerFrame,
            ashRequestedLumaMask: ashApprovedMask.luma,
            protectedLumaMask: protectedMask.luma,
            limits: nv12Limits(),
            sourceReference: sourceReference,
            temporalReference: temporalReference,
            confidenceBudget: R09ResidualConfidenceBudget(
                ashEligibilityQ15: options.ashEligibilityQ15,
                sourceReferenceQ15: options.sourceReferenceQ15,
                temporalReferenceQ15: options.temporalReferenceQ15,
                minimumRequiredQ15: options.minimumRequiredQ15
            ),
            resourceBudget: R09ResidualResourceBudget(
                maximumWorkingSetBytes: options.maximumWorkingSetBytes,
                maximumElapsedMicroseconds: options.maximumElapsedMicroseconds
            ),
            safetySignal: R09ResidualSafetySignal(
                hallucinationRiskQ15: options.hallucinationRiskQ15,
                maximumAllowedHallucinationRiskQ15:
                    options.maximumAllowedHallucinationRiskQ15
            )
        ))
    }

    static func authorizationInput(
        _ fixture: R09ResidualAuthorizationFixture
    ) async throws -> R09ASHResidualAuthorizationInput {
        let heads = try fullEligibilityHeads()
        let analysisService = try R08DeterministicAnalysisService(
            analysisHeadProvider: { _ in heads }
        )
        for _ in 0..<Int(fixture.identity.stateGeneration) {
            _ = try await analysisService.resetState(reason: .discontinuity)
        }
        var analysisOptions = R08TestRequestOptions()
        analysisOptions.streamID = fixture.identity.streamID
        analysisOptions.frameID = fixture.identity.frameID
        analysisOptions.shotID = fixture.identity.shotID
        analysisOptions.frameOrdinal = fixture.identity.frameOrdinal
        analysisOptions.stateGeneration = UInt64(fixture.identity.stateGeneration)
        let sidecar = R08ASHAnalysisSidecar(
            outcome: try await analysisService.analyze(
                try R08TestSupport.request(analysisOptions)
            )
        )
        var contextOptions = R07FunctionalContextOptions()
        contextOptions.frameID = fixture.identity.frameID
        contextOptions.shotID = fixture.identity.shotID
        contextOptions.currentBackendID = fixture.scalerIdentity.backendID
        let protected = try R07ProtectedMask(
            kind: .text,
            width: fixture.protectedLumaMask.width,
            height: fixture.protectedLumaMask.height,
            samplesQ15: fixture.protectedLumaMask.samplesQ15
        )
        return R09ASHResidualAuthorizationInput(
            identity: fixture.identity,
            authorization: fixture.authorization,
            scalerIdentity: fixture.scalerIdentity,
            modelIdentity: fixture.modelIdentity,
            postScalerFrame: fixture.postScalerFrame,
            decisionContext: try R07FunctionalTestFixtures.makeContext(contextOptions),
            analysisSidecar: sidecar,
            ashRequestedLumaMask: fixture.ashRequestedLumaMask,
            protectedComposition: try R07ProtectedRegionPolicy.compose(
                width: fixture.protectedLumaMask.width,
                height: fixture.protectedLumaMask.height,
                regions: [protected]
            ),
            limits: fixture.limits,
            sourceReference: fixture.sourceReference,
            temporalReference: fixture.temporalReference,
            confidenceBudget: fixture.confidenceBudget,
            resourceBudget: fixture.resourceBudget,
            safetySignal: fixture.safetySignal
        )
    }
}

extension R09ResidualTestSupport {
    static func frame(samplesQ16: [Int64]) throws -> R09PlanarFrameQ16 {
        try R09PlanarFrameQ16(
            planes: R09ResidualPlaneID.allCases.map { id in
                try R09UnsignedPlaneQ16(
                    id: id,
                    width: 2,
                    height: 2,
                    samplesQ16: samplesQ16
                )
            }
        )
    }

    static func nv12Frame(samplesQ16: [Int64]) throws -> R09PlanarFrameQ16 {
        try R09PlanarFrameQ16(
            luma: R09UnsignedPlaneQ16(
                id: .luma,
                width: 4,
                height: 4,
                samplesQ16: expandTwoByTwo(samplesQ16)
            ),
            chromaCb: R09UnsignedPlaneQ16(
                id: .chromaCb,
                width: 2,
                height: 2,
                samplesQ16: samplesQ16
            ),
            chromaCr: R09UnsignedPlaneQ16(
                id: .chromaCr,
                width: 2,
                height: 2,
                samplesQ16: samplesQ16
            )
        )
    }

    static func mask(samplesQ15: [Int64]) throws -> R09PlanarMaskQ15 {
        try R09PlanarMaskQ15(
            planes: R09ResidualPlaneID.allCases.map { id in
                try R09MaskPlaneQ15(
                    id: id,
                    width: 2,
                    height: 2,
                    samplesQ15: samplesQ15
                )
            }
        )
    }

    static func nv12Mask(samplesQ15: [Int64]) throws -> R09PlanarMaskQ15 {
        try R09PlanarMaskQ15(
            planes: [
                R09MaskPlaneQ15(
                    id: .luma,
                    width: 4,
                    height: 4,
                    samplesQ15: expandTwoByTwo(samplesQ15)
                ),
                R09MaskPlaneQ15(
                    id: .chromaCb,
                    width: 2,
                    height: 2,
                    samplesQ15: samplesQ15
                ),
                R09MaskPlaneQ15(
                    id: .chromaCr,
                    width: 2,
                    height: 2,
                    samplesQ15: samplesQ15
                )
            ]
        )
    }

    static func limits() throws -> R09ResidualLimits {
        try R09ResidualLimits(
            perPlane: R09PerPlaneResidualLimitsQ16(
                limits: [
                    R09PlaneResidualLimitQ16(id: .luma, maximumMagnitudeQ16: 4_096),
                    R09PlaneResidualLimitQ16(id: .chromaCb, maximumMagnitudeQ16: 2_048),
                    R09PlaneResidualLimitQ16(id: .chromaCr, maximumMagnitudeQ16: 2_048)
                ]
            ),
            content: R09ContentResidualLimitQ16(
                contentClass: .mixed,
                maximumMagnitudeQ16: 3_072
            ),
            edge: R09PlanarEdgeLimitsQ16(
                planes: try R09ResidualPlaneID.allCases.map { id in
                    try R09EdgeLimitPlaneQ16(
                        id: id,
                        width: 2,
                        height: 2,
                        maximumMagnitudesQ16: [3_072, 3_072, 0, 3_072]
                    )
                }
            ),
            consistency: R09ConsistencyLimitsQ16(
                sourceMaximumMagnitudeQ16: 4_096,
                temporalMaximumMagnitudeQ16: 4_096
            )
        )
    }

    static func nv12Limits() throws -> R09ResidualLimits {
        let edgeSamples: [Int64] = [3_072, 3_072, 0, 3_072]
        return try R09ResidualLimits(
            perPlane: R09PerPlaneResidualLimitsQ16(
                limits: [
                    R09PlaneResidualLimitQ16(id: .luma, maximumMagnitudeQ16: 4_096),
                    R09PlaneResidualLimitQ16(id: .chromaCb, maximumMagnitudeQ16: 2_048),
                    R09PlaneResidualLimitQ16(id: .chromaCr, maximumMagnitudeQ16: 2_048)
                ]
            ),
            content: R09ContentResidualLimitQ16(
                contentClass: .mixed,
                maximumMagnitudeQ16: 3_072
            ),
            edge: R09PlanarEdgeLimitsQ16(
                planes: [
                    R09EdgeLimitPlaneQ16(
                        id: .luma,
                        width: 4,
                        height: 4,
                        maximumMagnitudesQ16: expandTwoByTwo(edgeSamples)
                    ),
                    R09EdgeLimitPlaneQ16(
                        id: .chromaCb,
                        width: 2,
                        height: 2,
                        maximumMagnitudesQ16: edgeSamples
                    ),
                    R09EdgeLimitPlaneQ16(
                        id: .chromaCr,
                        width: 2,
                        height: 2,
                        maximumMagnitudesQ16: edgeSamples
                    )
                ]
            ),
            consistency: R09ConsistencyLimitsQ16(
                sourceMaximumMagnitudeQ16: 4_096,
                temporalMaximumMagnitudeQ16: 4_096
            )
        )
    }

    static func fullEligibilityHeads() throws -> R08AnalysisHeads {
        let zero = try R08Q15Map(
            width: 2,
            height: 2,
            samples: [Int64](repeating: 0, count: 4),
            role: "zero"
        )
        let full = try R08Q15Map(
            width: 2,
            height: 2,
            samples: [Int64](repeating: R09MaskPlaneQ15.maximumSample, count: 4),
            role: "full"
        )
        return try R08AnalysisHeads(
            protection: R08ProtectionHeads(faceSkinQ15: zero, textLineArtQ15: zero),
            condition: R08ConditionHeads(
                animationUILikelihoodQ15: zero,
                noiseCompressionSeverityQ15: zero,
                blurMotionBlurEstimateQ15: zero
            ),
            riskConfidence: R08RiskConfidenceHeads(
                aliasingRingingRiskQ15: full,
                textureDetailConfidenceQ15: full,
                motionReliabilityOcclusionRiskQ15: zero
            ),
            noReferenceQualityQ15: R08Q15Value(24_576, role: "no_reference"),
            sourceClassification: R08SourceClassificationResult(
                classification: .mixed,
                confidenceQ15: R08Q15Value(24_576, role: "classification")
            )
        )
    }

    static func expandTwoByTwo<T>(_ samples: [T]) -> [T] {
        precondition(samples.count == 4)
        return [
            samples[0], samples[0], samples[1], samples[1],
            samples[0], samples[0], samples[1], samples[1],
            samples[2], samples[2], samples[3], samples[3],
            samples[2], samples[2], samples[3], samples[3]
        ]
    }

    static func processingIdentity(
        backendID: String,
        backendRevision: String,
        configurationIdentity: String = "r09.fixture.configuration"
    ) throws -> AppleUpscaleProcessingIdentity {
        try AppleUpscaleProcessingIdentity(
            route: AppleUpscaleRouteIdentity(
                backend: AppleUpscaleBackendIdentity(
                    backendID: backendID,
                    backendRevision: backendRevision,
                    modelAssetsIdentity: .notRequired
                ),
                configurationIdentity: configurationIdentity,
                policyIdentity: "r09.fixture.policy",
                materialDecisionIdentity: "r09.fixture.decision"
            ),
            fallbackHistory: []
        )
    }

    static func produced(
        _ disposition: R09ResidualDisposition,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> R09ResidualOutput {
        guard case .produced(let output) = disposition else {
            throw R09ResidualTestError.expectedProduced(file: file, line: line)
        }
        return output
    }

    static func bypassed(
        _ disposition: R09ResidualDisposition,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> R09ResidualBypass {
        guard case .bypassed(let bypass) = disposition else {
            throw R09ResidualTestError.expectedBypassed(file: file, line: line)
        }
        return bypass
    }

    static func rawOutput(
        for request: R09ResidualRequest,
        planes: [R09RawResidualPlaneQ16]? = nil,
        confidenceQ15: Int64 = 24_576,
        workingSetBytes: Int64 = 4_096,
        elapsedMicroseconds: Int64 = 1_000,
        executionIdentity: R09ResidualExecutionIdentity = .deterministicSimulationV1
    ) async throws -> R09RawResidualProviderOutput {
        let nominal = try await R09DeterministicResidualProvider.predict(request: request)
        return R09RawResidualProviderOutput(
            executionIdentity: executionIdentity,
            planes: planes ?? nominal.planes,
            confidenceQ15: confidenceQ15,
            workingSetBytes: workingSetBytes,
            elapsedMicroseconds: elapsedMicroseconds
        )
    }
}

enum R09ResidualTestError: Error {
    case expectedAuthorized
    case expectedProduced(file: StaticString, line: UInt)
    case expectedBypassed(file: StaticString, line: UInt)
}
