import Foundation

public enum UpscaleMode: String, CaseIterable, Hashable, Identifiable, Sendable {
    case auto
    case quality
    case fast
    case deterministic

    public var id: String { rawValue }
}

struct R13ReleaseModeBinding: Hashable, Sendable {
    let requestedMode: UpscaleMode
    let effectiveMode: UpscaleMode
    let capabilityID: String
    let backendID: String
    let backendRevision: String
    let policyIdentity: String
    let materialDecisionIdentity: String

    init(requestedMode: UpscaleMode) throws {
        guard requestedMode != .auto else {
            throw UpscalerEngineError.modeUnavailable(
                mode: requestedMode,
                reason: R13ReleaseModePolicy.autoUnavailableReason
            )
        }
        self.requestedMode = requestedMode
        effectiveMode = .deterministic
        capabilityID = R03A11ProductAdmission.capabilityID
        backendID = R03A11ProductAdmission.subjectID.rawValue
        backendRevision = R03DeterministicBackendCatalog.backendRevision
        policyIdentity = R03A11ProductAdmission.policyIdentity
        materialDecisionIdentity = R03A11ProductAdmission.materialDecisionIdentity
    }
}

enum R13ReleaseModePolicy {
    static let autoUnavailableReason =
        "Auto mode is visible but is not release-qualified. Choose Quality, Fast, or Deterministic."

    static func availability(
        for mode: UpscaleMode
    ) -> UpscalerEngineAvailability {
        switch mode {
        case .auto:
            return .unavailable(reason: autoUnavailableReason)
        case .quality, .fast, .deterministic:
            return .available
        }
    }

    static func binding(for mode: UpscaleMode) throws -> R13ReleaseModeBinding {
        try R13ReleaseModeBinding(requestedMode: mode)
    }
}
