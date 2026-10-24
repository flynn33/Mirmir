import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox
import XCTest
@testable import Mirmir

final class BackendCatalogTests: XCTestCase {
    @MainActor
    func testModelDownloadProgressSuccessAndDuplicateStart() async throws {
        let backend = CatalogDownloadBackend()
        let model = await makeDownloadModel(backend)
        model.downloadSelectedModel()
        model.downloadSelectedModel()
        try await waitForDownloadCondition { await backend.callCount == 1 }
        await backend.report(-2)
        try await waitForDownloadCondition { model.modelDownloadProgress == 0 }
        await backend.report(2)
        try await waitForDownloadCondition { model.modelDownloadProgress == 1 }
        await backend.complete(failing: false)
        try await waitForDownloadCondition { !model.isDownloadingModel }
        await model.waitForBackendAvailability()
        XCTAssertEqual(model.modelDownloadMessage, "Apple model is ready.")
        XCTAssertEqual(model.modelDownloadProgress, 1)
        XCTAssertEqual(model.backendSnapshot?.entry(for: .videoToolboxSuperResolutionQuality)?.availability, .available)
        let calls = await backend.callCount
        XCTAssertEqual(calls, 1)
    }

    @MainActor
    func testModelDownloadFailureAllowsRetryAndClearIgnoresLateCallbacks() async throws {
        let backend = CatalogDownloadBackend()
        let model = await makeDownloadModel(backend)
        model.downloadSelectedModel()
        try await waitForDownloadCondition { await backend.callCount == 1 }
        await backend.complete(failing: true)
        try await waitForDownloadCondition { !model.isDownloadingModel }
        XCTAssertEqual(model.modelDownloadMessage, "Injected model download failure")
        await model.waitForBackendAvailability()
        XCTAssertEqual(model.backendSnapshot?.entry(for: .videoToolboxSuperResolutionQuality)?.availability, .modelDownloadRequired(progress: nil))
        model.downloadSelectedModel()
        try await waitForDownloadCondition { await backend.callCount == 2 }
        model.clear()
        await backend.report(0.8)
        await backend.complete(failing: false)
        // Drain the callback tasks from an API that finishes after cancellation.
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(model.isDownloadingModel)
        XCTAssertNil(model.modelDownloadProgress)
        XCTAssertNil(model.modelDownloadMessage)
        XCTAssertNil(model.currentVideoInfo)
    }

    @MainActor
    private func makeDownloadModel(_ backend: CatalogDownloadBackend) async -> MirmirViewModel {
        let source = makeVideoInfo(url: URL(fileURLWithPath: "/tmp/model-download-fixture.mov"))
        let model = MirmirViewModel(
            videoProbe: ImmediateCatalogVideoProbe(info: source),
            backendCatalog: UpscaleBackendCatalog(backends: [backend]),
            runtimeEnvironment: testEnvironment
        )
        model.selectBackend(.videoToolboxSuperResolutionQuality)
        model.selectVideo(source.url)
        await model.waitForCurrentProbe()
        await model.waitForBackendAvailability()
        return model
    }

    @MainActor
    private func waitForDownloadCondition(_ condition: @MainActor () async -> Bool) async throws {
        for _ in 0..<500 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw CatalogDownloadTestError.timeout
    }

    func testDeterministicReleaseDescriptorsContainNoPreviewIdentity() {
        for id in [
            UpscaleBackendID.mirmirDeterministicCPU,
            .mirmirDeterministicMetal
        ] {
            let descriptor = BackendDescriptor.descriptor(for: id)
            let releaseText = [descriptor?.title, descriptor?.summary]
                .compactMap { $0 }
                .joined(separator: " ")
                .lowercased()
            XCTAssertFalse(releaseText.contains("preview"))
            XCTAssertFalse(releaseText.contains("p05"))
            XCTAssertFalse(releaseText.contains("development"))
            XCTAssertTrue(releaseText.contains("p06"))
        }
    }

    func testDescriptorsContainEveryStablePickerIdentity() {
        XCTAssertEqual(BackendDescriptor.all.count, 14)
        XCTAssertEqual(
            Set(BackendDescriptor.all.map(\.id)),
            Set(UpscaleBackendID.allCases)
        )
        XCTAssertEqual(
            BackendDescriptor.descriptor(
                for: .videoToolboxInterpolationWithSpatialScale
            )?.group,
            .smoothMotion
        )
        XCTAssertEqual(
            BackendDescriptor.descriptor(
                for: .mirmirDeterministicMetal
            )?.id.rawValue,
            "mirmirDeterministicMetal"
        )
    }

    func testAutomaticOrderIsFixedAndExcludesNonSpatialChoices() {
        XCTAssertEqual(
            AutomaticBackendSelector.orderedBackendIDs,
            [
                .videoToolboxSuperResolutionQuality,
                .videoToolboxSuperResolutionLowLatency,
                .metalFXSpatial,
                .mpsLanczos,
                .coreImageLanczos,
                .vImageHighQuality,
                .videoToolboxPixelTransfer
            ]
        )
        XCTAssertFalse(
            AutomaticBackendSelector.orderedBackendIDs.contains(
                .videoToolboxInterpolationWithSpatialScale
            )
        )
        XCTAssertFalse(
            AutomaticBackendSelector.orderedBackendIDs.contains(
                .mirmirDeterministicCPU
            )
        )
    }

    func testAutomaticReportsFirstAvailableBackendInDocumentedOrder() async {
        let source = makeVideoInfo(
            url: URL(fileURLWithPath: "/tmp/catalog-source.mov")
        )
        var values = Dictionary(
            uniqueKeysWithValues: BackendDescriptor.concrete.map {
                ($0.id, BackendAvailability.available)
            }
        )
        values[.videoToolboxSuperResolutionQuality] = .unavailable(
            reason: .appleAPIUnsupported(details: "test rejection")
        )
        let catalog = UpscaleBackendCatalog(
            backends: makeStubBackends(values: values)
        )

        let snapshot = await catalog.snapshot(
            for: source,
            targetSize: CGSize(width: 640, height: 360),
            environment: testEnvironment
        )

        XCTAssertEqual(
            snapshot.automaticProposal,
            .videoToolboxSuperResolutionLowLatency
        )
        XCTAssertEqual(snapshot.entry(for: .automatic)?.availability, .available)
        XCTAssertEqual(snapshot.entries.count, 14)
    }

    func testExplicitUnavailableSelectionIsRetainedWithoutFallback() async {
        let source = makeVideoInfo(
            url: URL(fileURLWithPath: "/tmp/catalog-explicit.mov")
        )
        var values = Dictionary(
            uniqueKeysWithValues: BackendDescriptor.concrete.map {
                ($0.id, BackendAvailability.available)
            }
        )
        let unavailable = BackendAvailability.unavailable(
            reason: .noMetalDevice
        )
        values[.mpsLanczos] = unavailable
        let catalog = UpscaleBackendCatalog(
            backends: makeStubBackends(values: values)
        )
        let snapshot = await catalog.snapshot(
            for: source,
            targetSize: CGSize(width: 640, height: 360),
            environment: testEnvironment
        )

        let resolution = snapshot.resolution(for: .mpsLanczos)

        XCTAssertEqual(resolution.requestedBackendID, .mpsLanczos)
        XCTAssertEqual(resolution.actualBackendID, .mpsLanczos)
        XCTAssertEqual(resolution.availability, unavailable)
    }

    func testUnavailableReasonMappingIsActionableAndNotQualificationLanguage() {
        let text = BackendUnavailableReason.processingAdapterNotImplemented(
            backendID: .vImageHighQuality
        ).userFacingDescription

        XCTAssertTrue(text.contains("Accelerate/vImage High Quality"))
        XCTAssertTrue(text.contains("does not include"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("qualification"))
        XCTAssertEqual(
            BackendAvailability.unavailable(reason: .noMetalDevice).statusText,
            "Unavailable: No compatible Metal device is available on this Mac."
        )
    }

    func testSystemCapabilityProbeRejectsSubpixelDimensionsThatRoundToZero() async {
        let source = makeVideoInfo(
            url: URL(fileURLWithPath: "/tmp/catalog-subpixel.mov")
        )

        let availability = await SystemBackendCapabilityProbe().availability(
            for: .coreImageLanczos,
            source: source,
            targetSize: CGSize(width: 0.0009, height: 180)
        )

        XCTAssertEqual(
            availability,
            .unavailable(
                reason: .unsupportedTargetDimensions(
                    width: 0,
                    height: 0,
                    details: "The target must have positive integral dimensions."
                )
            )
        )
    }

    func testSmoothMotionRejectsSourceBeyondReportedTwoXGeometryLimit()
        async throws {
        guard #available(macOS 27.0, *) else { return }
        if !VTLowLatencyFrameInterpolationConfiguration.isSupported {
            let source = makeVideoInfo(
                url: URL(fileURLWithPath: "/tmp/catalog-smooth-motion-unsupported.mov"),
                encodedSize: CGSize(width: 64, height: 64)
            )
            let availability = await SystemBackendCapabilityProbe().availability(
                for: .videoToolboxInterpolationWithSpatialScale,
                source: source,
                targetSize: CGSize(width: 128, height: 128)
            )
            XCTAssertEqual(availability, .unavailable(reason: .appleAPIUnsupported(
                details: "VTLowLatencyFrameInterpolationConfiguration.isSupported is false"
            )))
            return
        }
        let maximumDimension = try XCTUnwrap(
            VTLowLatencyFrameInterpolationConfiguration
                .maximumDimension(forSpatialScaleFactor: 2)
        )
        let sourceWidth = maximumDimension + 1
        let source = makeVideoInfo(
            url: URL(fileURLWithPath: "/tmp/catalog-smooth-motion-limit.mov"),
            encodedSize: CGSize(width: sourceWidth, height: 2)
        )

        let availability = await SystemBackendCapabilityProbe().availability(
            for: .videoToolboxInterpolationWithSpatialScale,
            source: source,
            targetSize: CGSize(width: sourceWidth * 2, height: 4)
        )

        guard case .unavailable(
            reason: .unsupportedSourceDimensions(
                let width,
                let height,
                let details
            )
        ) = availability else {
            return XCTFail("Expected the reported Smooth Motion geometry limit")
        }
        XCTAssertEqual(width, sourceWidth)
        XCTAssertEqual(height, 2)
        XCTAssertTrue(details.contains("maximum dimension of \(maximumDimension)"))
    }

    func testHDRAvoidsEveryEightBitBackendAndAdmitsDeterministicP010()
        async throws {
        let source = makeVideoInfo(
            url: URL(fileURLWithPath: "/tmp/catalog-hdr.mov"),
            bitDepth: 10,
            pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            dynamicRange: .hdr
        )
        let snapshot = await UpscaleBackendCatalog.live().snapshot(
            for: source,
            targetSize: CGSize(width: 640, height: 360),
            environment: .current()
        )

        let deterministicIDs: Set<UpscaleBackendID> = [
            .mirmirDeterministicCPU,
            .mirmirDeterministicMetal
        ]
        for descriptor in BackendDescriptor.concrete
            where !deterministicIDs.contains(descriptor.id) {
            XCTAssertEqual(
                snapshot.entry(for: descriptor.id)?.availability,
                .unavailable(reason: .hdrPreservationUnavailable),
                "\(descriptor.title) must not silently convert HDR to SDR."
            )
        }
        let runtime = try ASHV4SemanticArtifactTestSupport
            .executableSystemMetalRuntime()
        let cpuDescriptor = try XCTUnwrap(
            BackendDescriptor.descriptor(for: .mirmirDeterministicCPU)
        )
        let cpu = try XCTUnwrap(DeterministicCPUBackend(
            descriptor: cpuDescriptor,
            runtimeProvider: .fixed(runtime)
        ))
        let cpuAvailability = await cpu.availability(
            for: source,
            targetSize: CGSize(width: 640, height: 360),
            environment: .current()
        )
        XCTAssertEqual(cpuAvailability, .available)
        let metalDescriptor = try XCTUnwrap(
            BackendDescriptor.descriptor(for: .mirmirDeterministicMetal)
        )
        let metal = try XCTUnwrap(DeterministicMetalBackend(
            descriptor: metalDescriptor,
            runtimeProvider: .fixed(runtime)
        ))
        let metalAvailability = await metal.availability(
            for: source,
            targetSize: CGSize(width: 640, height: 360),
            environment: .current()
        )
        XCTAssertTrue(
            metalAvailability == .available
                || metalAvailability == .unavailable(reason: .noMetalDevice)
        )
        XCTAssertEqual(
            snapshot.entry(for: .automatic)?.availability,
            .unavailable(reason: .noCompatibleAutomaticBackend)
        )
    }

    @MainActor
    func testViewModelStartupDoesNotProbeBackends() async {
        let counter = ProbeCounter()
        let backends = BackendDescriptor.concrete.map {
            CountingBackend(descriptor: $0, counter: counter)
                as any UpscaleBackend
        }
        let catalog = UpscaleBackendCatalog(backends: backends)

        _ = MirmirViewModel(
            videoProbe: WaitingCatalogVideoProbe(),
            backendCatalog: catalog,
            runtimeEnvironment: testEnvironment
        )

        let probeCount = await counter.value()
        XCTAssertEqual(probeCount, 0)
    }

    @MainActor
    func testViewModelRetainsExplicitSelectionAfterAvailabilityRefresh() async {
        let url = URL(fileURLWithPath: "/tmp/catalog-view-model.mov")
        let source = makeVideoInfo(url: url)
        let unavailable = BackendAvailability.unavailable(
            reason: .processingAdapterNotImplemented(
                backendID: .mpsLanczos
            )
        )
        let values = Dictionary(
            uniqueKeysWithValues: BackendDescriptor.concrete.map {
                ($0.id, unavailable)
            }
        )
        let viewModel = MirmirViewModel(
            videoProbe: ImmediateCatalogVideoProbe(info: source),
            backendCatalog: UpscaleBackendCatalog(
                backends: makeStubBackends(values: values)
            ),
            runtimeEnvironment: testEnvironment
        )

        viewModel.selectBackend(.mpsLanczos)
        viewModel.selectVideo(url)
        await viewModel.waitForCurrentProbe()
        await viewModel.waitForBackendAvailability()

        XCTAssertEqual(viewModel.selectedBackendID, .mpsLanczos)
        XCTAssertEqual(
            viewModel.backendSnapshot?.entry(for: .mpsLanczos)?.availability,
            unavailable
        )
    }

    @MainActor
    func testViewModelProvidesExactThreeOverTwoPresetForDeterministicRoute() async {
        let url = URL(fileURLWithPath: "/tmp/catalog-three-over-two.mov")
        let source = makeVideoInfo(
            url: url,
            encodedSize: CGSize(width: 320, height: 180)
        )
        let viewModel = MirmirViewModel(
            videoProbe: ImmediateCatalogVideoProbe(info: source),
            runtimeEnvironment: testEnvironment
        )

        viewModel.selectVideo(url)
        await viewModel.waitForCurrentProbe()
        viewModel.applyScale(numerator: 3, denominator: 2)
        await viewModel.waitForBackendAvailability()

        XCTAssertEqual(viewModel.targetWidth, 480)
        XCTAssertEqual(viewModel.targetHeight, 270)
        XCTAssertEqual(viewModel.backendTargetSize, CGSize(width: 480, height: 270))
    }

    @MainActor
    func testQualitySelectionWarnsBeforeChangingDefaultTargetToSupportedScale() async throws {
        let url = URL(fileURLWithPath: "/tmp/catalog-quality-adjustment.mov")
        let source = makeVideoInfo(
            url: url,
            encodedSize: CGSize(width: 320, height: 180)
        )
        var values = Dictionary(
            uniqueKeysWithValues: BackendDescriptor.concrete.map {
                ($0.id, BackendAvailability.available)
            }
        )
        values[.videoToolboxSuperResolutionQuality] = .unavailable(
            reason: .unsupportedScaleFactor(
                details: "requested 2×; this Mac reports [4]"
            )
        )
        let viewModel = MirmirViewModel(
            videoProbe: ImmediateCatalogVideoProbe(info: source),
            backendCatalog: UpscaleBackendCatalog(
                backends: makeStubBackends(values: values)
            ),
            runtimeEnvironment: testEnvironment,
            superResolutionScaleProvider: { backendID, _, _ in
                backendID == .videoToolboxSuperResolutionQuality ? [4] : [2, 4]
            }
        )

        viewModel.selectVideo(url)
        await viewModel.waitForCurrentProbe()
        await viewModel.waitForBackendAvailability()

        let adjustment = try XCTUnwrap(
            viewModel.targetAdjustmentForSelecting(
                .videoToolboxSuperResolutionQuality
            )
        )
        XCTAssertEqual(viewModel.targetWidth, 640)
        XCTAssertEqual(viewModel.targetHeight, 360)
        XCTAssertEqual(adjustment.proposedScaleFactor, 4)
        XCTAssertEqual(adjustment.proposedTargetWidth, 1_280)
        XCTAssertEqual(adjustment.proposedTargetHeight, 720)
        XCTAssertTrue(adjustment.message.contains("current 2× target"))
        XCTAssertTrue(adjustment.message.contains("quality model"))

        viewModel.applyBackendSelectionAdjustment(adjustment)
        await viewModel.waitForBackendAvailability()

        XCTAssertEqual(
            viewModel.selectedBackendID,
            .videoToolboxSuperResolutionQuality
        )
        XCTAssertEqual(viewModel.targetWidth, 1_280)
        XCTAssertEqual(viewModel.targetHeight, 720)
    }

    @MainActor
    func testLowLatencyDefaultTwoXSelectionNeedsNoTargetWarning() async {
        let url = URL(fileURLWithPath: "/tmp/catalog-low-latency-default.mov")
        let source = makeVideoInfo(url: url)
        let values = Dictionary(
            uniqueKeysWithValues: BackendDescriptor.concrete.map {
                ($0.id, BackendAvailability.available)
            }
        )
        let viewModel = MirmirViewModel(
            videoProbe: ImmediateCatalogVideoProbe(info: source),
            backendCatalog: UpscaleBackendCatalog(
                backends: makeStubBackends(values: values)
            ),
            runtimeEnvironment: testEnvironment,
            superResolutionScaleProvider: { _, _, _ in [2, 4] }
        )

        viewModel.selectVideo(url)
        await viewModel.waitForCurrentProbe()
        await viewModel.waitForBackendAvailability()

        XCTAssertNil(
            viewModel.targetAdjustmentForSelecting(
                .videoToolboxSuperResolutionLowLatency
            )
        )
        viewModel.selectBackend(.videoToolboxSuperResolutionLowLatency)
        XCTAssertEqual(viewModel.targetWidth, 640)
        XCTAssertEqual(viewModel.targetHeight, 360)
    }

    @MainActor
    func testQualitySelectionBeforeSourceWarnsAndChangesInitialDefaultAfterConsent() async {
        let url = URL(fileURLWithPath: "/tmp/catalog-quality-presource.mov")
        let source = makeVideoInfo(url: url)
        let viewModel = MirmirViewModel(
            videoProbe: ImmediateCatalogVideoProbe(info: source),
            runtimeEnvironment: testEnvironment,
            superResolutionScaleProvider: { backendID, _, _ in
                backendID == .videoToolboxSuperResolutionQuality ? [4] : [2, 4]
            }
        )

        let adjustment = try? XCTUnwrap(
            viewModel.targetAdjustmentForSelecting(
                .videoToolboxSuperResolutionQuality
            )
        )
        XCTAssertNil(adjustment?.sourceURL)
        XCTAssertEqual(adjustment?.proposedScaleFactor, 4)
        XCTAssertTrue(adjustment?.message.contains("normally starts") == true)
        guard let adjustment else { return }

        viewModel.applyBackendSelectionAdjustment(adjustment)
        XCTAssertEqual(
            viewModel.selectedBackendID,
            .videoToolboxSuperResolutionQuality
        )

        viewModel.selectVideo(url)
        await viewModel.waitForCurrentProbe()
        await viewModel.waitForBackendAvailability()

        XCTAssertEqual(viewModel.targetWidth, 1_280)
        XCTAssertEqual(viewModel.targetHeight, 720)
    }

    @MainActor
    func testViewModelRejectsUnrepresentableAndRoundedZeroEncodedDimensions() async {
        let sizes = [
            CGSize(width: CGFloat(Int.max), height: 180),
            CGSize(width: 0.0009, height: 180)
        ]

        for (index, size) in sizes.enumerated() {
            let url = URL(
                fileURLWithPath: "/tmp/catalog-invalid-geometry-\(index).mov"
            )
            let source = makeVideoInfo(url: url, encodedSize: size)
            let viewModel = MirmirViewModel(
                videoProbe: ImmediateCatalogVideoProbe(info: source),
                runtimeEnvironment: testEnvironment
            )

            viewModel.selectVideo(url)
            await viewModel.waitForCurrentProbe()

            XCTAssertEqual(viewModel.state, .ready(source))
            XCTAssertEqual(
                viewModel.backendAvailabilityMessage,
                "Backend availability requires positive integral encoded dimensions."
            )
            XCTAssertNil(viewModel.backendTargetSize)
            XCTAssertNil(viewModel.backendSnapshot)
        }
    }

    @MainActor
    func testDurableQueueKeepsEnqueueAvailableWhileDisablingImmediateStart()
        async throws {
        let sourceURL = URL(fileURLWithPath: "/tmp/catalog-queued-source.mov")
        let source = makeVideoInfo(url: sourceURL)
        let generatedAt = WorkflowWallClockInstantV4(
            nanosecondsSinceUnixEpoch: 42
        )
        let emptyQueue = WorkflowApplicationQueueSnapshotV4(
            generatedAt: generatedAt,
            items: []
        )
        let controller = CatalogQueueStateControllerV4(
            queue: emptyQueue,
            recovery: WorkflowLaunchRecoverySnapshotV4(
                generatedAt: generatedAt,
                items: []
            )
        )
        let values = Dictionary(
            uniqueKeysWithValues: BackendDescriptor.concrete.map {
                ($0.id, BackendAvailability.available)
            }
        )
        let viewModel = MirmirViewModel(
            videoProbe: ImmediateCatalogVideoProbe(info: source),
            backendCatalog: UpscaleBackendCatalog(
                backends: makeStubBackends(values: values)
            ),
            runtimeEnvironment: testEnvironment,
            workflowController: controller
        )
        await viewModel.initializeWorkflow()
        viewModel.selectBackend(.mirmirDeterministicCPU)
        viewModel.selectVideo(sourceURL)
        await viewModel.waitForCurrentProbe()
        await viewModel.waitForBackendAvailability()
        viewModel.setOutputURL(
            URL(fileURLWithPath: "/tmp/catalog-queued-output.mov")
        )

        XCTAssertTrue(viewModel.canStart)
        XCTAssertTrue(viewModel.canEnqueueWorkflow)

        let activeQueue = WorkflowApplicationQueueSnapshotV4(
            generatedAt: generatedAt,
            items: [try catalogQueueItem(lifecycle: .running)]
        )
        await controller.publish(activeQueue)
        for _ in 0..<20 { await Task.yield() }

        XCTAssertTrue(viewModel.isWorkflowProcessing)
        XCTAssertFalse(viewModel.canStart)
        XCTAssertTrue(viewModel.canEnqueueWorkflow)
        XCTAssertEqual(
            viewModel.startValidationMessage,
            "A durable job is active. Add this request to the queue."
        )
    }

    @MainActor
    func testProRes422SelectionRoundTripsIntoDurableRequest() async throws {
        let sourceURL = URL(
            fileURLWithPath: "/tmp/catalog-prores422-source.mov"
        )
        let outputURL = URL(
            fileURLWithPath: "/tmp/catalog-prores422-output.mov"
        )
        let source = makeVideoInfo(url: sourceURL)
        let generatedAt = WorkflowWallClockInstantV4(
            nanosecondsSinceUnixEpoch: 43
        )
        let controller = CatalogQueueStateControllerV4(
            queue: WorkflowApplicationQueueSnapshotV4(
                generatedAt: generatedAt,
                items: []
            ),
            recovery: WorkflowLaunchRecoverySnapshotV4(
                generatedAt: generatedAt,
                items: []
            )
        )
        let values = Dictionary(
            uniqueKeysWithValues: BackendDescriptor.concrete.map {
                ($0.id, BackendAvailability.available)
            }
        )
        let viewModel = MirmirViewModel(
            videoProbe: ImmediateCatalogVideoProbe(info: source),
            backendCatalog: UpscaleBackendCatalog(
                backends: makeStubBackends(values: values)
            ),
            runtimeEnvironment: testEnvironment,
            workflowController: controller
        )

        await viewModel.initializeWorkflow()
        viewModel.selectBackend(.mirmirDeterministicCPU)
        viewModel.selectVideo(sourceURL)
        await viewModel.waitForCurrentProbe()
        await viewModel.waitForBackendAvailability()
        viewModel.setOutputCodec(.proRes422)
        viewModel.setPreserveAudio(false)
        viewModel.setOutputURL(outputURL)
        XCTAssertTrue(viewModel.canStart)

        viewModel.startUpscale()
        await viewModel.waitForProcessing()

        let submittedRequest = await controller.latestSubmittedRequest()
        let request = try XCTUnwrap(submittedRequest)
        XCTAssertEqual(request.inputURL, sourceURL)
        XCTAssertEqual(request.outputURL, outputURL)
        XCTAssertEqual(request.backendID, .mirmirDeterministicCPU)
        XCTAssertEqual(request.targetWidth, 640)
        XCTAssertEqual(request.targetHeight, 360)
        XCTAssertEqual(request.outputCodec, .proRes422)
        XCTAssertEqual(request.preserveAudio, false)
        XCTAssertEqual(request.overwriteExistingFile, false)
    }

    @MainActor
    func testCompletedWorkflowKeepsOriginalSourceAfterSnapshotCleanup() async throws {
        let original = makeVideoInfo(url: URL(fileURLWithPath: "/tmp/original.mov"))
        let snapshot = makeVideoInfo(url: URL(fileURLWithPath: "/tmp/deleted-private-snapshot/original.mov"))
        let output = URL(fileURLWithPath: "/tmp/completed.mov")
        let instant = WorkflowWallClockInstantV4(nanosecondsSinceUnixEpoch: 45)
        let completion = WorkflowApplicationRunOutcomeV4.completed(
            WorkflowApplicationCompletionV4(source: snapshot, result: UpscaleResult(
                outputURL: output, actualBackendID: .mirmirDeterministicCPU,
                encodedWidth: 640, encodedHeight: 360, durationSeconds: 1,
                outputCodec: .hevc, audioResult: .absent,
                processedFrameCount: 24, processingDurationSeconds: 1
            ))
        )
        let controller = CatalogQueueStateControllerV4(
            queue: .init(generatedAt: instant, items: []),
            recovery: .init(generatedAt: instant, items: [])
        )
        let jobID = try WorkflowJobID("paused-original-selection")
        await controller.setOutcomes([
            .paused(jobID: jobID, source: snapshot), completion
        ])
        let values = Dictionary(uniqueKeysWithValues: BackendDescriptor.concrete.map {
            ($0.id, BackendAvailability.available)
        })
        let model = MirmirViewModel(
            videoProbe: ImmediateCatalogVideoProbe(info: original),
            backendCatalog: UpscaleBackendCatalog(backends: makeStubBackends(values: values)),
            runtimeEnvironment: testEnvironment, workflowController: controller
        )
        await model.initializeWorkflow()
        model.selectBackend(.mirmirDeterministicCPU)
        model.selectVideo(original.url)
        await model.waitForCurrentProbe()
        await model.waitForBackendAvailability()
        model.setOutputURL(output)
        XCTAssertTrue(model.canStart)
        model.startUpscale()
        await model.waitForProcessing()
        XCTAssertEqual(model.currentVideoInfo?.url, original.url)
        model.clear()
        model.resumeWorkflowJob(jobID)
        await model.waitForProcessing()
        guard case .completed(let source, _) = model.state else {
            return XCTFail("Expected completed workflow")
        }
        XCTAssertEqual(source.url, original.url)
        XCTAssertEqual(model.currentVideoInfo?.url, original.url)
        XCTAssertEqual(model.completedComparisonSourceURL, original.url)

        // A recovered job with no retained original must not offer a deleted
        // processing snapshot as a usable comparison file.
        model.clear()
        await controller.setOutcomes([completion])
        model.resumeWorkflowJob(try WorkflowJobID("recovered-other-job"))
        await model.waitForProcessing()
        XCTAssertNil(model.completedComparisonSourceURL)
    }

    @MainActor
    func testProRes4444AllowsOddIntegralAlphaGeometryInProductDraft()
        async throws {
        let sourceURL = URL(
            fileURLWithPath: "/tmp/catalog-prores4444-alpha-source.mov"
        )
        let source = makeVideoInfo(
            url: sourceURL,
            alphaModel: .straight
        )
        let generatedAt = WorkflowWallClockInstantV4(
            nanosecondsSinceUnixEpoch: 44
        )
        let controller = CatalogQueueStateControllerV4(
            queue: WorkflowApplicationQueueSnapshotV4(
                generatedAt: generatedAt,
                items: []
            ),
            recovery: WorkflowLaunchRecoverySnapshotV4(
                generatedAt: generatedAt,
                items: []
            )
        )
        let values = Dictionary(
            uniqueKeysWithValues: BackendDescriptor.concrete.map {
                ($0.id, BackendAvailability.available)
            }
        )
        let viewModel = MirmirViewModel(
            videoProbe: ImmediateCatalogVideoProbe(info: source),
            backendCatalog: UpscaleBackendCatalog(
                backends: makeStubBackends(values: values)
            ),
            runtimeEnvironment: testEnvironment,
            workflowController: controller
        )

        await viewModel.initializeWorkflow()
        viewModel.selectBackend(.mirmirDeterministicCPU)
        viewModel.selectVideo(sourceURL)
        await viewModel.waitForCurrentProbe()
        viewModel.setTargetWidth(641)
        viewModel.setTargetHeight(361)
        await viewModel.waitForBackendAvailability()
        viewModel.setOutputURL(
            URL(fileURLWithPath: "/tmp/catalog-prores4444-alpha-output.mov")
        )

        viewModel.setOutputCodec(.proRes4444)
        XCTAssertNil(viewModel.startValidationMessage)
        XCTAssertTrue(viewModel.canStart)

        viewModel.setOutputCodec(.h264)
        XCTAssertEqual(
            viewModel.startValidationMessage,
            "4:2:0 output requires even encoded dimensions."
        )
        XCTAssertFalse(viewModel.canStart)
    }
}

private let testEnvironment = RuntimeEnvironment(
    operatingSystem: RuntimeOperatingSystem(
        OperatingSystemVersion(
            majorVersion: 26,
            minorVersion: 0,
            patchVersion: 0
        )
    ),
    capabilityProbe: TestCapabilityProbe()
)

private struct TestCapabilityProbe: BackendCapabilityProbing {
    func availability(
        for backendID: UpscaleBackendID,
        source: VideoInfo,
        targetSize: CGSize
    ) async -> BackendAvailability {
        .unavailable(
            reason: .appleAPIUnsupported(
                details: "The injected stub backend owns this test result."
            )
        )
    }
}

private struct StubBackend: UpscaleBackend {
    let descriptor: BackendDescriptor
    let value: BackendAvailability

    func availability(
        for source: VideoInfo,
        targetSize: CGSize,
        environment: RuntimeEnvironment
    ) async -> BackendAvailability {
        value
    }

    func prepare(
        request: BackendPreparationRequest,
        environment: RuntimeEnvironment
    ) async throws -> any PreparedFrameUpscaler {
        throw BackendPreparationError.unavailable(
            descriptor.id,
            .processingAdapterNotImplemented(backendID: descriptor.id)
        )
    }
}

private actor ProbeCounter {
    private var count = 0

    func record() {
        count += 1
    }

    func value() -> Int {
        count
    }
}

private struct CountingBackend: UpscaleBackend {
    let descriptor: BackendDescriptor
    let counter: ProbeCounter

    func availability(
        for source: VideoInfo,
        targetSize: CGSize,
        environment: RuntimeEnvironment
    ) async -> BackendAvailability {
        await counter.record()
        return .available
    }

    func prepare(
        request: BackendPreparationRequest,
        environment: RuntimeEnvironment
    ) async throws -> any PreparedFrameUpscaler {
        throw BackendPreparationError.unavailable(
            descriptor.id,
            .processingAdapterNotImplemented(backendID: descriptor.id)
        )
    }
}

private struct WaitingCatalogVideoProbe: VideoProbing {
    func probe(url: URL) async throws -> VideoInfo {
        try await Task.sleep(nanoseconds: 60_000_000_000)
        throw CancellationError()
    }
}

private struct ImmediateCatalogVideoProbe: VideoProbing {
    let info: VideoInfo

    func probe(url: URL) async throws -> VideoInfo {
        info
    }
}

private enum CatalogQueueStateControllerErrorV4: Error {
    case unsupported
}

private actor CatalogQueueStateControllerV4:
    WorkflowApplicationControllingV4
{
    private var queue: WorkflowApplicationQueueSnapshotV4
    private let recovery: WorkflowLaunchRecoverySnapshotV4
    private var observer = WorkflowApplicationObserverV4.none
    private var submittedRequests: [UpscaleRequest] = []
    private var outcomes: [WorkflowApplicationRunOutcomeV4] = []

    func setOutcomes(_ outcomes: [WorkflowApplicationRunOutcomeV4]) {
        self.outcomes = outcomes
    }

    init(
        queue: WorkflowApplicationQueueSnapshotV4,
        recovery: WorkflowLaunchRecoverySnapshotV4
    ) {
        self.queue = queue
        self.recovery = recovery
    }

    func installObserver(_ observer: WorkflowApplicationObserverV4) async {
        self.observer = observer
    }

    func launch() async throws -> WorkflowApplicationLaunchSnapshotV4 {
        WorkflowApplicationLaunchSnapshotV4(
            queue: queue,
            recovery: recovery
        )
    }

    func enqueue(
        request _: UpscaleRequest,
        priority _: Int32
    ) async throws -> WorkflowApplicationEnqueueReceiptV4 {
        throw CatalogQueueStateControllerErrorV4.unsupported
    }

    func submit(
        request: UpscaleRequest,
        progress _: @escaping @Sendable (UpscaleProgress) -> Void,
        snapshot _: @escaping @Sendable (
            WorkflowApplicationQueueSnapshotV4
        ) -> Void
    ) async throws -> WorkflowApplicationRunOutcomeV4 {
        submittedRequests.append(request)
        if !outcomes.isEmpty { return outcomes.removeFirst() }
        throw CatalogQueueStateControllerErrorV4.unsupported
    }

    func latestSubmittedRequest() -> UpscaleRequest? {
        submittedRequests.last
    }

    func requestPause() async throws {
        throw CatalogQueueStateControllerErrorV4.unsupported
    }

    func cancelActive() async throws {
        throw CatalogQueueStateControllerErrorV4.unsupported
    }

    func resume(
        jobID _: WorkflowJobID,
        progress _: @escaping @Sendable (UpscaleProgress) -> Void,
        snapshot _: @escaping @Sendable (
            WorkflowApplicationQueueSnapshotV4
        ) -> Void
    ) async throws -> WorkflowApplicationRunOutcomeV4 {
        if !outcomes.isEmpty { return outcomes.removeFirst() }
        throw CatalogQueueStateControllerErrorV4.unsupported
    }

    func queueSnapshot() async throws -> WorkflowApplicationQueueSnapshotV4 {
        queue
    }

    func setPriority(jobID _: WorkflowJobID, value _: Int32) async throws {
        throw CatalogQueueStateControllerErrorV4.unsupported
    }

    func move(
        jobID _: WorkflowJobID,
        direction _: WorkflowApplicationQueueMoveV4
    ) async throws {
        throw CatalogQueueStateControllerErrorV4.unsupported
    }

    func deleteCachedJob(jobID _: WorkflowJobID) async throws {
        throw CatalogQueueStateControllerErrorV4.unsupported
    }

    func deleteCachedJobs(
        selection _: WorkflowCachedJobSelectionV4
    ) async throws -> Int {
        throw CatalogQueueStateControllerErrorV4.unsupported
    }

    func clearCache() async throws -> WorkflowCacheClearResultV4 {
        throw CatalogQueueStateControllerErrorV4.unsupported
    }

    func publish(_ queue: WorkflowApplicationQueueSnapshotV4) {
        self.queue = queue
        observer.snapshot(queue)
    }
}

private func catalogQueueItem(
    lifecycle: WorkflowJobLifecycle
) throws -> WorkflowApplicationQueueItemV4 {
    let digest = String(repeating: "a", count: 64)
    return WorkflowApplicationQueueItemV4(
        jobID: try WorkflowJobID("catalog-active-job"),
        lifecycle: lifecycle,
        queueOrdinal: nil,
        priority: 0,
        binding: WorkflowJobBinding(
            jobID: try WorkflowJobID("catalog-active-job"),
            requestID: try WorkflowRequestID(digest),
            sourceIdentityID: try WorkflowSourceIdentityID(digest),
            outputContractID: try WorkflowOutputContractID(digest),
            planID: try WorkflowPlanID(digest),
            runtimeBindingID: try WorkflowRuntimeBindingID(digest)
        ),
        requestRecordStatus: .missing,
        request: nil
    )
}

private func makeStubBackends(
    values: [UpscaleBackendID: BackendAvailability]
) -> [any UpscaleBackend] {
    BackendDescriptor.concrete.map { descriptor in
        StubBackend(
            descriptor: descriptor,
            value: values[descriptor.id]
                ?? .unavailable(
                    reason: .sdkAdapterNotCompiled(
                        requiredSymbol: descriptor.id.rawValue
                    )
                )
        ) as any UpscaleBackend
    }
}

private func makeVideoInfo(
    url: URL,
    encodedSize: CGSize = CGSize(width: 320, height: 180),
    bitDepth: Int = 8,
    pixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
    dynamicRange: VideoDynamicRange = .sdr,
    alphaModel: CanonicalAlphaModelV4 = .none
) -> VideoInfo {
    VideoInfo(
        url: url,
        duration: CMTime(seconds: 1, preferredTimescale: 600),
        geometry: VideoGeometry(
            encodedSize: encodedSize,
            naturalSize: encodedSize,
            presentationSize: encodedSize,
            displaySize: encodedSize,
            preferredTransform: .identity,
            cleanAperture: nil,
            pixelAspectRatio: VideoPixelAspectRatio(
                horizontalSpacing: 1,
                verticalSpacing: 1
            )
        ),
        nominalFrameRate: 30,
        minimumFrameDuration: CMTime(value: 1, timescale: 30),
        estimatedFrameCount: 30,
        estimatedDataRate: nil,
        codecFourCC: kCMVideoCodecType_H264,
        hasAudio: false,
        audioTrackCount: 0,
        videoTrackCount: 1,
        isReadable: true,
        isPlayable: true,
        fileSizeBytes: nil,
        color: VideoColorInfo(
            colorPrimaries: kCVImageBufferColorPrimaries_ITU_R_709_2 as String,
            transferFunction: kCVImageBufferTransferFunction_ITU_R_709_2 as String,
            yCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String,
            bitDepth: bitDepth,
            pixelFormat: pixelFormat,
            isFullRange: false,
            fieldCount: 1,
            fieldDetail: nil,
            alphaModel: alphaModel,
            hasMasteringDisplayMetadata: false,
            hasContentLightLevelMetadata: false,
            dynamicRange: dynamicRange
        )
    )
}

private enum CatalogDownloadTestError: Error { case timeout }

private actor CatalogDownloadBackend: ModelDownloadableBackend {
    nonisolated let descriptor = BackendDescriptor.descriptor(for: .videoToolboxSuperResolutionQuality)!
    private(set) var callCount = 0
    private var ready = false
    private var continuation: CheckedContinuation<Void, Error>?
    private var progress: (@Sendable (Double) -> Void)?

    func availability(for source: VideoInfo, targetSize: CGSize, environment: RuntimeEnvironment) async -> BackendAvailability {
        ready ? .available : .modelDownloadRequired(progress: nil)
    }

    func prepare(request: BackendPreparationRequest, environment: RuntimeEnvironment) async throws -> any PreparedFrameUpscaler {
        throw MirmirError.invalidRequest("The download-state fixture must not prepare frames.")
    }

    func downloadModel(request: BackendPreparationRequest, environment: RuntimeEnvironment, progress: @escaping @Sendable (Double) -> Void) async throws {
        callCount += 1
        self.progress = progress
        try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func report(_ value: Double) { progress?(value) }

    func complete(failing: Bool) {
        let pending = continuation
        continuation = nil
        if failing {
            pending?.resume(throwing: NSError(domain: "model-download-test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Injected model download failure"]))
        } else {
            ready = true
            pending?.resume()
        }
    }
}
