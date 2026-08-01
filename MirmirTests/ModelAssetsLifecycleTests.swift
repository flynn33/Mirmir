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
            resolution: .p1080,
            frameRate: 30,
            durationSeconds: 1,
            estimatedFrameCount: 30,
            codecHint: "test",
            hasAudio: false
        )
        viewModel.targetResolution = .p2160
        viewModel.enginePreference = .automatic
        viewModel.selectedMode = .quality

        let qualityBinding = try makeQualityModelBinding()
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
                    R04VideoToolboxSubjectID.lowLatency2x.rawValue
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
        let expected = try makeQualityModelBinding()
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

    private func makeQualityModelBinding() throws
        -> ModelAssetsRouteBinding {
        let binding = try XCTUnwrap(
            R04VideoToolboxNativeRouteSelector.exactBinding(
                sourceResolution: .p1080,
                targetResolution: .p2160,
                intent: .quality
            )
        )
        return .videoToolboxQuality(binding)
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
