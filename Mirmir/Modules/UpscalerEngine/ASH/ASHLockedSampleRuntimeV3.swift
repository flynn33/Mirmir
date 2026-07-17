import Foundation

extension ASHLockedRuntimeV3 {
    private struct SampleLocation {
        let sourceCoordinates: ASHSpatialSourceCoordinatesV2
        let cell: ASHAnalysisGridCellV2
        let phaseOrdinal: Int
        let coordinatePolicy: ASHSpatialCoordinatePolicyV2
    }

    private struct Evaluation {
        let value: Double
        let primary: ASHLockedRuntimeOperatorResultV3
        let secondary: ASHLockedRuntimeOperatorResultV3?
        let fallbackUsed: Bool
        let actualOperatorInvocationCount: Int
    }

    static func evaluateSample(
        frame: ASHLockedFrameRuntimeV3,
        runtimePlane: ASHRuntimePlaneV3,
        plane: ASHSpatialPlaneV2,
        destinationColumn: Int,
        destinationRow: Int,
        chromaSiting: ASHChromaSitingV2?
    ) throws -> ASHLockedRuntimeSampleResultV3 {
        switch runtimePlane {
        case .luma:
            guard chromaSiting == nil else {
                throw ASHLockedRuntimeV3Error.invalidChromaSiting
            }
        case .cb, .cr:
            guard chromaSiting == frame.chromaSiting else {
                throw ASHLockedRuntimeV3Error.invalidChromaSiting
            }
        }
        let grid = frame.dispatchGrids.grid(for: runtimePlane)
        return try evaluateSample(
            dispatchGrid: grid,
            configuration: grid.configuration,
            analysisGrid: frame.analysisGrid,
            runtimePlane: runtimePlane,
            plane: plane,
            destinationColumn: destinationColumn,
            destinationRow: destinationRow,
            chromaSiting: chromaSiting
        )
    }

    static func evaluateSample(
        dispatchGrid: ASHLockedDispatchGridV3,
        configuration: ASHLUTLockedConfigurationV3,
        analysisGrid: ASHAnalysisGridV2,
        runtimePlane: ASHRuntimePlaneV3,
        plane: ASHSpatialPlaneV2,
        destinationColumn: Int,
        destinationRow: Int,
        chromaSiting: ASHChromaSitingV2?
    ) throws -> ASHLockedRuntimeSampleResultV3 {
        guard dispatchGrid.configuration == configuration else {
            throw ASHLockedRuntimeV3Error.configurationMismatch
        }
        guard dispatchGrid.context == .spatialOnly,
              dispatchGrid.planeRole == runtimePlane.lutPlaneRole else {
            throw ASHLockedRuntimeV3Error.invalidPlaneRole
        }
        guard dispatchGrid.analysisColumnCount == analysisGrid.columnCount,
              dispatchGrid.analysisRowCount == analysisGrid.rowCount else {
            throw ASHLockedRuntimeV3Error.invalidAnalysisGrid
        }
        switch runtimePlane {
        case .luma:
            guard chromaSiting == nil else {
                throw ASHLockedRuntimeV3Error.invalidChromaSiting
            }
        case .cb, .cr:
            guard chromaSiting != nil else {
                throw ASHLockedRuntimeV3Error.invalidChromaSiting
            }
        }
        let location = try sampleLocation(
            route: dispatchGrid.route,
            configuration: configuration,
            analysisGrid: analysisGrid,
            planeRole: dispatchGrid.planeRole,
            plane: plane,
            destinationColumn: destinationColumn,
            destinationRow: destinationRow,
            chromaSiting: chromaSiting
        )
        let dispatch = try dispatchGrid.dispatch(
            cellColumn: location.cell.column,
            cellRow: location.cell.row,
            phaseOrdinal: location.phaseOrdinal
        )
        let expectedSourceExact = location.coordinatePolicy == .sourceAlignedRational
            && location.phaseOrdinal == 0
        guard dispatch.sourceAlignedEntryFlag == expectedSourceExact else {
            throw ASHLockedRuntimeV3Error.sourceExactMismatch
        }
        let evaluation = try evaluate(
            dispatch: dispatch,
            plane: plane,
            destinationColumn: destinationColumn,
            destinationRow: destinationRow,
            route: dispatchGrid.route,
            boundary: configuration.boundaryMode,
            coordinatePolicy: location.coordinatePolicy,
            sourceCoordinates: location.sourceCoordinates
        )
        return ASHLockedRuntimeSampleResultV3(
            value: evaluation.value,
            runtimePlane: runtimePlane,
            sourceCoordinates: location.sourceCoordinates,
            phaseOrdinal: location.phaseOrdinal,
            analysisCellColumn: location.cell.column,
            analysisCellRow: location.cell.row,
            dispatch: dispatch,
            primaryResult: evaluation.primary,
            secondaryResult: evaluation.secondary,
            sourceAlignedSamplePreserved: evaluation.primary.sample.sourceAlignedSamplePreserved
                && (evaluation.secondary?.sample.sourceAlignedSamplePreserved ?? true),
            numericalFallbackUsed: evaluation.fallbackUsed,
            actualOperatorInvocationCount: evaluation.actualOperatorInvocationCount
        )
    }

    static func evaluateCandidate(
        _ candidate: ASHLockedRuntimeCandidateV3,
        plane: ASHSpatialPlaneV2,
        destinationColumn: Int,
        destinationRow: Int,
        route: ASHSpatialRouteV2,
        coordinatePolicy: ASHSpatialCoordinatePolicyV2,
        boundary: ASHSpatialBoundaryModeV2,
        sourceCoordinates: ASHSpatialSourceCoordinatesV2? = nil
    ) throws -> ASHLockedRuntimeOperatorResultV3 {
        let effectiveDescriptorID = candidate.usesAnisotropy
            ? candidate.descriptor.id
            : candidate.descriptor.id & ~UInt8(0b0010)
        let effectiveDescriptor = try ASHSpatialDescriptorV2(id: effectiveDescriptorID)
        let sample = try ASHSpatialOperatorBankV2.evaluateSample(ASHSpatialSampleRequestV2(
            plane: plane,
            destinationColumn: destinationColumn,
            destinationRow: destinationRow,
            route: route,
            coordinatePolicy: coordinatePolicy,
            descriptor: effectiveDescriptor,
            sidecar: candidate.sidecar.operatorSidecar,
            boundary: boundary,
            parameters: candidate.parameters,
            coordinateOverride: sourceCoordinates
        ))
        return ASHLockedRuntimeOperatorResultV3(
            declaredDescriptorID: candidate.descriptor.id,
            effectiveDescriptorID: effectiveDescriptor.id,
            usesAnisotropy: candidate.usesAnisotropy,
            sample: sample
        )
    }

    private static func sampleLocation(
        route: ASHSpatialRouteV2,
        configuration: ASHLUTLockedConfigurationV3,
        analysisGrid: ASHAnalysisGridV2,
        planeRole: ASHLUTPlaneRoleV3,
        plane: ASHSpatialPlaneV2,
        destinationColumn: Int,
        destinationRow: Int,
        chromaSiting: ASHChromaSitingV2?
    ) throws -> SampleLocation {
        let outputWidth = try route.destinationExtent(for: plane.width)
        let outputHeight = try route.destinationExtent(for: plane.height)
        guard (0..<outputWidth).contains(destinationColumn),
              (0..<outputHeight).contains(destinationRow) else {
            throw ASHLockedRuntimeV3Error.invalidDestination(
                column: destinationColumn,
                row: destinationRow
            )
        }
        let routeSelection = configuration.routeSelection(for: route)
        let expectedLumaWidth = chromaSiting == nil ? plane.width : plane.width * 2
        let expectedLumaHeight = chromaSiting == nil ? plane.height : plane.height * 2
        guard analysisGrid.step == Int(routeSelection.analysisGridSourceStep),
              analysisGrid.sourceWidth == expectedLumaWidth,
              analysisGrid.sourceHeight == expectedLumaHeight else {
            throw ASHLockedRuntimeV3Error.invalidAnalysisGrid
        }
        let coordinatePolicy = routeSelection.coordinatePolicy(for: planeRole)
        let sourceCoordinates = try coordinates(
            plane: plane,
            destinationColumn: destinationColumn,
            destinationRow: destinationRow,
            outputWidth: outputWidth,
            outputHeight: outputHeight,
            policy: coordinatePolicy,
            chromaSiting: chromaSiting
        )
        let cell: ASHAnalysisGridCellV2
        if let chromaSiting {
            cell = try analysisGrid.cell(
                chromaSourceX: sourceCoordinates.horizontal,
                chromaSourceY: sourceCoordinates.vertical,
                siting: chromaSiting
            )
        } else {
            cell = try analysisGrid.cell(
                lumaSourceX: sourceCoordinates.horizontal,
                lumaSourceY: sourceCoordinates.vertical
            )
        }
        return SampleLocation(
            sourceCoordinates: sourceCoordinates,
            cell: cell,
            phaseOrdinal: try ASHLockedRuntimeV2.phaseOrdinal(
                sourceCoordinates: sourceCoordinates,
                plane: plane,
                outputWidth: outputWidth,
                outputHeight: outputHeight,
                route: route,
                policy: coordinatePolicy,
                chromaSiting: chromaSiting
            ),
            coordinatePolicy: coordinatePolicy
        )
    }

    private static func coordinates(
        plane: ASHSpatialPlaneV2,
        destinationColumn: Int,
        destinationRow: Int,
        outputWidth: Int,
        outputHeight: Int,
        policy: ASHSpatialCoordinatePolicyV2,
        chromaSiting: ASHChromaSitingV2?
    ) throws -> ASHSpatialSourceCoordinatesV2 {
        if let chromaSiting {
            return ASHSpatialSourceCoordinatesV2(
                horizontal: try chromaSiting.sourceCoordinate(
                    destinationIndex: destinationColumn,
                    sourceExtent: plane.width,
                    destinationExtent: outputWidth,
                    policy: policy,
                    axis: .horizontal
                ),
                vertical: try chromaSiting.sourceCoordinate(
                    destinationIndex: destinationRow,
                    sourceExtent: plane.height,
                    destinationExtent: outputHeight,
                    policy: policy,
                    axis: .vertical
                )
            )
        }
        return ASHSpatialSourceCoordinatesV2(
            horizontal: try ASHSpatialOperatorBankV2.coordinate(
                destinationIndex: destinationColumn,
                sourceExtent: plane.width,
                destinationExtent: outputWidth,
                policy: policy
            ),
            vertical: try ASHSpatialOperatorBankV2.coordinate(
                destinationIndex: destinationRow,
                sourceExtent: plane.height,
                destinationExtent: outputHeight,
                policy: policy
            )
        )
    }

    private static func evaluate(
        dispatch: ASHLockedRuntimeDispatchV3,
        plane: ASHSpatialPlaneV2,
        destinationColumn: Int,
        destinationRow: Int,
        route: ASHSpatialRouteV2,
        boundary: ASHSpatialBoundaryModeV2,
        coordinatePolicy: ASHSpatialCoordinatePolicyV2,
        sourceCoordinates: ASHSpatialSourceCoordinatesV2
    ) throws -> Evaluation {
        var actualOperatorInvocationCount = 0
        do {
            actualOperatorInvocationCount += 1
            let primary = try evaluateCandidate(
                dispatch.primary,
                plane: plane,
                destinationColumn: destinationColumn,
                destinationRow: destinationRow,
                route: route,
                coordinatePolicy: coordinatePolicy,
                boundary: boundary,
                sourceCoordinates: sourceCoordinates
            )
            guard let secondaryCandidate = dispatch.secondary else {
                return Evaluation(
                    value: primary.sample.value,
                    primary: primary,
                    secondary: nil,
                    fallbackUsed: false,
                    actualOperatorInvocationCount: actualOperatorInvocationCount
                )
            }
            actualOperatorInvocationCount += 1
            let secondary = try evaluateCandidate(
                secondaryCandidate,
                plane: plane,
                destinationColumn: destinationColumn,
                destinationRow: destinationRow,
                route: route,
                coordinatePolicy: coordinatePolicy,
                boundary: boundary,
                sourceCoordinates: sourceCoordinates
            )
            let denominator = Double(UInt16.max)
            let value = plane.legalClamp(
                (Double(dispatch.primaryWeightUNorm16) * primary.sample.value / denominator)
                    + (Double(dispatch.secondaryWeightUNorm16) * secondary.sample.value / denominator)
            )
            return Evaluation(
                value: value,
                primary: primary,
                secondary: secondary,
                fallbackUsed: false,
                actualOperatorInvocationCount: actualOperatorInvocationCount
            )
        } catch let error as ASHSpatialOperatorErrorV2 {
            guard ASHSpatialOperatorBankV2.conservativeFallback(for: error) != nil else {
                throw error
            }
            actualOperatorInvocationCount += 1
            let fallback = try conservativeEvaluation(
                dispatch: dispatch,
                plane: plane,
                destinationColumn: destinationColumn,
                destinationRow: destinationRow,
                route: route,
                boundary: boundary,
                coordinatePolicy: coordinatePolicy,
                sourceCoordinates: sourceCoordinates
            )
            return Evaluation(
                value: fallback.sample.value,
                primary: fallback,
                secondary: nil,
                fallbackUsed: true,
                actualOperatorInvocationCount: actualOperatorInvocationCount
            )
        }
    }

    private static func conservativeEvaluation(
        dispatch: ASHLockedRuntimeDispatchV3,
        plane: ASHSpatialPlaneV2,
        destinationColumn: Int,
        destinationRow: Int,
        route: ASHSpatialRouteV2,
        boundary: ASHSpatialBoundaryModeV2,
        coordinatePolicy: ASHSpatialCoordinatePolicyV2,
        sourceCoordinates: ASHSpatialSourceCoordinatesV2
    ) throws -> ASHLockedRuntimeOperatorResultV3 {
        let source = dispatch.primary.parameters
        let parameters = ASHSpatialDevelopmentParametersV2(
            anisotropyStrength: source.anisotropyStrength,
            minimumAnisotropicMagnitude: source.minimumAnisotropicMagnitude,
            minimumAnisotropicCoherence: source.minimumAnisotropicCoherence,
            controlledDetailGain: 0.0,
            relaxedLimiterAlpha: 0.0,
            riskDetailSuppressionThreshold: source.riskDetailSuppressionThreshold,
            lowPassRadius: source.lowPassRadius,
            weightEpsilon: source.weightEpsilon,
            supportRadius: 2.0
        )
        do {
            let sample = try ASHSpatialOperatorBankV2.evaluateSample(ASHSpatialSampleRequestV2(
                plane: plane,
                destinationColumn: destinationColumn,
                destinationRow: destinationRow,
                route: route,
                coordinatePolicy: coordinatePolicy,
                descriptor: try ASHSpatialDescriptorV2(id: 0),
                sidecar: dispatch.primary.sidecar.operatorSidecar,
                boundary: boundary,
                parameters: parameters,
                coordinateOverride: sourceCoordinates
            ))
            return ASHLockedRuntimeOperatorResultV3(
                declaredDescriptorID: 0,
                effectiveDescriptorID: 0,
                usesAnisotropy: false,
                sample: sample
            )
        } catch {
            throw ASHLockedRuntimeV3Error.numericalFallbackFailed
        }
    }
}
