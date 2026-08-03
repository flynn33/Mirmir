import CoreMedia
import CoreVideo
import XCTest
@testable import Mirmir

private typealias CheckpointJSONObjectV4 = [
    String: ASHCanonicalJSONValueV4
]

private enum CheckpointMutationFixtureError: Error {
    case malformed
}

final class DeterministicCPUBackendTests: XCTestCase {
    func testCanonicalASHCodeAndStrictDecoderExhaustivelyMatchTheFiniteContract() {
        XCTAssertEqual(ASHCode.codewords.count, 16)
        XCTAssertEqual(Set(ASHCode.codewords).count, 16)

        for codeword in ASHCode.codewords {
            XCTAssertTrue(codeword.hasValidIntegrity)
            XCTAssertEqual(codeword.bit(coordinate: 8), 0)
        }

        for leftIndex in ASHCode.codewords.indices {
            for rightIndex in ASHCode.codewords.indices where leftIndex < rightIndex {
                XCTAssertGreaterThanOrEqual(
                    ASHCode.codewords[leftIndex].hammingDistance(
                        to: ASHCode.codewords[rightIndex]
                    ),
                    4
                )
            }
        }

        var exactCount = 0
        var correctedCount = 0
        var uncorrectableCount = 0
        for rawValue in 0..<(1 << ASHState.bitCount) {
            let received = ASHState(validatedRawValue: UInt16(rawValue))
            let decoded = ASHCode.decode(received)
            let bruteForce = bruteForceDecode(received)
            XCTAssertEqual(decoded, bruteForce, "Mismatch for state \(received)")
            switch decoded.status {
            case .exact:
                exactCount += 1
            case .corrected:
                correctedCount += 1
            case .uncorrectable:
                uncorrectableCount += 1
            }
        }
        XCTAssertEqual(exactCount, 16)
        XCTAssertEqual(correctedCount, 144)
        XCTAssertEqual(uncorrectableCount, 352)
    }

    func testCanonicalASHStrictDecoderRejectsEveryTwoBitCodewordCorruption() {
        for codeword in ASHCode.codewords {
            for firstCoordinate in 1..<ASHState.bitCount {
                for secondCoordinate in (firstCoordinate + 1)...ASHState.bitCount {
                    let corrupted = codeword
                        .toggled(coordinate: firstCoordinate)
                        .toggled(coordinate: secondCoordinate)
                    let decoded = ASHCode.decode(corrupted)
                    XCTAssertEqual(decoded.status, .uncorrectable)
                    XCTAssertNil(decoded.codeword)
                    XCTAssertGreaterThanOrEqual(decoded.distance, 2)
                }
            }
        }
    }

    func testCanonicalASHAffineDecoderCorrectsEverySingleBitError() {
        for rawAnchor in 0..<(1 << ASHState.bitCount) {
            let anchor = ASHState(validatedRawValue: UInt16(rawAnchor))
            guard anchor.hasValidIntegrity else { continue }

            for codeword in ASHCode.codewords {
                let expected = anchor.xor(codeword)
                for coordinate in 1...ASHState.bitCount {
                    let decoded = ASHCode.decodeAffine(
                        received: expected.toggled(coordinate: coordinate),
                        anchor: anchor
                    )
                    XCTAssertEqual(decoded.status, .corrected)
                    XCTAssertEqual(decoded.codeword, expected)
                    XCTAssertEqual(decoded.distance, 1)
                    XCTAssertEqual(decoded.nearestCount, 1)
                }
            }
        }
    }

    func testRouteAvailabilityAcceptsArbitraryRationalUpscaleRoutes() async throws {
        let backend = try makeBackend()
        let source = makeSourceInfo(pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)

        let direct2x = await backend.availability(
            for: source,
            targetSize: CGSize(width: 32, height: 24),
            environment: deterministicTestEnvironment
        )
        let direct3Over2 = await backend.availability(
            for: source,
            targetSize: CGSize(width: 24, height: 18),
            environment: deterministicTestEnvironment
        )
        XCTAssertEqual(direct2x, .available)
        XCTAssertEqual(direct3Over2, .available)
        let arbitrary = await backend.availability(
            for: source,
            targetSize: CGSize(width: 28, height: 20),
            environment: deterministicTestEnvironment
        )
        XCTAssertEqual(arbitrary, .available)
    }

    func testRepeatedCPUReferenceFramesAreByteIdenticalForBothNV12Ranges() async throws {
        for pixelFormat in [
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ] {
            let sourceInfo = makeSourceInfo(pixelFormat: pixelFormat)
            let backend = try makeBackend()
            let request = BackendPreparationRequest(
                source: sourceInfo,
                targetSize: CGSize(width: 32, height: 24)
            )
            let first = try await backend.prepare(
                request: request,
                environment: deterministicTestEnvironment
            )
            let second = try await backend.prepare(
                request: request,
                environment: deterministicTestEnvironment
            )
            let source = try SyntheticNV12PixelBuffer.make(
                width: 16,
                height: 12,
                pixelFormat: pixelFormat
            )
            try SyntheticNV12PixelBuffer.fill(source, luma: 91, cb: 117, cr: 143)
            attachProgressiveBT709(to: source)
            let firstOutput = try SyntheticNV12PixelBuffer.make(
                width: 32,
                height: 24,
                pixelFormat: pixelFormat
            )
            let secondOutput = try SyntheticNV12PixelBuffer.make(
                width: 32,
                height: 24,
                pixelFormat: pixelFormat
            )
            let timing = FrameTiming(
                frameIndex: 0,
                presentationTime: .zero,
                duration: CMTime(value: 1, timescale: 30)
            )

            try await first.process(
                source: source,
                destination: firstOutput,
                timing: timing
            )
            try await second.process(
                source: source,
                destination: secondOutput,
                timing: timing
            )

            XCTAssertEqual(
                try SyntheticNV12PixelBuffer.visibleBytes(firstOutput, plane: 0),
                try SyntheticNV12PixelBuffer.visibleBytes(secondOutput, plane: 0)
            )
            XCTAssertEqual(
                try SyntheticNV12PixelBuffer.visibleBytes(firstOutput, plane: 1),
                try SyntheticNV12PixelBuffer.visibleBytes(secondOutput, plane: 1)
            )
        }
    }

    func testMissingChromaLocationDoesNotInventOrRequireAHiddenFallback() async throws {
        let sourceInfo = makeSourceInfo(
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
        let backend = try makeBackend()
        let prepared = try await backend.prepare(
            request: BackendPreparationRequest(
                source: sourceInfo,
                targetSize: CGSize(width: 32, height: 24)
            ),
            environment: deterministicTestEnvironment
        )
        let source = try SyntheticNV12PixelBuffer.make(width: 16, height: 12)
        let destination = try SyntheticNV12PixelBuffer.make(width: 32, height: 24)

        try SyntheticNV12PixelBuffer.fill(
            source,
            luma: 91,
            cb: 117,
            cr: 143
        )
        try await prepared.process(
            source: source,
            destination: destination,
            timing: FrameTiming(
                frameIndex: 0,
                presentationTime: .zero,
                duration: CMTime(value: 1, timescale: 30)
            )
        )
        XCTAssertNil(
            CVBufferCopyAttachment(
                destination,
                kCVImageBufferChromaLocationTopFieldKey,
                nil
            )
        )
    }

    func testFinishIsIdempotentAndPreventsFurtherCPUProcessing() async throws {
        let sourceInfo = makeSourceInfo(
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
        let backend = try makeBackend()
        let prepared = try await backend.prepare(
            request: BackendPreparationRequest(
                source: sourceInfo,
                targetSize: CGSize(width: 32, height: 24)
            ),
            environment: deterministicTestEnvironment
        )
        let source = try SyntheticNV12PixelBuffer.make(width: 16, height: 12)
        let destination = try SyntheticNV12PixelBuffer.make(width: 32, height: 24)
        try SyntheticNV12PixelBuffer.fill(source, luma: 91, cb: 117, cr: 143)
        attachProgressiveBT709(to: source)

        try await prepared.finish()
        try await prepared.finish()

        do {
            try await prepared.process(
                source: source,
                destination: destination,
                timing: FrameTiming(
                    frameIndex: 7,
                    presentationTime: .zero,
                    duration: CMTime(value: 1, timescale: 30)
                )
            )
            XCTFail("Expected processing after finish to fail.")
        } catch let error as MirmirError {
            guard case .backendProcessingFailed(let backendID, let frameIndex, let details) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(backendID, .mirmirDeterministicCPU)
            XCTAssertEqual(frameIndex, 7)
            XCTAssertTrue(details.contains("already finished"))
        }
    }

    func testPreparedCheckpointProducesByteIdenticalProgressiveResume()
        async throws {
        let sourceInfo = makeSourceInfo(
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
        let backend = try makeBackend()
        let request = BackendPreparationRequest(
            source: sourceInfo,
            targetSize: CGSize(width: 28, height: 20)
        )
        let continuousPrepared = try await backend.prepare(
            request: request,
            environment: deterministicTestEnvironment
        )
        let checkpointPrepared = try await backend.prepare(
            request: request,
            environment: deterministicTestEnvironment
        )
        let resumedPrepared = try await backend.prepare(
            request: request,
            environment: deterministicTestEnvironment
        )
        let continuous = try XCTUnwrap(
            continuousPrepared as? PreparedDeterministicV4Upscaler
        )
        let checkpointSource = try XCTUnwrap(
            checkpointPrepared as? PreparedDeterministicV4Upscaler
        )
        let resumed = try XCTUnwrap(
            resumedPrepared as? PreparedDeterministicV4Upscaler
        )
        let sources = try (0..<3).map { frameIndex in
            let buffer = try SyntheticNV12PixelBuffer.make(
                width: 16,
                height: 12
            )
            try writeMovingPattern(frameIndex: frameIndex, to: buffer)
            attachProgressiveBT709(to: buffer)
            return buffer
        }
        let timings = (0..<3).map { frameIndex in
            FrameTiming(
                frameIndex: frameIndex,
                presentationTime: CMTime(
                    value: Int64(frameIndex),
                    timescale: 30
                ),
                duration: CMTime(value: 1, timescale: 30)
            )
        }
        var continuousOutputs: [CVPixelBuffer] = []
        for frameIndex in sources.indices {
            let destination = try SyntheticNV12PixelBuffer.make(
                width: 28,
                height: 20
            )
            try await continuous.process(
                source: sources[frameIndex],
                destination: destination,
                timing: timings[frameIndex]
            )
            continuousOutputs.append(destination)
        }

        for frameIndex in 0...1 {
            let destination = try SyntheticNV12PixelBuffer.make(
                width: 28,
                height: 20
            )
            try await checkpointSource.process(
                source: sources[frameIndex],
                destination: destination,
                timing: timings[frameIndex]
            )
        }
        let planIdentity = ASHSHA256V4(
            rawData: Data("resume-plan-progressive".utf8)
        )
        let checkpointData = try await checkpointSource
            .makeTemporalCheckpoint(
                planSHA256: planIdentity,
                lastCompletedInputOrdinal: 1
            )
        let repeatedCheckpointData = try await checkpointSource
            .makeTemporalCheckpoint(
                planSHA256: planIdentity,
                lastCompletedInputOrdinal: 1
            )
        XCTAssertEqual(
            checkpointData,
            repeatedCheckpointData
        )
        try await resumed.restoreTemporalCheckpoint(
            checkpointData,
            planSHA256: planIdentity
        )
        let resumedOutput = try SyntheticNV12PixelBuffer.make(
            width: 28,
            height: 20
        )
        try await resumed.process(
            source: sources[2],
            destination: resumedOutput,
            timing: timings[2]
        )
        for plane in 0..<2 {
            XCTAssertEqual(
                try SyntheticNV12PixelBuffer.visibleBytes(
                    continuousOutputs[2],
                    plane: plane
                ),
                try SyntheticNV12PixelBuffer.visibleBytes(
                    resumedOutput,
                    plane: plane
                )
            )
        }

        let wrongPlan = ASHSHA256V4(rawData: Data("wrong-plan".utf8))
        await XCTAssertThrowsErrorAsync(
            try await resumed.restoreTemporalCheckpoint(
                checkpointData,
                planSHA256: wrongPlan
            )
        ) { error in
            XCTAssertEqual(
                error as? ASHPreparedTemporalCheckpointV4Error,
                .identityMismatch
            )
        }
    }

    func testCanonicalCheckpointRejectsMalformedNestedTemporalHistory()
        async throws {
        let sourceInfo = makeSourceInfo(
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
        let backend = try makeBackend()
        let request = BackendPreparationRequest(
            source: sourceInfo,
            targetSize: CGSize(width: 28, height: 20)
        )
        let sourceBackend = try await backend.prepare(
            request: request,
            environment: deterministicTestEnvironment
        )
        let restoreBackend = try await backend.prepare(
            request: request,
            environment: deterministicTestEnvironment
        )
        let source = try XCTUnwrap(
            sourceBackend as? PreparedDeterministicV4Upscaler
        )
        let restoreTarget = try XCTUnwrap(
            restoreBackend as? PreparedDeterministicV4Upscaler
        )

        for frameIndex in 0..<4 {
            let input = try SyntheticNV12PixelBuffer.make(
                width: 16,
                height: 12
            )
            try writeMovingPattern(frameIndex: frameIndex, to: input)
            attachProgressiveBT709(to: input)
            try await source.process(
                source: FramePixelBuffer(input),
                destination: FramePixelBuffer(
                    try SyntheticNV12PixelBuffer.make(
                        width: 28,
                        height: 20
                    )
                ),
                timing: FrameTiming(
                    frameIndex: frameIndex,
                    presentationTime: CMTime(
                        value: Int64(frameIndex),
                        timescale: 30
                    ),
                    duration: CMTime(value: 1, timescale: 30)
                )
            )
        }
        let planIdentity = ASHSHA256V4(
            rawData: Data("nested-history-validation".utf8)
        )
        let checkpoint = try await source.makeTemporalCheckpoint(
            planSHA256: planIdentity,
            lastCompletedInputOrdinal: 3
        )
        let wrongFormatIdentity = ASHSHA256V4(
            rawData: Data("wrong-history-format".utf8)
        )
        var malformed: [(name: String, data: Data)] = []

        malformed.append(("short luma samples", try checkpointByMutatingHistory(
            checkpoint,
            mutatingHistory: { history in
                try self.mutateCheckpointHistoryFrames(&history) { frames in
                    let last = frames.index(before: frames.endIndex)
                    try self.mutateCheckpointFrameLuma(&frames[last]) { luma in
                        guard case .array(var samples)? = luma["samples"],
                              !samples.isEmpty else {
                            throw CheckpointMutationFixtureError.malformed
                        }
                        samples.removeLast()
                        luma["samples"] = .array(samples)
                    }
                }
            }
        )))
        malformed.append(("out-of-range luma sample", try checkpointByMutatingHistory(
            checkpoint,
            mutatingHistory: { history in
                try self.mutateCheckpointHistoryFrames(&history) { frames in
                    let last = frames.index(before: frames.endIndex)
                    try self.mutateCheckpointFrameLuma(&frames[last]) { luma in
                        guard case .array(var samples)? = luma["samples"],
                              !samples.isEmpty else {
                            throw CheckpointMutationFixtureError.malformed
                        }
                        samples[0] = .integer(0)
                        luma["samples"] = .array(samples)
                    }
                }
            }
        )))
        malformed.append(("invalid frame identifier", try checkpointByMutatingHistory(
            checkpoint,
            mutatingHistory: { history in
                try self.mutateCheckpointHistoryFrames(&history) { frames in
                    frames[0]["frameID"] = .string("")
                }
            }
        )))
        malformed.append(("invalid tile state", try checkpointByMutatingHistory(
            checkpoint,
            mutatingHistory: { history in
                try self.mutateCheckpointHistoryFrames(&history) { frames in
                    frames[0]["tileStateRawValues"] = .array([.integer(1)])
                }
            }
        )))
        malformed.append(("missing production tile state", try checkpointByMutatingHistory(
            checkpoint,
            mutatingHistory: { history in
                try self.mutateCheckpointHistoryFrames(&history) { frames in
                    frames[0]["tileStateRawValues"] = .array([])
                }
            }
        )))
        malformed.append(("checkpoint format mismatch", try checkpointByMutatingHistory(
            checkpoint,
            mutatingHistory: { history in
                try self.mutateCheckpointHistoryFrames(&history) { frames in
                    for index in frames.indices {
                        frames[index]["formatIdentity"] = .string(
                            wrongFormatIdentity.rawValue
                        )
                    }
                }
            }
        )))
        malformed.append(("non-contiguous trailing ordinal", try checkpointByMutatingHistory(
            checkpoint,
            mutatingHistory: { history in
                try self.mutateCheckpointHistoryFrames(&history) { frames in
                    frames[0]["ordinal"] = .integer(0)
                    frames[0]["frameID"] = .string("v4-frame-0")
                }
            }
        )))
        malformed.append(("contradictory reset reason", try checkpointByMutatingHistory(
            checkpoint,
            mutatingHistory: { history in
                history["lastResetReason"] = .string("scene_cut")
            }
        )))
        malformed.append(("non-production stream identity", try checkpointByMutatingHistory(
            checkpoint,
            mutatingHistory: { history in
                try self.mutateCheckpointHistoryFrames(&history) { frames in
                    for index in frames.indices {
                        frames[index]["streamID"] = .string("forged-stream")
                    }
                }
            }
        )))
        malformed.append(("non-production cadence identity", try checkpointByMutatingHistory(
            checkpoint,
            mutatingHistory: { history in
                try self.mutateCheckpointHistoryFrames(&history) { frames in
                    for index in frames.indices {
                        frames[index]["cadenceID"] = .string("forged-cadence")
                    }
                }
            }
        )))
        malformed.append(("non-production history capacity", try checkpointByMutatingHistory(
            checkpoint,
            mutatingHistory: { history in
                history["capacity"] = .integer(4)
            }
        )))
        malformed.append(("zero history generation", try checkpointByMutatingHistory(
            checkpoint,
            mutatingHistory: { history in
                history["generation"] = .integer(0)
            }
        )))

        for candidate in malformed {
            await XCTAssertThrowsErrorAsync(
                try await restoreTarget.restoreTemporalCheckpoint(
                    candidate.data,
                    planSHA256: planIdentity
                )
            ) { error in
                XCTAssertEqual(
                    error as? ASHPreparedTemporalCheckpointV4Error,
                    .invalidState,
                    candidate.name
                )
            }
        }

        try await restoreTarget.restoreTemporalCheckpoint(
            checkpoint,
            planSHA256: planIdentity
        )
        let restoredCheckpoint = try await restoreTarget.makeTemporalCheckpoint(
            planSHA256: planIdentity,
            lastCompletedInputOrdinal: 3
        )
        XCTAssertEqual(
            restoredCheckpoint,
            checkpoint
        )
    }

    func testInterlacedPreparedPathUsesExactDoubleRateTimingAndResume()
        async throws {
        let sourceInfo = makeSourceInfo(
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            fieldCount: 2,
            fieldDetail: kCVImageBufferFieldDetailTemporalTopFirst as String
        )
        let backend = try makeBackend()
        let request = BackendPreparationRequest(
            source: sourceInfo,
            targetSize: CGSize(width: 32, height: 24)
        )
        let continuousPrepared = try await backend.prepare(
            request: request,
            environment: deterministicTestEnvironment
        )
        let checkpointPrepared = try await backend.prepare(
            request: request,
            environment: deterministicTestEnvironment
        )
        let resumedPrepared = try await backend.prepare(
            request: request,
            environment: deterministicTestEnvironment
        )
        let continuous = try XCTUnwrap(
            continuousPrepared as? PreparedDeterministicV4Upscaler
        )
        let checkpointSource = try XCTUnwrap(
            checkpointPrepared as? PreparedDeterministicV4Upscaler
        )
        let resumed = try XCTUnwrap(
            resumedPrepared as? PreparedDeterministicV4Upscaler
        )
        XCTAssertEqual(continuous.maximumOutputFramesPerInput, 2)
        let sources = try (0..<2).map { frameIndex in
            let buffer = try SyntheticNV12PixelBuffer.make(
                width: 16,
                height: 12
            )
            try writeFieldPattern(frameIndex: frameIndex, to: buffer)
            attachProgressiveBT709(to: buffer)
            CVBufferSetAttachment(
                buffer,
                kCVImageBufferFieldCountKey,
                NSNumber(value: 2),
                .shouldPropagate
            )
            CVBufferSetAttachment(
                buffer,
                kCVImageBufferFieldDetailKey,
                frameIndex == 0
                    ? kCVImageBufferFieldDetailTemporalTopFirst
                    : kCVImageBufferFieldDetailTemporalBottomFirst,
                .shouldPropagate
            )
            return buffer
        }
        let duration = CMTime(value: 1_001, timescale: 30_000)
        let timings = [
            FrameTiming(
                frameIndex: 0,
                presentationTime: CMTime(value: 1_001, timescale: 30_000),
                duration: duration
            ),
            FrameTiming(
                frameIndex: 1,
                presentationTime: CMTime(value: 2_002, timescale: 30_000),
                duration: duration
            )
        ]
        let firstContinuousDestinations = try makeDestinations(
            count: 2,
            width: 32,
            height: 24
        )
        let firstOutputs = try await continuous.processTemporal(
            source: FramePixelBuffer(sources[0]),
            destinations: firstContinuousDestinations.map(FramePixelBuffer.init),
            timing: timings[0]
        )
        XCTAssertEqual(firstOutputs.count, 2)
        XCTAssertEqual(
            firstOutputs[0].presentationTime,
            CMTime(value: 1_001, timescale: 30_000)
        )
        XCTAssertEqual(
            firstOutputs[1].presentationTime,
            CMTime(value: 1_001, timescale: 20_000)
        )
        for output in firstOutputs {
            XCTAssertEqual(
                (CVBufferCopyAttachment(
                    output.pixelBuffer.value,
                    kCVImageBufferFieldCountKey,
                    nil
                ) as? NSNumber)?.intValue,
                1
            )
            XCTAssertNil(CVBufferCopyAttachment(
                output.pixelBuffer.value,
                kCVImageBufferFieldDetailKey,
                nil
            ))
        }

        let secondContinuousDestinations = try makeDestinations(
            count: 2,
            width: 32,
            height: 24
        )
        let secondContinuousOutputs = try await continuous.processTemporal(
            source: FramePixelBuffer(sources[1]),
            destinations: secondContinuousDestinations.map(FramePixelBuffer.init),
            timing: timings[1]
        )
        let cadenceCheckpoint = try await continuous.makeTemporalCheckpoint(
            planSHA256: ASHSHA256V4(
                rawData: Data("cadence-transition-plan".utf8)
            ),
            lastCompletedInputOrdinal: 1
        )
        let cadenceState = try JSONDecoder().decode(
            ASHPreparedTemporalCheckpointV4.self,
            from: cadenceCheckpoint
        )
        XCTAssertEqual(
            cadenceState.history.frames.last?.cadenceID,
            "interlaced_bff_double_rate"
        )
        XCTAssertGreaterThanOrEqual(cadenceState.history.generation, 2)

        _ = try await checkpointSource.processTemporal(
            source: FramePixelBuffer(sources[0]),
            destinations: try makeDestinations(
                count: 2,
                width: 32,
                height: 24
            ).map(FramePixelBuffer.init),
            timing: timings[0]
        )
        let planIdentity = ASHSHA256V4(
            rawData: Data("resume-plan-interlaced".utf8)
        )
        let checkpointData = try await checkpointSource
            .makeTemporalCheckpoint(
                planSHA256: planIdentity,
                lastCompletedInputOrdinal: 0
            )
        try await resumed.restoreTemporalCheckpoint(
            checkpointData,
            planSHA256: planIdentity
        )
        let resumedDestinations = try makeDestinations(
            count: 2,
            width: 32,
            height: 24
        )
        let resumedOutputs = try await resumed.processTemporal(
            source: FramePixelBuffer(sources[1]),
            destinations: resumedDestinations.map(FramePixelBuffer.init),
            timing: timings[1]
        )
        XCTAssertEqual(
            secondContinuousOutputs.map(\.presentationTime),
            resumedOutputs.map(\.presentationTime)
        )
        for outputIndex in 0..<2 {
            for plane in 0..<2 {
                XCTAssertEqual(
                    try SyntheticNV12PixelBuffer.visibleBytes(
                        secondContinuousOutputs[outputIndex].pixelBuffer.value,
                        plane: plane
                    ),
                    try SyntheticNV12PixelBuffer.visibleBytes(
                        resumedOutputs[outputIndex].pixelBuffer.value,
                        plane: plane
                    )
                )
            }
        }
    }

    func testTelecineCadenceCheckpointResumeMatchesUninterruptedPixelsAndState()
        async throws {
        let sourceInfo = makeSourceInfo(
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            fieldCount: 2,
            fieldDetail: kCVImageBufferFieldDetailTemporalTopFirst as String
        )
        let request = BackendPreparationRequest(
            source: sourceInfo,
            targetSize: CGSize(width: 32, height: 24)
        )
        let backend = try makeBackend()
        let uninterruptedPrepared = try await backend.prepare(
            request: request,
            environment: deterministicTestEnvironment
        )
        let checkpointPrepared = try await backend.prepare(
            request: request,
            environment: deterministicTestEnvironment
        )
        let resumedPrepared = try await backend.prepare(
            request: request,
            environment: deterministicTestEnvironment
        )
        let uninterrupted = try XCTUnwrap(
            uninterruptedPrepared as? PreparedDeterministicV4Upscaler
        )
        let checkpointSource = try XCTUnwrap(
            checkpointPrepared as? PreparedDeterministicV4Upscaler
        )
        let resumed = try XCTUnwrap(
            resumedPrepared as? PreparedDeterministicV4Upscaler
        )
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
            (top: 27, bottom: 28)
        ]
        let sources = try pairs.map { pair in
            try makeCadenceSource(top: pair.top, bottom: pair.bottom)
        }
        let timings = pairs.indices.map { frameIndex in
            FrameTiming(
                frameIndex: frameIndex,
                presentationTime: CMTime(
                    value: Int64(frameIndex),
                    timescale: 30
                ),
                duration: CMTime(value: 1, timescale: 30)
            )
        }

        var uninterruptedOutputs: [[CVPixelBuffer]] = []
        for frameIndex in sources.indices {
            let destinations = try makeDestinations(
                count: 2,
                width: 32,
                height: 24
            )
            _ = try await uninterrupted.processTemporal(
                source: FramePixelBuffer(sources[frameIndex]),
                destinations: destinations.map(FramePixelBuffer.init),
                timing: timings[frameIndex]
            )
            uninterruptedOutputs.append(destinations)
        }

        for frameIndex in 0...10 {
            _ = try await checkpointSource.processTemporal(
                source: FramePixelBuffer(sources[frameIndex]),
                destinations: try makeDestinations(
                    count: 2,
                    width: 32,
                    height: 24
                ).map(FramePixelBuffer.init),
                timing: timings[frameIndex]
            )
        }
        let planIdentity = ASHSHA256V4(
            rawData: Data("telecine-resume-plan".utf8)
        )
        let checkpoint = try await checkpointSource.makeTemporalCheckpoint(
            planSHA256: planIdentity,
            lastCompletedInputOrdinal: 10
        )
        let captured = try JSONDecoder().decode(
            ASHPreparedTemporalCheckpointV4.self,
            from: checkpoint
        )
        XCTAssertEqual(
            captured.schemaID,
            ASHPreparedTemporalCheckpointV4.currentSchemaID
        )
        XCTAssertEqual(
            captured.fieldCadenceState?.classification,
            .telecine32
        )
        XCTAssertEqual(
            captured.history.frames.last?.cadenceID,
            "telecine_3_2_tff_double_rate"
        )

        var malformedValue = try ASHCanonicalJSONV4.parse(checkpoint)
        guard case .object(var malformedRoot) = malformedValue,
              case .object(var cadenceState)?
                = malformedRoot["fieldCadenceState"],
              case .array(var observations)?
                = cadenceState["observations"] else {
            return XCTFail("Expected a canonical field-cadence checkpoint.")
        }
        observations.removeFirst()
        cadenceState["observations"] = .array(observations)
        malformedRoot["fieldCadenceState"] = .object(cadenceState)
        malformedValue = .object(malformedRoot)
        let malformedCheckpoint = ASHCanonicalJSONV4.encode(malformedValue)
        await XCTAssertThrowsErrorAsync(
            try await resumed.restoreTemporalCheckpoint(
                malformedCheckpoint,
                planSHA256: planIdentity
            )
        ) { error in
            XCTAssertEqual(
                error as? ASHPreparedTemporalCheckpointV4Error,
                .invalidState
            )
        }

        var contradictoryValue = try ASHCanonicalJSONV4.parse(checkpoint)
        guard case .object(var contradictoryRoot) = contradictoryValue,
              case .object(var contradictoryCadence)?
                = contradictoryRoot["fieldCadenceState"],
              case .array(var contradictoryObservations)?
                = contradictoryCadence["observations"],
              case .object(var contradictoryObservation)
                = contradictoryObservations[0] else {
            return XCTFail("Expected canonical cadence evidence.")
        }
        contradictoryObservation["repeatEvidence"] = .string("both")
        contradictoryObservations[0] = .object(contradictoryObservation)
        contradictoryCadence["observations"] = .array(
            contradictoryObservations
        )
        contradictoryRoot["fieldCadenceState"] = .object(
            contradictoryCadence
        )
        contradictoryValue = .object(contradictoryRoot)
        let contradictoryCheckpoint = ASHCanonicalJSONV4.encode(
            contradictoryValue
        )
        await XCTAssertThrowsErrorAsync(
            try await resumed.restoreTemporalCheckpoint(
                contradictoryCheckpoint,
                planSHA256: planIdentity
            )
        ) { error in
            XCTAssertEqual(
                error as? ASHPreparedTemporalCheckpointV4Error,
                .invalidState
            )
        }

        var mismatchedOrdinalValue = try ASHCanonicalJSONV4.parse(checkpoint)
        guard case .object(var mismatchedOrdinalRoot) = mismatchedOrdinalValue
        else {
            return XCTFail("Expected canonical checkpoint object.")
        }
        mismatchedOrdinalRoot["lastCompletedInputOrdinal"] = .integer(9)
        mismatchedOrdinalValue = .object(mismatchedOrdinalRoot)
        await XCTAssertThrowsErrorAsync(
            try await resumed.restoreTemporalCheckpoint(
                ASHCanonicalJSONV4.encode(mismatchedOrdinalValue),
                planSHA256: planIdentity
            )
        ) { error in
            XCTAssertEqual(
                error as? ASHPreparedTemporalCheckpointV4Error,
                .invalidState
            )
        }

        var exhaustedOrdinalValue = try ASHCanonicalJSONV4.parse(checkpoint)
        guard case .object(var exhaustedOrdinalRoot) = exhaustedOrdinalValue
        else {
            return XCTFail("Expected canonical checkpoint object.")
        }
        exhaustedOrdinalRoot["nextOutputOrdinal"] = .integer(Int64.max)
        exhaustedOrdinalValue = .object(exhaustedOrdinalRoot)
        await XCTAssertThrowsErrorAsync(
            try await resumed.restoreTemporalCheckpoint(
                ASHCanonicalJSONV4.encode(exhaustedOrdinalValue),
                planSHA256: planIdentity
            )
        ) { error in
            XCTAssertEqual(
                error as? ASHPreparedTemporalCheckpointV4Error,
                .invalidState
            )
        }

        try await resumed.restoreTemporalCheckpoint(
            checkpoint,
            planSHA256: planIdentity
        )
        for frameIndex in 11...13 {
            let destinations = try makeDestinations(
                count: 2,
                width: 32,
                height: 24
            )
            let resumedOutputs = try await resumed.processTemporal(
                source: FramePixelBuffer(sources[frameIndex]),
                destinations: destinations.map(FramePixelBuffer.init),
                timing: timings[frameIndex]
            )
            XCTAssertEqual(
                resumedOutputs.map(\.presentationTime),
                [
                    CMTime(value: Int64(frameIndex * 2), timescale: 60),
                    CMTime(value: Int64(frameIndex * 2 + 1), timescale: 60)
                ]
            )
            for outputIndex in 0..<2 {
                for planeIndex in 0..<2 {
                    XCTAssertEqual(
                        try SyntheticNV12PixelBuffer.visibleBytes(
                            uninterruptedOutputs[frameIndex][outputIndex],
                            plane: planeIndex
                        ),
                        try SyntheticNV12PixelBuffer.visibleBytes(
                            destinations[outputIndex],
                            plane: planeIndex
                        )
                    )
                }
            }
        }
        let uninterruptedCheckpoint = try await uninterrupted
            .makeTemporalCheckpoint(
                planSHA256: planIdentity,
                lastCompletedInputOrdinal: 13
            )
        let resumedCheckpoint = try await resumed.makeTemporalCheckpoint(
            planSHA256: planIdentity,
            lastCompletedInputOrdinal: 13
        )
        XCTAssertEqual(resumedCheckpoint, uninterruptedCheckpoint)
    }

    func testMixedAndDominanceCadenceTransitionsResetHistoryExactlyOnce()
        async throws {
        let sourceInfo = makeSourceInfo(
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            fieldCount: 2,
            fieldDetail: kCVImageBufferFieldDetailTemporalTopFirst as String
        )
        let backend = try makeBackend()
        let preparedBackend = try await backend.prepare(
            request: BackendPreparationRequest(
                source: sourceInfo,
                targetSize: CGSize(width: 32, height: 24)
            ),
            environment: deterministicTestEnvironment
        )
        let prepared = try XCTUnwrap(
            preparedBackend as? PreparedDeterministicV4Upscaler
        )
        let telecinePairs = [
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
        for (frameIndex, pair) in telecinePairs.enumerated() {
            _ = try await prepared.processTemporal(
                source: FramePixelBuffer(try makeCadenceSource(
                    top: pair.top,
                    bottom: pair.bottom
                )),
                destinations: try makeDestinations(
                    count: 2,
                    width: 32,
                    height: 24
                ).map(FramePixelBuffer.init),
                timing: FrameTiming(
                    frameIndex: frameIndex,
                    presentationTime: CMTime(
                        value: Int64(frameIndex),
                        timescale: 30
                    ),
                    duration: CMTime(value: 1, timescale: 30)
                )
            )
        }
        let planIdentity = ASHSHA256V4(
            rawData: Data("cadence-reset-plan".utf8)
        )
        let telecineCheckpoint = try await prepared.makeTemporalCheckpoint(
            planSHA256: planIdentity,
            lastCompletedInputOrdinal: 10
        )
        let telecineState = try JSONDecoder().decode(
            ASHPreparedTemporalCheckpointV4.self,
            from: telecineCheckpoint
        )
        XCTAssertEqual(
            telecineState.fieldCadenceState?.classification,
            .telecine32
        )

        _ = try await prepared.processTemporal(
            source: FramePixelBuffer(try makeCadenceSource(
                top: 21,
                bottom: 24
            )),
            destinations: try makeDestinations(
                count: 2,
                width: 32,
                height: 24
            ).map(FramePixelBuffer.init),
            timing: FrameTiming(
                frameIndex: 11,
                presentationTime: CMTime(value: 11, timescale: 30),
                duration: CMTime(value: 1, timescale: 30)
            )
        )
        let mixedCheckpoint = try await prepared.makeTemporalCheckpoint(
            planSHA256: planIdentity,
            lastCompletedInputOrdinal: 11
        )
        let mixedState = try JSONDecoder().decode(
            ASHPreparedTemporalCheckpointV4.self,
            from: mixedCheckpoint
        )
        XCTAssertEqual(mixedState.fieldCadenceState?.classification, .mixed)
        XCTAssertEqual(
            mixedState.history.frames.last?.cadenceID,
            "mixed_tff_double_rate"
        )
        XCTAssertEqual(
            mixedState.history.generation,
            telecineState.history.generation + 1
        )
        XCTAssertEqual(mixedState.history.frames.count, 2)
        XCTAssertTrue(
            mixedState.history.frames.allSatisfy {
                $0.cadenceID == "mixed_tff_double_rate"
            }
        )

        let dominanceSource = try makeCadenceSource(top: 15, bottom: 16)
        CVBufferSetAttachment(
            dominanceSource,
            kCVImageBufferFieldDetailKey,
            kCVImageBufferFieldDetailTemporalBottomFirst,
            .shouldPropagate
        )
        _ = try await prepared.processTemporal(
            source: FramePixelBuffer(dominanceSource),
            destinations: try makeDestinations(
                count: 2,
                width: 32,
                height: 24
            ).map(FramePixelBuffer.init),
            timing: FrameTiming(
                frameIndex: 12,
                presentationTime: CMTime(value: 12, timescale: 30),
                duration: CMTime(value: 1, timescale: 30)
            )
        )
        let dominanceCheckpoint = try await prepared.makeTemporalCheckpoint(
            planSHA256: planIdentity,
            lastCompletedInputOrdinal: 12
        )
        let dominanceState = try JSONDecoder().decode(
            ASHPreparedTemporalCheckpointV4.self,
            from: dominanceCheckpoint
        )
        XCTAssertEqual(
            dominanceState.fieldCadenceState?.dominance,
            .bottomFieldFirst
        )
        XCTAssertEqual(
            dominanceState.fieldCadenceState?.classification,
            .interlaced
        )
        XCTAssertEqual(
            dominanceState.fieldCadenceState?.inputFrameCount,
            1
        )
        XCTAssertEqual(
            dominanceState.history.frames.last?.cadenceID,
            "interlaced_bff_double_rate"
        )
        XCTAssertEqual(
            dominanceState.history.generation,
            mixedState.history.generation + 1
        )
        XCTAssertEqual(dominanceState.history.frames.count, 2)
    }

    func testInterlacedFailureAndCancellationRollbackForByteIdenticalRetry()
        async throws {
        let sourceInfo = makeSourceInfo(
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            fieldCount: 2,
            fieldDetail: kCVImageBufferFieldDetailTemporalTopFirst as String
        )
        let request = BackendPreparationRequest(
            source: sourceInfo,
            targetSize: CGSize(width: 32, height: 24)
        )
        let backend = try makeBackend()
        var preparedActors: [PreparedDeterministicV4Upscaler] = []
        for _ in 0..<3 {
            let prepared = try await backend.prepare(
                request: request,
                environment: deterministicTestEnvironment
            )
            preparedActors.append(try XCTUnwrap(
                prepared as? PreparedDeterministicV4Upscaler
            ))
        }
        let clean = preparedActors[0]
        let cancelled = preparedActors[1]
        let failed = preparedActors[2]
        let source = try makeCadenceSource(top: 1, bottom: 2)
        let timing = FrameTiming(
            frameIndex: 0,
            presentationTime: .zero,
            duration: CMTime(value: 1, timescale: 30)
        )
        let cleanDestinations = try makeDestinations(
            count: 2,
            width: 32,
            height: 24
        )
        _ = try await clean.processTemporal(
            source: FramePixelBuffer(source),
            destinations: cleanDestinations.map(FramePixelBuffer.init),
            timing: timing
        )

        let sentinelKey = "com.mirmir.tests.transaction-sentinel" as CFString
        let cancelledDestinations = try makeDestinations(
            count: 2,
            width: 32,
            height: 24
        )
        for (index, destination) in cancelledDestinations.enumerated() {
            try fillAllPlaneBytes(destination, value: UInt8(0xA0 + index))
            CVBufferSetAttachment(
                destination,
                sentinelKey,
                "cancelled-\(index)" as CFString,
                .shouldPropagate
            )
        }
        let cancelledBytesBefore = try cancelledDestinations.map(allPlaneBytes)
        await cancelled.setInterlacedOutputBoundaryTestHook { outputIndex in
            if outputIndex == 1 { throw CancellationError() }
        }
        await XCTAssertThrowsErrorAsync(
            try await cancelled.processTemporal(
                source: FramePixelBuffer(source),
                destinations: cancelledDestinations.map(FramePixelBuffer.init),
                timing: timing
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        await cancelled.setInterlacedOutputBoundaryTestHook(nil)
        XCTAssertEqual(
            try cancelledDestinations.map(allPlaneBytes),
            cancelledBytesBefore
        )
        for (index, destination) in cancelledDestinations.enumerated() {
            XCTAssertEqual(
                CVBufferCopyAttachment(
                    destination,
                    sentinelKey,
                    nil
                ) as? String,
                "cancelled-\(index)"
            )
        }

        let validFirstDestination = try SyntheticNV12PixelBuffer.make(
            width: 32,
            height: 24
        )
        let invalidSecondDestination = try SyntheticNV12PixelBuffer.make(
            width: 30,
            height: 24
        )
        try fillAllPlaneBytes(validFirstDestination, value: 0xB1)
        try fillAllPlaneBytes(invalidSecondDestination, value: 0xB2)
        let failedBytesBefore = try [
            validFirstDestination,
            invalidSecondDestination
        ].map(allPlaneBytes)
        await XCTAssertThrowsErrorAsync(
            try await failed.processTemporal(
                source: FramePixelBuffer(source),
                destinations: [
                    FramePixelBuffer(validFirstDestination),
                    FramePixelBuffer(invalidSecondDestination)
                ],
                timing: timing
            )
        )
        XCTAssertEqual(
            try [validFirstDestination, invalidSecondDestination]
                .map(allPlaneBytes),
            failedBytesBefore
        )

        let planIdentity = ASHSHA256V4(
            rawData: Data("interlaced-transaction-retry".utf8)
        )
        let expectedCheckpoint = try await clean.makeTemporalCheckpoint(
            planSHA256: planIdentity,
            lastCompletedInputOrdinal: 0
        )
        for retryActor in [cancelled, failed] {
            let retryDestinations = try makeDestinations(
                count: 2,
                width: 32,
                height: 24
            )
            _ = try await retryActor.processTemporal(
                source: FramePixelBuffer(source),
                destinations: retryDestinations.map(FramePixelBuffer.init),
                timing: timing
            )
            for outputIndex in 0..<2 {
                for planeIndex in 0..<2 {
                    XCTAssertEqual(
                        try SyntheticNV12PixelBuffer.visibleBytes(
                            retryDestinations[outputIndex],
                            plane: planeIndex
                        ),
                        try SyntheticNV12PixelBuffer.visibleBytes(
                            cleanDestinations[outputIndex],
                            plane: planeIndex
                        )
                    )
                }
            }
            let retryCheckpoint = try await retryActor
                .makeTemporalCheckpoint(
                    planSHA256: planIdentity,
                    lastCompletedInputOrdinal: 0
                )
            XCTAssertEqual(
                retryCheckpoint,
                expectedCheckpoint
            )
        }
    }

    func testInterlacedDestinationAliasingFailsBeforeCallerMutation()
        async throws {
        let sourceInfo = makeSourceInfo(
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            fieldCount: 2,
            fieldDetail: kCVImageBufferFieldDetailTemporalTopFirst as String
        )
        let backend = try makeBackend()
        let preparedBackend = try await backend.prepare(
            request: BackendPreparationRequest(
                source: sourceInfo,
                targetSize: CGSize(width: 32, height: 24)
            ),
            environment: deterministicTestEnvironment
        )
        let prepared = try XCTUnwrap(
            preparedBackend as? PreparedDeterministicV4Upscaler
        )
        let source = try makeCadenceSource(top: 1, bottom: 2)
        let timing = FrameTiming(
            frameIndex: 0,
            presentationTime: .zero,
            duration: CMTime(value: 1, timescale: 30)
        )

        let identical = try SyntheticNV12PixelBuffer.make(
            width: 32,
            height: 24
        )
        try fillAllPlaneBytes(identical, value: 0xC1)
        let identicalBefore = try allPlaneBytes(identical)
        await XCTAssertThrowsErrorAsync(
            try await prepared.processTemporal(
                source: FramePixelBuffer(source),
                destinations: [
                    FramePixelBuffer(identical),
                    FramePixelBuffer(identical)
                ],
                timing: timing
            )
        ) { error in
            XCTAssertEqual(
                error as? ASHPreparedTemporalCheckpointV4Error,
                .destinationAlias
            )
        }
        XCTAssertEqual(try allPlaneBytes(identical), identicalBefore)

        let aliased = try InterlacedCrossPlaneAliasedNV12Fixture()
        let aliasedBefore = aliased.bytes
        await XCTAssertThrowsErrorAsync(
            try await prepared.processTemporal(
                source: FramePixelBuffer(source),
                destinations: [
                    FramePixelBuffer(aliased.first),
                    FramePixelBuffer(aliased.second)
                ],
                timing: timing
            )
        ) { error in
            XCTAssertEqual(
                error as? ASHPreparedTemporalCheckpointV4Error,
                .destinationAlias
            )
        }
        XCTAssertEqual(aliased.bytes, aliasedBefore)
    }

    func testInFlightGuardRejectsEveryReentrantLifecycleOperation()
        async throws {
        let sourceInfo = makeSourceInfo(
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            fieldCount: 2,
            fieldDetail: kCVImageBufferFieldDetailTemporalTopFirst as String
        )
        let request = BackendPreparationRequest(
            source: sourceInfo,
            targetSize: CGSize(width: 32, height: 24)
        )
        let backend = try makeBackend()
        let cleanBackend = try await backend.prepare(
            request: request,
            environment: deterministicTestEnvironment
        )
        let subjectBackend = try await backend.prepare(
            request: request,
            environment: deterministicTestEnvironment
        )
        let clean = try XCTUnwrap(
            cleanBackend as? PreparedDeterministicV4Upscaler
        )
        let subject = try XCTUnwrap(
            subjectBackend as? PreparedDeterministicV4Upscaler
        )
        let source = try makeCadenceSource(top: 1, bottom: 2)
        let timing = FrameTiming(
            frameIndex: 0,
            presentationTime: .zero,
            duration: CMTime(value: 1, timescale: 30)
        )
        let cleanDestinations = try makeDestinations(
            count: 2,
            width: 32,
            height: 24
        )
        _ = try await clean.processTemporal(
            source: FramePixelBuffer(source),
            destinations: cleanDestinations.map(FramePixelBuffer.init),
            timing: timing
        )
        let subjectDestinations = try makeDestinations(
            count: 2,
            width: 32,
            height: 24
        )
        let gate = InterlacedOutputBoundaryGate()
        await subject.setInterlacedOutputBoundaryTestHook { outputIndex in
            if outputIndex == 1 { await gate.suspend() }
        }
        let processingTask = Task {
            try await subject.processTemporal(
                source: FramePixelBuffer(source),
                destinations: subjectDestinations.map(FramePixelBuffer.init),
                timing: timing
            )
        }
        await gate.waitUntilEntered()

        let assertBusy: (Error) -> Void = { error in
            XCTAssertEqual(
                error as? ASHPreparedTemporalCheckpointV4Error,
                .operationInProgress
            )
        }
        await XCTAssertThrowsErrorAsync(
            try await subject.processTemporal(
                source: FramePixelBuffer(source),
                destinations: try self.makeDestinations(
                    count: 2,
                    width: 32,
                    height: 24
                ).map(FramePixelBuffer.init),
                timing: timing
            ),
            assertBusy
        )
        await XCTAssertThrowsErrorAsync(
            try await subject.finish(),
            assertBusy
        )
        await XCTAssertThrowsErrorAsync(
            try await subject.makeTemporalCheckpoint(
                planSHA256: ASHSHA256V4(rawData: Data("busy".utf8)),
                lastCompletedInputOrdinal: 0
            ),
            assertBusy
        )
        await XCTAssertThrowsErrorAsync(
            try await subject.restoreTemporalCheckpoint(
                Data(),
                planSHA256: ASHSHA256V4(rawData: Data("busy".utf8))
            ),
            assertBusy
        )

        await gate.release()
        _ = try await processingTask.value
        await subject.setInterlacedOutputBoundaryTestHook(nil)
        for outputIndex in 0..<2 {
            for planeIndex in 0..<2 {
                XCTAssertEqual(
                    try SyntheticNV12PixelBuffer.visibleBytes(
                        subjectDestinations[outputIndex],
                        plane: planeIndex
                    ),
                    try SyntheticNV12PixelBuffer.visibleBytes(
                        cleanDestinations[outputIndex],
                        plane: planeIndex
                    )
                )
            }
        }
        let planIdentity = ASHSHA256V4(
            rawData: Data("reentrant-operation-identity".utf8)
        )
        let cleanCheckpoint = try await clean.makeTemporalCheckpoint(
            planSHA256: planIdentity,
            lastCompletedInputOrdinal: 0
        )
        let subjectCheckpoint = try await subject.makeTemporalCheckpoint(
            planSHA256: planIdentity,
            lastCompletedInputOrdinal: 0
        )
        XCTAssertEqual(subjectCheckpoint, cleanCheckpoint)
    }

    private func bruteForceDecode(_ received: ASHState) -> ASHDecodeResult {
        let distances = ASHCode.codewords.map { codeword in
            (distance: received.hammingDistance(to: codeword), codeword: codeword)
        }
        let minimum = distances.map(\.distance).min() ?? ASHState.bitCount
        let nearest = distances.filter { $0.distance == minimum }.map(\.codeword)

        guard minimum <= 1, nearest.count == 1, let codeword = nearest.first else {
            return ASHDecodeResult(
                status: .uncorrectable,
                received: received,
                codeword: nil,
                messageBits: nil,
                distance: minimum,
                nearestCount: nearest.count
            )
        }

        return ASHDecodeResult(
            status: minimum == 0 ? .exact : .corrected,
            received: received,
            codeword: codeword,
            messageBits: ASHCode.messageBits(for: codeword),
            distance: minimum,
            nearestCount: 1
        )
    }

    private func makeBackend() throws -> DeterministicCPUBackend {
        let descriptor = try XCTUnwrap(
            BackendDescriptor.descriptor(for: .mirmirDeterministicCPU)
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ash-p06-cpu-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let runtime = try ASHV4SemanticArtifactTestSupport.buildAndLoad(
            at: directory
        )
        return try XCTUnwrap(DeterministicCPUBackend(
            descriptor: descriptor,
            runtimeProvider: .fixed(runtime)
        ))
    }

    private func checkpointByMutatingHistory(
        _ checkpoint: Data,
        mutatingHistory mutation: (inout CheckpointJSONObjectV4) throws -> Void
    ) throws -> Data {
        let parsed = try ASHCanonicalJSONV4.parse(checkpoint)
        guard case .object(var root) = parsed,
              case .object(var history)? = root["history"] else {
            throw CheckpointMutationFixtureError.malformed
        }
        try mutation(&history)
        root["history"] = .object(history)
        return ASHCanonicalJSONV4.encode(.object(root))
    }

    private func mutateCheckpointHistoryFrames(
        _ history: inout CheckpointJSONObjectV4,
        mutation: (inout [CheckpointJSONObjectV4]) throws -> Void
    ) throws {
        guard case .array(let encodedFrames)? = history["frames"] else {
            throw CheckpointMutationFixtureError.malformed
        }
        var frames: [CheckpointJSONObjectV4] = []
        frames.reserveCapacity(encodedFrames.count)
        for encodedFrame in encodedFrames {
            guard case .object(let frame) = encodedFrame else {
                throw CheckpointMutationFixtureError.malformed
            }
            frames.append(frame)
        }
        guard !frames.isEmpty else {
            throw CheckpointMutationFixtureError.malformed
        }
        try mutation(&frames)
        history["frames"] = .array(frames.map {
            ASHCanonicalJSONValueV4.object($0)
        })
    }

    private func mutateCheckpointFrameLuma(
        _ frame: inout CheckpointJSONObjectV4,
        mutation: (inout CheckpointJSONObjectV4) throws -> Void
    ) throws {
        guard case .object(var luma)? = frame["luma"] else {
            throw CheckpointMutationFixtureError.malformed
        }
        try mutation(&luma)
        frame["luma"] = .object(luma)
    }

    private func makeSourceInfo(
        pixelFormat: OSType,
        fieldCount: Int = 1,
        fieldDetail: String? = nil
    ) -> VideoInfo {
        let fullRange = pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        return VideoInfo(
            url: URL(fileURLWithPath: "/tmp/deterministic-source.mov"),
            duration: CMTime(value: 1, timescale: 30),
            geometry: VideoGeometry(
                encodedSize: CGSize(width: 16, height: 12),
                naturalSize: CGSize(width: 16, height: 12),
                presentationSize: CGSize(width: 16, height: 12),
                displaySize: CGSize(width: 16, height: 12),
                preferredTransform: .identity,
                cleanAperture: nil,
                pixelAspectRatio: VideoPixelAspectRatio(
                    horizontalSpacing: 1,
                    verticalSpacing: 1
                )
            ),
            nominalFrameRate: 30,
            minimumFrameDuration: CMTime(value: 1, timescale: 30),
            estimatedFrameCount: 1,
            estimatedDataRate: nil,
            codecFourCC: kCMVideoCodecType_H264,
            hasAudio: false,
            audioTrackCount: 0,
            videoTrackCount: 1,
            isReadable: true,
            isPlayable: true,
            fileSizeBytes: nil,
            color: VideoColorInfo(
                colorPrimaries: kCVImageBufferColorPrimaries_ITU_R_709_2 as String,
                transferFunction: kCVImageBufferTransferFunction_ITU_R_709_2 as String,
                yCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String,
                bitDepth: 8,
                pixelFormat: pixelFormat,
                isFullRange: fullRange,
                fieldCount: fieldCount,
                fieldDetail: fieldDetail,
                alphaModel: .none,
                hasMasteringDisplayMetadata: false,
                hasContentLightLevelMetadata: false,
                dynamicRange: .sdr
            )
        )
    }

    private func attachProgressiveBT709(to buffer: CVPixelBuffer) {
        CVBufferSetAttachment(
            buffer,
            kCVImageBufferChromaLocationTopFieldKey,
            kCVImageBufferChromaLocation_Left,
            .shouldPropagate
        )
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
            .shouldPropagate
        )
        CVBufferSetAttachment(
            buffer,
            kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferYCbCrMatrix_ITU_R_709_2,
            .shouldPropagate
        )
    }

    private func makeDestinations(
        count: Int,
        width: Int,
        height: Int
    ) throws -> [CVPixelBuffer] {
        try (0..<count).map { _ in
            try SyntheticNV12PixelBuffer.make(width: width, height: height)
        }
    }

    private func fillAllPlaneBytes(
        _ buffer: CVPixelBuffer,
        value: UInt8
    ) throws {
        XCTAssertEqual(
            CVPixelBufferLockBaseAddress(buffer, []),
            kCVReturnSuccess
        )
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        for planeIndex in 0..<CVPixelBufferGetPlaneCount(buffer) {
            let base = try XCTUnwrap(
                CVPixelBufferGetBaseAddressOfPlane(buffer, planeIndex)
            )
            let byteCount = CVPixelBufferGetBytesPerRowOfPlane(
                buffer,
                planeIndex
            ) * CVPixelBufferGetHeightOfPlane(buffer, planeIndex)
            memset(base, Int32(value), byteCount)
        }
    }

    private func allPlaneBytes(_ buffer: CVPixelBuffer) throws -> Data {
        XCTAssertEqual(
            CVPixelBufferLockBaseAddress(buffer, .readOnly),
            kCVReturnSuccess
        )
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        var result = Data()
        for planeIndex in 0..<CVPixelBufferGetPlaneCount(buffer) {
            let base = try XCTUnwrap(
                CVPixelBufferGetBaseAddressOfPlane(buffer, planeIndex)
            )
            let byteCount = CVPixelBufferGetBytesPerRowOfPlane(
                buffer,
                planeIndex
            ) * CVPixelBufferGetHeightOfPlane(buffer, planeIndex)
            result.append(
                base.assumingMemoryBound(to: UInt8.self),
                count: byteCount
            )
        }
        return result
    }

    private func writeMovingPattern(
        frameIndex: Int,
        to buffer: CVPixelBuffer
    ) throws {
        try SyntheticNV12PixelBuffer.fill(
            buffer,
            luma: 16,
            cb: 128,
            cr: 128
        )
        let frame = try PixelBufferSignalCodecV4.read(
            buffer,
            storage: .nv12VideoRange8Bit
        )
        let luma = frame.planes[0]
        var lumaValues: [UInt16] = []
        lumaValues.reserveCapacity(luma.width * luma.height)
        for index in 0..<(luma.width * luma.height) {
            let x = index % luma.width
            let y = index / luma.width
            let code = 16 + ((x * 13 + y * 7 + frameIndex * 29) % 220)
            lumaValues.append(UInt16(code))
        }
        let chroma = frame.planes[1]
        var chromaValues: [UInt16] = []
        chromaValues.reserveCapacity(chroma.samples.count)
        for index in 0..<(chroma.width * chroma.height) {
            chromaValues.append(UInt16(32 + ((index * 5 + frameIndex * 11) % 190)))
            chromaValues.append(UInt16(32 + ((index * 9 + frameIndex * 17) % 190)))
        }
        try PixelBufferSignalCodecV4.write(
            PixelBufferSignalFrameV4(
                storage: frame.storage,
                width: frame.width,
                height: frame.height,
                planes: [
                    try luma.replacingComponent(0, with: lumaValues),
                    try PixelBufferSignalPlaneV4(
                        width: chroma.width,
                        height: chroma.height,
                        componentsPerElement: chroma.componentsPerElement,
                        componentBounds: chroma.componentBounds,
                        samples: chromaValues
                    )
                ]
            ),
            to: buffer
        )
    }

    private func writeFieldPattern(
        frameIndex: Int,
        to buffer: CVPixelBuffer
    ) throws {
        try SyntheticNV12PixelBuffer.fill(
            buffer,
            luma: 16,
            cb: 128,
            cr: 128
        )
        let frame = try PixelBufferSignalCodecV4.read(
            buffer,
            storage: .nv12VideoRange8Bit
        )
        var planes: [PixelBufferSignalPlaneV4] = []
        for (planeIndex, plane) in frame.planes.enumerated() {
            var samples = plane.samples
            for y in 0..<plane.height {
                for x in 0..<plane.width {
                    for component in 0..<plane.componentsPerElement {
                        let index = ((y * plane.width) + x)
                            * plane.componentsPerElement + component
                        let base = y.isMultiple(of: 2) ? 48 : 196
                        samples[index] = UInt16(
                            min(235, base + ((x + component * 7
                                + planeIndex * 11 + frameIndex * 13) % 24))
                        )
                    }
                }
            }
            planes.append(try PixelBufferSignalPlaneV4(
                width: plane.width,
                height: plane.height,
                componentsPerElement: plane.componentsPerElement,
                componentBounds: plane.componentBounds,
                samples: samples
            ))
        }
        try PixelBufferSignalCodecV4.write(
            PixelBufferSignalFrameV4(
                storage: frame.storage,
                width: frame.width,
                height: frame.height,
                planes: planes
            ),
            to: buffer
        )
    }

    private func makeCadenceSource(
        top: Int,
        bottom: Int
    ) throws -> CVPixelBuffer {
        let buffer = try SyntheticNV12PixelBuffer.make(width: 16, height: 12)
        try SyntheticNV12PixelBuffer.fill(
            buffer,
            luma: 16,
            cb: 128,
            cr: 128
        )
        let frame = try PixelBufferSignalCodecV4.read(
            buffer,
            storage: .nv12VideoRange8Bit
        )
        var planes: [PixelBufferSignalPlaneV4] = []
        planes.reserveCapacity(frame.planes.count)
        for (planeIndex, plane) in frame.planes.enumerated() {
            var samples = plane.samples
            for y in 0..<plane.height {
                let token = y.isMultiple(of: 2) ? top : bottom
                for x in 0..<plane.width {
                    for component in 0..<plane.componentsPerElement {
                        let index = ((y * plane.width) + x)
                            * plane.componentsPerElement + component
                        let coordinate = (x + y / 2 + component * 3) % 5
                        let base = planeIndex == 0 ? 32 : 96
                        let step = planeIndex == 0 ? 5 : 3
                        samples[index] = UInt16(
                            base + token * step + coordinate
                        )
                    }
                }
            }
            planes.append(try PixelBufferSignalPlaneV4(
                width: plane.width,
                height: plane.height,
                componentsPerElement: plane.componentsPerElement,
                componentBounds: plane.componentBounds,
                samples: samples
            ))
        }
        try PixelBufferSignalCodecV4.write(
            PixelBufferSignalFrameV4(
                storage: frame.storage,
                width: frame.width,
                height: frame.height,
                planes: planes
            ),
            to: buffer
        )
        attachProgressiveBT709(to: buffer)
        CVBufferSetAttachment(
            buffer,
            kCVImageBufferFieldCountKey,
            NSNumber(value: 2),
            .shouldPropagate
        )
        CVBufferSetAttachment(
            buffer,
            kCVImageBufferFieldDetailKey,
            kCVImageBufferFieldDetailTemporalTopFirst,
            .shouldPropagate
        )
        return buffer
    }
}

private actor InterlacedOutputBoundaryGate {
    private var entered = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func suspend() async {
        entered = true
        for waiter in enteredWaiters { waiter.resume() }
        enteredWaiters.removeAll()
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private final class InterlacedCrossPlaneAliasedNV12Fixture {
    let first: CVPixelBuffer
    let second: CVPixelBuffer

    private let storage: InterlacedCrossPlaneAliasedNV12Storage

    var bytes: Data {
        Data(bytes: storage.baseAddress, count: storage.byteCount)
    }

    init() throws {
        let storage = try InterlacedCrossPlaneAliasedNV12Storage(
            byteCount: 3_072
        )
        self.storage = storage
        self.first = try Self.makeBuffer(
            storage: storage,
            lumaOffset: 0,
            chromaOffset: 1_024
        )
        self.second = try Self.makeBuffer(
            storage: storage,
            lumaOffset: 1_024,
            chromaOffset: 2_048
        )
    }

    private static func makeBuffer(
        storage: InterlacedCrossPlaneAliasedNV12Storage,
        lumaOffset: Int,
        chromaOffset: Int
    ) throws -> CVPixelBuffer {
        var planeBaseAddresses: [UnsafeMutableRawPointer?] = [
            storage.baseAddress.advanced(by: lumaOffset),
            storage.baseAddress.advanced(by: chromaOffset)
        ]
        var planeWidths = [32, 16]
        var planeHeights = [24, 12]
        var planeBytesPerRow = [32, 32]
        var pixelBuffer: CVPixelBuffer?
        let retainedStorage = Unmanaged.passRetained(storage)
        let status = CVPixelBufferCreateWithPlanarBytes(
            kCFAllocatorDefault,
            32,
            24,
            PixelStorageV4.nv12VideoRange8Bit.pixelFormat,
            nil,
            0,
            planeBaseAddresses.count,
            &planeBaseAddresses,
            &planeWidths,
            &planeHeights,
            &planeBytesPerRow,
            releaseInterlacedCrossPlaneAliasedNV12Storage,
            retainedStorage.toOpaque(),
            nil,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            retainedStorage.release()
            throw NSError(
                domain: "InterlacedCrossPlaneAliasedNV12Fixture",
                code: Int(status)
            )
        }
        return pixelBuffer
    }
}

private final class InterlacedCrossPlaneAliasedNV12Storage {
    let baseAddress: UnsafeMutableRawPointer
    let byteCount: Int

    init(byteCount: Int) throws {
        guard let baseAddress = malloc(byteCount) else {
            throw NSError(
                domain: "InterlacedCrossPlaneAliasedNV12Fixture",
                code: -1
            )
        }
        self.baseAddress = baseAddress
        self.byteCount = byteCount
        memset(baseAddress, 0xA5, byteCount)
    }

    deinit {
        free(baseAddress)
    }
}

private func releaseInterlacedCrossPlaneAliasedNV12Storage(
    releaseRefCon: UnsafeMutableRawPointer?,
    dataPtr _: UnsafeRawPointer?,
    dataSize _: Int,
    numberOfPlanes _: Int,
    planeAddresses _: UnsafeMutablePointer<UnsafeRawPointer?>?
) {
    guard let releaseRefCon else { return }
    Unmanaged<InterlacedCrossPlaneAliasedNV12Storage>
        .fromOpaque(releaseRefCon)
        .release()
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw")
    } catch {
        errorHandler(error)
    }
}

private let deterministicTestEnvironment = RuntimeEnvironment(
    operatingSystem: RuntimeOperatingSystem(
        OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
    ),
    capabilityProbe: DeterministicTestCapabilityProbe()
)

private struct DeterministicTestCapabilityProbe: BackendCapabilityProbing {
    func availability(
        for backendID: UpscaleBackendID,
        source: VideoInfo,
        targetSize: CGSize
    ) async -> BackendAvailability {
        .available
    }
}
