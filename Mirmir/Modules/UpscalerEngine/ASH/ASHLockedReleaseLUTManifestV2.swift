import Foundation

struct ASHLockedReleaseLUTManifestV2: Equatable, Sendable {
    static let schemaVersion = "2.0.0"
    static let manifestID = "mirmir-ash-route-luts-v2"

    let configurationID: String
    let compilerInput: ASHLockedLUTFileBindingV2
    let lutBinaryContract: ASHLockedLUTFileBindingV2
    let nativeParityManifest: ASHLockedLUTFileBindingV2
    let routes: [ASHLockedLUTManifestRouteV2]
    let manifestSHA256: ASHLUTHashV2

    func route(_ route: ASHSpatialRouteV2) throws -> ASHLockedLUTManifestRouteV2 {
        guard let result = routes.first(where: { $0.route == route }) else {
            throw ASHLockedLUTManifestErrorV2.routeIdentityMismatch
        }
        return result
    }

    static func load(
        _ data: Data,
        compilerInputData: Data,
        lutBinaryContractData: Data,
        nativeParityManifestData: Data,
        configuration: ASHLUTLockedConfigurationV2
    ) throws -> ASHLockedReleaseLUTManifestV2 {
        let parser = ASHLockedLUTManifestParsingV2.self
        let root = try parser.document(data)
        let keys: Set<String> = [
            "schema_version", "manifest_id", "status", "configuration_id",
            "compiler_input", "lut_binary_contract", "hash_bindings", "routes",
            "runtime_load_policy", "native_parity_manifest", "holdout_accessed",
            "manifest_sha256"
        ]
        guard Set(root.keys) == keys else {
            throw ASHLockedLUTManifestErrorV2.fieldSetMismatch
        }
        try parser.require(root["schema_version"], string: schemaVersion)
        try parser.require(root["manifest_id"], string: manifestID)
        try parser.require(root["status"], string: "locked_before_p07")
        try parser.require(root["holdout_accessed"], boolean: false)
        try parser.validateConfiguration(root: root, configuration: configuration)
        try validateRuntimeLoadPolicy(root["runtime_load_policy"])
        let compilerInput = try parser.fileBinding(
            root["compiler_input"],
            expectedPath: "locked-compiler-input.json"
        )
        let contract = try parser.fileBinding(
            root["lut_binary_contract"],
            expectedPath: "validation/calibration_v2/contracts/lut-binary-contract-v1.json"
        )
        let parity = try parser.fileBinding(
            root["native_parity_manifest"],
            expectedPath: "native-lut-parity-manifest.json"
        )
        try parser.validate(binding: compilerInput, data: compilerInputData)
        try parser.validate(binding: contract, data: lutBinaryContractData)
        try parser.validate(binding: parity, data: nativeParityManifestData)
        let manifestSHA256 = try parser.validateSelfHash(root)
        return ASHLockedReleaseLUTManifestV2(
            configurationID: configuration.configurationID,
            compilerInput: compilerInput,
            lutBinaryContract: contract,
            nativeParityManifest: parity,
            routes: try parser.routes(
                root["routes"],
                configuration: configuration,
                manifestSHA256: manifestSHA256
            ),
            manifestSHA256: manifestSHA256
        )
    }

    private static func validateRuntimeLoadPolicy(
        _ value: ASHLUTStrictJSONValueV2?
    ) throws {
        let parser = ASHLockedLUTManifestParsingV2.self
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
