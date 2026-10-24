import AVFoundation
import CoreVideo
import CoreGraphics
import CoreMedia
import CryptoKit
import Darwin
import Foundation

enum AVCanonicalMediaStateAdapterV4Error: Error, Equatable, Sendable {
    case localFileRequired(String)
    case regularFileRequired(String)
    case inputChangedDuringProbe
    case fileReadFailed(String)
    case nonNumericTime(path: String)
    case nonPositiveTimeScale(path: String, value: Int32)
    case nonzeroTimeEpoch(path: String, value: Int64)
    case roundedTime(path: String)
    case nonFiniteGeometry(path: String)
    case geometryOutsideExactRationalDomain(path: String)
    case unsupportedPropertyList(path: String, type: String)
    case avFoundationLoadFailed(path: String, reason: String)
    case canonicalizationRejected([CanonicalMediaObservationV4])
}

struct ASHStreamingFileIdentityV4: Equatable, Sendable {
    let contentSHA256: ASHSHA256V4
    let byteCount: Int64
    private let snapshot: FileSnapshot

    private struct FileSnapshot: Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
        let statusChangeSeconds: Int64
        let statusChangeNanoseconds: Int64

        init(_ status: stat) {
            device = UInt64(truncatingIfNeeded: status.st_dev)
            inode = UInt64(truncatingIfNeeded: status.st_ino)
            size = status.st_size
            modificationSeconds = Int64(status.st_mtimespec.tv_sec)
            modificationNanoseconds = Int64(status.st_mtimespec.tv_nsec)
            statusChangeSeconds = Int64(status.st_ctimespec.tv_sec)
            statusChangeNanoseconds = Int64(status.st_ctimespec.tv_nsec)
        }
    }

    static func read(
        url: URL,
        chunkByteCount: Int = 1_048_576
    ) throws -> Self {
        guard url.isFileURL else {
            throw AVCanonicalMediaStateAdapterV4Error.localFileRequired(
                url.absoluteString
            )
        }
        guard chunkByteCount > 0 else {
            throw AVCanonicalMediaStateAdapterV4Error.fileReadFailed(
                "chunk size must be positive"
            )
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw AVCanonicalMediaStateAdapterV4Error.fileReadFailed(
                String(describing: error)
            )
        }
        defer { try? handle.close() }

        var before = stat()
        guard fstat(handle.fileDescriptor, &before) == 0 else {
            throw AVCanonicalMediaStateAdapterV4Error.fileReadFailed(
                String(cString: strerror(errno))
            )
        }
        guard (before.st_mode & S_IFMT) == S_IFREG else {
            throw AVCanonicalMediaStateAdapterV4Error.regularFileRequired(
                url.path
            )
        }

        var hasher = SHA256()
        var observedByteCount: Int64 = 0
        do {
            while let data = try handle.read(upToCount: chunkByteCount),
                  !data.isEmpty {
                hasher.update(data: data)
                let (nextCount, overflow) = observedByteCount
                    .addingReportingOverflow(Int64(data.count))
                guard !overflow else {
                    throw AVCanonicalMediaStateAdapterV4Error.fileReadFailed(
                        "input byte count overflow"
                    )
                }
                observedByteCount = nextCount
                try Task.checkCancellation()
            }
        } catch let error as AVCanonicalMediaStateAdapterV4Error {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AVCanonicalMediaStateAdapterV4Error.fileReadFailed(
                String(describing: error)
            )
        }

        var after = stat()
        guard fstat(handle.fileDescriptor, &after) == 0 else {
            throw AVCanonicalMediaStateAdapterV4Error.fileReadFailed(
                String(cString: strerror(errno))
            )
        }
        var pathStatus = stat()
        let pathStatusResult = Self.status(at: url, into: &pathStatus)
        guard pathStatusResult == 0,
              Self.sameIdentity(before, after),
              Self.sameIdentity(after, pathStatus),
              observedByteCount == after.st_size else {
            throw AVCanonicalMediaStateAdapterV4Error.inputChangedDuringProbe
        }
        let digest = hasher.finalize().map {
            String(format: "%02x", $0)
        }.joined()
        return Self(
            contentSHA256: try ASHSHA256V4(digest),
            byteCount: observedByteCount,
            snapshot: FileSnapshot(after)
        )
    }

    func verifyUnchanged(url: URL) throws {
        var status = stat()
        let result = Self.status(at: url, into: &status)
        guard result == 0, FileSnapshot(status) == snapshot else {
            throw AVCanonicalMediaStateAdapterV4Error.inputChangedDuringProbe
        }
    }

    private static func status(at url: URL, into status: inout stat) -> Int32 {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return -1 }
        defer { try? handle.close() }
        return fstat(handle.fileDescriptor, &status)
    }

    private static func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }
}

enum ASHExactBinaryRationalV4 {
    static func convert(
        _ value: CGFloat,
        path: String
    ) throws -> ExactRationalV4 {
        try convert(Double(value), path: path)
    }

    static func convert(
        _ value: Double,
        path: String
    ) throws -> ExactRationalV4 {
        let bits = value.bitPattern
        let exponentBits = Int((bits >> 52) & 0x7ff)
        let fraction = bits & 0x000f_ffff_ffff_ffff
        guard exponentBits != 0x7ff else {
            throw AVCanonicalMediaStateAdapterV4Error.nonFiniteGeometry(
                path: path
            )
        }
        var significand: UInt64
        var binaryExponent: Int
        if exponentBits == 0 {
            significand = fraction
            binaryExponent = -1_074
        } else {
            significand = (UInt64(1) << 52) | fraction
            binaryExponent = exponentBits - 1_023 - 52
        }
        guard significand != 0 else { return .zero }

        if binaryExponent < 0 {
            let cancellation = min(
                significand.trailingZeroBitCount,
                -binaryExponent
            )
            significand >>= UInt64(cancellation)
            binaryExponent += cancellation
        }
        let isNegative = (bits >> 63) != 0
        if binaryExponent >= 0 {
            guard binaryExponent < 64,
                  significand <= (UInt64.max >> UInt64(binaryExponent)) else {
                throw AVCanonicalMediaStateAdapterV4Error
                    .geometryOutsideExactRationalDomain(path: path)
            }
            let magnitude = significand << UInt64(binaryExponent)
            let numerator = try signed(
                magnitude: magnitude,
                isNegative: isNegative,
                path: path
            )
            return try ExactRationalV4(numerator)
        }

        let denominatorExponent = -binaryExponent
        guard denominatorExponent <= 62 else {
            throw AVCanonicalMediaStateAdapterV4Error
                .geometryOutsideExactRationalDomain(path: path)
        }
        let numerator = try signed(
            magnitude: significand,
            isNegative: isNegative,
            path: path
        )
        return try ExactRationalV4(
            numerator,
            Int64(1) << Int64(denominatorExponent)
        )
    }

    private static func signed(
        magnitude: UInt64,
        isNegative: Bool,
        path: String
    ) throws -> Int64 {
        if isNegative, magnitude == Int64.min.magnitude {
            return Int64.min
        }
        guard magnitude <= UInt64(Int64.max) else {
            throw AVCanonicalMediaStateAdapterV4Error
                .geometryOutsideExactRationalDomain(path: path)
        }
        let positive = Int64(magnitude)
        return isNegative ? -positive : positive
    }
}

enum ASHExactCMTimeV4 {
    static func convert(
        _ time: CMTime,
        path: String
    ) throws -> ExactRationalV4 {
        guard time.isNumeric else {
            throw AVCanonicalMediaStateAdapterV4Error.nonNumericTime(path: path)
        }
        guard time.timescale > 0 else {
            throw AVCanonicalMediaStateAdapterV4Error.nonPositiveTimeScale(
                path: path,
                value: time.timescale
            )
        }
        guard time.epoch == 0 else {
            throw AVCanonicalMediaStateAdapterV4Error.nonzeroTimeEpoch(
                path: path,
                value: time.epoch
            )
        }
        guard !time.flags.contains(.hasBeenRounded) else {
            throw AVCanonicalMediaStateAdapterV4Error.roundedTime(path: path)
        }
        return try ExactRationalV4(time.value, Int64(time.timescale))
    }
}

enum ASHCanonicalPropertyListV4 {
    static func data(_ value: Any, path: String) throws -> Data {
        ASHCanonicalJSONV4.encode(try canonicalValue(value, path: path))
    }

    private static func canonicalValue(
        _ value: Any,
        path: String
    ) throws -> ASHCanonicalJSONValueV4 {
        if value is NSNull {
            return .null
        }
        if let string = value as? String {
            return .object([
                "type": .string("string"),
                "value": .string(string)
            ])
        }
        if let data = value as? Data {
            return .object([
                "type": .string("data"),
                "byte_count": .string(String(data.count)),
                "sha256": .string(ASHSHA256V4(rawData: data).rawValue)
            ])
        }
        if let date = value as? Date {
            return .object([
                "type": .string("date_binary64"),
                "value": .string(
                    String(format: "%016llx", date.timeIntervalSinceReferenceDate.bitPattern)
                )
            ])
        }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .object([
                    "type": .string("boolean"),
                    "value": .boolean(number.boolValue)
                ])
            }
            let type = String(cString: number.objCType)
            switch type {
            case "f":
                return .object([
                    "type": .string("float32"),
                    "value": .string(
                        String(format: "%08x", number.floatValue.bitPattern)
                    )
                ])
            case "d":
                return .object([
                    "type": .string("float64"),
                    "value": .string(
                        String(format: "%016llx", number.doubleValue.bitPattern)
                    )
                ])
            case "c", "s", "i", "l", "q", "C", "S", "I", "L", "Q":
                return .object([
                    "objc_type": .string(type),
                    "type": .string("integer"),
                    "value": .string(number.stringValue)
                ])
            default:
                throw AVCanonicalMediaStateAdapterV4Error.unsupportedPropertyList(
                    path: path,
                    type: "NSNumber<\(type)>"
                )
            }
        }
        if let array = value as? [Any] {
            return .array(
                try array.enumerated().map { index, element in
                    try canonicalValue(element, path: "\(path)[\(index)]")
                }
            )
        }
        if let array = value as? NSArray {
            return try canonicalValue(array.map { $0 }, path: path)
        }
        if let dictionary = value as? [String: Any] {
            var object: [String: ASHCanonicalJSONValueV4] = [:]
            for (key, element) in dictionary {
                object[key] = try canonicalValue(
                    element,
                    path: "\(path).\(key)"
                )
            }
            return .object(object)
        }
        if let dictionary = value as? NSDictionary {
            var converted: [String: Any] = [:]
            for (key, element) in dictionary {
                guard let key = key as? String else {
                    throw AVCanonicalMediaStateAdapterV4Error
                        .unsupportedPropertyList(
                            path: path,
                            type: "dictionary-key<\(type(of: key))>"
                        )
                }
                converted[key] = element
            }
            return try canonicalValue(converted, path: path)
        }
        throw AVCanonicalMediaStateAdapterV4Error.unsupportedPropertyList(
            path: path,
            type: String(reflecting: type(of: value))
        )
    }
}

/// Resolve omitted color tags using the same decoder that supplies processing
/// pixels. SD material can resolve to BT.601; assuming BT.709 here changes color.
/// Explicit declarations and changing format descriptions are never replaced.
/// Sampling facts absent from legacy QuickTime format descriptions. Read the
/// compressed headers rather than interpreting the packed RGB `Depth` field
/// as a component precision or assuming that every codec uses video range.
struct LegacyVideoSamplingFacts: Equatable, Sendable {
    let bitDepth: UInt8
    let fullRange: Bool
    let subsampling: CanonicalChromaSubsamplingV4

    static func resolve(
        asset: AVAsset, track: AVAssetTrack,
        descriptions: [CMFormatDescription]
    ) throws -> Self? {
        guard descriptions.count == 1, let description = descriptions.first else { return nil }
        let codec = CMFormatDescriptionGetMediaSubType(description)
        if codec == kCMVideoCodecType_MPEG4Video {
            let extensions = CMFormatDescriptionGetExtensions(description) as NSDictionary?
            guard let atoms = extensions?["SampleDescriptionExtensionAtoms"] as? NSDictionary,
                  let esds = atoms["esds"] as? Data else { return nil }
            return mpeg4(esds)
        }
        guard [kCMVideoCodecType_JPEG, kCMVideoCodecType_JPEG_OpenDML].contains(codec) else { return nil }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        defer { reader.cancelReading() }
        guard reader.startReading() else { throw reader.error ?? failure("Cannot read JPEG headers.") }
        var facts: Self?
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let count = CMSampleBufferGetNumSamples(sample)
            guard count > 0 else { continue }
            guard let buffer = CMSampleBufferGetDataBuffer(sample) else { return nil }
            let length = CMBlockBufferGetDataLength(buffer)
            guard length > 0, length <= 64 * 1024 * 1024, count <= length else { return nil }
            var bytes = Data(count: length)
            let status = bytes.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(buffer, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
            }
            guard status == noErr else { return nil }
            var offset = 0
            for index in 0..<count {
                let size = CMSampleBufferGetSampleSize(sample, at: index)
                guard size > 0, size <= length - offset,
                      let current = jpeg(bytes.subdata(in: offset..<(offset + size))) else { return nil }
                if let facts, facts != current { throw failure("JPEG sampling changes within the video track.") }
                facts = current
                offset += size
            }
            guard offset == length else { return nil }
        }
        guard reader.status == .completed else { throw reader.error ?? failure("Cannot finish reading JPEG headers.") }
        return facts
    }

    private static func failure(_ reason: String) -> AVCanonicalMediaStateAdapterV4Error {
        .avFoundationLoadFailed(path: "video.legacy_sampling", reason: reason)
    }

    static func jpeg(_ data: Data) -> Self? {
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
                      b[i + 8] == 1, b[i + 11] == 2, b[i + 14] == 3,
                      b[i + 12] == 0x11, b[i + 15] == 0x11 else { return nil }
                let sampling: CanonicalChromaSubsamplingV4
                switch b[i + 9] {
                case 0x22: sampling = .yuv420
                case 0x21: sampling = .yuv422
                case 0x11: sampling = .yuv444
                default: return nil
                }
                return Self(bitDepth: 8, fullRange: true, subsampling: sampling)
            }
            i += length
        }
        return nil
    }

    static func mpeg4(_ data: Data) -> Self? {
        let b = [UInt8](data)
        guard b.count >= 8 else { return nil }
        var fullRange = false
        var result: Self?
        for i in 0..<(b.count - 4) where b[i] == 0 && b[i + 1] == 0 && b[i + 2] == 1 {
            var bits = HeaderBits(bytes: Array(b[(i + 4)...]))
            let code = b[i + 3]
            if code == 0xb5 {
                guard let identifier = bits.read(1) else { return nil }
                if identifier == 1, bits.read(7) == nil { return nil }
                guard bits.read(4) == 1, let signal = bits.read(1) else { return nil }
                if signal == 1 {
                    guard bits.read(3) != nil, let range = bits.read(1),
                          let color = bits.read(1) else { return nil }
                    fullRange = range == 1
                    if color == 1, bits.read(24) == nil { return nil }
                }
            }
            guard (0x20...0x2f).contains(code) else { continue }
            guard bits.read(1) != nil, let object = bits.read(8),
                  [1, 17].contains(object), let identifier = bits.read(1) else { return nil }
            var version = 1
            if identifier == 1 {
                guard let value = bits.read(4), value > 0, bits.read(3) != nil else { return nil }
                version = value
            }
            guard let aspect = bits.read(4) else { return nil }
            if aspect == 15, bits.read(16) == nil { return nil }
            guard let control = bits.read(1) else { return nil }
            if control == 1 {
                guard bits.read(2) == 1, bits.read(1) != nil,
                      let vbv = bits.read(1) else { return nil }
                if vbv == 1 {
                    for width in [15, 15, 15, 14, 15] {
                        guard bits.read(width) != nil, bits.read(1) == 1 else { return nil }
                    }
                }
            }
            guard bits.read(2) == 0, bits.read(1) == 1,
                  let clock = bits.read(16), clock > 0, bits.read(1) == 1,
                  let fixed = bits.read(1) else { return nil }
            if fixed == 1 {
                let width = max(1, Int.bitWidth - (clock - 1).leadingZeroBitCount)
                guard bits.read(width) != nil else { return nil }
            }
            guard bits.read(1) == 1, let width = bits.read(13), width > 0,
                  bits.read(1) == 1, let height = bits.read(13), height > 0,
                  bits.read(1) == 1, bits.read(1) == 0,
                  bits.read(1) != nil, bits.read(version == 1 ? 1 : 2) == 0,
                  let nonEightBit = bits.read(1) else { return nil }
            if nonEightBit == 1 {
                guard bits.read(4) != nil, bits.read(4) == 8 else { return nil }
            }
            let current = Self(bitDepth: 8, fullRange: fullRange, subsampling: .yuv420)
            if let result, result != current { return nil }
            result = current
        }
        return result
    }

    private struct HeaderBits {
        let bytes: [UInt8]
        var offset = 0
        mutating func read(_ width: Int) -> Int? {
            guard width >= 0, width <= 24, offset + width <= bytes.count * 8 else { return nil }
            var result = 0
            for _ in 0..<width {
                result = (result << 1) | Int((bytes[offset / 8] >> (7 - offset % 8)) & 1)
                offset += 1
            }
            return result
        }
    }
}

enum VideoDecodedColorResolver {
    static func resolve(
        asset: AVAsset,
        track: AVAssetTrack,
        descriptions: [CMFormatDescription]
    ) throws -> [String: String] {
        let keys = [
            kCVImageBufferColorPrimariesKey,
            kCVImageBufferTransferFunctionKey,
            kCVImageBufferYCbCrMatrixKey
        ]
        guard descriptions.count == 1, let description = descriptions.first else {
            return [:]
        }
        let extensions = (
            CMFormatDescriptionGetExtensions(description) as NSDictionary?
        ) ?? [:]
        let missing = keys.filter { extensions[$0 as String] == nil }
        guard !missing.isEmpty else { return [:] }
        try Task.checkCancellation()
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        ])
        guard reader.canAdd(output) else {
            throw AVCanonicalMediaStateAdapterV4Error.avFoundationLoadFailed(
                path: "video.decoded_color",
                reason: "The video decoder cannot resolve missing color information."
            )
        }
        reader.add(output)
        defer { reader.cancelReading() }
        guard reader.startReading(),
              let sample = output.copyNextSampleBuffer(),
              let buffer = CMSampleBufferGetImageBuffer(sample) else {
            throw AVCanonicalMediaStateAdapterV4Error.avFoundationLoadFailed(
                path: "video.decoded_color",
                reason: reader.error?.localizedDescription
                    ?? "The video decoder could not read a frame to resolve missing color information."
            )
        }
        try Task.checkCancellation()
        var resolved: [String: String] = [:]
        for key in missing {
            if let value = CVBufferCopyAttachment(buffer, key, nil) as? String {
                resolved[key as String] = value
            }
        }
        return resolved
    }
}
