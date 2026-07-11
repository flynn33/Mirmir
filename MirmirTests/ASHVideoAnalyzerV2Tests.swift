import XCTest
@testable import Mirmir

// swiftlint:disable type_body_length identifier_name
final class ASHVideoAnalyzerV2Tests: XCTestCase {
    func test_codeRangeNormalizationPreservesEndpointsAndExcursions() {
        XCTAssertEqual(ASHVideoCodeRange8Bit.video.normalizeLuma(16), 0.0, accuracy: 0.0)
        XCTAssertEqual(ASHVideoCodeRange8Bit.video.normalizeLuma(235), 1.0, accuracy: 0.0)
        XCTAssertEqual(ASHVideoCodeRange8Bit.video.normalizeLuma(0), -16.0 / 219.0, accuracy: 1e-15)
        XCTAssertEqual(ASHVideoCodeRange8Bit.video.normalizeLuma(255), 239.0 / 219.0, accuracy: 1e-15)
        XCTAssertEqual(ASHVideoCodeRange8Bit.full.normalizeLuma(0), 0.0, accuracy: 0.0)
        XCTAssertEqual(ASHVideoCodeRange8Bit.full.normalizeLuma(255), 1.0, accuracy: 0.0)

        XCTAssertEqual(ASHVideoCodeRange8Bit.video.normalizeChroma(16), -0.5, accuracy: 0.0)
        XCTAssertEqual(ASHVideoCodeRange8Bit.video.normalizeChroma(240), 0.5, accuracy: 0.0)
        XCTAssertEqual(
            ASHVideoCodeRange8Bit.video.normalizeChroma(0),
            (-16.0 / 224.0) - 0.5,
            accuracy: 1e-15
        )
        XCTAssertEqual(
            ASHVideoCodeRange8Bit.video.normalizeChroma(255),
            (239.0 / 224.0) - 0.5,
            accuracy: 1e-15
        )
        XCTAssertEqual(ASHVideoCodeRange8Bit.full.normalizeChroma(0), -0.5, accuracy: 0.0)
        XCTAssertEqual(ASHVideoCodeRange8Bit.full.normalizeChroma(255), 0.5, accuracy: 0.0)
    }

    func test_scharrNormalizationAndBinomialTensorMatchLinearRampOracle() throws {
        let ramp = try plane(width: 17, height: 17, range: .full) { x, _ in
            UInt8(x * 12)
        }
        let result = try analyze(
            luma: ramp,
            location: ASHVideoAnalyzerV2Location(x: 8, y: 8),
            boundary: .reflect101
        )
        let expectedGradient = 12.0 / 255.0
        XCTAssertEqual(result.measurements.tensorXX, expectedGradient * expectedGradient, accuracy: 1e-15)
        XCTAssertEqual(result.measurements.tensorYY, 0.0, accuracy: 1e-15)
        XCTAssertEqual(result.measurements.tensorXY, 0.0, accuracy: 1e-15)
    }

    func test_orientationSectorQuantizationUsesQ15LowerSectorTie() {
        XCTAssertEqual(ASHVideoAnalyzerV2.quantizeTangentSector(0.0), 0)
        XCTAssertEqual(ASHVideoAnalyzerV2.quantizeTangentSector(.pi / 8.0), 0)
        XCTAssertEqual(ASHVideoAnalyzerV2.quantizeTangentSector(.pi / 8.0 + (.pi / 65_536.0)), 1)
        XCTAssertEqual(ASHVideoAnalyzerV2.quantizeTangentSector(3.0 * .pi / 8.0), 1)
    }

    func test_structureTensorConvertsNormalToAllFourTangentSectors() throws {
        let center = 12
        let fixtures: [(Int, (Int, Int) -> UInt8)] = [
            (0, { _, y in y < center ? 0 : 255 }),
            (1, { x, y in y < x ? 0 : 255 }),
            (2, { x, _ in x < center ? 0 : 255 }),
            (3, { x, y in x + y < center * 2 ? 0 : 255 })
        ]

        for (expectedSector, generator) in fixtures {
            let result = try analyze(
                luma: plane(width: 25, height: 25, range: .full, generator: generator),
                location: ASHVideoAnalyzerV2Location(x: center, y: center)
            )
            XCTAssertEqual(result.state.bit(coordinate: 3), 1)
            XCTAssertEqual(result.sidecar.orientationSector, expectedSector)
            XCTAssertEqual(
                result.sidecar.edgeTangentRadians,
                moduloPi(result.sidecar.edgeNormalRadians + (.pi / 2.0)),
                accuracy: 1e-12
            )
        }
    }

    func test_controlledMeasurementsCoverEveryPayloadBitAndParity() throws {
        let configuration = try ASHVideoAnalyzerV2DevelopmentConfiguration.makeDisposableP05Reference()
        let empty = measurements()
        let zero = try ASHVideoAnalyzerV2.packState(
            measurements: empty,
            history: nil,
            temporalEvidence: nil,
            configuration: configuration
        )
        XCTAssertEqual(payload(zero), Array(repeating: 0, count: 8))

        for (sector, expectedOrientation) in [(0, [0, 0]), (1, [1, 0]), (2, [0, 1]), (3, [1, 1])] {
            let state = try packed(
                measurements: measurements(gradient: 0.50, sector: sector),
                configuration: configuration
            )
            XCTAssertEqual(Array(payload(state).prefix(2)), expectedOrientation)
            XCTAssertEqual(state.bit(coordinate: 3), 1)
            assertParity(state)
        }

        let semanticMeasurements = [
            measurements(coherence: 0.50),
            measurements(texture: 0.50),
            measurements(risk: 0.50),
            measurements(chromaAlignment: 0.50)
        ]
        let expectedCoordinates = [4, 5, 6, 8]
        for (fixture, coordinate) in zip(semanticMeasurements, expectedCoordinates) {
            let state = try packed(measurements: fixture, configuration: configuration)
            XCTAssertEqual(state.bit(coordinate: coordinate), 1)
            XCTAssertEqual(payload(state).reduce(0, +), 1)
            assertParity(state)
        }

        let temporal = try ASHVideoAnalyzerV2ValidationTemporalEvidence(
            motionResidualPassed: true,
            forwardBackwardConsistencyPassed: true,
            occlusionPassed: true,
            sceneCutPassed: true,
            confidence: 0.50,
            motionVectorQ8_8: .zero
        )
        let temporalState = try ASHVideoAnalyzerV2.packState(
            measurements: empty,
            history: nil,
            temporalEvidence: temporal,
            configuration: configuration
        )
        XCTAssertEqual(temporalState.bit(coordinate: 7), 1)
        XCTAssertEqual(payload(temporalState).reduce(0, +), 1)
        assertParity(temporalState)
    }

    func test_hysteresisUsesMidpointOnlyWithoutValidHistoryAndResetsAtBands() throws {
        let configuration = try ASHVideoAnalyzerV2DevelopmentConfiguration.makeDisposableP05Reference()
        let edgeBand = configuration.bands.edgePresent
        let midpoint = measurements(gradient: (edgeBand.low + edgeBand.high) / 2.0)
        let zeroHistory = ASHVideoAnalyzerV2History(
            state: try ASHState(payloadBits: Array(repeating: 0, count: 8)),
            correspondenceIsValid: true
        )
        let oneHistory = ASHVideoAnalyzerV2History(
            state: try ASHState(payloadBits: [0, 0, 1, 0, 0, 0, 0, 0]),
            correspondenceIsValid: true
        )

        XCTAssertEqual(try packed(measurements: midpoint, configuration: configuration).bit(coordinate: 3), 1)
        XCTAssertEqual(
            try packed(measurements: midpoint, history: zeroHistory, configuration: configuration).bit(coordinate: 3),
            0
        )
        XCTAssertEqual(
            try packed(measurements: midpoint, history: oneHistory, configuration: configuration).bit(coordinate: 3),
            1
        )
        XCTAssertEqual(
            try packed(
                measurements: measurements(gradient: 0.10),
                history: oneHistory,
                configuration: configuration
            ).bit(coordinate: 3),
            0
        )
        XCTAssertEqual(
            try packed(
                measurements: measurements(gradient: 0.50),
                history: zeroHistory,
                configuration: configuration
            ).bit(coordinate: 3),
            1
        )

        let invalidParity = ASHVideoAnalyzerV2History(
            state: try ASHState(rawValue: 1),
            correspondenceIsValid: true
        )
        let invalidCorrespondence = ASHVideoAnalyzerV2History(
            state: zeroHistory.state,
            correspondenceIsValid: false
        )
        XCTAssertEqual(
            try packed(measurements: midpoint, history: invalidParity, configuration: configuration).bit(coordinate: 3),
            1
        )
        XCTAssertEqual(
            try packed(
                measurements: midpoint,
                history: invalidCorrespondence,
                configuration: configuration
            ).bit(coordinate: 3),
            1
        )
    }

    func test_temporalBitRequiresEveryValidationPredicateAndNeverPersistsWithoutEvidence() throws {
        let configuration = try ASHVideoAnalyzerV2DevelopmentConfiguration.makeDisposableP05Reference()
        let previousTemporal = ASHVideoAnalyzerV2History(
            state: try ASHState(payloadBits: [0, 0, 0, 0, 0, 0, 1, 0]),
            correspondenceIsValid: true
        )
        XCTAssertEqual(
            try packed(
                measurements: measurements(),
                history: previousTemporal,
                configuration: configuration
            ).bit(coordinate: 7),
            0
        )

        for failedPredicate in 0..<4 {
            var predicates = Array(repeating: true, count: 4)
            predicates[failedPredicate] = false
            let evidence = try ASHVideoAnalyzerV2ValidationTemporalEvidence(
                motionResidualPassed: predicates[0],
                forwardBackwardConsistencyPassed: predicates[1],
                occlusionPassed: predicates[2],
                sceneCutPassed: predicates[3],
                confidence: 1.0,
                motionVectorQ8_8: .zero
            )
            let state = try ASHVideoAnalyzerV2.packState(
                measurements: measurements(),
                history: previousTemporal,
                temporalEvidence: evidence,
                configuration: configuration
            )
            XCTAssertEqual(state.bit(coordinate: 7), 0)
        }

        let accepted = try ASHVideoAnalyzerV2ValidationTemporalEvidence(
            motionResidualPassed: true,
            forwardBackwardConsistencyPassed: true,
            occlusionPassed: true,
            sceneCutPassed: true,
            confidence: 1.0,
            motionVectorQ8_8: ASHVideoAnalyzerV2MotionVectorQ8_8(x: 256, y: -128)
        )
        XCTAssertEqual(
            try ASHVideoAnalyzerV2.packState(
                measurements: measurements(),
                history: nil,
                temporalEvidence: accepted,
                configuration: configuration
            ).bit(coordinate: 7),
            1
        )

        let constant = try plane(width: 1, height: 1, range: .video) { _, _ in 16 }
        let analyzed = try ASHVideoAnalyzerV2.analyze(
            ASHVideoAnalyzerV2Input(
                luma: constant,
                location: ASHVideoAnalyzerV2Location(x: 0, y: 0),
                chroma: nil,
                boundary: .clamp,
                history: nil,
                validationTemporalEvidence: accepted
            ),
            configuration: configuration
        )
        XCTAssertEqual(analyzed.state.bit(coordinate: 7), 1)
        XCTAssertEqual(analyzed.sidecar.temporalConfidence, 1.0, accuracy: 0.0)
        XCTAssertEqual(analyzed.sidecar.motionVectorQ8_8, accepted.motionVectorQ8_8)
        XCTAssertEqual(analyzed.hysteresis.temporalSupportValid, .midpointSet)
    }

    func test_chromaAnalysisDistinguishesAlignedContradictedAndChromaOnlyEdges() throws {
        let center = 12
        let verticalLuma = try plane(width: 25, height: 25, range: .full) { x, _ in
            x < center ? 0 : 255
        }
        let constantLuma = try plane(width: 25, height: 25, range: .full) { _, _ in 128 }
        let aligned = try chroma(width: 25, height: 25, location: center) { x, _ in
            x < center ? 32 : 224
        }
        let contradicted = try chroma(width: 25, height: 25, location: center) { _, y in
            y < center ? 32 : 224
        }

        let alignedResult = try analyze(
            luma: verticalLuma,
            location: ASHVideoAnalyzerV2Location(x: center, y: center),
            chroma: aligned
        )
        let contradictedResult = try analyze(
            luma: verticalLuma,
            location: ASHVideoAnalyzerV2Location(x: center, y: center),
            chroma: contradicted
        )
        let chromaOnlyResult = try analyze(
            luma: constantLuma,
            location: ASHVideoAnalyzerV2Location(x: center, y: center),
            chroma: aligned
        )

        XCTAssertEqual(alignedResult.state.bit(coordinate: 8), 1)
        XCTAssertGreaterThan(alignedResult.sidecar.chromaAlignment, 0.40)
        XCTAssertEqual(contradictedResult.state.bit(coordinate: 8), 0)
        XCTAssertEqual(contradictedResult.sidecar.chromaAlignment, 0.0, accuracy: 1e-12)
        XCTAssertEqual(chromaOnlyResult.state.bit(coordinate: 8), 0)
        XCTAssertEqual(chromaOnlyResult.sidecar.chromaAlignment, 0.0, accuracy: 1e-12)
    }

    func test_boundariesAndStateMappingFixtureMatrixAreFiniteDeterministicAndParityValid() throws {
        let center = 8
        var fixtures: [(String, ASHVideoAnalyzerV2CodePlane)] = []
        fixtures.append(("constant", try plane(width: 17, height: 17, range: .video) { _, _ in 128 }))
        fixtures.append(("corner", try plane(width: 17, height: 17, range: .video) { x, y in
            x >= center && y >= center ? 235 : 16
        }))
        fixtures.append(("thin-line", try plane(width: 17, height: 17, range: .video) { x, _ in
            x == center ? 235 : 16
        }))
        fixtures.append(("checker", try plane(width: 17, height: 17, range: .video) { x, y in
            (x + y).isMultiple(of: 2) ? 235 : 16
        }))
        fixtures.append(("texture", try plane(width: 17, height: 17, range: .video) { x, y in
            UInt8(16 + ((x * 37 + y * 19) % 220))
        }))
        fixtures.append(("noise", try plane(width: 17, height: 17, range: .video) { x, y in
            let horizontal = x * 73
            let vertical = y * 151
            let interaction = x * y * 11
            let legalCode = 16 + ((horizontal + vertical + interaction) % 220)
            return UInt8(legalCode)
        }))
        for (_, inputPlane) in fixtures {
            let first = try analyze(
                luma: inputPlane,
                location: ASHVideoAnalyzerV2Location(x: center, y: center),
                boundary: .reflect101
            )
            let second = try analyze(
                luma: inputPlane,
                location: ASHVideoAnalyzerV2Location(x: center, y: center),
                boundary: .reflect101
            )
            XCTAssertEqual(first, second)
            XCTAssertTrue(first.state.hasValidIntegrity)
            assertFinite(first.sidecar)
        }

        let singleton = try plane(width: 1, height: 1, range: .video) { _, _ in 16 }
        let clamped = try analyze(
            luma: singleton,
            location: ASHVideoAnalyzerV2Location(x: 0, y: 0),
            boundary: .clamp
        )
        let reflected = try analyze(
            luma: singleton,
            location: ASHVideoAnalyzerV2Location(x: 0, y: 0),
            boundary: .reflect101
        )
        XCTAssertEqual(clamped, reflected)
        XCTAssertEqual(clamped.sidecar.localMinimumY, 0.0, accuracy: 0.0)
        XCTAssertEqual(clamped.sidecar.localMaximumY, 0.0, accuracy: 0.0)
        XCTAssertEqual(clamped.sidecar.localNoiseEstimate, 0.0, accuracy: 0.0)
        XCTAssertEqual(clamped.hysteresis.edgePresent, .midpointClear)
        XCTAssertEqual(clamped.hysteresis.temporalSupportValid, .forcedOffWithoutTemporalEvidence)
    }

    private func analyze(
        luma: ASHVideoAnalyzerV2CodePlane,
        location: ASHVideoAnalyzerV2Location,
        chroma: ASHVideoAnalyzerV2ChromaInput? = nil,
        boundary: ASHVideoAnalyzerV2BoundaryRule = .clamp
    ) throws -> ASHVideoAnalyzerV2Result {
        try ASHVideoAnalyzerV2.analyze(
            ASHVideoAnalyzerV2Input(
                luma: luma,
                location: location,
                chroma: chroma,
                boundary: boundary,
                history: nil,
                validationTemporalEvidence: nil
            ),
            configuration: ASHVideoAnalyzerV2DevelopmentConfiguration.makeDisposableP05Reference()
        )
    }

    private func packed(
        measurements: ASHVideoAnalyzerV2Measurements,
        history: ASHVideoAnalyzerV2History? = nil,
        configuration: ASHVideoAnalyzerV2DevelopmentConfiguration
    ) throws -> ASHState {
        try ASHVideoAnalyzerV2.packState(
            measurements: measurements,
            history: history,
            temporalEvidence: nil,
            configuration: configuration
        )
    }

    private func measurements(
        gradient: Double = 0.0,
        coherence: Double = 0.0,
        sector: Int = 0,
        texture: Double = 0.0,
        risk: Double = 0.0,
        chromaAlignment: Double = 0.0
    ) -> ASHVideoAnalyzerV2Measurements {
        ASHVideoAnalyzerV2Measurements(
            tensorXX: 0.0,
            tensorYY: 0.0,
            tensorXY: 0.0,
            normalizedGradientMagnitude: gradient,
            structureCoherence: coherence,
            edgeNormalRadians: 0.0,
            edgeTangentRadians: 0.0,
            orientationSector: sector,
            textureEnergy: texture,
            riskProxy: risk,
            localNoiseEstimate: 0.0,
            chromaAlignment: chromaAlignment,
            chromaEdgeConfidence: 0.0,
            localMinimumY: 0.0,
            localMaximumY: 1.0
        )
    }

    private func plane(
        width: Int,
        height: Int,
        range: ASHVideoCodeRange8Bit,
        generator: (Int, Int) -> UInt8
    ) throws -> ASHVideoAnalyzerV2CodePlane {
        var codes: [UInt8] = []
        codes.reserveCapacity(width * height)
        for y in 0..<height {
            for x in 0..<width {
                codes.append(generator(x, y))
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

    private func chroma(
        width: Int,
        height: Int,
        location: Int,
        generator: (Int, Int) -> UInt8
    ) throws -> ASHVideoAnalyzerV2ChromaInput {
        let cb = try plane(width: width, height: height, range: .full, generator: generator)
        let cr = try plane(width: width, height: height, range: .full) { _, _ in 128 }
        return try ASHVideoAnalyzerV2ChromaInput(
            cb: cb,
            cr: cr,
            location: ASHVideoAnalyzerV2Location(x: location, y: location)
        )
    }

    private func payload(_ state: ASHState) -> [Int] {
        Array(state.bits.prefix(ASHState.payloadBitCount))
    }

    private func assertParity(_ state: ASHState, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(state.hasValidIntegrity, file: file, line: line)
        XCTAssertEqual(
            state.bit(coordinate: 9),
            payload(state).reduce(0, ^),
            file: file,
            line: line
        )
    }

    private func assertFinite(
        _ sidecar: ASHVideoAnalyzerV2Sidecar,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let values = [
            sidecar.normalizedGradientMagnitude,
            sidecar.structureCoherence,
            sidecar.edgeNormalRadians,
            sidecar.edgeTangentRadians,
            sidecar.textureEnergy,
            sidecar.riskProxy,
            sidecar.localNoiseEstimate,
            sidecar.temporalConfidence,
            sidecar.chromaAlignment,
            sidecar.chromaEdgeConfidence,
            sidecar.localMinimumY,
            sidecar.localMaximumY
        ]
        XCTAssertTrue(values.allSatisfy(\.isFinite), file: file, line: line)
    }

    private func moduloPi(_ angle: Double) -> Double {
        var value = angle.truncatingRemainder(dividingBy: .pi)
        if value < 0.0 {
            value += .pi
        }
        return value
    }
}
// swiftlint:enable type_body_length identifier_name
