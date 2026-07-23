import Foundation

enum R09ResidualPixelAuthority: String, Hashable, Sendable {
    case residualMapOnlyNoFrameApplication = "residual_map_only_no_frame_application"
}

enum R09ResidualFallbackRoute: String, Hashable, Sendable {
    case appleScalerOutputUnmodified = "apple_scaler_output_unmodified"
}

enum R09ResidualResourceRole: String, Hashable, Sendable {
    case workingSetBytes = "working_set_bytes"
    case elapsedMicroseconds = "elapsed_microseconds"
}

enum R09ResidualAvailabilityReason: String, Hashable, Sendable {
    case frameworkUnavailable = "framework_unavailable"
    case assetsUnavailable = "assets_unavailable"
}

enum R09ResidualProviderOutputError: Error, Hashable, Sendable {
    case executionIdentityMismatch
    case planeCountMismatch(expected: Int, actual: Int)
    case duplicatePlane(R09ResidualPlaneID)
    case missingPlane(R09ResidualPlaneID)
    case geometryMismatch(R09ResidualPlaneID)
    case sampleCountMismatch(R09ResidualPlaneID)
    case sampleOutOfRange(plane: R09ResidualPlaneID, index: Int, value: Int64)
    case directionInconsistent(plane: R09ResidualPlaneID, index: Int)
    case invalidConfidence(Int64)
    case invalidResourceMeasurement
}

enum R09ResidualBypassReason: Hashable, Sendable {
    case identityInvalid
    case cancelled
    case busy
    case disabledByPolicy
    case unavailable(R09ResidualAvailabilityReason)
    case confidenceBelowMinimum(
        role: R09ResidualConfidenceRole,
        minimumQ15: Int64,
        actualQ15: Int64
    )
    case noEligibleRegion
    case hallucinationRiskExceeded(maximumAllowedQ15: Int64, actualQ15: Int64)
    case sourceTemporalConsistencyRejected
    case planeLimitExceeded(
        plane: R09ResidualPlaneID,
        index: Int,
        maximumMagnitudeQ16: Int64,
        actualQ16: Int64
    )
    case resourceBudgetExceeded(
        role: R09ResidualResourceRole,
        maximum: Int64,
        actual: Int64
    )
    case providerFailed
    case invalidProviderOutput(R09ResidualProviderOutputError)
}

struct R09ResidualOutput: Hashable, Sendable {
    let requestIdentity: R09ResidualRequestIdentity
    let authorization: R09ResidualAuthorizationIdentity
    let scalerIdentity: R09AppleScalerIdentity
    let modelIdentity: R09ResidualModelIdentity
    let executionIdentity: R09ResidualExecutionIdentity
    let residual: R09PlanarResidualQ16
    let confidenceQ15: Int64
    let resourceMeasurement: R09ResidualResourceMeasurement
    let pixelAuthority = R09ResidualPixelAuthority.residualMapOnlyNoFrameApplication

    init(
        producerCapability _: R09ResidualProducerCapability,
        requestIdentity: R09ResidualRequestIdentity,
        authorization: R09ResidualAuthorizationIdentity,
        scalerIdentity: R09AppleScalerIdentity,
        modelIdentity: R09ResidualModelIdentity,
        executionIdentity: R09ResidualExecutionIdentity,
        residual: R09PlanarResidualQ16,
        confidenceQ15: Int64,
        resourceMeasurement: R09ResidualResourceMeasurement
    ) throws {
        try R09ResidualValidation.q15(confidenceQ15, role: "provider_output_confidence_q15")
        self.requestIdentity = requestIdentity
        self.authorization = authorization
        self.scalerIdentity = scalerIdentity
        self.modelIdentity = modelIdentity
        self.executionIdentity = executionIdentity
        self.residual = residual
        self.confidenceQ15 = confidenceQ15
        self.resourceMeasurement = resourceMeasurement
    }
}

struct R09ResidualBypass: Hashable, Sendable {
    let requestIdentity: R09ResidualRequestIdentity
    let authorization: R09ResidualAuthorizationIdentity
    let scalerIdentity: R09AppleScalerIdentity
    let modelIdentity: R09ResidualModelIdentity
    let executionIdentity: R09ResidualExecutionIdentity
    let reason: R09ResidualBypassReason
    let fallbackRoute = R09ResidualFallbackRoute.appleScalerOutputUnmodified
}

enum R09ResidualDisposition: Hashable, Sendable {
    case produced(R09ResidualOutput)
    case bypassed(R09ResidualBypass)
}

protocol R09CoreAIResidualService: Sendable {
    func predictResidual(for request: R09ResidualRequest) async -> R09ResidualDisposition
}
