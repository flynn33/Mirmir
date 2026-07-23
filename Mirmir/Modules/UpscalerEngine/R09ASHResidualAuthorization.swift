struct R09ASHAuthorizationCapability: Sendable {
    fileprivate init() {}
}

enum R09ASHResidualAuthorizer {
    static let acceptedR08AcceptanceSHA256 =
        "0d81917a93cf56cae867c11b7c65fb3c85e53b7596929cf9eec2ef09c24634b0"

    static func authorize(
        _ input: R09ASHResidualAuthorizationInput
    ) -> R09ASHResidualAuthorizationOutcome {
        do {
            return try authorizeValidated(input)
        } catch let error as R09ASHResidualAuthorizationError {
            return notAuthorized(input, reason: .authorizationInvalid(error))
        } catch let error as R09ResidualContractError {
            return notAuthorized(input, reason: .contractInvalid(error))
        } catch {
            return notAuthorized(input, reason: .unexpectedFailure)
        }
    }

    private static func authorizeValidated(
        _ input: R09ASHResidualAuthorizationInput
    ) throws -> R09ASHResidualAuthorizationOutcome {
        try validateStaticBindings(input)
        try validateAuthorizationBindings(input)
        try validateDecisionBindings(input)

        let analysisRequest = request(from: input.analysisSidecar)
        try validateAnalysisBinding(request: analysisRequest, input: input)

        if case .bypassed(let bypass) = input.analysisSidecar.outcome {
            return .notAuthorized(
                R09ASHResidualNoAuthorization(
                    requestIdentity: input.identity,
                    authorization: input.authorization,
                    scalerIdentity: input.scalerIdentity,
                    reason: .r08AnalysisBypassed(bypass.reason)
                )
            )
        }

        guard case .analyzed(let analysis) = input.analysisSidecar.outcome else {
            preconditionFailure("R08 analysis outcome has an unhandled case")
        }
        let masks = try composeMasks(
            frame: input.postScalerFrame,
            ashRequestedLumaMask: input.ashRequestedLumaMask,
            protectedComposition: input.protectedComposition,
            heads: analysis.heads
        )
        return .authorized(
            try R09ResidualRequest(
                ashAuthorization: R09ASHAuthorizationCapability(),
                identity: input.identity,
                authorization: input.authorization,
                scalerIdentity: input.scalerIdentity,
                modelIdentity: input.modelIdentity,
                postScalerFrame: input.postScalerFrame,
                ashApprovedMask: masks.eligible,
                protectedMask: masks.protected,
                limits: input.limits,
                sourceReference: input.sourceReference,
                temporalReference: input.temporalReference,
                confidenceBudget: input.confidenceBudget,
                resourceBudget: input.resourceBudget,
                safetySignal: input.safetySignal
            )
        )
    }

    private static func notAuthorized(
        _ input: R09ASHResidualAuthorizationInput,
        reason: R09ASHResidualNoAuthorizationReason
    ) -> R09ASHResidualAuthorizationOutcome {
        .notAuthorized(
            R09ASHResidualNoAuthorization(
                requestIdentity: input.identity,
                authorization: input.authorization,
                scalerIdentity: input.scalerIdentity,
                reason: reason
            )
        )
    }
}

private extension R09ASHResidualAuthorizer {
    struct ComposedMasks {
        let eligible: R09PlanarMaskQ15
        let protected: R09PlanarMaskQ15
    }

    static func validateStaticBindings(
        _ input: R09ASHResidualAuthorizationInput
    ) throws {
        guard input.authorization.referencedR08AcceptanceSHA256
                == acceptedR08AcceptanceSHA256 else {
            throw R09ASHResidualAuthorizationError.acceptedR08BindingMismatch(
                expected: acceptedR08AcceptanceSHA256,
                actual: input.authorization.referencedR08AcceptanceSHA256
            )
        }
        guard input.identity.ioContractSHA256 == R09ResidualRequestIdentity.ioContractSHA256 else {
            throw R09ASHResidualAuthorizationError.requestContractMismatch(
                expected: R09ResidualRequestIdentity.ioContractSHA256,
                actual: input.identity.ioContractSHA256
            )
        }
        guard input.scalerIdentity.backendID
                == R09AppleScalerIdentity.deterministicPrimaryBackendID,
              input.scalerIdentity.implementationVersion
                == R09AppleScalerIdentity.deterministicPrimaryBackendVersion,
              input.scalerIdentity.kind == .metalPerformanceShaders,
              input.scalerIdentity.scaleNumerator == 2,
              input.scalerIdentity.scaleDenominator == 1,
              input.scalerIdentity.processingIdentity.route.backend.modelAssetsIdentity
                == .notRequired else {
            throw R09ASHResidualAuthorizationError.deterministicExecutionBindingMismatch
        }
        guard input.modelIdentity.modelID == R09BoundedResidualStage.deterministicModelID,
              input.modelIdentity.modelVersion
                == R09BoundedResidualStage.deterministicModelVersion,
              input.modelIdentity.artifactKind == .deterministicSimulationContract,
              input.modelIdentity.contentSHA256
                == R09ResidualModelIdentity.deterministicProviderSHA256,
              input.modelIdentity.preprocessingIdentity
                == R09ResidualModelIdentity.deterministicPreprocessingIdentity,
              input.modelIdentity.postprocessingIdentity
                == R09ResidualModelIdentity.deterministicPostprocessingIdentity,
              input.modelIdentity.residualContractIdentity
                == R09ResidualModelIdentity.deterministicResidualContractIdentity else {
            throw R09ASHResidualAuthorizationError.deterministicModelBindingMismatch
        }
        guard input.authorization.scope == .deterministicSimulationOnly,
              input.scalerIdentity.executionMode == .deterministicFixtureSimulation,
              input.scalerIdentity.nativeExecution == .notObserved else {
            throw R09ASHResidualAuthorizationError.deterministicExecutionBindingMismatch
        }
    }

    static func validateAuthorizationBindings(
        _ input: R09ASHResidualAuthorizationInput
    ) throws {
        guard input.authorization.frameID == input.identity.frameID else {
            throw R09ASHResidualAuthorizationError.authorizationFrameMismatch(
                expected: input.identity.frameID,
                actual: input.authorization.frameID
            )
        }
        guard input.authorization.shotID == input.identity.shotID else {
            throw R09ASHResidualAuthorizationError.authorizationShotMismatch(
                expected: input.identity.shotID,
                actual: input.authorization.shotID
            )
        }
        guard input.authorization.streamID == input.identity.streamID else {
            throw R09ASHResidualAuthorizationError.authorizationStreamMismatch(
                expected: input.identity.streamID,
                actual: input.authorization.streamID
            )
        }
        guard input.authorization.stateGeneration == input.identity.stateGeneration else {
            throw R09ASHResidualAuthorizationError.authorizationStateGenerationMismatch(
                expected: input.identity.stateGeneration,
                actual: input.authorization.stateGeneration
            )
        }
        guard input.authorization.sourceReferenceFrameID == input.sourceReference.frameID,
              input.authorization.sourceReferenceFrameOrdinal
                == input.sourceReference.frameOrdinal else {
            throw R09ASHResidualAuthorizationError.authorizationSourceReferenceMismatch
        }
        guard input.authorization.temporalReferenceFrameID == input.temporalReference.frameID,
              input.authorization.temporalReferenceFrameOrdinal
                == input.temporalReference.frameOrdinal else {
            throw R09ASHResidualAuthorizationError.authorizationTemporalReferenceMismatch
        }
        guard input.authorization.primaryBackendID == input.scalerIdentity.backendID else {
            throw R09ASHResidualAuthorizationError.authorizationPrimaryBackendMismatch(
                expected: input.scalerIdentity.backendID,
                actual: input.authorization.primaryBackendID
            )
        }
        guard input.authorization.primaryProcessingIdentity
                == input.scalerIdentity.processingIdentity else {
            throw R09ASHResidualAuthorizationError.authorizationPrimaryRouteMismatch
        }
        guard input.scalerIdentity.outputFrameID == input.identity.frameID else {
            throw R09ASHResidualAuthorizationError.scalerOutputFrameMismatch(
                expected: input.identity.frameID,
                actual: input.scalerIdentity.outputFrameID
            )
        }
    }

    static func validateDecisionBindings(
        _ input: R09ASHResidualAuthorizationInput
    ) throws {
        guard input.decisionContext.frameID == input.identity.frameID else {
            throw R09ASHResidualAuthorizationError.decisionFrameMismatch(
                expected: input.identity.frameID,
                actual: input.decisionContext.frameID
            )
        }
        guard input.decisionContext.shotID == input.identity.shotID else {
            throw R09ASHResidualAuthorizationError.decisionShotMismatch(
                expected: input.identity.shotID,
                actual: input.decisionContext.shotID
            )
        }
        guard input.decisionContext.currentBackendID == input.scalerIdentity.backendID else {
            throw R09ASHResidualAuthorizationError.decisionPrimaryBackendMismatch(
                expected: input.scalerIdentity.backendID,
                actual: input.decisionContext.currentBackendID
            )
        }
        guard input.decisionContext.scaleNumerator == input.scalerIdentity.scaleNumerator,
              input.decisionContext.scaleDenominator == input.scalerIdentity.scaleDenominator else {
            throw R09ASHResidualAuthorizationError.decisionScaleMismatch(
                expectedNumerator: input.scalerIdentity.scaleNumerator,
                expectedDenominator: input.scalerIdentity.scaleDenominator,
                actualNumerator: input.decisionContext.scaleNumerator,
                actualDenominator: input.decisionContext.scaleDenominator
            )
        }
    }

    static func validateAnalysisBinding(
        request: R08AnalysisRequest,
        input: R09ASHResidualAuthorizationInput
    ) throws {
        guard request.frameID == input.identity.frameID else {
            throw R09ASHResidualAuthorizationError.analysisFrameMismatch(
                expected: input.identity.frameID,
                actual: request.frameID
            )
        }
        guard request.shotID == input.identity.shotID else {
            throw R09ASHResidualAuthorizationError.analysisShotMismatch(
                expected: input.identity.shotID,
                actual: request.shotID
            )
        }
        guard request.streamID == input.identity.streamID else {
            throw R09ASHResidualAuthorizationError.analysisStreamMismatch(
                expected: input.identity.streamID,
                actual: request.streamID
            )
        }
        guard request.frameOrdinal == input.identity.frameOrdinal else {
            throw R09ASHResidualAuthorizationError.analysisFrameOrdinalMismatch(
                expected: input.identity.frameOrdinal,
                actual: request.frameOrdinal
            )
        }
        guard request.stateGeneration == UInt64(input.identity.stateGeneration) else {
            throw R09ASHResidualAuthorizationError.analysisStateGenerationMismatch(
                expected: input.identity.stateGeneration,
                actual: request.stateGeneration
            )
        }
    }

    static func request(from sidecar: R08ASHAnalysisSidecar) -> R08AnalysisRequest {
        switch sidecar.outcome {
        case .analyzed(let result): result.request
        case .bypassed(let bypass): bypass.request
        }
    }

    static func composeMasks(
        frame: R09PlanarFrameQ16,
        ashRequestedLumaMask: R09MaskPlaneQ15,
        protectedComposition: R07ProtectedMaskComposition,
        heads: R08AnalysisHeads
    ) throws -> ComposedMasks {
        let luma = frame.luma
        guard ashRequestedLumaMask.id == .luma else {
            throw R09ASHResidualAuthorizationError.ashMaskPlaneMismatch(
                actual: ashRequestedLumaMask.id
            )
        }
        try requireGeometry(
            role: .ashRequestedLuma,
            expectedWidth: luma.width,
            expectedHeight: luma.height,
            actualWidth: ashRequestedLumaMask.width,
            actualHeight: ashRequestedLumaMask.height
        )
        try requireGeometry(
            role: .protectedComposition,
            expectedWidth: luma.width,
            expectedHeight: luma.height,
            actualWidth: protectedComposition.width,
            actualHeight: protectedComposition.height
        )

        let chromaWidth = luma.width / 2
        let chromaHeight = luma.height / 2
        guard luma.width.isMultiple(of: 2), luma.height.isMultiple(of: 2) else {
            throw R09ASHResidualAuthorizationError.geometryMismatch(
                role: .chromaCb,
                expectedWidth: chromaWidth,
                expectedHeight: chromaHeight,
                actualWidth: frame.chromaCb.width,
                actualHeight: frame.chromaCb.height
            )
        }
        try requireGeometry(
            role: .chromaCb,
            expectedWidth: chromaWidth,
            expectedHeight: chromaHeight,
            actualWidth: frame.chromaCb.width,
            actualHeight: frame.chromaCb.height
        )
        try requireGeometry(
            role: .chromaCr,
            expectedWidth: chromaWidth,
            expectedHeight: chromaHeight,
            actualWidth: frame.chromaCr.width,
            actualHeight: frame.chromaCr.height
        )

        let aliasingRisk = try expand(heads.riskConfidence.aliasingRingingRiskQ15, to: luma)
        let textureConfidence = try expand(
            heads.riskConfidence.textureDetailConfidenceQ15,
            to: luma
        )
        let motionOcclusionRisk = try expand(
            heads.riskConfidence.motionReliabilityOcclusionRiskQ15,
            to: luma
        )
        let faceProtection = try expand(heads.protection.faceSkinQ15, to: luma)
        let textProtection = try expand(heads.protection.textLineArtQ15, to: luma)

        var lumaEligibility: [Int64] = [], lumaProtection: [Int64] = []
        for index in luma.samplesQ16.indices {
            let protectedQ15 = max(
                protectedComposition.composedQ15[index].rawValue,
                faceProtection[index],
                textProtection[index]
            )
            let motionSafeQ15 = R09MaskPlaneQ15.maximumSample - motionOcclusionRisk[index]
            let learnedEligibilityQ15 = min(
                aliasingRisk[index],
                textureConfidence[index],
                motionSafeQ15
            )
            lumaProtection.append(protectedQ15)
            lumaEligibility.append(
                protectedQ15 == 0
                    ? min(ashRequestedLumaMask.samplesQ15[index], learnedEligibilityQ15)
                    : 0
            )
        }

        let chromaEligibility = downsampleMinimum(
            lumaEligibility,
            lumaWidth: luma.width,
            lumaHeight: luma.height
        )
        let chromaProtection = downsampleMaximum(
            lumaProtection,
            lumaWidth: luma.width,
            lumaHeight: luma.height
        )
        return try ComposedMasks(
            eligible: planarMask(
                luma: lumaEligibility,
                chroma: chromaEligibility,
                lumaWidth: luma.width,
                lumaHeight: luma.height
            ),
            protected: planarMask(
                luma: lumaProtection,
                chroma: chromaProtection,
                lumaWidth: luma.width,
                lumaHeight: luma.height
            )
        )
    }

    static func expand(
        _ map: R08Q15Map,
        to luma: R09UnsignedPlaneQ16
    ) throws -> [Int64] {
        guard luma.width.isMultiple(of: map.width),
              luma.height.isMultiple(of: map.height) else {
            throw R09ASHResidualAuthorizationError.unsupportedAnalysisMapGeometry(
                mapWidth: map.width,
                mapHeight: map.height,
                lumaWidth: luma.width,
                lumaHeight: luma.height
            )
        }
        let horizontalScale = luma.width / map.width
        let verticalScale = luma.height / map.height
        return (0..<luma.height).flatMap { row in
            (0..<luma.width).map { column in
                let sourceRow = row / verticalScale
                let sourceColumn = column / horizontalScale
                return map.samples[sourceRow * map.width + sourceColumn]
            }
        }
    }

    static func downsampleMinimum(
        _ luma: [Int64],
        lumaWidth: Int,
        lumaHeight: Int
    ) -> [Int64] {
        downsample(luma, lumaWidth: lumaWidth, lumaHeight: lumaHeight, combine: min)
    }

    static func downsampleMaximum(
        _ luma: [Int64],
        lumaWidth: Int,
        lumaHeight: Int
    ) -> [Int64] {
        downsample(luma, lumaWidth: lumaWidth, lumaHeight: lumaHeight, combine: max)
    }

    static func downsample(
        _ luma: [Int64],
        lumaWidth: Int,
        lumaHeight: Int,
        combine: (Int64, Int64) -> Int64
    ) -> [Int64] {
        (0..<(lumaHeight / 2)).flatMap { chromaRow in
            (0..<(lumaWidth / 2)).map { chromaColumn in
                let topLeft = chromaRow * 2 * lumaWidth + chromaColumn * 2
                return [
                    luma[topLeft],
                    luma[topLeft + 1],
                    luma[topLeft + lumaWidth],
                    luma[topLeft + lumaWidth + 1]
                ].dropFirst().reduce(luma[topLeft], combine)
            }
        }
    }

    static func planarMask(
        luma: [Int64],
        chroma: [Int64],
        lumaWidth: Int,
        lumaHeight: Int
    ) throws -> R09PlanarMaskQ15 {
        let chromaWidth = lumaWidth / 2
        let chromaHeight = lumaHeight / 2
        return try R09PlanarMaskQ15(
            planes: [
                R09MaskPlaneQ15(
                    id: .luma,
                    width: lumaWidth,
                    height: lumaHeight,
                    samplesQ15: luma
                ),
                R09MaskPlaneQ15(
                    id: .chromaCb,
                    width: chromaWidth,
                    height: chromaHeight,
                    samplesQ15: chroma
                ),
                R09MaskPlaneQ15(
                    id: .chromaCr,
                    width: chromaWidth,
                    height: chromaHeight,
                    samplesQ15: chroma
                )
            ]
        )
    }

    static func requireGeometry(
        role: R09ASHResidualGeometryRole,
        expectedWidth: Int,
        expectedHeight: Int,
        actualWidth: Int,
        actualHeight: Int
    ) throws {
        guard expectedWidth == actualWidth, expectedHeight == actualHeight else {
            throw R09ASHResidualAuthorizationError.geometryMismatch(
                role: role,
                expectedWidth: expectedWidth,
                expectedHeight: expectedHeight,
                actualWidth: actualWidth,
                actualHeight: actualHeight
            )
        }
    }
}
