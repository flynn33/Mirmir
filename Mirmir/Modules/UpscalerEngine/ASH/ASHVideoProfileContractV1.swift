import CryptoKit
import Foundation

enum ASHVideoProfileColorFieldV1: String, Equatable, Sendable {
    case colorPrimaries = "color_primaries"
    case transferFunction = "transfer_function"
    case yCbCrMatrix = "ycbcr_matrix"
}

enum ASHVideoProfilePixelFormatV1: String, CaseIterable, Equatable, Sendable {
    case fullRange420 = "420f"
    case videoRange420 = "420v"

    var range: ASHVideoCodeRange8Bit {
        switch self {
        case .fullRange420: .full
        case .videoRange420: .video
        }
    }
}

enum ASHVideoProfileContractV1Error: Error, Equatable, Sendable {
    case hashMismatch
    case nonCanonicalEncoding
    case fieldSetMismatch
    case invalidContract
    case unsupportedPixelFormat(String)
    case missingPixelFormat
    case unsupportedRange(String)
    case missingRange
    case invalidPixelFormatRangePair(pixelFormat: String, range: String)
    case missingColorMetadata(ASHVideoProfileColorFieldV1)
    case nonRec709ColorMetadata(field: ASHVideoProfileColorFieldV1, observed: String)
    case missingScanMetadata
    case interlacedInput
    case unsupportedScanType(String)
    case missingBitDepth
    case unsupportedBitDepth(Int)
    case missingSubsampling
    case unsupportedSubsampling(String)
    case missingChromaSiting
    case unsupportedChromaSiting(String)

    var machineCode: String {
        switch self {
        case .hashMismatch: "profile_contract_hash_mismatch"
        case .nonCanonicalEncoding: "profile_contract_noncanonical_encoding"
        case .fieldSetMismatch: "profile_contract_field_set_mismatch"
        case .invalidContract: "profile_contract_invalid"
        case .unsupportedPixelFormat: "unsupported_pixel_format"
        case .missingPixelFormat: "missing_pixel_format"
        case .unsupportedRange: "unsupported_range"
        case .missingRange: "missing_range"
        case .invalidPixelFormatRangePair: "invalid_pixel_format_range_pair"
        case .missingColorMetadata(let field): "missing_\(field.rawValue)"
        case .nonRec709ColorMetadata(let field, _): "non_rec709_\(field.rawValue)"
        case .missingScanMetadata: "missing_scan_metadata"
        case .interlacedInput: "interlaced_input"
        case .unsupportedScanType: "unsupported_scan_type"
        case .missingBitDepth: "missing_bit_depth"
        case .unsupportedBitDepth: "unsupported_bit_depth"
        case .missingSubsampling: "missing_subsampling"
        case .unsupportedSubsampling: "unsupported_subsampling"
        case .missingChromaSiting: "missing_chroma_siting"
        case .unsupportedChromaSiting: "unsupported_chroma_siting"
        }
    }
}

struct ASHVideoProfileObservationV1: Equatable, Sendable {
    let pixelFormat: String?
    let range: String?
    let colorPrimaries: String?
    let transferFunction: String?
    let yCbCrMatrix: String?
    let scanType: String?
    let bitDepth: Int?
    let subsampling: String?
    let chromaSiting: String?
}

struct ASHVideoProfileInstanceV1: Equatable, Sendable {
    let profileFamilyID: String
    let pixelFormat: ASHVideoProfilePixelFormatV1
    let range: ASHVideoCodeRange8Bit
    let colorPrimaries: String
    let transferFunction: String
    let yCbCrMatrix: String
    let scanType: String
    let bitDepth: Int
    let subsampling: String
    let chromaSiting: ASHChromaSitingV2

    fileprivate init(
        profileFamilyID: String,
        pixelFormat: ASHVideoProfilePixelFormatV1,
        range: ASHVideoCodeRange8Bit,
        colorPrimaries: String,
        transferFunction: String,
        yCbCrMatrix: String,
        scanType: String,
        bitDepth: Int,
        subsampling: String,
        chromaSiting: ASHChromaSitingV2
    ) {
        self.profileFamilyID = profileFamilyID
        self.pixelFormat = pixelFormat
        self.range = range
        self.colorPrimaries = colorPrimaries
        self.transferFunction = transferFunction
        self.yCbCrMatrix = yCbCrMatrix
        self.scanType = scanType
        self.bitDepth = bitDepth
        self.subsampling = subsampling
        self.chromaSiting = chromaSiting
    }

    var canonicalBytes: Data {
        ASHLUTCanonicalJSONV2.encode(canonicalValue)
    }

    var sha256: ASHLUTHashV2 {
        ASHLUTHashV2(validatedBytes: Array(SHA256.hash(data: canonicalBytes)))
    }

    fileprivate var canonicalValue: ASHLUTStrictJSONValueV2 {
        .object([
            "bit_depth": .integer(Int64(bitDepth)),
            "chroma_siting": .string(chromaSiting.rawValue),
            "color_primaries": .string(colorPrimaries),
            "pixel_format": .string(pixelFormat.rawValue),
            "profile_family_id": .string(profileFamilyID),
            "range": .string(range.rawValue),
            "scan_type": .string(scanType),
            "subsampling": .string(subsampling),
            "transfer_function": .string(transferFunction),
            "ycbcr_matrix": .string(yCbCrMatrix)
        ])
    }
}

struct ASHVideoProfileContractV1: Equatable, Sendable {
    static let schemaVersion = "1.0.0"
    static let artifactKind = "ash_video_profile_contract"
    static let profileFamilyID = "ash-rec709-progressive-420-8bit-v1"
    static let rec709Token = "ITU_R_709_2"
    static let progressiveToken = "progressive"
    static let subsamplingToken = "4:2:0"
    static let bitDepth = 8
    static let canonicalSitings: [ASHChromaSitingV2] = [
        .bottom, .bottomLeft, .center, .left, .top, .topLeft
    ]
    static let canonicalFormats: [ASHVideoProfilePixelFormatV1] = [
        .fullRange420, .videoRange420
    ]

    let sha256: ASHLUTHashV2
    let immutableBytes: Data

    private init(sha256: ASHLUTHashV2, immutableBytes: Data) {
        self.sha256 = sha256
        self.immutableBytes = immutableBytes
    }

    var canonicalInstances: [ASHVideoProfileInstanceV1] {
        Self.canonicalFormats.flatMap { format in
            Self.canonicalSitings.map { siting in
                makeInstance(pixelFormat: format, chromaSiting: siting)
            }
        }
    }

    var instanceMatrixSHA256: ASHLUTHashV2 {
        let value = ASHLUTStrictJSONValueV2.array(canonicalInstances.map(\.canonicalValue))
        let bytes = ASHLUTCanonicalJSONV2.encode(value)
        return ASHLUTHashV2(validatedBytes: Array(SHA256.hash(data: bytes)))
    }

    static func load(
        _ data: Data,
        expectedSHA256: ASHLUTHashV2? = nil
    ) throws -> ASHVideoProfileContractV1 {
        let observed = ASHLUTHashV2(validatedBytes: Array(SHA256.hash(data: data)))
        if let expectedSHA256, observed != expectedSHA256 {
            throw ASHVideoProfileContractV1Error.hashMismatch
        }
        let parsed: ASHLUTStrictJSONValueV2
        do {
            var parser = ASHLUTStrictJSONParserV2(data: data)
            parsed = try parser.parse()
        } catch {
            throw ASHVideoProfileContractV1Error.invalidContract
        }
        var canonicalText = ASHLUTCanonicalJSONV2.encode(parsed)
        canonicalText.append(0x0a)
        guard canonicalText == data else {
            throw ASHVideoProfileContractV1Error.nonCanonicalEncoding
        }
        try validateDocument(parsed)
        return ASHVideoProfileContractV1(sha256: observed, immutableBytes: data)
    }

    func validate(_ observation: ASHVideoProfileObservationV1) throws -> ASHVideoProfileInstanceV1 {
        let pixelFormat = try parsePixelFormat(observation.pixelFormat)
        let range = try parseRange(observation.range)
        guard pixelFormat.range == range else {
            throw ASHVideoProfileContractV1Error.invalidPixelFormatRangePair(
                pixelFormat: pixelFormat.rawValue,
                range: range.rawValue
            )
        }
        try validateColor(observation.colorPrimaries, field: .colorPrimaries)
        try validateColor(observation.transferFunction, field: .transferFunction)
        try validateColor(observation.yCbCrMatrix, field: .yCbCrMatrix)
        guard let scanType = observation.scanType else {
            throw ASHVideoProfileContractV1Error.missingScanMetadata
        }
        if scanType == "interlaced" {
            throw ASHVideoProfileContractV1Error.interlacedInput
        }
        guard scanType == Self.progressiveToken else {
            throw ASHVideoProfileContractV1Error.unsupportedScanType(scanType)
        }
        guard let bitDepth = observation.bitDepth else {
            throw ASHVideoProfileContractV1Error.missingBitDepth
        }
        guard bitDepth == Self.bitDepth else {
            throw ASHVideoProfileContractV1Error.unsupportedBitDepth(bitDepth)
        }
        guard let subsampling = observation.subsampling else {
            throw ASHVideoProfileContractV1Error.missingSubsampling
        }
        guard subsampling == Self.subsamplingToken else {
            throw ASHVideoProfileContractV1Error.unsupportedSubsampling(subsampling)
        }
        guard let rawSiting = observation.chromaSiting else {
            throw ASHVideoProfileContractV1Error.missingChromaSiting
        }
        guard let siting = ASHChromaSitingV2(rawValue: rawSiting),
              Self.canonicalSitings.contains(siting) else {
            throw ASHVideoProfileContractV1Error.unsupportedChromaSiting(rawSiting)
        }
        return makeInstance(pixelFormat: pixelFormat, chromaSiting: siting)
    }

    private func makeInstance(
        pixelFormat: ASHVideoProfilePixelFormatV1,
        chromaSiting: ASHChromaSitingV2
    ) -> ASHVideoProfileInstanceV1 {
        ASHVideoProfileInstanceV1(
            profileFamilyID: Self.profileFamilyID,
            pixelFormat: pixelFormat,
            range: pixelFormat.range,
            colorPrimaries: Self.rec709Token,
            transferFunction: Self.rec709Token,
            yCbCrMatrix: Self.rec709Token,
            scanType: Self.progressiveToken,
            bitDepth: Self.bitDepth,
            subsampling: Self.subsamplingToken,
            chromaSiting: chromaSiting
        )
    }

    private static func validateDocument(_ value: ASHLUTStrictJSONValueV2) throws {
        guard case .object(let root) = value else {
            throw ASHVideoProfileContractV1Error.invalidContract
        }
        let keys: Set<String> = [
            "allowed_chroma_sitings", "artifact_kind", "bit_depth", "color",
            "profile_family_id", "scan_type", "schema_version", "subsampling",
            "valid_pixel_format_range_pairs"
        ]
        guard Set(root.keys) == keys else {
            throw ASHVideoProfileContractV1Error.fieldSetMismatch
        }
        guard string(root["artifact_kind"]) == artifactKind,
              integer(root["bit_depth"]) == Int64(bitDepth),
              string(root["profile_family_id"]) == profileFamilyID,
              string(root["scan_type"]) == progressiveToken,
              string(root["schema_version"]) == schemaVersion,
              string(root["subsampling"]) == subsamplingToken,
              validateColorDocument(root["color"]),
              validateSitingDocument(root["allowed_chroma_sitings"]),
              validatePairDocument(root["valid_pixel_format_range_pairs"]) else {
            throw ASHVideoProfileContractV1Error.invalidContract
        }
    }

    private static func validateColorDocument(_ value: ASHLUTStrictJSONValueV2?) -> Bool {
        guard case .object(let color) = value,
              Set(color.keys) == ["color_primaries", "transfer_function", "ycbcr_matrix"] else {
            return false
        }
        return color.values.allSatisfy { string($0) == rec709Token }
    }

    private static func validateSitingDocument(_ value: ASHLUTStrictJSONValueV2?) -> Bool {
        guard case .array(let values) = value else { return false }
        return values.compactMap(string) == canonicalSitings.map(\.rawValue)
    }

    private static func validatePairDocument(_ value: ASHLUTStrictJSONValueV2?) -> Bool {
        guard case .array(let values) = value, values.count == canonicalFormats.count else {
            return false
        }
        return zip(values, canonicalFormats).allSatisfy { pair in
            let (value, format) = pair
            guard case .object(let pair) = value,
                  Set(pair.keys) == ["pixel_format", "range"] else {
                return false
            }
            return string(pair["pixel_format"]) == format.rawValue
                && string(pair["range"]) == format.range.rawValue
        }
    }

    private func parsePixelFormat(
        _ value: String?
    ) throws -> ASHVideoProfilePixelFormatV1 {
        guard let value else { throw ASHVideoProfileContractV1Error.missingPixelFormat }
        guard let format = ASHVideoProfilePixelFormatV1(rawValue: value) else {
            throw ASHVideoProfileContractV1Error.unsupportedPixelFormat(value)
        }
        return format
    }

    private func parseRange(_ value: String?) throws -> ASHVideoCodeRange8Bit {
        guard let value else { throw ASHVideoProfileContractV1Error.missingRange }
        guard let range = ASHVideoCodeRange8Bit(rawValue: value) else {
            throw ASHVideoProfileContractV1Error.unsupportedRange(value)
        }
        return range
    }

    private func validateColor(
        _ value: String?,
        field: ASHVideoProfileColorFieldV1
    ) throws {
        guard let value else {
            throw ASHVideoProfileContractV1Error.missingColorMetadata(field)
        }
        guard value == Self.rec709Token else {
            throw ASHVideoProfileContractV1Error.nonRec709ColorMetadata(
                field: field,
                observed: value
            )
        }
    }

    private static func string(_ value: ASHLUTStrictJSONValueV2?) -> String? {
        guard case .string(let result) = value else { return nil }
        return result
    }

    private static func integer(_ value: ASHLUTStrictJSONValueV2?) -> Int64? {
        guard case .integer(let result) = value else { return nil }
        return result
    }
}
