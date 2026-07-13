import XCTest
@testable import Mirmir

final class ASHCoordinateDiagnosticRuntimeV3Tests: XCTestCase {
    func testEveryRoutePolicyCellSelectsThePlanePolicyAndMatchesTheExactOracle() throws {
        let contract = try loadedContract()
        let lumaPlane = try constantPlane(extent: 4)
        let chromaPlane = try constantPlane(extent: 2)

        for route in ASHCoordinateModelRouteV3.allCases {
            let routeOracle = try XCTUnwrap(
                contract.coordinateOracles.first { $0.route == route }
            )
            var observedCells: Set<String> = []
            for lumaPolicy in ASHCoordinateModelPolicyV3.allCases {
                for chromaPolicy in ASHCoordinateModelPolicyV3.allCases {
                    let selection = try ASHCoordinateDiagnosticRouteSelectionV3(
                        route: route,
                        lumaCoordinatePolicy: lumaPolicy,
                        chromaCoordinatePolicy: chromaPolicy,
                        contract: contract
                    )
                    observedCells.insert("\(lumaPolicy.rawValue)/\(chromaPolicy.rawValue)")
                    XCTAssertEqual(selection.route, route)
                    XCTAssertEqual(selection.lumaCoordinatePolicy, lumaPolicy)
                    XCTAssertEqual(selection.chromaCoordinatePolicy, chromaPolicy)
                    XCTAssertEqual(selection.contractSHA256, contract.sha256)
                    XCTAssertEqual(selection.coordinatePolicy(for: nil), lumaPolicy)
                    XCTAssertEqual(selection.planeRole(for: nil), .luma)
                    for siting in ASHChromaSitingV2.allCases {
                        XCTAssertEqual(selection.coordinatePolicy(for: siting), chromaPolicy)
                        XCTAssertEqual(selection.planeRole(for: siting), .chroma)
                    }

                    let lumaOracle = try policyOracle(lumaPolicy, routeOracle: routeOracle)
                    try assertCoordinates(
                        selection: selection,
                        plane: lumaPlane,
                        chromaSiting: nil,
                        expectedRole: .luma,
                        expectedPolicy: lumaPolicy,
                        oracle: lumaOracle.luma
                    )

                    let chromaOracle = try policyOracle(chromaPolicy, routeOracle: routeOracle)
                    try assertCoordinates(
                        selection: selection,
                        plane: chromaPlane,
                        chromaSiting: .left,
                        expectedRole: .chroma,
                        expectedPolicy: chromaPolicy,
                        oracle: chromaOracle.chroma
                    )
                }
            }
            XCTAssertEqual(observedCells.count, 4)
        }
    }

    func testEveryDescriptorPreservesEveryIntegralSARLumaSiteForBothChromaPolicies() throws {
        let contract = try loadedContract()
        let plane = try ASHSpatialPlaneV2(
            width: 4,
            height: 4,
            samples: (0..<16).map { Double($0) / 16.0 }
        )
        let sidecar = try diagnosticSidecar()

        try assertIntegralPreservation(
            route: .direct2x,
            expectedSiteCount: 16,
            contract: contract,
            plane: plane,
            sidecar: sidecar
        )
        try assertIntegralPreservation(
            route: .direct3Over2,
            expectedSiteCount: 4,
            contract: contract,
            plane: plane,
            sidecar: sidecar
        )
    }

    func testInvalidAndUnloadedContractsFailWithTypedErrors() throws {
        XCTAssertThrowsError(
            try ASHCoordinateDiagnosticRouteSelectionV3(
                route: .direct2x,
                lumaCoordinatePolicy: .halfPixelCenter,
                chromaCoordinatePolicy: .sourceAlignedRational,
                contract: nil
            )
        ) { error in
            let typed = error as? ASHCoordinateDiagnosticRuntimeV3Error
            XCTAssertEqual(typed, .contractNotLoaded)
            XCTAssertEqual(typed?.machineCode, "coordinate_diagnostic_contract_not_loaded")
        }

        let data = try contractData()
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        let invalid = Data(
            text.replacingOccurrences(
                of: "generic_state_phase_v1",
                with: "legacy_phase_zero_override_v1"
            ).utf8
        )
        XCTAssertThrowsError(try ASHCoordinateModelContractV3.load(invalid)) { error in
            let typed = error as? ASHCoordinateModelContractV3Error
            XCTAssertEqual(typed, .invalidContract)
            XCTAssertEqual(typed?.machineCode, "coordinate_model_contract_invalid")
        }
    }

    private func assertCoordinates(
        selection: ASHCoordinateDiagnosticRouteSelectionV3,
        plane: ASHSpatialPlaneV2,
        chromaSiting: ASHChromaSitingV2?,
        expectedRole: ASHCoordinateDiagnosticPlaneRoleV3,
        expectedPolicy: ASHCoordinateModelPolicyV3,
        oracle: ASHCoordinateModelAxisOracleV3
    ) throws {
        for destinationColumn in oracle.horizontal.indices {
            let result = try ASHCoordinateDiagnosticRuntimeV3.sourceCoordinates(
                selection: selection,
                plane: plane,
                destinationColumn: destinationColumn,
                destinationRow: 0,
                chromaSiting: chromaSiting
            )
            XCTAssertEqual(result.planeRole, expectedRole)
            XCTAssertEqual(result.coordinatePolicy, expectedPolicy)
            assertExactRational(
                result.sourceCoordinates.horizontal,
                equals: oracle.horizontal[destinationColumn]
            )
        }
        for destinationRow in oracle.vertical.indices {
            let result = try ASHCoordinateDiagnosticRuntimeV3.sourceCoordinates(
                selection: selection,
                plane: plane,
                destinationColumn: 0,
                destinationRow: destinationRow,
                chromaSiting: chromaSiting
            )
            XCTAssertEqual(result.planeRole, expectedRole)
            XCTAssertEqual(result.coordinatePolicy, expectedPolicy)
            assertExactRational(
                result.sourceCoordinates.vertical,
                equals: oracle.vertical[destinationRow]
            )
        }
    }

    private func assertIntegralPreservation(
        route: ASHCoordinateModelRouteV3,
        expectedSiteCount: Int,
        contract: ASHCoordinateModelContractV3,
        plane: ASHSpatialPlaneV2,
        sidecar: ASHSpatialSidecarV2
    ) throws {
        let routeOracle = try XCTUnwrap(
            contract.coordinateOracles.first { $0.route == route }
        )
        let outputWidth = routeOracle.targetGeometry.luma.width
        let outputHeight = routeOracle.targetGeometry.luma.height

        for chromaPolicy in ASHCoordinateModelPolicyV3.allCases {
            let selection = try ASHCoordinateDiagnosticRouteSelectionV3(
                route: route,
                lumaCoordinatePolicy: .sourceAlignedRational,
                chromaCoordinatePolicy: chromaPolicy,
                contract: contract
            )
            for descriptor in ASHSpatialOperatorBankV2.descriptors {
                var integralSiteCount = 0
                var preservedSiteCount = 0
                var bitMismatchCount = 0

                for destinationRow in 0..<outputHeight {
                    for destinationColumn in 0..<outputWidth {
                        let coordinates = try ASHCoordinateDiagnosticRuntimeV3.sourceCoordinates(
                            selection: selection,
                            plane: plane,
                            destinationColumn: destinationColumn,
                            destinationRow: destinationRow,
                            chromaSiting: nil
                        )
                        guard let sourceColumn = coordinates.sourceCoordinates.horizontal.integralValue,
                              let sourceRow = coordinates.sourceCoordinates.vertical.integralValue else {
                            continue
                        }
                        integralSiteCount += 1

                        let result = try ASHCoordinateDiagnosticRuntimeV3.evaluateSample(
                            ASHCoordinateDiagnosticSampleRequestV3(
                                selection: selection,
                                plane: plane,
                                destinationColumn: destinationColumn,
                                destinationRow: destinationRow,
                                chromaSiting: nil,
                                descriptor: descriptor,
                                sidecar: sidecar,
                                boundary: .clamp,
                                parameters: .p05DevelopmentOnly
                            )
                        )
                        let expected = plane.sample(
                            column: sourceColumn,
                            row: sourceRow,
                            boundary: .clamp
                        )
                        XCTAssertEqual(result.coordinates.planeRole, .luma)
                        XCTAssertEqual(
                            result.coordinates.coordinatePolicy,
                            .sourceAlignedRational
                        )
                        XCTAssertEqual(
                            result.sample.sourceX,
                            coordinates.sourceCoordinates.horizontal
                        )
                        XCTAssertEqual(
                            result.sample.sourceY,
                            coordinates.sourceCoordinates.vertical
                        )
                        XCTAssertEqual(result.sample.descriptorID, descriptor.id)
                        XCTAssertEqual(result.sample.contributingSampleCount, 1)
                        XCTAssertTrue(result.sample.sourceAlignedSamplePreserved)
                        preservedSiteCount += result.sample.sourceAlignedSamplePreserved ? 1 : 0
                        if result.sample.value.bitPattern != expected.bitPattern {
                            bitMismatchCount += 1
                        }
                    }
                }

                XCTAssertEqual(integralSiteCount, expectedSiteCount)
                XCTAssertEqual(preservedSiteCount, expectedSiteCount)
                XCTAssertEqual(bitMismatchCount, 0)
            }
        }
    }

    private func assertExactRational(
        _ actual: ASHSpatialRationalCoordinateV2,
        equals expected: ASHCoordinateModelRationalV3,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertGreaterThan(actual.denominator, 0, file: file, line: line)
        XCTAssertGreaterThan(expected.denominator, 0, file: file, line: line)
        XCTAssertEqual(
            actual.numerator * expected.denominator,
            expected.numerator * actual.denominator,
            file: file,
            line: line
        )
    }

    private func policyOracle(
        _ policy: ASHCoordinateModelPolicyV3,
        routeOracle: ASHCoordinateModelRouteOracleV3
    ) throws -> ASHCoordinateModelPolicyOracleV3 {
        try XCTUnwrap(routeOracle.policyOracles.first { $0.policy == policy })
    }

    private func constantPlane(extent: Int) throws -> ASHSpatialPlaneV2 {
        try ASHSpatialPlaneV2(
            width: extent,
            height: extent,
            samples: Array(repeating: 0.5, count: extent * extent)
        )
    }

    private func diagnosticSidecar() throws -> ASHSpatialSidecarV2 {
        try ASHSpatialSidecarV2(
            orientationRadians: 0.0,
            normalizedMagnitude: 0.5,
            coherence: 0.5,
            risk: 0.5,
            chromaAlignment: 0.5,
            localMinimum: 0.0,
            localMaximum: 1.0
        )
    }

    private func loadedContract() throws -> ASHCoordinateModelContractV3 {
        try ASHCoordinateModelContractV3.load(try contractData())
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
