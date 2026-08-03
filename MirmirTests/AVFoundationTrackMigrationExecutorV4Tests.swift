import AVFoundation
import AudioToolbox
import CoreMedia
import CoreVideo
import XCTest
@testable import Mirmir

final class AVFoundationTrackMigrationExecutorV4Tests: XCTestCase {
    func testDeterministicSessionProcessesPrimaryAndPreservesRichAsset()
        async throws {
        let directory = try TrackMigrationFixtureDirectoryV4()
        defer { directory.remove() }
        let sourceURL = directory.url("deterministic-rich-source.mov")
        let destinationURL = directory.url("deterministic-rich-output.mov")
        let runtimeURL = directory.url("deterministic-p06.bundle")
        try await TrackMigrationFixtureFactoryV4.makeRichMovie(
            at: sourceURL,
            includeAudioGroup: false
        )

        let source = try await VideoProbe().probe(url: sourceURL)
        XCTAssertEqual(source.videoTrackCount, 2)
        XCTAssertEqual(source.audioTrackCount, 2)
        let runtime = try ASHV4SemanticArtifactTestSupport.buildAndLoad(
            at: runtimeURL
        )
        let descriptor = try XCTUnwrap(
            BackendDescriptor.descriptor(for: .mirmirDeterministicCPU)
        )
        let backend = try XCTUnwrap(DeterministicCPUBackend(
            descriptor: descriptor,
            runtimeProvider: .fixed(runtime)
        ))
        let targetSize = CGSize(width: 96, height: 72)
        let prepared = try await backend.prepare(
            request: BackendPreparationRequest(
                source: source,
                targetSize: targetSize
            ),
            environment: .current()
        )
        let result = try await VideoProcessingSession().process(
            request: UpscaleRequest(
                inputURL: sourceURL,
                outputURL: destinationURL,
                backendID: .mirmirDeterministicCPU,
                targetWidth: 96,
                targetHeight: 72,
                outputCodec: .h264,
                preserveAudio: true,
                overwriteExistingFile: false
            ),
            source: source,
            preparedBackend: prepared,
            cancellation: ProcessingCancellation(),
            progress: { _ in }
        )

        XCTAssertEqual(result.encodedWidth, 96)
        XCTAssertEqual(result.encodedHeight, 72)
        XCTAssertEqual(result.audioResult, .preserved)
        XCTAssertEqual(
            result.processedFrameCount,
            TrackMigrationFixtureFactoryV4.frameCount
        )
        XCTAssertGreaterThan(result.processingDurationSeconds, 0)

        let outputAsset = AVURLAsset(
            url: destinationURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let outputGraph = try await AVFoundationTrackGraphAdapterV4.probe(
            asset: outputAsset
        )
        XCTAssertEqual(outputGraph.tracks.filter { $0.kind == .video }.count, 2)
        XCTAssertEqual(outputGraph.tracks.filter { $0.kind == .audio }.count, 2)
        XCTAssertEqual(
            outputGraph.tracks.filter { $0.kind == .timedMetadata }.count,
            1
        )
        XCTAssertEqual(outputGraph.tracks.filter { $0.kind == .chapter }.count, 1)
        XCTAssertEqual(outputGraph.tracks.filter { $0.kind == .timecode }.count, 1)
        XCTAssertEqual(
            Set(outputGraph.associations.map(\.kind)),
            Set([.chapterList, .timecode, .metadataReferent])
        )
        let outputVideos = try await outputAsset.loadTracks(withMediaType: .video)
        XCTAssertEqual(outputVideos.count, 2)
        let primaryOutputSize = try await outputVideos[0].load(.naturalSize)
        let alternateOutputSize = try await outputVideos[1].load(.naturalSize)
        XCTAssertEqual(primaryOutputSize, targetSize)
        XCTAssertEqual(
            alternateOutputSize,
            CGSize(
                width: TrackMigrationFixtureFactoryV4.width,
                height: TrackMigrationFixtureFactoryV4.height
            )
        )
        XCTAssertFalse(try directory.containsPartialMovie())
    }

    func testExecutableMigrationPreservesEveryEncodedTrackAndVerifiesOutput()
        async throws {
        let directory = try TrackMigrationFixtureDirectoryV4()
        defer { directory.remove() }
        let sourceURL = directory.url("rich-source.mov")
        let destinationURL = directory.url("rich-output.mov")
        try await TrackMigrationFixtureFactoryV4.makeRichMovie(
            at: sourceURL,
            includeAudioGroup: false
        )

        let sourceAsset = AVURLAsset(
            url: sourceURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let source = try await AVFoundationTrackGraphAdapterV4.probe(
            asset: sourceAsset
        )
        XCTAssertEqual(source.tracks.filter { $0.kind == .video }.count, 2)
        XCTAssertEqual(
            source.tracks.filter { $0.kind == .video && $0.enabled }.count,
            2
        )
        XCTAssertEqual(source.tracks.filter { $0.kind == .audio }.count, 2)
        XCTAssertEqual(
            source.tracks.filter { $0.kind == .timedMetadata }.count,
            1
        )
        XCTAssertEqual(source.tracks.filter { $0.kind == .chapter }.count, 1)
        XCTAssertEqual(source.tracks.filter { $0.kind == .timecode }.count, 1)
        XCTAssertTrue(source.groups.isEmpty)
        XCTAssertEqual(
            Set(source.associations.map(\.kind)),
            Set([.chapterList, .timecode, .metadataReferent])
        )

        let plan = try MediaTrackGraphPlannerV4.makePlan(source: source)
        let blueprint = try AVFoundationTrackMigrationPlannerV4.makeBlueprint(
            source: source,
            plan: plan
        )
        let recorder = TrackMigrationProgressRecorderV4()
        let result = try await AVFoundationTrackMigrationExecutorV4().execute(
            AVFoundationTrackMigrationExecutionRequestV4(
                sourceURL: sourceURL,
                destinationURL: destinationURL,
                sourceGraph: source,
                identifiedPlan: plan,
                blueprint: blueprint
            ),
            progress: { recorder.record($0) }
        )

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destinationURL.path
        ))
        XCTAssertTrue(result.verificationReport.isConformant)
        XCTAssertEqual(result.outputGraph, source)
        XCTAssertEqual(
            result.trackResults.map(\.trackID),
            source.tracks.map { $0.identity.stableID }
        )
        XCTAssertTrue(result.trackResults.allSatisfy {
            $0.action == .passThrough
                && $0.migratedSampleCount > 0
                && $0.sourceSampleStreamSHA256 != nil
                && $0.sourceSampleStreamSHA256
                    == $0.outputSampleStreamSHA256
        })
        XCTAssertEqual(
            Set(recorder.snapshot().map(\.stage)),
            Set(AVFoundationTrackMigrationExecutionStageV4.allCases)
        )
        XCTAssertFalse(try directory.containsPartialMovie())
    }

    func testAlternateAudioGroupFailsClosedBeforeWriting() async throws {
        let directory = try TrackMigrationFixtureDirectoryV4()
        defer { directory.remove() }
        let sourceURL = directory.url("group-source.mov")
        let destinationURL = directory.url("group-output.mov")
        try await TrackMigrationFixtureFactoryV4.makeRichMovie(
            at: sourceURL,
            includeAudioGroup: true
        )
        let source = try await AVFoundationTrackGraphAdapterV4.probe(
            asset: AVURLAsset(url: sourceURL)
        )
        XCTAssertEqual(source.groups.count, 1)
        XCTAssertNotNil(source.groups[0].defaultTrackID)
        let plan = try MediaTrackGraphPlannerV4.makePlan(source: source)
        let blueprint = try AVFoundationTrackMigrationPlannerV4.makeBlueprint(
            source: source,
            plan: plan
        )

        await XCTAssertThrowsErrorAsyncV4(
            try await AVFoundationTrackMigrationExecutorV4().execute(
                .init(
                    sourceURL: sourceURL,
                    destinationURL: destinationURL,
                    sourceGraph: source,
                    identifiedPlan: plan,
                    blueprint: blueprint
                )
            )
        ) { error in
            guard case .unsupportedGroup(_, let reason) =
                error as? AVFoundationTrackMigrationExecutorV4Error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(reason, "empty_selection_policy_not_writable")
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: destinationURL.path
        ))
        XCTAssertFalse(try directory.containsPartialMovie())
    }

    func testEveryProcessedVideoRequiresAnExplicitTrackBoundHook()
        async throws {
        let directory = try TrackMigrationFixtureDirectoryV4()
        defer { directory.remove() }
        let sourceURL = directory.url("hook-source.mov")
        let destinationURL = directory.url("hook-output.mov")
        try await TrackMigrationFixtureFactoryV4.makeRichMovie(
            at: sourceURL,
            includeAudioGroup: false
        )
        let source = try await AVFoundationTrackGraphAdapterV4.probe(
            asset: AVURLAsset(url: sourceURL)
        )
        let videos = source.tracks.filter { $0.kind == .video && $0.enabled }
        XCTAssertEqual(videos.count, 2)
        let directives = videos.map {
            MediaTrackDirectiveV4(
                trackID: $0.identity.stableID,
                action: .process,
                targetFormatDescriptors: $0.formatDescriptors,
                dropConsent: nil
            )
        }
        let plan = try MediaTrackGraphPlannerV4.makePlan(
            source: source,
            request: .init(trackDirectives: directives)
        )
        let blueprint = try AVFoundationTrackMigrationPlannerV4.makeBlueprint(
            source: source,
            plan: plan
        )

        await XCTAssertThrowsErrorAsyncV4(
            try await AVFoundationTrackMigrationExecutorV4().execute(
                .init(
                    sourceURL: sourceURL,
                    destinationURL: destinationURL,
                    sourceGraph: source,
                    identifiedPlan: plan,
                    blueprint: blueprint,
                    videoProcessingHooks: [try processingHook(
                        for: videos[1]
                    ) { $0 }]
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? AVFoundationTrackMigrationExecutorV4Error,
                .missingProcessingHook(videos[0].identity.stableID)
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: destinationURL.path
        ))
        XCTAssertFalse(try directory.containsPartialMovie())
    }

    func testTrackBoundVideoHookReencodesOneVideoWhileEveryOtherTrackCopies()
        async throws {
        let directory = try TrackMigrationFixtureDirectoryV4()
        defer { directory.remove() }
        let sourceURL = directory.url("process-source.mov")
        let destinationURL = directory.url("process-output.mov")
        let calibrationURL = directory.url("process-calibration.mov")
        try await TrackMigrationFixtureFactoryV4.makeRichMovie(
            at: sourceURL,
            includeAudioGroup: false
        )
        let source = try await AVFoundationTrackGraphAdapterV4.probe(
            asset: AVURLAsset(url: sourceURL)
        )
        let video = try XCTUnwrap(source.tracks.first {
            $0.kind == .video
        })
        try await TrackMigrationFixtureFactoryV4.makeReencodedVideo(
            source: sourceURL,
            at: calibrationURL
        )
        let calibration = try await AVFoundationTrackGraphAdapterV4.probe(
            asset: AVURLAsset(url: calibrationURL)
        )
        let targetFormats = try XCTUnwrap(calibration.tracks.first)
            .formatDescriptors
        let plan = try processingPlan(
            source: source,
            video: video,
            targetFormats: targetFormats
        )
        let blueprint = try AVFoundationTrackMigrationPlannerV4.makeBlueprint(
            source: source,
            plan: plan
        )
        let result = try await AVFoundationTrackMigrationExecutorV4().execute(
            .init(
                sourceURL: sourceURL,
                destinationURL: destinationURL,
                sourceGraph: source,
                identifiedPlan: plan,
                blueprint: blueprint,
                videoProcessingHooks: [try processingHook(
                    for: video,
                    declaredOutputFormats: targetFormats
                ) { $0 }]
            )
        )

        XCTAssertTrue(result.verificationReport.isConformant)
        XCTAssertEqual(result.trackResults.count, source.tracks.count)
        XCTAssertEqual(
            result.trackResults.first {
                $0.trackID == video.identity.stableID
            }?.action,
            .process
        )
        XCTAssertEqual(
            result.trackResults.filter { $0.action == .passThrough }.count,
            source.tracks.count - 1
        )
        XCTAssertTrue(result.trackResults.allSatisfy {
            $0.migratedSampleCount > 0
        })
        XCTAssertNil(result.trackResults.first {
            $0.action == .process
        }?.sourceSampleStreamSHA256)
        XCTAssertTrue(result.trackResults.filter {
            $0.action == .passThrough
        }.allSatisfy {
            $0.sourceSampleStreamSHA256 == $0.outputSampleStreamSHA256
        })
        XCTAssertFalse(try directory.containsPartialMovie())
    }

    func testProcessorFaultCancelsWriterAndLeavesExistingDestinationUntouched()
        async throws {
        struct InjectedProcessorFailure: Error {}

        let directory = try TrackMigrationFixtureDirectoryV4()
        defer { directory.remove() }
        let sourceURL = directory.url("fault-source.mov")
        let destinationURL = directory.url("existing.mov")
        try await TrackMigrationFixtureFactoryV4.makeRichMovie(
            at: sourceURL,
            includeAudioGroup: false
        )
        let sentinel = Data("existing destination must survive".utf8)
        try sentinel.write(to: destinationURL)
        let source = try await AVFoundationTrackGraphAdapterV4.probe(
            asset: AVURLAsset(url: sourceURL)
        )
        let video = try XCTUnwrap(source.tracks.first {
            $0.kind == .video
        })
        let plan = try processingPlan(source: source, video: video)
        let blueprint = try AVFoundationTrackMigrationPlannerV4.makeBlueprint(
            source: source,
            plan: plan
        )
        let hook = try processingHook(for: video) { _ in
            throw InjectedProcessorFailure()
        }

        await XCTAssertThrowsErrorAsyncV4(
            try await AVFoundationTrackMigrationExecutorV4().execute(
                .init(
                    sourceURL: sourceURL,
                    destinationURL: destinationURL,
                    overwriteExistingFile: true,
                    sourceGraph: source,
                    identifiedPlan: plan,
                    blueprint: blueprint,
                    videoProcessingHooks: [hook]
                )
            )
        ) { error in
            guard case .processorFailed(let trackID, _) =
                error as? AVFoundationTrackMigrationExecutorV4Error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(trackID, video.identity.stableID)
        }
        XCTAssertEqual(try Data(contentsOf: destinationURL), sentinel)
        XCTAssertFalse(try directory.containsPartialMovie())
    }

    func testCancellationDuringProcessingDiscardsTemporaryOutput() async throws {
        let directory = try TrackMigrationFixtureDirectoryV4()
        defer { directory.remove() }
        let sourceURL = directory.url("cancel-source.mov")
        let destinationURL = directory.url("cancel-output.mov")
        try await TrackMigrationFixtureFactoryV4.makeRichMovie(
            at: sourceURL,
            includeAudioGroup: false
        )
        let source = try await AVFoundationTrackGraphAdapterV4.probe(
            asset: AVURLAsset(url: sourceURL)
        )
        let video = try XCTUnwrap(source.tracks.first {
            $0.kind == .video
        })
        let plan = try processingPlan(source: source, video: video)
        let blueprint = try AVFoundationTrackMigrationPlannerV4.makeBlueprint(
            source: source,
            plan: plan
        )
        let cancellation = AVFoundationTrackMigrationCancellationV4()
        let hook = try processingHook(for: video) { sample in
            cancellation.cancel()
            return sample
        }

        await XCTAssertThrowsErrorAsyncV4(
            try await AVFoundationTrackMigrationExecutorV4().execute(
                .init(
                    sourceURL: sourceURL,
                    destinationURL: destinationURL,
                    sourceGraph: source,
                    identifiedPlan: plan,
                    blueprint: blueprint,
                    videoProcessingHooks: [hook]
                ),
                cancellation: cancellation
            )
        ) { error in
            XCTAssertEqual(
                error as? AVFoundationTrackMigrationExecutorV4Error,
                .cancelled
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: destinationURL.path
        ))
        XCTAssertFalse(try directory.containsPartialMovie())
    }

    func testProcessedSampleTimingMutationFailsAtomically() async throws {
        let directory = try TrackMigrationFixtureDirectoryV4()
        defer { directory.remove() }
        let sourceURL = directory.url("timing-source.mov")
        let destinationURL = directory.url("timing-output.mov")
        try await TrackMigrationFixtureFactoryV4.makeRichMovie(
            at: sourceURL,
            includeAudioGroup: false
        )
        let source = try await AVFoundationTrackGraphAdapterV4.probe(
            asset: AVURLAsset(url: sourceURL)
        )
        let video = try XCTUnwrap(source.tracks.first {
            $0.kind == .video
        })
        let plan = try processingPlan(source: source, video: video)
        let blueprint = try AVFoundationTrackMigrationPlannerV4.makeBlueprint(
            source: source,
            plan: plan
        )
        let hook = try processingHook(for: video) { sample in
            let sourceBuffer = sample.sampleBuffer
            var timing = CMSampleTimingInfo(
                duration: CMSampleBufferGetDuration(sourceBuffer),
                presentationTimeStamp: CMTimeAdd(
                    CMSampleBufferGetPresentationTimeStamp(sourceBuffer),
                    CMTime(value: 1, timescale: 30)
                ),
                decodeTimeStamp: CMSampleBufferGetDecodeTimeStamp(sourceBuffer)
            )
            var copy: CMSampleBuffer?
            let status = CMSampleBufferCreateCopyWithNewTiming(
                allocator: kCFAllocatorDefault,
                sampleBuffer: sourceBuffer,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timing,
                sampleBufferOut: &copy
            )
            guard status == noErr, let copy else {
                throw TrackMigrationFixtureErrorV4.coreMedia(status)
            }
            return AVFoundationVideoSampleV4(sampleBuffer: copy)
        }

        await XCTAssertThrowsErrorAsyncV4(
            try await AVFoundationTrackMigrationExecutorV4().execute(
                .init(
                    sourceURL: sourceURL,
                    destinationURL: destinationURL,
                    sourceGraph: source,
                    identifiedPlan: plan,
                    blueprint: blueprint,
                    videoProcessingHooks: [hook]
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? AVFoundationTrackMigrationExecutorV4Error,
                .processedSampleChangedTiming(video.identity.stableID)
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: destinationURL.path
        ))
        XCTAssertFalse(try directory.containsPartialMovie())
    }

    func testTemporalHookUniformlySubdividesEverySourceIntervalAndPreservesAllTracks()
        async throws {
        let directory = try TrackMigrationFixtureDirectoryV4()
        defer { directory.remove() }
        let sourceURL = directory.url("temporal-source.mov")
        let calibrationURL = directory.url("temporal-calibration.mov")
        let destinationURL = directory.url("temporal-output.mov")
        try await TrackMigrationFixtureFactoryV4.makeRichMovie(
            at: sourceURL,
            includeAudioGroup: false
        )
        let source = try await AVFoundationTrackGraphAdapterV4.probe(
            asset: AVURLAsset(url: sourceURL)
        )
        let video = try XCTUnwrap(source.tracks.first {
            $0.kind == .video
        })
        try await TrackMigrationFixtureFactoryV4.makeReencodedVideo(
            source: sourceURL,
            at: calibrationURL
        )
        let calibration = try await AVFoundationTrackGraphAdapterV4.probe(
            asset: AVURLAsset(url: calibrationURL)
        )
        let targetFormats = try XCTUnwrap(calibration.tracks.first)
            .formatDescriptors
        let plan = try processingPlan(
            source: source,
            video: video,
            targetFormats: targetFormats
        )
        let blueprint = try AVFoundationTrackMigrationPlannerV4.makeBlueprint(
            source: source,
            plan: plan
        )
        let hook = try temporalProcessingHook(
            for: video,
            declaredOutputFormats: targetFormats,
            outputCount: 2
        ) { sample in
            let sourceBuffer = sample.sampleBuffer
            let observedDuration = CMSampleBufferGetDuration(sourceBuffer)
            let duration = observedDuration.isNumeric
                && observedDuration.value > 0
                ? observedDuration
                : CMTime(value: 1, timescale: 30)
            let sourcePTS = CMSampleBufferGetPresentationTimeStamp(sourceBuffer)
            let sourceDTS = CMSampleBufferGetDecodeTimeStamp(sourceBuffer)
            let subduration = CMTimeMultiplyByRatio(
                duration,
                multiplier: 1,
                divisor: 2
            )
            return try (0..<2).map { ordinal in
                let offset = CMTimeMultiply(
                    subduration,
                    multiplier: Int32(ordinal)
                )
                var timing = CMSampleTimingInfo(
                    duration: subduration,
                    presentationTimeStamp: CMTimeAdd(sourcePTS, offset),
                    decodeTimeStamp: sourceDTS.isNumeric
                        ? CMTimeAdd(sourceDTS, offset)
                        : sourceDTS
                )
                var copy: CMSampleBuffer?
                let status = CMSampleBufferCreateCopyWithNewTiming(
                    allocator: kCFAllocatorDefault,
                    sampleBuffer: sourceBuffer,
                    sampleTimingEntryCount: 1,
                    sampleTimingArray: &timing,
                    sampleBufferOut: &copy
                )
                guard status == noErr, let copy else {
                    throw TrackMigrationFixtureErrorV4.coreMedia(status)
                }
                return AVFoundationVideoSampleV4(sampleBuffer: copy)
            }
        }

        let result = try await AVFoundationTrackMigrationExecutorV4().execute(
            .init(
                sourceURL: sourceURL,
                destinationURL: destinationURL,
                sourceGraph: source,
                identifiedPlan: plan,
                blueprint: blueprint,
                videoProcessingHooks: [hook]
            )
        )

        XCTAssertTrue(result.verificationReport.isConformant)
        XCTAssertEqual(result.trackResults.count, source.tracks.count)
        XCTAssertEqual(
            result.trackResults.first {
                $0.trackID == video.identity.stableID
            }?.migratedSampleCount,
            16
        )
        XCTAssertTrue(result.trackResults.filter {
            $0.action == .passThrough
        }.allSatisfy {
            $0.sourceSampleStreamSHA256 == $0.outputSampleStreamSHA256
        })
        XCTAssertFalse(try directory.containsPartialMovie())
    }

    func testPreparedTemporalBackendAdapterOwnsBuffersTimingAndFinalization()
        async throws {
        let directory = try TrackMigrationFixtureDirectoryV4()
        defer { directory.remove() }
        let sourceURL = directory.url("prepared-source.mov")
        let calibrationURL = directory.url("prepared-calibration.mov")
        let destinationURL = directory.url("prepared-output.mov")
        try await TrackMigrationFixtureFactoryV4.makeRichMovie(
            at: sourceURL,
            includeAudioGroup: false
        )
        let source = try await AVFoundationTrackGraphAdapterV4.probe(
            asset: AVURLAsset(url: sourceURL)
        )
        let video = try XCTUnwrap(source.tracks.first {
            $0.kind == .video
        })
        try await TrackMigrationFixtureFactoryV4.makeReencodedVideo(
            source: sourceURL,
            at: calibrationURL
        )
        let calibration = try await AVFoundationTrackGraphAdapterV4.probe(
            asset: AVURLAsset(url: calibrationURL)
        )
        let targetFormats = try XCTUnwrap(calibration.tracks.first)
            .formatDescriptors
        let plan = try processingPlan(
            source: source,
            video: video,
            targetFormats: targetFormats
        )
        let blueprint = try AVFoundationTrackMigrationPlannerV4.makeBlueprint(
            source: source,
            plan: plan
        )
        let settings = try processingHook(
            for: video,
            declaredOutputFormats: targetFormats
        ) { $0 }.writerOutputSettings
        let backend = TrackMigrationDoubleRateCopyBackendV4(
            width: TrackMigrationFixtureFactoryV4.width,
            height: TrackMigrationFixtureFactoryV4.height
        )
        let hook = try PreparedFrameUpscalerTrackHookV4.make(
            trackID: video.identity.stableID,
            preparedBackend: backend,
            writerOutputSettings: settings,
            declaredOutputFormats: targetFormats,
            nominalSourceFrameDuration: ExactRationalV4(1, 30)
        )

        let result = try await AVFoundationTrackMigrationExecutorV4().execute(
            .init(
                sourceURL: sourceURL,
                destinationURL: destinationURL,
                sourceGraph: source,
                identifiedPlan: plan,
                blueprint: blueprint,
                videoProcessingHooks: [hook]
            )
        )

        XCTAssertTrue(result.verificationReport.isConformant)
        XCTAssertEqual(
            result.trackResults.first {
                $0.trackID == video.identity.stableID
            }?.migratedSampleCount,
            16
        )
        let processedInputCount = await backend.processedInputCount()
        let wasFinished = await backend.wasFinished()
        XCTAssertEqual(processedInputCount, 8)
        XCTAssertTrue(wasFinished)
        XCTAssertTrue(result.trackResults.filter {
            $0.action == .passThrough
        }.allSatisfy {
            $0.sourceSampleStreamSHA256 == $0.outputSampleStreamSHA256
        })
        XCTAssertFalse(try directory.containsPartialMovie())
    }

    func testNontrivialEditFailsBeforeDestinationCreation() async throws {
        let directory = try TrackMigrationFixtureDirectoryV4()
        defer { directory.remove() }
        let sourceURL = directory.url("edit-source.mov")
        let destinationURL = directory.url("edit-output.mov")
        try await TrackMigrationFixtureFactoryV4.makeRichMovie(
            at: sourceURL,
            includeAudioGroup: false
        )
        let observed = try await AVFoundationTrackGraphAdapterV4.probe(
            asset: AVURLAsset(url: sourceURL)
        )
        let source = try graphWithEmptyEdit(observed)
        let plan = try MediaTrackGraphPlannerV4.makePlan(source: source)
        let blueprint = try AVFoundationTrackMigrationPlannerV4.makeBlueprint(
            source: source,
            plan: plan
        )

        await XCTAssertThrowsErrorAsyncV4(
            try await AVFoundationTrackMigrationExecutorV4().execute(
                .init(
                    sourceURL: sourceURL,
                    destinationURL: destinationURL,
                    sourceGraph: source,
                    identifiedPlan: plan,
                    blueprint: blueprint
                )
            )
        ) { error in
            guard case .unsupportedTrack(_, let reason) =
                error as? AVFoundationTrackMigrationExecutorV4Error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(reason, "composition_required")
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: destinationURL.path
        ))
        XCTAssertFalse(try directory.containsPartialMovie())
    }

    func testAuxiliaryOrMuxedTrackFailsExplicitlyWithoutSilentDrop()
        async throws {
        let directory = try TrackMigrationFixtureDirectoryV4()
        defer { directory.remove() }
        let sourceURL = directory.url("aux-source.mov")
        let destinationURL = directory.url("aux-output.mov")
        try await TrackMigrationFixtureFactoryV4.makeRichMovie(
            at: sourceURL,
            includeAudioGroup: false
        )
        let observed = try await AVFoundationTrackGraphAdapterV4.probe(
            asset: AVURLAsset(url: sourceURL)
        )
        let source = try graphReplacingFirstTrackKind(
            observed,
            kind: .auxiliary,
            sourceMediaTypeID: AVMediaType.muxed.rawValue
        )
        let plan = try MediaTrackGraphPlannerV4.makePlan(source: source)
        let blueprint = try AVFoundationTrackMigrationPlannerV4.makeBlueprint(
            source: source,
            plan: plan
        )

        await XCTAssertThrowsErrorAsyncV4(
            try await AVFoundationTrackMigrationExecutorV4().execute(
                .init(
                    sourceURL: sourceURL,
                    destinationURL: destinationURL,
                    sourceGraph: source,
                    identifiedPlan: plan,
                    blueprint: blueprint
                )
            )
        ) { error in
            guard case .unsupportedTrack(_, let reason) =
                error as? AVFoundationTrackMigrationExecutorV4Error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(
                reason,
                "auxiliary_or_muxed_writer_support_unproven"
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: destinationURL.path
        ))
        XCTAssertFalse(try directory.containsPartialMovie())
    }
}

private extension AVFoundationTrackMigrationExecutorV4Tests {
    func processingPlan(
        source: MediaTrackGraphV4,
        video: MediaTrackNodeV4,
        targetFormats: [MediaTrackFormatDescriptorV4]? = nil
    ) throws -> MediaTrackGraphIdentifiedPlanV4 {
        try MediaTrackGraphPlannerV4.makePlan(
            source: source,
            request: .init(trackDirectives: [MediaTrackDirectiveV4(
                trackID: video.identity.stableID,
                action: .process,
                targetFormatDescriptors: targetFormats
                    ?? video.formatDescriptors,
                dropConsent: nil
            )])
        )
    }

    func processingHook(
        for video: MediaTrackNodeV4,
        declaredOutputFormats: [MediaTrackFormatDescriptorV4]? = nil,
        process: @escaping AVFoundationVideoTrackProcessingHookV4.Processor
    ) throws -> AVFoundationVideoTrackProcessingHookV4 {
        guard video.formatDescriptors.count == 1 else {
            throw TrackMigrationFixtureErrorV4.invalidFixture(
                "Expected one video format description."
            )
        }
        return AVFoundationVideoTrackProcessingHookV4(
            trackID: video.identity.stableID,
            readerOutputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    Int(kCVPixelFormatType_32BGRA)
            ],
            writerOutputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: TrackMigrationFixtureFactoryV4.width,
                AVVideoHeightKey: TrackMigrationFixtureFactoryV4.height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoExpectedSourceFrameRateKey: 30,
                    AVVideoMaxKeyFrameIntervalKey: 8
                ]
            ],
            declaredOutputFormats: declaredOutputFormats
                ?? video.formatDescriptors,
            process: process
        )
    }

    func temporalProcessingHook(
        for video: MediaTrackNodeV4,
        declaredOutputFormats: [MediaTrackFormatDescriptorV4]? = nil,
        outputCount: Int,
        process: @escaping AVFoundationVideoTrackProcessingHookV4
            .TemporalProcessor
    ) throws -> AVFoundationVideoTrackProcessingHookV4 {
        guard video.formatDescriptors.count == 1 else {
            throw TrackMigrationFixtureErrorV4.invalidFixture(
                "Expected one video format description."
            )
        }
        return AVFoundationVideoTrackProcessingHookV4(
            trackID: video.identity.stableID,
            readerOutputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    Int(kCVPixelFormatType_32BGRA)
            ],
            writerOutputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: TrackMigrationFixtureFactoryV4.width,
                AVVideoHeightKey: TrackMigrationFixtureFactoryV4.height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoExpectedSourceFrameRateKey: 30,
                    AVVideoMaxKeyFrameIntervalKey: 8
                ]
            ],
            declaredOutputFormats: declaredOutputFormats
                ?? video.formatDescriptors,
            outputTimingContract: .uniformlySubdivideSourceInterval(
                outputCount: outputCount,
                invalidSourceDurationFallback: try ExactRationalV4(1, 30)
            ),
            processTemporal: process
        )
    }

    func graphWithEmptyEdit(
        _ source: MediaTrackGraphV4
    ) throws -> MediaTrackGraphV4 {
        guard let first = source.tracks.first else {
            throw TrackMigrationFixtureErrorV4.invalidFixture("No tracks.")
        }
        let emptyEdit = try MediaTrackEditV4(
            ordinal: 0,
            source: nil,
            target: first.timeRange,
            isEmpty: true
        )
        let replacement = try MediaTrackNodeV4(
            identity: first.identity,
            enabled: first.enabled,
            kind: first.kind,
            sourceMediaTypeID: first.sourceMediaTypeID,
            language: first.language,
            roleIDs: first.roleIDs,
            timebase: first.timebase,
            timeRange: first.timeRange,
            edits: [emptyEdit],
            formatDescriptors: first.formatDescriptors,
            metadataFingerprint: first.metadataFingerprint
        )
        var tracks = source.tracks
        tracks[0] = replacement
        return try MediaTrackGraphV4(
            tracks: tracks,
            groups: source.groups,
            associations: source.associations,
            diagnostics: source.diagnostics
        )
    }

    func graphReplacingFirstTrackKind(
        _ source: MediaTrackGraphV4,
        kind: MediaTrackKindV4,
        sourceMediaTypeID: String
    ) throws -> MediaTrackGraphV4 {
        guard let first = source.tracks.first else {
            throw TrackMigrationFixtureErrorV4.invalidFixture("No tracks.")
        }
        let replacement = try MediaTrackNodeV4(
            identity: first.identity,
            enabled: first.enabled,
            kind: kind,
            sourceMediaTypeID: sourceMediaTypeID,
            language: first.language,
            roleIDs: first.roleIDs,
            timebase: first.timebase,
            timeRange: first.timeRange,
            edits: first.edits,
            formatDescriptors: first.formatDescriptors,
            metadataFingerprint: first.metadataFingerprint
        )
        var tracks = source.tracks
        tracks[0] = replacement
        return try MediaTrackGraphV4(
            tracks: tracks,
            groups: source.groups,
            associations: source.associations,
            diagnostics: source.diagnostics
        )
    }
}

private final class TrackMigrationProgressRecorderV4: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [AVFoundationTrackMigrationProgressV4] = []

    func record(_ value: AVFoundationTrackMigrationProgressV4) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func snapshot() -> [AVFoundationTrackMigrationProgressV4] {
        lock.lock()
        let snapshot = values
        lock.unlock()
        return snapshot
    }
}

private struct TrackMigrationFixtureDirectoryV4 {
    let rootURL: URL

    init() throws {
        rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mirmir-track-migration-v4-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: false
        )
    }

    func url(_ name: String) -> URL {
        rootURL.appendingPathComponent(name)
    }

    func containsPartialMovie() throws -> Bool {
        try FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil
        ).contains {
            $0.lastPathComponent.hasPrefix(".mirmir-track-v4-")
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

private enum TrackMigrationFixtureErrorV4: Error {
    case invalidFixture(String)
    case writer(String)
    case coreMedia(OSStatus)
}

private actor TrackMigrationDoubleRateCopyBackendV4:
    PreparedTemporalFrameUpscaler {
    nonisolated let sourcePixelBufferAttributes: PixelBufferAttributes
    nonisolated let destinationPixelBufferAttributes: PixelBufferAttributes
    nonisolated let actualBackendID = UpscaleBackendID.mirmirDeterministicCPU
    nonisolated let maximumOutputFramesPerInput = 2

    private let width: Int
    private let height: Int
    private var processedCount = 0
    private var finished = false

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        let attributes = PixelBufferAttributes([
            kCVPixelBufferPixelFormatTypeKey as String:
                Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ])
        sourcePixelBufferAttributes = attributes
        destinationPixelBufferAttributes = attributes
    }

    func process(
        source: FramePixelBuffer,
        destination: FramePixelBuffer,
        timing: FrameTiming
    ) async throws {
        try copy(source.value, to: destination.value)
    }

    func processTemporal(
        source: FramePixelBuffer,
        destinations: [FramePixelBuffer],
        timing: FrameTiming
    ) async throws -> [TemporalOutputFrame] {
        guard destinations.count >= 2 else {
            throw TrackMigrationFixtureErrorV4.invalidFixture(
                "The temporal adapter did not allocate two destinations."
            )
        }
        try copy(source.value, to: destinations[0].value)
        try copy(source.value, to: destinations[1].value)
        let halfDuration = CMTimeMultiplyByRatio(
            timing.duration,
            multiplier: 1,
            divisor: 2
        )
        processedCount += 1
        return [
            TemporalOutputFrame(
                pixelBuffer: destinations[0],
                presentationTime: timing.presentationTime
            ),
            TemporalOutputFrame(
                pixelBuffer: destinations[1],
                presentationTime: CMTimeAdd(
                    timing.presentationTime,
                    halfDuration
                )
            )
        ]
    }

    func finish() async throws {
        finished = true
    }

    func processedInputCount() -> Int { processedCount }
    func wasFinished() -> Bool { finished }

    private func copy(_ source: CVPixelBuffer, to destination: CVPixelBuffer)
        throws {
        guard CVPixelBufferGetPixelFormatType(source)
                == kCVPixelFormatType_32BGRA,
              CVPixelBufferGetPixelFormatType(destination)
                == kCVPixelFormatType_32BGRA,
              CVPixelBufferGetWidth(source) == width,
              CVPixelBufferGetHeight(source) == height,
              CVPixelBufferGetWidth(destination) == width,
              CVPixelBufferGetHeight(destination) == height else {
            throw TrackMigrationFixtureErrorV4.invalidFixture(
                "Unexpected copy-buffer geometry."
            )
        }
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(destination, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        guard let sourceBase = CVPixelBufferGetBaseAddress(source),
              let destinationBase = CVPixelBufferGetBaseAddress(destination)
        else {
            throw TrackMigrationFixtureErrorV4.invalidFixture(
                "Copy buffer has no base address."
            )
        }
        let sourceStride = CVPixelBufferGetBytesPerRow(source)
        let destinationStride = CVPixelBufferGetBytesPerRow(destination)
        for row in 0..<height {
            memcpy(
                destinationBase.advanced(by: row * destinationStride),
                sourceBase.advanced(by: row * sourceStride),
                width * 4
            )
        }
        CVBufferPropagateAttachments(source, destination)
    }
}

private enum TrackMigrationFixtureFactoryV4 {
    static let width = 64
    static let height = 48
    private static let frameRate: CMTimeScale = 30
    static let frameCount = 8

    private struct VideoLane {
        let input: AVAssetWriterInput
        let adaptor: AVAssetWriterInputPixelBufferAdaptor
        let seed: UInt8
    }

    static func makeReencodedVideo(source sourceURL: URL, at url: URL)
        async throws {
        let asset = AVURLAsset(
            url: sourceURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let sourceTracks = try await asset.loadTracks(withMediaType: .video)
        guard let sourceTrack = sourceTracks.first else {
            throw TrackMigrationFixtureErrorV4.invalidFixture(
                "Calibration source has no video."
            )
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: sourceTrack,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    Int(kCVPixelFormatType_32BGRA)
            ]
        )
        guard reader.canAdd(output) else {
            throw TrackMigrationFixtureErrorV4.invalidFixture(
                "Calibration reader rejected video."
            )
        }
        reader.add(output)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: videoOutputSettings
        )
        input.mediaTimeScale = try await sourceTrack.load(.naturalTimeScale)
        guard writer.canAdd(input) else {
            throw TrackMigrationFixtureErrorV4.invalidFixture(
                "Calibration writer rejected video."
            )
        }
        writer.add(input)
        guard reader.startReading(), writer.startWriting() else {
            throw TrackMigrationFixtureErrorV4.writer(
                writer.error?.localizedDescription
                    ?? reader.error?.localizedDescription
                    ?? "Calibration start failed."
            )
        }
        writer.startSession(atSourceTime: .zero)
        while let sample = output.copyNextSampleBuffer() {
            try await waitUntilReady(input, writer: writer)
            guard input.append(sample) else {
                throw TrackMigrationFixtureErrorV4.writer(
                    writer.error?.localizedDescription
                        ?? "Calibration append failed."
                )
            }
        }
        input.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        guard reader.status == .completed, writer.status == .completed else {
            throw TrackMigrationFixtureErrorV4.writer(
                writer.error?.localizedDescription
                    ?? reader.error?.localizedDescription
                    ?? "Calibration finish failed."
            )
        }
    }

    static func makeRichMovie(
        at url: URL,
        includeAudioGroup: Bool
    ) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let firstVideo = makeVideoLane(seed: 17, title: "primary-video")
        let secondVideo = makeVideoLane(seed: 113, title: "alternate-video")
        let audioFormat = try makeAudioFormatDescription()
        let englishAudio = makeAudioInput(
            languageCode: "eng",
            extendedLanguageTag: "en-US",
            title: "English",
            format: audioFormat
        )
        let spanishAudio = makeAudioInput(
            languageCode: "spa",
            extendedLanguageTag: "es-ES",
            title: "Spanish",
            format: audioFormat
        )
        let metadataGroup = makeTimedMetadataGroup()
        guard let metadataFormat = metadataGroup.copyFormatDescription() else {
            throw TrackMigrationFixtureErrorV4.invalidFixture(
                "Could not create timed metadata format."
            )
        }
        let metadataInput = AVAssetWriterInput(
            mediaType: .metadata,
            outputSettings: nil,
            sourceFormatHint: metadataFormat
        )
        metadataInput.metadata = trackMetadata(title: "Telemetry")
        let metadataAdaptor = AVAssetWriterInputMetadataAdaptor(
            assetWriterInput: metadataInput
        )
        let chapterGroup = makeChapterMetadataGroup()
        guard let chapterFormat = chapterGroup.copyFormatDescription() else {
            throw TrackMigrationFixtureErrorV4.invalidFixture(
                "Could not create chapter metadata format."
            )
        }
        let chapterInput = AVAssetWriterInput(
            mediaType: .metadata,
            outputSettings: nil,
            sourceFormatHint: chapterFormat
        )
        chapterInput.mediaDataLocation = .beforeMainMediaDataNotInterleaved
        let chapterAdaptor = AVAssetWriterInputMetadataAdaptor(
            assetWriterInput: chapterInput
        )
        let timecodeFormat = try makeTimecodeFormatDescription()
        let timecodeInput = AVAssetWriterInput(
            mediaType: .timecode,
            outputSettings: nil,
            sourceFormatHint: timecodeFormat
        )
        timecodeInput.mediaTimeScale = frameRate

        let allInputs = [
            firstVideo.input,
            secondVideo.input,
            englishAudio,
            spanishAudio,
            timecodeInput,
            metadataInput,
            chapterInput
        ]
        for input in allInputs {
            guard writer.canAdd(input) else {
                throw TrackMigrationFixtureErrorV4.writer(
                    "Writer rejected \(input.mediaType.rawValue)."
                )
            }
            writer.add(input)
        }
        if includeAudioGroup {
            let group = AVAssetWriterInputGroup(
                inputs: [englishAudio, spanishAudio],
                defaultInput: englishAudio
            )
            guard writer.canAdd(group) else {
                throw TrackMigrationFixtureErrorV4.writer(
                    "Writer rejected alternate audio group."
                )
            }
            writer.add(group)
        }
        let associationType = AVAssetTrack.AssociationType.metadataReferent
            .rawValue
        guard metadataInput.canAddTrackAssociation(
            withTrackOf: firstVideo.input,
            type: associationType
        ) else {
            throw TrackMigrationFixtureErrorV4.writer(
                "Writer rejected metadata referent association."
            )
        }
        metadataInput.addTrackAssociation(
            withTrackOf: firstVideo.input,
            type: associationType
        )
        for (target, type) in [
            (timecodeInput, AVAssetTrack.AssociationType.timecode.rawValue),
            (chapterInput, AVAssetTrack.AssociationType.chapterList.rawValue)
        ] {
            guard firstVideo.input.canAddTrackAssociation(
                withTrackOf: target,
                type: type
            ) else {
                throw TrackMigrationFixtureErrorV4.writer(
                    "Writer rejected \(type) association."
                )
            }
            firstVideo.input.addTrackAssociation(
                withTrackOf: target,
                type: type
            )
        }

        guard writer.startWriting() else {
            throw TrackMigrationFixtureErrorV4.writer(
                writer.error?.localizedDescription ?? "startWriting failed"
            )
        }
        writer.startSession(atSourceTime: .zero)

        let audioBuffer = try makeAudioSampleBuffer(
            format: audioFormat,
            amplitude: 700
        )
        let alternateAudioBuffer = try makeAudioSampleBuffer(
            format: audioFormat,
            amplitude: -700
        )
        try await append(
            audioBuffer,
            to: englishAudio,
            writer: writer
        )
        try await append(
            alternateAudioBuffer,
            to: spanishAudio,
            writer: writer
        )
        englishAudio.markAsFinished()
        spanishAudio.markAsFinished()

        try await waitUntilReady(metadataInput, writer: writer)
        guard metadataAdaptor.append(metadataGroup) else {
            throw TrackMigrationFixtureErrorV4.writer(
                writer.error?.localizedDescription
                    ?? "Timed metadata append failed."
            )
        }
        metadataInput.markAsFinished()
        try await waitUntilReady(chapterInput, writer: writer)
        guard chapterAdaptor.append(chapterGroup) else {
            throw TrackMigrationFixtureErrorV4.writer(
                writer.error?.localizedDescription
                    ?? "Chapter metadata append failed."
            )
        }
        chapterInput.markAsFinished()
        try await append(
            try makeTimecodeSampleBuffer(format: timecodeFormat),
            to: timecodeInput,
            writer: writer
        )
        timecodeInput.markAsFinished()

        for frameIndex in 0..<frameCount {
            let time = CMTime(
                value: CMTimeValue(frameIndex),
                timescale: frameRate
            )
            try await appendFrame(
                lane: firstVideo,
                frameIndex: frameIndex,
                time: time,
                writer: writer
            )
            try await appendFrame(
                lane: secondVideo,
                frameIndex: frameIndex,
                time: time,
                writer: writer
            )
        }
        firstVideo.input.markAsFinished()
        secondVideo.input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(
            value: CMTimeValue(frameCount),
            timescale: frameRate
        ))
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else {
            throw TrackMigrationFixtureErrorV4.writer(
                writer.error?.localizedDescription ?? "finishWriting failed"
            )
        }
    }

    private static func makeVideoLane(
        seed: UInt8,
        title: String
    ) -> VideoLane {
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: videoOutputSettings
        )
        input.mediaTimeScale = 600
        input.metadata = trackMetadata(title: title)
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String:
                Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        return VideoLane(
            input: input,
            adaptor: AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: attributes
            ),
            seed: seed
        )
    }

    private static var videoOutputSettings: [String: Any] {
        [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey:
                    AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey:
                    AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey:
                    AVVideoYCbCrMatrix_ITU_R_709_2
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoExpectedSourceFrameRateKey: frameRate,
                AVVideoMaxKeyFrameIntervalKey: frameCount
            ]
        ]
    }

    private static func makeAudioInput(
        languageCode: String,
        extendedLanguageTag: String,
        title: String,
        format: CMAudioFormatDescription
    ) -> AVAssetWriterInput {
        let input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: nil,
            sourceFormatHint: format
        )
        input.languageCode = languageCode
        input.extendedLanguageTag = extendedLanguageTag
        input.metadata = trackMetadata(title: title)
        return input
    }

    private static func makeAudioFormatDescription() throws
        -> CMAudioFormatDescription {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger
                | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var format: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &format
        )
        guard status == noErr, let format else {
            throw TrackMigrationFixtureErrorV4.coreMedia(status)
        }
        return format
    }

    private static func makeAudioSampleBuffer(
        format: CMAudioFormatDescription,
        amplitude: Int16
    ) throws -> CMSampleBuffer {
        let frameCount = 12_000
        let samples = [Int16](repeating: amplitude, count: frameCount)
        let byteCount = samples.count * MemoryLayout<Int16>.size
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let blockBuffer else {
            throw TrackMigrationFixtureErrorV4.coreMedia(status)
        }
        status = samples.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(
                with: $0.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: byteCount
            )
        }
        guard status == kCMBlockBufferNoErr else {
            throw TrackMigrationFixtureErrorV4.coreMedia(status)
        }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        var sampleSize = MemoryLayout<Int16>.size
        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleCount: frameCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            throw TrackMigrationFixtureErrorV4.coreMedia(status)
        }
        return sampleBuffer
    }

    private static func makeTimedMetadataGroup() -> AVTimedMetadataGroup {
        let item = AVMutableMetadataItem()
        item.identifier = .quickTimeMetadataLocationISO6709
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        item.value = "+37.3318-122.0312/" as NSString
        item.extendedLanguageTag = "en-US"
        return AVTimedMetadataGroup(
            items: [item],
            timeRange: CMTimeRange(
                start: .zero,
                duration: CMTime(value: 1, timescale: frameRate)
            )
        )
    }

    private static func makeChapterMetadataGroup() -> AVTimedMetadataGroup {
        let item = AVMutableMetadataItem()
        item.identifier = .quickTimeUserDataChapter
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        item.value = "Opening" as NSString
        item.extendedLanguageTag = "en-US"
        return AVTimedMetadataGroup(
            items: [item],
            timeRange: CMTimeRange(
                start: .zero,
                duration: CMTime(
                    value: CMTimeValue(frameCount),
                    timescale: frameRate
                )
            )
        )
    }

    private static func makeTimecodeFormatDescription() throws
        -> CMTimeCodeFormatDescription {
        var format: CMTimeCodeFormatDescription?
        let status = CMTimeCodeFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            timeCodeFormatType: kCMTimeCodeFormatType_TimeCode32,
            frameDuration: CMTime(value: 1, timescale: frameRate),
            frameQuanta: UInt32(frameRate),
            flags: 0,
            extensions: nil,
            formatDescriptionOut: &format
        )
        guard status == noErr, let format else {
            throw TrackMigrationFixtureErrorV4.coreMedia(status)
        }
        return format
    }

    private static func makeTimecodeSampleBuffer(
        format: CMTimeCodeFormatDescription
    ) throws -> CMSampleBuffer {
        var frameNumber = Int32(0).bigEndian
        let data = withUnsafeBytes(of: &frameNumber) { Data($0) }
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: data.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: data.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let blockBuffer else {
            throw TrackMigrationFixtureErrorV4.coreMedia(status)
        }
        status = data.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(
                with: $0.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: data.count
            )
        }
        guard status == kCMBlockBufferNoErr else {
            throw TrackMigrationFixtureErrorV4.coreMedia(status)
        }
        var timing = CMSampleTimingInfo(
            duration: CMTime(
                value: CMTimeValue(frameCount),
                timescale: frameRate
            ),
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        var sampleSize = data.count
        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            throw TrackMigrationFixtureErrorV4.coreMedia(status)
        }
        return sampleBuffer
    }

    private static func trackMetadata(title: String) -> [AVMetadataItem] {
        let item = AVMutableMetadataItem()
        item.identifier = .commonIdentifierTitle
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        item.value = title as NSString
        return [item]
    }

    private static func appendFrame(
        lane: VideoLane,
        frameIndex: Int,
        time: CMTime,
        writer: AVAssetWriter
    ) async throws {
        try await waitUntilReady(lane.input, writer: writer)
        guard let pool = lane.adaptor.pixelBufferPool else {
            throw TrackMigrationFixtureErrorV4.invalidFixture(
                "Video pixel-buffer pool is unavailable."
            )
        }
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(
            kCFAllocatorDefault,
            pool,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw TrackMigrationFixtureErrorV4.coreMedia(status)
        }
        fill(
            pixelBuffer: pixelBuffer,
            seed: lane.seed &+ UInt8(truncatingIfNeeded: frameIndex)
        )
        guard lane.adaptor.append(pixelBuffer, withPresentationTime: time) else {
            throw TrackMigrationFixtureErrorV4.writer(
                writer.error?.localizedDescription ?? "Video append failed."
            )
        }
    }

    private static func append(
        _ sampleBuffer: CMSampleBuffer,
        to input: AVAssetWriterInput,
        writer: AVAssetWriter
    ) async throws {
        try await waitUntilReady(input, writer: writer)
        guard input.append(sampleBuffer) else {
            throw TrackMigrationFixtureErrorV4.writer(
                writer.error?.localizedDescription ?? "Audio append failed."
            )
        }
    }

    private static func waitUntilReady(
        _ input: AVAssetWriterInput,
        writer: AVAssetWriter
    ) async throws {
        while !input.isReadyForMoreMediaData {
            if writer.status == .failed || writer.status == .cancelled {
                throw TrackMigrationFixtureErrorV4.writer(
                    writer.error?.localizedDescription ?? "Writer stopped."
                )
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private static func fill(pixelBuffer: CVPixelBuffer, seed: UInt8) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return
        }
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let width = CVPixelBufferGetWidth(pixelBuffer)
        for y in 0..<height {
            let row = base.advanced(by: y * rowBytes)
                .assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                let offset = x * 4
                row[offset] = seed &+ UInt8(truncatingIfNeeded: x)
                row[offset + 1] = seed &+ UInt8(truncatingIfNeeded: y)
                row[offset + 2] = seed
                row[offset + 3] = 255
            }
        }
    }
}

private func XCTAssertThrowsErrorAsyncV4<T>(
    _ expression: @autoclosure () async throws -> T,
    _ handler: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error.", file: file, line: line)
    } catch {
        handler(error)
    }
}
