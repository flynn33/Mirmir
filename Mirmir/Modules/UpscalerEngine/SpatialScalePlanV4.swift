import Foundation

enum SpatialScalePlanV4Error: Error, Equatable, Sendable {
    case nonPositiveExtent(axis: SpatialAxisV4, source: Int, target: Int)
    case extentExceedsLimit(axis: SpatialAxisV4, value: Int, limit: Int)
    case downscalingIsNotAdmitted(axis: SpatialAxisV4, source: Int, target: Int)
    case arithmeticOverflow
    case nonCanonicalSerializedPlan(axis: SpatialAxisV4)
    case nonCanonicalTwoDimensionalPlan
    case invalidSubsampledMapping
}

enum SpatialAxisV4: String, Codable, Hashable, Sendable {
    case horizontal
    case vertical
}

enum SpatialBorderRuleV4: String, Codable, Hashable, Sendable {
    case clamp
    case reflect101
}

/// Progressive 4:2:0 locations, expressed in half-luma-index units. This
/// low-level contract intentionally has no unresolved/default case.
enum SpatialChromaSitingV4: String, Codable, CaseIterable, Hashable, Sendable {
    case left
    case center
    case topLeft = "top_left"
    case top
    case bottomLeft = "bottom_left"
    case bottom

    func lumaOffsetNumerator(axis: SpatialAxisV4) -> Int64 {
        switch axis {
        case .horizontal:
            switch self {
            case .left, .topLeft, .bottomLeft: return 0
            case .center, .top, .bottom: return 1
            }
        case .vertical:
            switch self {
            case .topLeft, .top: return 0
            case .left, .center: return 1
            case .bottomLeft, .bottom: return 2
            }
        }
    }
}

struct SpatialChromaGeometryV4: Codable, Hashable, Sendable {
    static let coordinateProcedureID =
        "pixel-center-luma-authenticated-subsampled-siting-v2"
    static let kernelContractID =
        "ash-p06-catmull-rom-q14-subsampled-physical-siting-v2"

    let source: SpatialChromaSitingV4
    let target: SpatialChromaSitingV4

    var identity: String {
        Self.coordinateProcedureID + ":" + source.rawValue
            + "->" + target.rawValue
    }
}

/// Field normalization preserves the interleaved chroma plane's sample grid.
/// Each bobbed field retains its own declared location before conversion to
/// the one progressive output location. Dominance changes order, not phase.
struct SpatialInterlacedChromaGeometryV4: Codable, Hashable, Sendable {
    static let normalizationPolicyID =
        "field-bob-authenticated-interleaved-uv-siting-v2"

    static let temporalAlignmentPolicyID =
        "opposite-field-catmull-rom-q14-phase-align-v1"

    let topSource: SpatialChromaSitingV4
    let bottomSource: SpatialChromaSitingV4
    let target: SpatialChromaSitingV4

    func geometry(forTopField: Bool) -> SpatialChromaGeometryV4 {
        SpatialChromaGeometryV4(
            source: forTopField ? topSource : bottomSource, target: target
        )
    }

    var identity: String {
        Self.normalizationPolicyID + ":top=" + topSource.rawValue
            + ";bottom=" + bottomSource.rawValue + ";output=" + target.rawValue
            + ";temporal=" + Self.temporalAlignmentPolicyID
    }
}

/// Authenticated coordinate inputs for one subsampled axis. Original luma
/// extents are retained: ceil-divided plane counts are not the image scale
/// when a coded raster is odd.
struct SpatialSubsampledLumaMappingV4: Codable, Hashable, Sendable {
    let axis: SpatialAxisV4
    let sourceLumaExtent: Int
    let targetLumaExtent: Int
    let geometry: SpatialChromaGeometryV4

    init(
        axis: SpatialAxisV4,
        sourceLumaExtent: Int,
        targetLumaExtent: Int,
        geometry: SpatialChromaGeometryV4
    ) throws {
        let limit = SpatialAxisScalePlanV4.maximumSupportedExtent
        guard sourceLumaExtent > 0,
              targetLumaExtent >= sourceLumaExtent,
              sourceLumaExtent <= limit, targetLumaExtent <= limit else {
            throw SpatialScalePlanV4Error.invalidSubsampledMapping
        }
        self.axis = axis
        self.sourceLumaExtent = sourceLumaExtent
        self.targetLumaExtent = targetLumaExtent
        self.geometry = geometry
    }

    private enum CodingKeys: String, CodingKey {
        case axis, sourceLumaExtent, targetLumaExtent, geometry
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            axis: container.decode(SpatialAxisV4.self, forKey: .axis),
            sourceLumaExtent: container.decode(Int.self, forKey: .sourceLumaExtent),
            targetLumaExtent: container.decode(Int.self, forKey: .targetLumaExtent),
            geometry: container.decode(SpatialChromaGeometryV4.self, forKey: .geometry)
        )
    }

    func validate(
        axis: SpatialAxisV4,
        sourcePlaneExtent: Int,
        targetPlaneExtent: Int
    ) throws {
        guard self.axis == axis,
              sourcePlaneExtent == (sourceLumaExtent + 1) / 2,
              targetPlaneExtent == (targetLumaExtent + 1) / 2 else {
            throw SpatialScalePlanV4Error.invalidSubsampledMapping
        }
    }

    func sourceCoordinate(destinationIndex: Int) throws -> ExactRationalV4 {
        guard destinationIndex >= 0,
              destinationIndex < (targetLumaExtent + 1) / 2 else {
            throw SpatialScalePlanV4Error.invalidSubsampledMapping
        }
        // In luma-index space the target chroma center is 2*j + deltaOut.
        // Apply the luma half-pixel map, subtract deltaIn, then divide by2.
        let sourceOffset = geometry.source.lumaOffsetNumerator(axis: axis)
        let targetOffset = geometry.target.lumaOffsetNumerator(axis: axis)
        let index = Int64(destinationIndex).multipliedReportingOverflow(by: 4)
        let center = index.partialValue.addingReportingOverflow(targetOffset + 1)
        let scaled = center.partialValue.multipliedReportingOverflow(by: Int64(sourceLumaExtent))
        let offset = (sourceOffset + 1).multipliedReportingOverflow(by: Int64(targetLumaExtent))
        let numerator = scaled.partialValue.subtractingReportingOverflow(offset.partialValue)
        let denominator = Int64(targetLumaExtent).multipliedReportingOverflow(by: 4)
        guard !index.overflow, !center.overflow, !scaled.overflow,
              !offset.overflow, !numerator.overflow, !denominator.overflow else {
            throw SpatialScalePlanV4Error.arithmeticOverflow
        }
        return try ExactRationalV4(numerator.partialValue, denominator.partialValue)
    }
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
    static let subsampledSchemaVersion = 2
    static let maximumSupportedExtent = 65_536

    let axis: SpatialAxisV4
    let sourceExtent: Int
    let targetExtent: Int
    let scale: ExactRationalV4
    let borderRule: SpatialBorderRuleV4
    let positions: [SpatialSamplePositionV4]
    let uniquePhases: [ExactRationalV4]
    let subsampledLumaMapping: SpatialSubsampledLumaMappingV4?

    init(
        axis: SpatialAxisV4,
        sourceExtent: Int,
        targetExtent: Int,
        borderRule: SpatialBorderRuleV4 = .clamp,
        subsampledLumaMapping: SpatialSubsampledLumaMappingV4? = nil
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

        try subsampledLumaMapping?.validate(
            axis: axis,
            sourcePlaneExtent: sourceExtent,
            targetPlaneExtent: targetExtent
        )
        let source64 = Int64(sourceExtent)
        let target64 = Int64(targetExtent)
        let (genericCoordinateDenominator, denominatorOverflow) = target64
            .multipliedReportingOverflow(by: 2)
        guard !denominatorOverflow else {
            throw SpatialScalePlanV4Error.arithmeticOverflow
        }

        var positions: [SpatialSamplePositionV4] = []
        positions.reserveCapacity(targetExtent)
        var phases = Set<ExactRationalV4>()
        phases.reserveCapacity(targetExtent)

        for destinationIndex in 0..<targetExtent {
            let coordinateNumerator: Int64
            let coordinateDenominator: Int64
            if let subsampledLumaMapping {
                let coordinate = try subsampledLumaMapping.sourceCoordinate(
                    destinationIndex: destinationIndex
                )
                coordinateNumerator = coordinate.numerator
                coordinateDenominator = coordinate.denominator
            } else {
                let destination64 = Int64(destinationIndex)
                let (doubledIndex, doubledOverflow) = destination64
                    .multipliedReportingOverflow(by: 2)
                let (oddCenter, centerOverflow) = doubledIndex
                    .addingReportingOverflow(1)
                let (scaledCenter, productOverflow) = oddCenter
                    .multipliedReportingOverflow(by: source64)
                let (numerator, subtractionOverflow) = scaledCenter
                    .subtractingReportingOverflow(target64)
                guard !doubledOverflow, !centerOverflow,
                      !productOverflow, !subtractionOverflow else {
                    throw SpatialScalePlanV4Error.arithmeticOverflow
                }
                coordinateNumerator = numerator
                coordinateDenominator = genericCoordinateDenominator
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
        if let subsampledLumaMapping {
            self.scale = try ExactRationalV4(
                Int64(subsampledLumaMapping.targetLumaExtent),
                Int64(subsampledLumaMapping.sourceLumaExtent)
            )
        } else {
            self.scale = try ExactRationalV4(target64, source64)
        }
        self.subsampledLumaMapping = subsampledLumaMapping
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
        case subsampledLumaMapping
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        let axis = try container.decode(SpatialAxisV4.self, forKey: .axis)
        guard version == Self.schemaVersion || version == Self.subsampledSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported spatial scale plan schema."
            )
        }

        let mapping: SpatialSubsampledLumaMappingV4?
        if version == Self.subsampledSchemaVersion {
            mapping = try container.decode(
                SpatialSubsampledLumaMappingV4.self, forKey: .subsampledLumaMapping
            )
        } else {
            guard !container.contains(.subsampledLumaMapping) else {
                throw SpatialScalePlanV4Error.nonCanonicalSerializedPlan(axis: axis)
            }
            mapping = nil
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
            borderRule: borderRule,
            subsampledLumaMapping: mapping
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
        try container.encode(
            subsampledLumaMapping == nil ? Self.schemaVersion : Self.subsampledSchemaVersion,
            forKey: .schemaVersion
        )
        if let subsampledLumaMapping {
            try container.encode(subsampledLumaMapping, forKey: .subsampledLumaMapping)
        }
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
    static let subsampledSchemaVersion = 2

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

    init(
        sourceLumaWidth: Int,
        sourceLumaHeight: Int,
        targetLumaWidth: Int,
        targetLumaHeight: Int,
        chromaGeometry: SpatialChromaGeometryV4,
        borderRule: SpatialBorderRuleV4 = .clamp
    ) throws {
        let horizontalMapping = try SpatialSubsampledLumaMappingV4(
            axis: .horizontal, sourceLumaExtent: sourceLumaWidth,
            targetLumaExtent: targetLumaWidth, geometry: chromaGeometry
        )
        let verticalMapping = try SpatialSubsampledLumaMappingV4(
            axis: .vertical, sourceLumaExtent: sourceLumaHeight,
            targetLumaExtent: targetLumaHeight, geometry: chromaGeometry
        )
        self.horizontal = try SpatialAxisScalePlanV4(
            axis: .horizontal, sourceExtent: (sourceLumaWidth + 1) / 2,
            targetExtent: (targetLumaWidth + 1) / 2, borderRule: borderRule,
            subsampledLumaMapping: horizontalMapping
        )
        self.vertical = try SpatialAxisScalePlanV4(
            axis: .vertical, sourceExtent: (sourceLumaHeight + 1) / 2,
            targetExtent: (targetLumaHeight + 1) / 2, borderRule: borderRule,
            subsampledLumaMapping: verticalMapping
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
        guard version == Self.schemaVersion || version == Self.subsampledSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion, in: container,
                debugDescription: "Unsupported two-dimensional scale-plan schema."
            )
        }
        let horizontal = try container.decode(SpatialAxisScalePlanV4.self, forKey: .horizontal)
        let vertical = try container.decode(SpatialAxisScalePlanV4.self, forKey: .vertical)
        guard horizontal.axis == .horizontal, vertical.axis == .vertical else {
            throw SpatialScalePlanV4Error.nonCanonicalTwoDimensionalPlan
        }
        if version == Self.schemaVersion {
            guard horizontal.subsampledLumaMapping == nil,
                  vertical.subsampledLumaMapping == nil else {
                throw SpatialScalePlanV4Error.nonCanonicalTwoDimensionalPlan
            }
            self.horizontal = horizontal
            self.vertical = vertical
            return
        }
        guard let h = horizontal.subsampledLumaMapping,
              let v = vertical.subsampledLumaMapping,
              h.geometry == v.geometry,
              horizontal.borderRule == vertical.borderRule else {
            throw SpatialScalePlanV4Error.nonCanonicalTwoDimensionalPlan
        }
        let rebuilt = try Self(
            sourceLumaWidth: h.sourceLumaExtent,
            sourceLumaHeight: v.sourceLumaExtent,
            targetLumaWidth: h.targetLumaExtent,
            targetLumaHeight: v.targetLumaExtent,
            chromaGeometry: h.geometry,
            borderRule: horizontal.borderRule
        )
        guard horizontal == rebuilt.horizontal, vertical == rebuilt.vertical else {
            throw SpatialScalePlanV4Error.nonCanonicalTwoDimensionalPlan
        }
        self = rebuilt
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(
            horizontal.subsampledLumaMapping == nil
                ? Self.schemaVersion : Self.subsampledSchemaVersion,
            forKey: .schemaVersion
        )
        try container.encode(horizontal, forKey: .horizontal)
        try container.encode(vertical, forKey: .vertical)
    }
}
