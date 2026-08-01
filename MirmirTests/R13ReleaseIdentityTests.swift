import XCTest
@testable import Mirmir

final class R13ReleaseIdentityTests: XCTestCase {
    func testIdentityHashIsDeterministicAndBindsEveryReleaseDimension() throws {
        let first = try makeIdentity()
        let second = try makeIdentity()

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.identitySHA256.count, 64)
        XCTAssertEqual(first.source.sha256, hash("1"))
        XCTAssertEqual(first.source.byteCount, 9_876_543)
        XCTAssertEqual(first.requestedMode, .quality)
        XCTAssertEqual(first.enginePreference, .automatic)
        XCTAssertEqual(first.effectiveMode, .quality)
        XCTAssertEqual(first.output.width, 3_840)
        XCTAssertEqual(first.output.height, 2_160)
        XCTAssertEqual(first.capabilityID, "R13-QUALITY-ROUTER")
        XCTAssertEqual(first.backendID, "r13.quality.router")
        XCTAssertEqual(
            first.backendRevision,
            "r13.product-router.v1"
        )
        XCTAssertEqual(first.routeID, "scale_2x")
        XCTAssertEqual(
            first.framework.frameworkIdentifier,
            "AppleNativeMultiEngine"
        )

        XCTAssertEqual(first.timedMetadata.count, 39)
        let routingMetadata = try R13ProductASHDecisionSummary(
            events: [
                R13ProductASHDecisionEvent(
                    sequenceNumber: 0,
                    selectedRouteIdentity:
                        try releaseDecisionRoute(
                            backendID:
                                "r03.vimage.lanczos-5",
                            configurationIdentity:
                                "r03.vimage.lanczos5.scale-2x"
                        ),
                    reason: .initialSelection,
                    fallbackHistory: []
                )
            ]
        ).outputMetadata()
        let metadata = try first.finalizedTimedMetadata(
            routingDecisionMetadata: routingMetadata
        )
        XCTAssertTrue(
            metadata.keys.allSatisfy {
                $0.hasPrefix(R13ReleaseIdentity.metadataNamespace)
            }
        )
        XCTAssertEqual(
            metadata["com.mirmir.release.model-status"],
            "not_required"
        )
        XCTAssertEqual(
            metadata["com.mirmir.release.fallback-history"],
            "[]"
        )
        XCTAssertEqual(
            metadata[
                "com.mirmir.release.source-scan-structure"
            ],
            "progressive"
        )
        XCTAssertEqual(
            metadata[
                "com.mirmir.release.deinterlacing-algorithm"
            ],
            "not_required"
        )
        XCTAssertEqual(
            metadata[
                "com.mirmir.release.output-scan-structure"
            ],
            "progressive"
        )
        XCTAssertEqual(
            metadata["com.mirmir.release.identity-sha256"],
            first.identitySHA256
        )
        XCTAssertEqual(
            metadata[
                R13ProductASHDecisionMetadata.statusKey
            ],
            "complete"
        )
        XCTAssertNoThrow(try first.validateTimedMetadata(metadata))
        XCTAssertThrowsError(
            try first.finalizedTimedMetadata(
                routingDecisionMetadata: nil
            )
        ) { error in
            XCTAssertEqual(
                error as? R13ReleaseIdentityError,
                .routingDecisionMetadataMissing
            )
        }
    }

    func testInterlacedSourceBindsDeinterlacingIntoIdentityAndMetadata()
        throws {
        let progressive = try makeIdentity()
        let interlaced = try makeIdentity(
            sourceScanStructure: .interlacedTopFieldFirst
        )

        XCTAssertNotEqual(
            progressive.identitySHA256,
            interlaced.identitySHA256
        )
        XCTAssertEqual(
            interlaced.sourceScanStructure,
            .interlacedTopFieldFirst
        )
        XCTAssertEqual(
            interlaced.deinterlacingAlgorithmIdentity,
            R13FormatPreservingDeinterlacer.algorithmIdentity
        )
        XCTAssertEqual(
            interlaced.timedMetadata[
                "com.mirmir.release.source-scan-structure"
            ],
            "interlaced_top_field_first"
        )
        XCTAssertEqual(
            interlaced.timedMetadata[
                "com.mirmir.release.deinterlacing-algorithm"
            ],
            R13FormatPreservingDeinterlacer.algorithmIdentity
        )
    }

    func testRoutingExclusionsAndResumeBoundariesAreTypedCanonicalEvidence()
        throws {
        let identity = try makeIdentity()
        let exclusion =
            R13ProductASHScalingCandidateExclusion(
                declaredCandidateKind:
                    .videoToolboxQuality,
                expectedBackendID:
                    R04VideoToolboxSubjectID
                        .quality2x.rawValue,
                phase: .sessionConstruction,
                failure:
                    R13ProductASHScalingCandidateFailureEvidence(
                        error: NSError(
                            domain: "test.release.identity",
                            code: 17
                        )
                    )
            )
        let routingMetadata =
            try R13ProductASHDecisionSummary(
                events: [
                    R13ProductASHDecisionEvent(
                        sequenceNumber: 0,
                        selectedRouteIdentity:
                            try releaseDecisionRoute(
                                backendID:
                                    "r03.vimage.lanczos-5",
                                configurationIdentity:
                                    "r03.vimage.lanczos5.scale-2x"
                            ),
                        reason: .initialSelection,
                        fallbackHistory: [],
                        processingPressureQ16: 1_024
                    )
                ],
                candidateExclusions: [exclusion],
                resumeBoundaries: [
                    R13ProductASHResumeBoundary(
                        sequenceNumber: 0,
                        kind: .fullCacheNoBackendWarmup
                    )
                ]
            ).outputMetadata()
        let metadata = try identity.finalizedTimedMetadata(
            routingDecisionMetadata: routingMetadata
        )

        XCTAssertNoThrow(
            try identity.validateTimedMetadata(metadata)
        )
        XCTAssertEqual(
            metadata[
                R13ProductASHDecisionMetadata
                    .candidateExclusionCountKey
            ],
            "1"
        )
        XCTAssertEqual(
            metadata[
                R13ProductASHDecisionMetadata
                    .resumeBoundaryCountKey
            ],
            "1"
        )

        var mismatchedExclusionCount = metadata
        mismatchedExclusionCount[
            R13ProductASHDecisionMetadata
                .candidateExclusionCountKey
        ] = "2"
        assertRoutingMetadataError(
            identity: identity,
            metadata: mismatchedExclusionCount,
            field: "routing_candidate_exclusions"
        )

        var noncanonicalExclusions = metadata
        noncanonicalExclusions[
            R13ProductASHDecisionMetadata
                .candidateExclusionsKey
        ] = " "
            + routingMetadata.candidateExclusionsJSON
        assertRoutingMetadataError(
            identity: identity,
            metadata: noncanonicalExclusions,
            field: "routing_candidate_exclusions"
        )

        var invalidTypedExclusion = metadata
        invalidTypedExclusion[
            R13ProductASHDecisionMetadata
                .candidateExclusionsKey
        ] = routingMetadata.candidateExclusionsJSON
            .replacingOccurrences(
                of: R04VideoToolboxSubjectID
                    .quality2x.rawValue,
                with: ""
            )
        assertRoutingMetadataError(
            identity: identity,
            metadata: invalidTypedExclusion,
            field: "routing_candidate_exclusions"
        )

        var mismatchedBoundaryCount = metadata
        mismatchedBoundaryCount[
            R13ProductASHDecisionMetadata
                .resumeBoundaryCountKey
        ] = "2"
        assertRoutingMetadataError(
            identity: identity,
            metadata: mismatchedBoundaryCount,
            field: "routing_resume_boundaries"
        )

        var invalidBoundary = metadata
        invalidBoundary[
            R13ProductASHDecisionMetadata.resumeBoundariesKey
        ] = routingMetadata.resumeBoundariesJSON.replacingOccurrences(
            of: "\"restoredHistoryFrameCount\":0",
            with: "\"restoredHistoryFrameCount\":1"
        )
        assertRoutingMetadataError(
            identity: identity,
            metadata: invalidBoundary,
            field: "routing_resume_boundaries"
        )
    }

    func testFinalizedRoutingModelStatusTracksActualRoutesAndRejectsMismatch()
        throws {
        let identity = try makeIdentity()
        let appleManagedRoute = try releaseDecisionRoute(
            backendID: "r04.videotoolbox.quality",
            configurationIdentity:
                "r04.quality.scale-2x.observed.model-ready",
            modelAssetsIdentity:
                .appleConfigurationManaged(
                    configurationIdentity:
                        "r04.quality.scale-2x",
                    readiness: .ready
                )
        )
        let fallbackRoute = try releaseDecisionRoute(
            backendID: "r03.vimage.lanczos-5",
            configurationIdentity:
                "r03.vimage.lanczos5.scale-2x"
        )
        let appleManagedRoutingMetadata =
            try R13ProductASHDecisionSummary(
                events: [
                    R13ProductASHDecisionEvent(
                        sequenceNumber: 0,
                        selectedRouteIdentity:
                            appleManagedRoute,
                        reason: .initialSelection,
                        fallbackHistory: []
                    )
                ]
            ).outputMetadata()

        XCTAssertEqual(
            appleManagedRoutingMetadata
                .selectedModelStatuses,
            [.appleConfigurationManagedReady]
        )
        XCTAssertEqual(
            appleManagedRoutingMetadata.modelStatus,
            "apple_configuration_managed_ready"
        )
        let appleManagedOutput =
            try identity.finalizedTimedMetadata(
                routingDecisionMetadata:
                    appleManagedRoutingMetadata
            )
        XCTAssertEqual(
            appleManagedOutput[
                R13ProductASHDecisionMetadata.modelStatusKey
            ],
            "apple_configuration_managed_ready"
        )
        XCTAssertNoThrow(
            try identity.validateTimedMetadata(
                appleManagedOutput
            )
        )

        var mismatched = appleManagedOutput
        mismatched[
            R13ProductASHDecisionMetadata.modelStatusKey
        ] = "not_required"
        XCTAssertThrowsError(
            try identity.validateTimedMetadata(mismatched)
        ) { error in
            XCTAssertEqual(
                error as? R13ReleaseIdentityError,
                .routingDecisionMetadataInvalid(
                    field: "routing_model_status"
                )
            )
        }

        let mixedRoutingMetadata =
            try R13ProductASHDecisionSummary(
                events: [
                    R13ProductASHDecisionEvent(
                        sequenceNumber: 0,
                        selectedRouteIdentity:
                            appleManagedRoute,
                        reason: .initialSelection,
                        fallbackHistory: []
                    ),
                    R13ProductASHDecisionEvent(
                        sequenceNumber: 1,
                        selectedRouteIdentity:
                            fallbackRoute,
                        reason: .fatalBackendFailover,
                        fallbackHistory: [
                            try AppleUpscaleFallbackLink(
                                failedRoute: appleManagedRoute,
                                selectedRoute: fallbackRoute,
                                reasonCode: .backendUnavailable,
                                selectedFallbackOrdinal: 0
                            )
                        ]
                    )
                ]
            ).outputMetadata()
        let mixedOutput =
            try identity.finalizedTimedMetadata(
                routingDecisionMetadata:
                    mixedRoutingMetadata
            )
        XCTAssertEqual(
            mixedOutput[
                R13ProductASHDecisionMetadata.modelStatusKey
            ],
            "mixed"
        )
        XCTAssertEqual(
            mixedOutput[
                R13ProductASHDecisionMetadata
                    .selectedModelStatusesKey
            ],
            "apple_configuration_managed_ready,not_required"
        )
        XCTAssertNoThrow(
            try identity.validateTimedMetadata(mixedOutput)
        )

        var mismatchedFallbackCount = mixedOutput
        mismatchedFallbackCount[
            R13ProductASHDecisionMetadata.fallbackCountKey
        ] = "2"
        assertRoutingMetadataError(
            identity: identity,
            metadata: mismatchedFallbackCount,
            field: "routing_fallback_events"
        )

        var noncanonicalFallbackEvents = mixedOutput
        noncanonicalFallbackEvents[
            R13ProductASHDecisionMetadata.fallbackEventsKey
        ] = " " + mixedRoutingMetadata.fallbackEventsJSON
        assertRoutingMetadataError(
            identity: identity,
            metadata: noncanonicalFallbackEvents,
            field: "routing_fallback_events"
        )

        var invalidFallbackReason = mixedOutput
        invalidFallbackReason[
            R13ProductASHDecisionMetadata.fallbackEventsKey
        ] = mixedRoutingMetadata.fallbackEventsJSON
            .replacingOccurrences(
                of: AppleUpscaleFallbackReasonCode
                    .backendUnavailable.rawValue,
                with: "invented_reason"
            )
        assertRoutingMetadataError(
            identity: identity,
            metadata: invalidFallbackReason,
            field: "routing_fallback_events"
        )

        var invalidFallbackRoute = mixedOutput
        invalidFallbackRoute[
            R13ProductASHDecisionMetadata.fallbackEventsKey
        ] = mixedRoutingMetadata.fallbackEventsJSON
            .replacingOccurrences(
                of: "r13.release.decision.test.v1",
                with: ""
            )
        assertRoutingMetadataError(
            identity: identity,
            metadata: invalidFallbackRoute,
            field: "routing_fallback_events"
        )

        var duplicatedStatus = mixedOutput
        duplicatedStatus[
            R13ProductASHDecisionMetadata
                .selectedModelStatusesKey
        ] =
            "apple_configuration_managed_ready,"
            + "apple_configuration_managed_ready"
        XCTAssertThrowsError(
            try identity.validateTimedMetadata(
                duplicatedStatus
            )
        ) { error in
            XCTAssertEqual(
                error as? R13ReleaseIdentityError,
                .routingDecisionMetadataInvalid(
                    field:
                        "routing_selected_model_statuses"
                )
            )
        }
    }

    func testPolicyClaimsBindRouteClassAndRejectCrossedDirectRouterSemantics()
        throws {
        let direct = R13ReleaseModePolicy.binding(
            for: .deterministic
        )
        let router = R13ReleaseModePolicy.binding(
            for: .quality
        )
        let directProduct =
            R13ReleaseRoutePolicyClaim.canonical(
                routeClass: .canonicalProduct,
                binding: direct
            )
        let routerProduct =
            R13ReleaseRoutePolicyClaim.canonical(
                routeClass: .canonicalProduct,
                binding: router
            )
        let directAdaptive =
            R13ReleaseRoutePolicyClaim.canonical(
                routeClass:
                    .adaptiveFormatGeometry,
                binding: direct
            )
        let routerAdaptive =
            R13ReleaseRoutePolicyClaim.canonical(
                routeClass:
                    .adaptiveFormatGeometry,
                binding: router
            )
        let explicitQualityAdaptive =
            R13ReleaseRoutePolicyClaim.canonical(
                routeClass: .adaptiveFormatGeometry,
                binding: R13ReleaseModePolicy.binding(
                    for: .quality,
                    enginePreference: .videoToolboxQuality
                )
            )
        let explicitQualityProduct =
            R13ReleaseRoutePolicyClaim.canonical(
                routeClass: .canonicalProduct,
                binding: R13ReleaseModePolicy.binding(
                    for: .quality,
                    enginePreference: .videoToolboxQuality
                )
            )
        let explicitLowLatencyProduct =
            R13ReleaseRoutePolicyClaim.canonical(
                routeClass: .canonicalProduct,
                binding: R13ReleaseModePolicy.binding(
                    for: .fast,
                    enginePreference: .videoToolboxLowLatency
                )
            )
        let explicitMetalFXProduct =
            R13ReleaseRoutePolicyClaim.canonical(
                routeClass: .canonicalProduct,
                binding: R13ReleaseModePolicy.binding(
                    for: .fast,
                    enginePreference: .metalFXSpatial
                )
            )
        let automaticFastProduct =
            R13ReleaseRoutePolicyClaim.canonical(
                routeClass: .canonicalProduct,
                binding: R13ReleaseModePolicy.binding(
                    for: .fast
                )
            )

        XCTAssertEqual(
            directProduct.modelStatus,
            .notRequired
        )
        XCTAssertEqual(
            directProduct.fallbackSemantics,
            .forbidden
        )
        XCTAssertEqual(
            routerProduct.modelStatus,
            .runtimeSelected
        )
        XCTAssertEqual(
            routerProduct.fallbackSemantics,
            .runtimeSelectedOrderedFailover
        )
        XCTAssertEqual(
            directAdaptive.modelStatus,
            .notRequired
        )
        XCTAssertEqual(
            directAdaptive.fallbackSemantics,
            .forbidden
        )
        XCTAssertEqual(
            routerAdaptive.modelStatus,
            .notRequired
        )
        XCTAssertEqual(
            routerAdaptive.fallbackSemantics,
            .runtimeSelectedOrderedFailover
        )
        XCTAssertEqual(
            explicitQualityAdaptive.modelStatus,
            .runtimeSelected
        )
        XCTAssertEqual(
            explicitQualityAdaptive.fallbackSemantics,
            .forbidden
        )
        XCTAssertEqual(
            explicitQualityProduct.modelStatus,
            .runtimeSelected
        )
        XCTAssertEqual(
            explicitQualityProduct.fallbackSemantics,
            .forbidden
        )
        XCTAssertEqual(
            explicitLowLatencyProduct.modelStatus,
            .notRequired
        )
        XCTAssertEqual(
            explicitLowLatencyProduct.fallbackSemantics,
            .forbidden
        )
        XCTAssertEqual(
            explicitMetalFXProduct.modelStatus,
            .notRequired
        )
        XCTAssertEqual(
            explicitMetalFXProduct.fallbackSemantics,
            .forbidden
        )
        XCTAssertEqual(
            automaticFastProduct.modelStatus,
            .runtimeSelected
        )
        XCTAssertEqual(
            automaticFastProduct.fallbackSemantics,
            .runtimeSelectedOrderedFailover
        )

        XCTAssertThrowsError(
            try R13ReleaseRoutePolicyClaim(
                routeClass: .canonicalProduct,
                binding: router,
                modelStatus: .notRequired,
                fallbackSemantics:
                    .runtimeSelectedOrderedFailover
            )
        ) { error in
            XCTAssertEqual(
                error as?
                    R13ReleaseRoutePolicyClaimError,
                .modelStatusMismatch(
                    routeClass: .canonicalProduct,
                    expected: .runtimeSelected,
                    actual: .notRequired
                )
            )
        }
        XCTAssertThrowsError(
            try R13ReleaseRoutePolicyClaim(
                routeClass:
                    .adaptiveFormatGeometry,
                binding: direct,
                modelStatus: .notRequired,
                fallbackSemantics:
                    .runtimeSelectedOrderedFailover
            )
        ) { error in
            XCTAssertEqual(
                error as?
                    R13ReleaseRoutePolicyClaimError,
                .fallbackSemanticsMismatch(
                    routeClass:
                        .adaptiveFormatGeometry,
                    expected: .forbidden,
                    actual:
                        .runtimeSelectedOrderedFailover
                )
            )
        }

        let document = R13ReleasePolicyDocument(
            bindings: [direct, router]
        )
        XCTAssertEqual(
            document.modes.map(
                \.canonicalProductRoutePolicy
            ),
            [directProduct, routerProduct]
        )
        XCTAssertEqual(
            document.modes.map(
                \.adaptiveFormatGeometryRoutePolicy
            ),
            [directAdaptive, routerAdaptive]
        )
    }

    func testExactNativeMetadataRejectsWrongBackendFallbackAndModelClaims()
        throws {
        let scenarios: [(
            preference: UpscaleEnginePreference,
            mode: UpscaleMode,
            backendID: String,
            modelAssets: AppleUpscaleModelAssetsIdentity
        )] = [
            (
                .videoToolboxQuality,
                .quality,
                R04VideoToolboxSubjectID.quality2x.rawValue,
                .appleConfigurationManaged(
                    configurationIdentity:
                        "r04.quality.scale-2x",
                    readiness: .ready
                )
            ),
            (
                .videoToolboxLowLatency,
                .fast,
                R04VideoToolboxSubjectID.lowLatency2x.rawValue,
                .notRequired
            ),
            (
                .metalFXSpatial,
                .fast,
                R05MetalFXSubjectID.spatial2x.rawValue,
                .notRequired
            )
        ]

        for scenario in scenarios {
            let identity = try makeExactNativeIdentity(
                preference: scenario.preference,
                mode: scenario.mode
            )
            let routingMetadata = try R13ProductASHDecisionSummary(
                events: [
                    R13ProductASHDecisionEvent(
                        sequenceNumber: 0,
                        selectedRouteIdentity:
                            try releaseDecisionRoute(
                                backendID: scenario.backendID,
                                configurationIdentity:
                                    "exact-native-configuration",
                                modelAssetsIdentity:
                                    scenario.modelAssets
                            ),
                        reason: .initialSelection,
                        fallbackHistory: []
                    )
                ]
            ).outputMetadata()
            let metadata = try identity.finalizedTimedMetadata(
                routingDecisionMetadata: routingMetadata
            )
            XCTAssertNoThrow(
                try identity.validateTimedMetadata(metadata),
                scenario.preference.rawValue
            )

            var wrongBackend = metadata
            wrongBackend[
                R13ProductASHDecisionMetadata.selectedBackendsKey
            ] = R13ReleaseModePolicy.binding(
                for: scenario.mode,
                enginePreference: scenario.preference
            ).backendID
            assertRoutingMetadataError(
                identity: identity,
                metadata: wrongBackend,
                field: "routing_exact_native_policy"
            )
        }

        let qualityIdentity = try makeExactNativeIdentity(
            preference: .videoToolboxQuality,
            mode: .quality
        )
        let qualityRoute = try releaseDecisionRoute(
            backendID: R04VideoToolboxSubjectID.quality2x.rawValue,
            configurationIdentity: "exact-native-quality",
            modelAssetsIdentity: .appleConfigurationManaged(
                configurationIdentity: "r04.quality.scale-2x",
                readiness: .ready
            )
        )
        let qualityRoutingMetadata = try R13ProductASHDecisionSummary(
            events: [
                R13ProductASHDecisionEvent(
                    sequenceNumber: 0,
                    selectedRouteIdentity: qualityRoute,
                    reason: .initialSelection,
                    fallbackHistory: []
                )
            ]
        ).outputMetadata()
        let qualityMetadata = try qualityIdentity.finalizedTimedMetadata(
            routingDecisionMetadata: qualityRoutingMetadata
        )

        var falseFallback = qualityMetadata
        falseFallback[
            R13ProductASHDecisionMetadata.fallbackCountKey
        ] = "1"
        assertRoutingMetadataError(
            identity: qualityIdentity,
            metadata: falseFallback,
            field: "routing_exact_native_policy"
        )

        var falseTransition = qualityMetadata
        falseTransition[
            R13ProductASHDecisionMetadata.decisionCountKey
        ] = "2"
        falseTransition[
            R13ProductASHDecisionMetadata.transitionCountKey
        ] = "1"
        assertRoutingMetadataError(
            identity: qualityIdentity,
            metadata: falseTransition,
            field: "routing_exact_native_policy"
        )

        var falseModel = qualityMetadata
        falseModel[
            R13ProductASHDecisionMetadata.selectedModelStatusesKey
        ] = R13ProductASHSelectedModelStatus.notRequired.rawValue
        falseModel[
            R13ProductASHDecisionMetadata.modelStatusKey
        ] = R13ProductASHSelectedModelStatus.notRequired.rawValue
        assertRoutingMetadataError(
            identity: qualityIdentity,
            metadata: falseModel,
            field: "routing_exact_native_policy"
        )
    }

    func testAdaptiveIdentityAndPolicyBindTheExactDynamicQualityPlan()
        throws {
        let plan = try R13AdaptiveScalePlan(
            sourceResolution: VideoResolution(width: 728, height: 410),
            targetResolution: VideoResolution(width: 1_278, height: 720)
        )
        let scalePlan = R13ReleaseScalePlan.adaptiveMPSLanczos(plan)
        let basePolicy = try R13ReleasePolicyResourceBinding(
            policySHA256: hash("2"),
            resourceManifestSHA256: hash("3")
        )
        let boundPolicy = try R13ReleaseHardeningRuntime.policyResources(
            for: scalePlan,
            base: basePolicy
        )
        let policyDocument = R13AdaptiveReleasePolicyDocument(plan: plan)
        let policyData = try R13RestartCanonical.data(policyDocument)
        let decodedPolicy = try JSONDecoder().decode(
            R13AdaptiveReleasePolicyDocument.self,
            from: policyData
        )

        XCTAssertEqual(decodedPolicy, policyDocument)
        XCTAssertEqual(
            policyDocument.modelStatus,
            R13ReleasePolicyModelStatus
                .notRequired.rawValue
        )
        XCTAssertEqual(
            policyDocument.fallbackPolicy,
            R13ReleasePolicyFallbackSemantics
                .forbidden.rawValue
        )
        let routedPolicy =
            R13AdaptiveReleasePolicyDocument(
                plan: plan,
                modeBinding:
                    R13ReleaseModePolicy.binding(
                        for: .quality
                    )
            )
        XCTAssertEqual(
            routedPolicy.modelStatus,
            R13ReleasePolicyModelStatus
                .notRequired.rawValue
        )
        XCTAssertEqual(
            routedPolicy.fallbackPolicy,
            R13ReleasePolicyFallbackSemantics
                .runtimeSelectedOrderedFailover
                .rawValue
        )
        let exactQualityPolicy =
            R13AdaptiveReleasePolicyDocument(
                plan: plan,
                modeBinding:
                    R13ReleaseModePolicy.binding(
                        for: .quality,
                        enginePreference: .videoToolboxQuality
                    )
            )
        XCTAssertEqual(
            exactQualityPolicy.modelStatus,
            R13ReleasePolicyModelStatus.runtimeSelected.rawValue
        )
        XCTAssertEqual(
            exactQualityPolicy.fallbackPolicy,
            R13ReleasePolicyFallbackSemantics.forbidden.rawValue
        )
        let exactMetalFXPolicy =
            R13AdaptiveReleasePolicyDocument(
                plan: plan,
                modeBinding:
                    R13ReleaseModePolicy.binding(
                        for: .fast,
                        enginePreference: .metalFXSpatial
                    )
            )
        XCTAssertEqual(
            exactMetalFXPolicy.modelStatus,
            R13ReleasePolicyModelStatus.notRequired.rawValue
        )
        XCTAssertEqual(
            exactMetalFXPolicy.fallbackPolicy,
            R13ReleasePolicyFallbackSemantics.forbidden.rawValue
        )
        XCTAssertEqual(
            boundPolicy.policySHA256,
            R13CryptoKitRestartDigest().sha256(policyData)
        )
        XCTAssertNotEqual(
            boundPolicy.policySHA256,
            basePolicy.policySHA256
        )
        XCTAssertEqual(
            boundPolicy.resourceManifestSHA256,
            basePolicy.resourceManifestSHA256
        )
        XCTAssertEqual(
            try R13ReleaseHardeningRuntime.policyResources(
                for: .productQualified(.scale2x),
                base: basePolicy
            ),
            basePolicy
        )

        let identity = try R13ReleaseIdentity(
            try makeAdaptiveInput(
                plan: plan,
                policyResources: boundPolicy
            )
        )

        let modeBinding = R13ReleaseModePolicy.binding(for: .quality)
        XCTAssertEqual(
            identity.capabilityID,
            modeBinding.capabilityID
        )
        XCTAssertEqual(
            identity.backendID,
            modeBinding.backendID
        )
        XCTAssertEqual(
            identity.routeID,
            modeBinding.adaptiveRouteID
        )
        XCTAssertEqual(
            identity.configurationIdentity,
            modeBinding
                .adaptiveConfigurationIdentity(for: plan)
        )
        XCTAssertEqual(
            identity.policyIdentity,
            modeBinding.policyIdentity
        )
        XCTAssertEqual(
            identity.materialDecisionIdentity,
            modeBinding.materialDecisionIdentity
        )
        XCTAssertEqual(identity.policyResources, boundPolicy)
        XCTAssertNotEqual(identity.identitySHA256, try makeIdentity().identitySHA256)
        XCTAssertEqual(
            identity.timedMetadata[
                R13ProductASHDecisionMetadata.statusKey
            ],
            "pending"
        )
        XCTAssertThrowsError(
            try identity.finalizedTimedMetadata(
                routingDecisionMetadata: nil
            )
        ) { error in
            XCTAssertEqual(
                error as? R13ReleaseIdentityError,
                .routingDecisionMetadataMissing
            )
        }
        let invalidAdaptiveModelMetadata =
            try R13ProductASHDecisionSummary(
                events: [
                    R13ProductASHDecisionEvent(
                        sequenceNumber: 0,
                        selectedRouteIdentity:
                            try releaseDecisionRoute(
                                backendID:
                                    "r04.videotoolbox.quality",
                                configurationIdentity:
                                    "r04.quality.observed",
                                modelAssetsIdentity:
                                    .appleConfigurationManaged(
                                        configurationIdentity:
                                            "r04.quality",
                                        readiness: .ready
                                    )
                            ),
                        reason: .initialSelection,
                        fallbackHistory: []
                    )
                ]
            ).outputMetadata()
        XCTAssertThrowsError(
            try identity.finalizedTimedMetadata(
                routingDecisionMetadata:
                    invalidAdaptiveModelMetadata
            )
        ) { error in
            XCTAssertEqual(
                error as? R13ReleaseIdentityError,
                .routingDecisionMetadataInvalid(
                    field:
                        "routing_model_status_policy"
                )
            )
        }

        let job = UpscaleJob(
            identifier: "r13-adaptive-identity",
            inputURL: URL(fileURLWithPath: "/tmp/adaptive-input"),
            outputURL: URL(fileURLWithPath: "/tmp/adaptive-output.mp4"),
            targetResolution: plan.targetResolution,
            codec: .hevc,
            preserveAudio: true,
            mode: .quality
        )
        let source = try R13RestartSourceIdentity(
            sha256: hash("1"),
            byteCount: 9_876_543
        )
        let core = try R13ReleaseHardeningRuntime.makeRestartCore(
            job: job,
            scalePlan: scalePlan,
            identity: identity,
            modeBinding: modeBinding,
            source: source,
            totalFrameCount: 17
        )
        XCTAssertEqual(
            core.processing.routeIdentity,
            "\(modeBinding.adaptiveRouteID):"
                + modeBinding
                    .adaptiveConfigurationIdentity(for: plan)
                + ":release-\(identity.identitySHA256)"
                + ":\(job.processingConfiguration.identity)"
                + ":progressive:not_required"
        )
        XCTAssertEqual(
            core.processing.backendIdentity,
            modeBinding.backendID
        )
    }

    func testAdaptiveIdentityRejectsAnA11RouteClaim() throws {
        let plan = try R13AdaptiveScalePlan(
            sourceResolution: VideoResolution(width: 728, height: 410),
            targetResolution: VideoResolution(width: 1_278, height: 720)
        )
        let input = try makeAdaptiveInput(
            plan: plan,
            policyResources: R13ReleasePolicyResourceBinding(
                policySHA256: hash("2"),
                resourceManifestSHA256: hash("3")
            )
        )
        let invalid = replacingRoute(
            input,
            with: try R13ReleaseIdentity.makeA11Route(for: .scale2x)
        )

        XCTAssertThrowsError(try R13ReleaseIdentity(invalid)) { error in
            XCTAssertEqual(
                error as? R13ReleaseIdentityError,
                .adaptiveBindingMismatch(field: "backend_id")
            )
        }
    }

    func testRestartCoreBindsFullReleaseIdentityAndRejectsIdentityDrift()
        async throws {
        let input = try makeDirectInput()
        let identity = try R13ReleaseIdentity(input)
        let core = try restartCore(
            input: input,
            identity: identity,
            jobID: "r13-release-identity-drift"
        )
        let identicalIdentity = try R13ReleaseIdentity(input)
        let identicalCore = try restartCore(
            input: input,
            identity: identicalIdentity,
            jobID: core.jobID
        )
        let releaseComponent = try R13RestartProcessingIdentity
            .releaseIdentityComponent(
                sha256: identity.identitySHA256
            )

        XCTAssertEqual(
            identicalIdentity.identitySHA256,
            identity.identitySHA256
        )
        XCTAssertEqual(identicalCore, core)
        XCTAssertEqual(
            core.processing.routeIdentity,
            "scale_2x:"
                + "\(identity.configurationIdentity):"
                + "\(releaseComponent):"
                + "\(identity.processingConfigurationIdentity):"
                + "progressive:not_required"
        )

        let changedInputs = try directRestartDriftInputs(input)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = R13RestartJobStore(jobsRootURL: root)
        _ = try await store.create(core)
        _ = try await store.reopen(
            jobID: core.jobID,
            expecting: identicalCore,
            observedSource: core.source
        )

        for changed in changedInputs {
            let changedIdentity = try R13ReleaseIdentity(changed.input)
            let changedCore = try restartCore(
                input: changed.input,
                identity: changedIdentity,
                jobID: core.jobID
            )

            XCTAssertNotEqual(
                changedIdentity.identitySHA256,
                identity.identitySHA256,
                changed.label
            )
            XCTAssertNotEqual(changedCore, core, changed.label)
            XCTAssertEqual(changedCore.source, core.source, changed.label)
            XCTAssertEqual(changedCore.output, core.output, changed.label)
            XCTAssertEqual(
                changedCore.processing.backendIdentity,
                core.processing.backendIdentity,
                changed.label
            )
            do {
                _ = try await store.reopen(
                    jobID: core.jobID,
                    expecting: changedCore,
                    observedSource: core.source
                )
                XCTFail(
                    "Identity drift reopened cached frames: \(changed.label)"
                )
            } catch {
                XCTAssertEqual(
                    error as? R13RestartJobError,
                    .immutableCoreMismatch,
                    changed.label
                )
            }
        }
    }

    func testRestartCoreRejectsCompositeFrameworkRuntimeDrift()
        async throws {
        let input = try makeInput()
        let identity = try R13ReleaseIdentity(input)
        let core = try restartCore(
            input: input,
            identity: identity,
            jobID: "r13-composite-identity-drift"
        )
        let releaseComponent = try R13RestartProcessingIdentity
            .releaseIdentityComponent(
                sha256: identity.identitySHA256
            )
        XCTAssertEqual(
            core.processing.routeIdentity,
            "scale_2x:"
                + "\(identity.configurationIdentity):"
                + "\(releaseComponent):"
                + "\(identity.processingConfigurationIdentity):"
                + "progressive:not_required"
        )

        let changedInputs = [
            (
                label: "composite_version",
                input: try replacingReleaseInputs(
                    input,
                    framework: R13ReleaseFrameworkIdentity(
                        frameworkIdentifier:
                            input.framework.frameworkIdentifier,
                        version: "15.4.1",
                        buildIdentity: input.framework.buildIdentity
                    ),
                    runtime: R13ReleaseRuntimeIdentity(
                        runtimeIdentifier:
                            input.runtime.runtimeIdentifier,
                        version: "15.4.1",
                        buildIdentity: input.runtime.buildIdentity,
                        architecture: input.runtime.architecture
                    )
                )
            ),
            (
                label: "composite_build",
                input: try replacingReleaseInputs(
                    input,
                    framework: R13ReleaseFrameworkIdentity(
                        frameworkIdentifier:
                            input.framework.frameworkIdentifier,
                        version: input.framework.version,
                        buildIdentity: "24F75"
                    ),
                    runtime: R13ReleaseRuntimeIdentity(
                        runtimeIdentifier:
                            input.runtime.runtimeIdentifier,
                        version: input.runtime.version,
                        buildIdentity: "24F75",
                        architecture: input.runtime.architecture
                    )
                )
            )
        ]

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = R13RestartJobStore(jobsRootURL: root)
        _ = try await store.create(core)

        for changed in changedInputs {
            let changedIdentity = try R13ReleaseIdentity(changed.input)
            let changedCore = try restartCore(
                input: changed.input,
                identity: changedIdentity,
                jobID: core.jobID
            )

            XCTAssertNotEqual(
                changedIdentity.identitySHA256,
                identity.identitySHA256,
                changed.label
            )
            XCTAssertNotEqual(changedCore, core, changed.label)
            do {
                _ = try await store.reopen(
                    jobID: core.jobID,
                    expecting: changedCore,
                    observedSource: core.source
                )
                XCTFail(
                    "Composite identity drift reopened cached frames: "
                        + changed.label
                )
            } catch {
                XCTAssertEqual(
                    error as? R13RestartJobError,
                    .immutableCoreMismatch,
                    changed.label
                )
            }
        }
    }

    func testRecoveryRejectsLegacyAndMalformedReleaseIdentityBindings()
        async throws {
        let input = try makeInput()
        let identity = try R13ReleaseIdentity(input)
        let jobID = "r13-release-identity-recovery"
        let job = try restartJob(input: input, jobID: jobID)
        let core = try restartCore(
            input: input,
            identity: identity,
            jobID: jobID
        )
        let descriptor = try R13RecoveryDescriptor(job: job)
        let releaseComponent = try R13RestartProcessingIdentity
            .releaseIdentityComponent(
                sha256: identity.identitySHA256
            )
        let boundMarker = ":\(releaseComponent):"
        let legacyRouteIdentity = core.processing.routeIdentity
            .replacingOccurrences(
                of: boundMarker,
                with: ":"
            )

        XCTAssertNotEqual(
            legacyRouteIdentity,
            core.processing.routeIdentity
        )
        XCTAssertNoThrow(
            try descriptor.validate(
                against: R13ValidatedRecoverableJob(
                    cachedFrameCount: 0,
                    processing: core.processing,
                    output: core.output
                )
            )
        )

        let malformedRouteIdentities = [
            legacyRouteIdentity,
            core.processing.routeIdentity.replacingOccurrences(
                of: releaseComponent,
                with: "release-" + String(repeating: "a", count: 63)
            ),
            core.processing.routeIdentity.replacingOccurrences(
                of: releaseComponent,
                with: "release-" + String(repeating: "A", count: 64)
            ),
            core.processing.routeIdentity.replacingOccurrences(
                of: boundMarker,
                with: ":\(releaseComponent):\(releaseComponent):"
            )
        ]
        for routeIdentity in malformedRouteIdentities {
            let malformedCore = try replacingRouteIdentity(
                core,
                with: routeIdentity
            )
            XCTAssertThrowsError(
                try descriptor.validate(
                    against: R13ValidatedRecoverableJob(
                        cachedFrameCount: 0,
                        processing: malformedCore.processing,
                        output: malformedCore.output
                    )
                )
            ) { error in
                XCTAssertEqual(
                    error as? R13RestartJobError,
                    .immutableCoreMismatch
                )
            }
        }

        let legacyCore = try replacingRouteIdentity(
            core,
            with: legacyRouteIdentity
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = R13RestartJobStore(jobsRootURL: root)
        _ = try await store.create(legacyCore)
        do {
            _ = try await store.reopen(
                jobID: jobID,
                expecting: core,
                observedSource: core.source
            )
            XCTFail("A legacy core without release identity was reopened.")
        } catch {
            XCTAssertEqual(
                error as? R13RestartJobError,
                .immutableCoreMismatch
            )
        }
    }

    func testChangingBoundBytesOrPolicyChangesTheIdentityHash() throws {
        let baseline = try makeIdentity()
        let changedBytes = try makeIdentity(sourceByteCount: 9_876_544)
        let changedPolicy = try makeIdentity(policySHA256: hash("9"))

        XCTAssertNotEqual(baseline.identitySHA256, changedBytes.identitySHA256)
        XCTAssertNotEqual(baseline.identitySHA256, changedPolicy.identitySHA256)
        XCTAssertNotEqual(changedBytes.identitySHA256, changedPolicy.identitySHA256)
    }

    func testInvalidIdentityOutputModelAndFallbackFailClosed() throws {
        XCTAssertThrowsError(
            try R13ReleaseSourceBinding(
                sha256: String(repeating: "A", count: 64),
                byteCount: 1
            )
        ) { error in
            XCTAssertEqual(
                error as? R13ReleaseIdentityError,
                .invalidSHA256(field: "source_sha256")
            )
        }
        XCTAssertThrowsError(
            try R13ReleaseSourceBinding(sha256: hash("1"), byteCount: 0)
        ) { error in
            XCTAssertEqual(
                error as? R13ReleaseIdentityError,
                .invalidByteCount(field: "source_byte_count")
            )
        }
        XCTAssertThrowsError(
            try application(bundleIdentifier: "/Users/operator/Mirmir")
        ) { error in
            XCTAssertEqual(
                error as? R13ReleaseIdentityError,
                .invalidIdentity(field: "app_bundle_identifier")
            )
        }

        let input = try makeInput()
        let outputMismatchInput = R13ReleaseIdentityInput(
            source: input.source,
            modeBinding: input.modeBinding,
            output: try R13ReleaseOutputBinding(
                resolution: .p1080,
                codec: .hevc,
                preserveAudio: true
            ),
            scalePlan: input.scalePlan,
            routeIdentity: input.routeIdentity,
            application: input.application,
            framework: input.framework,
            runtime: input.runtime,
            policyResources: input.policyResources,
            fallbackHistory: []
        )
        XCTAssertThrowsError(
            try R13ReleaseIdentity(outputMismatchInput)
        ) { error in
            XCTAssertEqual(
                error as? R13ReleaseIdentityError,
                .outputRouteMismatch
            )
        }

        let boundModelRoute = try AppleUpscaleRouteIdentity(
            backend: AppleUpscaleBackendIdentity(
                backendID: input.modeBinding.backendID,
                backendRevision:
                    input.modeBinding.backendRevision,
                modelAssetsIdentity: .bound([
                    AppleUpscaleArtifactIdentity(
                        identifier: "unexpected.model",
                        sha256: hash("8")
                    )
                ])
            ),
            configurationIdentity: input.routeIdentity.configurationIdentity,
            policyIdentity: R03A11ProductAdmission.policyIdentity,
            materialDecisionIdentity:
                R03A11ProductAdmission.materialDecisionIdentity
        )
        XCTAssertThrowsError(
            try R13ReleaseIdentity(replacingRoute(input, with: boundModelRoute))
        ) { error in
            XCTAssertEqual(
                error as? R13ReleaseIdentityError,
                .modelAssetsMustBeNotRequired
            )
        }

        let failedRoute = try R13ReleaseIdentity.makeA11Route(for: .scale3Over2)
        let fallback = try AppleUpscaleFallbackLink(
            failedRoute: failedRoute,
            selectedRoute: input.routeIdentity,
            reasonCode: .backendUnavailable,
            selectedFallbackOrdinal: 0
        )
        XCTAssertThrowsError(
            try R13ReleaseIdentity(replacingFallback(input, with: [fallback]))
        ) { error in
            XCTAssertEqual(
                error as? R13ReleaseIdentityError,
                .fallbackHistoryMustBeEmpty
            )
        }
    }

    func testMetadataRequiresTheExactControlledKeyAndValueSet() throws {
        let identity = try makeIdentity()

        var missing = identity.timedMetadata
        missing.removeValue(forKey: "com.mirmir.release.policy-sha256")
        XCTAssertThrowsError(try identity.validateTimedMetadata(missing)) { error in
            XCTAssertEqual(
                error as? R13ReleaseIdentityError,
                .metadataKeysDiffer
            )
        }

        var additional = identity.timedMetadata
        additional["com.mirmir.release.uncontrolled"] = "value"
        XCTAssertThrowsError(
            try identity.validateTimedMetadata(additional)
        ) { error in
            XCTAssertEqual(
                error as? R13ReleaseIdentityError,
                .metadataKeysDiffer
            )
        }

        var changed = identity.timedMetadata
        changed["com.mirmir.release.backend-id"] = "r03.vimage.lanczos-3"
        XCTAssertThrowsError(try identity.validateTimedMetadata(changed)) { error in
            XCTAssertEqual(
                error as? R13ReleaseIdentityError,
                .metadataValueDiffers(
                    key: "com.mirmir.release.backend-id"
                )
            )
        }
    }
}

private extension R13ReleaseIdentityTests {
    func makeIdentity(
        sourceByteCount: UInt64 = 9_876_543,
        policySHA256: String? = nil,
        sourceScanStructure:
            MediaVideoScanStructure = .progressive
    ) throws -> R13ReleaseIdentity {
        try R13ReleaseIdentity(
            makeInput(
                sourceByteCount: sourceByteCount,
                policySHA256: policySHA256,
                sourceScanStructure: sourceScanStructure
            )
        )
    }

    func makeExactNativeIdentity(
        preference: UpscaleEnginePreference,
        mode: UpscaleMode
    ) throws -> R13ReleaseIdentity {
        let base = try makeInput()
        let scaleRoute = R03ScaleRoute.scale2x
        let modeBinding = R13ReleaseModePolicy.binding(
            for: mode,
            enginePreference: preference
        )
        return try R13ReleaseIdentity(
            R13ReleaseIdentityInput(
                source: base.source,
                modeBinding: modeBinding,
                output: base.output,
                scalePlan: .productQualified(scaleRoute),
                routeIdentity:
                    try R13ReleaseIdentity.makeProductRoute(
                        for: scaleRoute,
                        modeBinding: modeBinding
                    ),
                application: base.application,
                framework: try R13ReleaseFrameworkIdentity(
                    frameworkIdentifier:
                        modeBinding.frameworkIdentity,
                    version: "1",
                    buildIdentity: "1"
                ),
                runtime: base.runtime,
                policyResources: base.policyResources,
                fallbackHistory: [],
                processingConfiguration:
                    UpscaleProcessingConfiguration(
                        enginePreference: preference,
                        strategyPreference: .direct
                    )
            )
        )
    }

    private func assertRoutingMetadataError(
        identity: R13ReleaseIdentity,
        metadata: [String: String],
        field: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try identity.validateTimedMetadata(metadata),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? R13ReleaseIdentityError,
                .routingDecisionMetadataInvalid(field: field),
                file: file,
                line: line
            )
        }
    }

    func makeInput(
        sourceByteCount: UInt64 = 9_876_543,
        policySHA256: String? = nil,
        sourceScanStructure:
            MediaVideoScanStructure = .progressive
    ) throws -> R13ReleaseIdentityInput {
        let scaleRoute = R03ScaleRoute.scale2x
        return R13ReleaseIdentityInput(
            source: try R13ReleaseSourceBinding(
                sha256: hash("1"),
                byteCount: sourceByteCount
            ),
            modeBinding: R13ReleaseModePolicy.binding(for: .quality),
            output: try R13ReleaseOutputBinding(
                resolution: .p2160,
                codec: .hevc,
                preserveAudio: true
            ),
            scalePlan: .productQualified(scaleRoute),
            routeIdentity: try R13ReleaseIdentity.makeProductRoute(
                for: scaleRoute,
                modeBinding: R13ReleaseModePolicy.binding(
                    for: .quality
                )
            ),
            application: try application(),
            framework: try R13ReleaseFrameworkIdentity(
                frameworkIdentifier: "AppleNativeMultiEngine",
                version: "15.4",
                buildIdentity: "24F74"
            ),
            runtime: try R13ReleaseRuntimeIdentity(
                runtimeIdentifier: "macOS",
                version: "15.4",
                buildIdentity: "24F74",
                architecture: "arm64"
            ),
            policyResources: try R13ReleasePolicyResourceBinding(
                policySHA256: policySHA256 ?? hash("2"),
                resourceManifestSHA256: hash("3")
            ),
            fallbackHistory: [],
            sourceScanStructure: sourceScanStructure,
            deinterlacingAlgorithmIdentity:
                sourceScanStructure.requiresDeinterlacing
                ? R13FormatPreservingDeinterlacer
                    .algorithmIdentity
                : "not_required"
        )
    }

    func makeDirectInput() throws -> R13ReleaseIdentityInput {
        let base = try makeInput()
        let scaleRoute = R03ScaleRoute.scale2x
        let modeBinding = R13ReleaseModePolicy.binding(
            for: .deterministic
        )
        return R13ReleaseIdentityInput(
            source: base.source,
            modeBinding: modeBinding,
            output: base.output,
            scalePlan: .productQualified(scaleRoute),
            routeIdentity: try R13ReleaseIdentity.makeProductRoute(
                for: scaleRoute,
                modeBinding: modeBinding
            ),
            application: base.application,
            framework: try R13ReleaseFrameworkIdentity(
                frameworkIdentifier: "MetalPerformanceShaders",
                version: "1.0",
                buildIdentity: "1"
            ),
            runtime: base.runtime,
            policyResources: base.policyResources,
            fallbackHistory: base.fallbackHistory,
            processingConfiguration: base.processingConfiguration,
            sourceScanStructure: base.sourceScanStructure,
            deinterlacingAlgorithmIdentity:
                base.deinterlacingAlgorithmIdentity
        )
    }

    func application(
        bundleIdentifier: String = "com.mirmir.app"
    ) throws -> R13ReleaseApplicationIdentity {
        try R13ReleaseApplicationIdentity(
            bundleIdentifier: bundleIdentifier,
            semanticVersion: "1.0.0",
            buildVersion: "1",
            executableSHA256: hash("4"),
            executableByteCount: 1_234_567
        )
    }

    func releaseDecisionRoute(
        backendID: String,
        configurationIdentity: String,
        modelAssetsIdentity:
            AppleUpscaleModelAssetsIdentity = .notRequired
    ) throws -> AppleUpscaleRouteIdentity {
        try AppleUpscaleRouteIdentity(
            backend: AppleUpscaleBackendIdentity(
                backendID: backendID,
                backendRevision:
                    "r13.release.decision.test.v1",
                modelAssetsIdentity: modelAssetsIdentity
            ),
            configurationIdentity: configurationIdentity,
            policyIdentity:
                "r13.release.decision.test.policy",
            materialDecisionIdentity:
                "r13.release.decision.test.material"
        )
    }

    func makeAdaptiveInput(
        plan: R13AdaptiveScalePlan,
        policyResources: R13ReleasePolicyResourceBinding
    ) throws -> R13ReleaseIdentityInput {
        R13ReleaseIdentityInput(
            source: try R13ReleaseSourceBinding(
                sha256: hash("1"),
                byteCount: 9_876_543
            ),
            modeBinding: R13ReleaseModePolicy.binding(for: .quality),
            output: try R13ReleaseOutputBinding(
                resolution: plan.targetResolution,
                codec: .hevc,
                preserveAudio: true
            ),
            scalePlan: .adaptiveMPSLanczos(plan),
            routeIdentity: try R13ReleaseIdentity.makeAdaptiveRoute(
                for: plan,
                modeBinding: R13ReleaseModePolicy.binding(
                    for: .quality
                )
            ),
            application: try application(),
            framework: try R13ReleaseFrameworkIdentity(
                frameworkIdentifier: "AppleNativeMultiEngine",
                version: "15.4",
                buildIdentity: "24F74"
            ),
            runtime: try R13ReleaseRuntimeIdentity(
                runtimeIdentifier: "macOS",
                version: "15.4",
                buildIdentity: "24F74",
                architecture: "arm64"
            ),
            policyResources: policyResources,
            fallbackHistory: []
        )
    }

    func replacingRoute(
        _ input: R13ReleaseIdentityInput,
        with route: AppleUpscaleRouteIdentity
    ) -> R13ReleaseIdentityInput {
        R13ReleaseIdentityInput(
            source: input.source,
            modeBinding: input.modeBinding,
            output: input.output,
            scalePlan: input.scalePlan,
            routeIdentity: route,
            application: input.application,
            framework: input.framework,
            runtime: input.runtime,
            policyResources: input.policyResources,
            fallbackHistory: input.fallbackHistory
        )
    }

    func replacingFallback(
        _ input: R13ReleaseIdentityInput,
        with fallback: [AppleUpscaleFallbackLink]
    ) -> R13ReleaseIdentityInput {
        R13ReleaseIdentityInput(
            source: input.source,
            modeBinding: input.modeBinding,
            output: input.output,
            scalePlan: input.scalePlan,
            routeIdentity: input.routeIdentity,
            application: input.application,
            framework: input.framework,
            runtime: input.runtime,
            policyResources: input.policyResources,
            fallbackHistory: fallback
        )
    }

    func replacingReleaseInputs(
        _ input: R13ReleaseIdentityInput,
        application: R13ReleaseApplicationIdentity? = nil,
        framework: R13ReleaseFrameworkIdentity? = nil,
        runtime: R13ReleaseRuntimeIdentity? = nil,
        policyResources: R13ReleasePolicyResourceBinding? = nil
    ) -> R13ReleaseIdentityInput {
        R13ReleaseIdentityInput(
            source: input.source,
            modeBinding: input.modeBinding,
            output: input.output,
            scalePlan: input.scalePlan,
            routeIdentity: input.routeIdentity,
            application: application ?? input.application,
            framework: framework ?? input.framework,
            runtime: runtime ?? input.runtime,
            policyResources: policyResources ?? input.policyResources,
            fallbackHistory: input.fallbackHistory,
            processingConfiguration: input.processingConfiguration,
            sourceScanStructure: input.sourceScanStructure,
            deinterlacingAlgorithmIdentity:
                input.deinterlacingAlgorithmIdentity
        )
    }

    func directRestartDriftInputs(
        _ input: R13ReleaseIdentityInput
    ) throws -> [(label: String, input: R13ReleaseIdentityInput)] {
        [
            (
                "application_executable",
                replacingReleaseInputs(
                    input,
                    application: try R13ReleaseApplicationIdentity(
                        bundleIdentifier:
                            input.application.bundleIdentifier,
                        semanticVersion:
                            input.application.semanticVersion,
                        buildVersion: input.application.buildVersion,
                        executableSHA256: hash("5"),
                        executableByteCount:
                            input.application.executableByteCount
                    )
                )
            ),
            (
                "framework_version",
                replacingReleaseInputs(
                    input,
                    framework: try R13ReleaseFrameworkIdentity(
                        frameworkIdentifier:
                            input.framework.frameworkIdentifier,
                        version: "1.1",
                        buildIdentity: input.framework.buildIdentity
                    )
                )
            ),
            (
                "framework_build",
                replacingReleaseInputs(
                    input,
                    framework: try R13ReleaseFrameworkIdentity(
                        frameworkIdentifier:
                            input.framework.frameworkIdentifier,
                        version: input.framework.version,
                        buildIdentity: "2"
                    )
                )
            ),
            (
                "runtime_version",
                replacingReleaseInputs(
                    input,
                    runtime: try R13ReleaseRuntimeIdentity(
                        runtimeIdentifier:
                            input.runtime.runtimeIdentifier,
                        version: "15.4.1",
                        buildIdentity: input.runtime.buildIdentity,
                        architecture: input.runtime.architecture
                    )
                )
            ),
            (
                "runtime_build",
                replacingReleaseInputs(
                    input,
                    runtime: try R13ReleaseRuntimeIdentity(
                        runtimeIdentifier:
                            input.runtime.runtimeIdentifier,
                        version: input.runtime.version,
                        buildIdentity: "24F75",
                        architecture: input.runtime.architecture
                    )
                )
            ),
            (
                "policy_digest",
                replacingReleaseInputs(
                    input,
                    policyResources:
                        try R13ReleasePolicyResourceBinding(
                            policySHA256: hash("6"),
                            resourceManifestSHA256:
                                input.policyResources
                                    .resourceManifestSHA256
                        )
                )
            )
        ]
    }

    func restartJob(
        input: R13ReleaseIdentityInput,
        jobID: String
    ) throws -> UpscaleJob {
        guard let codec = OutputCodec(rawValue: input.output.codec) else {
            throw R13RestartJobError.invalidIdentity(
                field: "output_codec"
            )
        }
        return UpscaleJob(
            identifier: jobID,
            inputURL: URL(
                fileURLWithPath: "/tmp/\(jobID)-input.mov"
            ),
            outputURL: URL(
                fileURLWithPath: "/tmp/\(jobID)-output.mp4"
            ),
            targetResolution: VideoResolution(
                width: input.output.width,
                height: input.output.height
            ),
            codec: codec,
            preserveAudio: input.output.preserveAudio,
            mode: input.modeBinding.requestedMode,
            processingConfiguration: input.processingConfiguration
        )
    }

    func restartCore(
        input: R13ReleaseIdentityInput,
        identity: R13ReleaseIdentity,
        jobID: String
    ) throws -> R13RestartJobCore {
        let job = try restartJob(input: input, jobID: jobID)
        let source = try R13RestartSourceIdentity(
            sha256: input.source.sha256,
            byteCount: input.source.byteCount
        )
        return try R13ReleaseHardeningRuntime.makeRestartCore(
            job: job,
            scalePlan: input.scalePlan,
            identity: identity,
            modeBinding: input.modeBinding,
            source: source,
            totalFrameCount: 17
        )
    }

    func replacingRouteIdentity(
        _ core: R13RestartJobCore,
        with routeIdentity: String
    ) throws -> R13RestartJobCore {
        let processing = try R13RestartProcessingIdentity(
            requestedMode: core.processing.requestedMode,
            effectiveMode: core.processing.effectiveMode,
            routeIdentity: routeIdentity,
            backendIdentity: core.processing.backendIdentity,
            backendRevision: core.processing.backendRevision
        )
        return try R13RestartJobCore(
            jobID: core.jobID,
            source: core.source,
            processing: processing,
            output: core.output,
            totalFrameCount: core.totalFrameCount
        )
    }

    func hash(_ character: Character) -> String {
        String(repeating: String(character), count: 64)
    }
}
