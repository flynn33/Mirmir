enum R08ASHAnalysisBridgeError: Error, Equatable, Sendable {
    case frameIdentityMismatch(expected: String, actual: String)
    case shotIdentityMismatch(expected: String, actual: String)
    case unsupportedProtectionGeometry(width: Int, height: Int)
}

struct R08ASHAnalysisSidecar: Equatable, Sendable {
    let outcome: R08AnalysisOutcome

    var analyzedResult: R08AnalysisResult? {
        guard case .analyzed(let result) = outcome else { return nil }
        return result
    }

    var bypass: R08AnalysisBypass? {
        guard case .bypassed(let bypass) = outcome else { return nil }
        return bypass
    }
}

struct R08ASHAnalysisIntegration: Equatable, Sendable {
    let decisionContext: ASHDecisionContext
    let lowResolutionProtectedRegions: [R07LowResolutionProtectedRegion]
    let sidecar: R08ASHAnalysisSidecar
}

enum R08ASHAnalysisBridge {
    static func integrate(
        outcome: R08AnalysisOutcome,
        into base: ASHDecisionContext,
        deterministicRegions: [R07LowResolutionProtectedRegion]
    ) throws -> R08ASHAnalysisIntegration {
        let request = request(for: outcome)
        guard request.frameID == base.frameID else {
            throw R08ASHAnalysisBridgeError.frameIdentityMismatch(
                expected: base.frameID,
                actual: request.frameID
            )
        }
        guard request.shotID == base.shotID else {
            throw R08ASHAnalysisBridgeError.shotIdentityMismatch(
                expected: base.shotID,
                actual: request.shotID
            )
        }

        let sidecar = R08ASHAnalysisSidecar(outcome: outcome)
        guard case .analyzed(let result) = outcome else {
            return R08ASHAnalysisIntegration(
                decisionContext: base,
                lowResolutionProtectedRegions: deterministicRegions,
                sidecar: sidecar
            )
        }

        let learnedRegions = try protectedRegions(result.heads)
        return R08ASHAnalysisIntegration(
            decisionContext: try strengthenedContext(base, heads: result.heads),
            lowResolutionProtectedRegions: deterministicRegions + learnedRegions,
            sidecar: sidecar
        )
    }
}

private extension R08ASHAnalysisBridge {
    static func request(for outcome: R08AnalysisOutcome) -> R08AnalysisRequest {
        switch outcome {
        case .analyzed(let result): result.request
        case .bypassed(let bypass): bypass.request
        }
    }

    static func protectedRegions(
        _ heads: R08AnalysisHeads
    ) throws -> [R07LowResolutionProtectedRegion] {
        let face = try expandedForR07(heads.protection.faceSkinQ15)
        let textLineArt = try expandedForR07(heads.protection.textLineArtQ15)
        let animationUI = try expandedForR07(heads.condition.animationUILikelihoodQ15)
        return [
            R07LowResolutionProtectedRegion(kind: .face, samplesQ15: face),
            R07LowResolutionProtectedRegion(kind: .text, samplesQ15: textLineArt),
            R07LowResolutionProtectedRegion(kind: .lineArt, samplesQ15: textLineArt),
            R07LowResolutionProtectedRegion(kind: .animation, samplesQ15: animationUI),
            R07LowResolutionProtectedRegion(kind: .uiCapture, samplesQ15: animationUI)
        ]
    }

    static func expandedForR07(_ map: R08Q15Map) throws -> [Int64] {
        let targetWidth = R07FunctionalSupportGeometry.lowWidth
        let targetHeight = R07FunctionalSupportGeometry.lowHeight
        guard targetWidth.isMultiple(of: map.width),
              targetHeight.isMultiple(of: map.height) else {
            throw R08ASHAnalysisBridgeError.unsupportedProtectionGeometry(
                width: map.width,
                height: map.height
            )
        }
        let horizontalScale = targetWidth / map.width
        let verticalScale = targetHeight / map.height
        return (0..<targetHeight).flatMap { targetRow in
            (0..<targetWidth).map { targetColumn in
                let sourceRow = targetRow / verticalScale
                let sourceColumn = targetColumn / horizontalScale
                return map.samples[sourceRow * map.width + sourceColumn]
            }
        }
    }

    static func strengthenedContext(
        _ base: ASHDecisionContext,
        heads: R08AnalysisHeads
    ) throws -> ASHDecisionContext {
        let conditionRisk = heads.condition.noiseCompressionSeverityQ15.q16Maximum()
        let blurRisk = heads.condition.blurMotionBlurEstimateQ15.q16Maximum()
        let artifactRisk = heads.riskConfidence.aliasingRingingRiskQ15.q16Maximum()
        let motionOcclusionRisk = heads.riskConfidence
            .motionReliabilityOcclusionRiskQ15.q16Maximum()
        let learnedMotionReliability = R06ASHQ16.scale - motionOcclusionRisk

        return ASHDecisionContext(
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
                dwellFrames: base.dwellFrames
            ),
            signals: R06ASHSignalContext(
                sceneCutConfidenceQ16: base.sceneCutConfidenceQ16,
                motionConfidenceQ16: try R06ASHQ16(
                    min(base.motionConfidenceQ16.rawValue, learnedMotionReliability)
                ),
                occlusionConfidenceQ16: try R06ASHQ16(
                    max(base.occlusionConfidenceQ16.rawValue, motionOcclusionRisk)
                ),
                noiseEstimateQ16: try R06ASHQ16(
                    max(base.noiseEstimateQ16.rawValue, conditionRisk)
                ),
                blurEstimateQ16: try R06ASHQ16(
                    max(base.blurEstimateQ16.rawValue, blurRisk)
                ),
                compressionEstimateQ16: try R06ASHQ16(
                    max(base.compressionEstimateQ16.rawValue, conditionRisk)
                ),
                aliasingEstimateQ16: try R06ASHQ16(
                    max(base.aliasingEstimateQ16.rawValue, artifactRisk)
                )
            ),
            protection: R06ASHProtectionContext(
                faceOccupancyQ15: q15Maximum(
                    base.faceOccupancyQ15,
                    heads.protection.faceSkinQ15.mean
                ),
                textOccupancyQ15: q15Maximum(
                    base.textOccupancyQ15,
                    heads.protection.textLineArtQ15.mean
                ),
                lineArtOccupancyQ15: q15Maximum(
                    base.lineArtOccupancyQ15,
                    heads.protection.textLineArtQ15.mean
                ),
                animationOccupancyQ15: q15Maximum(
                    base.animationOccupancyQ15,
                    heads.condition.animationUILikelihoodQ15.mean
                ),
                uiOccupancyQ15: q15Maximum(
                    base.uiOccupancyQ15,
                    heads.condition.animationUILikelihoodQ15.mean
                )
            ),
            resources: R06ASHResourceContext(
                backendAvailability: base.backendAvailability,
                modelReadiness: base.modelReadiness,
                backendQualityConfidenceQ16: base.backendQualityConfidenceQ16,
                memoryPressureQ16: base.memoryPressureQ16,
                thermalPressureQ16: base.thermalPressureQ16,
                throughputPressureQ16: base.throughputPressureQ16
            ),
            backendHistory: try R06ASHBackendHistory(
                currentBackendID: base.currentBackendID,
                previousBackendID: base.previousBackendID
            ),
            effects: R06ASHEffectContext(
                preprocessStrengthQ16: base.preprocessStrengthQ16,
                postprocessStrengthQ16: base.postprocessStrengthQ16,
                artifactRiskQ16: try R06ASHQ16(
                    max(base.artifactRiskQ16.rawValue, artifactRisk)
                )
            ),
            outcome: R06ASHOutcomeContext(
                postflightFindings: base.postflightFindings,
                fallbackReason: base.fallbackReason,
                retryEligibility: base.retryEligibility
            )
        )
    }

    static func q15Maximum(_ base: R06ASHQ15, _ learned: Int64) -> R06ASHQ15 {
        R06ASHQ15(validatedRawValue: max(base.rawValue, learned))
    }
}
