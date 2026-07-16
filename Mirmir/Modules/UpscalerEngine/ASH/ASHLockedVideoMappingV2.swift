import CryptoKit
import Foundation

enum ASHLockedVideoMappingV2Error: Error, Equatable, Sendable {
    case hashMismatch
    case nonCanonicalEncoding
    case fieldSetMismatch
    case invalidValue
}

enum ASHLockedArtifactStatusV2: String, Equatable, Sendable {
    case calibrationCandidate = "calibration_candidate"
    case lockedBeforeP07 = "locked_before_p07"
}

/// Hash-bound analyzer inputs for one P06 calibration candidate.
///
/// The initializer remains private so callers cannot pair arbitrary analyzer
/// thresholds with a mapping hash. Every value must pass the strict JSON loader.
struct ASHLockedVideoMappingV2: Equatable, Sendable {
    let sha256: ASHLUTHashV2
    let status: ASHLockedArtifactStatusV2
    let configurationID: String
    let mappingSeedSHA256: ASHLUTHashV2
    let candidateVectorSHA256: ASHLUTHashV2
    let sharedBankConfigurationSHA256: ASHLUTHashV2
    let calibrationSelectionSHA256: ASHLUTHashV2?
    let selectedEvaluationSHA256: ASHLUTHashV2?
    let analyzerConfiguration: ASHVideoAnalyzerV2DevelopmentConfiguration
    let chromaSiting: ASHChromaSitingV2
    let boundaryMode: ASHSpatialBoundaryModeV2
    let direct2xAnalysisGridSourceStep: UInt8
    let direct3Over2AnalysisGridSourceStep: UInt8
    let immutableBytes: Data

    private init(
        sha256: ASHLUTHashV2,
        status: ASHLockedArtifactStatusV2,
        configurationID: String,
        mappingSeedSHA256: ASHLUTHashV2,
        candidateVectorSHA256: ASHLUTHashV2,
        sharedBankConfigurationSHA256: ASHLUTHashV2,
        calibrationSelectionSHA256: ASHLUTHashV2?,
        selectedEvaluationSHA256: ASHLUTHashV2?,
        analyzerConfiguration: ASHVideoAnalyzerV2DevelopmentConfiguration,
        chromaSiting: ASHChromaSitingV2,
        boundaryMode: ASHSpatialBoundaryModeV2,
        direct2xAnalysisGridSourceStep: UInt8,
        direct3Over2AnalysisGridSourceStep: UInt8,
        immutableBytes: Data
    ) {
        self.sha256 = sha256
        self.status = status
        self.configurationID = configurationID
        self.mappingSeedSHA256 = mappingSeedSHA256
        self.candidateVectorSHA256 = candidateVectorSHA256
        self.sharedBankConfigurationSHA256 = sharedBankConfigurationSHA256
        self.calibrationSelectionSHA256 = calibrationSelectionSHA256
        self.selectedEvaluationSHA256 = selectedEvaluationSHA256
        self.analyzerConfiguration = analyzerConfiguration
        self.chromaSiting = chromaSiting
        self.boundaryMode = boundaryMode
        self.direct2xAnalysisGridSourceStep = direct2xAnalysisGridSourceStep
        self.direct3Over2AnalysisGridSourceStep = direct3Over2AnalysisGridSourceStep
        self.immutableBytes = immutableBytes
    }

    func validate(configuration: ASHLUTLockedConfigurationV2) throws {
        guard sha256 == configuration.mappingSHA256 else {
            throw ASHLockedVideoMappingV2Error.hashMismatch
        }
        guard configurationID == configuration.configurationID,
              boundaryMode == configuration.boundaryMode,
              direct2xAnalysisGridSourceStep
                == configuration.routes.direct2x.analysisGridSourceStep,
              direct3Over2AnalysisGridSourceStep
                == configuration.routes.direct3Over2.analysisGridSourceStep else {
            throw ASHLockedVideoMappingV2Error.invalidValue
        }
    }

    static func load(
        _ data: Data,
        expectedSHA256: ASHLUTHashV2
    ) throws -> ASHLockedVideoMappingV2 {
        let observedSHA256 = ASHLUTHashV2(
            validatedBytes: Array(SHA256.hash(data: data))
        )
        guard observedSHA256 == expectedSHA256 else {
            throw ASHLockedVideoMappingV2Error.hashMismatch
        }

        var parser = ASHLUTStrictJSONParserV2(data: data)
        let parsed = try parser.parse()
        guard ASHLUTCanonicalJSONV2.encode(parsed) == data else {
            throw ASHLockedVideoMappingV2Error.nonCanonicalEncoding
        }
        let root = try object(parsed, keys: [
            "schema_version", "status", "mapping_id", "configuration_id",
            "mapping_seed_sha256", "candidate_vector_sha256",
            "shared_bank_configuration_sha256", "selection_binding",
            "canonical_core_unchanged", "input_contract", "boundary_mode",
            "analysis_grid_source_steps", "thresholds_unorm15",
            "analysis_epsilon_q0_30", "risk_weights_unorm15",
            "chroma_edge_confidence_unorm15"
        ])
        try require(root["schema_version"], string: "1.0.0")
        try require(root["mapping_id"], string: "ash-video-mapping-v2")
        try require(root["canonical_core_unchanged"], boolean: true)
        let status = try artifactStatus(root["status"])
        let configurationID = try string(root["configuration_id"])
        guard validConfigurationID(configurationID) else {
            throw ASHLockedVideoMappingV2Error.invalidValue
        }
        let selection = try selectionBinding(root["selection_binding"], status: status)
        let inputContract = try object(root["input_contract"], keys: [
            "pixel_format", "matrix", "range", "chroma_siting", "bit_depth",
            "subsampling"
        ])
        try require(inputContract["pixel_format"], string: "420v")
        try require(inputContract["matrix"], string: "BT.709")
        try require(inputContract["range"], string: "video")
        try require(inputContract["chroma_siting"], string: "left")
        try require(inputContract["bit_depth"], integer: 8)
        try require(inputContract["subsampling"], string: "4:2:0")
        let boundaryMode: ASHSpatialBoundaryModeV2
        switch try string(root["boundary_mode"]) {
        case "clamp": boundaryMode = .clamp
        case "mirror_reflect101": boundaryMode = .mirrorReflect101
        default: throw ASHLockedVideoMappingV2Error.invalidValue
        }
        let gridSteps = try object(root["analysis_grid_source_steps"], keys: [
            "direct_2x", "direct_3_over_2"
        ])
        let direct2xStep = try analysisGridStep(gridSteps["direct_2x"])
        let direct3Over2Step = try analysisGridStep(gridSteps["direct_3_over_2"])
        let analyzer = try analyzerConfiguration(root)
        return try ASHLockedVideoMappingV2(
            sha256: observedSHA256,
            status: status,
            configurationID: configurationID,
            mappingSeedSHA256: ASHLUTHashV2(
                hex: string(root["mapping_seed_sha256"])
            ),
            candidateVectorSHA256: ASHLUTHashV2(
                hex: string(root["candidate_vector_sha256"])
            ),
            sharedBankConfigurationSHA256: ASHLUTHashV2(
                hex: string(root["shared_bank_configuration_sha256"])
            ),
            calibrationSelectionSHA256: selection.calibrationSelection,
            selectedEvaluationSHA256: selection.selectedEvaluation,
            analyzerConfiguration: analyzer,
            chromaSiting: .left,
            boundaryMode: boundaryMode,
            direct2xAnalysisGridSourceStep: direct2xStep,
            direct3Over2AnalysisGridSourceStep: direct3Over2Step,
            immutableBytes: data
        )
    }

    private static func analyzerConfiguration(
        _ root: [String: ASHLUTStrictJSONValueV2]
    ) throws -> ASHVideoAnalyzerV2DevelopmentConfiguration {
        let thresholds = try object(root["thresholds_unorm15"], keys: [
            "edge_present", "coherent_structure", "texture_high_frequency",
            "alias_or_ringing_risk", "temporal_support_valid",
            "chroma_luma_structure_aligned"
        ])
        let bands = try ASHVideoAnalyzerV2DevelopmentBands(
            edgePresent: band(thresholds["edge_present"]),
            coherentStructure: band(thresholds["coherent_structure"]),
            textureHighFrequency: band(thresholds["texture_high_frequency"]),
            aliasOrRingingRisk: aliasRiskBand(thresholds["alias_or_ringing_risk"]),
            temporalSupportValid: fixedTemporalBand(
                thresholds["temporal_support_valid"]
            ),
            chromaLumaStructureAligned: band(
                thresholds["chroma_luma_structure_aligned"]
            )
        )
        let epsilonQ0x30 = try integer(root["analysis_epsilon_q0_30"])
        guard [1, 2, 4, 8, 16].contains(epsilonQ0x30) else {
            throw ASHLockedVideoMappingV2Error.invalidValue
        }
        let risk = try object(root["risk_weights_unorm15"], keys: [
            "laplacian", "alternating_difference"
        ])
        let laplacian = try unorm15(risk["laplacian"])
        let alternating = try unorm15(risk["alternating_difference"])
        guard [8_192, 16_384, 24_575].contains(laplacian),
              laplacian + alternating == 32_767 else {
            throw ASHLockedVideoMappingV2Error.invalidValue
        }
        let confidence = try unorm15(root["chroma_edge_confidence_unorm15"])
        guard [1_638, 3_277, 4_915, 6_553].contains(confidence) else {
            throw ASHLockedVideoMappingV2Error.invalidValue
        }
        return try ASHVideoAnalyzerV2DevelopmentConfiguration(
            bands: bands,
            epsilon: Double(epsilonQ0x30) / 1_073_741_824.0,
            riskWeights: ASHVideoAnalyzerV2RiskWeights(
                laplacian: Double(laplacian) / 32_767.0,
                alternatingDifference: Double(alternating) / 32_767.0
            ),
            chromaEdgeConfidenceThreshold: Double(confidence) / 32_767.0
        )
    }

    private static func fixedTemporalBand(
        _ value: ASHLUTStrictJSONValueV2?
    ) throws -> ASHVideoAnalyzerV2ThresholdBand {
        let result = try encodedBand(value)
        guard result.low == 32_767, result.high == 32_767 else {
            throw ASHLockedVideoMappingV2Error.invalidValue
        }
        return try decodedBand(result)
    }

    private static func band(
        _ value: ASHLUTStrictJSONValueV2?
    ) throws -> ASHVideoAnalyzerV2ThresholdBand {
        let result = try encodedBand(value)
        guard [3_277, 4_915, 6_553, 8_192, 9_830].contains(result.low),
              [9_830, 11_468, 13_107, 14_745, 16_384].contains(result.high),
              result.high - result.low >= 3_277 else {
            throw ASHLockedVideoMappingV2Error.invalidValue
        }
        return try decodedBand(result)
    }

    private static func aliasRiskBand(
        _ value: ASHLUTStrictJSONValueV2?
    ) throws -> ASHVideoAnalyzerV2ThresholdBand {
        let result = try encodedBand(value)
        guard [0, 3_277, 4_915, 6_553, 8_192, 9_830].contains(result.low),
              [3_277, 9_830, 11_468, 13_107, 14_745, 16_384].contains(result.high),
              result.high - result.low >= 3_277 else {
            throw ASHLockedVideoMappingV2Error.invalidValue
        }
        return try decodedBand(result)
    }

    private static func artifactStatus(
        _ value: ASHLUTStrictJSONValueV2?
    ) throws -> ASHLockedArtifactStatusV2 {
        guard let status = try ASHLockedArtifactStatusV2(rawValue: string(value)) else {
            throw ASHLockedVideoMappingV2Error.invalidValue
        }
        return status
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
                throw ASHLockedVideoMappingV2Error.invalidValue
            }
            return (nil, nil)
        case .lockedBeforeP07:
            return try (
                ASHLUTHashV2(hex: string(fields["calibration_selection_sha256"])),
                ASHLUTHashV2(hex: string(fields["selected_evaluation_sha256"]))
            )
        }
    }

    private static func analysisGridStep(
        _ value: ASHLUTStrictJSONValueV2?
    ) throws -> UInt8 {
        let result = try integer(value)
        guard [1, 2, 4].contains(result) else {
            throw ASHLockedVideoMappingV2Error.invalidValue
        }
        return UInt8(result)
    }

    private static func validConfigurationID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (3...128).contains(bytes.count),
              let first = bytes.first,
              (first >= 97 && first <= 122) || (first >= 48 && first <= 57) else {
            return false
        }
        return bytes.allSatisfy {
            ($0 >= 97 && $0 <= 122)
                || ($0 >= 48 && $0 <= 57)
                || [45, 46, 95].contains($0)
        }
    }

    private static func encodedBand(
        _ value: ASHLUTStrictJSONValueV2?
    ) throws -> (low: Int, high: Int) {
        let fields = try object(value, keys: ["low", "high"])
        let low = try unorm15(fields["low"])
        let high = try unorm15(fields["high"])
        guard low <= high else {
            throw ASHLockedVideoMappingV2Error.invalidValue
        }
        return (low, high)
    }

    private static func decodedBand(
        _ value: (low: Int, high: Int)
    ) throws -> ASHVideoAnalyzerV2ThresholdBand {
        try ASHVideoAnalyzerV2ThresholdBand(
            low: Double(value.low) / 32_767.0,
            high: Double(value.high) / 32_767.0
        )
    }

    private static func unorm15(_ value: ASHLUTStrictJSONValueV2?) throws -> Int {
        let result = try integer(value)
        guard (0...32_767).contains(result) else {
            throw ASHLockedVideoMappingV2Error.invalidValue
        }
        return result
    }

    private static func object(
        _ value: ASHLUTStrictJSONValueV2?,
        keys: Set<String>
    ) throws -> [String: ASHLUTStrictJSONValueV2] {
        guard case .object(let object)? = value, Set(object.keys) == keys else {
            throw ASHLockedVideoMappingV2Error.fieldSetMismatch
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
            throw ASHLockedVideoMappingV2Error.invalidValue
        }
        return string
    }

    private static func integer(_ value: ASHLUTStrictJSONValueV2?) throws -> Int {
        guard case .integer(let integer)? = value,
              let result = Int(exactly: integer) else {
            throw ASHLockedVideoMappingV2Error.invalidValue
        }
        return result
    }

    private static func require(
        _ value: ASHLUTStrictJSONValueV2?,
        string expected: String
    ) throws {
        guard try string(value) == expected else {
            throw ASHLockedVideoMappingV2Error.invalidValue
        }
    }

    private static func require(
        _ value: ASHLUTStrictJSONValueV2?,
        integer expected: Int
    ) throws {
        guard try integer(value) == expected else {
            throw ASHLockedVideoMappingV2Error.invalidValue
        }
    }

    private static func require(
        _ value: ASHLUTStrictJSONValueV2?,
        boolean expected: Bool
    ) throws {
        guard case .boolean(let observed)? = value, observed == expected else {
            throw ASHLockedVideoMappingV2Error.invalidValue
        }
    }
}
