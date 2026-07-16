import Foundation

extension ASHLockedReferencePipelineV2 {
    static func measureDispatchProjection(
        _ input: ASHLockedReferenceInputV2,
        warmupRepetitionCount: Int = 3,
        repetitionCount: Int = 10,
        telemetry: any ASHTelemetryRecording = ASHNoopTelemetryRecorder.shared
    ) throws -> ASHLockedDispatchProjectionMeasurementV2 {
        guard warmupRepetitionCount == 3, repetitionCount == 10 else {
            throw ASHLockedReferencePipelineV2Error.invalidMeasurementPolicy
        }
        try validate(input)
        guard input.lut.configuration == input.configuration else {
            throw ASHLockedRuntimeV2Error.configurationMismatch
        }
        let selection = input.configuration.routeSelection(for: input.lut.route)
        let lumaPlane = try makePlane(input.luma, channel: .luma)
        let cbPlane = try makePlane(input.cb, channel: .chroma)
        let crPlane = try makePlane(input.cr, channel: .chroma)
        var records: [ASHLockedDispatchProjectionRepetitionV2] = []
        var lastFull: ASHLockedReferenceOutputV2?
        var lastControl: ASHLockedReferenceOutputV2?
        for iteration in 0..<(warmupRepetitionCount + repetitionCount) {
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
            let dispatchGrid = try ASHLockedRuntimeV2.makeDispatchGrid(
                lut: input.lut,
                configuration: input.configuration,
                analysisGrid: analysisGrid,
                context: .spatialOnly,
                telemetry: telemetry
            )
            let dispatchElapsed = dispatchStart.duration(to: .now)
            let measuredIndex = iteration - warmupRepetitionCount
            let order: ASHLockedDispatchProjectionOrderV2 = measuredIndex.isMultiple(of: 2) ? .fullThenControl : .controlThenFull
            let firstIsFull = iteration < warmupRepetitionCount || order == .fullThenControl
            let first = try reconstructForMeasurement(
                lumaPlane: lumaPlane,
                cbPlane: cbPlane,
                crPlane: crPlane,
                dispatchGrid: dispatchGrid,
                configuration: input.configuration,
                analysisGrid: analysisGrid,
                chromaSiting: input.chromaSiting
            )
            let second = try reconstructForMeasurement(
                lumaPlane: lumaPlane,
                cbPlane: cbPlane,
                crPlane: crPlane,
                dispatchGrid: dispatchGrid,
                configuration: input.configuration,
                analysisGrid: analysisGrid,
                chromaSiting: input.chromaSiting
            )
            let full = firstIsFull ? first : second
            let control = firstIsFull ? second : first
            guard full.luma.output == control.luma.output, full.cb.output == control.cb.output,
                  full.cr.output == control.cr.output else {
                throw ASHLockedReferencePipelineV2Error.dispatchProjectionOutputMismatch
            }
            let fullOutput = measurementOutput(
                input: input,
                analysisGrid: analysisGrid,
                dispatchGrid: dispatchGrid,
                reconstruction: full,
                analysisElapsed: analysisElapsed,
                dispatchElapsed: dispatchElapsed
            )
            let controlOutput = measurementOutput(
                input: input,
                analysisGrid: analysisGrid,
                dispatchGrid: dispatchGrid,
                reconstruction: control,
                analysisElapsed: .zero,
                dispatchElapsed: .zero
            )
            lastFull = fullOutput
            lastControl = controlOutput
            if measuredIndex >= 0 {
                records.append(ASHLockedDispatchProjectionRepetitionV2(
                    index: measuredIndex, order: order,
                    fullAnalysisMilliseconds: milliseconds(analysisElapsed),
                    fullDispatchMilliseconds: milliseconds(dispatchElapsed),
                    fullReconstructionMilliseconds: milliseconds(full.elapsed),
                    controlReconstructionMilliseconds: milliseconds(control.elapsed)
                ))
            }
        }
        guard let lastFull, let lastControl, records.count == repetitionCount else {
            throw ASHLockedReferencePipelineV2Error.invalidMeasurementPolicy
        }
        return ASHLockedDispatchProjectionMeasurementV2(
            measurementDomain: "native_cpu_reference_projection_not_metal",
            warmupRepetitionCount: warmupRepetitionCount,
            fullOutput: lastFull,
            controlOutput: lastControl,
            repetitions: records
        )
    }
}
