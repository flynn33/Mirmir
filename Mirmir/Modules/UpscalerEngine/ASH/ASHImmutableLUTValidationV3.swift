import Foundation

private struct ASHLUTDecodedSecondaryV3 {
    let affineState: ASHState?
    let descriptorID: UInt8?
    let message: ASHMessage?
}

extension ASHLUTBinaryCodecV3 {
    static func decodeEntry(
        _ record: Data,
        logicalIndex: Int,
        route: ASHSpatialRouteV2,
        parameter: ASHLUTParameterPairV3,
        configuration: ASHLUTLockedConfigurationV3
    ) throws -> ASHLUTLoadedEntryV3 {
        let flags = ASHLUTLittleEndianV3.uint16(record, at: 14)
        guard flags & ~ASHLUTBinaryContractV3.permittedEntryFlags == 0,
              flags & ASHLUTBinaryContractV3.entryCompilerFallback == 0 else {
            throw ASHLUTBinaryErrorV3.invalidEntryFlags
        }
        let entriesPerPlane = route.phasePairCount
            * ASHLUTBinaryContractV3.contextCount
            * ASHLUTBinaryContractV3.validStateCount
        let planeOrdinal = logicalIndex / entriesPerPlane
        guard let planeRole = ASHLUTPlaneRoleV3(rawValue: UInt8(planeOrdinal)) else {
            throw ASHLUTBinaryErrorV3.dimensionMismatch
        }
        let withinPlaneIndex = logicalIndex % entriesPerPlane
        let stateOrdinal = withinPlaneIndex % ASHLUTBinaryContractV3.validStateCount
        let phaseAndContext = withinPlaneIndex / ASHLUTBinaryContractV3.validStateCount
        let contextRaw = phaseAndContext % ASHLUTBinaryContractV3.contextCount
        let phaseOrdinal = phaseAndContext / ASHLUTBinaryContractV3.contextCount
        let hasSecondary = flags & ASHLUTBinaryContractV3.entryHasSecondary != 0
        let sourceAlignedExact = configuration.routeSelection(for: route)
            .coordinatePolicy(for: planeRole) == .sourceAlignedRational
            && phaseOrdinal == 0
        var expectedFlags = ASHLUTBinaryContractV3.entryPrimaryExactVerified
        if sourceAlignedExact { expectedFlags |= ASHLUTBinaryContractV3.entrySourceAlignedExact }
        if contextRaw != 0 { expectedFlags |= ASHLUTBinaryContractV3.entryTemporalForcedSpatial }
        if hasSecondary { expectedFlags |= ASHLUTBinaryContractV3.entryHasSecondary | ASHLUTBinaryContractV3.entrySecondaryExactVerified }
        guard flags == expectedFlags else { throw ASHLUTBinaryErrorV3.invalidEntryFlags }

        let primaryAffineRaw = ASHLUTLittleEndianV3.uint16(record, at: 0)
        let primaryDescriptor = record[4]
        let primaryMessageRaw = record[6]
        let primaryWeight = ASHLUTLittleEndianV3.uint16(record, at: 8)
        let secondaryWeight = ASHLUTLittleEndianV3.uint16(record, at: 10)
        let margin = ASHLUTLittleEndianV3.uint16(record, at: 12)
        guard primaryAffineRaw <= ASHState.mask,
              primaryDescriptor < ASHSpatialDescriptorV2.count,
              primaryMessageRaw < 16 else {
            throw ASHLUTBinaryErrorV3.invalidAffine
        }
        let secondary = try decodeSecondary(
            record,
            hasSecondary: hasSecondary,
            parameter: parameter
        )
        try validateParameterFlags(
            parameter,
            primaryDescriptor: primaryDescriptor,
            secondaryDescriptor: secondary.descriptorID,
            sourceAlignedExact: sourceAlignedExact,
            hasSecondary: hasSecondary,
            margin: margin,
            configuration: configuration
        )

        let anchor = ASHLUTStateOrdinalTableV3.validStates[stateOrdinal]
        let primaryAffine = ASHState(validatedRawValue: primaryAffineRaw)
        let primaryMessage = ASHMessage(validatedRawValue: primaryMessageRaw)
        try validateAffine(primaryAffine, message: primaryMessage, anchor: anchor)
        if let secondaryAffineState = secondary.affineState,
           let secondaryMessage = secondary.message {
            try validateAffine(secondaryAffineState, message: secondaryMessage, anchor: anchor)
        }
        if sourceAlignedExact {
            guard primaryAffine == anchor,
                  primaryDescriptor == 0,
                  primaryMessage.rawValue == 0,
                  secondary.affineState == nil,
                  primaryWeight == UInt16.max,
                  secondaryWeight == 0,
                  margin == UInt16.max else {
                throw ASHLUTBinaryErrorV3.invalidSentinel
            }
        }
        try validateCandidateSemantics(
            anchor: anchor,
            planeRole: planeRole,
            phaseOrdinal: phaseOrdinal,
            route: route,
            primaryDescriptor: primaryDescriptor,
            secondaryDescriptor: secondary.descriptorID,
            parameter: parameter,
            sourceAlignedExact: sourceAlignedExact,
            configuration: configuration
        )
        return ASHLUTLoadedEntryV3(
            primaryAffineState: primaryAffine,
            secondaryAffineState: secondary.affineState,
            primaryDescriptorID: primaryDescriptor,
            secondaryDescriptorID: secondary.descriptorID,
            primaryMessage: primaryMessage,
            secondaryMessage: secondary.message,
            primaryWeightUNorm16: primaryWeight,
            secondaryWeightUNorm16: secondaryWeight,
            marginUNorm16: margin,
            flags: flags,
            parameterIndex: ASHLUTLittleEndianV3.uint32(record, at: 16),
            provenanceCRC32: ASHLUTLittleEndianV3.uint32(record, at: 20)
        )
    }

    private static func validateCandidateSemantics(
        anchor: ASHState,
        planeRole: ASHLUTPlaneRoleV3,
        phaseOrdinal: Int,
        route: ASHSpatialRouteV2,
        primaryDescriptor: UInt8,
        secondaryDescriptor: UInt8?,
        parameter: ASHLUTParameterPairV3,
        sourceAlignedExact: Bool,
        configuration: ASHLUTLockedConfigurationV3
    ) throws {
        let semanticState = try spatialSemanticStateForValidation(anchor)
        let baseDescriptor = baseDescriptorForValidation(
            state: semanticState,
            phaseOrdinal: phaseOrdinal,
            route: route,
            spatialPolicyID: configuration.routeSelection(for: route).spatialPolicyID
        )
        guard hardCompatibleForValidation(
                descriptorID: primaryDescriptor,
                slot: parameter.primary,
                state: semanticState
              ),
              secondaryDescriptor.map({ descriptor in
                  hardCompatibleForValidation(
                    descriptorID: descriptor,
                    slot: parameter.secondary,
                    state: semanticState
                  )
              }) ?? true else {
            throw ASHLUTBinaryErrorV3.invalidEntryFlags
        }
        try validate(
            slot: parameter.primary,
            descriptorID: primaryDescriptor,
            baseDescriptorID: baseDescriptor,
            sourceAligned: sourceAlignedExact,
            planeRole: planeRole,
            routeSelection: configuration.routeSelection(for: route),
            configuration: configuration
        )
        if let secondaryDescriptor {
            try validate(
                slot: parameter.secondary,
                descriptorID: secondaryDescriptor,
                baseDescriptorID: baseDescriptor,
                sourceAligned: sourceAlignedExact,
                planeRole: planeRole,
                routeSelection: configuration.routeSelection(for: route),
                configuration: configuration
            )
        }
    }

    private static func decodeSecondary(
        _ record: Data,
        hasSecondary: Bool,
        parameter: ASHLUTParameterPairV3
    ) throws -> ASHLUTDecodedSecondaryV3 {
        let affineRaw = ASHLUTLittleEndianV3.uint16(record, at: 2)
        let descriptor = record[5]
        let messageRaw = record[7]
        let primaryWeight = ASHLUTLittleEndianV3.uint16(record, at: 8)
        let secondaryWeight = ASHLUTLittleEndianV3.uint16(record, at: 10)
        let margin = ASHLUTLittleEndianV3.uint16(record, at: 12)
        if hasSecondary {
            guard affineRaw <= ASHState.mask,
                  descriptor < ASHSpatialDescriptorV2.count,
                  messageRaw < 16,
                  primaryWeight > 0,
                  secondaryWeight > 0,
                  primaryWeight >= secondaryWeight,
                  UInt32(primaryWeight) + UInt32(secondaryWeight) == UInt32(UInt16.max),
                  margin == primaryWeight - secondaryWeight,
                  parameter.secondary.isActive else {
                throw ASHLUTBinaryErrorV3.invalidSentinel
            }
            return ASHLUTDecodedSecondaryV3(
                affineState: ASHState(validatedRawValue: affineRaw),
                descriptorID: descriptor,
                message: ASHMessage(validatedRawValue: messageRaw)
            )
        }
        guard affineRaw == UInt16.max,
              descriptor == UInt8.max,
              messageRaw == UInt8.max,
              primaryWeight == UInt16.max,
              secondaryWeight == 0,
              parameter.secondary == .inactive else {
            throw ASHLUTBinaryErrorV3.invalidSentinel
        }
        return ASHLUTDecodedSecondaryV3(affineState: nil, descriptorID: nil, message: nil)
    }

    private static func validateParameterFlags(
        _ parameter: ASHLUTParameterPairV3,
        primaryDescriptor: UInt8,
        secondaryDescriptor: UInt8?,
        sourceAlignedExact: Bool,
        hasSecondary: Bool,
        margin: UInt16,
        configuration: ASHLUTLockedConfigurationV3
    ) throws {
        guard parameter.primary.isActive,
              parameter.confidenceThresholdUNorm16
                == configuration.compilerPolicy.confidenceThresholdUNorm16,
              parameter.primary.flags & ASHLUTParameterSlotV3.positiveDetailFlag
                == (primaryDescriptor & 0b0100 == 0 ? 0 : ASHLUTParameterSlotV3.positiveDetailFlag),
              parameter.primary.flags & ASHLUTParameterSlotV3.relaxedLimiterFlag
                == (primaryDescriptor & 0b1000 == 0 ? 0 : ASHLUTParameterSlotV3.relaxedLimiterFlag),
              parameter.primary.flags & ASHLUTParameterSlotV3.sourceAlignedPreservationFlag
                == (sourceAlignedExact ? ASHLUTParameterSlotV3.sourceAlignedPreservationFlag : 0),
              hasSecondary
                == (margin < configuration.compilerPolicy.confidenceThresholdUNorm16) else {
            throw ASHLUTBinaryErrorV3.invalidEntryFlags
        }
        guard let secondaryDescriptor else { return }
        guard parameter.secondary.flags & ASHLUTParameterSlotV3.positiveDetailFlag
                == (secondaryDescriptor & 0b0100 == 0 ? 0 : ASHLUTParameterSlotV3.positiveDetailFlag),
              parameter.secondary.flags & ASHLUTParameterSlotV3.relaxedLimiterFlag
                == (secondaryDescriptor & 0b1000 == 0 ? 0 : ASHLUTParameterSlotV3.relaxedLimiterFlag),
              parameter.secondary.flags & ASHLUTParameterSlotV3.sourceAlignedPreservationFlag
                == (sourceAlignedExact ? ASHLUTParameterSlotV3.sourceAlignedPreservationFlag : 0) else {
            throw ASHLUTBinaryErrorV3.invalidEntryFlags
        }
    }

    static func validateAffine(
        _ affine: ASHState,
        message: ASHMessage,
        anchor: ASHState
    ) throws {
        let decoded = ASHCode.decodeAffine(received: affine, anchor: anchor)
        guard decoded.status == .exact else {
            throw ASHLUTBinaryErrorV3.affineDecodeRejected
        }
        guard decoded.messageBits == message.bits else {
            throw ASHLUTBinaryErrorV3.decodedMessageMismatch
        }
    }

    static func validate(
        slot: ASHLUTParameterSlotV3,
        descriptorID: UInt8,
        baseDescriptorID: UInt8,
        sourceAligned: Bool,
        planeRole: ASHLUTPlaneRoleV3,
        routeSelection: ASHLUTLockedRouteSelectionV3,
        configuration: ASHLUTLockedConfigurationV3
    ) throws {
        let locked = configuration.operatorParameters
        let expectedAnisotropyStrength = routeSelection.anisotropyMode(for: planeRole)
            .anisotropyStrengthQ12
        if sourceAligned {
            guard descriptorID == 0,
                  slot.anisotropyStrengthQ12 == expectedAnisotropyStrength,
                  slot.minimumAnisotropicMagnitudeUNorm15 == locked.minimumAnisotropicMagnitudeUNorm15,
                  slot.minimumAnisotropicCoherenceUNorm15 == locked.minimumAnisotropicCoherenceUNorm15,
                  slot.detailGainQ12 == 0,
                  slot.relaxedLimiterAlphaQ12 == 0,
                  slot.riskSuppressionUNorm15 == locked.riskSuppressionUNorm15,
                  slot.supportRadiusQ8x8 == 512,
                  slot.weightEpsilonF32Bits == locked.weightEpsilonF32Bits,
                  slot.delta == ASHLUTSemanticDeltaV3(
                    orientation: 0,
                    support: 0,
                    detail: 0,
                    regularization: 0
                  ),
                  slot.flags == ASHLUTParameterSlotV3.activeFlag
                    | ASHLUTParameterSlotV3.sourceAlignedPreservationFlag else {
                throw ASHLUTBinaryErrorV3.invalidEntryFlags
            }
            return
        }
        let steps = configuration.semanticSteps
        let baseKernel = baseDescriptorID & 0b0001
        let baseSupport = baseDescriptorID & 0b0010
        let baseDetailGain = baseDescriptorID & 0b0100 == 0 ? 0 : locked.detailGainQ12
        let detailGain = adjustedForValidation(
            baseDetailGain,
            delta: slot.delta.detail,
            step: steps.detailGainStepQ12,
            range: 0...2_048
        )
        let baseAlpha = baseDescriptorID & 0b1000 == 0 ? 0 : locked.relaxedLimiterAlphaQ12
        let alpha = adjustedForValidation(
            baseAlpha,
            delta: -slot.delta.regularization,
            step: steps.regularizationStepQ12,
            range: 0...1_024
        )
        let supportRadius = adjustedForValidation(
            baseKernel == 0 ? 512 : 768,
            delta: slot.delta.support,
            step: steps.supportRadiusStepQ8x8,
            range: 256...768
        )
        let expectedDescriptor = baseKernel
            | baseSupport
            | (detailGain > 0 ? 0b0100 : 0)
            | (alpha > 0 ? 0b1000 : 0)
        var expectedFlags = ASHLUTParameterSlotV3.activeFlag
        if detailGain > 0 { expectedFlags |= ASHLUTParameterSlotV3.positiveDetailFlag }
        if alpha > 0 { expectedFlags |= ASHLUTParameterSlotV3.relaxedLimiterFlag }
        guard descriptorID == expectedDescriptor,
              slot.anisotropyStrengthQ12 == expectedAnisotropyStrength,
              slot.minimumAnisotropicMagnitudeUNorm15 == locked.minimumAnisotropicMagnitudeUNorm15,
              slot.minimumAnisotropicCoherenceUNorm15 == locked.minimumAnisotropicCoherenceUNorm15,
              slot.detailGainQ12 == detailGain,
              slot.relaxedLimiterAlphaQ12 == alpha,
              slot.riskSuppressionUNorm15 == locked.riskSuppressionUNorm15,
              slot.supportRadiusQ8x8 == supportRadius,
              slot.weightEpsilonF32Bits == locked.weightEpsilonF32Bits,
              slot.flags == expectedFlags else {
            throw ASHLUTBinaryErrorV3.invalidEntryFlags
        }
    }

    static func spatialSemanticStateForValidation(_ sourceState: ASHState) throws -> ASHState {
        var payload = Array(sourceState.bits.prefix(ASHState.payloadBitCount))
        payload[6] = 0
        return try ASHState(payloadBits: payload)
    }

    static func baseDescriptorForValidation(
        state: ASHState,
        phaseOrdinal: Int,
        route: ASHSpatialRouteV2,
        spatialPolicyID: UInt8
    ) -> UInt8 {
        let orientationPhase = state.bit(coordinate: 1) ^ state.bit(coordinate: 2)
        let edge = state.bit(coordinate: 3)
        let coherent = state.bit(coordinate: 4)
        let texture = state.bit(coordinate: 5)
        let risk = state.bit(coordinate: 6)
        let chromaAligned = state.bit(coordinate: 8)
        let horizontal = phaseOrdinal % route.scaleNumerator
        let vertical = phaseOrdinal / route.scaleNumerator
        let phaseHalfCycle = ((2 * horizontal >= route.scaleNumerator) ? 1 : 0)
            ^ ((2 * vertical >= route.scaleNumerator) ? 1 : 0)
        guard ASHLUTLockedRouteSelectionV3.admissibleSpatialPolicyIDs.contains(spatialPolicyID) else {
            preconditionFailure("validated spatial policy is inadmissible")
        }
        let kernelRule = Int(spatialPolicyID) / 16
        let supportRule = (Int(spatialPolicyID) % 16) / 4
        let detailRule = (Int(spatialPolicyID) % 4) / 2
        let limiterRule = Int(spatialPolicyID) % 2
        let orientedEdge = edge & orientationPhase
        let kernel: Int
        switch kernelRule {
        case 0: kernel = texture ^ orientedEdge ^ phaseHalfCycle
        case 1: kernel = texture ^ orientedEdge
        case 2: kernel = texture | orientedEdge
        default: preconditionFailure("invalid kernel rule")
        }
        let edgeCoherence = edge & coherent
        let support: Int
        switch supportRule {
        case 0: support = edgeCoherence
        case 1: support = edgeCoherence & (1 - risk)
        case 2: support = edgeCoherence & (1 - texture)
        case 3: support = edgeCoherence & (1 - risk) & (1 - texture)
        default: preconditionFailure("invalid support rule")
        }
        let detail = detailRule == 0
            ? edge & texture & (1 - risk)
            : texture & (1 - risk)
        let limiter = limiterRule == 0
            ? chromaAligned & (1 - risk)
            : chromaAligned
        return UInt8(kernel | (support << 1) | (detail << 2) | (limiter << 3))
    }

    static func hardCompatibleForValidation(
        descriptorID: UInt8,
        slot: ASHLUTParameterSlotV3,
        state: ASHState
    ) -> Bool {
        let edge = state.bit(coordinate: 3)
        let coherent = state.bit(coordinate: 4)
        let risk = state.bit(coordinate: 6)
        let chromaAligned = state.bit(coordinate: 8)
        if descriptorID & 0b0010 != 0, edge == 0, coherent == 0 { return false }
        if slot.detailGainQ12 > 0, risk == 1 { return false }
        if slot.relaxedLimiterAlphaQ12 > 0, chromaAligned == 0 { return false }
        return true
    }

    static func validateForcedSpatialContextMirrors(
        _ entries: [ASHLUTLoadedEntryV3],
        route: ASHSpatialRouteV2
    ) throws {
        let entriesPerPlane = route.phasePairCount
            * ASHLUTBinaryContractV3.contextCount
            * ASHLUTBinaryContractV3.validStateCount
        for plane in 0..<ASHLUTBinaryContractV3.planeCount {
            for phase in 0..<route.phasePairCount {
                let phaseBase = plane * entriesPerPlane
                    + phase * ASHLUTBinaryContractV3.contextCount
                    * ASHLUTBinaryContractV3.validStateCount
                for stateOrdinal in 0..<ASHLUTBinaryContractV3.validStateCount {
                    let spatial = entries[phaseBase + stateOrdinal]
                    for context in 1..<ASHLUTBinaryContractV3.contextCount {
                        let temporal = entries[
                            phaseBase + (context * ASHLUTBinaryContractV3.validStateCount)
                                + stateOrdinal
                        ]
                        guard spatial.primaryAffineState == temporal.primaryAffineState,
                          spatial.secondaryAffineState == temporal.secondaryAffineState,
                          spatial.primaryDescriptorID == temporal.primaryDescriptorID,
                          spatial.secondaryDescriptorID == temporal.secondaryDescriptorID,
                          spatial.primaryMessage == temporal.primaryMessage,
                          spatial.secondaryMessage == temporal.secondaryMessage,
                          spatial.primaryWeightUNorm16 == temporal.primaryWeightUNorm16,
                          spatial.secondaryWeightUNorm16 == temporal.secondaryWeightUNorm16,
                          spatial.marginUNorm16 == temporal.marginUNorm16,
                              spatial.parameterIndex == temporal.parameterIndex else {
                            throw ASHLUTBinaryErrorV3.invalidEntryFlags
                        }
                    }
                }
            }
        }
    }
    static func decodeParameter(
        _ record: Data,
        route: ASHSpatialRouteV2,
        configuration: ASHLUTLockedConfigurationV3
    ) throws -> ASHLUTParameterPairV3 {
        guard record[52] == 1,
              record[53] == 0,
              record[55..<60].allSatisfy({ $0 == 0 }) else {
            throw ASHLUTBinaryErrorV3.reservedNonzero
        }
        let lumaCoordinatePolicy = try decodeCoordinatePolicy(record[50])
        let chromaCoordinatePolicy = try decodeCoordinatePolicy(record[54])
        let boundaryMode: ASHSpatialBoundaryModeV2
        switch record[51] {
        case 0: boundaryMode = .clamp
        case 1: boundaryMode = .mirrorReflect101
        default: throw ASHLUTBinaryErrorV3.reservedNonzero
        }
        let selection = configuration.routeSelection(for: route)
        guard lumaCoordinatePolicy == selection.lumaCoordinatePolicy,
              chromaCoordinatePolicy == selection.chromaCoordinatePolicy,
              boundaryMode == configuration.boundaryMode else {
            throw ASHLUTBinaryErrorV3.inputHashMismatch
        }
        return ASHLUTParameterPairV3(
            primary: try decodeSlot(record, offset: 0, requiresActive: true),
            secondary: try decodeSlot(record, offset: 24, requiresActive: false),
            confidenceThresholdUNorm16: ASHLUTLittleEndianV3.uint16(record, at: 48),
            lumaCoordinatePolicy: lumaCoordinatePolicy,
            chromaCoordinatePolicy: chromaCoordinatePolicy,
            boundaryMode: boundaryMode
        )
    }

    private static func decodeCoordinatePolicy(
        _ byte: UInt8
    ) throws -> ASHSpatialCoordinatePolicyV2 {
        switch byte {
        case 0: .halfPixelCenter
        case 1: .sourceAlignedRational
        default: throw ASHLUTBinaryErrorV3.reservedNonzero
        }
    }

    static func decodeSlot(
        _ record: Data,
        offset: Int,
        requiresActive: Bool
    ) throws -> ASHLUTParameterSlotV3 {
        let bytes = Data(record[offset..<(offset + 24)])
        if bytes.allSatisfy({ $0 == 0 }) {
            guard !requiresActive else { throw ASHLUTBinaryErrorV3.invalidEntryFlags }
            return .inactive
        }
        let flags = ASHLUTLittleEndianV3.uint16(record, at: offset + 22)
        let allowedFlags = ASHLUTParameterSlotV3.activeFlag
            | ASHLUTParameterSlotV3.positiveDetailFlag
            | ASHLUTParameterSlotV3.relaxedLimiterFlag
            | ASHLUTParameterSlotV3.sourceAlignedPreservationFlag
        guard flags & ~allowedFlags == 0,
              flags & ASHLUTParameterSlotV3.activeFlag != 0,
              flags & ASHLUTParameterSlotV3.temporalContributionFlag == 0,
              flags & ASHLUTParameterSlotV3.denoisingFlag == 0 else {
            throw ASHLUTBinaryErrorV3.invalidEntryFlags
        }
        let minimumMagnitude = ASHLUTLittleEndianV3.uint16(record, at: offset + 2)
        let minimumCoherence = ASHLUTLittleEndianV3.uint16(record, at: offset + 4)
        let risk = ASHLUTLittleEndianV3.uint16(record, at: offset + 10)
        let epsilonBits = ASHLUTLittleEndianV3.uint32(record, at: offset + 14)
        let epsilon = Float(bitPattern: epsilonBits)
        guard minimumMagnitude <= 32_767,
              minimumCoherence <= 32_767,
              risk <= 32_767,
              epsilon.isFinite,
              epsilon > 0 else {
            throw ASHLUTBinaryErrorV3.invalidEntryFlags
        }
        let delta = ASHLUTSemanticDeltaV3(
            orientation: Int8(bitPattern: record[offset + 18]),
            support: Int8(bitPattern: record[offset + 19]),
            detail: Int8(bitPattern: record[offset + 20]),
            regularization: Int8(bitPattern: record[offset + 21])
        )
        guard [delta.orientation, delta.support, delta.detail, delta.regularization]
            .allSatisfy({ (-1...1).contains($0) }) else {
            throw ASHLUTBinaryErrorV3.invalidEntryFlags
        }
        return ASHLUTParameterSlotV3(
            anisotropyStrengthQ12: ASHLUTLittleEndianV3.uint16(record, at: offset),
            minimumAnisotropicMagnitudeUNorm15: minimumMagnitude,
            minimumAnisotropicCoherenceUNorm15: minimumCoherence,
            detailGainQ12: ASHLUTLittleEndianV3.uint16(record, at: offset + 6),
            relaxedLimiterAlphaQ12: ASHLUTLittleEndianV3.uint16(record, at: offset + 8),
            riskSuppressionUNorm15: risk,
            supportRadiusQ8x8: ASHLUTLittleEndianV3.uint16(record, at: offset + 12),
            weightEpsilonF32Bits: epsilonBits,
            delta: delta,
            flags: flags
        )
    }

}
