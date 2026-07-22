import Foundation

enum R07FunctionalSupportGeometry {
    static let fullWidth = 64
    static let fullHeight = 64
    static let lowWidth = 32
    static let lowHeight = 32
    static let fullSampleCount = 4_096
    static let lowSampleCount = 1_024
}

enum R07FunctionalReferencedNativeIdentity: Hashable, Sendable {
    case a04Configuration(String)
    case inheritedProcessing(AppleUpscaleProcessingIdentity)
}

struct R07FunctionalSupportIdentity: Hashable, Sendable {
    let simulationIdentity: String
    let referencedNativeIdentity: R07FunctionalReferencedNativeIdentity
}

enum R07FunctionalA04TemporalState: Hashable, Sendable {
    case continuous(
        alignedHistoryLumaQ16: [Int64],
        occlusionMask: [Int64]
    )
    case currentOnlyInvalidMotion
    case discontinuity
}

enum R07FunctionalSupportRequest: Hashable, Sendable {
    case a04(
        identity: R07FunctionalSupportIdentity,
        currentLumaQ16: [Int64],
        strengthQ16: R06ASHQ16,
        temporalState: R07FunctionalA04TemporalState
    )
    case a13(
        identity: R07FunctionalSupportIdentity,
        sourceChromaCbQ16: [Int64],
        sourceChromaCrQ16: [Int64],
        sameFrameLumaQ16: [Int64],
        protectionMaskQ15: [Int64]
    )
    case a15(
        identity: R07FunctionalSupportIdentity,
        lowResolutionMaskQ15: [Int64],
        sameFrameLumaQ16: [Int64]
    )

    var capabilityID: R07SupportCapabilityID {
        switch self {
        case .a04: .temporalNoiseFilter
        case .a13: .mpsGuidedFilter
        case .a15: .coreImageEdgePreserve
        }
    }

    var identity: R07FunctionalSupportIdentity {
        switch self {
        case .a04(let identity, _, _, _),
             .a13(let identity, _, _, _, _),
             .a15(let identity, _, _):
            identity
        }
    }
}

enum R07FunctionalSupportPayload: Hashable, Sendable {
    case denoisedLumaQ16([Int64])
    case reconstructedChromaQ16(cb: [Int64], cr: [Int64])
    case upsampledProtectionMaskQ15([Int64])
}

struct R07FunctionalSupportExecution: Hashable, Sendable {
    let capabilityID: R07SupportCapabilityID
    let identity: R07FunctionalSupportIdentity
    let payload: R07FunctionalSupportPayload
}

protocol R07FunctionalSupportExecuting: Sendable {
    func execute(
        _ request: R07FunctionalSupportRequest
    ) throws -> R07FunctionalSupportExecution
}

enum R07FunctionalSupportExecutionError: Error, Equatable, Sendable {
    case simulationIdentityMismatch(R07SupportCapabilityID)
    case sampleCountMismatch(role: String, expected: Int, actual: Int)
    case sampleOutOfRange(role: String, index: Int, value: Int64)
}

enum R07FunctionalSimulationIdentity {
    static let a04 =
        "r07.fixture-sim.a04.temporal-blend.luma-q16.strength-q16-24576.v1"
    static let a13 =
        "r07.fixture-sim.a13.luma-q16-gated-r8.chroma-cbcr-q16.window5.threshold-r8-2.v1"
    static let a15 =
        "r07.fixture-sim.a15.mask-q15-2x.luma-q16-gated-r8.radius3.threshold-r8-38.v1"

    static func identity(for capability: R07SupportCapabilityID) -> String? {
        switch capability {
        case .temporalNoiseFilter: a04
        case .mpsGuidedFilter: a13
        case .coreImageEdgePreserve: a15
        case .temporalAnalyzer: nil
        }
    }
}

struct R07DeterministicFixtureSupportExecutor: R07FunctionalSupportExecuting {
    private static let a13Radius = 2
    private static let a13LumaThresholdR8: Int64 = 2
    private static let a15Radius = 3
    private static let a15LumaThresholdR8: Int64 = 38

    func execute(
        _ request: R07FunctionalSupportRequest
    ) throws -> R07FunctionalSupportExecution {
        guard request.identity.simulationIdentity
            == R07FunctionalSimulationIdentity.identity(for: request.capabilityID),
              request.identity.referencedNativeIdentity
                == referencedNativeIdentity(for: request.capabilityID) else {
            throw R07FunctionalSupportExecutionError.simulationIdentityMismatch(
                request.capabilityID
            )
        }

        let payload: R07FunctionalSupportPayload
        switch request {
        case .a04(_, let current, let strength, let temporalState):
            payload = .denoisedLumaQ16(
                try temporalBlend(
                    current: current,
                    strength: strength,
                    temporalState: temporalState
                )
            )
        case .a13(_, let cb, let cr, let luma, let protection):
            payload = .reconstructedChromaQ16(
                cb: try guidedChroma(
                    source: cb,
                    luma: luma,
                    protection: protection
                ),
                cr: try guidedChroma(
                    source: cr,
                    luma: luma,
                    protection: protection
                )
            )
        case .a15(_, let lowMask, let luma):
            payload = .upsampledProtectionMaskQ15(
                try edgeAwareMask(lowMask: lowMask, luma: luma)
            )
        }

        return R07FunctionalSupportExecution(
            capabilityID: request.capabilityID,
            identity: request.identity,
            payload: payload
        )
    }
}

private extension R07DeterministicFixtureSupportExecutor {
    func temporalBlend(
        current: [Int64],
        strength: R06ASHQ16,
        temporalState: R07FunctionalA04TemporalState
    ) throws -> [Int64] {
        try validateQ16(current, role: "a04.current_luma_q16")
        guard strength == R07SupportStagePolicy.a04StrengthQ16 else {
            throw R07FunctionalSupportExecutionError.sampleOutOfRange(
                role: "a04.strength_q16",
                index: 0,
                value: strength.rawValue
            )
        }
        guard case .continuous(let history, let occlusion) = temporalState else {
            return current
        }
        try validateQ16(history, role: "a04.aligned_history_luma_q16")
        try requireCount(
            occlusion,
            expected: R07FunctionalSupportGeometry.fullSampleCount,
            role: "a04.occlusion_mask"
        )
        try validateBinaryMask(occlusion, role: "a04.occlusion_mask")

        let historyWeight = strength.rawValue
        let currentWeight = try R07CheckedInt64.subtract(
            R06ASHQ16.scale,
            historyWeight
        )
        return try current.indices.map { index in
            guard occlusion[index] == 0 else { return current[index] }
            let currentTerm = try R07CheckedInt64.multiply(
                current[index],
                currentWeight
            )
            let historyTerm = try R07CheckedInt64.multiply(
                history[index],
                historyWeight
            )
            let numerator = try R07CheckedInt64.add(currentTerm, historyTerm)
            return try R07CheckedInt64.divideTowardZero(
                numerator,
                by: R06ASHQ16.scale
            )
        }
    }

    func guidedChroma(
        source: [Int64],
        luma: [Int64],
        protection: [Int64]
    ) throws -> [Int64] {
        try validateQ16(source, role: "a13.source_chroma_q16")
        try validateQ16(luma, role: "a13.same_frame_luma_q16")
        try validateQ15(protection, role: "a13.protection_mask_q15")
        let lumaR8 = try luma.map(q16ToR8)
        var output = [Int64](
            repeating: 0,
            count: R07FunctionalSupportGeometry.fullSampleCount
        )

        for row in 0..<R07FunctionalSupportGeometry.fullHeight {
            for column in 0..<R07FunctionalSupportGeometry.fullWidth {
                let index = fullIndex(column: column, row: row)
                var sum: Int64 = 0
                var count: Int64 = 0
                for neighborY in boundedRange(
                    center: row,
                    radius: Self.a13Radius,
                    upperBound: R07FunctionalSupportGeometry.fullHeight
                ) {
                    for neighborX in boundedRange(
                        center: column,
                        radius: Self.a13Radius,
                        upperBound: R07FunctionalSupportGeometry.fullWidth
                    ) {
                        let neighbor = fullIndex(column: neighborX, row: neighborY)
                        let delta = try R07CheckedInt64.absoluteDifference(
                            lumaR8[index],
                            lumaR8[neighbor]
                        )
                        if delta <= Self.a13LumaThresholdR8 {
                            sum = try R07CheckedInt64.add(sum, source[neighbor])
                            count = try R07CheckedInt64.add(count, 1)
                        }
                    }
                }
                let guided = try R07CheckedInt64.divideTowardZero(sum, by: count)
                output[index] = try protectionBlend(
                    filtered: guided,
                    source: source[index],
                    maskQ15: protection[index]
                )
            }
        }
        return output
    }

    func edgeAwareMask(
        lowMask: [Int64],
        luma: [Int64]
    ) throws -> [Int64] {
        try validateQ15(
            lowMask,
            role: "a15.low_resolution_mask_q15",
            expected: R07FunctionalSupportGeometry.lowSampleCount
        )
        try validateQ16(luma, role: "a15.same_frame_luma_q16")
        let expanded = nearestNeighbor2x(lowMask)
        let lumaR8 = try luma.map(q16ToR8)
        var output = expanded

        for row in 0..<R07FunctionalSupportGeometry.fullHeight {
            for column in 0..<R07FunctionalSupportGeometry.fullWidth {
                let index = fullIndex(column: column, row: row)
                var weightedSum: Int64 = 0
                var weightSum: Int64 = 0
                for neighborY in boundedRange(
                    center: row,
                    radius: Self.a15Radius,
                    upperBound: R07FunctionalSupportGeometry.fullHeight
                ) {
                    for neighborX in boundedRange(
                        center: column,
                        radius: Self.a15Radius,
                        upperBound: R07FunctionalSupportGeometry.fullWidth
                    ) {
                        let neighbor = fullIndex(column: neighborX, row: neighborY)
                        let delta = try R07CheckedInt64.absoluteDifference(
                            lumaR8[index],
                            lumaR8[neighbor]
                        )
                        if delta <= Self.a15LumaThresholdR8 {
                            let distance = max(
                                Swift.abs(neighborX - column),
                                Swift.abs(neighborY - row)
                            )
                            let weight = Int64(Self.a15Radius + 1 - distance)
                            let term = try R07CheckedInt64.multiply(
                                expanded[neighbor],
                                weight
                            )
                            weightedSum = try R07CheckedInt64.add(weightedSum, term)
                            weightSum = try R07CheckedInt64.add(weightSum, weight)
                        }
                    }
                }
                output[index] = try R07CheckedInt64.divideTowardZero(
                    weightedSum,
                    by: weightSum
                )
            }
        }
        return output
    }

    func protectionBlend(
        filtered: Int64,
        source: Int64,
        maskQ15: Int64
    ) throws -> Int64 {
        let filteredWeight = try R07CheckedInt64.subtract(
            R06ASHQ15.maximum,
            maskQ15
        )
        let filteredTerm = try R07CheckedInt64.multiply(filtered, filteredWeight)
        let sourceTerm = try R07CheckedInt64.multiply(source, maskQ15)
        return try R07CheckedInt64.divideTowardZero(
            R07CheckedInt64.add(filteredTerm, sourceTerm),
            by: R06ASHQ15.maximum
        )
    }

    func nearestNeighbor2x(_ lowMask: [Int64]) -> [Int64] {
        var output = [Int64](
            repeating: 0,
            count: R07FunctionalSupportGeometry.fullSampleCount
        )
        for row in 0..<R07FunctionalSupportGeometry.fullHeight {
            for column in 0..<R07FunctionalSupportGeometry.fullWidth {
                let lowIndex =
                    (row / 2) * R07FunctionalSupportGeometry.lowWidth + (column / 2)
                output[fullIndex(column: column, row: row)] = lowMask[lowIndex]
            }
        }
        return output
    }

    func q16ToR8(_ value: Int64) throws -> Int64 {
        let scaled = try R07CheckedInt64.multiply(value, 255)
        return try R07CheckedInt64.divideTowardZero(scaled, by: R06ASHQ16.scale)
    }

    func referencedNativeIdentity(
        for capability: R07SupportCapabilityID
    ) -> R07FunctionalReferencedNativeIdentity? {
        switch capability {
        case .temporalNoiseFilter:
            .a04Configuration(R07SupportStagePolicy.a04ConfigurationIdentity)
        case .mpsGuidedFilter:
            .inheritedProcessing(
                R07SupportStagePolicy.a13Descriptor.processingIdentity
            )
        case .coreImageEdgePreserve:
            .inheritedProcessing(
                R07SupportStagePolicy.a15Descriptor.processingIdentity
            )
        case .temporalAnalyzer:
            nil
        }
    }

    func validateQ16(_ values: [Int64], role: String) throws {
        try validate(
            values,
            role: role,
            expected: R07FunctionalSupportGeometry.fullSampleCount,
            maximum: R06ASHQ16.scale
        )
    }

    func validateQ15(
        _ values: [Int64],
        role: String,
        expected: Int = R07FunctionalSupportGeometry.fullSampleCount
    ) throws {
        try validate(
            values,
            role: role,
            expected: expected,
            maximum: R06ASHQ15.maximum
        )
    }

    func validate(
        _ values: [Int64],
        role: String,
        expected: Int,
        maximum: Int64
    ) throws {
        try requireCount(values, expected: expected, role: role)
        if let invalid = values.enumerated().first(where: {
            !(0...maximum).contains($0.element)
        }) {
            throw R07FunctionalSupportExecutionError.sampleOutOfRange(
                role: role,
                index: invalid.offset,
                value: invalid.element
            )
        }
    }

    func validateBinaryMask(_ values: [Int64], role: String) throws {
        if let invalid = values.enumerated().first(where: {
            $0.element != 0 && $0.element != 1
        }) {
            throw R07FunctionalSupportExecutionError.sampleOutOfRange(
                role: role,
                index: invalid.offset,
                value: invalid.element
            )
        }
    }

    func requireCount<Element>(
        _ values: [Element],
        expected: Int,
        role: String
    ) throws {
        guard values.count == expected else {
            throw R07FunctionalSupportExecutionError.sampleCountMismatch(
                role: role,
                expected: expected,
                actual: values.count
            )
        }
    }

    func boundedRange(
        center: Int,
        radius: Int,
        upperBound: Int
    ) -> ClosedRange<Int> {
        max(0, center - radius)...min(upperBound - 1, center + radius)
    }

    func fullIndex(column: Int, row: Int) -> Int {
        row * R07FunctionalSupportGeometry.fullWidth + column
    }
}
