import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox
let expectedPixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
let averageBitRate = 250_000
let dataRateLimitBytes = 31_250
let dataRateLimitSeconds = 1
let expectedFrameRate = 30
struct SoftwareEncoderDescriptor {
    let id: String
    let name: String
    let displayName: String
}
struct CompressionOutcome {
    let encoder: SoftwareEncoderDescriptor
    let hardwareAccelerated: Bool
    let hardwareAccelerationPropertyAvailable: Bool
    let allFramesSync: Bool
}

struct AssetDescriptor {
    let asset: AVURLAsset
    let track: AVAssetTrack
    let format: CMFormatDescription
    let duration: CMTime
    let trackEnd: CMTime
    let width: Int
    let height: Int
    let codec: String
    let attachments: AttachmentEvidence
}

final class EncodedSampleCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [CMSampleBuffer] = []
    private var failures: [String] = []

    func record(status: OSStatus, flags: VTEncodeInfoFlags, sample: CMSampleBuffer?) {
        lock.lock()
        defer { lock.unlock() }
        guard status == noErr else {
            failures.append("compression callback returned OSStatus \(status)")
            return
        }
        guard !flags.contains(.frameDropped), let sample else {
            failures.append("compression callback dropped a frame")
            return
        }
        var copy: CMSampleBuffer?
        let copyStatus = CMSampleBufferCreateCopy(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sample,
            sampleBufferOut: &copy
        )
        guard copyStatus == noErr, let copy else {
            failures.append("compressed sample copy failed with OSStatus \(copyStatus)")
            return
        }
        samples.append(copy)
    }

    func finish(expectedCount: Int) throws -> [CMSampleBuffer] {
        lock.lock()
        defer { lock.unlock() }
        if let failure = failures.first {
            throw FixtureError.failed(failure)
        }
        guard samples.count == expectedCount else {
            throw FixtureError.failed(
                "encoder produced \(samples.count) samples; expected \(expectedCount)"
            )
        }
        return samples.sorted {
            CMTimeCompare(
                CMSampleBufferGetPresentationTimeStamp($0),
                CMSampleBufferGetPresentationTimeStamp($1)
            ) < 0
        }
    }
}

private func compressionOutputCallback(
    outputCallbackRefCon: UnsafeMutableRawPointer?,
    sourceFrameRefCon _: UnsafeMutableRawPointer?,
    status: OSStatus,
    infoFlags: VTEncodeInfoFlags,
    sampleBuffer: CMSampleBuffer?
) {
    guard let outputCallbackRefCon else { return }
    let collector = Unmanaged<EncodedSampleCollector>
        .fromOpaque(outputCallbackRefCon)
        .takeUnretainedValue()
    collector.record(status: status, flags: infoFlags, sample: sampleBuffer)
}

final class DecodedFrameCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [DecodedFrameEvidence] = []
    private var failures: [String] = []

    func record(
        status: OSStatus,
        flags: VTDecodeInfoFlags,
        imageBuffer: CVImageBuffer?,
        presentationTime: CMTime,
        duration: CMTime
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard status == noErr else {
            failures.append("decompression callback returned OSStatus \(status)")
            return
        }
        guard !flags.contains(.frameDropped), let imageBuffer else {
            failures.append("decompression callback dropped a frame")
            return
        }
        do {
            frames.append(
                try decodedFrameEvidence(
                    pixelBuffer: imageBuffer,
                    index: frames.count,
                    presentationTime: presentationTime,
                    duration: duration
                )
            )
        } catch {
            failures.append(String(describing: error))
        }
    }

    func finish(expectedCount: Int) throws -> [DecodedFrameEvidence] {
        lock.lock()
        defer { lock.unlock() }
        if let failure = failures.first {
            throw FixtureError.failed(failure)
        }
        guard frames.count == expectedCount else {
            throw FixtureError.failed(
                "decoder produced \(frames.count) frames; expected \(expectedCount)"
            )
        }
        let ordered = frames.sorted {
            CMTimeCompare($0.presentationTime.cmTime, $1.presentationTime.cmTime) < 0
        }
        return ordered.enumerated().map { index, frame in
            DecodedFrameEvidence(
                index: index,
                presentationTime: frame.presentationTime,
                duration: frame.duration,
                width: frame.width,
                height: frame.height,
                pixelFormat: frame.pixelFormat,
                activeRowSha256: frame.activeRowSha256,
                attachments: frame.attachments
            )
        }
    }
}

private func selectSoftwareH264Encoder() throws -> SoftwareEncoderDescriptor {
    var rawList: CFArray?
    let status = VTCopyVideoEncoderList(nil, &rawList)
    guard status == noErr, let entries = rawList as? [Any] else {
        throw FixtureError.operation("VTCopyVideoEncoderList", status)
    }
    let candidates = entries.compactMap { entry -> SoftwareEncoderDescriptor? in
        guard let dictionary = entry as? NSDictionary,
              let codec = dictionary[kVTVideoEncoderList_CodecType] as? NSNumber,
              codec.uint32Value == kCMVideoCodecType_H264,
              (dictionary[kVTVideoEncoderList_IsHardwareAccelerated] as? NSNumber)?.boolValue != true,
              let id = dictionary[kVTVideoEncoderList_EncoderID] as? String,
              let name = dictionary[kVTVideoEncoderList_EncoderName] as? String,
              let displayName = dictionary[kVTVideoEncoderList_DisplayName] as? String else {
            return nil
        }
        return SoftwareEncoderDescriptor(id: id, name: name, displayName: displayName)
    }
    guard candidates.count == 1, let encoder = candidates.first else {
        throw FixtureError.failed(
            "expected exactly one software H.264 encoder; found \(candidates.count)"
        )
    }
    return encoder
}

private func copyProperty(
    _ session: VTSession,
    key: CFString
) -> (OSStatus, CFTypeRef?) {
    let pointer = UnsafeMutablePointer<CFTypeRef?>.allocate(capacity: 1)
    pointer.initialize(to: nil)
    defer {
        pointer.deinitialize(count: 1)
        pointer.deallocate()
    }
    let status = VTSessionCopyProperty(
        session,
        key: key,
        allocator: kCFAllocatorDefault,
        valueOut: UnsafeMutableRawPointer(pointer)
    )
    return (status, pointer.pointee)
}

func optionalBoolProperty(
    _ session: VTSession,
    key: CFString,
    operation: String
) throws -> Bool? {
    let (status, value) = copyProperty(session, key: key)
    if status == kVTPropertyNotSupportedErr {
        return nil
    }
    guard status == noErr, let value, CFGetTypeID(value) == CFBooleanGetTypeID() else {
        throw FixtureError.operation(operation, status)
    }
    guard let result = value as? Bool else {
        throw FixtureError.failed("\(operation) returned a non-Boolean value")
    }
    return result
}

private func stringProperty(
    _ session: VTSession,
    key: CFString,
    operation: String
) throws -> String {
    let (status, value) = copyProperty(session, key: key)
    guard status == noErr, let value, CFGetTypeID(value) == CFStringGetTypeID(),
          let result = value as? String else {
        throw FixtureError.operation(operation, status)
    }
    return result
}

private func makeCompressionSession(
    encoder: SoftwareEncoderDescriptor,
    width: Int,
    height: Int,
    collector: EncodedSampleCollector
) throws -> VTCompressionSession {
    let encoderSpecification: [String: Any] = [
        kVTVideoEncoderSpecification_EncoderID as String: encoder.id,
        kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: false
    ]
    let sourceAttributes: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: expectedPixelFormat),
        kCVPixelBufferWidthKey as String: NSNumber(value: width),
        kCVPixelBufferHeightKey as String: NSNumber(value: height),
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
    ]
    var session: VTCompressionSession?
    let status = VTCompressionSessionCreate(
        allocator: kCFAllocatorDefault,
        width: Int32(width),
        height: Int32(height),
        codecType: kCMVideoCodecType_H264,
        encoderSpecification: encoderSpecification as CFDictionary,
        imageBufferAttributes: sourceAttributes as CFDictionary,
        compressedDataAllocator: nil,
        outputCallback: compressionOutputCallback,
        refcon: Unmanaged.passUnretained(collector).toOpaque(),
        compressionSessionOut: &session
    )
    guard status == noErr, let session else {
        throw FixtureError.operation("VTCompressionSessionCreate", status)
    }
    return session
}

private func configureCompressionSession(
    _ session: VTCompressionSession,
    encoder: SoftwareEncoderDescriptor
) throws -> Bool? {
    let properties: [String: Any] = [
        kVTCompressionPropertyKey_RealTime as String: false,
        kVTCompressionPropertyKey_AllowFrameReordering as String: false,
        kVTCompressionPropertyKey_AllowTemporalCompression as String: false,
        kVTCompressionPropertyKey_MaxKeyFrameInterval as String: 1,
        kVTCompressionPropertyKey_ProfileLevel as String: kVTProfileLevel_H264_Baseline_3_0,
        kVTCompressionPropertyKey_AverageBitRate as String: averageBitRate,
        kVTCompressionPropertyKey_DataRateLimits as String: [
            dataRateLimitBytes,
            dataRateLimitSeconds
        ],
        kVTCompressionPropertyKey_ExpectedFrameRate as String: expectedFrameRate,
        kVTCompressionPropertyKey_ColorPrimaries as String: kCVImageBufferColorPrimaries_ITU_R_709_2,
        kVTCompressionPropertyKey_TransferFunction as String: kCVImageBufferTransferFunction_ITU_R_709_2,
        kVTCompressionPropertyKey_YCbCrMatrix as String: kCVImageBufferYCbCrMatrix_ITU_R_709_2
    ]
    let propertyStatus = VTSessionSetProperties(session, propertyDictionary: properties as CFDictionary)
    guard propertyStatus == noErr else {
        throw FixtureError.operation("VTSessionSetProperties(compression)", propertyStatus)
    }
    let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(session)
    guard prepareStatus == noErr else {
        throw FixtureError.operation("VTCompressionSessionPrepareToEncodeFrames", prepareStatus)
    }
    let selectedEncoderId = try stringProperty(
        session,
        key: kVTCompressionPropertyKey_EncoderID,
        operation: "VTSessionCopyProperty(encoder ID)"
    )
    guard selectedEncoderId == encoder.id else {
        throw FixtureError.failed(
            "compression session selected encoder \(selectedEncoderId), expected \(encoder.id)"
        )
    }
    let acceleration = try optionalBoolProperty(
        session,
        key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
        operation: "VTSessionCopyProperty(encoder acceleration)"
    )
    guard acceleration != true else {
        throw FixtureError.failed("software encoder requirement was not honored")
    }
    return acceleration
}

private func encodeFrames(
    session: VTCompressionSession,
    payload: Data,
    sourceLock: SourceFixtureLock,
    collector: EncodedSampleCollector
) throws -> [CMSampleBuffer] {
    let width = sourceLock.pixelLayout.width
    let height = sourceLock.pixelLayout.height
    let frameSize = width * height * 3 / 2
    for frame in sourceLock.frames {
        let pixelBuffer = try makeSourcePixelBuffer(
            payload: payload,
            offset: frame.index * frameSize,
            width: width,
            height: height
        )
        var flags = VTEncodeInfoFlags()
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: frame.presentationTime.cmTime,
            duration: frame.duration.cmTime,
            frameProperties: [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary,
            sourceFrameRefcon: nil,
            infoFlagsOut: &flags
        )
        guard status == noErr, !flags.contains(.frameDropped) else {
            throw FixtureError.operation("VTCompressionSessionEncodeFrame", status)
        }
    }
    let completeStatus = VTCompressionSessionCompleteFrames(
        session,
        untilPresentationTimeStamp: .invalid
    )
    guard completeStatus == noErr else {
        throw FixtureError.operation("VTCompressionSessionCompleteFrames", completeStatus)
    }
    return try collector.finish(expectedCount: sourceLock.frameCount)
}

func encodeAndMux(
    sourcePayload: Data,
    sourceLock: SourceFixtureLock,
    outputURL: URL
) throws -> CompressionOutcome {
    guard !FileManager.default.fileExists(atPath: outputURL.path) else {
        throw FixtureError.invalidArgument("refusing to overwrite existing fixture \(outputURL.path)")
    }
    try FileManager.default.createDirectory(
        at: outputURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let width = sourceLock.pixelLayout.width
    let height = sourceLock.pixelLayout.height
    let encoder = try selectSoftwareH264Encoder()
    let collector = EncodedSampleCollector()
    let session = try makeCompressionSession(
        encoder: encoder,
        width: width,
        height: height,
        collector: collector
    )
    defer { VTCompressionSessionInvalidate(session) }
    let accelerationProperty = try configureCompressionSession(session, encoder: encoder)
    let samples = try encodeFrames(
        session: session,
        payload: sourcePayload,
        sourceLock: sourceLock,
        collector: collector
    )
    let allFramesSync = samples.allSatisfy { sample in
        guard let raw = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false),
              let attachments = raw as? [[CFString: Any]],
              let first = attachments.first else {
            return true
        }
        return (first[kCMSampleAttachmentKey_NotSync] as? Bool) != true
    }
    guard allFramesSync else {
        throw FixtureError.failed("keyframe interval one did not produce all-sync samples")
    }
    try mux(samples: samples, outputURL: outputURL)
    return CompressionOutcome(
        encoder: encoder,
        hardwareAccelerated: false,
        hardwareAccelerationPropertyAvailable: accelerationProperty != nil,
        allFramesSync: allFramesSync
    )
}

private func mux(samples: [CMSampleBuffer], outputURL: URL) throws {
    guard let format = samples.first.flatMap(CMSampleBufferGetFormatDescription) else {
        throw FixtureError.invalidFixture("compressed sample format description is absent")
    }
    let writer = try AVAssetWriter(url: outputURL, fileType: .mp4)
    writer.shouldOptimizeForNetworkUse = false
    let input = AVAssetWriterInput(
        mediaType: .video,
        outputSettings: nil,
        sourceFormatHint: format
    )
    input.expectsMediaDataInRealTime = false
    guard writer.canAdd(input) else {
        throw FixtureError.failed("AVAssetWriter rejected H.264 passthrough input")
    }
    writer.add(input)
    guard writer.startWriting() else {
        throw FixtureError.failed("AVAssetWriter.startWriting failed: \(String(describing: writer.error))")
    }
    writer.startSession(atSourceTime: .zero)
    for sample in samples {
        guard input.isReadyForMoreMediaData, input.append(sample) else {
            throw FixtureError.failed("AVAssetWriter passthrough append failed")
        }
    }
    input.markAsFinished()
    let semaphore = DispatchSemaphore(value: 0)
    writer.finishWriting { semaphore.signal() }
    guard semaphore.wait(timeout: .now() + 30) == .success else {
        throw FixtureError.failed("AVAssetWriter finish timed out")
    }
    guard writer.status == .completed else {
        throw FixtureError.failed("AVAssetWriter finish failed: \(String(describing: writer.error))")
    }
}

func loadAssetDescriptor(url: URL) async throws -> AssetDescriptor {
    let asset = AVURLAsset(
        url: url,
        options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
    )
    let tracks = try await asset.loadTracks(withMediaType: .video)
    guard tracks.count == 1, let track = tracks.first else {
        throw FixtureError.invalidFixture("fixture must contain exactly one video track")
    }
    let formats = try await track.load(.formatDescriptions)
    guard let format = formats.first else {
        throw FixtureError.invalidFixture("fixture video format description is absent")
    }
    let dimensions = CMVideoFormatDescriptionGetDimensions(format)
    return AssetDescriptor(
        asset: asset,
        track: track,
        format: format,
        duration: try await asset.load(.duration),
        trackEnd: CMTimeRangeGetEnd(try await track.load(.timeRange)),
        width: Int(dimensions.width),
        height: Int(dimensions.height),
        codec: fourCC(CMFormatDescriptionGetMediaSubType(format)),
        attachments: formatAttachments(format)
    )
}

func copySamples(
    descriptor: AssetDescriptor,
    outputSettings: [String: Any]?
) throws -> [CMSampleBuffer] {
    let reader = try AVAssetReader(asset: descriptor.asset)
    let output = AVAssetReaderTrackOutput(track: descriptor.track, outputSettings: outputSettings)
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else {
        throw FixtureError.failed("AVAssetReader rejected requested output")
    }
    reader.add(output)
    guard reader.startReading() else {
        throw FixtureError.failed("AVAssetReader start failed: \(String(describing: reader.error))")
    }
    var samples: [CMSampleBuffer] = []
    while let sample = output.copyNextSampleBuffer() {
        if CMSampleBufferGetNumSamples(sample) > 0 {
            samples.append(sample)
        }
    }
    guard reader.status == .completed else {
        throw FixtureError.failed("AVAssetReader failed: \(String(describing: reader.error))")
    }
    return samples
}
