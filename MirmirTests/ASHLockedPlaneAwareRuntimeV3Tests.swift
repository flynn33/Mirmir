import XCTest
@testable import Mirmir

// The route/plane matrix remains together so parity coverage is auditable as one unit.
// swiftlint:disable file_length
// swiftlint:disable:next type_body_length
final class ASHLockedPlaneAwareRuntimeV3Tests: XCTestCase {
    private struct LoadedFixture {
        let configuration: ASHLUTLockedConfigurationV3
        let compilation: ASHLUTCompilationV3
        let loaded: ASHLUTLoadedV3
    }

    private struct CodePlanes {
        let luma: ASHVideoAnalyzerV2CodePlane
        let cb: ASHVideoAnalyzerV2CodePlane
        let cr: ASHVideoAnalyzerV2CodePlane
    }

    private static let defaultFixtureResult: Result<LoadedFixture, Error> = Result {
        let fixture = try ASHLUTTestSupportV3.direct2x()
        return LoadedFixture(
            configuration: fixture.configuration,
            compilation: fixture.compilation,
            loaded: try ASHLUTBinaryCodecV3.load(
                fixture.artifact.data,
                expectedRoute: .direct2x,
                configuration: fixture.configuration
            )
        )
    }

    private static let modeZeroFixtureResult: Result<LoadedFixture, Error> = Result {
        let base = try ASHLUTTestSupportV3.sharedConfiguration()
        let baseSelection = base.routes.direct2x
        let direct2x = try ASHLUTTestSupportV3.routeSelection(
            policyID: baseSelection.spatialPolicyID,
            lumaMode: .isotropic,
            chromaMode: baseSelection.chromaAnisotropyMode,
            lumaCoordinatePolicy: baseSelection.lumaCoordinatePolicy,
            chromaCoordinatePolicy: baseSelection.chromaCoordinatePolicy,
            analysisGridSourceStep: baseSelection.analysisGridSourceStep
        )
        let configuration = try ASHLUTTestSupportV3.configuration(
            direct2x: direct2x,
            configurationID: "format-1.2-runtime-mode-zero"
        )
        let compilation = try ASHLUTLeafCompilerV3.compile(
            route: .direct2x,
            configuration: configuration
        )
        let artifact = try ASHLUTBinaryCodecV3.serialize(compilation)
        return LoadedFixture(
            configuration: configuration,
            compilation: compilation,
            loaded: try ASHLUTBinaryCodecV3.load(
                artifact.data,
                expectedRoute: .direct2x,
                configuration: configuration
            )
        )
    }

    func testModeZeroAndOneRemainOperationallyDistinctAtZeroStrength() throws {
        let modeZero = try Self.modeZeroFixtureResult.get()
        let modeOne = try Self.defaultFixtureResult.get()
        guard let zeroEntry = modeZero.compilation.entries.first(where: {
            $0.planeRole == .luma
                && $0.context == .spatialOnly
                && $0.phaseOrdinal != 0
                && $0.primary.descriptorID & 0b0010 != 0
        }) else {
            return XCTFail("fixture lacks a non-source-exact anisotropic primary entry")
        }
        let oneEntry = modeOne.compilation.entries[zeroEntry.logicalIndex]
        XCTAssertEqual(oneEntry.sourceState, zeroEntry.sourceState)
        XCTAssertEqual(oneEntry.phaseOrdinal, zeroEntry.phaseOrdinal)
        XCTAssertEqual(oneEntry.primary.descriptorID, zeroEntry.primary.descriptorID)

        let sidecar = try makeSidecar(chromaEdgeConfidence: 0.375)
        let zeroDispatch = try ASHLockedRuntimeV3.dispatch(
            lut: modeZero.loaded,
            configuration: modeZero.configuration,
            planeRole: .luma,
            sourceState: zeroEntry.sourceState,
            phaseOrdinal: Int(zeroEntry.phaseOrdinal),
            sidecar: sidecar
        )
        let oneDispatch = try ASHLockedRuntimeV3.dispatch(
            lut: modeOne.loaded,
            configuration: modeOne.configuration,
            planeRole: .luma,
            sourceState: zeroEntry.sourceState,
            phaseOrdinal: Int(zeroEntry.phaseOrdinal),
            sidecar: sidecar
        )
        XCTAssertEqual(zeroDispatch.primary.anisotropyMode, .isotropic)
        XCTAssertEqual(oneDispatch.primary.anisotropyMode, .rotatedZero)
        XCTAssertEqual(zeroDispatch.primary.anisotropyStrengthQ12, 0)
        XCTAssertEqual(oneDispatch.primary.anisotropyStrengthQ12, 0)
        XCTAssertFalse(zeroDispatch.primary.usesAnisotropy)
        XCTAssertTrue(oneDispatch.primary.usesAnisotropy)

        let plane = try asymmetricSpatialPlane(width: 7, height: 7)
        let horizontalPhase = Int(zeroEntry.phaseOrdinal) % 2
        let verticalPhase = Int(zeroEntry.phaseOrdinal) / 2
        let destinationColumn = 6 + horizontalPhase
        let destinationRow = 6 + verticalPhase
        let zeroResult = try ASHLockedRuntimeV3.evaluateCandidate(
            zeroDispatch.primary,
            plane: plane,
            destinationColumn: destinationColumn,
            destinationRow: destinationRow,
            route: .direct2x,
            coordinatePolicy: .sourceAlignedRational,
            boundary: modeZero.configuration.boundaryMode
        )
        let oneResult = try ASHLockedRuntimeV3.evaluateCandidate(
            oneDispatch.primary,
            plane: plane,
            destinationColumn: destinationColumn,
            destinationRow: destinationRow,
            route: .direct2x,
            coordinatePolicy: .sourceAlignedRational,
            boundary: modeOne.configuration.boundaryMode
        )
        XCTAssertFalse(zeroResult.sample.diagnostics.anisotropyUsed)
        XCTAssertTrue(oneResult.sample.diagnostics.anisotropyUsed)
        XCTAssertNotEqual(zeroResult.effectiveDescriptorID, oneResult.effectiveDescriptorID)
        XCTAssertNotEqual(zeroResult.sample.value.bitPattern, oneResult.sample.value.bitPattern)
    }

    func testFramePreparationUsesOneAnalyzerTraversalAndExactlyTwoPlaneGrids() throws {
        let fixture = try Self.defaultFixtureResult.get()
        let codePlanes = try makeCodePlanes(lumaWidth: 4, lumaHeight: 4)
        let immutableBytes = fixture.loaded.immutableBytes
        let frame = try ASHLockedRuntimeV3.prepareFrame(
            lut: fixture.loaded,
            configuration: fixture.configuration,
            luma: codePlanes.luma,
            cb: codePlanes.cb,
            cr: codePlanes.cr,
            chromaSiting: .center,
            analyzerConfiguration: try .makeDisposableP05Reference()
        )

        XCTAssertEqual(frame.constructionCounters.analyzerTraversalCount, 1)
        XCTAssertEqual(frame.constructionCounters.dispatchGridConstructionCount, 2)
        XCTAssertEqual(frame.constructionCounters.lutLoadCount, 0)
        XCTAssertEqual(frame.constructionCounters.jsonParsingCount, 0)
        XCTAssertEqual(frame.constructionCounters.runtimeTreeGenerationCount, 0)
        XCTAssertEqual(frame.constructionCounters.runtimePathConstructionCount, 0)
        XCTAssertEqual(fixture.loaded.immutableBytes, immutableBytes)
        XCTAssertEqual(frame.dispatchGrids.luma.planeRole, .luma)
        XCTAssertEqual(frame.dispatchGrids.chroma.planeRole, .chroma)
        XCTAssertEqual(frame.dispatchGrids.grid(for: .luma), frame.dispatchGrids.luma)
        XCTAssertEqual(frame.dispatchGrids.grid(for: .cb), frame.dispatchGrids.chroma)
        XCTAssertEqual(frame.dispatchGrids.grid(for: .cr), frame.dispatchGrids.chroma)
        XCTAssertEqual(
            frame.dispatchGrids.luma.dispatches.count,
            frame.analysisGrid.count * fixture.loaded.route.phasePairCount
        )
        XCTAssertEqual(
            frame.dispatchGrids.chroma.dispatches.count,
            frame.analysisGrid.count * fixture.loaded.route.phasePairCount
        )

        let lumaDispatch = try frame.dispatchGrids.luma.dispatch(
            cellColumn: 0,
            cellRow: 0,
            phaseOrdinal: 0
        )
        let chromaDispatch = try frame.dispatchGrids.chroma.dispatch(
            cellColumn: 0,
            cellRow: 0,
            phaseOrdinal: 0
        )
        XCTAssertTrue(lumaDispatch.sourceAlignedEntryFlag)
        XCTAssertFalse(chromaDispatch.sourceAlignedEntryFlag)
        XCTAssertEqual(lumaDispatch.primary.anisotropyMode, .rotatedZero)
        XCTAssertEqual(chromaDispatch.primary.anisotropyMode, .rotatedQ12x3072)
        let expectedConfidence = try frame.analysisGrid
            .cell(column: 0, row: 0)
            .analysis.sidecar.chromaEdgeConfidence.bitPattern
        XCTAssertEqual(
            lumaDispatch.primary.sidecar.chromaEdgeConfidenceBitPattern,
            expectedConfidence
        )
        XCTAssertEqual(
            chromaDispatch.primary.sidecar.chromaEdgeConfidenceBitPattern,
            expectedConfidence
        )
    }

    func testLumaAndChromaUsePlaneLocalCoordinatesAndCbCrShareChromaDispatch() throws {
        let fixture = try Self.defaultFixtureResult.get()
        let codePlanes = try makeCodePlanes(lumaWidth: 4, lumaHeight: 4)
        let frame = try ASHLockedRuntimeV3.prepareFrame(
            lut: fixture.loaded,
            configuration: fixture.configuration,
            luma: codePlanes.luma,
            cb: codePlanes.cb,
            cr: codePlanes.cr,
            chromaSiting: .center,
            analyzerConfiguration: try .makeDisposableP05Reference()
        )
        let lumaPlane = try spatialPlane(codePlanes.luma)
        let cbPlane = try spatialPlane(codePlanes.cb)
        let crPlane = try spatialPlane(codePlanes.cr)
        let luma = try ASHLockedRuntimeV3.evaluateSample(
            frame: frame,
            runtimePlane: .luma,
            plane: lumaPlane,
            destinationColumn: 0,
            destinationRow: 0,
            chromaSiting: nil
        )
        let cb = try ASHLockedRuntimeV3.evaluateSample(
            frame: frame,
            runtimePlane: .cb,
            plane: cbPlane,
            destinationColumn: 0,
            destinationRow: 0,
            chromaSiting: .center
        )
        let cr = try ASHLockedRuntimeV3.evaluateSample(
            frame: frame,
            runtimePlane: .cr,
            plane: crPlane,
            destinationColumn: 0,
            destinationRow: 0,
            chromaSiting: .center
        )

        XCTAssertEqual(luma.dispatch.planeRole, .luma)
        XCTAssertEqual(cb.dispatch.planeRole, .chroma)
        XCTAssertEqual(cr.dispatch.planeRole, .chroma)
        XCTAssertTrue(luma.dispatch.sourceAlignedEntryFlag)
        XCTAssertTrue(luma.sourceAlignedSamplePreserved)
        XCTAssertFalse(cb.dispatch.sourceAlignedEntryFlag)
        XCTAssertFalse(cr.dispatch.sourceAlignedEntryFlag)
        XCTAssertFalse(cb.sourceAlignedSamplePreserved)
        XCTAssertFalse(cr.sourceAlignedSamplePreserved)
        XCTAssertEqual(cb.dispatch, cr.dispatch)
        XCTAssertEqual(cb.sourceCoordinates, cr.sourceCoordinates)
        XCTAssertThrowsError(try ASHLockedRuntimeV3.evaluateSample(
            frame: frame,
            runtimePlane: .luma,
            plane: lumaPlane,
            destinationColumn: 0,
            destinationRow: 0,
            chromaSiting: .center
        )) { error in
            XCTAssertEqual(error as? ASHLockedRuntimeV3Error, .invalidChromaSiting)
        }
        XCTAssertThrowsError(try ASHLockedRuntimeV3.evaluateSample(
            frame: frame,
            runtimePlane: .cb,
            plane: cbPlane,
            destinationColumn: 0,
            destinationRow: 0,
            chromaSiting: nil
        )) { error in
            XCTAssertEqual(error as? ASHLockedRuntimeV3Error, .invalidChromaSiting)
        }
    }

    func testFrameEvaluationRejectsMismatchedChromaSitingAndAcceptsPreparedSiting() throws {
        let fixture = try Self.defaultFixtureResult.get()
        let codePlanes = try makeCodePlanes(lumaWidth: 4, lumaHeight: 4)
        let cbPlane = try spatialPlane(codePlanes.cb)
        let centerFrame = try ASHLockedRuntimeV3.prepareFrame(
            lut: fixture.loaded,
            configuration: fixture.configuration,
            luma: codePlanes.luma,
            cb: codePlanes.cb,
            cr: codePlanes.cr,
            chromaSiting: .center,
            analyzerConfiguration: try .makeDisposableP05Reference()
        )
        let centerResult = try ASHLockedRuntimeV3.evaluateSample(
            frame: centerFrame,
            runtimePlane: .cb,
            plane: cbPlane,
            destinationColumn: 0,
            destinationRow: 0,
            chromaSiting: .center
        )

        XCTAssertEqual(centerFrame.chromaSiting, .center)
        XCTAssertEqual(centerResult.runtimePlane, .cb)
        XCTAssertThrowsError(try ASHLockedRuntimeV3.evaluateSample(
            frame: centerFrame,
            runtimePlane: .cb,
            plane: cbPlane,
            destinationColumn: 0,
            destinationRow: 0,
            chromaSiting: .left
        )) { error in
            XCTAssertEqual(error as? ASHLockedRuntimeV3Error, .invalidChromaSiting)
        }

        let leftFrame = try ASHLockedRuntimeV3.prepareFrame(
            lut: fixture.loaded,
            configuration: fixture.configuration,
            luma: codePlanes.luma,
            cb: codePlanes.cb,
            cr: codePlanes.cr,
            chromaSiting: .left,
            analyzerConfiguration: try .makeDisposableP05Reference()
        )
        let leftResult = try ASHLockedRuntimeV3.evaluateSample(
            frame: leftFrame,
            runtimePlane: .cb,
            plane: cbPlane,
            destinationColumn: 0,
            destinationRow: 0,
            chromaSiting: .left
        )

        XCTAssertEqual(leftFrame.chromaSiting, .left)
        XCTAssertEqual(leftResult.runtimePlane, .cb)
        XCTAssertNotEqual(centerResult.sourceCoordinates, leftResult.sourceCoordinates)
    }

    // swiftlint:disable:next function_body_length
    func testFormat12EvaluationParityUsesExactLeftSitingForBothRoutes() throws {
        let fixtures = try ASHSpatialRouteV2.allCases.map { route -> LoadedFixture in
            let source = route == .direct2x
                ? try ASHLUTTestSupportV3.direct2x()
                : try ASHLUTTestSupportV3.direct3Over2()
            return LoadedFixture(
                configuration: source.configuration,
                compilation: source.compilation,
                loaded: try ASHLUTBinaryCodecV3.load(
                    source.artifact.data,
                    expectedRoute: route,
                    configuration: source.configuration
                )
            )
        }
        let codePlanes = try makeCodePlanes(lumaWidth: 4, lumaHeight: 4)
        // swiftlint:disable:next large_tuple
        let planes: [(ASHRuntimePlaneV3, ASHSpatialPlaneV2, ASHChromaSitingV2?)] = [
            (.luma, try spatialPlane(codePlanes.luma), nil),
            (.cb, try spatialPlane(codePlanes.cb), .left),
            (.cr, try spatialPlane(codePlanes.cr), .left)
        ]

        for fixture in fixtures {
            let frame = try ASHLockedRuntimeV3.prepareFrame(
                lut: fixture.loaded,
                configuration: fixture.configuration,
                luma: codePlanes.luma,
                cb: codePlanes.cb,
                cr: codePlanes.cr,
                chromaSiting: .left,
                analyzerConfiguration: try .makeDisposableP05Reference()
            )
            XCTAssertEqual(frame.chromaSiting, .left)
            XCTAssertEqual(frame.dispatchGrids.luma.route, fixture.loaded.route)
            XCTAssertEqual(frame.dispatchGrids.chroma.route, fixture.loaded.route)

            for (runtimePlane, plane, siting) in planes {
                let expectedCoordinates = leftSitingCoordinateOracle(
                    route: fixture.loaded.route,
                    runtimePlane: runtimePlane
                )
                let framed = try ASHLockedRuntimeV3.evaluateSample(
                    frame: frame,
                    runtimePlane: runtimePlane,
                    plane: plane,
                    destinationColumn: 2,
                    destinationRow: 2,
                    chromaSiting: siting
                )
                let direct = try ASHLockedRuntimeV3.evaluateSample(
                    dispatchGrid: frame.dispatchGrids.grid(for: runtimePlane),
                    configuration: fixture.configuration,
                    analysisGrid: frame.analysisGrid,
                    runtimePlane: runtimePlane,
                    plane: plane,
                    destinationColumn: 2,
                    destinationRow: 2,
                    chromaSiting: siting
                )
                XCTAssertEqual(framed, direct)
                XCTAssertEqual(framed.runtimePlane, runtimePlane)
                XCTAssertEqual(framed.sourceCoordinates, expectedCoordinates)
                XCTAssertEqual(
                    framed.primaryResult.sample.sourceX,
                    expectedCoordinates.horizontal
                )
                XCTAssertEqual(
                    framed.primaryResult.sample.sourceY,
                    expectedCoordinates.vertical
                )
                XCTAssertEqual(
                    framed.dispatch.planeRole,
                    runtimePlane == .luma ? .luma : .chroma
                )
                XCTAssertFalse(framed.numericalFallbackUsed)

                let coordinatePolicy = fixture.configuration
                    .routeSelection(for: fixture.loaded.route)
                    .coordinatePolicy(for: runtimePlane.lutPlaneRole)
                let expectedPrimary = try ASHLockedRuntimeV3.evaluateCandidate(
                    framed.dispatch.primary,
                    plane: plane,
                    destinationColumn: 2,
                    destinationRow: 2,
                    route: fixture.loaded.route,
                    coordinatePolicy: coordinatePolicy,
                    boundary: fixture.configuration.boundaryMode,
                    sourceCoordinates: expectedCoordinates
                )
                XCTAssertEqual(framed.primaryResult, expectedPrimary)

                let expectedValue: Double
                if let secondary = framed.dispatch.secondary {
                    let expectedSecondary = try ASHLockedRuntimeV3.evaluateCandidate(
                        secondary,
                        plane: plane,
                        destinationColumn: 2,
                        destinationRow: 2,
                        route: fixture.loaded.route,
                        coordinatePolicy: coordinatePolicy,
                        boundary: fixture.configuration.boundaryMode,
                        sourceCoordinates: expectedCoordinates
                    )
                    XCTAssertEqual(framed.secondaryResult, expectedSecondary)
                    let denominator = Double(UInt16.max)
                    expectedValue = plane.legalClamp(
                        (Double(framed.dispatch.primaryWeightUNorm16)
                            * expectedPrimary.sample.value / denominator)
                            + (Double(framed.dispatch.secondaryWeightUNorm16)
                                * expectedSecondary.sample.value / denominator)
                    )
                } else {
                    XCTAssertNil(framed.secondaryResult)
                    expectedValue = expectedPrimary.sample.value
                }
                XCTAssertEqual(framed.value.bitPattern, expectedValue.bitPattern)
            }
            let cbPlane = try spatialPlane(codePlanes.cb)
            XCTAssertThrowsError(try ASHLockedRuntimeV3.evaluateSample(
                frame: frame,
                runtimePlane: .cb,
                plane: cbPlane,
                destinationColumn: 2,
                destinationRow: 2,
                chromaSiting: .center
            )) { error in
                XCTAssertEqual(error as? ASHLockedRuntimeV3Error, .invalidChromaSiting)
            }
        }
    }

    func testConfidenceTransportIsExactValidatedAndRuntimeInert() throws {
        let zero = try makeSidecar(chromaEdgeConfidence: 0.0)
        let one = try makeSidecar(chromaEdgeConfidence: 1.0)
        let fractionalValue = Double(bitPattern: 0x3fd5_5555_5555_5555)
        let fractional = try makeSidecar(chromaEdgeConfidence: fractionalValue)
        XCTAssertEqual(zero.chromaEdgeConfidenceBitPattern, 0.0.bitPattern)
        XCTAssertEqual(one.chromaEdgeConfidenceBitPattern, 1.0.bitPattern)
        XCTAssertEqual(fractional.chromaEdgeConfidenceBitPattern, fractionalValue.bitPattern)
        XCTAssertEqual(fractional.chromaEdgeConfidence.bitPattern, fractionalValue.bitPattern)

        for invalid in [
            -Double.leastNonzeroMagnitude,
            1.0.nextUp,
            Double.infinity,
            -Double.infinity,
            Double.nan
        ] {
            XCTAssertThrowsError(try makeSidecar(chromaEdgeConfidence: invalid)) { error in
                XCTAssertEqual(error as? ASHLockedRuntimeV3Error, .invalidSidecar)
            }
        }

        let fixture = try Self.defaultFixtureResult.get()
        guard let entry = fixture.compilation.entries.first(where: {
            $0.planeRole == .luma
                && $0.context == .spatialOnly
                && $0.phaseOrdinal != 0
        }) else {
            return XCTFail("fixture lacks a luma spatial entry")
        }
        let dispatches = try [zero, one, fractional].map {
            try ASHLockedRuntimeV3.dispatch(
                lut: fixture.loaded,
                configuration: fixture.configuration,
                planeRole: .luma,
                sourceState: entry.sourceState,
                phaseOrdinal: Int(entry.phaseOrdinal),
                sidecar: $0
            )
        }
        for dispatch in dispatches.dropFirst() {
            assertDispatchSemanticsEqual(dispatches[0], dispatch)
        }

        let plane = try asymmetricSpatialPlane(width: 7, height: 7)
        let results = try dispatches.map {
            try ASHLockedRuntimeV3.evaluateCandidate(
                $0.primary,
                plane: plane,
                destinationColumn: 7,
                destinationRow: 6,
                route: .direct2x,
                coordinatePolicy: .sourceAlignedRational,
                boundary: fixture.configuration.boundaryMode
            )
        }
        for result in results.dropFirst() {
            XCTAssertEqual(result, results[0])
            XCTAssertEqual(result.sample.value.bitPattern, results[0].sample.value.bitPattern)
        }
    }

    private func leftSitingCoordinateOracle(
        route: ASHSpatialRouteV2,
        runtimePlane: ASHRuntimePlaneV3
    ) -> ASHSpatialSourceCoordinatesV2 {
        let horizontal: ASHSpatialRationalCoordinateV2
        let vertical: ASHSpatialRationalCoordinateV2
        switch (route, runtimePlane) {
        case (.direct2x, .luma):
            horizontal = ASHSpatialRationalCoordinateV2(numerator: 8, denominator: 8)
            vertical = ASHSpatialRationalCoordinateV2(numerator: 8, denominator: 8)
        case (.direct2x, .cb), (.direct2x, .cr):
            horizontal = ASHSpatialRationalCoordinateV2(numerator: 112, denominator: 128)
            vertical = ASHSpatialRationalCoordinateV2(numerator: 96, denominator: 128)
        case (.direct3Over2, .luma):
            horizontal = ASHSpatialRationalCoordinateV2(numerator: 14, denominator: 12)
            vertical = ASHSpatialRationalCoordinateV2(numerator: 14, denominator: 12)
        case (.direct3Over2, .cb), (.direct3Over2, .cr):
            horizontal = ASHSpatialRationalCoordinateV2(numerator: 48, denominator: 36)
            vertical = ASHSpatialRationalCoordinateV2(numerator: 45, denominator: 36)
        }
        return ASHSpatialSourceCoordinatesV2(
            horizontal: horizontal,
            vertical: vertical
        )
    }

    private func assertDispatchSemanticsEqual(
        _ lhs: ASHLockedRuntimeDispatchV3,
        _ rhs: ASHLockedRuntimeDispatchV3,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(lhs.sourceState, rhs.sourceState, file: file, line: line)
        XCTAssertEqual(lhs.planeRole, rhs.planeRole, file: file, line: line)
        XCTAssertEqual(lhs.parityWasRecomputed, rhs.parityWasRecomputed, file: file, line: line)
        XCTAssertEqual(lhs.primary.decodedMessage, rhs.primary.decodedMessage, file: file, line: line)
        XCTAssertEqual(lhs.primary.descriptor, rhs.primary.descriptor, file: file, line: line)
        XCTAssertEqual(lhs.primary.affineDecode, rhs.primary.affineDecode, file: file, line: line)
        XCTAssertEqual(lhs.primary.orientationSector, rhs.primary.orientationSector, file: file, line: line)
        XCTAssertEqual(lhs.primary.anisotropyMode, rhs.primary.anisotropyMode, file: file, line: line)
        XCTAssertEqual(lhs.primary.parameters, rhs.primary.parameters, file: file, line: line)
        XCTAssertEqual(lhs.secondary?.decodedMessage, rhs.secondary?.decodedMessage, file: file, line: line)
        XCTAssertEqual(lhs.secondary?.descriptor, rhs.secondary?.descriptor, file: file, line: line)
        XCTAssertEqual(lhs.secondary?.affineDecode, rhs.secondary?.affineDecode, file: file, line: line)
        XCTAssertEqual(lhs.secondary?.orientationSector, rhs.secondary?.orientationSector, file: file, line: line)
        XCTAssertEqual(lhs.secondary?.anisotropyMode, rhs.secondary?.anisotropyMode, file: file, line: line)
        XCTAssertEqual(lhs.secondary?.parameters, rhs.secondary?.parameters, file: file, line: line)
        XCTAssertEqual(lhs.primaryWeightUNorm16, rhs.primaryWeightUNorm16, file: file, line: line)
        XCTAssertEqual(lhs.secondaryWeightUNorm16, rhs.secondaryWeightUNorm16, file: file, line: line)
        XCTAssertEqual(lhs.marginUNorm16, rhs.marginUNorm16, file: file, line: line)
        XCTAssertEqual(lhs.affineFallbackUsed, rhs.affineFallbackUsed, file: file, line: line)
        XCTAssertEqual(lhs.sourceAlignedEntryFlag, rhs.sourceAlignedEntryFlag, file: file, line: line)
    }

    private func makeSidecar(chromaEdgeConfidence: Double) throws -> ASHSpatialSidecarV3 {
        try ASHSpatialSidecarV3(
            orientationRadians: .pi / 7.0,
            normalizedMagnitude: 1.0,
            coherence: 1.0,
            risk: 0.0,
            chromaAlignment: 1.0,
            chromaEdgeConfidence: chromaEdgeConfidence,
            localMinimum: 0.0,
            localMaximum: 1.0
        )
    }

    private func makeCodePlanes(lumaWidth: Int, lumaHeight: Int) throws -> CodePlanes {
        let luma = try codePlane(width: lumaWidth, height: lumaHeight) { column, row in
            let horizontal = column * 29
            let vertical = row * 41
            let interaction = column * row * 3
            return UInt8(16 + ((horizontal + vertical + interaction) % 220))
        }
        let cb = try codePlane(width: lumaWidth / 2, height: lumaHeight / 2) { column, row in
            UInt8(16 + ((column * 47 + row * 19) % 220))
        }
        let cr = try codePlane(width: lumaWidth / 2, height: lumaHeight / 2) { column, row in
            UInt8(235 - ((column * 31 + row * 43) % 220))
        }
        return CodePlanes(luma: luma, cb: cb, cr: cr)
    }

    private func codePlane(
        width: Int,
        height: Int,
        generator: (Int, Int) -> UInt8
    ) throws -> ASHVideoAnalyzerV2CodePlane {
        var codes: [UInt8] = []
        codes.reserveCapacity(width * height)
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

    private func spatialPlane(_ plane: ASHVideoAnalyzerV2CodePlane) throws -> ASHSpatialPlaneV2 {
        var samples: [Double] = []
        samples.reserveCapacity(plane.width * plane.height)
        for row in 0..<plane.height {
            let offset = row * plane.bytesPerRow
            for column in 0..<plane.width {
                samples.append(Double(plane.codes[offset + column]) / 255.0)
            }
        }
        return try ASHSpatialPlaneV2(
            width: plane.width,
            height: plane.height,
            samples: samples
        )
    }

    private func asymmetricSpatialPlane(width: Int, height: Int) throws -> ASHSpatialPlaneV2 {
        var samples: [Double] = []
        samples.reserveCapacity(width * height)
        for row in 0..<height {
            for column in 0..<width {
                let value = (column * 17) + (row * 31) + (column * row * 7) + (row * row * 3)
                samples.append(Double(value % 101) / 100.0)
            }
        }
        return try ASHSpatialPlaneV2(width: width, height: height, samples: samples)
    }
}
