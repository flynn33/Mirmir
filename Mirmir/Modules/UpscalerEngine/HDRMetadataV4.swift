import Foundation

enum HDRMetadataV4Error: Error, Equatable, Sendable {
    case hdrRequiresP010(PixelStorageV4)
    case invalidPayloadLength(kind: String, expected: Int, actual: Int)
    case invalidChromaticity(label: String, x: UInt16, y: UInt16)
    case invalidMasteringLuminance(minimum: UInt32, maximum: UInt32)
    case invalidContentLightLevel(maximumCLL: UInt16, maximumFALL: UInt16)
    case invalidHDR10PlusCountryCode(UInt8?)
    case invalidPostDecodeProcessingPropertyList
    case unsupportedColorTag(key: String, value: String?)
    case incompleteHDRColorTags
    case staticMetadataWithoutHDRTransfer
    case contradictoryMetadata(String)
    case dynamicMetadataRequiresRegeneration
    case unsupportedSampleCount(Int)
}

enum HDRTransferFunctionV4: String, Hashable, Sendable {
    case pq
    case hlg
}

enum HDRColorPrimariesV4: String, Hashable, Sendable {
    case bt2020
}

enum HDRYCbCrMatrixV4: String, Hashable, Sendable {
    case bt2020NonConstantLuminance = "bt_2020_ncl"
}

struct HDRSignalV4: Equatable, Hashable, Sendable {
    let storage: PixelStorageV4
    let transferFunction: HDRTransferFunctionV4
    let colorPrimaries: HDRColorPrimariesV4
    let yCbCrMatrix: HDRYCbCrMatrixV4
    let signalBitDepth: Int

    init(
        storage: PixelStorageV4,
        transferFunction: HDRTransferFunctionV4
    ) throws {
        guard storage == .p010VideoRange10Bit
                || storage == .p010FullRange10Bit else {
            throw HDRMetadataV4Error.hdrRequiresP010(storage)
        }
        self.storage = storage
        self.transferFunction = transferFunction
        self.colorPrimaries = .bt2020
        self.yCbCrMatrix = .bt2020NonConstantLuminance
        self.signalBitDepth = 10
    }

    /// This contract preserves encoded PQ or HLG values. It does not authorize
    /// tone mapping or a transfer-function conversion.
    var permitsToneMapping: Bool { false }
}

struct HDRChromaticityV4: Equatable, Hashable, Sendable {
    let x: UInt16
    let y: UInt16

    init(x: UInt16, y: UInt16, label: String) throws {
        let maximum = UInt32(50_000)
        guard UInt32(x) <= maximum,
              UInt32(y) <= maximum,
              UInt32(x) + UInt32(y) <= maximum else {
            throw HDRMetadataV4Error.invalidChromaticity(
                label: label,
                x: x,
                y: y
            )
        }
        self.x = x
        self.y = y
    }
}

/// HEVC mastering-display-colour-volume SEI payload. The three primary entries
/// retain their source order; no floating-point chromaticity conversion occurs.
struct MasteringDisplayColorVolumeV4: Equatable, Hashable, Sendable {
    let displayPrimaries: [HDRChromaticityV4]
    let whitePoint: HDRChromaticityV4
    let maximumDisplayMasteringLuminance: UInt32
    let minimumDisplayMasteringLuminance: UInt32

    init(
        displayPrimaries: [HDRChromaticityV4],
        whitePoint: HDRChromaticityV4,
        maximumDisplayMasteringLuminance: UInt32,
        minimumDisplayMasteringLuminance: UInt32
    ) throws {
        guard displayPrimaries.count == 3 else {
            throw HDRMetadataV4Error.invalidPayloadLength(
                kind: "mastering_display_primaries",
                expected: 3,
                actual: displayPrimaries.count
            )
        }
        guard maximumDisplayMasteringLuminance > 0,
              minimumDisplayMasteringLuminance
                <= maximumDisplayMasteringLuminance else {
            throw HDRMetadataV4Error.invalidMasteringLuminance(
                minimum: minimumDisplayMasteringLuminance,
                maximum: maximumDisplayMasteringLuminance
            )
        }
        self.displayPrimaries = displayPrimaries
        self.whitePoint = whitePoint
        self.maximumDisplayMasteringLuminance =
            maximumDisplayMasteringLuminance
        self.minimumDisplayMasteringLuminance =
            minimumDisplayMasteringLuminance
    }

    init(payload: Data) throws {
        guard payload.count == 24 else {
            throw HDRMetadataV4Error.invalidPayloadLength(
                kind: "mastering_display_color_volume",
                expected: 24,
                actual: payload.count
            )
        }
        let bytes = [UInt8](payload)
        var primaries: [HDRChromaticityV4] = []
        primaries.reserveCapacity(3)
        for index in 0..<3 {
            primaries.append(
                try HDRChromaticityV4(
                    x: Self.readBigEndianUInt16(bytes, at: index * 4),
                    y: Self.readBigEndianUInt16(bytes, at: index * 4 + 2),
                    label: "display_primary_\(index)"
                )
            )
        }
        try self.init(
            displayPrimaries: primaries,
            whitePoint: HDRChromaticityV4(
                x: Self.readBigEndianUInt16(bytes, at: 12),
                y: Self.readBigEndianUInt16(bytes, at: 14),
                label: "white_point"
            ),
            maximumDisplayMasteringLuminance: Self.readBigEndianUInt32(
                bytes,
                at: 16
            ),
            minimumDisplayMasteringLuminance: Self.readBigEndianUInt32(
                bytes,
                at: 20
            )
        )
    }

    var payload: Data {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(24)
        for primary in displayPrimaries {
            Self.appendBigEndian(primary.x, to: &bytes)
            Self.appendBigEndian(primary.y, to: &bytes)
        }
        Self.appendBigEndian(whitePoint.x, to: &bytes)
        Self.appendBigEndian(whitePoint.y, to: &bytes)
        Self.appendBigEndian(maximumDisplayMasteringLuminance, to: &bytes)
        Self.appendBigEndian(minimumDisplayMasteringLuminance, to: &bytes)
        return Data(bytes)
    }

    private static func readBigEndianUInt16(
        _ bytes: [UInt8],
        at offset: Int
    ) -> UInt16 {
        (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }

    private static func readBigEndianUInt32(
        _ bytes: [UInt8],
        at offset: Int
    ) -> UInt32 {
        (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
    }

    private static func appendBigEndian(
        _ value: UInt16,
        to bytes: inout [UInt8]
    ) {
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        bytes.append(UInt8(truncatingIfNeeded: value))
    }

    private static func appendBigEndian(
        _ value: UInt32,
        to bytes: inout [UInt8]
    ) {
        bytes.append(UInt8(truncatingIfNeeded: value >> 24))
        bytes.append(UInt8(truncatingIfNeeded: value >> 16))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        bytes.append(UInt8(truncatingIfNeeded: value))
    }
}

struct ContentLightLevelInfoV4: Equatable, Hashable, Sendable {
    let maximumContentLightLevel: UInt16
    let maximumFrameAverageLightLevel: UInt16

    init(
        maximumContentLightLevel: UInt16,
        maximumFrameAverageLightLevel: UInt16
    ) throws {
        guard maximumFrameAverageLightLevel <= maximumContentLightLevel else {
            throw HDRMetadataV4Error.invalidContentLightLevel(
                maximumCLL: maximumContentLightLevel,
                maximumFALL: maximumFrameAverageLightLevel
            )
        }
        self.maximumContentLightLevel = maximumContentLightLevel
        self.maximumFrameAverageLightLevel = maximumFrameAverageLightLevel
    }

    init(payload: Data) throws {
        guard payload.count == 4 else {
            throw HDRMetadataV4Error.invalidPayloadLength(
                kind: "content_light_level_info",
                expected: 4,
                actual: payload.count
            )
        }
        let bytes = [UInt8](payload)
        try self.init(
            maximumContentLightLevel:
                (UInt16(bytes[0]) << 8) | UInt16(bytes[1]),
            maximumFrameAverageLightLevel:
                (UInt16(bytes[2]) << 8) | UInt16(bytes[3])
        )
    }

    var payload: Data {
        Data([
            UInt8(truncatingIfNeeded: maximumContentLightLevel >> 8),
            UInt8(truncatingIfNeeded: maximumContentLightLevel),
            UInt8(truncatingIfNeeded: maximumFrameAverageLightLevel >> 8),
            UInt8(truncatingIfNeeded: maximumFrameAverageLightLevel)
        ])
    }
}

struct AmbientViewingEnvironmentV4: Equatable, Hashable, Sendable {
    let ambientIlluminance: UInt32
    let ambientLight: HDRChromaticityV4

    init(
        ambientIlluminance: UInt32,
        ambientLight: HDRChromaticityV4
    ) {
        self.ambientIlluminance = ambientIlluminance
        self.ambientLight = ambientLight
    }

    init(payload: Data) throws {
        guard payload.count == 8 else {
            throw HDRMetadataV4Error.invalidPayloadLength(
                kind: "ambient_viewing_environment",
                expected: 8,
                actual: payload.count
            )
        }
        let bytes = [UInt8](payload)
        self.ambientIlluminance =
            (UInt32(bytes[0]) << 24)
            | (UInt32(bytes[1]) << 16)
            | (UInt32(bytes[2]) << 8)
            | UInt32(bytes[3])
        self.ambientLight = try HDRChromaticityV4(
            x: (UInt16(bytes[4]) << 8) | UInt16(bytes[5]),
            y: (UInt16(bytes[6]) << 8) | UInt16(bytes[7]),
            label: "ambient_light"
        )
    }

    var payload: Data {
        Data([
            UInt8(truncatingIfNeeded: ambientIlluminance >> 24),
            UInt8(truncatingIfNeeded: ambientIlluminance >> 16),
            UInt8(truncatingIfNeeded: ambientIlluminance >> 8),
            UInt8(truncatingIfNeeded: ambientIlluminance),
            UInt8(truncatingIfNeeded: ambientLight.x >> 8),
            UInt8(truncatingIfNeeded: ambientLight.x),
            UInt8(truncatingIfNeeded: ambientLight.y >> 8),
            UInt8(truncatingIfNeeded: ambientLight.y)
        ])
    }
}

struct HDRStaticMetadataV4: Equatable, Hashable, Sendable {
    let masteringDisplayColorVolume: MasteringDisplayColorVolumeV4?
    let contentLightLevelInfo: ContentLightLevelInfoV4?
    let ambientViewingEnvironment: AmbientViewingEnvironmentV4?

    init(
        masteringDisplayColorVolume: MasteringDisplayColorVolumeV4? = nil,
        contentLightLevelInfo: ContentLightLevelInfoV4? = nil,
        ambientViewingEnvironment: AmbientViewingEnvironmentV4? = nil
    ) {
        self.masteringDisplayColorVolume = masteringDisplayColorVolume
        self.contentLightLevelInfo = contentLightLevelInfo
        self.ambientViewingEnvironment = ambientViewingEnvironment
    }

    var isEmpty: Bool {
        masteringDisplayColorVolume == nil
            && contentLightLevelInfo == nil
            && ambientViewingEnvironment == nil
    }
}

struct HDRFormatMetadataV4: Equatable, Hashable, Sendable {
    let signal: HDRSignalV4
    let staticMetadata: HDRStaticMetadataV4
}

struct HDR10PlusMetadataV4: Equatable, Hashable, Sendable {
    let ituTT35Payload: Data

    init(ituTT35Payload: Data) throws {
        guard ituTT35Payload.first == 0xB5 else {
            throw HDRMetadataV4Error.invalidHDR10PlusCountryCode(
                ituTT35Payload.first
            )
        }
        self.ituTT35Payload = ituTT35Payload
    }
}

/// Canonical binary-property-list representation of the CoreMedia dictionary.
/// It is Sendable and never carries Foundation reference objects across tasks.
struct PostDecodeProcessingMetadataV4: Equatable, Hashable, Sendable {
    let binaryPropertyList: Data

    init(propertyList: Any) throws {
        guard propertyList is NSDictionary,
              PropertyListSerialization.propertyList(
                propertyList,
                isValidFor: .binary
              ) else {
            throw HDRMetadataV4Error.invalidPostDecodeProcessingPropertyList
        }
        do {
            self.binaryPropertyList = try PropertyListSerialization.data(
                fromPropertyList: propertyList,
                format: .binary,
                options: 0
            )
        } catch {
            throw HDRMetadataV4Error.invalidPostDecodeProcessingPropertyList
        }
    }

    init(binaryPropertyList: Data) throws {
        do {
            var format = PropertyListSerialization.PropertyListFormat.binary
            let value = try PropertyListSerialization.propertyList(
                from: binaryPropertyList,
                options: [],
                format: &format
            )
            guard value is NSDictionary else {
                throw HDRMetadataV4Error
                    .invalidPostDecodeProcessingPropertyList
            }
            self.binaryPropertyList = try PropertyListSerialization.data(
                fromPropertyList: value,
                format: .binary,
                options: 0
            )
        } catch let error as HDRMetadataV4Error {
            throw error
        } catch {
            throw HDRMetadataV4Error.invalidPostDecodeProcessingPropertyList
        }
    }

    func propertyListDictionary() throws -> NSDictionary {
        do {
            let value = try PropertyListSerialization.propertyList(
                from: binaryPropertyList,
                options: [],
                format: nil
            )
            guard let dictionary = value as? NSDictionary else {
                throw HDRMetadataV4Error
                    .invalidPostDecodeProcessingPropertyList
            }
            return dictionary
        } catch let error as HDRMetadataV4Error {
            throw error
        } catch {
            throw HDRMetadataV4Error.invalidPostDecodeProcessingPropertyList
        }
    }
}

struct HDRDynamicMetadataV4: Equatable, Hashable, Sendable {
    let hdr10Plus: HDR10PlusMetadataV4?
    let postDecodeProcessing: PostDecodeProcessingMetadataV4?

    init(
        hdr10Plus: HDR10PlusMetadataV4? = nil,
        postDecodeProcessing: PostDecodeProcessingMetadataV4? = nil
    ) {
        self.hdr10Plus = hdr10Plus
        self.postDecodeProcessing = postDecodeProcessing
    }

    var isEmpty: Bool {
        hdr10Plus == nil && postDecodeProcessing == nil
    }
}

enum HDRDynamicEncodingPolicyV4: String, Hashable, Sendable {
    case absent
    case preserveSourceWhenPixelsAreUnmodified
}
