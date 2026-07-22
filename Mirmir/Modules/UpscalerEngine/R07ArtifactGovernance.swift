// swiftlint:disable file_length

enum R07ArtifactKind: String, CaseIterable, Hashable, Sendable {
    case ringing
    case halo
    case ghosting
    case flicker
    case falseTexture = "false_texture"
    case chromaDisplacement = "chroma_displacement"

    var threshold: Int64 {
        switch self {
        case .ringing, .halo:
            return 3_277
        case .ghosting, .flicker, .falseTexture:
            return 4_096
        case .chromaDisplacement:
            return 64
        }
    }

    var unit: R07ArtifactUnit {
        self == .chromaDisplacement ? .q8Pixels : .q16
    }
}

enum R07ArtifactUnit: String, Hashable, Sendable {
    case q16
    case q8Pixels = "q8_pixels"
}

enum R07ArtifactGovernanceError: Error, Equatable, Sendable {
    case emptyVector(role: String)
    case vectorAboveMaximum(role: String, actual: Int, maximum: Int)
    case sampleCountMismatch(role: String, expected: Int, actual: Int)
    case sampleOutOfDomain(
        role: String,
        index: Int,
        value: Int64,
        minimum: Int64,
        maximum: Int64
    )
    case invalidRingingBounds(index: Int, lower: Int64, upper: Int64)
    case zeroSupportRejected
    case noValidGhostingSamplesRejected
    case insufficientSamplesRejected(role: String, actual: Int, minimum: Int)
    case invalidRawValue(kind: R07ArtifactKind, value: Int64)
    case incompleteArtifactOrder(
        expected: [R07ArtifactKind],
        actual: [R07ArtifactKind]
    )
    case arithmeticOverflow(operation: String)
    case emptyComparatorBackendSet
    case emptyComparatorBackendID(index: Int)
    case duplicateComparatorBackendID(String)
    case comparatorRecordCountMismatch(expected: Int, actual: Int)
    case incompleteComparatorRecord(String)
    case comparatorDimensionMismatch(
        backendID: String,
        expected: R07ComparatorDimension,
        actual: R07ComparatorDimension
    )
    case unknownComparatorBackendID(String)
    case duplicateComparatorRecord(String)
    case missingComparatorRecord(String)
}

struct R07ArtifactMeasurement: Hashable, Sendable {
    let kind: R07ArtifactKind
    let rawValue: Int64
    let normalizedRiskQ16: R06ASHQ16
    let detected: Bool
    let contributingSampleCount: Int?
}

struct R07ArtifactAggregate: Hashable, Sendable {
    let orderedMeasurements: [R07ArtifactMeasurement]
    let maximumNormalizedRiskQ16: R06ASHQ16
}

enum R07ArtifactCheckedInt64 {
    static func add(
        _ lhs: Int64,
        _ rhs: Int64,
        operation: String
    ) throws -> Int64 {
        let result = lhs.addingReportingOverflow(rhs)
        guard !result.overflow else {
            throw R07ArtifactGovernanceError.arithmeticOverflow(operation: operation)
        }
        return result.partialValue
    }

    static func subtract(
        _ lhs: Int64,
        _ rhs: Int64,
        operation: String
    ) throws -> Int64 {
        let result = lhs.subtractingReportingOverflow(rhs)
        guard !result.overflow else {
            throw R07ArtifactGovernanceError.arithmeticOverflow(operation: operation)
        }
        return result.partialValue
    }

    static func multiply(
        _ lhs: Int64,
        _ rhs: Int64,
        operation: String
    ) throws -> Int64 {
        let result = lhs.multipliedReportingOverflow(by: rhs)
        guard !result.overflow else {
            throw R07ArtifactGovernanceError.arithmeticOverflow(operation: operation)
        }
        return result.partialValue
    }

    static func absolute(_ value: Int64, operation: String) throws -> Int64 {
        guard value != .min else {
            throw R07ArtifactGovernanceError.arithmeticOverflow(operation: operation)
        }
        return Swift.abs(value)
    }

    static func absoluteDifference(
        _ lhs: Int64,
        _ rhs: Int64,
        operation: String
    ) throws -> Int64 {
        let difference = try subtract(lhs, rhs, operation: "\(operation)_subtract")
        return try absolute(difference, operation: "\(operation)_absolute")
    }
}

enum R07ArtifactGovernance {
    static let maximumSampleCount = 4_096
    static let normalLumaDomain: ClosedRange<Int64> = 0...65_536
    static let ringingCandidateDomain: ClosedRange<Int64> = -65_536...131_072
    static let ringingBoundDomain: ClosedRange<Int64> = 0...65_536

    static func validateDeclaredSampleCount(_ count: Int, role: String) throws {
        guard count > 0 else {
            throw R07ArtifactGovernanceError.emptyVector(role: role)
        }
        guard count <= maximumSampleCount else {
            throw R07ArtifactGovernanceError.vectorAboveMaximum(
                role: role,
                actual: count,
                maximum: maximumSampleCount
            )
        }
    }

    static func ringing(
        candidateQ16: [Int64],
        lowerBoundsQ16: [Int64],
        upperBoundsQ16: [Int64]
    ) throws -> R07ArtifactMeasurement {
        try validateVector(candidateQ16, role: "candidate", domain: ringingCandidateDomain)
        try requireSameCount(lowerBoundsQ16, as: candidateQ16, role: "lower_bounds")
        try requireSameCount(upperBoundsQ16, as: candidateQ16, role: "upper_bounds")
        try validateSamples(lowerBoundsQ16, role: "lower_bounds", domain: ringingBoundDomain)
        try validateSamples(upperBoundsQ16, role: "upper_bounds", domain: ringingBoundDomain)

        var rawValue: Int64 = 0
        for index in candidateQ16.indices {
            let lower = lowerBoundsQ16[index]
            let upper = upperBoundsQ16[index]
            guard lower <= upper else {
                throw R07ArtifactGovernanceError.invalidRingingBounds(
                    index: index,
                    lower: lower,
                    upper: upper
                )
            }
            let overshoot = max(0, candidateQ16[index] - upper)
            let undershoot = max(0, lower - candidateQ16[index])
            rawValue = max(rawValue, max(overshoot, undershoot))
        }
        return try measurement(kind: .ringing, rawValue: rawValue)
    }

    static func halo(
        candidateQ16: [Int64],
        referenceQ16: [Int64],
        support: [Bool]
    ) throws -> R07ArtifactMeasurement {
        try validateNormalPair(candidateQ16, referenceQ16)
        try requireSameCount(support, as: candidateQ16, role: "support")
        guard support.contains(true) else {
            throw R07ArtifactGovernanceError.zeroSupportRejected
        }
        var rawValue: Int64 = 0
        for index in candidateQ16.indices where support[index] {
            rawValue = max(
                rawValue,
                try R07ArtifactCheckedInt64.absoluteDifference(
                    candidateQ16[index],
                    referenceQ16[index],
                    operation: "halo_difference"
                )
            )
        }
        return try measurement(
            kind: .halo,
            rawValue: rawValue,
            contributingSampleCount: support.filter { $0 }.count
        )
    }

    static func ghosting(
        currentQ16: [Int64],
        alignedPreviousQ16: [Int64],
        occlusionMask: [Bool]
    ) throws -> R07ArtifactMeasurement {
        try validateNormalPair(currentQ16, alignedPreviousQ16)
        try requireSameCount(occlusionMask, as: currentQ16, role: "occlusion_mask")
        var total: Int64 = 0
        var validCount = 0
        for index in currentQ16.indices where !occlusionMask[index] {
            let difference = try R07ArtifactCheckedInt64.absoluteDifference(
                currentQ16[index],
                alignedPreviousQ16[index],
                operation: "ghosting_difference"
            )
            total = try R07ArtifactCheckedInt64.add(total, difference, operation: "ghosting_sum")
            validCount += 1
        }
        guard validCount > 0 else {
            throw R07ArtifactGovernanceError.noValidGhostingSamplesRejected
        }
        return try measurement(
            kind: .ghosting,
            rawValue: total / Int64(validCount),
            contributingSampleCount: validCount
        )
    }

    static func flicker(
        currentQ16: [Int64],
        previousQ16: [Int64],
        beforePreviousQ16: [Int64]
    ) throws -> R07ArtifactMeasurement {
        try validateVector(currentQ16, role: "current", domain: normalLumaDomain)
        try requireSameCount(previousQ16, as: currentQ16, role: "previous")
        try requireSameCount(beforePreviousQ16, as: currentQ16, role: "before_previous")
        try validateSamples(previousQ16, role: "previous", domain: normalLumaDomain)
        try validateSamples(beforePreviousQ16, role: "before_previous", domain: normalLumaDomain)

        var total: Int64 = 0
        for index in currentQ16.indices {
            let doubledPrevious = try R07ArtifactCheckedInt64.multiply(
                previousQ16[index],
                2,
                operation: "flicker_double_previous"
            )
            let first = try R07ArtifactCheckedInt64.subtract(
                currentQ16[index],
                doubledPrevious,
                operation: "flicker_current_minus_previous"
            )
            let secondDifference = try R07ArtifactCheckedInt64.add(
                first,
                beforePreviousQ16[index],
                operation: "flicker_add_before_previous"
            )
            let magnitude = try R07ArtifactCheckedInt64.absolute(
                secondDifference,
                operation: "flicker_absolute"
            ) / 2
            total = try R07ArtifactCheckedInt64.add(total, magnitude, operation: "flicker_sum")
        }
        return try measurement(
            kind: .flicker,
            rawValue: total / Int64(currentQ16.count)
        )
    }

    static func falseTexture(
        candidateQ16: [Int64],
        sourceQ16: [Int64]
    ) throws -> R07ArtifactMeasurement {
        try validateNormalPair(candidateQ16, sourceQ16)
        guard candidateQ16.count >= 2 else {
            throw R07ArtifactGovernanceError.insufficientSamplesRejected(
                role: "candidate_and_source",
                actual: candidateQ16.count,
                minimum: 2
            )
        }
        let candidateMean = try meanAdjacentDifference(candidateQ16, role: "candidate")
        let sourceMean = try meanAdjacentDifference(sourceQ16, role: "source")
        return try measurement(
            kind: .falseTexture,
            rawValue: max(0, candidateMean - sourceMean)
        )
    }

    static func chromaDisplacement(
        lumaEdgePositionQ8: Int64,
        chromaEdgePositionQ8: Int64
    ) throws -> R07ArtifactMeasurement {
        let rawValue = try R07ArtifactCheckedInt64.absoluteDifference(
            lumaEdgePositionQ8,
            chromaEdgePositionQ8,
            operation: "chroma_displacement"
        )
        return try measurement(kind: .chromaDisplacement, rawValue: rawValue)
    }

    static func measurement(
        kind: R07ArtifactKind,
        rawValue: Int64,
        contributingSampleCount: Int? = nil
    ) throws -> R07ArtifactMeasurement {
        guard rawValue >= 0 else {
            throw R07ArtifactGovernanceError.invalidRawValue(kind: kind, value: rawValue)
        }
        let scaled = try R07ArtifactCheckedInt64.multiply(
            rawValue,
            R06ASHQ16.scale,
            operation: "\(kind.rawValue)_normalize_multiply"
        )
        let normalized = min(R06ASHQ16.scale, scaled / kind.threshold)
        return R07ArtifactMeasurement(
            kind: kind,
            rawValue: rawValue,
            normalizedRiskQ16: try R06ASHQ16(normalized),
            detected: rawValue > kind.threshold,
            contributingSampleCount: contributingSampleCount
        )
    }

    static func aggregate(
        _ measurements: [R07ArtifactMeasurement]
    ) throws -> R07ArtifactAggregate {
        let actualOrder = measurements.map(\.kind)
        guard actualOrder == R07ArtifactKind.allCases else {
            throw R07ArtifactGovernanceError.incompleteArtifactOrder(
                expected: R07ArtifactKind.allCases,
                actual: actualOrder
            )
        }
        let maximum = measurements.map(\.normalizedRiskQ16).max() ?? .zero
        return R07ArtifactAggregate(
            orderedMeasurements: measurements,
            maximumNormalizedRiskQ16: maximum
        )
    }
}

private extension R07ArtifactGovernance {
    static func validateVector(
        _ values: [Int64],
        role: String,
        domain: ClosedRange<Int64>
    ) throws {
        try validateDeclaredSampleCount(values.count, role: role)
        try validateSamples(values, role: role, domain: domain)
    }

    static func validateSamples(
        _ values: [Int64],
        role: String,
        domain: ClosedRange<Int64>
    ) throws {
        if let invalid = values.enumerated().first(where: { !domain.contains($0.element) }) {
            throw R07ArtifactGovernanceError.sampleOutOfDomain(
                role: role,
                index: invalid.offset,
                value: invalid.element,
                minimum: domain.lowerBound,
                maximum: domain.upperBound
            )
        }
    }

    static func requireSameCount<Element, Expected>(
        _ values: [Element],
        as expected: [Expected],
        role: String
    ) throws {
        guard values.count == expected.count else {
            throw R07ArtifactGovernanceError.sampleCountMismatch(
                role: role,
                expected: expected.count,
                actual: values.count
            )
        }
    }

    static func validateNormalPair(
        _ first: [Int64],
        _ second: [Int64]
    ) throws {
        try validateVector(first, role: "candidate_or_current", domain: normalLumaDomain)
        try requireSameCount(second, as: first, role: "reference_or_previous")
        try validateSamples(second, role: "reference_or_previous", domain: normalLumaDomain)
    }

    static func meanAdjacentDifference(
        _ values: [Int64],
        role: String
    ) throws -> Int64 {
        var total: Int64 = 0
        for index in values.indices.dropFirst() {
            let difference = try R07ArtifactCheckedInt64.absoluteDifference(
                values[index],
                values[index - 1],
                operation: "\(role)_adjacent_difference"
            )
            total = try R07ArtifactCheckedInt64.add(
                total,
                difference,
                operation: "\(role)_adjacent_sum"
            )
        }
        return total / Int64(values.count - 1)
    }
}

enum R07ComparatorDimension: String, CaseIterable, Hashable, Sendable {
    case temporalArtifact = "temporal_artifact"
    case chromaDisplacement = "chroma_displacement"
    case spatialMSSSIM = "spatial_ms_ssim"
    case protectedIntegrity = "protected_integrity"

    var metric: String {
        switch self {
        case .temporalArtifact:
            return "maximum_normalized_risk_q16_over_ringing_halo_ghosting_flicker_false_texture"
        case .chromaDisplacement:
            return "raw_chroma_displacement_q8_pixels"
        case .spatialMSSSIM:
            return "delta_ppm"
        case .protectedIntegrity:
            return "weighted_mae_q16"
        }
    }

    var unit: R07ComparatorUnit {
        switch self {
        case .temporalArtifact, .protectedIntegrity:
            return .q16
        case .chromaDisplacement:
            return .q8Pixels
        case .spatialMSSSIM:
            return .ppm
        }
    }

    var equation: String {
        switch self {
        case .temporalArtifact:
            return "baseline_temporal_risk_q16-auto_temporal_risk_q16"
        case .chromaDisplacement:
            return "baseline_chroma_displacement_q8_pixels-auto_chroma_displacement_q8_pixels"
        case .spatialMSSSIM:
            return "auto_ms_ssim_ppm-baseline_ms_ssim_ppm"
        case .protectedIntegrity:
            return "auto_weighted_mae_q16-baseline_weighted_mae_q16"
        }
    }

    var passThreshold: Int64 {
        self == .spatialMSSSIM ? -5_000 : (self == .protectedIntegrity ? 0 : 1)
    }

    var passOperator: R07ComparatorPassOperator {
        self == .protectedIntegrity ? .lessThanOrEqual : .greaterThanOrEqual
    }
}

enum R07ComparatorPassOperator: String, Hashable, Sendable {
    case greaterThanOrEqual = "greater_than_or_equal"
    case lessThanOrEqual = "less_than_or_equal"
}

enum R07ComparatorUnit: String, Hashable, Sendable {
    case q16
    case q8Pixels = "q8_pixels"
    case ppm
}

enum R07ComparatorBackendScope: String, Hashable, Sendable {
    case syntheticFixtureOnly = "synthetic_fixture_only"
}

enum R07ComparatorObservationStatus: String, Hashable, Sendable {
    case notObserved = "not_observed"
}

enum R07ComparatorProductQualification: String, Hashable, Sendable {
    case notClaimed = "not_claimed"
}

enum R07ComparatorClaim: String, Hashable, Sendable {
    case forbidden
}

struct R07BlockedProductComparison: Hashable, Sendable {
    static let reason = "upstream_no_product_qualified_primary_backend"

    let dimension: R07ComparatorDimension
    let usedBackendIDs: [String] = []
    let status: R07ComparatorObservationStatus = .notObserved
    let nonvacuousRequirementSatisfied = false
    let fixtureComparisonExecuted = false
    let productQualification: R07ComparatorProductQualification = .notClaimed
    let claim: R07ComparatorClaim = .forbidden

    var reason: String {
        Self.reason
    }

    var productComparisonExecution: R07ComparatorObservationStatus {
        status
    }
}

struct R07SyntheticComparatorRecord: Hashable, Sendable {
    let fixtureBackendID: String
    let dimension: R07ComparatorDimension
    let baselineValue: Int64
    let autoValue: Int64
    let complete: Bool
}

struct R07SyntheticComparatorResult: Hashable, Sendable {
    let fixtureBackendID: String
    let dimension: R07ComparatorDimension
    let computedDelta: Int64
    let passed: Bool
    let backendScope: R07ComparatorBackendScope
    let nonvacuousRequirementSatisfied: Bool
    let fixtureComparisonExecuted: Bool
    let productComparisonExecution: R07ComparatorObservationStatus
    let productQualification: R07ComparatorProductQualification
    let claim: R07ComparatorClaim
}

enum R07SyntheticComparator {
    static func evaluate(
        dimension: R07ComparatorDimension,
        fixtureBackendIDs: [String],
        records: [R07SyntheticComparatorRecord]
    ) throws -> [R07SyntheticComparatorResult] {
        guard !fixtureBackendIDs.isEmpty else {
            throw R07ArtifactGovernanceError.emptyComparatorBackendSet
        }
        var expectedIDs = Set<String>()
        for (index, backendID) in fixtureBackendIDs.enumerated() {
            guard !backendID.isEmpty else {
                throw R07ArtifactGovernanceError.emptyComparatorBackendID(index: index)
            }
            guard expectedIDs.insert(backendID).inserted else {
                throw R07ArtifactGovernanceError.duplicateComparatorBackendID(backendID)
            }
        }
        guard records.count == fixtureBackendIDs.count else {
            throw R07ArtifactGovernanceError.comparatorRecordCountMismatch(
                expected: fixtureBackendIDs.count,
                actual: records.count
            )
        }

        var recordsByID: [String: R07SyntheticComparatorRecord] = [:]
        for record in records {
            guard record.complete else {
                throw R07ArtifactGovernanceError.incompleteComparatorRecord(
                    record.fixtureBackendID
                )
            }
            guard record.dimension == dimension else {
                throw R07ArtifactGovernanceError.comparatorDimensionMismatch(
                    backendID: record.fixtureBackendID,
                    expected: dimension,
                    actual: record.dimension
                )
            }
            guard expectedIDs.contains(record.fixtureBackendID) else {
                throw R07ArtifactGovernanceError.unknownComparatorBackendID(
                    record.fixtureBackendID
                )
            }
            guard recordsByID.updateValue(record, forKey: record.fixtureBackendID) == nil else {
                throw R07ArtifactGovernanceError.duplicateComparatorRecord(
                    record.fixtureBackendID
                )
            }
        }

        return try fixtureBackendIDs.map { backendID in
            guard let record = recordsByID[backendID] else {
                throw R07ArtifactGovernanceError.missingComparatorRecord(backendID)
            }
            let delta = try computedDelta(for: record)
            return R07SyntheticComparatorResult(
                fixtureBackendID: backendID,
                dimension: dimension,
                computedDelta: delta,
                passed: passes(delta, dimension: dimension),
                backendScope: .syntheticFixtureOnly,
                nonvacuousRequirementSatisfied: true,
                fixtureComparisonExecuted: true,
                productComparisonExecution: .notObserved,
                productQualification: .notClaimed,
                claim: .forbidden
            )
        }
    }
}

private extension R07SyntheticComparator {
    static func computedDelta(
        for record: R07SyntheticComparatorRecord
    ) throws -> Int64 {
        switch record.dimension {
        case .temporalArtifact, .chromaDisplacement:
            return try R07ArtifactCheckedInt64.subtract(
                record.baselineValue,
                record.autoValue,
                operation: "\(record.dimension.rawValue)_comparator_subtract"
            )
        case .spatialMSSSIM, .protectedIntegrity:
            return try R07ArtifactCheckedInt64.subtract(
                record.autoValue,
                record.baselineValue,
                operation: "\(record.dimension.rawValue)_comparator_subtract"
            )
        }
    }

    static func passes(
        _ delta: Int64,
        dimension: R07ComparatorDimension
    ) -> Bool {
        switch dimension.passOperator {
        case .greaterThanOrEqual:
            return delta >= dimension.passThreshold
        case .lessThanOrEqual:
            return delta <= dimension.passThreshold
        }
    }
}
