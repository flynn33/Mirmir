import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// Packet/header facts, not an assertion that encoded ProRes has a bit-depth
/// field or that its native 4:2:0 decoder conversion is lossless.
struct ProRes422SourceFactsV4: Equatable, Sendable {
    let width: Int
    let height: Int
    let scan: ProRes422WorkingFormatV4.Scan
    let primariesCode: UInt8
    let transferCode: UInt8
    let matrixCode: UInt8

    enum Failure: LocalizedError {
        case unsupported(String)
        var errorDescription: String? {
            switch self { case .unsupported(let reason): "ProRes input: \(reason)" }
        }
    }

    static func supports(_ codec: FourCharCode) -> Bool {
        [kCMVideoCodecType_AppleProRes422, kCMVideoCodecType_AppleProRes422HQ,
         kCMVideoCodecType_AppleProRes422LT, kCMVideoCodecType_AppleProRes422Proxy].contains(codec)
    }

    static func header(_ data: Data) throws -> Self {
        guard (28...67_108_864).contains(data.count) else { throw Failure.unsupported("truncated frame header") }
        let b = [UInt8](data)
        func be16(_ n: Int) -> Int { Int(b[n]) * 256 + Int(b[n + 1]) }
        let size = b.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let headerSize = be16(8)
        guard Int(size) == b.count, Array(b[4..<8]) == Array("icpf".utf8),
              headerSize >= 20, headerSize <= b.count - 8,
              b[11] <= 1, b[20] >> 6 == 2, b[25] & 15 == 0,
              [0, 1, 2, 5, 6, 9, 11, 12].contains(b[22]),
              [0, 1, 2, 16, 18].contains(b[23]), [0, 1, 2, 6, 9].contains(b[24]),
              be16(16) > 0, be16(18) > 0 else {
            throw Failure.unsupported("frame ownership, version, raster or opaque422 declaration differs")
        }
        let scan: ProRes422WorkingFormatV4.Scan
        switch (b[20] >> 2) & 3 {
        case 0: scan = .progressive
        case 1: scan = .topFirst
        case 2: scan = .bottomFirst
        default: throw Failure.unsupported("reserved interlace mode")
        }
        return Self(width: be16(16), height: be16(18), scan: scan,
                    primariesCode: b[22], transferCode: b[23], matrixCode: b[24])
    }

    static func resolve(asset: AVAsset, track: AVAssetTrack,
                        descriptions: [CMFormatDescription]) throws -> Self? {
        guard descriptions.contains(where: { supports(CMFormatDescriptionGetMediaSubType($0)) }) else { return nil }
        guard descriptions.count == 1, let description = descriptions.first,
              supports(CMFormatDescriptionGetMediaSubType(description)) else {
            throw Failure.unsupported("changing source sample descriptions")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else { throw Failure.unsupported("compressed track cannot be read") }
        reader.add(output)
        defer { reader.cancelReading() }
        guard reader.startReading() else { throw reader.error ?? Failure.unsupported("reader did not start") }
        var facts: Self?
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let count = CMSampleBufferGetNumSamples(sample)
            if count == 0 { continue }
            guard let block = CMSampleBufferGetDataBuffer(sample) else {
                throw Failure.unsupported("compressed sample has no bytes")
            }
            let length = CMBlockBufferGetDataLength(block)
            guard length > 0, length <= 67_108_864, count <= length else {
                throw Failure.unsupported("compressed sample extent exceeds the bounded reader")
            }
            var bytes = Data(count: length)
            let status = bytes.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
            }
            guard status == noErr else { throw Failure.unsupported("compressed bytes unavailable") }
            var offset = 0
            for index in 0..<count {
                let size = CMSampleBufferGetSampleSize(sample, at: index)
                guard size > 0, size <= length - offset else { throw Failure.unsupported("sample extent differs") }
                let current = try header(bytes.subdata(in: offset..<(offset + size)))
                if let facts, facts != current { throw Failure.unsupported("raster, scan or color changes within the track") }
                try current.validate(description: description)
                facts = current; offset += size
            }
            guard offset == length else { throw Failure.unsupported("unowned sample bytes") }
        }
        guard reader.status == .completed, facts != nil else {
            throw reader.error ?? Failure.unsupported("no complete frame headers")
        }
        return facts
    }

    func validate(description: CMFormatDescription) throws {
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        let values = CMFormatDescriptionGetExtensions(description) as NSDictionary? ?? [:]
        guard Self.supports(CMFormatDescriptionGetMediaSubType(description)),
              Int(dimensions.width) == width, Int(dimensions.height) == height else {
            throw Failure.unsupported("container/header raster disagreement")
        }
        if let raw = values[kCMFormatDescriptionExtension_FieldCount as String] {
            guard let count = raw as? NSNumber, count.doubleValue == Double(scan.fieldCount) else {
                throw Failure.unsupported("container/header field-count disagreement")
            }
        }
        if let raw = values[kCMFormatDescriptionExtension_FieldDetail as String] {
            guard let detail = raw as? String, scan.agrees(with: detail) else {
                throw Failure.unsupported("container/header field-order disagreement")
            }
        }
        if let raw = values[kCMFormatDescriptionExtension_FullRangeVideo as String] {
            guard let full = raw as? NSNumber, full.doubleValue == 0 else {
                throw Failure.unsupported("container declares full range for native video-range v216")
            }
        }
        // Retain declared container color; fill absent labels from the frame,
        // before consulting a decoder's resolution-dependent fallback labels.
    }

    func colorFallback(over decoded: [String: String]) -> [String: String] {
        var result = decoded
        if let primaries {
            result[kCVImageBufferColorPrimariesKey as String] = primaries
        }
        if let transfer {
            result[kCVImageBufferTransferFunctionKey as String] = transfer
        }
        if let matrix {
            result[kCVImageBufferYCbCrMatrixKey as String] = matrix
        }
        return result
    }

    var primaries: String? {
        switch primariesCode {
        case 1: kCVImageBufferColorPrimaries_ITU_R_709_2 as String
        case 5: kCVImageBufferColorPrimaries_EBU_3213 as String
        case 6: kCVImageBufferColorPrimaries_SMPTE_C as String
        case 9: kCVImageBufferColorPrimaries_ITU_R_2020 as String
        case 11: kCVImageBufferColorPrimaries_DCI_P3 as String
        case 12: kCVImageBufferColorPrimaries_P3_D65 as String
        default: nil
        }
    }
    var transfer: String? {
        switch transferCode {
        case 1: kCVImageBufferTransferFunction_ITU_R_709_2 as String
        case 16: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String
        case 18: kCVImageBufferTransferFunction_ITU_R_2100_HLG as String
        default: nil
        }
    }
    var matrix: String? {
        switch matrixCode {
        case 1: kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String
        case 6: kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String
        case 9: kCVImageBufferYCbCrMatrix_ITU_R_2020 as String
        default: nil
        }
    }
}
