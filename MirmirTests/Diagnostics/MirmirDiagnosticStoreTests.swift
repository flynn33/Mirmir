import Foundation
import XCTest
@testable import Mirmir

final class MirmirDiagnosticStoreTests: XCTestCase {
    func testProductionRetentionPolicyMatchesApprovedBounds() {
        let policy = MirmirDiagnosticRetentionPolicy.production

        XCTAssertEqual(
            policy.maximumAgeMilliseconds,
            30 * 24 * 60 * 60 * 1_000
        )
        XCTAssertEqual(policy.maximumRecords, 10_000)
        XCTAssertEqual(policy.maximumTotalBytes, 10 * 1_024 * 1_024)
        XCTAssertEqual(policy.maximumRecordBytes, 32 * 1_024)
    }

    func testPersistentStoreReopensRecordsWithStrictSequence() async throws {
        let fixture = try DiagnosticStoreFixture()
        defer { fixture.cleanup() }
        let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let store = try MirmirDiagnosticStore(
            persistentDirectoryURL: fixture.directoryURL,
            policy: try policy(),
            clock: fixedClock(wall: 1_000, uptime: 10),
            sessionID: sessionID
        )

        let recorded = try await store.record(event(code: "probe_completed"))
        XCTAssertEqual(recorded.sequence, 0)
        XCTAssertEqual(recorded.sessionID, MirmirDiagnosticID(sessionID))

        let reopened = try MirmirDiagnosticStore(
            persistentDirectoryURL: fixture.directoryURL,
            policy: try policy(),
            clock: fixedClock(wall: 2_000, uptime: 20),
            sessionID: UUID(
                uuidString: "00000000-0000-0000-0000-000000000002"
            )!
        )
        let snapshot = try await reopened.snapshot()

        XCTAssertEqual(snapshot.records, [recorded])
        XCTAssertEqual(snapshot.retainedRecordCount, 1)
        XCTAssertEqual(snapshot.prunedRecordCount, 0)
        XCTAssertEqual(snapshot.rejectedRecordCount, 0)
        let journal = try Data(contentsOf: fixture.journalURL)
        XCTAssertEqual(journal.last, 0x0A)
        XCTAssertFalse(journal.isEmpty)
    }

    func testCountRetentionPrunesOldestFirst() async throws {
        let store = MirmirDiagnosticStore(
            inMemoryWith: try policy(maximumRecords: 2),
            clock: fixedClock(wall: 10_000, uptime: 100)
        )

        _ = try await store.record(event(code: "first"))
        _ = try await store.record(event(code: "second"))
        _ = try await store.record(event(code: "third"))

        let snapshot = try await store.snapshot()
        XCTAssertEqual(snapshot.records.map(\.sequence), [1, 2])
        XCTAssertEqual(
            snapshot.records.map(\.event.code.rawValue),
            ["second", "third"]
        )
        XCTAssertEqual(snapshot.prunedRecordCount, 1)
    }

    func testAgeRetentionPrunesExpiredRecordsAcrossSnapshot() async throws {
        let clock = ManualDiagnosticClock(
            wallMilliseconds: 1_000,
            uptimeNanoseconds: 100
        )
        let store = MirmirDiagnosticStore(
            inMemoryWith: try policy(maximumAgeMilliseconds: 1_000),
            clock: clock.clock
        )
        _ = try await store.record(event(code: "expires"))

        clock.set(wallMilliseconds: 2_001, uptimeNanoseconds: 200)
        let snapshot = try await store.snapshot()

        XCTAssertTrue(snapshot.records.isEmpty)
        XCTAssertEqual(snapshot.prunedRecordCount, 1)
    }

    func testTotalByteRetentionKeepsNewestRecordsAndBoundsJournal() async throws {
        let fixture = try DiagnosticStoreFixture()
        defer { fixture.cleanup() }
        let retention = try policy(
            maximumRecords: 100,
            maximumTotalBytes: 1_400,
            maximumRecordBytes: 900
        )
        let store = try MirmirDiagnosticStore(
            persistentDirectoryURL: fixture.directoryURL,
            policy: retention,
            clock: fixedClock(wall: 4_000, uptime: 400)
        )

        for index in 0..<8 {
            _ = try await store.record(
                event(
                    code: "bounded_record",
                    fields: [
                        try MirmirDiagnosticField(
                            key: "index",
                            value: .signedInteger(Int64(index))
                        )
                    ]
                )
            )
        }

        let snapshot = try await store.snapshot()
        let fileSize = try XCTUnwrap(
            try fixture.journalURL.resourceValues(
                forKeys: [.fileSizeKey]
            ).fileSize
        )
        XCTAssertLessThanOrEqual(fileSize, retention.maximumTotalBytes)
        XCTAssertGreaterThan(snapshot.prunedRecordCount, 0)
        XCTAssertEqual(snapshot.records.last?.sequence, 7)
        XCTAssertEqual(
            snapshot.records.map(\.sequence),
            snapshot.records.map(\.sequence).sorted()
        )
    }

    func testOversizedRecordIsRejectedWithoutConsumingSequence() async throws {
        let store = MirmirDiagnosticStore(
            inMemoryWith: try policy(
                maximumTotalBytes: 4_096,
                maximumRecordBytes: 350
            ),
            clock: fixedClock(wall: 5_000, uptime: 500)
        )
        let fields = try (0..<12).map { index in
            try MirmirDiagnosticField(
                key: "field_\(index)",
                value: .identifier(
                    "value_\(index)_abcdefghijklmnopqrstuvwxyz"
                )
            )
        }

        do {
            _ = try await store.record(
                event(code: "oversized", fields: fields)
            )
            XCTFail("Expected oversized diagnostic rejection.")
        } catch let error as MirmirDiagnosticStoreError {
            guard case .recordExceedsByteLimit(let observed, let maximum) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertGreaterThan(observed, maximum)
            XCTAssertEqual(maximum, 350)
        }

        let accepted = try await store.record(event(code: "accepted"))
        let snapshot = try await store.snapshot()
        XCTAssertEqual(accepted.sequence, 0)
        XCTAssertEqual(snapshot.records.map(\.sequence), [0])
        XCTAssertEqual(snapshot.rejectedRecordCount, 1)
    }

    func testConcurrentActorCallersReceiveUniqueMonotonicSequences() async throws {
        let store = MirmirDiagnosticStore(
            inMemoryWith: try policy(maximumRecords: 200),
            clock: fixedClock(wall: 6_000, uptime: 600)
        )
        let diagnosticEvent = try event(code: "concurrent_record")

        let sequences = try await withThrowingTaskGroup(
            of: UInt64.self,
            returning: [UInt64].self
        ) { group in
            for _ in 0..<100 {
                group.addTask {
                    try await store.record(diagnosticEvent).sequence
                }
            }
            var values: [UInt64] = []
            for try await sequence in group {
                values.append(sequence)
            }
            return values
        }

        XCTAssertEqual(sequences.sorted(), Array(0..<100).map(UInt64.init))
        let snapshot = try await store.snapshot()
        XCTAssertEqual(snapshot.records.map(\.sequence), Array(0..<100).map(UInt64.init))
    }

    func testIndependentStoresCoordinateThroughPersistentLock() async throws {
        let fixture = try DiagnosticStoreFixture()
        defer { fixture.cleanup() }
        let retention = try policy(maximumRecords: 100)
        let first = try MirmirDiagnosticStore(
            persistentDirectoryURL: fixture.directoryURL,
            policy: retention,
            clock: fixedClock(wall: 7_000, uptime: 700)
        )
        let second = try MirmirDiagnosticStore(
            persistentDirectoryURL: fixture.directoryURL,
            policy: retention,
            clock: fixedClock(wall: 7_001, uptime: 701)
        )
        let diagnosticEvent = try event(code: "cross_process_record")

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<40 {
                let selectedStore = index.isMultiple(of: 2) ? first : second
                group.addTask {
                    _ = try await selectedStore.record(diagnosticEvent)
                }
            }
            try await group.waitForAll()
        }

        let snapshot = try await first.snapshot()
        XCTAssertEqual(snapshot.retainedRecordCount, 40)
        XCTAssertEqual(snapshot.records.map(\.sequence), Array(0..<40).map(UInt64.init))
    }

    func testCorruptTailRecoveryPreservesValidPrefixAndRecordsWarning() async throws {
        let fixture = try DiagnosticStoreFixture()
        defer { fixture.cleanup() }
        let store = try MirmirDiagnosticStore(
            persistentDirectoryURL: fixture.directoryURL,
            policy: try policy(),
            clock: fixedClock(wall: 8_000, uptime: 800)
        )
        let original = try await store.record(event(code: "valid_prefix"))
        let corruptTail = Data(#"{"schema_version":1,"sequence":"#.utf8)
        let handle = try FileHandle(forWritingTo: fixture.journalURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: corruptTail)
        try handle.synchronize()
        try handle.close()

        let reopened = try MirmirDiagnosticStore(
            persistentDirectoryURL: fixture.directoryURL,
            policy: try policy(),
            clock: fixedClock(wall: 9_000, uptime: 900)
        )
        let snapshot = try await reopened.snapshot()

        XCTAssertEqual(snapshot.records.first, original)
        XCTAssertEqual(snapshot.records.map(\.sequence), [0, 1])
        XCTAssertEqual(
            snapshot.records.last?.event.code.rawValue,
            "diagnostic_store_tail_recovered"
        )
        XCTAssertEqual(snapshot.recoveredCorruptTailCount, 1)
        XCTAssertEqual(
            snapshot.recoveredCorruptByteCount,
            UInt64(corruptTail.count)
        )
        let repaired = try Data(contentsOf: fixture.journalURL)
        XCTAssertEqual(repaired.last, 0x0A)
        XCTAssertFalse(repaired.suffix(corruptTail.count) == corruptTail)
    }

    func testFutureJournalSchemaFailsWithoutOverwritingFile() throws {
        let fixture = try DiagnosticStoreFixture()
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(
            at: fixture.directoryURL,
            withIntermediateDirectories: true
        )
        let future = Data(
            """
            {"next_sequence":0,"pruned_record_count":0,"recovered_corrupt_byte_count":0,"recovered_corrupt_tail_count":0,"rejected_record_count":0,"schema_version":2}

            """.utf8
        )
        try future.write(to: fixture.journalURL)

        XCTAssertThrowsError(
            try MirmirDiagnosticStore(
                persistentDirectoryURL: fixture.directoryURL,
                policy: try policy(),
                clock: fixedClock(wall: 10_000, uptime: 1_000)
            )
        ) { error in
            XCTAssertEqual(
                error as? MirmirDiagnosticStoreError,
                .unsupportedJournalSchema(2)
            )
        }
        XCTAssertEqual(try Data(contentsOf: fixture.journalURL), future)
    }
}

private extension MirmirDiagnosticStoreTests {
    func policy(
        maximumAgeMilliseconds: Int64 = 30 * 24 * 60 * 60 * 1_000,
        maximumRecords: Int = 100,
        maximumTotalBytes: Int = 1 * 1_024 * 1_024,
        maximumRecordBytes: Int = 16 * 1_024
    ) throws -> MirmirDiagnosticRetentionPolicy {
        try MirmirDiagnosticRetentionPolicy(
            maximumAgeMilliseconds: maximumAgeMilliseconds,
            maximumRecords: maximumRecords,
            maximumTotalBytes: maximumTotalBytes,
            maximumRecordBytes: maximumRecordBytes
        )
    }

    func fixedClock(
        wall: Int64,
        uptime: UInt64
    ) -> MirmirDiagnosticClock {
        MirmirDiagnosticClock(
            wallMilliseconds: { wall },
            uptimeNanoseconds: { uptime }
        )
    }

    func event(
        code: String,
        fields: [MirmirDiagnosticField] = []
    ) throws -> MirmirDiagnosticEvent {
        try MirmirDiagnosticEvent(
            severity: .info,
            subsystem: "diagnostics_test",
            operation: "record",
            code: code,
            fields: fields
        )
    }
}

private final class ManualDiagnosticClock: @unchecked Sendable {
    private let lock = NSLock()
    private var wall: Int64
    private var uptime: UInt64

    init(wallMilliseconds: Int64, uptimeNanoseconds: UInt64) {
        wall = wallMilliseconds
        uptime = uptimeNanoseconds
    }

    var clock: MirmirDiagnosticClock {
        MirmirDiagnosticClock(
            wallMilliseconds: { [self] in
                lock.withLock { wall }
            },
            uptimeNanoseconds: { [self] in
                lock.withLock { uptime }
            }
        )
    }

    func set(wallMilliseconds: Int64, uptimeNanoseconds: UInt64) {
        lock.withLock {
            wall = wallMilliseconds
            uptime = uptimeNanoseconds
        }
    }
}

private struct DiagnosticStoreFixture {
    let directoryURL: URL

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "mirmir-diagnostics-\(UUID().uuidString)",
                isDirectory: true
            )
    }

    var journalURL: URL {
        directoryURL.appendingPathComponent(
            MirmirDiagnosticStore.journalFileName,
            isDirectory: false
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
