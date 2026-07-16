import Foundation

enum ASHLockedRuntimeV3Error: Error, Equatable, Sendable {
    case configurationMismatch
    case parameterIndexOutOfBounds(UInt32)
    case invalidAnalysisGrid
    case invalidDestination(column: Int, row: Int)
    case invalidPhase
    case invalidPlaneRole
    case invalidChromaSiting
    case invalidRuntimeParameter
    case invalidSidecar
    case modeParameterMismatch
    case sourceExactMismatch
    case numericalFallbackFailed
}

enum ASHRuntimePlaneV3: UInt8, CaseIterable, Equatable, Sendable {
    case luma
    case cb
    case cr

    var lutPlaneRole: ASHLUTPlaneRoleV3 {
        switch self {
        case .luma: .luma
        case .cb, .cr: .chroma
        }
    }
}

struct ASHSpatialSidecarV3: Equatable, Sendable {
    let operatorSidecar: ASHSpatialSidecarV2
    let chromaEdgeConfidenceBitPattern: UInt64

    var chromaEdgeConfidence: Double {
        Double(bitPattern: chromaEdgeConfidenceBitPattern)
    }

    init(
        orientationRadians: Double,
        normalizedMagnitude: Double,
        coherence: Double,
        risk: Double,
        chromaAlignment: Double,
        chromaEdgeConfidence: Double,
        localMinimum: Double,
        localMaximum: Double
    ) throws {
        guard chromaEdgeConfidence.isFinite,
              (0.0...1.0).contains(chromaEdgeConfidence) else {
            throw ASHLockedRuntimeV3Error.invalidSidecar
        }
        do {
            operatorSidecar = try ASHSpatialSidecarV2(
                orientationRadians: orientationRadians,
                normalizedMagnitude: normalizedMagnitude,
                coherence: coherence,
                risk: risk,
                chromaAlignment: chromaAlignment,
                localMinimum: localMinimum,
                localMaximum: localMaximum
            )
        } catch {
            throw ASHLockedRuntimeV3Error.invalidSidecar
        }
        chromaEdgeConfidenceBitPattern = chromaEdgeConfidence.bitPattern
    }

    func rotatingOrientation(to orientationRadians: Double) throws -> ASHSpatialSidecarV3 {
        try ASHSpatialSidecarV3(
            orientationRadians: orientationRadians,
            normalizedMagnitude: operatorSidecar.normalizedMagnitude,
            coherence: operatorSidecar.coherence,
            risk: operatorSidecar.risk,
            chromaAlignment: operatorSidecar.chromaAlignment,
            chromaEdgeConfidence: chromaEdgeConfidence,
            localMinimum: operatorSidecar.localMinimum,
            localMaximum: operatorSidecar.localMaximum
        )
    }
}

struct ASHLockedRuntimeConstructionCountersV3: Equatable, Sendable {
    let analyzerTraversalCount: Int
    let dispatchGridConstructionCount: Int
    let lutLoadCount: Int
    let jsonParsingCount: Int
    let runtimeTreeGenerationCount: Int
    let runtimePathConstructionCount: Int

    static let preparedFrame = ASHLockedRuntimeConstructionCountersV3(
        analyzerTraversalCount: 1,
        dispatchGridConstructionCount: ASHLUTPlaneRoleV3.allCases.count,
        lutLoadCount: 0,
        jsonParsingCount: 0,
        runtimeTreeGenerationCount: 0,
        runtimePathConstructionCount: 0
    )
}

struct ASHLockedRuntimeCandidateV3: Equatable, Sendable {
    let decodedMessage: ASHMessage
    let descriptor: ASHSpatialDescriptorV2
    let affineDecode: ASHLockedAffineDecodeResultV2
    let sidecar: ASHSpatialSidecarV3
    let orientationSector: Int
    let anisotropyMode: ASHLUTAnisotropyModeV3
    let parameters: ASHSpatialDevelopmentParametersV2

    var usesAnisotropy: Bool { anisotropyMode.usesAnisotropy }
    var anisotropyStrengthQ12: UInt16 { anisotropyMode.anisotropyStrengthQ12 }
}

struct ASHLockedRuntimeDispatchV3: Equatable, Sendable {
    let sourceState: ASHState
    let planeRole: ASHLUTPlaneRoleV3
    let parityWasRecomputed: Bool
    let primary: ASHLockedRuntimeCandidateV3
    let secondary: ASHLockedRuntimeCandidateV3?
    let primaryWeightUNorm16: UInt16
    let secondaryWeightUNorm16: UInt16
    let marginUNorm16: UInt16
    let affineFallbackUsed: Bool
    let sourceAlignedEntryFlag: Bool

    var operatorEvaluationCount: Int { secondary == nil ? 1 : 2 }
}

struct ASHLockedDispatchGridV3: Equatable, Sendable {
    let route: ASHSpatialRouteV2
    let configuration: ASHLUTLockedConfigurationV3
    let planeRole: ASHLUTPlaneRoleV3
    let context: ASHLUTContextV3
    let analysisColumnCount: Int
    let analysisRowCount: Int
    let dispatches: [ASHLockedRuntimeDispatchV3]

    func dispatch(
        cellColumn: Int,
        cellRow: Int,
        phaseOrdinal: Int
    ) throws -> ASHLockedRuntimeDispatchV3 {
        guard (0..<analysisColumnCount).contains(cellColumn),
              (0..<analysisRowCount).contains(cellRow),
              (0..<route.phasePairCount).contains(phaseOrdinal) else {
            throw ASHLockedRuntimeV3Error.invalidPhase
        }
        let cellIndex = (cellRow * analysisColumnCount) + cellColumn
        return dispatches[(cellIndex * route.phasePairCount) + phaseOrdinal]
    }
}

struct ASHLockedPlaneDispatchGridsV3: Equatable, Sendable {
    let luma: ASHLockedDispatchGridV3
    let chroma: ASHLockedDispatchGridV3

    func grid(for plane: ASHRuntimePlaneV3) -> ASHLockedDispatchGridV3 {
        switch plane {
        case .luma: luma
        case .cb, .cr: chroma
        }
    }
}

struct ASHLockedFrameRuntimeV3: Equatable, Sendable {
    let analysisGrid: ASHAnalysisGridV2
    let dispatchGrids: ASHLockedPlaneDispatchGridsV3
    let chromaSiting: ASHChromaSitingV2
    let constructionCounters: ASHLockedRuntimeConstructionCountersV3
}

struct ASHLockedRuntimeOperatorResultV3: Equatable, Sendable {
    let declaredDescriptorID: UInt8
    let effectiveDescriptorID: UInt8
    let usesAnisotropy: Bool
    let sample: ASHSpatialSampleResultV2
}

struct ASHLockedRuntimeSampleResultV3: Equatable, Sendable {
    let value: Double
    let runtimePlane: ASHRuntimePlaneV3
    let sourceCoordinates: ASHSpatialSourceCoordinatesV2
    let phaseOrdinal: Int
    let analysisCellColumn: Int
    let analysisCellRow: Int
    let dispatch: ASHLockedRuntimeDispatchV3
    let primaryResult: ASHLockedRuntimeOperatorResultV3
    let secondaryResult: ASHLockedRuntimeOperatorResultV3?
    let sourceAlignedSamplePreserved: Bool
    let numericalFallbackUsed: Bool
}

enum ASHLockedRuntimeV3 {}
