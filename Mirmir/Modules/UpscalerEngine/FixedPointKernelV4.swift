import Foundation

enum FixedPointKernelV4Error: Error, Equatable, Sendable {
    case invalidCoefficientPrecision(Int)
    case invalidPhase(ExactRationalV4)
    case coefficientArithmeticOverflow
    case coefficientNormalizationFailure(expected: Int32, actual: Int64)
    case phaseKernelMissing(ExactRationalV4)
    case invalidSourceLayout(
        width: Int,
        height: Int,
        rowStride: Int,
        sampleCount: Int
    )
    case invalidCodeBounds(minimum: UInt16, maximum: UInt16)
    case executionArithmeticOverflow
    case nonCanonicalKernelIR
}

enum FixedPointRoundingRuleV4: String, Codable, Hashable, Sendable {
    case nearestTiesToEven
}

/// One exact phase of the locked P06 four-tap cubic coefficient procedure.
struct FixedPointPhaseKernelV4: Codable, Equatable, Hashable, Sendable {
    static let tapOffsets = [-1, 0, 1, 2]

    let phase: ExactRationalV4
    let coefficients: [Int32]
    let fractionalBits: Int
    let roundingRule: FixedPointRoundingRuleV4

    var normalization: Int32 {
        Int32(1 << fractionalBits)
    }

    init(
        phase: ExactRationalV4,
        coefficients: [Int32],
        fractionalBits: Int,
        roundingRule: FixedPointRoundingRuleV4
    ) throws {
        guard phase >= .zero, phase < .one else {
            throw FixedPointKernelV4Error.invalidPhase(phase)
        }
        guard (1...20).contains(fractionalBits), coefficients.count == 4 else {
            throw FixedPointKernelV4Error.invalidCoefficientPrecision(
                fractionalBits
            )
        }
        let expected = Int32(1 << fractionalBits)
        let sum = coefficients.reduce(Int64(0)) { $0 + Int64($1) }
        guard sum == Int64(expected) else {
            throw FixedPointKernelV4Error.coefficientNormalizationFailure(
                expected: expected,
                actual: sum
            )
        }
        self.phase = phase
        self.coefficients = coefficients
        self.fractionalBits = fractionalBits
        self.roundingRule = roundingRule
    }
}

/// Deterministic coefficient compiler shared by CPU execution and Metal asset
/// generation. It evaluates the interpolating Catmull-Rom cubic exactly as
/// integer polynomials over the reduced rational phase, then uses a declared
/// largest-remainder normalization to produce Q14 coefficients that sum to 1.
enum FixedPointCoefficientCompilerV4 {
    static let procedureID = "ash-p06-catmull-rom-q14-largest-remainder-v1"
    static let fractionalBits = 14
    static let normalization = Int32(1 << fractionalBits)

    static func compile(
        phase: ExactRationalV4
    ) throws -> FixedPointPhaseKernelV4 {
        guard phase >= .zero, phase < .one else {
            throw FixedPointKernelV4Error.invalidPhase(phase)
        }
        let n = phase.numerator
        let d = phase.denominator
        let (dSquared, dSquaredOverflow) = d.multipliedReportingOverflow(by: d)
        let (dCubed, dCubedOverflow) = dSquared.multipliedReportingOverflow(by: d)
        let (nSquared, nSquaredOverflow) = n.multipliedReportingOverflow(by: n)
        let (nCubed, nCubedOverflow) = nSquared.multipliedReportingOverflow(by: n)
        let (commonDenominator, denominatorOverflow) = dCubed
            .multipliedReportingOverflow(by: 2)
        guard !dSquaredOverflow,
              !dCubedOverflow,
              !nSquaredOverflow,
              !nCubedOverflow,
              !denominatorOverflow,
              commonDenominator > 0 else {
            throw FixedPointKernelV4Error.coefficientArithmeticOverflow
        }

        let nDSquared = try checkedMultiply(n, dSquared)
        let nSquaredD = try checkedMultiply(nSquared, d)
        let twoNSquaredD = try checkedMultiply(nSquaredD, 2)
        let threeNCubed = try checkedMultiply(nCubed, 3)
        let fourNSquaredD = try checkedMultiply(nSquaredD, 4)
        let fiveNSquaredD = try checkedMultiply(nSquaredD, 5)
        let twoDCubed = commonDenominator

        let weightNumerators = [
            try checkedSubtract(
                try checkedAdd(-nDSquared, twoNSquaredD),
                nCubed
            ),
            try checkedAdd(
                try checkedSubtract(twoDCubed, fiveNSquaredD),
                threeNCubed
            ),
            try checkedSubtract(
                try checkedAdd(nDSquared, fourNSquaredD),
                threeNCubed
            ),
            try checkedAdd(-nSquaredD, nCubed)
        ]
        guard weightNumerators.reduce(Int64(0), +) == commonDenominator else {
            throw FixedPointKernelV4Error.coefficientArithmeticOverflow
        }

        let coefficients = try normalizedQuantization(
            numerators: weightNumerators,
            denominator: UInt64(commonDenominator),
            phase: phase
        )
        return try FixedPointPhaseKernelV4(
            phase: phase,
            coefficients: coefficients,
            fractionalBits: fractionalBits,
            roundingRule: .nearestTiesToEven
        )
    }

    private struct FloorQuantization {
        var value: Int64
        let fractionalNumerator: UInt64
        let tap: Int
    }

    private static func normalizedQuantization(
        numerators: [Int64],
        denominator: UInt64,
        phase: ExactRationalV4
    ) throws -> [Int32] {
        var floors = try numerators.enumerated().map { tap, numerator in
            let decomposition = try scaledFloor(
                numerator: numerator,
                multiplier: UInt64(normalization),
                denominator: denominator
            )
            return FloorQuantization(
                value: decomposition.quotient,
                fractionalNumerator: decomposition.remainder,
                tap: tap
            )
        }
        let floorSum = floors.reduce(Int64(0)) { $0 + $1.value }
        let residual = Int64(normalization) - floorSum
        guard (0...Int64(floors.count - 1)).contains(residual) else {
            throw FixedPointKernelV4Error.coefficientArithmeticOverflow
        }

        let leftHalf = try phase.compared(to: ExactRationalV4(1, 2))
            != .descending
        let preferredTapOrder = leftHalf ? [1, 2, 0, 3] : [2, 1, 3, 0]
        let rankByTap = Dictionary(
            uniqueKeysWithValues: preferredTapOrder.enumerated().map {
                ($0.element, $0.offset)
            }
        )
        let allocationOrder = floors.indices.sorted { left, right in
            let leftRemainder = floors[left].fractionalNumerator
            let rightRemainder = floors[right].fractionalNumerator
            if leftRemainder != rightRemainder {
                return leftRemainder > rightRemainder
            }
            return rankByTap[floors[left].tap]! < rankByTap[floors[right].tap]!
        }
        for offset in 0..<Int(residual) {
            floors[allocationOrder[offset]].value += 1
        }

        return try floors.map { quantization in
            guard let value = Int32(exactly: quantization.value) else {
                throw FixedPointKernelV4Error.coefficientArithmeticOverflow
            }
            return value
        }
    }

    /// Returns mathematical floor and a nonnegative fractional numerator for
    /// `numerator * multiplier / denominator`, using a full-width product.
    private static func scaledFloor(
        numerator: Int64,
        multiplier: UInt64,
        denominator: UInt64
    ) throws -> (quotient: Int64, remainder: UInt64) {
        let product = numerator.magnitude.multipliedFullWidth(by: multiplier)
        let division = denominator.dividingFullWidth(product)
        guard division.quotient <= UInt64(Int64.max) else {
            throw FixedPointKernelV4Error.coefficientArithmeticOverflow
        }
        let magnitudeQuotient = Int64(division.quotient)
        if numerator >= 0 {
            return (magnitudeQuotient, division.remainder)
        }
        if division.remainder == 0 {
            return (-magnitudeQuotient, 0)
        }
        let (negativeFloor, overflow) = magnitudeQuotient
            .addingReportingOverflow(1)
        guard !overflow else {
            throw FixedPointKernelV4Error.coefficientArithmeticOverflow
        }
        return (-negativeFloor, denominator - division.remainder)
    }

    private static func checkedMultiply(
        _ left: Int64,
        _ right: Int64
    ) throws -> Int64 {
        let (result, overflow) = left.multipliedReportingOverflow(by: right)
        guard !overflow else {
            throw FixedPointKernelV4Error.coefficientArithmeticOverflow
        }
        return result
    }

    private static func checkedAdd(
        _ left: Int64,
        _ right: Int64
    ) throws -> Int64 {
        let (result, overflow) = left.addingReportingOverflow(right)
        guard !overflow else {
            throw FixedPointKernelV4Error.coefficientArithmeticOverflow
        }
        return result
    }

    private static func checkedSubtract(
        _ left: Int64,
        _ right: Int64
    ) throws -> Int64 {
        let (result, overflow) = left.subtractingReportingOverflow(right)
        guard !overflow else {
            throw FixedPointKernelV4Error.coefficientArithmeticOverflow
        }
        return result
    }
}

/// Canonical ordered kernel IR. Phase indices are explicit and stable, so a
/// Metal table cannot infer identity from dictionary or file ordering.
struct FixedPointKernelIRV4: Codable, Equatable, Hashable, Sendable {
    static let schemaVersion = 1

    let coefficientProcedureID: String
    let fractionalBits: Int
    let horizontalKernels: [FixedPointPhaseKernelV4]
    let verticalKernels: [FixedPointPhaseKernelV4]
    let horizontalKernelIndexByDestination: [Int]
    let verticalKernelIndexByDestination: [Int]

    init(scalePlan: SpatialScalePlanV4) throws {
        self.coefficientProcedureID = FixedPointCoefficientCompilerV4.procedureID
        self.fractionalBits = FixedPointCoefficientCompilerV4.fractionalBits
        self.horizontalKernels = try scalePlan.horizontal.uniquePhases.map(
            FixedPointCoefficientCompilerV4.compile
        )
        self.verticalKernels = try scalePlan.vertical.uniquePhases.map(
            FixedPointCoefficientCompilerV4.compile
        )
        self.horizontalKernelIndexByDestination = try Self.indices(
            positions: scalePlan.horizontal.positions,
            kernels: horizontalKernels
        )
        self.verticalKernelIndexByDestination = try Self.indices(
            positions: scalePlan.vertical.positions,
            kernels: verticalKernels
        )
    }

    /// Rejects an IR that was not derived byte-for-byte from the supplied
    /// canonical scale plan and the release-locked coefficient procedure.
    /// This prevents a decoded or caller-constructed table from selecting a
    /// different kernel while still presenting valid dimensions.
    func validate(scalePlan: SpatialScalePlanV4) throws {
        try validateStructure()
        guard self == (try FixedPointKernelIRV4(scalePlan: scalePlan)) else {
            throw FixedPointKernelV4Error.nonCanonicalKernelIR
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case coefficientProcedureID
        case fractionalBits
        case horizontalKernels
        case verticalKernels
        case horizontalKernelIndexByDestination
        case verticalKernelIndexByDestination
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        guard version == Self.schemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported fixed-point kernel IR schema."
            )
        }
        self.coefficientProcedureID = try container.decode(
            String.self,
            forKey: .coefficientProcedureID
        )
        self.fractionalBits = try container.decode(
            Int.self,
            forKey: .fractionalBits
        )
        self.horizontalKernels = try container.decode(
            [FixedPointPhaseKernelV4].self,
            forKey: .horizontalKernels
        )
        self.verticalKernels = try container.decode(
            [FixedPointPhaseKernelV4].self,
            forKey: .verticalKernels
        )
        self.horizontalKernelIndexByDestination = try container.decode(
            [Int].self,
            forKey: .horizontalKernelIndexByDestination
        )
        self.verticalKernelIndexByDestination = try container.decode(
            [Int].self,
            forKey: .verticalKernelIndexByDestination
        )
        try validateStructure()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.schemaVersion, forKey: .schemaVersion)
        try container.encode(
            coefficientProcedureID,
            forKey: .coefficientProcedureID
        )
        try container.encode(fractionalBits, forKey: .fractionalBits)
        try container.encode(horizontalKernels, forKey: .horizontalKernels)
        try container.encode(verticalKernels, forKey: .verticalKernels)
        try container.encode(
            horizontalKernelIndexByDestination,
            forKey: .horizontalKernelIndexByDestination
        )
        try container.encode(
            verticalKernelIndexByDestination,
            forKey: .verticalKernelIndexByDestination
        )
    }

    private func validateStructure() throws {
        guard coefficientProcedureID
                == FixedPointCoefficientCompilerV4.procedureID,
              fractionalBits == FixedPointCoefficientCompilerV4.fractionalBits,
              !horizontalKernels.isEmpty,
              !verticalKernels.isEmpty else {
            throw FixedPointKernelV4Error.nonCanonicalKernelIR
        }
        for kernels in [horizontalKernels, verticalKernels] {
            guard kernels.map(\.phase) == kernels.map(\.phase).sorted(),
                  Set(kernels.map(\.phase)).count == kernels.count else {
                throw FixedPointKernelV4Error.nonCanonicalKernelIR
            }
            for kernel in kernels {
                guard kernel
                        == (try FixedPointCoefficientCompilerV4.compile(
                            phase: kernel.phase
                        )) else {
                    throw FixedPointKernelV4Error.nonCanonicalKernelIR
                }
            }
        }
        guard horizontalKernelIndexByDestination.allSatisfy({
            horizontalKernels.indices.contains($0)
        }), verticalKernelIndexByDestination.allSatisfy({
            verticalKernels.indices.contains($0)
        }) else {
            throw FixedPointKernelV4Error.nonCanonicalKernelIR
        }
    }

    private static func indices(
        positions: [SpatialSamplePositionV4],
        kernels: [FixedPointPhaseKernelV4]
    ) throws -> [Int] {
        let indexByPhase = Dictionary(
            uniqueKeysWithValues: kernels.enumerated().map {
                ($0.element.phase, $0.offset)
            }
        )
        return try positions.map { position in
            guard let index = indexByPhase[position.phase] else {
                throw FixedPointKernelV4Error.phaseKernelMissing(position.phase)
            }
            return index
        }
    }
}

/// Scalar CPU reference for the shared separable fixed-point IR. It keeps the
/// horizontal Q14 accumulator unrounded and performs one Q28 ties-to-even
/// reduction after the vertical pass, making the clamp point explicit.
enum FixedPointCPUExecutorV4 {
    static func execute(
        source: [UInt16],
        sourceRowStride: Int,
        scalePlan: SpatialScalePlanV4,
        kernelIR: FixedPointKernelIRV4,
        minimumCode: UInt16,
        maximumCode: UInt16
    ) throws -> [UInt16] {
        guard minimumCode <= maximumCode else {
            throw FixedPointKernelV4Error.invalidCodeBounds(
                minimum: minimumCode,
                maximum: maximumCode
            )
        }
        let sourceWidth = scalePlan.sourceWidth
        let sourceHeight = scalePlan.sourceHeight
        let (requiredSourceCount, sourceCountOverflow) = sourceRowStride
            .multipliedReportingOverflow(by: sourceHeight)
        guard sourceRowStride >= sourceWidth,
              sourceHeight > 0,
              !sourceCountOverflow,
              source.count >= requiredSourceCount else {
            throw FixedPointKernelV4Error.invalidSourceLayout(
                width: sourceWidth,
                height: sourceHeight,
                rowStride: sourceRowStride,
                sampleCount: source.count
            )
        }
        try kernelIR.validate(scalePlan: scalePlan)

        let targetWidth = scalePlan.targetWidth
        let targetHeight = scalePlan.targetHeight
        let (horizontalCount, horizontalCountOverflow) = targetWidth
            .multipliedReportingOverflow(by: sourceHeight)
        let (outputCount, outputCountOverflow) = targetWidth
            .multipliedReportingOverflow(by: targetHeight)
        guard !horizontalCountOverflow, !outputCountOverflow else {
            throw FixedPointKernelV4Error.executionArithmeticOverflow
        }
        var horizontal = Array(repeating: Int64(0), count: horizontalCount)

        for sourceY in 0..<sourceHeight {
            for targetX in 0..<targetWidth {
                let position = scalePlan.horizontal.positions[targetX]
                let kernel = kernelIR.horizontalKernels[
                    kernelIR.horizontalKernelIndexByDestination[targetX]
                ]
                var accumulator: Int64 = 0
                for tap in 0..<FixedPointPhaseKernelV4.tapOffsets.count {
                    let rawX = position.sourceBase
                        + FixedPointPhaseKernelV4.tapOffsets[tap]
                    let sourceX = borderIndex(
                        rawX,
                        count: sourceWidth,
                        rule: scalePlan.horizontal.borderRule
                    )
                    let sample = Int64(
                        source[sourceY * sourceRowStride + sourceX]
                    )
                    accumulator = try multiplyAccumulate(
                        accumulator,
                        sample,
                        Int64(kernel.coefficients[tap])
                    )
                }
                horizontal[sourceY * targetWidth + targetX] = accumulator
            }
        }

        var output = Array(repeating: UInt16(0), count: outputCount)
        let finalShift = kernelIR.fractionalBits * 2
        for targetY in 0..<targetHeight {
            let position = scalePlan.vertical.positions[targetY]
            let kernel = kernelIR.verticalKernels[
                kernelIR.verticalKernelIndexByDestination[targetY]
            ]
            for targetX in 0..<targetWidth {
                var accumulator: Int64 = 0
                for tap in 0..<FixedPointPhaseKernelV4.tapOffsets.count {
                    let rawY = position.sourceBase
                        + FixedPointPhaseKernelV4.tapOffsets[tap]
                    let sourceY = borderIndex(
                        rawY,
                        count: sourceHeight,
                        rule: scalePlan.vertical.borderRule
                    )
                    accumulator = try multiplyAccumulate(
                        accumulator,
                        horizontal[sourceY * targetWidth + targetX],
                        Int64(kernel.coefficients[tap])
                    )
                }
                let rounded = try roundTiesToEven(
                    accumulator,
                    fractionalBits: finalShift
                )
                let clamped = min(
                    Int64(maximumCode),
                    max(Int64(minimumCode), rounded)
                )
                output[targetY * targetWidth + targetX] = UInt16(clamped)
            }
        }
        return output
    }

    private static func multiplyAccumulate(
        _ accumulator: Int64,
        _ multiplicand: Int64,
        _ multiplier: Int64
    ) throws -> Int64 {
        let (product, productOverflow) = multiplicand
            .multipliedReportingOverflow(by: multiplier)
        let (result, additionOverflow) = accumulator
            .addingReportingOverflow(product)
        guard !productOverflow, !additionOverflow else {
            throw FixedPointKernelV4Error.executionArithmeticOverflow
        }
        return result
    }

    static func roundTiesToEven(
        _ value: Int64,
        fractionalBits: Int
    ) throws -> Int64 {
        guard (0...30).contains(fractionalBits) else {
            throw FixedPointKernelV4Error.invalidCoefficientPrecision(
                fractionalBits
            )
        }
        guard fractionalBits > 0 else {
            return value
        }
        let denominator = Int64(1 << fractionalBits)
        var quotient = value / denominator
        var remainder = value % denominator
        if remainder < 0 {
            quotient -= 1
            remainder += denominator
        }
        let doubledRemainder = remainder * 2
        if doubledRemainder < denominator {
            return quotient
        }
        if doubledRemainder > denominator {
            return quotient + 1
        }
        return quotient.isMultiple(of: 2) ? quotient : quotient + 1
    }

    static func borderIndex(
        _ index: Int,
        count: Int,
        rule: SpatialBorderRuleV4
    ) -> Int {
        precondition(count > 0)
        switch rule {
        case .clamp:
            return min(count - 1, max(0, index))
        case .reflect101:
            guard count > 1 else {
                return 0
            }
            let period = 2 * (count - 1)
            var reflected = index % period
            if reflected < 0 {
                reflected += period
            }
            return reflected < count ? reflected : period - reflected
        }
    }
}
