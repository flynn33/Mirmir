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
    case invalidDestinationLayout(expectedCount: Int, actualCount: Int)
    case overlappingSourceAndDestination
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

/// Four source indices and coefficients prepared once from one canonical axis.
/// The explicit fields preserve the declared tap order without per-pixel
/// arrays, dictionary lookups, phase resolution, or border arithmetic.
struct FixedPointPreparedAxisSampleV4: Equatable, Sendable {
    let source0: Int
    let source1: Int
    let source2: Int
    let source3: Int
    let coefficient0: Int64
    let coefficient1: Int64
    let coefficient2: Int64
    let coefficient3: Int64

    @inline(__always)
    fileprivate func contains(source: Int) -> Bool {
        source0 == source || source1 == source
            || source2 == source || source3 == source
    }

    fileprivate var absoluteCoefficientSum: UInt64 {
        coefficient0.magnitude + coefficient1.magnitude
            + coefficient2.magnitude + coefficient3.magnitude
    }
}

/// Validated, immutable hot-path representation shared by repeated plane
/// executions. Border indices and coefficient selections are fully resolved.
struct FixedPointPreparedScaleV4: Equatable, Sendable {
    let sourceWidth: Int
    let sourceHeight: Int
    let targetWidth: Int
    let targetHeight: Int
    let outputSampleCount: Int
    let finalFractionalBits: Int
    let horizontalSamples: [FixedPointPreparedAxisSampleV4]
    let verticalSamples: [FixedPointPreparedAxisSampleV4]

    init(
        scalePlan: SpatialScalePlanV4,
        kernelIR: FixedPointKernelIRV4
    ) throws {
        try kernelIR.validate(scalePlan: scalePlan)
        let (outputSampleCount, outputOverflow) = scalePlan.targetWidth
            .multipliedReportingOverflow(by: scalePlan.targetHeight)
        guard !outputOverflow else {
            throw FixedPointKernelV4Error.executionArithmeticOverflow
        }
        let horizontal = try Self.prepare(
            positions: scalePlan.horizontal.positions,
            kernelIndices: kernelIR.horizontalKernelIndexByDestination,
            kernels: kernelIR.horizontalKernels,
            sourceCount: scalePlan.sourceWidth,
            borderRule: scalePlan.horizontal.borderRule
        )
        let vertical = try Self.prepare(
            positions: scalePlan.vertical.positions,
            kernelIndices: kernelIR.verticalKernelIndexByDestination,
            kernels: kernelIR.verticalKernels,
            sourceCount: scalePlan.sourceHeight,
            borderRule: scalePlan.vertical.borderRule
        )
        try Self.validateAccumulatorBounds(
            horizontal: horizontal,
            vertical: vertical
        )
        self.sourceWidth = scalePlan.sourceWidth
        self.sourceHeight = scalePlan.sourceHeight
        self.targetWidth = scalePlan.targetWidth
        self.targetHeight = scalePlan.targetHeight
        self.outputSampleCount = outputSampleCount
        self.finalFractionalBits = kernelIR.fractionalBits * 2
        self.horizontalSamples = horizontal
        self.verticalSamples = vertical
    }

    private static func prepare(
        positions: [SpatialSamplePositionV4],
        kernelIndices: [Int],
        kernels: [FixedPointPhaseKernelV4],
        sourceCount: Int,
        borderRule: SpatialBorderRuleV4
    ) throws -> [FixedPointPreparedAxisSampleV4] {
        guard positions.count == kernelIndices.count else {
            throw FixedPointKernelV4Error.nonCanonicalKernelIR
        }
        return try positions.indices.map { destination in
            let position = positions[destination]
            let kernelIndex = kernelIndices[destination]
            guard kernels.indices.contains(kernelIndex) else {
                throw FixedPointKernelV4Error.nonCanonicalKernelIR
            }
            let kernel = kernels[kernelIndex]
            let indices = FixedPointPhaseKernelV4.tapOffsets.map { offset in
                FixedPointCPUExecutorV4.borderIndex(
                    position.sourceBase + offset,
                    count: sourceCount,
                    rule: borderRule
                )
            }
            return FixedPointPreparedAxisSampleV4(
                source0: indices[0],
                source1: indices[1],
                source2: indices[2],
                source3: indices[3],
                coefficient0: Int64(kernel.coefficients[0]),
                coefficient1: Int64(kernel.coefficients[1]),
                coefficient2: Int64(kernel.coefficients[2]),
                coefficient3: Int64(kernel.coefficients[3])
            )
        }
    }

    /// Canonical Q14 coefficients and UInt16 inputs have a much smaller bound
    /// than Int64. Proving that once permits wrapping operators in the timed
    /// loop while retaining fail-closed preparation for a changed contract.
    private static func validateAccumulatorBounds(
        horizontal: [FixedPointPreparedAxisSampleV4],
        vertical: [FixedPointPreparedAxisSampleV4]
    ) throws {
        guard let horizontalSum = horizontal.map(\.absoluteCoefficientSum).max(),
              let verticalSum = vertical.map(\.absoluteCoefficientSum).max()
        else {
            throw FixedPointKernelV4Error.nonCanonicalKernelIR
        }
        let horizontalBound = UInt64(UInt16.max)
            .multipliedReportingOverflow(by: horizontalSum)
        let finalBound = horizontalBound.partialValue
            .multipliedReportingOverflow(by: verticalSum)
        guard !horizontalBound.overflow,
              !finalBound.overflow,
              finalBound.partialValue <= UInt64(Int64.max) else {
            throw FixedPointKernelV4Error.executionArithmeticOverflow
        }
    }
}

/// Four-row separable cache reused across frames. It bounds intermediate
/// storage to `4 * targetWidth` Int64 values instead of a full source-height
/// plane and retains its allocation while the prepared scale is unchanged.
struct FixedPointCPUWorkspaceV4: Sendable {
    fileprivate var horizontalRows: [Int64] = []
    fileprivate var sourceRowBySlot = Array(repeating: -1, count: 4)
    private(set) var allocationCount = 0

    var reusableHorizontalSampleCount: Int { horizontalRows.count }

    var reusableStorageIdentity: UInt {
        horizontalRows.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return 0 }
            return UInt(bitPattern: baseAddress)
        }
    }

    /// Reserves the complete bounded workspace. Callers that process a frame
    /// stream do this during scaler preparation; frame execution subsequently
    /// resets only the four source-row tags and never changes array capacity.
    mutating func prepare(targetWidth: Int) throws {
        let (sampleCount, overflow) = targetWidth.multipliedReportingOverflow(
            by: 4
        )
        guard !overflow else {
            throw FixedPointKernelV4Error.executionArithmeticOverflow
        }
        if horizontalRows.count != sampleCount {
            horizontalRows = Array(repeating: 0, count: sampleCount)
            allocationCount += 1
        }
        for slot in sourceRowBySlot.indices {
            sourceRowBySlot[slot] = -1
        }
    }
}

/// Optimized CPU executor for the shared separable fixed-point IR. The Metal
/// path fuses all 16 products per destination; CPU uses a bounded four-row
/// separable cache because that performs fewer products while preserving the
/// same unrounded horizontal Q14 and single ordered Q28 reduction.
enum FixedPointCPUExecutorV4 {
    static func execute(
        source: [UInt16],
        sourceRowStride: Int,
        scalePlan: SpatialScalePlanV4,
        kernelIR: FixedPointKernelIRV4,
        minimumCode: UInt16,
        maximumCode: UInt16
    ) throws -> [UInt16] {
        let prepared = try FixedPointPreparedScaleV4(
            scalePlan: scalePlan,
            kernelIR: kernelIR
        )
        var workspace = FixedPointCPUWorkspaceV4()
        return try execute(
            source: source,
            sourceRowStride: sourceRowStride,
            preparedScale: prepared,
            minimumCode: minimumCode,
            maximumCode: maximumCode,
            workspace: &workspace
        )
    }

    static func execute(
        source: [UInt16],
        sourceRowStride: Int,
        preparedScale: FixedPointPreparedScaleV4,
        minimumCode: UInt16,
        maximumCode: UInt16,
        workspace: inout FixedPointCPUWorkspaceV4
    ) throws -> [UInt16] {
        var output = Array(
            repeating: UInt16(0),
            count: preparedScale.outputSampleCount
        )
        try source.withUnsafeBufferPointer { sourceBuffer in
            try output.withUnsafeMutableBufferPointer { outputBuffer in
                try execute(
                    source: sourceBuffer,
                    sourceRowStride: sourceRowStride,
                    preparedScale: preparedScale,
                    minimumCode: minimumCode,
                    maximumCode: maximumCode,
                    destination: outputBuffer,
                    workspace: &workspace
                )
            }
        }
        return output
    }

    static func execute(
        source: UnsafeBufferPointer<UInt16>,
        sourceRowStride: Int,
        preparedScale: FixedPointPreparedScaleV4,
        minimumCode: UInt16,
        maximumCode: UInt16,
        destination: UnsafeMutableBufferPointer<UInt16>,
        workspace: inout FixedPointCPUWorkspaceV4
    ) throws {
        guard minimumCode <= maximumCode else {
            throw FixedPointKernelV4Error.invalidCodeBounds(
                minimum: minimumCode,
                maximum: maximumCode
            )
        }
        let (requiredSourceCount, sourceCountOverflow) = sourceRowStride
            .multipliedReportingOverflow(by: preparedScale.sourceHeight)
        guard sourceRowStride >= preparedScale.sourceWidth,
              !sourceCountOverflow,
              source.count >= requiredSourceCount else {
            throw FixedPointKernelV4Error.invalidSourceLayout(
                width: preparedScale.sourceWidth,
                height: preparedScale.sourceHeight,
                rowStride: sourceRowStride,
                sampleCount: source.count
            )
        }
        guard destination.count >= preparedScale.outputSampleCount else {
            throw FixedPointKernelV4Error.invalidDestinationLayout(
                expectedCount: preparedScale.outputSampleCount,
                actualCount: destination.count
            )
        }
        try validateNonoverlapping(
            source: source,
            requiredSourceCount: requiredSourceCount,
            destination: destination,
            requiredDestinationCount: preparedScale.outputSampleCount
        )
        try workspace.prepare(targetWidth: preparedScale.targetWidth)

        let minimum = Int64(minimumCode)
        let maximum = Int64(maximumCode)
        for targetY in 0..<preparedScale.targetHeight {
            let vertical = preparedScale.verticalSamples[targetY]
            let slot0 = horizontalRowSlot(
                sourceY: vertical.source0,
                retaining: vertical,
                source: source,
                sourceRowStride: sourceRowStride,
                preparedScale: preparedScale,
                workspace: &workspace
            )
            let slot1 = horizontalRowSlot(
                sourceY: vertical.source1,
                retaining: vertical,
                source: source,
                sourceRowStride: sourceRowStride,
                preparedScale: preparedScale,
                workspace: &workspace
            )
            let slot2 = horizontalRowSlot(
                sourceY: vertical.source2,
                retaining: vertical,
                source: source,
                sourceRowStride: sourceRowStride,
                preparedScale: preparedScale,
                workspace: &workspace
            )
            let slot3 = horizontalRowSlot(
                sourceY: vertical.source3,
                retaining: vertical,
                source: source,
                sourceRowStride: sourceRowStride,
                preparedScale: preparedScale,
                workspace: &workspace
            )
            let row0 = slot0 * preparedScale.targetWidth
            let row1 = slot1 * preparedScale.targetWidth
            let row2 = slot2 * preparedScale.targetWidth
            let row3 = slot3 * preparedScale.targetWidth
            let outputRow = targetY * preparedScale.targetWidth
            for targetX in 0..<preparedScale.targetWidth {
                var accumulator = workspace.horizontalRows[row0 + targetX]
                    &* vertical.coefficient0
                accumulator = accumulator &+ (
                    workspace.horizontalRows[row1 + targetX]
                        &* vertical.coefficient1
                )
                accumulator = accumulator &+ (
                    workspace.horizontalRows[row2 + targetX]
                        &* vertical.coefficient2
                )
                accumulator = accumulator &+ (
                    workspace.horizontalRows[row3 + targetX]
                        &* vertical.coefficient3
                )
                let rounded = roundTiesToEvenPrepared(
                    accumulator,
                    fractionalBits: preparedScale.finalFractionalBits
                )
                destination[outputRow + targetX] = UInt16(
                    min(maximum, max(minimum, rounded))
                )
            }
        }
    }

    /// Executes directly against one component of an interleaved byte plane.
    /// The caller owns and locks both planes and has already validated every
    /// visible stored source code. This path retains the exact same ordered
    /// Q14/Q28 reduction as the planar reference entry point while avoiding a
    /// source plane, destination plane, or full-height intermediate array.
    static func executeInterleavedComponent(
        sourceBaseAddress: UnsafeRawPointer,
        sourceRowBytes: Int,
        destinationBaseAddress: UnsafeMutableRawPointer,
        destinationRowBytes: Int,
        bytesPerComponent: Int,
        componentsPerElement: Int,
        componentIndex: Int,
        storedCodeShift: Int,
        preparedScale: FixedPointPreparedScaleV4,
        minimumCode: UInt16,
        maximumCode: UInt16,
        workspace: inout FixedPointCPUWorkspaceV4
    ) throws {
        guard minimumCode <= maximumCode else {
            throw FixedPointKernelV4Error.invalidCodeBounds(
                minimum: minimumCode,
                maximum: maximumCode
            )
        }
        let storageBitCount: Int
        let maximumStoredCode: UInt32
        switch bytesPerComponent {
        case 1:
            storageBitCount = 8
            maximumStoredCode = UInt32(UInt8.max)
        case 2:
            storageBitCount = 16
            maximumStoredCode = UInt32(UInt16.max)
        default:
            throw FixedPointKernelV4Error.executionArithmeticOverflow
        }
        guard componentsPerElement > 0,
              (0..<componentsPerElement).contains(componentIndex),
              (0..<storageBitCount).contains(storedCodeShift),
              (UInt32(maximumCode) << UInt32(storedCodeShift))
                <= maximumStoredCode else {
            throw FixedPointKernelV4Error.executionArithmeticOverflow
        }
        let sourceActiveBytes = try activeRowByteCount(
            width: preparedScale.sourceWidth,
            bytesPerComponent: bytesPerComponent,
            componentsPerElement: componentsPerElement
        )
        let destinationActiveBytes = try activeRowByteCount(
            width: preparedScale.targetWidth,
            bytesPerComponent: bytesPerComponent,
            componentsPerElement: componentsPerElement
        )
        guard sourceRowBytes >= sourceActiveBytes else {
            throw FixedPointKernelV4Error.invalidSourceLayout(
                width: preparedScale.sourceWidth,
                height: preparedScale.sourceHeight,
                rowStride: sourceRowBytes,
                sampleCount: sourceActiveBytes
            )
        }
        guard destinationRowBytes >= destinationActiveBytes else {
            throw FixedPointKernelV4Error.invalidDestinationLayout(
                expectedCount: destinationActiveBytes,
                actualCount: destinationRowBytes
            )
        }
        try validateNonoverlapping(
            sourceBaseAddress: sourceBaseAddress,
            sourceRowBytes: sourceRowBytes,
            sourceHeight: preparedScale.sourceHeight,
            destinationBaseAddress: destinationBaseAddress,
            destinationRowBytes: destinationRowBytes,
            destinationHeight: preparedScale.targetHeight
        )
        try workspace.prepare(targetWidth: preparedScale.targetWidth)

        let minimum = Int64(minimumCode)
        let maximum = Int64(maximumCode)
        for targetY in 0..<preparedScale.targetHeight {
            let vertical = preparedScale.verticalSamples[targetY]
            let slot0 = horizontalRowSlotInterleaved(
                sourceY: vertical.source0,
                retaining: vertical,
                sourceBaseAddress: sourceBaseAddress,
                sourceRowBytes: sourceRowBytes,
                bytesPerComponent: bytesPerComponent,
                componentsPerElement: componentsPerElement,
                componentIndex: componentIndex,
                storedCodeShift: storedCodeShift,
                preparedScale: preparedScale,
                workspace: &workspace
            )
            let slot1 = horizontalRowSlotInterleaved(
                sourceY: vertical.source1,
                retaining: vertical,
                sourceBaseAddress: sourceBaseAddress,
                sourceRowBytes: sourceRowBytes,
                bytesPerComponent: bytesPerComponent,
                componentsPerElement: componentsPerElement,
                componentIndex: componentIndex,
                storedCodeShift: storedCodeShift,
                preparedScale: preparedScale,
                workspace: &workspace
            )
            let slot2 = horizontalRowSlotInterleaved(
                sourceY: vertical.source2,
                retaining: vertical,
                sourceBaseAddress: sourceBaseAddress,
                sourceRowBytes: sourceRowBytes,
                bytesPerComponent: bytesPerComponent,
                componentsPerElement: componentsPerElement,
                componentIndex: componentIndex,
                storedCodeShift: storedCodeShift,
                preparedScale: preparedScale,
                workspace: &workspace
            )
            let slot3 = horizontalRowSlotInterleaved(
                sourceY: vertical.source3,
                retaining: vertical,
                sourceBaseAddress: sourceBaseAddress,
                sourceRowBytes: sourceRowBytes,
                bytesPerComponent: bytesPerComponent,
                componentsPerElement: componentsPerElement,
                componentIndex: componentIndex,
                storedCodeShift: storedCodeShift,
                preparedScale: preparedScale,
                workspace: &workspace
            )
            let row0 = slot0 * preparedScale.targetWidth
            let row1 = slot1 * preparedScale.targetWidth
            let row2 = slot2 * preparedScale.targetWidth
            let row3 = slot3 * preparedScale.targetWidth
            for targetX in 0..<preparedScale.targetWidth {
                var accumulator = workspace.horizontalRows[row0 + targetX]
                    &* vertical.coefficient0
                accumulator = accumulator &+ (
                    workspace.horizontalRows[row1 + targetX]
                        &* vertical.coefficient1
                )
                accumulator = accumulator &+ (
                    workspace.horizontalRows[row2 + targetX]
                        &* vertical.coefficient2
                )
                accumulator = accumulator &+ (
                    workspace.horizontalRows[row3 + targetX]
                        &* vertical.coefficient3
                )
                let rounded = roundTiesToEvenPrepared(
                    accumulator,
                    fractionalBits: preparedScale.finalFractionalBits
                )
                storeSignalCode(
                    UInt16(min(maximum, max(minimum, rounded))),
                    baseAddress: destinationBaseAddress,
                    rowBytes: destinationRowBytes,
                    x: targetX,
                    y: targetY,
                    bytesPerComponent: bytesPerComponent,
                    componentsPerElement: componentsPerElement,
                    componentIndex: componentIndex,
                    storedCodeShift: storedCodeShift
                )
            }
        }
    }

    @inline(__always)
    private static func horizontalRowSlot(
        sourceY: Int,
        retaining vertical: FixedPointPreparedAxisSampleV4,
        source: UnsafeBufferPointer<UInt16>,
        sourceRowStride: Int,
        preparedScale: FixedPointPreparedScaleV4,
        workspace: inout FixedPointCPUWorkspaceV4
    ) -> Int {
        for slot in 0..<4 where workspace.sourceRowBySlot[slot] == sourceY {
            return slot
        }
        var replacement = 0
        while replacement < 4,
              vertical.contains(source: workspace.sourceRowBySlot[replacement]) {
            replacement += 1
        }
        precondition(replacement < 4)
        workspace.sourceRowBySlot[replacement] = sourceY
        let sourceRow = sourceY * sourceRowStride
        let horizontalRow = replacement * preparedScale.targetWidth
        for targetX in 0..<preparedScale.targetWidth {
            let horizontal = preparedScale.horizontalSamples[targetX]
            var accumulator = Int64(source[sourceRow + horizontal.source0])
                &* horizontal.coefficient0
            accumulator = accumulator &+ (
                Int64(source[sourceRow + horizontal.source1])
                    &* horizontal.coefficient1
            )
            accumulator = accumulator &+ (
                Int64(source[sourceRow + horizontal.source2])
                    &* horizontal.coefficient2
            )
            accumulator = accumulator &+ (
                Int64(source[sourceRow + horizontal.source3])
                    &* horizontal.coefficient3
            )
            workspace.horizontalRows[horizontalRow + targetX] = accumulator
        }
        return replacement
    }

    @inline(__always)
    private static func horizontalRowSlotInterleaved(
        sourceY: Int,
        retaining vertical: FixedPointPreparedAxisSampleV4,
        sourceBaseAddress: UnsafeRawPointer,
        sourceRowBytes: Int,
        bytesPerComponent: Int,
        componentsPerElement: Int,
        componentIndex: Int,
        storedCodeShift: Int,
        preparedScale: FixedPointPreparedScaleV4,
        workspace: inout FixedPointCPUWorkspaceV4
    ) -> Int {
        for slot in 0..<4 where workspace.sourceRowBySlot[slot] == sourceY {
            return slot
        }
        var replacement = 0
        while replacement < 4,
              vertical.contains(source: workspace.sourceRowBySlot[replacement]) {
            replacement += 1
        }
        precondition(replacement < 4)
        workspace.sourceRowBySlot[replacement] = sourceY
        let horizontalRow = replacement * preparedScale.targetWidth
        for targetX in 0..<preparedScale.targetWidth {
            let horizontal = preparedScale.horizontalSamples[targetX]
            var accumulator = Int64(loadSignalCode(
                baseAddress: sourceBaseAddress,
                rowBytes: sourceRowBytes,
                x: horizontal.source0,
                y: sourceY,
                bytesPerComponent: bytesPerComponent,
                componentsPerElement: componentsPerElement,
                componentIndex: componentIndex,
                storedCodeShift: storedCodeShift
            )) &* horizontal.coefficient0
            accumulator = accumulator &+ (
                Int64(loadSignalCode(
                    baseAddress: sourceBaseAddress,
                    rowBytes: sourceRowBytes,
                    x: horizontal.source1,
                    y: sourceY,
                    bytesPerComponent: bytesPerComponent,
                    componentsPerElement: componentsPerElement,
                    componentIndex: componentIndex,
                    storedCodeShift: storedCodeShift
                )) &* horizontal.coefficient1
            )
            accumulator = accumulator &+ (
                Int64(loadSignalCode(
                    baseAddress: sourceBaseAddress,
                    rowBytes: sourceRowBytes,
                    x: horizontal.source2,
                    y: sourceY,
                    bytesPerComponent: bytesPerComponent,
                    componentsPerElement: componentsPerElement,
                    componentIndex: componentIndex,
                    storedCodeShift: storedCodeShift
                )) &* horizontal.coefficient2
            )
            accumulator = accumulator &+ (
                Int64(loadSignalCode(
                    baseAddress: sourceBaseAddress,
                    rowBytes: sourceRowBytes,
                    x: horizontal.source3,
                    y: sourceY,
                    bytesPerComponent: bytesPerComponent,
                    componentsPerElement: componentsPerElement,
                    componentIndex: componentIndex,
                    storedCodeShift: storedCodeShift
                )) &* horizontal.coefficient3
            )
            workspace.horizontalRows[horizontalRow + targetX] = accumulator
        }
        return replacement
    }

    @inline(__always)
    private static func loadSignalCode(
        baseAddress: UnsafeRawPointer,
        rowBytes: Int,
        x: Int,
        y: Int,
        bytesPerComponent: Int,
        componentsPerElement: Int,
        componentIndex: Int,
        storedCodeShift: Int
    ) -> UInt16 {
        let row = baseAddress.advanced(by: y * rowBytes)
            .assumingMemoryBound(to: UInt8.self)
        let sampleIndex = x * componentsPerElement + componentIndex
        let stored: UInt16
        if bytesPerComponent == 1 {
            stored = UInt16(row[sampleIndex])
        } else {
            let offset = sampleIndex * 2
            stored = UInt16(row[offset]) | (UInt16(row[offset + 1]) << 8)
        }
        return stored >> UInt16(storedCodeShift)
    }

    @inline(__always)
    private static func storeSignalCode(
        _ signalCode: UInt16,
        baseAddress: UnsafeMutableRawPointer,
        rowBytes: Int,
        x: Int,
        y: Int,
        bytesPerComponent: Int,
        componentsPerElement: Int,
        componentIndex: Int,
        storedCodeShift: Int
    ) {
        let row = baseAddress.advanced(by: y * rowBytes)
            .assumingMemoryBound(to: UInt8.self)
        let sampleIndex = x * componentsPerElement + componentIndex
        let stored = signalCode << UInt16(storedCodeShift)
        if bytesPerComponent == 1 {
            row[sampleIndex] = UInt8(truncatingIfNeeded: stored)
        } else {
            let offset = sampleIndex * 2
            row[offset] = UInt8(truncatingIfNeeded: stored)
            row[offset + 1] = UInt8(truncatingIfNeeded: stored >> 8)
        }
    }

    private static func activeRowByteCount(
        width: Int,
        bytesPerComponent: Int,
        componentsPerElement: Int
    ) throws -> Int {
        let components = width.multipliedReportingOverflow(
            by: componentsPerElement
        )
        let bytes = components.partialValue.multipliedReportingOverflow(
            by: bytesPerComponent
        )
        guard !components.overflow, !bytes.overflow else {
            throw FixedPointKernelV4Error.executionArithmeticOverflow
        }
        return bytes.partialValue
    }

    private static func validateNonoverlapping(
        sourceBaseAddress: UnsafeRawPointer,
        sourceRowBytes: Int,
        sourceHeight: Int,
        destinationBaseAddress: UnsafeMutableRawPointer,
        destinationRowBytes: Int,
        destinationHeight: Int
    ) throws {
        let sourceBytes = sourceRowBytes.multipliedReportingOverflow(
            by: sourceHeight
        )
        let destinationBytes = destinationRowBytes.multipliedReportingOverflow(
            by: destinationHeight
        )
        guard !sourceBytes.overflow,
              !destinationBytes.overflow,
              let sourceByteCount = UInt(exactly: sourceBytes.partialValue),
              let destinationByteCount = UInt(
                exactly: destinationBytes.partialValue
              ) else {
            throw FixedPointKernelV4Error.executionArithmeticOverflow
        }
        let sourceStart = UInt(bitPattern: sourceBaseAddress)
        let destinationStart = UInt(bitPattern: destinationBaseAddress)
        let sourceEnd = sourceStart.addingReportingOverflow(
            sourceByteCount
        )
        let destinationEnd = destinationStart.addingReportingOverflow(
            destinationByteCount
        )
        guard !sourceEnd.overflow,
              !destinationEnd.overflow else {
            throw FixedPointKernelV4Error.executionArithmeticOverflow
        }
        if sourceStart < destinationEnd.partialValue,
           destinationStart < sourceEnd.partialValue {
            throw FixedPointKernelV4Error.overlappingSourceAndDestination
        }
    }

    private static func validateNonoverlapping(
        source: UnsafeBufferPointer<UInt16>,
        requiredSourceCount: Int,
        destination: UnsafeMutableBufferPointer<UInt16>,
        requiredDestinationCount: Int
    ) throws {
        guard let sourceAddress = source.baseAddress,
              let destinationAddress = destination.baseAddress else {
            return
        }
        let sourceByteCount = requiredSourceCount.multipliedReportingOverflow(
            by: MemoryLayout<UInt16>.stride
        )
        let destinationByteCount = requiredDestinationCount
            .multipliedReportingOverflow(by: MemoryLayout<UInt16>.stride)
        guard !sourceByteCount.overflow,
              !destinationByteCount.overflow,
              let sourceByteLength = UInt(exactly: sourceByteCount.partialValue),
              let destinationByteLength = UInt(
                exactly: destinationByteCount.partialValue
              ) else {
            throw FixedPointKernelV4Error.executionArithmeticOverflow
        }
        let sourceStart = UInt(bitPattern: sourceAddress)
        let destinationStart = UInt(bitPattern: destinationAddress)
        let sourceEnd = sourceStart.addingReportingOverflow(
            sourceByteLength
        )
        let destinationEnd = destinationStart.addingReportingOverflow(
            destinationByteLength
        )
        guard !sourceEnd.overflow,
              !destinationEnd.overflow else {
            throw FixedPointKernelV4Error.executionArithmeticOverflow
        }
        if sourceStart < destinationEnd.partialValue,
           destinationStart < sourceEnd.partialValue {
            throw FixedPointKernelV4Error.overlappingSourceAndDestination
        }
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
        return roundTiesToEvenPrepared(
            value,
            fractionalBits: fractionalBits
        )
    }

    @inline(__always)
    private static func roundTiesToEvenPrepared(
        _ value: Int64,
        fractionalBits: Int
    ) -> Int64 {
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
