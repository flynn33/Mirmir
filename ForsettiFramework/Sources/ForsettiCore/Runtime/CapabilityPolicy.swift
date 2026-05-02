import Foundation

public enum CapabilityPolicyDecision: Sendable {
    case allowed
    case denied(reason: String)
}

public protocol CapabilityPolicy: Sendable {
    func evaluate(moduleID: String, capability: Capability) -> CapabilityPolicyDecision
}

public struct AllowAllCapabilityPolicy: CapabilityPolicy {
    public init() {}

    public func evaluate(moduleID: String, capability: Capability) -> CapabilityPolicyDecision {
        .allowed
    }
}

public struct FixedCapabilityPolicy: CapabilityPolicy {
    private let allowedCapabilities: Set<Capability>

    public init(allowedCapabilities: Set<Capability>) {
        self.allowedCapabilities = allowedCapabilities
    }

    public func evaluate(moduleID: String, capability: Capability) -> CapabilityPolicyDecision {
        if allowedCapabilities.contains(capability) {
            return .allowed
        }
        return .denied(reason: "Capability \(capability.rawValue) is not enabled for this build.")
    }
}
