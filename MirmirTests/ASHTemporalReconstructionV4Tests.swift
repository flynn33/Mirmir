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

    func testStreamingMotionFieldAndVectorSamplingMatchReferenceExactly()
        throws {
        let previous = try makeFrame(id: "stream-0", ordinal: 0) { x, y in
            self.patternSample(x: x, y: y)
        }
        let current = try makeFrame(id: "stream-1", ordinal: 1) { x, y in
            self.patternSample(x: min(x + 2, 15), y: min(y + 1, 15))
        }
        let referenceMotion = try ASHTemporalMotionAnalyzerV4.analyze(
            current: current,
            previous: previous
        )
        let streaming = try ASHTemporalMotionAnalyzerV4.analyzeField(
            current: current,
            previous: previous
        )
        XCTAssertEqual(streaming.field.vectors, referenceMotion.vectors)
        XCTAssertEqual(
            streaming.field.temporalEvidenceQ16,
            referenceMotion.temporalEvidenceQ16
        )
        XCTAssertEqual(streaming.field.sceneCut, referenceMotion.sceneCut)
        XCTAssertEqual(
            streaming.allocationDiagnostics.maximumRetainedCandidatesPerBlock,
            2
        )
        XCTAssertEqual(
            streaming.allocationDiagnostics.materializedAlignedSampleCount,
            0
        )

        let program = try ASHDepthFourBranchCompilerV4.compileCanonical()
        for payload in 0..<256 {
            let state = try ASHState(payloadBits: (0..<8).map { bit in
                (payload >> bit) & 1
            })
            let reference = try ASHTemporalReconstructorV4.reconstruct(
                spatial: current.luma,
                motionAnalysis: referenceMotion,
                sourceState: state,
                resetReason: nil,
                program: program
            )
            let vectorOnly = try ASHTemporalReconstructorV4.reconstruct(
                spatial: current.luma,
                motionField: streaming.field,
                previousHistory: previous,
                sourceState: state,
                resetReason: nil,
                program: program
            )
            XCTAssertEqual(vectorOnly, reference)
        }
    }

    func testParallelMotionMatchesIndependentSortedOracleAtUnevenEdges()
        throws {
        for (width, height) in [(53, 101), (129, 135), (3, 5), (1, 33), (37, 1)] {
            let previous = try makeFrame(
                id: "parallel-0", ordinal: 0, width: width, height: height
            ) { x, y in self.patternSample(x: x, y: y) }
            let current = try makeFrame(
                id: "parallel-1", ordinal: 1, width: width, height: height
            ) { x, y in
                self.patternSample(
                    x: (x + 2) % width,
                    y: (y + 1) % height
                )
            }
            let reference = try sortedMotionOracle(
                current: current, previous: previous
            )
            XCTAssertFalse(reference.sceneCut)
            for policy in [ASHTemporalMotionExecutionPolicyV4.serial,
                           .automatic,
                           .parallel(maximumWorkers: 2),
                           .parallel(maximumWorkers: 3),
                           .parallel(maximumWorkers: 7),
                           .parallel(maximumWorkers: Int.max)] {
                let result = try ASHTemporalMotionAnalyzerV4.analyzeField(
                    current: current, previous: previous,
                    executionPolicy: policy
                )
                XCTAssertEqual(result.field, reference)
                XCTAssertEqual(
                    result.allocationDiagnostics.materializedAlignedSampleCount,
                    0
                )
                XCTAssertEqual(
                    result.allocationDiagnostics.maximumRetainedCandidatesPerBlock,
                    2
                )
            }
        }
    }

    func testParallelMotionPreservesTiesOcclusionAndSceneCut() throws {
        for (previousCode, currentCode) in [
            (UInt16(400), UInt16(400)), (400, 401), (64, 940)
        ] {
            let previous = try makeFrame(
                id: "constant-0", ordinal: 0, width: 35, height: 73
            ) { _, _ in previousCode }
            let current = try makeFrame(
                id: "constant-1", ordinal: 1, width: 35, height: 73
            ) { _, _ in currentCode }
            let reference = try sortedMotionOracle(
                current: current, previous: previous
            )
            for workers in [1, 2, 7] {
                let result = try ASHTemporalMotionAnalyzerV4.analyzeField(
                    current: current, previous: previous,
                    executionPolicy: .parallel(maximumWorkers: workers)
                )
                XCTAssertEqual(result.field, reference)
            }
            if previousCode == 64 {
                XCTAssertTrue(reference.sceneCut)
                XCTAssertTrue(reference.vectors.isEmpty)
            } else {
                XCTAssertFalse(reference.sceneCut)
                XCTAssertTrue(reference.vectors.allSatisfy {
                    $0.dx == 0 && $0.dy == 0 && $0.confidenceQ16 == 0
                        && $0.occluded
                })
            }
        }
    }

    func testParallelMotionRepeatedAndConcurrentCallsMatchIndependentOracle()
        async throws {
        let previous = try makeFrame(
            id: "concurrent-0", ordinal: 0, width: 41, height: 83
        ) { x, y in self.patternSample(x: x, y: y) }
        let current = try makeFrame(
            id: "concurrent-1", ordinal: 1, width: 41, height: 83
        ) { x, y in self.patternSample(x: min(x + 1, 40), y: y) }
        let reference = try sortedMotionOracle(
            current: current, previous: previous
        )
        for _ in 0..<4 {
            XCTAssertEqual(
                try ASHTemporalMotionAnalyzerV4.analyzeField(
                    current: current, previous: previous,
                    executionPolicy: .parallel(maximumWorkers: 7)
                ).field,
                reference
            )
        }
        try await withThrowingTaskGroup(of: ASHTemporalMotionFieldV4.self) {
            group in
            for index in 0..<8 {
                group.addTask {
                    try ASHTemporalMotionAnalyzerV4.analyzeField(
                        current: current, previous: previous,
                        executionPolicy: .parallel(
                            maximumWorkers: index.isMultiple(of: 2) ? 2 : 7
                        )
                    ).field
                }
            }
            for try await field in group {
                XCTAssertEqual(field, reference)
            }
        }
    }

    func testMotionExecutionPolicyBoundsWorkersAndRejectsInvalidLimits()
        throws {
        let available = max(1, ProcessInfo.processInfo.activeProcessorCount)
        XCTAssertEqual(
            try ASHTemporalMotionExecutionPolicyV4.automatic.workerCount(
                rows: 100, blockCount: 255
            ), 1
        )
        XCTAssertEqual(
            try ASHTemporalMotionExecutionPolicyV4.automatic.workerCount(
                rows: 100, blockCount: 256
            ), min(100, available)
        )
        XCTAssertEqual(
            try ASHTemporalMotionExecutionPolicyV4.parallel(maximumWorkers: 3)
                .workerCount(rows: 100, blockCount: 1_000),
            min(3, available)
        )
        XCTAssertEqual(
            try ASHTemporalMotionExecutionPolicyV4.parallel(maximumWorkers: Int.max)
                .workerCount(rows: 2, blockCount: 1_000),
            min(2, available)
        )
        let frame = try makeFrame(id: "invalid-worker", ordinal: 0) { _, _ in 400 }
        let next = try makeFrame(id: "next", ordinal: 1) { _, _ in 400 }
        for limit in [0, -1] {
            XCTAssertThrowsError(
                try ASHTemporalMotionAnalyzerV4.analyzeField(
                    current: next, previous: frame,
                    executionPolicy: .parallel(maximumWorkers: limit)
                )
            ) { error in
                XCTAssertEqual(error as? ASHTemporalV4Error, .invalidConfiguration)
            }
        }
        XCTAssertThrowsError(
            try ASHTemporalMotionAnalyzerV4.analyzeField(
                current: frame, previous: next,
                executionPolicy: .parallel(maximumWorkers: 3)
            )
        ) { error in
            XCTAssertEqual(error as? ASHTemporalV4Error, .futureOrConcurrentHistory)
        }
    }

    func testCaptureParallelMotionBenchmarkWhenRequested() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["MIRMIR_V4_MOTION_BENCHMARK_DIR"],
              !directory.isEmpty else {
            throw XCTSkip("Set MIRMIR_V4_MOTION_BENCHMARK_DIR for motion timing.")
        }
        let processingActivity = MirmirProcessingActivity.begin(
            "Benchmarking deterministic motion"
        )
        defer { processingActivity.end() }
        struct Record: Codable {
            let width: Int
            let height: Int
            let workerCount: Int
            let fieldsEqual: Bool
            let serialSeconds: [Double]
            let parallelSeconds: [Double]
        }
        let repetitions = min(10, max(1,
            Int(environment["MIRMIR_V4_MOTION_BENCHMARK_SAMPLES"] ?? "3") ?? 3
        ))
        let policy = ASHTemporalMotionExecutionPolicyV4.parallel(
            maximumWorkers: max(1,
                Int(environment["MIRMIR_V4_MOTION_BENCHMARK_WORKERS"] ?? "")
                    ?? ProcessInfo.processInfo.activeProcessorCount
            )
        )
        var records: [Record] = []
        for (width, height) in [(1920, 816), (3840, 1632)] {
            let previous = try makeFrame(
                id: "timing-0", ordinal: 0, width: width, height: height
            ) { x, y in self.patternSample(x: x, y: y) }
            let current = try makeFrame(
                id: "timing-1", ordinal: 1, width: width, height: height
            ) { x, y in
                self.patternSample(x: min(x + 2, width - 1), y: y)
            }
            let expected = try ASHTemporalMotionAnalyzerV4.analyzeField(
                current: current, previous: previous, executionPolicy: .serial
            ).field
            XCTAssertFalse(expected.sceneCut)
            XCTAssertEqual(
                try ASHTemporalMotionAnalyzerV4.analyzeField(
                    current: current, previous: previous, executionPolicy: policy
                ).field, expected
            )
            var serialSeconds: [Double] = []
            var parallelSeconds: [Double] = []
            var fieldsEqual = true
            for iteration in 0..<repetitions {
                let order: [ASHTemporalMotionExecutionPolicyV4] =
                    iteration.isMultiple(of: 2) ? [.serial, policy] : [policy, .serial]
                for (index, execution) in order.enumerated() {
                    let started = DispatchTime.now().uptimeNanoseconds
                    let field = try ASHTemporalMotionAnalyzerV4.analyzeField(
                        current: current, previous: previous,
                        executionPolicy: execution
                    ).field
                    let seconds = Double(DispatchTime.now().uptimeNanoseconds - started)
                        / 1_000_000_000
                    let isSerial = iteration.isMultiple(of: 2) == (index == 0)
                    if isSerial { serialSeconds.append(seconds) }
                    else { parallelSeconds.append(seconds) }
                    fieldsEqual = fieldsEqual && field == expected
                    XCTAssertEqual(field, expected)
                }
            }
            records.append(Record(
                width: width, height: height,
                workerCount: try policy.workerCount(
                    rows: (height + 7) / 8,
                    blockCount: ((width + 7) / 8) * ((height + 7) / 8)
                ),
                fieldsEqual: fieldsEqual,
                serialSeconds: serialSeconds, parallelSeconds: parallelSeconds
            ))
        }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(
            at: output, withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(records)
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "motion-parallel-benchmark.json"
        attachment.lifetime = .keepAlways
        add(attachment)
        try data.write(
            to: output.appendingPathComponent("motion-parallel-benchmark.json"),
            options: .atomic
        )
    }

    func testThreeRowSpatialWorkspaceMatchesReferenceForEveryState() throws {
        let program = try ASHDepthFourBranchCompilerV4.compileCanonical()
        var workspace = ASHSpatialReconstructionWorkspaceV4()
        let geometries = [
            (1, 1), (2, 1), (1, 3), (2, 2), (3, 5), (8, 7), (17, 9)
        ]
        for (width, height) in geometries {
            let sampleCount = width * height
            var input: [UInt16] = []
            input.reserveCapacity(sampleCount)
            for index in 0..<sampleCount {
                let code = 64 + ((index * 97 + width * 31 + height * 17) % 877)
                input.append(UInt16(code))
            }
            let plane = try ASHTemporalPlaneV4(
                width: width,
                height: height,
                minimumCode: 64,
                maximumCode: 940,
                samples: input
            )
            for payload in 0..<256 {
                let state = try ASHState(payloadBits: (0..<8).map { bit in
                    (payload >> bit) & 1
                })
                let reference = try ASHSpatialReconstructorV4.reconstruct(
                    spatial: plane,
                    sourceState: state,
                    program: program
                )
                var optimized = input
                let controls = try ASHSpatialReconstructorV4.reconstructInPlace(
                    samples: &optimized,
                    width: width,
                    height: height,
                    minimumCode: 64,
                    maximumCode: 940,
                    sourceState: state,
                    program: program,
                    workspace: &workspace
                )
                XCTAssertEqual(optimized, reference.output.samples)
                XCTAssertEqual(
                    controls.targetMessageRawValue,
                    reference.targetMessageRawValue
                )
                XCTAssertEqual(controls.basisGainsQ16, reference.basisGainsQ16)
                XCTAssertEqual(controls.retainedRowSampleCount, width * 3)
            }
        }
        XCTAssertEqual(workspace.retainedSampleCapacity, 17 * 3)
        XCTAssertEqual(workspace.retainedByteUpperBound, 17 * 3 * 2)
        let stableIdentity = workspace.storageIdentity
        let stableAllocations = workspace.storageAllocationCount
        var small = [UInt16](repeating: 400, count: 6)
        _ = try ASHSpatialReconstructorV4.reconstructInPlace(
            samples: &small,
            width: 3,
            height: 2,
            minimumCode: 64,
            maximumCode: 940,
            sourceState: ASHState(rawValue: 0),
            program: program,
            workspace: &workspace
        )
        XCTAssertEqual(workspace.storageIdentity, stableIdentity)
        XCTAssertEqual(workspace.storageAllocationCount, stableAllocations)
    }

    func testInPlaceConditioningCancellationAndInvalidFieldNeverMutate()
        async throws {
        let program = try ASHDepthFourBranchCompilerV4.compileCanonical()
        let input = (0..<64).map { UInt16(64 + ($0 * 11) % 877) }
        let cancelled = await Task { () -> ([UInt16], Error?) in
            var samples = input
            var workspace = ASHSpatialReconstructionWorkspaceV4()
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try ASHSpatialReconstructorV4.reconstructInPlace(
                    samples: &samples,
                    width: 8,
                    height: 8,
                    minimumCode: 64,
                    maximumCode: 940,
                    sourceState: try ASHState(rawValue: 0),
                    program: program,
                    workspace: &workspace
                )
                return (samples, nil)
            } catch {
                return (samples, error)
            }
        }.value
        XCTAssertTrue(cancelled.1 is CancellationError)
        XCTAssertEqual(cancelled.0, input)

        let previous = try makeFrame(id: "bounds-0", ordinal: 0) { x, y in
            self.patternSample(x: x, y: y)
        }
        let current = try makeFrame(id: "bounds-1", ordinal: 1) { x, y in
            self.patternSample(x: x, y: y)
        }
        let valid = try ASHTemporalMotionAnalyzerV4.analyzeField(
            current: current,
            previous: previous
        ).field
        var forgedVectors = valid.vectors
        let original = forgedVectors[0]
        forgedVectors[0] = ASHTemporalMotionVectorV4(
            blockIndex: original.blockIndex,
            originX: original.originX,
            originY: original.originY,
            width: original.width,
            height: original.height,
            dx: -1,
            dy: original.dy,
            absoluteDifference: original.absoluteDifference,
            normalizedCostQ16: original.normalizedCostQ16,
            confidenceQ16: original.confidenceQ16,
            occluded: original.occluded
        )
        let forged = replacingVectors(in: valid, with: forgedVectors)
        var unchanged = current.luma.samples
        XCTAssertThrowsError(
            try ASHTemporalReconstructorV4.reconstructInPlace(
                samples: &unchanged,
                width: current.luma.width,
                height: current.luma.height,
                minimumCode: current.luma.minimumCode,
                maximumCode: current.luma.maximumCode,
                motionField: forged,
                previousHistory: previous,
                sourceState: ASHState(rawValue: 0),
                resetReason: nil,
                program: program
            )
        )
        XCTAssertEqual(unchanged, current.luma.samples)
    }

    func testCanonicalMaxIntegerAndLayoutTamperingFailWithoutTrap() throws {
        let oversizedVector = ASHTemporalMotionVectorV4(
            blockIndex: 0,
            originX: Int.max,
            originY: 0,
            width: Int.max,
            height: 8,
            dx: 0,
            dy: 0,
            absoluteDifference: 0,
            normalizedCostQ16: 0,
            confidenceQ16: 1,
            occluded: false
        )
        let oversizedField = ASHTemporalMotionFieldV4(
            policyID: "ash.test.max-int",
            currentFrameID: "current",
            previousFrameID: "previous",
            streamID: "video-main",
            formatIdentity: formatIdentity,
            planeWidth: 16,
            planeHeight: 16,
            minimumCode: 64,
            maximumCode: 940,
            sceneDifferenceQ16: 0,
            sceneCut: false,
            temporalEvidenceQ16: 0,
            blockColumns: 1,
            blockRows: 1,
            vectors: [oversizedVector]
        )
        let canonical = try ASHCanonicalJSONV4.encode(oversizedField)
        let decoded = try ASHCanonicalJSONV4.decode(
            ASHTemporalMotionFieldV4.self,
            from: canonical
        )
        XCTAssertThrowsError(try decoded.validate()) { error in
            XCTAssertEqual(error as? ASHTemporalV4Error, .invalidMotionField)
        }

        let previous = try makeFrame(id: "layout-0", ordinal: 0) { x, y in
            self.patternSample(x: x, y: y)
        }
        let current = try makeFrame(id: "layout-1", ordinal: 1) { x, y in
            self.patternSample(x: x, y: y)
        }
        let field = try ASHTemporalMotionAnalyzerV4.analyzeField(
            current: current,
            previous: previous
        ).field
        var overlapping = field.vectors
        let second = overlapping[1]
        overlapping[1] = ASHTemporalMotionVectorV4(
            blockIndex: second.blockIndex,
            originX: 0,
            originY: second.originY,
            width: second.width,
            height: second.height,
            dx: second.dx,
            dy: second.dy,
            absoluteDifference: second.absoluteDifference,
            normalizedCostQ16: second.normalizedCostQ16,
            confidenceQ16: second.confidenceQ16,
            occluded: second.occluded
        )
        XCTAssertThrowsError(
            try replacingVectors(in: field, with: overlapping).validate()
        ) { error in
            XCTAssertEqual(error as? ASHTemporalV4Error, .invalidMotionField)
        }
    }

    func testCanonicalCheckpointRejectsDeepPlaneAndProgressTampering()
        throws {
        let frame = try makeFrame(id: "deep-0", ordinal: 0) { x, y in
            self.patternSample(x: x, y: y)
        }
        var history = try ASHTemporalHistoryV4(capacity: 1)
        try history.append(frame)
        let checkpoint = try ASHTemporalCheckpointV4(
            planSHA256: planIdentity,
            runtimeManifestSHA256: runtimeIdentity,
            lastCompletedInputOrdinal: 0,
            lastCompletedOutputPresentationTime: .zero,
            history: history
        )
        let canonical = try checkpoint.canonicalData
        let sampleList = frame.luma.samples.map(String.init).joined(separator: ",")
        let sampleNeedle = "\"samples\":[\(sampleList)]"
        let shortened = try replacingUTF8(
            sampleNeedle,
            with: "\"samples\":[\(frame.luma.samples[0])]",
            in: canonical
        )
        XCTAssertThrowsError(try ASHTemporalCheckpointV4.decodeCanonical(
            shortened,
            expectedPlanSHA256: planIdentity,
            expectedRuntimeManifestSHA256: runtimeIdentity
        )) { error in
            XCTAssertEqual(error as? ASHTemporalV4Error, .invalidHistory)
        }

        var outOfRangeSamples = frame.luma.samples
        outOfRangeSamples[outOfRangeSamples.count - 1] = 941
        let outOfRangeList = outOfRangeSamples.map(String.init)
            .joined(separator: ",")
        let outOfRange = try replacingUTF8(
            sampleNeedle,
            with: "\"samples\":[\(outOfRangeList)]",
            in: canonical
        )
        XCTAssertThrowsError(try ASHTemporalCheckpointV4.decodeCanonical(
            outOfRange,
            expectedPlanSHA256: planIdentity,
            expectedRuntimeManifestSHA256: runtimeIdentity
        )) { error in
            XCTAssertEqual(error as? ASHTemporalV4Error, .invalidHistory)
        }

        let advancedProgress = try replacingUTF8(
            "\"lastCompletedInputOrdinal\":0",
            with: "\"lastCompletedInputOrdinal\":1",
            in: canonical
        )
        XCTAssertThrowsError(try ASHTemporalCheckpointV4.decodeCanonical(
            advancedProgress,
            expectedPlanSHA256: planIdentity,
            expectedRuntimeManifestSHA256: runtimeIdentity
        )) { error in
            XCTAssertEqual(error as? ASHTemporalV4Error, .invalidHistory)
        }
    }

    func testTypedContinuityContractDistinguishesEveryResetBoundary()
        throws {
        let previous = try makeContinuity(frameOrdinal: 0)

        func primary(
            _ current: ASHTemporalContinuityDescriptorV4
        ) throws -> ASHTemporalResetReasonV4? {
            try ASHTemporalContinuityEvaluatorV4.evaluate(
                previous: previous,
                current: current
            ).primaryReason
        }

        XCTAssertEqual(
            try ASHTemporalContinuityEvaluatorV4.evaluate(
                previous: nil,
                current: previous
            ).reasons,
            [.streamStart]
        )
        XCTAssertNil(try primary(makeContinuity(frameOrdinal: 1)))
        XCTAssertEqual(
            try primary(makeContinuity(
                frameOrdinal: 1,
                presentationTime: try ExactRationalV4(2, 30)
            )),
            .presentationTimeDiscontinuity
        )
        XCTAssertEqual(
            try primary(makeContinuity(frameOrdinal: 2)),
            .seek
        )
        XCTAssertEqual(
            try primary(makeContinuity(
                frameOrdinal: 1,
                edit: identity("d")
            )),
            .editBoundary
        )
        XCTAssertEqual(
            try primary(makeContinuity(
                frameOrdinal: 1,
                geometry: identity("e")
            )),
            .geometryChange
        )
        XCTAssertEqual(
            try primary(makeContinuity(
                frameOrdinal: 1,
                pixelFormat: identity("f")
            )),
            .pixelFormatChange
        )
        XCTAssertEqual(
            try primary(makeContinuity(
                frameOrdinal: 1,
                format: identity("1")
            )),
            .formatChange
        )
        XCTAssertEqual(
            try primary(makeContinuity(
                frameOrdinal: 1,
                color: identity("2")
            )),
            .colorDomainChange
        )
        XCTAssertEqual(
            try primary(makeContinuity(
                frameOrdinal: 1,
                hdr: identity("3")
            )),
            .hdrMetadataChange
        )
        XCTAssertEqual(
            try primary(makeContinuity(
                frameOrdinal: 1,
                cadence: identity("4")
            )),
            .fieldCadenceChange
        )
        XCTAssertEqual(
            try primary(makeContinuity(
                frameOrdinal: 1,
                contract: identity("5")
            )),
            .contractChange
        )
        XCTAssertEqual(
            try primary(makeContinuity(
                frameOrdinal: 1,
                declaredReset: .explicitReset
            )),
            .explicitReset
        )
        let simultaneous = try ASHTemporalContinuityEvaluatorV4.evaluate(
            previous: previous,
            current: makeContinuity(
                frameOrdinal: 1,
                edit: identity("d"),
                color: identity("2"),
                hdr: identity("3")
            )
        )
        XCTAssertEqual(
            simultaneous.reasons,
            [.editBoundary, .colorDomainChange, .hdrMetadataChange]
        )
        XCTAssertEqual(
            ASHTemporalResetReasonV4.presentationTimeDiscontinuity
                .measurementTrigger,
            .discontinuity
        )
        XCTAssertEqual(
            ASHTemporalResetReasonV4.hdrMetadataChange.measurementTrigger,
            .colorDomainChange
        )
    }

    func testCanonical8KCaptureUsesOnlyBoundedTileAllocations() throws {
        let capture = try ASHTemporalTiledFrameBuilderV4.capture(
            frameID: "8k-frame-0",
            streamID: "primary-video",
            formatIdentity: formatIdentity,
            ordinal: 0,
            presentationTime: .zero,
            cadenceID: "progressive",
            frameWidth: 8_192,
            frameHeight: 4_320,
            minimumCode: 64,
            maximumCode: 940,
            stateForTile: { _ in try ASHState(rawValue: 0) },
            sampleAt: { x, y in
                UInt16(64 + ((x * 13 + y * 17) % 877))
            }
        )
        let diagnostics = capture.allocationDiagnostics
        XCTAssertEqual(diagnostics.fullFrameSampleCount, 8_192 * 4_320)
        XCTAssertGreaterThan(
            diagnostics.fullFrameSampleCount,
            ASHTemporalPlaneV4.maximumSampleCount
        )
        XCTAssertEqual(diagnostics.tileCount, 32 * 17)
        XCTAssertEqual(diagnostics.fullFrameSampleArrayAllocationCount, 0)
        XCTAssertLessThanOrEqual(
            diagnostics.largestContiguousSampleAllocation,
            ASHTemporalTilePolicyV4.canonical
                .maximumRetainedTileSampleCount
        )
        XCTAssertTrue(capture.frame.tiles.allSatisfy {
            $0.retainedSamples.count
                <= ASHTemporalTilePolicyV4.canonical
                    .maximumRetainedTileSampleCount
        })
    }

    func testTiledMotionAndReconstructionAreScheduleAndExecutorIdentical()
        throws {
        let previous = try makeTiledFrame(
            id: "tile-0",
            ordinal: 0
        ) { x, y in
            self.tiledPatternSample(x: x, y: y)
        }
        let current = try makeTiledFrame(
            id: "tile-1",
            ordinal: 1
        ) { x, y in
            self.tiledPatternSample(x: min(x + 2, 31), y: y)
        }
        let motion = try ASHTemporalTiledMotionAnalyzerV4.analyze(
            current: current,
            previous: previous
        )
        XCTAssertFalse(motion.field.sceneCut)
        XCTAssertEqual(
            motion.field.tileStates[0].vectors[0].dx,
            2
        )
        XCTAssertEqual(
            motion.allocationDiagnostics
                .fullFrameMotionVectorArrayAllocationCount,
            0
        )
        XCTAssertEqual(
            motion.allocationDiagnostics.materializedAlignedSampleCount,
            0
        )
        let program = try ASHDepthFourBranchCompilerV4.compileCanonical()
        let cpu = try ASHTemporalTiledReconstructorV4.reconstruct(
            currentSpatial: current,
            previousHistory: previous,
            motionField: motion.field,
            resetReason: nil,
            program: program,
            executor: .cpuFixedPoint,
            schedule: .raster
        )
        let metal = try ASHTemporalTiledReconstructorV4.reconstruct(
            currentSpatial: current,
            previousHistory: previous,
            motionField: motion.field,
            resetReason: nil,
            program: program,
            executor: .metalFixedPoint,
            schedule: .reverseRaster
        )
        let interleaved = try ASHTemporalTiledReconstructorV4.reconstruct(
            currentSpatial: current,
            previousHistory: previous,
            motionField: motion.field,
            resetReason: nil,
            program: program,
            executor: .metalFixedPoint,
            schedule: .evenThenOdd
        )
        XCTAssertEqual(cpu.tiles, metal.tiles)
        XCTAssertEqual(cpu.tiles, interleaved.tiles)
        XCTAssertEqual(
            cpu.diagnostics.fullFrameSampleArrayAllocationCount,
            0
        )
        XCTAssertEqual(cpu.diagnostics.materializedAlignedSampleCount, 0)
        XCTAssertTrue(cpu.tiles.contains { $0.historyWeightQ16 > 0 })
        let currentActive = try current.tiles.map { try $0.activeSamples() }
        XCTAssertNotEqual(cpu.tiles.map(\.samples), currentActive)

        for reason in [
            ASHTemporalResetReasonV4.presentationTimeDiscontinuity,
            .seek, .editBoundary, .formatChange, .colorDomainChange,
            .hdrMetadataChange
        ] {
            let reset = try ASHTemporalTiledReconstructorV4.reconstruct(
                currentSpatial: current,
                previousHistory: previous,
                motionField: motion.field,
                resetReason: reason,
                program: program,
                executor: .cpuFixedPoint,
                schedule: .evenThenOdd
            )
            XCTAssertEqual(reset.tiles.map(\.samples), currentActive)
            XCTAssertTrue(reset.tiles.allSatisfy {
                $0.historyWeightQ16 == 0
            })
        }
    }

    func testParallelTiledMotionMatchesIndependentOracleAndSerialPixels()
        throws {
        let program = try ASHDepthFourBranchCompilerV4.compileCanonical()
        for (width, height) in [(53, 101), (129, 135), (3, 5)] {
            let previous = try makeTiledFrame(
                id: "parallel-tile-0", ordinal: 0, width: width, height: height
            ) { x, y in self.patternSample(x: x, y: y) }
            let current = try makeTiledFrame(
                id: "parallel-tile-1", ordinal: 1, width: width, height: height
            ) { x, y in
                self.patternSample(x: (x + 2) % width, y: (y + 1) % height)
            }
            let fullPrevious = try makeFrame(
                id: previous.frameID, ordinal: 0, width: width, height: height
            ) { x, y in self.patternSample(x: x, y: y) }
            let fullCurrent = try makeFrame(
                id: current.frameID, ordinal: 1, width: width, height: height
            ) { x, y in
                self.patternSample(x: (x + 2) % width, y: (y + 1) % height)
            }
            let oracle = try sortedMotionOracle(current: fullCurrent, previous: fullPrevious)
            XCTAssertFalse(oracle.sceneCut)
            let serial = try ASHTemporalTiledMotionAnalyzerV4.analyze(
                current: current, previous: previous, executionPolicy: .serial
            )
            XCTAssertEqual(serial.field.sceneDifferenceQ16, oracle.sceneDifferenceQ16)
            XCTAssertEqual(serial.field.temporalEvidenceQ16, oracle.temporalEvidenceQ16)
            for state in serial.field.tileStates {
                let active = try current.grid.descriptor(at: state.tileIndex).active
                var expected: [ASHTemporalMotionVectorV4] = []
                for vector in oracle.vectors where active.contains(x: vector.originX, y: vector.originY) {
                    expected.append(ASHTemporalMotionVectorV4(
                        blockIndex: expected.count,
                        originX: vector.originX, originY: vector.originY,
                        width: vector.width, height: vector.height,
                        dx: vector.dx, dy: vector.dy,
                        absoluteDifference: vector.absoluteDifference,
                        normalizedCostQ16: vector.normalizedCostQ16,
                        confidenceQ16: vector.confidenceQ16, occluded: vector.occluded
                    ))
                }
                XCTAssertEqual(state.vectors, expected)
                let weighted = expected.reduce(UInt64(0)) {
                    $0 + UInt64($1.normalizedCostQ16) * UInt64($1.width * $1.height)
                }
                XCTAssertEqual(state.temporalEvidenceQ16, UInt32(oracleRoundedRatio(
                    weighted, UInt64(active.sampleCount)
                )))
            }
            let expectedPixels = try ASHTemporalTiledReconstructorV4.reconstruct(
                currentSpatial: current, previousHistory: previous,
                motionField: serial.field, resetReason: nil, program: program,
                executor: .cpuFixedPoint, schedule: .raster
            ).tiles
            if width > 3 {
                XCTAssertTrue(expectedPixels.contains { $0.historyWeightQ16 > 0 })
            }
            for policy in [ASHTemporalMotionExecutionPolicyV4.automatic,
                           .parallel(maximumWorkers: 2),
                           .parallel(maximumWorkers: 3),
                           .parallel(maximumWorkers: 7),
                           .parallel(maximumWorkers: Int.max)] {
                let parallel = try ASHTemporalTiledMotionAnalyzerV4.analyze(
                    current: current, previous: previous, executionPolicy: policy
                )
                XCTAssertEqual(parallel.field, serial.field)
                XCTAssertEqual(parallel.allocationDiagnostics, serial.allocationDiagnostics)
                XCTAssertEqual(parallel.allocationDiagnostics.fullFrameMotionVectorArrayAllocationCount, 0)
                XCTAssertEqual(parallel.allocationDiagnostics.materializedAlignedSampleCount, 0)
                XCTAssertLessThanOrEqual(parallel.allocationDiagnostics.largestContiguousMotionVectorAllocation, 4)
                let actualPixels = try ASHTemporalTiledReconstructorV4.reconstruct(
                    currentSpatial: current, previousHistory: previous,
                    motionField: parallel.field, resetReason: nil, program: program,
                    executor: .metalFixedPoint, schedule: .reverseRaster
                ).tiles
                XCTAssertEqual(actualPixels, expectedPixels)
            }
        }
    }

    func testParallelTiledMotionPreservesSceneCutAndRejectsInvalidWorkers()
        throws {
        let previous = try makeTiledFrame(id: "dark-tile", ordinal: 0) { _, _ in 64 }
        let current = try makeTiledFrame(id: "light-tile", ordinal: 1) { _, _ in 940 }
        let serial = try ASHTemporalTiledMotionAnalyzerV4.analyze(
            current: current, previous: previous, executionPolicy: .serial
        )
        let parallel = try ASHTemporalTiledMotionAnalyzerV4.analyze(
            current: current, previous: previous, executionPolicy: .parallel(maximumWorkers: 7)
        )
        XCTAssertEqual(parallel, serial)
        XCTAssertTrue(parallel.field.sceneCut)
        XCTAssertTrue(parallel.field.tileStates.allSatisfy { $0.sceneCut && $0.vectors.isEmpty })
        for workers in [0, -1] {
            XCTAssertThrowsError(try ASHTemporalTiledMotionAnalyzerV4.analyze(
                current: current, previous: previous, executionPolicy: .parallel(maximumWorkers: workers)
            )) { error in
                XCTAssertEqual(error as? ASHTemporalV4Error, .invalidConfiguration)
            }
        }
    }

    func testCancelledInitiatingTaskCannotPublishFullOrTiledMotion() async throws {
        let previous = try makeFrame(id: "cancel-full-0", ordinal: 0) { _, _ in 400 }
        let current = try makeFrame(id: "cancel-full-1", ordinal: 1) { _, _ in 401 }
        let tiledPrevious = try makeTiledFrame(id: "cancel-tile-0", ordinal: 0) { _, _ in 400 }
        let tiledCurrent = try makeTiledFrame(id: "cancel-tile-1", ordinal: 1) { _, _ in 401 }
        for tiled in [false, true] {
            let operation = Task.detached {
                withUnsafeCurrentTask { $0?.cancel() }
                if tiled {
                    _ = try ASHTemporalTiledMotionAnalyzerV4.analyze(
                        current: tiledCurrent, previous: tiledPrevious,
                        executionPolicy: .parallel(maximumWorkers: 7)
                    )
                } else {
                    _ = try ASHTemporalMotionAnalyzerV4.analyzeField(
                        current: current, previous: previous,
                        executionPolicy: .parallel(maximumWorkers: 7)
                    )
                }
            }
            do {
                try await operation.value
                XCTFail("A cancelled initiating task published motion.")
            } catch {
                XCTAssertTrue(error is CancellationError)
            }
        }
    }

    func testTiledHistoryCheckpointRoundTripRestoresMotionAndPixels()
        throws {
        let previous = try makeTiledFrame(
            id: "resume-tile-0",
            ordinal: 0
        ) { x, y in
            self.tiledPatternSample(x: x, y: y)
        }
        let current = try makeTiledFrame(
            id: "resume-tile-1",
            ordinal: 1
        ) { x, y in
            self.tiledPatternSample(x: min(x + 1, 31), y: y)
        }
        let motion = try ASHTemporalTiledMotionAnalyzerV4.analyze(
            current: current,
            previous: previous
        ).field
        var history = try ASHTemporalTiledHistoryV4(capacity: 2)
        try history.append(previous, motionFromPrevious: nil)
        try history.append(current, motionFromPrevious: motion)
        let checkpoint = try ASHTemporalTiledCheckpointV4(
            planSHA256: planIdentity,
            runtimeManifestSHA256: runtimeIdentity,
            lastCompletedInputOrdinal: 1,
            lastCompletedOutputPresentationTime: try ExactRationalV4(1, 30),
            history: history
        )
        let data = try checkpoint.canonicalData
        let decoded = try ASHTemporalTiledCheckpointV4.decodeCanonical(
            data,
            expectedPlanSHA256: planIdentity,
            expectedRuntimeManifestSHA256: runtimeIdentity
        )
        XCTAssertEqual(decoded, checkpoint)
        let restoredPrevious = try XCTUnwrap(
            decoded.history.entries.first?.frame
        )
        let restoredCurrent = try XCTUnwrap(
            decoded.history.entries.last?.frame
        )
        let restoredMotion = try XCTUnwrap(
            decoded.history.entries.last?.motionFromPrevious
        )
        let program = try ASHDepthFourBranchCompilerV4.compileCanonical()
        XCTAssertEqual(
            try ASHTemporalTiledReconstructorV4.reconstruct(
                currentSpatial: restoredCurrent,
                previousHistory: restoredPrevious,
                motionField: restoredMotion,
                resetReason: nil,
                program: program,
                executor: .cpuFixedPoint
            ).tiles,
            try ASHTemporalTiledReconstructorV4.reconstruct(
                currentSpatial: current,
                previousHistory: previous,
                motionField: motion,
                resetReason: nil,
                program: program,
                executor: .metalFixedPoint,
                schedule: .reverseRaster
            ).tiles
        )
        var nonCanonical = data
        nonCanonical.append(0x0a)
        XCTAssertThrowsError(try ASHTemporalTiledCheckpointV4.decodeCanonical(
            nonCanonical,
            expectedPlanSHA256: planIdentity,
            expectedRuntimeManifestSHA256: runtimeIdentity
        )) { error in
            XCTAssertEqual(
                error as? ASHTemporalV4Error,
                .nonCanonicalCheckpoint
            )
        }
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

    // A separate serial implementation materializes and sorts all candidates,
    // rather than sharing the production best-two selection or batching code.
    private func sortedMotionOracle(
        current: ASHTemporalFrameV4,
        previous: ASHTemporalFrameV4,
        configuration: ASHTemporalBlockMatchingConfigurationV4 = .canonical
    ) throws -> ASHTemporalMotionFieldV4 {
        try current.validate()
        try previous.validate()
        let plane = current.luma
        let prior = previous.luma
        guard plane.width == prior.width, plane.height == prior.height,
              plane.minimumCode == prior.minimumCode,
              plane.maximumCode == prior.maximumCode else {
            throw ASHTemporalV4Error.planeGeometryMismatch
        }
        let codeCount = UInt64(plane.maximumCode - plane.minimumCode) + 1
        var currentHistogram = [UInt64](repeating: 0, count: 16)
        var previousHistogram = [UInt64](repeating: 0, count: 16)
        for (currentSample, previousSample) in zip(plane.samples, prior.samples) {
            currentHistogram[Int(UInt64(currentSample - plane.minimumCode)
                * 16 / codeCount)] += 1
            previousHistogram[Int(UInt64(previousSample - prior.minimumCode)
                * 16 / codeCount)] += 1
        }
        let histogramDistance = zip(currentHistogram, previousHistogram)
            .reduce(UInt64(0)) { sum, bins in
                sum + UInt64(abs(Int64(bins.0) - Int64(bins.1)))
            }
        let sceneDifference = UInt32(oracleRoundedRatio(
            histogramDistance * UInt64(ASHNormalizedQ16V4.scale),
            UInt64(plane.samples.count * 2)
        ))
        let sceneCut = sceneDifference
            >= configuration.sceneCutHistogramThresholdQ16
        var vectors: [ASHTemporalMotionVectorV4] = []
        if !sceneCut {
            for originY in stride(
                from: 0, to: plane.height, by: configuration.blockHeight
            ) {
                for originX in stride(
                    from: 0, to: plane.width, by: configuration.blockWidth
                ) {
                    let width = min(configuration.blockWidth, plane.width - originX)
                    let height = min(configuration.blockHeight, plane.height - originY)
                    var candidates: [(cost: UInt64, dx: Int, dy: Int)] = []
                    for dy in -configuration.searchRadius...configuration.searchRadius {
                        for dx in -configuration.searchRadius...configuration.searchRadius {
                            guard originX + dx >= 0, originY + dy >= 0,
                                  originX + dx + width <= plane.width,
                                  originY + dy + height <= plane.height else { continue }
                            let cost = (0..<height).reduce(UInt64(0)) { rowSum, y in
                                rowSum + (0..<width).reduce(UInt64(0)) { sum, x in
                                    let currentSample = plane.samples[
                                        (originY + y) * plane.width + originX + x
                                    ]
                                    let previousSample = prior.samples[
                                        (originY + y + dy) * prior.width + originX + x + dx
                                    ]
                                    return sum + UInt64(abs(Int(currentSample) - Int(previousSample)))
                                }
                            }
                            candidates.append((cost, dx, dy))
                        }
                    }
                    candidates.sort {
                        if $0.cost != $1.cost { return $0.cost < $1.cost }
                        let lhsDistance = abs($0.dx) + abs($0.dy)
                        let rhsDistance = abs($1.dx) + abs($1.dy)
                        if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
                        if $0.dy != $1.dy { return $0.dy < $1.dy }
                        return $0.dx < $1.dx
                    }
                    guard let best = candidates.first else {
                        throw ASHTemporalV4Error.invalidMotionField
                    }
                    let second = candidates.count > 1 ? candidates[1] : best
                    let costQ16 = UInt32(oracleRoundedRatio(
                        best.cost * UInt64(ASHNormalizedQ16V4.scale),
                        UInt64(width * height)
                            * UInt64(plane.maximumCode - plane.minimumCode)
                    ))
                    let confidenceQ16 = second.cost > best.cost
                        ? UInt32(oracleRoundedRatio(
                            (second.cost - best.cost) * UInt64(ASHNormalizedQ16V4.scale),
                            second.cost
                        )) : 0
                    vectors.append(ASHTemporalMotionVectorV4(
                        blockIndex: vectors.count,
                        originX: originX, originY: originY,
                        width: width, height: height,
                        dx: Int16(best.dx), dy: Int16(best.dy),
                        absoluteDifference: best.cost,
                        normalizedCostQ16: costQ16,
                        confidenceQ16: confidenceQ16,
                        occluded: costQ16 > configuration.occlusionCostThresholdQ16
                            || confidenceQ16 < configuration.minimumConfidenceQ16
                    ))
                }
            }
        }
        let weightedEvidence = vectors.reduce(UInt64(0)) { sum, vector in
            sum + UInt64(vector.normalizedCostQ16)
                * UInt64(vector.width * vector.height)
        }
        let field = ASHTemporalMotionFieldV4(
            policyID: configuration.policyID,
            currentFrameID: current.frameID,
            previousFrameID: previous.frameID,
            streamID: current.streamID,
            formatIdentity: current.formatIdentity,
            planeWidth: plane.width, planeHeight: plane.height,
            minimumCode: plane.minimumCode, maximumCode: plane.maximumCode,
            sceneDifferenceQ16: sceneDifference, sceneCut: sceneCut,
            temporalEvidenceQ16: sceneCut ? sceneDifference : UInt32(oracleRoundedRatio(
                weightedEvidence, UInt64(plane.samples.count)
            )),
            blockColumns: (plane.width + configuration.blockWidth - 1)
                / configuration.blockWidth,
            blockRows: (plane.height + configuration.blockHeight - 1)
                / configuration.blockHeight,
            vectors: vectors
        )
        try field.validate()
        return field
    }

    private func oracleRoundedRatio(_ numerator: UInt64, _ denominator: UInt64)
        -> UInt64 {
        let quotient = numerator / denominator
        let twiceRemainder = (numerator % denominator) * 2
        let roundsUp = twiceRemainder > denominator
            || (twiceRemainder == denominator && !quotient.isMultiple(of: 2))
        return quotient + (roundsUp ? 1 : 0)
    }

    private func makeFrame(
        id: String,
        stream: String = "video-main",
        ordinal: Int64,
        width: Int = 16,
        height: Int = 16,
        generator: (Int, Int) -> UInt16
    ) throws -> ASHTemporalFrameV4 {
        let samples = (0..<height).flatMap { y in
            (0..<width).map { x in generator(x, y) }
        }
        return try ASHTemporalFrameV4(
            frameID: id,
            streamID: stream,
            formatIdentity: formatIdentity,
            ordinal: ordinal,
            presentationTime: try ExactRationalV4(ordinal, 30),
            luma: ASHTemporalPlaneV4(
                width: width,
                height: height,
                minimumCode: 64,
                maximumCode: 940,
                samples: samples
            ),
            tileStateRawValues: [],
            cadenceID: "progressive"
        )
    }

    private func identity(_ character: Character) -> ASHSHA256V4 {
        try! ASHSHA256V4(
            String(repeating: String(character), count: 64)
        )
    }

    private func makeContinuity(
        frameOrdinal: Int64,
        presentationTime: ExactRationalV4? = nil,
        edit: ASHSHA256V4? = nil,
        format: ASHSHA256V4? = nil,
        geometry: ASHSHA256V4? = nil,
        pixelFormat: ASHSHA256V4? = nil,
        color: ASHSHA256V4? = nil,
        hdr: ASHSHA256V4? = nil,
        cadence: ASHSHA256V4? = nil,
        contract: ASHSHA256V4? = nil,
        declaredReset: ASHTemporalResetReasonV4? = nil
    ) throws -> ASHTemporalContinuityDescriptorV4 {
        try ASHTemporalContinuityDescriptorV4(
            frameOrdinal: frameOrdinal,
            presentationTime: presentationTime
                ?? ExactRationalV4(frameOrdinal, 30),
            duration: ExactRationalV4(1, 30),
            editIdentity: edit ?? identity("6"),
            formatIdentity: format ?? identity("7"),
            geometryIdentity: geometry ?? identity("8"),
            pixelFormatIdentity: pixelFormat ?? identity("9"),
            colorIdentity: color ?? identity("a"),
            hdrMetadataIdentity: hdr,
            cadenceIdentity: cadence ?? identity("b"),
            contractIdentity: contract ?? identity("c"),
            declaredReset: declaredReset
        )
    }

    private func makeTiledFrame(
        id: String,
        ordinal: Int64,
        width: Int = 32,
        height: Int = 16,
        generator: (Int, Int) -> UInt16
    ) throws -> ASHTemporalTiledFrameV4 {
        let policy = try ASHTemporalTilePolicyV4(
            policyID: "ash.test.tiles.16x16-halo4",
            tileWidth: 16,
            tileHeight: 16,
            searchHalo: 4,
            maximumFrameWidth: max(width, 64),
            maximumFrameHeight: max(height, 32)
        )
        return try ASHTemporalTiledFrameBuilderV4.capture(
            frameID: id,
            streamID: "video-main",
            formatIdentity: formatIdentity,
            ordinal: ordinal,
            presentationTime: ExactRationalV4(ordinal, 30),
            cadenceID: "progressive",
            frameWidth: width,
            frameHeight: height,
            minimumCode: 64,
            maximumCode: 940,
            policy: policy,
            stateForTile: { index in
                try ASHState(payloadBits: (0..<8).map { bit in
                    (index >> bit) & 1
                })
            },
            sampleAt: generator
        ).frame
    }

    private func tiledPatternSample(x: Int, y: Int) -> UInt16 {
        UInt16(64 + ((x * 71 + y * 43 + x * y * 5) % 877))
    }

    private func replacingVectors(
        in field: ASHTemporalMotionFieldV4,
        with vectors: [ASHTemporalMotionVectorV4]
    ) -> ASHTemporalMotionFieldV4 {
        ASHTemporalMotionFieldV4(
            policyID: field.policyID,
            currentFrameID: field.currentFrameID,
            previousFrameID: field.previousFrameID,
            streamID: field.streamID,
            formatIdentity: field.formatIdentity,
            planeWidth: field.planeWidth,
            planeHeight: field.planeHeight,
            minimumCode: field.minimumCode,
            maximumCode: field.maximumCode,
            sceneDifferenceQ16: field.sceneDifferenceQ16,
            sceneCut: field.sceneCut,
            temporalEvidenceQ16: field.temporalEvidenceQ16,
            blockColumns: field.blockColumns,
            blockRows: field.blockRows,
            vectors: vectors
        )
    }

    private func replacingUTF8(
        _ needle: String,
        with replacement: String,
        in data: Data
    ) throws -> Data {
        guard let text = String(data: data, encoding: .utf8),
              let range = text.range(of: needle) else {
            throw ASHTemporalV4Error.invalidHistory
        }
        return Data(text.replacingCharacters(
            in: range,
            with: replacement
        ).utf8)
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
