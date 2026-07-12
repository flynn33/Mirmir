import Foundation

extension ASHLockedRuntimeV2 {
    static func makeDispatchGrid(
        lut: ASHLUTLoadedV2,
        configuration: ASHLUTLockedConfigurationV2,
        analysisGrid: ASHAnalysisGridV2,
        context: ASHLUTContextV2 = .spatialOnly,
        telemetry: any ASHTelemetryRecording = ASHNoopTelemetryRecorder.shared
    ) throws -> ASHLockedDispatchGridV2 {
        guard lut.configuration == configuration else {
            throw ASHLockedRuntimeV2Error.configurationMismatch
        }
        let routeSelection = configuration.routeSelection(for: lut.route)
        guard analysisGrid.step == Int(routeSelection.analysisGridSourceStep) else {
            throw ASHLockedRuntimeV2Error.invalidAnalysisGrid
        }
        var dispatches: [ASHLockedRuntimeDispatchV2] = []
        dispatches.reserveCapacity(analysisGrid.count * lut.route.phasePairCount)
        for cell in analysisGrid.cells {
            let sidecar = try spatialSidecar(cell.analysis.sidecar)
            for phaseOrdinal in 0..<lut.route.phasePairCount {
                dispatches.append(try dispatch(
                    lut: lut,
                    configuration: configuration,
                    sourceState: cell.analysis.state,
                    phaseOrdinal: phaseOrdinal,
                    context: context,
                    sidecar: sidecar,
                    telemetry: telemetry
                ))
            }
        }
        return ASHLockedDispatchGridV2(
            route: lut.route,
            configuration: configuration,
            context: context,
            analysisColumnCount: analysisGrid.columnCount,
            analysisRowCount: analysisGrid.rowCount,
            dispatches: dispatches,
            counters: .zero
        )
    }

    static func dispatch(
        lut: ASHLUTLoadedV2,
        configuration: ASHLUTLockedConfigurationV2,
        sourceState: ASHState,
        phaseOrdinal: Int,
        context: ASHLUTContextV2,
        sidecar: ASHSpatialSidecarV2,
        telemetry: any ASHTelemetryRecording = ASHNoopTelemetryRecorder.shared
    ) throws -> ASHLockedRuntimeDispatchV2 {
        guard lut.configuration == configuration else {
            throw ASHLockedRuntimeV2Error.configurationMismatch
        }
        let normalized = normalize(sourceState)
        telemetry.recordState(rawValue: normalized.state.rawValue)
        let entry = try lut.entry(
            state: normalized.state,
            phaseOrdinal: phaseOrdinal,
            context: context
        )
        guard Int(entry.parameterIndex) < lut.parameters.count else {
            throw ASHLockedRuntimeV2Error.parameterIndexOutOfBounds(entry.parameterIndex)
        }
        return try dispatch(
            entry: entry,
            parameters: lut.parameters[Int(entry.parameterIndex)],
            configuration: configuration,
            route: lut.route,
            sourceState: normalized.state,
            parityWasRecomputed: normalized.recomputed,
            sidecar: sidecar,
            telemetry: telemetry
        )
    }

    static func dispatch(
        entry: ASHLUTLoadedEntryV2,
        parameters: ASHLUTParameterPairV2,
        configuration: ASHLUTLockedConfigurationV2,
        route: ASHSpatialRouteV2,
        sourceState: ASHState,
        parityWasRecomputed: Bool,
        sidecar: ASHSpatialSidecarV2,
        telemetry: any ASHTelemetryRecording = ASHNoopTelemetryRecorder.shared
    ) throws -> ASHLockedRuntimeDispatchV2 {
        _ = route
        let normalized = normalize(sourceState)
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
                parityWasRecomputed: parityWasRecomputed || normalized.recomputed,
                decode: primaryDecode,
                configuration: configuration,
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
            sidecar: sidecar
        )

        var secondaryCandidate: ASHLockedRuntimeCandidateV2?
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
                    parityWasRecomputed: parityWasRecomputed || normalized.recomputed,
                    decode: secondaryDecode,
                    configuration: configuration,
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
                sidecar: sidecar
            )
        }

        let dispatch = ASHLockedRuntimeDispatchV2(
            sourceState: normalized.state,
            parityWasRecomputed: parityWasRecomputed || normalized.recomputed,
            primary: primary,
            secondary: secondaryCandidate,
            primaryWeightUNorm16: entry.primaryWeightUNorm16,
            secondaryWeightUNorm16: entry.secondaryWeightUNorm16,
            marginUNorm16: entry.marginUNorm16,
            affineFallbackUsed: false,
            sourceAlignedEntryFlag: entry.flags & ASHLUTBinaryContractV2.entrySourceAlignedExact != 0,
            counters: .zero
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
    ) throws -> ASHSpatialSidecarV2 {
        let minimum = unit(sidecar.localMinimumY)
        let maximum = unit(sidecar.localMaximumY)
        return try ASHSpatialSidecarV2(
            orientationRadians: sidecar.edgeTangentRadians,
            normalizedMagnitude: sidecar.normalizedGradientMagnitude,
            coherence: sidecar.structureCoherence,
            risk: sidecar.riskProxy,
            chromaAlignment: sidecar.chromaAlignment,
            localMinimum: min(minimum, maximum),
            localMaximum: max(minimum, maximum)
        )
    }

    private static func fallbackDispatch(
        sourceState: ASHState,
        parityWasRecomputed: Bool,
        decode: ASHLockedAffineDecodeResultV2,
        configuration: ASHLUTLockedConfigurationV2,
        sidecar: ASHSpatialSidecarV2,
        telemetry: any ASHTelemetryRecording
    ) throws -> ASHLockedRuntimeDispatchV2 {
        let candidateParameters = try runtimeParameters(
            slot: .inactive,
            configuration: configuration,
            conservativeFallback: true
        )
        let candidate = ASHLockedRuntimeCandidateV2(
            decodedMessage: ASHMessage(validatedRawValue: 0),
            descriptor: try ASHSpatialDescriptorV2(id: 0),
            affineDecode: decode,
            sidecar: sidecar,
            orientationSector: ASHVideoAnalyzerV2.quantizeTangentSector(sidecar.orientationRadians),
            parameters: candidateParameters
        )
        let dispatch = ASHLockedRuntimeDispatchV2(
            sourceState: sourceState,
            parityWasRecomputed: parityWasRecomputed,
            primary: candidate,
            secondary: nil,
            primaryWeightUNorm16: UInt16.max,
            secondaryWeightUNorm16: 0,
            marginUNorm16: UInt16.max,
            affineFallbackUsed: true,
            sourceAlignedEntryFlag: false,
            counters: .zero
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
        slot: ASHLUTParameterSlotV2,
        configuration: ASHLUTLockedConfigurationV2,
        sidecar: ASHSpatialSidecarV2
    ) throws -> ASHLockedRuntimeCandidateV2 {
        let sectorDelta = Int(slot.delta.orientation)
        let rotatedRadians = moduloPi(
            sidecar.orientationRadians + (Double(sectorDelta) * (.pi / 4.0))
        )
        let rotatedSidecar = try ASHSpatialSidecarV2(
            orientationRadians: rotatedRadians,
            normalizedMagnitude: sidecar.normalizedMagnitude,
            coherence: sidecar.coherence,
            risk: sidecar.risk,
            chromaAlignment: sidecar.chromaAlignment,
            localMinimum: sidecar.localMinimum,
            localMaximum: sidecar.localMaximum
        )
        return ASHLockedRuntimeCandidateV2(
            decodedMessage: message,
            descriptor: try ASHSpatialDescriptorV2(id: descriptorID),
            affineDecode: decode,
            sidecar: rotatedSidecar,
            orientationSector: moduloFour(
                ASHVideoAnalyzerV2.quantizeTangentSector(sidecar.orientationRadians) + sectorDelta
            ),
            parameters: try runtimeParameters(
                slot: slot,
                configuration: configuration,
                conservativeFallback: false
            )
        )
    }

    private static func runtimeParameters(
        slot: ASHLUTParameterSlotV2,
        configuration: ASHLUTLockedConfigurationV2,
        conservativeFallback: Bool
    ) throws -> ASHSpatialDevelopmentParametersV2 {
        let locked = configuration.operatorParameters
        let anisotropyStrengthQ12 = conservativeFallback
            ? locked.anisotropyStrengthQ12
            : slot.anisotropyStrengthQ12
        let minimumMagnitudeUNorm15 = conservativeFallback
            ? locked.minimumAnisotropicMagnitudeUNorm15
            : slot.minimumAnisotropicMagnitudeUNorm15
        let minimumCoherenceUNorm15 = conservativeFallback
            ? locked.minimumAnisotropicCoherenceUNorm15
            : slot.minimumAnisotropicCoherenceUNorm15
        let riskSuppressionUNorm15 = conservativeFallback
            ? locked.riskSuppressionUNorm15
            : slot.riskSuppressionUNorm15
        let epsilonBits = conservativeFallback ? locked.weightEpsilonF32Bits : slot.weightEpsilonF32Bits
        let parameters = ASHSpatialDevelopmentParametersV2(
            anisotropyStrength: Double(anisotropyStrengthQ12) / 4_096.0,
            minimumAnisotropicMagnitude: Double(minimumMagnitudeUNorm15) / 32_767.0,
            minimumAnisotropicCoherence: Double(minimumCoherenceUNorm15) / 32_767.0,
            controlledDetailGain: conservativeFallback ? 0.0 : Double(slot.detailGainQ12) / 4_096.0,
            relaxedLimiterAlpha: conservativeFallback ? 0.0 : Double(slot.relaxedLimiterAlphaQ12) / 4_096.0,
            riskDetailSuppressionThreshold: Double(riskSuppressionUNorm15) / 32_767.0,
            lowPassRadius: Double(locked.lowPassRadiusQ8x8) / 256.0,
            weightEpsilon: Double(Float(bitPattern: epsilonBits)),
            supportRadius: conservativeFallback ? 2.0 : Double(slot.supportRadiusQ8x8) / 256.0
        )
        guard parameters.isValid else { throw ASHLockedRuntimeV2Error.invalidRuntimeParameter }
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
