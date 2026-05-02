import Foundation

public enum CompatibilitySeverity: String, Sendable {
    case info
    case warning
    case error
}

public enum CompatibilityIssueCode: String, Sendable {
    case invalidSchemaVersion
    case unsupportedPlatform
    case unsupportedForsettiVersion
    case capabilityDenied
}

public struct CompatibilityIssue: Sendable, Hashable {
    public let code: CompatibilityIssueCode
    public let severity: CompatibilitySeverity
    public let message: String

    public init(code: CompatibilityIssueCode, severity: CompatibilitySeverity, message: String) {
        self.code = code
        self.severity = severity
        self.message = message
    }
}

public struct CompatibilityReport: Sendable, Hashable {
    public let moduleID: String
    public let issues: [CompatibilityIssue]

    public init(moduleID: String, issues: [CompatibilityIssue]) {
        self.moduleID = moduleID
        self.issues = issues
    }

    public var isCompatible: Bool {
        !issues.contains { $0.severity == .error }
    }
}

public final class CompatibilityChecker {
    private let runtimePlatform: Platform
    private let forsettiVersion: SemVer
    private let capabilityPolicy: any CapabilityPolicy

    public init(
        runtimePlatform: Platform,
        forsettiVersion: SemVer,
        capabilityPolicy: any CapabilityPolicy
    ) {
        self.runtimePlatform = runtimePlatform
        self.forsettiVersion = forsettiVersion
        self.capabilityPolicy = capabilityPolicy
    }

    public func evaluate(manifest: ModuleManifest) -> CompatibilityReport {
        var issues: [CompatibilityIssue] = []

        if manifest.schemaVersion != ModuleManifest.supportedSchemaVersion {
            issues.append(
                CompatibilityIssue(
                    code: .invalidSchemaVersion,
                    severity: .error,
                    message: "Unsupported schema \(manifest.schemaVersion). Expected \(ModuleManifest.supportedSchemaVersion)."
                )
            )
        }

        if !manifest.supportedPlatforms.contains(runtimePlatform) {
            issues.append(
                CompatibilityIssue(
                    code: .unsupportedPlatform,
                    severity: .error,
                    message: "Module does not support runtime platform \(runtimePlatform.rawValue)."
                )
            )
        }

        if manifest.minForsettiVersion > forsettiVersion {
            issues.append(
                CompatibilityIssue(
                    code: .unsupportedForsettiVersion,
                    severity: .error,
                    message: "Requires Forsetti >= \(manifest.minForsettiVersion.description), current is \(forsettiVersion.description)."
                )
            )
        }

        if let maxForsettiVersion = manifest.maxForsettiVersion, maxForsettiVersion < forsettiVersion {
            issues.append(
                CompatibilityIssue(
                    code: .unsupportedForsettiVersion,
                    severity: .error,
                    message: "Supports Forsetti <= \(maxForsettiVersion.description), current is \(forsettiVersion.description)."
                )
            )
        }

        manifest.capabilitiesRequested.forEach { capability in
            if capability == .uiThemeMask {
                issues.append(
                    CompatibilityIssue(
                        code: .capabilityDenied,
                        severity: .error,
                        message: "Capability \(capability.rawValue) is reserved for the Forsetti framework shell."
                    )
                )
                return
            }

            let decision = capabilityPolicy.evaluate(moduleID: manifest.moduleID, capability: capability)
            if case let .denied(reason) = decision {
                issues.append(
                    CompatibilityIssue(
                        code: .capabilityDenied,
                        severity: .error,
                        message: "Capability \(capability.rawValue) denied. \(reason)"
                    )
                )
            }
        }

        return CompatibilityReport(moduleID: manifest.moduleID, issues: issues)
    }
}
