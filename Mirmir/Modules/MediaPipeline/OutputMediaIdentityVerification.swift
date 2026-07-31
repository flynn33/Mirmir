import AVFoundation
import CoreMedia
import CoreVideo
import CryptoKit
import Foundation

enum MediaPreservationIdentityError: Error, CustomStringConvertible {
    case unsupportedMetadataValue(String)
    case duplicateTrackID(CMPersistentTrackID)
    case sampleIdentityFailed(mediaType: String, reason: String)
    case missingAssociationTarget(
        associationType: String,
        sourceMediaType: String,
        targetMediaType: String
    )
    case disabledAssociationTarget(
        associationType: String,
        sourceMediaType: String,
        targetMediaType: String,
        requiredAction: String
    )

    var description: String {
        switch self {
        case .unsupportedMetadataValue(let description):
            return "unsupported metadata value \(description)"
        case .duplicateTrackID(let trackID):
            return "duplicate source track ID \(trackID)"
        case .sampleIdentityFailed(let mediaType, let reason):
            return "\(mediaType) sample identity failed: \(reason)"
        case .missingAssociationTarget(
            let associationType,
            let sourceMediaType,
            let targetMediaType
        ):
            return "\(sourceMediaType) association \(associationType) "
                + "targets unpreserved \(targetMediaType)"
        case .disabledAssociationTarget(
            let associationType,
            let sourceMediaType,
            let targetMediaType,
            let requiredAction
        ):
            return "\(sourceMediaType) association \(associationType) "
                + "requires \(targetMediaType) target preservation. "
                + requiredAction
        }
    }
}

enum MediaPreservationMetadataIdentityReader {
    static func read(
        _ items: [AVMetadataItem]
    ) async throws -> OutputMediaMetadataIdentity {
        var canonicalItems: [Data] = []
        canonicalItems.reserveCapacity(items.count)
        for item in items {
            canonicalItems.append(try await canonicalItem(item))
        }
        canonicalItems.sort { lhs, rhs in
            lhs.lexicographicallyPrecedes(rhs)
        }
        return OutputMediaMetadataIdentity(
            canonicalItems: canonicalItems
        )
    }

    private static func canonicalItem(
        _ item: AVMetadataItem
    ) async throws -> Data {
        let value = try await item.load(.value)
        let extraAttributes = try await item.load(.extraAttributes)
        var fields: [String: Any] = [
            "time": exactTimeDescription(item.time),
            "duration": exactTimeDescription(item.duration)
        ]
        if let identifier = item.identifier {
            fields["identifier"] = identifier.rawValue
        }
        if let keySpace = item.keySpace {
            fields["key_space"] = keySpace.rawValue
        }
        if let commonKey = item.commonKey {
            fields["common_key"] = commonKey.rawValue
        }
        if let key = item.key {
            fields["key"] = key
        }
        if let extendedLanguageTag = item.extendedLanguageTag {
            fields["extended_language_tag"] = extendedLanguageTag
        }
        if let locale = item.locale {
            fields["locale"] = locale.identifier
        }
        if let startDate = item.startDate {
            fields["start_date"] = startDate
        }
        if let dataType = item.dataType {
            fields["data_type"] = dataType
        }
        if let value {
            fields["value"] = value
        }
        if let extraAttributes {
            fields["extra_attributes"] = extraAttributes
        }
        return try MediaPreservationCanonicalEncoder.encode(fields)
    }

    private static func exactTimeDescription(_ time: CMTime) -> String {
        "value=\(time.value),timescale=\(time.timescale),"
            + "flags=\(time.flags.rawValue),epoch=\(time.epoch)"
    }
}

private enum MediaPreservationCanonicalEncoder {
    static func encode(_ value: Any) throws -> Data {
        var result = Data()
        try append(value, to: &result)
        return result
    }

    private static func append(
        _ value: Any,
        to data: inout Data
    ) throws {
        if value is NSNull {
            appendTag(0, to: &data)
            return
        }
        if let string = value as? String {
            appendTag(1, to: &data)
            appendData(Data(string.utf8), to: &data)
            return
        }
        if let rawData = value as? Data {
            appendTag(2, to: &data)
            appendData(rawData, to: &data)
            return
        }
        if let date = value as? Date {
            appendTag(3, to: &data)
            appendUInt64(
                date.timeIntervalSinceReferenceDate.bitPattern,
                to: &data
            )
            return
        }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                appendTag(number.boolValue ? 5 : 4, to: &data)
                return
            }
            appendTag(6, to: &data)
            appendData(
                Data(String(cString: number.objCType).utf8),
                to: &data
            )
            appendData(Data(number.stringValue.utf8), to: &data)
            return
        }
        if let array = value as? NSArray {
            appendTag(7, to: &data)
            appendUInt64(UInt64(array.count), to: &data)
            for element in array {
                try append(element, to: &data)
            }
            return
        }
        if let dictionary = value as? NSDictionary {
            appendTag(8, to: &data)
            var encodedEntries: [(key: Data, value: Data)] = []
            encodedEntries.reserveCapacity(dictionary.count)
            for (key, value) in dictionary {
                encodedEntries.append((
                    key: try encode(key),
                    value: try encode(value)
                ))
            }
            encodedEntries.sort { lhs, rhs in
                if lhs.key == rhs.key {
                    return lhs.value.lexicographicallyPrecedes(rhs.value)
                }
                return lhs.key.lexicographicallyPrecedes(rhs.key)
            }
            appendUInt64(UInt64(encodedEntries.count), to: &data)
            for entry in encodedEntries {
                appendData(entry.key, to: &data)
                appendData(entry.value, to: &data)
            }
            return
        }
        if let url = value as? URL {
            appendTag(9, to: &data)
            appendData(Data(url.absoluteString.utf8), to: &data)
            return
        }
        throw MediaPreservationIdentityError.unsupportedMetadataValue(
            String(reflecting: type(of: value))
        )
    }

    private static func appendTag(
        _ tag: UInt8,
        to data: inout Data
    ) {
        data.append(tag)
    }

    private static func appendData(
        _ value: Data,
        to data: inout Data
    ) {
        appendUInt64(UInt64(value.count), to: &data)
        data.append(value)
    }

    private static func appendUInt64(
        _ value: UInt64,
        to data: inout Data
    ) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { bytes in
            data.append(contentsOf: bytes)
        }
    }
}

private final class MediaPreservationReaderCancellation:
    @unchecked Sendable {
    private let reader: AVAssetReader

    init(reader: AVAssetReader) {
        self.reader = reader
    }

    func cancel() {
        reader.cancelReading()
    }
}

enum MediaPreservationTrackSampleIdentityReader {
    static func read(
        asset: AVURLAsset,
        track: AVAssetTrack,
        cancellationCheck: @escaping @Sendable () throws -> Void
    ) async throws -> OutputMediaTrackSampleIdentity {
        let mediaType = track.mediaType.rawValue
        let reader: AVAssetReader
        do {
            try cancellationCheck()
            reader = try AVAssetReader(asset: asset)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw failure(
                mediaType,
                "reader creation failed: \(error)"
            )
        }
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: nil
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw failure(
                mediaType,
                "reader rejected compressed sample-copy output"
            )
        }
        reader.add(output)
        guard reader.startReading() else {
            throw failure(
                mediaType,
                reader.error.map {
                    "reader did not start: \($0)"
                } ?? "reader did not start"
            )
        }

        let cancellation = MediaPreservationReaderCancellation(
            reader: reader
        )
        return try await withTaskCancellationHandler {
            do {
                var hasher = CanonicalSampleHasher(
                    mediaType: mediaType
                )
                var sampleCount = 0
                var totalPayloadByteCount: Int64 = 0
                while true {
                    try cancellationCheck()
                    guard let sampleBuffer =
                            output.copyNextSampleBuffer() else {
                        break
                    }
                    let containedSampleCount =
                        CMSampleBufferGetNumSamples(sampleBuffer)
                    guard containedSampleCount > 0 else {
                        continue
                    }
                    let (nextCount, countOverflowed) =
                        sampleCount.addingReportingOverflow(
                            containedSampleCount
                        )
                    guard !countOverflowed else {
                        throw failure(
                            mediaType,
                            "sample count overflowed"
                        )
                    }
                    let blockBuffer =
                        CMSampleBufferGetDataBuffer(sampleBuffer)
                    let blockLength = blockBuffer.map(
                        CMBlockBufferGetDataLength
                    ) ?? 0
                    var payloadOffset = 0
                    for containedIndex in 0..<containedSampleCount {
                        try cancellationCheck()
                        var timing = CMSampleTimingInfo()
                        let timingStatus =
                            CMSampleBufferGetSampleTimingInfo(
                                sampleBuffer,
                                at: containedIndex,
                                timingInfoOut: &timing
                            )
                        guard timingStatus == noErr else {
                            throw failure(
                                mediaType,
                                "sample \(sampleCount + containedIndex) "
                                    + "timing read failed: "
                                    + "\(timingStatus)"
                            )
                        }
                        let payloadSize =
                            CMSampleBufferGetSampleSize(
                                sampleBuffer,
                                at: containedIndex
                            )
                        guard payloadSize >= 0 else {
                            throw failure(
                                mediaType,
                                "sample \(sampleCount + containedIndex) "
                                    + "reported a negative payload size"
                            )
                        }
                        let (nextOffset, offsetOverflowed) =
                            payloadOffset.addingReportingOverflow(
                                payloadSize
                            )
                        guard !offsetOverflowed,
                              nextOffset <= blockLength else {
                            throw failure(
                                mediaType,
                                "sample payload partition exceeds its "
                                    + "block buffer"
                            )
                        }
                        let payload: Data
                        if payloadSize == 0 {
                            payload = Data()
                        } else {
                            guard let blockBuffer else {
                                throw failure(
                                    mediaType,
                                    "sample \(sampleCount + containedIndex) "
                                        + "has no block buffer"
                                )
                            }
                            var copiedPayload = Data(
                                count: payloadSize
                            )
                            let payloadStatus: OSStatus =
                                copiedPayload.withUnsafeMutableBytes {
                                    bytes in
                                    guard let destination =
                                            bytes.baseAddress else {
                                        return kCMBlockBufferBadPointerParameterErr
                                    }
                                    return CMBlockBufferCopyDataBytes(
                                        blockBuffer,
                                        atOffset: payloadOffset,
                                        dataLength: payloadSize,
                                        destination: destination
                                    )
                                }
                            guard payloadStatus
                                    == kCMBlockBufferNoErr else {
                                throw failure(
                                    mediaType,
                                    "sample "
                                        + "\(sampleCount + containedIndex) "
                                        + "payload copy failed: "
                                        + "\(payloadStatus)"
                                )
                            }
                            payload = copiedPayload
                        }
                        let (nextByteCount, byteCountOverflowed) =
                            totalPayloadByteCount
                            .addingReportingOverflow(
                                Int64(payloadSize)
                            )
                        guard !byteCountOverflowed else {
                            throw failure(
                                mediaType,
                                "payload byte count overflowed"
                            )
                        }
                        hasher.append(
                            timing: timing,
                            payload: payload,
                            index: sampleCount + containedIndex
                        )
                        totalPayloadByteCount = nextByteCount
                        payloadOffset = nextOffset
                    }
                    guard payloadOffset == blockLength else {
                        throw failure(
                            mediaType,
                            "sample payload partition is "
                                + "\(payloadOffset) bytes; block buffer "
                                + "contains \(blockLength) bytes"
                        )
                    }
                    sampleCount = nextCount
                }
                try cancellationCheck()
                guard reader.status == .completed else {
                    throw failure(
                        mediaType,
                        reader.error.map {
                            "reader failed: \($0)"
                        } ?? "reader status \(reader.status.rawValue)"
                    )
                }
                return OutputMediaTrackSampleIdentity(
                    sampleCount: sampleCount,
                    totalPayloadByteCount: totalPayloadByteCount,
                    canonicalSHA256: hasher.finalize(
                        sampleCount: sampleCount
                    )
                )
            } catch is CancellationError {
                cancellation.cancel()
                throw CancellationError()
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func failure(
        _ mediaType: String,
        _ reason: String
    ) -> MediaPreservationIdentityError {
        .sampleIdentityFailed(
            mediaType: mediaType,
            reason: reason
        )
    }

    private struct CanonicalSampleHasher {
        private var hasher = SHA256()

        init(mediaType: String) {
            append(Data(
                "MirmirMediaTrackSampleIdentity/v1".utf8
            ))
            append(UInt64(mediaType.utf8.count))
            append(Data(mediaType.utf8))
        }

        mutating func append(
            timing: CMSampleTimingInfo,
            payload: Data,
            index: Int
        ) {
            append(UInt64(index))
            append(timing.presentationTimeStamp)
            append(timing.decodeTimeStamp)
            append(timing.duration)
            append(UInt64(payload.count))
            append(payload)
        }

        mutating func finalize(sampleCount: Int) -> String {
            append(UInt64(sampleCount))
            return hasher.finalize()
                .map { String(format: "%02x", $0) }
                .joined()
        }

        private mutating func append(_ time: CMTime) {
            guard time.isValid else {
                append(UInt8(0))
                return
            }
            if time.isPositiveInfinity {
                append(UInt8(1))
            } else if time.isNegativeInfinity {
                append(UInt8(2))
            } else if time.isIndefinite {
                append(UInt8(3))
            } else if time.isNumeric, time.timescale > 0 {
                append(UInt8(4))
                let divisor = semanticTimeDivisor(
                    value: time.value,
                    timescale: time.timescale
                )
                append(time.value / divisor)
                append(UInt32(Int64(time.timescale) / divisor))
            } else {
                append(UInt8(5))
                append(UInt64(bitPattern: time.value))
                append(UInt32(bitPattern: time.timescale))
                append(time.flags.rawValue)
            }
            append(UInt64(bitPattern: time.epoch))
        }

        private mutating func append<T: FixedWidthInteger>(
            _ value: T
        ) {
            var bigEndian = value.bigEndian
            withUnsafeBytes(of: &bigEndian) { bytes in
                hasher.update(bufferPointer: bytes)
            }
        }

        private mutating func append(_ data: Data) {
            hasher.update(data: data)
        }

        private func semanticTimeDivisor(
            value: Int64,
            timescale: CMTimeScale
        ) -> Int64 {
            let denominator = Int64(timescale)
            var lhs = denominator
            var rhs = value % denominator
            if rhs < 0 {
                rhs = -rhs
            }
            while rhs != 0 {
                let remainder = lhs % rhs
                lhs = rhs
                rhs = remainder
            }
            return lhs
        }
    }
}

struct SourceMediaAssociationTargetSelection: Sendable, Equatable {
    static let all = SourceMediaAssociationTargetSelection(
        preserveAudio: true,
        preserveSubtitles: true,
        preserveMetadata: true
    )

    let preserveAudio: Bool
    let preserveSubtitles: Bool
    let preserveMetadata: Bool

    func disabledAction(for mediaType: AVMediaType) -> String? {
        switch mediaType {
        case .audio:
            return preserveAudio
                ? nil
                : "Enable Preserve Source Audio Tracks."
        case .subtitle, .text, .closedCaption:
            return preserveSubtitles
                ? nil
                : "Enable source subtitle and caption preservation."
        case .metadata, .timecode:
            return preserveMetadata
                ? nil
                : "Enable source metadata and timecode preservation."
        default:
            return nil
        }
    }
}

enum SourceMediaPreservationPlanner {
    static let preservedMediaTypes: [AVMediaType] = [
        .video,
        .audio,
        .subtitle,
        .text,
        .closedCaption,
        .metadata,
        .timecode
    ]

    static func make(
        asset: AVURLAsset,
        selectedTracks: [AVAssetTrack],
        preserveMetadata: Bool,
        associationTargetSelection:
            SourceMediaAssociationTargetSelection = .all
    ) async throws -> SourceMediaPreservationPlan {
        let preservationTracks = try await includingAssociationTargets(
            selectedTracks,
            selection: associationTargetSelection
        )
        let containerMetadata = preserveMetadata
            ? try await asset.load(.metadata)
            : []
        let containerIdentity =
            try await MediaPreservationMetadataIdentityReader.read(
                containerMetadata
            )
        var nextOrdinalByMediaType: [String: Int] = [:]
        var trackReferenceByID:
            [CMPersistentTrackID: OutputMediaTrackReference] = [:]
        var trackPlans: [SourceMediaTrackPreservationPlan] = []
        trackPlans.reserveCapacity(preservationTracks.count)

        for track in preservationTracks {
            let mediaType = track.mediaType.rawValue
            let ordinal = nextOrdinalByMediaType[mediaType, default: 0]
            nextOrdinalByMediaType[mediaType] = ordinal + 1
            let reference = OutputMediaTrackReference(
                mediaType: mediaType,
                ordinal: ordinal
            )
            guard trackReferenceByID.updateValue(
                reference,
                forKey: track.trackID
            ) == nil else {
                throw MediaPreservationIdentityError.duplicateTrackID(
                    track.trackID
                )
            }

            trackPlans.append(
                try await makeTrackPlan(
                    asset: asset,
                    track: track,
                    reference: reference,
                    preserveMetadata: preserveMetadata
                )
            )
        }

        var associations: [OutputMediaTrackAssociationExpectation] = []
        for plan in trackPlans {
            let associationTypes = try await plan.track.load(
                .availableTrackAssociationTypes
            )
            for associationType in associationTypes {
                let targets = try await plan.track.loadAssociatedTracks(
                    ofType: associationType
                )
                for target in targets {
                    guard let targetReference =
                            trackReferenceByID[target.trackID] else {
                        throw MediaPreservationIdentityError
                            .missingAssociationTarget(
                                associationType: associationType.rawValue,
                                sourceMediaType:
                                    plan.track.mediaType.rawValue,
                                targetMediaType:
                                    target.mediaType.rawValue
                            )
                    }
                    associations.append(
                        OutputMediaTrackAssociationExpectation(
                            source: plan.expectation.reference,
                            target: targetReference,
                            associationType: associationType.rawValue
                        )
                    )
                }
            }
        }
        associations.sort(by: associationSort)

        var expectedTrackCounts: [String: Int] = [:]
        for mediaType in preservedMediaTypes {
            expectedTrackCounts[mediaType.rawValue] =
                nextOrdinalByMediaType[mediaType.rawValue, default: 0]
        }
        for (mediaType, count) in nextOrdinalByMediaType {
            expectedTrackCounts[mediaType] = count
        }
        let expectation = OutputMediaPreservationExpectation(
            containerMetadata: containerIdentity,
            tracks: trackPlans.map(\.expectation),
            associations: associations,
            expectedTrackCounts: expectedTrackCounts
        )
        return SourceMediaPreservationPlan(
            containerMetadata: containerMetadata,
            tracks: trackPlans,
            associations: associations,
            expectation: expectation
        )
    }

    private static func makeTrackPlan(
        asset: AVURLAsset,
        track: AVAssetTrack,
        reference: OutputMediaTrackReference,
        preserveMetadata: Bool
    ) async throws -> SourceMediaTrackPreservationPlan {
        let timeRange = try await track.load(.timeRange)
        try AVFoundationSourceTimelinePreflight.validate(
            timeRange,
            mediaType: track.mediaType
        )
        let naturalTimeScale = try await track.load(.naturalTimeScale)
        let exactTimeScale = try ExactVideoWriterTimeScale.resolve(
            naturalTimeScale: naturalTimeScale,
            trackTimeRange: timeRange
        )
        let formatDescriptions = try await track.load(
            .formatDescriptions
        )
        let metadata = preserveMetadata
            ? try await track.load(.metadata)
            : []
        let metadataIdentity =
            try await MediaPreservationMetadataIdentityReader.read(
                metadata
            )
        let sampleIdentity: OutputMediaTrackSampleIdentity?
        if requiresExactSampleIdentity(reference) {
            sampleIdentity =
                try await MediaPreservationTrackSampleIdentityReader
                .read(
                    asset: asset,
                    track: track,
                    cancellationCheck: {
                        try Task.checkCancellation()
                    }
                )
        } else {
            sampleIdentity = nil
        }
        let linearPCMIdentity: OutputMediaLinearPCMTrackIdentity?
        let isLinearPCM = track.mediaType == .audio
            && !formatDescriptions.isEmpty
            && formatDescriptions.allSatisfy {
                CMFormatDescriptionGetMediaSubType($0)
                    == kAudioFormatLinearPCM
            }
        if isLinearPCM {
            linearPCMIdentity =
                try await OutputMediaLinearPCMIdentityReader
                .readTrack(
                    asset: asset,
                    track: track,
                    ordinal: reference.ordinal,
                    cancellationCheck: {
                        try Task.checkCancellation()
                    }
                )
        } else {
            linearPCMIdentity = nil
        }
        let appleLosslessIdentity:
            OutputMediaAppleLosslessTrackIdentity?
        let isAppleLossless = track.mediaType == .audio
            && !formatDescriptions.isEmpty
            && formatDescriptions.allSatisfy {
                CMFormatDescriptionGetMediaSubType($0)
                    == kAudioFormatAppleLossless
            }
        if isAppleLossless {
            appleLosslessIdentity =
                try await OutputMediaAppleLosslessIdentityReader
                .readTrack(
                    asset: asset,
                    track: track,
                    ordinal: reference.ordinal,
                    cancellationCheck: {
                        try Task.checkCancellation()
                    }
                )
        } else {
            appleLosslessIdentity = nil
        }
        let segmentIdentity: [OutputMediaTrackSegmentIdentity]?
        if track.mediaType == .closedCaption {
            segmentIdentity = try await track.load(.segments).map {
                OutputMediaTrackSegmentIdentity(
                    isEmpty: $0.isEmpty,
                    source: $0.timeMapping.source,
                    target: $0.timeMapping.target
                )
            }
        } else {
            segmentIdentity = nil
        }
        let expectation = OutputMediaTrackPreservationExpectation(
            reference: reference,
            timeRange: timeRange,
            naturalTimeScale: exactTimeScale,
            formatSubtypes: formatDescriptions.map {
                CMFormatDescriptionGetMediaSubType($0)
            },
            totalSampleDataLength:
                try await track.load(.totalSampleDataLength),
            sampleIdentity: sampleIdentity,
            linearPCMIdentity: linearPCMIdentity,
            appleLosslessIdentity: appleLosslessIdentity,
            segmentIdentity: segmentIdentity,
            isEnabled: try await track.load(.isEnabled),
            languageCode: try await track.load(.languageCode),
            extendedLanguageTag:
                try await track.load(.extendedLanguageTag),
            metadata: metadataIdentity
        )
        return SourceMediaTrackPreservationPlan(
            track: track,
            metadata: metadata,
            expectation: expectation
        )
    }

    static func includingAssociationTargets(
        _ selectedTracks: [AVAssetTrack],
        selection: SourceMediaAssociationTargetSelection = .all
    ) async throws -> [AVAssetTrack] {
        var tracks: [AVAssetTrack] = []
        tracks.reserveCapacity(selectedTracks.count)
        var includedTrackIDs: Set<CMPersistentTrackID> = []
        for track in selectedTracks {
            guard includedTrackIDs.insert(track.trackID).inserted else {
                throw MediaPreservationIdentityError.duplicateTrackID(
                    track.trackID
                )
            }
            tracks.append(track)
        }

        var sourceIndex = 0
        while sourceIndex < tracks.count {
            try Task.checkCancellation()
            let source = tracks[sourceIndex]
            sourceIndex += 1
            let associationTypes = try await source.load(
                .availableTrackAssociationTypes
            )
            for associationType in associationTypes {
                let targets = try await source.loadAssociatedTracks(
                    ofType: associationType
                )
                for target in targets
                where !includedTrackIDs.contains(target.trackID) {
                    if let requiredAction = selection.disabledAction(
                        for: target.mediaType
                    ) {
                        throw MediaPreservationIdentityError
                            .disabledAssociationTarget(
                                associationType:
                                    associationType.rawValue,
                                sourceMediaType:
                                    source.mediaType.rawValue,
                                targetMediaType:
                                    target.mediaType.rawValue,
                                requiredAction: requiredAction
                            )
                    }
                    includedTrackIDs.insert(target.trackID)
                    tracks.append(target)
                }
            }
        }
        return tracks
    }

    static func associationSort(
        _ lhs: OutputMediaTrackAssociationExpectation,
        _ rhs: OutputMediaTrackAssociationExpectation
    ) -> Bool {
        associationSortKey(lhs) < associationSortKey(rhs)
    }

    private static func requiresExactSampleIdentity(
        _ reference: OutputMediaTrackReference
    ) -> Bool {
        reference.mediaType != AVMediaType.audio.rawValue
            && !(reference.mediaType == AVMediaType.video.rawValue
                && reference.ordinal == 0)
    }

    private static func associationSortKey(
        _ association: OutputMediaTrackAssociationExpectation
    ) -> String {
        "\(association.source.mediaType):\(association.source.ordinal):"
            + "\(association.associationType):"
            + "\(association.target.mediaType):"
            + "\(association.target.ordinal)"
    }
}

enum SourceMediaPreservationPreflight {
    private static let auxiliaryMediaTypes: [AVMediaType] = [
        .subtitle,
        .text,
        .closedCaption,
        .metadata,
        .timecode
    ]

    static func inspect(
        asset: AVURLAsset,
        videoTrack: AVAssetTrack
    ) async throws -> SourceMediaPreservationCapability {
        try Task.checkCancellation()
        let audioTracks = try await asset.loadTracks(
            withMediaType: .audio
        )
        var auxiliaryTracks: [AVAssetTrack] = []
        for mediaType in auxiliaryMediaTypes {
            try Task.checkCancellation()
            auxiliaryTracks.append(
                contentsOf: try await asset.loadTracks(
                    withMediaType: mediaType
                )
            )
        }
        let selectedTracks =
            try await SourceMediaPreservationPlanner
                .includingAssociationTargets(
                    [videoTrack] + audioTracks + auxiliaryTracks
                )
        let references = trackReferences(selectedTracks)
        let inspectableTracks = selectedTracks.filter {
            $0.trackID != videoTrack.trackID
        }

        var capabilities: [SourceMediaTrackCapability] = []
        capabilities.reserveCapacity(inspectableTracks.count)
        for track in inspectableTracks {
            try Task.checkCancellation()
            guard let reference = references[track.trackID] else {
                capabilities.append(
                    unavailableTrack(
                        track: track,
                        ordinal: 0,
                        error: MediaPreservationIdentityError
                            .duplicateTrackID(track.trackID)
                    )
                )
                continue
            }
            do {
                capabilities.append(
                    try await inspectTrack(
                        asset: asset,
                        track: track,
                        reference: reference
                    )
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                capabilities.append(
                    unavailableTrack(
                        track: track,
                        ordinal: reference.ordinal,
                        error: error
                    )
                )
            }
        }

        let associationResult = await inspectAssociations(
            selectedTracks: selectedTracks,
            references: references
        )
        let containerResult = await inspectContainerMetadata(
            asset: asset
        )
        var overallSupport = containerResult.support

        do {
            _ = try await SourceMediaPreservationPlanner.make(
                asset: asset,
                selectedTracks: selectedTracks,
                preserveMetadata: true
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch is OutputMediaLinearPCMIdentityError {
            // `inspectTrack` records the exact per-audio-track PCM
            // remediation. Do not promote that selected-track gap to
            // container metadata, because disabling audio preservation
            // must leave otherwise supported metadata selectable.
        } catch let error as MediaPreservationIdentityError {
            switch error {
            case .missingAssociationTarget,
                    .disabledAssociationTarget:
                if associationResult.associations.allSatisfy({
                    $0.support.isCompatible
                }) {
                    overallSupport = unsupportedAssociationSupport(
                        error.description
                    )
                }
            case .unsupportedMetadataValue:
                overallSupport = .unavailable(
                    gap: .metadataIdentityUnavailable,
                    reason: "Source metadata uses a value that Mirmir "
                        + "cannot yet preserve exactly (\(error)). "
                        + "Exact preservation for this metadata value "
                        + "type is not implemented.",
                    missingCapability:
                        "metadata value passthrough"
                )
            case .sampleIdentityFailed:
                overallSupport = .unavailable(
                    gap: .trackIdentityUnavailable,
                    reason: "A source auxiliary track cannot be "
                        + "identified exactly (\(error)). Exact sample "
                        + "passthrough for this track remains "
                        + "unimplemented.",
                    missingCapability:
                        "auxiliary sample passthrough"
                )
            case .duplicateTrackID:
                overallSupport = .unavailable(
                    gap: .trackIdentityUnavailable,
                    reason: "The source media graph is ambiguous "
                        + "(\(error)). Exact duplicate-track identity "
                        + "handling is not implemented.",
                    missingCapability:
                        "duplicate track identity handling"
                )
            }
        } catch {
            overallSupport = .unavailable(
                gap: .trackIdentityUnavailable,
                reason: "Mirmir could not establish an exact source "
                    + "media preservation plan (\(error)). The missing "
                    + "track-preservation path must be implemented "
                    + "before this media can be preserved.",
                missingCapability:
                    "source track preservation planning"
            )
        }
        if let failure = associationResult.failureSupport {
            overallSupport = failure
        }

        return SourceMediaPreservationCapability(
            verificationLevel: .exactProbe,
            tracks: capabilities,
            associations: associationResult.associations.sorted {
                $0.id < $1.id
            },
            hasContainerMetadata:
                containerResult.hasContainerMetadata,
            containerMetadataIdentitySHA256:
                containerResult.identitySHA256,
            support: overallSupport
        )
    }

    private static func inspectTrack(
        asset: AVURLAsset,
        track: AVAssetTrack,
        reference: OutputMediaTrackReference
    ) async throws -> SourceMediaTrackCapability {
        let formatDescriptions = try await track.load(
            .formatDescriptions
        )
        let formatSubtypes = formatDescriptions.map {
            fourCCString(
                CMFormatDescriptionGetMediaSubType($0)
            )
        }
        let timeRange = try await track.load(.timeRange)
        try AVFoundationSourceTimelinePreflight.validate(
            timeRange,
            mediaType: track.mediaType
        )
        let naturalTimeScale = try await track.load(
            .naturalTimeScale
        )
        let exactTimeScale = try ExactVideoWriterTimeScale.resolve(
            naturalTimeScale: naturalTimeScale,
            trackTimeRange: timeRange
        )
        let totalSampleDataLength = try await track.load(
            .totalSampleDataLength
        )
        let isEnabled = try await track.load(.isEnabled)
        let languageCode = try await track.load(.languageCode)
        let extendedLanguageTag = try await track.load(
            .extendedLanguageTag
        )
        let metadata = try await track.load(.metadata)
        let metadataIdentity =
            try await MediaPreservationMetadataIdentityReader.read(
                metadata
            )
        let sampleIdentity: OutputMediaTrackSampleIdentity?
        if track.mediaType != .audio {
            sampleIdentity =
                try await MediaPreservationTrackSampleIdentityReader
                .read(
                    asset: asset,
                    track: track,
                    cancellationCheck: {
                        try Task.checkCancellation()
                    }
                )
        } else {
            sampleIdentity = nil
        }
        let segmentIdentity: [OutputMediaTrackSegmentIdentity]?
        if track.mediaType == .closedCaption {
            segmentIdentity = try await track.load(.segments).map {
                OutputMediaTrackSegmentIdentity(
                    isEmpty: $0.isEmpty,
                    source: $0.timeMapping.source,
                    target: $0.timeMapping.target
                )
            }
        } else {
            segmentIdentity = nil
        }

        var sampleRate: Double?
        var channelCount: UInt32?
        if track.mediaType == .audio,
           let formatDescription = formatDescriptions.first,
           let stream =
            CMAudioFormatDescriptionGetStreamBasicDescription(
                formatDescription
            )?.pointee {
            sampleRate = stream.mSampleRate
            channelCount = stream.mChannelsPerFrame
        }

        var support: SourceMediaPreservationSupport = .exact
        var compressedAudioIdentitySHA256: String?
        var linearPCMAudioIdentitySHA256: String?
        if track.mediaType == .audio {
            let isAAC = !formatSubtypes.isEmpty
                && formatSubtypes.allSatisfy { $0 == "aac " }
            let isLinearPCM = !formatSubtypes.isEmpty
                && formatSubtypes.allSatisfy { $0 == "lpcm" }
            let isAppleLossless = !formatSubtypes.isEmpty
                && formatSubtypes.allSatisfy { $0 == "alac" }
            if isAAC {
                do {
                    let identity =
                        try await OutputMediaAACIdentityReader.readTrack(
                            asset: asset,
                            track: track,
                            ordinal: reference.ordinal,
                            cancellationCheck: {
                                try Task.checkCancellation()
                            }
                        )
                    sampleRate =
                        identity.compressedIdentity.sampleRate
                    channelCount =
                        identity.compressedIdentity.channelCount
                    compressedAudioIdentitySHA256 =
                        identity.compressedIdentity.canonicalSHA256
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    support = audioFailureSupport(
                        ordinal: reference.ordinal,
                        formatSubtypes: formatSubtypes,
                        error: error
                    )
                }
            } else if isLinearPCM {
                do {
                    let identity =
                        try await OutputMediaLinearPCMIdentityReader
                        .readTrack(
                            asset: asset,
                            track: track,
                            ordinal: reference.ordinal,
                            cancellationCheck: {
                                try Task.checkCancellation()
                            }
                        )
                    sampleRate = identity.formats.first?.sampleRate
                    channelCount =
                        identity.formats.first?.channelsPerFrame
                    linearPCMAudioIdentitySHA256 =
                        identity.canonicalSHA256
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    support = linearPCMFailureSupport(
                        ordinal: reference.ordinal,
                        error: error
                    )
                }
            } else if isAppleLossless {
                do {
                    let identity =
                        try await
                        OutputMediaAppleLosslessIdentityReader
                        .readTrack(
                            asset: asset,
                            track: track,
                            ordinal: reference.ordinal,
                            cancellationCheck: {
                                try Task.checkCancellation()
                            }
                        )
                    sampleRate = identity.formats.first?.sampleRate
                    channelCount =
                        identity.formats.first?.channelsPerFrame
                    compressedAudioIdentitySHA256 =
                        identity.canonicalSHA256
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    support = appleLosslessFailureSupport(
                        ordinal: reference.ordinal,
                        error: error
                    )
                }
            } else {
                support = audioFailureSupport(
                    ordinal: reference.ordinal,
                    formatSubtypes: formatSubtypes,
                    error: OutputMediaVerificationError
                        .compressedAACMismatch(
                            reason: "the audio track is not uniformly "
                                + "AAC, Apple Lossless, or Linear PCM"
                        )
                )
            }
        }

        var encoder = SourceMediaCapabilityIdentityEncoder()
        encoder.append(reference.mediaType)
        encoder.append(Int64(reference.ordinal))
        encoder.append(timeRange)
        encoder.append(Int64(exactTimeScale))
        encoder.append(Int64(totalSampleDataLength))
        encoder.append(isEnabled)
        encoder.append(languageCode)
        encoder.append(extendedLanguageTag)
        encoder.append(formatSubtypes)
        encoder.append(metadataIdentity)
        encoder.append(sampleIdentity)
        encoder.append(segmentIdentity)
        encoder.append(compressedAudioIdentitySHA256)
        encoder.append(linearPCMAudioIdentitySHA256)

        return SourceMediaTrackCapability(
            mediaType: reference.mediaType,
            ordinal: reference.ordinal,
            formatSubtypes: formatSubtypes,
            isEnabled: isEnabled,
            languageCode: languageCode,
            extendedLanguageTag: extendedLanguageTag,
            sampleRate: sampleRate,
            channelCount: channelCount,
            compressedAudioIdentitySHA256:
                compressedAudioIdentitySHA256,
            linearPCMAudioIdentitySHA256:
                linearPCMAudioIdentitySHA256,
            exactTrackIdentitySHA256: encoder.sha256,
            support: support
        )
    }

    private static func inspectAssociations(
        selectedTracks: [AVAssetTrack],
        references:
            [CMPersistentTrackID: OutputMediaTrackReference]
    ) async -> (
        associations: [SourceMediaTrackAssociationCapability],
        failureSupport: SourceMediaPreservationSupport?
    ) {
        var result: [SourceMediaTrackAssociationCapability] = []
        do {
            for sourceTrack in selectedTracks {
                try Task.checkCancellation()
                guard let sourceReference =
                        references[sourceTrack.trackID] else {
                    continue
                }
                let associationTypes = try await sourceTrack.load(
                    .availableTrackAssociationTypes
                )
                for associationType in associationTypes {
                    let targets =
                        try await sourceTrack.loadAssociatedTracks(
                            ofType: associationType
                        )
                    for target in targets {
                        let targetReference =
                            references[target.trackID]
                        let support: SourceMediaPreservationSupport
                        if targetReference != nil {
                            support = .exact
                        } else {
                            let targetName =
                                SourceMediaTrackCapability
                                .mediaTypeDisplayName(
                                    target.mediaType.rawValue
                                )
                            support = .unavailable(
                                gap: .unsupportedAssociation,
                                reason: "Source "
                                    + SourceMediaTrackCapability
                                        .mediaTypeDisplayName(
                                            sourceTrack.mediaType
                                                .rawValue
                                        )
                                    + " track "
                                    + "\(sourceReference.ordinal + 1) "
                                    + "association "
                                    + "\(associationType.rawValue) "
                                    + "targets \(targetName), but exact "
                                    + "\(targetName.lowercased()) track "
                                    + "passthrough and association "
                                    + "reconstruction are not "
                                    + "implemented.",
                                missingCapability:
                                    "\(targetName) track passthrough "
                                    + "and \(associationType.rawValue) "
                                    + "association reconstruction"
                            )
                        }
                        result.append(
                            SourceMediaTrackAssociationCapability(
                                sourceMediaType:
                                    sourceReference.mediaType,
                                sourceOrdinal:
                                    sourceReference.ordinal,
                                targetMediaType:
                                    target.mediaType.rawValue,
                                targetOrdinal:
                                    targetReference?.ordinal,
                                associationType:
                                    associationType.rawValue,
                                support: support
                            )
                        )
                    }
                }
            }
            return (result, nil)
        } catch is CancellationError {
            return (
                result,
                .unavailable(
                    gap: .trackIdentityUnavailable,
                    reason: "Source media association inspection was "
                        + "cancelled before an exact graph was "
                        + "established.",
                    missingCapability:
                        "complete association inspection"
                )
            )
        } catch {
            return (
                result,
                .unavailable(
                    gap: .unsupportedAssociation,
                    reason: "Mirmir could not read the complete source "
                        + "track association graph (\(error)). Exact "
                        + "association preservation cannot start until "
                        + "this graph is supported.",
                    missingCapability:
                        "source association graph inspection"
                )
            )
        }
    }

    private static func inspectContainerMetadata(
        asset: AVURLAsset
    ) async -> (
        hasContainerMetadata: Bool,
        identitySHA256: String?,
        support: SourceMediaPreservationSupport
    ) {
        do {
            let metadata = try await asset.load(.metadata)
            let identity =
                try await MediaPreservationMetadataIdentityReader.read(
                    metadata
                )
            return (
                !metadata.isEmpty,
                metadataIdentitySHA256(identity),
                .exact
            )
        } catch {
            return (
                false,
                nil,
                .unavailable(
                    gap: .metadataIdentityUnavailable,
                    reason: "Source container metadata could not be "
                        + "identified exactly (\(error)). Exact "
                        + "passthrough for this metadata representation "
                        + "is not implemented.",
                    missingCapability:
                        "container metadata identity passthrough"
                )
            )
        }
    }

    private static func unavailableTrack(
        track: AVAssetTrack,
        ordinal: Int,
        error: Error
    ) -> SourceMediaTrackCapability {
        let mediaName =
            SourceMediaTrackCapability.mediaTypeDisplayName(
                track.mediaType.rawValue
            )
        return SourceMediaTrackCapability(
            mediaType: track.mediaType.rawValue,
            ordinal: ordinal,
            formatSubtypes: [],
            isEnabled: nil,
            languageCode: nil,
            extendedLanguageTag: nil,
            sampleRate: nil,
            channelCount: nil,
            compressedAudioIdentitySHA256: nil,
            linearPCMAudioIdentitySHA256: nil,
            exactTrackIdentitySHA256: nil,
            support: .unavailable(
                gap: .trackIdentityUnavailable,
                reason: "\(mediaName) track \(ordinal + 1) could not "
                    + "be identified exactly (\(error)). Exact "
                    + "\(mediaName.lowercased()) passthrough for this "
                    + "track is not implemented.",
                missingCapability:
                    "\(mediaName) track identity passthrough"
            )
        )
    }

    private static func audioFailureSupport(
        ordinal: Int,
        formatSubtypes: [String],
        error: Error
    ) -> SourceMediaPreservationSupport {
        let formats = formatSubtypes.isEmpty
            ? "an unidentified codec"
            : formatSubtypes.map(
                SourceMediaTrackCapability.formatDisplayName
            ).joined(separator: ", ")
        let isNonAAC = !formatSubtypes.isEmpty
            && formatSubtypes.contains { $0 != "aac " }
        if isNonAAC {
            return .unavailable(
                gap: .nonAACAudioCodec,
                reason: "Audio track \(ordinal + 1) uses \(formats), "
                    + "but Mirmir's current exact audio passthrough "
                    + "accepts AAC, Apple Lossless, and supported "
                    + "interleaved Linear PCM. "
                    + "Exact \(formats) passthrough is not implemented. "
                    + "Turn off Preserve Source Audio Tracks for this "
                    + "job, or use an AAC, Apple Lossless, or supported "
                    + "Linear PCM source.",
                missingCapability:
                    "\(formats) audio passthrough"
            )
        }
        return .unavailable(
            gap: .aacIdentityUnavailable,
            reason: "Audio track \(ordinal + 1) reports \(formats), "
                + "but its exact compressed identity could not be "
                + "established (\(error)). Turn off Preserve Source "
                + "Audio Tracks or use an independently verified AAC "
                + "source; support for this AAC representation remains "
                + "required.",
            missingCapability:
                "this AAC representation's exact passthrough"
        )
    }

    private static func appleLosslessFailureSupport(
        ordinal: Int,
        error: Error
    ) -> SourceMediaPreservationSupport {
        .unavailable(
            gap: .appleLosslessIdentityUnavailable,
            reason: "Audio track \(ordinal + 1) reports Apple Lossless "
                + "(alac), but its exact compressed identity could not "
                + "be established (\(error)). Turn off Preserve Source "
                + "Audio Tracks or use a valid Apple Lossless source; "
                + "support for this representation remains required.",
            missingCapability:
                "this Apple Lossless representation's exact passthrough"
        )
    }

    private static func linearPCMFailureSupport(
        ordinal: Int,
        error: Error
    ) -> SourceMediaPreservationSupport {
        let reason = String(describing: error)
        if let pcmError =
                error as? OutputMediaLinearPCMIdentityError,
           case .unsupportedRepresentation = pcmError {
            return .unavailable(
                gap: .unsupportedLinearPCMVariant,
                reason: reason,
                missingCapability:
                    "this Linear PCM representation's exact passthrough"
            )
        }
        return .unavailable(
            gap: .linearPCMIdentityUnavailable,
            reason: reason,
            missingCapability:
                "this Linear PCM track's exact sample-copy identity"
        )
    }

    private static func unsupportedAssociationSupport(
        _ description: String
    ) -> SourceMediaPreservationSupport {
        .unavailable(
            gap: .unsupportedAssociation,
            reason: "A source track association cannot be reconstructed "
                + "exactly (\(description)). Exact passthrough for the "
                + "association target is not implemented.",
            missingCapability:
                "the missing association target and graph reconstruction"
        )
    }

    private static func trackReferences(
        _ tracks: [AVAssetTrack]
    ) -> [CMPersistentTrackID: OutputMediaTrackReference] {
        var nextOrdinalByMediaType: [String: Int] = [:]
        var result:
            [CMPersistentTrackID: OutputMediaTrackReference] = [:]
        for track in tracks {
            let mediaType = track.mediaType.rawValue
            let ordinal =
                nextOrdinalByMediaType[mediaType, default: 0]
            nextOrdinalByMediaType[mediaType] = ordinal + 1
            result[track.trackID] = OutputMediaTrackReference(
                mediaType: mediaType,
                ordinal: ordinal
            )
        }
        return result
    }

    private static func metadataIdentitySHA256(
        _ identity: OutputMediaMetadataIdentity
    ) -> String {
        var encoder = SourceMediaCapabilityIdentityEncoder()
        encoder.append(identity)
        return encoder.sha256
    }

    private static func fourCCString(_ value: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }
}

private struct SourceMediaCapabilityIdentityEncoder {
    private var data = Data()

    var sha256: String {
        SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }

    mutating func append(_ value: String) {
        append(Data(value.utf8))
    }

    mutating func append(_ value: String?) {
        guard let value else {
            append(UInt8(0))
            return
        }
        append(UInt8(1))
        append(value)
    }

    mutating func append(_ value: Bool) {
        append(value ? UInt8(1) : UInt8(0))
    }

    mutating func append(_ value: Int64) {
        appendInteger(value)
    }

    mutating func append(_ values: [String]) {
        appendInteger(UInt64(values.count))
        for value in values {
            append(value)
        }
    }

    mutating func append(_ time: CMTime) {
        guard time.isValid else {
            append(UInt8(0))
            return
        }
        if time.isPositiveInfinity {
            append(UInt8(1))
        } else if time.isNegativeInfinity {
            append(UInt8(2))
        } else if time.isIndefinite {
            append(UInt8(3))
        } else if time.isNumeric, time.timescale > 0 {
            append(UInt8(4))
            let divisor = semanticTimeDivisor(
                value: time.value,
                timescale: time.timescale
            )
            appendInteger(time.value / divisor)
            appendInteger(
                UInt32(Int64(time.timescale) / divisor)
            )
        } else {
            append(UInt8(5))
            appendInteger(time.value)
            appendInteger(time.timescale)
            appendInteger(time.flags.rawValue)
        }
        appendInteger(time.epoch)
    }

    mutating func append(_ range: CMTimeRange) {
        append(range.start)
        append(range.duration)
    }

    mutating func append(
        _ identity: OutputMediaMetadataIdentity
    ) {
        appendInteger(UInt64(identity.canonicalItems.count))
        for item in identity.canonicalItems {
            append(item)
        }
    }

    mutating func append(
        _ identity: OutputMediaTrackSampleIdentity?
    ) {
        guard let identity else {
            append(UInt8(0))
            return
        }
        append(UInt8(1))
        appendInteger(Int64(identity.sampleCount))
        appendInteger(identity.totalPayloadByteCount)
        append(identity.canonicalSHA256)
    }

    mutating func append(
        _ segments: [OutputMediaTrackSegmentIdentity]?
    ) {
        guard let segments else {
            append(UInt8(0))
            return
        }
        append(UInt8(1))
        appendInteger(UInt64(segments.count))
        for segment in segments {
            append(segment.isEmpty)
            append(segment.source)
            append(segment.target)
        }
    }

    private mutating func append(_ value: UInt8) {
        data.append(value)
    }

    private mutating func append(_ value: Data) {
        appendInteger(UInt64(value.count))
        data.append(value)
    }

    private mutating func appendInteger<T: FixedWidthInteger>(
        _ value: T
    ) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) {
            data.append(contentsOf: $0)
        }
    }

    private func semanticTimeDivisor(
        value: Int64,
        timescale: CMTimeScale
    ) -> Int64 {
        let denominator = Int64(timescale)
        var lhs = denominator
        var rhs = value % denominator
        if rhs < 0 {
            rhs = -rhs
        }
        while rhs != 0 {
            let remainder = lhs % rhs
            lhs = rhs
            rhs = remainder
        }
        return lhs
    }
}

extension OutputMediaVerifier {
    static func verifyMediaPreservation(
        asset: AVURLAsset,
        expected: OutputMediaPreservationExpectation,
        mirmirMetadataTrackID: CMPersistentTrackID?,
        cancellationCheck: @escaping @Sendable () throws -> Void
    ) async throws {
        try cancellationCheck()
        let actualContainerMetadata = try await asset.load(.metadata)
        let actualContainerIdentity: OutputMediaMetadataIdentity
        do {
            actualContainerIdentity =
                try await MediaPreservationMetadataIdentityReader.read(
                    actualContainerMetadata
                )
        } catch {
            throw mediaPreservationMismatch(
                "container metadata identity failed: \(error)"
            )
        }
        guard actualContainerIdentity == expected.containerMetadata else {
            throw mediaPreservationMismatch(
                "container metadata items differ (expected "
                    + "\(expected.containerMetadata.canonicalItems.count), "
                    + "observed "
                    + "\(actualContainerIdentity.canonicalItems.count))"
            )
        }

        var actualTracksByMediaType: [String: [AVAssetTrack]] = [:]
        let mediaTypeKeys = Set(
            SourceMediaPreservationPlanner.preservedMediaTypes.map(
                \.rawValue
            )
                + Array(expected.expectedTrackCounts.keys)
        )
        for mediaTypeKey in mediaTypeKeys.sorted() {
            try cancellationCheck()
            let mediaType = AVMediaType(rawValue: mediaTypeKey)
            var tracks = try await asset.loadTracks(
                withMediaType: mediaType
            )
            if mediaType == .metadata,
               let mirmirMetadataTrackID {
                tracks.removeAll {
                    $0.trackID == mirmirMetadataTrackID
                }
            }
            actualTracksByMediaType[mediaTypeKey] = tracks
            let expectedCount = expected.expectedTrackCounts[
                mediaTypeKey,
                default: 0
            ]
            guard tracks.count == expectedCount else {
                throw mediaPreservationMismatch(
                    "\(mediaTypeKey) track count: expected "
                        + "\(expectedCount), observed \(tracks.count)"
                )
            }
        }

        var actualReferenceByTrackID:
            [CMPersistentTrackID: OutputMediaTrackReference] = [:]
        for trackExpectation in expected.tracks {
            try cancellationCheck()
            let reference = trackExpectation.reference
            guard let tracks =
                    actualTracksByMediaType[reference.mediaType],
                  tracks.indices.contains(reference.ordinal) else {
                throw mediaPreservationMismatch(
                    "missing track \(reference)"
                )
            }
            let track = tracks[reference.ordinal]
            actualReferenceByTrackID[track.trackID] = reference
            try await verifyPreservedTrack(
                asset: asset,
                track,
                expected: trackExpectation,
                cancellationCheck: cancellationCheck
            )
        }

        var actualAssociations:
            [OutputMediaTrackAssociationExpectation] = []
        for trackExpectation in expected.tracks {
            try cancellationCheck()
            let reference = trackExpectation.reference
            guard let sourceTrack = actualTracksByMediaType[
                reference.mediaType
            ]?[reference.ordinal] else {
                throw mediaPreservationMismatch(
                    "missing association source \(reference)"
                )
            }
            let associationTypes = try await sourceTrack.load(
                .availableTrackAssociationTypes
            )
            for associationType in associationTypes {
                let targetTracks =
                    try await sourceTrack.loadAssociatedTracks(
                        ofType: associationType
                    )
                for targetTrack in targetTracks {
                    guard targetTrack.trackID
                            != mirmirMetadataTrackID,
                          let targetReference =
                            actualReferenceByTrackID[
                                targetTrack.trackID
                            ] else {
                        throw mediaPreservationMismatch(
                            "association \(associationType.rawValue) "
                                + "from \(reference) targets an "
                                + "unexpected track"
                        )
                    }
                    actualAssociations.append(
                        OutputMediaTrackAssociationExpectation(
                            source: reference,
                            target: targetReference,
                            associationType:
                                associationType.rawValue
                        )
                    )
                }
            }
        }
        actualAssociations.sort(
            by: SourceMediaPreservationPlanner.associationSort
        )
        guard actualAssociations == expected.associations else {
            throw mediaPreservationMismatch(
                "track association graph differs (expected "
                    + "\(expected.associations.count), observed "
                    + "\(actualAssociations.count))"
            )
        }
    }

    private static func verifyPreservedTrack(
        asset: AVURLAsset,
        _ track: AVAssetTrack,
        expected: OutputMediaTrackPreservationExpectation,
        cancellationCheck: @escaping @Sendable () throws -> Void
    ) async throws {
        let reference = expected.reference
        let timeRange = try await track.load(.timeRange)
        guard semanticTimesAreEqual(
            timeRange.start,
            expected.timeRange.start
        ), semanticTimesAreEqual(
            timeRange.duration,
            expected.timeRange.duration
        ) else {
            throw mediaPreservationMismatch(
                "\(reference) time range differs (expected start "
                    + "\(exactTimeDescription(expected.timeRange.start)), "
                    + "duration "
                    + "\(exactTimeDescription(expected.timeRange.duration)); "
                    + "observed start "
                    + "\(exactTimeDescription(timeRange.start)), duration "
                    + "\(exactTimeDescription(timeRange.duration)))"
            )
        }
        let naturalTimeScale = try await track.load(.naturalTimeScale)
        guard naturalTimeScale == expected.naturalTimeScale else {
            throw mediaPreservationMismatch(
                "\(reference) timescale: expected "
                    + "\(expected.naturalTimeScale), observed "
                + "\(naturalTimeScale)"
            )
        }
        if let expectedSegments = expected.segmentIdentity {
            let observedSegments = try await track.load(.segments).map {
                OutputMediaTrackSegmentIdentity(
                    isEmpty: $0.isEmpty,
                    source: $0.timeMapping.source,
                    target: $0.timeMapping.target
                )
            }
            guard observedSegments == expectedSegments else {
                throw mediaPreservationMismatch(
                    "\(reference) edit segments differ (expected "
                        + "\(expectedSegments), observed "
                        + "\(observedSegments))"
                )
            }
        }
        let isTransformedPrimaryVideo =
            reference.mediaType == AVMediaType.video.rawValue
                && reference.ordinal == 0
        if !isTransformedPrimaryVideo {
            let formatSubtypes = try await track.load(
                .formatDescriptions
            ).map {
                CMFormatDescriptionGetMediaSubType($0)
            }
            guard formatSubtypes == expected.formatSubtypes else {
                throw mediaPreservationMismatch(
                    "\(reference) format subtypes differ"
                )
            }
            let totalSampleDataLength = try await track.load(
                .totalSampleDataLength
            )
            guard totalSampleDataLength
                    == expected.totalSampleDataLength else {
                throw mediaPreservationMismatch(
                    "\(reference) sample bytes: expected "
                        + "\(expected.totalSampleDataLength), observed "
                        + "\(totalSampleDataLength)"
                )
            }
            if let expectedSampleIdentity = expected.sampleIdentity {
                let actualSampleIdentity: OutputMediaTrackSampleIdentity
                do {
                    actualSampleIdentity =
                        try await MediaPreservationTrackSampleIdentityReader
                        .read(
                            asset: asset,
                            track: track,
                            cancellationCheck: cancellationCheck
                        )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw mediaPreservationMismatch(
                        "\(reference) sample identity read failed: "
                            + "\(error)"
                    )
                }
                guard actualSampleIdentity
                        == expectedSampleIdentity else {
                    throw mediaPreservationMismatch(
                        "\(reference) sample timing or payload identity "
                            + "differs (expected "
                            + "\(expectedSampleIdentity.sampleCount) "
                            + "samples/"
                            + "\(expectedSampleIdentity.totalPayloadByteCount) "
                            + "bytes, observed "
                            + "\(actualSampleIdentity.sampleCount) samples/"
                            + "\(actualSampleIdentity.totalPayloadByteCount) "
                            + "bytes)"
                    )
                }
            }
            if let expectedLinearPCM =
                    expected.linearPCMIdentity {
                let actualLinearPCM:
                    OutputMediaLinearPCMTrackIdentity
                do {
                    actualLinearPCM =
                        try await OutputMediaLinearPCMIdentityReader
                        .readTrack(
                            asset: asset,
                            track: track,
                            ordinal: reference.ordinal,
                            cancellationCheck: cancellationCheck
                        )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw mediaPreservationMismatch(
                        "\(reference) Linear PCM identity read failed: "
                            + "\(error)"
                    )
                }
                guard actualLinearPCM == expectedLinearPCM else {
                    throw mediaPreservationMismatch(
                        "\(reference) Linear PCM ASBD, channel layout, "
                            + "timing, or payload identity differs "
                            + "(expected "
                            + "\(expectedLinearPCM.audioFrameCount) "
                            + "frames/"
                            + "\(expectedLinearPCM.totalPayloadByteCount) "
                            + "bytes/"
                            + "\(expectedLinearPCM.payloadSHA256), "
                            + "observed "
                            + "\(actualLinearPCM.audioFrameCount) "
                            + "frames/"
                            + "\(actualLinearPCM.totalPayloadByteCount) "
                            + "bytes/"
                            + "\(actualLinearPCM.payloadSHA256))"
                    )
                }
            }
            if let expectedAppleLossless =
                    expected.appleLosslessIdentity {
                let actualAppleLossless:
                    OutputMediaAppleLosslessTrackIdentity
                do {
                    actualAppleLossless =
                        try await
                        OutputMediaAppleLosslessIdentityReader
                        .readTrack(
                            asset: asset,
                            track: track,
                            ordinal: reference.ordinal,
                            cancellationCheck: cancellationCheck
                        )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw mediaPreservationMismatch(
                        "\(reference) Apple Lossless identity read "
                            + "failed: \(error)"
                    )
                }
                let expectedSamples =
                    expectedAppleLossless.sampleIdentity
                let actualSamples =
                    actualAppleLossless.sampleIdentity
                guard actualAppleLossless
                        == expectedAppleLossless else {
                    throw mediaPreservationMismatch(
                        "\(reference) Apple Lossless ASBD, codec "
                            + "configuration, channel layout, timing, "
                            + "or payload identity differs (expected "
                            + "\(expectedSamples.sampleCount) packets/"
                            + "\(expectedSamples.totalPayloadByteCount) "
                            + "bytes/"
                            + "\(expectedAppleLossless.canonicalSHA256), "
                            + "observed "
                            + "\(actualSamples.sampleCount) packets/"
                            + "\(actualSamples.totalPayloadByteCount) "
                            + "bytes/"
                            + "\(actualAppleLossless.canonicalSHA256))"
                    )
                }
            }
        }
        let isEnabled = try await track.load(.isEnabled)
        guard isEnabled == expected.isEnabled else {
            throw mediaPreservationMismatch(
                "\(reference) enabled state differs"
            )
        }
        let languageCode = try await track.load(.languageCode)
        guard languageCode == expected.languageCode else {
            throw mediaPreservationMismatch(
                "\(reference) language code differs"
            )
        }
        let extendedLanguageTag = try await track.load(
            .extendedLanguageTag
        )
        guard extendedLanguageTag
                == expected.extendedLanguageTag else {
            throw mediaPreservationMismatch(
                "\(reference) extended language tag differs"
            )
        }
        try cancellationCheck()
        let metadata = try await track.load(.metadata)
        let metadataIdentity: OutputMediaMetadataIdentity
        do {
            metadataIdentity =
                try await MediaPreservationMetadataIdentityReader.read(
                    metadata
                )
        } catch {
            throw mediaPreservationMismatch(
                "\(reference) metadata identity failed: \(error)"
            )
        }
        guard metadataIdentity == expected.metadata else {
            throw mediaPreservationMismatch(
                "\(reference) static metadata differs (expected "
                    + "\(expected.metadata.canonicalItems.count), "
                    + "observed "
                    + "\(metadataIdentity.canonicalItems.count))"
            )
        }
        try cancellationCheck()
    }

    private static func mediaPreservationMismatch(
        _ reason: String
    ) -> OutputMediaVerificationError {
        .mediaPreservationMismatch(reason: reason)
    }

    static func verifyVideoColor(
        formatDescription: CMFormatDescription,
        expected: OutputMediaVideoColorExpectation
    ) throws {
        let extensions = (CMFormatDescriptionGetExtensions(formatDescription) as NSDictionary?)
        if let expectedFullRange =
                expected.compressedFullRangeVideo {
            try verifyVideoColorField(
                "full range video",
                expected: String(expectedFullRange),
                actual: compressedVideoFullRangeValue(
                    extensions?[
                        kCMFormatDescriptionExtension_FullRangeVideo
                            as String
                    ]
                ).map(String.init)
            )
        }
        if let expectedBits = expected.compressedBitsPerComponent {
            try verifyVideoColorField(
                "compressed bits per component",
                expected: String(expectedBits),
                actual: (
                    extensions?[
                        kCMFormatDescriptionExtension_BitsPerComponent
                            as String
                    ] as? NSNumber
                ).map { String($0.intValue) }
            )
        }
        try verifyVideoColorField(
            "color primaries",
            expected: expected.colorPrimaries,
            actual: extensions?[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String
        )
        try verifyVideoColorField(
            "transfer function",
            expected: expected.transferFunction,
            actual: extensions?[kCMFormatDescriptionExtension_TransferFunction as String] as? String
        )
        try verifyVideoColorField(
            "YCbCr matrix",
            expected: expected.yCbCrMatrix,
            actual: extensions?[kCMFormatDescriptionExtension_YCbCrMatrix as String] as? String
        )
        if let chromaLocation = expected.chromaLocation {
            try verifyVideoColorField(
                "chroma location",
                expected: chromaLocation,
                actual: extensions?[
                    kCMFormatDescriptionExtension_ChromaLocationTopField
                        as String
                ] as? String
            )
        }
        try verifyAlpha(
            extensions: extensions,
            expected: expected.alphaMode
        )
        try verifyHDRStaticMetadata(
            extensions: extensions,
            expected: expected
        )
    }

    private static func compressedVideoFullRangeValue(_ extensionValue: Any?) -> Bool? {
        // Core Media defines an absent FullRangeVideo extension as false for
        // YCbCr compressed formats. A present value must still be a CFBoolean.
        guard let extensionValue else { return false }
        guard let number = extensionValue as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else {
            return nil
        }
        return number.boolValue
    }

    static func verifyDecodedVideoColor(
        pixelBuffer: CVPixelBuffer,
        expected: OutputMediaVideoColorExpectation
    ) throws {
        try verifyVideoColorField(
            "decoded color primaries",
            expected: expected.colorPrimaries,
            actual: CVBufferCopyAttachment(
                pixelBuffer,
                kCVImageBufferColorPrimariesKey,
                nil
            ) as? String
        )
        try verifyVideoColorField(
            "decoded transfer function",
            expected: expected.transferFunction,
            actual: CVBufferCopyAttachment(
                pixelBuffer,
                kCVImageBufferTransferFunctionKey,
                nil
            ) as? String
        )
        if expected.usesYCbCr {
            try verifyVideoColorField(
                "decoded YCbCr matrix",
                expected: expected.yCbCrMatrix,
                actual: CVBufferCopyAttachment(
                    pixelBuffer,
                    kCVImageBufferYCbCrMatrixKey,
                    nil
                ) as? String
            )
            if let chromaLocation = expected.chromaLocation {
                try verifyVideoColorField(
                    "decoded chroma location",
                    expected: chromaLocation,
                    actual: CVBufferCopyAttachment(
                        pixelBuffer,
                        kCVImageBufferChromaLocationTopFieldKey,
                        nil
                    ) as? String
                )
            }
        }
        if expected.alphaMode != .none {
            try verifyVideoColorField(
                "decoded alpha mode",
                expected: alphaModeString(expected.alphaMode),
                actual: CVBufferCopyAttachment(
                    pixelBuffer,
                    kCVImageBufferAlphaChannelModeKey,
                    nil
                ) as? String
            )
        }
        try verifyDecodedHDRStaticMetadata(
            pixelBuffer: pixelBuffer,
            expected: expected
        )
    }

    private static func verifyAlpha(
        extensions: NSDictionary?,
        expected: MediaVideoAlphaMode
    ) throws {
        let containsAlpha = (
            extensions?[
                kCMFormatDescriptionExtension_ContainsAlphaChannel as String
            ] as? NSNumber
        )?.boolValue ?? false
        try verifyVideoColorField(
            "alpha presence",
            expected: String(expected != .none),
            actual: String(containsAlpha)
        )
        guard expected != .none else { return }
        try verifyVideoColorField(
            "alpha mode",
            expected: alphaModeString(expected),
            actual: extensions?[
                kCMFormatDescriptionExtension_AlphaChannelMode as String
            ] as? String
        )
    }

    private static func alphaModeString(
        _ mode: MediaVideoAlphaMode
    ) -> String {
        switch mode {
        case .none:
            return "none"
        case .straight:
            return kCMFormatDescriptionAlphaChannelMode_StraightAlpha
                as String
        case .premultiplied:
            return kCMFormatDescriptionAlphaChannelMode_PremultipliedAlpha
                as String
        }
    }

    private static func verifyHDRStaticMetadata(
        extensions: NSDictionary?,
        expected: OutputMediaVideoColorExpectation
    ) throws {
        try verifyMetadataData(
            field: "mastering display color volume",
            expected: expected.masteringDisplayColorVolume,
            actual: extensions?[
                kCMFormatDescriptionExtension_MasteringDisplayColorVolume
                    as String
            ] as? Data
        )
        try verifyMetadataData(
            field: "content light level",
            expected: expected.contentLightLevelInfo,
            actual: extensions?[
                kCMFormatDescriptionExtension_ContentLightLevelInfo as String
            ] as? Data
        )
    }

    private static func verifyDecodedHDRStaticMetadata(
        pixelBuffer: CVPixelBuffer,
        expected: OutputMediaVideoColorExpectation
    ) throws {
        try verifyMetadataData(
            field: "decoded mastering display color volume",
            expected: expected.masteringDisplayColorVolume,
            actual: CVBufferCopyAttachment(
                pixelBuffer,
                kCVImageBufferMasteringDisplayColorVolumeKey,
                nil
            ) as? Data
        )
        try verifyMetadataData(
            field: "decoded content light level",
            expected: expected.contentLightLevelInfo,
            actual: CVBufferCopyAttachment(
                pixelBuffer,
                kCVImageBufferContentLightLevelInfoKey,
                nil
            ) as? Data
        )
    }

    private static func verifyMetadataData(
        field: String,
        expected: Data?,
        actual: Data?
    ) throws {
        guard actual == expected else {
            throw OutputMediaVerificationError.videoColorMismatch(
                field: field,
                expected: expected.map { "\($0.count) exact bytes" }
                    ?? "absent",
                actual: actual.map { "\($0.count) different bytes" }
                    ?? "missing"
            )
        }
    }

    private static func verifyVideoColorField(
        _ field: String,
        expected: String,
        actual: String?
    ) throws {
        guard actual == expected else {
            throw OutputMediaVerificationError.videoColorMismatch(
                field: field,
                expected: expected,
                actual: actual
            )
        }
    }

    static func verifyCompressedAAC(
        _ actual: OutputMediaAACIdentity,
        expected: OutputMediaAACIdentity
    ) throws {
        guard actual.codec == expected.codec else {
            throw compressedAACMismatch(
                field: "codec",
                expected: fourCCString(expected.codec),
                actual: fourCCString(actual.codec)
            )
        }
        guard actual.sampleRate.bitPattern == expected.sampleRate.bitPattern else {
            throw compressedAACMismatch(
                field: "sample rate",
                expected: String(expected.sampleRate),
                actual: String(actual.sampleRate)
            )
        }
        guard actual.channelCount == expected.channelCount else {
            throw compressedAACMismatch(
                field: "channel count",
                expected: String(expected.channelCount),
                actual: String(actual.channelCount)
            )
        }
        guard actual.codecConfigurationMagicCookie
            == expected.codecConfigurationMagicCookie else {
            throw compressedAACMismatch(
                field: "codec configuration magic cookie",
                expected: dataIdentityDescription(expected.codecConfigurationMagicCookie),
                actual: dataIdentityDescription(actual.codecConfigurationMagicCookie)
            )
        }
        guard actual.channelLayout == expected.channelLayout else {
            throw compressedAACMismatch(
                field: "channel layout",
                expected: String(describing: expected.channelLayout),
                actual: String(describing: actual.channelLayout)
            )
        }
        try verifySemanticTimeRange(
            actual.trackTimeRange,
            expected: expected.trackTimeRange,
            field: "track time range"
        )
        guard actual.samples.count == expected.samples.count else {
            throw compressedAACMismatch(
                field: "compressed AAC access-unit count",
                expected: String(expected.samples.count),
                actual: String(actual.samples.count)
            )
        }
        for index in expected.samples.indices {
            let actualSample = actual.samples[index]
            let expectedSample = expected.samples[index]
            try verifySemanticTime(
                actualSample.presentationTime,
                expected: expectedSample.presentationTime,
                field: "access unit \(index) presentation time"
            )
            try verifySemanticTime(
                actualSample.decodeTime,
                expected: expectedSample.decodeTime,
                field: "access unit \(index) decode time"
            )
            try verifySemanticTime(
                actualSample.duration,
                expected: expectedSample.duration,
                field: "access unit \(index) duration"
            )
            guard actualSample.sampleCount == expectedSample.sampleCount else {
                throw compressedAACMismatch(
                    field: "access unit \(index) contained sample count",
                    expected: String(expectedSample.sampleCount),
                    actual: String(actualSample.sampleCount)
                )
            }
            guard actualSample.payloadByteCount == expectedSample.payloadByteCount else {
                throw compressedAACMismatch(
                    field: "access unit \(index) payload byte count",
                    expected: String(expectedSample.payloadByteCount),
                    actual: String(actualSample.payloadByteCount)
                )
            }
            guard actualSample.payloadSHA256 == expectedSample.payloadSHA256 else {
                throw compressedAACMismatch(
                    field: "access unit \(index) payload SHA-256",
                    expected: expectedSample.payloadSHA256,
                    actual: actualSample.payloadSHA256
                )
            }
        }
        guard actual.canonicalSHA256 == expected.canonicalSHA256 else {
            throw compressedAACMismatch(
                field: "canonical identity SHA-256",
                expected: expected.canonicalSHA256,
                actual: actual.canonicalSHA256
            )
        }
    }

    private static func verifySemanticTimeRange(
        _ actual: CMTimeRange,
        expected: CMTimeRange,
        field: String
    ) throws {
        try verifySemanticTime(
            actual.start,
            expected: expected.start,
            field: "\(field) start"
        )
        try verifySemanticTime(
            actual.duration,
            expected: expected.duration,
            field: "\(field) duration"
        )
    }

    private static func verifySemanticTime(
        _ actual: CMTime,
        expected: CMTime,
        field: String
    ) throws {
        guard semanticTimesAreEqual(actual, expected) else {
            throw compressedAACMismatch(
                field: field,
                expected: exactTimeDescription(expected),
                actual: exactTimeDescription(actual)
            )
        }
    }

    private static func semanticTimesAreEqual(
        _ actual: CMTime,
        _ expected: CMTime
    ) -> Bool {
        guard actual.isValid == expected.isValid else {
            return false
        }
        guard actual.isValid else {
            return true
        }
        guard actual.epoch == expected.epoch else {
            return false
        }
        if actual.isNumeric, expected.isNumeric {
            return CMTimeCompare(actual, expected) == 0
        }
        if actual.isPositiveInfinity || expected.isPositiveInfinity {
            return actual.isPositiveInfinity && expected.isPositiveInfinity
        }
        if actual.isNegativeInfinity || expected.isNegativeInfinity {
            return actual.isNegativeInfinity && expected.isNegativeInfinity
        }
        if actual.isIndefinite || expected.isIndefinite {
            return actual.isIndefinite && expected.isIndefinite
        }
        return actual.value == expected.value
            && actual.timescale == expected.timescale
            && actual.flags == expected.flags
    }

    private static func compressedAACMismatch(
        field: String,
        expected: String,
        actual: String
    ) -> OutputMediaVerificationError {
        .compressedAACMismatch(
            reason: "\(field): expected \(expected), observed \(actual)"
        )
    }

    private static func exactTimeDescription(_ time: CMTime) -> String {
        "value=\(time.value),timescale=\(time.timescale),flags=\(time.flags.rawValue),epoch=\(time.epoch)"
    }

    private static func dataIdentityDescription(_ data: Data) -> String {
        let digest = SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
        return "bytes=\(data.count),sha256=\(digest)"

    }

    private static func fourCCString(_ value: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }
}
