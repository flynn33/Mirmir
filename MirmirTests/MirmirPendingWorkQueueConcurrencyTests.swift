import Foundation
import XCTest
@testable import Mirmir

final class MirmirPendingWorkQueueConcurrencyTests: XCTestCase {
    func testHeadClaimIsIdempotentAndSerialAcrossRemoval() async throws {
        let directory = try makePendingQueueTemporaryDirectory()
        let queue = MirmirPendingWorkQueue(directoryURL: directory)

        let emptyClaim = try await queue.markStartedOrReturnHead()
        XCTAssertNil(emptyClaim.record)
        XCTAssertFalse(emptyClaim.didMarkStarted)

        _ = try await queue.enqueueMany([
            makePendingQueueRecord(id: "job-first", order: 0),
            makePendingQueueRecord(id: "job-second", order: 1),
            makePendingQueueRecord(id: "job-third", order: 2)
        ])
        let firstStart = Date(timeIntervalSinceReferenceDate: 500)
        let firstClaim = try await queue.markStartedOrReturnHead(
            startedAt: firstStart
        )
        XCTAssertEqual(firstClaim.record?.id, "job-first")
        XCTAssertEqual(firstClaim.record?.state, .started)
        XCTAssertEqual(firstClaim.record?.startedAt, firstStart)
        XCTAssertTrue(firstClaim.didMarkStarted)

        let repeatedClaim = try await queue.markStartedOrReturnHead(
            startedAt: Date(timeIntervalSinceReferenceDate: 900)
        )
        XCTAssertEqual(repeatedClaim.record, firstClaim.record)
        XCTAssertFalse(repeatedClaim.didMarkStarted)

        do {
            _ = try await queue.update(
                makePendingQueueRecord(id: "job-first", order: 0)
            )
            XCTFail("Started work was editable.")
        } catch {
            XCTAssertEqual(
                error as? MirmirPendingQueueError,
                .recordAlreadyStarted
            )
        }
        do {
            _ = try await queue.reorder(
                ids: ["job-second", "job-first", "job-third"]
            )
            XCTFail("The started head was moved.")
        } catch {
            XCTAssertEqual(
                error as? MirmirPendingQueueError,
                .invalidReorder
            )
        }

        let reordered = try await queue.reorder(
            ids: ["job-first", "job-third", "job-second"]
        )
        XCTAssertEqual(
            reordered.records.map(\.id),
            ["job-first", "job-third", "job-second"]
        )
        let removed = try await queue.remove(id: "job-first")
        XCTAssertTrue(removed)

        let secondStart = Date(timeIntervalSinceReferenceDate: 600)
        let secondClaim = try await queue.markStartedOrReturnHead(
            startedAt: secondStart
        )
        XCTAssertEqual(secondClaim.record?.id, "job-third")
        XCTAssertEqual(secondClaim.record?.startedAt, secondStart)
        XCTAssertTrue(secondClaim.didMarkStarted)
    }

    func testConcurrentClaimsReturnOneStartedHeadAndOneTransition()
        async throws {
        let directory = try makePendingQueueTemporaryDirectory()
        let queue = MirmirPendingWorkQueue(directoryURL: directory)
        _ = try await queue.enqueue(
            makePendingQueueRecord(id: "job-concurrent-head", order: 0)
        )
        let startedAt = Date(timeIntervalSinceReferenceDate: 1_000)

        let claims = try await withThrowingTaskGroup(
            of: MirmirPendingQueueHeadClaim.self,
            returning: [MirmirPendingQueueHeadClaim].self
        ) { group in
            for _ in 0..<40 {
                group.addTask {
                    try await queue.markStartedOrReturnHead(
                        startedAt: startedAt
                    )
                }
            }
            var values: [MirmirPendingQueueHeadClaim] = []
            for try await claim in group {
                values.append(claim)
            }
            return values
        }

        XCTAssertEqual(claims.count, 40)
        XCTAssertTrue(
            claims.allSatisfy { $0.record?.id == "job-concurrent-head" }
        )
        XCTAssertTrue(claims.allSatisfy { $0.record?.startedAt == startedAt })
        XCTAssertEqual(claims.filter(\.didMarkStarted).count, 1)

        let persisted = try await queue.load()
        XCTAssertEqual(persisted.records.first?.state, .started)
        XCTAssertEqual(persisted.records.first?.startedAt, startedAt)
    }

    func testStartedHeadReturnsToPendingIdempotentlyAndPersists()
        async throws {
        let directory = try makePendingQueueTemporaryDirectory()
        let queue = MirmirPendingWorkQueue(directoryURL: directory)
        _ = try await queue.enqueueMany([
            makePendingQueueRecord(id: "job-head", order: 0),
            makePendingQueueRecord(id: "job-next", order: 1)
        ])
        _ = try await queue.markStartedOrReturnHead(
            startedAt: Date(timeIntervalSinceReferenceDate: 500)
        )

        let returned = try await queue.returnStartedHeadToPending(
            id: "job-head"
        )
        XCTAssertEqual(returned.records.map(\.id), ["job-head", "job-next"])
        XCTAssertEqual(returned.records.map(\.order), [0, 1])
        XCTAssertEqual(returned.head?.state, .pending)
        XCTAssertNil(returned.head?.startedAt)

        let idempotent = try await queue.returnStartedHeadToPending(
            id: "job-head"
        )
        XCTAssertEqual(idempotent, returned)

        do {
            _ = try await queue.returnStartedHeadToPending(id: "job-next")
            XCTFail("A non-head record was returned to pending.")
        } catch {
            XCTAssertEqual(
                error as? MirmirPendingQueueError,
                .recordNotQueueHead
            )
        }
        do {
            _ = try await queue.returnStartedHeadToPending(id: "job-missing")
            XCTFail("An absent record was returned to pending.")
        } catch {
            XCTAssertEqual(
                error as? MirmirPendingQueueError,
                .recordNotFound
            )
        }

        let reloaded = MirmirPendingWorkQueue(directoryURL: directory)
        let persisted = try await reloaded.load()
        XCTAssertEqual(persisted.records, returned.records)

        let restarted = try await reloaded.markStartedOrReturnHead(
            startedAt: Date(timeIntervalSinceReferenceDate: 700)
        )
        XCTAssertEqual(restarted.record?.id, "job-head")
        XCTAssertTrue(restarted.didMarkStarted)
    }

    func testConcurrentReturnsSafelyConvergeOnPendingHead() async throws {
        let directory = try makePendingQueueTemporaryDirectory()
        let queue = MirmirPendingWorkQueue(directoryURL: directory)
        _ = try await queue.enqueue(
            makePendingQueueRecord(id: "job-return", order: 0)
        )
        _ = try await queue.markStartedOrReturnHead(
            startedAt: Date(timeIntervalSinceReferenceDate: 500)
        )

        let snapshots = try await withThrowingTaskGroup(
            of: MirmirPendingQueueSnapshot.self,
            returning: [MirmirPendingQueueSnapshot].self
        ) { group in
            for _ in 0..<40 {
                group.addTask {
                    try await queue.returnStartedHeadToPending(
                        id: "job-return"
                    )
                }
            }
            var values: [MirmirPendingQueueSnapshot] = []
            for try await snapshot in group {
                values.append(snapshot)
            }
            return values
        }

        XCTAssertEqual(snapshots.count, 40)
        XCTAssertTrue(snapshots.allSatisfy { $0.head?.state == .pending })
        XCTAssertTrue(snapshots.allSatisfy { $0.head?.startedAt == nil })
        XCTAssertTrue(snapshots.allSatisfy { $0.head?.order == 0 })

        let reloaded = MirmirPendingWorkQueue(directoryURL: directory)
        let persisted = try await reloaded.load()
        XCTAssertEqual(persisted.head?.id, "job-return")
        XCTAssertEqual(persisted.head?.state, .pending)
        XCTAssertNil(persisted.head?.startedAt)
    }

    func testConcurrentEnqueuesLoseNoRecordsAndPersistCanonicalOrder()
        async throws {
        let directory = try makePendingQueueTemporaryDirectory()
        let limits = try MirmirPendingQueueLimits(
            maximumRecords: 100,
            maximumDocumentBytes: 2 * 1_024 * 1_024,
            maximumBookmarkBytes: 1_024
        )
        let queue = MirmirPendingWorkQueue(
            directoryURL: directory,
            limits: limits
        )

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<50 {
                group.addTask {
                    _ = try await queue.enqueue(
                        makePendingQueueRecord(
                            id: "job-\(index)",
                            order: 0,
                            createdAt: Date(
                                timeIntervalSinceReferenceDate: Double(index)
                            )
                        )
                    )
                }
            }
            try await group.waitForAll()
        }

        let snapshot = try await queue.load()
        XCTAssertEqual(snapshot.records.count, 50)
        XCTAssertEqual(Set(snapshot.records.map(\.id)).count, 50)
        XCTAssertEqual(snapshot.records.map(\.order), Array(0..<50))

        let reloaded = MirmirPendingWorkQueue(
            directoryURL: directory,
            limits: limits
        )
        let persisted = try await reloaded.load()
        XCTAssertEqual(persisted.records, snapshot.records)
    }
}
