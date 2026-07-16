import CryptoKit
import Foundation

enum ASHLockedLUTManifestErrorV3: Error, Equatable, Sendable {
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

struct ASHLockedLUTFileBindingV3: Equatable, Sendable {
    let path: String
    let sha256: ASHLUTHashV3
    let sizeBytes: Int
}

struct ASHLockedLUTManifestRouteV3: Equatable, Sendable {
    let route: ASHSpatialRouteV2
    let lumaCoordinatePolicy: ASHSpatialCoordinatePolicyV2
    let chromaCoordinatePolicy: ASHSpatialCoordinatePolicyV2
    let analysisGridSourceStep: UInt8
    let entryCount: Int
    let parameterCount: Int
    let path: String
    let wholeFileSizeBytes: Int
    let wholeFileSHA256: ASHLUTHashV3
    let payloadSHA256: ASHLUTHashV3
    let headerCRC32: UInt32
    let payloadCRC32: UInt32
    let configuration: ASHLUTLockedConfigurationV3
    let manifestSHA256: ASHLUTHashV3
}

struct ASHLockedReleaseLUTManifestV3: Equatable, Sendable {
    static let filename = "lut-manifest-v3.json"
    static let schemaVersion = "3.0.0"
    static let manifestID = "mirmir-ash-route-luts-v3"
    static let compilerInputFilename = "locked-compiler-input-v2.json"
    static let nativeParityManifestFilename = "native-lut-parity-manifest-v3.json"

    let configurationID: String
    let compilerInput: ASHLockedLUTFileBindingV3
    let nativeParityManifest: ASHLockedLUTFileBindingV3
    let routes: [ASHLockedLUTManifestRouteV3]
    let manifestSHA256: ASHLUTHashV3

    func route(_ route: ASHSpatialRouteV2) throws -> ASHLockedLUTManifestRouteV3 {
        guard let result = routes.first(where: { $0.route == route }) else {
            throw ASHLockedLUTManifestErrorV3.routeIdentityMismatch
        }
        return result
    }

    static func load(
        _ data: Data,
        compilerInputData: Data,
        nativeParityManifestData: Data,
        configuration: ASHLUTLockedConfigurationV3
    ) throws -> ASHLockedReleaseLUTManifestV3 {
        let parser = ASHLockedLUTManifestParsingV3.self
        let root = try parser.document(data)
        let keys: Set<String> = [
            "schema_version", "manifest_id", "status", "configuration_id",
            "compiler_input", "hash_bindings", "routes", "runtime_load_policy",
            "native_parity_manifest", "holdout_accessed", "manifest_sha256"
        ]
        guard Set(root.keys) == keys else {
            throw ASHLockedLUTManifestErrorV3.fieldSetMismatch
        }
        try parser.require(root["schema_version"], string: schemaVersion)
        try parser.require(root["manifest_id"], string: manifestID)
        try parser.require(root["status"], string: "locked_before_p07")
        try parser.require(root["holdout_accessed"], boolean: false)
        try parser.validateConfiguration(root: root, configuration: configuration)
        try validateRuntimeLoadPolicy(root["runtime_load_policy"])
        let compilerInput = try parser.fileBinding(
            root["compiler_input"],
            expectedPath: compilerInputFilename
        )
        let nativeParityManifest = try parser.fileBinding(
            root["native_parity_manifest"],
            expectedPath: nativeParityManifestFilename
        )
        try parser.validate(binding: compilerInput, data: compilerInputData)
        try parser.validate(binding: nativeParityManifest, data: nativeParityManifestData)
        let manifestSHA256 = try parser.validateSelfHash(root)
        return ASHLockedReleaseLUTManifestV3(
            configurationID: configuration.configurationID,
            compilerInput: compilerInput,
            nativeParityManifest: nativeParityManifest,
            routes: try parser.routes(
                root["routes"],
                configuration: configuration,
                manifestSHA256: manifestSHA256
            ),
            manifestSHA256: manifestSHA256
        )
    }

    private static func validateRuntimeLoadPolicy(
        _ value: ASHLUTStrictJSONValueV3?
    ) throws {
        let parser = ASHLockedLUTManifestParsingV3.self
        let fields = try parser.object(value, keys: [
            "immutability", "load_frequency", "per_frame_load_count",
            "runtime_tree_generation_count",
            "maximum_operator_evaluations_per_output_cell"
        ])
        try parser.require(
            fields["immutability"],
            string: "validate complete bytes before publication and retain immutable bytes"
        )
        try parser.require(
            fields["load_frequency"],
            string: "once_per_route_per_configuration"
        )
        try parser.require(fields["per_frame_load_count"], integer: 0)
        try parser.require(fields["runtime_tree_generation_count"], integer: 0)
        try parser.require(
            fields["maximum_operator_evaluations_per_output_cell"],
            integer: 2
        )
    }
}

enum ASHLockedLUTManifestParsingV3 {
    static let hashBindingKeys: Set<String> = [
        "mapping_sha256", "operator_bank_sha256", "metric_policy_sha256",
        "compiler_inputs_sha256", "calibration_plan_sha256",
        "corpus_lock_bundle_sha256"
    ]

    static let routeKeys: Set<String> = [
        "route", "route_id", "scale_numerator", "scale_denominator",
        "phase_count", "context_count", "valid_state_count", "plane_count",
        "luma_coordinate_policy", "chroma_coordinate_policy",
        "analysis_grid_source_step", "entry_count", "parameter_count", "path",
        "whole_file_size_bytes", "whole_file_sha256", "payload_sha256",
        "header_crc32", "payload_crc32"
    ]

    static func document(_ data: Data) throws -> [String: ASHLUTStrictJSONValueV3] {
        guard data.last == 0x0a else {
            throw ASHLockedLUTManifestErrorV3.nonCanonicalEncoding
        }
        let compact = Data(data.dropLast())
        do {
            var parser = ASHLUTStrictJSONParserV3(data: compact)
            let parsed = try parser.parse()
            guard ASHLUTCanonicalJSONV3.encode(parsed) == compact,
                  case .object(let root) = parsed else {
                throw ASHLockedLUTManifestErrorV3.nonCanonicalEncoding
            }
            return root
        } catch let error as ASHLockedLUTManifestErrorV3 {
            throw error
        } catch {
            throw ASHLockedLUTManifestErrorV3.nonCanonicalEncoding
        }
    }

    static func validateSelfHash(
        _ root: [String: ASHLUTStrictJSONValueV3]
    ) throws -> ASHLUTHashV3 {
        let declared = try hash(root["manifest_sha256"])
        var input = root
        guard input.removeValue(forKey: "manifest_sha256") != nil else {
            throw ASHLockedLUTManifestErrorV3.fieldSetMismatch
        }
        let bytes = ASHLUTCanonicalJSONV3.encode(.object(input))
        let observed = ASHLUTHashV3(validatedBytes: Array(SHA256.hash(data: bytes)))
        guard declared == observed else {
            throw ASHLockedLUTManifestErrorV3.selfHashMismatch
        }
        return declared
    }

    static func validateConfiguration(
        root: [String: ASHLUTStrictJSONValueV3],
        configuration: ASHLUTLockedConfigurationV3
    ) throws {
        guard try string(root["configuration_id"]) == configuration.configurationID else {
            throw ASHLockedLUTManifestErrorV3.configurationMismatch
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
            throw ASHLockedLUTManifestErrorV3.configurationMismatch
        }
    }

    static func routes(
        _ value: ASHLUTStrictJSONValueV3?,
        configuration: ASHLUTLockedConfigurationV3,
        manifestSHA256: ASHLUTHashV3
    ) throws -> [ASHLockedLUTManifestRouteV3] {
        let rows = try array(value)
        guard rows.count == ASHSpatialRouteV2.allCases.count else {
            throw ASHLockedLUTManifestErrorV3.routeOrderMismatch
        }
        return try zip(rows, ASHSpatialRouteV2.allCases).map { value, route in
            try decodeRoute(
                object(value, keys: routeKeys),
                expectedRoute: route,
                configuration: configuration,
                manifestSHA256: manifestSHA256
            )
        }
    }

    static func fileBinding(
        _ value: ASHLUTStrictJSONValueV3?,
        expectedPath: String? = nil
    ) throws -> ASHLockedLUTFileBindingV3 {
        let fields = try object(value, keys: ["path", "sha256", "size_bytes"])
        let path = try string(fields["path"])
        guard safeRelativePath(path), expectedPath == nil || path == expectedPath else {
            throw ASHLockedLUTManifestErrorV3.invalidValue
        }
        let size = try integer(fields["size_bytes"])
        guard size > 0 else {
            throw ASHLockedLUTManifestErrorV3.invalidValue
        }
        return ASHLockedLUTFileBindingV3(
            path: path,
            sha256: try hash(fields["sha256"]),
            sizeBytes: size
        )
    }

    static func validate(binding: ASHLockedLUTFileBindingV3, data: Data) throws {
        let observed = ASHLUTHashV3(validatedBytes: Array(SHA256.hash(data: data)))
        guard data.count == binding.sizeBytes, observed == binding.sha256 else {
            throw ASHLockedLUTManifestErrorV3.fileBindingMismatch
        }
    }

    static func object(
        _ value: ASHLUTStrictJSONValueV3?,
        keys: Set<String>
    ) throws -> [String: ASHLUTStrictJSONValueV3] {
        guard case .object(let object)? = value, Set(object.keys) == keys else {
            throw ASHLockedLUTManifestErrorV3.fieldSetMismatch
        }
        return object
    }

    static func object(
        _ value: ASHLUTStrictJSONValueV3,
        keys: Set<String>
    ) throws -> [String: ASHLUTStrictJSONValueV3] {
        try object(Optional(value), keys: keys)
    }

    static func array(_ value: ASHLUTStrictJSONValueV3?) throws -> [ASHLUTStrictJSONValueV3] {
        guard case .array(let array)? = value else {
            throw ASHLockedLUTManifestErrorV3.invalidValue
        }
        return array
    }

    static func string(_ value: ASHLUTStrictJSONValueV3?) throws -> String {
        guard case .string(let string)? = value else {
            throw ASHLockedLUTManifestErrorV3.invalidValue
        }
        return string
    }

    static func integer(_ value: ASHLUTStrictJSONValueV3?) throws -> Int {
        guard case .integer(let integer)? = value,
              let result = Int(exactly: integer) else {
            throw ASHLockedLUTManifestErrorV3.invalidValue
        }
        return result
    }

    static func boolean(_ value: ASHLUTStrictJSONValueV3?) throws -> Bool {
        guard case .boolean(let boolean)? = value else {
            throw ASHLockedLUTManifestErrorV3.invalidValue
        }
        return boolean
    }

    static func hash(_ value: ASHLUTStrictJSONValueV3?) throws -> ASHLUTHashV3 {
        do {
            return try ASHLUTHashV3(hex: string(value))
        } catch {
            throw ASHLockedLUTManifestErrorV3.invalidValue
        }
    }

    static func require(_ value: ASHLUTStrictJSONValueV3?, string expected: String) throws {
        guard try string(value) == expected else {
            throw ASHLockedLUTManifestErrorV3.invalidValue
        }
    }

    static func require(_ value: ASHLUTStrictJSONValueV3?, integer expected: Int) throws {
        guard try integer(value) == expected else {
            throw ASHLockedLUTManifestErrorV3.invalidValue
        }
    }

    static func require(_ value: ASHLUTStrictJSONValueV3?, boolean expected: Bool) throws {
        guard try boolean(value) == expected else {
            throw ASHLockedLUTManifestErrorV3.invalidValue
        }
    }

    private static func decodeRoute(
        _ row: [String: ASHLUTStrictJSONValueV3],
        expectedRoute route: ASHSpatialRouteV2,
        configuration: ASHLUTLockedConfigurationV3,
        manifestSHA256: ASHLUTHashV3
    ) throws -> ASHLockedLUTManifestRouteV3 {
        let routeID = route == .direct2x ? 1 : 2
        let routePath = route == .direct2x ? "direct2x.ashlut" : "direct3over2.ashlut"
        guard try string(row["route"]) == route.rawValue,
              try integer(row["route_id"]) == routeID,
              try integer(row["scale_numerator"]) == route.scaleNumerator,
              try integer(row["scale_denominator"]) == route.scaleDenominator,
              try integer(row["phase_count"]) == route.phasePairCount,
              try integer(row["context_count"]) == ASHLUTBinaryContractV3.contextCount,
              try integer(row["valid_state_count"]) == ASHLUTBinaryContractV3.validStateCount,
              try integer(row["plane_count"]) == ASHLUTBinaryContractV3.planeCount,
              try string(row["path"]) == routePath else {
            throw ASHLockedLUTManifestErrorV3.routeOrderMismatch
        }
        let selection = configuration.routeSelection(for: route)
        guard try string(row["luma_coordinate_policy"])
                == selection.lumaCoordinatePolicy.rawValue,
              try string(row["chroma_coordinate_policy"])
                == selection.chromaCoordinatePolicy.rawValue,
              try integer(row["analysis_grid_source_step"])
                == Int(selection.analysisGridSourceStep) else {
            throw ASHLockedLUTManifestErrorV3.routeIdentityMismatch
        }
        let expectedEntryCount = ASHLUTBinaryContractV3.planeCount
            * route.phasePairCount
            * ASHLUTBinaryContractV3.contextCount
            * ASHLUTBinaryContractV3.validStateCount
        let entryCount = try integer(row["entry_count"])
        let parameterCount = try integer(row["parameter_count"])
        let wholeFileSize = try integer(row["whole_file_size_bytes"])
        guard entryCount == expectedEntryCount,
              parameterCount > 0,
              wholeFileSize > 0 else {
            throw ASHLockedLUTManifestErrorV3.routeIdentityMismatch
        }
        return ASHLockedLUTManifestRouteV3(
            route: route,
            lumaCoordinatePolicy: selection.lumaCoordinatePolicy,
            chromaCoordinatePolicy: selection.chromaCoordinatePolicy,
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

    private static func crc32(_ value: ASHLUTStrictJSONValueV3?) throws -> UInt32 {
        let encoded = try string(value)
        guard encoded.count == 10,
              encoded.hasPrefix("0x"),
              encoded.dropFirst(2).allSatisfy({ $0.isNumber || ("A"..."F").contains(String($0)) }),
              let result = UInt32(encoded.dropFirst(2), radix: 16) else {
            throw ASHLockedLUTManifestErrorV3.invalidValue
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
