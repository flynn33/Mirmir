import Foundation

enum DeterministicDeinterlacerV4Error: Error, Equatable, Sendable {
    case invalidGeometry(width: Int, height: Int, components: Int)
    case sampleCountMismatch(expected: Int, actual: Int)
    case invalidCodeBounds(minimum: UInt16, maximum: UInt16)
    case codeOutOfRange(
        index: Int,
        value: UInt16,
        minimum: UInt16,
        maximum: UInt16
    )
    case incompatibleNeighbor(String)
    case invalidAnalysisComponent(Int)
    case coordinateOutOfRange(x: Int, y: Int, component: Int)
    case invalidTiming(
        presentationValue: Int64,
        durationValue: Int64,
        timescale: Int32
    )
    case arithmeticOverflow
}

enum FieldParityV4: Int, Hashable, Sendable {
    case top = 0
    case bottom = 1
}

enum FieldDominanceV4: String, Hashable, Sendable {
    case topFieldFirst = "top_field_first"
    case bottomFieldFirst = "bottom_field_first"

    var outputOrder: [FieldParityV4] {
        switch self {
        case .topFieldFirst:
            [.top, .bottom]
        case .bottomFieldFirst:
            [.bottom, .top]
        }
    }
}

/// A plane of unpacked signal codes. P010 callers pass values after removing
/// the six storage padding bits; output values remain in the same code domain.
struct FieldPlaneV4: Equatable, Hashable, Sendable {
    let width: Int
    let height: Int
    let componentsPerSample: Int
    let minimumCode: UInt16
    let maximumCode: UInt16
    let samples: [UInt16]

    init(
        width: Int,
        height: Int,
        componentsPerSample: Int = 1,
        minimumCode: UInt16,
        maximumCode: UInt16,
        samples: [UInt16]
    ) throws {
        guard width > 0, height > 1, componentsPerSample > 0 else {
            throw DeterministicDeinterlacerV4Error.invalidGeometry(
                width: width,
                height: height,
                components: componentsPerSample
            )
        }
        guard minimumCode <= maximumCode else {
            throw DeterministicDeinterlacerV4Error.invalidCodeBounds(
                minimum: minimumCode,
                maximum: maximumCode
            )
        }
        let expectedCount = try Self.checkedSampleCount(
            width: width,
            height: height,
            components: componentsPerSample
        )
        guard samples.count == expectedCount else {
            throw DeterministicDeinterlacerV4Error.sampleCountMismatch(
                expected: expectedCount,
                actual: samples.count
            )
        }
        for (index, value) in samples.enumerated()
            where value < minimumCode || value > maximumCode {
            throw DeterministicDeinterlacerV4Error.codeOutOfRange(
                index: index,
                value: value,
                minimum: minimumCode,
                maximum: maximumCode
            )
        }
        self.width = width
        self.height = height
        self.componentsPerSample = componentsPerSample
        self.minimumCode = minimumCode
        self.maximumCode = maximumCode
        self.samples = samples
    }

    func signalCode(x: Int, y: Int, component: Int) throws -> UInt16 {
        guard x >= 0,
              y >= 0,
              component >= 0,
              x < width,
              y < height,
              component < componentsPerSample else {
            throw DeterministicDeinterlacerV4Error.coordinateOutOfRange(
                x: x,
                y: y,
                component: component
            )
        }
        return codeUnchecked(x: x, y: y, component: component)
    }

    fileprivate func index(x: Int, y: Int, component: Int) -> Int {
        ((y * width) + x) * componentsPerSample + component
    }

    fileprivate func codeUnchecked(x: Int, y: Int, component: Int) -> UInt16 {
        samples[index(x: x, y: y, component: component)]
    }

    private static func checkedSampleCount(
        width: Int,
        height: Int,
        components: Int
    ) throws -> Int {
        let (pixelCount, pixelOverflow) = width.multipliedReportingOverflow(
            by: height
        )
        let (sampleCount, sampleOverflow) = pixelCount
            .multipliedReportingOverflow(by: components)
        guard !pixelOverflow, !sampleOverflow else {
            throw DeterministicDeinterlacerV4Error.arithmeticOverflow
        }
        return sampleCount
    }
}

struct InterlacedFrameTimingV4: Equatable, Hashable, Sendable {
    let presentationValue: Int64
    let durationValue: Int64
    let timescale: Int32

    init(
        presentationValue: Int64,
        durationValue: Int64,
        timescale: Int32
    ) throws {
        guard durationValue > 0, timescale > 0 else {
            throw DeterministicDeinterlacerV4Error.invalidTiming(
                presentationValue: presentationValue,
                durationValue: durationValue,
                timescale: timescale
            )
        }
        self.presentationValue = presentationValue
        self.durationValue = durationValue
        self.timescale = timescale
    }
}

struct ProgressiveFieldTimingV4: Equatable, Hashable, Sendable {
    let presentationValue: Int64
    let durationValue: Int64
    let timescale: Int32
}

struct DeinterlaceThresholdsV4: Equatable, Hashable, Sendable {
    let motionCodeDifference: UInt16
    let sceneCutMeanAbsoluteDifference: UInt16
    let analysisComponent: Int

    init(
        motionCodeDifference: UInt16,
        sceneCutMeanAbsoluteDifference: UInt16,
        analysisComponent: Int = 0
    ) {
        self.motionCodeDifference = motionCodeDifference
        self.sceneCutMeanAbsoluteDifference =
            sceneCutMeanAbsoluteDifference
        self.analysisComponent = analysisComponent
    }
}

struct DeinterlaceDecisionSummaryV4: Equatable, Hashable, Sendable {
    let preservedSampleCount: Int
    let temporalSampleCount: Int
    let spatialSampleCount: Int
    let temporalSuppressedBySceneCut: Bool
}

struct DeinterlacedFieldFrameV4: Equatable, Hashable, Sendable {
    let sourceField: FieldParityV4
    let timing: ProgressiveFieldTimingV4
    let progressivePlane: FieldPlaneV4
    let decisions: DeinterlaceDecisionSummaryV4
}

/// Deterministic edge-directed bob with motion-adaptive temporal substitution.
/// Source field lines are copied exactly. Missing lines use a spatial candidate
/// unless both temporal neighbors agree and no scene cut is present.
enum DeterministicDeinterlacerV4 {
    static let algorithmIdentity =
        "field_bob.edge_directed.temporal_gate.tie_even.v1"

    static func deinterlace(
        previous: FieldPlaneV4?,
        current: FieldPlaneV4,
        next: FieldPlaneV4?,
        dominance: FieldDominanceV4,
        timing: InterlacedFrameTimingV4,
        thresholds: DeinterlaceThresholdsV4
    ) throws -> [DeinterlacedFieldFrameV4] {
        guard current.componentsPerSample > thresholds.analysisComponent,
              thresholds.analysisComponent >= 0 else {
            throw DeterministicDeinterlacerV4Error.invalidAnalysisComponent(
                thresholds.analysisComponent
            )
        }
        try validateNeighbor(previous, named: "previous", current: current)
        try validateNeighbor(next, named: "next", current: current)

        let hasTemporalPair = previous != nil && next != nil
        let sceneCut: Bool
        if let previous, let next {
            sceneCut = try isSceneCut(
                previous,
                current,
                threshold: thresholds.sceneCutMeanAbsoluteDifference,
                component: thresholds.analysisComponent
            ) || isSceneCut(
                current,
                next,
                threshold: thresholds.sceneCutMeanAbsoluteDifference,
                component: thresholds.analysisComponent
            )
        } else {
            sceneCut = false
        }

        let outputTimescale = try doubledTimescale(timing.timescale)
        let firstPresentation = try doubled(timing.presentationValue)
        var outputs: [DeinterlacedFieldFrameV4] = []
        outputs.reserveCapacity(2)
        for (ordinal, parity) in dominance.outputOrder.enumerated() {
            let presentation = ordinal == 0
                ? firstPresentation
                : try checkedSum(firstPresentation, timing.durationValue)
            let reconstruction = try reconstruct(
                parity: parity,
                previous: previous,
                current: current,
                next: next,
                temporalAllowed: hasTemporalPair && !sceneCut,
                sceneCut: sceneCut,
                motionThreshold: thresholds.motionCodeDifference
            )
            outputs.append(
                DeinterlacedFieldFrameV4(
                    sourceField: parity,
                    timing: ProgressiveFieldTimingV4(
                        presentationValue: presentation,
                        durationValue: timing.durationValue,
                        timescale: outputTimescale
                    ),
                    progressivePlane: reconstruction.plane,
                    decisions: reconstruction.decisions
                )
            )
        }
        return outputs
    }

    private static func reconstruct(
        parity: FieldParityV4,
        previous: FieldPlaneV4?,
        current: FieldPlaneV4,
        next: FieldPlaneV4?,
        temporalAllowed: Bool,
        sceneCut: Bool,
        motionThreshold: UInt16
    ) throws -> (
        plane: FieldPlaneV4,
        decisions: DeinterlaceDecisionSummaryV4
    ) {
        var samples = current.samples
        var preservedCount = 0
        var temporalCount = 0
        var spatialCount = 0
        for y in 0..<current.height {
            let isSourceLine = y.isMultiple(of: 2) == (parity == .top)
            for x in 0..<current.width {
                for component in 0..<current.componentsPerSample {
                    let index = current.index(x: x, y: y, component: component)
                    if isSourceLine {
                        preservedCount += 1
                        continue
                    }
                    let spatial = spatialCandidate(
                        current,
                        x: x,
                        y: y,
                        component: component
                    )
                    if temporalAllowed,
                       let previous,
                       let next {
                        let previousCode = previous.codeUnchecked(
                            x: x,
                            y: y,
                            component: component
                        )
                        let nextCode = next.codeUnchecked(
                            x: x,
                            y: y,
                            component: component
                        )
                        let temporal = roundedAverage(
                            previousCode,
                            nextCode
                        )
                        let temporalDifference = absoluteDifference(
                            previousCode,
                            nextCode
                        )
                        let currentDifference = absoluteDifference(
                            current.samples[index],
                            temporal
                        )
                        if temporalDifference <= motionThreshold,
                           currentDifference <= motionThreshold {
                            samples[index] = temporal
                            temporalCount += 1
                            continue
                        }
                    }
                    samples[index] = spatial
                    spatialCount += 1
                }
            }
        }
        return (
            plane: try FieldPlaneV4(
                width: current.width,
                height: current.height,
                componentsPerSample: current.componentsPerSample,
                minimumCode: current.minimumCode,
                maximumCode: current.maximumCode,
                samples: samples
            ),
            decisions: DeinterlaceDecisionSummaryV4(
                preservedSampleCount: preservedCount,
                temporalSampleCount: temporalCount,
                spatialSampleCount: spatialCount,
                temporalSuppressedBySceneCut: sceneCut
            )
        )
    }

    private static func spatialCandidate(
        _ plane: FieldPlaneV4,
        x: Int,
        y: Int,
        component: Int
    ) -> UInt16 {
        let upperY = y - 1
        let lowerY = y + 1
        if upperY < 0 {
            return plane.codeUnchecked(x: x, y: lowerY, component: component)
        }
        if lowerY >= plane.height {
            return plane.codeUnchecked(x: x, y: upperY, component: component)
        }

        var first = plane.codeUnchecked(x: x, y: upperY, component: component)
        var second = plane.codeUnchecked(x: x, y: lowerY, component: component)
        var bestGradient = absoluteDifference(first, second)

        if x > 0, x + 1 < plane.width {
            let diagonalFirst = plane.codeUnchecked(
                x: x - 1,
                y: upperY,
                component: component
            )
            let diagonalSecond = plane.codeUnchecked(
                x: x + 1,
                y: lowerY,
                component: component
            )
            let gradient = absoluteDifference(
                diagonalFirst,
                diagonalSecond
            )
            if gradient < bestGradient {
                first = diagonalFirst
                second = diagonalSecond
                bestGradient = gradient
            }

            let reverseFirst = plane.codeUnchecked(
                x: x + 1,
                y: upperY,
                component: component
            )
            let reverseSecond = plane.codeUnchecked(
                x: x - 1,
                y: lowerY,
                component: component
            )
            let reverseGradient = absoluteDifference(
                reverseFirst,
                reverseSecond
            )
            if reverseGradient < bestGradient {
                first = reverseFirst
                second = reverseSecond
            }
        }
        return roundedAverage(first, second)
    }

    private static func isSceneCut(
        _ first: FieldPlaneV4,
        _ second: FieldPlaneV4,
        threshold: UInt16,
        component: Int
    ) throws -> Bool {
        var differenceSum = UInt64(0)
        for y in 0..<first.height {
            for x in 0..<first.width {
                let difference = UInt64(
                    absoluteDifference(
                        first.codeUnchecked(x: x, y: y, component: component),
                        second.codeUnchecked(x: x, y: y, component: component)
                    )
                )
                let (newSum, overflow) = differenceSum.addingReportingOverflow(
                    difference
                )
                guard !overflow else {
                    throw DeterministicDeinterlacerV4Error.arithmeticOverflow
                }
                differenceSum = newSum
            }
        }
        let (sampleCount, countOverflow) = first.width
            .multipliedReportingOverflow(by: first.height)
        guard !countOverflow else {
            throw DeterministicDeinterlacerV4Error.arithmeticOverflow
        }
        let (thresholdSum, thresholdOverflow) = UInt64(sampleCount)
            .multipliedReportingOverflow(by: UInt64(threshold))
        guard !thresholdOverflow else {
            throw DeterministicDeinterlacerV4Error.arithmeticOverflow
        }
        return differenceSum > thresholdSum
    }

    private static func validateNeighbor(
        _ neighbor: FieldPlaneV4?,
        named name: String,
        current: FieldPlaneV4
    ) throws {
        guard let neighbor else { return }
        guard neighbor.width == current.width,
              neighbor.height == current.height,
              neighbor.componentsPerSample == current.componentsPerSample,
              neighbor.minimumCode == current.minimumCode,
              neighbor.maximumCode == current.maximumCode else {
            throw DeterministicDeinterlacerV4Error.incompatibleNeighbor(name)
        }
    }

    private static func roundedAverage(_ first: UInt16, _ second: UInt16) -> UInt16 {
        let sum = UInt32(first) + UInt32(second)
        let quotient = sum / 2
        if sum.isMultiple(of: 2) || quotient.isMultiple(of: 2) {
            return UInt16(quotient)
        }
        return UInt16(quotient + 1)
    }

    private static func absoluteDifference(
        _ first: UInt16,
        _ second: UInt16
    ) -> UInt16 {
        first >= second ? first - second : second - first
    }

    private static func doubledTimescale(_ value: Int32) throws -> Int32 {
        let (result, overflow) = value.multipliedReportingOverflow(by: 2)
        guard !overflow else {
            throw DeterministicDeinterlacerV4Error.arithmeticOverflow
        }
        return result
    }

    private static func doubled(_ value: Int64) throws -> Int64 {
        let (result, overflow) = value.multipliedReportingOverflow(by: 2)
        guard !overflow else {
            throw DeterministicDeinterlacerV4Error.arithmeticOverflow
        }
        return result
    }

    private static func checkedSum(_ first: Int64, _ second: Int64) throws -> Int64 {
        let (result, overflow) = first.addingReportingOverflow(second)
        guard !overflow else {
            throw DeterministicDeinterlacerV4Error.arithmeticOverflow
        }
        return result
    }
}
