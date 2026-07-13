import Foundation

// P06 offline compiler and immutable LUT runtime types.

// MARK: - P06 state-conditioned LUT compiler core

enum ASHLUTContextV2: UInt8, CaseIterable, Sendable {
    case spatialOnly
    case temporalPrevious
    case temporalNext
    case temporalBidirectional
}

enum ASHLUTCanonicalActionV2: UInt8, CaseIterable, Sendable {
    case zero
    case plus
    case minus

    var semanticStep: Int8 {
        switch self {
        case .zero: 0
        case .plus: 1
        case .minus: -1
        }
    }

    var massNumeratorOverFour: UInt16 {
        self == .zero ? 2 : 1
    }
}

struct ASHLUTSemanticDeltaV2: Equatable, Sendable {
    let orientation: Int8
    let support: Int8
    let detail: Int8
    let regularization: Int8
}

struct ASHLUTCanonicalPathV2: Equatable, Sendable {
    let ordinal: UInt8
    let actions: [ASHLUTCanonicalActionV2]
    let message: ASHMessage
    let branchMassNumerator: UInt16
    let semanticDelta: ASHLUTSemanticDeltaV2
}

struct ASHLUTHashV2: Equatable, Hashable, Sendable {
    static let byteCount = 32

    let bytes: [UInt8]

    init(hex: String) throws {
        let characters = Array(hex.utf8)
        guard characters.count == Self.byteCount * 2 else {
            throw ASHLUTCompilerErrorV2.invalidHash
        }
        var decoded: [UInt8] = []
        decoded.reserveCapacity(Self.byteCount)
        for offset in stride(from: 0, to: characters.count, by: 2) {
            guard let high = Self.hexDigit(characters[offset]),
                  let low = Self.hexDigit(characters[offset + 1]) else {
                throw ASHLUTCompilerErrorV2.invalidHash
            }
            decoded.append((high << 4) | low)
        }
        guard decoded.contains(where: { $0 != 0 }) else {
            throw ASHLUTCompilerErrorV2.invalidHash
        }
        bytes = decoded
    }

    init(validatedBytes: [UInt8]) {
        precondition(validatedBytes.count == Self.byteCount)
        bytes = validatedBytes
    }

    var hex: String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func hexDigit(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: byte - 48
        case 97...102: byte - 87
        default: nil
        }
    }
}

struct ASHLUTLockedOperatorParametersV2: Equatable, Sendable {
    let anisotropyStrengthQ12: UInt16
    let minimumAnisotropicMagnitudeUNorm15: UInt16
    let minimumAnisotropicCoherenceUNorm15: UInt16
    let detailGainQ12: UInt16
    let relaxedLimiterAlphaQ12: UInt16
    let riskSuppressionUNorm15: UInt16
    let lowPassRadiusQ8x8: UInt16
    let weightEpsilonF32Bits: UInt32

    init(
        anisotropyStrengthQ12: UInt16,
        minimumAnisotropicMagnitudeUNorm15: UInt16,
        minimumAnisotropicCoherenceUNorm15: UInt16,
        detailGainQ12: UInt16,
        relaxedLimiterAlphaQ12: UInt16,
        riskSuppressionUNorm15: UInt16,
        lowPassRadiusQ8x8: UInt16,
        weightEpsilonF32Bits: UInt32
    ) throws {
        guard [0, 1_024, 2_048, 3_072, 4_096].contains(Int(anisotropyStrengthQ12)),
              [819, 1_638, 3_277, 4_915].contains(Int(minimumAnisotropicMagnitudeUNorm15)),
              [3_277, 4_915, 8_192, 12_288].contains(Int(minimumAnisotropicCoherenceUNorm15)),
              [0, 384, 768, 1_152, 1_536].contains(Int(detailGainQ12)),
              [0, 128, 256, 384, 512].contains(Int(relaxedLimiterAlphaQ12)),
              [16_384, 21_299, 26_214].contains(Int(riskSuppressionUNorm15)),
              [384, 512, 640].contains(Int(lowPassRadiusQ8x8)),
              weightEpsilonF32Bits == 730_643_660 else {
            throw ASHLUTCompilerErrorV2.invalidLockedConfiguration
        }
        self.anisotropyStrengthQ12 = anisotropyStrengthQ12
        self.minimumAnisotropicMagnitudeUNorm15 = minimumAnisotropicMagnitudeUNorm15
        self.minimumAnisotropicCoherenceUNorm15 = minimumAnisotropicCoherenceUNorm15
        self.detailGainQ12 = detailGainQ12
        self.relaxedLimiterAlphaQ12 = relaxedLimiterAlphaQ12
        self.riskSuppressionUNorm15 = riskSuppressionUNorm15
        self.lowPassRadiusQ8x8 = lowPassRadiusQ8x8
        self.weightEpsilonF32Bits = weightEpsilonF32Bits
    }
}

struct ASHLUTLockedSemanticStepsV2: Equatable, Sendable {
    let orientationSectorStep: UInt8
    let supportRadiusStepQ8x8: UInt16
    let detailGainStepQ12: UInt16
    let regularizationStepQ12: UInt16

    init(
        orientationSectorStep: UInt8,
        supportRadiusStepQ8x8: UInt16,
        detailGainStepQ12: UInt16,
        regularizationStepQ12: UInt16
    ) throws {
        guard orientationSectorStep == 1,
              [32, 64, 96].contains(Int(supportRadiusStepQ8x8)),
              [64, 128, 256].contains(Int(detailGainStepQ12)),
              [32, 64, 128].contains(Int(regularizationStepQ12)) else {
            throw ASHLUTCompilerErrorV2.invalidLockedConfiguration
        }
        self.orientationSectorStep = orientationSectorStep
        self.supportRadiusStepQ8x8 = supportRadiusStepQ8x8
        self.detailGainStepQ12 = detailGainStepQ12
        self.regularizationStepQ12 = regularizationStepQ12
    }
}

enum ASHLUTPlaneRoleV2: Equatable, Sendable {
    case luma
    case chroma
}

struct ASHLUTLockedRouteSelectionV2: Equatable, Sendable {
    let lumaCoordinatePolicy: ASHSpatialCoordinatePolicyV2
    let chromaCoordinatePolicy: ASHSpatialCoordinatePolicyV2
    let analysisGridSourceStep: UInt8

    init(
        lumaCoordinatePolicy: ASHSpatialCoordinatePolicyV2,
        chromaCoordinatePolicy: ASHSpatialCoordinatePolicyV2,
        analysisGridSourceStep: UInt8
    ) throws {
        guard [1, 2, 4].contains(analysisGridSourceStep) else {
            throw ASHLUTCompilerErrorV2.invalidLockedConfiguration
        }
        self.lumaCoordinatePolicy = lumaCoordinatePolicy
        self.chromaCoordinatePolicy = chromaCoordinatePolicy
        self.analysisGridSourceStep = analysisGridSourceStep
    }

    func coordinatePolicy(for planeRole: ASHLUTPlaneRoleV2) -> ASHSpatialCoordinatePolicyV2 {
        switch planeRole {
        case .luma: lumaCoordinatePolicy
        case .chroma: chromaCoordinatePolicy
        }
    }

    var bothPlanesAreSourceAligned: Bool {
        lumaCoordinatePolicy == .sourceAlignedRational
            && chromaCoordinatePolicy == .sourceAlignedRational
    }
}

struct ASHLUTLockedRoutesV2: Equatable, Sendable {
    let direct2x: ASHLUTLockedRouteSelectionV2
    let direct3Over2: ASHLUTLockedRouteSelectionV2

    func selection(for route: ASHSpatialRouteV2) -> ASHLUTLockedRouteSelectionV2 {
        switch route {
        case .direct2x: direct2x
        case .direct3Over2: direct3Over2
        }
    }
}

struct ASHLUTLockedCompilerPolicyV2: Equatable, Sendable {
    let penaltyDecayDenominator: UInt16
    let orientationPenaltyStep: UInt16
    let supportPenaltyStep: UInt16
    let detailPenaltyStep: UInt16
    let regularizationPenaltyStep: UInt16
    let unsupportedSupportExpansionPenalty: UInt16
    let coherentSupportReductionPenalty: UInt16
    let unsupportedDetailIncreasePenalty: UInt16
    let supportedDetailReductionPenalty: UInt16
    let relaxationUnderRiskPenalty: UInt16
    let phaseKernelMismatchPenalty: UInt16
    let confidenceThresholdUNorm16: UInt16
    let penaltyToWeight: [UInt16]

    init(
        penaltyDecayDenominator: UInt16,
        orientationPenaltyStep: UInt16,
        supportPenaltyStep: UInt16,
        detailPenaltyStep: UInt16,
        regularizationPenaltyStep: UInt16,
        unsupportedSupportExpansionPenalty: UInt16,
        coherentSupportReductionPenalty: UInt16,
        unsupportedDetailIncreasePenalty: UInt16,
        supportedDetailReductionPenalty: UInt16,
        relaxationUnderRiskPenalty: UInt16,
        phaseKernelMismatchPenalty: UInt16,
        confidenceThresholdUNorm16: UInt16,
        penaltyToWeight: [UInt16]
    ) throws {
        let expectedPenaltyTable = (0..<256).map { index -> UInt16 in
            let numerator = UInt32(UInt16.max) * UInt32(penaltyDecayDenominator)
            let denominator = UInt32(penaltyDecayDenominator) + UInt32(index)
            return UInt16((numerator + (denominator / 2)) / denominator)
        }
        guard [16, 32, 64, 128].contains(Int(penaltyDecayDenominator)),
              [0, 2, 4, 8].contains(Int(orientationPenaltyStep)),
              [0, 4, 8, 16].contains(Int(supportPenaltyStep)),
              [0, 4, 8, 16].contains(Int(detailPenaltyStep)),
              [0, 4, 8, 16].contains(Int(regularizationPenaltyStep)),
              [16, 32, 64, 96].contains(Int(unsupportedSupportExpansionPenalty)),
              [8, 16, 32, 64].contains(Int(coherentSupportReductionPenalty)),
              [16, 32, 64, 96].contains(Int(unsupportedDetailIncreasePenalty)),
              [8, 16, 32, 64].contains(Int(supportedDetailReductionPenalty)),
              [32, 64, 96, 128].contains(Int(relaxationUnderRiskPenalty)),
              [0, 4, 8, 16].contains(Int(phaseKernelMismatchPenalty)),
              [16_384, 24_576, 32_768, 36_044, 40_959, 49_151].contains(Int(confidenceThresholdUNorm16)),
              penaltyToWeight == expectedPenaltyTable else {
            throw ASHLUTCompilerErrorV2.invalidPenaltyTable
        }
        self.penaltyDecayDenominator = penaltyDecayDenominator
        self.orientationPenaltyStep = orientationPenaltyStep
        self.supportPenaltyStep = supportPenaltyStep
        self.detailPenaltyStep = detailPenaltyStep
        self.regularizationPenaltyStep = regularizationPenaltyStep
        self.unsupportedSupportExpansionPenalty = unsupportedSupportExpansionPenalty
        self.coherentSupportReductionPenalty = coherentSupportReductionPenalty
        self.unsupportedDetailIncreasePenalty = unsupportedDetailIncreasePenalty
        self.supportedDetailReductionPenalty = supportedDetailReductionPenalty
        self.relaxationUnderRiskPenalty = relaxationUnderRiskPenalty
        self.phaseKernelMismatchPenalty = phaseKernelMismatchPenalty
        self.confidenceThresholdUNorm16 = confidenceThresholdUNorm16
        self.penaltyToWeight = penaltyToWeight
    }
}

struct ASHLUTLockedConfigurationV2: Equatable, Sendable {
    static let schemaVersion = "1.0.0"
    static let status = "locked"
    static let topTwo = 2

    let configurationID: String
    let mappingSHA256: ASHLUTHashV2
    let operatorBankSHA256: ASHLUTHashV2
    let metricPolicySHA256: ASHLUTHashV2
    let compilerInputsSHA256: ASHLUTHashV2
    let calibrationPlanSHA256: ASHLUTHashV2
    let corpusLockBundleSHA256: ASHLUTHashV2
    let boundaryMode: ASHSpatialBoundaryModeV2
    let operatorParameters: ASHLUTLockedOperatorParametersV2
    let semanticSteps: ASHLUTLockedSemanticStepsV2
    let compilerPolicy: ASHLUTLockedCompilerPolicyV2
    let routes: ASHLUTLockedRoutesV2

    init(
        configurationID: String,
        mappingSHA256: ASHLUTHashV2,
        operatorBankSHA256: ASHLUTHashV2,
        metricPolicySHA256: ASHLUTHashV2,
        compilerInputsSHA256: ASHLUTHashV2,
        calibrationPlanSHA256: ASHLUTHashV2,
        corpusLockBundleSHA256: ASHLUTHashV2,
        boundaryMode: ASHSpatialBoundaryModeV2,
        operatorParameters: ASHLUTLockedOperatorParametersV2,
        semanticSteps: ASHLUTLockedSemanticStepsV2,
        compilerPolicy: ASHLUTLockedCompilerPolicyV2,
        routes: ASHLUTLockedRoutesV2
    ) throws {
        guard Self.isValidConfigurationID(configurationID) else {
            throw ASHLUTCompilerErrorV2.invalidLockedConfiguration
        }
        self.configurationID = configurationID
        self.mappingSHA256 = mappingSHA256
        self.operatorBankSHA256 = operatorBankSHA256
        self.metricPolicySHA256 = metricPolicySHA256
        self.compilerInputsSHA256 = compilerInputsSHA256
        self.calibrationPlanSHA256 = calibrationPlanSHA256
        self.corpusLockBundleSHA256 = corpusLockBundleSHA256
        self.boundaryMode = boundaryMode
        self.operatorParameters = operatorParameters
        self.semanticSteps = semanticSteps
        self.compilerPolicy = compilerPolicy
        self.routes = routes
    }

    func routeSelection(for route: ASHSpatialRouteV2) -> ASHLUTLockedRouteSelectionV2 {
        routes.selection(for: route)
    }

    private static func isValidConfigurationID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (3...128).contains(bytes.count),
              let first = bytes.first,
              (48...57).contains(first) || (97...122).contains(first) else {
            return false
        }
        return bytes.dropFirst().allSatisfy {
            (48...57).contains($0)
                || (97...122).contains($0)
                || [45, 46, 95].contains($0)
        }
    }
}

enum ASHLUTCompilerErrorV2: Error, Equatable, Sendable {
    case invalidHash
    case invalidPenaltyTable
    case invalidLockedConfiguration
    case invalidPhase
    case invalidStateOrdinal
    case affineRecoveryFailed
    case noCompatibleCandidate
    case entryCountMismatch
    case arithmeticOverflow
}

struct ASHLUTParameterSlotV2: Equatable, Sendable {
    static let activeFlag: UInt16 = 1 << 0
    static let positiveDetailFlag: UInt16 = 1 << 1
    static let relaxedLimiterFlag: UInt16 = 1 << 2
    static let temporalContributionFlag: UInt16 = 1 << 3
    static let sourceAlignedPreservationFlag: UInt16 = 1 << 4
    static let denoisingFlag: UInt16 = 1 << 5

    static let inactive = ASHLUTParameterSlotV2(
        anisotropyStrengthQ12: 0,
        minimumAnisotropicMagnitudeUNorm15: 0,
        minimumAnisotropicCoherenceUNorm15: 0,
        detailGainQ12: 0,
        relaxedLimiterAlphaQ12: 0,
        riskSuppressionUNorm15: 0,
        supportRadiusQ8x8: 0,
        weightEpsilonF32Bits: 0,
        delta: ASHLUTSemanticDeltaV2(orientation: 0, support: 0, detail: 0, regularization: 0),
        flags: 0
    )

    let anisotropyStrengthQ12: UInt16
    let minimumAnisotropicMagnitudeUNorm15: UInt16
    let minimumAnisotropicCoherenceUNorm15: UInt16
    let detailGainQ12: UInt16
    let relaxedLimiterAlphaQ12: UInt16
    let riskSuppressionUNorm15: UInt16
    let supportRadiusQ8x8: UInt16
    let weightEpsilonF32Bits: UInt32
    let delta: ASHLUTSemanticDeltaV2
    let flags: UInt16

    var isActive: Bool { flags & Self.activeFlag != 0 }
}

struct ASHLUTParameterPairV2: Equatable, Sendable {
    let primary: ASHLUTParameterSlotV2
    let secondary: ASHLUTParameterSlotV2
    let confidenceThresholdUNorm16: UInt16
    let lumaCoordinatePolicy: ASHSpatialCoordinatePolicyV2
    let chromaCoordinatePolicy: ASHSpatialCoordinatePolicyV2
    let boundaryMode: ASHSpatialBoundaryModeV2
}

struct ASHLUTCompiledCandidateV2: Equatable, Sendable {
    let message: ASHMessage
    let affineState: ASHState
    let descriptorID: UInt8
    let representativePathOrdinal: UInt8
    let representativePenalty: UInt16
    let aggregatedWeight: UInt32
    let semanticDelta: ASHLUTSemanticDeltaV2
    let detailGainQ12: UInt16
    let relaxedLimiterAlphaQ12: UInt16
    let supportRadiusQ8x8: UInt16
}

struct ASHLUTCompiledEntryV2: Equatable, Sendable {
    let logicalIndex: Int
    let sourceState: ASHState
    let validStateOrdinal: UInt16
    let phaseOrdinal: UInt16
    let context: ASHLUTContextV2
    let primary: ASHLUTCompiledCandidateV2
    let secondary: ASHLUTCompiledCandidateV2?
    let primaryWeightUNorm16: UInt16
    let secondaryWeightUNorm16: UInt16
    let marginUNorm16: UInt16
    let sourceAlignedExact: Bool
    let temporalForcedSpatial: Bool
    let parameters: ASHLUTParameterPairV2

    var operatorEvaluationCount: Int { secondary == nil ? 1 : 2 }
}

struct ASHLUTCompilationV2: Equatable, Sendable {
    let route: ASHSpatialRouteV2
    let configuration: ASHLUTLockedConfigurationV2
    let entries: [ASHLUTCompiledEntryV2]
    let offlinePathEvaluationCount: Int
    let runtimeTreeGenerationCount: Int

    var maximumOperatorEvaluations: Int {
        entries.map(\.operatorEvaluationCount).max() ?? 0
    }
}

enum ASHLUTStateOrdinalTableV2 {
    static let invalidOrdinal = UInt16.max

    static let validStates: [ASHState] = {
        (UInt16(0)..<UInt16(1 << ASHState.bitCount)).compactMap { raw in
            let state = ASHState(validatedRawValue: raw)
            return state.hasValidIntegrity ? state : nil
        }
    }()

    static let rawToOrdinal: [UInt16] = {
        var table = Array(repeating: invalidOrdinal, count: 1 << ASHState.bitCount)
        for (ordinal, state) in validStates.enumerated() {
            table[Int(state.rawValue)] = UInt16(ordinal)
        }
        return table
    }()

    static func ordinal(for state: ASHState) -> UInt16? {
        let ordinal = rawToOrdinal[Int(state.rawValue)]
        return ordinal == invalidOrdinal ? nil : ordinal
    }
}
