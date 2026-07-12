import CryptoKit
import Foundation
@testable import Mirmir

enum ASHLockedRuntimeTestSupportV2 {
    struct Fixture {
        let configuration: ASHLUTLockedConfigurationV2
        let compilation: ASHLUTCompilationV2
        let loaded: ASHLUTLoadedV2
    }

    struct MappingFixture {
        let runtime: Fixture
        let mapping: ASHLockedVideoMappingV2
        let mappingData: Data
    }

    struct Planes {
        let luma: ASHVideoAnalyzerV2CodePlane
        let cb: ASHVideoAnalyzerV2CodePlane
        let cr: ASHVideoAnalyzerV2CodePlane
    }

    private static let lockedMappingFixtures: [ASHSpatialRouteV2: Result<MappingFixture, Error>] =
        Dictionary(uniqueKeysWithValues: ASHSpatialRouteV2.allCases.map { route in
            (route, Result { try makeLockedMappingFixture(route) })
        })

    static func existingFixture(_ route: ASHSpatialRouteV2) throws -> Fixture {
        switch route {
        case .direct2x:
            let source = try ASHLUTTestSupportV2.sourceDirect2x()
            return Fixture(
                configuration: source.configuration,
                compilation: source.compilation,
                loaded: try ASHLUTBinaryCodecV2.load(
                    source.artifact.data,
                    expectedRoute: route,
                    configuration: source.configuration
                )
            )
        case .direct3Over2:
            let source = try ASHLUTTestSupportV2.halfPixelDirect3Over2()
            return Fixture(
                configuration: source.configuration,
                compilation: source.compilation,
                loaded: try ASHLUTBinaryCodecV2.load(
                    source.artifact.data,
                    expectedRoute: route,
                    configuration: source.configuration
                )
            )
        }
    }

    static func lockedMappingFixture(
        _ route: ASHSpatialRouteV2
    ) throws -> MappingFixture {
        guard let result = lockedMappingFixtures[route] else {
            throw ASHLockedVideoMappingV2Error.invalidValue
        }
        return try result.get()
    }

    static func lockedMappingData(
        edgePresentLow: Int = 6_553
    ) throws -> Data {
        let document: [String: Any] = [
            "analysis_epsilon_q0_30": 1,
            "analysis_grid_source_steps": [
                "direct_2x": 1,
                "direct_3_over_2": 2
            ],
            "boundary_mode": "mirror_reflect101",
            "candidate_vector_sha256": String(repeating: "bb", count: 32),
            "canonical_core_unchanged": true,
            "chroma_edge_confidence_unorm15": 3_277,
            "configuration_id": "p06-reference-fixture-001",
            "input_contract": [
                "bit_depth": 8,
                "chroma_siting": "left",
                "matrix": "BT.709",
                "pixel_format": "420v",
                "range": "video",
                "subsampling": "4:2:0"
            ],
            "mapping_id": "ash-video-mapping-v2",
            "mapping_seed_sha256": String(repeating: "aa", count: 32),
            "risk_weights_unorm15": [
                "alternating_difference": 16_383,
                "laplacian": 16_384
            ],
            "schema_version": "1.0.0",
            "selection_binding": [
                "calibration_selection_sha256": NSNull(),
                "selected_evaluation_sha256": NSNull()
            ],
            "shared_bank_configuration_sha256": String(repeating: "cc", count: 32),
            "status": "calibration_candidate",
            "thresholds_unorm15": [
                "alias_or_ringing_risk": ["high": 13_107, "low": 6_553],
                "chroma_luma_structure_aligned": ["high": 13_107, "low": 6_553],
                "coherent_structure": ["high": 13_107, "low": 6_553],
                "edge_present": ["high": 13_107, "low": edgePresentLow],
                "temporal_support_valid": ["high": 32_767, "low": 32_767],
                "texture_high_frequency": ["high": 13_107, "low": 6_553]
            ]
        ]
        return try JSONSerialization.data(
            withJSONObject: document,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    static func fixture(
        route: ASHSpatialRouteV2,
        policy: ASHSpatialCoordinatePolicyV2,
        step: Int
    ) throws -> Fixture {
        let configuration = try configuration(
            route: route,
            policy: policy,
            step: step
        )
        let compilation = try ASHLUTLeafCompilerV2.compile(
            route: route,
            configuration: configuration
        )
        let artifact = try ASHLUTBinaryCodecV2.serialize(compilation)
        return Fixture(
            configuration: configuration,
            compilation: compilation,
            loaded: try ASHLUTBinaryCodecV2.load(
                artifact.data,
                expectedRoute: route,
                configuration: configuration
            )
        )
    }

    static func configuration(
        route: ASHSpatialRouteV2,
        policy: ASHSpatialCoordinatePolicyV2,
        step: Int
    ) throws -> ASHLUTLockedConfigurationV2 {
        let base = try ASHLUTTestSupportV2.configuration(policy: policy)
        let selection = try ASHLUTLockedRouteSelectionV2(
            coordinatePolicy: policy,
            analysisGridSourceStep: UInt8(step)
        )
        let routeByte = route == .direct2x ? UInt8(0x70) : UInt8(0x78)
        return try ASHLUTLockedConfigurationV2(
            configurationID: "ash-p06-runtime-\(route.rawValue)-s\(step)",
            mappingSHA256: base.mappingSHA256,
            operatorBankSHA256: base.operatorBankSHA256,
            metricPolicySHA256: base.metricPolicySHA256,
            compilerInputsSHA256: ASHLUTTestSupportV2.hash(byte: routeByte + UInt8(step)),
            calibrationPlanSHA256: base.calibrationPlanSHA256,
            corpusLockBundleSHA256: base.corpusLockBundleSHA256,
            boundaryMode: base.boundaryMode,
            operatorParameters: base.operatorParameters,
            semanticSteps: base.semanticSteps,
            compilerPolicy: base.compilerPolicy,
            routes: ASHLUTLockedRoutesV2(direct2x: selection, direct3Over2: selection)
        )
    }

    static func configurationCopy(
        _ source: ASHLUTLockedConfigurationV2,
        configurationID: String
    ) throws -> ASHLUTLockedConfigurationV2 {
        try ASHLUTLockedConfigurationV2(
            configurationID: configurationID,
            mappingSHA256: source.mappingSHA256,
            operatorBankSHA256: source.operatorBankSHA256,
            metricPolicySHA256: source.metricPolicySHA256,
            compilerInputsSHA256: source.compilerInputsSHA256,
            calibrationPlanSHA256: source.calibrationPlanSHA256,
            corpusLockBundleSHA256: source.corpusLockBundleSHA256,
            boundaryMode: source.boundaryMode,
            operatorParameters: source.operatorParameters,
            semanticSteps: source.semanticSteps,
            compilerPolicy: source.compilerPolicy,
            routes: source.routes
        )
    }

    static func configurationCopy(
        _ source: ASHLUTLockedConfigurationV2,
        mappingSHA256: ASHLUTHashV2
    ) throws -> ASHLUTLockedConfigurationV2 {
        try ASHLUTLockedConfigurationV2(
            configurationID: source.configurationID,
            mappingSHA256: mappingSHA256,
            operatorBankSHA256: source.operatorBankSHA256,
            metricPolicySHA256: source.metricPolicySHA256,
            compilerInputsSHA256: source.compilerInputsSHA256,
            calibrationPlanSHA256: source.calibrationPlanSHA256,
            corpusLockBundleSHA256: source.corpusLockBundleSHA256,
            boundaryMode: source.boundaryMode,
            operatorParameters: source.operatorParameters,
            semanticSteps: source.semanticSteps,
            compilerPolicy: source.compilerPolicy,
            routes: source.routes
        )
    }

    static func planes(
        width: Int = 8,
        height: Int = 8
    ) throws -> Planes {
        let luma = try codePlane(width: width, height: height) { column, row in
            lumaCode(column: column, row: row, width: width)
        }
        let cb = try codePlane(width: width / 2, height: height / 2) { column, row in
            cbCode(column: column, row: row)
        }
        let cr = try codePlane(width: width / 2, height: height / 2) { column, row in
            crCode(column: column, row: row)
        }
        return Planes(luma: luma, cb: cb, cr: cr)
    }

    static func analysisGrid(
        planes: Planes,
        configuration: ASHLUTLockedConfigurationV2,
        route: ASHSpatialRouteV2,
        siting: ASHChromaSitingV2 = .center
    ) throws -> ASHAnalysisGridV2 {
        try ASHAnalysisGridBuilderV2.build(
            luma: planes.luma,
            cb: planes.cb,
            cr: planes.cr,
            chromaSiting: siting,
            step: Int(configuration.routeSelection(for: route).analysisGridSourceStep),
            boundary: configuration.boundaryMode,
            configuration: try .makeDisposableP05Reference()
        )
    }

    static func spatialPlane(
        _ source: ASHVideoAnalyzerV2CodePlane,
        chroma: Bool = false
    ) throws -> ASHSpatialPlaneV2 {
        var samples: [Double] = []
        for row in 0..<source.height {
            for column in 0..<source.width {
                let code = source.codes[(row * source.bytesPerRow) + column]
                let value = chroma
                    ? source.range.normalizeChroma(code) + 0.5
                    : source.range.normalizeLuma(code)
                samples.append(min(1.0, max(0.0, value)))
            }
        }
        return try ASHSpatialPlaneV2(
            width: source.width,
            height: source.height,
            samples: samples
        )
    }

    static func sidecar(orientation: Double = .pi / 8.0) throws -> ASHSpatialSidecarV2 {
        try ASHSpatialSidecarV2(
            orientationRadians: orientation,
            normalizedMagnitude: 0.8,
            coherence: 0.9,
            risk: 0.1,
            chromaAlignment: 0.9,
            localMinimum: 0.0,
            localMaximum: 1.0
        )
    }

    private static func codePlane(
        width: Int,
        height: Int,
        generator: (Int, Int) -> UInt8
    ) throws -> ASHVideoAnalyzerV2CodePlane {
        var codes: [UInt8] = []
        for row in 0..<height {
            for column in 0..<width {
                codes.append(generator(column, row))
            }
        }
        return try ASHVideoAnalyzerV2CodePlane(
            width: width,
            height: height,
            bytesPerRow: width,
            codes: codes,
            range: .video
        )
    }

    private static func makeLockedMappingFixture(
        _ route: ASHSpatialRouteV2
    ) throws -> MappingFixture {
        let base = try existingFixture(route).configuration
        let mappingData = try lockedMappingData()
        let mappingSHA256 = ASHLUTHashV2(
            validatedBytes: Array(SHA256.hash(data: mappingData))
        )
        let configuration = try configurationCopy(
            base,
            mappingSHA256: mappingSHA256
        )
        let compilation = try ASHLUTLeafCompilerV2.compile(
            route: route,
            configuration: configuration
        )
        let artifact = try ASHLUTBinaryCodecV2.serialize(compilation)
        let loaded = try ASHLUTBinaryCodecV2.load(
            artifact.data,
            expectedRoute: route,
            configuration: configuration
        )
        return MappingFixture(
            runtime: Fixture(
                configuration: configuration,
                compilation: compilation,
                loaded: loaded
            ),
            mapping: try ASHLockedVideoMappingV2.load(
                mappingData,
                expectedSHA256: mappingSHA256
            ),
            mappingData: mappingData
        )
    }

    private static func lumaCode(column: Int, row: Int, width: Int) -> UInt8 {
        if column < width / 2 {
            let value = 16 + ((column * 17 + row * 37) % 100)
            return UInt8(value)
        }
        let interaction = column * row
        let value = 120 + ((column * 31 + row * 43 + interaction) % 116)
        return UInt8(value)
    }

    private static func cbCode(column: Int, row: Int) -> UInt8 {
        UInt8(16 + ((column * 47 + row * 23) % 225))
    }

    private static func crCode(column: Int, row: Int) -> UInt8 {
        UInt8(240 - ((column * 29 + row * 53) % 225))
    }
}
