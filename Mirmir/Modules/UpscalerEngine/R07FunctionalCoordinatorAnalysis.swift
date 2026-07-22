enum R07FunctionalCoordinatorAnalysis {
    static func composeProtection(
        regions: [R07ProtectedMask]
    ) throws -> R07FunctionalProtectionResult {
        let composition = try R07ProtectedRegionPolicy.compose(
            width: R07FunctionalSupportGeometry.fullWidth,
            height: R07FunctionalSupportGeometry.fullHeight,
            regions: regions
        )
        let rawSamples = composition.composedQ15.map { UInt16($0.rawValue) }
        let reconstructed = try R06ASHMaskSet(
            lumaProtection: R06ASHMask(
                id: .lumaProtection,
                width: composition.width,
                height: composition.height,
                samplesQ15: rawSamples
            ),
            chromaProtection: R06ASHMask(
                id: .chromaProtection,
                width: composition.width,
                height: composition.height,
                samplesQ15: rawSamples
            ),
            postprocessSuppression: R06ASHMask(
                id: .postprocessSuppression,
                width: composition.width,
                height: composition.height,
                samplesQ15: rawSamples
            )
        )
        guard reconstructed == composition.masks else {
            throw R07FunctionalCoordinatorError.invalidProtectedComposition
        }
        return R07FunctionalProtectionResult(
            composition: composition,
            context: try protectionContext(regions: regions)
        )
    }

    static func analyzeArtifacts(
        denoisedLumaQ16: [Int64],
        reconstructedChromaCbQ16: [Int64],
        reconstructedChromaCrQ16: [Int64],
        temporalInput: R07TemporalAnalysisInput,
        input: R07FunctionalArtifactAnalysisInput,
        temporalBoundary: Bool,
        motionValid: Bool
    ) throws -> R07FunctionalArtifactAnalysisResult {
        let lumaEdgeQ8 = try strongestHorizontalEdgePositionQ8(
            denoisedLumaQ16
        )
        let cbEdgeQ8 = try strongestHorizontalEdgePositionQ8(
            reconstructedChromaCbQ16
        )
        let crEdgeQ8 = try strongestHorizontalEdgePositionQ8(
            reconstructedChromaCrQ16
        )
        var notApplicable: [R07ArtifactKind] = []
        let ghosting: R07ArtifactMeasurement
        let flicker: R07ArtifactMeasurement
        let halo: R07ArtifactMeasurement
        do {
            halo = try R07ArtifactGovernance.halo(
                candidateQ16: denoisedLumaQ16,
                referenceQ16: input.haloReferenceQ16,
                support: input.haloSupport
            )
        } catch R07ArtifactGovernanceError.zeroSupportRejected {
            halo = try R07ArtifactGovernance.measurement(
                kind: .halo,
                rawValue: 0,
                contributingSampleCount: 0
            )
            notApplicable.append(.halo)
        }
        if temporalBoundary || !motionValid {
            ghosting = try R07ArtifactGovernance.measurement(
                kind: .ghosting,
                rawValue: 0
            )
            notApplicable.append(.ghosting)
        } else {
            ghosting = try R07ArtifactGovernance.ghosting(
                currentQ16: denoisedLumaQ16,
                alignedPreviousQ16: temporalInput.alignedPreviousLumaQ16,
                occlusionMask: temporalInput.occlusionMask.map { $0 == 1 }
            )
        }
        if temporalBoundary {
            flicker = try R07ArtifactGovernance.measurement(
                kind: .flicker,
                rawValue: 0
            )
            notApplicable.append(.flicker)
        } else {
            flicker = try R07ArtifactGovernance.flicker(
                currentQ16: denoisedLumaQ16,
                previousQ16: temporalInput.previousLumaQ16,
                beforePreviousQ16: input.beforePreviousLumaQ16
            )
        }
        let chromaDisplacement: R07ArtifactMeasurement
        if let lumaEdgeQ8, cbEdgeQ8 != nil || crEdgeQ8 != nil {
            let cbDifference = try cbEdgeQ8.map {
                try R07CheckedInt64.absoluteDifference(lumaEdgeQ8, $0)
            } ?? 0
            let crDifference = try crEdgeQ8.map {
                try R07CheckedInt64.absoluteDifference(lumaEdgeQ8, $0)
            } ?? 0
            chromaDisplacement = try R07ArtifactGovernance.measurement(
                kind: .chromaDisplacement,
                rawValue: max(cbDifference, crDifference)
            )
        } else {
            chromaDisplacement = try R07ArtifactGovernance.measurement(
                kind: .chromaDisplacement,
                rawValue: 0
            )
            notApplicable.append(.chromaDisplacement)
        }
        let aggregate = try R07ArtifactGovernance.aggregate([
            R07ArtifactGovernance.ringing(
                candidateQ16: denoisedLumaQ16,
                lowerBoundsQ16: input.ringingLowerBoundsQ16,
                upperBoundsQ16: input.ringingUpperBoundsQ16
            ),
            halo,
            ghosting,
            flicker,
            R07ArtifactGovernance.falseTexture(
                candidateQ16: denoisedLumaQ16,
                sourceQ16: input.falseTextureSourceQ16
            ),
            chromaDisplacement
        ])
        return R07FunctionalArtifactAnalysisResult(
            aggregate: aggregate,
            notApplicableKinds: notApplicable
        )
    }

    static func makePostflightFindings(
        aggregate: R07ArtifactAggregate,
        protectedIntegrity: R07WeightedMAEResult
    ) throws -> R06ASHPostflightFindings {
        var findings = try aggregate.orderedMeasurements.compactMap { measurement in
            measurement.detected
                ? try R06ASHPostflightFinding(id: measurement.kind.rawValue)
                : nil
        }
        if protectedIntegrity.violatesProtectedIntegrity {
            findings.append(try R06ASHPostflightFinding(id: "protected_integrity"))
        }
        return try R06ASHPostflightFindings(
            riskQ16: max(
                aggregate.maximumNormalizedRiskQ16,
                protectedIntegrity.weightedMAEQ16
            ),
            findings: findings
        )
    }

    static func makeNextContext(
        base: ASHDecisionContext,
        completedDecision: R07CompletedR06Decision,
        temporalSignals: R07FunctionalTemporalSignals,
        boundary: Bool,
        protection: R06ASHProtectionContext,
        artifactRiskQ16: R06ASHQ16,
        postflightFindings: R06ASHPostflightFindings
    ) throws -> ASHDecisionContext {
        ASHDecisionContext(
            identity: try R06ASHIdentityContext(
                frameID: base.frameID,
                shotID: base.shotID,
                routeID: base.routeID,
                scaleNumerator: base.scaleNumerator,
                scaleDenominator: base.scaleDenominator,
                planeLayout: base.planeLayout,
                chromaSiting: base.chromaSiting
            ),
            state: try R06ASHStateContext(
                continuousFeatureValuesQ16: base.continuousFeatureValuesQ16,
                currentState: base.currentState,
                previousState: base.previousState,
                stateTransition: base.stateTransition,
                dwellFrames: boundary ? 0 : base.dwellFrames
            ),
            signals: R06ASHSignalContext(
                sceneCutConfidenceQ16: temporalSignals.sceneCutConfidenceQ16,
                motionConfidenceQ16: temporalSignals.motionConfidenceQ16,
                occlusionConfidenceQ16: temporalSignals.occlusionConfidenceQ16,
                noiseEstimateQ16: base.noiseEstimateQ16,
                blurEstimateQ16: base.blurEstimateQ16,
                compressionEstimateQ16: base.compressionEstimateQ16,
                aliasingEstimateQ16: base.aliasingEstimateQ16
            ),
            protection: protection,
            resources: R06ASHResourceContext(
                backendAvailability: base.backendAvailability,
                modelReadiness: base.modelReadiness,
                backendQualityConfidenceQ16: base.backendQualityConfidenceQ16,
                memoryPressureQ16: base.memoryPressureQ16,
                thermalPressureQ16: base.thermalPressureQ16,
                throughputPressureQ16: base.throughputPressureQ16
            ),
            backendHistory: try R06ASHBackendHistory(
                currentBackendID: boundary
                    ? nil
                    : completedDecision.record.selectedPlan.selectedBackendID,
                previousBackendID: boundary ? nil : base.previousBackendID
            ),
            effects: R06ASHEffectContext(
                preprocessStrengthQ16: base.preprocessStrengthQ16,
                postprocessStrengthQ16: base.postprocessStrengthQ16,
                artifactRiskQ16: artifactRiskQ16
            ),
            outcome: R06ASHOutcomeContext(
                postflightFindings: postflightFindings,
                fallbackReason: boundary ? nil : base.fallbackReason,
                retryEligibility: base.retryEligibility
            )
        )
    }
}

private extension R07FunctionalCoordinatorAnalysis {
    static func protectionContext(
        regions: [R07ProtectedMask]
    ) throws -> R06ASHProtectionContext {
        R06ASHProtectionContext(
            faceOccupancyQ15: try occupancy(regions, kinds: [.face]),
            textOccupancyQ15: try occupancy(regions, kinds: [.subtitle, .text]),
            lineArtOccupancyQ15: try occupancy(regions, kinds: [.lineArt]),
            animationOccupancyQ15: try occupancy(regions, kinds: [.animation]),
            uiOccupancyQ15: try occupancy(regions, kinds: [.uiCapture])
        )
    }

    static func occupancy(
        _ regions: [R07ProtectedMask],
        kinds: Set<R07ProtectedContentKind>
    ) throws -> R06ASHQ15 {
        let matching = regions.filter { kinds.contains($0.kind) }
        guard !matching.isEmpty else { return .zero }
        var sum: Int64 = 0
        for index in 0..<R07FunctionalSupportGeometry.fullSampleCount {
            let maximum = matching.map { $0.samplesQ15[index] }.max() ?? .zero
            sum = try R07CheckedInt64.add(sum, maximum.rawValue)
        }
        return R06ASHQ15(
            validatedRawValue: try R07CheckedInt64.divideTowardZero(
                sum,
                by: Int64(R07FunctionalSupportGeometry.fullSampleCount)
            )
        )
    }

    static func strongestHorizontalEdgePositionQ8(
        _ samplesQ16: [Int64]
    ) throws -> Int64? {
        guard samplesQ16.count == R07FunctionalSupportGeometry.fullSampleCount else {
            throw R07FunctionalCoordinatorError.invalidFullResolutionSampleCount(
                role: "edge_position_q16",
                actual: samplesQ16.count
            )
        }
        var strongestPosition: Int?
        var strongestMagnitude: Int64 = 0
        for column in 1..<R07FunctionalSupportGeometry.fullWidth {
            var magnitude: Int64 = 0
            for row in 0..<R07FunctionalSupportGeometry.fullHeight {
                let index = row * R07FunctionalSupportGeometry.fullWidth + column
                let difference = try R07CheckedInt64.absoluteDifference(
                    samplesQ16[index],
                    samplesQ16[index - 1]
                )
                magnitude = try R07CheckedInt64.add(magnitude, difference)
            }
            if magnitude > strongestMagnitude {
                strongestMagnitude = magnitude
                strongestPosition = column
            }
        }
        guard let strongestPosition else { return nil }
        return try R07CheckedInt64.multiply(Int64(strongestPosition), 256)
    }
}
