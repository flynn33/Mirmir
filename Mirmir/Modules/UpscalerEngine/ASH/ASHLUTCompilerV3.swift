import Foundation

// P06 deterministic offline leaf compiler.

enum ASHLUTLeafCompilerV3 {
    struct ResolvedSemantics {
        let descriptorID: UInt8
        let detailGainQ12: UInt16
        let relaxedLimiterAlphaQ12: UInt16
        let supportRadiusQ8x8: UInt16
    }

    struct CompatiblePath {
        let path: ASHLUTCanonicalPathV3
        let semantics: ResolvedSemantics
        let penalty: UInt16
    }

    struct MessageGroup {
        var representative: CompatiblePath
        var rawAggregatedWeight: UInt64
    }

    struct RankedMessageGroup {
        let representative: CompatiblePath
        let encodedWeightQ16x16: UInt32
    }

    static func canonicalPaths() throws -> [ASHLUTCanonicalPathV3] {
        var paths: [ASHLUTCanonicalPathV3] = []
        paths.reserveCapacity(81)
        for ordinal in 0..<81 {
            var remaining = ordinal
            var actions: [ASHLUTCanonicalActionV3] = []
            actions.reserveCapacity(4)
            for divisor in [27, 9, 3, 1] {
                let digit = remaining / divisor
                remaining %= divisor
                guard let action = ASHLUTCanonicalActionV3(rawValue: UInt8(digit)) else {
                    throw ASHLUTCompilerErrorV3.invalidLockedConfiguration
                }
                actions.append(action)
            }

            var message = ASHMessage(validatedRawValue: 0)
            var mass: UInt16 = 1
            for (level, action) in actions.enumerated() {
                switch action {
                case .zero:
                    break
                case .plus:
                    message = try message.toggled(bitIndex: level)
                case .minus:
                    message = try message.toggled(bitIndex: (level + 1) % ASHMessage.bitCount)
                }
                mass *= action.massNumeratorOverFour
            }
            paths.append(ASHLUTCanonicalPathV3(
                ordinal: UInt8(ordinal),
                actions: actions,
                message: message,
                branchMassNumerator: mass,
                semanticDelta: ASHLUTSemanticDeltaV3(
                    orientation: actions[0].semanticStep,
                    support: actions[1].semanticStep,
                    detail: actions[2].semanticStep,
                    regularization: actions[3].semanticStep
                )
            ))
        }
        guard paths.count == 81,
              paths.reduce(0, { $0 + Int($1.branchMassNumerator) }) == 256 else {
            throw ASHLUTCompilerErrorV3.invalidLockedConfiguration
        }
        return paths
    }

    static func logicalIndex(
        planeRole: ASHLUTPlaneRoleV3,
        phaseOrdinal: Int,
        context: ASHLUTContextV3,
        validStateOrdinal: Int,
        route: ASHSpatialRouteV2
    ) throws -> Int {
        guard (0..<route.phasePairCount).contains(phaseOrdinal) else {
            throw ASHLUTCompilerErrorV3.invalidPhase
        }
        guard (0..<ASHLUTStateOrdinalTableV3.validStates.count).contains(validStateOrdinal) else {
            throw ASHLUTCompilerErrorV3.invalidStateOrdinal
        }
        let entriesPerPlane = route.phasePairCount
            * ASHLUTContextV3.allCases.count
            * ASHLUTStateOrdinalTableV3.validStates.count
        return Int(planeRole.rawValue) * entriesPerPlane
            + (((phaseOrdinal * ASHLUTContextV3.allCases.count) + Int(context.rawValue))
                * ASHLUTStateOrdinalTableV3.validStates.count)
            + validStateOrdinal
    }

    static func compile(
        route: ASHSpatialRouteV2,
        configuration: ASHLUTLockedConfigurationV3
    ) throws -> ASHLUTCompilationV3 {
        let paths = try canonicalPaths()
        guard ASHLUTStateOrdinalTableV3.validStates.count == 256 else {
            throw ASHLUTCompilerErrorV3.entryCountMismatch
        }
        let expectedEntryCount = route.phasePairCount
            * ASHLUTContextV3.allCases.count
            * ASHLUTStateOrdinalTableV3.validStates.count
            * ASHLUTPlaneRoleV3.allCases.count
        var entries: [ASHLUTCompiledEntryV3] = []
        entries.reserveCapacity(expectedEntryCount)
        var pathEvaluationCount = 0

        for planeRole in ASHLUTPlaneRoleV3.allCases {
            for phaseOrdinal in 0..<route.phasePairCount {
                for context in ASHLUTContextV3.allCases {
                    for (stateOrdinal, sourceState) in ASHLUTStateOrdinalTableV3.validStates.enumerated() {
                        let logicalIndex = try logicalIndex(
                            planeRole: planeRole,
                            phaseOrdinal: phaseOrdinal,
                            context: context,
                            validStateOrdinal: stateOrdinal,
                            route: route
                        )
                        entries.append(try compileCell(
                            logicalIndex: logicalIndex,
                            planeRole: planeRole,
                            sourceState: sourceState,
                            validStateOrdinal: UInt16(stateOrdinal),
                            phaseOrdinal: UInt16(phaseOrdinal),
                            context: context,
                            route: route,
                            paths: paths,
                            configuration: configuration
                        ))
                        pathEvaluationCount += paths.count
                    }
                }
            }
        }
        guard entries.count == expectedEntryCount,
              pathEvaluationCount == expectedEntryCount * 81 else {
            throw ASHLUTCompilerErrorV3.entryCountMismatch
        }
        return ASHLUTCompilationV3(
            route: route,
            configuration: configuration,
            entries: entries,
            offlinePathEvaluationCount: pathEvaluationCount,
            runtimeTreeGenerationCount: 0
        )
    }

    private static func compileCell(
        logicalIndex: Int,
        planeRole: ASHLUTPlaneRoleV3,
        sourceState: ASHState,
        validStateOrdinal: UInt16,
        phaseOrdinal: UInt16,
        context: ASHLUTContextV3,
        route: ASHSpatialRouteV2,
        paths: [ASHLUTCanonicalPathV3],
        configuration: ASHLUTLockedConfigurationV3
    ) throws -> ASHLUTCompiledEntryV3 {
        let routeSelection = configuration.routeSelection(for: route)
        let sourceAligned = routeSelection.coordinatePolicy(for: planeRole) == .sourceAlignedRational
            && phaseOrdinal == 0
        if sourceAligned {
            _ = try genericGroups(
                sourceState: sourceState,
                phaseOrdinal: phaseOrdinal,
                route: route,
                paths: paths,
                configuration: configuration
            )
            return sourceAlignedEntry(
                logicalIndex: logicalIndex,
                planeRole: planeRole,
                sourceState: sourceState,
                validStateOrdinal: validStateOrdinal,
                phaseOrdinal: phaseOrdinal,
                context: context,
                routeSelection: routeSelection,
                configuration: configuration
            )
        }
        return try compileGenericCell(
            logicalIndex: logicalIndex,
            planeRole: planeRole,
            sourceState: sourceState,
            validStateOrdinal: validStateOrdinal,
            phaseOrdinal: phaseOrdinal,
            context: context,
            route: route,
            paths: paths,
            configuration: configuration
        )
    }
}

extension ASHLUTLeafCompilerV3 {
    static func compileGenericCell(
        logicalIndex: Int,
        planeRole: ASHLUTPlaneRoleV3,
        sourceState: ASHState,
        validStateOrdinal: UInt16,
        phaseOrdinal: UInt16,
        context: ASHLUTContextV3,
        route: ASHSpatialRouteV2,
        paths: [ASHLUTCanonicalPathV3],
        configuration: ASHLUTLockedConfigurationV3
    ) throws -> ASHLUTCompiledEntryV3 {
        let groups = try genericGroups(
            sourceState: sourceState,
            phaseOrdinal: phaseOrdinal,
            route: route,
            paths: paths,
            configuration: configuration
        )
        let routeSelection = configuration.routeSelection(for: route)
        let ranked = try groups.values.map { group in
            RankedMessageGroup(
                representative: group.representative,
                encodedWeightQ16x16: try encodeMessageWeightQ16x16(group.rawAggregatedWeight)
            )
        }.sorted { lhs, rhs in
            if lhs.encodedWeightQ16x16 != rhs.encodedWeightQ16x16 {
                return lhs.encodedWeightQ16x16 > rhs.encodedWeightQ16x16
            }
            if lhs.representative.penalty != rhs.representative.penalty {
                return lhs.representative.penalty < rhs.representative.penalty
            }
            return lhs.representative.path.message.rawValue < rhs.representative.path.message.rawValue
        }
        let primaryGroup = ranked[0]
        let possibleSecondaryGroup = ranked[1]
        guard primaryGroup.encodedWeightQ16x16 > 0,
              possibleSecondaryGroup.encodedWeightQ16x16 > 0 else {
            throw ASHLUTCompilerErrorV3.noCompatibleCandidate
        }
        let provisionalWeights = normalizedWeights(
            primary: primaryGroup.encodedWeightQ16x16,
            secondary: possibleSecondaryGroup.encodedWeightQ16x16
        )
        let provisionalMargin = provisionalWeights.primary - provisionalWeights.secondary
        let hasSecondary = provisionalMargin < configuration.compilerPolicy.confidenceThresholdUNorm16
        let secondaryGroup = hasSecondary ? possibleSecondaryGroup : nil
        let weights = hasSecondary
            ? provisionalWeights
            : (primary: UInt16.max, secondary: UInt16(0))
        let primary = compiledCandidate(primaryGroup, anchor: sourceState)
        let secondary = secondaryGroup.map { compiledCandidate($0, anchor: sourceState) }
        return ASHLUTCompiledEntryV3(
            logicalIndex: logicalIndex,
            planeRole: planeRole,
            sourceState: sourceState,
            validStateOrdinal: validStateOrdinal,
            phaseOrdinal: phaseOrdinal,
            context: context,
            primary: primary,
            secondary: secondary,
            primaryWeightUNorm16: weights.primary,
            secondaryWeightUNorm16: weights.secondary,
            marginUNorm16: provisionalMargin,
            sourceAlignedExact: false,
            temporalForcedSpatial: context != .spatialOnly,
            parameters: ASHLUTParameterPairV3(
                primary: parameterSlot(
                    candidate: primary,
                    sourceAligned: false,
                    planeRole: planeRole,
                    routeSelection: routeSelection,
                    configuration: configuration
                ),
                secondary: secondary.map {
                    parameterSlot(
                        candidate: $0,
                        sourceAligned: false,
                        planeRole: planeRole,
                        routeSelection: routeSelection,
                        configuration: configuration
                    )
                } ?? .inactive,
                confidenceThresholdUNorm16: configuration.compilerPolicy.confidenceThresholdUNorm16,
                lumaCoordinatePolicy: routeSelection.lumaCoordinatePolicy,
                chromaCoordinatePolicy: routeSelection.chromaCoordinatePolicy,
                boundaryMode: configuration.boundaryMode
            )
        )
    }

    private static func genericGroups(
        sourceState: ASHState,
        phaseOrdinal: UInt16,
        route: ASHSpatialRouteV2,
        paths: [ASHLUTCanonicalPathV3],
        configuration: ASHLUTLockedConfigurationV3
    ) throws -> [UInt8: MessageGroup] {
        let semanticState = try spatialSemanticState(sourceState)
        let baseDescriptor = baseDescriptorID(
            state: semanticState,
            phaseOrdinal: Int(phaseOrdinal),
            route: route,
            spatialPolicyID: configuration.routeSelection(for: route).spatialPolicyID
        )
        let groups = try compatibleGroups(
            sourceState: sourceState,
            semanticState: semanticState,
            baseDescriptor: baseDescriptor,
            phaseOrdinal: phaseOrdinal,
            route: route,
            paths: paths,
            configuration: configuration
        )
        guard groups.count >= 2 else {
            throw ASHLUTCompilerErrorV3.noCompatibleCandidate
        }
        return groups
    }

    private static func compatibleGroups(
        sourceState: ASHState,
        semanticState: ASHState,
        baseDescriptor: UInt8,
        phaseOrdinal: UInt16,
        route: ASHSpatialRouteV2,
        paths: [ASHLUTCanonicalPathV3],
        configuration: ASHLUTLockedConfigurationV3
    ) throws -> [UInt8: MessageGroup] {
        var groups: [UInt8: MessageGroup] = [:]
        for path in paths {
            let codeword = ASHCode.encode(path.message)
            let affine = sourceState.xor(codeword)
            let decoded = ASHCode.decodeAffine(received: affine, anchor: sourceState)
            guard decoded.status == .exact,
                  decoded.messageBits == path.message.bits else {
                throw ASHLUTCompilerErrorV3.affineRecoveryFailed
            }
            let semantics = apply(
                delta: path.semanticDelta,
                to: baseDescriptor,
                parameters: configuration.operatorParameters,
                steps: configuration.semanticSteps
            )
            guard hardCompatible(semantics: semantics, state: semanticState) else {
                continue
            }
            let penalty = compatibilityPenalty(
                path: path,
                baseDescriptorID: baseDescriptor,
                state: semanticState,
                phaseOrdinal: Int(phaseOrdinal),
                route: route,
                policy: configuration.compilerPolicy
            )
            let penaltyIndex = min(Int(penalty), configuration.compilerPolicy.penaltyToWeight.count - 1)
            let weighted = UInt64(path.branchMassNumerator)
                * UInt64(configuration.compilerPolicy.penaltyToWeight[penaltyIndex])
            let candidate = CompatiblePath(
                path: path,
                semantics: semantics,
                penalty: penalty
            )
            if var group = groups[path.message.rawValue] {
                let total = group.rawAggregatedWeight.addingReportingOverflow(weighted)
                guard !total.overflow else { throw ASHLUTCompilerErrorV3.arithmeticOverflow }
                group.rawAggregatedWeight = total.partialValue
                if isBetterRepresentative(candidate, than: group.representative) {
                    group.representative = candidate
                }
                groups[path.message.rawValue] = group
            } else {
                groups[path.message.rawValue] = MessageGroup(
                    representative: candidate,
                    rawAggregatedWeight: weighted
                )
            }
        }
        return groups
    }

    private static func sourceAlignedEntry(
        logicalIndex: Int,
        planeRole: ASHLUTPlaneRoleV3,
        sourceState: ASHState,
        validStateOrdinal: UInt16,
        phaseOrdinal: UInt16,
        context: ASHLUTContextV3,
        routeSelection: ASHLUTLockedRouteSelectionV3,
        configuration: ASHLUTLockedConfigurationV3
    ) -> ASHLUTCompiledEntryV3 {
        let primary = ASHLUTCompiledCandidateV3(
            message: ASHMessage(validatedRawValue: 0),
            affineState: sourceState,
            descriptorID: 0,
            representativePathOrdinal: 0,
            representativePenalty: 0,
            aggregatedWeight: 65_536,
            semanticDelta: ASHLUTSemanticDeltaV3(
                orientation: 0,
                support: 0,
                detail: 0,
                regularization: 0
            ),
            detailGainQ12: 0,
            relaxedLimiterAlphaQ12: 0,
            supportRadiusQ8x8: 512
        )
        return ASHLUTCompiledEntryV3(
            logicalIndex: logicalIndex,
            planeRole: planeRole,
            sourceState: sourceState,
            validStateOrdinal: validStateOrdinal,
            phaseOrdinal: phaseOrdinal,
            context: context,
            primary: primary,
            secondary: nil,
            primaryWeightUNorm16: UInt16.max,
            secondaryWeightUNorm16: 0,
            marginUNorm16: UInt16.max,
            sourceAlignedExact: true,
            temporalForcedSpatial: context != .spatialOnly,
            parameters: ASHLUTParameterPairV3(
                primary: sourcePreservationParameterSlot(
                    planeRole: planeRole,
                    routeSelection: routeSelection,
                    configuration: configuration
                ),
                secondary: .inactive,
                confidenceThresholdUNorm16: configuration.compilerPolicy.confidenceThresholdUNorm16,
                lumaCoordinatePolicy: routeSelection.lumaCoordinatePolicy,
                chromaCoordinatePolicy: routeSelection.chromaCoordinatePolicy,
                boundaryMode: configuration.boundaryMode
            )
        )
    }

}
