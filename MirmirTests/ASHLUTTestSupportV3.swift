import Foundation
@testable import Mirmir

struct ASHLUTTestFixtureV3 {
    let configuration: ASHLUTLockedConfigurationV3
    let compilation: ASHLUTCompilationV3
    let artifact: ASHLUTBinaryArtifactV3
}

enum ASHLUTTestSupportV3 {
    private static let direct2xResult = Result {
        try makeFixture(route: .direct2x)
    }

    private static let direct3Over2Result = Result {
        try makeFixture(route: .direct3Over2)
    }

    static func direct2x() throws -> ASHLUTTestFixtureV3 {
        try direct2xResult.get()
    }

    static func direct3Over2() throws -> ASHLUTTestFixtureV3 {
        try direct3Over2Result.get()
    }

    static func sharedConfiguration() throws -> ASHLUTLockedConfigurationV3 {
        try ASHLUTLockedConfigurationJSONLoaderV3.load(sharedLockedInputData())
    }

    static func sharedLockedInputData() throws -> Data {
        try Data(contentsOf: repositoryRoot.appendingPathComponent(
            "validation/calibration_v2/tests/fixtures/locked-compiler-input-format-1.2-parity-v2.json"
        ))
    }

    static func configuration(
        direct2x: ASHLUTLockedRouteSelectionV3? = nil,
        direct3Over2: ASHLUTLockedRouteSelectionV3? = nil,
        configurationID: String = "format-1.2-swift-test-001"
    ) throws -> ASHLUTLockedConfigurationV3 {
        let base = try sharedConfiguration()
        return try ASHLUTLockedConfigurationV3(
            configurationID: configurationID,
            mappingSHA256: base.mappingSHA256,
            operatorBankSHA256: base.operatorBankSHA256,
            metricPolicySHA256: base.metricPolicySHA256,
            compilerInputsSHA256: base.compilerInputsSHA256,
            calibrationPlanSHA256: base.calibrationPlanSHA256,
            corpusLockBundleSHA256: base.corpusLockBundleSHA256,
            boundaryMode: base.boundaryMode,
            operatorParameters: base.operatorParameters,
            semanticSteps: base.semanticSteps,
            compilerPolicy: base.compilerPolicy,
            routes: ASHLUTLockedRoutesV3(
                direct2x: direct2x ?? base.routes.direct2x,
                direct3Over2: direct3Over2 ?? base.routes.direct3Over2
            )
        )
    }

    static func routeSelection(
        policyID: UInt8,
        lumaMode: ASHLUTAnisotropyModeV3,
        chromaMode: ASHLUTAnisotropyModeV3,
        lumaCoordinatePolicy: ASHSpatialCoordinatePolicyV2,
        chromaCoordinatePolicy: ASHSpatialCoordinatePolicyV2,
        analysisGridSourceStep: UInt8
    ) throws -> ASHLUTLockedRouteSelectionV3 {
        try ASHLUTLockedRouteSelectionV3(
            spatialPolicyID: policyID,
            lumaAnisotropyMode: lumaMode,
            chromaAnisotropyMode: chromaMode,
            lumaCoordinatePolicy: lumaCoordinatePolicy,
            chromaCoordinatePolicy: chromaCoordinatePolicy,
            analysisGridSourceStep: analysisGridSourceStep
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

    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static func makeFixture(route: ASHSpatialRouteV2) throws -> ASHLUTTestFixtureV3 {
        let configuration = try sharedConfiguration()
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
}
