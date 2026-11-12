import AVFoundation
import CoreVideo
import Foundation

/// Unpacks authenticated private working samples. Original source metadata and
/// clocks remain in the source context; this surface owns only declared pixels.
enum SoftwareRawWorkingVideo {
    static func unpack(_ sample: CMSampleBuffer, asset: AVAsset, video: CanonicalVideoStateV4,
                       allowedFrames: Range<Int>? = nil, metalCompatible: Bool) throws -> CMSampleBuffer {
        let storage: PixelStorageV4
        let format: String
        switch (video.pixel.bitDepth, video.pixel.range) {
        case (8, .video): storage = .nv12VideoRange8Bit; format = "420v"
        case (8, .full): storage = .nv12FullRange8Bit; format = "420f"
        case (10, .video): storage = .p010VideoRange10Bit; format = "x420"
        case (10, .full): storage = .p010FullRange10Bit; format = "xf20"
        default: throw ProbeFailure("raw working depth/range is not qualified")
        }
        let nativeSiting: CFString
        switch video.pixel.chromaSiting {
        case .left: nativeSiting = kCVImageBufferChromaLocation_Left
        case .center: nativeSiting = kCVImageBufferChromaLocation_Center
        case .topLeft: nativeSiting = kCVImageBufferChromaLocation_TopLeft
        case .top: nativeSiting = kCVImageBufferChromaLocation_Top
        case .bottomLeft: nativeSiting = kCVImageBufferChromaLocation_BottomLeft
        case .bottom: nativeSiting = kCVImageBufferChromaLocation_Bottom
        case .unknown, .notApplicable: throw ProbeFailure("unqualified raw working chroma phase")
        }
        let width = Int(video.encodedRaster.width), height = Int(video.encodedRaster.height)
        guard width > 0, height > 0, width <= 8192, height <= 8192,
              video.pixel.chromaSubsampling == .yuv420, video.pixel.alphaModel == .none,
              video.pixel.formatID == "working-" + format,
              CMSampleBufferGetNumSamples(sample) == 1,
              CMSampleBufferGetImageBuffer(sample) == nil,
              let description = CMSampleBufferGetFormatDescription(sample),
              CMFormatDescriptionGetMediaType(description) == kCMMediaType_Video,
              CMFormatDescriptionGetMediaSubType(description) == storage.pixelFormat,
              CMSampleBufferGetDataBuffer(sample) == nil else {
            throw ProbeFailure("raw working sample format/shape differs: formatID=\(video.pixel.formatID), samples=\(CMSampleBufferGetNumSamples(sample)), image=\(CMSampleBufferGetImageBuffer(sample) != nil), data=\(CMSampleBufferGetDataBuffer(sample) != nil), subtype=\(CMSampleBufferGetFormatDescription(sample).map(CMFormatDescriptionGetMediaSubType) ?? 0), expected=\(storage.pixelFormat)")
        }
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        guard dimensions.width == width, dimensions.height == height else {
            throw ProbeFailure("raw working encoded dimensions differ")
        }
        let bytesPerCode = storage.signalBitDepth == 8 ? 1 : 2
        let yStride = width * bytesPerCode, uvStride = ((width + 1) / 2) * 2 * bytesPerCode
        let uvOffset = 16 + yStride * height
        let extent = uvOffset + uvStride * ((height + 1) / 2)
        let reference = try SoftwareVirtualCarrier.resolveReference(for: sample, asset: asset, allowedFrames: allowedFrames)
        let data = reference.data
        guard extent <= 64 * 1024 * 1024, data.count == extent else {
            throw ProbeFailure("raw working payload extent differs")
        }
        func be32(_ offset: Int) -> Int {
            (offset..<offset + 4).reduce(0) { ($0 << 8) | Int(data[$1]) }
        }
        guard be32(0) == 16, be32(4) == yStride,
              be32(8) == uvOffset, be32(12) == uvStride else {
            throw ProbeFailure("raw working plane layout differs from declared profile")
        }
        if bytesPerCode == 2 {
            for offset in stride(from: 16, to: extent, by: 2) where data[offset] & 63 != 0 {
                throw ProbeFailure("raw P010 sample contains nonzero unused bits")
            }
        }
        let buffer = try PixelBufferSignalCodecV4.makeBuffer(storage: storage,
            width: width, height: height, metalCompatible: metalCompatible)
        let locked = CVPixelBufferLockBaseAddress(buffer, [])
        guard locked == kCVReturnSuccess else { throw ProbeFailure("raw working buffer lock failed") }
        do {
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            try data.withUnsafeBytes { source in
                for plane in 0..<2 {
                    let rows = plane == 0 ? height : (height + 1) / 2
                    let active = plane == 0 ? yStride : uvStride
                    let offset = plane == 0 ? 16 : uvOffset
                    let targetStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
                    guard CVPixelBufferGetHeightOfPlane(buffer, plane) == rows,
                          targetStride >= active,
                          let target = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else {
                        throw ProbeFailure("raw working destination span differs")
                    }
                    for row in 0..<rows {
                        memcpy(target.advanced(by: row * targetStride),
                            source.baseAddress!.advanced(by: offset + row * active), active)
                    }
                }
            }
        }
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey,
            video.color.primaries as CFString, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey,
            video.color.transferFunction as CFString, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey,
            video.color.matrix as CFString, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferFieldCountKey, 1 as CFNumber, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferChromaLocationTopFieldKey,
            nativeSiting, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferChromaLocationBottomFieldKey,
            nativeSiting, .shouldPropagate)
        var outputDescription: CMVideoFormatDescription?
        let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: buffer, formatDescriptionOut: &outputDescription)
        guard formatStatus == noErr, let outputDescription else { throw ProbeFailure("raw working image format failed") }
        let mediaDecodeTime = CMSampleBufferGetDecodeTimeStamp(sample)
        var timing = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(sample),
            presentationTimeStamp: reference.presentation,
            decodeTimeStamp: mediaDecodeTime.isNumeric
                ? CMTimeAdd(mediaDecodeTime, reference.mediaToWorkingOffset) : mediaDecodeTime)
        var output: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: buffer, formatDescription: outputDescription, sampleTiming: &timing,
            sampleBufferOut: &output)
        guard sampleStatus == noErr, let output else { throw ProbeFailure("raw working image sample failed") }
        return output
    }
}
