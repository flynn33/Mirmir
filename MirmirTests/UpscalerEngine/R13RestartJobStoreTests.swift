import Foundation
import XCTest
@testable import Mirmir

// Persistence scenarios share one descriptor-pinned restart-store fixture.
// swiftlint:disable file_length
// swiftlint:disable:next type_body_length
final class R13RestartJobStoreTests: XCTestCase {
    func testReopenVerifiesCachedPrefixForFreshWriterReplay() async throws {
        let fixture = try R13RestartStoreFixture()
        defer { fixture.cleanup() }
        let core = try fixture.makeCore(totalFrameCount: 3)
        let store = R13RestartJobStore(jobsRootURL: fixture.jobsRoot)
        var plan = try await store.create(core)
        let first = try fixture.frame(value: 10)
        let second = try fixture.frame(value: 20)
        plan = try await store.commitProcessedFrame(
            first,
            at: 0,
            using: plan
        )
        plan = try await store.commitProcessedFrame(
            second,
            at: 1,
            using: plan
        )

        let reopened = try await store.reopen(
            jobID: core.jobID,
            expecting: core,
            observedSource: core.source
        )

        XCTAssertTrue(reopened.requiresFreshMediaWriter)
        XCTAssertEqual(reopened.writerStartFrameIndex, 0)
        XCTAssertEqual(reopened.verifiedCachedPrefixCount, 2)
        XCTAssertEqual(reopened.backendStartFrameIndex, 2)
        XCTAssertEqual(
            try reopened.disposition(forFrameAt: 0),
            .replayVerifiedCache
        )
        XCTAssertEqual(
            try reopened.disposition(forFrameAt: 1),
            .replayVerifiedCache
        )
        XCTAssertEqual(
            try reopened.disposition(forFrameAt: 2),
            .runBackend
        )
        let replayedFirst = try await store.loadCachedFrame(
            at: 0,
            using: reopened
        )
        let replayedSecond = try await store.loadCachedFrame(
            at: 1,
            using: reopened
        )
        XCTAssertEqual(replayedFirst, first)
        XCTAssertEqual(replayedSecond, second)
    }

    func testUnchangedFullValidationReusesDescriptorPinnedSnapshots()
        async throws {
        let fixture = try R13RestartStoreFixture()
        defer { fixture.cleanup() }
        let core = try fixture.makeCore(totalFrameCount: 3)
        let fileSystem = R13CountingSnapshotFileSystem()
        let store = R13RestartJobStore(
            jobsRootURL: fixture.jobsRoot,
            fileSystem: fileSystem
        )
        var plan = try await store.create(core)
        plan = try await store.commitProcessedFrame(
            fixture.frame(value: 10),
            at: 0,
            using: plan
        )
        plan = try await store.commitProcessedFrame(
            fixture.frame(value: 20),
            at: 1,
            using: plan
        )

        fileSystem.resetCounts()
        let firstValidatedCount = try await store.validateRecoverableJob(
            jobID: core.jobID
        )
        XCTAssertEqual(firstValidatedCount, 2)
        XCTAssertEqual(fileSystem.counts().artifactContentReads, 2)
        XCTAssertEqual(fileSystem.counts().snapshotComparisons, 0)

        fileSystem.resetCounts()
        let reusedValidatedCount = try await store.validateRecoverableJob(
            jobID: core.jobID
        )
        XCTAssertEqual(reusedValidatedCount, 2)
        XCTAssertEqual(fileSystem.counts().artifactContentReads, 0)
        XCTAssertEqual(fileSystem.counts().snapshotComparisons, 6)

        fileSystem.resetCounts()
        let reopened = try await store.reopen(
            jobID: core.jobID,
            expecting: core,
            observedSource: core.source
        )
        XCTAssertEqual(reopened.verifiedCachedPrefixCount, 2)
        XCTAssertEqual(fileSystem.counts().artifactContentReads, 0)
        XCTAssertEqual(fileSystem.counts().snapshotComparisons, 6)

        fileSystem.resetCounts()
        _ = try await store.loadCachedFrame(at: 0, using: reopened)
        XCTAssertEqual(
            fileSystem.counts().artifactContentReads,
            1,
            "Replay must continue to validate the selected frame payload."
        )
    }

    func testCachedValidationRejectsArtifactTamperBeforeReopen()
        async throws {
        let fixture = try R13RestartStoreFixture()
        defer { fixture.cleanup() }
        let core = try fixture.makeCore(totalFrameCount: 2)
        let fileSystem = R13CountingSnapshotFileSystem()
        let store = R13RestartJobStore(
            jobsRootURL: fixture.jobsRoot,
            fileSystem: fileSystem
        )
        var plan = try await store.create(core)
        plan = try await store.commitProcessedFrame(
            fixture.frame(value: 31),
            at: 0,
            using: plan
        )
        _ = try await store.validateRecoverableJob(jobID: core.jobID)
        let artifactURL = try fixture.artifactURL(
            jobID: core.jobID,
            frameIndex: 0
        )
        var artifact = try Data(contentsOf: artifactURL)
        artifact[artifact.startIndex] ^= 0x01
        try artifact.write(to: artifactURL, options: .atomic)

        fileSystem.resetCounts()
        do {
            _ = try await store.reopen(
                jobID: core.jobID,
                expecting: core,
                observedSource: core.source
            )
            XCTFail("A changed artifact must invalidate cached evidence.")
        } catch {
            XCTAssertEqual(
                error as? R13RestartJobError,
                .cachedFrameCorrupt(index: 0)
            )
        }
        XCTAssertGreaterThan(fileSystem.counts().snapshotComparisons, 0)
        XCTAssertEqual(fileSystem.counts().artifactContentReads, 1)
    }

    func testSameContentArtifactReplacementForcesFullRevalidation()
        async throws {
        let fixture = try R13RestartStoreFixture()
        defer { fixture.cleanup() }
        let core = try fixture.makeCore(totalFrameCount: 2)
        let fileSystem = R13CountingSnapshotFileSystem()
        let store = R13RestartJobStore(
            jobsRootURL: fixture.jobsRoot,
            fileSystem: fileSystem
        )
        var plan = try await store.create(core)
        plan = try await store.commitProcessedFrame(
            fixture.frame(value: 44),
            at: 0,
            using: plan
        )
        _ = try await store.validateRecoverableJob(jobID: core.jobID)
        let artifactURL = R13RestartPath.resolvingExistingAncestor(
            of: try fixture.artifactURL(
                jobID: core.jobID,
                frameIndex: 0
            )
        )
        let localFileSystem = R13LocalRestartFileSystem()
        let before = try XCTUnwrap(
            localFileSystem.readRegularFileWithSnapshot(
                artifactURL,
                maximumBytes: Int.max
            ).snapshot
        )
        let replacementURL = artifactURL.deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString)
        try Data(contentsOf: artifactURL).write(to: replacementURL)
        try FileManager.default.removeItem(at: artifactURL)
        try FileManager.default.moveItem(
            at: replacementURL,
            to: artifactURL
        )
        let after = try XCTUnwrap(
            localFileSystem.readRegularFileWithSnapshot(
                artifactURL,
                maximumBytes: Int.max
            ).snapshot
        )
        XCTAssertNotEqual(before.fileID, after.fileID)

        fileSystem.resetCounts()
        let replacementValidatedCount =
            try await store.validateRecoverableJob(jobID: core.jobID)
        XCTAssertEqual(replacementValidatedCount, 1)
        XCTAssertGreaterThan(fileSystem.counts().snapshotComparisons, 0)
        XCTAssertEqual(fileSystem.counts().artifactContentReads, 1)

        fileSystem.resetCounts()
        let reusedReplacementCount =
            try await store.validateRecoverableJob(jobID: core.jobID)
        XCTAssertEqual(reusedReplacementCount, 1)
        XCTAssertEqual(fileSystem.counts().artifactContentReads, 0)
    }

    func testSequentialCommitDoesNotReadPriorFrameArtifacts()
        async throws {
        let fixture = try R13RestartStoreFixture()
        defer { fixture.cleanup() }
        let core = try fixture.makeCore(totalFrameCount: 2)
        let fileSystem = R13CountingSnapshotFileSystem()
        let store = R13RestartJobStore(
            jobsRootURL: fixture.jobsRoot,
            fileSystem: fileSystem
        )
        var plan = try await store.create(core)
        plan = try await store.commitProcessedFrame(
            fixture.frame(value: 51),
            at: 0,
            using: plan
        )

        fileSystem.resetCounts()
        _ = try await store.commitProcessedFrame(
            fixture.frame(value: 52),
            at: 1,
            using: plan
        )

        XCTAssertEqual(fileSystem.counts().artifactContentReads, 0)
    }

    func testSourceDriftFailsBeforeWriterOrBackendCreation() async throws {
        let fixture = try R13RestartStoreFixture()
        defer { fixture.cleanup() }
        let core = try fixture.makeCore(totalFrameCount: 1)
        let store = R13RestartJobStore(jobsRootURL: fixture.jobsRoot)
        _ = try await store.create(core)
        let drifted = try R13RestartSourceIdentity(
            sha256: String(repeating: "9", count: 64),
            byteCount: core.source.byteCount
        )
        var writerCreated = false
        var backendCalled = false

        do {
            _ = try await store.reopen(
                jobID: core.jobID,
                expecting: core,
                observedSource: drifted
            )
            writerCreated = true
            backendCalled = true
            XCTFail("Source drift must fail before downstream work.")
        } catch {
            XCTAssertEqual(
                error as? R13RestartJobError,
                .sourceDrift(expected: core.source, observed: drifted)
            )
        }
        XCTAssertFalse(writerCreated)
        XCTAssertFalse(backendCalled)
    }

    func testCachedFrameTamperFailsBeforeWriterOrBackendCreation() async throws {
        let fixture = try R13RestartStoreFixture()
        defer { fixture.cleanup() }
        let core = try fixture.makeCore(totalFrameCount: 2)
        let store = R13RestartJobStore(jobsRootURL: fixture.jobsRoot)
        var plan = try await store.create(core)
        plan = try await store.commitProcessedFrame(
            fixture.frame(value: 8),
            at: 0,
            using: plan
        )
        let recordURL = fixture.jobDirectory(jobID: core.jobID)
            .appendingPathComponent("records/0.json")
        let record = try JSONDecoder().decode(
            R13RestartCommitRecord.self,
            from: Data(contentsOf: recordURL)
        )
        let artifactURL = fixture.jobDirectory(jobID: core.jobID)
            .appendingPathComponent(record.artifact.relativePath)
        var artifact = try Data(contentsOf: artifactURL)
        artifact[artifact.index(before: artifact.endIndex)] ^= 0x01
        try artifact.write(to: artifactURL, options: .atomic)
        var writerCreated = false
        var backendCalled = false

        do {
            _ = try await store.reopen(
                jobID: core.jobID,
                expecting: core,
                observedSource: core.source
            )
            writerCreated = true
            backendCalled = true
            XCTFail("Tampered cache data must fail before downstream work.")
        } catch {
            XCTAssertEqual(
                error as? R13RestartJobError,
                .cachedFrameCorrupt(index: 0)
            )
        }
        XCTAssertFalse(writerCreated)
        XCTAssertFalse(backendCalled)
    }

    func testInterruptedCommitLeavesHeadAuthoritativeAndRetryable() async throws {
        let fixture = try R13RestartStoreFixture()
        defer { fixture.cleanup() }
        let core = try fixture.makeCore(totalFrameCount: 1)
        let fileSystem = R13FailingHeadFileSystem()
        let failingStore = R13RestartJobStore(
            jobsRootURL: fixture.jobsRoot,
            fileSystem: fileSystem
        )
        let initialPlan = try await failingStore.create(core)
        fileSystem.clearEvents()
        fileSystem.failNextHeadReplacement()

        do {
            _ = try await failingStore.commitProcessedFrame(
                fixture.frame(value: 44),
                at: 0,
                using: initialPlan
            )
            XCTFail("The injected head publication failure must surface.")
        } catch {
            XCTAssertEqual(
                error as? R13RestartJobError,
                .ioFailure(operation: "injected_head_replace")
            )
        }
        XCTAssertEqual(
            fileSystem.events().suffix(3),
            ["frame", "record", "head"]
        )

        let retryStore = R13RestartJobStore(jobsRootURL: fixture.jobsRoot)
        var reopened = try await retryStore.reopen(
            jobID: core.jobID,
            expecting: core,
            observedSource: core.source
        )
        XCTAssertEqual(reopened.verifiedCachedPrefixCount, 0)
        reopened = try await retryStore.commitProcessedFrame(
            fixture.frame(value: 44),
            at: 0,
            using: reopened
        )
        XCTAssertEqual(reopened.verifiedCachedPrefixCount, 1)
    }

    func testPrepublicationReceiptRequiresCompleteVerifiedCache() async throws {
        let fixture = try R13RestartStoreFixture()
        defer { fixture.cleanup() }
        let core = try fixture.makeCore(totalFrameCount: 1)
        let store = R13RestartJobStore(jobsRootURL: fixture.jobsRoot)
        var plan = try await store.create(core)

        do {
            _ = try await store.preparePrepublicationReceipt(
                using: plan,
                observedSource: core.source,
                outputMediaSHA256: String(repeating: "f", count: 64),
                outputMediaByteCount: 100
            )
            XCTFail("Incomplete frame caches cannot authorize publication.")
        } catch {
            XCTAssertEqual(
                error as? R13RestartJobError,
                .incompleteJob(committed: 0, expected: 1)
            )
        }
        plan = try await store.commitProcessedFrame(
            fixture.frame(value: 12),
            at: 0,
            using: plan
        )
        let first = try await store.preparePrepublicationReceipt(
            using: plan,
            observedSource: core.source,
            outputMediaSHA256: String(repeating: "f", count: 64),
            outputMediaByteCount: 100
        )
        let second = try await store.preparePrepublicationReceipt(
            using: plan,
            observedSource: core.source,
            outputMediaSHA256: String(repeating: "f", count: 64),
            outputMediaByteCount: 100
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.writerStartFrameIndex, 0)
        XCTAssertEqual(first.partialMediaReusePolicy, .forbidden)
        XCTAssertEqual(first.frameCount, 1)
    }

    func testReopenClearsTentativeReceiptAndAllowsDifferentRetryReceipt()
        async throws {
        let fixture = try R13RestartStoreFixture()
        defer { fixture.cleanup() }
        let core = try fixture.makeCore(totalFrameCount: 1)
        let firstStore = R13RestartJobStore(jobsRootURL: fixture.jobsRoot)
        var plan = try await firstStore.create(core)
        plan = try await firstStore.commitProcessedFrame(
            fixture.frame(value: 21),
            at: 0,
            using: plan
        )
        let first = try await firstStore.preparePrepublicationReceipt(
            using: plan,
            observedSource: core.source,
            outputMediaSHA256: String(repeating: "a", count: 64),
            outputMediaByteCount: 100
        )
        let receiptURL = fixture.jobDirectory(jobID: core.jobID)
            .appendingPathComponent("prepublication-receipt-v1.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: receiptURL.path))

        let relaunchedStore = R13RestartJobStore(
            jobsRootURL: fixture.jobsRoot
        )
        let reopened = try await relaunchedStore.reopen(
            jobID: core.jobID,
            expecting: core,
            observedSource: core.source
        )

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: receiptURL.path)
        )
        let retry = try await relaunchedStore.preparePrepublicationReceipt(
            using: reopened,
            observedSource: core.source,
            outputMediaSHA256: String(repeating: "b", count: 64),
            outputMediaByteCount: 101
        )
        XCTAssertNotEqual(retry, first)
        XCTAssertEqual(
            retry.outputMediaSHA256,
            String(repeating: "b", count: 64)
        )
        XCTAssertEqual(retry.outputMediaByteCount, 101)
    }

    func testDiscardRemovesOnlyTheExactValidatedJobDirectory() async throws {
        let fixture = try R13RestartStoreFixture()
        defer { fixture.cleanup() }
        let firstCore = try fixture.makeCore(
            jobID: "job-first",
            totalFrameCount: 1
        )
        let secondCore = try fixture.makeCore(
            jobID: "job-second",
            totalFrameCount: 1
        )
        let store = R13RestartJobStore(jobsRootURL: fixture.jobsRoot)
        _ = try await store.create(firstCore)
        _ = try await store.create(secondCore)

        try await store.discard(jobID: firstCore.jobID)

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.jobDirectory(jobID: firstCore.jobID).path
            )
        )
        XCTAssertNoThrow(
            try FileManager.default.contentsOfDirectory(
                atPath: fixture.jobDirectory(jobID: secondCore.jobID).path
            )
        )
        _ = try await store.reopen(
            jobID: secondCore.jobID,
            expecting: secondCore,
            observedSource: secondCore.source
        )
    }
}

private struct R13RestartStoreFixture {
    let root: URL
    let jobsRoot: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        jobsRoot = root.appendingPathComponent("Jobs", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
    }

    func makeCore(
        jobID: String = "job-restart",
        totalFrameCount: Int
    ) throws -> R13RestartJobCore {
        try R13RestartJobCore(
            jobID: jobID,
            source: R13RestartSourceIdentity(
                sha256: String(repeating: "1", count: 64),
                byteCount: 123
            ),
            processing: R13RestartProcessingIdentity(
                requestedMode: "deterministic",
                effectiveMode: "deterministic",
                routeIdentity: "scale_3_over_2",
                backendIdentity: "r03.mps.lanczos",
                backendRevision: "1"
            ),
            output: R13RestartOutputIdentity(
                width: 4,
                height: 2,
                codec: "hevc",
                audioPolicy: "preserve"
            ),
            totalFrameCount: totalFrameCount
        )
    }

    func frame(value: UInt8) throws -> R13NV12Frame {
        try R13NV12Frame(
            width: 4,
            height: 2,
            luma: Data(repeating: value, count: 8),
            chroma: Data(repeating: value &+ 1, count: 4)
        )
    }

    func jobDirectory(jobID: String) -> URL {
        jobsRoot.appendingPathComponent(jobID, isDirectory: true)
    }

    func artifactURL(
        jobID: String,
        frameIndex: Int
    ) throws -> URL {
        let jobDirectory = jobDirectory(jobID: jobID)
        let record = try JSONDecoder().decode(
            R13RestartCommitRecord.self,
            from: Data(
                contentsOf: jobDirectory.appendingPathComponent(
                    "records/\(frameIndex).json"
                )
            )
        )
        return jobDirectory.appendingPathComponent(
            record.artifact.relativePath
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private final class R13CountingSnapshotFileSystem:
    R13RestartFileSystem,
    @unchecked Sendable {
    struct Counts {
        var artifactContentReads = 0
        var snapshotComparisons = 0
    }

    private let base = R13LocalRestartFileSystem()
    private let lock = NSLock()
    private var observedCounts = Counts()

    func ensureDirectory(_ url: URL) throws {
        try base.ensureDirectory(url)
    }

    func createDirectoryExclusively(_ url: URL) throws {
        try base.createDirectoryExclusively(url)
    }

    func validateDirectory(_ url: URL) throws {
        try base.validateDirectory(url)
    }

    func exists(_ url: URL) -> Bool {
        base.exists(url)
    }

    func readRegularFile(_ url: URL, maximumBytes: Int) throws -> Data {
        recordContentRead(at: url)
        return try base.readRegularFile(
            url,
            maximumBytes: maximumBytes
        )
    }

    func readRegularFileWithSnapshot(
        _ url: URL,
        maximumBytes: Int
    ) throws -> R13RestartRegularFileRead {
        recordContentRead(at: url)
        return try base.readRegularFileWithSnapshot(
            url,
            maximumBytes: maximumBytes
        )
    }

    func regularFile(
        _ url: URL,
        matches snapshot: R13RestartRegularFileSnapshot
    ) -> Bool {
        lock.withLock {
            observedCounts.snapshotComparisons += 1
        }
        return base.regularFile(url, matches: snapshot)
    }

    func writeNewAtomically(_ data: Data, to url: URL) throws {
        try base.writeNewAtomically(data, to: url)
    }

    func replaceAtomically(_ data: Data, at url: URL) throws {
        try base.replaceAtomically(data, at: url)
    }

    func publishDirectoryAtomically(
        from sourceURL: URL,
        to destinationURL: URL
    ) throws {
        try base.publishDirectoryAtomically(
            from: sourceURL,
            to: destinationURL
        )
    }

    func removeFile(_ url: URL) throws {
        try base.removeFile(url)
    }

    func removeDirectory(_ url: URL) throws {
        try base.removeDirectory(url)
    }

    func resetCounts() {
        lock.withLock {
            observedCounts = Counts()
        }
    }

    func counts() -> Counts {
        lock.withLock { observedCounts }
    }

    private func recordContentRead(at url: URL) {
        guard url.pathExtension == "r13nv12" else { return }
        lock.withLock {
            observedCounts.artifactContentReads += 1
        }
    }
}

private final class R13FailingHeadFileSystem:
    R13RestartFileSystem,
    @unchecked Sendable {
    private let base = R13LocalRestartFileSystem()
    private let lock = NSLock()
    private var shouldFailHead = false
    private var observedEvents: [String] = []

    func ensureDirectory(_ url: URL) throws {
        try base.ensureDirectory(url)
    }

    func createDirectoryExclusively(_ url: URL) throws {
        try base.createDirectoryExclusively(url)
    }

    func validateDirectory(_ url: URL) throws {
        try base.validateDirectory(url)
    }

    func exists(_ url: URL) -> Bool {
        base.exists(url)
    }

    func readRegularFile(_ url: URL, maximumBytes: Int) throws -> Data {
        try base.readRegularFile(url, maximumBytes: maximumBytes)
    }

    func writeNewAtomically(_ data: Data, to url: URL) throws {
        if url.pathExtension == "r13nv12" {
            appendEvent("frame")
        } else if url.deletingLastPathComponent().lastPathComponent
                    == "records" {
            appendEvent("record")
        }
        try base.writeNewAtomically(data, to: url)
    }

    func replaceAtomically(_ data: Data, at url: URL) throws {
        if url.lastPathComponent == "head-v1.json" {
            appendEvent("head")
            let fails = lock.withLock {
                defer { shouldFailHead = false }
                return shouldFailHead
            }
            if fails {
                throw R13RestartJobError.ioFailure(
                    operation: "injected_head_replace"
                )
            }
        }
        try base.replaceAtomically(data, at: url)
    }

    func publishDirectoryAtomically(
        from sourceURL: URL,
        to destinationURL: URL
    ) throws {
        try base.publishDirectoryAtomically(
            from: sourceURL,
            to: destinationURL
        )
    }

    func removeDirectory(_ url: URL) throws {
        try base.removeDirectory(url)
    }

    func removeFile(_ url: URL) throws {
        try base.removeFile(url)
    }

    func failNextHeadReplacement() {
        lock.withLock {
            shouldFailHead = true
        }
    }

    func clearEvents() {
        lock.withLock {
            observedEvents = []
        }
    }

    func events() -> [String] {
        lock.withLock { observedEvents }
    }

    private func appendEvent(_ event: String) {
        lock.withLock {
            observedEvents.append(event)
        }
    }
}

// swiftlint:enable file_length
