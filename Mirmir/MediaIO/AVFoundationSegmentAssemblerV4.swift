import AVFoundation
import CoreMedia
import CoreVideo
import CryptoKit
import Darwin
import Foundation

enum AVFoundationSegmentV4Error: Error, Equatable, LocalizedError, Sendable {
    case emptySegmentSet
    case invalidSegmentSequence
    case unsafeArtifact(String)
    case unreadableAsset(String)
    case emptyTrack(Int32)
    case nonIndependentVideoTrack(Int32)
    case segmentDurationMismatch(ordinal: UInt64)
    case trackLayoutMismatch(ordinal: UInt64)
    case unsupportedTrackLayout(String)
    case exportUnavailable
    case exportFailed(String)
    case assembledPayloadMismatch
    case assembledDecodedPayloadMismatch(String)
    case assembledTimingMismatch
    case assembledLayoutMismatch

    var errorDescription: String? {
        switch self {
        case .emptySegmentSet:
            "At least one independently decodable segment is required."
        case .invalidSegmentSequence:
            "The segment sequence is non-contiguous or changes codec identity."
        case let .unsafeArtifact(path):
            "The checkpoint artifact is not a safe single-link regular file: \(path)"
        case let .unreadableAsset(reason):
            "The segment media asset is unreadable: \(reason)"
        case let .emptyTrack(trackID):
            "Segment track \(trackID) contains no media samples."
        case let .nonIndependentVideoTrack(trackID):
            "Segment video track \(trackID) does not begin with a sync sample."
        case let .segmentDurationMismatch(ordinal):
            "Segment \(ordinal) does not cover its declared checkpoint interval."
        case let .trackLayoutMismatch(ordinal):
            "Segment \(ordinal) changes the deterministic track layout."
        case let .unsupportedTrackLayout(reason):
            "The segmented track layout cannot be assembled losslessly: \(reason)"
        case .exportUnavailable:
            "AVFoundation cannot create a passthrough exporter for the segments."
        case let .exportFailed(reason):
            "AVFoundation segment assembly failed: \(reason)"
        case .assembledPayloadMismatch:
            "The assembled media payload differs from the checkpoint segments."
        case let .assembledDecodedPayloadMismatch(reason):
            "The assembled decoded video differs from the checkpoint segments: \(reason)"
        case .assembledTimingMismatch:
            "The assembled media timing differs from the checkpoint segments."
        case .assembledLayoutMismatch:
            "The assembled track layout differs from the checkpoint segments."
        }
    }
}

/// A stable track key intentionally excludes the container-assigned track ID.
/// Independently encoded segments are allowed to receive different physical
/// IDs, while their semantic media role must remain unchanged.
struct AVFoundationSegmentTrackKeyV4: Codable, Comparable, Hashable, Sendable {
    let mediaType: String
    let mediaSubType: UInt32
    let languageCode: String?
    let extendedLanguageTag: String?
    let roleOrdinal: Int

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.mediaType != rhs.mediaType { return lhs.mediaType < rhs.mediaType }
        if lhs.mediaSubType != rhs.mediaSubType {
            return lhs.mediaSubType < rhs.mediaSubType
        }
        if lhs.languageCode != rhs.languageCode {
            return (lhs.languageCode ?? "") < (rhs.languageCode ?? "")
        }
        if lhs.extendedLanguageTag != rhs.extendedLanguageTag {
            return (lhs.extendedLanguageTag ?? "")
                < (rhs.extendedLanguageTag ?? "")
        }
        return lhs.roleOrdinal < rhs.roleOrdinal
    }
}

struct AVFoundationSegmentTrackIdentityV4: Codable, Equatable, Hashable,
    Sendable {
    let key: AVFoundationSegmentTrackKeyV4
    let naturalTimeScale: Int32
    let preferredTransform: [Double]
    let sampleCount: UInt64
    let payloadStreamSHA256: String
    let timingStreamSHA256: String
    let firstPresentationTime: WorkflowMediaTimeV4
    let endPresentationTimeExclusive: WorkflowMediaTimeV4
    let firstSampleIsSync: Bool
}

struct AVFoundationSegmentIdentityV4: Codable, Equatable, Hashable, Sendable {
    static let currentSchemaVersion: UInt16 = 1

    let schemaVersion: UInt16
    let duration: WorkflowMediaTimeV4
    let tracks: [AVFoundationSegmentTrackIdentityV4]
    let commonMetadataSHA256: String

    init(
        duration: WorkflowMediaTimeV4,
        tracks: [AVFoundationSegmentTrackIdentityV4],
        commonMetadataSHA256: String
    ) throws {
        guard !tracks.isEmpty,
              Set(tracks.map(\.key)).count == tracks.count,
              tracks.allSatisfy({ $0.sampleCount > 0 }),
              commonMetadataSHA256.count == 64 else {
            throw AVFoundationSegmentV4Error.unreadableAsset(
                "invalid canonical segment identity"
            )
        }
        schemaVersion = Self.currentSchemaVersion
        self.duration = duration
        self.tracks = tracks.sorted { $0.key < $1.key }
        self.commonMetadataSHA256 = commonMetadataSHA256
    }

    var layoutSHA256: String {
        get throws {
            let layouts = tracks.map {
                AVFoundationSegmentTrackLayoutV4(
                    key: $0.key,
                    naturalTimeScale: $0.naturalTimeScale,
                    preferredTransform: $0.preferredTransform
                )
            }
            return Self.sha256(try Self.canonicalData(layouts))
        }
    }

    var canonicalSHA256: String {
        get throws { Self.sha256(try Self.canonicalData(self)) }
    }

    private static func canonicalData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private struct AVFoundationSegmentTrackLayoutV4: Codable, Hashable, Sendable {
    let key: AVFoundationSegmentTrackKeyV4
    let naturalTimeScale: Int32
    let preferredTransform: [Double]
}

struct AVFoundationSegmentProbeV4: Sendable {
    func probe(url: URL) async throws -> AVFoundationSegmentIdentityV4 {
        try Self.validateRegularFile(url)
        let asset = AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let duration = try await asset.load(.duration)
        guard duration.isNumeric, duration.timescale > 0, duration.value > 0 else {
            throw AVFoundationSegmentV4Error.unreadableAsset("invalid duration")
        }
        let tracks = try await asset.load(.tracks)
        guard !tracks.isEmpty else {
            throw AVFoundationSegmentV4Error.unreadableAsset("no tracks")
        }

        let descriptors = try await makeTrackDescriptors(tracks)
        var identities: [AVFoundationSegmentTrackIdentityV4] = []
        identities.reserveCapacity(descriptors.count)
        for descriptor in descriptors {
            identities.append(try await scanTrack(
                descriptor.track,
                key: descriptor.key,
                asset: asset
            ))
        }
        let metadata = try await asset.load(.commonMetadata)
        let metadataHash = try await commonMetadataHash(metadata)
        return try AVFoundationSegmentIdentityV4(
            duration: try Self.workflowTime(duration),
            tracks: identities,
            commonMetadataSHA256: metadataHash
        )
    }

    private struct TrackDescriptor {
        let track: AVAssetTrack
        let key: AVFoundationSegmentTrackKeyV4
    }

    private func makeTrackDescriptors(
        _ tracks: [AVAssetTrack]
    ) async throws -> [TrackDescriptor] {
        struct Base: Comparable {
            let track: AVAssetTrack
            let mediaType: String
            let mediaSubType: UInt32
            let languageCode: String?
            let extendedLanguageTag: String?

            static func < (lhs: Self, rhs: Self) -> Bool {
                if lhs.mediaType != rhs.mediaType {
                    return lhs.mediaType < rhs.mediaType
                }
                if lhs.mediaSubType != rhs.mediaSubType {
                    return lhs.mediaSubType < rhs.mediaSubType
                }
                if lhs.languageCode != rhs.languageCode {
                    return (lhs.languageCode ?? "") < (rhs.languageCode ?? "")
                }
                if lhs.extendedLanguageTag != rhs.extendedLanguageTag {
                    return (lhs.extendedLanguageTag ?? "")
                        < (rhs.extendedLanguageTag ?? "")
                }
                return lhs.track.trackID < rhs.track.trackID
            }
        }

        var bases: [Base] = []
        bases.reserveCapacity(tracks.count)
        for track in tracks {
            let formats = try await track.load(.formatDescriptions)
            let mediaSubType = formats.first.map(CMFormatDescriptionGetMediaSubType)
                ?? 0
            bases.append(Base(
                track: track,
                mediaType: track.mediaType.rawValue,
                mediaSubType: mediaSubType,
                languageCode: try await track.load(.languageCode),
                extendedLanguageTag: try await track.load(.extendedLanguageTag)
            ))
        }
        bases.sort()
        var roleCounts: [String: Int] = [:]
        return bases.map { base in
            let role = [
                base.mediaType,
                String(base.mediaSubType),
                base.languageCode ?? "",
                base.extendedLanguageTag ?? ""
            ].joined(separator: "|")
            let ordinal = roleCounts[role, default: 0]
            roleCounts[role] = ordinal + 1
            return TrackDescriptor(
                track: base.track,
                key: AVFoundationSegmentTrackKeyV4(
                    mediaType: base.mediaType,
                    mediaSubType: base.mediaSubType,
                    languageCode: base.languageCode,
                    extendedLanguageTag: base.extendedLanguageTag,
                    roleOrdinal: ordinal
                )
            )
        }
    }

    private func scanTrack(
        _ track: AVAssetTrack,
        key: AVFoundationSegmentTrackKeyV4,
        asset: AVAsset
    ) async throws -> AVFoundationSegmentTrackIdentityV4 {
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw AVFoundationSegmentV4Error.unreadableAsset(
                String(describing: error)
            )
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw AVFoundationSegmentV4Error.unreadableAsset(
                "reader rejected track \(track.trackID)"
            )
        }
        reader.add(output)
        guard reader.startReading() else {
            throw AVFoundationSegmentV4Error.unreadableAsset(
                String(describing: reader.error)
            )
        }

        var payloadHasher = SHA256()
        var timingHasher = SHA256()
        var sampleCount: UInt64 = 0
        var firstPresentation: CMTime?
        var endPresentation = CMTime.zero
        var firstIsSync = false
        while let sample = output.copyNextSampleBuffer() {
            let presentation = CMSampleBufferGetPresentationTimeStamp(sample)
            let duration = CMSampleBufferGetDuration(sample)
            let decode = CMSampleBufferGetDecodeTimeStamp(sample)
            if sampleCount == 0, presentation.isNumeric {
                firstPresentation = presentation
                firstIsSync = Self.isSync(sample)
            } else if sampleCount == 0 {
                firstIsSync = Self.isSync(sample)
            }
            if presentation.isNumeric {
                let sampleEnd = duration.isNumeric && duration.value > 0
                    ? CMTimeAdd(presentation, duration)
                    : presentation
                if CMTimeCompare(sampleEnd, endPresentation) > 0 {
                    endPresentation = sampleEnd
                }
            }
            let payload = try Self.sampleData(sample)
            Self.updateLengthPrefixed(&payloadHasher, data: payload)
            Self.updateTiming(
                &timingHasher,
                presentation: presentation,
                decode: decode,
                duration: duration,
                isSync: Self.isSync(sample),
                payloadByteCount: payload.count
            )
            sampleCount += 1
        }
        guard reader.status == .completed else {
            throw AVFoundationSegmentV4Error.unreadableAsset(
                String(describing: reader.error)
            )
        }
        guard sampleCount > 0 else {
            throw AVFoundationSegmentV4Error.emptyTrack(track.trackID)
        }
        if track.mediaType == .video, !firstIsSync {
            throw AVFoundationSegmentV4Error.nonIndependentVideoTrack(
                track.trackID
            )
        }
        let transform = try await track.load(.preferredTransform)
        let naturalTimeScale = try await track.load(.naturalTimeScale)
        let trackRange = try await track.load(.timeRange)
        let resolvedFirstPresentation = firstPresentation
            ?? trackRange.start
        let resolvedEndPresentation = endPresentation.isNumeric
            && CMTimeCompare(endPresentation, resolvedFirstPresentation) >= 0
            ? endPresentation
            : trackRange.end
        guard resolvedFirstPresentation.isNumeric,
              resolvedFirstPresentation.timescale > 0,
              resolvedEndPresentation.isNumeric,
              resolvedEndPresentation.timescale > 0 else {
            throw AVFoundationSegmentV4Error.unreadableAsset(
                "track \(track.trackID) has no representable time range"
            )
        }
        return AVFoundationSegmentTrackIdentityV4(
            key: key,
            naturalTimeScale: naturalTimeScale,
            preferredTransform: [
                transform.a,
                transform.b,
                transform.c,
                transform.d,
                transform.tx,
                transform.ty
            ],
            sampleCount: sampleCount,
            payloadStreamSHA256: Self.hex(payloadHasher.finalize()),
            timingStreamSHA256: Self.hex(timingHasher.finalize()),
            firstPresentationTime: try Self.workflowTime(
                resolvedFirstPresentation
            ),
            endPresentationTimeExclusive: try Self.workflowTime(
                resolvedEndPresentation
            ),
            firstSampleIsSync: firstIsSync
        )
    }

    private func commonMetadataHash(
        _ items: [AVMetadataItem]
    ) async throws -> String {
        struct Entry: Codable {
            let identifier: String
            let keySpace: String
            let dataSHA256: String
            let stringSHA256: String
        }
        var entries: [Entry] = []
        entries.reserveCapacity(items.count)
        for item in items {
            let data = try await item.load(.dataValue) ?? Data()
            let string = try await item.load(.stringValue) ?? ""
            entries.append(Entry(
                identifier: item.identifier?.rawValue ?? "",
                keySpace: item.keySpace?.rawValue ?? "",
                dataSHA256: Self.hex(SHA256.hash(data: data)),
                stringSHA256: Self.hex(SHA256.hash(data: Data(string.utf8)))
            ))
        }
        entries.sort {
            if $0.identifier != $1.identifier {
                return $0.identifier < $1.identifier
            }
            if $0.keySpace != $1.keySpace { return $0.keySpace < $1.keySpace }
            if $0.dataSHA256 != $1.dataSHA256 {
                return $0.dataSHA256 < $1.dataSHA256
            }
            return $0.stringSHA256 < $1.stringSHA256
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return Self.hex(SHA256.hash(data: try encoder.encode(entries)))
    }

    private static func sampleData(_ sample: CMSampleBuffer) throws -> Data {
        guard let block = CMSampleBufferGetDataBuffer(sample) else {
            return Data()
        }
        let byteCount = CMBlockBufferGetDataLength(block)
        var data = Data(count: byteCount)
        let status = data.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { return OSStatus(-12700) }
            return CMBlockBufferCopyDataBytes(
                block,
                atOffset: 0,
                dataLength: byteCount,
                destination: base
            )
        }
        guard status == kCMBlockBufferNoErr else {
            throw AVFoundationSegmentV4Error.unreadableAsset(
                "sample payload copy failed with status \(status)"
            )
        }
        return data
    }

    private static func isSync(_ sample: CMSampleBuffer) -> Bool {
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

    private static func updateLengthPrefixed(
        _ hasher: inout SHA256,
        data: Data
    ) {
        var length = UInt64(data.count).bigEndian
        withUnsafeBytes(of: &length) { hasher.update(bufferPointer: $0) }
        hasher.update(data: data)
    }

    private static func updateTiming(
        _ hasher: inout SHA256,
        presentation: CMTime,
        decode: CMTime,
        duration: CMTime,
        isSync: Bool,
        payloadByteCount: Int
    ) {
        for value in [presentation, decode, duration] {
            var numericValue = value.value.bigEndian
            var timescale = value.timescale.bigEndian
            var flags = value.flags.rawValue.bigEndian
            var epoch = value.epoch.bigEndian
            withUnsafeBytes(of: &numericValue) { hasher.update(bufferPointer: $0) }
            withUnsafeBytes(of: &timescale) { hasher.update(bufferPointer: $0) }
            withUnsafeBytes(of: &flags) { hasher.update(bufferPointer: $0) }
            withUnsafeBytes(of: &epoch) { hasher.update(bufferPointer: $0) }
        }
        var sync: UInt8 = isSync ? 1 : 0
        var bytes = UInt64(payloadByteCount).bigEndian
        withUnsafeBytes(of: &sync) { hasher.update(bufferPointer: $0) }
        withUnsafeBytes(of: &bytes) { hasher.update(bufferPointer: $0) }
    }

    private static func workflowTime(
        _ time: CMTime
    ) throws -> WorkflowMediaTimeV4 {
        // AVFoundation's valid numeric timescales are positive Int32 values.
        // The coordinator contract permits up to one billion; common media
        // timescales fit directly. An out-of-contract value is normalized to
        // nanoseconds with round-toward-zero solely for identity reporting.
        if time.timescale > 0, time.timescale <= 1_000_000_000,
           let result = try? WorkflowMediaTimeV4(
               value: time.value,
               timescale: time.timescale
           ) {
            return result
        }
        let converted = CMTimeConvertScale(
            time,
            timescale: 1_000_000_000,
            method: .default
        )
        return try WorkflowMediaTimeV4(
            value: converted.value,
            timescale: converted.timescale
        )
    }

    private static func validateRegularFile(_ url: URL) throws {
        var value = stat()
        guard url.isFileURL,
              lstat(url.path, &value) == 0,
              (value.st_mode & S_IFMT) == S_IFREG,
              value.st_nlink == 1 else {
            throw AVFoundationSegmentV4Error.unsafeArtifact(url.path)
        }
    }

    private static func hex<D: Sequence>(_ digest: D) -> String
    where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

enum AVFoundationSegmentAssemblyPreservationV4: String, Codable, Hashable,
    Sendable {
    case trackPayloads = "track_payloads"
    case decodedVideoPayloads = "decoded_video_payloads"
    case exactSampleTiming = "exact_sample_timing"
    case commonMetadata = "common_metadata"
    case languageTags = "language_tags"
    case preferredTransforms = "preferred_transforms"
    case physicalTrackIDsNotPreserved = "physical_track_ids_not_preserved"
    case trackAssociationsNotRepresentable = "track_associations_not_representable"
    case mediaSelectionGroupsNotRepresentable = "media_selection_groups_not_representable"
    case containerBytesNotContractual = "container_bytes_not_contractual"
}

struct AVFoundationSegmentAssemblyRequestV4: @unchecked Sendable {
    let artifactRootURL: URL
    let segments: [WorkflowSegmentCheckpointV4]
    let mediaTimelineStart: WorkflowMediaTimeV4
    let outputTimelineStart: WorkflowMediaTimeV4
    let destinationURL: URL
    let outputFileType: AVFileType
    let overwriteExistingFile: Bool

    init(
        artifactRootURL: URL,
        segments: [WorkflowSegmentCheckpointV4],
        mediaTimelineStart: WorkflowMediaTimeV4,
        outputTimelineStart: WorkflowMediaTimeV4,
        destinationURL: URL,
        outputFileType: AVFileType = .mov,
        overwriteExistingFile: Bool = false
    ) {
        self.artifactRootURL = artifactRootURL
        self.segments = segments
        self.mediaTimelineStart = mediaTimelineStart
        self.outputTimelineStart = outputTimelineStart
        self.destinationURL = destinationURL
        self.outputFileType = outputFileType
        self.overwriteExistingFile = overwriteExistingFile
    }
}

struct AVFoundationTransientSegmentV4: Sendable {
    let url: URL
    let startTime: WorkflowMediaTimeV4
    let endTimeExclusive: WorkflowMediaTimeV4
    let codecSettingsHash: WorkflowOutputContractID
}

struct AVFoundationTransientSegmentAssemblyRequestV4: @unchecked Sendable {
    let trustedRootURL: URL
    let segments: [AVFoundationTransientSegmentV4]
    let mediaTimelineStart: WorkflowMediaTimeV4
    let outputTimelineStart: WorkflowMediaTimeV4
    let destinationURL: URL
    let outputFileType: AVFileType
    let overwriteExistingFile: Bool

    init(
        trustedRootURL: URL,
        segments: [AVFoundationTransientSegmentV4],
        mediaTimelineStart: WorkflowMediaTimeV4,
        outputTimelineStart: WorkflowMediaTimeV4,
        destinationURL: URL,
        outputFileType: AVFileType = .mov,
        overwriteExistingFile: Bool = false
    ) {
        self.trustedRootURL = trustedRootURL
        self.segments = segments
        self.mediaTimelineStart = mediaTimelineStart
        self.outputTimelineStart = outputTimelineStart
        self.destinationURL = destinationURL
        self.outputFileType = outputFileType
        self.overwriteExistingFile = overwriteExistingFile
    }
}

struct AVFoundationSegmentAssemblyResultV4: Equatable, Sendable {
    let destinationURL: URL
    let segmentCount: Int
    let outputIdentity: AVFoundationSegmentIdentityV4
    let outputFileSHA256: String
    let preservation: Set<AVFoundationSegmentAssemblyPreservationV4>
}

/// Container bytes are reported independently from the release-level media
/// equivalence contract. MOV atom ordering and exporter-authored bookkeeping
/// may differ across OS builds even when decoded payload, timing, layout, and
/// metadata are identical.
struct AVFoundationSegmentAssemblyEquivalenceV4: Equatable, Sendable {
    let semanticIdentityIsIdentical: Bool
    let containerBytesAreIdentical: Bool

    init(
        _ lhs: AVFoundationSegmentAssemblyResultV4,
        _ rhs: AVFoundationSegmentAssemblyResultV4
    ) {
        semanticIdentityIsIdentical = lhs.outputIdentity == rhs.outputIdentity
        containerBytesAreIdentical = lhs.outputFileSHA256
            == rhs.outputFileSHA256
    }
}

struct AVFoundationSegmentAssemblerV4: Sendable {
    func assemble(
        _ request: AVFoundationSegmentAssemblyRequestV4
    ) async throws -> AVFoundationSegmentAssemblyResultV4 {
        try Self.validateSequence(request.segments)
        let mediaTimelineStart = Self.cmTime(request.mediaTimelineStart)
        let outputTimelineStart = Self.cmTime(request.outputTimelineStart)
        guard mediaTimelineStart.isNumeric,
              outputTimelineStart.isNumeric,
              CMTimeCompare(mediaTimelineStart, .zero) >= 0,
              CMTimeCompare(outputTimelineStart, .zero) >= 0,
              !mediaTimelineStart.flags.contains(.hasBeenRounded),
              !outputTimelineStart.flags.contains(.hasBeenRounded),
              CMTimeCompare(
                mediaTimelineStart,
                Self.cmTime(request.segments[0].startTime)
              ) == 0 else {
            throw AVFoundationSegmentV4Error.invalidSegmentSequence
        }
        let artifactRoot = request.artifactRootURL.standardizedFileURL
            .resolvingSymlinksInPath()
        var assets: [AVURLAsset] = []
        var identities: [AVFoundationSegmentIdentityV4] = []
        var segmentURLs: [URL] = []
        for segment in request.segments {
            let verified = try await WorkflowSegmentCheckpointStoreV4
                .verifySegmentArtifact(
                    segment.artifact,
                    artifactRootURL: artifactRoot
                )
            let interval = try Self.subtract(
                segment.endTimeExclusive,
                segment.startTime
            )
            guard Self.covers(verified.identity.duration, interval) else {
                throw AVFoundationSegmentV4Error.segmentDurationMismatch(
                    ordinal: segment.ordinal
                )
            }
            if let first = identities.first,
               try first.layoutSHA256 != verified.identity.layoutSHA256 {
                throw AVFoundationSegmentV4Error.trackLayoutMismatch(
                    ordinal: segment.ordinal
                )
            }
            identities.append(verified.identity)
            segmentURLs.append(verified.url)
            assets.append(AVURLAsset(
                url: verified.url,
                options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
            ))
        }

        return try await assembleVerified(
            assets: assets,
            identities: identities,
            segmentURLs: segmentURLs,
            segments: request.segments,
            mediaTimelineStart: mediaTimelineStart,
            outputTimelineStart: outputTimelineStart,
            destinationURL: request.destinationURL,
            outputFileType: request.outputFileType,
            overwriteExistingFile: request.overwriteExistingFile
        )
    }

    func assembleTransient(
        _ request: AVFoundationTransientSegmentAssemblyRequestV4
    ) async throws -> AVFoundationSegmentAssemblyResultV4 {
        let trustedRoot = request.trustedRootURL.standardizedFileURL
            .resolvingSymlinksInPath()
        let rootPrefix = trustedRoot.path.hasSuffix("/")
            ? trustedRoot.path : trustedRoot.path + "/"
        guard !request.segments.isEmpty else {
            throw AVFoundationSegmentV4Error.emptySegmentSet
        }
        var assets: [AVURLAsset] = []
        var identities: [AVFoundationSegmentIdentityV4] = []
        var segmentURLs: [URL] = []
        var boundaries: [WorkflowSegmentCheckpointV4] = []
        for (index, segment) in request.segments.enumerated() {
            let resolved = segment.url.standardizedFileURL
                .resolvingSymlinksInPath()
            guard resolved.path.hasPrefix(rootPrefix) else {
                throw AVFoundationSegmentV4Error.unreadableAsset(
                    "transient segment escapes its trusted root"
                )
            }
            let identity = try await AVFoundationSegmentProbeV4().probe(
                url: resolved
            )
            let interval = try Self.subtract(
                segment.endTimeExclusive,
                segment.startTime
            )
            guard Self.covers(identity.duration, interval) else {
                throw AVFoundationSegmentV4Error.segmentDurationMismatch(
                    ordinal: UInt64(index)
                )
            }
            if let first = identities.first,
               try first.layoutSHA256 != identity.layoutSHA256 {
                throw AVFoundationSegmentV4Error.trackLayoutMismatch(
                    ordinal: UInt64(index)
                )
            }
            let rawIdentity = try WorkflowSegmentCheckpointStoreV4
                .rawFileIdentity(resolved)
            let rawSHA = try WorkflowCheckpointArtifactHashV4(
                rawIdentity.sha256
            )
            let artifact = try WorkflowCheckpointArtifactV4(
                artifactID: try WorkflowArtifactIDV4(
                    String(format: "direct-segment-%08d", index)
                ),
                kind: .segment,
                relativePath: resolved.lastPathComponent,
                byteCount: rawIdentity.byteCount,
                sha256: rawSHA,
                reopenReceiptSHA256: rawSHA
            )
            boundaries.append(try WorkflowSegmentCheckpointV4(
                ordinal: UInt64(index),
                artifact: artifact,
                startTime: segment.startTime,
                endTimeExclusive: segment.endTimeExclusive,
                nextStartTime: index + 1 < request.segments.count
                    ? request.segments[index + 1].startTime
                    : nil,
                codecSettingsHash: segment.codecSettingsHash,
                isIndependentlyDecodable: true
            ))
            identities.append(identity)
            segmentURLs.append(resolved)
            assets.append(AVURLAsset(
                url: resolved,
                options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
            ))
        }
        try Self.validateTransientSequence(boundaries)
        let mediaTimelineStart = Self.cmTime(request.mediaTimelineStart)
        let outputTimelineStart = Self.cmTime(request.outputTimelineStart)
        guard mediaTimelineStart.isNumeric,
              outputTimelineStart.isNumeric,
              CMTimeCompare(outputTimelineStart, .zero) >= 0,
              !mediaTimelineStart.flags.contains(.hasBeenRounded),
              !outputTimelineStart.flags.contains(.hasBeenRounded),
              CMTimeCompare(
                mediaTimelineStart,
                Self.cmTime(boundaries[0].startTime)
              ) == 0 else {
            throw AVFoundationSegmentV4Error.invalidSegmentSequence
        }
        return try await assembleVerified(
            assets: assets,
            identities: identities,
            segmentURLs: segmentURLs,
            segments: boundaries,
            mediaTimelineStart: mediaTimelineStart,
            outputTimelineStart: outputTimelineStart,
            destinationURL: request.destinationURL,
            outputFileType: request.outputFileType,
            overwriteExistingFile: request.overwriteExistingFile
        )
    }

    private func assembleVerified(
        assets: [AVURLAsset],
        identities: [AVFoundationSegmentIdentityV4],
        segmentURLs: [URL],
        segments: [WorkflowSegmentCheckpointV4],
        mediaTimelineStart: CMTime,
        outputTimelineStart: CMTime,
        destinationURL: URL,
        outputFileType: AVFileType,
        overwriteExistingFile: Bool
    ) async throws -> AVFoundationSegmentAssemblyResultV4 {
        let composition = AVMutableComposition()
        let firstTracks = try await assets[0].load(.tracks)
        let firstDescriptors = try await Self.descriptors(firstTracks)
        var compositionTracks: [
            AVFoundationSegmentTrackKeyV4: AVMutableCompositionTrack
        ] = [:]
        for descriptor in firstDescriptors {
            guard let target = composition.addMutableTrack(
                withMediaType: descriptor.track.mediaType,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                throw AVFoundationSegmentV4Error.unsupportedTrackLayout(
                    descriptor.key.mediaType
                )
            }
            target.preferredTransform = try await descriptor.track.load(
                .preferredTransform
            )
            target.naturalTimeScale = try await descriptor.track.load(
                .naturalTimeScale
            )
            target.languageCode = descriptor.key.languageCode
            target.extendedLanguageTag = descriptor.key.extendedLanguageTag
            compositionTracks[descriptor.key] = target
        }

        guard mediaTimelineStart.isNumeric,
              CMTimeCompare(
                mediaTimelineStart,
                Self.cmTime(segments[0].startTime)
              ) == 0 else {
            throw AVFoundationSegmentV4Error.invalidSegmentSequence
        }
        let origin = segments[0].startTime
        for index in assets.indices {
            let sourceTracks = try await assets[index].load(.tracks)
            let sourceDescriptors = try await Self.descriptors(sourceTracks)
            guard sourceDescriptors.map(\.key)
                    == firstDescriptors.map(\.key) else {
                throw AVFoundationSegmentV4Error.trackLayoutMismatch(
                    ordinal: segments[index].ordinal
                )
            }
            let insertionBase = CMTimeAdd(
                outputTimelineStart,
                try Self.cmTime(
                    Self.subtract(segments[index].startTime, origin)
                )
            )
            guard insertionBase.isNumeric,
                  !insertionBase.flags.contains(.hasBeenRounded) else {
                throw AVFoundationSegmentV4Error.invalidSegmentSequence
            }
            let declaredDuration = try Self.cmTime(Self.subtract(
                segments[index].endTimeExclusive,
                segments[index].startTime
            ))
            for descriptor in sourceDescriptors {
                guard let target = compositionTracks[descriptor.key] else {
                    throw AVFoundationSegmentV4Error.assembledLayoutMismatch
                }
                let sourceRange = try await descriptor.track.load(.timeRange)
                let relativeTrackStart = CMTimeMaximum(sourceRange.start, .zero)
                let remaining = CMTimeSubtract(
                    declaredDuration,
                    relativeTrackStart
                )
                guard remaining.isNumeric, remaining.value > 0 else {
                    throw AVFoundationSegmentV4Error.unsupportedTrackLayout(
                        "track begins beyond its declared segment boundary"
                    )
                }
                let zeroBasedAvailable = CMTimeRange(
                    start: sourceRange.start,
                    duration: CMTimeMinimum(sourceRange.duration, remaining)
                )
                try target.insertTimeRange(
                    zeroBasedAvailable,
                    of: descriptor.track,
                    at: CMTimeAdd(insertionBase, relativeTrackStart)
                )
            }
        }

        let destination = try AtomicOutputFile(
            finalURL: destinationURL,
            overwriteExistingFile: overwriteExistingFile
        )
        defer { destination.discard() }
        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            throw AVFoundationSegmentV4Error.exportUnavailable
        }
        exporter.metadata = try await assets[0].load(.commonMetadata)
        exporter.shouldOptimizeForNetworkUse = false
        let exportDuration = CMTimeAdd(
            outputTimelineStart,
            CMTimeSubtract(
                Self.cmTime(segments.last!.endTimeExclusive),
                Self.cmTime(segments.first!.startTime)
            )
        )
        guard exportDuration.isNumeric,
              exportDuration.value > 0,
              !exportDuration.flags.contains(.hasBeenRounded) else {
            throw AVFoundationSegmentV4Error.invalidSegmentSequence
        }
        exporter.timeRange = CMTimeRange(
            start: .zero,
            duration: exportDuration
        )
        do {
            try await exporter.export(
                to: destination.temporaryURL,
                as: outputFileType
            )
        } catch {
            throw AVFoundationSegmentV4Error.exportFailed(
                String(describing: error)
            )
        }
        let outputIdentity = try await AVFoundationSegmentProbeV4().probe(
            url: destination.temporaryURL
        )
        try Self.verifyAssembledIdentity(
            outputIdentity,
            from: identities,
            segments: segments,
            outputTimelineStart: outputTimelineStart
        )
        let elementaryPayloadsPreserved = try await Self.verifyAssembledStreams(
            outputURL: destination.temporaryURL,
            segmentURLs: segmentURLs,
            segments: segments,
            mediaTimelineStart: mediaTimelineStart
        )
        let outputSHA = try WorkflowSegmentCheckpointStoreV4.rawFileIdentity(
            destination.temporaryURL
        ).sha256
        try destination.publish()
        return AVFoundationSegmentAssemblyResultV4(
            destinationURL: destinationURL,
            segmentCount: segments.count,
            outputIdentity: outputIdentity,
            outputFileSHA256: outputSHA,
            preservation: [
                elementaryPayloadsPreserved
                    ? .trackPayloads : .decodedVideoPayloads,
                .exactSampleTiming,
                .commonMetadata,
                .languageTags,
                .preferredTransforms,
                .physicalTrackIDsNotPreserved,
                .trackAssociationsNotRepresentable,
                .mediaSelectionGroupsNotRepresentable,
                .containerBytesNotContractual
            ]
        )
    }

    private struct Descriptor {
        let track: AVAssetTrack
        let key: AVFoundationSegmentTrackKeyV4
    }

    private static func descriptors(
        _ tracks: [AVAssetTrack]
    ) async throws -> [Descriptor] {
        struct Base {
            let track: AVAssetTrack
            let mediaSubType: UInt32
            let languageCode: String?
            let extendedLanguageTag: String?
        }
        var bases: [Base] = []
        for track in tracks {
            let formats = try await track.load(.formatDescriptions)
            bases.append(Base(
                track: track,
                mediaSubType: formats.first.map(CMFormatDescriptionGetMediaSubType)
                    ?? 0,
                languageCode: try await track.load(.languageCode),
                extendedLanguageTag: try await track.load(.extendedLanguageTag)
            ))
        }
        bases.sort {
            let left = (
                $0.track.mediaType.rawValue,
                $0.mediaSubType,
                $0.languageCode ?? "",
                $0.extendedLanguageTag ?? "",
                $0.track.trackID
            )
            let right = (
                $1.track.mediaType.rawValue,
                $1.mediaSubType,
                $1.languageCode ?? "",
                $1.extendedLanguageTag ?? "",
                $1.track.trackID
            )
            return left < right
        }
        var roles: [String: Int] = [:]
        return bases.map { base in
            let role = [
                base.track.mediaType.rawValue,
                String(base.mediaSubType),
                base.languageCode ?? "",
                base.extendedLanguageTag ?? ""
            ].joined(separator: "|")
            let ordinal = roles[role, default: 0]
            roles[role] = ordinal + 1
            return Descriptor(
                track: base.track,
                key: AVFoundationSegmentTrackKeyV4(
                    mediaType: base.track.mediaType.rawValue,
                    mediaSubType: base.mediaSubType,
                    languageCode: base.languageCode,
                    extendedLanguageTag: base.extendedLanguageTag,
                    roleOrdinal: ordinal
                )
            )
        }
    }

    private static func validateSequence(
        _ segments: [WorkflowSegmentCheckpointV4]
    ) throws {
        guard !segments.isEmpty,
              segments.enumerated().allSatisfy({
                  $0.element.ordinal == UInt64($0.offset)
              }) else {
            throw AVFoundationSegmentV4Error.emptySegmentSet
        }
        for index in segments.indices.dropFirst() {
            let previous = segments[index - 1]
            let current = segments[index]
            guard previous.endTimeExclusive.timescale
                    == current.startTime.timescale,
                  previous.endTimeExclusive.value <= current.startTime.value,
                  previous.nextStartTime == current.startTime,
                  previous.codecSettingsHash
                    == segments[index].codecSettingsHash,
                  segments[index].isIndependentlyDecodable else {
                throw AVFoundationSegmentV4Error.invalidSegmentSequence
            }
        }
    }

    private static func validateTransientSequence(
        _ segments: [WorkflowSegmentCheckpointV4]
    ) throws {
        guard !segments.isEmpty,
              segments.enumerated().allSatisfy({
                  $0.element.ordinal == UInt64($0.offset)
                      && $0.element.isIndependentlyDecodable
              }) else {
            throw AVFoundationSegmentV4Error.emptySegmentSet
        }
        for index in segments.indices.dropFirst() {
            let previousEnd = cmTime(
                segments[index - 1].endTimeExclusive
            )
            let currentStart = cmTime(segments[index].startTime)
            guard CMTimeCompare(previousEnd, currentStart) <= 0,
                  segments[index - 1].nextStartTime
                    == segments[index].startTime,
                  segments[index - 1].codecSettingsHash
                    == segments[index].codecSettingsHash else {
                throw AVFoundationSegmentV4Error.invalidSegmentSequence
            }
        }
    }

    private static func subtract(
        _ lhs: WorkflowMediaTimeV4,
        _ rhs: WorkflowMediaTimeV4
    ) throws -> WorkflowMediaTimeV4 {
        let difference = CMTimeSubtract(cmTime(lhs), cmTime(rhs))
        guard difference.isNumeric,
              difference.value >= 0,
              !difference.flags.contains(.hasBeenRounded),
              difference.timescale > 0,
              difference.timescale <= 1_000_000_000 else {
            throw AVFoundationSegmentV4Error.invalidSegmentSequence
        }
        return try WorkflowMediaTimeV4(
            value: difference.value,
            timescale: difference.timescale
        )
    }

    private static func cmTime(_ time: WorkflowMediaTimeV4) -> CMTime {
        CMTime(value: time.value, timescale: time.timescale)
    }

    private static func covers(
        _ observed: WorkflowMediaTimeV4,
        _ required: WorkflowMediaTimeV4
    ) -> Bool {
        let observedTime = CMTime(
            value: observed.value,
            timescale: observed.timescale
        )
        let requiredTime = CMTime(
            value: required.value,
            timescale: required.timescale
        )
        return CMTimeCompare(observedTime, requiredTime) >= 0
    }

    private static func verifyAssembledIdentity(
        _ output: AVFoundationSegmentIdentityV4,
        from inputs: [AVFoundationSegmentIdentityV4],
        segments: [WorkflowSegmentCheckpointV4],
        outputTimelineStart: CMTime
    ) throws {
        guard let first = inputs.first,
              try output.layoutSHA256 == first.layoutSHA256,
              output.commonMetadataSHA256 == first.commonMetadataSHA256 else {
            throw AVFoundationSegmentV4Error.assembledLayoutMismatch
        }
        let inputByKey = Dictionary(grouping: inputs.flatMap(\.tracks), by: \.key)
        guard Set(output.tracks.map(\.key)) == Set(inputByKey.keys) else {
            throw AVFoundationSegmentV4Error.assembledLayoutMismatch
        }
        for track in output.tracks {
            guard let pieces = inputByKey[track.key] else {
                throw AVFoundationSegmentV4Error.assembledLayoutMismatch
            }
            if track.key.mediaType != AVMediaType.video.rawValue,
               pieces.reduce(UInt64(0), { $0 + $1.sampleCount })
                != track.sampleCount {
                throw AVFoundationSegmentV4Error.assembledDecodedPayloadMismatch(
                    "non-video compressed sample count changed"
                )
            }
        }
        let expectedDuration = CMTimeAdd(
            outputTimelineStart,
            CMTimeSubtract(
                cmTime(segments.last!.endTimeExclusive),
                cmTime(segments.first!.startTime)
            )
        )
        let outputDuration = CMTime(
            value: output.duration.value,
            timescale: output.duration.timescale
        )
        guard CMTimeCompare(outputDuration, expectedDuration) == 0 else {
            throw AVFoundationSegmentV4Error.assembledTimingMismatch
        }
    }

    /// Verifies the actual elementary stream in constant memory. This is
    /// stronger than comparing summary hashes: every compressed payload,
    /// timestamp, duration, decode timestamp, and sync flag must survive the
    /// passthrough composition in the same order.
    private static func verifyAssembledStreams(
        outputURL: URL,
        segmentURLs: [URL],
        segments: [WorkflowSegmentCheckpointV4],
        mediaTimelineStart: CMTime
    ) async throws -> Bool {
        let outputAsset = AVURLAsset(
            url: outputURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let outputDescriptors = try await descriptors(
            outputAsset.load(.tracks)
        )
        var allElementaryPayloadsPreserved = true
        for outputDescriptor in outputDescriptors {
            do {
                try await verifyExactTrackStream(
                    outputDescriptor: outputDescriptor,
                    outputAsset: outputAsset,
                    segmentURLs: segmentURLs,
                    segments: segments,
                    mediaTimelineStart: mediaTimelineStart
                )
                continue
            } catch AVFoundationSegmentV4Error.assembledPayloadMismatch
                where outputDescriptor.track.mediaType == .video {
                allElementaryPayloadsPreserved = false
                try await verifyDecodedVideoStream(
                    outputDescriptor: outputDescriptor,
                    outputAsset: outputAsset,
                    segmentURLs: segmentURLs,
                    segments: segments,
                    mediaTimelineStart: mediaTimelineStart
                )
            }
        }
        return allElementaryPayloadsPreserved
    }

    private static func verifyExactTrackStream(
        outputDescriptor: Descriptor,
        outputAsset: AVURLAsset,
        segmentURLs: [URL],
        segments: [WorkflowSegmentCheckpointV4],
        mediaTimelineStart: CMTime
    ) async throws {
            let outputReader = try AVAssetReader(asset: outputAsset)
            let output = AVAssetReaderTrackOutput(
                track: outputDescriptor.track,
                outputSettings: nil
            )
            output.alwaysCopiesSampleData = false
            guard outputReader.canAdd(output) else {
                throw AVFoundationSegmentV4Error.assembledLayoutMismatch
            }
            outputReader.add(output)
            guard outputReader.startReading() else {
                throw AVFoundationSegmentV4Error.exportFailed(
                    String(describing: outputReader.error)
                )
            }
            for index in segmentURLs.indices {
                let sourceAsset = AVURLAsset(
                    url: segmentURLs[index],
                    options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
                )
                let sourceDescriptors = try await descriptors(
                    sourceAsset.load(.tracks)
                )
                guard let sourceDescriptor = sourceDescriptors.first(where: {
                    $0.key == outputDescriptor.key
                }) else {
                    throw AVFoundationSegmentV4Error.assembledLayoutMismatch
                }
                let sourceReader = try AVAssetReader(asset: sourceAsset)
                sourceReader.timeRange = CMTimeRange(
                    start: .zero,
                    duration: CMTime(
                        value: segments[index].endTimeExclusive.value
                            - segments[index].startTime.value,
                        timescale: segments[index].startTime.timescale
                    )
                )
                let source = AVAssetReaderTrackOutput(
                    track: sourceDescriptor.track,
                    outputSettings: nil
                )
                source.alwaysCopiesSampleData = false
                guard sourceReader.canAdd(source) else {
                    throw AVFoundationSegmentV4Error.assembledLayoutMismatch
                }
                sourceReader.add(source)
                guard sourceReader.startReading() else {
                    throw AVFoundationSegmentV4Error.unreadableAsset(
                        String(describing: sourceReader.error)
                    )
                }
                let offset = CMTimeSubtract(
                    cmTime(segments[index].startTime),
                    mediaTimelineStart
                )
                while let sourceSample = source.copyNextSampleBuffer() {
                    guard let outputSample = output.copyNextSampleBuffer() else {
                        throw AVFoundationSegmentV4Error.assembledPayloadMismatch
                    }
                    guard try sampleData(sourceSample) == sampleData(outputSample),
                          isSync(sourceSample) == isSync(outputSample) else {
                        throw AVFoundationSegmentV4Error.assembledPayloadMismatch
                    }
                    guard shiftedTimeEquals(
                        CMSampleBufferGetPresentationTimeStamp(sourceSample),
                        CMSampleBufferGetPresentationTimeStamp(outputSample),
                        offset: offset
                    ), shiftedTimeEquals(
                        CMSampleBufferGetDecodeTimeStamp(sourceSample),
                        CMSampleBufferGetDecodeTimeStamp(outputSample),
                        offset: offset
                    ), CMTimeCompare(
                        CMSampleBufferGetDuration(sourceSample),
                        CMSampleBufferGetDuration(outputSample)
                    ) == 0 else {
                        throw AVFoundationSegmentV4Error.assembledTimingMismatch
                    }
                }
                guard sourceReader.status == .completed else {
                    throw AVFoundationSegmentV4Error.unreadableAsset(
                        String(describing: sourceReader.error)
                    )
                }
            }
            guard output.copyNextSampleBuffer() == nil,
                  outputReader.status == .completed else {
                throw AVFoundationSegmentV4Error.assembledPayloadMismatch
            }
    }

    private static func verifyDecodedVideoStream(
        outputDescriptor: Descriptor,
        outputAsset: AVURLAsset,
        segmentURLs: [URL],
        segments: [WorkflowSegmentCheckpointV4],
        mediaTimelineStart: CMTime
    ) async throws {
        let outputReader = try AVAssetReader(asset: outputAsset)
        let output = AVAssetReaderTrackOutput(
            track: outputDescriptor.track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_64ARGB
            ]
        )
        guard outputReader.canAdd(output) else {
            throw AVFoundationSegmentV4Error.assembledDecodedPayloadMismatch(
                "output reader rejected video track"
            )
        }
        outputReader.add(output)
        guard outputReader.startReading() else {
            throw AVFoundationSegmentV4Error.assembledDecodedPayloadMismatch(
                "output reader failed to start"
            )
        }
        for index in segmentURLs.indices {
            let sourceAsset = AVURLAsset(
                url: segmentURLs[index],
                options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
            )
            let sourceDescriptors = try await descriptors(
                sourceAsset.load(.tracks)
            )
            guard let sourceDescriptor = sourceDescriptors.first(where: {
                $0.key == outputDescriptor.key
            }) else {
                throw AVFoundationSegmentV4Error.assembledLayoutMismatch
            }
            let sourceReader = try AVAssetReader(asset: sourceAsset)
            sourceReader.timeRange = CMTimeRange(
                start: .zero,
                duration: CMTime(
                    value: segments[index].endTimeExclusive.value
                        - segments[index].startTime.value,
                    timescale: segments[index].startTime.timescale
                )
            )
            let source = AVAssetReaderTrackOutput(
                track: sourceDescriptor.track,
                outputSettings: [
                    kCVPixelBufferPixelFormatTypeKey as String:
                        kCVPixelFormatType_64ARGB
                ]
            )
            guard sourceReader.canAdd(source) else {
                throw AVFoundationSegmentV4Error.assembledDecodedPayloadMismatch(
                    "source reader rejected segment \(index)"
                )
            }
            sourceReader.add(source)
            guard sourceReader.startReading() else {
                throw AVFoundationSegmentV4Error.assembledDecodedPayloadMismatch(
                    "source reader failed to start for segment \(index)"
                )
            }
            let offset = CMTimeSubtract(
                cmTime(segments[index].startTime),
                mediaTimelineStart
            )
            while let sourceSample = source.copyNextSampleBuffer() {
                guard let outputSample = output.copyNextSampleBuffer(),
                      try decodedPixelData(sourceSample)
                        == decodedPixelData(outputSample) else {
                    throw AVFoundationSegmentV4Error.assembledDecodedPayloadMismatch(
                        "pixel or sample-count mismatch in segment \(index)"
                    )
                }
                guard shiftedTimeEquals(
                    CMSampleBufferGetPresentationTimeStamp(sourceSample),
                    CMSampleBufferGetPresentationTimeStamp(outputSample),
                    offset: offset
                ), CMTimeCompare(
                    CMSampleBufferGetDuration(sourceSample),
                    CMSampleBufferGetDuration(outputSample)
                ) == 0 else {
                    throw AVFoundationSegmentV4Error.assembledTimingMismatch
                }
            }
            guard sourceReader.status == .completed else {
                throw AVFoundationSegmentV4Error.assembledDecodedPayloadMismatch(
                    "source decode failed for segment \(index)"
                )
            }
        }
        guard output.copyNextSampleBuffer() == nil,
              outputReader.status == .completed else {
            throw AVFoundationSegmentV4Error.assembledDecodedPayloadMismatch(
                "assembled output has trailing or unreadable frames"
            )
        }
    }

    private static func decodedPixelData(
        _ sample: CMSampleBuffer
    ) throws -> Data {
        guard let image = CMSampleBufferGetImageBuffer(sample) else {
            throw AVFoundationSegmentV4Error.assembledDecodedPayloadMismatch(
                "decoder returned no image buffer"
            )
        }
        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        guard CVPixelBufferGetPlaneCount(image) == 0,
              let base = CVPixelBufferGetBaseAddress(image) else {
            throw AVFoundationSegmentV4Error.assembledDecodedPayloadMismatch(
                "decoder returned an unsupported image layout"
            )
        }
        let widthBytes = CVPixelBufferGetWidth(image) * 8
        let height = CVPixelBufferGetHeight(image)
        let stride = CVPixelBufferGetBytesPerRow(image)
        var result = Data()
        result.reserveCapacity(widthBytes * height)
        for row in 0 ..< height {
            result.append(
                base.advanced(by: row * stride)
                    .assumingMemoryBound(to: UInt8.self),
                count: widthBytes
            )
        }
        return result
    }

    private static func sampleData(_ sample: CMSampleBuffer) throws -> Data {
        guard let block = CMSampleBufferGetDataBuffer(sample) else {
            return Data()
        }
        let byteCount = CMBlockBufferGetDataLength(block)
        if byteCount == 0 { return Data() }
        var data = Data(count: byteCount)
        let status = data.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { return OSStatus(-12700) }
            return CMBlockBufferCopyDataBytes(
                block,
                atOffset: 0,
                dataLength: byteCount,
                destination: base
            )
        }
        guard status == kCMBlockBufferNoErr else {
            throw AVFoundationSegmentV4Error.assembledPayloadMismatch
        }
        return data
    }

    private static func isSync(_ sample: CMSampleBuffer) -> Bool {
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

    private static func shiftedTimeEquals(
        _ source: CMTime,
        _ output: CMTime,
        offset: CMTime
    ) -> Bool {
        if !source.isNumeric || !output.isNumeric {
            return source == output
        }
        return CMTimeCompare(CMTimeAdd(source, offset), output) == 0
    }
}
