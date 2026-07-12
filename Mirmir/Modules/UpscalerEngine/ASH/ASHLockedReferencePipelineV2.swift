import Foundation

enum ASHLockedReferencePipelineV2 {
    static func process(
        _ input: ASHLockedReferenceInputV2,
        telemetry: any ASHTelemetryRecording = ASHNoopTelemetryRecorder.shared
    ) throws -> ASHLockedReferenceOutputV2 {
        try validate(input)
        guard input.lut.configuration == input.configuration else {
            throw ASHLockedRuntimeV2Error.configurationMismatch
        }
        let routeSelection = input.configuration.routeSelection(for: input.lut.route)

        let analysisStart = ContinuousClock.now
        let analysisGrid = try ASHAnalysisGridBuilderV2.build(
            luma: input.luma,
            cb: input.cb,
            cr: input.cr,
            chromaSiting: input.chromaSiting,
            step: Int(routeSelection.analysisGridSourceStep),
            boundary: input.configuration.boundaryMode,
            configuration: input.mapping.analyzerConfiguration
        )
        let analysisElapsed = analysisStart.duration(to: .now)

        let dispatchStart = ContinuousClock.now
        let dispatchGrid = try ASHLockedRuntimeV2.makeDispatchGrid(
            lut: input.lut,
            configuration: input.configuration,
            analysisGrid: analysisGrid,
            context: .spatialOnly,
            telemetry: telemetry
        )
        let dispatchElapsed = dispatchStart.duration(to: .now)

        let lumaPlane = try makePlane(input.luma, channel: .luma)
        let cbPlane = try makePlane(input.cb, channel: .chroma)
        let crPlane = try makePlane(input.cr, channel: .chroma)
        let reconstructionStart = ContinuousClock.now
        let luma = try reconstruct(
            plane: lumaPlane,
            dispatchGrid: dispatchGrid,
            configuration: input.configuration,
            analysisGrid: analysisGrid,
            chromaSiting: nil
        )
        let cb = try reconstruct(
            plane: cbPlane,
            dispatchGrid: dispatchGrid,
            configuration: input.configuration,
            analysisGrid: analysisGrid,
            chromaSiting: input.chromaSiting
        )
        let cr = try reconstruct(
            plane: crPlane,
            dispatchGrid: dispatchGrid,
            configuration: input.configuration,
            analysisGrid: analysisGrid,
            chromaSiting: input.chromaSiting
        )
        let reconstructionElapsed = reconstructionStart.duration(to: .now)
        return ASHLockedReferenceOutputV2(
            luma: luma.output,
            cb: cb.output,
            cr: cr.output,
            summary: makeSummary(
                input: input,
                analysisGrid: analysisGrid,
                dispatchGrid: dispatchGrid,
                luma: luma,
                cb: cb,
                cr: cr,
                timings: Timings(
                    analysis: analysisElapsed,
                    dispatch: dispatchElapsed,
                    reconstruction: reconstructionElapsed
                )
            )
        )
    }

    static func processControlDispatch(
        _ input: ASHLockedReferenceInputV2,
        mode: ASHLockedDispatchControlModeV2
    ) throws -> ASHLockedReferenceOutputV2 {
        try validate(input)
        guard input.lut.configuration == input.configuration else {
            throw ASHLockedRuntimeV2Error.configurationMismatch
        }
        let selection = input.configuration.routeSelection(for: input.lut.route)
        let analysisStart = ContinuousClock.now
        let analysisGrid = try ASHAnalysisGridBuilderV2.build(
            luma: input.luma,
            cb: input.cb,
            cr: input.cr,
            chromaSiting: input.chromaSiting,
            step: Int(selection.analysisGridSourceStep),
            boundary: input.configuration.boundaryMode,
            configuration: input.mapping.analyzerConfiguration
        )
        let analysisElapsed = analysisStart.duration(to: .now)
        let dispatchStart = ContinuousClock.now
        let dispatchGrid = try ASHLockedControlRuntimeV2.makeDispatchGrid(
            lut: input.lut,
            configuration: input.configuration,
            analysisGrid: analysisGrid,
            mode: mode
        )
        let dispatchElapsed = dispatchStart.duration(to: .now)
        let lumaPlane = try makePlane(input.luma, channel: .luma)
        let cbPlane = try makePlane(input.cb, channel: .chroma)
        let crPlane = try makePlane(input.cr, channel: .chroma)
        let reconstructionStart = ContinuousClock.now
        let luma = try reconstruct(
            plane: lumaPlane,
            dispatchGrid: dispatchGrid,
            configuration: input.configuration,
            analysisGrid: analysisGrid,
            chromaSiting: nil
        )
        let cb = try reconstruct(
            plane: cbPlane,
            dispatchGrid: dispatchGrid,
            configuration: input.configuration,
            analysisGrid: analysisGrid,
            chromaSiting: input.chromaSiting
        )
        let cr = try reconstruct(
            plane: crPlane,
            dispatchGrid: dispatchGrid,
            configuration: input.configuration,
            analysisGrid: analysisGrid,
            chromaSiting: input.chromaSiting
        )
        let reconstructionElapsed = reconstructionStart.duration(to: .now)
        return ASHLockedReferenceOutputV2(
            luma: luma.output,
            cb: cb.output,
            cr: cr.output,
            summary: makeSummary(
                input: input,
                analysisGrid: analysisGrid,
                dispatchGrid: dispatchGrid,
                luma: luma,
                cb: cb,
                cr: cr,
                timings: Timings(
                    analysis: analysisElapsed,
                    dispatch: dispatchElapsed,
                    reconstruction: reconstructionElapsed
                )
            )
        )
    }
}

extension ASHLockedReferencePipelineV2 {
    enum Channel {
        case luma
        case chroma
    }

    struct ReconstructionSummary {
        let output: ASHLockedReferencePlaneOutputV2
        let numericalFallbacks: Int
        let sourcePreservations: Int
    }

    private struct DispatchSummary {
        var operatorHistogram: [UInt8: Int] = [:]
        var exact = 0
        var corrected = 0
        var rejected = 0
        var parityRepairs = 0
        var affineFallbacks = 0
        var sourceAlignedEntries = 0
        var maximumCandidates = 0
    }

    private struct Timings {
        let analysis: Duration
        let dispatch: Duration
        let reconstruction: Duration
    }

    struct MeasurementReconstruction {
        let luma: ReconstructionSummary
        let cb: ReconstructionSummary
        let cr: ReconstructionSummary
        let elapsed: Duration
    }

    static func reconstructForMeasurement(
        lumaPlane: ASHSpatialPlaneV2,
        cbPlane: ASHSpatialPlaneV2,
        crPlane: ASHSpatialPlaneV2,
        dispatchGrid: ASHLockedDispatchGridV2,
        configuration: ASHLUTLockedConfigurationV2,
        analysisGrid: ASHAnalysisGridV2,
        chromaSiting: ASHChromaSitingV2
    ) throws -> MeasurementReconstruction {
        let start = ContinuousClock.now
        let luma = try reconstruct(
            plane: lumaPlane,
            dispatchGrid: dispatchGrid,
            configuration: configuration,
            analysisGrid: analysisGrid,
            chromaSiting: nil
        )
        let cb = try reconstruct(
            plane: cbPlane,
            dispatchGrid: dispatchGrid,
            configuration: configuration,
            analysisGrid: analysisGrid,
            chromaSiting: chromaSiting
        )
        let cr = try reconstruct(
            plane: crPlane,
            dispatchGrid: dispatchGrid,
            configuration: configuration,
            analysisGrid: analysisGrid,
            chromaSiting: chromaSiting
        )
        return MeasurementReconstruction(
            luma: luma,
            cb: cb,
            cr: cr,
            elapsed: start.duration(to: .now)
        )
    }

    static func measurementOutput(
        input: ASHLockedReferenceInputV2,
        analysisGrid: ASHAnalysisGridV2,
        dispatchGrid: ASHLockedDispatchGridV2,
        reconstruction: MeasurementReconstruction,
        analysisElapsed: Duration,
        dispatchElapsed: Duration
    ) -> ASHLockedReferenceOutputV2 {
        ASHLockedReferenceOutputV2(
            luma: reconstruction.luma.output,
            cb: reconstruction.cb.output,
            cr: reconstruction.cr.output,
            summary: makeSummary(
                input: input,
                analysisGrid: analysisGrid,
                dispatchGrid: dispatchGrid,
                luma: reconstruction.luma,
                cb: reconstruction.cb,
                cr: reconstruction.cr,
                timings: Timings(
                    analysis: analysisElapsed,
                    dispatch: dispatchElapsed,
                    reconstruction: reconstruction.elapsed
                )
            )
        )
    }

    private static func makeSummary(
        input: ASHLockedReferenceInputV2,
        analysisGrid: ASHAnalysisGridV2,
        dispatchGrid: ASHLockedDispatchGridV2,
        luma: ReconstructionSummary,
        cb: ReconstructionSummary,
        cr: ReconstructionSummary,
        timings: Timings
    ) -> ASHLockedReferenceSummaryV2 {
        let dispatch = summarize(dispatchGrid)
        let stateHistogram = Dictionary(grouping: analysisGrid.cells, by: { $0.analysis.state.rawValue })
            .mapValues(\.count)
        let configuration = input.configuration
        return ASHLockedReferenceSummaryV2(
            route: input.lut.route,
            coordinatePolicy: configuration.routeSelection(for: input.lut.route).coordinatePolicy,
            boundaryMode: configuration.boundaryMode,
            analysisGridSourceStep: analysisGrid.step,
            analysisCellCount: analysisGrid.count,
            dispatchRecordCount: dispatchGrid.dispatches.count,
            stateHistogram: stateHistogram,
            operatorHistogram: dispatch.operatorHistogram,
            exactDecodeCount: dispatch.exact,
            correctedDecodeCount: dispatch.corrected,
            rejectedDecodeCount: dispatch.rejected,
            parityRecomputationCount: dispatch.parityRepairs,
            affineFallbackCount: dispatch.affineFallbacks,
            numericalFallbackCount: luma.numericalFallbacks + cb.numericalFallbacks + cr.numericalFallbacks,
            sourceAlignedEntryDispatchCount: dispatch.sourceAlignedEntries,
            sourceAlignedSamplePreservationCount: luma.sourcePreservations
                + cb.sourcePreservations
                + cr.sourcePreservations,
            maximumOperatorEvaluations: dispatch.maximumCandidates,
            runtimeTreeGenerationCount: dispatchGrid.counters.runtimeTreeGenerationCount,
            runtimePathAllocationCount: dispatchGrid.counters.runtimePathAllocationCount,
            cpuReferenceAnalysisTraversalCount: 1,
            cpuReferenceFullFrameLoopCount: 3,
            productionMetalConstraintEvaluated: false,
            loadedLUTInstanceCount: 1,
            perFrameLUTLoadCount: 0,
            configurationID: configuration.configurationID,
            mappingSHA256: configuration.mappingSHA256,
            operatorBankSHA256: configuration.operatorBankSHA256,
            metricPolicySHA256: configuration.metricPolicySHA256,
            compilerInputsSHA256: configuration.compilerInputsSHA256,
            calibrationPlanSHA256: configuration.calibrationPlanSHA256,
            corpusLockBundleSHA256: configuration.corpusLockBundleSHA256,
            chromaOutputConvention: .normalizedZeroToOne,
            analysisElapsedMilliseconds: milliseconds(timings.analysis),
            dispatchElapsedMilliseconds: milliseconds(timings.dispatch),
            reconstructionElapsedMilliseconds: milliseconds(timings.reconstruction),
            lutPayloadSHA256: input.lut.payloadSHA256,
            lutWholeFileSHA256: input.lut.wholeFileSHA256
        )
    }

    static func validate(_ input: ASHLockedReferenceInputV2) throws {
        guard input.mapping.sha256 == input.configuration.mappingSHA256 else {
            throw ASHLockedReferencePipelineV2Error.mappingHashMismatch
        }
        do {
            try input.mapping.validate(configuration: input.configuration)
        } catch {
            throw ASHLockedReferencePipelineV2Error.mappingConfigurationMismatch
        }
        guard input.chromaSiting == input.mapping.chromaSiting else {
            throw ASHLockedReferencePipelineV2Error.chromaSitingMismatch
        }
        guard input.cb.width == input.cr.width,
              input.cb.height == input.cr.height else {
            throw ASHLockedReferencePipelineV2Error.mismatchedChromaGeometry
        }
        guard input.luma.range == input.cb.range,
              input.cb.range == input.cr.range else {
            throw ASHLockedReferencePipelineV2Error.mismatchedPlaneRange
        }
        guard input.luma.width == input.cb.width * 2,
              input.luma.height == input.cb.height * 2 else {
            throw ASHLockedReferencePipelineV2Error.unsupportedChromaSubsampling
        }
        _ = try input.lut.route.destinationExtent(for: input.luma.width)
        _ = try input.lut.route.destinationExtent(for: input.luma.height)
        _ = try input.lut.route.destinationExtent(for: input.cb.width)
        _ = try input.lut.route.destinationExtent(for: input.cb.height)
    }

    static func makePlane(
        _ source: ASHVideoAnalyzerV2CodePlane,
        channel: Channel
    ) throws -> ASHSpatialPlaneV2 {
        var samples: [Double] = []
        samples.reserveCapacity(source.width * source.height)
        for row in 0..<source.height {
            let rowOffset = row * source.bytesPerRow
            for column in 0..<source.width {
                let code = source.codes[rowOffset + column]
                let value: Double
                switch channel {
                case .luma: value = source.range.normalizeLuma(code)
                case .chroma: value = source.range.normalizeChroma(code) + 0.5
                }
                samples.append(unit(value))
            }
        }
        return try ASHSpatialPlaneV2(
            width: source.width,
            height: source.height,
            samples: samples,
            legalRange: 0.0...1.0
        )
    }

    static func reconstruct(
        plane: ASHSpatialPlaneV2,
        dispatchGrid: ASHLockedDispatchGridV2,
        configuration: ASHLUTLockedConfigurationV2,
        analysisGrid: ASHAnalysisGridV2,
        chromaSiting: ASHChromaSitingV2?
    ) throws -> ReconstructionSummary {
        let outputWidth = try dispatchGrid.route.destinationExtent(for: plane.width)
        let outputHeight = try dispatchGrid.route.destinationExtent(for: plane.height)
        var samples: [Double] = []
        samples.reserveCapacity(outputWidth * outputHeight)
        var numericalFallbacks = 0
        var sourcePreservations = 0
        for row in 0..<outputHeight {
            for column in 0..<outputWidth {
                if samples.count.isMultiple(of: 4_096) {
                    try Task.checkCancellation()
                }
                let result = try ASHLockedRuntimeV2.evaluateSample(
                    dispatchGrid: dispatchGrid,
                    configuration: configuration,
                    analysisGrid: analysisGrid,
                    plane: plane,
                    destinationColumn: column,
                    destinationRow: row,
                    chromaSiting: chromaSiting
                )
                samples.append(result.value)
                if result.numericalFallbackUsed { numericalFallbacks += 1 }
                if result.sourceAlignedSamplePreserved { sourcePreservations += 1 }
            }
        }
        return ReconstructionSummary(
            output: ASHLockedReferencePlaneOutputV2(
                width: outputWidth,
                height: outputHeight,
                normalizedSamples: samples
            ),
            numericalFallbacks: numericalFallbacks,
            sourcePreservations: sourcePreservations
        )
    }

    private static func summarize(_ grid: ASHLockedDispatchGridV2) -> DispatchSummary {
        var summary = DispatchSummary()
        for dispatch in grid.dispatches {
            summary.maximumCandidates = max(summary.maximumCandidates, dispatch.operatorEvaluationCount)
            if dispatch.parityWasRecomputed { summary.parityRepairs += 1 }
            if dispatch.affineFallbackUsed { summary.affineFallbacks += 1 }
            if dispatch.sourceAlignedEntryFlag { summary.sourceAlignedEntries += 1 }
            record(dispatch.primary, fallback: dispatch.affineFallbackUsed, into: &summary)
            if let secondary = dispatch.secondary {
                record(secondary, fallback: false, into: &summary)
            }
        }
        return summary
    }

    private static func record(
        _ candidate: ASHLockedRuntimeCandidateV2,
        fallback: Bool,
        into summary: inout DispatchSummary
    ) {
        summary.operatorHistogram[candidate.descriptor.id, default: 0] += 1
        if fallback {
            summary.rejected += 1
            return
        }
        switch candidate.affineDecode.status {
        case .exact: summary.exact += 1
        case .corrected: summary.corrected += 1
        case .uncorrectable: summary.rejected += 1
        }
    }

    static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return (Double(components.seconds) * 1_000.0)
            + (Double(components.attoseconds) / 1_000_000_000_000_000.0)
    }

    private static func unit(_ value: Double) -> Double {
        min(1.0, max(0.0, value))
    }
}
