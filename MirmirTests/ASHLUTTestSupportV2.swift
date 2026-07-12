import Foundation
@testable import Mirmir

struct ASHLUTTestFixtureV2 {
    let configuration: ASHLUTLockedConfigurationV2
    let compilation: ASHLUTCompilationV2
    let artifact: ASHLUTBinaryArtifactV2
}

enum ASHLUTTestSupportV2 {
    private static let sourceDirect2xResult = Result {
        let configuration = try ASHLUTTestSupportV2.sharedConfiguration()
        let compilation = try ASHLUTLeafCompilerV2.compile(
            route: .direct2x,
            configuration: configuration
        )
        let artifact = try ASHLUTBinaryCodecV2.serialize(compilation)
        return ASHLUTTestFixtureV2(
            configuration: configuration,
            compilation: compilation,
            artifact: artifact
        )
    }

    private static let halfPixelDirect3Over2Result = Result {
        let configuration = try ASHLUTTestSupportV2.sharedConfiguration()
        let compilation = try ASHLUTLeafCompilerV2.compile(
            route: .direct3Over2,
            configuration: configuration
        )
        let artifact = try ASHLUTBinaryCodecV2.serialize(compilation)
        return ASHLUTTestFixtureV2(
            configuration: configuration,
            compilation: compilation,
            artifact: artifact
        )
    }

    static func sourceDirect2x() throws -> ASHLUTTestFixtureV2 {
        try sourceDirect2xResult.get()
    }

    static func halfPixelDirect3Over2() throws -> ASHLUTTestFixtureV2 {
        try halfPixelDirect3Over2Result.get()
    }

    static func sharedConfiguration() throws -> ASHLUTLockedConfigurationV2 {
        try ASHLUTLockedConfigurationJSONLoaderV2.load(sharedLockedInputData())
    }

    static func sharedLockedInputData() throws -> Data {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try Data(contentsOf: repository.appendingPathComponent(
            "validation/calibration_v2/fixtures/locked-compiler-input-shared-v1.json"
        ))
    }

    static func configuration(
        policy: ASHSpatialCoordinatePolicyV2
    ) throws -> ASHLUTLockedConfigurationV2 {
        let operatorParameters = try ASHLUTLockedOperatorParametersV2(
            anisotropyStrengthQ12: 2_048,
            minimumAnisotropicMagnitudeUNorm15: 1_638,
            minimumAnisotropicCoherenceUNorm15: 8_192,
            detailGainQ12: 768,
            relaxedLimiterAlphaQ12: 256,
            riskSuppressionUNorm15: 21_299,
            lowPassRadiusQ8x8: 640,
            weightEpsilonF32Bits: 730_643_660
        )
        let semanticSteps = try ASHLUTLockedSemanticStepsV2(
            orientationSectorStep: 1,
            supportRadiusStepQ8x8: 64,
            detailGainStepQ12: 128,
            regularizationStepQ12: 64
        )
        let compilerPolicy = try compilerPolicy()
        let routes = ASHLUTLockedRoutesV2(
            direct2x: try ASHLUTLockedRouteSelectionV2(
                coordinatePolicy: policy,
                analysisGridSourceStep: 1
            ),
            direct3Over2: try ASHLUTLockedRouteSelectionV2(
                coordinatePolicy: policy,
                analysisGridSourceStep: 2
            )
        )
        return try ASHLUTLockedConfigurationV2(
            configurationID: "ash-p06-test-v1",
            mappingSHA256: hash(byte: 0x11),
            operatorBankSHA256: hash(byte: 0x22),
            metricPolicySHA256: hash(byte: 0x33),
            compilerInputsSHA256: hash(byte: 0x44),
            calibrationPlanSHA256: hash(byte: 0x55),
            corpusLockBundleSHA256: hash(byte: 0x66),
            boundaryMode: .mirrorReflect101,
            operatorParameters: operatorParameters,
            semanticSteps: semanticSteps,
            compilerPolicy: compilerPolicy,
            routes: routes
        )
    }

    static func compilerPolicy(
        penaltyTable: [UInt16]? = nil
    ) throws -> ASHLUTLockedCompilerPolicyV2 {
        let denominator: UInt16 = 64
        return try ASHLUTLockedCompilerPolicyV2(
            penaltyDecayDenominator: denominator,
            orientationPenaltyStep: 4,
            supportPenaltyStep: 8,
            detailPenaltyStep: 8,
            regularizationPenaltyStep: 8,
            unsupportedSupportExpansionPenalty: 64,
            coherentSupportReductionPenalty: 32,
            unsupportedDetailIncreasePenalty: 64,
            supportedDetailReductionPenalty: 32,
            relaxationUnderRiskPenalty: 96,
            phaseKernelMismatchPenalty: 8,
            confidenceThresholdUNorm16: 36_044,
            penaltyToWeight: penaltyTable ?? exactPenaltyTable(denominator: denominator)
        )
    }

    static func exactPenaltyTable(denominator: UInt16) -> [UInt16] {
        (0..<256).map { index in
            let numerator = UInt32(UInt16.max) * UInt32(denominator)
            let divisor = UInt32(denominator) + UInt32(index)
            return UInt16((numerator + (divisor / 2)) / divisor)
        }
    }

    static func hash(byte: UInt8) throws -> ASHLUTHashV2 {
        try ASHLUTHashV2(
            hex: String(repeating: String(format: "%02x", byte), count: ASHLUTHashV2.byteCount)
        )
    }

    static func uint16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    static func uint32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    static func write(_ value: UInt16, at offset: Int, in data: inout Data) {
        data[offset] = UInt8(truncatingIfNeeded: value)
        data[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }

    static func write(_ value: UInt32, at offset: Int, in data: inout Data) {
        data[offset] = UInt8(truncatingIfNeeded: value)
        data[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        data[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        data[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }

    static func adjusted(
        _ base: UInt16,
        delta: Int8,
        step: UInt16,
        range: ClosedRange<Int>
    ) -> UInt16 {
        UInt16(min(range.upperBound, max(range.lowerBound, Int(base) + Int(delta) * Int(step))))
    }
}
