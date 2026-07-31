import AudioToolbox
import AVFoundation
import CoreMedia
import CryptoKit
import Foundation

// Exact ALAC configuration and packet identity form one reviewable contract.
// swiftlint:disable file_length type_body_length

enum OutputMediaAppleLosslessIdentityError:
    Error,
    CustomStringConvertible {
    case unsupportedRepresentation(
        trackOrdinal: Int,
        formatOrdinal: Int?,
        reason: String,
        remediation: String
    )
    case identityUnavailable(
        trackOrdinal: Int,
        reason: String
    )

    var description: String {
        switch self {
        case .unsupportedRepresentation(
            let trackOrdinal,
            let formatOrdinal,
            let reason,
            let remediation
        ):
            let format = formatOrdinal.map {
                " format \($0 + 1)"
            } ?? ""
            return "Audio track \(trackOrdinal + 1)\(format) uses "
                + "Apple Lossless (alac), but \(reason). \(remediation)"
        case .identityUnavailable(let trackOrdinal, let reason):
            return "Audio track \(trackOrdinal + 1) uses Apple Lossless "
                + "(alac), but its exact sample-copy identity could not "
                + "be established (\(reason)). Use a valid Apple "
                + "Lossless source or turn off Preserve Source Audio "
                + "Tracks for this job."
        }
    }
}

struct OutputMediaAppleLosslessFormatIdentity:
    Sendable,
    Equatable {
    let mediaSubtype: FourCharCode
    let sampleRateBitPattern: UInt64
    let formatID: AudioFormatID
    let formatFlags: AudioFormatFlags
    let bytesPerPacket: UInt32
    let framesPerPacket: UInt32
    let bytesPerFrame: UInt32
    let channelsPerFrame: UInt32
    let bitsPerChannel: UInt32
    let reserved: UInt32
    let codecConfigurationMagicCookie: Data
    let channelLayout: OutputMediaAACChannelLayoutIdentity?

    var sampleRate: Double {
        Double(bitPattern: sampleRateBitPattern)
    }
}

struct OutputMediaAppleLosslessTrackIdentity:
    @unchecked Sendable,
    Equatable {
    let formats: [OutputMediaAppleLosslessFormatIdentity]
    let trackTimeRange: CMTimeRange
    let sampleIdentity: OutputMediaTrackSampleIdentity
    let canonicalSHA256: String
}

enum OutputMediaAppleLosslessIdentityReader {
    static func read(
        url: URL,
        cancellationCheck: @escaping @Sendable () throws -> Void = {
            try Task.checkCancellation()
        }
    ) async throws -> OutputMediaAppleLosslessTrackIdentity {
        try cancellationCheck()
        let asset = AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
            try cancellationCheck()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw identityUnavailable(
                0,
                "audio track loading failed: \(error)"
            )
        }
        guard tracks.count == 1, let track = tracks.first else {
            throw identityUnavailable(
                0,
                "expected one audio track, observed \(tracks.count)"
            )
        }
        return try await readTrack(
            asset: asset,
            track: track,
            ordinal: 0,
            cancellationCheck: cancellationCheck
        )
    }

    static func readTrack(
        asset: AVURLAsset,
        track: AVAssetTrack,
        ordinal: Int,
        cancellationCheck: @escaping @Sendable () throws -> Void
    ) async throws -> OutputMediaAppleLosslessTrackIdentity {
        let formatDescriptions: [CMFormatDescription]
        let trackTimeRange: CMTimeRange
        do {
            try cancellationCheck()
            formatDescriptions = try await track.load(
                .formatDescriptions
            )
            try cancellationCheck()
            trackTimeRange = try await track.load(.timeRange)
            try cancellationCheck()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw identityUnavailable(
                ordinal,
                "track property loading failed: \(error)"
            )
        }

        let formats = try formatIdentities(
            formatDescriptions,
            trackOrdinal: ordinal
        )
        guard let stableFormat = formats.first else {
            throw unsupported(
                ordinal,
                nil,
                "the track has no audio format description",
                "Rewrite the track with a declared Apple Lossless "
                    + "format description."
            )
        }
        guard formats.dropFirst().allSatisfy({
            $0 == stableFormat
        }) else {
            throw unsupported(
                ordinal,
                nil,
                "its ASBD, codec configuration, or channel layout "
                    + "changes within one track",
                "Split each stable Apple Lossless representation into "
                    + "a separate track before processing."
            )
        }

        let sampleIdentity: OutputMediaTrackSampleIdentity
        do {
            sampleIdentity =
                try await MediaPreservationTrackSampleIdentityReader
                .read(
                    asset: asset,
                    track: track,
                    cancellationCheck: cancellationCheck
                )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw identityUnavailable(
                ordinal,
                "compressed packet inspection failed: \(error)"
            )
        }
        guard sampleIdentity.sampleCount > 0 else {
            throw identityUnavailable(
                ordinal,
                "the track contains no Apple Lossless packets"
            )
        }
        try cancellationCheck()
        return OutputMediaAppleLosslessTrackIdentity(
            formats: formats,
            trackTimeRange: trackTimeRange,
            sampleIdentity: sampleIdentity,
            canonicalSHA256: canonicalSHA256(
                formats: formats,
                trackTimeRange: trackTimeRange,
                sampleIdentity: sampleIdentity
            )
        )
    }

    static func formatIdentities(
        _ descriptions: [CMFormatDescription],
        trackOrdinal: Int
    ) throws -> [OutputMediaAppleLosslessFormatIdentity] {
        guard !descriptions.isEmpty else {
            throw unsupported(
                trackOrdinal,
                nil,
                "the track has no audio format description",
                "Rewrite the track with a declared Apple Lossless "
                    + "format description."
            )
        }
        return try descriptions.enumerated().map { entry in
            try formatIdentity(
                entry.element,
                trackOrdinal: trackOrdinal,
                formatOrdinal: entry.offset
            )
        }
    }

    private static func formatIdentity(
        _ description: CMFormatDescription,
        trackOrdinal: Int,
        formatOrdinal: Int
    ) throws -> OutputMediaAppleLosslessFormatIdentity {
        let mediaSubtype = CMFormatDescriptionGetMediaSubType(
            description
        )
        guard CMFormatDescriptionGetMediaType(description)
                == kCMMediaType_Audio,
              let streamPointer =
                CMAudioFormatDescriptionGetStreamBasicDescription(
                    description
                ) else {
            throw unsupported(
                trackOrdinal,
                formatOrdinal,
                "its Core Media format description has no ASBD",
                "Rewrite the source with an explicit Apple Lossless "
                    + "audio format description."
            )
        }
        let stream = streamPointer.pointee
        try validate(
            stream,
            mediaSubtype: mediaSubtype,
            trackOrdinal: trackOrdinal,
            formatOrdinal: formatOrdinal
        )
        return OutputMediaAppleLosslessFormatIdentity(
            mediaSubtype: mediaSubtype,
            sampleRateBitPattern: stream.mSampleRate.bitPattern,
            formatID: stream.mFormatID,
            formatFlags: stream.mFormatFlags,
            bytesPerPacket: stream.mBytesPerPacket,
            framesPerPacket: stream.mFramesPerPacket,
            bytesPerFrame: stream.mBytesPerFrame,
            channelsPerFrame: stream.mChannelsPerFrame,
            bitsPerChannel: stream.mBitsPerChannel,
            reserved: stream.mReserved,
            codecConfigurationMagicCookie:
                try codecConfigurationMagicCookie(
                    from: description,
                    trackOrdinal: trackOrdinal,
                    formatOrdinal: formatOrdinal
                ),
            channelLayout: try channelLayoutIdentity(
                from: description,
                trackOrdinal: trackOrdinal,
                formatOrdinal: formatOrdinal
            )
        )
    }

    private static func validate(
        _ stream: AudioStreamBasicDescription,
        mediaSubtype: FourCharCode,
        trackOrdinal: Int,
        formatOrdinal: Int
    ) throws {
        guard mediaSubtype == kAudioFormatAppleLossless,
              stream.mFormatID == kAudioFormatAppleLossless else {
            throw unsupported(
                trackOrdinal,
                formatOrdinal,
                "its subtype or ASBD format ID is not alac",
                "Use an Apple Lossless source representation."
            )
        }
        guard stream.mSampleRate.isFinite,
              stream.mSampleRate > 0 else {
            throw unsupported(
                trackOrdinal,
                formatOrdinal,
                "its ASBD sample rate is not a positive finite value",
                "Rewrite the track with an explicit positive sample "
                    + "rate."
            )
        }
        guard stream.mChannelsPerFrame > 0 else {
            throw unsupported(
                trackOrdinal,
                formatOrdinal,
                "its ASBD declares zero channels",
                "Rewrite the track with at least one declared channel."
            )
        }
        guard stream.mFramesPerPacket > 0 else {
            throw unsupported(
                trackOrdinal,
                formatOrdinal,
                "its ASBD declares zero frames per packet",
                "Rewrite the track with a valid Apple Lossless packet "
                    + "size."
            )
        }
        let supportedFlags: Set<AudioFormatFlags> = [
            kAppleLosslessFormatFlag_16BitSourceData,
            kAppleLosslessFormatFlag_20BitSourceData,
            kAppleLosslessFormatFlag_24BitSourceData,
            kAppleLosslessFormatFlag_32BitSourceData
        ]
        guard supportedFlags.contains(stream.mFormatFlags) else {
            throw unsupported(
                trackOrdinal,
                formatOrdinal,
                "its ASBD source-bit-depth flag is "
                    + "\(stream.mFormatFlags), outside the four Apple "
                    + "Lossless source representations",
                "Rewrite the track as 16-, 20-, 24-, or 32-bit Apple "
                    + "Lossless audio."
            )
        }
    }

    private static func codecConfigurationMagicCookie(
        from description: CMFormatDescription,
        trackOrdinal: Int,
        formatOrdinal: Int
    ) throws -> Data {
        var byteCount = 0
        guard let bytes = CMAudioFormatDescriptionGetMagicCookie(
            description,
            sizeOut: &byteCount
        ), byteCount > 0 else {
            throw unsupported(
                trackOrdinal,
                formatOrdinal,
                "its format description has no ALAC codec "
                    + "configuration magic cookie",
                "Rewrite the source with a complete Apple Lossless "
                    + "codec configuration."
            )
        }
        return Data(bytes: bytes, count: byteCount)
    }

    private static func channelLayoutIdentity(
        from description: CMFormatDescription,
        trackOrdinal: Int,
        formatOrdinal: Int
    ) throws -> OutputMediaAACChannelLayoutIdentity? {
        var byteCount = 0
        guard let layout = CMAudioFormatDescriptionGetChannelLayout(
            description,
            sizeOut: &byteCount
        ) else {
            guard byteCount == 0 else {
                throw unsupported(
                    trackOrdinal,
                    formatOrdinal,
                    "its channel layout is missing while reporting "
                        + "\(byteCount) layout bytes",
                    "Rewrite the track with a valid channel layout."
                )
            }
            return nil
        }
        let descriptionOffset = MemoryLayout<AudioChannelLayout>.size
            - MemoryLayout<AudioChannelDescription>.size
        let descriptionSize =
            MemoryLayout<AudioChannelDescription>.stride
        let descriptionCount = Int(
            layout.pointee.mNumberChannelDescriptions
        )
        guard byteCount >= descriptionOffset,
              descriptionCount <= (byteCount - descriptionOffset)
                / descriptionSize else {
            throw unsupported(
                trackOrdinal,
                formatOrdinal,
                "its \(byteCount)-byte channel layout cannot contain "
                    + "\(descriptionCount) channel descriptions",
                "Rewrite the track with a valid channel layout."
            )
        }
        let firstDescription = UnsafeRawPointer(layout)
            .advanced(by: descriptionOffset)
            .assumingMemoryBound(
                to: AudioChannelDescription.self
            )
        let descriptions = (0..<descriptionCount).map { index in
            let channel = firstDescription
                .advanced(by: index).pointee
            return OutputMediaAACChannelDescriptionIdentity(
                label: channel.mChannelLabel,
                flags: channel.mChannelFlags.rawValue,
                coordinateBitPatterns: [
                    channel.mCoordinates.0.bitPattern,
                    channel.mCoordinates.1.bitPattern,
                    channel.mCoordinates.2.bitPattern
                ]
            )
        }
        return OutputMediaAACChannelLayoutIdentity(
            layoutTag: layout.pointee.mChannelLayoutTag,
            channelBitmap: layout.pointee.mChannelBitmap.rawValue,
            channelDescriptions: descriptions
        )
    }

    private static func canonicalSHA256(
        formats: [OutputMediaAppleLosslessFormatIdentity],
        trackTimeRange: CMTimeRange,
        sampleIdentity: OutputMediaTrackSampleIdentity
    ) -> String {
        var encoder = AppleLosslessCanonicalEncoder()
        encoder.append("mirmir-apple-lossless-track-identity-v1")
        encoder.append(UInt64(formats.count))
        for format in formats {
            encoder.append(format)
        }
        encoder.append(trackTimeRange.start)
        encoder.append(trackTimeRange.duration)
        encoder.append(Int64(sampleIdentity.sampleCount))
        encoder.append(sampleIdentity.totalPayloadByteCount)
        encoder.append(sampleIdentity.canonicalSHA256)
        return encoder.sha256
    }

    private static func unsupported(
        _ trackOrdinal: Int,
        _ formatOrdinal: Int?,
        _ reason: String,
        _ remediation: String
    ) -> OutputMediaAppleLosslessIdentityError {
        .unsupportedRepresentation(
            trackOrdinal: trackOrdinal,
            formatOrdinal: formatOrdinal,
            reason: reason,
            remediation: remediation
        )
    }

    private static func identityUnavailable(
        _ trackOrdinal: Int,
        _ reason: String
    ) -> OutputMediaAppleLosslessIdentityError {
        .identityUnavailable(
            trackOrdinal: trackOrdinal,
            reason: reason
        )
    }
}

private struct AppleLosslessCanonicalEncoder {
    private var hasher = SHA256()

    var sha256: String {
        hasher.finalize().map {
            String(format: "%02x", $0)
        }.joined()
    }

    mutating func append(
        _ format: OutputMediaAppleLosslessFormatIdentity
    ) {
        append(format.mediaSubtype)
        append(format.sampleRateBitPattern)
        append(format.formatID)
        append(format.formatFlags)
        append(format.bytesPerPacket)
        append(format.framesPerPacket)
        append(format.bytesPerFrame)
        append(format.channelsPerFrame)
        append(format.bitsPerChannel)
        append(format.reserved)
        append(UInt64(format.codecConfigurationMagicCookie.count))
        hasher.update(data: format.codecConfigurationMagicCookie)
        guard let layout = format.channelLayout else {
            append(UInt8(0))
            return
        }
        append(UInt8(1))
        append(layout.layoutTag)
        append(layout.channelBitmap)
        append(UInt64(layout.channelDescriptions.count))
        for channel in layout.channelDescriptions {
            append(channel.label)
            append(channel.flags)
            append(UInt64(channel.coordinateBitPatterns.count))
            for coordinate in channel.coordinateBitPatterns {
                append(coordinate)
            }
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

    mutating func append(_ value: String) {
        let data = Data(value.utf8)
        append(UInt64(data.count))
        hasher.update(data: data)
    }

    mutating func append<T: FixedWidthInteger>(_ value: T) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) {
            hasher.update(bufferPointer: $0)
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

// swiftlint:enable file_length type_body_length
