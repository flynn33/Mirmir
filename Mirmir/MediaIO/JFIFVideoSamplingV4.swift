import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// Source sampling proof, separate from JPEG's sequential/progressive coding
/// mode. Video scan/raster declarations and complete image framing are required.
struct JFIFVideoSamplingV4: Equatable, Sendable {
    let width: Int32
    let height: Int32

    static func progressiveDeclaration(from description: CMFormatDescription) throws -> Self? {
        guard CMFormatDescriptionGetMediaType(description) == kCMMediaType_Video,
              [kCMVideoCodecType_JPEG, kCMVideoCodecType_JPEG_OpenDML]
                .contains(CMFormatDescriptionGetMediaSubType(description)) else { return nil }
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        let extensions = CMFormatDescriptionGetExtensions(description) as NSDictionary? ?? [:]
        guard dimensions.width > 0, dimensions.height > 0,
              let count = extensions[kCMFormatDescriptionExtension_FieldCount as String] as? NSNumber,
              count.doubleValue == 1,
              extensions[kCMFormatDescriptionExtension_FieldDetail as String] == nil else {
            throw failure("JFIF progressive video requires one declared full-raster field; JPEG coding mode is insufficient.")
        }
        for (key, expected) in [(kCMFormatDescriptionExtension_BitsPerComponent, 8),
                                (kCMFormatDescriptionExtension_FullRangeVideo, 1)] {
            if let raw = extensions[key as String] {
                guard let value = raw as? NSNumber, value.doubleValue == Double(expected) else {
                    throw failure("JFIF and container depth/range declarations disagree.")
                }
            }
        }
        if let raw = extensions[kCVImageBufferChromaSubsamplingKey as String] {
            guard let value = raw as? String,
                  value == kCVImageBufferChromaSubsampling_420 as String else {
                throw failure("JFIF and container subsampling declarations disagree.")
            }
        }
        for key in [kCMFormatDescriptionExtension_ChromaLocationTopField,
                    kCMFormatDescriptionExtension_ChromaLocationBottomField] {
            if let raw = extensions[key as String] {
                guard let value = raw as? String,
                      value == kCMFormatDescriptionChromaLocation_Center as String else {
                    throw failure("JFIF and container chroma locations disagree.")
                }
            }
        }
        return Self(width: dimensions.width, height: dimensions.height)
    }

    func validatePacket(_ data: Data) throws {
        guard let raster = Self.fullImageRaster(data),
              raster.0 == Int(width), raster.1 == Int(height) else {
            throw Self.failure("The declared progressive JFIF frame does not contain exactly one complete matching 4:2:0 image.")
        }
    }

    /// T.871 section9 defines centered component registration for JFIF. A
    /// complete codestream proves image ownership; SOF2 alone says nothing
    /// about a movie's field count.
    static func fullImageRaster(_ data: Data) -> (Int, Int)? {
        guard (4...67_108_864).contains(data.count) else { return nil }
        let b = [UInt8](data)
        guard b[0] == 0xff, b[1] == 0xd8 else { return nil }
        var cursor = 2, image: (Int, Int)?, jfif = false, sawScan = false
        var scanComponents: Set<UInt8> = []
        while cursor < b.count {
            guard b[cursor] == 0xff else { return nil }
            while cursor < b.count, b[cursor] == 0xff { cursor += 1 }
            guard cursor < b.count else { return nil }
            let marker = b[cursor]; cursor += 1
            if marker == 0xd9 {
                guard cursor == b.count, jfif, sawScan, scanComponents == [1, 2, 3] else { return nil }
                return image
            }
            guard marker != 0, marker != 0xd8, !(0xd0...0xd7).contains(marker),
                  cursor + 2 <= b.count else { return nil }
            let length = Int(b[cursor]) * 256 + Int(b[cursor + 1])
            guard length >= 2, length <= b.count - cursor else { return nil }
            let begin = cursor + 2, end = cursor + length
            if marker == 0xe0, length >= 7,
               Array(b[begin..<(begin + 5)]) == Array("JFIF\0".utf8) {
                guard !jfif, !sawScan, length >= 16,
                      b[begin + 5] == 1, b[begin + 6] <= 2,
                      b[begin + 7] <= 2,
                      Int(b[begin + 8]) * 256 + Int(b[begin + 9]) > 0,
                      Int(b[begin + 10]) * 256 + Int(b[begin + 11]) > 0,
                      length == 16 + 3 * Int(b[begin + 12]) * Int(b[begin + 13]) else { return nil }
                jfif = true
            }
            if marker == 0xee, length >= 14,
               Array(b[begin..<(begin + 5)]) == Array("Adobe".utf8), b[begin + 11] != 1 {
                return nil
            }
            if [UInt8(0xc0), 0xc1, 0xc2].contains(marker) {
                guard image == nil, jfif, !sawScan, length == 17,
                      b[begin] == 8, b[begin + 5] == 3,
                      b[begin + 6] == 1, b[begin + 7] == 0x22, b[begin + 8] <= 3,
                      b[begin + 9] == 2, b[begin + 10] == 0x11, b[begin + 11] <= 3,
                      b[begin + 12] == 3, b[begin + 13] == 0x11, b[begin + 14] <= 3 else { return nil }
                let height = Int(b[begin + 1]) * 256 + Int(b[begin + 2])
                let width = Int(b[begin + 3]) * 256 + Int(b[begin + 4])
                guard width > 0, height > 0 else { return nil }
                image = (width, height)
            } else if !([UInt8(0xc4), 0xdb, 0xdd, 0xda, 0xfe].contains(marker)
                        || (0xe0...0xef).contains(marker)) {
                return nil
            }
            cursor = end
            if marker == 0xda {
                guard image != nil, length >= 6 else { return nil }
                let count = Int(b[begin])
                guard (1...3).contains(count), length == 6 + 2 * count else { return nil }
                var ids: Set<UInt8> = []
                for index in 0..<count {
                    let id = b[begin + 1 + 2 * index]
                    guard (1...3).contains(id), ids.insert(id).inserted else { return nil }
                    scanComponents.insert(id)
                }
                sawScan = true
                var found = false
                while cursor < b.count {
                    if b[cursor] != 0xff { cursor += 1; continue }
                    let start = cursor
                    while cursor < b.count, b[cursor] == 0xff { cursor += 1 }
                    guard cursor < b.count else { return nil }
                    if b[cursor] == 0 || (0xd0...0xd7).contains(b[cursor]) { cursor += 1; continue }
                    cursor = start; found = true; break
                }
                guard found else { return nil }
            }
        }
        return nil
    }

    static func normalizeDecodedBuffer(_ buffer: CVPixelBuffer, source: Self?) throws {
        guard let source else { return }
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
              CVPixelBufferGetWidth(buffer) == Int(source.width),
              CVPixelBufferGetHeight(buffer) == Int(source.height),
              CVPixelBufferGetPlaneCount(buffer) == 2,
              CVPixelBufferGetWidthOfPlane(buffer, 0) == Int(source.width),
              CVPixelBufferGetHeightOfPlane(buffer, 0) == Int(source.height),
              CVPixelBufferGetWidthOfPlane(buffer, 1) == (Int(source.width) + 1) / 2,
              CVPixelBufferGetHeightOfPlane(buffer, 1) == (Int(source.height) + 1) / 2 else {
            throw failure("The decoded JFIF surface contradicts its authenticated sampling/raster.")
        }
        if let raw = CVBufferCopyAttachment(buffer, kCVImageBufferChromaSubsamplingKey, nil) {
            guard let value = raw as? String, value == kCVImageBufferChromaSubsampling_420 as String else {
                throw failure("The decoded JFIF surface declares another subsampling grid.")
            }
        }
        if let raw = CVBufferCopyAttachment(buffer, kCMFormatDescriptionExtension_FullRangeVideo, nil) {
            guard let value = raw as? NSNumber, value.doubleValue == 1 else {
                throw failure("The decoded JFIF surface declares video range.")
            }
        }
        if let raw = CVBufferCopyAttachment(buffer, kCVImageBufferFieldCountKey, nil) {
            guard let value = raw as? NSNumber, value.doubleValue == 1 else {
                throw failure("The progressive JFIF surface declares another field count.")
            }
        }
        guard CVBufferCopyAttachment(buffer, kCVImageBufferFieldDetailKey, nil) == nil else {
            throw failure("The progressive JFIF surface declares interlaced field detail.")
        }
        for key in [kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocationBottomFieldKey] {
            if let raw = CVBufferCopyAttachment(buffer, key, nil) {
                guard let value = raw as? String, value == kCVImageBufferChromaLocation_Center as String else {
                    throw failure("The decoded JFIF chroma location contradicts the source proof.")
                }
            }
        }
        if CVBufferCopyAttachment(buffer, kCVImageBufferChromaLocationTopFieldKey, nil) == nil {
            CVBufferSetAttachment(buffer, kCVImageBufferChromaLocationTopFieldKey,
                                  kCVImageBufferChromaLocation_Center, .shouldPropagate)
        }
    }

    private static func failure(_ reason: String) -> AVCanonicalMediaStateAdapterV4Error {
        .avFoundationLoadFailed(path: "video.jfif_sampling", reason: reason)
    }
}
