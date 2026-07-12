import CryptoKit
import Foundation

enum ASHLockedLUTManifestErrorV2: Error, Equatable, Sendable {
    case nonCanonicalEncoding
    case fieldSetMismatch
    case invalidValue
    case selfHashMismatch
    case configurationMismatch
    case fileBindingMismatch
    case routeOrderMismatch
    case routeIdentityMismatch
    case wholeFileHashMismatch
    case payloadHashMismatch
    case checksumMismatch
}

struct ASHLockedLUTFileBindingV2: Equatable, Sendable {
    let path: String
    let sha256: ASHLUTHashV2
    let sizeBytes: Int
}

struct ASHLockedLUTManifestRouteV2: Equatable, Sendable {
    let route: ASHSpatialRouteV2
    let coordinatePolicy: ASHSpatialCoordinatePolicyV2
    let analysisGridSourceStep: UInt8
    let entryCount: Int
    let parameterCount: Int
    let path: String
    let wholeFileSizeBytes: Int
    let wholeFileSHA256: ASHLUTHashV2
    let payloadSHA256: ASHLUTHashV2
    let headerCRC32: UInt32
    let payloadCRC32: UInt32
    let configuration: ASHLUTLockedConfigurationV2
    let manifestSHA256: ASHLUTHashV2
}

enum ASHLockedLUTManifestParsingV2 {
    static let hashBindingKeys: Set<String> = [
        "mapping_sha256", "operator_bank_sha256", "metric_policy_sha256",
        "compiler_inputs_sha256", "calibration_plan_sha256",
        "corpus_lock_bundle_sha256"
    ]

    static let routeKeys: Set<String> = [
        "route", "route_id", "scale_numerator", "scale_denominator",
        "phase_count", "context_count", "valid_state_count",
        "coordinate_policy", "analysis_grid_source_step", "entry_count",
        "parameter_count", "path", "whole_file_size_bytes",
        "whole_file_sha256", "payload_sha256", "header_crc32", "payload_crc32"
    ]

    static func document(_ data: Data) throws -> [String: ASHLUTStrictJSONValueV2] {
        guard data.last == 0x0a else {
            throw ASHLockedLUTManifestErrorV2.nonCanonicalEncoding
        }
        let compact = Data(data.dropLast())
        var parser = ASHLUTStrictJSONParserV2(data: compact)
        let parsed = try parser.parse()
        guard ASHLUTCanonicalJSONV2.encode(parsed) == compact,
              case .object(let root) = parsed else {
            throw ASHLockedLUTManifestErrorV2.nonCanonicalEncoding
        }
        return root
    }

    static func validateSelfHash(
        _ root: [String: ASHLUTStrictJSONValueV2]
    ) throws -> ASHLUTHashV2 {
        let declared = try hash(root["manifest_sha256"])
        var input = root
        guard input.removeValue(forKey: "manifest_sha256") != nil else {
            throw ASHLockedLUTManifestErrorV2.fieldSetMismatch
        }
        let bytes = ASHLUTCanonicalJSONV2.encode(.object(input))
        let observed = ASHLUTHashV2(
            validatedBytes: Array(SHA256.hash(data: bytes))
        )
        guard declared == observed else {
            throw ASHLockedLUTManifestErrorV2.selfHashMismatch
        }
        return declared
    }

    static func validateConfiguration(
        root: [String: ASHLUTStrictJSONValueV2],
        configuration: ASHLUTLockedConfigurationV2
    ) throws {
        guard try string(root["configuration_id"]) == configuration.configurationID else {
            throw ASHLockedLUTManifestErrorV2.configurationMismatch
        }
        let hashes = try object(root["hash_bindings"], keys: hashBindingKeys)
        let expected = [
            "mapping_sha256": configuration.mappingSHA256,
            "operator_bank_sha256": configuration.operatorBankSHA256,
            "metric_policy_sha256": configuration.metricPolicySHA256,
            "compiler_inputs_sha256": configuration.compilerInputsSHA256,
            "calibration_plan_sha256": configuration.calibrationPlanSHA256,
            "corpus_lock_bundle_sha256": configuration.corpusLockBundleSHA256
        ]
        for (name, value) in expected where try hash(hashes[name]) != value {
            throw ASHLockedLUTManifestErrorV2.configurationMismatch
        }
    }

    static func routes(
        _ value: ASHLUTStrictJSONValueV2?,
        configuration: ASHLUTLockedConfigurationV2,
        manifestSHA256: ASHLUTHashV2
    ) throws -> [ASHLockedLUTManifestRouteV2] {
        let rows = try array(value)
        guard rows.count == ASHSpatialRouteV2.allCases.count else {
            throw ASHLockedLUTManifestErrorV2.routeOrderMismatch
        }
        return try zip(rows, ASHSpatialRouteV2.allCases).map { value, route in
            let row = try object(value, keys: routeKeys)
            return try decodeRoute(
                row,
                expectedRoute: route,
                configuration: configuration,
                manifestSHA256: manifestSHA256
            )
        }
    }

    static func fileBinding(
        _ value: ASHLUTStrictJSONValueV2?,
        expectedPath: String? = nil
    ) throws -> ASHLockedLUTFileBindingV2 {
        let fields = try object(value, keys: ["path", "sha256", "size_bytes"])
        let path = try string(fields["path"])
        guard safeRelativePath(path), expectedPath == nil || path == expectedPath else {
            throw ASHLockedLUTManifestErrorV2.invalidValue
        }
        let size = try integer(fields["size_bytes"])
        guard size > 0 else {
            throw ASHLockedLUTManifestErrorV2.invalidValue
        }
        return ASHLockedLUTFileBindingV2(
            path: path,
            sha256: try hash(fields["sha256"]),
            sizeBytes: size
        )
    }

    static func validate(
        binding: ASHLockedLUTFileBindingV2,
        data: Data
    ) throws {
        let observed = ASHLUTHashV2(
            validatedBytes: Array(SHA256.hash(data: data))
        )
        guard data.count == binding.sizeBytes, observed == binding.sha256 else {
            throw ASHLockedLUTManifestErrorV2.fileBindingMismatch
        }
    }

    static func object(
        _ value: ASHLUTStrictJSONValueV2?,
        keys: Set<String>
    ) throws -> [String: ASHLUTStrictJSONValueV2] {
        guard case .object(let object)? = value, Set(object.keys) == keys else {
            throw ASHLockedLUTManifestErrorV2.fieldSetMismatch
        }
        return object
    }

    static func object(
        _ value: ASHLUTStrictJSONValueV2,
        keys: Set<String>
    ) throws -> [String: ASHLUTStrictJSONValueV2] {
        try object(Optional(value), keys: keys)
    }

    static func array(
        _ value: ASHLUTStrictJSONValueV2?
    ) throws -> [ASHLUTStrictJSONValueV2] {
        guard case .array(let array)? = value else {
            throw ASHLockedLUTManifestErrorV2.invalidValue
        }
        return array
    }

    static func string(_ value: ASHLUTStrictJSONValueV2?) throws -> String {
        guard case .string(let string)? = value else {
            throw ASHLockedLUTManifestErrorV2.invalidValue
        }
        return string
    }

    static func integer(_ value: ASHLUTStrictJSONValueV2?) throws -> Int {
        guard case .integer(let integer)? = value,
              let result = Int(exactly: integer) else {
            throw ASHLockedLUTManifestErrorV2.invalidValue
        }
        return result
    }

    static func boolean(_ value: ASHLUTStrictJSONValueV2?) throws -> Bool {
        guard case .boolean(let boolean)? = value else {
            throw ASHLockedLUTManifestErrorV2.invalidValue
        }
        return boolean
    }

    static func hash(_ value: ASHLUTStrictJSONValueV2?) throws -> ASHLUTHashV2 {
        do {
            return try ASHLUTHashV2(hex: string(value))
        } catch {
            throw ASHLockedLUTManifestErrorV2.invalidValue
        }
    }

    static func require(
        _ value: ASHLUTStrictJSONValueV2?,
        string expected: String
    ) throws {
        guard try string(value) == expected else {
            throw ASHLockedLUTManifestErrorV2.invalidValue
        }
    }

    static func require(
        _ value: ASHLUTStrictJSONValueV2?,
        integer expected: Int
    ) throws {
        guard try integer(value) == expected else {
            throw ASHLockedLUTManifestErrorV2.invalidValue
        }
    }

    static func require(
        _ value: ASHLUTStrictJSONValueV2?,
        boolean expected: Bool
    ) throws {
        guard try boolean(value) == expected else {
            throw ASHLockedLUTManifestErrorV2.invalidValue
        }
    }

    private static func decodeRoute(
        _ row: [String: ASHLUTStrictJSONValueV2],
        expectedRoute route: ASHSpatialRouteV2,
        configuration: ASHLUTLockedConfigurationV2,
        manifestSHA256: ASHLUTHashV2
    ) throws -> ASHLockedLUTManifestRouteV2 {
        let routeID = route == .direct2x ? 1 : 2
        let routePath = route == .direct2x ? "direct2x.ashlut" : "direct3over2.ashlut"
        guard try string(row["route"]) == route.rawValue,
              try integer(row["route_id"]) == routeID,
              try integer(row["scale_numerator"]) == route.scaleNumerator,
              try integer(row["scale_denominator"]) == route.scaleDenominator,
              try integer(row["phase_count"]) == route.phasePairCount,
              try integer(row["context_count"]) == 4,
              try integer(row["valid_state_count"]) == 256,
              try string(row["path"]) == routePath else {
            throw ASHLockedLUTManifestErrorV2.routeOrderMismatch
        }
        let selection = configuration.routeSelection(for: route)
        guard try string(row["coordinate_policy"]) == selection.coordinatePolicy.rawValue,
              try integer(row["analysis_grid_source_step"])
                == Int(selection.analysisGridSourceStep) else {
            throw ASHLockedLUTManifestErrorV2.routeIdentityMismatch
        }
        let expectedEntryCount = route.phasePairCount * 4 * 256
        let entryCount = try integer(row["entry_count"])
        let parameterCount = try integer(row["parameter_count"])
        let wholeFileSize = try integer(row["whole_file_size_bytes"])
        guard entryCount == expectedEntryCount,
              parameterCount > 0,
              wholeFileSize > 0 else {
            throw ASHLockedLUTManifestErrorV2.routeIdentityMismatch
        }
        return ASHLockedLUTManifestRouteV2(
            route: route,
            coordinatePolicy: selection.coordinatePolicy,
            analysisGridSourceStep: selection.analysisGridSourceStep,
            entryCount: entryCount,
            parameterCount: parameterCount,
            path: routePath,
            wholeFileSizeBytes: wholeFileSize,
            wholeFileSHA256: try hash(row["whole_file_sha256"]),
            payloadSHA256: try hash(row["payload_sha256"]),
            headerCRC32: try crc32(row["header_crc32"]),
            payloadCRC32: try crc32(row["payload_crc32"]),
            configuration: configuration,
            manifestSHA256: manifestSHA256
        )
    }

    private static func crc32(_ value: ASHLUTStrictJSONValueV2?) throws -> UInt32 {
        let encoded = try string(value)
        guard encoded.count == 10,
              encoded.hasPrefix("0x"),
              encoded.dropFirst(2).allSatisfy({ $0.isNumber || ("A"..."F").contains(String($0)) }),
              let result = UInt32(encoded.dropFirst(2), radix: 16) else {
            throw ASHLockedLUTManifestErrorV2.invalidValue
        }
        return result
    }

    private static func safeRelativePath(_ value: String) -> Bool {
        guard !value.isEmpty,
              !value.hasPrefix("/"),
              !value.contains("\\"),
              !value.contains("//"),
              !value.contains("\0") else {
            return false
        }
        return value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }
}
