import Foundation

enum ASHCoordinateDiagnosticRuntimeV3Error: Error, Equatable, Sendable {
    case contractNotLoaded
    case routeNotDeclared(ASHCoordinateModelRouteV3)
    case lumaPolicyNotDeclared(
        route: ASHCoordinateModelRouteV3,
        policy: ASHCoordinateModelPolicyV3
    )
    case chromaPolicyNotDeclared(
        route: ASHCoordinateModelRouteV3,
        policy: ASHCoordinateModelPolicyV3
    )

    var machineCode: String {
        switch self {
        case .contractNotLoaded:
            "coordinate_diagnostic_contract_not_loaded"
        case .routeNotDeclared:
            "coordinate_diagnostic_route_not_declared"
        case .lumaPolicyNotDeclared:
            "coordinate_diagnostic_luma_policy_not_declared"
        case .chromaPolicyNotDeclared:
            "coordinate_diagnostic_chroma_policy_not_declared"
        }
    }
}

enum ASHCoordinateDiagnosticPlaneRoleV3: Equatable, Sendable {
    case luma
    case chroma
}

struct ASHCoordinateDiagnosticRouteSelectionV3: Equatable, Sendable {
    let route: ASHCoordinateModelRouteV3
    let lumaCoordinatePolicy: ASHCoordinateModelPolicyV3
    let chromaCoordinatePolicy: ASHCoordinateModelPolicyV3
    let contractSHA256: ASHLUTHashV2

    init(
        route: ASHCoordinateModelRouteV3,
        lumaCoordinatePolicy: ASHCoordinateModelPolicyV3,
        chromaCoordinatePolicy: ASHCoordinateModelPolicyV3,
        contract: ASHCoordinateModelContractV3?
    ) throws {
        guard let contract else {
            throw ASHCoordinateDiagnosticRuntimeV3Error.contractNotLoaded
        }
        guard let dimensions = contract.routeDimensions.first(where: { $0.route == route }) else {
            throw ASHCoordinateDiagnosticRuntimeV3Error.routeNotDeclared(route)
        }
        guard dimensions.lumaCoordinatePolicyValues.contains(lumaCoordinatePolicy) else {
            throw ASHCoordinateDiagnosticRuntimeV3Error.lumaPolicyNotDeclared(
                route: route,
                policy: lumaCoordinatePolicy
            )
        }
        guard dimensions.chromaCoordinatePolicyValues.contains(chromaCoordinatePolicy) else {
            throw ASHCoordinateDiagnosticRuntimeV3Error.chromaPolicyNotDeclared(
                route: route,
                policy: chromaCoordinatePolicy
            )
        }
        self.route = route
        self.lumaCoordinatePolicy = lumaCoordinatePolicy
        self.chromaCoordinatePolicy = chromaCoordinatePolicy
        contractSHA256 = contract.sha256
    }

    func coordinatePolicy(
        for chromaSiting: ASHChromaSitingV2?
    ) -> ASHCoordinateModelPolicyV3 {
        chromaSiting == nil ? lumaCoordinatePolicy : chromaCoordinatePolicy
    }

    func planeRole(
        for chromaSiting: ASHChromaSitingV2?
    ) -> ASHCoordinateDiagnosticPlaneRoleV3 {
        chromaSiting == nil ? .luma : .chroma
    }
}

struct ASHCoordinateDiagnosticCoordinatesV3: Equatable, Sendable {
    let planeRole: ASHCoordinateDiagnosticPlaneRoleV3
    let coordinatePolicy: ASHCoordinateModelPolicyV3
    let sourceCoordinates: ASHSpatialSourceCoordinatesV2
}

struct ASHCoordinateDiagnosticSampleRequestV3: Sendable {
    let selection: ASHCoordinateDiagnosticRouteSelectionV3
    let plane: ASHSpatialPlaneV2
    let destinationColumn: Int
    let destinationRow: Int
    let chromaSiting: ASHChromaSitingV2?
    let descriptor: ASHSpatialDescriptorV2
    let sidecar: ASHSpatialSidecarV2
    let boundary: ASHSpatialBoundaryModeV2
    let parameters: ASHSpatialDevelopmentParametersV2
}

struct ASHCoordinateDiagnosticSampleResultV3: Equatable, Sendable {
    let coordinates: ASHCoordinateDiagnosticCoordinatesV3
    let sample: ASHSpatialSampleResultV2
}

/// Contract-bound coordinate diagnostics only. This type does not select a winning policy
/// and is not connected to the production compiler, LUT, or runtime dispatch paths.
enum ASHCoordinateDiagnosticRuntimeV3 {
    static func sourceCoordinates(
        selection: ASHCoordinateDiagnosticRouteSelectionV3,
        plane: ASHSpatialPlaneV2,
        destinationColumn: Int,
        destinationRow: Int,
        chromaSiting: ASHChromaSitingV2?
    ) throws -> ASHCoordinateDiagnosticCoordinatesV3 {
        let route = selection.route.spatialRouteV2
        let policy = selection.coordinatePolicy(for: chromaSiting)
        let spatialPolicy = policy.spatialPolicyV2
        let destinationWidth = try route.destinationExtent(for: plane.width)
        let destinationHeight = try route.destinationExtent(for: plane.height)
        let horizontal: ASHSpatialRationalCoordinateV2
        let vertical: ASHSpatialRationalCoordinateV2

        if let chromaSiting {
            horizontal = try chromaSiting.sourceCoordinate(
                destinationIndex: destinationColumn,
                sourceExtent: plane.width,
                destinationExtent: destinationWidth,
                policy: spatialPolicy,
                axis: .horizontal
            )
            vertical = try chromaSiting.sourceCoordinate(
                destinationIndex: destinationRow,
                sourceExtent: plane.height,
                destinationExtent: destinationHeight,
                policy: spatialPolicy,
                axis: .vertical
            )
        } else {
            horizontal = try ASHSpatialOperatorBankV2.coordinate(
                destinationIndex: destinationColumn,
                sourceExtent: plane.width,
                destinationExtent: destinationWidth,
                policy: spatialPolicy
            )
            vertical = try ASHSpatialOperatorBankV2.coordinate(
                destinationIndex: destinationRow,
                sourceExtent: plane.height,
                destinationExtent: destinationHeight,
                policy: spatialPolicy
            )
        }

        return ASHCoordinateDiagnosticCoordinatesV3(
            planeRole: selection.planeRole(for: chromaSiting),
            coordinatePolicy: policy,
            sourceCoordinates: ASHSpatialSourceCoordinatesV2(
                horizontal: horizontal,
                vertical: vertical
            )
        )
    }

    static func evaluateSample(
        _ request: ASHCoordinateDiagnosticSampleRequestV3
    ) throws -> ASHCoordinateDiagnosticSampleResultV3 {
        let coordinates = try sourceCoordinates(
            selection: request.selection,
            plane: request.plane,
            destinationColumn: request.destinationColumn,
            destinationRow: request.destinationRow,
            chromaSiting: request.chromaSiting
        )
        let sample = try ASHSpatialOperatorBankV2.evaluateSample(
            ASHSpatialSampleRequestV2(
                plane: request.plane,
                destinationColumn: request.destinationColumn,
                destinationRow: request.destinationRow,
                route: request.selection.route.spatialRouteV2,
                coordinatePolicy: coordinates.coordinatePolicy.spatialPolicyV2,
                descriptor: request.descriptor,
                sidecar: request.sidecar,
                boundary: request.boundary,
                parameters: request.parameters,
                coordinateOverride: coordinates.sourceCoordinates
            )
        )
        return ASHCoordinateDiagnosticSampleResultV3(
            coordinates: coordinates,
            sample: sample
        )
    }
}

private extension ASHCoordinateModelRouteV3 {
    var spatialRouteV2: ASHSpatialRouteV2 {
        switch self {
        case .direct2x: .direct2x
        case .direct3Over2: .direct3Over2
        }
    }
}

private extension ASHCoordinateModelPolicyV3 {
    var spatialPolicyV2: ASHSpatialCoordinatePolicyV2 {
        switch self {
        case .halfPixelCenter: .halfPixelCenter
        case .sourceAlignedRational: .sourceAlignedRational
        }
    }
}
