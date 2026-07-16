import Foundation

// The P05 CPU reference keeps the analyzer, affine dispatch, direct plane
// evaluation, and fallback path together so the end-to-end contract is
// auditable before the P08 Metal replacement.
// swiftlint:disable file_length type_body_length

enum ASHSpatialReferencePipelineV2Error: Error, Equatable, Sendable {
    case mismatchedChromaGeometry
    case mismatchedPlaneRange
    case unsupportedChromaSubsampling
    case analysisResultCount
    case invalidAnalyzerState
    case invalidPhaseCardinality(expected: Int, actual: Int)
    case missingDispatch
    case numericalFallbackFailed
}

struct ASHSpatialReferenceInputV2: Sendable {
    let luma: ASHVideoAnalyzerV2CodePlane
    let cb: ASHVideoAnalyzerV2CodePlane
    let cr: ASHVideoAnalyzerV2CodePlane
    let chromaSiting: ASHChromaSitingV2
    let route: ASHSpatialRouteV2
    let runtimeConfiguration: ASHSpatialRuntimeConfigurationV2
    let analyzerConfiguration: ASHVideoAnalyzerV2DevelopmentConfiguration
    let operatorParameters: ASHSpatialDevelopmentParametersV2
    let stateInputEnabled: Bool
}

struct ASHSpatialReferencePlaneOutputV2: Equatable, Sendable {
    let width: Int
    let height: Int
    let normalizedSamples: [Double]
}

struct ASHSpatialReferenceSummaryV2: Equatable, Sendable {
    let route: ASHSpatialRouteV2
    let coordinatePolicy: ASHSpatialCoordinatePolicyV2
    let chromaSiting: ASHChromaSitingV2
    let analysisSampleCount: Int
    let reconstructedLumaSampleCount: Int
    let reconstructedChromaSampleCount: Int
    let stateHistogram: [UInt16: Int]
    let operatorHistogram: [UInt8: Int]
    let maxOperatorEvaluations: Int
    let temporalStateCount: Int
    let parityRecomputationCount: Int
    let numericalFallbackCount: Int
    let sourceAlignedPreservationCount: Int
    let runtimeTreeGenerationCount: Int
    let nearestExpansionUsed: Bool
    let stateInputEnabled: Bool
    let runtimeConfiguration: ASHSpatialRuntimeConfigurationV2
}

struct ASHSpatialReferenceOutputV2: Equatable, Sendable {
    let luma: ASHSpatialReferencePlaneOutputV2
    let cb: ASHSpatialReferencePlaneOutputV2
    let cr: ASHSpatialReferencePlaneOutputV2
    let summary: ASHSpatialReferenceSummaryV2
}

private struct ASHSpatialReferenceMutableSummaryV2 {
    var stateHistogram: [UInt16: Int] = [:]
    var operatorHistogram: [UInt8: Int] = [:]
    var maxOperatorEvaluations = 0
    var temporalStateCount = 0
    var parityRecomputationCount = 0
    var numericalFallbackCount = 0
    var sourceAlignedPreservationCount = 0
}

private struct ASHSpatialDispatchKeyV2: Hashable {
    let analysisIndex: Int
    let phase: ASHSpatialPhaseV2
}

private struct ASHSpatialDispatchCachesV2 {
    let luma: [ASHSpatialDispatchKeyV2: ASHSpatialDispatchV2]
    let chroma: [ASHSpatialDispatchKeyV2: ASHSpatialDispatchV2]
}

enum ASHSpatialReferencePipelineV2 {
    static func process(
        _ input: ASHSpatialReferenceInputV2,
        telemetry: any ASHTelemetryRecording = ASHNoopTelemetryRecorder.shared
    ) throws -> ASHSpatialReferenceOutputV2 {
        try validate(input)
        let lumaMeasurements = try telemetry.measure(.analyzeLuma) {
            try analyzeLumaSourceSites(input)
        }
        let measurements = try telemetry.measure(.analyzeChroma) {
            try analyzeChromaSourceSites(input, lumaMeasurements: lumaMeasurements)
        }
        let analyses = try telemetry.measure(.statePack) {
            try packSourceSites(input, measurements: measurements)
        }
        telemetry.increment(.fullFrameCPULoops, by: 3)

        let lumaPlane = try ASHNV12FrameCodec.normalizedPlane(input.luma, channel: .luma)
        let cbPlane = try ASHNV12FrameCodec.normalizedPlane(input.cb, channel: .chroma)
        let crPlane = try ASHNV12FrameCodec.normalizedPlane(input.cr, channel: .chroma)
        var summary = telemetry.measure(.telemetryReduce) {
            recordAnalysisTelemetry(analyses, telemetry: telemetry)
            return makeAnalysisSummary(analyses)
        }
        let dispatches = try telemetry.measure(.dispatchDecode) {
            let luma = try makeDispatches(
                analyses: analyses,
                plane: lumaPlane,
                route: input.route,
                coordinatePolicy: input.runtimeConfiguration.coordinatePolicy,
                chromaSiting: nil,
                stateInputEnabled: input.stateInputEnabled,
                telemetry: telemetry,
                summary: &summary
            )
            let chroma = try makeDispatches(
                analyses: analyses,
                plane: cbPlane,
                route: input.route,
                coordinatePolicy: input.runtimeConfiguration.coordinatePolicy,
                chromaSiting: input.chromaSiting,
                stateInputEnabled: input.stateInputEnabled,
                telemetry: telemetry,
                summary: &summary
            )
            recordDispatchCacheTelemetry(
                analysisCount: analyses.count,
                lumaCount: luma.count,
                chromaCount: chroma.count,
                telemetry: telemetry
            )
            return ASHSpatialDispatchCachesV2(luma: luma, chroma: chroma)
        }

        let luma = try telemetry.measure(.reconstructLuma) {
            try reconstruct(
                plane: lumaPlane,
                route: input.route,
                analyses: analyses,
                dispatches: dispatches.luma,
                lumaWidth: input.luma.width,
                lumaHeight: input.luma.height,
                runtimeConfiguration: input.runtimeConfiguration,
                operatorParameters: input.operatorParameters,
                chromaSiting: nil,
                summary: &summary
            )
        }
        telemetry.increment(.fullFrameCPULoops)

        let cb = try telemetry.measure(.reconstructChroma) {
            try reconstruct(
                plane: cbPlane,
                route: input.route,
                analyses: analyses,
                dispatches: dispatches.chroma,
                lumaWidth: input.luma.width,
                lumaHeight: input.luma.height,
                runtimeConfiguration: input.runtimeConfiguration,
                operatorParameters: input.operatorParameters,
                chromaSiting: input.chromaSiting,
                summary: &summary
            )
        }
        telemetry.increment(.fullFrameCPULoops)
        let cr = try telemetry.measure(.reconstructChroma) {
            try reconstruct(
                plane: crPlane,
                route: input.route,
                analyses: analyses,
                dispatches: dispatches.chroma,
                lumaWidth: input.luma.width,
                lumaHeight: input.luma.height,
                runtimeConfiguration: input.runtimeConfiguration,
                operatorParameters: input.operatorParameters,
                chromaSiting: input.chromaSiting,
                summary: &summary
            )
        }
        telemetry.increment(.fullFrameCPULoops)

        return makeOutput(
            input: input,
            analyses: analyses,
            luma: luma,
            cb: cb,
            cr: cr,
            summary: summary
        )
    }

    private static func makeOutput(
        input: ASHSpatialReferenceInputV2,
        analyses: [ASHVideoAnalyzerV2Result],
        luma: ASHSpatialReferencePlaneOutputV2,
        cb: ASHSpatialReferencePlaneOutputV2,
        cr: ASHSpatialReferencePlaneOutputV2,
        summary: ASHSpatialReferenceMutableSummaryV2
    ) -> ASHSpatialReferenceOutputV2 {
        ASHSpatialReferenceOutputV2(
            luma: luma,
            cb: cb,
            cr: cr,
            summary: ASHSpatialReferenceSummaryV2(
                route: input.route,
                coordinatePolicy: input.runtimeConfiguration.coordinatePolicy,
                chromaSiting: input.chromaSiting,
                analysisSampleCount: analyses.count,
                reconstructedLumaSampleCount: luma.normalizedSamples.count,
                reconstructedChromaSampleCount: cb.normalizedSamples.count + cr.normalizedSamples.count,
                stateHistogram: summary.stateHistogram,
                operatorHistogram: summary.operatorHistogram,
                maxOperatorEvaluations: summary.maxOperatorEvaluations,
                temporalStateCount: summary.temporalStateCount,
                parityRecomputationCount: summary.parityRecomputationCount,
                numericalFallbackCount: summary.numericalFallbackCount,
                sourceAlignedPreservationCount: summary.sourceAlignedPreservationCount,
                runtimeTreeGenerationCount: 0,
                nearestExpansionUsed: false,
                stateInputEnabled: input.stateInputEnabled,
                runtimeConfiguration: input.runtimeConfiguration
            )
        )
    }

    private static func validate(_ input: ASHSpatialReferenceInputV2) throws {
        guard input.cb.width == input.cr.width,
              input.cb.height == input.cr.height else {
            throw ASHSpatialReferencePipelineV2Error.mismatchedChromaGeometry
        }
        guard input.luma.range == input.cb.range,
              input.cb.range == input.cr.range else {
            throw ASHSpatialReferencePipelineV2Error.mismatchedPlaneRange
        }
        guard input.luma.width == input.cb.width * 2,
              input.luma.height == input.cb.height * 2 else {
            throw ASHSpatialReferencePipelineV2Error.unsupportedChromaSubsampling
        }
        _ = try input.route.destinationExtent(for: input.luma.width)
        _ = try input.route.destinationExtent(for: input.luma.height)
        _ = try input.route.destinationExtent(for: input.cb.width)
        _ = try input.route.destinationExtent(for: input.cb.height)
    }

    private static func analyzeLumaSourceSites(
        _ input: ASHSpatialReferenceInputV2
    ) throws -> [ASHVideoAnalyzerV2Measurements] {
        var results: [ASHVideoAnalyzerV2Measurements] = []
        results.reserveCapacity(input.luma.width * input.luma.height)
        let boundary = analyzerBoundary(input.runtimeConfiguration.boundaryMode)
        for row in 0..<input.luma.height {
            for column in 0..<input.luma.width {
                if results.count.isMultiple(of: 4_096) {
                    try Task.checkCancellation()
                }
                results.append(try ASHVideoAnalyzerV2.analyzeLuma(
                    ASHVideoAnalyzerV2Input(
                        luma: input.luma,
                        location: ASHVideoAnalyzerV2Location(x: column, y: row),
                        chroma: nil,
                        boundary: boundary,
                        history: nil,
                        validationTemporalEvidence: nil
                    ),
                    configuration: input.analyzerConfiguration
                ))
            }
        }
        return results
    }

    private static func analyzeChromaSourceSites(
        _ input: ASHSpatialReferenceInputV2,
        lumaMeasurements: [ASHVideoAnalyzerV2Measurements]
    ) throws -> [ASHVideoAnalyzerV2Measurements] {
        guard lumaMeasurements.count == input.luma.width * input.luma.height else {
            throw ASHSpatialReferencePipelineV2Error.analysisResultCount
        }
        var results: [ASHVideoAnalyzerV2Measurements] = []
        results.reserveCapacity(lumaMeasurements.count)
        let boundary = analyzerBoundary(input.runtimeConfiguration.boundaryMode)
        for row in 0..<input.luma.height {
            for column in 0..<input.luma.width {
                let index = (row * input.luma.width) + column
                if index.isMultiple(of: 4_096) {
                    try Task.checkCancellation()
                }
                let chroma = try ASHVideoAnalyzerV2ChromaInput(
                    cb: input.cb,
                    cr: input.cr,
                    location: input.chromaSiting.sourceChromaLocation(
                        lumaX: column,
                        lumaY: row
                    )
                )
                results.append(ASHVideoAnalyzerV2.analyzeChroma(
                    lumaMeasurements[index],
                    chroma: chroma,
                    boundary: boundary,
                    configuration: input.analyzerConfiguration
                ))
            }
        }
        return results
    }

    private static func packSourceSites(
        _ input: ASHSpatialReferenceInputV2,
        measurements: [ASHVideoAnalyzerV2Measurements]
    ) throws -> [ASHVideoAnalyzerV2Result] {
        guard measurements.count == input.luma.width * input.luma.height else {
            throw ASHSpatialReferencePipelineV2Error.analysisResultCount
        }
        var results: [ASHVideoAnalyzerV2Result] = []
        results.reserveCapacity(measurements.count)
        for (index, measurement) in measurements.enumerated() {
            if index.isMultiple(of: 4_096) {
                try Task.checkCancellation()
            }
            let result = try ASHVideoAnalyzerV2.makeResult(
                measurements: measurement,
                inputRange: input.luma.range,
                history: nil,
                temporalEvidence: nil,
                configuration: input.analyzerConfiguration
            )
            guard result.state.rawValue & ~ASHState.mask == 0,
                  result.state.hasValidIntegrity else {
                throw ASHSpatialReferencePipelineV2Error.invalidAnalyzerState
            }
            results.append(result)
        }
        return results
    }

    private static func makeAnalysisSummary(
        _ analyses: [ASHVideoAnalyzerV2Result]
    ) -> ASHSpatialReferenceMutableSummaryV2 {
        var summary = ASHSpatialReferenceMutableSummaryV2()
        for analysis in analyses {
            summary.stateHistogram[analysis.state.rawValue, default: 0] += 1
            if analysis.state.bit(coordinate: 7) == 1 {
                summary.temporalStateCount += 1
            }
        }
        return summary
    }

    private static func recordAnalysisTelemetry(
        _ analyses: [ASHVideoAnalyzerV2Result],
        telemetry: any ASHTelemetryRecording
    ) {
        var transitionCount = 0
        var invalidParityCount = 0
        var previousState: ASHState?
        var decisions: [String: Int] = [:]
        for analysis in analyses {
            telemetry.recordState(rawValue: analysis.state.rawValue)
            if !analysis.state.hasValidIntegrity {
                invalidParityCount += 1
            }
            if let previousState, previousState != analysis.state {
                transitionCount += 1
            }
            previousState = analysis.state
            let hysteresis = analysis.hysteresis
            for decision in [
                hysteresis.edgePresent,
                hysteresis.coherentStructure,
                hysteresis.textureHighFrequency,
                hysteresis.aliasOrRingingRisk,
                hysteresis.temporalSupportValid,
                hysteresis.chromaLumaStructureAligned
            ] {
                decisions[decision.rawValue, default: 0] += 1
            }
        }

        var details = [
            "analysis_sample_count": String(analyses.count),
            "spatial_state_transition_count": String(transitionCount),
            "invalid_parity_count": String(invalidParityCount),
            "temporal_history_used": "false"
        ]
        for decision in ASHVideoAnalyzerV2HysteresisDecision.allCases {
            details["hysteresis_\(decision.rawValue)"] = String(decisions[decision.rawValue, default: 0])
        }
        telemetry.recordMedia(ASHMediaObservation(kind: "ash_v2_state_analysis", details: details))
    }

    private static func recordDispatchCacheTelemetry(
        analysisCount: Int,
        lumaCount: Int,
        chromaCount: Int,
        telemetry: any ASHTelemetryRecording
    ) {
        telemetry.recordMedia(ASHMediaObservation(
            kind: "ash_v2_dispatch_cache",
            details: [
                "analysis_cell_count": String(analysisCount),
                "luma_dispatch_count": String(lumaCount),
                "chroma_dispatch_count": String(chromaCount),
                "luma_phase_count": String(lumaCount / analysisCount),
                "chroma_phase_count": String(chromaCount / analysisCount)
            ]
        ))
    }

    private static func makeDispatches(
        analyses: [ASHVideoAnalyzerV2Result],
        plane: ASHSpatialPlaneV2,
        route: ASHSpatialRouteV2,
        coordinatePolicy: ASHSpatialCoordinatePolicyV2,
        chromaSiting: ASHChromaSitingV2?,
        stateInputEnabled: Bool,
        telemetry: any ASHTelemetryRecording,
        summary: inout ASHSpatialReferenceMutableSummaryV2
    ) throws -> [ASHSpatialDispatchKeyV2: ASHSpatialDispatchV2] {
        var phases: [ASHSpatialPhaseV2] = []
        var observedPhases = Set<ASHSpatialPhaseV2>()
        let outputWidth = try route.destinationExtent(for: plane.width)
        let outputHeight = try route.destinationExtent(for: plane.height)
        for row in 0..<route.scaleNumerator {
            for column in 0..<route.scaleNumerator {
                let dispatchCoordinates = try coordinates(
                    column: column,
                    row: row,
                    plane: plane,
                    outputWidth: outputWidth,
                    outputHeight: outputHeight,
                    policy: coordinatePolicy
                )
                let sourceCoordinates = try reconstructionCoordinates(
                    dispatchCoordinates: dispatchCoordinates,
                    chromaSiting: chromaSiting,
                    column: column,
                    row: row,
                    plane: plane,
                    outputWidth: outputWidth,
                    outputHeight: outputHeight,
                    policy: coordinatePolicy
                )
                let phase = ASHSpatialPhaseV2(
                    horizontal: ASHSpatialPhaseComponentV2(coordinate: sourceCoordinates.horizontal),
                    vertical: ASHSpatialPhaseComponentV2(coordinate: sourceCoordinates.vertical)
                )
                if observedPhases.insert(phase).inserted {
                    phases.append(phase)
                }
            }
        }
        guard phases.count == route.phasePairCount else {
            throw ASHSpatialReferencePipelineV2Error.invalidPhaseCardinality(
                expected: route.phasePairCount,
                actual: phases.count
            )
        }

        var dispatches: [ASHSpatialDispatchKeyV2: ASHSpatialDispatchV2] = [:]
        dispatches.reserveCapacity(analyses.count * phases.count)
        for (analysisIndex, analysis) in analyses.enumerated() {
            for phase in phases {
                let dispatch = try ASHSpatialDevelopmentSelectorV2.dispatch(
                    state: analysis.state,
                    phase: phase,
                    stateInputEnabled: stateInputEnabled
                )
                dispatches[ASHSpatialDispatchKeyV2(
                    analysisIndex: analysisIndex,
                    phase: phase
                )] = dispatch
                record(dispatch: dispatch, telemetry: telemetry, summary: &summary)
            }
        }
        return dispatches
    }

    // swiftlint:disable:next function_parameter_count
    private static func reconstruct(
        plane: ASHSpatialPlaneV2,
        route: ASHSpatialRouteV2,
        analyses: [ASHVideoAnalyzerV2Result],
        dispatches: [ASHSpatialDispatchKeyV2: ASHSpatialDispatchV2],
        lumaWidth: Int,
        lumaHeight: Int,
        runtimeConfiguration: ASHSpatialRuntimeConfigurationV2,
        operatorParameters: ASHSpatialDevelopmentParametersV2,
        chromaSiting: ASHChromaSitingV2?,
        summary: inout ASHSpatialReferenceMutableSummaryV2
    ) throws -> ASHSpatialReferencePlaneOutputV2 {
        guard analyses.count == lumaWidth * lumaHeight else {
            throw ASHSpatialReferencePipelineV2Error.analysisResultCount
        }
        let outputWidth = try route.destinationExtent(for: plane.width)
        let outputHeight = try route.destinationExtent(for: plane.height)
        var output: [Double] = []
        output.reserveCapacity(outputWidth * outputHeight)

        for row in 0..<outputHeight {
            for column in 0..<outputWidth {
                if output.count.isMultiple(of: 4_096) {
                    try Task.checkCancellation()
                }
                let dispatchCoordinates = try coordinates(
                    column: column,
                    row: row,
                    plane: plane,
                    outputWidth: outputWidth,
                    outputHeight: outputHeight,
                    policy: runtimeConfiguration.coordinatePolicy
                )
                let sourceCoordinates = try reconstructionCoordinates(
                    dispatchCoordinates: dispatchCoordinates,
                    chromaSiting: chromaSiting,
                    column: column,
                    row: row,
                    plane: plane,
                    outputWidth: outputWidth,
                    outputHeight: outputHeight,
                    policy: runtimeConfiguration.coordinatePolicy
                )
                let analysisEntry = analysisEntry(
                    sourceX: sourceCoordinates.horizontal.value,
                    sourceY: sourceCoordinates.vertical.value,
                    planeWidth: plane.width,
                    planeHeight: plane.height,
                    lumaWidth: lumaWidth,
                    lumaHeight: lumaHeight,
                    chromaSiting: chromaSiting,
                    analyses: analyses
                )
                let phase = ASHSpatialPhaseV2(
                    horizontal: ASHSpatialPhaseComponentV2(coordinate: sourceCoordinates.horizontal),
                    vertical: ASHSpatialPhaseComponentV2(coordinate: sourceCoordinates.vertical)
                )
                guard let dispatch = dispatches[ASHSpatialDispatchKeyV2(
                    analysisIndex: analysisEntry.index,
                    phase: phase
                )] else {
                    throw ASHSpatialReferencePipelineV2Error.missingDispatch
                }
                let value = try evaluateDispatch(
                    dispatch,
                    plane: plane,
                    column: column,
                    row: row,
                    route: route,
                    analysis: analysisEntry.result,
                    runtimeConfiguration: runtimeConfiguration,
                    operatorParameters: operatorParameters,
                    coordinateOverride: sourceCoordinates,
                    summary: &summary
                )
                output.append(value)
            }
        }
        return ASHSpatialReferencePlaneOutputV2(
            width: outputWidth,
            height: outputHeight,
            normalizedSamples: output
        )
    }

    private static func coordinates(
        column: Int,
        row: Int,
        plane: ASHSpatialPlaneV2,
        outputWidth: Int,
        outputHeight: Int,
        policy: ASHSpatialCoordinatePolicyV2
    ) throws -> ASHSpatialSourceCoordinatesV2 {
        ASHSpatialSourceCoordinatesV2(
            horizontal: try ASHSpatialOperatorBankV2.coordinate(
                destinationIndex: column,
                sourceExtent: plane.width,
                destinationExtent: outputWidth,
                policy: policy
            ),
            vertical: try ASHSpatialOperatorBankV2.coordinate(
                destinationIndex: row,
                sourceExtent: plane.height,
                destinationExtent: outputHeight,
                policy: policy
            )
        )
    }

    private static func reconstructionCoordinates(
        dispatchCoordinates: ASHSpatialSourceCoordinatesV2,
        chromaSiting: ASHChromaSitingV2?,
        column: Int,
        row: Int,
        plane: ASHSpatialPlaneV2,
        outputWidth: Int,
        outputHeight: Int,
        policy: ASHSpatialCoordinatePolicyV2
    ) throws -> ASHSpatialSourceCoordinatesV2 {
        guard let chromaSiting else { return dispatchCoordinates }
        return ASHSpatialSourceCoordinatesV2(
            horizontal: try chromaSiting.sourceCoordinate(
                destinationIndex: column,
                sourceExtent: plane.width,
                destinationExtent: outputWidth,
                policy: policy,
                axis: .horizontal
            ),
            vertical: try chromaSiting.sourceCoordinate(
                destinationIndex: row,
                sourceExtent: plane.height,
                destinationExtent: outputHeight,
                policy: policy,
                axis: .vertical
            )
        )
    }

    private static func analysisEntry(
        sourceX: Double,
        sourceY: Double,
        planeWidth: Int,
        planeHeight: Int,
        lumaWidth: Int,
        lumaHeight: Int,
        chromaSiting: ASHChromaSitingV2?,
        analyses: [ASHVideoAnalyzerV2Result]
    ) -> (index: Int, result: ASHVideoAnalyzerV2Result) {
        let lumaX: Double
        let lumaY: Double
        if let chromaSiting {
            lumaX = (2.0 * sourceX) + (Double(chromaSiting.horizontalLumaOffsetNumerator) / 2.0)
            lumaY = (2.0 * sourceY) + (Double(chromaSiting.verticalLumaOffsetNumerator) / 2.0)
        } else {
            lumaX = sourceX * Double(lumaWidth) / Double(planeWidth)
            lumaY = sourceY * Double(lumaHeight) / Double(planeHeight)
        }
        let column = min(lumaWidth - 1, max(0, Int(lumaX.rounded())))
        let row = min(lumaHeight - 1, max(0, Int(lumaY.rounded())))
        let index = (row * lumaWidth) + column
        return (index, analyses[index])
    }

    // swiftlint:disable:next function_parameter_count
    private static func evaluateDispatch(
        _ dispatch: ASHSpatialDispatchV2,
        plane: ASHSpatialPlaneV2,
        column: Int,
        row: Int,
        route: ASHSpatialRouteV2,
        analysis: ASHVideoAnalyzerV2Result,
        runtimeConfiguration: ASHSpatialRuntimeConfigurationV2,
        operatorParameters: ASHSpatialDevelopmentParametersV2,
        coordinateOverride: ASHSpatialSourceCoordinatesV2,
        summary: inout ASHSpatialReferenceMutableSummaryV2
    ) throws -> Double {
        let sidecar = try spatialSidecar(analysis.sidecar)
        let primary = try evaluateDescriptor(
            dispatch.primaryDecodedMessage.rawValue,
            plane: plane,
            column: column,
            row: row,
            route: route,
            sidecar: sidecar,
            runtimeConfiguration: runtimeConfiguration,
            operatorParameters: operatorParameters,
            coordinateOverride: coordinateOverride,
            summary: &summary
        )
        guard let secondaryMessage = dispatch.secondaryDecodedMessage else { return primary.value }
        let secondary = try evaluateDescriptor(
            secondaryMessage.rawValue,
            plane: plane,
            column: column,
            row: row,
            route: route,
            sidecar: sidecar,
            runtimeConfiguration: runtimeConfiguration,
            operatorParameters: operatorParameters,
            coordinateOverride: coordinateOverride,
            summary: &summary
        )
        return plane.legalClamp(
            (dispatch.primaryWeight * primary.value)
                + (dispatch.secondaryWeight * secondary.value)
        )
    }

    // swiftlint:disable:next function_parameter_count
    private static func evaluateDescriptor(
        _ descriptorID: UInt8,
        plane: ASHSpatialPlaneV2,
        column: Int,
        row: Int,
        route: ASHSpatialRouteV2,
        sidecar: ASHSpatialSidecarV2,
        runtimeConfiguration: ASHSpatialRuntimeConfigurationV2,
        operatorParameters: ASHSpatialDevelopmentParametersV2,
        coordinateOverride: ASHSpatialSourceCoordinatesV2,
        summary: inout ASHSpatialReferenceMutableSummaryV2
    ) throws -> ASHSpatialSampleResultV2 {
        let sampleRequest = try request(
            descriptorID: descriptorID,
            plane: plane,
            column: column,
            row: row,
            route: route,
            sidecar: sidecar,
            runtimeConfiguration: runtimeConfiguration,
            operatorParameters: operatorParameters,
            coordinateOverride: coordinateOverride
        )
        do {
            let result = try ASHSpatialOperatorBankV2.evaluateSample(sampleRequest)
            if result.sourceAlignedSamplePreserved {
                summary.sourceAlignedPreservationCount += 1
            }
            return result
        } catch let error as ASHSpatialOperatorErrorV2 {
            guard descriptorID != 0,
                  ASHSpatialOperatorBankV2.conservativeFallback(for: error) != nil else {
                throw error
            }
            summary.numericalFallbackCount += 1
            let fallback = try request(
                descriptorID: 0,
                plane: plane,
                column: column,
                row: row,
                route: route,
                sidecar: sidecar,
                runtimeConfiguration: runtimeConfiguration,
                operatorParameters: operatorParameters,
                coordinateOverride: coordinateOverride
            )
            do {
                return try ASHSpatialOperatorBankV2.evaluateSample(fallback)
            } catch {
                throw ASHSpatialReferencePipelineV2Error.numericalFallbackFailed
            }
        }
    }

    // The reference request mirrors every independently audited operator input.
    // swiftlint:disable:next function_parameter_count
    private static func request(
        descriptorID: UInt8,
        plane: ASHSpatialPlaneV2,
        column: Int,
        row: Int,
        route: ASHSpatialRouteV2,
        sidecar: ASHSpatialSidecarV2,
        runtimeConfiguration: ASHSpatialRuntimeConfigurationV2,
        operatorParameters: ASHSpatialDevelopmentParametersV2,
        coordinateOverride: ASHSpatialSourceCoordinatesV2
    ) throws -> ASHSpatialSampleRequestV2 {
        ASHSpatialSampleRequestV2(
            plane: plane,
            destinationColumn: column,
            destinationRow: row,
            route: route,
            coordinatePolicy: runtimeConfiguration.coordinatePolicy,
            descriptor: try ASHSpatialDescriptorV2(id: descriptorID),
            sidecar: sidecar,
            boundary: runtimeConfiguration.boundaryMode,
            parameters: operatorParameters,
            coordinateOverride: coordinateOverride
        )
    }

    private static func spatialSidecar(
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

    private static func record(
        dispatch: ASHSpatialDispatchV2,
        telemetry: any ASHTelemetryRecording,
        summary: inout ASHSpatialReferenceMutableSummaryV2
    ) {
        summary.operatorHistogram[dispatch.primaryDecodedMessage.rawValue, default: 0] += 1
        summary.maxOperatorEvaluations = max(
            summary.maxOperatorEvaluations,
            dispatch.operatorEvaluationCount
        )
        if dispatch.parityWasRecomputed {
            summary.parityRecomputationCount += 1
        }
        telemetry.recordMessage(dispatch.primaryDecodedMessage.rawValue)
        telemetry.recordOperator(dispatch.primaryDecodedMessage.rawValue)
        telemetry.recordDecode(.exact)
        telemetry.recordCandidateCount(dispatch.operatorEvaluationCount)
    }

    private static func analyzerBoundary(
        _ boundary: ASHSpatialBoundaryModeV2
    ) -> ASHVideoAnalyzerV2BoundaryRule {
        switch boundary {
        case .clamp:
            return .clamp
        case .mirrorReflect101:
            return .reflect101
        }
    }

    private static func unit(_ value: Double) -> Double {
        min(1.0, max(0.0, value))
    }
}

// swiftlint:enable file_length type_body_length
