import XCTest
@testable import Mirmir

final class R08DeterministicAnalysisServiceTests: XCTestCase {
    func testAnalyzedResultIsCompleteBoundedAndAnalysisOnly() async throws {
        let service = try R08DeterministicAnalysisService()
        let request = try R08TestSupport.request()
        let result = try R08TestSupport.analyzed(try await service.analyze(request))

        XCTAssertEqual(result.request.scheduleTrigger, .periodicProxyFrame)
        XCTAssertEqual(result.executionIdentity, .deterministicFixtureV1)
        XCTAssertEqual(result.pixelAuthority, .analysisOnlyNoPixelOutput)
        XCTAssertEqual(result.resourceUsage.memoryBytes, 4_096)
        XCTAssertEqual(result.resourceUsage.latencyMicroseconds, 1_000)
        XCTAssertEqual(
            result.resourceUsage.zeroCopyDisposition,
            .notUsedDeterministicSimulation
        )
        XCTAssertEqual(result.stateReceipt.generation, 0)
        XCTAssertEqual(result.stateReceipt.frameOrdinal, 12)
        XCTAssertEqual(result.cacheDisposition, .specialized)
        XCTAssertEqual(result.heads.sourceClassification.classification, .mixed)

        let maps = spatialMaps(result.heads)
        XCTAssertEqual(maps.count, 8)
        XCTAssertTrue(maps.allSatisfy { map in
            map.width == 2
                && map.height == 2
                && map.samples.count == 4
                && map.samples.allSatisfy { (0...R08Q15Map.maximumSample).contains($0) }
        })
        XCTAssertTrue(
            (0...R08Q15Map.maximumSample).contains(
                result.heads.noReferenceQualityQ15.rawValue
            )
        )

        let snapshot = await service.snapshot()
        XCTAssertEqual(snapshot.streamID, request.streamID)
        XCTAssertEqual(snapshot.shotID, request.shotID)
        XCTAssertEqual(snapshot.lastFrameOrdinal, 12)
        XCTAssertEqual(snapshot.analyzedCount, 1)
        XCTAssertEqual(snapshot.specializationCount, 1)
        XCTAssertEqual(snapshot.cacheHitCount, 0)
    }

    func testOutputsAreRepeatableAndAOTBehaviorallyEquivalent() async throws {
        let plainService = try R08DeterministicAnalysisService()
        let aotService = try R08DeterministicAnalysisService()
        let unavailableService = try R08DeterministicAnalysisService()
        let plainRequest = try R08TestSupport.request()
        var aotOptions = R08TestRequestOptions()
        aotOptions.aot = .behaviorallyEquivalent
        let aotRequest = try R08TestSupport.request(aotOptions)
        var unavailableOptions = R08TestRequestOptions()
        unavailableOptions.aot = .unavailable
        let unavailableRequest = try R08TestSupport.request(unavailableOptions)

        let plain = try R08TestSupport.analyzed(
            try await plainService.analyze(plainRequest)
        )
        let aot = try R08TestSupport.analyzed(
            try await aotService.analyze(aotRequest)
        )
        let unavailable = try R08TestSupport.analyzed(
            try await unavailableService.analyze(unavailableRequest)
        )

        XCTAssertEqual(plain.heads, aot.heads)
        XCTAssertEqual(aot.heads, unavailable.heads)
        XCTAssertEqual(plain.resourceUsage.aotCompilation, .notRequested)
        XCTAssertEqual(aot.resourceUsage.aotCompilation, .behaviorallyEquivalent)
        XCTAssertEqual(plain.resourceUsage.aotExecutionTrace, .runtimeSpecialization)
        XCTAssertEqual(aot.resourceUsage.aotExecutionTrace, .deterministicAOTFixtureSimulation)
        XCTAssertEqual(
            unavailable.resourceUsage.aotExecutionTrace,
            .runtimeFallbackNativeAOTNotObserved
        )
        XCTAssertEqual(aot.executionIdentity.nativeExecution, .notObserved)
        XCTAssertEqual(unavailable.executionIdentity.nativeExecution, .notObserved)
        let plainKeys = await plainService.snapshot().specializationKeysOldestFirst
        let aotKeys = await aotService.snapshot().specializationKeysOldestFirst
        XCTAssertEqual(plainKeys, aotKeys)
    }

    func testServiceUsesResolvedScheduleAndRejectsUnscheduledFrame() async throws {
        let service = try R08DeterministicAnalysisService()

        var requested = R08TestRequestOptions()
        requested.frameOrdinal = 5
        requested.ashRequested = true
        requested.keyframe = true
        let requestedResult = try R08TestSupport.analyzed(
            try await service.analyze(try R08TestSupport.request(requested))
        )
        XCTAssertEqual(requestedResult.request.scheduleTrigger, .ashRequestedFrame)

        var keyframe = R08TestRequestOptions()
        keyframe.frameOrdinal = 7
        keyframe.keyframe = true
        let keyframeResult = try R08TestSupport.analyzed(
            try await service.analyze(try R08TestSupport.request(keyframe))
        )
        XCTAssertEqual(keyframeResult.request.scheduleTrigger, .keyframe)

        var periodic = R08TestRequestOptions()
        periodic.frameOrdinal = 24
        let periodicResult = try R08TestSupport.analyzed(
            try await service.analyze(try R08TestSupport.request(periodic))
        )
        XCTAssertEqual(periodicResult.request.scheduleTrigger, .periodicProxyFrame)

        let acceptedSnapshot = await service.snapshot()
        var unscheduled = R08TestRequestOptions()
        unscheduled.frameOrdinal = 25
        let bypass = try R08TestSupport.bypass(
            try await service.analyze(try R08TestSupport.request(unscheduled))
        )
        XCTAssertEqual(bypass.reason, .unscheduledFrame)
        let rejectedSnapshot = await service.snapshot()
        XCTAssertEqual(rejectedSnapshot, acceptedSnapshot)
    }

    func testAvailabilityFailuresUseTypedBypassWithoutMutation() async throws {
        let reasons: [R08AnalysisBypassReason] = [
            .unsupportedOS,
            .frameworkUnavailable,
            .assetsAbsent,
            .disabledByPolicy
        ]
        for reason in reasons {
            let service = try R08DeterministicAnalysisService(
                availabilityBypassReason: reason
            )
            let bypass = try R08TestSupport.bypass(
                try await service.analyze(try R08TestSupport.request())
            )
            XCTAssertEqual(bypass.reason, reason)
            let snapshot = await service.snapshot()
            XCTAssertEqual(snapshot.analyzedCount, 0)
        }
    }

    func testInvalidSimulationIdentityBypassesWithoutMutation() async throws {
        var nativeTransfer = R08TestRequestOptions()
        nativeTransfer.executionMode = .nativeCoreAI
        nativeTransfer.zeroCopyAttempt = .succeeded
        let customProxy = try R08AnalysisProxyIdentity(
            fixtureID: "other-proxy",
            contentSHA256: String(repeating: "b", count: 64),
            width: 512,
            height: 288,
            pixelFormat: "BGRA"
        )
        var wrongProxy = R08TestRequestOptions()
        wrongProxy.proxyIdentity = customProxy
        var nativeArtifact = R08TestRequestOptions()
        nativeArtifact.model = try R08TestSupport.model(artifactKind: .coreAIModel)

        for options in [nativeTransfer, wrongProxy, nativeArtifact] {
            let service = try R08DeterministicAnalysisService()
            let bypass = try R08TestSupport.bypass(
                try await service.analyze(try R08TestSupport.request(options))
            )
            XCTAssertEqual(bypass.reason, .identityInvalid)
            let snapshot = await service.snapshot()
            XCTAssertEqual(snapshot.analyzedCount, 0)
        }
    }

    func testInvalidOutputBypassesWithoutStateOrCacheMutation() async throws {
        let service = try R08DeterministicAnalysisService(
            analysisHeadProvider: { _ in
                throw R08AnalysisContractError.missingOutputHead(
                    R08AnalysisOutputHeadID.noReferenceQualityEstimate.rawValue
                )
            }
        )
        let bypass = try R08TestSupport.bypass(
            try await service.analyze(try R08TestSupport.request())
        )

        XCTAssertEqual(bypass.reason, .outputInvalid)
        let snapshot = await service.snapshot()
        XCTAssertEqual(snapshot.stateGeneration, 0)
        XCTAssertNil(snapshot.streamID)
        XCTAssertNil(snapshot.shotID)
        XCTAssertNil(snapshot.lastFrameOrdinal)
        XCTAssertTrue(snapshot.specializationKeysOldestFirst.isEmpty)
        XCTAssertEqual(snapshot.analyzedCount, 0)
    }

    func testBoundedSpecializationCacheUsesExactKeyAndLRUOrder() async throws {
        let service = try R08DeterministicAnalysisService(cacheCapacity: 2)
        try await analyze(service, ordinal: 12, hashCharacter: "a")
        try await analyze(service, ordinal: 24, hashCharacter: "b")
        try await analyze(service, ordinal: 36, hashCharacter: "c")

        var snapshot = await service.snapshot()
        XCTAssertEqual(
            snapshot.specializationKeysOldestFirst.map(\.modelSHA256),
            [String(repeating: "b", count: 64), String(repeating: "c", count: 64)]
        )
        XCTAssertEqual(snapshot.specializationCount, 3)
        XCTAssertEqual(snapshot.cacheHitCount, 0)

        try await analyze(service, ordinal: 48, hashCharacter: "b")
        snapshot = await service.snapshot()
        XCTAssertEqual(
            snapshot.specializationKeysOldestFirst.map(\.modelSHA256),
            [String(repeating: "c", count: 64), String(repeating: "b", count: 64)]
        )
        XCTAssertEqual(snapshot.analyzedCount, 4)
        XCTAssertEqual(snapshot.specializationCount, 3)
        XCTAssertEqual(snapshot.cacheHitCount, 1)
    }

    func testSpecializationKeyIncludesModelPlatformAndIOContract() async throws {
        let service = try R08DeterministicAnalysisService(cacheCapacity: 4)
        _ = try await service.analyze(try R08TestSupport.request())

        var otherPlatform = R08TestRequestOptions()
        otherPlatform.frameOrdinal = 24
        otherPlatform.platformID = "r08.test.other-platform"
        let platformResult = try R08TestSupport.analyzed(
            try await service.analyze(try R08TestSupport.request(otherPlatform))
        )
        XCTAssertEqual(platformResult.cacheDisposition, .specialized)

        var otherIO = R08TestRequestOptions()
        otherIO.frameOrdinal = 36
        otherIO.ioContractID = "r08.test.other-io-contract"
        let ioResult = try R08TestSupport.analyzed(
            try await service.analyze(try R08TestSupport.request(otherIO))
        )
        XCTAssertEqual(ioResult.cacheDisposition, .specialized)

        var originalKey = R08TestRequestOptions()
        originalKey.frameOrdinal = 48
        let hit = try R08TestSupport.analyzed(
            try await service.analyze(try R08TestSupport.request(originalKey))
        )
        XCTAssertEqual(hit.cacheDisposition, .hit)

        let snapshot = await service.snapshot()
        XCTAssertEqual(snapshot.specializationCount, 3)
        XCTAssertEqual(snapshot.cacheHitCount, 1)
        XCTAssertEqual(Set(snapshot.specializationKeysOldestFirst.map(\.modelSHA256)).count, 1)
        XCTAssertEqual(Set(snapshot.specializationKeysOldestFirst.map(\.platformProfile)).count, 2)
        XCTAssertEqual(Set(snapshot.specializationKeysOldestFirst.map(\.ioContractIdentity)).count, 2)
    }

}

final class R08DeterministicAnalysisLifecycleTests: XCTestCase {
    func testResetChangesGenerationClearsSequenceAndRetainsCache() async throws {
        let service = try R08DeterministicAnalysisService()
        _ = try await service.analyze(try R08TestSupport.request())
        let accepted = await service.snapshot()
        XCTAssertEqual(accepted.specializationKeysOldestFirst.count, 1)

        let generation = try await service.resetState(reason: .sceneCut)
        XCTAssertEqual(generation, 1)
        let reset = await service.snapshot()
        XCTAssertNil(reset.streamID)
        XCTAssertNil(reset.shotID)
        XCTAssertNil(reset.lastFrameOrdinal)
        XCTAssertEqual(reset.specializationKeysOldestFirst, accepted.specializationKeysOldestFirst)

        var stale = R08TestRequestOptions()
        stale.frameOrdinal = 24
        let staleBypass = try R08TestSupport.bypass(
            try await service.analyze(try R08TestSupport.request(stale))
        )
        XCTAssertEqual(
            staleBypass.reason,
            .stateGenerationMismatch(expected: 1, actual: 0)
        )

        var current = stale
        current.stateGeneration = 1
        let result = try R08TestSupport.analyzed(
            try await service.analyze(try R08TestSupport.request(current))
        )
        XCTAssertEqual(result.stateReceipt.generation, 1)
    }

    func testStreamShotAndOrdinalRejectionsDoNotMutateState() async throws {
        let service = try R08DeterministicAnalysisService()
        var acceptedOptions = R08TestRequestOptions()
        acceptedOptions.frameOrdinal = 24
        _ = try await service.analyze(try R08TestSupport.request(acceptedOptions))
        let accepted = await service.snapshot()

        var otherStream = R08TestRequestOptions()
        otherStream.frameOrdinal = 36
        otherStream.streamID = "other.stream"
        let streamBypass = try R08TestSupport.bypass(
            try await service.analyze(try R08TestSupport.request(otherStream))
        )
        XCTAssertEqual(
            streamBypass.reason,
            .streamIdentityMismatch(expected: "r08.stream", actual: "other.stream")
        )

        var otherShot = R08TestRequestOptions()
        otherShot.frameOrdinal = 36
        otherShot.shotID = "other.shot"
        let shotBypass = try R08TestSupport.bypass(
            try await service.analyze(try R08TestSupport.request(otherShot))
        )
        XCTAssertEqual(
            shotBypass.reason,
            .shotIdentityMismatch(expected: "r07.shot", actual: "other.shot")
        )

        var duplicateOptions = R08TestRequestOptions()
        duplicateOptions.frameOrdinal = 24
        let duplicate = try R08TestSupport.bypass(
            try await service.analyze(try R08TestSupport.request(duplicateOptions))
        )
        XCTAssertEqual(duplicate.reason, .duplicateFrameOrdinal(24))

        var staleOptions = R08TestRequestOptions()
        staleOptions.frameOrdinal = 23
        let stale = try R08TestSupport.bypass(
            try await service.analyze(try R08TestSupport.request(staleOptions))
        )
        XCTAssertEqual(stale.reason, .staleFrameOrdinal(previous: 24, actual: 23))
        let rejected = await service.snapshot()
        XCTAssertEqual(rejected, accepted)
    }

    func testStateResetDuringAwaitIsCaughtBeforeCommit() async throws {
        let gate = R08TestCommitGate()
        let service = try R08DeterministicAnalysisService(
            beforeCommit: { await gate.wait() }
        )
        let task = Task {
            try await service.analyze(try R08TestSupport.request())
        }
        await gate.waitUntilEntered()
        let pending = await service.snapshot()

        let resetGeneration = try await service.resetState(reason: .discontinuity)
        XCTAssertEqual(resetGeneration, 1)
        await gate.release()
        let bypass = try R08TestSupport.bypass(try await task.value)
        XCTAssertEqual(
            bypass.reason,
            .stateGenerationMismatch(expected: 1, actual: 0)
        )

        let rejected = await service.snapshot()
        XCTAssertEqual(rejected.stateGeneration, 1)
        XCTAssertEqual(rejected.specializationKeysOldestFirst, pending.specializationKeysOldestFirst)
        XCTAssertEqual(rejected.analyzedCount, pending.analyzedCount)
        XCTAssertNil(rejected.lastFrameOrdinal)
    }

    func testCancellationResetsGenerationWithoutCommittingResultOrCache() async throws {
        let gate = R08TestCommitGate()
        let service = try R08DeterministicAnalysisService(
            beforeCommit: { await gate.wait() }
        )
        let task = Task {
            try await service.analyze(try R08TestSupport.request())
        }
        await gate.waitUntilEntered()
        let preCancellation = await service.snapshot()

        task.cancel()
        await gate.release()
        let bypass = try R08TestSupport.bypass(try await task.value)
        XCTAssertEqual(bypass.reason, .cancelled)

        let snapshot = await service.snapshot()
        XCTAssertEqual(snapshot.stateGeneration, 1)
        XCTAssertNil(snapshot.streamID)
        XCTAssertNil(snapshot.shotID)
        XCTAssertNil(snapshot.lastFrameOrdinal)
        XCTAssertEqual(
            snapshot.specializationKeysOldestFirst,
            preCancellation.specializationKeysOldestFirst
        )
        XCTAssertEqual(snapshot.analyzedCount, preCancellation.analyzedCount)
        XCTAssertEqual(snapshot.specializationCount, preCancellation.specializationCount)
        XCTAssertEqual(snapshot.cacheHitCount, preCancellation.cacheHitCount)
    }

    func testConcurrentRequestBypassesBusyWithoutMutatingInFlightTransaction() async throws {
        let gate = R08TestCommitGate()
        let service = try R08DeterministicAnalysisService(
            beforeCommit: { await gate.wait() }
        )
        let first = Task {
            try await service.analyze(try R08TestSupport.request())
        }
        await gate.waitUntilEntered()

        var secondOptions = R08TestRequestOptions()
        secondOptions.frameOrdinal = 24
        let second = try R08TestSupport.bypass(
            try await service.analyze(try R08TestSupport.request(secondOptions))
        )
        XCTAssertEqual(second.reason, .busy)

        first.cancel()
        await gate.release()
        let firstBypass = try R08TestSupport.bypass(try await first.value)
        XCTAssertEqual(firstBypass.reason, .cancelled)
        let snapshot = await service.snapshot()
        XCTAssertEqual(snapshot.stateGeneration, 1)
        XCTAssertEqual(snapshot.analyzedCount, 0)
    }
}

private extension R08DeterministicAnalysisServiceTests {
    func spatialMaps(_ heads: R08AnalysisHeads) -> [R08Q15Map] {
        [
            heads.protection.faceSkinQ15,
            heads.protection.textLineArtQ15,
            heads.condition.animationUILikelihoodQ15,
            heads.condition.noiseCompressionSeverityQ15,
            heads.condition.blurMotionBlurEstimateQ15,
            heads.riskConfidence.aliasingRingingRiskQ15,
            heads.riskConfidence.textureDetailConfidenceQ15,
            heads.riskConfidence.motionReliabilityOcclusionRiskQ15
        ]
    }

    func analyze(
        _ service: R08DeterministicAnalysisService,
        ordinal: Int64,
        hashCharacter: Character
    ) async throws {
        var options = R08TestRequestOptions()
        options.frameOrdinal = ordinal
        options.model = try R08TestSupport.model(hashCharacter: hashCharacter)
        _ = try R08TestSupport.analyzed(
            try await service.analyze(try R08TestSupport.request(options))
        )
    }
}
