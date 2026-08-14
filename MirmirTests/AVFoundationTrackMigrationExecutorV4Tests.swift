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
            includeAudioGroup: true
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
        let execution = try await VideoProcessingSession()
            .processWithDeterministicV4ExecutionReceipt(
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
        let result = execution.result
        let receipt = execution.receipt

        XCTAssertEqual(result.encodedWidth, 96)
        XCTAssertEqual(result.encodedHeight, 72)
        XCTAssertEqual(result.audioResult, .preserved)
        XCTAssertEqual(
            result.processedFrameCount,
            TrackMigrationFixtureFactoryV4.frameCount
        )
        XCTAssertGreaterThan(result.processingDurationSeconds, 0)
        XCTAssertEqual(
            receipt.schemaID,
            DeterministicV4MediaExecutionReceiptV4.currentSchemaID
        )
        XCTAssertEqual(
            receipt.preparedBackendType,
            "Mirmir.PreparedDeterministicV4Upscaler"
        )
        XCTAssertEqual(receipt.executor, .cpuFixedPoint)
        XCTAssertEqual(receipt.requestedBackendID, .mirmirDeterministicCPU)
        XCTAssertEqual(receipt.actualBackendID, .mirmirDeterministicCPU)
        XCTAssertEqual(receipt.runtimeManifestSHA256, runtime.manifestSHA256)
        XCTAssertEqual(
            receipt.runtimeProvenanceSHA256,
            try runtime.manifest.provenance.canonicalSHA256
        )
        XCTAssertEqual(receipt.targetWidth, 96)
        XCTAssertEqual(receipt.targetHeight, 72)
        XCTAssertEqual(receipt.encodedWidth, result.encodedWidth)
        XCTAssertEqual(receipt.encodedHeight, result.encodedHeight)
        XCTAssertEqual(
            receipt.processedFrameCount,
            result.processedFrameCount
        )
        XCTAssertEqual(
            receipt.sourceGraphSHA256,
            receipt.migrationSourceGraphSHA256
        )
        XCTAssertEqual(receipt.trackPlanSHA256, receipt.migrationPlanSHA256)
        XCTAssertEqual(receipt.plannedTracks.count, receipt.migratedTracks.count)
        XCTAssertEqual(
            receipt.migratedTracks.map { [$0.stableID, $0.action.rawValue] },
            receipt.plannedTracks.map { [$0.stableID, $0.action.rawValue] }
        )
        XCTAssertNil(receipt.alphaVerification)
        let receiptData = try ASHCanonicalJSONV4.encode(receipt)
        XCTAssertEqual(
            try ASHCanonicalJSONV4.decode(
                DeterministicV4MediaExecutionReceiptV4.self,
                from: receiptData
            ),
            receipt
        )

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
        XCTAssertEqual(outputGraph.groups.count, 1)
        XCTAssertNotNil(outputGraph.groups[0].defaultTrackID)
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

    func testDeterministicSessionAutomaticallyTranscodesIncompatibleAlternateAudio()
        async throws {
        let directory = try TrackMigrationFixtureDirectoryV4()
        defer { directory.remove() }
        let sourceURL = directory.url("deterministic-multiformat-source.mov")
        let destinationURL = directory.url("deterministic-multiformat-output.mov")
        let runtimeURL = directory.url("deterministic-multiformat-p06.bundle")
        try await TrackMigrationFixtureFactoryV4
            .makeRichMovieWithIncompatibleAudioTransitions(
                at: sourceURL,
                includeAudioGroup: true
            )
        let sourceAsset = AVURLAsset(url: sourceURL)
        let sourceGraph = try await AVFoundationTrackGraphAdapterV4.probe(
            asset: sourceAsset
        )
        let sourceAudio = sourceGraph.tracks.filter { $0.kind == .audio }
        XCTAssertEqual(sourceAudio.count, 2)
        XCTAssertTrue(sourceAudio.allSatisfy {
            $0.formatDescriptors.count == 2
        })
        let sourceGroup = try XCTUnwrap(sourceGraph.groups.first)

        let source = try await VideoProbe().probe(url: sourceURL)
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
        let preparedBackend = try await backend.prepare(
            request: BackendPreparationRequest(
                source: source,
                targetSize: CGSize(width: 96, height: 72)
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
            preparedBackend: preparedBackend,
            cancellation: ProcessingCancellation(),
            progress: { _ in }
        )

        XCTAssertEqual(result.audioResult, .transcoded)
        let outputGraph = try await AVFoundationTrackGraphAdapterV4.probe(
            asset: AVURLAsset(url: destinationURL)
        )
        let outputAudio = outputGraph.tracks.filter { $0.kind == .audio }
        XCTAssertEqual(outputAudio.count, 2)
        XCTAssertTrue(outputAudio.allSatisfy {
            $0.formatDescriptors.count == 1
                && $0.formatDescriptors[0].mediaSubtypeID
                    == "fourcc_61616320"
        })
        XCTAssertEqual(outputGraph.groups.first, sourceGroup)
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
            result.sourceAssetMetadataSHA256,
            result.outputAssetMetadataSHA256
        )
        XCTAssertEqual(
            result.sourceChapterMetadataSHA256,
            result.outputChapterMetadataSHA256
        )
        let sourceAssetMetadata = try await sourceAsset.load(.metadata)
        XCTAssertFalse(sourceAssetMetadata.isEmpty)
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

    func testMigrationUsesBoundDeterministicTemporaryAndRejectsUnsafePaths()
        async throws {
        let directory = try TrackMigrationFixtureDirectoryV4()
        defer { directory.remove() }
        let sourceURL = directory.url("deterministic-temp-source.mov")
        try await TrackMigrationFixtureFactoryV4.makeRichMovie(
            at: sourceURL,
            includeAudioGroup: false
        )
        let source = try await AVFoundationTrackGraphAdapterV4.probe(
            asset: AVURLAsset(url: sourceURL)
        )
        let plan = try MediaTrackGraphPlannerV4.makePlan(source: source)
        let blueprint = try AVFoundationTrackMigrationPlannerV4.makeBlueprint(
            source: source,
            plan: plan
        )

        let destinationURL = directory.url("deterministic-temp-output.mov")
        let temporaryURL = directory.url(
            ".mirmir-migration-bound.partial.mov"
        )
        let result = try await AVFoundationTrackMigrationExecutorV4().execute(
            .init(
                sourceURL: sourceURL,
                destinationURL: destinationURL,
                temporaryURL: temporaryURL,
                sourceGraph: source,
                identifiedPlan: plan,
                blueprint: blueprint
            )
        )
        XCTAssertEqual(result.destinationURL, destinationURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryURL.path))

        await XCTAssertThrowsErrorAsyncV4(
            try await AVFoundationTrackMigrationExecutorV4().execute(
                .init(
                    sourceURL: sourceURL,
                    destinationURL: directory.url("unsafe-name-output.mov"),
                    temporaryURL: directory.url("ordinary-temporary.mov"),
                    sourceGraph: source,
                    identifiedPlan: plan,
                    blueprint: blueprint
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? AVFoundationTrackMigrationExecutorV4Error,
                .invalidTemporaryDestination
            )
        }

        let occupiedURL = directory.url(
            ".mirmir-migration-occupied.partial.mov"
        )
        try Data("not-owned-by-this-execution".utf8).write(to: occupiedURL)
        await XCTAssertThrowsErrorAsyncV4(
            try await AVFoundationTrackMigrationExecutorV4().execute(
                .init(
                    sourceURL: sourceURL,
                    destinationURL: directory.url("occupied-temp-output.mov"),
                    temporaryURL: occupiedURL,
                    sourceGraph: source,
                    identifiedPlan: plan,
                    blueprint: blueprint
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? AVFoundationTrackMigrationExecutorV4Error,
                .destinationExists
            )
        }
        XCTAssertEqual(
            try Data(contentsOf: occupiedURL),
            Data("not-owned-by-this-execution".utf8)
        )
    }

    func testWorkflowSourceProgressCursorReadsTrackLinearlyAcrossBoundaries()
        async throws {
        let directory = try TrackMigrationFixtureDirectoryV4()
        defer { directory.remove() }
        let sourceURL = directory.url("linear-progress-source.mov")
        try await TrackMigrationFixtureFactoryV4.makeRichMovie(
            at: sourceURL,
            includeAudioGroup: true
        )
        let asset = AVURLAsset(
            url: sourceURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let audioTrack = try XCTUnwrap(audioTracks.first)
        let duration = try await asset.load(.duration)
        XCTAssertTrue(duration.isNumeric)
        XCTAssertGreaterThan(duration.value, 0)
        let cursor = try WorkflowSourceTrackProgressCursorV4(
            asset: asset,
            track: audioTrack
        )
        defer { cursor.cancel() }

        var observations: [WorkflowSourceTrackProgressObservationV4] = []
        for divisor in [4, 2, 1] {
            let boundary = CMTimeMultiplyByRatio(
                duration,
                multiplier: 1,
                divisor: Int32(divisor)
            )
            observations.append(try cursor.progress(
                through: WorkflowMediaTimeV4(
                    value: boundary.value,
                    timescale: boundary.timescale
                )
            ))
        }
        XCTAssertEqual(cursor.readerCreationCount, 1)
        let finalObservation = try XCTUnwrap(observations.last)
        XCTAssertGreaterThan(finalObservation.count, 0)
        XCTAssertTrue(zip(observations, observations.dropFirst()).allSatisfy {
            $0.0.count <= $0.1.count
        })
        XCTAssertEqual(
            cursor.copiedSampleCount,
            finalObservation.count + cursor.nonTimedSampleBufferCount
        )
        let copiedAtEnd = cursor.copiedSampleCount
        _ = try cursor.progress(
            through: WorkflowMediaTimeV4(
                value: duration.value,
                timescale: duration.timescale
            )
        )
        XCTAssertEqual(cursor.copiedSampleCount, copiedAtEnd)

        XCTAssertThrowsError(try cursor.progress(
            through: WorkflowMediaTimeV4(value: 0, timescale: 1)
        ))
    }

    func testPassThroughHDRVideoUsesExactFrameBoundMetadataLossGate()
        async throws {
        let directory = try TrackMigrationFixtureDirectoryV4()
        defer { directory.remove() }
        let sourceURL = directory.url("dynamic-hdr-source.mov")
        let destinationURL = directory.url("dynamic-hdr-output.mov")
        try await TrackMigrationFixtureFactoryV4.makeRichMovie(
            at: sourceURL,
            includeAudioGroup: false
        )

        let source = try await AVFoundationTrackGraphAdapterV4.probe(
            asset: AVURLAsset(url: sourceURL)
        )
        XCTAssertEqual(source.tracks.filter { $0.kind == .video }.count, 2)
        let plan = try MediaTrackGraphPlannerV4.makePlan(source: source)
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
                blueprint: blueprint
            )
        )

        XCTAssertTrue(result.verificationReport.isConformant)
        let sourceSample = try await firstEncodedVideoSample(in: sourceURL)
        XCTAssertNil(
            try AVFoundationHDRMetadataAdapterV4.probeDynamicMetadata(
                from: sourceSample
            )
        )
        let metadata = try frameBoundHDRMetadata(seed: 0x20)
        let expectedSample = try copySampleBufferV4(sourceSample)
        try AVFoundationHDRMetadataAdapterV4.migrate(
            metadata,
            to: expectedSample
        )
        XCTAssertEqual(
            try AVFoundationHDRMetadataAdapterV4.probeDynamicMetadata(
                from: expectedSample
            ),
            metadata
        )
        let preservedSample = try copySampleBufferV4(sourceSample)
        try AVFoundationHDRMetadataAdapterV4.migrate(
            metadata,
            to: preservedSample
        )
        var expectedStream = DynamicHDRMetadataStreamAccumulatorV4()
        var preservedStream = DynamicHDRMetadataStreamAccumulatorV4()
        var strippedStream = DynamicHDRMetadataStreamAccumulatorV4()
        try expectedStream.append(expectedSample)
        try preservedStream.append(preservedSample)
        try strippedStream.append(sourceSample)
        XCTAssertNoThrow(try AVFoundationTrackMigrationExecutorV4
            .verifyDynamicHDRStream(
                expected: expectedStream,
                actual: preservedStream
            ))
        XCTAssertThrowsError(try AVFoundationTrackMigrationExecutorV4
            .verifyDynamicHDRStream(
                expected: expectedStream,
                actual: strippedStream
            )) { error in
                XCTAssertEqual(
                    error as? VideoWriterFormatContractV4Error,
                    .dynamicHDRMetadataMismatch
                )
            }
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destinationURL.path
        ))
        XCTAssertFalse(try directory.containsPartialMovie())
    }

    func testAlternateAudioGroupRoundTripsDefaultSelectionAndStreams()
        async throws {
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
        let sourceGroup = try XCTUnwrap(source.groups.first)
        let defaultTrackID = try XCTUnwrap(sourceGroup.defaultTrackID)
        XCTAssertFalse(sourceGroup.allowsEmptySelection)
        XCTAssertEqual(
            sourceGroup.memberTrackIDs.filter {
                source.track(id: $0)?.enabled == true
            },
            [defaultTrackID]
        )
        let plan = try MediaTrackGraphPlannerV4.makePlan(source: source)
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
                blueprint: blueprint
            )
        )

        XCTAssertTrue(result.verificationReport.isConformant)
        XCTAssertEqual(result.outputGraph.groups, source.groups)
        XCTAssertEqual(result.outputGraph, source)
        let audioTrackIDs = Set(source.tracks.filter { $0.kind == .audio }
            .map { $0.identity.stableID })
        let audioResults = result.trackResults.filter {
            audioTrackIDs.contains($0.trackID)
        }
        XCTAssertEqual(audioResults.count, 2)
        XCTAssertTrue(audioResults.allSatisfy {
            $0.action == .passThrough
                && $0.migratedSampleCount > 0
                && $0.sourceSampleStreamSHA256 != nil
                && $0.sourceSampleStreamSHA256
                    == $0.outputSampleStreamSHA256
        })
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destinationURL.path
        ))
        XCTAssertFalse(try directory.containsPartialMovie())
    }

    func testAlternateAudioGroupRoundTripsEmptySelection() async throws {
        let directory = try TrackMigrationFixtureDirectoryV4()
        defer { directory.remove() }
        let sourceURL = directory.url("empty-group-source.mov")
        let destinationURL = directory.url("empty-group-output.mov")
        try await TrackMigrationFixtureFactoryV4.makeRichMovie(
            at: sourceURL,
            includeAudioGroup: true,
            selectDefaultAudio: false
        )
        let source = try await AVFoundationTrackGraphAdapterV4.probe(
            asset: AVURLAsset(url: sourceURL)
        )
        let group = try XCTUnwrap(source.groups.first)
        XCTAssertNil(group.defaultTrackID)
        XCTAssertTrue(group.allowsEmptySelection)
        XCTAssertTrue(group.memberTrackIDs.allSatisfy { id in
            source.track(id: id)?.enabled == false
        })
        let plan = try MediaTrackGraphPlannerV4.makePlan(source: source)
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
                blueprint: blueprint
            )
        )

        XCTAssertTrue(result.verificationReport.isConformant)
        XCTAssertEqual(result.outputGraph, source)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destinationURL.path
        ))
        XCTAssertFalse(try directory.containsPartialMovie())
    }

    func testSameSemanticsAudioPayloadsRemainBoundToLogicalOrdinals()
        async throws {
        let directory = try TrackMigrationFixtureDirectoryV4()
        defer { directory.remove() }
        let sourceURL = directory.url("same-semantics-audio.mov")
        let destinationURL = directory.url("same-semantics-output.mov")
        try await TrackMigrationFixtureFactoryV4.makeTwinAudioPayloadMovie(
            at: sourceURL
        )
        let source = try await AVFoundationTrackGraphAdapterV4.probe(
            asset: AVURLAsset(url: sourceURL)
        )
        XCTAssertEqual(source.tracks.count, 2)
        let first = source.tracks[0]
        let second = source.tracks[1]
        XCTAssertEqual(first.kind, second.kind)
        XCTAssertEqual(first.enabled, second.enabled)
        XCTAssertEqual(first.language, second.language)
        XCTAssertEqual(first.roleIDs, second.roleIDs)
        XCTAssertEqual(first.timebase, second.timebase)
        XCTAssertEqual(first.timeRange, second.timeRange)
        XCTAssertEqual(first.edits, second.edits)
        XCTAssertEqual(first.formatDescriptors, second.formatDescriptors)
        XCTAssertEqual(first.metadataFingerprint, second.metadataFingerprint)
        let plan = try MediaTrackGraphPlannerV4.makePlan(source: source)
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
                blueprint: blueprint
            )
        )

        XCTAssertEqual(result.outputGraph, source)
        XCTAssertEqual(result.trackResults.count, 2)
        let sourceDigests = result.trackResults.compactMap(
            \.sourceSampleStreamSHA256
        )
        XCTAssertEqual(Set(sourceDigests).count, 2)
        XCTAssertTrue(result.trackResults.allSatisfy {
            $0.sourceSampleStreamSHA256 == $0.outputSampleStreamSHA256
        })
        XCTAssertFalse(try directory.containsPartialMovie())
    }

    func testAlternateAudioGroupReconstructsAfterConsentedMemberDrop()
        async throws {
        let directory = try TrackMigrationFixtureDirectoryV4()
        defer { directory.remove() }
        let sourceURL = directory.url("reconstructed-group-source.mov")
        let destinationURL = directory.url("reconstructed-group-output.mov")
        try await TrackMigrationFixtureFactoryV4.makeRichMovie(
            at: sourceURL,
            includeAudioGroup: true
        )
        let source = try await AVFoundationTrackGraphAdapterV4.probe(
            asset: AVURLAsset(url: sourceURL)
        )
        let group = try XCTUnwrap(source.groups.first)
        let defaultTrackID = try XCTUnwrap(group.defaultTrackID)
        let droppedTrackID = try XCTUnwrap(group.memberTrackIDs.first {
            $0 != defaultTrackID
        })
        let approval = ASHSHA256V4(
            rawData: Data("alternate-audio-member-drop".utf8)
        )
        let trackConsent = try MediaTrackDropConsentV4(
            subjectID: droppedTrackID.rawValue,
            reasonID: "user-approved-audio-drop",
            approvalSHA256: approval
        )
        let groupConsent = try MediaTrackDropConsentV4(
            subjectID: group.identity.stableID.rawValue,
            reasonID: "user-approved-audio-drop",
            approvalSHA256: approval
        )
        let plan = try MediaTrackGraphPlannerV4.makePlan(
            source: source,
            request: .init(
                trackDirectives: [MediaTrackDirectiveV4(
                    trackID: droppedTrackID,
                    action: .dropWithConsent,
                    targetFormatDescriptors: [],
                    dropConsent: trackConsent
                )],
                groupDirectives: [MediaTrackGroupDirectiveV4(
                    groupID: group.identity.stableID,
                    action: .transcode,
                    outputMemberTrackIDs: [defaultTrackID],
                    outputDefaultTrackID: defaultTrackID,
                    dropConsent: groupConsent
                )]
            )
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
                blueprint: blueprint
            )
        )

        XCTAssertTrue(result.verificationReport.isConformant)
        let outputGroup = try XCTUnwrap(result.outputGraph.groups.first)
        XCTAssertEqual(outputGroup.memberTrackIDs, [defaultTrackID])
        XCTAssertEqual(outputGroup.defaultTrackID, defaultTrackID)
        XCTAssertFalse(outputGroup.allowsEmptySelection)
        XCTAssertNil(result.outputGraph.track(id: droppedTrackID))
        let retainedResult = try XCTUnwrap(result.trackResults.first {
            $0.trackID == defaultTrackID
        })
        XCTAssertEqual(
            retainedResult.sourceSampleStreamSHA256,
            retainedResult.outputSampleStreamSHA256
        )
        XCTAssertFalse(try directory.containsPartialMovie())
    }

    func testAlternateAudioGroupRejectsContradictoryEnabledMembers()
        async throws {
        let directory = try TrackMigrationFixtureDirectoryV4()
        defer { directory.remove() }
        let sourceURL = directory.url("contradictory-group-source.mov")
        let destinationURL = directory.url("contradictory-group-output.mov")
        try await TrackMigrationFixtureFactoryV4.makeRichMovie(
            at: sourceURL,
            includeAudioGroup: true
        )
        let source = try await AVFoundationTrackGraphAdapterV4.probe(
            asset: AVURLAsset(url: sourceURL)
        )
        let group = try XCTUnwrap(source.groups.first)
        let contradictoryTracks = try source.tracks.map { track in
            guard group.memberTrackIDs.contains(track.identity.stableID) else {
                return track
            }
            return try trackReplacingEnabled(track, enabled: true)
        }
        let contradictorySource = try MediaTrackGraphV4(
            tracks: contradictoryTracks,
            groups: source.groups,
            associations: source.associations,
            diagnostics: source.diagnostics
        )
        let plan = try MediaTrackGraphPlannerV4.makePlan(
            source: contradictorySource
        )
        let blueprint = try AVFoundationTrackMigrationPlannerV4.makeBlueprint(
            source: contradictorySource,
            plan: plan
        )

        await XCTAssertThrowsErrorAsyncV4(
            try await AVFoundationTrackMigrationExecutorV4().execute(
                .init(
                    sourceURL: sourceURL,
                    destinationURL: destinationURL,
                    sourceGraph: contradictorySource,
                    identifiedPlan: plan,
                    blueprint: blueprint
                )
            )
        ) { error in
            guard case .unsupportedGroup(_, let reason) =
                error as? AVFoundationTrackMigrationExecutorV4Error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(
                reason,
                "enabled_state_not_representable_by_default"
            )
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

    func testEveryTranscodedAudioTrackRequiresAnExplicitTrackBoundHook()
        async throws {
        let directory = try TrackMigrationFixtureDirectoryV4()
        defer { directory.remove() }
        let sourceURL = directory.url("audio-hook-source.mov")
        let destinationURL = directory.url("audio-hook-output.mov")
        try await TrackMigrationFixtureFactoryV4.makeRichMovie(
            at: sourceURL,
            includeAudioGroup: false
        )
        let asset = AVURLAsset(url: sourceURL)
        let source = try await AVFoundationTrackGraphAdapterV4.probe(
            asset: asset
        )
        let audio = try XCTUnwrap(source.tracks.first { $0.kind == .audio })
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let sourceAudio = try XCTUnwrap(audioTracks.first)
        let calibration = try await AVFoundationAACFormatCalibratorV4()
            .calibrate(
                asset: asset,
                track: sourceAudio,
                trackID: audio.identity.stableID
            )
        let basePlan = try MediaTrackGraphPlannerV4.makePlan(
            source: source,
            request: .init(trackDirectives: [MediaTrackDirectiveV4(
                trackID: audio.identity.stableID,
                action: .transcode,
                targetFormatDescriptors: [calibration.targetFormat],
                dropConsent: nil
            )])
        )
        let plan = try basePlan.applyingTranscodePrimingDurations([
            audio.identity.stableID: calibration.encoderPrimingDuration
        ])
        let blueprint = try AVFoundationTrackMigrationPlannerV4.makeBlueprint(
            source: source,
            plan: plan
        )

        await XCTAssertThrowsErrorAsyncV4(
            try await AVFoundationTrackMigrationExecutorV4().execute(.init(
                sourceURL: sourceURL,
                destinationURL: destinationURL,
                sourceGraph: source,
                identifiedPlan: plan,
                blueprint: blueprint
            ))
        ) { error in
            XCTAssertEqual(
                error as? AVFoundationTrackMigrationExecutorV4Error,
                .missingProcessingHook(audio.identity.stableID)
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: destinationURL.path
        ))
        XCTAssertFalse(try directory.containsPartialMovie())
    }

    func testTrackBoundAudioHookTranscodesPCMToAACAndPreservesOtherTracks()
        async throws {
        let directory = try TrackMigrationFixtureDirectoryV4()
        defer { directory.remove() }
        let sourceURL = directory.url("audio-transcode-source.mov")
        let destinationURL = directory.url("audio-transcode-output.mov")
        try await TrackMigrationFixtureFactoryV4.makeRichMovie(
            at: sourceURL,
            includeAudioGroup: false
        )
        let asset = AVURLAsset(url: sourceURL)
        let source = try await AVFoundationTrackGraphAdapterV4.probe(
            asset: asset
        )
        let audio = try XCTUnwrap(source.tracks.first { $0.kind == .audio })
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let sourceAudio = try XCTUnwrap(audioTracks.first)
        let calibration = try await AVFoundationAACFormatCalibratorV4()
            .calibrate(
                asset: asset,
                track: sourceAudio,
                trackID: audio.identity.stableID
            )
        XCTAssertEqual(
            calibration.targetFormat.mediaSubtypeID,
            "fourcc_61616320"
        )
        let basePlan = try MediaTrackGraphPlannerV4.makePlan(
            source: source,
            request: .init(trackDirectives: [MediaTrackDirectiveV4(
                trackID: audio.identity.stableID,
                action: .transcode,
                targetFormatDescriptors: [calibration.targetFormat],
                dropConsent: nil
            )])
        )
        let plan = try basePlan.applyingTranscodePrimingDurations([
            audio.identity.stableID: calibration.encoderPrimingDuration
        ])
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
                nonVideoTranscodeHooks: [calibration.hook]
            )
        )

        XCTAssertTrue(result.verificationReport.isConformant)
        let outputAudio = try XCTUnwrap(result.outputGraph.track(
            id: audio.identity.stableID
        ))
        XCTAssertEqual(
            outputAudio.formatDescriptors,
            [calibration.targetFormat]
        )
        let audioResult = try XCTUnwrap(result.trackResults.first {
            $0.trackID == audio.identity.stableID
        })
        XCTAssertEqual(audioResult.action, .transcode)
        XCTAssertNil(audioResult.sourceSampleStreamSHA256)
        XCTAssertNil(audioResult.outputSampleStreamSHA256)
        XCTAssertTrue(result.trackResults.filter {
            $0.trackID != audio.identity.stableID
        }.allSatisfy {
            $0.action == .passThrough
                && $0.sourceSampleStreamSHA256
                    == $0.outputSampleStreamSHA256
        })
        XCTAssertFalse(try directory.containsPartialMovie())
    }

    func testAudioHookCannotPublishAByteMutatedDecodedPCMStream()
        async throws {
        let directory = try TrackMigrationFixtureDirectoryV4()
        defer { directory.remove() }
        let sourceURL = directory.url("audio-payload-mutation-source.mov")
        let destinationURL = directory.url("audio-payload-mutation-output.mov")
        let context = try await audioTranscodeContext(sourceURL: sourceURL)
        let calibratedHook = context.calibration.hook
        let hook = AVFoundationNonVideoTrackTranscodeHookV4(
            trackID: context.audio.identity.stableID,
            readerOutputSettings: calibratedHook.readerOutputSettings,
            writerOutputSettings: calibratedHook.writerOutputSettings,
            declaredOutputFormats: calibratedHook.declaredOutputFormats
        ) { wrapped in
            AVFoundationNonVideoSampleV4(
                sampleBuffer: try payloadMutatingCopyV4(
                    of: wrapped.sampleBuffer
                )
            )
        }

        await XCTAssertThrowsErrorAsyncV4(
            try await AVFoundationTrackMigrationExecutorV4().execute(.init(
                sourceURL: sourceURL,
                destinationURL: destinationURL,
                sourceGraph: context.source,
                identifiedPlan: context.plan,
                blueprint: context.blueprint,
                nonVideoTranscodeHooks: [hook]
            ))
        ) { error in
            XCTAssertEqual(
                error as? AVFoundationTrackMigrationExecutorV4Error,
                .processedSampleCanonicalStreamMismatch(
                    context.audio.identity.stableID
                )
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: destinationURL.path
        ))
        XCTAssertFalse(try directory.containsPartialMovie())
    }

    func testUnrequestedHookCancellationIsReportedAsProcessorFailure()
        async throws {
        let directory = try TrackMigrationFixtureDirectoryV4()
        defer { directory.remove() }
        let sourceURL = directory.url("false-cancellation-source.mov")
        let destinationURL = directory.url("false-cancellation-output.mov")
        let context = try await audioTranscodeContext(sourceURL: sourceURL)
        let calibratedHook = context.calibration.hook
        let hook = AVFoundationNonVideoTrackTranscodeHookV4(
            trackID: context.audio.identity.stableID,
            readerOutputSettings: calibratedHook.readerOutputSettings,
            writerOutputSettings: calibratedHook.writerOutputSettings,
            declaredOutputFormats: calibratedHook.declaredOutputFormats
        ) { _ in
            throw CancellationError()
        }

        await XCTAssertThrowsErrorAsyncV4(
            try await AVFoundationTrackMigrationExecutorV4().execute(.init(
                sourceURL: sourceURL,
                destinationURL: destinationURL,
                sourceGraph: context.source,
                identifiedPlan: context.plan,
                blueprint: context.blueprint,
                nonVideoTranscodeHooks: [hook]
            ))
        ) { error in
            guard case .processorFailed(let trackID, _) =
                    error as? AVFoundationTrackMigrationExecutorV4Error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(trackID, context.audio.identity.stableID)
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: destinationURL.path
        ))
        XCTAssertFalse(try directory.containsPartialMovie())
    }

    func testAACCalibrationPreservesRealFivePointOneAndSevenPointOneLayouts()
        async throws {
        let directory = try TrackMigrationFixtureDirectoryV4()
        defer { directory.remove() }
        let calibrator = AVFoundationAACFormatCalibratorV4()
        let cases: [(
            String,
            source: AudioChannelLayoutTag,
            encoder: AudioChannelLayoutTag,
            channels: UInt32
        )] = [
            (
                "five-one",
                kAudioChannelLayoutTag_MPEG_5_1_A,
                kAudioChannelLayoutTag_AAC_5_1,
                6
            ),
            (
                "seven-one",
                kAudioChannelLayoutTag_MPEG_7_1_C,
                kAudioChannelLayoutTag_AAC_7_1_B,
                8
            )
        ]

        for (name, sourceLayout, encoderLayout, channelCount) in cases {
            let sourceURL = directory.url("\(name)-source.mov")
            try await TrackMigrationFixtureFactoryV4.makeAudioMovie(
                at: sourceURL,
                channelLayoutTag: sourceLayout,
                amplitude: 500
            )
            let asset = AVURLAsset(url: sourceURL)
            let graph = try await AVFoundationTrackGraphAdapterV4.probe(
                asset: asset
            )
            let node = try XCTUnwrap(graph.tracks.first)
            let audioTracks = try await asset.loadTracks(
                withMediaType: .audio
            )
            let track = try XCTUnwrap(audioTracks.first)
            let calibration = try await calibrator.calibrate(
                asset: asset,
                track: track,
                trackID: node.identity.stableID
            )

            XCTAssertEqual(
                calibration.targetFormat.mediaSubtypeID,
                "fourcc_61616320"
            )
            XCTAssertEqual(
                calibration.hook.writerOutputSettings[
                    AVNumberOfChannelsKey
                ] as? Int,
                Int(channelCount)
            )
            let writerLayout = try XCTUnwrap(
                calibration.hook.writerOutputSettings[
                    AVChannelLayoutKey
                ] as? Data
            )
            let readerLayout = try XCTUnwrap(
                calibration.hook.readerOutputSettings[
                    AVChannelLayoutKey
                ] as? Data
            )
            XCTAssertEqual(writerLayout, readerLayout)
            XCTAssertEqual(
                channelLayoutTag(in: writerLayout),
                encoderLayout
            )
        }
        let cacheCount = await calibrator
            .cachedOutputCountForQualification()
        XCTAssertEqual(cacheCount, cases.count)
    }

    func testAACCalibrationCacheIsolatedByDistinctSixChannelLayouts()
        async throws {
        let directory = try TrackMigrationFixtureDirectoryV4()
        defer { directory.remove() }
        let calibrator = AVFoundationAACFormatCalibratorV4()
        var layoutData: [Data] = []
        var sourceFingerprints: [ASHSHA256V4] = []
        for (ordinal, tag) in [
            kAudioChannelLayoutTag_MPEG_5_1_A,
            kAudioChannelLayoutTag_MPEG_5_1_B
        ].enumerated() {
            let sourceURL = directory.url("cache-layout-\(ordinal).mov")
            try await TrackMigrationFixtureFactoryV4.makeAudioMovie(
                at: sourceURL,
                channelLayoutTag: tag,
                amplitude: Int16(400 + ordinal)
            )
            let asset = AVURLAsset(url: sourceURL)
            let graph = try await AVFoundationTrackGraphAdapterV4.probe(
                asset: asset
            )
            let sourceFormat = try XCTUnwrap(
                graph.tracks.first?.formatDescriptors.first
            )
            sourceFingerprints.append(sourceFormat.canonicalFingerprint)
            let audioTracks = try await asset.loadTracks(
                withMediaType: .audio
            )
            let track = try XCTUnwrap(audioTracks.first)
            let calibration = try await calibrator.calibrate(
                asset: asset,
                track: track,
                trackID: try XCTUnwrap(graph.tracks.first).identity.stableID
            )
            layoutData.append(try XCTUnwrap(
                calibration.hook.writerOutputSettings[
                    AVChannelLayoutKey
                ] as? Data
            ))
        }

        XCTAssertEqual(layoutData[0], layoutData[1])
        XCTAssertNotEqual(sourceFingerprints[0], sourceFingerprints[1])
        let cacheCount = await calibrator
            .cachedOutputCountForQualification()
        XCTAssertEqual(cacheCount, 2)
    }

    func testCompatibleRealMultipleAudioDescriptionsRoundTripExactly()
        async throws {
        let directory = try TrackMigrationFixtureDirectoryV4()
        defer { directory.remove() }
        let sourceURL = directory.url("compatible-real-multidesc.mov")
        let destinationURL = directory.url("compatible-real-output.mov")
        try await TrackMigrationFixtureFactoryV4
            .makeCompatibleMultiDescriptionAudioMovie(at: sourceURL)
        let source = try await AVFoundationTrackGraphAdapterV4.probe(
            asset: AVURLAsset(url: sourceURL)
        )
        let audio = try XCTUnwrap(source.tracks.first)
        XCTAssertEqual(audio.kind, .audio)
        XCTAssertEqual(audio.formatDescriptors.count, 2)
        XCTAssertNotEqual(
            audio.formatDescriptors[0].canonicalFingerprint,
            audio.formatDescriptors[1].canonicalFingerprint
        )
        let plan = try MediaTrackGraphPlannerV4.makePlan(source: source)
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
                blueprint: blueprint
            )
        )

        XCTAssertTrue(result.verificationReport.isConformant)
        XCTAssertEqual(result.outputGraph, source)
        let trackResult = try XCTUnwrap(result.trackResults.first)
        XCTAssertEqual(
            trackResult.sourceSampleStreamSHA256,
            trackResult.outputSampleStreamSHA256
        )
        XCTAssertFalse(try directory.containsPartialMovie())
    }

    func testAACCalibrationCancellationIsNotRelabeledAsCodecFailure()
        async throws {
        let directory = try TrackMigrationFixtureDirectoryV4()
        defer { directory.remove() }
        let sourceURL = directory.url("cancel-calibration.mov")
        try await TrackMigrationFixtureFactoryV4.makeAudioMovie(
            at: sourceURL,
            channelLayoutTag: kAudioChannelLayoutTag_MPEG_7_1_C,
            amplitude: 450
        )
        let asset = AVURLAsset(url: sourceURL)
        let graph = try await AVFoundationTrackGraphAdapterV4.probe(asset: asset)
        let node = try XCTUnwrap(graph.tracks.first)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(audioTracks.first)
        let cancellation = ProcessingCancellation()
        let task = Task {
            try await AVFoundationAACFormatCalibratorV4().calibrate(
                asset: asset,
                track: track,
                trackID: node.identity.stableID,
                cancellation: cancellation
            )
        }
        await Task.yield()
        cancellation.cancel()

        do {
            _ = try await task.value
            XCTFail("Calibration unexpectedly completed after cancellation.")
        } catch is CancellationError {
            // Exact error identity is the contract under test.
        } catch {
            XCTFail("Cancellation was relabeled as \(error).")
        }
    }

    func testCompatibleMultipleAudioFormatDescriptionsArePassThroughEligible()
        async throws {
        let directory = try TrackMigrationFixtureDirectoryV4()
        defer { directory.remove() }
        let sourceURL = directory.url("multi-format-compatible.mov")
        try await TrackMigrationFixtureFactoryV4.makeRichMovie(
            at: sourceURL,
            includeAudioGroup: false
        )
        let source = try await AVFoundationTrackGraphAdapterV4.probe(
            asset: AVURLAsset(url: sourceURL)
        )
        let audio = try XCTUnwrap(source.tracks.first { $0.kind == .audio })
        let descriptions = try [
            audioFormatDescription(sampleRate: 48_000, channels: 1),
            audioFormatDescription(sampleRate: 48_000, channels: 1)
        ]
        let formats = try descriptions.enumerated().map { ordinal, value in
            try AVFoundationTrackGraphAdapterV4.canonicalFormatDescriptor(
                value,
                ordinal: UInt32(ordinal)
            )
        }
        let planned = try passThroughTrack(audio, formats: formats)

        XCTAssertNoThrow(try AVFoundationTrackMigrationExecutorV4
            .validatePassThroughFormatInventory(
                descriptions,
                planned: planned,
                sourceMediaType: .audio
            ))
    }

    func testIncompatibleMultipleAudioFormatDescriptionsRequireTranscodeHook()
        async throws {
        let directory = try TrackMigrationFixtureDirectoryV4()
        defer { directory.remove() }
        let sourceURL = directory.url("multi-format-incompatible.mov")
        try await TrackMigrationFixtureFactoryV4.makeRichMovie(
            at: sourceURL,
            includeAudioGroup: false
        )
        let source = try await AVFoundationTrackGraphAdapterV4.probe(
            asset: AVURLAsset(url: sourceURL)
        )
        let audio = try XCTUnwrap(source.tracks.first { $0.kind == .audio })
        let descriptions = try [
            audioFormatDescription(sampleRate: 48_000, channels: 1),
            audioFormatDescription(sampleRate: 44_100, channels: 1)
        ]
        let formats = try descriptions.enumerated().map { ordinal, value in
            try AVFoundationTrackGraphAdapterV4.canonicalFormatDescriptor(
                value,
                ordinal: UInt32(ordinal)
            )
        }
        let planned = try passThroughTrack(audio, formats: formats)

        XCTAssertThrowsError(try AVFoundationTrackMigrationExecutorV4
            .validatePassThroughFormatInventory(
                descriptions,
                planned: planned,
                sourceMediaType: .audio
            )) { error in
                XCTAssertEqual(
                    error as? AVFoundationTrackMigrationExecutorV4Error,
                    .unsupportedTrack(
                        audio.identity.stableID,
                        reason:
                            "incompatible_format_transition_requires_transcode_hook"
                    )
                )
            }
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

    func testCancellationEnteringSourceMetadataScanRemainsCancelled()
        async throws {
        let directory = try TrackMigrationFixtureDirectoryV4()
        defer { directory.remove() }
        let sourceURL = directory.url("metadata-cancel-source.mov")
        let destinationURL = directory.url("metadata-cancel-output.mov")
        try await TrackMigrationFixtureFactoryV4.makeRichMovie(
            at: sourceURL,
            includeAudioGroup: false
        )
        let source = try await AVFoundationTrackGraphAdapterV4.probe(
            asset: AVURLAsset(url: sourceURL)
        )
        let plan = try MediaTrackGraphPlannerV4.makePlan(source: source)
        let blueprint = try AVFoundationTrackMigrationPlannerV4.makeBlueprint(
            source: source,
            plan: plan
        )
        let cancellation = AVFoundationTrackMigrationCancellationV4()

        await XCTAssertThrowsErrorAsyncV4(
            try await AVFoundationTrackMigrationExecutorV4().execute(
                .init(
                    sourceURL: sourceURL,
                    destinationURL: destinationURL,
                    sourceGraph: source,
                    identifiedPlan: plan,
                    blueprint: blueprint
                ),
                cancellation: cancellation,
                progress: { event in
                    if event.stage == .preparingReaderWriter,
                       event.trackID == nil {
                        cancellation.cancel()
                    }
                }
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

    func testCancellationEnteringOutputMetadataScanRemainsCancelled()
        async throws {
        let directory = try TrackMigrationFixtureDirectoryV4()
        defer { directory.remove() }
        let sourceURL = directory.url("output-metadata-cancel-source.mov")
        let destinationURL = directory.url("output-metadata-cancel-output.mov")
        try await TrackMigrationFixtureFactoryV4.makeRichMovie(
            at: sourceURL,
            includeAudioGroup: false
        )
        let source = try await AVFoundationTrackGraphAdapterV4.probe(
            asset: AVURLAsset(url: sourceURL)
        )
        let plan = try MediaTrackGraphPlannerV4.makePlan(source: source)
        let blueprint = try AVFoundationTrackMigrationPlannerV4.makeBlueprint(
            source: source,
            plan: plan
        )
        let cancellation = AVFoundationTrackMigrationCancellationV4()

        await XCTAssertThrowsErrorAsyncV4(
            try await AVFoundationTrackMigrationExecutorV4().execute(
                .init(
                    sourceURL: sourceURL,
                    destinationURL: destinationURL,
                    sourceGraph: source,
                    identifiedPlan: plan,
                    blueprint: blueprint
                ),
                cancellation: cancellation,
                progress: { event in
                    if event.stage == .verifying {
                        cancellation.cancel()
                    }
                }
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

    func testCancellationDuringScaledEditPrescanIsAtomic() async throws {
        let directory = try TrackMigrationFixtureDirectoryV4()
        defer { directory.remove() }
        let mediaURL = directory.url("prescan-media.mov")
        let sourceURL = directory.url("prescan-scaled.mov")
        let destinationURL = directory.url("prescan-output.mov")
        try await TrackMigrationFixtureFactoryV4.makeRichMovie(
            at: mediaURL,
            includeAudioGroup: false
        )
        try await TrackMigrationFixtureFactoryV4.makeScaledEditedMovie(
            source: mediaURL,
            at: sourceURL
        )
        let source = try await AVFoundationTrackGraphAdapterV4.probe(
            asset: AVURLAsset(url: sourceURL)
        )
        let scaledTrack = try XCTUnwrap(source.tracks.first)
        let plan = try MediaTrackGraphPlannerV4.makePlan(source: source)
        let blueprint = try AVFoundationTrackMigrationPlannerV4.makeBlueprint(
            source: source,
            plan: plan
        )
        let cancellation = AVFoundationTrackMigrationCancellationV4()

        await XCTAssertThrowsErrorAsyncV4(
            try await AVFoundationTrackMigrationExecutorV4().execute(
                .init(
                    sourceURL: sourceURL,
                    destinationURL: destinationURL,
                    sourceGraph: source,
                    identifiedPlan: plan,
                    blueprint: blueprint
                ),
                cancellation: cancellation,
                progress: { event in
                    if event.stage == .preparingReaderWriter,
                       event.trackID == scaledTrack.identity.stableID,
                       event.migratedSampleCount > 0 {
                        cancellation.cancel()
                    }
                }
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

    func testNonVideoHookRejectsMiddleSampleTimingMutationWithSameEnvelope()
        async throws {
        let directory = try TrackMigrationFixtureDirectoryV4()
        defer { directory.remove() }
        let sourceURL = directory.url("audio-middle-timing-source.mov")
        let destinationURL = directory.url("audio-middle-timing-output.mov")
        try await TrackMigrationFixtureFactoryV4.makeRichMovie(
            at: sourceURL,
            includeAudioGroup: false
        )
        let asset = AVURLAsset(url: sourceURL)
        let source = try await AVFoundationTrackGraphAdapterV4.probe(
            asset: asset
        )
        let audio = try XCTUnwrap(source.tracks.first { $0.kind == .audio })
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let sourceTrack = try XCTUnwrap(audioTracks.first)
        let calibration = try await AVFoundationAACFormatCalibratorV4()
            .calibrate(
                asset: asset,
                track: sourceTrack,
                trackID: audio.identity.stableID
            )
        let basePlan = try MediaTrackGraphPlannerV4.makePlan(
            source: source,
            request: .init(trackDirectives: [MediaTrackDirectiveV4(
                trackID: audio.identity.stableID,
                action: .transcode,
                targetFormatDescriptors: [calibration.targetFormat],
                dropConsent: nil
            )])
        )
        let plan = try basePlan.applyingTranscodePrimingDurations([
            audio.identity.stableID: calibration.encoderPrimingDuration
        ])
        let blueprint = try AVFoundationTrackMigrationPlannerV4.makeBlueprint(
            source: source,
            plan: plan
        )
        let hook = AVFoundationNonVideoTrackTranscodeHookV4(
            trackID: audio.identity.stableID,
            readerOutputSettings: calibration.hook.readerOutputSettings,
            writerOutputSettings: calibration.hook.writerOutputSettings,
            declaredOutputFormats: calibration.hook.declaredOutputFormats
        ) { wrapped in
            let sourceBuffer = wrapped.sampleBuffer
            let sampleCount = CMSampleBufferGetNumSamples(sourceBuffer)
            guard sampleCount > 2 else {
                throw TrackMigrationFixtureErrorV4.invalidFixture(
                    "Decoded audio buffer did not contain multiple samples."
                )
            }
            var timings = try (0..<sampleCount).map { index in
                var timing = CMSampleTimingInfo.invalid
                let status = CMSampleBufferGetSampleTimingInfo(
                    sourceBuffer,
                    at: index,
                    timingInfoOut: &timing
                )
                guard status == noErr else {
                    throw TrackMigrationFixtureErrorV4.coreMedia(status)
                }
                return timing
            }
            let middle = sampleCount / 2
            timings[middle].presentationTimeStamp = CMTimeAdd(
                timings[middle].presentationTimeStamp,
                CMTime(value: 1, timescale: 96_000)
            )
            var copy: CMSampleBuffer?
            let status = CMSampleBufferCreateCopyWithNewTiming(
                allocator: kCFAllocatorDefault,
                sampleBuffer: sourceBuffer,
                sampleTimingEntryCount: timings.count,
                sampleTimingArray: &timings,
                sampleBufferOut: &copy
            )
            guard status == noErr, let copy else {
                throw TrackMigrationFixtureErrorV4.coreMedia(status)
            }
            XCTAssertEqual(
                CMSampleBufferGetPresentationTimeStamp(copy),
                CMSampleBufferGetPresentationTimeStamp(sourceBuffer)
            )
            XCTAssertEqual(
                CMSampleBufferGetDuration(copy),
                CMSampleBufferGetDuration(sourceBuffer)
            )
            return AVFoundationNonVideoSampleV4(sampleBuffer: copy)
        }

        await XCTAssertThrowsErrorAsyncV4(
            try await AVFoundationTrackMigrationExecutorV4().execute(.init(
                sourceURL: sourceURL,
                destinationURL: destinationURL,
                sourceGraph: source,
                identifiedPlan: plan,
                blueprint: blueprint,
                nonVideoTranscodeHooks: [hook]
            ))
        ) { error in
            XCTAssertEqual(
                error as? AVFoundationTrackMigrationExecutorV4Error,
                .processedSampleChangedTiming(audio.identity.stableID)
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

    func testNontrivialEditListUsesDeterministicEncodedCompositionRoute()
        async throws {
        let directory = try TrackMigrationFixtureDirectoryV4()
        defer { directory.remove() }
        let mediaURL = directory.url("edit-media.mov")
        let sourceURL = directory.url("edit-source.mov")
        let destinationURL = directory.url("edit-output.mov")
        try await TrackMigrationFixtureFactoryV4.makeRichMovie(
            at: mediaURL,
            includeAudioGroup: false
        )
        try await TrackMigrationFixtureFactoryV4.makeEditedMovie(
            source: mediaURL,
            at: sourceURL
        )
        let source = try await AVFoundationTrackGraphAdapterV4.probe(
            asset: AVURLAsset(url: sourceURL)
        )
        let editedTrack = try XCTUnwrap(source.tracks.first)
        XCTAssertGreaterThan(editedTrack.edits.count, 1)
        XCTAssertTrue(editedTrack.edits.contains(where: \.isEmpty))
        let plan = try MediaTrackGraphPlannerV4.makePlan(source: source)
        let blueprint = try AVFoundationTrackMigrationPlannerV4.makeBlueprint(
            source: source,
            plan: plan
        )
        XCTAssertEqual(blueprint.tracks.first?.outcome, .requiresComposition)

        let result = try await AVFoundationTrackMigrationExecutorV4().execute(
            .init(
                sourceURL: sourceURL,
                destinationURL: destinationURL,
                sourceGraph: source,
                identifiedPlan: plan,
                blueprint: blueprint
            )
        )

        XCTAssertTrue(result.verificationReport.isConformant)
        XCTAssertEqual(result.outputGraph, source)
        XCTAssertEqual(
            result.trackResults.first?.sourceSampleStreamSHA256,
            result.trackResults.first?.outputSampleStreamSHA256
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destinationURL.path
        ))
        XCTAssertFalse(try directory.containsPartialMovie())
    }

    func testScaledEditRoundTripsExactRationalMappingAndEncodedStream()
        async throws {
        let directory = try TrackMigrationFixtureDirectoryV4()
        defer { directory.remove() }
        let mediaURL = directory.url("scaled-edit-media.mov")
        let sourceURL = directory.url("scaled-edit-source.mov")
        let destinationURL = directory.url("scaled-edit-output.mov")
        try await TrackMigrationFixtureFactoryV4.makeRichMovie(
            at: mediaURL,
            includeAudioGroup: false
        )
        try await TrackMigrationFixtureFactoryV4.makeScaledEditedMovie(
            source: mediaURL,
            at: sourceURL
        )
        let source = try await AVFoundationTrackGraphAdapterV4.probe(
            asset: AVURLAsset(url: sourceURL)
        )
        let scaledTrack = try XCTUnwrap(source.tracks.first)
        XCTAssertTrue(scaledTrack.edits.contains { edit in
            edit.source?.duration != edit.target.duration
        })
        let plan = try MediaTrackGraphPlannerV4.makePlan(source: source)
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
                blueprint: blueprint
            )
        )

        XCTAssertTrue(result.verificationReport.isConformant)
        XCTAssertEqual(result.outputGraph, source)
        XCTAssertEqual(
            result.trackResults.first?.sourceSampleStreamSHA256,
            result.trackResults.first?.outputSampleStreamSHA256
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destinationURL.path
        ))
        XCTAssertFalse(try directory.containsPartialMovie())
    }

    func testScaledDiscontiguousEmptyEditsCoexistWithAudioTranscoding()
        async throws {
        let directory = try TrackMigrationFixtureDirectoryV4()
        defer { directory.remove() }
        let mediaURL = directory.url("combined-edit-media.mov")
        let sourceURL = directory.url("combined-edit-source.mov")
        let destinationURL = directory.url("combined-edit-output.mov")
        try await TrackMigrationFixtureFactoryV4
            .makeRichMovieWithIncompatibleAudioTransitions(
                at: mediaURL,
                includeAudioGroup: false
            )
        try await TrackMigrationFixtureFactoryV4
            .makeScaledDiscontiguousEditedMovie(
                source: mediaURL,
                at: sourceURL
            )
        let asset = AVURLAsset(url: sourceURL)
        let source = try await AVFoundationTrackGraphAdapterV4.probe(
            asset: asset
        )
        let editedVideo = try XCTUnwrap(source.tracks.first {
            $0.kind == .video
        })
        XCTAssertTrue(editedVideo.edits.contains(where: \.isEmpty))
        XCTAssertGreaterThan(
            editedVideo.edits.filter { !$0.isEmpty }.count,
            1
        )
        XCTAssertTrue(editedVideo.edits.contains { edit in
            edit.source?.duration != edit.target.duration
        })

        let assetTracks = try await asset.load(.tracks)
        let calibrator = AVFoundationAACFormatCalibratorV4()
        var directives: [MediaTrackDirectiveV4] = []
        var hooks: [AVFoundationNonVideoTrackTranscodeHookV4] = []
        var primingDurations: [
            MediaTrackStableIDV4: ExactRationalV4
        ] = [:]
        for audio in source.tracks.filter({ $0.kind == .audio }) {
            let sourceTrack = assetTracks[Int(audio.identity.ordinal)]
            let calibration = try await calibrator.calibrate(
                asset: asset,
                track: sourceTrack,
                trackID: audio.identity.stableID
            )
            directives.append(MediaTrackDirectiveV4(
                trackID: audio.identity.stableID,
                action: .transcode,
                targetFormatDescriptors: [calibration.targetFormat],
                dropConsent: nil
            ))
            hooks.append(calibration.hook)
            primingDurations[audio.identity.stableID] = calibration
                .encoderPrimingDuration
        }
        let basePlan = try MediaTrackGraphPlannerV4.makePlan(
            source: source,
            request: .init(trackDirectives: directives)
        )
        let plan = try basePlan.applyingTranscodePrimingDurations(
            primingDurations
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
                nonVideoTranscodeHooks: hooks
            )
        )

        XCTAssertTrue(result.verificationReport.isConformant)
        XCTAssertTrue(result.trackResults.filter {
            $0.action == .passThrough
        }.allSatisfy {
            $0.sourceSampleStreamSHA256 == $0.outputSampleStreamSHA256
        })
        XCTAssertEqual(
            result.trackResults.filter { $0.action == .transcode }.count,
            2
        )
        XCTAssertFalse(try directory.containsPartialMovie())
    }

    func testDiscontiguousAudioEditsSurviveAACTranscodeRoundTrip()
        async throws {
        let directory = try TrackMigrationFixtureDirectoryV4()
        defer { directory.remove() }
        let mediaURL = directory.url("audio-edit-media.mov")
        let sourceURL = directory.url("audio-edit-source.mov")
        let destinationURL = directory.url("audio-edit-output.mov")
        try await TrackMigrationFixtureFactoryV4
            .makeRichMovieWithIncompatibleAudioTransitions(
                at: mediaURL,
                includeAudioGroup: false
            )
        try await TrackMigrationFixtureFactoryV4
            .makeDiscontiguousAudioEditedMovie(
                source: mediaURL,
                at: sourceURL
            )
        let asset = AVURLAsset(url: sourceURL)
        let source = try await AVFoundationTrackGraphAdapterV4.probe(
            asset: asset
        )
        let sourceAudio = source.tracks.filter { $0.kind == .audio }
        XCTAssertEqual(sourceAudio.count, 2)
        for audio in sourceAudio {
            XCTAssertEqual(audio.edits.filter(\.isEmpty).count, 2)
            let mediaEdits = audio.edits.filter { !$0.isEmpty }
            XCTAssertEqual(mediaEdits.count, 2)
            let firstSource = try XCTUnwrap(mediaEdits[0].source)
            let secondSource = try XCTUnwrap(mediaEdits[1].source)
            XCTAssertGreaterThan(
                secondSource.start,
                try firstSource.start.adding(firstSource.duration)
            )
        }

        let assetTracks = try await asset.load(.tracks)
        let calibrator = AVFoundationAACFormatCalibratorV4()
        var directives: [MediaTrackDirectiveV4] = []
        var hooks: [AVFoundationNonVideoTrackTranscodeHookV4] = []
        var primingDurations: [
            MediaTrackStableIDV4: ExactRationalV4
        ] = [:]
        for audio in sourceAudio {
            let sourceTrack = assetTracks[Int(audio.identity.ordinal)]
            let calibration = try await calibrator.calibrate(
                asset: asset,
                track: sourceTrack,
                trackID: audio.identity.stableID
            )
            directives.append(MediaTrackDirectiveV4(
                trackID: audio.identity.stableID,
                action: .transcode,
                targetFormatDescriptors: [calibration.targetFormat],
                dropConsent: nil
            ))
            hooks.append(calibration.hook)
            primingDurations[audio.identity.stableID] = calibration
                .encoderPrimingDuration
        }
        let basePlan = try MediaTrackGraphPlannerV4.makePlan(
            source: source,
            request: .init(trackDirectives: directives)
        )
        let plan = try basePlan.applyingTranscodePrimingDurations(
            primingDurations
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
                nonVideoTranscodeHooks: hooks
            )
        )

        XCTAssertTrue(result.verificationReport.isConformant)
        XCTAssertTrue(result.trackResults.filter {
            $0.action == .passThrough
        }.allSatisfy {
            $0.sourceSampleStreamSHA256 == $0.outputSampleStreamSHA256
        })
        XCTAssertEqual(
            result.trackResults.filter { $0.action == .transcode }.count,
            2
        )
        for sourceTrack in sourceAudio {
            let expected = try XCTUnwrap(plan.plan.tracks.first {
                $0.source.identity.stableID == sourceTrack.identity.stableID
            }?.expectedOutput)
            let output = try XCTUnwrap(result.outputGraph.tracks.first {
                $0.identity.stableID == sourceTrack.identity.stableID
            })
            XCTAssertEqual(output.edits, expected.edits)
            XCTAssertEqual(output.formatDescriptors.count, 1)
            XCTAssertEqual(
                output.formatDescriptors[0].mediaSubtypeID,
                "fourcc_61616320"
            )
        }
        XCTAssertFalse(try directory.containsPartialMovie())
    }

    func testSubtitleAndClosedCaptionTracksRoundTripEncodedStreams()
        async throws {
        let directory = try TrackMigrationFixtureDirectoryV4()
        defer { directory.remove() }
        let sourceURL = directory.url("legible-source.mov")
        let destinationURL = directory.url("legible-output.mov")
        try await TrackMigrationFixtureFactoryV4.makeLegibleMovie(at: sourceURL)
        let source = try await AVFoundationTrackGraphAdapterV4.probe(
            asset: AVURLAsset(url: sourceURL)
        )
        XCTAssertEqual(source.tracks.map(\.kind), [.subtitle, .caption])
        let plan = try MediaTrackGraphPlannerV4.makePlan(source: source)
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
                blueprint: blueprint
            )
        )

        XCTAssertTrue(result.verificationReport.isConformant)
        XCTAssertEqual(result.outputGraph, source)
        XCTAssertEqual(result.trackResults.count, 2)
        XCTAssertTrue(result.trackResults.allSatisfy {
            $0.migratedSampleCount > 0
                && $0.sourceSampleStreamSHA256
                    == $0.outputSampleStreamSHA256
        })
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destinationURL.path
        ))
        XCTAssertFalse(try directory.containsPartialMovie())
    }

    func testAuxiliaryPictureTrackRoundTripsEncodedStreamWithoutSilentDrop()
        async throws {
        let directory = try TrackMigrationFixtureDirectoryV4()
        defer { directory.remove() }
        let sourceURL = directory.url("aux-source.mov")
        let destinationURL = directory.url("aux-output.mov")
        try await TrackMigrationFixtureFactoryV4.makeAuxiliaryPictureMovie(
            at: sourceURL
        )
        let source = try await AVFoundationTrackGraphAdapterV4.probe(
            asset: AVURLAsset(url: sourceURL)
        )
        XCTAssertEqual(source.tracks.count, 1)
        XCTAssertEqual(source.tracks.first?.kind, .auxiliary)
        XCTAssertEqual(
            source.tracks.first?.sourceMediaTypeID,
            "auxv"
        )
        let plan = try MediaTrackGraphPlannerV4.makePlan(source: source)
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
                blueprint: blueprint
            )
        )

        XCTAssertTrue(result.verificationReport.isConformant)
        XCTAssertEqual(result.outputGraph, source)
        let trackResult = try XCTUnwrap(result.trackResults.first)
        XCTAssertGreaterThan(trackResult.migratedSampleCount, 0)
        XCTAssertEqual(
            trackResult.sourceSampleStreamSHA256,
            trackResult.outputSampleStreamSHA256
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destinationURL.path
        ))
        XCTAssertFalse(try directory.containsPartialMovie())
    }

    func testSampleStreamAccumulatorIncrementalDigestMatchesReferenceBytes()
        throws {
        let duration = CMTime(value: 1, timescale: 30)
        let first = try sampleStreamQualificationBuffer(
            payloads: [
                Data([0x00, 0x00, 0x00, 0x01]),
                Data([0x10, 0x20, 0x30, 0x40])
            ],
            start: .zero,
            duration: duration
        )
        let second = try sampleStreamQualificationBuffer(
            payloads: [
                Data([0xaa, 0xbb, 0xcc, 0xdd]),
                Data([0x7f, 0x00, 0x80, 0xff]),
                Data([0xde, 0xad, 0xbe, 0xef])
            ],
            start: CMTime(value: 2, timescale: 30),
            duration: duration
        )

        var accumulator = SampleStreamAccumulatorV4()
        try accumulator.append(first)
        let firstDigest = accumulator.digest
        XCTAssertEqual(accumulator.digest, firstDigest)

        try accumulator.append(second)
        let referenceBytes = try referenceSampleStreamCanonicalBytes([
            first,
            second
        ])
        var domainSeparated = Data(
            "ash-avfoundation-sample-stream-v4".utf8
        )
        domainSeparated.append(0)
        domainSeparated.append(referenceBytes)
        let expectedDigest = ASHSHA256V4(rawData: domainSeparated)

        XCTAssertNotEqual(accumulator.digest, firstDigest)
        XCTAssertEqual(accumulator.digest, expectedDigest)
        XCTAssertEqual(accumulator.digest, expectedDigest)
        XCTAssertEqual(
            accumulator.retentionDiagnosticForQualification
                .processedCanonicalByteCount,
            UInt64(referenceBytes.count)
        )
    }

    func testSampleStreamAccumulatorRetainsOnlyFixedHashState() throws {
        let buffer = try sampleStreamQualificationBuffer(
            payloads: [
                Data([0x00, 0x00, 0x00, 0x01]),
                Data([0x00, 0x00, 0x00, 0x02]),
                Data([0x00, 0x00, 0x00, 0x03]),
                Data([0x00, 0x00, 0x00, 0x04])
            ],
            start: .zero,
            duration: CMTime(value: 1, timescale: 30)
        )
        let bytesPerBuffer = try referenceSampleStreamCanonicalBytes([
            buffer
        ]).count
        var accumulator = SampleStreamAccumulatorV4()
        let initial = accumulator.retentionDiagnosticForQualification

        let appendCount = 2_048
        for _ in 0..<appendCount {
            try accumulator.append(buffer)
        }

        let diagnostic = accumulator.retentionDiagnosticForQualification
        XCTAssertEqual(
            diagnostic.processedCanonicalByteCount,
            UInt64(bytesPerBuffer * appendCount)
        )
        XCTAssertGreaterThan(diagnostic.processedCanonicalByteCount, 1_000_000)
        XCTAssertEqual(diagnostic.retainedCanonicalByteCount, 0)
        XCTAssertEqual(
            diagnostic.fixedStateByteCount,
            initial.fixedStateByteCount
        )
        XCTAssertGreaterThan(diagnostic.fixedStateByteCount, 0)
        XCTAssertLessThan(diagnostic.fixedStateByteCount, 4_096)
        XCTAssertEqual(accumulator.digest, accumulator.digest)
    }

    func testDynamicHDRMultisetIsOrderIndependentAndBindsDuplicates()
        throws {
        let a = Data("frame-a".utf8)
        let b = Data("frame-b".utf8)
        let c = Data("frame-c".utf8)
        var source = DynamicHDRMetadataStreamAccumulatorV4()
        var permuted = DynamicHDRMetadataStreamAccumulatorV4()
        var changedDuplicate = DynamicHDRMetadataStreamAccumulatorV4()
        var droppedDuplicate = DynamicHDRMetadataStreamAccumulatorV4()

        for record in [a, a, b, c] {
            try source.appendCanonicalRecordForQualification(record)
        }
        for record in [c, a, b, a] {
            try permuted.appendCanonicalRecordForQualification(record)
        }
        for record in [a, b, b, c] {
            try changedDuplicate.appendCanonicalRecordForQualification(record)
        }
        for record in [a, b, c] {
            try droppedDuplicate.appendCanonicalRecordForQualification(record)
        }

        XCTAssertEqual(source, permuted)
        XCTAssertEqual(source.digest, permuted.digest)
        XCTAssertNotEqual(source, changedDuplicate)
        XCTAssertNotEqual(source.digest, changedDuplicate.digest)
        XCTAssertNotEqual(source, droppedDuplicate)
        XCTAssertNotEqual(source.digest, droppedDuplicate.digest)
    }

    func testDynamicHDRMultisetRetainsFixedStateBeyondOneMillionRecords()
        throws {
        let record = Data("repeated-frame-metadata".utf8)
        var direct = DynamicHDRMetadataStreamAccumulatorV4()
        for _ in 0..<3 {
            try direct.appendCanonicalRecordForQualification(record)
        }
        var repeated = DynamicHDRMetadataStreamAccumulatorV4()
        try repeated.appendRepeatedCanonicalRecordForQualification(
            record,
            count: 3
        )
        XCTAssertEqual(direct, repeated)

        var accumulator = DynamicHDRMetadataStreamAccumulatorV4()
        let initial = accumulator.retentionDiagnosticForQualification
        try accumulator.appendRepeatedCanonicalRecordForQualification(
            record,
            count: 1_000_001
        )

        let diagnostic = accumulator.retentionDiagnosticForQualification
        XCTAssertEqual(diagnostic.processedRecordCount, 1_000_001)
        XCTAssertEqual(diagnostic.retainedRecordByteCount, 0)
        XCTAssertEqual(
            diagnostic.fixedStateByteCount,
            initial.fixedStateByteCount
        )
        XCTAssertGreaterThan(diagnostic.fixedStateByteCount, 0)
        XCTAssertLessThan(diagnostic.fixedStateByteCount, 4_096)
        XCTAssertFalse(accumulator.digest.isEmpty)
    }
}

private extension AVFoundationTrackMigrationExecutorV4Tests {
    struct AudioTranscodeContextV4 {
        let source: MediaTrackGraphV4
        let audio: MediaTrackNodeV4
        let plan: MediaTrackGraphIdentifiedPlanV4
        let blueprint: AVFoundationTrackMigrationBlueprintV4
        let calibration: AVFoundationAACCalibrationV4
    }

    func audioTranscodeContext(
        sourceURL: URL
    ) async throws -> AudioTranscodeContextV4 {
        try await TrackMigrationFixtureFactoryV4.makeRichMovie(
            at: sourceURL,
            includeAudioGroup: false
        )
        let asset = AVURLAsset(url: sourceURL)
        let source = try await AVFoundationTrackGraphAdapterV4.probe(
            asset: asset
        )
        let audio = try XCTUnwrap(source.tracks.first { $0.kind == .audio })
        let sourceTracks = try await asset.loadTracks(withMediaType: .audio)
        let sourceTrack = try XCTUnwrap(sourceTracks.first)
        let calibration = try await AVFoundationAACFormatCalibratorV4()
            .calibrate(
                asset: asset,
                track: sourceTrack,
                trackID: audio.identity.stableID
            )
        let basePlan = try MediaTrackGraphPlannerV4.makePlan(
            source: source,
            request: .init(trackDirectives: [MediaTrackDirectiveV4(
                trackID: audio.identity.stableID,
                action: .transcode,
                targetFormatDescriptors: [calibration.targetFormat],
                dropConsent: nil
            )])
        )
        let plan = try basePlan.applyingTranscodePrimingDurations([
            audio.identity.stableID: calibration.encoderPrimingDuration
        ])
        return AudioTranscodeContextV4(
            source: source,
            audio: audio,
            plan: plan,
            blueprint: try AVFoundationTrackMigrationPlannerV4.makeBlueprint(
                source: source,
                plan: plan
            ),
            calibration: calibration
        )
    }

    func firstEncodedVideoSample(
        in url: URL
    ) async throws -> CMSampleBuffer {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: nil
        )
        guard reader.canAdd(output) else {
            throw TrackMigrationFixtureErrorV4.invalidFixture(
                "Cannot read dynamic HDR fixture."
            )
        }
        reader.add(output)
        guard reader.startReading() else {
            throw TrackMigrationFixtureErrorV4.invalidFixture(
                reader.error?.localizedDescription
                    ?? "Dynamic HDR reader did not start."
            )
        }
        var firstSample: CMSampleBuffer?
        while let sample = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetImageBuffer(sample) != nil
                    || CMSampleBufferGetTotalSampleSize(sample) > 0 else {
                continue
            }
            if firstSample == nil { firstSample = sample }
        }
        guard reader.status == .completed else {
            throw TrackMigrationFixtureErrorV4.invalidFixture(
                reader.error?.localizedDescription
                    ?? "Dynamic HDR reader did not finish."
            )
        }
        return try XCTUnwrap(firstSample)
    }

    func frameBoundHDRMetadata(seed: UInt8) throws -> HDRDynamicMetadataV4 {
        HDRDynamicMetadataV4(
            hdr10Plus: try HDR10PlusMetadataV4(
                ituTT35Payload: Data([
                    0xB5, 0x00, 0x3C, 0x00, 0x01, 0x04, 0x01,
                    seed, seed &+ 1
                ])
            ),
            postDecodeProcessing: try PostDecodeProcessingMetadataV4(
                propertyList: ["seed": NSNumber(value: seed)] as NSDictionary
            )
        )
    }

    func channelLayoutTag(in data: Data) -> AudioChannelLayoutTag {
        data.withUnsafeBytes {
            $0.loadUnaligned(as: AudioChannelLayoutTag.self)
        }
    }

    func sampleStreamQualificationBuffer(
        payloads: [Data],
        start: CMTime,
        duration: CMTime
    ) throws -> CMSampleBuffer {
        guard !payloads.isEmpty,
              payloads.allSatisfy({ $0.count == MemoryLayout<Int32>.size })
        else {
            throw TrackMigrationFixtureErrorV4.invalidFixture(
                "Qualification timecode samples must be four bytes."
            )
        }
        var format: CMTimeCodeFormatDescription?
        var status = CMTimeCodeFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            timeCodeFormatType: kCMTimeCodeFormatType_TimeCode32,
            frameDuration: duration,
            frameQuanta: 30,
            flags: 0,
            extensions: nil,
            formatDescriptionOut: &format
        )
        guard status == noErr, let format else {
            throw TrackMigrationFixtureErrorV4.coreMedia(status)
        }

        let payload = payloads.reduce(into: Data()) { bytes, sample in
            bytes.append(sample)
        }
        var blockBuffer: CMBlockBuffer?
        status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: payload.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: payload.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let blockBuffer else {
            throw TrackMigrationFixtureErrorV4.coreMedia(status)
        }
        status = payload.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: payload.count
            )
        }
        guard status == kCMBlockBufferNoErr else {
            throw TrackMigrationFixtureErrorV4.coreMedia(status)
        }

        let timings = payloads.indices.map { index in
            CMSampleTimingInfo(
                duration: duration,
                presentationTimeStamp: CMTimeAdd(
                    start,
                    CMTimeMultiply(duration, multiplier: Int32(index))
                ),
                decodeTimeStamp: .invalid
            )
        }
        let sampleSizes = payloads.map(\.count)
        var sampleBuffer: CMSampleBuffer?
        status = timings.withUnsafeBufferPointer { timingBuffer in
            sampleSizes.withUnsafeBufferPointer { sizeBuffer in
                CMSampleBufferCreate(
                    allocator: kCFAllocatorDefault,
                    dataBuffer: blockBuffer,
                    dataReady: true,
                    makeDataReadyCallback: nil,
                    refcon: nil,
                    formatDescription: format,
                    sampleCount: payloads.count,
                    sampleTimingEntryCount: timings.count,
                    sampleTimingArray: timingBuffer.baseAddress,
                    sampleSizeEntryCount: sampleSizes.count,
                    sampleSizeArray: sizeBuffer.baseAddress,
                    sampleBufferOut: &sampleBuffer
                )
            }
        }
        guard status == noErr, let sampleBuffer else {
            throw TrackMigrationFixtureErrorV4.coreMedia(status)
        }
        return sampleBuffer
    }

    func referenceSampleStreamCanonicalBytes(
        _ buffers: [CMSampleBuffer]
    ) throws -> Data {
        var canonicalBytes = Data()
        for sample in buffers {
            let sampleCount = CMSampleBufferGetNumSamples(sample)
            if sampleCount == 0 {
                continue
            }
            guard let format = CMSampleBufferGetFormatDescription(sample)
            else {
                throw TrackMigrationFixtureErrorV4.invalidFixture(
                    "Qualification sample has no format description."
                )
            }
            let formatFingerprint = try AVFoundationTrackGraphAdapterV4
                .canonicalFormatDescriptor(format).canonicalFingerprint
            let mediaType = CMFormatDescriptionGetMediaType(format)
            let mediaSubtype = CMFormatDescriptionGetMediaSubType(format)
            let dataBuffer = CMSampleBufferGetDataBuffer(sample)
            var dataOffset = 0

            for index in 0..<sampleCount {
                var timing = CMSampleTimingInfo()
                let timingStatus = CMSampleBufferGetSampleTimingInfo(
                    sample,
                    at: index,
                    timingInfoOut: &timing
                )
                guard timingStatus == noErr else {
                    throw TrackMigrationFixtureErrorV4.coreMedia(timingStatus)
                }
                let sampleSize = CMSampleBufferGetSampleSize(sample, at: index)
                let payload: Data
                if sampleSize == 0 {
                    payload = Data()
                } else {
                    guard let dataBuffer else {
                        throw TrackMigrationFixtureErrorV4.invalidFixture(
                            "Qualification sample has no data buffer."
                        )
                    }
                    var bytes = Data(count: sampleSize)
                    let copyStatus = bytes.withUnsafeMutableBytes { destination in
                        CMBlockBufferCopyDataBytes(
                            dataBuffer,
                            atOffset: dataOffset,
                            dataLength: sampleSize,
                            destination: destination.baseAddress!
                        )
                    }
                    guard copyStatus == kCMBlockBufferNoErr else {
                        throw TrackMigrationFixtureErrorV4.coreMedia(copyStatus)
                    }
                    payload = bytes
                }

                canonicalBytes.append(1)
                appendReferenceTime(
                    timing.presentationTimeStamp,
                    to: &canonicalBytes
                )
                appendReferenceTime(
                    timing.decodeTimeStamp,
                    to: &canonicalBytes
                )
                appendReferenceTime(timing.duration, to: &canonicalBytes)
                appendReferenceInteger(mediaType, to: &canonicalBytes)
                appendReferenceInteger(mediaSubtype, to: &canonicalBytes)
                canonicalBytes.append(
                    contentsOf: formatFingerprint.rawValue.utf8
                )
                appendReferenceInteger(UInt64(sampleSize), to: &canonicalBytes)
                canonicalBytes.append(contentsOf: ASHSHA256V4(
                    rawData: payload
                ).rawValue.utf8)
                dataOffset += sampleSize
            }
        }
        return canonicalBytes
    }

    func appendReferenceTime(_ time: CMTime, to bytes: inout Data) {
        appendReferenceInteger(time.value, to: &bytes)
        appendReferenceInteger(time.timescale, to: &bytes)
        appendReferenceInteger(time.flags.rawValue, to: &bytes)
        appendReferenceInteger(time.epoch, to: &bytes)
    }

    func appendReferenceInteger<T: FixedWidthInteger>(
        _ value: T,
        to bytes: inout Data
    ) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) {
            bytes.append(contentsOf: $0)
        }
    }

    func passThroughTrack(
        _ track: MediaTrackNodeV4,
        formats: [MediaTrackFormatDescriptorV4]
    ) throws -> MediaTrackPlannedTrackV4 {
        let node = try MediaTrackNodeV4(
            identity: track.identity,
            enabled: track.enabled,
            kind: track.kind,
            sourceMediaTypeID: track.sourceMediaTypeID,
            language: track.language,
            roleIDs: track.roleIDs,
            timebase: track.timebase,
            timeRange: track.timeRange,
            edits: track.edits,
            formatDescriptors: formats,
            metadataFingerprint: track.metadataFingerprint
        )
        return MediaTrackPlannedTrackV4(
            source: node,
            action: .passThrough,
            origin: .defaultPreservation,
            expectedOutput: node,
            dropConsent: nil
        )
    }

    func audioFormatDescription(
        sampleRate: Double,
        channels: UInt32
    ) throws -> CMAudioFormatDescription {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger
                | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2 * channels,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2 * channels,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var result: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &result
        )
        guard status == noErr, let result else {
            throw TrackMigrationFixtureErrorV4.coreMedia(status)
        }
        return result
    }

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

    func trackReplacingEnabled(
        _ track: MediaTrackNodeV4,
        enabled: Bool
    ) throws -> MediaTrackNodeV4 {
        try MediaTrackNodeV4(
            identity: track.identity,
            enabled: enabled,
            kind: track.kind,
            sourceMediaTypeID: track.sourceMediaTypeID,
            language: track.language,
            roleIDs: track.roleIDs,
            timebase: track.timebase,
            timeRange: track.timeRange,
            edits: track.edits,
            formatDescriptors: track.formatDescriptors,
            metadataFingerprint: track.metadataFingerprint
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

    static func makeEditedMovie(source sourceURL: URL, at outputURL: URL)
        async throws {
        let sourceAsset = AVURLAsset(
            url: sourceURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let sourceTracks = try await sourceAsset.loadTracks(
            withMediaType: .video
        )
        guard let sourceTrack = sourceTracks.first else {
            throw TrackMigrationFixtureErrorV4.invalidFixture(
                "Edit-list source has no video track."
            )
        }
        let composition = AVMutableComposition()
        guard let target = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw TrackMigrationFixtureErrorV4.invalidFixture(
                "Could not create the edit-list composition track."
            )
        }
        target.preferredTransform = try await sourceTrack.load(
            .preferredTransform
        )
        target.naturalTimeScale = try await sourceTrack.load(
            .naturalTimeScale
        )

        let frame = CMTime(value: 1, timescale: frameRate)
        target.insertEmptyTimeRange(CMTimeRange(
            start: .zero,
            duration: frame
        ))
        try target.insertTimeRange(
            CMTimeRange(
                start: .zero,
                duration: CMTimeMultiply(frame, multiplier: 3)
            ),
            of: sourceTrack,
            at: frame
        )
        let secondEmptyStart = CMTimeMultiply(frame, multiplier: 4)
        target.insertEmptyTimeRange(CMTimeRange(
            start: secondEmptyStart,
            duration: frame
        ))
        try target.insertTimeRange(
            CMTimeRange(
                start: CMTimeMultiply(frame, multiplier: 3),
                duration: CMTimeMultiply(frame, multiplier: 3)
            ),
            of: sourceTrack,
            at: CMTimeMultiply(frame, multiplier: 5)
        )

        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            throw TrackMigrationFixtureErrorV4.invalidFixture(
                "Could not create the edit-list exporter."
            )
        }
        exporter.metadata = assetMetadata()
        try await exporter.export(to: outputURL, as: .mov)
    }

    static func makeScaledEditedMovie(
        source sourceURL: URL,
        at outputURL: URL
    ) async throws {
        try FileManager.default.copyItem(at: sourceURL, to: outputURL)
        let movie = AVMutableMovie(
            url: outputURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        guard let target = movie.tracks(withMediaType: .video).first else {
            throw TrackMigrationFixtureErrorV4.invalidFixture(
                "Scaled-edit source has no video track."
            )
        }
        let sourceRange = try await target.load(.timeRange)
        target.scaleTimeRange(
            sourceRange,
            toDuration: CMTimeMultiplyByRatio(
                sourceRange.duration,
                multiplier: 2,
                divisor: 1
            )
        )
        try movie.writeHeader(
            to: outputURL,
            fileType: .mov,
            options: .addMovieHeaderToDestination
        )
    }

    static func makeScaledDiscontiguousEditedMovie(
        source sourceURL: URL,
        at outputURL: URL
    ) async throws {
        try FileManager.default.copyItem(at: sourceURL, to: outputURL)
        let movie = AVMutableMovie(
            url: outputURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        guard let target = movie.tracks(withMediaType: .video).first else {
            throw TrackMigrationFixtureErrorV4.invalidFixture(
                "Combined-edit source has no video track."
            )
        }
        let original = try await target.load(.timeRange)
        let frame = CMTime(value: 1, timescale: frameRate)
        target.insertEmptyTimeRange(CMTimeRange(
            start: original.start,
            duration: frame
        ))
        let shiftedMedia = CMTimeRange(
            start: CMTimeAdd(original.start, frame),
            duration: original.duration
        )
        target.scaleTimeRange(
            shiftedMedia,
            toDuration: CMTimeMultiplyByRatio(
                shiftedMedia.duration,
                multiplier: 2,
                divisor: 1
            )
        )
        target.removeTimeRange(CMTimeRange(
            start: CMTimeAdd(
                shiftedMedia.start,
                CMTimeMultiply(frame, multiplier: 2)
            ),
            duration: frame
        ))
        try movie.writeHeader(
            to: outputURL,
            fileType: .mov,
            options: .addMovieHeaderToDestination
        )
    }

    static func makeDiscontiguousAudioEditedMovie(
        source sourceURL: URL,
        at outputURL: URL
    ) async throws {
        try FileManager.default.copyItem(at: sourceURL, to: outputURL)
        let movie = AVMutableMovie(
            url: outputURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let audioTracks = movie.tracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else {
            throw TrackMigrationFixtureErrorV4.invalidFixture(
                "Audio-edit source has no audio tracks."
            )
        }
        let emptyDuration = CMTime(value: 1, timescale: 20)
        let mediaDuration = CMTime(value: 1, timescale: 10)
        let firstSource = CMTimeRange(
            start: .zero,
            duration: mediaDuration
        )
        let secondSource = CMTimeRange(
            start: CMTime(value: 3, timescale: 10),
            duration: mediaDuration
        )
        let firstTarget = CMTimeRange(
            start: emptyDuration,
            duration: mediaDuration
        )
        let middleEmpty = CMTimeRange(
            start: CMTime(value: 3, timescale: 20),
            duration: emptyDuration
        )
        let secondTarget = CMTimeRange(
            start: CMTime(value: 1, timescale: 5),
            duration: mediaDuration
        )
        for track in audioTracks {
            let mediaRange = track.mediaPresentationTimeRange
            guard CMTimeRangeContainsTimeRange(
                mediaRange,
                otherRange: firstSource
            ), CMTimeRangeContainsTimeRange(
                mediaRange,
                otherRange: secondSource
            ) else {
                throw TrackMigrationFixtureErrorV4.invalidFixture(
                    "Audio-edit source media is too short."
                )
            }
            track.removeTimeRange(track.timeRange)
            track.insertEmptyTimeRange(CMTimeRange(
                start: .zero,
                duration: emptyDuration
            ))
            guard track.insertMediaTimeRange(firstSource, into: firstTarget)
            else {
                throw TrackMigrationFixtureErrorV4.invalidFixture(
                    "Could not insert the first audio media edit."
                )
            }
            track.insertEmptyTimeRange(middleEmpty)
            guard track.insertMediaTimeRange(secondSource, into: secondTarget)
            else {
                throw TrackMigrationFixtureErrorV4.invalidFixture(
                    "Could not insert the second audio media edit."
                )
            }
        }
        try movie.writeHeader(
            to: outputURL,
            fileType: .mov,
            options: .addMovieHeaderToDestination
        )
    }

    static func makeAuxiliaryPictureMovie(at url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.metadata = assetMetadata()
        let lane = makeVideoLane(
            seed: 211,
            title: "auxiliary-picture",
            mediaType: .auxiliaryPicture
        )
        lane.input.mediaTimeScale = frameRate
        guard writer.availableMediaTypes.contains(.auxiliaryPicture),
              writer.canAdd(lane.input) else {
            throw TrackMigrationFixtureErrorV4.writer(
                "Writer rejected an auxiliary-picture track."
            )
        }
        writer.add(lane.input)
        guard writer.startWriting() else {
            throw TrackMigrationFixtureErrorV4.writer(
                writer.error?.localizedDescription
                    ?? "Auxiliary writer did not start."
            )
        }
        writer.startSession(atSourceTime: .zero)
        for frameIndex in 0..<frameCount {
            try await appendFrame(
                lane: lane,
                frameIndex: frameIndex,
                time: CMTime(
                    value: CMTimeValue(frameIndex),
                    timescale: frameRate
                ),
                writer: writer
            )
        }
        lane.input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(
            value: CMTimeValue(frameCount),
            timescale: frameRate
        ))
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else {
            throw TrackMigrationFixtureErrorV4.writer(
                writer.error?.localizedDescription
                    ?? "Auxiliary writer did not finish."
            )
        }
    }

    static func makeLegibleMovie(at url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.metadata = assetMetadata()
        let subtitleFormat = try makeFormatDescription(
            mediaType: kCMMediaType_Subtitle,
            mediaSubtype: kCMTextFormatType_3GText,
            extensions: subtitleFormatExtensions
        )
        let captionFormat = try makeFormatDescription(
            mediaType: kCMMediaType_ClosedCaption,
            mediaSubtype: kCMClosedCaptionFormatType_CEA608
        )
        let subtitleInput = AVAssetWriterInput(
            mediaType: .subtitle,
            outputSettings: nil,
            sourceFormatHint: subtitleFormat
        )
        subtitleInput.mediaTimeScale = 600
        subtitleInput.languageCode = "eng"
        subtitleInput.extendedLanguageTag = "en-US"
        subtitleInput.metadata = trackMetadata(title: "English subtitles")
        let captionInput = AVAssetWriterInput(
            mediaType: .closedCaption,
            outputSettings: nil,
            sourceFormatHint: captionFormat
        )
        captionInput.mediaTimeScale = 600
        captionInput.languageCode = "eng"
        captionInput.extendedLanguageTag = "en-US"
        captionInput.metadata = trackMetadata(title: "CEA-608 captions")
        for input in [subtitleInput, captionInput] {
            guard writer.availableMediaTypes.contains(input.mediaType),
                  writer.canAdd(input) else {
                throw TrackMigrationFixtureErrorV4.writer(
                    "Writer rejected \(input.mediaType.rawValue)."
                )
            }
            writer.add(input)
        }

        guard writer.startWriting() else {
            throw TrackMigrationFixtureErrorV4.writer(
                writer.error?.localizedDescription
                    ?? "Legible writer did not start."
            )
        }
        writer.startSession(atSourceTime: .zero)
        let duration = CMTime(
            value: CMTimeValue(frameCount),
            timescale: frameRate
        )
        let subtitleText = Data("ASH subtitle".utf8)
        let subtitleLength = UInt16(subtitleText.count).bigEndian
        var subtitleData = withUnsafeBytes(of: subtitleLength) { Data($0) }
        subtitleData.append(subtitleText)
        try await append(
            try makeEncodedSampleBuffer(
                data: subtitleData,
                format: subtitleFormat,
                duration: duration
            ),
            to: subtitleInput,
            writer: writer
        )
        // QuickTime wraps CEA-608 pairs in a `cdat` atom. The first eight
        // bytes are its big-endian size and type; the remaining bytes encode
        // a resume-caption-loading control followed by HI.
        let captionData = Data([
            0x00, 0x00, 0x00, 0x0C,
            0x63, 0x64, 0x61, 0x74,
            0x94, 0x20, 0xC8, 0xC9
        ])
        try await append(
            try makeEncodedSampleBuffer(
                data: captionData,
                format: captionFormat,
                duration: duration
            ),
            to: captionInput,
            writer: writer
        )
        subtitleInput.markAsFinished()
        captionInput.markAsFinished()
        writer.endSession(atSourceTime: duration)
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else {
            throw TrackMigrationFixtureErrorV4.writer(
                writer.error?.localizedDescription
                    ?? "Legible writer did not finish."
            )
        }
    }

    static func makeRichMovie(
        at url: URL,
        includeAudioGroup: Bool,
        selectDefaultAudio: Bool = true,
        incompatibleAudioTransition: Bool = false
    ) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.metadata = assetMetadata()
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
                defaultInput: selectDefaultAudio ? englishAudio : nil
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
        if incompatibleAudioTransition {
            let transitionFormat = try makeAudioFormatDescription(
                sampleRate: 44_100
            )
            let transitionTime = CMTime(value: 1, timescale: 4)
            try await append(
                try makeAudioSampleBuffer(
                    format: transitionFormat,
                    amplitude: 350,
                    presentationTimeStamp: transitionTime
                ),
                to: englishAudio,
                writer: writer
            )
            try await append(
                try makeAudioSampleBuffer(
                    format: transitionFormat,
                    amplitude: -350,
                    presentationTimeStamp: transitionTime
                ),
                to: spanishAudio,
                writer: writer
            )
        }
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
        writer.endSession(atSourceTime: incompatibleAudioTransition
            ? CMTime(value: 1, timescale: 2)
            : CMTime(
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

    static func makeRichMovieWithIncompatibleAudioTransitions(
        at url: URL,
        includeAudioGroup: Bool
    ) async throws {
        try await makeRichMovie(
            at: url,
            includeAudioGroup: includeAudioGroup,
            incompatibleAudioTransition: true
        )
    }

    static func makeAudioMovie(
        at url: URL,
        channelLayoutTag: AudioChannelLayoutTag,
        amplitude: Int16
    ) async throws {
        let channels = AudioChannelLayoutTag_GetNumberOfChannels(
            channelLayoutTag
        )
        let format = try makeAudioFormatDescription(
            channels: channels,
            channelLayoutTag: channelLayoutTag
        )
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: nil,
            sourceFormatHint: format
        )
        guard writer.canAdd(input) else {
            throw TrackMigrationFixtureErrorV4.writer(
                "Writer rejected multichannel PCM input."
            )
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw TrackMigrationFixtureErrorV4.writer(
                writer.error?.localizedDescription ?? "startWriting failed"
            )
        }
        writer.startSession(atSourceTime: .zero)
        try await append(
            try makeAudioSampleBuffer(format: format, amplitude: amplitude),
            to: input,
            writer: writer
        )
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 1, timescale: 4))
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else {
            throw TrackMigrationFixtureErrorV4.writer(
                writer.error?.localizedDescription ?? "finishWriting failed"
            )
        }
    }

    static func makeTwinAudioPayloadMovie(at url: URL) async throws {
        let format = try makeAudioFormatDescription()
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let first = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: nil,
            sourceFormatHint: format
        )
        let second = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: nil,
            sourceFormatHint: format
        )
        for input in [first, second] {
            guard writer.canAdd(input) else {
                throw TrackMigrationFixtureErrorV4.writer(
                    "Writer rejected twin PCM input."
                )
            }
            writer.add(input)
        }
        guard writer.startWriting() else {
            throw TrackMigrationFixtureErrorV4.writer(
                writer.error?.localizedDescription ?? "startWriting failed"
            )
        }
        writer.startSession(atSourceTime: .zero)
        try await append(
            try makeAudioSampleBuffer(format: format, amplitude: 600),
            to: first,
            writer: writer
        )
        try await append(
            try makeAudioSampleBuffer(format: format, amplitude: -600),
            to: second,
            writer: writer
        )
        first.markAsFinished()
        second.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 1, timescale: 4))
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else {
            throw TrackMigrationFixtureErrorV4.writer(
                writer.error?.localizedDescription ?? "finishWriting failed"
            )
        }
    }

    static func makeCompatibleMultiDescriptionAudioMovie(
        at url: URL
    ) async throws {
        let first = try makeAudioFormatDescription(
            channels: 6,
            channelLayoutTag: kAudioChannelLayoutTag_MPEG_5_1_A
        )
        let second = try makeAudioFormatDescription(
            channels: 6,
            channelLayoutTag: kAudioChannelLayoutTag_MPEG_5_1_B
        )
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: nil
        )
        guard writer.canAdd(input) else {
            throw TrackMigrationFixtureErrorV4.writer(
                "Writer rejected multi-description PCM input."
            )
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw TrackMigrationFixtureErrorV4.writer(
                writer.error?.localizedDescription ?? "startWriting failed"
            )
        }
        writer.startSession(atSourceTime: .zero)
        try await append(
            try makeAudioSampleBuffer(format: first, amplitude: 300),
            to: input,
            writer: writer
        )
        try await append(
            try makeAudioSampleBuffer(
                format: second,
                amplitude: -300,
                presentationTimeStamp: CMTime(value: 1, timescale: 4)
            ),
            to: input,
            writer: writer
        )
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 1, timescale: 2))
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
        title: String,
        mediaType: AVMediaType = .video
    ) -> VideoLane {
        let input = AVAssetWriterInput(
            mediaType: mediaType,
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

    private static func makeAudioFormatDescription(
        sampleRate: Double = 48_000,
        channels: UInt32 = 1,
        channelLayoutTag: AudioChannelLayoutTag? = nil
    ) throws
        -> CMAudioFormatDescription {
        let bytesPerFrame = 2 * channels
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger
                | kAudioFormatFlagIsPacked,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var format: CMAudioFormatDescription?
        let status: OSStatus
        if let channelLayoutTag {
            var layout = AudioChannelLayout()
            layout.mChannelLayoutTag = channelLayoutTag
            let layoutSize = MemoryLayout<AudioChannelLayout>.size
                - MemoryLayout<AudioChannelDescription>.size
            status = withUnsafePointer(to: &layout) { pointer in
                CMAudioFormatDescriptionCreate(
                    allocator: kCFAllocatorDefault,
                    asbd: &asbd,
                    layoutSize: layoutSize,
                    layout: pointer,
                    magicCookieSize: 0,
                    magicCookie: nil,
                    extensions: nil,
                    formatDescriptionOut: &format
                )
            }
        } else {
            status = CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: &asbd,
                layoutSize: 0,
                layout: nil,
                magicCookieSize: 0,
                magicCookie: nil,
                extensions: nil,
                formatDescriptionOut: &format
            )
        }
        guard status == noErr, let format else {
            throw TrackMigrationFixtureErrorV4.coreMedia(status)
        }
        return format
    }

    private static func makeFormatDescription(
        mediaType: CMMediaType,
        mediaSubtype: FourCharCode,
        extensions: CFDictionary? = nil
    ) throws -> CMFormatDescription {
        var format: CMFormatDescription?
        let status = CMFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            mediaType: mediaType,
            mediaSubType: mediaSubtype,
            extensions: extensions,
            formatDescriptionOut: &format
        )
        guard status == noErr, let format else {
            throw TrackMigrationFixtureErrorV4.coreMedia(status)
        }
        return format
    }

    private static var subtitleFormatExtensions: CFDictionary {
        let transparentBlack: [CFString: NSNumber] = [
            kCMTextFormatDescriptionColor_Red: NSNumber(value: Int8(0)),
            kCMTextFormatDescriptionColor_Green: NSNumber(value: Int8(0)),
            kCMTextFormatDescriptionColor_Blue: NSNumber(value: Int8(0)),
            kCMTextFormatDescriptionColor_Alpha: NSNumber(value: Int8(0))
        ]
        let opaqueWhite: [CFString: NSNumber] = [
            kCMTextFormatDescriptionColor_Red: NSNumber(value: UInt8.max),
            kCMTextFormatDescriptionColor_Green: NSNumber(value: UInt8.max),
            kCMTextFormatDescriptionColor_Blue: NSNumber(value: UInt8.max),
            kCMTextFormatDescriptionColor_Alpha: NSNumber(value: UInt8.max)
        ]
        let extensions: [CFString: Any] = [
            kCMTextFormatDescriptionExtension_DisplayFlags:
                NSNumber(value: UInt32(0)),
            kCMTextFormatDescriptionExtension_HorizontalJustification:
                NSNumber(value: Int8(0)),
            kCMTextFormatDescriptionExtension_VerticalJustification:
                NSNumber(value: Int8(-1)),
            kCMTextFormatDescriptionExtension_BackgroundColor:
                transparentBlack,
            kCMTextFormatDescriptionExtension_DefaultTextBox: [
                kCMTextFormatDescriptionRect_Top: NSNumber(value: Int16(0)),
                kCMTextFormatDescriptionRect_Left: NSNumber(value: Int16(0)),
                kCMTextFormatDescriptionRect_Bottom: NSNumber(value: Int16(48)),
                kCMTextFormatDescriptionRect_Right: NSNumber(value: Int16(64))
            ],
            kCMTextFormatDescriptionExtension_DefaultStyle: [
                kCMTextFormatDescriptionStyle_StartChar:
                    NSNumber(value: Int16(0)),
                kCMTextFormatDescriptionStyle_EndChar:
                    NSNumber(value: Int16(0)),
                kCMTextFormatDescriptionStyle_Font: NSNumber(value: Int16(1)),
                kCMTextFormatDescriptionStyle_FontFace: NSNumber(value: Int8(0)),
                kCMTextFormatDescriptionStyle_FontSize: NSNumber(value: Int8(18)),
                kCMTextFormatDescriptionStyle_ForegroundColor: opaqueWhite
            ],
            kCMTextFormatDescriptionExtension_FontTable: ["1": "Helvetica"]
        ]
        return extensions as CFDictionary
    }

    private static func makeEncodedSampleBuffer(
        data: Data,
        format: CMFormatDescription,
        duration: CMTime
    ) throws -> CMSampleBuffer {
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
        status = data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                return kCMBlockBufferBadLengthParameterErr
            }
            return CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: data.count
            )
        }
        guard status == kCMBlockBufferNoErr else {
            throw TrackMigrationFixtureErrorV4.coreMedia(status)
        }
        var timing = CMSampleTimingInfo(
            duration: duration,
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

    private static func makeAudioSampleBuffer(
        format: CMAudioFormatDescription,
        amplitude: Int16,
        presentationTimeStamp: CMTime = .zero
    ) throws -> CMSampleBuffer {
        guard let stream = CMAudioFormatDescriptionGetStreamBasicDescription(
            format
        )?.pointee,
        stream.mSampleRate.isFinite,
        let integralRate = Int(exactly: stream.mSampleRate),
        let timeScale = Int32(exactly: integralRate),
        timeScale > 0 else {
            throw TrackMigrationFixtureErrorV4.invalidFixture(
                "Audio sample rate is invalid."
            )
        }
        let frameCount = Int(timeScale) / 4
        let channelCount = Int(stream.mChannelsPerFrame)
        let samples = [Int16](
            repeating: amplitude,
            count: frameCount * channelCount
        )
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
            duration: CMTime(value: 1, timescale: timeScale),
            presentationTimeStamp: presentationTimeStamp,
            decodeTimeStamp: .invalid
        )
        var sampleSize = MemoryLayout<Int16>.size * channelCount
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

    private static func assetMetadata() -> [AVMetadataItem] {
        let title = AVMutableMetadataItem()
        title.identifier = .commonIdentifierTitle
        title.dataType = kCMMetadataBaseDataType_UTF8 as String
        title.extendedLanguageTag = "en-US"
        title.value = "Mirmir deterministic migration fixture" as NSString

        let copyright = AVMutableMetadataItem()
        copyright.identifier = .commonIdentifierCopyrights
        copyright.dataType = kCMMetadataBaseDataType_UTF8 as String
        copyright.value = "Copyright 2026 ASH" as NSString
        return [title, copyright]
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

private func copySampleBufferV4(
    _ source: CMSampleBuffer
) throws -> CMSampleBuffer {
    var copy: CMSampleBuffer?
    let status = CMSampleBufferCreateCopy(
        allocator: kCFAllocatorDefault,
        sampleBuffer: source,
        sampleBufferOut: &copy
    )
    guard status == noErr, let copy else {
        throw TrackMigrationFixtureErrorV4.coreMedia(status)
    }
    return copy
}

private func payloadMutatingCopyV4(
    of source: CMSampleBuffer
) throws -> CMSampleBuffer {
    let sampleCount = CMSampleBufferGetNumSamples(source)
    guard sampleCount > 0,
          let format = CMSampleBufferGetFormatDescription(source),
          let sourceData = CMSampleBufferGetDataBuffer(source) else {
        throw TrackMigrationFixtureErrorV4.invalidFixture(
            "Decoded audio sample has no mutable payload contract."
        )
    }
    let totalSize = CMSampleBufferGetTotalSampleSize(source)
    guard totalSize > 0 else {
        throw TrackMigrationFixtureErrorV4.invalidFixture(
            "Decoded audio sample payload is empty."
        )
    }
    var payload = Data(count: totalSize)
    var status = payload.withUnsafeMutableBytes { destination in
        CMBlockBufferCopyDataBytes(
            sourceData,
            atOffset: 0,
            dataLength: totalSize,
            destination: destination.baseAddress!
        )
    }
    guard status == kCMBlockBufferNoErr else {
        throw TrackMigrationFixtureErrorV4.coreMedia(status)
    }
    payload[payload.startIndex] ^= 0xff

    var blockBuffer: CMBlockBuffer?
    status = CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault,
        memoryBlock: nil,
        blockLength: totalSize,
        blockAllocator: kCFAllocatorDefault,
        customBlockSource: nil,
        offsetToData: 0,
        dataLength: totalSize,
        flags: 0,
        blockBufferOut: &blockBuffer
    )
    guard status == kCMBlockBufferNoErr, let blockBuffer else {
        throw TrackMigrationFixtureErrorV4.coreMedia(status)
    }
    status = payload.withUnsafeBytes { sourceBytes in
        CMBlockBufferReplaceDataBytes(
            with: sourceBytes.baseAddress!,
            blockBuffer: blockBuffer,
            offsetIntoDestination: 0,
            dataLength: totalSize
        )
    }
    guard status == kCMBlockBufferNoErr else {
        throw TrackMigrationFixtureErrorV4.coreMedia(status)
    }

    var timings = try (0..<sampleCount).map { index in
        var timing = CMSampleTimingInfo.invalid
        let timingStatus = CMSampleBufferGetSampleTimingInfo(
            source,
            at: index,
            timingInfoOut: &timing
        )
        guard timingStatus == noErr else {
            throw TrackMigrationFixtureErrorV4.coreMedia(timingStatus)
        }
        return timing
    }
    var sampleSizes = (0..<sampleCount).map {
        CMSampleBufferGetSampleSize(source, at: $0)
    }
    var result: CMSampleBuffer?
    status = CMSampleBufferCreate(
        allocator: kCFAllocatorDefault,
        dataBuffer: blockBuffer,
        dataReady: true,
        makeDataReadyCallback: nil,
        refcon: nil,
        formatDescription: format,
        sampleCount: sampleCount,
        sampleTimingEntryCount: timings.count,
        sampleTimingArray: &timings,
        sampleSizeEntryCount: sampleSizes.count,
        sampleSizeArray: &sampleSizes,
        sampleBufferOut: &result
    )
    guard status == noErr, let result else {
        throw TrackMigrationFixtureErrorV4.coreMedia(status)
    }
    return result
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
