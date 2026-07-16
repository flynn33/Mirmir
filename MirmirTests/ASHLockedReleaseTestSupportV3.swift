import CryptoKit
import Foundation
import os.lock
@testable import Mirmir

enum ASHLockedReleaseTestSupportV3 {
    struct Fixture: Sendable {
        let root: URL
        let direct2x: ASHLUTTestFixtureV3
        let direct3Over2: ASHLUTTestFixtureV3
    }

    private struct Template: Sendable {
        let configurationBytes: Data
        let mappingBytes: Data
        let parityBytes: Data
        let manifestBytes: Data
        let direct2x: ASHLUTTestFixtureV3
        let direct3Over2: ASHLUTTestFixtureV3
    }

    private static let templateCache = OSAllocatedUnfairLock<Template?>(
        initialState: nil
    )

    static func makeFixture() throws -> Fixture {
        let template = try templateCache.withLock { cached in
            if let cached { return cached }
            let template = try makeTemplate()
            cached = template
            return template
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mirmir-ash-v3-artifacts-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
        try template.configurationBytes.write(
            to: root.appendingPathComponent(
                ASHLockedReleaseLUTManifestV3.compilerInputFilename
            )
        )
        try template.mappingBytes.write(
            to: root.appendingPathComponent("locked-mapping.json")
        )
        try template.parityBytes.write(
            to: root.appendingPathComponent(
                ASHLockedReleaseLUTManifestV3.nativeParityManifestFilename
            )
        )
        try template.manifestBytes.write(
            to: root.appendingPathComponent(ASHLockedReleaseLUTManifestV3.filename)
        )
        try template.direct2x.artifact.data.write(
            to: root.appendingPathComponent("direct2x.ashlut")
        )
        try template.direct3Over2.artifact.data.write(
            to: root.appendingPathComponent("direct3over2.ashlut")
        )
        return Fixture(
            root: root,
            direct2x: template.direct2x,
            direct3Over2: template.direct3Over2
        )
    }

    static func artifacts() async throws -> ASHLockedArtifactSetV3 {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        return try await ASHLockedArtifactStoreV3(
            resourceRoot: fixture.root
        ).artifacts()
    }

    private static func makeTemplate() throws -> Template {
        let base = try ASHLUTTestSupportV3.sharedConfiguration()
        let mappingBytes = try makeMapping(configuration: base)
        let configurationBytes = try makeConfiguration(
            mappingSHA256: sha256(mappingBytes)
        )
        let configuration = try ASHLUTLockedConfigurationJSONLoaderV3.load(
            configurationBytes
        )
        let direct2x = try makeRouteFixture(.direct2x, configuration: configuration)
        let direct3Over2 = try makeRouteFixture(
            .direct3Over2,
            configuration: configuration
        )
        let parityBytes = Data("{\"status\":\"verified\"}\n".utf8)
        return Template(
            configurationBytes: configurationBytes,
            mappingBytes: mappingBytes,
            parityBytes: parityBytes,
            manifestBytes: try makeManifest(
                configuration: configuration,
                configurationBytes: configurationBytes,
                parityBytes: parityBytes,
                fixtures: [direct2x, direct3Over2]
            ),
            direct2x: direct2x,
            direct3Over2: direct3Over2
        )
    }

    private static func makeRouteFixture(
        _ route: ASHSpatialRouteV2,
        configuration: ASHLUTLockedConfigurationV3
    ) throws -> ASHLUTTestFixtureV3 {
        let compilation = try ASHLUTLeafCompilerV3.compile(
            route: route,
            configuration: configuration
        )
        return ASHLUTTestFixtureV3(
            configuration: configuration,
            compilation: compilation,
            artifact: try ASHLUTBinaryCodecV3.serialize(compilation)
        )
    }

    private static func makeConfiguration(mappingSHA256: ASHLUTHashV3) throws -> Data {
        let source = try ASHLUTTestSupportV3.sharedLockedInputData()
        var parser = ASHLUTStrictJSONParserV3(data: source)
        guard case .object(var root) = try parser.parse(),
              case .object(var hashes)? = root["hash_bindings"] else {
            throw ASHLUTLockedConfigurationJSONErrorV3.invalidSyntax
        }
        hashes["mapping_sha256"] = .string(mappingSHA256.hex)
        hashes.removeValue(forKey: "compiler_inputs_sha256")
        root["hash_bindings"] = .object(hashes)
        let selfHash = sha256(ASHLUTCanonicalJSONV3.encode(.object(root)))
        hashes["compiler_inputs_sha256"] = .string(selfHash.hex)
        root["hash_bindings"] = .object(hashes)
        var bytes = ASHLUTCanonicalJSONV3.encode(.object(root))
        bytes.append(0x0a)
        return bytes
    }

    private static func makeMapping(
        configuration: ASHLUTLockedConfigurationV3
    ) throws -> Data {
        let document: [String: Any] = [
            "analysis_epsilon_q0_30": 1,
            "analysis_grid_source_steps": [
                "direct_2x": Int(configuration.routes.direct2x.analysisGridSourceStep),
                "direct_3_over_2": Int(
                    configuration.routes.direct3Over2.analysisGridSourceStep
                )
            ],
            "boundary_mode": configuration.boundaryMode == .clamp
                ? "clamp" : "mirror_reflect101",
            "candidate_vector_sha256": String(repeating: "bb", count: 32),
            "canonical_core_unchanged": true,
            "chroma_edge_confidence_unorm15": 3_277,
            "configuration_id": configuration.configurationID,
            "input_contract": [
                "bit_depth": 8,
                "chroma_siting": "left",
                "matrix": "BT.709",
                "pixel_format": "420v",
                "range": "video",
                "subsampling": "4:2:0"
            ],
            "mapping_id": "ash-video-mapping-v2",
            "mapping_seed_sha256": String(repeating: "aa", count: 32),
            "risk_weights_unorm15": [
                "alternating_difference": 16_383,
                "laplacian": 16_384
            ],
            "schema_version": "1.0.0",
            "selection_binding": [
                "calibration_selection_sha256": String(repeating: "dd", count: 32),
                "selected_evaluation_sha256": String(repeating: "ee", count: 32)
            ],
            "shared_bank_configuration_sha256": String(repeating: "cc", count: 32),
            "status": "locked_before_p07",
            "thresholds_unorm15": [
                "alias_or_ringing_risk": ["high": 13_107, "low": 6_553],
                "chroma_luma_structure_aligned": ["high": 13_107, "low": 6_553],
                "coherent_structure": ["high": 13_107, "low": 6_553],
                "edge_present": ["high": 13_107, "low": 6_553],
                "temporal_support_valid": ["high": 32_767, "low": 32_767],
                "texture_high_frequency": ["high": 13_107, "low": 6_553]
            ]
        ]
        return try JSONSerialization.data(
            withJSONObject: document,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    private static func makeManifest(
        configuration: ASHLUTLockedConfigurationV3,
        configurationBytes: Data,
        parityBytes: Data,
        fixtures: [ASHLUTTestFixtureV3]
    ) throws -> Data {
        var root: [String: ASHLUTStrictJSONValueV3] = [
            "schema_version": .string(ASHLockedReleaseLUTManifestV3.schemaVersion),
            "manifest_id": .string(ASHLockedReleaseLUTManifestV3.manifestID),
            "status": .string("locked_before_p07"),
            "configuration_id": .string(configuration.configurationID),
            "compiler_input": fileBinding(
                path: ASHLockedReleaseLUTManifestV3.compilerInputFilename,
                data: configurationBytes
            ),
            "native_parity_manifest": fileBinding(
                path: ASHLockedReleaseLUTManifestV3.nativeParityManifestFilename,
                data: parityBytes
            ),
            "hash_bindings": .object([
                "mapping_sha256": .string(configuration.mappingSHA256.hex),
                "operator_bank_sha256": .string(configuration.operatorBankSHA256.hex),
                "metric_policy_sha256": .string(configuration.metricPolicySHA256.hex),
                "compiler_inputs_sha256": .string(configuration.compilerInputsSHA256.hex),
                "calibration_plan_sha256": .string(configuration.calibrationPlanSHA256.hex),
                "corpus_lock_bundle_sha256": .string(
                    configuration.corpusLockBundleSHA256.hex
                )
            ]),
            "routes": .array(try fixtures.map(routeRow)),
            "runtime_load_policy": .object([
                "immutability": .string(
                    "validate complete bytes before publication and retain immutable bytes"
                ),
                "load_frequency": .string("once_per_route_per_configuration"),
                "per_frame_load_count": .integer(0),
                "runtime_tree_generation_count": .integer(0),
                "maximum_operator_evaluations_per_output_cell": .integer(2)
            ]),
            "holdout_accessed": .boolean(false)
        ]
        root["manifest_sha256"] = .string(
            sha256(ASHLUTCanonicalJSONV3.encode(.object(root))).hex
        )
        var bytes = ASHLUTCanonicalJSONV3.encode(.object(root))
        bytes.append(0x0a)
        return bytes
    }

    private static func routeRow(
        _ fixture: ASHLUTTestFixtureV3
    ) throws -> ASHLUTStrictJSONValueV3 {
        let route = fixture.artifact.route
        let selection = fixture.configuration.routeSelection(for: route)
        let path = route == .direct2x ? "direct2x.ashlut" : "direct3over2.ashlut"
        return .object([
            "route": .string(route.rawValue),
            "route_id": .integer(Int64(route == .direct2x ? 1 : 2)),
            "scale_numerator": .integer(Int64(route.scaleNumerator)),
            "scale_denominator": .integer(Int64(route.scaleDenominator)),
            "phase_count": .integer(Int64(route.phasePairCount)),
            "context_count": .integer(Int64(ASHLUTBinaryContractV3.contextCount)),
            "valid_state_count": .integer(Int64(ASHLUTBinaryContractV3.validStateCount)),
            "plane_count": .integer(Int64(ASHLUTBinaryContractV3.planeCount)),
            "luma_coordinate_policy": .string(selection.lumaCoordinatePolicy.rawValue),
            "chroma_coordinate_policy": .string(selection.chromaCoordinatePolicy.rawValue),
            "analysis_grid_source_step": .integer(Int64(selection.analysisGridSourceStep)),
            "entry_count": .integer(Int64(fixture.compilation.entries.count)),
            "parameter_count": .integer(Int64(fixture.artifact.parameterCount)),
            "path": .string(path),
            "whole_file_size_bytes": .integer(Int64(fixture.artifact.data.count)),
            "whole_file_sha256": .string(fixture.artifact.wholeFileSHA256.hex),
            "payload_sha256": .string(fixture.artifact.payloadSHA256.hex),
            "header_crc32": .string(String(
                format: "0x%08X",
                ASHLUTTestSupportV3.uint32(fixture.artifact.data, at: 288)
            )),
            "payload_crc32": .string(String(
                format: "0x%08X",
                ASHLUTTestSupportV3.uint32(fixture.artifact.data, at: 292)
            ))
        ])
    }

    private static func fileBinding(
        path: String,
        data: Data
    ) -> ASHLUTStrictJSONValueV3 {
        .object([
            "path": .string(path),
            "sha256": .string(sha256(data).hex),
            "size_bytes": .integer(Int64(data.count))
        ])
    }

    private static func sha256(_ data: Data) -> ASHLUTHashV3 {
        ASHLUTHashV3(validatedBytes: Array(SHA256.hash(data: data)))
    }
}
