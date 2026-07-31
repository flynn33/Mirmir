import Darwin
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import os.lock
import XCTest
@testable import Mirmir

// Release service scenarios share one test fixture and helper set.
// swiftlint:disable file_length type_body_length

final class R13ReleaseUpscalerEngineServiceTests: XCTestCase {
    func testEveryReleaseModeIsAvailable() {
        let eventLog = R13ReleaseTestEventLog()
        let media = R13ReleaseTestMediaPipeline(
            resolution: .p720,
            frames: [],
            eventLog: eventLog
        )
        let factory = R13ReleaseTestSessionFactory(
            behavior: .processed,
            eventLog: eventLog
        )
        let service = makeService(media: media, factory: factory)

        XCTAssertEqual(service.availability, .available)
        for mode in UpscaleMode.allCases {
            XCTAssertEqual(service.availability(for: mode), .available)
        }
    }

    func testAutoSubmitsAndFreezesItsResolvedAutomaticBinding() async throws {
        let eventLog = R13ReleaseTestEventLog()
        let media = R13ReleaseTestMediaPipeline(
            resolution: .p720,
            frames: [],
            eventLog: eventLog
        )
        let factory = R13ReleaseTestSessionFactory(
            behavior: .processed,
            eventLog: eventLog
        )
        let service = makeService(media: media, factory: factory)

        let auto = try service.submit(
            makeJob(
                identifier: "r13-auto",
                target: .p1080,
                mode: .auto
            )
        )
        _ = try await auto.waitForCompletion()

        XCTAssertEqual(media.probeCount, 1)
        XCTAssertEqual(media.beginSessionCount, 1)
        XCTAssertEqual(factory.routes, [.scale3Over2])
        XCTAssertEqual(factory.modeBindings.map(\.requestedMode), [.auto])
        XCTAssertEqual(factory.modeBindings.map(\.effectiveMode), [.auto])
        XCTAssertEqual(
            factory.modeBindings.map(\.scalerKind),
            [.highQualityVImage]
        )
    }

    func testInvalidJobIdentifierRejectsBeforeMediaOrBackendWork() {
        let eventLog = R13ReleaseTestEventLog()
        let media = R13ReleaseTestMediaPipeline(
            resolution: .p720,
            frames: [],
            eventLog: eventLog
        )
        let factory = R13ReleaseTestSessionFactory(
            behavior: .processed,
            eventLog: eventLog
        )
        let service = makeService(media: media, factory: factory)

        XCTAssertThrowsError(
            try service.submit(
                makeJob(
                    identifier: "../unsafe",
                    target: .p1080,
                    mode: .quality
                )
            )
        ) { error in
            guard let engineError = error as? UpscalerEngineError,
                  case .invalidJobIdentifier(let identifier) = engineError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(identifier, "../unsafe")
        }
        XCTAssertEqual(media.probeCount, 0)
        XCTAssertTrue(factory.routes.isEmpty)
    }

    func testAllModesUseTheirExactCanonicalScalerAndStableTransactionID() async throws {
        for route in R03ScaleRoute.allCases {
            for mode in UpscaleMode.allCases {
                let eventLog = R13ReleaseTestEventLog()
                let media = R13ReleaseTestMediaPipeline(
                    resolution: route.canonicalSourceResolution,
                    frames: [],
                    eventLog: eventLog
                )
                let factory = R13ReleaseTestSessionFactory(
                    behavior: .processed,
                    eventLog: eventLog
                )
                let service = makeService(media: media, factory: factory)
                let identifier = "r13-\(route.rawValue)-\(mode.rawValue)"
                let handle = try service.submit(
                    makeJob(
                        identifier: identifier,
                        target: route.canonicalTargetResolution,
                        mode: mode
                    )
                )

                let result = try await handle.waitForCompletion()

                XCTAssertEqual(result.lastPathComponent, "\(identifier).mp4")
                XCTAssertEqual(factory.routes, [route])
                XCTAssertEqual(
                    factory.modeBindings,
                    [R13ReleaseModePolicy.binding(for: mode)]
                )
                let mediaSession = try XCTUnwrap(media.lastSession)
                XCTAssertEqual(
                    mediaSession.outputProfile.transactionIdentifier,
                    identifier
                )
                XCTAssertEqual(mediaSession.finishCount, 1)
                XCTAssertEqual(mediaSession.cancelCount, 0)
                let appleSession = try XCTUnwrap(factory.session(for: route))
                let snapshot = await appleSession.snapshot()
                XCTAssertEqual(snapshot.finishCount, 1)
                XCTAssertEqual(snapshot.cancelCount, 0)
            }
        }
    }

    func testScalePlanPreservesQualifiedRoutesAndBindsAdaptiveGeometry()
        throws {
        XCTAssertEqual(
            try R13ReleaseJobContracts.scalePlan(
                source: .p720,
                target: .p1080
            ),
            .productQualified(.scale3Over2)
        )
        XCTAssertEqual(
            try R13ReleaseJobContracts.scalePlan(
                source: .p1080,
                target: .p2160
            ),
            .productQualified(.scale2x)
        )

        let source = VideoResolution(width: 729, height: 411)
        let target = VideoResolution(width: 1_278, height: 720)
        guard case .adaptiveMPSLanczos(let plan) =
            try R13ReleaseJobContracts.scalePlan(
                source: source,
                target: target
            ) else {
            return XCTFail("Expected adaptive MPS plan.")
        }
        XCTAssertEqual(plan.sourceResolution, source)
        XCTAssertEqual(
            plan.processingSourceResolution,
            VideoResolution(width: 730, height: 412)
        )
        XCTAssertEqual(plan.targetResolution, target)
        XCTAssertTrue(
            plan.configurationIdentity.contains(
                "730x412-to-1278x720"
            )
        )
    }

    func testAdaptiveScalePlanRejectsDownscaleOddTargetAndAspectChange() {
        for target in [
            VideoResolution(width: 640, height: 360),
            VideoResolution(width: 1_279, height: 720),
            VideoResolution(width: 1_000, height: 720)
        ] {
            XCTAssertThrowsError(
                try R13AdaptiveScalePlan(
                    sourceResolution: VideoResolution(
                        width: 640,
                        height: 360
                    ),
                    targetResolution: target
                )
            )
        }
    }

    func testAspectContractUsesExactOnePixelBoundaryWithoutOverflow() {
        let maximum = Int.max
        let source = VideoResolution(
            width: maximum,
            height: maximum
        )
        XCTAssertTrue(
            R13AspectRatioContract.preservesWithinOneOutputPixel(
                source: source,
                target: VideoResolution(
                    width: maximum,
                    height: maximum - 1
                )
            ),
            "A one-output-pixel width difference is admissible."
        )
        XCTAssertFalse(
            R13AspectRatioContract.preservesWithinOneOutputPixel(
                source: source,
                target: VideoResolution(
                    width: maximum,
                    height: maximum - 2
                )
            ),
            "A two-output-pixel width difference is not admissible."
        )
        XCTAssertFalse(
            R13AspectRatioContract.preservesWithinOneOutputPixel(
                source: VideoResolution(width: 0, height: 1),
                target: VideoResolution(width: 2, height: 2)
            )
        )
    }

    func testAdaptiveGeometryUsesDistinctMPSPathAndMetadata()
        async throws {
        let eventLog = R13ReleaseTestEventLog()
        let source = VideoResolution(width: 640, height: 360)
        let target = VideoResolution(width: 1_280, height: 720)
        let media = R13ReleaseTestMediaPipeline(
            resolution: source,
            frames: [
                try R13ReleaseTestFrames.make(
                    resolution: source,
                    index: 0
                )
            ],
            eventLog: eventLog
        )
        let factory = R13ReleaseTestSessionFactory(
            behavior: .processed,
            eventLog: eventLog
        )
        let service = R13ReleaseUpscalerEngineService(
            media: media,
            modeAwareSessionFactory: { [factory] route, modeBinding in
                try await factory.make(
                    route: route,
                    modeBinding: modeBinding
                )
            },
            adaptiveScalerFactory: { [eventLog] plan in
                R13ReleaseTestAdaptiveScaler(
                    plan: plan,
                    eventLog: eventLog
                )
            }
        )
        let handle = try service.submit(
            makeJob(
                identifier: "r13-adaptive-geometry",
                target: target,
                mode: .deterministic
            )
        )

        let result = try await handle.waitForCompletion()

        XCTAssertEqual(
            result.lastPathComponent,
            "r13-adaptive-geometry.mp4"
        )
        XCTAssertTrue(factory.routes.isEmpty)
        XCTAssertTrue(eventLog.contains("adaptive.scale"))
        let mediaSession = try XCTUnwrap(media.lastSession)
        XCTAssertEqual(mediaSession.appendedFrameIndices, [0])
        XCTAssertEqual(mediaSession.finishCount, 1)
        XCTAssertEqual(mediaSession.cancelCount, 0)
        XCTAssertEqual(
            mediaSession.outputProfile.timedMetadataTemplate[
                "com.mirmir.release.backend-id"
            ],
            "r03.mps.lanczos"
        )
        XCTAssertEqual(
            mediaSession.outputProfile.timedMetadataTemplate[
                "com.mirmir.release.route-id"
            ],
            "adaptive_mps_lanczos"
        )
    }

    func testCanonicalLivePathAppliesEdgeAndDetailConfiguration()
        async throws {
        let low = try await runCapturedCanonicalEnhancement(
            identifier: "r13-canonical-enhancement-low",
            edge: .low,
            detail: .low
        )
        let high = try await runCapturedCanonicalEnhancement(
            identifier: "r13-canonical-enhancement-high",
            edge: .high,
            detail: .high
        )

        XCTAssertEqual(low.width, VideoResolution.p1080.width)
        XCTAssertEqual(low.height, VideoResolution.p1080.height)
        XCTAssertNotEqual(low.luma, high.luma)
        XCTAssertEqual(low.chroma, high.chroma)
    }

    func testAdaptiveLivePathAppliesEdgeAndDetailConfiguration()
        async throws {
        let low = try await runCapturedAdaptiveEnhancement(
            identifier: "r13-adaptive-enhancement-low",
            edge: .low,
            detail: .low
        )
        let high = try await runCapturedAdaptiveEnhancement(
            identifier: "r13-adaptive-enhancement-high",
            edge: .high,
            detail: .high
        )

        XCTAssertEqual(low.width, 1_280)
        XCTAssertEqual(low.height, 720)
        XCTAssertNotEqual(low.luma, high.luma)
        XCTAssertEqual(low.chroma, high.chroma)
    }

    func testOnePixelAdaptiveAspectRoundingIsAcceptedByOutputAndPreview()
        throws {
        let source = VideoResolution(width: 729, height: 411)
        let normalizedSource = VideoResolution(width: 730, height: 412)
        let target = VideoResolution(width: 1_278, height: 720)
        XCTAssertNoThrow(
            try AVFoundationMediaSession.scaledVideoTransform(
                .identity,
                sourceResolution: source,
                outputResolution: target
            )
        )
        let sourceBuffer = try R13ReleaseTestFrames.makeOutput(
            resolution: normalizedSource
        )
        let targetBuffer = try R13ReleaseTestFrames.makeOutput(
            resolution: target
        )

        let preview = try R13PreviewFrameEncoder().encode(
            source: sourceBuffer,
            processed: targetBuffer,
            sourcePresentationResolution: source,
            frameIndex: 0,
            presentationSeconds: 0,
            presentationTransform: .identity
        )

        XCTAssertEqual(preview.source.width, source.width)
        XCTAssertEqual(preview.source.height, source.height)
        XCTAssertEqual(preview.processed.width, source.width)
        XCTAssertEqual(preview.processed.height, source.height)
    }

    func testOutputAndPreviewRejectAspectChangesLargerThanOnePixel()
        throws {
        let source = VideoResolution(width: 728, height: 410)
        let invalidTarget = VideoResolution(width: 1_260, height: 720)
        XCTAssertThrowsError(
            try AVFoundationMediaSession.scaledVideoTransform(
                .identity,
                sourceResolution: source,
                outputResolution: invalidTarget
            )
        )
        let sourceBuffer = try R13ReleaseTestFrames.makeOutput(
            resolution: source
        )
        let targetBuffer = try R13ReleaseTestFrames.makeOutput(
            resolution: invalidTarget
        )

        XCTAssertThrowsError(
            try R13PreviewFrameEncoder().encode(
                source: sourceBuffer,
                processed: targetBuffer,
                sourcePresentationResolution: source,
                frameIndex: 0,
                presentationSeconds: 0,
                presentationTransform: .identity
            )
        ) { error in
            XCTAssertEqual(
                error as? R13PreviewFrameEncodingError,
                .aspectRatioMismatch
            )
        }
    }

    func testFrameLoopPreservesFIFOAndReleasesInputAndOutputLifetimes() async throws {
        let eventLog = R13ReleaseTestEventLog()
        let previewEncoder = R13RecordingPreviewEncoder(eventLog: eventLog)
        let presentationTransform = CGAffineTransform(
            a: 0,
            b: 1,
            c: -1,
            d: 0,
            tx: 1_080,
            ty: 0
        )
        let frames = try [
            R13ReleaseTestFrames.make(resolution: .p720, index: 0),
            R13ReleaseTestFrames.make(resolution: .p720, index: 1)
        ]
        let media = R13ReleaseTestMediaPipeline(
            resolution: .p720,
            frames: frames,
            eventLog: eventLog,
            presentationTransform: presentationTransform
        )
        let factory = R13ReleaseTestSessionFactory(
            behavior: .processed,
            eventLog: eventLog
        )
        let service = R13ReleaseUpscalerEngineService(
            media: media,
            modeAwareSessionFactory: { [factory] route, modeBinding in
                try await factory.make(
                    route: route,
                    modeBinding: modeBinding
                )
            },
            previewEncoder: previewEncoder,
            inputReleaseObserver: { [eventLog] identity in
                eventLog.record("input.release.\(identity)")
            }
        )
        let handle = try service.submit(
            makeJob(
                identifier: "r13-fifo",
                target: .p1080,
                mode: .fast
            )
        )

        _ = try await handle.waitForCompletion()

        let mediaSession = try XCTUnwrap(media.lastSession)
        XCTAssertEqual(mediaSession.appendedFrameIndices, [0, 1])
        let appleSession = try XCTUnwrap(factory.session(for: .scale3Over2))
        let snapshot = await appleSession.snapshot()
        XCTAssertEqual(snapshot.submittedSequenceNumbers, [0, 1])
        XCTAssertEqual(snapshot.processedFrameCount, 2)
        XCTAssertEqual(snapshot.finishCount, 1)

        let events = eventLog.events
        assertOrdered(
            [
                "apple.submit.0",
                "input.release.r13.release.input."
                    + "\(R13ReleaseModePolicy.binding(for: .fast).backendID)"
                    + ".fast.0",
                "media.append.0",
                "preview.encode.0",
                "output.release.0"
            ],
            in: events
        )
        assertOrdered(
            [
                "apple.submit.1",
                "input.release.r13.release.input."
                    + "\(R13ReleaseModePolicy.binding(for: .fast).backendID)"
                    + ".fast.1",
                "media.append.1",
                "output.release.1"
            ],
            in: events
        )
        XCTAssertEqual(previewEncoder.encodedFrameIndices, [0])
        XCTAssertEqual(
            previewEncoder.presentationTransforms,
            [presentationTransform]
        )
        XCTAssertFalse(events.contains("media.cancel"))
    }

    func testPreviewEncoderCopiesBoundedImmutableSourceAndProcessedImages()
        throws {
        let sourceRecord = try R13ReleaseTestFrames.make(
            resolution: VideoResolution(width: 16, height: 8),
            index: 7
        )
        let processed = try R13ReleaseTestFrames.makeOutput(
            resolution: VideoResolution(width: 32, height: 16)
        )
        try fillNV12(
            sourceRecord.pixelBuffer,
            luma: 32,
            chroma: 128
        )
        try fillNV12(
            processed,
            luma: 224,
            chroma: 128
        )
        let encoder = R13PreviewFrameEncoder()
        let uhdPreviewDimensions = R13PreviewFrameEncoder.previewDimensions(
            width: 3_840,
            height: 2_160
        )

        let preview = try encoder.encode(
            source: sourceRecord.pixelBuffer,
            processed: processed,
            sourcePresentationResolution:
                VideoResolution(width: 16, height: 8),
            frameIndex: 7,
            presentationSeconds: 1.25,
            presentationTransform: .identity
        )
        let copiedSource = preview.source.rgba8
        let copiedProcessed = preview.processed.rgba8

        XCTAssertEqual(preview.frameIndex, 7)
        XCTAssertEqual(preview.presentationSeconds, 1.25)
        XCTAssertEqual(preview.source.width, 16)
        XCTAssertEqual(preview.source.height, 8)
        XCTAssertEqual(preview.processed.width, 16)
        XCTAssertEqual(preview.processed.height, 8)
        XCTAssertEqual(uhdPreviewDimensions.width, 960)
        XCTAssertEqual(uhdPreviewDimensions.height, 540)
        XCTAssertEqual(
            uhdPreviewDimensions.width
                * uhdPreviewDimensions.height
                * UpscalePreviewImage.bytesPerPixel,
            2_073_600
        )
        XCTAssertNil(
            UpscalePreviewImage(
                width: UpscalePreviewImage.maximumWidth + 1,
                height: 1,
                rgba8: Data()
            )
        )
        XCTAssertEqual(
            preview.source.rgba8.count,
            16 * 8 * UpscalePreviewImage.bytesPerPixel
        )
        XCTAssertEqual(
            preview.processed.rgba8.count,
            16 * 8 * UpscalePreviewImage.bytesPerPixel
        )
        XCTAssertLessThanOrEqual(
            preview.source.width,
            UpscalePreviewImage.maximumWidth
        )
        XCTAssertLessThanOrEqual(
            preview.source.height,
            UpscalePreviewImage.maximumHeight
        )
        XCTAssertNotEqual(copiedSource, copiedProcessed)
        XCTAssertNotNil(preview.source.makeCGImage())
        XCTAssertNotNil(preview.processed.makeCGImage())

        try fillNV12(
            sourceRecord.pixelBuffer,
            luma: 224,
            chroma: 128
        )
        try fillNV12(
            processed,
            luma: 32,
            chroma: 128
        )

        XCTAssertEqual(preview.source.rgba8, copiedSource)
        XCTAssertEqual(preview.processed.rgba8, copiedProcessed)
    }

    func testPreviewEncoderAppliesAsymmetricPresentationTransformToBothImages()
        throws {
        let source = try makeHorizontalGrayscalePair(dark: 24, light: 224)
        let processed = try makeHorizontalGrayscalePair(
            dark: 48,
            light: 200
        )
        let transform = CGAffineTransform(
            a: 0,
            b: 1,
            c: -1,
            d: 0,
            tx: 19,
            ty: -7
        )

        let preview = try R13PreviewFrameEncoder().encode(
            source: source,
            processed: processed,
            sourcePresentationResolution:
                VideoResolution(width: 2, height: 1),
            frameIndex: 4,
            presentationSeconds: 0.25,
            presentationTransform: transform
        )

        XCTAssertEqual(preview.source.width, 1)
        XCTAssertEqual(preview.source.height, 2)
        XCTAssertEqual(preview.processed.width, 1)
        XCTAssertEqual(preview.processed.height, 2)
        let sourceFirst = Int(preview.source.rgba8[0])
        let sourceSecond = Int(preview.source.rgba8[4])
        let processedFirst = Int(preview.processed.rgba8[0])
        let processedSecond = Int(preview.processed.rgba8[4])
        XCTAssertGreaterThan(abs(sourceFirst - sourceSecond), 100)
        XCTAssertGreaterThan(abs(processedFirst - processedSecond), 100)
        XCTAssertGreaterThan(
            (sourceFirst - sourceSecond)
                * (processedFirst - processedSecond),
            0,
            "Both sides must apply the same presentation orientation."
        )
    }

    func testPreviewEmitterLazilyCopiesSamplesAtBoundedRateAndKeepsNewest()
        async throws {
        let encoder = R13RecordingPreviewEncoder()
        let emitter = R13UpscalePreviewEmitter(
            encoder: encoder,
            minimumSampleInterval: 0.5,
            minimumWallClockIntervalNanoseconds: 0
        )
        let source = try R13ReleaseTestFrames.makeOutput(
            resolution: VideoResolution(width: 16, height: 8)
        )
        let processed = try R13ReleaseTestFrames.makeOutput(
            resolution: VideoResolution(width: 32, height: 16)
        )
        let samples: [(index: Int, time: CMTime)] = [
            (0, CMTime(value: 0, timescale: 100)),
            (1, CMTime(value: 10, timescale: 100)),
            (2, CMTime(value: 49, timescale: 100)),
            (3, CMTime(value: 50, timescale: 100)),
            (4, CMTime(value: 75, timescale: 100)),
            (5, CMTime(value: 100, timescale: 100))
        ]
        var requestedSourceFrameIndices: [Int] = []

        for sample in samples {
            emitter.offer(
                source: {
                    requestedSourceFrameIndices.append(sample.index)
                    return source
                },
                processed: processed,
                sourcePresentationResolution:
                    VideoResolution(width: 16, height: 8),
                frameIndex: sample.index,
                presentationTime: sample.time,
                presentationTransform: .identity
            )
        }

        XCTAssertEqual(
            encoder.encodedFrameIndices,
            [0, 3, 5],
            "Encoding must be complete when offer returns; no pixel buffer "
                + "may escape into deferred preview work."
        )
        XCTAssertEqual(
            requestedSourceFrameIndices,
            [0, 3, 5],
            "Source normalization must run only for frames selected by the "
                + "preview sampling gate."
        )

        emitter.finish()
        var iterator = emitter.stream.makeAsyncIterator()
        let delivered = await iterator.next()
        let afterFinish = await iterator.next()

        XCTAssertEqual(delivered?.frameIndex, 5)
        XCTAssertNil(afterFinish)
    }

    func testPreviewEmitterAlsoBoundsWorkByInjectedMonotonicWallClock()
        throws {
        let encoder = R13RecordingPreviewEncoder()
        let clock = OSAllocatedUnfairLock<UInt64>(initialState: 0)
        let emitter = R13UpscalePreviewEmitter(
            encoder: encoder,
            minimumSampleInterval: 0,
            minimumWallClockIntervalNanoseconds: 500,
            monotonicTimeNanoseconds: {
                clock.withLock { $0 }
            }
        )
        let source = try R13ReleaseTestFrames.makeOutput(
            resolution: VideoResolution(width: 16, height: 8)
        )
        let processed = try R13ReleaseTestFrames.makeOutput(
            resolution: VideoResolution(width: 32, height: 16)
        )
        struct PreviewTimingSample {
            let index: Int
            let mediaValue: Int64
            let wallValue: UInt64
        }
        let samples = [
            PreviewTimingSample(index: 0, mediaValue: 0, wallValue: 0),
            PreviewTimingSample(index: 1, mediaValue: 1, wallValue: 100),
            PreviewTimingSample(index: 2, mediaValue: 2, wallValue: 499),
            PreviewTimingSample(index: 3, mediaValue: 3, wallValue: 500),
            PreviewTimingSample(index: 4, mediaValue: 4, wallValue: 1_000)
        ]

        for sample in samples {
            clock.withLock { $0 = sample.wallValue }
            emitter.offer(
                source: { source },
                processed: processed,
                sourcePresentationResolution:
                    VideoResolution(width: 16, height: 8),
                frameIndex: sample.index,
                presentationTime: CMTime(
                    value: sample.mediaValue,
                    timescale: 1
                ),
                presentationTransform: .identity
            )
        }

        XCTAssertEqual(encoder.encodedFrameIndices, [0, 3, 4])
    }

    func testPreviewEmitterReleasesAnamorphicCacheReplaySourceEachSample()
        throws {
        let failures = OSAllocatedUnfairLock<
            [R13PreviewEncodingFailure]
        >(initialState: [])
        let emitter = R13UpscalePreviewEmitter(
            minimumSampleInterval: 0,
            minimumWallClockIntervalNanoseconds: 0,
            failureObserver: { failure in
                failures.withLock { $0.append(failure) }
            }
        )
        let codedResolution = VideoResolution(width: 12, height: 8)
        let presentationResolution = VideoResolution(width: 16, height: 8)
        let pixelAspectRatio = try XCTUnwrap(
            VideoPixelAspectRatio(
                horizontalSpacing: 4,
                verticalSpacing: 3
            )
        )
        let source = try R13ReleaseTestFrames.makeOutput(
            resolution: codedResolution
        )
        let pixelAspectAttachment = [
            kCVImageBufferPixelAspectRatioHorizontalSpacingKey as String:
                NSNumber(value: pixelAspectRatio.horizontalSpacing),
            kCVImageBufferPixelAspectRatioVerticalSpacingKey as String:
                NSNumber(value: pixelAspectRatio.verticalSpacing)
        ] as CFDictionary
        CVBufferSetAttachment(
            source,
            kCVImageBufferPixelAspectRatioKey,
            pixelAspectAttachment,
            .shouldPropagate
        )
        let processed = try R13ReleaseTestFrames.makeOutput(
            resolution: VideoResolution(width: 32, height: 16)
        )
        let normalizer = R13NV12FrameNormalizer()

        for frameIndex in 0..<128 {
            emitter.offer(
                source: {
                    try normalizer.normalize(
                        source,
                        codedResolution: codedResolution,
                        presentationResolution: presentationResolution,
                        pixelAspectRatio: pixelAspectRatio
                    )
                },
                processed: processed,
                sourcePresentationResolution:
                    presentationResolution,
                frameIndex: frameIndex,
                presentationTime: CMTime(
                    value: Int64(frameIndex),
                    timescale: 1
                ),
                presentationTransform: .identity
            )
        }

        XCTAssertTrue(
            failures.withLock { $0 }.isEmpty,
            "All 128 cache-replay preview samples must release their "
                + "anamorphic normalized source before the next sample."
        )
    }

    func testAppendFailureCannotPublishUnwrittenBackendPreview() async throws {
        let eventLog = R13ReleaseTestEventLog()
        let previewEncoder = R13RecordingPreviewEncoder(eventLog: eventLog)
        let media = R13ReleaseTestMediaPipeline(
            resolution: .p720,
            frames: [
                try R13ReleaseTestFrames.make(
                    resolution: .p720,
                    index: 0
                )
            ],
            eventLog: eventLog,
            appendFailureFrameIndex: 0
        )
        let factory = R13ReleaseTestSessionFactory(
            behavior: .processed,
            eventLog: eventLog
        )
        let service = R13ReleaseUpscalerEngineService(
            media: media,
            modeAwareSessionFactory: { [factory] route, modeBinding in
                try await factory.make(
                    route: route,
                    modeBinding: modeBinding
                )
            },
            previewEncoder: previewEncoder
        )
        let handle = try service.submit(
            makeJob(
                identifier: "r13-preview-after-append",
                target: .p1080,
                mode: .deterministic
            )
        )

        do {
            _ = try await handle.waitForCompletion()
            XCTFail("The injected append failure must terminate the job.")
        } catch let error as R13ReleaseTestMediaSessionError {
            XCTAssertEqual(error, .appendFailed(frameIndex: 0))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertTrue(previewEncoder.encodedFrameIndices.isEmpty)
        XCTAssertTrue(eventLog.contains("media.append.failed.0"))
        XCTAssertFalse(eventLog.contains("preview.encode.0"))
    }

    func testPreviewSourcePreparationFailureIsNonfatalStructuredAndRetried()
        throws {
        let encoder = R13RecordingPreviewEncoder()
        let failures = OSAllocatedUnfairLock<
            [R13PreviewEncodingFailure]
        >(initialState: [])
        let emitter = R13UpscalePreviewEmitter(
            encoder: encoder,
            failureObserver: { failure in
                failures.withLock { $0.append(failure) }
            }
        )
        let processed = try R13ReleaseTestFrames.makeOutput(
            resolution: VideoResolution(width: 32, height: 16)
        )
        let source = try R13ReleaseTestFrames.makeOutput(
            resolution: VideoResolution(width: 16, height: 8)
        )

        emitter.offer(
            source: {
                throw R13PreviewTestError.sourcePreparationFailed
            },
            processed: processed,
            sourcePresentationResolution:
                VideoResolution(width: 16, height: 8),
            frameIndex: 11,
            presentationTime: .zero,
            presentationTransform: .identity
        )
        emitter.offer(
            source: { source },
            processed: processed,
            sourcePresentationResolution:
                VideoResolution(width: 16, height: 8),
            frameIndex: 12,
            presentationTime: CMTime(value: 1, timescale: 100),
            presentationTransform: .identity
        )

        XCTAssertEqual(
            encoder.encodedFrameIndices,
            [12],
            "A failed attempt must not consume the next sampling window."
        )
        XCTAssertEqual(
            failures.withLock { $0 },
            [
                R13PreviewEncodingFailure(
                    frameIndex: 11,
                    stage: .sourcePreparation,
                    underlyingError:
                        R13PreviewTestError.sourcePreparationFailed
                )
            ]
        )
    }

    func testPreviewSourcePoolExhaustionPreservesTypedDiagnosticDetails()
        throws {
        let failures = OSAllocatedUnfairLock<
            [R13PreviewEncodingFailure]
        >(initialState: [])
        let emitter = R13UpscalePreviewEmitter(
            encoder: R13RecordingPreviewEncoder(),
            failureObserver: { failure in
                failures.withLock { $0.append(failure) }
            }
        )
        let processed = try R13ReleaseTestFrames.makeOutput(
            resolution: VideoResolution(width: 32, height: 16)
        )

        emitter.offer(
            source: {
                throw PixelBufferBridgeError.poolDequeueFailed(
                    kCVReturnWouldExceedAllocationThreshold
                )
            },
            processed: processed,
            sourcePresentationResolution:
                VideoResolution(width: 16, height: 8),
            frameIndex: 17,
            presentationTime: .zero,
            presentationTransform: .identity
        )

        let failure = try XCTUnwrap(failures.withLock { $0.first })
        let fields = Dictionary(
            uniqueKeysWithValues: failure.diagnosticFields.map {
                ($0.key.rawValue, $0.value.displayValue)
            }
        )
        let identity = MirmirDiagnosticErrorIdentity(failure)

        XCTAssertEqual(failure.stage, .sourcePreparation)
        XCTAssertEqual(
            failure.reasonCode,
            "source_pool_allocation_threshold_exceeded"
        )
        XCTAssertEqual(fields["frame_index"], "17")
        XCTAssertEqual(
            fields["preview_failure_stage"],
            "source_preparation"
        )
        XCTAssertEqual(
            fields["preview_failure_reason"],
            "source_pool_allocation_threshold_exceeded"
        )
        XCTAssertEqual(
            fields["preview_underlying_error_type"],
            "pixel_buffer_bridge_error"
        )
        XCTAssertEqual(fields["preview_status_code"], "-6689")
        XCTAssertTrue(
            identity.frames.contains {
                $0.domain
                    == (PixelBufferBridgeError.poolDequeueFailed(
                        kCVReturnWouldExceedAllocationThreshold
                    ) as NSError).domain
            }
        )
    }

    func testPreviewEncodingFailureIsDiagnosticWarningWithoutFailingJob()
        async throws {
        let eventLog = R13ReleaseTestEventLog()
        let media = R13ReleaseTestMediaPipeline(
            resolution: .p720,
            frames: [
                try R13ReleaseTestFrames.make(
                    resolution: .p720,
                    index: 0
                )
            ],
            eventLog: eventLog
        )
        let factory = R13ReleaseTestSessionFactory(
            behavior: .processed,
            eventLog: eventLog
        )
        let diagnostics = MirmirDiagnosticStore()
        let service = R13ReleaseUpscalerEngineService(
            media: media,
            modeAwareSessionFactory: { [factory] route, modeBinding in
                try await factory.make(
                    route: route,
                    modeBinding: modeBinding
                )
            },
            previewEncoder: R13FailingPreviewEncoder(),
            diagnostics: diagnostics
        )
        let handle = try service.submit(
            makeJob(
                identifier: "r13-preview-diagnostic",
                target: .p1080,
                mode: .deterministic
            )
        )

        let output = try await handle.waitForCompletion()
        let diagnostic = try await waitForDiagnostic(
            code: "release_preview_encoding_failed",
            in: diagnostics
        )
        let fields = Dictionary(
            uniqueKeysWithValues: diagnostic.event.fields.map {
                ($0.key.rawValue, $0.value.displayValue)
            }
        )

        XCTAssertEqual(
            output.lastPathComponent,
            "r13-preview-diagnostic.mp4"
        )
        XCTAssertEqual(diagnostic.event.severity, .warning)
        XCTAssertEqual(
            fields["failure_category"],
            "preview_encoding_failed"
        )
        XCTAssertEqual(fields["frame_index"], "0")
        XCTAssertEqual(
            fields["preview_failure_reason"],
            "bitmap_allocation_failed"
        )
        XCTAssertEqual(
            fields["preview_failure_stage"],
            "frame_encoding"
        )
        XCTAssertEqual(
            fields["preview_underlying_error_type"],
            "preview_frame_encoding_error"
        )
        XCTAssertNotNil(diagnostic.event.error)
    }

    func testGeometryFailureDiagnosticCapturesActualAndExpectedDimensions()
        async throws {
        let eventLog = R13ReleaseTestEventLog()
        let decodedResolution = VideoResolution(
            width: 1_440,
            height: 1_080
        )
        let media = R13ReleaseTestMediaPipeline(
            resolution: .p1080,
            frames: [
                try R13ReleaseTestFrames.make(
                    resolution: decodedResolution,
                    index: 0
                )
            ],
            eventLog: eventLog
        )
        let factory = R13ReleaseTestSessionFactory(
            behavior: .processed,
            eventLog: eventLog
        )
        let diagnostics = MirmirDiagnosticStore()
        let service = R13ReleaseUpscalerEngineService(
            media: media,
            modeAwareSessionFactory: { [factory] route, modeBinding in
                try await factory.make(
                    route: route,
                    modeBinding: modeBinding
                )
            },
            diagnostics: diagnostics
        )
        let handle = try service.submit(
            makeJob(
                identifier: "r13-decoded-geometry-mismatch",
                target: .p2160,
                mode: .deterministic
            )
        )

        do {
            _ = try await handle.waitForCompletion()
            XCTFail("Decoded geometry mismatch must fail normalization.")
        } catch let error as R03NV12ScalingError {
            XCTAssertEqual(
                error,
                .invalidDimensions(
                    expectedWidth: 1_920,
                    expectedHeight: 1_080,
                    actualWidth: 1_440,
                    actualHeight: 1_080
                )
            )
        } catch {
            XCTFail("Unexpected engine error: \(error)")
        }

        let mismatch = try await waitForDiagnostic(
            code: "release_first_decoded_frame_geometry_mismatch",
            in: diagnostics
        )
        let frameFailure = try await waitForDiagnostic(
            code: "release_frame_processing_failed",
            in: diagnostics
        )
        let mismatchFields = Dictionary(
            uniqueKeysWithValues: mismatch.event.fields.map {
                ($0.key.rawValue, $0.value.displayValue)
            }
        )
        let failureFields = Dictionary(
            uniqueKeysWithValues: frameFailure.event.fields.map {
                ($0.key.rawValue, $0.value.displayValue)
            }
        )

        XCTAssertEqual(
            mismatchFields["actual_decoded_dimensions"],
            "1440x1080"
        )
        XCTAssertEqual(
            mismatchFields["expected_normalized_dimensions"],
            "1920x1080"
        )
        XCTAssertEqual(
            failureFields["actual_decoded_dimensions"],
            "1440x1080"
        )
        XCTAssertEqual(
            failureFields["expected_normalized_dimensions"],
            "1920x1080"
        )
        XCTAssertEqual(
            failureFields["error_actual_dimensions"],
            "1440x1080"
        )
        XCTAssertEqual(
            failureFields["error_expected_dimensions"],
            "1920x1080"
        )
        XCTAssertEqual(failureFields["failure_category"], "invalid_dimensions")

        let snapshot = try await diagnostics.snapshot()
        let terminalCodes = snapshot.records.map(\.event.code.rawValue).filter {
            [
                "release_job_completed",
                "release_job_cancelled",
                "release_job_failed"
            ].contains($0)
        }
        XCTAssertEqual(terminalCodes, ["release_job_failed"])
        let appleSession = try XCTUnwrap(factory.session(for: .scale2x))
        let appleSnapshot = await appleSession.snapshot()
        XCTAssertEqual(appleSnapshot.submittedSequenceNumbers, [])
        XCTAssertGreaterThanOrEqual(appleSnapshot.cancelCount, 1)
        XCTAssertGreaterThanOrEqual(
            try XCTUnwrap(media.lastSession).cancelCount,
            1
        )
    }

    func testBackendFailureDiagnosticPreservesTypedRootCause()
        async throws {
        let eventLog = R13ReleaseTestEventLog()
        let media = R13ReleaseTestMediaPipeline(
            resolution: .p1080,
            frames: [
                try R13ReleaseTestFrames.make(
                    resolution: .p1080,
                    index: 0
                )
            ],
            eventLog: eventLog
        )
        let failureContext = AppleUpscaleBackendFailureContext(
            stage: .outputBufferAllocation,
            statusCode: Int(kCVReturnWouldExceedAllocationThreshold)
        )
        let factory = R13ReleaseTestSessionFactory(
            behavior: .failed(
                reason:
                    "r03_output_pool_allocation_threshold_exceeded",
                context: failureContext
            ),
            eventLog: eventLog
        )
        let diagnostics = MirmirDiagnosticStore()
        let service = R13ReleaseUpscalerEngineService(
            media: media,
            modeAwareSessionFactory: { [factory] route, modeBinding in
                try await factory.make(
                    route: route,
                    modeBinding: modeBinding
                )
            },
            diagnostics: diagnostics
        )
        let handle = try service.submit(
            makeJob(
                identifier: "r13-typed-backend-failure",
                target: .p2160,
                mode: .deterministic
            )
        )

        do {
            _ = try await handle.waitForCompletion()
            XCTFail("The injected backend failure must terminate the job.")
        } catch let error as R13BackendFrameProcessingError {
            XCTAssertEqual(error.frameIndex, 0)
            XCTAssertEqual(
                error.failure.reason,
                "r03_output_pool_allocation_threshold_exceeded"
            )
            XCTAssertEqual(error.failure.context, failureContext)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let record = try await waitForDiagnostic(
            code: "release_frame_processing_failed",
            in: diagnostics
        )
        assertBackendFailureDiagnostic(record)
    }

    private func assertBackendFailureDiagnostic(
        _ record: MirmirDiagnosticRecord,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let fields = Dictionary(
            uniqueKeysWithValues: record.event.fields.map {
                ($0.key.rawValue, $0.value.displayValue)
            }
        )
        XCTAssertEqual(
            fields["failure_category"],
            "backend_frame_processing_failed",
            file: file,
            line: line
        )
        XCTAssertEqual(
            fields["backend_failure_reason"],
            "r03_output_pool_allocation_threshold_exceeded",
            file: file,
            line: line
        )
        XCTAssertEqual(
            fields["backend_failure_stage"],
            "output_buffer_allocation",
            file: file,
            line: line
        )
        XCTAssertEqual(
            fields["backend_status_code"],
            String(kCVReturnWouldExceedAllocationThreshold),
            file: file,
            line: line
        )
        XCTAssertEqual(fields["frame_index"], "0", file: file, line: line)
        XCTAssertEqual(
            record.event.error?.frames.count,
            2,
            file: file,
            line: line
        )
    }

    func testCancellationCancelsBothSessionsAndReleasesPendingInput() async throws {
        let eventLog = R13ReleaseTestEventLog()
        let media = R13ReleaseTestMediaPipeline(
            resolution: .p720,
            frames: [
                try R13ReleaseTestFrames.make(resolution: .p720, index: 0)
            ],
            eventLog: eventLog
        )
        let factory = R13ReleaseTestSessionFactory(
            behavior: .suspendUntilCancelled,
            eventLog: eventLog
        )
        let service = R13ReleaseUpscalerEngineService(
            media: media,
            modeAwareSessionFactory: { [factory] route, modeBinding in
                try await factory.make(
                    route: route,
                    modeBinding: modeBinding
                )
            },
            inputReleaseObserver: { [eventLog] identity in
                eventLog.record("input.release.\(identity)")
            }
        )
        let handle = try service.submit(
            makeJob(
                identifier: "r13-cancel",
                target: .p1080,
                mode: .quality
            )
        )
        try await waitForEvent("apple.submit.0", in: eventLog)

        handle.cancel()

        do {
            _ = try await handle.waitForCompletion()
            XCTFail("Cancellation must terminate the release job.")
        } catch let error as UpscalerEngineError {
            guard case .cancelled = error else {
                return XCTFail("Unexpected engine error: \(error)")
            }
        }
        let mediaSession = try XCTUnwrap(media.lastSession)
        XCTAssertGreaterThanOrEqual(mediaSession.cancelCount, 1)
        XCTAssertTrue(mediaSession.appendedFrameIndices.isEmpty)
        let appleSession = try XCTUnwrap(factory.session(for: .scale3Over2))
        let snapshot = await appleSession.snapshot()
        XCTAssertGreaterThanOrEqual(snapshot.cancelCount, 1)
        XCTAssertTrue(
            eventLog.contains(
                "input.release.r13.release.input."
                    + "\(R13ReleaseModePolicy.binding(for: .quality).backendID)"
                    + ".quality.0"
            )
        )
        XCTAssertFalse(eventLog.contains("output.release.0"))
    }

    func testConcurrentSubmissionDiagnosticCapturesActiveState() async throws {
        let eventLog = R13ReleaseTestEventLog()
        let media = R13ReleaseTestMediaPipeline(
            resolution: .p720,
            frames: [
                try R13ReleaseTestFrames.make(resolution: .p720, index: 0)
            ],
            eventLog: eventLog
        )
        let factory = R13ReleaseTestSessionFactory(
            behavior: .suspendUntilCancelled,
            eventLog: eventLog
        )
        let diagnostics = MirmirDiagnosticStore()
        let service = R13ReleaseUpscalerEngineService(
            media: media,
            modeAwareSessionFactory: { [factory] route, modeBinding in
                try await factory.make(
                    route: route,
                    modeBinding: modeBinding
                )
            },
            diagnostics: diagnostics
        )
        let activeHandle = try service.submit(
            makeJob(
                identifier: "r13-active-diagnostic",
                target: .p1080,
                mode: .quality
            )
        )
        try await waitForEvent("apple.submit.0", in: eventLog)

        XCTAssertThrowsError(
            try service.submit(
                makeJob(
                    identifier: "r13-rejected-diagnostic",
                    target: .p1080,
                    mode: .fast
                )
            )
        ) { error in
            guard let engineError = error as? UpscalerEngineError,
                  case .jobAlreadyRunning = engineError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        do {
            try await service.discardRecoverableJob(
                id: "r13-active-diagnostic"
            )
            XCTFail("An active job must prevent recovery-cache deletion.")
        } catch let error as UpscalerEngineError {
            guard case .jobAlreadyRunning = error else {
                return XCTFail("Unexpected discard error: \(error)")
            }
        }

        let rejected = try await waitForDiagnostic(
            code: "release_job_submit_rejected_already_running",
            in: diagnostics
        )
        let expectedStateField = try MirmirDiagnosticField(
            key: "active_job_state",
            value: MirmirDiagnosticFieldValue.identifier("active")
        )
        XCTAssertEqual(rejected.event.severity, .warning)
        XCTAssertTrue(rejected.event.fields.contains(expectedStateField))

        activeHandle.cancel()
        do {
            _ = try await activeHandle.waitForCompletion()
            XCTFail("Cancellation must terminate the release job.")
        } catch let error as UpscalerEngineError {
            guard case .cancelled = error else {
                return XCTFail("Unexpected engine error: \(error)")
            }
        }
        let snapshot = try await diagnostics.snapshot()
        let terminalCodes = snapshot.records.map(\.event.code.rawValue).filter {
            [
                "release_job_completed",
                "release_job_cancelled",
                "release_job_failed"
            ].contains($0)
        }
        XCTAssertEqual(terminalCodes, ["release_job_cancelled"])
    }

    func testFailedRecoveryDiscardReleasesMaintenanceReservation()
        async throws {
        let eventLog = R13ReleaseTestEventLog()
        let media = R13ReleaseTestMediaPipeline(
            resolution: .p720,
            frames: [],
            eventLog: eventLog
        )
        let factory = R13ReleaseTestSessionFactory(
            behavior: .processed,
            eventLog: eventLog
        )
        let service = makeService(media: media, factory: factory)

        do {
            try await service.discardRecoverableJob(
                id: "r13-missing-recovery"
            )
            XCTFail("A missing hardening runtime must reject deletion.")
        } catch let error as R13RestartJobError {
            guard case .jobMissing(let identifier) = error else {
                return XCTFail("Unexpected discard error: \(error)")
            }
            XCTAssertEqual(identifier, "r13-missing-recovery")
        }

        let handle = try service.submit(
            makeJob(
                identifier: "r13-after-failed-discard",
                target: .p1080,
                mode: .deterministic
            )
        )
        _ = try await handle.waitForCompletion()
    }

    func testHeldDiagnosticJournalLockDoesNotStallJobOrRetainActiveState()
        async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "mirmir-r13-diagnostic-lock-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let diagnostics = try MirmirDiagnosticStore(
            persistentDirectoryURL: directoryURL
        )
        let lockURL = directoryURL.appendingPathComponent(
            MirmirDiagnosticStore.lockFileName,
            isDirectory: false
        )
        var lockDescriptor = open(
            lockURL.path,
            O_RDWR | O_NOFOLLOW | O_CLOEXEC
        )
        guard lockDescriptor >= 0 else {
            return XCTFail("Unable to open the diagnostic journal lock.")
        }
        defer {
            if lockDescriptor >= 0 {
                _ = flock(lockDescriptor, LOCK_UN)
                close(lockDescriptor)
            }
        }
        guard flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            return XCTFail("Unable to acquire the diagnostic journal lock.")
        }

        let eventLog = R13ReleaseTestEventLog()
        let media = R13ReleaseTestMediaPipeline(
            resolution: .p720,
            frames: [],
            eventLog: eventLog
        )
        let factory = R13ReleaseTestSessionFactory(
            behavior: .processed,
            eventLog: eventLog
        )
        let service = R13ReleaseUpscalerEngineService(
            media: media,
            modeAwareSessionFactory: { [factory] route, modeBinding in
                try await factory.make(
                    route: route,
                    modeBinding: modeBinding
                )
            },
            diagnostics: diagnostics
        )
        let handle = try service.submit(
            makeJob(
                identifier: "r13-diagnostic-lock-independence",
                target: .p1080,
                mode: .deterministic
            )
        )
        let completionState = OSAllocatedUnfairLock(
            initialState: R13BoundedJobCompletion.pending
        )
        let completed = expectation(
            description: "Job completes while diagnostic flock remains held."
        )
        let completionTask = Task {
            do {
                let outputURL = try await handle.waitForCompletion()
                completionState.withLock {
                    $0 = .success(outputURL)
                }
            } catch {
                let identity = error as NSError
                completionState.withLock {
                    $0 = .failure(
                        domain: identity.domain,
                        code: identity.code
                    )
                }
            }
            completed.fulfill()
        }
        defer { completionTask.cancel() }

        await fulfillment(of: [completed], timeout: 2)

        switch completionState.withLock({ $0 }) {
        case .pending:
            XCTFail("The job did not terminate before the diagnostic timeout.")
        case .failure(let domain, let code):
            XCTFail("The job failed with \(domain) error \(code).")
        case .success(let outputURL):
            XCTAssertEqual(
                outputURL.lastPathComponent,
                "r13-diagnostic-lock-independence.mp4"
            )
        }
        let activeStateIsIdle = service.activeJobState.withLock { state in
            if case .idle = state {
                return true
            }
            return false
        }
        XCTAssertTrue(
            activeStateIsIdle,
            "Diagnostic persistence retained the active-job reservation."
        )

        XCTAssertEqual(flock(lockDescriptor, LOCK_UN), 0)
        close(lockDescriptor)
        lockDescriptor = -1
        await diagnostics.diagnosticSubmissionQueue.flush()
        let snapshot = try await diagnostics.snapshot()
        XCTAssertEqual(
            snapshot.records.filter {
                $0.event.code.rawValue == "release_job_completed"
            }.count,
            1
        )
    }

    private func makeService(
        media: R13ReleaseTestMediaPipeline,
        factory: R13ReleaseTestSessionFactory
    ) -> R13ReleaseUpscalerEngineService {
        R13ReleaseUpscalerEngineService(
            media: media,
            modeAwareSessionFactory: {
                [factory] route, modeBinding in
                try await factory.make(
                    route: route,
                    modeBinding: modeBinding
                )
            }
        )
    }

    private func runCapturedCanonicalEnhancement(
        identifier: String,
        edge: MirmirAdjustmentLevel,
        detail: MirmirAdjustmentLevel
    ) async throws -> R13NV12Frame {
        let eventLog = R13ReleaseTestEventLog()
        let media = R13ReleaseTestMediaPipeline(
            resolution: .p720,
            frames: [
                try R13ReleaseTestFrames.make(
                    resolution: .p720,
                    index: 0
                )
            ],
            eventLog: eventLog,
            captureAppendedFrames: true
        )
        let factory = R13ReleaseTestSessionFactory(
            behavior: .processed,
            eventLog: eventLog,
            outputFiller: { output, _ in
                try Self.fillEnhancementPattern(output)
            }
        )
        let service = makeService(media: media, factory: factory)
        let job = UpscaleJob(
            identifier: identifier,
            inputURL: try makeInputFixtureURL(
                identifier: identifier
            ),
            outputURL: URL(
                fileURLWithPath: "/tmp/\(identifier).mp4"
            ),
            targetResolution: .p1080,
            preserveAudio: false,
            mode: .deterministic,
            processingConfiguration: UpscaleProcessingConfiguration(
                temporalConsistencyEnabled: false,
                edgeFidelityLevel: edge,
                detailRecoveryLevel: detail
            )
        )

        _ = try await service.submit(job).waitForCompletion()

        return try XCTUnwrap(media.lastSession?.appendedFrames.first)
    }

    private func runCapturedAdaptiveEnhancement(
        identifier: String,
        edge: MirmirAdjustmentLevel,
        detail: MirmirAdjustmentLevel
    ) async throws -> R13NV12Frame {
        let eventLog = R13ReleaseTestEventLog()
        let source = VideoResolution(width: 640, height: 360)
        let target = VideoResolution(width: 1_280, height: 720)
        let media = R13ReleaseTestMediaPipeline(
            resolution: source,
            frames: [
                try R13ReleaseTestFrames.make(
                    resolution: source,
                    index: 0
                )
            ],
            eventLog: eventLog,
            captureAppendedFrames: true
        )
        let factory = R13ReleaseTestSessionFactory(
            behavior: .processed,
            eventLog: eventLog
        )
        let service = R13ReleaseUpscalerEngineService(
            media: media,
            modeAwareSessionFactory: {
                [factory] route, modeBinding in
                try await factory.make(
                    route: route,
                    modeBinding: modeBinding
                )
            },
            adaptiveScalerFactory: { plan in
                R13ReleaseTestAdaptiveScaler(
                    plan: plan,
                    eventLog: eventLog,
                    destinationFiller: {
                        try Self.fillEnhancementPattern($0)
                    }
                )
            }
        )
        let job = UpscaleJob(
            identifier: identifier,
            inputURL: try makeInputFixtureURL(
                identifier: identifier
            ),
            outputURL: URL(
                fileURLWithPath: "/tmp/\(identifier).mp4"
            ),
            targetResolution: target,
            preserveAudio: false,
            mode: .deterministic,
            processingConfiguration: UpscaleProcessingConfiguration(
                temporalConsistencyEnabled: false,
                edgeFidelityLevel: edge,
                detailRecoveryLevel: detail
            )
        )

        _ = try await service.submit(job).waitForCompletion()

        return try XCTUnwrap(media.lastSession?.appendedFrames.first)
    }

    private static func fillEnhancementPattern(
        _ pixelBuffer: CVPixelBuffer
    ) throws {
        let status = CVPixelBufferLockBaseAddress(pixelBuffer, [])
        guard status == kCVReturnSuccess else {
            throw R13PreviewTestError.pixelBufferLockFailed(status)
        }
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        }
        guard let lumaAddress = CVPixelBufferGetBaseAddressOfPlane(
                  pixelBuffer,
                  0
              ),
              let chromaAddress = CVPixelBufferGetBaseAddressOfPlane(
                  pixelBuffer,
                  1
              ) else {
            throw R13PreviewTestError.invalidNV12Planes
        }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(
            pixelBuffer,
            0
        )
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(
            pixelBuffer,
            1
        )
        let luma = lumaAddress.assumingMemoryBound(to: UInt8.self)
        let chroma = chromaAddress.assumingMemoryBound(to: UInt8.self)
        for row in 0..<height {
            for column in 0..<width {
                let texture = (row * 13 + column * 29) % 37
                let edge = column >= width / 2 ? 72 : 0
                luma[row * lumaStride + column] = UInt8(
                    min(235, 48 + texture + edge)
                )
            }
        }
        for row in 0..<(height / 2) {
            memset(
                chroma.advanced(by: row * chromaStride),
                128,
                width
            )
        }
    }

    private func makeJob(
        identifier: String,
        target: VideoResolution,
        mode: UpscaleMode
    ) throws -> UpscaleJob {
        UpscaleJob(
            identifier: identifier,
            inputURL: try makeInputFixtureURL(
                identifier: identifier
            ),
            outputURL: URL(fileURLWithPath: "/tmp/\(identifier).mp4"),
            targetResolution: target,
            preserveAudio: false,
            mode: mode
        )
    }

    private func makeInputFixtureURL(
        identifier: String
    ) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "mirmir-r13-service-source-\(UUID().uuidString)",
                isDirectory: true
            )
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false
            )
            let sourceURL = directory.appendingPathComponent(
                "source.mp4",
                isDirectory: false
            )
            try Data(
                "mirmir-r13-test-source:\(identifier)".utf8
            ).write(to: sourceURL, options: .atomic)
            addTeardownBlock {
                try? FileManager.default.removeItem(at: directory)
            }
            return sourceURL
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func assertOrdered(
        _ orderedEvents: [String],
        in events: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var previousIndex = -1
        for event in orderedEvents {
            guard let index = events.firstIndex(of: event) else {
                XCTFail("Missing event \(event): \(events)", file: file, line: line)
                return
            }
            XCTAssertGreaterThan(
                index,
                previousIndex,
                "Out-of-order event \(event): \(events)",
                file: file,
                line: line
            )
            previousIndex = index
        }
    }

    private func fillNV12(
        _ pixelBuffer: CVPixelBuffer,
        luma: UInt8,
        chroma: UInt8
    ) throws {
        let status = CVPixelBufferLockBaseAddress(pixelBuffer, [])
        guard status == kCVReturnSuccess else {
            throw R13PreviewTestError.pixelBufferLockFailed(status)
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard CVPixelBufferGetPlaneCount(pixelBuffer) == 2,
              let lumaBase = CVPixelBufferGetBaseAddressOfPlane(
                  pixelBuffer,
                  0
              ),
              let chromaBase = CVPixelBufferGetBaseAddressOfPlane(
                  pixelBuffer,
                  1
              ) else {
            throw R13PreviewTestError.invalidNV12Planes
        }
        memset(
            lumaBase,
            Int32(luma),
            CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
                * CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        )
        memset(
            chromaBase,
            Int32(chroma),
            CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
                * CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
        )
    }

    private func makeHorizontalGrayscalePair(
        dark: UInt8,
        light: UInt8
    ) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let createStatus = CVPixelBufferCreate(
            kCFAllocatorDefault,
            2,
            1,
            kCVPixelFormatType_32BGRA,
            nil,
            &pixelBuffer
        )
        guard createStatus == kCVReturnSuccess,
              let pixelBuffer else {
            throw R13PreviewTestError.pixelBufferCreationFailed(createStatus)
        }
        let lockStatus = CVPixelBufferLockBaseAddress(pixelBuffer, [])
        guard lockStatus == kCVReturnSuccess else {
            throw R13PreviewTestError.pixelBufferLockFailed(lockStatus)
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw R13PreviewTestError.invalidPackedPixelBuffer
        }
        let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
        for (pixelIndex, value) in [dark, light].enumerated() {
            let offset = pixelIndex * 4
            bytes[offset] = value
            bytes[offset + 1] = value
            bytes[offset + 2] = value
            bytes[offset + 3] = 255
        }
        return pixelBuffer
    }

    private func waitForEvent(
        _ event: String,
        in eventLog: R13ReleaseTestEventLog
    ) async throws {
        for _ in 0..<200 {
            if eventLog.contains(event) {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for \(event). Events: \(eventLog.events)")
    }

    private func waitForDiagnostic(
        code: String,
        in store: MirmirDiagnosticStore
    ) async throws -> MirmirDiagnosticRecord {
        for _ in 0..<200 {
            let snapshot = try await store.snapshot()
            if let record = snapshot.records.first(
                where: { $0.event.code.rawValue == code }
            ) {
                return record
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        let snapshot = try await store.snapshot()
        return try XCTUnwrap(
            snapshot.records.first {
                $0.event.code.rawValue == code
            },
            "Timed out waiting for diagnostic \(code)."
        )
    }
}

private enum R13BoundedJobCompletion: Sendable {
    case pending
    case success(URL)
    case failure(domain: String, code: Int)
}

private enum R13PreviewTestError: Error {
    case pixelBufferCreationFailed(CVReturn)
    case pixelBufferLockFailed(CVReturn)
    case invalidNV12Planes
    case invalidPackedPixelBuffer
    case sourcePreparationFailed
}

private final class R13RecordingPreviewEncoder:
    R13PreviewFrameEncoding,
    @unchecked Sendable {
    private struct State {
        var frameIndices: [Int] = []
        var presentationTransforms: [CGAffineTransform] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let eventLog: R13ReleaseTestEventLog?

    init(eventLog: R13ReleaseTestEventLog? = nil) {
        self.eventLog = eventLog
    }

    var encodedFrameIndices: [Int] {
        state.withLock { $0.frameIndices }
    }

    var presentationTransforms: [CGAffineTransform] {
        state.withLock { $0.presentationTransforms }
    }

    func encode(
        source _: CVPixelBuffer,
        processed _: CVPixelBuffer,
        sourcePresentationResolution _: VideoResolution,
        frameIndex: Int,
        presentationSeconds: Double,
        presentationTransform: CGAffineTransform
    ) throws -> UpscalePreviewFrame {
        state.withLock {
            $0.frameIndices.append(frameIndex)
            $0.presentationTransforms.append(presentationTransform)
        }
        eventLog?.record("preview.encode.\(frameIndex)")
        let source = try XCTUnwrap(
            UpscalePreviewImage(
                width: 1,
                height: 1,
                rgba8: Data([UInt8(clamping: frameIndex), 0, 0, 255])
            )
        )
        let processed = try XCTUnwrap(
            UpscalePreviewImage(
                width: 1,
                height: 1,
                rgba8: Data([0, UInt8(clamping: frameIndex), 0, 255])
            )
        )
        return try XCTUnwrap(
            UpscalePreviewFrame(
                frameIndex: frameIndex,
                presentationSeconds: presentationSeconds,
                source: source,
                processed: processed
            )
        )
    }
}

private struct R13FailingPreviewEncoder: R13PreviewFrameEncoding {
    func encode(
        source _: CVPixelBuffer,
        processed _: CVPixelBuffer,
        sourcePresentationResolution _: VideoResolution,
        frameIndex _: Int,
        presentationSeconds _: Double,
        presentationTransform _: CGAffineTransform
    ) throws -> UpscalePreviewFrame {
        throw R13PreviewFrameEncodingError.bitmapAllocationFailed
    }
}

// swiftlint:enable file_length type_body_length
