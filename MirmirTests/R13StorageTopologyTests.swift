import Foundation
import XCTest
@testable import Mirmir

final class R13StorageTopologyTests: XCTestCase {
    func testFoundationProbeDetectsExistingDirectoriesOnSameVolume()
        throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let first = root.appendingPathComponent(
            "First",
            isDirectory: true
        )
        let second = root.appendingPathComponent(
            "Second",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: first,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: second,
            withIntermediateDirectories: true
        )

        XCTAssertTrue(
            try R13FoundationVolumeTopologyProbe().sharesVolume(
                first,
                second
            )
        )
    }

    func testSameVolumeRejectsIndependentCapacityAndRollsBack()
        async throws {
        let fixture = try R13HardeningFixture()
        defer { fixture.cleanup() }
        let plan = try capacityPlan(for: fixture)
        let available = plan.combinedBoundary - 1
        XCTAssertGreaterThanOrEqual(
            available,
            plan.distinctCacheBoundary
        )
        XCTAssertGreaterThanOrEqual(
            available,
            plan.distinctOutputAdmissionBoundary
        )
        let cacheProbe = R13CapacityProbe(capacity: available)
        let outputProbe = R13CapacityProbe(capacity: UInt64.max)
        let runtime = try fixture.makeRuntime(
            cacheProbe: cacheProbe,
            outputProbe: outputProbe,
            sameVolume: true
        )
        let identifier = "r13-shared-volume-rejection"

        do {
            _ = try await runtime.prepare(
                job: fixture.makeJob(identifier: identifier),
                source: fixture.sourceProfile,
                route: .scale3Over2,
                modeBinding: R13ReleaseModePolicy.binding(
                    for: .deterministic
                )
            )
            XCTFail("Combined same-volume capacity must be enforced.")
        } catch {
            XCTAssertEqual(
                error as? R13RestartJobError,
                .insufficientDiskSpace(
                    requiredBytes: plan.combinedBoundary,
                    availableBytes: available
                )
            )
        }

        XCTAssertEqual(cacheProbe.probedURLs, [fixture.jobsRoot])
        XCTAssertTrue(outputProbe.probedURLs.isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.jobDirectory(identifier: identifier).path
            )
        )
    }

    func testSameVolumeAcceptsExactCombinedBoundary() async throws {
        let fixture = try R13HardeningFixture()
        defer { fixture.cleanup() }
        let plan = try capacityPlan(for: fixture)
        let cacheProbe = R13CapacityProbe(
            capacity: plan.combinedBoundary
        )
        let outputProbe = R13CapacityProbe(capacity: UInt64.max)
        let runtime = try fixture.makeRuntime(
            cacheProbe: cacheProbe,
            outputProbe: outputProbe,
            sameVolume: true
        )

        let attempt = try await runtime.prepare(
            job: fixture.makeJob(identifier: "r13-shared-volume-boundary"),
            source: fixture.sourceProfile,
            route: .scale3Over2,
            modeBinding: R13ReleaseModePolicy.binding(
                for: .deterministic
            )
        )
        await attempt.releaseResources()

        XCTAssertEqual(cacheProbe.probedURLs, [fixture.jobsRoot])
        XCTAssertTrue(outputProbe.probedURLs.isEmpty)
    }

    func testSameVolumePreFinalizationRecheckAcceptsExactOutputBoundary()
        async throws {
        let fixture = try R13HardeningFixture()
        defer { fixture.cleanup() }
        let plan = try capacityPlan(for: fixture)
        let outputProbe = R13CapacityProbe(capacity: UInt64.max)
        let runtime = try fixture.makeRuntime(
            cacheProbe: R13CapacityProbe(
                capacity: plan.combinedBoundary
            ),
            outputProbe: outputProbe,
            sameVolume: true
        )
        let attempt = try await runtime.prepare(
            job: fixture.makeJob(
                identifier: "r13-shared-output-recheck-boundary"
            ),
            source: fixture.sourceProfile,
            route: .scale3Over2,
            modeBinding: R13ReleaseModePolicy.binding(
                for: .deterministic
            )
        )

        outputProbe.capacity = plan.distinctOutputLiveRecheckBoundary
        try await attempt.beforeOutputFinalize()
        await attempt.releaseResources()

        XCTAssertEqual(
            outputProbe.probedURLs,
            [fixture.outputDirectory]
        )
    }

    func testSameVolumePreFinalizationRecheckRejectsOneByteBelowOutputBoundary()
        async throws {
        let fixture = try R13HardeningFixture()
        defer { fixture.cleanup() }
        let plan = try capacityPlan(for: fixture)
        let outputProbe = R13CapacityProbe(capacity: UInt64.max)
        let runtime = try fixture.makeRuntime(
            cacheProbe: R13CapacityProbe(
                capacity: plan.combinedBoundary
            ),
            outputProbe: outputProbe,
            sameVolume: true
        )
        let attempt = try await runtime.prepare(
            job: fixture.makeJob(
                identifier: "r13-shared-output-recheck-floor"
            ),
            source: fixture.sourceProfile,
            route: .scale3Over2,
            modeBinding: R13ReleaseModePolicy.binding(
                for: .deterministic
            )
        )
        let available =
            plan.distinctOutputLiveRecheckBoundary - 1
        outputProbe.capacity = available

        do {
            try await attempt.beforeOutputFinalize()
            XCTFail(
                "Same-volume finalization must retain final-output capacity."
            )
        } catch {
            XCTAssertEqual(
                error as? R13RestartJobError,
                .insufficientDiskSpace(
                    requiredBytes:
                        plan.distinctOutputLiveRecheckBoundary,
                    availableBytes: available
                )
            )
        }
        await attempt.releaseResources()

        XCTAssertEqual(
            outputProbe.probedURLs,
            [fixture.outputDirectory]
        )
    }

    func testDistinctVolumesAcceptIndependentExactBoundaries()
        async throws {
        let fixture = try R13HardeningFixture()
        defer { fixture.cleanup() }
        let plan = try capacityPlan(for: fixture)
        XCTAssertLessThan(
            plan.distinctCacheBoundary,
            plan.combinedBoundary
        )
        let cacheProbe = R13CapacityProbe(
            capacity: plan.distinctCacheBoundary
        )
        let outputProbe = R13CapacityProbe(
            capacity: plan.distinctOutputAdmissionBoundary
        )
        let runtime = try fixture.makeRuntime(
            cacheProbe: cacheProbe,
            outputProbe: outputProbe,
            sameVolume: false
        )

        let attempt = try await runtime.prepare(
            job: fixture.makeJob(identifier: "r13-distinct-volume-boundary"),
            source: fixture.sourceProfile,
            route: .scale3Over2,
            modeBinding: R13ReleaseModePolicy.binding(
                for: .deterministic
            )
        )
        await attempt.releaseResources()

        XCTAssertEqual(cacheProbe.probedURLs, [fixture.jobsRoot])
        XCTAssertEqual(
            outputProbe.probedURLs,
            [fixture.outputDirectory]
        )
    }

    func testDistinctOutputVolumeRejectsOneByteBelowAdmissionBoundary()
        async throws {
        let fixture = try R13HardeningFixture()
        defer { fixture.cleanup() }
        let plan = try capacityPlan(for: fixture)
        let available = plan.distinctOutputAdmissionBoundary - 1
        let cacheProbe = R13CapacityProbe(capacity: UInt64.max)
        let outputProbe = R13CapacityProbe(capacity: available)
        let runtime = try fixture.makeRuntime(
            cacheProbe: cacheProbe,
            outputProbe: outputProbe,
            sameVolume: false
        )
        let identifier = "r13-distinct-output-admission-floor"

        do {
            _ = try await runtime.prepare(
                job: fixture.makeJob(identifier: identifier),
                source: fixture.sourceProfile,
                route: .scale3Over2,
                modeBinding: R13ReleaseModePolicy.binding(
                    for: .deterministic
                )
            )
            XCTFail("Distinct output admission must retain the disk floor.")
        } catch {
            XCTAssertEqual(
                error as? R13RestartJobError,
                .insufficientDiskSpace(
                    requiredBytes:
                        plan.distinctOutputAdmissionBoundary,
                    availableBytes: available
                )
            )
        }

        XCTAssertEqual(
            outputProbe.probedURLs,
            [fixture.outputDirectory]
        )
        XCTAssertTrue(cacheProbe.probedURLs.isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.jobDirectory(identifier: identifier).path
            )
        )
    }

    func testDistinctOutputLiveRecheckAcceptsExactBoundary()
        async throws {
        let fixture = try R13HardeningFixture()
        defer { fixture.cleanup() }
        let plan = try capacityPlan(for: fixture)
        let outputProbe = R13CapacityProbe(
            capacity: plan.distinctOutputAdmissionBoundary
        )
        let runtime = try fixture.makeRuntime(
            cacheProbe: R13CapacityProbe(capacity: UInt64.max),
            outputProbe: outputProbe,
            sameVolume: false
        )
        let attempt = try await runtime.prepare(
            job: fixture.makeJob(
                identifier: "r13-distinct-output-recheck-boundary"
            ),
            source: fixture.sourceProfile,
            route: .scale3Over2,
            modeBinding: R13ReleaseModePolicy.binding(
                for: .deterministic
            )
        )

        outputProbe.capacity = plan.distinctOutputLiveRecheckBoundary
        try await attempt.recheckResources()
        await attempt.releaseResources()

        XCTAssertEqual(
            outputProbe.probedURLs,
            [fixture.outputDirectory, fixture.outputDirectory]
        )
    }

    func testDistinctOutputLiveRecheckRejectsOneByteBelowBoundary()
        async throws {
        let fixture = try R13HardeningFixture()
        defer { fixture.cleanup() }
        let plan = try capacityPlan(for: fixture)
        let outputProbe = R13CapacityProbe(
            capacity: plan.distinctOutputAdmissionBoundary
        )
        let runtime = try fixture.makeRuntime(
            cacheProbe: R13CapacityProbe(capacity: UInt64.max),
            outputProbe: outputProbe,
            sameVolume: false
        )
        let attempt = try await runtime.prepare(
            job: fixture.makeJob(
                identifier: "r13-distinct-output-recheck-floor"
            ),
            source: fixture.sourceProfile,
            route: .scale3Over2,
            modeBinding: R13ReleaseModePolicy.binding(
                for: .deterministic
            )
        )
        let available =
            plan.distinctOutputLiveRecheckBoundary - 1
        outputProbe.capacity = available

        do {
            try await attempt.recheckResources()
            XCTFail("Distinct output recheck must retain the disk floor.")
        } catch {
            XCTAssertEqual(
                error as? R13RestartJobError,
                .insufficientDiskSpace(
                    requiredBytes:
                        plan.distinctOutputLiveRecheckBoundary,
                    availableBytes: available
                )
            )
        }
        await attempt.releaseResources()

        XCTAssertEqual(
            outputProbe.probedURLs,
            [fixture.outputDirectory, fixture.outputDirectory]
        )
    }
}

private extension R13StorageTopologyTests {
    struct CapacityPlan {
        let combinedBoundary: UInt64
        let distinctCacheBoundary: UInt64
        let distinctOutputAdmissionBoundary: UInt64
        let distinctOutputLiveRecheckBoundary: UInt64
    }

    func capacityPlan(
        for fixture: R13HardeningFixture
    ) throws -> CapacityPlan {
        let documents = try R13ReleaseHardeningDocuments.production()
        let job = fixture.makeJob(identifier: "r13-capacity-model")
        let sourceByteCount = UInt64(
            try Data(contentsOf: fixture.sourceURL).count
        )
        let expectedFinalOutputBytes =
            try R13ReleaseHardeningRuntime.expectedOutputBytes(
                source: fixture.sourceProfile,
                sourceByteCount: sourceByteCount,
                job: job
            )
        let expectedFinalizationPeakBytes =
            try R13ReleaseHardeningRuntime.expectedFinalizationPeakBytes(
                source: fixture.sourceProfile,
                sourceByteCount: sourceByteCount,
                job: job
            )
        let preflight = R13StoragePreflight(
            capacityProbe: R13CapacityProbe(capacity: UInt64.max)
        )
        let combinedReceipt = try preflight.evaluate(
            try request(
                expectedFinalOutputBytes: expectedFinalizationPeakBytes
            ),
            at: fixture.jobsRoot
        )
        let distinctReceipt = try preflight.evaluate(
            try request(expectedFinalOutputBytes: 1),
            at: fixture.jobsRoot
        )
        let minimumFreeDiskBytes =
            documents.resourcePolicy.minimumFreeDiskBytes
        let outputReserveBytes: UInt64 = 67_108_864
        let distinctOutputReservation = try checkedAdd(
            expectedFinalizationPeakBytes,
            outputReserveBytes
        )
        return CapacityPlan(
            combinedBoundary: try checkedAdd(
                combinedReceipt.requiredBytes,
                minimumFreeDiskBytes
            ),
            distinctCacheBoundary: try checkedAdd(
                distinctReceipt.requiredBytes,
                minimumFreeDiskBytes
            ),
            distinctOutputAdmissionBoundary: try checkedAdd(
                distinctOutputReservation,
                minimumFreeDiskBytes
            ),
            distinctOutputLiveRecheckBoundary: try checkedAdd(
                try checkedAdd(
                    expectedFinalOutputBytes,
                    outputReserveBytes
                ),
                minimumFreeDiskBytes
            )
        )
    }

    func request(
        expectedFinalOutputBytes: UInt64
    ) throws -> R13StoragePreflightRequest {
        try R13StoragePreflightRequest(
            outputWidth: VideoResolution.p1080.width,
            outputHeight: VideoResolution.p1080.height,
            totalFrameCount: 1,
            expectedFinalOutputBytes: expectedFinalOutputBytes,
            additionalReserveBytes: 67_108_864
        )
    }

    func checkedAdd(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else {
            throw CapacityPlanError.arithmeticOverflow
        }
        return sum
    }
}

private enum CapacityPlanError: Error {
    case arithmeticOverflow
}
