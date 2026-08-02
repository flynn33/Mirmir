import Foundation

/// Builds the serialized GPU ABI in memory from the checked-in P05 reference
/// definitions. This is a deterministic development/preview closure, not a
/// replacement for (or claim about) the absent P06 release-lock package.
enum ASHMetalDevelopmentRuntimeFactoryV3 {
    static let implementationVersion = "ash-p05-metal-v3-preview"

    static func makeRuntime(
        route: ASHSpatialRouteV2,
        codeRange: ASHVideoCodeRange8Bit,
        chromaSiting: ASHChromaSitingV2,
        metal: any MetalRenderingService,
        telemetry: any ASHTelemetryRecording = ASHNoopTelemetryRecorder.shared
    ) throws -> ASHMetalSpatialRuntimeV3 {
        let lut = try makeLUT(route: route)
        return try makeRuntime(
            route: route,
            lut: lut,
            codeRange: codeRange,
            chromaSiting: chromaSiting,
            metal: metal,
            telemetry: telemetry
        )
    }

    static func makeRuntime(
        route: ASHSpatialRouteV2,
        lut: ASHMetalRuntimeLUTV3,
        codeRange: ASHVideoCodeRange8Bit,
        chromaSiting: ASHChromaSitingV2,
        metal: any MetalRenderingService,
        telemetry: any ASHTelemetryRecording = ASHNoopTelemetryRecorder.shared
    ) throws -> ASHMetalSpatialRuntimeV3 {
        let configuration = lut.configuration
        let mapping = ASHMetalRuntimeMappingV3(
            analyzerConfiguration: try .makeDisposableP05Reference(),
            codeRange: codeRange,
            chromaSiting: chromaSiting,
            boundaryMode: configuration.boundaryMode,
            direct2xAnalysisGridSourceStep: configuration.direct2x
                .analysisGridSourceStep,
            direct3Over2AnalysisGridSourceStep: configuration.direct3Over2
                .analysisGridSourceStep
        )
        return try ASHMetalSpatialRuntimeV3(
            route: route,
            lut: lut,
            mapping: mapping,
            metal: metal,
            telemetry: telemetry
        )
    }

    static func makeLUT(route: ASHSpatialRouteV2) throws -> ASHMetalRuntimeLUTV3 {
        try makeLUT(route: route, configuration: makeConfiguration())
    }
}

private extension ASHMetalDevelopmentRuntimeFactoryV3 {
    static func makeConfiguration() throws -> ASHMetalRuntimeConfigurationV3 {
        let development = ASHSpatialDevelopmentParametersV2.p05DevelopmentOnly
        let source = ASHSpatialRuntimeConfigurationV2.developmentP05
        guard development.isValid,
              source.analysisGrid == "source_site",
              let anisotropyMode = ASHLUTAnisotropyModeV3.allCases.first(
                where: { $0.anisotropyStrengthQ12 == q12(development.anisotropyStrength) }
              ) else {
            throw ASHMetalSpatialRuntimeErrorV3.configurationMismatch
        }
        let runtimeParameters = ASHMetalRuntimeOperatorParametersV3(
            minimumAnisotropicMagnitudeUNorm15: unorm15(
                development.minimumAnisotropicMagnitude
            ),
            minimumAnisotropicCoherenceUNorm15: unorm15(
                development.minimumAnisotropicCoherence
            ),
            detailGainQ12: q12(development.controlledDetailGain),
            relaxedLimiterAlphaQ12: q12(development.relaxedLimiterAlpha),
            riskSuppressionUNorm15: unorm15(
                development.riskDetailSuppressionThreshold
            ),
            lowPassRadiusQ8x8: UInt16(
                (development.lowPassRadius * 256.0).rounded()
            ),
            weightEpsilonF32Bits: Float(development.weightEpsilon).bitPattern
        )
        let selection = ASHMetalRuntimeRouteSelectionV3(
            spatialPolicyID: nil,
            lumaAnisotropyMode: anisotropyMode,
            chromaAnisotropyMode: anisotropyMode,
            lumaCoordinatePolicy: source.coordinatePolicy,
            chromaCoordinatePolicy: source.coordinatePolicy,
            analysisGridSourceStep: 1
        )
        return ASHMetalRuntimeConfigurationV3(
            boundaryMode: source.boundaryMode,
            operatorParameters: runtimeParameters,
            direct2x: selection,
            direct3Over2: selection
        )
    }

    static func makeLUT(
        route: ASHSpatialRouteV2,
        configuration: ASHMetalRuntimeConfigurationV3
    ) throws -> ASHMetalRuntimeLUTV3 {
        let expectedCount = route.phasePairCount
            * ASHLUTContextV3.allCases.count
            * ASHLUTStateOrdinalTableV3.validStates.count
            * ASHLUTPlaneRoleV3.allCases.count
        var entries: [ASHLUTCompiledEntryV3] = []
        entries.reserveCapacity(expectedCount)
        for planeRole in ASHLUTPlaneRoleV3.allCases {
            for phaseOrdinal in 0..<route.phasePairCount {
                for context in ASHLUTContextV3.allCases {
                    for (stateOrdinal, state) in ASHLUTStateOrdinalTableV3
                        .validStates.enumerated() {
                        entries.append(try makeEntry(
                            logicalIndex: entries.count,
                            planeRole: planeRole,
                            phaseOrdinal: phaseOrdinal,
                            context: context,
                            stateOrdinal: stateOrdinal,
                            state: state,
                            route: route,
                            configuration: configuration
                        ))
                    }
                }
            }
        }
        guard entries.count == expectedCount else {
            throw ASHLUTCompilerErrorV3.entryCountMismatch
        }
        let source = ASHSpatialRuntimeConfigurationV2.developmentP05
        let artifact = try ASHLUTBinaryCodecV3.serializeDevelopmentRuntime(
            route: route,
            entries: entries,
            mappingSHA256: ASHLUTHashV3(hex: source.mappingSHA256),
            operatorBankSHA256: ASHLUTHashV3(hex: source.operatorBankSHA256),
            selection: configuration.routeSelection(for: route)
        )
        return try ASHMetalRuntimeLUTV3(
            route: route,
            configuration: configuration,
            immutableBytes: artifact.data,
            parameterCount: artifact.parameterCount
        )
    }

    // swiftlint:disable:next function_parameter_count
    static func makeEntry(
        logicalIndex: Int,
        planeRole: ASHLUTPlaneRoleV3,
        phaseOrdinal: Int,
        context: ASHLUTContextV3,
        stateOrdinal: Int,
        state: ASHState,
        route: ASHSpatialRouteV2,
        configuration: ASHMetalRuntimeConfigurationV3
    ) throws -> ASHLUTCompiledEntryV3 {
        let sourceAligned = phaseOrdinal == 0
        let dispatch: ASHSpatialDispatchV2
        if sourceAligned {
            dispatch = ASHSpatialDispatchV2(
                sourceState: state,
                selectorState: state,
                parityWasRecomputed: false,
                primaryDecodedMessage: ASHMessage(validatedRawValue: 0),
                secondaryDecodedMessage: nil,
                primaryAffineState: state,
                secondaryAffineState: nil,
                primaryWeight: 1,
                secondaryWeight: 0,
                margin: 1
            )
        } else {
            let phase = try ASHSpatialPhaseV2.sourceAlignedDevelopment(
                horizontalIndex: phaseOrdinal % route.scaleNumerator,
                verticalIndex: phaseOrdinal / route.scaleNumerator,
                route: route
            )
            dispatch = try ASHSpatialDevelopmentSelectorV2.dispatch(
                state: state,
                phase: phase
            )
        }
        let primary = candidate(
            message: dispatch.primaryDecodedMessage,
            affineState: dispatch.primaryAffineState,
            configuration: configuration
        )
        let secondary: ASHLUTCompiledCandidateV3?
        if let message = dispatch.secondaryDecodedMessage,
           let affine = dispatch.secondaryAffineState {
            secondary = candidate(
                message: message,
                affineState: affine,
                configuration: configuration
            )
        } else {
            secondary = nil
        }
        let primaryWeight = secondary == nil
            ? UInt16.max
            : unorm16(dispatch.primaryWeight)
        let secondaryWeight = secondary == nil
            ? 0
            : UInt16.max - primaryWeight
        let routeSelection = configuration.routeSelection(for: route)
        return ASHLUTCompiledEntryV3(
            logicalIndex: logicalIndex,
            planeRole: planeRole,
            sourceState: state,
            validStateOrdinal: UInt16(stateOrdinal),
            phaseOrdinal: UInt16(phaseOrdinal),
            context: context,
            primary: primary,
            secondary: secondary,
            primaryWeightUNorm16: primaryWeight,
            secondaryWeightUNorm16: secondaryWeight,
            marginUNorm16: secondary == nil
                ? UInt16.max
                : primaryWeight - secondaryWeight,
            sourceAlignedExact: sourceAligned,
            temporalForcedSpatial: context != .spatialOnly,
            parameters: ASHLUTParameterPairV3(
                primary: parameterSlot(
                    descriptorID: primary.descriptorID,
                    sourceAligned: sourceAligned,
                    planeRole: planeRole,
                    selection: routeSelection,
                    configuration: configuration
                ),
                secondary: secondary.map {
                    parameterSlot(
                        descriptorID: $0.descriptorID,
                        sourceAligned: false,
                        planeRole: planeRole,
                        selection: routeSelection,
                        configuration: configuration
                    )
                } ?? .inactive,
                confidenceThresholdUNorm16: unorm16(
                    ASHSpatialDevelopmentSelectorV2.confidenceThreshold
                ),
                lumaCoordinatePolicy: routeSelection.lumaCoordinatePolicy,
                chromaCoordinatePolicy: routeSelection.chromaCoordinatePolicy,
                boundaryMode: configuration.boundaryMode
            )
        )
    }

    static func candidate(
        message: ASHMessage,
        affineState: ASHState,
        configuration: ASHMetalRuntimeConfigurationV3
    ) -> ASHLUTCompiledCandidateV3 {
        let descriptorID = message.rawValue
        return ASHLUTCompiledCandidateV3(
            message: message,
            affineState: affineState,
            descriptorID: descriptorID,
            representativePathOrdinal: 0,
            representativePenalty: 0,
            aggregatedWeight: 1,
            semanticDelta: ASHLUTSemanticDeltaV3(
                orientation: 0,
                support: 0,
                detail: 0,
                regularization: 0
            ),
            detailGainQ12: descriptorID & 0b0100 == 0
                ? 0 : configuration.operatorParameters.detailGainQ12,
            relaxedLimiterAlphaQ12: descriptorID & 0b1000 == 0
                ? 0 : configuration.operatorParameters.relaxedLimiterAlphaQ12,
            supportRadiusQ8x8: supportRadiusQ8x8(descriptorID: descriptorID)
        )
    }

    static func parameterSlot(
        descriptorID: UInt8,
        sourceAligned: Bool,
        planeRole: ASHLUTPlaneRoleV3,
        selection: ASHMetalRuntimeRouteSelectionV3,
        configuration: ASHMetalRuntimeConfigurationV3
    ) -> ASHLUTParameterSlotV3 {
        let parameters = configuration.operatorParameters
        let effectiveDescriptor: UInt8 = sourceAligned ? 0 : descriptorID
        var flags = ASHLUTParameterSlotV3.activeFlag
        if effectiveDescriptor & 0b0100 != 0 {
            flags |= ASHLUTParameterSlotV3.positiveDetailFlag
        }
        if effectiveDescriptor & 0b1000 != 0 {
            flags |= ASHLUTParameterSlotV3.relaxedLimiterFlag
        }
        if sourceAligned {
            flags |= ASHLUTParameterSlotV3.sourceAlignedPreservationFlag
        }
        return ASHLUTParameterSlotV3(
            anisotropyStrengthQ12: selection.anisotropyMode(for: planeRole)
                .anisotropyStrengthQ12,
            minimumAnisotropicMagnitudeUNorm15:
                parameters.minimumAnisotropicMagnitudeUNorm15,
            minimumAnisotropicCoherenceUNorm15:
                parameters.minimumAnisotropicCoherenceUNorm15,
            detailGainQ12: effectiveDescriptor & 0b0100 == 0
                ? 0 : parameters.detailGainQ12,
            relaxedLimiterAlphaQ12: effectiveDescriptor & 0b1000 == 0
                ? 0 : parameters.relaxedLimiterAlphaQ12,
            riskSuppressionUNorm15: parameters.riskSuppressionUNorm15,
            supportRadiusQ8x8: supportRadiusQ8x8(
                descriptorID: effectiveDescriptor
            ),
            weightEpsilonF32Bits: parameters.weightEpsilonF32Bits,
            delta: ASHLUTSemanticDeltaV3(
                orientation: 0,
                support: 0,
                detail: 0,
                regularization: 0
            ),
            flags: flags
        )
    }

    static func supportRadiusQ8x8(descriptorID: UInt8) -> UInt16 {
        let descriptor = ASHSpatialDescriptorV2.all[Int(descriptorID)]
        return UInt16((descriptor.baseKernel.supportRadius * 256.0).rounded())
    }

    static func unorm15(_ value: Double) -> UInt16 {
        UInt16((min(1, max(0, value)) * 32_767).rounded())
    }

    static func unorm16(_ value: Double) -> UInt16 {
        UInt16((min(1, max(0, value)) * 65_535).rounded())
    }

    static func q12(_ value: Double) -> UInt16 {
        UInt16((min(16, max(0, value)) * 4_096).rounded())
    }

}
