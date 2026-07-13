import XCTest
@testable import Mirmir

struct ASHLUTCompilerObservationsV2 {
    let descriptorIDs: Set<UInt8>
    let gainAndAlpha: Bool
    let secondary: Bool
    let ordinaryPruning: Bool
}

extension ASHLUTCompilerV2Tests {
    func assertCompilation(
        _ compilation: ASHLUTCompilationV2,
        configuration: ASHLUTLockedConfigurationV2
    ) throws -> ASHLUTCompilerObservationsV2 {
        let route = compilation.route
        let expectedCount = route.phasePairCount * 4 * 256
        XCTAssertEqual(compilation.entries.count, expectedCount)
        XCTAssertEqual(compilation.offlinePathEvaluationCount, expectedCount * 81)
        XCTAssertEqual(compilation.runtimeTreeGenerationCount, 0)
        XCTAssertLessThanOrEqual(compilation.maximumOperatorEvaluations, 2)

        var descriptorIDs = Set<UInt8>()
        var gainAndAlpha = false
        var secondaryObserved = false
        var ordinaryPruning = false
        let canonicalPaths = try ASHLUTLeafCompilerV2.canonicalPaths()
        for (index, entry) in compilation.entries.enumerated() {
            let stateOrdinal = index % 256
            let phaseAndContext = index / 256
            let contextRaw = phaseAndContext % 4
            let phase = phaseAndContext / 4
            XCTAssertEqual(entry.logicalIndex, index)
            XCTAssertEqual(entry.validStateOrdinal, UInt16(stateOrdinal))
            XCTAssertEqual(entry.phaseOrdinal, UInt16(phase))
            XCTAssertEqual(entry.context.rawValue, UInt8(contextRaw))
            XCTAssertEqual(entry.sourceState, ASHLUTStateOrdinalTableV2.validStates[stateOrdinal])
            XCTAssertEqual(entry.temporalForcedSpatial, contextRaw != 0)
            XCTAssertLessThanOrEqual(entry.operatorEvaluationCount, 2)
            XCTAssertEqual(
                entry.parameters.lumaCoordinatePolicy,
                configuration.routeSelection(for: route).lumaCoordinatePolicy
            )
            XCTAssertEqual(
                entry.parameters.chromaCoordinatePolicy,
                configuration.routeSelection(for: route).chromaCoordinatePolicy
            )
            XCTAssertEqual(entry.parameters.boundaryMode, configuration.boundaryMode)

            let expectedSourceExact = configuration.routeSelection(for: route)
                .bothPlanesAreSourceAligned && phase == 0
            XCTAssertEqual(entry.sourceAlignedExact, expectedSourceExact)
            if let secondary = entry.secondary {
                secondaryObserved = true
                XCTAssertGreaterThan(entry.primaryWeightUNorm16, 0)
                XCTAssertGreaterThan(entry.secondaryWeightUNorm16, 0)
                XCTAssertGreaterThanOrEqual(entry.primaryWeightUNorm16, entry.secondaryWeightUNorm16)
                XCTAssertEqual(
                    UInt32(entry.primaryWeightUNorm16) + UInt32(entry.secondaryWeightUNorm16),
                    UInt32(UInt16.max)
                )
                XCTAssertEqual(
                    entry.marginUNorm16,
                    entry.primaryWeightUNorm16 - entry.secondaryWeightUNorm16
                )
                XCTAssertLessThan(
                    entry.marginUNorm16,
                    configuration.compilerPolicy.confidenceThresholdUNorm16
                )
                let coexists = try assertCandidate(
                    secondary,
                    slot: entry.parameters.secondary,
                    entry: entry,
                    route: route,
                    canonicalPaths: canonicalPaths,
                    configuration: configuration
                )
                gainAndAlpha = gainAndAlpha || coexists
                descriptorIDs.insert(secondary.descriptorID)
            } else {
                XCTAssertEqual(entry.primaryWeightUNorm16, UInt16.max)
                XCTAssertEqual(entry.secondaryWeightUNorm16, 0)
                XCTAssertEqual(entry.parameters.secondary, .inactive)
                if expectedSourceExact {
                    XCTAssertEqual(entry.marginUNorm16, UInt16.max)
                } else {
                    ordinaryPruning = true
                    XCTAssertGreaterThanOrEqual(
                        entry.marginUNorm16,
                        configuration.compilerPolicy.confidenceThresholdUNorm16
                    )
                }
            }
            let coexists = try assertCandidate(
                entry.primary,
                slot: entry.parameters.primary,
                entry: entry,
                route: route,
                canonicalPaths: canonicalPaths,
                configuration: configuration
            )
            gainAndAlpha = gainAndAlpha || coexists
            descriptorIDs.insert(entry.primary.descriptorID)
        }
        try assertContextAndTemporalAliases(compilation)
        return ASHLUTCompilerObservationsV2(
            descriptorIDs: descriptorIDs,
            gainAndAlpha: gainAndAlpha,
            secondary: secondaryObserved,
            ordinaryPruning: ordinaryPruning
        )
    }

    func assertCandidate(
        _ candidate: ASHLUTCompiledCandidateV2,
        slot: ASHLUTParameterSlotV2,
        entry: ASHLUTCompiledEntryV2,
        route: ASHSpatialRouteV2,
        canonicalPaths: [ASHLUTCanonicalPathV2],
        configuration: ASHLUTLockedConfigurationV2
    ) throws -> Bool {
        let decoded = ASHCode.decodeAffine(received: candidate.affineState, anchor: entry.sourceState)
        XCTAssertEqual(decoded.status, .exact)
        XCTAssertEqual(decoded.messageBits, candidate.message.bits)
        XCTAssertLessThan(candidate.descriptorID, UInt8(ASHSpatialDescriptorV2.count))
        XCTAssertGreaterThan(candidate.aggregatedWeight, 0)
        XCTAssertLessThan(Int(candidate.representativePathOrdinal), canonicalPaths.count)
        let path = canonicalPaths[Int(candidate.representativePathOrdinal)]
        XCTAssertEqual(path.message, candidate.message)
        XCTAssertEqual(path.semanticDelta, candidate.semanticDelta)
        XCTAssertEqual(slot.delta, candidate.semanticDelta)

        if entry.sourceAlignedExact {
            XCTAssertEqual(candidate.message.rawValue, 0)
            XCTAssertEqual(candidate.affineState, entry.sourceState)
            XCTAssertEqual(candidate.descriptorID, 0)
            XCTAssertEqual(candidate.aggregatedWeight, 65_536)
            XCTAssertEqual(slot.detailGainQ12, 0)
            XCTAssertEqual(slot.relaxedLimiterAlphaQ12, 0)
            XCTAssertEqual(slot.supportRadiusQ8x8, 512)
            XCTAssertEqual(
                slot.flags,
                ASHLUTParameterSlotV2.activeFlag
                    | ASHLUTParameterSlotV2.sourceAlignedPreservationFlag
            )
            return false
        }

        let semanticState = try spatialSemanticState(entry.sourceState)
        let base = baseDescriptor(
            state: semanticState,
            phase: Int(entry.phaseOrdinal),
            route: route
        )
        let locked = configuration.operatorParameters
        let steps = configuration.semanticSteps
        let baseKernel = base & 1
        let baseSupport = base & 0b0010
        let expectedGain = ASHLUTTestSupportV2.adjusted(
            base & 0b0100 == 0 ? 0 : locked.detailGainQ12,
            delta: candidate.semanticDelta.detail,
            step: steps.detailGainStepQ12,
            range: 0...2_048
        )
        let expectedAlpha = ASHLUTTestSupportV2.adjusted(
            base & 0b1000 == 0 ? 0 : locked.relaxedLimiterAlphaQ12,
            delta: -candidate.semanticDelta.regularization,
            step: steps.regularizationStepQ12,
            range: 0...1_024
        )
        let expectedSupport = ASHLUTTestSupportV2.adjusted(
            baseKernel == 0 ? 512 : 768,
            delta: candidate.semanticDelta.support,
            step: steps.supportRadiusStepQ8x8,
            range: 256...768
        )
        let expectedDescriptor = baseKernel
            | baseSupport
            | (expectedGain > 0 ? 0b0100 : 0)
            | (expectedAlpha > 0 ? 0b1000 : 0)
        XCTAssertEqual(candidate.descriptorID, expectedDescriptor)
        XCTAssertEqual(candidate.detailGainQ12, expectedGain)
        XCTAssertEqual(candidate.relaxedLimiterAlphaQ12, expectedAlpha)
        XCTAssertEqual(candidate.supportRadiusQ8x8, expectedSupport)
        XCTAssertEqual(slot.detailGainQ12, expectedGain)
        XCTAssertEqual(slot.relaxedLimiterAlphaQ12, expectedAlpha)
        XCTAssertEqual(slot.supportRadiusQ8x8, expectedSupport)
        XCTAssertEqual(slot.anisotropyStrengthQ12, locked.anisotropyStrengthQ12)
        XCTAssertEqual(slot.minimumAnisotropicMagnitudeUNorm15, locked.minimumAnisotropicMagnitudeUNorm15)
        XCTAssertEqual(slot.minimumAnisotropicCoherenceUNorm15, locked.minimumAnisotropicCoherenceUNorm15)
        XCTAssertEqual(slot.riskSuppressionUNorm15, locked.riskSuppressionUNorm15)
        XCTAssertEqual(slot.weightEpsilonF32Bits, locked.weightEpsilonF32Bits)

        var expectedFlags = ASHLUTParameterSlotV2.activeFlag
        if expectedGain > 0 { expectedFlags |= ASHLUTParameterSlotV2.positiveDetailFlag }
        if expectedAlpha > 0 { expectedFlags |= ASHLUTParameterSlotV2.relaxedLimiterFlag }
        XCTAssertEqual(slot.flags, expectedFlags)
        let edge = semanticState.bit(coordinate: 3)
        let coherent = semanticState.bit(coordinate: 4)
        let risk = semanticState.bit(coordinate: 6)
        let chromaAligned = semanticState.bit(coordinate: 8)
        XCTAssertFalse(candidate.descriptorID & 0b0010 != 0 && edge == 0 && coherent == 0)
        if expectedGain > 0 { XCTAssertEqual(risk, 0) }
        if expectedAlpha > 0 { XCTAssertEqual(chromaAligned, 1) }
        return expectedGain > 0 && expectedAlpha > 0
    }

    func assertContextAndTemporalAliases(_ compilation: ASHLUTCompilationV2) throws {
        for phase in 0..<compilation.route.phasePairCount {
            let phaseBase = phase * 4 * 256
            for stateOrdinal in 0..<256 {
                let spatial = compilation.entries[phaseBase + stateOrdinal]
                for context in 1..<4 {
                    let alias = compilation.entries[phaseBase + context * 256 + stateOrdinal]
                    XCTAssertEqual(spatial.primary, alias.primary)
                    XCTAssertEqual(spatial.secondary, alias.secondary)
                    XCTAssertEqual(spatial.primaryWeightUNorm16, alias.primaryWeightUNorm16)
                    XCTAssertEqual(spatial.secondaryWeightUNorm16, alias.secondaryWeightUNorm16)
                    XCTAssertEqual(spatial.marginUNorm16, alias.marginUNorm16)
                    XCTAssertEqual(spatial.parameters, alias.parameters)
                }

                let cleared = try spatialSemanticState(spatial.sourceState)
                let clearedOrdinal = try XCTUnwrap(ASHLUTStateOrdinalTableV2.ordinal(for: cleared))
                let clearedEntry = compilation.entries[phaseBase + Int(clearedOrdinal)]
                XCTAssertEqual(spatial.primary.message, clearedEntry.primary.message)
                XCTAssertEqual(spatial.primary.descriptorID, clearedEntry.primary.descriptorID)
                XCTAssertEqual(spatial.secondary?.message, clearedEntry.secondary?.message)
                XCTAssertEqual(spatial.secondary?.descriptorID, clearedEntry.secondary?.descriptorID)
                XCTAssertEqual(spatial.primaryWeightUNorm16, clearedEntry.primaryWeightUNorm16)
                XCTAssertEqual(spatial.secondaryWeightUNorm16, clearedEntry.secondaryWeightUNorm16)
                XCTAssertEqual(spatial.marginUNorm16, clearedEntry.marginUNorm16)
                XCTAssertEqual(spatial.parameters, clearedEntry.parameters)
            }
        }
    }

    func spatialSemanticState(_ source: ASHState) throws -> ASHState {
        var payload = Array(source.bits.prefix(ASHState.payloadBitCount))
        payload[6] = 0
        return try ASHState(payloadBits: payload)
    }

    func baseDescriptor(
        state: ASHState,
        phase: Int,
        route: ASHSpatialRouteV2
    ) -> UInt8 {
        let horizontal = phase % route.scaleNumerator
        let vertical = phase / route.scaleNumerator
        let halfCycle = ((2 * horizontal >= route.scaleNumerator) ? 1 : 0)
            ^ ((2 * vertical >= route.scaleNumerator) ? 1 : 0)
        let kernel = state.bit(coordinate: 5)
            ^ (state.bit(coordinate: 3)
                & (state.bit(coordinate: 1) ^ state.bit(coordinate: 2)))
            ^ halfCycle
        let support = state.bit(coordinate: 3) & state.bit(coordinate: 4)
        let detail = state.bit(coordinate: 3)
            & state.bit(coordinate: 5)
            & (1 - state.bit(coordinate: 6))
        let limiter = state.bit(coordinate: 8) & (1 - state.bit(coordinate: 6))
        return UInt8(kernel | support << 1 | detail << 2 | limiter << 3)
    }
}
