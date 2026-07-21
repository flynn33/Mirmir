import Foundation

enum R06ASHDecisionContextError: Error, Equatable, Sendable {
    case q16OutOfRange(Int64)
    case q15OutOfRange(Int64)
    case invalidIdentity(field: String)
    case invalidScale(numerator: Int, denominator: Int)
    case invalidContinuousFeatureCount(expected: Int, actual: Int)
    case invalidStateIntegrity(field: String)
    case invalidStateTransition
    case invalidDwellFrames(Int)
    case duplicatePostflightFinding(String)
}

struct R06ASHQ16: Comparable, Hashable, Sendable {
    static let scale: Int64 = 65_536
    static let zero = R06ASHQ16(validatedRawValue: 0)
    static let one = R06ASHQ16(validatedRawValue: scale)

    let rawValue: Int64

    init(_ rawValue: Int64) throws {
        guard (0...Self.scale).contains(rawValue) else {
            throw R06ASHDecisionContextError.q16OutOfRange(rawValue)
        }
        self.rawValue = rawValue
    }

    init(validatedRawValue: Int64) {
        precondition((0...Self.scale).contains(validatedRawValue))
        rawValue = validatedRawValue
    }

    static func < (lhs: R06ASHQ16, rhs: R06ASHQ16) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct R06ASHQ15: Comparable, Hashable, Sendable {
    static let maximum: Int64 = 32_767
    static let zero = R06ASHQ15(validatedRawValue: 0)
    static let one = R06ASHQ15(validatedRawValue: maximum)

    let rawValue: Int64

    init(_ rawValue: Int64) throws {
        guard (0...Self.maximum).contains(rawValue) else {
            throw R06ASHDecisionContextError.q15OutOfRange(rawValue)
        }
        self.rawValue = rawValue
    }

    init(validatedRawValue: Int64) {
        precondition((0...Self.maximum).contains(validatedRawValue))
        rawValue = validatedRawValue
    }

    static func < (lhs: R06ASHQ15, rhs: R06ASHQ15) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum R06ASHPlaneLayout: String, Equatable, Sendable {
    case nv12
}

enum R06ASHBackendAvailability: String, Equatable, Sendable {
    case available
    case unavailable
    case unknown
}

enum R06ASHModelReadiness: String, Equatable, Sendable {
    case notRequired = "not_required"
    case ready
    case unavailable
    case acquisitionFailed = "acquisition_failed"
}

enum R06ASHRetryEligibility: String, Equatable, Sendable {
    case eligible
    case ineligible
}

enum R06ASHFallbackReasonCode: String, Equatable, Sendable {
    case backendUnavailable = "backend_unavailable"
    case backendRejected = "backend_rejected"
    case backendFailed = "backend_failed"
}

struct R06ASHFallbackReason: Equatable, Sendable {
    let code: R06ASHFallbackReasonCode
    let failedBackendID: String

    init(code: R06ASHFallbackReasonCode, failedBackendID: String) throws {
        self.code = code
        self.failedBackendID = try R06ASHDecisionValidation.identity(
            failedBackendID,
            field: "fallback_reason.failed_backend_id"
        )
    }

    var fatalBackendID: String? {
        code == .backendFailed ? failedBackendID : nil
    }
}

struct R06ASHPostflightFinding: Equatable, Sendable {
    let id: String

    init(id: String) throws {
        self.id = try R06ASHDecisionValidation.identity(
            id,
            field: "postflight_findings.id"
        )
    }
}

struct R06ASHPostflightFindings: Equatable, Sendable {
    let riskQ16: R06ASHQ16
    let findings: [R06ASHPostflightFinding]

    init(riskQ16: R06ASHQ16, findings: [R06ASHPostflightFinding]) throws {
        var findingIDs: Set<String> = []
        for finding in findings where !findingIDs.insert(finding.id).inserted {
            throw R06ASHDecisionContextError.duplicatePostflightFinding(finding.id)
        }
        self.riskQ16 = riskQ16
        self.findings = findings
    }
}

struct R06ASHStateTransition: Equatable, Sendable {
    let message: ASHMessage

    init(previousState: ASHState, currentState: ASHState) throws {
        guard previousState.hasValidIntegrity else {
            throw R06ASHDecisionContextError.invalidStateIntegrity(field: "previous_state")
        }
        guard currentState.hasValidIntegrity else {
            throw R06ASHDecisionContextError.invalidStateIntegrity(field: "current_state")
        }
        let decoded = ASHCode.decodeAffine(received: currentState, anchor: previousState)
        guard decoded.status == .exact,
              let messageBits = decoded.messageBits,
              let message = try? ASHMessage(bits: messageBits) else {
            throw R06ASHDecisionContextError.invalidStateTransition
        }
        self.message = message
    }
}

struct R06ASHIdentityContext: Equatable, Sendable {
    let frameID: String
    let shotID: String
    let routeID: String
    let scaleNumerator: Int
    let scaleDenominator: Int
    let planeLayout: R06ASHPlaneLayout
    let chromaSiting: ASHChromaSitingV2

    init(
        frameID: String,
        shotID: String,
        routeID: String,
        scaleNumerator: Int,
        scaleDenominator: Int,
        planeLayout: R06ASHPlaneLayout,
        chromaSiting: ASHChromaSitingV2
    ) throws {
        guard scaleNumerator > 0, scaleDenominator > 0 else {
            throw R06ASHDecisionContextError.invalidScale(
                numerator: scaleNumerator,
                denominator: scaleDenominator
            )
        }
        self.frameID = try R06ASHDecisionValidation.identity(frameID, field: "frame_id")
        self.shotID = try R06ASHDecisionValidation.identity(shotID, field: "shot_id")
        self.routeID = try R06ASHDecisionValidation.identity(routeID, field: "route_id")
        self.scaleNumerator = scaleNumerator
        self.scaleDenominator = scaleDenominator
        self.planeLayout = planeLayout
        self.chromaSiting = chromaSiting
    }
}

struct R06ASHStateContext: Equatable, Sendable {
    let continuousFeatureValuesQ16: [R06ASHQ16]
    let currentState: ASHState
    let previousState: ASHState
    let stateTransition: R06ASHStateTransition
    let dwellFrames: Int

    init(
        continuousFeatureValuesQ16: [R06ASHQ16],
        currentState: ASHState,
        previousState: ASHState,
        stateTransition: R06ASHStateTransition,
        dwellFrames: Int
    ) throws {
        guard continuousFeatureValuesQ16.count == ASHState.payloadBitCount else {
            throw R06ASHDecisionContextError.invalidContinuousFeatureCount(
                expected: ASHState.payloadBitCount,
                actual: continuousFeatureValuesQ16.count
            )
        }
        guard currentState.hasValidIntegrity else {
            throw R06ASHDecisionContextError.invalidStateIntegrity(field: "current_state")
        }
        guard previousState.hasValidIntegrity else {
            throw R06ASHDecisionContextError.invalidStateIntegrity(field: "previous_state")
        }
        let expectedTransition = try R06ASHStateTransition(
            previousState: previousState,
            currentState: currentState
        )
        guard stateTransition == expectedTransition else {
            throw R06ASHDecisionContextError.invalidStateTransition
        }
        guard dwellFrames >= 0 else {
            throw R06ASHDecisionContextError.invalidDwellFrames(dwellFrames)
        }
        self.continuousFeatureValuesQ16 = continuousFeatureValuesQ16
        self.currentState = currentState
        self.previousState = previousState
        self.stateTransition = stateTransition
        self.dwellFrames = dwellFrames
    }
}

struct R06ASHSignalContext: Equatable, Sendable {
    let sceneCutConfidenceQ16: R06ASHQ16
    let motionConfidenceQ16: R06ASHQ16
    let occlusionConfidenceQ16: R06ASHQ16
    let noiseEstimateQ16: R06ASHQ16
    let blurEstimateQ16: R06ASHQ16
    let compressionEstimateQ16: R06ASHQ16
    let aliasingEstimateQ16: R06ASHQ16
}

struct R06ASHProtectionContext: Equatable, Sendable {
    let faceOccupancyQ15: R06ASHQ15
    let textOccupancyQ15: R06ASHQ15
    let lineArtOccupancyQ15: R06ASHQ15
    let animationOccupancyQ15: R06ASHQ15
    let uiOccupancyQ15: R06ASHQ15
}

struct R06ASHResourceContext: Equatable, Sendable {
    let backendAvailability: R06ASHBackendAvailability
    let modelReadiness: R06ASHModelReadiness
    let backendQualityConfidenceQ16: R06ASHQ16
    let memoryPressureQ16: R06ASHQ16
    let thermalPressureQ16: R06ASHQ16
    let throughputPressureQ16: R06ASHQ16
}

struct R06ASHBackendHistory: Equatable, Sendable {
    let currentBackendID: String?
    let previousBackendID: String?

    init(currentBackendID: String?, previousBackendID: String?) throws {
        self.currentBackendID = try R06ASHDecisionValidation.optionalIdentity(
            currentBackendID,
            field: "current_backend_id"
        )
        self.previousBackendID = try R06ASHDecisionValidation.optionalIdentity(
            previousBackendID,
            field: "previous_backend_id"
        )
    }
}

struct R06ASHEffectContext: Equatable, Sendable {
    let preprocessStrengthQ16: R06ASHQ16
    let postprocessStrengthQ16: R06ASHQ16
    let artifactRiskQ16: R06ASHQ16
}

struct R06ASHOutcomeContext: Equatable, Sendable {
    let postflightFindings: R06ASHPostflightFindings
    let fallbackReason: R06ASHFallbackReason?
    let retryEligibility: R06ASHRetryEligibility
}

struct ASHDecisionContext: Equatable, Sendable {
    static let version = "r06.v1"

    let frameID: String
    let shotID: String
    let routeID: String
    let scaleNumerator: Int
    let scaleDenominator: Int
    let planeLayout: R06ASHPlaneLayout
    let chromaSiting: ASHChromaSitingV2
    let continuousFeatureValuesQ16: [R06ASHQ16]
    let currentState: ASHState
    let previousState: ASHState
    let stateTransition: R06ASHStateTransition
    let dwellFrames: Int
    let sceneCutConfidenceQ16: R06ASHQ16
    let motionConfidenceQ16: R06ASHQ16
    let occlusionConfidenceQ16: R06ASHQ16
    let noiseEstimateQ16: R06ASHQ16
    let blurEstimateQ16: R06ASHQ16
    let compressionEstimateQ16: R06ASHQ16
    let aliasingEstimateQ16: R06ASHQ16
    let faceOccupancyQ15: R06ASHQ15
    let textOccupancyQ15: R06ASHQ15
    let lineArtOccupancyQ15: R06ASHQ15
    let animationOccupancyQ15: R06ASHQ15
    let uiOccupancyQ15: R06ASHQ15
    let backendAvailability: R06ASHBackendAvailability
    let modelReadiness: R06ASHModelReadiness
    let backendQualityConfidenceQ16: R06ASHQ16
    let memoryPressureQ16: R06ASHQ16
    let thermalPressureQ16: R06ASHQ16
    let throughputPressureQ16: R06ASHQ16
    let currentBackendID: String?
    let previousBackendID: String?
    let preprocessStrengthQ16: R06ASHQ16
    let postprocessStrengthQ16: R06ASHQ16
    let artifactRiskQ16: R06ASHQ16
    let postflightFindings: R06ASHPostflightFindings
    let fallbackReason: R06ASHFallbackReason?
    let retryEligibility: R06ASHRetryEligibility

    init(
        identity: R06ASHIdentityContext,
        state: R06ASHStateContext,
        signals: R06ASHSignalContext,
        protection: R06ASHProtectionContext,
        resources: R06ASHResourceContext,
        backendHistory: R06ASHBackendHistory,
        effects: R06ASHEffectContext,
        outcome: R06ASHOutcomeContext
    ) {
        frameID = identity.frameID
        shotID = identity.shotID
        routeID = identity.routeID
        scaleNumerator = identity.scaleNumerator
        scaleDenominator = identity.scaleDenominator
        planeLayout = identity.planeLayout
        chromaSiting = identity.chromaSiting
        continuousFeatureValuesQ16 = state.continuousFeatureValuesQ16
        currentState = state.currentState
        previousState = state.previousState
        stateTransition = state.stateTransition
        dwellFrames = state.dwellFrames
        sceneCutConfidenceQ16 = signals.sceneCutConfidenceQ16
        motionConfidenceQ16 = signals.motionConfidenceQ16
        occlusionConfidenceQ16 = signals.occlusionConfidenceQ16
        noiseEstimateQ16 = signals.noiseEstimateQ16
        blurEstimateQ16 = signals.blurEstimateQ16
        compressionEstimateQ16 = signals.compressionEstimateQ16
        aliasingEstimateQ16 = signals.aliasingEstimateQ16
        faceOccupancyQ15 = protection.faceOccupancyQ15
        textOccupancyQ15 = protection.textOccupancyQ15
        lineArtOccupancyQ15 = protection.lineArtOccupancyQ15
        animationOccupancyQ15 = protection.animationOccupancyQ15
        uiOccupancyQ15 = protection.uiOccupancyQ15
        backendAvailability = resources.backendAvailability
        modelReadiness = resources.modelReadiness
        backendQualityConfidenceQ16 = resources.backendQualityConfidenceQ16
        memoryPressureQ16 = resources.memoryPressureQ16
        thermalPressureQ16 = resources.thermalPressureQ16
        throughputPressureQ16 = resources.throughputPressureQ16
        currentBackendID = backendHistory.currentBackendID
        previousBackendID = backendHistory.previousBackendID
        preprocessStrengthQ16 = effects.preprocessStrengthQ16
        postprocessStrengthQ16 = effects.postprocessStrengthQ16
        artifactRiskQ16 = effects.artifactRiskQ16
        postflightFindings = outcome.postflightFindings
        fallbackReason = outcome.fallbackReason
        retryEligibility = outcome.retryEligibility
    }

    var message: ASHMessage {
        stateTransition.message
    }

    var fatalBackendID: String? {
        fallbackReason?.fatalBackendID
    }

    var postflightRiskQ16: R06ASHQ16 {
        postflightFindings.riskQ16
    }
}

private enum R06ASHDecisionValidation {
    static func identity(_ value: String, field: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed == value else {
            throw R06ASHDecisionContextError.invalidIdentity(field: field)
        }
        return value
    }

    static func optionalIdentity(_ value: String?, field: String) throws -> String? {
        guard let value else { return nil }
        return try identity(value, field: field)
    }
}
