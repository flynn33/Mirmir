import CryptoKit
import Foundation

enum ASHLUTLockedConfigurationJSONErrorV2: Error, Equatable, Sendable {
    case invalidUTF8
    case invalidSyntax
    case duplicateKey
    case fieldSetMismatch
    case invalidValue
    case selfHashMismatch
}

enum ASHLUTLockedConfigurationJSONLoaderV2 {
    static func load(_ data: Data) throws -> ASHLUTLockedConfigurationV2 {
        guard String(data: data, encoding: .utf8) != nil else {
            throw ASHLUTLockedConfigurationJSONErrorV2.invalidUTF8
        }
        var parser = ASHLUTStrictJSONParserV2(data: data)
        let root = try parser.parse()
        let document = try object(root, keys: [
            "schema_version", "status", "configuration_id", "hash_bindings",
            "canonicalization", "boundary_mode", "operator_parameters",
            "semantic_steps", "compiler_policy", "routes", "temporal",
            "source_aligned", "top_two"
        ])
        try require(string(document["schema_version"]), equals: "1.0.0")
        try require(string(document["status"]), equals: "locked")
        try validateCanonicalization(document["canonicalization"])
        try validateTemporal(document["temporal"])
        try validateSourceAligned(document["source_aligned"])
        try require(integer(document["top_two"]), equals: 2)

        let hashes = try object(document["hash_bindings"], keys: [
            "mapping_sha256", "operator_bank_sha256", "metric_policy_sha256",
            "compiler_inputs_sha256", "calibration_plan_sha256",
            "corpus_lock_bundle_sha256"
        ])
        let suppliedSelfHash = try string(hashes["compiler_inputs_sha256"])
        var canonicalDocument = document
        var canonicalHashes = hashes
        canonicalHashes.removeValue(forKey: "compiler_inputs_sha256")
        canonicalDocument["hash_bindings"] = .object(canonicalHashes)
        let canonicalBytes = ASHLUTCanonicalJSONV2.encode(.object(canonicalDocument))
        let computedSelfHash = SHA256.hash(data: canonicalBytes).map {
            String(format: "%02x", $0)
        }.joined()
        guard computedSelfHash == suppliedSelfHash else {
            throw ASHLUTLockedConfigurationJSONErrorV2.selfHashMismatch
        }

        do {
            let operatorParameters = try decodeOperatorParameters(
                document["operator_parameters"]
            )
            let semanticSteps = try decodeSemanticSteps(document["semantic_steps"])
            let compilerPolicy = try decodeCompilerPolicy(document["compiler_policy"])
            let routes = try decodeRoutes(document["routes"])
            let boundaryMode: ASHSpatialBoundaryModeV2
            switch try string(document["boundary_mode"]) {
            case "clamp": boundaryMode = .clamp
            case "mirror_reflect101": boundaryMode = .mirrorReflect101
            default: throw ASHLUTLockedConfigurationJSONErrorV2.invalidValue
            }
            return try ASHLUTLockedConfigurationV2(
                configurationID: string(document["configuration_id"]),
                mappingSHA256: ASHLUTHashV2(hex: string(hashes["mapping_sha256"])),
                operatorBankSHA256: ASHLUTHashV2(hex: string(hashes["operator_bank_sha256"])),
                metricPolicySHA256: ASHLUTHashV2(hex: string(hashes["metric_policy_sha256"])),
                compilerInputsSHA256: ASHLUTHashV2(hex: suppliedSelfHash),
                calibrationPlanSHA256: ASHLUTHashV2(hex: string(hashes["calibration_plan_sha256"])),
                corpusLockBundleSHA256: ASHLUTHashV2(hex: string(hashes["corpus_lock_bundle_sha256"])),
                boundaryMode: boundaryMode,
                operatorParameters: operatorParameters,
                semanticSteps: semanticSteps,
                compilerPolicy: compilerPolicy,
                routes: routes
            )
        } catch let error as ASHLUTLockedConfigurationJSONErrorV2 {
            throw error
        } catch {
            throw ASHLUTLockedConfigurationJSONErrorV2.invalidValue
        }
    }

    static func canonicalHashInput(_ data: Data) throws -> Data {
        guard String(data: data, encoding: .utf8) != nil else {
            throw ASHLUTLockedConfigurationJSONErrorV2.invalidUTF8
        }
        var parser = ASHLUTStrictJSONParserV2(data: data)
        guard case .object(var document) = try parser.parse(),
              case .object(var hashes)? = document["hash_bindings"],
              hashes.removeValue(forKey: "compiler_inputs_sha256") != nil else {
            throw ASHLUTLockedConfigurationJSONErrorV2.fieldSetMismatch
        }
        document["hash_bindings"] = .object(hashes)
        return ASHLUTCanonicalJSONV2.encode(.object(document))
    }

    private static func decodeOperatorParameters(
        _ value: ASHLUTStrictJSONValueV2?
    ) throws -> ASHLUTLockedOperatorParametersV2 {
        let fields = try object(value, keys: [
            "anisotropy_strength_q12", "minimum_anisotropic_magnitude_unorm15",
            "minimum_anisotropic_coherence_unorm15", "detail_gain_q12",
            "relaxed_limiter_alpha_q12", "risk_detail_suppression_unorm15",
            "low_pass_radius_q8_8", "weight_epsilon_f32_bits"
        ])
        return try ASHLUTLockedOperatorParametersV2(
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
    }

    private static func decodeSemanticSteps(
        _ value: ASHLUTStrictJSONValueV2?
    ) throws -> ASHLUTLockedSemanticStepsV2 {
        let fields = try object(value, keys: [
            "orientation_sector_step", "support_radius_step_q8_8",
            "detail_gain_step_q12", "regularization_step_q12"
        ])
        return try ASHLUTLockedSemanticStepsV2(
            orientationSectorStep: uint8(fields["orientation_sector_step"]),
            supportRadiusStepQ8x8: uint16(fields["support_radius_step_q8_8"]),
            detailGainStepQ12: uint16(fields["detail_gain_step_q12"]),
            regularizationStepQ12: uint16(fields["regularization_step_q12"])
        )
    }

    private static func decodeCompilerPolicy(
        _ value: ASHLUTStrictJSONValueV2?
    ) throws -> ASHLUTLockedCompilerPolicyV2 {
        let fields = try object(value, keys: [
            "penalty_decay_denominator", "penalty_to_weight_unorm16",
            "penalty_orientation_step", "penalty_support_step", "penalty_detail_step",
            "penalty_regularization_step", "penalty_unsupported_support_expansion",
            "penalty_coherent_support_reduction", "penalty_unsupported_detail_increase",
            "penalty_supported_detail_reduction", "penalty_relaxation_under_risk",
            "penalty_phase_kernel_mismatch", "confidence_threshold_unorm16"
        ])
        let table = try array(fields["penalty_to_weight_unorm16"]).map(uint16)
        return try ASHLUTLockedCompilerPolicyV2(
            penaltyDecayDenominator: uint16(fields["penalty_decay_denominator"]),
            orientationPenaltyStep: uint16(fields["penalty_orientation_step"]),
            supportPenaltyStep: uint16(fields["penalty_support_step"]),
            detailPenaltyStep: uint16(fields["penalty_detail_step"]),
            regularizationPenaltyStep: uint16(fields["penalty_regularization_step"]),
            unsupportedSupportExpansionPenalty: uint16(
                fields["penalty_unsupported_support_expansion"]
            ),
            coherentSupportReductionPenalty: uint16(
                fields["penalty_coherent_support_reduction"]
            ),
            unsupportedDetailIncreasePenalty: uint16(
                fields["penalty_unsupported_detail_increase"]
            ),
            supportedDetailReductionPenalty: uint16(
                fields["penalty_supported_detail_reduction"]
            ),
            relaxationUnderRiskPenalty: uint16(fields["penalty_relaxation_under_risk"]),
            phaseKernelMismatchPenalty: uint16(fields["penalty_phase_kernel_mismatch"]),
            confidenceThresholdUNorm16: uint16(fields["confidence_threshold_unorm16"]),
            penaltyToWeight: table
        )
    }

    private static func decodeRoutes(
        _ value: ASHLUTStrictJSONValueV2?
    ) throws -> ASHLUTLockedRoutesV2 {
        let fields = try object(value, keys: ["direct_2x", "direct_3_over_2"])
        return ASHLUTLockedRoutesV2(
            direct2x: try decodeRoute(fields["direct_2x"]),
            direct3Over2: try decodeRoute(fields["direct_3_over_2"])
        )
    }

    private static func decodeRoute(
        _ value: ASHLUTStrictJSONValueV2?
    ) throws -> ASHLUTLockedRouteSelectionV2 {
        let fields = try object(value, keys: [
            "coordinate_policy", "analysis_grid_source_step"
        ])
        let policy: ASHSpatialCoordinatePolicyV2
        switch try string(fields["coordinate_policy"]) {
        case "half_pixel_center": policy = .halfPixelCenter
        case "source_aligned_rational": policy = .sourceAlignedRational
        default: throw ASHLUTLockedConfigurationJSONErrorV2.invalidValue
        }
        return try ASHLUTLockedRouteSelectionV2(
            coordinatePolicy: policy,
            analysisGridSourceStep: uint8(fields["analysis_grid_source_step"])
        )
    }

    private static func validateCanonicalization(
        _ value: ASHLUTStrictJSONValueV2?
    ) throws {
        let fields = try object(value, keys: [
            "encoding", "object_key_order", "array_order", "whitespace",
            "string_escaping", "number_domain", "duplicate_keys",
            "trailing_newline_in_hash_input", "hash_algorithm", "hash_scope"
        ])
        try require(string(fields["encoding"]), equals: "UTF-8")
        try require(string(fields["object_key_order"]), equals: "ascending Unicode scalar value")
        try require(string(fields["array_order"]), equals: "preserved")
        try require(string(fields["whitespace"]), equals: "none")
        try require(
            string(fields["string_escaping"]),
            equals: "JSON quotation, reverse-solidus, and control escapes; non-ASCII encoded directly as UTF-8"
        )
        try require(string(fields["number_domain"]), equals: "integers only")
        try require(string(fields["duplicate_keys"]), equals: "reject")
        try require(boolean(fields["trailing_newline_in_hash_input"]), equals: false)
        try require(string(fields["hash_algorithm"]), equals: "SHA-256")
        try require(
            string(fields["hash_scope"]),
            equals: "complete canonical document with only /hash_bindings/compiler_inputs_sha256 omitted"
        )
    }

    private static func validateTemporal(_ value: ASHLUTStrictJSONValueV2?) throws {
        let fields = try object(value, keys: [
            "enabled", "context_count", "context_aliases_to_spatial",
            "semantic_state", "affine_anchor"
        ])
        try require(boolean(fields["enabled"]), equals: false)
        try require(integer(fields["context_count"]), equals: 4)
        let aliases = try array(fields["context_aliases_to_spatial"]).map(integer)
        try require(aliases, equals: [1, 2, 3])
        try require(
            string(fields["semantic_state"]),
            equals: "clear payload coordinate 7 and recompute coordinate 9 parity"
        )
        try require(
            string(fields["affine_anchor"]),
            equals: "original parity-valid source state"
        )
    }

    private static func validateSourceAligned(_ value: ASHLUTStrictJSONValueV2?) throws {
        let fields = try object(value, keys: [
            "exact", "predicate", "primary_message", "primary_descriptor",
            "secondary", "denoising"
        ])
        try require(boolean(fields["exact"]), equals: true)
        try require(
            string(fields["predicate"]),
            equals: "source_aligned_rational with horizontal phase zero and vertical phase zero"
        )
        try require(integer(fields["primary_message"]), equals: 0)
        try require(integer(fields["primary_descriptor"]), equals: 0)
        try require(string(fields["secondary"]), equals: "inactive")
        try require(boolean(fields["denoising"]), equals: false)
    }

    private static func object(
        _ value: ASHLUTStrictJSONValueV2?,
        keys: [String]
    ) throws -> [String: ASHLUTStrictJSONValueV2] {
        guard case .object(let object)? = value,
              Set(object.keys) == Set(keys),
              object.count == keys.count else {
            throw ASHLUTLockedConfigurationJSONErrorV2.fieldSetMismatch
        }
        return object
    }

    private static func array(
        _ value: ASHLUTStrictJSONValueV2?
    ) throws -> [ASHLUTStrictJSONValueV2] {
        guard case .array(let array)? = value else {
            throw ASHLUTLockedConfigurationJSONErrorV2.invalidValue
        }
        return array
    }

    private static func string(_ value: ASHLUTStrictJSONValueV2?) throws -> String {
        guard case .string(let string)? = value else {
            throw ASHLUTLockedConfigurationJSONErrorV2.invalidValue
        }
        return string
    }

    private static func integer(_ value: ASHLUTStrictJSONValueV2?) throws -> Int64 {
        guard case .integer(let integer)? = value else {
            throw ASHLUTLockedConfigurationJSONErrorV2.invalidValue
        }
        return integer
    }

    private static func boolean(_ value: ASHLUTStrictJSONValueV2?) throws -> Bool {
        guard case .boolean(let boolean)? = value else {
            throw ASHLUTLockedConfigurationJSONErrorV2.invalidValue
        }
        return boolean
    }

    private static func uint8(_ value: ASHLUTStrictJSONValueV2?) throws -> UInt8 {
        guard let result = UInt8(exactly: try integer(value)) else {
            throw ASHLUTLockedConfigurationJSONErrorV2.invalidValue
        }
        return result
    }

    private static func uint16(_ value: ASHLUTStrictJSONValueV2?) throws -> UInt16 {
        guard let result = UInt16(exactly: try integer(value)) else {
            throw ASHLUTLockedConfigurationJSONErrorV2.invalidValue
        }
        return result
    }

    private static func uint32(_ value: ASHLUTStrictJSONValueV2?) throws -> UInt32 {
        guard let result = UInt32(exactly: try integer(value)) else {
            throw ASHLUTLockedConfigurationJSONErrorV2.invalidValue
        }
        return result
    }

    private static func require<T: Equatable>(_ value: T, equals expected: T) throws {
        guard value == expected else {
            throw ASHLUTLockedConfigurationJSONErrorV2.invalidValue
        }
    }
}
