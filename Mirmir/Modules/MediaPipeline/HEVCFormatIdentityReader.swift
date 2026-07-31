import CoreMedia
import Foundation

enum HEVCChromaSampling: Int, Sendable, Equatable {
    case monochrome = 0
    case yuv420 = 1
    case yuv422 = 2
    case yuv444 = 3
}

struct HEVCEncodedFormatIdentity: Sendable, Equatable {
    let chromaSampling: HEVCChromaSampling
    let lumaBitDepth: Int
    let chromaBitDepth: Int
}

enum HEVCFormatIdentityReaderError: Error, Sendable, Equatable,
    CustomStringConvertible {
    case notHEVC(FourCharCode)
    case parameterSetReadFailed(OSStatus)
    case missingSequenceParameterSet
    case invalidNALUnit(String)
    case truncatedSequenceParameterSet
    case invalidSequenceParameterSet(String)

    var description: String {
        switch self {
        case .notHEVC(let subtype):
            return "format subtype \(subtype) is not HEVC"
        case .parameterSetReadFailed(let status):
            return "HEVC parameter-set read failed with status \(status)"
        case .missingSequenceParameterSet:
            return "HEVC format description has no sequence parameter set"
        case .invalidNALUnit(let reason):
            return "invalid HEVC NAL unit: \(reason)"
        case .truncatedSequenceParameterSet:
            return "HEVC sequence parameter set is truncated"
        case .invalidSequenceParameterSet(let reason):
            return "invalid HEVC sequence parameter set: \(reason)"
        }
    }
}

enum HEVCFormatIdentityReader {
    static func read(
        formatDescription: CMFormatDescription
    ) throws -> HEVCEncodedFormatIdentity {
        let subtype = CMFormatDescriptionGetMediaSubType(formatDescription)
        guard subtype == kCMVideoCodecType_HEVC
                || subtype == kCMVideoCodecType_HEVCWithAlpha else {
            throw HEVCFormatIdentityReaderError.notHEVC(subtype)
        }

        var parameterSetCount = 0
        var nalUnitHeaderLength: Int32 = 0
        var firstParameterSet: UnsafePointer<UInt8>?
        var firstParameterSetSize = 0
        let countStatus =
            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                formatDescription,
                parameterSetIndex: 0,
                parameterSetPointerOut: &firstParameterSet,
                parameterSetSizeOut: &firstParameterSetSize,
                parameterSetCountOut: &parameterSetCount,
                nalUnitHeaderLengthOut: &nalUnitHeaderLength
            )
        guard countStatus == noErr else {
            throw HEVCFormatIdentityReaderError.parameterSetReadFailed(
                countStatus
            )
        }
        guard parameterSetCount > 0 else {
            throw HEVCFormatIdentityReaderError.missingSequenceParameterSet
        }

        for index in 0..<parameterSetCount {
            var bytes: UnsafePointer<UInt8>?
            var byteCount = 0
            let status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                formatDescription,
                parameterSetIndex: index,
                parameterSetPointerOut: &bytes,
                parameterSetSizeOut: &byteCount,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil
            )
            guard status == noErr else {
                throw HEVCFormatIdentityReaderError.parameterSetReadFailed(
                    status
                )
            }
            guard let bytes, byteCount >= 2 else {
                continue
            }
            let nalUnit = Data(bytes: bytes, count: byteCount)
            if nalUnitType(nalUnit) == 33 {
                return try read(sequenceParameterSetNALUnit: nalUnit)
            }
        }
        throw HEVCFormatIdentityReaderError.missingSequenceParameterSet
    }

    static func read(
        sequenceParameterSetNALUnit nalUnit: Data
    ) throws -> HEVCEncodedFormatIdentity {
        guard nalUnit.count >= 3 else {
            throw HEVCFormatIdentityReaderError.invalidNALUnit(
                "an SPS requires a two-byte NAL header and RBSP payload"
            )
        }
        guard nalUnit.first.map({ ($0 & 0x80) == 0 }) == true else {
            throw HEVCFormatIdentityReaderError.invalidNALUnit(
                "forbidden_zero_bit is set"
            )
        }
        guard nalUnitType(nalUnit) == 33 else {
            throw HEVCFormatIdentityReaderError.invalidNALUnit(
                "NAL unit type is not SPS_NUT"
            )
        }
        guard (nalUnit[1] & 0x07) != 0 else {
            throw HEVCFormatIdentityReaderError.invalidNALUnit(
                "nuh_temporal_id_plus1 is zero"
            )
        }

        let rbsp = try removeEmulationPreventionBytes(
            Data(nalUnit.dropFirst(2))
        )
        var reader = HEVCBitReader(bytes: rbsp)
        do {
            _ = try reader.readBits(4)
            let maxSubLayersMinus1 = Int(try reader.readBits(3))
            guard maxSubLayersMinus1 <= 6 else {
                throw HEVCFormatIdentityReaderError
                    .invalidSequenceParameterSet(
                        "sps_max_sub_layers_minus1 exceeds 6"
                    )
            }
            _ = try reader.readBits(1)
            try skipProfileTierLevel(
                reader: &reader,
                maxSubLayersMinus1: maxSubLayersMinus1
            )
            _ = try reader.readUnsignedExpGolomb()
            let chromaFormatIDC = try reader.readUnsignedExpGolomb()
            guard let chromaSampling = HEVCChromaSampling(
                rawValue: Int(chromaFormatIDC)
            ) else {
                throw HEVCFormatIdentityReaderError
                    .invalidSequenceParameterSet(
                        "chroma_format_idc \(chromaFormatIDC) is outside 0...3"
                    )
            }
            if chromaSampling == .yuv444 {
                _ = try reader.readBits(1)
            }
            _ = try reader.readUnsignedExpGolomb()
            _ = try reader.readUnsignedExpGolomb()
            let conformanceWindowFlag = try reader.readBits(1)
            if conformanceWindowFlag == 1 {
                for _ in 0..<4 {
                    _ = try reader.readUnsignedExpGolomb()
                }
            }
            let lumaBitDepthMinus8 = try reader.readUnsignedExpGolomb()
            let chromaBitDepthMinus8 = try reader.readUnsignedExpGolomb()
            guard lumaBitDepthMinus8 <= 8,
                  chromaBitDepthMinus8 <= 8 else {
                throw HEVCFormatIdentityReaderError
                    .invalidSequenceParameterSet(
                        "bit depth exceeds the HEVC 8...16-bit range"
                    )
            }
            return HEVCEncodedFormatIdentity(
                chromaSampling: chromaSampling,
                lumaBitDepth: 8 + Int(lumaBitDepthMinus8),
                chromaBitDepth: 8 + Int(chromaBitDepthMinus8)
            )
        } catch HEVCBitReaderError.truncated {
            throw HEVCFormatIdentityReaderError
                .truncatedSequenceParameterSet
        } catch HEVCBitReaderError.expGolombOverflow {
            throw HEVCFormatIdentityReaderError
                .invalidSequenceParameterSet(
                    "unsigned Exp-Golomb value exceeds UInt64"
                )
        }
    }

    private static func nalUnitType(_ nalUnit: Data) -> UInt8? {
        nalUnit.first.map { ($0 >> 1) & 0x3f }
    }

    private static func removeEmulationPreventionBytes(
        _ encoded: Data
    ) throws -> Data {
        var decoded = Data()
        decoded.reserveCapacity(encoded.count)
        var zeroCount = 0
        var index = encoded.startIndex
        while index < encoded.endIndex {
            let byte = encoded[index]
            if zeroCount >= 2, byte == 0x03 {
                let nextIndex = encoded.index(after: index)
                guard nextIndex < encoded.endIndex,
                      encoded[nextIndex] <= 0x03 else {
                    throw HEVCFormatIdentityReaderError.invalidNALUnit(
                        "malformed emulation-prevention byte"
                    )
                }
                zeroCount = 0
                index = nextIndex
                continue
            }
            decoded.append(byte)
            zeroCount = byte == 0 ? zeroCount + 1 : 0
            index = encoded.index(after: index)
        }
        return decoded
    }

    private static func skipProfileTierLevel(
        reader: inout HEVCBitReader,
        maxSubLayersMinus1: Int
    ) throws {
        try reader.skipBits(2 + 1 + 5)
        try reader.skipBits(32)
        try reader.skipBits(48)
        try reader.skipBits(8)

        var subLayerProfilePresent = Array(
            repeating: false,
            count: maxSubLayersMinus1
        )
        var subLayerLevelPresent = Array(
            repeating: false,
            count: maxSubLayersMinus1
        )
        for index in 0..<maxSubLayersMinus1 {
            subLayerProfilePresent[index] = try reader.readBits(1) == 1
            subLayerLevelPresent[index] = try reader.readBits(1) == 1
        }
        if maxSubLayersMinus1 > 0 {
            for _ in maxSubLayersMinus1..<8 {
                try reader.skipBits(2)
            }
        }
        for index in 0..<maxSubLayersMinus1 {
            if subLayerProfilePresent[index] {
                try reader.skipBits(2 + 1 + 5)
                try reader.skipBits(32)
                try reader.skipBits(48)
            }
            if subLayerLevelPresent[index] {
                try reader.skipBits(8)
            }
        }
    }
}

private enum HEVCBitReaderError: Error {
    case truncated
    case expGolombOverflow
}

private struct HEVCBitReader {
    let bytes: Data
    private(set) var bitOffset = 0

    mutating func readBits(_ count: Int) throws -> UInt64 {
        precondition((0...64).contains(count))
        guard bitOffset + count <= bytes.count * 8 else {
            throw HEVCBitReaderError.truncated
        }
        var value: UInt64 = 0
        for _ in 0..<count {
            let byteIndex = bitOffset / 8
            let bitIndex = 7 - (bitOffset % 8)
            let bit = (bytes[byteIndex] >> bitIndex) & 1
            value = (value << 1) | UInt64(bit)
            bitOffset += 1
        }
        return value
    }

    mutating func skipBits(_ count: Int) throws {
        guard count >= 0, bitOffset + count <= bytes.count * 8 else {
            throw HEVCBitReaderError.truncated
        }
        bitOffset += count
    }

    mutating func readUnsignedExpGolomb() throws -> UInt64 {
        var leadingZeroBits = 0
        while try readBits(1) == 0 {
            leadingZeroBits += 1
            guard leadingZeroBits < 64 else {
                throw HEVCBitReaderError.expGolombOverflow
            }
        }
        guard leadingZeroBits > 0 else {
            return 0
        }
        let suffix = try readBits(leadingZeroBits)
        return (UInt64(1) << UInt64(leadingZeroBits)) - 1 + suffix
    }
}
