import Foundation
import XCTest
@testable import Mirmir

final class R13ResourceGovernanceTests: XCTestCase {
    func testDeterministicAdmissionAndExactlyOnceRelease() async throws {
        let request = try makeRequest()
        let firstGovernor = R13ResourceGovernor(
            policy: try makePolicy(),
            probes: nominalProbes()
        )
        let secondGovernor = R13ResourceGovernor(
            policy: try makePolicy(),
            probes: nominalProbes()
        )

        let firstLease = try admitted(await firstGovernor.admit(request))
        let secondLease = try admitted(await secondGovernor.admit(request))
        XCTAssertEqual(firstLease.leaseIdentity, secondLease.leaseIdentity)
        XCTAssertEqual(firstLease.admissionOrdinal, 0)
        XCTAssertFalse(firstLease.isReleased)

        let active = await firstGovernor.snapshot()
        XCTAssertEqual(active.activeLeaseIdentities, [firstLease.leaseIdentity])
        XCTAssertEqual(active.reservedDiskBytes, 200)
        XCTAssertEqual(active.reservedMemoryBytes, 100)

        let firstRelease = await firstGovernor.release(firstLease)
        let secondRelease = await firstGovernor.release(firstLease)
        XCTAssertEqual(
            firstRelease,
            .released(leaseIdentity: firstLease.leaseIdentity)
        )
        XCTAssertEqual(
            secondRelease,
            .alreadyReleased(leaseIdentity: firstLease.leaseIdentity)
        )
        XCTAssertTrue(firstLease.isReleased)

        let released = await firstGovernor.snapshot()
        XCTAssertTrue(released.activeLeaseIdentities.isEmpty)
        XCTAssertEqual(released.reservedDiskBytes, 0)
        XCTAssertEqual(released.reservedMemoryBytes, 0)

        let readmitted = try admitted(await firstGovernor.admit(request))
        XCTAssertEqual(readmitted.admissionOrdinal, 1)
        XCTAssertNotEqual(readmitted.leaseIdentity, firstLease.leaseIdentity)
    }

    func testDiskMemoryThermalAndConcurrencyRejectionsAreTyped() async throws {
        let request = try makeRequest()

        let diskGovernor = R13ResourceGovernor(
            policy: try makePolicy(),
            probes: probes(disk: 1_199, memory: 2_000, thermal: .nominal)
        )
        let diskOutcome = await diskGovernor.admit(request)
        XCTAssertEqual(
            rejected(diskOutcome),
            .insufficientDisk(
                requiredBytes: 200,
                availableBytes: 1_199,
                reservedBytes: 0,
                minimumFreeBytes: 1_000
            )
        )

        let memoryGovernor = R13ResourceGovernor(
            policy: try makePolicy(),
            probes: probes(disk: 2_000, memory: 599, thermal: .nominal)
        )
        let memoryOutcome = await memoryGovernor.admit(request)
        XCTAssertEqual(
            rejected(memoryOutcome),
            .insufficientMemory(
                requiredBytes: 100,
                availableBytes: 599,
                reservedBytes: 0,
                minimumFreeBytes: 500
            )
        )

        let thermalGovernor = R13ResourceGovernor(
            policy: try makePolicy(),
            probes: probes(disk: 2_000, memory: 2_000, thermal: .serious)
        )
        let thermalOutcome = await thermalGovernor.admit(request)
        XCTAssertEqual(
            rejected(thermalOutcome),
            .thermalLimitExceeded(observed: .serious, maximum: .fair)
        )

        let concurrencyGovernor = R13ResourceGovernor(
            policy: try makePolicy(maximumConcurrentJobs: 1),
            probes: nominalProbes()
        )
        _ = try admitted(await concurrencyGovernor.admit(request))
        let second = try R13ResourceRequest(
            jobIdentity: "job.second",
            requiredDiskBytes: 1,
            requiredMemoryBytes: 1
        )
        let concurrencyOutcome = await concurrencyGovernor.admit(second)
        XCTAssertEqual(
            rejected(concurrencyOutcome),
            .concurrencyLimitReached(limit: 1)
        )
    }

    func testEachProbeFailureReportsItsExactProbeKindWithoutAdmission() async throws {
        let request = try makeRequest()
        let cases: [(R13ResourceProbeKind, R13ResourceProbes)] = [
            (
                .disk,
                R13ResourceProbes(
                    availableDiskBytes: { throw ProbeFailure() },
                    availableMemoryBytes: { 2_000 },
                    thermalCondition: { .nominal }
                )
            ),
            (
                .memory,
                R13ResourceProbes(
                    availableDiskBytes: { 2_000 },
                    availableMemoryBytes: { throw ProbeFailure() },
                    thermalCondition: { .nominal }
                )
            ),
            (
                .thermal,
                R13ResourceProbes(
                    availableDiskBytes: { 2_000 },
                    availableMemoryBytes: { 2_000 },
                    thermalCondition: { throw ProbeFailure() }
                )
            )
        ]

        for (expected, probes) in cases {
            let governor = R13ResourceGovernor(
                policy: try makePolicy(),
                probes: probes
            )
            let outcome = await governor.admit(request)
            guard case .probeFailed(let observed) = outcome else {
                return XCTFail("Expected typed probe failure")
            }
            XCTAssertEqual(observed, expected)
            let snapshot = await governor.snapshot()
            XCTAssertTrue(snapshot.activeLeaseIdentities.isEmpty)
            XCTAssertEqual(snapshot.nextAdmissionOrdinal, 0)
        }
    }

    func testDuplicateActiveJobAndOverflowFailWithoutStateMutation() async throws {
        let request = try makeRequest()
        let governor = R13ResourceGovernor(
            policy: try makePolicy(),
            probes: nominalProbes()
        )
        _ = try admitted(await governor.admit(request))
        let duplicateOutcome = await governor.admit(request)
        XCTAssertEqual(
            rejected(duplicateOutcome),
            .duplicateActiveJob(request.jobIdentity)
        )

        let overflowGovernor = R13ResourceGovernor(
            policy: try makePolicy(),
            probes: probes(
                disk: UInt64.max,
                memory: UInt64.max,
                thermal: .nominal
            )
        )
        let overflow = try R13ResourceRequest(
            jobIdentity: "job.overflow",
            requiredDiskBytes: UInt64.max,
            requiredMemoryBytes: 1
        )
        let overflowOutcome = await overflowGovernor.admit(overflow)
        XCTAssertEqual(
            rejected(overflowOutcome),
            .resourceArithmeticOverflow
        )
        let snapshot = await overflowGovernor.snapshot()
        XCTAssertTrue(snapshot.activeLeaseIdentities.isEmpty)
        XCTAssertEqual(snapshot.nextAdmissionOrdinal, 0)
    }

    func testDurableCacheConsumptionReducesOnlyOutstandingDiskReservation()
        async throws {
        let disk = R13MutableDiskCapacity(1_200)
        let governor = R13ResourceGovernor(
            policy: try makePolicy(),
            probes: R13ResourceProbes(
                availableDiskBytes: { disk.value },
                availableMemoryBytes: { 2_000 },
                thermalCondition: { .nominal }
            )
        )
        let lease = try admitted(await governor.admit(makeRequest()))

        disk.value = 1_100
        guard case .rejected(.insufficientDisk) =
                await governor.recheck(lease) else {
            return XCTFail(
                "Physical cache growth must reject until its reservation "
                    + "is marked consumed."
            )
        }

        let firstConsumption = await governor.consumeDiskReservation(
            lease,
            bytes: 100
        )
        XCTAssertEqual(
            firstConsumption,
            .consumed(remainingDiskBytes: 100)
        )
        guard case .accepted(let observation) =
                await governor.recheck(lease) else {
            return XCTFail(
                "A durable cache write must no longer be double-counted."
            )
        }
        XCTAssertEqual(observation.availableDiskBytes, 1_100)
        let excessiveConsumption = await governor.consumeDiskReservation(
            lease,
            bytes: 101
        )
        XCTAssertEqual(
            excessiveConsumption,
            .exceedsReservation(requestedBytes: 101, remainingBytes: 100)
        )
        let partiallyConsumed = await governor.snapshot()
        XCTAssertEqual(partiallyConsumed.reservedDiskBytes, 100)

        let release = await governor.release(lease)
        XCTAssertEqual(
            release,
            .released(leaseIdentity: lease.leaseIdentity)
        )
        let released = await governor.snapshot()
        XCTAssertEqual(released.reservedDiskBytes, 0)
    }

    func testRecheckDoesNotDoubleCountCurrentWorkingMemoryReservation()
        async throws {
        let memory = R13MutableMemoryCapacity(600)
        let governor = R13ResourceGovernor(
            policy: try makePolicy(maximumConcurrentJobs: 1),
            probes: R13ResourceProbes(
                availableDiskBytes: { 2_000 },
                availableMemoryBytes: { memory.value },
                thermalCondition: { .nominal }
            )
        )
        let lease = try admitted(await governor.admit(makeRequest()))

        memory.value = 500
        guard case .accepted(let observation) =
                await governor.recheck(lease) else {
            return XCTFail(
                "Live free memory already reflects the current job's "
                    + "allocated working set."
            )
        }
        XCTAssertEqual(observation.availableMemoryBytes, 500)

        memory.value = 499
        guard case .rejected(
            .insufficientMemory(
                requiredBytes: 100,
                availableBytes: 499,
                reservedBytes: 0,
                minimumFreeBytes: 500
            )
        ) = await governor.recheck(lease) else {
            return XCTFail(
                "Recheck must still enforce the free-memory floor."
            )
        }
    }

    func testLiveDiskGrowthAllowanceRemainsReservedAtFreeFloor()
        async throws {
        let disk = R13MutableDiskCapacity(1_200)
        let governor = R13ResourceGovernor(
            policy: try makePolicy(maximumConcurrentJobs: 2),
            probes: R13ResourceProbes(
                availableDiskBytes: { disk.value },
                availableMemoryBytes: { 2_000 },
                thermalCondition: { .nominal }
            )
        )
        let request = try R13ResourceRequest(
            jobIdentity: "job.shared.volume",
            requiredDiskBytes: 200,
            liveDiskGrowthAllowanceBytes: 100,
            requiredMemoryBytes: 100
        )
        let lease = try admitted(await governor.admit(request))

        disk.value = 1_100
        guard case .accepted = await governor.recheck(lease) else {
            return XCTFail(
                "Observed output growth within its allowance must not be "
                    + "double-counted for the owning lease."
            )
        }
        let competingRequest = try R13ResourceRequest(
            jobIdentity: "job.competing",
            requiredDiskBytes: 1,
            requiredMemoryBytes: 1
        )
        let competingAdmission = await governor.admit(competingRequest)
        XCTAssertEqual(
            rejected(competingAdmission),
            .insufficientDisk(
                requiredBytes: 1,
                availableBytes: 1_100,
                reservedBytes: 200,
                minimumFreeBytes: 1_000
            )
        )

        disk.value = 1_000
        let cacheConsumption = await governor.consumeDiskReservation(
            lease,
            bytes: 100
        )
        XCTAssertEqual(
            cacheConsumption,
            .consumed(remainingDiskBytes: 100)
        )
        guard case .accepted = await governor.recheck(lease) else {
            return XCTFail(
                "Tracked cache growth must remain admissible at the exact "
                    + "minimum-free boundary."
            )
        }
        let excessiveConsumption = await governor.consumeDiskReservation(
            lease,
            bytes: 1
        )
        XCTAssertEqual(
            excessiveConsumption,
            .exceedsReservation(requestedBytes: 1, remainingBytes: 0)
        )

        disk.value = 999
        guard case .rejected(
            .insufficientDisk(
                requiredBytes: 0,
                availableBytes: 999,
                reservedBytes: 0,
                minimumFreeBytes: 1_000
            )
        ) = await governor.recheck(lease) else {
            return XCTFail(
                "Unreserved growth beyond the allowance must cross the "
                    + "minimum-free floor with a typed rejection."
            )
        }
    }
}

private struct ProbeFailure: Error {}

private final class R13MutableDiskCapacity: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: UInt64

    init(_ value: UInt64) {
        storedValue = value
    }

    var value: UInt64 {
        get {
            lock.withLock { storedValue }
        }
        set {
            lock.withLock { storedValue = newValue }
        }
    }
}

private final class R13MutableMemoryCapacity: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: UInt64

    init(_ value: UInt64) {
        storedValue = value
    }

    var value: UInt64 {
        get {
            lock.withLock { storedValue }
        }
        set {
            lock.withLock { storedValue = newValue }
        }
    }
}

private extension R13ResourceGovernanceTests {
    func makePolicy(
        maximumConcurrentJobs: Int = 2
    ) throws -> R13ResourcePolicy {
        try R13ResourcePolicy(
            policySHA256: String(repeating: "a", count: 64),
            minimumFreeDiskBytes: 1_000,
            minimumFreeMemoryBytes: 500,
            maximumThermalCondition: .fair,
            maximumConcurrentJobs: maximumConcurrentJobs
        )
    }

    func makeRequest() throws -> R13ResourceRequest {
        try R13ResourceRequest(
            jobIdentity: "job.release.001",
            requiredDiskBytes: 200,
            requiredMemoryBytes: 100
        )
    }

    func nominalProbes() -> R13ResourceProbes {
        probes(disk: 2_000, memory: 2_000, thermal: .nominal)
    }

    func probes(
        disk: UInt64,
        memory: UInt64,
        thermal: R13ThermalCondition
    ) -> R13ResourceProbes {
        R13ResourceProbes(
            availableDiskBytes: { disk },
            availableMemoryBytes: { memory },
            thermalCondition: { thermal }
        )
    }

    func admitted(
        _ outcome: R13ResourceAdmissionOutcome,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> R13ResourceLease {
        guard case .admitted(let lease) = outcome else {
            XCTFail("Expected resource admission", file: file, line: line)
            throw UnexpectedOutcome()
        }
        return lease
    }

    func rejected(
        _ outcome: R13ResourceAdmissionOutcome,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> R13ResourceRejection? {
        guard case .rejected(let rejection) = outcome else {
            XCTFail("Expected resource rejection", file: file, line: line)
            return nil
        }
        return rejection
    }
}

extension R13ResourceGovernanceTests {
    func testWorkingMemoryReservationTracksBackendOutputPoolCapacity()
        throws {
        XCTAssertEqual(
            R03DeterministicBackend.outputPoolCapacity,
            16
        )
        let source = VideoResolution.p1080
        let target = VideoResolution.p2160
        let sourceBytes = try R13NV12Frame.expectedPlaneByteCounts(
            width: source.width,
            height: source.height
        ).total
        let targetBytes = try R13NV12Frame.expectedPlaneByteCounts(
            width: target.width,
            height: target.height
        ).total
        let expected = UInt64(sourceBytes + targetBytes)
            * UInt64(R03DeterministicBackend.outputPoolCapacity)
            + 67_108_864

        XCTAssertEqual(
            try R13ReleaseHardeningRuntime.requiredWorkingMemoryBytes(
                source: source,
                target: target
            ),
            expected
        )
    }
}

private struct UnexpectedOutcome: Error {}
