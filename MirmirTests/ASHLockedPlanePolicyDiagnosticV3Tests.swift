import XCTest
@testable import Mirmir

// swiftlint:disable file_length type_body_length

final class ASHLockedPlanePolicyDiagnosticV3Tests: XCTestCase {
    private struct Fixture {
        let route: ASHCoordinateModelRouteV3
        let spatialRoute: ASHSpatialRouteV2
        let contract: ASHCoordinateModelContractV3
        let lumaPlane: ASHSpatialPlaneV2
        let cbPlane: ASHSpatialPlaneV2
        let crPlane: ASHSpatialPlaneV2
        let runtime: ASHLockedRuntimeTestSupportV2.Fixture
        let analysisGrid: ASHAnalysisGridV2
        let dispatchGrid: ASHLockedDispatchGridV2
    }

    private struct CoordinateCells {
        let halfHalf: ASHLockedPlanePolicyDiagnosticResultV3
        let halfSource: ASHLockedPlanePolicyDiagnosticResultV3
        let sourceHalf: ASHLockedPlanePolicyDiagnosticResultV3
        let sourceSource: ASHLockedPlanePolicyDiagnosticResultV3

        var all: [ASHLockedPlanePolicyDiagnosticResultV3] {
            [halfHalf, halfSource, sourceHalf, sourceSource]
        }
    }

    func testAllCoordinateAndAnisotropyCellsRemainPlaneIndependent() throws {
        let contract = try loadedContract()
        for route in ASHCoordinateModelRouteV3.allCases {
            let fixture = try makeFixture(route: route, contract: contract)
            let cells = try processCoordinateCells(fixture)
            assertGenericDispatch(fixture)
            try assertShapesFlagsAndStrengths(fixture, cells: cells)
            try assertCoordinatePlaneIndependence(cells)
            try assertAnisotropyPlaneIndependence(cells)
            assertSelectedPolicies(cells)
            assertIntegralPreservation(fixture, cells: cells)
        }
    }

    func testMatchingLockedCellIsExactlyEqualToProductionEvaluation() throws {
        let contract = try loadedContract()
        for route in ASHCoordinateModelRouteV3.allCases {
            let fixture = try makeFixture(route: route, contract: contract)
            let result = try process(
                fixture,
                lumaPolicy: .halfPixelCenter,
                chromaPolicy: .halfPixelCenter
            )
            let matched = try resultCell(
                result,
                lumaStrengthQ12: 3_072,
                chromaStrengthQ12: 3_072
            )

            XCTAssertTrue(fixture.dispatchGrid.dispatches.allSatisfy { dispatch in
                let secondaryMatches = dispatch.secondary.map {
                    $0.parameters.anisotropyStrength == 0.75
                } ?? true
                return dispatch.primary.parameters.anisotropyStrength == 0.75
                    && secondaryMatches
            })
            XCTAssertEqual(
                matched.luma.output,
                try productionOutput(fixture, plane: fixture.lumaPlane, chromaSiting: nil)
            )
            XCTAssertEqual(
                matched.cb.output,
                try productionOutput(fixture, plane: fixture.cbPlane, chromaSiting: .left)
            )
            XCTAssertEqual(
                matched.cr.output,
                try productionOutput(fixture, plane: fixture.crPlane, chromaSiting: .left)
            )
        }
    }

    func testOverrideCopiesOnlyAnisotropyAndNilIsIdentity() throws {
        let fixture = try makeFixture(
            route: .direct2x,
            contract: loadedContract()
        )
        let source = try XCTUnwrap(fixture.dispatchGrid.dispatches.first).primary.parameters

        XCTAssertEqual(
            ASHLockedRuntimeV2.parametersByApplyingDiagnosticAnisotropyOverride(
                source,
                anisotropyStrengthQ12Override: nil
            ),
            source
        )
        for strength in [UInt16(0), UInt16(3_072)] {
            let overridden = ASHLockedRuntimeV2
                .parametersByApplyingDiagnosticAnisotropyOverride(
                    source,
                    anisotropyStrengthQ12Override: strength
                )
            XCTAssertEqual(overridden.anisotropyStrength, Double(strength) / 4_096.0)
            assertNonAnisotropyParametersEqual(source, overridden)
        }
    }

    func testDiagnosticOverridePreservesConservativeFallbackSemantics() throws {
        let fixture = try makeFixture(
            route: .direct2x,
            contract: loadedContract()
        )
        let fallbackGrid = try forcedFallbackGrid(fixture)
        var values: [Double] = []

        for strength in [UInt16(0), UInt16(3_072)] {
            let result = try ASHLockedRuntimeV2.evaluateSampleForDiagnostic(
                dispatchGrid: fallbackGrid,
                configuration: fixture.runtime.configuration,
                analysisGrid: fixture.analysisGrid,
                plane: fixture.lumaPlane,
                destinationColumn: 0,
                destinationRow: 0,
                chromaSiting: nil,
                coordinatePolicyOverride: .halfPixelCenter,
                anisotropyStrengthQ12Override: strength
            )
            XCTAssertTrue(result.numericalFallbackUsed)
            XCTAssertEqual(result.primaryResult.descriptorID, 0)
            XCTAssertNil(result.secondaryResult)
            XCTAssertTrue(result.value.isFinite)
            values.append(result.value)
        }
        XCTAssertEqual(values[0], values[1])
    }

    func testExactAnisotropyDimensionRejectsReorderingAndAlteration() throws {
        let fixture = try makeFixture(
            route: .direct2x,
            contract: loadedContract()
        )
        let exact = ASHLockedPlanePolicyDiagnosticV3.requiredAnisotropyCells
        XCTAssertEqual(exact, [
            .init(lumaStrengthQ12: 0, chromaStrengthQ12: 0),
            .init(lumaStrengthQ12: 0, chromaStrengthQ12: 3_072),
            .init(lumaStrengthQ12: 3_072, chromaStrengthQ12: 0),
            .init(lumaStrengthQ12: 3_072, chromaStrengthQ12: 3_072)
        ])

        try assertInvalidAnisotropyCells(fixture, cells: exact.reversed())
        try assertInvalidAnisotropyCells(fixture, cells: Array(exact.dropLast()))
        var altered = exact
        altered[1] = .init(lumaStrengthQ12: 0, chromaStrengthQ12: 2_048)
        try assertInvalidAnisotropyCells(fixture, cells: altered)
    }

    func testRouteConfigurationContextAndGenericGridGuardsRemainActive() throws {
        let fixture = try makeFixture(
            route: .direct2x,
            contract: loadedContract()
        )
        let baseRequest = try request(
            fixture,
            lumaPolicy: .halfPixelCenter,
            chromaPolicy: .halfPixelCenter
        )

        let wrongRouteSelection = try ASHCoordinateDiagnosticRouteSelectionV3(
            route: .direct3Over2,
            lumaCoordinatePolicy: .halfPixelCenter,
            chromaCoordinatePolicy: .halfPixelCenter,
            contract: fixture.contract
        )
        XCTAssertThrowsError(try ASHLockedPlanePolicyDiagnosticV3.process(.init(
            selection: wrongRouteSelection,
            lumaPlane: baseRequest.lumaPlane,
            cbPlane: baseRequest.cbPlane,
            crPlane: baseRequest.crPlane,
            dispatchGrid: baseRequest.dispatchGrid,
            configuration: baseRequest.configuration,
            analysisGrid: baseRequest.analysisGrid,
            chromaSiting: baseRequest.chromaSiting,
            anisotropyCells: baseRequest.anisotropyCells
        ))) { error in
            XCTAssertEqual(error as? ASHLockedPlanePolicyDiagnosticV3Error, .routeMismatch)
        }

        let differentConfiguration = try ASHLockedRuntimeTestSupportV2.configurationCopy(
            fixture.runtime.configuration,
            configurationID: "ash-p06-runtime-diagnostic-mismatch"
        )
        try assertRequestError(
            baseRequest,
            dispatchGrid: baseRequest.dispatchGrid,
            configuration: differentConfiguration,
            expected: .configurationMismatch
        )
        try assertRequestError(
            baseRequest,
            dispatchGrid: gridCopy(baseRequest.dispatchGrid, context: .temporalPrevious),
            configuration: baseRequest.configuration,
            expected: .requiresSpatialOnlyDispatchGrid
        )
        try assertRequestError(
            baseRequest,
            dispatchGrid: try gridWithSourceAlignedEntryFlag(baseRequest.dispatchGrid),
            configuration: baseRequest.configuration,
            expected: .requiresGenericDispatchGrid
        )
    }

    func testGenericGridDoesNotRequireLockedHalfPixelCoordinatePolicy() throws {
        let contract = try loadedContract()
        for route in ASHCoordinateModelRouteV3.allCases {
            let fixture = try makeFixture(route: route, contract: contract)
            let sourceConfiguration = fixture.runtime.configuration
            let routeSelection = try ASHLUTLockedRouteSelectionV2(
                coordinatePolicy: .sourceAlignedRational,
                analysisGridSourceStep: sourceConfiguration
                    .routeSelection(for: fixture.spatialRoute)
                    .analysisGridSourceStep
            )
            let configuration = try configurationCopy(
                sourceConfiguration,
                routes: ASHLUTLockedRoutesV2(
                    direct2x: routeSelection,
                    direct3Over2: routeSelection
                )
            )
            let grid = gridCopy(
                fixture.dispatchGrid,
                configuration: configuration
            )
            let selection = try ASHCoordinateDiagnosticRouteSelectionV3(
                route: route,
                lumaCoordinatePolicy: .sourceAlignedRational,
                chromaCoordinatePolicy: .sourceAlignedRational,
                contract: contract
            )
            let result = try ASHLockedPlanePolicyDiagnosticV3.process(.init(
                selection: selection,
                lumaPlane: fixture.lumaPlane,
                cbPlane: fixture.cbPlane,
                crPlane: fixture.crPlane,
                dispatchGrid: grid,
                configuration: configuration,
                analysisGrid: fixture.analysisGrid,
                chromaSiting: .left,
                anisotropyCells: ASHLockedPlanePolicyDiagnosticV3.requiredAnisotropyCells
            ))
            XCTAssertEqual(result.anisotropyCells.count, 4)
        }
    }

    private func makeFixture(
        route: ASHCoordinateModelRouteV3,
        contract: ASHCoordinateModelContractV3
    ) throws -> Fixture {
        let spatialRoute = spatialRoute(for: route)
        let codePlanes = try ASHLockedRuntimeTestSupportV2.planes()
        let runtime = try runtimeFixture(
            route: spatialRoute,
            policy: .halfPixelCenter,
            step: spatialRoute == .direct2x ? 1 : 2,
            anisotropyStrengthQ12: 3_072
        )
        let analysisGrid = try ASHLockedRuntimeTestSupportV2.analysisGrid(
            planes: codePlanes,
            configuration: runtime.configuration,
            route: spatialRoute,
            siting: .left
        )
        return Fixture(
            route: route,
            spatialRoute: spatialRoute,
            contract: contract,
            lumaPlane: try ASHLockedRuntimeTestSupportV2.spatialPlane(codePlanes.luma),
            cbPlane: try ASHLockedRuntimeTestSupportV2.spatialPlane(
                codePlanes.cb,
                chroma: true
            ),
            crPlane: try ASHLockedRuntimeTestSupportV2.spatialPlane(
                codePlanes.cr,
                chroma: true
            ),
            runtime: runtime,
            analysisGrid: analysisGrid,
            dispatchGrid: try ASHLockedRuntimeV2.makeDispatchGrid(
                lut: runtime.loaded,
                configuration: runtime.configuration,
                analysisGrid: analysisGrid
            )
        )
    }

    private func runtimeFixture(
        route: ASHSpatialRouteV2,
        policy: ASHSpatialCoordinatePolicyV2,
        step: Int,
        anisotropyStrengthQ12: UInt16
    ) throws -> ASHLockedRuntimeTestSupportV2.Fixture {
        let source = try ASHLockedRuntimeTestSupportV2.configuration(
            route: route,
            policy: policy,
            step: step
        )
        let locked = source.operatorParameters
        let parameters = try ASHLUTLockedOperatorParametersV2(
            anisotropyStrengthQ12: anisotropyStrengthQ12,
            minimumAnisotropicMagnitudeUNorm15: locked.minimumAnisotropicMagnitudeUNorm15,
            minimumAnisotropicCoherenceUNorm15: locked.minimumAnisotropicCoherenceUNorm15,
            detailGainQ12: locked.detailGainQ12,
            relaxedLimiterAlphaQ12: locked.relaxedLimiterAlphaQ12,
            riskSuppressionUNorm15: locked.riskSuppressionUNorm15,
            lowPassRadiusQ8x8: locked.lowPassRadiusQ8x8,
            weightEpsilonF32Bits: locked.weightEpsilonF32Bits
        )
        let configuration = try configurationCopy(source, operatorParameters: parameters)
        let compilation = try ASHLUTLeafCompilerV2.compile(
            route: route,
            configuration: configuration
        )
        let artifact = try ASHLUTBinaryCodecV2.serialize(compilation)
        return ASHLockedRuntimeTestSupportV2.Fixture(
            configuration: configuration,
            compilation: compilation,
            loaded: try ASHLUTBinaryCodecV2.load(
                artifact.data,
                expectedRoute: route,
                configuration: configuration
            )
        )
    }

    private func processCoordinateCells(_ fixture: Fixture) throws -> CoordinateCells {
        try CoordinateCells(
            halfHalf: process(
                fixture,
                lumaPolicy: .halfPixelCenter,
                chromaPolicy: .halfPixelCenter
            ),
            halfSource: process(
                fixture,
                lumaPolicy: .halfPixelCenter,
                chromaPolicy: .sourceAlignedRational
            ),
            sourceHalf: process(
                fixture,
                lumaPolicy: .sourceAlignedRational,
                chromaPolicy: .halfPixelCenter
            ),
            sourceSource: process(
                fixture,
                lumaPolicy: .sourceAlignedRational,
                chromaPolicy: .sourceAlignedRational
            )
        )
    }

    private func process(
        _ fixture: Fixture,
        lumaPolicy: ASHCoordinateModelPolicyV3,
        chromaPolicy: ASHCoordinateModelPolicyV3
    ) throws -> ASHLockedPlanePolicyDiagnosticResultV3 {
        try ASHLockedPlanePolicyDiagnosticV3.process(request(
            fixture,
            lumaPolicy: lumaPolicy,
            chromaPolicy: chromaPolicy
        ))
    }

    private func request(
        _ fixture: Fixture,
        lumaPolicy: ASHCoordinateModelPolicyV3,
        chromaPolicy: ASHCoordinateModelPolicyV3,
        anisotropyCells: [ASHLockedPlaneAnisotropyCellV3] =
            ASHLockedPlanePolicyDiagnosticV3.requiredAnisotropyCells
    ) throws -> ASHLockedPlanePolicyDiagnosticRequestV3 {
        let selection = try ASHCoordinateDiagnosticRouteSelectionV3(
            route: fixture.route,
            lumaCoordinatePolicy: lumaPolicy,
            chromaCoordinatePolicy: chromaPolicy,
            contract: fixture.contract
        )
        return ASHLockedPlanePolicyDiagnosticRequestV3(
            selection: selection,
            lumaPlane: fixture.lumaPlane,
            cbPlane: fixture.cbPlane,
            crPlane: fixture.crPlane,
            dispatchGrid: fixture.dispatchGrid,
            configuration: fixture.runtime.configuration,
            analysisGrid: fixture.analysisGrid,
            chromaSiting: .left,
            anisotropyCells: anisotropyCells
        )
    }

    private func resultCell(
        _ result: ASHLockedPlanePolicyDiagnosticResultV3,
        lumaStrengthQ12: UInt16,
        chromaStrengthQ12: UInt16
    ) throws -> ASHLockedPlaneAnisotropyResultV3 {
        try XCTUnwrap(result.anisotropyCells.first {
            $0.selection == ASHLockedPlaneAnisotropyCellV3(
                lumaStrengthQ12: lumaStrengthQ12,
                chromaStrengthQ12: chromaStrengthQ12
            )
        })
    }

    private func assertGenericDispatch(_ fixture: Fixture) {
        XCTAssertFalse(
            fixture.runtime.compilation.entries.contains(where: \.sourceAlignedExact)
        )
        XCTAssertFalse(
            fixture.dispatchGrid.dispatches.contains(where: \.sourceAlignedEntryFlag)
        )
    }

    private func assertShapesFlagsAndStrengths(
        _ fixture: Fixture,
        cells: CoordinateCells
    ) throws {
        let lumaSampleCount = try fixture.spatialRoute.destinationExtent(
            for: fixture.lumaPlane.width
        ) * fixture.spatialRoute.destinationExtent(for: fixture.lumaPlane.height)
        let chromaSampleCount = try fixture.spatialRoute.destinationExtent(
            for: fixture.cbPlane.width
        ) * fixture.spatialRoute.destinationExtent(for: fixture.cbPlane.height)

        for coordinateCell in cells.all {
            XCTAssertEqual(coordinateCell.route, fixture.route)
            XCTAssertEqual(coordinateCell.contractSHA256, fixture.contract.sha256)
            XCTAssertEqual(
                coordinateCell.anisotropyCells.map(\.selection),
                ASHLockedPlanePolicyDiagnosticV3.requiredAnisotropyCells
            )
            for cell in coordinateCell.anisotropyCells {
                XCTAssertEqual(cell.luma.anisotropyStrengthQ12, cell.selection.lumaStrengthQ12)
                XCTAssertEqual(cell.cb.anisotropyStrengthQ12, cell.selection.chromaStrengthQ12)
                XCTAssertEqual(cell.cr.anisotropyStrengthQ12, cell.selection.chromaStrengthQ12)
                XCTAssertEqual(cell.luma.output.normalizedSamples.count, lumaSampleCount)
                XCTAssertEqual(cell.cb.output.normalizedSamples.count, chromaSampleCount)
                XCTAssertEqual(cell.cr.output.normalizedSamples.count, chromaSampleCount)
                for output in [cell.luma, cell.cb, cell.cr] {
                    XCTAssertEqual(output.sourceAlignedEntryFlagSampleCount, 0)
                    XCTAssertEqual(output.numericalFallbackCount, 0)
                }
            }
        }
    }

    private func assertCoordinatePlaneIndependence(
        _ cells: CoordinateCells
    ) throws {
        for selection in ASHLockedPlanePolicyDiagnosticV3.requiredAnisotropyCells {
            let halfHalf = try resultCell(cells.halfHalf, selection: selection)
            let halfSource = try resultCell(cells.halfSource, selection: selection)
            let sourceHalf = try resultCell(cells.sourceHalf, selection: selection)
            let sourceSource = try resultCell(cells.sourceSource, selection: selection)
            XCTAssertEqual(halfSource.luma, halfHalf.luma)
            XCTAssertEqual(sourceHalf.luma, sourceSource.luma)
            XCTAssertEqual(halfSource.cb, sourceSource.cb)
            XCTAssertEqual(halfSource.cr, sourceSource.cr)
            XCTAssertEqual(sourceHalf.cb, halfHalf.cb)
            XCTAssertEqual(sourceHalf.cr, halfHalf.cr)
        }
    }

    private func assertAnisotropyPlaneIndependence(
        _ cells: CoordinateCells
    ) throws {
        for coordinateCell in cells.all {
            let zeroZero = try resultCell(
                coordinateCell,
                lumaStrengthQ12: 0,
                chromaStrengthQ12: 0
            )
            let zeroChroma = try resultCell(
                coordinateCell,
                lumaStrengthQ12: 0,
                chromaStrengthQ12: 3_072
            )
            let lumaZero = try resultCell(
                coordinateCell,
                lumaStrengthQ12: 3_072,
                chromaStrengthQ12: 0
            )
            let lumaChroma = try resultCell(
                coordinateCell,
                lumaStrengthQ12: 3_072,
                chromaStrengthQ12: 3_072
            )
            assertPlanePayloadEqual(zeroZero.luma, zeroChroma.luma)
            assertPlanePayloadEqual(lumaZero.luma, lumaChroma.luma)
            assertPlanePayloadEqual(zeroZero.cb, lumaZero.cb)
            assertPlanePayloadEqual(zeroZero.cr, lumaZero.cr)
            assertPlanePayloadEqual(zeroChroma.cb, lumaChroma.cb)
            assertPlanePayloadEqual(zeroChroma.cr, lumaChroma.cr)
        }
    }

    private func assertPlanePayloadEqual(
        _ first: ASHLockedPlaneDiagnosticOutputV3,
        _ second: ASHLockedPlaneDiagnosticOutputV3
    ) {
        XCTAssertEqual(first.coordinatePolicy, second.coordinatePolicy)
        XCTAssertEqual(first.output, second.output)
        XCTAssertEqual(
            first.sourceAlignedSamplePreservationCount,
            second.sourceAlignedSamplePreservationCount
        )
        XCTAssertEqual(
            first.sourceAlignedEntryFlagSampleCount,
            second.sourceAlignedEntryFlagSampleCount
        )
        XCTAssertEqual(first.numericalFallbackCount, second.numericalFallbackCount)
    }

    private func assertSelectedPolicies(_ cells: CoordinateCells) {
        for index in ASHLockedPlanePolicyDiagnosticV3.requiredAnisotropyCells.indices {
            XCTAssertEqual(cells.halfHalf.anisotropyCells[index].luma.coordinatePolicy, .halfPixelCenter)
            XCTAssertEqual(cells.halfSource.anisotropyCells[index].luma.coordinatePolicy, .halfPixelCenter)
            XCTAssertEqual(cells.sourceHalf.anisotropyCells[index].luma.coordinatePolicy, .sourceAlignedRational)
            XCTAssertEqual(cells.sourceSource.anisotropyCells[index].luma.coordinatePolicy, .sourceAlignedRational)
            XCTAssertEqual(cells.halfHalf.anisotropyCells[index].cb.coordinatePolicy, .halfPixelCenter)
            XCTAssertEqual(cells.sourceHalf.anisotropyCells[index].cb.coordinatePolicy, .halfPixelCenter)
            XCTAssertEqual(cells.halfSource.anisotropyCells[index].cb.coordinatePolicy, .sourceAlignedRational)
            XCTAssertEqual(cells.sourceSource.anisotropyCells[index].cb.coordinatePolicy, .sourceAlignedRational)
            XCTAssertEqual(cells.halfHalf.anisotropyCells[index].cr.coordinatePolicy, .halfPixelCenter)
            XCTAssertEqual(cells.sourceHalf.anisotropyCells[index].cr.coordinatePolicy, .halfPixelCenter)
            XCTAssertEqual(cells.halfSource.anisotropyCells[index].cr.coordinatePolicy, .sourceAlignedRational)
            XCTAssertEqual(cells.sourceSource.anisotropyCells[index].cr.coordinatePolicy, .sourceAlignedRational)
        }
    }

    private func assertIntegralPreservation(
        _ fixture: Fixture,
        cells: CoordinateCells
    ) {
        let expectedCount = fixture.spatialRoute == .direct2x ? 64 : 16
        for index in ASHLockedPlanePolicyDiagnosticV3.requiredAnisotropyCells.indices {
            XCTAssertEqual(
                cells.halfHalf.anisotropyCells[index]
                    .luma.sourceAlignedSamplePreservationCount,
                0
            )
            XCTAssertEqual(
                cells.halfSource.anisotropyCells[index]
                    .luma.sourceAlignedSamplePreservationCount,
                0
            )
            XCTAssertEqual(
                cells.sourceHalf.anisotropyCells[index]
                    .luma.sourceAlignedSamplePreservationCount,
                expectedCount
            )
            XCTAssertEqual(
                cells.sourceSource.anisotropyCells[index]
                    .luma.sourceAlignedSamplePreservationCount,
                expectedCount
            )
        }
    }

    private func productionOutput(
        _ fixture: Fixture,
        plane: ASHSpatialPlaneV2,
        chromaSiting: ASHChromaSitingV2?
    ) throws -> ASHLockedReferencePlaneOutputV2 {
        let width = try fixture.spatialRoute.destinationExtent(for: plane.width)
        let height = try fixture.spatialRoute.destinationExtent(for: plane.height)
        var samples: [Double] = []
        for row in 0..<height {
            for column in 0..<width {
                samples.append(try ASHLockedRuntimeV2.evaluateSample(
                    dispatchGrid: fixture.dispatchGrid,
                    configuration: fixture.runtime.configuration,
                    analysisGrid: fixture.analysisGrid,
                    plane: plane,
                    destinationColumn: column,
                    destinationRow: row,
                    chromaSiting: chromaSiting
                ).value)
            }
        }
        return ASHLockedReferencePlaneOutputV2(
            width: width,
            height: height,
            normalizedSamples: samples
        )
    }

    private func assertNonAnisotropyParametersEqual(
        _ source: ASHSpatialDevelopmentParametersV2,
        _ overridden: ASHSpatialDevelopmentParametersV2
    ) {
        XCTAssertEqual(overridden.minimumAnisotropicMagnitude, source.minimumAnisotropicMagnitude)
        XCTAssertEqual(overridden.minimumAnisotropicCoherence, source.minimumAnisotropicCoherence)
        XCTAssertEqual(overridden.controlledDetailGain, source.controlledDetailGain)
        XCTAssertEqual(overridden.relaxedLimiterAlpha, source.relaxedLimiterAlpha)
        XCTAssertEqual(overridden.riskDetailSuppressionThreshold, source.riskDetailSuppressionThreshold)
        XCTAssertEqual(overridden.lowPassRadius, source.lowPassRadius)
        XCTAssertEqual(overridden.weightEpsilon, source.weightEpsilon)
        XCTAssertEqual(overridden.supportRadius, source.supportRadius)
    }

    private func forcedFallbackGrid(_ fixture: Fixture) throws -> ASHLockedDispatchGridV2 {
        let source = try XCTUnwrap(fixture.dispatchGrid.dispatches.first)
        let sourceCandidate = source.primary
        let parameters = ASHSpatialDevelopmentParametersV2(
            anisotropyStrength: sourceCandidate.parameters.anisotropyStrength,
            minimumAnisotropicMagnitude: sourceCandidate.parameters.minimumAnisotropicMagnitude,
            minimumAnisotropicCoherence: sourceCandidate.parameters.minimumAnisotropicCoherence,
            controlledDetailGain: 0.25,
            relaxedLimiterAlpha: 0.0,
            riskDetailSuppressionThreshold: sourceCandidate.parameters.riskDetailSuppressionThreshold,
            lowPassRadius: 0.5,
            weightEpsilon: 0.6,
            supportRadius: 2.0
        )
        let candidate = ASHLockedRuntimeCandidateV2(
            decodedMessage: sourceCandidate.decodedMessage,
            descriptor: try ASHSpatialDescriptorV2(id: 4),
            affineDecode: sourceCandidate.affineDecode,
            sidecar: sourceCandidate.sidecar,
            orientationSector: sourceCandidate.orientationSector,
            parameters: parameters
        )
        let dispatch = ASHLockedRuntimeDispatchV2(
            sourceState: source.sourceState,
            parityWasRecomputed: source.parityWasRecomputed,
            primary: candidate,
            secondary: nil,
            primaryWeightUNorm16: .max,
            secondaryWeightUNorm16: 0,
            marginUNorm16: .max,
            affineFallbackUsed: source.affineFallbackUsed,
            sourceAlignedEntryFlag: false,
            counters: source.counters
        )
        return ASHLockedDispatchGridV2(
            route: fixture.dispatchGrid.route,
            configuration: fixture.dispatchGrid.configuration,
            context: fixture.dispatchGrid.context,
            analysisColumnCount: fixture.dispatchGrid.analysisColumnCount,
            analysisRowCount: fixture.dispatchGrid.analysisRowCount,
            dispatches: Array(
                repeating: dispatch,
                count: fixture.dispatchGrid.dispatches.count
            ),
            counters: fixture.dispatchGrid.counters
        )
    }

    private func assertInvalidAnisotropyCells<S: Sequence>(
        _ fixture: Fixture,
        cells: S
    ) throws where S.Element == ASHLockedPlaneAnisotropyCellV3 {
        let invalidRequest = try request(
            fixture,
            lumaPolicy: .halfPixelCenter,
            chromaPolicy: .halfPixelCenter,
            anisotropyCells: Array(cells)
        )
        XCTAssertThrowsError(try ASHLockedPlanePolicyDiagnosticV3.process(invalidRequest)) { error in
            XCTAssertEqual(
                error as? ASHLockedPlanePolicyDiagnosticV3Error,
                .invalidAnisotropyCells
            )
        }
    }

    private func assertRequestError(
        _ request: ASHLockedPlanePolicyDiagnosticRequestV3,
        dispatchGrid: ASHLockedDispatchGridV2,
        configuration: ASHLUTLockedConfigurationV2,
        expected: ASHLockedPlanePolicyDiagnosticV3Error
    ) throws {
        XCTAssertThrowsError(try ASHLockedPlanePolicyDiagnosticV3.process(.init(
            selection: request.selection,
            lumaPlane: request.lumaPlane,
            cbPlane: request.cbPlane,
            crPlane: request.crPlane,
            dispatchGrid: dispatchGrid,
            configuration: configuration,
            analysisGrid: request.analysisGrid,
            chromaSiting: request.chromaSiting,
            anisotropyCells: request.anisotropyCells
        ))) { error in
            XCTAssertEqual(error as? ASHLockedPlanePolicyDiagnosticV3Error, expected)
        }
    }

    private func resultCell(
        _ result: ASHLockedPlanePolicyDiagnosticResultV3,
        selection: ASHLockedPlaneAnisotropyCellV3
    ) throws -> ASHLockedPlaneAnisotropyResultV3 {
        try XCTUnwrap(result.anisotropyCells.first { $0.selection == selection })
    }

    private func gridCopy(
        _ source: ASHLockedDispatchGridV2,
        configuration: ASHLUTLockedConfigurationV2? = nil,
        context: ASHLUTContextV2? = nil,
        dispatches: [ASHLockedRuntimeDispatchV2]? = nil
    ) -> ASHLockedDispatchGridV2 {
        ASHLockedDispatchGridV2(
            route: source.route,
            configuration: configuration ?? source.configuration,
            context: context ?? source.context,
            analysisColumnCount: source.analysisColumnCount,
            analysisRowCount: source.analysisRowCount,
            dispatches: dispatches ?? source.dispatches,
            counters: source.counters
        )
    }

    private func gridWithSourceAlignedEntryFlag(
        _ source: ASHLockedDispatchGridV2
    ) throws -> ASHLockedDispatchGridV2 {
        var dispatches = source.dispatches
        let dispatch = try XCTUnwrap(dispatches.first)
        dispatches[0] = ASHLockedRuntimeDispatchV2(
            sourceState: dispatch.sourceState,
            parityWasRecomputed: dispatch.parityWasRecomputed,
            primary: dispatch.primary,
            secondary: dispatch.secondary,
            primaryWeightUNorm16: dispatch.primaryWeightUNorm16,
            secondaryWeightUNorm16: dispatch.secondaryWeightUNorm16,
            marginUNorm16: dispatch.marginUNorm16,
            affineFallbackUsed: dispatch.affineFallbackUsed,
            sourceAlignedEntryFlag: true,
            counters: dispatch.counters
        )
        return gridCopy(source, dispatches: dispatches)
    }

    private func configurationCopy(
        _ source: ASHLUTLockedConfigurationV2,
        operatorParameters: ASHLUTLockedOperatorParametersV2? = nil,
        routes: ASHLUTLockedRoutesV2? = nil
    ) throws -> ASHLUTLockedConfigurationV2 {
        try ASHLUTLockedConfigurationV2(
            configurationID: source.configurationID,
            mappingSHA256: source.mappingSHA256,
            operatorBankSHA256: source.operatorBankSHA256,
            metricPolicySHA256: source.metricPolicySHA256,
            compilerInputsSHA256: source.compilerInputsSHA256,
            calibrationPlanSHA256: source.calibrationPlanSHA256,
            corpusLockBundleSHA256: source.corpusLockBundleSHA256,
            boundaryMode: source.boundaryMode,
            operatorParameters: operatorParameters ?? source.operatorParameters,
            semanticSteps: source.semanticSteps,
            compilerPolicy: source.compilerPolicy,
            routes: routes ?? source.routes
        )
    }

    private func spatialRoute(
        for route: ASHCoordinateModelRouteV3
    ) -> ASHSpatialRouteV2 {
        switch route {
        case .direct2x: .direct2x
        case .direct3Over2: .direct3Over2
        }
    }

    private func loadedContract() throws -> ASHCoordinateModelContractV3 {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: repositoryRoot.appendingPathComponent(
            "validation/calibration_v2/contracts/coordinate-model-contract-v3.json"
        ))
        return try ASHCoordinateModelContractV3.load(data)
    }
}

// swiftlint:enable file_length type_body_length
