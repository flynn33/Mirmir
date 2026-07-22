import Foundation

enum R07CheckedInt64Error: Error, Equatable, Sendable {
    case overflow(operation: String)
    case divisionByZero
    case minimumMagnitude
}

enum R07CheckedInt64 {
    static func add(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let result = lhs.addingReportingOverflow(rhs)
        guard !result.overflow else {
            throw R07CheckedInt64Error.overflow(operation: "addition")
        }
        return result.partialValue
    }

    static func subtract(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let result = lhs.subtractingReportingOverflow(rhs)
        guard !result.overflow else {
            throw R07CheckedInt64Error.overflow(operation: "subtraction")
        }
        return result.partialValue
    }

    static func multiply(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let result = lhs.multipliedReportingOverflow(by: rhs)
        guard !result.overflow else {
            throw R07CheckedInt64Error.overflow(operation: "multiplication")
        }
        return result.partialValue
    }

    static func divideTowardZero(_ numerator: Int64, by denominator: Int64) throws -> Int64 {
        guard denominator != 0 else {
            throw R07CheckedInt64Error.divisionByZero
        }
        guard numerator != Int64.min || denominator != -1 else {
            throw R07CheckedInt64Error.overflow(operation: "division")
        }
        return numerator / denominator
    }

    static func magnitude(_ value: Int64) throws -> Int64 {
        guard value != Int64.min else {
            throw R07CheckedInt64Error.minimumMagnitude
        }
        return value < 0 ? -value : value
    }

    static func absoluteDifference(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        try magnitude(subtract(lhs, rhs))
    }
}

enum R07TemporalVectorRole: String, Equatable, Sendable {
    case current
    case previous
    case alignedPrevious = "aligned_previous"
    case occlusionMask = "occlusion_mask"
}

enum R07TemporalAnalysisError: Error, Equatable, Sendable {
    case emptyVectorRejected
    case sampleCountMismatchRejected
    case vectorOrMaskOversizeRejected(actual: Int, maximum: Int)
    case frameOrdinalsNotStrictlyIncreasing(previous: Int64, current: Int64)
    case lumaSampleOutOfRange(role: R07TemporalVectorRole, index: Int, value: Int64)
    case invalidOcclusionMaskValue(index: Int, value: Int64)
    case noValidMotionSamplesRejected

    var reason: String {
        switch self {
        case .emptyVectorRejected:
            return "empty_vector_rejected"
        case .sampleCountMismatchRejected:
            return "sample_count_mismatch_rejected"
        case .vectorOrMaskOversizeRejected:
            return "vector_or_mask_oversize_rejected"
        case .frameOrdinalsNotStrictlyIncreasing:
            return "frame_ordinals_not_strictly_increasing"
        case .lumaSampleOutOfRange:
            return "luma_sample_out_of_range"
        case .invalidOcclusionMaskValue:
            return "invalid_occlusion_mask_value"
        case .noValidMotionSamplesRejected:
            return "no_valid_motion_samples_rejected"
        }
    }
}

struct R07TemporalAnalysisInput: Equatable, Sendable {
    let previousFrameOrdinal: Int64
    let currentFrameOrdinal: Int64
    let currentLumaQ16: [Int64]
    let previousLumaQ16: [Int64]
    let alignedPreviousLumaQ16: [Int64]
    let occlusionMask: [Int64]

    static func constantFill(
        previousFrameOrdinal: Int64,
        currentFrameOrdinal: Int64,
        declaredSampleCount: Int,
        currentFillQ16: Int64,
        previousFillQ16: Int64,
        alignedPreviousFillQ16: Int64,
        occlusionFill: Int64
    ) throws -> Self {
        guard declaredSampleCount > 0 else {
            throw R07TemporalAnalysisError.emptyVectorRejected
        }
        guard declaredSampleCount <= R07TemporalAnalysisEngine.maximumSampleCount else {
            throw R07TemporalAnalysisError.vectorOrMaskOversizeRejected(
                actual: declaredSampleCount,
                maximum: R07TemporalAnalysisEngine.maximumSampleCount
            )
        }
        return Self(
            previousFrameOrdinal: previousFrameOrdinal,
            currentFrameOrdinal: currentFrameOrdinal,
            currentLumaQ16: Array(repeating: currentFillQ16, count: declaredSampleCount),
            previousLumaQ16: Array(repeating: previousFillQ16, count: declaredSampleCount),
            alignedPreviousLumaQ16: Array(
                repeating: alignedPreviousFillQ16,
                count: declaredSampleCount
            ),
            occlusionMask: Array(repeating: occlusionFill, count: declaredSampleCount)
        )
    }
}

struct R07TemporalAnalysisResult: Equatable, Sendable {
    let sampleCount: Int
    let sceneCutRawQ16: R06ASHQ16
    let sceneCutDetected: Bool
    let motionConfidenceQ16: R06ASHQ16
    let motionValid: Bool
    let validMotionSampleCount: Int
    let occlusionQ16: R06ASHQ16
    let occlusionDetected: Bool
}

enum R07TemporalAnalysisEngine {
    static let maximumSampleCount = 4_096
    static let sceneCutThresholdQ16: Int64 = 49_152
    static let motionValidityThresholdQ16: Int64 = 49_152
    static let occlusionThresholdQ16: Int64 = 16_384

    static func analyze(_ input: R07TemporalAnalysisInput) throws -> R07TemporalAnalysisResult {
        try validate(input)

        var sceneCutDifferenceSum: Int64 = 0
        var alignedDifferenceSum: Int64 = 0
        var validMotionSampleCount: Int64 = 0
        var occludedSampleCount: Int64 = 0

        for index in input.currentLumaQ16.indices {
            let sceneCutDifference = try R07CheckedInt64.absoluteDifference(
                input.currentLumaQ16[index],
                input.previousLumaQ16[index]
            )
            sceneCutDifferenceSum = try R07CheckedInt64.add(
                sceneCutDifferenceSum,
                sceneCutDifference
            )

            if input.occlusionMask[index] == 0 {
                let alignedDifference = try R07CheckedInt64.absoluteDifference(
                    input.currentLumaQ16[index],
                    input.alignedPreviousLumaQ16[index]
                )
                alignedDifferenceSum = try R07CheckedInt64.add(
                    alignedDifferenceSum,
                    alignedDifference
                )
                validMotionSampleCount = try R07CheckedInt64.add(validMotionSampleCount, 1)
            } else {
                occludedSampleCount = try R07CheckedInt64.add(occludedSampleCount, 1)
            }
        }

        guard validMotionSampleCount > 0 else {
            throw R07TemporalAnalysisError.noValidMotionSamplesRejected
        }

        let sampleCount = Int64(input.currentLumaQ16.count)
        let sceneCutRaw = try R07CheckedInt64.divideTowardZero(
            sceneCutDifferenceSum,
            by: sampleCount
        )
        let alignedDifferenceMean = try R07CheckedInt64.divideTowardZero(
            alignedDifferenceSum,
            by: validMotionSampleCount
        )
        let motionConfidence = try R07CheckedInt64.subtract(
            R06ASHQ16.scale,
            alignedDifferenceMean
        )
        let occlusionNumerator = try R07CheckedInt64.multiply(
            occludedSampleCount,
            R06ASHQ16.scale
        )
        let occlusion = try R07CheckedInt64.divideTowardZero(
            occlusionNumerator,
            by: sampleCount
        )

        return R07TemporalAnalysisResult(
            sampleCount: input.currentLumaQ16.count,
            sceneCutRawQ16: R06ASHQ16(validatedRawValue: sceneCutRaw),
            sceneCutDetected: sceneCutRaw >= sceneCutThresholdQ16,
            motionConfidenceQ16: R06ASHQ16(validatedRawValue: motionConfidence),
            motionValid: motionConfidence >= motionValidityThresholdQ16,
            validMotionSampleCount: Int(validMotionSampleCount),
            occlusionQ16: R06ASHQ16(validatedRawValue: occlusion),
            occlusionDetected: occlusion >= occlusionThresholdQ16
        )
    }

    private static func validate(_ input: R07TemporalAnalysisInput) throws {
        guard input.previousFrameOrdinal < input.currentFrameOrdinal else {
            throw R07TemporalAnalysisError.frameOrdinalsNotStrictlyIncreasing(
                previous: input.previousFrameOrdinal,
                current: input.currentFrameOrdinal
            )
        }

        let sampleCount = input.currentLumaQ16.count
        guard sampleCount > 0,
              !input.previousLumaQ16.isEmpty,
              !input.alignedPreviousLumaQ16.isEmpty,
              !input.occlusionMask.isEmpty else {
            throw R07TemporalAnalysisError.emptyVectorRejected
        }
        guard input.previousLumaQ16.count == sampleCount,
              input.alignedPreviousLumaQ16.count == sampleCount,
              input.occlusionMask.count == sampleCount else {
            throw R07TemporalAnalysisError.sampleCountMismatchRejected
        }
        guard sampleCount <= maximumSampleCount else {
            throw R07TemporalAnalysisError.vectorOrMaskOversizeRejected(
                actual: sampleCount,
                maximum: maximumSampleCount
            )
        }

        try validateLuma(input.currentLumaQ16, role: .current)
        try validateLuma(input.previousLumaQ16, role: .previous)
        try validateLuma(input.alignedPreviousLumaQ16, role: .alignedPrevious)
        for (index, value) in input.occlusionMask.enumerated() where value != 0 && value != 1 {
            throw R07TemporalAnalysisError.invalidOcclusionMaskValue(index: index, value: value)
        }
    }

    private static func validateLuma(
        _ samples: [Int64],
        role: R07TemporalVectorRole
    ) throws {
        for (index, value) in samples.enumerated()
        where !(0...R06ASHQ16.scale).contains(value) {
            throw R07TemporalAnalysisError.lumaSampleOutOfRange(
                role: role,
                index: index,
                value: value
            )
        }
    }
}
