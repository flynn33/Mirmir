import Foundation
import XCTest
@testable import Mirmir

final class MirmirPendingWorkQueueTests: XCTestCase {
    func testRoundTripPersistsBookmarksAndCompleteEffectsConfiguration()
        async throws {
        let directory = try makePendingQueueTemporaryDirectory()
        let queue = MirmirPendingWorkQueue(directoryURL: directory)
        let configuration = UpscaleProcessingConfiguration(
            enginePreference: .mpsLanczos,
            strategyPreference: .adaptive,
            temporalConsistencyEnabled: false,
            edgeFidelityLevel: .high,
            detailRecoveryLevel: .low,
            effects: UpscaleEffectConfiguration(
                edgePreservationEnabled: true,
                compressionCleanupEnabled: true,
                textureGrainProtectionEnabled: true,
                temporalStabilityEnabled: true
            )
        )
        let record = makePendingQueueRecord(
            id: "job-round-trip",
            order: 0,
            createdAt: Date(timeIntervalSinceReferenceDate: 1_234.5),
            bookmarks: makePendingQueueBookmarks(
                sourceBookmark: Data([0x00, 0x10, 0xFF]),
                outputBookmark: Data([0xAB, 0xCD, 0xEF]),
                sourceDisplayName: "input.mov",
                outputDisplayName: "enhanced.mov"
            ),
            settings: makePendingQueueSettings(
                targetResolution: VideoResolution(width: 7_680, height: 4_320),
                codec: .h264,
                preserveAudio: false,
                requestedMode: .deterministic,
                processingConfiguration: configuration
            )
        )

        let mutation = try await queue.enqueue(record)
        XCTAssertEqual(mutation.records, [record])
        XCTAssertNil(mutation.recovery)

        let reloadedQueue = MirmirPendingWorkQueue(directoryURL: directory)
        let reloaded = try await reloadedQueue.load()
        XCTAssertEqual(reloaded.records, [record])
        XCTAssertEqual(
            reloaded.records.first?.settings.processingConfiguration.effects,
            configuration.effects
        )

        let data = try Data(contentsOf: pendingQueueDocumentURL(in: directory))
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"schemaVersion\":1"))
        XCTAssertFalse(json.contains("sourceURL"))
        XCTAssertFalse(json.contains("outputURL"))
        XCTAssertFalse(json.contains("/Users/"))
    }

    func testProcessingPathBatchFailurePersistsAtomicallyAcrossRestart()
        async throws {
        let directory = try makePendingQueueTemporaryDirectory()
        let queue = MirmirPendingWorkQueue(directoryURL: directory)
        let batchID = "batch-restart"
        let paths: [UpscaleEnginePreference] = [
            .mpsLanczos,
            .coreImageLanczos
        ]
        let records = paths.enumerated().map { index, path in
            makePendingQueueRecord(
                id: "job-path-\(index)",
                order: index,
                bookmarks: makePendingQueueBookmarks(
                    outputDisplayName: "output-\(index).mp4"
                ),
                settings: makePendingQueueSettings(
                    continuesAfterFailure: true,
                    processingPathBatch:
                        MirmirProcessingPathBatchContext(
                            id: batchID,
                            path: path,
                            ordinal: index,
                            totalCount: paths.count
                        )
                )
            )
        }
        _ = try await queue.enqueueMany(records)
        _ = try await queue.markStartedOrReturnHead(
            startedAt: Date(timeIntervalSinceReferenceDate: 101)
        )

        let terminal = try await queue.recordTerminalResultAndRemove(
            id: records[0].id,
            status: .failed,
            reason: "injected path failure",
            completedAt: Date(timeIntervalSinceReferenceDate: 102)
        )
        XCTAssertEqual(terminal.records.map(\.id), [records[1].id])
        XCTAssertEqual(terminal.records.map(\.order), [0])

        let reloaded = try await MirmirPendingWorkQueue(
            directoryURL: directory
        ).load()
        XCTAssertEqual(reloaded.records.map(\.id), [records[1].id])
        XCTAssertEqual(reloaded.processingPathBatchResults.count, 1)
        let result = try XCTUnwrap(
            reloaded.processingPathBatchResults.first
        )
        XCTAssertEqual(result.batch.id, batchID)
        XCTAssertEqual(result.batch.path, paths[0])
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.reason, "injected path failure")
        let summary = try XCTUnwrap(
            MirmirProcessingPathBatchSummary.latest(
                in: reloaded.processingPathBatchResults
            )
        )
        XCTAssertEqual(summary.totalCount, 2)
        XCTAssertEqual(summary.completedCount, 0)
        XCTAssertEqual(summary.failedCount, 1)
        XCTAssertFalse(summary.isComplete)
    }

    func testProcessingPathBatchReportsSuccessOnlyAfterEveryPathCompletes()
        async throws {
        let directory = try makePendingQueueTemporaryDirectory()
        let queue = MirmirPendingWorkQueue(directoryURL: directory)
        let batchID = "batch-all-success"
        let paths: [UpscaleEnginePreference] = [
            .mpsLanczos,
            .coreImageLanczos
        ]
        let records = paths.enumerated().map { index, path in
            makePendingQueueRecord(
                id: "job-success-\(index)",
                order: index,
                settings: makePendingQueueSettings(
                    continuesAfterFailure: true,
                    processingPathBatch:
                        MirmirProcessingPathBatchContext(
                            id: batchID,
                            path: path,
                            ordinal: index,
                            totalCount: paths.count
                        )
                )
            )
        }
        _ = try await queue.enqueueMany(records)
        _ = try await queue.recordTerminalResultAndRemove(
            id: records[0].id,
            status: .completed,
            reason: nil,
            completedAt: Date(timeIntervalSinceReferenceDate: 101)
        )
        let finished = try await queue.recordTerminalResultAndRemove(
            id: records[1].id,
            status: .completed,
            reason: nil,
            completedAt: Date(timeIntervalSinceReferenceDate: 102)
        )

        let summary = try XCTUnwrap(
            MirmirProcessingPathBatchSummary.latest(
                in: finished.processingPathBatchResults
            )
        )
        XCTAssertTrue(finished.records.isEmpty)
        XCTAssertEqual(summary.completedCount, 2)
        XCTAssertEqual(summary.failedCount, 0)
        XCTAssertTrue(summary.isComplete)
        XCTAssertTrue(summary.allSucceeded)
    }

    func testBackslashOutputNamePersistsAsContainedPathComponent()
        async throws {
        let directory = try makePendingQueueTemporaryDirectory()
        let queue = MirmirPendingWorkQueue(directoryURL: directory)
        let outputDisplayName = #"client\final.mov"#
        let record = makePendingQueueRecord(
            id: "job-backslash-output-name",
            order: 0,
            bookmarks: makePendingQueueBookmarks(
                outputDisplayName: outputDisplayName
            )
        )

        _ = try await queue.enqueue(record)
        let reloadedQueue = MirmirPendingWorkQueue(directoryURL: directory)
        let reloaded = try await reloadedQueue.load()
        let persistedDisplayName = try XCTUnwrap(
            reloaded.records.first?.bookmarks.outputDisplayName
        )
        XCTAssertEqual(persistedDisplayName, outputDisplayName)

        let outputDirectory = directory.appendingPathComponent(
            "Exports",
            isDirectory: true
        ).standardizedFileURL
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: false
        )
        let outputFile = outputDirectory.appendingPathComponent(
            persistedDisplayName,
            isDirectory: false
        ).standardizedFileURL
        try Data([0x01]).write(to: outputFile)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputFile.path))
        XCTAssertEqual(outputFile.lastPathComponent, persistedDisplayName)
        XCTAssertEqual(
            outputFile.deletingLastPathComponent().standardizedFileURL,
            outputDirectory
        )
    }

    func testBatchOrderUpdateReorderRemoveAndClearPersistDeterministically()
        async throws {
        let directory = try makePendingQueueTemporaryDirectory()
        let queue = MirmirPendingWorkQueue(directoryURL: directory)
        let third = makePendingQueueRecord(id: "job-third", order: 2)
        let first = makePendingQueueRecord(id: "job-first", order: 0)
        let second = makePendingQueueRecord(id: "job-second", order: 1)

        let inserted = try await queue.enqueueMany([third, first, second])
        XCTAssertEqual(
            inserted.records.map(\.id),
            ["job-first", "job-second", "job-third"]
        )
        XCTAssertEqual(inserted.records.map(\.order), [0, 1, 2])

        let updatedSecond = makePendingQueueRecord(
            id: "job-second",
            order: 1,
            settings: makePendingQueueSettings(
                codec: .h264,
                preserveAudio: false,
                requestedMode: .fast
            )
        )
        let updated = try await queue.update(updatedSecond)
        XCTAssertEqual(updated.records[1], updatedSecond)

        let reordered = try await queue.reorder(
            ids: ["job-third", "job-first", "job-second"]
        )
        XCTAssertEqual(
            reordered.records.map(\.id),
            ["job-third", "job-first", "job-second"]
        )
        XCTAssertEqual(reordered.records.map(\.order), [0, 1, 2])

        let removed = try await queue.remove(id: "job-first")
        let removedAgain = try await queue.remove(id: "job-first")
        XCTAssertTrue(removed)
        XCTAssertFalse(removedAgain)

        let afterRemoval = try await queue.load()
        XCTAssertEqual(
            afterRemoval.records.map(\.id),
            ["job-third", "job-second"]
        )
        XCTAssertEqual(afterRemoval.records.map(\.order), [0, 1])

        let reloaded = MirmirPendingWorkQueue(directoryURL: directory)
        let persisted = try await reloaded.load()
        XCTAssertEqual(persisted.records, afterRemoval.records)

        let cleared = try await reloaded.clear()
        XCTAssertEqual(cleared.records, [])
        let emptyReload = try await queue.load()
        XCTAssertEqual(emptyReload.records, [])
    }

    func testBatchImportIsAtomicForInvalidDuplicateAndCapacityFailures()
        async throws {
        let directory = try makePendingQueueTemporaryDirectory()
        let limits = try MirmirPendingQueueLimits(
            maximumRecords: 3,
            maximumDocumentBytes: 64 * 1_024,
            maximumBookmarkBytes: 1_024
        )
        let queue = MirmirPendingWorkQueue(
            directoryURL: directory,
            limits: limits
        )
        let seed = makePendingQueueRecord(id: "job-seed", order: 0)
        _ = try await queue.enqueue(seed)

        let valid = makePendingQueueRecord(id: "job-valid", order: 0)
        let invalid = makePendingQueueRecord(
            id: "job-invalid",
            order: 1,
            bookmarks: makePendingQueueBookmarks(sourceBookmark: Data())
        )
        await assertEnqueueManyRejected(
            [valid, invalid],
            expected: .invalidRecord(field: .sourceBookmark),
            by: queue
        )

        let duplicate = makePendingQueueRecord(id: "job-duplicate", order: 0)
        await assertEnqueueManyRejected(
            [duplicate, duplicate.assigningOrder(1)],
            expected: .duplicateJobID,
            by: queue
        )
        await assertEnqueueManyRejected(
            [seed],
            expected: .duplicateJobID,
            by: queue
        )
        await assertEnqueueManyRejected(
            [
                makePendingQueueRecord(id: "job-two", order: 0),
                makePendingQueueRecord(id: "job-three", order: 1),
                makePendingQueueRecord(id: "job-four", order: 2)
            ],
            expected: .capacityExceeded,
            by: queue
        )

        let persisted = try await queue.load()
        XCTAssertEqual(persisted.records, [seed])
    }

    func testStrictValidationRejectsUnsafeOrInternallyInvalidRecords()
        async throws {
        let directory = try makePendingQueueTemporaryDirectory()
        let queue = MirmirPendingWorkQueue(directoryURL: directory)

        await assertEnqueueRejected(
            makePendingQueueRecord(id: "invalid/id", order: 0),
            expected: .invalidRecord(field: .jobID),
            by: queue
        )
        await assertEnqueueRejected(
            makePendingQueueRecord(
                id: "empty-bookmark",
                order: 0,
                bookmarks: makePendingQueueBookmarks(outputBookmark: Data())
            ),
            expected: .invalidRecord(field: .outputBookmark),
            by: queue
        )
        await assertEnqueueRejected(
            makePendingQueueRecord(
                id: "raw-path-name",
                order: 0,
                bookmarks: makePendingQueueBookmarks(
                    outputDisplayName: "/Users/private/output.mov"
                )
            ),
            expected: .invalidRecord(field: .outputDisplayName),
            by: queue
        )
        await assertEnqueueRejected(
            makePendingQueueRecord(
                id: "invalid-resolution",
                order: 0,
                settings: makePendingQueueSettings(
                    targetResolution: VideoResolution(width: 0, height: 1_080)
                )
            ),
            expected: .invalidRecord(field: .targetResolution),
            by: queue
        )
        await assertEnqueueRejected(
            makePendingQueueRecord(
                id: "invalid-date",
                order: 0,
                createdAt: Date(timeIntervalSinceReferenceDate: .infinity)
            ),
            expected: .invalidRecord(field: .createdAt),
            by: queue
        )
        await assertEnqueueRejected(
            makePendingQueueRecord(
                id: "invalid-lifecycle",
                order: 0,
                startedAt: Date(timeIntervalSinceReferenceDate: 200)
            ),
            expected: .invalidRecord(field: .lifecycle),
            by: queue
        )

        let snapshot = try await queue.load()
        XCTAssertEqual(snapshot.records, [])
    }

    func testOutputDisplayNameBoundaryRejectsSlashNULAndDotTraversal()
        async throws {
        let directory = try makePendingQueueTemporaryDirectory()
        let queue = MirmirPendingWorkQueue(directoryURL: directory)
        let rejectedNames = [
            "nested/output.mov",
            "output\u{0}.mov",
            ".",
            ".."
        ]

        for (index, rejectedName) in rejectedNames.enumerated() {
            let record = makePendingQueueRecord(
                id: "job-invalid-output-name-\(index)",
                order: 0,
                bookmarks: makePendingQueueBookmarks(
                    outputDisplayName: rejectedName
                )
            )
            await assertEnqueueRejected(
                record,
                expected: .invalidRecord(field: .outputDisplayName),
                by: queue
            )
        }

        let persisted = try await queue.load()
        XCTAssertEqual(persisted.records, [])
    }

    func testCountAndDocumentByteBoundsPreserveExistingQueue()
        async throws {
        let directory = try makePendingQueueTemporaryDirectory()
        let limits = try MirmirPendingQueueLimits(
            maximumRecords: 2,
            maximumDocumentBytes: 1_600,
            maximumBookmarkBytes: 700
        )
        let queue = MirmirPendingWorkQueue(
            directoryURL: directory,
            limits: limits
        )
        let first = makePendingQueueRecord(id: "job-first", order: 0)
        _ = try await queue.enqueue(first)

        let oversized = makePendingQueueRecord(
            id: "job-too-large",
            order: 0,
            bookmarks: makePendingQueueBookmarks(
                sourceBookmark: Data(repeating: 0x41, count: 650),
                outputBookmark: Data(repeating: 0x42, count: 650)
            )
        )
        await assertEnqueueRejected(
            oversized,
            expected: .documentTooLarge,
            by: queue
        )

        let second = makePendingQueueRecord(id: "job-second", order: 0)
        _ = try await queue.enqueue(second)
        await assertEnqueueRejected(
            makePendingQueueRecord(id: "job-third", order: 0),
            expected: .capacityExceeded,
            by: queue
        )

        let persisted = try await queue.load()
        XCTAssertEqual(persisted.records.map(\.id), ["job-first", "job-second"])
    }
}

private extension MirmirPendingWorkQueueTests {
    func assertEnqueueRejected(
        _ record: MirmirPendingWorkRecord,
        expected: MirmirPendingQueueError,
        by queue: MirmirPendingWorkQueue,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await queue.enqueue(record)
            XCTFail("The invalid queue mutation succeeded.", file: file, line: line)
        } catch {
            XCTAssertEqual(
                error as? MirmirPendingQueueError,
                expected,
                file: file,
                line: line
            )
        }
    }

    func assertEnqueueManyRejected(
        _ records: [MirmirPendingWorkRecord],
        expected: MirmirPendingQueueError,
        by queue: MirmirPendingWorkQueue,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await queue.enqueueMany(records)
            XCTFail("The invalid batch mutation succeeded.", file: file, line: line)
        } catch {
            XCTAssertEqual(
                error as? MirmirPendingQueueError,
                expected,
                file: file,
                line: line
            )
        }
    }
}
