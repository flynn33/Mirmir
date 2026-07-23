import CoreMedia
import CoreVideo
import XCTest
@testable import Mirmir

struct R09StageFixedService: R09CoreAIResidualService {
    let disposition: R09ResidualDisposition

    func predictResidual(for _: R09ResidualRequest) async -> R09ResidualDisposition {
        disposition
    }
}

enum R09ResidualTestingOutputFactory {
    static func output(
        requestIdentity: R09ResidualRequestIdentity,
        authorization: R09ResidualAuthorizationIdentity,
        scalerIdentity: R09AppleScalerIdentity,
        modelIdentity: R09ResidualModelIdentity,
        executionIdentity: R09ResidualExecutionIdentity,
        residual: R09PlanarResidualQ16,
        confidenceQ15: Int64,
        resourceMeasurement: R09ResidualResourceMeasurement
    ) throws -> R09ResidualOutput {
        try R09ResidualOutput(
            producerCapability: .testingOnly(),
            requestIdentity: requestIdentity,
            authorization: authorization,
            scalerIdentity: scalerIdentity,
            modelIdentity: modelIdentity,
            executionIdentity: executionIdentity,
            residual: residual,
            confidenceQ15: confidenceQ15,
            resourceMeasurement: resourceMeasurement
        )
    }
}

final class R09BoundedResidualStageTests: XCTestCase {
    func testServiceToStageAppliesBoundedResidualAndPreservesExactRollback() async throws {
        let fixture = try await R09StageTestSupport.fixture()
        guard case .applied(let applied) = await R09BoundedResidualStage().process(
            request: fixture.request,
            appleOnlyFrame: fixture.appleFrame,
            service: R09DeterministicResidualService()
        ) else {
            return XCTFail("Expected a fully validated residual application")
        }

        XCTAssertTrue(applied.appleOnlyFrame.pixelBuffer === fixture.appleFrame.pixelBuffer)
        XCTAssertTrue(applied.rollbackFrame.pixelBuffer === fixture.appleFrame.pixelBuffer)
        XCTAssertFalse(applied.correctedFrame.pixelBuffer === fixture.appleFrame.pixelBuffer)
        XCTAssertEqual(
            try R09StageTestSupport.activeBytes(fixture.appleFrame.pixelBuffer),
            fixture.originalBytes
        )
        XCTAssertEqual(
            try R09StageTestSupport.activeBytes(applied.correctedFrame.pixelBuffer),
            R09StagePixelBytes(
                luma: [UInt8](repeating: 122, count: 16),
                chroma: Array(repeating: [UInt8(128), UInt8(132)], count: 4)
                    .flatMap { $0 }
            )
        )
        for id in R09ResidualPlaneID.allCases {
            let expected = fixture.request.postScalerFrame[id].samplesQ16.map { $0 + 514 }
            XCTAssertEqual(applied.correctedPlanarFrame[id].samplesQ16, expected)
        }
        XCTAssertEqual(applied.receipt.requestIdentity, fixture.request.identity)
        XCTAssertEqual(applied.receipt.authorization, fixture.request.authorization)
        XCTAssertEqual(applied.receipt.limits, fixture.request.limits)
        XCTAssertEqual(applied.receipt.confidenceBudget, fixture.request.confidenceBudget)
        XCTAssertEqual(applied.receipt.resourceBudget, fixture.request.resourceBudget)
        XCTAssertEqual(applied.receipt.safetySignal, fixture.request.safetySignal)
        XCTAssertEqual(applied.receipt.providerConfidenceQ15, 24_576)
        XCTAssertEqual(
            applied.receipt.resourceMeasurement,
            try R09ResidualResourceMeasurement(
                workingSetBytes: 4_096,
                elapsedMicroseconds: 1_000
            )
        )
        XCTAssertEqual(applied.receipt.appliedSampleCount, 24)
        XCTAssertTrue(applied.receipt.appleOnlyRollbackPreserved)
        XCTAssertEqual(
            applied.correctedFrame.presentationTimestamp,
            fixture.appleFrame.presentationTimestamp
        )
        XCTAssertEqual(applied.correctedFrame.duration, fixture.appleFrame.duration)
        XCTAssertEqual(applied.correctedFrame.colorDescription, fixture.appleFrame.colorDescription)
        XCTAssertEqual(applied.correctedFrame.metadataIdentity, fixture.appleFrame.metadataIdentity)
        XCTAssertEqual(applied.correctedFrame.processingIdentity, fixture.appleFrame.processingIdentity)
        XCTAssertEqual(
            CVBufferCopyAttachment(
                applied.correctedFrame.pixelBuffer,
                kCVImageBufferColorPrimariesKey,
                nil
            ) as? String,
            kCVImageBufferColorPrimaries_ITU_R_709_2 as String
        )

        let gate = R09ResidualTestGate()
        let suspendedOutput = try R09StageTestSupport.output(
            request: fixture.request,
            luma: [257] + [Int64](repeating: 0, count: 15)
        )
        let serialStage = R09BoundedResidualStage()
        let suspendingService = R09StageSuspendingService(
            gate: gate,
            disposition: .produced(suspendedOutput)
        )
        let firstTransaction = Task {
            await serialStage.process(
                request: fixture.request,
                appleOnlyFrame: fixture.appleFrame,
                service: suspendingService
            )
        }
        await gate.waitUntilEntered()
        let busy = try R09StageTestSupport.bypass(
            await serialStage.process(
                request: fixture.request,
                appleOnlyFrame: fixture.appleFrame,
                service: R09DeterministicResidualService()
            )
        )
        XCTAssertEqual(busy.reason, .transactionBusy)
        XCTAssertTrue(busy.appleOnlyFrame.pixelBuffer === fixture.appleFrame.pixelBuffer)
        firstTransaction.cancel()
        await gate.release()
        let cancelled = try R09StageTestSupport.bypass(await firstTransaction.value)
        XCTAssertEqual(cancelled.reason, .proposalService(.cancelled))
        XCTAssertTrue(cancelled.appleOnlyFrame.pixelBuffer === fixture.appleFrame.pixelBuffer)
    }

    func testProtectedSampleRejectsWholeProposalWithoutPartialPixelApplication() async throws {
        let fixture = try await R09StageTestSupport.fixture(protectedLumaIndices: [1])
        var luma = [Int64](repeating: 0, count: 16)
        luma[0] = 257
        luma[1] = 257
        let output = try R09StageTestSupport.output(
            request: fixture.request,
            luma: luma
        )

        let bypass = try R09StageTestSupport.bypass(
            await R09BoundedResidualStage().process(
                request: fixture.request,
                appleOnlyFrame: fixture.appleFrame,
                service: R09StageFixedService(disposition: .produced(output))
            )
        )

        XCTAssertEqual(bypass.reason, .protectedSample(plane: .luma, index: 1))
        XCTAssertEqual(bypass.fallbackRoute, .appleScalerOutputUnmodified)
        XCTAssertTrue(bypass.appleOnlyFrame.pixelBuffer === fixture.appleFrame.pixelBuffer)
        XCTAssertEqual(
            try R09StageTestSupport.activeBytes(bypass.appleOnlyFrame.pixelBuffer),
            fixture.originalBytes
        )

    }

    func testStageIndependentlyRejectsConfidenceResourceAndHallucinationFailures() async throws {
        let fixture = try await R09StageTestSupport.fixture()
        let residual = try R09StageTestSupport.output(
            request: fixture.request,
            luma: [257] + [Int64](repeating: 0, count: 15)
        ).residual

        let lowConfidence = try R09StageTestSupport.output(
            request: fixture.request,
            residual: residual,
            confidenceQ15: fixture.request.confidenceBudget.minimumRequiredQ15 - 1
        )
        let lowConfidenceReason = try await R09StageTestSupport.bypassReason(
            output: lowConfidence,
            fixture: fixture
        )
        XCTAssertEqual(
            lowConfidenceReason,
            .proposalConfidenceBelowMinimum(
                minimumQ15: fixture.request.confidenceBudget.minimumRequiredQ15,
                actualQ15: fixture.request.confidenceBudget.minimumRequiredQ15 - 1
            )
        )

        let overBudget = try R09StageTestSupport.output(
            request: fixture.request,
            residual: residual,
            workingSetBytes: fixture.request.resourceBudget.maximumWorkingSetBytes + 1
        )
        let overBudgetReason = try await R09StageTestSupport.bypassReason(
            output: overBudget,
            fixture: fixture
        )
        XCTAssertEqual(
            overBudgetReason,
            .proposalResourceBudgetExceeded(
                role: .workingSetBytes,
                maximum: fixture.request.resourceBudget.maximumWorkingSetBytes,
                actual: fixture.request.resourceBudget.maximumWorkingSetBytes + 1
            )
        )

        let unsafeFixture = try await R09StageTestSupport.fixture(
            hallucinationRiskQ15: 20_000,
            maximumAllowedHallucinationRiskQ15: 16_384
        )
        let unsafeOutput = try R09StageTestSupport.output(
            request: unsafeFixture.request,
            luma: [257] + [Int64](repeating: 0, count: 15)
        )
        let unsafeReason = try await R09StageTestSupport.bypassReason(
            output: unsafeOutput,
            fixture: unsafeFixture
        )
        XCTAssertEqual(
            unsafeReason,
            .hallucinationRiskExceeded(maximumAllowedQ15: 16_384, actualQ15: 20_000)
        )

        let lowApprovalFixture = try await R09StageTestSupport.fixture(ashApprovalQ15: 1)
        let overApprovedOutput = try R09StageTestSupport.output(
            request: lowApprovalFixture.request,
            luma: [257] + [Int64](repeating: 0, count: 15)
        )
        let overApprovedReason = try await R09StageTestSupport.bypassReason(
            output: overApprovedOutput,
            fixture: lowApprovalFixture
        )
        XCTAssertEqual(
            overApprovedReason,
            .residualLimitExceeded(plane: .luma, index: 0)
        )
    }

    func testExecutionAndAppleFrameIdentityMismatchesReturnOriginalFrame() async throws {
        let fixture = try await R09StageTestSupport.fixture()
        let residual = try R09StageTestSupport.output(
            request: fixture.request,
            luma: [257] + [Int64](repeating: 0, count: 15)
        ).residual
        let mismatchedExecution = try R09ResidualExecutionIdentity(
            runtimeID: "r09.different-runtime",
            modelContentSHA256: R09ResidualModelIdentity.deterministicProviderSHA256,
            ioContractSHA256: R09ResidualRequestIdentity.ioContractSHA256,
            mode: .deterministicFixtureSimulation,
            nativeExecution: .notObserved
        )
        let mismatchedOutput = try R09StageTestSupport.output(
            request: fixture.request,
            residual: residual,
            executionIdentity: mismatchedExecution
        )
        let mismatchedReason = try await R09StageTestSupport.bypassReason(
            output: mismatchedOutput,
            fixture: fixture
        )
        XCTAssertEqual(
            mismatchedReason,
            .proposalIdentityMismatch
        )

        let wrongFrame = try R09StageTestSupport.appleFrame(
            pixelBuffer: fixture.appleFrame.pixelBuffer,
            frameID: "r09.frame.other",
            processingIdentity: fixture.appleFrame.processingIdentity
        )
        let validOutput = try R09StageTestSupport.output(
            request: fixture.request,
            residual: residual
        )
        let bypass = try R09StageTestSupport.bypass(
            await R09BoundedResidualStage().process(
                request: fixture.request,
                appleOnlyFrame: wrongFrame,
                service: R09StageFixedService(disposition: .produced(validOutput))
            )
        )
        XCTAssertEqual(bypass.reason, .appleScalerFrameMismatch)
        XCTAssertTrue(bypass.appleOnlyFrame.pixelBuffer === fixture.appleFrame.pixelBuffer)
        XCTAssertEqual(
            try R09StageTestSupport.activeBytes(bypass.appleOnlyFrame.pixelBuffer),
            fixture.originalBytes
        )

        let wrongRouteFrame = try R09StageTestSupport.appleFrame(
            pixelBuffer: fixture.appleFrame.pixelBuffer,
            frameID: fixture.request.identity.frameID,
            processingIdentity: R09StageTestSupport.processingIdentity(
                configurationIdentity: "r09.fixture.other-configuration"
            )
        )
        let routeBypass = try R09StageTestSupport.bypass(
            await R09BoundedResidualStage().process(
                request: fixture.request,
                appleOnlyFrame: wrongRouteFrame,
                service: R09StageFixedService(disposition: .produced(validOutput))
            )
        )
        XCTAssertEqual(routeBypass.reason, .appleScalerIdentityMismatch)
        XCTAssertTrue(routeBypass.appleOnlyFrame.pixelBuffer === fixture.appleFrame.pixelBuffer)
    }

    func testNV12CodecRoundTripsActiveSamplesAndRejectsUnsupportedFormat() async throws {
        let fixture = try await R09StageTestSupport.fixture()
        let decoded = try R09NV12PlanarCodec.decode(fixture.appleFrame.pixelBuffer)
        XCTAssertEqual(decoded, fixture.request.postScalerFrame)

        let encoded = try R09NV12PlanarCodec.encode(
            decoded,
            matching: fixture.appleFrame.pixelBuffer
        )
        XCTAssertEqual(
            try R09StageTestSupport.activeBytes(encoded),
            fixture.originalBytes
        )
        XCTAssertEqual(
            CVBufferCopyAttachment(encoded, kCVImageBufferColorPrimariesKey, nil) as? String,
            kCVImageBufferColorPrimaries_ITU_R_709_2 as String
        )

        let subByteOutput = try R09StageTestSupport.output(
            request: fixture.request,
            luma: [1] + [Int64](repeating: 0, count: 15)
        )
        let subByteReason = try await R09StageTestSupport.bypassReason(
            output: subByteOutput,
            fixture: fixture
        )
        XCTAssertEqual(
            subByteReason,
            .codec(
                .sampleNotExactlyRepresentable(
                    plane: .luma,
                    index: 0,
                    expectedQ16: decoded.luma.samplesQ16[0] + 1,
                    materializedQ16: decoded.luma.samplesQ16[0]
                )
            )
        )
        XCTAssertEqual(
            try R09StageTestSupport.activeBytes(fixture.appleFrame.pixelBuffer),
            fixture.originalBytes
        )

        var bgra: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            4,
            4,
            kCVPixelFormatType_32BGRA,
            nil,
            &bgra
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        let unsupported = try XCTUnwrap(bgra)
        XCTAssertThrowsError(try R09NV12PlanarCodec.decode(unsupported)) { error in
            XCTAssertEqual(
                error as? R09NV12PlanarCodecError,
                .unsupportedPixelFormat(kCVPixelFormatType_32BGRA)
            )
        }
    }
}
