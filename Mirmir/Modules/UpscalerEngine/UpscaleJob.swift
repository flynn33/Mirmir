import Foundation

public enum UpscaleEnginePreference:
    String,
    CaseIterable,
    Codable,
    Hashable,
    Identifiable,
    Sendable {
    case automatic
    case accelerateVImageStandard = "accelerate_vimage_standard"
    case accelerateVImageHighQuality = "accelerate_vimage_high_quality"
    case mpsBilinear = "mps_bilinear"
    case mpsLanczos = "mps_lanczos"
    case coreImageLanczos = "core_image_lanczos"
    case coreImageBicubic = "core_image_bicubic"
    case videoToolboxPixelTransfer = "videotoolbox_pixel_transfer"
    case videoToolboxQuality = "videotoolbox_quality"
    case videoToolboxLowLatency = "videotoolbox_low_latency"
    case metalFXSpatial = "metalfx_spatial"

    public var id: String { rawValue }

    var requiresNativeUpscaleSession: Bool {
        switch self {
        case .videoToolboxQuality,
             .videoToolboxLowLatency,
             .metalFXSpatial:
            return true
        case .automatic,
             .accelerateVImageStandard,
             .accelerateVImageHighQuality,
             .mpsBilinear,
             .mpsLanczos,
             .coreImageLanczos,
             .coreImageBicubic,
             .videoToolboxPixelTransfer:
            return false
        }
    }
}

public enum UpscaleStrategyPreference:
    String,
    CaseIterable,
    Codable,
    Hashable,
    Identifiable,
    Sendable {
    case automatic
    case direct
    case adaptive

    public var id: String { rawValue }
}

public enum MirmirAdjustmentLevel:
    String,
    CaseIterable,
    Codable,
    Hashable,
    Identifiable,
    Sendable {
    case low
    case medium
    case high

    public var id: String { rawValue }
}

public struct UpscaleEffectConfiguration:
    Codable,
    Equatable,
    Hashable,
    Sendable {
    public let edgePreservationEnabled: Bool
    public let compressionCleanupEnabled: Bool
    public let textureGrainProtectionEnabled: Bool
    public let temporalStabilityEnabled: Bool

    public init(
        edgePreservationEnabled: Bool = false,
        compressionCleanupEnabled: Bool = false,
        textureGrainProtectionEnabled: Bool = false,
        temporalStabilityEnabled: Bool = false
    ) {
        self.edgePreservationEnabled = edgePreservationEnabled
        self.compressionCleanupEnabled = compressionCleanupEnabled
        self.textureGrainProtectionEnabled =
            textureGrainProtectionEnabled
        self.temporalStabilityEnabled = temporalStabilityEnabled
    }

    public static let `default` = UpscaleEffectConfiguration()

    var isDefault: Bool {
        self == .default
    }

    var identityComponents: [String] {
        [
            "edge-preservation-\(edgePreservationEnabled ? "on" : "off")",
            "compression-cleanup-\(compressionCleanupEnabled ? "on" : "off")",
            "texture-grain-protection-"
                + "\(textureGrainProtectionEnabled ? "on" : "off")",
            "temporal-stability-\(temporalStabilityEnabled ? "on" : "off")"
        ]
    }
}

public struct UpscaleProcessingConfiguration:
    Codable,
    Equatable,
    Hashable,
    Sendable {
    public let enginePreference: UpscaleEnginePreference
    public let strategyPreference: UpscaleStrategyPreference
    public let temporalConsistencyEnabled: Bool
    public let edgeFidelityLevel: MirmirAdjustmentLevel
    public let detailRecoveryLevel: MirmirAdjustmentLevel
    public let effects: UpscaleEffectConfiguration
    public let smoothMotion: SmoothMotionConfiguration

    public init(
        enginePreference: UpscaleEnginePreference = .automatic,
        strategyPreference: UpscaleStrategyPreference = .automatic,
        temporalConsistencyEnabled: Bool = true,
        edgeFidelityLevel: MirmirAdjustmentLevel = .medium,
        detailRecoveryLevel: MirmirAdjustmentLevel = .medium,
        effects: UpscaleEffectConfiguration = .default,
        smoothMotion: SmoothMotionConfiguration = .default
    ) {
        self.enginePreference = enginePreference
        self.strategyPreference = strategyPreference
        self.temporalConsistencyEnabled =
            temporalConsistencyEnabled
        self.edgeFidelityLevel = edgeFidelityLevel
        self.detailRecoveryLevel = detailRecoveryLevel
        self.effects = effects
        self.smoothMotion = smoothMotion
    }

    public static let `default` = UpscaleProcessingConfiguration()

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(
            keyedBy: CodingKeys.self
        )
        enginePreference = try container.decode(
            UpscaleEnginePreference.self,
            forKey: .enginePreference
        )
        strategyPreference = try container.decode(
            UpscaleStrategyPreference.self,
            forKey: .strategyPreference
        )
        temporalConsistencyEnabled = try container.decode(
            Bool.self,
            forKey: .temporalConsistencyEnabled
        )
        edgeFidelityLevel = try container.decode(
            MirmirAdjustmentLevel.self,
            forKey: .edgeFidelityLevel
        )
        detailRecoveryLevel = try container.decode(
            MirmirAdjustmentLevel.self,
            forKey: .detailRecoveryLevel
        )
        effects = try container.decodeIfPresent(
            UpscaleEffectConfiguration.self,
            forKey: .effects
        ) ?? .default
        smoothMotion = try container.decodeIfPresent(
            SmoothMotionConfiguration.self,
            forKey: .smoothMotion
        ) ?? .default
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(
            enginePreference,
            forKey: .enginePreference
        )
        try container.encode(
            strategyPreference,
            forKey: .strategyPreference
        )
        try container.encode(
            temporalConsistencyEnabled,
            forKey: .temporalConsistencyEnabled
        )
        try container.encode(
            edgeFidelityLevel,
            forKey: .edgeFidelityLevel
        )
        try container.encode(
            detailRecoveryLevel,
            forKey: .detailRecoveryLevel
        )
        try container.encode(effects, forKey: .effects)
        try container.encode(smoothMotion, forKey: .smoothMotion)
    }

    var identity: String {
        let existingComponents = [
            "r13.processing.v1",
            "engine-\(enginePreference.rawValue)",
            "strategy-\(strategyPreference.rawValue)",
            "temporal-\(temporalConsistencyEnabled ? "on" : "off")",
            "edge-\(edgeFidelityLevel.rawValue)",
            "detail-\(detailRecoveryLevel.rawValue)"
        ]
        guard !effects.isDefault || smoothMotion != .default else {
            return existingComponents.joined(separator: ".")
        }
        if smoothMotion == .default {
            return (
                ["r13.processing.v2"]
                    + existingComponents.dropFirst()
                    + effects.identityComponents
            ).joined(separator: ".")
        }
        return (
            ["r13.processing.v3"]
                + existingComponents.dropFirst()
                + effects.identityComponents
                + smoothMotion.identityComponents
        ).joined(separator: ".")
    }

    private enum CodingKeys: String, CodingKey {
        case enginePreference
        case strategyPreference
        case temporalConsistencyEnabled
        case edgeFidelityLevel
        case detailRecoveryLevel
        case effects
        case smoothMotion
    }
}

public struct UpscaleJob: Sendable {
    public let identifier: String
    public let inputURL: URL
    public let outputURL: URL
    public let targetResolution: VideoResolution
    public let codec: OutputCodec
    public let preserveAudio: Bool
    public let mode: UpscaleMode
    public let processingConfiguration: UpscaleProcessingConfiguration

    public init(
        identifier: String = UUID().uuidString,
        inputURL: URL,
        outputURL: URL,
        targetResolution: VideoResolution,
        codec: OutputCodec = .hevc,
        preserveAudio: Bool = true,
        mode: UpscaleMode = .deterministic,
        processingConfiguration: UpscaleProcessingConfiguration = .default
    ) {
        self.identifier = identifier
        self.inputURL = inputURL
        self.outputURL = outputURL
        self.targetResolution = targetResolution
        self.codec = codec
        self.preserveAudio = preserveAudio
        self.mode = mode
        self.processingConfiguration = processingConfiguration
    }
}

public struct UpscaleProgress: Sendable, Equatable {
    public let framesProcessed: Int
    public let totalFrames: Int
    public let throughputFPS: Double
    public let etaSeconds: Double?

    public init(framesProcessed: Int, totalFrames: Int, throughputFPS: Double, etaSeconds: Double?) {
        self.framesProcessed = framesProcessed
        self.totalFrames = totalFrames
        self.throughputFPS = throughputFPS
        self.etaSeconds = etaSeconds
    }

    public var fraction: Double {
        guard totalFrames > 0 else { return 0 }
        return min(1, max(0, Double(framesProcessed) / Double(totalFrames)))
    }
}

enum FileURLIdentity {
    static func refersToSameFile(
        _ lhs: URL,
        _ rhs: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        let normalizedLHS = lhs.resolvingSymlinksInPath().standardizedFileURL
        let normalizedRHS = rhs.resolvingSymlinksInPath().standardizedFileURL

        guard normalizedLHS.isFileURL, normalizedRHS.isFileURL else {
            return normalizedLHS == normalizedRHS
        }
        if normalizedLHS.path == normalizedRHS.path {
            return true
        }

        guard
            let lhsAttributes = try? fileManager.attributesOfItem(atPath: normalizedLHS.path),
            let rhsAttributes = try? fileManager.attributesOfItem(atPath: normalizedRHS.path),
            let lhsDevice = lhsAttributes[.systemNumber] as? NSNumber,
            let rhsDevice = rhsAttributes[.systemNumber] as? NSNumber,
            let lhsFile = lhsAttributes[.systemFileNumber] as? NSNumber,
            let rhsFile = rhsAttributes[.systemFileNumber] as? NSNumber
        else {
            return false
        }

        return lhsDevice == rhsDevice && lhsFile == rhsFile
    }
}
