import AVFoundation
import CoreMedia
import Foundation
import XCTest
@testable import Mirmir

final class TimedMetadataPipelineIntegrationTests: XCTestCase {
    func testMixedMetadataMigratesThroughProductionFinalMuxAndCleansArtifacts()
        async throws {
        let fixture = try MediaOutputFixture(
            sourceExtension: "mov",
            destinationExtension: "mov"
        )
        defer { fixture.remove() }

        let videoURL = fixture.directory.appendingPathComponent("video.mov")
        let metadataURL = fixture.directory.appendingPathComponent(
            "mixed-metadata.mov"
        )
        let videoDuration = CMTime(value: 1_800, timescale: 600)
        let sourceGroups = timedMetadataPipelineSourceGroups()
        let foreignStaticItem = timedMetadataPipelineItem(
            key: "org.example.static",
            value: "foreign-static"
        )
        let controlledStaticItem = timedMetadataPipelineItem(
            key: "com.mirmir.release.stale-static",
            value: "remove-static"
        )

        try await writeOneFrameVideo(
            to: videoURL,
            resolution: VideoResolution(width: 64, height: 64),
            duration: videoDuration
        )
        try await writeTimedMetadataPipelineAsset(
            to: metadataURL,
            groups: sourceGroups,
            staticMetadata: [foreignStaticItem, controlledStaticItem]
        )
        try await writeTimedMetadataPipelineSource(
            to: fixture.source,
            videoURL: videoURL,
            metadataURL: metadataURL
        )

        let sourceAsset = AVURLAsset(
            url: fixture.source,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let sourceMetadataTracks = try await sourceAsset.loadTracks(
            withMediaType: .metadata
        )
        let sourceMetadataTrack = try XCTUnwrap(
            sourceMetadataTracks.first
        )
        let sourceMetadataRange = try await sourceMetadataTrack.load(
            .timeRange
        )
        // QuickTime represents delayed track presentation with a leading
        // empty edit. The track envelope therefore starts at zero while the
        // decoded stream begins at the first group's nonzero timestamp.
        XCTAssertEqual(
            CMTimeCompare(sourceMetadataRange.start, .zero),
            0
        )
        let reopenedSourceGroups = try readTimedMetadataPipelineGroups(
            asset: sourceAsset,
            track: sourceMetadataTrack
        )
        XCTAssertGreaterThan(
            CMTimeCompare(
                try XCTUnwrap(reopenedSourceGroups.first).timeRange.start,
                .zero
            ),
            0,
            "The source timed-metadata stream must start at a nonzero timestamp."
        )
        XCTAssertEqual(
            reopenedSourceGroups.map(\.timeRange),
            sourceGroups.map(\.timeRange)
        )
        XCTAssertEqual(
            reopenedSourceGroups.map {
                $0.items.compactMap { $0.identifier?.rawValue }
            },
            sourceGroups.map {
                $0.items.compactMap { $0.identifier?.rawValue }
            }
        )
        let expectedSanitizedGroups = reopenedSourceGroups.map { group in
            AVTimedMetadataGroup(
                items: group.items.filter { item in
                    guard let identifier = item.identifier?.rawValue else {
                        return false
                    }
                    return !MirmirTimedMetadataPolicy
                        .isControlledIdentifier(identifier)
                        && !MirmirTimedMetadataPolicy
                            .resemblesControlledIdentifier(identifier)
                },
                timeRange: group.timeRange
            )
        }
        var expectedForeignValues: [String?] = []
        for item in expectedSanitizedGroups.flatMap(\.items) {
            expectedForeignValues.append(try await item.load(.stringValue))
        }

        let pipeline = AVFoundationMediaPipeline(
            metal: NoopMetalRenderingService()
        )
        let profile = try await pipeline.probe(url: fixture.source)
        XCTAssertNil(
            profile.mediaPreservationCapability.failureReason(
                preserveAudio: false,
                preserveSubtitles: true,
                preserveMetadata: true
            )
        )
        let identity = [
            "com.mirmir.release.backend-id": "current-production-run"
        ]
        let mediaSession = try await pipeline.beginSession(
            source: profile,
            output: OutputProfile(
                url: fixture.destination,
                resolution: VideoResolution(width: 64, height: 64),
                codec: .h264,
                preserveAudio: false,
                timedMetadataTemplate: identity
            )
        )
        let session = try XCTUnwrap(
            mediaSession as? AVFoundationMediaSession
        )
        defer { session.cancel() }

        let artifact = try XCTUnwrap(
            session.sourceMediaPreservation.migrationArtifacts.first
        )
        XCTAssertEqual(
            session.sourceMediaPreservation.migrationArtifacts.count,
            1
        )
        let metadataPlan = try XCTUnwrap(
            session.sourceMediaPreservation.track(
                withID: sourceMetadataTrack.trackID
            )
        )
        XCTAssertEqual(
            metadataPlan.track.mediaType,
            AVMediaType.metadata
        )
        XCTAssertEqual(
            CMTimeCompare(metadataPlan.sourceCopyTimeRange.start, .zero),
            0,
            "The private migration asset must be normalized to zero."
        )
        XCTAssertEqual(
            CMTimeCompare(
                metadataPlan.destinationStart,
                sourceMetadataRange.start
            ),
            0,
            "Planning must retain the original nonzero output start."
        )
        XCTAssertEqual(
            CMTimeCompare(
                metadataPlan.expectation.timeRange.start,
                sourceMetadataRange.start
            ),
            0
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: artifact.assetURL.path)
        )
        XCTAssertFalse(
            timedMetadataPipelineOwnershipMarkers(in: fixture.directory)
                .isEmpty
        )

        try await processTimedMetadataPipelineSession(session)
        try await session.finish(finalMetadata: identity)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: artifact.assetURL.path)
        )
        XCTAssertTrue(
            timedMetadataPipelineOwnedTemporaryEntries(
                in: fixture.directory
            ).isEmpty
        )
        XCTAssertNil(session.terminalCleanupError)

        let outputAsset = AVURLAsset(
            url: fixture.destination,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let outputMetadataTracks = try await outputAsset.loadTracks(
            withMediaType: .metadata
        )
        XCTAssertEqual(
            outputMetadataTracks.count,
            2,
            "Output must contain one sanitized foreign track and one new identity track."
        )

        var foreignTrack: AVAssetTrack?
        var foreignGroups: [AVTimedMetadataGroup] = []
        var controlledTracks: [AVAssetTrack] = []
        for track in outputMetadataTracks {
            let groups = try readTimedMetadataPipelineGroups(
                asset: outputAsset,
                track: track
            )
            let identifiers = groups.flatMap(\.items).compactMap {
                $0.identifier?.rawValue
            }
            if identifiers.contains("mdta/org.example.scene") {
                XCTAssertNil(foreignTrack)
                foreignTrack = track
                foreignGroups = groups
            }
            if identifiers.contains(where: {
                MirmirTimedMetadataPolicy.isControlledIdentifier($0)
                    || MirmirTimedMetadataPolicy
                        .resemblesControlledIdentifier($0)
            }) {
                controlledTracks.append(track)
            }
        }

        let reopenedForeignTrack = try XCTUnwrap(foreignTrack)
        XCTAssertEqual(
            foreignGroups.count,
            expectedSanitizedGroups.count,
            "Final mux must not fabricate or discard metadata groups."
        )
        XCTAssertEqual(
            foreignGroups.map(\.timeRange),
            expectedSanitizedGroups.map(\.timeRange),
            "Final mux must restore every original group boundary and order."
        )
        XCTAssertEqual(
            foreignGroups.map {
                $0.items.compactMap { $0.identifier?.rawValue }
            },
            expectedSanitizedGroups.map {
                $0.items.compactMap { $0.identifier?.rawValue }
            }
        )
        XCTAssertTrue(
            foreignGroups.flatMap(\.items).allSatisfy { item in
                guard let identifier = item.identifier?.rawValue else {
                    return false
                }
                return !MirmirTimedMetadataPolicy
                    .isControlledIdentifier(identifier)
                    && !MirmirTimedMetadataPolicy
                        .resemblesControlledIdentifier(identifier)
            }
        )
        var foreignValues: [String?] = []
        for item in foreignGroups.flatMap(\.items) {
            foreignValues.append(try await item.load(.stringValue))
        }
        XCTAssertEqual(foreignValues, expectedForeignValues)
        let reopenedForeignRange = try await reopenedForeignTrack.load(
            .timeRange
        )
        XCTAssertEqual(
            CMTimeCompare(
                reopenedForeignRange.start,
                sourceMetadataRange.start
            ),
            0
        )
        XCTAssertEqual(
            CMTimeCompare(
                reopenedForeignRange.duration,
                sourceMetadataRange.duration
            ),
            0
        )
        let staticMetadata = try await reopenedForeignTrack.load(.metadata)
        XCTAssertEqual(
            staticMetadata.compactMap { $0.identifier?.rawValue },
            ["mdta/org.example.static"]
        )
        let foreignStaticValue = try await staticMetadata.first?.load(
            .stringValue
        )
        XCTAssertEqual(foreignStaticValue, "foreign-static")
        XCTAssertEqual(controlledTracks.count, 1)
        let canonicalGroups = try readTimedMetadataPipelineGroups(
            asset: outputAsset,
            track: try XCTUnwrap(controlledTracks.first)
        )
        XCTAssertEqual(
            canonicalGroups.flatMap(\.items).compactMap {
                $0.identifier?.rawValue
            },
            ["mdta/com.mirmir.release.backend-id"]
        )
    }

    func testCleanPriorIdentityIsReplacedWithoutTrackProliferation()
        async throws {
        let fixture = try MediaOutputFixture(
            sourceExtension: "mov",
            destinationExtension: "mov"
        )
        defer { fixture.remove() }
        let firstOutputURL = fixture.directory.appendingPathComponent(
            "first-output.mov"
        )
        let duration = CMTime(value: 1, timescale: 30)
        try await writeOneFrameVideo(
            to: fixture.source,
            resolution: VideoResolution(width: 64, height: 64),
            duration: duration
        )

        let pipeline = AVFoundationMediaPipeline(
            metal: NoopMetalRenderingService()
        )
        let firstIdentity = [
            "com.mirmir.release.backend-id": "first-production-run"
        ]
        let firstProfile = try await pipeline.probe(url: fixture.source)
        let firstMediaSession = try await pipeline.beginSession(
            source: firstProfile,
            output: OutputProfile(
                url: firstOutputURL,
                resolution: VideoResolution(width: 64, height: 64),
                codec: .h264,
                preserveAudio: false,
                timedMetadataTemplate: firstIdentity
            )
        )
        let firstSession = try XCTUnwrap(
            firstMediaSession as? AVFoundationMediaSession
        )
        defer { firstSession.cancel() }
        try await processTimedMetadataPipelineSession(firstSession)
        try await firstSession.finish(finalMetadata: firstIdentity)

        let firstAsset = AVURLAsset(url: firstOutputURL)
        let firstMetadataTracks = try await firstAsset.loadTracks(
            withMediaType: .metadata
        )
        XCTAssertEqual(firstMetadataTracks.count, 1)

        let replacementIdentity = [
            "com.mirmir.release.backend-id": "replacement-production-run"
        ]
        let reprocessProfile = try await pipeline.probe(url: firstOutputURL)
        let reprocessMediaSession = try await pipeline.beginSession(
            source: reprocessProfile,
            output: OutputProfile(
                url: fixture.destination,
                resolution: VideoResolution(width: 64, height: 64),
                codec: .h264,
                preserveAudio: false,
                timedMetadataTemplate: replacementIdentity
            )
        )
        let reprocessSession = try XCTUnwrap(
            reprocessMediaSession as? AVFoundationMediaSession
        )
        defer { reprocessSession.cancel() }
        XCTAssertTrue(
            reprocessSession.sourceMediaPreservation.migrationArtifacts
                .isEmpty,
            "A clean replaceable identity track must be dropped, not migrated into a shell."
        )
        XCTAssertTrue(
            reprocessSession.sourceMediaPreservation.tracks.allSatisfy {
                $0.expectation.reference.mediaType
                    != AVMediaType.metadata.rawValue
            }
        )

        try await processTimedMetadataPipelineSession(reprocessSession)
        try await reprocessSession.finish(
            finalMetadata: replacementIdentity
        )

        let outputAsset = AVURLAsset(url: fixture.destination)
        let metadataTracks = try await outputAsset.loadTracks(
            withMediaType: .metadata
        )
        XCTAssertEqual(
            metadataTracks.count,
            1,
            "Reprocessing must not proliferate historical identity tracks."
        )
        let groups = try readTimedMetadataPipelineGroups(
            asset: outputAsset,
            track: try XCTUnwrap(metadataTracks.first)
        )
        XCTAssertEqual(
            groups.flatMap(\.items).compactMap {
                $0.identifier?.rawValue
            },
            ["mdta/com.mirmir.release.backend-id"]
        )
        let replacementValue = try await groups.flatMap(\.items).first?
            .load(.stringValue)
        XCTAssertEqual(replacementValue, "replacement-production-run")
        XCTAssertTrue(
            timedMetadataPipelineOwnedTemporaryEntries(
                in: fixture.directory
            ).isEmpty
        )
        XCTAssertNil(reprocessSession.terminalCleanupError)
    }

    func testMultiDescriptionABABindingsSurviveProductionFinalMux()
        async throws {
        let fixture = try MediaOutputFixture(
            sourceExtension: "mov",
            destinationExtension: "mov"
        )
        defer { fixture.remove() }
        let videoURL = fixture.directory.appendingPathComponent(
            "multi-description-video.mov"
        )
        let firstMetadataURL = fixture.directory.appendingPathComponent(
            "multi-description-first.mov"
        )
        let secondMetadataURL = fixture.directory.appendingPathComponent(
            "multi-description-second.mov"
        )
        let heterogeneousMetadataURL = fixture.directory.appendingPathComponent(
            "multi-description-aba.mov"
        )
        let videoDuration = CMTime(value: 1_800, timescale: 600)
        let controlledKey = "com.mirmir.release.multi-description"
        let firstIdentifier = "mdta/org.example.multi-description-first"
        let secondIdentifier = "mdta/org.example.multi-description-second"
        try await writeOneFrameVideo(
            to: videoURL,
            resolution: VideoResolution(width: 64, height: 64),
            duration: videoDuration
        )
        try await writeTimedMetadataPipelineAsset(
            to: firstMetadataURL,
            groups: [
                timedMetadataPipelineGroup(
                    items: [
                        timedMetadataPipelineItem(
                            key: controlledKey,
                            value: "remove-first"
                        ),
                        timedMetadataPipelineItem(
                            key: "org.example.multi-description-first",
                            value: "first"
                        )
                    ],
                    start: 0,
                    duration: 600
                )
            ],
            staticMetadata: []
        )
        try await writeTimedMetadataPipelineAsset(
            to: secondMetadataURL,
            groups: [
                timedMetadataPipelineGroup(
                    items: [
                        timedMetadataPipelineItem(
                            key: controlledKey,
                            value: "remove-second"
                        ),
                        timedMetadataPipelineItem(
                            key: "org.example.multi-description-second",
                            value: "second"
                        )
                    ],
                    start: 0,
                    duration: 600
                )
            ],
            staticMetadata: []
        )
        try await concatenateTimedMetadataPipelineAssets(
            [firstMetadataURL, secondMetadataURL, firstMetadataURL],
            to: heterogeneousMetadataURL
        )
        try await writeTimedMetadataPipelineSource(
            to: fixture.source,
            videoURL: videoURL,
            metadataURL: heterogeneousMetadataURL
        )

        let pipeline = AVFoundationMediaPipeline(
            metal: NoopMetalRenderingService()
        )
        let profile = try await pipeline.probe(url: fixture.source)
        let identity = [
            "com.mirmir.release.backend-id": "multi-description-final-mux"
        ]
        let mediaSession = try await pipeline.beginSession(
            source: profile,
            output: OutputProfile(
                url: fixture.destination,
                resolution: VideoResolution(width: 64, height: 64),
                codec: .h264,
                preserveAudio: false,
                timedMetadataTemplate: identity
            )
        )
        let session = try XCTUnwrap(
            mediaSession as? AVFoundationMediaSession
        )
        defer { session.cancel() }
        XCTAssertEqual(
            session.sourceMediaPreservation.migrationArtifacts.count,
            1
        )
        let migration = try XCTUnwrap(
            session.sourceMediaPreservation.migrationArtifacts.first
        )
        let migrationFormatIdentifierLists = try await
            timedMetadataPipelineFormatIdentifierLists(
                migration.sanitizedTrack
            )
        XCTAssertEqual(
            migrationFormatIdentifierLists,
            [[firstIdentifier], [secondIdentifier]]
        )
        XCTAssertEqual(
            try timedMetadataPipelineSampleFormatBindings(
                asset: migration.migrationAsset,
                track: migration.sanitizedTrack
            ),
            [[firstIdentifier], [secondIdentifier], [firstIdentifier]]
        )

        try await processTimedMetadataPipelineSession(session)
        try await session.finish(finalMetadata: identity)
        for inputURL in [
            videoURL,
            firstMetadataURL,
            secondMetadataURL,
            heterogeneousMetadataURL,
            fixture.source
        ] {
            try FileManager.default.removeItem(at: inputURL)
        }

        let outputAsset = AVURLAsset(
            url: fixture.destination,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let outputMetadataTracks = try await outputAsset.loadTracks(
            withMediaType: .metadata
        )
        XCTAssertEqual(outputMetadataTracks.count, 2)
        var preservedTrack: AVAssetTrack?
        for track in outputMetadataTracks {
            let identifiers = try await timedMetadataPipelineFormatIdentifierLists(
                track
            ).flatMap { $0 }
            if identifiers.contains(firstIdentifier) {
                preservedTrack = track
            }
        }
        let reopenedTrack = try XCTUnwrap(preservedTrack)
        let reopenedFormatIdentifierLists = try await
            timedMetadataPipelineFormatIdentifierLists(reopenedTrack)
        XCTAssertEqual(
            reopenedFormatIdentifierLists,
            [[firstIdentifier], [secondIdentifier]]
        )
        XCTAssertEqual(
            try timedMetadataPipelineSampleFormatBindings(
                asset: outputAsset,
                track: reopenedTrack
            ),
            [[firstIdentifier], [secondIdentifier], [firstIdentifier]]
        )
        let groups = try readTimedMetadataPipelineGroups(
            asset: outputAsset,
            track: reopenedTrack
        )
        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(
            groups.map {
                $0.items.compactMap { $0.identifier?.rawValue }
            },
            [[firstIdentifier], [secondIdentifier], [firstIdentifier]]
        )
        XCTAssertTrue(
            timedMetadataPipelineOwnedTemporaryEntries(
                in: fixture.directory
            ).isEmpty
        )
    }

    func testUnboundDescriptionAnchorSurvivesProductionFinalMux()
        async throws {
        let fixture = try MediaOutputFixture(
            sourceExtension: "mov",
            destinationExtension: "mov"
        )
        defer { fixture.remove() }
        let videoURL = fixture.directory.appendingPathComponent(
            "unbound-description-video.mov"
        )
        let firstMetadataURL = fixture.directory.appendingPathComponent(
            "unbound-description-first.mov"
        )
        let secondMetadataURL = fixture.directory.appendingPathComponent(
            "unbound-description-second.mov"
        )
        let heterogeneousMetadataURL = fixture.directory.appendingPathComponent(
            "unbound-description-heterogeneous.mov"
        )
        let unboundMetadataURL = fixture.directory.appendingPathComponent(
            "unbound-description-source.mov"
        )
        let videoDuration = CMTime(value: 1_800, timescale: 600)
        let controlledKey = "com.mirmir.release.unbound-description"
        let firstIdentifier = "mdta/org.example.unbound-description-first"
        let secondIdentifier = "mdta/org.example.unbound-description-second"
        try await writeOneFrameVideo(
            to: videoURL,
            resolution: VideoResolution(width: 64, height: 64),
            duration: videoDuration
        )
        try await writeTimedMetadataPipelineAsset(
            to: firstMetadataURL,
            groups: [
                timedMetadataPipelineGroup(
                    items: [
                        timedMetadataPipelineItem(
                            key: controlledKey,
                            value: "remove-first"
                        ),
                        timedMetadataPipelineItem(
                            key: "org.example.unbound-description-first",
                            value: "first"
                        )
                    ],
                    start: 0,
                    duration: 1_800
                )
            ],
            staticMetadata: []
        )
        try await writeTimedMetadataPipelineAsset(
            to: secondMetadataURL,
            groups: [
                timedMetadataPipelineGroup(
                    items: [
                        timedMetadataPipelineItem(
                            key: controlledKey,
                            value: "remove-second"
                        ),
                        timedMetadataPipelineItem(
                            key: "org.example.unbound-description-second",
                            value: "second"
                        )
                    ],
                    start: 0,
                    duration: 1_800
                )
            ],
            staticMetadata: []
        )
        try await concatenateTimedMetadataPipelineAssets(
            [firstMetadataURL, secondMetadataURL],
            to: heterogeneousMetadataURL
        )
        try await writeTimedMetadataPipelineUnboundTrack(
            from: heterogeneousMetadataURL,
            presenting: CMTimeRange(
                start: .zero,
                duration: videoDuration
            ),
            to: unboundMetadataURL
        )
        try await writeTimedMetadataPipelineSource(
            to: fixture.source,
            videoURL: videoURL,
            metadataURL: unboundMetadataURL
        )

        let sourceAsset = AVURLAsset(
            url: fixture.source,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let sourceMetadataTracks = try await sourceAsset.loadTracks(
            withMediaType: .metadata
        )
        let sourceMetadataTrack = try XCTUnwrap(
            sourceMetadataTracks.first
        )
        let sourceFormatDescriptions = try await sourceMetadataTrack.load(
            .formatDescriptions
        )
        XCTAssertEqual(
            sourceFormatDescriptions.count,
            2
        )
        XCTAssertEqual(
            try timedMetadataPipelineSampleFormatBindings(
                asset: sourceAsset,
                track: sourceMetadataTrack
            ).count,
            1,
            "The second complete source description must have no presented sample."
        )

        let pipeline = AVFoundationMediaPipeline(
            metal: NoopMetalRenderingService()
        )
        let profile = try await pipeline.probe(url: fixture.source)
        let identity = [
            "com.mirmir.release.backend-id": "unbound-description-final-mux"
        ]
        let mediaSession = try await pipeline.beginSession(
            source: profile,
            output: OutputProfile(
                url: fixture.destination,
                resolution: VideoResolution(width: 64, height: 64),
                codec: .h264,
                preserveAudio: false,
                timedMetadataTemplate: identity
            )
        )
        let session = try XCTUnwrap(
            mediaSession as? AVFoundationMediaSession
        )
        defer { session.cancel() }
        XCTAssertEqual(
            session.sourceMediaPreservation.migrationArtifacts.count,
            1
        )
        let migration = try XCTUnwrap(
            session.sourceMediaPreservation.migrationArtifacts.first
        )
        let migrationIdentifierLists = try await
            timedMetadataPipelineFormatIdentifierLists(
                migration.sanitizedTrack
            )
        XCTAssertEqual(
            migrationIdentifierLists,
            [[firstIdentifier], [secondIdentifier]]
        )
        XCTAssertEqual(
            try timedMetadataPipelineSampleFormatBindings(
                asset: migration.migrationAsset,
                track: migration.sanitizedTrack
            ),
            [[firstIdentifier]]
        )
        let migrationGroups = try readTimedMetadataPipelineGroups(
            asset: migration.migrationAsset,
            track: migration.sanitizedTrack
        )
        XCTAssertEqual(
            migrationGroups.map {
                $0.items.compactMap { $0.identifier?.rawValue }
            },
            [[firstIdentifier]]
        )

        try await processTimedMetadataPipelineSession(session)
        try await session.finish(finalMetadata: identity)
        for inputURL in [
            videoURL,
            firstMetadataURL,
            secondMetadataURL,
            heterogeneousMetadataURL,
            unboundMetadataURL,
            fixture.source
        ] {
            try FileManager.default.removeItem(at: inputURL)
        }

        let outputAsset = AVURLAsset(
            url: fixture.destination,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let outputMetadataTracks = try await outputAsset.loadTracks(
            withMediaType: .metadata
        )
        XCTAssertEqual(outputMetadataTracks.count, 2)
        var preservedTrack: AVAssetTrack?
        for track in outputMetadataTracks {
            let identifiers = try await timedMetadataPipelineFormatIdentifierLists(
                track
            ).flatMap { $0 }
            if identifiers.contains(firstIdentifier) {
                preservedTrack = track
            }
        }
        let reopenedTrack = try XCTUnwrap(preservedTrack)
        let reopenedIdentifierLists = try await
            timedMetadataPipelineFormatIdentifierLists(reopenedTrack)
        XCTAssertEqual(
            reopenedIdentifierLists,
            [[firstIdentifier], [secondIdentifier]]
        )
        XCTAssertEqual(
            try timedMetadataPipelineSampleFormatBindings(
                asset: outputAsset,
                track: reopenedTrack
            ),
            [[firstIdentifier]]
        )
        let groups = try readTimedMetadataPipelineGroups(
            asset: outputAsset,
            track: reopenedTrack
        )
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(
            groups.map {
                $0.items.compactMap { $0.identifier?.rawValue }
            },
            [[firstIdentifier]]
        )

        let expandedMedia = try await
            inspectTimedMetadataPipelineCompleteMedia(
                at: fixture.destination,
                containing: firstIdentifier
            )
        XCTAssertEqual(
            expandedMedia.sampleFormatBindings,
            [[firstIdentifier], [secondIdentifier]],
            "Expanding the complete media table must expose the hidden B anchor."
        )
        XCTAssertEqual(expandedMedia.samplePayloadHex.count, 2)
        XCTAssertEqual(
            expandedMedia.samplePayloadHex.last,
            "0000000800000000",
            "The hidden anchor must be the adaptor-proven zero-item boxed-metadata payload."
        )
        XCTAssertEqual(
            expandedMedia.decodedIdentifiersByGroup,
            [[firstIdentifier], []],
            "The structurally exposed anchor must decode as a zero-item group."
        )
        XCTAssertTrue(
            timedMetadataPipelineOwnedTemporaryEntries(
                in: fixture.directory
            ).isEmpty
        )
    }
}

private enum TimedMetadataPipelineIntegrationError: Error {
    case rejectedInput
    case writerFailed(Error?)
    case readerRejectedOutput
    case readerFailed(Error?)
    case invalidMetadataItem
    case formatDescriptionFailed(OSStatus)
    case trackCreationFailed(AVMediaType)
}

private func timedMetadataPipelineSourceGroups()
    -> [AVTimedMetadataGroup] {
    [
        timedMetadataPipelineGroup(
            items: [
                timedMetadataPipelineItem(
                    key: "com.mirmir.release.leading",
                    value: "remove-leading"
                )
            ],
            start: 600,
            duration: 120
        ),
        timedMetadataPipelineGroup(
            items: [
                timedMetadataPipelineItem(
                    key: "com.mirmir.release.stale-scene",
                    value: "remove-scene"
                ),
                timedMetadataPipelineItem(
                    key: "org.example.scene",
                    value: "scene-7"
                )
            ],
            start: 720,
            duration: 180
        ),
        timedMetadataPipelineGroup(
            items: [
                timedMetadataPipelineItem(
                    key: "org.example.rating",
                    value: "five-stars"
                )
            ],
            start: 900,
            duration: 300
        ),
        timedMetadataPipelineGroup(
            items: [
                timedMetadataPipelineItem(
                    key: "com.mirmir.release.trailing",
                    value: "remove-trailing"
                )
            ],
            start: 1_200,
            duration: 300
        )
    ]
}

private func timedMetadataPipelineItem(
    key: String,
    value: String
) -> AVMutableMetadataItem {
    let item = AVMutableMetadataItem()
    item.keySpace = .quickTimeMetadata
    item.key = key as NSString
    item.value = value as NSString
    item.dataType = kCMMetadataBaseDataType_UTF8 as String
    return item
}

private func timedMetadataPipelineGroup(
    items: [AVMetadataItem],
    start: Int64,
    duration: Int64
) -> AVTimedMetadataGroup {
    AVTimedMetadataGroup(
        items: items,
        timeRange: CMTimeRange(
            start: CMTime(value: start, timescale: 600),
            duration: CMTime(value: duration, timescale: 600)
        )
    )
}

private func writeTimedMetadataPipelineAsset(
    to url: URL,
    groups: [AVTimedMetadataGroup],
    staticMetadata: [AVMetadataItem]
) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(
        mediaType: .metadata,
        outputSettings: nil,
        sourceFormatHint: try timedMetadataPipelineFormatDescription(groups)
    )
    input.expectsMediaDataInRealTime = false
    input.mediaTimeScale = 600
    input.metadata = staticMetadata
    guard writer.canAdd(input) else {
        throw TimedMetadataPipelineIntegrationError.rejectedInput
    }
    writer.add(input)
    let adaptor = AVAssetWriterInputMetadataAdaptor(
        assetWriterInput: input
    )
    guard writer.startWriting() else {
        throw TimedMetadataPipelineIntegrationError.writerFailed(
            writer.error
        )
    }
    writer.startSession(atSourceTime: .zero)
    for group in groups {
        while !input.isReadyForMoreMediaData {
            try Task.checkCancellation()
            guard writer.status == .writing else {
                throw TimedMetadataPipelineIntegrationError.writerFailed(
                    writer.error
                )
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        guard adaptor.append(group) else {
            throw TimedMetadataPipelineIntegrationError.writerFailed(
                writer.error
            )
        }
    }
    guard let endTime = groups.map(\.timeRange.end).max() else {
        throw TimedMetadataPipelineIntegrationError.invalidMetadataItem
    }
    writer.endSession(atSourceTime: endTime)
    input.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else {
        throw TimedMetadataPipelineIntegrationError.writerFailed(
            writer.error
        )
    }
}

private func timedMetadataPipelineFormatDescription(
    _ groups: [AVTimedMetadataGroup]
) throws -> CMMetadataFormatDescription {
    var seen: Set<String> = []
    var specifications: [[String: Any]] = []
    for item in groups.flatMap(\.items) {
        guard let identifier = item.identifier?.rawValue,
              let dataType = item.dataType else {
            throw TimedMetadataPipelineIntegrationError.invalidMetadataItem
        }
        let identity = identifier + "\u{0}" + dataType
        guard seen.insert(identity).inserted else { continue }
        specifications.append([
            kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier
                as String: identifier,
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType
                as String: dataType
        ])
    }
    var description: CMMetadataFormatDescription?
    let status = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
        allocator: kCFAllocatorDefault,
        metadataType: kCMMetadataFormatType_Boxed,
        metadataSpecifications: specifications as CFArray,
        formatDescriptionOut: &description
    )
    guard status == noErr, let description else {
        throw TimedMetadataPipelineIntegrationError
            .formatDescriptionFailed(status)
    }
    return description
}

private func writeTimedMetadataPipelineSource(
    to outputURL: URL,
    videoURL: URL,
    metadataURL: URL
) async throws {
    let videoAsset = AVURLAsset(
        url: videoURL,
        options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
    )
    let metadataAsset = AVURLAsset(
        url: metadataURL,
        options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
    )
    let videoTracks = try await videoAsset.loadTracks(
        withMediaType: .video
    )
    let metadataTracks = try await metadataAsset.loadTracks(
        withMediaType: .metadata
    )
    let videoTrack = try XCTUnwrap(videoTracks.first)
    let metadataTrack = try XCTUnwrap(metadataTracks.first)

    let movie = AVMutableMovie()
    movie.timescale = 600
    movie.defaultMediaDataStorage = AVMediaDataStorage(
        url: outputURL,
        options: nil
    )
    for track in [videoTrack, metadataTrack] {
        guard let destinationTrack = movie.addMutableTrack(
            withMediaType: track.mediaType,
            copySettingsFrom: track,
            options: nil
        ) else {
            throw TimedMetadataPipelineIntegrationError
                .trackCreationFailed(track.mediaType)
        }
        let naturalTimeScale = try await track.load(.naturalTimeScale)
        if naturalTimeScale > 0 {
            destinationTrack.timescale = naturalTimeScale
        }
        destinationTrack.isEnabled = try await track.load(.isEnabled)
        destinationTrack.languageCode = try await track.load(.languageCode)
        destinationTrack.extendedLanguageTag = try await track.load(
            .extendedLanguageTag
        )
        destinationTrack.metadata = try await track.load(.metadata)
        let timeRange = try await track.load(.timeRange)
        try destinationTrack.insertTimeRange(
            timeRange,
            of: track,
            at: timeRange.start,
            copySampleData: true
        )
        guard track.mediaType == .metadata else { continue }
        let segments = try await track.load(.segments)
        let copiedMediaTimeRange =
            destinationTrack.mediaPresentationTimeRange
        destinationTrack.removeTimeRange(destinationTrack.timeRange)
        guard destinationTrack.mediaPresentationTimeRange
                == copiedMediaTimeRange else {
            throw TimedMetadataPipelineIntegrationError
                .trackCreationFailed(track.mediaType)
        }
        for segment in segments where !segment.isEmpty {
            guard destinationTrack.insertMediaTimeRange(
                segment.timeMapping.source,
                into: segment.timeMapping.target
            ) else {
                throw TimedMetadataPipelineIntegrationError
                    .trackCreationFailed(track.mediaType)
            }
        }
        try retainTimedMetadataPipelineUnboundDescriptions(
            from: try await track.load(.formatDescriptions),
            on: destinationTrack,
            naturalTimeScale: naturalTimeScale
        )
    }
    try movie.writeHeader(
        to: outputURL,
        fileType: .mov,
        options: .addMovieHeaderToDestination
    )
}

private func concatenateTimedMetadataPipelineAssets(
    _ sourceURLs: [URL],
    to outputURL: URL
) async throws {
    let sourceAssets = sourceURLs.map {
        AVURLAsset(
            url: $0,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
    }
    var sourceTracks: [AVAssetTrack] = []
    for sourceAsset in sourceAssets {
        let tracks = try await sourceAsset.loadTracks(
            withMediaType: .metadata
        )
        sourceTracks.append(try XCTUnwrap(tracks.first))
    }
    let firstTrack = try XCTUnwrap(sourceTracks.first)
    let movie = AVMutableMovie()
    movie.timescale = 600
    movie.defaultMediaDataStorage = AVMediaDataStorage(
        url: outputURL,
        options: nil
    )
    guard let destinationTrack = movie.addMutableTrack(
        withMediaType: .metadata,
        copySettingsFrom: firstTrack,
        options: nil
    ) else {
        throw TimedMetadataPipelineIntegrationError
            .trackCreationFailed(.metadata)
    }
    let naturalTimeScale = try await firstTrack.load(.naturalTimeScale)
    if naturalTimeScale > 0 {
        destinationTrack.timescale = naturalTimeScale
    }
    var insertionTime = CMTime.zero
    for sourceTrack in sourceTracks {
        let sourceTimeRange = try await sourceTrack.load(.timeRange)
        try destinationTrack.insertTimeRange(
            sourceTimeRange,
            of: sourceTrack,
            at: insertionTime,
            copySampleData: true
        )
        insertionTime = CMTimeAdd(
            insertionTime,
            sourceTimeRange.duration
        )
    }
    try movie.writeHeader(
        to: outputURL,
        fileType: .mov,
        options: .addMovieHeaderToDestination
    )
    withExtendedLifetime(sourceAssets) {}
}

private func writeTimedMetadataPipelineUnboundTrack(
    from sourceURL: URL,
    presenting presentedTimeRange: CMTimeRange,
    to outputURL: URL
) async throws {
    let sourceAsset = AVURLAsset(
        url: sourceURL,
        options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
    )
    let sourceTracks = try await sourceAsset.loadTracks(
        withMediaType: .metadata
    )
    let sourceTrack = try XCTUnwrap(sourceTracks.first)
    let movie = AVMutableMovie()
    movie.timescale = 600
    movie.defaultMediaDataStorage = AVMediaDataStorage(
        url: outputURL,
        options: nil
    )
    guard let destinationTrack = movie.addMutableTrack(
        withMediaType: .metadata,
        copySettingsFrom: sourceTrack,
        options: nil
    ) else {
        throw TimedMetadataPipelineIntegrationError
            .trackCreationFailed(.metadata)
    }
    let naturalTimeScale = try await sourceTrack.load(.naturalTimeScale)
    if naturalTimeScale > 0 {
        destinationTrack.timescale = naturalTimeScale
    }
    destinationTrack.isEnabled = try await sourceTrack.load(.isEnabled)
    destinationTrack.languageCode = try await sourceTrack.load(
        .languageCode
    )
    destinationTrack.extendedLanguageTag = try await sourceTrack.load(
        .extendedLanguageTag
    )
    destinationTrack.metadata = try await sourceTrack.load(.metadata)
    let completeSourceTimeRange = try await sourceTrack.load(.timeRange)
    try destinationTrack.insertTimeRange(
        completeSourceTimeRange,
        of: sourceTrack,
        at: .zero,
        copySampleData: true
    )
    destinationTrack.removeTimeRange(destinationTrack.timeRange)
    guard destinationTrack.insertMediaTimeRange(
        presentedTimeRange,
        into: CMTimeRange(
            start: .zero,
            duration: presentedTimeRange.duration
        )
    ) else {
        throw TimedMetadataPipelineIntegrationError
            .trackCreationFailed(.metadata)
    }
    try movie.writeHeader(
        to: outputURL,
        fileType: .mov,
        options: .addMovieHeaderToDestination
    )
    withExtendedLifetime(sourceAsset) {}
}

private func retainTimedMetadataPipelineUnboundDescriptions(
    from sourceDescriptions: [CMFormatDescription],
    on destinationTrack: AVMutableMovieTrack,
    naturalTimeScale: CMTimeScale
) throws {
    var remainingSourceDescriptions = sourceDescriptions
    for rawDescription in destinationTrack.formatDescriptions {
        let destinationDescription = rawDescription as! CMFormatDescription
        let destinationIdentity = try
            OutputMediaMetadataFormatSchemaIdentityReader
            .canonicalFormatDescription(destinationDescription)
        guard let sourceIndex = try remainingSourceDescriptions.firstIndex(
            where: { sourceDescription in
                try OutputMediaMetadataFormatSchemaIdentityReader
                    .canonicalFormatDescription(sourceDescription)
                    == destinationIdentity
            }
        ) else {
            throw TimedMetadataPipelineIntegrationError.invalidMetadataItem
        }
        remainingSourceDescriptions.remove(at: sourceIndex)
    }
    for description in remainingSourceDescriptions {
        try OutputMediaMetadataFormatDescriptionAnchorWriter.append(
            description,
            to: destinationTrack,
            naturalTimeScale: naturalTimeScale
        )
    }
}

private func processTimedMetadataPipelineSession(
    _ session: AVFoundationMediaSession
) async throws {
    var frameCount = 0
    while let record = try await session.nextSourceFrame() {
        let output = try PixelBufferBridge.dequeue(
            from: session.outputPixelBufferPool
        )
        try fillNV12(output)
        try await session.appendOutput(
            pixelBuffer: output,
            timing: record.timing
        )
        frameCount += 1
    }
    XCTAssertEqual(frameCount, 1)
}

private func readTimedMetadataPipelineGroups(
    asset: AVAsset,
    track: AVAssetTrack
) throws -> [AVTimedMetadataGroup] {
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(
        track: track,
        outputSettings: nil
    )
    guard reader.canAdd(output) else {
        throw TimedMetadataPipelineIntegrationError.readerRejectedOutput
    }
    reader.add(output)
    let adaptor = AVAssetReaderOutputMetadataAdaptor(
        assetReaderTrackOutput: output
    )
    guard reader.startReading() else {
        throw TimedMetadataPipelineIntegrationError.readerFailed(
            reader.error
        )
    }
    var groups: [AVTimedMetadataGroup] = []
    while let group = adaptor.nextTimedMetadataGroup() {
        groups.append(group)
    }
    guard reader.status == .completed else {
        throw TimedMetadataPipelineIntegrationError.readerFailed(
            reader.error
        )
    }
    return groups
}

private func timedMetadataPipelineFormatIdentifierLists(
    _ track: AVAssetTrack
) async throws -> [[String]] {
    try await track.load(.formatDescriptions).map { description in
        (CMMetadataFormatDescriptionGetIdentifiers(description)
            as? [String]) ?? []
    }
}

private func timedMetadataPipelineSampleFormatBindings(
    asset: AVAsset,
    track: AVAssetTrack
) throws -> [[String]] {
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(
        track: track,
        outputSettings: nil
    )
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else {
        throw TimedMetadataPipelineIntegrationError.readerRejectedOutput
    }
    reader.add(output)
    guard reader.startReading() else {
        throw TimedMetadataPipelineIntegrationError.readerFailed(
            reader.error
        )
    }
    var bindings: [[String]] = []
    while let sampleBuffer = output.copyNextSampleBuffer() {
        let sampleCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard sampleCount > 0 else { continue }
        guard let description = CMSampleBufferGetFormatDescription(
            sampleBuffer
        ) else {
            throw TimedMetadataPipelineIntegrationError.invalidMetadataItem
        }
        let identifiers = (
            CMMetadataFormatDescriptionGetIdentifiers(description)
                as? [String]
        ) ?? []
        bindings.append(
            contentsOf: repeatElement(
                identifiers,
                count: sampleCount
            )
        )
    }
    guard reader.status == .completed else {
        throw TimedMetadataPipelineIntegrationError.readerFailed(
            reader.error
        )
    }
    return bindings
}

private struct TimedMetadataPipelineCompleteMediaInspection {
    let sampleFormatBindings: [[String]]
    let samplePayloadHex: [String]
    let decodedIdentifiersByGroup: [[String]]
}

private func inspectTimedMetadataPipelineCompleteMedia(
    at url: URL,
    containing requiredIdentifier: String
) async throws -> TimedMetadataPipelineCompleteMediaInspection {
    let movie = AVMutableMovie(
        url: url,
        options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
    )
    let metadataTracks = try await movie.loadTracks(
        withMediaType: .metadata
    )
    var selectedTrack: AVMutableMovieTrack?
    for mutableTrack in metadataTracks {
        let identifiers = try await
            timedMetadataPipelineFormatIdentifierLists(mutableTrack)
                .flatMap { $0 }
        if identifiers.contains(requiredIdentifier) {
            selectedTrack = mutableTrack
        }
    }
    let track = try XCTUnwrap(selectedTrack)
    let completeMediaTimeRange = track.mediaPresentationTimeRange
    track.removeTimeRange(track.timeRange)
    guard track.insertMediaTimeRange(
        completeMediaTimeRange,
        into: CMTimeRange(
            start: .zero,
            duration: completeMediaTimeRange.duration
        )
    ) else {
        throw TimedMetadataPipelineIntegrationError
            .trackCreationFailed(.metadata)
    }
    let bindings = try timedMetadataPipelineSampleFormatBindings(
        asset: movie,
        track: track
    )
    let payloadHex = try timedMetadataPipelineSamplePayloadHex(
        asset: movie,
        track: track
    )
    let groups = try readTimedMetadataPipelineGroups(
        asset: movie,
        track: track
    )
    return TimedMetadataPipelineCompleteMediaInspection(
        sampleFormatBindings: bindings,
        samplePayloadHex: payloadHex,
        decodedIdentifiersByGroup: groups.map {
            $0.items.compactMap { $0.identifier?.rawValue }
        }
    )
}

private func timedMetadataPipelineSamplePayloadHex(
    asset: AVAsset,
    track: AVAssetTrack
) throws -> [String] {
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(
        track: track,
        outputSettings: nil
    )
    output.alwaysCopiesSampleData = true
    guard reader.canAdd(output) else {
        throw TimedMetadataPipelineIntegrationError.readerRejectedOutput
    }
    reader.add(output)
    guard reader.startReading() else {
        throw TimedMetadataPipelineIntegrationError.readerFailed(
            reader.error
        )
    }
    var payloadHex: [String] = []
    while let sampleBuffer = output.copyNextSampleBuffer() {
        guard CMSampleBufferGetNumSamples(sampleBuffer) > 0 else {
            continue
        }
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            payloadHex.append("")
            continue
        }
        let length = CMBlockBufferGetDataLength(blockBuffer)
        var data = Data(count: length)
        let copyStatus = data.withUnsafeMutableBytes { bytes -> OSStatus in
            guard let baseAddress = bytes.baseAddress else {
                return length == 0
                    ? kCMBlockBufferNoErr
                    : kCMBlockBufferBadPointerParameterErr
            }
            return CMBlockBufferCopyDataBytes(
                blockBuffer,
                atOffset: 0,
                dataLength: length,
                destination: baseAddress
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else {
            throw TimedMetadataPipelineIntegrationError.readerFailed(nil)
        }
        payloadHex.append(data.map {
            String(format: "%02x", $0)
        }.joined())
    }
    guard reader.status == .completed else {
        throw TimedMetadataPipelineIntegrationError.readerFailed(
            reader.error
        )
    }
    return payloadHex
}

private func timedMetadataPipelineOwnershipMarkers(
    in directory: URL
) -> [URL] {
    timedMetadataPipelineDirectoryEntries(in: directory).filter {
        $0.lastPathComponent.hasPrefix(".mirmir-temporary-owner-")
            && $0.lastPathComponent.hasSuffix(".marker")
    }
}

private func timedMetadataPipelineOwnedTemporaryEntries(
    in directory: URL
) -> [URL] {
    timedMetadataPipelineDirectoryEntries(in: directory).filter { url in
        let name = url.lastPathComponent
        return name.contains(".metadata-stage-")
            || (name.hasPrefix(".mirmir-temporary-owner-")
                && name.hasSuffix(".marker"))
            || (name.hasPrefix(".destination.mirmir-")
                && name.contains(".partial"))
            || name.contains(".video-stage")
    }
}

private func timedMetadataPipelineDirectoryEntries(
    in directory: URL
) -> [URL] {
    (try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
    )) ?? []
}
