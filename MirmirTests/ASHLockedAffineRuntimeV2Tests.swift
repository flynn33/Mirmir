import XCTest
@testable import Mirmir

final class ASHLockedAffineRuntimeV2Tests: XCTestCase {
    func test_512EntryRuntimeDecoderExhaustivelyCoversExactOneBitAndTwoBitPaths() {
        for anchor in ASHLUTStateOrdinalTableV2.validStates {
            for messageRawValue in UInt8(0)..<UInt8(16) {
                let message = ASHMessage(validatedRawValue: messageRawValue)
                let affine = anchor.xor(ASHCode.encode(message))
                let exact = ASHLockedAffineDecoderV2.decode(received: affine, anchor: anchor)
                XCTAssertEqual(exact.status, .exact)
                XCTAssertEqual(exact.message, message)
                XCTAssertNil(exact.correctedCoordinate)

                for coordinate in 1...ASHState.bitCount {
                    let corrected = ASHLockedAffineDecoderV2.decode(
                        received: affine.toggled(coordinate: coordinate),
                        anchor: anchor
                    )
                    XCTAssertEqual(corrected.status, .corrected)
                    XCTAssertEqual(corrected.message, message)
                    XCTAssertEqual(corrected.correctedCoordinate, UInt8(coordinate))
                }

                for first in 1..<ASHState.bitCount {
                    for second in (first + 1)...ASHState.bitCount {
                        let rejected = ASHLockedAffineDecoderV2.decode(
                            received: affine.toggled(coordinate: first).toggled(coordinate: second),
                            anchor: anchor
                        )
                        XCTAssertEqual(rejected.status, .uncorrectable)
                        XCTAssertNil(rejected.message)
                    }
                }
            }
        }
    }

    func test_loadedRuntimeExhaustivelyUsesOneOrTwoExactCandidatesWithoutTreeOrPathWork() throws {
        let sidecar = try ASHLockedRuntimeTestSupportV2.sidecar()
        for route in ASHSpatialRouteV2.allCases {
            let fixture = try ASHLockedRuntimeTestSupportV2.existingFixture(route)
            for phase in 0..<route.phasePairCount {
                for context in ASHLUTContextV2.allCases {
                    for state in ASHLUTStateOrdinalTableV2.validStates {
                        let dispatch = try ASHLockedRuntimeV2.dispatch(
                            lut: fixture.loaded,
                            configuration: fixture.configuration,
                            sourceState: state,
                            phaseOrdinal: phase,
                            context: context,
                            sidecar: sidecar
                        )
                        let entry = try fixture.loaded.entry(
                            state: state,
                            phaseOrdinal: phase,
                            context: context
                        )
                        let pair = fixture.loaded.parameters[Int(entry.parameterIndex)]
                        XCTAssertEqual(dispatch.primary.affineDecode.status, .exact)
                        XCTAssertEqual(dispatch.primary.decodedMessage, entry.primaryMessage)
                        XCTAssertEqual(dispatch.primary.descriptor.id, entry.primaryDescriptorID)
                        assertParameterSemantics(
                            dispatch.primary,
                            slot: pair.primary,
                            configuration: fixture.configuration,
                            baseSidecar: sidecar
                        )
                        if let secondary = dispatch.secondary {
                            XCTAssertEqual(secondary.affineDecode.status, .exact)
                            XCTAssertEqual(secondary.decodedMessage, entry.secondaryMessage)
                            XCTAssertEqual(secondary.descriptor.id, entry.secondaryDescriptorID)
                            assertParameterSemantics(
                                secondary,
                                slot: pair.secondary,
                                configuration: fixture.configuration,
                                baseSidecar: sidecar
                            )
                        }
                        XCTAssertEqual(dispatch.operatorEvaluationCount, entry.operatorEvaluationCount)
                        XCTAssertLessThanOrEqual(dispatch.operatorEvaluationCount, 2)
                        XCTAssertEqual(dispatch.primaryWeightUNorm16, entry.primaryWeightUNorm16)
                        XCTAssertEqual(dispatch.secondaryWeightUNorm16, entry.secondaryWeightUNorm16)
                        XCTAssertEqual(dispatch.marginUNorm16, entry.marginUNorm16)
                        XCTAssertFalse(dispatch.affineFallbackUsed)
                        XCTAssertEqual(dispatch.counters, .zero)
                    }
                }
            }
            XCTAssertEqual(fixture.loaded.runtimeTreeGenerationCount, 0)
            XCTAssertLessThanOrEqual(fixture.loaded.maximumOperatorEvaluations, 2)
        }
    }

    func test_oneBitAffineFaultIsCorrectedAndTwoBitFaultUsesConservativeFallback() throws {
        let fixture = try ASHLockedRuntimeTestSupportV2.existingFixture(.direct2x)
        let state = ASHLUTStateOrdinalTableV2.validStates[0]
        let entry = try fixture.loaded.entry(
            state: state,
            phaseOrdinal: 1,
            context: .spatialOnly
        )
        let parameters = fixture.loaded.parameters[Int(entry.parameterIndex)]
        let sidecar = try ASHLockedRuntimeTestSupportV2.sidecar()

        let correctedEntry = replacingPrimaryAffine(
            entry,
            with: entry.primaryAffineState.toggled(coordinate: 4)
        )
        let corrected = try ASHLockedRuntimeV2.dispatch(
            entry: correctedEntry,
            parameters: parameters,
            configuration: fixture.configuration,
            route: .direct2x,
            sourceState: state,
            parityWasRecomputed: false,
            sidecar: sidecar
        )
        XCTAssertEqual(corrected.primary.affineDecode.status, .corrected)
        XCTAssertEqual(corrected.primary.affineDecode.correctedCoordinate, 4)
        XCTAssertEqual(corrected.primary.decodedMessage, entry.primaryMessage)
        XCTAssertFalse(corrected.affineFallbackUsed)

        let rejectedEntry = replacingPrimaryAffine(
            entry,
            with: entry.primaryAffineState.toggled(coordinate: 4).toggled(coordinate: 7)
        )
        let rejected = try ASHLockedRuntimeV2.dispatch(
            entry: rejectedEntry,
            parameters: parameters,
            configuration: fixture.configuration,
            route: .direct2x,
            sourceState: state,
            parityWasRecomputed: false,
            sidecar: sidecar
        )
        XCTAssertEqual(rejected.primary.affineDecode.status, .uncorrectable)
        XCTAssertTrue(rejected.affineFallbackUsed)
        XCTAssertEqual(rejected.primary.descriptor.id, 0)
        XCTAssertEqual(rejected.primary.parameters.controlledDetailGain, 0.0, accuracy: 0.0)
        XCTAssertEqual(rejected.primary.parameters.relaxedLimiterAlpha, 0.0, accuracy: 0.0)
        XCTAssertEqual(rejected.primary.parameters.supportRadius, 2.0)
        XCTAssertEqual(rejected.operatorEvaluationCount, 1)
    }

    func test_invalidAnalysisParityIsRecomputedBeforeLUTLookup() throws {
        let fixture = try ASHLockedRuntimeTestSupportV2.existingFixture(.direct2x)
        let valid = ASHLUTStateOrdinalTableV2.validStates[73]
        let invalid = valid.toggled(coordinate: 9)
        XCTAssertFalse(invalid.hasValidIntegrity)
        let dispatch = try ASHLockedRuntimeV2.dispatch(
            lut: fixture.loaded,
            configuration: fixture.configuration,
            sourceState: invalid,
            phaseOrdinal: 2,
            context: .spatialOnly,
            sidecar: try ASHLockedRuntimeTestSupportV2.sidecar()
        )
        XCTAssertTrue(dispatch.parityWasRecomputed)
        XCTAssertEqual(dispatch.sourceState, valid)
        XCTAssertEqual(dispatch.primary.affineDecode.status, .exact)
    }

    func test_supportRadiusExpandsAndContractsKernelWhileBaseRadiusIsNumericallyIdentical() throws {
        let plane = try ASHSpatialPlaneV2(
            width: 7,
            height: 7,
            samples: (0..<49).map { index in
                let row: Int = index / 7
                let column: Int = index % 7
                let weightedColumn: Int = column * 13
                let weightedRow: Int = row * 29
                let interaction: Int = column * row * 7
                let foldedSample: Int = (weightedColumn + weightedRow + interaction) % 97
                let normalizedSample: Double = Double(foldedSample) / 96.0
                return normalizedSample
            }
        )
        let base = ASHSpatialDevelopmentParametersV2.p05DevelopmentOnly
        let explicitBase = replacingSupport(base, radius: 2.0)
        let contracted = replacingSupport(base, radius: 1.75)
        let expanded = replacingSupport(base, radius: 2.25)
        let implicitValue = try evaluateSupportFixture(plane: plane, parameters: base)
        let explicitValue = try evaluateSupportFixture(plane: plane, parameters: explicitBase)
        let contractedValue = try evaluateSupportFixture(plane: plane, parameters: contracted)
        let expandedValue = try evaluateSupportFixture(plane: plane, parameters: expanded)

        XCTAssertEqual(implicitValue, explicitValue, accuracy: 0.0)
        let contractedDelta: Double = abs(contractedValue - implicitValue)
        let expandedDelta: Double = abs(expandedValue - implicitValue)
        let expansionRange: Double = abs(expandedValue - contractedValue)
        XCTAssertGreaterThan(contractedDelta, 1.0e-9)
        XCTAssertGreaterThan(expandedDelta, 1.0e-9)
        XCTAssertGreaterThan(expansionRange, 1.0e-9)
    }

    private func assertParameterSemantics(
        _ candidate: ASHLockedRuntimeCandidateV2,
        slot: ASHLUTParameterSlotV2,
        configuration: ASHLUTLockedConfigurationV2,
        baseSidecar: ASHSpatialSidecarV2,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            candidate.orientationSector,
            moduloFour(
                ASHVideoAnalyzerV2.quantizeTangentSector(baseSidecar.orientationRadians)
                    + Int(slot.delta.orientation)
            ),
            file: file,
            line: line
        )
        XCTAssertEqual(
            candidate.parameters.anisotropyStrength,
            Double(slot.anisotropyStrengthQ12) / 4_096.0,
            accuracy: 0.0,
            file: file,
            line: line
        )
        XCTAssertEqual(
            candidate.parameters.minimumAnisotropicMagnitude,
            Double(slot.minimumAnisotropicMagnitudeUNorm15) / 32_767.0,
            accuracy: 0.0,
            file: file,
            line: line
        )
        XCTAssertEqual(
            candidate.parameters.minimumAnisotropicCoherence,
            Double(slot.minimumAnisotropicCoherenceUNorm15) / 32_767.0,
            accuracy: 0.0,
            file: file,
            line: line
        )
        XCTAssertEqual(
            candidate.parameters.controlledDetailGain,
            Double(slot.detailGainQ12) / 4_096.0,
            accuracy: 0.0,
            file: file,
            line: line
        )
        XCTAssertEqual(
            candidate.parameters.relaxedLimiterAlpha,
            Double(slot.relaxedLimiterAlphaQ12) / 4_096.0,
            accuracy: 0.0,
            file: file,
            line: line
        )
        XCTAssertEqual(
            candidate.parameters.riskDetailSuppressionThreshold,
            Double(slot.riskSuppressionUNorm15) / 32_767.0,
            accuracy: 0.0,
            file: file,
            line: line
        )
        XCTAssertEqual(
            candidate.parameters.supportRadius,
            Double(slot.supportRadiusQ8x8) / 256.0,
            file: file,
            line: line
        )
        XCTAssertEqual(
            candidate.parameters.lowPassRadius,
            Double(configuration.operatorParameters.lowPassRadiusQ8x8) / 256.0,
            accuracy: 0.0,
            file: file,
            line: line
        )
        XCTAssertEqual(
            candidate.parameters.weightEpsilon,
            Double(Float(bitPattern: slot.weightEpsilonF32Bits)),
            accuracy: 0.0,
            file: file,
            line: line
        )
    }

    private func replacingPrimaryAffine(
        _ entry: ASHLUTLoadedEntryV2,
        with affine: ASHState
    ) -> ASHLUTLoadedEntryV2 {
        ASHLUTLoadedEntryV2(
            primaryAffineState: affine,
            secondaryAffineState: entry.secondaryAffineState,
            primaryDescriptorID: entry.primaryDescriptorID,
            secondaryDescriptorID: entry.secondaryDescriptorID,
            primaryMessage: entry.primaryMessage,
            secondaryMessage: entry.secondaryMessage,
            primaryWeightUNorm16: entry.primaryWeightUNorm16,
            secondaryWeightUNorm16: entry.secondaryWeightUNorm16,
            marginUNorm16: entry.marginUNorm16,
            flags: entry.flags,
            parameterIndex: entry.parameterIndex,
            provenanceCRC32: entry.provenanceCRC32
        )
    }

    private func replacingSupport(
        _ source: ASHSpatialDevelopmentParametersV2,
        radius: Double
    ) -> ASHSpatialDevelopmentParametersV2 {
        ASHSpatialDevelopmentParametersV2(
            anisotropyStrength: source.anisotropyStrength,
            minimumAnisotropicMagnitude: source.minimumAnisotropicMagnitude,
            minimumAnisotropicCoherence: source.minimumAnisotropicCoherence,
            controlledDetailGain: source.controlledDetailGain,
            relaxedLimiterAlpha: source.relaxedLimiterAlpha,
            riskDetailSuppressionThreshold: source.riskDetailSuppressionThreshold,
            lowPassRadius: source.lowPassRadius,
            weightEpsilon: source.weightEpsilon,
            supportRadius: radius
        )
    }

    private func evaluateSupportFixture(
        plane: ASHSpatialPlaneV2,
        parameters: ASHSpatialDevelopmentParametersV2
    ) throws -> Double {
        try ASHSpatialOperatorBankV2.evaluateSample(ASHSpatialSampleRequestV2(
            plane: plane,
            destinationColumn: 3,
            destinationRow: 3,
            route: .direct2x,
            coordinatePolicy: .sourceAlignedRational,
            descriptor: try ASHSpatialDescriptorV2(id: 0),
            sidecar: try ASHLockedRuntimeTestSupportV2.sidecar(),
            boundary: .mirrorReflect101,
            parameters: parameters,
            coordinateOverride: ASHSpatialSourceCoordinatesV2(
                horizontal: ASHSpatialRationalCoordinateV2(numerator: 7, denominator: 3),
                vertical: ASHSpatialRationalCoordinateV2(numerator: 8, denominator: 3)
            )
        )).value
    }

    private func moduloFour(_ value: Int) -> Int {
        let remainder = value % 4
        return remainder >= 0 ? remainder : remainder + 4
    }
}
