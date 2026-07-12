import Foundation

struct ASHLockedCandidateLUTManifestV1: Equatable, Sendable {
    static let schemaVersion = "1.0.0"
    static let manifestID = "mirmir-ash-candidate-route-luts-v1"

    let configurationID: String
    let compilerInput: ASHLockedLUTFileBindingV2
    let routes: [ASHLockedLUTManifestRouteV2]
    let executableSHA256: ASHLUTHashV2
    let sourceManifestSHA256: ASHLUTHashV2
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
        configuration: ASHLUTLockedConfigurationV2
    ) throws -> ASHLockedCandidateLUTManifestV1 {
        let parser = ASHLockedLUTManifestParsingV2.self
        let root = try parser.document(data)
        let keys: Set<String> = [
            "schema_version", "manifest_id", "status", "configuration_id",
            "compiler_input", "hash_bindings", "routes", "swift_cli",
            "native_parity_claimed", "manifest_sha256"
        ]
        guard Set(root.keys) == keys else {
            throw ASHLockedLUTManifestErrorV2.fieldSetMismatch
        }
        try parser.require(root["schema_version"], string: schemaVersion)
        try parser.require(root["manifest_id"], string: manifestID)
        try parser.require(root["status"], string: "calibration_candidate")
        try parser.require(root["native_parity_claimed"], boolean: false)
        try parser.validateConfiguration(root: root, configuration: configuration)
        let compilerInput = try parser.fileBinding(
            root["compiler_input"],
            expectedPath: "locked-compiler-input.json"
        )
        try parser.validate(binding: compilerInput, data: compilerInputData)
        let manifestSHA256 = try parser.validateSelfHash(root)
        let cli = try parser.object(root["swift_cli"], keys: [
            "executable_sha256", "source_manifest_sha256"
        ])
        return ASHLockedCandidateLUTManifestV1(
            configurationID: configuration.configurationID,
            compilerInput: compilerInput,
            routes: try parser.routes(
                root["routes"],
                configuration: configuration,
                manifestSHA256: manifestSHA256
            ),
            executableSHA256: try parser.hash(cli["executable_sha256"]),
            sourceManifestSHA256: try parser.hash(cli["source_manifest_sha256"]),
            manifestSHA256: manifestSHA256
        )
    }
}
