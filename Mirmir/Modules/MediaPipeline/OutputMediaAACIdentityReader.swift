import AVFoundation
import AudioToolbox
import CoreMedia
import CryptoKit
import Foundation

private final class OutputMediaAACReaderCancellation: @unchecked Sendable {
    private let reader: AVAssetReader

    init(reader: AVAssetReader) {
        self.reader = reader
    }

    func cancel() {
        reader.cancelReading()
    }
}

struct OutputMediaAACTrackIdentity:
    @unchecked Sendable,
    Equatable {
    let reference: OutputMediaTrackReference
    let compressedIdentity: OutputMediaAACIdentity
    let isEnabled: Bool
    let languageCode: String?
    let extendedLanguageTag: String?
    let metadata: OutputMediaMetadataIdentity
}

struct OutputMediaAACIdentityReader: Sendable {
    struct AccessUnit {
        let identity: OutputMediaAACSampleIdentity
        let payload: Data
    }

    private struct FormatIdentity: Equatable {
        let codec: AudioFormatID
        let sampleRate: Double
        let channelCount: UInt32
        let codecConfigurationMagicCookie: Data
        let channelLayout: OutputMediaAACChannelLayoutIdentity?
    }

    private struct HeaderIdentity {
        let format: FormatIdentity
        let trackTimeRange: CMTimeRange

        var codec: AudioFormatID { format.codec }
        var sampleRate: Double { format.sampleRate }
        var channelCount: UInt32 { format.channelCount }
        var codecConfigurationMagicCookie: Data {
            format.codecConfigurationMagicCookie
        }
        var channelLayout: OutputMediaAACChannelLayoutIdentity? {
            format.channelLayout
        }
    }

    func read(url: URL) async throws -> OutputMediaAACIdentity {
        try await read(
            url: url,
            cancellationCheck: {
                try Task.checkCancellation()
            }
        )
    }

    func read(
        url: URL,
        cancellationCheck: @escaping @Sendable () throws -> Void
    ) async throws -> OutputMediaAACIdentity {
        let tracks = try await readAll(
            url: url,
            cancellationCheck: cancellationCheck
        )
        guard tracks.count == 1, let track = tracks.first else {
            throw OutputMediaVerificationError.compressedAACMismatch(
                reason: "expected one audio track, observed \(tracks.count)"
            )
        }
        return track.compressedIdentity
    }

    func readAll(
        url: URL
    ) async throws -> [OutputMediaAACTrackIdentity] {
        try await readAll(
            url: url,
            cancellationCheck: {
                try Task.checkCancellation()
            }
        )
    }

    func readAll(
        url: URL,
        cancellationCheck: @escaping @Sendable () throws -> Void
    ) async throws -> [OutputMediaAACTrackIdentity] {
        try cancellationCheck()
        let asset = AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        return try await Self.readAll(
            asset: asset,
            cancellationCheck: cancellationCheck
        )
    }

    static func read(asset: AVURLAsset) async throws -> OutputMediaAACIdentity {
        try await read(
            asset: asset,
            cancellationCheck: {
                try Task.checkCancellation()
            }
        )
    }

    static func read(
        asset: AVURLAsset,
        cancellationCheck: @escaping @Sendable () throws -> Void
    ) async throws -> OutputMediaAACIdentity {
        let tracks = try await readAll(
            asset: asset,
            cancellationCheck: cancellationCheck
        )
        guard tracks.count == 1, let track = tracks.first else {
            throw OutputMediaVerificationError.compressedAACMismatch(
                reason: "expected one audio track, observed \(tracks.count)"
            )
        }
        return track.compressedIdentity
    }

    static func readAll(
        asset: AVURLAsset
    ) async throws -> [OutputMediaAACTrackIdentity] {
        try await readAll(
            asset: asset,
            cancellationCheck: {
                try Task.checkCancellation()
            }
        )
    }

    static func readAll(
        asset: AVURLAsset,
        cancellationCheck: @escaping @Sendable () throws -> Void
    ) async throws -> [OutputMediaAACTrackIdentity] {
        let tracks: [AVAssetTrack]
        do {
            try cancellationCheck()
            tracks = try await asset.loadTracks(withMediaType: .audio)
            try cancellationCheck()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try cancellationCheck()
            throw OutputMediaVerificationError.compressedAACMismatch(
                reason: "audio track loading failed: \(error)"
            )
        }
        var identities: [OutputMediaAACTrackIdentity] = []
        identities.reserveCapacity(tracks.count)
        for (ordinal, track) in tracks.enumerated() {
            try cancellationCheck()
            identities.append(
                try await readTrack(
                    asset: asset,
                    track: track,
                    ordinal: ordinal,
                    cancellationCheck: cancellationCheck
                )
            )
        }
        try cancellationCheck()
        return identities
    }

    static func readTracks(
        asset: AVURLAsset,
        references: [OutputMediaTrackReference],
        cancellationCheck: @escaping @Sendable () throws -> Void
    ) async throws -> [OutputMediaAACTrackIdentity] {
        guard !references.isEmpty else {
            try cancellationCheck()
            return []
        }
        let tracks: [AVAssetTrack]
        do {
            try cancellationCheck()
            tracks = try await asset.loadTracks(
                withMediaType: .audio
            )
            try cancellationCheck()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw OutputMediaVerificationError.compressedAACMismatch(
                reason: "selected AAC track loading failed: \(error)"
            )
        }
        var seenOrdinals: Set<Int> = []
        var identities: [OutputMediaAACTrackIdentity] = []
        identities.reserveCapacity(references.count)
        for reference in references {
            guard reference.mediaType
                    == AVMediaType.audio.rawValue else {
                throw OutputMediaVerificationError
                    .compressedAACMismatch(
                        reason: "selected AAC reference "
                            + "\(reference) is not an audio track"
                    )
            }
            guard tracks.indices.contains(reference.ordinal) else {
                throw OutputMediaVerificationError
                    .compressedAACMismatch(
                        reason: "selected AAC reference "
                            + "\(reference) is absent from "
                            + "\(tracks.count) reopened audio tracks"
                    )
            }
            guard seenOrdinals.insert(reference.ordinal).inserted else {
                throw OutputMediaVerificationError
                    .compressedAACMismatch(
                        reason: "selected AAC reference "
                            + "\(reference) is duplicated"
                    )
            }
            identities.append(
                try await readTrack(
                    asset: asset,
                    track: tracks[reference.ordinal],
                    ordinal: reference.ordinal,
                    cancellationCheck: cancellationCheck
                )
            )
        }
        try cancellationCheck()
        return identities
    }

    static func readTrack(
        asset: AVURLAsset,
        track: AVAssetTrack,
        ordinal: Int,
        cancellationCheck: @escaping @Sendable () throws -> Void
    ) async throws -> OutputMediaAACTrackIdentity {
        let formatDescriptions: [CMFormatDescription]
        let trackTimeRange: CMTimeRange
        let isEnabled: Bool
        let languageCode: String?
        let extendedLanguageTag: String?
        let metadataItems: [AVMetadataItem]
        do {
            try cancellationCheck()
            formatDescriptions = try await track.load(.formatDescriptions)
            try cancellationCheck()
            trackTimeRange = try await track.load(.timeRange)
            try cancellationCheck()
            isEnabled = try await track.load(.isEnabled)
            try cancellationCheck()
            languageCode = try await track.load(.languageCode)
            try cancellationCheck()
            extendedLanguageTag = try await track.load(
                .extendedLanguageTag
            )
            try cancellationCheck()
            metadataItems = try await track.load(.metadata)
            try cancellationCheck()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try cancellationCheck()
            throw OutputMediaVerificationError.compressedAACMismatch(
                reason: "audio track \(ordinal) property loading failed: "
                    + "\(error)"
            )
        }
        guard !formatDescriptions.isEmpty else {
            throw OutputMediaVerificationError.compressedAACMismatch(
                reason: "audio track \(ordinal) has no format description"
            )
        }
        var formatIdentities: [FormatIdentity] = []
        formatIdentities.reserveCapacity(formatDescriptions.count)
        for (formatOrdinal, formatDescription) in
            formatDescriptions.enumerated() {
            try cancellationCheck()
            formatIdentities.append(
                try formatIdentity(
                    formatDescription,
                    trackOrdinal: ordinal,
                    formatOrdinal: formatOrdinal
                )
            )
        }
        guard let formatIdentity = formatIdentities.first,
              formatIdentities.dropFirst().allSatisfy({
                  $0 == formatIdentity
              }) else {
            throw OutputMediaVerificationError.compressedAACMismatch(
                reason: "audio track \(ordinal) changes AAC configuration "
                    + "across \(formatDescriptions.count) format descriptions"
            )
        }
        let header = HeaderIdentity(
            format: formatIdentity,
            trackTimeRange: trackTimeRange
        )
        let compressedIdentity = try await readCompressedSamples(
            asset: asset,
            track: track,
            header: header,
            cancellationCheck: cancellationCheck
        )
        let metadata: OutputMediaMetadataIdentity
        do {
            metadata =
                try await MediaPreservationMetadataIdentityReader.read(
                    metadataItems
                )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw OutputMediaVerificationError.compressedAACMismatch(
                reason: "audio track \(ordinal) metadata identity failed: "
                    + "\(error)"
            )
        }
        try cancellationCheck()
        return OutputMediaAACTrackIdentity(
            reference: OutputMediaTrackReference(
                mediaType: AVMediaType.audio.rawValue,
                ordinal: ordinal
            ),
            compressedIdentity: compressedIdentity,
            isEnabled: isEnabled,
            languageCode: languageCode,
            extendedLanguageTag: extendedLanguageTag,
            metadata: metadata
        )
    }

    private static func formatIdentity(
        _ formatDescription: CMFormatDescription,
        trackOrdinal: Int,
        formatOrdinal: Int
    ) throws -> FormatIdentity {
        let codec = CMFormatDescriptionGetMediaSubType(
            formatDescription
        )
        guard CMFormatDescriptionGetMediaType(formatDescription)
                == kCMMediaType_Audio,
              let streamDescription =
                CMAudioFormatDescriptionGetStreamBasicDescription(
                    formatDescription
                )?.pointee else {
            throw OutputMediaVerificationError.compressedAACMismatch(
                reason: "audio track \(trackOrdinal) format "
                    + "\(formatOrdinal) has no audio stream description"
            )
        }
        guard codec == kAudioFormatMPEG4AAC,
              streamDescription.mFormatID
                == kAudioFormatMPEG4AAC else {
            throw OutputMediaVerificationError.compressedAACMismatch(
                reason: "audio track \(trackOrdinal) format "
                    + "\(formatOrdinal) codec is subtype="
                    + "\(fourCCString(codec)), stream="
                    + "\(fourCCString(streamDescription.mFormatID)); "
                    + "expected aac "
                    + "(\(fourCCString(kAudioFormatMPEG4AAC)))"
            )
        }
        return FormatIdentity(
            codec: codec,
            sampleRate: streamDescription.mSampleRate,
            channelCount: streamDescription.mChannelsPerFrame,
            codecConfigurationMagicCookie:
                try copyCodecConfigurationMagicCookie(
                    from: formatDescription
                ),
            channelLayout: try readChannelLayoutIdentity(
                from: formatDescription
            )
        )
    }

    private static func readCompressedSamples(
        asset: AVURLAsset,
        track: AVAssetTrack,
        header: HeaderIdentity,
        cancellationCheck: @escaping @Sendable () throws -> Void
    ) async throws -> OutputMediaAACIdentity {
        let reader: AVAssetReader
        do {
            try cancellationCheck()
            reader = try AVAssetReader(asset: asset)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try cancellationCheck()
            throw OutputMediaVerificationError.compressedAACMismatch(
                reason: "compressed audio reader creation failed: \(error)"
            )
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw OutputMediaVerificationError.compressedAACMismatch(
                reason: "reader rejected compressed AAC output"
            )
        }
        reader.add(output)
        guard reader.startReading() else {
            throw OutputMediaVerificationError.compressedAACMismatch(
                reason: reader.error.map { "compressed audio reader did not start: \($0)" }
                    ?? "compressed audio reader did not start"
            )
        }

        let cancellation = OutputMediaAACReaderCancellation(reader: reader)
        return try await withTaskCancellationHandler {
            do {
                var canonicalHasher = CanonicalAACIdentityHasher(
                    codec: header.codec,
                    sampleRate: header.sampleRate,
                    channelCount: header.channelCount,
                    codecConfigurationMagicCookie: header.codecConfigurationMagicCookie,
                    channelLayout: header.channelLayout,
                    trackTimeRange: header.trackTimeRange
                )
                var samples: [OutputMediaAACSampleIdentity] = []
                while true {
                    try cancellationCheck()
                    guard let sampleBuffer = output.copyNextSampleBuffer() else {
                        break
                    }
                    try cancellationCheck()
                    // AVFoundation can emit a terminal marker with no media
                    // samples or payload. It is not part of the compressed
                    // AAC access-unit sequence.
                    guard CMSampleBufferGetNumSamples(sampleBuffer) > 0 else {
                        continue
                    }
                    let accessUnits = try accessUnits(
                        from: sampleBuffer,
                        startingAt: samples.count
                    )
                    for accessUnit in accessUnits {
                        try cancellationCheck()
                        canonicalHasher.append(
                            sample: accessUnit.identity,
                            payload: accessUnit.payload,
                            index: samples.count
                        )
                        samples.append(accessUnit.identity)
                    }
                }
                try cancellationCheck()
                guard reader.status == .completed else {
                    throw OutputMediaVerificationError.compressedAACMismatch(
                        reason: reader.error.map {
                            "compressed audio reader failed: \($0)"
                        } ?? "compressed audio reader status \(reader.status.rawValue)"
                    )
                }
                guard !samples.isEmpty else {
                    throw OutputMediaVerificationError.compressedAACMismatch(
                        reason: "audio track contains no compressed AAC samples"
                    )
                }

                return OutputMediaAACIdentity(
                    codec: header.codec,
                    sampleRate: header.sampleRate,
                    channelCount: header.channelCount,
                    trackTimeRange: header.trackTimeRange,
                    samples: samples,
                    canonicalSHA256: canonicalHasher.finalize(
                        sampleCount: samples.count
                    ),
                    codecConfigurationMagicCookie:
                        header.codecConfigurationMagicCookie,
                    channelLayout: header.channelLayout
                )
            } catch is CancellationError {
                cancellation.cancel()
                throw CancellationError()
            } catch {
                try cancellationCheck()
                throw error
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
}

extension OutputMediaAACIdentityReader {
    struct CanonicalAACIdentityHasher {
        private var hasher = SHA256()

        init(
            codec: AudioFormatID,
            sampleRate: Double,
            channelCount: UInt32,
            codecConfigurationMagicCookie: Data,
            channelLayout: OutputMediaAACChannelLayoutIdentity?,
            trackTimeRange: CMTimeRange
        ) {
            append(Data("mirmir-output-aac-identity-v3\0".utf8))
            append(codec)
            append(sampleRate.bitPattern)
            append(channelCount)
            append(UInt64(codecConfigurationMagicCookie.count))
            append(codecConfigurationMagicCookie)
            append(channelLayout)
            append(trackTimeRange.start)
            append(trackTimeRange.duration)
        }

        mutating func append(
            sample: OutputMediaAACSampleIdentity,
            payload: Data,
            index: Int
        ) {
            append(UInt64(index))
            append(sample.presentationTime)
            append(sample.decodeTime)
            append(sample.duration)
            append(UInt64(sample.sampleCount))
            append(UInt64(payload.count))
            append(payload)
        }

        mutating func finalize(sampleCount: Int) -> String {
            append(UInt64(sampleCount))
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }

        private mutating func append(
            _ channelLayout: OutputMediaAACChannelLayoutIdentity?
        ) {
            guard let channelLayout else {
                append(UInt8(0))
                return
            }
            append(UInt8(1))
            append(channelLayout.layoutTag)
            append(channelLayout.channelBitmap)
            append(UInt64(channelLayout.channelDescriptions.count))
            for description in channelLayout.channelDescriptions {
                append(description.label)
                append(description.flags)
                append(UInt64(description.coordinateBitPatterns.count))
                for coordinate in description.coordinateBitPatterns {
                    append(coordinate)
                }
            }
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

        private mutating func append<T: FixedWidthInteger>(_ value: T) {
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

extension OutputMediaAACIdentityReader {
    // Bounds, partition, timing, and payload checks form one fail-closed parse.
    // swiftlint:disable:next function_body_length
    static func accessUnits(
        from sampleBuffer: CMSampleBuffer,
        startingAt firstAccessUnitIndex: Int
    ) throws -> [AccessUnit] {
        let sampleCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard sampleCount > 0 else {
            return []
        }
        guard firstAccessUnitIndex >= 0 else {
            throw OutputMediaVerificationError.compressedAACMismatch(
                reason: "compressed access-unit index cannot be negative"
            )
        }
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            throw OutputMediaVerificationError.compressedAACMismatch(
                reason: "compressed sample buffer beginning at access unit "
                    + "\(firstAccessUnitIndex) has no block buffer"
            )
        }
        let payloadLength = CMBlockBufferGetDataLength(blockBuffer)
        guard payloadLength > 0 else {
            throw OutputMediaVerificationError.compressedAACMismatch(
                reason: "compressed sample buffer beginning at access unit "
                    + "\(firstAccessUnitIndex) has an empty payload"
            )
        }

        var sampleSizes: [Int] = []
        sampleSizes.reserveCapacity(sampleCount)
        var partitionLength = 0
        for sampleIndex in 0..<sampleCount {
            let sampleSize = CMSampleBufferGetSampleSize(
                sampleBuffer,
                at: sampleIndex
            )
            guard sampleSize > 0 else {
                throw OutputMediaVerificationError.compressedAACMismatch(
                    reason: "compressed access unit "
                        + "\(firstAccessUnitIndex + sampleIndex) has an empty payload"
                )
            }
            let (nextLength, overflowed) = partitionLength.addingReportingOverflow(
                sampleSize
            )
            guard !overflowed else {
                throw OutputMediaVerificationError.compressedAACMismatch(
                    reason: "compressed sample payload partition length overflowed"
                )
            }
            partitionLength = nextLength
            sampleSizes.append(sampleSize)
        }
        guard partitionLength == payloadLength else {
            throw OutputMediaVerificationError.compressedAACMismatch(
                reason: "compressed sample payload partition is \(partitionLength) bytes; "
                    + "block buffer contains \(payloadLength) bytes"
            )
        }

        var accessUnits: [AccessUnit] = []
        accessUnits.reserveCapacity(sampleCount)
        var payloadOffset = 0
        for sampleIndex in 0..<sampleCount {
            var timing = CMSampleTimingInfo()
            let timingStatus = CMSampleBufferGetSampleTimingInfo(
                sampleBuffer,
                at: sampleIndex,
                timingInfoOut: &timing
            )
            guard timingStatus == noErr else {
                throw OutputMediaVerificationError.compressedAACMismatch(
                    reason: "compressed access unit "
                        + "\(firstAccessUnitIndex + sampleIndex) timing read failed: "
                        + "\(timingStatus)"
                )
            }

            let sampleSize = sampleSizes[sampleIndex]
            var payload = Data(count: sampleSize)
            let payloadStatus: OSStatus = payload.withUnsafeMutableBytes { bytes in
                guard let destination = bytes.baseAddress else {
                    return kCMBlockBufferBadPointerParameterErr
                }
                return CMBlockBufferCopyDataBytes(
                    blockBuffer,
                    atOffset: payloadOffset,
                    dataLength: sampleSize,
                    destination: destination
                )
            }
            guard payloadStatus == kCMBlockBufferNoErr else {
                throw OutputMediaVerificationError.compressedAACMismatch(
                    reason: "compressed access unit "
                        + "\(firstAccessUnitIndex + sampleIndex) payload copy failed: "
                        + "\(payloadStatus)"
                )
            }

            let identity = OutputMediaAACSampleIdentity(
                presentationTime: timing.presentationTimeStamp,
                decodeTime: timing.decodeTimeStamp,
                duration: timing.duration,
                sampleCount: 1,
                payloadByteCount: payload.count,
                payloadSHA256: sha256(payload)
            )
            accessUnits.append(AccessUnit(identity: identity, payload: payload))
            payloadOffset += sampleSize
        }
        return accessUnits
    }
}

private extension OutputMediaAACIdentityReader {
    static func copyCodecConfigurationMagicCookie(
        from formatDescription: CMFormatDescription
    ) throws -> Data {
        var byteCount = 0
        guard let bytes = CMAudioFormatDescriptionGetMagicCookie(
            formatDescription,
            sizeOut: &byteCount
        ), byteCount > 0 else {
            throw OutputMediaVerificationError.compressedAACMismatch(
                reason: "AAC format has no codec configuration magic cookie"
            )
        }
        return Data(bytes: bytes, count: byteCount)
    }

    static func readChannelLayoutIdentity(
        from formatDescription: CMFormatDescription
    ) throws -> OutputMediaAACChannelLayoutIdentity? {
        var byteCount = 0
        guard let layout = CMAudioFormatDescriptionGetChannelLayout(
            formatDescription,
            sizeOut: &byteCount
        ) else {
            guard byteCount == 0 else {
                throw OutputMediaVerificationError.compressedAACMismatch(
                    reason: "AAC channel layout is missing with nonzero size \(byteCount)"
                )
            }
            return nil
        }

        let descriptionOffset = MemoryLayout<AudioChannelLayout>.size
            - MemoryLayout<AudioChannelDescription>.size
        let descriptionSize = MemoryLayout<AudioChannelDescription>.stride
        let descriptionCount = Int(layout.pointee.mNumberChannelDescriptions)
        guard byteCount >= descriptionOffset,
              descriptionCount <= (byteCount - descriptionOffset) / descriptionSize else {
            throw OutputMediaVerificationError.compressedAACMismatch(
                reason: "AAC channel layout size \(byteCount) cannot contain "
                    + "\(descriptionCount) channel descriptions"
            )
        }

        let firstDescription = UnsafeRawPointer(layout)
            .advanced(by: descriptionOffset)
            .assumingMemoryBound(to: AudioChannelDescription.self)
        let descriptions = (0..<descriptionCount).map { index in
            let description = firstDescription.advanced(by: index).pointee
            return OutputMediaAACChannelDescriptionIdentity(
                label: description.mChannelLabel,
                flags: description.mChannelFlags.rawValue,
                coordinateBitPatterns: [
                    description.mCoordinates.0.bitPattern,
                    description.mCoordinates.1.bitPattern,
                    description.mCoordinates.2.bitPattern
                ]
            )
        }
        return OutputMediaAACChannelLayoutIdentity(
            layoutTag: layout.pointee.mChannelLayoutTag,
            channelBitmap: layout.pointee.mChannelBitmap.rawValue,
            channelDescriptions: descriptions
        )
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func fourCCString(_ value: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }
}

extension OutputMediaVerifier {
    static func verifyCompressedAACTracks(
        _ actual: [OutputMediaAACTrackIdentity],
        expected: [OutputMediaAACTrackIdentity]
    ) throws {
        guard actual.count == expected.count else {
            throw OutputMediaVerificationError.compressedAACMismatch(
                reason: "audio track count: expected \(expected.count), "
                    + "observed \(actual.count)"
            )
        }
        for index in expected.indices {
            let actualTrack = actual[index]
            let expectedTrack = expected[index]
            guard actualTrack.reference == expectedTrack.reference else {
                throw trackMismatch(
                    index: index,
                    field: "ordered reference",
                    expected: String(
                        describing: expectedTrack.reference
                    ),
                    actual: String(
                        describing: actualTrack.reference
                    )
                )
            }
            guard actualTrack.isEnabled == expectedTrack.isEnabled else {
                throw trackMismatch(
                    index: index,
                    field: "enabled state",
                    expected: String(expectedTrack.isEnabled),
                    actual: String(actualTrack.isEnabled)
                )
            }
            guard actualTrack.languageCode
                    == expectedTrack.languageCode else {
                throw trackMismatch(
                    index: index,
                    field: "language code",
                    expected: expectedTrack.languageCode ?? "absent",
                    actual: actualTrack.languageCode ?? "absent"
                )
            }
            guard actualTrack.extendedLanguageTag
                    == expectedTrack.extendedLanguageTag else {
                throw trackMismatch(
                    index: index,
                    field: "extended language tag",
                    expected:
                        expectedTrack.extendedLanguageTag ?? "absent",
                    actual:
                        actualTrack.extendedLanguageTag ?? "absent"
                )
            }
            guard actualTrack.metadata == expectedTrack.metadata else {
                throw trackMismatch(
                    index: index,
                    field: "metadata",
                    expected: "\(expectedTrack.metadata.canonicalItems.count) "
                        + "canonical items",
                    actual: "\(actualTrack.metadata.canonicalItems.count) "
                        + "different canonical items"
                )
            }
            do {
                try verifyCompressedAAC(
                    actualTrack.compressedIdentity,
                    expected: expectedTrack.compressedIdentity
                )
            } catch let error as OutputMediaVerificationError {
                guard case .compressedAACMismatch(let reason) = error else {
                    throw error
                }
                throw OutputMediaVerificationError.compressedAACMismatch(
                    reason: "audio track \(index) \(reason)"
                )
            }
        }
    }

    private static func trackMismatch(
        index: Int,
        field: String,
        expected: String,
        actual: String
    ) -> OutputMediaVerificationError {
        .compressedAACMismatch(
            reason: "audio track \(index) \(field): expected "
                + "\(expected), observed \(actual)"
        )
    }
}

// AAC header parsing, access-unit parsing, and canonical hashing are one contract.
// swiftlint:disable:this file_length
