import Foundation

#if canImport(Mirmir)
@testable import Mirmir
#endif

struct ASHCalibrationFrameRequest {
    let requestID: String
    let route: ASHSpatialRouteV2
    let inputPath: String
    let inputSHA256: String
    let inputWidth: Int
    let inputHeight: Int
    let outputPath: String
    let outputWidth: Int
    let outputHeight: Int
}

struct ASHCalibrationBatchRequest {
    let configurationID: String
    let compilerInputsSHA256: String
    let frames: [ASHCalibrationFrameRequest]

    static func parse(
        _ data: Data,
        configuration: ASHLUTLockedConfigurationV2
    ) throws -> ASHCalibrationBatchRequest {
        let json = ASHCalibrationCLIJSON.self
        let value = try json.strictCanonicalValue(data)
        let root = try json.object(value, keys: [
            "schema_version", "operation", "configuration_id",
            "compiler_inputs_sha256", "frames"
        ])
        guard try json.string(root["schema_version"]) == "1.0.0",
              try json.string(root["operation"]) == "process_batch" else {
            throw ASHCalibrationCLIError.invalidRequest("protocol identity mismatch")
        }
        let configurationID = try json.string(root["configuration_id"])
        let compilerInputsSHA256 = try json.string(root["compiler_inputs_sha256"])
        guard configurationID == configuration.configurationID,
              compilerInputsSHA256 == configuration.compilerInputsSHA256.hex else {
            throw ASHCalibrationCLIError.invalidRequest("configuration identity mismatch")
        }
        let frameValues = try json.array(root["frames"])
        guard !frameValues.isEmpty, frameValues.count <= 256 else {
            throw ASHCalibrationCLIError.invalidRequest("invalid batch size")
        }
        let frames = try frameValues.map(parseFrame)
        guard Set(frames.map(\.requestID)).count == frames.count,
              Set(frames.map(\.outputPath)).count == frames.count else {
            throw ASHCalibrationCLIError.invalidRequest("duplicate request ID or output path")
        }
        return ASHCalibrationBatchRequest(
            configurationID: configurationID,
            compilerInputsSHA256: compilerInputsSHA256,
            frames: frames
        )
    }

    static func parse(
        _ data: Data,
        configuration: ASHLUTLockedConfigurationV3
    ) throws -> ASHCalibrationBatchRequest {
        let json = ASHCalibrationCLIJSON.self
        let value = try json.strictCanonicalValue(data)
        let root = try json.object(value, keys: [
            "schema_version", "operation", "configuration_id",
            "compiler_inputs_sha256", "frames"
        ])
        guard try json.string(root["schema_version"]) == "1.0.0",
              try json.string(root["operation"]) == "process_batch" else {
            throw ASHCalibrationCLIError.invalidRequest("protocol identity mismatch")
        }
        let configurationID = try json.string(root["configuration_id"])
        let compilerInputsSHA256 = try json.string(root["compiler_inputs_sha256"])
        guard configurationID == configuration.configurationID,
              compilerInputsSHA256 == configuration.compilerInputsSHA256.hex else {
            throw ASHCalibrationCLIError.invalidRequest("configuration identity mismatch")
        }
        let frameValues = try json.array(root["frames"])
        guard !frameValues.isEmpty, frameValues.count <= 256 else {
            throw ASHCalibrationCLIError.invalidRequest("invalid batch size")
        }
        let frames = try frameValues.map(parseFrame)
        guard Set(frames.map(\.requestID)).count == frames.count,
              Set(frames.map(\.outputPath)).count == frames.count else {
            throw ASHCalibrationCLIError.invalidRequest("duplicate request ID or output path")
        }
        return ASHCalibrationBatchRequest(
            configurationID: configurationID,
            compilerInputsSHA256: compilerInputsSHA256,
            frames: frames
        )
    }

    static func parseFrame(
        _ value: ASHLUTStrictJSONValueV2
    ) throws -> ASHCalibrationFrameRequest {
        let json = ASHCalibrationCLIJSON.self
        let fields = try json.object(value, keys: [
            "request_id", "route", "input_path", "input_sha256", "input_width",
            "input_height", "output_path", "output_width", "output_height",
            "pixel_format", "matrix", "range", "chroma_siting"
        ])
        guard try json.string(fields["pixel_format"]) == "420v",
              try json.string(fields["matrix"]) == "BT.709",
              try json.string(fields["range"]) == "video",
              try json.string(fields["chroma_siting"]) == "left" else {
            throw ASHCalibrationCLIError.unsupported("pixel/color/chroma contract")
        }
        let route: ASHSpatialRouteV2
        switch try json.string(fields["route"]) {
        case "direct-2x": route = .direct2x
        case "direct-3over2": route = .direct3Over2
        default: throw ASHCalibrationCLIError.unsupported("route")
        }
        let inputWidth = try json.integer(fields["input_width"])
        let inputHeight = try json.integer(fields["input_height"])
        let outputWidth = try json.integer(fields["output_width"])
        let outputHeight = try json.integer(fields["output_height"])
        guard inputWidth > 0,
              inputHeight > 0,
              inputWidth.isMultiple(of: 2),
              inputHeight.isMultiple(of: 2),
              outputWidth == (try route.destinationExtent(for: inputWidth)),
              outputHeight == (try route.destinationExtent(for: inputHeight)),
              outputWidth.isMultiple(of: 2),
              outputHeight.isMultiple(of: 2),
              try route.destinationExtent(for: inputWidth / 2) == outputWidth / 2,
              try route.destinationExtent(for: inputHeight / 2) == outputHeight / 2 else {
            throw ASHCalibrationCLIError.unsupported("route geometry")
        }
        let requestID = try json.string(fields["request_id"])
        let inputSHA256 = try json.string(fields["input_sha256"])
        guard !requestID.isEmpty,
              requestID.count <= 128,
              inputSHA256.count == 64,
              inputSHA256.allSatisfy({ $0.isNumber || ("a"..."f").contains(String($0)) }) else {
            throw ASHCalibrationCLIError.invalidRequest("request ID or input hash")
        }
        return ASHCalibrationFrameRequest(
            requestID: requestID,
            route: route,
            inputPath: try json.string(fields["input_path"]),
            inputSHA256: inputSHA256,
            inputWidth: inputWidth,
            inputHeight: inputHeight,
            outputPath: try json.string(fields["output_path"]),
            outputWidth: outputWidth,
            outputHeight: outputHeight
        )
    }
}

struct ASHCalibrationCorrectiveOutputDescriptor {
    let ordinal: Int
    let coordinateCellID: String
    let anisotropyCellID: String
    let outputPath: String
}

enum ASHCalibrationCorrectiveHashContract {
    static let outputPlaneID = "active-nv12-code-bytes-sha256-v1"
    static let normalizedPlaneID = "mirmir-ash-normalized-plane-f64-be-v1"
    static let normalizedPlaneDomain = Data(
        "MIRMIR-ASH-NORMALIZED-PLANE-F64-V1\0".utf8
    )
    static let analysisGridID = "mirmir-ash-analysis-grid-v3-be-v1"
    static let analysisGridDomain = Data("MIRMIR-ASH-ANALYSIS-GRID-V3\0".utf8)
    static let serializationRebindID =
        "mirmir-ash-generic-v3-diagnostic-coordinate-policy-rebind-v1"
    static let serializationRebindDomain = Data(
        "MIRMIR-ASH-GENERIC-V3-DIAGNOSTIC-SERIALIZATION-REBIND-V1\0".utf8
    )
}

struct ASHCalibrationCorrectiveDiagnosticRequest {
    static let coordinateCells = ["HH", "HS", "SH", "SS"]
    static let anisotropyCells = ["00", "03", "30", "33"]

    let configurationID: String
    let compilerInputsSHA256: String
    let coordinateModelContractPath: String
    let coordinateModelContractSHA256: String
    let analysisGridSourceStep: Int
    let outputDescriptors: [ASHCalibrationCorrectiveOutputDescriptor]
    let productionV2ReferenceOutputPath: String
    let frame: ASHCalibrationFrameRequest

    static func parse(
        _ data: Data,
        configuration: ASHLUTLockedConfigurationV2
    ) throws -> ASHCalibrationCorrectiveDiagnosticRequest {
        let json = ASHCalibrationCLIJSON.self
        let root = try json.object(try json.strictCanonicalValue(data), keys: [
            "schema_version", "operation", "configuration_id",
            "compiler_inputs_sha256", "coordinate_model_contract_path",
            "coordinate_model_contract_sha256", "analysis_grid_source_step",
            "output_descriptors", "production_v2_reference_output_path", "frame"
        ])
        guard try json.string(root["schema_version"]) == "1.0.0",
              try json.string(root["operation"]) == "diagnose_corrective_frame" else {
            throw ASHCalibrationCLIError.invalidRequest(
                "corrective diagnostic protocol identity"
            )
        }
        let configurationID = try json.string(root["configuration_id"])
        let compilerInputsSHA256 = try json.string(root["compiler_inputs_sha256"])
        guard configurationID == configuration.configurationID,
              compilerInputsSHA256 == configuration.compilerInputsSHA256.hex else {
            throw ASHCalibrationCLIError.invalidRequest(
                "corrective diagnostic configuration identity"
            )
        }
        let contractPath = try json.string(root["coordinate_model_contract_path"])
        let contractSHA256 = try json.string(root["coordinate_model_contract_sha256"])
        guard isSHA256(contractSHA256), isLexicallySafeAbsolutePath(contractPath) else {
            throw ASHCalibrationCLIError.invalidRequest(
                "corrective diagnostic coordinate contract binding"
            )
        }
        let step = try json.integer(root["analysis_grid_source_step"])
        let frame = try ASHCalibrationBatchRequest.parseFrame(root["frame"]!)
        guard step == Int(
            configuration.routeSelection(for: frame.route).analysisGridSourceStep
        ) else {
            throw ASHCalibrationCLIError.invalidRequest(
                "corrective diagnostic analysis step"
            )
        }
        let productionOutputPath = try json.string(
            root["production_v2_reference_output_path"]
        )
        guard productionOutputPath == frame.outputPath,
              isLexicallySafeAbsolutePath(frame.inputPath),
              isLexicallySafeAbsolutePath(productionOutputPath) else {
            throw ASHCalibrationCLIError.invalidRequest(
                "corrective diagnostic production output identity"
            )
        }

        let descriptorValues = try json.array(root["output_descriptors"])
        guard descriptorValues.count
                == coordinateCells.count * anisotropyCells.count else {
            throw ASHCalibrationCLIError.invalidRequest(
                "corrective diagnostic output descriptor cardinality"
            )
        }
        var descriptors: [ASHCalibrationCorrectiveOutputDescriptor] = []
        descriptors.reserveCapacity(descriptorValues.count)
        for (ordinal, value) in descriptorValues.enumerated() {
            let fields = try json.object(value, keys: [
                "ordinal", "coordinate_cell_id", "anisotropy_cell_id", "output_path"
            ])
            let expectedCoordinate = coordinateCells[ordinal / anisotropyCells.count]
            let expectedAnisotropy = anisotropyCells[ordinal % anisotropyCells.count]
            let outputPath = try json.string(fields["output_path"])
            guard try json.integer(fields["ordinal"]) == ordinal,
                  try json.string(fields["coordinate_cell_id"]) == expectedCoordinate,
                  try json.string(fields["anisotropy_cell_id"]) == expectedAnisotropy,
                  isLexicallySafeAbsolutePath(outputPath) else {
                throw ASHCalibrationCLIError.invalidRequest(
                    "corrective diagnostic output descriptor order or identity"
                )
            }
            descriptors.append(ASHCalibrationCorrectiveOutputDescriptor(
                ordinal: ordinal,
                coordinateCellID: expectedCoordinate,
                anisotropyCellID: expectedAnisotropy,
                outputPath: outputPath
            ))
        }
        let outputPaths = descriptors.map(\.outputPath) + [productionOutputPath]
        guard Set(outputPaths).count == outputPaths.count,
              !outputPaths.contains(frame.inputPath),
              !outputPaths.contains(contractPath) else {
            throw ASHCalibrationCLIError.invalidRequest(
                "corrective diagnostic output paths are not unique"
            )
        }
        return ASHCalibrationCorrectiveDiagnosticRequest(
            configurationID: configurationID,
            compilerInputsSHA256: compilerInputsSHA256,
            coordinateModelContractPath: contractPath,
            coordinateModelContractSHA256: contractSHA256,
            analysisGridSourceStep: step,
            outputDescriptors: descriptors,
            productionV2ReferenceOutputPath: productionOutputPath,
            frame: frame
        )
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy {
            $0.isNumber || ("a"..."f").contains(String($0))
        }
    }

    private static func isLexicallySafeAbsolutePath(_ path: String) -> Bool {
        path.hasPrefix("/")
            && path.count > 1
            && !path.contains("\0")
            && !path.contains("//")
            && !(path as NSString).pathComponents.contains(".")
            && !(path as NSString).pathComponents.contains("..")
    }
}

struct ASHCalibrationMeasurementRequest {
    let configurationID: String
    let compilerInputsSHA256: String
    let frame: ASHCalibrationFrameRequest

    static func parse(
        _ data: Data,
        configuration: ASHLUTLockedConfigurationV2
    ) throws -> ASHCalibrationMeasurementRequest {
        let json = ASHCalibrationCLIJSON.self
        let value = try json.strictCanonicalValue(data)
        let root = try json.object(value, keys: [
            "schema_version", "operation", "configuration_id",
            "compiler_inputs_sha256", "frame", "warmup_repetitions",
            "measured_repetitions"
        ])
        guard try json.string(root["schema_version"]) == "1.0.0",
              try json.string(root["operation"]) == "measure_dispatch_projection",
              try json.integer(root["warmup_repetitions"]) == 3,
              try json.integer(root["measured_repetitions"]) == 10 else {
            throw ASHCalibrationCLIError.invalidRequest("measurement policy mismatch")
        }
        let configurationID = try json.string(root["configuration_id"])
        let compilerInputsSHA256 = try json.string(root["compiler_inputs_sha256"])
        guard configurationID == configuration.configurationID,
              compilerInputsSHA256 == configuration.compilerInputsSHA256.hex else {
            throw ASHCalibrationCLIError.invalidRequest("configuration identity mismatch")
        }
        guard let frameValue = root["frame"] else {
            throw ASHCalibrationCLIError.invalidRequest("measurement frame absent")
        }
        return ASHCalibrationMeasurementRequest(
            configurationID: configurationID,
            compilerInputsSHA256: compilerInputsSHA256,
            frame: try ASHCalibrationBatchRequest.parseFrame(frameValue)
        )
    }
}

enum ASHCalibrationControlMode {
    case fullASH
    case fixedDescriptor(UInt8)
    case conventional(ASHLockedConventionalAlgorithmV2)
    case nonASH(ASHLockedNonASHRuleV2)
    case stateOnly
    case h07
    case nearest
}

struct ASHCalibrationControlRequest {
    let controlKey: String
    let controlMode: String
    let requestSHA256: String
    let configurationSHA256: String
    let sharedBankConfigurationSHA256: String
    let mode: ASHCalibrationControlMode
    let frame: ASHCalibrationFrameRequest

    static func parse(
        _ data: Data,
        configuration: ASHLUTLockedConfigurationV2,
        mapping: ASHLockedVideoMappingV2
    ) throws -> ASHCalibrationControlRequest {
        guard mapping.configurationID == configuration.configurationID else {
            throw ASHCalibrationCLIError.invalidRequest(
                "control configuration identity"
            )
        }
        return try parse(
            data,
            mapping: mapping,
            selectorID: "continuous-linear-bank-selector-q15-v1"
        )
    }

    static func parse(
        _ data: Data,
        configuration: ASHLUTLockedConfigurationV3,
        mapping: ASHLockedVideoMappingV2
    ) throws -> ASHCalibrationControlRequest {
        guard mapping.configurationID == configuration.configurationID else {
            throw ASHCalibrationCLIError.invalidRequest(
                "format-1.2 control configuration identity"
            )
        }
        return try parse(
            data,
            mapping: mapping,
            selectorID: "continuous-linear-bank-selector-q15-v2"
        )
    }

    private static func parse(
        _ data: Data,
        mapping: ASHLockedVideoMappingV2,
        selectorID: String
    ) throws -> ASHCalibrationControlRequest {
        let json = ASHCalibrationCLIJSON.self
        let value = try json.strictCanonicalValue(data)
        let root = try json.object(value, keys: [
            "schema_version", "operation", "control_request", "frame"
        ])
        guard try json.string(root["schema_version"]) == "1.0.0",
              try json.string(root["operation"]) == "reconstruct_control" else {
            throw ASHCalibrationCLIError.invalidRequest("control protocol identity")
        }
        let rawControl = try json.object(root["control_request"], keys: [
            "schema_version", "operation", "control_key", "control_mode",
            "configuration_sha256", "shared_bank_configuration_sha256",
            "parameters", "request_sha256"
        ])
        guard try json.string(rawControl["schema_version"]) == "1.0.0",
              try json.string(rawControl["operation"]) == "reconstruct_control" else {
            throw ASHCalibrationCLIError.invalidRequest("nested control identity")
        }
        var unhashed = rawControl
        let declaredRequestSHA256 = try json.string(unhashed.removeValue(forKey: "request_sha256"))
        guard ASHCalibrationCLIHash.hex(
            ASHLUTCanonicalJSONV2.encode(.object(unhashed))
        ) == declaredRequestSHA256 else {
            throw ASHCalibrationCLIError.hashMismatch("control request")
        }
        let sharedBank = try json.string(rawControl["shared_bank_configuration_sha256"])
        guard sharedBank == mapping.sharedBankConfigurationSHA256.hex else {
            throw ASHCalibrationCLIError.hashMismatch("control shared bank")
        }
        let controlKey = try json.string(rawControl["control_key"])
        let controlMode = try json.string(rawControl["control_mode"])
        let configurationSHA256 = try json.string(rawControl["configuration_sha256"])
        let parameters = try parameterObject(rawControl["parameters"])
        let mode = try parseMode(
            controlKey: controlKey,
            controlMode: controlMode,
            configurationSHA256: configurationSHA256,
            sharedBank: sharedBank,
            parameters: parameters,
            candidateVectorSHA256: mapping.candidateVectorSHA256.hex,
            selectorID: selectorID
        )
        let frame = try ASHCalibrationBatchRequest.parseFrame(root["frame"]!)
        if case .h07 = mode, frame.route != .direct3Over2 {
            throw ASHCalibrationCLIError.unsupported("H07 requires direct-3over2")
        }
        return ASHCalibrationControlRequest(
            controlKey: controlKey,
            controlMode: controlMode,
            requestSHA256: declaredRequestSHA256,
            configurationSHA256: configurationSHA256,
            sharedBankConfigurationSHA256: sharedBank,
            mode: mode,
            frame: frame
        )
    }

    private static func parseMode(
        controlKey: String,
        controlMode: String,
        configurationSHA256: String,
        sharedBank: String,
        parameters: [String: ASHLUTStrictJSONValueV2],
        candidateVectorSHA256: String,
        selectorID: String
    ) throws -> ASHCalibrationControlMode {
        let json = ASHCalibrationCLIJSON.self
        let expectedConfiguration: ASHLUTStrictJSONValueV2
        let mode: ASHCalibrationControlMode
        switch controlMode {
        case "full_ash":
            guard Set(parameters.keys) == ["control_id", "candidate_vector_sha256"],
                  try json.string(parameters["control_id"])
                    == "ash-state-plus-branch-compiler-v1",
                  try json.string(parameters["candidate_vector_sha256"])
                    == candidateVectorSHA256,
                  controlKey == "full_ash" else {
                throw ASHCalibrationCLIError.invalidRequest("full ASH identity")
            }
            _ = try ASHLUTHashV2(hex: configurationSHA256)
            expectedConfiguration = .null
            mode = .fullASH
        case "fixed_descriptor_uniform":
            guard Set(parameters.keys) == ["descriptor_id"] else {
                throw ASHCalibrationCLIError.invalidRequest("fixed parameters")
            }
            let descriptor = try json.integer(parameters["descriptor_id"])
            guard (0..<ASHSpatialDescriptorV2.count).contains(descriptor),
                  controlKey == String(format: "fixed_descriptor_%02d", descriptor) else {
                throw ASHCalibrationCLIError.invalidRequest("fixed identity")
            }
            expectedConfiguration = .object([
                "control_id": .string("fixed-descriptor-uniform-v1"),
                "descriptor_id": .integer(Int64(descriptor)),
                "shared_bank_configuration_sha256": .string(sharedBank)
            ])
            mode = .fixedDescriptor(UInt8(descriptor))
        case "conventional_uniform":
            guard Set(parameters.keys) == ["algorithm_id"] else {
                throw ASHCalibrationCLIError.invalidRequest("conventional parameters")
            }
            let algorithmID = try json.string(parameters["algorithm_id"])
            guard let algorithm = ASHLockedConventionalAlgorithmV2(rawValue: algorithmID),
                  controlKey == "conventional_\(ASHLockedConventionalAlgorithmV2.allCases.firstIndex(of: algorithm)!)" else {
                throw ASHCalibrationCLIError.invalidRequest("conventional identity")
            }
            expectedConfiguration = .object([
                "algorithm_id": .string(algorithmID),
                "control_id": .string("uniform-conventional-selection-v1"),
                "shared_bank_configuration_sha256": .string(sharedBank)
            ])
            mode = .conventional(algorithm)
        case "non_ash_selector_q15":
            guard Set(parameters.keys) == [
                "selector_id", "selected_rule_sha256", "selected_rule_configuration"
            ],
            try json.string(parameters["selector_id"]) == selectorID,
            controlKey == "non_ash_selector" else {
                throw ASHCalibrationCLIError.invalidRequest("non-ASH identity")
            }
            let ruleObject = try parameterObject(parameters["selected_rule_configuration"])
            guard Set(ruleObject.keys) == Set(ASHLockedNonASHRuleV2.coordinateOrder) else {
                throw ASHCalibrationCLIError.invalidRequest("non-ASH rule fields")
            }
            let ruleSHA256 = ASHCalibrationCLIHash.hex(
                ASHLUTCanonicalJSONV2.encode(.object(ruleObject))
            )
            guard try json.string(parameters["selected_rule_sha256"]) == ruleSHA256 else {
                throw ASHCalibrationCLIError.hashMismatch("non-ASH rule")
            }
            var coordinates: [String: Int] = [:]
            for name in ASHLockedNonASHRuleV2.coordinateOrder {
                coordinates[name] = try json.integer(ruleObject[name])
            }
            expectedConfiguration = .object([
                "rule_sha256": .string(ruleSHA256),
                "selector_id": .string(selectorID),
                "shared_bank_configuration_sha256": .string(sharedBank)
            ])
            mode = .nonASH(try ASHLockedNonASHRuleV2(coordinates: coordinates))
        case "state_only":
            guard Set(parameters.keys) == ["control_id", "candidate_vector_sha256"],
                  try json.string(parameters["control_id"])
                    == "ash-state-only-base-descriptor-v1",
                  try json.string(parameters["candidate_vector_sha256"])
                    == candidateVectorSHA256,
                  controlKey == "state_only" else {
                throw ASHCalibrationCLIError.invalidRequest("state-only identity")
            }
            expectedConfiguration = .object(parameters)
            mode = .stateOnly
        case "h07_direct2x_then_lanczos3":
            guard Set(parameters.keys) == [
                "experiment_id", "direct_id", "control_id",
                "candidate_adapter_configuration_sha256"
            ],
            try json.string(parameters["experiment_id"]) == "H07",
            try json.string(parameters["direct_id"]) == "direct3over2-locked-route-v1",
            try json.string(parameters["control_id"])
                == "direct2x-then-lanczos3-control-v1",
            controlKey == "h07_direct_3_over_2" else {
                throw ASHCalibrationCLIError.invalidRequest("H07 identity")
            }
            expectedConfiguration = .object([
                "candidate_adapter_configuration_sha256": parameters[
                    "candidate_adapter_configuration_sha256"
                ]!,
                "control_id": .string("direct2x-then-lanczos3-control-v1")
            ])
            mode = .h07
        case "nearest_uniform":
            guard Set(parameters.keys) == ["control_id"],
                  try json.string(parameters["control_id"])
                    == "nearest-same-writer-420v-v1",
                  controlKey == "nearest_same_writer" else {
                throw ASHCalibrationCLIError.invalidRequest("nearest identity")
            }
            expectedConfiguration = .object([
                "control_id": .string("nearest-same-writer-420v-v1"),
                "shared_bank_configuration_sha256": .string(sharedBank)
            ])
            mode = .nearest
        case "p00_current_production_ash":
            throw ASHCalibrationCLIError.unsupported("P00 uses isolated helper")
        default:
            throw ASHCalibrationCLIError.unsupported("control mode")
        }
        if case .fullASH = mode { return mode }
        guard ASHCalibrationCLIHash.hex(
            ASHLUTCanonicalJSONV2.encode(expectedConfiguration)
        ) == configurationSHA256 else {
            throw ASHCalibrationCLIError.hashMismatch("control configuration")
        }
        return mode
    }

    private static func parameterObject(
        _ value: ASHLUTStrictJSONValueV2?
    ) throws -> [String: ASHLUTStrictJSONValueV2] {
        guard case .object(let object)? = value else {
            throw ASHCalibrationCLIError.invalidRequest("parameters object expected")
        }
        return object
    }

}

struct ASHCalibrationNonASHCachePrepareRequest {
    let sourceAssetID: String
    let degradationProfileID: String?
    let degradationProfileSHA256: String?
    let inputFrameSHA256: String
    let cacheArtifactPath: String
    let frame: ASHCalibrationFrameRequest

    static func parse(
        _ data: Data,
        configuration: ASHLUTLockedConfigurationV2,
        mapping: ASHLockedVideoMappingV2
    ) throws -> ASHCalibrationNonASHCachePrepareRequest {
        let json = ASHCalibrationCLIJSON.self
        let root = try json.object(try json.strictCanonicalValue(data), keys: [
            "schema_version", "operation", "configuration_id",
            "shared_bank_configuration_sha256", "source_asset_id",
            "degradation_profile_id", "degradation_profile_sha256",
            "input_frame_sha256", "cache_artifact_path", "frame"
        ])
        guard try json.string(root["schema_version"]) == "1.0.0",
              try json.string(root["operation"]) == "prepare_non_ash_cache",
              try json.string(root["configuration_id"])
                == configuration.configurationID,
              try json.string(root["shared_bank_configuration_sha256"])
                == mapping.sharedBankConfigurationSHA256.hex else {
            throw ASHCalibrationCLIError.invalidRequest("non-ASH cache identity")
        }
        let sourceAssetID = try json.string(root["source_asset_id"])
        let inputFrameSHA256 = try json.string(root["input_frame_sha256"])
        guard !sourceAssetID.isEmpty,
              sourceAssetID.count <= 1_024,
              isSHA256(inputFrameSHA256) else {
            throw ASHCalibrationCLIError.invalidRequest("non-ASH cache source identity")
        }
        let degradationProfileID: String?
        let degradationProfileSHA256: String?
        switch root["degradation_profile_id"] {
        case .null?: degradationProfileID = nil
        case .string(let value)?: degradationProfileID = value
        default:
            throw ASHCalibrationCLIError.invalidRequest("degradation profile ID")
        }
        switch root["degradation_profile_sha256"] {
        case .null?: degradationProfileSHA256 = nil
        case .string(let value)?: degradationProfileSHA256 = value
        default:
            throw ASHCalibrationCLIError.invalidRequest("degradation profile hash")
        }
        guard (degradationProfileID == nil) == (degradationProfileSHA256 == nil),
              degradationProfileID?.isEmpty != true,
              (degradationProfileID?.count ?? 0) <= 1_024,
              degradationProfileSHA256.map(isSHA256) ?? true else {
            throw ASHCalibrationCLIError.invalidRequest("degradation profile binding")
        }
        guard let frameValue = root["frame"] else {
            throw ASHCalibrationCLIError.invalidRequest("non-ASH cache frame")
        }
        return ASHCalibrationNonASHCachePrepareRequest(
            sourceAssetID: sourceAssetID,
            degradationProfileID: degradationProfileID,
            degradationProfileSHA256: degradationProfileSHA256,
            inputFrameSHA256: inputFrameSHA256,
            cacheArtifactPath: try json.string(root["cache_artifact_path"]),
            frame: try ASHCalibrationBatchRequest.parseFrame(frameValue)
        )
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy {
            $0.isNumber || ("a"..."f").contains(String($0))
        }
    }
}

struct ASHCalibrationNonASHCacheImportRequest {
    let cacheToken: String
    let cacheManifest: [String: Any]
    let artifactPath: String
    let artifactSHA256: String

    static func parse(
        _ data: Data,
        configuration: ASHLUTLockedConfigurationV2,
        mapping: ASHLockedVideoMappingV2
    ) throws -> ASHCalibrationNonASHCacheImportRequest {
        let json = ASHCalibrationCLIJSON.self
        let root = try json.object(try json.strictCanonicalValue(data), keys: [
            "schema_version", "operation", "configuration_id",
            "shared_bank_configuration_sha256", "cache_token", "cache_manifest",
            "cache_artifact_path", "cache_artifact_sha256"
        ])
        let token = try json.string(root["cache_token"])
        let artifactSHA256 = try json.string(root["cache_artifact_sha256"])
        guard try json.string(root["schema_version"]) == "1.0.0",
              try json.string(root["operation"]) == "import_non_ash_cache",
              try json.string(root["configuration_id"])
                == configuration.configurationID,
              try json.string(root["shared_bank_configuration_sha256"])
                == mapping.sharedBankConfigurationSHA256.hex,
              isSHA256(token),
              isSHA256(artifactSHA256),
              case .object(let rawManifest)? = root["cache_manifest"],
              ASHCalibrationCLIHash.hex(
                ASHLUTCanonicalJSONV2.encode(.object(
                    rawManifest.filter { $0.key != "cache_manifest_sha256" }
                ))
              ) == token else {
            throw ASHCalibrationCLIError.invalidRequest("imported cache identity")
        }
        let fields = try json.object(root["cache_manifest"], keys: [
            "schema_version", "artifact_kind", "bank_id", "route",
            "source_asset_id", "degradation_profile_id",
            "degradation_profile_sha256", "input_frame_sha256", "dimensions",
            "analysis_grid_invocation_count", "feature_tensor_q15_sha256",
            "descriptor_outputs", "cache_manifest_sha256"
        ])
        let dimensions = try json.object(fields["dimensions"], keys: [
            "input_luma", "input_chroma", "output_luma", "output_chroma"
        ])
        func pair(_ value: ASHLUTStrictJSONValueV2?) throws -> [Int] {
            let values = try json.array(value)
            guard values.count == 2 else {
                throw ASHCalibrationCLIError.invalidRequest("cache dimension pair")
            }
            return try values.map { try json.integer($0) }
        }
        let descriptorValues = try json.array(fields["descriptor_outputs"])
        guard descriptorValues.count == ASHSpatialDescriptorV2.count else {
            throw ASHCalibrationCLIError.invalidRequest("cache descriptor count")
        }
        let descriptorOutputs: [[String: Any]] = try descriptorValues.enumerated().map {
            index, value in
            let row = try json.object(value, keys: [
                "descriptor_id", "output_frame_sha256"
            ])
            let identifier = try json.integer(row["descriptor_id"])
            let outputSHA256 = try json.string(row["output_frame_sha256"])
            guard identifier == index, isSHA256(outputSHA256) else {
                throw ASHCalibrationCLIError.invalidRequest("cache descriptor binding")
            }
            return [
                "descriptor_id": identifier,
                "output_frame_sha256": outputSHA256
            ]
        }
        func nullableString(_ value: ASHLUTStrictJSONValueV2?) throws -> Any {
            switch value {
            case .null?: return NSNull()
            case .string(let string)?: return string
            default: throw ASHCalibrationCLIError.invalidRequest("cache nullable string")
            }
        }
        let manifest: [String: Any] = [
            "schema_version": try json.string(fields["schema_version"]),
            "artifact_kind": try json.string(fields["artifact_kind"]),
            "bank_id": try json.string(fields["bank_id"]),
            "route": try json.string(fields["route"]),
            "source_asset_id": try json.string(fields["source_asset_id"]),
            "degradation_profile_id": try nullableString(
                fields["degradation_profile_id"]
            ),
            "degradation_profile_sha256": try nullableString(
                fields["degradation_profile_sha256"]
            ),
            "input_frame_sha256": try json.string(fields["input_frame_sha256"]),
            "dimensions": [
                "input_luma": try pair(dimensions["input_luma"]),
                "input_chroma": try pair(dimensions["input_chroma"]),
                "output_luma": try pair(dimensions["output_luma"]),
                "output_chroma": try pair(dimensions["output_chroma"])
            ],
            "analysis_grid_invocation_count": try json.integer(
                fields["analysis_grid_invocation_count"]
            ),
            "feature_tensor_q15_sha256": try json.string(
                fields["feature_tensor_q15_sha256"]
            ),
            "descriptor_outputs": descriptorOutputs,
            "cache_manifest_sha256": try json.string(
                fields["cache_manifest_sha256"]
            )
        ]
        guard manifest["schema_version"] as? String == "1.0.0",
              manifest["artifact_kind"] as? String
                == "p06_native_non_ash_output_cache",
              manifest["bank_id"] as? String
                == mapping.sharedBankConfigurationSHA256.hex,
              manifest["cache_manifest_sha256"] as? String == token,
              manifest["analysis_grid_invocation_count"] as? Int == 1,
              isSHA256(manifest["input_frame_sha256"] as? String ?? ""),
              isSHA256(manifest["feature_tensor_q15_sha256"] as? String ?? "") else {
            throw ASHCalibrationCLIError.invalidRequest("imported cache manifest")
        }
        return ASHCalibrationNonASHCacheImportRequest(
            cacheToken: token,
            cacheManifest: manifest,
            artifactPath: try json.string(root["cache_artifact_path"]),
            artifactSHA256: artifactSHA256
        )
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy {
            $0.isNumber || ("a"..."f").contains(String($0))
        }
    }
}

struct ASHCalibrationNonASHCachedReconstructionRequest {
    let cacheToken: String
    let ruleSHA256: String
    let ruleCoordinates: [String: Int]
    let rule: ASHLockedNonASHRuleV2
    let outputPath: String

    static func parse(
        _ data: Data
    ) throws -> ASHCalibrationNonASHCachedReconstructionRequest {
        let json = ASHCalibrationCLIJSON.self
        let root = try json.object(try json.strictCanonicalValue(data), keys: [
            "schema_version", "operation", "cache_token", "rule_configuration",
            "rule_sha256", "output_path"
        ])
        let cacheToken = try json.string(root["cache_token"])
        let ruleSHA256 = try json.string(root["rule_sha256"])
        guard try json.string(root["schema_version"]) == "1.0.0",
              try json.string(root["operation"]) == "reconstruct_non_ash_cached",
              isSHA256(cacheToken),
              isSHA256(ruleSHA256) else {
            throw ASHCalibrationCLIError.invalidRequest("cached non-ASH identity")
        }
        guard case .object(let rawRule)? = root["rule_configuration"],
              Set(rawRule.keys) == Set(ASHLockedNonASHRuleV2.coordinateOrder),
              ASHCalibrationCLIHash.hex(
                ASHLUTCanonicalJSONV2.encode(.object(rawRule))
              ) == ruleSHA256 else {
            throw ASHCalibrationCLIError.hashMismatch("cached non-ASH rule")
        }
        var coordinates: [String: Int] = [:]
        for name in ASHLockedNonASHRuleV2.coordinateOrder {
            coordinates[name] = try json.integer(rawRule[name])
        }
        return ASHCalibrationNonASHCachedReconstructionRequest(
            cacheToken: cacheToken,
            ruleSHA256: ruleSHA256,
            ruleCoordinates: coordinates,
            rule: try ASHLockedNonASHRuleV2(coordinates: coordinates),
            outputPath: try json.string(root["output_path"])
        )
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy {
            $0.isNumber || ("a"..."f").contains(String($0))
        }
    }
}

struct ASHCalibrationFixedCachedReconstructionRequest {
    let cacheToken: String
    let descriptorID: Int
    let outputPath: String

    static func parse(
        _ data: Data
    ) throws -> ASHCalibrationFixedCachedReconstructionRequest {
        let json = ASHCalibrationCLIJSON.self
        let root = try json.object(try json.strictCanonicalValue(data), keys: [
            "schema_version", "operation", "cache_token", "descriptor_id",
            "output_path"
        ])
        let cacheToken = try json.string(root["cache_token"])
        let descriptorID = try json.integer(root["descriptor_id"])
        guard try json.string(root["schema_version"]) == "1.0.0",
              try json.string(root["operation"]) == "reconstruct_fixed_cached",
              cacheToken.count == 64,
              cacheToken.allSatisfy({
                  $0.isNumber || ("a"..."f").contains(String($0))
              }),
              (0..<ASHSpatialDescriptorV2.count).contains(descriptorID) else {
            throw ASHCalibrationCLIError.invalidRequest("cached fixed identity")
        }
        return ASHCalibrationFixedCachedReconstructionRequest(
            cacheToken: cacheToken,
            descriptorID: descriptorID,
            outputPath: try json.string(root["output_path"])
        )
    }
}

enum ASHCalibrationRequestOperation {
    static func parse(_ data: Data) throws -> String {
        let json = ASHCalibrationCLIJSON.self
        let value = try json.strictCanonicalValue(data)
        guard case .object(let root) = value else {
            throw ASHCalibrationCLIError.invalidRequest("request object expected")
        }
        return try json.string(root["operation"])
    }
}

final class ASHCalibrationNativeSession {
    private struct GenericCorrectiveDiagnosticRuntime {
        let compilation: ASHGenericPhaseCompilationV3
        let artifact: ASHLUTBinaryArtifactV2
        let loaded: ASHLUTLoadedV2
        let diagnosticConfiguration: ASHLUTLockedConfigurationV2
    }

    private struct PreparedCorrectiveOutput {
        let path: String
        let data: Data
    }

    let configuration: ASHLUTLockedConfigurationV2
    let mapping: ASHLockedVideoMappingV2
    let operatorBank: ASHLockedOperatorBankV2
    let manifest: ASHLockedCandidateLUTManifestV1
    let direct2xLUT: ASHLUTLoadedV2
    let direct3Over2LUT: ASHLUTLoadedV2

    private(set) var invocationCount = 0
    private var genericCorrectiveDiagnosticRuntimes:
        [ASHSpatialRouteV2: GenericCorrectiveDiagnosticRuntime] = [:]
    private var genericCorrectiveCompilationCounts: [ASHSpatialRouteV2: Int] = [:]
    private let correctiveOutputWriter: (Data, String) throws -> Void
    private let correctiveOutputReopener: (String) throws -> Data
    private let correctiveOutputRemover: (String) -> Void
    private var nonASHCaches: [String: ASHLockedNonASHOutputCacheV2] = [:]
    private var nonASHCacheManifests: [String: [String: Any]] = [:]
    private var nonASHCacheIdentityTokens: [String: String] = [:]

    init(
        configuration: ASHLUTLockedConfigurationV2,
        mapping: ASHLockedVideoMappingV2,
        operatorBank: ASHLockedOperatorBankV2,
        manifest: ASHLockedCandidateLUTManifestV1,
        direct2xData: Data,
        direct3Over2Data: Data,
        correctiveOutputWriter: @escaping (Data, String) throws -> Void = {
            data, path in
            try ASHCalibrationCLIFileIO.writeNewEphemeralRegularFile(data, path: path)
        },
        correctiveOutputReopener: @escaping (String) throws -> Data = {
            try ASHCalibrationCLIFileIO.readRegularFile($0)
        },
        correctiveOutputRemover: @escaping (String) -> Void = {
            ASHCalibrationCLIFileIO.removeIfPresent($0)
        }
    ) throws {
        try mapping.validate(configuration: configuration)
        try operatorBank.validate(mapping: mapping)
        self.configuration = configuration
        self.mapping = mapping
        self.operatorBank = operatorBank
        self.manifest = manifest
        self.correctiveOutputWriter = correctiveOutputWriter
        self.correctiveOutputReopener = correctiveOutputReopener
        self.correctiveOutputRemover = correctiveOutputRemover
        direct2xLUT = try ASHLUTBinaryCodecV2.load(
            direct2xData,
            manifestRoute: manifest.route(.direct2x),
            configuration: configuration
        )
        direct3Over2LUT = try ASHLUTBinaryCodecV2.load(
            direct3Over2Data,
            manifestRoute: manifest.route(.direct3Over2),
            configuration: configuration
        )
    }

    func process(_ request: ASHCalibrationBatchRequest) throws -> [[String: Any]] {
        try request.frames.map(processFrame)
    }

    func measure(_ request: ASHCalibrationMeasurementRequest) throws -> [String: Any] {
        try measureFrame(request.frame)
    }

    func control(_ request: ASHCalibrationControlRequest) throws -> [String: Any] {
        try controlFrame(request)
    }

    func prepareNonASHCache(
        _ request: ASHCalibrationNonASHCachePrepareRequest
    ) throws -> [String: Any] {
        try prepareNonASHCacheFrame(request)
    }

    func importNonASHCache(
        _ request: ASHCalibrationNonASHCacheImportRequest
    ) throws -> [String: Any] {
        try importNonASHCacheArtifact(request)
    }

    func reconstructNonASHCached(
        _ request: ASHCalibrationNonASHCachedReconstructionRequest
    ) throws -> [String: Any] {
        try reconstructNonASHCachedFrame(request)
    }

    func reconstructFixedCached(
        _ request: ASHCalibrationFixedCachedReconstructionRequest
    ) throws -> [String: Any] {
        try reconstructFixedCachedFrame(request)
    }

    func diagnoseCorrective(
        _ request: ASHCalibrationCorrectiveDiagnosticRequest
    ) throws -> [String: Any] {
        invocationCount += 1
        let frame = request.frame
        let inputData = try ASHCalibrationCLIFileIO.readRegularFile(frame.inputPath)
        guard inputData.count == frame.inputWidth * frame.inputHeight * 3 / 2 else {
            throw ASHCalibrationCLIError.invalidRequest(
                "corrective diagnostic input NV12 byte count"
            )
        }
        guard ASHCalibrationCLIHash.hex(inputData) == frame.inputSHA256 else {
            throw ASHCalibrationCLIError.hashMismatch(
                "corrective diagnostic input NV12"
            )
        }
        let codePlanes = try decodeNV12(
            inputData,
            width: frame.inputWidth,
            height: frame.inputHeight
        )
        let contractData = try ASHCalibrationCLIFileIO.readRegularFile(
            request.coordinateModelContractPath
        )
        let expectedContractHash = try ASHLUTHashV2(
            hex: request.coordinateModelContractSHA256
        )
        guard ASHCalibrationCLIHash.value(contractData) == expectedContractHash else {
            throw ASHCalibrationCLIError.hashMismatch(
                "corrective diagnostic coordinate contract file"
            )
        }
        let contract = try ASHCoordinateModelContractV3.load(
            contractData,
            expectedSHA256: expectedContractHash
        )
        let productionLUT = frame.route == .direct2x ? direct2xLUT : direct3Over2LUT
        let referenceInput = ASHLockedReferenceInputV2(
            luma: codePlanes.luma,
            cb: codePlanes.cb,
            cr: codePlanes.cr,
            chromaSiting: .left,
            lut: productionLUT,
            configuration: configuration,
            mapping: mapping
        )
        try ASHLockedReferencePipelineV2.validate(referenceInput)
        let riskDiagnostic = try ASHRiskStateDiagnosticV3.process(
            ASHRiskStateDiagnosticRequestV3(
                luma: codePlanes.luma,
                cb: codePlanes.cb,
                cr: codePlanes.cr,
                chromaSiting: .left,
                step: request.analysisGridSourceStep,
                boundary: configuration.boundaryMode,
                baseConfiguration: mapping.analyzerConfiguration,
                riskWeights: ASHRiskStateDiagnosticV3.exactRiskWeights,
                riskThresholdBands: ASHRiskStateDiagnosticV3.exactRiskThresholdBands
            )
        )
        let analysisGrid = riskDiagnostic.baselineGrid
        let analysisGridSHA256 = try correctiveAnalysisGridSHA256(analysisGrid)
        let lumaPlane = try ASHLockedReferencePipelineV2.makePlane(
            codePlanes.luma,
            channel: .luma
        )
        let cbPlane = try ASHLockedReferencePipelineV2.makePlane(
            codePlanes.cb,
            channel: .chroma
        )
        let crPlane = try ASHLockedReferencePipelineV2.makePlane(
            codePlanes.cr,
            channel: .chroma
        )

        let generic = try genericCorrectiveRuntime(for: frame.route)
        let genericDispatch = try ASHLockedRuntimeV2.makeDispatchGrid(
            lut: generic.loaded,
            configuration: generic.diagnosticConfiguration,
            analysisGrid: analysisGrid,
            context: .spatialOnly
        )
        let coordinateRoute: ASHCoordinateModelRouteV3 = frame.route == .direct2x
            ? .direct2x : .direct3Over2
        let anisotropyCells = ASHLockedPlanePolicyDiagnosticV3.requiredAnisotropyCells
        var preparedOutputs: [PreparedCorrectiveOutput] = []
        preparedOutputs.reserveCapacity(request.outputDescriptors.count + 1)
        var cellEvidence: [[String: Any]] = []
        cellEvidence.reserveCapacity(request.outputDescriptors.count)

        for coordinateCellID in ASHCalibrationCorrectiveDiagnosticRequest.coordinateCells {
            let policies = try correctiveCoordinatePolicies(coordinateCellID)
            let selection = try ASHCoordinateDiagnosticRouteSelectionV3(
                route: coordinateRoute,
                lumaCoordinatePolicy: policies.luma,
                chromaCoordinatePolicy: policies.chroma,
                contract: contract
            )
            let diagnostic = try ASHLockedPlanePolicyDiagnosticV3.process(
                ASHLockedPlanePolicyDiagnosticRequestV3(
                    selection: selection,
                    lumaPlane: lumaPlane,
                    cbPlane: cbPlane,
                    crPlane: crPlane,
                    dispatchGrid: genericDispatch,
                    configuration: generic.diagnosticConfiguration,
                    analysisGrid: analysisGrid,
                    chromaSiting: .left,
                    anisotropyCells: anisotropyCells
                )
            )
            guard diagnostic.route == coordinateRoute,
                  diagnostic.contractSHA256 == contract.sha256,
                  diagnostic.anisotropyCells.count == anisotropyCells.count else {
                throw ASHCalibrationCLIError.outputValidation(
                    "corrective diagnostic plane result identity"
                )
            }
            for (anisotropyIndex, anisotropy) in diagnostic.anisotropyCells.enumerated() {
                let ordinal = cellEvidence.count
                let descriptor = request.outputDescriptors[ordinal]
                let expectedAnisotropyID = ASHCalibrationCorrectiveDiagnosticRequest
                    .anisotropyCells[anisotropyIndex]
                guard descriptor.ordinal == ordinal,
                      descriptor.coordinateCellID == coordinateCellID,
                      descriptor.anisotropyCellID == expectedAnisotropyID,
                      anisotropy.selection == anisotropyCells[anisotropyIndex] else {
                    throw ASHCalibrationCLIError.outputValidation(
                        "corrective diagnostic cell result order"
                    )
                }
                let outputData = try encodeNV12(
                    luma: anisotropy.luma.output,
                    cb: anisotropy.cb.output,
                    cr: anisotropy.cr.output
                )
                try validateCorrectiveOutputGeometry(
                    outputData,
                    frame: frame,
                    luma: anisotropy.luma.output,
                    cb: anisotropy.cb.output,
                    cr: anisotropy.cr.output
                )
                let planeHashes = try correctivePlaneCodeSHA256(
                    nv12: outputData,
                    width: frame.outputWidth,
                    height: frame.outputHeight
                )
                let blockID = "\(coordinateRoute.rawValue)-\(coordinateCellID)-\(expectedAnisotropyID)"
                cellEvidence.append([
                    "ordinal": ordinal,
                    "block_id": blockID,
                    "coordinate_cell_id": coordinateCellID,
                    "anisotropy_cell_id": expectedAnisotropyID,
                    "output_path": descriptor.outputPath,
                    "output_nv12_sha256": ASHCalibrationCLIHash.hex(outputData),
                    "output_frame_sha256": try planarFrameSHA256(
                        nv12: outputData,
                        width: frame.outputWidth,
                        height: frame.outputHeight
                    ),
                    "planes": [
                        "y": try correctivePlaneEvidence(
                            anisotropy.luma,
                            channelTag: "Y\0",
                            outputPlaneSHA256: planeHashes["y"]!
                        ),
                        "cb": try correctivePlaneEvidence(
                            anisotropy.cb,
                            channelTag: "CB\0",
                            outputPlaneSHA256: planeHashes["cb"]!
                        ),
                        "cr": try correctivePlaneEvidence(
                            anisotropy.cr,
                            channelTag: "CR\0",
                            outputPlaneSHA256: planeHashes["cr"]!
                        )
                    ]
                ])
                preparedOutputs.append(PreparedCorrectiveOutput(
                    path: descriptor.outputPath,
                    data: outputData
                ))
            }
        }
        guard cellEvidence.count == request.outputDescriptors.count,
              preparedOutputs.count == request.outputDescriptors.count else {
            throw ASHCalibrationCLIError.outputValidation(
                "corrective diagnostic cell cardinality"
            )
        }

        let productionDispatch = try ASHLockedRuntimeV2.makeDispatchGrid(
            lut: productionLUT,
            configuration: configuration,
            analysisGrid: analysisGrid,
            context: .spatialOnly
        )
        let productionReconstruction = try ASHLockedReferencePipelineV2
            .reconstructForMeasurement(
                lumaPlane: lumaPlane,
                cbPlane: cbPlane,
                crPlane: crPlane,
                dispatchGrid: productionDispatch,
                configuration: configuration,
                analysisGrid: analysisGrid,
                chromaSiting: .left
            )
        let productionData = try encodeNV12(
            luma: productionReconstruction.luma.output,
            cb: productionReconstruction.cb.output,
            cr: productionReconstruction.cr.output
        )
        try validateCorrectiveOutputGeometry(
            productionData,
            frame: frame,
            luma: productionReconstruction.luma.output,
            cb: productionReconstruction.cb.output,
            cr: productionReconstruction.cr.output
        )
        let productionPlaneHashes = try correctivePlaneCodeSHA256(
            nv12: productionData,
            width: frame.outputWidth,
            height: frame.outputHeight
        )
        let productionManifestRoute = try manifest.route(frame.route)
        let productionEvidence: [String: Any] = [
            "output_path": request.productionV2ReferenceOutputPath,
            "output_nv12_sha256": ASHCalibrationCLIHash.hex(productionData),
            "output_frame_sha256": try planarFrameSHA256(
                nv12: productionData,
                width: frame.outputWidth,
                height: frame.outputHeight
            ),
            "planes": [
                "y": [
                    "output_plane_sha256": productionPlaneHashes["y"]!,
                    "normalized_plane_sha256": try correctiveNormalizedPlaneSHA256(
                        productionReconstruction.luma.output,
                        channelTag: "Y\0"
                    )
                ],
                "cb": [
                    "output_plane_sha256": productionPlaneHashes["cb"]!,
                    "normalized_plane_sha256": try correctiveNormalizedPlaneSHA256(
                        productionReconstruction.cb.output,
                        channelTag: "CB\0"
                    )
                ],
                "cr": [
                    "output_plane_sha256": productionPlaneHashes["cr"]!,
                    "normalized_plane_sha256": try correctiveNormalizedPlaneSHA256(
                        productionReconstruction.cr.output,
                        channelTag: "CR\0"
                    )
                ]
            ],
            "lut_whole_file_sha256": productionManifestRoute.wholeFileSHA256.hex,
            "lut_payload_sha256": productionManifestRoute.payloadSHA256.hex,
            "lut_entry_count": productionManifestRoute.entryCount
        ]
        preparedOutputs.append(PreparedCorrectiveOutput(
            path: request.productionV2ReferenceOutputPath,
            data: productionData
        ))

        guard riskDiagnostic.baselineGrid == analysisGrid,
              riskDiagnostic.cells.count
                == ASHRiskStateDiagnosticV3.exactRiskWeights.count
                    * ASHRiskStateDiagnosticV3.exactRiskThresholdBands.count else {
            throw ASHCalibrationCLIError.outputValidation(
                "corrective risk diagnostic baseline or cardinality"
            )
        }
        let riskCells: [[String: Any]] = try riskDiagnostic.cells.map { cell in
            let weightIndex = cell.ordinal
                / ASHRiskStateDiagnosticV3.exactRiskThresholdBands.count
            let bandIndex = cell.ordinal
                % ASHRiskStateDiagnosticV3.exactRiskThresholdBands.count
            guard weightIndex < ASHRiskStateDiagnosticV3.exactRiskWeights.count,
                  bandIndex < ASHRiskStateDiagnosticV3.exactRiskThresholdBands.count,
                  cell.riskWeights
                    == ASHRiskStateDiagnosticV3.exactRiskWeights[weightIndex],
                  cell.riskThresholdBand
                    == ASHRiskStateDiagnosticV3.exactRiskThresholdBands[bandIndex],
                  let minimum = cell.sortedRiskProxyUNorm15.first,
                  let maximum = cell.sortedRiskProxyUNorm15.last,
                  cell.sortedRiskProxyUNorm15.count == riskDiagnostic.baselineGrid.count else {
                throw ASHCalibrationCLIError.outputValidation(
                    "corrective risk diagnostic cell identity"
                )
            }
            return [
                "ordinal": cell.ordinal,
                "cell_id": String(
                    format: "weight-%02d-band-%02d",
                    weightIndex,
                    bandIndex
                ),
                "risk_weight_pair": [
                    "laplacian_unorm15": Int(cell.riskWeights.laplacianUNorm15),
                    "alternating_difference_unorm15": Int(
                        cell.riskWeights.alternatingDifferenceUNorm15
                    )
                ],
                "risk_threshold_band": [
                    "low_unorm15": Int(cell.riskThresholdBand.lowUNorm15),
                    "high_unorm15": Int(cell.riskThresholdBand.highUNorm15)
                ],
                "risk_zero_count": cell.riskZeroCount,
                "risk_one_count": cell.riskOneCount,
                "risk_proxy_minimum_unorm15": Int(minimum),
                "risk_proxy_maximum_unorm15": Int(maximum),
                "risk_proxy_value_count": cell.sortedRiskProxyUNorm15.count,
                "risk_proxy_vector_sha256": cell.riskProxyVectorSHA256.hex
            ]
        }

        guard preparedOutputs.count == 17,
              Set(preparedOutputs.map(\.path)).count == preparedOutputs.count,
              genericCorrectiveCompilationCounts[frame.route] == 1 else {
            throw ASHCalibrationCLIError.outputValidation(
                "corrective diagnostic transaction or compiler counters"
            )
        }
        let response: [String: Any] = [
            "schema_version": "1.0.0",
            "status": "development_diagnostic_no_selection",
            "split": "development",
            "validation_accessed": false,
            "holdout_accessed": false,
            "selected_winner": NSNull(),
            "request_id": frame.requestID,
            "target_route": coordinateRoute.rawValue,
            "configuration_id": request.configurationID,
            "compiler_inputs_sha256": request.compilerInputsSHA256,
            "candidate_vector_sha256": mapping.candidateVectorSHA256.hex,
            "shared_bank_configuration_sha256": mapping
                .sharedBankConfigurationSHA256.hex,
            "mapping_sha256": configuration.mappingSHA256.hex,
            "operator_bank_sha256": configuration.operatorBankSHA256.hex,
            "metric_policy_sha256": configuration.metricPolicySHA256.hex,
            "calibration_plan_sha256": configuration.calibrationPlanSHA256.hex,
            "corpus_lock_bundle_sha256": configuration.corpusLockBundleSHA256.hex,
            "candidate_lut_runtime_manifest_sha256": manifest.manifestSHA256.hex,
            "input_sha256": ASHCalibrationCLIHash.hex(inputData),
            "coordinate_model_contract_file_sha256": contract.sha256.hex,
            "coordinate_oracle_matrix_sha256": contract.coordinateOracleMatrixSHA256.hex,
            "coordinate_experiment_dimensions_sha256": contract.experimentDimensionsSHA256.hex,
            "output_plane_hash_contract": ASHCalibrationCorrectiveHashContract
                .outputPlaneID,
            "normalized_plane_hash_contract": ASHCalibrationCorrectiveHashContract
                .normalizedPlaneID,
            "analysis_grid_hash_contract": ASHCalibrationCorrectiveHashContract
                .analysisGridID,
            "analysis_grid_source_step": analysisGrid.step,
            "analysis_cell_count": analysisGrid.count,
            "analysis_grid_sha256": analysisGridSHA256,
            "generic_lut": [
                "whole_file_sha256": generic.artifact.wholeFileSHA256.hex,
                "payload_sha256": generic.artifact.payloadSHA256.hex,
                "entry_count": generic.loaded.entries.count,
                "parameter_count": generic.loaded.parameters.count,
                "header_crc32": String(
                    format: "0x%08X",
                    ASHLUTLittleEndianV2.uint32(
                        generic.loaded.immutableBytes,
                        at: 288
                    )
                ),
                "payload_crc32": String(
                    format: "0x%08X",
                    ASHLUTLittleEndianV2.uint32(
                        generic.loaded.immutableBytes,
                        at: 292
                    )
                ),
                "offline_path_evaluation_count": generic.compilation
                    .offlinePathEvaluationCount,
                "runtime_tree_generation_count": generic.compilation
                    .runtimeTreeGenerationCount,
                "maximum_operator_evaluations": generic.compilation
                    .maximumOperatorEvaluations,
                "serialization_rebind_contract": ASHCalibrationCorrectiveHashContract
                    .serializationRebindID,
                "original_luma_coordinate_policy": configuration.routeSelection(
                    for: frame.route
                ).lumaCoordinatePolicy.rawValue,
                "original_chroma_coordinate_policy": configuration.routeSelection(
                    for: frame.route
                ).chromaCoordinatePolicy.rawValue,
                "serialized_luma_coordinate_policy": generic.diagnosticConfiguration
                    .routeSelection(for: frame.route).lumaCoordinatePolicy.rawValue,
                "serialized_chroma_coordinate_policy": generic.diagnosticConfiguration
                    .routeSelection(for: frame.route).chromaCoordinatePolicy.rawValue,
                "serialization_rebind_applied": configuration.routeSelection(
                    for: frame.route
                ) != generic.diagnosticConfiguration.routeSelection(for: frame.route),
                "serialization_rebind_sha256": correctiveSerializationRebindSHA256(
                    route: frame.route,
                    original: configuration.routeSelection(for: frame.route),
                    serialized: generic.diagnosticConfiguration.routeSelection(for: frame.route)
                )
            ],
            "session_counters": [
                "input_decode_count": 1,
                "analysis_grid_build_count": 1,
                "generic_compile_count_for_route": genericCorrectiveCompilationCounts[
                    frame.route
                ]!,
                "generic_dispatch_count": 1,
                "plane_diagnostic_count": 4,
                "risk_diagnostic_count": 1,
                "production_v2_dispatch_count": 1,
                "output_write_count": preparedOutputs.count,
                "output_reopen_count": preparedOutputs.count
            ],
            "production_v2_reference": productionEvidence,
            "cells": cellEvidence,
            "native_invocation_proof": [
                "protocol": "serve-candidate/diagnose_corrective_frame-v1",
                "process_id": Int(ProcessInfo.processInfo.processIdentifier),
                "executable_sha256": manifest.executableSHA256.hex,
                "source_manifest_sha256": manifest.sourceManifestSHA256.hex
            ],
            "risk_state": [
                "analysis_grid_source_step": riskDiagnostic.baselineGrid.step,
                "analysis_cell_count": riskDiagnostic.baselineGrid.count,
                "baseline_analysis_grid_sha256": try correctiveAnalysisGridSHA256(
                    riskDiagnostic.baselineGrid
                ),
                "cells": riskCells
            ]
        ]
        _ = try ASHCalibrationCLIJSON.canonicalData(response)
        var writtenPaths: [String] = []
        do {
            for output in preparedOutputs {
                try correctiveOutputWriter(output.data, output.path)
                writtenPaths.append(output.path)
                guard try correctiveOutputReopener(output.path) == output.data else {
                    throw ASHCalibrationCLIError.outputValidation(
                        "corrective diagnostic output reopen"
                    )
                }
            }
            return response
        } catch {
            for path in writtenPaths {
                correctiveOutputRemover(path)
            }
            throw error
        }
    }

    func correctiveGenericCompilationCount(for route: ASHSpatialRouteV2) -> Int {
        genericCorrectiveCompilationCounts[route, default: 0]
    }

    private func genericCorrectiveRuntime(
        for route: ASHSpatialRouteV2
    ) throws -> GenericCorrectiveDiagnosticRuntime {
        if let existing = genericCorrectiveDiagnosticRuntimes[route] {
            return existing
        }
        let diagnostic = try ASHGenericPhaseCompilerDiagnosticV3.compile(
            route: route,
            configuration: configuration
        )
        let containerConfiguration = try correctiveDiagnosticContainerConfiguration(
            for: route
        )
        let containerEntries = correctiveDiagnosticContainerEntries(diagnostic.entries)
        guard correctiveDiagnosticContainerEntriesPreserveSemantics(
            original: diagnostic.entries,
            container: containerEntries
        ) else {
            throw ASHCalibrationCLIError.outputValidation(
                "generic corrective serialization rebind semantics"
            )
        }
        let compilation = ASHLUTCompilationV2(
            route: route,
            configuration: containerConfiguration,
            entries: containerEntries,
            offlinePathEvaluationCount: diagnostic.offlinePathEvaluationCount,
            runtimeTreeGenerationCount: diagnostic.runtimeTreeGenerationCount
        )
        let artifact = try ASHLUTBinaryCodecV2.serialize(compilation)
        let loaded = try ASHLUTBinaryCodecV2.load(
            artifact.data,
            expectedRoute: route,
            configuration: containerConfiguration
        )
        guard loaded.immutableBytes == artifact.data,
              loaded.wholeFileSHA256 == artifact.wholeFileSHA256,
              loaded.payloadSHA256 == artifact.payloadSHA256,
              loaded.entries.count == diagnostic.entries.count,
              loaded.configuration == containerConfiguration,
              diagnostic.runtimeTreeGenerationCount == 0 else {
            throw ASHCalibrationCLIError.outputValidation(
                "generic corrective LUT serialize/load binding"
            )
        }
        if configuration.routeSelection(for: route) != containerConfiguration
            .routeSelection(for: route) {
            do {
                _ = try ASHLUTBinaryCodecV2.load(
                    artifact.data,
                    expectedRoute: route,
                    configuration: configuration
                )
                throw ASHCalibrationCLIError.outputValidation(
                    "generic corrective original configuration accepted rebind artifact"
                )
            } catch ASHLUTBinaryErrorV2.inputHashMismatch {
                // The frozen loader rejects the serialized half-pixel parameter table
                // before decoding entries under the original source-aligned route.
            }
        }
        let runtime = GenericCorrectiveDiagnosticRuntime(
            compilation: diagnostic,
            artifact: artifact,
            loaded: loaded,
            diagnosticConfiguration: containerConfiguration
        )
        genericCorrectiveDiagnosticRuntimes[route] = runtime
        genericCorrectiveCompilationCounts[route, default: 0] += 1
        return runtime
    }

    func correctiveDiagnosticContainerConfiguration(
        for route: ASHSpatialRouteV2
    ) throws -> ASHLUTLockedConfigurationV2 {
        let routeSelection = configuration.routeSelection(for: route)
        let diagnosticSelection = try ASHLUTLockedRouteSelectionV2(
            lumaCoordinatePolicy: .halfPixelCenter,
            chromaCoordinatePolicy: .halfPixelCenter,
            analysisGridSourceStep: routeSelection.analysisGridSourceStep
        )
        let routes = ASHLUTLockedRoutesV2(
            direct2x: route == .direct2x
                ? diagnosticSelection : configuration.routes.direct2x,
            direct3Over2: route == .direct3Over2
                ? diagnosticSelection : configuration.routes.direct3Over2
        )
        return try ASHLUTLockedConfigurationV2(
            configurationID: configuration.configurationID,
            mappingSHA256: configuration.mappingSHA256,
            operatorBankSHA256: configuration.operatorBankSHA256,
            metricPolicySHA256: configuration.metricPolicySHA256,
            compilerInputsSHA256: configuration.compilerInputsSHA256,
            calibrationPlanSHA256: configuration.calibrationPlanSHA256,
            corpusLockBundleSHA256: configuration.corpusLockBundleSHA256,
            boundaryMode: configuration.boundaryMode,
            operatorParameters: configuration.operatorParameters,
            semanticSteps: configuration.semanticSteps,
            compilerPolicy: configuration.compilerPolicy,
            routes: routes
        )
    }

    func correctiveDiagnosticContainerEntries(
        _ entries: [ASHLUTCompiledEntryV2]
    ) -> [ASHLUTCompiledEntryV2] {
        entries.map { entry in
            let parameters = ASHLUTParameterPairV2(
                primary: entry.parameters.primary,
                secondary: entry.parameters.secondary,
                confidenceThresholdUNorm16: entry.parameters.confidenceThresholdUNorm16,
                lumaCoordinatePolicy: .halfPixelCenter,
                chromaCoordinatePolicy: .halfPixelCenter,
                boundaryMode: entry.parameters.boundaryMode
            )
            return ASHLUTCompiledEntryV2(
                logicalIndex: entry.logicalIndex,
                sourceState: entry.sourceState,
                validStateOrdinal: entry.validStateOrdinal,
                phaseOrdinal: entry.phaseOrdinal,
                context: entry.context,
                primary: entry.primary,
                secondary: entry.secondary,
                primaryWeightUNorm16: entry.primaryWeightUNorm16,
                secondaryWeightUNorm16: entry.secondaryWeightUNorm16,
                marginUNorm16: entry.marginUNorm16,
                sourceAlignedExact: entry.sourceAlignedExact,
                temporalForcedSpatial: entry.temporalForcedSpatial,
                parameters: parameters
            )
        }
    }

    func correctiveGenericDiagnosticArtifact(
        for route: ASHSpatialRouteV2
    ) throws -> Data {
        try genericCorrectiveRuntime(for: route).artifact.data
    }

    func correctiveGenericDiagnosticConfiguration(
        for route: ASHSpatialRouteV2
    ) throws -> ASHLUTLockedConfigurationV2 {
        try genericCorrectiveRuntime(for: route).diagnosticConfiguration
    }

    func correctiveGenericDiagnosticCompilation(
        for route: ASHSpatialRouteV2
    ) throws -> ASHGenericPhaseCompilationV3 {
        try genericCorrectiveRuntime(for: route).compilation
    }

    func correctiveSerializationRebindSHA256(
        route: ASHSpatialRouteV2,
        original: ASHLUTLockedRouteSelectionV2,
        serialized: ASHLUTLockedRouteSelectionV2
    ) -> String {
        var data = ASHCalibrationCorrectiveHashContract.serializationRebindDomain
        data.append(Data(route.rawValue.utf8))
        data.append(0)
        data.append(Data(original.lumaCoordinatePolicy.rawValue.utf8))
        data.append(0)
        data.append(Data(original.chromaCoordinatePolicy.rawValue.utf8))
        data.append(0)
        data.append(Data(serialized.lumaCoordinatePolicy.rawValue.utf8))
        data.append(0)
        data.append(Data(serialized.chromaCoordinatePolicy.rawValue.utf8))
        data.append(0)
        data.append(original == serialized ? 0 : 1)
        return ASHCalibrationCLIHash.hex(data)
    }

    private func correctiveDiagnosticContainerEntriesPreserveSemantics(
        original: [ASHLUTCompiledEntryV2],
        container: [ASHLUTCompiledEntryV2]
    ) -> Bool {
        guard original.count == container.count else { return false }
        return zip(original, container).allSatisfy { source, rebound in
            source.logicalIndex == rebound.logicalIndex
                && source.sourceState == rebound.sourceState
                && source.validStateOrdinal == rebound.validStateOrdinal
                && source.phaseOrdinal == rebound.phaseOrdinal
                && source.context == rebound.context
                && source.primary == rebound.primary
                && source.secondary == rebound.secondary
                && source.primaryWeightUNorm16 == rebound.primaryWeightUNorm16
                && source.secondaryWeightUNorm16 == rebound.secondaryWeightUNorm16
                && source.marginUNorm16 == rebound.marginUNorm16
                && source.sourceAlignedExact == rebound.sourceAlignedExact
                && source.temporalForcedSpatial == rebound.temporalForcedSpatial
                && source.parameters.primary == rebound.parameters.primary
                && source.parameters.secondary == rebound.parameters.secondary
                && source.parameters.confidenceThresholdUNorm16
                    == rebound.parameters.confidenceThresholdUNorm16
                && source.parameters.boundaryMode == rebound.parameters.boundaryMode
                && rebound.parameters.lumaCoordinatePolicy == .halfPixelCenter
                && rebound.parameters.chromaCoordinatePolicy == .halfPixelCenter
        }
    }

    private func correctiveCoordinatePolicies(
        _ cellID: String
    ) throws -> (
        luma: ASHCoordinateModelPolicyV3,
        chroma: ASHCoordinateModelPolicyV3
    ) {
        switch cellID {
        case "HH": (.halfPixelCenter, .halfPixelCenter)
        case "HS": (.halfPixelCenter, .sourceAlignedRational)
        case "SH": (.sourceAlignedRational, .halfPixelCenter)
        case "SS": (.sourceAlignedRational, .sourceAlignedRational)
        default:
            throw ASHCalibrationCLIError.invalidRequest(
                "corrective diagnostic coordinate cell"
            )
        }
    }

    private func validateCorrectiveOutputGeometry(
        _ data: Data,
        frame: ASHCalibrationFrameRequest,
        luma: ASHLockedReferencePlaneOutputV2,
        cb: ASHLockedReferencePlaneOutputV2,
        cr: ASHLockedReferencePlaneOutputV2
    ) throws {
        guard luma.width == frame.outputWidth,
              luma.height == frame.outputHeight,
              cb.width == frame.outputWidth / 2,
              cb.height == frame.outputHeight / 2,
              cr.width == cb.width,
              cr.height == cb.height,
              data.count == frame.outputWidth * frame.outputHeight * 3 / 2 else {
            throw ASHCalibrationCLIError.outputValidation(
                "corrective diagnostic output geometry"
            )
        }
    }

    private func correctivePlaneCodeSHA256(
        nv12: Data,
        width: Int,
        height: Int
    ) throws -> [String: String] {
        let yByteCount = width * height
        guard width > 0,
              height > 0,
              width.isMultiple(of: 2),
              height.isMultiple(of: 2),
              nv12.count == yByteCount * 3 / 2 else {
            throw ASHCalibrationCLIError.outputValidation(
                "corrective diagnostic plane hash geometry"
            )
        }
        let chromaSampleCount = yByteCount / 4
        var cb = Data()
        var cr = Data()
        cb.reserveCapacity(chromaSampleCount)
        cr.reserveCapacity(chromaSampleCount)
        for index in 0..<chromaSampleCount {
            cb.append(nv12[yByteCount + 2 * index])
            cr.append(nv12[yByteCount + 2 * index + 1])
        }
        return [
            "y": ASHCalibrationCLIHash.hex(Data(nv12.prefix(yByteCount))),
            "cb": ASHCalibrationCLIHash.hex(cb),
            "cr": ASHCalibrationCLIHash.hex(cr)
        ]
    }

    private func correctivePlaneEvidence(
        _ output: ASHLockedPlaneDiagnosticOutputV3,
        channelTag: String,
        outputPlaneSHA256: String
    ) throws -> [String: Any] {
        [
            "coordinate_policy": output.coordinatePolicy.rawValue,
            "anisotropy_strength_q12": Int(output.anisotropyStrengthQ12),
            "sample_count": output.output.width * output.output.height,
            "output_plane_sha256": outputPlaneSHA256,
            "normalized_plane_sha256": try correctiveNormalizedPlaneSHA256(
                output.output,
                channelTag: channelTag
            ),
            "source_aligned_entry_flag_sample_count": output
                .sourceAlignedEntryFlagSampleCount,
            "source_aligned_sample_preservation_count": output
                .sourceAlignedSamplePreservationCount,
            "numerical_fallback_count": output.numericalFallbackCount
        ]
    }

    func correctiveNormalizedPlaneSHA256(
        _ plane: ASHLockedReferencePlaneOutputV2,
        channelTag: String
    ) throws -> String {
        guard ["Y\0", "CB\0", "CR\0"].contains(channelTag),
              plane.width > 0,
              plane.height > 0,
              plane.normalizedSamples.count == plane.width * plane.height,
              let width = UInt32(exactly: plane.width),
              let height = UInt32(exactly: plane.height),
              let sampleCount = UInt32(exactly: plane.normalizedSamples.count) else {
            throw ASHCalibrationCLIError.outputValidation(
                "corrective diagnostic normalized plane hash geometry"
            )
        }
        var data = ASHCalibrationCorrectiveHashContract.normalizedPlaneDomain
        data.append(contentsOf: Data(channelTag.utf8))
        appendBigEndian(height, to: &data)
        appendBigEndian(width, to: &data)
        appendBigEndian(sampleCount, to: &data)
        for sample in plane.normalizedSamples {
            guard sample.isFinite else {
                throw ASHCalibrationCLIError.outputValidation(
                    "corrective diagnostic normalized plane hash sample"
                )
            }
            appendBigEndian(sample.bitPattern, to: &data)
        }
        return ASHCalibrationCLIHash.hex(data)
    }

    func correctiveAnalysisGridSHA256(
        _ grid: ASHAnalysisGridV2
    ) throws -> String {
        guard grid.cells.count == grid.columnCount * grid.rowCount else {
            throw ASHCalibrationCLIError.outputValidation(
                "corrective diagnostic analysis grid cardinality"
            )
        }
        var data = ASHCalibrationCorrectiveHashContract.analysisGridDomain
        for value in [
            grid.sourceWidth, grid.sourceHeight, grid.step,
            grid.columnCount, grid.rowCount, grid.cells.count
        ] {
            guard let exact = UInt32(exactly: value) else {
                throw ASHCalibrationCLIError.outputValidation(
                    "corrective diagnostic analysis grid extent"
                )
            }
            appendBigEndian(exact, to: &data)
        }
        for cell in grid.cells {
            for value in [
                cell.column, cell.row, cell.originX, cell.originY,
                cell.actualWidth, cell.actualHeight
            ] {
                guard let exact = UInt32(exactly: value) else {
                    throw ASHCalibrationCLIError.outputValidation(
                        "corrective diagnostic analysis cell extent"
                    )
                }
                appendBigEndian(exact, to: &data)
            }
            appendBigEndian(cell.centerX.bitPattern, to: &data)
            appendBigEndian(cell.centerY.bitPattern, to: &data)
            appendBigEndian(cell.analysis.state.rawValue, to: &data)
            let measurements = cell.analysis.measurements
            for value in [
                measurements.tensorXX,
                measurements.tensorYY,
                measurements.tensorXY,
                measurements.normalizedGradientMagnitude,
                measurements.structureCoherence,
                measurements.edgeNormalRadians,
                measurements.edgeTangentRadians,
                Double(measurements.orientationSector),
                measurements.textureEnergy,
                measurements.riskProxy,
                measurements.localNoiseEstimate,
                measurements.chromaAlignment,
                measurements.chromaEdgeConfidence,
                measurements.localMinimumY,
                measurements.localMaximumY
            ] {
                guard value.isFinite else {
                    throw ASHCalibrationCLIError.outputValidation(
                        "corrective diagnostic nonfinite analysis value"
                    )
                }
                appendBigEndian(value.bitPattern, to: &data)
            }
            let sidecar = cell.analysis.sidecar
            data.append(sidecar.inputRange == .video ? 0 : 1)
            for value in [
                sidecar.normalizedGradientMagnitude,
                sidecar.structureCoherence,
                sidecar.edgeNormalRadians,
                sidecar.edgeTangentRadians
            ] {
                guard value.isFinite else {
                    throw ASHCalibrationCLIError.outputValidation(
                        "corrective diagnostic nonfinite sidecar value"
                    )
                }
                appendBigEndian(value.bitPattern, to: &data)
            }
            guard let orientationSector = UInt32(exactly: sidecar.orientationSector) else {
                throw ASHCalibrationCLIError.outputValidation(
                    "corrective diagnostic sidecar orientation"
                )
            }
            appendBigEndian(orientationSector, to: &data)
            for value in [
                sidecar.textureEnergy,
                sidecar.riskProxy,
                sidecar.localNoiseEstimate,
                sidecar.temporalConfidence
            ] {
                guard value.isFinite else {
                    throw ASHCalibrationCLIError.outputValidation(
                        "corrective diagnostic nonfinite sidecar value"
                    )
                }
                appendBigEndian(value.bitPattern, to: &data)
            }
            appendBigEndian(sidecar.motionVectorQ8_8.x, to: &data)
            appendBigEndian(sidecar.motionVectorQ8_8.y, to: &data)
            for value in [
                sidecar.chromaAlignment,
                sidecar.chromaEdgeConfidence,
                sidecar.localMinimumY,
                sidecar.localMaximumY
            ] {
                guard value.isFinite else {
                    throw ASHCalibrationCLIError.outputValidation(
                        "corrective diagnostic nonfinite sidecar value"
                    )
                }
                appendBigEndian(value.bitPattern, to: &data)
            }
            let hysteresis = cell.analysis.hysteresis
            for decision in [
                hysteresis.edgePresent,
                hysteresis.coherentStructure,
                hysteresis.textureHighFrequency,
                hysteresis.aliasOrRingingRisk,
                hysteresis.temporalSupportValid,
                hysteresis.chromaLumaStructureAligned
            ] {
                try appendCorrectiveLengthPrefixedUTF8(
                    decision.rawValue,
                    to: &data
                )
            }
        }
        return ASHCalibrationCLIHash.hex(data)
    }

    private func appendCorrectiveLengthPrefixedUTF8(
        _ value: String,
        to data: inout Data
    ) throws {
        let bytes = Data(value.utf8)
        guard let count = UInt16(exactly: bytes.count) else {
            throw ASHCalibrationCLIError.outputValidation(
                "corrective diagnostic hash string length"
            )
        }
        appendBigEndian(count, to: &data)
        data.append(bytes)
    }

    private func processFrame(_ request: ASHCalibrationFrameRequest) throws -> [String: Any] {
        invocationCount += 1
        ASHCalibrationCLIFileIO.removeIfPresent(request.outputPath)
        do {
            let inputData = try ASHCalibrationCLIFileIO.readRegularFile(request.inputPath)
            guard inputData.count == request.inputWidth * request.inputHeight * 3 / 2 else {
                throw ASHCalibrationCLIError.invalidRequest("input NV12 byte count")
            }
            guard ASHCalibrationCLIHash.hex(inputData) == request.inputSHA256 else {
                throw ASHCalibrationCLIError.hashMismatch("input NV12")
            }
            let planes = try decodeNV12(
                inputData,
                width: request.inputWidth,
                height: request.inputHeight
            )
            let lut = request.route == .direct2x ? direct2xLUT : direct3Over2LUT
            let output = try ASHLockedReferencePipelineV2.process(
                ASHLockedReferenceInputV2(
                    luma: planes.luma,
                    cb: planes.cb,
                    cr: planes.cr,
                    chromaSiting: .left,
                    lut: lut,
                    configuration: configuration,
                    mapping: mapping
                )
            )
            let outputData = try encodeNV12(output)
            guard outputData.count == request.outputWidth * request.outputHeight * 3 / 2 else {
                throw ASHCalibrationCLIError.outputValidation("output NV12 byte count")
            }
            try ASHCalibrationCLIFileIO.writeNewEphemeralRegularFile(
                outputData,
                path: request.outputPath
            )
            let reopened = try ASHCalibrationCLIFileIO.readRegularFile(request.outputPath)
            guard reopened == outputData else {
                throw ASHCalibrationCLIError.outputValidation("reopened output bytes")
            }
            return try summary(
                request: request,
                inputData: inputData,
                outputData: outputData,
                runtime: output.summary
            )
        } catch {
            ASHCalibrationCLIFileIO.removeIfPresent(request.outputPath)
            throw error
        }
    }

    private func measureFrame(_ request: ASHCalibrationFrameRequest) throws -> [String: Any] {
        invocationCount += 1
        ASHCalibrationCLIFileIO.removeIfPresent(request.outputPath)
        do {
            let inputData = try ASHCalibrationCLIFileIO.readRegularFile(request.inputPath)
            guard inputData.count == request.inputWidth * request.inputHeight * 3 / 2,
                  ASHCalibrationCLIHash.hex(inputData) == request.inputSHA256 else {
                throw ASHCalibrationCLIError.hashMismatch("measurement input NV12")
            }
            let planes = try decodeNV12(
                inputData,
                width: request.inputWidth,
                height: request.inputHeight
            )
            let lut = request.route == .direct2x ? direct2xLUT : direct3Over2LUT
            let measurement = try ASHLockedReferencePipelineV2.measureDispatchProjection(
                ASHLockedReferenceInputV2(
                    luma: planes.luma,
                    cb: planes.cb,
                    cr: planes.cr,
                    chromaSiting: .left,
                    lut: lut,
                    configuration: configuration,
                    mapping: mapping
                )
            )
            let fullData = try encodeNV12(measurement.fullOutput)
            let controlData = try encodeNV12(measurement.controlOutput)
            guard fullData == controlData else {
                throw ASHCalibrationCLIError.outputValidation(
                    "dispatch projection changed quantized output"
                )
            }
            try ASHCalibrationCLIFileIO.writeNewEphemeralRegularFile(
                fullData,
                path: request.outputPath
            )
            guard try ASHCalibrationCLIFileIO.readRegularFile(request.outputPath) == fullData else {
                throw ASHCalibrationCLIError.outputValidation("measurement output reopen")
            }
            var result = try summary(
                request: request,
                inputData: inputData,
                outputData: fullData,
                runtime: measurement.fullOutput.summary
            )
            result["measurement_domain"] = measurement.measurementDomain
            result["warmup_repetition_count"] = measurement.warmupRepetitionCount
            result["measured_repetition_count"] = measurement.repetitions.count
            result["full_output_nv12_sha256"] = ASHCalibrationCLIHash.hex(fullData)
            result["control_output_nv12_sha256"] = ASHCalibrationCLIHash.hex(controlData)
            result["repetitions"] = measurement.repetitions.map { repetition in
                [
                    "index": repetition.index,
                    "order": repetition.order.rawValue,
                    "full_analysis_nanoseconds": nanoseconds(
                        repetition.fullAnalysisMilliseconds
                    ),
                    "full_dispatch_nanoseconds": nanoseconds(
                        repetition.fullDispatchMilliseconds
                    ),
                    "full_reconstruction_nanoseconds": nanoseconds(
                        repetition.fullReconstructionMilliseconds
                    ),
                    "control_reconstruction_nanoseconds": nanoseconds(
                        repetition.controlReconstructionMilliseconds
                    )
                ] as [String: Any]
            }
            return result
        } catch {
            ASHCalibrationCLIFileIO.removeIfPresent(request.outputPath)
            throw error
        }
    }

    private func prepareNonASHCacheFrame(
        _ request: ASHCalibrationNonASHCachePrepareRequest
    ) throws -> [String: Any] {
        invocationCount += 1
        let frame = request.frame
        let inputData = try ASHCalibrationCLIFileIO.readRegularFile(frame.inputPath)
        guard inputData.count == frame.inputWidth * frame.inputHeight * 3 / 2,
              ASHCalibrationCLIHash.hex(inputData) == frame.inputSHA256 else {
            throw ASHCalibrationCLIError.hashMismatch("non-ASH cache input NV12")
        }
        let boundaryInputFrameSHA256 = try planarFrameSHA256(
            nv12: inputData,
            width: frame.inputWidth,
            height: frame.inputHeight
        )
        let route = frame.route == .direct2x ? "direct-2x" : "direct-3over2"
        let identity: [String: Any] = [
            "schema_version": "1.0.0",
            "artifact_kind": "p06_native_non_ash_cache_identity",
            "bank_id": mapping.sharedBankConfigurationSHA256.hex,
            "route": route,
            "source_asset_id": request.sourceAssetID,
            "degradation_profile_id": request.degradationProfileID ?? NSNull(),
            "degradation_profile_sha256": request.degradationProfileSHA256 ?? NSNull(),
            "input_frame_sha256": request.inputFrameSHA256,
            "boundary_input_frame_sha256": boundaryInputFrameSHA256,
            "input_nv12_sha256": ASHCalibrationCLIHash.hex(inputData),
            "input_luma_dimensions": [frame.inputHeight, frame.inputWidth],
            "output_luma_dimensions": [frame.outputHeight, frame.outputWidth]
        ]
        let identitySHA256 = ASHCalibrationCLIHash.hex(
            try ASHCalibrationCLIJSON.canonicalData(identity)
        )
        if let token = nonASHCacheIdentityTokens[identitySHA256],
           let cacheManifest = nonASHCacheManifests[token],
           let cache = nonASHCaches[token] {
            let artifact = try cache.serializedArtifactData()
            try ASHCalibrationCLIFileIO.writeNewEphemeralRegularFile(
                artifact,
                path: request.cacheArtifactPath
            )
            return [
                "cache_token": token,
                "cache_manifest": cacheManifest,
                "cache_reused": true,
                "cache_artifact_sha256": ASHCalibrationCLIHash.hex(artifact),
                "cache_artifact_size_bytes": artifact.count,
                "preparation_analysis_grid_invocation_count": 0,
                "preparation_spatial_operator_evaluation_count": 0
            ]
        }

        let planes = try decodeNV12(
            inputData,
            width: frame.inputWidth,
            height: frame.inputHeight
        )
        let cache = try ASHLockedReferencePipelineV2.prepareNonASHOutputCache(
            ASHLockedNonASHCacheInputV2(
                luma: planes.luma,
                cb: planes.cb,
                cr: planes.cr,
                chromaSiting: .left,
                route: frame.route,
                configuration: configuration,
                mapping: mapping,
                inputFrameSHA256: try ASHLUTHashV2(hex: request.inputFrameSHA256)
            )
        )
        guard cache.analysisGridInvocationCount == 1,
              cache.statefulLUTLookupCount == 0,
              cache.descriptorPrecomputeCount == ASHSpatialDescriptorV2.count,
              cache.inputLumaWidth == frame.inputWidth,
              cache.inputLumaHeight == frame.inputHeight,
              cache.outputLumaWidth == frame.outputWidth,
              cache.outputLumaHeight == frame.outputHeight else {
            throw ASHCalibrationCLIError.outputValidation("non-ASH cache counters or geometry")
        }
        let descriptorOutputs: [[String: Any]] = try (0..<ASHSpatialDescriptorV2.count).map {
            descriptorID in
            let payload = try cache.descriptorOutputNV12(descriptorID: descriptorID)
            return [
                "descriptor_id": descriptorID,
                "output_frame_sha256": try planarFrameSHA256(
                    nv12: payload,
                    width: cache.outputLumaWidth,
                    height: cache.outputLumaHeight
                )
            ]
        }
        var cacheManifest: [String: Any] = [
            "schema_version": "1.0.0",
            "artifact_kind": "p06_native_non_ash_output_cache",
            "bank_id": mapping.sharedBankConfigurationSHA256.hex,
            "route": route,
            "source_asset_id": request.sourceAssetID,
            "degradation_profile_id": request.degradationProfileID ?? NSNull(),
            "degradation_profile_sha256": request.degradationProfileSHA256 ?? NSNull(),
            "input_frame_sha256": request.inputFrameSHA256,
            "dimensions": [
                "input_luma": [cache.inputLumaHeight, cache.inputLumaWidth],
                "input_chroma": [cache.inputChromaHeight, cache.inputChromaWidth],
                "output_luma": [cache.outputLumaHeight, cache.outputLumaWidth],
                "output_chroma": [cache.outputChromaHeight, cache.outputChromaWidth]
            ],
            "analysis_grid_invocation_count": cache.analysisGridInvocationCount,
            "feature_tensor_q15_sha256": ASHCalibrationCLIHash.hex(
                try cache.featureTensorQ15Data()
            ),
            "descriptor_outputs": descriptorOutputs
        ]
        let token = ASHCalibrationCLIHash.hex(
            try ASHCalibrationCLIJSON.canonicalData(cacheManifest)
        )
        cacheManifest["cache_manifest_sha256"] = token
        nonASHCaches[token] = cache
        nonASHCacheManifests[token] = cacheManifest
        nonASHCacheIdentityTokens[identitySHA256] = token
        let artifact = try cache.serializedArtifactData()
        try ASHCalibrationCLIFileIO.writeNewEphemeralRegularFile(
            artifact,
            path: request.cacheArtifactPath
        )
        return [
            "cache_token": token,
            "cache_manifest": cacheManifest,
            "cache_reused": false,
            "cache_artifact_sha256": ASHCalibrationCLIHash.hex(artifact),
            "cache_artifact_size_bytes": artifact.count,
            "preparation_analysis_grid_invocation_count": 1,
            "preparation_spatial_operator_evaluation_count": 16
        ]
    }

    private func importNonASHCacheArtifact(
        _ request: ASHCalibrationNonASHCacheImportRequest
    ) throws -> [String: Any] {
        invocationCount += 1
        let artifact = try ASHCalibrationCLIFileIO.readRegularFile(request.artifactPath)
        guard ASHCalibrationCLIHash.hex(artifact) == request.artifactSHA256 else {
            throw ASHCalibrationCLIError.hashMismatch("non-ASH cache artifact")
        }
        let cache = try ASHLockedNonASHOutputCacheV2.loadSerializedArtifactData(
            artifact,
            configurationID: configuration.configurationID,
            expectedSharedBankConfigurationSHA256: mapping.sharedBankConfigurationSHA256
        )
        guard let dimensions = request.cacheManifest["dimensions"]
                as? [String: [Int]],
              let route = request.cacheManifest["route"] as? String,
              let featureSHA256 = request.cacheManifest["feature_tensor_q15_sha256"]
                as? String,
              let inputFrameSHA256 = request.cacheManifest["input_frame_sha256"]
                as? String,
              let descriptors = request.cacheManifest["descriptor_outputs"]
                as? [[String: Any]],
              route == (cache.route == .direct2x ? "direct-2x" : "direct-3over2"),
              dimensions["input_luma"]
                == [cache.inputLumaHeight, cache.inputLumaWidth],
              dimensions["input_chroma"]
                == [cache.inputChromaHeight, cache.inputChromaWidth],
              dimensions["output_luma"]
                == [cache.outputLumaHeight, cache.outputLumaWidth],
              dimensions["output_chroma"]
                == [cache.outputChromaHeight, cache.outputChromaWidth],
              cache.inputFrameSHA256?.hex == inputFrameSHA256,
              ASHCalibrationCLIHash.hex(try cache.featureTensorQ15Data())
                == featureSHA256,
              descriptors.count == ASHSpatialDescriptorV2.count else {
            throw ASHCalibrationCLIError.outputValidation(
                "imported non-ASH cache manifest binding"
            )
        }
        for descriptorID in 0..<ASHSpatialDescriptorV2.count {
            let row = descriptors[descriptorID]
            let payload = try cache.descriptorOutputNV12(descriptorID: descriptorID)
            guard row["descriptor_id"] as? Int == descriptorID,
                  row["output_frame_sha256"] as? String == (try planarFrameSHA256(
                    nv12: payload,
                    width: cache.outputLumaWidth,
                    height: cache.outputLumaHeight
                  )) else {
                throw ASHCalibrationCLIError.outputValidation(
                    "imported non-ASH descriptor bytes"
                )
            }
        }
        nonASHCaches[request.cacheToken] = cache
        nonASHCacheManifests[request.cacheToken] = request.cacheManifest
        return [
            "cache_token": request.cacheToken,
            "cache_manifest": request.cacheManifest,
            "cache_reused": true,
            "cache_artifact_sha256": request.artifactSHA256,
            "cache_artifact_size_bytes": artifact.count,
            "preparation_analysis_grid_invocation_count": 0,
            "preparation_spatial_operator_evaluation_count": 0
        ]
    }

    private func reconstructNonASHCachedFrame(
        _ request: ASHCalibrationNonASHCachedReconstructionRequest
    ) throws -> [String: Any] {
        invocationCount += 1
        ASHCalibrationCLIFileIO.removeIfPresent(request.outputPath)
        do {
            guard let cache = nonASHCaches[request.cacheToken],
                  let cacheManifest = nonASHCacheManifests[request.cacheToken],
                  cacheManifest["cache_manifest_sha256"] as? String
                    == request.cacheToken else {
                throw ASHCalibrationCLIError.invalidRequest("unknown non-ASH cache token")
            }
            let outputData = try cache.reconstructNV12(rule: request.rule)
            guard outputData.count == cache.descriptorOutputByteCount else {
                throw ASHCalibrationCLIError.outputValidation(
                    "cached non-ASH output NV12 byte count"
                )
            }
            try ASHCalibrationCLIFileIO.writeNewEphemeralRegularFile(
                outputData,
                path: request.outputPath
            )
            guard try ASHCalibrationCLIFileIO.readRegularFile(request.outputPath)
                    == outputData else {
                throw ASHCalibrationCLIError.outputValidation(
                    "cached non-ASH output reopen"
                )
            }
            let outputFrameSHA256 = try planarFrameSHA256(
                nv12: outputData,
                width: cache.outputLumaWidth,
                height: cache.outputLumaHeight
            )
            var cacheRecord: [String: Any] = [
                "schema_version": "1.0.0",
                "artifact_kind": "p06_native_non_ash_cached_reconstruction",
                "cache_token": request.cacheToken,
                "cache_manifest_sha256": request.cacheToken,
                "rule_configuration": request.ruleCoordinates,
                "rule_sha256": request.ruleSHA256,
                "output_frame_sha256": outputFrameSHA256,
                "target_route": cache.route == .direct2x
                    ? "direct-2x" : "direct-3over2",
                "stateful_lut_lookup_count": 0,
                "spatial_operator_recompute_count": 0,
                "analysis_grid_invocation_count": 0
            ]
            cacheRecord["record_sha256"] = ASHCalibrationCLIHash.hex(
                try ASHCalibrationCLIJSON.canonicalData(cacheRecord)
            )
            return [
                "cache_record": cacheRecord,
                "output_nv12_sha256": ASHCalibrationCLIHash.hex(outputData),
                "output_width": cache.outputLumaWidth,
                "output_height": cache.outputLumaHeight
            ]
        } catch {
            ASHCalibrationCLIFileIO.removeIfPresent(request.outputPath)
            throw error
        }
    }

    private func reconstructFixedCachedFrame(
        _ request: ASHCalibrationFixedCachedReconstructionRequest
    ) throws -> [String: Any] {
        invocationCount += 1
        ASHCalibrationCLIFileIO.removeIfPresent(request.outputPath)
        do {
            guard let cache = nonASHCaches[request.cacheToken],
                  let cacheManifest = nonASHCacheManifests[request.cacheToken],
                  cacheManifest["cache_manifest_sha256"] as? String
                    == request.cacheToken,
                  let inputFrameSHA256 = cacheManifest["input_frame_sha256"] as? String,
                  let bankID = cacheManifest["bank_id"] as? String,
                  bankID == mapping.sharedBankConfigurationSHA256.hex else {
                throw ASHCalibrationCLIError.invalidRequest("unknown fixed cache token")
            }
            let outputData = try cache.descriptorOutputNV12(
                descriptorID: request.descriptorID
            )
            try ASHCalibrationCLIFileIO.writeNewEphemeralRegularFile(
                outputData,
                path: request.outputPath
            )
            guard try ASHCalibrationCLIFileIO.readRegularFile(request.outputPath)
                    == outputData else {
                throw ASHCalibrationCLIError.outputValidation("cached fixed output reopen")
            }
            let outputFrameSHA256 = try planarFrameSHA256(
                nv12: outputData,
                width: cache.outputLumaWidth,
                height: cache.outputLumaHeight
            )
            let controlRequest = try fixedControlRequest(
                descriptorID: request.descriptorID,
                bankID: bankID
            )
            var cacheRecord: [String: Any] = [
                "schema_version": "1.0.0",
                "artifact_kind": "p06_native_fixed_cached_reconstruction",
                "cache_token": request.cacheToken,
                "cache_manifest_sha256": request.cacheToken,
                "descriptor_id": request.descriptorID,
                "shared_bank_configuration_sha256": bankID,
                "input_frame_sha256": inputFrameSHA256,
                "output_frame_sha256": outputFrameSHA256,
                "target_route": cache.route == .direct2x
                    ? "direct-2x" : "direct-3over2",
                "control_request": controlRequest,
                "stateful_lut_lookup_count": 0,
                "spatial_operator_recompute_count": 0,
                "analysis_grid_invocation_count": 0
            ]
            cacheRecord["record_sha256"] = ASHCalibrationCLIHash.hex(
                try ASHCalibrationCLIJSON.canonicalData(cacheRecord)
            )
            return [
                "cache_record": cacheRecord,
                "output_nv12_sha256": ASHCalibrationCLIHash.hex(outputData),
                "output_width": cache.outputLumaWidth,
                "output_height": cache.outputLumaHeight
            ]
        } catch {
            ASHCalibrationCLIFileIO.removeIfPresent(request.outputPath)
            throw error
        }
    }

    private func fixedControlRequest(
        descriptorID: Int,
        bankID: String
    ) throws -> [String: Any] {
        let configurationObject: [String: Any] = [
            "control_id": "fixed-descriptor-uniform-v1",
            "descriptor_id": descriptorID,
            "shared_bank_configuration_sha256": bankID
        ]
        let configurationSHA256 = ASHCalibrationCLIHash.hex(
            try ASHCalibrationCLIJSON.canonicalData(configurationObject)
        )
        var request: [String: Any] = [
            "schema_version": "1.0.0",
            "operation": "reconstruct_control",
            "control_key": String(format: "fixed_descriptor_%02d", descriptorID),
            "control_mode": "fixed_descriptor_uniform",
            "configuration_sha256": configurationSHA256,
            "shared_bank_configuration_sha256": bankID,
            "parameters": ["descriptor_id": descriptorID]
        ]
        request["request_sha256"] = ASHCalibrationCLIHash.hex(
            try ASHCalibrationCLIJSON.canonicalData(request)
        )
        return request
    }

    private func controlFrame(
        _ request: ASHCalibrationControlRequest
    ) throws -> [String: Any] {
        invocationCount += 1
        let frame = request.frame
        ASHCalibrationCLIFileIO.removeIfPresent(frame.outputPath)
        do {
            let inputData = try ASHCalibrationCLIFileIO.readRegularFile(frame.inputPath)
            guard inputData.count == frame.inputWidth * frame.inputHeight * 3 / 2,
                  ASHCalibrationCLIHash.hex(inputData) == frame.inputSHA256 else {
                throw ASHCalibrationCLIError.hashMismatch("control input NV12")
            }
            let planes = try decodeNV12(
                inputData,
                width: frame.inputWidth,
                height: frame.inputHeight
            )
            let routeLUT = frame.route == .direct2x ? direct2xLUT : direct3Over2LUT
            let routeInput = ASHLockedReferenceInputV2(
                luma: planes.luma,
                cb: planes.cb,
                cr: planes.cr,
                chromaSiting: .left,
                lut: routeLUT,
                configuration: configuration,
                mapping: mapping
            )
            let output: ASHLockedControlFrameV2
            let proof: [String: Any]
            let lockedRuntimeSummary: [String: Any]?
            var h07RuntimeSummary: [String: Any]? = nil
            switch request.mode {
            case .fullASH:
                let reference = try ASHLockedReferencePipelineV2.process(routeInput)
                output = controlFrame(reference)
                lockedRuntimeSummary = runtimeSummary(reference.summary)
                proof = [
                    "dispatch_source": "complete_compiled_primary_secondary_lut_dispatch",
                    "maximum_operator_evaluations": reference.summary.maximumOperatorEvaluations
                ]
            case .fixedDescriptor(let descriptorID):
                let reference = try ASHLockedReferencePipelineV2.processControlDispatch(
                    routeInput,
                    mode: .fixedDescriptor(descriptorID)
                )
                output = controlFrame(reference)
                lockedRuntimeSummary = runtimeSummary(reference.summary)
                proof = [
                    "dispatch_source": "uniform_descriptor_no_lut_dispatch",
                    "descriptor_id": Int(descriptorID),
                    "primary_weight_unorm16": Int(UInt16.max),
                    "secondary_present": false,
                    "message_raw_value": 0
                ]
            case .stateOnly:
                let reference = try ASHLockedReferencePipelineV2.processControlDispatch(
                    routeInput,
                    mode: .stateOnly
                )
                output = controlFrame(reference)
                lockedRuntimeSummary = runtimeSummary(reference.summary)
                proof = [
                    "dispatch_source": "state_phase_context_base_descriptor_before_branch",
                    "primary_weight_unorm16": Int(UInt16.max),
                    "secondary_present": false,
                    "message_raw_value": 0
                ]
            case .nonASH(let rule):
                let reference = try ASHLockedReferencePipelineV2.processControlDispatch(
                    routeInput,
                    mode: .nonASHSelector(rule)
                )
                output = controlFrame(reference)
                lockedRuntimeSummary = runtimeSummary(reference.summary)
                proof = [
                    "dispatch_source": "continuous_features_q15_no_ash_state_or_lut_dispatch",
                    "coordinate_count": ASHLockedNonASHRuleV2.coordinateOrder.count,
                    "primary_weight_unorm16": Int(UInt16.max),
                    "secondary_present": false,
                    "message_raw_value": 0
                ]
            case .conventional(let algorithm):
                lockedRuntimeSummary = nil
                output = try ASHLockedControlResamplerV2.conventional(
                    input: routeInput,
                    algorithm: algorithm
                )
                proof = [
                    "dispatch_source": "uniform_conventional_separable",
                    "algorithm_id": algorithm.rawValue,
                    "luma_coordinate_policy": configuration.routeSelection(for: frame.route)
                        .lumaCoordinatePolicy.rawValue,
                    "chroma_coordinate_policy": configuration.routeSelection(for: frame.route)
                        .chromaCoordinatePolicy.rawValue,
                    "boundary_mode": configuration.boundaryMode.rawValue
                ]
            case .nearest:
                lockedRuntimeSummary = nil
                output = try ASHLockedControlResamplerV2.nearest(input: routeInput)
                proof = [
                    "dispatch_source": "nearest_integer_floor_same_writer",
                    "index_formula": "min(floor(dst*source_extent/target_extent),source_extent-1)"
                ]
            case .h07:
                let direct2x = try ASHLockedReferencePipelineV2.process(
                    ASHLockedReferenceInputV2(
                        luma: planes.luma,
                        cb: planes.cb,
                        cr: planes.cr,
                        chromaSiting: .left,
                        lut: direct2xLUT,
                        configuration: configuration,
                        mapping: mapping
                    )
                )
                lockedRuntimeSummary = runtimeSummary(direct2x.summary)
                output = try ASHLockedControlResamplerV2.h07Lanczos3(
                    direct2x: direct2x,
                    targetLumaWidth: frame.outputWidth,
                    targetLumaHeight: frame.outputHeight,
                    targetChromaWidth: frame.outputWidth / 2,
                    targetChromaHeight: frame.outputHeight / 2,
                    boundary: configuration.boundaryMode
                )
                h07RuntimeSummary = try makeH07RuntimeSummary(
                    direct2x: direct2x,
                    targetLumaWidth: frame.outputWidth,
                    targetLumaHeight: frame.outputHeight
                )
                proof = [
                    "dispatch_source": "candidate_direct2x_then_lanczos3",
                    "direct2x_lut_whole_file_sha256": try manifest.route(.direct2x)
                        .wholeFileSHA256.hex,
                    "postprocess": "lanczos3-separable-v1",
                    "postprocess_coordinate": "src=(dst+0.5)*intermediate_extent/target_extent-0.5",
                    "boundary_mode": configuration.boundaryMode.rawValue
                ]
            }
            let outputData = try encodeNV12(output)
            guard outputData.count == frame.outputWidth * frame.outputHeight * 3 / 2 else {
                throw ASHCalibrationCLIError.outputValidation("control output NV12 byte count")
            }
            try ASHCalibrationCLIFileIO.writeNewEphemeralRegularFile(
                outputData,
                path: frame.outputPath
            )
            guard try ASHCalibrationCLIFileIO.readRegularFile(frame.outputPath) == outputData else {
                throw ASHCalibrationCLIError.outputValidation("control output reopen")
            }
            let manifestRoute = try manifest.route(frame.route)
            return [
                "request_id": frame.requestID,
                "invocation_index": invocationCount,
                "control_key": request.controlKey,
                "control_mode": request.controlMode,
                "control_request_sha256": request.requestSHA256,
                "control_configuration_sha256": request.configurationSHA256,
                "shared_bank_configuration_sha256": request.sharedBankConfigurationSHA256,
                "target_route": frame.route == .direct2x ? "direct-2x" : "direct-3over2",
                "input_nv12_sha256": ASHCalibrationCLIHash.hex(inputData),
                "output_nv12_sha256": ASHCalibrationCLIHash.hex(outputData),
                "configuration_id": configuration.configurationID,
                "candidate_lut_runtime_manifest_sha256": manifest.manifestSHA256.hex,
                "candidate_route_lut_whole_file_sha256": manifestRoute.wholeFileSHA256.hex,
                "control_execution_proof": proof,
                "locked_runtime_summary": lockedRuntimeSummary ?? NSNull(),
                "h07_runtime_summary": h07RuntimeSummary ?? NSNull(),
                "pixel_contract": "bt709-video-range-420v-8bit-nv12-v1",
                "quantization_convention": "common_420v_round_to_nearest_even",
                "production_metal_constraint_satisfied": false,
                "native_invocation_proof": [
                    "protocol": "mirmir-ash-calibration-cli-v1",
                    "process_id": Int(ProcessInfo.processInfo.processIdentifier),
                    "executable_sha256": manifest.executableSHA256.hex,
                    "source_manifest_sha256": manifest.sourceManifestSHA256.hex
                ]
            ]
        } catch {
            ASHCalibrationCLIFileIO.removeIfPresent(frame.outputPath)
            throw error
        }
    }

    private struct CodePlanes {
        let luma: ASHVideoAnalyzerV2CodePlane
        let cb: ASHVideoAnalyzerV2CodePlane
        let cr: ASHVideoAnalyzerV2CodePlane
    }

    private func decodeNV12(_ data: Data, width: Int, height: Int) throws -> CodePlanes {
        let yCount = width * height
        let y = Array(data[0..<yCount])
        let uv = Array(data[yCount..<data.count])
        var cb: [UInt8] = []
        var cr: [UInt8] = []
        cb.reserveCapacity(uv.count / 2)
        cr.reserveCapacity(uv.count / 2)
        for index in stride(from: 0, to: uv.count, by: 2) {
            cb.append(uv[index])
            cr.append(uv[index + 1])
        }
        return CodePlanes(
            luma: try ASHVideoAnalyzerV2CodePlane(
                width: width,
                height: height,
                bytesPerRow: width,
                codes: y,
                range: .video
            ),
            cb: try ASHVideoAnalyzerV2CodePlane(
                width: width / 2,
                height: height / 2,
                bytesPerRow: width / 2,
                codes: cb,
                range: .video
            ),
            cr: try ASHVideoAnalyzerV2CodePlane(
                width: width / 2,
                height: height / 2,
                bytesPerRow: width / 2,
                codes: cr,
                range: .video
            )
        )
    }

    private func encodeNV12(_ output: ASHLockedReferenceOutputV2) throws -> Data {
        try encodeNV12(luma: output.luma, cb: output.cb, cr: output.cr)
    }

    private func encodeNV12(_ output: ASHLockedControlFrameV2) throws -> Data {
        try encodeNV12(luma: output.luma, cb: output.cb, cr: output.cr)
    }

    private func encodeNV12(
        luma: ASHLockedReferencePlaneOutputV2,
        cb normalizedCB: ASHLockedReferencePlaneOutputV2,
        cr normalizedCR: ASHLockedReferencePlaneOutputV2
    ) throws -> Data {
        let cb = try ASHLockedCandidateAdapterBridgeV2.centeredChroma(normalizedCB)
        let cr = try ASHLockedCandidateAdapterBridgeV2.centeredChroma(normalizedCR)
        guard luma.width == cb.width * 2,
              luma.height == cb.height * 2,
              cb.width == cr.width,
              cb.height == cr.height else {
            throw ASHCalibrationCLIError.outputValidation("output 4:2:0 geometry")
        }
        var result = Data()
        result.reserveCapacity(luma.width * luma.height * 3 / 2)
        for value in luma.normalizedSamples {
            result.append(try quantize(value * 219.0 + 16.0))
        }
        for index in cb.samples.indices {
            result.append(try quantize((cb.samples[index] + 0.5) * 224.0 + 16.0))
            result.append(try quantize((cr.samples[index] + 0.5) * 224.0 + 16.0))
        }
        return result
    }

    private func controlFrame(
        _ output: ASHLockedReferenceOutputV2
    ) -> ASHLockedControlFrameV2 {
        ASHLockedControlFrameV2(
            luma: output.luma,
            cb: output.cb,
            cr: output.cr
        )
    }

    private func runtimeSummary(
        _ summary: ASHLockedReferenceSummaryV2
    ) -> [String: Any] {
        [
            "luma_coordinate_policy": summary.lumaCoordinatePolicy.rawValue,
            "chroma_coordinate_policy": summary.chromaCoordinatePolicy.rawValue,
            "state_histogram": summary.stateHistogram.keys.sorted().map { state in
                [
                    "state_raw_value": Int(state),
                    "count": summary.stateHistogram[state]!
                ]
            },
            "operator_histogram": summary.operatorHistogram.keys.sorted().map { descriptor in
                [
                    "descriptor_id": Int(descriptor),
                    "count": summary.operatorHistogram[descriptor]!
                ]
            },
            "maximum_operator_evaluations": summary.maximumOperatorEvaluations,
            "analysis_cell_count": summary.analysisCellCount,
            "occupied_analysis_cell_count": summary.occupiedAnalysisCellCount,
            "dispatch_record_count": summary.dispatchRecordCount,
            "exact_decode_count": summary.exactDecodeCount,
            "corrected_decode_count": summary.correctedDecodeCount,
            "rejected_decode_count": summary.rejectedDecodeCount
        ]
    }

    private func makeH07RuntimeSummary(
        direct2x: ASHLockedReferenceOutputV2,
        targetLumaWidth: Int,
        targetLumaHeight: Int
    ) throws -> [String: Any] {
        let intermediatePixelCount = direct2x.luma.width * direct2x.luma.height
        let targetPixelCount = targetLumaWidth * targetLumaHeight
        let direct2WorkItemCount = 2 * intermediatePixelCount
        let lanczos3WorkItemCount = 12 * targetPixelCount
        var summary: [String: Any] = [
            "schema_version": "1.0.0",
            "artifact_kind": "p06_h07_direct2_lanczos3_runtime_summary",
            "direct2_analysis_grid_invocation_count": 1,
            "direct2_analysis_cell_count": direct2x.summary.analysisCellCount,
            "direct2_intermediate_luma_dimensions": [
                "height": direct2x.luma.height,
                "width": direct2x.luma.width
            ],
            "target_luma_pixel_count": targetPixelCount,
            "direct2_operator_work_item_count": direct2WorkItemCount,
            "lanczos3_work_item_count": lanczos3WorkItemCount,
            "total_work_item_count": direct2WorkItemCount + lanczos3WorkItemCount
        ]
        summary["summary_sha256"] = ASHCalibrationCLIHash.hex(
            try ASHCalibrationCLIJSON.canonicalData(summary)
        )
        return summary
    }

    private func planarFrameSHA256(
        nv12: Data,
        width: Int,
        height: Int
    ) throws -> String {
        let yByteCount = width * height
        guard width > 0,
              height > 0,
              width.isMultiple(of: 2),
              height.isMultiple(of: 2),
              nv12.count == yByteCount * 3 / 2 else {
            throw ASHCalibrationCLIError.outputValidation(
                "planar frame hash NV12 geometry"
            )
        }
        var data = Data("MIRMIR-PLANAR-Q16-V1\0".utf8)
        data.append(contentsOf: Data("Y\0".utf8))
        appendBigEndian(UInt32(height), to: &data)
        appendBigEndian(UInt32(width), to: &data)
        for code in nv12.prefix(yByteCount) {
            let normalized = min(1.0, max(0.0, (Double(code) - 16.0) / 219.0))
            appendBigEndian(
                UInt16((normalized * 65_535.0).rounded(.toNearestOrEven)),
                to: &data
            )
        }
        let chromaHeight = height / 2
        let chromaWidth = width / 2
        for (tag, byteOffset) in [("CB\0", 0), ("CR\0", 1)] {
            data.append(contentsOf: Data(tag.utf8))
            appendBigEndian(UInt32(chromaHeight), to: &data)
            appendBigEndian(UInt32(chromaWidth), to: &data)
            for row in 0..<chromaHeight {
                let rowOffset = yByteCount + row * width
                for column in 0..<chromaWidth {
                    let code = nv12[rowOffset + 2 * column + byteOffset]
                    let unsigned = min(
                        1.0,
                        max(0.0, (Double(code) - 16.0) / 224.0)
                    )
                    appendBigEndian(
                        UInt16((unsigned * 65_535.0).rounded(.toNearestOrEven)),
                        to: &data
                    )
                }
            }
        }
        return ASHCalibrationCLIHash.hex(data)
    }

    private func appendBigEndian<T: FixedWidthInteger>(
        _ value: T,
        to data: inout Data
    ) {
        var encoded = value.bigEndian
        withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
    }

    private func quantize(_ value: Double) throws -> UInt8 {
        guard value.isFinite else {
            throw ASHCalibrationCLIError.outputValidation("nonfinite sample")
        }
        let rounded = value.rounded(.toNearestOrEven)
        return UInt8(min(255.0, max(0.0, rounded)))
    }

    private func summary(
        request: ASHCalibrationFrameRequest,
        inputData: Data,
        outputData: Data,
        runtime: ASHLockedReferenceSummaryV2
    ) throws -> [String: Any] {
        let manifestRoute = try manifest.route(request.route)
        return [
            "request_id": request.requestID,
            "invocation_index": invocationCount,
            "target_route": request.route == .direct2x ? "direct-2x" : "direct-3over2",
            "input_width": request.inputWidth,
            "input_height": request.inputHeight,
            "output_width": request.outputWidth,
            "output_height": request.outputHeight,
            "input_nv12_sha256": ASHCalibrationCLIHash.hex(inputData),
            "output_nv12_sha256": ASHCalibrationCLIHash.hex(outputData),
            "configuration_id": configuration.configurationID,
            "mapping_sha256": configuration.mappingSHA256.hex,
            "operator_bank_sha256": configuration.operatorBankSHA256.hex,
            "metric_policy_sha256": configuration.metricPolicySHA256.hex,
            "compiler_inputs_sha256": configuration.compilerInputsSHA256.hex,
            "calibration_plan_sha256": configuration.calibrationPlanSHA256.hex,
            "corpus_lock_bundle_sha256": configuration.corpusLockBundleSHA256.hex,
            "candidate_vector_sha256": mapping.candidateVectorSHA256.hex,
            "shared_bank_configuration_sha256": mapping.sharedBankConfigurationSHA256.hex,
            "candidate_lut_runtime_manifest_sha256": manifest.manifestSHA256.hex,
            "route_lut_whole_file_sha256": manifestRoute.wholeFileSHA256.hex,
            "route_lut_payload_sha256": manifestRoute.payloadSHA256.hex,
            "lut_header_crc32": String(format: "0x%08X", manifestRoute.headerCRC32),
            "lut_payload_crc32": String(format: "0x%08X", manifestRoute.payloadCRC32),
            "lut_entry_count": manifestRoute.entryCount,
            "lut_parameter_count": manifestRoute.parameterCount,
            "cpu_reference_analysis_traversals": runtime.cpuReferenceAnalysisTraversalCount,
            "cpu_reference_full_frame_loop_count": runtime.cpuReferenceFullFrameLoopCount,
            "production_metal_constraint_satisfied": false,
            "loaded_lut_instance_count": runtime.loadedLUTInstanceCount,
            "session_loaded_lut_instance_count": 2,
            "per_frame_lut_load_count": runtime.perFrameLUTLoadCount,
            "runtime_leaf_tree_generations": runtime.runtimeTreeGenerationCount,
            "runtime_path_generations": runtime.runtimePathAllocationCount,
            "maximum_operator_evaluations": runtime.maximumOperatorEvaluations,
            "analysis_cell_count": runtime.analysisCellCount,
            "occupied_analysis_cell_count": runtime.occupiedAnalysisCellCount,
            "dispatch_record_count": runtime.dispatchRecordCount,
            "analysis_elapsed_nanoseconds": nanoseconds(runtime.analysisElapsedMilliseconds),
            "dispatch_elapsed_nanoseconds": nanoseconds(runtime.dispatchElapsedMilliseconds),
            "reconstruction_elapsed_nanoseconds": nanoseconds(
                runtime.reconstructionElapsedMilliseconds
            ),
            "chroma_convention": "ASHLockedCandidateAdapterBridgeV2.centeredChroma_subtract_0.5_once",
            "quantization_convention": "common_420v_round_to_nearest_even",
            "pixel_contract": "bt709-video-range-420v-8bit-nv12-v1",
            "locked_runtime_summary": runtimeSummary(runtime),
            "native_invocation_proof": [
                "protocol": "mirmir-ash-calibration-cli-v1",
                "process_id": Int(ProcessInfo.processInfo.processIdentifier),
                "executable_sha256": manifest.executableSHA256.hex,
                "source_manifest_sha256": manifest.sourceManifestSHA256.hex
            ]
        ]
    }

    private func nanoseconds(_ milliseconds: Double) -> Int {
        Int((milliseconds * 1_000_000.0).rounded(.toNearestOrEven))
    }
}

/// Plane-aware format-1.2 candidate session.
///
/// The V1 session remains byte-for-byte behaviorally isolated above. This
/// session loads the two V3 LUTs once, verifies every manifest binding before
/// publication, and reconstructs through the same V3 frame pipeline used by
/// the Apple-native application runtime.
final class ASHCalibrationNativeSessionV2 {
    let configuration: ASHLUTLockedConfigurationV3
    let mapping: ASHLockedVideoMappingV2
    let manifest: ASHLockedCandidateLUTManifestV2
    let direct2xLUT: ASHLUTLoadedV3
    let direct3Over2LUT: ASHLUTLoadedV3

    private(set) var invocationCount = 0

    init(
        configuration: ASHLUTLockedConfigurationV3,
        mapping: ASHLockedVideoMappingV2,
        manifest: ASHLockedCandidateLUTManifestV2,
        direct2xData: Data,
        direct3Over2Data: Data
    ) throws {
        guard mapping.status == .calibrationCandidate,
              mapping.configurationID == configuration.configurationID,
              mapping.sha256.hex == configuration.mappingSHA256.hex,
              mapping.boundaryMode == configuration.boundaryMode,
              mapping.direct2xAnalysisGridSourceStep
                == configuration.routes.direct2x.analysisGridSourceStep,
              mapping.direct3Over2AnalysisGridSourceStep
                == configuration.routes.direct3Over2.analysisGridSourceStep else {
            throw ASHLockedVideoMappingV2Error.invalidValue
        }
        self.configuration = configuration
        self.mapping = mapping
        self.manifest = manifest
        direct2xLUT = try Self.loadLUT(
            direct2xData,
            route: .direct2x,
            manifest: manifest,
            configuration: configuration
        )
        direct3Over2LUT = try Self.loadLUT(
            direct3Over2Data,
            route: .direct3Over2,
            manifest: manifest,
            configuration: configuration
        )
    }

    func process(_ request: ASHCalibrationBatchRequest) throws -> [[String: Any]] {
        try request.frames.map(processFrame)
    }

    func control(_ request: ASHCalibrationControlRequest) throws -> [String: Any] {
        try controlFrame(request)
    }

    private static func loadLUT(
        _ data: Data,
        route: ASHSpatialRouteV2,
        manifest: ASHLockedCandidateLUTManifestV2,
        configuration: ASHLUTLockedConfigurationV3
    ) throws -> ASHLUTLoadedV3 {
        let binding = try manifest.route(route)
        guard data.count == binding.wholeFileSizeBytes,
              ASHCalibrationCLIHash.hex(data) == binding.wholeFileSHA256.hex,
              ASHLUTLittleEndianV3.uint32(data, at: 288) == binding.headerCRC32,
              ASHLUTLittleEndianV3.uint32(data, at: 292) == binding.payloadCRC32 else {
            throw ASHLockedLUTManifestErrorV3.wholeFileHashMismatch
        }
        let loaded = try ASHLUTBinaryCodecV3.load(
            data,
            expectedRoute: route,
            configuration: configuration
        )
        guard loaded.wholeFileSHA256 == binding.wholeFileSHA256,
              loaded.payloadSHA256 == binding.payloadSHA256,
              loaded.entries.count == binding.entryCount,
              loaded.parameters.count == binding.parameterCount else {
            throw ASHLockedLUTManifestErrorV3.payloadHashMismatch
        }
        return loaded
    }

    private func controlFrame(
        _ request: ASHCalibrationControlRequest
    ) throws -> [String: Any] {
        invocationCount += 1
        let frame = request.frame
        ASHCalibrationCLIFileIO.removeIfPresent(frame.outputPath)
        do {
            let inputData = try ASHCalibrationCLIFileIO.readRegularFile(
                frame.inputPath
            )
            guard inputData.count == frame.inputWidth * frame.inputHeight * 3 / 2,
                  ASHCalibrationCLIHash.hex(inputData) == frame.inputSHA256 else {
                throw ASHCalibrationCLIError.hashMismatch(
                    "format-1.2 control input NV12"
                )
            }
            let source = try decodeNV12(
                inputData,
                width: frame.inputWidth,
                height: frame.inputHeight
            )
            let lut = frame.route == .direct2x ? direct2xLUT : direct3Over2LUT
            let routeInput = ASHLockedFramePipelineInputV3(
                source: source,
                destinationGeometry: ASHNV12FrameGeometry(
                    lumaWidth: frame.outputWidth,
                    lumaHeight: frame.outputHeight,
                    chromaWidth: frame.outputWidth / 2,
                    chromaHeight: frame.outputHeight / 2
                ),
                destinationRange: .video,
                expectedRange: .video,
                expectedChromaSiting: .left,
                lut: lut,
                configuration: configuration,
                analyzerConfiguration: mapping.analyzerConfiguration
            )
            let output: ASHLockedControlFrameV2
            let runtime: ASHLockedFrameSummaryV3?
            let proof: [String: Any]
            var h07RuntimeSummary: [String: Any]? = nil
            switch request.mode {
            case .fullASH:
                let result = try ASHLockedFramePipelineV3.process(routeInput)
                output = controlFrame(result)
                runtime = result.summary
                proof = [
                    "dispatch_source": "complete_plane_aware_primary_secondary_lut_dispatch",
                    "maximum_operator_evaluations": result.summary.maximumOperatorEvaluations
                ]
            case .fixedDescriptor(let descriptorID):
                let result = try ASHLockedFramePipelineV3.processControlDispatch(
                    routeInput,
                    mode: .fixedDescriptor(descriptorID)
                )
                output = controlFrame(result)
                runtime = result.summary
                proof = [
                    "dispatch_source": "uniform_descriptor_plane_aware_no_lut_dispatch",
                    "descriptor_id": Int(descriptorID),
                    "primary_weight_unorm16": Int(UInt16.max),
                    "secondary_present": false,
                    "message_raw_value": 0
                ]
            case .stateOnly:
                let result = try ASHLockedFramePipelineV3.processControlDispatch(
                    routeInput,
                    mode: .stateOnly
                )
                output = controlFrame(result)
                runtime = result.summary
                proof = [
                    "dispatch_source": "plane_aware_state_phase_policy_base_descriptor_before_branch",
                    "primary_weight_unorm16": Int(UInt16.max),
                    "secondary_present": false,
                    "message_raw_value": 0
                ]
            case .nonASH(let rule):
                let result = try ASHLockedFramePipelineV3.processControlDispatch(
                    routeInput,
                    mode: .nonASHSelector(rule)
                )
                output = controlFrame(result)
                runtime = result.summary
                proof = [
                    "dispatch_source": "plane_aware_continuous_features_q15_no_ash_state_or_lut_dispatch",
                    "coordinate_count": ASHLockedNonASHRuleV2.coordinateOrder.count,
                    "primary_weight_unorm16": Int(UInt16.max),
                    "secondary_present": false,
                    "message_raw_value": 0
                ]
            case .conventional(let algorithm):
                output = try ASHLockedControlResamplerV2.conventional(
                    source: source,
                    route: frame.route,
                    configuration: configuration,
                    algorithm: algorithm
                )
                runtime = nil
                proof = [
                    "dispatch_source": "uniform_conventional_separable",
                    "algorithm_id": algorithm.rawValue,
                    "luma_coordinate_policy": configuration
                        .routeSelection(for: frame.route)
                        .lumaCoordinatePolicy.rawValue,
                    "chroma_coordinate_policy": configuration
                        .routeSelection(for: frame.route)
                        .chromaCoordinatePolicy.rawValue,
                    "boundary_mode": configuration.boundaryMode.rawValue
                ]
            case .nearest:
                output = try ASHLockedControlResamplerV2.nearest(
                    source: source,
                    route: frame.route
                )
                runtime = nil
                proof = [
                    "dispatch_source": "nearest_integer_floor_same_writer",
                    "index_formula": "min(floor(dst*source_extent/target_extent),source_extent-1)"
                ]
            case .h07:
                let direct2Input = ASHLockedFramePipelineInputV3(
                    source: source,
                    destinationGeometry: ASHNV12FrameGeometry(
                        lumaWidth: frame.inputWidth * 2,
                        lumaHeight: frame.inputHeight * 2,
                        chromaWidth: frame.inputWidth,
                        chromaHeight: frame.inputHeight
                    ),
                    destinationRange: .video,
                    expectedRange: .video,
                    expectedChromaSiting: .left,
                    lut: direct2xLUT,
                    configuration: configuration,
                    analyzerConfiguration: mapping.analyzerConfiguration
                )
                let direct2 = try ASHLockedFramePipelineV3.process(direct2Input)
                output = try ASHLockedControlResamplerV2.h07Lanczos3(
                    direct2x: direct2,
                    targetLumaWidth: frame.outputWidth,
                    targetLumaHeight: frame.outputHeight,
                    targetChromaWidth: frame.outputWidth / 2,
                    targetChromaHeight: frame.outputHeight / 2,
                    boundary: configuration.boundaryMode
                )
                runtime = direct2.summary
                h07RuntimeSummary = try makeH07RuntimeSummary(
                    direct2x: direct2,
                    targetLumaWidth: frame.outputWidth,
                    targetLumaHeight: frame.outputHeight
                )
                proof = [
                    "dispatch_source": "candidate_plane_aware_direct2x_then_lanczos3",
                    "direct2x_lut_whole_file_sha256": try manifest
                        .route(.direct2x).wholeFileSHA256.hex,
                    "postprocess": "lanczos3-separable-v1",
                    "postprocess_coordinate": "src=(dst+0.5)*intermediate_extent/target_extent-0.5",
                    "boundary_mode": configuration.boundaryMode.rawValue
                ]
            }
            let outputData = try encodeNV12(output)
            guard outputData.count == frame.outputWidth * frame.outputHeight * 3 / 2 else {
                throw ASHCalibrationCLIError.outputValidation(
                    "format-1.2 control output NV12 byte count"
                )
            }
            try ASHCalibrationCLIFileIO.writeNewEphemeralRegularFile(
                outputData,
                path: frame.outputPath
            )
            guard try ASHCalibrationCLIFileIO.readRegularFile(frame.outputPath)
                    == outputData else {
                throw ASHCalibrationCLIError.outputValidation(
                    "format-1.2 control output reopen"
                )
            }
            let manifestRoute = try manifest.route(frame.route)
            return [
                "request_id": frame.requestID,
                "invocation_index": invocationCount,
                "control_key": request.controlKey,
                "control_mode": request.controlMode,
                "control_request_sha256": request.requestSHA256,
                "control_configuration_sha256": request.configurationSHA256,
                "shared_bank_configuration_sha256": request.sharedBankConfigurationSHA256,
                "target_route": frame.route == .direct2x
                    ? "direct-2x" : "direct-3over2",
                "input_nv12_sha256": ASHCalibrationCLIHash.hex(inputData),
                "output_nv12_sha256": ASHCalibrationCLIHash.hex(outputData),
                "configuration_id": configuration.configurationID,
                "candidate_lut_runtime_manifest_sha256": manifest.manifestSHA256.hex,
                "candidate_route_lut_whole_file_sha256": manifestRoute.wholeFileSHA256.hex,
                "control_execution_proof": proof,
                "locked_runtime_summary": runtime.map(runtimeSummary) ?? NSNull(),
                "h07_runtime_summary": h07RuntimeSummary ?? NSNull(),
                "pixel_contract": "bt709-video-range-420v-8bit-nv12-v1",
                "quantization_convention": "common_420v_round_to_nearest_even",
                "production_metal_constraint_satisfied": false,
                "native_invocation_proof": [
                    "protocol": "mirmir-ash-calibration-cli-v2",
                    "process_id": Int(ProcessInfo.processInfo.processIdentifier),
                    "executable_sha256": manifest.executableSHA256.hex,
                    "source_manifest_sha256": manifest.sourceManifestSHA256.hex
                ]
            ]
        } catch {
            ASHCalibrationCLIFileIO.removeIfPresent(frame.outputPath)
            throw error
        }
    }

    private func processFrame(
        _ request: ASHCalibrationFrameRequest
    ) throws -> [String: Any] {
        invocationCount += 1
        ASHCalibrationCLIFileIO.removeIfPresent(request.outputPath)
        do {
            let inputData = try ASHCalibrationCLIFileIO.readRegularFile(
                request.inputPath
            )
            guard inputData.count
                    == request.inputWidth * request.inputHeight * 3 / 2,
                  ASHCalibrationCLIHash.hex(inputData) == request.inputSHA256 else {
                throw ASHCalibrationCLIError.hashMismatch("format-1.2 input NV12")
            }
            let source = try decodeNV12(
                inputData,
                width: request.inputWidth,
                height: request.inputHeight
            )
            let lut = request.route == .direct2x ? direct2xLUT : direct3Over2LUT
            let output = try ASHLockedFramePipelineV3.process(
                ASHLockedFramePipelineInputV3(
                    source: source,
                    destinationGeometry: ASHNV12FrameGeometry(
                        lumaWidth: request.outputWidth,
                        lumaHeight: request.outputHeight,
                        chromaWidth: request.outputWidth / 2,
                        chromaHeight: request.outputHeight / 2
                    ),
                    destinationRange: .video,
                    expectedRange: .video,
                    expectedChromaSiting: .left,
                    lut: lut,
                    configuration: configuration,
                    analyzerConfiguration: mapping.analyzerConfiguration
                )
            )
            let outputData = try encodeNV12(output)
            guard outputData.count
                    == request.outputWidth * request.outputHeight * 3 / 2 else {
                throw ASHCalibrationCLIError.outputValidation(
                    "format-1.2 output NV12 byte count"
                )
            }
            try ASHCalibrationCLIFileIO.writeNewEphemeralRegularFile(
                outputData,
                path: request.outputPath
            )
            guard try ASHCalibrationCLIFileIO.readRegularFile(request.outputPath)
                    == outputData else {
                throw ASHCalibrationCLIError.outputValidation(
                    "format-1.2 reopened output bytes"
                )
            }
            return try summary(
                request: request,
                inputData: inputData,
                outputData: outputData,
                runtime: output.summary
            )
        } catch {
            ASHCalibrationCLIFileIO.removeIfPresent(request.outputPath)
            throw error
        }
    }

    private func decodeNV12(
        _ data: Data,
        width: Int,
        height: Int
    ) throws -> ASHNV12CodeFrame {
        let yCount = width * height
        let y = Array(data[0..<yCount])
        let uv = Array(data[yCount..<data.count])
        var cb: [UInt8] = []
        var cr: [UInt8] = []
        cb.reserveCapacity(uv.count / 2)
        cr.reserveCapacity(uv.count / 2)
        for index in stride(from: 0, to: uv.count, by: 2) {
            cb.append(uv[index])
            cr.append(uv[index + 1])
        }
        return ASHNV12CodeFrame(
            luma: try ASHVideoAnalyzerV2CodePlane(
                width: width,
                height: height,
                bytesPerRow: width,
                codes: y,
                range: .video
            ),
            cb: try ASHVideoAnalyzerV2CodePlane(
                width: width / 2,
                height: height / 2,
                bytesPerRow: width / 2,
                codes: cb,
                range: .video
            ),
            cr: try ASHVideoAnalyzerV2CodePlane(
                width: width / 2,
                height: height / 2,
                bytesPerRow: width / 2,
                codes: cr,
                range: .video
            ),
            chromaSiting: .left
        )
    }

    private func encodeNV12(_ output: ASHLockedFrameOutputV3) throws -> Data {
        try encodeNV12(
            lumaWidth: output.luma.width,
            lumaHeight: output.luma.height,
            luma: output.luma.normalizedSamples,
            chromaWidth: output.cb.width,
            chromaHeight: output.cb.height,
            cb: output.cb.normalizedSamples,
            cr: output.cr.normalizedSamples
        )
    }

    private func encodeNV12(_ output: ASHLockedControlFrameV2) throws -> Data {
        try encodeNV12(
            lumaWidth: output.luma.width,
            lumaHeight: output.luma.height,
            luma: output.luma.normalizedSamples,
            chromaWidth: output.cb.width,
            chromaHeight: output.cb.height,
            cb: output.cb.normalizedSamples,
            cr: output.cr.normalizedSamples
        )
    }

    private func encodeNV12(
        lumaWidth: Int,
        lumaHeight: Int,
        luma: [Double],
        chromaWidth: Int,
        chromaHeight: Int,
        cb: [Double],
        cr: [Double]
    ) throws -> Data {
        guard lumaWidth == chromaWidth * 2,
              lumaHeight == chromaHeight * 2,
              luma.count == lumaWidth * lumaHeight,
              cb.count == chromaWidth * chromaHeight,
              cr.count == cb.count else {
            throw ASHCalibrationCLIError.outputValidation(
                "format-1.2 output 4:2:0 geometry"
            )
        }
        var result = Data()
        result.reserveCapacity(lumaWidth * lumaHeight * 3 / 2)
        for value in luma {
            result.append(try quantize(value * 219.0 + 16.0))
        }
        for index in cb.indices {
            let cbValue = cb[index]
            let crValue = cr[index]
            guard cbValue.isFinite, crValue.isFinite,
                  (0.0...1.0).contains(cbValue),
                  (0.0...1.0).contains(crValue) else {
                throw ASHCalibrationCLIError.outputValidation(
                    "format-1.2 normalized chroma sample"
                )
            }
            result.append(try quantize(cbValue * 224.0 + 16.0))
            result.append(try quantize(crValue * 224.0 + 16.0))
        }
        return result
    }

    private func controlFrame(
        _ output: ASHLockedFrameOutputV3
    ) -> ASHLockedControlFrameV2 {
        ASHLockedControlFrameV2(
            luma: ASHLockedReferencePlaneOutputV2(
                width: output.luma.width,
                height: output.luma.height,
                normalizedSamples: output.luma.normalizedSamples
            ),
            cb: ASHLockedReferencePlaneOutputV2(
                width: output.cb.width,
                height: output.cb.height,
                normalizedSamples: output.cb.normalizedSamples
            ),
            cr: ASHLockedReferencePlaneOutputV2(
                width: output.cr.width,
                height: output.cr.height,
                normalizedSamples: output.cr.normalizedSamples
            )
        )
    }

    private func runtimeSummary(
        _ summary: ASHLockedFrameSummaryV3
    ) -> [String: Any] {
        let selection = configuration.routeSelection(for: summary.route)
        return [
            "schema_version": "2.0.0",
            "luma_coordinate_policy": selection.lumaCoordinatePolicy.rawValue,
            "chroma_coordinate_policy": selection.chromaCoordinatePolicy.rawValue,
            "luma_anisotropy_mode_ordinal": Int(
                selection.lumaAnisotropyMode.rawValue
            ),
            "chroma_anisotropy_mode_ordinal": Int(
                selection.chromaAnisotropyMode.rawValue
            ),
            "state_histogram": summary.stateHistogram.keys.sorted().map { state in
                [
                    "state_raw_value": Int(state),
                    "count": summary.stateHistogram[state]!
                ]
            },
            "luma_operator_histogram": summary.lumaOperatorHistogram.keys
                .sorted().map { descriptor in
                    [
                        "descriptor_id": Int(descriptor),
                        "count": summary.lumaOperatorHistogram[descriptor]!
                    ]
                },
            "chroma_operator_histogram": summary.chromaOperatorHistogram.keys
                .sorted().map { descriptor in
                    [
                        "descriptor_id": Int(descriptor),
                        "count": summary.chromaOperatorHistogram[descriptor]!
                    ]
                },
            "maximum_operator_evaluations": summary.maximumOperatorEvaluations,
            "analysis_cell_count": summary.analysisCellCount,
            "occupied_analysis_cell_count": summary.occupiedAnalysisCellCount,
            "dispatch_record_count": summary.dispatchRecordCount,
            "exact_decode_count": summary.exactDecodeCount,
            "corrected_decode_count": summary.correctedDecodeCount,
            "rejected_decode_count": summary.rejectedDecodeCount
        ]
    }

    private func makeH07RuntimeSummary(
        direct2x: ASHLockedFrameOutputV3,
        targetLumaWidth: Int,
        targetLumaHeight: Int
    ) throws -> [String: Any] {
        let intermediatePixelCount = direct2x.luma.width * direct2x.luma.height
        let targetPixelCount = targetLumaWidth * targetLumaHeight
        let direct2WorkItemCount = 2 * intermediatePixelCount
        let lanczos3WorkItemCount = 12 * targetPixelCount
        var summary: [String: Any] = [
            "schema_version": "1.0.0",
            "artifact_kind": "p06_h07_direct2_lanczos3_runtime_summary",
            "direct2_analysis_grid_invocation_count": 1,
            "direct2_analysis_cell_count": direct2x.summary.analysisCellCount,
            "direct2_intermediate_luma_dimensions": [
                "height": direct2x.luma.height,
                "width": direct2x.luma.width
            ],
            "target_luma_pixel_count": targetPixelCount,
            "direct2_operator_work_item_count": direct2WorkItemCount,
            "lanczos3_work_item_count": lanczos3WorkItemCount,
            "total_work_item_count": direct2WorkItemCount + lanczos3WorkItemCount
        ]
        summary["summary_sha256"] = ASHCalibrationCLIHash.hex(
            try ASHCalibrationCLIJSON.canonicalData(summary)
        )
        return summary
    }

    private func quantize(_ value: Double) throws -> UInt8 {
        guard value.isFinite else {
            throw ASHCalibrationCLIError.outputValidation(
                "format-1.2 nonfinite sample"
            )
        }
        return UInt8(min(255.0, max(0.0, value.rounded(.toNearestOrEven))))
    }

    private func summary(
        request: ASHCalibrationFrameRequest,
        inputData: Data,
        outputData: Data,
        runtime: ASHLockedFrameSummaryV3
    ) throws -> [String: Any] {
        let route = try manifest.route(request.route)
        let selection = configuration.routeSelection(for: request.route)
        return [
            "request_id": request.requestID,
            "invocation_index": invocationCount,
            "target_route": request.route == .direct2x
                ? "direct-2x" : "direct-3over2",
            "input_width": request.inputWidth,
            "input_height": request.inputHeight,
            "output_width": request.outputWidth,
            "output_height": request.outputHeight,
            "input_nv12_sha256": ASHCalibrationCLIHash.hex(inputData),
            "output_nv12_sha256": ASHCalibrationCLIHash.hex(outputData),
            "configuration_id": configuration.configurationID,
            "mapping_sha256": configuration.mappingSHA256.hex,
            "operator_bank_sha256": configuration.operatorBankSHA256.hex,
            "metric_policy_sha256": configuration.metricPolicySHA256.hex,
            "compiler_inputs_sha256": configuration.compilerInputsSHA256.hex,
            "calibration_plan_sha256": configuration.calibrationPlanSHA256.hex,
            "corpus_lock_bundle_sha256": configuration.corpusLockBundleSHA256.hex,
            "candidate_vector_sha256": mapping.candidateVectorSHA256.hex,
            "shared_bank_configuration_sha256": mapping
                .sharedBankConfigurationSHA256.hex,
            "candidate_lut_runtime_manifest_sha256": manifest.manifestSHA256.hex,
            "route_lut_whole_file_sha256": route.wholeFileSHA256.hex,
            "route_lut_payload_sha256": route.payloadSHA256.hex,
            "lut_header_crc32": String(format: "0x%08X", route.headerCRC32),
            "lut_payload_crc32": String(format: "0x%08X", route.payloadCRC32),
            "lut_entry_count": route.entryCount,
            "lut_parameter_count": route.parameterCount,
            "cpu_reference_analysis_traversals": runtime
                .constructionCounters.analyzerTraversalCount,
            "cpu_reference_full_frame_loop_count": 3,
            "production_metal_constraint_satisfied": false,
            "loaded_lut_instance_count": 1,
            "session_loaded_lut_instance_count": 2,
            "per_frame_lut_load_count": runtime.constructionCounters.lutLoadCount,
            "runtime_leaf_tree_generations": runtime
                .constructionCounters.runtimeTreeGenerationCount,
            "runtime_path_generations": runtime
                .constructionCounters.runtimePathConstructionCount,
            "maximum_operator_evaluations": runtime.maximumOperatorEvaluations,
            "analysis_cell_count": runtime.analysisCellCount,
            "occupied_analysis_cell_count": runtime.occupiedAnalysisCellCount,
            "dispatch_record_count": runtime.dispatchRecordCount,
            "analysis_elapsed_nanoseconds": 0,
            "dispatch_elapsed_nanoseconds": 0,
            "reconstruction_elapsed_nanoseconds": 0,
            "chroma_convention": "ASHLockedCandidateAdapterBridgeV2.centeredChroma_subtract_0.5_once",
            "quantization_convention": "common_420v_round_to_nearest_even",
            "pixel_contract": "bt709-video-range-420v-8bit-nv12-v1",
            "locked_runtime_summary": [
                "luma_coordinate_policy": selection.lumaCoordinatePolicy.rawValue,
                "chroma_coordinate_policy": selection.chromaCoordinatePolicy.rawValue,
                "luma_anisotropy_mode_ordinal": Int(
                    selection.lumaAnisotropyMode.rawValue
                ),
                "chroma_anisotropy_mode_ordinal": Int(
                    selection.chromaAnisotropyMode.rawValue
                ),
                "analysis_cell_count": runtime.analysisCellCount,
                "dispatch_record_count": runtime.dispatchRecordCount,
                "primary_evaluation_count": runtime.primaryEvaluationCount,
                "secondary_evaluation_count": runtime.secondaryEvaluationCount,
                "maximum_operator_evaluations": runtime.maximumOperatorEvaluations,
                "affine_fallback_count": runtime.affineFallbackCount,
                "numerical_fallback_count": runtime.numericalFallbackCount,
                "parity_recomputation_count": runtime.parityRecomputationCount,
                "source_aligned_preservation_count": runtime
                    .sourceAlignedPreservationCount,
                "temporal_state_count": runtime.temporalStateCount
            ],
            "native_invocation_proof": [
                "protocol": "mirmir-ash-calibration-cli-v2",
                "process_id": Int(ProcessInfo.processInfo.processIdentifier),
                "executable_sha256": manifest.executableSHA256.hex,
                "source_manifest_sha256": manifest.sourceManifestSHA256.hex
            ]
        ]
    }
}
