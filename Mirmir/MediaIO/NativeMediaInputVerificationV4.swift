import AVFoundation
import AudioToolbox
import CoreMedia
import CoreVideo
import CryptoKit
import Foundation

enum NativeMediaInputVerificationV4 {
    private static let maximumPacketBytes = 64 * 1024 * 1024

    static func verify(
        original: AVAsset,
        derived: AVAsset,
        canonicalFormat: CMVideoFormatDescription,
        strategy: NativeMediaInputAssetResolverV4.Strategy,
        cancellation: (any NativeMediaInputCancellationV4)?
    ) async throws {
        try check(cancellation)
        guard try await derived.load(.metadata).isEmpty,
              try await derived.load(.trackGroups).isEmpty,
              try await derived.load(.availableChapterLocales).isEmpty else {
            throw failure("The normalized input added metadata, groups, or chapters.")
        }
        let sourceTracks = try await original.load(.tracks)
        let outputTracks = try await derived.load(.tracks)
        guard !sourceTracks.isEmpty, sourceTracks.count == outputTracks.count,
              sourceTracks.allSatisfy({ $0.trackID != 0 }),
              outputTracks.allSatisfy({ $0.trackID != 0 }),
              Set(sourceTracks.map(\.trackID)).count == sourceTracks.count,
              Set(outputTracks.map(\.trackID)).count == outputTracks.count else {
            throw failure("The normalized input changed the track inventory.")
        }
        for (source, output) in zip(sourceTracks, outputTracks) {
            try check(cancellation)
            let sourceEnabled = try await source.load(.isEnabled)
            let outputEnabled = try await output.load(.isEnabled)
            let sourceLanguage = try await source.load(.languageCode)
            let outputLanguage = try await output.load(.languageCode)
            let sourceTag = try await source.load(.extendedLanguageTag)
            let outputTag = try await output.load(.extendedLanguageTag)
            let sourceVolume = try await source.load(.preferredVolume)
            let outputVolume = try await output.load(.preferredVolume)
            guard source.mediaType == output.mediaType,
                  sourceEnabled == outputEnabled,
                  try await source.load(.preferredTransform) == .identity,
                  try await output.load(.preferredTransform) == .identity,
                  try await output.load(.metadata).isEmpty,
                  try await output.load(.availableTrackAssociationTypes).isEmpty,
                  sameLanguage(sourceLanguage, output: outputLanguage),
                  sourceTag == outputTag,
                  sourceVolume == outputVolume else {
                throw failure("The normalized input changed track identity or metadata.")
            }
            let sourceRange = try await source.load(.timeRange)
            let outputRange = try await output.load(.timeRange)
            guard sameTime(sourceRange.start, outputRange.start),
                  sameTime(sourceRange.duration, outputRange.duration) else {
                throw failure("The normalized input changed an exact track range.")
            }
            let formats = try await output.load(.formatDescriptions)
            guard formats.count == 1 else {
                throw failure("The normalized input changed its format inventory.")
            }
            if source.mediaType == .video {
                try verifyVideoFormat(formats[0], expected: canonicalFormat, strategy: strategy)
                try verifyVideo(
                    original: original, source: source,
                    derived: derived, output: output,
                    canonicalFormat: canonicalFormat, strategy: strategy,
                    expectedEnd: CMTimeRangeGetEnd(sourceRange),
                    cancellation: cancellation
                )
            } else if source.mediaType == .audio {
                let sourceFormats = try await source.load(.formatDescriptions)
                guard sourceFormats.count == 1 else {
                    throw failure("The source PCM format inventory changed.")
                }
                let stream = try verifyPCMFormat(sourceFormats[0], output: formats[0])
                let expected = try pcmFacts(
                    asset: original, track: source, stream: stream,
                    cancellation: cancellation
                )
                let actual = try pcmFacts(
                    asset: derived, track: output, stream: stream,
                    cancellation: cancellation
                )
                guard expected == actual else {
                    throw failure("The normalized input changed PCM samples or their exact timeline.")
                }
            } else {
                throw failure("The normalized input contains an unsupported track type.")
            }
        }
        try check(cancellation)
    }

    private static func verifyVideo(
        original: AVAsset, source: AVAssetTrack,
        derived: AVAsset, output: AVAssetTrack,
        canonicalFormat: CMVideoFormatDescription,
        strategy: NativeMediaInputAssetResolverV4.Strategy,
        expectedEnd: CMTime,
        cancellation: (any NativeMediaInputCancellationV4)?
    ) throws {
        let lhs = try reader(asset: original, track: source)
        defer { lhs.0.cancelReading() }
        let rhs = try reader(asset: derived, track: output)
        defer { rhs.0.cancelReading() }
        var presentationClock = try NativeAVICompressedPresentationClockV4(
            strategy: strategy, format: canonicalFormat
        )
        var count: UInt64 = 0
        while true {
            try check(cancellation)
            let sourceSample = try nextPacket(lhs.1, cancellation: cancellation)
            let outputSample = try nextPacket(rhs.1, cancellation: cancellation)
            guard let sourceSample, let outputSample else {
                guard sourceSample == nil, outputSample == nil,
                      lhs.0.status == .completed, rhs.0.status == .completed,
                      count > 0 else {
                    throw failure("The normalized input changed the compressed video sample count.")
                }
                try presentationClock.finish(expectedEnd: expectedEnd)
                return
            }
            guard CMSampleBufferGetNumSamples(sourceSample) == 1,
                  CMSampleBufferGetNumSamples(outputSample) == 1,
                  sameTime(CMSampleBufferGetDecodeTimeStamp(sourceSample),
                           CMSampleBufferGetDecodeTimeStamp(outputSample)),
                  sameTime(CMSampleBufferGetDuration(sourceSample),
                           CMSampleBufferGetDuration(outputSample)),
                  notSync(sourceSample) == notSync(outputSample) else {
                throw failure("The normalized input changed compressed video timing or sync flags.")
            }
            let sourceBytes = try payload(sourceSample)
            try NativeMediaInputAssetResolverV4.verifyStableConfiguration(
                sourceBytes, format: canonicalFormat, strategy: strategy
            )
            var timing = CMSampleTimingInfo()
            guard CMSampleBufferGetSampleTimingInfo(sourceSample, at: 0, timingInfoOut: &timing) == noErr else {
                throw failure("The source compressed video timing could not be read.")
            }
            let presentationTime = try presentationClock.presentationTime(packet: sourceBytes, timing: timing)
            guard sameTime(presentationTime, CMSampleBufferGetPresentationTimeStamp(outputSample)) else {
                throw failure("The normalized input changed the bitstream-derived video presentation clock.")
            }
            let expected = strategy == .aviH264
                ? try NativeMediaInputAssetResolverV4.lengthPrefixedH264(sourceBytes)
                : sourceBytes
            guard expected == (try payload(outputSample)),
                  let format = CMSampleBufferGetFormatDescription(outputSample) else {
                throw failure("The normalized input changed compressed video payloads.")
            }
            try verifyVideoFormat(format, expected: canonicalFormat, strategy: strategy)
            guard count < UInt64.max else { throw failure("Video sample count overflowed.") }
            count += 1
        }
    }

    private struct PCMStreamFacts: Equatable {
        let digest: Data
        let frames: UInt64
        let firstTime: CMTime
        let endTime: CMTime

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.digest == rhs.digest && lhs.frames == rhs.frames
                && sameTime(lhs.firstTime, rhs.firstTime)
                && sameTime(lhs.endTime, rhs.endTime)
        }
    }

    private static func pcmFacts(
        asset: AVAsset, track: AVAssetTrack, stream: AudioStreamBasicDescription,
        cancellation: (any NativeMediaInputCancellationV4)?
    ) throws -> PCMStreamFacts {
        let input = try reader(asset: asset, track: track)
        defer { input.0.cancelReading() }
        var hash = SHA256()
        var frames: UInt64 = 0
        var firstTime: CMTime?
        var endTime: CMTime?
        guard let rate = Int32(exactly: stream.mSampleRate), rate > 0 else {
            throw failure("The PCM sample clock is not an exact supported integer.")
        }
        while let sample = try nextPacket(input.1, cancellation: cancellation) {
            try check(cancellation)
            let count = CMSampleBufferGetNumSamples(sample)
            let start = CMSampleBufferGetPresentationTimeStamp(sample)
            let duration = CMTime(value: Int64(count), timescale: rate)
            let observedDuration = CMSampleBufferGetDuration(sample)
            guard count > 0, start.isNumeric, start.epoch == 0,
                  !start.flags.contains(.hasBeenRounded),
                  sameTime(duration, observedDuration),
                  endTime.map({ sameTime($0, start) }) ?? true else {
                throw failure("The PCM sample stream has an inexact or discontinuous timeline.")
            }
            let bytes = try payload(sample)
            let expectedBytes = UInt64(count).multipliedReportingOverflow(
                by: UInt64(stream.mBytesPerFrame)
            )
            let nextFrames = frames.addingReportingOverflow(UInt64(count))
            guard !expectedBytes.overflow, expectedBytes.partialValue == UInt64(bytes.count),
                  !nextFrames.overflow else {
                throw failure("The PCM sample stream has inconsistent frame sizing.")
            }
            hash.update(data: bytes)
            frames = nextFrames.partialValue
            firstTime = firstTime ?? start
            let end = CMTimeAdd(start, duration)
            guard end.isNumeric, !end.flags.contains(.hasBeenRounded) else {
                throw failure("The PCM sample stream end is not exactly representable.")
            }
            endTime = end
        }
        guard input.0.status == .completed, frames > 0,
              let firstTime, let endTime else {
            throw failure("The PCM sample inventory could not be completed.")
        }
        return PCMStreamFacts(digest: Data(hash.finalize()), frames: frames,
                              firstTime: firstTime, endTime: endTime)
    }

    private static func verifyPCMFormat(
        _ source: CMFormatDescription, output: CMFormatDescription
    ) throws -> AudioStreamBasicDescription {
        guard let lhs = CMAudioFormatDescriptionGetStreamBasicDescription(source)?.pointee,
              let rhs = CMAudioFormatDescriptionGetStreamBasicDescription(output)?.pointee,
              lhs.mFormatID == kAudioFormatLinearPCM,
              lhs.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0,
              lhs.mBytesPerFrame > 0, lhs.mFramesPerPacket == 1,
              lhs.mSampleRate == rhs.mSampleRate, lhs.mFormatID == rhs.mFormatID,
              lhs.mFormatFlags == rhs.mFormatFlags, lhs.mBytesPerPacket == rhs.mBytesPerPacket,
              lhs.mFramesPerPacket == rhs.mFramesPerPacket, lhs.mBytesPerFrame == rhs.mBytesPerFrame,
              lhs.mChannelsPerFrame == rhs.mChannelsPerFrame, lhs.mBitsPerChannel == rhs.mBitsPerChannel else {
            throw failure("The normalized input changed the PCM stream format.")
        }
        return lhs
    }

    private static func verifyVideoFormat(
        _ format: CMFormatDescription, expected: CMVideoFormatDescription,
        strategy: NativeMediaInputAssetResolverV4.Strategy
    ) throws {
        let lhs = CMVideoFormatDescriptionGetDimensions(expected)
        let rhs = CMVideoFormatDescriptionGetDimensions(format)
        guard CMFormatDescriptionGetMediaType(format) == kCMMediaType_Video,
              CMFormatDescriptionGetMediaSubType(format) == CMFormatDescriptionGetMediaSubType(expected),
              lhs.width == rhs.width, lhs.height == rhs.height else {
            throw failure("The normalized input changed coded video geometry or codec.")
        }
        if strategy == .aviH264 {
            guard try h264Configuration(expected) == h264Configuration(format) else {
                throw failure("The normalized input changed H.264 decoder configuration.")
            }
        } else if strategy == .aviOpenDMLJPEG {
            guard CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_JPEG,
                  CMFormatDescriptionGetMediaSubType(expected) == kCMVideoCodecType_JPEG else {
                throw failure("The normalized OpenDML input did not publish ordinary JPEG.")
            }
            let sourceAtoms = (CMFormatDescriptionGetExtensions(expected) as NSDictionary?)?
                .object(forKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? NSDictionary
            let outputAtoms = (CMFormatDescriptionGetExtensions(format) as NSDictionary?)?
                .object(forKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? NSDictionary
            guard sourceAtoms?["mjht"] == nil, outputAtoms?["mjht"] == nil else {
                throw failure("The normalized OpenDML input retained an external Huffman atom.")
            }
        } else {
            guard try mpeg4Configuration(expected) == mpeg4Configuration(format) else {
                throw failure("The normalized input changed MPEG-4 decoder configuration.")
            }
        }
        let source = CMFormatDescriptionGetExtensions(expected) as? [String: Any] ?? [:]
        let output = CMFormatDescriptionGetExtensions(format) as? [String: Any] ?? [:]
        let strictKeys = [
            kCMFormatDescriptionExtension_ColorPrimaries,
            kCMFormatDescriptionExtension_TransferFunction,
            kCMFormatDescriptionExtension_YCbCrMatrix,
            kCMFormatDescriptionExtension_FieldDetail,
            kCMFormatDescriptionExtension_ChromaLocationTopField,
            kCMFormatDescriptionExtension_ChromaLocationBottomField,
            kCMFormatDescriptionExtension_MasteringDisplayColorVolume,
            kCMFormatDescriptionExtension_ContentLightLevelInfo,
            kCMFormatDescriptionExtension_AmbientViewingEnvironment
        ]
        for key in strictKeys where !equalProperty(source[key as String], output[key as String]) {
            throw failure("The normalized input changed a video signal extension.")
        }
        guard number(source[kCMFormatDescriptionExtension_FullRangeVideo as String], default: 0)
                == number(output[kCMFormatDescriptionExtension_FullRangeVideo as String], default: 0),
              number(source[kCMFormatDescriptionExtension_FieldCount as String], default: 1)
                == number(output[kCMFormatDescriptionExtension_FieldCount as String], default: 1),
              aspectRatio(source) == aspectRatio(output),
              cleanAperture(source, width: lhs.width, height: lhs.height)
                == cleanAperture(output, width: rhs.width, height: rhs.height) else {
            throw failure("The normalized input changed video range, scan, or presentation geometry.")
        }
    }

    private static func h264Configuration(_ format: CMFormatDescription) throws -> [Data] {
        var count = 0
        var headerLength: Int32 = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format,
            parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: &headerLength) == noErr,
              (1...64).contains(count), headerLength == 4 else {
            throw failure("H.264 decoder configuration is not closed.")
        }
        return try (0..<count).map { index in
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format,
                parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
                  let pointer, size > 0, size <= maximumPacketBytes else {
                throw failure("An H.264 parameter set is invalid.")
            }
            return Data(bytes: pointer, count: size)
        }
    }

    static func mpeg4Configuration(_ format: CMFormatDescription) throws -> Data {
        let extensions = CMFormatDescriptionGetExtensions(format) as? [String: Any] ?? [:]
        let atoms = extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String]
            as? [String: Any]
        guard let data = atoms?["esds"] as? Data, data.count >= 4,
              data.count <= maximumPacketBytes else {
            throw failure("MPEG-4 decoder configuration is missing.")
        }
        let bytes = [UInt8](data)
        var configurations: [Data] = []
        func walk(_ begin: Int, _ end: Int, _ depth: Int) throws {
            guard depth <= 4 else { throw failure("MPEG-4 descriptor nesting is invalid.") }
            var cursor = begin
            while cursor < end {
                let tag = bytes[cursor]
                cursor += 1
                var size = 0
                var terminated = false
                for _ in 0..<4 {
                    guard cursor < end else { throw failure("MPEG-4 descriptor length is truncated.") }
                    let byte = bytes[cursor]
                    cursor += 1
                    size = (size << 7) | Int(byte & 0x7f)
                    if byte & 0x80 == 0 { terminated = true; break }
                }
                guard terminated, size <= end - cursor else {
                    throw failure("MPEG-4 descriptor bounds are invalid.")
                }
                let finish = cursor + size
                if tag == 5 {
                    configurations.append(Data(bytes[cursor..<finish]))
                } else if tag == 3 {
                    guard size >= 3, bytes[cursor + 2] == 0 else {
                        throw failure("MPEG-4 ES descriptor flags are unsupported.")
                    }
                    try walk(cursor + 3, finish, depth + 1)
                } else if tag == 4 {
                    guard size >= 13, bytes[cursor] == 0x20, bytes[cursor + 1] == 0x11 else {
                        throw failure("MPEG-4 decoder descriptor is unsupported.")
                    }
                    try walk(cursor + 13, finish, depth + 1)
                }
                cursor = finish
            }
        }
        try walk(4, bytes.count, 0)
        guard configurations.count == 1, let configuration = configurations.first,
              !configuration.isEmpty else {
            throw failure("MPEG-4 has no unique decoder-specific configuration.")
        }
        return configuration
    }

    private static func reader(asset: AVAsset, track: AVAssetTrack) throws
        -> (AVAssetReader, AVAssetReaderTrackOutput) {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = true
        guard reader.canAdd(output) else { throw failure("The packet verification reader rejected a track.") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? failure("The packet verification reader could not start.") }
        return (reader, output)
    }

    private static func nextPacket(
        _ output: AVAssetReaderTrackOutput,
        cancellation: (any NativeMediaInputCancellationV4)?
    ) throws -> CMSampleBuffer? {
        while let sample = output.copyNextSampleBuffer() {
            try check(cancellation)
            if CMSampleBufferGetNumSamples(sample) > 0 { return sample }
        }
        return nil
    }

    private static func payload(_ sample: CMSampleBuffer) throws -> Data {
        guard let block = CMSampleBufferGetDataBuffer(sample) else {
            throw failure("A verification sample has no encoded payload.")
        }
        let count = CMBlockBufferGetDataLength(block)
        guard count > 0, count <= maximumPacketBytes else {
            throw failure("A verification sample exceeds the bounded packet size.")
        }
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count, destination: $0.baseAddress!)
        }
        guard status == noErr else { throw failure("A verification sample could not be copied.") }
        return data
    }

    private static func notSync(_ sample: CMSampleBuffer) -> Bool {
        let values = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
            as? [[String: Any]]
        return (values?.first?[kCMSampleAttachmentKey_NotSync as String] as? NSNumber)?.boolValue ?? false
    }

    private static func sameTime(_ lhs: CMTime, _ rhs: CMTime) -> Bool {
        if !lhs.isValid || !rhs.isValid { return !lhs.isValid && !rhs.isValid }
        return lhs.isNumeric && rhs.isNumeric && lhs.epoch == rhs.epoch
            && !lhs.flags.contains(.hasBeenRounded) && !rhs.flags.contains(.hasBeenRounded)
            && CMTimeCompare(lhs, rhs) == 0
    }

    private static func number(_ value: Any?, default fallback: Double) -> Double {
        guard let value else { return fallback }
        return (value as? NSNumber)?.doubleValue ?? .nan
    }

    private static func aspectRatio(_ values: [String: Any]) -> [Double] {
        let ratio = values[kCMFormatDescriptionExtension_PixelAspectRatio as String] as? [String: Any] ?? [:]
        return [number(ratio[kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing as String], default: 1),
                number(ratio[kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing as String], default: 1)]
    }

    private static func cleanAperture(_ values: [String: Any], width: Int32, height: Int32) -> [Double] {
        let aperture = values[kCMFormatDescriptionExtension_CleanAperture as String] as? [String: Any] ?? [:]
        return [number(aperture[kCMFormatDescriptionKey_CleanApertureWidth as String], default: Double(width)),
                number(aperture[kCMFormatDescriptionKey_CleanApertureHeight as String], default: Double(height)),
                number(aperture[kCMFormatDescriptionKey_CleanApertureHorizontalOffset as String], default: 0),
                number(aperture[kCMFormatDescriptionKey_CleanApertureVerticalOffset as String], default: 0)]
    }

    private static func equalProperty(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case (let lhs?, let rhs?): return (lhs as? NSObject)?.isEqual(rhs) ?? false
        default: return false
        }
    }

    private static func sameLanguage(_ source: String?, output: String?) -> Bool {
        source == output || (source == nil && output == "und")
    }

    private static func check(_ cancellation: (any NativeMediaInputCancellationV4)?) throws {
        try cancellation?.check()
        try Task.checkCancellation()
    }

    private static func failure(_ details: String) -> NativeMediaInputAssetErrorV4 {
        .unsupported(details)
    }
}
