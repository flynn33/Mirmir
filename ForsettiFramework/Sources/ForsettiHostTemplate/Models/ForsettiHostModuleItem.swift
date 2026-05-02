import Foundation
import ForsettiCore

public enum ForsettiHostModuleAvailability: Equatable, Sendable {
    case eligible
    case locked(productID: String?)
    case incompatible(issues: [CompatibilityIssue])

    public var userFacingReason: String? {
        switch self {
        case .eligible:
            return nil
        case let .locked(productID):
            if let productID {
                return "Locked. Requires purchase (\(productID))."
            }
            return "Locked by entitlement policy."
        case let .incompatible(issues):
            return issues.map(\.message).joined(separator: " ")
        }
    }
}

public struct ForsettiHostModuleItem: Identifiable, Hashable, Sendable {
    public let manifest: ModuleManifest
    public let compatibilityReport: CompatibilityReport
    public let isUnlocked: Bool
    public let isActive: Bool

    public init(
        manifest: ModuleManifest,
        compatibilityReport: CompatibilityReport,
        isUnlocked: Bool,
        isActive: Bool
    ) {
        self.manifest = manifest
        self.compatibilityReport = compatibilityReport
        self.isUnlocked = isUnlocked
        self.isActive = isActive
    }

    public var id: String { manifest.moduleID }
    public var moduleID: String { manifest.moduleID }
    public var displayName: String { manifest.displayName }
    public var moduleType: ModuleType { manifest.moduleType }

    public var availability: ForsettiHostModuleAvailability {
        if !compatibilityReport.isCompatible {
            return .incompatible(issues: compatibilityReport.issues)
        }

        if !isUnlocked {
            return .locked(productID: manifest.iapProductID)
        }

        return .eligible
    }

    public var canActivate: Bool {
        if case .eligible = availability {
            return true
        }
        return false
    }
}
