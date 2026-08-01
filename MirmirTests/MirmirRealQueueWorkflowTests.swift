import AVFoundation
import CoreMedia
import Foundation
import XCTest
@testable import Mirmir

@MainActor
final class MirmirRealQueueWorkflowTests: XCTestCase {
    // This acceptance intentionally crosses the shipping ViewModel, persistent
    // queue/history stores, AVFoundation media pipeline, and release engine.
    // swiftlint:disable:next function_body_length
    func testShippingViewModelRunsTwoPersistedQueuedH264VideosSerially()
        async throws {
        let workspace = try MirmirRealQueueWorkspace()
        defer { workspace.remove() }
        try await writeOneFrameVideo(
            to: workspace.firstSourceURL,
            resolution: .p720,
            duration: CMTime(value: 1, timescale: 30),
            codec: .h264
        )
        try await writeOneFrameVideo(
            to: workspace.secondSourceURL,
            resolution: .p720,
            duration: CMTime(value: 1, timescale: 30),
            codec: .h264
        )
        try await assertMirmirRealQueueH264Video(
            at: workspace.firstSourceURL,
            resolution: .p720
        )
        try await assertMirmirRealQueueH264Video(
            at: workspace.secondSourceURL,
            resolution: .p720
        )

        let harness = try R13IntegrationHardeningHarness.make(
            jobsRootURL: workspace.jobsRootURL,
            exactFrameCount: 1
        )
        let diagnostics = MirmirDiagnosticStore()
        let media = AVFoundationMediaPipeline(
            metal: NoopMetalRenderingService(),
            diagnostics: diagnostics
        )
        let engine = R13ReleaseUpscalerEngineService(
            media: media,
            hardeningRuntime: harness.runtime,
            diagnostics: diagnostics
        )
        let resolver = MirmirRealQueueBookmarkResolver()
        let preferencesSuite =
            "com.mirmir.tests.real-queue.\(UUID().uuidString)"
        let preferencesDefaults = try XCTUnwrap(
            UserDefaults(suiteName: preferencesSuite)
        )
        preferencesDefaults.removePersistentDomain(
            forName: preferencesSuite
        )
        defer {
            preferencesDefaults.removePersistentDomain(
                forName: preferencesSuite
            )
        }
        let preferencesStore = MirmirPreferencesStore(
            defaults: preferencesDefaults
        )
        let expectedConfiguration = UpscaleProcessingConfiguration(
            enginePreference: .accelerateVImageHighQuality,
            strategyPreference: .direct,
            temporalConsistencyEnabled: false,
            edgeFidelityLevel: .low,
            detailRecoveryLevel: .high,
            effects: .default,
            smoothMotion: SmoothMotionConfiguration(
                cadence: .quadruple,
                sceneCutSensitivity: .high
            )
        )

        var enqueuedRecords: [MirmirPendingWorkRecord] = []
        do {
            let enqueueQueue = MirmirPendingWorkQueue(
                directoryURL: workspace.queueDirectoryURL
            )
            let enqueueViewModel = MirmirViewModel(
                mediaPipeline: media,
                upscalerEngine: engine,
                modelAssets: NotRequiredModelAssetsService(),
                diagnostics: diagnostics,
                preferencesStore: preferencesStore,
                pendingWorkQueue: enqueueQueue,
                workHistoryBookmarkResolver: resolver,
                securityScopedResourceAccess:
                    mirmirRealQueueGrantedResourceAccess
            )
            try await waitForMirmirRealQueue(
                enqueueViewModel,
                count: 0,
                requireIdle: true
            )
            XCTAssertTrue(enqueueViewModel.selectDefaultMode(.quality))
            XCTAssertTrue(
                enqueueViewModel.selectDefaultOutputCodec(.h264)
            )
            XCTAssertTrue(
                enqueueViewModel.selectDefaultEngine(
                    .accelerateVImageHighQuality
                )
            )
            XCTAssertTrue(
                enqueueViewModel.selectDefaultStrategy(.direct)
            )
            XCTAssertTrue(
                enqueueViewModel.setDefaultTemporalConsistency(false)
            )
            XCTAssertTrue(
                enqueueViewModel.selectDefaultEdgeFidelity(.low)
            )
            XCTAssertTrue(
                enqueueViewModel.selectDefaultDetailRecovery(.high)
            )
            XCTAssertTrue(
                enqueueViewModel.setDefaultEdgePreservation(false)
            )
            XCTAssertTrue(
                enqueueViewModel.setDefaultCompressionCleanup(false)
            )
            XCTAssertTrue(
                enqueueViewModel.setDefaultTextureGrainProtection(false)
            )
            XCTAssertTrue(
                enqueueViewModel.setDefaultTemporalStability(false)
            )
            XCTAssertTrue(
                enqueueViewModel.selectDefaultSmoothMotionCadence(
                    .quadruple
                )
            )
            XCTAssertTrue(
                enqueueViewModel
                    .selectDefaultSmoothMotionSceneCutSensitivity(.high)
            )

            enqueueViewModel.enqueueSourceURLs(
                [
                    workspace.firstSourceURL,
                    workspace.secondSourceURL
                ],
                outputDirectoryURL: workspace.outputDirectoryURL
            )
            try await waitForMirmirRealQueue(
                enqueueViewModel,
                count: 2,
                requireIdle: true
            )
            enqueuedRecords = try await enqueueQueue.load().records
        }

        XCTAssertEqual(
            enqueuedRecords.map(\.bookmarks.sourceDisplayName),
            [
                workspace.firstSourceURL.lastPathComponent,
                workspace.secondSourceURL.lastPathComponent
            ]
        )
        XCTAssertEqual(enqueuedRecords.map(\.order), [0, 1])
        XCTAssertEqual(Set(enqueuedRecords.map(\.id)).count, 2)
        XCTAssertEqual(
            enqueuedRecords.map(\.settings.targetResolution),
            [.p1080, .p1080]
        )
        XCTAssertEqual(
            enqueuedRecords.map(\.settings.codec),
            [.h264, .h264]
        )
        XCTAssertEqual(
            enqueuedRecords.map(\.settings.requestedMode),
            [.quality, .quality]
        )
        XCTAssertEqual(
            enqueuedRecords.map(\.settings.processingConfiguration),
            [expectedConfiguration, expectedConfiguration]
        )
        XCTAssertEqual(
            enqueuedRecords.map(\.settings.preserveAudio),
            [false, false]
        )
        XCTAssertEqual(
            enqueuedRecords.map(\.bookmarks.sourceBookmark),
            [
                Data(workspace.firstSourceURL.standardizedFileURL.path.utf8),
                Data(workspace.secondSourceURL.standardizedFileURL.path.utf8)
            ]
        )
        XCTAssertEqual(
            enqueuedRecords.map(\.bookmarks.outputBookmark),
            [
                Data(
                    workspace.outputDirectoryURL.standardizedFileURL.path.utf8
                ),
                Data(
                    workspace.outputDirectoryURL.standardizedFileURL.path.utf8
                )
            ]
        )
        XCTAssertTrue(
            enqueuedRecords.allSatisfy {
                $0.state == .pending
                    && $0.startedAt == nil
                    && $0.bookmarks.outputDisplayName.hasSuffix(".mp4")
                    && $0.bookmarks.outputDisplayName.contains("_queue_")
            }
        )
        XCTAssertEqual(
            preferencesStore.load().defaultUpscaleMode,
            .quality
        )
        XCTAssertEqual(
            preferencesStore.load().defaultOutputCodec,
            .h264
        )
        XCTAssertEqual(
            MirmirPersistedJobDefaults(
                preferences: preferencesStore.load()
            ).processingConfiguration,
            expectedConfiguration
        )

        let outputURLs = enqueuedRecords.map {
            workspace.outputDirectoryURL.appendingPathComponent(
                $0.bookmarks.outputDisplayName,
                isDirectory: false
            )
        }
        let executionQueue = MirmirPendingWorkQueue(
            directoryURL: workspace.queueDirectoryURL
        )
        let historyStore = MirmirWorkHistoryStore(
            directoryURL: workspace.historyDirectoryURL
        )
        let executionViewModel = MirmirViewModel(
            mediaPipeline: media,
            upscalerEngine: engine,
            modelAssets: NotRequiredModelAssetsService(),
            diagnostics: diagnostics,
            preferencesStore: MirmirPreferencesStore(
                defaults: preferencesDefaults
            ),
            workHistoryStore: historyStore,
            pendingWorkQueue: executionQueue,
            workHistoryBookmarkResolver: resolver,
            workHistoryOutputIdentityMeasurer:
                R13LocalRestartSourceMeasurer(),
            securityScopedResourceAccess:
                mirmirRealQueueGrantedResourceAccess
        )
        try await waitForMirmirRealQueue(
            executionViewModel,
            ids: enqueuedRecords.map(\.id),
            requireIdle: true
        )
        try await waitForMirmirRealHistory(
            executionViewModel,
            count: 0
        )
        XCTAssertEqual(
            executionViewModel.persistedDefaults.processingConfiguration,
            expectedConfiguration
        )

        executionViewModel.startNextPendingWork()
        try await waitForMirmirRealQueueWorkflowCompletion(
            executionViewModel,
            expectedFinalOutputURL: outputURLs[1],
            expectedHistoryCount: 2
        )

        XCTAssertEqual(
            executionViewModel.state,
            .finished(outputURLs[1])
        )
        XCTAssertNil(executionViewModel.pendingQueueError)
        XCTAssertNil(executionViewModel.workHistoryError)
        let drainedQueue = try await executionQueue.load()
        XCTAssertEqual(drainedQueue.records, [])
        for outputURL in outputURLs {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: outputURL.path)
            )
            try await assertMirmirRealQueueH264Video(
                at: outputURL,
                resolution: .p1080
            )
        }

        let history = try await historyStore.snapshot().records
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(Set(history.map(\.id)), Set(enqueuedRecords.map(\.id)))
        let historyByID = Dictionary(
            uniqueKeysWithValues: history.map { ($0.id, $0) }
        )
        for (index, queued) in enqueuedRecords.enumerated() {
            let record = try XCTUnwrap(historyByID[queued.id])
            XCTAssertEqual(record.terminalResult, .completed)
            XCTAssertEqual(record.sourceBookmark, queued.bookmarks.sourceBookmark)
            XCTAssertEqual(
                record.outputBookmark,
                queued.bookmarks.outputBookmark
            )
            XCTAssertEqual(record.outputBookmarkScope, .directory)
            XCTAssertEqual(
                record.sourceDisplayName,
                queued.bookmarks.sourceDisplayName
            )
            XCTAssertEqual(
                record.outputDisplayName,
                queued.bookmarks.outputDisplayName
            )
            XCTAssertEqual(record.sourceResolution, .p720)
            XCTAssertEqual(record.targetResolution, .p1080)
            XCTAssertEqual(record.codec, .h264)
            XCTAssertEqual(record.sourceAudioTrackCount, 0)
            XCTAssertFalse(record.preserveAudio)
            XCTAssertEqual(record.requestedMode, .quality)
            XCTAssertEqual(
                record.processingConfiguration,
                expectedConfiguration
            )
            XCTAssertNotNil(record.startedAt)
            XCTAssertGreaterThanOrEqual(
                record.completedAt,
                try XCTUnwrap(record.startedAt)
            )
            XCTAssertEqual(
                record.outputVerification.availability,
                .available
            )
            let independentIdentity =
                try R13LocalRestartSourceMeasurer().measureSource(
                    at: outputURLs[index]
                )
            XCTAssertEqual(
                record.outputVerification.identity,
                independentIdentity.sha256
            )
        }
        let firstHistory = try XCTUnwrap(
            historyByID[enqueuedRecords[0].id]
        )
        let secondHistory = try XCTUnwrap(
            historyByID[enqueuedRecords[1].id]
        )
        XCTAssertLessThanOrEqual(
            firstHistory.completedAt,
            try XCTUnwrap(secondHistory.startedAt)
        )

        let governor = await harness.governor.snapshot()
        XCTAssertTrue(governor.activeLeaseIdentities.isEmpty)
        XCTAssertEqual(governor.reservedDiskBytes, 0)
        XCTAssertEqual(governor.reservedMemoryBytes, 0)
        XCTAssertEqual(governor.nextAdmissionOrdinal, 2)
        let hardeningDiagnostics = await harness.diagnostics.snapshot()
        XCTAssertEqual(
            hardeningDiagnostics.records.filter {
                $0.event.code == .outputReopened
            }.count,
            2
        )
        XCTAssertEqual(
            hardeningDiagnostics.records.filter {
                $0.event.code == .resourceReleased
            }.count,
            2
        )
        let recoverableJobs = try await engine.recoverableJobs()
        XCTAssertTrue(recoverableJobs.jobs.isEmpty)
    }
}

// The fixture resolver serializes temporary paths instead of creating real
// sandbox bookmarks, so it supplies the matching deterministic scope grant.
private let mirmirRealQueueGrantedResourceAccess =
    MirmirSecurityScopedResourceAccess(
        startAccessing: { _ in true },
        stopAccessing: { _ in },
        canCreateBookmark: { _ in true }
    )

private struct MirmirRealQueueWorkspace {
    let directoryURL: URL
    let firstSourceURL: URL
    let secondSourceURL: URL
    let outputDirectoryURL: URL
    let jobsRootURL: URL
    let queueDirectoryURL: URL
    let historyDirectoryURL: URL

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "mirmir-real-queue-\(UUID().uuidString)",
                isDirectory: true
            )
        firstSourceURL = directoryURL.appendingPathComponent(
            "first-source.mp4",
            isDirectory: false
        )
        secondSourceURL = directoryURL.appendingPathComponent(
            "second-source.mp4",
            isDirectory: false
        )
        outputDirectoryURL = directoryURL.appendingPathComponent(
            "Outputs",
            isDirectory: true
        )
        jobsRootURL = directoryURL.appendingPathComponent(
            "Jobs",
            isDirectory: true
        )
        queueDirectoryURL = directoryURL.appendingPathComponent(
            "Queue",
            isDirectory: true
        )
        historyDirectoryURL = directoryURL.appendingPathComponent(
            "History",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outputDirectoryURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: jobsRootURL,
            withIntermediateDirectories: true
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

private struct MirmirRealQueueBookmarkResolver:
    MirmirWorkHistoryBookmarkResolving {
    func makeBookmark(
        for url: URL,
        role _: MirmirWorkHistoryBookmarkRole
    ) throws -> Data {
        Data(url.standardizedFileURL.path.utf8)
    }

    func resolveBookmark(
        _ bookmark: Data,
        role: MirmirWorkHistoryBookmarkRole
    ) throws -> MirmirWorkHistoryResolvedBookmark {
        guard let path = String(data: bookmark, encoding: .utf8),
              path.hasPrefix("/") else {
            throw MirmirWorkHistoryBookmarkError
                .resolutionFailed(role: role)
        }
        return MirmirWorkHistoryResolvedBookmark(
            url: URL(
                fileURLWithPath: path,
                isDirectory: role == .output
            ),
            isStale: false
        )
    }
}

@MainActor
private func waitForMirmirRealQueue(
    _ viewModel: MirmirViewModel,
    ids: [String]? = nil,
    count: Int? = nil,
    requireIdle: Bool
) async throws {
    for _ in 0..<2_000 {
        if let error = viewModel.pendingQueueError {
            throw MirmirRealQueueAcceptanceError.queue(error)
        }
        let hasExpectedIDs =
            ids.map { viewModel.pendingWorkRecords.map(\.id) == $0 }
                ?? true
        let hasExpectedCount =
            count.map { viewModel.pendingWorkRecords.count == $0 }
                ?? true
        let isIdle = !requireIdle
            || (
                !viewModel.pendingQueueIsLoading
                    && !viewModel.pendingQueueMutationIsInProgress
            )
        if hasExpectedIDs, hasExpectedCount, isIdle {
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw MirmirRealQueueAcceptanceError.timeout(
        "queue IDs \(viewModel.pendingWorkRecords.map(\.id)); "
            + "loading \(viewModel.pendingQueueIsLoading); "
            + "mutating \(viewModel.pendingQueueMutationIsInProgress)"
    )
}

@MainActor
private func waitForMirmirRealHistory(
    _ viewModel: MirmirViewModel,
    count: Int
) async throws {
    for _ in 0..<2_000 {
        if let error = viewModel.workHistoryError {
            throw MirmirRealQueueAcceptanceError.history(error)
        }
        if !viewModel.workHistoryIsLoading,
           viewModel.workHistoryRecords.count == count {
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw MirmirRealQueueAcceptanceError.timeout(
        "history count \(viewModel.workHistoryRecords.count); "
            + "loading \(viewModel.workHistoryIsLoading)"
    )
}

@MainActor
private func waitForMirmirRealQueueWorkflowCompletion(
    _ viewModel: MirmirViewModel,
    expectedFinalOutputURL: URL,
    expectedHistoryCount: Int
) async throws {
    for _ in 0..<6_000 {
        if let error = viewModel.pendingQueueError {
            throw MirmirRealQueueAcceptanceError.queue(error)
        }
        if let error = viewModel.workHistoryError {
            throw MirmirRealQueueAcceptanceError.history(error)
        }
        if case .failed(let reason) = viewModel.state {
            throw MirmirRealQueueAcceptanceError.workflow(reason)
        }
        let reachedExpectedOutput =
            viewModel.state == .finished(expectedFinalOutputURL)
        if reachedExpectedOutput,
           viewModel.pendingWorkRecords.isEmpty,
           !viewModel.pendingQueueIsLoading,
           !viewModel.pendingQueueMutationIsInProgress,
           !viewModel.workHistoryIsLoading,
           viewModel.workHistoryRecords.count == expectedHistoryCount {
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw MirmirRealQueueAcceptanceError.timeout(
        "workflow state \(String(describing: viewModel.state)); "
            + "queue count \(viewModel.pendingWorkRecords.count); "
            + "history count \(viewModel.workHistoryRecords.count)"
    )
}

private func assertMirmirRealQueueH264Video(
    at url: URL,
    resolution: VideoResolution
) async throws {
    let asset = AVURLAsset(
        url: url,
        options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
    )
    let isPlayable = try await asset.load(.isPlayable)
    XCTAssertTrue(isPlayable)
    let tracks = try await asset.loadTracks(withMediaType: .video)
    XCTAssertEqual(tracks.count, 1)
    let track = try XCTUnwrap(tracks.first)
    let formats = try await track.load(.formatDescriptions)
    let format = try XCTUnwrap(formats.first)
    XCTAssertEqual(
        CMFormatDescriptionGetMediaSubType(format),
        kCMVideoCodecType_H264
    )
    let dimensions = CMVideoFormatDescriptionGetDimensions(format)
    XCTAssertEqual(Int(dimensions.width), resolution.width)
    XCTAssertEqual(Int(dimensions.height), resolution.height)
}

private enum MirmirRealQueueAcceptanceError:
    Error,
    CustomStringConvertible {
    case queue(String)
    case history(String)
    case workflow(String)
    case timeout(String)

    var description: String {
        switch self {
        case .queue(let reason):
            return "Queue failure: \(reason)"
        case .history(let reason):
            return "History failure: \(reason)"
        case .workflow(let reason):
            return "Workflow failure: \(reason)"
        case .timeout(let state):
            return "Timed out: \(state)"
        }
    }
}
