import Metal
import XCTest
@testable import Mirmir

final class ASHMetalFrameResourceRingV3Tests: XCTestCase {
    func testDefaultRingAppliesFIFOBackpressureAtThreeInFlightFrames() async throws {
        let ring = try ASHMetalFrameResourceRingV3()
        let first = try await ring.acquire()
        let second = try await ring.acquire()
        let third = try await ring.acquire()
        XCTAssertEqual(
            [first.slot.index, second.slot.index, third.slot.index],
            [0, 1, 2]
        )
        XCTAssertEqual(
            ring.snapshot(),
            ASHMetalFrameResourceRingSnapshotV3(
                capacity: 3,
                availableSlotCount: 0,
                inFlightSlotCount: 3,
                waitingTaskCount: 0,
                peakInFlightSlotCount: 3,
                acquisitionCount: 3,
                releaseCount: 0
            )
        )

        let waiting = Task { try await ring.acquire() }
        try await waitUntil { ring.snapshot().waitingTaskCount == 1 }
        ring.release(second)
        let resumed = try await waiting.value
        XCTAssertEqual(resumed.slot.index, second.slot.index)

        ring.release(first)
        ring.release(third)
        ring.release(resumed)
        let final = ring.snapshot()
        XCTAssertEqual(final.availableSlotCount, 3)
        XCTAssertEqual(final.inFlightSlotCount, 0)
        XCTAssertEqual(final.acquisitionCount, 4)
        XCTAssertEqual(final.releaseCount, 4)
    }

    func testCancellationRemovesAWaitingAcquireWithoutConsumingASlot() async throws {
        let ring = try ASHMetalFrameResourceRingV3(capacity: 1)
        let held = try await ring.acquire()
        let waiting = Task { try await ring.acquire() }
        try await waitUntil { ring.snapshot().waitingTaskCount == 1 }

        waiting.cancel()
        do {
            _ = try await waiting.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertEqual(ring.snapshot().waitingTaskCount, 0)
        XCTAssertEqual(ring.snapshot().inFlightSlotCount, 1)

        ring.release(held)
        XCTAssertEqual(ring.snapshot().availableSlotCount, 1)
    }

    func testSlotRetainsFrameResourcesUntilReleaseAndReusesBuffers() async throws {
        let ring = try ASHMetalFrameResourceRingV3(capacity: 1)
        let slot = try await ring.acquire()
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let first = try slot.slot.reusableBuffer(
            kind: .stateSamples,
            minimumLength: 64,
            device: device
        )
        let second = try slot.slot.reusableBuffer(
            kind: .stateSamples,
            minimumLength: 32,
            device: device
        )
        XCTAssertTrue(first === second)

        var resource: LifetimeProbe? = LifetimeProbe()
        weak let weakResource = resource
        slot.slot.retainFrameResources([try XCTUnwrap(resource)])
        resource = nil
        XCTAssertNotNil(weakResource)
        XCTAssertEqual(slot.slot.retainedFrameResourceCount, 1)

        ring.release(slot)
        XCTAssertNil(weakResource)
        XCTAssertEqual(slot.slot.retainedFrameResourceCount, 0)
    }

    func testStaleAndDoubleReleaseCannotRecycleASuccessorLease() async throws {
        let ring = try ASHMetalFrameResourceRingV3(capacity: 1)
        let stale = try await ring.acquire()
        ring.release(stale)
        ring.release(stale)

        let successor = try await ring.acquire()
        var resource: LifetimeProbe? = LifetimeProbe()
        weak let weakResource = resource
        successor.slot.retainFrameResources([try XCTUnwrap(resource)])
        resource = nil

        ring.release(stale)
        XCTAssertNotNil(weakResource)
        XCTAssertEqual(successor.slot.retainedFrameResourceCount, 1)
        XCTAssertEqual(ring.snapshot().inFlightSlotCount, 1)
        XCTAssertEqual(ring.snapshot().releaseCount, 1)

        ring.release(successor)
        XCTAssertNil(weakResource)
        XCTAssertEqual(ring.snapshot().inFlightSlotCount, 0)
        XCTAssertEqual(ring.snapshot().releaseCount, 2)
    }

    func testRejectsCapacitiesOutsideTheDeclaredBound() {
        XCTAssertThrowsError(try ASHMetalFrameResourceRingV3(capacity: 0))
        XCTAssertThrowsError(try ASHMetalFrameResourceRingV3(capacity: 4))
    }

    private func waitUntil(
        _ predicate: @escaping @Sendable () -> Bool
    ) async throws {
        for _ in 0..<1_000 {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("Condition was not reached before the bounded yield limit")
    }
}

private final class LifetimeProbe {}
