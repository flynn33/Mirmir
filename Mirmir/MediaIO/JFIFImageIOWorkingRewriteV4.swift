import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Turns JFIF Motion JPEG that the progressive native path cannot admit —
/// 4:2:2 / 4:4:4 chroma, or interlaced `FieldCount=2` — into an ordinary
/// progressive-field 4:2:0 JPEG MOV. Packets are ImageIO-decoded and re-encoded
/// as JFIF 4:2:0 with `FieldCount=1`; presentation timing and exact frame count
/// are preserved. This is a working-delivery rewrite, not a claim that VT
/// natively owns 4:2:2/4:4:4 or interlaced JPEG as progressive JFIF.
enum JFIFImageIOWorkingRewriteV4 {
    enum Failure: Error, Equatable {
        case unsupported(String)
        case io(String)
    }

    private static let supportedInterlacedFieldDetails: Set<String> = [
        kCMFormatDescriptionFieldDetail_TemporalTopFirst as String,
        kCMFormatDescriptionFieldDetail_TemporalBottomFirst as String,
        kCMFormatDescriptionFieldDetail_SpatialFirstLineEarly as String,
        kCMFormatDescriptionFieldDetail_SpatialFirstLineLate as String
    ]

    /// Returns true when the first video packet needs the ImageIO working
    /// rewrite: JFIF 4:2:2/4:4:4 under a progressive field declaration, or any
    /// classified JFIF sampling under an interlaced `FieldCount=2` declaration.
    static func needsRewrite(asset: AVAsset) async throws -> Bool {
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard tracks.count == 1, let track = tracks.first else { return false }
        let descriptions = try await track.load(.formatDescriptions)
        guard descriptions.count == 1, let description = descriptions.first else {
            return false
        }
        let codec = CMFormatDescriptionGetMediaSubType(description)
        guard [kCMVideoCodecType_JPEG, kCMVideoCodecType_JPEG_OpenDML].contains(codec) else {
            return false
        }
        let extensions = CMFormatDescriptionGetExtensions(description) as NSDictionary? ?? [:]
        let interlaced: Bool
        if let fieldCount = extensions[kCMFormatDescriptionExtension_FieldCount as String] as? NSNumber {
            if fieldCount.doubleValue == 1 {
                guard extensions[kCMFormatDescriptionExtension_FieldDetail as String] == nil else {
                    return false
                }
                interlaced = false
            } else if fieldCount.doubleValue == 2 {
                guard let detail = extensions[kCMFormatDescriptionExtension_FieldDetail as String] as? String,
                      supportedInterlacedFieldDetails.contains(detail) else {
                    return false
                }
                interlaced = true
            } else {
                return false
            }
        } else {
            // Missing FieldCount is common on ffmpeg remuxes and is treated as
            // one full-raster field when FieldDetail is absent.
            guard extensions[kCMFormatDescriptionExtension_FieldDetail as String] == nil else {
                return false
            }
            interlaced = false
        }
        guard let packet = try firstCompressedPacket(asset: asset, track: track),
              let sampling = chromaSubsampling(packet) else {
            return false
        }
        if interlaced {
            // Progressive JFIF admission rejects FieldCount=2. Rewrite any
            // classified JFIF sampling onto a progressive-field 4:2:0 entry.
            return sampling == .yuv420 || sampling == .yuv422 || sampling == .yuv444
        }
        // Canonical JFIF (chroma 0x11) and ffmpeg-equivalent MCU factorizations
        // (e.g. Y=0x22/Cb=0x12 for 4:2:2) both need the ImageIO rewrite path.
        return sampling == .yuv422 || sampling == .yuv444
    }

    /// Classifies JFIF YCbCr chroma from SOF sampling factors. Accepts both the
    /// LegacyVideoSamplingFacts-canonical form (chroma HxV = 0x11) and equivalent
    /// relative MCU factorizations used by ffmpeg Motion JPEG.
    static func chromaSubsampling(_ data: Data) -> CanonicalChromaSubsamplingV4? {
        if let facts = LegacyVideoSamplingFacts.jpeg(data) {
            return facts.subsampling
        }
        let b = [UInt8](data)
        guard b.count >= 4, b[0] == 0xff, b[1] == 0xd8 else { return nil }
        var i = 2
        var jfif = false
        while i + 4 <= b.count {
            guard b[i] == 0xff else { return nil }
            while i < b.count, b[i] == 0xff { i += 1 }
            guard i + 3 <= b.count else { return nil }
            let marker = b[i]; i += 1
            if marker == 0xda || marker == 0xd9 { return nil }
            let length = Int(b[i]) * 256 + Int(b[i + 1])
            guard length >= 2, length <= b.count - i else { return nil }
            if marker == 0xe0, length >= 16 {
                jfif = Array(b[(i + 2)..<(i + 7)]) == Array("JFIF\0".utf8)
            }
            if marker == 0xc0 || marker == 0xc1 || marker == 0xc2 {
                guard jfif, length == 17, b[i + 2] == 8, b[i + 7] == 3,
                      b[i + 8] == 1, b[i + 11] == 2, b[i + 14] == 3 else {
                    return nil
                }
                let yH = Int(b[i + 9] >> 4), yV = Int(b[i + 9] & 0x0f)
                let cbH = Int(b[i + 12] >> 4), cbV = Int(b[i + 12] & 0x0f)
                let crH = Int(b[i + 15] >> 4), crV = Int(b[i + 15] & 0x0f)
                guard yH > 0, yV > 0, cbH > 0, cbV > 0, crH > 0, crV > 0,
                      yH == cbH * (yH / cbH), yV == cbV * (yV / cbV),
                      cbH == crH, cbV == crV else {
                    return nil
                }
                let hRatio = yH / cbH
                let vRatio = yV / cbV
                switch (hRatio, vRatio) {
                case (2, 2): return .yuv420
                case (2, 1): return .yuv422
                case (1, 1): return .yuv444
                default: return nil
                }
            }
            i += length
        }
        return nil
    }

    /// Writes a progressive-field 4:2:0 JFIF JPEG MOV at `destination` with one
    /// sample per source packet and identical presentation timestamps.
    static func rewrite(
        asset: AVAsset,
        to destination: URL,
        cancellation: () throws -> Void = {}
    ) async throws {
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard tracks.count == 1, let track = tracks.first else {
            throw Failure.unsupported("JPEG working rewrite requires exactly one video track.")
        }
        let descriptions = try await track.load(.formatDescriptions)
        guard descriptions.count == 1, let description = descriptions.first else {
            throw Failure.unsupported("JPEG working rewrite requires a single sample entry.")
        }
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        guard dimensions.width > 0, dimensions.height > 0 else {
            throw Failure.unsupported("JPEG working rewrite requires a positive raster.")
        }

        try cancellation()
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }

        var format: CMVideoFormatDescription?
        let extensions = [
            kCMFormatDescriptionExtension_FieldCount as String: 1
        ] as CFDictionary
        let formatCode = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_JPEG,
            width: dimensions.width,
            height: dimensions.height,
            extensions: extensions,
            formatDescriptionOut: &format
        )
        guard formatCode == noErr, let format else {
            throw Failure.io("Cannot create progressive JPEG sample entry (\(formatCode)).")
        }

        let writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: nil,
            sourceFormatHint: format
        )
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else {
            throw Failure.io("JPEG working rewrite writer rejected its video input.")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw Failure.io(String(describing: writer.error))
        }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = true
        guard reader.canAdd(output) else {
            throw Failure.io("JPEG working rewrite reader rejected its video track.")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw Failure.io(String(describing: reader.error))
        }

        var started = false
        var frameCount = 0
        while let sample = output.copyNextSampleBuffer() {
            try cancellation()
            let count = CMSampleBufferGetNumSamples(sample)
            guard count > 0 else { continue }
            guard let block = CMSampleBufferGetDataBuffer(sample) else {
                throw Failure.unsupported("JPEG packet is missing its compressed payload.")
            }
            let length = CMBlockBufferGetDataLength(block)
            guard length > 0, length <= 64 * 1024 * 1024 else {
                throw Failure.unsupported("JPEG packet size is outside the working rewrite budget.")
            }
            var bytes = Data(count: length)
            let status = bytes.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(
                    block,
                    atOffset: 0,
                    dataLength: length,
                    destination: $0.baseAddress!
                )
            }
            guard status == noErr else {
                throw Failure.io("JPEG packet copy failed (\(status)).")
            }
            var timing = CMSampleTimingInfo()
            let timingCode = CMSampleBufferGetSampleTimingInfo(sample, at: 0, timingInfoOut: &timing)
            guard timingCode == noErr,
                  timing.presentationTimeStamp.isNumeric,
                  !timing.presentationTimeStamp.flags.contains(.hasBeenRounded) else {
                throw Failure.unsupported("JPEG packet presentation time is not exact.")
            }
            if !started {
                writer.startSession(atSourceTime: timing.presentationTimeStamp)
                started = true
            }
            let jpeg = try encodeJFIF420(
                bytes,
                width: Int(dimensions.width),
                height: Int(dimensions.height)
            )
            let rebound = try sampleBuffer(
                jpeg: jpeg,
                format: format,
                timing: timing
            )
            while !input.isReadyForMoreMediaData {
                try cancellation()
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            guard input.append(rebound) else {
                throw Failure.io(String(describing: writer.error))
            }
            frameCount += 1
        }
        guard reader.status == .completed else {
            throw Failure.io(String(describing: reader.error))
        }
        guard started, frameCount > 0 else {
            throw Failure.unsupported("JPEG working rewrite found no video frames.")
        }
        let end = try await track.load(.timeRange).end
        input.markAsFinished()
        writer.endSession(atSourceTime: end)
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw Failure.io(String(describing: writer.error))
        }

        // Authenticate the rewritten sample entry as progressive-field JFIF 4:2:0.
        let rewritten = AVURLAsset(
            url: destination,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let rewrittenTracks = try await rewritten.loadTracks(withMediaType: .video)
        guard rewrittenTracks.count == 1,
              let rewrittenTrack = rewrittenTracks.first else {
            throw Failure.unsupported("Rewritten JPEG MOV is missing its video track.")
        }
        let rewrittenDescriptions = try await rewrittenTrack.load(.formatDescriptions)
        guard rewrittenDescriptions.count == 1,
              let rewrittenDescription = rewrittenDescriptions.first,
              CMFormatDescriptionGetMediaSubType(rewrittenDescription) == kCMVideoCodecType_JPEG,
              let proof = try JFIFVideoSamplingV4.progressiveDeclaration(from: rewrittenDescription)
        else {
            throw Failure.unsupported("Rewritten JPEG MOV is not progressive JFIF.")
        }
        guard let first = try firstCompressedPacket(asset: rewritten, track: rewrittenTrack) else {
            throw Failure.unsupported("Rewritten JPEG MOV has no compressed packets.")
        }
        try proof.validatePacket(first)
        guard let facts = LegacyVideoSamplingFacts.jpeg(first), facts.subsampling == .yuv420 else {
            throw Failure.unsupported("Rewritten JPEG MOV did not become progressive 4:2:0.")
        }
        let rewrittenFrames = try await decodedFrameCount(of: rewritten)
        guard rewrittenFrames == frameCount else {
            throw Failure.unsupported(
                "Rewritten JPEG MOV frame count \(rewrittenFrames) disagrees with source \(frameCount)."
            )
        }
    }

    private static func encodeJFIF420(
        _ jpeg: Data,
        width: Int,
        height: Int
    ) throws -> Data {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(
                  source,
                  0,
                  [kCGImageSourceShouldCache: false] as CFDictionary
              ) else {
            throw Failure.unsupported("ImageIO could not decode a JPEG packet.")
        }
        guard image.width == width, image.height == height else {
            throw Failure.unsupported(
                "ImageIO JPEG raster \(image.width)x\(image.height) disagrees with \(width)x\(height)."
            )
        }
        // ImageIO preserves source chroma when re-encoding a JPEG-backed CGImage
        // (422 stays 422). Redraw into an RGB bitmap so the destination emits
        // ordinary JFIF 4:2:0 that VideoToolbox can decode.
        guard let rgbContext = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw Failure.io("Cannot create RGB working context.")
        }
        rgbContext.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let rgbImage = rgbContext.makeImage() else {
            throw Failure.io("Cannot materialize RGB working image.")
        }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            encoded,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw Failure.io("Cannot create ImageIO JPEG destination.")
        }
        CGImageDestinationAddImage(
            destination,
            rgbImage,
            [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw Failure.io("ImageIO JPEG encode failed.")
        }
        let data = encoded as Data
        guard let facts = LegacyVideoSamplingFacts.jpeg(data), facts.subsampling == .yuv420 else {
            throw Failure.unsupported("ImageIO JPEG encode did not produce JFIF 4:2:0.")
        }
        return data
    }

    private static func sampleBuffer(
        jpeg: Data,
        format: CMVideoFormatDescription,
        timing: CMSampleTimingInfo
    ) throws -> CMSampleBuffer {
        var block: CMBlockBuffer?
        var code = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: jpeg.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: jpeg.count,
            flags: 0,
            blockBufferOut: &block
        )
        guard code == noErr, let block else {
            throw Failure.io("Cannot allocate rewritten JPEG packet buffer (\(code)).")
        }
        code = jpeg.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(
                with: $0.baseAddress!,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: jpeg.count
            )
        }
        guard code == noErr else {
            throw Failure.io("Cannot fill rewritten JPEG packet buffer (\(code)).")
        }
        var mutableTiming = timing
        var size = jpeg.count
        var sample: CMSampleBuffer?
        code = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &mutableTiming,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &size,
            sampleBufferOut: &sample
        )
        guard code == noErr, let sample else {
            throw Failure.io("Cannot construct rewritten JPEG packet (\(code)).")
        }
        return sample
    }

    private static func firstCompressedPacket(
        asset: AVAsset,
        track: AVAssetTrack
    ) throws -> Data? {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        defer { reader.cancelReading() }
        guard reader.startReading() else { return nil }
        while let sample = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(sample) > 0,
                  let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            guard length > 0 else { continue }
            var bytes = Data(count: length)
            let status = bytes.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(
                    block,
                    atOffset: 0,
                    dataLength: length,
                    destination: $0.baseAddress!
                )
            }
            guard status == noErr else { return nil }
            return bytes
        }
        return nil
    }

    private static func decodedFrameCount(of asset: AVAsset) async throws -> Int {
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { return 0 }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        guard reader.canAdd(output) else {
            throw Failure.io("Cannot reopen rewritten JPEG for frame verification.")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw Failure.io(String(describing: reader.error))
        }
        var count = 0
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetImageBuffer(sample) != nil { count += 1 }
        }
        guard reader.status == .completed else {
            throw Failure.io(String(describing: reader.error))
        }
        return count
    }
}
