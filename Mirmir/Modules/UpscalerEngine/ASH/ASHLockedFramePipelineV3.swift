import Foundation

enum ASHLockedFramePipelineErrorV3: Error, Equatable, Sendable {
    case configurationMismatch
    case invalidSourceGeometry
    case invalidDestinationGeometry
    case codeRangeMismatch
    case chromaSitingMismatch
    case invalidOutputSample
    case operatorEvaluationLimitExceeded
}

struct ASHLockedFramePipelineInputV3: Sendable {
    let source: ASHNV12CodeFrame
    let destinationGeometry: ASHNV12FrameGeometry
    let destinationRange: ASHVideoCodeRange8Bit
    let expectedRange: ASHVideoCodeRange8Bit
    let expectedChromaSiting: ASHChromaSitingV2
    let lut: ASHLUTLoadedV3
    let configuration: ASHLUTLockedConfigurationV3
    let analyzerConfiguration: ASHVideoAnalyzerV2DevelopmentConfiguration
}

struct ASHLockedFrameSummaryV3: Equatable, Sendable {
    let route: ASHSpatialRouteV2
    let constructionCounters: ASHLockedRuntimeConstructionCountersV3
    let reconstructedLumaSampleCount: Int
    let reconstructedChromaSampleCount: Int
    let primaryEvaluationCount: Int
    let secondaryEvaluationCount: Int
    let maximumOperatorEvaluations: Int
    let affineFallbackCount: Int
    let numericalFallbackCount: Int
    let parityRecomputationCount: Int
    let sourceAlignedPreservationCount: Int
    let temporalStateCount: Int
}

struct ASHLockedFrameOutputV3: Equatable, Sendable {
    let luma: ASHSpatialReferencePlaneOutputV2
    let cb: ASHSpatialReferencePlaneOutputV2
    let cr: ASHSpatialReferencePlaneOutputV2
    let summary: ASHLockedFrameSummaryV3
}

private struct ASHLockedFrameMutableSummaryV3 {
    var primaryEvaluationCount = 0
    var secondaryEvaluationCount = 0
    var maximumOperatorEvaluations = 0
    var affineFallbackCount = 0
    var numericalFallbackCount = 0
    var parityRecomputationCount = 0
    var sourceAlignedPreservationCount = 0

    mutating func record(_ result: ASHLockedRuntimeSampleResultV3) throws {
        let count = result.dispatch.operatorEvaluationCount
        guard (1...2).contains(count) else {
            throw ASHLockedFramePipelineErrorV3.operatorEvaluationLimitExceeded
        }
        guard result.value.isFinite, (0.0...1.0).contains(result.value) else {
            throw ASHLockedFramePipelineErrorV3.invalidOutputSample
        }
        primaryEvaluationCount += 1
        secondaryEvaluationCount += result.secondaryResult == nil ? 0 : 1
        maximumOperatorEvaluations = max(maximumOperatorEvaluations, count)
        affineFallbackCount += result.dispatch.affineFallbackUsed ? 1 : 0
        numericalFallbackCount += result.numericalFallbackUsed ? 1 : 0
        parityRecomputationCount += result.dispatch.parityWasRecomputed ? 1 : 0
        sourceAlignedPreservationCount += result.sourceAlignedSamplePreserved ? 1 : 0
    }
}

enum ASHLockedFramePipelineV3 {
    static func process(
        _ input: ASHLockedFramePipelineInputV3,
        telemetry: any ASHTelemetryRecording = ASHNoopTelemetryRecorder.shared
    ) throws -> ASHLockedFrameOutputV3 {
        try validate(input)
        try Task.checkCancellation()
        let lumaPlane = try ASHNV12FrameCodec.normalizedPlane(
            input.source.luma,
            channel: .luma
        )
        let cbPlane = try ASHNV12FrameCodec.normalizedPlane(
            input.source.cb,
            channel: .chroma
        )
        let crPlane = try ASHNV12FrameCodec.normalizedPlane(
            input.source.cr,
            channel: .chroma
        )
        let frame = try ASHLockedRuntimeV3.prepareFrame(
            lut: input.lut,
            configuration: input.configuration,
            luma: input.source.luma,
            cb: input.source.cb,
            cr: input.source.cr,
            chromaSiting: input.source.chromaSiting,
            analyzerConfiguration: input.analyzerConfiguration,
            telemetry: telemetry
        )
        var summary = ASHLockedFrameMutableSummaryV3()
        let luma = try reconstruct(
            frame: frame,
            runtimePlane: .luma,
            plane: lumaPlane,
            chromaSiting: nil,
            summary: &summary
        )
        try Task.checkCancellation()
        let cb = try reconstruct(
            frame: frame,
            runtimePlane: .cb,
            plane: cbPlane,
            chromaSiting: input.source.chromaSiting,
            summary: &summary
        )
        try Task.checkCancellation()
        let cr = try reconstruct(
            frame: frame,
            runtimePlane: .cr,
            plane: crPlane,
            chromaSiting: input.source.chromaSiting,
            summary: &summary
        )
        return ASHLockedFrameOutputV3(
            luma: luma,
            cb: cb,
            cr: cr,
            summary: ASHLockedFrameSummaryV3(
                route: input.lut.route,
                constructionCounters: frame.constructionCounters,
                reconstructedLumaSampleCount: luma.normalizedSamples.count,
                reconstructedChromaSampleCount: cb.normalizedSamples.count
                    + cr.normalizedSamples.count,
                primaryEvaluationCount: summary.primaryEvaluationCount,
                secondaryEvaluationCount: summary.secondaryEvaluationCount,
                maximumOperatorEvaluations: summary.maximumOperatorEvaluations,
                affineFallbackCount: summary.affineFallbackCount,
                numericalFallbackCount: summary.numericalFallbackCount,
                parityRecomputationCount: summary.parityRecomputationCount,
                sourceAlignedPreservationCount: summary.sourceAlignedPreservationCount,
                temporalStateCount: 0
            )
        )
    }

    private static func validate(_ input: ASHLockedFramePipelineInputV3) throws {
        let source = input.source
        guard input.lut.configuration == input.configuration else {
            throw ASHLockedFramePipelineErrorV3.configurationMismatch
        }
        guard source.luma.width == source.cb.width * 2,
              source.luma.height == source.cb.height * 2,
              source.cb.width == source.cr.width,
              source.cb.height == source.cr.height else {
            throw ASHLockedFramePipelineErrorV3.invalidSourceGeometry
        }
        guard source.luma.range == input.expectedRange,
              source.cb.range == input.expectedRange,
              source.cr.range == input.expectedRange,
              input.destinationRange == input.expectedRange else {
            throw ASHLockedFramePipelineErrorV3.codeRangeMismatch
        }
        guard source.chromaSiting == input.expectedChromaSiting else {
            throw ASHLockedFramePipelineErrorV3.chromaSitingMismatch
        }
        let route = input.lut.route
        guard input.destinationGeometry == ASHNV12FrameGeometry(
            lumaWidth: try route.destinationExtent(for: source.luma.width),
            lumaHeight: try route.destinationExtent(for: source.luma.height),
            chromaWidth: try route.destinationExtent(for: source.cb.width),
            chromaHeight: try route.destinationExtent(for: source.cb.height)
        ) else {
            throw ASHLockedFramePipelineErrorV3.invalidDestinationGeometry
        }
    }

    private static func reconstruct(
        frame: ASHLockedFrameRuntimeV3,
        runtimePlane: ASHRuntimePlaneV3,
        plane: ASHSpatialPlaneV2,
        chromaSiting: ASHChromaSitingV2?,
        summary: inout ASHLockedFrameMutableSummaryV3
    ) throws -> ASHSpatialReferencePlaneOutputV2 {
        let width = try frame.dispatchGrids.luma.route.destinationExtent(for: plane.width)
        let height = try frame.dispatchGrids.luma.route.destinationExtent(for: plane.height)
        var samples: [Double] = []
        samples.reserveCapacity(width * height)
        for row in 0..<height {
            for column in 0..<width {
                if samples.count.isMultiple(of: 4_096) {
                    try Task.checkCancellation()
                }
                let result = try ASHLockedRuntimeV3.evaluateSample(
                    frame: frame,
                    runtimePlane: runtimePlane,
                    plane: plane,
                    destinationColumn: column,
                    destinationRow: row,
                    chromaSiting: chromaSiting
                )
                try summary.record(result)
                samples.append(result.value)
            }
        }
        return ASHSpatialReferencePlaneOutputV2(
            width: width,
            height: height,
            normalizedSamples: samples
        )
    }
}
