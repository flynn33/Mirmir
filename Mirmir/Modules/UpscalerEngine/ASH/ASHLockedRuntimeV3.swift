import Foundation

extension ASHLockedRuntimeV3 {
    static func prepareFrame(
        lut: ASHLUTLoadedV3,
        configuration: ASHLUTLockedConfigurationV3,
        luma: ASHVideoAnalyzerV2CodePlane,
        cb: ASHVideoAnalyzerV2CodePlane,
        cr: ASHVideoAnalyzerV2CodePlane,
        chromaSiting: ASHChromaSitingV2,
        analyzerConfiguration: ASHVideoAnalyzerV2DevelopmentConfiguration,
        telemetry: any ASHTelemetryRecording = ASHNoopTelemetryRecorder.shared
    ) throws -> ASHLockedFrameRuntimeV3 {
        guard lut.configuration == configuration else {
            throw ASHLockedRuntimeV3Error.configurationMismatch
        }
        let routeSelection = configuration.routeSelection(for: lut.route)
        let analysisGrid = try ASHAnalysisGridBuilderV2.build(
            luma: luma,
            cb: cb,
            cr: cr,
            chromaSiting: chromaSiting,
            step: Int(routeSelection.analysisGridSourceStep),
            boundary: configuration.boundaryMode,
            configuration: analyzerConfiguration
        )
        let grids = try makeDispatchGrids(
            lut: lut,
            configuration: configuration,
            analysisGrid: analysisGrid,
            telemetry: telemetry
        )
        return ASHLockedFrameRuntimeV3(
            analysisGrid: analysisGrid,
            dispatchGrids: grids,
            chromaSiting: chromaSiting,
            constructionCounters: .preparedFrame
        )
    }

    static func makeDispatchGrids(
        lut: ASHLUTLoadedV3,
        configuration: ASHLUTLockedConfigurationV3,
        analysisGrid: ASHAnalysisGridV2,
        telemetry: any ASHTelemetryRecording = ASHNoopTelemetryRecorder.shared
    ) throws -> ASHLockedPlaneDispatchGridsV3 {
        let luma = try makeDispatchGrid(
            lut: lut,
            configuration: configuration,
            analysisGrid: analysisGrid,
            planeRole: .luma,
            telemetry: telemetry
        )
        let chroma = try makeDispatchGrid(
            lut: lut,
            configuration: configuration,
            analysisGrid: analysisGrid,
            planeRole: .chroma,
            telemetry: telemetry
        )
        return ASHLockedPlaneDispatchGridsV3(luma: luma, chroma: chroma)
    }

    static func makeDispatchGrid(
        lut: ASHLUTLoadedV3,
        configuration: ASHLUTLockedConfigurationV3,
        analysisGrid: ASHAnalysisGridV2,
        planeRole: ASHLUTPlaneRoleV3,
        telemetry: any ASHTelemetryRecording = ASHNoopTelemetryRecorder.shared
    ) throws -> ASHLockedDispatchGridV3 {
        guard lut.configuration == configuration else {
            throw ASHLockedRuntimeV3Error.configurationMismatch
        }
        let routeSelection = configuration.routeSelection(for: lut.route)
        guard analysisGrid.step == Int(routeSelection.analysisGridSourceStep) else {
            throw ASHLockedRuntimeV3Error.invalidAnalysisGrid
        }
        var dispatches: [ASHLockedRuntimeDispatchV3] = []
        dispatches.reserveCapacity(analysisGrid.count * lut.route.phasePairCount)
        for cell in analysisGrid.cells {
            let sidecar = try spatialSidecar(cell.analysis.sidecar)
            for phaseOrdinal in 0..<lut.route.phasePairCount {
                dispatches.append(try dispatch(
                    lut: lut,
                    configuration: configuration,
                    planeRole: planeRole,
                    sourceState: cell.analysis.state,
                    phaseOrdinal: phaseOrdinal,
                    sidecar: sidecar,
                    telemetry: telemetry
                ))
            }
        }
        return ASHLockedDispatchGridV3(
            route: lut.route,
            configuration: configuration,
            planeRole: planeRole,
            context: .spatialOnly,
            analysisColumnCount: analysisGrid.columnCount,
            analysisRowCount: analysisGrid.rowCount,
            dispatches: dispatches
        )
    }

    static func dispatch(
        lut: ASHLUTLoadedV3,
        configuration: ASHLUTLockedConfigurationV3,
        planeRole: ASHLUTPlaneRoleV3,
        sourceState: ASHState,
        phaseOrdinal: Int,
        sidecar: ASHSpatialSidecarV3,
        telemetry: any ASHTelemetryRecording = ASHNoopTelemetryRecorder.shared
    ) throws -> ASHLockedRuntimeDispatchV3 {
        guard lut.configuration == configuration else {
            throw ASHLockedRuntimeV3Error.configurationMismatch
        }
        let normalized = normalize(sourceState)
        telemetry.recordState(rawValue: normalized.state.rawValue)
        let entry = try lut.entry(
            state: normalized.state,
            planeRole: planeRole,
            phaseOrdinal: phaseOrdinal,
            context: .spatialOnly
        )
        guard Int(entry.parameterIndex) < lut.parameters.count else {
            throw ASHLockedRuntimeV3Error.parameterIndexOutOfBounds(entry.parameterIndex)
        }
        return try dispatch(
            entry: entry,
            parameters: lut.parameters[Int(entry.parameterIndex)],
            configuration: configuration,
            route: lut.route,
            planeRole: planeRole,
            sourceState: normalized.state,
            parityWasRecomputed: normalized.recomputed,
            sidecar: sidecar,
            telemetry: telemetry
        )
    }

    static func dispatch(
        entry: ASHLUTLoadedEntryV3,
        parameters: ASHLUTParameterPairV3,
        configuration: ASHLUTLockedConfigurationV3,
        route: ASHSpatialRouteV2,
        planeRole: ASHLUTPlaneRoleV3,
        sourceState: ASHState,
        parityWasRecomputed: Bool,
        sidecar: ASHSpatialSidecarV3,
        telemetry: any ASHTelemetryRecording = ASHNoopTelemetryRecorder.shared
    ) throws -> ASHLockedRuntimeDispatchV3 {
        let normalized = normalize(sourceState)
        let anisotropyMode = configuration
            .routeSelection(for: route)
            .anisotropyMode(for: planeRole)
        let primaryDecode = ASHLockedAffineDecoderV2.decode(
            received: entry.primaryAffineState,
            anchor: normalized.state
        )
        telemetry.recordDecode(primaryDecode.status)
        guard primaryDecode.status != .uncorrectable,
              primaryDecode.message == entry.primaryMessage else {
            if primaryDecode.status != .uncorrectable {
                telemetry.recordDecode(.uncorrectable)
            }
            return try fallbackDispatch(
                sourceState: normalized.state,
                planeRole: planeRole,
                parityWasRecomputed: parityWasRecomputed || normalized.recomputed,
                decode: primaryDecode,
                configuration: configuration,
                anisotropyMode: anisotropyMode,
                sidecar: sidecar,
                telemetry: telemetry
            )
        }
        let primary = try candidate(
            message: entry.primaryMessage,
            descriptorID: entry.primaryDescriptorID,
            decode: primaryDecode,
            slot: parameters.primary,
            configuration: configuration,
            anisotropyMode: anisotropyMode,
            sidecar: sidecar
        )

        var secondaryCandidate: ASHLockedRuntimeCandidateV3?
        if let secondaryAffine = entry.secondaryAffineState,
           let secondaryMessage = entry.secondaryMessage,
           let secondaryDescriptorID = entry.secondaryDescriptorID {
            let secondaryDecode = ASHLockedAffineDecoderV2.decode(
                received: secondaryAffine,
                anchor: normalized.state
            )
            telemetry.recordDecode(secondaryDecode.status)
            guard secondaryDecode.status != .uncorrectable,
                  secondaryDecode.message == secondaryMessage else {
                if secondaryDecode.status != .uncorrectable {
                    telemetry.recordDecode(.uncorrectable)
                }
                return try fallbackDispatch(
                    sourceState: normalized.state,
                    planeRole: planeRole,
                    parityWasRecomputed: parityWasRecomputed || normalized.recomputed,
                    decode: secondaryDecode,
                    configuration: configuration,
                    anisotropyMode: anisotropyMode,
                    sidecar: sidecar,
                    telemetry: telemetry
                )
            }
            secondaryCandidate = try candidate(
                message: secondaryMessage,
                descriptorID: secondaryDescriptorID,
                decode: secondaryDecode,
                slot: parameters.secondary,
                configuration: configuration,
                anisotropyMode: anisotropyMode,
                sidecar: sidecar
            )
        }

        let dispatch = ASHLockedRuntimeDispatchV3(
            sourceState: normalized.state,
            planeRole: planeRole,
            parityWasRecomputed: parityWasRecomputed || normalized.recomputed,
            primary: primary,
            secondary: secondaryCandidate,
            primaryWeightUNorm16: entry.primaryWeightUNorm16,
            secondaryWeightUNorm16: entry.secondaryWeightUNorm16,
            marginUNorm16: entry.marginUNorm16,
            affineFallbackUsed: false,
            sourceAlignedEntryFlag: entry.flags & ASHLUTBinaryContractV3.entrySourceAlignedExact != 0
        )
        telemetry.recordMessage(primary.decodedMessage.rawValue)
        telemetry.recordOperator(primary.descriptor.id)
        if let secondaryCandidate {
            telemetry.recordMessage(secondaryCandidate.decodedMessage.rawValue)
            telemetry.recordOperator(secondaryCandidate.descriptor.id)
        }
        telemetry.recordCandidateCount(dispatch.operatorEvaluationCount)
        return dispatch
    }

    static func spatialSidecar(
        _ sidecar: ASHVideoAnalyzerV2Sidecar
    ) throws -> ASHSpatialSidecarV3 {
        let minimum = unit(sidecar.localMinimumY)
        let maximum = unit(sidecar.localMaximumY)
        return try ASHSpatialSidecarV3(
            orientationRadians: sidecar.edgeTangentRadians,
            normalizedMagnitude: sidecar.normalizedGradientMagnitude,
            coherence: sidecar.structureCoherence,
            risk: sidecar.riskProxy,
            chromaAlignment: sidecar.chromaAlignment,
            chromaEdgeConfidence: sidecar.chromaEdgeConfidence,
            localMinimum: min(minimum, maximum),
            localMaximum: max(minimum, maximum)
        )
    }

    private static func fallbackDispatch(
        sourceState: ASHState,
        planeRole: ASHLUTPlaneRoleV3,
        parityWasRecomputed: Bool,
        decode: ASHLockedAffineDecodeResultV2,
        configuration: ASHLUTLockedConfigurationV3,
        anisotropyMode: ASHLUTAnisotropyModeV3,
        sidecar: ASHSpatialSidecarV3,
        telemetry: any ASHTelemetryRecording
    ) throws -> ASHLockedRuntimeDispatchV3 {
        let candidate = ASHLockedRuntimeCandidateV3(
            decodedMessage: ASHMessage(validatedRawValue: 0),
            descriptor: try ASHSpatialDescriptorV2(id: 0),
            affineDecode: decode,
            sidecar: sidecar,
            orientationSector: ASHVideoAnalyzerV2.quantizeTangentSector(
                sidecar.operatorSidecar.orientationRadians
            ),
            anisotropyMode: anisotropyMode,
            parameters: try runtimeParameters(
                slot: .inactive,
                configuration: configuration,
                anisotropyMode: anisotropyMode,
                conservativeFallback: true
            )
        )
        let dispatch = ASHLockedRuntimeDispatchV3(
            sourceState: sourceState,
            planeRole: planeRole,
            parityWasRecomputed: parityWasRecomputed,
            primary: candidate,
            secondary: nil,
            primaryWeightUNorm16: UInt16.max,
            secondaryWeightUNorm16: 0,
            marginUNorm16: UInt16.max,
            affineFallbackUsed: true,
            sourceAlignedEntryFlag: false
        )
        telemetry.recordMessage(candidate.decodedMessage.rawValue)
        telemetry.recordOperator(candidate.descriptor.id)
        telemetry.recordCandidateCount(1)
        return dispatch
    }

    private static func candidate(
        message: ASHMessage,
        descriptorID: UInt8,
        decode: ASHLockedAffineDecodeResultV2,
        slot: ASHLUTParameterSlotV3,
        configuration: ASHLUTLockedConfigurationV3,
        anisotropyMode: ASHLUTAnisotropyModeV3,
        sidecar: ASHSpatialSidecarV3
    ) throws -> ASHLockedRuntimeCandidateV3 {
        let sectorDelta = Int(slot.delta.orientation)
        let rotatedRadians = moduloPi(
            sidecar.operatorSidecar.orientationRadians
                + (Double(sectorDelta) * (.pi / 4.0))
        )
        return ASHLockedRuntimeCandidateV3(
            decodedMessage: message,
            descriptor: try ASHSpatialDescriptorV2(id: descriptorID),
            affineDecode: decode,
            sidecar: try sidecar.rotatingOrientation(to: rotatedRadians),
            orientationSector: moduloFour(
                ASHVideoAnalyzerV2.quantizeTangentSector(
                    sidecar.operatorSidecar.orientationRadians
                ) + sectorDelta
            ),
            anisotropyMode: anisotropyMode,
            parameters: try runtimeParameters(
                slot: slot,
                configuration: configuration,
                anisotropyMode: anisotropyMode,
                conservativeFallback: false
            )
        )
    }

    private static func runtimeParameters(
        slot: ASHLUTParameterSlotV3,
        configuration: ASHLUTLockedConfigurationV3,
        anisotropyMode: ASHLUTAnisotropyModeV3,
        conservativeFallback: Bool
    ) throws -> ASHSpatialDevelopmentParametersV2 {
        if !conservativeFallback,
           slot.anisotropyStrengthQ12 != anisotropyMode.anisotropyStrengthQ12 {
            throw ASHLockedRuntimeV3Error.modeParameterMismatch
        }
        let locked = configuration.operatorParameters
        let minimumMagnitudeUNorm15 = conservativeFallback
            ? locked.minimumAnisotropicMagnitudeUNorm15
            : slot.minimumAnisotropicMagnitudeUNorm15
        let minimumCoherenceUNorm15 = conservativeFallback
            ? locked.minimumAnisotropicCoherenceUNorm15
            : slot.minimumAnisotropicCoherenceUNorm15
        let riskSuppressionUNorm15 = conservativeFallback
            ? locked.riskSuppressionUNorm15
            : slot.riskSuppressionUNorm15
        let epsilonBits = conservativeFallback
            ? locked.weightEpsilonF32Bits
            : slot.weightEpsilonF32Bits
        let parameters = ASHSpatialDevelopmentParametersV2(
            anisotropyStrength: Double(anisotropyMode.anisotropyStrengthQ12) / 4_096.0,
            minimumAnisotropicMagnitude: Double(minimumMagnitudeUNorm15) / 32_767.0,
            minimumAnisotropicCoherence: Double(minimumCoherenceUNorm15) / 32_767.0,
            controlledDetailGain: conservativeFallback
                ? 0.0
                : Double(slot.detailGainQ12) / 4_096.0,
            relaxedLimiterAlpha: conservativeFallback
                ? 0.0
                : Double(slot.relaxedLimiterAlphaQ12) / 4_096.0,
            riskDetailSuppressionThreshold: Double(riskSuppressionUNorm15) / 32_767.0,
            lowPassRadius: Double(locked.lowPassRadiusQ8x8) / 256.0,
            weightEpsilon: Double(Float(bitPattern: epsilonBits)),
            supportRadius: conservativeFallback
                ? 2.0
                : Double(slot.supportRadiusQ8x8) / 256.0
        )
        guard parameters.isValid else {
            throw ASHLockedRuntimeV3Error.invalidRuntimeParameter
        }
        return parameters
    }

    private static func normalize(_ state: ASHState) -> (state: ASHState, recomputed: Bool) {
        guard !state.hasValidIntegrity else { return (state, false) }
        let payload = state.rawValue & 0x01fe
        let parity = UInt16((payload >> 1).nonzeroBitCount & 1)
        return (ASHState(validatedRawValue: payload | parity), true)
    }

    private static func moduloPi(_ angle: Double) -> Double {
        var value = angle.truncatingRemainder(dividingBy: .pi)
        if value < 0.0 { value += .pi }
        return value
    }

    private static func moduloFour(_ value: Int) -> Int {
        let remainder = value % 4
        return remainder >= 0 ? remainder : remainder + 4
    }

    private static func unit(_ value: Double) -> Double {
        min(1.0, max(0.0, value))
    }
}
