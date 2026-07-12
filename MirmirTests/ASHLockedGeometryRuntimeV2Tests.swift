import XCTest
@testable import Mirmir

final class ASHLockedGeometryRuntimeV2Tests: XCTestCase {
    func test_exactRationalPhaseClassesMapToCompilerOrdinalsForEveryRoutePolicyAndSiting() throws {
        let samples = (0..<36).map { Double(($0 * 17) % 37) / 36.0 }
        let plane = try ASHSpatialPlaneV2(width: 6, height: 6, samples: samples)
        for route in ASHSpatialRouteV2.allCases {
            let outputWidth = try route.destinationExtent(for: plane.width)
            let outputHeight = try route.destinationExtent(for: plane.height)
            for policy in ASHSpatialCoordinatePolicyV2.allCases {
                let sitings: [ASHChromaSitingV2?] = [nil] + ASHChromaSitingV2.allCases.map(Optional.some)
                for siting in sitings {
                    for row in 0..<outputHeight {
                        for column in 0..<outputWidth {
                            let coordinates = try sourceCoordinates(
                                column: column,
                                row: row,
                                plane: plane,
                                outputWidth: outputWidth,
                                outputHeight: outputHeight,
                                policy: policy,
                                siting: siting
                            )
                            let ordinal = try ASHLockedRuntimeV2.phaseOrdinal(
                                sourceCoordinates: coordinates,
                                plane: plane,
                                outputWidth: outputWidth,
                                outputHeight: outputHeight,
                                route: route,
                                policy: policy,
                                chromaSiting: siting
                            )
                            let expected = ((row % route.scaleNumerator) * route.scaleNumerator)
                                + (column % route.scaleNumerator)
                            XCTAssertEqual(
                                ordinal,
                                expected,
                                "\(route.rawValue) \(policy.rawValue) \(siting?.rawValue ?? "luma")"
                            )
                        }
                    }
                }
            }
        }
    }

    func test_sourceAlignedEntryFlagIsDistinctFromActualChromaSamplePreservation() throws {
        let fixture = try ASHLockedRuntimeTestSupportV2.existingFixture(.direct2x)
        let planes = try ASHLockedRuntimeTestSupportV2.planes()
        let grid = try ASHLockedRuntimeTestSupportV2.analysisGrid(
            planes: planes,
            configuration: fixture.configuration,
            route: .direct2x,
            siting: .center
        )
        let dispatchGrid = try ASHLockedRuntimeV2.makeDispatchGrid(
            lut: fixture.loaded,
            configuration: fixture.configuration,
            analysisGrid: grid
        )
        let luma = try ASHLockedRuntimeV2.evaluateSample(
            dispatchGrid: dispatchGrid,
            configuration: fixture.configuration,
            analysisGrid: grid,
            plane: ASHLockedRuntimeTestSupportV2.spatialPlane(planes.luma),
            destinationColumn: 0,
            destinationRow: 0,
            chromaSiting: nil
        )
        XCTAssertTrue(luma.dispatch.sourceAlignedEntryFlag)
        XCTAssertTrue(luma.sourceAlignedSamplePreserved)

        let centeredChroma = try ASHLockedRuntimeV2.evaluateSample(
            dispatchGrid: dispatchGrid,
            configuration: fixture.configuration,
            analysisGrid: grid,
            plane: ASHLockedRuntimeTestSupportV2.spatialPlane(planes.cb, chroma: true),
            destinationColumn: 0,
            destinationRow: 0,
            chromaSiting: .center
        )
        XCTAssertTrue(centeredChroma.dispatch.sourceAlignedEntryFlag)
        XCTAssertFalse(centeredChroma.sourceCoordinates.horizontal.isIntegral)
        XCTAssertFalse(centeredChroma.sourceCoordinates.vertical.isIntegral)
        XCTAssertFalse(centeredChroma.sourceAlignedSamplePreserved)

        let leftGrid = try ASHLockedRuntimeTestSupportV2.analysisGrid(
            planes: planes,
            configuration: fixture.configuration,
            route: .direct2x,
            siting: .left
        )
        let leftDispatchGrid = try ASHLockedRuntimeV2.makeDispatchGrid(
            lut: fixture.loaded,
            configuration: fixture.configuration,
            analysisGrid: leftGrid
        )
        let cositedChroma = try ASHLockedRuntimeV2.evaluateSample(
            dispatchGrid: leftDispatchGrid,
            configuration: fixture.configuration,
            analysisGrid: leftGrid,
            plane: ASHLockedRuntimeTestSupportV2.spatialPlane(planes.cb, chroma: true),
            destinationColumn: 0,
            destinationRow: 0,
            chromaSiting: .left
        )
        XCTAssertTrue(cositedChroma.sourceCoordinates.horizontal.isIntegral)
        XCTAssertFalse(cositedChroma.sourceCoordinates.vertical.isIntegral)
        XCTAssertFalse(cositedChroma.sourceAlignedSamplePreserved)
    }

    func test_bothRoutesEvaluateEveryTargetAcrossAllLockedGridSteps() throws {
        let planes = try ASHLockedRuntimeTestSupportV2.planes()
        let lumaPlane = try ASHLockedRuntimeTestSupportV2.spatialPlane(planes.luma)
        for route in ASHSpatialRouteV2.allCases {
            for step in [1, 2, 4] {
                let fixture = try ASHLockedRuntimeTestSupportV2.fixture(
                    route: route,
                    policy: .sourceAlignedRational,
                    step: step
                )
                let grid = try ASHLockedRuntimeTestSupportV2.analysisGrid(
                    planes: planes,
                    configuration: fixture.configuration,
                    route: route
                )
                let dispatchGrid = try ASHLockedRuntimeV2.makeDispatchGrid(
                    lut: fixture.loaded,
                    configuration: fixture.configuration,
                    analysisGrid: grid
                )
                let outputWidth = try route.destinationExtent(for: lumaPlane.width)
                let outputHeight = try route.destinationExtent(for: lumaPlane.height)
                for row in 0..<outputHeight {
                    for column in 0..<outputWidth {
                        let result = try ASHLockedRuntimeV2.evaluateSample(
                            dispatchGrid: dispatchGrid,
                            configuration: fixture.configuration,
                            analysisGrid: grid,
                            plane: lumaPlane,
                            destinationColumn: column,
                            destinationRow: row,
                            chromaSiting: nil
                        )
                        XCTAssertEqual(
                            result.phaseOrdinal,
                            ((row % route.scaleNumerator) * route.scaleNumerator)
                                + (column % route.scaleNumerator)
                        )
                        XCTAssertTrue(result.value.isFinite)
                        XCTAssertTrue((0.0...1.0).contains(result.value))
                        XCTAssertLessThanOrEqual(result.dispatch.operatorEvaluationCount, 2)
                        XCTAssertEqual(result.dispatch.counters, .zero)
                    }
                }
                XCTAssertEqual(dispatchGrid.dispatches.count, grid.count * route.phasePairCount)
                XCTAssertEqual(dispatchGrid.counters, .zero)
                XCTAssertEqual(grid.step, step)
            }
        }
    }

    func test_runtimeRejectsDifferentConfigurationBeforeLookupAndRejectsWrongGridStep() throws {
        let fixture = try ASHLockedRuntimeTestSupportV2.existingFixture(.direct2x)
        let planes = try ASHLockedRuntimeTestSupportV2.planes()
        let validGrid = try ASHLockedRuntimeTestSupportV2.analysisGrid(
            planes: planes,
            configuration: fixture.configuration,
            route: .direct2x
        )
        let different = try ASHLockedRuntimeTestSupportV2.configurationCopy(
            fixture.configuration,
            configurationID: "ash-p06-runtime-mismatched"
        )
        XCTAssertThrowsError(try ASHLockedRuntimeV2.dispatch(
            lut: fixture.loaded,
            configuration: different,
            sourceState: ASHLUTStateOrdinalTableV2.validStates[0],
            phaseOrdinal: 999,
            context: .spatialOnly,
            sidecar: ASHLockedRuntimeTestSupportV2.sidecar()
        )) { error in
            XCTAssertEqual(error as? ASHLockedRuntimeV2Error, .configurationMismatch)
        }
        XCTAssertThrowsError(try ASHLockedRuntimeV2.makeDispatchGrid(
            lut: fixture.loaded,
            configuration: different,
            analysisGrid: validGrid
        )) { error in
            XCTAssertEqual(error as? ASHLockedRuntimeV2Error, .configurationMismatch)
        }

        let wrongStepGrid = try ASHAnalysisGridBuilderV2.build(
            luma: planes.luma,
            cb: planes.cb,
            cr: planes.cr,
            chromaSiting: .center,
            step: 2,
            boundary: fixture.configuration.boundaryMode,
            configuration: try .makeDisposableP05Reference()
        )
        XCTAssertThrowsError(try ASHLockedRuntimeV2.makeDispatchGrid(
            lut: fixture.loaded,
            configuration: fixture.configuration,
            analysisGrid: wrongStepGrid
        )) { error in
            XCTAssertEqual(error as? ASHLockedRuntimeV2Error, .invalidAnalysisGrid)
        }
    }

    private func sourceCoordinates(
        column: Int,
        row: Int,
        plane: ASHSpatialPlaneV2,
        outputWidth: Int,
        outputHeight: Int,
        policy: ASHSpatialCoordinatePolicyV2,
        siting: ASHChromaSitingV2?
    ) throws -> ASHSpatialSourceCoordinatesV2 {
        if let siting {
            return ASHSpatialSourceCoordinatesV2(
                horizontal: try siting.sourceCoordinate(
                    destinationIndex: column,
                    sourceExtent: plane.width,
                    destinationExtent: outputWidth,
                    policy: policy,
                    axis: .horizontal
                ),
                vertical: try siting.sourceCoordinate(
                    destinationIndex: row,
                    sourceExtent: plane.height,
                    destinationExtent: outputHeight,
                    policy: policy,
                    axis: .vertical
                )
            )
        }
        return ASHSpatialSourceCoordinatesV2(
            horizontal: try ASHSpatialOperatorBankV2.coordinate(
                destinationIndex: column,
                sourceExtent: plane.width,
                destinationExtent: outputWidth,
                policy: policy
            ),
            vertical: try ASHSpatialOperatorBankV2.coordinate(
                destinationIndex: row,
                sourceExtent: plane.height,
                destinationExtent: outputHeight,
                policy: policy
            )
        )
    }
}
