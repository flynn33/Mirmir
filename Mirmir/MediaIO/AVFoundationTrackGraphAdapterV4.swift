import AVFoundation
import CoreMedia
import Foundation

enum AVFoundationTrackGraphAdapterV4Error: Error, Equatable, Sendable {
    case duplicateContainerTrackID(Int32)
    case invalidTime(trackID: Int32, field: String)
    case sourceGraphIdentityMismatch
}

private indirect enum AVFoundationCanonicalPropertyV4: Codable, Hashable,
    Sendable {
    case null
    case boolean(Bool)
    case integer(String)
    case realBitPattern(String)
    case string(String)
    case data(byteCount: Int64, sha256: ASHSHA256V4)
    case array([AVFoundationCanonicalPropertyV4])
    case object([AVFoundationCanonicalPropertyEntryV4])
    case unsupported(typeID: String)
}

private struct AVFoundationCanonicalPropertyEntryV4: Codable, Comparable,
    Hashable, Sendable {
    let key: String
    let value: AVFoundationCanonicalPropertyV4

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.key < rhs.key }
}

private struct AVFoundationAudioFormatFingerprintV4: Codable, Hashable,
    Sendable {
    let sampleRateBitPattern: String
    let formatID: String
    let formatFlags: UInt32
    let bytesPerPacket: UInt32
    let framesPerPacket: UInt32
    let bytesPerFrame: UInt32
    let channelsPerFrame: UInt32
    let bitsPerChannel: UInt32
}

private struct AVFoundationFormatFingerprintV4: Codable, Hashable, Sendable {
    static let currentSchemaID = "ash.avfoundation-format-fingerprint.v4.1"

    let schemaID: String
    let mediaTypeID: String
    let mediaSubtypeID: String
    let videoWidth: Int32?
    let videoHeight: Int32?
    let audio: AVFoundationAudioFormatFingerprintV4?
    let extensions: AVFoundationCanonicalPropertyV4

    init(
        mediaTypeID: String,
        mediaSubtypeID: String,
        videoWidth: Int32?,
        videoHeight: Int32?,
        audio: AVFoundationAudioFormatFingerprintV4?,
        extensions: AVFoundationCanonicalPropertyV4
    ) {
        schemaID = Self.currentSchemaID
        self.mediaTypeID = mediaTypeID
        self.mediaSubtypeID = mediaSubtypeID
        self.videoWidth = videoWidth
        self.videoHeight = videoHeight
        self.audio = audio
        self.extensions = extensions
    }
}

private struct AVFoundationMetadataFingerprintItemV4: Codable, Comparable,
    Hashable, Sendable {
    let identifier: String
    let dataType: String
    let languageTag: String
    let valueKind: String
    let valueSHA256: ASHSHA256V4

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.identifier != rhs.identifier {
            return lhs.identifier < rhs.identifier
        }
        if lhs.dataType != rhs.dataType { return lhs.dataType < rhs.dataType }
        if lhs.languageTag != rhs.languageTag {
            return lhs.languageTag < rhs.languageTag
        }
        if lhs.valueKind != rhs.valueKind {
            return lhs.valueKind < rhs.valueKind
        }
        return lhs.valueSHA256 < rhs.valueSHA256
    }
}

private struct AVFoundationMetadataFingerprintV4: Codable, Hashable, Sendable {
    static let currentSchemaID = "ash.avfoundation-track-metadata.v4.1"

    let schemaID: String
    let items: [AVFoundationMetadataFingerprintItemV4]

    init(items: [AVFoundationMetadataFingerprintItemV4]) {
        schemaID = Self.currentSchemaID
        self.items = items.sorted()
    }
}

enum AVFoundationTrackGraphAdapterV4 {
    /// Produces the same canonical descriptor used by whole-asset probing.
    /// Processed-track planners use this only after a real encoder calibration
    /// has produced its final sample description; callers never synthesize a
    /// fingerprint from requested settings.
    static func canonicalFormatDescriptor(
        _ description: CMFormatDescription,
        ordinal: UInt32 = 0
    ) throws -> MediaTrackFormatDescriptorV4 {
        try formatDescriptor(description, ordinal: ordinal).descriptor
    }

    static func probe(asset: AVAsset) async throws -> MediaTrackGraphV4 {
        let assetTracks = try await asset.load(.tracks)
        var trackIDMap: [Int32: MediaTrackStableIDV4] = [:]
        for (offset, track) in assetTracks.enumerated() {
            let containerID = track.trackID
            guard trackIDMap[containerID] == nil else {
                throw AVFoundationTrackGraphAdapterV4Error
                    .duplicateContainerTrackID(containerID)
            }
            trackIDMap[containerID] = try stableID(
                containerTrackID: containerID,
                ordinal: offset
            )
        }

        var diagnostics: [MediaTrackDiagnosticV4] = []
        var associations: [MediaTrackAssociationV4] = []
        var chapterTrackIDs = Set<MediaTrackStableIDV4>()
        for track in assetTracks {
            guard let sourceID = trackIDMap[track.trackID] else { continue }
            let types = try await track.load(.availableTrackAssociationTypes)
                .sorted { $0.rawValue < $1.rawValue }
            for type in types {
                let targets = try await track.loadAssociatedTracks(ofType: type)
                    .sorted { $0.trackID < $1.trackID }
                for target in targets {
                    guard let targetID = trackIDMap[target.trackID] else {
                        diagnostics.append(MediaTrackDiagnosticV4(
                            severity: .error,
                            code: .danglingAssociation,
                            path: "associations.\(sourceID.rawValue)",
                            observedValue: "missing_container_track_\(target.trackID)"
                        ))
                        continue
                    }
                    let associationKind = kind(for: type)
                    if associationKind == .chapterList {
                        chapterTrackIDs.insert(targetID)
                    }
                    associations.append(try MediaTrackAssociationV4(
                        ordinal: UInt32(associations.count),
                        sourceTrackID: sourceID,
                        targetTrackID: targetID,
                        kind: associationKind,
                        sourceAssociationTypeID: stableToken(type.rawValue)
                    ))
                }
            }
        }

        var nodes: [MediaTrackNodeV4] = []
        nodes.reserveCapacity(assetTracks.count)
        for (offset, track) in assetTracks.enumerated() {
            let trackID = try stableID(
                containerTrackID: track.trackID,
                ordinal: offset
            )
            let result = try await probe(
                track: track,
                identity: MediaTrackIdentityV4(
                    ordinal: UInt32(offset),
                    stableID: trackID,
                    containerTrackID: track.trackID
                ),
                isChapter: chapterTrackIDs.contains(trackID)
            )
            nodes.append(result.node)
            diagnostics.append(contentsOf: result.diagnostics)
        }

        let assetGroups = try await asset.load(.trackGroups)
        var groups: [MediaTrackGroupV4] = []
        for (offset, group) in assetGroups.enumerated() {
            var memberIDs: [MediaTrackStableIDV4] = []
            for number in group.trackIDs {
                let containerID = number.int32Value
                guard let memberID = trackIDMap[containerID] else {
                    diagnostics.append(MediaTrackDiagnosticV4(
                        severity: .error,
                        code: .danglingGroupMember,
                        path: "groups.av-group-\(offset)",
                        observedValue: "missing_container_track_\(containerID)"
                    ))
                    continue
                }
                memberIDs.append(memberID)
            }
            let sourceOrder = Dictionary(
                uniqueKeysWithValues: nodes.enumerated().map {
                    ($0.element.identity.stableID, $0.offset)
                }
            )
            memberIDs.sort { sourceOrder[$0, default: .max]
                < sourceOrder[$1, default: .max] }
            guard !memberIDs.isEmpty else { continue }
            let enabledMembers = memberIDs.filter { id in
                nodes.first { $0.identity.stableID == id }?.enabled == true
            }
            if enabledMembers.count > 1 {
                diagnostics.append(MediaTrackDiagnosticV4(
                    severity: .error,
                    code: .contradictoryGroupSelection,
                    path: "groups.av-group-\(offset).default",
                    observedValue: enabledMembers.map(\.rawValue)
                        .joined(separator: ",")
                ))
            }
            groups.append(try MediaTrackGroupV4(
                identity: MediaTrackGroupIdentityV4(
                    ordinal: UInt32(offset),
                    stableID: MediaTrackGroupStableIDV4("av-group-\(offset)")
                ),
                kind: .alternate,
                memberTrackIDs: memberIDs,
                defaultTrackID: enabledMembers.count == 1
                    ? enabledMembers[0]
                    : nil,
                allowsEmptySelection: enabledMembers.isEmpty
            ))
        }

        return try MediaTrackGraphV4(
            tracks: nodes,
            groups: groups,
            associations: associations,
            diagnostics: Array(Set(diagnostics)).sorted()
        )
    }

    private struct ProbedTrack {
        let node: MediaTrackNodeV4
        let diagnostics: [MediaTrackDiagnosticV4]
    }

    private static func probe(
        track: AVAssetTrack,
        identity: MediaTrackIdentityV4,
        isChapter: Bool
    ) async throws -> ProbedTrack {
        var diagnostics: [MediaTrackDiagnosticV4] = []
        let path = "tracks.\(identity.stableID.rawValue)"
        let kind = mediaKind(for: track.mediaType, isChapter: isChapter)
        if kind == .unknown {
            diagnostics.append(MediaTrackDiagnosticV4(
                severity: .warning,
                code: .unknownMediaType,
                path: path + ".kind",
                observedValue: stableToken(track.mediaType.rawValue)
            ))
        }

        let loadedTimeScale = try await track.load(.naturalTimeScale)
        let naturalTimeScale: CMTimeScale
        if loadedTimeScale > 0 {
            naturalTimeScale = loadedTimeScale
        } else {
            naturalTimeScale = 1
            diagnostics.append(MediaTrackDiagnosticV4(
                severity: .error,
                code: .timingMismatch,
                path: path + ".timebase",
                observedValue: "invalid_timescale_\(loadedTimeScale)"
            ))
        }
        let timeRange = try await track.load(.timeRange)
        let exactTimeRange: MediaExactTimeRangeV4
        do {
            exactTimeRange = try exact(timeRange, trackID: track.trackID)
        } catch {
            exactTimeRange = try MediaExactTimeRangeV4(
                start: .zero,
                duration: .zero
            )
            diagnostics.append(MediaTrackDiagnosticV4(
                severity: .error,
                code: .timingMismatch,
                path: path + ".timeRange",
                observedValue: "invalid_or_unloaded"
            ))
        }
        let segments = try await track.load(.segments)
        var edits: [MediaTrackEditV4] = []
        for (offset, segment) in segments.enumerated() {
            let mapping = segment.timeMapping
            edits.append(try MediaTrackEditV4(
                ordinal: UInt32(offset),
                source: segment.isEmpty
                    ? nil
                    : try exact(mapping.source, trackID: track.trackID),
                target: try exact(mapping.target, trackID: track.trackID),
                isEmpty: segment.isEmpty
            ))
        }

        let formatDescriptions = try await track.load(.formatDescriptions)
        var formats: [MediaTrackFormatDescriptorV4] = []
        for (offset, description) in formatDescriptions.enumerated() {
            let result = try formatDescriptor(
                description,
                ordinal: UInt32(offset)
            )
            formats.append(result.descriptor)
            if result.descriptor.completeness != .complete {
                diagnostics.append(MediaTrackDiagnosticV4(
                    severity: .warning,
                    code: .partialFormatDescriptor,
                    path: path + ".formats.\(offset)",
                    observedValue: result.descriptor.mediaSubtypeID
                ))
            }
        }
        if formats.isEmpty {
            diagnostics.append(MediaTrackDiagnosticV4(
                severity: .warning,
                code: .missingFormatDescriptor,
                path: path + ".formats",
                observedValue: "empty"
            ))
        }

        let language = try MediaTrackLanguageV4(
            languageCode: try await track.load(.languageCode),
            extendedLanguageTag: try await track.load(.extendedLanguageTag)
        )
        let roles = try await track.load(.mediaCharacteristics)
            .map { stableToken($0.rawValue) }
            .sorted()
        let metadata = try await metadataFingerprint(for: track)
        let node = try MediaTrackNodeV4(
            identity: identity,
            enabled: try await track.load(.isEnabled),
            kind: kind,
            sourceMediaTypeID: stableToken(track.mediaType.rawValue),
            language: language,
            roleIDs: Array(Set(roles)).sorted(),
            timebase: try ExactRationalV4(1, Int64(naturalTimeScale)),
            timeRange: exactTimeRange,
            edits: edits,
            formatDescriptors: formats,
            metadataFingerprint: metadata
        )
        return ProbedTrack(node: node, diagnostics: diagnostics)
    }

    private static func exact(
        _ range: CMTimeRange,
        trackID: Int32
    ) throws -> MediaExactTimeRangeV4 {
        guard range.isValid,
              range.start.isNumeric,
              range.duration.isNumeric,
              range.start.timescale > 0,
              range.duration.timescale > 0 else {
            throw AVFoundationTrackGraphAdapterV4Error.invalidTime(
                trackID: trackID,
                field: "timeRange"
            )
        }
        return try MediaExactTimeRangeV4(
            start: ExactRationalV4(
                range.start.value,
                Int64(range.start.timescale)
            ),
            duration: ExactRationalV4(
                range.duration.value,
                Int64(range.duration.timescale)
            )
        )
    }

    private static func stableID(
        containerTrackID: Int32,
        ordinal: Int
    ) throws -> MediaTrackStableIDV4 {
        if containerTrackID == 0 {
            return try MediaTrackStableIDV4("av-track-ordinal-\(ordinal)")
        }
        return try MediaTrackStableIDV4("av-track-\(containerTrackID)")
    }

    private static func mediaKind(
        for mediaType: AVMediaType,
        isChapter: Bool
    ) -> MediaTrackKindV4 {
        if isChapter { return .chapter }
        switch mediaType {
        case .video:
            return .video
        case .audio:
            return .audio
        case .subtitle, .text:
            return .subtitle
        case .closedCaption:
            return .caption
        case .timecode:
            return .timecode
        case .metadata:
            return .timedMetadata
        case .muxed:
            return .auxiliary
        default:
            return .unknown
        }
    }

    private static func kind(
        for type: AVAssetTrack.AssociationType
    ) -> MediaTrackAssociationKindV4 {
        switch type {
        case .audioFallback:
            return .audioFallback
        case .chapterList:
            return .chapterList
        case .forcedSubtitlesOnly:
            return .forcedSubtitlesOnly
        case .selectionFollower:
            return .selectionFollower
        case .timecode:
            return .timecode
        case .metadataReferent:
            return .metadataReferent
        default:
            if #available(macOS 26, *), type == .renderMetadataSource {
                return .renderMetadataSource
            }
            return .unknown
        }
    }

    private static func formatDescriptor(
        _ description: CMFormatDescription,
        ordinal: UInt32
    ) throws -> (
        descriptor: MediaTrackFormatDescriptorV4,
        complete: Bool
    ) {
        let mediaTypeID = fourCC(CMFormatDescriptionGetMediaType(description))
        let mediaSubtypeID = fourCC(
            CMFormatDescriptionGetMediaSubType(description)
        )
        var videoWidth: Int32?
        var videoHeight: Int32?
        if CMFormatDescriptionGetMediaType(description) == kCMMediaType_Video {
            let dimensions = CMVideoFormatDescriptionGetDimensions(description)
            videoWidth = dimensions.width
            videoHeight = dimensions.height
        }
        var audio: AVFoundationAudioFormatFingerprintV4?
        if CMFormatDescriptionGetMediaType(description) == kCMMediaType_Audio,
           let stream = CMAudioFormatDescriptionGetStreamBasicDescription(
               description
           )?.pointee {
            audio = AVFoundationAudioFormatFingerprintV4(
                sampleRateBitPattern: String(
                    stream.mSampleRate.bitPattern,
                    radix: 16
                ),
                formatID: fourCC(stream.mFormatID),
                formatFlags: stream.mFormatFlags,
                bytesPerPacket: stream.mBytesPerPacket,
                framesPerPacket: stream.mFramesPerPacket,
                bytesPerFrame: stream.mBytesPerFrame,
                channelsPerFrame: stream.mChannelsPerFrame,
                bitsPerChannel: stream.mBitsPerChannel
            )
        }
        let extensions: NSDictionary
        if let value = CMFormatDescriptionGetExtensions(description) {
            extensions = value as NSDictionary
        } else {
            extensions = [:]
        }
        let canonicalExtensions = canonicalProperty(extensions)
        let payload = AVFoundationFormatFingerprintV4(
            mediaTypeID: mediaTypeID,
            mediaSubtypeID: mediaSubtypeID,
            videoWidth: videoWidth,
            videoHeight: videoHeight,
            audio: audio,
            extensions: canonicalExtensions.value
        )
        let fingerprint = try ASHCanonicalJSONV4.hash(
            payload,
            domain: "ash-avfoundation-format-description-v4"
        )
        return (
            try MediaTrackFormatDescriptorV4(
                ordinal: ordinal,
                mediaTypeID: mediaTypeID,
                mediaSubtypeID: mediaSubtypeID,
                canonicalFingerprint: fingerprint,
                completeness: canonicalExtensions.complete
                    ? .complete
                    : .partial
            ),
            canonicalExtensions.complete
        )
    }

    private static func metadataFingerprint(
        for track: AVAssetTrack
    ) async throws -> ASHSHA256V4 {
        let metadata = try await track.load(.metadata)
        var items: [AVFoundationMetadataFingerprintItemV4] = []
        for item in metadata {
            let dataValue = try await item.load(.dataValue)
            let stringValue = dataValue == nil
                ? try await item.load(.stringValue)
                : nil
            let bytes: Data
            let kind: String
            if let dataValue {
                bytes = dataValue
                kind = "data"
            } else if let stringValue {
                bytes = Data(stringValue.utf8)
                kind = "string"
            } else {
                bytes = Data()
                kind = "unavailable"
            }
            items.append(AVFoundationMetadataFingerprintItemV4(
                identifier: stableToken(item.identifier?.rawValue ?? "none"),
                dataType: stableToken(item.dataType ?? "none"),
                languageTag: stableToken(
                    item.extendedLanguageTag ?? "none"
                ),
                valueKind: kind,
                valueSHA256: ASHSHA256V4(rawData: bytes)
            ))
        }
        return try ASHCanonicalJSONV4.hash(
            AVFoundationMetadataFingerprintV4(items: items),
            domain: "ash-avfoundation-track-metadata-v4"
        )
    }

    private static func canonicalProperty(
        _ value: Any
    ) -> (value: AVFoundationCanonicalPropertyV4, complete: Bool) {
        if value is NSNull { return (.null, true) }
        if CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID(),
           let boolean = value as? Bool {
            return (.boolean(boolean), true)
        }
        if let number = value as? NSNumber {
            let type = String(cString: number.objCType)
            if ["f", "d"].contains(type) {
                return (
                    .realBitPattern(
                        String(number.doubleValue.bitPattern, radix: 16)
                    ),
                    true
                )
            }
            return (.integer(number.stringValue), true)
        }
        if let string = value as? String { return (.string(string), true) }
        if let data = value as? Data {
            return (
                .data(
                    byteCount: Int64(data.count),
                    sha256: ASHSHA256V4(rawData: data)
                ),
                true
            )
        }
        if let array = value as? [Any] {
            var complete = true
            let values = array.map { element in
                let result = canonicalProperty(element)
                complete = complete && result.complete
                return result.value
            }
            return (.array(values), complete)
        }
        if let dictionary = value as? NSDictionary {
            var complete = true
            var entries: [AVFoundationCanonicalPropertyEntryV4] = []
            for (key, entryValue) in dictionary {
                guard let key = key as? String else {
                    complete = false
                    continue
                }
                let result = canonicalProperty(entryValue)
                complete = complete && result.complete
                entries.append(AVFoundationCanonicalPropertyEntryV4(
                    key: key,
                    value: result.value
                ))
            }
            return (.object(entries.sorted()), complete)
        }
        return (
            .unsupported(typeID: stableToken(String(reflecting: type(of: value)))),
            false
        )
    }

    private static func fourCC(_ code: FourCharCode) -> String {
        "fourcc_" + String(format: "%08x", code)
    }

    private static func stableToken(_ rawValue: String) -> String {
        if MediaTrackGraphLexiconV4.isStableToken(rawValue) {
            return rawValue
        }
        return "utf8_" + rawValue.utf8.map {
            String(format: "%02x", $0)
        }.joined()
    }
}

enum AVFoundationTrackReaderStrategyV4: String, Codable, Hashable, Sendable {
    case encodedTrackOutput = "av_asset_reader_track_output_encoded"
    case decodedVideoOutput = "av_asset_reader_track_output_decoded_video"
    case externalTranscoder = "external_transcoder"
    case none
}

enum AVFoundationTrackWriterStrategyV4: String, Codable, Hashable, Sendable {
    case sourceFormatHintInput = "av_asset_writer_input_source_format_hint"
    case processedVideoInput = "av_asset_writer_input_processed_video"
    case externalTranscoder = "external_transcoder"
    case none
}

enum AVFoundationTrackMigrationOutcomeV4: String, Codable, Hashable,
    Sendable {
    case directReaderWriter = "direct_reader_writer"
    case requiresProcessor = "requires_processor"
    case requiresComposition = "requires_composition"
    case authorizedDrop = "authorized_drop"
    case incompatible
}

enum AVFoundationTrackMigrationLimitationV4: String, CaseIterable, Codable,
    Comparable, Hashable, Sendable {
    case formatDescriptorRequiresVerification = "format_descriptor_requires_verification"
    case outputOrderRequiresVerification = "output_order_requires_verification"
    case persistentTrackIDNotControllable = "persistent_track_id_not_controllable"
    case trackMetadataRequiresMigration = "track_metadata_requires_migration"
    case unknownMediaType = "unknown_media_type"
    case missingSourceFormatHint = "missing_source_format_hint"
    case arbitraryEditListRequiresComposition = "arbitrary_edit_list_requires_composition"
    case unknownTrackGroup = "unknown_track_group"
    case unknownTrackAssociation = "unknown_track_association"

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct AVFoundationTrackMigrationV4: Codable, Equatable, Hashable, Sendable {
    let trackID: MediaTrackStableIDV4
    let sourceOrdinal: UInt32
    let action: MediaTrackActionV4
    let readerStrategy: AVFoundationTrackReaderStrategyV4
    let writerStrategy: AVFoundationTrackWriterStrategyV4
    let outcome: AVFoundationTrackMigrationOutcomeV4
    let limitations: [AVFoundationTrackMigrationLimitationV4]
}

struct AVFoundationGroupMigrationV4: Codable, Equatable, Hashable, Sendable {
    let groupID: MediaTrackGroupStableIDV4
    let action: MediaTrackActionV4
    let usesAVAssetWriterInputGroup: Bool
    let outcome: AVFoundationTrackMigrationOutcomeV4
    let limitations: [AVFoundationTrackMigrationLimitationV4]
}

struct AVFoundationAssociationMigrationV4: Codable, Equatable, Hashable,
    Sendable {
    let ordinal: UInt32
    let action: MediaTrackActionV4
    let usesAVAssetWriterInputAssociation: Bool
    let outcome: AVFoundationTrackMigrationOutcomeV4
    let limitations: [AVFoundationTrackMigrationLimitationV4]
}

struct AVFoundationTrackMigrationBlueprintV4: Codable, Equatable, Hashable,
    Sendable {
    static let currentSchemaID = "ash.avfoundation-track-migration.v4.1"
    static let identityDomain = "ash-avfoundation-track-migration-v4"

    let schemaID: String
    let sourceGraphSHA256: ASHSHA256V4
    let planSHA256: ASHSHA256V4
    let tracks: [AVFoundationTrackMigrationV4]
    let groups: [AVFoundationGroupMigrationV4]
    let associations: [AVFoundationAssociationMigrationV4]

    init(
        sourceGraphSHA256: ASHSHA256V4,
        planSHA256: ASHSHA256V4,
        tracks: [AVFoundationTrackMigrationV4],
        groups: [AVFoundationGroupMigrationV4],
        associations: [AVFoundationAssociationMigrationV4]
    ) {
        schemaID = Self.currentSchemaID
        self.sourceGraphSHA256 = sourceGraphSHA256
        self.planSHA256 = planSHA256
        self.tracks = tracks
        self.groups = groups
        self.associations = associations
    }

    var hasIncompatibility: Bool {
        tracks.contains { $0.outcome == .incompatible }
            || groups.contains { $0.outcome == .incompatible }
            || associations.contains { $0.outcome == .incompatible }
    }

    var canonicalSHA256: ASHSHA256V4 {
        get throws {
            try ASHCanonicalJSONV4.hash(self, domain: Self.identityDomain)
        }
    }
}

enum AVFoundationTrackMigrationPlannerV4 {
    static func makeBlueprint(
        source: MediaTrackGraphV4,
        plan identifiedPlan: MediaTrackGraphIdentifiedPlanV4
    ) throws -> AVFoundationTrackMigrationBlueprintV4 {
        try source.validate()
        try identifiedPlan.verify()
        let sourceHash = try source.canonicalSHA256
        guard sourceHash == identifiedPlan.plan.sourceGraphSHA256 else {
            throw AVFoundationTrackGraphAdapterV4Error
                .sourceGraphIdentityMismatch
        }

        let tracks = identifiedPlan.plan.tracks.map { planned in
            migration(for: planned)
        }
        let groups = identifiedPlan.plan.groups.map { planned in
            let unknown = planned.source.kind == .unknown
            return AVFoundationGroupMigrationV4(
                groupID: planned.source.identity.stableID,
                action: planned.action,
                usesAVAssetWriterInputGroup:
                    planned.action != .dropWithConsent && !unknown,
                outcome: planned.action == .dropWithConsent
                    ? .authorizedDrop
                    : unknown ? .incompatible : .directReaderWriter,
                limitations: unknown ? [.unknownTrackGroup] : []
            )
        }
        let associations = identifiedPlan.plan.associations.map { planned in
            let unknown = planned.source.kind == .unknown
            return AVFoundationAssociationMigrationV4(
                ordinal: planned.source.ordinal,
                action: planned.action,
                usesAVAssetWriterInputAssociation:
                    planned.action == .passThrough && !unknown,
                outcome: planned.action == .dropWithConsent
                    ? .authorizedDrop
                    : unknown ? .incompatible : .directReaderWriter,
                limitations: unknown ? [.unknownTrackAssociation] : []
            )
        }
        return AVFoundationTrackMigrationBlueprintV4(
            sourceGraphSHA256: sourceHash,
            planSHA256: identifiedPlan.planSHA256,
            tracks: tracks,
            groups: groups,
            associations: associations
        )
    }

    private static func migration(
        for planned: MediaTrackPlannedTrackV4
    ) -> AVFoundationTrackMigrationV4 {
        var limitations: Set<AVFoundationTrackMigrationLimitationV4> = [
            .outputOrderRequiresVerification,
            .persistentTrackIDNotControllable,
            .formatDescriptorRequiresVerification,
            .trackMetadataRequiresMigration
        ]
        let track = planned.source
        switch planned.action {
        case .dropWithConsent:
            return AVFoundationTrackMigrationV4(
                trackID: track.identity.stableID,
                sourceOrdinal: track.identity.ordinal,
                action: planned.action,
                readerStrategy: .none,
                writerStrategy: .none,
                outcome: .authorizedDrop,
                limitations: []
            )
        case .process:
            return AVFoundationTrackMigrationV4(
                trackID: track.identity.stableID,
                sourceOrdinal: track.identity.ordinal,
                action: planned.action,
                readerStrategy: .decodedVideoOutput,
                writerStrategy: .processedVideoInput,
                outcome: .requiresProcessor,
                limitations: Array(limitations).sorted()
            )
        case .transcode:
            return AVFoundationTrackMigrationV4(
                trackID: track.identity.stableID,
                sourceOrdinal: track.identity.ordinal,
                action: planned.action,
                readerStrategy: .externalTranscoder,
                writerStrategy: .externalTranscoder,
                outcome: .requiresProcessor,
                limitations: Array(limitations).sorted()
            )
        case .passThrough:
            if track.kind == .unknown {
                limitations.insert(.unknownMediaType)
                return incompatible(planned, limitations: limitations)
            }
            if track.formatDescriptors.isEmpty {
                limitations.insert(.missingSourceFormatHint)
                return incompatible(planned, limitations: limitations)
            }
            if track.edits.count > 1 || track.edits.contains(where: \.isEmpty) {
                limitations.insert(.arbitraryEditListRequiresComposition)
                return AVFoundationTrackMigrationV4(
                    trackID: track.identity.stableID,
                    sourceOrdinal: track.identity.ordinal,
                    action: planned.action,
                    readerStrategy: .encodedTrackOutput,
                    writerStrategy: .sourceFormatHintInput,
                    outcome: .requiresComposition,
                    limitations: Array(limitations).sorted()
                )
            }
            return AVFoundationTrackMigrationV4(
                trackID: track.identity.stableID,
                sourceOrdinal: track.identity.ordinal,
                action: planned.action,
                readerStrategy: .encodedTrackOutput,
                writerStrategy: .sourceFormatHintInput,
                outcome: .directReaderWriter,
                limitations: Array(limitations).sorted()
            )
        }
    }

    private static func incompatible(
        _ planned: MediaTrackPlannedTrackV4,
        limitations: Set<AVFoundationTrackMigrationLimitationV4>
    ) -> AVFoundationTrackMigrationV4 {
        AVFoundationTrackMigrationV4(
            trackID: planned.source.identity.stableID,
            sourceOrdinal: planned.source.identity.ordinal,
            action: planned.action,
            readerStrategy: .none,
            writerStrategy: .none,
            outcome: .incompatible,
            limitations: Array(limitations).sorted()
        )
    }
}
