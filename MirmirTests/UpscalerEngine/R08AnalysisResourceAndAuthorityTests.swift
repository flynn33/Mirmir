import XCTest
@testable import Mirmir

final class R08AnalysisResourceBudgetTests: XCTestCase {
    func testExactMemoryAndLatencyBudgetBoundariesAreAccepted() async throws {
        let measurement = try R08AnalysisResourceMeasurement(
            workingSetBytes: R08AnalysisBudgets.functionalMemoryBytes,
            elapsedMicroseconds: R08AnalysisBudgets.functionalLatencyMicroseconds
        )
        let service = try R08DeterministicAnalysisService(resourceMeasurement: measurement)
        let result = try R08TestSupport.analyzed(
            try await service.analyze(try R08TestSupport.request())
        )

        XCTAssertEqual(result.resourceUsage.memoryBytes, 67_108_864)
        XCTAssertEqual(result.resourceUsage.latencyMicroseconds, 20_000)
        let snapshot = await service.snapshot()
        XCTAssertEqual(snapshot.analyzedCount, 1)
        XCTAssertEqual(snapshot.lastFrameOrdinal, 12)
    }

    func testMemoryOneByteOverFrozenBudgetBypassesWithoutCommit() async throws {
        let measurement = try R08AnalysisResourceMeasurement(
            workingSetBytes: R08AnalysisBudgets.functionalMemoryBytes + 1,
            elapsedMicroseconds: R08AnalysisBudgets.functionalLatencyMicroseconds
        )
        let service = try R08DeterministicAnalysisService(resourceMeasurement: measurement)
        let bypass = try R08TestSupport.bypass(
            try await service.analyze(try R08TestSupport.request())
        )

        XCTAssertEqual(
            bypass.reason,
            .memoryBudgetExceeded(required: 67_108_865, limit: 67_108_864)
        )
        assertNoCommit(await service.snapshot())
    }

    func testLatencyOneMillisecondOverFrozenBudgetBypassesWithoutCommit() async throws {
        let measurement = try R08AnalysisResourceMeasurement(
            workingSetBytes: R08AnalysisBudgets.functionalMemoryBytes,
            elapsedMicroseconds: R08AnalysisBudgets.functionalLatencyMicroseconds + 1_000
        )
        let service = try R08DeterministicAnalysisService(resourceMeasurement: measurement)
        let bypass = try R08TestSupport.bypass(
            try await service.analyze(try R08TestSupport.request())
        )

        XCTAssertEqual(
            bypass.reason,
            .latencyBudgetExceeded(required: 21_000, limit: 20_000)
        )
        assertNoCommit(await service.snapshot())
    }
}

final class R08ForbiddenOutputServiceTests: XCTestCase {
    func testForbiddenPixelAndBackendOutputsUseTypedNoCommitFallbacks() async throws {
        let cases: [(R08AnalysisContractError, R08AnalysisBypassReason)] = [
            (
                .forbiddenPixelOutput("pixel_frame"),
                .pixelOutputForbidden("pixel_frame")
            ),
            (
                .forbiddenPixelOutput("pixel_residual"),
                .pixelOutputForbidden("pixel_residual")
            ),
            (
                .forbiddenModelDecisionAuthority("selected_backend_id"),
                .modelDecisionAuthorityForbidden("selected_backend_id")
            )
        ]

        for (error, expectedReason) in cases {
            let service = try R08DeterministicAnalysisService(
                analysisHeadProvider: { _ in throw error }
            )
            let bypass = try R08TestSupport.bypass(
                try await service.analyze(try R08TestSupport.request())
            )
            XCTAssertEqual(bypass.reason, expectedReason)
            XCTAssertEqual(bypass.pixelAuthority, .analysisOnlyNoPixelOutput)

            let snapshot = await service.snapshot()
            XCTAssertNil(snapshot.lastFrameOrdinal)
            XCTAssertTrue(snapshot.specializationKeysOldestFirst.isEmpty)
            XCTAssertEqual(snapshot.analyzedCount, 0)
        }
    }
}

final class R08InputTransferFallbackTests: XCTestCase {
    func testUnavailableZeroCopyCreatesOwnedCopyWithoutNativeExecutionClaim() throws {
        var source: [UInt8] = [3, 1, 4, 1, 5]
        let unavailable = try R08DeterministicInputCopy.make(
            sourceBytes: source,
            zeroCopyAttempt: .unavailable
        )
        let failed = try R08DeterministicInputCopy.make(
            sourceBytes: source,
            zeroCopyAttempt: .failed
        )

        source[0] = 9
        XCTAssertEqual(unavailable.bytes, [3, 1, 4, 1, 5])
        XCTAssertEqual(failed.bytes, [3, 1, 4, 1, 5])
        XCTAssertEqual(unavailable.transfer.disposition, .copiedDeterministicFallback)
        XCTAssertEqual(failed.transfer.disposition, .copiedDeterministicFallback)
        XCTAssertEqual(unavailable.nativeExecution, .notObserved)
        XCTAssertEqual(failed.nativeExecution, .notObserved)

        XCTAssertThrowsError(
            try R08DeterministicInputCopy.make(
                sourceBytes: source,
                zeroCopyAttempt: .succeeded
            )
        ) { error in
            XCTAssertEqual(error as? R08AnalysisContractError, .invalidInputTransferBinding)
        }
    }
}

private extension R08AnalysisResourceBudgetTests {
    func assertNoCommit(
        _ snapshot: R08AnalysisServiceSnapshot,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(snapshot.stateGeneration, 0, file: file, line: line)
        XCTAssertNil(snapshot.streamID, file: file, line: line)
        XCTAssertNil(snapshot.shotID, file: file, line: line)
        XCTAssertNil(snapshot.lastFrameOrdinal, file: file, line: line)
        XCTAssertTrue(snapshot.specializationKeysOldestFirst.isEmpty, file: file, line: line)
        XCTAssertEqual(snapshot.analyzedCount, 0, file: file, line: line)
        XCTAssertEqual(snapshot.specializationCount, 0, file: file, line: line)
        XCTAssertEqual(snapshot.cacheHitCount, 0, file: file, line: line)
    }
}
