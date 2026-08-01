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
        try expectedIdentity.validateTimedMetadata(metadata)
        for (key, expectedValue) in expectedIdentity.timedMetadata
        where R13ProductASHDecisionMetadata.pendingValues[key] == nil {
            XCTAssertEqual(metadata[key], expectedValue, key)
        }
        XCTAssertEqual(
            metadata[R13ProductASHDecisionMetadata.statusKey],
            "complete"
        )
        XCTAssertEqual(
            metadata[R13ProductASHDecisionMetadata.decisionCountKey],
            "1"
        )
        XCTAssertEqual(
            metadata[R13ProductASHDecisionMetadata.transitionCountKey],
            "0"
        )
        XCTAssertNotEqual(
            metadata[R13ProductASHDecisionMetadata.selectedBackendsKey],
            "pending"
        )
        XCTAssertNotEqual(
            metadata[R13ProductASHDecisionMetadata.journalSHA256Key],
            String(repeating: "0", count: 64)
        )
        try await assertR13ReopenedOutput(
            at: workspace.outputURL,
            resolution: .p1080
        )
        try await assertR13ReopenedCodecAndContainer(
            at: workspace.outputURL,
            codec: .h264,
            pathExtension: "mov",
            majorBrand: "qt  "
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

    func testShippingServiceExecutesRealAutoAndFastModes()
        async throws {
        for mode in [UpscaleMode.auto, .fast] {
            let workspace = try R13IntegrationWorkspace(
                outputFileName: "\(mode.rawValue)-output.mov"
            )
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
            let diagnostics = MirmirDiagnosticStore()
            let media = AVFoundationMediaPipeline(
                metal: NoopMetalRenderingService(),
                diagnostics: diagnostics
            )
            let service = R13ReleaseUpscalerEngineService(
                media: media,
                hardeningRuntime: harness.runtime,
                diagnostics: diagnostics
            )
            let job = makeR13IntegrationJob(
                identifier: "r13-real-\(mode.rawValue)",
                workspace: workspace,
                mode: mode
            )

            let result = try await service.submit(job)
                .waitForCompletion()

            XCTAssertEqual(result, workspace.outputURL, mode.rawValue)
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: workspace.outputURL.path
                ),
                mode.rawValue
            )
            try await assertR13ReopenedOutput(
                at: result,
                resolution: .p1080
            )
            let metadata = try await readR13ReleaseMetadata(at: result)
            let expectedIdentity = try makeR13ExpectedIntegrationIdentity(
                job: job,
                workspace: workspace,
                harness: harness
            )
            try expectedIdentity.validateTimedMetadata(metadata)
            XCTAssertEqual(
                metadata["com.mirmir.release.requested-mode"],
                mode.rawValue
            )
            XCTAssertEqual(
                metadata["com.mirmir.release.effective-mode"],
                mode.rawValue
            )
            XCTAssertNotEqual(
                metadata[
                    R13ProductASHDecisionMetadata.selectedBackendsKey
                ],
                "pending"
            )
            XCTAssertEqual(
                metadata[R13ProductASHDecisionMetadata.statusKey],
                "complete"
            )
            try await assertR13SuccessfulResourceClosure(
                service: service,
                harness: harness
            )
        }
    }

    func testShippingServiceProcessesRealLowLatencyScale4Video()
        async throws {
        let observation = try await R04VideoToolboxBackend
            .observeNativeCapability(subjectID: .lowLatency4x)
        guard case .runnable = observation.status else {
            throw XCTSkip(
                "This host does not expose the exact native VideoToolbox "
                    + "480x270-to-1920x1080 Low Latency route: "
                    + "\(observation.status)."
            )
        }

        let keepProof = ProcessInfo.processInfo.environment[
            "MIRMIR_KEEP_LOW_LATENCY_4X_PROOF"
        ] == "1"
        let workspace = try R13IntegrationWorkspace(
            outputFileName: "low-latency-4x-output.mov"
        )
        defer {
            if !keepProof {
                workspace.remove()
            }
        }
        let videoOnlyURL = workspace.directory.appendingPathComponent(
            "low-latency-4x-video-only.mp4"
        )
        let audioOnlyURL = workspace.directory.appendingPathComponent(
            "low-latency-4x-audio-only.m4a"
        )
        let frameCount = 3
        let frameDuration = CMTime(value: 1, timescale: 30)
        try await writeVideoFrames(
            to: videoOnlyURL,
            resolution: .p270,
            frameCount: frameCount,
            frameDuration: frameDuration
        )
        try writeAACFixture(
            to: audioOnlyURL,
            seed: 43,
            frameCount: 4_800
        )
        try await muxVideoAndAAC(
            videoURL: videoOnlyURL,
            audioURL: audioOnlyURL,
            destinationURL: workspace.sourceURL
        )
        let diagnostics = MirmirDiagnosticStore()
        let media = AVFoundationMediaPipeline(
            metal: NoopMetalRenderingService(),
            diagnostics: diagnostics
        )
        let source = try await media.probe(url: workspace.sourceURL)
        XCTAssertEqual(source.resolution, .p270)
        XCTAssertEqual(source.codedResolution, .p270)
        XCTAssertEqual(source.audioTrackCount, 1)
        let sourceAACIdentity = try await OutputMediaAACIdentityReader().read(
            url: workspace.sourceURL
        )
        XCTAssertEqual(sourceAACIdentity.codec, kAudioFormatMPEG4AAC)
        XCTAssertEqual(sourceAACIdentity.sampleRate, 48_000)
        XCTAssertEqual(sourceAACIdentity.channelCount, 2)
        let visibleTargets = await MirmirViewModel.targets(for: .p270)
        XCTAssertTrue(visibleTargets.contains(.p1080))
        XCTAssertEqual(
            try R13ReleaseJobContracts.scalePlan(
                source: .p270,
                target: .p1080,
                strategyPreference: .direct
            ),
            .productQualified(.scale4x)
        )

        let harness = try R13IntegrationHardeningHarness.make(
            jobsRootURL: workspace.jobsRootURL,
            exactFrameCount: frameCount
        )
        let service = R13ReleaseUpscalerEngineService(
            media: media,
            hardeningRuntime: harness.runtime,
            diagnostics: diagnostics
        )
        let job = UpscaleJob(
            identifier: "r13-real-videotoolbox-low-latency-4x",
            inputURL: workspace.sourceURL,
            outputURL: workspace.outputURL,
            targetResolution: .p1080,
            codec: .h264,
            preserveAudio: true,
            mode: .fast,
            processingConfiguration: UpscaleProcessingConfiguration(
                enginePreference: .videoToolboxLowLatency,
                strategyPreference: .direct
            )
        )

        let result = try await service.submit(job).waitForCompletion()

        XCTAssertEqual(result, workspace.outputURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.path))
        let output = try await media.probe(url: result)
        XCTAssertEqual(output.resolution, .p1080)
        XCTAssertEqual(output.codedResolution, .p1080)
        XCTAssertEqual(output.estimatedFrameCount, frameCount)
        XCTAssertEqual(output.audioTrackCount, 1)
        XCTAssertEqual(output.codecHint, "avc1")
        let outputAACIdentity = try await OutputMediaAACIdentityReader().read(
            url: result
        )
        XCTAssertEqual(outputAACIdentity.codec, kAudioFormatMPEG4AAC)
        XCTAssertEqual(outputAACIdentity.sampleRate, 48_000)
        XCTAssertEqual(outputAACIdentity.channelCount, 2)
        XCTAssertEqual(outputAACIdentity, sourceAACIdentity)
        let metadata = try await readR13ReleaseMetadata(at: result)
        XCTAssertEqual(
            metadata["com.mirmir.release.engine-preference"],
            UpscaleEnginePreference.videoToolboxLowLatency.rawValue
        )
        XCTAssertEqual(
            metadata["com.mirmir.release.route-id"],
            R03ScaleRoute.scale4x.rawValue
        )
        XCTAssertEqual(
            metadata[R13ProductASHDecisionMetadata.selectedBackendsKey],
            R04VideoToolboxSubjectID.lowLatency4x.rawValue
        )
        XCTAssertEqual(
            metadata[R13ProductASHDecisionMetadata.fallbackCountKey],
            "0"
        )
        XCTAssertEqual(
            metadata[R13ProductASHDecisionMetadata.candidateExclusionCountKey],
            "0"
        )
        XCTAssertEqual(
            metadata[R13ProductASHDecisionMetadata.decisionCountKey],
            String(frameCount)
        )
        try await assertR13SuccessfulResourceClosure(
            service: service,
            harness: harness
        )

        let sourceAttachment = XCTAttachment(
            contentsOfFile: workspace.sourceURL
        )
        sourceAttachment.name = "low-latency-4x-source.mp4"
        sourceAttachment.lifetime = .keepAlways
        add(sourceAttachment)
        let outputAttachment = XCTAttachment(contentsOfFile: result)
        outputAttachment.name = "low-latency-4x-output.mov"
        outputAttachment.lifetime = .keepAlways
        add(outputAttachment)

        if keepProof {
            print("MIRMIR_LOW_LATENCY_4X_SOURCE=\(workspace.sourceURL.path)")
            print("MIRMIR_LOW_LATENCY_4X_OUTPUT=\(workspace.outputURL.path)")
        }
    }

    func testShippingServiceProcessesRealQualityScale4VideoWithAAC()
        async throws {
        let observation = try await R04VideoToolboxBackend
            .observeNativeCapability(subjectID: .quality4x)
        guard case .runnable = observation.status else {
            throw XCTSkip(
                "This host does not expose a ready native VideoToolbox "
                    + "Quality 480x270-to-1920x1080 route: "
                    + "\(observation.status)."
            )
        }

        let keepProof = ProcessInfo.processInfo.environment[
            "MIRMIR_KEEP_QUALITY_4X_PROOF"
        ] == "1"
        let workspace = try R13IntegrationWorkspace(
            outputFileName: "quality-4x-output.mov"
        )
        defer {
            if !keepProof {
                workspace.remove()
            }
        }
        let videoOnlyURL = workspace.directory.appendingPathComponent(
            "quality-4x-video-only.mp4"
        )
        let audioOnlyURL = workspace.directory.appendingPathComponent(
            "quality-4x-audio-only.m4a"
        )
        let frameCount = 3
        let frameDuration = CMTime(value: 1, timescale: 30)
        try await writeVideoFrames(
            to: videoOnlyURL,
            resolution: .p270,
            frameCount: frameCount,
            frameDuration: frameDuration
        )
        try writeAACFixture(
            to: audioOnlyURL,
            seed: 41,
            frameCount: 4_800
        )
        try await muxVideoAndAAC(
            videoURL: videoOnlyURL,
            audioURL: audioOnlyURL,
            destinationURL: workspace.sourceURL
        )

        let diagnostics = MirmirDiagnosticStore()
        let media = AVFoundationMediaPipeline(
            metal: NoopMetalRenderingService(),
            diagnostics: diagnostics
        )
        let source = try await media.probe(url: workspace.sourceURL)
        XCTAssertEqual(source.resolution, .p270)
        XCTAssertEqual(source.codedResolution, .p270)
        XCTAssertEqual(source.audioTrackCount, 1)
        let visibleTargets = await MirmirViewModel.targets(for: .p270)
        XCTAssertTrue(visibleTargets.contains(.p1080))
        XCTAssertEqual(
            try R13ReleaseJobContracts.scalePlan(
                source: .p270,
                target: .p1080,
                strategyPreference: .direct
            ),
            .productQualified(.scale4x)
        )

        let harness = try R13IntegrationHardeningHarness.make(
            jobsRootURL: workspace.jobsRootURL,
            exactFrameCount: frameCount
        )
        let service = R13ReleaseUpscalerEngineService(
            media: media,
            hardeningRuntime: harness.runtime,
            diagnostics: diagnostics
        )
        let job = UpscaleJob(
            identifier: "r13-real-videotoolbox-quality-4x",
            inputURL: workspace.sourceURL,
            outputURL: workspace.outputURL,
            targetResolution: .p1080,
            codec: .h264,
            preserveAudio: true,
            mode: .quality,
            processingConfiguration: UpscaleProcessingConfiguration(
                enginePreference: .videoToolboxQuality,
                strategyPreference: .direct
            )
        )

        let result = try await service.submit(job).waitForCompletion()

        XCTAssertEqual(result, workspace.outputURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.path))
        let output = try await media.probe(url: result)
        XCTAssertEqual(output.resolution, .p1080)
        XCTAssertEqual(output.codedResolution, .p1080)
        XCTAssertEqual(output.estimatedFrameCount, frameCount)
        XCTAssertEqual(output.audioTrackCount, 1)
        XCTAssertEqual(output.codecHint, "avc1")
        let metadata = try await readR13ReleaseMetadata(at: result)
        XCTAssertEqual(
            metadata["com.mirmir.release.engine-preference"],
            UpscaleEnginePreference.videoToolboxQuality.rawValue
        )
        XCTAssertEqual(
            metadata["com.mirmir.release.route-id"],
            R03ScaleRoute.scale4x.rawValue
        )
        XCTAssertEqual(
            metadata[R13ProductASHDecisionMetadata.selectedBackendsKey],
            R04VideoToolboxSubjectID.quality4x.rawValue
        )
        XCTAssertEqual(
            metadata[R13ProductASHDecisionMetadata.fallbackCountKey],
            "0"
        )
        XCTAssertEqual(
            metadata[R13ProductASHDecisionMetadata.candidateExclusionCountKey],
            "0"
        )
        XCTAssertEqual(
            metadata[R13ProductASHDecisionMetadata.decisionCountKey],
            String(frameCount)
        )
        try await assertR13SuccessfulResourceClosure(
            service: service,
            harness: harness
        )

        if keepProof {
            print("MIRMIR_QUALITY_4X_SOURCE=\(workspace.sourceURL.path)")
            print("MIRMIR_QUALITY_4X_OUTPUT=\(workspace.outputURL.path)")
        }
    }

    @MainActor
    func testShippingViewModelCompletesRealSelectedFileWorkflow()
        async throws {
        let workspace = try R13IntegrationWorkspace(
            outputFileName: "selected-workflow.mov"
        )
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
        let diagnostics = MirmirDiagnosticStore()
        let media = AVFoundationMediaPipeline(
            metal: NoopMetalRenderingService(),
            diagnostics: diagnostics
        )
        let service = R13ReleaseUpscalerEngineService(
            media: media,
            hardeningRuntime: harness.runtime,
            diagnostics: diagnostics
        )
        var revealedURL: URL?
        let viewModel = MirmirViewModel(
            mediaPipeline: media,
            upscalerEngine: service,
            modelAssets: NotRequiredModelAssetsService(),
            diagnostics: diagnostics,
            revealFileInFinder: { revealedURL = $0 }
        )

        viewModel.loadSource(url: workspace.sourceURL)
        for _ in 0..<1_000 where viewModel.state == .probing {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(viewModel.state, .ready)
        XCTAssertEqual(viewModel.sourceProfile?.resolution, .p720)
        XCTAssertTrue(viewModel.selectTargetForPendingJob(.p1080))
        XCTAssertTrue(viewModel.selectModeForPendingJob(.quality))
        XCTAssertTrue(viewModel.selectCodecForPendingJob(.h264))
        XCTAssertTrue(
            viewModel.acceptOutputURLSelectedByUser(
                workspace.outputURL
            )
        )
        XCTAssertNil(viewModel.canStartFailureReason)

        viewModel.startUpscale()
        for _ in 0..<2_000 {
            if viewModel.state == .finished(workspace.outputURL) {
                break
            }
            if case .failed(let reason) = viewModel.state {
                XCTFail("Real selected-file workflow failed: \(reason)")
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(
            viewModel.state,
            .finished(workspace.outputURL)
        )
        XCTAssertEqual(
            viewModel.completedOutputURL,
            workspace.outputURL
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: workspace.outputURL.path
            )
        )
        try await assertR13ReopenedOutput(
            at: workspace.outputURL,
            resolution: .p1080
        )
        viewModel.revealOutputInFinder()
        XCTAssertEqual(revealedURL, workspace.outputURL)
        XCTAssertNil(viewModel.completedOutputRevealError)
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
    let modeBinding = R13ReleaseModePolicy.binding(
        for: job.mode,
        enginePreference:
            job.processingConfiguration.enginePreference
    )
    let environment = try R13ReleaseEnvironment(
        application: harness.environment.application,
        framework: R13ReleaseFrameworkIdentity(
            frameworkIdentifier:
                modeBinding.frameworkIdentity,
            version: harness.environment.framework.version,
            buildIdentity:
                harness.environment.framework.buildIdentity
        ),
        runtime: harness.environment.runtime
    )
    return try R13ReleaseHardeningRuntime.makeReleaseIdentity(
        job: job,
        route: .scale3Over2,
        modeBinding: modeBinding,
        source: R13LocalRestartSourceMeasurer().measureSource(
            at: workspace.sourceURL
        ),
        environment: environment,
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
    let modeBinding = R13ReleaseModePolicy.binding(
        for: .deterministic
    )
    XCTAssertEqual(
        countR13IntegrationEvents(
            "input.release.r13.release.input."
                + "\(modeBinding.backendID).deterministic.0",
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
