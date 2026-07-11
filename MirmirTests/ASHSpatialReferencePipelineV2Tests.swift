import XCTest
@testable import Mirmir

final class ASHSpatialReferencePipelineV2Tests: XCTestCase {
    private struct ChromaCoordinateCase {
        let route: ASHSpatialRouteV2
        let sourceExtent: Int
        let destinationExtent: Int
        let sourceAlignedCenter: Double
        let halfPixelCenter: Double
    }

    func test_directRoutesReconstructAllThreePlanesAtExactDimensions() throws {
        for route in ASHSpatialRouteV2.allCases {
            let output = try ASHSpatialReferencePipelineV2.process(makeInput(route: route))
            let expectedLumaWidth = try route.destinationExtent(for: 8)
            let expectedLumaHeight = try route.destinationExtent(for: 8)
            let expectedChromaWidth = try route.destinationExtent(for: 4)
            let expectedChromaHeight = try route.destinationExtent(for: 4)

            XCTAssertEqual(output.luma.width, expectedLumaWidth)
            XCTAssertEqual(output.luma.height, expectedLumaHeight)
            XCTAssertEqual(output.cb.width, expectedChromaWidth)
            XCTAssertEqual(output.cb.height, expectedChromaHeight)
            XCTAssertEqual(output.cr.width, expectedChromaWidth)
            XCTAssertEqual(output.cr.height, expectedChromaHeight)
            XCTAssertEqual(output.summary.analysisSampleCount, 64)
            XCTAssertEqual(output.summary.reconstructedLumaSampleCount, expectedLumaWidth * expectedLumaHeight)
            XCTAssertEqual(
                output.summary.reconstructedChromaSampleCount,
                2 * expectedChromaWidth * expectedChromaHeight
            )
        }
    }

    func test_pipelineIsCausalBoundedSpatialOnlyAndDoesNotUseExpandedSubstrate() throws {
        let output = try ASHSpatialReferencePipelineV2.process(makeInput(route: .direct2x))

        XCTAssertGreaterThan(output.summary.stateHistogram.count, 1)
        XCTAssertGreaterThan(output.summary.operatorHistogram.count, 1)
        XCTAssertLessThanOrEqual(output.summary.maxOperatorEvaluations, 2)
        XCTAssertEqual(output.summary.temporalStateCount, 0)
        XCTAssertEqual(output.summary.parityRecomputationCount, 0)
        XCTAssertEqual(output.summary.runtimeTreeGenerationCount, 0)
        XCTAssertFalse(output.summary.nearestExpansionUsed)
        XCTAssertGreaterThan(output.summary.sourceAlignedPreservationCount, 0)
    }

    func test_stateDisabledControlChangesDirectReconstruction() throws {
        let enabled = try ASHSpatialReferencePipelineV2.process(
            makeInput(route: .direct2x, stateInputEnabled: true)
        )
        let disabled = try ASHSpatialReferencePipelineV2.process(
            makeInput(route: .direct2x, stateInputEnabled: false)
        )
        let deltas = zip(enabled.luma.normalizedSamples, disabled.luma.normalizedSamples).map {
            abs($0 - $1)
        }

        XCTAssertGreaterThan(deltas.max() ?? 0.0, 1.0e-8)
        XCTAssertNotEqual(enabled.summary.operatorHistogram, disabled.summary.operatorHistogram)
    }

    func test_chromaIsDirectlyInterpolatedAndCbCrRemainIndependent() throws {
        let input = try makeInput(route: .direct2x)
        let output = try ASHSpatialReferencePipelineV2.process(input)
        let sourceCb = normalizedChroma(input.cb.codes[0], range: input.cb.range)
        let sourceCr = normalizedChroma(input.cr.codes[0], range: input.cr.range)

        XCTAssertNotEqual(output.cb.normalizedSamples[1], sourceCb, accuracy: 1.0e-8)
        XCTAssertNotEqual(output.cr.normalizedSamples[1], sourceCr, accuracy: 1.0e-8)
        XCTAssertNotEqual(output.cb.normalizedSamples, output.cr.normalizedSamples)
    }

    func test_chromaSitingOffsetTableProducesExactPolicyAndRouteCoordinates() throws {
        let cases = [
            ChromaCoordinateCase(
                route: .direct2x,
                sourceExtent: 4,
                destinationExtent: 8,
                sourceAlignedCenter: -1.0 / 8.0,
                halfPixelCenter: -1.0 / 4.0
            ),
            ChromaCoordinateCase(
                route: .direct3Over2,
                sourceExtent: 6,
                destinationExtent: 9,
                sourceAlignedCenter: -1.0 / 12.0,
                halfPixelCenter: -1.0 / 6.0
            )
        ]
        for testCase in cases {
            XCTAssertEqual(
                try chromaCoordinate(.center, .horizontal, .sourceAlignedRational, testCase),
                testCase.sourceAlignedCenter,
                accuracy: 0.0,
                testCase.route.rawValue
            )
            XCTAssertEqual(
                try chromaCoordinate(.center, .horizontal, .halfPixelCenter, testCase),
                testCase.halfPixelCenter,
                accuracy: 0.0,
                testCase.route.rawValue
            )
            XCTAssertEqual(
                try chromaCoordinate(.left, .horizontal, .sourceAlignedRational, testCase),
                0.0,
                accuracy: 0.0,
                testCase.route.rawValue
            )
            XCTAssertEqual(
                try chromaCoordinate(.left, .horizontal, .halfPixelCenter, testCase),
                testCase.sourceAlignedCenter,
                accuracy: 0.0,
                testCase.route.rawValue
            )
            XCTAssertEqual(
                try chromaCoordinate(.top, .vertical, .sourceAlignedRational, testCase),
                0.0,
                accuracy: 0.0
            )
            XCTAssertEqual(
                try chromaCoordinate(.topLeft, .vertical, .halfPixelCenter, testCase),
                testCase.sourceAlignedCenter,
                accuracy: 0.0
            )
            XCTAssertEqual(
                try chromaCoordinate(.bottom, .vertical, .sourceAlignedRational, testCase),
                2.0 * testCase.sourceAlignedCenter,
                accuracy: 0.0
            )
            XCTAssertEqual(
                try chromaCoordinate(.bottom, .vertical, .halfPixelCenter, testCase),
                testCase.halfPixelCenter + testCase.sourceAlignedCenter,
                accuracy: 0.0
            )
            let topLeft = ASHChromaSitingV2.topLeft.sourceChromaLocation(lumaX: 0, lumaY: 0)
            XCTAssertEqual(
                topLeft,
                ASHChromaContinuousLocationV2(horizontal: 0.0, vertical: 0.0)
            )
        }
    }

    func test_chromaSitingChangesControlledDirectReconstruction() throws {
        let center = try ASHSpatialReferencePipelineV2.process(
            makeInput(route: .direct2x, chromaSiting: .center)
        )
        let left = try ASHSpatialReferencePipelineV2.process(
            makeInput(route: .direct2x, chromaSiting: .left)
        )

        XCTAssertNotEqual(center.cb.normalizedSamples, left.cb.normalizedSamples)
        XCTAssertNotEqual(center.summary.chromaSiting, left.summary.chromaSiting)
    }

    func test_everyOutputSampleIsFiniteAndInsideNormalizedLegalRange() throws {
        for route in ASHSpatialRouteV2.allCases {
            let output = try ASHSpatialReferencePipelineV2.process(makeInput(route: route))
            for plane in [output.luma, output.cb, output.cr] {
                XCTAssertTrue(plane.normalizedSamples.allSatisfy {
                    $0.isFinite && (0.0...1.0).contains($0)
                })
            }
        }
    }

    func test_pipelineRejectsNon420GeometryBeforeAnalysis() throws {
        let input = try makeInput(route: .direct2x)
        let invalidCb = try codePlane(width: 8, height: 4, range: .video) { _, _ in 128 }
        let invalid = ASHSpatialReferenceInputV2(
            luma: input.luma,
            cb: invalidCb,
            cr: invalidCb,
            chromaSiting: input.chromaSiting,
            route: input.route,
            runtimeConfiguration: input.runtimeConfiguration,
            analyzerConfiguration: input.analyzerConfiguration,
            operatorParameters: input.operatorParameters,
            stateInputEnabled: input.stateInputEnabled
        )

        XCTAssertThrowsError(try ASHSpatialReferencePipelineV2.process(invalid)) { error in
            XCTAssertEqual(error as? ASHSpatialReferencePipelineV2Error, .unsupportedChromaSubsampling)
        }
    }

    private func makeInput(
        route: ASHSpatialRouteV2,
        stateInputEnabled: Bool = true,
        chromaSiting: ASHChromaSitingV2 = .center
    ) throws -> ASHSpatialReferenceInputV2 {
        let luma = try codePlane(width: 8, height: 8, range: .video) { column, row in
            if column < 4 {
                return row.isMultiple(of: 2) ? 20 : 72
            }
            return (column + row).isMultiple(of: 2) ? 232 : 148
        }
        let cb = try codePlane(width: 4, height: 4, range: .video) { column, row in
            UInt8(24 + ((column * 37 + row * 13) % 200))
        }
        let cr = try codePlane(width: 4, height: 4, range: .video) { column, row in
            UInt8(232 - ((column * 19 + row * 29) % 200))
        }
        return ASHSpatialReferenceInputV2(
            luma: luma,
            cb: cb,
            cr: cr,
            chromaSiting: chromaSiting,
            route: route,
            runtimeConfiguration: .developmentP05,
            analyzerConfiguration: try .makeDisposableP05Reference(),
            operatorParameters: .p05DevelopmentOnly,
            stateInputEnabled: stateInputEnabled
        )
    }

    private func codePlane(
        width: Int,
        height: Int,
        range: ASHVideoCodeRange8Bit,
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
            range: range
        )
    }

    private func normalizedChroma(_ code: UInt8, range: ASHVideoCodeRange8Bit) -> Double {
        min(1.0, max(0.0, range.normalizeChroma(code) + 0.5))
    }

    private func chromaCoordinate(
        _ siting: ASHChromaSitingV2,
        _ axis: ASHChromaSitingAxisV2,
        _ policy: ASHSpatialCoordinatePolicyV2,
        _ testCase: ChromaCoordinateCase
    ) throws -> Double {
        try siting.sourceCoordinate(
            destinationIndex: 0,
            sourceExtent: testCase.sourceExtent,
            destinationExtent: testCase.destinationExtent,
            policy: policy,
            axis: axis
        ).value
    }
}
