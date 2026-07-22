struct R07FunctionalTemporalSignals: Equatable, Sendable {
    let sceneCutConfidenceQ16: R06ASHQ16
    let motionConfidenceQ16: R06ASHQ16
    let occlusionConfidenceQ16: R06ASHQ16

    static let discontinuity = R07FunctionalTemporalSignals(
        sceneCutConfidenceQ16: .zero,
        motionConfidenceQ16: .zero,
        occlusionConfidenceQ16: .zero
    )

    static func analysis(
        _ analysis: R07TemporalAnalysisResult
    ) -> R07FunctionalTemporalSignals {
        R07FunctionalTemporalSignals(
            sceneCutConfidenceQ16: analysis.sceneCutRawQ16,
            motionConfidenceQ16: analysis.motionConfidenceQ16,
            occlusionConfidenceQ16: analysis.occlusionQ16
        )
    }

    static func sceneCut(
        _ analysis: R07TemporalAnalysisResult
    ) -> R07FunctionalTemporalSignals {
        R07FunctionalTemporalSignals(
            sceneCutConfidenceQ16: analysis.sceneCutRawQ16,
            motionConfidenceQ16: .zero,
            occlusionConfidenceQ16: .zero
        )
    }
}

struct R07FunctionalSupportAdmissions {
    let a04: R07FunctionalSupportIdentity
    let a13: R07FunctionalSupportIdentity
    let a15: R07FunctionalSupportIdentity
}

struct R07FunctionalTemporalEvaluation {
    let analysis: R07TemporalAnalysisResult?
    let disposition: R07FunctionalTemporalDisposition
    let boundaryReason: R07PostflightBoundaryReason?
    let signals: R07FunctionalTemporalSignals
}

struct R07FunctionalSupportBundle {
    let executions: [R07FunctionalSupportExecution]
    let denoisedLumaQ16: [Int64]
    let reconstructedChromaCbQ16: [Int64]
    let reconstructedChromaCrQ16: [Int64]
    let protection: R07FunctionalProtectionResult
}

struct R07FunctionalFrameEvaluation {
    let artifactAnalysis: R07FunctionalArtifactAnalysisResult
    let protectedIntegrity: R07WeightedMAEResult
    let protectedIntegrityDisposition: R07ProtectedIntegrityDisposition
    let reportFindings: R06ASHPostflightFindings
}

extension R07FunctionalCoordinator {
    func evaluateTemporal(
        _ input: R07FunctionalCoordinatorInput
    ) throws -> R07FunctionalTemporalEvaluation {
        guard !input.discontinuity else {
            return R07FunctionalTemporalEvaluation(
                analysis: nil,
                disposition: .notApplicableDiscontinuity,
                boundaryReason: .discontinuity,
                signals: .discontinuity
            )
        }
        let analysis = try R07TemporalAnalysisEngine.analyze(input.temporalInput)
        return R07FunctionalTemporalEvaluation(
            analysis: analysis,
            disposition: .analyzed,
            boundaryReason: analysis.sceneCutDetected ? .sceneCut : nil,
            signals: analysis.sceneCutDetected
                ? .sceneCut(analysis)
                : .analysis(analysis)
        )
    }

    func runSupport(
        _ input: R07FunctionalCoordinatorInput,
        temporal: R07FunctionalTemporalEvaluation
    ) throws -> R07FunctionalSupportBundle {
        let boundary = temporal.boundaryReason != nil
        let admissions = try resolveSupportAdmissions(
            scope: input.scope,
            discontinuity: boundary
        )
        let a04 = try execute(
            .a04(
                identity: admissions.a04,
                currentLumaQ16: input.temporalInput.currentLumaQ16,
                strengthQ16: R07SupportStagePolicy.a04StrengthQ16,
                temporalState: a04State(input, temporal: temporal)
            )
        )
        let luma = try R07FunctionalCoordinatorValidation.requireLuma(a04)
        var a15Executions: [R07FunctionalSupportExecution] = []
        var regions: [R07ProtectedMask] = []
        for inputRegion in input.lowResolutionProtectedRegions {
            let execution = try execute(
                .a15(
                    identity: admissions.a15,
                    lowResolutionMaskQ15: inputRegion.samplesQ15,
                    sameFrameLumaQ16: luma
                )
            )
            let samples = try R07FunctionalCoordinatorValidation
                .requireProtectionMask(execution)
            a15Executions.append(execution)
            regions.append(
                try R07ProtectedMask(
                    kind: inputRegion.kind,
                    width: R07FunctionalSupportGeometry.fullWidth,
                    height: R07FunctionalSupportGeometry.fullHeight,
                    samplesQ15: samples
                )
            )
        }
        let protection = try R07FunctionalCoordinatorAnalysis.composeProtection(
            regions: regions
        )
        let a13 = try execute(
            .a13(
                identity: admissions.a13,
                sourceChromaCbQ16: input.sourceChromaCbQ16,
                sourceChromaCrQ16: input.sourceChromaCrQ16,
                sameFrameLumaQ16: luma,
                protectionMaskQ15:
                    protection.composition.composedQ15.map(\.rawValue)
            )
        )
        let chroma = try R07FunctionalCoordinatorValidation.requireChroma(a13)
        return R07FunctionalSupportBundle(
            executions: [a04] + a15Executions + [a13],
            denoisedLumaQ16: luma,
            reconstructedChromaCbQ16: chroma.cb,
            reconstructedChromaCrQ16: chroma.cr,
            protection: protection
        )
    }

    func evaluateFrame(
        _ input: R07FunctionalCoordinatorInput,
        support: R07FunctionalSupportBundle,
        temporal: R07FunctionalTemporalEvaluation
    ) throws -> R07FunctionalFrameEvaluation {
        let artifacts = try R07FunctionalCoordinatorAnalysis.analyzeArtifacts(
            denoisedLumaQ16: support.denoisedLumaQ16,
            reconstructedChromaCbQ16: support.reconstructedChromaCbQ16,
            reconstructedChromaCrQ16: support.reconstructedChromaCrQ16,
            temporalInput: input.temporalInput,
            input: input.artifactAnalysis,
            temporalBoundary: temporal.boundaryReason != nil,
            motionValid: temporal.analysis?.motionValid == true
        )
        let weights = support.protection.composition.composedQ15.map(\.rawValue)
        let disposition: R07ProtectedIntegrityDisposition =
            weights.contains { $0 > 0 }
                ? .measured
                : .notApplicableNoProtectedWeight
        let integrity = if disposition == .measured {
            try R07ProtectedRegionPolicy.weightedMAE(
                candidateQ16: support.denoisedLumaQ16,
                referenceQ16: input.artifactAnalysis.protectedReferenceQ16,
                maskQ15: weights
            )
        } else {
            R07WeightedMAEResult(weightedMAEQ16: .zero)
        }
        return R07FunctionalFrameEvaluation(
            artifactAnalysis: artifacts,
            protectedIntegrity: integrity,
            protectedIntegrityDisposition: disposition,
            reportFindings:
                try R07FunctionalCoordinatorAnalysis.makePostflightFindings(
                    aggregate: artifacts.aggregate,
                    protectedIntegrity: integrity
                )
        )
    }

    func resolveAnalysisPlan(
        scope: AppleUpscaleAdmissionScope
    ) throws -> R07A05AnalysisPlan {
        guard case .analysisPlan(let plan) = supportPolicy.resolve(
            scope: scope,
            request: .a05Analysis
        ), plan == .temporalAnalyzer else {
            throw R07FunctionalCoordinatorError.invalidSupportPolicy(.temporalAnalyzer)
        }
        return plan
    }

    func resolveSupportAdmissions(
        scope: AppleUpscaleAdmissionScope,
        discontinuity: Bool
    ) throws -> R07FunctionalSupportAdmissions {
        guard case .a04Admission(let admission) = supportPolicy.resolve(
            scope: scope,
            request: .a04(
                qualificationStatus: .fixtureAdmitted,
                temporalState: R07TemporalSupportState(discontinuity: discontinuity)
            )
        ), let a04 = admission.descriptor else {
            throw R07FunctionalCoordinatorError.invalidSupportPolicy(.temporalNoiseFilter)
        }
        let a13 = try inheritedDescriptor(scope: scope, request: .a13Descriptor)
        let a15 = try inheritedDescriptor(scope: scope, request: .a15Descriptor)
        try validateParameters(a04: a04, a13: a13, a15: a15, discontinuity: discontinuity)
        return R07FunctionalSupportAdmissions(
            a04: .init(
                simulationIdentity: R07FunctionalSimulationIdentity.a04,
                referencedNativeIdentity: .a04Configuration(a04.configurationIdentity)
            ),
            a13: .init(
                simulationIdentity: R07FunctionalSimulationIdentity.a13,
                referencedNativeIdentity: .inheritedProcessing(a13.processingIdentity)
            ),
            a15: .init(
                simulationIdentity: R07FunctionalSimulationIdentity.a15,
                referencedNativeIdentity: .inheritedProcessing(a15.processingIdentity)
            )
        )
    }

    func inheritedDescriptor(
        scope: AppleUpscaleAdmissionScope,
        request: R07SupportStageRequest
    ) throws -> R07InheritedSupportStageDescriptor {
        guard case .inheritedDescriptor(let descriptor) = supportPolicy.resolve(
            scope: scope,
            request: request
        ) else {
            throw R07FunctionalCoordinatorError.invalidSupportPolicy(
                request == .a13Descriptor ? .mpsGuidedFilter : .coreImageEdgePreserve
            )
        }
        return descriptor
    }

    func execute(
        _ request: R07FunctionalSupportRequest
    ) throws -> R07FunctionalSupportExecution {
        let execution = try supportExecutor.execute(request)
        guard execution.capabilityID == request.capabilityID else {
            throw R07FunctionalCoordinatorError.supportExecutionCapabilityMismatch(
                expected: request.capabilityID,
                actual: execution.capabilityID
            )
        }
        guard execution.identity == request.identity else {
            throw R07FunctionalCoordinatorError.supportExecutionIdentityMismatch(
                request.capabilityID
            )
        }
        return execution
    }
}

private extension R07FunctionalCoordinator {
    func a04State(
        _ input: R07FunctionalCoordinatorInput,
        temporal: R07FunctionalTemporalEvaluation
    ) -> R07FunctionalA04TemporalState {
        if temporal.boundaryReason != nil { return .discontinuity }
        guard temporal.analysis?.motionValid == true else {
            return .currentOnlyInvalidMotion
        }
        return .continuous(
            alignedHistoryLumaQ16: input.temporalInput.alignedPreviousLumaQ16,
            occlusionMask: input.temporalInput.occlusionMask
        )
    }

    func validateParameters(
        a04: R07A04SupportStageDescriptor,
        a13: R07InheritedSupportStageDescriptor,
        a15: R07InheritedSupportStageDescriptor,
        discontinuity: Bool
    ) throws {
        guard a04.discontinuity == discontinuity else {
            throw R07FunctionalCoordinatorError.invalidSupportPolicyParameters(
                .temporalNoiseFilter
            )
        }
        guard case .a13(let kernelSize, let epsilon) = a13.parameters,
              kernelSize == 5,
              epsilon == 0.01 else {
            throw R07FunctionalCoordinatorError.invalidSupportPolicyParameters(
                .mpsGuidedFilter
            )
        }
        guard case .a15(let spatialSigma, let lumaSigma) = a15.parameters,
              spatialSigma == 3,
              lumaSigma == 0.15 else {
            throw R07FunctionalCoordinatorError.invalidSupportPolicyParameters(
                .coreImageEdgePreserve
            )
        }
    }
}
