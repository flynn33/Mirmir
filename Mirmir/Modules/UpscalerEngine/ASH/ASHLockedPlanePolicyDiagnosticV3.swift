import Foundation

enum ASHLockedPlanePolicyDiagnosticV3Error: Error, Equatable, Sendable {
    case routeMismatch
    case configurationMismatch
    case requiresSpatialOnlyDispatchGrid
    case requiresGenericDispatchGrid
    case invalidAnisotropyCells

    var machineCode: String {
        switch self {
        case .routeMismatch:
            "locked_plane_diagnostic_route_mismatch"
        case .configurationMismatch:
            "locked_plane_diagnostic_configuration_mismatch"
        case .requiresSpatialOnlyDispatchGrid:
            "locked_plane_diagnostic_requires_spatial_dispatch_grid"
        case .requiresGenericDispatchGrid:
            "locked_plane_diagnostic_requires_generic_dispatch_grid"
        case .invalidAnisotropyCells:
            "locked_plane_diagnostic_invalid_anisotropy_cells"
        }
    }
}

struct ASHLockedPlaneAnisotropyCellV3: Equatable, Sendable {
    let lumaStrengthQ12: UInt16
    let chromaStrengthQ12: UInt16
}

struct ASHLockedPlanePolicyDiagnosticRequestV3: Sendable {
    let selection: ASHCoordinateDiagnosticRouteSelectionV3
    let lumaPlane: ASHSpatialPlaneV2
    let cbPlane: ASHSpatialPlaneV2
    let crPlane: ASHSpatialPlaneV2
    let dispatchGrid: ASHLockedDispatchGridV2
    let configuration: ASHLUTLockedConfigurationV2
    let analysisGrid: ASHAnalysisGridV2
    let chromaSiting: ASHChromaSitingV2
    let anisotropyCells: [ASHLockedPlaneAnisotropyCellV3]
}

struct ASHLockedPlaneDiagnosticOutputV3: Equatable, Sendable {
    let coordinatePolicy: ASHCoordinateModelPolicyV3
    let anisotropyStrengthQ12: UInt16
    let output: ASHLockedReferencePlaneOutputV2
    let sourceAlignedSamplePreservationCount: Int
    let sourceAlignedEntryFlagSampleCount: Int
    let numericalFallbackCount: Int
}

struct ASHLockedPlaneAnisotropyResultV3: Equatable, Sendable {
    let selection: ASHLockedPlaneAnisotropyCellV3
    let luma: ASHLockedPlaneDiagnosticOutputV3
    let cb: ASHLockedPlaneDiagnosticOutputV3
    let cr: ASHLockedPlaneDiagnosticOutputV3
}

struct ASHLockedPlanePolicyDiagnosticResultV3: Equatable, Sendable {
    let route: ASHCoordinateModelRouteV3
    let contractSHA256: ASHLUTHashV2
    let anisotropyCells: [ASHLockedPlaneAnisotropyResultV3]
}

/// Development diagnostic only. The caller supplies one locked generic dispatch
/// grid, and the contract-bound selection controls each plane's coordinate policy
/// without changing analysis or dispatch compilation.
enum ASHLockedPlanePolicyDiagnosticV3 {
    static let requiredAnisotropyCells = [
        ASHLockedPlaneAnisotropyCellV3(lumaStrengthQ12: 0, chromaStrengthQ12: 0),
        ASHLockedPlaneAnisotropyCellV3(lumaStrengthQ12: 0, chromaStrengthQ12: 3_072),
        ASHLockedPlaneAnisotropyCellV3(lumaStrengthQ12: 3_072, chromaStrengthQ12: 0),
        ASHLockedPlaneAnisotropyCellV3(lumaStrengthQ12: 3_072, chromaStrengthQ12: 3_072)
    ]

    static func process(
        _ request: ASHLockedPlanePolicyDiagnosticRequestV3
    ) throws -> ASHLockedPlanePolicyDiagnosticResultV3 {
        guard request.selection.route.lockedDiagnosticRouteV2 == request.dispatchGrid.route else {
            throw ASHLockedPlanePolicyDiagnosticV3Error.routeMismatch
        }
        guard request.dispatchGrid.configuration == request.configuration else {
            throw ASHLockedPlanePolicyDiagnosticV3Error.configurationMismatch
        }
        guard request.dispatchGrid.context == .spatialOnly else {
            throw ASHLockedPlanePolicyDiagnosticV3Error.requiresSpatialOnlyDispatchGrid
        }
        guard request.dispatchGrid.dispatches.allSatisfy({ !$0.sourceAlignedEntryFlag }) else {
            throw ASHLockedPlanePolicyDiagnosticV3Error
                .requiresGenericDispatchGrid
        }
        guard request.anisotropyCells == requiredAnisotropyCells else {
            throw ASHLockedPlanePolicyDiagnosticV3Error.invalidAnisotropyCells
        }

        let lumaPolicy = request.selection.coordinatePolicy(for: nil)
        let chromaPolicy = request.selection.coordinatePolicy(for: request.chromaSiting)
        return ASHLockedPlanePolicyDiagnosticResultV3(
            route: request.selection.route,
            contractSHA256: request.selection.contractSHA256,
            anisotropyCells: try request.anisotropyCells.map { cell in
                ASHLockedPlaneAnisotropyResultV3(
                    selection: cell,
                    luma: try reconstruct(
                        plane: request.lumaPlane,
                        policy: lumaPolicy,
                        anisotropyStrengthQ12: cell.lumaStrengthQ12,
                        dispatchGrid: request.dispatchGrid,
                        configuration: request.configuration,
                        analysisGrid: request.analysisGrid,
                        chromaSiting: nil
                    ),
                    cb: try reconstruct(
                        plane: request.cbPlane,
                        policy: chromaPolicy,
                        anisotropyStrengthQ12: cell.chromaStrengthQ12,
                        dispatchGrid: request.dispatchGrid,
                        configuration: request.configuration,
                        analysisGrid: request.analysisGrid,
                        chromaSiting: request.chromaSiting
                    ),
                    cr: try reconstruct(
                        plane: request.crPlane,
                        policy: chromaPolicy,
                        anisotropyStrengthQ12: cell.chromaStrengthQ12,
                        dispatchGrid: request.dispatchGrid,
                        configuration: request.configuration,
                        analysisGrid: request.analysisGrid,
                        chromaSiting: request.chromaSiting
                    )
                )
            }
        )
    }

    private static func reconstruct(
        plane: ASHSpatialPlaneV2,
        policy: ASHCoordinateModelPolicyV3,
        anisotropyStrengthQ12: UInt16,
        dispatchGrid: ASHLockedDispatchGridV2,
        configuration: ASHLUTLockedConfigurationV2,
        analysisGrid: ASHAnalysisGridV2,
        chromaSiting: ASHChromaSitingV2?
    ) throws -> ASHLockedPlaneDiagnosticOutputV3 {
        let outputWidth = try dispatchGrid.route.destinationExtent(for: plane.width)
        let outputHeight = try dispatchGrid.route.destinationExtent(for: plane.height)
        var samples: [Double] = []
        samples.reserveCapacity(outputWidth * outputHeight)
        var preservationCount = 0
        var entryFlagSampleCount = 0
        var fallbackCount = 0

        for row in 0..<outputHeight {
            for column in 0..<outputWidth {
                if samples.count.isMultiple(of: 4_096) {
                    try Task.checkCancellation()
                }
                let result = try ASHLockedRuntimeV2.evaluateSampleForDiagnostic(
                    dispatchGrid: dispatchGrid,
                    configuration: configuration,
                    analysisGrid: analysisGrid,
                    plane: plane,
                    destinationColumn: column,
                    destinationRow: row,
                    chromaSiting: chromaSiting,
                    coordinatePolicyOverride: policy.lockedDiagnosticPolicyV2,
                    anisotropyStrengthQ12Override: anisotropyStrengthQ12
                )
                samples.append(result.value)
                if result.sourceAlignedSamplePreserved { preservationCount += 1 }
                if result.dispatch.sourceAlignedEntryFlag { entryFlagSampleCount += 1 }
                if result.numericalFallbackUsed { fallbackCount += 1 }
            }
        }

        return ASHLockedPlaneDiagnosticOutputV3(
            coordinatePolicy: policy,
            anisotropyStrengthQ12: anisotropyStrengthQ12,
            output: ASHLockedReferencePlaneOutputV2(
                width: outputWidth,
                height: outputHeight,
                normalizedSamples: samples
            ),
            sourceAlignedSamplePreservationCount: preservationCount,
            sourceAlignedEntryFlagSampleCount: entryFlagSampleCount,
            numericalFallbackCount: fallbackCount
        )
    }
}

private extension ASHCoordinateModelRouteV3 {
    var lockedDiagnosticRouteV2: ASHSpatialRouteV2 {
        switch self {
        case .direct2x: .direct2x
        case .direct3Over2: .direct3Over2
        }
    }
}

private extension ASHCoordinateModelPolicyV3 {
    var lockedDiagnosticPolicyV2: ASHSpatialCoordinatePolicyV2 {
        switch self {
        case .halfPixelCenter: .halfPixelCenter
        case .sourceAlignedRational: .sourceAlignedRational
        }
    }
}
