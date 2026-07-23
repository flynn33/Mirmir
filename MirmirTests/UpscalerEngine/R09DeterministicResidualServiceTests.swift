import XCTest
@testable import Mirmir

actor R09ResidualTestGate {
    private var entered = false
    private var released = false
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []

    func pause() async {
        entered = true
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseContinuations.append(continuation)
        }
    }

    func waitUntilEntered() async {
        while !entered {
            await Task.yield()
        }
    }

    func release() {
        released = true
        let continuations = releaseContinuations
        releaseContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }
}

final class R09DeterministicResidualServiceTests: XCTestCase {
    func testDeterministicOutputIsRepeatableAndTruthfullySimulated() async throws {
        let request = try await R09ResidualTestSupport.request()
        let first = try R09ResidualTestSupport.produced(
            await R09DeterministicResidualService().predictResidual(for: request)
        )
        let second = try R09ResidualTestSupport.produced(
            await R09DeterministicResidualService().predictResidual(for: request)
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.requestIdentity, request.identity)
        XCTAssertEqual(first.authorization, request.authorization)
        XCTAssertEqual(first.scalerIdentity, request.scalerIdentity)
        XCTAssertEqual(first.modelIdentity, request.modelIdentity)
        XCTAssertEqual(first.executionIdentity, .deterministicSimulationV1)
        XCTAssertEqual(first.executionIdentity.nativeExecution, .notObserved)
        XCTAssertEqual(first.pixelAuthority, .residualMapOnlyNoFrameApplication)
        XCTAssertEqual(first.resourceMeasurement.workingSetBytes, 4_096)
        XCTAssertEqual(first.resourceMeasurement.elapsedMicroseconds, 1_000)
    }

    func testOutputIsSignedZeroCenteredAndBoundedByEveryInputPolicy() async throws {
        let request = try await R09ResidualTestSupport.request()
        let output = try R09ResidualTestSupport.produced(
            await R09DeterministicResidualService().predictResidual(for: request)
        )

        XCTAssertEqual(
            output.residual.luma.samplesQ16,
            R09ResidualTestSupport.expandTwoByTwo([2_000, -2_000, 0, 2_000])
        )
        XCTAssertEqual(output.residual.chromaCb.samplesQ16, [2_000, -2_000, 0, 2_000])
        XCTAssertEqual(output.residual.chromaCr.samplesQ16, [2_000, -2_000, 0, 2_000])
        XCTAssertTrue(output.residual.luma.samplesQ16.contains(where: { $0 < 0 }))
        XCTAssertTrue(output.residual.luma.samplesQ16.contains(0))
        XCTAssertTrue(output.residual.luma.samplesQ16.contains(where: { $0 > 0 }))

        for id in R09ResidualPlaneID.allCases {
            let plane = output.residual[id]
            XCTAssertEqual(plane.width, request.postScalerFrame[id].width)
            XCTAssertEqual(plane.height, request.postScalerFrame[id].height)
            XCTAssertTrue(plane.samplesQ16.allSatisfy { sample in
                abs(sample) <= request.limits.perPlane[id].maximumMagnitudeQ16
                    && abs(sample) <= request.limits.content.maximumMagnitudeQ16
                    && abs(sample) <= R09PlaneResidualLimitQ16.hardMaximumMagnitude
            })
            let disabledIndex = id == .luma ? 8 : 2
            XCTAssertEqual(
                plane.samplesQ16[disabledIndex],
                0,
                "protected/edge-disabled sample must be zero"
            )
        }
    }

    func testInputAndProviderConfidenceFailuresBypassWithoutResidual() async throws {
        var lowInput = R09ResidualTestRequestOptions()
        lowInput.sourceReferenceQ15 = 16_383
        let inputBypass = try R09ResidualTestSupport.bypassed(
            await R09DeterministicResidualService().predictResidual(
                for: try await R09ResidualTestSupport.request(lowInput)
            )
        )
        XCTAssertEqual(
            inputBypass.reason,
            .confidenceBelowMinimum(
                role: .sourceReference,
                minimumQ15: 16_384,
                actualQ15: 16_383
            )
        )
        XCTAssertEqual(inputBypass.fallbackRoute, .appleScalerOutputUnmodified)

        let request = try await R09ResidualTestSupport.request()
        let service = R09DeterministicResidualService { request in
            try await R09ResidualTestSupport.rawOutput(
                for: request,
                confidenceQ15: 16_383
            )
        }
        let providerBypass = try R09ResidualTestSupport.bypassed(
            await service.predictResidual(for: request)
        )
        XCTAssertEqual(
            providerBypass.reason,
            .confidenceBelowMinimum(
                role: .providerOutput,
                minimumQ15: 16_384,
                actualQ15: 16_383
            )
        )
    }

    func testResourceFailuresAreTypedAndFailClosed() async throws {
        let request = try await R09ResidualTestSupport.request()
        let memoryService = R09DeterministicResidualService { request in
            try await R09ResidualTestSupport.rawOutput(
                for: request,
                workingSetBytes: 8_193
            )
        }
        let memory = try R09ResidualTestSupport.bypassed(
            await memoryService.predictResidual(for: request)
        )
        XCTAssertEqual(
            memory.reason,
            .resourceBudgetExceeded(
                role: .workingSetBytes,
                maximum: 8_192,
                actual: 8_193
            )
        )

        let latencyService = R09DeterministicResidualService { request in
            try await R09ResidualTestSupport.rawOutput(
                for: request,
                elapsedMicroseconds: 2_001
            )
        }
        let latency = try R09ResidualTestSupport.bypassed(
            await latencyService.predictResidual(for: request)
        )
        XCTAssertEqual(
            latency.reason,
            .resourceBudgetExceeded(
                role: .elapsedMicroseconds,
                maximum: 2_000,
                actual: 2_001
            )
        )
    }

    func testMalformedProviderRangeAndDirectionBypass() async throws {
        let request = try await R09ResidualTestSupport.request()
        let nominal = try await R09ResidualTestSupport.rawOutput(for: request)
        var outOfRangePlanes = nominal.planes
        var outOfRangeSamples = outOfRangePlanes[0].samplesQ16
        outOfRangeSamples[0] = 4_097
        outOfRangePlanes[0] = R09RawResidualPlaneQ16(
            id: .luma,
            width: outOfRangePlanes[0].width,
            height: outOfRangePlanes[0].height,
            samplesQ16: outOfRangeSamples
        )
        let frozenOutOfRangePlanes = outOfRangePlanes
        let rangeService = R09DeterministicResidualService { request in
            try await R09ResidualTestSupport.rawOutput(
                for: request,
                planes: frozenOutOfRangePlanes
            )
        }
        let rangeBypass = try R09ResidualTestSupport.bypassed(
            await rangeService.predictResidual(for: request)
        )
        XCTAssertEqual(
            rangeBypass.reason,
            .invalidProviderOutput(.sampleOutOfRange(plane: .luma, index: 0, value: 4_097))
        )

        var wrongDirectionPlanes = nominal.planes
        var wrongDirectionSamples = wrongDirectionPlanes[0].samplesQ16
        wrongDirectionSamples[0] = -1
        wrongDirectionPlanes[0] = R09RawResidualPlaneQ16(
            id: .luma,
            width: wrongDirectionPlanes[0].width,
            height: wrongDirectionPlanes[0].height,
            samplesQ16: wrongDirectionSamples
        )
        let frozenWrongDirectionPlanes = wrongDirectionPlanes
        let directionService = R09DeterministicResidualService { request in
            try await R09ResidualTestSupport.rawOutput(
                for: request,
                planes: frozenWrongDirectionPlanes
            )
        }
        let directionBypass = try R09ResidualTestSupport.bypassed(
            await directionService.predictResidual(for: request)
        )
        XCTAssertEqual(
            directionBypass.reason,
            .invalidProviderOutput(.directionInconsistent(plane: .luma, index: 0))
        )

        var planeLimitPlanes = nominal.planes
        var planeLimitSamples = planeLimitPlanes[1].samplesQ16
        planeLimitSamples[0] = 2_049
        planeLimitPlanes[1] = R09RawResidualPlaneQ16(
            id: .chromaCb,
            width: planeLimitPlanes[1].width,
            height: planeLimitPlanes[1].height,
            samplesQ16: planeLimitSamples
        )
        let frozenPlaneLimitPlanes = planeLimitPlanes
        let planeLimitService = R09DeterministicResidualService { request in
            try await R09ResidualTestSupport.rawOutput(
                for: request,
                planes: frozenPlaneLimitPlanes
            )
        }
        let planeLimitBypass = try R09ResidualTestSupport.bypassed(
            await planeLimitService.predictResidual(for: request)
        )
        XCTAssertEqual(
            planeLimitBypass.reason,
            .planeLimitExceeded(
                plane: .chromaCb,
                index: 0,
                maximumMagnitudeQ16: 2_048,
                actualQ16: 2_049
            )
        )
    }

    func testIdentityMismatchAndProviderFailureAreDistinctBypasses() async throws {
        var wrongModel = R09ResidualTestRequestOptions()
        wrongModel.modelIdentity = try R09ResidualModelIdentity(
            modelID: "r09.other-model",
            modelVersion: "1",
            artifactKind: .deterministicSimulationContract,
            contentSHA256: R09ResidualModelIdentity.deterministicProviderSHA256,
            preprocessingIdentity:
                R09ResidualModelIdentity.deterministicPreprocessingIdentity,
            postprocessingIdentity:
                R09ResidualModelIdentity.deterministicPostprocessingIdentity,
            residualContractIdentity:
                R09ResidualModelIdentity.deterministicResidualContractIdentity
        )
        guard case .notAuthorized(let modelBypass) = try await R09ResidualTestSupport
            .authorizationOutcome(wrongModel) else {
            return XCTFail("A model identity mismatch must not create a request")
        }
        XCTAssertEqual(
            modelBypass.reason,
            .authorizationInvalid(.deterministicModelBindingMismatch)
        )

        var wrongScaler = R09ResidualTestRequestOptions()
        wrongScaler.scalerBackendID = "r09.other-primary"
        wrongScaler.scalerImplementationVersion = "r09.other-primary.v1"
        guard case .notAuthorized(let scalerBypass) = try await R09ResidualTestSupport
            .authorizationOutcome(wrongScaler) else {
            return XCTFail("A scaler identity mismatch must not create a request")
        }
        XCTAssertEqual(
            scalerBypass.reason,
            .authorizationInvalid(.deterministicExecutionBindingMismatch)
        )

        let failingService = R09DeterministicResidualService { _ in
            throw R09ResidualTestProviderError.failed
        }
        let failure = try R09ResidualTestSupport.bypassed(
            await failingService.predictResidual(
                for: try await R09ResidualTestSupport.request()
            )
        )
        XCTAssertEqual(failure.reason, .providerFailed)
    }

    func testEligibilityHallucinationAndConsistencyStopsAreTyped() async throws {
        var noRegion = R09ResidualTestRequestOptions()
        noRegion.ashApprovedSamplesQ15 = [0, 0, 0, 0]
        let noRegionBypass = try R09ResidualTestSupport.bypassed(
            await R09DeterministicResidualService().predictResidual(
                for: try await R09ResidualTestSupport.request(noRegion)
            )
        )
        XCTAssertEqual(noRegionBypass.reason, .noEligibleRegion)

        var hallucination = R09ResidualTestRequestOptions()
        hallucination.hallucinationRiskQ15 = 16_385
        let hallucinationBypass = try R09ResidualTestSupport.bypassed(
            await R09DeterministicResidualService().predictResidual(
                for: try await R09ResidualTestSupport.request(hallucination)
            )
        )
        XCTAssertEqual(
            hallucinationBypass.reason,
            .hallucinationRiskExceeded(maximumAllowedQ15: 16_384, actualQ15: 16_385)
        )

        var conflict = R09ResidualTestRequestOptions()
        conflict.sourceSamplesQ16 = [34_000, 34_000, 34_000, 34_000]
        conflict.temporalSamplesQ16 = [26_000, 26_000, 26_000, 26_000]
        let consistencyBypass = try R09ResidualTestSupport.bypassed(
            await R09DeterministicResidualService().predictResidual(
                for: try await R09ResidualTestSupport.request(conflict)
            )
        )
        XCTAssertEqual(consistencyBypass.reason, .sourceTemporalConsistencyRejected)
    }

    func testPolicyAvailabilityBusyAndCancellationRemainFailClosed() async throws {
        let request = try await R09ResidualTestSupport.request()
        let disabled = try R09ResidualTestSupport.bypassed(
            await R09DeterministicResidualService(policyEnabled: false)
                .predictResidual(for: request)
        )
        XCTAssertEqual(disabled.reason, .disabledByPolicy)

        let unavailable = try R09ResidualTestSupport.bypassed(
            await R09DeterministicResidualService(availabilityFailure: .assetsUnavailable)
                .predictResidual(for: request)
        )
        XCTAssertEqual(unavailable.reason, .unavailable(.assetsUnavailable))

        let busyGate = R09ResidualTestGate()
        let busyService = R09DeterministicResidualService { request in
            await busyGate.pause()
            return try await R09DeterministicResidualProvider.predict(request: request)
        }
        let first = Task { await busyService.predictResidual(for: request) }
        await busyGate.waitUntilEntered()
        let busy = try R09ResidualTestSupport.bypassed(
            await busyService.predictResidual(for: request)
        )
        XCTAssertEqual(busy.reason, .busy)
        await busyGate.release()
        _ = try R09ResidualTestSupport.produced(await first.value)

        let cancellationGate = R09ResidualTestGate()
        let cancellationService = R09DeterministicResidualService { request in
            await cancellationGate.pause()
            return try await R09DeterministicResidualProvider.predict(request: request)
        }
        let cancelledTask = Task {
            await cancellationService.predictResidual(for: request)
        }
        await cancellationGate.waitUntilEntered()
        cancelledTask.cancel()
        await cancellationGate.release()
        let cancelled = try R09ResidualTestSupport.bypassed(await cancelledTask.value)
        XCTAssertEqual(cancelled.reason, .cancelled)
    }
}

enum R09ResidualTestProviderError: Error {
    case failed
}
