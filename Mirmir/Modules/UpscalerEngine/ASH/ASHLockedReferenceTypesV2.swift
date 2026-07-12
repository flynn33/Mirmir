import Foundation

enum ASHLockedReferencePipelineV2Error: Error, Equatable, Sendable {
    case mismatchedChromaGeometry
    case mismatchedPlaneRange
    case unsupportedChromaSubsampling
    case mappingHashMismatch
    case mappingConfigurationMismatch
    case chromaSitingMismatch
    case invalidMeasurementPolicy
    case dispatchProjectionOutputMismatch
    case invalidNormalizedChromaSample(Int)
}

enum ASHLockedChromaOutputConventionV2: String, Equatable, Sendable {
    case normalizedZeroToOne = "normalized_chroma_0_1"
}

struct ASHLockedReferenceInputV2: Sendable {
    let luma: ASHVideoAnalyzerV2CodePlane
    let cb: ASHVideoAnalyzerV2CodePlane
    let cr: ASHVideoAnalyzerV2CodePlane
    let chromaSiting: ASHChromaSitingV2
    let lut: ASHLUTLoadedV2
    let configuration: ASHLUTLockedConfigurationV2
    let mapping: ASHLockedVideoMappingV2
}

struct ASHLockedReferencePlaneOutputV2: Equatable, Sendable {
    let width: Int
    let height: Int
    let normalizedSamples: [Double]
}

struct ASHLockedReferenceSummaryV2: Equatable, Sendable {
    let route: ASHSpatialRouteV2
    let coordinatePolicy: ASHSpatialCoordinatePolicyV2
    let boundaryMode: ASHSpatialBoundaryModeV2
    let analysisGridSourceStep: Int
    let analysisCellCount: Int
    let dispatchRecordCount: Int
    let stateHistogram: [UInt16: Int]
    let operatorHistogram: [UInt8: Int]
    let exactDecodeCount: Int
    let correctedDecodeCount: Int
    let rejectedDecodeCount: Int
    let parityRecomputationCount: Int
    let affineFallbackCount: Int
    let numericalFallbackCount: Int
    let sourceAlignedEntryDispatchCount: Int
    let sourceAlignedSamplePreservationCount: Int
    let maximumOperatorEvaluations: Int
    let runtimeTreeGenerationCount: Int
    let runtimePathAllocationCount: Int
    let cpuReferenceAnalysisTraversalCount: Int
    let cpuReferenceFullFrameLoopCount: Int
    let productionMetalConstraintEvaluated: Bool
    let loadedLUTInstanceCount: Int
    let perFrameLUTLoadCount: Int
    let configurationID: String
    let mappingSHA256: ASHLUTHashV2
    let operatorBankSHA256: ASHLUTHashV2
    let metricPolicySHA256: ASHLUTHashV2
    let compilerInputsSHA256: ASHLUTHashV2
    let calibrationPlanSHA256: ASHLUTHashV2
    let corpusLockBundleSHA256: ASHLUTHashV2
    let chromaOutputConvention: ASHLockedChromaOutputConventionV2
    let analysisElapsedMilliseconds: Double
    let dispatchElapsedMilliseconds: Double
    let reconstructionElapsedMilliseconds: Double
    let lutPayloadSHA256: ASHLUTHashV2
    let lutWholeFileSHA256: ASHLUTHashV2
}

struct ASHLockedReferenceOutputV2: Equatable, Sendable {
    let luma: ASHLockedReferencePlaneOutputV2
    let cb: ASHLockedReferencePlaneOutputV2
    let cr: ASHLockedReferencePlaneOutputV2
    let summary: ASHLockedReferenceSummaryV2
}

enum ASHLockedDispatchProjectionOrderV2: String, Equatable, Sendable {
    case fullThenControl = "full_then_control"
    case controlThenFull = "control_then_full"
}

struct ASHLockedDispatchProjectionRepetitionV2: Equatable, Sendable {
    let index: Int
    let order: ASHLockedDispatchProjectionOrderV2
    let fullAnalysisMilliseconds: Double
    let fullDispatchMilliseconds: Double
    let fullReconstructionMilliseconds: Double
    let controlReconstructionMilliseconds: Double
}

struct ASHLockedDispatchProjectionMeasurementV2: Equatable, Sendable {
    let measurementDomain: String
    let warmupRepetitionCount: Int
    let fullOutput: ASHLockedReferenceOutputV2
    let controlOutput: ASHLockedReferenceOutputV2
    let repetitions: [ASHLockedDispatchProjectionRepetitionV2]
}

struct ASHLockedCenteredChromaPlaneV2: Equatable, Sendable {
    let width: Int
    let height: Int
    let samples: [Double]
}

enum ASHLockedCandidateAdapterBridgeV2 {
    static func centeredChroma(
        _ plane: ASHLockedReferencePlaneOutputV2
    ) throws -> ASHLockedCenteredChromaPlaneV2 {
        var samples: [Double] = []
        samples.reserveCapacity(plane.normalizedSamples.count)
        for (index, sample) in plane.normalizedSamples.enumerated() {
            guard sample.isFinite, (0.0...1.0).contains(sample) else {
                throw ASHLockedReferencePipelineV2Error.invalidNormalizedChromaSample(index)
            }
            samples.append(sample - 0.5)
        }
        return ASHLockedCenteredChromaPlaneV2(
            width: plane.width,
            height: plane.height,
            samples: samples
        )
    }
}
