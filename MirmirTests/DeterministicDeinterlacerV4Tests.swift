import XCTest
@testable import Mirmir

final class DeterministicDeinterlacerV4Tests: XCTestCase {
    func testTFFAndBFFProduceExactHalfFrameCadenceInDominanceOrder() throws {
        let current = try plane([
            [100, 110],
            [120, 130],
            [140, 150],
            [160, 170]
        ])
        let timing = try InterlacedFrameTimingV4(
            presentationValue: 3,
            durationValue: 1,
            timescale: 30
        )
        let thresholds = DeinterlaceThresholdsV4(
            motionCodeDifference: 0,
            sceneCutMeanAbsoluteDifference: 0
        )

        let tff = try DeterministicDeinterlacerV4.deinterlace(
            previous: nil,
            current: current,
            next: nil,
            dominance: .topFieldFirst,
            timing: timing,
            thresholds: thresholds
        )
        XCTAssertEqual(tff.map(\.sourceField), [.top, .bottom])
        XCTAssertEqual(
            tff.map(\.timing),
            [
                ProgressiveFieldTimingV4(
                    presentationValue: 6,
                    durationValue: 1,
                    timescale: 60
                ),
                ProgressiveFieldTimingV4(
                    presentationValue: 7,
                    durationValue: 1,
                    timescale: 60
                )
            ]
        )

        let bff = try DeterministicDeinterlacerV4.deinterlace(
            previous: nil,
            current: current,
            next: nil,
            dominance: .bottomFieldFirst,
            timing: timing,
            thresholds: thresholds
        )
        XCTAssertEqual(bff.map(\.sourceField), [.bottom, .top])
        XCTAssertEqual(bff.map(\.timing), tff.map(\.timing))

        let negativeTimeline = try DeterministicDeinterlacerV4.deinterlace(
            previous: nil,
            current: current,
            next: nil,
            dominance: .topFieldFirst,
            timing: InterlacedFrameTimingV4(
                presentationValue: -1,
                durationValue: 1,
                timescale: 30
            ),
            thresholds: thresholds
        )
        XCTAssertEqual(
            negativeTimeline.map(\.timing),
            [
                ProgressiveFieldTimingV4(
                    presentationValue: -2,
                    durationValue: 1,
                    timescale: 60
                ),
                ProgressiveFieldTimingV4(
                    presentationValue: -1,
                    durationValue: 1,
                    timescale: 60
                )
            ]
        )
    }

    func testCausalClassifierDetectsEveryTFFTelecinePhaseAndPersistsState()
        throws {
        let pairs = [
            (top: 1, bottom: 2),
            (top: 3, bottom: 4),
            (top: 3, bottom: 6),
            (top: 7, bottom: 8),
            (top: 9, bottom: 8),
            (top: 11, bottom: 12),
            (top: 13, bottom: 14),
            (top: 13, bottom: 16),
            (top: 17, bottom: 18),
            (top: 19, bottom: 18),
            (top: 21, bottom: 22),
            (top: 23, bottom: 24),
            (top: 23, bottom: 26),
            (top: 27, bottom: 28),
            (top: 29, bottom: 28)
        ]
        let decisions = try cadenceDecisions(
            dominance: .topFieldFirst,
            pairs: pairs
        )

        XCTAssertEqual(
            decisions.prefix(10).map(\.state.classification),
            Array(repeating: .interlaced, count: 10)
        )
        XCTAssertTrue(
            decisions.dropFirst(10).allSatisfy {
                $0.state.classification == .telecine32
            }
        )
        XCTAssertEqual(
            decisions[10].state.observations.map(\.repeatEvidence),
            [
                .neither, .topOnly, .neither, .bottomOnly, .neither,
                .neither, .topOnly, .neither, .bottomOnly, .neither
            ]
        )
        XCTAssertTrue(decisions[10].didTransition)
        XCTAssertFalse(decisions[11].didTransition)
        XCTAssertEqual(
            decisions[14].state.cadenceID,
            "telecine_3_2_tff_double_rate"
        )

        let restoredState = try JSONDecoder().decode(
            DeterministicFieldCadenceStateV4.self,
            from: JSONEncoder().encode(decisions[10].state)
        )
        let next = try cadencePlane(top: 23, bottom: 24)
        let resumed = try DeterministicFieldCadenceClassifierV4.observe(
            previous: try cadencePlane(top: 21, bottom: 22),
            current: next,
            dominance: .topFieldFirst,
            repeatCodeDifference: 0,
            state: restoredState
        )
        XCTAssertEqual(resumed, decisions[11])
    }

    func testBFFTelecineOrderMixedTransitionAndReturnToInterlaced() throws {
        let bffPairs = [
            (top: 1, bottom: 2),
            (top: 3, bottom: 4),
            (top: 5, bottom: 4),
            (top: 7, bottom: 8),
            (top: 7, bottom: 10),
            (top: 11, bottom: 12),
            (top: 13, bottom: 14),
            (top: 15, bottom: 14),
            (top: 17, bottom: 18),
            (top: 17, bottom: 20),
            (top: 21, bottom: 22)
        ]
        let bff = try cadenceDecisions(
            dominance: .bottomFieldFirst,
            pairs: bffPairs
        )
        XCTAssertEqual(bff.last?.state.classification, .telecine32)
        XCTAssertEqual(
            bff.last?.state.observations.map(\.repeatEvidence),
            [
                .neither, .bottomOnly, .neither, .topOnly, .neither,
                .neither, .bottomOnly, .neither, .topOnly, .neither
            ]
        )
        XCTAssertEqual(
            bff.last?.state.cadenceID,
            "telecine_3_2_bff_double_rate"
        )

        var state = try XCTUnwrap(bff.last?.state)
        var previous = try cadencePlane(top: 21, bottom: 22)
        var current = try cadencePlane(top: 21, bottom: 24)
        var decision = try DeterministicFieldCadenceClassifierV4.observe(
            previous: previous,
            current: current,
            dominance: .bottomFieldFirst,
            repeatCodeDifference: 0,
            state: state
        )
        XCTAssertEqual(decision.state.classification, .mixed)
        XCTAssertTrue(decision.didTransition)
        state = decision.state

        var transitionCount = 0
        for token in stride(from: 25, through: 43, by: 2) {
            previous = current
            current = try cadencePlane(top: token, bottom: token + 1)
            decision = try DeterministicFieldCadenceClassifierV4.observe(
                previous: previous,
                current: current,
                dominance: .bottomFieldFirst,
                repeatCodeDifference: 0,
                state: state
            )
            if decision.didTransition { transitionCount += 1 }
            state = decision.state
        }
        XCTAssertEqual(state.classification, .interlaced)
        XCTAssertEqual(transitionCount, 1)
    }

    func testDominanceTransitionResetsEvidenceAndWholeFrameRepeatsDoNotMimic32()
        throws {
        let pairs = [
            (top: 1, bottom: 2),
            (top: 3, bottom: 4),
            (top: 3, bottom: 6),
            (top: 7, bottom: 8),
            (top: 9, bottom: 8),
            (top: 11, bottom: 12),
            (top: 13, bottom: 14),
            (top: 13, bottom: 16),
            (top: 17, bottom: 18),
            (top: 19, bottom: 18),
            (top: 21, bottom: 22)
        ]
        let tff = try cadenceDecisions(
            dominance: .topFieldFirst,
            pairs: pairs
        )
        let switched = try DeterministicFieldCadenceClassifierV4.observe(
            previous: try cadencePlane(top: 21, bottom: 22),
            current: try cadencePlane(top: 23, bottom: 24),
            dominance: .bottomFieldFirst,
            repeatCodeDifference: 0,
            state: try XCTUnwrap(tff.last?.state)
        )
        XCTAssertTrue(switched.didTransition)
        XCTAssertEqual(switched.state.dominance, .bottomFieldFirst)
        XCTAssertEqual(switched.state.inputFrameCount, 1)
        XCTAssertEqual(
            switched.state.streamInputFrameCount,
            UInt64(pairs.count + 1)
        )
        XCTAssertEqual(switched.state.classification, .interlaced)
        XCTAssertTrue(switched.state.observations.isEmpty)

        let duplicatePairs = Array(
            repeating: (top: 20, bottom: 21),
            count: 13
        )
        let duplicates = try cadenceDecisions(
            dominance: .topFieldFirst,
            pairs: duplicatePairs
        )
        XCTAssertTrue(
            duplicates.allSatisfy {
                $0.state.classification == .interlaced
            }
        )
        XCTAssertEqual(
            duplicates.last?.state.observations.map(\.repeatEvidence),
            Array(repeating: .both, count: 10)
        )
    }

    func testRepeatEvidenceRejectsSparseAndBlockLocalMotionAtNV12AndP010Scale()
        throws {
        let domains: [(minimum: UInt16, maximum: UInt16, threshold: UInt16,
            base: UInt16)] = [
            (16, 235, 4, 64),
            (64, 940, 16, 256)
        ]
        for domain in domains {
            let previous = try flatCadencePlane(
                width: 128,
                height: 64,
                minimum: domain.minimum,
                maximum: domain.maximum,
                top: domain.base,
                bottom: domain.base
            )
            let initial = try DeterministicFieldCadenceClassifierV4.observe(
                previous: nil,
                current: previous,
                dominance: .topFieldFirst,
                repeatCodeDifference: domain.threshold,
                state: nil
            )

            let boundary = try flatCadencePlane(
                width: 128,
                height: 64,
                minimum: domain.minimum,
                maximum: domain.maximum,
                top: domain.base + domain.threshold,
                bottom: domain.base + domain.threshold + 1
            )
            let boundaryDecision = try DeterministicFieldCadenceClassifierV4
                .observe(
                    previous: previous,
                    current: boundary,
                    dominance: .topFieldFirst,
                    repeatCodeDifference: domain.threshold,
                    state: initial.state
                )
            XCTAssertEqual(
                boundaryDecision.observation?.repeatEvidence,
                .topOnly
            )
            XCTAssertLessThanOrEqual(
                try XCTUnwrap(
                    boundaryDecision.observation?
                        .topMeanAbsoluteDifferenceQ16
                ),
                65_536
            )

            let localized = try flatCadencePlane(
                width: 128,
                height: 64,
                minimum: domain.minimum,
                maximum: domain.maximum,
                top: domain.base,
                bottom: domain.base + domain.threshold + 1,
                topOverrides: Array(repeating: domain.maximum, count: 9)
            )
            let localizedDecision = try DeterministicFieldCadenceClassifierV4
                .observe(
                    previous: previous,
                    current: localized,
                    dominance: .topFieldFirst,
                    repeatCodeDifference: domain.threshold,
                    state: initial.state
                )
            XCTAssertEqual(
                localizedDecision.observation?.repeatEvidence,
                .neither
            )
            XCTAssertGreaterThan(
                try XCTUnwrap(
                    localizedDecision.observation?
                        .topMaximumBlockChangedSampleFractionQ16
                ),
                DeterministicFieldCadenceClassifierV4
                    .maximumBlockChangedSampleFractionQ16
            )

            let sparse = try flatCadencePlane(
                width: 64,
                height: 16,
                minimum: domain.minimum,
                maximum: domain.maximum,
                top: domain.base,
                bottom: domain.base + domain.threshold + 1,
                topOverrides: Array(repeating: domain.maximum, count: 9)
            )
            let sparsePrevious = try flatCadencePlane(
                width: 64,
                height: 16,
                minimum: domain.minimum,
                maximum: domain.maximum,
                top: domain.base,
                bottom: domain.base
            )
            let sparseInitial = try DeterministicFieldCadenceClassifierV4
                .observe(
                    previous: nil,
                    current: sparsePrevious,
                    dominance: .topFieldFirst,
                    repeatCodeDifference: domain.threshold,
                    state: nil
                )
            let sparseDecision = try DeterministicFieldCadenceClassifierV4
                .observe(
                    previous: sparsePrevious,
                    current: sparse,
                    dominance: .topFieldFirst,
                    repeatCodeDifference: domain.threshold,
                    state: sparseInitial.state
                )
            XCTAssertEqual(sparseDecision.observation?.repeatEvidence, .neither)
            XCTAssertGreaterThan(
                try XCTUnwrap(
                    sparseDecision.observation?.topChangedSampleFractionQ16
                ),
                DeterministicFieldCadenceClassifierV4
                    .maximumChangedSampleFractionQ16
            )

            let minimumPlane = try flatCadencePlane(
                width: 16,
                height: 16,
                minimum: domain.minimum,
                maximum: domain.maximum,
                top: domain.minimum,
                bottom: domain.minimum
            )
            let maximumPlane = try flatCadencePlane(
                width: 16,
                height: 16,
                minimum: domain.minimum,
                maximum: domain.maximum,
                top: domain.maximum,
                bottom: domain.maximum
            )
            let fullScaleInitial = try DeterministicFieldCadenceClassifierV4
                .observe(
                    previous: nil,
                    current: minimumPlane,
                    dominance: .topFieldFirst,
                    repeatCodeDifference: domain.threshold,
                    state: nil
                )
            let fullScale = try DeterministicFieldCadenceClassifierV4.observe(
                previous: minimumPlane,
                current: maximumPlane,
                dominance: .topFieldFirst,
                repeatCodeDifference: domain.threshold,
                state: fullScaleInitial.state
            )
            XCTAssertEqual(
                fullScale.observation?.topMeanAbsoluteDifferenceQ16,
                65_536
            )
            XCTAssertEqual(
                fullScale.observation?.bottomMeanAbsoluteDifferenceQ16,
                65_536
            )
        }
    }

    func testTwoCycleHysteresisRejectsOneCycleOrdinaryMotionAndAlternatingHolds()
        throws {
        let oneCycleThenMotion = [
            (top: 1, bottom: 2),
            (top: 3, bottom: 4),
            (top: 3, bottom: 6),
            (top: 7, bottom: 8),
            (top: 9, bottom: 8),
            (top: 11, bottom: 12),
            (top: 13, bottom: 14),
            (top: 15, bottom: 16),
            (top: 17, bottom: 18),
            (top: 19, bottom: 20),
            (top: 21, bottom: 22)
        ]
        XCTAssertTrue(try cadenceDecisions(
            dominance: .topFieldFirst,
            pairs: oneCycleThenMotion
        ).allSatisfy { $0.state.classification == .interlaced })

        let ordinaryMotion = (0..<16).map {
            (top: $0 * 2 + 1, bottom: $0 * 2 + 2)
        }
        XCTAssertTrue(try cadenceDecisions(
            dominance: .topFieldFirst,
            pairs: ordinaryMotion
        ).allSatisfy { $0.state.classification == .interlaced })

        var alternatingHolds: [(top: Int, bottom: Int)] = []
        for token in stride(from: 1, through: 15, by: 2) {
            alternatingHolds.append((top: token, bottom: token + 1))
            alternatingHolds.append((top: token, bottom: token + 1))
        }
        let holdDecisions = try cadenceDecisions(
            dominance: .topFieldFirst,
            pairs: alternatingHolds
        )
        XCTAssertTrue(
            holdDecisions.allSatisfy {
                $0.state.classification == .interlaced
            }
        )
        XCTAssertTrue(
            holdDecisions.compactMap(\.observation).contains {
                $0.repeatEvidence == .both
            }
        )
    }

    func testCadenceOrdinalHeadroomFailsClosedWithoutIntegerTrap() throws {
        let exhausted = try DeterministicFieldCadenceStateV4(
            dominance: .topFieldFirst,
            streamInputFrameCount: UInt64.max,
            inputFrameCount: 1,
            classification: .interlaced,
            observations: []
        )
        let plane = try cadencePlane(top: 1, bottom: 2)
        XCTAssertThrowsError(
            try DeterministicFieldCadenceClassifierV4.observe(
                previous: plane,
                current: plane,
                dominance: .topFieldFirst,
                repeatCodeDifference: 0,
                state: exhausted
            )
        ) { error in
            XCTAssertEqual(
                error as? DeterministicFieldCadenceV4Error,
                .arithmeticOverflow
            )
        }
    }

    func testEachOutputPreservesItsSourceFieldLinesByteExactly() throws {
        let current = try plane([
            [64, 65, 66],
            [200, 201, 202],
            [300, 301, 302],
            [400, 401, 402]
        ])
        let outputs = try deinterlace(current: current)
        let top = try XCTUnwrap(outputs.first { $0.sourceField == .top })
        let bottom = try XCTUnwrap(outputs.first { $0.sourceField == .bottom })

        for x in 0..<3 {
            XCTAssertEqual(
                try top.progressivePlane.signalCode(x: x, y: 0, component: 0),
                try current.signalCode(x: x, y: 0, component: 0)
            )
            XCTAssertEqual(
                try top.progressivePlane.signalCode(x: x, y: 2, component: 0),
                try current.signalCode(x: x, y: 2, component: 0)
            )
            XCTAssertEqual(
                try bottom.progressivePlane.signalCode(x: x, y: 1, component: 0),
                try current.signalCode(x: x, y: 1, component: 0)
            )
            XCTAssertEqual(
                try bottom.progressivePlane.signalCode(x: x, y: 3, component: 0),
                try current.signalCode(x: x, y: 3, component: 0)
            )
        }
        XCTAssertEqual(top.decisions.preservedSampleCount, 6)
        XCTAssertEqual(bottom.decisions.preservedSampleCount, 6)
    }

    func testStaticTemporalNeighborsReplaceSpatialBobCandidate() throws {
        let current = try plane([[100], [120], [200], [220]])
        XCTAssertThrowsError(
            try current.signalCode(x: -1, y: 0, component: 0)
        )
        let outputs = try DeterministicDeinterlacerV4.deinterlace(
            previous: current,
            current: current,
            next: current,
            dominance: .topFieldFirst,
            timing: testTiming,
            thresholds: DeinterlaceThresholdsV4(
                motionCodeDifference: 0,
                sceneCutMeanAbsoluteDifference: 0
            )
        )
        let top = outputs[0]
        XCTAssertEqual(top.progressivePlane.samples, current.samples)
        XCTAssertEqual(top.decisions.temporalSampleCount, 2)
        XCTAssertEqual(top.decisions.spatialSampleCount, 0)
        XCTAssertFalse(top.decisions.temporalSuppressedBySceneCut)
    }

    func testMotionDisagreementSelectsSpatialCandidate() throws {
        let current = try plane([[80], [100], [100], [120]])
        let previous = try plane([[80], [0], [100], [0]])
        let next = try plane([[80], [200], [100], [200]])
        let outputs = try DeterministicDeinterlacerV4.deinterlace(
            previous: previous,
            current: current,
            next: next,
            dominance: .topFieldFirst,
            timing: testTiming,
            thresholds: DeinterlaceThresholdsV4(
                motionCodeDifference: 10,
                sceneCutMeanAbsoluteDifference: 1_023
            )
        )
        let top = outputs[0]
        XCTAssertEqual(
            try top.progressivePlane.signalCode(x: 0, y: 1, component: 0),
            90
        )
        XCTAssertEqual(
            try top.progressivePlane.signalCode(x: 0, y: 3, component: 0),
            100
        )
        XCTAssertEqual(top.decisions.temporalSampleCount, 0)
        XCTAssertEqual(top.decisions.spatialSampleCount, 2)
    }

    func testSceneCutDisablesOtherwiseStableTemporalCandidate() throws {
        let current = try plane([[100], [120], [200], [220]])
        let cutSide = try plane([[900], [120], [900], [220]])
        let outputs = try DeterministicDeinterlacerV4.deinterlace(
            previous: cutSide,
            current: current,
            next: cutSide,
            dominance: .topFieldFirst,
            timing: testTiming,
            thresholds: DeinterlaceThresholdsV4(
                motionCodeDifference: 0,
                sceneCutMeanAbsoluteDifference: 100
            )
        )
        let top = outputs[0]
        XCTAssertTrue(top.decisions.temporalSuppressedBySceneCut)
        XCTAssertEqual(top.decisions.temporalSampleCount, 0)
        XCTAssertEqual(
            try top.progressivePlane.signalCode(x: 0, y: 1, component: 0),
            150
        )
    }

    func testEdgeDirectedSpatialInterpolationHasStableTiePriority() throws {
        let current = try plane([
            [50, 0, 150],
            [500, 500, 500],
            [150, 200, 50]
        ])
        let outputs = try deinterlace(current: current)
        let top = outputs[0]
        XCTAssertEqual(
            try top.progressivePlane.signalCode(x: 1, y: 1, component: 0),
            50
        )
        XCTAssertEqual(top.decisions.spatialSampleCount, 3)
    }

    func testInvalidPlaneNeighborComponentAndTimingOverflowFailClosed() throws {
        XCTAssertThrowsError(
            try FieldPlaneV4(
                width: 2,
                height: 2,
                minimumCode: 64,
                maximumCode: 940,
                samples: [64]
            )
        )
        let current = try plane([[100], [120], [200], [220]])
        let incompatible = try plane([[100, 100], [120, 120]])
        XCTAssertThrowsError(
            try DeterministicDeinterlacerV4.deinterlace(
                previous: incompatible,
                current: current,
                next: nil,
                dominance: .topFieldFirst,
                timing: testTiming,
                thresholds: DeinterlaceThresholdsV4(
                    motionCodeDifference: 0,
                    sceneCutMeanAbsoluteDifference: 0
                )
            )
        )
        XCTAssertThrowsError(
            try DeterministicDeinterlacerV4.deinterlace(
                previous: nil,
                current: current,
                next: nil,
                dominance: .topFieldFirst,
                timing: testTiming,
                thresholds: DeinterlaceThresholdsV4(
                    motionCodeDifference: 0,
                    sceneCutMeanAbsoluteDifference: 0,
                    analysisComponent: 1
                )
            )
        )
        let overflowingTiming = try InterlacedFrameTimingV4(
            presentationValue: 0,
            durationValue: 1,
            timescale: Int32.max
        )
        XCTAssertThrowsError(
            try DeterministicDeinterlacerV4.deinterlace(
                previous: nil,
                current: current,
                next: nil,
                dominance: .topFieldFirst,
                timing: overflowingTiming,
                thresholds: DeinterlaceThresholdsV4(
                    motionCodeDifference: 0,
                    sceneCutMeanAbsoluteDifference: 0
                )
            )
        )
    }

    private var testTiming: InterlacedFrameTimingV4 {
        get throws {
            try InterlacedFrameTimingV4(
                presentationValue: 0,
                durationValue: 1,
                timescale: 30
            )
        }
    }

    private func deinterlace(
        current: FieldPlaneV4
    ) throws -> [DeinterlacedFieldFrameV4] {
        try DeterministicDeinterlacerV4.deinterlace(
            previous: nil,
            current: current,
            next: nil,
            dominance: .topFieldFirst,
            timing: testTiming,
            thresholds: DeinterlaceThresholdsV4(
                motionCodeDifference: 0,
                sceneCutMeanAbsoluteDifference: 0
            )
        )
    }

    private func plane(_ rows: [[UInt16]]) throws -> FieldPlaneV4 {
        let width = try XCTUnwrap(rows.first?.count)
        XCTAssertTrue(rows.allSatisfy { $0.count == width })
        return try FieldPlaneV4(
            width: width,
            height: rows.count,
            minimumCode: 0,
            maximumCode: 1_023,
            samples: rows.flatMap { $0 }
        )
    }

    private func cadenceDecisions(
        dominance: FieldDominanceV4,
        pairs: [(top: Int, bottom: Int)]
    ) throws -> [DeterministicFieldCadenceDecisionV4] {
        var state: DeterministicFieldCadenceStateV4?
        var previous: FieldPlaneV4?
        var decisions: [DeterministicFieldCadenceDecisionV4] = []
        for pair in pairs {
            let current = try cadencePlane(
                top: pair.top,
                bottom: pair.bottom
            )
            let decision = try DeterministicFieldCadenceClassifierV4.observe(
                previous: previous,
                current: current,
                dominance: dominance,
                repeatCodeDifference: 0,
                state: state
            )
            decisions.append(decision)
            state = decision.state
            previous = current
        }
        return decisions
    }

    private func cadencePlane(top: Int, bottom: Int) throws -> FieldPlaneV4 {
        var rows: [[UInt16]] = []
        rows.reserveCapacity(6)
        for y in 0..<6 {
            let field = y.isMultiple(of: 2) ? top : bottom
            var row: [UInt16] = []
            row.reserveCapacity(4)
            for x in 0..<4 {
                let code = 64 + field * 8 + x + y / 2
                row.append(UInt16(code))
            }
            rows.append(row)
        }
        return try plane(rows)
    }

    private func flatCadencePlane(
        width: Int,
        height: Int,
        minimum: UInt16,
        maximum: UInt16,
        top: UInt16,
        bottom: UInt16,
        topOverrides: [UInt16] = []
    ) throws -> FieldPlaneV4 {
        var samples = Array(repeating: UInt16(0), count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                samples[y * width + x] = y.isMultiple(of: 2) ? top : bottom
            }
        }
        var overrideIndex = 0
        for y in stride(from: 0, to: height, by: 2) {
            for x in 0..<width where overrideIndex < topOverrides.count {
                samples[y * width + x] = topOverrides[overrideIndex]
                overrideIndex += 1
            }
        }
        return try FieldPlaneV4(
            width: width,
            height: height,
            minimumCode: minimum,
            maximumCode: maximum,
            samples: samples
        )
    }
}
