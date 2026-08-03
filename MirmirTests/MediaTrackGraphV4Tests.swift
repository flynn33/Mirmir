import AVFoundation
import CoreMedia
import XCTest
@testable import Mirmir

final class MediaTrackGraphPlannerV4Tests: XCTestCase {
    func testDefaultPlanExplicitlyPreservesEveryTrackGroupAndAssociation() throws {
        let source = try makeMultiTrackGraph()
        let identified = try MediaTrackGraphPlannerV4.makePlan(source: source)
        let plan = identified.plan

        XCTAssertEqual(plan.tracks.count, source.tracks.count)
        XCTAssertTrue(plan.tracks.allSatisfy {
            $0.action == .passThrough
                && $0.origin == .defaultPreservation
                && $0.expectedOutput == $0.source
        })
        XCTAssertEqual(plan.groups.count, source.groups.count)
        XCTAssertTrue(plan.groups.allSatisfy {
            $0.action == .passThrough
                && $0.origin == .defaultPreservation
        })
        XCTAssertEqual(plan.associations.count, source.associations.count)
        XCTAssertTrue(plan.associations.allSatisfy {
            $0.action == .passThrough
        })

        let enabledVideoIDs = source.tracks.filter {
            $0.enabled && $0.kind == .video
        }.map { $0.identity.stableID }
        XCTAssertEqual(enabledVideoIDs.count, 2)
        XCTAssertEqual(
            plan.tracks.filter {
                $0.source.enabled && $0.source.kind == .video
            }.map { $0.source.identity.stableID },
            enabledVideoIDs
        )
        XCTAssertEqual(
            Set(source.tracks.map(\.kind)),
            Set([
                .video, .audio, .subtitle, .caption, .chapter, .timecode,
                .timedMetadata, .auxiliary
            ])
        )
        XCTAssertNoThrow(try identified.verify())
    }

    func testEveryEnabledVideoCanBeProcessedWithoutFirstTrackSelection() throws {
        let source = try makeMultiTrackGraph()
        let videoTracks = source.tracks.filter {
            $0.enabled && $0.kind == .video
        }
        let directives = try videoTracks.reversed().enumerated().map {
            offset, track in
            MediaTrackDirectiveV4(
                trackID: track.identity.stableID,
                action: .process,
                targetFormatDescriptors: [try makeFormat(seed: 80 + offset)],
                dropConsent: nil
            )
        }
        let plan = try MediaTrackGraphPlannerV4.makePlan(
            source: source,
            request: MediaTrackGraphPlanningRequestV4(
                trackDirectives: directives
            )
        ).plan

        let plannedVideos = plan.tracks.filter { $0.source.kind == .video }
        XCTAssertEqual(plannedVideos.count, 2)
        XCTAssertTrue(plannedVideos.allSatisfy { $0.action == .process })
        XCTAssertEqual(
            plan.tracks.map { $0.source.identity.stableID },
            source.tracks.map { $0.identity.stableID }
        )
        XCTAssertTrue(
            plan.tracks.filter { $0.source.kind != .video }.allSatisfy {
                $0.action == .passThrough
                    && $0.origin == .defaultPreservation
            }
        )
    }

    func testDropRequiresSubjectBoundConsent() throws {
        let source = try makeMultiTrackGraph()
        let subtitleID = try MediaTrackStableIDV4("subtitle-en")
        let missingConsent = MediaTrackDirectiveV4(
            trackID: subtitleID,
            action: .dropWithConsent,
            targetFormatDescriptors: [],
            dropConsent: nil
        )
        XCTAssertThrowsError(
            try MediaTrackGraphPlannerV4.makePlan(
                source: source,
                request: .init(trackDirectives: [missingConsent])
            )
        ) { error in
            XCTAssertEqual(
                error as? MediaTrackGraphPlannerV4Error,
                .missingDropConsent(subjectID: subtitleID.rawValue)
            )
        }

        let wrongConsent = try MediaTrackDropConsentV4(
            subjectID: "caption-en",
            reasonID: "user-removed-subtitles",
            approvalSHA256: try testHash(90)
        )
        XCTAssertThrowsError(
            try MediaTrackGraphPlannerV4.makePlan(
                source: source,
                request: .init(trackDirectives: [MediaTrackDirectiveV4(
                    trackID: subtitleID,
                    action: .dropWithConsent,
                    targetFormatDescriptors: [],
                    dropConsent: wrongConsent
                )])
            )
        )
    }

    func testPartialAlternateGroupDropMustExplicitlyReconstructGroup() throws {
        let source = try makeMultiTrackGraph()
        let spanishID = try MediaTrackStableIDV4("audio-es")
        let audioGroupID = try MediaTrackGroupStableIDV4("audio-alternates")
        let trackConsent = try consent(for: spanishID.rawValue, seed: 101)
        let dropSpanish = MediaTrackDirectiveV4(
            trackID: spanishID,
            action: .dropWithConsent,
            targetFormatDescriptors: [],
            dropConsent: trackConsent
        )

        XCTAssertThrowsError(
            try MediaTrackGraphPlannerV4.makePlan(
                source: source,
                request: .init(trackDirectives: [dropSpanish])
            )
        ) { error in
            guard case .invalidGroupAction(groupID: audioGroupID, _) =
                error as? MediaTrackGraphPlannerV4Error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let englishID = try MediaTrackStableIDV4("audio-en")
        let reconstructed = MediaTrackGroupDirectiveV4(
            groupID: audioGroupID,
            action: .transcode,
            outputMemberTrackIDs: [englishID],
            outputDefaultTrackID: englishID,
            dropConsent: try consent(for: audioGroupID.rawValue, seed: 102)
        )
        let plan = try MediaTrackGraphPlannerV4.makePlan(
            source: source,
            request: .init(
                trackDirectives: [dropSpanish],
                groupDirectives: [reconstructed]
            )
        ).plan
        XCTAssertEqual(
            plan.groups.first?.expectedOutput?.memberTrackIDs,
            [englishID]
        )
        XCTAssertEqual(
            plan.tracks.first {
                $0.source.identity.stableID == spanishID
            }?.action,
            .dropWithConsent
        )
    }

    func testDroppingWholeGroupAndEdgesIsExplicit() throws {
        let source = try makeMultiTrackGraph()
        let englishID = try MediaTrackStableIDV4("audio-en")
        let spanishID = try MediaTrackStableIDV4("audio-es")
        let groupID = try MediaTrackGroupStableIDV4("audio-alternates")
        let trackDrops = try [englishID, spanishID].enumerated().map {
            offset, id in
            MediaTrackDirectiveV4(
                trackID: id,
                action: .dropWithConsent,
                targetFormatDescriptors: [],
                dropConsent: try consent(
                    for: id.rawValue,
                    seed: UInt64(110 + offset)
                )
            )
        }
        let groupDrop = MediaTrackGroupDirectiveV4(
            groupID: groupID,
            action: .dropWithConsent,
            outputMemberTrackIDs: nil,
            outputDefaultTrackID: nil,
            dropConsent: try consent(for: groupID.rawValue, seed: 112)
        )
        let plan = try MediaTrackGraphPlannerV4.makePlan(
            source: source,
            request: .init(
                trackDirectives: trackDrops,
                groupDirectives: [groupDrop]
            )
        ).plan

        XCTAssertNil(plan.groups.first?.expectedOutput)
        XCTAssertEqual(plan.groups.first?.action, .dropWithConsent)
        let audioEdges = plan.associations.filter {
            $0.source.sourceTrackID == englishID
                || $0.source.targetTrackID == englishID
                || $0.source.sourceTrackID == spanishID
                || $0.source.targetTrackID == spanishID
        }
        XCTAssertFalse(audioEdges.isEmpty)
        XCTAssertTrue(audioEdges.allSatisfy {
            $0.action == .dropWithConsent && !$0.dropConsents.isEmpty
        })
    }

    func testSemanticVerifierAcceptsExactGraphAndCanonicalRoundTrip() throws {
        let source = try makeMultiTrackGraph()
        let plan = try MediaTrackGraphPlannerV4.makePlan(source: source)
        let output = try expectedOutput(for: plan.plan)
        let report = try MediaTrackSemanticVerifierV4.verify(
            plan: plan,
            output: output
        )

        XCTAssertTrue(report.isConformant)
        XCTAssertTrue(report.diagnostics.isEmpty)
        let graphData = try source.canonicalData
        let decoded = try ASHCanonicalJSONV4.decode(
            MediaTrackGraphV4.self,
            from: graphData
        )
        try decoded.validate()
        XCTAssertEqual(
            try decoded.canonicalSHA256,
            try source.canonicalSHA256
        )
        let planData = try ASHCanonicalJSONV4.encode(plan)
        let decodedPlan = try ASHCanonicalJSONV4.decode(
            MediaTrackGraphIdentifiedPlanV4.self,
            from: planData
        )
        XCTAssertNoThrow(try decodedPlan.verify())
        XCTAssertEqual(decodedPlan, plan)
    }

    func testSemanticVerifierReportsEverySilentDrop() throws {
        let source = try makeMultiTrackGraph()
        let plan = try MediaTrackGraphPlannerV4.makePlan(source: source)
        let mainVideo = try XCTUnwrap(source.tracks.first)
        let output = try MediaTrackGraphV4(
            tracks: [mainVideo],
            groups: [],
            associations: [],
            diagnostics: []
        )
        let report = try MediaTrackSemanticVerifierV4.verify(
            plan: plan,
            output: output
        )

        XCTAssertFalse(report.isConformant)
        let missingPaths = report.diagnostics.filter {
            $0.code == .missingOutputTrack
        }.map(\.path)
        XCTAssertEqual(missingPaths.count, source.tracks.count - 1)
        for track in source.tracks.dropFirst() {
            XCTAssertTrue(
                missingPaths.contains(
                    "tracks.\(track.identity.stableID.rawValue)"
                )
            )
        }
        XCTAssertTrue(report.diagnostics.contains {
            $0.code == .missingOutputGroup
        })
        XCTAssertTrue(report.diagnostics.contains {
            $0.code == .associationMismatch
        })
    }

    func testSemanticVerifierDiagnosesAllProtectedTrackSemantics() throws {
        let source = try makeMultiTrackGraph()
        let plan = try MediaTrackGraphPlannerV4.makePlan(source: source)
        let audioID = try MediaTrackStableIDV4("audio-es")
        let original = try XCTUnwrap(source.track(id: audioID))
        let altered = try MediaTrackNodeV4(
            identity: original.identity,
            enabled: !original.enabled,
            kind: .auxiliary,
            sourceMediaTypeID: "changed_media_type",
            language: MediaTrackLanguageV4(
                languageCode: "fra",
                extendedLanguageTag: "fr-FR"
            ),
            roleIDs: ["commentary"],
            timebase: ExactRationalV4(1, 1_000),
            timeRange: MediaExactTimeRangeV4(
                start: .zero,
                duration: ExactRationalV4(59)
            ),
            edits: [],
            formatDescriptors: [try makeFormat(seed: 130)],
            metadataFingerprint: try testHash(131)
        )
        let tracks = source.tracks.map {
            $0.identity.stableID == audioID ? altered : $0
        }
        let output = try MediaTrackGraphV4(
            tracks: tracks,
            groups: source.groups,
            associations: source.associations,
            diagnostics: []
        )
        let report = try MediaTrackSemanticVerifierV4.verify(
            plan: plan,
            output: output
        )
        let codes = Set(report.diagnostics.map(\.code))
        XCTAssertTrue(codes.isSuperset(of: [
            .trackKindMismatch,
            .enabledStateMismatch,
            .languageMismatch,
            .roleMismatch,
            .timingMismatch,
            .editListMismatch,
            .formatDescriptorMismatch,
            .metadataMismatch
        ]))
    }

    func testUnknownTrackIsDiagnosedPreservedAndMigrationIsIncompatible() throws {
        let source = try makeMultiTrackGraph(includeUnknown: true)
        let warning = try XCTUnwrap(source.diagnostics.first {
            $0.code == .unknownMediaType
        })
        XCTAssertEqual(warning.severity, .warning)
        let plan = try MediaTrackGraphPlannerV4.makePlan(source: source)
        let unknownID = try MediaTrackStableIDV4("unknown-private")
        XCTAssertEqual(
            plan.plan.tracks.first {
                $0.source.identity.stableID == unknownID
            }?.action,
            .passThrough
        )

        let blueprint = try AVFoundationTrackMigrationPlannerV4.makeBlueprint(
            source: source,
            plan: plan
        )
        let migration = try XCTUnwrap(blueprint.tracks.first {
            $0.trackID == unknownID
        })
        XCTAssertEqual(migration.outcome, .incompatible)
        XCTAssertTrue(migration.limitations.contains(.unknownMediaType))
        XCTAssertTrue(blueprint.hasIncompatibility)
    }

    func testBlockingSourceContradictionPreventsPlanning() throws {
        let source = try makeMultiTrackGraph(
            extraDiagnostics: [MediaTrackDiagnosticV4(
                severity: .error,
                code: .contradictoryGroupSelection,
                path: "groups.audio-alternates.default",
                observedValue: "audio-en,audio-es"
            )]
        )
        XCTAssertThrowsError(
            try MediaTrackGraphPlannerV4.makePlan(source: source)
        ) { error in
            guard case let .sourceHasBlockingDiagnostics(diagnostics) =
                error as? MediaTrackGraphPlannerV4Error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(diagnostics.count, 1)
        }
    }

    func testMigrationBlueprintNamesEveryTrackAndRequiredPath() throws {
        let source = try makeMultiTrackGraph()
        let mainID = try MediaTrackStableIDV4("video-main")
        let spanishID = try MediaTrackStableIDV4("audio-es")
        let captionID = try MediaTrackStableIDV4("caption-en")
        let directives = [
            MediaTrackDirectiveV4(
                trackID: mainID,
                action: .process,
                targetFormatDescriptors: [try makeFormat(seed: 140)],
                dropConsent: nil
            ),
            MediaTrackDirectiveV4(
                trackID: spanishID,
                action: .transcode,
                targetFormatDescriptors: [try makeFormat(seed: 141)],
                dropConsent: nil
            ),
            MediaTrackDirectiveV4(
                trackID: captionID,
                action: .dropWithConsent,
                targetFormatDescriptors: [],
                dropConsent: try consent(for: captionID.rawValue, seed: 142)
            )
        ]
        let plan = try MediaTrackGraphPlannerV4.makePlan(
            source: source,
            request: .init(trackDirectives: directives)
        )
        let blueprint = try AVFoundationTrackMigrationPlannerV4.makeBlueprint(
            source: source,
            plan: plan
        )

        XCTAssertEqual(blueprint.tracks.count, source.tracks.count)
        XCTAssertEqual(
            blueprint.tracks.map(\.trackID),
            source.tracks.map { $0.identity.stableID }
        )
        XCTAssertEqual(
            blueprint.tracks.first { $0.trackID == mainID }?.outcome,
            .requiresProcessor
        )
        XCTAssertEqual(
            blueprint.tracks.first { $0.trackID == spanishID }?.outcome,
            .requiresProcessor
        )
        XCTAssertEqual(
            blueprint.tracks.first { $0.trackID == captionID }?.outcome,
            .authorizedDrop
        )
        XCTAssertTrue(blueprint.tracks.filter {
            ![mainID, spanishID, captionID].contains($0.trackID)
        }.allSatisfy { $0.outcome == .directReaderWriter })
        XCTAssertEqual(blueprint.groups.count, source.groups.count)
        XCTAssertEqual(blueprint.associations.count, source.associations.count)
    }

    func testArbitraryEditListProducesExplicitCompositionRequirement() throws {
        let source = try makeMultiTrackGraph(multiEditTrackID: "chapter-track")
        let plan = try MediaTrackGraphPlannerV4.makePlan(source: source)
        let blueprint = try AVFoundationTrackMigrationPlannerV4.makeBlueprint(
            source: source,
            plan: plan
        )
        let chapterID = try MediaTrackStableIDV4("chapter-track")
        let migration = try XCTUnwrap(blueprint.tracks.first {
            $0.trackID == chapterID
        })
        XCTAssertEqual(migration.outcome, .requiresComposition)
        XCTAssertTrue(
            migration.limitations.contains(
                .arbitraryEditListRequiresComposition
            )
        )
    }

    func testDirectiveOrderDoesNotChangeCanonicalPlanIdentity() throws {
        let source = try makeMultiTrackGraph()
        let first = MediaTrackDirectiveV4(
            trackID: try MediaTrackStableIDV4("video-main"),
            action: .process,
            targetFormatDescriptors: [try makeFormat(seed: 150)],
            dropConsent: nil
        )
        let second = MediaTrackDirectiveV4(
            trackID: try MediaTrackStableIDV4("video-angle-b"),
            action: .process,
            targetFormatDescriptors: [try makeFormat(seed: 151)],
            dropConsent: nil
        )
        let forward = try MediaTrackGraphPlannerV4.makePlan(
            source: source,
            request: .init(trackDirectives: [first, second])
        )
        let reverse = try MediaTrackGraphPlannerV4.makePlan(
            source: source,
            request: .init(trackDirectives: [second, first])
        )
        XCTAssertEqual(forward, reverse)
        XCTAssertEqual(
            forward.planSHA256.rawValue,
            "e666a334a20604eeb4bcf813749205a636cfb6b6864c948451000145b5d20726"
        )
    }

    func testAVFoundationProbeEnumeratesEveryCompositionTrack() async throws {
        let composition = AVMutableComposition()
        let videoMain = try XCTUnwrap(composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: 1
        ))
        _ = try XCTUnwrap(composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: 2
        ))
        _ = try XCTUnwrap(composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: 3
        ))
        _ = try XCTUnwrap(composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: 4
        ))
        _ = try XCTUnwrap(composition.addMutableTrack(
            withMediaType: .subtitle,
            preferredTrackID: 5
        ))
        _ = try XCTUnwrap(composition.addMutableTrack(
            withMediaType: .closedCaption,
            preferredTrackID: 6
        ))
        let chapter = try XCTUnwrap(composition.addMutableTrack(
            withMediaType: .text,
            preferredTrackID: 7
        ))
        _ = try XCTUnwrap(composition.addMutableTrack(
            withMediaType: .timecode,
            preferredTrackID: 8
        ))
        _ = try XCTUnwrap(composition.addMutableTrack(
            withMediaType: .metadata,
            preferredTrackID: 9
        ))
        _ = try XCTUnwrap(composition.addMutableTrack(
            withMediaType: AVMediaType(rawValue: "auxv"),
            preferredTrackID: 10
        ))
        videoMain.addTrackAssociation(to: chapter, type: .chapterList)

        let graph = try await AVFoundationTrackGraphAdapterV4.probe(
            asset: composition
        )
        XCTAssertEqual(graph.tracks.count, 10)
        XCTAssertEqual(graph.tracks.filter { $0.kind == .video }.count, 2)
        XCTAssertEqual(graph.tracks.filter { $0.kind == .audio }.count, 2)
        XCTAssertEqual(graph.tracks.filter { $0.kind == .subtitle }.count, 1)
        XCTAssertEqual(graph.tracks.filter { $0.kind == .caption }.count, 1)
        XCTAssertEqual(graph.tracks.filter { $0.kind == .chapter }.count, 1)
        XCTAssertEqual(graph.tracks.filter { $0.kind == .timecode }.count, 1)
        XCTAssertEqual(
            graph.tracks.filter { $0.kind == .timedMetadata }.count,
            1
        )
        XCTAssertEqual(graph.tracks.filter { $0.kind == .auxiliary }.count, 1)
        XCTAssertEqual(
            graph.tracks.map { $0.identity.containerTrackID },
            Array(1 ... 10).map(Int32.init)
        )
        XCTAssertTrue(graph.associations.contains {
            $0.kind == .chapterList
        })
        XCTAssertEqual(
            graph.diagnostics.filter {
                $0.code == .missingFormatDescriptor
            }.count,
            10
        )
        XCTAssertNoThrow(try graph.validate())
    }

    func testAVFoundationProbeDoesNotRelabelMuxedTrackAsAuxiliary()
        async throws {
        let composition = AVMutableComposition()
        _ = try XCTUnwrap(composition.addMutableTrack(
            withMediaType: .muxed,
            preferredTrackID: 1
        ))

        let graph = try await AVFoundationTrackGraphAdapterV4.probe(
            asset: composition
        )
        XCTAssertEqual(graph.tracks.map(\.kind), [.unknown])
        XCTAssertTrue(graph.diagnostics.contains { diagnostic in
            diagnostic.code == .unknownMediaType
                && diagnostic.path == "tracks.av-track-1.kind"
        })
    }
}

private func makeMultiTrackGraph(
    includeUnknown: Bool = false,
    multiEditTrackID: String? = nil,
    extraDiagnostics: [MediaTrackDiagnosticV4] = []
) throws -> MediaTrackGraphV4 {
    let definitions: [(String, MediaTrackKindV4, Bool, String?, [String])] = [
        ("video-main", .video, true, nil, ["main"]),
        ("video-angle-b", .video, true, nil, ["alternate"]),
        ("audio-en", .audio, true, "en-US", ["main"]),
        ("audio-es", .audio, false, "es-ES", ["alternate"]),
        ("subtitle-en", .subtitle, true, "en-US", ["subtitle"]),
        ("caption-en", .caption, true, "en-US", ["caption"]),
        ("chapter-track", .chapter, true, nil, ["chapters"]),
        ("timecode-track", .timecode, true, nil, ["timecode"]),
        ("timed-metadata", .timedMetadata, true, nil, ["metadata"]),
        ("auxiliary-depth", .auxiliary, true, nil, ["auxiliary"])
    ]
    var tracks: [MediaTrackNodeV4] = []
    for (offset, definition) in definitions.enumerated() {
        tracks.append(try makeTrack(
            id: definition.0,
            ordinal: UInt32(offset),
            kind: definition.1,
            enabled: definition.2,
            languageTag: definition.3,
            roles: definition.4,
            formatSeed: UInt64(10 + offset),
            editCount: multiEditTrackID == definition.0 ? 2 : 1
        ))
    }
    var diagnostics = extraDiagnostics
    if includeUnknown {
        tracks.append(try makeTrack(
            id: "unknown-private",
            ordinal: UInt32(tracks.count),
            kind: .unknown,
            enabled: true,
            languageTag: nil,
            roles: ["private"],
            formatSeed: 30,
            editCount: 1
        ))
        diagnostics.append(MediaTrackDiagnosticV4(
            severity: .warning,
            code: .unknownMediaType,
            path: "tracks.unknown-private.kind",
            observedValue: "vendor_private"
        ))
    }

    let audioGroup = try MediaTrackGroupV4(
        identity: MediaTrackGroupIdentityV4(
            ordinal: 0,
            stableID: MediaTrackGroupStableIDV4("audio-alternates")
        ),
        kind: .alternate,
        memberTrackIDs: [
            MediaTrackStableIDV4("audio-en"),
            MediaTrackStableIDV4("audio-es")
        ],
        defaultTrackID: MediaTrackStableIDV4("audio-en"),
        allowsEmptySelection: false
    )
    let associations = [
        try MediaTrackAssociationV4(
            ordinal: 0,
            sourceTrackID: MediaTrackStableIDV4("video-main"),
            targetTrackID: MediaTrackStableIDV4("chapter-track"),
            kind: .chapterList,
            sourceAssociationTypeID: "chapter_list"
        ),
        try MediaTrackAssociationV4(
            ordinal: 1,
            sourceTrackID: MediaTrackStableIDV4("video-main"),
            targetTrackID: MediaTrackStableIDV4("timecode-track"),
            kind: .timecode,
            sourceAssociationTypeID: "timecode"
        ),
        try MediaTrackAssociationV4(
            ordinal: 2,
            sourceTrackID: MediaTrackStableIDV4("timed-metadata"),
            targetTrackID: MediaTrackStableIDV4("video-main"),
            kind: .metadataReferent,
            sourceAssociationTypeID: "metadata_referent"
        ),
        try MediaTrackAssociationV4(
            ordinal: 3,
            sourceTrackID: MediaTrackStableIDV4("audio-en"),
            targetTrackID: MediaTrackStableIDV4("subtitle-en"),
            kind: .selectionFollower,
            sourceAssociationTypeID: "selection_follower"
        )
    ]
    return try MediaTrackGraphV4(
        tracks: tracks,
        groups: [audioGroup],
        associations: associations,
        diagnostics: Array(Set(diagnostics)).sorted()
    )
}

private func makeTrack(
    id: String,
    ordinal: UInt32,
    kind: MediaTrackKindV4,
    enabled: Bool,
    languageTag: String?,
    roles: [String],
    formatSeed: UInt64,
    editCount: Int
) throws -> MediaTrackNodeV4 {
    var edits: [MediaTrackEditV4] = []
    for offset in 0 ..< editCount {
        let start = try ExactRationalV4(Int64(offset * 30))
        let range = try MediaExactTimeRangeV4(
            start: start,
            duration: ExactRationalV4(30)
        )
        edits.append(try MediaTrackEditV4(
            ordinal: UInt32(offset),
            source: range,
            target: range,
            isEmpty: false
        ))
    }
    return try MediaTrackNodeV4(
        identity: MediaTrackIdentityV4(
            ordinal: ordinal,
            stableID: MediaTrackStableIDV4(id),
            containerTrackID: Int32(ordinal + 1)
        ),
        enabled: enabled,
        kind: kind,
        sourceMediaTypeID: kind.rawValue,
        language: MediaTrackLanguageV4(
            languageCode: languageTag.map { String($0.prefix(2)) },
            extendedLanguageTag: languageTag
        ),
        roleIDs: roles.sorted(),
        timebase: ExactRationalV4(1, 600),
        timeRange: MediaExactTimeRangeV4(
            start: .zero,
            duration: ExactRationalV4(60)
        ),
        edits: edits,
        formatDescriptors: [try makeFormat(seed: Int(formatSeed))],
        metadataFingerprint: try testHash(formatSeed + 1_000)
    )
}

private func makeFormat(seed: Int) throws -> MediaTrackFormatDescriptorV4 {
    try MediaTrackFormatDescriptorV4(
        ordinal: 0,
        mediaTypeID: "media_\(seed)",
        mediaSubtypeID: "codec_\(seed)",
        canonicalFingerprint: try testHash(UInt64(seed)),
        completeness: .complete
    )
}

private func expectedOutput(
    for plan: MediaTrackGraphPlanV4
) throws -> MediaTrackGraphV4 {
    try MediaTrackGraphV4(
        tracks: plan.tracks.compactMap(\.expectedOutput),
        groups: plan.groups.compactMap(\.expectedOutput),
        associations: plan.associations.compactMap {
            $0.action == .passThrough ? $0.source : nil
        },
        diagnostics: plan.diagnostics
    )
}

private func consent(
    for subjectID: String,
    seed: UInt64
) throws -> MediaTrackDropConsentV4 {
    try MediaTrackDropConsentV4(
        subjectID: subjectID,
        reasonID: "user-approved-drop",
        approvalSHA256: try testHash(seed)
    )
}

private func testHash(_ value: UInt64) throws -> ASHSHA256V4 {
    let suffix = String(value, radix: 16)
    return try ASHSHA256V4(
        String(repeating: "0", count: 64 - suffix.count) + suffix
    )
}
