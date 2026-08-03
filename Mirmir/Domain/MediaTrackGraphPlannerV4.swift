import Foundation

enum MediaTrackGraphPlannerV4Error: Error, Equatable, Sendable {
    case unsupportedRequestSchema(String)
    case sourceHasBlockingDiagnostics([MediaTrackDiagnosticV4])
    case duplicateTrackDirective(MediaTrackStableIDV4)
    case unknownTrackDirective(MediaTrackStableIDV4)
    case duplicateGroupDirective(MediaTrackGroupStableIDV4)
    case unknownGroupDirective(MediaTrackGroupStableIDV4)
    case invalidTrackAction(trackID: MediaTrackStableIDV4, reason: String)
    case invalidGroupAction(groupID: MediaTrackGroupStableIDV4, reason: String)
    case missingDropConsent(subjectID: String)
    case dropConsentSubjectMismatch(expected: String, actual: String)
    case sourceGraphIdentityMismatch
    case invalidPlan(String)
    case planIdentityMismatch(expected: ASHSHA256V4, actual: ASHSHA256V4)
}

enum MediaTrackActionV4: String, Codable, Hashable, Sendable {
    case process
    case transcode
    case passThrough = "pass_through"
    case dropWithConsent = "drop_with_consent"
}

enum MediaTrackDecisionOriginV4: String, Codable, Hashable, Sendable {
    case explicit
    case defaultPreservation = "default_preservation"
}

struct MediaTrackDropConsentV4: Codable, Comparable, Equatable, Hashable,
    Sendable {
    let subjectID: String
    let reasonID: String
    let approvalSHA256: ASHSHA256V4

    init(
        subjectID: String,
        reasonID: String,
        approvalSHA256: ASHSHA256V4
    ) throws {
        guard MediaTrackGraphLexiconV4.isStableIdentifier(subjectID),
              MediaTrackGraphLexiconV4.isStableIdentifier(reasonID) else {
            throw MediaTrackGraphV4Error.invalidIdentifier(
                type: "drop_consent",
                value: subjectID + ":" + reasonID
            )
        }
        self.subjectID = subjectID
        self.reasonID = reasonID
        self.approvalSHA256 = approvalSHA256
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.subjectID != rhs.subjectID {
            return lhs.subjectID < rhs.subjectID
        }
        if lhs.reasonID != rhs.reasonID { return lhs.reasonID < rhs.reasonID }
        return lhs.approvalSHA256 < rhs.approvalSHA256
    }
}

struct MediaTrackDirectiveV4: Codable, Equatable, Hashable, Sendable {
    let trackID: MediaTrackStableIDV4
    let action: MediaTrackActionV4
    let targetFormatDescriptors: [MediaTrackFormatDescriptorV4]
    let dropConsent: MediaTrackDropConsentV4?
}

struct MediaTrackGroupDirectiveV4: Codable, Equatable, Hashable, Sendable {
    let groupID: MediaTrackGroupStableIDV4
    let action: MediaTrackActionV4
    let outputMemberTrackIDs: [MediaTrackStableIDV4]?
    let outputDefaultTrackID: MediaTrackStableIDV4?
    let dropConsent: MediaTrackDropConsentV4?
}

struct MediaTrackGraphPlanningRequestV4: Codable, Equatable, Hashable,
    Sendable {
    static let currentSchemaID = "ash.media-track-planning-request.v4.1"

    let schemaID: String
    let trackDirectives: [MediaTrackDirectiveV4]
    let groupDirectives: [MediaTrackGroupDirectiveV4]

    init(
        trackDirectives: [MediaTrackDirectiveV4] = [],
        groupDirectives: [MediaTrackGroupDirectiveV4] = []
    ) {
        schemaID = Self.currentSchemaID
        self.trackDirectives = trackDirectives
        self.groupDirectives = groupDirectives
    }
}

struct MediaTrackPlannedTrackV4: Codable, Equatable, Hashable, Sendable {
    let source: MediaTrackNodeV4
    let action: MediaTrackActionV4
    let origin: MediaTrackDecisionOriginV4
    let expectedOutput: MediaTrackNodeV4?
    let dropConsent: MediaTrackDropConsentV4?
}

struct MediaTrackPlannedGroupV4: Codable, Equatable, Hashable, Sendable {
    let source: MediaTrackGroupV4
    let action: MediaTrackActionV4
    let origin: MediaTrackDecisionOriginV4
    let expectedOutput: MediaTrackGroupV4?
    let dropConsent: MediaTrackDropConsentV4?
}

struct MediaTrackPlannedAssociationV4: Codable, Equatable, Hashable,
    Sendable {
    let source: MediaTrackAssociationV4
    let action: MediaTrackActionV4
    let dropConsents: [MediaTrackDropConsentV4]
}

struct MediaTrackGraphPlanV4: Codable, Equatable, Hashable, Sendable {
    static let currentSchemaID = "ash.media-track-graph-plan.v4.1"
    static let identityDomain = "ash-media-track-graph-plan-v4"

    let schemaID: String
    let sourceGraphSHA256: ASHSHA256V4
    let tracks: [MediaTrackPlannedTrackV4]
    let groups: [MediaTrackPlannedGroupV4]
    let associations: [MediaTrackPlannedAssociationV4]
    let diagnostics: [MediaTrackDiagnosticV4]

    init(
        sourceGraphSHA256: ASHSHA256V4,
        tracks: [MediaTrackPlannedTrackV4],
        groups: [MediaTrackPlannedGroupV4],
        associations: [MediaTrackPlannedAssociationV4],
        diagnostics: [MediaTrackDiagnosticV4]
    ) throws {
        schemaID = Self.currentSchemaID
        self.sourceGraphSHA256 = sourceGraphSHA256
        self.tracks = tracks
        self.groups = groups
        self.associations = associations
        self.diagnostics = diagnostics
        try validate()
    }

    func validate() throws {
        guard schemaID == Self.currentSchemaID else {
            throw MediaTrackGraphPlannerV4Error.invalidPlan(
                "unsupported schema \(schemaID)"
            )
        }
        guard tracks.map(\.source.identity)
            == tracks.map(\.source.identity).sorted(),
              Set(tracks.map { $0.source.identity.stableID }).count
                == tracks.count else {
            throw MediaTrackGraphPlannerV4Error.invalidPlan(
                "planned tracks must be unique and source ordered"
            )
        }
        for track in tracks {
            try Self.validate(track)
        }
        guard groups.map(\.source.identity)
            == groups.map(\.source.identity).sorted(),
              Set(groups.map { $0.source.identity.stableID }).count
                == groups.count else {
            throw MediaTrackGraphPlannerV4Error.invalidPlan(
                "planned groups must be unique and source ordered"
            )
        }
        for group in groups {
            try Self.validate(group)
        }
        guard associations.map({ $0.source.ordinal })
            == associations.map({ $0.source.ordinal }).sorted(),
              Set(associations.map({ $0.source.ordinal })).count
                == associations.count else {
            throw MediaTrackGraphPlannerV4Error.invalidPlan(
                "planned associations must be unique and source ordered"
            )
        }
        for association in associations {
            switch association.action {
            case .passThrough:
                guard association.dropConsents.isEmpty else {
                    throw MediaTrackGraphPlannerV4Error.invalidPlan(
                        "preserved association contains drop consent"
                    )
                }
            case .dropWithConsent:
                guard !association.dropConsents.isEmpty,
                      association.dropConsents
                        == Array(Set(association.dropConsents)).sorted() else {
                    throw MediaTrackGraphPlannerV4Error.invalidPlan(
                        "dropped association lacks canonical consent"
                    )
                }
            case .process, .transcode:
                throw MediaTrackGraphPlannerV4Error.invalidPlan(
                    "associations cannot be processed or transcoded"
                )
            }
        }
        guard diagnostics == Array(Set(diagnostics)).sorted() else {
            throw MediaTrackGraphPlannerV4Error.invalidPlan(
                "plan diagnostics are not canonical"
            )
        }
    }

    var canonicalSHA256: ASHSHA256V4 {
        get throws {
            try validate()
            return try ASHCanonicalJSONV4.hash(
                self,
                domain: Self.identityDomain
            )
        }
    }

    private static func validate(
        _ track: MediaTrackPlannedTrackV4
    ) throws {
        let trackID = track.source.identity.stableID.rawValue
        switch track.action {
        case .passThrough:
            guard track.expectedOutput == track.source,
                  track.dropConsent == nil else {
                throw MediaTrackGraphPlannerV4Error.invalidPlan(
                    "pass-through track \(trackID) must be unchanged"
                )
            }
        case .process:
            guard let output = track.expectedOutput,
                  track.dropConsent == nil,
                  track.source.semanticsExceptFormatsEqual(to: output),
                  !output.formatDescriptors.isEmpty else {
                throw MediaTrackGraphPlannerV4Error.invalidPlan(
                    "processed track \(trackID) changed protected semantics"
                )
            }
        case .transcode:
            guard let output = track.expectedOutput,
                  track.dropConsent == nil,
                  track.source.transcodePresentationSemanticsEqual(to: output),
                  !output.formatDescriptors.isEmpty else {
                throw MediaTrackGraphPlannerV4Error.invalidPlan(
                    "transcoded track \(trackID) changed protected presentation semantics"
                )
            }
        case .dropWithConsent:
            guard track.expectedOutput == nil,
                  track.dropConsent?.subjectID == trackID else {
                throw MediaTrackGraphPlannerV4Error.invalidPlan(
                    "dropped track \(trackID) lacks matching consent"
                )
            }
        }
    }

    private static func validate(
        _ group: MediaTrackPlannedGroupV4
    ) throws {
        let groupID = group.source.identity.stableID.rawValue
        switch group.action {
        case .passThrough:
            guard group.expectedOutput == group.source,
                  group.dropConsent == nil else {
                throw MediaTrackGraphPlannerV4Error.invalidPlan(
                    "pass-through group \(groupID) must be unchanged"
                )
            }
        case .transcode:
            guard let output = group.expectedOutput,
                  group.source.semanticsExceptMembershipEqual(to: output) else {
                throw MediaTrackGraphPlannerV4Error.invalidPlan(
                    "reconstructed group \(groupID) changed protected semantics"
                )
            }
        case .dropWithConsent:
            guard group.expectedOutput == nil,
                  group.dropConsent?.subjectID == groupID else {
                throw MediaTrackGraphPlannerV4Error.invalidPlan(
                    "dropped group \(groupID) lacks matching consent"
                )
            }
        case .process:
            throw MediaTrackGraphPlannerV4Error.invalidPlan(
                "groups cannot use process"
            )
        }
    }
}

struct MediaTrackGraphIdentifiedPlanV4: Codable, Equatable, Hashable,
    Sendable {
    let plan: MediaTrackGraphPlanV4
    let planSHA256: ASHSHA256V4

    init(plan: MediaTrackGraphPlanV4) throws {
        self.plan = plan
        planSHA256 = try plan.canonicalSHA256
    }

    func verify() throws {
        try plan.validate()
        let actual = try plan.canonicalSHA256
        guard actual == planSHA256 else {
            throw MediaTrackGraphPlannerV4Error.planIdentityMismatch(
                expected: planSHA256,
                actual: actual
            )
        }
    }

    func applyingTranscodePrimingDurations(
        _ primingByTrackID: [MediaTrackStableIDV4: ExactRationalV4]
    ) throws -> MediaTrackGraphIdentifiedPlanV4 {
        guard !primingByTrackID.isEmpty else { return self }
        var consumed = Set<MediaTrackStableIDV4>()
        let tracks = try plan.tracks.map { planned -> MediaTrackPlannedTrackV4 in
            let id = planned.source.identity.stableID
            guard let priming = primingByTrackID[id] else { return planned }
            guard planned.action == .transcode,
                  let expected = planned.expectedOutput,
                  priming >= .zero else {
                throw MediaTrackGraphPlannerV4Error.invalidPlan(
                    "priming adjustment requires a transcoded track and nonnegative duration \(id.rawValue)"
                )
            }
            let edits = try expected.edits.map { edit in
                guard !edit.isEmpty else { return edit }
                return try MediaTrackEditV4(
                    ordinal: edit.ordinal,
                    source: MediaExactTimeRangeV4(
                        start: try edit.target.start.adding(priming),
                        duration: edit.target.duration
                    ),
                    target: edit.target,
                    isEmpty: false
                )
            }
            consumed.insert(id)
            let output = try MediaTrackNodeV4(
                identity: expected.identity,
                enabled: expected.enabled,
                kind: expected.kind,
                sourceMediaTypeID: expected.sourceMediaTypeID,
                language: expected.language,
                roleIDs: expected.roleIDs,
                timebase: expected.timebase,
                timeRange: expected.timeRange,
                edits: edits,
                formatDescriptors: expected.formatDescriptors,
                metadataFingerprint: expected.metadataFingerprint
            )
            return MediaTrackPlannedTrackV4(
                source: planned.source,
                action: planned.action,
                origin: planned.origin,
                expectedOutput: output,
                dropConsent: planned.dropConsent
            )
        }
        guard consumed == Set(primingByTrackID.keys) else {
            throw MediaTrackGraphPlannerV4Error.invalidPlan(
                "priming adjustment references an unknown track"
            )
        }
        return try MediaTrackGraphIdentifiedPlanV4(plan: .init(
            sourceGraphSHA256: plan.sourceGraphSHA256,
            tracks: tracks,
            groups: plan.groups,
            associations: plan.associations,
            diagnostics: plan.diagnostics
        ))
    }
}

enum MediaTrackGraphPlannerV4 {
    static func makePlan(
        source: MediaTrackGraphV4,
        request: MediaTrackGraphPlanningRequestV4 = .init()
    ) throws -> MediaTrackGraphIdentifiedPlanV4 {
        try source.validate()
        let blocking = source.diagnostics.filter { $0.severity.isBlocking }
        guard blocking.isEmpty else {
            throw MediaTrackGraphPlannerV4Error
                .sourceHasBlockingDiagnostics(blocking)
        }
        guard request.schemaID
            == MediaTrackGraphPlanningRequestV4.currentSchemaID else {
            throw MediaTrackGraphPlannerV4Error.unsupportedRequestSchema(
                request.schemaID
            )
        }

        let sourceTrackIDs = Set(source.tracks.map { $0.identity.stableID })
        var trackDirectives: [MediaTrackStableIDV4: MediaTrackDirectiveV4] = [:]
        for directive in request.trackDirectives {
            guard sourceTrackIDs.contains(directive.trackID) else {
                throw MediaTrackGraphPlannerV4Error.unknownTrackDirective(
                    directive.trackID
                )
            }
            guard trackDirectives.updateValue(
                directive,
                forKey: directive.trackID
            ) == nil else {
                throw MediaTrackGraphPlannerV4Error.duplicateTrackDirective(
                    directive.trackID
                )
            }
        }

        let sourceGroupIDs = Set(source.groups.map { $0.identity.stableID })
        var groupDirectives: [
            MediaTrackGroupStableIDV4: MediaTrackGroupDirectiveV4
        ] = [:]
        for directive in request.groupDirectives {
            guard sourceGroupIDs.contains(directive.groupID) else {
                throw MediaTrackGraphPlannerV4Error.unknownGroupDirective(
                    directive.groupID
                )
            }
            guard groupDirectives.updateValue(
                directive,
                forKey: directive.groupID
            ) == nil else {
                throw MediaTrackGraphPlannerV4Error.duplicateGroupDirective(
                    directive.groupID
                )
            }
        }

        var plannedTracks: [MediaTrackPlannedTrackV4] = []
        plannedTracks.reserveCapacity(source.tracks.count)
        for track in source.tracks {
            let directive = trackDirectives[track.identity.stableID]
            plannedTracks.append(
                try plan(track: track, directive: directive)
            )
        }
        let planByTrackID = Dictionary(
            uniqueKeysWithValues: plannedTracks.map {
                ($0.source.identity.stableID, $0)
            }
        )

        var plannedGroups: [MediaTrackPlannedGroupV4] = []
        plannedGroups.reserveCapacity(source.groups.count)
        for group in source.groups {
            plannedGroups.append(
                try plan(
                    group: group,
                    directive: groupDirectives[group.identity.stableID],
                    tracks: planByTrackID
                )
            )
        }

        let plannedAssociations = try source.associations.map { association in
            let endpoints = [
                planByTrackID[association.sourceTrackID],
                planByTrackID[association.targetTrackID]
            ].compactMap { $0 }
            guard endpoints.count == 2 else {
                throw MediaTrackGraphPlannerV4Error.invalidPlan(
                    "association endpoint was not planned"
                )
            }
            let consents = endpoints.compactMap { endpoint in
                endpoint.action == .dropWithConsent
                    ? endpoint.dropConsent
                    : nil
            }
            return MediaTrackPlannedAssociationV4(
                source: association,
                action: consents.isEmpty ? .passThrough : .dropWithConsent,
                dropConsents: Array(Set(consents)).sorted()
            )
        }

        let plan = try MediaTrackGraphPlanV4(
            sourceGraphSHA256: source.canonicalSHA256,
            tracks: plannedTracks,
            groups: plannedGroups,
            associations: plannedAssociations,
            diagnostics: source.diagnostics
        )
        return try MediaTrackGraphIdentifiedPlanV4(plan: plan)
    }

    private static func plan(
        track: MediaTrackNodeV4,
        directive: MediaTrackDirectiveV4?
    ) throws -> MediaTrackPlannedTrackV4 {
        let origin: MediaTrackDecisionOriginV4 = directive == nil
            ? .defaultPreservation
            : .explicit
        let directive = directive ?? MediaTrackDirectiveV4(
            trackID: track.identity.stableID,
            action: .passThrough,
            targetFormatDescriptors: [],
            dropConsent: nil
        )
        let trackID = track.identity.stableID
        guard directive.targetFormatDescriptors.map(\.ordinal)
            == directive.targetFormatDescriptors.map(\.ordinal).sorted(),
              Set(directive.targetFormatDescriptors.map(\.ordinal)).count
                == directive.targetFormatDescriptors.count else {
            throw MediaTrackGraphPlannerV4Error.invalidTrackAction(
                trackID: trackID,
                reason: "target formats must be unique and ordered"
            )
        }

        switch directive.action {
        case .passThrough:
            guard directive.targetFormatDescriptors.isEmpty,
                  directive.dropConsent == nil else {
                throw invalidTrack(trackID, "pass-through accepts no target/consent")
            }
            return MediaTrackPlannedTrackV4(
                source: track,
                action: .passThrough,
                origin: origin,
                expectedOutput: track,
                dropConsent: nil
            )
        case .process:
            guard track.kind == .video,
                  track.enabled,
                  !directive.targetFormatDescriptors.isEmpty,
                  directive.targetFormatDescriptors.allSatisfy({
                      $0.completeness == .complete
                  }),
                  directive.dropConsent == nil else {
                throw invalidTrack(
                    trackID,
                    "process requires an enabled video and complete target formats"
                )
            }
            return MediaTrackPlannedTrackV4(
                source: track,
                action: .process,
                origin: origin,
                expectedOutput: try track.replacingFormats(
                    directive.targetFormatDescriptors
                ),
                dropConsent: nil
            )
        case .transcode:
            guard !directive.targetFormatDescriptors.isEmpty,
                  directive.dropConsent == nil else {
                throw invalidTrack(
                    trackID,
                    "transcode requires target formats and no consent"
                )
            }
            return MediaTrackPlannedTrackV4(
                source: track,
                action: .transcode,
                origin: origin,
                expectedOutput: try track.replacingFormats(
                    directive.targetFormatDescriptors
                ),
                dropConsent: nil
            )
        case .dropWithConsent:
            guard directive.targetFormatDescriptors.isEmpty,
                  let consent = directive.dropConsent else {
                throw MediaTrackGraphPlannerV4Error.missingDropConsent(
                    subjectID: trackID.rawValue
                )
            }
            guard consent.subjectID == trackID.rawValue else {
                throw MediaTrackGraphPlannerV4Error
                    .dropConsentSubjectMismatch(
                        expected: trackID.rawValue,
                        actual: consent.subjectID
                    )
            }
            return MediaTrackPlannedTrackV4(
                source: track,
                action: .dropWithConsent,
                origin: origin,
                expectedOutput: nil,
                dropConsent: consent
            )
        }
    }

    private static func plan(
        group: MediaTrackGroupV4,
        directive: MediaTrackGroupDirectiveV4?,
        tracks: [MediaTrackStableIDV4: MediaTrackPlannedTrackV4]
    ) throws -> MediaTrackPlannedGroupV4 {
        let origin: MediaTrackDecisionOriginV4 = directive == nil
            ? .defaultPreservation
            : .explicit
        let directive = directive ?? MediaTrackGroupDirectiveV4(
            groupID: group.identity.stableID,
            action: .passThrough,
            outputMemberTrackIDs: nil,
            outputDefaultTrackID: nil,
            dropConsent: nil
        )
        let groupID = group.identity.stableID
        let survivingMembers = group.memberTrackIDs.filter {
            tracks[$0]?.action != .dropWithConsent
        }

        switch directive.action {
        case .passThrough:
            guard directive.outputMemberTrackIDs == nil,
                  directive.outputDefaultTrackID == nil,
                  directive.dropConsent == nil,
                  survivingMembers == group.memberTrackIDs else {
                throw invalidGroup(
                    groupID,
                    "pass-through cannot hide a member drop or change membership"
                )
            }
            return MediaTrackPlannedGroupV4(
                source: group,
                action: .passThrough,
                origin: origin,
                expectedOutput: group,
                dropConsent: nil
            )
        case .transcode:
            let outputMembers = directive.outputMemberTrackIDs
                ?? group.memberTrackIDs
            guard outputMembers == survivingMembers,
                  !outputMembers.isEmpty,
                  Set(outputMembers).count == outputMembers.count,
                  outputMembers.allSatisfy(group.memberTrackIDs.contains) else {
                throw invalidGroup(
                    groupID,
                    "reconstructed membership must exactly name surviving members"
                )
            }
            let membershipChanged = outputMembers != group.memberTrackIDs
            if membershipChanged {
                guard let consent = directive.dropConsent else {
                    throw MediaTrackGraphPlannerV4Error.missingDropConsent(
                        subjectID: groupID.rawValue
                    )
                }
                try validate(consent: consent, subjectID: groupID.rawValue)
            } else if directive.dropConsent != nil {
                throw invalidGroup(
                    groupID,
                    "unchanged reconstruction cannot carry drop consent"
                )
            }
            let defaultTrackID = directive.outputDefaultTrackID
                ?? group.defaultTrackID
            guard defaultTrackID.map(outputMembers.contains) ?? true else {
                throw invalidGroup(
                    groupID,
                    "output default must be a surviving member"
                )
            }
            return MediaTrackPlannedGroupV4(
                source: group,
                action: .transcode,
                origin: origin,
                expectedOutput: try group.replacingMembers(
                    outputMembers,
                    defaultTrackID: defaultTrackID
                ),
                dropConsent: directive.dropConsent
            )
        case .dropWithConsent:
            guard survivingMembers.isEmpty,
                  directive.outputMemberTrackIDs == nil,
                  directive.outputDefaultTrackID == nil,
                  let consent = directive.dropConsent else {
                throw invalidGroup(
                    groupID,
                    "dropping a group requires all members dropped and group consent"
                )
            }
            try validate(consent: consent, subjectID: groupID.rawValue)
            return MediaTrackPlannedGroupV4(
                source: group,
                action: .dropWithConsent,
                origin: origin,
                expectedOutput: nil,
                dropConsent: consent
            )
        case .process:
            throw invalidGroup(groupID, "track groups cannot be processed")
        }
    }

    private static func validate(
        consent: MediaTrackDropConsentV4,
        subjectID: String
    ) throws {
        guard consent.subjectID == subjectID else {
            throw MediaTrackGraphPlannerV4Error.dropConsentSubjectMismatch(
                expected: subjectID,
                actual: consent.subjectID
            )
        }
    }

    private static func invalidTrack(
        _ id: MediaTrackStableIDV4,
        _ reason: String
    ) -> MediaTrackGraphPlannerV4Error {
        .invalidTrackAction(trackID: id, reason: reason)
    }

    private static func invalidGroup(
        _ id: MediaTrackGroupStableIDV4,
        _ reason: String
    ) -> MediaTrackGraphPlannerV4Error {
        .invalidGroupAction(groupID: id, reason: reason)
    }
}

struct MediaTrackSemanticVerificationReportV4: Codable, Equatable, Hashable,
    Sendable {
    static let currentSchemaID = "ash.media-track-semantic-report.v4.1"
    static let identityDomain = "ash-media-track-semantic-report-v4"

    let schemaID: String
    let planSHA256: ASHSHA256V4
    let outputGraphSHA256: ASHSHA256V4
    let diagnostics: [MediaTrackDiagnosticV4]

    init(
        planSHA256: ASHSHA256V4,
        outputGraphSHA256: ASHSHA256V4,
        diagnostics: [MediaTrackDiagnosticV4]
    ) {
        schemaID = Self.currentSchemaID
        self.planSHA256 = planSHA256
        self.outputGraphSHA256 = outputGraphSHA256
        self.diagnostics = Array(Set(diagnostics)).sorted()
    }

    var isConformant: Bool {
        !diagnostics.contains { $0.severity.isBlocking }
    }

    var canonicalSHA256: ASHSHA256V4 {
        get throws {
            try ASHCanonicalJSONV4.hash(self, domain: Self.identityDomain)
        }
    }
}

enum MediaTrackSemanticVerifierV4 {
    static func verify(
        plan identifiedPlan: MediaTrackGraphIdentifiedPlanV4,
        output: MediaTrackGraphV4
    ) throws -> MediaTrackSemanticVerificationReportV4 {
        try identifiedPlan.verify()
        try output.validate()
        let plan = identifiedPlan.plan
        var diagnostics = plan.diagnostics + output.diagnostics

        let expectedTracks = plan.tracks.compactMap(\.expectedOutput)
        let expectedIDs = expectedTracks.map { $0.identity.stableID }
        let expectedIDSet = Set(expectedIDs)
        let actualIDs = output.tracks.map { $0.identity.stableID }
        let actualIDSet = Set(actualIDs)
        for id in expectedIDs where !actualIDSet.contains(id) {
            diagnostics.append(error(
                .missingOutputTrack,
                path: "tracks.\(id.rawValue)",
                observed: "absent"
            ))
        }
        for id in actualIDs where !expectedIDSet.contains(id) {
            diagnostics.append(error(
                .unexpectedOutputTrack,
                path: "tracks.\(id.rawValue)",
                observed: "present"
            ))
        }
        let actualExpectedOrder = actualIDs.filter(expectedIDSet.contains)
        if actualExpectedOrder != expectedIDs {
            diagnostics.append(error(
                .outputTrackOrderMismatch,
                path: "tracks",
                observed: actualExpectedOrder.map(\.rawValue).joined(separator: ",")
            ))
        }

        let outputByID = Dictionary(
            uniqueKeysWithValues: output.tracks.map {
                ($0.identity.stableID, $0)
            }
        )
        for expected in expectedTracks {
            guard let actual = outputByID[expected.identity.stableID] else {
                continue
            }
            compare(expected: expected, actual: actual, into: &diagnostics)
        }

        let expectedGroups = plan.groups.compactMap(\.expectedOutput)
        let expectedGroupIDs = Set(expectedGroups.map { $0.identity.stableID })
        let outputGroups = Dictionary(
            uniqueKeysWithValues: output.groups.map {
                ($0.identity.stableID, $0)
            }
        )
        for expected in expectedGroups {
            let id = expected.identity.stableID
            guard let actual = outputGroups[id] else {
                diagnostics.append(error(
                    .missingOutputGroup,
                    path: "groups.\(id.rawValue)",
                    observed: "absent"
                ))
                continue
            }
            if actual != expected {
                diagnostics.append(error(
                    .groupSemanticMismatch,
                    path: "groups.\(id.rawValue)",
                    observed: "group_contract_changed"
                ))
            }
        }
        for group in output.groups
        where !expectedGroupIDs.contains(group.identity.stableID) {
            diagnostics.append(error(
                .unexpectedOutputGroup,
                path: "groups.\(group.identity.stableID.rawValue)",
                observed: "present"
            ))
        }

        let expectedAssociations = plan.associations.compactMap {
            $0.action == .passThrough ? $0.source : nil
        }
        if expectedAssociations != output.associations {
            diagnostics.append(error(
                .associationMismatch,
                path: "associations",
                observed: "association_graph_changed"
            ))
        }

        return MediaTrackSemanticVerificationReportV4(
            planSHA256: identifiedPlan.planSHA256,
            outputGraphSHA256: try output.canonicalSHA256,
            diagnostics: diagnostics
        )
    }

    private static func compare(
        expected: MediaTrackNodeV4,
        actual: MediaTrackNodeV4,
        into diagnostics: inout [MediaTrackDiagnosticV4]
    ) {
        let path = "tracks.\(expected.identity.stableID.rawValue)"
        if expected.identity != actual.identity {
            diagnostics.append(error(
                .trackIdentityMismatch,
                path: path + ".identity",
                observed: "ordinal_or_container_id_changed"
            ))
        }
        if expected.kind != actual.kind
            || expected.sourceMediaTypeID != actual.sourceMediaTypeID {
            diagnostics.append(error(
                .trackKindMismatch,
                path: path + ".kind",
                observed: actual.kind.rawValue
            ))
        }
        if expected.enabled != actual.enabled {
            diagnostics.append(error(
                .enabledStateMismatch,
                path: path + ".enabled",
                observed: String(actual.enabled)
            ))
        }
        if expected.language != actual.language {
            diagnostics.append(error(
                .languageMismatch,
                path: path + ".language",
                observed: "language_changed"
            ))
        }
        if expected.roleIDs != actual.roleIDs {
            diagnostics.append(error(
                .roleMismatch,
                path: path + ".roles",
                observed: actual.roleIDs.joined(separator: ",")
            ))
        }
        if expected.timebase != actual.timebase
            || expected.timeRange != actual.timeRange {
            diagnostics.append(error(
                .timingMismatch,
                path: path + ".timing",
                observed: "timebase_or_range_changed"
            ))
        }
        if expected.edits != actual.edits {
            diagnostics.append(error(
                .editListMismatch,
                path: path + ".edits",
                observed: "edit_mapping_changed"
            ))
        }
        if expected.formatDescriptors != actual.formatDescriptors {
            diagnostics.append(error(
                .formatDescriptorMismatch,
                path: path + ".formats",
                observed: "format_fingerprint_changed"
            ))
        }
        if expected.metadataFingerprint != actual.metadataFingerprint {
            diagnostics.append(error(
                .metadataMismatch,
                path: path + ".metadata",
                observed: "metadata_fingerprint_changed"
            ))
        }
    }

    private static func error(
        _ code: MediaTrackDiagnosticCodeV4,
        path: String,
        observed: String
    ) -> MediaTrackDiagnosticV4 {
        MediaTrackDiagnosticV4(
            severity: .error,
            code: code,
            path: path,
            observedValue: observed
        )
    }
}

private extension MediaTrackNodeV4 {
    func semanticsExceptFormatsEqual(to other: MediaTrackNodeV4) -> Bool {
        identity == other.identity
            && enabled == other.enabled
            && kind == other.kind
            && sourceMediaTypeID == other.sourceMediaTypeID
            && language == other.language
            && roleIDs == other.roleIDs
            && timebase == other.timebase
            && timeRange == other.timeRange
            && edits == other.edits
            && metadataFingerprint == other.metadataFingerprint
    }

    func transcodePresentationSemanticsEqual(
        to other: MediaTrackNodeV4
    ) -> Bool {
        guard identity == other.identity
            && enabled == other.enabled
            && kind == other.kind
            && sourceMediaTypeID == other.sourceMediaTypeID
            && language == other.language
            && roleIDs == other.roleIDs
            && timebase == other.timebase
            && timeRange == other.timeRange
            && edits.count == other.edits.count
            && metadataFingerprint == other.metadataFingerprint else {
            return false
        }
        if edits == other.edits { return true }

        var observedPriming: ExactRationalV4?
        for (source, output) in zip(edits, other.edits) {
            guard source.ordinal == output.ordinal,
                  source.target == output.target,
                  source.isEmpty == output.isEmpty else {
                return false
            }
            if source.isEmpty {
                guard output.source == nil else { return false }
                continue
            }
            guard let outputSource = output.source,
                  outputSource.duration == output.target.duration,
                  let priming = try? outputSource.start.subtracting(
                      output.target.start
                  ),
                  priming >= .zero else {
                return false
            }
            if let observedPriming {
                guard observedPriming == priming else { return false }
            } else {
                observedPriming = priming
            }
        }
        return observedPriming != nil
    }
}

private extension MediaTrackGroupV4 {
    func semanticsExceptMembershipEqual(to other: MediaTrackGroupV4) -> Bool {
        identity == other.identity
            && kind == other.kind
            && allowsEmptySelection == other.allowsEmptySelection
    }
}
