import Foundation

enum ASHLockedControlRuntimeV2Error: Error, Equatable, Sendable {
    case invalidDescriptorID(Int)
    case invalidNonASHRule
    case invalidNonASHFeature
    case invalidControlMode
    case invalidNonASHFeatureShape
}

struct ASHLockedNonASHRuleV2: Equatable, Sendable {
    static let coordinateOrder = (0..<16).map {
        String(format: "bias_descriptor_%02d_q8_8", $0)
    } + [
        "weight_magnitude_q8_8",
        "weight_coherence_q8_8",
        "weight_texture_q8_8",
        "weight_risk_q8_8",
        "weight_chroma_alignment_q8_8",
        "weight_orientation_cos_q8_8",
        "weight_orientation_sin_q8_8",
        "weight_noise_q8_8",
        "weight_horizontal_phase_q8_8",
        "weight_vertical_phase_q8_8",
        "weight_route_q8_8"
    ]
    static let permittedValues = Set([-384, -256, -128, 0, 128, 256, 384])

    let coordinates: [String: Int]

    init(coordinates: [String: Int]) throws {
        guard Set(coordinates.keys) == Set(Self.coordinateOrder),
              coordinates.values.allSatisfy(Self.permittedValues.contains) else {
            throw ASHLockedControlRuntimeV2Error.invalidNonASHRule
        }
        self.coordinates = coordinates
    }
}

struct ASHLockedPreparedNonASHRuleV2: Equatable, Sendable {
    fileprivate let descriptorBiasScores: [Int64]
    fileprivate let signedFeatureWeights: [Int64]
}

enum ASHLockedDispatchControlModeV2: Equatable, Sendable {
    case fixedDescriptor(UInt8)
    case stateOnly
    case nonASHSelector(ASHLockedNonASHRuleV2)
}

enum ASHLockedControlRuntimeV2 {
    static let nonASHCellFeatureOrder = [
        "weight_magnitude_q8_8",
        "weight_coherence_q8_8",
        "weight_texture_q8_8",
        "weight_risk_q8_8",
        "weight_chroma_alignment_q8_8",
        "weight_orientation_cos_q8_8",
        "weight_orientation_sin_q8_8",
        "weight_noise_q8_8"
    ]
    static let nonASHPhaseFeatureOrder = [
        "weight_horizontal_phase_q8_8",
        "weight_vertical_phase_q8_8",
        "weight_route_q8_8"
    ]
    static let nonASHFeatureOrder = nonASHCellFeatureOrder + nonASHPhaseFeatureOrder

    static func makeDispatchGrid(
        lut: ASHLUTLoadedV2,
        configuration: ASHLUTLockedConfigurationV2,
        analysisGrid: ASHAnalysisGridV2,
        mode: ASHLockedDispatchControlModeV2
    ) throws -> ASHLockedDispatchGridV2 {
        guard lut.configuration == configuration else {
            throw ASHLockedRuntimeV2Error.configurationMismatch
        }
        return try makeDispatchGrid(
            route: lut.route,
            configuration: configuration,
            analysisGrid: analysisGrid,
            mode: mode
        )
    }

    static func makeDispatchGrid(
        route: ASHSpatialRouteV2,
        configuration: ASHLUTLockedConfigurationV2,
        analysisGrid: ASHAnalysisGridV2,
        mode: ASHLockedDispatchControlModeV2
    ) throws -> ASHLockedDispatchGridV2 {
        let selection = configuration.routeSelection(for: route)
        guard analysisGrid.step == Int(selection.analysisGridSourceStep) else {
            throw ASHLockedRuntimeV2Error.invalidAnalysisGrid
        }
        var dispatches: [ASHLockedRuntimeDispatchV2] = []
        dispatches.reserveCapacity(analysisGrid.count * route.phasePairCount)
        for cell in analysisGrid.cells {
            let state: ASHState
            switch mode {
            case .stateOnly:
                state = try ASHLUTLeafCompilerV2.spatialSemanticState(
                    cell.analysis.state
                )
            case .fixedDescriptor, .nonASHSelector:
                state = ASHState(validatedRawValue: 0)
            }
            let sidecar = try ASHLockedRuntimeV2.spatialSidecar(
                cell.analysis.sidecar
            )
            for phaseOrdinal in 0..<route.phasePairCount {
                let descriptorID = try descriptorID(
                    mode: mode,
                    cell: cell,
                    state: state,
                    phaseOrdinal: phaseOrdinal,
                    route: route,
                    selection: selection,
                    analysisGrid: analysisGrid
                )
                dispatches.append(try dispatch(
                    descriptorID: descriptorID,
                    state: state,
                    sidecar: sidecar,
                    configuration: configuration
                ))
            }
        }
        return ASHLockedDispatchGridV2(
            route: route,
            configuration: configuration,
            context: .spatialOnly,
            analysisColumnCount: analysisGrid.columnCount,
            analysisRowCount: analysisGrid.rowCount,
            dispatches: dispatches,
            counters: .zero
        )
    }
}

extension ASHLockedControlRuntimeV2 {
    private static func descriptorID(
        mode: ASHLockedDispatchControlModeV2,
        cell: ASHAnalysisGridCellV2,
        state: ASHState,
        phaseOrdinal: Int,
        route: ASHSpatialRouteV2,
        selection: ASHLUTLockedRouteSelectionV2,
        analysisGrid: ASHAnalysisGridV2
    ) throws -> UInt8 {
        switch mode {
        case .fixedDescriptor(let descriptorID):
            guard descriptorID < ASHSpatialDescriptorV2.count else {
                throw ASHLockedControlRuntimeV2Error.invalidDescriptorID(
                    Int(descriptorID)
                )
            }
            return descriptorID
        case .stateOnly:
            return ASHLUTLeafCompilerV2.baseDescriptorID(
                state: state,
                phaseOrdinal: phaseOrdinal,
                route: route
            )
        case .nonASHSelector(let rule):
            return try nonASHDescriptorID(
                rule: rule,
                sidecar: cell.analysis.sidecar,
                phaseOrdinal: phaseOrdinal,
                route: route,
                selection: selection,
                analysisGrid: analysisGrid
            )
        }
    }

    private static func dispatch(
        descriptorID: UInt8,
        state: ASHState,
        sidecar: ASHSpatialSidecarV2,
        configuration: ASHLUTLockedConfigurationV2
    ) throws -> ASHLockedRuntimeDispatchV2 {
        let zeroDelta = ASHLUTSemanticDeltaV2(
            orientation: 0,
            support: 0,
            detail: 0,
            regularization: 0
        )
        let semantics = ASHLUTLeafCompilerV2.apply(
            delta: zeroDelta,
            to: descriptorID,
            parameters: configuration.operatorParameters,
            steps: configuration.semanticSteps
        )
        guard semantics.descriptorID == descriptorID else {
            throw ASHLockedControlRuntimeV2Error.invalidControlMode
        }
        let locked = configuration.operatorParameters
        let parameters = ASHSpatialDevelopmentParametersV2(
            anisotropyStrength: Double(locked.anisotropyStrengthQ12) / 4_096.0,
            minimumAnisotropicMagnitude: (
                Double(locked.minimumAnisotropicMagnitudeUNorm15) / 32_767.0
            ),
            minimumAnisotropicCoherence: (
                Double(locked.minimumAnisotropicCoherenceUNorm15) / 32_767.0
            ),
            controlledDetailGain: Double(semantics.detailGainQ12) / 4_096.0,
            relaxedLimiterAlpha: (
                Double(semantics.relaxedLimiterAlphaQ12) / 4_096.0
            ),
            riskDetailSuppressionThreshold: (
                Double(locked.riskSuppressionUNorm15) / 32_767.0
            ),
            lowPassRadius: Double(locked.lowPassRadiusQ8x8) / 256.0,
            weightEpsilon: Double(
                Float(bitPattern: locked.weightEpsilonF32Bits)
            ),
            supportRadius: Double(semantics.supportRadiusQ8x8) / 256.0
        )
        guard parameters.isValid else {
            throw ASHLockedRuntimeV2Error.invalidRuntimeParameter
        }
        let message = ASHMessage(validatedRawValue: 0)
        let decode = ASHLockedAffineDecodeResultV2(
            status: .exact,
            message: message,
            correctedCoordinate: nil,
            distance: 0,
            nearestCount: 1
        )
        let candidate = ASHLockedRuntimeCandidateV2(
            decodedMessage: message,
            descriptor: try ASHSpatialDescriptorV2(id: descriptorID),
            affineDecode: decode,
            sidecar: sidecar,
            orientationSector: ASHVideoAnalyzerV2.quantizeTangentSector(
                sidecar.orientationRadians
            ),
            parameters: parameters
        )
        return ASHLockedRuntimeDispatchV2(
            sourceState: state,
            parityWasRecomputed: false,
            primary: candidate,
            secondary: nil,
            primaryWeightUNorm16: UInt16.max,
            secondaryWeightUNorm16: 0,
            marginUNorm16: UInt16.max,
            affineFallbackUsed: false,
            sourceAlignedEntryFlag: false,
            counters: .zero
        )
    }

    private static func nonASHDescriptorID(
        rule: ASHLockedNonASHRuleV2,
        sidecar: ASHVideoAnalyzerV2Sidecar,
        phaseOrdinal: Int,
        route: ASHSpatialRouteV2,
        selection: ASHLUTLockedRouteSelectionV2,
        analysisGrid: ASHAnalysisGridV2
    ) throws -> UInt8 {
        try nonASHDescriptorID(
            rule: rule,
            cellFeatureValuesQ15: nonASHCellFeatureValuesQ15(sidecar),
            phaseFeatureValuesQ15: nonASHPhaseFeatureValuesQ15(
                phaseOrdinal: phaseOrdinal,
                route: route,
                selection: selection,
                sourceWidth: analysisGrid.sourceWidth,
                sourceHeight: analysisGrid.sourceHeight
            )
        )
    }

    static func nonASHCellFeatureValuesQ15(
        _ sidecar: ASHVideoAnalyzerV2Sidecar
    ) -> [Int16] {
        [
            exactInt16(centeredUNormQ15(sidecar.normalizedGradientMagnitude)),
            exactInt16(centeredUNormQ15(sidecar.structureCoherence)),
            exactInt16(centeredUNormQ15(sidecar.textureEnergy)),
            exactInt16(centeredUNormQ15(sidecar.riskProxy)),
            exactInt16(centeredUNormQ15(sidecar.chromaAlignment)),
            exactInt16(signedQ15(cos(2.0 * sidecar.edgeTangentRadians))),
            exactInt16(signedQ15(sin(2.0 * sidecar.edgeTangentRadians))),
            exactInt16(centeredUNormQ15(sidecar.localNoiseEstimate))
        ]
    }

    static func nonASHPhaseFeatureValuesQ15(
        phaseOrdinal: Int,
        route: ASHSpatialRouteV2,
        selection: ASHLUTLockedRouteSelectionV2,
        sourceWidth: Int,
        sourceHeight: Int
    ) throws -> [Int16] {
        guard (0..<route.phasePairCount).contains(phaseOrdinal) else {
            throw ASHLockedRuntimeV2Error.invalidPhase
        }
        let horizontalPhaseIndex = phaseOrdinal % route.scaleNumerator
        let verticalPhaseIndex = phaseOrdinal / route.scaleNumerator
        let outputWidth = try route.destinationExtent(for: sourceWidth)
        let outputHeight = try route.destinationExtent(for: sourceHeight)
        let horizontalCoordinate = try ASHSpatialOperatorBankV2.coordinate(
            destinationIndex: horizontalPhaseIndex,
            sourceExtent: sourceWidth,
            destinationExtent: outputWidth,
            policy: selection.lumaCoordinatePolicy
        )
        let verticalCoordinate = try ASHSpatialOperatorBankV2.coordinate(
            destinationIndex: verticalPhaseIndex,
            sourceExtent: sourceHeight,
            destinationExtent: outputHeight,
            policy: selection.lumaCoordinatePolicy
        )
        let horizontalPhase = ASHSpatialPhaseComponentV2(
            coordinate: horizontalCoordinate
        )
        let verticalPhase = ASHSpatialPhaseComponentV2(
            coordinate: verticalCoordinate
        )
        return [
            exactInt16(centeredUNormQ15(
                Double(horizontalPhase.numerator) / Double(horizontalPhase.denominator)
            )),
            exactInt16(centeredUNormQ15(
                Double(verticalPhase.numerator) / Double(verticalPhase.denominator)
            )),
            exactInt16(route == .direct2x ? -32_767 : 32_767)
        ]
    }

    static func nonASHDescriptorID(
        rule: ASHLockedNonASHRuleV2,
        cellFeatureValuesQ15: [Int16],
        phaseFeatureValuesQ15: [Int16]
    ) throws -> UInt8 {
        guard cellFeatureValuesQ15.count == nonASHCellFeatureOrder.count,
              phaseFeatureValuesQ15.count == nonASHPhaseFeatureOrder.count else {
            throw ASHLockedControlRuntimeV2Error.invalidNonASHFeatureShape
        }
        return try nonASHDescriptorID(
            preparedRule: prepareNonASHRule(rule),
            cellFeatureValuesQ15: cellFeatureValuesQ15,
            cellOffset: 0,
            phaseFeatureValuesQ15: phaseFeatureValuesQ15,
            phaseOffset: 0
        )
    }

    static func nonASHDescriptorID(
        rule: ASHLockedNonASHRuleV2,
        cellFeatureValuesQ15: [Int16],
        cellOffset: Int,
        phaseFeatureValuesQ15: [Int16],
        phaseOffset: Int
    ) throws -> UInt8 {
        try nonASHDescriptorID(
            preparedRule: prepareNonASHRule(rule),
            cellFeatureValuesQ15: cellFeatureValuesQ15,
            cellOffset: cellOffset,
            phaseFeatureValuesQ15: phaseFeatureValuesQ15,
            phaseOffset: phaseOffset
        )
    }

    static func prepareNonASHRule(
        _ rule: ASHLockedNonASHRuleV2
    ) throws -> ASHLockedPreparedNonASHRuleV2 {
        guard Set(rule.coordinates.keys) == Set(ASHLockedNonASHRuleV2.coordinateOrder),
              rule.coordinates.values.allSatisfy(
                ASHLockedNonASHRuleV2.permittedValues.contains
              ) else {
            throw ASHLockedControlRuntimeV2Error.invalidNonASHRule
        }
        var biasScores: [Int64] = []
        biasScores.reserveCapacity(ASHSpatialDescriptorV2.count)
        for descriptor in 0..<ASHSpatialDescriptorV2.count {
            let name = ASHLockedNonASHRuleV2.coordinateOrder[descriptor]
            guard let bias = rule.coordinates[name],
                  let exactBias = Int64(exactly: bias) else {
                throw ASHLockedControlRuntimeV2Error.invalidNonASHRule
            }
            let (score, overflow) = exactBias.multipliedReportingOverflow(by: 1 << 15)
            guard !overflow else {
                throw ASHLockedControlRuntimeV2Error.invalidNonASHRule
            }
            biasScores.append(score)
        }
        var signedWeights: [Int64] = []
        signedWeights.reserveCapacity(
            ASHSpatialDescriptorV2.count * nonASHFeatureOrder.count
        )
        for descriptor in 0..<ASHSpatialDescriptorV2.count {
            let descriptorID = UInt8(descriptor)
            for name in nonASHFeatureOrder {
                guard let weight = rule.coordinates[name],
                      let exactWeight = Int64(exactly: weight) else {
                    throw ASHLockedControlRuntimeV2Error.invalidNonASHRule
                }
                signedWeights.append(
                    Int64(featureSign(coordinate: name, descriptorID: descriptorID))
                        * exactWeight
                )
            }
        }
        return ASHLockedPreparedNonASHRuleV2(
            descriptorBiasScores: biasScores,
            signedFeatureWeights: signedWeights
        )
    }

    static func nonASHDescriptorID(
        preparedRule: ASHLockedPreparedNonASHRuleV2,
        cellFeatureValuesQ15: [Int16],
        cellOffset: Int,
        phaseFeatureValuesQ15: [Int16],
        phaseOffset: Int
    ) throws -> UInt8 {
        let cellCount = nonASHCellFeatureOrder.count
        let phaseCount = nonASHPhaseFeatureOrder.count
        let featureCount = nonASHFeatureOrder.count
        guard cellOffset >= 0,
              phaseOffset >= 0,
              cellFeatureValuesQ15.count >= cellCount,
              phaseFeatureValuesQ15.count >= phaseCount,
              cellOffset <= cellFeatureValuesQ15.count - cellCount,
              phaseOffset <= phaseFeatureValuesQ15.count - phaseCount,
              preparedRule.descriptorBiasScores.count == ASHSpatialDescriptorV2.count,
              preparedRule.signedFeatureWeights.count
                == ASHSpatialDescriptorV2.count * featureCount else {
            throw ASHLockedControlRuntimeV2Error.invalidNonASHFeatureShape
        }
        var bestDescriptor = UInt8(0)
        var bestScore = Int64.min
        for descriptor in 0..<ASHSpatialDescriptorV2.count {
            var score = preparedRule.descriptorBiasScores[descriptor]
            let weightOffset = descriptor * featureCount
            for featureIndex in 0..<featureCount {
                let feature = featureIndex < cellCount
                    ? cellFeatureValuesQ15[cellOffset + featureIndex]
                    : phaseFeatureValuesQ15[phaseOffset + featureIndex - cellCount]
                let signedWeight = preparedRule.signedFeatureWeights[
                    weightOffset + featureIndex
                ]
                let (term, multiplicationOverflow) = signedWeight
                    .multipliedReportingOverflow(by: Int64(feature))
                let (next, additionOverflow) = score.addingReportingOverflow(term)
                guard !multiplicationOverflow, !additionOverflow else {
                    throw ASHLockedControlRuntimeV2Error.invalidNonASHFeature
                }
                score = next
            }
            if score > bestScore {
                bestScore = score
                bestDescriptor = UInt8(descriptor)
            }
        }
        return bestDescriptor
    }

    private static func featureSign(
        coordinate: String,
        descriptorID: UInt8
    ) -> Int {
        let bit: UInt8
        switch coordinate {
        case "weight_magnitude_q8_8", "weight_coherence_q8_8",
             "weight_orientation_cos_q8_8", "weight_orientation_sin_q8_8":
            bit = 0b0010
        case "weight_texture_q8_8", "weight_risk_q8_8":
            bit = 0b0100
        case "weight_chroma_alignment_q8_8", "weight_noise_q8_8":
            bit = 0b1000
        default:
            bit = 0b0001
        }
        return descriptorID & bit == 0 ? -1 : 1
    }

    private static func centeredUNormQ15(_ value: Double) -> Int {
        let unit = min(1.0, max(0.0, value))
        let quantized = Int((unit * 32_767.0).rounded(.toNearestOrEven))
        return (2 * quantized) - 32_767
    }

    private static func signedQ15(_ value: Double) -> Int {
        let signed = min(1.0, max(-1.0, value))
        return Int((signed * 32_767.0).rounded(.toNearestOrEven))
    }

    private static func exactInt16(_ value: Int) -> Int16 {
        precondition(Int(Int16.min)...Int(Int16.max) ~= value)
        return Int16(value)
    }
}
