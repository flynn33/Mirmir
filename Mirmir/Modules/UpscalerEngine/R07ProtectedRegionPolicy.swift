enum R07ProtectedContentKind: String, CaseIterable, Hashable, Sendable {
    case uiCapture = "ui_capture"
    case subtitle
    case text
    case face
    case lineArt = "line_art"
    case animation
}

enum R07ProtectedRegionPolicyError: Error, Equatable, Sendable {
    case invalidWidth(Int)
    case invalidHeight(Int)
    case sampleCountOverflow(width: Int, height: Int)
    case sampleCountAboveMaximum(actual: Int, maximum: Int)
    case sampleCountMismatch(role: String, expected: Int, actual: Int)
    case maskSampleOutOfRange(index: Int, value: Int64)
    case lumaSampleOutOfRange(role: String, index: Int, value: Int64)
    case regionDimensionMismatch(
        kind: R07ProtectedContentKind,
        expectedWidth: Int,
        expectedHeight: Int,
        actualWidth: Int,
        actualHeight: Int
    )
    case zeroWeightRejected
}

struct R07ProtectedMask: Hashable, Sendable {
    static let minimumDimension = 1
    static let maximumDimension = 64
    static let maximumSampleCount = 4_096

    let kind: R07ProtectedContentKind
    let width: Int
    let height: Int
    let samplesQ15: [R06ASHQ15]

    init(
        kind: R07ProtectedContentKind,
        width: Int,
        height: Int,
        samplesQ15: [Int64]
    ) throws {
        let expectedCount = try Self.validatedSampleCount(width: width, height: height)
        guard samplesQ15.count <= Self.maximumSampleCount else {
            throw R07ProtectedRegionPolicyError.sampleCountAboveMaximum(
                actual: samplesQ15.count,
                maximum: Self.maximumSampleCount
            )
        }
        guard samplesQ15.count == expectedCount else {
            throw R07ProtectedRegionPolicyError.sampleCountMismatch(
                role: "mask_q15",
                expected: expectedCount,
                actual: samplesQ15.count
            )
        }
        self.kind = kind
        self.width = width
        self.height = height
        self.samplesQ15 = try samplesQ15.enumerated().map { index, value in
            guard (0...R06ASHQ15.maximum).contains(value) else {
                throw R07ProtectedRegionPolicyError.maskSampleOutOfRange(
                    index: index,
                    value: value
                )
            }
            return R06ASHQ15(validatedRawValue: value)
        }
    }

    static func constantFill(
        kind: R07ProtectedContentKind,
        width: Int,
        height: Int,
        declaredSampleCount: Int,
        fillQ15: Int64
    ) throws -> R07ProtectedMask {
        let expectedCount = try validatedSampleCount(width: width, height: height)
        guard declaredSampleCount <= maximumSampleCount else {
            throw R07ProtectedRegionPolicyError.sampleCountAboveMaximum(
                actual: declaredSampleCount,
                maximum: maximumSampleCount
            )
        }
        guard declaredSampleCount == expectedCount else {
            throw R07ProtectedRegionPolicyError.sampleCountMismatch(
                role: "declared_sample_count",
                expected: expectedCount,
                actual: declaredSampleCount
            )
        }
        return try R07ProtectedMask(
            kind: kind,
            width: width,
            height: height,
            samplesQ15: Array(repeating: fillQ15, count: declaredSampleCount)
        )
    }
}

fileprivate extension R07ProtectedMask {
    static func validatedSampleCount(width: Int, height: Int) throws -> Int {
        guard width >= minimumDimension else {
            throw R07ProtectedRegionPolicyError.invalidWidth(width)
        }
        guard height >= minimumDimension else {
            throw R07ProtectedRegionPolicyError.invalidHeight(height)
        }
        let count = width.multipliedReportingOverflow(by: height)
        guard !count.overflow else {
            throw R07ProtectedRegionPolicyError.sampleCountOverflow(
                width: width,
                height: height
            )
        }
        guard width <= maximumDimension else {
            throw R07ProtectedRegionPolicyError.invalidWidth(width)
        }
        guard height <= maximumDimension else {
            throw R07ProtectedRegionPolicyError.invalidHeight(height)
        }
        guard count.partialValue <= maximumSampleCount else {
            throw R07ProtectedRegionPolicyError.sampleCountAboveMaximum(
                actual: count.partialValue,
                maximum: maximumSampleCount
            )
        }
        return count.partialValue
    }
}

struct R07ProtectedMaskComposition: Hashable, Sendable {
    let width: Int
    let height: Int
    let composedQ15: [R06ASHQ15]
    let ownerByPixel: [R07ProtectedContentKind?]
    let masks: R06ASHMaskSet

    var lumaChromaPostprocessIdentical: Bool {
        let ordered = masks.orderedMasks
        guard let first = ordered.first else {
            return false
        }
        return ordered.dropFirst().allSatisfy {
            $0.width == first.width
                && $0.height == first.height
                && $0.samplesQ15 == first.samplesQ15
        }
    }
}

struct R07WeightedMAEResult: Hashable, Sendable {
    static let thresholdQ16: Int64 = 1_024

    let weightedMAEQ16: R06ASHQ16

    var violatesProtectedIntegrity: Bool {
        weightedMAEQ16.rawValue > Self.thresholdQ16
    }
}

enum R07ProtectedRegionPolicy {
    static func compose(
        width: Int,
        height: Int,
        regions: [R07ProtectedMask]
    ) throws -> R07ProtectedMaskComposition {
        let count = try validatedCompositionCount(width: width, height: height)
        for region in regions {
            guard region.width == width, region.height == height else {
                throw R07ProtectedRegionPolicyError.regionDimensionMismatch(
                    kind: region.kind,
                    expectedWidth: width,
                    expectedHeight: height,
                    actualWidth: region.width,
                    actualHeight: region.height
                )
            }
        }

        var composed = [R06ASHQ15](repeating: .zero, count: count)
        var owners = [R07ProtectedContentKind?](repeating: nil, count: count)
        for index in 0..<count {
            for kind in R07ProtectedContentKind.allCases {
                for region in regions where region.kind == kind {
                    let sample = region.samplesQ15[index]
                    if sample > composed[index] {
                        composed[index] = sample
                        owners[index] = kind
                    }
                }
            }
        }

        let rawSamples = composed.map { UInt16($0.rawValue) }
        let masks = try R06ASHMaskSet(
            lumaProtection: R06ASHMask(
                id: .lumaProtection,
                width: width,
                height: height,
                samplesQ15: rawSamples
            ),
            chromaProtection: R06ASHMask(
                id: .chromaProtection,
                width: width,
                height: height,
                samplesQ15: rawSamples
            ),
            postprocessSuppression: R06ASHMask(
                id: .postprocessSuppression,
                width: width,
                height: height,
                samplesQ15: rawSamples
            )
        )
        return R07ProtectedMaskComposition(
            width: width,
            height: height,
            composedQ15: composed,
            ownerByPixel: owners,
            masks: masks
        )
    }

    static func weightedMAE(
        candidateQ16: [Int64],
        referenceQ16: [Int64],
        maskQ15: [Int64]
    ) throws -> R07WeightedMAEResult {
        try validateWeightedVector(candidateQ16, role: "candidate")
        try requireCount(referenceQ16, expected: candidateQ16.count, role: "reference")
        try requireCount(maskQ15, expected: candidateQ16.count, role: "mask_q15")
        try validateLumaSamples(referenceQ16, role: "reference")
        try validateMaskSamples(maskQ15)

        var weightedDifference: Int64 = 0
        var weightSum: Int64 = 0
        for index in candidateQ16.indices {
            let difference = try R07ArtifactCheckedInt64.absoluteDifference(
                candidateQ16[index],
                referenceQ16[index],
                operation: "weighted_mae_difference"
            )
            let product = try R07ArtifactCheckedInt64.multiply(
                difference,
                maskQ15[index],
                operation: "weighted_mae_multiply"
            )
            weightedDifference = try R07ArtifactCheckedInt64.add(
                weightedDifference,
                product,
                operation: "weighted_mae_numerator_sum"
            )
            weightSum = try R07ArtifactCheckedInt64.add(
                weightSum,
                maskQ15[index],
                operation: "weighted_mae_weight_sum"
            )
        }
        guard weightSum > 0 else {
            throw R07ProtectedRegionPolicyError.zeroWeightRejected
        }
        return R07WeightedMAEResult(
            weightedMAEQ16: try R06ASHQ16(weightedDifference / weightSum)
        )
    }
}

private extension R07ProtectedRegionPolicy {
    static func validatedCompositionCount(width: Int, height: Int) throws -> Int {
        try R07ProtectedMask.validatedSampleCount(width: width, height: height)
    }

    static func validateWeightedVector(_ values: [Int64], role: String) throws {
        guard values.count <= R07ProtectedMask.maximumSampleCount else {
            throw R07ProtectedRegionPolicyError.sampleCountAboveMaximum(
                actual: values.count,
                maximum: R07ProtectedMask.maximumSampleCount
            )
        }
        try validateLumaSamples(values, role: role)
    }

    static func validateLumaSamples(_ values: [Int64], role: String) throws {
        if let invalid = values.enumerated().first(where: {
            !(0...R06ASHQ16.scale).contains($0.element)
        }) {
            throw R07ProtectedRegionPolicyError.lumaSampleOutOfRange(
                role: role,
                index: invalid.offset,
                value: invalid.element
            )
        }
    }

    static func validateMaskSamples(_ values: [Int64]) throws {
        if let invalid = values.enumerated().first(where: {
            !(0...R06ASHQ15.maximum).contains($0.element)
        }) {
            throw R07ProtectedRegionPolicyError.maskSampleOutOfRange(
                index: invalid.offset,
                value: invalid.element
            )
        }
    }

    static func requireCount<Element>(
        _ values: [Element],
        expected: Int,
        role: String
    ) throws {
        guard values.count == expected else {
            throw R07ProtectedRegionPolicyError.sampleCountMismatch(
                role: role,
                expected: expected,
                actual: values.count
            )
        }
    }
}
