import Foundation
import os.lock
import XCTest
@testable import Mirmir

private let adaptiveSourceResolution = VideoResolution(width: 640, height: 360)
private let adaptiveTargetResolution = VideoResolution(width: 1_280, height: 720)

final class R13ReleaseTestAdaptiveScaler:
    R03NV12Scaling,
    @unchecked Sendable {
    typealias SourceObserver =
        @Sendable (CVPixelBuffer) throws -> Void
    typealias DestinationFiller =
        @Sendable (CVPixelBuffer) throws -> Void

    private let plan: R13AdaptiveScalePlan
    private let eventLog: R13ReleaseTestEventLog
    private let sourceObserver: SourceObserver
    private let destinationFiller: DestinationFiller

    init(
        plan: R13AdaptiveScalePlan,
        eventLog: R13ReleaseTestEventLog,
        sourceObserver: @escaping SourceObserver = { _ in },
        destinationFiller: @escaping DestinationFiller = { _ in }
    ) {
        self.plan = plan
        self.eventLog = eventLog
        self.sourceObserver = sourceObserver
        self.destinationFiller = destinationFiller
    }

    func scale(
        source: CVPixelBuffer,
        destination: CVPixelBuffer,
        cancellation: AppleUpscaleOperationCancellationSignal
    ) throws {
        guard !cancellation.isCancelled else {
            throw R03NV12ScalingError.operationCancelled
        }
        try R03NV12Contract.validate(
            pixelBuffer: source,
            resolution: plan.processingSourceResolution
        )
        try R03NV12Contract.validate(
            pixelBuffer: destination,
            resolution: plan.targetResolution
        )
        try sourceObserver(source)
        try destinationFiller(destination)
        eventLog.record("adaptive.scale")
    }

    func finish() {
        eventLog.record("adaptive.finish")
    }

    func cancel() {
        eventLog.record("adaptive.cancel")
    }
}

final class R13AdaptiveHardeningIntegrationTests: XCTestCase {
    func testResourceRejectionPrecedesAdaptiveScalerAndMediaSession()
        async throws {
        let workspace = try R13IntegrationWorkspace()
        defer { workspace.remove() }
        try workspace.writeOpaqueSource(
            Data("adaptive-resource-rejection".utf8)
        )
        let eventLog = R13ReleaseTestEventLog()
        let media = R13IntegrationMediaPipeline(
            resolution: adaptiveSourceResolution,
            frames: try makeFrames(count: 1),
            estimatedFrameCount: 1
        )
        let harness = try R13IntegrationHardeningHarness.make(
            jobsRootURL: workspace.jobsRootURL,
            exactFrameCount: 1,
            resourceDiskBytes: 0
        )
        let factory = R13ReleaseTestSessionFactory(
            behavior: .processed,
            eventLog: eventLog
        )
        let service = makeService(
            media: media,
            factory: factory,
            hardeningRuntime: harness.runtime,
            eventLog: eventLog
        )

        do {
            _ = try await service.submit(
                makeJob(
                    identifier: "r13-adaptive-resource-rejection",
                    workspace: workspace
                )
            ).waitForCompletion()
            XCTFail("Rejected resources must terminate the adaptive job.")
        } catch let error as R13ReleaseHardeningError {
            guard case .resourceRejected(let rejection) = error else {
                return XCTFail(
                    "Expected resource rejection, got \(error)."
                )
            }
            guard case .insufficientDisk = rejection else {
                return XCTFail(
                    "Expected insufficient disk, got \(rejection)."
                )
            }
        } catch {
            return XCTFail("Expected resource rejection, got \(error).")
        }

        XCTAssertEqual(media.beginSessionCount, 0)
        XCTAssertTrue(factory.routes.isEmpty)
        XCTAssertFalse(eventLog.contains("adaptive.factory"))
        XCTAssertFalse(eventLog.contains("adaptive.scale"))
        let governor = await harness.governor.snapshot()
        XCTAssertTrue(governor.activeLeaseIdentities.isEmpty)
        XCTAssertEqual(governor.reservedDiskBytes, 0)
        XCTAssertEqual(governor.reservedMemoryBytes, 0)
        XCTAssertEqual(governor.nextAdmissionOrdinal, 0)
        let diagnostics = await harness.diagnostics.snapshot()
        XCTAssertEqual(
            diagnosticCount(.resourceRejected, in: diagnostics),
            1
        )
        XCTAssertEqual(
            diagnosticCount(.resourceReleased, in: diagnostics),
            0
        )
        let recoverable = try await service.recoverableJobs()
        XCTAssertTrue(recoverable.jobs.isEmpty)
    }

    func testInterruptedAdaptiveJobReplaysOnlyVerifiedCachedPrefix()
        async throws {
        let workspace = try R13IntegrationWorkspace()
        defer { workspace.remove() }
        let originalSource = Data("adaptive-stable-source".utf8)
        try workspace.writeOpaqueSource(originalSource)
        let eventLog = R13ReleaseTestEventLog()
        let frames = try makeFrames(count: 3)
        let media = R13IntegrationMediaPipeline(
            resolution: adaptiveSourceResolution,
            frames: frames,
            estimatedFrameCount: 3,
            failureThresholds: [2, nil]
        )
        let harness = try R13IntegrationHardeningHarness.make(
            jobsRootURL: workspace.jobsRootURL,
            exactFrameCount: 3
        )
        let scalerInputs = OSAllocatedUnfairLock(
            initialState: [R13NV12Frame]()
        )
        let factory = R13ReleaseTestSessionFactory(
            behavior: .processed,
            eventLog: eventLog
        )
        let service = makeService(
            media: media,
            factory: factory,
            hardeningRuntime: harness.runtime,
            eventLog: eventLog,
            sourceObserver: { input in
                let frame = try R13NV12Frame
                    .captureTightActivePlanes(from: input)
                scalerInputs.withLock { $0.append(frame) }
            }
        )
        let job = makeJob(
            identifier: "r13-adaptive-stable-resume",
            workspace: workspace
        )

        await assertInterrupted(try service.submit(job))

        XCTAssertEqual(media.beginSessionCount, 1)
        XCTAssertEqual(
            try XCTUnwrap(media.sessions.first).appendedFrameIndices,
            [0, 1]
        )
        XCTAssertEqual(eventCount("adaptive.factory", in: eventLog), 1)
        XCTAssertEqual(eventCount("adaptive.scale", in: eventLog), 2)
        XCTAssertEqual(eventCount("adaptive.cancel", in: eventLog), 1)
        XCTAssertEqual(eventCount("adaptive.finish", in: eventLog), 0)

        try workspace.writeOpaqueSource(
            Data("adaptive-drifted-source".utf8)
        )
        await assertSourceDrift(try service.submit(job))

        XCTAssertEqual(media.beginSessionCount, 1)
        XCTAssertEqual(eventCount("adaptive.factory", in: eventLog), 1)
        XCTAssertEqual(eventCount("adaptive.scale", in: eventLog), 2)

        try workspace.writeOpaqueSource(originalSource)
        let result = try await service.submit(job).waitForCompletion()

        XCTAssertEqual(result, workspace.outputURL)
        assertResumeFrameProcessing(
            media: media,
            eventLog: eventLog,
            factory: factory
        )
        let baselineProcessor =
            try R13ReleaseFormatEnhancementProcessor(
                targetResolution: adaptiveSourceResolution,
                videoFormat: .sdrBT709,
                temporalConsistencyEnabled: true,
                edgeFidelityLevel: .medium,
                detailRecoveryLevel: .medium,
                edgePreservationEnabled: false,
                compressionCleanupEnabled: false,
                textureGrainProtectionEnabled: false,
                temporalStabilityEnabled: false
            )
        defer { baselineProcessor.cancel() }
        let baselineNormalizer = R13NV12FrameNormalizer()
        var baselineFrame: CVPixelBuffer?
        for record in frames {
            let normalized = try baselineNormalizer
                .normalizeForAdaptiveScaling(
                    record.pixelBuffer,
                    codedResolution: adaptiveSourceResolution,
                    presentationResolution: adaptiveSourceResolution,
                    processingResolution: adaptiveSourceResolution,
                    pixelAspectRatio: nil
                )
            baselineFrame = try baselineProcessor.process(normalized)
        }
        let expectedResumedInput = try R13NV12Frame
            .captureTightActivePlanes(
                from: try XCTUnwrap(baselineFrame)
            )
        XCTAssertEqual(
            scalerInputs.withLock { $0.last },
            expectedResumedInput,
            "Adaptive cached-prefix replay must rebuild source-domain "
                + "temporal enhancement before scaling the suffix."
        )
        try await assertResumeHardeningClosure(
            job: job,
            workspace: workspace,
            media: media,
            harness: harness,
            service: service
        )
    }

    func testAdaptivePrepublicationRejectsMetadataAndSourceDrift()
        async throws {
        let workspace = try R13IntegrationWorkspace()
        defer { workspace.remove() }
        try workspace.writeOpaqueSource(
            Data("adaptive-prepublication-source".utf8)
        )
        let harness = try R13IntegrationHardeningHarness.make(
            jobsRootURL: workspace.jobsRootURL,
            exactFrameCount: 1
        )
        let job = makeJob(
            identifier: "r13-adaptive-prepublication",
            workspace: workspace
        )
        let stagedSource = try await harness.runtime.stageSource(for: job)
        let source = SourceProfile(
            url: stagedSource.processingURL,
            resolution: adaptiveSourceResolution,
            frameRate: 30,
            durationSeconds: 1.0 / 30.0,
            estimatedFrameCount: 1,
            codecHint: "r13-adaptive-test",
            hasAudio: false
        )
        let scalePlan = try R13ReleaseJobContracts.scalePlan(
            source: adaptiveSourceResolution,
            target: adaptiveTargetResolution
        )
        let attempt = try await harness.runtime.prepare(
            job: job,
            source: source,
            scalePlan: scalePlan,
            modeBinding: R13ReleaseModePolicy.binding(for: job.mode),
            stagedSource: stagedSource
        )
        var invalidMetadata = attempt.identity.timedMetadata
        invalidMetadata["com.mirmir.release.backend-id"] =
            "tampered.backend.identity"

        await assertMetadataMismatch(
            attempt: attempt,
            outputURL: workspace.outputURL,
            metadata: invalidMetadata
        )
        do {
            try Data("adaptive-staged-source-drift".utf8).write(
                to: attempt.processingSourceURL,
                options: .atomic
            )
        } catch {
            _ = await attempt.releaseResources()
            throw error
        }
        await assertPrepublicationSourceDrift(
            attempt: attempt,
            outputURL: workspace.outputURL
        )
        _ = await attempt.releaseResources()

        let diagnostics = await harness.diagnostics.snapshot()
        XCTAssertEqual(
            diagnosticCount(.outputReopened, in: diagnostics),
            0
        )
        XCTAssertEqual(
            diagnosticCount(.resourceReleased, in: diagnostics),
            1
        )
        let governor = await harness.governor.snapshot()
        XCTAssertTrue(governor.activeLeaseIdentities.isEmpty)
        XCTAssertEqual(governor.reservedDiskBytes, 0)
        XCTAssertEqual(governor.reservedMemoryBytes, 0)
        XCTAssertEqual(governor.nextAdmissionOrdinal, 1)
    }

    private func makeFrames(count: Int) throws -> [FrameRecord] {
        try (0..<count).map {
            try R13ReleaseTestFrames.make(
                resolution: adaptiveSourceResolution,
                index: $0
            )
        }
    }

    private func makeJob(
        identifier: String,
        workspace: R13IntegrationWorkspace
    ) -> UpscaleJob {
        UpscaleJob(
            identifier: identifier,
            inputURL: workspace.sourceURL,
            outputURL: workspace.outputURL,
            targetResolution: adaptiveTargetResolution,
            codec: .h264,
            preserveAudio: false,
            mode: .deterministic
        )
    }

    private func makeService(
        media: MediaPipelineService,
        factory: R13ReleaseTestSessionFactory,
        hardeningRuntime: R13ReleaseHardeningRuntime,
        eventLog: R13ReleaseTestEventLog,
        sourceObserver:
            @escaping R13ReleaseTestAdaptiveScaler.SourceObserver = {
                _ in
            }
    ) -> R13ReleaseUpscalerEngineService {
        R13ReleaseUpscalerEngineService(
            media: media,
            sessionFactory: { [factory] route in
                try await factory.make(route: route)
            },
            adaptiveScalerFactory: { [eventLog] plan in
                eventLog.record("adaptive.factory")
                return R13ReleaseTestAdaptiveScaler(
                    plan: plan,
                    eventLog: eventLog,
                    sourceObserver: sourceObserver
                )
            },
            hardeningRuntime: hardeningRuntime
        )
    }

    private func assertResumeFrameProcessing(
        media: R13IntegrationMediaPipeline,
        eventLog: R13ReleaseTestEventLog,
        factory: R13ReleaseTestSessionFactory
    ) {
        XCTAssertEqual(media.beginSessionCount, 2)
        XCTAssertEqual(media.sessions[1].appendedFrameIndices, [0, 1, 2])
        XCTAssertEqual(eventCount("adaptive.factory", in: eventLog), 2)
        XCTAssertEqual(
            eventCount("adaptive.scale", in: eventLog),
            3,
            "Only frame 2 may be rescaled after cached frames 0 and 1."
        )
        XCTAssertEqual(eventCount("adaptive.cancel", in: eventLog), 1)
        XCTAssertEqual(eventCount("adaptive.finish", in: eventLog), 1)
        XCTAssertTrue(factory.routes.isEmpty)
    }

    private func assertResumeHardeningClosure(
        job: UpscaleJob,
        workspace: R13IntegrationWorkspace,
        media: R13IntegrationMediaPipeline,
        harness: R13IntegrationHardeningHarness,
        service: R13ReleaseUpscalerEngineService
    ) async throws {
        let expectedIdentity = try makeExpectedIdentity(
            job: job,
            workspace: workspace,
            harness: harness
        )
        XCTAssertEqual(
            media.sessions[1].finalMetadata,
            expectedIdentity.timedMetadata
        )
        try expectedIdentity.validateTimedMetadata(
            media.sessions[1].finalMetadata
        )
        let modeBinding = R13ReleaseModePolicy.binding(for: job.mode)
        XCTAssertEqual(
            expectedIdentity.backendID,
            modeBinding.backendID
        )
        XCTAssertEqual(
            expectedIdentity.routeID,
            modeBinding.scalerKind.adaptiveRouteID
        )

        let diagnostics = await harness.diagnostics.snapshot()
        XCTAssertEqual(
            diagnosticCount(.cacheFrameCommitted, in: diagnostics),
            3
        )
        XCTAssertEqual(
            diagnosticCount(.cacheFrameReplayed, in: diagnostics),
            2
        )
        XCTAssertEqual(
            diagnosticCount(.outputReopened, in: diagnostics),
            1
        )
        XCTAssertEqual(
            diagnosticCount(.resourceReleased, in: diagnostics),
            2
        )
        XCTAssertEqual(
            diagnosticCount(.jobCompleted, in: diagnostics),
            1
        )
        let governor = await harness.governor.snapshot()
        XCTAssertTrue(governor.activeLeaseIdentities.isEmpty)
        XCTAssertEqual(governor.reservedDiskBytes, 0)
        XCTAssertEqual(governor.reservedMemoryBytes, 0)
        XCTAssertEqual(governor.nextAdmissionOrdinal, 2)
        XCTAssertEqual(
            harness.capacityObservation.labels,
            try expectedR13IntegrationCapacityLabels(
                for: workspace,
                liveRecheckCountsByAttempt: [2, 4]
            )
        )
        let recoverable = try await service.recoverableJobs()
        XCTAssertTrue(recoverable.jobs.isEmpty)
    }

    private func makeExpectedIdentity(
        job: UpscaleJob,
        workspace: R13IntegrationWorkspace,
        harness: R13IntegrationHardeningHarness
    ) throws -> R13ReleaseIdentity {
        try R13ReleaseHardeningRuntime.makeReleaseIdentity(
            job: job,
            scalePlan: R13ReleaseJobContracts.scalePlan(
                source: adaptiveSourceResolution,
                target: adaptiveTargetResolution
            ),
            modeBinding: R13ReleaseModePolicy.binding(for: job.mode),
            source: R13LocalRestartSourceMeasurer().measureSource(
                at: workspace.sourceURL
            ),
            environment: harness.environment,
            policyResources: harness.documents.policyResources
        )
    }
}

private func assertInterrupted(_ handle: UpscalerJobHandle) async {
    do {
        _ = try await handle.waitForCompletion()
        XCTFail("The injected interruption must terminate the job.")
    } catch R13IntegrationMediaError.interrupted {
        return
    } catch {
        XCTFail("Expected injected interruption, got \(error).")
    }
}

private func assertSourceDrift(_ handle: UpscalerJobHandle) async {
    do {
        _ = try await handle.waitForCompletion()
        XCTFail("A changed source must not reopen the adaptive cache.")
    } catch R13RestartJobError.sourceDrift {
        return
    } catch {
        XCTFail("Expected adaptive source drift, got \(error).")
    }
}

private func assertMetadataMismatch(
    attempt: R13ReleaseHardeningAttempt,
    outputURL: URL,
    metadata: [String: String]
) async {
    do {
        try await attempt.validateBeforePublish(
            outputURL: outputURL,
            metadata: metadata
        )
        XCTFail("Changed adaptive identity metadata must be rejected.")
    } catch let error as R13ReleaseIdentityError {
        XCTAssertEqual(
            error,
            .metadataValueDiffers(
                key: "com.mirmir.release.backend-id"
            )
        )
    } catch {
        XCTFail("Expected adaptive metadata mismatch, got \(error).")
    }
}

private func assertPrepublicationSourceDrift(
    attempt: R13ReleaseHardeningAttempt,
    outputURL: URL
) async {
    do {
        try await attempt.validateBeforePublish(
            outputURL: outputURL,
            metadata: attempt.identity.timedMetadata
        )
        XCTFail("Changed staged source must fail prepublication validation.")
    } catch R13RestartJobError.sourceDrift {
        return
    } catch {
        XCTFail("Expected prepublication source drift, got \(error).")
    }
}

private func diagnosticCount(
    _ code: R13ReleaseDiagnosticCode,
    in snapshot: R13ReleaseDiagnosticsSnapshot
) -> Int {
    snapshot.records.filter { $0.event.code == code }.count
}

private func eventCount(
    _ event: String,
    in eventLog: R13ReleaseTestEventLog
) -> Int {
    eventLog.events.filter { $0 == event }.count
}
