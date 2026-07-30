import AVFoundation
import CoreMedia
import Foundation
import XCTest
@testable import Mirmir

final class R13ReleaseIntegrationTests: XCTestCase {
    func testWriterFileTypeMatchesDestinationContainerExtension() throws {
        XCTAssertEqual(
            try AVFoundationMediaSession.writerFileType(
                for: URL(fileURLWithPath: "/output.mp4")
            ),
            .mp4
        )
        XCTAssertEqual(
            try AVFoundationMediaSession.writerFileType(
                for: URL(fileURLWithPath: "/output.MOV")
            ),
            .mov
        )
        XCTAssertThrowsError(
            try AVFoundationMediaSession.writerFileType(
                for: URL(fileURLWithPath: "/output.avi")
            )
        ) { error in
            guard let pipelineError = error as? MediaPipelineError,
                  case .unsupportedOutputContainer(let pathExtension) =
                    pipelineError else {
                return XCTFail(
                    "Expected unsupported output-container error, got \(error)."
                )
            }
            XCTAssertEqual(pathExtension, "avi")
        }
    }

    func testShippingServiceBindsExactReleaseIdentityAndReopensControlledMetadata() async throws {
        let mustExportAcceptanceOutput = ProcessInfo.processInfo.environment[
            "R13_ACCEPTANCE_OUTPUT_ARTIFACT_PATH"
        ] != nil
        let workspace = try R13IntegrationWorkspace()
        defer { workspace.remove() }
        try await writeOneFrameVideo(
            to: workspace.sourceURL,
            resolution: .p720,
            duration: CMTime(value: 1, timescale: 30)
        )
        let harness = try R13IntegrationHardeningHarness.make(
            jobsRootURL: workspace.jobsRootURL,
            exactFrameCount: 1
        )
        let media = AVFoundationMediaPipeline(
            metal: NoopMetalRenderingService()
        )
        let service = R13ReleaseUpscalerEngineService(
            media: media,
            hardeningRuntime: harness.runtime
        )
        let job = makeR13IntegrationJob(
            identifier: "r13-acceptance-output",
            workspace: workspace,
            mode: .quality
        )

        let result = try await service.submit(job).waitForCompletion()

        XCTAssertEqual(result, workspace.outputURL)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: workspace.outputURL.path
            )
        )
        XCTAssertEqual(
            try readR13ISOBaseMediaMajorBrand(at: workspace.outputURL),
            "qt  "
        )
        let expectedIdentity = try makeR13ExpectedIntegrationIdentity(
            job: job,
            workspace: workspace,
            harness: harness
        )
        let metadata = try await readR13ReleaseMetadata(
            at: workspace.outputURL
        )
        XCTAssertEqual(metadata, expectedIdentity.timedMetadata)
        try expectedIdentity.validateTimedMetadata(metadata)
        try await assertR13ReopenedOutput(
            at: workspace.outputURL,
            resolution: .p1080
        )
        XCTAssertEqual(
            harness.capacityObservation.labels,
            try expectedR13IntegrationCapacityLabels(
                for: workspace,
                liveRecheckCountsByAttempt: [2]
            )
        )
        try await assertR13SuccessfulResourceClosure(
            service: service,
            harness: harness
        )
        if mustExportAcceptanceOutput {
            let payload = try Data(contentsOf: workspace.outputURL)
                .base64EncodedString()
            print("R13_ACCEPTANCE_OUTPUT_BASE64=\(payload)")
        }
    }

    func testShippingServiceResumesInterruptedJobWithStableIDAndExactCachedPrefixReplay() async throws {
        let workspace = try R13IntegrationWorkspace()
        defer { workspace.remove() }
        let originalSource = Data("stable-r13-source".utf8)
        try workspace.writeOpaqueSource(originalSource)
        let frames = try makeR13IntegrationFrames(count: 3)
        let media = R13IntegrationMediaPipeline(
            resolution: .p720,
            frames: frames,
            estimatedFrameCount: 3,
            failureThresholds: [2, nil]
        )
        let harness = try R13IntegrationHardeningHarness.make(
            jobsRootURL: workspace.jobsRootURL,
            exactFrameCount: 3
        )
        let eventLog = R13ReleaseTestEventLog()
        let factory = R13ReleaseTestSessionFactory(
            behavior: .processed,
            eventLog: eventLog
        )
        let service = makeR13IntegrationService(
            media: media,
            factory: factory,
            hardeningRuntime: harness.runtime,
            eventLog: eventLog
        )
        let job = makeR13IntegrationJob(
            identifier: "r13-stable-resume",
            workspace: workspace
        )

        try await assertR13Interrupted(service.submit(job))
        let firstBackend = try XCTUnwrap(
            factory.session(for: .scale3Over2)
        )
        let firstBackendSnapshot = await firstBackend.snapshot()
        XCTAssertEqual(
            firstBackendSnapshot.submittedSequenceNumbers,
            [0, 1]
        )

        try workspace.writeOpaqueSource(Data("drifted-r13-source".utf8))
        try await assertR13SourceDrift(service.submit(job))
        XCTAssertEqual(media.beginSessionCount, 1)
        XCTAssertEqual(factory.routes, [.scale3Over2])

        try workspace.writeOpaqueSource(originalSource)
        let result = try await service.submit(job).waitForCompletion()

        XCTAssertEqual(result, workspace.outputURL)
        XCTAssertEqual(media.beginSessionCount, 2)
        XCTAssertEqual(media.sessions[1].appendedFrameIndices, [0, 1, 2])
        let resumedBackend = try XCTUnwrap(
            factory.session(for: .scale3Over2)
        )
        let resumedBackendSnapshot = await resumedBackend.snapshot()
        XCTAssertEqual(
            resumedBackendSnapshot.submittedSequenceNumbers,
            [2]
        )
        XCTAssertEqual(
            harness.capacityObservation.labels,
            try expectedR13IntegrationCapacityLabels(
                for: workspace,
                liveRecheckCountsByAttempt: [2, 4]
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: workspace.outputURL.path
            )
        )
    }

    func testShippingServiceFaultsNeverPublishAndReleaseEveryResourceExactlyOnce() async throws {
        for faultPoint in R13FaultPoint.allCases {
            let workspace = try R13IntegrationWorkspace()
            defer { workspace.remove() }
            try workspace.writeOpaqueSource(
                Data("fault-\(faultPoint.rawValue)".utf8)
            )
            let frames = try makeR13IntegrationFrames(count: 1)
            let media = R13IntegrationMediaPipeline(
                resolution: .p720,
                frames: frames,
                estimatedFrameCount: 1
            )
            let harness = try R13IntegrationHardeningHarness.make(
                jobsRootURL: workspace.jobsRootURL,
                exactFrameCount: 1,
                faultPoint: faultPoint
            )
            let eventLog = R13ReleaseTestEventLog()
            let factory = R13ReleaseTestSessionFactory(
                behavior: .processed,
                eventLog: eventLog
            )
            let service = makeR13IntegrationService(
                media: media,
                factory: factory,
                hardeningRuntime: harness.runtime,
                eventLog: eventLog
            )
            let job = makeR13IntegrationJob(
                identifier: "r13-fault-\(faultPoint.rawValue)",
                workspace: workspace
            )

            try await assertR13InjectedFault(
                service.submit(job),
                point: faultPoint
            )
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: workspace.outputURL.path
                )
            )
            try await assertR13FaultResourceClosure(
                harness: harness,
                faultPoint: faultPoint
            )
            assertR13FrameResources(
                eventLog: eventLog,
                faultPoint: faultPoint
            )
        }
    }

    func testShippingServiceUsesExactSourceFrameCountNotEstimatedFrameCount() async throws {
        let successful = try R13IntegrationWorkspace()
        defer { successful.remove() }
        try successful.writeOpaqueSource(Data("exact-count-success".utf8))
        let successfulFrames = try makeR13IntegrationFrames(count: 2)
        let successfulMedia = R13IntegrationMediaPipeline(
            resolution: .p720,
            frames: successfulFrames,
            estimatedFrameCount: 999
        )
        let successfulHarness = try R13IntegrationHardeningHarness.make(
            jobsRootURL: successful.jobsRootURL,
            exactFrameCount: 2
        )
        let successfulFactory = R13ReleaseTestSessionFactory(
            behavior: .processed,
            eventLog: R13ReleaseTestEventLog()
        )
        let successfulService = makeR13IntegrationService(
            media: successfulMedia,
            factory: successfulFactory,
            hardeningRuntime: successfulHarness.runtime
        )
        let successfulJob = makeR13IntegrationJob(
            identifier: "r13-exact-count-success",
            workspace: successful
        )

        _ = try await successfulService
            .submit(successfulJob)
            .waitForCompletion()
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: successful.outputURL.path
            )
        )

        let failing = try R13IntegrationWorkspace()
        defer { failing.remove() }
        try failing.writeOpaqueSource(Data("exact-count-failure".utf8))
        let failingMedia = R13IntegrationMediaPipeline(
            resolution: .p720,
            frames: successfulFrames,
            estimatedFrameCount: 2
        )
        let failingHarness = try R13IntegrationHardeningHarness.make(
            jobsRootURL: failing.jobsRootURL,
            exactFrameCount: 3
        )
        let failingFactory = R13ReleaseTestSessionFactory(
            behavior: .processed,
            eventLog: R13ReleaseTestEventLog()
        )
        let failingService = makeR13IntegrationService(
            media: failingMedia,
            factory: failingFactory,
            hardeningRuntime: failingHarness.runtime
        )
        let failingJob = makeR13IntegrationJob(
            identifier: "r13-exact-count-failure",
            workspace: failing
        )

        try await assertR13FrameCountMismatch(
            failingService.submit(failingJob),
            expected: 3,
            actual: 2
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: failing.outputURL.path
            )
        )
    }

}

private func makeR13IntegrationFrames(
    count: Int
) throws -> [FrameRecord] {
    try (0..<count).map {
        try R13ReleaseTestFrames.make(
            resolution: .p720,
            index: $0
        )
    }
}

private func makeR13ExpectedIntegrationIdentity(
    job: UpscaleJob,
    workspace: R13IntegrationWorkspace,
    harness: R13IntegrationHardeningHarness
) throws -> R13ReleaseIdentity {
    try R13ReleaseHardeningRuntime.makeReleaseIdentity(
        job: job,
        route: .scale3Over2,
        modeBinding: R13ReleaseModePolicy.binding(for: job.mode),
        source: R13LocalRestartSourceMeasurer().measureSource(
            at: workspace.sourceURL
        ),
        environment: harness.environment,
        policyResources: harness.documents.policyResources
    )
}

func assertR13ReopenedOutput(
    at url: URL,
    resolution: VideoResolution
) async throws {
    let asset = AVURLAsset(url: url)
    let tracks = try await asset.loadTracks(withMediaType: .video)
    XCTAssertEqual(tracks.count, 1)
    let size = try await XCTUnwrap(tracks.first).load(.naturalSize)
    XCTAssertEqual(Int(abs(size.width).rounded()), resolution.width)
    XCTAssertEqual(Int(abs(size.height).rounded()), resolution.height)
}

private func assertR13SuccessfulResourceClosure(
    service: R13ReleaseUpscalerEngineService,
    harness: R13IntegrationHardeningHarness
) async throws {
    let governor = await harness.governor.snapshot()
    XCTAssertTrue(governor.activeLeaseIdentities.isEmpty)
    XCTAssertEqual(governor.reservedDiskBytes, 0)
    XCTAssertEqual(governor.reservedMemoryBytes, 0)
    XCTAssertEqual(governor.nextAdmissionOrdinal, 1)
    let diagnostics = await harness.diagnostics.snapshot()
    XCTAssertEqual(
        diagnostics.records.filter {
            $0.event.code == .outputReopened
        }.count,
        1
    )
    XCTAssertEqual(
        diagnostics.records.filter {
            $0.event.code == .resourceReleased
        }.count,
        1
    )
    let recoverableJobs = try await service.recoverableJobs()
    XCTAssertTrue(recoverableJobs.jobs.isEmpty)
}

private func assertR13Interrupted(
    _ handle: UpscalerJobHandle
) async throws {
    do {
        _ = try await handle.waitForCompletion()
        XCTFail("An interrupted writer must not complete.")
    } catch R13IntegrationMediaError.interrupted {
        return
    }
}

private func assertR13SourceDrift(
    _ handle: UpscalerJobHandle
) async throws {
    do {
        _ = try await handle.waitForCompletion()
        XCTFail("A changed source must not reopen cached frames.")
    } catch R13RestartJobError.sourceDrift {
        return
    }
}

private func assertR13InjectedFault(
    _ handle: UpscalerJobHandle,
    point: R13FaultPoint
) async throws {
    do {
        _ = try await handle.waitForCompletion()
        XCTFail("Injected fault \(point.rawValue) must terminate.")
    } catch let error as R13ReleaseHardeningError {
        XCTAssertEqual(
            error,
            .injectedFault(point: point, fault: .diskFull)
        )
    }
}

private func assertR13FaultResourceClosure(
    harness: R13IntegrationHardeningHarness,
    faultPoint: R13FaultPoint
) async throws {
    let governor = await harness.governor.snapshot()
    XCTAssertTrue(governor.activeLeaseIdentities.isEmpty)
    XCTAssertEqual(governor.reservedDiskBytes, 0)
    XCTAssertEqual(governor.reservedMemoryBytes, 0)
    let expectedAdmissionCount =
        faultPoint == .beforeResourceAdmission ? 0 : 1
    XCTAssertEqual(
        governor.nextAdmissionOrdinal,
        UInt64(expectedAdmissionCount)
    )
    let diagnostics = await harness.diagnostics.snapshot()
    XCTAssertEqual(
        diagnostics.records.filter {
            $0.event.code == .resourceReleased
        }.count,
        expectedAdmissionCount
    )
}

private func assertR13FrameResources(
    eventLog: R13ReleaseTestEventLog,
    faultPoint: R13FaultPoint
) {
    let reachedFrameLoop = faultPoint == .beforeOutputFinalize
        || faultPoint == .beforeMetadataReopen
    let expectedCount = reachedFrameLoop ? 1 : 0
    XCTAssertEqual(
        countR13IntegrationEvents(
            "input.release.r13.a11.input.deterministic.0",
            in: eventLog
        ),
        expectedCount
    )
    XCTAssertEqual(
        countR13IntegrationEvents(
            "output.release.0",
            in: eventLog
        ),
        expectedCount
    )
}

private func assertR13FrameCountMismatch(
    _ handle: UpscalerJobHandle,
    expected: Int,
    actual: Int
) async throws {
    do {
        _ = try await handle.waitForCompletion()
        XCTFail("Exact decoded-frame mismatch must terminate.")
    } catch let error as R13ReleaseHardeningError {
        XCTAssertEqual(
            error,
            .outputFrameCountMismatch(
                expected: expected,
                actual: actual
            )
        )
    }
}
