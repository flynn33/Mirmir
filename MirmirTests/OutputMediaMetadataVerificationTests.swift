import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import XCTest
@testable import Mirmir

final class OutputMediaMetadataVerificationTests: XCTestCase {
    func testProbeInventoriesNoAudioAndCompatibleMetadataExactly()
        async throws {
        let fixture = try MediaOutputFixture()
        defer { fixture.remove() }
        try await writeOneFrameVideo(
            to: fixture.source,
            resolution: VideoResolution(width: 64, height: 64),
            duration: CMTime(value: 1, timescale: 30),
            containerMetadata: [
                fixtureMetadataItem(
                    identifier: .commonIdentifierTitle,
                    value: "Preflight container metadata"
                )
            ],
            timedMetadata: [
                "org.example.preflight": "compatible"
            ]
        )

        let profile = try await AVFoundationMediaPipeline(
            metal: NoopMetalRenderingService()
        ).probe(url: fixture.source)
        let capability = profile.mediaPreservationCapability

        XCTAssertFalse(profile.hasAudio)
        XCTAssertTrue(capability.audioTracks.isEmpty)
        XCTAssertEqual(capability.auxiliaryTracks.count, 1)
        XCTAssertEqual(
            capability.auxiliaryTracks.first?.mediaType,
            AVMediaType.metadata.rawValue
        )
        XCTAssertEqual(
            capability.auxiliaryTracks.first?.support,
            .exact
        )
        XCTAssertEqual(
            capability.auxiliaryTracks.first?
                .exactTrackIdentitySHA256?.count,
            64
        )
        XCTAssertTrue(capability.hasContainerMetadata)
        XCTAssertEqual(
            capability.containerMetadataIdentitySHA256?.count,
            64
        )
        XCTAssertEqual(capability.support, .exact)
        XCTAssertNil(
            capability.failureReason(
                preserveAudio: false,
                preserveSubtitles: true,
                preserveMetadata: true
            )
        )
    }

    func testSessionEmbedsAndReopensExactFinalMirmirIdentity() async throws {
        let fixture = try MediaOutputFixture()
        defer { fixture.remove() }
        let duration = CMTime(value: 1, timescale: 30)
        try await writeOneFrameVideo(
            to: fixture.source,
            resolution: VideoResolution(width: 64, height: 64),
            duration: duration
        )
        let staticMetadata = [
            "com.mirmir.ash.configuration-id": "fixture-configuration",
            "com.mirmir.ash.release-manifest-sha256": String(repeating: "a", count: 64),
            "com.mirmir.release.backend-id": "mps-lanczos",
            "com.mirmir.release.model-assets": "not_required"
        ]
        let template = staticMetadata.merging([
            "com.mirmir.ash.numerical-fallback-count": "0"
        ]) { _, final in final }
        let finalMetadata = staticMetadata.merging([
            "com.mirmir.ash.numerical-fallback-count": "7"
        ]) { _, final in final }
        let pipeline = AVFoundationMediaPipeline(metal: NoopMetalRenderingService())
        let source = try await pipeline.probe(url: fixture.source)
        let session = try await pipeline.beginSession(
            source: source,
            output: OutputProfile(
                url: fixture.destination,
                resolution: VideoResolution(width: 128, height: 128),
                codec: .h264,
                preserveAudio: false,
                timedMetadataTemplate: template
            )
        )
        let nextRecord = try await session.nextSourceFrame()
        let record = try XCTUnwrap(nextRecord)
        let output = try PixelBufferBridge.dequeue(from: session.outputPixelBufferPool)
        try fillNV12(output)
        try await session.appendOutput(pixelBuffer: output, timing: record.timing)
        let endOfStream = try await session.nextSourceFrame()
        XCTAssertNil(endOfStream)

        try await session.finish(finalMetadata: finalMetadata)

        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.destination.path))
        _ = try await OutputMediaVerifier().verify(
            url: fixture.destination,
            expectation: OutputMediaVerificationExpectation(
                resolution: VideoResolution(width: 128, height: 128),
                codec: .h264,
                timing: try makeTimingSnapshot(
                    presentationTime: record.presentationTime,
                    duration: record.duration
                ),
                timedMetadata: finalMetadata
            )
        )
        XCTAssertTrue(fixture.recognizedStagingFiles().isEmpty)
    }

    func testControlledMetadataPolicyRejectsForeignBareAndWhitespaceKeys() throws {
        try MirmirTimedMetadataPolicy.validate([
            "com.mirmir.release.backend-id": "mps-lanczos",
            "com.mirmir.ash.configuration-id": "fixture"
        ])

        for key in [
            "com.mirmir",
            "com.mirmir.",
            "com.mirmirx.release.backend-id",
            "org.example.backend-id",
            "com.mirmir.release.bad key",
            "com.mirmir.release.bad\nkey"
        ] {
            XCTAssertThrowsError(
                try MirmirTimedMetadataPolicy.validate([key: "value"]),
                "Expected controlled metadata-key rejection for \(String(reflecting: key))."
            )
        }
        XCTAssertThrowsError(
            try MirmirTimedMetadataPolicy.validate([
                "com.mirmir.release.backend-id": ""
            ])
        )
    }

    func testSessionRejectsFinalASHIdentityKeyDriftWithoutPublishing() async throws {
        let fixture = try MediaOutputFixture()
        defer { fixture.remove() }
        let duration = CMTime(value: 1, timescale: 30)
        try await writeOneFrameVideo(
            to: fixture.source,
            resolution: VideoResolution(width: 64, height: 64),
            duration: duration
        )
        let pipeline = AVFoundationMediaPipeline(metal: NoopMetalRenderingService())
        let source = try await pipeline.probe(url: fixture.source)
        let session = try await pipeline.beginSession(
            source: source,
            output: OutputProfile(
                url: fixture.destination,
                resolution: VideoResolution(width: 128, height: 128),
                codec: .h264,
                preserveAudio: false,
                timedMetadataTemplate: [
                    "com.mirmir.ash.numerical-fallback-count": "0"
                ]
            )
        )
        let nextRecord = try await session.nextSourceFrame()
        let record = try XCTUnwrap(nextRecord)
        let output = try PixelBufferBridge.dequeue(from: session.outputPixelBufferPool)
        try fillNV12(output)
        try await session.appendOutput(pixelBuffer: output, timing: record.timing)
        let endOfStream = try await session.nextSourceFrame()
        XCTAssertNil(endOfStream)

        do {
            try await session.finish(finalMetadata: [
                "com.mirmir.ash.unexpected": "1"
            ])
            XCTFail("Expected final ASH identity key-closure rejection.")
        } catch let error as MediaPipelineError {
            guard case .outputMetadataMismatch = error else {
                return XCTFail("Unexpected media pipeline error: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        XCTAssertTrue(fixture.recognizedTemporaryFiles().isEmpty)
    }

    func testSessionPreservesContainerTrackTimedMetadataAndAssociation()
        async throws {
        let fixture = try MediaOutputFixture()
        defer { fixture.remove() }
        let duration = CMTime(value: 1, timescale: 30)
        let containerItem = fixtureMetadataItem(
            identifier: .commonIdentifierTitle,
            value: "container-value"
        )
        let videoItem = fixtureMetadataItem(
            identifier: .commonIdentifierDescription,
            value: "video-value"
        )
        let sourceTimedMetadata = [
            "org.example.scene": "opening"
        ]
        try await writeOneFrameVideo(
            to: fixture.source,
            resolution: VideoResolution(width: 64, height: 64),
            duration: duration,
            containerMetadata: [containerItem],
            videoTrackMetadata: [videoItem],
            timedMetadata: sourceTimedMetadata
        )
        let mirmirMetadata = [
            "com.mirmir.release.backend-id": "fixture"
        ]
        let pipeline = AVFoundationMediaPipeline(
            metal: NoopMetalRenderingService()
        )
        let source = try await pipeline.probe(url: fixture.source)
        XCTAssertEqual(source.metadataTrackCount, 1)
        XCTAssertTrue(source.hasContainerMetadata)
        let session = try await pipeline.beginSession(
            source: source,
            output: OutputProfile(
                url: fixture.destination,
                resolution: VideoResolution(width: 128, height: 128),
                codec: .h264,
                preserveAudio: false,
                timedMetadataTemplate: mirmirMetadata
            )
        )
        let nextRecord = try await session.nextSourceFrame()
        let record = try XCTUnwrap(nextRecord)
        let output = try PixelBufferBridge.dequeue(
            from: session.outputPixelBufferPool
        )
        try fillNV12(output)
        try await session.appendOutput(
            pixelBuffer: output,
            timing: record.timing
        )
        let endOfStream = try await session.nextSourceFrame()
        XCTAssertNil(endOfStream)
        try await session.finish(finalMetadata: mirmirMetadata)

        let outputAsset = AVURLAsset(
            url: fixture.destination,
            options: [
                AVURLAssetPreferPreciseDurationAndTimingKey: true
            ]
        )
        let outputContainerMetadata = try await outputAsset.load(
            .metadata
        )
        let outputContainerValue = try await metadataStringValue(
            outputContainerMetadata,
            commonKey: .commonKeyTitle
        )
        XCTAssertEqual(
            outputContainerValue,
            "container-value"
        )
        let videoTracks = try await outputAsset.loadTracks(
            withMediaType: .video
        )
        let videoTrack = try XCTUnwrap(videoTracks.first)
        let videoMetadata = try await videoTrack.load(.metadata)
        let videoMetadataValue = try await metadataStringValue(
            videoMetadata,
            commonKey: .commonKeyDescription
        )
        XCTAssertEqual(
            videoMetadataValue,
            "video-value"
        )
        let metadataTracks = try await outputAsset.loadTracks(
            withMediaType: .metadata
        )
        XCTAssertEqual(metadataTracks.count, 2)
        let possibleSourceTrack = try await metadataTrack(
            in: metadataTracks,
            containingIdentifier: "mdta/org.example.scene"
        )
        let sourceTrack = try XCTUnwrap(possibleSourceTrack)
        let associatedVideoTracks =
            try await sourceTrack.loadAssociatedTracks(
                ofType: .metadataReferent
            )
        XCTAssertEqual(associatedVideoTracks.map(\.trackID), [
            videoTrack.trackID
        ])
        let reopenedSourceTimedMetadata =
            try await firstTimedMetadataValues(
                asset: outputAsset,
                track: sourceTrack
            )
        XCTAssertEqual(
            reopenedSourceTimedMetadata,
            sourceTimedMetadata
        )
        XCTAssertTrue(fixture.recognizedTemporaryFiles().isEmpty)
    }

    func testSessionPreservesSubtitleTimecodeAndTimecodeAssociation()
        async throws {
        for destinationExtension in ["mov", "mp4"] {
            try await assertSessionPreservesSubtitleTimecode(
                destinationExtension: destinationExtension
            )
        }
    }

    func testSessionPreservesRecursiveExternalAuxiliaryVideoAssociations()
        async throws {
        let fixture = try MediaOutputFixture(
            sourceExtension: "mov",
            destinationExtension: "mov"
        )
        defer { fixture.remove() }
        try await writeRecursiveAuxiliaryVideoFixture(
            to: fixture.source
        )
        let pipeline = AVFoundationMediaPipeline(
            metal: NoopMetalRenderingService()
        )
        let source = try await pipeline.probe(url: fixture.source)
        let capability = source.mediaPreservationCapability
        let associatedVideoTracks = capability.tracks.filter {
            $0.mediaType == AVMediaType.video.rawValue
        }
        XCTAssertEqual(
            associatedVideoTracks.map(\.ordinal),
            [1, 2]
        )
        XCTAssertTrue(
            associatedVideoTracks.allSatisfy {
                $0.support == .exact
                    && $0.exactTrackIdentitySHA256?.count == 64
            }
        )
        XCTAssertEqual(capability.associations.count, 2)
        XCTAssertTrue(
            capability.associations.allSatisfy {
                $0.associationType == "auxl"
                    && $0.support == .exact
                    && $0.targetOrdinal != nil
            }
        )
        XCTAssertTrue(
            capability.requiresQuickTimeMovieContainer(
                preserveAudio: false
            )
        )

        let rejectedMP4 = fixture.directory.appendingPathComponent(
            "associated-output.mp4"
        )
        do {
            _ = try await pipeline.beginSession(
                source: source,
                output: OutputProfile(
                    url: rejectedMP4,
                    resolution:
                        VideoResolution(width: 128, height: 128),
                    codec: .h264,
                    preserveAudio: false
                )
            )
            XCTFail("Expected early associated-video MP4 rejection.")
        } catch let error as MediaPipelineError {
            guard case .outputContainerCannotPreserveTrackAssociations(
                let pathExtension
            ) = error else {
                return XCTFail("Unexpected container error: \(error)")
            }
            XCTAssertEqual(pathExtension, "mp4")
            XCTAssertTrue(error.description.contains("QuickTime Movie"))
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: rejectedMP4.path)
        )

        let sourceAsset = AVURLAsset(
            url: fixture.source,
            options: [
                AVURLAssetPreferPreciseDurationAndTimingKey: true
            ]
        )
        let sourceVideoTracks = try await sourceAsset.loadTracks(
            withMediaType: .video
        )
        XCTAssertEqual(sourceVideoTracks.count, 3)
        let sourceAuxiliaryIdentities =
            try await associatedVideoSampleIdentities(
                asset: sourceAsset,
                primaryTrack: sourceVideoTracks[0]
            )

        let session = try await pipeline.beginSession(
            source: source,
            output: OutputProfile(
                url: fixture.destination,
                resolution: VideoResolution(width: 128, height: 128),
                codec: .h264,
                preserveAudio: false
            )
        )
        while let record = try await session.nextSourceFrame() {
            let output = try PixelBufferBridge.dequeue(
                from: session.outputPixelBufferPool
            )
            try fillNV12(output)
            try await session.appendOutput(
                pixelBuffer: output,
                timing: record.timing
            )
        }
        try await session.finish()

        let outputAsset = AVURLAsset(
            url: fixture.destination,
            options: [
                AVURLAssetPreferPreciseDurationAndTimingKey: true
            ]
        )
        let outputVideoTracks = try await outputAsset.loadTracks(
            withMediaType: .video
        )
        XCTAssertEqual(outputVideoTracks.count, 3)
        let primaryFormats = try await outputVideoTracks[0].load(
            .formatDescriptions
        )
        let primaryFormat = try XCTUnwrap(primaryFormats.first)
        let primaryDimensions =
            CMVideoFormatDescriptionGetDimensions(primaryFormat)
        XCTAssertEqual(primaryDimensions.width, 128)
        XCTAssertEqual(primaryDimensions.height, 128)
        var auxiliaryDimensions: [CMVideoDimensions] = []
        for track in outputVideoTracks.dropFirst() {
            let formats = try await track.load(.formatDescriptions)
            auxiliaryDimensions.append(
                CMVideoFormatDescriptionGetDimensions(
                    try XCTUnwrap(formats.first)
                )
            )
        }
        XCTAssertEqual(
            auxiliaryDimensions.map(\.width),
            [48, 32]
        )
        XCTAssertEqual(
            auxiliaryDimensions.map(\.height),
            [48, 32]
        )
        for sourceIndex in 0..<2 {
            let targets = try await outputVideoTracks[sourceIndex]
                .loadAssociatedTracks(
                    ofType: AVAssetTrack.AssociationType(
                        rawValue: "auxl"
                    )
                )
            XCTAssertEqual(
                targets.map(\.trackID),
                [outputVideoTracks[sourceIndex + 1].trackID]
            )
        }
        let outputAuxiliaryIdentities =
            try await associatedVideoSampleIdentities(
                asset: outputAsset,
                primaryTrack: outputVideoTracks[0]
            )
        XCTAssertEqual(
            outputAuxiliaryIdentities,
            sourceAuxiliaryIdentities
        )
        XCTAssertTrue(fixture.recognizedTemporaryFiles().isEmpty)
    }

    func testDisabledAssociationTargetCategoryRetainsActionableReason()
        async throws {
        let fixture = try MediaOutputFixture(
            sourceExtension: "mov",
            destinationExtension: "mov"
        )
        defer { fixture.remove() }
        try await writeOneFrameVideo(
            to: fixture.source,
            resolution: VideoResolution(width: 64, height: 64),
            duration: CMTime(value: 1, timescale: 30),
            timecodeFrameNumber: 1_800
        )
        let pipeline = AVFoundationMediaPipeline(
            metal: NoopMetalRenderingService()
        )
        let source = try await pipeline.probe(url: fixture.source)
        let reason = try XCTUnwrap(
            source.mediaPreservationCapability.failureReason(
                preserveAudio: false,
                preserveSubtitles: true,
                preserveMetadata: false
            )
        )
        XCTAssertTrue(reason.contains("association"))
        XCTAssertTrue(reason.contains("Timecode"))
        XCTAssertTrue(
            reason.contains(
                "Enable source metadata and timecode preservation."
            )
        )

        do {
            _ = try await pipeline.beginSession(
                source: source,
                output: OutputProfile(
                    url: fixture.destination,
                    resolution:
                        VideoResolution(width: 128, height: 128),
                    codec: .h264,
                    preserveAudio: false,
                    preserveMetadata: false
                )
            )
            XCTFail("Expected required timecode-target rejection.")
        } catch let error as MediaPipelineError {
            guard case .mediaPreservationPreflightFailed(
                let observedReason
            ) = error else {
                return XCTFail("Unexpected pipeline error: \(error)")
            }
            XCTAssertEqual(observedReason, reason)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.destination.path
            )
        )
    }

    private func assertSessionPreservesSubtitleTimecode(
        destinationExtension: String
    ) async throws {
        let fixture = try MediaOutputFixture(
            sourceExtension: "mov",
            destinationExtension: destinationExtension
        )
        defer { fixture.remove() }
        let duration = CMTime(value: 1, timescale: 30)
        try await writeOneFrameVideo(
            to: fixture.source,
            resolution: VideoResolution(width: 64, height: 64),
            duration: duration,
            subtitleText: "Preserve this subtitle.",
            timecodeFrameNumber: 1_800
        )
        let pipeline = AVFoundationMediaPipeline(
            metal: NoopMetalRenderingService()
        )
        let source = try await pipeline.probe(url: fixture.source)
        XCTAssertEqual(source.subtitleTrackCount, 1)
        XCTAssertEqual(source.metadataTrackCount, 1)

        let session = try await pipeline.beginSession(
            source: source,
            output: OutputProfile(
                url: fixture.destination,
                resolution: VideoResolution(width: 128, height: 128),
                codec: .h264,
                preserveAudio: false
            )
        )
        let nextRecord = try await session.nextSourceFrame()
        let record = try XCTUnwrap(nextRecord)
        let output = try PixelBufferBridge.dequeue(
            from: session.outputPixelBufferPool
        )
        try fillNV12(output)
        try await session.appendOutput(
            pixelBuffer: output,
            timing: record.timing
        )
        let endOfStream = try await session.nextSourceFrame()
        XCTAssertNil(endOfStream)
        try await session.finish()

        let outputAsset = AVURLAsset(
            url: fixture.destination,
            options: [
                AVURLAssetPreferPreciseDurationAndTimingKey: true
            ]
        )
        let subtitleTracks = try await outputAsset.loadTracks(
            withMediaType: .subtitle
        )
        let timecodeTracks = try await outputAsset.loadTracks(
            withMediaType: .timecode
        )
        XCTAssertEqual(subtitleTracks.count, 1)
        XCTAssertEqual(timecodeTracks.count, 1)
        let outputVideoTracks = try await outputAsset.loadTracks(
            withMediaType: .video
        )
        let outputVideoTrack = try XCTUnwrap(outputVideoTracks.first)
        let associatedTimecodeTracks =
            try await outputVideoTrack.loadAssociatedTracks(
                ofType: .timecode
            )
        XCTAssertEqual(
            associatedTimecodeTracks.map(\.trackID),
            timecodeTracks.map(\.trackID)
        )
        XCTAssertTrue(fixture.recognizedTemporaryFiles().isEmpty)
    }

    func testSessionPreservesQuickTimeTextTrack() async throws {
        for destinationExtension in ["mov", "mp4"] {
            try await assertSessionPreservesQuickTimeTextTrack(
                destinationExtension: destinationExtension
            )
        }
    }

    private func assertSessionPreservesQuickTimeTextTrack(
        destinationExtension: String
    ) async throws {
        let fixture = try MediaOutputFixture(
            sourceExtension: "mov",
            destinationExtension: destinationExtension
        )
        defer { fixture.remove() }
        try await writeOneFrameVideo(
            to: fixture.source,
            resolution: VideoResolution(width: 64, height: 64),
            duration: CMTime(value: 1, timescale: 30),
            textTrackText: "Preserve this text track."
        )
        let pipeline = AVFoundationMediaPipeline(
            metal: NoopMetalRenderingService()
        )
        let source = try await pipeline.probe(url: fixture.source)
        XCTAssertEqual(source.subtitleTrackCount, 1)

        let session = try await pipeline.beginSession(
            source: source,
            output: OutputProfile(
                url: fixture.destination,
                resolution: VideoResolution(width: 128, height: 128),
                codec: .h264,
                preserveAudio: false
            )
        )
        while let record = try await session.nextSourceFrame() {
            let output = try PixelBufferBridge.dequeue(
                from: session.outputPixelBufferPool
            )
            try fillNV12(output)
            try await session.appendOutput(
                pixelBuffer: output,
                timing: record.timing
            )
        }
        try await session.finish()

        let outputAsset = AVURLAsset(
            url: fixture.destination,
            options: [
                AVURLAssetPreferPreciseDurationAndTimingKey: true
            ]
        )
        let textTracks = try await outputAsset.loadTracks(
            withMediaType: .text
        )
        XCTAssertEqual(textTracks.count, 1)
        XCTAssertTrue(fixture.recognizedTemporaryFiles().isEmpty)
    }

    func testSessionPreservesCEA608ClosedCaptionTrack() async throws {
        for destinationExtension in ["mov", "mp4"] {
            try await assertSessionPreservesCEA608ClosedCaptionTrack(
                destinationExtension: destinationExtension
            )
        }
    }

    private func assertSessionPreservesCEA608ClosedCaptionTrack(
        destinationExtension: String
    ) async throws {
        let fixture = try MediaOutputFixture(
            sourceExtension: "mov",
            destinationExtension: destinationExtension
        )
        defer { fixture.remove() }
        try await writeVideoFrames(
            to: fixture.source,
            resolution: VideoResolution(width: 64, height: 64),
            frameCount: 3,
            frameDuration: CMTime(value: 1, timescale: 1),
            closedCaptionText: "Preserve this closed caption.",
            closedCaptionTimeRange: CMTimeRange(
                start: CMTime(value: 1, timescale: 1),
                duration: CMTime(value: 1, timescale: 1)
            )
        )
        let sourceAsset = AVURLAsset(
            url: fixture.source,
            options: [
                AVURLAssetPreferPreciseDurationAndTimingKey: true
            ]
        )
        let sourceClosedCaptionTracks = try await sourceAsset.loadTracks(
            withMediaType: .closedCaption
        )
        XCTAssertEqual(sourceClosedCaptionTracks.count, 1)
        let sourceClosedCaptionTrack = try XCTUnwrap(
            sourceClosedCaptionTracks.first
        )
        let sourceCaptionFormats =
            try await sourceClosedCaptionTrack.load(.formatDescriptions)
        let sourceCaptionFormat = try XCTUnwrap(
            sourceCaptionFormats.first
        )
        XCTAssertEqual(
            CMFormatDescriptionGetMediaSubType(sourceCaptionFormat),
            kCMClosedCaptionFormatType_CEA608
        )
        let sourceVideoTracks =
            try await sourceAsset.loadTracks(withMediaType: .video)
        let sourceVideoTrack = try XCTUnwrap(sourceVideoTracks.first)
        let sourceAssociatedCaptionTracks =
            try await sourceVideoTrack.loadAssociatedTracks(
                ofType: AVAssetTrack.AssociationType(rawValue: "clcp")
            )
        XCTAssertEqual(
            sourceAssociatedCaptionTracks.map(\.trackID),
            [sourceClosedCaptionTrack.trackID]
        )
        let sourceDuration = try await sourceAsset.load(.duration)
        let sourceCaptionTimeRange =
            try await sourceClosedCaptionTrack.load(.timeRange)
        let sourceCaptionSegments =
            try await sourceClosedCaptionTrack.load(.segments).map {
                OutputMediaTrackSegmentIdentity(
                    isEmpty: $0.isEmpty,
                    source: $0.timeMapping.source,
                    target: $0.timeMapping.target
                )
            }
        let pipeline = AVFoundationMediaPipeline(
            metal: NoopMetalRenderingService()
        )
        let source = try await pipeline.probe(url: fixture.source)
        XCTAssertEqual(source.subtitleTrackCount, 1)

        let session = try await pipeline.beginSession(
            source: source,
            output: OutputProfile(
                url: fixture.destination,
                resolution: VideoResolution(width: 128, height: 128),
                codec: .h264,
                preserveAudio: false
            )
        )
        let concreteSession = try XCTUnwrap(
            session as? AVFoundationMediaSession
        )
        let sourceCaptionExpectation = try XCTUnwrap(
            concreteSession.sourceMediaPreservation.expectation.tracks
                .first {
                    $0.reference.mediaType
                        == AVMediaType.closedCaption.rawValue
                }
        )
        let sourceSampleIdentity = try XCTUnwrap(
            sourceCaptionExpectation.sampleIdentity
        )
        XCTAssertEqual(sourceSampleIdentity.sampleCount, 2)
        XCTAssertEqual(
            sourceSampleIdentity.totalPayloadByteCount,
            56
        )
        XCTAssertEqual(
            sourceCaptionExpectation.segmentIdentity,
            sourceCaptionSegments
        )
        while let record = try await session.nextSourceFrame() {
            let output = try PixelBufferBridge.dequeue(
                from: session.outputPixelBufferPool
            )
            try fillNV12(output)
            try await session.appendOutput(
                pixelBuffer: output,
                timing: record.timing
            )
        }
        try await session.finish()

        let outputAsset = AVURLAsset(
            url: fixture.destination,
            options: [
                AVURLAssetPreferPreciseDurationAndTimingKey: true
            ]
        )
        let closedCaptionTracks = try await outputAsset.loadTracks(
            withMediaType: .closedCaption
        )
        XCTAssertEqual(closedCaptionTracks.count, 1)
        let outputClosedCaptionTrack = try XCTUnwrap(
            closedCaptionTracks.first
        )
        let outputDuration = try await outputAsset.load(.duration)
        XCTAssertEqual(
            CMTimeCompare(outputDuration, sourceDuration),
            0,
            "Container duration changed for .\(destinationExtension)."
        )
        let outputCaptionTimeRange =
            try await outputClosedCaptionTrack.load(.timeRange)
        XCTAssertEqual(
            CMTimeCompare(
                outputCaptionTimeRange.start,
                sourceCaptionTimeRange.start
            ),
            0,
            "Caption start changed for .\(destinationExtension)."
        )
        XCTAssertEqual(
            CMTimeCompare(
                outputCaptionTimeRange.duration,
                sourceCaptionTimeRange.duration
            ),
            0,
            "Caption duration changed for .\(destinationExtension)."
        )
        let outputCaptionSegments =
            try await outputClosedCaptionTrack.load(.segments).map {
                OutputMediaTrackSegmentIdentity(
                    isEmpty: $0.isEmpty,
                    source: $0.timeMapping.source,
                    target: $0.timeMapping.target
                )
            }
        XCTAssertEqual(
            outputCaptionSegments,
            sourceCaptionSegments,
            "Caption edit map changed for .\(destinationExtension)."
        )
        let outputCaptionFormats =
            try await outputClosedCaptionTrack.load(.formatDescriptions)
        let outputCaptionFormat = try XCTUnwrap(
            outputCaptionFormats.first
        )
        XCTAssertEqual(
            CMFormatDescriptionGetMediaSubType(outputCaptionFormat),
            kCMClosedCaptionFormatType_CEA608
        )
        let outputVideoTracks =
            try await outputAsset.loadTracks(withMediaType: .video)
        let outputVideoTrack = try XCTUnwrap(outputVideoTracks.first)
        let outputAssociatedCaptionTracks =
            try await outputVideoTrack.loadAssociatedTracks(
                ofType: AVAssetTrack.AssociationType(rawValue: "clcp")
            )
        XCTAssertEqual(
            outputAssociatedCaptionTracks.map(\.trackID),
            [outputClosedCaptionTrack.trackID]
        )
        let reopenedPlan = try await SourceMediaPreservationPlanner.make(
            asset: outputAsset,
            selectedTracks: [
                outputVideoTrack,
                outputClosedCaptionTrack
            ],
            preserveMetadata: true
        )
        let outputCaptionExpectation = try XCTUnwrap(
            reopenedPlan.expectation.tracks.first {
                $0.reference.mediaType
                    == AVMediaType.closedCaption.rawValue
            }
        )
        XCTAssertEqual(
            outputCaptionExpectation.sampleIdentity,
            sourceCaptionExpectation.sampleIdentity,
            "Caption sample timing/payload identity changed for "
                + ".\(destinationExtension)."
        )
        XCTAssertTrue(fixture.recognizedTemporaryFiles().isEmpty)
    }

    func testSessionRoundTripsP010SDRPQAndHLGWithoutEightBitCollapse()
        async throws {
        let mastering = Data([
            0x8A, 0x48, 0x39, 0x08,
            0x21, 0x34, 0x9B, 0xAA,
            0x19, 0x96, 0x08, 0xFC,
            0x3D, 0x13, 0x40, 0x42,
            0x00, 0x98, 0x96, 0x80,
            0x00, 0x00, 0x00, 0x32
        ])
        let formats: [MediaVideoFormat] = [
            .sdrBT709TenBit,
            .sdrBT2020TenBit,
            .hdrBT2020PQ(
                masteringDisplayColorVolume: mastering,
                contentLightLevelInfo: Data([
                    0x03, 0xE8, 0x01, 0x90
                ])
            ),
            .hdrBT2020HLG()
        ]
        for format in formats {
            let fixture = try MediaOutputFixture()
            defer { fixture.remove() }
            let duration = CMTime(value: 1, timescale: 30)
            try await writeOneFrameVideo(
                to: fixture.source,
                resolution: VideoResolution(width: 64, height: 64),
                duration: duration,
                codec: .hevc,
                videoFormat: format
            )
            let pipeline = AVFoundationMediaPipeline(
                metal: NoopMetalRenderingService()
            )
            let source = try await pipeline.probe(url: fixture.source)
            XCTAssertEqual(source.videoFormat, format)

            do {
                _ = try await pipeline.beginSession(
                    source: source,
                    output: OutputProfile(
                        url: fixture.destination,
                        resolution: VideoResolution(
                            width: 128,
                            height: 128
                        ),
                        codec: .h264,
                        preserveAudio: false
                    )
                )
                XCTFail("Expected H.264 format-preservation rejection.")
            } catch let error as MediaPipelineError {
                guard case .outputCodecCannotPreserveVideoFormat =
                        error else {
                    return XCTFail(
                        "Unexpected media pipeline error: \(error)"
                    )
                }
                XCTAssertTrue(error.description.contains("Select HEVC"))
            }

            let session = try await pipeline.beginSession(
                source: source,
                output: OutputProfile(
                    url: fixture.destination,
                    resolution: VideoResolution(
                        width: 128,
                        height: 128
                    ),
                    codec: .hevc,
                    preserveAudio: false
                )
            )
            XCTAssertEqual(session.videoFormat, format)
            let nextRecord = try await session.nextSourceFrame()
            let record = try XCTUnwrap(nextRecord)
            XCTAssertEqual(
                CVPixelBufferGetPixelFormatType(record.pixelBuffer),
                kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            )
            let output = try PixelBufferBridge.dequeue(
                from: session.outputPixelBufferPool
            )
            try fillP010(output)
            try await session.appendOutput(
                pixelBuffer: output,
                timing: record.timing
            )
            let endOfStream = try await session.nextSourceFrame()
            XCTAssertNil(endOfStream)
            try await session.finish()

            let reopened = try await pipeline.probe(
                url: fixture.destination
            )
            XCTAssertEqual(reopened.videoFormat, format)
            XCTAssertTrue(
                fixture.recognizedTemporaryFiles().isEmpty
            )
        }
    }

    func testSessionRoundTripsEightBitHEVCAlpha() async throws {
        let fixture = try MediaOutputFixture(
            sourceExtension: "mov",
            destinationExtension: "mov"
        )
        defer { fixture.remove() }
        let format = MediaVideoFormat.sdrBT709WithAlpha(
            mode: .straight
        )
        let duration = CMTime(value: 1, timescale: 30)
        try await writeOneFrameVideo(
            to: fixture.source,
            resolution: VideoResolution(width: 64, height: 64),
            duration: duration,
            codec: .hevc,
            videoFormat: format
        )
        let pipeline = AVFoundationMediaPipeline(
            metal: NoopMetalRenderingService()
        )
        let source = try await pipeline.probe(url: fixture.source)
        XCTAssertEqual(source.videoFormat, format)
        do {
            _ = try await pipeline.beginSession(
                source: source,
                output: OutputProfile(
                    url: fixture.destination,
                    resolution: VideoResolution(
                        width: 128,
                        height: 128
                    ),
                    codec: .h264,
                    preserveAudio: false
                )
            )
            XCTFail("Expected H.264 alpha-preservation rejection.")
        } catch let error as MediaPipelineError {
            guard case .outputCodecCannotPreserveVideoFormat =
                    error else {
                return XCTFail(
                    "Unexpected media pipeline error: \(error)"
                )
            }
            XCTAssertTrue(error.description.contains("Select HEVC"))
        }
        let session = try await pipeline.beginSession(
            source: source,
            output: OutputProfile(
                url: fixture.destination,
                resolution: VideoResolution(width: 128, height: 128),
                codec: .hevc,
                preserveAudio: false
            )
        )
        let nextRecord = try await session.nextSourceFrame()
        let record = try XCTUnwrap(nextRecord)
        XCTAssertEqual(
            CVPixelBufferGetPixelFormatType(record.pixelBuffer),
            kCVPixelFormatType_32BGRA
        )
        let output = try PixelBufferBridge.dequeue(
            from: session.outputPixelBufferPool
        )
        try fillBGRA(output)
        format.installAttachments(on: output)
        try await session.appendOutput(
            pixelBuffer: output,
            timing: record.timing
        )
        let endOfStream = try await session.nextSourceFrame()
        XCTAssertNil(endOfStream)
        try await session.finish()

        let reopened = try await pipeline.probe(
            url: fixture.destination
        )
        XCTAssertEqual(reopened.videoFormat, format)
        XCTAssertTrue(fixture.recognizedTemporaryFiles().isEmpty)
    }
}

private func writeRecursiveAuxiliaryVideoFixture(
    to destinationURL: URL
) async throws {
    let directory = destinationURL.deletingLastPathComponent()
    let sourceURLs = (0..<3).map {
        directory.appendingPathComponent(
            "association-source-\($0).mov"
        )
    }
    defer {
        for url in sourceURLs {
            try? FileManager.default.removeItem(at: url)
        }
    }
    let resolutions = [
        VideoResolution(width: 64, height: 64),
        VideoResolution(width: 48, height: 48),
        VideoResolution(width: 32, height: 32)
    ]
    for (url, resolution) in zip(sourceURLs, resolutions) {
        try await writeOneFrameVideo(
            to: url,
            resolution: resolution,
            duration: CMTime(value: 1, timescale: 30)
        )
    }

    var sourceAssets: [AVURLAsset] = []
    var sourceTracks: [AVAssetTrack] = []
    for url in sourceURLs {
        let asset = AVURLAsset(
            url: url,
            options: [
                AVURLAssetPreferPreciseDurationAndTimingKey: true
            ]
        )
        let tracks = try await asset.loadTracks(
            withMediaType: .video
        )
        sourceAssets.append(asset)
        sourceTracks.append(try XCTUnwrap(tracks.first))
    }

    let movie = AVMutableMovie()
    movie.timescale = 600
    movie.defaultMediaDataStorage = AVMediaDataStorage(
        url: destinationURL,
        options: nil
    )
    var destinationTracks: [AVMutableMovieTrack] = []
    for sourceTrack in sourceTracks {
        guard let destinationTrack = movie.addMutableTrack(
            withMediaType: .video,
            copySettingsFrom: sourceTrack,
            options: nil
        ) else {
            throw MediaTestFailure.cannotAddWriterInput
        }
        let timeRange = try await sourceTrack.load(.timeRange)
        let timeScale = try await sourceTrack.load(
            .naturalTimeScale
        )
        destinationTrack.timescale = timeScale
        destinationTrack.preferredTransform = try await sourceTrack.load(
            .preferredTransform
        )
        destinationTrack.isEnabled = try await sourceTrack.load(
            .isEnabled
        )
        destinationTrack.metadata = try await sourceTrack.load(
            .metadata
        )
        try destinationTrack.insertTimeRange(
            timeRange,
            of: sourceTrack,
            at: timeRange.start,
            copySampleData: true
        )
        destinationTracks.append(destinationTrack)
    }
    for sourceIndex in 0..<2 {
        destinationTracks[sourceIndex].addTrackAssociation(
            to: destinationTracks[sourceIndex + 1],
            type: AVAssetTrack.AssociationType(rawValue: "auxl")
        )
    }
    try movie.writeHeader(
        to: destinationURL,
        fileType: .mov,
        options: .addMovieHeaderToDestination
    )
    withExtendedLifetime(sourceAssets) {}
}

private func associatedVideoSampleIdentities(
    asset: AVURLAsset,
    primaryTrack: AVAssetTrack
) async throws -> [OutputMediaTrackSampleIdentity] {
    let plan = try await SourceMediaPreservationPlanner.make(
        asset: asset,
        selectedTracks: [primaryTrack],
        preserveMetadata: true
    )
    var identities: [OutputMediaTrackSampleIdentity] = []
    for track in plan.expectation.tracks
    where track.reference.mediaType == AVMediaType.video.rawValue
        && track.reference.ordinal > 0 {
        identities.append(try XCTUnwrap(track.sampleIdentity))
    }
    return identities
}

private func fixtureMetadataItem(
    identifier: AVMetadataIdentifier,
    value: String
) -> AVMetadataItem {
    let item = AVMutableMetadataItem()
    item.identifier = identifier
    item.value = value as NSString
    item.dataType = kCMMetadataBaseDataType_UTF8 as String
    return item
}

private func metadataStringValues(
    _ items: [AVMetadataItem]
) async throws -> [String: String] {
    var result: [String: String] = [:]
    for item in items {
        guard let identifier = item.identifier?.rawValue,
              let value = try await item.load(.stringValue) else {
            continue
        }
        result[identifier] = value
    }
    return result
}

private func metadataStringValue(
    _ items: [AVMetadataItem],
    commonKey: AVMetadataKey
) async throws -> String? {
    for item in items {
        guard item.commonKey == commonKey else {
            continue
        }
        if let value = try await item.load(.stringValue) {
            return value
        }
    }
    return nil
}

private func metadataTrack(
    in tracks: [AVAssetTrack],
    containingIdentifier identifier: String
) async throws -> AVAssetTrack? {
    for track in tracks {
        let formats = try await track.load(.formatDescriptions)
        let identifiers = formats.flatMap { description in
            (
                CMMetadataFormatDescriptionGetIdentifiers(description)
                    as? [String]
            ) ?? []
        }
        if identifiers.contains(identifier) {
            return track
        }
    }
    return nil
}

private func firstTimedMetadataValues(
    asset: AVURLAsset,
    track: AVAssetTrack
) async throws -> [String: String] {
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(
        track: track,
        outputSettings: nil
    )
    guard reader.canAdd(output) else {
        throw MediaTestFailure.cannotAddReaderOutput
    }
    reader.add(output)
    let adaptor = AVAssetReaderOutputMetadataAdaptor(
        assetReaderTrackOutput: output
    )
    guard reader.startReading() else {
        throw MediaTestFailure.cannotStartReader
    }
    guard let group = adaptor.nextTimedMetadataGroup() else {
        throw MediaTestFailure.readerFailed
    }
    let identifiedValues = try await metadataStringValues(group.items)
    let values = Dictionary(uniqueKeysWithValues: identifiedValues.map {
        key, value in
        let bareKey = key.hasPrefix("mdta/")
            ? String(key.dropFirst("mdta/".count))
            : key
        return (bareKey, value)
    })
    while adaptor.nextTimedMetadataGroup() != nil {}
    guard reader.status == .completed else {
        throw MediaTestFailure.readerFailed
    }
    return values
}
