import AVFoundation
import AudioToolbox
import CoreMedia
import CoreVideo
import CryptoKit
import Darwin
import VideoToolbox
import XCTest
@testable import Mirmir

final class AVFoundationTrackMigrationExecutorV4Tests: XCTestCase {
    func testChapterMetadataTimeCanonicalizesEquivalentZeroClocks() throws {
        for timescale: CMTimeScale in [1, 500, 1_000, 90_000] {
            let canonical = try AVFoundationTrackMigrationExecutorV4
                .canonicalChapterMetadataTime(
                    CMTime(value: 0, timescale: timescale)
                )
            XCTAssertEqual(canonical.value, 0)
            XCTAssertEqual(canonical.timescale, 1)
            XCTAssertEqual(canonical.flags, .valid)
            XCTAssertEqual(canonical.epoch, 0)
        }
    }

    func testChapterMetadataTimeCanonicalizesExactRationalsAndRetainsChanges()
        throws {
        let source = CMTime(value: 3_753, timescale: 90_000)
        let canonical = try AVFoundationTrackMigrationExecutorV4
            .canonicalChapterMetadataTime(source)
        let equivalent = try AVFoundationTrackMigrationExecutorV4
            .canonicalChapterMetadataTime(
                CMTime(value: 417, timescale: 10_000)
            )
        XCTAssertEqual(canonical.value, 417)
        XCTAssertEqual(canonical.timescale, 10_000)
        XCTAssertEqual(equivalent.value, canonical.value)
        XCTAssertEqual(equivalent.timescale, canonical.timescale)
        XCTAssertEqual(CMTimeCompare(source, canonical), 0)

        let changed = try AVFoundationTrackMigrationExecutorV4
            .canonicalChapterMetadataTime(
                CMTime(value: 3_754, timescale: 90_000)
            )
        XCTAssertNotEqual(CMTimeCompare(canonical, changed), 0)

        let chapterDuration = try AVFoundationTrackMigrationExecutorV4
            .canonicalChapterMetadataTime(
                CMTime(value: 392_100, timescale: 1_000)
            )
        XCTAssertEqual(chapterDuration.value, 3_921)
        XCTAssertEqual(chapterDuration.timescale, 10)
    }

    func testChapterMetadataTimePreservesNumericFlagsAndEpoch() throws {
        let original = CMTime(
            value: 0,
            timescale: 500,
            flags: [.valid, .hasBeenRounded],
            epoch: 7
        )
        let canonical = try AVFoundationTrackMigrationExecutorV4
            .canonicalChapterMetadataTime(original)
        XCTAssertEqual(canonical.value, 0)
        XCTAssertEqual(canonical.timescale, 1)
        XCTAssertEqual(canonical.flags, original.flags)
        XCTAssertEqual(canonical.epoch, original.epoch)

        let exact = try AVFoundationTrackMigrationExecutorV4
            .canonicalChapterMetadataTime(
                CMTime(value: 0, timescale: 500, flags: .valid, epoch: 7)
            )
        let differentEpoch = try AVFoundationTrackMigrationExecutorV4
            .canonicalChapterMetadataTime(
                CMTime(value: 0, timescale: 500, flags: original.flags, epoch: 8)
            )
        XCTAssertNotEqual(canonical.flags, exact.flags)
        XCTAssertNotEqual(canonical.epoch, differentEpoch.epoch)
    }

    func testChapterMetadataTimePreservesNonnumericRepresentations() throws {
        let originals: [CMTime] = [
            .invalid,
            .indefinite,
            .positiveInfinity,
            .negativeInfinity,
            CMTime(value: 17, timescale: 500, flags: [], epoch: 7),
            CMTime(value: 17, timescale: 0, flags: .valid, epoch: 7),
            CMTime(value: 17, timescale: -500, flags: .valid, epoch: 7),
        ]
        for original in originals {
            let canonical = try AVFoundationTrackMigrationExecutorV4
                .canonicalChapterMetadataTime(original)
            XCTAssertEqual(canonical.value, original.value)
            XCTAssertEqual(canonical.timescale, original.timescale)
            XCTAssertEqual(canonical.flags, original.flags)
            XCTAssertEqual(canonical.epoch, original.epoch)
        }
    }

    func testMediaSegmentErrorCode11ExplainsWriterRejection() {
        let error = DeterministicV4MediaSegmentError.writerRejectedTrack as NSError
        XCTAssertEqual(error.domain, "Mirmir.DeterministicV4MediaSegmentError")
        XCTAssertEqual(error.code, 11)
        XCTAssertTrue(error.localizedDescription.contains("video output configuration"))
        XCTAssertTrue(error.localizedDescription.contains("Diagnostics"))
    }

    func testMediaSegmentErrorCode16IsInvalidSampleTiming() {
        let site = DeterministicV4InvalidSampleTimingSite
            .nominalCadenceOffLattice
        let error = DeterministicV4MediaSegmentError.invalidSampleTiming(
            site: site
        ) as NSError
        XCTAssertEqual(error.domain, "Mirmir.DeterministicV4MediaSegmentError")
        XCTAssertEqual(error.code, 16)
        XCTAssertTrue(error.localizedDescription.contains(site.rawValue))
        XCTAssertEqual(
            Set(DeterministicV4InvalidSampleTimingSite.allCases.map(\.rawValue))
                .count,
            57
        )
        XCTAssertEqual(
            DeterministicV4InvalidSampleTimingSite.allCases.count,
            57
        )
    }

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
        let runtimeEvents = execution.runtimeEvents

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
        XCTAssertEqual(
            receipt.hdr10PlusPreservation.routeID,
            .canonicalDynamicAbsentOnePass
        )
        XCTAssertEqual(receipt.hdr10PlusPreservation.segmentCount, 0)
        XCTAssertEqual(
            receipt.hdr10PlusPreservation.rewrittenSampleCount,
            0
        )
        XCTAssertEqual(
            receipt.hdr10PlusPreservation.timelineMappingSHA256,
            try DeterministicV4HDR10PlusPreservationReportV4
                .notApplicableTimelineMappingSHA256(
                    trackPlanSHA256: receipt.trackPlanSHA256
                )
        )
        let receiptData = try ASHCanonicalJSONV4.encode(receipt)
        XCTAssertEqual(
            try ASHCanonicalJSONV4.decode(
                DeterministicV4MediaExecutionReceiptV4.self,
                from: receiptData
            ),
            receipt
        )
        XCTAssertEqual(runtimeEvents.map(\.ordinal), [0, 1, 2])
        XCTAssertEqual(
            runtimeEvents.map(\.kind),
            [.planning, .execution, .verification]
        )
        XCTAssertEqual(
            runtimeEvents.map(\.code),
            [
                "asset_plan_bound",
                "asset_execution_completed",
                "asset_output_verified"
            ]
        )
        XCTAssertTrue(runtimeEvents.allSatisfy {
            $0.planSHA256 == receipt.ashPlanSHA256
                && $0.runtimeManifestSHA256
                    == receipt.runtimeManifestSHA256
        })
        XCTAssertEqual(runtimeEvents[0].parentEventSHA256, [])
        XCTAssertEqual(
            runtimeEvents[1].parentEventSHA256,
            [try runtimeEvents[0].canonicalSHA256]
        )
        XCTAssertEqual(
            runtimeEvents[2].parentEventSHA256,
            [try runtimeEvents[1].canonicalSHA256]
        )
        try runtimeEvents.forEach { try $0.validate() }
        XCTAssertEqual(
            runtimeEvents,
            try DeterministicV4MediaRuntimeEventChainV4.make(
                receipt: receipt
            )
        )
        let runtimeEventData = try ASHCanonicalJSONV4.encode(runtimeEvents)
        XCTAssertEqual(
            try ASHCanonicalJSONV4.decode(
                [ASHRuntimeEventEnvelopeV4].self,
                from: runtimeEventData
            ),
            runtimeEvents
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

    func testDynamicHDRSegmentRoutePreservesNonzeroPrimaryStartEarlierAudioBoundaryGapAndTemporalReset()
        async throws {
        let directory = try TrackMigrationFixtureDirectoryV4()
        defer { directory.remove() }
        let sourceURL = directory.url("hdr-boundary-source.mov")
        let changedLeadingDurationURL = directory.url(
            "hdr-boundary-leading-duration-changed.mov"
        )
        let destinationURL = directory.url("hdr-boundary-output.mov")
        let runtimeURL = directory.url("hdr-boundary-p06.bundle")
        let fixture = try await TrackMigrationFixtureFactoryV4
            .makeHDRBoundaryMovie(
                at: sourceURL,
                changedLeadingDurationURL: changedLeadingDurationURL
            )
        let cursorDiagnostic = try await
            hdrBoundaryCursorGeneratorObservation(
                at: sourceURL,
                expectedPresentationTimes: fixture.mediaPresentationTimes,
                expectedReaderReportedDurations:
                    TrackMigrationFixtureFactoryV4
                        .hdrBoundaryReaderReportedDurations(),
                expectedMetadata: fixture.hdr10Plus
            )
        let cursorAttachment = XCTAttachment(
            string: cursorDiagnostic.diagnostic
        )
        cursorAttachment.name = "HDR boundary cursor and generator facts"
        cursorAttachment.lifetime = .keepAlways
        add(cursorAttachment)
        XCTAssertEqual(
            cursorDiagnostic.facts.map(\.cursorPresentationTime),
            fixture.mediaPresentationTimes
        )
        XCTAssertEqual(
            cursorDiagnostic.facts.map(\.cursorDecodeTime),
            fixture.mediaPresentationTimes.indices.map {
                CMTime(value: CMTimeValue($0), timescale: 30)
            }
        )
        XCTAssertEqual(
            cursorDiagnostic.facts.map(\.cursorDuration),
            TrackMigrationFixtureFactoryV4
                .hdrBoundaryReaderReportedDurations()
        )
        XCTAssertEqual(
            cursorDiagnostic.facts.map(\.generatedPresentationTime),
            fixture.mediaPresentationTimes
        )
        XCTAssertEqual(
            cursorDiagnostic.facts.map(\.generatedDecodeTime),
            cursorDiagnostic.facts.map(\.cursorDecodeTime)
        )
        XCTAssertEqual(
            cursorDiagnostic.facts.map(\.generatedDuration),
            cursorDiagnostic.facts.map(\.cursorDuration)
        )
        XCTAssertEqual(
            cursorDiagnostic.facts.map(\.generatedOutputPresentationTime),
            fixture.mediaPresentationTimes
        )
        XCTAssertEqual(
            cursorDiagnostic.facts.map(\.generatedOutputDuration),
            cursorDiagnostic.facts.map(\.cursorDuration)
        )
        XCTAssertTrue(cursorDiagnostic.facts.allSatisfy {
            $0.generatedDataByteCount > 0
                && $0.cursorIsFullSync
                && !$0.cursorIsPartialSync
                && $0.cursorSamplesRequiredForDecoderRefresh == 0
                && $0.generatedIsSync
                && ($0.trimDurationAtStart.map(hdrBoundaryIsExactZero)
                    ?? true)
                && ($0.trimDurationAtEnd.map(hdrBoundaryIsExactZero)
                    ?? true)
        })
        let source = try await VideoProbe().probe(url: sourceURL)
        XCTAssertEqual(source.videoTrackCount, 1)
        XCTAssertEqual(source.audioTrackCount, 1)
        let decodedSourceDomain = try await decodedVideoSampleDomain(
            at: sourceURL
        )
        XCTAssertEqual(decodedSourceDomain.zeroSampleMarkerCount, 0)
        XCTAssertEqual(
            decodedSourceDomain.presentationTimes.count,
            TrackMigrationFixtureFactoryV4.hdrBoundaryFrameCount + 1
        )
        XCTAssertEqual(
            decodedSourceDomain.presentationTimes.first,
            .zero
        )
        XCTAssertEqual(
            Array(decodedSourceDomain.presentationTimes.dropFirst()),
            fixture.mediaPresentationTimes.map {
                CMTimeAdd($0, fixture.primaryTargetStart)
            }
        )
        let frameDuration = CMTime(value: 1, timescale: 30)
        let readerTargetEnd = CMTimeAdd(
            CMTimeAdd(
                try XCTUnwrap(fixture.mediaPresentationTimes.last),
                frameDuration
            ),
            fixture.primaryTargetStart
        )
        let firstMediaTimes = Array(
            fixture.mediaPresentationTimes.prefix(60)
        )
        let firstTargetTimes = firstMediaTimes.map {
            CMTimeAdd($0, fixture.primaryTargetStart)
        }
        let firstReaderDomain = try await directTimelineReaderDomain(
            at: sourceURL,
            targetStart: fixture.primaryTargetStart,
            targetEnd: readerTargetEnd,
            offset: fixture.primaryTargetStart,
            maximumConcreteSamples: 60
        )
        XCTAssertTrue(firstReaderDomain.decodedSampleCounts.allSatisfy {
            $0 == 0 || $0 == 1
        })
        XCTAssertEqual(
            firstReaderDomain.decodedSampleCounts.filter { $0 == 1 }.count,
            60
        )
        XCTAssertEqual(
            firstReaderDomain.decodedTargetPresentationTimes,
            firstTargetTimes
        )
        XCTAssertEqual(
            firstReaderDomain.decodedDurations,
            Array(repeating: .invalid, count: 60)
        )
        XCTAssertEqual(
            firstReaderDomain.canonicalMediaPresentationTimes,
            firstMediaTimes
        )
        XCTAssertTrue(firstReaderDomain.compressedSampleCounts.allSatisfy {
            $0 == 0 || $0 == 1
        })
        XCTAssertEqual(
            firstReaderDomain.compressedSampleCounts.filter { $0 == 1 }.count,
            60
        )
        XCTAssertEqual(
            firstReaderDomain.compressedMediaPresentationTimes,
            firstMediaTimes
        )
        XCTAssertEqual(
            firstReaderDomain.compressedDurations,
            Array(
                TrackMigrationFixtureFactoryV4
                    .hdrBoundaryReaderReportedDurations()
                    .prefix(60)
            )
        )
        XCTAssertEqual(
            firstReaderDomain.canonicalMediaPresentationTimes,
            firstReaderDomain.compressedMediaPresentationTimes
        )
        XCTAssertEqual(
            Set(firstReaderDomain.canonicalMediaPresentationTimes),
            Set(firstReaderDomain.compressedMediaPresentationTimes)
        )

        let finalMediaTime = try XCTUnwrap(
            fixture.mediaPresentationTimes.last
        )
        let finalTargetTime = CMTimeAdd(
            finalMediaTime,
            fixture.primaryTargetStart
        )
        let finalReaderDomain = try await directTimelineReaderDomain(
            at: sourceURL,
            targetStart: finalTargetTime,
            targetEnd: readerTargetEnd,
            offset: fixture.primaryTargetStart,
            maximumConcreteSamples: 60
        )
        XCTAssertTrue(finalReaderDomain.decodedSampleCounts.allSatisfy {
            $0 == 0 || $0 == 1
        })
        XCTAssertEqual(
            finalReaderDomain.decodedSampleCounts.filter { $0 == 1 }.count,
            1
        )
        XCTAssertEqual(
            finalReaderDomain.decodedTargetPresentationTimes,
            [finalTargetTime]
        )
        XCTAssertEqual(
            finalReaderDomain.decodedDurations,
            [.invalid]
        )
        XCTAssertEqual(
            finalReaderDomain.canonicalMediaPresentationTimes,
            [finalMediaTime]
        )
        XCTAssertTrue(finalReaderDomain.compressedSampleCounts.allSatisfy {
            $0 == 0 || $0 == 1
        })
        XCTAssertEqual(
            finalReaderDomain.compressedSampleCounts.filter { $0 == 1 }.count,
            1
        )
        XCTAssertEqual(
            finalReaderDomain.compressedMediaPresentationTimes,
            [finalMediaTime]
        )
        XCTAssertEqual(
            finalReaderDomain.compressedDurations,
            [frameDuration]
        )
        XCTAssertEqual(
            Set(finalReaderDomain.canonicalMediaPresentationTimes),
            Set(finalReaderDomain.compressedMediaPresentationTimes)
        )
        let durationRecords = try firstMediaTimes.prefix(2).map {
            DeterministicV4DecodedDurationRecordV4(
                presentationTime: try HDR10PlusPresentationTimeV4($0),
                duration: frameDuration
            )
        }
        XCTAssertThrowsError(
            try DeterministicV4DecodedDurationLedgerV4(
                records: [durationRecords[0], durationRecords[0]],
                maximumRecordCount: 2
            )
        )
        var mismatchedDurationLedger = try
            DeterministicV4DecodedDurationLedgerV4(
                records: durationRecords,
                maximumRecordCount: 2
            )
        XCTAssertThrowsError(
            try mismatchedDurationLedger.consume(
                presentationTime: durationRecords[1].presentationTime
            )
        )
        let unconsumedDurationLedger = try
            DeterministicV4DecodedDurationLedgerV4(
                records: durationRecords,
                maximumRecordCount: 2
            )
        XCTAssertThrowsError(try unconsumedDurationLedger.seal())
        var exactDurationLedger = try
            DeterministicV4DecodedDurationLedgerV4(
                records: durationRecords,
                maximumRecordCount: 2
            )
        for record in durationRecords {
            XCTAssertEqual(
                try exactDurationLedger.consume(
                    presentationTime: record.presentationTime
                ),
                frameDuration
            )
        }
        XCTAssertNoThrow(try exactDurationLedger.seal())
        let strictGapRecords = [
            DeterministicV4DecodedDurationRecordV4(
                presentationTime: durationRecords[0].presentationTime,
                duration: CMTime(value: 1, timescale: 60)
            ),
            durationRecords[1]
        ]
        var strictGapLedger = try DeterministicV4DecodedDurationLedgerV4(
            records: strictGapRecords,
            maximumRecordCount: 2
        )
        for record in strictGapRecords {
            XCTAssertEqual(
                try strictGapLedger.consume(
                    presentationTime: record.presentationTime
                ),
                record.duration
            )
        }
        XCTAssertNoThrow(try strictGapLedger.seal())
        let overlapRecords = [
            DeterministicV4DecodedDurationRecordV4(
                presentationTime: durationRecords[0].presentationTime,
                duration: CMTime(value: 1, timescale: 15)
            ),
            durationRecords[1]
        ]
        XCTAssertThrowsError(
            try DeterministicV4DecodedDurationLedgerV4(
                records: overlapRecords,
                maximumRecordCount: 2
            )
        )

        let bookmarkReference = "ephemeral-current-session-v4"
        let bookmarkDocumentSHA256 = ASHSHA256V4(rawData: Data(
            (bookmarkReference + "|v1").utf8
        ))
        let canonicalAdapter = AVCanonicalMediaStateAdapterV4()
        let canonicalRequest = AVCanonicalMediaStateProbeRequestV4(
            url: sourceURL,
            bookmarkReference: bookmarkReference,
            bookmarkDocumentSHA256: bookmarkDocumentSHA256,
            scanDynamicHDRMetadata: true
        )
        let canonicalProbe = try await canonicalAdapter.probe(
            canonicalRequest
        )
        XCTAssertEqual(canonicalProbe.admission, .admitted)
        let canonicalState = try canonicalProbe.requireAdmittedState()
        let canonicalPrimary = try XCTUnwrap(
            canonicalState.tracks.first {
                $0.enabled && $0.kind == .video
            }
        )
        XCTAssertEqual(
            canonicalPrimary.edits,
            [
                CanonicalMediaEditV4(
                    ordinal: 1,
                    sourceStart: .zero,
                    sourceDuration: try ExactRationalV4(91, 30),
                    timelineStart: try ExactRationalV4(2, 1),
                    rate: try ExactRationalV4(1, 1)
                )
            ]
        )
        let segmentMappingMetadata = canonicalPrimary.metadata.filter {
            $0.dataType
                == "application/vnd.apple.track-segment-mapping.v4"
        }
        XCTAssertEqual(
            segmentMappingMetadata.map(\.key),
            ["segment-mapping-000000", "segment-mapping-000001"]
        )
        let emptyEditWarnings = canonicalState.observations.filter {
            $0.severity == .warning
                && $0.code == .unsupportedValue
                && $0.path == "tracks[000000].edits[0]"
                && $0.observedValue
                    == "empty edit omitted from canonical edit rows; exact mapping fingerprinted in segment-mapping metadata and route topology is admitted separately"
        }
        XCTAssertEqual(emptyEditWarnings.count, 1)
        let canonicalHash = try canonicalState.canonicalSHA256
        let repeatedCanonicalProbe = try await canonicalAdapter.probe(
            canonicalRequest
        )
        XCTAssertEqual(repeatedCanonicalProbe.admission, .admitted)
        let repeatedCanonicalState = try repeatedCanonicalProbe
            .requireAdmittedState()
        XCTAssertEqual(repeatedCanonicalState, canonicalState)
        XCTAssertEqual(
            try repeatedCanonicalState.canonicalSHA256,
            canonicalHash
        )
        let repeatedCanonicalPrimary = try XCTUnwrap(
            repeatedCanonicalState.tracks.first {
                $0.enabled && $0.kind == .video
            }
        )
        XCTAssertEqual(
            repeatedCanonicalPrimary.metadata.filter {
                $0.dataType
                    == "application/vnd.apple.track-segment-mapping.v4"
            },
            segmentMappingMetadata
        )

        let changedCanonicalProbe = try await canonicalAdapter.probe(.init(
            url: changedLeadingDurationURL,
            bookmarkReference: bookmarkReference,
            bookmarkDocumentSHA256: bookmarkDocumentSHA256,
            scanDynamicHDRMetadata: true
        ))
        XCTAssertEqual(changedCanonicalProbe.admission, .admitted)
        let changedCanonicalState = try changedCanonicalProbe
            .requireAdmittedState()
        let changedCanonicalPrimary = try XCTUnwrap(
            changedCanonicalState.tracks.first {
                $0.enabled && $0.kind == .video
            }
        )
        XCTAssertEqual(
            changedCanonicalPrimary.edits,
            [
                CanonicalMediaEditV4(
                    ordinal: 1,
                    sourceStart: .zero,
                    sourceDuration: try ExactRationalV4(91, 30),
                    timelineStart: try ExactRationalV4(3, 1),
                    rate: try ExactRationalV4(1, 1)
                )
            ]
        )
        let changedSegmentMappingMetadata = changedCanonicalPrimary.metadata
            .filter {
                $0.dataType
                    == "application/vnd.apple.track-segment-mapping.v4"
            }
        XCTAssertEqual(
            changedSegmentMappingMetadata.map(\.key),
            ["segment-mapping-000000", "segment-mapping-000001"]
        )
        let leadingSegmentMapping = try XCTUnwrap(
            segmentMappingMetadata.first
        )
        let changedLeadingSegmentMapping = try XCTUnwrap(
            changedSegmentMappingMetadata.first
        )
        XCTAssertNotEqual(
            changedLeadingSegmentMapping.valueSHA256,
            leadingSegmentMapping.valueSHA256
        )
        XCTAssertNotEqual(
            try changedCanonicalState.canonicalSHA256,
            canonicalHash
        )

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
        let prepared = try await backend.prepare(
            request: BackendPreparationRequest(
                source: source,
                targetSize: CGSize(width: 96, height: 72)
            ),
            environment: .current()
        )
        let planning = try XCTUnwrap(
            prepared as? any PreparedDeterministicV4PlanningBackend
        )
        let temporal = try XCTUnwrap(
            prepared as? any PreparedCheckpointableTemporalFrameUpscaler
        )
        let recording = TrackMigrationRecordingDeterministicBackendV4(
            planning: planning,
            temporal: temporal
        )
        let request = UpscaleRequest(
            inputURL: sourceURL,
            outputURL: destinationURL,
            backendID: .mirmirDeterministicCPU,
            targetWidth: 96,
            targetHeight: 72,
            outputCodec: .hevc,
            preserveAudio: true,
            overwriteExistingFile: false
        )
        let planned = try await DeterministicV4WholeAssetPlanner().prepare(
            request: request,
            source: source,
            backend: recording,
            cancellation: ProcessingCancellation()
        )
        let primaryRows = planned.trackPlan.plan.tracks.filter {
            $0.source.identity.stableID
                == planned.primaryGraphTrack.identity.stableID
        }
        let plannedPrimary = try XCTUnwrap(primaryRows.first)
        XCTAssertEqual(primaryRows.count, 1)
        XCTAssertEqual(plannedPrimary.action, .process)
        XCTAssertEqual(
            plannedPrimary.expectedOutput?.timeRange.start,
            try ExactRationalV4(0, 1)
        )
        XCTAssertEqual(
            plannedPrimary.expectedOutput?.timeRange.duration,
            try ExactRationalV4(151, 30)
        )
        XCTAssertEqual(
            plannedPrimary.source.timeRange,
            plannedPrimary.expectedOutput?.timeRange
        )
        let plannedAudio = try XCTUnwrap(
            planned.trackPlan.plan.tracks.first {
                $0.source.kind == .audio
            }
        )
        XCTAssertEqual(
            plannedAudio.expectedOutput?.timeRange.start,
            try ExactRationalV4(0, 1)
        )
        let timelineMapping = try DeterministicV4PrimaryTimelineMappingV4(
            plannedPrimary: plannedPrimary
        )
        XCTAssertEqual(
            timelineMapping.mediaRange.start,
            try ExactRationalV4(0, 1)
        )
        XCTAssertEqual(
            timelineMapping.targetRange.start,
            try ExactRationalV4(2, 1)
        )
        XCTAssertEqual(
            timelineMapping.offset,
            try ExactRationalV4(2, 1)
        )
        XCTAssertEqual(
            timelineMapping.topology,
            .leadingEmptyThenNonempty
        )
        XCTAssertEqual(timelineMapping.acceptedEdits.count, 2)
        XCTAssertTrue(timelineMapping.acceptedEdits[0].isEmpty)
        XCTAssertNil(timelineMapping.acceptedEdits[0].source)
        XCTAssertEqual(
            timelineMapping.acceptedEdits[0].target.start,
            try ExactRationalV4(0, 1)
        )
        XCTAssertEqual(
            timelineMapping.acceptedEdits[0].target.duration,
            try ExactRationalV4(2, 1)
        )
        XCTAssertFalse(timelineMapping.acceptedEdits[1].isEmpty)
        XCTAssertEqual(
            timelineMapping.acceptedEdits[1].source?.start,
            try ExactRationalV4(0, 1)
        )
        XCTAssertEqual(
            timelineMapping.acceptedEdits[1].source?.duration,
            try ExactRationalV4(91, 30)
        )
        XCTAssertEqual(
            timelineMapping.acceptedEdits[1].target.start,
            try ExactRationalV4(2, 1)
        )
        XCTAssertEqual(
            timelineMapping.acceptedEdits[1].target.duration,
            try ExactRationalV4(91, 30)
        )
        let singleEdit = try MediaTrackEditV4(
            ordinal: 0,
            source: timelineMapping.mediaRange,
            target: timelineMapping.targetRange,
            isEmpty: false
        )
        let singleSource = try replacingTimeline(
            plannedPrimary.source,
            timeRange: timelineMapping.targetRange,
            edits: [singleEdit]
        )
        let singleOutput = try replacingTimeline(
            try XCTUnwrap(plannedPrimary.expectedOutput),
            timeRange: timelineMapping.targetRange,
            edits: [singleEdit]
        )
        let singleMapping = try DeterministicV4PrimaryTimelineMappingV4(
            plannedPrimary: MediaTrackPlannedTrackV4(
                source: singleSource,
                action: .process,
                origin: plannedPrimary.origin,
                expectedOutput: singleOutput,
                dropConsent: nil
            )
        )
        XCTAssertEqual(singleMapping.topology, .singleNonempty)
        XCTAssertEqual(singleMapping.acceptedEdits, [singleEdit])
        XCTAssertEqual(singleMapping.mediaRange, timelineMapping.mediaRange)
        XCTAssertEqual(singleMapping.targetRange, timelineMapping.targetRange)
        XCTAssertEqual(singleMapping.offset, timelineMapping.offset)
        let sourceTimeRangeMismatch = try replacingTimeline(
            plannedPrimary.source,
            timeRange: timelineMapping.targetRange,
            edits: plannedPrimary.source.edits
        )
        XCTAssertThrowsError(
            try DeterministicV4PrimaryTimelineMappingV4(
                plannedPrimary: MediaTrackPlannedTrackV4(
                    source: sourceTimeRangeMismatch,
                    action: .process,
                    origin: plannedPrimary.origin,
                    expectedOutput: plannedPrimary.expectedOutput,
                    dropConsent: nil
                )
            )
        )
        let sourceEditsMismatch = try replacingTimeline(
            plannedPrimary.source,
            timeRange: plannedPrimary.source.timeRange,
            edits: [singleEdit]
        )
        XCTAssertThrowsError(
            try DeterministicV4PrimaryTimelineMappingV4(
                plannedPrimary: MediaTrackPlannedTrackV4(
                    source: sourceEditsMismatch,
                    action: .process,
                    origin: plannedPrimary.origin,
                    expectedOutput: plannedPrimary.expectedOutput,
                    dropConsent: nil
                )
            )
        )
        let scaledTarget = try MediaExactTimeRangeV4(
            start: ExactRationalV4(2, 1),
            duration: ExactRationalV4(182, 30)
        )
        let scaledEdit = try MediaTrackEditV4(
            ordinal: 0,
            source: timelineMapping.mediaRange,
            target: scaledTarget,
            isEmpty: false
        )
        let scaledSource = try replacingTimeline(
            plannedPrimary.source,
            timeRange: scaledTarget,
            edits: [scaledEdit]
        )
        let scaledOutput = try replacingTimeline(
            try XCTUnwrap(plannedPrimary.expectedOutput),
            timeRange: scaledTarget,
            edits: [scaledEdit]
        )
        XCTAssertThrowsError(
            try DeterministicV4PrimaryTimelineMappingV4(
                plannedPrimary: MediaTrackPlannedTrackV4(
                    source: scaledSource,
                    action: .process,
                    origin: plannedPrimary.origin,
                    expectedOutput: scaledOutput,
                    dropConsent: nil
                )
            )
        )
        let splitDuration = try ExactRationalV4(91, 60)
        let secondMediaStart = try ExactRationalV4(91, 60)
        let secondTargetStart = try ExactRationalV4(211, 60)
        let multipleEdits = [
            try MediaTrackEditV4(
                ordinal: 0,
                source: MediaExactTimeRangeV4(
                    start: .zero,
                    duration: splitDuration
                ),
                target: MediaExactTimeRangeV4(
                    start: ExactRationalV4(2, 1),
                    duration: splitDuration
                ),
                isEmpty: false
            ),
            try MediaTrackEditV4(
                ordinal: 1,
                source: MediaExactTimeRangeV4(
                    start: secondMediaStart,
                    duration: splitDuration
                ),
                target: MediaExactTimeRangeV4(
                    start: secondTargetStart,
                    duration: splitDuration
                ),
                isEmpty: false
            )
        ]
        let multipleSource = try replacingTimeline(
            plannedPrimary.source,
            timeRange: timelineMapping.targetRange,
            edits: multipleEdits
        )
        let multipleOutput = try replacingTimeline(
            try XCTUnwrap(plannedPrimary.expectedOutput),
            timeRange: timelineMapping.targetRange,
            edits: multipleEdits
        )
        XCTAssertThrowsError(
            try DeterministicV4PrimaryTimelineMappingV4(
                plannedPrimary: MediaTrackPlannedTrackV4(
                    source: multipleSource,
                    action: .process,
                    origin: plannedPrimary.origin,
                    expectedOutput: multipleOutput,
                    dropConsent: nil
                )
            )
        )

        func assertStrictTimelineMappingRejected(
            _ caseName: String,
            timeRange: MediaExactTimeRangeV4,
            edits: [MediaTrackEditV4],
            file: StaticString = #filePath,
            line: UInt = #line
        ) throws {
            let sourceTrack = try replacingTimeline(
                plannedPrimary.source,
                timeRange: timeRange,
                edits: edits
            )
            let outputTrack = try replacingTimeline(
                try XCTUnwrap(plannedPrimary.expectedOutput),
                timeRange: timeRange,
                edits: edits
            )
            XCTAssertThrowsError(
                try DeterministicV4PrimaryTimelineMappingV4(
                    plannedPrimary: MediaTrackPlannedTrackV4(
                        source: sourceTrack,
                        action: .process,
                        origin: plannedPrimary.origin,
                        expectedOutput: outputTrack,
                        dropConsent: nil
                    )
                ),
                caseName,
                file: file,
                line: line
            )
        }

        let admittedMediaEdit = timelineMapping.acceptedEdits[1]
        let leadingGap = try MediaTrackEditV4(
            ordinal: 0,
            source: nil,
            target: MediaExactTimeRangeV4(
                start: .zero,
                duration: ExactRationalV4(1, 1)
            ),
            isEmpty: true
        )
        let leadingOverlap = try MediaTrackEditV4(
            ordinal: 0,
            source: nil,
            target: MediaExactTimeRangeV4(
                start: .zero,
                duration: ExactRationalV4(3, 1)
            ),
            isEmpty: true
        )
        let zeroTargetRange = try MediaExactTimeRangeV4(
            start: ExactRationalV4(2, 1),
            duration: .zero
        )
        let zeroDurationEdit = try MediaTrackEditV4(
            ordinal: 0,
            source: MediaExactTimeRangeV4(
                start: .zero,
                duration: .zero
            ),
            target: zeroTargetRange,
            isEmpty: false
        )
        try assertStrictTimelineMappingRejected(
            "zero-duration media mapping",
            timeRange: zeroTargetRange,
            edits: [zeroDurationEdit]
        )
        let zeroDurationLeadingEmpty = try MediaTrackEditV4(
            ordinal: 0,
            source: nil,
            target: MediaExactTimeRangeV4(
                start: .zero,
                duration: .zero
            ),
            isEmpty: true
        )
        let negativeSourceEdit = try MediaTrackEditV4(
            ordinal: 0,
            source: MediaExactTimeRangeV4(
                start: ExactRationalV4(-1, 1),
                duration: timelineMapping.mediaRange.duration
            ),
            target: timelineMapping.targetRange,
            isEmpty: false
        )
        try assertStrictTimelineMappingRejected(
            "negative media start",
            timeRange: timelineMapping.targetRange,
            edits: [negativeSourceEdit]
        )

        let mediaFirst = try MediaTrackEditV4(
            ordinal: 0,
            source: timelineMapping.mediaRange,
            target: timelineMapping.targetRange,
            isEmpty: false
        )
        let targetEnd = try timelineMapping.targetEnd
        let trailingEmpty = try MediaTrackEditV4(
            ordinal: 1,
            source: nil,
            target: MediaExactTimeRangeV4(
                start: targetEnd,
                duration: ExactRationalV4(1, 1)
            ),
            isEmpty: true
        )
        let trailingEmptyOrdinalTwo = try MediaTrackEditV4(
            ordinal: 2,
            source: nil,
            target: trailingEmpty.target,
            isEmpty: true
        )
        let fullPlannedRange = try XCTUnwrap(
            plannedPrimary.expectedOutput
        ).timeRange
        let invalidEditTopologies: [(
            name: String,
            timeRange: MediaExactTimeRangeV4,
            edits: [MediaTrackEditV4]
        )] = [
            (
                "leading gap",
                fullPlannedRange,
                [leadingGap, admittedMediaEdit]
            ),
            (
                "leading overlap",
                fullPlannedRange,
                [leadingOverlap, admittedMediaEdit]
            ),
            (
                "zero-duration leading empty",
                fullPlannedRange,
                [zeroDurationLeadingEmpty, admittedMediaEdit]
            ),
            (
                "reordered empty after media",
                fullPlannedRange,
                [mediaFirst, trailingEmpty]
            ),
            (
                "multiple empty edits",
                fullPlannedRange,
                timelineMapping.acceptedEdits + [trailingEmptyOrdinalTwo]
            )
        ]
        for topology in invalidEditTopologies {
            try assertStrictTimelineMappingRejected(
                topology.name,
                timeRange: topology.timeRange,
                edits: topology.edits
            )
        }

        let progressRecorder = UpscaleProgressRecorderV4()
        let execution = try await VideoProcessingSession()
            .processWithDeterministicV4ExecutionReceipt(
                request: request,
                source: source,
                preparedBackend: recording,
                cancellation: ProcessingCancellation(),
                progress: { progressRecorder.record($0) }
            )
        XCTAssertEqual(
            execution.result.processedFrameCount,
            TrackMigrationFixtureFactoryV4.hdrBoundaryFrameCount
        )
        XCTAssertEqual(
            execution.receipt.hdr10PlusPreservation.routeID,
            .boundedSegmentPrefixSEI
        )
        XCTAssertEqual(
            execution.receipt.hdr10PlusPreservation.segmentCount,
            2
        )
        XCTAssertEqual(
            execution.receipt.hdr10PlusPreservation.rewrittenSampleCount,
            0
        )
        XCTAssertEqual(
            execution.receipt.hdr10PlusPreservation.timelineMappingSHA256,
            try timelineMapping.canonicalSHA256
        )
        XCTAssertEqual(
            execution.receipt.hdr10PlusPreservation.timelineMappingSHA256,
            try ASHSHA256V4(
                "fc3bd406492075fc19ac2d5582ab7c71de5afb2e917b1d5ad4a57ee6a6e309b7"
            )
        )
        let migratedPrimary = try XCTUnwrap(
            execution.receipt.migratedTracks.first {
                $0.stableID == planned.primaryGraphTrack.identity.stableID
                    .rawValue
            }
        )
        XCTAssertEqual(
            migratedPrimary.migratedSampleCount,
            Int64(TrackMigrationFixtureFactoryV4.hdrBoundaryFrameCount)
        )
        let migratedAudio = try XCTUnwrap(
            execution.receipt.migratedTracks.first { $0.action == .passThrough }
        )
        XCTAssertEqual(
            migratedAudio.sourceSampleStreamSHA256,
            migratedAudio.outputSampleStreamSHA256
        )

        let backendObservations = await recording.recordedObservations()
        XCTAssertEqual(
            backendObservations.map(\.frameIndex),
            Array(0..<TrackMigrationFixtureFactoryV4.hdrBoundaryFrameCount)
        )
        XCTAssertEqual(
            backendObservations.map(\.presentationTime),
            fixture.mediaPresentationTimes
        )
        XCTAssertEqual(
            backendObservations.first?.resetReasons,
            [.streamStart]
        )
        XCTAssertEqual(
            backendObservations.last?.resetReasons,
            [.presentationTimeDiscontinuity]
        )
        let finishCallCount = await recording.recordedFinishCallCount()
        XCTAssertEqual(finishCallCount, 1)

        let presentationProgress = progressRecorder.snapshot().compactMap {
            event -> CMTime? in
            guard event.phase == .processingVideo else { return nil }
            return event.processedTime
        }
        let expectedPresentationProgress = fixture.mediaPresentationTimes.map {
            CMTimeAdd(
                CMTimeAdd($0, CMTime(value: 1, timescale: 30)),
                fixture.primaryTargetStart
            )
        }
        XCTAssertEqual(presentationProgress, expectedPresentationProgress)

        let outputHDR = try await hdr10PlusVideoObservations(
            at: destinationURL
        )
        let presentationOrder = outputHDR.presentationTimes.indices.sorted {
            CMTimeCompare(
                outputHDR.presentationTimes[$0],
                outputHDR.presentationTimes[$1]
            ) < 0
        }
        let presentationOrderedTimes = presentationOrder.map {
            outputHDR.presentationTimes[$0]
        }
        XCTAssertEqual(
            presentationOrderedTimes,
            fixture.mediaPresentationTimes
        )
        XCTAssertEqual(
            presentationOrder.map { outputHDR.metadata[$0] },
            Array(
                repeating: Optional(fixture.hdr10Plus),
                count: fixture.mediaPresentationTimes.count
            )
        )
        XCTAssertEqual(
            outputHDR.decodeTimes,
            fixture.mediaPresentationTimes.indices.map {
                CMTime(value: CMTimeValue($0), timescale: 30)
            }
        )
        XCTAssertEqual(
            zip(outputHDR.decodeTimes, outputHDR.decodeTimes.dropFirst()).map {
                CMTimeSubtract($1, $0)
            },
            Array(
                repeating: frameDuration,
                count: fixture.mediaPresentationTimes.count - 1
            )
        )
        XCTAssertEqual(
            outputHDR.durations.count,
            fixture.mediaPresentationTimes.count
        )
        XCTAssertTrue(outputHDR.durations.allSatisfy {
            $0.isNumeric
                && $0.value > 0
                && !$0.flags.contains(.hasBeenRounded)
        })
        XCTAssertEqual(
            presentationOrderedTimes[59],
            CMTime(value: 59, timescale: 30)
        )
        XCTAssertEqual(
            presentationOrderedTimes[60],
            fixture.mediaGapStart
        )
        XCTAssertEqual(
            CMTimeAdd(
                presentationOrderedTimes[59],
                frameDuration
            ),
            CMTime(value: 60, timescale: 30)
        )
        XCTAssertGreaterThan(
            CMTimeGetSeconds(CMTimeSubtract(
                presentationOrderedTimes[60],
                presentationOrderedTimes[59]
            )),
            CMTimeGetSeconds(CMTime(value: 1, timescale: 30))
        )

        let outputAsset = AVURLAsset(
            url: destinationURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let outputGraph = try await AVFoundationTrackGraphAdapterV4.probe(
            asset: outputAsset
        )
        let outputPrimary = try XCTUnwrap(
            outputGraph.tracks.first { $0.kind == .video }
        )
        let expectedPrimary = try XCTUnwrap(plannedPrimary.expectedOutput)
        XCTAssertEqual(outputPrimary.timeRange, expectedPrimary.timeRange)
        XCTAssertEqual(outputPrimary.edits, expectedPrimary.edits)
        let outputAudio = try XCTUnwrap(
            outputGraph.tracks.first { $0.kind == .audio }
        )
        XCTAssertEqual(outputAudio.timeRange, plannedAudio.expectedOutput?.timeRange)
        XCTAssertEqual(outputAudio.edits, plannedAudio.expectedOutput?.edits)
        let sourceHDRFormat = try await hdrFormatMetadata(at: sourceURL)
        let outputHDRFormat = try await hdrFormatMetadata(at: destinationURL)
        XCTAssertEqual(sourceHDRFormat, outputHDRFormat)
        XCTAssertFalse(try directory.containsPartialMovie())
    }

    func testCanonicalDynamicAbsentRouteUsesOnePassBackendAndExecutorOnce()
        async throws {
        let directory = try TrackMigrationFixtureDirectoryV4()
        defer { directory.remove() }
        let sourceURL = directory.url("one-pass-source.mov")
        let destinationURL = directory.url("one-pass-output.mov")
        let runtimeURL = directory.url("one-pass-p06.bundle")
        try await TrackMigrationFixtureFactoryV4.makeRichMovie(
            at: sourceURL,
            includeAudioGroup: false
        )
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
        let prepared = try await backend.prepare(
            request: BackendPreparationRequest(
                source: source,
                targetSize: CGSize(width: 96, height: 72)
            ),
            environment: .current()
        )
        let recording = TrackMigrationRecordingDeterministicBackendV4(
            planning: try XCTUnwrap(
                prepared as? any PreparedDeterministicV4PlanningBackend
            ),
            temporal: try XCTUnwrap(
                prepared as? any PreparedCheckpointableTemporalFrameUpscaler
            )
        )
        let progress = UpscaleProgressRecorderV4()
        let execution = try await DeterministicV4MediaProcessingSession()
            .process(
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
                preparedBackend: recording,
                cancellation: ProcessingCancellation(),
                progress: { progress.record($0) }
            )

        XCTAssertEqual(
            execution.receipt.hdr10PlusPreservation.routeID,
            .canonicalDynamicAbsentOnePass
        )
        XCTAssertEqual(execution.receipt.hdr10PlusPreservation.segmentCount, 0)
        XCTAssertEqual(
            execution.receipt.hdr10PlusPreservation.rewrittenSampleCount,
            0
        )
        XCTAssertEqual(
            execution.receipt.hdr10PlusPreservation.timelineMappingSHA256,
            try DeterministicV4HDR10PlusPreservationReportV4
                .notApplicableTimelineMappingSHA256(
                    trackPlanSHA256: execution.receipt.trackPlanSHA256
                )
        )
        let observations = await recording.recordedObservations()
        XCTAssertEqual(
            observations.map(\.frameIndex),
            Array(0..<TrackMigrationFixtureFactoryV4.frameCount)
        )
        XCTAssertEqual(Set(observations.map(\.frameIndex)).count, observations.count)
        let finishCallCount = await recording.recordedFinishCallCount()
        XCTAssertEqual(finishCallCount, 1)
        let progressValues = progress.snapshot()
        XCTAssertEqual(
            progressValues.filter { $0.phase == .finalizing }.count,
            1
        )
        XCTAssertEqual(
            progressValues.filter { $0.phase == .completed }.count,
            2
        )
        XCTAssertEqual(
            execution.result.processedFrameCount,
            TrackMigrationFixtureFactoryV4.frameCount
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destinationURL.path
        ))
        XCTAssertFalse(try directory.containsPartialMovie())
    }

    func testCanonicalDynamicAbsentDecodedCadenceChecksSegmentLookahead()
        throws {
        let nominal = try ExactRationalV4(1, 30)
        let constantRateBoundary = (0...60).map {
            CMTime(value: CMTimeValue($0), timescale: 30)
        }
        let nominalDurations = Array(
            repeating: CMTime(value: 1, timescale: 30),
            count: constantRateBoundary.count
        )
        XCTAssertNoThrow(
            try DeterministicV4MediaProcessingSession
                .validateNominalDecodedCadence(
                    presentationTimes: constantRateBoundary,
                    decodedDurations: nominalDurations,
                    nominalSourceFrameDuration: nominal
                )
        )

        let ntscNominal = try ExactRationalV4(1_001, 24_000)
        let quantizedNTSCBoundary = (0...60).map { index in
            let converted = CMTimeConvertScale(
                CMTime(
                    value: CMTimeValue(index * 1_001),
                    timescale: 24_000
                ),
                timescale: 90_000,
                method: .default
            )
            return CMTime(value: converted.value, timescale: 90_000)
        }
        let quantizedNTSCDurations = quantizedNTSCBoundary.indices.map {
            index in
            let value: CMTimeValue
            if index + 1 < quantizedNTSCBoundary.count {
                value = quantizedNTSCBoundary[index + 1].value
                    - quantizedNTSCBoundary[index].value
            } else {
                value = 3_754
            }
            return CMTime(value: value, timescale: 90_000)
        }
        XCTAssertNoThrow(
            try DeterministicV4MediaProcessingSession
                .validateNominalDecodedCadence(
                    presentationTimes: quantizedNTSCBoundary,
                    decodedDurations: quantizedNTSCDurations,
                    nominalSourceFrameDuration: ntscNominal
                ),
            "A 90 kHz media clock must retain normal 3,753/3,754-tick NTSC quantization."
        )
        XCTAssertNoThrow(
            try DeterministicV4MediaProcessingSession
                .validateNominalDecodedCadence(
                    presentationTimes: Array(
                        constantRateBoundary.prefix(60)
                    ),
                    decodedDurations: Array(nominalDurations.prefix(60)),
                    nominalSourceFrameDuration: nominal
                )
        )

        var boundaryGap = constantRateBoundary
        boundaryGap[60] = CMTime(value: 90, timescale: 30)
        XCTAssertThrowsError(
            try DeterministicV4MediaProcessingSession
                .validateNominalDecodedCadence(
                    presentationTimes: boundaryGap,
                    decodedDurations: nominalDurations,
                    nominalSourceFrameDuration: nominal
                )
        ) {
            XCTAssertEqual(
                $0 as? DeterministicV4MediaSegmentError,
                .invalidSampleTiming(site: .nominalCadenceOffLattice)
            )
        }

        var variableRateBoundary = constantRateBoundary
        variableRateBoundary[60] = CMTime(value: 121, timescale: 60)
        XCTAssertThrowsError(
            try DeterministicV4MediaProcessingSession
                .validateNominalDecodedCadence(
                    presentationTimes: variableRateBoundary,
                    decodedDurations: nominalDurations,
                    nominalSourceFrameDuration: nominal
                )
        ) {
            XCTAssertEqual(
                $0 as? DeterministicV4MediaSegmentError,
                .invalidSampleTiming(site: .nominalCadenceOffLattice)
            )
        }

        var mismatchedDurations = nominalDurations
        mismatchedDurations[59] = CMTime(value: 1, timescale: 60)
        XCTAssertThrowsError(
            try DeterministicV4MediaProcessingSession
                .validateNominalDecodedCadence(
                    presentationTimes: constantRateBoundary,
                    decodedDurations: mismatchedDurations,
                    nominalSourceFrameDuration: nominal
                )
        ) {
            XCTAssertEqual(
                $0 as? DeterministicV4MediaSegmentError,
                .invalidSampleTiming(
                    site: .nominalCadenceInvalidDecodedDuration
                )
            )
        }

        let unavailableDurations = Array(
            repeating: CMTime.invalid,
            count: constantRateBoundary.count
        )
        XCTAssertNoThrow(
            try DeterministicV4MediaProcessingSession
                .validateNominalDecodedCadence(
                    presentationTimes: constantRateBoundary,
                    decodedDurations: unavailableDurations,
                    nominalSourceFrameDuration: nominal
                )
        )

        let nominalDuration = try DeterministicV4MediaProcessingSession
            .nominalDecodedDuration(nominal)
        XCTAssertEqual(
            try DeterministicV4MediaProcessingSession
                .canonicalNominalDecodedDuration(
                    observedDuration: .invalid,
                    nominalDuration: nominalDuration
                ),
            nominalDuration
        )
        let roundedDuration = CMTimeConvertScale(
            nominalDuration,
            timescale: 1_000,
            method: .default
        )
        XCTAssertTrue(roundedDuration.flags.contains(.hasBeenRounded))
        XCTAssertEqual(
            try DeterministicV4MediaProcessingSession
                .canonicalNominalDecodedDuration(
                    observedDuration: roundedDuration,
                    nominalDuration: nominalDuration
                ),
            nominalDuration
        )
    }

    func testSegmentWriterClockUsesExact90kBoundaryTimescale() throws {
        let directory = try TrackMigrationFixtureDirectoryV4()
        defer { directory.remove() }
        let writer = try AVAssetWriter(
            outputURL: directory.url("segment-writer-clock.mov"),
            fileType: .mov
        )
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: nil
        )

        try DeterministicV4MediaProcessingSession.bindSegmentWriterClock(
            writer: writer,
            input: input,
            timescale: 90_000
        )

        XCTAssertEqual(writer.movieTimeScale, 90_000)
        XCTAssertEqual(input.mediaTimeScale, 90_000)
    }

    func testNominalDecodedCadenceAcceptsLong90kNTSCClockLattice()
        throws {
        let nominal = try ExactRationalV4(1_001, 24_000)
        let lastFrameIndex = 2_471
        let boundaries = (0...(lastFrameIndex + 1)).map { index in
            let converted = CMTimeConvertScale(
                CMTime(
                    value: CMTimeValue(index * 1_001),
                    timescale: 24_000
                ),
                timescale: 90_000,
                method: .default
            )
            return CMTime(value: converted.value, timescale: 90_000)
        }
        let presentationTimes = Array(boundaries.dropLast())
        let decodedDurations = zip(boundaries, boundaries.dropFirst()).map {
            CMTimeSubtract($1, $0)
        }

        for index in [0, 60, 1_000, lastFrameIndex] {
            let exact = CMTimeConvertScale(
                CMTime(
                    value: CMTimeValue(index * 1_001),
                    timescale: 24_000
                ),
                timescale: 90_000,
                method: .default
            )
            XCTAssertEqual(presentationTimes[index].value, exact.value)
            XCTAssertEqual(presentationTimes[index].timescale, 90_000)
        }
        XCTAssertNotEqual(
            presentationTimes[lastFrameIndex].value,
            decodedDurations[0].value * CMTimeValue(lastFrameIndex),
            "The long-timing regression must diverge from repeated use of one quantized frame duration."
        )
        XCTAssertNoThrow(
            try DeterministicV4MediaProcessingSession
                .validateNominalDecodedCadence(
                    presentationTimes: presentationTimes,
                    decodedDurations: decodedDurations,
                    nominalSourceFrameDuration: nominal
                )
        )
    }

    func testNominalDecodedCadenceAcceptsFerris90kClockQuantization()
        throws {
        let presentationTimes = [
            CMTime(value: 0, timescale: 1_000),
            CMTime(value: 3_753, timescale: 90_000),
            CMTime(value: 7_507, timescale: 90_000)
        ]
        let unavailableDurations = Array(
            repeating: CMTime.invalid,
            count: presentationTimes.count
        )
        let nominal = try ExactRationalV4(1_001, 24_000)

        XCTAssertNoThrow(
            try DeterministicV4MediaProcessingSession
                .validateNominalDecodedCadence(
                    presentationTimes: presentationTimes,
                    decodedDurations: unavailableDurations,
                    nominalSourceFrameDuration: nominal
                )
        )

        var realGap = presentationTimes
        realGap[2] = CMTime(value: 11_260, timescale: 90_000)
        XCTAssertThrowsError(
            try DeterministicV4MediaProcessingSession
                .validateNominalDecodedCadence(
                    presentationTimes: realGap,
                    decodedDurations: unavailableDurations,
                    nominalSourceFrameDuration: nominal
                )
        ) {
            XCTAssertEqual(
                $0 as? DeterministicV4MediaSegmentError,
                .invalidSampleTiming(site: .nominalCadenceOffLattice)
            )
        }
    }

    func testPlannerUsesExactNTSCNominalInsteadOfMinimumClockTick()
        throws {
        let nominal = try DeterministicV4WholeAssetPlanner
            .nominalFrameDuration(
                nominalFrameRate: 23.976023,
                minimumFrameDuration: CMTime(
                    value: 3_753,
                    timescale: 90_000
                ),
                fallbackTimebase: ExactRationalV4(1, 90_000)
            )

        XCTAssertEqual(nominal, try ExactRationalV4(1_001, 24_000))
    }

    func testPlannerRecognizesShortNTSCTrackAverageRateOnDistinctClock()
        throws {
        for rate: Float in [23.976064682006836, 23.97601318359375] {
            for tick: Int64 in [3_753, 3_754] {
                XCTAssertEqual(
                    try DeterministicV4WholeAssetPlanner.nominalFrameDuration(
                        nominalFrameRate: rate,
                        minimumFrameDuration: CMTime(value: tick, timescale: 90_000),
                        fallbackTimebase: ExactRationalV4(1, 90_000)
                    ),
                    try ExactRationalV4(1_001, 24_000)
                )
            }
        }
    }

    func testPlannerDoesNotGuessNTSCFromAmbiguousOrContradictoryClock()
        throws {
        let cases: [(Float, CMTime)] = [
            (24, CMTime(value: 1, timescale: 24)),
            (24, CMTime(value: 3_750, timescale: 90_000)),
            (25, CMTime(value: 1, timescale: 25)),
            (30, CMTime(value: 1, timescale: 30)),
            (12, CMTime(value: 2, timescale: 24)),
            (Float(600.0 / 26.0), CMTime(value: 26, timescale: 600)),
            (Float(90_000.0 / 3_753.0), CMTime(value: 3_753, timescale: 90_000)),
            (Float(90_000.0 / 3_754.0), CMTime(value: 3_754, timescale: 90_000)),
            (23.976064682006836, CMTime(value: 25, timescale: 600)),
            (23.95, CMTime(value: 3_753, timescale: 90_000)),
            (23.976064682006836, CMTime(value: 3_755, timescale: 90_000))
        ]
        for (rate, minimum) in cases {
            XCTAssertEqual(
                try DeterministicV4WholeAssetPlanner.nominalFrameDuration(
                    nominalFrameRate: rate,
                    minimumFrameDuration: minimum,
                    fallbackTimebase: ExactRationalV4(1, 90_000)
                ),
                try ExactRationalV4(minimum.value, Int64(minimum.timescale))
            )
        }
        XCTAssertEqual(
            try DeterministicV4WholeAssetPlanner.nominalFrameDuration(
                nominalFrameRate: 23.976064682006836,
                minimumFrameDuration: nil,
                fallbackTimebase: ExactRationalV4(1, 90_000)
            ),
            try ExactRationalV4(
                1_000_000, Int64((Double(Float(23.976064682006836)) * 1_000_000).rounded())
            )
        )
    }

    func testShortNTSCMetadataRecognitionStillRejectsDecodedTimingGap()
        throws {
        let nominal = try DeterministicV4WholeAssetPlanner.nominalFrameDuration(
            nominalFrameRate: 23.976064682006836,
            minimumFrameDuration: CMTime(value: 3_753, timescale: 90_000),
            fallbackTimebase: ExactRationalV4(1, 90_000)
        )
        let valid = [0, 3_754, 7_508, 11_261].map {
            CMTime(value: Int64($0), timescale: 90_000)
        }
        let durations = Array(repeating: CMTime.invalid, count: valid.count)
        XCTAssertNoThrow(try DeterministicV4MediaProcessingSession.validateNominalDecodedCadence(
            presentationTimes: valid, decodedDurations: durations,
            nominalSourceFrameDuration: nominal
        ))
        var invalid = valid
        invalid[2] = CMTime(value: 7_510, timescale: 90_000)
        XCTAssertThrowsError(try DeterministicV4MediaProcessingSession.validateNominalDecodedCadence(
            presentationTimes: invalid, decodedDurations: durations,
            nominalSourceFrameDuration: nominal
        )) {
            XCTAssertEqual($0 as? DeterministicV4MediaSegmentError,
                .invalidSampleTiming(site: .nominalCadenceOffLattice))
        }
    }

    func testEncodedSegmentTimingAcceptsUniqueLegalClockQuantization()
        throws {
        let expected = try HDR10PlusPresentationTimeV4(
            CMTime(value: 1_001, timescale: 6_000)
        )
        var legal = Dictionary(uniqueKeysWithValues: [
            (expected, nil as HDR10PlusMetadataV4?)
        ])
        XCTAssertNil(try DeterministicV4MediaProcessingSession
            .removeExpectedHDR10PlusMetadata(
                for: CMTime(value: 100, timescale: 600),
                from: &legal
            ))
        XCTAssertTrue(legal.isEmpty)

        var gap = Dictionary(uniqueKeysWithValues: [
            (expected, nil as HDR10PlusMetadataV4?)
        ])
        XCTAssertThrowsError(try DeterministicV4MediaProcessingSession
            .removeExpectedHDR10PlusMetadata(
                for: CMTime(value: 102, timescale: 600),
                from: &gap
            ))
        XCTAssertEqual(gap.count, 1)
    }

    func testFerrisObserved90kRemainderAcceptsOnlyAdmittedAdjacentTick()
        throws {
        let processedEnd = CMTimeAdd(
            CMTime(value: 556_211_906, timescale: 90_000),
            CMTime(value: 1_001, timescale: 24_000)
        )
        let admittedEnd = CMTime(value: 556_215_660, timescale: 90_000)

        XCTAssertThrowsError(
            try DeterministicV4MediaProcessingSession.workflowTime(
                processedEnd,
                timescale: 90_000
            )
        ) {
            XCTAssertEqual(
                $0 as? DeterministicV4MediaSegmentError,
                .invalidSampleTiming(site: .cmTimeNotExactlyRepresentable)
            )
        }

        let terminal = try DeterministicV4MediaProcessingSession.workflowTime(
                exact: processedEnd,
                admittedBoundary: admittedEnd,
                timescale: 90_000
            )

        XCTAssertEqual(terminal.value, 556_215_660)
        XCTAssertEqual(terminal.timescale, 90_000)
    }

    func testFerrisFrame148175ReconstructsExactLastFrameStart()
        throws {
        let exactStart = try DeterministicV4MediaProcessingSession
            .nominalDecodedPresentationTime(
                plannedStart: .zero,
                nominalSourceFrameDuration:
                    ExactRationalV4(1_001, 24_000),
                frameIndex: 148_175
            )

        XCTAssertEqual(exactStart.value, 5_932_927)
        XCTAssertEqual(exactStart.timescale, 960)
        XCTAssertTrue(
            DeterministicV4MediaProcessingSession
                .isValidClockQuantization(
                    CMTime(value: 556_211_906, timescale: 90_000),
                    of: exactStart
                )
        )
    }

    func testAdmittedClockPolicyRejectsBoundaryTwoTicksAwayWithNewSiteID()
        throws {
        let processedEnd = CMTimeAdd(
            CMTime(value: 556_211_906, timescale: 90_000),
            CMTime(value: 1_001, timescale: 24_000)
        )
        let unrelatedEnd = CMTime(value: 556_215_662, timescale: 90_000)

        XCTAssertThrowsError(
            try DeterministicV4MediaProcessingSession
                .workflowTime(
                    exact: processedEnd,
                    admittedBoundary: unrelatedEnd,
                    timescale: 90_000
                )
        ) {
            XCTAssertEqual(
                $0 as? DeterministicV4MediaSegmentError,
                .invalidSampleTiming(
                    site: .exactRationalNotAdjacentToAdmittedClockBoundary
                )
            )
        }
    }

    func testExactTerminalBoundaryRemainsExactWithoutSnapping()
        throws {
        let decodedEnd = CMTime(value: 241, timescale: 24)

        let terminal = try DeterministicV4MediaProcessingSession
            .workflowTime(
                exact: decodedEnd,
                admittedBoundary: decodedEnd,
                timescale: 24
            )

        XCTAssertEqual(terminal.value, 241)
        XCTAssertEqual(terminal.timescale, 24)
    }

    func testMissingFinalNTSCFrameRejectsAdmittedAssetEndWithNewSiteID()
        throws {
        let nominal = try ExactRationalV4(1_001, 24_000)
        let missingFrameEnd = try nominal.multiplied(
            by: ExactRationalV4(148_175)
        )
        let missingFrameEndTime = CMTime(
            value: missingFrameEnd.numerator,
            timescale: Int32(missingFrameEnd.denominator)
        )
        let admittedAssetEnd = CMTime(
            value: 556_215_660,
            timescale: 90_000
        )

        XCTAssertThrowsError(
            try DeterministicV4MediaProcessingSession.workflowTime(
                exact: missingFrameEndTime,
                admittedBoundary: admittedAssetEnd,
                timescale: 90_000
            )
        ) {
            XCTAssertEqual(
                $0 as? DeterministicV4MediaSegmentError,
                .invalidSampleTiming(
                    site: .exactRationalNotAdjacentToAdmittedClockBoundary
                )
            )
        }
    }

    func testCanonicalDynamicAbsentDecodedCadenceDoesNotUseRoundedTrackEnd()
        throws {
        let nominal = try ExactRationalV4(1, 24)
        let presentationTimes = (0..<241).map {
            CMTime(value: CMTimeValue($0), timescale: 24)
        }
        let decodedDurations = Array(
            repeating: CMTime(value: 1, timescale: 24),
            count: presentationTimes.count
        )
        let decodedEnd = CMTime(value: 241, timescale: 24)
        let roundedContainerEnd = CMTime(value: 10_042, timescale: 1_000)
        XCTAssertNotEqual(CMTimeCompare(decodedEnd, roundedContainerEnd), 0)
        XCTAssertEqual(
            CMTimeCompare(
                CMTimeAdd(
                    try XCTUnwrap(presentationTimes.last),
                    try XCTUnwrap(decodedDurations.last)
                ),
                decodedEnd
            ),
            0
        )

        // Container track ranges are not inputs to decoded-cadence validation:
        // their terminal values may be rounded more coarsely than frame timing.
        XCTAssertNoThrow(
            try DeterministicV4MediaProcessingSession
                .validateNominalDecodedCadence(
                    presentationTimes: presentationTimes,
                    decodedDurations: decodedDurations,
                    nominalSourceFrameDuration: nominal
                )
        )
    }

    func testProcessSegmentSite057ExportsExactAndAdmittedClockContext()
        async throws {
        let directory = try TrackMigrationFixtureDirectoryV4()
        defer { directory.remove() }
        let sourceURL = directory.url("site057-diagnostic-source.mov")
        let destinationURL = directory.url("site057-diagnostic-output.mov")
        let segmentURL = directory.url("site057-diagnostic-segment.mov")
        let runtimeURL = directory.url("site057-diagnostic-p06.bundle")
        let admittedFrameDuration = CMTime(
            value: 3_750,
            timescale: 90_000
        )
        try await TrackMigrationFixtureFactoryV4.makeRichMovie(
            at: sourceURL,
            includeAudioGroup: false,
            videoFrameCount: 1,
            videoMediaTimeScale: 90_000,
            videoFrameDuration: admittedFrameDuration,
            videoExpectedFrameRate: 24
        )

        let sourceAsset = AVURLAsset(
            url: sourceURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let sourceVideos = try await sourceAsset.loadTracks(
            withMediaType: .video
        )
        let sourceVideo = try XCTUnwrap(sourceVideos.first)
        let admittedEnd = CMTimeRangeGetEnd(
            try await sourceVideo.load(.timeRange)
        )
        XCTAssertEqual(CMTimeCompare(admittedEnd, admittedFrameDuration), 0)

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
        let prepared = try await backend.prepare(
            request: BackendPreparationRequest(
                source: source,
                targetSize: CGSize(width: 96, height: 72)
            ),
            environment: .current()
        )
        let recording = TrackMigrationRecordingDeterministicBackendV4(
            planning: try XCTUnwrap(
                prepared as? any PreparedDeterministicV4PlanningBackend
            ),
            temporal: try XCTUnwrap(
                prepared as? any PreparedCheckpointableTemporalFrameUpscaler
            )
        )
        let request = UpscaleRequest(
            inputURL: sourceURL,
            outputURL: destinationURL,
            backendID: .mirmirDeterministicCPU,
            targetWidth: 96,
            targetHeight: 72,
            outputCodec: .h264,
            preserveAudio: true,
            overwriteExistingFile: false
        )
        let plan = try await DeterministicV4WholeAssetPlanner().prepare(
            request: request,
            source: source,
            backend: recording,
            cancellation: ProcessingCancellation()
        )
        let exactNominalPlan = DeterministicV4PreparedAssetPlan(
            canonicalMedia: plan.canonicalMedia,
            ashPlan: plan.ashPlan,
            sourceGraph: plan.sourceGraph,
            trackPlan: plan.trackPlan,
            migrationBlueprint: plan.migrationBlueprint,
            primaryCanonicalTrack: plan.primaryCanonicalTrack,
            primaryGraphTrack: plan.primaryGraphTrack,
            videoDelivery: plan.videoDelivery,
            encodedFormatDescriptor: plan.encodedFormatDescriptor,
            nominalSourceFrameDuration:
                try ExactRationalV4(1_001, 24_000),
            nonVideoTranscodeHooks: plan.nonVideoTranscodeHooks
        )
        let diagnosticStore = MirmirDiagnosticStore(
            inMemoryWith: .production
        )
        let diagnosticRecorder = MirmirDiagnosticRecorder(
            store: diagnosticStore
        )

        do {
            _ = try await MirmirDiagnosticScope.$recorder.withValue(
                diagnosticRecorder
            ) {
                try await DeterministicV4MediaProcessingSession()
                    .processSegment(
                        request: request,
                        source: source,
                        preparedPlan: exactNominalPlan,
                        preparedBackend: recording,
                        startingInputFrameIndex: 0,
                        startTime: try WorkflowMediaTimeV4(
                            value: 0,
                            timescale: 1
                        ),
                        maximumInputFrames: 2,
                        segmentURL: segmentURL,
                        cancellation: ProcessingCancellation(),
                        progress: { _ in }
                    )
            }
            XCTFail("The nonadjacent admitted boundary must fail at site 057.")
        } catch {
            XCTAssertEqual(
                error as? DeterministicV4MediaSegmentError,
                .invalidSampleTiming(
                    site: .exactRationalNotAdjacentToAdmittedClockBoundary
                )
            )
        }
        await plan.finishProcessingBackend(planningBackend: recording)

        let snapshot = try await diagnosticStore.snapshot()
        let failures = snapshot.records.filter {
            $0.event.operation.rawValue == "process_segment"
        }
        let failure = try XCTUnwrap(failures.first)
        XCTAssertEqual(failures.count, 1)
        let fields = Dictionary(uniqueKeysWithValues:
            failure.event.fields.map {
                ($0.key.rawValue, $0.value.displayValue)
            }
        )
        XCTAssertEqual(
            fields["timing_site_id"],
            DeterministicV4InvalidSampleTimingSite
                .exactRationalNotAdjacentToAdmittedClockBoundary.rawValue
        )
        XCTAssertEqual(fields["exact_boundary_value"], "1001")
        XCTAssertEqual(fields["exact_boundary_timescale"], "24000")
        XCTAssertEqual(
            fields["admitted_boundary_value"],
            String(admittedEnd.value)
        )
        XCTAssertEqual(
            fields["admitted_boundary_timescale"],
            String(admittedEnd.timescale)
        )
        XCTAssertEqual(fields["boundary_clock_timescale"], "90000")

        let json = String(
            decoding: try await diagnosticStore.exportJSON(),
            as: UTF8.self
        )
        let markdown = String(
            decoding: try await diagnosticStore.exportMarkdown(),
            as: UTF8.self
        )
        for expected in [
            "dv4_timing_057_exact_rational_not_adjacent_to_admitted_clock_boundary",
            "exact_boundary_value",
            "exact_boundary_timescale",
            "admitted_boundary_value",
            "admitted_boundary_timescale",
            "boundary_clock_timescale"
        ] {
            XCTAssertTrue(json.contains(expected))
            XCTAssertTrue(
                markdown.contains(
                    expected.replacingOccurrences(of: "_", with: "\\_")
                )
            )
        }
    }

    func testNTSC90kSegmentEmitsExactLastFrameStartBeforeBoundary()
        async throws {
        let directory = try TrackMigrationFixtureDirectoryV4()
        defer { directory.remove() }
        let sourceURL = directory.url("segmented-sdr-source.mov")
        let destinationURL = directory.url("segmented-sdr-output.mov")
        let segmentURL = directory.url("segmented-sdr-part.mov")
        let runtimeURL = directory.url("segmented-sdr-p06.bundle")
        let videoFrameCount = 37
        let processedFrameCount = 36
        let nominalFrameDuration = CMTime(
            value: 1_001,
            timescale: 24_000
        )
        try await TrackMigrationFixtureFactoryV4.makeRichMovie(
            at: sourceURL,
            includeAudioGroup: false,
            videoFrameCount: videoFrameCount,
            videoMediaTimeScale: 90_000,
            videoFrameDuration: nominalFrameDuration,
            videoExpectedFrameRate: 24_000.0 / 1_001.0
        )

        let asset = AVURLAsset(
            url: sourceURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let videoTrack = try XCTUnwrap(videoTracks.first)
        let durationReader = try AVAssetReader(asset: asset)
        let durationOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    Int(kCVPixelFormatType_32BGRA)
            ]
        )
        XCTAssertTrue(durationReader.canAdd(durationOutput))
        durationReader.add(durationOutput)
        XCTAssertTrue(durationReader.startReading())
        let decodedSample = try XCTUnwrap(
            durationOutput.copyNextSampleBuffer()
        )
        var fixturePresentationTimes = [
            CMSampleBufferGetPresentationTimeStamp(decodedSample)
        ]
        while let sample = durationOutput.copyNextSampleBuffer() {
            fixturePresentationTimes.append(
                CMSampleBufferGetPresentationTimeStamp(sample)
            )
        }
        let decodedDuration = CMSampleBufferGetDuration(decodedSample)
        XCTAssertFalse(
            decodedDuration.isNumeric && decodedDuration.value > 0,
            "The regression fixture must expose an unspecified decoded duration."
        )
        durationReader.cancelReading()
        XCTAssertEqual(fixturePresentationTimes.count, videoFrameCount)

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
        let prepared = try await backend.prepare(
            request: BackendPreparationRequest(
                source: source,
                targetSize: CGSize(width: 96, height: 72)
            ),
            environment: .current()
        )
        let recording = TrackMigrationRecordingDeterministicBackendV4(
            planning: try XCTUnwrap(
                prepared as? any PreparedDeterministicV4PlanningBackend
            ),
            temporal: try XCTUnwrap(
                prepared as? any PreparedCheckpointableTemporalFrameUpscaler
            )
        )
        let request = UpscaleRequest(
            inputURL: sourceURL,
            outputURL: destinationURL,
            backendID: .mirmirDeterministicCPU,
            targetWidth: 96,
            targetHeight: 72,
            outputCodec: .h264,
            preserveAudio: true,
            overwriteExistingFile: false
        )
        let plan = try await DeterministicV4WholeAssetPlanner().prepare(
            request: request,
            source: source,
            backend: recording,
            cancellation: ProcessingCancellation()
        )
        let exactNTSCPlan = DeterministicV4PreparedAssetPlan(
            canonicalMedia: plan.canonicalMedia,
            ashPlan: plan.ashPlan,
            sourceGraph: plan.sourceGraph,
            trackPlan: plan.trackPlan,
            migrationBlueprint: plan.migrationBlueprint,
            primaryCanonicalTrack: plan.primaryCanonicalTrack,
            primaryGraphTrack: plan.primaryGraphTrack,
            videoDelivery: plan.videoDelivery,
            encodedFormatDescriptor: plan.encodedFormatDescriptor,
            nominalSourceFrameDuration:
                try ExactRationalV4(1_001, 24_000),
            nonVideoTranscodeHooks: plan.nonVideoTranscodeHooks
        )
        XCTAssertEqual(
            exactNTSCPlan.nominalSourceFrameDuration,
            try ExactRationalV4(1_001, 24_000)
        )
        XCTAssertTrue(
            try XCTUnwrap(plan.primaryCanonicalTrack.video)
                .color.dynamicHDRMetadata.isEmpty
        )

        let result: DeterministicV4MediaSegmentResultV4
        do {
            result = try await DeterministicV4MediaProcessingSession()
                .processSegment(
                    request: request,
                    source: source,
                    preparedPlan: exactNTSCPlan,
                    preparedBackend: recording,
                    startingInputFrameIndex: 0,
                    startTime: try WorkflowMediaTimeV4(
                        value: 0,
                        timescale: 1
                    ),
                    maximumInputFrames: processedFrameCount,
                    segmentURL: segmentURL,
                    cancellation: ProcessingCancellation(),
                    progress: { _ in },
                    timelineMapping: nil,
                    progressPresentationOffset: .zero
                )
        } catch {
            await plan.finishProcessingBackend(planningBackend: recording)
            throw error
        }
        await plan.finishProcessingBackend(planningBackend: recording)

        XCTAssertFalse(result.terminal)
        XCTAssertNotNil(result.nextStartTime)
        XCTAssertEqual(
            result.inputSampleCount,
            processedFrameCount
        )
        XCTAssertEqual(
            result.outputSampleCount,
            processedFrameCount
        )
        let outputLedger = try XCTUnwrap(result.hdr10PlusOutputLedger)
        XCTAssertEqual(
            outputLedger.records.count,
            processedFrameCount
        )
        XCTAssertTrue(outputLedger.records.allSatisfy { $0.metadata == nil })
        let observations = await recording.recordedObservations()
        XCTAssertEqual(
            observations.map(\.duration),
            Array(repeating: nominalFrameDuration, count: processedFrameCount),
            "Unavailable decoded durations must use exact nominal cadence."
        )
        XCTAssertEqual(
            observations.last?.presentationTime,
            CMTime(value: 35_035, timescale: 24_000),
            "The final decoded frame must use its exact 1001/24000 lattice start."
        )
        XCTAssertEqual(result.endTimeExclusive.value, 135_135)
        XCTAssertEqual(result.endTimeExclusive.timescale, 90_000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: segmentURL.path))
    }

    func testNTSC90kNonterminalLookaheadUsesSharedBoundaryPolicy()
        async throws {
        let directory = try TrackMigrationFixtureDirectoryV4()
        defer { directory.remove() }
        let sourceURL = directory.url("segmented-sdr-source.mov")
        let destinationURL = directory.url("segmented-sdr-output.mov")
        let firstSegmentURL = directory.url("segmented-sdr-part-0.mov")
        let runtimeURL = directory.url("segmented-sdr-p06.bundle")
        let videoFrameCount = 61
        let nominalFrameDuration = CMTime(
            value: 1_001,
            timescale: 24_000
        )
        try await TrackMigrationFixtureFactoryV4.makeRichMovie(
            at: sourceURL,
            includeAudioGroup: false,
            videoFrameCount: videoFrameCount,
            videoMediaTimeScale: 90_000,
            videoFrameDuration: nominalFrameDuration,
            videoExpectedFrameRate: 24_000.0 / 1_001.0
        )

        let asset = AVURLAsset(
            url: sourceURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let videoTrack = try XCTUnwrap(videoTracks.first)
        let durationReader = try AVAssetReader(asset: asset)
        let durationOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    Int(kCVPixelFormatType_32BGRA)
            ]
        )
        XCTAssertTrue(durationReader.canAdd(durationOutput))
        durationReader.add(durationOutput)
        XCTAssertTrue(durationReader.startReading())
        let decodedSample = try XCTUnwrap(
            durationOutput.copyNextSampleBuffer()
        )
        let decodedDuration = CMSampleBufferGetDuration(decodedSample)
        XCTAssertFalse(
            decodedDuration.isNumeric && decodedDuration.value > 0,
            "The regression fixture must expose an unspecified decoded duration."
        )
        durationReader.cancelReading()

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
        let prepared = try await backend.prepare(
            request: BackendPreparationRequest(
                source: source,
                targetSize: CGSize(width: 96, height: 72)
            ),
            environment: .current()
        )
        let recording = TrackMigrationRecordingDeterministicBackendV4(
            planning: try XCTUnwrap(
                prepared as? any PreparedDeterministicV4PlanningBackend
            ),
            temporal: try XCTUnwrap(
                prepared as? any PreparedCheckpointableTemporalFrameUpscaler
            )
        )
        let request = UpscaleRequest(
            inputURL: sourceURL,
            outputURL: destinationURL,
            backendID: .mirmirDeterministicCPU,
            targetWidth: 96,
            targetHeight: 72,
            outputCodec: .h264,
            preserveAudio: true,
            overwriteExistingFile: false
        )
        let plan = try await DeterministicV4WholeAssetPlanner().prepare(
            request: request,
            source: source,
            backend: recording,
            cancellation: ProcessingCancellation()
        )
        let exactNTSCPlan = DeterministicV4PreparedAssetPlan(
            canonicalMedia: plan.canonicalMedia,
            ashPlan: plan.ashPlan,
            sourceGraph: plan.sourceGraph,
            trackPlan: plan.trackPlan,
            migrationBlueprint: plan.migrationBlueprint,
            primaryCanonicalTrack: plan.primaryCanonicalTrack,
            primaryGraphTrack: plan.primaryGraphTrack,
            videoDelivery: plan.videoDelivery,
            encodedFormatDescriptor: plan.encodedFormatDescriptor,
            nominalSourceFrameDuration:
                try ExactRationalV4(1_001, 24_000),
            nonVideoTranscodeHooks: plan.nonVideoTranscodeHooks
        )
        XCTAssertEqual(
            exactNTSCPlan.nominalSourceFrameDuration,
            try ExactRationalV4(1_001, 24_000)
        )
        XCTAssertTrue(
            try XCTUnwrap(plan.primaryCanonicalTrack.video)
                .color.dynamicHDRMetadata.isEmpty
        )

        let initialStart = try WorkflowMediaTimeV4(
            value: 0,
            timescale: 1
        )
        let firstResult: DeterministicV4MediaSegmentResultV4
        do {
            let session = DeterministicV4MediaProcessingSession()
            firstResult = try await session
                .processSegment(
                    request: request,
                    source: source,
                    preparedPlan: exactNTSCPlan,
                    preparedBackend: recording,
                    startingInputFrameIndex: 0,
                    startTime: initialStart,
                    maximumInputFrames: 60,
                    segmentURL: firstSegmentURL,
                    cancellation: ProcessingCancellation(),
                    progress: { _ in },
                    timelineMapping: nil,
                    progressPresentationOffset: .zero
                )
        } catch {
            await plan.finishProcessingBackend(planningBackend: recording)
            throw error
        }
        await plan.finishProcessingBackend(planningBackend: recording)

        XCTAssertFalse(firstResult.terminal)
        XCTAssertNotNil(firstResult.nextStartTime)
        XCTAssertEqual(
            Optional(firstResult.endTimeExclusive),
            firstResult.nextStartTime
        )
        XCTAssertEqual(firstResult.inputSampleCount, 60)
        XCTAssertEqual(firstResult.outputSampleCount, 60)
        XCTAssertEqual(firstResult.nextStartTime?.value, 225_225)
        XCTAssertEqual(firstResult.nextStartTime?.timescale, 90_000)
        let outputLedger = try XCTUnwrap(firstResult.hdr10PlusOutputLedger)
        XCTAssertEqual(
            outputLedger.records.count,
            60
        )
        XCTAssertTrue(outputLedger.records.allSatisfy { $0.metadata == nil })
        let observations = await recording.recordedObservations()
        XCTAssertEqual(
            observations.map(\.duration),
            Array(
                repeating: nominalFrameDuration,
                count: 60
            ),
            "Exact compressed timing must remain continuous across the durable boundary."
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: firstSegmentURL.path
        ))
        let firstSegmentAsset = AVURLAsset(
            url: firstSegmentURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let firstSegmentVideoTracks = try await firstSegmentAsset.loadTracks(
            withMediaType: .video
        )
        let firstSegmentVideo = try XCTUnwrap(firstSegmentVideoTracks.first)
        let firstSegmentTimeScale = try await firstSegmentVideo.load(
            .naturalTimeScale
        )
        XCTAssertEqual(
            firstSegmentTimeScale,
            90_000,
            "The production segment writer must retain the source boundary clock."
        )
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
        let sourceAudioTracks = try await sourceAsset.loadTracks(
            withMediaType: .audio
        )
        XCTAssertEqual(sourceAudioTracks.count, 2)
        let sourceAudioTrackIDs = Set(sourceAudioTracks.map(\.trackID))
        let sourceGraph = try await AVFoundationTrackGraphAdapterV4.probe(
            asset: sourceAsset
        )
        let graphAudio = sourceGraph.tracks.filter { $0.kind == .audio }
        XCTAssertEqual(graphAudio.count, sourceAudioTracks.count)
        XCTAssertTrue(graphAudio.allSatisfy {
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
        let request = UpscaleRequest(
            inputURL: sourceURL,
            outputURL: destinationURL,
            backendID: .mirmirDeterministicCPU,
            targetWidth: 96,
            targetHeight: 72,
            outputCodec: .h264,
            preserveAudio: true,
            overwriteExistingFile: false
        )
        let planningPreparedBackend = try await backend.prepare(
            request: BackendPreparationRequest(
                source: source,
                targetSize: CGSize(width: 96, height: 72)
            ),
            environment: .current()
        )
        let planningBackend = try XCTUnwrap(
            planningPreparedBackend
                as? any PreparedDeterministicV4RuntimePlanningBackend
        )
        let preparedPlan = try await DeterministicV4WholeAssetPlanner()
            .prepare(
                request: request,
                source: source,
                backend: planningBackend,
                cancellation: ProcessingCancellation()
            )
        let plannedAudio = preparedPlan.trackPlan.plan.tracks.filter {
            $0.source.kind == .audio
        }
        XCTAssertEqual(
            Set(plannedAudio.compactMap(\.source.identity.containerTrackID)),
            sourceAudioTrackIDs
        )
        XCTAssertEqual(plannedAudio.count, sourceAudioTracks.count)
        XCTAssertTrue(plannedAudio.allSatisfy {
            $0.action != .dropWithConsent
                && $0.dropConsent == nil
                && $0.expectedOutput != nil
        })
        await preparedPlan.finishProcessingBackend(
            planningBackend: planningBackend
        )

        let preparedBackend = try await backend.prepare(
            request: BackendPreparationRequest(
                source: source,
                targetSize: CGSize(width: 96, height: 72)
            ),
            environment: .current()
        )
        let result = try await VideoProcessingSession().process(
            request: request,
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

    func testDurableWorkflowTranscodesIncompatibleAlternateAudioAndReportsIt()
        async throws {
        try await assertDurableWorkflowAudio(
            incompatibleAudioTransition: true,
            preserveAudio: true,
            expectedAudioResult: .transcoded
        )
    }

    func testDurableWorkflowPreservesCompatibleAlternateAudioAndReportsIt()
        async throws {
        try await assertDurableWorkflowAudio(
            incompatibleAudioTransition: false,
            preserveAudio: true,
            expectedAudioResult: .preserved
        )
    }

    func testDurableWorkflowOmitsIncompatibleAudioOnlyWhenRequested()
        async throws {
        try await assertDurableWorkflowAudio(
            incompatibleAudioTransition: true,
            preserveAudio: false,
            expectedAudioResult: .omitted
        )
    }

    private func assertDurableWorkflowAudio(
        incompatibleAudioTransition: Bool,
        preserveAudio: Bool,
        expectedAudioResult: AudioOutputResult
    ) async throws {
        let directory = try TrackMigrationFixtureDirectoryV4()
        defer { directory.remove() }
        let sourceURL = directory.url("durable-multiformat-source.mov")
        let destinationURL = directory.url("durable-multiformat-output.mov")
        try await TrackMigrationFixtureFactoryV4.makeRichMovie(
            at: sourceURL,
            includeAudioGroup: true,
            incompatibleAudioTransition: incompatibleAudioTransition
        )
        let sourceGraph = try await AVFoundationTrackGraphAdapterV4.probe(
            asset: AVURLAsset(url: sourceURL)
        )
        let sourceAudio = sourceGraph.tracks.filter { $0.kind == .audio }
        XCTAssertEqual(sourceAudio.count, 2)
        XCTAssertTrue(sourceAudio.allSatisfy {
            $0.formatDescriptors.count
                == (incompatibleAudioTransition ? 2 : 1)
        })
        let queue = try WorkflowApplicationQueueV4(
            trustedRootURL: directory.url("durable-store"),
            workerID: WorkflowWorkerIDV4("durable-audio-transcode-test"),
            resolver: TrackMigrationWorkflowBookmarkResolverV4()
        )
        let coordinator = WorkflowApplicationCoordinatorV4(
            queue: queue,
            engine: WorkflowDeterministicApplicationEngineV4(
                videoProbe: VideoProbe(),
                backendCatalog: .live(),
                runtimeEnvironment: .current()
            ),
            maximumInputFramesPerBoundary: 4
        )
        let outcome = try await coordinator.submit(
            request: UpscaleRequest(
                inputURL: sourceURL,
                outputURL: destinationURL,
                backendID: .mirmirDeterministicCPU,
                targetWidth: 96,
                targetHeight: 72,
                outputCodec: .h264,
                preserveAudio: preserveAudio,
                overwriteExistingFile: false
            ),
            progress: { _ in },
            snapshot: { _ in }
        )
        guard case .completed(let completion) = outcome else {
            return XCTFail("The durable audio-transcode job did not complete.")
        }
        XCTAssertEqual(completion.result.audioResult, expectedAudioResult)
        let outputGraph = try await AVFoundationTrackGraphAdapterV4.probe(
            asset: AVURLAsset(url: destinationURL)
        )
        let outputAudio = outputGraph.tracks.filter { $0.kind == .audio }
        if preserveAudio {
            XCTAssertEqual(outputAudio.count, sourceAudio.count)
            XCTAssertTrue(outputAudio.allSatisfy {
                $0.formatDescriptors.count == 1
                    && $0.formatDescriptors[0].mediaSubtypeID
                        == (incompatibleAudioTransition
                            ? "fourcc_61616320" : "fourcc_6c70636d")
            })
            XCTAssertEqual(outputGraph.groups, sourceGraph.groups)
        } else {
            XCTAssertTrue(outputAudio.isEmpty)
        }
        let snapshot = try await queue.queueSnapshot()
        XCTAssertEqual(snapshot.items.count, 1)
        XCTAssertTrue(snapshot.items.allSatisfy { $0.lifecycle == .completed })
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

        let directoryAliasURL = directory.url("destination-directory-alias")
        try FileManager.default.createSymbolicLink(
            at: directoryAliasURL,
            withDestinationURL: directory.rootURL
        )
        let aliasedTemporaryURL = directoryAliasURL.appendingPathComponent(
            ".mirmir-migration-aliased.partial.mov",
            isDirectory: false
        )
        let aliasedDestinationURL = directory.url("aliased-temp-output.mov")
        let aliasedResult = try await AVFoundationTrackMigrationExecutorV4()
            .execute(
                .init(
                    sourceURL: sourceURL,
                    destinationURL: aliasedDestinationURL,
                    temporaryURL: aliasedTemporaryURL,
                    sourceGraph: source,
                    identifiedPlan: plan,
                    blueprint: blueprint
                )
            )
        XCTAssertEqual(aliasedResult.destinationURL, aliasedDestinationURL)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: aliasedDestinationURL.path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: aliasedTemporaryURL.path
        ))

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

        let outsideDirectory = try TrackMigrationFixtureDirectoryV4()
        defer { outsideDirectory.remove() }
        await XCTAssertThrowsErrorAsyncV4(
            try await AVFoundationTrackMigrationExecutorV4().execute(
                .init(
                    sourceURL: sourceURL,
                    destinationURL: directory.url(
                        "different-directory-output.mov"
                    ),
                    temporaryURL: outsideDirectory.url(
                        ".mirmir-migration-outside.partial.mov"
                    ),
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

    func testConventionalSessionPreservesAlternateAudioGroup() async throws {
        let directory = try TrackMigrationFixtureDirectoryV4()
        defer { directory.remove() }
        let sourceURL = directory.url("conventional-group-source.mov")
        let destinationURL = directory.url("conventional-group-output.mov")
        try await TrackMigrationFixtureFactoryV4.makeRichMovie(
            at: sourceURL,
            includeAudioGroup: true
        )
        let source = try await VideoProbe().probe(url: sourceURL)
        XCTAssertEqual(source.audioTrackCount, 2)

        let result = try await UpscaleCoordinator().process(
            UpscaleRequest(
                inputURL: sourceURL,
                outputURL: destinationURL,
                backendID: .vImageHighQuality,
                targetWidth: 96,
                targetHeight: 72,
                outputCodec: .h264,
                preserveAudio: true,
                overwriteExistingFile: false
            ),
            progress: { _ in }
        )
        XCTAssertTrue([.preserved, .transcoded].contains(result.audioResult))

        let outputAsset = AVURLAsset(
            url: destinationURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let outputAudioTracks = try await outputAsset.loadTracks(
            withMediaType: .audio
        )
        XCTAssertEqual(outputAudioTracks.count, 2)
        let outputAudioIDs = Set(outputAudioTracks.map(\.trackID))
        let outputAudioGroups = try await outputAsset.load(.trackGroups)
            .filter { group in
                let memberIDs = Set(group.trackIDs.map(\.int32Value))
                return memberIDs.count > 1
                    && memberIDs.isSubset(of: outputAudioIDs)
            }
        XCTAssertEqual(outputAudioGroups.count, 1)
        XCTAssertEqual(outputAudioGroups.first?.trackIDs.count, 2)
        var enabledCount = 0
        for track in outputAudioTracks where try await track.load(.isEnabled) {
            enabledCount += 1
        }
        XCTAssertEqual(enabledCount, 1)
    }

    func testConventionalSessionPreservesSingletonAudioGroupAndDefaultSelection()
        async throws {
        let directory = try TrackMigrationFixtureDirectoryV4()
        defer { directory.remove() }
        let sourceURL = directory.url("conventional-singleton-source.mov")
        let destinationURL = directory.url(
            "conventional-singleton-output.mov"
        )
        try await TrackMigrationFixtureFactoryV4
            .makeSingletonAudioGroupMovie(at: sourceURL)

        let sourceAsset = AVURLAsset(url: sourceURL)
        let sourceAudioTracks = try await sourceAsset.loadTracks(
            withMediaType: .audio
        )
        XCTAssertEqual(sourceAudioTracks.count, 1)
        let sourceAudio = try XCTUnwrap(sourceAudioTracks.first)
        let sourceGroups = try await sourceAsset.load(.trackGroups).filter {
            $0.trackIDs.map(\.int32Value).contains(sourceAudio.trackID)
        }
        XCTAssertEqual(sourceGroups.count, 1)
        XCTAssertEqual(
            sourceGroups.first?.trackIDs.map(\.int32Value),
            [sourceAudio.trackID]
        )
        let sourceAudioEnabled = try await sourceAudio.load(.isEnabled)
        XCTAssertTrue(sourceAudioEnabled)
        let loadedSourceSelection = try await sourceAsset
            .loadMediaSelectionGroup(for: .audible)
        let sourceSelection = try XCTUnwrap(loadedSourceSelection)
        XCTAssertEqual(sourceSelection.options.count, 1)
        XCTAssertNotNil(sourceSelection.defaultOption)

        let result = try await UpscaleCoordinator().process(
            UpscaleRequest(
                inputURL: sourceURL,
                outputURL: destinationURL,
                backendID: .vImageStandard,
                targetWidth: 96,
                targetHeight: 72,
                outputCodec: .h264,
                preserveAudio: true,
                overwriteExistingFile: false
            ),
            progress: { _ in }
        )
        XCTAssertTrue([.preserved, .transcoded].contains(result.audioResult))

        let outputAsset = AVURLAsset(url: destinationURL)
        let outputAudioTracks = try await outputAsset.loadTracks(
            withMediaType: .audio
        )
        XCTAssertEqual(outputAudioTracks.count, 1)
        let outputAudio = try XCTUnwrap(outputAudioTracks.first)
        let outputGroups = try await outputAsset.load(.trackGroups).filter {
            $0.trackIDs.map(\.int32Value).contains(outputAudio.trackID)
        }
        XCTAssertEqual(outputGroups.count, 1)
        XCTAssertEqual(
            outputGroups.first?.trackIDs.map(\.int32Value),
            [outputAudio.trackID]
        )
        let outputAudioEnabled = try await outputAudio.load(.isEnabled)
        XCTAssertTrue(outputAudioEnabled)
        let loadedOutputSelection = try await outputAsset
            .loadMediaSelectionGroup(for: .audible)
        let outputSelection = try XCTUnwrap(loadedOutputSelection)
        XCTAssertEqual(
            outputSelection.options.count,
            sourceSelection.options.count
        )
        XCTAssertEqual(
            outputSelection.defaultOption != nil,
            sourceSelection.defaultOption != nil
        )
        XCTAssertEqual(
            outputSelection.allowsEmptySelection,
            sourceSelection.allowsEmptySelection
        )

        let sourceGraph = try await AVFoundationTrackGraphAdapterV4.probe(
            asset: sourceAsset
        )
        let outputGraph = try await AVFoundationTrackGraphAdapterV4.probe(
            asset: outputAsset
        )
        XCTAssertEqual(
            AudioTopologyV4(graph: outputGraph, preservingAudio: true),
            AudioTopologyV4(graph: sourceGraph, preservingAudio: true)
        )
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

    func testAVIMissingLanguageRemainsUndeterminedInMovieContainer() async throws {
        let sourceURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "legacy-mjpeg", withExtension: "avi"))
        let directory = try TrackMigrationFixtureDirectoryV4()
        defer { directory.remove() }
        let destinationURL = directory.url("avi-rewrapped.mov")
        let source = try await AVFoundationTrackGraphAdapterV4.probe(asset: AVURLAsset(url: sourceURL))
        XCTAssertTrue(source.tracks.allSatisfy { $0.language.languageCode == nil && $0.language.extendedLanguageTag == nil })
        let plan = try MediaTrackGraphPlannerV4.makePlan(source: source)
        let result = try await AVFoundationTrackMigrationExecutorV4().execute(.init(
            sourceURL: sourceURL, destinationURL: destinationURL,
            sourceGraph: source, identifiedPlan: plan,
            blueprint: try AVFoundationTrackMigrationPlannerV4.makeBlueprint(source: source, plan: plan)
        ))
        XCTAssertTrue(result.verificationReport.isConformant)
        XCTAssertEqual(result.outputGraph.tracks.map(\.language), source.tracks.map(\.language))
        let reopened = try await AVURLAsset(url: destinationURL).load(.tracks)
        XCTAssertEqual(reopened.count, source.tracks.count)
        for track in reopened {
            let code = try await track.load(.languageCode)
            let extended = try await track.load(.extendedLanguageTag)
            XCTAssertEqual(code, "und")
            XCTAssertNil(extended)
        }
        let originalVideo = try await AVURLAsset(url: sourceURL).loadTracks(withMediaType: .video)
        let writtenVideo = reopened.filter { $0.mediaType == .video }
        let before = try await XCTUnwrap(originalVideo.first).load(.formatDescriptions)[0]
        let after = try await XCTUnwrap(writtenVideo.first).load(.formatDescriptions)[0]
        let expected = try AVFoundationTrackGraphAdapterV4.canonicalSampleStreamFormatDescriptor(before)
        XCTAssertEqual(expected, try AVFoundationTrackGraphAdapterV4.canonicalSampleStreamFormatDescriptor(after))
        let extensions = try XCTUnwrap(CMFormatDescriptionGetExtensions(after) as NSDictionary?)
        for mutation in 0..<3 {
            let changed = NSMutableDictionary(dictionary: extensions)
            switch mutation {
            case 0:
                var raw = try XCTUnwrap(changed["VerbatimSampleDescription"] as? Data)
                raw[20] ^= 1 // an unrecognized vendor header must remain bound
                changed["VerbatimSampleDescription"] = raw
            case 1: changed["CVFieldCount"] = 2
            default: changed["UnrecognizedVideoMetadata"] = "must remain bound"
            }
            var description: CMVideoFormatDescription?
            XCTAssertEqual(CMVideoFormatDescriptionCreate(
                allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_JPEG_OpenDML,
                width: 160, height: 96, extensions: changed,
                formatDescriptionOut: &description
            ), noErr)
            XCTAssertNotEqual(expected, try AVFoundationTrackGraphAdapterV4.canonicalSampleStreamFormatDescriptor(XCTUnwrap(description)))
        }
    }

    func testLegacyPCMSampleEntrySurvivesNativeMovieRewrapping() async throws {
        let sourceURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "legacy-mjpeg", withExtension: "mov"))
        let directory = try TrackMigrationFixtureDirectoryV4()
        defer { directory.remove() }
        let destinationURL = directory.url("legacy-pcm-rewrapped.mov")
        let source = try await AVFoundationTrackGraphAdapterV4.probe(asset: AVURLAsset(url: sourceURL))
        let plan = try MediaTrackGraphPlannerV4.makePlan(source: source)
        let result = try await AVFoundationTrackMigrationExecutorV4().execute(.init(
            sourceURL: sourceURL, destinationURL: destinationURL,
            sourceGraph: source, identifiedPlan: plan,
            blueprint: try AVFoundationTrackMigrationPlannerV4.makeBlueprint(source: source, plan: plan)
        ))
        XCTAssertTrue(result.verificationReport.isConformant)
        XCTAssertTrue(result.trackResults.allSatisfy {
            $0.sourceSampleStreamSHA256 != nil
                && $0.sourceSampleStreamSHA256 == $0.outputSampleStreamSHA256
        })
        let sourceTracks = try await AVURLAsset(url: sourceURL).loadTracks(withMediaType: .audio)
        let outputTracks = try await AVURLAsset(url: destinationURL).loadTracks(withMediaType: .audio)
        let before = try await XCTUnwrap(sourceTracks.first).load(.formatDescriptions)[0]
        let after = try await XCTUnwrap(outputTracks.first).load(.formatDescriptions)[0]
        XCTAssertNotEqual(
            try AVFoundationTrackGraphAdapterV4.canonicalFormatDescriptor(before),
            try AVFoundationTrackGraphAdapterV4.canonicalFormatDescriptor(after)
        )
        let expected = try AVFoundationTrackGraphAdapterV4.canonicalSampleStreamFormatDescriptor(before)
        XCTAssertEqual(expected, try AVFoundationTrackGraphAdapterV4.canonicalSampleStreamFormatDescriptor(after))
        let extensions = try XCTUnwrap(CMFormatDescriptionGetExtensions(before) as NSDictionary?)
        let originalASBD = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(before)).pointee
        for mutation in 0..<4 {
            var asbd = originalASBD
            let changed = NSMutableDictionary(dictionary: extensions)
            switch mutation {
            case 0: asbd.mSampleRate = 44_100
            case 1: asbd.mFormatFlags ^= kAudioFormatFlagIsBigEndian
            case 2: changed["UnrecognizedAudioMetadata"] = "must remain bound"
            default:
                var raw = try XCTUnwrap(changed["VerbatimSampleDescription"] as? Data)
                raw[40] ^= 1 // unknown child atom must never be discarded
                changed["VerbatimSampleDescription"] = raw
            }
            var format: CMAudioFormatDescription?
            XCTAssertEqual(CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault, asbd: &asbd,
                layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
                extensions: changed, formatDescriptionOut: &format
            ), noErr)
            XCTAssertNotEqual(expected, try AVFoundationTrackGraphAdapterV4.canonicalSampleStreamFormatDescriptor(XCTUnwrap(format)))
        }
    }

    func testAC3SampleStreamFormatNormalizesContainerWrappersWithoutChangingGraphIdentity()
        throws {
        let cookie = Data([0, 0, 0, 11, 0x64, 0x61, 0x63, 0x33, 0x10, 0x12, 0x40])
        let iso = try sampleStreamAC3QualificationFormat(
            cookie: cookie, usesISOWrapper: true
        )
        let movie = try sampleStreamAC3QualificationFormat(
            cookie: cookie, usesISOWrapper: false
        )

        XCTAssertNotEqual(
            try AVFoundationTrackGraphAdapterV4.canonicalFormatDescriptor(iso),
            try AVFoundationTrackGraphAdapterV4.canonicalFormatDescriptor(movie)
        )
        XCTAssertEqual(
            try AVFoundationTrackGraphAdapterV4.canonicalSampleStreamFormatDescriptor(iso),
            try AVFoundationTrackGraphAdapterV4.canonicalSampleStreamFormatDescriptor(movie)
        )
        XCTAssertEqual(
            try AVFoundationTrackGraphAdapterV4.canonicalSampleStreamFormatDescriptor(
                iso, ordinal: 7
            ).ordinal,
            7
        )
        let timing = CMSampleTimingInfo(
            duration: CMTime(value: 1_536, timescale: 48_000),
            presentationTimeStamp: .zero,
            decodeTimeStamp: .zero
        )
        var sourceStream = SampleStreamAccumulatorV4()
        var outputStream = SampleStreamAccumulatorV4()
        try sourceStream.append(sampleStreamQualificationBuffer(
            payloads: [Data([1, 2, 3, 4])], start: .zero,
            duration: timing.duration, timings: [timing],
            formatDescription: iso
        ))
        try outputStream.append(sampleStreamQualificationBuffer(
            payloads: [Data([1, 2, 3, 4])], start: .zero,
            duration: timing.duration, timings: [timing],
            formatDescription: movie
        ))
        XCTAssertEqual(sourceStream.digest, outputStream.digest)
    }

    func testAC3SampleStreamFormatBindsCodecConfigurationAudioDescriptionAndOtherExtensions()
        throws {
        let cookie = Data([0, 0, 0, 11, 0x64, 0x61, 0x63, 0x33, 0x10, 0x12, 0x40])
        let original = try AVFoundationTrackGraphAdapterV4
            .canonicalSampleStreamFormatDescriptor(
                sampleStreamAC3QualificationFormat(
                    cookie: cookie, usesISOWrapper: true,
                    otherExtension: "original"
                )
            )
        var changedCookie = cookie
        changedCookie[9] ^= 0x08
        let changes = try [
            sampleStreamAC3QualificationFormat(
                cookie: changedCookie, usesISOWrapper: false,
                otherExtension: "original"
            ),
            sampleStreamAC3QualificationFormat(
                cookie: cookie, usesISOWrapper: false,
                sampleRate: 44_100, otherExtension: "original"
            ),
            sampleStreamAC3QualificationFormat(
                cookie: cookie, usesISOWrapper: false,
                channels: 6, otherExtension: "original"
            ),
            sampleStreamAC3QualificationFormat(
                cookie: cookie, usesISOWrapper: false,
                otherExtension: "changed"
            )
        ]
        for change in changes {
            XCTAssertNotEqual(
                original,
                try AVFoundationTrackGraphAdapterV4
                    .canonicalSampleStreamFormatDescriptor(change)
            )
        }
    }

    func testAC3SampleStreamFormatKeepsWrappersForMissingMalformedAndUnknownCookies()
        throws {
        let cookie = Data([0, 0, 0, 11, 0x64, 0x61, 0x63, 0x33, 0x10, 0x12, 0x40])
        var wrongSize = cookie
        wrongSize[3] = 12
        var unknownType = cookie
        unknownType[5] = 0x65
        let rejectedCookies = [
            Data(), Data(cookie.dropLast()), cookie + Data([0]),
            wrongSize, unknownType
        ]
        for rejected in rejectedCookies {
            let iso = try sampleStreamAC3QualificationFormat(
                cookie: rejected, usesISOWrapper: true
            )
            let movie = try sampleStreamAC3QualificationFormat(
                cookie: rejected, usesISOWrapper: false
            )
            XCTAssertEqual(
                try AVFoundationTrackGraphAdapterV4.canonicalSampleStreamFormatDescriptor(iso),
                try AVFoundationTrackGraphAdapterV4.canonicalFormatDescriptor(iso)
            )
            XCTAssertNotEqual(
                try AVFoundationTrackGraphAdapterV4.canonicalSampleStreamFormatDescriptor(iso),
                try AVFoundationTrackGraphAdapterV4.canonicalSampleStreamFormatDescriptor(movie)
            )
        }
        let otherCodecISO = try sampleStreamAC3QualificationFormat(
            cookie: cookie, usesISOWrapper: true,
            formatID: kAudioFormatEnhancedAC3
        )
        let otherCodecMovie = try sampleStreamAC3QualificationFormat(
            cookie: cookie, usesISOWrapper: false,
            formatID: kAudioFormatEnhancedAC3
        )
        XCTAssertNotEqual(
            try AVFoundationTrackGraphAdapterV4.canonicalSampleStreamFormatDescriptor(otherCodecISO),
            try AVFoundationTrackGraphAdapterV4.canonicalSampleStreamFormatDescriptor(otherCodecMovie)
        )
    }

    func testAC3PassThroughOutputFormatProofRetainsInventoryAndObservedDescriptorChecks()
        throws {
        let cookie = Data([0, 0, 0, 11, 0x64, 0x61, 0x63, 0x33, 0x10, 0x12, 0x40])
        let source = try [
            sampleStreamAC3QualificationFormat(cookie: cookie, usesISOWrapper: true),
            sampleStreamAC3QualificationFormat(
                cookie: cookie, usesISOWrapper: true, channels: 6
            )
        ]
        let output = try [
            sampleStreamAC3QualificationFormat(cookie: cookie, usesISOWrapper: false),
            sampleStreamAC3QualificationFormat(
                cookie: cookie, usesISOWrapper: false, channels: 6
            )
        ]
        func observed(_ formats: [CMFormatDescription]) throws
            -> [MediaTrackFormatDescriptorV4] {
            try formats.enumerated().map {
                try AVFoundationTrackGraphAdapterV4.canonicalFormatDescriptor(
                    $0.element, ordinal: UInt32($0.offset)
                )
            }
        }
        XCTAssertTrue(try AVFoundationTrackMigrationExecutorV4
            .passThroughOutputFormatsMatchForQualification(
                source: source, output: output, observed: observed(output)
            ))
        for changedOutput in [[], [output[0]], [output[0], output[1], output[0]],
                              [output[1], output[0]]] {
            XCTAssertFalse(try AVFoundationTrackMigrationExecutorV4
                .passThroughOutputFormatsMatchForQualification(
                    source: source, output: changedOutput,
                    observed: observed(changedOutput)
                ))
        }
        XCTAssertFalse(try AVFoundationTrackMigrationExecutorV4
            .passThroughOutputFormatsMatchForQualification(
                source: source, output: output, observed: observed(source)
            ))
        XCTAssertFalse(try AVFoundationTrackMigrationExecutorV4
            .passThroughOutputFormatsMatchForQualification(
                source: source, output: output,
                observed: [try AVFoundationTrackGraphAdapterV4
                    .canonicalFormatDescriptor(output[0], ordinal: 7)]
                    + [try AVFoundationTrackGraphAdapterV4
                        .canonicalFormatDescriptor(output[1], ordinal: 1)]
            ))
    }

    func testAC3PassThroughOutputFormatProofRejectsChangedSemantics() throws {
        let cookie = Data([0, 0, 0, 11, 0x64, 0x61, 0x63, 0x33, 0x10, 0x12, 0x40])
        let source = try sampleStreamAC3QualificationFormat(
            cookie: cookie, usesISOWrapper: true, otherExtension: "original"
        )
        var changedCookie = cookie
        changedCookie[9] ^= 0x08
        let changedOutputs = try [
            sampleStreamAC3QualificationFormat(
                cookie: changedCookie, usesISOWrapper: false,
                otherExtension: "original"
            ),
            sampleStreamAC3QualificationFormat(
                cookie: cookie, usesISOWrapper: false,
                sampleRate: 44_100, otherExtension: "original"
            ),
            sampleStreamAC3QualificationFormat(
                cookie: cookie, usesISOWrapper: false,
                channels: 6, otherExtension: "original"
            ),
            sampleStreamAC3QualificationFormat(
                cookie: cookie, usesISOWrapper: false,
                otherExtension: "changed"
            ),
            sampleStreamAC3QualificationFormat(
                cookie: Data(cookie.dropLast()), usesISOWrapper: false,
                otherExtension: "original"
            )
        ]
        for output in changedOutputs {
            let observed = try AVFoundationTrackGraphAdapterV4
                .canonicalFormatDescriptor(output)
            XCTAssertFalse(try AVFoundationTrackMigrationExecutorV4
                .passThroughOutputFormatsMatchForQualification(
                    source: [source], output: [output], observed: [observed]
                ))
        }
    }

    func testISOTrackNameMigrationPreservesExactUTF8ValueAndSourceFingerprint()
        async throws {
        let source = isoTrackNameQualificationItem(Data("Stéréo 🎧".utf8))
        source.extendedLanguageTag = "fr"
        let originalHash = try await AVFoundationTrackGraphAdapterV4
            .canonicalTrackMetadataFingerprint([source])
        let output = try await AVFoundationTrackGraphAdapterV4
            .migratedTrackMetadataItems([source])
        let item = try XCTUnwrap(output.first)
        XCTAssertEqual(output.count, 1)
        XCTAssertEqual(item.identifier, .quickTimeUserDataTrackName)
        XCTAssertEqual(item.dataType, kCMMetadataBaseDataType_UTF8 as String)
        XCTAssertEqual(item.extendedLanguageTag, source.extendedLanguageTag)
        XCTAssertEqual(item.time, source.time)
        XCTAssertEqual(item.duration, source.duration)
        let itemString = try await item.load(.stringValue)
        XCTAssertEqual(
            Data(try XCTUnwrap(itemString).utf8),
            Data("Stéréo 🎧".utf8)
        )
        let retainedSourceHash = try await AVFoundationTrackGraphAdapterV4
            .canonicalTrackMetadataFingerprint([source])
        let rawOutputHash = try await AVFoundationTrackGraphAdapterV4
            .canonicalTrackMetadataFingerprint(output)
        let migratedSourceHash = try await AVFoundationTrackGraphAdapterV4
            .canonicalMigratedTrackMetadataFingerprint([source])
        let migratedOutputHash = try await AVFoundationTrackGraphAdapterV4
            .canonicalMigratedTrackMetadataFingerprint(output)
        XCTAssertEqual(originalHash, retainedSourceHash)
        XCTAssertNotEqual(originalHash, rawOutputHash)
        XCTAssertEqual(migratedSourceHash, migratedOutputHash)
    }

    func testISOTrackNameMigrationBindsMissingChangedLanguageAndUnknownMetadata()
        async throws {
        let source = isoTrackNameQualificationItem(Data("Stereo".utf8))
        let expected = try await AVFoundationTrackGraphAdapterV4
            .canonicalMigratedTrackMetadataFingerprint([source])
        let output = try await AVFoundationTrackGraphAdapterV4
            .migratedTrackMetadataItems([source])
        let changedName = try XCTUnwrap(output.first?.mutableCopy()
            as? AVMutableMetadataItem)
        changedName.value = "Surround" as NSString
        let changedLanguage = try XCTUnwrap(output.first?.mutableCopy()
            as? AVMutableMetadataItem)
        changedLanguage.extendedLanguageTag = "en"
        let unknown = AVMutableMetadataItem()
        unknown.identifier = .quickTimeMetadataDescription
        unknown.dataType = kCMMetadataBaseDataType_UTF8 as String
        unknown.value = "Additional metadata" as NSString
        for items in [[], [changedName], [changedLanguage], output + [unknown]] {
            let actual = try await AVFoundationTrackGraphAdapterV4
                .canonicalMigratedTrackMetadataFingerprint(items)
            XCTAssertNotEqual(expected, actual)
        }
        let unknownOutput = try await AVFoundationTrackGraphAdapterV4
            .migratedTrackMetadataItems([unknown])
        let unknownHash = try await AVFoundationTrackGraphAdapterV4
            .canonicalTrackMetadataFingerprint([unknown])
        let unknownOutputHash = try await AVFoundationTrackGraphAdapterV4
            .canonicalTrackMetadataFingerprint(unknownOutput)
        XCTAssertEqual(unknownHash, unknownOutputHash)
    }

    func testISOTrackNameMigrationRetainsInvalidUTF8WithoutLossyConversion()
        async throws {
        let source = isoTrackNameQualificationItem(Data([0xff, 0xfe]))
        let originalHash = try await AVFoundationTrackGraphAdapterV4
            .canonicalTrackMetadataFingerprint([source])
        let output = try await AVFoundationTrackGraphAdapterV4
            .migratedTrackMetadataItems([source])
        let item = try XCTUnwrap(output.first)
        let outputData = try await item.load(.dataValue)
        let migratedHash = try await AVFoundationTrackGraphAdapterV4
            .canonicalMigratedTrackMetadataFingerprint([source])
        XCTAssertEqual(output.count, 1)
        XCTAssertEqual(item.identifier, source.identifier)
        XCTAssertEqual(item.dataType, source.dataType)
        XCTAssertEqual(outputData, Data([0xff, 0xfe]))
        XCTAssertEqual(originalHash, migratedHash)
    }

    func testAACMP4RawISOTrackNameSurvivesMOVMigration() async throws {
        let directory = try TrackMigrationFixtureDirectoryV4()
        defer { directory.remove() }
        let sourceURL = directory.url("iso-track-name-source.mp4")
        let outputURL = directory.url("iso-track-name-output.mov")
        try await TrackMigrationFixtureFactoryV4.makeAACMovie(
            at: sourceURL, fileType: .mp4
        )
        try injectISOTrackNameQualificationAtom(
            Data("Stereo".utf8), into: sourceURL
        )
        let sourceAsset = AVURLAsset(url: sourceURL)
        let source = try await AVFoundationTrackGraphAdapterV4.probe(asset: sourceAsset)
        let sourceTracks = try await sourceAsset.loadTracks(withMediaType: .audio)
        let sourceItems = try await XCTUnwrap(sourceTracks.first).load(.metadata)
        let sourceItem = try XCTUnwrap(sourceItems.first)
        XCTAssertEqual(sourceItems.count, 1)
        XCTAssertEqual(sourceItem.identifier?.rawValue, "uiso/name")
        let sourceItemData = try await sourceItem.load(.dataValue)
        XCTAssertEqual(sourceItemData, Data("Stereo".utf8))
        let sourceMetadataHash = try XCTUnwrap(source.tracks.first).metadataFingerprint
        let plan = try MediaTrackGraphPlannerV4.makePlan(source: source)
        let result = try await AVFoundationTrackMigrationExecutorV4().execute(.init(
            sourceURL: sourceURL, destinationURL: outputURL,
            sourceGraph: source, identifiedPlan: plan,
            blueprint: try AVFoundationTrackMigrationPlannerV4
                .makeBlueprint(source: source, plan: plan)
        ))
        XCTAssertTrue(result.verificationReport.isConformant)
        XCTAssertEqual(
            result.outputGraph.tracks.first?.metadataFingerprint,
            sourceMetadataHash
        )
        let stream = try XCTUnwrap(result.trackResults.first)
        XCTAssertEqual(stream.sourceSampleStreamSHA256, stream.outputSampleStreamSHA256)
        let outputTracks = try await AVURLAsset(url: outputURL)
            .loadTracks(withMediaType: .audio)
        let outputItems = try await XCTUnwrap(outputTracks.first).load(.metadata)
        let outputItem = try XCTUnwrap(outputItems.first)
        XCTAssertEqual(outputItems.count, 1)
        XCTAssertEqual(outputItem.identifier, .quickTimeUserDataTrackName)
        let outputString = try await outputItem.load(.stringValue)
        XCTAssertEqual(
            Data(try XCTUnwrap(outputString).utf8),
            Data("Stereo".utf8)
        )
        let retainedSource = try await AVFoundationTrackGraphAdapterV4
            .probe(asset: sourceAsset)
        XCTAssertEqual(
            retainedSource.tracks.first?.metadataFingerprint,
            sourceMetadataHash
        )
    }

    func testChapterListContainerMappingRetainsAllIdentityFields() async throws {
        let item = AVMutableMetadataItem()
        item.identifier = AVMetadataIdentifier(rawValue: "uiso/chpl")
        item.dataType = kCMMetadataBaseDataType_RawData as String
        item.value = Data([1, 2, 3]) as NSData
        item.extendedLanguageTag = "en-US"
        let mapped = try XCTUnwrap(AVFoundationTrackMigrationExecutorV4.movAssetMetadataItems([item]).first)
        XCTAssertEqual(mapped.identifier?.rawValue, "udta/chpl")
        XCTAssertEqual(item.identifier?.rawValue, "uiso/chpl")
        let expected = try await AVFoundationTrackMigrationExecutorV4.canonicalAssetMetadataSHA256([item])
        let observed = try await AVFoundationTrackMigrationExecutorV4.canonicalAssetMetadataSHA256([mapped])
        XCTAssertEqual(expected, observed)
        for changed in ["payload", "language", "identifier", "type", "missing"] {
            let mutation = mapped.mutableCopy() as! AVMutableMetadataItem
            switch changed {
            case "payload": mutation.value = Data([1, 2, 4]) as NSData
            case "language": mutation.extendedLanguageTag = "fr"
            case "identifier": mutation.identifier = AVMetadataIdentifier(rawValue: "udta/name")
            case "type": mutation.dataType = kCMMetadataBaseDataType_UTF8 as String
            default: break
            }
            let hash = try await AVFoundationTrackMigrationExecutorV4.canonicalAssetMetadataSHA256(
                changed == "missing" ? [] : [mutation]
            )
            XCTAssertNotEqual(expected, hash, changed)
        }
    }

    func testChapterListContainerMappingLeavesUnknownMetadataUntouched() {
        for (identifier, type) in [
            ("uiso/name", kCMMetadataBaseDataType_RawData as String),
            ("uiso/chpl", kCMMetadataBaseDataType_UTF8 as String)
        ] {
            let item = AVMutableMetadataItem()
            item.identifier = AVMetadataIdentifier(rawValue: identifier)
            item.dataType = type
            item.value = Data([7]) as NSData
            let output = AVFoundationTrackMigrationExecutorV4.movAssetMetadataItems([item])
            XCTAssertTrue(output[0] === item)
        }
    }

    func testMP4RawChapterListSurvivesMOVMigration() async throws {
        let directory = try TrackMigrationFixtureDirectoryV4()
        defer { directory.remove() }
        let sourceURL = directory.url("chapter-list-source.mp4")
        let outputURL = directory.url("chapter-list-output.mov")
        try await TrackMigrationFixtureFactoryV4.makeAACMovie(at: sourceURL, fileType: .mp4)
        // Nero chapter-list userdata: version 1, one chapter at zero named Start.
        let bytes = Data([1, 0, 0, 0, 0, 0, 0, 0, 1,
                          0, 0, 0, 0, 0, 0, 0, 0, 5]) + Data("Start".utf8)
        try injectAssetChapterListAtom(bytes, into: sourceURL)
        let original = try Data(contentsOf: sourceURL)
        let asset = AVURLAsset(url: sourceURL)
        let metadata = try await asset.load(.metadata)
        let chapter = try XCTUnwrap(metadata.first { $0.identifier?.rawValue == "uiso/chpl" })
        let sourceBytes = try await chapter.load(.dataValue)
        XCTAssertEqual(sourceBytes, bytes)
        let graph = try await AVFoundationTrackGraphAdapterV4.probe(asset: asset)
        let plan = try MediaTrackGraphPlannerV4.makePlan(source: graph)
        let result = try await AVFoundationTrackMigrationExecutorV4().execute(.init(
            sourceURL: sourceURL, destinationURL: outputURL,
            sourceGraph: graph, identifiedPlan: plan,
            blueprint: try AVFoundationTrackMigrationPlannerV4.makeBlueprint(source: graph, plan: plan)
        ))
        XCTAssertTrue(result.verificationReport.isConformant)
        XCTAssertEqual(result.sourceAssetMetadataSHA256, result.outputAssetMetadataSHA256)
        let outputMetadata = try await AVURLAsset(url: outputURL).load(.metadata)
        let retained = try XCTUnwrap(outputMetadata.first { $0.identifier?.rawValue == "udta/chpl" })
        let outputBytes = try await retained.load(.dataValue)
        XCTAssertEqual(outputBytes, bytes)
        XCTAssertEqual(try Data(contentsOf: sourceURL), original)
    }

    func testAACMP4PassThroughToMOVPreservesSemanticIdentityAndSamples()
        async throws {
        let directory = try TrackMigrationFixtureDirectoryV4()
        defer { directory.remove() }
        let sourceURL = directory.url("aac-wrapper-source.mp4")
        let destinationURL = directory.url("aac-wrapper-output.mov")
        try await TrackMigrationFixtureFactoryV4.makeAACMovie(
            at: sourceURL,
            fileType: .mp4
        )

        let sourceAsset = AVURLAsset(
            url: sourceURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let source = try await AVFoundationTrackGraphAdapterV4.probe(
            asset: sourceAsset
        )
        let sourceAudio = try XCTUnwrap(source.tracks.first)
        XCTAssertEqual(source.tracks.count, 1)
        XCTAssertEqual(sourceAudio.kind, .audio)
        XCTAssertEqual(sourceAudio.formatDescriptors.count, 1)
        XCTAssertEqual(
            sourceAudio.formatDescriptors[0].mediaSubtypeID,
            "fourcc_61616320"
        )
        let sourceAssetTracks = try await sourceAsset.loadTracks(
            withMediaType: .audio
        )
        let sourceAssetTrack = try XCTUnwrap(sourceAssetTracks.first)
        let sourceFormats = try await sourceAssetTrack.load(
            .formatDescriptions
        )
        let sourceFormat = try XCTUnwrap(sourceFormats.first)
        let sourceExtensions = try XCTUnwrap(
            CMFormatDescriptionGetExtensions(sourceFormat) as NSDictionary?
        )
        XCTAssertNotNil(sourceExtensions["VerbatimISOSampleEntry"])

        let plan = try MediaTrackGraphPlannerV4.makePlan(source: source)
        let result = try await AVFoundationTrackMigrationExecutorV4().execute(
            .init(
                sourceURL: sourceURL,
                destinationURL: destinationURL,
                outputFileType: .mov,
                sourceGraph: source,
                identifiedPlan: plan,
                blueprint: try AVFoundationTrackMigrationPlannerV4
                    .makeBlueprint(source: source, plan: plan)
            )
        )

        let outputAudio = try XCTUnwrap(result.outputGraph.tracks.first)
        XCTAssertEqual(outputAudio.formatDescriptors, sourceAudio.formatDescriptors)
        let migrated = try XCTUnwrap(result.trackResults.first)
        XCTAssertEqual(migrated.action, .passThrough)
        XCTAssertGreaterThan(migrated.migratedSampleCount, 0)
        XCTAssertEqual(
            try XCTUnwrap(migrated.sourceSampleStreamSHA256),
            migrated.outputSampleStreamSHA256
        )
        let destinationAsset = AVURLAsset(
            url: destinationURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let destinationTracks = try await destinationAsset.loadTracks(
            withMediaType: .audio
        )
        let destinationTrack = try XCTUnwrap(destinationTracks.first)
        let destinationFormats = try await destinationTrack.load(
            .formatDescriptions
        )
        let destinationFormat = try XCTUnwrap(destinationFormats.first)
        let destinationExtensions = try XCTUnwrap(
            CMFormatDescriptionGetExtensions(destinationFormat) as NSDictionary?
        )
        XCTAssertNotNil(
            destinationExtensions["VerbatimSampleDescription"]
        )
        XCTAssertTrue(result.verificationReport.isConformant)
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

    func testProcessedVideoReplacementRebuildsExactLeadingEmptyEditTopology()
        async throws {
        let directory = try TrackMigrationFixtureDirectoryV4()
        defer { directory.remove() }
        let mediaURL = directory.url("replacement-edit-media.mov")
        let sourceURL = directory.url("replacement-edit-source.mov")
        let replacementURL = directory.url("replacement-edit-stream.mov")
        let destinationURL = directory.url("replacement-edit-output.mov")
        try await TrackMigrationFixtureFactoryV4.makeRichMovie(
            at: mediaURL,
            includeAudioGroup: false
        )
        try await TrackMigrationFixtureFactoryV4
            .makeLeadingEmptyVideoEditedMovie(
                source: mediaURL,
                at: sourceURL
            )
        try await TrackMigrationFixtureFactoryV4.makeReencodedVideo(
            source: mediaURL,
            at: replacementURL
        )

        let source = try await AVFoundationTrackGraphAdapterV4.probe(
            asset: AVURLAsset(url: sourceURL)
        )
        let video = try XCTUnwrap(source.tracks.first { $0.kind == .video })
        XCTAssertTrue(video.edits.first?.isEmpty == true)
        XCTAssertEqual(video.edits.count, 2)
        let firstMediaEdit = try XCTUnwrap(
            video.edits.first { !$0.isEmpty }
        )
        XCTAssertGreaterThan(firstMediaEdit.target.start, .zero)
        XCTAssertEqual(firstMediaEdit.source?.start, .zero)

        let replacement = try await AVFoundationTrackGraphAdapterV4.probe(
            asset: AVURLAsset(url: replacementURL)
        )
        let replacementVideo = try XCTUnwrap(replacement.tracks.first)
        XCTAssertFalse(replacementVideo.edits.contains(where: \.isEmpty))
        let plan = try processingPlan(
            source: source,
            video: video,
            targetFormats: replacementVideo.formatDescriptors
        )
        let expected = try XCTUnwrap(plan.plan.tracks.first {
            $0.source.identity.stableID == video.identity.stableID
        }?.expectedOutput)
        XCTAssertEqual(expected.edits, video.edits)
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
                processedVideoReplacement: .init(
                    trackID: video.identity.stableID,
                    sourceURL: replacementURL
                )
            )
        )

        let output = try XCTUnwrap(result.outputGraph.tracks.first)
        XCTAssertEqual(output.timeRange, expected.timeRange)
        XCTAssertEqual(output.edits, expected.edits)
        XCTAssertTrue(output.edits.first?.isEmpty == true)
        XCTAssertEqual(
            output.edits.first { !$0.isEmpty }?.source,
            firstMediaEdit.source
        )
        let processed = try XCTUnwrap(result.trackResults.first)
        XCTAssertEqual(processed.action, .process)
        XCTAssertEqual(
            processed.sourceSampleStreamSHA256,
            processed.outputSampleStreamSHA256
        )
        XCTAssertTrue(result.verificationReport.isConformant)
        XCTAssertFalse(try directory.containsPartialMovie())
    }

    func testProcessedVideoReplacementRestoresNonzeroMediaOriginWithoutDroppingFrames()
        async throws {
        let directory = try TrackMigrationFixtureDirectoryV4()
        defer { directory.remove() }
        let mediaURL = directory.url("media-origin-media.mov")
        let sourceURL = directory.url("media-origin-source.mov")
        let replacementURL = directory.url("media-origin-replacement.mov")
        let destinationURL = directory.url("media-origin-output.mov")
        try await TrackMigrationFixtureFactoryV4.makeRichMovie(
            at: mediaURL,
            includeAudioGroup: false
        )
        try await TrackMigrationFixtureFactoryV4
            .makeNonzeroSourceVideoEditedMovie(
                source: mediaURL,
                at: sourceURL
            )

        let source = try await AVFoundationTrackGraphAdapterV4.probe(
            asset: AVURLAsset(url: sourceURL)
        )
        let video = try XCTUnwrap(source.tracks.first { $0.kind == .video })
        let sourceMapping = try XCTUnwrap(
            video.edits.first { !$0.isEmpty }?.source
        )
        XCTAssertGreaterThan(sourceMapping.start, .zero)
        let sourceTarget = try XCTUnwrap(
            video.edits.first { !$0.isEmpty }?.target
        )
        XCTAssertEqual(sourceTarget.start, .zero)
        XCTAssertEqual(sourceTarget.duration, sourceMapping.duration)

        try await TrackMigrationFixtureFactoryV4.makeReencodedVideo(
            source: sourceURL,
            at: replacementURL,
            normalizePresentationToZero: true
        )

        let replacement = try await AVFoundationTrackGraphAdapterV4.probe(
            asset: AVURLAsset(url: replacementURL)
        )
        let replacementVideo = try XCTUnwrap(replacement.tracks.first)
        let replacementMapping = try XCTUnwrap(
            replacementVideo.edits.first { !$0.isEmpty }?.source
        )
        XCTAssertEqual(replacementMapping.start, .zero)
        XCTAssertEqual(
            replacementVideo.edits.first { !$0.isEmpty }?.target.start,
            .zero
        )
        let replacementSamples = try await realVideoSampleTimings(
            at: replacementURL
        )
        XCTAssertGreaterThan(replacementSamples.count, 1)
        let replacementFirstPresentation = try XCTUnwrap(
            replacementSamples.first
        )
        XCTAssertTrue(replacementFirstPresentation.isNumeric)
        XCTAssertEqual(replacementFirstPresentation.epoch, 0)
        XCTAssertFalse(
            replacementFirstPresentation.flags.contains(.hasBeenRounded)
        )
        XCTAssertEqual(
            try ExactRationalV4(
                replacementFirstPresentation.value,
                Int64(replacementFirstPresentation.timescale)
            ),
            .zero
        )

        let plan = try processingPlan(
            source: source,
            video: video,
            targetFormats: replacementVideo.formatDescriptors
        )
        let expected = try XCTUnwrap(plan.plan.tracks.first {
            $0.source.identity.stableID == video.identity.stableID
        }?.expectedOutput)
        XCTAssertEqual(
            expected.edits.first { !$0.isEmpty }?.source,
            sourceMapping
        )
        let result = try await AVFoundationTrackMigrationExecutorV4().execute(
            .init(
                sourceURL: sourceURL,
                destinationURL: destinationURL,
                sourceGraph: source,
                identifiedPlan: plan,
                blueprint: try AVFoundationTrackMigrationPlannerV4
                    .makeBlueprint(source: source, plan: plan),
                processedVideoReplacement: .init(
                    trackID: video.identity.stableID,
                    sourceURL: replacementURL
                )
            )
        )

        let output = try XCTUnwrap(result.outputGraph.tracks.first {
            $0.identity.stableID == video.identity.stableID
        })
        XCTAssertEqual(output.timeRange, expected.timeRange)
        XCTAssertEqual(output.edits, expected.edits)
        let processed = try XCTUnwrap(result.trackResults.first {
            $0.trackID == video.identity.stableID
        })
        XCTAssertEqual(
            processed.migratedSampleCount,
            Int64(replacementSamples.count)
        )
        XCTAssertEqual(
            try XCTUnwrap(processed.sourceSampleStreamSHA256),
            processed.outputSampleStreamSHA256
        )
        let destinationSamples = try await realVideoSampleTimings(
            at: destinationURL
        )
        XCTAssertEqual(
            destinationSamples.count,
            replacementSamples.count
        )
        let destinationFirstPresentation = try XCTUnwrap(
            destinationSamples.first
        )
        XCTAssertTrue(destinationFirstPresentation.isNumeric)
        XCTAssertEqual(destinationFirstPresentation.epoch, 0)
        XCTAssertFalse(
            destinationFirstPresentation.flags.contains(.hasBeenRounded)
        )
        XCTAssertEqual(
            try ExactRationalV4(
                destinationFirstPresentation.value,
                Int64(destinationFirstPresentation.timescale)
            ),
            sourceMapping.start
        )
        XCTAssertTrue(result.verificationReport.isConformant)
        XCTAssertFalse(try directory.containsPartialMovie())
    }

    func testProcessedReplacementMediaOriginCanPrecedeTargetSessionStart()
        throws {
        let targetStart = try ExactRationalV4(1, 30)
        let withoutReplacement = try AVFoundationTrackMigrationExecutorV4
            .sessionStartTimeForQualification(
                plannedTargetStarts: [targetStart],
                processedReplacementMediaStarts: []
            )
        XCTAssertEqual(withoutReplacement, CMTime(value: 1, timescale: 30))

        let withReplacement = try AVFoundationTrackMigrationExecutorV4
            .sessionStartTimeForQualification(
                plannedTargetStarts: [targetStart],
                processedReplacementMediaStarts: [.zero]
            )
        XCTAssertEqual(withReplacement, .zero)
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

    func testZeroSampleEditMarkerPreservesLeadingEditWithoutChangingRealCount()
        async throws {
        let directory = try TrackMigrationFixtureDirectoryV4()
        defer { directory.remove() }
        let mediaURL = directory.url("marker-media.mov")
        let sourceURL = directory.url("marker-source.mov")
        let destinationURL = directory.url("marker-output.mov")
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
        let sourceTrack = try XCTUnwrap(source.tracks.first)
        XCTAssertTrue(sourceTrack.edits.first?.isEmpty == true)
        let sourceTimings = try await realVideoSampleTimings(at: sourceURL)
        XCTAssertFalse(sourceTimings.isEmpty)

        let realPresentationTime = CMTime(value: 7, timescale: 30)
        let realSample = try sampleStreamQualificationBuffer(
            payloads: [
                Data([0x00, 0x00, 0x00, 0x01]),
                Data([0x00, 0x00, 0x00, 0x02])
            ],
            start: realPresentationTime,
            duration: CMTime(value: 1, timescale: 30)
        )
        XCTAssertEqual(CMSampleBufferGetNumSamples(realSample), 2)
        let marker = try makeZeroSampleMarker()
        var accountedSampleCount: Int64 = 0
        var lastRealPresentationTime: CMTime?
        AVFoundationTrackMigrationExecutorV4.accountAppendedRealSamples(
            in: realSample,
            sampleCount: &accountedSampleCount,
            lastPresentationTime: &lastRealPresentationTime
        )
        AVFoundationTrackMigrationExecutorV4.accountAppendedRealSamples(
            in: marker,
            sampleCount: &accountedSampleCount,
            lastPresentationTime: &lastRealPresentationTime
        )
        XCTAssertEqual(accountedSampleCount, 1)
        XCTAssertEqual(lastRealPresentationTime, realPresentationTime)

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

        let outputTimings = try await realVideoSampleTimings(
            at: destinationURL
        )
        XCTAssertEqual(outputTimings, sourceTimings)
        XCTAssertEqual(
            result.trackResults.first?.migratedSampleCount,
            Int64(sourceTimings.count)
        )
        let outputTrack = try XCTUnwrap(result.outputGraph.tracks.first)
        XCTAssertTrue(outputTrack.edits.first?.isEmpty == true)
        XCTAssertEqual(outputTrack.edits, sourceTrack.edits)
        XCTAssertTrue(result.verificationReport.isConformant)
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
            "ash-avfoundation-sample-stream-v4.2".utf8
        )
        domainSeparated.append(0)
        domainSeparated.append(referenceBytes)
        let expectedDigest = ASHSHA256V4(rawData: domainSeparated)

        XCTAssertNotEqual(accumulator.digest, firstDigest)
        XCTAssertEqual(accumulator.digest, expectedDigest)
        XCTAssertEqual(accumulator.digest, expectedDigest)
        let retention = accumulator.retentionDiagnosticForQualification
        XCTAssertGreaterThan(retention.processedCanonicalByteCount, 0)
        XCTAssertLessThan(
            retention.processedCanonicalByteCount,
            UInt64(referenceBytes.count)
        )
        XCTAssertGreaterThan(retention.retainedCanonicalByteCount, 0)
    }

    func testSampleStreamAccumulatorCanonicalizesExactTimesAndReaderDurationArtifacts()
        throws {
        let formatDuration = CMTime(value: 1, timescale: 30)
        let payloads = [
            Data([0x10, 0x20, 0x30, 0x40]),
            Data([0x20, 0x30, 0x40, 0x50]),
            Data([0x30, 0x40, 0x50, 0x60])
        ]
        let sourceTimings = [
            CMSampleTimingInfo(
                duration: formatDuration,
                presentationTimeStamp: CMTime(value: 58, timescale: 30),
                decodeTimeStamp: CMTime(value: 58, timescale: 30)
            ),
            CMSampleTimingInfo(
                duration: formatDuration,
                presentationTimeStamp: CMTime(value: 59, timescale: 30),
                decodeTimeStamp: CMTime(value: 59, timescale: 30)
            ),
            CMSampleTimingInfo(
                duration: formatDuration,
                presentationTimeStamp: CMTime(value: 90, timescale: 30),
                decodeTimeStamp: CMTime(value: 60, timescale: 30)
            )
        ]
        var synthesizedTimings = sourceTimings
        synthesizedTimings[1].duration = CMTime(value: 31, timescale: 30)
        var shiftedTimings = synthesizedTimings
        shiftedTimings[2].presentationTimeStamp = CMTime(
            value: 91,
            timescale: 30
        )
        let source = try sampleStreamQualificationBuffer(
            payloads: payloads,
            start: .zero,
            duration: formatDuration,
            formatDuration: formatDuration,
            timings: sourceTimings
        )
        let rewritten = try sampleStreamQualificationBuffer(
            payloads: payloads,
            start: .zero,
            duration: formatDuration,
            formatDuration: formatDuration,
            timings: synthesizedTimings
        )
        let shifted = try sampleStreamQualificationBuffer(
            payloads: payloads,
            start: .zero,
            duration: formatDuration,
            formatDuration: formatDuration,
            timings: shiftedTimings
        )
        let alteredPayload = try sampleStreamQualificationBuffer(
            payloads: [payloads[0], payloads[1], Data([0x30, 0x40, 0x50, 0x61])],
            start: .zero,
            duration: formatDuration,
            formatDuration: formatDuration,
            timings: sourceTimings
        )

        var sourceIdentity = SampleStreamAccumulatorV4()
        var rewrittenIdentity = SampleStreamAccumulatorV4()
        var shiftedIdentity = SampleStreamAccumulatorV4()
        var alteredPayloadIdentity = SampleStreamAccumulatorV4()
        try sourceIdentity.append(source)
        try rewrittenIdentity.append(rewritten)
        try shiftedIdentity.append(shifted)
        try alteredPayloadIdentity.append(alteredPayload)

        XCTAssertEqual(sourceIdentity.digest, rewrittenIdentity.digest)
        XCTAssertNotEqual(sourceIdentity.digest, shiftedIdentity.digest)
        XCTAssertNotEqual(sourceIdentity.digest, alteredPayloadIdentity.digest)
    }

    func testSampleStreamAccumulatorPreservesUniformAACPacketGrouping() throws {
        let format = try sampleStreamAACQualificationFormat()
        let frame = CMTime(value: 1_024, timescale: 48_000)
        let payloads = [Data([1, 2, 3, 4]), Data([5, 6, 7, 8])]
        let timing = CMSampleTimingInfo(
            duration: frame,
            presentationTimeStamp: frame,
            decodeTimeStamp: frame
        )
        let grouped = try sampleStreamQualificationBuffer(
            payloads: payloads, start: frame, duration: frame,
            timings: [timing], formatDescription: format
        )
        var readerTiming = CMSampleTimingInfo()
        XCTAssertEqual(
            CMSampleBufferGetSampleTimingInfo(
                grouped, at: 0, timingInfoOut: &readerTiming
            ),
            noErr
        )
        XCTAssertFalse(readerTiming.decodeTimeStamp.isNumeric)
        XCTAssertEqual(CMTimeCompare(CMSampleBufferGetDecodeTimeStamp(grouped), frame), 0)

        var groupedIdentity = SampleStreamAccumulatorV4()
        var separateIdentity = SampleStreamAccumulatorV4()
        try groupedIdentity.append(grouped)
        for index in payloads.indices {
            let timestamp = CMTime(value: Int64((index + 1) * 1_024), timescale: 48_000)
            try separateIdentity.append(sampleStreamQualificationBuffer(
                payloads: [payloads[index]], start: timestamp, duration: frame,
                timings: [CMSampleTimingInfo(
                    duration: frame,
                    presentationTimeStamp: timestamp,
                    decodeTimeStamp: timestamp
                )], formatDescription: format
            ))
        }
        XCTAssertEqual(groupedIdentity.digest, separateIdentity.digest)
    }

    func testSampleStreamAccumulatorBindsUniformAACTimingAndPayloadChanges()
        throws {
        let format = try sampleStreamAACQualificationFormat()
        let frame = CMTime(value: 1_024, timescale: 48_000)
        let payloads = [Data([1, 2, 3, 4]), Data([5, 6, 7, 8])]
        func digest(
            presentation: CMTime = CMTime(value: 1_024, timescale: 48_000),
            decode: CMTime = CMTime(value: 1_024, timescale: 48_000),
            samples: [Data] = [Data([1, 2, 3, 4]), Data([5, 6, 7, 8])]
        ) throws -> ASHSHA256V4 {
            var identity = SampleStreamAccumulatorV4()
            try identity.append(sampleStreamQualificationBuffer(
                payloads: samples, start: presentation, duration: frame,
                timings: [CMSampleTimingInfo(
                    duration: frame,
                    presentationTimeStamp: presentation,
                    decodeTimeStamp: decode
                )], formatDescription: format
            ))
            return identity.digest
        }
        let original = try digest()
        XCTAssertNotEqual(original, try digest(decode: CMTime(value: 2_048, timescale: 48_000)))
        XCTAssertNotEqual(original, try digest(presentation: CMTime(value: 2_048, timescale: 48_000)))
        XCTAssertNotEqual(original, try digest(samples: [payloads[0], Data([5, 6, 7, 9])]))
        XCTAssertNotEqual(original, try digest(decode: .invalid))
    }

    func testSampleStreamAccumulatorRetainsExplicitAACDecodeTimes() throws {
        let format = try sampleStreamAACQualificationFormat()
        let frame = CMTime(value: 1_024, timescale: 48_000)
        let payloads = [Data([1, 2, 3, 4]), Data([5, 6, 7, 8])]
        let timings = payloads.indices.map { index in
            let timestamp = CMTime(value: Int64((index + 1) * 1_024), timescale: 48_000)
            return CMSampleTimingInfo(
                duration: frame,
                presentationTimeStamp: timestamp,
                decodeTimeStamp: timestamp
            )
        }
        var changedTimings = timings
        changedTimings[1].decodeTimeStamp = CMTime(value: 3_072, timescale: 48_000)
        var originalIdentity = SampleStreamAccumulatorV4()
        var changedIdentity = SampleStreamAccumulatorV4()
        try originalIdentity.append(sampleStreamQualificationBuffer(
            payloads: payloads, start: frame, duration: frame,
            timings: timings, formatDescription: format
        ))
        try changedIdentity.append(sampleStreamQualificationBuffer(
            payloads: payloads, start: frame, duration: frame,
            timings: changedTimings, formatDescription: format
        ))
        XCTAssertNotEqual(originalIdentity.digest, changedIdentity.digest)
    }

    func testSampleStreamAccumulatorPreservesUniformAACDecodeEpoch() throws {
        let format = try sampleStreamAACQualificationFormat()
        let frame = CMTime(value: 1_024, timescale: 48_000)
        let payloads = [Data([1, 2, 3, 4]), Data([5, 6, 7, 8])]
        func groupedIdentity(decodeEpoch: CMTimeEpoch) throws -> SampleStreamAccumulatorV4 {
            var identity = SampleStreamAccumulatorV4()
            try identity.append(sampleStreamQualificationBuffer(
                payloads: payloads, start: frame, duration: frame,
                timings: [CMSampleTimingInfo(
                    duration: frame,
                    presentationTimeStamp: frame,
                    decodeTimeStamp: CMTime(
                        value: 1_024, timescale: 48_000,
                        flags: .valid, epoch: decodeEpoch
                    )
                )], formatDescription: format
            ))
            return identity
        }
        let grouped = try groupedIdentity(decodeEpoch: 7)
        var separate = SampleStreamAccumulatorV4()
        for index in payloads.indices {
            let value = Int64((index + 1) * 1_024)
            let presentation = CMTime(value: value, timescale: 48_000)
            try separate.append(sampleStreamQualificationBuffer(
                payloads: [payloads[index]], start: presentation, duration: frame,
                timings: [CMSampleTimingInfo(
                    duration: frame,
                    presentationTimeStamp: presentation,
                    decodeTimeStamp: CMTime(
                        value: value, timescale: 48_000, flags: .valid, epoch: 7
                    )
                )], formatDescription: format
            ))
        }
        XCTAssertEqual(grouped.digest, separate.digest)
        XCTAssertNotEqual(grouped.digest, try groupedIdentity(decodeEpoch: 8).digest)
    }

    func testSampleStreamAccumulatorRejectsRoundedUniformAACClock() throws {
        let format = try sampleStreamAACQualificationFormat()
        let frame = CMTime(value: 1_024, timescale: 48_000)
        let rounded = CMTime(
            value: 1_024, timescale: 48_000,
            flags: [.valid, .hasBeenRounded], epoch: 0
        )
        let timings = [
            CMSampleTimingInfo(
                duration: frame, presentationTimeStamp: frame, decodeTimeStamp: rounded
            ),
            CMSampleTimingInfo(
                duration: frame, presentationTimeStamp: rounded, decodeTimeStamp: frame
            ),
            CMSampleTimingInfo(
                duration: rounded, presentationTimeStamp: frame, decodeTimeStamp: frame
            ),
        ]
        for timing in timings {
            let buffer = try sampleStreamQualificationBuffer(
                payloads: [Data([1, 2, 3, 4]), Data([5, 6, 7, 8])],
                start: frame, duration: frame,
                timings: [timing], formatDescription: format
            )
            var identity = SampleStreamAccumulatorV4()
            XCTAssertThrowsError(try identity.append(buffer)) {
                XCTAssertEqual(
                    ($0 as? SampleStreamAccumulatorV4.Error)?.status,
                    kCMSampleBufferError_SampleTimingInfoInvalid
                )
            }
        }
    }

    func testSampleStreamAccumulatorBindsTerminalDurationMutation() throws {
        let frame = CMTime(value: 1, timescale: 30)
        let payloads = [
            Data([0x01, 0x02, 0x03, 0x04]),
            Data([0x05, 0x06, 0x07, 0x08]),
            Data([0x09, 0x0a, 0x0b, 0x0c])
        ]
        let timings = (0..<3).map { index in
            CMSampleTimingInfo(
                duration: frame,
                presentationTimeStamp: CMTime(
                    value: CMTimeValue(index),
                    timescale: 30
                ),
                decodeTimeStamp: CMTime(
                    value: CMTimeValue(index),
                    timescale: 30
                )
            )
        }
        var mutatedTimings = timings
        mutatedTimings[2].duration = CMTime(value: 2, timescale: 30)
        let source = try sampleStreamQualificationBuffer(
            payloads: payloads,
            start: .zero,
            duration: frame,
            timings: timings
        )
        let mutated = try sampleStreamQualificationBuffer(
            payloads: payloads,
            start: .zero,
            duration: frame,
            timings: mutatedTimings
        )
        var sourceIdentity = SampleStreamAccumulatorV4()
        var mutatedIdentity = SampleStreamAccumulatorV4()
        try sourceIdentity.append(source)
        try mutatedIdentity.append(mutated)

        XCTAssertNotEqual(sourceIdentity.digest, mutatedIdentity.digest)
    }

    func testSampleStreamAccumulatorCanonicalizesAuthorizedTerminalBoundarySynthesis()
        throws
    {
        let frame = CMTime(value: 1, timescale: 30)
        let payloads = [
            Data([0x01, 0x02, 0x03, 0x04]),
            Data([0x05, 0x06, 0x07, 0x08]),
            Data([0x09, 0x0a, 0x0b, 0x0c]),
            Data([0x0d, 0x0e, 0x0f, 0x10])
        ]
        let timings = [
            CMSampleTimingInfo(
                duration: frame,
                presentationTimeStamp: CMTime(value: 58, timescale: 30),
                decodeTimeStamp: CMTime(value: 57, timescale: 30)
            ),
            CMSampleTimingInfo(
                duration: frame,
                presentationTimeStamp: CMTime(value: 59, timescale: 30),
                decodeTimeStamp: CMTime(value: 58, timescale: 30)
            ),
            CMSampleTimingInfo(
                duration: frame,
                presentationTimeStamp: CMTime(value: 57, timescale: 30),
                decodeTimeStamp: CMTime(value: 59, timescale: 30)
            ),
            CMSampleTimingInfo(
                duration: frame,
                presentationTimeStamp: CMTime(value: 90, timescale: 30),
                decodeTimeStamp: CMTime(value: 60, timescale: 30)
            )
        ]
        var synthesizedTimings = timings
        synthesizedTimings[3].duration = CMTime(value: 31, timescale: 30)
        let source = try sampleStreamQualificationBuffer(
            payloads: payloads,
            start: .zero,
            duration: frame,
            timings: timings
        )
        let synthesized = try sampleStreamQualificationBuffer(
            payloads: payloads,
            start: .zero,
            duration: frame,
            timings: synthesizedTimings
        )
        let authorizedEnd = CMTime(value: 91, timescale: 30)
        var sourceIdentity = SampleStreamAccumulatorV4(
            authorizedTerminalPresentationEnd: authorizedEnd
        )
        var synthesizedIdentity = SampleStreamAccumulatorV4(
            authorizedTerminalPresentationEnd: authorizedEnd
        )
        try sourceIdentity.append(source)
        try synthesizedIdentity.append(synthesized)

        XCTAssertEqual(sourceIdentity.digest, synthesizedIdentity.digest)
    }

    func testSampleStreamTerminalAuthorizationRequiresObservedEditAgreement()
        throws
    {
        let trackID = try MediaTrackStableIDV4("av-track-1")
        let leading = try MediaTrackEditV4(
            ordinal: 0,
            source: nil,
            target: MediaExactTimeRangeV4(
                start: .zero,
                duration: ExactRationalV4(2, 1)
            ),
            isEmpty: true
        )
        let mapped = try MediaTrackEditV4(
            ordinal: 1,
            source: MediaExactTimeRangeV4(
                start: .zero,
                duration: ExactRationalV4(91, 30)
            ),
            target: MediaExactTimeRangeV4(
                start: ExactRationalV4(2, 1),
                duration: ExactRationalV4(91, 30)
            ),
            isEmpty: false
        )
        let changed = try MediaTrackEditV4(
            ordinal: 1,
            source: MediaExactTimeRangeV4(
                start: .zero,
                duration: ExactRationalV4(90, 30)
            ),
            target: MediaExactTimeRangeV4(
                start: ExactRationalV4(2, 1),
                duration: ExactRationalV4(90, 30)
            ),
            isEmpty: false
        )
        let plannedEnd = CMTime(value: 91, timescale: 30)

        XCTAssertEqual(
            try AVFoundationTrackMigrationExecutorV4
                .authorizedTerminalPresentationEndForReopen(
                    trackID: trackID,
                    planned: plannedEnd,
                    plannedEdits: [leading, mapped],
                    observedEdits: [leading, mapped]
                ),
            plannedEnd
        )
        XCTAssertThrowsError(
            try AVFoundationTrackMigrationExecutorV4
                .authorizedTerminalPresentationEndForReopen(
                    trackID: trackID,
                    planned: plannedEnd,
                    plannedEdits: [leading, mapped],
                    observedEdits: [leading, changed]
                )
        )
        XCTAssertNil(
            try AVFoundationTrackMigrationExecutorV4
                .authorizedTerminalPresentationEndForReopen(
                    trackID: trackID,
                    planned: nil,
                    plannedEdits: [leading, mapped],
                    observedEdits: [leading, changed]
                )
        )
    }

    func testEditMapMovieTimescaleExactlyRepresentsPlannedMapping()
        throws
    {
        let trackID = try MediaTrackStableIDV4("av-track-1")
        let duration = try ExactRationalV4(21, 500)
        let timeRange = try MediaExactTimeRangeV4(
            start: .zero,
            duration: duration
        )
        let edit = try MediaTrackEditV4(
            ordinal: 0,
            source: timeRange,
            target: timeRange,
            isEmpty: false
        )

        let timescale = try AVFoundationTrackMigrationExecutorV4
            .exactEditMapMovieTimescaleForQualification([(
                trackID: trackID,
                timeRange: timeRange,
                edits: [edit]
            )])

        XCTAssertEqual(timescale, 500)
        XCTAssertEqual(
            CMTimeConvertScale(
                CMTime(value: 21, timescale: 500),
                timescale: timescale,
                method: .default
            ),
            CMTime(value: 21, timescale: timescale)
        )
    }

    func testEditMapMovieTimescaleKeepsMediaTimebaseIndependent() throws {
        let trackID = try MediaTrackStableIDV4("av-track-1")
        let timeRange = try MediaExactTimeRangeV4(
            start: .zero,
            duration: ExactRationalV4(1, 600)
        )
        let edit = try MediaTrackEditV4(
            ordinal: 0,
            source: MediaExactTimeRangeV4(
                start: .zero,
                duration: ExactRationalV4(1, 2_147_483_647)
            ),
            target: timeRange,
            isEmpty: false
        )

        let timescale = try AVFoundationTrackMigrationExecutorV4
            .exactEditMapMovieTimescaleForQualification([(
                trackID: trackID,
                timeRange: timeRange,
                edits: [edit]
            )])

        XCTAssertEqual(timescale, 600)
    }

    func testEditMapMovieTimescaleRejectsUnrepresentableLCM() throws {
        let trackID = try MediaTrackStableIDV4("av-track-1")
        let timeRange = try MediaExactTimeRangeV4(
            start: .zero,
            duration: ExactRationalV4(1, 2_147_483_646)
        )
        let incompatibleEdit = try MediaTrackEditV4(
            ordinal: 0,
            source: nil,
            target: MediaExactTimeRangeV4(
                start: .zero,
                duration: ExactRationalV4(1, 2_147_483_647)
            ),
            isEmpty: true
        )

        XCTAssertThrowsError(
            try AVFoundationTrackMigrationExecutorV4
                .exactEditMapMovieTimescaleForQualification([(
                    trackID: trackID,
                    timeRange: timeRange,
                    edits: [incompatibleEdit]
                )])
        ) { error in
            XCTAssertEqual(
                error as? AVFoundationTrackMigrationExecutorV4Error,
                .unsupportedTrack(
                    trackID,
                    reason: "edit_map_timescale_not_representable"
                )
            )
        }
    }

    func testMovieTimescalePreservingPCMSamplesIncludesExactSampleClock()
        throws {
        let trackID = try MediaTrackStableIDV4("av-track-2")
        let timescale = try AVFoundationTrackMigrationExecutorV4
            .movieTimescalePreservingPCMSamplesForQualification(
                plannedMovieTimescale: 22_500,
                preservedPCMSampleClocks: [(trackID: trackID, timescale: 48_000)]
            )

        XCTAssertEqual(timescale, 720_000)
        for boundary in [
            CMTime(value: 61_937, timescale: 22_500),
            CMTime(value: 132_131, timescale: 48_000),
            CMTime(value: 132_132, timescale: 48_000)
        ] {
            let converted = CMTimeConvertScale(
                boundary,
                timescale: timescale,
                method: .default
            )
            XCTAssertFalse(converted.flags.contains(.hasBeenRounded))
            XCTAssertEqual(CMTimeCompare(converted, boundary), 0)
        }
        XCTAssertEqual(
            try AVFoundationTrackMigrationExecutorV4
                .movieTimescalePreservingPCMSamplesForQualification(
                    plannedMovieTimescale: timescale,
                    preservedPCMSampleClocks: [(trackID: trackID, timescale: 48_000)]
                ),
            timescale
        )
    }

    func testMovieTimescaleWithoutPreservedPCMSamplesKeepsPlannedClock()
        throws {
        XCTAssertEqual(
            try AVFoundationTrackMigrationExecutorV4
                .movieTimescalePreservingPCMSamplesForQualification(
                    plannedMovieTimescale: 22_500,
                    preservedPCMSampleClocks: []
                ),
            22_500
        )
    }

    func testPreservedPCMSampleClockUsesNativeClockForFractionalSampleRate()
        throws {
        let trackID = try MediaTrackStableIDV4("av-track-2")
        let format = try audioFormatDescription(sampleRate: 48_000.5, channels: 1)
        let stream = try XCTUnwrap(
            CMAudioFormatDescriptionGetStreamBasicDescription(format)
        ).pointee
        XCTAssertEqual(stream.mSampleRate, 48_000.5)
        let clocks = try AVFoundationTrackMigrationExecutorV4
            .preservedPCMSampleClockTimescalesForQualification(
                [format],
                sourceNativeClock: 96_001,
                trackID: trackID
            )

        XCTAssertEqual(clocks, [96_001])
        let movieClock = try AVFoundationTrackMigrationExecutorV4
            .movieTimescalePreservingPCMSamplesForQualification(
                plannedMovieTimescale: 600,
                preservedPCMSampleClocks: clocks.map {
                    (trackID: trackID, timescale: $0)
                }
            )
        let exactSamplePeriod = CMTime(value: 2, timescale: 96_001)
        let converted = CMTimeConvertScale(
            exactSamplePeriod,
            timescale: movieClock,
            method: .default
        )
        XCTAssertEqual(movieClock, 57_600_600)
        XCTAssertFalse(converted.flags.contains(.hasBeenRounded))
        XCTAssertEqual(CMTimeCompare(converted, exactSamplePeriod), 0)
    }

    func testPreservedPCMSampleClockFilterIgnoresAACAndVideo() throws {
        let trackID = try MediaTrackStableIDV4("av-track-2")
        var stream = AudioStreamBasicDescription(
            mSampleRate: 48_000.5,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 1_024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        var audio: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &stream,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &audio
        ), noErr)
        var video: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_H264,
            width: 96,
            height: 64,
            extensions: nil,
            formatDescriptionOut: &video
        ), noErr)
        let clocks = try AVFoundationTrackMigrationExecutorV4
            .preservedPCMSampleClockTimescalesForQualification(
                [try XCTUnwrap(audio), try XCTUnwrap(video)],
                sourceNativeClock: 96_001,
                trackID: trackID
            )
        XCTAssertTrue(clocks.isEmpty)
        XCTAssertEqual(
            try AVFoundationTrackMigrationExecutorV4
                .movieTimescalePreservingPCMSamplesForQualification(
                    plannedMovieTimescale: 22_500,
                    preservedPCMSampleClocks: clocks.map {
                        (trackID: trackID, timescale: $0)
                    }
                ),
            22_500
        )
    }

    func testMovieTimescalePreservingPCMSamplesRejectsUnrepresentableLCM()
        throws {
        let trackID = try MediaTrackStableIDV4("av-track-2")
        XCTAssertThrowsError(
            try AVFoundationTrackMigrationExecutorV4
                .movieTimescalePreservingPCMSamplesForQualification(
                    plannedMovieTimescale: 2_147_483_647,
                    preservedPCMSampleClocks: [(trackID: trackID, timescale: 48_000)]
                )
        ) { error in
            XCTAssertEqual(
                error as? AVFoundationTrackMigrationExecutorV4Error,
                .unsupportedTrack(
                    trackID,
                    reason: "edit_map_timescale_not_representable"
                )
            )
        }
    }

    func testSampleStreamAccumulatorRejectsUnprovenTerminalBoundarySynthesis()
        throws
    {
        let frame = CMTime(value: 1, timescale: 30)
        let payloads = [
            Data([0x01, 0x02, 0x03, 0x04]),
            Data([0x05, 0x06, 0x07, 0x08]),
            Data([0x09, 0x0a, 0x0b, 0x0c])
        ]
        let timings = [
            CMSampleTimingInfo(
                duration: frame,
                presentationTimeStamp: CMTime(value: 58, timescale: 30),
                decodeTimeStamp: CMTime(value: 58, timescale: 30)
            ),
            CMSampleTimingInfo(
                duration: frame,
                presentationTimeStamp: CMTime(value: 59, timescale: 30),
                decodeTimeStamp: CMTime(value: 59, timescale: 30)
            ),
            CMSampleTimingInfo(
                duration: frame,
                presentationTimeStamp: CMTime(value: 90, timescale: 30),
                decodeTimeStamp: CMTime(value: 60, timescale: 30)
            )
        ]
        var synthesizedTimings = timings
        synthesizedTimings[2].duration = CMTime(value: 31, timescale: 30)
        var nonGapTimings = timings
        nonGapTimings[2].duration = CMTime(value: 30, timescale: 30)
        var invalidCadenceTimings = synthesizedTimings
        invalidCadenceTimings[2].decodeTimeStamp = CMTime(
            value: 59,
            timescale: 30
        )
        var invalidCadenceSourceTimings = timings
        invalidCadenceSourceTimings[2].decodeTimeStamp = CMTime(
            value: 59,
            timescale: 30
        )
        var reorderedTimings = timings
        reorderedTimings[1].presentationTimeStamp = CMTime(
            value: 91,
            timescale: 30
        )
        var reorderedSynthesizedTimings = reorderedTimings
        reorderedSynthesizedTimings[2].duration = CMTime(
            value: 31,
            timescale: 30
        )

        func buffer(_ sampleTimings: [CMSampleTimingInfo]) throws
            -> CMSampleBuffer
        {
            try sampleStreamQualificationBuffer(
                payloads: payloads,
                start: .zero,
                duration: frame,
                timings: sampleTimings
            )
        }
        func digest(
            _ sampleTimings: [CMSampleTimingInfo],
            authorizedEnd: CMTime?
        ) throws -> ASHSHA256V4 {
            var identity = SampleStreamAccumulatorV4(
                authorizedTerminalPresentationEnd: authorizedEnd
            )
            try identity.append(buffer(sampleTimings))
            return identity.digest
        }

        XCTAssertNotEqual(
            try digest(timings, authorizedEnd: nil),
            try digest(synthesizedTimings, authorizedEnd: nil)
        )
        XCTAssertNotEqual(
            try digest(
                timings,
                authorizedEnd: CMTime(value: 92, timescale: 30)
            ),
            try digest(
                synthesizedTimings,
                authorizedEnd: CMTime(value: 92, timescale: 30)
            )
        )
        XCTAssertNotEqual(
            try digest(
                timings,
                authorizedEnd: CMTime(value: 91, timescale: 30)
            ),
            try digest(
                nonGapTimings,
                authorizedEnd: CMTime(value: 91, timescale: 30)
            )
        )
        XCTAssertNotEqual(
            try digest(
                invalidCadenceSourceTimings,
                authorizedEnd: CMTime(value: 91, timescale: 30)
            ),
            try digest(
                invalidCadenceTimings,
                authorizedEnd: CMTime(value: 91, timescale: 30)
            )
        )
        XCTAssertNotEqual(
            try digest(
                reorderedTimings,
                authorizedEnd: CMTime(value: 91, timescale: 30)
            ),
            try digest(
                reorderedSynthesizedTimings,
                authorizedEnd: CMTime(value: 91, timescale: 30)
            )
        )
    }

    func testSampleStreamAccumulatorBindsUnjustifiedInteriorDurationMutation()
        throws
    {
        let frame = CMTime(value: 1, timescale: 30)
        let payloads = [
            Data([0x01, 0x02, 0x03, 0x04]),
            Data([0x05, 0x06, 0x07, 0x08]),
            Data([0x09, 0x0a, 0x0b, 0x0c])
        ]
        let timings = (0..<3).map { index in
            CMSampleTimingInfo(
                duration: frame,
                presentationTimeStamp: CMTime(
                    value: CMTimeValue(index),
                    timescale: 30
                ),
                decodeTimeStamp: CMTime(
                    value: CMTimeValue(index),
                    timescale: 30
                )
            )
        }
        var mutatedTimings = timings
        mutatedTimings[1].duration = CMTime(value: 2, timescale: 30)
        let source = try sampleStreamQualificationBuffer(
            payloads: payloads,
            start: .zero,
            duration: frame,
            timings: timings
        )
        let mutated = try sampleStreamQualificationBuffer(
            payloads: payloads,
            start: .zero,
            duration: frame,
            timings: mutatedTimings
        )
        var sourceIdentity = SampleStreamAccumulatorV4()
        var mutatedIdentity = SampleStreamAccumulatorV4()
        try sourceIdentity.append(source)
        try mutatedIdentity.append(mutated)

        XCTAssertNotEqual(sourceIdentity.digest, mutatedIdentity.digest)
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
        XCTAssertLessThan(
            diagnostic.processedCanonicalByteCount,
            UInt64(bytesPerBuffer * appendCount)
        )
        XCTAssertGreaterThan(diagnostic.processedCanonicalByteCount, 1_000_000)
        XCTAssertGreaterThan(diagnostic.retainedCanonicalByteCount, 0)
        XCTAssertLessThan(diagnostic.retainedCanonicalByteCount, 1_024)
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
        duration: CMTime,
        formatDuration: CMTime? = nil,
        timings explicitTimings: [CMSampleTimingInfo]? = nil,
        formatDescription: CMFormatDescription? = nil
    ) throws -> CMSampleBuffer {
        guard !payloads.isEmpty,
              payloads.allSatisfy({ $0.count == MemoryLayout<Int32>.size })
        else {
            throw TrackMigrationFixtureErrorV4.invalidFixture(
                "Qualification timecode samples must be four bytes."
            )
        }
        var format = formatDescription
        var status = noErr
        if format == nil {
            status = CMTimeCodeFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                timeCodeFormatType: kCMTimeCodeFormatType_TimeCode32,
                frameDuration: formatDuration ?? duration,
                frameQuanta: 30,
                flags: 0,
                extensions: nil,
                formatDescriptionOut: &format
            )
        }
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

        let timings = explicitTimings ?? payloads.indices.map { index in
            CMSampleTimingInfo(
                duration: duration,
                presentationTimeStamp: CMTimeAdd(
                    start,
                    CMTimeMultiply(duration, multiplier: Int32(index))
                ),
                decodeTimeStamp: .invalid
            )
        }
        guard timings.count == payloads.count || timings.count == 1 else {
            throw TrackMigrationFixtureErrorV4.invalidFixture(
                "Qualification timing count differs from payload count."
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

    func isoTrackNameQualificationItem(_ value: Data) -> AVMutableMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = AVMetadataIdentifier(rawValue: "uiso/name")
        item.dataType = kCMMetadataBaseDataType_RawData as String
        item.value = value as NSData
        item.extraAttributes = [
            AVMetadataExtraAttributeKey(rawValue: "dataTypeNamespace"):
                "com.apple.quicktime.udta",
            AVMetadataExtraAttributeKey(rawValue: "dataType"): 0
        ]
        return item
    }

    func injectAssetChapterListAtom(_ payload: Data, into url: URL) throws {
        var movie = try Data(contentsOf: url)
        func box(_ type: String, _ data: Data) -> Data {
            var length = UInt32(data.count + 8).bigEndian
            return withUnsafeBytes(of: &length) { Data($0) } + Data(type.utf8) + data
        }
        var offset = 0
        var sawMedia = false
        while offset + 8 <= movie.count {
            var length = movie[offset..<(offset + 4)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            if length == 1 {
                guard offset + 16 <= movie.count else {
                    throw TrackMigrationFixtureErrorV4.invalidFixture("Truncated extended atom.")
                }
                length = movie[(offset + 8)..<(offset + 16)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            } else if length == 0 { length = UInt64(movie.count - offset) }
            guard length >= 8, length <= UInt64(movie.count - offset) else {
                throw TrackMigrationFixtureErrorV4.invalidFixture("Invalid fixture atom extent.")
            }
            let type = String(decoding: movie[(offset + 4)..<(offset + 8)], as: UTF8.self)
            if type == "mdat" { sawMedia = true }
            if type == "moov" {
                guard sawMedia else {
                    throw TrackMigrationFixtureErrorV4.invalidFixture("Fixture requires trailing moov.")
                }
                let end = offset + Int(length)
                let original = movie[(offset + 8)..<end]
                let replacement = box("moov", Data(original) + box("udta", box("chpl", payload)))
                movie.replaceSubrange(offset..<end, with: replacement)
                try movie.write(to: url, options: .atomic)
                return
            }
            offset += Int(length)
        }
        throw TrackMigrationFixtureErrorV4.invalidFixture("Fixture moov is missing.")
    }

    func injectISOTrackNameQualificationAtom(_ value: Data, into url: URL)
        throws {
        var movie = try Data(contentsOf: url)
        func integer(_ data: Data, at offset: Int, count: Int) -> UInt64 {
            data[offset..<(offset + count)].reduce(0) { ($0 << 8) | UInt64($1) }
        }
        func atoms(_ data: Data, in range: Range<Int>) throws
            -> [(type: String, range: Range<Int>)] {
            var result: [(String, Range<Int>)] = []
            var offset = range.lowerBound
            while offset < range.upperBound {
                guard range.upperBound - offset >= 8 else {
                    throw TrackMigrationFixtureErrorV4.invalidFixture("Truncated fixture atom.")
                }
                var size = integer(data, at: offset, count: 4)
                let headerSize: Int
                if size == 1 {
                    guard range.upperBound - offset >= 16 else {
                        throw TrackMigrationFixtureErrorV4.invalidFixture("Truncated fixture extended atom.")
                    }
                    size = integer(data, at: offset + 8, count: 8)
                    headerSize = 16
                } else {
                    headerSize = 8
                    if size == 0 { size = UInt64(range.upperBound - offset) }
                }
                guard size >= headerSize, size <= UInt64(range.upperBound - offset),
                      let count = Int(exactly: size) else {
                    throw TrackMigrationFixtureErrorV4.invalidFixture("Invalid fixture atom extent.")
                }
                let type = String(decoding: data[(offset + 4)..<(offset + 8)], as: UTF8.self)
                result.append((type, offset..<(offset + count)))
                offset += count
            }
            return result
        }
        func sizeBytes(_ size: Int) throws -> Data {
            guard let exact = UInt32(exactly: size) else {
                throw TrackMigrationFixtureErrorV4.invalidFixture("Fixture atom exceeds 32-bit size.")
            }
            var bigEndian = exact.bigEndian
            return withUnsafeBytes(of: &bigEndian) { Data($0) }
        }
        let topLevel = try atoms(movie, in: 0..<movie.count)
        let moov = try XCTUnwrap(topLevel.first { $0.type == "moov" })
        let mdat = try XCTUnwrap(topLevel.first { $0.type == "mdat" })
        guard moov.range.lowerBound > mdat.range.lowerBound,
              integer(movie, at: moov.range.lowerBound, count: 4) != 1 else {
            throw TrackMigrationFixtureErrorV4.invalidFixture("Fixture requires trailing 32-bit moov.")
        }
        let children = try atoms(movie, in: (moov.range.lowerBound + 8)..<moov.range.upperBound)
        let tracks = children.filter { $0.type == "trak" }
        let track = try XCTUnwrap(tracks.first)
        guard tracks.count == 1,
              integer(movie, at: track.range.lowerBound, count: 4) != 1 else {
            throw TrackMigrationFixtureErrorV4.invalidFixture("Fixture requires one 32-bit track.")
        }
        let trackChildren = try atoms(movie, in: (track.range.lowerBound + 8)..<track.range.upperBound)
        guard !trackChildren.contains(where: { $0.type == "udta" }) else {
            throw TrackMigrationFixtureErrorV4.invalidFixture("Fixture already has track user data.")
        }
        let name = try sizeBytes(value.count + 8) + Data("name".utf8) + value
        let userData = try sizeBytes(name.count + 8) + Data("udta".utf8) + name
        movie.replaceSubrange(track.range.lowerBound..<(track.range.lowerBound + 4),
                              with: try sizeBytes(track.range.count + userData.count))
        movie.replaceSubrange(moov.range.lowerBound..<(moov.range.lowerBound + 4),
                              with: try sizeBytes(moov.range.count + userData.count))
        movie.insert(contentsOf: userData, at: track.range.upperBound)
        try movie.write(to: url, options: .atomic)
    }

    func sampleStreamAC3QualificationFormat(
        cookie: Data,
        usesISOWrapper: Bool,
        sampleRate: Double = 48_000,
        channels: UInt32 = 2,
        formatID: AudioFormatID = kAudioFormatAC3,
        otherExtension: String? = nil
    ) throws -> CMAudioFormatDescription {
        var stream = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: formatID,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 1_536,
            mBytesPerFrame: 0,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        // Captured from the actual MP4 source and its verified MOV audio replay.
        let wrapper = try XCTUnwrap(Data(base64Encoded: usesISOWrapper
            ? "AAAAL2FjLTMAAAAAAAAAAQAAAAAAAAAAAAIAEAAAAAC7gAAAAAAAC2RhYzMQEkA="
            : "AAAAR2FjLTMAAAAAAAAAAQABAAAAAAAAAAIAEP/+AAC7gAAAAAAGAAAAAAEAAAACAAAAAgAAABN3YXZlAAAAC2RhYzMQEkA="
        ))
        var extensions: [String: Any] = [
            usesISOWrapper ? "VerbatimISOSampleEntry"
                : "VerbatimSampleDescription": wrapper
        ]
        if let otherExtension {
            extensions["QualificationCodecExtension"] = otherExtension
        }
        var format: CMAudioFormatDescription?
        let status = cookie.withUnsafeBytes { bytes in
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: &stream,
                layoutSize: 0,
                layout: nil,
                magicCookieSize: cookie.count,
                magicCookie: bytes.baseAddress,
                extensions: extensions as CFDictionary,
                formatDescriptionOut: &format
            )
        }
        guard status == noErr, let format else {
            throw TrackMigrationFixtureErrorV4.coreMedia(status)
        }
        return format
    }

    func sampleStreamAACQualificationFormat() throws -> CMAudioFormatDescription {
        var stream = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 1_024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        var format: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &stream,
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
                try appendReferenceTime(
                    timing.presentationTimeStamp,
                    to: &canonicalBytes
                )
                try appendReferenceTime(
                    timing.decodeTimeStamp,
                    to: &canonicalBytes
                )
                try appendReferenceTime(
                    timing.duration,
                    to: &canonicalBytes
                )
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

    func appendReferenceTime(_ time: CMTime, to bytes: inout Data) throws {
        if time.isNumeric, time.timescale != 0 {
            let exact = try ExactRationalV4(
                time.value,
                Int64(time.timescale)
            )
            bytes.append(1)
            appendReferenceInteger(exact.numerator, to: &bytes)
            appendReferenceInteger(exact.denominator, to: &bytes)
        } else {
            bytes.append(0)
            appendReferenceInteger(time.value, to: &bytes)
            appendReferenceInteger(time.timescale, to: &bytes)
        }
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

private func replacingTimeline(
    _ track: MediaTrackNodeV4,
    timeRange: MediaExactTimeRangeV4,
    edits: [MediaTrackEditV4]
) throws -> MediaTrackNodeV4 {
    try MediaTrackNodeV4(
        identity: track.identity,
        enabled: track.enabled,
        kind: track.kind,
        sourceMediaTypeID: track.sourceMediaTypeID,
        language: track.language,
        roleIDs: track.roleIDs,
        timebase: track.timebase,
        timeRange: timeRange,
        edits: edits,
        formatDescriptors: track.formatDescriptors,
        metadataFingerprint: track.metadataFingerprint
    )
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

private final class UpscaleProgressRecorderV4: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UpscaleProgress] = []

    func record(_ value: UpscaleProgress) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func snapshot() -> [UpscaleProgress] {
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

private actor TrackMigrationRecordingDeterministicBackendV4:
    PreparedDeterministicV4PlanningBackend,
    PreparedCheckpointableTemporalFrameUpscaler {
    struct Observation: Equatable, Sendable {
        let frameIndex: Int
        let presentationTime: CMTime
        let duration: CMTime
        let resetReasons: [ASHTemporalResetReasonV4?]
    }

    nonisolated let sourcePixelBufferAttributes: PixelBufferAttributes
    nonisolated let destinationPixelBufferAttributes: PixelBufferAttributes
    nonisolated let actualBackendID: UpscaleBackendID
    nonisolated let maximumOutputFramesPerInput: Int
    nonisolated let deterministicExecutor: ASHExecutorV4
    nonisolated let deterministicStorage: PixelStorageV4

    private let planning: any PreparedDeterministicV4PlanningBackend
    private let temporal: any PreparedCheckpointableTemporalFrameUpscaler
    private var observations: [Observation] = []
    private var finishCallCount = 0

    init(
        planning: any PreparedDeterministicV4PlanningBackend,
        temporal: any PreparedCheckpointableTemporalFrameUpscaler
    ) {
        self.planning = planning
        self.temporal = temporal
        sourcePixelBufferAttributes = planning.sourcePixelBufferAttributes
        destinationPixelBufferAttributes =
            planning.destinationPixelBufferAttributes
        actualBackendID = planning.actualBackendID
        maximumOutputFramesPerInput = temporal.maximumOutputFramesPerInput
        deterministicExecutor = planning.deterministicExecutor
        deterministicStorage = planning.deterministicStorage
    }

    func makeASHExecutionPlan(
        media: CanonicalMediaStateV4,
        request: ASHExecutionRequestV4
    ) async throws -> ASHIdentifiedExecutionPlanV4 {
        try await planning.makeASHExecutionPlan(media: media, request: request)
    }

    func process(
        source: FramePixelBuffer,
        destination: FramePixelBuffer,
        timing: FrameTiming
    ) async throws {
        try await planning.process(
            source: source,
            destination: destination,
            timing: timing
        )
    }

    func processTemporal(
        source: FramePixelBuffer,
        destinations: [FramePixelBuffer],
        timing: FrameTiming
    ) async throws -> [TemporalOutputFrame] {
        let output = try await temporal.processTemporal(
            source: source,
            destinations: destinations,
            timing: timing
        )
        observations.append(Observation(
            frameIndex: timing.frameIndex,
            presentationTime: timing.presentationTime,
            duration: timing.duration,
            resetReasons: output.map(\.temporalResetReason)
        ))
        return output
    }

    func makeTemporalCheckpoint(
        planSHA256: ASHSHA256V4,
        lastCompletedInputOrdinal: Int64
    ) async throws -> Data {
        try await temporal.makeTemporalCheckpoint(
            planSHA256: planSHA256,
            lastCompletedInputOrdinal: lastCompletedInputOrdinal
        )
    }

    func restoreTemporalCheckpoint(
        _ data: Data,
        planSHA256: ASHSHA256V4
    ) async throws {
        try await temporal.restoreTemporalCheckpoint(
            data,
            planSHA256: planSHA256
        )
    }

    func finish() async throws {
        finishCallCount += 1
        try await planning.finish()
    }

    func recordedObservations() -> [Observation] { observations }
    func recordedFinishCallCount() -> Int { finishCallCount }
}

private struct TrackMigrationWorkflowBookmarkResolverV4:
    WorkflowSecurityScopedBookmarkResolvingV4 {
    func makeBookmark(
        for url: URL,
        role _: WorkflowScopedResourceRoleV4
    ) throws -> Data {
        Data(url.standardizedFileURL.path.utf8)
    }

    func resolveBookmark(
        _ data: Data,
        role _: WorkflowScopedResourceRoleV4
    ) throws -> WorkflowResolvedScopedResourceV4 {
        let path = try XCTUnwrap(String(data: data, encoding: .utf8))
        return WorkflowResolvedScopedResourceV4(
            url: URL(fileURLWithPath: path),
            isStale: false,
            startAccessing: { true },
            stopAccessing: {}
        )
    }
}

private enum TrackMigrationFixtureFactoryV4 {
    static let width = 64
    static let height = 48
    private static let frameRate: CMTimeScale = 30
    private static let hdrBoundaryContainerTimescale: CMTimeScale = 600
    static let frameCount = 8
    static let hdrBoundaryFrameCount = 61
    private static let hdrBoundaryStoredFrameCount = 62

    struct HDRBoundaryFixture: Sendable {
        let hdr10Plus: HDR10PlusMetadataV4
        let mediaPresentationTimes: [CMTime]
        let primaryTargetStart: CMTime
        let mediaGapStart: CMTime
    }

    private struct VideoLane {
        let input: AVAssetWriterInput
        let adaptor: AVAssetWriterInputPixelBufferAdaptor
        let seed: UInt8
    }

    static func makeHDRBoundaryMovie(
        at url: URL,
        changedLeadingDurationURL: URL? = nil
    ) async throws -> HDRBoundaryFixture {
        let encodedURL = url.deletingPathExtension()
            .appendingPathExtension("encoded.mov")
        let audioURL = url.deletingPathExtension()
            .appendingPathExtension("audio.mov")
        let formatMetadata = try hdrBoundaryFormatMetadata()
        let hdr10Plus = try hdrBoundaryHDR10PlusMetadata()
        try await encodeHDRBoundaryVideo(
            at: encodedURL,
            metadata: formatMetadata
        )
        try await requireHDRBoundaryDecodedP010Legal(
            at: encodedURL,
            expectedMetadata: formatMetadata,
            expectedPresentationTimes: (0..<hdrBoundaryStoredFrameCount).map {
                CMTime(value: CMTimeValue($0), timescale: frameRate)
            }
        )
        let localTimes = (0..<hdrBoundaryFrameCount).map { index in
            index < 60
                ? CMTime(
                    value: CMTimeValue(index),
                    timescale: frameRate
                )
                : CMTime(value: 90, timescale: frameRate)
        }
        try await makeAudioMovie(
            at: audioURL,
            channelLayoutTag: kAudioChannelLayoutTag_Stereo,
            amplitude: 512
        )
        let primaryStart = CMTime(value: 2, timescale: 1)
        try await makeHDRBoundaryMutableMovie(
            encodedVideoURL: encodedURL,
            audioURL: audioURL,
            outputURL: url,
            primaryStart: primaryStart,
            expectedMetadata: formatMetadata,
            hdr10Plus: hdr10Plus,
            expectedMediaTimes: localTimes
        )
        if let changedLeadingDurationURL {
            try await makeHDRBoundaryMutableMovie(
                encodedVideoURL: encodedURL,
                audioURL: audioURL,
                outputURL: changedLeadingDurationURL,
                primaryStart: CMTime(value: 3, timescale: 1),
                expectedMetadata: formatMetadata,
                hdr10Plus: hdr10Plus,
                expectedMediaTimes: localTimes
            )
        }
        try FileManager.default.removeItem(at: encodedURL)
        try FileManager.default.removeItem(at: audioURL)
        return HDRBoundaryFixture(
            hdr10Plus: hdr10Plus,
            mediaPresentationTimes: localTimes,
            primaryTargetStart: primaryStart,
            mediaGapStart: CMTime(value: 90, timescale: frameRate)
        )
    }

    private static func hdrBoundaryFrameDomainStart(
        _ graphStart: CMTime
    ) throws -> CMTime {
        guard graphStart.isNumeric,
              !graphStart.flags.contains(.hasBeenRounded) else {
            throw TrackMigrationFixtureErrorV4.invalidFixture(
                "HDR boundary graph start is not exact numeric time."
            )
        }
        let frameStart = CMTimeConvertScale(
            graphStart,
            timescale: frameRate,
            method: .default
        )
        let roundTrip = CMTimeConvertScale(
            frameStart,
            timescale: graphStart.timescale,
            method: .default
        )
        guard frameStart.isNumeric,
              !frameStart.flags.contains(.hasBeenRounded),
              exactlyEqual(roundTrip, graphStart) else {
            throw TrackMigrationFixtureErrorV4.invalidFixture(
                "HDR boundary graph start is not exactly representable at "
                    + "the authored frame timescale."
            )
        }
        return frameStart
    }

    private static func requireHDRBoundaryObservations(
        _ observations: HDR10PlusVideoObservationsV4,
        expectedTimes: [CMTime],
        expectedReaderReportedDurations: [CMTime],
        expectedMetadata: HDR10PlusMetadataV4,
        expectedFormatMetadata: HDRFormatMetadataV4,
        stage: String
    ) throws {
        guard expectedReaderReportedDurations.count == expectedTimes.count,
              observations.presentationTimes.count == expectedTimes.count,
              observations.decodeTimes.count == expectedTimes.count,
              observations.durations.count == expectedTimes.count,
              observations.syncSamples.count == expectedTimes.count,
              observations.metadata.count == expectedTimes.count,
              observations.codecType == kCMVideoCodecType_HEVC,
              observations.formatMetadata == expectedFormatMetadata else {
            throw TrackMigrationFixtureErrorV4.invalidFixture(
                "\(stage) HDR boundary count mismatch: expected "
                    + "\(expectedTimes.count), observed PTS "
                    + "\(observations.presentationTimes.count), metadata "
                    + "\(observations.metadata.count), codec "
                    + "\(observations.codecType), format "
                    + "\(String(describing: observations.formatMetadata))."
            )
        }
        if let index = expectedTimes.indices.first(where: {
            !exactlyEqual(
                observations.presentationTimes[$0],
                expectedTimes[$0]
            )
        }) {
            throw TrackMigrationFixtureErrorV4.invalidFixture(
                "\(stage) HDR boundary PTS mismatch at index \(index): "
                    + "expected \(describe(expectedTimes[index])), observed "
                    + "\(describe(observations.presentationTimes[index]))."
            )
        }
        let expectedDecodeTimes = expectedTimes.indices.map {
            CMTime(value: CMTimeValue($0), timescale: frameRate)
        }
        if let index = expectedDecodeTimes.indices.first(where: {
            !exactlyEqual(
                observations.decodeTimes[$0],
                expectedDecodeTimes[$0]
            )
        }) {
            throw TrackMigrationFixtureErrorV4.invalidFixture(
                "\(stage) HDR boundary DTS mismatch at index \(index): "
                    + "expected \(describe(expectedDecodeTimes[index])), "
                    + "observed \(describe(observations.decodeTimes[index]))."
            )
        }
        let frameDuration = CMTime(value: 1, timescale: frameRate)
        if let index = observations.durations.indices.first(where: {
            !exactlyEqual(
                observations.durations[$0],
                expectedReaderReportedDurations[$0]
            )
        }) {
            throw TrackMigrationFixtureErrorV4.invalidFixture(
                "\(stage) HDR boundary duration mismatch at index \(index): "
                    + "expected "
                    + "\(describe(expectedReaderReportedDurations[index])), "
                    + "observed "
                    + "\(describe(observations.durations[index]))."
            )
        }
        let authoritativeDurations = observations.decodeTimes.indices.map {
            index in
            guard observations.decodeTimes.indices.contains(index + 1) else {
                return observations.durations[index]
            }
            return CMTimeSubtract(
                observations.decodeTimes[index + 1],
                observations.decodeTimes[index]
            )
        }
        if let index = authoritativeDurations.indices.first(where: {
            !exactlyEqual(authoritativeDurations[$0], frameDuration)
        }) {
            throw TrackMigrationFixtureErrorV4.invalidFixture(
                "\(stage) HDR boundary authoritative decode duration mismatch "
                    + "at index \(index): expected \(describe(frameDuration)), "
                    + "observed \(describe(authoritativeDurations[index]))."
            )
        }
        guard observations.syncSamples.allSatisfy({ $0 }) else {
            throw TrackMigrationFixtureErrorV4.invalidFixture(
                "\(stage) HDR boundary contains a non-sync sample."
            )
        }
        let decodeBoundaryDelta = CMTimeSubtract(
            observations.decodeTimes[60],
            observations.decodeTimes[59]
        )
        let priorEnd = CMTimeAdd(
            observations.presentationTimes[59],
            decodeBoundaryDelta
        )
        guard exactlyEqual(
                priorEnd,
                CMTime(value: 60, timescale: frameRate)
              ),
              exactlyEqual(decodeBoundaryDelta, frameDuration),
              CMTimeCompare(
                priorEnd,
                observations.presentationTimes[60]
              ) < 0 else {
            throw TrackMigrationFixtureErrorV4.invalidFixture(
                "\(stage) HDR boundary does not retain the exact [2,3) gap."
            )
        }
        if let index = observations.metadata.indices.first(where: {
            observations.metadata[$0] != expectedMetadata
        }) {
            let expectedSHA = sha256(expectedMetadata.ituTT35Payload)
            let observedSHA = observations.metadata[index].map {
                sha256($0.ituTT35Payload)
            } ?? "nil"
            throw TrackMigrationFixtureErrorV4.invalidFixture(
                "\(stage) HDR boundary metadata mismatch at index \(index): "
                    + "expected SHA-256 \(expectedSHA), observed \(observedSHA)."
            )
        }
    }

    static func hdrBoundaryReaderReportedDurations() -> [CMTime] {
        var durations = Array(
            repeating: CMTime(value: 1, timescale: frameRate),
            count: hdrBoundaryFrameCount
        )
        durations[59] = CMTime(value: 31, timescale: frameRate)
        return durations
    }

    private static func describe(_ time: CMTime) -> String {
        "\(time.value)/\(time.timescale) epoch=\(time.epoch) "
            + "flags=\(time.flags.rawValue)"
    }

    private static func exactlyEqual(_ lhs: CMTime, _ rhs: CMTime) -> Bool {
        lhs.value == rhs.value
            && lhs.timescale == rhs.timescale
            && lhs.flags == rhs.flags
            && lhs.epoch == rhs.epoch
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private static func encodeHDRBoundaryVideo(
        at url: URL,
        metadata: HDRFormatMetadataV4
    ) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        var compression = try AVFoundationHDRMetadataAdapterV4
            .videoToolboxCompressionProperties(
                for: metadata,
                dynamicPolicy: .preserveSourceWhenPixelsAreUnmodified,
                pixelsWereModified: false
            )
        compression[AVVideoProfileLevelKey] =
            kVTProfileLevel_HEVC_Main10_AutoLevel
        compression[AVVideoAllowFrameReorderingKey] = false
        compression[AVVideoMaxKeyFrameIntervalKey] = 1
        compression[AVVideoExpectedSourceFrameRateKey] = Int(frameRate)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey:
                AVFoundationHDRMetadataAdapterV4
                    .avFoundationColorProperties(for: metadata.signal),
            AVVideoCompressionPropertiesKey: compression
        ]
        guard writer.canApply(
            outputSettings: settings,
            forMediaType: .video
        ) else {
            throw TrackMigrationFixtureErrorV4.writer(
                "Writer rejected the HDR boundary HEVC settings."
            )
        }
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: settings
        )
        input.mediaTimeScale = frameRate
        guard writer.canAdd(input) else {
            throw TrackMigrationFixtureErrorV4.writer(
                writer.error?.localizedDescription
                    ?? "Writer rejected the HDR boundary video input."
            )
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw TrackMigrationFixtureErrorV4.writer(
                writer.error?.localizedDescription
                    ?? "HDR boundary writer did not start."
            )
        }
        writer.startSession(atSourceTime: .zero)

        for frame in 0..<hdrBoundaryStoredFrameCount {
            var pixelBuffer: CVPixelBuffer?
            let pixelStatus = CVPixelBufferCreate(
                kCFAllocatorDefault,
                width,
                height,
                kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
                    as CFDictionary,
                &pixelBuffer
            )
            guard pixelStatus == kCVReturnSuccess, let pixelBuffer else {
                throw TrackMigrationFixtureErrorV4.coreMedia(pixelStatus)
            }
            fillHDRBoundaryP010(pixelBuffer, frame: frame)
            try AVFoundationHDRMetadataAdapterV4.migrate(
                metadata,
                to: pixelBuffer
            )
            var format: CMVideoFormatDescription?
            var status = CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &format
            )
            guard status == noErr, let format else {
                throw TrackMigrationFixtureErrorV4.coreMedia(status)
            }
            let presentationTime = CMTime(
                value: CMTimeValue(frame),
                timescale: frameRate
            )
            var timing = CMSampleTimingInfo(
                duration: CMTime(value: 1, timescale: frameRate),
                presentationTimeStamp: presentationTime,
                decodeTimeStamp: presentationTime
            )
            var sample: CMSampleBuffer?
            status = CMSampleBufferCreateReadyWithImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescription: format,
                sampleTiming: &timing,
                sampleBufferOut: &sample
            )
            guard status == noErr, let sample else {
                throw TrackMigrationFixtureErrorV4.coreMedia(status)
            }
            try await waitUntilReady(input, writer: writer)
            guard input.append(sample) else {
                throw TrackMigrationFixtureErrorV4.writer(
                    writer.error?.localizedDescription
                        ?? "HDR boundary append failed."
                )
            }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(
            value: CMTimeValue(hdrBoundaryStoredFrameCount),
            timescale: frameRate
        ))
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else {
            throw TrackMigrationFixtureErrorV4.writer(
                writer.error?.localizedDescription
                    ?? "HDR boundary writer did not finish."
            )
        }
    }

    private static func requireHDRBoundaryDecodedP010Legal(
        at url: URL,
        expectedMetadata: HDRFormatMetadataV4,
        expectedPresentationTimes: [CMTime],
        readerTimeRange: CMTimeRange? = nil
    ) async throws {
        guard expectedPresentationTimes.count == hdrBoundaryFrameCount
                || expectedPresentationTimes.count
                    == hdrBoundaryStoredFrameCount else {
            throw TrackMigrationFixtureErrorV4.invalidFixture(
                "HDR boundary legal-range preflight requires exactly 61 "
                    + "presented or 62 stored PTS."
            )
        }
        let asset = AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard tracks.count == 1, let track = tracks.first else {
            throw TrackMigrationFixtureErrorV4.invalidFixture(
                "HDR boundary legal-range preflight requires one video track."
            )
        }
        let formats = try await track.load(.formatDescriptions)
        guard formats.count == 1, let format = formats.first,
              CMFormatDescriptionGetMediaSubType(format)
                == kCMVideoCodecType_HEVC,
              try AVFoundationHDRMetadataAdapterV4.probe(
                formatDescription: format,
                decodedStorage: .p010VideoRange10Bit
              ) == expectedMetadata else {
            throw TrackMigrationFixtureErrorV4.invalidFixture(
                "HDR boundary legal-range preflight requires exact Main10 HDR."
            )
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    Int(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange),
                AVVideoDecompressionPropertiesKey: [
                    kVTDecompressionPropertyKey_PropagatePerFrameHDRDisplayMetadata
                        as String: true
                ]
            ]
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw TrackMigrationFixtureErrorV4.invalidFixture(
                "HDR boundary legal-range reader rejected the video track."
            )
        }
        reader.add(output)
        if let readerTimeRange { reader.timeRange = readerTimeRange }
        guard reader.startReading() else {
            throw TrackMigrationFixtureErrorV4.writer(
                reader.error?.localizedDescription
                    ?? "HDR boundary legal-range reader did not start."
            )
        }
        var concreteIndex = 0
        while let sample = output.copyNextSampleBuffer() {
            let sampleCount = CMSampleBufferGetNumSamples(sample)
            if sampleCount == 0 { continue }
            guard sampleCount == 1,
                  concreteIndex < expectedPresentationTimes.count,
                  let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else {
                throw TrackMigrationFixtureErrorV4.invalidFixture(
                    "HDR boundary legal-range reader emitted an invalid sample."
                )
            }
            let expectedTime = expectedPresentationTimes[concreteIndex]
            let presentation = CMSampleBufferGetPresentationTimeStamp(sample)
            guard exactlyEqual(presentation, expectedTime) else {
                throw TrackMigrationFixtureErrorV4.invalidFixture(
                    "HDR boundary legal-range PTS mismatch at frame "
                        + "\(concreteIndex): expected \(describe(expectedTime)), "
                        + "observed \(describe(presentation))."
                )
            }
            try validateHDRBoundaryDecodedP010(
                pixelBuffer,
                frameIndex: concreteIndex
            )
            let decodedMetadata = try AVFoundationHDRMetadataAdapterV4.probe(
                pixelBuffer: pixelBuffer,
                storage: .p010VideoRange10Bit,
                fallback: expectedMetadata
            )
            guard decodedMetadata == expectedMetadata else {
                throw TrackMigrationFixtureErrorV4.invalidFixture(
                    "HDR boundary decoded HDR differs at frame \(concreteIndex)."
                )
            }
            concreteIndex += 1
        }
        guard reader.status == .completed,
              concreteIndex == expectedPresentationTimes.count else {
            throw TrackMigrationFixtureErrorV4.writer(
                reader.error?.localizedDescription
                    ?? "HDR boundary legal-range reader did not retain its "
                        + "exact expected frame count."
            )
        }
    }

    private static func validateHDRBoundaryDecodedP010(
        _ pixelBuffer: CVPixelBuffer,
        frameIndex: Int
    ) throws {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer)
                == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
              CVPixelBufferGetWidth(pixelBuffer) == width,
              CVPixelBufferGetHeight(pixelBuffer) == height,
              CVPixelBufferGetPlaneCount(pixelBuffer) == 2 else {
            throw TrackMigrationFixtureErrorV4.invalidFixture(
                "HDR boundary decoded P010 structure differs at frame "
                    + "\(frameIndex)."
            )
        }
        let status = CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        guard status == kCVReturnSuccess else {
            throw TrackMigrationFixtureErrorV4.coreMedia(status)
        }
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        }
        for plane in 0..<2 {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(
                pixelBuffer,
                plane
            )?.assumingMemoryBound(to: UInt16.self) else {
                throw TrackMigrationFixtureErrorV4.invalidFixture(
                    "HDR boundary decoded plane \(plane) is inaccessible."
                )
            }
            let planeWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, plane)
            let planeHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(
                pixelBuffer,
                plane
            ) / MemoryLayout<UInt16>.stride
            let components = plane == 0 ? 1 : 2
            let maximum = plane == 0 ? 940 : 960
            for y in 0..<planeHeight {
                for x in 0..<planeWidth {
                    for component in 0..<components {
                        let stored = base[y * stride + x * components + component]
                        let code = Int(stored >> 6)
                        guard stored & 0x003F == 0,
                              (64...maximum).contains(code) else {
                            throw TrackMigrationFixtureErrorV4.invalidFixture(
                                "HDR boundary decoded P010 code is invalid at "
                                    + "frame \(frameIndex), plane \(plane), "
                                    + "x \(x), y \(y), component \(component): "
                                    + "stored \(stored), code \(code)."
                            )
                        }
                    }
                }
            }
        }
    }

    private static func makeHDRBoundaryMutableMovie(
        encodedVideoURL: URL,
        audioURL: URL,
        outputURL: URL,
        primaryStart: CMTime,
        expectedMetadata: HDRFormatMetadataV4,
        hdr10Plus: HDR10PlusMetadataV4,
        expectedMediaTimes: [CMTime]
    ) async throws {
        guard !FileManager.default.fileExists(atPath: outputURL.path) else {
            throw TrackMigrationFixtureErrorV4.invalidFixture(
                "HDR boundary destination unexpectedly exists."
            )
        }
        let videoAsset = AVURLAsset(
            url: encodedVideoURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let audioAsset = AVURLAsset(
            url: audioURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let videoTracks = try await videoAsset.loadTracks(
            withMediaType: .video
        )
        let audioTracks = try await audioAsset.loadTracks(
            withMediaType: .audio
        )
        guard videoTracks.count == 1, let sourceVideo = videoTracks.first,
              audioTracks.count == 1, let sourceAudio = audioTracks.first else {
            throw TrackMigrationFixtureErrorV4.invalidFixture(
                "HDR boundary mutable movie requires one video and one audio "
                    + "source track."
            )
        }
        let videoFormats = try await sourceVideo.load(.formatDescriptions)
        guard videoFormats.count == 1, let videoFormat = videoFormats.first,
              CMFormatDescriptionGetMediaSubType(videoFormat)
                == kCMVideoCodecType_HEVC else {
            throw TrackMigrationFixtureErrorV4.invalidFixture(
                "HDR boundary encoded source requires one HEVC format."
            )
        }
        let audioRange = try await sourceAudio.load(.timeRange)
        _ = try await sourceVideo.load(.naturalTimeScale)
        _ = try await sourceVideo.load(.preferredTransform)
        _ = try await sourceVideo.load(.metadata)
        _ = try await sourceVideo.load(.languageCode)
        _ = try await sourceVideo.load(.extendedLanguageTag)
        _ = try await sourceAudio.load(.naturalTimeScale)
        _ = try await sourceAudio.load(.metadata)
        _ = try await sourceAudio.load(.languageCode)
        _ = try await sourceAudio.load(.extendedLanguageTag)

        let stagingRoot = outputURL.deletingLastPathComponent()
            .appendingPathComponent(
                ".hdr-boundary-movie-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: stagingRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        defer { try? FileManager.default.removeItem(at: stagingRoot) }
        try requireOwnedMode(stagingRoot, mode: 0o700)
        let stagedURL = stagingRoot.appendingPathComponent("payload.mov")
        var published = false
        do {
            if #available(macOS 26.0, *) {
                do {
                    try buildHDRBoundaryMutableMovie(
                        videoAsset: videoAsset,
                        sourceVideo: sourceVideo,
                        videoFormat: videoFormat,
                        sourceAudio: sourceAudio,
                        audioRange: audioRange,
                        outputURL: stagedURL,
                        primaryStart: primaryStart,
                        hdr10Plus: hdr10Plus
                    )
                } catch let fixtureError as TrackMigrationFixtureErrorV4 {
                    throw fixtureError
                } catch {
                    throw TrackMigrationFixtureErrorV4.writer(
                        "HDR boundary mutable-movie construction failed: "
                            + diagnosticErrorChain(error)
                    )
                }
            } else {
                throw TrackMigrationFixtureErrorV4.invalidFixture(
                    "HDR boundary mutable-movie fixture requires macOS 26."
                )
            }
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: stagedURL.path
            )
            try requireOwnedMode(stagedURL, mode: 0o600)
            do {
                try await requireHDRBoundaryMutableMovieAsset(
                    at: stagedURL,
                    audioRange: audioRange,
                    primaryStart: primaryStart,
                    expectedMetadata: expectedMetadata,
                    hdr10Plus: hdr10Plus,
                    expectedMediaTimes: expectedMediaTimes,
                    stage: "Private staged mutable movie"
                )
            } catch {
                throw TrackMigrationFixtureErrorV4.writer(
                    "HDR boundary pre-rename validation failed: "
                        + diagnosticErrorChain(error)
                )
            }
            guard rename(
                stagedURL.path,
                outputURL.path
            ) == 0 else {
                throw TrackMigrationFixtureErrorV4.writer(
                    "Atomic HDR boundary rename failed: "
                        + String(cString: strerror(errno))
                )
            }
            published = true
            try requireOwnedMode(outputURL, mode: 0o600)
            do {
                try await requireHDRBoundaryMutableMovieAsset(
                    at: outputURL,
                    audioRange: audioRange,
                    primaryStart: primaryStart,
                    expectedMetadata: expectedMetadata,
                    hdr10Plus: hdr10Plus,
                    expectedMediaTimes: expectedMediaTimes,
                    stage: "Atomically renamed mutable movie"
                )
            } catch {
                throw TrackMigrationFixtureErrorV4.writer(
                    "HDR boundary post-rename validation failed: "
                        + diagnosticErrorChain(error)
                )
            }
        } catch {
            if published { try? FileManager.default.removeItem(at: outputURL) }
            throw error
        }
    }

    @available(macOS 26.0, *)
    private static func buildHDRBoundaryMutableMovie(
        videoAsset: AVAsset,
        sourceVideo: AVAssetTrack,
        videoFormat: CMFormatDescription,
        sourceAudio: AVAssetTrack,
        audioRange: CMTimeRange,
        outputURL: URL,
        primaryStart: CMTime,
        hdr10Plus: HDR10PlusMetadataV4
    ) throws {
        try createOwnerOnlyEmptyStorageFile(at: outputURL)
        let movie = AVMutableMovie()
        // 600 exactly represents both the 30 fps video cadence and the
        // quarter-second PCM fixture. A movie timescale of 30 quantizes the
        // audio edit boundary and defeats the exact-range preservation check.
        movie.timescale = hdrBoundaryContainerTimescale
        movie.metadata = assetMetadata()
        let mediaDataStorage = AVMediaDataStorage(
            url: outputURL,
            options: nil
        )
        movie.defaultMediaDataStorage = mediaDataStorage
        guard let destinationVideo = movie.addMutableTrack(
            withMediaType: .video,
            copySettingsFrom: sourceVideo,
            options: nil
        ) else {
            throw TrackMigrationFixtureErrorV4.invalidFixture(
                "HDR boundary mutable movie rejected its video track."
            )
        }
        destinationVideo.mediaDataStorage = mediaDataStorage
        destinationVideo.timescale = frameRate
        try requireHDRBoundaryStorageBinding(
            movie: movie,
            track: destinationVideo,
            expectedURL: outputURL,
            stage: "final fixture video storage"
        )

        let reader = try AVAssetReader(asset: videoAsset)
        let output = AVAssetReaderTrackOutput(
            track: sourceVideo,
            outputSettings: nil
        )
        output.alwaysCopiesSampleData = true
        guard reader.canAdd(output) else {
            throw TrackMigrationFixtureErrorV4.invalidFixture(
                "HDR boundary mutable movie reader rejected compressed video."
            )
        }
        reader.add(output)
        guard reader.startReading() else {
            throw TrackMigrationFixtureErrorV4.writer(
                reader.error?.localizedDescription
                    ?? "HDR boundary mutable movie reader did not start."
            )
        }
        defer {
            if reader.status == .reading { reader.cancelReading() }
        }
        var concreteOrdinal = 0
        while let sample = output.copyNextSampleBuffer() {
            let sampleCount = CMSampleBufferGetNumSamples(sample)
            if sampleCount == 0 { continue }
            guard sampleCount == 1,
                  concreteOrdinal < hdrBoundaryStoredFrameCount,
                  CMSampleBufferDataIsReady(sample),
                  let sampleFormat = CMSampleBufferGetFormatDescription(sample),
                  CMFormatDescriptionEqual(
                    sampleFormat,
                    otherFormatDescription: videoFormat
                  ) else {
                throw TrackMigrationFixtureErrorV4.invalidFixture(
                    "HDR boundary mutable movie observed an invalid raw "
                        + "compressed sample at ordinal \(concreteOrdinal)."
                )
            }
            let retimed = try retimeHDRBoundaryCompressedSample(
                sample,
                ordinal: concreteOrdinal
            )
            let rewritten = try AVFoundationHDRMetadataAdapterV4
                .insertingHDR10PlusMetadata(hdr10Plus, into: retimed)
            guard try AVFoundationHDRMetadataAdapterV4
                    .compressedHDR10PlusMetadata(
                        from: rewritten.sampleBuffer
                    ) == hdr10Plus else {
                throw TrackMigrationFixtureErrorV4.invalidFixture(
                    "HDR boundary in-band HDR injection failed at ordinal "
                        + "\(concreteOrdinal)."
                )
            }
            let expectedDecode = CMTime(
                value: CMTimeValue(concreteOrdinal),
                timescale: frameRate
            )
            let expectedPresentation: CMTime
            if concreteOrdinal == 60 {
                expectedPresentation = CMTime(value: 90, timescale: frameRate)
            } else if concreteOrdinal == 61 {
                expectedPresentation = CMTime(value: 91, timescale: frameRate)
            } else {
                expectedPresentation = expectedDecode
            }
            let ready = CMReadySampleBuffer<CMSampleBuffer.DynamicContent>(
                unsafeBuffer: rewritten.sampleBuffer
            )
            let appended: (decodeTime: CMTime, presentationTime: CMTime)
            do {
                appended = try destinationVideo.append(ready)
            } catch {
                throw TrackMigrationFixtureErrorV4.writer(
                    "HDR boundary mutable-movie append failed at ordinal "
                        + "\(concreteOrdinal): "
                        + diagnosticErrorChain(error)
                )
            }
            guard exactlyEqual(appended.decodeTime, expectedDecode),
                  exactlyEqual(
                    appended.presentationTime,
                    expectedPresentation
                  ) else {
                throw TrackMigrationFixtureErrorV4.invalidFixture(
                    "HDR boundary mutable movie append timing changed at "
                        + "ordinal \(concreteOrdinal): DTS "
                        + "\(describe(appended.decodeTime)), PTS "
                        + "\(describe(appended.presentationTime))."
                )
            }
            concreteOrdinal += 1
        }
        guard reader.status == .completed,
              concreteOrdinal == hdrBoundaryStoredFrameCount else {
            throw TrackMigrationFixtureErrorV4.invalidFixture(
                "HDR boundary mutable movie did not append all 62 stored "
                    + "samples."
            )
        }

        let mediaRange = CMTimeRange(
            start: .zero,
            duration: CMTime(value: 91, timescale: frameRate)
        )
        let targetRange = CMTimeRange(
            start: primaryStart,
            duration: mediaRange.duration
        )
        guard destinationVideo.insertMediaTimeRange(
            mediaRange,
            into: targetRange
        ) else {
            throw TrackMigrationFixtureErrorV4.invalidFixture(
                "HDR boundary mutable movie rejected its exact media mapping."
            )
        }
        guard let destinationAudio = movie.addMutableTrack(
            withMediaType: .audio,
            copySettingsFrom: sourceAudio,
            options: nil
        ) else {
            throw TrackMigrationFixtureErrorV4.invalidFixture(
                "HDR boundary mutable movie rejected its audio track."
            )
        }
        destinationAudio.mediaDataStorage = mediaDataStorage
        do {
            try destinationAudio.insertTimeRange(
                audioRange,
                of: sourceAudio,
                at: .zero,
                copySampleData: true
            )
        } catch {
            throw TrackMigrationFixtureErrorV4.writer(
                "HDR boundary audio sample copy failed: "
                    + diagnosticErrorChain(error)
            )
        }
        do {
            try movie.writeHeader(
                to: outputURL,
                fileType: .mov,
                options: .addMovieHeaderToDestination
            )
        } catch {
            throw TrackMigrationFixtureErrorV4.writer(
                "HDR boundary AddMovieHeader write failed: "
                    + diagnosticErrorChain(error)
            )
        }
    }

    private static func createOwnerOnlyEmptyStorageFile(
        at url: URL
    ) throws {
        let descriptor = Darwin.open(
            url.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else {
            throw TrackMigrationFixtureErrorV4.writer(
                "Owner-only media storage creation failed: "
                    + String(cString: strerror(errno))
            )
        }
        let closeResult = Darwin.close(descriptor)
        guard closeResult == 0 else {
            throw TrackMigrationFixtureErrorV4.writer(
                "Owner-only media storage close failed: "
                    + String(cString: strerror(errno))
            )
        }
        try requireOwnedMode(url, mode: 0o600)
    }

    @available(macOS 26.0, *)
    private static func requireHDRBoundaryStorageBinding(
        movie: AVMutableMovie,
        track: AVMutableMovieTrack,
        expectedURL: URL,
        stage: String
    ) throws {
        guard let movieStorage = movie.defaultMediaDataStorage,
              let movieURL = movieStorage.url(),
              let trackStorage = track.mediaDataStorage,
              let trackURL = trackStorage.url(),
              movieURL.standardizedFileURL
                == expectedURL.standardizedFileURL,
              trackURL.standardizedFileURL
                == expectedURL.standardizedFileURL else {
            throw TrackMigrationFixtureErrorV4.invalidFixture(
                "\(stage) did not retain its exact explicit storage URL."
            )
        }
        try requireOwnedMode(
            expectedURL.deletingLastPathComponent(),
            mode: 0o700
        )
        try requireOwnedMode(expectedURL, mode: 0o600)
    }

    private static func retimeHDRBoundaryCompressedSample(
        _ sample: CMSampleBuffer,
        ordinal: Int
    ) throws -> CMSampleBuffer {
        guard CMSampleBufferGetNumSamples(sample) == 1,
              (0..<hdrBoundaryStoredFrameCount).contains(ordinal) else {
            throw TrackMigrationFixtureErrorV4.invalidFixture(
                "HDR boundary retime received an invalid concrete sample."
            )
        }
        let decodeTime = CMTime(
            value: CMTimeValue(ordinal),
            timescale: frameRate
        )
        let rawPresentation = CMSampleBufferGetPresentationTimeStamp(sample)
        let rawDecode = CMSampleBufferGetDecodeTimeStamp(sample)
        let rawDuration = CMSampleBufferGetDuration(sample)
        let frameDuration = CMTime(value: 1, timescale: frameRate)
        guard rawPresentation.isNumeric,
              rawDecode.isNumeric,
              rawDuration.isNumeric,
              !rawPresentation.flags.contains(.hasBeenRounded),
              !rawDecode.flags.contains(.hasBeenRounded),
              !rawDuration.flags.contains(.hasBeenRounded),
              exactlyEqual(rawPresentation, decodeTime),
              exactlyEqual(rawDecode, decodeTime),
              exactlyEqual(rawDuration, frameDuration),
              hdrBoundarySampleIsSync(sample) else {
            throw TrackMigrationFixtureErrorV4.invalidFixture(
                "HDR boundary encoder timing/sync drifted at ordinal \(ordinal): "
                    + "PTS \(describe(rawPresentation)), DTS "
                    + "\(describe(rawDecode)), duration "
                    + "\(describe(rawDuration)), sync "
                    + "\(hdrBoundarySampleIsSync(sample))."
            )
        }
        guard ordinal >= 60 else { return sample }
        let presentationValue: CMTimeValue = ordinal == 60 ? 90 : 91
        var timing = CMSampleTimingInfo(
            duration: rawDuration,
            presentationTimeStamp: CMTime(
                value: presentationValue,
                timescale: frameRate
            ),
            decodeTimeStamp: rawDecode
        )
        var retimed: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sample,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &retimed
        )
        guard status == noErr, let retimed else {
            throw TrackMigrationFixtureErrorV4.coreMedia(status)
        }
        return retimed
    }

    private static func requireHDRBoundaryMutableMovieAsset(
        at url: URL,
        audioRange: CMTimeRange,
        primaryStart: CMTime,
        expectedMetadata: HDRFormatMetadataV4,
        hdr10Plus: HDR10PlusMetadataV4,
        expectedMediaTimes: [CMTime],
        stage: String
    ) async throws {
        let asset = AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let allTracks = try await asset.load(.tracks)
        guard allTracks.count == 2,
              videoTracks.count == 1, let video = videoTracks.first,
              audioTracks.count == 1, let audio = audioTracks.first else {
            throw TrackMigrationFixtureErrorV4.invalidFixture(
                "\(stage) requires exactly one video and one audio track."
            )
        }
        let mediaDuration = CMTime(value: 91, timescale: frameRate)
        let expectedFullRange = CMTimeRange(
            start: .zero,
            duration: CMTimeAdd(primaryStart, mediaDuration)
        )
        let videoRange = try await video.load(.timeRange)
        let segments = try await video.load(.segments)
        guard exactlyEqualFrameRange(videoRange, expectedFullRange),
              segments.count == 2,
              segments[0].isEmpty,
              !segments[1].isEmpty,
              exactlyEqualFrameRange(
                segments[0].timeMapping.target,
                CMTimeRange(start: .zero, duration: primaryStart)
              ),
              exactlyEqualFrameRange(
                segments[1].timeMapping.source,
                CMTimeRange(start: .zero, duration: mediaDuration)
              ),
              exactlyEqualFrameRange(
                segments[1].timeMapping.target,
                CMTimeRange(start: primaryStart, duration: mediaDuration)
              ) else {
            throw TrackMigrationFixtureErrorV4.invalidFixture(
                "\(stage) did not retain exactly one leading empty edit and "
                    + "one unscaled nonempty video mapping."
            )
        }
        let observedAudioRange = try await audio.load(.timeRange)
        guard exactSemanticTimeRangeEqual(observedAudioRange, audioRange) else {
            throw TrackMigrationFixtureErrorV4.invalidFixture(
                "\(stage) changed the exact audio range copied at target zero."
            )
        }
        try requireHDRBoundaryObservations(
            try await hdr10PlusVideoObservations(at: url),
            expectedTimes: expectedMediaTimes,
            expectedReaderReportedDurations:
                hdrBoundaryReaderReportedDurations(),
            expectedMetadata: hdr10Plus,
            expectedFormatMetadata: expectedMetadata,
            stage: stage
        )
        let cursor = try await hdrBoundaryCursorGeneratorObservation(
            at: url,
            expectedPresentationTimes: expectedMediaTimes,
            expectedReaderReportedDurations:
                hdrBoundaryReaderReportedDurations(),
            expectedMetadata: hdr10Plus
        )
        guard cursor.facts.count == hdrBoundaryFrameCount else {
            throw TrackMigrationFixtureErrorV4.invalidFixture(
                "\(stage) cursor/generator exposed the hidden sentinel."
            )
        }
        let frameStart = try hdrBoundaryFrameDomainStart(primaryStart)
        try await requireHDRBoundaryDecodedP010Legal(
            at: url,
            expectedMetadata: expectedMetadata,
            expectedPresentationTimes: expectedMediaTimes.map {
                CMTimeConvertScale(
                    CMTimeAdd($0, frameStart),
                    timescale: hdrBoundaryContainerTimescale,
                    method: .default
                )
            },
            readerTimeRange: CMTimeRange(
                start: primaryStart,
                duration: mediaDuration
            )
        )
    }

    private static func requireOwnedMode(_ url: URL, mode: Int) throws {
        let attributes = try FileManager.default.attributesOfItem(
            atPath: url.path
        )
        let observedMode = (attributes[.posixPermissions] as? NSNumber)?
            .intValue ?? -1
        let owner = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value
        guard observedMode & 0o777 == mode, owner == getuid() else {
            throw TrackMigrationFixtureErrorV4.invalidFixture(
                "HDR boundary private path ownership/mode differs at "
                    + "\(url.lastPathComponent): owner "
                    + "\(String(describing: owner)), mode \(observedMode)."
            )
        }
    }

    private static func diagnosticErrorChain(_ error: Error) -> String {
        "reflected="
            + renderDiagnosticValue(String(reflecting: error), depth: 0)
            + " nsError=("
            + renderDiagnosticNSError(error as NSError, depth: 0)
            + ")"
    }

    private static func renderDiagnosticNSError(
        _ error: NSError,
        depth: Int
    ) -> String {
        guard depth < 8 else { return "<underlying-depth-limit>" }
        let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
        let entries = error.userInfo
            .filter { String(describing: $0.key) != NSUnderlyingErrorKey }
            .map { key, value in
                "\(String(describing: key))="
                    + renderDiagnosticValue(value, depth: depth + 1)
            }
            .sorted()
        var result = "domain=\(error.domain) code=\(error.code) userInfo={"
            + entries.joined(separator: ",") + "}"
        if let underlying {
            result += " underlying=("
                + renderDiagnosticNSError(underlying, depth: depth + 1)
                + ")"
        }
        return result
    }

    private static func renderDiagnosticValue(
        _ value: Any,
        depth: Int
    ) -> String {
        if let error = value as? NSError {
            return renderDiagnosticNSError(error, depth: depth)
        }
        if value is URL || value is NSURL { return "<url-redacted>" }
        if let data = value as? Data {
            return "<data-redacted-length=\(data.count)>"
        }
        if let values = value as? [Any] {
            return "[" + values.map {
                renderDiagnosticValue($0, depth: depth + 1)
            }.joined(separator: ",") + "]"
        }
        let description = String(describing: value)
        if description.contains("file://")
            || description.contains("/Users/")
            || description.contains("/private/")
            || description.contains("/tmp/") {
            return "<path-containing-value-redacted>"
        }
        return description
    }

    private static func exactlyEqualFrameRange(
        _ lhs: CMTimeRange,
        _ rhs: CMTimeRange
    ) -> Bool {
        guard let lhsStart = try? hdrBoundaryFrameDomainStart(lhs.start),
              let lhsDuration = try? hdrBoundaryFrameDomainStart(lhs.duration),
              let rhsStart = try? hdrBoundaryFrameDomainStart(rhs.start),
              let rhsDuration = try? hdrBoundaryFrameDomainStart(rhs.duration)
        else { return false }
        return exactlyEqual(lhsStart, rhsStart)
            && exactlyEqual(lhsDuration, rhsDuration)
    }

    private static func exactSemanticTimeRangeEqual(
        _ lhs: CMTimeRange,
        _ rhs: CMTimeRange
    ) -> Bool {
        lhs.start.isNumeric
            && lhs.duration.isNumeric
            && rhs.start.isNumeric
            && rhs.duration.isNumeric
            && !lhs.start.flags.contains(.hasBeenRounded)
            && !lhs.duration.flags.contains(.hasBeenRounded)
            && !rhs.start.flags.contains(.hasBeenRounded)
            && !rhs.duration.flags.contains(.hasBeenRounded)
            && CMTimeCompare(lhs.start, rhs.start) == 0
            && CMTimeCompare(lhs.duration, rhs.duration) == 0
    }

    private static func hdrBoundaryFormatMetadata() throws
        -> HDRFormatMetadataV4 {
        let primaries = [
            try HDRChromaticityV4(x: 8_500, y: 39_850, label: "green"),
            try HDRChromaticityV4(x: 6_550, y: 2_300, label: "blue"),
            try HDRChromaticityV4(x: 35_400, y: 14_600, label: "red")
        ]
        return HDRFormatMetadataV4(
            signal: try HDRSignalV4(
                storage: .p010VideoRange10Bit,
                transferFunction: .pq
            ),
            staticMetadata: HDRStaticMetadataV4(
                masteringDisplayColorVolume:
                    try MasteringDisplayColorVolumeV4(
                        displayPrimaries: primaries,
                        whitePoint: HDRChromaticityV4(
                            x: 15_635,
                            y: 16_450,
                            label: "white"
                        ),
                        maximumDisplayMasteringLuminance: 10_000_000,
                        minimumDisplayMasteringLuminance: 50
                    ),
                contentLightLevelInfo: try ContentLightLevelInfoV4(
                    maximumContentLightLevel: 1_000,
                    maximumFrameAverageLightLevel: 400
                ),
                ambientViewingEnvironment: try AmbientViewingEnvironmentV4(
                    ambientIlluminance: 123_456,
                    ambientLight: HDRChromaticityV4(
                        x: 15_635,
                        y: 16_450,
                        label: "ambient"
                    )
                )
            )
        )
    }

    private static func hdrBoundaryHDR10PlusMetadata() throws
        -> HDR10PlusMetadataV4 {
        try HDR10PlusMetadataV4(ituTT35Payload: Data([
            0xB5, 0x00, 0x3C, 0x00, 0x01, 0x04, 0x01, 0x40,
            0x00, 0x0C, 0x80, 0x3C, 0xB0, 0x19, 0xBD, 0x0D,
            0x80, 0x00, 0x41, 0xE4, 0x08, 0x00, 0x00, 0x28,
            0x5F, 0x00, 0x50, 0x01, 0x70, 0xC8, 0x00, 0x05,
            0x90, 0x00, 0x12, 0x58, 0x01, 0xAE, 0xD0, 0x0B,
            0x5A, 0xF8, 0x1B, 0xE3, 0x18, 0x5B, 0x4C, 0x00,
            0x42, 0x90, 0x3C, 0x24, 0x8F, 0x4A, 0x9B, 0xF9,
            0x42, 0xDB, 0xD8, 0x37, 0xBE, 0x57, 0xAA, 0x00
        ]))
    }

    private static func fillHDRBoundaryP010(
        _ buffer: CVPixelBuffer,
        frame: Int
    ) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        for plane in 0..<2 {
            let planeWidth = CVPixelBufferGetWidthOfPlane(buffer, plane)
            let planeHeight = CVPixelBufferGetHeightOfPlane(buffer, plane)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
                / MemoryLayout<UInt16>.stride
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)?
                .assumingMemoryBound(to: UInt16.self) else { continue }
            let components = planeWidth * (plane == 0 ? 1 : 2)
            for y in 0..<planeHeight {
                for x in 0..<components {
                    let code: Int
                    if plane == 0 {
                        code = 384 + ((x * 3 + y * 5 + frame * 7) % 128)
                    } else {
                        let baseCode = x & 1 == 0 ? 448 : 576
                        code = baseCode + ((x * 3 + y * 5 + frame * 7) % 64)
                    }
                    base[y * stride + x] = UInt16(code << 6)
                }
            }
        }
    }

    static func makeReencodedVideo(
        source sourceURL: URL,
        at url: URL,
        normalizePresentationToZero: Bool = false
    ) async throws {
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
            outputSettings: videoOutputSettings()
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
        var presentationOrigin: CMTime?
        while let sample = output.copyNextSampleBuffer() {
            let sampleCount = CMSampleBufferGetNumSamples(sample)
            guard sampleCount > 0 else { continue }
            let writerSample: CMSampleBuffer
            if normalizePresentationToZero {
                guard sampleCount == 1 else {
                    throw TrackMigrationFixtureErrorV4.invalidFixture(
                        "Normalized calibration video requires one sample per buffer."
                    )
                }
                var timing = CMSampleTimingInfo.invalid
                let timingStatus = CMSampleBufferGetSampleTimingInfo(
                    sample,
                    at: 0,
                    timingInfoOut: &timing
                )
                guard timingStatus == noErr,
                      timing.presentationTimeStamp.isNumeric,
                      timing.presentationTimeStamp.timescale > 0,
                      timing.presentationTimeStamp.epoch == 0,
                      !timing.presentationTimeStamp.flags.contains(
                        .hasBeenRounded
                      ) else {
                    throw TrackMigrationFixtureErrorV4.invalidFixture(
                        "Calibration video has inexact presentation timing."
                    )
                }
                let origin = presentationOrigin
                    ?? timing.presentationTimeStamp
                presentationOrigin = origin
                timing.presentationTimeStamp = CMTimeSubtract(
                    timing.presentationTimeStamp,
                    origin
                )
                guard timing.presentationTimeStamp.isNumeric,
                      timing.presentationTimeStamp.timescale > 0,
                      timing.presentationTimeStamp.epoch == 0,
                      !timing.presentationTimeStamp.flags.contains(
                        .hasBeenRounded
                      ),
                      CMTimeCompare(
                        timing.presentationTimeStamp,
                        .zero
                      ) >= 0 else {
                    throw TrackMigrationFixtureErrorV4.invalidFixture(
                        "Calibration video could not be normalized exactly."
                    )
                }
                var normalized: CMSampleBuffer?
                let copyStatus = CMSampleBufferCreateCopyWithNewTiming(
                    allocator: kCFAllocatorDefault,
                    sampleBuffer: sample,
                    sampleTimingEntryCount: 1,
                    sampleTimingArray: &timing,
                    sampleBufferOut: &normalized
                )
                guard copyStatus == noErr, let normalized else {
                    throw TrackMigrationFixtureErrorV4.coreMedia(copyStatus)
                }
                writerSample = normalized
            } else {
                writerSample = sample
            }
            try await waitUntilReady(input, writer: writer)
            guard input.append(writerSample) else {
                throw TrackMigrationFixtureErrorV4.writer(
                    writer.error?.localizedDescription
                        ?? "Calibration append failed."
                )
            }
        }
        guard !normalizePresentationToZero || presentationOrigin != nil else {
            throw TrackMigrationFixtureErrorV4.invalidFixture(
                "Calibration video contained no concrete samples to normalize."
            )
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

    static func makeLeadingEmptyVideoEditedMovie(
        source sourceURL: URL,
        at outputURL: URL
    ) async throws {
        try FileManager.default.copyItem(at: sourceURL, to: outputURL)
        let movie = AVMutableMovie(
            url: outputURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        guard let video = movie.tracks(withMediaType: .video).first else {
            throw TrackMigrationFixtureErrorV4.invalidFixture(
                "Leading-empty source has no video track."
            )
        }
        let mediaRange = video.mediaPresentationTimeRange
        guard mediaRange.duration.isNumeric,
              mediaRange.duration.value > 0 else {
            throw TrackMigrationFixtureErrorV4.invalidFixture(
                "Leading-empty source has no video media range."
            )
        }
        video.removeTimeRange(video.timeRange)
        guard video.mediaPresentationTimeRange == mediaRange else {
            throw TrackMigrationFixtureErrorV4.invalidFixture(
                "Leading-empty edit changed the video media table."
            )
        }
        let leadingEmptyDuration = CMTime(value: 1, timescale: frameRate)
        video.insertEmptyTimeRange(CMTimeRange(
            start: .zero,
            duration: leadingEmptyDuration
        ))
        guard video.insertMediaTimeRange(
            mediaRange,
            into: CMTimeRange(
                start: leadingEmptyDuration,
                duration: mediaRange.duration
            )
        ) else {
            throw TrackMigrationFixtureErrorV4.invalidFixture(
                "Could not insert the leading-empty video media edit."
            )
        }
        try movie.writeHeader(
            to: outputURL,
            fileType: .mov,
            options: .addMovieHeaderToDestination
        )
    }

    static func makeNonzeroSourceVideoEditedMovie(
        source sourceURL: URL,
        at outputURL: URL
    ) async throws {
        try FileManager.default.copyItem(at: sourceURL, to: outputURL)
        let movie = AVMutableMovie(
            url: outputURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        guard let video = movie.tracks(withMediaType: .video).first else {
            throw TrackMigrationFixtureErrorV4.invalidFixture(
                "Nonzero-origin source has no video track."
            )
        }
        let mediaRange = video.mediaPresentationTimeRange
        let frame = CMTime(value: 1, timescale: frameRate)
        let selectedStart = CMTimeAdd(mediaRange.start, frame)
        let selectedDuration = CMTimeSubtract(mediaRange.duration, frame)
        let selectedRange = CMTimeRange(
            start: selectedStart,
            duration: selectedDuration
        )
        guard mediaRange.start.isNumeric,
              mediaRange.duration.isNumeric,
              mediaRange.start.epoch == 0,
              mediaRange.duration.epoch == 0,
              !mediaRange.start.flags.contains(.hasBeenRounded),
              !mediaRange.duration.flags.contains(.hasBeenRounded),
              selectedRange.isValid,
              selectedStart.isNumeric,
              selectedDuration.isNumeric,
              selectedStart.epoch == 0,
              selectedDuration.epoch == 0,
              !selectedStart.flags.contains(.hasBeenRounded),
              !selectedDuration.flags.contains(.hasBeenRounded),
              CMTimeCompare(selectedStart, .zero) > 0,
              CMTimeCompare(selectedDuration, .zero) > 0 else {
            throw TrackMigrationFixtureErrorV4.invalidFixture(
                "Nonzero-origin source has no exact one-frame subrange."
            )
        }
        video.removeTimeRange(video.timeRange)
        guard video.mediaPresentationTimeRange == mediaRange else {
            throw TrackMigrationFixtureErrorV4.invalidFixture(
                "Nonzero-origin edit changed the video media table."
            )
        }
        guard video.insertMediaTimeRange(
            selectedRange,
            into: CMTimeRange(start: .zero, duration: selectedDuration)
        ) else {
            throw TrackMigrationFixtureErrorV4.invalidFixture(
                "Could not insert the nonzero-origin video media edit."
            )
        }
        try movie.writeHeader(
            to: outputURL,
            fileType: .mov,
            options: .addMovieHeaderToDestination
        )
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
        incompatibleAudioTransition: Bool = false,
        videoFrameCount: Int = frameCount,
        videoMediaTimeScale: CMTimeScale = 600,
        videoFrameDuration: CMTime = CMTime(
            value: 1,
            timescale: frameRate
        ),
        videoExpectedFrameRate: Double = Double(frameRate)
    ) async throws {
        guard videoFrameCount > 0,
              videoFrameDuration.isNumeric,
              videoFrameDuration.value > 0,
              videoExpectedFrameRate > 0 else {
            throw TrackMigrationFixtureErrorV4.invalidFixture(
                "Video cadence must be positive."
            )
        }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.metadata = assetMetadata()
        let firstVideo = makeVideoLane(
            seed: 17,
            title: "primary-video",
            mediaTimeScale: videoMediaTimeScale,
            expectedFrameRate: videoExpectedFrameRate
        )
        let secondVideo = makeVideoLane(
            seed: 113,
            title: "alternate-video",
            mediaTimeScale: videoMediaTimeScale,
            expectedFrameRate: videoExpectedFrameRate
        )
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

        for frameIndex in 0..<videoFrameCount {
            let time = CMTimeMultiply(
                videoFrameDuration,
                multiplier: Int32(frameIndex)
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
            : CMTimeMultiply(
                videoFrameDuration,
                multiplier: Int32(videoFrameCount)
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

    static func makeSingletonAudioGroupMovie(at url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let video = makeVideoLane(seed: 17, title: "primary-video")
        let audioFormat = try makeAudioFormatDescription()
        let audio = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000
            ],
            sourceFormatHint: audioFormat
        )
        audio.languageCode = "eng"
        audio.extendedLanguageTag = "en-US"
        audio.metadata = trackMetadata(title: "English")

        for input in [video.input, audio] {
            guard writer.canAdd(input) else {
                throw TrackMigrationFixtureErrorV4.writer(
                    "Writer rejected singleton-group fixture input."
                )
            }
            writer.add(input)
        }
        let group = AVAssetWriterInputGroup(
            inputs: [audio],
            defaultInput: audio
        )
        guard writer.canAdd(group) else {
            throw TrackMigrationFixtureErrorV4.writer(
                "Writer rejected singleton audio group."
            )
        }
        writer.add(group)
        guard writer.startWriting() else {
            throw TrackMigrationFixtureErrorV4.writer(
                writer.error?.localizedDescription ?? "startWriting failed"
            )
        }
        writer.startSession(atSourceTime: .zero)

        try await append(
            try makeAudioSampleBuffer(format: audioFormat, amplitude: 700),
            to: audio,
            writer: writer
        )
        audio.markAsFinished()
        for frameIndex in 0..<3 {
            try await appendFrame(
                lane: video,
                frameIndex: frameIndex,
                time: CMTime(
                    value: CMTimeValue(frameIndex),
                    timescale: frameRate
                ),
                writer: writer
            )
        }
        video.input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 3, timescale: frameRate))
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

    static func makeAACMovie(
        at url: URL,
        fileType: AVFileType
    ) async throws {
        let sampleRate = 48_000
        let channelCount: UInt32 = 2
        let sourceFormat = try makeAudioFormatDescription(
            sampleRate: Double(sampleRate),
            channels: channelCount,
            channelLayoutTag: kAudioChannelLayoutTag_Stereo
        )
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        let input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: Int(channelCount),
                AVEncoderBitRateKey: 128_000
            ],
            sourceFormatHint: sourceFormat
        )
        guard writer.canAdd(input) else {
            throw TrackMigrationFixtureErrorV4.writer(
                "Writer rejected AAC fixture input."
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
            try makeAudioSampleBuffer(
                format: sourceFormat,
                amplitude: 700
            ),
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
        mediaType: AVMediaType = .video,
        mediaTimeScale: CMTimeScale = 600,
        expectedFrameRate: Double = Double(frameRate)
    ) -> VideoLane {
        let input = AVAssetWriterInput(
            mediaType: mediaType,
            outputSettings: videoOutputSettings(
                expectedFrameRate: expectedFrameRate
            )
        )
        input.mediaTimeScale = mediaTimeScale
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

    private static func videoOutputSettings(
        expectedFrameRate: Double = Double(frameRate)
    ) -> [String: Any] {
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
                AVVideoExpectedSourceFrameRateKey: expectedFrameRate,
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

private struct HDR10PlusVideoObservationsV4: Sendable {
    let zeroSampleMarkerCount: Int
    let presentationTimes: [CMTime]
    let decodeTimes: [CMTime]
    let durations: [CMTime]
    let syncSamples: [Bool]
    let metadata: [HDR10PlusMetadataV4?]
    let codecType: CMVideoCodecType
    let formatMetadata: HDRFormatMetadataV4?
}

private struct HDRBoundaryCursorGeneratorSampleFactV4: Sendable {
    let cursorPresentationTime: CMTime
    let cursorDecodeTime: CMTime
    let cursorDuration: CMTime
    let generatedPresentationTime: CMTime
    let generatedDecodeTime: CMTime
    let generatedDuration: CMTime
    let generatedOutputPresentationTime: CMTime
    let generatedOutputDuration: CMTime
    let generatedDataByteCount: Int
    let trimDurationAtStart: CMTime?
    let trimDurationAtEnd: CMTime?
    let cursorIsFullSync: Bool
    let cursorIsPartialSync: Bool
    let cursorIsDroppable: Bool
    let cursorIndicatesHasDependentSamples: Bool
    let cursorHasDependentSamples: Bool
    let cursorIndicatesDependsOnOthers: Bool
    let cursorDependsOnOthers: Bool
    let cursorIndicatesHasRedundantCoding: Bool
    let cursorHasRedundantCoding: Bool
    let cursorSamplesRequiredForDecoderRefresh: Int
    let generatedIsSync: Bool
    let generatedDependsOnOthers: Bool?
    let generatedIsDependedOnByOthers: Bool?
    let generatedHasRedundantCoding: Bool?

    var diagnostic: String {
        [
            "cursorPTS=\(hdrBoundaryDescribeTime(cursorPresentationTime))",
            "cursorDTS=\(hdrBoundaryDescribeTime(cursorDecodeTime))",
            "cursorDuration=\(hdrBoundaryDescribeTime(cursorDuration))",
            "generatedPTS=\(hdrBoundaryDescribeTime(generatedPresentationTime))",
            "generatedDTS=\(hdrBoundaryDescribeTime(generatedDecodeTime))",
            "generatedDuration=\(hdrBoundaryDescribeTime(generatedDuration))",
            "generatedOutputPTS=\(hdrBoundaryDescribeTime(generatedOutputPresentationTime))",
            "generatedOutputDuration=\(hdrBoundaryDescribeTime(generatedOutputDuration))",
            "generatedBytes=\(generatedDataByteCount)",
            "trimStart=\(trimDurationAtStart.map(hdrBoundaryDescribeTime) ?? "absent")",
            "trimEnd=\(trimDurationAtEnd.map(hdrBoundaryDescribeTime) ?? "absent")",
            "cursorSync=full:\(cursorIsFullSync),partial:\(cursorIsPartialSync),droppable:\(cursorIsDroppable)",
            "cursorDependency=indicatesHasDependents:\(cursorIndicatesHasDependentSamples),hasDependents:\(cursorHasDependentSamples),indicatesDepends:\(cursorIndicatesDependsOnOthers),depends:\(cursorDependsOnOthers),indicatesRedundant:\(cursorIndicatesHasRedundantCoding),redundant:\(cursorHasRedundantCoding),refresh:\(cursorSamplesRequiredForDecoderRefresh)",
            "generatedDependency=sync:\(generatedIsSync),depends:\(String(describing: generatedDependsOnOthers)),dependedOn:\(String(describing: generatedIsDependedOnByOthers)),redundant:\(String(describing: generatedHasRedundantCoding))"
        ].joined(separator: " ")
    }
}

private struct HDRBoundaryCursorGeneratorObservationV4: Sendable {
    let facts: [HDRBoundaryCursorGeneratorSampleFactV4]

    var diagnostic: String {
        facts.enumerated().map { ordinal, fact in
            "ordinal=\(ordinal) \(fact.diagnostic)"
        }.joined(separator: "\n")
    }
}

private func hdrBoundaryCursorGeneratorObservation(
    at url: URL,
    expectedPresentationTimes: [CMTime],
    expectedReaderReportedDurations: [CMTime],
    expectedMetadata: HDR10PlusMetadataV4
) async throws -> HDRBoundaryCursorGeneratorObservationV4 {
    guard !expectedPresentationTimes.isEmpty,
          expectedReaderReportedDurations.count
            == expectedPresentationTimes.count else {
        throw TrackMigrationFixtureErrorV4.invalidFixture(
            "Cursor diagnostic requires matching nonempty timing domains."
        )
    }
    let asset = AVURLAsset(
        url: url,
        options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
    )
    let tracks = try await asset.loadTracks(withMediaType: .video)
    guard tracks.count == 1, let track = tracks.first,
          try await track.load(.canProvideSampleCursors) else {
        throw TrackMigrationFixtureErrorV4.invalidFixture(
            "Composed HDR track cannot provide sample cursors."
        )
    }
    let formats = try await track.load(.formatDescriptions)
    guard formats.count == 1, let trackFormat = formats.first,
          CMFormatDescriptionGetMediaSubType(trackFormat)
            == kCMVideoCodecType_HEVC else {
        throw TrackMigrationFixtureErrorV4.invalidFixture(
            "Cursor diagnostic requires one HEVC format description."
        )
    }
    guard let cursor = track.makeSampleCursor(
        presentationTimeStamp: expectedPresentationTimes[0]
    ) else {
        throw TrackMigrationFixtureErrorV4.invalidFixture(
            "Composed HDR track did not create its first sample cursor."
        )
    }
    let generator = AVSampleBufferGenerator(asset: asset, timebase: nil)
    var facts: [HDRBoundaryCursorGeneratorSampleFactV4] = []
    facts.reserveCapacity(expectedPresentationTimes.count)

    for ordinal in expectedPresentationTimes.indices {
        let expectedPresentation = expectedPresentationTimes[ordinal]
        let expectedDecode = CMTime(
            value: CMTimeValue(ordinal),
            timescale: 30
        )
        let cursorPresentation = cursor.presentationTimeStamp
        let cursorDecode = cursor.decodeTimeStamp
        let cursorDuration = cursor.currentSampleDuration
        let expectedReaderReportedDuration =
            expectedReaderReportedDurations[ordinal]
        let cursorSync = cursor.currentSampleSyncInfo
        let cursorDependency = cursor.currentSampleDependencyInfo
        guard hdrBoundaryExactTimeEqual(
                cursorPresentation,
                expectedPresentation
              ),
              hdrBoundaryExactTimeEqual(cursorDecode, expectedDecode),
              hdrBoundaryExactTimeEqual(
                cursorDuration,
                expectedReaderReportedDuration
              ),
              cursorSync.sampleIsFullSync.boolValue,
              !cursorSync.sampleIsPartialSync.boolValue,
              cursor.samplesRequiredForDecoderRefresh == 0,
              !(cursorDependency.sampleIndicatesWhetherItDependsOnOthers
                    .boolValue
                && cursorDependency.sampleDependsOnOthers.boolValue) else {
            throw TrackMigrationFixtureErrorV4.invalidFixture(
                "Cursor timing or dependency mismatch at ordinal \(ordinal): "
                    + "PTS \(hdrBoundaryDescribeTime(cursorPresentation)), "
                    + "DTS \(hdrBoundaryDescribeTime(cursorDecode)), duration "
                    + "\(hdrBoundaryDescribeTime(cursorDuration)), fullSync "
                    + "\(cursorSync.sampleIsFullSync), partialSync "
                    + "\(cursorSync.sampleIsPartialSync), depends "
                    + "\(cursorDependency.sampleDependsOnOthers), refresh "
                    + "\(cursor.samplesRequiredForDecoderRefresh)."
            )
        }
        let cursorFormat = cursor.copyCurrentSampleFormatDescription()
        guard CMFormatDescriptionEqual(
            cursorFormat,
            otherFormatDescription: trackFormat
        ) else {
            throw TrackMigrationFixtureErrorV4.invalidFixture(
                "Cursor format changed at ordinal \(ordinal)."
            )
        }

        let request = AVSampleBufferRequest(start: cursor)
        request.direction = .none
        let generated = try generator.makeSampleBuffer(for: request)
        let sampleCount = CMSampleBufferGetNumSamples(generated)
        let generatedPresentation = CMSampleBufferGetPresentationTimeStamp(
            generated
        )
        let generatedDecode = CMSampleBufferGetDecodeTimeStamp(generated)
        let generatedDuration = CMSampleBufferGetDuration(generated)
        let generatedOutputPresentation =
            CMSampleBufferGetOutputPresentationTimeStamp(generated)
        let generatedOutputDuration = CMSampleBufferGetOutputDuration(
            generated
        )
        let generatedFormat = CMSampleBufferGetFormatDescription(generated)
        let generatedDataByteCount = CMSampleBufferGetDataBuffer(generated)
            .map(CMBlockBufferGetDataLength) ?? 0
        let trimStart = try hdrBoundaryTimeAttachment(
            generated,
            key: kCMSampleBufferAttachmentKey_TrimDurationAtStart
        )
        let trimEnd = try hdrBoundaryTimeAttachment(
            generated,
            key: kCMSampleBufferAttachmentKey_TrimDurationAtEnd
        )
        let generatedMetadata = try AVFoundationHDRMetadataAdapterV4
            .compressedHDR10PlusMetadata(from: generated)
        guard CMSampleBufferDataIsReady(generated),
              sampleCount == 1,
              generatedDataByteCount > 0,
              CMFormatDescriptionEqual(
                generatedFormat,
                otherFormatDescription: cursorFormat
              ),
              hdrBoundaryExactTimeEqual(
                generatedPresentation,
                cursorPresentation
              ),
              hdrBoundaryExactTimeEqual(generatedDecode, cursorDecode),
              hdrBoundaryExactTimeEqual(generatedDuration, cursorDuration),
              hdrBoundaryExactTimeEqual(
                generatedOutputPresentation,
                cursorPresentation
              ),
              hdrBoundaryExactTimeEqual(
                generatedOutputDuration,
                cursorDuration
              ),
              trimStart.map(hdrBoundaryIsExactZero) ?? true,
              trimEnd.map(hdrBoundaryIsExactZero) ?? true,
              hdrBoundarySampleIsSync(generated),
              generatedMetadata == expectedMetadata else {
            throw TrackMigrationFixtureErrorV4.invalidFixture(
                "Generated cursor sample mismatch at ordinal \(ordinal): "
                    + "ready \(CMSampleBufferDataIsReady(generated)), count "
                    + "\(sampleCount), bytes \(generatedDataByteCount), PTS "
                    + "\(hdrBoundaryDescribeTime(generatedPresentation)), DTS "
                    + "\(hdrBoundaryDescribeTime(generatedDecode)), duration "
                    + "\(hdrBoundaryDescribeTime(generatedDuration)), outputPTS "
                    + "\(hdrBoundaryDescribeTime(generatedOutputPresentation)), "
                    + "outputDuration "
                    + "\(hdrBoundaryDescribeTime(generatedOutputDuration)), "
                    + "sync \(hdrBoundarySampleIsSync(generated)), HDR "
                    + "\(String(describing: generatedMetadata))."
            )
        }
        let generatedAttachments =
            CMSampleBufferGetSampleAttachmentsArray(
                generated,
                createIfNecessary: false
            ) as? [[CFString: Any]]
        let generatedAttachment = generatedAttachments?.first
        facts.append(HDRBoundaryCursorGeneratorSampleFactV4(
            cursorPresentationTime: cursorPresentation,
            cursorDecodeTime: cursorDecode,
            cursorDuration: cursorDuration,
            generatedPresentationTime: generatedPresentation,
            generatedDecodeTime: generatedDecode,
            generatedDuration: generatedDuration,
            generatedOutputPresentationTime: generatedOutputPresentation,
            generatedOutputDuration: generatedOutputDuration,
            generatedDataByteCount: generatedDataByteCount,
            trimDurationAtStart: trimStart,
            trimDurationAtEnd: trimEnd,
            cursorIsFullSync: cursorSync.sampleIsFullSync.boolValue,
            cursorIsPartialSync: cursorSync.sampleIsPartialSync.boolValue,
            cursorIsDroppable: cursorSync.sampleIsDroppable.boolValue,
            cursorIndicatesHasDependentSamples:
                cursorDependency
                    .sampleIndicatesWhetherItHasDependentSamples.boolValue,
            cursorHasDependentSamples:
                cursorDependency.sampleHasDependentSamples.boolValue,
            cursorIndicatesDependsOnOthers:
                cursorDependency.sampleIndicatesWhetherItDependsOnOthers
                    .boolValue,
            cursorDependsOnOthers:
                cursorDependency.sampleDependsOnOthers.boolValue,
            cursorIndicatesHasRedundantCoding:
                cursorDependency
                    .sampleIndicatesWhetherItHasRedundantCoding.boolValue,
            cursorHasRedundantCoding:
                cursorDependency.sampleHasRedundantCoding.boolValue,
            cursorSamplesRequiredForDecoderRefresh:
                cursor.samplesRequiredForDecoderRefresh,
            generatedIsSync: hdrBoundarySampleIsSync(generated),
            generatedDependsOnOthers: generatedAttachment?[
                kCMSampleAttachmentKey_DependsOnOthers
            ] as? Bool,
            generatedIsDependedOnByOthers: generatedAttachment?[
                kCMSampleAttachmentKey_IsDependedOnByOthers
            ] as? Bool,
            generatedHasRedundantCoding: generatedAttachment?[
                kCMSampleAttachmentKey_HasRedundantCoding
            ] as? Bool
        ))

        let traversed = cursor.stepInPresentationOrder(byCount: 1)
        guard traversed == 1 else {
            throw TrackMigrationFixtureErrorV4.invalidFixture(
                "Cursor presentation-order traversal mismatch after ordinal "
                    + "\(ordinal): expected 1, observed "
                    + "\(traversed)."
            )
        }
    }
    let sentinelPresentation = CMTimeAdd(
        expectedPresentationTimes[expectedPresentationTimes.count - 1],
        expectedReaderReportedDurations[
            expectedReaderReportedDurations.count - 1
        ]
    )
    let sentinelDecode = CMTime(
        value: CMTimeValue(expectedPresentationTimes.count),
        timescale: 30
    )
    guard hdrBoundaryExactTimeEqual(
            cursor.presentationTimeStamp,
            sentinelPresentation
          ),
          hdrBoundaryExactTimeEqual(cursor.decodeTimeStamp, sentinelDecode)
    else {
        throw TrackMigrationFixtureErrorV4.invalidFixture(
            "Cursor did not retain the stored duration-lookahead sentinel."
        )
    }
    return HDRBoundaryCursorGeneratorObservationV4(facts: facts)
}

private func hdrBoundaryExactTimeEqual(
    _ lhs: CMTime,
    _ rhs: CMTime
) -> Bool {
    lhs.value == rhs.value
        && lhs.timescale == rhs.timescale
        && lhs.flags == rhs.flags
        && lhs.epoch == rhs.epoch
}

private func hdrBoundaryIsExactZero(_ time: CMTime) -> Bool {
    time.isNumeric
        && !time.flags.contains(.hasBeenRounded)
        && CMTimeCompare(time, .zero) == 0
}

private func hdrBoundaryDescribeTime(_ time: CMTime) -> String {
    "\(time.value)/\(time.timescale) epoch=\(time.epoch) "
        + "flags=\(time.flags.rawValue)"
}

private func hdrBoundaryTimeAttachment(
    _ sample: CMSampleBuffer,
    key: CFString
) throws -> CMTime? {
    var mode: CMAttachmentMode = kCMAttachmentMode_ShouldNotPropagate
    guard let raw = CMGetAttachment(
        sample,
        key: key,
        attachmentModeOut: &mode
    ) else {
        return nil
    }
    guard CFGetTypeID(raw) == CFDictionaryGetTypeID() else {
        throw TrackMigrationFixtureErrorV4.invalidFixture(
            "Cursor-generated trim attachment is not a CMTime dictionary."
        )
    }
    return CMTimeMakeFromDictionary((raw as! CFDictionary))
}

private struct DirectTimelineReaderDomainV4: Sendable {
    let decodedSampleCounts: [Int]
    let decodedTargetPresentationTimes: [CMTime]
    let decodedDurations: [CMTime]
    let canonicalMediaPresentationTimes: [CMTime]
    let compressedSampleCounts: [Int]
    let compressedMediaPresentationTimes: [CMTime]
    let compressedDurations: [CMTime]
}

private func directTimelineReaderDomain(
    at url: URL,
    targetStart: CMTime,
    targetEnd: CMTime,
    offset: CMTime,
    maximumConcreteSamples: Int
) async throws -> DirectTimelineReaderDomainV4 {
    let targetDuration = CMTimeSubtract(targetEnd, targetStart)
    guard targetStart.isNumeric,
          targetEnd.isNumeric,
          targetDuration.isNumeric,
          targetDuration.value > 0,
          maximumConcreteSamples > 0 else {
        throw TrackMigrationFixtureErrorV4.invalidFixture(
            "Direct reader-domain request is invalid."
        )
    }
    let asset = AVURLAsset(
        url: url,
        options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
    )
    let tracks = try await asset.loadTracks(withMediaType: .video)
    let track = try XCTUnwrap(tracks.first)
    let decodedReader = try AVAssetReader(asset: asset)
    let decodedOutput = AVAssetReaderTrackOutput(
        track: track,
        outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String:
                Int(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange),
            AVVideoDecompressionPropertiesKey: [
                kVTDecompressionPropertyKey_PropagatePerFrameHDRDisplayMetadata
                    as String: true
            ]
        ]
    )
    decodedOutput.alwaysCopiesSampleData = false
    guard decodedReader.canAdd(decodedOutput) else {
        throw TrackMigrationFixtureErrorV4.invalidFixture(
            "Direct decoded reader rejected the video track."
        )
    }
    decodedReader.add(decodedOutput)
    decodedReader.timeRange = CMTimeRange(
        start: targetStart,
        duration: targetDuration
    )
    guard decodedReader.startReading() else {
        throw TrackMigrationFixtureErrorV4.writer(
            decodedReader.error?.localizedDescription
                ?? "Direct decoded reader did not start."
        )
    }
    defer {
        if decodedReader.status == .reading {
            decodedReader.cancelReading()
        }
    }
    var decodedSampleCounts: [Int] = []
    var decodedTargetPresentationTimes: [CMTime] = []
    var decodedDurations: [CMTime] = []
    var canonicalMediaPresentationTimes: [CMTime] = []
    while decodedTargetPresentationTimes.count < maximumConcreteSamples,
          let sample = decodedOutput.copyNextSampleBuffer() {
        let sampleCount = CMSampleBufferGetNumSamples(sample)
        decodedSampleCounts.append(sampleCount)
        if sampleCount == 0 { continue }
        guard sampleCount == 1 else {
            throw TrackMigrationFixtureErrorV4.invalidFixture(
                "Direct decoded reader aggregated concrete samples."
            )
        }
        let targetPresentation = CMSampleBufferGetPresentationTimeStamp(
            sample
        )
        let duration = CMSampleBufferGetDuration(sample)
        let mediaPresentation = CMTimeSubtract(targetPresentation, offset)
        guard targetPresentation.isNumeric,
              mediaPresentation.isNumeric,
              !mediaPresentation.flags.contains(.hasBeenRounded) else {
            throw TrackMigrationFixtureErrorV4.invalidFixture(
                "Direct decoded reader emitted invalid presentation timing."
            )
        }
        decodedTargetPresentationTimes.append(targetPresentation)
        decodedDurations.append(duration)
        canonicalMediaPresentationTimes.append(mediaPresentation)
    }
    let decodedReaderExhausted = decodedReader.status == .completed
    guard decodedReader.status != .failed,
          decodedReader.status != .cancelled,
          !decodedTargetPresentationTimes.isEmpty else {
        throw TrackMigrationFixtureErrorV4.writer(
            decodedReader.error?.localizedDescription
                ?? "Direct decoded reader did not expose a concrete domain."
        )
    }
    if decodedReader.status == .reading {
        decodedReader.cancelReading()
    }

    let compressedReader = try AVAssetReader(asset: asset)
    let compressedOutput = AVAssetReaderTrackOutput(
        track: track,
        outputSettings: nil
    )
    compressedOutput.alwaysCopiesSampleData = false
    guard compressedReader.canAdd(compressedOutput) else {
        throw TrackMigrationFixtureErrorV4.invalidFixture(
            "Direct compressed reader rejected the video track."
        )
    }
    compressedReader.add(compressedOutput)
    compressedReader.timeRange = CMTimeRange(
        start: targetStart,
        duration: targetDuration
    )
    guard compressedReader.startReading() else {
        throw TrackMigrationFixtureErrorV4.writer(
            compressedReader.error?.localizedDescription
                ?? "Direct compressed reader did not start."
        )
    }
    var compressedSampleCounts: [Int] = []
    var compressedMediaPresentationTimes: [CMTime] = []
    var compressedDurations: [CMTime] = []
    while compressedMediaPresentationTimes.count
            < decodedTargetPresentationTimes.count,
          let sample = compressedOutput.copyNextSampleBuffer() {
        let sampleCount = CMSampleBufferGetNumSamples(sample)
        compressedSampleCounts.append(sampleCount)
        if sampleCount == 0 { continue }
        guard sampleCount == 1 else {
            throw TrackMigrationFixtureErrorV4.invalidFixture(
                "Direct compressed reader aggregated concrete samples."
            )
        }
        let presentation = CMSampleBufferGetPresentationTimeStamp(sample)
        let duration = CMSampleBufferGetDuration(sample)
        guard presentation.isNumeric,
              duration.isNumeric,
              duration.value > 0,
              !duration.flags.contains(.hasBeenRounded) else {
            throw TrackMigrationFixtureErrorV4.invalidFixture(
                "Direct compressed reader emitted nonnumeric timing."
            )
        }
        compressedMediaPresentationTimes.append(presentation)
        compressedDurations.append(duration)
    }
    if decodedReaderExhausted {
        while let sample = compressedOutput.copyNextSampleBuffer() {
            let sampleCount = CMSampleBufferGetNumSamples(sample)
            compressedSampleCounts.append(sampleCount)
            if sampleCount == 0 { continue }
            throw TrackMigrationFixtureErrorV4.invalidFixture(
                "Direct compressed reader emitted an extra concrete sample."
            )
        }
        guard compressedReader.status == .completed else {
            throw TrackMigrationFixtureErrorV4.writer(
                compressedReader.error?.localizedDescription
                    ?? "Direct compressed reader did not complete."
            )
        }
    } else {
        guard compressedReader.status != .failed,
              compressedReader.status != .cancelled else {
            throw TrackMigrationFixtureErrorV4.writer(
                compressedReader.error?.localizedDescription
                    ?? "Direct compressed reader stopped early."
            )
        }
        compressedReader.cancelReading()
    }
    return DirectTimelineReaderDomainV4(
        decodedSampleCounts: decodedSampleCounts,
        decodedTargetPresentationTimes: decodedTargetPresentationTimes,
        decodedDurations: decodedDurations,
        canonicalMediaPresentationTimes: canonicalMediaPresentationTimes,
        compressedSampleCounts: compressedSampleCounts,
        compressedMediaPresentationTimes: compressedMediaPresentationTimes,
        compressedDurations: compressedDurations
    )
}

private struct DecodedVideoSampleDomainV4: Sendable {
    let zeroSampleMarkerCount: Int
    let presentationTimes: [CMTime]
}

private func decodedVideoSampleDomain(at url: URL) async throws
    -> DecodedVideoSampleDomainV4 {
    let asset = AVURLAsset(
        url: url,
        options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
    )
    let tracks = try await asset.loadTracks(withMediaType: .video)
    let track = try XCTUnwrap(tracks.first)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(
        track: track,
        outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String:
                Int(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange),
            AVVideoDecompressionPropertiesKey: [
                kVTDecompressionPropertyKey_PropagatePerFrameHDRDisplayMetadata
                    as String: true
            ]
        ]
    )
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else {
        throw TrackMigrationFixtureErrorV4.invalidFixture(
            "Decoded-domain reader rejected the video track."
        )
    }
    reader.add(output)
    guard reader.startReading() else {
        throw TrackMigrationFixtureErrorV4.writer(
            reader.error?.localizedDescription
                ?? "Decoded-domain reader did not start."
        )
    }
    var zeroSampleMarkerCount = 0
    var presentationTimes: [CMTime] = []
    while let sample = output.copyNextSampleBuffer() {
        let sampleCount = CMSampleBufferGetNumSamples(sample)
        if sampleCount == 0 {
            zeroSampleMarkerCount += 1
            continue
        }
        guard sampleCount == 1 else {
            throw TrackMigrationFixtureErrorV4.invalidFixture(
                "Decoded-domain reader aggregated concrete samples."
            )
        }
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sample)
        guard presentationTime.isNumeric else {
            throw TrackMigrationFixtureErrorV4.invalidFixture(
                "Decoded-domain reader emitted a nonnumeric concrete PTS."
            )
        }
        presentationTimes.append(presentationTime)
    }
    guard reader.status == .completed else {
        throw TrackMigrationFixtureErrorV4.writer(
            reader.error?.localizedDescription
                ?? "Decoded-domain reader did not complete."
        )
    }
    return DecodedVideoSampleDomainV4(
        zeroSampleMarkerCount: zeroSampleMarkerCount,
        presentationTimes: presentationTimes
    )
}

private func hdr10PlusVideoObservations(at url: URL) async throws
    -> HDR10PlusVideoObservationsV4 {
    let asset = AVURLAsset(
        url: url,
        options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
    )
    let tracks = try await asset.loadTracks(withMediaType: .video)
    let track = try XCTUnwrap(tracks.first)
    let formats = try await track.load(.formatDescriptions)
    guard formats.count == 1, let format = formats.first else {
        throw TrackMigrationFixtureErrorV4.invalidFixture(
            "HDR10+ observation requires one format description."
        )
    }
    let codecType = CMFormatDescriptionGetMediaSubType(format)
    let formatMetadata = try AVFoundationHDRMetadataAdapterV4.probe(
        formatDescription: format,
        decodedStorage: .p010VideoRange10Bit
    )
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else {
        throw TrackMigrationFixtureErrorV4.invalidFixture(
            "HDR10+ observation reader rejected the video track."
        )
    }
    reader.add(output)
    guard reader.startReading() else {
        throw TrackMigrationFixtureErrorV4.writer(
            reader.error?.localizedDescription
                ?? "HDR10+ observation reader did not start."
        )
    }
    var zeroSampleMarkerCount = 0
    var presentationTimes: [CMTime] = []
    var decodeTimes: [CMTime] = []
    var durations: [CMTime] = []
    var syncSamples: [Bool] = []
    var metadata: [HDR10PlusMetadataV4?] = []
    var seen = Set<HDR10PlusPresentationTimeV4>()
    while let sample = output.copyNextSampleBuffer() {
        let sampleCount = CMSampleBufferGetNumSamples(sample)
        if sampleCount == 0 {
            zeroSampleMarkerCount += 1
            continue
        }
        guard sampleCount == 1 else {
            throw TrackMigrationFixtureErrorV4.invalidFixture(
                "HDR10+ observation aggregated concrete samples."
            )
        }
        let presentation = CMSampleBufferGetPresentationTimeStamp(sample)
        let decode = CMSampleBufferGetDecodeTimeStamp(sample)
        let duration = CMSampleBufferGetDuration(sample)
        guard presentation.isNumeric,
              decode.isNumeric,
              duration.isNumeric,
              duration.value > 0,
              !presentation.flags.contains(.hasBeenRounded),
              !decode.flags.contains(.hasBeenRounded),
              !duration.flags.contains(.hasBeenRounded),
              seen.insert(try HDR10PlusPresentationTimeV4(presentation))
                .inserted else {
            throw TrackMigrationFixtureErrorV4.invalidFixture(
                "HDR10+ observation emitted invalid or duplicate timing."
            )
        }
        presentationTimes.append(presentation)
        decodeTimes.append(decode)
        durations.append(duration)
        syncSamples.append(hdrBoundarySampleIsSync(sample))
        metadata.append(
            try AVFoundationHDRMetadataAdapterV4
                .compressedHDR10PlusMetadata(from: sample)
        )
    }
    guard reader.status == .completed else {
        throw TrackMigrationFixtureErrorV4.writer(
            reader.error?.localizedDescription
                ?? "HDR10+ observation reader did not complete."
        )
    }
    return HDR10PlusVideoObservationsV4(
        zeroSampleMarkerCount: zeroSampleMarkerCount,
        presentationTimes: presentationTimes,
        decodeTimes: decodeTimes,
        durations: durations,
        syncSamples: syncSamples,
        metadata: metadata,
        codecType: codecType,
        formatMetadata: formatMetadata
    )
}

private func hdrBoundarySampleIsSync(_ sample: CMSampleBuffer) -> Bool {
    guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
        sample,
        createIfNecessary: false
    ) as? [[CFString: Any]],
    let first = attachments.first,
    let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool else {
        return true
    }
    return !notSync
}

private func hdrFormatMetadata(at url: URL) async throws
    -> HDRFormatMetadataV4? {
    let asset = AVURLAsset(url: url)
    let tracks = try await asset.loadTracks(withMediaType: .video)
    let track = try XCTUnwrap(tracks.first)
    let formats = try await track.load(.formatDescriptions)
    guard formats.count == 1, let format = formats.first else {
        throw TrackMigrationFixtureErrorV4.invalidFixture(
            "HDR format observation requires one video format description."
        )
    }
    return try AVFoundationHDRMetadataAdapterV4.probe(
        formatDescription: format,
        decodedStorage: .p010VideoRange10Bit
    )
}

private func makeZeroSampleMarker() throws -> CMSampleBuffer {
    var marker: CMSampleBuffer?
    let status = CMSampleBufferCreate(
        allocator: kCFAllocatorDefault,
        dataBuffer: nil,
        dataReady: true,
        makeDataReadyCallback: nil,
        refcon: nil,
        formatDescription: nil,
        sampleCount: 0,
        sampleTimingEntryCount: 0,
        sampleTimingArray: nil,
        sampleSizeEntryCount: 0,
        sampleSizeArray: nil,
        sampleBufferOut: &marker
    )
    guard status == noErr, let marker else {
        throw TrackMigrationFixtureErrorV4.coreMedia(status)
    }
    return marker
}

private func realVideoSampleTimings(at url: URL) async throws -> [CMTime] {
    let asset = AVURLAsset(
        url: url,
        options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
    )
    let tracks = try await asset.loadTracks(withMediaType: .video)
    let track = try XCTUnwrap(tracks.first)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    guard reader.canAdd(output) else {
        throw TrackMigrationFixtureErrorV4.invalidFixture(
            "Timing reader rejected the video track."
        )
    }
    reader.add(output)
    guard reader.startReading() else {
        throw TrackMigrationFixtureErrorV4.writer(
            reader.error?.localizedDescription ?? "Timing reader did not start."
        )
    }
    var timings: [CMTime] = []
    while let sample = output.copyNextSampleBuffer() {
        guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
        timings.append(CMSampleBufferGetPresentationTimeStamp(sample))
    }
    guard reader.status == .completed else {
        throw TrackMigrationFixtureErrorV4.writer(
            reader.error?.localizedDescription
                ?? "Timing reader did not complete."
        )
    }
    return timings
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
