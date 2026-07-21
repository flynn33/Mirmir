import AVFoundation
import AudioToolbox
import CoreMedia
import CryptoKit
import Foundation

struct OutputMediaAACIdentityReader: Sendable {
    private struct HeaderIdentity {
        let codec: AudioFormatID
        let sampleRate: Double
        let channelCount: UInt32
        let trackTimeRange: CMTimeRange
        let codecConfigurationMagicCookie: Data
        let channelLayout: OutputMediaAACChannelLayoutIdentity?
    }

    func read(url: URL) async throws -> OutputMediaAACIdentity {
        let asset = AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        return try await Self.read(asset: asset)
    }

    static func read(asset: AVURLAsset) async throws -> OutputMediaAACIdentity {
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
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
            formatDescriptions = try await track.load(.formatDescriptions)
            trackTimeRange = try await track.load(.timeRange)
        } catch {
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
        return try readCompressedSamples(
            asset: asset,
            track: track,
            header: header
        )
    }

    private static func readCompressedSamples(
        asset: AVURLAsset,
        track: AVAssetTrack,
        header: HeaderIdentity
    ) throws -> OutputMediaAACIdentity {
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
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

        var canonicalHasher = CanonicalAACIdentityHasher(
            codec: header.codec,
            sampleRate: header.sampleRate,
            channelCount: header.channelCount,
            codecConfigurationMagicCookie: header.codecConfigurationMagicCookie,
            channelLayout: header.channelLayout,
            trackTimeRange: header.trackTimeRange
        )
        var samples: [OutputMediaAACSampleIdentity] = []
        while let sample = output.copyNextSampleBuffer() {
            // AVFoundation can emit a terminal marker with no media samples or
            // payload. It is not part of the ordered compressed AAC sequence.
            guard CMSampleBufferGetNumSamples(sample) > 0 else {
                continue
            }
            let payload = try copyPayload(from: sample, sampleIndex: samples.count)
            let sampleIdentity = OutputMediaAACSampleIdentity(
                presentationTime: CMSampleBufferGetPresentationTimeStamp(sample),
                decodeTime: CMSampleBufferGetDecodeTimeStamp(sample),
                duration: CMSampleBufferGetDuration(sample),
                sampleCount: CMSampleBufferGetNumSamples(sample),
                payloadByteCount: payload.count,
                payloadSHA256: sha256(payload)
            )
            canonicalHasher.append(
                sample: sampleIdentity,
                payload: payload,
                index: samples.count
            )
            samples.append(sampleIdentity)
        }
        guard reader.status == .completed else {
            throw OutputMediaVerificationError.compressedAACMismatch(
                reason: reader.error.map { "compressed audio reader failed: \($0)" }
                    ?? "compressed audio reader status \(reader.status.rawValue)"
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
            canonicalSHA256: canonicalHasher.finalize(sampleCount: samples.count),
            codecConfigurationMagicCookie: header.codecConfigurationMagicCookie,
            channelLayout: header.channelLayout
        )
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
            append(Data("mirmir-output-aac-identity-v2\0".utf8))
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
            append(UInt64(bitPattern: time.value))
            append(UInt32(bitPattern: time.timescale))
            append(time.flags.rawValue)
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

    static func copyPayload(
        from sample: CMSampleBuffer,
        sampleIndex: Int
    ) throws -> Data {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sample) else {
            throw OutputMediaVerificationError.compressedAACMismatch(
                reason: "compressed sample \(sampleIndex) has no block buffer"
            )
        }
        let length = CMBlockBufferGetDataLength(blockBuffer)
        guard length > 0 else {
            throw OutputMediaVerificationError.compressedAACMismatch(
                reason: "compressed sample \(sampleIndex) has an empty payload"
            )
        }
        var payload = Data(count: length)
        let status: OSStatus = payload.withUnsafeMutableBytes { bytes in
            guard let destination = bytes.baseAddress else {
                return kCMBlockBufferBadPointerParameterErr
            }
            return CMBlockBufferCopyDataBytes(
                blockBuffer,
                atOffset: 0,
                dataLength: length,
                destination: destination
            )
        }
        guard status == kCMBlockBufferNoErr else {
            throw OutputMediaVerificationError.compressedAACMismatch(
                reason: "compressed sample \(sampleIndex) payload copy failed: \(status)"
            )
        }
        return payload
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
