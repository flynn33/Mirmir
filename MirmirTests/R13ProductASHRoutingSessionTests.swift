import XCTest
@testable import Mirmir

final class R13ProductASHRoutingSessionTests: XCTestCase {
    func testProcessedSelectionPublishesExactDecisionSummary()
        async throws {
        let primary = try makeCandidate(
            backendID: "test.router.primary",
            rank: 65_536,
            script: [.processed]
        )
        let fallback = try makeCandidate(
            backendID: "test.router.fallback",
            rank: 0,
            script: [.processed]
        )
        let router = try makeRouter(candidates: [
            primary.candidate,
            fallback.candidate
        ])
        let fixture = try makeFrame(sequenceNumber: 4, seed: 31)

        let outcome = await router.submit(fixture.frame)
        let processed = try requireProcessed(outcome)
        defer { processed.resourceLifetimeToken.release() }

        XCTAssertEqual(processed.processingIdentity.route, primary.identity)
        XCTAssertTrue(processed.processingIdentity.fallbackHistory.isEmpty)
        XCTAssertEqual(fixture.probe.releaseCount(for: fixture.tokenIdentity), 1)
        let decision = await router.decisionSummary()
        XCTAssertEqual(
            decision,
            R13ProductASHDecisionSummary(
                events: [
                    R13ProductASHDecisionEvent(
                        sequenceNumber: 4,
                        selectedRouteIdentity:
                            primary.identity,
                        reason: .initialSelection,
                        failedBackendIDs: []
                    )
                ]
            )
        )
        XCTAssertEqual(
            decision.selectedBackendIDs,
            [primary.identity.backend.backendID]
        )
        XCTAssertEqual(decision.fallbackCount, 0)
        let outputMetadata = try decision.outputMetadata()
        XCTAssertEqual(
            R13ProductASHDecisionMetadata.pendingValues[
                R13ProductASHDecisionMetadata.statusKey
            ],
            "pending"
        )
        XCTAssertEqual(outputMetadata.decisionCount, 1)
        XCTAssertEqual(outputMetadata.transitionCount, 0)
        XCTAssertEqual(outputMetadata.fallbackCount, 0)
        XCTAssertEqual(
            outputMetadata.selectedBackendIDs,
            [primary.identity.backend.backendID]
        )
        XCTAssertEqual(
            outputMetadata.selectedModelStatuses,
            [.notRequired]
        )
        XCTAssertEqual(
            outputMetadata.modelStatus,
            R13ProductASHSelectedModelStatus
                .notRequired.rawValue
        )
        XCTAssertEqual(
            outputMetadata.values[
                R13ProductASHDecisionMetadata
                    .selectedModelStatusesKey
            ],
            R13ProductASHSelectedModelStatus
                .notRequired.rawValue
        )
        XCTAssertEqual(
            outputMetadata.journalSHA256,
            "1d7b681a7083e857d9f34db5cd823589"
                + "31bdbddf97ecc0416b0ac3faefee45aa"
        )
        XCTAssertEqual(
            outputMetadata.values[
                R13ProductASHDecisionMetadata.statusKey
            ],
            "complete"
        )
        XCTAssertEqual(
            outputMetadata,
            try decision.outputMetadata()
        )
        let primarySnapshot = await primary.session.snapshot()
        let fallbackSnapshot = await fallback.session.snapshot()
        XCTAssertEqual(
            primarySnapshot,
            R13ProductASHTestSessionSnapshot(
                submittedSequenceNumbers: [4],
                resetReasons: [.discontinuity],
                finishCount: 0,
                cancelCount: 0
            )
        )
        XCTAssertTrue(
            fallbackSnapshot.submittedSequenceNumbers.isEmpty
        )
        await router.cancel()
    }

    func testModelStatusMetadataUsesOnlyActuallySelectedCandidate()
        async throws {
        let selected = try makeCandidate(
            backendID: "test.router.model-free-selected",
            rank: 65_536,
            script: [.processed]
        )
        let unusedAppleManaged = try makeCandidate(
            backendID: "test.router.apple-managed-unused",
            rank: 0,
            modelAssetsIdentity:
                .appleConfigurationManaged(
                    configurationIdentity:
                        "test.router.apple-managed-unused.configuration.v1",
                    readiness: .ready
                ),
            script: [.processed]
        )
        let router = try makeRouter(candidates: [
            unusedAppleManaged.candidate,
            selected.candidate
        ])

        try await submitAndRelease(
            sequenceNumber: 0,
            seed: 37,
            to: router
        )

        let metadata = try await router.decisionSummary()
            .outputMetadata()
        XCTAssertEqual(
            metadata.selectedBackendIDs,
            [selected.identity.backend.backendID]
        )
        XCTAssertEqual(
            metadata.selectedModelStatuses,
            [.notRequired]
        )
        XCTAssertEqual(
            metadata.modelStatus,
            R13ProductASHSelectedModelStatus
                .notRequired.rawValue
        )
        await router.cancel()
    }

    func testActuallySelectedAppleManagedRouteAndFallbackReportMixedStatus()
        async throws {
        let appleManagedBackendID =
            "test.router.apple-managed-selected"
        let appleManaged = try makeCandidate(
            backendID: appleManagedBackendID,
            rank: 65_536,
            modelAssetsIdentity:
                .appleConfigurationManaged(
                    configurationIdentity:
                        "\(appleManagedBackendID).configuration.v1",
                    readiness: .ready
                ),
            script: [.processed, .unavailable]
        )
        let fallback = try makeCandidate(
            backendID: "test.router.model-free-fallback",
            rank: 0,
            script: [.processed]
        )
        let router = try makeRouter(candidates: [
            fallback.candidate,
            appleManaged.candidate
        ])

        try await submitAndRelease(
            sequenceNumber: 0,
            seed: 41,
            to: router
        )
        try await submitAndRelease(
            sequenceNumber: 1,
            seed: 41,
            to: router
        )

        let summary = await router.decisionSummary()
        XCTAssertEqual(
            summary.events.map(\.selectedRouteIdentity),
            [appleManaged.identity, fallback.identity]
        )
        let metadata = try summary.outputMetadata()
        XCTAssertEqual(
            metadata.selectedModelStatuses,
            [
                .appleConfigurationManagedReady,
                .notRequired
            ]
        )
        XCTAssertEqual(metadata.modelStatus, "mixed")
        XCTAssertEqual(
            metadata.values[
                R13ProductASHDecisionMetadata
                    .selectedModelStatusesKey
            ],
            "apple_configuration_managed_ready,not_required"
        )
        XCTAssertEqual(
            metadata.values[
                R13ProductASHDecisionMetadata.modelStatusKey
            ],
            "mixed"
        )
        await router.cancel()
    }

    func testDecisionJournalHashBindsSelectedRouteModelIdentity()
        throws {
        let modelFreeRoute = try modelIdentityRoute(
            modelAssetsIdentity: .notRequired
        )
        let appleManagedRoute = try modelIdentityRoute(
            modelAssetsIdentity:
                .appleConfigurationManaged(
                    configurationIdentity:
                        "test.router.journal.configuration.v1",
                    readiness: .ready
                )
        )
        let modelFreeMetadata =
            try R13ProductASHDecisionSummary(
                events: [
                    R13ProductASHDecisionEvent(
                        sequenceNumber: 0,
                        selectedRouteIdentity:
                            modelFreeRoute,
                        reason: .initialSelection,
                        failedBackendIDs: []
                    )
                ]
            ).outputMetadata()
        let appleManagedMetadata =
            try R13ProductASHDecisionSummary(
                events: [
                    R13ProductASHDecisionEvent(
                        sequenceNumber: 0,
                        selectedRouteIdentity:
                            appleManagedRoute,
                        reason: .initialSelection,
                        failedBackendIDs: []
                    )
                ]
            ).outputMetadata()

        XCTAssertNotEqual(
            modelFreeMetadata.journalSHA256,
            appleManagedMetadata.journalSHA256
        )
        XCTAssertEqual(
            modelFreeMetadata.selectedModelStatuses,
            [.notRequired]
        )
        XCTAssertEqual(
            appleManagedMetadata.selectedModelStatuses,
            [.appleConfigurationManagedReady]
        )
    }

    func testUnavailableAndFailedCandidatesProduceTypedFallbackChain()
        async throws {
        let unavailable = try makeCandidate(
            backendID: "test.router.unavailable",
            rank: 65_536,
            script: [.unavailable]
        )
        let failed = try makeCandidate(
            backendID: "test.router.failed",
            rank: 32_768,
            script: [.failed]
        )
        let selected = try makeCandidate(
            backendID: "test.router.selected",
            rank: 0,
            script: [.processed]
        )
        let router = try makeRouter(candidates: [
            selected.candidate,
            failed.candidate,
            unavailable.candidate
        ])
        let fixture = try makeFrame(sequenceNumber: 8, seed: 47)

        let outcome = await router.submit(fixture.frame)
        let processed = try requireProcessed(outcome)
        defer { processed.resourceLifetimeToken.release() }

        XCTAssertEqual(processed.processingIdentity.route, selected.identity)
        XCTAssertEqual(
            processed.processingIdentity.fallbackHistory,
            [
                try AppleUpscaleFallbackLink(
                    failedRoute: unavailable.identity,
                    selectedRoute: failed.identity,
                    reasonCode: .backendUnavailable,
                    selectedFallbackOrdinal: 0
                ),
                try AppleUpscaleFallbackLink(
                    failedRoute: failed.identity,
                    selectedRoute: selected.identity,
                    reasonCode: .backendFailed,
                    selectedFallbackOrdinal: 1
                )
            ]
        )
        let decision = await router.decisionSummary()
        XCTAssertEqual(decision.fallbackCount, 2)
        XCTAssertEqual(
            decision.events,
            [
                R13ProductASHDecisionEvent(
                    sequenceNumber: 8,
                    selectedRouteIdentity:
                        selected.identity,
                    reason: .fatalBackendFailover,
                    failedBackendIDs: [
                        unavailable.identity.backend.backendID,
                        failed.identity.backend.backendID
                    ]
                )
            ]
        )
        let unavailableSnapshot =
            await unavailable.session.snapshot()
        let failedSnapshot = await failed.session.snapshot()
        let selectedSnapshot = await selected.session.snapshot()
        XCTAssertEqual(
            unavailableSnapshot.submittedSequenceNumbers,
            [8]
        )
        XCTAssertEqual(
            failedSnapshot.submittedSequenceNumbers,
            [8]
        )
        XCTAssertEqual(
            selectedSnapshot.submittedSequenceNumbers,
            [8]
        )
        await router.cancel()
    }

    func testResetClearsSelectionHistoryAndRestartsInitialSelection()
        async throws {
        let primary = try makeCandidate(
            backendID: "test.router.reset.primary",
            rank: 65_536,
            script: [.processed]
        )
        let secondary = try makeCandidate(
            backendID: "test.router.reset.secondary",
            rank: 0,
            script: [.processed]
        )
        let router = try makeRouter(candidates: [
            primary.candidate,
            secondary.candidate
        ])

        try await submitAndRelease(
            sequenceNumber: 0,
            seed: 71,
            to: router
        )
        try await submitAndRelease(
            sequenceNumber: 1,
            seed: 71,
            to: router
        )
        await router.reset(reason: .callerRequested)
        try await submitAndRelease(
            sequenceNumber: 2,
            seed: 71,
            to: router
        )

        let decision = await router.decisionSummary()
        XCTAssertEqual(
            decision.events.map(\.reason),
            [
                .initialSelection,
                .scoreWinnerSelected,
                .initialSelection
            ]
        )
        let primarySnapshot = await primary.session.snapshot()
        let secondarySnapshot = await secondary.session.snapshot()
        XCTAssertEqual(
            primarySnapshot.resetReasons,
            [
                .discontinuity,
                .callerRequested,
                .discontinuity
            ]
        )
        XCTAssertEqual(
            secondarySnapshot.resetReasons,
            [.callerRequested]
        )
        await router.cancel()
    }

    func testFinishIsIdempotentAndClosesAdmission() async throws {
        let first = try makeCandidate(
            backendID: "test.router.finish.first",
            rank: 65_536,
            script: [.processed]
        )
        let second = try makeCandidate(
            backendID: "test.router.finish.second",
            rank: 0,
            script: [.processed]
        )
        let router = try makeRouter(candidates: [
            first.candidate,
            second.candidate
        ])

        let firstSummary = await router.finish()
        let secondSummary = await router.finish()
        await router.cancel()
        let firstSnapshot = await first.session.snapshot()
        let secondSnapshot = await second.session.snapshot()

        XCTAssertEqual(firstSummary, secondSummary)
        XCTAssertEqual(firstSummary.terminalizationCount, 1)
        XCTAssertEqual(firstSnapshot.finishCount, 1)
        XCTAssertEqual(secondSnapshot.finishCount, 1)
        XCTAssertEqual(firstSnapshot.cancelCount, 0)
        XCTAssertEqual(secondSnapshot.cancelCount, 0)

        let lateFrame = try makeFrame(sequenceNumber: 11, seed: 83)
        let outcome = await router.submit(lateFrame.frame)
        guard case .rejected(let rejection) = outcome else {
            return XCTFail("Finished router accepted a late frame.")
        }
        XCTAssertEqual(rejection.reason, "admission_closed")
        XCTAssertEqual(
            lateFrame.probe.releaseCount(for: lateFrame.tokenIdentity),
            1
        )
    }

    func testCancelIsIdempotentAndFinishDoesNotReterminalize()
        async throws {
        let first = try makeCandidate(
            backendID: "test.router.cancel.first",
            rank: 65_536,
            script: [.processed]
        )
        let second = try makeCandidate(
            backendID: "test.router.cancel.second",
            rank: 0,
            script: [.processed]
        )
        let router = try makeRouter(candidates: [
            first.candidate,
            second.candidate
        ])

        await router.cancel()
        await router.cancel()
        let summary = await router.finish()
        let firstSnapshot = await first.session.snapshot()
        let secondSnapshot = await second.session.snapshot()

        XCTAssertEqual(summary.terminalizationCount, 1)
        XCTAssertEqual(firstSnapshot.cancelCount, 1)
        XCTAssertEqual(secondSnapshot.cancelCount, 1)
        XCTAssertEqual(firstSnapshot.finishCount, 0)
        XCTAssertEqual(secondSnapshot.finishCount, 0)
    }

    func testCachedPrefixReplayWarmsOnlyFinalCandidateThenContinuesLive()
        async throws {
        let selected = try makeCandidate(
            backendID: "test.router.resume.selected",
            rank: 65_536,
            script: [.processed, .processed]
        )
        let fallback = try makeCandidate(
            backendID: "test.router.resume.fallback",
            rank: 0,
            script: [.processed]
        )
        let router = try makeRouter(candidates: [
            selected.candidate,
            fallback.candidate
        ])
        let first = try makeFrame(sequenceNumber: 0, seed: 101)
        let second = try makeFrame(sequenceNumber: 1, seed: 102)
        let firstDecision = R13ProductASHDecisionEvent(
            sequenceNumber: 0,
            selectedRouteIdentity: selected.identity,
            reason: .initialSelection,
            failedBackendIDs: [],
            processingPressureQ16: 4_096
        )
        let secondDecision = R13ProductASHDecisionEvent(
            sequenceNumber: 1,
            selectedRouteIdentity: selected.identity,
            reason: .hysteresisHold,
            failedBackendIDs: [],
            processingPressureQ16: 12_288
        )

        try await router.replayCachedDecision(
            first.frame,
            decision: firstDecision,
            isFinalCachedPrefixFrame: false,
            requiresBackendWarmup: false
        )
        let selectedAfterFirstReplay =
            await selected.session.snapshot()
        XCTAssertTrue(
            selectedAfterFirstReplay
                .submittedSequenceNumbers.isEmpty
        )
        try await router.replayCachedDecision(
            second.frame,
            decision: secondDecision,
            isFinalCachedPrefixFrame: true,
            requiresBackendWarmup: true
        )

        let selectedAfterWarmup =
            await selected.session.snapshot()
        let fallbackAfterWarmup =
            await fallback.session.snapshot()
        XCTAssertEqual(
            selectedAfterWarmup
                .submittedSequenceNumbers,
            [1],
            "Resume may warm only the final cached prefix frame."
        )
        XCTAssertTrue(
            fallbackAfterWarmup
                .submittedSequenceNumbers.isEmpty
        )
        XCTAssertEqual(
            first.probe.releaseCount(for: first.tokenIdentity),
            1
        )
        XCTAssertEqual(
            second.probe.releaseCount(for: second.tokenIdentity),
            1
        )

        try await submitAndRelease(
            sequenceNumber: 2,
            seed: 103,
            to: router
        )

        let selectedAfterLiveFrame =
            await selected.session.snapshot()
        XCTAssertEqual(
            selectedAfterLiveFrame
                .submittedSequenceNumbers,
            [1, 2]
        )
        let summary = await router.decisionSummary()
        XCTAssertEqual(
            Array(summary.events.prefix(2)),
            [firstDecision, secondDecision]
        )
        XCTAssertEqual(summary.events.map(\.sequenceNumber), [0, 1, 2])
        XCTAssertNotEqual(
            summary.events[2].reason,
            .initialSelection,
            "Restored selection/dwell history must reach the live decision."
        )
        XCTAssertEqual(
            summary.resumeBoundaries,
            [
                R13ProductASHResumeBoundary(
                    sequenceNumber: 1,
                    kind: .oneFrameSelectedCandidateWarmup
                )
            ]
        )
        let metadata = try summary.outputMetadata()
        XCTAssertEqual(metadata.decisionCount, 3)
        XCTAssertEqual(metadata.resumeBoundaryCount, 1)
        await router.cancel()
    }

    func testFullCacheReplaySubmitsNoBackendFrames()
        async throws {
        let selected = try makeCandidate(
            backendID: "test.router.full-cache.selected",
            rank: 65_536,
            script: [.processed]
        )
        let fallback = try makeCandidate(
            backendID: "test.router.full-cache.fallback",
            rank: 0,
            script: [.processed]
        )
        let router = try makeRouter(candidates: [
            selected.candidate,
            fallback.candidate
        ])
        for sequenceNumber in 0...1 {
            let frame = try makeFrame(
                sequenceNumber: sequenceNumber,
                seed: 110 + sequenceNumber
            )
            try await router.replayCachedDecision(
                frame.frame,
                decision: R13ProductASHDecisionEvent(
                    sequenceNumber: sequenceNumber,
                    selectedRouteIdentity: selected.identity,
                    reason: sequenceNumber == 0
                        ? .initialSelection
                        : .hysteresisHold,
                    failedBackendIDs: [],
                    processingPressureQ16:
                        Int64(sequenceNumber * 1_024)
                ),
                isFinalCachedPrefixFrame:
                    sequenceNumber == 1,
                requiresBackendWarmup: false
            )
            XCTAssertEqual(
                frame.probe.releaseCount(
                    for: frame.tokenIdentity
                ),
                1
            )
        }

        let selectedSnapshot =
            await selected.session.snapshot()
        let fallbackSnapshot =
            await fallback.session.snapshot()
        XCTAssertTrue(
            selectedSnapshot
                .submittedSequenceNumbers.isEmpty
        )
        XCTAssertTrue(
            fallbackSnapshot
                .submittedSequenceNumbers.isEmpty
        )
        let summary = await router.decisionSummary()
        XCTAssertEqual(summary.events.map(\.sequenceNumber), [0, 1])
        XCTAssertEqual(
            summary.resumeBoundaries,
            [
                R13ProductASHResumeBoundary(
                    sequenceNumber: 1,
                    kind: .fullCacheNoBackendWarmup
                )
            ]
        )
        await router.cancel()
    }

    func testReplayRejectsUnknownRouteBeforeWarmupAndReleasesInput()
        async throws {
        let admitted = try makeCandidate(
            backendID: "test.router.replay.admitted",
            rank: 65_536,
            script: [.processed]
        )
        let unknown = try makeCandidate(
            backendID: "test.router.replay.unknown",
            rank: 0,
            script: [.processed]
        )
        let router = try makeRouter(
            candidates: [admitted.candidate]
        )
        let frame = try makeFrame(sequenceNumber: 0, seed: 120)

        do {
            try await router.replayCachedDecision(
                frame.frame,
                decision: R13ProductASHDecisionEvent(
                    sequenceNumber: 0,
                    selectedRouteIdentity: unknown.identity,
                    reason: .initialSelection,
                    failedBackendIDs: []
                ),
                isFinalCachedPrefixFrame: true,
                requiresBackendWarmup: true
            )
            XCTFail("An unadmitted persisted route cannot be replayed.")
        } catch {
            XCTAssertEqual(
                error as? R13ProductASHRoutingSessionError,
                .invalidReplayDecision(sequenceNumber: 0)
            )
        }
        XCTAssertEqual(
            frame.probe.releaseCount(for: frame.tokenIdentity),
            1
        )
        let admittedSnapshot =
            await admitted.session.snapshot()
        XCTAssertTrue(
            admittedSnapshot
                .submittedSequenceNumbers.isEmpty
        )
        await router.cancel()
    }

    func testDecisionJournalHashBindsPressureExclusionsAndResumeBoundary()
        throws {
        let route = try modelIdentityRoute(
            modelAssetsIdentity: .notRequired
        )
        let baseEvent = R13ProductASHDecisionEvent(
            sequenceNumber: 0,
            selectedRouteIdentity: route,
            reason: .initialSelection,
            failedBackendIDs: []
        )
        let base = try R13ProductASHDecisionSummary(
            events: [baseEvent]
        ).outputMetadata()
        let pressure = try R13ProductASHDecisionSummary(
            events: [
                R13ProductASHDecisionEvent(
                    sequenceNumber: 0,
                    selectedRouteIdentity: route,
                    reason: .initialSelection,
                    failedBackendIDs: [],
                    processingPressureQ16: 1
                )
            ]
        ).outputMetadata()
        let exclusion =
            R13ProductASHScalingCandidateExclusion(
                declaredKind: .deterministicMPSLanczos,
                expectedBackendID:
                    "test.router.excluded-candidate",
                phase: .scalerConstruction,
                failure:
                    R13ProductASHScalingCandidateFailureEvidence(
                        error: NSError(
                            domain: "test.router",
                            code: 42
                        )
                    )
            )
        let excluded = try R13ProductASHDecisionSummary(
            events: [baseEvent],
            candidateExclusions: [exclusion]
        ).outputMetadata()
        let resumed = try R13ProductASHDecisionSummary(
            events: [baseEvent],
            resumeBoundaries: [
                R13ProductASHResumeBoundary(
                    sequenceNumber: 0,
                    kind: .fullCacheNoBackendWarmup
                )
            ]
        ).outputMetadata()

        XCTAssertNotEqual(
            Set([
                base.journalSHA256,
                pressure.journalSHA256,
                excluded.journalSHA256,
                resumed.journalSHA256
            ]).count,
            1
        )
        XCTAssertEqual(
            Set([
                base.journalSHA256,
                pressure.journalSHA256,
                excluded.journalSHA256,
                resumed.journalSHA256
            ]).count,
            4
        )
        XCTAssertEqual(excluded.candidateExclusionCount, 1)
        XCTAssertEqual(resumed.resumeBoundaryCount, 1)
    }

    func testA11FactoryPropagatesOneConstructionFailureIntoFinalRoutingEvidence()
        async throws {
        let route = R03ScaleRoute.scale2x
        let modeBinding =
            R13ReleaseModePolicy.binding(for: .auto)
        let failedKind =
            R13ProductASHCandidateKind.videoToolboxQuality
        let binding = try await R13A11ProductSessionFactory
            .makeSession(
                route: route,
                modeBinding: modeBinding,
                processingConfiguration: .default,
                streamIdentifier:
                    "test.a11.one-construction-failure",
                candidateConstructor: { declaration in
                    if declaration.declaredKind == failedKind {
                        throw NSError(
                            domain:
                                "test.a11.candidate-construction",
                            code: 41
                        )
                    }
                    return try makeCandidate(
                        backendID:
                            declaration.expectedBackendID,
                        rank: 65_536,
                        script: [.processed]
                    ).candidate
                }
            )
        let reporter = try XCTUnwrap(
            binding.session
                as? any R13ProductASHDecisionReporting
        )
        let admissionSummary =
            await reporter.decisionSummary()
        let exclusion = try XCTUnwrap(
            admissionSummary.candidateExclusions.first
        )

        XCTAssertTrue(admissionSummary.events.isEmpty)
        XCTAssertEqual(
            admissionSummary.candidateExclusions.count,
            1
        )
        XCTAssertEqual(exclusion.declaredKind, failedKind)
        XCTAssertEqual(
            exclusion.expectedBackendID,
            R04VideoToolboxSubjectID.quality2x.rawValue
        )
        XCTAssertEqual(
            exclusion.phase,
            .sessionConstruction
        )
        XCTAssertEqual(
            exclusion.failure.reasonCode,
            "unexpected_typed_error"
        )
        XCTAssertEqual(
            exclusion.failure.errorDomain,
            "test.a11.candidate-construction"
        )
        XCTAssertEqual(exclusion.failure.errorCode, 41)
        XCTAssertEqual(
            exclusion.failure.detailSHA256.count,
            64
        )

        let fixture = try makeFrame(
            sequenceNumber: 0,
            seed: 109
        )
        let outcome = await binding.session.submit(
            fixture.frame
        )
        let processed = try requireProcessed(outcome)
        processed.resourceLifetimeToken.release()
        XCTAssertEqual(
            fixture.probe.releaseCount(
                for: fixture.tokenIdentity
            ),
            1
        )

        let finalSummary =
            await reporter.decisionSummary()
        XCTAssertEqual(
            finalSummary.candidateExclusions,
            [exclusion]
        )
        let metadata = try finalSummary.outputMetadata()
        let decoded = try JSONDecoder().decode(
            [R13ProductASHScalingCandidateExclusion].self,
            from: try XCTUnwrap(
                metadata.candidateExclusionsJSON
                    .data(using: .utf8)
            )
        )
        XCTAssertEqual(decoded, [exclusion])
        XCTAssertEqual(
            metadata.candidateExclusionsJSON,
            try R13ProductASHScalingCandidateExclusionEncoding
                .canonicalJSON([exclusion])
        )
        XCTAssertEqual(metadata.candidateExclusionCount, 1)
        XCTAssertNotEqual(
            metadata.journalSHA256,
            String(repeating: "0", count: 64)
        )
        _ = await binding.session.finish()
    }

    func testA11FactoryAllConstructionFailuresReturnEveryTypedExclusion()
        async throws {
        let route = R03ScaleRoute.scale2x
        let modeBinding =
            R13ReleaseModePolicy.binding(for: .auto)
        let declarations =
            R13A11ProductSessionFactory
                .candidateDeclarations(
                    route: route,
                    orchestrationKind:
                        modeBinding.orchestrationKind
                )

        do {
            _ = try await R13A11ProductSessionFactory
                .makeSession(
                    route: route,
                    modeBinding: modeBinding,
                    processingConfiguration: .default,
                    streamIdentifier:
                        "test.a11.all-construction-failures",
                    candidateConstructor: { declaration in
                        let ordinal =
                            R13ProductASHCandidateKind.allCases
                                .firstIndex(
                                    of:
                                        declaration.declaredKind
                                ) ?? -1
                        throw NSError(
                            domain:
                                "test.a11.all."
                                + declaration.declaredKind
                                    .rawValue,
                            code: 100 + ordinal
                        )
                    }
                )
            XCTFail(
                "All failed candidate constructions must fail closed."
            )
        } catch R13ProductASHScalingRouterError
            .noAdmittedCandidates(let exclusions) {
            XCTAssertEqual(
                exclusions.count,
                declarations.count
            )
            XCTAssertEqual(
                exclusions.map(\.declaredKind),
                declarations.map(\.declaredKind)
            )
            XCTAssertEqual(
                exclusions.map(\.expectedBackendID),
                declarations.map(\.expectedBackendID)
            )
            XCTAssertEqual(
                Set(exclusions.map(\.failure.errorCode))
                    .count,
                declarations.count
            )
            XCTAssertTrue(
                exclusions.allSatisfy {
                    $0.phase == .sessionConstruction
                        && $0.failure.reasonCode
                            == "unexpected_typed_error"
                        && $0.failure.detailSHA256.count == 64
                }
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testDeterministicAndExplicitEnginesNeverEnterOrchestration()
        async throws {
        let explicitEngines: [UpscaleEnginePreference] = [
            .accelerateVImageHighQuality,
            .mpsBilinear,
            .mpsLanczos
        ]
        for mode in UpscaleMode.allCases {
            for engine in explicitEngines {
                XCTAssertFalse(
                    R13ReleaseModePolicy.binding(
                        for: mode,
                        enginePreference: engine
                    ).usesProductOrchestration
                )
            }
        }

        let directBindings = [
            R13ReleaseModePolicy.binding(for: .deterministic),
            R13ReleaseModePolicy.binding(
                for: .auto,
                enginePreference: .accelerateVImageHighQuality
            ),
            R13ReleaseModePolicy.binding(
                for: .quality,
                enginePreference: .mpsBilinear
            ),
            R13ReleaseModePolicy.binding(
                for: .fast,
                enginePreference: .mpsLanczos
            )
        ]
        for modeBinding in directBindings {
            XCTAssertFalse(modeBinding.usesProductOrchestration)
            let binding = try await R13A11ProductSessionFactory
                .makeSession(
                    route: .scale3Over2,
                    modeBinding: modeBinding
                )
            XCTAssertNil(
                binding.session
                    as? any R13ProductASHDecisionReporting
            )
            XCTAssertEqual(
                binding.routeIdentity.backend.backendID,
                modeBinding.backendID
            )
            await binding.session.cancel()
        }
    }

    private func modelIdentityRoute(
        modelAssetsIdentity:
            AppleUpscaleModelAssetsIdentity
    ) throws -> AppleUpscaleRouteIdentity {
        try AppleUpscaleRouteIdentity(
            backend: AppleUpscaleBackendIdentity(
                backendID: "test.router.journal",
                backendRevision:
                    "test.router.journal.backend.v1",
                modelAssetsIdentity: modelAssetsIdentity
            ),
            configurationIdentity:
                "test.router.journal.observed.v1",
            policyIdentity:
                "test.router.journal.policy.v1",
            materialDecisionIdentity:
                "test.router.journal.decision.v1"
        )
    }
}

final class R13ModelLifecycleEngineBoundaryTests: XCTestCase {
    func testNonReadyQualityObservationIsNotAdmittedAndKeepsFallbacks()
        throws {
        let binding = try qualityBinding()
        let diagnostics = R04VideoToolboxConfigurationDiagnostics(
            nativeIdentity: .quality(
                R04ObservedQualityConfiguration(
                    frameWidth: 1_920,
                    frameHeight: 1_080,
                    integerScaleFactor: 2,
                    inputType: .video,
                    usesPrecomputedFlow: false,
                    qualityPriority: .normal,
                    revision: 0
                )
            ),
            supportedPixelFormats: [
                R04VideoToolboxRouteCatalog.pixelFormat
            ],
            modelStatus: .downloadRequired,
            processingMode: .quality
        )
        let observation = R04VTNativeCapabilityObservation(
            route: binding.route,
            capability: try capability(
                for: binding,
                disposition: .unavailable,
                eligibility: .notEvaluated
            ),
            status: .unavailable(.modelNotReady),
            diagnostics: diagnostics
        )

        XCTAssertNil(
            R13VideoToolboxProductCandidateAdmission
                .modelAssetsIdentity(
                    binding: binding,
                    observation: observation
                )
        )
        XCTAssertEqual(
            R13A11ProductSessionFactory
                .fallbackProfiles(for: .quality)
                .map(\.kind),
            [.highQualityVImage, .deterministicMPSLanczos]
        )
    }

    func testReadyQualityObservationBindsAppleManagedModelToExactRoute()
        throws {
        let binding = try qualityBinding()
        let observation = R04VTNativeCapabilityObservation(
            route: binding.route,
            capability: try capability(
                for: binding,
                disposition: .runnable,
                eligibility: .productQualified
            ),
            status: .runnable,
            diagnostics: readyQualityDiagnostics()
        )

        let identity = try XCTUnwrap(
            R13VideoToolboxProductCandidateAdmission
                .modelAssetsIdentity(
                    binding: binding,
                    observation: observation
                )
        )

        XCTAssertEqual(
            identity,
            .appleConfigurationManaged(
                configurationIdentity:
                    binding.route.configurationIdentity,
                readiness: .ready
            )
        )
    }

    func testRoutingResourcesReportReadyWhenAppleManagedCandidateExists()
        throws {
        let route = try AppleUpscaleRouteIdentity(
            backend: AppleUpscaleBackendIdentity(
                backendID: "test.videotoolbox.quality",
                backendRevision: "1",
                modelAssetsIdentity:
                    .appleConfigurationManaged(
                        configurationIdentity:
                            "test.quality.configuration",
                        readiness: .ready
                    )
            ),
            configurationIdentity:
                "test.quality.configuration.observed.model-ready",
            policyIdentity: "test.product.policy",
            materialDecisionIdentity: "test.product.decision"
        )
        let candidate = R13ProductBackendSessionCandidate(
            session: try R13ModelLifecycleIdentitySession(
                identity: route
            ),
            routeIdentity: route,
            profile: .videoToolboxQuality
        )

        XCTAssertEqual(
            R13ProductASHRoutingSession.modelReadiness(
                for: [candidate]
            ),
            .ready
        )
        XCTAssertEqual(
            R13ProductASHRoutingSession.modelReadiness(for: []),
            .notRequired
        )
    }

    func testAppleManagedModelIdentityRejectsEmptyConfigurationIdentity() {
        XCTAssertThrowsError(
            try AppleUpscaleBackendIdentity(
                backendID: "test.videotoolbox.quality",
                backendRevision: "1",
                modelAssetsIdentity:
                    .appleConfigurationManaged(
                        configurationIdentity: "",
                        readiness: .ready
                    )
            )
        ) { error in
            XCTAssertEqual(
                error as? AppleUpscaleContractError,
                .emptyIdentityField(
                    "configuration_model_identity"
                )
            )
        }
    }

    private func qualityBinding() throws
        -> R04VideoToolboxNativeRouteBinding {
        try XCTUnwrap(
            R04VideoToolboxNativeRouteSelector.exactBinding(
                sourceResolution: .p1080,
                targetResolution: .p2160,
                intent: .quality
            )
        )
    }

    private func readyQualityDiagnostics()
        -> R04VideoToolboxConfigurationDiagnostics {
        R04VideoToolboxConfigurationDiagnostics(
            nativeIdentity: .quality(
                R04ObservedQualityConfiguration(
                    frameWidth: 1_920,
                    frameHeight: 1_080,
                    integerScaleFactor: 2,
                    inputType: .video,
                    usesPrecomputedFlow: false,
                    qualityPriority: .normal,
                    revision: 0
                )
            ),
            supportedPixelFormats: [
                R04VideoToolboxRouteCatalog.pixelFormat
            ],
            modelStatus: .ready,
            processingMode: .quality
        )
    }

    private func capability(
        for binding: R04VideoToolboxNativeRouteBinding,
        disposition: AppleUpscaleRuntimeDisposition,
        eligibility: AppleUpscaleBackendEligibility
    ) throws -> AppleUpscaleCapability {
        try AppleUpscaleCapability(
            id: AppleUpscaleCapabilityID(
                binding.route.capabilityID
            ),
            role: .primaryScaler,
            frameworkIdentity: "VideoToolbox",
            observationStatus: .observed,
            runtimeDisposition: disposition,
            backendEligibility: eligibility
        )
    }
}

private actor R13ModelLifecycleIdentitySession:
    AppleUpscaleSession {
    nonisolated let identity: AppleUpscaleRouteIdentity
    private let failure: AppleUpscaleBackendFailed

    init(identity: AppleUpscaleRouteIdentity) throws {
        self.identity = identity
        failure = try AppleUpscaleBackendFailed(
            processingIdentity:
                AppleUpscaleProcessingIdentity(
                    route: identity,
                    fallbackHistory: []
                ),
            reason: "not_executed"
        )
    }

    func submit(
        _ frame: AppleUpscaleFrame
    ) async -> AppleUpscaleBackendOutcome<
        AppleUpscaleProcessedFrame
    > {
        frame.resourceLifetimeToken.release()
        return .failed(failure)
    }

    func reset(reason _: AppleUpscaleResetReason) async {}

    func finish() async -> AppleUpscaleSessionSummary {
        AppleUpscaleSessionSummary(
            submittedFrameCount: 0,
            processedFrameCount: 0,
            terminalizationCount: 1
        )
    }

    func cancel() async {}
}
