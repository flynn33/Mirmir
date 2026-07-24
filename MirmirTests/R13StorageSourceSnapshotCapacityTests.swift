import Foundation
import os.lock
import XCTest
@testable import Mirmir

final class R13StorageSourceSnapshotCapacityTests: XCTestCase {
    func testSnapshotCapacityAcceptsExactBoundaryAndRejectsOneByteShort()
        throws {
        let accepted = try R13SnapshotCapacityFixture()
        defer { accepted.cleanup() }
        let source = Data("snapshot-capacity".utf8)
        try source.write(to: accepted.sourceURL)
        let minimumFreeBytes: UInt64 = 100
        let requiredBytes = UInt64(source.count) + minimumFreeBytes
        let acceptingSnapshotter = R13LocalSourceSnapshotter(
            sourceMeasurer: R13LocalRestartSourceMeasurer(),
            capacityProbe: R13FixedSnapshotCapacityProbe(
                availableBytes: requiredBytes
            ),
            minimumFreeDiskBytes: minimumFreeBytes
        )

        let snapshot = try acceptingSnapshotter.createSnapshot(
            sourceURL: accepted.sourceURL,
            jobID: "r13-snapshot-capacity-accepted",
            jobsRootURL: accepted.jobsRootURL
        )
        XCTAssertEqual(try Data(contentsOf: snapshot.processingURL), source)
        try acceptingSnapshotter.discard(snapshot)

        let rejected = try R13SnapshotCapacityFixture()
        defer { rejected.cleanup() }
        try source.write(to: rejected.sourceURL)
        let rejectingSnapshotter = R13LocalSourceSnapshotter(
            sourceMeasurer: R13LocalRestartSourceMeasurer(),
            capacityProbe: R13FixedSnapshotCapacityProbe(
                availableBytes: requiredBytes - 1
            ),
            minimumFreeDiskBytes: minimumFreeBytes
        )

        XCTAssertThrowsError(
            try rejectingSnapshotter.createSnapshot(
                sourceURL: rejected.sourceURL,
                jobID: "r13-snapshot-capacity-rejected",
                jobsRootURL: rejected.jobsRootURL
            )
        ) { error in
            XCTAssertEqual(
                error as? R13RestartJobError,
                .insufficientDiskSpace(
                    requiredBytes: requiredBytes,
                    availableBytes: requiredBytes - 1
                )
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: rejected.snapshotsRootURL.path
            )
        )
    }

    func testSnapshotCapacityArithmeticOverflowFailsBeforeCreatingStorage()
        throws {
        let fixture = try R13SnapshotCapacityFixture()
        defer { fixture.cleanup() }
        let snapshotter = R13LocalSourceSnapshotter(
            sourceMeasurer: R13MaximumSourceIdentityMeasurer(),
            capacityProbe: R13FixedSnapshotCapacityProbe(
                availableBytes: UInt64.max
            ),
            minimumFreeDiskBytes: 1
        )

        XCTAssertThrowsError(
            try snapshotter.createSnapshot(
                sourceURL: fixture.sourceURL,
                jobID: "r13-snapshot-capacity-overflow",
                jobsRootURL: fixture.jobsRootURL
            )
        ) { error in
            XCTAssertEqual(
                error as? R13RestartJobError,
                .arithmeticOverflow(
                    field: "source_snapshot_required_bytes"
                )
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.snapshotsRootURL.path
            )
        )
    }

    func testGrowingSourceNeverWritesBeyondAdmittedSnapshotByteCount()
        throws {
        let fixture = try R13SnapshotCapacityFixture()
        defer { fixture.cleanup() }
        let admittedSource = Data([0x5A])
        try admittedSource.write(to: fixture.sourceURL)
        let retainedSnapshotLinkURL = fixture.rootURL
            .appendingPathComponent("retained-snapshot-link.mov")
        let snapshotter = R13LocalSourceSnapshotter(
            sourceMeasurer: R13LocalRestartSourceMeasurer(),
            copyBarrier: R13GrowSourceAfterFirstCopyBarrier(
                snapshotsRootURL: fixture.snapshotsRootURL,
                retainedSnapshotLinkURL: retainedSnapshotLinkURL
            )
        )

        XCTAssertThrowsError(
            try snapshotter.createSnapshot(
                sourceURL: fixture.sourceURL,
                jobID: "r13-snapshot-growth-bound",
                jobsRootURL: fixture.jobsRootURL
            )
        ) { error in
            XCTAssertEqual(
                error as? R13RestartJobError,
                .ioFailure(
                    operation: "source_changed_during_snapshot"
                )
            )
        }

        XCTAssertEqual(
            try Data(contentsOf: retainedSnapshotLinkURL),
            admittedSource
        )
        XCTAssertGreaterThan(
            try Data(contentsOf: fixture.sourceURL).count,
            admittedSource.count
        )
        let retainedEntries = try FileManager.default.contentsOfDirectory(
            at: fixture.snapshotsRootURL,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(retainedEntries.isEmpty)
    }

    func testAttemptCleanupReportsBoundedFailureAndRetainsSnapshotForRetry()
        async throws {
        let fixture = try R13HardeningFixture()
        defer { fixture.cleanup() }
        let snapshotter = R13InjectedCleanupSourceSnapshotter(
            sourceMeasurer: R13LocalRestartSourceMeasurer(),
            failuresBeforeSuccess: R13SourceSnapshotCleanup.attemptLimit
        )
        let runtime = try makeCleanupRuntime(
            fixture: fixture,
            sourceSnapshotter: snapshotter
        )
        let job = fixture.makeJob(identifier: "r13-snapshot-cleanup-retry")
        let attempt = try await runtime.prepare(
            job: job,
            source: fixture.sourceProfile,
            route: .scale3Over2,
            modeBinding: R13ReleaseModePolicy.binding(
                for: .deterministic
            )
        )

        let failedResult = await attempt.releaseResources()
        let failedCleanup = try XCTUnwrap(failedResult)

        XCTAssertFalse(failedCleanup.snapshotRemoved)
        XCTAssertEqual(
            failedCleanup.attempts,
            R13SourceSnapshotCleanup.attemptLimit
        )
        guard case .cleanupFailed(
            let directoryURL,
            let attempts,
            nil,
            _
        )? = failedCleanup.error else {
            return XCTFail(
                "Expected typed source-snapshot cleanup failure."
            )
        }
        XCTAssertEqual(directoryURL, failedCleanup.directoryURL)
        XCTAssertEqual(attempts, R13SourceSnapshotCleanup.attemptLimit)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: failedCleanup.directoryURL.path
            )
        )
        let diagnostics = await runtime.diagnosticsSnapshot()
        XCTAssertTrue(
            diagnostics.records.contains { record in
                record.event.code == .sourceSnapshotCleanupFailed
                    && record.event.severity == .error
                    && record.event.fields.contains { field in
                        field.key == .reason
                            && field.value
                                == R13ReleaseDiagnosticReason
                                    .sourceSnapshotCleanupFailed.rawValue
                    }
            }
        )

        let retryResult = await attempt.releaseResources()
        let successfulRetry = try XCTUnwrap(retryResult)

        XCTAssertTrue(successfulRetry.snapshotRemoved)
        XCTAssertEqual(successfulRetry.attempts, 1)
        XCTAssertNil(successfulRetry.error)
        XCTAssertEqual(
            snapshotter.discardAttemptCount,
            R13SourceSnapshotCleanup.attemptLimit + 1
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: successfulRetry.directoryURL.path
            )
        )
        let exhaustedRetry = await attempt.releaseResources()
        XCTAssertNil(exhaustedRetry)
    }

    private func makeCleanupRuntime(
        fixture: R13HardeningFixture,
        sourceSnapshotter: any R13SourceSnapshotting
    ) throws -> R13ReleaseHardeningRuntime {
        let documents = try R13ReleaseHardeningDocuments.production()
        let governor = R13ResourceGovernor(
            policy: documents.resourcePolicy,
            probes: R13ResourceProbes(
                availableDiskBytes: { UInt64.max },
                availableMemoryBytes: { UInt64.max },
                thermalCondition: { .nominal }
            )
        )
        return R13ReleaseHardeningRuntime(
            jobsRootURL: fixture.jobsRoot,
            sourceMeasurer: R13LocalRestartSourceMeasurer(),
            frameCounter: R13SnapshotFixedFrameCounter(),
            environmentCollector: try R13FixedEnvironmentCollector(),
            documents: documents,
            bookmarkResolver: R13TestBookmarkResolver(),
            storagePreflight: R13StoragePreflight(
                capacityProbe: R13CapacityProbe(
                    capacity: UInt64.max
                )
            ),
            outputCapacityProbe: R13CapacityProbe(
                capacity: UInt64.max
            ),
            resourceGovernor: governor,
            faultInjector: R13ProductionNoOpFaultInjector(),
            diagnostics: R13ReleaseDiagnostics(
                policy: try R13ReleaseDiagnosticsPolicy(
                    maximumRecords: 64,
                    maximumTotalBytes: 65_536
                )
            ),
            sourceSnapshotter: sourceSnapshotter
        )
    }
}

private struct R13FixedSnapshotCapacityProbe:
    R13AvailableCapacityProbing {
    let availableBytes: UInt64

    func availableCapacityForImportantUsage(at _: URL) throws -> UInt64 {
        availableBytes
    }
}

private struct R13MaximumSourceIdentityMeasurer:
    R13RestartSourceMeasuring {
    func measureSource(at _: URL) throws -> R13RestartSourceIdentity {
        try R13RestartSourceIdentity(
            sha256: String(repeating: "a", count: 64),
            byteCount: UInt64.max
        )
    }
}

private struct R13SnapshotFixedFrameCounter:
    R13SourceFrameCountMeasuring {
    func exactVideoFrameCount(at _: URL) async throws -> Int {
        1
    }
}

private final class R13GrowSourceAfterFirstCopyBarrier:
    R13SourceSnapshotCopyBarrier,
    @unchecked Sendable {
    private let snapshotsRootURL: URL
    private let retainedSnapshotLinkURL: URL
    private let didGrow = OSAllocatedUnfairLock(initialState: false)

    init(
        snapshotsRootURL: URL,
        retainedSnapshotLinkURL: URL
    ) {
        self.snapshotsRootURL = snapshotsRootURL
        self.retainedSnapshotLinkURL = retainedSnapshotLinkURL
    }

    func didCopy(
        byteCount _: UInt64,
        from sourceURL: URL
    ) throws {
        let mustGrow = didGrow.withLock { current in
            guard !current else { return false }
            current = true
            return true
        }
        guard mustGrow else { return }
        let snapshotDirectories = try FileManager.default
            .contentsOfDirectory(
                at: snapshotsRootURL,
                includingPropertiesForKeys: nil
            )
        let snapshotDirectory = try XCTUnwrap(
            snapshotDirectories.first
        )
        let snapshotFiles = try FileManager.default
            .contentsOfDirectory(
                at: snapshotDirectory,
                includingPropertiesForKeys: nil
            )
        let snapshotURL = try XCTUnwrap(snapshotFiles.first)
        try FileManager.default.linkItem(
            at: snapshotURL,
            to: retainedSnapshotLinkURL
        )
        let handle = try FileHandle(forWritingTo: sourceURL)
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: Data([0xA5, 0xA5]))
        try handle.synchronize()
        try handle.close()
    }
}

private final class R13InjectedCleanupSourceSnapshotter:
    R13SourceSnapshotting,
    @unchecked Sendable {
    private struct State {
        var remainingFailures: Int
        var discardAttemptCount = 0
    }

    private let base: R13LocalSourceSnapshotter
    private let state: OSAllocatedUnfairLock<State>

    init(
        sourceMeasurer: any R13RestartSourceMeasuring,
        failuresBeforeSuccess: Int
    ) {
        base = R13LocalSourceSnapshotter(
            sourceMeasurer: sourceMeasurer,
            capacityProbe: R13FixedSnapshotCapacityProbe(
                availableBytes: .max
            )
        )
        state = OSAllocatedUnfairLock(
            initialState: State(
                remainingFailures: failuresBeforeSuccess
            )
        )
    }

    var discardAttemptCount: Int {
        state.withLock { $0.discardAttemptCount }
    }

    func createSnapshot(
        sourceURL: URL,
        jobID: String,
        jobsRootURL: URL
    ) throws -> R13RetainedSourceSnapshot {
        try base.createSnapshot(
            sourceURL: sourceURL,
            jobID: jobID,
            jobsRootURL: jobsRootURL
        )
    }

    func discard(_ snapshot: R13RetainedSourceSnapshot) throws {
        let injectFailure = state.withLock { current in
            current.discardAttemptCount += 1
            guard current.remainingFailures > 0 else {
                return false
            }
            current.remainingFailures -= 1
            return true
        }
        if injectFailure {
            throw R13RestartJobError.ioFailure(
                operation: "injected_source_snapshot_cleanup"
            )
        }
        try base.discard(snapshot)
    }
}

private struct R13SnapshotCapacityFixture {
    let rootURL: URL
    let jobsRootURL: URL
    let sourceURL: URL

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "mirmir-r13-snapshot-capacity-\(UUID().uuidString)",
                isDirectory: true
            )
        jobsRootURL = rootURL.appendingPathComponent(
            "Jobs",
            isDirectory: true
        )
        sourceURL = rootURL.appendingPathComponent("source.mov")
        try FileManager.default.createDirectory(
            at: jobsRootURL,
            withIntermediateDirectories: true
        )
    }

    var snapshotsRootURL: URL {
        jobsRootURL.appendingPathComponent(
            ".source-snapshots",
            isDirectory: true
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}
