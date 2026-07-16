import CryptoKit
import Foundation

enum ASHLockedOperatorBankV2Error: Error, Equatable, Sendable {
    case hashMismatch
    case nonCanonicalEncoding
    case fieldSetMismatch
    case invalidValue
    case configurationMismatch
    case mappingMismatch
}

struct ASHLockedOperatorBankV2: Equatable, Sendable {
    let sha256: ASHLUTHashV2
    let status: ASHLockedArtifactStatusV2
    let configurationID: String
    let operatorBankSeedSHA256: ASHLUTHashV2
    let candidateVectorSHA256: ASHLUTHashV2
    let sharedBankConfigurationSHA256: ASHLUTHashV2
    let calibrationSelectionSHA256: ASHLUTHashV2?
    let selectedEvaluationSHA256: ASHLUTHashV2?
    let immutableBytes: Data

    static func load(
        _ data: Data,
        expectedSHA256: ASHLUTHashV2,
        configuration: ASHLUTLockedConfigurationV2
    ) throws -> ASHLockedOperatorBankV2 {
        let observedSHA256 = ASHLUTHashV2(
            validatedBytes: Array(SHA256.hash(data: data))
        )
        guard observedSHA256 == expectedSHA256,
              observedSHA256 == configuration.operatorBankSHA256 else {
            throw ASHLockedOperatorBankV2Error.hashMismatch
        }
        var parser = ASHLUTStrictJSONParserV2(data: data)
        let parsed = try parser.parse()
        guard ASHLUTCanonicalJSONV2.encode(parsed) == data else {
            throw ASHLockedOperatorBankV2Error.nonCanonicalEncoding
        }
        let root = try object(parsed, keys: [
            "schema_version", "status", "operator_bank_id", "configuration_id",
            "operator_bank_seed_sha256", "candidate_vector_sha256",
            "shared_bank_configuration_sha256", "selection_binding",
            "boundary_mode", "coordinate_policies", "operator_parameters",
            "semantic_steps"
        ])
        try require(root["schema_version"], string: "1.0.0")
        try require(root["operator_bank_id"], string: "ash-spatial-operator-bank-v2")
        let status = try artifactStatus(root["status"])
        let configurationID = try string(root["configuration_id"])
        guard configurationID == configuration.configurationID else {
            throw ASHLockedOperatorBankV2Error.configurationMismatch
        }
        let selection = try selectionBinding(root["selection_binding"], status: status)
        try validateBoundary(root["boundary_mode"], configuration: configuration)
        try validateCoordinatePolicies(
            root["coordinate_policies"],
            configuration: configuration
        )
        try validateOperatorParameters(
            root["operator_parameters"],
            configuration: configuration
        )
        try validateSemanticSteps(root["semantic_steps"], configuration: configuration)
        return try ASHLockedOperatorBankV2(
            sha256: observedSHA256,
            status: status,
            configurationID: configurationID,
            operatorBankSeedSHA256: ASHLUTHashV2(
                hex: string(root["operator_bank_seed_sha256"])
            ),
            candidateVectorSHA256: ASHLUTHashV2(
                hex: string(root["candidate_vector_sha256"])
            ),
            sharedBankConfigurationSHA256: ASHLUTHashV2(
                hex: string(root["shared_bank_configuration_sha256"])
            ),
            calibrationSelectionSHA256: selection.calibrationSelection,
            selectedEvaluationSHA256: selection.selectedEvaluation,
            immutableBytes: data
        )
    }

    func validate(mapping: ASHLockedVideoMappingV2) throws {
        guard status == mapping.status,
              configurationID == mapping.configurationID,
              candidateVectorSHA256 == mapping.candidateVectorSHA256,
              sharedBankConfigurationSHA256 == mapping.sharedBankConfigurationSHA256,
              calibrationSelectionSHA256 == mapping.calibrationSelectionSHA256,
              selectedEvaluationSHA256 == mapping.selectedEvaluationSHA256 else {
            throw ASHLockedOperatorBankV2Error.mappingMismatch
        }
    }

    private static func validateBoundary(
        _ value: ASHLUTStrictJSONValueV2?,
        configuration: ASHLUTLockedConfigurationV2
    ) throws {
        let expected = configuration.boundaryMode == .clamp
            ? "clamp"
            : "mirror_reflect101"
        guard try string(value) == expected else {
            throw ASHLockedOperatorBankV2Error.configurationMismatch
        }
    }

    private static func validateCoordinatePolicies(
        _ value: ASHLUTStrictJSONValueV2?,
        configuration: ASHLUTLockedConfigurationV2
    ) throws {
        let fields = try object(value, keys: ["direct_2x", "direct_3_over_2"])
        try validateCoordinatePolicies(
            fields["direct_2x"],
            selection: configuration.routes.direct2x
        )
        try validateCoordinatePolicies(
            fields["direct_3_over_2"],
            selection: configuration.routes.direct3Over2
        )
    }

    private static func validateCoordinatePolicies(
        _ value: ASHLUTStrictJSONValueV2?,
        selection: ASHLUTLockedRouteSelectionV2
    ) throws {
        let fields = try object(value, keys: [
            "luma_coordinate_policy", "chroma_coordinate_policy"
        ])
        guard try coordinatePolicy(string(fields["luma_coordinate_policy"]))
                == selection.lumaCoordinatePolicy,
              try coordinatePolicy(string(fields["chroma_coordinate_policy"]))
                == selection.chromaCoordinatePolicy else {
            throw ASHLockedOperatorBankV2Error.configurationMismatch
        }
    }

    private static func coordinatePolicy(
        _ value: String
    ) throws -> ASHSpatialCoordinatePolicyV2 {
        switch value {
        case "half_pixel_center": .halfPixelCenter
        case "source_aligned_rational": .sourceAlignedRational
        default: throw ASHLockedOperatorBankV2Error.invalidValue
        }
    }

    private static func validateOperatorParameters(
        _ value: ASHLUTStrictJSONValueV2?,
        configuration: ASHLUTLockedConfigurationV2
    ) throws {
        let fields = try object(value, keys: [
            "anisotropy_strength_q12", "minimum_anisotropic_magnitude_unorm15",
            "minimum_anisotropic_coherence_unorm15", "detail_gain_q12",
            "relaxed_limiter_alpha_q12", "risk_detail_suppression_unorm15",
            "low_pass_radius_q8_8", "weight_epsilon_f32_bits"
        ])
        let decoded = try ASHLUTLockedOperatorParametersV2(
            anisotropyStrengthQ12: uint16(fields["anisotropy_strength_q12"]),
            minimumAnisotropicMagnitudeUNorm15: uint16(
                fields["minimum_anisotropic_magnitude_unorm15"]
            ),
            minimumAnisotropicCoherenceUNorm15: uint16(
                fields["minimum_anisotropic_coherence_unorm15"]
            ),
            detailGainQ12: uint16(fields["detail_gain_q12"]),
            relaxedLimiterAlphaQ12: uint16(fields["relaxed_limiter_alpha_q12"]),
            riskSuppressionUNorm15: uint16(fields["risk_detail_suppression_unorm15"]),
            lowPassRadiusQ8x8: uint16(fields["low_pass_radius_q8_8"]),
            weightEpsilonF32Bits: uint32(fields["weight_epsilon_f32_bits"])
        )
        guard decoded == configuration.operatorParameters else {
            throw ASHLockedOperatorBankV2Error.configurationMismatch
        }
    }

    private static func validateSemanticSteps(
        _ value: ASHLUTStrictJSONValueV2?,
        configuration: ASHLUTLockedConfigurationV2
    ) throws {
        let fields = try object(value, keys: [
            "orientation_sector_step", "support_radius_step_q8_8",
            "detail_gain_step_q12", "regularization_step_q12"
        ])
        let decoded = try ASHLUTLockedSemanticStepsV2(
            orientationSectorStep: uint8(fields["orientation_sector_step"]),
            supportRadiusStepQ8x8: uint16(fields["support_radius_step_q8_8"]),
            detailGainStepQ12: uint16(fields["detail_gain_step_q12"]),
            regularizationStepQ12: uint16(fields["regularization_step_q12"])
        )
        guard decoded == configuration.semanticSteps else {
            throw ASHLockedOperatorBankV2Error.configurationMismatch
        }
    }

    private static func selectionBinding(
        _ value: ASHLUTStrictJSONValueV2?,
        status: ASHLockedArtifactStatusV2
    ) throws -> (calibrationSelection: ASHLUTHashV2?, selectedEvaluation: ASHLUTHashV2?) {
        let fields = try object(value, keys: [
            "calibration_selection_sha256", "selected_evaluation_sha256"
        ])
        switch status {
        case .calibrationCandidate:
            guard case .null? = fields["calibration_selection_sha256"],
                  case .null? = fields["selected_evaluation_sha256"] else {
                throw ASHLockedOperatorBankV2Error.invalidValue
            }
            return (nil, nil)
        case .lockedBeforeP07:
            return try (
                ASHLUTHashV2(hex: string(fields["calibration_selection_sha256"])),
                ASHLUTHashV2(hex: string(fields["selected_evaluation_sha256"]))
            )
        }
    }

    private static func artifactStatus(
        _ value: ASHLUTStrictJSONValueV2?
    ) throws -> ASHLockedArtifactStatusV2 {
        guard let status = ASHLockedArtifactStatusV2(rawValue: try string(value)) else {
            throw ASHLockedOperatorBankV2Error.invalidValue
        }
        return status
    }

    private static func object(
        _ value: ASHLUTStrictJSONValueV2?,
        keys: Set<String>
    ) throws -> [String: ASHLUTStrictJSONValueV2] {
        guard case .object(let object)? = value, Set(object.keys) == keys else {
            throw ASHLockedOperatorBankV2Error.fieldSetMismatch
        }
        return object
    }

    private static func object(
        _ value: ASHLUTStrictJSONValueV2,
        keys: Set<String>
    ) throws -> [String: ASHLUTStrictJSONValueV2] {
        try object(Optional(value), keys: keys)
    }

    private static func string(_ value: ASHLUTStrictJSONValueV2?) throws -> String {
        guard case .string(let string)? = value else {
            throw ASHLockedOperatorBankV2Error.invalidValue
        }
        return string
    }

    private static func integer(_ value: ASHLUTStrictJSONValueV2?) throws -> Int {
        guard case .integer(let integer)? = value,
              let result = Int(exactly: integer) else {
            throw ASHLockedOperatorBankV2Error.invalidValue
        }
        return result
    }

    private static func uint8(_ value: ASHLUTStrictJSONValueV2?) throws -> UInt8 {
        guard let result = UInt8(exactly: try integer(value)) else {
            throw ASHLockedOperatorBankV2Error.invalidValue
        }
        return result
    }

    private static func uint16(_ value: ASHLUTStrictJSONValueV2?) throws -> UInt16 {
        guard let result = UInt16(exactly: try integer(value)) else {
            throw ASHLockedOperatorBankV2Error.invalidValue
        }
        return result
    }

    private static func uint32(_ value: ASHLUTStrictJSONValueV2?) throws -> UInt32 {
        guard let result = UInt32(exactly: try integer(value)) else {
            throw ASHLockedOperatorBankV2Error.invalidValue
        }
        return result
    }

    private static func require(
        _ value: ASHLUTStrictJSONValueV2?,
        string expected: String
    ) throws {
        guard try string(value) == expected else {
            throw ASHLockedOperatorBankV2Error.invalidValue
        }
    }
}
