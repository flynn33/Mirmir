import Foundation

enum ASHLockedDispatchControlModeV3: Equatable, Sendable {
    case fixedDescriptor(UInt8)
    case stateOnly
    case nonASHSelector(ASHLockedNonASHRuleV2)
}

enum ASHLockedControlRuntimeV3 {
    static func prepareFrame(
        input: ASHLockedFramePipelineInputV3,
        mode: ASHLockedDispatchControlModeV3
    ) throws -> ASHLockedFrameRuntimeV3 {
        let selection = input.configuration.routeSelection(for: input.lut.route)
        let analysisGrid = try ASHAnalysisGridBuilderV2.build(
            luma: input.source.luma,
            cb: input.source.cb,
            cr: input.source.cr,
            chromaSiting: input.source.chromaSiting,
            step: Int(selection.analysisGridSourceStep),
            boundary: input.configuration.boundaryMode,
            configuration: input.analyzerConfiguration
        )
        let luma = try makeDispatchGrid(
            route: input.lut.route,
            configuration: input.configuration,
            analysisGrid: analysisGrid,
            planeRole: .luma,
            mode: mode
        )
        let chroma = try makeDispatchGrid(
            route: input.lut.route,
            configuration: input.configuration,
            analysisGrid: analysisGrid,
            planeRole: .chroma,
            mode: mode
        )
        return ASHLockedFrameRuntimeV3(
            analysisGrid: analysisGrid,
            dispatchGrids: ASHLockedPlaneDispatchGridsV3(
                luma: luma,
                chroma: chroma
            ),
            chromaSiting: input.source.chromaSiting,
            constructionCounters: .preparedFrame
        )
    }

    private static func makeDispatchGrid(
        route: ASHSpatialRouteV2,
        configuration: ASHLUTLockedConfigurationV3,
        analysisGrid: ASHAnalysisGridV2,
        planeRole: ASHLUTPlaneRoleV3,
        mode: ASHLockedDispatchControlModeV3
    ) throws -> ASHLockedDispatchGridV3 {
        let selection = configuration.routeSelection(for: route)
        guard analysisGrid.step == Int(selection.analysisGridSourceStep) else {
            throw ASHLockedRuntimeV3Error.invalidAnalysisGrid
        }
        let v2Selection = try ASHLUTLockedRouteSelectionV2(
            lumaCoordinatePolicy: selection.coordinatePolicy(for: planeRole),
            chromaCoordinatePolicy: selection.coordinatePolicy(for: planeRole),
            analysisGridSourceStep: selection.analysisGridSourceStep
        )
        var dispatches: [ASHLockedRuntimeDispatchV3] = []
        dispatches.reserveCapacity(analysisGrid.count * route.phasePairCount)
        for cell in analysisGrid.cells {
            let sourceState: ASHState
            switch mode {
            case .stateOnly:
                sourceState = try ASHLUTLeafCompilerV3.spatialSemanticState(
                    cell.analysis.state
                )
            case .fixedDescriptor, .nonASHSelector:
                sourceState = ASHState(validatedRawValue: 0)
            }
            let sidecar = try ASHLockedRuntimeV3.spatialSidecar(
                cell.analysis.sidecar
            )
            for phaseOrdinal in 0..<route.phasePairCount {
                let descriptorID: UInt8
                switch mode {
                case .fixedDescriptor(let value):
                    guard value < ASHSpatialDescriptorV2.count else {
                        throw ASHLockedControlRuntimeV2Error.invalidDescriptorID(
                            Int(value)
                        )
                    }
                    descriptorID = value
                case .stateOnly:
                    descriptorID = ASHLUTLeafCompilerV3.baseDescriptorID(
                        state: sourceState,
                        phaseOrdinal: phaseOrdinal,
                        route: route,
                        spatialPolicyID: selection.spatialPolicyID
                    )
                case .nonASHSelector(let rule):
                    descriptorID = try ASHLockedControlRuntimeV2.nonASHDescriptorID(
                        rule: rule,
                        cellFeatureValuesQ15: ASHLockedControlRuntimeV2
                            .nonASHCellFeatureValuesQ15(cell.analysis.sidecar),
                        phaseFeatureValuesQ15: ASHLockedControlRuntimeV2
                            .nonASHPhaseFeatureValuesQ15(
                                phaseOrdinal: phaseOrdinal,
                                route: route,
                                selection: v2Selection,
                                sourceWidth: analysisGrid.sourceWidth,
                                sourceHeight: analysisGrid.sourceHeight
                            )
                    )
                }
                dispatches.append(try dispatch(
                    descriptorID: descriptorID,
                    sourceState: sourceState,
                    planeRole: planeRole,
                    sidecar: sidecar,
                    route: route,
                    configuration: configuration
                ))
            }
        }
        return ASHLockedDispatchGridV3(
            route: route,
            configuration: configuration,
            planeRole: planeRole,
            context: .spatialOnly,
            analysisColumnCount: analysisGrid.columnCount,
            analysisRowCount: analysisGrid.rowCount,
            dispatches: dispatches
        )
    }

    private static func dispatch(
        descriptorID: UInt8,
        sourceState: ASHState,
        planeRole: ASHLUTPlaneRoleV3,
        sidecar: ASHSpatialSidecarV3,
        route: ASHSpatialRouteV2,
        configuration: ASHLUTLockedConfigurationV3
    ) throws -> ASHLockedRuntimeDispatchV3 {
        let semantics = ASHLUTLeafCompilerV3.apply(
            delta: ASHLUTSemanticDeltaV3(
                orientation: 0,
                support: 0,
                detail: 0,
                regularization: 0
            ),
            to: descriptorID,
            parameters: configuration.operatorParameters,
            steps: configuration.semanticSteps
        )
        guard semantics.descriptorID == descriptorID else {
            throw ASHLockedControlRuntimeV2Error.invalidControlMode
        }
        let locked = configuration.operatorParameters
        let anisotropyMode = configuration
            .routeSelection(for: route)
            .anisotropyMode(for: planeRole)
        let parameters = ASHSpatialDevelopmentParametersV2(
            anisotropyStrength: Double(
                anisotropyMode.anisotropyStrengthQ12
            ) / 4_096.0,
            minimumAnisotropicMagnitude: Double(
                locked.minimumAnisotropicMagnitudeUNorm15
            ) / 32_767.0,
            minimumAnisotropicCoherence: Double(
                locked.minimumAnisotropicCoherenceUNorm15
            ) / 32_767.0,
            controlledDetailGain: Double(
                semantics.detailGainQ12
            ) / 4_096.0,
            relaxedLimiterAlpha: Double(
                semantics.relaxedLimiterAlphaQ12
            ) / 4_096.0,
            riskDetailSuppressionThreshold: Double(
                locked.riskSuppressionUNorm15
            ) / 32_767.0,
            lowPassRadius: Double(locked.lowPassRadiusQ8x8) / 256.0,
            weightEpsilon: Double(
                Float(bitPattern: locked.weightEpsilonF32Bits)
            ),
            supportRadius: Double(semantics.supportRadiusQ8x8) / 256.0
        )
        guard parameters.isValid else {
            throw ASHLockedRuntimeV3Error.invalidRuntimeParameter
        }
        let message = ASHMessage(validatedRawValue: 0)
        let decode = ASHLockedAffineDecodeResultV2(
            status: .exact,
            message: message,
            correctedCoordinate: nil,
            distance: 0,
            nearestCount: 1
        )
        let candidate = ASHLockedRuntimeCandidateV3(
            decodedMessage: message,
            descriptor: try ASHSpatialDescriptorV2(id: descriptorID),
            affineDecode: decode,
            sidecar: sidecar,
            orientationSector: ASHVideoAnalyzerV2.quantizeTangentSector(
                sidecar.operatorSidecar.orientationRadians
            ),
            anisotropyMode: anisotropyMode,
            parameters: parameters
        )
        return ASHLockedRuntimeDispatchV3(
            sourceState: sourceState,
            planeRole: planeRole,
            parityWasRecomputed: false,
            primary: candidate,
            secondary: nil,
            primaryWeightUNorm16: UInt16.max,
            secondaryWeightUNorm16: 0,
            marginUNorm16: UInt16.max,
            affineFallbackUsed: false,
            sourceAlignedEntryFlag: false
        )
    }
}
