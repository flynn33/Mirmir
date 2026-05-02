import Foundation

public enum Platform: String, Codable, CaseIterable, Sendable {
    case iOS
    case macOS

    public static var current: Platform {
        #if os(iOS)
        return .iOS
        #elseif os(macOS)
        return .macOS
        #else
        fatalError("Forsetti supports only iOS and macOS")
        #endif
    }
}

public enum Capability: String, Codable, CaseIterable, Hashable, Sendable {
    case networking
    case storage
    case secureStorage = "secure_storage"
    case fileExport = "file_export"
    case cryptoUtilities = "crypto_utilities"
    case telemetry
    case routingOverlay = "routing_overlay"
    case uiThemeMask = "ui_theme_mask"
    case toolbarItems = "toolbar_items"
    case viewInjection = "view_injection"
}

public enum ModuleType: String, Codable, Sendable {
    case service
    case ui
    /// A complete single-application module that includes its own UI.
    case app
}

public struct ModuleDescriptor: Codable, Hashable, Sendable {
    public let moduleID: String
    public let displayName: String
    public let moduleVersion: SemVer
    public let moduleType: ModuleType

    public init(
        moduleID: String,
        displayName: String,
        moduleVersion: SemVer,
        moduleType: ModuleType
    ) {
        self.moduleID = moduleID
        self.displayName = displayName
        self.moduleVersion = moduleVersion
        self.moduleType = moduleType
    }
}

public struct ModuleManifest: Codable, Hashable, Sendable {
    public static let supportedSchemaVersion = "1.0"

    public let schemaVersion: String
    public let moduleID: String
    public let displayName: String
    public let moduleVersion: SemVer
    public let moduleType: ModuleType
    public let supportedPlatforms: [Platform]
    public let minForsettiVersion: SemVer
    public let maxForsettiVersion: SemVer?
    public let capabilitiesRequested: [Capability]
    public let iapProductID: String?
    public let entryPoint: String

    public init(
        schemaVersion: String,
        moduleID: String,
        displayName: String,
        moduleVersion: SemVer,
        moduleType: ModuleType,
        supportedPlatforms: [Platform],
        minForsettiVersion: SemVer,
        maxForsettiVersion: SemVer? = nil,
        capabilitiesRequested: [Capability],
        iapProductID: String? = nil,
        entryPoint: String
    ) {
        self.schemaVersion = schemaVersion
        self.moduleID = moduleID
        self.displayName = displayName
        self.moduleVersion = moduleVersion
        self.moduleType = moduleType
        self.supportedPlatforms = supportedPlatforms
        self.minForsettiVersion = minForsettiVersion
        self.maxForsettiVersion = maxForsettiVersion
        self.capabilitiesRequested = capabilitiesRequested
        self.iapProductID = iapProductID
        self.entryPoint = entryPoint
    }
}
