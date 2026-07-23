import Foundation

enum R09ResidualReferenceKind: String, Hashable, Sendable {
    case source
    case alignedTemporal = "aligned_temporal"
}

struct R09ResidualReferenceFrame: Hashable, Sendable {
    let kind: R09ResidualReferenceKind
    let frameID: String
    let shotID: String
    let streamID: String
    let stateGeneration: Int64
    let frameOrdinal: Int64
    let frame: R09PlanarFrameQ16

    init(
        kind: R09ResidualReferenceKind,
        frameID: String,
        shotID: String,
        streamID: String,
        stateGeneration: Int64,
        frameOrdinal: Int64,
        frame: R09PlanarFrameQ16
    ) throws {
        guard frameOrdinal >= 0 else {
            throw R09ResidualContractError.invalidFrameOrdinal(
                role: kind.rawValue,
                value: frameOrdinal
            )
        }
        guard stateGeneration >= 0 else {
            throw R09ResidualContractError.invalidStateGeneration(stateGeneration)
        }
        self.kind = kind
        self.frameID = try R09ResidualValidation.identity(frameID, field: "reference_frame_id")
        self.shotID = try R09ResidualValidation.identity(shotID, field: "reference_shot_id")
        self.streamID = try R09ResidualValidation.identity(
            streamID,
            field: "reference_stream_id"
        )
        self.stateGeneration = stateGeneration
        self.frameOrdinal = frameOrdinal
        self.frame = frame
    }
}
enum R09ResidualConfidenceRole: String, Hashable, Sendable {
    case ashEligibility = "ash_eligibility"
    case sourceReference = "source_reference"
    case temporalReference = "temporal_reference"
    case providerOutput = "provider_output"
}

struct R09ResidualConfidenceBudget: Hashable, Sendable {
    let ashEligibilityQ15: Int64
    let sourceReferenceQ15: Int64
    let temporalReferenceQ15: Int64
    let minimumRequiredQ15: Int64

    init(
        ashEligibilityQ15: Int64,
        sourceReferenceQ15: Int64,
        temporalReferenceQ15: Int64,
        minimumRequiredQ15: Int64
    ) throws {
        let values: [(String, Int64)] = [
            ("ash_eligibility_q15", ashEligibilityQ15),
            ("source_reference_q15", sourceReferenceQ15),
            ("temporal_reference_q15", temporalReferenceQ15),
            ("minimum_required_q15", minimumRequiredQ15)
        ]
        for (role, value) in values {
            try R09ResidualValidation.q15(value, role: role)
        }
        self.ashEligibilityQ15 = ashEligibilityQ15
        self.sourceReferenceQ15 = sourceReferenceQ15
        self.temporalReferenceQ15 = temporalReferenceQ15
        self.minimumRequiredQ15 = minimumRequiredQ15
    }
}

struct R09ResidualResourceBudget: Hashable, Sendable {
    let maximumWorkingSetBytes: Int64
    let maximumElapsedMicroseconds: Int64

    init(maximumWorkingSetBytes: Int64, maximumElapsedMicroseconds: Int64) throws {
        guard maximumWorkingSetBytes > 0 else {
            throw R09ResidualContractError.invalidBudget(
                role: "maximum_working_set_bytes",
                value: maximumWorkingSetBytes
            )
        }
        guard maximumElapsedMicroseconds > 0 else {
            throw R09ResidualContractError.invalidBudget(
                role: "maximum_elapsed_microseconds",
                value: maximumElapsedMicroseconds
            )
        }
        self.maximumWorkingSetBytes = maximumWorkingSetBytes
        self.maximumElapsedMicroseconds = maximumElapsedMicroseconds
    }
}

struct R09ResidualResourceMeasurement: Hashable, Sendable {
    let workingSetBytes: Int64
    let elapsedMicroseconds: Int64

    init(workingSetBytes: Int64, elapsedMicroseconds: Int64) throws {
        guard workingSetBytes >= 0 else {
            throw R09ResidualContractError.invalidBudget(
                role: "measured_working_set_bytes",
                value: workingSetBytes
            )
        }
        guard elapsedMicroseconds >= 0 else {
            throw R09ResidualContractError.invalidBudget(
                role: "measured_elapsed_microseconds",
                value: elapsedMicroseconds
            )
        }
        self.workingSetBytes = workingSetBytes
        self.elapsedMicroseconds = elapsedMicroseconds
    }
}

struct R09ResidualSafetySignal: Hashable, Sendable {
    let hallucinationRiskQ15: Int64
    let maximumAllowedHallucinationRiskQ15: Int64

    init(
        hallucinationRiskQ15: Int64,
        maximumAllowedHallucinationRiskQ15: Int64
    ) throws {
        try R09ResidualValidation.q15(
            hallucinationRiskQ15,
            role: "hallucination_risk_q15"
        )
        try R09ResidualValidation.q15(
            maximumAllowedHallucinationRiskQ15,
            role: "maximum_allowed_hallucination_risk_q15"
        )
        self.hallucinationRiskQ15 = hallucinationRiskQ15
        self.maximumAllowedHallucinationRiskQ15 = maximumAllowedHallucinationRiskQ15
    }
}

struct R09ResidualRequest: Hashable, Sendable {
    let identity: R09ResidualRequestIdentity
    let authorization: R09ResidualAuthorizationIdentity
    let scalerIdentity: R09AppleScalerIdentity
    let modelIdentity: R09ResidualModelIdentity
    let postScalerFrame: R09PlanarFrameQ16
    let ashApprovedMask: R09PlanarMaskQ15
    let protectedMask: R09PlanarMaskQ15
    let limits: R09ResidualLimits
    let sourceReference: R09ResidualReferenceFrame
    let temporalReference: R09ResidualReferenceFrame
    let confidenceBudget: R09ResidualConfidenceBudget
    let resourceBudget: R09ResidualResourceBudget
    let safetySignal: R09ResidualSafetySignal

    init(
        ashAuthorization _: R09ASHAuthorizationCapability,
        identity: R09ResidualRequestIdentity,
        authorization: R09ResidualAuthorizationIdentity,
        scalerIdentity: R09AppleScalerIdentity,
        modelIdentity: R09ResidualModelIdentity,
        postScalerFrame: R09PlanarFrameQ16,
        ashApprovedMask: R09PlanarMaskQ15,
        protectedMask: R09PlanarMaskQ15,
        limits: R09ResidualLimits,
        sourceReference: R09ResidualReferenceFrame,
        temporalReference: R09ResidualReferenceFrame,
        confidenceBudget: R09ResidualConfidenceBudget,
        resourceBudget: R09ResidualResourceBudget,
        safetySignal: R09ResidualSafetySignal
    ) throws {
        guard identity.frameID == scalerIdentity.outputFrameID,
              authorization.frameID == identity.frameID,
              authorization.shotID == identity.shotID,
              authorization.streamID == identity.streamID,
              authorization.stateGeneration == identity.stateGeneration,
              authorization.sourceReferenceFrameID == sourceReference.frameID,
              authorization.sourceReferenceFrameOrdinal == sourceReference.frameOrdinal,
              authorization.temporalReferenceFrameID == temporalReference.frameID,
              authorization.temporalReferenceFrameOrdinal == temporalReference.frameOrdinal,
              authorization.primaryBackendID == scalerIdentity.backendID,
              authorization.primaryProcessingIdentity
                == scalerIdentity.processingIdentity else {
            throw R09ResidualContractError.invalidExecutionBinding
        }
        guard sourceReference.kind == .source,
              sourceReference.shotID == identity.shotID,
              sourceReference.streamID == identity.streamID,
              sourceReference.stateGeneration == identity.stateGeneration,
              sourceReference.frameOrdinal == identity.frameOrdinal,
              temporalReference.kind == .alignedTemporal,
              temporalReference.shotID == identity.shotID,
              temporalReference.streamID == identity.streamID,
              temporalReference.stateGeneration == identity.stateGeneration,
              temporalReference.frameOrdinal < identity.frameOrdinal else {
            throw R09ResidualContractError.invalidReferenceBinding
        }
        try Self.validateGeometry(
            frame: postScalerFrame,
            ashApprovedMask: ashApprovedMask,
            protectedMask: protectedMask,
            edge: limits.edge,
            source: sourceReference.frame,
            temporal: temporalReference.frame
        )
        self.identity = identity
        self.authorization = authorization
        self.scalerIdentity = scalerIdentity
        self.modelIdentity = modelIdentity
        self.postScalerFrame = postScalerFrame
        self.ashApprovedMask = ashApprovedMask
        self.protectedMask = protectedMask
        self.limits = limits
        self.sourceReference = sourceReference
        self.temporalReference = temporalReference
        self.confidenceBudget = confidenceBudget
        self.resourceBudget = resourceBudget
        self.safetySignal = safetySignal
    }

    private static func validateGeometry(
        frame: R09PlanarFrameQ16,
        ashApprovedMask: R09PlanarMaskQ15,
        protectedMask: R09PlanarMaskQ15,
        edge: R09PlanarEdgeLimitsQ16,
        source: R09PlanarFrameQ16,
        temporal: R09PlanarFrameQ16
    ) throws {
        for id in R09ResidualPlaneID.allCases {
            let expected = frame[id]
            try R09ResidualValidation.geometry(
                role: "ash_approved_mask",
                plane: id,
                expected: expected,
                actualWidth: ashApprovedMask[id].width,
                actualHeight: ashApprovedMask[id].height
            )
            try R09ResidualValidation.geometry(
                role: "protected_mask",
                plane: id,
                expected: expected,
                actualWidth: protectedMask[id].width,
                actualHeight: protectedMask[id].height
            )
            try R09ResidualValidation.geometry(
                role: "edge_limit",
                plane: id,
                expected: expected,
                actualWidth: edge[id].width,
                actualHeight: edge[id].height
            )
            try R09ResidualValidation.geometry(
                role: "source_reference",
                plane: id,
                expected: expected,
                actualWidth: source[id].width,
                actualHeight: source[id].height
            )
            try R09ResidualValidation.geometry(
                role: "temporal_reference",
                plane: id,
                expected: expected,
                actualWidth: temporal[id].width,
                actualHeight: temporal[id].height
            )
        }
    }
}
