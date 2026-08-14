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

enum FieldParityV4: Int, Codable, Hashable, Sendable {
    case top = 0
    case bottom = 1
}

enum FieldDominanceV4: String, Codable, Hashable, Sendable {
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

enum DeterministicFieldCadenceClassV4: String, Codable, Equatable, Hashable,
    Sendable {
    case interlaced
    case telecine32 = "telecine_3_2"
    case mixed
}

enum DeterministicFieldRepeatEvidenceV4: String, Codable, Equatable, Hashable,
    Sendable {
    case neither
    case topOnly = "top_only"
    case bottomOnly = "bottom_only"
    case both
}

enum DeterministicFieldCadenceV4Error: Error, Equatable, Sendable {
    case incompatibleFieldHistory
    case invalidState
    case arithmeticOverflow
}

/// Causal evidence for the transition ending at `inputFrameOrdinal`. The two
/// deltas compare like-parity source fields only; no future frame is observed.
struct DeterministicFieldCadenceObservationV4: Codable, Equatable, Hashable,
    Sendable {
    let inputFrameOrdinal: UInt64
    let topMeanAbsoluteDifferenceQ16: UInt32
    let bottomMeanAbsoluteDifferenceQ16: UInt32
    let topChangedSampleFractionQ16: UInt32
    let bottomChangedSampleFractionQ16: UInt32
    let topMaximumBlockMeanAbsoluteDifferenceQ16: UInt32
    let bottomMaximumBlockMeanAbsoluteDifferenceQ16: UInt32
    let topMaximumBlockChangedSampleFractionQ16: UInt32
    let bottomMaximumBlockChangedSampleFractionQ16: UInt32
    let normalizedRepeatThresholdQ16: UInt32
    let repeatEvidence: DeterministicFieldRepeatEvidenceV4

    func validate() throws {
        guard inputFrameOrdinal > 0,
              topMeanAbsoluteDifferenceQ16 <= 65_536,
              bottomMeanAbsoluteDifferenceQ16 <= 65_536,
              topChangedSampleFractionQ16 <= 65_536,
              bottomChangedSampleFractionQ16 <= 65_536,
              topMaximumBlockMeanAbsoluteDifferenceQ16 <= 65_536,
              bottomMaximumBlockMeanAbsoluteDifferenceQ16 <= 65_536,
              topMaximumBlockChangedSampleFractionQ16 <= 65_536,
              bottomMaximumBlockChangedSampleFractionQ16 <= 65_536,
              normalizedRepeatThresholdQ16 <= 65_536 else {
            throw DeterministicFieldCadenceV4Error.invalidState
        }
        let topRepeated = DeterministicFieldCadenceClassifierV4
            .isRepeatedParity(
                meanAbsoluteDifferenceQ16:
                    topMeanAbsoluteDifferenceQ16,
                changedSampleFractionQ16: topChangedSampleFractionQ16,
                maximumBlockMeanAbsoluteDifferenceQ16:
                    topMaximumBlockMeanAbsoluteDifferenceQ16,
                maximumBlockChangedSampleFractionQ16:
                    topMaximumBlockChangedSampleFractionQ16,
                normalizedRepeatThresholdQ16:
                    normalizedRepeatThresholdQ16
            )
        let bottomRepeated = DeterministicFieldCadenceClassifierV4
            .isRepeatedParity(
                meanAbsoluteDifferenceQ16:
                    bottomMeanAbsoluteDifferenceQ16,
                changedSampleFractionQ16: bottomChangedSampleFractionQ16,
                maximumBlockMeanAbsoluteDifferenceQ16:
                    bottomMaximumBlockMeanAbsoluteDifferenceQ16,
                maximumBlockChangedSampleFractionQ16:
                    bottomMaximumBlockChangedSampleFractionQ16,
                normalizedRepeatThresholdQ16:
                    normalizedRepeatThresholdQ16
            )
        let expectedRepeatEvidence: DeterministicFieldRepeatEvidenceV4
        switch (topRepeated, bottomRepeated) {
        case (false, false): expectedRepeatEvidence = .neither
        case (true, false): expectedRepeatEvidence = .topOnly
        case (false, true): expectedRepeatEvidence = .bottomOnly
        case (true, true): expectedRepeatEvidence = .both
        }
        guard repeatEvidence == expectedRepeatEvidence else {
            throw DeterministicFieldCadenceV4Error.invalidState
        }
    }
}

/// The entire bounded field-cadence state. Keeping the five most recent
/// transitions from each of two complete cycles recognizes every cyclic phase
/// of 3:2 pulldown without promoting a one-cycle coincidence. The complete
/// trailing window also makes checkpoint/resume classification byte-stable.
struct DeterministicFieldCadenceStateV4: Codable, Equatable, Hashable,
    Sendable {
    static let evidenceCapacity = 10

    let dominance: FieldDominanceV4
    let streamInputFrameCount: UInt64
    let inputFrameCount: UInt64
    let classification: DeterministicFieldCadenceClassV4
    let observations: [DeterministicFieldCadenceObservationV4]

    init(
        dominance: FieldDominanceV4,
        streamInputFrameCount: UInt64,
        inputFrameCount: UInt64,
        classification: DeterministicFieldCadenceClassV4,
        observations: [DeterministicFieldCadenceObservationV4]
    ) throws {
        self.dominance = dominance
        self.streamInputFrameCount = streamInputFrameCount
        self.inputFrameCount = inputFrameCount
        self.classification = classification
        self.observations = observations
        try validate()
    }

    func validate() throws {
        guard streamInputFrameCount > 0,
              inputFrameCount > 0,
              inputFrameCount <= streamInputFrameCount,
              observations.count <= Self.evidenceCapacity else {
            throw DeterministicFieldCadenceV4Error.invalidState
        }
        let availableObservationCount = inputFrameCount - 1
        let expectedObservationCount = availableObservationCount
            >= UInt64(Self.evidenceCapacity)
            ? Self.evidenceCapacity : Int(availableObservationCount)
        guard observations.count == expectedObservationCount else {
            throw DeterministicFieldCadenceV4Error.invalidState
        }
        let firstExpectedOrdinal = inputFrameCount
            - UInt64(expectedObservationCount)
        for (index, observation) in observations.enumerated() {
            try observation.validate()
            guard observation.inputFrameOrdinal
                    == firstExpectedOrdinal + UInt64(index) else {
                throw DeterministicFieldCadenceV4Error.invalidState
            }
        }
        guard classification == DeterministicFieldCadenceClassifierV4
            .classify(observations: observations, dominance: dominance) else {
            throw DeterministicFieldCadenceV4Error.invalidState
        }
    }

    var cadenceID: String {
        let dominanceID = dominance == .topFieldFirst ? "tff" : "bff"
        switch classification {
        case .interlaced:
            return "interlaced_\(dominanceID)_double_rate"
        case .telecine32:
            return "telecine_3_2_\(dominanceID)_double_rate"
        case .mixed:
            return "mixed_\(dominanceID)_double_rate"
        }
    }
}

struct DeterministicFieldCadenceDecisionV4: Equatable, Hashable, Sendable {
    let state: DeterministicFieldCadenceStateV4
    let observation: DeterministicFieldCadenceObservationV4?
    let didTransition: Bool
}

/// Deterministic 3:2 classification from ordered, same-parity field evidence.
/// The detector intentionally has no `next` input: its result for a frame can
/// never change after that frame has been emitted.
enum DeterministicFieldCadenceClassifierV4 {
    static let algorithmIdentity =
        "field-cadence.block-consistent.causal-3-2-two-cycle.v3"

    /// A repeated field may contain a bounded amount of compression noise,
    /// but not a small moving object whose energy is hidden by a frame-wide
    /// average. Both global and per-block changed-sample limits are Q16.
    static let maximumChangedSampleFractionQ16: UInt32 = 1_024
    static let maximumBlockChangedSampleFractionQ16: UInt32 = 4_096
    static let comparisonBlockWidth = 16
    static let comparisonBlockFieldHeight = 8

    static func observe(
        previous: FieldPlaneV4?,
        current: FieldPlaneV4,
        dominance: FieldDominanceV4,
        repeatCodeDifference: UInt16,
        state: DeterministicFieldCadenceStateV4?
    ) throws -> DeterministicFieldCadenceDecisionV4 {
        if let state {
            try state.validate()
        }

        guard let state else {
            let initial = try DeterministicFieldCadenceStateV4(
                dominance: dominance,
                streamInputFrameCount: 1,
                inputFrameCount: 1,
                classification: .interlaced,
                observations: []
            )
            return DeterministicFieldCadenceDecisionV4(
                state: initial,
                observation: nil,
                didTransition: false
            )
        }
        if state.dominance != dominance {
            let nextStreamCount = state.streamInputFrameCount
                .addingReportingOverflow(1)
            guard !nextStreamCount.overflow else {
                throw DeterministicFieldCadenceV4Error.arithmeticOverflow
            }
            let initial = try DeterministicFieldCadenceStateV4(
                dominance: dominance,
                streamInputFrameCount: nextStreamCount.partialValue,
                inputFrameCount: 1,
                classification: .interlaced,
                observations: []
            )
            return DeterministicFieldCadenceDecisionV4(
                state: initial,
                observation: nil,
                didTransition: true
            )
        }
        guard let previous else {
            throw DeterministicFieldCadenceV4Error.incompatibleFieldHistory
        }
        let nextCount = state.inputFrameCount.addingReportingOverflow(1)
        let nextStreamCount = state.streamInputFrameCount
            .addingReportingOverflow(1)
        guard !nextCount.overflow, !nextStreamCount.overflow else {
            throw DeterministicFieldCadenceV4Error.arithmeticOverflow
        }
        let observation = try measure(
            previous: previous,
            current: current,
            inputFrameOrdinal: state.inputFrameCount,
            repeatCodeDifference: repeatCodeDifference
        )
        var observations = state.observations
        observations.append(observation)
        if observations.count > DeterministicFieldCadenceStateV4
            .evidenceCapacity {
            observations.removeFirst(
                observations.count
                    - DeterministicFieldCadenceStateV4.evidenceCapacity
            )
        }
        let nextClassification = classify(
            observations: observations,
            dominance: dominance
        )
        let nextState = try DeterministicFieldCadenceStateV4(
            dominance: dominance,
            streamInputFrameCount: nextStreamCount.partialValue,
            inputFrameCount: nextCount.partialValue,
            classification: nextClassification,
            observations: observations
        )
        return DeterministicFieldCadenceDecisionV4(
            state: nextState,
            observation: observation,
            didTransition: nextClassification != state.classification
        )
    }

    fileprivate static func classify(
        observations: [DeterministicFieldCadenceObservationV4],
        dominance: FieldDominanceV4
    ) -> DeterministicFieldCadenceClassV4 {
        guard observations.count
                == DeterministicFieldCadenceStateV4.evidenceCapacity else {
            return .interlaced
        }
        let firstRepeat: DeterministicFieldRepeatEvidenceV4
        let secondRepeat: DeterministicFieldRepeatEvidenceV4
        switch dominance {
        case .topFieldFirst:
            firstRepeat = .topOnly
            secondRepeat = .bottomOnly
        case .bottomFieldFirst:
            firstRepeat = .bottomOnly
            secondRepeat = .topOnly
        }
        let canonical: [DeterministicFieldRepeatEvidenceV4] = [
            .neither, firstRepeat, .neither, secondRepeat, .neither
        ]
        let observed = observations.map(\.repeatEvidence)
        for phase in canonical.indices {
            if observed.indices.allSatisfy({ index in
                observed[index]
                    == canonical[(index + phase) % canonical.count]
            }) {
                return .telecine32
            }
        }
        let singleParityRepeats = observed.filter {
            $0 == .topOnly || $0 == .bottomOnly
        }
        if singleParityRepeats.count >= 3,
           singleParityRepeats.contains(.topOnly),
           singleParityRepeats.contains(.bottomOnly) {
            return .mixed
        }
        return .interlaced
    }

    private static func measure(
        previous: FieldPlaneV4,
        current: FieldPlaneV4,
        inputFrameOrdinal: UInt64,
        repeatCodeDifference: UInt16
    ) throws -> DeterministicFieldCadenceObservationV4 {
        guard previous.width == current.width,
              previous.height == current.height,
              previous.componentsPerSample == current.componentsPerSample,
              previous.minimumCode == current.minimumCode,
              previous.maximumCode == current.maximumCode else {
            throw DeterministicFieldCadenceV4Error.incompatibleFieldHistory
        }
        let top = try fieldDifference(
            previous: previous,
            current: current,
            parity: .top,
            repeatCodeDifference: repeatCodeDifference
        )
        let bottom = try fieldDifference(
            previous: previous,
            current: current,
            parity: .bottom,
            repeatCodeDifference: repeatCodeDifference
        )
        let normalizedRepeatThresholdQ16 = try Self
            .normalizedRepeatThresholdQ16(
            minimumCode: current.minimumCode,
            maximumCode: current.maximumCode,
            repeatCodeDifference: repeatCodeDifference
        )
        let topRepeated = isRepeatedParity(
            meanAbsoluteDifferenceQ16: top.meanQ16,
            changedSampleFractionQ16: top.changedFractionQ16,
            maximumBlockMeanAbsoluteDifferenceQ16:
                top.maximumBlockMeanQ16,
            maximumBlockChangedSampleFractionQ16:
                top.maximumBlockChangedFractionQ16,
            normalizedRepeatThresholdQ16: normalizedRepeatThresholdQ16
        )
        let bottomRepeated = isRepeatedParity(
            meanAbsoluteDifferenceQ16: bottom.meanQ16,
            changedSampleFractionQ16: bottom.changedFractionQ16,
            maximumBlockMeanAbsoluteDifferenceQ16:
                bottom.maximumBlockMeanQ16,
            maximumBlockChangedSampleFractionQ16:
                bottom.maximumBlockChangedFractionQ16,
            normalizedRepeatThresholdQ16: normalizedRepeatThresholdQ16
        )
        let repeatEvidence: DeterministicFieldRepeatEvidenceV4
        switch (topRepeated, bottomRepeated) {
        case (false, false): repeatEvidence = .neither
        case (true, false): repeatEvidence = .topOnly
        case (false, true): repeatEvidence = .bottomOnly
        case (true, true): repeatEvidence = .both
        }
        return DeterministicFieldCadenceObservationV4(
            inputFrameOrdinal: inputFrameOrdinal,
            topMeanAbsoluteDifferenceQ16: top.meanQ16,
            bottomMeanAbsoluteDifferenceQ16: bottom.meanQ16,
            topChangedSampleFractionQ16: top.changedFractionQ16,
            bottomChangedSampleFractionQ16: bottom.changedFractionQ16,
            topMaximumBlockMeanAbsoluteDifferenceQ16:
                top.maximumBlockMeanQ16,
            bottomMaximumBlockMeanAbsoluteDifferenceQ16:
                bottom.maximumBlockMeanQ16,
            topMaximumBlockChangedSampleFractionQ16:
                top.maximumBlockChangedFractionQ16,
            bottomMaximumBlockChangedSampleFractionQ16:
                bottom.maximumBlockChangedFractionQ16,
            normalizedRepeatThresholdQ16: normalizedRepeatThresholdQ16,
            repeatEvidence: repeatEvidence
        )
    }

    private static func fieldDifference(
        previous: FieldPlaneV4,
        current: FieldPlaneV4,
        parity: FieldParityV4,
        repeatCodeDifference: UInt16
    ) throws -> (
        meanQ16: UInt32,
        changedFractionQ16: UInt32,
        maximumBlockMeanQ16: UInt32,
        maximumBlockChangedFractionQ16: UInt32
    ) {
        var differenceSum = UInt64(0)
        var sampleCount = UInt64(0)
        var changedSampleCount = UInt64(0)
        var maximumBlockMeanQ16 = UInt32(0)
        var maximumBlockChangedFractionQ16 = UInt32(0)
        let fieldRowCount = current.height / 2
            + (parity == .top && !current.height.isMultiple(of: 2) ? 1 : 0)
        for fieldOriginY in stride(
            from: 0,
            to: fieldRowCount,
            by: comparisonBlockFieldHeight
        ) {
            let blockFieldHeight = min(
                comparisonBlockFieldHeight,
                fieldRowCount - fieldOriginY
            )
            for originX in stride(
                from: 0,
                to: current.width,
                by: comparisonBlockWidth
            ) {
                let blockWidth = min(
                    comparisonBlockWidth,
                    current.width - originX
                )
                var blockDifferenceSum = UInt64(0)
                var blockSampleCount = UInt64(0)
                var blockChangedSampleCount = UInt64(0)
                for fieldY in fieldOriginY..<(
                    fieldOriginY + blockFieldHeight
                ) {
                    let y = parity.rawValue + fieldY * 2
                    for x in originX..<(originX + blockWidth) {
                        let first = previous.codeUnchecked(
                            x: x,
                            y: y,
                            component: 0
                        )
                        let second = current.codeUnchecked(
                            x: x,
                            y: y,
                            component: 0
                        )
                        let difference = first > second
                            ? UInt64(first - second)
                            : UInt64(second - first)
                        blockDifferenceSum = try checkedCadenceSum(
                            blockDifferenceSum,
                            difference
                        )
                        blockSampleCount = try checkedCadenceSum(
                            blockSampleCount,
                            1
                        )
                        if difference > UInt64(repeatCodeDifference) {
                            blockChangedSampleCount = try checkedCadenceSum(
                                blockChangedSampleCount,
                                1
                            )
                        }
                    }
                }
                differenceSum = try checkedCadenceSum(
                    differenceSum,
                    blockDifferenceSum
                )
                sampleCount = try checkedCadenceSum(
                    sampleCount,
                    blockSampleCount
                )
                changedSampleCount = try checkedCadenceSum(
                    changedSampleCount,
                    blockChangedSampleCount
                )
                let signalRange = UInt64(
                    current.maximumCode - current.minimumCode
                )
                let blockDenominator = blockSampleCount
                    .multipliedReportingOverflow(by: signalRange)
                guard !blockDenominator.overflow else {
                    throw DeterministicFieldCadenceV4Error.arithmeticOverflow
                }
                let blockMeanQ16 = try normalizedQ16(
                    blockDifferenceSum,
                    denominator: blockDenominator.partialValue
                )
                let blockChangedFractionQ16 = try normalizedQ16(
                    blockChangedSampleCount,
                    denominator: blockSampleCount
                )
                maximumBlockMeanQ16 = max(
                    maximumBlockMeanQ16,
                    blockMeanQ16
                )
                maximumBlockChangedFractionQ16 = max(
                    maximumBlockChangedFractionQ16,
                    blockChangedFractionQ16
                )
            }
        }
        guard sampleCount > 0 else {
            throw DeterministicFieldCadenceV4Error.invalidState
        }
        let signalRange = UInt64(current.maximumCode - current.minimumCode)
        let denominator = sampleCount.multipliedReportingOverflow(
            by: signalRange
        )
        guard !denominator.overflow else {
            throw DeterministicFieldCadenceV4Error.arithmeticOverflow
        }
        let meanQ16 = try normalizedQ16(
            differenceSum,
            denominator: denominator.partialValue
        )
        let changedFractionQ16 = try normalizedQ16(
            changedSampleCount,
            denominator: sampleCount
        )
        return (
            meanQ16: meanQ16,
            changedFractionQ16: changedFractionQ16,
            maximumBlockMeanQ16: maximumBlockMeanQ16,
            maximumBlockChangedFractionQ16:
                maximumBlockChangedFractionQ16
        )
    }

    fileprivate static func isRepeatedParity(
        meanAbsoluteDifferenceQ16: UInt32,
        changedSampleFractionQ16: UInt32,
        maximumBlockMeanAbsoluteDifferenceQ16: UInt32,
        maximumBlockChangedSampleFractionQ16: UInt32,
        normalizedRepeatThresholdQ16: UInt32
    ) -> Bool {
        meanAbsoluteDifferenceQ16 <= normalizedRepeatThresholdQ16
            && changedSampleFractionQ16
                <= maximumChangedSampleFractionQ16
            && maximumBlockMeanAbsoluteDifferenceQ16
                <= normalizedRepeatThresholdQ16
            && maximumBlockChangedSampleFractionQ16
                <= maximumBlockChangedSampleFractionQ16
    }

    static func normalizedRepeatThresholdQ16(
        minimumCode: UInt16,
        maximumCode: UInt16,
        repeatCodeDifference: UInt16
    ) throws -> UInt32 {
        guard minimumCode <= maximumCode else {
            throw DeterministicFieldCadenceV4Error.invalidState
        }
        let signalRange = UInt64(maximumCode - minimumCode)
        return try normalizedQ16(
            min(UInt64(repeatCodeDifference), signalRange),
            denominator: signalRange
        )
    }

    private static func checkedCadenceSum(
        _ lhs: UInt64,
        _ rhs: UInt64
    ) throws -> UInt64 {
        let result = lhs.addingReportingOverflow(rhs)
        guard !result.overflow else {
            throw DeterministicFieldCadenceV4Error.arithmeticOverflow
        }
        return result.partialValue
    }

    private static func normalizedQ16(
        _ numerator: UInt64,
        denominator: UInt64
    ) throws -> UInt32 {
        if denominator == 0 { return 0 }
        let scaled = numerator.multipliedReportingOverflow(by: 65_536)
        guard !scaled.overflow else {
            throw DeterministicFieldCadenceV4Error.arithmeticOverflow
        }
        var quotient = scaled.partialValue / denominator
        let remainder = scaled.partialValue % denominator
        let doubledRemainder = remainder.multipliedReportingOverflow(by: 2)
        guard !doubledRemainder.overflow else {
            throw DeterministicFieldCadenceV4Error.arithmeticOverflow
        }
        if doubledRemainder.partialValue > denominator
            || (doubledRemainder.partialValue == denominator
                && !quotient.isMultiple(of: 2)) {
            let rounded = quotient.addingReportingOverflow(1)
            guard !rounded.overflow else {
                throw DeterministicFieldCadenceV4Error.arithmeticOverflow
            }
            quotient = rounded.partialValue
        }
        guard quotient <= 65_536, let result = UInt32(exactly: quotient) else {
            throw DeterministicFieldCadenceV4Error.arithmeticOverflow
        }
        return result
    }
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
