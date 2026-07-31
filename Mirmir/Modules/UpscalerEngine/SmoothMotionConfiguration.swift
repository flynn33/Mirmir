import Foundation

public enum SmoothMotionCadence:
    String,
    CaseIterable,
    Codable,
    Hashable,
    Identifiable,
    Sendable {
    case double = "2x"
    case quadruple = "4x"

    public var id: String { rawValue }

    var multiplier: Int {
        switch self {
        case .double:
            return 2
        case .quadruple:
            return 4
        }
    }

    var interpolationPhases: [Float] {
        (1..<multiplier).map {
            Float($0) / Float(multiplier)
        }
    }

    var videoToolboxInterpolationLevel: Int {
        switch self {
        case .double:
            return 1
        case .quadruple:
            return 2
        }
    }
}

public enum SmoothMotionSceneCutSensitivity:
    String,
    CaseIterable,
    Codable,
    Hashable,
    Identifiable,
    Sendable {
    case low
    case standard
    case high

    public var id: String { rawValue }

    var normalizedDifferenceThreshold: Double {
        switch self {
        case .low:
            return 0.30
        case .standard:
            return 0.22
        case .high:
            return 0.15
        }
    }
}

public struct SmoothMotionConfiguration:
    Codable,
    Equatable,
    Hashable,
    Sendable {
    public let cadence: SmoothMotionCadence
    public let sceneCutSensitivity: SmoothMotionSceneCutSensitivity

    public init(
        cadence: SmoothMotionCadence = .double,
        sceneCutSensitivity: SmoothMotionSceneCutSensitivity = .standard
    ) {
        self.cadence = cadence
        self.sceneCutSensitivity = sceneCutSensitivity
    }

    public static let `default` = SmoothMotionConfiguration()

    var identityComponents: [String] {
        [
            "smooth-motion-\(cadence.rawValue)",
            "scene-cut-\(sceneCutSensitivity.rawValue)",
            "route-native-preferred-deterministic-fallback"
        ]
    }
}
