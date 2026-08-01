import CoreVideo
import XCTest
@testable import Mirmir

final class R13FullFrameEnhancementProcessorTests: XCTestCase {
    private let resolution = VideoResolution(width: 12, height: 8)

    func testEdgeAndDetailSettingsMateriallyChangeFullFrameOutput()
        throws {
        let input = try makeBuffer { row, column in
            let texture = ((row * 17 + column * 29) % 7) * 6
            let edge = column >= 6 ? 56 : 0
            return UInt8(72 + texture + edge)
        }

        let lowEdge = try processor(
            temporal: false,
            edge: .low,
            detail: .low
        ).process(input)
        let highEdge = try processor(
            temporal: false,
            edge: .high,
            detail: .low
        ).process(input)
        let lowDetail = try processor(
            temporal: false,
            edge: .low,
            detail: .low
        ).process(input)
        let highDetail = try processor(
            temporal: false,
            edge: .low,
            detail: .high
        ).process(input)

        XCTAssertNotEqual(luma(lowEdge), luma(highEdge))
        XCTAssertNotEqual(luma(lowDetail), luma(highDetail))
        XCTAssertEqual(chroma(lowEdge), chroma(input))
        XCTAssertEqual(
            CVPixelBufferGetPixelFormatType(lowEdge),
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
        XCTAssertEqual(
            CVPixelBufferGetWidth(lowEdge),
            resolution.width
        )
        XCTAssertEqual(
            CVPixelBufferGetHeight(lowEdge),
            resolution.height
        )
        XCTAssertFalse(lowEdge === input)
        assertColorAttachmentsPreserved(from: input, to: lowEdge)
    }

    func testTemporalStabilizationChangesOnlyLowMotionRegion()
        throws {
        let first = try makeBuffer { row, column in
            UInt8(80 + ((row + column) % 2) * 4)
        }
        let second = try makeBuffer { row, column in
            let base = 80 + ((row + column) % 2) * 4
            return UInt8(base + (column < 6 ? 4 : 60))
        }
        let temporal = try processor(
            temporal: true,
            edge: .low,
            detail: .low
        )
        let spatialOnly = try processor(
            temporal: false,
            edge: .low,
            detail: .low
        )

        _ = try temporal.process(first)
        let stabilized = try temporal.process(second)
        let unstabilized = try spatialOnly.process(second)
        let stabilizedLuma = luma(stabilized)
        let unstabilizedLuma = luma(unstabilized)
        var changedLowMotionSampleCount = 0

        for row in 0..<resolution.height {
            for column in 0..<resolution.width {
                let index = row * resolution.width + column
                if column < 6 {
                    if stabilizedLuma[index] != unstabilizedLuma[index] {
                        changedLowMotionSampleCount += 1
                    }
                } else {
                    XCTAssertEqual(
                        stabilizedLuma[index],
                        unstabilizedLuma[index],
                        "High-motion sample changed at \(row),\(column)"
                    )
                }
            }
        }
        XCTAssertGreaterThan(changedLowMotionSampleCount, 0)
    }

    func testSceneTransitionDoesNotGhostPriorFrame() throws {
        let dark = try makeBuffer { _, _ in 32 }
        let bright = try makeBuffer { _, _ in 220 }
        let temporal = try processor(
            temporal: true,
            edge: .high,
            detail: .high
        )
        let spatialOnly = try processor(
            temporal: false,
            edge: .high,
            detail: .high
        )

        _ = try temporal.process(dark)
        let transitioned = try temporal.process(bright)
        let expected = try spatialOnly.process(bright)

        XCTAssertEqual(logicalBytes(transitioned), logicalBytes(expected))
        XCTAssertTrue(luma(transitioned).allSatisfy { $0 == 220 })
    }

    func testIdenticalConfigurationAndSequenceAreRepeatable() throws {
        let firstFrame = try makeBuffer { row, column in
            UInt8(64 + ((row * 11 + column * 7) % 80))
        }
        let secondFrame = try makeBuffer { row, column in
            UInt8(66 + ((row * 11 + column * 7) % 80))
        }
        let thirdFrame = try makeBuffer { row, column in
            UInt8(67 + ((row * 13 + column * 5) % 80))
        }
        let frames = [firstFrame, secondFrame, thirdFrame]
        let first = try processor(
            temporal: true,
            edge: .medium,
            detail: .high
        )
        let second = try processor(
            temporal: true,
            edge: .medium,
            detail: .high
        )

        let firstOutputs = try frames.map {
            logicalBytes(try first.process($0))
        }
        let secondOutputs = try frames.map {
            logicalBytes(try second.process($0))
        }

        XCTAssertEqual(firstOutputs, secondOutputs)
    }

    func testDisabledProductEffectsPreserveLegacyOutput() throws {
        let input = try makeBuffer { row, column in
            UInt8(70 + ((row * 13 + column * 19) % 72))
        }
        let implicitDisabled = try processor(
            temporal: false,
            edge: .high,
            detail: .high
        )
        let explicitDisabled = try processor(
            temporal: false,
            edge: .high,
            detail: .high,
            edgePreservation: false,
            compressionCleanup: false,
            textureProtection: false,
            temporalStability: false
        )

        XCTAssertEqual(
            logicalBytes(try implicitDisabled.process(input)),
            logicalBytes(try explicitDisabled.process(input))
        )
    }

    func testEdgePreservationLimitsHaloAtStrongSourceEdge() throws {
        let input = try makeBuffer { _, column in
            column < 6 ? 64 : 192
        }
        let baseline = try processor(
            temporal: false,
            edge: .high,
            detail: .high,
            compressionCleanup: true,
            textureProtection: true
        )
        let preserving = try processor(
            temporal: false,
            edge: .high,
            detail: .high,
            edgePreservation: true,
            compressionCleanup: true,
            textureProtection: true
        )

        let baselineLuma = luma(try baseline.process(input))
        let preservingLuma = luma(try preserving.process(input))
        let leftIndex = 4 * resolution.width + 5
        let rightIndex = leftIndex + 1
        let sourceContrast = 192 - 64
        let baselineContrast =
            Int(baselineLuma[rightIndex])
                - Int(baselineLuma[leftIndex])
        let preservingContrast =
            Int(preservingLuma[rightIndex])
                - Int(preservingLuma[leftIndex])

        XCTAssertNotEqual(baselineLuma, preservingLuma)
        XCTAssertLessThan(
            abs(preservingContrast - sourceContrast),
            abs(baselineContrast - sourceContrast)
        )
        XCTAssertLessThanOrEqual(
            abs(Int(preservingLuma[leftIndex]) - 64),
            2
        )
        XCTAssertLessThanOrEqual(
            abs(Int(preservingLuma[rightIndex]) - 192),
            2
        )
    }

    func testCompressionCleanupDeblocksFlatRegionsWithoutSofteningStrongEdge()
        throws {
        let blocked = try makeBuffer { row, column in
            let blockLevel = column < 8 ? 96 : 106
            return UInt8(blockLevel + (row + column) % 3)
        }
        let baseline = try processor(
            temporal: false,
            edge: .medium,
            detail: .medium
        )
        let cleanup = try processor(
            temporal: false,
            edge: .medium,
            detail: .medium,
            compressionCleanup: true
        )
        XCTAssertNotEqual(
            luma(try baseline.process(blocked)),
            luma(try cleanup.process(blocked))
        )

        let strongEdge = try makeBuffer { _, column in
            column < 6 ? 56 : 200
        }
        let strongBaseline = luma(
            try processor(
                temporal: false,
                edge: .high,
                detail: .high
            ).process(strongEdge)
        )
        let strongCleanup = luma(
            try processor(
                temporal: false,
                edge: .high,
                detail: .high,
                compressionCleanup: true
            ).process(strongEdge)
        )
        for row in 1..<(resolution.height - 1) {
            for column in 5...6 {
                let index = row * resolution.width + column
                XCTAssertEqual(
                    strongCleanup[index],
                    strongBaseline[index],
                    "Strong edge changed at \(row),\(column)"
                )
            }
        }
    }

    func testTextureProtectionRestoresOriginalHighFrequencyDetail()
        throws {
        let texture = try makeBuffer { row, column in
            (row + column).isMultiple(of: 2) ? 88 : 108
        }
        let unprotected = luma(
            try processor(
                temporal: false,
                edge: .high,
                detail: .high,
                compressionCleanup: true
            ).process(texture)
        )
        let protected = luma(
            try processor(
                temporal: false,
                edge: .high,
                detail: .high,
                compressionCleanup: true,
                textureProtection: true
            ).process(texture)
        )
        let original = luma(texture)
        let unprotectedDamage = zip(unprotected, original).reduce(0) {
            $0 + abs(Int($1.0) - Int($1.1))
        }
        let protectedDamage = zip(protected, original).reduce(0) {
            $0 + abs(Int($1.0) - Int($1.1))
        }

        XCTAssertNotEqual(unprotected, protected)
        XCTAssertLessThan(protectedDamage, unprotectedDamage)

        let enhancementOnly = luma(
            try processor(
                temporal: false,
                edge: .high,
                detail: .high
            ).process(texture)
        )
        let textureOnly = luma(
            try processor(
                temporal: false,
                edge: .high,
                detail: .high,
                textureProtection: true
            ).process(texture)
        )
        XCTAssertNotEqual(enhancementOnly, textureOnly)
    }

    func testTemporalStabilityIndependentlySuppressesLowMotionFlicker()
        throws {
        let first = try makeBuffer { _, _ in 100 }
        let flicker = try makeBuffer { _, _ in 112 }
        let sceneChange = try makeBuffer { _, _ in 220 }
        let stable = try processor(
            temporal: false,
            edge: .low,
            detail: .low,
            temporalStability: true
        )
        let noTemporalEffect = try processor(
            temporal: false,
            edge: .low,
            detail: .low
        )

        _ = try stable.process(first)
        let stabilized = luma(try stable.process(flicker))
        let baseline = luma(try noTemporalEffect.process(flicker))

        XCTAssertTrue(baseline.allSatisfy { $0 == 112 })
        XCTAssertTrue(stabilized.allSatisfy { $0 == 106 })
        XCTAssertTrue(
            luma(try stable.process(sceneChange))
                .allSatisfy { $0 == 220 }
        )
    }

    func testEnhancementReducesAggregateSquaredErrorForKnownFlickerSequence()
        throws {
        let referenceFrames = try (0..<4).map { _ in
            try makeBuffer { _, _ in 100 }
        }
        let degradedLevels: [UInt8] = [100, 112, 100, 112]
        let degradedFrames = try degradedLevels.map { level in
            try makeBuffer { _, _ in level }
        }
        let enhancement = try processor(
            temporal: true,
            edge: .high,
            detail: .high,
            edgePreservation: true,
            compressionCleanup: true,
            textureProtection: true,
            temporalStability: true
        )
        let enhancedFrames = try degradedFrames.map {
            try enhancement.process($0)
        }
        let referenceSamples = referenceFrames.flatMap { luma($0) }
        let degradedSamples = degradedFrames.flatMap { luma($0) }
        let enhancedSamples = enhancedFrames.flatMap { luma($0) }
        let degradedSquaredError = zip(
            degradedSamples,
            referenceSamples
        ).reduce(into: Int64(0)) { total, samples in
            let difference =
                Int64(samples.0) - Int64(samples.1)
            total += difference * difference
        }
        let enhancedSquaredError = zip(
            enhancedSamples,
            referenceSamples
        ).reduce(into: Int64(0)) { total, samples in
            let difference =
                Int64(samples.0) - Int64(samples.1)
            total += difference * difference
        }

        XCTAssertLessThan(
            enhancedSquaredError,
            degradedSquaredError
        )
    }

    func testTemporalStabilityRestoredHistoryMatchesUninterruptedHistory()
        throws {
        let first = try makeBuffer { row, column in
            UInt8(92 + (row + column) % 4)
        }
        let second = try makeBuffer { row, column in
            UInt8(101 + (row + column) % 4)
        }
        let uninterrupted = try processor(
            temporal: false,
            edge: .medium,
            detail: .medium,
            temporalStability: true
        )
        let restored = try processor(
            temporal: false,
            edge: .medium,
            detail: .medium,
            temporalStability: true
        )

        let cached = try uninterrupted.process(first)
        try restored.restoreTemporalHistory(from: cached)

        XCTAssertEqual(
            logicalBytes(try uninterrupted.process(second)),
            logicalBytes(try restored.process(second))
        )
    }

    func testAllProductEffectsAreRepeatableTogether() throws {
        let frames = try [
            makeBuffer { row, column in
                UInt8(74 + ((row * 7 + column * 11) % 44))
            },
            makeBuffer { row, column in
                UInt8(78 + ((row * 7 + column * 11) % 44))
            }
        ]
        let first = try processor(
            temporal: true,
            edge: .high,
            detail: .high,
            edgePreservation: true,
            compressionCleanup: true,
            textureProtection: true,
            temporalStability: true
        )
        let second = try processor(
            temporal: true,
            edge: .high,
            detail: .high,
            edgePreservation: true,
            compressionCleanup: true,
            textureProtection: true,
            temporalStability: true
        )

        XCTAssertEqual(
            try frames.map {
                logicalBytes(try first.process($0))
            },
            try frames.map {
                logicalBytes(try second.process($0))
            }
        )
    }

    func testParallelProductEffectsAreRepeatableAcrossProcessors()
        throws {
        let parallelResolution = VideoResolution(
            width: 128,
            height: 96
        )
        let frames = try [
            makeBuffer(resolution: parallelResolution) { row, column in
                UInt8(70 + ((row * 13 + column * 17) % 52))
            },
            makeBuffer(resolution: parallelResolution) { row, column in
                UInt8(74 + ((row * 13 + column * 17) % 52))
            }
        ]
        let first = try processor(
            targetResolution: parallelResolution,
            temporal: true,
            edge: .high,
            detail: .high,
            edgePreservation: true,
            compressionCleanup: true,
            textureProtection: true,
            temporalStability: true
        )
        let second = try processor(
            targetResolution: parallelResolution,
            temporal: true,
            edge: .high,
            detail: .high,
            edgePreservation: true,
            compressionCleanup: true,
            textureProtection: true,
            temporalStability: true
        )

        XCTAssertEqual(
            try frames.map {
                logicalBytes(try first.process($0))
            },
            try frames.map {
                logicalBytes(try second.process($0))
            }
        )
    }

    func testProcessorOwnedMemoryPlanIsResolutionBounded()
        throws {
        let fourK = VideoResolution(width: 3_840, height: 2_160)
        let pixelCount = fourK.width * fourK.height
        let baseline = try R13FullFrameEnhancementProcessor(
            targetResolution: fourK,
            temporalConsistencyEnabled: false,
            edgeFidelityLevel: .high,
            detailRecoveryLevel: .high
        )
        let stability = try R13FullFrameEnhancementProcessor(
            targetResolution: fourK,
            temporalConsistencyEnabled: false,
            edgeFidelityLevel: .high,
            detailRecoveryLevel: .high,
            temporalStabilityEnabled: true
        )
        let bothTemporalEffects =
            try R13FullFrameEnhancementProcessor(
                targetResolution: fourK,
                temporalConsistencyEnabled: true,
                edgeFidelityLevel: .high,
                detailRecoveryLevel: .high,
                temporalStabilityEnabled: true
            )

        XCTAssertEqual(
            baseline.memoryPlan,
            R13FullFrameEnhancementMemoryPlan(
                framePixelCount: pixelCount,
                maximumHistoryBytes: 0,
                temporalMaskBytes: 0
            )
        )
        XCTAssertEqual(
            stability.memoryPlan.maximumHistoryBytes,
            pixelCount * 3
        )
        XCTAssertEqual(
            stability.memoryPlan.temporalMaskBytes,
            pixelCount
        )
        XCTAssertEqual(
            bothTemporalEffects.memoryPlan.temporalMaskBytes,
            pixelCount * 2
        )
        XCTAssertEqual(
            bothTemporalEffects.memoryPlan.maximumProcessorOwnedBytes,
            pixelCount * 5
        )
        XCTAssertLessThanOrEqual(
            bothTemporalEffects.memoryPlan.maximumProcessorOwnedBytes,
            40 * 1_024 * 1_024
        )
    }

    func testRestoredVerifiedHistoryMatchesUninterruptedHistory()
        throws {
        let firstFrame = try makeBuffer { row, column in
            UInt8(96 + ((row + column) % 3) * 3)
        }
        let secondFrame = try makeBuffer { row, column in
            UInt8(99 + ((row + column) % 3) * 3)
        }
        let uninterrupted = try processor(
            temporal: true,
            edge: .medium,
            detail: .medium
        )
        let restored = try processor(
            temporal: true,
            edge: .medium,
            detail: .medium
        )

        let verifiedCachedOutput =
            try uninterrupted.process(firstFrame)
        try restored.restoreTemporalHistory(
            from: verifiedCachedOutput
        )
        let uninterruptedOutput =
            try uninterrupted.process(secondFrame)
        let restoredOutput = try restored.process(secondFrame)

        XCTAssertEqual(
            logicalBytes(uninterruptedOutput),
            logicalBytes(restoredOutput)
        )
    }

    func testResetFinishAndCancelHaveTypedLifecycleSemantics()
        throws {
        let firstFrame = try makeBuffer { _, _ in 90 }
        let secondFrame = try makeBuffer { _, _ in 94 }
        let resetProcessor = try processor(
            temporal: true,
            edge: .low,
            detail: .low
        )
        let freshProcessor = try processor(
            temporal: true,
            edge: .low,
            detail: .low
        )
        _ = try resetProcessor.process(firstFrame)
        try resetProcessor.reset()
        XCTAssertEqual(
            logicalBytes(try resetProcessor.process(secondFrame)),
            logicalBytes(try freshProcessor.process(secondFrame))
        )

        let finished = try processor(
            temporal: false,
            edge: .low,
            detail: .low,
            edgePreservation: true,
            compressionCleanup: true,
            textureProtection: true,
            temporalStability: true
        )
        try finished.finish()
        try finished.finish()
        finished.cancel()
        XCTAssertThrowsError(try finished.process(firstFrame)) {
            XCTAssertEqual(
                $0 as? R13FullFrameEnhancementProcessorError,
                .finished
            )
        }

        let cancelled = try processor(
            temporal: true,
            edge: .low,
            detail: .low,
            edgePreservation: true,
            compressionCleanup: true,
            textureProtection: true,
            temporalStability: true
        )
        cancelled.cancel()
        XCTAssertThrowsError(try cancelled.finish()) {
            XCTAssertEqual(
                $0 as? R13FullFrameEnhancementProcessorError,
                .cancelled
            )
        }
        XCTAssertThrowsError(try cancelled.process(firstFrame)) {
            XCTAssertEqual(
                $0 as? R13FullFrameEnhancementProcessorError,
                .cancelled
            )
        }
    }

    func testRejectsNon420vAndMismatchedResolutionWithTypedErrors()
        throws {
        let processor = try processor(
            temporal: false,
            edge: .low,
            detail: .low
        )
        let fullRange = try makeBuffer(
            resolution: resolution,
            format: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ) { _, _ in 100 }
        XCTAssertThrowsError(try processor.process(fullRange)) {
            XCTAssertEqual(
                $0 as? R13FullFrameEnhancementProcessorError,
                .unsupportedPixelFormat(
                    role: .source,
                    actual:
                        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                )
            )
        }

        let wrongResolution = VideoResolution(width: 10, height: 8)
        let wrongSize = try makeBuffer(
            resolution: wrongResolution
        ) { _, _ in 100 }
        XCTAssertThrowsError(try processor.process(wrongSize)) {
            XCTAssertEqual(
                $0 as? R13FullFrameEnhancementProcessorError,
                .resolutionMismatch(
                    role: .source,
                    expected: resolution,
                    actual: wrongResolution
                )
            )
        }
    }
}

final class R13FullFrameEnhancementProcessorPerformanceTests:
    XCTestCase {
    func testReleaseBenchmarkWhenRequested() throws {
        guard let rawCase = ProcessInfo.processInfo.environment[
            "MIRMIR_PROCESSOR_BENCHMARK_CASE"
        ] else {
            throw XCTSkip(
                "Set MIRMIR_PROCESSOR_BENCHMARK_CASE to run."
            )
        }
#if DEBUG
        XCTFail("Processor benchmarks must use the Release configuration.")
        return
#else
        let benchmarkCase = try XCTUnwrap(
            BenchmarkCase(rawValue: rawCase),
            "Unknown processor benchmark case: \(rawCase)"
        )
        try run(benchmarkCase)
#endif
    }
}

private extension R13FullFrameEnhancementProcessorPerformanceTests {
    enum BenchmarkScenario: String {
        case baselineSpatial = "baseline_spatial"
        case allEffects = "all_effects"
        case temporalSteadyState = "temporal_steady_state"
    }

    enum BenchmarkCase: String {
        case baseline1080 = "baseline_1920x1080"
        case effects1080 = "all_effects_1920x1080"
        case temporal1080 = "temporal_1920x1080"
        case baseline2160 = "baseline_3840x2160"
        case effects2160 = "all_effects_3840x2160"
        case temporal2160 = "temporal_3840x2160"

        var resolution: VideoResolution {
            switch self {
            case .baseline1080, .effects1080, .temporal1080:
                return .p1080
            case .baseline2160, .effects2160, .temporal2160:
                return .p2160
            }
        }

        var scenario: BenchmarkScenario {
            switch self {
            case .baseline1080, .baseline2160:
                return .baselineSpatial
            case .effects1080, .effects2160:
                return .allEffects
            case .temporal1080, .temporal2160:
                return .temporalSteadyState
            }
        }
    }

    struct MemorySample {
        let residentBytes: UInt64
        let peakResidentBytes: UInt64
    }

    // The benchmark is intentionally custom rather than XCTest `measure`:
    // it records per-frame samples and process peak RSS in a machine-readable
    // artifact while leaving absolute performance policy out of CI.
    func run(_ benchmarkCase: BenchmarkCase) throws {
        let warmupIterations = 2
        let measuredIterations = 5
        let initialMemory = try memorySample()
        let resolution = benchmarkCase.resolution
        let inputs = [
            try makeBenchmarkBuffer(resolution: resolution, offset: 0),
            try makeBenchmarkBuffer(resolution: resolution, offset: 2)
        ]
        let processor = try makeProcessor(
            resolution: resolution,
            scenario: benchmarkCase.scenario
        )
        var checksum: UInt64 = 0
        var lastOutput: CVPixelBuffer?

        for iteration in 0..<warmupIterations {
            let output = try processor.process(
                inputs[iteration % inputs.count]
            )
            checksum &+= sampledChecksum(output)
            lastOutput = output
        }
        let warmedMemory = try memorySample()
        var frameMilliseconds: [Double] = []
        var maximumObservedResidentBytes =
            warmedMemory.residentBytes
        for iteration in 0..<measuredIterations {
            let started = DispatchTime.now().uptimeNanoseconds
            let output = try processor.process(
                inputs[(iteration + warmupIterations) % inputs.count]
            )
            let elapsed = DispatchTime.now().uptimeNanoseconds - started
            frameMilliseconds.append(Double(elapsed) / 1_000_000)
            checksum &+= sampledChecksum(output)
            lastOutput = output
            maximumObservedResidentBytes = max(
                maximumObservedResidentBytes,
                try memorySample().residentBytes
            )
        }
        _ = lastOutput
        let finalMemory = try memorySample()
        try processor.finish()

        let sorted = frameMilliseconds.sorted()
        let median = sorted[sorted.count / 2]
        let p95Index = max(
            0,
            Int(ceil(Double(sorted.count) * 0.95)) - 1
        )
        let mean =
            frameMilliseconds.reduce(0, +)
            / Double(frameMilliseconds.count)
        let report: [String: Any] = [
            "case": benchmarkCase.rawValue,
            "scenario": benchmarkCase.scenario.rawValue,
            "width": resolution.width,
            "height": resolution.height,
            "warmup_iterations": warmupIterations,
            "measured_iterations": measuredIterations,
            "frame_milliseconds": frameMilliseconds,
            "mean_milliseconds": mean,
            "median_milliseconds": median,
            "p95_milliseconds": sorted[p95Index],
            "frames_per_second": 1_000 / mean,
            "initial_resident_bytes": initialMemory.residentBytes,
            "warmed_resident_bytes": warmedMemory.residentBytes,
            "maximum_observed_resident_bytes":
                maximumObservedResidentBytes,
            "process_peak_resident_bytes":
                finalMemory.peakResidentBytes,
            "peak_growth_from_initial_bytes":
                max(
                    0,
                    Int64(finalMemory.peakResidentBytes)
                        - Int64(initialMemory.peakResidentBytes)
                ),
            "checksum": checksum
        ]
        let data = try JSONSerialization.data(
            withJSONObject: report,
            options: [.sortedKeys]
        )
        let line = try XCTUnwrap(String(data: data, encoding: .utf8))
        print("MIRMIR_PROCESSOR_BENCHMARK \(line)")
        if let outputPath = ProcessInfo.processInfo.environment[
            "MIRMIR_PROCESSOR_BENCHMARK_OUTPUT"
        ] {
            try data.write(
                to: URL(fileURLWithPath: outputPath),
                options: .atomic
            )
        }
        XCTAssertEqual(frameMilliseconds.count, measuredIterations)
        XCTAssertNotEqual(checksum, 0)
    }

    func makeProcessor(
        resolution: VideoResolution,
        scenario: BenchmarkScenario
    ) throws -> R13FullFrameEnhancementProcessor {
        try R13FullFrameEnhancementProcessor(
            targetResolution: resolution,
            temporalConsistencyEnabled:
                scenario == .temporalSteadyState,
            edgeFidelityLevel: .high,
            detailRecoveryLevel: .high,
            edgePreservationEnabled: scenario == .allEffects,
            compressionCleanupEnabled: scenario == .allEffects,
            textureGrainProtectionEnabled: scenario == .allEffects,
            temporalStabilityEnabled:
                scenario != .baselineSpatial
        )
    }

    func makeBenchmarkBuffer(
        resolution: VideoResolution,
        offset: Int
    ) throws -> CVPixelBuffer {
        let attributes = [
            kCVPixelBufferIOSurfacePropertiesKey as String:
                [String: Any]()
        ] as CFDictionary
        var optionalBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            resolution.width,
            resolution.height,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            attributes,
            &optionalBuffer
        )
        guard status == kCVReturnSuccess,
              let buffer = optionalBuffer else {
            throw R13FullFrameEnhancementProcessorError
                .outputAllocationFailed(status)
        }
        let lockStatus = CVPixelBufferLockBaseAddress(buffer, [])
        XCTAssertEqual(lockStatus, kCVReturnSuccess)
        defer {
            CVPixelBufferUnlockBaseAddress(buffer, [])
        }
        let luma = try XCTUnwrap(
            CVPixelBufferGetBaseAddressOfPlane(buffer, 0)
        ).assumingMemoryBound(to: UInt8.self)
        let lumaStride =
            CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        for row in 0..<resolution.height {
            let lumaRow = luma.advanced(by: row * lumaStride)
            for column in 0..<resolution.width {
                lumaRow[column] = UInt8(
                    48 + (
                        row * 13
                            + column * 7
                            + (row / 8) * 3
                            + (column / 8) * 5
                    ) % 144 + offset
                )
            }
        }
        let chroma = try XCTUnwrap(
            CVPixelBufferGetBaseAddressOfPlane(buffer, 1)
        ).assumingMemoryBound(to: UInt8.self)
        let chromaStride =
            CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        for row in 0..<(resolution.height / 2) {
            let chromaRow = chroma.advanced(by: row * chromaStride)
            for column in 0..<(resolution.width / 2) {
                chromaRow[column * 2] = UInt8(
                    112 + (row * 3 + column * 5 + offset) % 17
                )
                chromaRow[column * 2 + 1] = UInt8(
                    128 + (row * 7 + column * 3 + offset) % 17
                )
            }
        }
        return buffer
    }

    func sampledChecksum(_ buffer: CVPixelBuffer) -> UInt64 {
        let status = CVPixelBufferLockBaseAddress(buffer, .readOnly)
        XCTAssertEqual(status, kCVReturnSuccess)
        defer {
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        }
        guard let address =
                CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else {
            return 0
        }
        let luma = address.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        var checksum: UInt64 = 0
        for index in 0..<16 {
            let row = index * (height - 1) / 15
            let column = (15 - index) * (width - 1) / 15
            checksum = checksum &* 257
                &+ UInt64(luma[row * stride + column])
        }
        return checksum
    }

    func memorySample() throws -> MemorySample {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.size
                / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(
                to: integer_t.self,
                capacity: Int(count)
            ) { rebound in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    rebound,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else {
            throw NSError(
                domain: "MirmirProcessorBenchmark",
                code: Int(result)
            )
        }
        return MemorySample(
            residentBytes: info.resident_size,
            peakResidentBytes: info.resident_size_max
        )
    }
}

private extension R13FullFrameEnhancementProcessorTests {
    func processor(
        targetResolution: VideoResolution? = nil,
        temporal: Bool,
        edge: MirmirAdjustmentLevel,
        detail: MirmirAdjustmentLevel,
        edgePreservation: Bool = false,
        compressionCleanup: Bool = false,
        textureProtection: Bool = false,
        temporalStability: Bool = false
    ) throws -> R13FullFrameEnhancementProcessor {
        try R13FullFrameEnhancementProcessor(
            targetResolution: targetResolution ?? resolution,
            temporalConsistencyEnabled: temporal,
            edgeFidelityLevel: edge,
            detailRecoveryLevel: detail,
            edgePreservationEnabled: edgePreservation,
            compressionCleanupEnabled: compressionCleanup,
            textureGrainProtectionEnabled: textureProtection,
            temporalStabilityEnabled: temporalStability
        )
    }

    func makeBuffer(
        resolution: VideoResolution? = nil,
        format: OSType =
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        lumaValue: (Int, Int) -> UInt8
    ) throws -> CVPixelBuffer {
        let resolution = resolution ?? self.resolution
        let attributes = [
            kCVPixelBufferIOSurfacePropertiesKey as String:
                [String: Any]()
        ] as CFDictionary
        var optionalBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            resolution.width,
            resolution.height,
            format,
            attributes,
            &optionalBuffer
        )
        let buffer = try XCTUnwrap(optionalBuffer)
        XCTAssertEqual(status, kCVReturnSuccess)
        let lockStatus = CVPixelBufferLockBaseAddress(buffer, [])
        XCTAssertEqual(lockStatus, kCVReturnSuccess)
        defer {
            CVPixelBufferUnlockBaseAddress(buffer, [])
        }

        let luma = try XCTUnwrap(
            CVPixelBufferGetBaseAddressOfPlane(buffer, 0)
        ).assumingMemoryBound(to: UInt8.self)
        let lumaStride =
            CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        for row in 0..<resolution.height {
            for column in 0..<resolution.width {
                luma[row * lumaStride + column] =
                    lumaValue(row, column)
            }
        }
        let chroma = try XCTUnwrap(
            CVPixelBufferGetBaseAddressOfPlane(buffer, 1)
        ).assumingMemoryBound(to: UInt8.self)
        let chromaStride =
            CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        for row in 0..<(resolution.height / 2) {
            for column in 0..<(resolution.width / 2) {
                chroma[row * chromaStride + column * 2] =
                    UInt8(116 + (row + column) % 5)
                chroma[row * chromaStride + column * 2 + 1] =
                    UInt8(132 + (row * 2 + column) % 5)
            }
        }
        installColorAttachments(on: buffer)
        return buffer
    }

    func installColorAttachments(on buffer: CVPixelBuffer) {
        CVBufferSetAttachment(
            buffer,
            kCVImageBufferColorPrimariesKey,
            kCVImageBufferColorPrimaries_ITU_R_709_2,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            buffer,
            kCVImageBufferTransferFunctionKey,
            kCVImageBufferTransferFunction_ITU_R_709_2,
            .shouldNotPropagate
        )
        CVBufferSetAttachment(
            buffer,
            kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferYCbCrMatrix_ITU_R_709_2,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            buffer,
            kCVImageBufferChromaLocationTopFieldKey,
            kCVImageBufferChromaLocation_Left,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            buffer,
            kCVImageBufferChromaLocationBottomFieldKey,
            kCVImageBufferChromaLocation_Left,
            .shouldPropagate
        )
    }

    func assertColorAttachmentsPreserved(
        from source: CVPixelBuffer,
        to destination: CVPixelBuffer,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let keys: [CFString] = [
            kCVImageBufferColorPrimariesKey,
            kCVImageBufferTransferFunctionKey,
            kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferChromaLocationTopFieldKey,
            kCVImageBufferChromaLocationBottomFieldKey
        ]
        for key in keys {
            var sourceMode = CVAttachmentMode.shouldPropagate
            var destinationMode = CVAttachmentMode.shouldPropagate
            let sourceValue = CVBufferCopyAttachment(
                source,
                key,
                &sourceMode
            )
            let destinationValue = CVBufferCopyAttachment(
                destination,
                key,
                &destinationMode
            )
            XCTAssertEqual(
                sourceValue as? NSObject,
                destinationValue as? NSObject,
                file: file,
                line: line
            )
            XCTAssertEqual(
                sourceMode,
                destinationMode,
                file: file,
                line: line
            )
        }
    }

    func luma(_ buffer: CVPixelBuffer) -> [UInt8] {
        let lockStatus = CVPixelBufferLockBaseAddress(
            buffer,
            .readOnly
        )
        XCTAssertEqual(lockStatus, kCVReturnSuccess)
        defer {
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        }
        let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!
            .assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        return (0..<height).flatMap { row in
            (0..<width).map { column in
                base[row * stride + column]
            }
        }
    }

    func chroma(_ buffer: CVPixelBuffer) -> [UInt8] {
        let lockStatus = CVPixelBufferLockBaseAddress(
            buffer,
            .readOnly
        )
        XCTAssertEqual(lockStatus, kCVReturnSuccess)
        defer {
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        }
        let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!
            .assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        let activeBytesPerRow = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer) / 2
        return (0..<height).flatMap { row in
            (0..<activeBytesPerRow).map { column in
                base[row * stride + column]
            }
        }
    }

    func logicalBytes(_ buffer: CVPixelBuffer) -> [UInt8] {
        luma(buffer) + chroma(buffer)
    }
}
