import Foundation
import XCTest
@testable import Mirmir

extension ASHCorrectiveCLITests {
    func test_lateReopenFailureRollsBackAllSeventeenOutputs() throws {
        let fixture = try Self.fixtureResult.get()
        var reopenCount = 0
        let session = try makeSession(fixture) { path in
            reopenCount += 1
            if reopenCount == 17 {
                throw InjectedFailure.lateReopen
            }
            return try ASHCalibrationCLIFileIO.readRegularFile(path)
        }
        let bundle = try requestBundle(
            fixture: fixture,
            route: .direct2x,
            suffix: "rollback"
        )
        XCTAssertThrowsError(try session.diagnoseCorrective(bundle.request)) { error in
            XCTAssertTrue(error is InjectedFailure)
        }
        XCTAssertEqual(reopenCount, 17)
        for path in bundle.outputPaths {
            XCTAssertFalse(FileManager.default.fileExists(atPath: path), path)
        }
    }

    func test_preexistingLateOutputIsPreservedAndNewOutputsRollback() throws {
        let fixture = try Self.fixtureResult.get()
        let session = try makeSession(fixture)
        let bundle = try requestBundle(
            fixture: fixture,
            route: .direct2x,
            suffix: "preexisting"
        )
        let protectedPath = bundle.outputPaths[15]
        let sentinel = Data("preexisting-user-data".utf8)
        try sentinel.write(
            to: URL(fileURLWithPath: protectedPath),
            options: .withoutOverwriting
        )
        XCTAssertThrowsError(try session.diagnoseCorrective(bundle.request))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: protectedPath)), sentinel)
        for path in bundle.outputPaths where path != protectedPath {
            XCTAssertFalse(FileManager.default.fileExists(atPath: path), path)
        }
    }

    func test_hashContractsHaveKnownDomainsVectorsAndFullGridMutationCoverage() throws {
        let fixture = try Self.fixtureResult.get()
        let session = try makeSession(fixture)
        XCTAssertEqual(
            ASHCalibrationCorrectiveHashContract.normalizedPlaneDomain,
            Data("MIRMIR-ASH-NORMALIZED-PLANE-F64-V1\0".utf8)
        )
        XCTAssertEqual(
            ASHCalibrationCorrectiveHashContract.analysisGridDomain,
            Data("MIRMIR-ASH-ANALYSIS-GRID-V3\0".utf8)
        )
        try assertSerializationRebindHashVectors(session)
        let knownPlane = ASHLockedReferencePlaneOutputV2(
            width: 2,
            height: 2,
            normalizedSamples: [0.0, 0.25, 0.5, 1.0]
        )
        let knownYHash = try session.correctiveNormalizedPlaneSHA256(
            knownPlane,
            channelTag: "Y\0"
        )
        XCTAssertEqual(
            knownYHash,
            "943b52f4bac69708bf9d60680283734bd9df71080032bbc0c2271df0ea035fa2"
        )
        XCTAssertNotEqual(
            knownYHash,
            try session.correctiveNormalizedPlaneSHA256(
                knownPlane,
                channelTag: "CB\0"
            )
        )

        let grid = try ASHAnalysisGridBuilderV2.build(
            luma: fixture.planes.luma,
            cb: fixture.planes.cb,
            cr: fixture.planes.cr,
            chromaSiting: .left,
            step: Int(
                fixture.configuration.routes.direct2x.analysisGridSourceStep
            ),
            boundary: fixture.configuration.boundaryMode,
            configuration: fixture.mapping.analyzerConfiguration
        )
        let originalHash = try session.correctiveAnalysisGridSHA256(grid)
        XCTAssertEqual(
            originalHash,
            "0cbde997c752b74e80cec9f744743410d4d381b2de44b9f5e6c705eec144be63"
        )
        let sidecarMutation = try replacingFirstCell(
            in: grid,
            mutateSidecar: true,
            mutateHysteresis: false
        )
        let hysteresisMutation = try replacingFirstCell(
            in: grid,
            mutateSidecar: false,
            mutateHysteresis: true
        )
        XCTAssertNotEqual(
            originalHash,
            try session.correctiveAnalysisGridSHA256(sidecarMutation)
        )
        XCTAssertNotEqual(
            originalHash,
            try session.correctiveAnalysisGridSHA256(hysteresisMutation)
        )
    }

    private func assertSerializationRebindHashVectors(
        _ session: ASHCalibrationNativeSession
    ) throws {
        let halfHalf = try ASHLUTLockedRouteSelectionV2(
            lumaCoordinatePolicy: .halfPixelCenter,
            chromaCoordinatePolicy: .halfPixelCenter,
            analysisGridSourceStep: 1
        )
        let sourceSource = try ASHLUTLockedRouteSelectionV2(
            lumaCoordinatePolicy: .sourceAlignedRational,
            chromaCoordinatePolicy: .sourceAlignedRational,
            analysisGridSourceStep: 1
        )
        let unchangedPreimage = serializationRebindPreimage(
            route: .direct2x,
            original: halfHalf,
            serialized: halfHalf
        )
        XCTAssertEqual(unchangedPreimage.count, 140)
        XCTAssertEqual(
            ASHCalibrationCLIHash.hex(unchangedPreimage),
            "3ed8c81f113cefbf598143404ab67012a2b5f5b046ef6d902a6713790ef68762"
        )
        XCTAssertEqual(
            session.correctiveSerializationRebindSHA256(
                route: .direct2x,
                original: halfHalf,
                serialized: halfHalf
            ),
            "3ed8c81f113cefbf598143404ab67012a2b5f5b046ef6d902a6713790ef68762"
        )
        let appliedPreimage = serializationRebindPreimage(
            route: .direct3Over2,
            original: sourceSource,
            serialized: halfHalf
        )
        XCTAssertEqual(appliedPreimage.count, 158)
        XCTAssertEqual(
            ASHCalibrationCLIHash.hex(appliedPreimage),
            "c04531c94bfb111dec57c6a5fa7c7a81ba615d7f2c4ba92a6fe1048d3c803a4a"
        )
        XCTAssertEqual(
            session.correctiveSerializationRebindSHA256(
                route: .direct3Over2,
                original: sourceSource,
                serialized: halfHalf
            ),
            "c04531c94bfb111dec57c6a5fa7c7a81ba615d7f2c4ba92a6fe1048d3c803a4a"
        )
    }
}

extension ASHCorrectiveCLITests {
    func assertResponse(
        _ response: [String: Any],
        request: ASHCalibrationCorrectiveDiagnosticRequest,
        fixture: Fixture,
        route: ASHSpatialRouteV2
    ) throws {
        try assertResponseIdentity(response, request: request, fixture: fixture, route: route)
        try assertResponseRuntime(response, fixture: fixture, route: route)
        try assertResponseOutputs(response, request: request, fixture: fixture)
    }

    func assertResponseIdentity(
        _ response: [String: Any],
        request: ASHCalibrationCorrectiveDiagnosticRequest,
        fixture: Fixture,
        route: ASHSpatialRouteV2
    ) throws {
        XCTAssertEqual(Set(response.keys), [
            "schema_version", "status", "split", "validation_accessed",
            "holdout_accessed", "selected_winner", "request_id", "target_route",
            "configuration_id", "compiler_inputs_sha256", "candidate_vector_sha256",
            "shared_bank_configuration_sha256", "mapping_sha256",
            "operator_bank_sha256", "metric_policy_sha256", "calibration_plan_sha256",
            "corpus_lock_bundle_sha256", "candidate_lut_runtime_manifest_sha256",
            "input_sha256", "coordinate_model_contract_file_sha256",
            "coordinate_oracle_matrix_sha256",
            "coordinate_experiment_dimensions_sha256", "output_plane_hash_contract",
            "normalized_plane_hash_contract", "analysis_grid_hash_contract",
            "analysis_grid_source_step", "analysis_cell_count", "analysis_grid_sha256",
            "generic_lut", "session_counters", "production_v2_reference", "cells",
            "native_invocation_proof", "risk_state"
        ])
        XCTAssertEqual(response["schema_version"] as? String, "1.0.0")
        XCTAssertEqual(
            response["status"] as? String,
            "development_diagnostic_no_selection"
        )
        XCTAssertEqual(response["split"] as? String, "development")
        XCTAssertEqual(response["validation_accessed"] as? Bool, false)
        XCTAssertEqual(response["holdout_accessed"] as? Bool, false)
        XCTAssertTrue(response["selected_winner"] is NSNull)
        XCTAssertEqual(response["request_id"] as? String, request.frame.requestID)
        XCTAssertEqual(response["target_route"] as? String, route.rawValue)
        XCTAssertEqual(
            response["configuration_id"] as? String,
            fixture.configuration.configurationID
        )
        XCTAssertEqual(
            response["compiler_inputs_sha256"] as? String,
            fixture.configuration.compilerInputsSHA256.hex
        )
        XCTAssertEqual(
            response["candidate_vector_sha256"] as? String,
            fixture.mapping.candidateVectorSHA256.hex
        )
        XCTAssertEqual(
            response["shared_bank_configuration_sha256"] as? String,
            fixture.mapping.sharedBankConfigurationSHA256.hex
        )
        XCTAssertEqual(
            response["mapping_sha256"] as? String,
            fixture.configuration.mappingSHA256.hex
        )
        XCTAssertEqual(
            response["operator_bank_sha256"] as? String,
            fixture.configuration.operatorBankSHA256.hex
        )
        XCTAssertEqual(
            response["candidate_lut_runtime_manifest_sha256"] as? String,
            fixture.manifest.manifestSHA256.hex
        )
        XCTAssertEqual(
            response["output_plane_hash_contract"] as? String,
            ASHCalibrationCorrectiveHashContract.outputPlaneID
        )
        XCTAssertEqual(
            response["normalized_plane_hash_contract"] as? String,
            ASHCalibrationCorrectiveHashContract.normalizedPlaneID
        )
        XCTAssertEqual(
            response["analysis_grid_hash_contract"] as? String,
            ASHCalibrationCorrectiveHashContract.analysisGridID
        )
    }

    func assertResponseRuntime(
        _ response: [String: Any],
        fixture: Fixture,
        route: ASHSpatialRouteV2
    ) throws {
        let counters = try XCTUnwrap(response["session_counters"] as? [String: Int])
        XCTAssertEqual(counters, [
            "input_decode_count": 1,
            "analysis_grid_build_count": 1,
            "generic_compile_count_for_route": 1,
            "generic_dispatch_count": 1,
            "plane_diagnostic_count": 4,
            "risk_diagnostic_count": 1,
            "production_v2_dispatch_count": 1,
            "output_write_count": 17,
            "output_reopen_count": 17
        ])
        let generic = try XCTUnwrap(response["generic_lut"] as? [String: Any])
        XCTAssertEqual(Set(generic.keys), [
            "whole_file_sha256", "payload_sha256", "entry_count", "parameter_count",
            "header_crc32", "payload_crc32", "offline_path_evaluation_count",
            "runtime_tree_generation_count", "maximum_operator_evaluations",
            "serialization_rebind_contract", "original_luma_coordinate_policy",
            "original_chroma_coordinate_policy", "serialized_luma_coordinate_policy",
            "serialized_chroma_coordinate_policy", "serialization_rebind_applied",
            "serialization_rebind_sha256"
        ])
        let entryCount = try XCTUnwrap(generic["entry_count"] as? Int)
        XCTAssertEqual(
            generic["offline_path_evaluation_count"] as? Int,
            entryCount * 81
        )
        XCTAssertEqual(generic["runtime_tree_generation_count"] as? Int, 0)
        XCTAssertGreaterThan(try XCTUnwrap(generic["parameter_count"] as? Int), 0)
        XCTAssertEqual(
            generic["serialization_rebind_contract"] as? String,
            ASHCalibrationCorrectiveHashContract.serializationRebindID
        )
        XCTAssertEqual(
            generic["original_luma_coordinate_policy"] as? String,
            fixture.configuration.routeSelection(for: route).lumaCoordinatePolicy.rawValue
        )
        XCTAssertEqual(
            generic["original_chroma_coordinate_policy"] as? String,
            fixture.configuration.routeSelection(for: route).chromaCoordinatePolicy.rawValue
        )
        XCTAssertEqual(
            generic["serialized_luma_coordinate_policy"] as? String,
            ASHSpatialCoordinatePolicyV2.halfPixelCenter.rawValue
        )
        XCTAssertEqual(
            generic["serialized_chroma_coordinate_policy"] as? String,
            ASHSpatialCoordinatePolicyV2.halfPixelCenter.rawValue
        )
        let originalSelection = fixture.configuration.routeSelection(for: route)
        let serializedSelection = try ASHLUTLockedRouteSelectionV2(
            lumaCoordinatePolicy: .halfPixelCenter,
            chromaCoordinatePolicy: .halfPixelCenter,
            analysisGridSourceStep: originalSelection.analysisGridSourceStep
        )
        XCTAssertEqual(
            generic["serialization_rebind_applied"] as? Bool,
            originalSelection != serializedSelection
        )
        XCTAssertEqual(
            generic["serialization_rebind_sha256"] as? String,
            ASHCalibrationCLIHash.hex(serializationRebindPreimage(
                route: route,
                original: originalSelection,
                serialized: serializedSelection
            ))
        )
        XCTAssertNotNil(
            (generic["header_crc32"] as? String)?.range(
                of: "^0x[0-9A-F]{8}$",
                options: .regularExpression
            )
        )
        XCTAssertNotNil(
            (generic["payload_crc32"] as? String)?.range(
                of: "^0x[0-9A-F]{8}$",
                options: .regularExpression
            )
        )
    }

    func assertResponseOutputs(
        _ response: [String: Any],
        request: ASHCalibrationCorrectiveDiagnosticRequest,
        fixture: Fixture
    ) throws {
        let proof = try XCTUnwrap(
            response["native_invocation_proof"] as? [String: Any]
        )
        XCTAssertEqual(Set(proof.keys), [
            "protocol", "process_id", "executable_sha256", "source_manifest_sha256"
        ])
        XCTAssertEqual(
            proof["protocol"] as? String,
            "serve-candidate/diagnose_corrective_frame-v1"
        )
        XCTAssertEqual(
            proof["executable_sha256"] as? String,
            fixture.manifest.executableSHA256.hex
        )
        XCTAssertEqual(
            proof["source_manifest_sha256"] as? String,
            fixture.manifest.sourceManifestSHA256.hex
        )
        XCTAssertEqual(proof["process_id"] as? Int, Int(getpid()))

        let cells = try XCTUnwrap(response["cells"] as? [[String: Any]])
        XCTAssertEqual(cells.count, 16)
        for (ordinal, cell) in cells.enumerated() {
            XCTAssertEqual(cell["ordinal"] as? Int, ordinal)
            XCTAssertEqual(
                cell["coordinate_cell_id"] as? String,
                ASHCalibrationCorrectiveDiagnosticRequest.coordinateCells[ordinal / 4]
            )
            XCTAssertEqual(
                cell["anisotropy_cell_id"] as? String,
                ASHCalibrationCorrectiveDiagnosticRequest.anisotropyCells[ordinal % 4]
            )
            let path = try XCTUnwrap(cell["output_path"] as? String)
            XCTAssertEqual(path, request.outputDescriptors[ordinal].outputPath)
            XCTAssertTrue(FileManager.default.fileExists(atPath: path))
            let planes = try XCTUnwrap(cell["planes"] as? [String: [String: Any]])
            XCTAssertEqual(Set(planes.keys), ["y", "cb", "cr"])
            for plane in planes.values {
                XCTAssertEqual(Set(plane.keys), [
                    "coordinate_policy", "anisotropy_strength_q12", "sample_count",
                    "output_plane_sha256", "normalized_plane_sha256",
                    "source_aligned_entry_flag_sample_count",
                    "source_aligned_sample_preservation_count", "numerical_fallback_count"
                ])
                XCTAssertEqual(
                    plane["source_aligned_entry_flag_sample_count"] as? Int,
                    0
                )
                XCTAssertEqual((plane["output_plane_sha256"] as? String)?.count, 64)
                XCTAssertEqual((plane["normalized_plane_sha256"] as? String)?.count, 64)
            }
        }
        let risk = try XCTUnwrap(response["risk_state"] as? [String: Any])
        XCTAssertEqual(
            risk["baseline_analysis_grid_sha256"] as? String,
            response["analysis_grid_sha256"] as? String
        )
        XCTAssertEqual((risk["cells"] as? [[String: Any]])?.count, 30)
    }

    func assertProductionParity(
        response: [String: Any],
        request: ASHCalibrationCorrectiveDiagnosticRequest,
        fixture: Fixture
    ) throws {
        let reference = try ASHLockedReferencePipelineV2.process(
            ASHLockedReferenceInputV2(
                luma: fixture.planes.luma,
                cb: fixture.planes.cb,
                cr: fixture.planes.cr,
                chromaSiting: .left,
                lut: try XCTUnwrap(fixture.routeLUTs[request.frame.route]),
                configuration: fixture.configuration,
                mapping: fixture.mapping
            )
        )
        let expected = try encodeNV12(reference)
        let production = try XCTUnwrap(
            response["production_v2_reference"] as? [String: Any]
        )
        XCTAssertEqual(
            Set(production.keys),
            [
                "output_path", "output_nv12_sha256", "output_frame_sha256", "planes",
                "lut_whole_file_sha256", "lut_payload_sha256", "lut_entry_count"
            ]
        )
        let path = try XCTUnwrap(production["output_path"] as? String)
        XCTAssertEqual(path, request.productionV2ReferenceOutputPath)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), expected)
        XCTAssertEqual(
            production["output_nv12_sha256"] as? String,
            ASHCalibrationCLIHash.hex(expected)
        )
        let planes = try XCTUnwrap(
            production["planes"] as? [String: [String: String]]
        )
        XCTAssertEqual(Set(planes.keys), ["y", "cb", "cr"])
        for plane in planes.values {
            XCTAssertEqual(Set(plane.keys), [
                "output_plane_sha256", "normalized_plane_sha256"
            ])
        }
    }

    func assertNormalizedAnisotropyIndependence(
        _ response: [String: Any]
    ) throws {
        let cells = try XCTUnwrap(response["cells"] as? [[String: Any]])
        for coordinateOffset in stride(from: 0, to: cells.count, by: 4) {
            let hashes = try cells[coordinateOffset..<(coordinateOffset + 4)].map { cell in
                let planes = try XCTUnwrap(
                    cell["planes"] as? [String: [String: Any]]
                )
                return try Dictionary(uniqueKeysWithValues: ["y", "cb", "cr"].map { channel in
                    (
                        channel,
                        try XCTUnwrap(
                            planes[channel]?["normalized_plane_sha256"] as? String
                        )
                    )
                })
            }
            XCTAssertEqual(hashes[1]["y"], hashes[0]["y"])
            XCTAssertEqual(hashes[1]["cb"], hashes[3]["cb"])
            XCTAssertEqual(hashes[1]["cr"], hashes[3]["cr"])
            XCTAssertEqual(hashes[2]["y"], hashes[3]["y"])
            XCTAssertEqual(hashes[2]["cb"], hashes[0]["cb"])
            XCTAssertEqual(hashes[2]["cr"], hashes[0]["cr"])
        }
    }

}
