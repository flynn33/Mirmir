import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation

/// A bounded signal-RGB thumbnail path for qualified native progressive 8-bit 4:2:0.
/// The decoder's YCbCr planes and their attachments remain unchanged.
enum NativeThumbnailSignalConverterV4 {
    struct Failure: Error { let reason: String }

    struct Contract: Equatable {
        let width: Int
        let height: Int
        let siting: CanonicalChromaSitingV4
        let fullRange: Bool
        let primaries: String
        let transfer: String
        let matrix: String
    }

    static func contract(
        descriptions: [CMFormatDescription], transform: CGAffineTransform,
        characteristics: [AVMediaCharacteristic]
    ) throws -> Contract? {
        guard !descriptions.isEmpty, transform == .identity,
              !characteristics.contains(.containsAlphaChannel),
              !characteristics.contains(.containsHDRVideo) else { return nil }
        let avc = try AVCChromaLocationV4.declaration(from: descriptions)
        var first: Contract?
        for description in descriptions {
            let codec = CMFormatDescriptionGetMediaSubType(description)
            guard codec == kCMVideoCodecType_H264 || codec == kCMVideoCodecType_HEVC else { return nil }
            let ext = CMFormatDescriptionGetExtensions(description) as NSDictionary? ?? [:]
            guard ext[kCMFormatDescriptionExtension_MasteringDisplayColorVolume as String] == nil,
                  ext[kCMFormatDescriptionExtension_ContentLightLevelInfo as String] == nil,
                  (ext[kCMFormatDescriptionExtension_ContainsAlphaChannel as String] as? NSNumber)?.boolValue != true else { return nil }
            if let depth = ext[kCMFormatDescriptionExtension_BitsPerComponent as String] {
                guard let depth = depth as? NSNumber, depth.intValue == 8 else { return nil }
            }
            if ext[kCMFormatDescriptionExtension_FieldCount as String] != nil {
                guard (try? AVCanonicalScanDescriptionV4(extensions: ext).state.cadence)
                    == .progressive else { return nil }
            }
            if codec == kCMVideoCodecType_H264 {
                guard let avc, avc.facts.bitDepth == 8, avc.facts.chromaFormat == 1,
                      avc.facts.progressive else { return nil }
            } else {
                guard let atoms = ext["SampleDescriptionExtensionAtoms"] as? NSDictionary,
                      let configuration = atoms["hvcC"] as? Data, configuration.count >= 23,
                      configuration[0] == 1, configuration[16] & 3 == 1,
                      configuration[17] & 7 == 0, configuration[18] & 7 == 0,
                      (ext[kCMFormatDescriptionExtension_BitsPerComponent as String] as? NSNumber)?.intValue == 8,
                      (try? AVCanonicalScanDescriptionV4(extensions: ext).state.cadence) == .progressive else { return nil }
            }
            let dimensions = CMVideoFormatDescriptionGetDimensions(description)
            let width = Int(dimensions.width), height = Int(dimensions.height)
            guard width > 0, height > 0, width <= 32768, height <= 32768,
                  description.presentationDimensions(usePixelAspectRatio: true, useCleanAperture: true)
                    == CGSize(width: width, height: height) else { return nil }
            if let aspect = ext[kCMFormatDescriptionExtension_PixelAspectRatio as String] as? NSDictionary {
                guard let h = aspect[kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing as String] as? NSNumber,
                      let v = aspect[kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing as String] as? NSNumber,
                      h.int64Value > 0, h == v else { return nil }
            }
            if ext[kCMFormatDescriptionExtension_CleanAperture as String] != nil {
                guard description.cleanAperture(originIsAtTopLeft: true)
                    == CGRect(x: 0, y: 0, width: width, height: height) else { return nil }
            }
            guard let primaries = ext[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String,
                  let transfer = ext[kCMFormatDescriptionExtension_TransferFunction as String] as? String,
                  [kCVImageBufferTransferFunction_ITU_R_709_2 as String,
                   kCVImageBufferTransferFunction_sRGB as String].contains(transfer),
                  let matrix = ext[kCMFormatDescriptionExtension_YCbCrMatrix as String] as? String,
                  [kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String,
                   kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String].contains(matrix),
                  let siting = avc?.location ?? AVCChromaLocationV4.canonicalLocation(
                    ext[kCMFormatDescriptionExtension_ChromaLocationTopField as String] as? String),
                  [.left, .center, .topLeft, .top, .bottomLeft, .bottom].contains(siting) else { return nil }
            let fullRange = (ext[kCMFormatDescriptionExtension_FullRangeVideo as String] as? NSNumber)?.boolValue ?? false
            let current = Contract(width: width, height: height, siting: siting,
                fullRange: fullRange, primaries: primaries, transfer: transfer, matrix: matrix)
            guard first == nil || first == current else { return nil }
            first = current
        }
        return first
    }

    /// Nil means this media family still uses the existing image-generator path.
    /// A qualified family's decode/conversion failure throws instead of returning an incorrect image.
    static func image(
        asset: AVAsset, at time: CMTime, size: CGSize
    ) async throws -> CGImage? {
        var selected: AVAssetTrack?
        for track in try await asset.loadTracks(withMediaType: .video) {
            if try await track.load(.isEnabled) {
                guard selected == nil else { return nil }
                selected = track
            }
        }
        guard let track = selected else { return nil }
        let descriptions = try await track.load(.formatDescriptions)
        guard let contract = try contract(descriptions: descriptions,
            transform: try await track.load(.preferredTransform),
            characteristics: try await track.load(.mediaCharacteristics)) else { return nil }
        try Task.checkCancellation()
        let reader = try AVAssetReader(asset: asset)
        let pixelFormat = contract.fullRange ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw Failure(reason: "thumbnail_reader_output") }
        reader.add(output)
        let range = try await track.load(.timeRange)
        let remaining = CMTimeSubtract(CMTimeRangeGetEnd(range), time)
        guard time.isNumeric, remaining.isNumeric, CMTimeCompare(remaining, .zero) > 0 else {
            throw Failure(reason: "thumbnail_time_outside_track")
        }
        reader.timeRange = CMTimeRange(start: time, duration: remaining)
        defer { reader.cancelReading() }
        guard reader.startReading() else { throw reader.error ?? Failure(reason: "thumbnail_reader_start") }
        guard let sample = output.copyNextSampleBuffer(),
              CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample), time) == 0,
              let buffer = CMSampleBufferGetImageBuffer(sample) else {
            throw reader.error ?? Failure(reason: "thumbnail_reader_time")
        }
        let locations = try AVCChromaLocationV4.interpretedDecodedLocations(
            buffer, source: AVCChromaLocationV4.declaration(from: descriptions))
        if let top = locations.top {
            guard AVCChromaLocationV4.canonicalLocation(top) == contract.siting else {
                throw Failure(reason: "thumbnail_decoded_phase_contract")
            }
        }
        try Task.checkCancellation()
        return try image(buffer: buffer, contract: contract, size: size)
    }

    static func image(buffer: CVPixelBuffer, contract: Contract, size: CGSize) throws -> CGImage {
        guard size.width.isFinite, size.height.isFinite,
              size.width >= 1, size.height >= 1,
              size.width <= 1600, size.height <= 1000 else {
            throw Failure(reason: "thumbnail_size")
        }
        let width = Int(size.width), height = Int(size.height)
        guard width > 0, height > 0,
              size.width == Double(width), size.height == Double(height),
              width <= 1600, height <= 1000,
              CVPixelBufferGetWidth(buffer) == contract.width,
              CVPixelBufferGetHeight(buffer) == contract.height,
              CVPixelBufferGetPlaneCount(buffer) == 2,
              CVPixelBufferGetPixelFormatType(buffer) == (contract.fullRange
                ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
              let attachments = CVBufferCopyAttachments(buffer, .shouldPropagate),
              let colorSpace = CVImageBufferCreateColorSpaceFromAttachments(attachments)?.takeRetainedValue(),
              colorSpace.model == .rgb else { throw Failure(reason: "thumbnail_buffer_contract") }
        let values = attachments as NSDictionary
        guard values[kCVImageBufferColorPrimariesKey as String] as? String == contract.primaries,
              values[kCVImageBufferTransferFunctionKey as String] as? String == contract.transfer,
              values[kCVImageBufferYCbCrMatrixKey as String] as? String == contract.matrix,
              (values[kCVImageBufferFieldCountKey as String] as? NSNumber)?.intValue == 1,
              values[kCVImageBufferMasteringDisplayColorVolumeKey as String] == nil,
              values[kCVImageBufferContentLightLevelInfoKey as String] == nil else {
            throw Failure(reason: "thumbnail_decoded_color_contract")
        }
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
            throw Failure(reason: "thumbnail_buffer_lock")
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let cw = (contract.width + 1) / 2, ch = (contract.height + 1) / 2
        let ys = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let cs = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        guard CVPixelBufferGetWidthOfPlane(buffer, 0) == contract.width,
              CVPixelBufferGetHeightOfPlane(buffer, 0) == contract.height,
              CVPixelBufferGetWidthOfPlane(buffer, 1) == cw,
              CVPixelBufferGetHeightOfPlane(buffer, 1) == ch,
              ys >= contract.width, cs >= cw * 2,
              let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)?.assumingMemoryBound(to: UInt8.self),
              let cBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)?.assumingMemoryBound(to: UInt8.self) else {
            throw Failure(reason: "thumbnail_decoded_planes")
        }
        let phase: (Int, Int) = switch contract.siting {
        case .left: (0, 1)
        case .center: (1, 1)
        case .topLeft: (0, 0)
        case .top: (1, 0)
        case .bottomLeft: (0, 2)
        case .bottom: (1, 2)
        default: throw Failure(reason: "thumbnail_phase")
        }
        let k: Int128 = contract.matrix == kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String ? 10000 : 1000
        let kr: Int128 = k == 10000 ? 2126 : 299
        let kb: Int128 = k == 10000 ? 722 : 114
        let kg = k - kr - kb
        let yd: Int128 = contract.fullRange ? 1 : 219
        let cd: Int128 = contract.fullRange ? 1 : 224
        let scale: Int128 = contract.fullRange ? 1 : 255
        let offset: Int128 = contract.fullRange ? 0 : 16
        let denominator = Int128(16 * width * height)
        let rgbDenominator = denominator * yd * cd * k
        var pixels = Data(count: width * height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let target = bytes.bindMemory(to: UInt8.self)
            for row in 0..<height {
                if row & 15 == 0 { try Task.checkCancellation() }
                let y = (2 * row + 1) * contract.height - height
                for column in 0..<width {
                    let x = (2 * column + 1) * contract.width - width
                    let luma = sample(yBase, stride: ys, step: 1, component: 0,
                        width: contract.width, height: contract.height,
                        x: x, xd: 2 * width, y: y, yd: 2 * height) * 4
                    let cb = sample(cBase, stride: cs, step: 2, component: 0, width: cw, height: ch,
                        x: x - phase.0 * width, xd: 4 * width,
                        y: y - phase.1 * height, yd: 4 * height) - 128 * denominator
                    let cr = sample(cBase, stride: cs, step: 2, component: 1, width: cw, height: ch,
                        x: x - phase.0 * width, xd: 4 * width,
                        y: y - phase.1 * height, yd: 4 * height) - 128 * denominator
                    let lum = (luma - offset * denominator) * scale
                    let common = lum * cd * k
                    let r = common + 2 * (k - kr) * cr * scale * yd
                    let b = common + 2 * (k - kb) * cb * scale * yd
                    let g = common * kg - 2 * kb * (k - kb) * cb * scale * yd
                        - 2 * kr * (k - kr) * cr * scale * yd
                    let destination = (row * width + column) * 4
                    target[destination] = code(r, denominator: rgbDenominator)
                    target[destination + 1] = code(g, denominator: rgbDenominator * kg)
                    target[destination + 2] = code(b, denominator: rgbDenominator)
                    target[destination + 3] = 255
                }
            }
        }
        guard let provider = CGDataProvider(data: pixels as CFData),
              let result = CGImage(width: width, height: height, bitsPerComponent: 8,
                bitsPerPixel: 32, bytesPerRow: width * 4, space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
                    .union(.byteOrder32Big), provider: provider, decode: nil,
                shouldInterpolate: true, intent: .defaultIntent) else {
            throw Failure(reason: "thumbnail_image_creation")
        }
        return result
    }

    private static func sample(_ base: UnsafePointer<UInt8>, stride: Int, step: Int,
        component: Int, width: Int, height: Int, x: Int, xd: Int, y: Int, yd: Int) -> Int128 {
        let cx = min(max(x, 0), (width - 1) * xd)
        let cy = min(max(y, 0), (height - 1) * yd)
        let ix = cx / xd, iy = cy / yd, fx = cx % xd, fy = cy % yd
        let nx = min(ix + 1, width - 1), ny = min(iy + 1, height - 1)
        let a = Int128(base[iy * stride + ix * step + component]) * Int128(xd - fx)
            + Int128(base[iy * stride + nx * step + component]) * Int128(fx)
        let b = Int128(base[ny * stride + ix * step + component]) * Int128(xd - fx)
            + Int128(base[ny * stride + nx * step + component]) * Int128(fx)
        return a * Int128(yd - fy) + b * Int128(fy)
    }

    private static func code(_ value: Int128, denominator: Int128) -> UInt8 {
        guard value > 0 else { return 0 }
        let rounded = (2 * value + denominator) / (2 * denominator)
        return rounded >= 255 ? 255 : UInt8(rounded)
    }
}
