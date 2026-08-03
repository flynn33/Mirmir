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
}
