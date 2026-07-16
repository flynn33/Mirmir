import Foundation

private struct ASHLUTDecodedSecondaryV2 {
    let affineState: ASHState?
    let descriptorID: UInt8?
    let message: ASHMessage?
}

extension ASHLUTBinaryCodecV2 {
    static func decodeEntry(
        _ record: Data,
        logicalIndex: Int,
        route: ASHSpatialRouteV2,
        parameter: ASHLUTParameterPairV2,
        configuration: ASHLUTLockedConfigurationV2
    ) throws -> ASHLUTLoadedEntryV2 {
        let flags = ASHLUTLittleEndianV2.uint16(record, at: 14)
        guard flags & ~ASHLUTBinaryContractV2.permittedEntryFlags == 0,
              flags & ASHLUTBinaryContractV2.entryCompilerFallback == 0 else {
            throw ASHLUTBinaryErrorV2.invalidEntryFlags
        }
        let stateOrdinal = logicalIndex % ASHLUTBinaryContractV2.validStateCount
        let phaseAndContext = logicalIndex / ASHLUTBinaryContractV2.validStateCount
        let contextRaw = phaseAndContext % ASHLUTBinaryContractV2.contextCount
        let phaseOrdinal = phaseAndContext / ASHLUTBinaryContractV2.contextCount
        let hasSecondary = flags & ASHLUTBinaryContractV2.entryHasSecondary != 0
        let sourceAlignedExact = configuration.routeSelection(for: route)
            .bothPlanesAreSourceAligned
            && phaseOrdinal == 0
        var expectedFlags = ASHLUTBinaryContractV2.entryPrimaryExactVerified
        if sourceAlignedExact { expectedFlags |= ASHLUTBinaryContractV2.entrySourceAlignedExact }
        if contextRaw != 0 { expectedFlags |= ASHLUTBinaryContractV2.entryTemporalForcedSpatial }
        if hasSecondary { expectedFlags |= ASHLUTBinaryContractV2.entryHasSecondary | ASHLUTBinaryContractV2.entrySecondaryExactVerified }
        guard flags == expectedFlags else { throw ASHLUTBinaryErrorV2.invalidEntryFlags }

        let primaryAffineRaw = ASHLUTLittleEndianV2.uint16(record, at: 0)
        let primaryDescriptor = record[4]
        let primaryMessageRaw = record[6]
        let primaryWeight = ASHLUTLittleEndianV2.uint16(record, at: 8)
        let secondaryWeight = ASHLUTLittleEndianV2.uint16(record, at: 10)
        let margin = ASHLUTLittleEndianV2.uint16(record, at: 12)
        guard primaryAffineRaw <= ASHState.mask,
              primaryDescriptor < ASHSpatialDescriptorV2.count,
              primaryMessageRaw < 16 else {
            throw ASHLUTBinaryErrorV2.invalidAffine
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

        let anchor = ASHLUTStateOrdinalTableV2.validStates[stateOrdinal]
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
                throw ASHLUTBinaryErrorV2.invalidSentinel
            }
        }
        try validateCandidateSemantics(
            anchor: anchor,
            phaseOrdinal: phaseOrdinal,
            route: route,
            primaryDescriptor: primaryDescriptor,
            secondaryDescriptor: secondary.descriptorID,
            parameter: parameter,
            sourceAlignedExact: sourceAlignedExact,
            configuration: configuration
        )
        return ASHLUTLoadedEntryV2(
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
            parameterIndex: ASHLUTLittleEndianV2.uint32(record, at: 16),
            provenanceCRC32: ASHLUTLittleEndianV2.uint32(record, at: 20)
        )
    }

    private static func validateCandidateSemantics(
        anchor: ASHState,
        phaseOrdinal: Int,
        route: ASHSpatialRouteV2,
        primaryDescriptor: UInt8,
        secondaryDescriptor: UInt8?,
        parameter: ASHLUTParameterPairV2,
        sourceAlignedExact: Bool,
        configuration: ASHLUTLockedConfigurationV2
    ) throws {
        let semanticState = try spatialSemanticStateForValidation(anchor)
        let baseDescriptor = baseDescriptorForValidation(
            state: semanticState,
            phaseOrdinal: phaseOrdinal,
            route: route
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
            throw ASHLUTBinaryErrorV2.invalidEntryFlags
        }
        try validate(
            slot: parameter.primary,
            descriptorID: primaryDescriptor,
            baseDescriptorID: baseDescriptor,
            sourceAligned: sourceAlignedExact,
            configuration: configuration
        )
        if let secondaryDescriptor {
            try validate(
                slot: parameter.secondary,
                descriptorID: secondaryDescriptor,
                baseDescriptorID: baseDescriptor,
                sourceAligned: sourceAlignedExact,
                configuration: configuration
            )
        }
    }

    private static func decodeSecondary(
        _ record: Data,
        hasSecondary: Bool,
        parameter: ASHLUTParameterPairV2
    ) throws -> ASHLUTDecodedSecondaryV2 {
        let affineRaw = ASHLUTLittleEndianV2.uint16(record, at: 2)
        let descriptor = record[5]
        let messageRaw = record[7]
        let primaryWeight = ASHLUTLittleEndianV2.uint16(record, at: 8)
        let secondaryWeight = ASHLUTLittleEndianV2.uint16(record, at: 10)
        let margin = ASHLUTLittleEndianV2.uint16(record, at: 12)
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
                throw ASHLUTBinaryErrorV2.invalidSentinel
            }
            return ASHLUTDecodedSecondaryV2(
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
            throw ASHLUTBinaryErrorV2.invalidSentinel
        }
        return ASHLUTDecodedSecondaryV2(affineState: nil, descriptorID: nil, message: nil)
    }

    private static func validateParameterFlags(
        _ parameter: ASHLUTParameterPairV2,
        primaryDescriptor: UInt8,
        secondaryDescriptor: UInt8?,
        sourceAlignedExact: Bool,
        hasSecondary: Bool,
        margin: UInt16,
        configuration: ASHLUTLockedConfigurationV2
    ) throws {
        guard parameter.primary.isActive,
              parameter.confidenceThresholdUNorm16
                == configuration.compilerPolicy.confidenceThresholdUNorm16,
              parameter.primary.flags & ASHLUTParameterSlotV2.positiveDetailFlag
                == (primaryDescriptor & 0b0100 == 0 ? 0 : ASHLUTParameterSlotV2.positiveDetailFlag),
              parameter.primary.flags & ASHLUTParameterSlotV2.relaxedLimiterFlag
                == (primaryDescriptor & 0b1000 == 0 ? 0 : ASHLUTParameterSlotV2.relaxedLimiterFlag),
              parameter.primary.flags & ASHLUTParameterSlotV2.sourceAlignedPreservationFlag
                == (sourceAlignedExact ? ASHLUTParameterSlotV2.sourceAlignedPreservationFlag : 0),
              hasSecondary
                == (margin < configuration.compilerPolicy.confidenceThresholdUNorm16) else {
            throw ASHLUTBinaryErrorV2.invalidEntryFlags
        }
        guard let secondaryDescriptor else { return }
        guard parameter.secondary.flags & ASHLUTParameterSlotV2.positiveDetailFlag
                == (secondaryDescriptor & 0b0100 == 0 ? 0 : ASHLUTParameterSlotV2.positiveDetailFlag),
              parameter.secondary.flags & ASHLUTParameterSlotV2.relaxedLimiterFlag
                == (secondaryDescriptor & 0b1000 == 0 ? 0 : ASHLUTParameterSlotV2.relaxedLimiterFlag),
              parameter.secondary.flags & ASHLUTParameterSlotV2.sourceAlignedPreservationFlag
                == (sourceAlignedExact ? ASHLUTParameterSlotV2.sourceAlignedPreservationFlag : 0) else {
            throw ASHLUTBinaryErrorV2.invalidEntryFlags
        }
    }

    static func validateAffine(
        _ affine: ASHState,
        message: ASHMessage,
        anchor: ASHState
    ) throws {
        let decoded = ASHCode.decodeAffine(received: affine, anchor: anchor)
        guard decoded.status == .exact else {
            throw ASHLUTBinaryErrorV2.affineDecodeRejected
        }
        guard decoded.messageBits == message.bits else {
            throw ASHLUTBinaryErrorV2.decodedMessageMismatch
        }
    }

    static func validate(
        slot: ASHLUTParameterSlotV2,
        descriptorID: UInt8,
        baseDescriptorID: UInt8,
        sourceAligned: Bool,
        configuration: ASHLUTLockedConfigurationV2
    ) throws {
        let locked = configuration.operatorParameters
        if sourceAligned {
            guard descriptorID == 0,
                  slot.anisotropyStrengthQ12 == locked.anisotropyStrengthQ12,
                  slot.minimumAnisotropicMagnitudeUNorm15 == locked.minimumAnisotropicMagnitudeUNorm15,
                  slot.minimumAnisotropicCoherenceUNorm15 == locked.minimumAnisotropicCoherenceUNorm15,
                  slot.detailGainQ12 == 0,
                  slot.relaxedLimiterAlphaQ12 == 0,
                  slot.riskSuppressionUNorm15 == locked.riskSuppressionUNorm15,
                  slot.supportRadiusQ8x8 == 512,
                  slot.weightEpsilonF32Bits == locked.weightEpsilonF32Bits,
                  slot.delta == ASHLUTSemanticDeltaV2(
                    orientation: 0,
                    support: 0,
                    detail: 0,
                    regularization: 0
                  ),
                  slot.flags == ASHLUTParameterSlotV2.activeFlag
                    | ASHLUTParameterSlotV2.sourceAlignedPreservationFlag else {
                throw ASHLUTBinaryErrorV2.invalidEntryFlags
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
        var expectedFlags = ASHLUTParameterSlotV2.activeFlag
        if detailGain > 0 { expectedFlags |= ASHLUTParameterSlotV2.positiveDetailFlag }
        if alpha > 0 { expectedFlags |= ASHLUTParameterSlotV2.relaxedLimiterFlag }
        guard descriptorID == expectedDescriptor,
              slot.anisotropyStrengthQ12 == locked.anisotropyStrengthQ12,
              slot.minimumAnisotropicMagnitudeUNorm15 == locked.minimumAnisotropicMagnitudeUNorm15,
              slot.minimumAnisotropicCoherenceUNorm15 == locked.minimumAnisotropicCoherenceUNorm15,
              slot.detailGainQ12 == detailGain,
              slot.relaxedLimiterAlphaQ12 == alpha,
              slot.riskSuppressionUNorm15 == locked.riskSuppressionUNorm15,
              slot.supportRadiusQ8x8 == supportRadius,
              slot.weightEpsilonF32Bits == locked.weightEpsilonF32Bits,
              slot.flags == expectedFlags else {
            throw ASHLUTBinaryErrorV2.invalidEntryFlags
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
        route: ASHSpatialRouteV2
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
        let kernel = texture ^ (edge & orientationPhase) ^ phaseHalfCycle
        let support = edge & coherent
        let detail = edge & texture & (1 - risk)
        let limiter = chromaAligned & (1 - risk)
        return UInt8(kernel | (support << 1) | (detail << 2) | (limiter << 3))
    }

    static func hardCompatibleForValidation(
        descriptorID: UInt8,
        slot: ASHLUTParameterSlotV2,
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
        _ entries: [ASHLUTLoadedEntryV2],
        route: ASHSpatialRouteV2
    ) throws {
        for phase in 0..<route.phasePairCount {
            let phaseBase = phase * ASHLUTBinaryContractV2.contextCount * ASHLUTBinaryContractV2.validStateCount
            for stateOrdinal in 0..<ASHLUTBinaryContractV2.validStateCount {
                let spatial = entries[phaseBase + stateOrdinal]
                for context in 1..<ASHLUTBinaryContractV2.contextCount {
                    let temporal = entries[
                        phaseBase + (context * ASHLUTBinaryContractV2.validStateCount) + stateOrdinal
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
                        throw ASHLUTBinaryErrorV2.invalidEntryFlags
                    }
                }
            }
        }
    }
    static func decodeParameter(
        _ record: Data,
        route: ASHSpatialRouteV2,
        configuration: ASHLUTLockedConfigurationV2
    ) throws -> ASHLUTParameterPairV2 {
        guard record[52] == 1,
              record[53] == 0,
              record[55..<60].allSatisfy({ $0 == 0 }) else {
            throw ASHLUTBinaryErrorV2.reservedNonzero
        }
        let lumaCoordinatePolicy = try decodeCoordinatePolicy(record[50])
        let chromaCoordinatePolicy = try decodeCoordinatePolicy(record[54])
        let boundaryMode: ASHSpatialBoundaryModeV2
        switch record[51] {
        case 0: boundaryMode = .clamp
        case 1: boundaryMode = .mirrorReflect101
        default: throw ASHLUTBinaryErrorV2.reservedNonzero
        }
        let selection = configuration.routeSelection(for: route)
        guard lumaCoordinatePolicy == selection.lumaCoordinatePolicy,
              chromaCoordinatePolicy == selection.chromaCoordinatePolicy,
              boundaryMode == configuration.boundaryMode else {
            throw ASHLUTBinaryErrorV2.inputHashMismatch
        }
        return ASHLUTParameterPairV2(
            primary: try decodeSlot(record, offset: 0, requiresActive: true),
            secondary: try decodeSlot(record, offset: 24, requiresActive: false),
            confidenceThresholdUNorm16: ASHLUTLittleEndianV2.uint16(record, at: 48),
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
        default: throw ASHLUTBinaryErrorV2.reservedNonzero
        }
    }

    static func decodeSlot(
        _ record: Data,
        offset: Int,
        requiresActive: Bool
    ) throws -> ASHLUTParameterSlotV2 {
        let bytes = Data(record[offset..<(offset + 24)])
        if bytes.allSatisfy({ $0 == 0 }) {
            guard !requiresActive else { throw ASHLUTBinaryErrorV2.invalidEntryFlags }
            return .inactive
        }
        let flags = ASHLUTLittleEndianV2.uint16(record, at: offset + 22)
        let allowedFlags = ASHLUTParameterSlotV2.activeFlag
            | ASHLUTParameterSlotV2.positiveDetailFlag
            | ASHLUTParameterSlotV2.relaxedLimiterFlag
            | ASHLUTParameterSlotV2.sourceAlignedPreservationFlag
        guard flags & ~allowedFlags == 0,
              flags & ASHLUTParameterSlotV2.activeFlag != 0,
              flags & ASHLUTParameterSlotV2.temporalContributionFlag == 0,
              flags & ASHLUTParameterSlotV2.denoisingFlag == 0 else {
            throw ASHLUTBinaryErrorV2.invalidEntryFlags
        }
        let minimumMagnitude = ASHLUTLittleEndianV2.uint16(record, at: offset + 2)
        let minimumCoherence = ASHLUTLittleEndianV2.uint16(record, at: offset + 4)
        let risk = ASHLUTLittleEndianV2.uint16(record, at: offset + 10)
        let epsilonBits = ASHLUTLittleEndianV2.uint32(record, at: offset + 14)
        let epsilon = Float(bitPattern: epsilonBits)
        guard minimumMagnitude <= 32_767,
              minimumCoherence <= 32_767,
              risk <= 32_767,
              epsilon.isFinite,
              epsilon > 0 else {
            throw ASHLUTBinaryErrorV2.invalidEntryFlags
        }
        let delta = ASHLUTSemanticDeltaV2(
            orientation: Int8(bitPattern: record[offset + 18]),
            support: Int8(bitPattern: record[offset + 19]),
            detail: Int8(bitPattern: record[offset + 20]),
            regularization: Int8(bitPattern: record[offset + 21])
        )
        guard [delta.orientation, delta.support, delta.detail, delta.regularization]
            .allSatisfy({ (-1...1).contains($0) }) else {
            throw ASHLUTBinaryErrorV2.invalidEntryFlags
        }
        return ASHLUTParameterSlotV2(
            anisotropyStrengthQ12: ASHLUTLittleEndianV2.uint16(record, at: offset),
            minimumAnisotropicMagnitudeUNorm15: minimumMagnitude,
            minimumAnisotropicCoherenceUNorm15: minimumCoherence,
            detailGainQ12: ASHLUTLittleEndianV2.uint16(record, at: offset + 6),
            relaxedLimiterAlphaQ12: ASHLUTLittleEndianV2.uint16(record, at: offset + 8),
            riskSuppressionUNorm15: risk,
            supportRadiusQ8x8: ASHLUTLittleEndianV2.uint16(record, at: offset + 12),
            weightEpsilonF32Bits: epsilonBits,
            delta: delta,
            flags: flags
        )
    }

}
