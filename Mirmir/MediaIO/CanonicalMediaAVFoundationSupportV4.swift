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

/// A complete rectangular, progressive, eight-bit MPEG-4 Part 2 VOL. The
/// admitted 4:2:0 codec sampling lattice is Left; an absent QuickTime attachment
/// does not change that lattice. Keep this proof separate from legacy partial
/// header extraction, which is also used for AVI transport admission.
struct MPEG4ProgressiveSamplingV4: Equatable, Sendable {
    let width: Int32
    let height: Int32
    let fullRange: Bool
    let sourceConfiguration: Data

    private init(width: Int32, height: Int32, fullRange: Bool, sourceConfiguration: Data) {
        self.width = width
        self.height = height
        self.fullRange = fullRange
        self.sourceConfiguration = sourceConfiguration
    }

    static func normalizeDecodedBuffer(_ buffer: CVPixelBuffer, source: Self?) throws {
        guard let source else { return }
        let expected = source.fullRange
            ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let width = Int(source.width), height = Int(source.height)
        guard CVPixelBufferGetPixelFormatType(buffer) == expected,
              CVPixelBufferGetWidth(buffer) == width, CVPixelBufferGetHeight(buffer) == height,
              CVPixelBufferGetPlaneCount(buffer) == 2,
              CVPixelBufferGetWidthOfPlane(buffer, 0) == width,
              CVPixelBufferGetHeightOfPlane(buffer, 0) == height,
              CVPixelBufferGetWidthOfPlane(buffer, 1) == (width + 1) / 2,
              CVPixelBufferGetHeightOfPlane(buffer, 1) == (height + 1) / 2 else {
            throw failure("The decoded MPEG-4 surface contradicts its authenticated sampling configuration.")
        }
        for (key, expected) in [
            (kCVImageBufferFieldCountKey, 1),
            (kCMFormatDescriptionExtension_FullRangeVideo, source.fullRange ? 1 : 0)
        ] {
            if let raw = CVBufferCopyAttachment(buffer, key, nil) {
                guard let value = raw as? NSNumber, value.doubleValue == Double(expected) else {
                    throw failure("The decoded MPEG-4 sampling declarations contradict the VOL.")
                }
            }
        }
        guard CVBufferCopyAttachment(buffer, kCVImageBufferFieldDetailKey, nil) == nil else {
            throw failure("The progressive MPEG-4 surface declares interlaced field detail.")
        }
        for key in [kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocationBottomFieldKey] {
            if let raw = CVBufferCopyAttachment(buffer, key, nil) {
                guard let value = raw as? String, value == kCVImageBufferChromaLocation_Left as String else {
                    throw failure("The decoded MPEG-4 chroma location contradicts the VOL.")
                }
            }
        }
        if let raw = CVBufferCopyAttachment(buffer, kCVImageBufferChromaSubsamplingKey, nil) {
            guard let value = raw as? String, value == kCVImageBufferChromaSubsampling_420 as String else {
                throw failure("The decoded MPEG-4 chroma subsampling contradicts the VOL.")
            }
        }
        // Progressive CoreVideo surfaces use the top-field location. Preserve
        // every existing correct attachment and its mode, including bottom.
        if CVBufferCopyAttachment(buffer, kCVImageBufferChromaLocationTopFieldKey, nil) == nil {
            CVBufferSetAttachment(buffer, kCVImageBufferChromaLocationTopFieldKey,
                                  kCVImageBufferChromaLocation_Left, .shouldPropagate)
        }
    }

    static func declaration(from descriptions: [CMFormatDescription]) throws -> Self? {
        guard descriptions.count == 1, let description = descriptions.first else {
            guard !descriptions.contains(where: {
                CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_MPEG4Video
            }) else { throw failure("MPEG-4 changes sampling configurations within its track.") }
            return nil
        }
        return try declaration(from: description)
    }

    static func declaration(from description: CMFormatDescription) throws -> Self? {
        guard CMFormatDescriptionGetMediaType(description) == kCMMediaType_Video,
              CMFormatDescriptionGetMediaSubType(description) == kCMVideoCodecType_MPEG4Video else { return nil }
        let extensions = (CMFormatDescriptionGetExtensions(description) as NSDictionary?) ?? [:]
        guard let atoms = extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] as? NSDictionary,
              let esds = atoms["esds"] as? Data,
              let configuration = decoderConfiguration(esds),
              let proof = parse(configuration) else {
            throw failure("The MPEG-4 progressive sampling configuration is incomplete or unsupported.")
        }
        try proof.validate(description: description)
        return proof
    }

    func validate(description: CMFormatDescription) throws {
        let size = CMVideoFormatDescriptionGetDimensions(description)
        let extensions = (CMFormatDescriptionGetExtensions(description) as NSDictionary?) ?? [:]
        guard CMFormatDescriptionGetMediaType(description) == kCMMediaType_Video,
              CMFormatDescriptionGetMediaSubType(description) == kCMVideoCodecType_MPEG4Video,
              size.width == width, size.height == height else {
            throw Self.failure("MPEG-4 VOL and container rasters disagree.")
        }
        for (key, expected) in [
            (kCMFormatDescriptionExtension_BitsPerComponent, 8),
            (kCMFormatDescriptionExtension_FullRangeVideo, fullRange ? 1 : 0),
            (kCMFormatDescriptionExtension_FieldCount, 1)
        ] {
            if let raw = extensions[key as String] {
                guard let number = raw as? NSNumber, number.doubleValue == Double(expected) else {
                    throw Self.failure("MPEG-4 VOL and container sampling declarations disagree.")
                }
            }
        }
        guard extensions[kCMFormatDescriptionExtension_FieldDetail as String] == nil else {
            throw Self.failure("Progressive MPEG-4 carries an interlaced field-detail declaration.")
        }
        for key in [kCMFormatDescriptionExtension_ChromaLocationTopField,
                    kCMFormatDescriptionExtension_ChromaLocationBottomField] {
            if let raw = extensions[key as String] {
                guard let value = raw as? String, value == kCMFormatDescriptionChromaLocation_Left as String else {
                    throw Self.failure("MPEG-4 VOL and container chroma locations disagree.")
                }
            }
        }
        if let raw = extensions[kCVImageBufferChromaSubsamplingKey as String] {
            guard let value = raw as? String,
                  value == kCVImageBufferChromaSubsampling_420 as String else {
                throw Self.failure("MPEG-4 VOL and container chroma subsampling disagree.")
            }
        }
    }

    // ISO/IEC 14496-1 ES_Descriptor -> DecoderConfigDescriptor ->
    // DecoderSpecificInfo. Authenticate declared descriptor boundaries before
    // interpreting any start code; payload bytes in unrelated descriptors are
    // not video configuration.
    static func decoderConfiguration(_ data: Data) -> Data? {
        guard (4...1_048_576).contains(data.count) else { return nil }
        let b = [UInt8](data)
        guard b.prefix(4).allSatisfy({ $0 == 0 }) else { return nil }
        var configurations: [Data] = []
        func walk(_ begin: Int, _ end: Int, _ parent: UInt8) -> Bool {
            var cursor = begin
            var tags: Set<UInt8> = []
            while cursor < end {
                let tag = b[cursor]; cursor += 1
                guard tags.insert(tag).inserted else { return false }
                var count = 0
                var terminated = false
                for _ in 0..<4 {
                    guard cursor < end else { return false }
                    let value = b[cursor]; cursor += 1
                    count = (count << 7) | Int(value & 0x7f)
                    if value & 0x80 == 0 { terminated = true; break }
                }
                guard terminated, count <= end - cursor else { return false }
                let finish = cursor + count
                switch (parent, tag) {
                case (0, 3):
                    guard count >= 3, b[cursor + 2] == 0,
                          walk(cursor + 3, finish, tag) else { return false }
                case (3, 4):
                    guard count >= 13, b[cursor] == 0x20, b[cursor + 1] == 0x11,
                          walk(cursor + 13, finish, tag) else { return false }
                case (4, 5):
                    guard count > 0 else { return false }
                    configurations.append(Data(b[cursor..<finish]))
                case (3, 6):
                    guard count == 1, b[cursor] == 2 else { return false }
                default: return false
                }
                cursor = finish
            }
            switch parent {
            case 0: return tags == [3]
            case 3: return tags == [4, 6]
            case 4: return tags == [5]
            default: return false
            }
        }
        guard walk(4, b.count, 0), configurations.count == 1 else { return nil }
        return configurations[0]
    }

    static func parse(_ data: Data) -> Self? {
        guard (4...1_048_576).contains(data.count) else { return nil }
        let b = [UInt8](data)
        var starts: [Int] = []
        for index in 0..<(b.count - 3) where b[index] == 0 && b[index + 1] == 0 && b[index + 2] == 1 {
            guard starts.count < 1_024 else { return nil }
            starts.append(index)
        }
        guard starts.first == 0 else { return nil }
        var range = false
        var visualSeen = false
        var layer: Self?
        for (ordinal, start) in starts.enumerated() {
            let end = ordinal + 1 < starts.count ? starts[ordinal + 1] : b.count
            guard end >= start + 4 else { return nil }
            let code = b[start + 3]
            var bits = Bits(Array(b[(start + 4)..<end]))
            switch code {
            case 0xb0:
                guard ordinal == 0, end - start == 5 else { return nil }
            case 0xb5:
                guard !visualSeen, layer == nil, let identifier = bits.read(1) else { return nil }
                visualSeen = true
                if identifier == 1 {
                    guard let version = bits.read(4), version > 0, bits.read(3) != nil else { return nil }
                }
                guard bits.read(4) == 1, let signal = bits.read(1) else { return nil }
                if signal == 1 {
                    guard bits.read(3) != nil, let value = bits.read(1), let color = bits.read(1) else { return nil }
                    range = value == 1
                    if color == 1, bits.read(24) == nil { return nil }
                }
                guard bits.finish() else { return nil }
            case 0x00...0x1f:
                guard layer == nil, end == start + 4 else { return nil }
            case 0x20...0x2f:
                guard layer == nil, let dimensions = dimensions(&bits) else { return nil }
                layer = Self(width: Int32(dimensions.0), height: Int32(dimensions.1), fullRange: range,
                             sourceConfiguration: data)
            case 0xb2: break // User data has no sampling syntax.
            default: return nil
            }
        }
        return layer
    }

    private static func dimensions(_ bits: inout Bits) -> (Int, Int)? {
        guard bits.read(1) != nil, let object = bits.read(8), [1, 17].contains(object),
              let identifier = bits.read(1) else { return nil }
        var version = 1
        if identifier == 1 {
            guard let value = bits.read(4), value > 0, bits.read(3) != nil else { return nil }
            version = value
        }
        guard let aspect = bits.read(4), (1...5).contains(aspect) || aspect == 15 else { return nil }
        if aspect == 15 {
            guard let x = bits.read(8), x > 0, let y = bits.read(8), y > 0 else { return nil }
        }
        guard let control = bits.read(1) else { return nil }
        if control == 1 {
            guard bits.read(2) == 1, bits.read(1) != nil, let vbv = bits.read(1) else { return nil }
            if vbv == 1 {
                for width in [15, 15, 15, 14, 15] {
                    guard bits.read(width) != nil, bits.read(1) == 1 else { return nil }
                }
            }
        }
        guard bits.read(2) == 0, bits.read(1) == 1, let clock = bits.read(16), clock > 0,
              bits.read(1) == 1, let fixed = bits.read(1) else { return nil }
        if fixed == 1 {
            let count = max(1, Int.bitWidth - (clock - 1).leadingZeroBitCount)
            guard let step = bits.read(count), step > 0, step < clock else { return nil }
        }
        guard bits.read(1) == 1, let width = bits.read(13), width > 0,
              bits.read(1) == 1, let height = bits.read(13), height > 0,
              bits.read(1) == 1, bits.read(1) == 0, // progressive
              bits.read(1) == 1, // OBMC disabled
              bits.read(version == 1 ? 1 : 2) == 0, // no sprite
              let nonEightBit = bits.read(1) else { return nil }
        if nonEightBit == 1 {
            guard bits.read(4) == 5, bits.read(4) == 8 else { return nil }
        }
        guard let quantized = bits.read(1) else { return nil }
        if quantized == 1 {
            for _ in 0..<2 {
                guard let custom = bits.read(1) else { return nil }
                if custom == 1 {
                    for index in 0..<64 {
                        guard let value = bits.read(8), index > 0 || value > 0 else { return nil }
                        if value == 0 { break }
                    }
                }
            }
        }
        if version != 1, bits.read(1) == nil { return nil } // quarter_sample
        guard bits.read(1) == 1, // complexity estimation disabled
              bits.read(1) != nil, let partitioned = bits.read(1) else { return nil }
        if partitioned == 1, bits.read(1) == nil { return nil }
        if version != 1 {
            guard bits.read(1) == 0, bits.read(1) == 0 else { return nil } // no newpred/reduced resolution
        }
        guard bits.read(1) == 0, bits.finish() else { return nil } // no scalability
        return (width, height)
    }

    private struct Bits {
        let bytes: [UInt8]
        var offset = 0
        init(_ bytes: [UInt8]) { self.bytes = bytes }
        mutating func read(_ count: Int) -> Int? {
            guard (0...24).contains(count), offset + count <= bytes.count * 8 else { return nil }
            var value = 0
            for _ in 0..<count {
                value = value * 2 + Int((bytes[offset / 8] >> (7 - offset % 8)) & 1)
                offset += 1
            }
            return value
        }
        mutating func finish() -> Bool {
            let remaining = bytes.count * 8 - offset
            guard (1...8).contains(remaining), read(1) == 0 else { return false }
            for _ in 1..<remaining where read(1) != 1 { return false }
            return true
        }
    }

    private static func failure(_ reason: String) -> AVCanonicalMediaStateAdapterV4Error {
        .avFoundationLoadFailed(path: "video.mpeg4_sampling", reason: reason)
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
    var jfifDeclaration: JFIFVideoSamplingV4? = nil
    var nativeWorkingJFIFDeclaration: JFIFVideoSamplingV4? = nil

    static func resolve(
        asset: AVAsset, track: AVAssetTrack,
        descriptions: [CMFormatDescription]
    ) throws -> Self? {
        // Sampling consumers must share the same unique MPEG-4 configuration.
        _ = try MPEG4ProgressiveSamplingV4.declaration(from: descriptions)
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
        var jfifDeclaration: JFIFVideoSamplingV4?
        let extensions = CMFormatDescriptionGetExtensions(description) as NSDictionary? ?? [:]
        let isDeclaredProgressive = (extensions[kCMFormatDescriptionExtension_FieldCount as String] as? NSNumber)?.doubleValue == 1
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
                if current.subsampling == .yuv420, isDeclaredProgressive {
                    let proof = try JFIFVideoSamplingV4.progressiveDeclaration(from: description)
                    try proof?.validatePacket(bytes.subdata(in: offset..<(offset + size)))
                    jfifDeclaration = proof
                }
                facts = current
                offset += size
            }
            guard offset == length else { return nil }
        }
        guard reader.status == .completed else { throw reader.error ?? failure("Cannot finish reading JPEG headers.") }
        facts?.jfifDeclaration = jfifDeclaration
        // The source JFIF declaration also applies to OpenDML. Its native
        // dmb1/default-table decoder path has a separate unqualified behavior;
        // only the ordinary JPEG decoder is an authenticated identity delivery.
        if codec == kCMVideoCodecType_JPEG {
            facts?.nativeWorkingJFIFDeclaration = jfifDeclaration
        }
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
