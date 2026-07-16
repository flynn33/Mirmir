import Foundation

extension ASHLUTLeafCompilerV3 {
    static func spatialSemanticState(_ sourceState: ASHState) throws -> ASHState {
        var payload = Array(sourceState.bits.prefix(ASHState.payloadBitCount))
        payload[6] = 0
        return try ASHState(payloadBits: payload)
    }

    static func baseDescriptorID(
        state: ASHState,
        phaseOrdinal: Int,
        route: ASHSpatialRouteV2,
        spatialPolicyID: UInt8
    ) -> UInt8 {
        precondition(ASHLUTLockedRouteSelectionV3.admissibleSpatialPolicyIDs.contains(spatialPolicyID))
        let orientationPhase = state.bit(coordinate: 1) ^ state.bit(coordinate: 2)
        let edge = state.bit(coordinate: 3)
        let coherent = state.bit(coordinate: 4)
        let texture = state.bit(coordinate: 5)
        let risk = state.bit(coordinate: 6)
        let chromaAligned = state.bit(coordinate: 8)
        let phase = phaseComponents(ordinal: phaseOrdinal, route: route)
        let phaseInfluence = ((2 * phase.horizontal >= route.scaleNumerator) ? 1 : 0)
            ^ ((2 * phase.vertical >= route.scaleNumerator) ? 1 : 0)
        let kernelRule = Int(spatialPolicyID) / 16
        let supportRule = (Int(spatialPolicyID) % 16) / 4
        let detailRule = (Int(spatialPolicyID) % 4) / 2
        let limiterRule = Int(spatialPolicyID) % 2
        let orientedEdge = edge & orientationPhase
        let kernel: Int
        switch kernelRule {
        case 0: kernel = texture ^ orientedEdge ^ phaseInfluence
        case 1: kernel = texture ^ orientedEdge
        case 2: kernel = texture | orientedEdge
        default: preconditionFailure("validated spatial policy has invalid kernel rule")
        }
        let edgeCoherence = edge & coherent
        let support: Int
        switch supportRule {
        case 0: support = edgeCoherence
        case 1: support = edgeCoherence & (1 - risk)
        case 2: support = edgeCoherence & (1 - texture)
        case 3: support = edgeCoherence & (1 - risk) & (1 - texture)
        default: preconditionFailure("validated spatial policy has invalid support rule")
        }
        let detail = detailRule == 0
            ? edge & texture & (1 - risk)
            : texture & (1 - risk)
        let limiter = limiterRule == 0
            ? chromaAligned & (1 - risk)
            : chromaAligned
        return UInt8(kernel | (support << 1) | (detail << 2) | (limiter << 3))
    }

    static func apply(
        delta: ASHLUTSemanticDeltaV3,
        to baseDescriptorID: UInt8,
        parameters: ASHLUTLockedOperatorParametersV3,
        steps: ASHLUTLockedSemanticStepsV3
    ) -> ResolvedSemantics {
        let baseKernel = Int(baseDescriptorID & 0b0001)
        let baseSupport = Int((baseDescriptorID >> 1) & 1)
        let baseDetailGain = baseDescriptorID & 0b0100 == 0 ? 0 : parameters.detailGainQ12
        let baseLimiterAlpha = baseDescriptorID & 0b1000 == 0 ? 0 : parameters.relaxedLimiterAlphaQ12
        let detailGain = adjusted(
            baseDetailGain,
            delta: delta.detail,
            step: steps.detailGainStepQ12,
            range: 0...2_048
        )
        let limiterAlpha = adjusted(
            baseLimiterAlpha,
            delta: -delta.regularization,
            step: steps.regularizationStepQ12,
            range: 0...1_024
        )
        let detail = detailGain > 0 ? 1 : 0
        let limiter = limiterAlpha > 0 ? 1 : 0
        let supportRadius = adjusted(
            baseKernel == 0 ? 512 : 768,
            delta: delta.support,
            step: steps.supportRadiusStepQ8x8,
            range: 256...768
        )
        return ResolvedSemantics(
            descriptorID: UInt8(baseKernel | (baseSupport << 1) | (detail << 2) | (limiter << 3)),
            detailGainQ12: detailGain,
            relaxedLimiterAlphaQ12: limiterAlpha,
            supportRadiusQ8x8: supportRadius
        )
    }

    static func hardCompatible(semantics: ResolvedSemantics, state: ASHState) -> Bool {
        let edge = state.bit(coordinate: 3)
        let coherent = state.bit(coordinate: 4)
        let risk = state.bit(coordinate: 6)
        let chromaAligned = state.bit(coordinate: 8)
        let usesSupport = semantics.descriptorID & 0b0010 != 0
        if usesSupport, edge == 0, coherent == 0 { return false }
        if semantics.detailGainQ12 > 0, risk == 1 { return false }
        if semantics.relaxedLimiterAlphaQ12 > 0, chromaAligned == 0 { return false }
        return true
    }

    static func compatibilityPenalty(
        path: ASHLUTCanonicalPathV3,
        baseDescriptorID: UInt8,
        state: ASHState,
        phaseOrdinal: Int,
        route: ASHSpatialRouteV2,
        policy: ASHLUTLockedCompilerPolicyV3
    ) -> UInt16 {
        var penalty: UInt16 = 0
        func add(_ term: UInt16) {
            let sum = penalty.addingReportingOverflow(term)
            penalty = sum.overflow ? UInt16.max : sum.partialValue
        }
        func scaledMagnitude(_ delta: Int8, _ step: UInt16) -> UInt16 {
            let product = UInt32(abs(Int(delta))) * UInt32(step)
            return UInt16(min(UInt32(UInt16.max), product))
        }
        add(scaledMagnitude(path.semanticDelta.orientation, policy.orientationPenaltyStep))
        add(scaledMagnitude(path.semanticDelta.support, policy.supportPenaltyStep))
        add(scaledMagnitude(path.semanticDelta.detail, policy.detailPenaltyStep))
        add(scaledMagnitude(path.semanticDelta.regularization, policy.regularizationPenaltyStep))
        let frozenSupportPredicate = state.bit(coordinate: 3) == 1
            && state.bit(coordinate: 4) == 1
        let baseDetail = baseDescriptorID & 0b0100 != 0
        if path.semanticDelta.support > 0, !frozenSupportPredicate {
            add(policy.unsupportedSupportExpansionPenalty)
        }
        if path.semanticDelta.support < 0, frozenSupportPredicate {
            add(policy.coherentSupportReductionPenalty)
        }
        if path.semanticDelta.detail > 0, state.bit(coordinate: 5) == 0 {
            add(policy.unsupportedDetailIncreasePenalty)
        }
        if path.semanticDelta.detail < 0, baseDetail {
            add(policy.supportedDetailReductionPenalty)
        }
        if path.semanticDelta.regularization < 0,
           state.bit(coordinate: 6) == 1 || state.bit(coordinate: 8) == 0 {
            add(policy.relaxationUnderRiskPenalty)
        }
        let phase = phaseComponents(ordinal: phaseOrdinal, route: route)
        let phaseHalfCycle = ((2 * phase.horizontal >= route.scaleNumerator) ? 1 : 0)
            ^ ((2 * phase.vertical >= route.scaleNumerator) ? 1 : 0)
        if Int(baseDescriptorID & 0b0001) != phaseHalfCycle {
            add(policy.phaseKernelMismatchPenalty)
        }
        return penalty
    }

    static func isBetterRepresentative(
        _ candidate: CompatiblePath,
        than current: CompatiblePath
    ) -> Bool {
        if candidate.penalty != current.penalty { return candidate.penalty < current.penalty }
        if candidate.path.branchMassNumerator != current.path.branchMassNumerator {
            return candidate.path.branchMassNumerator > current.path.branchMassNumerator
        }
        return candidate.path.ordinal < current.path.ordinal
    }

    static func compiledCandidate(
        _ group: RankedMessageGroup,
        anchor: ASHState
    ) -> ASHLUTCompiledCandidateV3 {
        let representative = group.representative
        return ASHLUTCompiledCandidateV3(
            message: representative.path.message,
            affineState: anchor.xor(ASHCode.encode(representative.path.message)),
            descriptorID: representative.semantics.descriptorID,
            representativePathOrdinal: representative.path.ordinal,
            representativePenalty: representative.penalty,
            aggregatedWeight: group.encodedWeightQ16x16,
            semanticDelta: representative.path.semanticDelta,
            detailGainQ12: representative.semantics.detailGainQ12,
            relaxedLimiterAlphaQ12: representative.semantics.relaxedLimiterAlphaQ12,
            supportRadiusQ8x8: representative.semantics.supportRadiusQ8x8
        )
    }

    static func encodeMessageWeightQ16x16(_ rawWeight: UInt64) throws -> UInt32 {
        let scale: UInt64 = 65_536
        let denominator: UInt64 = 256 * UInt64(UInt16.max)
        let product = rawWeight.multipliedReportingOverflow(by: scale)
        guard !product.overflow else { throw ASHLUTCompilerErrorV3.arithmeticOverflow }
        let rounded = product.partialValue.addingReportingOverflow(denominator / 2)
        guard !rounded.overflow else { throw ASHLUTCompilerErrorV3.arithmeticOverflow }
        let encoded = rounded.partialValue / denominator
        guard let result = UInt32(exactly: encoded), result > 0 else {
            throw ASHLUTCompilerErrorV3.arithmeticOverflow
        }
        return result
    }

    static func normalizedWeights(
        primary: UInt32,
        secondary: UInt32
    ) -> (primary: UInt16, secondary: UInt16) {
        let total = UInt64(primary) + UInt64(secondary)
        let primaryWeight = UInt16(
            min(UInt64(UInt16.max), ((UInt64(primary) * UInt64(UInt16.max)) + (total / 2)) / total)
        )
        return (primaryWeight, UInt16.max - primaryWeight)
    }

    static func parameterSlot(
        candidate: ASHLUTCompiledCandidateV3,
        sourceAligned: Bool,
        planeRole: ASHLUTPlaneRoleV3,
        routeSelection: ASHLUTLockedRouteSelectionV3,
        configuration: ASHLUTLockedConfigurationV3
    ) -> ASHLUTParameterSlotV3 {
        let parameters = configuration.operatorParameters
        var flags = ASHLUTParameterSlotV3.activeFlag
        if candidate.descriptorID & 0b0100 != 0 { flags |= ASHLUTParameterSlotV3.positiveDetailFlag }
        if candidate.descriptorID & 0b1000 != 0 { flags |= ASHLUTParameterSlotV3.relaxedLimiterFlag }
        if sourceAligned { flags |= ASHLUTParameterSlotV3.sourceAlignedPreservationFlag }
        return ASHLUTParameterSlotV3(
            anisotropyStrengthQ12: routeSelection.anisotropyMode(for: planeRole)
                .anisotropyStrengthQ12,
            minimumAnisotropicMagnitudeUNorm15: parameters.minimumAnisotropicMagnitudeUNorm15,
            minimumAnisotropicCoherenceUNorm15: parameters.minimumAnisotropicCoherenceUNorm15,
            detailGainQ12: candidate.detailGainQ12,
            relaxedLimiterAlphaQ12: candidate.relaxedLimiterAlphaQ12,
            riskSuppressionUNorm15: parameters.riskSuppressionUNorm15,
            supportRadiusQ8x8: candidate.supportRadiusQ8x8,
            weightEpsilonF32Bits: parameters.weightEpsilonF32Bits,
            delta: candidate.semanticDelta,
            flags: flags
        )
    }

    static func sourcePreservationParameterSlot(
        planeRole: ASHLUTPlaneRoleV3,
        routeSelection: ASHLUTLockedRouteSelectionV3,
        configuration: ASHLUTLockedConfigurationV3
    ) -> ASHLUTParameterSlotV3 {
        let parameters = configuration.operatorParameters
        return ASHLUTParameterSlotV3(
            anisotropyStrengthQ12: routeSelection.anisotropyMode(for: planeRole)
                .anisotropyStrengthQ12,
            minimumAnisotropicMagnitudeUNorm15: parameters.minimumAnisotropicMagnitudeUNorm15,
            minimumAnisotropicCoherenceUNorm15: parameters.minimumAnisotropicCoherenceUNorm15,
            detailGainQ12: 0,
            relaxedLimiterAlphaQ12: 0,
            riskSuppressionUNorm15: parameters.riskSuppressionUNorm15,
            supportRadiusQ8x8: 512,
            weightEpsilonF32Bits: parameters.weightEpsilonF32Bits,
            delta: ASHLUTSemanticDeltaV3(
                orientation: 0,
                support: 0,
                detail: 0,
                regularization: 0
            ),
            flags: ASHLUTParameterSlotV3.activeFlag
                | ASHLUTParameterSlotV3.sourceAlignedPreservationFlag
        )
    }

    static func adjusted(
        _ base: UInt16,
        delta: Int8,
        step: UInt16,
        range: ClosedRange<Int>
    ) -> UInt16 {
        let value = Int(base) + (Int(delta) * Int(step))
        return UInt16(min(range.upperBound, max(range.lowerBound, value)))
    }

    static func phaseComponents(
        ordinal: Int,
        route: ASHSpatialRouteV2
    ) -> (horizontal: Int, vertical: Int) {
        (ordinal % route.scaleNumerator, ordinal / route.scaleNumerator)
    }

}
