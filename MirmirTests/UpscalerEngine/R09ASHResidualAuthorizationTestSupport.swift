import XCTest
@testable import Mirmir

struct R09ASHResidualAuthorizationFixture {
    var identity: R09ResidualRequestIdentity
    var authorization: R09ResidualAuthorizationIdentity
    var scalerIdentity: R09AppleScalerIdentity
    var modelIdentity: R09ResidualModelIdentity
    var postScalerFrame: R09PlanarFrameQ16
    var decisionContext: ASHDecisionContext
    var analysisSidecar: R08ASHAnalysisSidecar
    var ashRequestedLumaMask: R09MaskPlaneQ15
    var protectedComposition: R07ProtectedMaskComposition
    var limits: R09ResidualLimits
    var sourceReference: R09ResidualReferenceFrame
    var temporalReference: R09ResidualReferenceFrame
    var confidenceBudget: R09ResidualConfidenceBudget
    var resourceBudget: R09ResidualResourceBudget
    var safetySignal: R09ResidualSafetySignal

    var input: R09ASHResidualAuthorizationInput {
        R09ASHResidualAuthorizationInput(
            identity: identity,
            authorization: authorization,
            scalerIdentity: scalerIdentity,
            modelIdentity: modelIdentity,
            postScalerFrame: postScalerFrame,
            decisionContext: decisionContext,
            analysisSidecar: analysisSidecar,
            ashRequestedLumaMask: ashRequestedLumaMask,
            protectedComposition: protectedComposition,
            limits: limits,
            sourceReference: sourceReference,
            temporalReference: temporalReference,
            confidenceBudget: confidenceBudget,
            resourceBudget: resourceBudget,
            safetySignal: safetySignal
        )
    }
}
extension R09ASHResidualAuthorizationTests {
    static let acceptedR08SHA256 =
        "0d81917a93cf56cae867c11b7c65fb3c85e53b7596929cf9eec2ef09c24634b0"
    static let zeroMap = Array(repeating: Int64(0), count: 4)
    static let fullMap = Array(repeating: R09MaskPlaneQ15.maximumSample, count: 4)

    func makeFixture(
        heads: R08AnalysisHeads? = nil,
        r08Options: R08TestRequestOptions = R08TestRequestOptions(),
        availabilityBypass: R08AnalysisBypassReason? = nil,
        ashSamples: [Int64]? = nil,
        protectedSamples: [Int64]? = nil,
        contextOptions: R07FunctionalContextOptions? = nil
    ) async throws -> R09ASHResidualAuthorizationFixture {
        let selectedHeads = try heads ?? Self.heads(
            aliasing: Self.fullMap,
            texture: Self.fullMap,
            motionRisk: Self.zeroMap
        )
        let service = try R08DeterministicAnalysisService(
            availabilityBypassReason: availabilityBypass,
            analysisHeadProvider: { _ in selectedHeads }
        )
        let sidecar = R08ASHAnalysisSidecar(
            outcome: try await service.analyze(try R08TestSupport.request(r08Options))
        )
        let frame = try Self.frame()
        let selectedProtected = protectedSamples ?? Array(repeating: 0, count: 16)
        let protectedMask = try R07ProtectedMask(
            kind: .text,
            width: 4,
            height: 4,
            samplesQ15: selectedProtected
        )
        return try R09ASHResidualAuthorizationFixture(
            identity: Self.identity(),
            authorization: Self.authorization(),
            scalerIdentity: Self.scalerIdentity(),
            modelIdentity: Self.modelIdentity(),
            postScalerFrame: frame,
            decisionContext: R07FunctionalTestFixtures.makeContext(
                contextOptions ?? Self.defaultContextOptions()
            ),
            analysisSidecar: sidecar,
            ashRequestedLumaMask: R09MaskPlaneQ15(
                id: .luma,
                width: 4,
                height: 4,
                samplesQ15: ashSamples ?? Array(repeating: 24_576, count: 16)
            ),
            protectedComposition: R07ProtectedRegionPolicy.compose(
                width: 4,
                height: 4,
                regions: [protectedMask]
            ),
            limits: Self.limits(),
            sourceReference: R09ResidualReferenceFrame(
                kind: .source,
                frameID: "source.12",
                shotID: "r07.shot",
                streamID: "r08.stream",
                stateGeneration: 0,
                frameOrdinal: 12,
                frame: frame
            ),
            temporalReference: R09ResidualReferenceFrame(
                kind: .alignedTemporal,
                frameID: "temporal.11",
                shotID: "r07.shot",
                streamID: "r08.stream",
                stateGeneration: 0,
                frameOrdinal: 11,
                frame: frame
            ),
            confidenceBudget: R09ResidualConfidenceBudget(
                ashEligibilityQ15: 24_576,
                sourceReferenceQ15: 24_576,
                temporalReferenceQ15: 24_576,
                minimumRequiredQ15: 16_384
            ),
            resourceBudget: R09ResidualResourceBudget(
                maximumWorkingSetBytes: 8_192,
                maximumElapsedMicroseconds: 2_000
            ),
            safetySignal: R09ResidualSafetySignal(
                hallucinationRiskQ15: 1_000,
                maximumAllowedHallucinationRiskQ15: 2_000
            )
        )
    }

    func authorizedRequest(
        _ fixture: R09ASHResidualAuthorizationFixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> R09ResidualRequest {
        let outcome = R09ASHResidualAuthorizer.authorize(fixture.input)
        guard case .authorized(let request) = outcome else {
            XCTFail("Expected an authorized R09 request", file: file, line: line)
            throw R09ASHResidualAuthorizationTestError.unexpectedOutcome
        }
        return request
    }

    func assertAuthorizationError(
        _ expected: R09ASHResidualAuthorizationError,
        fixture: R09ASHResidualAuthorizationFixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let outcome = R09ASHResidualAuthorizer.authorize(fixture.input)
        guard case .notAuthorized(let bypass) = outcome else {
            return XCTFail("Expected typed R09 authorization bypass", file: file, line: line)
        }
        XCTAssertEqual(
            bypass.reason,
            .authorizationInvalid(expected),
            file: file,
            line: line
        )
        XCTAssertEqual(
            bypass.fallbackRoute,
            .appleScalerOutputUnmodified,
            file: file,
            line: line
        )
    }

    static func identity(
        ioContractSHA256: String = R09ResidualRequestIdentity.ioContractSHA256
    ) throws -> R09ResidualRequestIdentity {
        try R09ResidualRequestIdentity(
            frameID: "r07.frame.101",
            shotID: "r07.shot",
            streamID: "r08.stream",
            frameOrdinal: 12,
            stateGeneration: 0,
            ioContractSHA256: ioContractSHA256
        )
    }

    static func authorization(
        referencedR08AcceptanceSHA256: String = acceptedR08SHA256,
        stateGeneration: Int64 = 0,
        primaryProcessingIdentity: AppleUpscaleProcessingIdentity? = nil
    ) throws -> R09ResidualAuthorizationIdentity {
        try R09ResidualAuthorizationIdentity(
            authorizationID: "r09.authorization.fixture",
            referencedR08AcceptanceSHA256: referencedR08AcceptanceSHA256,
            scope: .deterministicSimulationOnly,
            frameID: "r07.frame.101",
            shotID: "r07.shot",
            streamID: "r08.stream",
            stateGeneration: stateGeneration,
            sourceReferenceFrameID: "source.12",
            sourceReferenceFrameOrdinal: 12,
            temporalReferenceFrameID: "temporal.11",
            temporalReferenceFrameOrdinal: 11,
            primaryBackendID: R09AppleScalerIdentity.deterministicPrimaryBackendID,
            primaryProcessingIdentity: try primaryProcessingIdentity
                ?? R09ResidualTestSupport.processingIdentity(
                    backendID: R09AppleScalerIdentity.deterministicPrimaryBackendID,
                    backendRevision: R09AppleScalerIdentity.deterministicPrimaryBackendVersion
                )
        )
    }

    static func scalerIdentity() throws -> R09AppleScalerIdentity {
        try R09AppleScalerIdentity(
            backendID: R09AppleScalerIdentity.deterministicPrimaryBackendID,
            implementationVersion: R09AppleScalerIdentity.deterministicPrimaryBackendVersion,
            processingIdentity: R09ResidualTestSupport.processingIdentity(
                backendID: R09AppleScalerIdentity.deterministicPrimaryBackendID,
                backendRevision: R09AppleScalerIdentity.deterministicPrimaryBackendVersion
            ),
            outputFrameID: "r07.frame.101",
            kind: .metalPerformanceShaders,
            scaleNumerator: 2,
            scaleDenominator: 1,
            executionMode: .deterministicFixtureSimulation,
            nativeExecution: .notObserved
        )
    }

    static func modelIdentity() throws -> R09ResidualModelIdentity {
        try R09ResidualModelIdentity(
            modelID: "r09.deterministic-local-residual",
            modelVersion: "1",
            artifactKind: .deterministicSimulationContract,
            contentSHA256: R09ResidualModelIdentity.deterministicProviderSHA256,
            preprocessingIdentity:
                R09ResidualModelIdentity.deterministicPreprocessingIdentity,
            postprocessingIdentity:
                R09ResidualModelIdentity.deterministicPostprocessingIdentity,
            residualContractIdentity:
                R09ResidualModelIdentity.deterministicResidualContractIdentity
        )
    }

    static func defaultContextOptions() -> R07FunctionalContextOptions {
        var options = R07FunctionalContextOptions()
        options.currentBackendID = R09AppleScalerIdentity.deterministicPrimaryBackendID
        return options
    }

    static func frame() throws -> R09PlanarFrameQ16 {
        try R09PlanarFrameQ16(
            luma: R09UnsignedPlaneQ16(
                id: .luma,
                width: 4,
                height: 4,
                samplesQ16: Array(repeating: 32_768, count: 16)
            ),
            chromaCb: R09UnsignedPlaneQ16(
                id: .chromaCb,
                width: 2,
                height: 2,
                samplesQ16: Array(repeating: 30_000, count: 4)
            ),
            chromaCr: R09UnsignedPlaneQ16(
                id: .chromaCr,
                width: 2,
                height: 2,
                samplesQ16: Array(repeating: 34_000, count: 4)
            )
        )
    }

    static func limits() throws -> R09ResidualLimits {
        let perPlane = try R09PerPlaneResidualLimitsQ16(
            limits: [
                R09PlaneResidualLimitQ16(id: .luma, maximumMagnitudeQ16: 4_096),
                R09PlaneResidualLimitQ16(id: .chromaCb, maximumMagnitudeQ16: 2_048),
                R09PlaneResidualLimitQ16(id: .chromaCr, maximumMagnitudeQ16: 2_048)
            ]
        )
        let edge = try R09PlanarEdgeLimitsQ16(
            planes: [
                R09EdgeLimitPlaneQ16(
                    id: .luma,
                    width: 4,
                    height: 4,
                    maximumMagnitudesQ16: Array(repeating: 3_072, count: 16)
                ),
                R09EdgeLimitPlaneQ16(
                    id: .chromaCb,
                    width: 2,
                    height: 2,
                    maximumMagnitudesQ16: Array(repeating: 2_048, count: 4)
                ),
                R09EdgeLimitPlaneQ16(
                    id: .chromaCr,
                    width: 2,
                    height: 2,
                    maximumMagnitudesQ16: Array(repeating: 2_048, count: 4)
                )
            ]
        )
        return R09ResidualLimits(
            perPlane: perPlane,
            content: try R09ContentResidualLimitQ16(
                contentClass: .mixed,
                maximumMagnitudeQ16: 3_072
            ),
            edge: edge,
            consistency: try R09ConsistencyLimitsQ16(
                sourceMaximumMagnitudeQ16: 4_096,
                temporalMaximumMagnitudeQ16: 4_096
            )
        )
    }

    static func heads(
        face: [Int64] = zeroMap,
        text: [Int64] = zeroMap,
        aliasing: [Int64],
        texture: [Int64],
        motionRisk: [Int64]
    ) throws -> R08AnalysisHeads {
        let zero = try map(zeroMap, role: "zero")
        return try R08AnalysisHeads(
            protection: R08ProtectionHeads(
                faceSkinQ15: map(face, role: "face"),
                textLineArtQ15: map(text, role: "text")
            ),
            condition: R08ConditionHeads(
                animationUILikelihoodQ15: zero,
                noiseCompressionSeverityQ15: zero,
                blurMotionBlurEstimateQ15: zero
            ),
            riskConfidence: R08RiskConfidenceHeads(
                aliasingRingingRiskQ15: map(aliasing, role: "aliasing"),
                textureDetailConfidenceQ15: map(texture, role: "texture"),
                motionReliabilityOcclusionRiskQ15: map(motionRisk, role: "motion")
            ),
            noReferenceQualityQ15: R08Q15Value(24_576, role: "no_reference"),
            sourceClassification: R08SourceClassificationResult(
                classification: .mixed,
                confidenceQ15: R08Q15Value(24_576, role: "classification")
            )
        )
    }

    static func map(_ samples: [Int64], role: String) throws -> R08Q15Map {
        try R08Q15Map(width: 2, height: 2, samples: samples, role: role)
    }
}

private enum R09ASHResidualAuthorizationTestError: Error {
    case unexpectedOutcome
}
