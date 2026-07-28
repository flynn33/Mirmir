import Foundation
import XCTest
@testable import Mirmir

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

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
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
