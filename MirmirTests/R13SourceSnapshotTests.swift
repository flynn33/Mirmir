import CoreMedia
import Foundation
import os.lock
import XCTest
@testable import Mirmir

final class R13SourceSnapshotTests: XCTestCase {
    func testLocalSnapshotRetainsExactBytesAndDeletesUniqueCopy()
        throws {
        let fixture = try R13SourceSnapshotFixture()
        defer { fixture.cleanup() }
        let original = Data("immutable-r13-source".utf8)
        try original.write(to: fixture.sourceURL)
        let snapshotter = R13LocalSourceSnapshotter(
            sourceMeasurer: R13LocalRestartSourceMeasurer()
        )

        let snapshot = try snapshotter.createSnapshot(
            sourceURL: fixture.sourceURL,
            jobID: "r13-snapshot-retention",
            jobsRootURL: fixture.jobsRootURL
        )

        XCTAssertEqual(try Data(contentsOf: snapshot.processingURL), original)
        XCTAssertEqual(snapshot.storageByteCount, UInt64(original.count))
        XCTAssertTrue(
            snapshot.directoryURL.lastPathComponent.hasPrefix(
                ".r13-snapshot-retention."
            )
        )
        XCTAssertEqual(
            snapshot.directoryURL
                .deletingLastPathComponent()
                .lastPathComponent,
            ".source-snapshots"
        )
        try Data("changed-original".utf8).write(to: fixture.sourceURL)
        XCTAssertEqual(try Data(contentsOf: snapshot.processingURL), original)

        try snapshotter.discard(snapshot)

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: snapshot.directoryURL.path
            )
        )
    }

    func testLocalSnapshotUsesDeterministicNameForExtensionlessInput()
        throws {
        let fixture = try R13SourceSnapshotFixture()
        defer { fixture.cleanup() }
        let sourceURL = fixture.rootURL.appendingPathComponent(
            "extensionless-input"
        )
        let original = Data("extensionless-video-container".utf8)
        try original.write(to: sourceURL)
        let snapshotter = R13LocalSourceSnapshotter(
            sourceMeasurer: R13LocalRestartSourceMeasurer()
        )

        let snapshot = try snapshotter.createSnapshot(
            sourceURL: sourceURL,
            jobID: "r13-extensionless-snapshot",
            jobsRootURL: fixture.jobsRootURL
        )
        defer { try? snapshotter.discard(snapshot) }

        XCTAssertEqual(snapshot.processingURL.lastPathComponent, "source")
        XCTAssertEqual(try Data(contentsOf: snapshot.processingURL), original)
    }

    func testLocalSnapshotFallsBackForUnusualExtensions()
        throws {
        let fixture = try R13SourceSnapshotFixture()
        defer { fixture.cleanup() }
        let snapshotter = R13LocalSourceSnapshotter(
            sourceMeasurer: R13LocalRestartSourceMeasurer()
        )
        let fileNames = [
            "video.this-extension-exceeds-sixteen-characters",
            "video.映像"
        ]

        for (index, fileName) in fileNames.enumerated() {
            let sourceURL = fixture.rootURL.appendingPathComponent(fileName)
            let original = Data("unusual-video-\(index)".utf8)
            try original.write(to: sourceURL)

            let snapshot = try snapshotter.createSnapshot(
                sourceURL: sourceURL,
                jobID: "r13-unusual-extension-\(index)",
                jobsRootURL: fixture.jobsRootURL
            )

            XCTAssertEqual(snapshot.processingURL.lastPathComponent, "source")
            XCTAssertEqual(
                try Data(contentsOf: snapshot.processingURL),
                original
            )
            try snapshotter.discard(snapshot)
        }
    }

    func testLocalSnapshotRejectsMutateAndRestoreDuringCopy()
        throws {
        let fixture = try R13SourceSnapshotFixture()
        defer { fixture.cleanup() }
        let original = Data(repeating: 0x5A, count: 2_097_152)
        try original.write(to: fixture.sourceURL)
        let snapshotter = R13LocalSourceSnapshotter(
            sourceMeasurer: R13LocalRestartSourceMeasurer(),
            copyBarrier: R13MutateAndRestoreSourceBarrier(
                original: original
            )
        )

        XCTAssertThrowsError(
            try snapshotter.createSnapshot(
                sourceURL: fixture.sourceURL,
                jobID: "r13-snapshot-mutation",
                jobsRootURL: fixture.jobsRootURL
            )
        ) { error in
            guard case .ioFailure(let operation) =
                    error as? R13RestartJobError else {
                return XCTFail("Unexpected snapshot error: \(error)")
            }
            XCTAssertEqual(
                operation,
                "source_changed_during_snapshot"
            )
        }
        XCTAssertEqual(try Data(contentsOf: fixture.sourceURL), original)
        let snapshotsRoot = fixture.jobsRootURL.appendingPathComponent(
            ".source-snapshots",
            isDirectory: true
        )
        let retainedEntries = try FileManager.default.contentsOfDirectory(
            at: snapshotsRoot,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(retainedEntries.isEmpty)
    }

    func testShippingServiceUsesSnapshotForEverySourceConsumerAndCleanup()
        async throws {
        let fixture = try R13SourceSnapshotFixture()
        defer { fixture.cleanup() }
        let original = Data("shipping-source-before-probe".utf8)
        let mutated = Data("shipping-source-after-stage".utf8)
        try original.write(to: fixture.sourceURL)
        let snapshotter = R13ObservedSourceSnapshotter(
            sourceMeasurer: R13LocalRestartSourceMeasurer()
        )
        let frameCounter = R13ObservedSourceFrameCounter(frameCount: 1)
        let runtime = try makeRuntime(
            fixture: fixture,
            frameCounter: frameCounter,
            sourceSnapshotter: snapshotter
        )
        let events = R13ReleaseTestEventLog()
        let baseMedia = R13ReleaseTestMediaPipeline(
            resolution: .p720,
            frames: [
                try R13ReleaseTestFrames.make(
                    resolution: .p720,
                    index: 0
                )
            ],
            eventLog: events
        )
        let media = R13SourceBindingMediaPipeline(
            base: baseMedia,
            beforeProbe: {
                try mutated.write(to: fixture.sourceURL)
            }
        )
        let factory = R13ReleaseTestSessionFactory(
            behavior: .processed,
            eventLog: events
        )
        let service = R13ReleaseUpscalerEngineService(
            media: media,
            sessionFactory: { [factory] route in
                try await factory.make(route: route)
            },
            hardeningRuntime: runtime
        )
        let job = fixture.makeJob(identifier: "r13-snapshot-shipping")

        do {
            _ = try await service.submit(job).waitForCompletion()
            XCTFail("The test media session does not create an output file.")
        } catch {
            guard case .ioFailure(let operation) =
                    error as? R13RestartJobError else {
                return XCTFail("Unexpected service error: \(error)")
            }
            XCTAssertEqual(operation, "open_source")
        }

        let snapshot = try XCTUnwrap(snapshotter.createdSnapshots.first)
        XCTAssertEqual(media.probedURLs, [snapshot.processingURL])
        XCTAssertEqual(media.sessionSourceURLs, [snapshot.processingURL])
        XCTAssertEqual(frameCounter.measuredURLs, [snapshot.processingURL])
        XCTAssertEqual(
            baseMedia.lastSession?.sourceProfile.url,
            snapshot.processingURL
        )
        XCTAssertTrue(events.contains("media.next.0"))
        XCTAssertEqual(try Data(contentsOf: fixture.sourceURL), mutated)
        XCTAssertEqual(snapshotter.discardedDirectories, [
            snapshot.directoryURL
        ])
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: snapshot.directoryURL.path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.jobsRootURL
                    .appendingPathComponent(
                        job.identifier,
                        isDirectory: true
                    )
                    .path
            ),
            "A failed attempt must retain its restart cache."
        )
    }

    func testSuccessfulShippingDeletesSnapshotAndCompletedRestartCache()
        async throws {
        let fixture = try R13SourceSnapshotFixture()
        defer { fixture.cleanup() }
        try await writeOneFrameVideo(
            to: fixture.sourceURL,
            resolution: .p720,
            duration: CMTime(value: 1, timescale: 30)
        )
        let snapshotter = R13ObservedSourceSnapshotter(
            sourceMeasurer: R13LocalRestartSourceMeasurer()
        )
        let frameCounter = R13ObservedSourceFrameCounter(frameCount: 1)
        let runtime = try makeRuntime(
            fixture: fixture,
            frameCounter: frameCounter,
            sourceSnapshotter: snapshotter
        )
        let events = R13ReleaseTestEventLog()
        let factory = R13ReleaseTestSessionFactory(
            behavior: .processed,
            eventLog: events
        )
        let service = R13ReleaseUpscalerEngineService(
            media: AVFoundationMediaPipeline(
                metal: NoopMetalRenderingService()
            ),
            sessionFactory: { [factory] route in
                try await factory.make(route: route)
            },
            hardeningRuntime: runtime
        )
        let job = fixture.makeJob(identifier: "r13-snapshot-success")

        let result = try await service.submit(job).waitForCompletion()

        let snapshot = try XCTUnwrap(snapshotter.createdSnapshots.first)
        XCTAssertEqual(result, job.outputURL)
        XCTAssertEqual(frameCounter.measuredURLs, [
            snapshot.processingURL
        ])
        XCTAssertEqual(snapshotter.discardedDirectories, [
            snapshot.directoryURL
        ])
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: snapshot.directoryURL.path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.jobsRootURL
                    .appendingPathComponent(
                        job.identifier,
                        isDirectory: true
                    )
                    .path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: job.outputURL.path)
        )
    }

    private func makeRuntime(
        fixture: R13SourceSnapshotFixture,
        frameCounter: any R13SourceFrameCountMeasuring,
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
            jobsRootURL: fixture.jobsRootURL,
            sourceMeasurer: R13LocalRestartSourceMeasurer(),
            frameCounter: frameCounter,
            environmentCollector: try R13FixedEnvironmentCollector(),
            documents: documents,
            bookmarkResolver: R13TestBookmarkResolver(),
            storagePreflight: R13StoragePreflight(
                capacityProbe: R13CapacityProbe(capacity: UInt64.max)
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

private struct R13SourceSnapshotFixture {
    let rootURL: URL
    let jobsRootURL: URL
    let outputDirectoryURL: URL
    let sourceURL: URL

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "mirmir-r13-snapshot-\(UUID().uuidString)",
                isDirectory: true
            )
        jobsRootURL = rootURL.appendingPathComponent(
            "Jobs",
            isDirectory: true
        )
        outputDirectoryURL = rootURL.appendingPathComponent(
            "Output",
            isDirectory: true
        )
        sourceURL = rootURL.appendingPathComponent("source.mp4")
        try FileManager.default.createDirectory(
            at: jobsRootURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: outputDirectoryURL,
            withIntermediateDirectories: true
        )
    }

    func makeJob(identifier: String) -> UpscaleJob {
        UpscaleJob(
            identifier: identifier,
            inputURL: sourceURL,
            outputURL: outputDirectoryURL.appendingPathComponent(
                "\(identifier).mp4"
            ),
            targetResolution: .p1080,
            codec: .h264,
            preserveAudio: false,
            mode: .deterministic
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

private final class R13MutateAndRestoreSourceBarrier:
    R13SourceSnapshotCopyBarrier,
    @unchecked Sendable {
    let original: Data
    private let state = OSAllocatedUnfairLock(initialState: false)

    init(original: Data) {
        self.original = original
    }

    func didCopy(
        byteCount _: UInt64,
        from sourceURL: URL
    ) throws {
        let mustMutate = state.withLock { didMutate in
            guard !didMutate else { return false }
            didMutate = true
            return true
        }
        guard mustMutate else { return }
        try Data(repeating: 0xA5, count: original.count).write(
            to: sourceURL,
            options: .atomic
        )
        try original.write(to: sourceURL, options: .atomic)
    }
}

private final class R13ObservedSourceSnapshotter:
    R13SourceSnapshotting,
    @unchecked Sendable {
    private struct State {
        var createdSnapshots: [R13RetainedSourceSnapshot] = []
        var discardedDirectories: [URL] = []
    }

    private let base: R13LocalSourceSnapshotter
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(sourceMeasurer: any R13RestartSourceMeasuring) {
        base = R13LocalSourceSnapshotter(
            sourceMeasurer: sourceMeasurer
        )
    }

    var createdSnapshots: [R13RetainedSourceSnapshot] {
        state.withLock { $0.createdSnapshots }
    }

    var discardedDirectories: [URL] {
        state.withLock { $0.discardedDirectories }
    }

    func createSnapshot(
        sourceURL: URL,
        jobID: String,
        jobsRootURL: URL
    ) throws -> R13RetainedSourceSnapshot {
        let snapshot = try base.createSnapshot(
            sourceURL: sourceURL,
            jobID: jobID,
            jobsRootURL: jobsRootURL
        )
        state.withLock { $0.createdSnapshots.append(snapshot) }
        return snapshot
    }

    func discard(_ snapshot: R13RetainedSourceSnapshot) throws {
        try base.discard(snapshot)
        state.withLock {
            $0.discardedDirectories.append(snapshot.directoryURL)
        }
    }
}

private final class R13ObservedSourceFrameCounter:
    R13SourceFrameCountMeasuring,
    @unchecked Sendable {
    private let frameCount: Int
    private let state = OSAllocatedUnfairLock(initialState: [URL]())

    init(frameCount: Int) {
        self.frameCount = frameCount
    }

    var measuredURLs: [URL] {
        state.withLock { $0 }
    }

    func exactVideoFrameCount(at url: URL) async throws -> Int {
        state.withLock { $0.append(url) }
        return frameCount
    }
}

private final class R13SourceBindingMediaPipeline:
    MediaPipelineService,
    @unchecked Sendable {
    private struct State {
        var probedURLs: [URL] = []
        var sessionSourceURLs: [URL] = []
    }

    private let base: R13ReleaseTestMediaPipeline
    private let beforeProbe: @Sendable () throws -> Void
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(
        base: R13ReleaseTestMediaPipeline,
        beforeProbe: @escaping @Sendable () throws -> Void
    ) {
        self.base = base
        self.beforeProbe = beforeProbe
    }

    var probedURLs: [URL] {
        state.withLock { $0.probedURLs }
    }

    var sessionSourceURLs: [URL] {
        state.withLock { $0.sessionSourceURLs }
    }

    func probe(url: URL) async throws -> SourceProfile {
        state.withLock { $0.probedURLs.append(url) }
        try beforeProbe()
        return try await base.probe(url: url)
    }

    func beginSession(
        source: SourceProfile,
        output: OutputProfile
    ) async throws -> MediaSession {
        state.withLock { $0.sessionSourceURLs.append(source.url) }
        return try await base.beginSession(
            source: source,
            output: output
        )
    }

    func start() {
        base.start()
    }

    func stop() {
        base.stop()
    }
}

// swiftlint:disable:this file_length
