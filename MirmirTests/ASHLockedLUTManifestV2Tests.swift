import CryptoKit
import Foundation
import XCTest
@testable import Mirmir

final class ASHLockedLUTManifestV2Tests: XCTestCase {
    func test_candidateManifestBindsBothRouteLUTsBeforeImmutableLoad() throws {
        let fixture = try makeManifestFixture()
        let manifest = try ASHLockedCandidateLUTManifestV1.load(
            fixture.manifestData,
            compilerInputData: fixture.compilerInputData,
            configuration: fixture.configuration
        )
        XCTAssertEqual(manifest.routes.map(\.route), ASHSpatialRouteV2.allCases)
        for route in ASHSpatialRouteV2.allCases {
            let manifestRoute = try manifest.route(route)
            let loaded = try ASHLUTBinaryCodecV2.load(
                fixture.data[route]!,
                manifestRoute: manifestRoute,
                configuration: fixture.configuration
            )
            XCTAssertEqual(loaded.route, route)
            XCTAssertEqual(loaded.wholeFileSHA256, manifestRoute.wholeFileSHA256)
            XCTAssertEqual(loaded.payloadSHA256, manifestRoute.payloadSHA256)
        }
    }

    func test_candidateManifestRejectsMissingWrongOrderAndSubstitutedRouteRows() throws {
        let fixture = try makeManifestFixture()
        var document = fixture.manifestDocument
        document["routes"] = [fixture.routeRows[0]]
        XCTAssertThrowsError(try load(document, fixture: fixture)) { error in
            XCTAssertEqual(error as? ASHLockedLUTManifestErrorV2, .routeOrderMismatch)
        }

        document = fixture.manifestDocument
        document["routes"] = Array(fixture.routeRows.reversed())
        XCTAssertThrowsError(try load(document, fixture: fixture)) { error in
            XCTAssertEqual(error as? ASHLockedLUTManifestErrorV2, .routeOrderMismatch)
        }

        var substituted = fixture.routeRows[0]
        substituted["whole_file_sha256"] = fixture.routeRows[1]["whole_file_sha256"]
        document = fixture.manifestDocument
        document["routes"] = [substituted, fixture.routeRows[1]]
        let manifest = try load(document, fixture: fixture)
        XCTAssertThrowsError(try ASHLUTBinaryCodecV2.load(
            fixture.data[.direct2x]!,
            manifestRoute: manifest.route(.direct2x),
            configuration: fixture.configuration
        )) { error in
            XCTAssertEqual(error as? ASHLockedLUTManifestErrorV2, .wholeFileHashMismatch)
        }
    }

    func test_manifestRejectsInternallyValidResealedLUTFromDifferentIdentity() throws {
        let fixture = try makeManifestFixture()
        let manifest = try ASHLockedCandidateLUTManifestV1.load(
            fixture.manifestData,
            compilerInputData: fixture.compilerInputData,
            configuration: fixture.configuration
        )
        let alternate = try ASHLockedRuntimeTestSupportV2.fixture(
            route: .direct2x,
            policy: .halfPixelCenter,
            step: 1
        )
        let alternateArtifact = try ASHLUTBinaryCodecV2.serialize(alternate.compilation)
        XCTAssertNoThrow(try ASHLUTBinaryCodecV2.load(
            alternateArtifact.data,
            expectedRoute: .direct2x,
            configuration: alternate.configuration
        ))
        XCTAssertThrowsError(try ASHLUTBinaryCodecV2.load(
            alternateArtifact.data,
            manifestRoute: manifest.route(.direct2x),
            configuration: fixture.configuration
        )) { error in
            XCTAssertEqual(error as? ASHLockedLUTManifestErrorV2, .wholeFileHashMismatch)
        }
    }

    private struct ManifestFixture {
        let configuration: ASHLUTLockedConfigurationV2
        let compilerInputData: Data
        let data: [ASHSpatialRouteV2: Data]
        let routeRows: [[String: Any]]
        let manifestDocument: [String: Any]
        let manifestData: Data
    }

    private func makeManifestFixture() throws -> ManifestFixture {
        let direct2x = try ASHLockedRuntimeTestSupportV2.lockedMappingFixture(.direct2x)
        let direct3Over2 = try ASHLockedRuntimeTestSupportV2.lockedMappingFixture(.direct3Over2)
        let configuration = direct2x.runtime.configuration
        XCTAssertEqual(configuration, direct3Over2.runtime.configuration)
        let compilerInputData = Data("strict-compiler-input-fixture".utf8)
        let routes = [direct2x.runtime.loaded, direct3Over2.runtime.loaded]
        let rows = routes.map { loaded -> [String: Any] in
            let route = loaded.route
            let selection = configuration.routeSelection(for: route)
            return [
                "analysis_grid_source_step": Int(selection.analysisGridSourceStep),
                "context_count": 4,
                "coordinate_policy": selection.coordinatePolicy.rawValue,
                "entry_count": loaded.entries.count,
                "header_crc32": crc32(loaded.immutableBytes, at: 288),
                "parameter_count": loaded.parameters.count,
                "path": route == .direct2x ? "direct2x.ashlut" : "direct3over2.ashlut",
                "payload_crc32": crc32(loaded.immutableBytes, at: 292),
                "payload_sha256": loaded.payloadSHA256.hex,
                "phase_count": route.phasePairCount,
                "route": route.rawValue,
                "route_id": route == .direct2x ? 1 : 2,
                "scale_denominator": route.scaleDenominator,
                "scale_numerator": route.scaleNumerator,
                "valid_state_count": 256,
                "whole_file_sha256": loaded.wholeFileSHA256.hex,
                "whole_file_size_bytes": loaded.immutableBytes.count
            ]
        }
        let hashes: [String: Any] = [
            "calibration_plan_sha256": configuration.calibrationPlanSHA256.hex,
            "compiler_inputs_sha256": configuration.compilerInputsSHA256.hex,
            "corpus_lock_bundle_sha256": configuration.corpusLockBundleSHA256.hex,
            "mapping_sha256": configuration.mappingSHA256.hex,
            "metric_policy_sha256": configuration.metricPolicySHA256.hex,
            "operator_bank_sha256": configuration.operatorBankSHA256.hex
        ]
        let document: [String: Any] = [
            "compiler_input": binding(
                path: "locked-compiler-input.json",
                data: compilerInputData
            ),
            "configuration_id": configuration.configurationID,
            "hash_bindings": hashes,
            "manifest_id": "mirmir-ash-candidate-route-luts-v1",
            "native_parity_claimed": false,
            "routes": rows,
            "schema_version": "1.0.0",
            "status": "calibration_candidate",
            "swift_cli": [
                "executable_sha256": String(repeating: "dd", count: 32),
                "source_manifest_sha256": String(repeating: "ee", count: 32)
            ]
        ]
        let manifestData = try encodedManifest(document)
        return ManifestFixture(
            configuration: configuration,
            compilerInputData: compilerInputData,
            data: Dictionary(uniqueKeysWithValues: routes.map { ($0.route, $0.immutableBytes) }),
            routeRows: rows,
            manifestDocument: document,
            manifestData: manifestData
        )
    }

    private func load(
        _ document: [String: Any],
        fixture: ManifestFixture
    ) throws -> ASHLockedCandidateLUTManifestV1 {
        try ASHLockedCandidateLUTManifestV1.load(
            encodedManifest(document),
            compilerInputData: fixture.compilerInputData,
            configuration: fixture.configuration
        )
    }

    private func encodedManifest(_ source: [String: Any]) throws -> Data {
        let input = try JSONSerialization.data(
            withJSONObject: source,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        var document = source
        document["manifest_sha256"] = SHA256.hash(data: input).map {
            String(format: "%02x", $0)
        }.joined()
        var result = try JSONSerialization.data(
            withJSONObject: document,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        result.append(0x0a)
        return result
    }

    private func binding(path: String, data: Data) -> [String: Any] {
        [
            "path": path,
            "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            "size_bytes": data.count
        ]
    }

    private func crc32(_ data: Data, at offset: Int) -> String {
        String(format: "0x%08X", ASHLUTTestSupportV2.uint32(data, at: offset))
    }
}
