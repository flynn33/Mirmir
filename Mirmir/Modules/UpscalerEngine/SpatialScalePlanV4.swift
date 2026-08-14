import Foundation

enum SpatialScalePlanV4Error: Error, Equatable, Sendable {
    case nonPositiveExtent(axis: SpatialAxisV4, source: Int, target: Int)
    case extentExceedsLimit(axis: SpatialAxisV4, value: Int, limit: Int)
    case downscalingIsNotAdmitted(axis: SpatialAxisV4, source: Int, target: Int)
    case arithmeticOverflow
    case nonCanonicalSerializedPlan(axis: SpatialAxisV4)
    case nonCanonicalTwoDimensionalPlan
}

enum SpatialAxisV4: String, Codable, Hashable, Sendable {
    case horizontal
    case vertical
}

enum SpatialBorderRuleV4: String, Codable, Hashable, Sendable {
    case clamp
    case reflect101
}

/// Exact source-center position for one destination sample. The coordinate is
/// `sourceBase + phase`, where `phase` is always reduced and lies in `[0, 1)`.
struct SpatialSamplePositionV4: Codable, Equatable, Hashable, Sendable {
    let destinationIndex: Int
    let sourceBase: Int
    let phase: ExactRationalV4

    init(
        destinationIndex: Int,
        sourceBase: Int,
        phase: ExactRationalV4
    ) {
        precondition(destinationIndex >= 0)
        precondition(phase >= .zero && phase < .one)
        self.destinationIndex = destinationIndex
        self.sourceBase = sourceBase
        self.phase = phase
    }

    func sourceCenterCoordinate() throws -> ExactRationalV4 {
        try ExactRationalV4(Int64(sourceBase)).adding(phase)
    }
}

/// Immutable per-axis coordinate plan for arbitrary rational upscaling.
///
/// For destination center `j`, the exact source-center coordinate is:
///
///     ((2*j + 1) * sourceExtent - targetExtent) / (2 * targetExtent)
///
/// The initializer decomposes that rational into a mathematical floor and a
/// nonnegative reduced phase. CPU and Metal artifact generation therefore see
/// identical coordinates without performing floating-point division.
struct SpatialAxisScalePlanV4: Codable, Equatable, Hashable, Sendable {
    static let schemaVersion = 1
    static let maximumSupportedExtent = 65_536

    let axis: SpatialAxisV4
    let sourceExtent: Int
    let targetExtent: Int
    let scale: ExactRationalV4
    let borderRule: SpatialBorderRuleV4
    let positions: [SpatialSamplePositionV4]
    let uniquePhases: [ExactRationalV4]

    init(
        axis: SpatialAxisV4,
        sourceExtent: Int,
        targetExtent: Int,
        borderRule: SpatialBorderRuleV4 = .clamp
    ) throws {
        guard sourceExtent > 0, targetExtent > 0 else {
            throw SpatialScalePlanV4Error.nonPositiveExtent(
                axis: axis,
                source: sourceExtent,
                target: targetExtent
            )
        }
        for value in [sourceExtent, targetExtent]
            where value > Self.maximumSupportedExtent {
            throw SpatialScalePlanV4Error.extentExceedsLimit(
                axis: axis,
                value: value,
                limit: Self.maximumSupportedExtent
            )
        }
        guard targetExtent >= sourceExtent else {
            throw SpatialScalePlanV4Error.downscalingIsNotAdmitted(
                axis: axis,
                source: sourceExtent,
                target: targetExtent
            )
        }

        let source64 = Int64(sourceExtent)
        let target64 = Int64(targetExtent)
        let (coordinateDenominator, denominatorOverflow) = target64
            .multipliedReportingOverflow(by: 2)
        guard !denominatorOverflow else {
            throw SpatialScalePlanV4Error.arithmeticOverflow
        }

        var positions: [SpatialSamplePositionV4] = []
        positions.reserveCapacity(targetExtent)
        var phases = Set<ExactRationalV4>()
        phases.reserveCapacity(targetExtent)

        for destinationIndex in 0..<targetExtent {
            let destination64 = Int64(destinationIndex)
            let (doubledIndex, doubledOverflow) = destination64
                .multipliedReportingOverflow(by: 2)
            let (oddCenter, centerOverflow) = doubledIndex
                .addingReportingOverflow(1)
            let (scaledCenter, productOverflow) = oddCenter
                .multipliedReportingOverflow(by: source64)
            let (coordinateNumerator, subtractionOverflow) = scaledCenter
                .subtractingReportingOverflow(target64)
            guard !doubledOverflow,
                  !centerOverflow,
                  !productOverflow,
                  !subtractionOverflow else {
                throw SpatialScalePlanV4Error.arithmeticOverflow
            }

            let decomposition = Self.floorDividing(
                coordinateNumerator,
                by: coordinateDenominator
            )
            guard let sourceBase = Int(exactly: decomposition.quotient) else {
                throw SpatialScalePlanV4Error.arithmeticOverflow
            }
            let phase = try ExactRationalV4(
                decomposition.remainder,
                coordinateDenominator
            )
            positions.append(
                SpatialSamplePositionV4(
                    destinationIndex: destinationIndex,
                    sourceBase: sourceBase,
                    phase: phase
                )
            )
            phases.insert(phase)
        }

        self.axis = axis
        self.sourceExtent = sourceExtent
        self.targetExtent = targetExtent
        self.scale = try ExactRationalV4(target64, source64)
        self.borderRule = borderRule
        self.positions = positions
        self.uniquePhases = phases.sorted()
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case axis
        case sourceExtent
        case targetExtent
        case scale
        case borderRule
        case positions
        case uniquePhases
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        let axis = try container.decode(SpatialAxisV4.self, forKey: .axis)
        guard version == Self.schemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported spatial scale plan schema."
            )
        }

        let sourceExtent = try container.decode(Int.self, forKey: .sourceExtent)
        let targetExtent = try container.decode(Int.self, forKey: .targetExtent)
        let borderRule = try container.decode(
            SpatialBorderRuleV4.self,
            forKey: .borderRule
        )
        let rebuilt = try SpatialAxisScalePlanV4(
            axis: axis,
            sourceExtent: sourceExtent,
            targetExtent: targetExtent,
            borderRule: borderRule
        )
        let encodedScale = try container.decode(
            ExactRationalV4.self,
            forKey: .scale
        )
        let encodedPositions = try container.decode(
            [SpatialSamplePositionV4].self,
            forKey: .positions
        )
        let encodedPhases = try container.decode(
            [ExactRationalV4].self,
            forKey: .uniquePhases
        )
        guard encodedScale == rebuilt.scale,
              encodedPositions == rebuilt.positions,
              encodedPhases == rebuilt.uniquePhases else {
            throw SpatialScalePlanV4Error.nonCanonicalSerializedPlan(axis: axis)
        }
        self = rebuilt
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.schemaVersion, forKey: .schemaVersion)
        try container.encode(axis, forKey: .axis)
        try container.encode(sourceExtent, forKey: .sourceExtent)
        try container.encode(targetExtent, forKey: .targetExtent)
        try container.encode(scale, forKey: .scale)
        try container.encode(borderRule, forKey: .borderRule)
        try container.encode(positions, forKey: .positions)
        try container.encode(uniquePhases, forKey: .uniquePhases)
    }

    private static func floorDividing(
        _ numerator: Int64,
        by positiveDenominator: Int64
    ) -> (quotient: Int64, remainder: Int64) {
        precondition(positiveDenominator > 0)
        var quotient = numerator / positiveDenominator
        var remainder = numerator % positiveDenominator
        if remainder < 0 {
            quotient -= 1
            remainder += positiveDenominator
        }
        return (quotient, remainder)
    }
}

struct SpatialScalePlanV4: Codable, Equatable, Hashable, Sendable {
    static let schemaVersion = 1

    let horizontal: SpatialAxisScalePlanV4
    let vertical: SpatialAxisScalePlanV4

    init(
        sourceWidth: Int,
        sourceHeight: Int,
        targetWidth: Int,
        targetHeight: Int,
        borderRule: SpatialBorderRuleV4 = .clamp
    ) throws {
        self.horizontal = try SpatialAxisScalePlanV4(
            axis: .horizontal,
            sourceExtent: sourceWidth,
            targetExtent: targetWidth,
            borderRule: borderRule
        )
        self.vertical = try SpatialAxisScalePlanV4(
            axis: .vertical,
            sourceExtent: sourceHeight,
            targetExtent: targetHeight,
            borderRule: borderRule
        )
    }

    var sourceWidth: Int { horizontal.sourceExtent }
    var sourceHeight: Int { vertical.sourceExtent }
    var targetWidth: Int { horizontal.targetExtent }
    var targetHeight: Int { vertical.targetExtent }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case horizontal
        case vertical
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        guard version == Self.schemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported two-dimensional scale-plan schema."
            )
        }
        let horizontal = try container.decode(
            SpatialAxisScalePlanV4.self,
            forKey: .horizontal
        )
        let vertical = try container.decode(
            SpatialAxisScalePlanV4.self,
            forKey: .vertical
        )
        guard horizontal.axis == .horizontal, vertical.axis == .vertical else {
            throw SpatialScalePlanV4Error.nonCanonicalTwoDimensionalPlan
        }
        self.horizontal = horizontal
        self.vertical = vertical
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.schemaVersion, forKey: .schemaVersion)
        try container.encode(horizontal, forKey: .horizontal)
        try container.encode(vertical, forKey: .vertical)
    }
}
