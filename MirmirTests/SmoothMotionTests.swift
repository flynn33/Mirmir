import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import XCTest
@testable import Mirmir

final class SmoothMotionTests: XCTestCase {
    func testCadencePlannerPreservesVariableFrameRateEndpoints()
        throws {
        let source = FrameTiming(
            frameIndex: 7,
            presentationTime: CMTime(value: 100, timescale: 600),
            duration: CMTime(value: 41, timescale: 600)
        )
        let end = CMTime(value: 173, timescale: 600)

        for cadence in SmoothMotionCadence.allCases {
            let timings = try SmoothMotionCadencePlanner(
                cadence: cadence
            ).timings(
                for: source,
                endingAt: end,
                outputStartIndex: 20
            )

            XCTAssertEqual(timings.count, cadence.multiplier)
            XCTAssertEqual(
                timings.map(\.frameIndex),
                Array(20..<(20 + cadence.multiplier))
            )
            XCTAssertEqual(timings.first?.presentationTime, source.presentationTime)
            let last = try XCTUnwrap(timings.last)
            XCTAssertEqual(
                CMTimeAdd(last.presentationTime, last.duration),
                end
            )
            XCTAssertTrue(
                timings.allSatisfy {
                    CMTimeCompare($0.duration, .zero) > 0
                }
            )
        }
    }

    func testDeterministicP010PQBlendPreservesCodesAndAttachments()
        async throws {
        let resolution = VideoResolution(width: 8, height: 4)
        let format = MediaVideoFormat.hdrBT2020PQ(
            masteringDisplayColorVolume: Data([1, 2, 3, 4]),
            contentLightLevelInfo: Data([5, 6, 7, 8])
        )
        let previous = try makeP010Buffer(
            resolution: resolution,
            luma: 64,
            chroma: 64,
            format: format
        )
        let current = try makeP010Buffer(
            resolution: resolution,
            luma: 940,
            chroma: 960,
            format: format
        )
        setLocalTestAttachment(on: previous)
        let interpolator = try SmoothMotionDeterministicInterpolator(
            resolution: resolution,
            pixelFormat: format.pixelStorage.pixelFormat
        )

        let frames = try await interpolator.interpolate(
            previous: previous,
            current: current,
            previousTime: .zero,
            currentTime: CMTime(value: 1, timescale: 30),
            phases: [0.5],
            presentationTimes: [CMTime(value: 1, timescale: 60)]
        )
        let result = try XCTUnwrap(frames.first)

        XCTAssertEqual(
            CVPixelBufferGetPixelFormatType(result),
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        )
        XCTAssertEqual(try p010Code(result, plane: 0), 502)
        XCTAssertEqual(try p010Code(result, plane: 1), 512)
        XCTAssertEqual(try p010Word(result, plane: 0) & 0x3f, 0)
        XCTAssertEqual(try p010Word(result, plane: 1) & 0x3f, 0)
        XCTAssertEqual(
            attachmentDictionary(result, mode: .shouldPropagate),
            attachmentDictionary(previous, mode: .shouldPropagate)
        )
        XCTAssertEqual(
            attachmentDictionary(result, mode: .shouldNotPropagate),
            attachmentDictionary(previous, mode: .shouldNotPropagate)
        )
        XCTAssertNoThrow(try format.validate(pixelBuffer: result))
    }

    func testDeterministicBGRAAlphaBlendPreservesAllChannelsAndMode()
        async throws {
        let resolution = VideoResolution(width: 8, height: 4)
        let format = MediaVideoFormat.sdrBT709WithAlpha(mode: .straight)
        let previous = try makeBGRABuffer(
            resolution: resolution,
            pixel: (20, 40, 60, 80),
            format: format
        )
        let current = try makeBGRABuffer(
            resolution: resolution,
            pixel: (220, 200, 180, 160),
            format: format
        )
        setLocalTestAttachment(on: previous)
        let interpolator = try SmoothMotionDeterministicInterpolator(
            resolution: resolution,
            pixelFormat: format.pixelStorage.pixelFormat
        )

        let frames = try await interpolator.interpolate(
            previous: previous,
            current: current,
            previousTime: .zero,
            currentTime: CMTime(value: 1, timescale: 30),
            phases: [0.5],
            presentationTimes: [CMTime(value: 1, timescale: 60)]
        )
        let result = try XCTUnwrap(frames.first)

        XCTAssertEqual(try bgraPixel(result), [120, 120, 120, 120])
        XCTAssertEqual(
            attachmentDictionary(result, mode: .shouldPropagate),
            attachmentDictionary(previous, mode: .shouldPropagate)
        )
        XCTAssertEqual(
            attachmentDictionary(result, mode: .shouldNotPropagate),
            attachmentDictionary(previous, mode: .shouldNotPropagate)
        )
        XCTAssertNoThrow(try format.validate(pixelBuffer: result))
    }

    func testSceneCutDetectorHandlesP010AndBGRA() throws {
        let resolution = VideoResolution(width: 8, height: 4)
        let p010Format = MediaVideoFormat.hdrBT2020PQ()
        let p010Analysis = try SmoothMotionLumaSceneCutDetector().analyze(
            previous: try makeP010Buffer(
                resolution: resolution,
                luma: 64,
                chroma: 512,
                format: p010Format
            ),
            current: try makeP010Buffer(
                resolution: resolution,
                luma: 940,
                chroma: 512,
                format: p010Format
            ),
            sensitivity: .standard
        )
        XCTAssertTrue(p010Analysis.isSceneCut)

        let bgraFormat =
            MediaVideoFormat.sdrBT709WithAlpha(mode: .premultiplied)
        let bgraAnalysis = try SmoothMotionLumaSceneCutDetector().analyze(
            previous: try makeBGRABuffer(
                resolution: resolution,
                pixel: (0, 0, 0, 255),
                format: bgraFormat
            ),
            current: try makeBGRABuffer(
                resolution: resolution,
                pixel: (255, 255, 255, 255),
                format: bgraFormat
            ),
            sensitivity: .standard
        )
        XCTAssertTrue(bgraAnalysis.isSceneCut)
    }

    func testSceneCutDetectorHandlesEveryRegisteredPixelLayout()
        throws {
        let detector = SmoothMotionLumaSceneCutDetector()
        for pixelFormat in R13PixelLayoutRegistry
            .supportedPixelFormats {
            let layout = try R13PixelLayoutRegistry.layout(
                for: pixelFormat
            )
            let width = max(8, layout.requiredWidthMultiple * 4)
            let height = max(8, layout.requiredHeightMultiple * 4)
            let analysis = try detector.analyze(
                previous:
                    try R13PixelLayoutTestFixtures
                        .makeUniformBuffer(
                            pixelFormat: pixelFormat,
                            width: width,
                            height: height,
                            maximumLuma: false
                        ),
                current:
                    try R13PixelLayoutTestFixtures
                        .makeUniformBuffer(
                            pixelFormat: pixelFormat,
                            width: width,
                            height: height,
                            maximumLuma: true
                        ),
                sensitivity: .standard
            )

            XCTAssertTrue(
                analysis.isSceneCut,
                "format \(pixelFormat)"
            )
            XCTAssertEqual(
                analysis.meanNormalizedLumaDifference,
                1,
                accuracy: 0.000_001,
                "format \(pixelFormat)"
            )
        }
    }

    func testMediaSessionEmitsTwoAndFourTimesCadenceWithoutRetimingAudio()
        async throws {
        let resolution = VideoResolution(width: 8, height: 4)
        for cadence in SmoothMotionCadence.allCases {
            let base = try SmoothMotionRecordingMediaSession(
                resolution: resolution,
                videoFormat: .sdrBT709,
                frameRate: 30,
                sourceDuration: 0.1,
                preserveAudio: true
            )
            let session = try makeDeterministicSession(
                base: base,
                configuration: SmoothMotionConfiguration(
                    cadence: cadence,
                    sceneCutSensitivity: .standard
                )
            )
            for index in 0..<3 {
                try await session.appendOutput(
                    pixelBuffer: try makeNV12Buffer(
                        resolution: resolution,
                        luma: UInt8(32 + index * 16),
                        chroma: 128
                    ),
                    timing: FrameTiming(
                        frameIndex: index,
                        presentationTime: CMTime(
                            value: Int64(index),
                            timescale: 30
                        ),
                        duration: CMTime(value: 1, timescale: 30)
                    )
                )
            }

            let metadata = try await session.finalizedMetadata(base: [:])
            try await session.finish(finalMetadata: metadata)

            XCTAssertEqual(
                base.appendedTimings.count,
                3 * cadence.multiplier
            )
            XCTAssertEqual(
                base.appendedTimings.map(\.frameIndex),
                Array(0..<(3 * cadence.multiplier))
            )
            let last = try XCTUnwrap(base.appendedTimings.last)
            XCTAssertEqual(
                CMTimeAdd(last.presentationTime, last.duration),
                CMTime(value: 3, timescale: 30)
            )
            XCTAssertTrue(base.outputProfile.preserveAudio)
            XCTAssertEqual(
                metadata[
                    SmoothMotionDecisionMetadata
                        .cadenceMultiplierKey
                ],
                String(cadence.multiplier)
            )
            XCTAssertEqual(
                metadata[
                    SmoothMotionDecisionMetadata.outputFrameCountKey
                ],
                String(3 * cadence.multiplier)
            )
            XCTAssertEqual(
                metadata[
                    SmoothMotionDecisionMetadata.outputFrameRateKey
                ],
                String(
                    format: "%.6f",
                    30 * Double(cadence.multiplier)
                )
            )
            XCTAssertEqual(base.finishCount, 1)
        }
    }

    func testSceneCutUsesHoldInsteadOfCrossFrameBlend()
        async throws {
        let resolution = VideoResolution(width: 8, height: 4)
        let base = try SmoothMotionRecordingMediaSession(
            resolution: resolution,
            videoFormat: .sdrBT709,
            frameRate: 30,
            sourceDuration: 2.0 / 30.0,
            preserveAudio: false
        )
        let session = try makeDeterministicSession(
            base: base,
            configuration: SmoothMotionConfiguration(
                cadence: .double,
                sceneCutSensitivity: .standard
            )
        )
        try await session.appendOutput(
            pixelBuffer: try makeNV12Buffer(
                resolution: resolution,
                luma: 16,
                chroma: 128
            ),
            timing: frameTiming(index: 0)
        )
        try await session.appendOutput(
            pixelBuffer: try makeNV12Buffer(
                resolution: resolution,
                luma: 235,
                chroma: 128
            ),
            timing: frameTiming(index: 1)
        )

        _ = try await session.finalizedMetadata(base: [:])

        XCTAssertEqual(session.summary.sceneCutCount, 1)
        XCTAssertEqual(session.summary.interpolatedFrameCount, 0)
        XCTAssertEqual(session.summary.heldFrameCount, 2)
        XCTAssertEqual(base.appendedBuffers.count, 4)
        XCTAssertEqual(try nv12Luma(base.appendedBuffers[1]), 16)
        XCTAssertEqual(try nv12Luma(base.appendedBuffers[2]), 235)
    }

    func testCancellationTerminatesCadenceAndBaseSession()
        async throws {
        let resolution = VideoResolution(width: 8, height: 4)
        let base = try SmoothMotionRecordingMediaSession(
            resolution: resolution,
            videoFormat: .sdrBT709,
            frameRate: 30,
            sourceDuration: 1.0 / 30.0,
            preserveAudio: false
        )
        let session = try makeDeterministicSession(
            base: base,
            configuration: .default
        )
        try await session.appendOutput(
            pixelBuffer: try makeNV12Buffer(
                resolution: resolution,
                luma: 64,
                chroma: 128
            ),
            timing: frameTiming(index: 0)
        )

        session.cancel()

        do {
            _ = try await session.finalizedMetadata(base: [:])
            XCTFail("Cancellation must reject pending cadence flush.")
        } catch {
            XCTAssertEqual(
                error as? SmoothMotionInterpolationError,
                .cancelled
            )
        }
        XCTAssertEqual(base.cancelCount, 1)
        XCTAssertEqual(base.appendedTimings.count, 0)
    }

    func testRecoveryDescriptorRetainsSmoothMotionConfiguration()
        throws {
        let job = smoothMotionJob(
            identifier: "smooth-motion-recovery",
            cadence: .quadruple,
            sensitivity: .high
        )
        let descriptor = try R13RecoveryDescriptor(job: job)
        let data = try R13RestartCanonical.data(descriptor)
        let decoded = try JSONDecoder().decode(
            R13RecoveryDescriptor.self,
            from: data
        )
        let recoverable = try R13RecoverableUpscaleJob(
            descriptor: decoded
        )

        XCTAssertEqual(
            decoded.schemaVersion,
            R13RecoveryDescriptor.currentSchemaVersion
        )
        XCTAssertEqual(
            recoverable.processingConfiguration.smoothMotion,
            SmoothMotionConfiguration(
                cadence: .quadruple,
                sceneCutSensitivity: .high
            )
        )

        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        )
        legacyObject["schema_version"] = 3
        legacyObject.removeValue(forKey: "smooth_motion_cadence")
        legacyObject.removeValue(
            forKey: "smooth_motion_scene_cut_sensitivity"
        )
        legacyObject["mode"] = UpscaleMode.deterministic.rawValue
        let legacyData = try JSONSerialization.data(
            withJSONObject: legacyObject,
            options: [.sortedKeys]
        )
        let legacy = try JSONDecoder().decode(
            R13RecoveryDescriptor.self,
            from: legacyData
        )
        XCTAssertNoThrow(try legacy.validate())
        XCTAssertEqual(
            try R13RecoverableUpscaleJob(descriptor: legacy)
                .processingConfiguration.smoothMotion,
            .default
        )
    }

    func testReleaseIdentityValidatesFinalSmoothMotionMetadata()
        throws {
        let configuration = UpscaleProcessingConfiguration(
            enginePreference: .accelerateVImageHighQuality,
            smoothMotion: SmoothMotionConfiguration(
                cadence: .quadruple,
                sceneCutSensitivity: .high
            )
        )
        let binding = R13ReleaseModePolicy.binding(
            for: .smoothMotion,
            enginePreference: configuration.enginePreference
        )
        let route = R03ScaleRoute.scale3Over2
        let identity = try R13ReleaseIdentity(
            R13ReleaseIdentityInput(
                source: try R13ReleaseSourceBinding(
                    sha256: String(repeating: "1", count: 64),
                    byteCount: 1_024
                ),
                modeBinding: binding,
                output: try R13ReleaseOutputBinding(
                    resolution: route.canonicalTargetResolution,
                    codec: .hevc,
                    preserveAudio: true
                ),
                scalePlan: .productQualified(route),
                routeIdentity:
                    try R13ReleaseIdentity.makeProductRoute(
                        for: route,
                        modeBinding: binding
                    ),
                application: try R13ReleaseApplicationIdentity(
                    bundleIdentifier: "com.mirmir.app",
                    semanticVersion: "1.0.0",
                    buildVersion: "1",
                    executableSHA256:
                        String(repeating: "2", count: 64),
                    executableByteCount: 2_048
                ),
                framework: try R13ReleaseFrameworkIdentity(
                    frameworkIdentifier: binding.frameworkIdentity,
                    version: "26.0",
                    buildIdentity: "25A1"
                ),
                runtime: try R13ReleaseRuntimeIdentity(
                    runtimeIdentifier: "macOS",
                    version: "26.0",
                    buildIdentity: "25A1",
                    architecture: "arm64"
                ),
                policyResources:
                    try R13ReleasePolicyResourceBinding(
                        policySHA256:
                            String(repeating: "3", count: 64),
                        resourceManifestSHA256:
                            String(repeating: "4", count: 64)
                    ),
                fallbackHistory: [],
                processingConfiguration: configuration
            )
        )
        var metadata = identity.timedMetadata
        metadata.merge(
            SmoothMotionDecisionMetadata(
                summary: SmoothMotionProcessingSummary(
                    cadenceMultiplier: 4,
                    sourceFrameCount: 2,
                    outputFrameCount: 8,
                    generatedFrameCount: 6,
                    interpolatedFrameCount: 3,
                    heldFrameCount: 3,
                    sceneCutCount: 0,
                    sceneAnalysisFailureCount: 0,
                    nativeRuntimeFallbackCount: 0,
                    outputFramesPerSecond: 120,
                    route: SmoothMotionInterpolationRoute
                        .deterministicFormatBlend.rawValue,
                    fallbackReason:
                        SmoothMotionNativeAvailabilityReason
                            .supportQueryRejected.rawValue
                )
            ).values
        ) { _, finalized in finalized }

        XCTAssertNoThrow(try identity.validateTimedMetadata(metadata))
        metadata[
            SmoothMotionDecisionMetadata.outputFrameCountKey
        ] = "7"
        XCTAssertThrowsError(
            try identity.validateTimedMetadata(metadata)
        )
    }

    func testReleaseServiceActuallyAppliesSmoothMotionCadence()
        async throws {
        for cadence in SmoothMotionCadence.allCases {
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
            let service = R13ReleaseUpscalerEngineService(
                media: media,
                modeAwareSessionFactory: {
                    [factory] route, modeBinding in
                    try await factory.make(
                        route: route,
                        modeBinding: modeBinding
                    )
                }
            )
            let job = smoothMotionJob(
                identifier: "smooth-motion-service-\(cadence.rawValue)",
                cadence: cadence,
                sensitivity: .standard
            )

            _ = try await service.submit(job).waitForCompletion()

            let session = try XCTUnwrap(media.lastSession)
            XCTAssertEqual(
                session.appendedFrameIndices,
                Array(0..<cadence.multiplier)
            )
            XCTAssertEqual(
                session.finalMetadata[
                    SmoothMotionDecisionMetadata.outputFrameCountKey
                ],
                String(cadence.multiplier)
            )
            let last = try XCTUnwrap(session.appendedTimings.last)
            XCTAssertEqual(
                CMTimeAdd(last.presentationTime, last.duration),
                CMTime(value: 1, timescale: 30)
            )
            XCTAssertTrue(session.outputProfile.preserveAudio)
        }
    }

    func testFormatPreservingReleaseRoutesApplySmoothMotionCadence()
        async throws {
        let resolution = VideoResolution.p720
        let formats: [MediaVideoFormat] = [
            .hdrBT2020PQ(),
            .sdrBT709WithAlpha(mode: .straight)
        ]
        for (formatIndex, format) in formats.enumerated() {
            let eventLog = R13ReleaseTestEventLog()
            let frames: [FrameRecord]
            if format.pixelStorage.pixelFormat
                == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange {
                frames = [
                    FrameRecord(
                        pixelBuffer: try makeP010Buffer(
                            resolution: resolution,
                            luma: 256,
                            chroma: 512,
                            format: format
                        ),
                        timing: frameTiming(index: 0)
                    ),
                    FrameRecord(
                        pixelBuffer: try makeP010Buffer(
                            resolution: resolution,
                            luma: 320,
                            chroma: 544,
                            format: format
                        ),
                        timing: frameTiming(index: 1)
                    )
                ]
            } else {
                frames = [
                    FrameRecord(
                        pixelBuffer: try makeBGRABuffer(
                            resolution: resolution,
                            pixel: (48, 64, 80, 96),
                            format: format
                        ),
                        timing: frameTiming(index: 0)
                    ),
                    FrameRecord(
                        pixelBuffer: try makeBGRABuffer(
                            resolution: resolution,
                            pixel: (64, 80, 96, 112),
                            format: format
                        ),
                        timing: frameTiming(index: 1)
                    )
                ]
            }
            let media = R13ReleaseTestMediaPipeline(
                resolution: resolution,
                frames: frames,
                eventLog: eventLog,
                videoFormat: format
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
                }
            )
            let job = smoothMotionJob(
                identifier:
                    "smooth-motion-format-\(formatIndex)",
                cadence: .double,
                sensitivity: .standard
            )

            _ = try await service.submit(job).waitForCompletion()

            let session = try XCTUnwrap(media.lastSession)
            XCTAssertEqual(session.appendedFrameIndices, [0, 1, 2, 3])
            XCTAssertEqual(session.outputProfile.videoFormat, format)
            XCTAssertEqual(
                session.finalMetadata[
                    SmoothMotionDecisionMetadata.outputFrameCountKey
                ],
                "4"
            )
            XCTAssertNotEqual(
                session.finalMetadata[
                    SmoothMotionDecisionMetadata.routeKey
                ],
                "pending"
            )
        }
    }

    func testAVFoundationCadencePreservesAudioAndContainerDuration()
        async throws {
        for cadence in SmoothMotionCadence.allCases {
            let fixture = try MediaOutputFixture()
            defer { fixture.remove() }
            let videoURL = fixture.directory.appendingPathComponent(
                "smooth-motion-video.mp4"
            )
            let audioURL = fixture.directory.appendingPathComponent(
                "smooth-motion-audio.m4a"
            )
            let resolution = VideoResolution(width: 64, height: 64)
            try await writeVideoFrames(
                to: videoURL,
                resolution: resolution,
                frameCount: 3,
                frameDuration: CMTime(value: 1, timescale: 30)
            )
            try writeAACFixture(
                to: audioURL,
                frameCount: 12_000
            )
            try await muxVideoAndAAC(
                videoURL: videoURL,
                audioURL: audioURL,
                destinationURL: fixture.source,
                preserveExactVideoEndWithMarker: true
            )
            let expectedAudio = try await OutputMediaAACIdentityReader()
                .read(url: fixture.source)
            let sourceAsset = AVURLAsset(
                url: fixture.source,
                options: [
                    AVURLAssetPreferPreciseDurationAndTimingKey: true
                ]
            )
            let sourceDuration = try await sourceAsset.load(.duration)
            let sourceVideoTracks = try await sourceAsset
                .loadTracks(withMediaType: .video)
            let sourceVideoTrack = try XCTUnwrap(
                sourceVideoTracks.first
            )
            let sourceVideoRange = try await sourceVideoTrack
                .load(.timeRange)
            let pipeline = AVFoundationMediaPipeline(
                metal: NoopMetalRenderingService()
            )
            let source = try await pipeline.probe(url: fixture.source)
            let base = try await pipeline.beginSession(
                source: source,
                output: OutputProfile(
                    url: fixture.destination,
                    resolution: resolution,
                    codec: .h264,
                    preserveAudio: true,
                    videoFormat: source.videoFormat,
                    timedMetadataTemplate:
                        SmoothMotionDecisionMetadata.pendingValues
                )
            )
            let fallback = try SmoothMotionDeterministicInterpolator(
                resolution: resolution,
                pixelFormat:
                    base.videoFormat.pixelStorage.pixelFormat
            )
            let session = SmoothMotionMediaSession(
                base: base,
                configuration: SmoothMotionConfiguration(
                    cadence: cadence,
                    sceneCutSensitivity: .standard
                ),
                native: nil,
                nativeUnavailableReason: .supportQueryRejected,
                fallback: fallback,
                sceneCutDetector: SmoothMotionLumaSceneCutDetector()
            )
            defer { session.cancel() }
            var processedSourceFrameCount = 0
            while let record = try await session.nextSourceFrame() {
                try await session.appendOutput(
                    pixelBuffer: record.pixelBuffer,
                    timing: record.timing
                )
                processedSourceFrameCount += 1
            }
            XCTAssertGreaterThan(processedSourceFrameCount, 0)
            let metadata = try await session.finalizedMetadata(base: [:])
            XCTAssertEqual(
                metadata[
                    SmoothMotionDecisionMetadata.sourceFrameCountKey
                ],
                String(processedSourceFrameCount)
            )
            try await session.finish(finalMetadata: metadata)

            let outputAsset = AVURLAsset(
                url: fixture.destination,
                options: [
                    AVURLAssetPreferPreciseDurationAndTimingKey: true
                ]
            )
            let outputVideoTracks = try await outputAsset
                .loadTracks(withMediaType: .video)
            let outputVideoTrack = try XCTUnwrap(
                outputVideoTracks.first
            )
            let outputVideoRange = try await outputVideoTrack
                .load(.timeRange)
            XCTAssertEqual(
                CMTimeCompare(
                    CMTimeRangeGetEnd(outputVideoRange),
                    CMTimeRangeGetEnd(sourceVideoRange)
                ),
                0
            )
            XCTAssertEqual(
                try videoSampleCount(
                    asset: outputAsset,
                    track: outputVideoTrack
                ),
                processedSourceFrameCount * cadence.multiplier
            )
            let outputAudio = try await OutputMediaAACIdentityReader()
                .read(url: fixture.destination)
            XCTAssertEqual(outputAudio, expectedAudio)
            let outputDuration = try await outputAsset.load(.duration)
            XCTAssertEqual(
                CMTimeCompare(
                    outputDuration,
                    sourceDuration
                ),
                0
            )
        }
    }

    func testShippingReleaseServiceExecutesRealSmoothMotionWorkflow()
        async throws {
        for cadence in SmoothMotionCadence.allCases {
            try await assertShippingSmoothMotionWorkflow(
                cadence: cadence
            )
        }
    }
}

private extension SmoothMotionTests {
    func assertShippingSmoothMotionWorkflow(
        cadence: SmoothMotionCadence
    ) async throws {
        let workspace = try R13IntegrationWorkspace(
            outputFileName: "smooth-motion-\(cadence.rawValue).mov"
        )
        defer { workspace.remove() }
        try await writeSmoothMotionSceneCutFixture(
            to: workspace.sourceURL,
            resolution: .p720
        )
        let diagnostics = MirmirDiagnosticStore()
        let media = AVFoundationMediaPipeline(
            metal: NoopMetalRenderingService(),
            diagnostics: diagnostics
        )
        let source = try await media.probe(url: workspace.sourceURL)
        XCTAssertEqual(source.resolution, .p720)
        XCTAssertEqual(source.estimatedFrameCount, 3)
        XCTAssertEqual(source.scanStructure, .progressive)

        let hardening = try R13IntegrationHardeningHarness.make(
            jobsRootURL: workspace.jobsRootURL,
            exactFrameCount: 3
        )
        let configuration = UpscaleProcessingConfiguration(
            temporalConsistencyEnabled: false,
            smoothMotion: SmoothMotionConfiguration(
                cadence: cadence,
                sceneCutSensitivity: .standard
            )
        )
        let job = UpscaleJob(
            identifier: "smooth-motion-real-\(cadence.rawValue)",
            inputURL: workspace.sourceURL,
            outputURL: workspace.outputURL,
            targetResolution: .p1080,
            codec: .h264,
            preserveAudio: false,
            mode: .smoothMotion,
            processingConfiguration: configuration
        )
        let service = R13ReleaseUpscalerEngineService(
            media: media,
            hardeningRuntime: hardening.runtime,
            diagnostics: diagnostics
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: workspace.outputURL.path
            )
        )
        let result = try await service.submit(job).waitForCompletion()

        try await assertSmoothMotionPublishedMedia(
            result: result,
            outputURL: workspace.outputURL,
            jobIdentifier: job.identifier,
            media: media,
            cadence: cadence
        )
        try await assertSmoothMotionReleaseMetadata(
            at: result,
            sourceURL: workspace.sourceURL,
            sourceScanStructure: source.scanStructure,
            job: job,
            configuration: configuration,
            hardening: hardening,
            diagnostics: diagnostics,
            cadence: cadence
        )
        try await assertSmoothMotionDiagnostics(
            hardening: hardening,
            diagnostics: diagnostics
        )
    }

    func assertSmoothMotionPublishedMedia(
        result: URL,
        outputURL: URL,
        jobIdentifier: String,
        media: AVFoundationMediaPipeline,
        cadence: SmoothMotionCadence
    ) async throws {
        XCTAssertEqual(result, outputURL)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: outputURL.path)
        )
        let outputDirectoryEntries = try FileManager.default
            .contentsOfDirectory(
                at: outputURL.deletingLastPathComponent(),
                includingPropertiesForKeys: nil
            )
        XCTAssertFalse(
            outputDirectoryEntries.contains {
                $0.lastPathComponent.contains(
                    ".mirmir-\(jobIdentifier).partial"
                )
            }
        )

        let reopened = try await media.probe(url: result)
        XCTAssertEqual(reopened.resolution, .p1080)
        XCTAssertEqual(reopened.scanStructure, .progressive)
        let decodedFrames = try await readSmoothMotionDecodedFrames(
            at: result
        )
        let sampleTimings = try await readSmoothMotionSampleTimings(
            at: result
        )
        let expectedFrameCount = 3 * cadence.multiplier
        XCTAssertEqual(decodedFrames.count, expectedFrameCount)
        XCTAssertEqual(sampleTimings.count, expectedFrameCount)
        for index in 0..<expectedFrameCount {
            let expectedPresentationTime = CMTime(
                value: Int64(index),
                timescale: CMTimeScale(30 * cadence.multiplier)
            )
            let expectedDuration = CMTime(
                value: 1,
                timescale: CMTimeScale(30 * cadence.multiplier)
            )
            XCTAssertEqual(
                CMTimeCompare(
                    decodedFrames[index].presentationTime,
                    expectedPresentationTime
                ),
                0,
                "cadence \(cadence.rawValue), decoded frame "
                    + "\(index) PTS"
            )
            XCTAssertEqual(
                CMTimeCompare(
                    sampleTimings[index].presentationTime,
                    expectedPresentationTime
                ),
                0,
                "cadence \(cadence.rawValue), compressed sample "
                    + "\(index) PTS"
            )
            XCTAssertEqual(
                CMTimeCompare(
                    sampleTimings[index].duration,
                    expectedDuration
                ),
                0,
                "cadence \(cadence.rawValue), compressed sample "
                    + "\(index) duration actual "
                    + "\(sampleTimings[index].duration.value)/"
                    + "\(sampleTimings[index].duration.timescale), "
                    + "expected \(expectedDuration.value)/"
                    + "\(expectedDuration.timescale)"
            )
        }

        let firstSourceLuma = decodedFrames[0].centerLuma
        let firstInterpolatedLuma = decodedFrames[1].centerLuma
        let secondSourceLuma =
            decodedFrames[cadence.multiplier].centerLuma
        XCTAssertGreaterThan(
            firstInterpolatedLuma,
            firstSourceLuma
        )
        XCTAssertLessThan(
            firstInterpolatedLuma,
            secondSourceLuma
        )
        let heldBeforeCut =
            decodedFrames[(2 * cadence.multiplier) - 1].centerLuma
        let brightScene =
            decodedFrames[2 * cadence.multiplier].centerLuma
        XCTAssertLessThanOrEqual(
            abs(Int(heldBeforeCut) - Int(secondSourceLuma)),
            12
        )
        XCTAssertGreaterThan(
            abs(Int(brightScene) - Int(heldBeforeCut)),
            64
        )
    }

    func assertSmoothMotionReleaseMetadata(
        at result: URL,
        sourceURL: URL,
        sourceScanStructure: MediaVideoScanStructure,
        job: UpscaleJob,
        configuration: UpscaleProcessingConfiguration,
        hardening: R13IntegrationHardeningHarness,
        diagnostics: MirmirDiagnosticStore,
        cadence: SmoothMotionCadence
    ) async throws {
        let metadata = try await readR13ReleaseMetadata(at: result)
        let modeBinding = R13ReleaseModePolicy.binding(
            for: .smoothMotion,
            enginePreference: configuration.enginePreference
        )
        let environment = try R13IntegrationEnvironmentCollector(
            environment: hardening.environment
        ).collect(frameworkIdentity: modeBinding.frameworkIdentity)
        let expectedIdentity = try R13ReleaseHardeningRuntime
            .makeReleaseIdentity(
                job: job,
                scalePlan: try R13ReleaseJobContracts.scalePlan(
                    source: .p720,
                    target: .p1080
                ),
                modeBinding: modeBinding,
                source: try R13LocalRestartSourceMeasurer()
                    .measureSource(at: sourceURL),
                environment: environment,
                policyResources: hardening.documents.policyResources,
                sourceScanStructure: sourceScanStructure
            )
        XCTAssertNoThrow(
            try expectedIdentity.validateTimedMetadata(metadata)
        )
        XCTAssertEqual(
            metadata["com.mirmir.release.requested-mode"],
            UpscaleMode.smoothMotion.rawValue
        )
        XCTAssertEqual(
            metadata["com.mirmir.release.effective-mode"],
            UpscaleMode.smoothMotion.rawValue
        )
        XCTAssertEqual(
            metadata["com.mirmir.release.backend-id"],
            modeBinding.backendID
        )
        try assertSmoothMotionDecisionCounts(
            metadata: metadata,
            cadence: cadence
        )
        try await assertSmoothMotionRouteMetadata(
            metadata: metadata,
            diagnostics: diagnostics
        )
    }

    func assertSmoothMotionDecisionCounts(
        metadata: [String: String],
        cadence: SmoothMotionCadence
    ) throws {
        XCTAssertEqual(
            metadata[
                SmoothMotionDecisionMetadata.cadenceMultiplierKey
            ],
            String(cadence.multiplier)
        )
        XCTAssertEqual(
            metadata[SmoothMotionDecisionMetadata.sourceFrameCountKey],
            "3"
        )
        XCTAssertEqual(
            metadata[SmoothMotionDecisionMetadata.outputFrameCountKey],
            String(3 * cadence.multiplier)
        )
        XCTAssertEqual(
            metadata[
                SmoothMotionDecisionMetadata.generatedFrameCountKey
            ],
            String(3 * (cadence.multiplier - 1))
        )
        XCTAssertEqual(
            metadata[
                SmoothMotionDecisionMetadata.interpolatedFrameCountKey
            ],
            String(cadence.multiplier - 1)
        )
        XCTAssertEqual(
            metadata[SmoothMotionDecisionMetadata.heldFrameCountKey],
            String(2 * (cadence.multiplier - 1))
        )
        XCTAssertEqual(
            metadata[SmoothMotionDecisionMetadata.sceneCutCountKey],
            "1"
        )
        XCTAssertEqual(
            metadata[
                SmoothMotionDecisionMetadata
                    .sceneAnalysisFailureCountKey
            ],
            "0"
        )
        let outputFrameRate = try XCTUnwrap(
            Double(
                metadata[
                    SmoothMotionDecisionMetadata.outputFrameRateKey
                ] ?? ""
            )
        )
        XCTAssertEqual(
            outputFrameRate,
            30 * Double(cadence.multiplier),
            accuracy: 0.000_001
        )
    }

    func assertSmoothMotionRouteMetadata(
        metadata: [String: String],
        diagnostics: MirmirDiagnosticStore
    ) async throws {
        let nativeRuntimeFallbackCount = try XCTUnwrap(
            Int(
                metadata[
                    SmoothMotionDecisionMetadata
                        .nativeRuntimeFallbackCountKey
                ] ?? ""
            )
        )
        XCTAssertGreaterThanOrEqual(nativeRuntimeFallbackCount, 0)
        let interpolationRoute = try XCTUnwrap(
            metadata[SmoothMotionDecisionMetadata.routeKey]
        )
        XCTAssertNotEqual(interpolationRoute, "pending")
        XCTAssertNotEqual(interpolationRoute, "frame_hold_only")
        let usedNativeInterpolation = interpolationRoute.contains(
            SmoothMotionInterpolationRoute
                .videoToolboxLowLatency.rawValue
        )
        let usedDeterministicInterpolation = interpolationRoute.contains(
            SmoothMotionInterpolationRoute
                .deterministicFormatBlend.rawValue
        )
        XCTAssertTrue(
            usedNativeInterpolation || usedDeterministicInterpolation
        )
        let fallbackReason = try XCTUnwrap(
            metadata[SmoothMotionDecisionMetadata.fallbackReasonKey]
        )
        XCTAssertNotEqual(fallbackReason, "pending")
        let diagnosticSnapshot = try await diagnostics.snapshot()
        let runtimeFallbackDiagnosticCount =
            diagnosticSnapshot.records.filter {
                $0.event.code.rawValue
                    == "smooth_motion_native_processing_fallback"
            }.count
        XCTAssertEqual(
            runtimeFallbackDiagnosticCount,
            nativeRuntimeFallbackCount
        )
        if usedNativeInterpolation && !usedDeterministicInterpolation {
            XCTAssertEqual(nativeRuntimeFallbackCount, 0)
            XCTAssertEqual(fallbackReason, "none")
        } else if nativeRuntimeFallbackCount > 0 {
            XCTAssertTrue(usedDeterministicInterpolation)
            XCTAssertEqual(
                fallbackReason,
                "native_processing_failed"
            )
        } else {
            XCTAssertTrue(usedDeterministicInterpolation)
            XCTAssertNotEqual(fallbackReason, "none")
        }
    }

    func assertSmoothMotionDiagnostics(
        hardening: R13IntegrationHardeningHarness,
        diagnostics: MirmirDiagnosticStore
    ) async throws {
        let releaseSnapshot = await hardening.diagnostics.snapshot()
        XCTAssertEqual(
            releaseSnapshot.records.filter {
                $0.event.code == .outputReopened
            }.count,
            1
        )
        XCTAssertEqual(
            releaseSnapshot.records.filter {
                $0.event.code == .jobCompleted
            }.count,
            1
        )
        let diagnosticSnapshot = try await diagnostics.snapshot()
        XCTAssertEqual(
            diagnosticSnapshot.records.filter {
                $0.event.code.rawValue
                    == "smooth_motion_scene_cut_hold"
            }.count,
            1
        )
        XCTAssertEqual(
            diagnosticSnapshot.records.filter {
                $0.event.code.rawValue
                    == "smooth_motion_completed"
            }.count,
            1
        )
    }

    func makeDeterministicSession(
        base: SmoothMotionRecordingMediaSession,
        configuration: SmoothMotionConfiguration
    ) throws -> SmoothMotionMediaSession {
        let fallback = try SmoothMotionDeterministicInterpolator(
            resolution: base.outputProfile.resolution,
            pixelFormat: base.videoFormat.pixelStorage.pixelFormat
        )
        return SmoothMotionMediaSession(
            base: base,
            configuration: configuration,
            native: nil,
            nativeUnavailableReason: .supportQueryRejected,
            fallback: fallback,
            sceneCutDetector: SmoothMotionLumaSceneCutDetector()
        )
    }

    func smoothMotionJob(
        identifier: String,
        cadence: SmoothMotionCadence,
        sensitivity: SmoothMotionSceneCutSensitivity
    ) -> UpscaleJob {
        UpscaleJob(
            identifier: identifier,
            inputURL: URL(
                fileURLWithPath: "/tmp/\(identifier)-input.mp4"
            ),
            outputURL: URL(
                fileURLWithPath: "/tmp/\(identifier).mp4"
            ),
            targetResolution: .p1080,
            codec: .hevc,
            preserveAudio: true,
            mode: .smoothMotion,
            processingConfiguration: UpscaleProcessingConfiguration(
                smoothMotion: SmoothMotionConfiguration(
                    cadence: cadence,
                    sceneCutSensitivity: sensitivity
                )
            )
        )
    }

    func frameTiming(index: Int) -> FrameTiming {
        FrameTiming(
            frameIndex: index,
            presentationTime: CMTime(
                value: Int64(index),
                timescale: 30
            ),
            duration: CMTime(value: 1, timescale: 30)
        )
    }

    func makeNV12Buffer(
        resolution: VideoResolution,
        luma: UInt8,
        chroma: UInt8
    ) throws -> CVPixelBuffer {
        let buffer = try makeBuffer(
            resolution: resolution,
            pixelFormat:
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
        try withLockedBuffer(buffer) {
            for plane in 0..<2 {
                guard let base =
                    CVPixelBufferGetBaseAddressOfPlane(
                        buffer,
                        plane
                    ) else {
                    throw SmoothMotionInterpolationError
                        .inaccessiblePlane(plane)
                }
                let activeBytes =
                    CVPixelBufferGetWidthOfPlane(buffer, plane)
                    * (plane == 0 ? 1 : 2)
                let height =
                    CVPixelBufferGetHeightOfPlane(buffer, plane)
                let stride =
                    CVPixelBufferGetBytesPerRowOfPlane(
                        buffer,
                        plane
                    )
                for row in 0..<height {
                    memset(
                        base.advanced(by: row * stride),
                        Int32(plane == 0 ? luma : chroma),
                        activeBytes
                    )
                }
            }
        }
        MediaVideoFormat.sdrBT709.installAttachments(on: buffer)
        return buffer
    }

    func makeP010Buffer(
        resolution: VideoResolution,
        luma: UInt16,
        chroma: UInt16,
        format: MediaVideoFormat
    ) throws -> CVPixelBuffer {
        let buffer = try makeBuffer(
            resolution: resolution,
            pixelFormat:
                kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        )
        try withLockedBuffer(buffer) {
            for plane in 0..<2 {
                guard let raw =
                    CVPixelBufferGetBaseAddressOfPlane(
                        buffer,
                        plane
                    ) else {
                    throw SmoothMotionInterpolationError
                        .inaccessiblePlane(plane)
                }
                let activeSamples =
                    CVPixelBufferGetWidthOfPlane(buffer, plane)
                    * (plane == 0 ? 1 : 2)
                let height =
                    CVPixelBufferGetHeightOfPlane(buffer, plane)
                let stride =
                    CVPixelBufferGetBytesPerRowOfPlane(
                        buffer,
                        plane
                    ) / MemoryLayout<UInt16>.stride
                let base = raw.assumingMemoryBound(to: UInt16.self)
                let value = (plane == 0 ? luma : chroma) << 6
                for row in 0..<height {
                    let destination =
                        base.advanced(by: row * stride)
                    for column in 0..<activeSamples {
                        destination[column] = value
                    }
                }
            }
        }
        format.installAttachments(on: buffer)
        return buffer
    }

    func makeBGRABuffer(
        resolution: VideoResolution,
        pixel: (UInt8, UInt8, UInt8, UInt8),
        format: MediaVideoFormat
    ) throws -> CVPixelBuffer {
        let buffer = try makeBuffer(
            resolution: resolution,
            pixelFormat: kCVPixelFormatType_32BGRA
        )
        try withLockedBuffer(buffer) {
            guard let raw = CVPixelBufferGetBaseAddress(buffer) else {
                throw SmoothMotionInterpolationError
                    .inaccessiblePlane(0)
            }
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            let base = raw.assumingMemoryBound(to: UInt8.self)
            for row in 0..<resolution.height {
                let destination = base.advanced(by: row * stride)
                for column in 0..<resolution.width {
                    let offset = column * 4
                    destination[offset] = pixel.0
                    destination[offset + 1] = pixel.1
                    destination[offset + 2] = pixel.2
                    destination[offset + 3] = pixel.3
                }
            }
        }
        format.installAttachments(on: buffer)
        return buffer
    }

    func makeBuffer(
        resolution: VideoResolution,
        pixelFormat: OSType
    ) throws -> CVPixelBuffer {
        let pool = try PixelBufferBridge.makePool(
            width: resolution.width,
            height: resolution.height,
            format: pixelFormat,
            capacity: 1
        )
        return try PixelBufferBridge.dequeue(from: pool)
    }

    func withLockedBuffer(
        _ buffer: CVPixelBuffer,
        _ body: () throws -> Void
    ) throws {
        let status = CVPixelBufferLockBaseAddress(buffer, [])
        guard status == kCVReturnSuccess else {
            throw SmoothMotionInterpolationError.lockFailed(status)
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        try body()
    }

    func p010Word(
        _ buffer: CVPixelBuffer,
        plane: Int
    ) throws -> UInt16 {
        var result: UInt16 = 0
        try withLockedReadBuffer(buffer) {
            guard let raw =
                    CVPixelBufferGetBaseAddressOfPlane(buffer, plane)
            else {
                throw SmoothMotionInterpolationError
                    .inaccessiblePlane(plane)
            }
            result = raw.assumingMemoryBound(to: UInt16.self)[0]
        }
        return result
    }

    func p010Code(
        _ buffer: CVPixelBuffer,
        plane: Int
    ) throws -> UInt16 {
        try p010Word(buffer, plane: plane) >> 6
    }

    func bgraPixel(_ buffer: CVPixelBuffer) throws -> [UInt8] {
        var result: [UInt8] = []
        try withLockedReadBuffer(buffer) {
            guard let raw = CVPixelBufferGetBaseAddress(buffer) else {
                throw SmoothMotionInterpolationError
                    .inaccessiblePlane(0)
            }
            let base = raw.assumingMemoryBound(to: UInt8.self)
            result = Array(UnsafeBufferPointer(start: base, count: 4))
        }
        return result
    }

    func nv12Luma(_ buffer: CVPixelBuffer) throws -> UInt8 {
        var result: UInt8 = 0
        try withLockedReadBuffer(buffer) {
            guard let raw =
                    CVPixelBufferGetBaseAddressOfPlane(buffer, 0)
            else {
                throw SmoothMotionInterpolationError
                    .inaccessiblePlane(0)
            }
            result = raw.assumingMemoryBound(to: UInt8.self)[0]
        }
        return result
    }

    func withLockedReadBuffer(
        _ buffer: CVPixelBuffer,
        _ body: () throws -> Void
    ) throws {
        let status = CVPixelBufferLockBaseAddress(buffer, .readOnly)
        guard status == kCVReturnSuccess else {
            throw SmoothMotionInterpolationError.lockFailed(status)
        }
        defer {
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        }
        try body()
    }

    func setLocalTestAttachment(on buffer: CVPixelBuffer) {
        CVBufferSetAttachment(
            buffer,
            "com.mirmir.test.local" as CFString,
            "retained" as CFString,
            .shouldNotPropagate
        )
    }

    func attachmentDictionary(
        _ buffer: CVPixelBuffer,
        mode: CVAttachmentMode
    ) -> NSDictionary {
        CVBufferCopyAttachments(buffer, mode) as NSDictionary?
            ?? NSDictionary()
    }

    func videoSampleCount(
        asset: AVAsset,
        track: AVAssetTrack
    ) throws -> Int {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: nil
        )
        guard reader.canAdd(output) else {
            throw MediaTestFailure.cannotAddReaderOutput
        }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? MediaTestFailure.cannotStartReader
        }
        var count = 0
        while let sampleBuffer = output.copyNextSampleBuffer() {
            count += CMSampleBufferGetNumSamples(sampleBuffer)
        }
        guard reader.status == .completed else {
            throw reader.error ?? MediaTestFailure.readerFailed
        }
        return count
    }
}

private struct SmoothMotionDecodedFrame {
    let presentationTime: CMTime
    let centerLuma: UInt8
}

private struct SmoothMotionSampleTiming {
    let presentationTime: CMTime
    let duration: CMTime
}

private func writeSmoothMotionSceneCutFixture(
    to url: URL,
    resolution: VideoResolution
) async throws {
    let writer = try AVAssetWriter(url: url, fileType: .mp4)
    let input = AVAssetWriterInput(
        mediaType: .video,
        outputSettings: ProductVideoOutputSettings.make(
            resolution: resolution,
            codec: .h264
        )
    )
    input.expectsMediaDataInRealTime = false
    input.mediaTimeScale = 600
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: resolution.width,
            kCVPixelBufferHeightKey as String: resolution.height,
            kCVPixelBufferIOSurfacePropertiesKey as String:
                [String: Any]()
        ]
    )
    guard writer.canAdd(input) else {
        throw MediaTestFailure.cannotAddWriterInput
    }
    writer.add(input)
    guard writer.startWriting() else {
        throw writer.error ?? MediaTestFailure.cannotStartWriter
    }
    writer.startSession(atSourceTime: .zero)
    guard let pool = adaptor.pixelBufferPool else {
        throw MediaTestFailure.missingPixelBufferPool
    }
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(120))
    for (index, luma) in [UInt8(48), 80, 224].enumerated() {
        while !input.isReadyForMoreMediaData {
            try Task.checkCancellation()
            guard clock.now < deadline,
                  writer.status == .writing else {
                writer.cancelWriting()
                throw writer.error ?? MediaTestFailure.timeout
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        var optionalBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(
            kCFAllocatorDefault,
            pool,
            &optionalBuffer
        )
        guard status == kCVReturnSuccess,
              let buffer = optionalBuffer else {
            writer.cancelWriting()
            throw MediaTestFailure.cannotCreatePixelBuffer(status)
        }
        try fillSmoothMotionFixture(buffer, luma: luma)
        MediaVideoFormat.sdrBT709.installAttachments(on: buffer)
        guard adaptor.append(
            buffer,
            withPresentationTime: CMTime(
                value: Int64(index),
                timescale: 30
            )
        ) else {
            writer.cancelWriting()
            throw writer.error ?? MediaTestFailure.appendFailed
        }
    }
    input.markAsFinished()
    writer.endSession(atSourceTime: CMTime(value: 3, timescale: 30))
    await writer.finishWriting()
    guard writer.status == .completed else {
        throw writer.error ?? MediaTestFailure.writerFailed
    }
}

private func fillSmoothMotionFixture(
    _ pixelBuffer: CVPixelBuffer,
    luma: UInt8
) throws {
    let status = CVPixelBufferLockBaseAddress(pixelBuffer, [])
    guard status == kCVReturnSuccess else {
        throw MediaTestFailure.appendFailed
    }
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    guard CVPixelBufferGetPlaneCount(pixelBuffer) == 2 else {
        throw MediaTestFailure.appendFailed
    }
    for plane in 0..<2 {
        guard let base = CVPixelBufferGetBaseAddressOfPlane(
            pixelBuffer,
            plane
        ) else {
            throw MediaTestFailure.appendFailed
        }
        memset(
            base,
            plane == 0 ? Int32(luma) : 128,
            CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
                * CVPixelBufferGetBytesPerRowOfPlane(
                    pixelBuffer,
                    plane
                )
        )
    }
}

private func readSmoothMotionDecodedFrames(
    at url: URL
) async throws -> [SmoothMotionDecodedFrame] {
    let asset = AVURLAsset(
        url: url,
        options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: true
        ]
    )
    let tracks = try await asset.loadTracks(withMediaType: .video)
    let track = try XCTUnwrap(tracks.first)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(
        track: track,
        outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
    )
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else {
        throw MediaTestFailure.cannotAddReaderOutput
    }
    reader.add(output)
    guard reader.startReading() else {
        throw reader.error ?? MediaTestFailure.cannotStartReader
    }
    var frames: [SmoothMotionDecodedFrame] = []
    while let sample = output.copyNextSampleBuffer() {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else {
            reader.cancelReading()
            throw MediaTestFailure.readerFailed
        }
        frames.append(
            SmoothMotionDecodedFrame(
                presentationTime:
                    CMSampleBufferGetPresentationTimeStamp(sample),
                centerLuma: try smoothMotionCenterLuma(pixelBuffer)
            )
        )
    }
    guard reader.status == .completed else {
        throw reader.error ?? MediaTestFailure.readerFailed
    }
    return frames.sorted {
        CMTimeCompare(
            $0.presentationTime,
            $1.presentationTime
        ) < 0
    }
}

private func readSmoothMotionSampleTimings(
    at url: URL
) async throws -> [SmoothMotionSampleTiming] {
    let asset = AVURLAsset(
        url: url,
        options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: true
        ]
    )
    let tracks = try await asset.loadTracks(withMediaType: .video)
    let track = try XCTUnwrap(tracks.first)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(
        track: track,
        outputSettings: nil
    )
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else {
        throw MediaTestFailure.cannotAddReaderOutput
    }
    reader.add(output)
    guard reader.startReading() else {
        throw reader.error ?? MediaTestFailure.cannotStartReader
    }
    var timings: [SmoothMotionSampleTiming] = []
    while let sampleBuffer = output.copyNextSampleBuffer() {
        for sampleIndex in 0..<CMSampleBufferGetNumSamples(
            sampleBuffer
        ) {
            var timing = CMSampleTimingInfo()
            let timingStatus = CMSampleBufferGetSampleTimingInfo(
                sampleBuffer,
                at: sampleIndex,
                timingInfoOut: &timing
            )
            guard timingStatus == noErr else {
                reader.cancelReading()
                throw MediaTestFailure.readerFailed
            }
            timings.append(
                SmoothMotionSampleTiming(
                    presentationTime: timing.presentationTimeStamp,
                    duration: timing.duration
                )
            )
        }
    }
    guard reader.status == .completed else {
        throw reader.error ?? MediaTestFailure.readerFailed
    }
    return timings.sorted {
        CMTimeCompare(
            $0.presentationTime,
            $1.presentationTime
        ) < 0
    }
}

private func smoothMotionCenterLuma(
    _ pixelBuffer: CVPixelBuffer
) throws -> UInt8 {
    let status = CVPixelBufferLockBaseAddress(
        pixelBuffer,
        .readOnly
    )
    guard status == kCVReturnSuccess else {
        throw MediaTestFailure.readerFailed
    }
    defer {
        CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
    }
    guard CVPixelBufferGetPlaneCount(pixelBuffer) == 2,
          let base = CVPixelBufferGetBaseAddressOfPlane(
              pixelBuffer,
              0
          ) else {
        throw MediaTestFailure.readerFailed
    }
    let row = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0) / 2
    let column = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0) / 2
    return base
        .advanced(
            by:
                row
                    * CVPixelBufferGetBytesPerRowOfPlane(
                        pixelBuffer,
                        0
                    )
                + column
        )
        .assumingMemoryBound(to: UInt8.self)
        .pointee
}

private final class SmoothMotionRecordingMediaSession:
    MediaSession,
    @unchecked Sendable {
    private struct State {
        var appendedBuffers: [CVPixelBuffer] = []
        var appendedTimings: [FrameTiming] = []
        var finalMetadata: [String: String] = [:]
        var finishCount = 0
        var cancelCount = 0
    }

    let sourceProfile: SourceProfile
    let outputProfile: OutputProfile
    let videoFormat: MediaVideoFormat
    let outputPixelBufferPool: CVPixelBufferPool
    var terminalCleanupError: MediaPipelineError? { nil }

    private let lock = NSLock()
    private var state = State()

    init(
        resolution: VideoResolution,
        videoFormat: MediaVideoFormat,
        frameRate: Double,
        sourceDuration: Double,
        preserveAudio: Bool
    ) throws {
        self.videoFormat = videoFormat
        sourceProfile = SourceProfile(
            url: URL(fileURLWithPath: "/tmp/smooth-motion-source.mov"),
            resolution: resolution,
            frameRate: frameRate,
            durationSeconds: sourceDuration,
            estimatedFrameCount:
                Int((sourceDuration * frameRate).rounded()),
            codecHint: "smooth-motion-test",
            hasAudio: preserveAudio,
            videoFormat: videoFormat
        )
        outputProfile = OutputProfile(
            url: URL(fileURLWithPath: "/tmp/smooth-motion-output.mov"),
            resolution: resolution,
            codec: .hevc,
            preserveAudio: preserveAudio,
            videoFormat: videoFormat
        )
        outputPixelBufferPool = try PixelBufferBridge.makePool(
            width: resolution.width,
            height: resolution.height,
            format: videoFormat.pixelStorage.pixelFormat,
            capacity: 16
        )
    }

    var appendedBuffers: [CVPixelBuffer] {
        lock.withLock { state.appendedBuffers }
    }

    var appendedTimings: [FrameTiming] {
        lock.withLock { state.appendedTimings }
    }

    var finishCount: Int {
        lock.withLock { state.finishCount }
    }

    var cancelCount: Int {
        lock.withLock { state.cancelCount }
    }

    func nextSourceFrame() async throws -> FrameRecord? {
        nil
    }

    func appendOutput(
        pixelBuffer: CVPixelBuffer,
        timing: FrameTiming
    ) async throws {
        lock.withLock {
            state.appendedBuffers.append(pixelBuffer)
            state.appendedTimings.append(timing)
        }
    }

    func finish() async throws {
        lock.withLock { state.finishCount += 1 }
    }

    func finish(
        finalMetadata: [String: String]
    ) async throws {
        lock.withLock {
            state.finalMetadata = finalMetadata
        }
        try await finish()
    }

    func cancel() {
        lock.withLock { state.cancelCount += 1 }
    }
}
