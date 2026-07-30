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

struct OutputMediaAACIdentityReader: Sendable {
    struct AccessUnit {
        let identity: OutputMediaAACSampleIdentity
        let payload: Data
    }

    private struct HeaderIdentity {
        let codec: AudioFormatID
        let sampleRate: Double
        let channelCount: UInt32
        let trackTimeRange: CMTimeRange
        let codecConfigurationMagicCookie: Data
        let channelLayout: OutputMediaAACChannelLayoutIdentity?
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
        try cancellationCheck()
        let asset = AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        return try await Self.read(
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
        guard tracks.count == 1, let track = tracks.first else {
            throw OutputMediaVerificationError.compressedAACMismatch(
                reason: "expected one audio track, observed \(tracks.count)"
            )
        }

        let formatDescriptions: [CMFormatDescription]
        let trackTimeRange: CMTimeRange
        do {
            try cancellationCheck()
            formatDescriptions = try await track.load(.formatDescriptions)
            try cancellationCheck()
            trackTimeRange = try await track.load(.timeRange)
            try cancellationCheck()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try cancellationCheck()
            throw OutputMediaVerificationError.compressedAACMismatch(
                reason: "audio format loading failed: \(error)"
            )
        }
        guard formatDescriptions.count == 1,
              let formatDescription = formatDescriptions.first,
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(
                formatDescription
              )?.pointee else {
            throw OutputMediaVerificationError.compressedAACMismatch(
                reason: "expected one audio stream description, observed "
                    + "\(formatDescriptions.count)"
            )
        }
        let codec = CMFormatDescriptionGetMediaSubType(formatDescription)
        guard codec == kAudioFormatMPEG4AAC,
              streamDescription.mFormatID == kAudioFormatMPEG4AAC else {
            throw OutputMediaVerificationError.compressedAACMismatch(
                reason: "audio codec is subtype=\(fourCCString(codec)), "
                    + "stream=\(fourCCString(streamDescription.mFormatID)); expected aac "
                    + "(\(fourCCString(kAudioFormatMPEG4AAC)))"
            )
        }
        let header = HeaderIdentity(
            codec: codec,
            sampleRate: streamDescription.mSampleRate,
            channelCount: streamDescription.mChannelsPerFrame,
            trackTimeRange: trackTimeRange,
            codecConfigurationMagicCookie: try copyCodecConfigurationMagicCookie(
                from: formatDescription
            ),
            channelLayout: try readChannelLayoutIdentity(from: formatDescription)
        )
        return try await readCompressedSamples(
            asset: asset,
            track: track,
            header: header,
            cancellationCheck: cancellationCheck
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

// AAC header parsing, access-unit parsing, and canonical hashing are one contract.
// swiftlint:disable:this file_length
