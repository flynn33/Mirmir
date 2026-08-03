import Foundation

enum MediaTrackGraphV4Error: Error, Equatable, Sendable {
    case unsupportedSchema(String)
    case invalidIdentifier(type: String, value: String)
    case invalidOrdering(String)
    case duplicateTrackID(String)
    case duplicateTrackOrdinal(UInt32)
    case invalidTrack(id: String, reason: String)
    case duplicateGroupID(String)
    case duplicateGroupOrdinal(UInt32)
    case invalidGroup(id: String, reason: String)
    case invalidAssociation(ordinal: UInt32, reason: String)
    case invalidDiagnostics
}

struct MediaTrackStableIDV4: Codable, Comparable, CustomStringConvertible,
    Hashable, Sendable {
    let rawValue: String

    init(_ rawValue: String) throws {
        guard MediaTrackGraphLexiconV4.isStableIdentifier(rawValue) else {
            throw MediaTrackGraphV4Error.invalidIdentifier(
                type: "track",
                value: rawValue
            )
        }
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        do {
            try self.init(container.decode(String.self))
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid stable media-track identifier."
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var description: String { rawValue }
}

struct MediaTrackGroupStableIDV4: Codable, Comparable,
    CustomStringConvertible, Hashable, Sendable {
    let rawValue: String

    init(_ rawValue: String) throws {
        guard MediaTrackGraphLexiconV4.isStableIdentifier(rawValue) else {
            throw MediaTrackGraphV4Error.invalidIdentifier(
                type: "track_group",
                value: rawValue
            )
        }
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        do {
            try self.init(container.decode(String.self))
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid stable media-track-group identifier."
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var description: String { rawValue }
}

enum MediaTrackKindV4: String, CaseIterable, Codable, Hashable, Sendable {
    case video
    case audio
    case subtitle
    case caption
    case chapter
    case timecode
    case timedMetadata = "timed_metadata"
    case auxiliary
    case unknown
}

enum MediaTrackFormatCompletenessV4: String, Codable, Hashable, Sendable {
    case complete
    case partial
    case unknown
}

enum MediaTrackGroupKindV4: String, Codable, Hashable, Sendable {
    case alternate
    case mutuallyExclusive = "mutually_exclusive"
    case unknown
}

enum MediaTrackAssociationKindV4: String, Codable, Hashable, Sendable {
    case audioFallback = "audio_fallback"
    case chapterList = "chapter_list"
    case forcedSubtitlesOnly = "forced_subtitles_only"
    case selectionFollower = "selection_follower"
    case timecode
    case metadataReferent = "metadata_referent"
    case renderMetadataSource = "render_metadata_source"
    case unknown
}

enum MediaTrackDiagnosticSeverityV4: String, Codable, Hashable, Sendable {
    case information
    case warning
    case error
    case incompatible

    var isBlocking: Bool {
        self == .error || self == .incompatible
    }
}

enum MediaTrackDiagnosticCodeV4: String, Codable, Hashable, Sendable {
    case unknownMediaType = "unknown_media_type"
    case missingFormatDescriptor = "missing_format_descriptor"
    case partialFormatDescriptor = "partial_format_descriptor"
    case unknownFormatProperty = "unknown_format_property"
    case contradictoryGroupSelection = "contradictory_group_selection"
    case danglingGroupMember = "dangling_group_member"
    case danglingAssociation = "dangling_association"
    case actionContradiction = "action_contradiction"
    case unsupportedMigration = "unsupported_migration"
    case missingOutputTrack = "missing_output_track"
    case unexpectedOutputTrack = "unexpected_output_track"
    case outputTrackOrderMismatch = "output_track_order_mismatch"
    case trackIdentityMismatch = "track_identity_mismatch"
    case trackKindMismatch = "track_kind_mismatch"
    case enabledStateMismatch = "enabled_state_mismatch"
    case languageMismatch = "language_mismatch"
    case roleMismatch = "role_mismatch"
    case timingMismatch = "timing_mismatch"
    case editListMismatch = "edit_list_mismatch"
    case formatDescriptorMismatch = "format_descriptor_mismatch"
    case metadataMismatch = "metadata_mismatch"
    case missingOutputGroup = "missing_output_group"
    case unexpectedOutputGroup = "unexpected_output_group"
    case groupSemanticMismatch = "group_semantic_mismatch"
    case associationMismatch = "association_mismatch"
}

struct MediaTrackDiagnosticV4: Codable, Comparable, Equatable, Hashable,
    Sendable {
    let severity: MediaTrackDiagnosticSeverityV4
    let code: MediaTrackDiagnosticCodeV4
    let path: String
    let observedValue: String

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.path != rhs.path { return lhs.path < rhs.path }
        if lhs.code.rawValue != rhs.code.rawValue {
            return lhs.code.rawValue < rhs.code.rawValue
        }
        if lhs.severity.rawValue != rhs.severity.rawValue {
            return lhs.severity.rawValue < rhs.severity.rawValue
        }
        return lhs.observedValue < rhs.observedValue
    }
}

struct MediaTrackLanguageV4: Codable, Equatable, Hashable, Sendable {
    let languageCode: String?
    let extendedLanguageTag: String?

    init(languageCode: String?, extendedLanguageTag: String?) throws {
        guard Self.isValid(languageCode), Self.isValid(extendedLanguageTag) else {
            throw MediaTrackGraphV4Error.invalidTrack(
                id: "language",
                reason: "language values must be nonempty, bounded strings"
            )
        }
        self.languageCode = languageCode
        self.extendedLanguageTag = extendedLanguageTag
    }

    private static func isValid(_ value: String?) -> Bool {
        guard let value else { return true }
        return !value.isEmpty
            && value.utf8.count <= 128
            && !value.unicodeScalars.contains { $0.value == 0 }
    }
}

struct MediaExactTimeRangeV4: Codable, Equatable, Hashable, Sendable {
    let start: ExactRationalV4
    let duration: ExactRationalV4

    init(start: ExactRationalV4, duration: ExactRationalV4) throws {
        guard duration >= .zero else {
            throw MediaTrackGraphV4Error.invalidTrack(
                id: "time_range",
                reason: "duration must not be negative"
            )
        }
        self.start = start
        self.duration = duration
    }
}

struct MediaTrackEditV4: Codable, Equatable, Hashable, Sendable {
    let ordinal: UInt32
    let source: MediaExactTimeRangeV4?
    let target: MediaExactTimeRangeV4
    let isEmpty: Bool

    init(
        ordinal: UInt32,
        source: MediaExactTimeRangeV4?,
        target: MediaExactTimeRangeV4,
        isEmpty: Bool
    ) throws {
        guard (isEmpty && source == nil) || (!isEmpty && source != nil) else {
            throw MediaTrackGraphV4Error.invalidTrack(
                id: "edit_\(ordinal)",
                reason: "empty edits must omit their source range"
            )
        }
        self.ordinal = ordinal
        self.source = source
        self.target = target
        self.isEmpty = isEmpty
    }
}

struct MediaTrackFormatDescriptorV4: Codable, Equatable, Hashable, Sendable {
    let ordinal: UInt32
    let mediaTypeID: String
    let mediaSubtypeID: String
    let canonicalFingerprint: ASHSHA256V4
    let completeness: MediaTrackFormatCompletenessV4

    init(
        ordinal: UInt32,
        mediaTypeID: String,
        mediaSubtypeID: String,
        canonicalFingerprint: ASHSHA256V4,
        completeness: MediaTrackFormatCompletenessV4
    ) throws {
        guard MediaTrackGraphLexiconV4.isStableToken(mediaTypeID),
              MediaTrackGraphLexiconV4.isStableToken(mediaSubtypeID) else {
            throw MediaTrackGraphV4Error.invalidTrack(
                id: "format_\(ordinal)",
                reason: "media type and subtype must be stable tokens"
            )
        }
        self.ordinal = ordinal
        self.mediaTypeID = mediaTypeID
        self.mediaSubtypeID = mediaSubtypeID
        self.canonicalFingerprint = canonicalFingerprint
        self.completeness = completeness
    }
}

struct MediaTrackIdentityV4: Codable, Comparable, Equatable, Hashable,
    Sendable {
    let ordinal: UInt32
    let stableID: MediaTrackStableIDV4
    let containerTrackID: Int32?

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.ordinal != rhs.ordinal { return lhs.ordinal < rhs.ordinal }
        return lhs.stableID < rhs.stableID
    }
}

struct MediaTrackNodeV4: Codable, Equatable, Hashable, Sendable {
    let identity: MediaTrackIdentityV4
    let enabled: Bool
    let kind: MediaTrackKindV4
    let sourceMediaTypeID: String
    let language: MediaTrackLanguageV4
    let roleIDs: [String]
    /// Seconds represented by one source media tick.
    let timebase: ExactRationalV4
    let timeRange: MediaExactTimeRangeV4
    let edits: [MediaTrackEditV4]
    let formatDescriptors: [MediaTrackFormatDescriptorV4]
    let metadataFingerprint: ASHSHA256V4

    init(
        identity: MediaTrackIdentityV4,
        enabled: Bool,
        kind: MediaTrackKindV4,
        sourceMediaTypeID: String,
        language: MediaTrackLanguageV4,
        roleIDs: [String],
        timebase: ExactRationalV4,
        timeRange: MediaExactTimeRangeV4,
        edits: [MediaTrackEditV4],
        formatDescriptors: [MediaTrackFormatDescriptorV4],
        metadataFingerprint: ASHSHA256V4
    ) throws {
        guard MediaTrackGraphLexiconV4.isStableToken(sourceMediaTypeID),
              roleIDs == Array(Set(roleIDs)).sorted(),
              roleIDs.allSatisfy(MediaTrackGraphLexiconV4.isStableToken),
              timebase.isPositive,
              edits.map(\.ordinal) == edits.map(\.ordinal).sorted(),
              Set(edits.map(\.ordinal)).count == edits.count,
              zip(edits, edits.dropFirst()).allSatisfy({
                  $0.target.start <= $1.target.start
              }),
              formatDescriptors.map(\.ordinal)
                == formatDescriptors.map(\.ordinal).sorted(),
              Set(formatDescriptors.map(\.ordinal)).count
                == formatDescriptors.count else {
            throw MediaTrackGraphV4Error.invalidTrack(
                id: identity.stableID.rawValue,
                reason: "track semantics are not canonical"
            )
        }
        self.identity = identity
        self.enabled = enabled
        self.kind = kind
        self.sourceMediaTypeID = sourceMediaTypeID
        self.language = language
        self.roleIDs = roleIDs
        self.timebase = timebase
        self.timeRange = timeRange
        self.edits = edits
        self.formatDescriptors = formatDescriptors
        self.metadataFingerprint = metadataFingerprint
    }

    func replacingFormats(
        _ formats: [MediaTrackFormatDescriptorV4]
    ) throws -> MediaTrackNodeV4 {
        try MediaTrackNodeV4(
            identity: identity,
            enabled: enabled,
            kind: kind,
            sourceMediaTypeID: sourceMediaTypeID,
            language: language,
            roleIDs: roleIDs,
            timebase: timebase,
            timeRange: timeRange,
            edits: edits,
            formatDescriptors: formats,
            metadataFingerprint: metadataFingerprint
        )
    }
}

struct MediaTrackGroupIdentityV4: Codable, Comparable, Equatable, Hashable,
    Sendable {
    let ordinal: UInt32
    let stableID: MediaTrackGroupStableIDV4

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.ordinal != rhs.ordinal { return lhs.ordinal < rhs.ordinal }
        return lhs.stableID < rhs.stableID
    }
}

struct MediaTrackGroupV4: Codable, Equatable, Hashable, Sendable {
    let identity: MediaTrackGroupIdentityV4
    let kind: MediaTrackGroupKindV4
    let memberTrackIDs: [MediaTrackStableIDV4]
    let defaultTrackID: MediaTrackStableIDV4?
    let allowsEmptySelection: Bool

    init(
        identity: MediaTrackGroupIdentityV4,
        kind: MediaTrackGroupKindV4,
        memberTrackIDs: [MediaTrackStableIDV4],
        defaultTrackID: MediaTrackStableIDV4?,
        allowsEmptySelection: Bool
    ) throws {
        guard !memberTrackIDs.isEmpty,
              Set(memberTrackIDs).count == memberTrackIDs.count,
              defaultTrackID.map(memberTrackIDs.contains) ?? true else {
            throw MediaTrackGraphV4Error.invalidGroup(
                id: identity.stableID.rawValue,
                reason: "group membership/default selection is invalid"
            )
        }
        self.identity = identity
        self.kind = kind
        self.memberTrackIDs = memberTrackIDs
        self.defaultTrackID = defaultTrackID
        self.allowsEmptySelection = allowsEmptySelection
    }

    func replacingMembers(
        _ members: [MediaTrackStableIDV4],
        defaultTrackID: MediaTrackStableIDV4?
    ) throws -> MediaTrackGroupV4 {
        try MediaTrackGroupV4(
            identity: identity,
            kind: kind,
            memberTrackIDs: members,
            defaultTrackID: defaultTrackID,
            allowsEmptySelection: allowsEmptySelection
        )
    }
}

struct MediaTrackAssociationV4: Codable, Equatable, Hashable, Sendable {
    let ordinal: UInt32
    let sourceTrackID: MediaTrackStableIDV4
    let targetTrackID: MediaTrackStableIDV4
    let kind: MediaTrackAssociationKindV4
    let sourceAssociationTypeID: String

    init(
        ordinal: UInt32,
        sourceTrackID: MediaTrackStableIDV4,
        targetTrackID: MediaTrackStableIDV4,
        kind: MediaTrackAssociationKindV4,
        sourceAssociationTypeID: String
    ) throws {
        guard sourceTrackID != targetTrackID,
              MediaTrackGraphLexiconV4.isStableToken(
                  sourceAssociationTypeID
              ) else {
            throw MediaTrackGraphV4Error.invalidAssociation(
                ordinal: ordinal,
                reason: "association endpoints/type are invalid"
            )
        }
        self.ordinal = ordinal
        self.sourceTrackID = sourceTrackID
        self.targetTrackID = targetTrackID
        self.kind = kind
        self.sourceAssociationTypeID = sourceAssociationTypeID
    }
}

struct MediaTrackGraphV4: Codable, Equatable, Hashable, Sendable {
    static let currentSchemaID = "ash.media-track-graph.v4.1"
    static let identityDomain = "ash-media-track-graph-v4"

    let schemaID: String
    let tracks: [MediaTrackNodeV4]
    let groups: [MediaTrackGroupV4]
    let associations: [MediaTrackAssociationV4]
    let diagnostics: [MediaTrackDiagnosticV4]

    init(
        tracks: [MediaTrackNodeV4],
        groups: [MediaTrackGroupV4],
        associations: [MediaTrackAssociationV4],
        diagnostics: [MediaTrackDiagnosticV4]
    ) throws {
        schemaID = Self.currentSchemaID
        self.tracks = tracks
        self.groups = groups
        self.associations = associations
        self.diagnostics = diagnostics
        try validate()
    }

    func validate() throws {
        guard schemaID == Self.currentSchemaID else {
            throw MediaTrackGraphV4Error.unsupportedSchema(schemaID)
        }
        guard tracks.map(\.identity) == tracks.map(\.identity).sorted() else {
            throw MediaTrackGraphV4Error.invalidOrdering("tracks")
        }
        var trackIDs = Set<MediaTrackStableIDV4>()
        var trackOrdinals = Set<UInt32>()
        for track in tracks {
            guard trackIDs.insert(track.identity.stableID).inserted else {
                throw MediaTrackGraphV4Error.duplicateTrackID(
                    track.identity.stableID.rawValue
                )
            }
            guard trackOrdinals.insert(track.identity.ordinal).inserted else {
                throw MediaTrackGraphV4Error.duplicateTrackOrdinal(
                    track.identity.ordinal
                )
            }
        }
        let orderByTrack = Dictionary(
            uniqueKeysWithValues: tracks.enumerated().map {
                ($0.element.identity.stableID, $0.offset)
            }
        )

        guard groups.map(\.identity) == groups.map(\.identity).sorted() else {
            throw MediaTrackGraphV4Error.invalidOrdering("groups")
        }
        var groupIDs = Set<MediaTrackGroupStableIDV4>()
        var groupOrdinals = Set<UInt32>()
        for group in groups {
            let groupID = group.identity.stableID
            guard groupIDs.insert(groupID).inserted else {
                throw MediaTrackGraphV4Error.duplicateGroupID(groupID.rawValue)
            }
            guard groupOrdinals.insert(group.identity.ordinal).inserted else {
                throw MediaTrackGraphV4Error.duplicateGroupOrdinal(
                    group.identity.ordinal
                )
            }
            guard group.memberTrackIDs.allSatisfy({ trackIDs.contains($0) }) else {
                throw MediaTrackGraphV4Error.invalidGroup(
                    id: groupID.rawValue,
                    reason: "group references a missing track"
                )
            }
            let memberOrder = group.memberTrackIDs.compactMap {
                orderByTrack[$0]
            }
            guard memberOrder == memberOrder.sorted() else {
                throw MediaTrackGraphV4Error.invalidGroup(
                    id: groupID.rawValue,
                    reason: "group members must follow source track order"
                )
            }
            if let defaultTrackID = group.defaultTrackID,
               tracks.first(where: {
                   $0.identity.stableID == defaultTrackID
               })?.enabled != true {
                throw MediaTrackGraphV4Error.invalidGroup(
                    id: groupID.rawValue,
                    reason: "default member must be enabled"
                )
            }
        }

        guard associations.map(\.ordinal)
            == associations.map(\.ordinal).sorted(),
              Set(associations.map(\.ordinal)).count == associations.count else {
            throw MediaTrackGraphV4Error.invalidOrdering("associations")
        }
        var associationKeys = Set<String>()
        for association in associations {
            guard trackIDs.contains(association.sourceTrackID),
                  trackIDs.contains(association.targetTrackID) else {
                throw MediaTrackGraphV4Error.invalidAssociation(
                    ordinal: association.ordinal,
                    reason: "association references a missing track"
                )
            }
            let key = association.sourceTrackID.rawValue + "\u{0}"
                + association.targetTrackID.rawValue + "\u{0}"
                + association.sourceAssociationTypeID
            guard associationKeys.insert(key).inserted else {
                throw MediaTrackGraphV4Error.invalidAssociation(
                    ordinal: association.ordinal,
                    reason: "duplicate association"
                )
            }
        }

        guard diagnostics == Array(Set(diagnostics)).sorted(),
              diagnostics.allSatisfy({
                  !$0.path.isEmpty
                      && !$0.observedValue.unicodeScalars.contains {
                          $0.value == 0
                      }
              }) else {
            throw MediaTrackGraphV4Error.invalidDiagnostics
        }
    }

    func track(id: MediaTrackStableIDV4) -> MediaTrackNodeV4? {
        tracks.first { $0.identity.stableID == id }
    }

    func group(id: MediaTrackGroupStableIDV4) -> MediaTrackGroupV4? {
        groups.first { $0.identity.stableID == id }
    }

    var canonicalData: Data {
        get throws {
            try validate()
            return try ASHCanonicalJSONV4.encode(self)
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
}

enum MediaTrackGraphLexiconV4 {
    static func isStableIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 160 else { return false }
        return value.utf8.allSatisfy { byte in
            (0x30...0x39).contains(byte)
                || (0x41...0x5a).contains(byte)
                || (0x61...0x7a).contains(byte)
                || [0x2d, 0x2e, 0x3a, 0x5f].contains(byte)
        }
    }

    static func isStableToken(_ value: String) -> Bool {
        isStableIdentifier(value)
    }
}
