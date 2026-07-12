import Foundation

extension ASHLockedRuntimeV2 {
    static func evaluateSample(
        lut: ASHLUTLoadedV2,
        configuration: ASHLUTLockedConfigurationV2,
        analysisGrid: ASHAnalysisGridV2,
        plane: ASHSpatialPlaneV2,
        destinationColumn: Int,
        destinationRow: Int,
        chromaSiting: ASHChromaSitingV2?,
        context: ASHLUTContextV2 = .spatialOnly,
        telemetry: any ASHTelemetryRecording = ASHNoopTelemetryRecorder.shared
    ) throws -> ASHLockedRuntimeSampleResultV2 {
        guard lut.configuration == configuration else {
            throw ASHLockedRuntimeV2Error.configurationMismatch
        }
        let location = try sampleLocation(
            route: lut.route,
            configuration: configuration,
            analysisGrid: analysisGrid,
            plane: plane,
            destinationColumn: destinationColumn,
            destinationRow: destinationRow,
            chromaSiting: chromaSiting
        )
        let baseSidecar = try spatialSidecar(location.cell.analysis.sidecar)
        let dispatch = try dispatch(
            lut: lut,
            configuration: configuration,
            sourceState: location.cell.analysis.state,
            phaseOrdinal: location.phaseOrdinal,
            context: context,
            sidecar: baseSidecar,
            telemetry: telemetry
        )
        return try sampleResult(
            dispatch: dispatch,
            location: location,
            plane: plane,
            destinationColumn: destinationColumn,
            destinationRow: destinationRow,
            route: lut.route,
            configuration: configuration
        )
    }

    static func evaluateSample(
        dispatchGrid: ASHLockedDispatchGridV2,
        configuration: ASHLUTLockedConfigurationV2,
        analysisGrid: ASHAnalysisGridV2,
        plane: ASHSpatialPlaneV2,
        destinationColumn: Int,
        destinationRow: Int,
        chromaSiting: ASHChromaSitingV2?
    ) throws -> ASHLockedRuntimeSampleResultV2 {
        guard dispatchGrid.configuration == configuration else {
            throw ASHLockedRuntimeV2Error.configurationMismatch
        }
        guard dispatchGrid.analysisColumnCount == analysisGrid.columnCount,
              dispatchGrid.analysisRowCount == analysisGrid.rowCount else {
            throw ASHLockedRuntimeV2Error.invalidAnalysisGrid
        }
        let location = try sampleLocation(
            route: dispatchGrid.route,
            configuration: configuration,
            analysisGrid: analysisGrid,
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
        return try sampleResult(
            dispatch: dispatch,
            location: location,
            plane: plane,
            destinationColumn: destinationColumn,
            destinationRow: destinationRow,
            route: dispatchGrid.route,
            configuration: configuration
        )
    }

    static func phaseOrdinal(
        sourceCoordinates: ASHSpatialSourceCoordinatesV2,
        plane: ASHSpatialPlaneV2,
        outputWidth: Int,
        outputHeight: Int,
        route: ASHSpatialRouteV2,
        policy: ASHSpatialCoordinatePolicyV2,
        chromaSiting: ASHChromaSitingV2?
    ) throws -> Int {
        let horizontal = try phaseIndex(
            observed: sourceCoordinates.horizontal,
            sourceExtent: plane.width,
            destinationExtent: outputWidth,
            route: route,
            policy: policy,
            chromaSiting: chromaSiting,
            axis: .horizontal
        )
        let vertical = try phaseIndex(
            observed: sourceCoordinates.vertical,
            sourceExtent: plane.height,
            destinationExtent: outputHeight,
            route: route,
            policy: policy,
            chromaSiting: chromaSiting,
            axis: .vertical
        )
        return (vertical * route.scaleNumerator) + horizontal
    }

    static func nonASHFeatureIndex(
        route: ASHSpatialRouteV2,
        configuration: ASHLUTLockedConfigurationV2,
        analysisGrid: ASHAnalysisGridV2,
        plane: ASHSpatialPlaneV2,
        destinationColumn: Int,
        destinationRow: Int,
        chromaSiting: ASHChromaSitingV2?
    ) throws -> Int {
        let location = try sampleLocation(
            route: route,
            configuration: configuration,
            analysisGrid: analysisGrid,
            plane: plane,
            destinationColumn: destinationColumn,
            destinationRow: destinationRow,
            chromaSiting: chromaSiting
        )
        let cellIndex = (location.cell.row * analysisGrid.columnCount)
            + location.cell.column
        return (cellIndex * route.phasePairCount) + location.phaseOrdinal
    }

    private struct SampleLocation {
        let sourceCoordinates: ASHSpatialSourceCoordinatesV2
        let cell: ASHAnalysisGridCellV2
        let phaseOrdinal: Int
        let coordinatePolicy: ASHSpatialCoordinatePolicyV2
    }

    private struct Evaluation {
        let value: Double
        let primary: ASHSpatialSampleResultV2
        let secondary: ASHSpatialSampleResultV2?
        let fallbackUsed: Bool
    }

    private static func sampleLocation(
        route: ASHSpatialRouteV2,
        configuration: ASHLUTLockedConfigurationV2,
        analysisGrid: ASHAnalysisGridV2,
        plane: ASHSpatialPlaneV2,
        destinationColumn: Int,
        destinationRow: Int,
        chromaSiting: ASHChromaSitingV2?
    ) throws -> SampleLocation {
        let outputWidth = try route.destinationExtent(for: plane.width)
        let outputHeight = try route.destinationExtent(for: plane.height)
        guard (0..<outputWidth).contains(destinationColumn),
              (0..<outputHeight).contains(destinationRow) else {
            throw ASHLockedRuntimeV2Error.invalidDestination(
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
            throw ASHLockedRuntimeV2Error.invalidAnalysisGrid
        }
        let sourceCoordinates = try coordinates(
            plane: plane,
            destinationColumn: destinationColumn,
            destinationRow: destinationRow,
            outputWidth: outputWidth,
            outputHeight: outputHeight,
            policy: routeSelection.coordinatePolicy,
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
            phaseOrdinal: try phaseOrdinal(
                sourceCoordinates: sourceCoordinates,
                plane: plane,
                outputWidth: outputWidth,
                outputHeight: outputHeight,
                route: route,
                policy: routeSelection.coordinatePolicy,
                chromaSiting: chromaSiting
            ),
            coordinatePolicy: routeSelection.coordinatePolicy
        )
    }

    private static func sampleResult(
        dispatch: ASHLockedRuntimeDispatchV2,
        location: SampleLocation,
        plane: ASHSpatialPlaneV2,
        destinationColumn: Int,
        destinationRow: Int,
        route: ASHSpatialRouteV2,
        configuration: ASHLUTLockedConfigurationV2
    ) throws -> ASHLockedRuntimeSampleResultV2 {
        let evaluation = try evaluate(
            dispatch: dispatch,
            plane: plane,
            destinationColumn: destinationColumn,
            destinationRow: destinationRow,
            route: route,
            coordinatePolicy: location.coordinatePolicy,
            boundary: configuration.boundaryMode,
            sourceCoordinates: location.sourceCoordinates
        )
        return ASHLockedRuntimeSampleResultV2(
            value: evaluation.value,
            sourceCoordinates: location.sourceCoordinates,
            phaseOrdinal: location.phaseOrdinal,
            analysisCellColumn: location.cell.column,
            analysisCellRow: location.cell.row,
            dispatch: dispatch,
            primaryResult: evaluation.primary,
            secondaryResult: evaluation.secondary,
            sourceAlignedSamplePreserved: evaluation.primary.sourceAlignedSamplePreserved
                && (evaluation.secondary?.sourceAlignedSamplePreserved ?? true),
            numericalFallbackUsed: evaluation.fallbackUsed
        )
    }

    private static func evaluate(
        dispatch: ASHLockedRuntimeDispatchV2,
        plane: ASHSpatialPlaneV2,
        destinationColumn: Int,
        destinationRow: Int,
        route: ASHSpatialRouteV2,
        coordinatePolicy: ASHSpatialCoordinatePolicyV2,
        boundary: ASHSpatialBoundaryModeV2,
        sourceCoordinates: ASHSpatialSourceCoordinatesV2
    ) throws -> Evaluation {
        do {
            let primary = try evaluate(
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
                return Evaluation(value: primary.value, primary: primary, secondary: nil, fallbackUsed: false)
            }
            let secondary = try evaluate(
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
                (Double(dispatch.primaryWeightUNorm16) * primary.value / denominator)
                    + (Double(dispatch.secondaryWeightUNorm16) * secondary.value / denominator)
            )
            return Evaluation(value: value, primary: primary, secondary: secondary, fallbackUsed: false)
        } catch let error as ASHSpatialOperatorErrorV2 {
            guard ASHSpatialOperatorBankV2.conservativeFallback(for: error) != nil else {
                throw error
            }
            let fallback = try conservativeEvaluation(
                dispatch: dispatch,
                plane: plane,
                destinationColumn: destinationColumn,
                destinationRow: destinationRow,
                route: route,
                coordinatePolicy: coordinatePolicy,
                boundary: boundary,
                sourceCoordinates: sourceCoordinates
            )
            return Evaluation(value: fallback.value, primary: fallback, secondary: nil, fallbackUsed: true)
        }
    }

    private static func conservativeEvaluation(
        dispatch: ASHLockedRuntimeDispatchV2,
        plane: ASHSpatialPlaneV2,
        destinationColumn: Int,
        destinationRow: Int,
        route: ASHSpatialRouteV2,
        coordinatePolicy: ASHSpatialCoordinatePolicyV2,
        boundary: ASHSpatialBoundaryModeV2,
        sourceCoordinates: ASHSpatialSourceCoordinatesV2
    ) throws -> ASHSpatialSampleResultV2 {
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
            return try ASHSpatialOperatorBankV2.evaluateSample(ASHSpatialSampleRequestV2(
                plane: plane,
                destinationColumn: destinationColumn,
                destinationRow: destinationRow,
                route: route,
                coordinatePolicy: coordinatePolicy,
                descriptor: try ASHSpatialDescriptorV2(id: 0),
                sidecar: dispatch.primary.sidecar,
                boundary: boundary,
                parameters: parameters,
                coordinateOverride: sourceCoordinates
            ))
        } catch {
            throw ASHLockedRuntimeV2Error.numericalFallbackFailed
        }
    }

    private static func evaluate(
        _ candidate: ASHLockedRuntimeCandidateV2,
        plane: ASHSpatialPlaneV2,
        destinationColumn: Int,
        destinationRow: Int,
        route: ASHSpatialRouteV2,
        coordinatePolicy: ASHSpatialCoordinatePolicyV2,
        boundary: ASHSpatialBoundaryModeV2,
        sourceCoordinates: ASHSpatialSourceCoordinatesV2
    ) throws -> ASHSpatialSampleResultV2 {
        try ASHSpatialOperatorBankV2.evaluateSample(ASHSpatialSampleRequestV2(
            plane: plane,
            destinationColumn: destinationColumn,
            destinationRow: destinationRow,
            route: route,
            coordinatePolicy: coordinatePolicy,
            descriptor: candidate.descriptor,
            sidecar: candidate.sidecar,
            boundary: boundary,
            parameters: candidate.parameters,
            coordinateOverride: sourceCoordinates
        ))
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

    private static func phaseIndex(
        observed: ASHSpatialRationalCoordinateV2,
        sourceExtent: Int,
        destinationExtent: Int,
        route: ASHSpatialRouteV2,
        policy: ASHSpatialCoordinatePolicyV2,
        chromaSiting: ASHChromaSitingV2?,
        axis: ASHChromaSitingAxisV2
    ) throws -> Int {
        let observedPhase = ASHSpatialPhaseComponentV2(coordinate: observed)
        for index in 0..<route.scaleNumerator {
            let candidate: ASHSpatialRationalCoordinateV2
            if let chromaSiting {
                candidate = try chromaSiting.sourceCoordinate(
                    destinationIndex: index,
                    sourceExtent: sourceExtent,
                    destinationExtent: destinationExtent,
                    policy: policy,
                    axis: axis
                )
            } else {
                candidate = try ASHSpatialOperatorBankV2.coordinate(
                    destinationIndex: index,
                    sourceExtent: sourceExtent,
                    destinationExtent: destinationExtent,
                    policy: policy
                )
            }
            if ASHSpatialPhaseComponentV2(coordinate: candidate) == observedPhase {
                return index
            }
        }
        throw ASHLockedRuntimeV2Error.invalidPhase
    }
}
