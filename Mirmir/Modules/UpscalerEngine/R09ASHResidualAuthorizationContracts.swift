enum R09ASHResidualAuthorizationError: Error, Equatable, Sendable {
    case acceptedR08BindingMismatch(expected: String, actual: String)
    case requestContractMismatch(expected: String, actual: String)
    case deterministicModelBindingMismatch
    case deterministicExecutionBindingMismatch
    case authorizationFrameMismatch(expected: String, actual: String)
    case authorizationShotMismatch(expected: String, actual: String)
    case authorizationStreamMismatch(expected: String, actual: String)
    case authorizationStateGenerationMismatch(expected: Int64, actual: Int64)
    case authorizationSourceReferenceMismatch
    case authorizationTemporalReferenceMismatch
    case authorizationPrimaryBackendMismatch(expected: String, actual: String)
    case authorizationPrimaryRouteMismatch
    case scalerOutputFrameMismatch(expected: String, actual: String)
    case decisionFrameMismatch(expected: String, actual: String)
    case decisionShotMismatch(expected: String, actual: String)
    case decisionPrimaryBackendMismatch(expected: String, actual: String?)
    case decisionScaleMismatch(
        expectedNumerator: Int, expectedDenominator: Int,
        actualNumerator: Int, actualDenominator: Int
    )
    case analysisFrameMismatch(expected: String, actual: String)
    case analysisShotMismatch(expected: String, actual: String)
    case analysisStreamMismatch(expected: String, actual: String)
    case analysisFrameOrdinalMismatch(expected: Int64, actual: Int64)
    case analysisStateGenerationMismatch(expected: Int64, actual: UInt64)
    case ashMaskPlaneMismatch(actual: R09ResidualPlaneID)
    case geometryMismatch(
        role: R09ASHResidualGeometryRole,
        expectedWidth: Int, expectedHeight: Int,
        actualWidth: Int, actualHeight: Int
    )
    case unsupportedAnalysisMapGeometry(
        mapWidth: Int,
        mapHeight: Int,
        lumaWidth: Int,
        lumaHeight: Int
    )
}
enum R09ASHResidualGeometryRole: String, Equatable, Sendable {
    case ashRequestedLuma = "ash_requested_luma"
    case protectedComposition = "protected_composition"
    case chromaCb = "chroma_cb"
    case chromaCr = "chroma_cr"
}
enum R09ASHResidualNoAuthorizationReason: Equatable, Sendable {
    case r08AnalysisBypassed(R08AnalysisBypassReason)
    case authorizationInvalid(R09ASHResidualAuthorizationError)
    case contractInvalid(R09ResidualContractError)
    case unexpectedFailure
}
struct R09ASHResidualNoAuthorization: Equatable, Sendable {
    let requestIdentity: R09ResidualRequestIdentity
    let authorization: R09ResidualAuthorizationIdentity
    let scalerIdentity: R09AppleScalerIdentity
    let reason: R09ASHResidualNoAuthorizationReason
    let fallbackRoute = R09ResidualFallbackRoute.appleScalerOutputUnmodified
}
enum R09ASHResidualAuthorizationOutcome: Equatable, Sendable {
    case authorized(R09ResidualRequest)
    case notAuthorized(R09ASHResidualNoAuthorization)
}

struct R09ASHResidualAuthorizationInput: Sendable {
    let identity: R09ResidualRequestIdentity
    let authorization: R09ResidualAuthorizationIdentity
    let scalerIdentity: R09AppleScalerIdentity
    let modelIdentity: R09ResidualModelIdentity
    let postScalerFrame: R09PlanarFrameQ16
    let decisionContext: ASHDecisionContext
    let analysisSidecar: R08ASHAnalysisSidecar
    let ashRequestedLumaMask: R09MaskPlaneQ15
    let protectedComposition: R07ProtectedMaskComposition
    let limits: R09ResidualLimits
    let sourceReference: R09ResidualReferenceFrame
    let temporalReference: R09ResidualReferenceFrame
    let confidenceBudget: R09ResidualConfidenceBudget
    let resourceBudget: R09ResidualResourceBudget
    let safetySignal: R09ResidualSafetySignal
}
