import AVFoundation
import CoreMedia
import CoreVideo
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
    let codecConfiguration: AVFoundationBinaryFingerprintV4?
    let channelLayout: AVFoundationBinaryFingerprintV4?
}

private struct AVFoundationBinaryFingerprintV4: Codable, Hashable, Sendable {
    let byteCount: Int64
    let sha256: ASHSHA256V4
}

private struct AVFoundationFormatFingerprintV4: Codable, Hashable, Sendable {
    static let currentSchemaID = "ash.avfoundation-format-fingerprint.v4.2"

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

    static func canonicalSampleStreamFormatDescriptor(
        _ description: CMFormatDescription,
        ordinal: UInt32 = 0
    ) throws -> MediaTrackFormatDescriptorV4 {
        // Keep durable graph and plan identities unchanged. Container wrapper
        // normalization belongs only to verified compressed-stream identity.
        try formatDescriptor(
            description,
            ordinal: ordinal,
            normalizesAC3ContainerWrapper: true
        ).descriptor
    }

    static func probe(asset: AVAsset) async throws -> MediaTrackGraphV4 {
        if let original = OriginalSoftwareMediaContext.associated(with: asset),
           let graph = original.typedProjection.graph {
            try Task.checkCancellation()
            return graph
        }
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
        // AVFoundation's public Swift overlay does not currently name the
        // `auxv` media type even though AVAssetWriter accepts it.
        if mediaType.rawValue == "auxv" { return .auxiliary }
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
            // A muxed stream does not identify a writable auxiliary-track
            // sample contract. Keep it typed as unknown so preservation
            // planning fails closed instead of relabeling it as `auxv`.
            return .unknown
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
        ordinal: UInt32,
        normalizesAC3ContainerWrapper: Bool = false
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
        var normalizesAACContainerWrapper = false
        var hasCompleteAC3Configuration = false
        var pcmDescription: AudioStreamBasicDescription?
        if CMFormatDescriptionGetMediaType(description) == kCMMediaType_Audio,
           let stream = CMAudioFormatDescriptionGetStreamBasicDescription(
               description
           )?.pointee {
            var byteCount = 0
            let codecConfigurationPointer =
                CMAudioFormatDescriptionGetMagicCookie(
                    description,
                    sizeOut: &byteCount
                )
            let codecConfigurationByteCount = byteCount
            if normalizesAC3ContainerWrapper,
               stream.mFormatID == kAudioFormatLinearPCM,
               codecConfigurationByteCount == 0 {
                pcmDescription = stream
            }
            let codecConfiguration = codecConfigurationPointer.map {
                AVFoundationBinaryFingerprintV4(
                    byteCount: Int64(codecConfigurationByteCount),
                    sha256: ASHSHA256V4(rawData: Data(
                        bytes: $0,
                        count: codecConfigurationByteCount
                    ))
                )
            }
            normalizesAACContainerWrapper =
                stream.mFormatID == kAudioFormatMPEG4AAC
                && codecConfigurationPointer != nil
                && codecConfigurationByteCount > 0
            if normalizesAC3ContainerWrapper,
               stream.mFormatID == kAudioFormatAC3,
               codecConfigurationByteCount == 11,
               let codecConfigurationPointer {
                let cookie = Data(
                    bytes: codecConfigurationPointer,
                    count: codecConfigurationByteCount
                )
                // The observed AC3 cookie is one complete dac3 atom: its
                // eight-byte header plus the three-byte AC3 configuration.
                // Unknown or incomplete cookies retain the raw wrapper.
                hasCompleteAC3Configuration = cookie.prefix(8).elementsEqual(
                    [0, 0, 0, 11, 0x64, 0x61, 0x63, 0x33]
                )
            }
            byteCount = 0
            let channelLayout = CMAudioFormatDescriptionGetChannelLayout(
                description,
                sizeOut: &byteCount
            ).map {
                AVFoundationBinaryFingerprintV4(
                    byteCount: Int64(byteCount),
                    sha256: ASHSHA256V4(rawData: Data(
                        bytes: $0,
                        count: byteCount
                    ))
                )
            }
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
                bitsPerChannel: stream.mBitsPerChannel,
                codecConfiguration: codecConfiguration,
                channelLayout: channelLayout
            )
        }
        let extensions: NSDictionary
        if let value = CMFormatDescriptionGetExtensions(description) {
            extensions = value as NSDictionary
        } else {
            extensions = [:]
        }
        let fingerprintExtensions: NSDictionary
        let normalizesPCMContainerWrapper = pcmDescription.map {
            canonicalPCMWrapper(extensions, stream: $0)
        } ?? false
        if normalizesAACContainerWrapper || hasCompleteAC3Configuration
            || normalizesPCMContainerWrapper {
            // Core Media exposes an ISO sample-entry wrapper for MP4 and a
            // QuickTime sample-description wrapper for MOV even when the
            // audio semantics are identical. A complete AC3 dac3 cookie or a
            // nonempty AAC cookie is required because it binds configuration that
            // may otherwise exist only inside the container wrapper. Unknown
            // or incomplete compressed formats retain their verbatim wrapper
            // and therefore fail closed.
            let normalized = NSMutableDictionary(dictionary: extensions)
            normalized.removeObject(forKey: "VerbatimISOSampleEntry")
            normalized.removeObject(forKey: "VerbatimSampleDescription")
            fingerprintExtensions = normalized
        } else if normalizesAC3ContainerWrapper,
                  CMFormatDescriptionGetMediaType(description) == kCMMediaType_Video,
                  CMFormatDescriptionGetMediaSubType(description) == kCMVideoCodecType_H264,
                  let normalized = canonicalAVCVisualSampleEntryWrapper(
                    extensions, width: videoWidth, height: videoHeight
                  ) {
            fingerprintExtensions = normalized
        } else if normalizesAC3ContainerWrapper,
                  CMFormatDescriptionGetMediaSubType(description) == kCMVideoCodecType_JPEG_OpenDML,
                  let normalized = canonicalOpenDMLWrapper(
                    extensions, width: videoWidth, height: videoHeight
                  ) {
            fingerprintExtensions = normalized
        } else {
            fingerprintExtensions = extensions
        }
        let canonicalExtensions = canonicalProperty(fingerprintExtensions)
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
                    : .partial,
                videoRaster: videoWidth.flatMap { width in
                    videoHeight.map { height in
                        CanonicalRasterV4(
                            width: Int64(width),
                            height: Int64(height)
                        )
                    }
                }
            ),
            canonicalExtensions.complete
        )
    }

    /// ISO and QuickTime expose different wrappers for an unchanged avc1
    /// description. Bind its complete visual header and every opaque atom;
    /// fold only the exact typed properties AVAssetWriter materializes in MOV.
    private static func canonicalAVCVisualSampleEntryWrapper(
        _ extensions: NSDictionary, width: Int32?, height: Int32?
    ) -> NSDictionary? {
        let iso = extensions["VerbatimISOSampleEntry"] as? Data
        let movie = extensions["VerbatimSampleDescription"] as? Data
        guard (extensions["VerbatimISOSampleEntry"] != nil)
                != (extensions["VerbatimSampleDescription"] != nil),
              (iso != nil) != (movie != nil), let raw = iso ?? movie,
              extensions["VerifiedAVCVisualSampleEntryHeaderV4"] == nil,
              extensions["VerifiedAVCOpaqueAtomOrderV4"] == nil,
              let width, let height, width > 0, height > 0,
              width <= UInt16.max, height <= UInt16.max,
              raw.count >= 86, raw.count <= UInt32.max,
              let atoms = extensions["SampleDescriptionExtensionAtoms"] as? NSDictionary,
              let configuration = atoms["avcC"] as? Data,
              configuration.count >= 7, configuration[0] == 1 else { return nil }
        let bytes = [UInt8](raw)
        func number(_ offset: Int, _ count: Int) -> UInt64 {
            bytes[offset..<(offset + count)].reduce(0) { ($0 << 8) | UInt64($1) }
        }
        guard number(0, 4) == bytes.count,
              bytes[4..<8].elementsEqual("avc1".utf8),
              bytes[8..<14].allSatisfy({ $0 == 0 }),
              number(14, 2) == 1, number(16, 2) == 0,
              number(32, 2) == UInt64(width),
              number(34, 2) == UInt64(height), bytes[50] <= 31 else { return nil }
        var header = Data(bytes[4..<86])
        if extensions["FormatName"] as? String == "'avc1'" {
            var defaultName = [UInt8](repeating: 0, count: 32)
            defaultName[0] = 6
            defaultName.replaceSubrange(1..<7, with: "'avc1'".utf8)
            let name = bytes[50..<82]
            if name.allSatisfy({ $0 == 0 }) || name.elementsEqual(defaultName) {
                // MOV materializes Core Media's default codec label when the
                // ISO compressor name is empty; all other name bytes stay bound.
                header.replaceSubrange(46..<78, with: repeatElement(UInt8(0), count: 32))
            }
        }
        func matchesNumber(_ value: Any?, _ expected: UInt64) -> Bool {
            guard let value = value as? NSNumber,
                  CFGetTypeID(value) != CFBooleanGetTypeID() else { return false }
            return value.isEqual(to: NSNumber(value: expected))
        }
        var offset = 86
        var seen: Set<String> = []
        var opaqueOrder: [String] = []
        while offset < bytes.count {
            // QuickTime appends one zero terminator after the atom list.
            if movie != nil, bytes.count - offset == 4,
               bytes[offset...].allSatisfy({ $0 == 0 }) { offset += 4; break }
            guard bytes.count - offset >= 8 else { return nil }
            let length = number(offset, 4)
            guard length >= 8, length <= UInt64(bytes.count - offset),
                  let type = String(bytes: bytes[(offset + 4)..<(offset + 8)], encoding: .ascii),
                  seen.insert(type).inserted else { return nil }
            let end = offset + Int(length)
            let payload = Data(bytes[(offset + 8)..<end])
            switch type {
            case "pasp":
                guard payload.count == 8,
                      let aspect = extensions["CVPixelAspectRatio"] as? NSDictionary,
                      matchesNumber(aspect["HorizontalSpacing"], number(offset + 8, 4)),
                      matchesNumber(aspect["VerticalSpacing"], number(offset + 12, 4)) else { return nil }
            case "colr":
                let isNCLC = payload.count == 10
                    && payload.prefix(4).elementsEqual("nclc".utf8)
                let isNCLX = payload.count == 11
                    && payload.prefix(4).elementsEqual("nclx".utf8)
                guard isNCLC || isNCLX,
                      let range = extensions["FullRangeVideo"] as? NSNumber,
                      CFGetTypeID(range) == CFBooleanGetTypeID() else { return nil }
                let primaries = extensions["CVImageBufferColorPrimaries"] as? String
                let transfer = extensions["CVImageBufferTransferFunction"] as? String
                let matrix = extensions["CVImageBufferYCbCrMatrix"] as? String
                // CoreVideo's codepoint mapping rejects unknown numeric tags
                // instead of conflating them with the unspecified code 2.
                guard number(offset + 12, 2) == UInt64(CVColorPrimariesGetIntegerCodePointForString(primaries as CFString?)),
                      number(offset + 14, 2) == UInt64(CVTransferFunctionGetIntegerCodePointForString(transfer as CFString?)),
                      number(offset + 16, 2) == UInt64(CVYCbCrMatrixGetIntegerCodePointForString(matrix as CFString?)),
                      !isNCLX || payload[10] == (range.boolValue ? 0x80 : 0) else { return nil }
            case "fiel":
                guard payload.elementsEqual([1, 0]),
                      matchesNumber(extensions["CVFieldCount"], 1),
                      extensions["CVFieldDetail"] == nil else { return nil }
            case "chrm":
                guard payload.elementsEqual([0, 0]),
                      extensions["CVImageBufferChromaLocationTopField"] as? String == "Left",
                      extensions["CVImageBufferChromaLocationBottomField"] as? String == "Left" else { return nil }
            default:
                guard let exposed = atoms[type] as? Data,
                      exposed == payload else { return nil }
                if type == "avcC" {
                    guard payload == configuration else { return nil }
                } else if type == "btrt" {
                    guard payload.count == 12 else { return nil }
                } else {
                    opaqueOrder.append(type)
                }
            }
            offset = end
        }
        guard offset == bytes.count, seen.contains("avcC") else { return nil }
        let normalized = NSMutableDictionary(dictionary: extensions)
        normalized.removeObject(forKey: "VerbatimISOSampleEntry")
        normalized.removeObject(forKey: "VerbatimSampleDescription")
        normalized["VerifiedAVCVisualSampleEntryHeaderV4"] = header
        normalized["VerifiedAVCOpaqueAtomOrderV4"] = opaqueOrder
        return normalized
    }

    /// AVI has no QuickTime image-description header. Bind the JPEG tables and
    /// field count while accepting only the exact default header AVAssetWriter
    /// adds to MOV. Unrecognized headers, atoms and extension values stay bound.
    private static func canonicalOpenDMLWrapper(
        _ extensions: NSDictionary, width: Int32?, height: Int32?
    ) -> NSDictionary? {
        guard let width, let height, width > 0, height > 0,
              width <= UInt16.max, height <= UInt16.max,
              extensions["VerbatimISOSampleEntry"] == nil,
              let raw = extensions["VerbatimSampleDescription"] as? Data,
              let atoms = extensions["SampleDescriptionExtensionAtoms"] as? NSDictionary,
              atoms.count == 1, let tables = atoms["mjht"] as? Data,
              !tables.isEmpty, tables.count <= 65_536,
              extensions["CVFieldCount"] as? Int == 1,
              extensions["Depth"] as? Int == 24,
              extensions["Version"] as? Int == 0,
              extensions["RevisionLevel"] as? Int == 0,
              extensions["SpatialQuality"] as? Int == 512,
              extensions["TemporalQuality"] as? Int == 512,
              extensions["FormatName"] as? String == "'dmb1'" else { return nil }
        var expected = Data()
        func append(_ value: UInt64, bytes: Int) {
            for shift in (0..<bytes).reversed() {
                expected.append(UInt8(truncatingIfNeeded: value >> (shift * 8)))
            }
        }
        append(UInt64(108 + tables.count), bytes: 4)
        expected.append(contentsOf: "dmb1".utf8)
        expected.append(contentsOf: repeatElement(0, count: 6))
        append(1, bytes: 2) // data reference
        append(0, bytes: 8) // version, revision and vendor
        append(512, bytes: 4)
        append(512, bytes: 4)
        append(UInt64(width), bytes: 2)
        append(UInt64(height), bytes: 2)
        append(72 << 16, bytes: 4)
        append(72 << 16, bytes: 4)
        append(0, bytes: 4)
        append(1, bytes: 2)
        expected.append(6)
        expected.append(contentsOf: "'dmb1'".utf8)
        expected.append(contentsOf: repeatElement(0, count: 25))
        append(24, bytes: 2)
        append(0xffff, bytes: 2)
        append(UInt64(tables.count + 8), bytes: 4)
        expected.append(contentsOf: "mjht".utf8)
        expected.append(tables)
        append(10, bytes: 4)
        expected.append(contentsOf: "fiel".utf8)
        expected.append(contentsOf: [1, 0, 0, 0, 0, 0])
        guard expected == raw else { return nil }
        let normalized = NSMutableDictionary(dictionary: extensions)
        for key in ["VerbatimSampleDescription", "Depth", "Version", "RevisionLevel",
                    "SpatialQuality", "TemporalQuality", "FormatName"] {
            normalized.removeObject(forKey: key)
        }
        return normalized
    }

    /// AVAssetWriter can replace a version-zero sowt/twos entry with a
    /// version-two lpcm entry without changing any PCM samples. Normalize only
    /// the understood header and optional mono/stereo chan atom. Unknown child
    /// atoms remain part of the fingerprint, as do all ASBD/layout fields.
    private static func canonicalPCMWrapper(
        _ extensions: NSDictionary, stream: AudioStreamBasicDescription
    ) -> Bool {
        guard extensions["VerbatimISOSampleEntry"] == nil,
              let raw = extensions["VerbatimSampleDescription"] as? Data else { return false }
        let b = [UInt8](raw)
        guard b.count >= 36 else { return false }
        func number(_ offset: Int, _ count: Int) -> UInt64 {
            b[offset..<(offset + count)].reduce(0) { ($0 << 8) | UInt64($1) }
        }
        guard number(0, 4) == b.count,
              b[8..<14].allSatisfy({ $0 == 0 }), number(14, 2) == 1,
              number(18, 2) == 0, number(20, 4) == 0,
              stream.mFramesPerPacket == 1,
              stream.mBytesPerPacket == stream.mBytesPerFrame,
              [1, 2].contains(stream.mChannelsPerFrame),
              [8, 16, 24, 32].contains(stream.mBitsPerChannel),
              stream.mBytesPerFrame == stream.mChannelsPerFrame * (stream.mBitsPerChannel / 8)
        else { return false }
        let version = number(16, 2)
        let codec = String(bytes: b[4..<8], encoding: .ascii)
        if version == 0, codec == "sowt" || codec == "twos" {
            guard b.count == 36 || b.count == 60,
                  number(24, 2) == stream.mChannelsPerFrame,
                  number(26, 2) == stream.mBitsPerChannel,
                  number(28, 4) == 0,
                  Double(number(32, 4)) / 65536 == stream.mSampleRate,
                  stream.mFormatFlags == (codec == "sowt" ? 12 : 14)
            else { return false }
            if b.count == 60 {
                let tag: UInt64 = stream.mChannelsPerFrame == 1 ? 0x00640001 : 0x00650002
                guard number(36, 4) == 24,
                      String(bytes: b[40..<44], encoding: .ascii) == "chan",
                      number(44, 4) == 0, number(48, 4) == tag,
                      number(52, 4) == 0, number(56, 4) == 0 else { return false }
            }
            return true
        }
        guard version == 2, codec == "lpcm", b.count == 72,
              number(24, 2) == 3, number(26, 2) == 16,
              number(28, 2) == 0xfffe, number(30, 2) == 0,
              number(32, 4) == 0x00010000, number(36, 4) == 72,
              Double(bitPattern: number(40, 8)) == stream.mSampleRate,
              number(48, 4) == stream.mChannelsPerFrame,
              number(52, 4) == 0x7f000000,
              number(56, 4) == stream.mBitsPerChannel,
              number(60, 4) == stream.mFormatFlags,
              number(64, 4) == stream.mBytesPerPacket,
              number(68, 4) == stream.mFramesPerPacket else { return false }
        return true
    }

    static func migratedTrackMetadataItems(
        _ items: [AVMetadataItem]
    ) async throws -> [AVMetadataItem] {
        var result: [AVMetadataItem] = []
        for item in items {
            guard item.identifier?.rawValue == "uiso/name",
                  item.dataType == kCMMetadataBaseDataType_RawData as String,
                  let bytes = try await item.load(.dataValue),
                  let text = String(data: bytes, encoding: .utf8),
                  Data(text.utf8) == bytes else {
                result.append(item)
                continue
            }
            // AVAssetWriter silently drops raw ISO track names in MOV. Use
            // its supported typed track-name encoding without changing text.
            let converted = item.mutableCopy() as! AVMutableMetadataItem
            converted.identifier = .quickTimeUserDataTrackName
            converted.dataType = kCMMetadataBaseDataType_UTF8 as String
            converted.value = text as NSString
            // Typed QuickTime userdata serializes an unspecified metadata
            // language as und. Declare that representation on this converted
            // item; other metadata and explicit language tags stay bound.
            converted.extendedLanguageTag = item.extendedLanguageTag ?? "und"
            converted.locale = item.locale ?? Locale(
                identifier: converted.extendedLanguageTag ?? "und"
            )
            converted.extraAttributes = try await item.load(.extraAttributes)?
                .filter {
                    $0.key.rawValue != "dataType"
                        && $0.key.rawValue != "dataTypeNamespace"
                }
            result.append(converted)
        }
        return result
    }

    static func canonicalMigratedTrackMetadataFingerprint(
        _ items: [AVMetadataItem]
    ) async throws -> ASHSHA256V4 {
        try await canonicalTrackMetadataFingerprint(
            migratedTrackMetadataItems(items)
        )
    }

    private static func metadataFingerprint(
        for track: AVAssetTrack
    ) async throws -> ASHSHA256V4 {
        try await canonicalTrackMetadataFingerprint(track.load(.metadata))
    }

    static func canonicalTrackMetadataFingerprint(
        _ metadata: [AVMetadataItem]
    ) async throws -> ASHSHA256V4 {
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
