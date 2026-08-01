import Foundation
import os.lock
@testable import Mirmir
import XCTest

final class ModelAssetsLifecycleTests: XCTestCase {
    func test_modelAssetsServiceSharesOneDownloadAndStreamsProgress()
        async throws {
        let provider = VTControlledModelConfigurationProbe(
            status: .downloadRequired,
            downloadDelayNanoseconds: 12_000_000
        )
        let service = DefaultModelAssetsService { _ in
            VTModelStager(
                configurationProvider: provider,
                acquisitionAuthority: .systemDownloadAuthorized,
                pollingIntervalNanoseconds: 1_000_000
            )
        }
        let binding = try makeQualityModelBinding()
        service.bind(binding, for: .video)

        // Register the observer synchronously before acquisition starts. A
        // Task does not guarantee that its body begins before subsequently
        // created child tasks, so constructing the stream inside the Task
        // made this test race the initial downloading(0) publication.
        let statusStream = service.statusStream(for: .video)
        let statusTask = Task { () -> [ModelAssetsStatus] in
            var statuses: [ModelAssetsStatus] = []
            for await status in statusStream {
                statuses.append(status)
                if status == .ready {
                    return statuses
                }
            }
            return statuses
        }

        async let firstReady: Void = service.ensureReady(for: .video)
        async let secondReady: Void = service.ensureReady(for: .video)
        _ = try await (firstReady, secondReady)
        let statuses = await statusTask.value

        XCTAssertEqual(provider.downloadCount, 1)
        XCTAssertTrue(
            statuses.contains(.downloading(progress: 0))
        )
        XCTAssertTrue(
            statuses.contains { status in
                guard case .downloading(let progress) = status else {
                    return false
                }
                return progress > 0 && progress < 1
            }
        )
        XCTAssertEqual(statuses.last, .ready)
        XCTAssertEqual(service.currentStatus(for: .video), .ready)
    }

    func test_modelAssetsServiceRetryStartsAfterDownloadFailure()
        async throws {
        let provider = VTControlledModelConfigurationProbe(
            status: .downloadRequired,
            downloadDelayNanoseconds: 4_000_000,
            failuresBeforeSuccess: 1
        )
        let service = DefaultModelAssetsService { _ in
            VTModelStager(
                configurationProvider: provider,
                acquisitionAuthority: .systemDownloadAuthorized,
                pollingIntervalNanoseconds: 1_000_000
            )
        }
        service.bind(try makeQualityModelBinding(), for: .video)

        do {
            try await service.ensureReady(for: .video)
            XCTFail("The injected first download failure was not surfaced.")
        } catch let error as ModelAssetsServiceError {
            guard case .downloadFailed = error else {
                return XCTFail("Unexpected service error: \(error)")
            }
        }
        guard case .failed = service.currentStatus(for: .video) else {
            return XCTFail("The failed download must remain observable.")
        }

        try await service.ensureReady(for: .video)

        XCTAssertEqual(provider.downloadCount, 2)
        XCTAssertEqual(service.currentStatus(for: .video), .ready)
    }

    func test_modelAssetsServiceRetriesFailedConfigurationConstruction()
        async throws {
        let provider = VTControlledModelConfigurationProbe(
            status: .downloadRequired
        )
        let factory = VTStagerFactoryProbe(
            provider: provider,
            failuresBeforeSuccess: 1
        )
        let service = DefaultModelAssetsService(
            stagerFactory: { binding in
                try factory.make(binding: binding)
            }
        )
        service.bind(try makeQualityModelBinding(), for: .video)

        guard case .failed = service.currentStatus(for: .video) else {
            return XCTFail("The construction failure must be observable.")
        }

        try await service.ensureReady(for: .video)

        XCTAssertEqual(factory.makeCallCount, 2)
        XCTAssertEqual(provider.downloadCount, 1)
        XCTAssertEqual(service.currentStatus(for: .video), .ready)
    }

    func test_modelAssetsServiceCancellationStopsWaitWithoutFabricatingFailure()
        async throws {
        let provider = VTControlledModelConfigurationProbe(
            status: .downloading(progress: 0.4)
        )
        let service = DefaultModelAssetsService { _ in
            VTModelStager(
                configurationProvider: provider,
                acquisitionAuthority: .systemDownloadAuthorized,
                pollingIntervalNanoseconds: 1_000_000
            )
        }
        service.bind(try makeQualityModelBinding(), for: .video)

        let waiter = Task {
            try await service.ensureReady(for: .video)
        }
        try await Task.sleep(nanoseconds: 3_000_000)
        waiter.cancel()

        do {
            try await waiter.value
            XCTFail("The cancelled caller unexpectedly completed.")
        } catch is CancellationError {
            // Expected: caller cancellation is not a model failure.
        } catch {
            XCTFail("Unexpected cancellation result: \(error)")
        }

        XCTAssertEqual(provider.downloadCount, 0)
        XCTAssertEqual(
            service.currentStatus(for: .video),
            .downloading(progress: 0.4)
        )
    }

    func test_modelAssetsServiceStopTerminatesWaitersAndCanRestart()
        async throws {
        let provider = VTControlledModelConfigurationProbe(
            status: .downloading(progress: 0.4)
        )
        let service = DefaultModelAssetsService { _ in
            VTModelStager(
                configurationProvider: provider,
                acquisitionAuthority: .systemDownloadAuthorized,
                pollingIntervalNanoseconds: 1_000_000
            )
        }
        service.bind(try makeQualityModelBinding(), for: .video)

        let waiter = Task {
            try await service.ensureReady(for: .video)
        }
        try await Task.sleep(nanoseconds: 3_000_000)
        service.stop()

        do {
            try await waiter.value
            XCTFail("Stopping the service left a waiter running.")
        } catch let error as ModelAssetsServiceError {
            XCTAssertEqual(
                error,
                .downloadFailed(
                    ModelAssetsServiceError.serviceStopped.description
                )
            )
        } catch {
            XCTFail("Unexpected stopped-service error: \(error)")
        }

        service.start()
        XCTAssertEqual(
            service.currentStatus(for: .video),
            .downloading(progress: 0.4)
        )
        service.bind(
            .notRequired(routeID: "fallback.after-restart"),
            for: .video
        )
    }

    func test_modelAssetsServiceRebindingRejectsStaleWaiterAndCompletion()
        async throws {
        let provider = VTControlledModelConfigurationProbe(
            status: .downloadRequired,
            downloadDelayNanoseconds: 20_000_000
        )
        let service = DefaultModelAssetsService { _ in
            VTModelStager(
                configurationProvider: provider,
                acquisitionAuthority: .systemDownloadAuthorized,
                pollingIntervalNanoseconds: 1_000_000
            )
        }
        service.bind(try makeQualityModelBinding(), for: .video)

        let waiter = Task {
            try await service.ensureReady(for: .video)
        }
        try await Task.sleep(nanoseconds: 3_000_000)
        service.bind(
            .notRequired(routeID: "fallback.vimage"),
            for: .video
        )

        do {
            try await waiter.value
            XCTFail("The stale model waiter unexpectedly completed.")
        } catch let error as ModelAssetsServiceError {
            XCTAssertEqual(error, .configurationChanged)
        } catch {
            XCTFail("Unexpected stale-waiter error: \(error)")
        }

        try await Task.sleep(nanoseconds: 5_000_000)
        XCTAssertEqual(
            service.currentBinding(for: .video),
            .notRequired(routeID: "fallback.vimage")
        )
        XCTAssertEqual(service.currentStatus(for: .video), .notRequired)
    }

    func test_modelFreeBindingNeverConstructsOrDownloadsAStager()
        async throws {
        let factory = VTStagerFactoryProbe()
        let service = DefaultModelAssetsService(
            stagerFactory: { binding in
                try factory.make(binding: binding)
            }
        )
        service.bind(
            .notRequired(routeID: "r03.vimage.model-free"),
            for: .video
        )

        try await service.ensureReady(for: .video)

        XCTAssertEqual(factory.makeCallCount, 0)
        XCTAssertEqual(service.currentStatus(for: .video), .notRequired)
    }

    @MainActor
    @available(macOS 26.0, *)
    func test_viewModelBindsExactQualityAndModelFreeRoutes()
        async throws {
        let provider = VTControlledModelConfigurationProbe(
            status: .downloadRequired
        )
        let service = DefaultModelAssetsService { _ in
            VTModelStager(
                configurationProvider: provider,
                acquisitionAuthority: .systemDownloadAuthorized
            )
        }
        let viewModel = MirmirViewModel(
            mediaPipeline: NoopMediaPipelineService(),
            upscalerEngine: NoopUpscalerEngineService(),
            modelAssets: service
        )
        viewModel.sourceProfile = SourceProfile(
            url: URL(fileURLWithPath: "/tmp/model-route.mov"),
            resolution: .p270,
            frameRate: 30,
            durationSeconds: 1,
            estimatedFrameCount: 30,
            codecHint: "test",
            hasAudio: false
        )
        viewModel.targetResolution = .p1080
        viewModel.enginePreference = .automatic
        viewModel.selectedMode = .quality

        let qualityBinding = try makeQualityModelBinding(
            source: .p270,
            target: .p1080
        )
        XCTAssertEqual(
            viewModel.modelAssetsBinding,
            qualityBinding
        )
        XCTAssertEqual(
            service.currentBinding(for: .video),
            qualityBinding
        )
        XCTAssertEqual(
            service.currentStatus(for: .video),
            .downloadRequired
        )
        await waitForModelStatus(
            .downloadRequired,
            in: viewModel
        )
        XCTAssertTrue(viewModel.modelAssetsShowsPreparationControl)
        XCTAssertTrue(viewModel.modelAssetsCanPrepare)
        XCTAssertEqual(
            viewModel.modelAssetsPreparationActionTitle,
            "Download Model"
        )

        viewModel.ensureModelsReady()
        await waitForModelStatus(.ready, in: viewModel)
        XCTAssertEqual(provider.downloadCount, 1)
        XCTAssertFalse(viewModel.modelAssetsCanPrepare)

        viewModel.selectedMode = .fast
        XCTAssertEqual(
            viewModel.modelAssetsBinding,
            .notRequired(
                routeID:
                    R04VideoToolboxSubjectID.lowLatency4x.rawValue
            )
        )
        XCTAssertEqual(service.currentStatus(for: .video), .notRequired)

        viewModel.selectedMode = .deterministic
        guard case .notRequired(let routeID) =
                viewModel.modelAssetsBinding else {
            return XCTFail(
                "Deterministic mode must bind a model-free route."
            )
        }
        XCTAssertTrue(routeID.contains("r03"))
        XCTAssertEqual(service.currentStatus(for: .video), .notRequired)
    }

    @MainActor
    @available(macOS 26.0, *)
    func test_automaticQualityModelIsOptionalWhenDownloadIsRequiredOrFails()
        async throws {
        let provider = VTControlledModelConfigurationProbe(
            status: .downloadRequired,
            failuresBeforeSuccess: 1
        )
        let service = DefaultModelAssetsService { _ in
            VTModelStager(
                configurationProvider: provider,
                acquisitionAuthority: .systemDownloadAuthorized
            )
        }
        let outputDirectory = try makePendingQueueTemporaryDirectory()
        let viewModel = MirmirViewModel(
            mediaPipeline: NoopMediaPipelineService(),
            upscalerEngine: NoopUpscalerEngineService(),
            modelAssets: service
        )
        viewModel.sourceProfile = SourceProfile(
            url: URL(fileURLWithPath: "/tmp/automatic-quality.mov"),
            resolution: .p270,
            frameRate: 30,
            durationSeconds: 1,
            estimatedFrameCount: 30,
            codecHint: "test",
            hasAudio: false
        )
        viewModel.targetResolution = .p1080
        viewModel.selectedMode = .quality
        viewModel.enginePreference = .automatic
        viewModel.outputURL = outputDirectory
            .appendingPathComponent("automatic-quality.mp4")
        viewModel.state = .ready

        guard case .videoToolboxQuality =
                viewModel.modelAssetsBinding else {
            return XCTFail(
                "Executable Automatic Quality may expose model preparation."
            )
        }
        XCTAssertEqual(viewModel.modelStatus, .downloadRequired)
        XCTAssertTrue(viewModel.modelAssetsShowsPreparationControl)
        XCTAssertTrue(viewModel.canStart)
        XCTAssertNil(viewModel.canStartFailureReason)

        viewModel.ensureModelsReady()
        for _ in 0..<1_000 {
            if case .failed = viewModel.modelStatus { break }
            await Task.yield()
        }
        guard case .failed = viewModel.modelStatus else {
            return XCTFail("The injected model failure was not observed.")
        }
        XCTAssertEqual(provider.downloadCount, 1)
        XCTAssertTrue(viewModel.canStart)
        XCTAssertNil(viewModel.canStartFailureReason)
    }

    @MainActor
    @available(macOS 26.0, *)
    func test_allPathsBindsVideoToolboxQualityModelBeforeQueueing()
        async throws {
        let queueDirectory = try makePendingQueueTemporaryDirectory()
        let provider = VTControlledModelConfigurationProbe(
            status: .downloadRequired
        )
        let service = DefaultModelAssetsService { _ in
            VTModelStager(
                configurationProvider: provider,
                acquisitionAuthority: .systemDownloadAuthorized
            )
        }
        let viewModel = MirmirViewModel(
            mediaPipeline: NoopMediaPipelineService(),
            upscalerEngine: NoopUpscalerEngineService(),
            modelAssets: service,
            pendingWorkQueue: MirmirPendingWorkQueue(
                directoryURL: queueDirectory
            )
        )
        viewModel.sourceProfile = SourceProfile(
            url: URL(fileURLWithPath: "/tmp/all-paths-model-route.mov"),
            resolution: .p1080,
            frameRate: 30,
            durationSeconds: 1,
            estimatedFrameCount: 30,
            codecHint: "test",
            hasAudio: false
        )
        viewModel.targetResolution = .p2160
        viewModel.outputURL = queueDirectory.appendingPathComponent(
            "all-paths-output.mp4"
        )
        viewModel.state = .ready

        XCTAssertTrue(
            viewModel.selectAllProcessingPathsForPendingJob()
        )
        await waitForModelStatus(.downloadRequired, in: viewModel)
        let expectedResolution = try XCTUnwrap(
            R13VideoToolboxQualityJobRouteResolver.resolve(
                mode: viewModel.selectedMode,
                enginePreference: .videoToolboxQuality,
                videoFormat: .sdrBT709,
                presentationSourceResolution: .p1080,
                targetResolution: .p2160,
                strategyPreference: .automatic
            )
        )
        let expected = ModelAssetsRouteBinding.videoToolboxQuality(
            expectedResolution.binding
        )
        XCTAssertEqual(viewModel.modelAssetsBinding, expected)
        XCTAssertEqual(service.currentBinding(for: .video), expected)
        XCTAssertEqual(
            service.currentStatus(for: .video),
            .downloadRequired
        )
        XCTAssertTrue(viewModel.modelAssetsShowsPreparationControl)
        XCTAssertTrue(viewModel.modelAssetsCanPrepare)
        XCTAssertTrue(
            viewModel.selectedEnginePreferences.contains(
                .videoToolboxQuality
            )
        )
        XCTAssertFalse(viewModel.canStart)
        XCTAssertEqual(
            viewModel.canStartFailureReason,
            viewModel.modelAssetsDetailText
        )

        XCTAssertTrue(
            viewModel.toggleProcessingPathForPendingJob(
                .videoToolboxQuality
            )
        )
        XCTAssertFalse(
            viewModel.selectedEnginePreferences.contains(
                .videoToolboxQuality
            )
        )
        XCTAssertEqual(
            viewModel.selectedEnginePreferences.count,
            UpscaleEnginePreference.concreteProcessingPaths.count - 1
        )
        guard case .notRequired = viewModel.modelAssetsBinding else {
            return XCTFail(
                "A subset without Quality must be model-free."
            )
        }
        XCTAssertFalse(viewModel.modelAssetsShowsPreparationControl)
        XCTAssertTrue(viewModel.canStart)
        XCTAssertNil(viewModel.canStartFailureReason)

        XCTAssertTrue(
            viewModel.toggleProcessingPathForPendingJob(
                .videoToolboxQuality
            )
        )
        await waitForModelStatus(.downloadRequired, in: viewModel)
        XCTAssertEqual(viewModel.modelAssetsBinding, expected)
        XCTAssertFalse(viewModel.canStart)

        viewModel.ensureModelsReady()
        await waitForModelStatus(.ready, in: viewModel)

        XCTAssertEqual(provider.downloadCount, 1)
        XCTAssertTrue(viewModel.canStart)
        XCTAssertNil(viewModel.canStartFailureReason)
        XCTAssertEqual(
            viewModel.selectedEnginePreferences,
            UpscaleEnginePreference.concreteProcessingPaths
        )
    }

    @MainActor
    @available(macOS 26.0, *)
    func test_explicitQuality720pAutomaticStrategyStagesAdmittedNativeModel()
        async throws {
        let outputDirectory = try makePendingQueueTemporaryDirectory()
        let provider = VTControlledModelConfigurationProbe(
            status: .downloadRequired
        )
        let service = DefaultModelAssetsService { _ in
            VTModelStager(
                configurationProvider: provider,
                acquisitionAuthority: .systemDownloadAuthorized
            )
        }
        let viewModel = MirmirViewModel(
            mediaPipeline: NoopMediaPipelineService(),
            upscalerEngine: NoopUpscalerEngineService(),
            modelAssets: service
        )
        viewModel.sourceProfile = SourceProfile(
            url: URL(fileURLWithPath: "/tmp/model-route-720.mov"),
            resolution: .p720,
            frameRate: 30,
            durationSeconds: 1,
            estimatedFrameCount: 30,
            codecHint: "test",
            hasAudio: false
        )
        viewModel.targetResolution = .p1080
        XCTAssertTrue(
            viewModel.selectModeForPendingJob(.quality)
        )
        XCTAssertTrue(
            viewModel.selectEngineForPendingJob(
                .videoToolboxQuality
            )
        )
        viewModel.outputURL = outputDirectory
            .appendingPathComponent("quality-720-to-1080.mp4")
        viewModel.state = .ready

        XCTAssertEqual(viewModel.strategyPreference, .automatic)
        guard case .videoToolboxQuality(let nativeBinding) =
                viewModel.modelAssetsBinding else {
            return XCTFail(
                "Explicit 720p Quality must bind its native model."
            )
        }
        let expected = try XCTUnwrap(
            R13VideoToolboxQualityJobRouteResolver.resolve(
                mode: .quality,
                enginePreference: .videoToolboxQuality,
                videoFormat: .sdrBT709,
                presentationSourceResolution: .p720,
                targetResolution: .p1080,
                strategyPreference: .automatic
            )
        )
        XCTAssertEqual(nativeBinding, expected.binding)
        XCTAssertTrue(expected.requiresAdaptiveNativeExecution)
        XCTAssertTrue(
            [.two, .four].contains(
                nativeBinding.route.scaleFactor
            )
        )
        XCTAssertNotEqual(
            nativeBinding.subjectID,
            .quality1p5xContract
        )
        XCTAssertEqual(viewModel.modelStatus, .downloadRequired)
        XCTAssertFalse(viewModel.canStart)
        XCTAssertEqual(
            viewModel.canStartFailureReason,
            viewModel.modelAssetsDetailText
        )

        viewModel.ensureModelsReady()
        await waitForModelStatus(.ready, in: viewModel)

        XCTAssertEqual(provider.downloadCount, 1)
        XCTAssertTrue(viewModel.canStart)
        XCTAssertNil(viewModel.canStartFailureReason)
    }

    @MainActor
    @available(macOS 26.0, *)
    func test_explicitQualityArbitraryGeometryBindsAdaptiveNativeModel()
        async throws {
        let provider = VTControlledModelConfigurationProbe(
            status: .downloadRequired
        )
        let service = DefaultModelAssetsService { _ in
            VTModelStager(
                configurationProvider: provider,
                acquisitionAuthority: .systemDownloadAuthorized
            )
        }
        let viewModel = MirmirViewModel(
            mediaPipeline: NoopMediaPipelineService(),
            upscalerEngine: NoopUpscalerEngineService(),
            modelAssets: service
        )
        let source = VideoResolution(width: 854, height: 480)
        let target = VideoResolution(width: 1_282, height: 720)
        viewModel.sourceProfile = SourceProfile(
            url: URL(fileURLWithPath: "/tmp/model-route-adaptive.mov"),
            resolution: source,
            frameRate: 30,
            durationSeconds: 1,
            estimatedFrameCount: 30,
            codecHint: "test",
            hasAudio: false
        )
        viewModel.targetResolution = target
        XCTAssertTrue(
            viewModel.selectEngineForPendingJob(
                .videoToolboxQuality
            )
        )

        guard case .videoToolboxQuality(let nativeBinding) =
                viewModel.modelAssetsBinding else {
            return XCTFail(
                "Arbitrary explicit Quality geometry must bind a model."
            )
        }
        let expected = try XCTUnwrap(
            R13VideoToolboxQualityJobRouteResolver.resolve(
                mode: .deterministic,
                enginePreference: .videoToolboxQuality,
                videoFormat: .sdrBT709,
                presentationSourceResolution: source,
                targetResolution: target,
                strategyPreference: .automatic
            )
        )
        XCTAssertEqual(nativeBinding, expected.binding)
        XCTAssertTrue(expected.requiresAdaptiveNativeExecution)
        XCTAssertTrue(
            [.two, .four].contains(
                nativeBinding.route.scaleFactor
            )
        )
        XCTAssertEqual(viewModel.modelStatus, .downloadRequired)
        XCTAssertEqual(service.currentStatus(for: .video), .downloadRequired)
    }

    @MainActor
    @available(macOS 26.0, *)
    func test_strategyChangeImmediatelyRebindsCurrentQualityModelStatus()
        async throws {
        let readyProvider = VTControlledModelConfigurationProbe(
            status: .ready
        )
        let downloadProvider = VTControlledModelConfigurationProbe(
            status: .downloadRequired
        )
        let service = DefaultModelAssetsService { binding in
            let isCatalogExact =
                binding.route.configurationContract
                    .scaleFactorIdentity == "4"
            return VTModelStager(
            configurationProvider:
                    isCatalogExact ? readyProvider : downloadProvider,
                acquisitionAuthority: .systemDownloadAuthorized
            )
        }
        let outputDirectory = try makePendingQueueTemporaryDirectory()
        let viewModel = MirmirViewModel(
            mediaPipeline: NoopMediaPipelineService(),
            upscalerEngine: NoopUpscalerEngineService(),
            modelAssets: service
        )
        viewModel.sourceProfile = SourceProfile(
            url: URL(fileURLWithPath: "/tmp/model-route-rebind.mov"),
            resolution: .p270,
            frameRate: 30,
            durationSeconds: 1,
            estimatedFrameCount: 30,
            codecHint: "test",
            hasAudio: false
        )
        viewModel.targetResolution = .p1080
        XCTAssertTrue(
            viewModel.selectModeForPendingJob(.quality)
        )
        XCTAssertTrue(
            viewModel.selectEngineForPendingJob(
                .videoToolboxQuality
            )
        )
        viewModel.outputURL = outputDirectory
            .appendingPathComponent("quality-rebind.mp4")
        viewModel.state = .ready

        XCTAssertEqual(viewModel.modelStatus, .ready)
        XCTAssertTrue(viewModel.canStart)
        let exactBinding = viewModel.modelAssetsBinding

        XCTAssertTrue(
            viewModel.selectStrategyForPendingJob(.adaptive)
        )

        XCTAssertNotEqual(viewModel.modelAssetsBinding, exactBinding)
        XCTAssertEqual(viewModel.modelStatus, .downloadRequired)
        XCTAssertEqual(service.currentStatus(for: .video), .downloadRequired)
        XCTAssertFalse(viewModel.canStart)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(viewModel.modelStatus, .downloadRequired)
        XCTAssertFalse(viewModel.canStart)
    }

    @MainActor
    @available(macOS 26.0, *)
    func test_explicitExtendedQualityRouteStagesItsNativeModel()
        async throws {
        let provider = VTControlledModelConfigurationProbe(
            status: .downloadRequired
        )
        let service = DefaultModelAssetsService { _ in
            VTModelStager(
                configurationProvider: provider,
                acquisitionAuthority: .systemDownloadAuthorized
            )
        }
        let format = MediaVideoFormat.hdrBT2020PQ(
            masteringDisplayColorVolume:
                Data(repeating: 0x27, count: 24),
            contentLightLevelInfo:
                Data([0x01, 0x02, 0x03, 0x04])
        )
        let viewModel = MirmirViewModel(
            mediaPipeline: NoopMediaPipelineService(),
            upscalerEngine: NoopUpscalerEngineService(),
            modelAssets: service
        )
        viewModel.sourceProfile = SourceProfile(
            url: URL(fileURLWithPath: "/tmp/model-route-explicit-hdr.mov"),
            resolution: .p1080,
            frameRate: 30,
            durationSeconds: 1,
            estimatedFrameCount: 30,
            codecHint: "hevc-main10",
            hasAudio: false,
            videoFormat: format
        )
        viewModel.targetResolution = .p2160
        XCTAssertTrue(
            viewModel.selectEngineForPendingJob(
                .videoToolboxQuality
            )
        )

        guard case .videoToolboxQuality(let nativeBinding) =
                viewModel.modelAssetsBinding else {
            return XCTFail(
                "Explicit HDR Quality must bind its native model."
            )
        }
        let expected = try XCTUnwrap(
            R13VideoToolboxQualityJobRouteResolver.resolve(
                mode: .deterministic,
                enginePreference: .videoToolboxQuality,
                videoFormat: format,
                presentationSourceResolution: .p1080,
                targetResolution: .p2160,
                strategyPreference: .automatic
            )
        )
        XCTAssertEqual(nativeBinding, expected.binding)
        XCTAssertTrue(expected.requiresAdaptiveNativeExecution)
        XCTAssertEqual(viewModel.modelStatus, .downloadRequired)

        viewModel.ensureModelsReady()
        await waitForModelStatus(.ready, in: viewModel)
        XCTAssertEqual(provider.downloadCount, 1)
    }

    @MainActor
    @available(macOS 26.0, *)
    func test_extendedFormatQualityRouteDoesNotRequestUnusedVTModel()
        async throws {
        let factory = VTStagerFactoryProbe()
        let service = DefaultModelAssetsService(
            stagerFactory: { binding in
                try factory.make(binding: binding)
            }
        )
        let format = MediaVideoFormat.hdrBT2020PQ(
            masteringDisplayColorVolume:
                Data(repeating: 0x27, count: 24),
            contentLightLevelInfo:
                Data([0x01, 0x02, 0x03, 0x04])
        )
        let viewModel = MirmirViewModel(
            mediaPipeline: NoopMediaPipelineService(),
            upscalerEngine: NoopUpscalerEngineService(),
            modelAssets: service
        )
        viewModel.sourceProfile = SourceProfile(
            url: URL(fileURLWithPath: "/tmp/model-route-hdr.mov"),
            resolution: .p1080,
            frameRate: 30,
            durationSeconds: 1,
            estimatedFrameCount: 30,
            codecHint: "hevc-main10",
            hasAudio: false,
            videoFormat: format
        )
        viewModel.targetResolution = .p2160
        viewModel.enginePreference = .automatic
        viewModel.selectedMode = .quality

        guard case .notRequired(let routeID) =
                viewModel.modelAssetsBinding else {
            return XCTFail(
                "The P010 quality route must not request an unused "
                    + "NV12 VideoToolbox model."
            )
        }
        XCTAssertTrue(
            routeID.contains(format.pixelStorage.rawValue)
        )
        XCTAssertTrue(routeID.contains("r13.quality.router"))
        XCTAssertEqual(
            service.currentBinding(for: .video),
            viewModel.modelAssetsBinding
        )
        XCTAssertEqual(
            service.currentStatus(for: .video),
            .notRequired
        )

        try await service.ensureReady(for: .video)
        XCTAssertEqual(factory.makeCallCount, 0)
    }

    @MainActor
    @available(macOS 26.0, *)
    func test_explicitQualityQueueHeadStaysPendingUntilOneModelDownloadFinishes()
        async throws {
        let fixture = try await makeQueuedQualityFixture(
            identifier: "queued-quality-fresh",
            enginePreference: .videoToolboxQuality,
            provider: VTControlledModelConfigurationProbe(
                status: .downloadRequired,
                downloadDelayNanoseconds: 80_000_000
            )
        )

        fixture.viewModel.startNextPendingWork()
        try await waitForQueueCondition {
            fixture.provider.downloadCount == 1
                && fixture.viewModel.pendingQueueModelPreparation?
                    .isPreparing == true
        }

        let preparingSnapshot = try await fixture.queue.load()
        XCTAssertEqual(
            preparingSnapshot.records.first?.state,
            .pending
        )
        XCTAssertTrue(
            preparingSnapshot.processingPathBatchResults.isEmpty
        )
        XCTAssertTrue(fixture.engine.submittedJobs.isEmpty)

        try await waitForQueueCondition {
            fixture.engine.submittedJobs.count == 1
        }
        XCTAssertEqual(fixture.provider.downloadCount, 1)
        XCTAssertEqual(
            fixture.engine.submittedJobs.first?.identifier,
            fixture.record.id
        )
        XCTAssertEqual(
            fixture.engine.submittedJobs.first?
                .processingConfiguration.enginePreference,
            .videoToolboxQuality
        )
        let submittedSnapshot = try await fixture.queue.load()
        XCTAssertEqual(submittedSnapshot.records.first?.state, .started)
        XCTAssertNil(fixture.viewModel.pendingQueueModelPreparation)
        fixture.engine.latestHandle?.completeCancellation()
    }

    @MainActor
    @available(macOS 26.0, *)
    func test_restartedQualityBatchHeadFailureStaysPendingAndRetrySubmits()
        async throws {
        let fixture = try await makeQueuedQualityFixture(
            identifier: "queued-quality-restarted-batch",
            enginePreference: .videoToolboxQuality,
            provider: VTControlledModelConfigurationProbe(
                status: .downloadRequired,
                failuresBeforeSuccess: 1
            ),
            processingPathBatch: MirmirProcessingPathBatchContext(
                id: "restarted-all-paths-batch",
                path: .videoToolboxQuality,
                ordinal: 0,
                totalCount:
                    UpscaleEnginePreference
                        .concreteProcessingPaths.count
            ),
            recreateQueueBeforeViewModel: true
        )

        fixture.viewModel.startNextPendingWork()
        try await waitForQueueCondition {
            fixture.viewModel.pendingQueueModelPreparation?
                .failureReason != nil
                && !fixture.viewModel
                    .pendingQueueMutationIsInProgress
        }

        let failedSnapshot = try await fixture.queue.load()
        XCTAssertEqual(failedSnapshot.records.first?.state, .pending)
        XCTAssertTrue(failedSnapshot.processingPathBatchResults.isEmpty)
        XCTAssertTrue(fixture.engine.submittedJobs.isEmpty)
        XCTAssertEqual(fixture.provider.downloadCount, 1)

        fixture.viewModel.startNextPendingWork()
        try await waitForQueueCondition {
            fixture.engine.submittedJobs.count == 1
        }

        XCTAssertEqual(fixture.provider.downloadCount, 2)
        XCTAssertEqual(
            fixture.engine.submittedJobs.first?.identifier,
            fixture.record.id
        )
        let retriedSnapshot = try await fixture.queue.load()
        XCTAssertEqual(retriedSnapshot.records.first?.state, .started)
        XCTAssertTrue(retriedSnapshot.processingPathBatchResults.isEmpty)
        fixture.engine.latestHandle?.completeCancellation()
    }

    @MainActor
    @available(macOS 26.0, *)
    func test_automaticQueueHeadSubmitsWithoutMandatoryModelDownload()
        async throws {
        let fixture = try await makeQueuedQualityFixture(
            identifier: "queued-automatic-quality",
            enginePreference: .automatic,
            provider: VTControlledModelConfigurationProbe(
                status: .downloadRequired
            )
        )

        XCTAssertFalse(
            MirmirViewModel
                .queuedWorkRequiresReadyConfigurationModel(
                    enginePreference: .automatic
                )
        )
        XCTAssertTrue(
            MirmirViewModel
                .queuedWorkRequiresReadyConfigurationModel(
                    enginePreference: .videoToolboxQuality
                )
        )

        fixture.viewModel.startNextPendingWork()
        try await waitForQueueCondition {
            fixture.engine.submittedJobs.count == 1
        }

        XCTAssertEqual(fixture.provider.downloadCount, 0)
        XCTAssertNil(fixture.viewModel.pendingQueueModelPreparation)
        XCTAssertEqual(
            fixture.engine.submittedJobs.first?
                .processingConfiguration.enginePreference,
            .automatic
        )
        fixture.engine.latestHandle?.completeCancellation()
    }

    @MainActor
    @available(macOS 26.0, *)
    private func makeQueuedQualityFixture(
        identifier: String,
        enginePreference: UpscaleEnginePreference,
        provider: VTControlledModelConfigurationProbe,
        processingPathBatch:
            MirmirProcessingPathBatchContext? = nil,
        recreateQueueBeforeViewModel: Bool = false
    ) async throws -> VTQueuedQualityFixture {
        let root = try makePendingQueueTemporaryDirectory()
        let outputDirectory = root.appendingPathComponent(
            "Output",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: false
        )
        let sourceURL = root.appendingPathComponent("\(identifier).mov")
        try Data([0x01, 0x02, 0x03]).write(to: sourceURL)
        let profile = SourceProfile(
            url: sourceURL,
            resolution: .p270,
            frameRate: 30,
            durationSeconds: 1,
            estimatedFrameCount: 30,
            codecHint: "test",
            hasAudio: false
        )
        let resolver = VTQueueBookmarkResolver()
        let record = makePendingQueueRecord(
            id: identifier,
            order: 0,
            bookmarks: MirmirPendingWorkBookmarks(
                sourceBookmark: try resolver.makeBookmark(
                    for: sourceURL,
                    role: .source
                ),
                outputBookmark: try resolver.makeBookmark(
                    for: outputDirectory,
                    role: .output
                ),
                sourceDisplayName: sourceURL.lastPathComponent,
                outputDisplayName: "\(identifier).mp4"
            ),
            settings: makePendingQueueSettings(
                targetResolution: .p1080,
                codec: .hevc,
                preserveAudio: false,
                requestedMode: .quality,
                processingConfiguration:
                    UpscaleProcessingConfiguration(
                        enginePreference: enginePreference,
                        strategyPreference: .automatic
                    ),
                processingPathBatch: processingPathBatch
            )
        )
        let queueDirectory = root.appendingPathComponent(
            "Queue",
            isDirectory: true
        )
        let seedQueue = MirmirPendingWorkQueue(
            directoryURL: queueDirectory
        )
        _ = try await seedQueue.enqueue(record)
        let queue = recreateQueueBeforeViewModel
            ? MirmirPendingWorkQueue(directoryURL: queueDirectory)
            : seedQueue
        let service = DefaultModelAssetsService { _ in
            VTModelStager(
                configurationProvider: provider,
                acquisitionAuthority: .systemDownloadAuthorized,
                pollingIntervalNanoseconds: 1_000_000
            )
        }
        let engine = VTQueueRecordingEngine()
        let viewModel = MirmirViewModel(
            mediaPipeline: VTQueueMediaPipeline(profile: profile),
            upscalerEngine: engine,
            modelAssets: service,
            pendingWorkQueue: queue,
            workHistoryBookmarkResolver: resolver,
            securityScopedResourceAccess:
                MirmirSecurityScopedResourceAccess(
                    startAccessing: { _ in true },
                    stopAccessing: { _ in },
                    canCreateBookmark: { _ in true }
                )
        )
        try await waitForQueueCondition {
            viewModel.pendingWorkRecords.map(\.id) == [record.id]
                && !viewModel.pendingQueueIsLoading
        }
        return VTQueuedQualityFixture(
            queue: queue,
            record: record,
            provider: provider,
            engine: engine,
            viewModel: viewModel
        )
    }

    @MainActor
    private func waitForQueueCondition(
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<4_000 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail(
            "Timed out waiting for queued model lifecycle condition.",
            file: file,
            line: line
        )
    }

    @MainActor
    private func waitForModelStatus(
        _ expectedStatus: ModelAssetsStatus,
        in viewModel: MirmirViewModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<1_000 {
            if viewModel.modelStatus == expectedStatus {
                return
            }
            await Task.yield()
        }
        XCTFail(
            "Timed out waiting for model status \(expectedStatus); "
                + "observed \(viewModel.modelStatus).",
            file: file,
            line: line
        )
    }

    private func makeQualityModelBinding(
        source: VideoResolution = .p1080,
        target: VideoResolution = .p2160
    ) throws
        -> ModelAssetsRouteBinding {
        let binding = try XCTUnwrap(
            R04VideoToolboxNativeRouteSelector.exactBinding(
                sourceResolution: source,
                targetResolution: target,
                intent: .quality
            )
        )
        return .videoToolboxQuality(binding)
    }
}

@available(macOS 26.0, *)
private struct VTQueuedQualityFixture {
    let queue: MirmirPendingWorkQueue
    let record: MirmirPendingWorkRecord
    let provider: VTControlledModelConfigurationProbe
    let engine: VTQueueRecordingEngine
    let viewModel: MirmirViewModel
}

private struct VTQueueBookmarkResolver:
    MirmirWorkHistoryBookmarkResolving {
    func makeBookmark(
        for url: URL,
        role _: MirmirWorkHistoryBookmarkRole
    ) throws -> Data {
        Data(url.path.utf8)
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
            url: URL(fileURLWithPath: path),
            isStale: false
        )
    }
}

private final class VTQueueMediaPipeline:
    MediaPipelineService,
    @unchecked Sendable {
    private let profile: SourceProfile

    init(profile: SourceProfile) {
        self.profile = profile
    }

    func probe(url: URL) async throws -> SourceProfile {
        guard url.standardizedFileURL
                == profile.url.standardizedFileURL else {
            throw MirmirWorkHistoryBookmarkError
                .resolutionFailed(role: .source)
        }
        return profile
    }

    func beginSession(
        source: SourceProfile,
        output: OutputProfile
    ) async throws -> MediaSession {
        try await NoopMediaPipelineService().beginSession(
            source: source,
            output: output
        )
    }

    func start() {}
    func stop() {}
}

private final class VTQueueRecordingEngine:
    UpscalerEngineService,
    @unchecked Sendable {
    let availability: UpscalerEngineAvailability = .available

    private struct State {
        var submittedJobs: [UpscaleJob] = []
        var latestHandle: VTQueueHoldingHandle?
    }

    private let lock = OSAllocatedUnfairLock(
        initialState: State()
    )

    var submittedJobs: [UpscaleJob] {
        lock.withLock { $0.submittedJobs }
    }

    var latestHandle: VTQueueHoldingHandle? {
        lock.withLock { $0.latestHandle }
    }

    func submit(_ job: UpscaleJob) throws -> UpscalerJobHandle {
        let handle = VTQueueHoldingHandle()
        lock.withLock { state in
            state.submittedJobs.append(job)
            state.latestHandle = handle
        }
        return handle
    }

    func start() {}
    func stop() {}
}

private final class VTQueueHoldingHandle:
    UpscalerJobHandle,
    @unchecked Sendable {
    private struct State {
        var result: Result<URL, Error>?
        var waiter: CheckedContinuation<URL, Error>?
    }

    let progressStream = AsyncStream<UpscaleProgress> {
        $0.finish()
    }
    private let lock = OSAllocatedUnfairLock(
        initialState: State()
    )

    func cancel() {
        complete(.failure(CancellationError()))
    }

    func waitForCompletion() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let completed: Result<URL, Error>? = lock.withLock { state in
                if let result = state.result { return result }
                state.waiter = continuation
                return nil
            }
            if let completed {
                continuation.resume(with: completed)
            }
        }
    }

    func completeCancellation() {
        complete(.failure(CancellationError()))
    }

    private func complete(_ result: Result<URL, Error>) {
        let waiter: CheckedContinuation<URL, Error>? = lock.withLock { state in
            guard state.result == nil else { return nil }
            state.result = result
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(with: result)
    }
}

private enum VTControlledModelProbeError: Error {
    case injectedDownloadFailure
    case injectedFactoryFailure
}

private final class VTControlledModelConfigurationProbe:
    VTModelConfigurationProviding,
    @unchecked Sendable {
    private struct State {
        var status: VTModelStagerStatus
        var downloadCount = 0
        var failuresRemaining: Int
    }

    private let lock: OSAllocatedUnfairLock<State>
    private let downloadDelayNanoseconds: UInt64

    init(
        status: VTModelStagerStatus,
        downloadDelayNanoseconds: UInt64 = 0,
        failuresBeforeSuccess: Int = 0
    ) {
        lock = OSAllocatedUnfairLock(
            initialState: State(
                status: status,
                failuresRemaining: failuresBeforeSuccess
            )
        )
        self.downloadDelayNanoseconds = downloadDelayNanoseconds
    }

    var downloadCount: Int {
        lock.withLock { $0.downloadCount }
    }

    func currentStatus() -> VTModelStagerStatus {
        lock.withLock { $0.status }
    }

    func downloadConfigurationModel() async throws {
        let mustFail = lock.withLock { state -> Bool in
            state.downloadCount += 1
            state.status = .downloading(progress: 0.25)
            guard state.failuresRemaining > 0 else { return false }
            state.failuresRemaining -= 1
            return true
        }

        if downloadDelayNanoseconds > 0 {
            try await Task.sleep(
                nanoseconds: downloadDelayNanoseconds / 2
            )
            lock.withLock {
                $0.status = .downloading(progress: 0.75)
            }
            try await Task.sleep(
                nanoseconds: downloadDelayNanoseconds
                    - downloadDelayNanoseconds / 2
            )
        }

        if mustFail {
            lock.withLock { $0.status = .downloadRequired }
            throw VTControlledModelProbeError.injectedDownloadFailure
        }
        lock.withLock { $0.status = .ready }
    }
}

private final class VTStagerFactoryProbe: @unchecked Sendable {
    private struct State {
        var makeCallCount = 0
        var failuresRemaining: Int
    }

    private let lock: OSAllocatedUnfairLock<State>
    private let provider: VTControlledModelConfigurationProbe?

    init(
        provider: VTControlledModelConfigurationProbe? = nil,
        failuresBeforeSuccess: Int = 0
    ) {
        self.provider = provider
        lock = OSAllocatedUnfairLock(
            initialState: State(
                failuresRemaining: failuresBeforeSuccess
            )
        )
    }

    var makeCallCount: Int {
        lock.withLock { $0.makeCallCount }
    }

    func make(
        binding _: R04VideoToolboxNativeRouteBinding
    ) throws -> VTModelStager {
        let mustFail = lock.withLock { state -> Bool in
            state.makeCallCount += 1
            guard state.failuresRemaining > 0 else { return false }
            state.failuresRemaining -= 1
            return true
        }
        if mustFail {
            throw VTControlledModelProbeError.injectedFactoryFailure
        }
        guard let provider else {
            return VTModelStager()
        }
        return VTModelStager(
            configurationProvider: provider,
            acquisitionAuthority: .systemDownloadAuthorized,
            pollingIntervalNanoseconds: 1_000_000
        )
    }
}
