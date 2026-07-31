import AudioToolbox
import AVFoundation
import CoreMedia
import CryptoKit
import Foundation

// swiftlint:disable file_length

enum OutputMediaLinearPCMIdentityError:
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
                + "Linear PCM (lpcm), but \(reason). \(remediation)"
        case .identityUnavailable(let trackOrdinal, let reason):
            return "Audio track \(trackOrdinal + 1) uses Linear PCM "
                + "(lpcm), but its exact sample-copy identity could not "
                + "be established (\(reason)). Use a valid interleaved "
                + "PCM source or turn off Preserve Source Audio Tracks "
                + "for this job."
        }
    }
}

private final class OutputMediaLinearPCMReaderCancellation:
    @unchecked Sendable {
    private let reader: AVAssetReader

    init(reader: AVAssetReader) {
        self.reader = reader
    }

    func cancel() {
        reader.cancelReading()
    }
}

enum OutputMediaLinearPCMIdentityReader {
    static func readTrack(
        asset: AVURLAsset,
        track: AVAssetTrack,
        ordinal: Int,
        cancellationCheck: @escaping @Sendable () throws -> Void
    ) async throws -> OutputMediaLinearPCMTrackIdentity {
        let formatDescriptions: [CMFormatDescription]
        do {
            try cancellationCheck()
            formatDescriptions = try await track.load(
                .formatDescriptions
            )
            try cancellationCheck()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw identityUnavailable(
                ordinal,
                "format-description loading failed: \(error)"
            )
        }
        let formats = try formatIdentities(
            formatDescriptions,
            trackOrdinal: ordinal
        )
        guard let format = formats.first else {
            throw unsupported(
                ordinal,
                nil,
                "the track has no audio format description",
                "Use a Linear PCM file with a declared ASBD, or turn "
                    + "off Preserve Source Audio Tracks for this job."
            )
        }
        guard formats.dropFirst().allSatisfy({ $0 == format }) else {
            throw unsupported(
                ordinal,
                nil,
                "its ASBD or channel layout changes within one track",
                "Split each stable PCM representation into a separate "
                    + "track before processing, or turn off Preserve "
                    + "Source Audio Tracks for this job."
            )
        }
        return try await readSamples(
            asset: asset,
            track: track,
            trackOrdinal: ordinal,
            formats: formats,
            bytesPerFrame: Int(format.bytesPerFrame),
            sampleRate: format.sampleRate,
            cancellationCheck: cancellationCheck
        )
    }

    static func formatIdentities(
        _ formatDescriptions: [CMFormatDescription],
        trackOrdinal: Int
    ) throws -> [OutputMediaLinearPCMFormatIdentity] {
        guard !formatDescriptions.isEmpty else {
            throw unsupported(
                trackOrdinal,
                nil,
                "the track has no audio format description",
                "Use a Linear PCM file with a declared ASBD, or turn "
                    + "off Preserve Source Audio Tracks for this job."
            )
        }
        return try formatDescriptions.enumerated().map { entry in
            let (formatOrdinal, description) = entry
            return try formatIdentity(
                description,
                trackOrdinal: trackOrdinal,
                formatOrdinal: formatOrdinal
            )
        }
    }

    static func validate(
        _ stream: AudioStreamBasicDescription,
        mediaSubtype: FourCharCode,
        trackOrdinal: Int,
        formatOrdinal: Int
    ) throws {
        try validateHeader(
            stream,
            mediaSubtype: mediaSubtype,
            trackOrdinal: trackOrdinal,
            formatOrdinal: formatOrdinal
        )
        let storageBitsPerChannel = try validateStorage(
            stream,
            trackOrdinal: trackOrdinal,
            formatOrdinal: formatOrdinal
        )
        try validateNumericRepresentation(
            stream,
            storageBitsPerChannel: storageBitsPerChannel,
            trackOrdinal: trackOrdinal,
            formatOrdinal: formatOrdinal
        )
    }

    private static func validateHeader(
        _ stream: AudioStreamBasicDescription,
        mediaSubtype: FourCharCode,
        trackOrdinal: Int,
        formatOrdinal: Int
    ) throws {
        guard mediaSubtype == kAudioFormatLinearPCM,
              stream.mFormatID == kAudioFormatLinearPCM else {
            throw unsupported(
                trackOrdinal,
                formatOrdinal,
                "its subtype or ASBD format ID is not lpcm",
                "Convert the track to a stable Linear PCM, Apple Lossless, "
                    + "or AAC representation before processing."
            )
        }
        guard stream.mSampleRate.isFinite,
              stream.mSampleRate > 0 else {
            throw unsupported(
                trackOrdinal,
                formatOrdinal,
                "its ASBD sample rate is not a positive finite value",
                "Rewrite the track with an explicit positive sample "
                    + "rate before processing."
            )
        }
        guard stream.mChannelsPerFrame > 0 else {
            throw unsupported(
                trackOrdinal,
                formatOrdinal,
                "its ASBD declares zero channels",
                "Rewrite the track with at least one declared channel "
                    + "before processing."
            )
        }
        guard stream.mFramesPerPacket == 1 else {
            throw unsupported(
                trackOrdinal,
                formatOrdinal,
                "its ASBD declares \(stream.mFramesPerPacket) frames "
                    + "per packet instead of one",
                "Rewrite the track as ordinary one-frame-per-packet "
                    + "Linear PCM before processing."
            )
        }
        guard stream.mBytesPerFrame > 0,
              stream.mBytesPerPacket == stream.mBytesPerFrame else {
            throw unsupported(
                trackOrdinal,
                formatOrdinal,
                "its ASBD packet and frame byte sizes are not a "
                    + "nonzero one-to-one PCM layout",
                "Rewrite the track with fixed, matching bytes-per-frame "
                    + "and bytes-per-packet values."
            )
        }
    }

    private static func validateStorage(
        _ stream: AudioStreamBasicDescription,
        trackOrdinal: Int,
        formatOrdinal: Int
    ) throws -> UInt64 {
        let nonInterleaved = stream.mFormatFlags
            & kAudioFormatFlagIsNonInterleaved != 0
        guard !nonInterleaved else {
            throw unsupported(
                trackOrdinal,
                formatOrdinal,
                "its ASBD is non-interleaved, which has no single "
                    + "file-sample payload for exact sample-copy hashing",
                "Rewrite the track as interleaved Linear PCM before "
                    + "processing."
            )
        }
        guard stream.mBytesPerFrame
                % stream.mChannelsPerFrame == 0 else {
            throw unsupported(
                trackOrdinal,
                formatOrdinal,
                "its bytes-per-frame value is not divisible by its "
                    + "channel count",
                "Rewrite the track with a complete fixed-width sample "
                    + "for every channel."
            )
        }
        let storageBitsPerChannel = UInt64(
            stream.mBytesPerFrame / stream.mChannelsPerFrame
        ) * 8
        guard stream.mBitsPerChannel > 0,
              UInt64(stream.mBitsPerChannel)
                <= storageBitsPerChannel else {
            throw unsupported(
                trackOrdinal,
                formatOrdinal,
                "its \(stream.mBitsPerChannel)-bit sample does not fit "
                    + "the declared \(storageBitsPerChannel)-bit channel "
                    + "storage",
                "Rewrite the track with consistent PCM bit depth and "
                    + "frame byte sizes."
            )
        }
        return storageBitsPerChannel
    }

    private static func validateNumericRepresentation(
        _ stream: AudioStreamBasicDescription,
        storageBitsPerChannel: UInt64,
        trackOrdinal: Int,
        formatOrdinal: Int
    ) throws {
        let isFloat =
            stream.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let isSignedInteger =
            stream.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0
        guard !(isFloat && isSignedInteger) else {
            throw unsupported(
                trackOrdinal,
                formatOrdinal,
                "its ASBD declares samples as both floating-point and "
                    + "signed integer",
                "Rewrite the track with one unambiguous PCM numeric "
                    + "representation."
            )
        }
        if isFloat {
            guard [32, 64].contains(Int(stream.mBitsPerChannel)),
                  UInt64(stream.mBitsPerChannel)
                    == storageBitsPerChannel else {
                throw unsupported(
                    trackOrdinal,
                    formatOrdinal,
                    "its floating-point samples are not packed 32-bit "
                        + "or 64-bit values",
                    "Rewrite the track as packed Float32, packed Float64, "
                        + "or integer Linear PCM."
                )
            }
        }
        guard stream.mReserved == 0 else {
            throw unsupported(
                trackOrdinal,
                formatOrdinal,
                "its ASBD reserved field is nonzero",
                "Rewrite the track with a standards-conforming Linear "
                    + "PCM format description."
            )
        }
    }
}

private extension OutputMediaLinearPCMIdentityReader {
    struct TimingRun {
        var presentationStart: CMTime
        var decodeStart: CMTime
        let frameDuration: CMTime
        var frameCount: Int64
    }

    struct SampleScanState {
        var payloadHasher = SHA256()
        var timingRuns: [TimingRun] = []
        var frameCount: Int64 = 0
        var payloadByteCount: Int64 = 0
    }

    static func formatIdentity(
        _ description: CMFormatDescription,
        trackOrdinal: Int,
        formatOrdinal: Int
    ) throws -> OutputMediaLinearPCMFormatIdentity {
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
                "Rewrite the source with an explicit Linear PCM audio "
                    + "format description."
            )
        }
        let stream = streamPointer.pointee
        try validate(
            stream,
            mediaSubtype: mediaSubtype,
            trackOrdinal: trackOrdinal,
            formatOrdinal: formatOrdinal
        )
        return OutputMediaLinearPCMFormatIdentity(
            mediaSubtype: mediaSubtype,
            sampleRateBitPattern: stream.mSampleRate.bitPattern,
            formatFlags: stream.mFormatFlags,
            bytesPerPacket: stream.mBytesPerPacket,
            framesPerPacket: stream.mFramesPerPacket,
            bytesPerFrame: stream.mBytesPerFrame,
            channelsPerFrame: stream.mChannelsPerFrame,
            bitsPerChannel: stream.mBitsPerChannel,
            channelLayout: try channelLayoutIdentity(
                from: description,
                trackOrdinal: trackOrdinal,
                formatOrdinal: formatOrdinal
            )
        )
    }

    static func channelLayoutIdentity(
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
        let count = Int(
            layout.pointee.mNumberChannelDescriptions
        )
        guard byteCount >= descriptionOffset,
              count <= (byteCount - descriptionOffset)
                / descriptionSize else {
            throw unsupported(
                trackOrdinal,
                formatOrdinal,
                "its \(byteCount)-byte channel layout cannot contain "
                    + "\(count) channel descriptions",
                "Rewrite the track with a valid channel layout."
            )
        }
        let firstDescription = UnsafeRawPointer(layout)
            .advanced(by: descriptionOffset)
            .assumingMemoryBound(
                to: AudioChannelDescription.self
            )
        let descriptions = (0..<count).map { index in
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

    static func readSamples(
        asset: AVURLAsset,
        track: AVAssetTrack,
        trackOrdinal: Int,
        formats: [OutputMediaLinearPCMFormatIdentity],
        bytesPerFrame: Int,
        sampleRate: Double,
        cancellationCheck: @escaping @Sendable () throws -> Void
    ) async throws -> OutputMediaLinearPCMTrackIdentity {
        let reader: AVAssetReader
        do {
            try cancellationCheck()
            reader = try AVAssetReader(asset: asset)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw identityUnavailable(
                trackOrdinal,
                "reader creation failed: \(error)"
            )
        }
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: nil
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw identityUnavailable(
                trackOrdinal,
                "AVAssetReader rejected sample-copy output"
            )
        }
        reader.add(output)
        guard reader.startReading() else {
            throw identityUnavailable(
                trackOrdinal,
                reader.error.map {
                    "reader did not start: \($0)"
                } ?? "reader did not start"
            )
        }
        let cancellation =
            OutputMediaLinearPCMReaderCancellation(reader: reader)
        return try await withTaskCancellationHandler {
            do {
                return try scanSamples(
                    reader: reader,
                    output: output,
                    trackOrdinal: trackOrdinal,
                    formats: formats,
                    bytesPerFrame: bytesPerFrame,
                    sampleRate: sampleRate,
                    cancellationCheck: cancellationCheck
                )
            } catch is CancellationError {
                cancellation.cancel()
                throw CancellationError()
            } catch {
                cancellation.cancel()
                throw error
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    static func scanSamples(
        reader: AVAssetReader,
        output: AVAssetReaderTrackOutput,
        trackOrdinal: Int,
        formats: [OutputMediaLinearPCMFormatIdentity],
        bytesPerFrame: Int,
        sampleRate: Double,
        cancellationCheck: () throws -> Void
    ) throws -> OutputMediaLinearPCMTrackIdentity {
        var state = SampleScanState()
        let expectedFrameDuration =
            exactFrameDuration(sampleRate: sampleRate)
        while true {
            try cancellationCheck()
            guard let sample = output.copyNextSampleBuffer() else {
                break
            }
            guard CMSampleBufferGetNumSamples(sample) > 0 else {
                continue
            }
            try appendSample(
                sample,
                bytesPerFrame: bytesPerFrame,
                expectedFrameDuration: expectedFrameDuration,
                state: &state,
                trackOrdinal: trackOrdinal
            )
        }
        try cancellationCheck()
        guard reader.status == .completed else {
            throw identityUnavailable(
                trackOrdinal,
                reader.error.map {
                    "reader failed: \($0)"
                } ?? "reader status \(reader.status.rawValue)"
            )
        }
        guard state.frameCount > 0 else {
            throw identityUnavailable(
                trackOrdinal,
                "the track contains no PCM audio frames"
            )
        }
        let payloadSHA256 = state.payloadHasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
        let canonicalRuns = state.timingRuns.map {
            OutputMediaLinearPCMTimingRunIdentity(
                presentationStart:
                    semanticTimeIdentity($0.presentationStart),
                decodeStart:
                    semanticTimeIdentity($0.decodeStart),
                frameDuration:
                    semanticTimeIdentity($0.frameDuration),
                frameCount: $0.frameCount
            )
        }
        return OutputMediaLinearPCMTrackIdentity(
            formats: formats,
            timingRuns: canonicalRuns,
            audioFrameCount: state.frameCount,
            totalPayloadByteCount: state.payloadByteCount,
            payloadSHA256: payloadSHA256,
            canonicalSHA256: canonicalSHA256(
                formats: formats,
                timingRuns: canonicalRuns,
                frameCount: state.frameCount,
                payloadByteCount: state.payloadByteCount,
                payloadSHA256: payloadSHA256
            )
        )
    }

    static func appendSample(
        _ sample: CMSampleBuffer,
        bytesPerFrame: Int,
        expectedFrameDuration: CMTime?,
        state: inout SampleScanState,
        trackOrdinal: Int
    ) throws {
        let containedFrames =
            CMSampleBufferGetNumSamples(sample)
        let frameIncrement = Int64(containedFrames)
        let (nextFrameCount, frameOverflow) =
            state.frameCount.addingReportingOverflow(
                frameIncrement
            )
        guard !frameOverflow else {
            throw identityUnavailable(
                trackOrdinal,
                "audio-frame count overflowed"
            )
        }
        let expectedPayloadLength =
            containedFrames.multipliedReportingOverflow(
                by: bytesPerFrame
            )
        guard !expectedPayloadLength.overflow else {
            throw identityUnavailable(
                trackOrdinal,
                "sample payload length overflowed"
            )
        }
        let payload = try samplePayload(
            sample,
            expectedLength: expectedPayloadLength.partialValue,
            trackOrdinal: trackOrdinal
        )
        let (nextByteCount, byteOverflow) =
            state.payloadByteCount.addingReportingOverflow(
                Int64(payload.count)
            )
        guard !byteOverflow else {
            throw identityUnavailable(
                trackOrdinal,
                "payload byte count overflowed"
            )
        }
        state.payloadHasher.update(data: payload)
        try appendTiming(
            of: sample,
            containedFrames: containedFrames,
            expectedFrameDuration: expectedFrameDuration,
            to: &state.timingRuns,
            trackOrdinal: trackOrdinal
        )
        state.frameCount = nextFrameCount
        state.payloadByteCount = nextByteCount
    }

    static func samplePayload(
        _ sample: CMSampleBuffer,
        expectedLength: Int,
        trackOrdinal: Int
    ) throws -> Data {
        guard let block = CMSampleBufferGetDataBuffer(sample) else {
            throw identityUnavailable(
                trackOrdinal,
                "a PCM sample buffer has no data block"
            )
        }
        let length = CMBlockBufferGetDataLength(block)
        guard length == expectedLength else {
            throw identityUnavailable(
                trackOrdinal,
                "a PCM sample buffer contains \(length) bytes for "
                    + "\(CMSampleBufferGetNumSamples(sample)) frames; "
                    + "its ASBD requires \(expectedLength) bytes"
            )
        }
        var payload = Data(count: length)
        let status: OSStatus =
            payload.withUnsafeMutableBytes { bytes in
                guard let destination = bytes.baseAddress else {
                    return length == 0
                        ? kCMBlockBufferNoErr
                        : kCMBlockBufferBadPointerParameterErr
                }
                return CMBlockBufferCopyDataBytes(
                    block,
                    atOffset: 0,
                    dataLength: length,
                    destination: destination
                )
            }
        guard status == kCMBlockBufferNoErr else {
            throw identityUnavailable(
                trackOrdinal,
                "PCM payload copy failed with status \(status)"
            )
        }
        return payload
    }

    static func appendTiming(
        of sample: CMSampleBuffer,
        containedFrames: Int,
        expectedFrameDuration: CMTime?,
        to runs: inout [TimingRun],
        trackOrdinal: Int
    ) throws {
        var entryCount: CMItemCount = 0
        let countStatus = CMSampleBufferGetSampleTimingInfoArray(
            sample,
            entryCount: 0,
            arrayToFill: nil,
            entriesNeededOut: &entryCount
        )
        guard countStatus == noErr, entryCount > 0 else {
            throw identityUnavailable(
                trackOrdinal,
                "PCM timing-table inspection failed with status "
                    + "\(countStatus) and \(entryCount) entries"
            )
        }
        var timings = Array(
            repeating: CMSampleTimingInfo(),
            count: entryCount
        )
        let timingStatus = timings.withUnsafeMutableBufferPointer { buffer in
            CMSampleBufferGetSampleTimingInfoArray(
                sample,
                entryCount: entryCount,
                arrayToFill: buffer.baseAddress,
                entriesNeededOut: nil
            )
        }
        guard timingStatus == noErr else {
            throw identityUnavailable(
                trackOrdinal,
                "PCM timing-table read failed with status "
                    + "\(timingStatus)"
            )
        }
        if timings.count == 1 {
            let timing = try normalizedSingleEntryTiming(
                timings[0],
                sample: sample,
                containedFrames: containedFrames,
                expectedFrameDuration: expectedFrameDuration,
                trackOrdinal: trackOrdinal
            )
            try appendTimingRun(
                timing,
                frameCount: containedFrames,
                to: &runs,
                trackOrdinal: trackOrdinal
            )
            return
        }
        guard timings.count == containedFrames else {
            throw identityUnavailable(
                trackOrdinal,
                "PCM timing table has \(timings.count) entries for "
                    + "\(containedFrames) audio frames"
            )
        }
        for timing in timings {
            if let expectedFrameDuration,
               !semanticallyEqual(
                   timing.duration,
                   expectedFrameDuration
               ) {
                throw identityUnavailable(
                    trackOrdinal,
                    "PCM per-frame duration differs from its ASBD "
                        + "sample rate"
                )
            }
            try appendTimingRun(
                timing,
                frameCount: 1,
                to: &runs,
                trackOrdinal: trackOrdinal
            )
        }
    }

    static func normalizedSingleEntryTiming(
        _ timing: CMSampleTimingInfo,
        sample: CMSampleBuffer,
        containedFrames: Int,
        expectedFrameDuration: CMTime?,
        trackOrdinal: Int
    ) throws -> CMSampleTimingInfo {
        guard containedFrames > 0,
              containedFrames <= Int(Int32.max) else {
            throw identityUnavailable(
                trackOrdinal,
                "PCM timing group has an unsupported frame count "
                    + "\(containedFrames)"
            )
        }
        var normalized = timing
        let frameMultiplier = Int32(containedFrames)
        let bufferDuration = CMSampleBufferGetDuration(sample)
        if let expectedFrameDuration {
            let expectedBufferDuration = CMTimeMultiply(
                expectedFrameDuration,
                multiplier: frameMultiplier
            )
            if semanticallyEqual(
                timing.duration,
                expectedFrameDuration
            ) {
                normalized.duration = expectedFrameDuration
            } else if semanticallyEqual(
                timing.duration,
                expectedBufferDuration
            ) {
                normalized.duration = expectedFrameDuration
            } else {
                throw identityUnavailable(
                    trackOrdinal,
                    "PCM timing duration is neither one ASBD audio "
                        + "frame nor the complete "
                        + "\(containedFrames)-frame sample buffer"
                )
            }
            if bufferDuration.isNumeric,
               !semanticallyEqual(
                   bufferDuration,
                   expectedBufferDuration
               ),
               !semanticallyEqual(
                   bufferDuration,
                   expectedFrameDuration
               ) {
                throw identityUnavailable(
                    trackOrdinal,
                    "PCM sample-buffer duration is neither one ASBD "
                        + "audio frame nor \(containedFrames) ASBD "
                        + "audio frames"
                )
            }
            return normalized
        }

        guard containedFrames == 1 else {
            guard bufferDuration.isNumeric else {
                throw identityUnavailable(
                    trackOrdinal,
                    "PCM multi-frame sample buffer has no numeric "
                        + "duration and its sample rate is not an exact "
                        + "integer timescale"
                )
            }
            if semanticallyEqual(timing.duration, bufferDuration) {
                normalized.duration = CMTimeMultiplyByRatio(
                    bufferDuration,
                    multiplier: 1,
                    divisor: frameMultiplier
                )
            } else {
                let expandedDuration = CMTimeMultiply(
                    timing.duration,
                    multiplier: frameMultiplier
                )
                guard semanticallyEqual(
                    expandedDuration,
                    bufferDuration
                ) else {
                    throw identityUnavailable(
                        trackOrdinal,
                        "PCM timing cannot be normalized independently "
                            + "of reader sample-buffer grouping"
                    )
                }
            }
            return normalized
        }
        return normalized
    }

    static func appendTimingRun(
        _ timing: CMSampleTimingInfo,
        frameCount: Int,
        to runs: inout [TimingRun],
        trackOrdinal: Int
    ) throws {
        guard frameCount > 0,
              timing.presentationTimeStamp.isNumeric,
              timing.duration.isNumeric,
              CMTimeCompare(timing.duration, .zero) > 0 else {
            throw identityUnavailable(
                trackOrdinal,
                "PCM frames do not have positive numeric duration and "
                    + "presentation timing"
            )
        }
        let increment = Int64(frameCount)
        if var last = runs.last,
           semanticallyEqual(
               last.frameDuration,
               timing.duration
           ),
           timeFollowsRun(
               timing.presentationTimeStamp,
               start: last.presentationStart,
               duration: last.frameDuration,
               frameCount: last.frameCount
           ),
           decodeTimeFollowsRun(
               timing.decodeTimeStamp,
               start: last.decodeStart,
               duration: last.frameDuration,
               frameCount: last.frameCount
           ) {
            let (nextCount, overflow) =
                last.frameCount.addingReportingOverflow(
                    increment
                )
            guard !overflow else {
                throw identityUnavailable(
                    trackOrdinal,
                    "PCM timing-run frame count overflowed"
                )
            }
            last.frameCount = nextCount
            runs[runs.count - 1] = last
            return
        }
        runs.append(TimingRun(
            presentationStart: timing.presentationTimeStamp,
            decodeStart: timing.decodeTimeStamp,
            frameDuration: timing.duration,
            frameCount: increment
        ))
    }

    static func timeFollowsRun(
        _ value: CMTime,
        start: CMTime,
        duration: CMTime,
        frameCount: Int64
    ) -> Bool {
        guard frameCount <= Int64(Int32.max) else {
            return false
        }
        let offset = CMTimeMultiply(
            duration,
            multiplier: Int32(frameCount)
        )
        return semanticallyEqual(value, CMTimeAdd(start, offset))
    }

    static func decodeTimeFollowsRun(
        _ value: CMTime,
        start: CMTime,
        duration: CMTime,
        frameCount: Int64
    ) -> Bool {
        if !value.isValid, !start.isValid {
            return true
        }
        guard value.isNumeric, start.isNumeric else {
            return false
        }
        return timeFollowsRun(
            value,
            start: start,
            duration: duration,
            frameCount: frameCount
        )
    }

    static func semanticallyEqual(
        _ lhs: CMTime,
        _ rhs: CMTime
    ) -> Bool {
        if lhs.isNumeric, rhs.isNumeric {
            return CMTimeCompare(lhs, rhs) == 0
                && lhs.epoch == rhs.epoch
        }
        return semanticTimeIdentity(lhs)
            == semanticTimeIdentity(rhs)
    }

    static func semanticTimeIdentity(
        _ time: CMTime
    ) -> OutputMediaSemanticTimeIdentity {
        let kind: OutputMediaSemanticTimeIdentity.Kind
        var value = time.value
        var timescale = UInt32(bitPattern: time.timescale)
        if !time.isValid {
            kind = .invalid
            value = 0
            timescale = 0
        } else if time.isPositiveInfinity {
            kind = .positiveInfinity
            value = 0
            timescale = 0
        } else if time.isNegativeInfinity {
            kind = .negativeInfinity
            value = 0
            timescale = 0
        } else if time.isIndefinite {
            kind = .indefinite
            value = 0
            timescale = 0
        } else if time.isNumeric, time.timescale > 0 {
            kind = .numeric
            let divisor = semanticTimeDivisor(
                value: time.value,
                timescale: time.timescale
            )
            value = time.value / divisor
            timescale = UInt32(
                Int64(time.timescale) / divisor
            )
        } else {
            kind = .other
        }
        return OutputMediaSemanticTimeIdentity(
            kind: kind,
            value: value,
            timescale: timescale,
            flags: kind == .other ? time.flags.rawValue : 0,
            epoch: time.epoch
        )
    }

    static func canonicalSHA256(
        formats: [OutputMediaLinearPCMFormatIdentity],
        timingRuns: [OutputMediaLinearPCMTimingRunIdentity],
        frameCount: Int64,
        payloadByteCount: Int64,
        payloadSHA256: String
    ) -> String {
        var encoder = LinearPCMCanonicalEncoder()
        encoder.append("mirmir-linear-pcm-track-identity-v1")
        encoder.append(UInt64(formats.count))
        for format in formats {
            encoder.append(format)
        }
        encoder.append(UInt64(timingRuns.count))
        for run in timingRuns {
            encoder.append(run)
        }
        encoder.append(frameCount)
        encoder.append(payloadByteCount)
        encoder.append(payloadSHA256)
        return encoder.sha256
    }

    static func semanticTimeDivisor(
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

    static func exactFrameDuration(
        sampleRate: Double
    ) -> CMTime? {
        let rounded = sampleRate.rounded()
        guard rounded == sampleRate,
              rounded > 0,
              rounded <= Double(Int32.max) else {
            return nil
        }
        return CMTime(
            value: 1,
            timescale: CMTimeScale(rounded)
        )
    }

    static func unsupported(
        _ trackOrdinal: Int,
        _ formatOrdinal: Int?,
        _ reason: String,
        _ remediation: String
    ) -> OutputMediaLinearPCMIdentityError {
        .unsupportedRepresentation(
            trackOrdinal: trackOrdinal,
            formatOrdinal: formatOrdinal,
            reason: reason,
            remediation: remediation
        )
    }

    static func identityUnavailable(
        _ trackOrdinal: Int,
        _ reason: String
    ) -> OutputMediaLinearPCMIdentityError {
        .identityUnavailable(
            trackOrdinal: trackOrdinal,
            reason: reason
        )
    }
}

private struct LinearPCMCanonicalEncoder {
    private var hasher = SHA256()

    var sha256: String {
        hasher.finalize().map {
            String(format: "%02x", $0)
        }.joined()
    }

    mutating func append(
        _ format: OutputMediaLinearPCMFormatIdentity
    ) {
        append(format.mediaSubtype)
        append(format.sampleRateBitPattern)
        append(format.formatFlags)
        append(format.bytesPerPacket)
        append(format.framesPerPacket)
        append(format.bytesPerFrame)
        append(format.channelsPerFrame)
        append(format.bitsPerChannel)
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

    mutating func append(
        _ run: OutputMediaLinearPCMTimingRunIdentity
    ) {
        append(run.presentationStart)
        append(run.decodeStart)
        append(run.frameDuration)
        append(run.frameCount)
    }

    mutating func append(
        _ time: OutputMediaSemanticTimeIdentity
    ) {
        append(time.kind.rawValue)
        append(time.value)
        append(time.timescale)
        append(time.flags)
        append(time.epoch)
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
}

// swiftlint:enable file_length
