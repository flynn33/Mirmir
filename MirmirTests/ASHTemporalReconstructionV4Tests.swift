import XCTest
@testable import Mirmir

final class ASHTemporalReconstructionV4Tests: XCTestCase {
    private let formatIdentity = try! ASHSHA256V4(
        String(repeating: "a", count: 64)
    )
    private let planIdentity = try! ASHSHA256V4(
        String(repeating: "b", count: 64)
    )
    private let runtimeIdentity = try! ASHSHA256V4(
        String(repeating: "c", count: 64)
    )

    func testBlockMatchingRecoversExactTranslationWithTotalTieOrder() throws {
        let previous = try makeFrame(id: "f0", ordinal: 0) { x, y in
            self.patternSample(x: x, y: y)
        }
        let current = try makeFrame(id: "f1", ordinal: 1) { x, y in
            let sourceX = min(x + 2, 15)
            let sourceY = min(y + 1, 15)
            return self.patternSample(x: sourceX, y: sourceY)
        }
        let analysis = try ASHTemporalMotionAnalyzerV4.analyze(
            current: current,
            previous: previous
        )
        XCTAssertFalse(analysis.sceneCut)
        XCTAssertEqual(analysis.vectors[0].dx, 2)
        XCTAssertEqual(analysis.vectors[0].dy, 1)
        XCTAssertEqual(analysis.vectors[0].absoluteDifference, 0)
        XCTAssertEqual(
            analysis.alignedPrevious?.samples.prefix(8),
            current.luma.samples.prefix(8)
        )
    }

    func testTexturelessTieSelectsZeroVectorAndReportsNoConfidence() throws {
        let previous = try makeFrame(id: "f0", ordinal: 0) { _, _ in 400 }
        let current = try makeFrame(id: "f1", ordinal: 1) { _, _ in 400 }
        let analysis = try ASHTemporalMotionAnalyzerV4.analyze(
            current: current,
            previous: previous
        )
        XCTAssertTrue(analysis.vectors.allSatisfy {
            $0.dx == 0 && $0.dy == 0 && $0.confidenceQ16 == 0
                && $0.occluded
        })
        XCTAssertEqual(analysis.temporalEvidenceQ16, 0)
    }

    func testSceneCutSuppressesMotionAndAlignedHistory() throws {
        let previous = try makeFrame(id: "dark", ordinal: 0) { _, _ in 64 }
        let current = try makeFrame(id: "bright", ordinal: 1) { _, _ in 940 }
        let analysis = try ASHTemporalMotionAnalyzerV4.analyze(
            current: current,
            previous: previous
        )
        XCTAssertTrue(analysis.sceneCut)
        XCTAssertGreaterThanOrEqual(
            analysis.sceneDifferenceQ16,
            ASHTemporalBlockMatchingConfigurationV4.canonical
                .sceneCutHistogramThresholdQ16
        )
        XCTAssertNil(analysis.alignedPrevious)
        XCTAssertTrue(analysis.vectors.isEmpty)
    }

    func testFutureConcurrentAndSemanticMismatchesFailClosed() throws {
        let current = try makeFrame(id: "f1", ordinal: 1) { x, y in
            UInt16(64 + x + y)
        }
        let future = try makeFrame(id: "f2", ordinal: 2) { x, y in
            UInt16(64 + x + y)
        }
        XCTAssertThrowsError(
            try ASHTemporalMotionAnalyzerV4.analyze(
                current: current,
                previous: future
            )
        ) { error in
            XCTAssertEqual(
                error as? ASHTemporalV4Error,
                .futureOrConcurrentHistory
            )
        }

        let otherStream = try makeFrame(
            id: "other",
            stream: "other-stream",
            ordinal: 0
        ) { x, y in UInt16(64 + x + y) }
        XCTAssertThrowsError(
            try ASHTemporalMotionAnalyzerV4.analyze(
                current: current,
                previous: otherStream
            )
        ) { error in
            XCTAssertEqual(
                error as? ASHTemporalV4Error,
                .streamIdentityMismatch
            )
        }
    }

    func testHistoryIsBoundedOrderedAndResetGenerationIsExplicit() throws {
        var history = try ASHTemporalHistoryV4(capacity: 2)
        try history.append(makeFrame(id: "f0", ordinal: 0) { _, _ in 100 })
        try history.append(makeFrame(id: "f1", ordinal: 1) { _, _ in 101 })
        try history.append(makeFrame(id: "f2", ordinal: 2) { _, _ in 102 })
        XCTAssertEqual(history.frames.map(\.frameID), ["f1", "f2"])
        XCTAssertThrowsError(
            try history.append(makeFrame(id: "stale", ordinal: 1) { _, _ in 100 })
        )
        try history.reset(reason: .seek)
        XCTAssertEqual(history.generation, 1)
        XCTAssertEqual(history.lastResetReason, .seek)
        XCTAssertTrue(history.frames.isEmpty)
    }

    func testCheckpointIsCanonicalIdentityBoundAndResumeStable() throws {
        var history = try ASHTemporalHistoryV4(capacity: 3)
        try history.append(makeFrame(id: "f0", ordinal: 0) { x, y in
            UInt16(64 + x * 2 + y * 3)
        })
        try history.append(makeFrame(id: "f1", ordinal: 1) { x, y in
            UInt16(65 + x * 2 + y * 3)
        })
        let checkpoint = try ASHTemporalCheckpointV4(
            planSHA256: planIdentity,
            runtimeManifestSHA256: runtimeIdentity,
            lastCompletedInputOrdinal: 1,
            lastCompletedOutputPresentationTime: try ExactRationalV4(1, 30),
            history: history
        )
        let data = try checkpoint.canonicalData
        let decoded = try ASHTemporalCheckpointV4.decodeCanonical(
            data,
            expectedPlanSHA256: planIdentity,
            expectedRuntimeManifestSHA256: runtimeIdentity
        )
        XCTAssertEqual(decoded, checkpoint)
        XCTAssertEqual(
            try decoded.canonicalSHA256,
            try checkpoint.canonicalSHA256
        )

        let current = try makeFrame(id: "f2", ordinal: 2) { x, y in
            UInt16(66 + x * 2 + y * 3)
        }
        XCTAssertEqual(
            try ASHTemporalMotionAnalyzerV4.analyze(
                current: current,
                previous: try XCTUnwrap(history.frames.last)
            ),
            try ASHTemporalMotionAnalyzerV4.analyze(
                current: current,
                previous: try XCTUnwrap(decoded.history.frames.last)
            )
        )

        XCTAssertThrowsError(
            try ASHTemporalCheckpointV4.decodeCanonical(
                data,
                expectedPlanSHA256: runtimeIdentity,
                expectedRuntimeManifestSHA256: runtimeIdentity
            )
        ) { error in
            XCTAssertEqual(
                error as? ASHTemporalV4Error,
                .checkpointIdentityMismatch
            )
        }
    }

    func testCheckpointRejectsNonCanonicalJSON() throws {
        let history = try ASHTemporalHistoryV4(capacity: 2)
        let checkpoint = try ASHTemporalCheckpointV4(
            planSHA256: planIdentity,
            runtimeManifestSHA256: runtimeIdentity,
            lastCompletedInputOrdinal: 0,
            lastCompletedOutputPresentationTime: .zero,
            history: history
        )
        var data = try checkpoint.canonicalData
        data.append(0x0a)
        XCTAssertThrowsError(
            try ASHTemporalCheckpointV4.decodeCanonical(
                data,
                expectedPlanSHA256: planIdentity,
                expectedRuntimeManifestSHA256: runtimeIdentity
            )
        ) { error in
            XCTAssertEqual(
                error as? ASHTemporalV4Error,
                .nonCanonicalCheckpoint
            )
        }
    }

    func testResetPathIsExactSpatialIdentity() throws {
        let spatial = try ASHTemporalPlaneV4(
            width: 4,
            height: 2,
            minimumCode: 64,
            maximumCode: 940,
            samples: [100, 200, 300, 400, 500, 600, 700, 800]
        )
        let history = try spatial.replacing(
            samples: Array(repeating: 400, count: 8)
        )
        let state = try ASHState(payloadBits: [0, 0, 0, 0, 0, 0, 0, 0])
        let result = try ASHTemporalReconstructorV4.reconstruct(
            spatial: spatial,
            alignedHistory: history,
            sourceState: state,
            motionConfidenceQ16: ASHNormalizedQ16V4.scale,
            resetReason: .sceneCut,
            program: ASHDepthFourBranchCompilerV4.compileCanonical()
        )
        XCTAssertEqual(result.output, spatial)
        XCTAssertEqual(result.historyWeightQ16, 0)
    }

    func testSpatialReconstructionIsStateConditionedAndDeterministic() throws {
        let spatial = try ASHTemporalPlaneV4(
            width: 8,
            height: 8,
            minimumCode: 64,
            maximumCode: 940,
            samples: (0..<64).map { index in
                let x = index % 8
                let y = index / 8
                return UInt16(96 + ((x * 101 + y * 67) % 780))
            }
        )
        let program = try ASHDepthFourBranchCompilerV4.compileCanonical()
        var distinctPixels = Set<[UInt16]>()
        var distinctTargets = Set<UInt8>()
        for payload in 0..<256 {
            let state = try ASHState(payloadBits: (0..<8).map { bit in
                (payload >> bit) & 1
            })
            let first = try ASHSpatialReconstructorV4.reconstruct(
                spatial: spatial,
                sourceState: state,
                program: program
            )
            let second = try ASHSpatialReconstructorV4.reconstruct(
                spatial: spatial,
                sourceState: state,
                program: program
            )
            XCTAssertEqual(first, second)
            XCTAssertTrue(first.output.samples.allSatisfy {
                (spatial.minimumCode...spatial.maximumCode).contains($0)
            })
            distinctPixels.insert(first.output.samples)
            distinctTargets.insert(first.targetMessageRawValue)
        }
        XCTAssertEqual(distinctTargets, Set(UInt8(0)..<UInt8(16)))
        XCTAssertGreaterThan(distinctPixels.count, 1)
    }

    func testSpatialReconstructionLeavesConstantPlaneExact() throws {
        let spatial = try ASHTemporalPlaneV4(
            width: 5,
            height: 3,
            minimumCode: 64,
            maximumCode: 940,
            samples: Array(repeating: 512, count: 15)
        )
        let state = try ASHState(
            payloadBits: [1, 0, 1, 0, 1, 0, 1, 0]
        )
        let result = try ASHSpatialReconstructorV4.reconstruct(
            spatial: spatial,
            sourceState: state,
            program: ASHDepthFourBranchCompilerV4.compileCanonical()
        )
        XCTAssertEqual(result.output, spatial)
        XCTAssertEqual(result.basisGainsQ16.count, 4)
        XCTAssertEqual(result.basisGainsQ16[3], 0)
    }

    func testBlockwiseReconstructionKeepsOccludedBlocksSpatial() throws {
        let spatial = try ASHTemporalPlaneV4(
            width: 4,
            height: 2,
            minimumCode: 64,
            maximumCode: 940,
            samples: Array(repeating: 700, count: 8)
        )
        let history = try spatial.replacing(
            samples: Array(repeating: 300, count: 8)
        )
        let motion = try makeTwoBlockMotion(
            aligned: history,
            firstConfidenceQ16: ASHNormalizedQ16V4.scale,
            secondConfidenceQ16: ASHNormalizedQ16V4.scale,
            secondOccluded: true
        )
        let state = try ASHState(
            payloadBits: Array(repeating: 0, count: ASHState.payloadBitCount)
        )
        let result = try ASHTemporalReconstructorV4.reconstruct(
            spatial: spatial,
            motionAnalysis: motion,
            sourceState: state,
            resetReason: nil,
            program: ASHDepthFourBranchCompilerV4.compileCanonical()
        )

        XCTAssertTrue(result.output.samples[0..<2].allSatisfy { $0 < 700 })
        XCTAssertTrue(result.output.samples[4..<6].allSatisfy { $0 < 700 })
        XCTAssertEqual(Array(result.output.samples[2..<4]), [700, 700])
        XCTAssertEqual(Array(result.output.samples[6..<8]), [700, 700])
        XCTAssertEqual(
            result.historyWeightQ16,
            ASHTemporalReconstructorV4.maximumHistoryWeightQ16 / 2
        )
    }

    func testBlockwiseReconstructionUsesEachVectorsConfidence() throws {
        let spatial = try ASHTemporalPlaneV4(
            width: 4,
            height: 2,
            minimumCode: 64,
            maximumCode: 940,
            samples: Array(repeating: 700, count: 8)
        )
        let history = try spatial.replacing(
            samples: Array(repeating: 300, count: 8)
        )
        let motion = try makeTwoBlockMotion(
            aligned: history,
            firstConfidenceQ16: ASHNormalizedQ16V4.scale,
            secondConfidenceQ16: 4_096,
            secondOccluded: false
        )
        let state = try ASHState(
            payloadBits: Array(repeating: 0, count: ASHState.payloadBitCount)
        )
        let result = try ASHTemporalReconstructorV4.reconstruct(
            spatial: spatial,
            motionAnalysis: motion,
            sourceState: state,
            resetReason: nil,
            program: ASHDepthFourBranchCompilerV4.compileCanonical()
        )

        XCTAssertLessThan(result.output.samples[0], result.output.samples[2])
        XCTAssertLessThan(result.output.samples[2], 700)
        XCTAssertLessThanOrEqual(
            result.historyWeightQ16,
            ASHTemporalReconstructorV4.maximumHistoryWeightQ16
        )
    }

    func testASHStateMateriallyConditionsBlockwiseTemporalPixels() throws {
        let spatial = try ASHTemporalPlaneV4(
            width: 4,
            height: 2,
            minimumCode: 64,
            maximumCode: 940,
            samples: Array(repeating: 700, count: 8)
        )
        let history = try spatial.replacing(
            samples: Array(repeating: 300, count: 8)
        )
        let motion = try makeTwoBlockMotion(
            aligned: history,
            firstConfidenceQ16: 8_192,
            secondConfidenceQ16: 8_192,
            secondOccluded: false
        )
        let program = try ASHDepthFourBranchCompilerV4.compileCanonical()
        let states = try (0..<256).map { rawPayload -> ASHState in
            try ASHState(payloadBits: (0..<8).map {
                (rawPayload >> (7 - $0)) & 1
            })
        }
        let results = try states.map { state in
            try ASHTemporalReconstructorV4.reconstruct(
                spatial: spatial,
                motionAnalysis: motion,
                sourceState: state,
                resetReason: nil,
                program: program
            )
        }

        XCTAssertGreaterThan(Set(results.map(\.historyWeightQ16)).count, 1)
        XCTAssertGreaterThan(
            Set(results.map { $0.output.samples[0] }).count,
            1
        )
        XCTAssertTrue(results.allSatisfy { $0.output.samples[0] < 700 })
    }

    func testBlockwiseResetRemainsExactSpatialIdentity() throws {
        let spatial = try ASHTemporalPlaneV4(
            width: 4,
            height: 2,
            minimumCode: 64,
            maximumCode: 940,
            samples: Array(repeating: 700, count: 8)
        )
        let motion = try makeTwoBlockMotion(
            aligned: spatial,
            firstConfidenceQ16: ASHNormalizedQ16V4.scale,
            secondConfidenceQ16: ASHNormalizedQ16V4.scale,
            secondOccluded: false
        )
        let result = try ASHTemporalReconstructorV4.reconstruct(
            spatial: spatial,
            motionAnalysis: motion,
            sourceState: try ASHState(
                payloadBits: Array(
                    repeating: 0,
                    count: ASHState.payloadBitCount
                )
            ),
            resetReason: .discontinuity,
            program: ASHDepthFourBranchCompilerV4.compileCanonical()
        )

        XCTAssertEqual(result.output, spatial)
        XCTAssertEqual(result.historyWeightQ16, 0)
    }

    func testASHStateMateriallyConditionsTemporalPixels() throws {
        let spatial = try ASHTemporalPlaneV4(
            width: 4,
            height: 2,
            minimumCode: 64,
            maximumCode: 940,
            samples: Array(repeating: 700, count: 8)
        )
        let history = try spatial.replacing(
            samples: Array(repeating: 300, count: 8)
        )
        let program = try ASHDepthFourBranchCompilerV4.compileCanonical()
        let states = try (0..<256).map { rawPayload -> ASHState in
            try ASHState(payloadBits: (0..<8).map {
                (rawPayload >> (7 - $0)) & 1
            })
        }
        let results = try states.map { state in
            try ASHTemporalReconstructorV4.reconstruct(
                spatial: spatial,
                alignedHistory: history,
                sourceState: state,
                motionConfidenceQ16: ASHNormalizedQ16V4.scale,
                resetReason: nil,
                program: program
            )
        }
        XCTAssertGreaterThan(Set(results.map(\.historyWeightQ16)).count, 1)
        XCTAssertGreaterThan(Set(results.map { $0.output.samples[0] }).count, 1)
        XCTAssertTrue(results.allSatisfy { $0.output.samples[0] < 700 })
    }

    func testInvalidPlaneAndIntegrityStateFailClosed() throws {
        XCTAssertThrowsError(
            try ASHTemporalPlaneV4(
                width: 2,
                height: 2,
                minimumCode: 64,
                maximumCode: 940,
                samples: [64, 65, 66]
            )
        )
        let spatial = try ASHTemporalPlaneV4(
            width: 1,
            height: 1,
            minimumCode: 64,
            maximumCode: 940,
            samples: [500]
        )
        XCTAssertThrowsError(
            try ASHTemporalReconstructorV4.reconstruct(
                spatial: spatial,
                alignedHistory: spatial,
                sourceState: try ASHState(rawValue: 1),
                motionConfidenceQ16: ASHNormalizedQ16V4.scale,
                resetReason: nil,
                program: ASHDepthFourBranchCompilerV4.compileCanonical()
            )
        )
    }

    private func makeFrame(
        id: String,
        stream: String = "video-main",
        ordinal: Int64,
        generator: (Int, Int) -> UInt16
    ) throws -> ASHTemporalFrameV4 {
        let samples = (0..<16).flatMap { y in
            (0..<16).map { x in generator(x, y) }
        }
        return try ASHTemporalFrameV4(
            frameID: id,
            streamID: stream,
            formatIdentity: formatIdentity,
            ordinal: ordinal,
            presentationTime: try ExactRationalV4(ordinal, 30),
            luma: ASHTemporalPlaneV4(
                width: 16,
                height: 16,
                minimumCode: 64,
                maximumCode: 940,
                samples: samples
            ),
            tileStateRawValues: [],
            cadenceID: "progressive"
        )
    }

    private func patternSample(x: Int, y: Int) -> UInt16 {
        let horizontal = x * 37
        let vertical = y * 61
        let crossTerm = x * y * 3
        return UInt16(64 + ((horizontal + vertical + crossTerm) % 800))
    }

    private func makeTwoBlockMotion(
        aligned: ASHTemporalPlaneV4,
        firstConfidenceQ16: UInt32,
        secondConfidenceQ16: UInt32,
        secondOccluded: Bool
    ) throws -> ASHTemporalMotionAnalysisV4 {
        let vectors = [
            ASHTemporalMotionVectorV4(
                blockIndex: 0,
                originX: 0,
                originY: 0,
                width: 2,
                height: 2,
                dx: 0,
                dy: 0,
                absoluteDifference: 0,
                normalizedCostQ16: 0,
                confidenceQ16: firstConfidenceQ16,
                occluded: false
            ),
            ASHTemporalMotionVectorV4(
                blockIndex: 1,
                originX: 2,
                originY: 0,
                width: 2,
                height: 2,
                dx: 0,
                dy: 0,
                absoluteDifference: 0,
                normalizedCostQ16: 0,
                confidenceQ16: secondConfidenceQ16,
                occluded: secondOccluded
            )
        ]
        let analysis = ASHTemporalMotionAnalysisV4(
            policyID: "ash.test.two-block-motion",
            currentFrameID: "current",
            previousFrameID: "previous",
            sceneDifferenceQ16: 0,
            sceneCut: false,
            temporalEvidenceQ16: 0,
            blockColumns: 2,
            blockRows: 1,
            vectors: vectors,
            alignedPrevious: aligned
        )
        try analysis.validate()
        return analysis
    }
}
