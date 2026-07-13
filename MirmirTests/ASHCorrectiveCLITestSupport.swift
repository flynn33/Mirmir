import Foundation
import XCTest
@testable import Mirmir

extension ASHCorrectiveCLITests {
    func requestBundle(
        fixture: Fixture,
        route: ASHSpatialRouteV2,
        suffix: String
    ) throws -> RequestBundle {
        let document = try requestDocument(
            fixture: fixture,
            route: route,
            suffix: suffix
        )
        let request = try ASHCalibrationCorrectiveDiagnosticRequest.parse(
            canonicalData(document),
            configuration: fixture.configuration
        )
        return RequestBundle(
            document: document,
            request: request,
            outputPaths: request.outputDescriptors.map(\.outputPath)
                + [request.productionV2ReferenceOutputPath]
        )
    }

    func serializationRebindPreimage(
        route: ASHSpatialRouteV2,
        original: ASHSpatialCoordinatePolicyV2,
        serialized: ASHSpatialCoordinatePolicyV2
    ) -> Data {
        var data = Data(
            "MIRMIR-ASH-GENERIC-V3-DIAGNOSTIC-SERIALIZATION-REBIND-V1\0".utf8
        )
        data.append(Data(route.rawValue.utf8))
        data.append(0)
        data.append(Data(original.rawValue.utf8))
        data.append(0)
        data.append(Data(serialized.rawValue.utf8))
        data.append(0)
        data.append(original == serialized ? 0 : 1)
        return data
    }

    func requestDocument(
        fixture: Fixture,
        route: ASHSpatialRouteV2,
        suffix: String
    ) throws -> [String: Any] {
        let width = fixture.planes.luma.width
        let height = fixture.planes.luma.height
        let outputWidth = try route.destinationExtent(for: width)
        let outputHeight = try route.destinationExtent(for: height)
        let productionPath = temporaryRoot.appendingPathComponent(
            "\(suffix)-production.nv12"
        ).path
        var descriptors: [[String: Any]] = []
        for coordinate in ASHCalibrationCorrectiveDiagnosticRequest.coordinateCells {
            for anisotropy in ASHCalibrationCorrectiveDiagnosticRequest.anisotropyCells {
                let ordinal = descriptors.count
                descriptors.append([
                    "ordinal": ordinal,
                    "coordinate_cell_id": coordinate,
                    "anisotropy_cell_id": anisotropy,
                    "output_path": temporaryRoot.appendingPathComponent(
                        "\(suffix)-\(coordinate)-\(anisotropy).nv12"
                    ).path
                ])
            }
        }
        return [
            "schema_version": "1.0.0",
            "operation": "diagnose_corrective_frame",
            "configuration_id": fixture.configuration.configurationID,
            "compiler_inputs_sha256": fixture.configuration.compilerInputsSHA256.hex,
            "coordinate_model_contract_path": contractPath!,
            "coordinate_model_contract_sha256": ASHCalibrationCLIHash.hex(
                fixture.coordinateContractData
            ),
            "analysis_grid_source_step": Int(
                fixture.configuration.routeSelection(for: route).analysisGridSourceStep
            ),
            "output_descriptors": descriptors,
            "production_v2_reference_output_path": productionPath,
            "frame": [
                "request_id": "corrective-\(suffix)",
                "route": route == .direct2x ? "direct-2x" : "direct-3over2",
                "input_path": inputPath!,
                "input_sha256": ASHCalibrationCLIHash.hex(fixture.inputData),
                "input_width": width,
                "input_height": height,
                "output_path": productionPath,
                "output_width": outputWidth,
                "output_height": outputHeight,
                "pixel_format": "420v",
                "matrix": "BT.709",
                "range": "video",
                "chroma_siting": "left"
            ]
        ]
    }

    func makeSession(
        _ fixture: Fixture,
        reopener: ((String) throws -> Data)? = nil
    ) throws -> ASHCalibrationNativeSession {
        if let reopener {
            return try ASHCalibrationNativeSession(
                configuration: fixture.configuration,
                mapping: fixture.mapping,
                operatorBank: fixture.operatorBank,
                manifest: fixture.manifest,
                direct2xData: try XCTUnwrap(fixture.routeData[.direct2x]),
                direct3Over2Data: try XCTUnwrap(fixture.routeData[.direct3Over2]),
                correctiveOutputReopener: reopener
            )
        }
        return try ASHCalibrationNativeSession(
            configuration: fixture.configuration,
            mapping: fixture.mapping,
            operatorBank: fixture.operatorBank,
            manifest: fixture.manifest,
            direct2xData: try XCTUnwrap(fixture.routeData[.direct2x]),
            direct3Over2Data: try XCTUnwrap(fixture.routeData[.direct3Over2])
        )
    }

    func assertParseRejects(
        _ document: [String: Any],
        fixture: Fixture
    ) throws {
        XCTAssertThrowsError(try ASHCalibrationCorrectiveDiagnosticRequest.parse(
            canonicalData(document),
            configuration: fixture.configuration
        ))
    }

    func assertNoRequestedOutputs(_ document: [String: Any]) throws {
        let descriptors = try XCTUnwrap(
            document["output_descriptors"] as? [[String: Any]]
        )
        let paths = try descriptors.map {
            try XCTUnwrap($0["output_path"] as? String)
        } + [
            try XCTUnwrap(
                document["production_v2_reference_output_path"] as? String
            )
        ]
        for path in paths {
            XCTAssertFalse(FileManager.default.fileExists(atPath: path), path)
        }
    }

    func replacingFirstCell(
        in grid: ASHAnalysisGridV2,
        mutateSidecar: Bool,
        mutateHysteresis: Bool
    ) throws -> ASHAnalysisGridV2 {
        var cells = grid.cells
        let source = try XCTUnwrap(cells.first)
        let oldSidecar = source.analysis.sidecar
        let sidecar = ASHVideoAnalyzerV2Sidecar(
            inputRange: oldSidecar.inputRange,
            normalizedGradientMagnitude: oldSidecar.normalizedGradientMagnitude,
            structureCoherence: oldSidecar.structureCoherence,
            edgeNormalRadians: oldSidecar.edgeNormalRadians,
            edgeTangentRadians: oldSidecar.edgeTangentRadians,
            orientationSector: oldSidecar.orientationSector,
            textureEnergy: oldSidecar.textureEnergy,
            riskProxy: oldSidecar.riskProxy,
            localNoiseEstimate: oldSidecar.localNoiseEstimate,
            temporalConfidence: mutateSidecar ? 0.5 : oldSidecar.temporalConfidence,
            motionVectorQ8_8: oldSidecar.motionVectorQ8_8,
            chromaAlignment: oldSidecar.chromaAlignment,
            chromaEdgeConfidence: oldSidecar.chromaEdgeConfidence,
            localMinimumY: oldSidecar.localMinimumY,
            localMaximumY: oldSidecar.localMaximumY
        )
        let oldHysteresis = source.analysis.hysteresis
        let replacementEdge: ASHVideoAnalyzerV2HysteresisDecision =
            oldHysteresis.edgePresent == .heldSet ? .heldClear : .heldSet
        let hysteresis = ASHVideoAnalyzerV2HysteresisDiagnostics(
            edgePresent: mutateHysteresis
                ? replacementEdge : oldHysteresis.edgePresent,
            coherentStructure: oldHysteresis.coherentStructure,
            textureHighFrequency: oldHysteresis.textureHighFrequency,
            aliasOrRingingRisk: oldHysteresis.aliasOrRingingRisk,
            temporalSupportValid: oldHysteresis.temporalSupportValid,
            chromaLumaStructureAligned: oldHysteresis.chromaLumaStructureAligned
        )
        cells[0] = ASHAnalysisGridCellV2(
            column: source.column,
            row: source.row,
            originX: source.originX,
            originY: source.originY,
            actualWidth: source.actualWidth,
            actualHeight: source.actualHeight,
            centerX: source.centerX,
            centerY: source.centerY,
            analysis: ASHVideoAnalyzerV2Result(
                state: source.analysis.state,
                measurements: source.analysis.measurements,
                sidecar: sidecar,
                hysteresis: hysteresis
            )
        )
        return ASHAnalysisGridV2(
            sourceWidth: grid.sourceWidth,
            sourceHeight: grid.sourceHeight,
            step: grid.step,
            columnCount: grid.columnCount,
            rowCount: grid.rowCount,
            cells: cells
        )
    }

    func encodeNV12(_ output: ASHLockedReferenceOutputV2) throws -> Data {
        let cb = try ASHLockedCandidateAdapterBridgeV2.centeredChroma(output.cb)
        let cr = try ASHLockedCandidateAdapterBridgeV2.centeredChroma(output.cr)
        var data = Data()
        for value in output.luma.normalizedSamples {
            data.append(quantize(value * 219.0 + 16.0))
        }
        for index in cb.samples.indices {
            data.append(quantize((cb.samples[index] + 0.5) * 224.0 + 16.0))
            data.append(quantize((cr.samples[index] + 0.5) * 224.0 + 16.0))
        }
        return data
    }

    private func quantize(_ value: Double) -> UInt8 {
        UInt8(min(255.0, max(0.0, value.rounded(.toNearestOrEven))))
    }

    func canonicalData(_ document: [String: Any]) throws -> Data {
        try ASHCalibrationCLIJSON.canonicalData(document)
    }

    static func makeFixture() throws -> Fixture {
        let mappingFixture = try ASHLockedRuntimeTestSupportV2.lockedMappingFixture(
            .direct2x
        )
        let mapping = mappingFixture.mapping
        let base = mappingFixture.runtime.configuration
        let preliminaryOperatorData = try operatorBankData(
            configuration: base,
            mapping: mapping
        )
        let operatorHash = ASHCalibrationCLIHash.value(preliminaryOperatorData)
        let configuration = try ASHLUTLockedConfigurationV2(
            configurationID: base.configurationID,
            mappingSHA256: base.mappingSHA256,
            operatorBankSHA256: operatorHash,
            metricPolicySHA256: base.metricPolicySHA256,
            compilerInputsSHA256: base.compilerInputsSHA256,
            calibrationPlanSHA256: base.calibrationPlanSHA256,
            corpusLockBundleSHA256: base.corpusLockBundleSHA256,
            boundaryMode: base.boundaryMode,
            operatorParameters: base.operatorParameters,
            semanticSteps: base.semanticSteps,
            compilerPolicy: base.compilerPolicy,
            routes: base.routes
        )
        let operatorData = try operatorBankData(
            configuration: configuration,
            mapping: mapping
        )
        guard ASHCalibrationCLIHash.value(operatorData) == operatorHash else {
            throw ASHCalibrationCLIError.outputValidation(
                "test operator fixture hash changed"
            )
        }
        let operatorBank = try ASHLockedOperatorBankV2.load(
            operatorData,
            expectedSHA256: operatorHash,
            configuration: configuration
        )
        var routeData: [ASHSpatialRouteV2: Data] = [:]
        var routeLUTs: [ASHSpatialRouteV2: ASHLUTLoadedV2] = [:]
        for route in ASHSpatialRouteV2.allCases {
            let compilation = try ASHLUTLeafCompilerV2.compile(
                route: route,
                configuration: configuration
            )
            let artifact = try ASHLUTBinaryCodecV2.serialize(compilation)
            routeData[route] = artifact.data
            routeLUTs[route] = try ASHLUTBinaryCodecV2.load(
                artifact.data,
                expectedRoute: route,
                configuration: configuration
            )
        }
        let compilerInputData = Data("corrective-cli-test-compiler-input".utf8)
        let manifestData = try candidateManifestData(
            configuration: configuration,
            compilerInputData: compilerInputData,
            routeLUTs: routeLUTs
        )
        let manifest = try ASHLockedCandidateLUTManifestV1.load(
            manifestData,
            compilerInputData: compilerInputData,
            configuration: configuration
        )
        let planes = try ASHLockedRuntimeTestSupportV2.planes(width: 8, height: 8)
        let inputData = inputNV12(planes)
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let coordinateContractData = try Data(contentsOf: repositoryRoot
            .appendingPathComponent(
                "validation/calibration_v2/contracts/coordinate-model-contract-v3.json"
            ))
        return Fixture(
            configuration: configuration,
            mapping: mapping,
            operatorBank: operatorBank,
            manifest: manifest,
            routeData: routeData,
            routeLUTs: routeLUTs,
            planes: planes,
            inputData: inputData,
            coordinateContractData: coordinateContractData
        )
    }

    private static func operatorBankData(
        configuration: ASHLUTLockedConfigurationV2,
        mapping: ASHLockedVideoMappingV2
    ) throws -> Data {
        let parameters = configuration.operatorParameters
        let steps = configuration.semanticSteps
        return try ASHCalibrationCLIJSON.canonicalData([
            "schema_version": "1.0.0",
            "status": mapping.status.rawValue,
            "operator_bank_id": "ash-spatial-operator-bank-v2",
            "configuration_id": configuration.configurationID,
            "operator_bank_seed_sha256": String(repeating: "ab", count: 32),
            "candidate_vector_sha256": mapping.candidateVectorSHA256.hex,
            "shared_bank_configuration_sha256": mapping
                .sharedBankConfigurationSHA256.hex,
            "selection_binding": [
                "calibration_selection_sha256": NSNull(),
                "selected_evaluation_sha256": NSNull()
            ],
            "boundary_mode": configuration.boundaryMode == .clamp
                ? "clamp" : "mirror_reflect101",
            "coordinate_policies": [
                "direct_2x": configuration.routes.direct2x.coordinatePolicy.rawValue,
                "direct_3_over_2": configuration.routes.direct3Over2
                    .coordinatePolicy.rawValue
            ],
            "operator_parameters": [
                "anisotropy_strength_q12": Int(parameters.anisotropyStrengthQ12),
                "minimum_anisotropic_magnitude_unorm15": Int(
                    parameters.minimumAnisotropicMagnitudeUNorm15
                ),
                "minimum_anisotropic_coherence_unorm15": Int(
                    parameters.minimumAnisotropicCoherenceUNorm15
                ),
                "detail_gain_q12": Int(parameters.detailGainQ12),
                "relaxed_limiter_alpha_q12": Int(parameters.relaxedLimiterAlphaQ12),
                "risk_detail_suppression_unorm15": Int(parameters.riskSuppressionUNorm15),
                "low_pass_radius_q8_8": Int(parameters.lowPassRadiusQ8x8),
                "weight_epsilon_f32_bits": Int(parameters.weightEpsilonF32Bits)
            ],
            "semantic_steps": [
                "orientation_sector_step": Int(steps.orientationSectorStep),
                "support_radius_step_q8_8": Int(steps.supportRadiusStepQ8x8),
                "detail_gain_step_q12": Int(steps.detailGainStepQ12),
                "regularization_step_q12": Int(steps.regularizationStepQ12)
            ]
        ])
    }

    private static func candidateManifestData(
        configuration: ASHLUTLockedConfigurationV2,
        compilerInputData: Data,
        routeLUTs: [ASHSpatialRouteV2: ASHLUTLoadedV2]
    ) throws -> Data {
        let routes: [[String: Any]] = try ASHSpatialRouteV2.allCases.map { route in
            let loaded = try XCTUnwrap(routeLUTs[route])
            let selection = configuration.routeSelection(for: route)
            return [
                "analysis_grid_source_step": Int(selection.analysisGridSourceStep),
                "context_count": 4,
                "coordinate_policy": selection.coordinatePolicy.rawValue,
                "entry_count": loaded.entries.count,
                "header_crc32": String(
                    format: "0x%08X",
                    ASHLUTLittleEndianV2.uint32(loaded.immutableBytes, at: 288)
                ),
                "parameter_count": loaded.parameters.count,
                "path": route == .direct2x ? "direct2x.ashlut" : "direct3over2.ashlut",
                "payload_crc32": String(
                    format: "0x%08X",
                    ASHLUTLittleEndianV2.uint32(loaded.immutableBytes, at: 292)
                ),
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
        var document: [String: Any] = [
            "compiler_input": [
                "path": "locked-compiler-input.json",
                "sha256": ASHCalibrationCLIHash.hex(compilerInputData),
                "size_bytes": compilerInputData.count
            ],
            "configuration_id": configuration.configurationID,
            "hash_bindings": [
                "calibration_plan_sha256": configuration.calibrationPlanSHA256.hex,
                "compiler_inputs_sha256": configuration.compilerInputsSHA256.hex,
                "corpus_lock_bundle_sha256": configuration.corpusLockBundleSHA256.hex,
                "mapping_sha256": configuration.mappingSHA256.hex,
                "metric_policy_sha256": configuration.metricPolicySHA256.hex,
                "operator_bank_sha256": configuration.operatorBankSHA256.hex
            ],
            "manifest_id": "mirmir-ash-candidate-route-luts-v1",
            "native_parity_claimed": false,
            "routes": routes,
            "schema_version": "1.0.0",
            "status": "calibration_candidate",
            "swift_cli": [
                "executable_sha256": String(repeating: "dd", count: 32),
                "source_manifest_sha256": String(repeating: "ee", count: 32)
            ]
        ]
        document["manifest_sha256"] = ASHCalibrationCLIHash.hex(
            try ASHCalibrationCLIJSON.canonicalData(document)
        )
        var data = try ASHCalibrationCLIJSON.canonicalData(document)
        data.append(0x0a)
        return data
    }

    private static func inputNV12(
        _ planes: ASHLockedRuntimeTestSupportV2.Planes
    ) -> Data {
        var data = Data(planes.luma.codes)
        for index in planes.cb.codes.indices {
            data.append(planes.cb.codes[index])
            data.append(planes.cr.codes[index])
        }
        return data
    }
}
