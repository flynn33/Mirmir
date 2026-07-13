import XCTest
@testable import Mirmir

final class ASHCoordinateModelContractV3Tests: XCTestCase {
    func testContractLoadsWithFrozenCanonicalHashesAndUnselectedDimensions() throws {
        let data = try contractData()
        let expected = try ASHLUTHashV2(
            hex: "283704ffcd267be7d85eb74c3791d466f94ba6aaa5430e7443a37683db0faced"
        )
        let contract = try ASHCoordinateModelContractV3.load(
            data,
            expectedSHA256: expected
        )

        XCTAssertEqual(contract.sha256, expected)
        XCTAssertEqual(contract.immutableBytes, data)
        XCTAssertEqual(contract.canonicalBytes, data)
        XCTAssertEqual(
            contract.coordinateOracleMatrixSHA256.hex,
            "3cb5d705a24fd3928496b5ee35e671e5219b6928d1cf5dd6c08cb74c83e226d9"
        )
        XCTAssertEqual(
            contract.experimentDimensionsSHA256.hex,
            "a9fcabb4a08d3e43e5dcdcb0b8ef55f13d379f462f6f5db283aa802b757e88f2"
        )
        XCTAssertEqual(
            ASHCoordinateModelContractV3.phaseZeroCompilationSemantics,
            "generic_state_phase_v1"
        )
        XCTAssertEqual(
            ASHCoordinateModelContractV3.integralPreservationSemantics,
            "actual_rational_integrality_v1"
        )
        XCTAssertEqual(
            ASHCoordinateModelContractV3.selectionStatus,
            "unselected_experiment_dimensions"
        )
        XCTAssertEqual(
            contract.routeDimensions.map(\.route),
            [.direct2x, .direct3Over2]
        )
        for dimensions in contract.routeDimensions {
            XCTAssertEqual(
                dimensions.lumaCoordinatePolicyValues,
                [.halfPixelCenter, .sourceAlignedRational]
            )
            XCTAssertEqual(
                dimensions.chromaCoordinatePolicyValues,
                [.halfPixelCenter, .sourceAlignedRational]
            )
        }
    }

    func testDirect2xLeftSitedY4C2RationalOracleIsExact() throws {
        let oracle = try routeOracle(.direct2x)
        XCTAssertEqual(oracle.scaleNumerator, 2)
        XCTAssertEqual(oracle.scaleDenominator, 1)
        XCTAssertEqual(
            oracle.lowResolutionGeometry,
            squareGeometry(lumaExtent: 4, chromaExtent: 2)
        )
        XCTAssertEqual(
            oracle.targetGeometry,
            squareGeometry(lumaExtent: 8, chromaExtent: 4)
        )
        XCTAssertEqual(oracle.phaseOrdinalGrid, [[0, 1], [2, 3]])

        let halfPixel = try policyOracle(.halfPixelCenter, routeOracle: oracle)
        assertCoordinates(
            halfPixel.luma.horizontal,
            [(-1, 4), (1, 4), (3, 4), (5, 4), (7, 4), (9, 4), (11, 4), (13, 4)]
        )
        XCTAssertEqual(halfPixel.luma.horizontal, halfPixel.luma.vertical)
        assertCoordinates(
            halfPixel.chroma.horizontal,
            [(-1, 8), (3, 8), (7, 8), (11, 8)]
        )
        assertCoordinates(
            halfPixel.chroma.vertical,
            [(-1, 4), (1, 4), (3, 4), (5, 4)]
        )

        let sourceAligned = try policyOracle(.sourceAlignedRational, routeOracle: oracle)
        assertCoordinates(
            sourceAligned.luma.horizontal,
            [(0, 1), (1, 2), (1, 1), (3, 2), (2, 1), (5, 2), (3, 1), (7, 2)]
        )
        XCTAssertEqual(sourceAligned.luma.horizontal, sourceAligned.luma.vertical)
        assertCoordinates(
            sourceAligned.chroma.horizontal,
            [(0, 1), (1, 2), (1, 1), (3, 2)]
        )
        assertCoordinates(
            sourceAligned.chroma.vertical,
            [(-1, 8), (3, 8), (7, 8), (11, 8)]
        )
    }

    func testDirect3Over2LeftSitedY4C2RationalOracleIsExact() throws {
        let oracle = try routeOracle(.direct3Over2)
        XCTAssertEqual(oracle.scaleNumerator, 3)
        XCTAssertEqual(oracle.scaleDenominator, 2)
        XCTAssertEqual(
            oracle.lowResolutionGeometry,
            squareGeometry(lumaExtent: 4, chromaExtent: 2)
        )
        XCTAssertEqual(
            oracle.targetGeometry,
            squareGeometry(lumaExtent: 6, chromaExtent: 3)
        )
        XCTAssertEqual(
            oracle.phaseOrdinalGrid,
            [[0, 1, 2], [3, 4, 5], [6, 7, 8]]
        )

        let halfPixel = try policyOracle(.halfPixelCenter, routeOracle: oracle)
        assertCoordinates(
            halfPixel.luma.horizontal,
            [(-1, 6), (1, 2), (7, 6), (11, 6), (5, 2), (19, 6)]
        )
        XCTAssertEqual(halfPixel.luma.horizontal, halfPixel.luma.vertical)
        assertCoordinates(
            halfPixel.chroma.horizontal,
            [(-1, 12), (7, 12), (5, 4)]
        )
        assertCoordinates(
            halfPixel.chroma.vertical,
            [(-1, 6), (1, 2), (7, 6)]
        )

        let sourceAligned = try policyOracle(.sourceAlignedRational, routeOracle: oracle)
        assertCoordinates(
            sourceAligned.luma.horizontal,
            [(0, 1), (2, 3), (4, 3), (2, 1), (8, 3), (10, 3)]
        )
        XCTAssertEqual(sourceAligned.luma.horizontal, sourceAligned.luma.vertical)
        assertCoordinates(
            sourceAligned.chroma.horizontal,
            [(0, 1), (2, 3), (4, 3)]
        )
        assertCoordinates(
            sourceAligned.chroma.vertical,
            [(-1, 12), (7, 12), (5, 4)]
        )
    }

    func testStrictLoaderRejectsHashCanonicalFieldAndSemanticMutations() throws {
        let data = try contractData()
        let wrongHash = try ASHLUTHashV2(hex: String(repeating: "ab", count: 32))
        XCTAssertThrowsError(
            try ASHCoordinateModelContractV3.load(data, expectedSHA256: wrongHash)
        ) {
            XCTAssertEqual($0 as? ASHCoordinateModelContractV3Error, .hashMismatch)
        }

        var noncanonical = data
        noncanonical.append(0x20)
        XCTAssertThrowsError(try ASHCoordinateModelContractV3.load(noncanonical)) {
            XCTAssertEqual(
                $0 as? ASHCoordinateModelContractV3Error,
                .nonCanonicalEncoding
            )
        }

        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        let semanticMutation = Data(
            text.replacingOccurrences(
                of: "generic_state_phase_v1",
                with: "legacy_phase_zero_override_v1"
            ).utf8
        )
        XCTAssertThrowsError(try ASHCoordinateModelContractV3.load(semanticMutation)) {
            XCTAssertEqual($0 as? ASHCoordinateModelContractV3Error, .invalidContract)
        }

        let extraField = Data(
            (String(text.dropLast(2)) + ",\"unexpected\":0}\n").utf8
        )
        XCTAssertThrowsError(try ASHCoordinateModelContractV3.load(extraField)) {
            XCTAssertEqual($0 as? ASHCoordinateModelContractV3Error, .fieldSetMismatch)
        }

        let duplicate = Data(
            "{\"artifact_kind\":\"a\",\"artifact_kind\":\"b\"}\n".utf8
        )
        XCTAssertThrowsError(try ASHCoordinateModelContractV3.load(duplicate)) {
            XCTAssertEqual($0 as? ASHCoordinateModelContractV3Error, .invalidContract)
        }
    }

    func testTypedErrorMachineCodesAreFrozen() {
        let pairs: [(ASHCoordinateModelContractV3Error, String)] = [
            (.hashMismatch, "coordinate_model_contract_hash_mismatch"),
            (.nonCanonicalEncoding, "coordinate_model_contract_noncanonical_encoding"),
            (.fieldSetMismatch, "coordinate_model_contract_field_set_mismatch"),
            (.invalidContract, "coordinate_model_contract_invalid")
        ]
        for (error, expected) in pairs {
            XCTAssertEqual(error.machineCode, expected)
        }
    }

    private func routeOracle(
        _ route: ASHCoordinateModelRouteV3
    ) throws -> ASHCoordinateModelRouteOracleV3 {
        let contract = try ASHCoordinateModelContractV3.load(try contractData())
        return try XCTUnwrap(contract.coordinateOracles.first { $0.route == route })
    }

    private func policyOracle(
        _ policy: ASHCoordinateModelPolicyV3,
        routeOracle: ASHCoordinateModelRouteOracleV3
    ) throws -> ASHCoordinateModelPolicyOracleV3 {
        try XCTUnwrap(routeOracle.policyOracles.first { $0.policy == policy })
    }

    private func assertCoordinates(
        _ actual: [ASHCoordinateModelRationalV3],
        _ expected: [(Int64, Int64)],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            actual,
            expected.map {
                ASHCoordinateModelRationalV3(numerator: $0.0, denominator: $0.1)
            },
            file: file,
            line: line
        )
    }

    private func squareGeometry(
        lumaExtent: Int,
        chromaExtent: Int
    ) -> ASHCoordinateModelGeometryV3 {
        ASHCoordinateModelGeometryV3(
            luma: ASHCoordinateModelExtentV3(width: lumaExtent, height: lumaExtent),
            cb: ASHCoordinateModelExtentV3(width: chromaExtent, height: chromaExtent),
            cr: ASHCoordinateModelExtentV3(width: chromaExtent, height: chromaExtent)
        )
    }

    private func contractData() throws -> Data {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try Data(contentsOf: repositoryRoot.appendingPathComponent(
            "validation/calibration_v2/contracts/coordinate-model-contract-v3.json"
        ))
    }
}
