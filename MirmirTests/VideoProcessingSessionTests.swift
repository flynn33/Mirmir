import AVFoundation
import XCTest
@testable import Mirmir

final class VideoProcessingSessionTests: XCTestCase {
    private struct EndToEndBaselineRun: Codable {
        let backendID: String
        let sampleIndex: Int
        let wallMilliseconds: Double
        let sessionMilliseconds: Double
        let processedFrameCount: Int
        let outputByteCount: Int
        let stageMilliseconds: [String: Double]
        let stageSampleCounts: [String: Int]
    }

    private struct EndToEndBaselineCapture: Codable {
        let schemaVersion: String
        let inputFile: String
        let inputByteCount: Int
        let targetWidth: Int
        let targetHeight: Int
        let outputCodec: String
        let warmupCount: Int
        let sampleCount: Int
        let runs: [EndToEndBaselineRun]
    }

    func testCaptureV3EndToEndBaselineWhenRequested() async throws {
        guard let requestedDirectory = ProcessInfo.processInfo.environment[
            "MIRMIR_V4_BASELINE_DIR"
        ], !requestedDirectory.isEmpty else {
            throw XCTSkip("Set MIRMIR_V4_BASELINE_DIR to capture end-to-end timing.")
        }

        let outputDirectory = URL(fileURLWithPath: requestedDirectory, isDirectory: true)
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        let warmupCount = max(
            0,
            Int(ProcessInfo.processInfo.environment["MIRMIR_V4_WARMUP_COUNT"] ?? "5")
                ?? 5
        )
        let sampleCount = max(
            1,
            Int(ProcessInfo.processInfo.environment["MIRMIR_V4_SAMPLE_COUNT"] ?? "10")
                ?? 10
        )
        let fixtures = try TemporaryFixtureDirectory()
        defer { fixtures.remove() }
        let inputURL = fixtures.url(for: "v3-end-to-end-input.mov")
        try await VideoProbeFixtureFactory.makeVideo(at: inputURL, transform: .identity)
        let deterministicCatalog = try deterministicCatalog()
        let archivedInputName = "end-to-end-input.mov"
        let archivedInput = outputDirectory.appendingPathComponent(archivedInputName)
        try FileManager.default.copyItem(at: inputURL, to: archivedInput)

        let targetWidth = 128
        let targetHeight = 96
        var runs: [EndToEndBaselineRun] = []
        for backendID in [
            UpscaleBackendID.mirmirDeterministicCPU,
            .mirmirDeterministicMetal
        ] {
            for iteration in 0..<(warmupCount + sampleCount) {
                let timingRecorder = BaselineVideoTimingRecorder()
                let coordinator = UpscaleCoordinator(
                    backendCatalog: deterministicCatalog,
                    processingSession: VideoProcessingSession(
                        timingHandler: { event in
                            timingRecorder.record(event)
                        }
                    )
                )
                let outputURL = fixtures.url(
                    for: "\(backendID.rawValue)-\(iteration).mov"
                )
                let startedAt = DispatchTime.now().uptimeNanoseconds
                let result = try await coordinator.process(
                    UpscaleRequest(
                        inputURL: inputURL,
                        outputURL: outputURL,
                        backendID: backendID,
                        targetWidth: targetWidth,
                        targetHeight: targetHeight,
                        outputCodec: .h264,
                        preserveAudio: false,
                        overwriteExistingFile: false
                    ),
                    progress: { _ in }
                )
                let finishedAt = DispatchTime.now().uptimeNanoseconds
                guard iteration >= warmupCount else {
                    continue
                }
                let timing = timingRecorder.snapshot()
                let attributes = try FileManager.default.attributesOfItem(
                    atPath: outputURL.path
                )
                runs.append(EndToEndBaselineRun(
                    backendID: backendID.rawValue,
                    sampleIndex: iteration - warmupCount,
                    wallMilliseconds: Double(finishedAt - startedAt) / 1_000_000.0,
                    sessionMilliseconds: result.processingDurationSeconds * 1_000.0,
                    processedFrameCount: result.processedFrameCount,
                    outputByteCount: (attributes[.size] as? NSNumber)?.intValue ?? 0,
                    stageMilliseconds: timing.milliseconds,
                    stageSampleCounts: timing.counts
                ))
            }
        }

        let inputAttributes = try FileManager.default.attributesOfItem(
            atPath: archivedInput.path
        )
        let capture = EndToEndBaselineCapture(
            schemaVersion: "mirmir-v4-end-to-end-baseline-v1",
            inputFile: archivedInputName,
            inputByteCount: (inputAttributes[.size] as? NSNumber)?.intValue ?? 0,
            targetWidth: targetWidth,
            targetHeight: targetHeight,
            outputCodec: OutputCodec.h264.rawValue,
            warmupCount: warmupCount,
            sampleCount: sampleCount,
            runs: runs
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(capture).write(
            to: outputDirectory.appendingPathComponent("end-to-end-results.json"),
            options: .atomic
        )
    }

    func testConventionalAppleBackendsProduceReadableOutputWhenAvailable() async throws {
        let fixtures = try TemporaryFixtureDirectory()
        defer { fixtures.remove() }
        let inputURL = fixtures.url(for: "conventional-input.mov")
        try await VideoProbeFixtureFactory.makeVideo(
            at: inputURL,
            transform: .identity
        )

        let backendIDs: [UpscaleBackendID] = [
            .mpsLanczos,
            .mpsBilinear,
            .coreImageLanczos,
            .coreImageBicubic,
            .videoToolboxPixelTransfer
        ]
        for backendID in backendIDs {
            let outputURL = fixtures.url(for: "\(backendID.rawValue).mov")
            let result = try await UpscaleCoordinator().process(
                UpscaleRequest(
                    inputURL: inputURL,
                    outputURL: outputURL,
                    backendID: backendID,
                    targetWidth: 128,
                    targetHeight: 96,
                    outputCodec: .h264,
                    preserveAudio: false,
                    overwriteExistingFile: false
                ),
                progress: { _ in }
            )

            XCTAssertEqual(result.actualBackendID, backendID)
            XCTAssertEqual(result.encodedWidth, 128)
            XCTAssertEqual(result.encodedHeight, 96)
            XCTAssertEqual(result.processedFrameCount, 3)
            XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        }
        XCTAssertFalse(try directoryContainsPartialFile(fixtures.rootURL))
    }

    func testMetalFXSpatialProducesReadableOutputWithExplicitBT709Bridge() async throws {
        let fixtures = try TemporaryFixtureDirectory()
        defer { fixtures.remove() }
        let inputURL = fixtures.url(for: "metalfx-input.mov")
        let outputURL = fixtures.url(for: "metalfx-output.mov")
        try await VideoProbeFixtureFactory.makeVideo(at: inputURL, transform: .identity)

        let result = try await UpscaleCoordinator().process(
            UpscaleRequest(
                inputURL: inputURL,
                outputURL: outputURL,
                backendID: .metalFXSpatial,
                targetWidth: 128,
                targetHeight: 96,
                outputCodec: .h264,
                preserveAudio: false,
                overwriteExistingFile: false
            ),
            progress: { _ in }
        )

        XCTAssertEqual(result.actualBackendID, .metalFXSpatial)
        XCTAssertEqual(result.encodedWidth, 128)
        XCTAssertEqual(result.encodedHeight, 96)
        XCTAssertEqual(result.processedFrameCount, 3)
        XCTAssertFalse(try directoryContainsPartialFile(fixtures.rootURL))
    }

    func testUntaggedSDRCompletesEveryConventionalSDRRoute() async throws {
        let fixtures = try TemporaryFixtureDirectory()
        defer { fixtures.remove() }
        let input = fixtures.url(for: "untagged-conventional.mov")
        try await VideoProbeFixtureFactory.makeVideo(
            at: input, transform: .identity, includeColorProperties: false
        )
        let source = try await VideoProbe().probe(url: input)
        let methods: [UpscaleBackendID] = [
            .automatic, .mpsLanczos, .mpsBilinear, .coreImageLanczos,
            .coreImageBicubic, .vImageHighQuality, .vImageStandard,
            .videoToolboxPixelTransfer
        ]
        for method in methods {
            let output = fixtures.url(for: "untagged-\(method.rawValue).mov")
            let result = try await UpscaleCoordinator().process(
                UpscaleRequest(
                    inputURL: input, outputURL: output, backendID: method,
                    targetWidth: 128, targetHeight: 96, outputCodec: .h264,
                    preserveAudio: false, overwriteExistingFile: false
                ), progress: { _ in }
            )
            if method != .automatic { XCTAssertEqual(result.actualBackendID, method) }
            XCTAssertEqual(result.processedFrameCount, 3)
            let reopened = try await VideoProbe().probe(url: output)
            XCTAssertTrue(reopened.isReadable)
            XCTAssertEqual(reopened.color.colorPrimaries, source.color.colorPrimaries)
            XCTAssertEqual(reopened.color.transferFunction, source.color.transferFunction)
            XCTAssertEqual(reopened.color.yCbCrMatrix, source.color.yCbCrMatrix)
        }
    }

    @MainActor
    func testDurableCompletionLoadsOriginalAndOutputInComparisonPlayer() async throws {
        let fixtures = try TemporaryFixtureDirectory()
        defer { fixtures.remove() }
        let input = fixtures.url(for: "comparison-original.mov")
        try await VideoProbeFixtureFactory.makeVideo(at: input, transform: .identity)
        let output = fixtures.url(for: "comparison-output.mov")
        let queue = try WorkflowApplicationQueueV4(
            trustedRootURL: fixtures.rootURL.appendingPathComponent("queue"),
            workerID: WorkflowWorkerIDV4("comparison-regression"),
            resolver: ComparisonFixtureBookmarkResolver()
        )
        let workflow = WorkflowApplicationCoordinatorV4(
            queue: queue,
            engine: WorkflowDeterministicApplicationEngineV4(
                videoProbe: VideoProbe(), backendCatalog: .live(),
                runtimeEnvironment: .current()
            ),
            maximumInputFramesPerBoundary: 60
        )
        let model = MirmirViewModel(workflowController: workflow)
        await model.initializeWorkflow()
        model.selectBackend(.mirmirDeterministicMetal)
        model.selectVideo(input)
        await model.waitForCurrentProbe()
        await model.waitForBackendAvailability()
        model.setOutputURL(output)
        XCTAssertTrue(model.canStart)
        model.startUpscale()
        await model.waitForProcessing()
        guard case .completed(_, let result) = model.state else {
            return XCTFail("Expected durable completion: \(model.state)")
        }
        let original = try XCTUnwrap(model.completedComparisonSourceURL)
        XCTAssertEqual(original, input)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        let player = MirmirSynchronizedPlaybackController()
        defer { player.tearDown() }
        player.load(sourceURL: original, completedOutputURL: result.outputURL)
        for _ in 0..<200 {
            if player.timeline.isReady { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(player.timeline.isReady, "\(player.timeline.loadState)")
        XCTAssertGreaterThan(player.timeline.duration, 0)
        XCTAssertNotNil(player.sourcePlayer.currentItem)
        XCTAssertNotNil(player.outputPlayer.currentItem)
    }

    @MainActor
    func testAVIComparisonAndThumbnailUseNativeResolvedSource()
        async throws {
        for fixture in ["native-avi-h264", "native-avi-mpeg4"] {
            let sourceURL = try XCTUnwrap(Bundle(for: Self.self).url(
                forResource: fixture,
                withExtension: "avi"
            )).standardizedFileURL
            let outputURL = try await NativeMediaInputAssetResolverV4.asset(
                url: sourceURL
            ).url.standardizedFileURL
            let controller = MirmirSynchronizedPlaybackController()
            defer { controller.tearDown() }
            controller.load(sourceURL: sourceURL, completedOutputURL: outputURL)
            for _ in 0..<200 {
                if controller.timeline.isReady { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTAssertTrue(controller.timeline.isReady, "\(fixture): \(controller.timeline.loadState)")
            let sourceAsset = try XCTUnwrap(
                controller.sourcePlayer.currentItem?.asset as? AVURLAsset
            )
            let outputAsset = try XCTUnwrap(
                controller.outputPlayer.currentItem?.asset as? AVURLAsset
            )
            XCTAssertNotEqual(sourceAsset.url.standardizedFileURL, sourceURL)
            XCTAssertEqual(outputAsset.url.standardizedFileURL, outputURL)
            let sourceFrame = await MirmirFramePreviewLoader.frame(
                at: sourceURL,
                role: .source,
                preferredTime: 1
            )
            let outputFrame = await MirmirFramePreviewLoader.frame(
                at: outputURL,
                role: .completedOutput,
                preferredTime: 1
            )
            XCTAssertNotNil(sourceFrame, fixture)
            XCTAssertNotNil(outputFrame, fixture)
        }
    }

    func testCommonInputCodecsCompleteBothProductionDeterministicRoutes() async throws {
        let fixtures = try TemporaryFixtureDirectory()
        defer { fixtures.remove() }
        for codec in [AVVideoCodecType.h264, .hevc, .proRes422] {
            let inputURL = fixtures.url(for: "input-\(codec.rawValue).mov")
            try await VideoProbeFixtureFactory.makeVideo(
                at: inputURL,
                transform: .identity,
                codec: codec
            )
            for backendID in [UpscaleBackendID.mirmirDeterministicCPU, .mirmirDeterministicMetal] {
                do {
                    let outputURL = fixtures.url(for: "\(codec.rawValue)-\(backendID.rawValue).mov")
                    let result = try await UpscaleCoordinator().process(
                        UpscaleRequest(
                            inputURL: inputURL,
                            outputURL: outputURL,
                            backendID: backendID,
                            targetWidth: 128,
                            targetHeight: 96,
                            outputCodec: .hevc,
                            preserveAudio: false,
                            overwriteExistingFile: false
                        ),
                        progress: { _ in }
                    )
                    XCTAssertEqual(result.actualBackendID, backendID)
                    XCTAssertEqual(result.processedFrameCount, 3)
                    let reopened = try await VideoProbe().probe(url: outputURL)
                    XCTAssertTrue(reopened.isReadable)
                    XCTAssertEqual(reopened.geometry.encodedSize, CGSize(width: 128, height: 96))
                } catch {
                    XCTFail("\(codec.rawValue), \(backendID.rawValue): \(error)")
                }
            }
        }
    }

    func testProgressiveJFIFMOVCompletesBothProductionDeterministicRoutes() async throws {
        let fixtures = try TemporaryFixtureDirectory()
        defer { fixtures.remove() }
        let input = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "legacy-mjpeg", withExtension: "mov"))
        let originalBytes = try Data(contentsOf: input)
        for backend in [UpscaleBackendID.mirmirDeterministicCPU, .mirmirDeterministicMetal] {
            let output = fixtures.url(for: "jfif-\(backend.rawValue).mov")
            let result = try await UpscaleCoordinator().process(
                UpscaleRequest(inputURL: input, outputURL: output, backendID: backend,
                    targetWidth: 320, targetHeight: 192, outputCodec: .h264,
                    preserveAudio: true, overwriteExistingFile: false), progress: { _ in })
            XCTAssertEqual(result.actualBackendID, backend)
            XCTAssertEqual(result.processedFrameCount, 72)
            XCTAssertEqual(result.audioResult, .preserved)
            let reopened = try await VideoProbe().probe(url: output)
            XCTAssertTrue(reopened.isReadable)
            XCTAssertEqual(reopened.geometry.encodedSize, CGSize(width: 320, height: 192))
            XCTAssertEqual(reopened.color.chromaSiting, .center)
            let tracks = try await AVURLAsset(url: output).loadTracks(withMediaType: .video)
            let descriptions = try await XCTUnwrap(tracks.first).load(.formatDescriptions)
            XCTAssertEqual(try AVCChromaLocationV4.declaration(from: descriptions)?.location, .center)
            let artifact = XCTAttachment(contentsOfFile: output)
            artifact.name = "jfif-session-\(backend.rawValue).mov"
            artifact.lifetime = .keepAlways
            add(artifact)
        }
        XCTAssertEqual(try Data(contentsOf: input), originalBytes)
        XCTAssertFalse(try directoryContainsPartialFile(fixtures.rootURL))
    }

    func testProRes422WorkingAvailabilityKeepsAutomaticDocumentedScope() async throws {
        let fixtures = try TemporaryFixtureDirectory()
        defer { fixtures.remove() }
        let input = fixtures.url(for: "automatic-prores-input.mov")
        try await VideoProbeFixtureFactory.makeVideo(at: input, transform: .identity, codec: .proRes422)
        let source = try await VideoProbe().probe(url: input)
        let catalog = UpscaleBackendCatalog.live()
        let snapshot = await catalog.snapshot(for: source,
            targetSize: CGSize(width: 128, height: 96), environment: .current())
        XCTAssertEqual(snapshot.entry(for: .mirmirDeterministicCPU)?.availability, .available)
        XCTAssertEqual(snapshot.entry(for: .mirmirDeterministicMetal)?.availability, .available)
        let firstApple = AutomaticBackendSelector.orderedBackendIDs.first {
            snapshot.entry(for: $0)?.availability == .available
        }
        let actual = snapshot.resolution(for: .automatic)
        XCTAssertEqual(actual.actualBackendID, firstApple)
        XCTAssertEqual(actual.availability, firstApple == nil
            ? .unavailable(reason: .noCompatibleAutomaticBackend) : .available)
    }

    func testUntaggedH264CompletesBothProductionDeterministicRoutes() async throws {
        let fixtures = try TemporaryFixtureDirectory()
        defer { fixtures.remove() }
        let inputURL = fixtures.url(for: "untagged.mov")
        try await VideoProbeFixtureFactory.makeVideo(
            at: inputURL,
            transform: .identity,
            includeColorProperties: false
        )
        let asset = AVURLAsset(url: inputURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let formats = try await track.load(.formatDescriptions)
        let format = try XCTUnwrap(formats.first)
        XCTAssertNil(CMFormatDescriptionGetExtension(
            format,
            extensionKey: kCMFormatDescriptionExtension_TransferFunction
        ), "The regression must use a genuinely untagged source.")
        let sourceInfo = try await VideoProbe().probe(url: inputURL)
        XCTAssertEqual(sourceInfo.color.isFullRange, false)
        XCTAssertEqual(sourceInfo.color.dynamicRange, .sdr)
        XCTAssertEqual(sourceInfo.color.colorPrimaries, kCVImageBufferColorPrimaries_SMPTE_C as String)
        XCTAssertEqual(sourceInfo.color.yCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String)

        for backendID in [
            UpscaleBackendID.mirmirDeterministicCPU,
            .mirmirDeterministicMetal
        ] {
            let outputURL = fixtures.url(for: "\(backendID.rawValue).mov")
            let result = try await UpscaleCoordinator().process(
                UpscaleRequest(
                    inputURL: inputURL,
                    outputURL: outputURL,
                    backendID: backendID,
                    targetWidth: 128,
                    targetHeight: 96,
                    outputCodec: .h264,
                    preserveAudio: false,
                    overwriteExistingFile: false
                ),
                progress: { _ in }
            )
            XCTAssertEqual(result.actualBackendID, backendID)
            XCTAssertEqual(result.processedFrameCount, 3)
            let outputInfo = try await VideoProbe().probe(url: outputURL)
            XCTAssertEqual(outputInfo.geometry.encodedSize, CGSize(width: 128, height: 96))
            XCTAssertTrue(outputInfo.isReadable)
            XCTAssertEqual(outputInfo.color.colorPrimaries, sourceInfo.color.colorPrimaries)
            XCTAssertEqual(outputInfo.color.transferFunction, sourceInfo.color.transferFunction)
            XCTAssertEqual(outputInfo.color.yCbCrMatrix, sourceInfo.color.yCbCrMatrix)
        }
        XCTAssertFalse(try directoryContainsPartialFile(fixtures.rootURL))
    }

    func testDeterministicCPUReferenceProcessesShortClipWithoutAppleFallback() async throws {
        let fixtures = try TemporaryFixtureDirectory()
        defer { fixtures.remove() }
        let inputURL = fixtures.url(for: "deterministic-input.mov")
        let outputURL = fixtures.url(for: "deterministic-output.mov")
        try await VideoProbeFixtureFactory.makeVideo(at: inputURL, transform: .identity)
        let activityRecorder = MirmirProcessingActivityTestRecorder()
        let coordinator = UpscaleCoordinator(
            backendCatalog: try deterministicCatalog(),
            processingActivityFactory: { activityRecorder.begin($0) }
        )

        let result = try await coordinator.process(
            UpscaleRequest(
                inputURL: inputURL,
                outputURL: outputURL,
                backendID: .mirmirDeterministicCPU,
                targetWidth: 128,
                targetHeight: 96,
                outputCodec: .h264,
                preserveAudio: false,
                overwriteExistingFile: false
            ),
            progress: { activityRecorder.recordProtectedProgress($0) }
        )

        XCTAssertEqual(result.actualBackendID, .mirmirDeterministicCPU)
        XCTAssertEqual(result.encodedWidth, 128)
        XCTAssertEqual(result.encodedHeight, 96)
        XCTAssertEqual(result.processedFrameCount, 3)
        XCTAssertFalse(try directoryContainsPartialFile(fixtures.rootURL))
        let activity = activityRecorder.snapshot
        XCTAssertEqual(activity.beginCount, 1)
        XCTAssertEqual(activity.endCount, 1)
        XCTAssertEqual(activity.activeCount, 0)
        XCTAssertTrue(activity.progressActivityCounts.allSatisfy { $0 == 1 })
        XCTAssertTrue(activity.progressPhases.contains(.finalizing))
        XCTAssertTrue(activity.progressPhases.contains(.validatingOutput))
        XCTAssertTrue(activity.progressPhases.contains(.completed))
    }

    func testDeterministicMetalProcessesShortClipWithoutBackendFallback() async throws {
        let fixtures = try TemporaryFixtureDirectory()
        defer { fixtures.remove() }
        let inputURL = fixtures.url(for: "deterministic-metal-input.mov")
        let outputURL = fixtures.url(for: "deterministic-metal-output.mov")
        try await VideoProbeFixtureFactory.makeVideo(at: inputURL, transform: .identity)
        let activityRecorder = MirmirProcessingActivityTestRecorder()
        let coordinator = UpscaleCoordinator(
            backendCatalog: try deterministicCatalog(),
            processingActivityFactory: { activityRecorder.begin($0) }
        )

        let result = try await coordinator.process(
            UpscaleRequest(
                inputURL: inputURL,
                outputURL: outputURL,
                backendID: .mirmirDeterministicMetal,
                targetWidth: 128,
                targetHeight: 96,
                outputCodec: .h264,
                preserveAudio: false,
                overwriteExistingFile: false
            ),
            progress: { activityRecorder.recordProtectedProgress($0) }
        )

        XCTAssertEqual(result.actualBackendID, .mirmirDeterministicMetal)
        XCTAssertEqual(result.encodedWidth, 128)
        XCTAssertEqual(result.encodedHeight, 96)
        XCTAssertEqual(result.processedFrameCount, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertFalse(try directoryContainsPartialFile(fixtures.rootURL))
        let activity = activityRecorder.snapshot
        XCTAssertEqual(activity.beginCount, 1)
        XCTAssertEqual(activity.endCount, 1)
        XCTAssertEqual(activity.activeCount, 0)
        XCTAssertTrue(activity.progressActivityCounts.allSatisfy { $0 == 1 })
        XCTAssertTrue(activity.progressPhases.contains(.finalizing))
        XCTAssertTrue(activity.progressPhases.contains(.validatingOutput))
        XCTAssertTrue(activity.progressPhases.contains(.completed))
    }

    func testDeterministicCPUAndMetalProduceVerifiedProRes422WholeAssets()
        async throws {
        let fixtures = try TemporaryFixtureDirectory()
        defer { fixtures.remove() }
        let inputURL = fixtures.url(for: "deterministic-prores-input.mov")
        try await VideoProbeFixtureFactory.makeVideo(
            at: inputURL,
            transform: .identity
        )
        let catalog = try deterministicCatalog()

        for backendID in [
            UpscaleBackendID.mirmirDeterministicCPU,
            .mirmirDeterministicMetal
        ] {
            let outputURL = fixtures.url(
                for: "\(backendID.rawValue)-prores422.mov"
            )
            let result = try await UpscaleCoordinator(
                backendCatalog: catalog
            ).process(
                UpscaleRequest(
                    inputURL: inputURL,
                    outputURL: outputURL,
                    backendID: backendID,
                    targetWidth: 128,
                    targetHeight: 96,
                    outputCodec: .proRes422,
                    preserveAudio: false,
                    overwriteExistingFile: false
                ),
                progress: { _ in }
            )

            XCTAssertEqual(result.actualBackendID, backendID)
            XCTAssertEqual(result.outputCodec, .proRes422)
            XCTAssertEqual(result.encodedWidth, 128)
            XCTAssertEqual(result.encodedHeight, 96)
            XCTAssertEqual(result.processedFrameCount, 3)
            try await verifyProRes422Output(at: outputURL)
        }
        XCTAssertFalse(try directoryContainsPartialFile(fixtures.rootURL))
    }

    func testVideoToolboxSuperResolutionContractsRunOrReportExactUnavailability() async throws {
        let fixtures = try TemporaryFixtureDirectory()
        defer { fixtures.remove() }
        let inputURL = fixtures.url(for: "vt-super-resolution-input.mov")
        try await VideoProbeFixtureFactory.makeVideo(at: inputURL, transform: .identity)
        let source = try await VideoProbe().probe(url: inputURL)
        let target = CGSize(width: 128, height: 96)
        let catalog = UpscaleBackendCatalog.live()
        let snapshot = await catalog.snapshot(
            for: source,
            targetSize: target,
            environment: .current()
        )

        for backendID in [
            UpscaleBackendID.videoToolboxSuperResolutionQuality,
            .videoToolboxSuperResolutionLowLatency
        ] {
            let availability = try XCTUnwrap(snapshot.entry(for: backendID)?.availability)
            let capability = XCTAttachment(string: "\(backendID.rawValue): \(availability.statusText)")
            capability.name = "VideoToolbox runtime capability"
            capability.lifetime = .keepAlways
            add(capability)
            switch availability {
            case .available:
                let outputURL = fixtures.url(for: "\(backendID.rawValue).mov")
                let result = try await UpscaleCoordinator().process(
                    UpscaleRequest(
                        inputURL: inputURL,
                        outputURL: outputURL,
                        backendID: backendID,
                        targetWidth: 128,
                        targetHeight: 96,
                        outputCodec: .h264,
                        preserveAudio: false,
                        overwriteExistingFile: false
                    ),
                    progress: { _ in }
                )
                XCTAssertEqual(result.actualBackendID, backendID)
                XCTAssertEqual(result.processedFrameCount, 3)
            case .modelDownloadRequired:
                XCTAssertEqual(backendID, .videoToolboxSuperResolutionQuality)
                XCTAssertTrue(availability.statusText.contains("Model download required"))
            case .unavailable(let reason):
                XCTAssertFalse(reason.userFacingDescription.isEmpty)
            }
        }
    }

    func testVideoToolboxSuperResolutionProcessesSupportedGeometry() async throws {
        let fixtures = try TemporaryFixtureDirectory()
        defer { fixtures.remove() }
        let input = fixtures.url(for: "vt-supported-geometry.mov")
        try await VideoProbeFixtureFactory.makeVideo(
            at: input, transform: .identity, width: 256, height: 144
        )
        let source = try await VideoProbe().probe(url: input)
        for (backend, scale) in [
            (UpscaleBackendID.videoToolboxSuperResolutionQuality, 4),
            (.videoToolboxSuperResolutionLowLatency, 2)
        ] {
            let width = 256 * scale
            let height = 144 * scale
            let availability = await UpscaleBackendCatalog.live().availability(
                for: backend, source: source,
                targetSize: CGSize(width: width, height: height), environment: .current()
            )
            let capability = XCTAttachment(string: "\(backend.rawValue) at \(width)x\(height): \(availability.statusText)")
            capability.name = "VideoToolbox supported geometry"
            capability.lifetime = .keepAlways
            add(capability)
            switch availability {
            case .available:
                let output = fixtures.url(for: "\(backend.rawValue)-supported.mov")
                let result = try await UpscaleCoordinator().process(UpscaleRequest(
                    inputURL: input, outputURL: output, backendID: backend,
                    targetWidth: width, targetHeight: height, outputCodec: .h264,
                    preserveAudio: false, overwriteExistingFile: false
                ), progress: { _ in })
                XCTAssertEqual(result.actualBackendID, backend)
                XCTAssertEqual(result.processedFrameCount, 3)
                let observed = try await VideoProbe().probe(url: output)
                XCTAssertEqual(observed.geometry.encodedSize, CGSize(width: width, height: height))
                XCTAssertEqual(CMTimeCompare(observed.duration, source.duration), 0)
                let decodedTimes = try await decodedPresentationTimes(at: output)
                XCTAssertEqual(decodedTimes.count, 3)
                for (ordinal, timestamp) in decodedTimes.enumerated() {
                    XCTAssertEqual(CMTimeCompare(timestamp, CMTime(value: Int64(ordinal), timescale: 30)), 0)
                }
            case .modelDownloadRequired:
                XCTAssertEqual(backend, .videoToolboxSuperResolutionQuality)
            case .unavailable(let reason):
                XCTAssertFalse(reason.userFacingDescription.isEmpty)
            }
        }
    }

    func testVideoToolboxInterpolationMaintainsDurationAndProducesTwoXCadenceWhenAvailable() async throws {
        let fixtures = try TemporaryFixtureDirectory()
        defer { fixtures.remove() }
        let silentURL = fixtures.url(for: "vt-interpolation-silent.mov")
        let audioURL = fixtures.url(for: "vt-interpolation-audio.wav")
        let inputURL = fixtures.url(for: "vt-interpolation-input.mov")
        let outputURL = fixtures.url(for: "vt-interpolation-output.mov")
        try await VideoProbeFixtureFactory.makeVideo(at: silentURL, transform: .identity)
        try VideoProbeFixtureFactory.makeAudio(at: audioURL)
        try await VideoProbeFixtureFactory.combine(
            videoURL: silentURL,
            audioURL: audioURL,
            outputURL: inputURL
        )
        let source = try await VideoProbe().probe(url: inputURL)
        let availability = await UpscaleBackendCatalog.live().availability(
            for: .videoToolboxInterpolationWithSpatialScale,
            source: source,
            targetSize: CGSize(width: 128, height: 96),
            environment: .current()
        )

        let capability = XCTAttachment(string: availability.statusText)
        capability.name = "VideoToolbox interpolation runtime capability"
        capability.lifetime = .keepAlways
        add(capability)

        switch availability {
        case .available:
            let result = try await UpscaleCoordinator().process(
                UpscaleRequest(
                    inputURL: inputURL,
                    outputURL: outputURL,
                    backendID: .videoToolboxInterpolationWithSpatialScale,
                    targetWidth: 128,
                    targetHeight: 96,
                    outputCodec: .h264,
                    preserveAudio: true,
                    overwriteExistingFile: false
                ),
                progress: { _ in }
            )
            XCTAssertEqual(
                result.actualBackendID,
                .videoToolboxInterpolationWithSpatialScale
            )
            XCTAssertEqual(result.processedFrameCount, 5)
            XCTAssertEqual(result.encodedWidth, 128)
            XCTAssertEqual(result.encodedHeight, 96)
            XCTAssertTrue([.preserved, .transcoded].contains(result.audioResult))
            XCTAssertEqual(
                result.durationSeconds,
                CMTimeGetSeconds(source.duration),
                accuracy: 1.0 / 600.0
            )
        case .modelDownloadRequired:
            XCTFail("The low-latency interpolation path must not expose a model download flow.")
        case .unavailable(let reason):
            XCTAssertFalse(reason.userFacingDescription.isEmpty)
        }
    }

    func testVImageHighQualityProducesReadableAtomicOutput() async throws {
        let fixtures = try TemporaryFixtureDirectory()
        defer { fixtures.remove() }
        let inputURL = fixtures.url(for: "input.mov")
        let outputURL = fixtures.url(for: "output.mov")
        try await VideoProbeFixtureFactory.makeVideo(
            at: inputURL,
            transform: .identity
        )

        let result = try await UpscaleCoordinator().process(
            UpscaleRequest(
                inputURL: inputURL,
                outputURL: outputURL,
                backendID: .vImageHighQuality,
                targetWidth: 128,
                targetHeight: 96,
                outputCodec: .h264,
                preserveAudio: false,
                overwriteExistingFile: false
            ),
            progress: { _ in }
        )

        XCTAssertEqual(result.actualBackendID, .vImageHighQuality)
        XCTAssertEqual(result.encodedWidth, 128)
        XCTAssertEqual(result.encodedHeight, 96)
        XCTAssertEqual(result.processedFrameCount, 3)
        XCTAssertEqual(result.audioResult, .omitted)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertFalse(try directoryContainsPartialFile(fixtures.rootURL))
    }

    func testSilentInputReportsAudioAbsentWhenPreservationRequested() async throws {
        let fixtures = try TemporaryFixtureDirectory()
        defer { fixtures.remove() }
        let inputURL = fixtures.url(for: "silent.mov")
        let outputURL = fixtures.url(for: "silent-output.mov")
        try await VideoProbeFixtureFactory.makeVideo(
            at: inputURL,
            transform: .identity
        )

        let result = try await UpscaleCoordinator().process(
            UpscaleRequest(
                inputURL: inputURL,
                outputURL: outputURL,
                backendID: .vImageStandard,
                targetWidth: 128,
                targetHeight: 96,
                outputCodec: .h264,
                preserveAudio: true,
                overwriteExistingFile: false
            ),
            progress: { _ in }
        )

        XCTAssertEqual(result.actualBackendID, .vImageStandard)
        XCTAssertEqual(result.audioResult, .absent)
    }

    func testSingleAudioTrackIsPreservedOrExplicitlyTranscoded() async throws {
        let fixtures = try TemporaryFixtureDirectory()
        defer { fixtures.remove() }
        let silentURL = fixtures.url(for: "audio-video.mov")
        let audioURL = fixtures.url(for: "audio.wav")
        let inputURL = fixtures.url(for: "audio-input.mov")
        let outputURL = fixtures.url(for: "audio-output.mov")
        try await VideoProbeFixtureFactory.makeVideo(at: silentURL, transform: .identity)
        try VideoProbeFixtureFactory.makeAudio(at: audioURL)
        try await VideoProbeFixtureFactory.combine(
            videoURL: silentURL,
            audioURL: audioURL,
            outputURL: inputURL
        )

        let result = try await UpscaleCoordinator().process(
            UpscaleRequest(
                inputURL: inputURL,
                outputURL: outputURL,
                backendID: .vImageHighQuality,
                targetWidth: 128,
                targetHeight: 96,
                outputCodec: .h264,
                preserveAudio: true,
                overwriteExistingFile: false
            ),
            progress: { _ in }
        )

        XCTAssertTrue([.preserved, .transcoded].contains(result.audioResult))
        let output = try await VideoProbe().probe(url: outputURL)
        XCTAssertEqual(output.audioTrackCount, 1)
        XCTAssertEqual(result.durationSeconds, CMTimeGetSeconds(output.duration), accuracy: 0.002)
    }

    func testMultipleAudioTracksArePreservedWithoutCollapsing() async throws {
        let fixtures = try TemporaryFixtureDirectory()
        defer { fixtures.remove() }
        let silentURL = fixtures.url(for: "multi-audio-video.mov")
        let firstAudioURL = fixtures.url(for: "multi-audio-first.wav")
        let secondAudioURL = fixtures.url(for: "multi-audio-second.wav")
        let inputURL = fixtures.url(for: "multi-audio-input.mov")
        let outputURL = fixtures.url(for: "multi-audio-output.mov")
        try await VideoProbeFixtureFactory.makeVideo(
            at: silentURL,
            transform: .identity
        )
        try VideoProbeFixtureFactory.makeAudio(
            at: firstAudioURL,
            amplitude: 0.25
        )
        try VideoProbeFixtureFactory.makeAudio(
            at: secondAudioURL,
            amplitude: -0.25
        )
        try await VideoProbeFixtureFactory.combine(
            videoURL: silentURL,
            audioURLs: [firstAudioURL, secondAudioURL],
            outputURL: inputURL
        )
        let source = try await VideoProbe().probe(url: inputURL)
        XCTAssertEqual(source.audioTrackCount, 2)

        let result = try await UpscaleCoordinator().process(
            UpscaleRequest(
                inputURL: inputURL,
                outputURL: outputURL,
                backendID: .vImageHighQuality,
                targetWidth: 128,
                targetHeight: 96,
                outputCodec: .h264,
                preserveAudio: true,
                overwriteExistingFile: false
            ),
            progress: { _ in }
        )

        XCTAssertTrue([.preserved, .transcoded].contains(result.audioResult))
        let output = try await VideoProbe().probe(url: outputURL)
        XCTAssertEqual(output.audioTrackCount, source.audioTrackCount)
        XCTAssertEqual(
            result.durationSeconds,
            CMTimeGetSeconds(output.duration),
            accuracy: 0.002
        )
    }

    func testPortraitTransformAndDisplayDimensionsArePreserved() async throws {
        let fixtures = try TemporaryFixtureDirectory()
        defer { fixtures.remove() }
        let inputURL = fixtures.url(for: "portrait-input.mov")
        let outputURL = fixtures.url(for: "portrait-output.mov")
        let portraitTransform = CGAffineTransform(
            a: 0,
            b: 1,
            c: -1,
            d: 0,
            tx: 48,
            ty: 0
        )
        try await VideoProbeFixtureFactory.makeVideo(
            at: inputURL,
            transform: portraitTransform
        )

        _ = try await UpscaleCoordinator().process(
            UpscaleRequest(
                inputURL: inputURL,
                outputURL: outputURL,
                backendID: .vImageStandard,
                targetWidth: 128,
                targetHeight: 96,
                outputCodec: .h264,
                preserveAudio: false,
                overwriteExistingFile: false
            ),
            progress: { _ in }
        )

        let output = try await VideoProbe().probe(url: outputURL)
        XCTAssertEqual(output.geometry.encodedSize, CGSize(width: 128, height: 96))
        XCTAssertEqual(output.geometry.orientation, .portrait)
        XCTAssertEqual(output.displaySize, CGSize(width: 96, height: 128))
    }

    func testVariableFrameRatePresentationTimesAreNotForcedToConstantCadence() async throws {
        let fixtures = try TemporaryFixtureDirectory()
        defer { fixtures.remove() }
        let inputURL = fixtures.url(for: "vfr-input.mov")
        let outputURL = fixtures.url(for: "vfr-output.mov")
        let sourceTimes = [
            CMTime(value: 0, timescale: 600),
            CMTime(value: 20, timescale: 600),
            CMTime(value: 65, timescale: 600)
        ]
        try await VideoProbeFixtureFactory.makeVideo(
            at: inputURL,
            transform: .identity,
            presentationTimes: sourceTimes
        )

        _ = try await UpscaleCoordinator().process(
            UpscaleRequest(
                inputURL: inputURL,
                outputURL: outputURL,
                backendID: .vImageHighQuality,
                targetWidth: 128,
                targetHeight: 96,
                outputCodec: .h264,
                preserveAudio: false,
                overwriteExistingFile: false
            ),
            progress: { _ in }
        )

        let outputTimes = try await decodedPresentationTimes(at: outputURL)
        XCTAssertEqual(outputTimes.count, sourceTimes.count)
        for (actual, expected) in zip(outputTimes, sourceTimes) {
            XCTAssertEqual(
                CMTimeGetSeconds(actual),
                CMTimeGetSeconds(expected),
                accuracy: 1.0 / 600.0
            )
        }
        XCTAssertNotEqual(
            CMTimeSubtract(outputTimes[1], outputTimes[0]),
            CMTimeSubtract(outputTimes[2], outputTimes[1])
        )
    }

    func testProRes422OutputIsReadableAfterInitialWriterStabilization() async throws {
        let fixtures = try TemporaryFixtureDirectory()
        defer { fixtures.remove() }
        let inputURL = fixtures.url(for: "prores-input.mov")
        let outputURL = fixtures.url(for: "prores-output.mov")
        try await VideoProbeFixtureFactory.makeVideo(at: inputURL, transform: .identity)

        let result = try await UpscaleCoordinator().process(
            UpscaleRequest(
                inputURL: inputURL,
                outputURL: outputURL,
                backendID: .vImageHighQuality,
                targetWidth: 128,
                targetHeight: 96,
                outputCodec: .proRes422,
                preserveAudio: false,
                overwriteExistingFile: false
            ),
            progress: { _ in }
        )

        XCTAssertEqual(result.outputCodec, .proRes422)
        let output = try await VideoProbe().probe(url: outputURL)
        XCTAssertEqual(output.codecFourCC, kCMVideoCodecType_AppleProRes422)
    }

    func testHEVCOutputIsReadableAndReportsItsCodec() async throws {
        let fixtures = try TemporaryFixtureDirectory()
        defer { fixtures.remove() }
        let inputURL = fixtures.url(for: "hevc-input.mov")
        let outputURL = fixtures.url(for: "hevc-output.mov")
        try await VideoProbeFixtureFactory.makeVideo(at: inputURL, transform: .identity)

        let result = try await UpscaleCoordinator().process(
            UpscaleRequest(
                inputURL: inputURL,
                outputURL: outputURL,
                backendID: .vImageHighQuality,
                targetWidth: 128,
                targetHeight: 96,
                outputCodec: .hevc,
                preserveAudio: false,
                overwriteExistingFile: false
            ),
            progress: { _ in }
        )

        XCTAssertEqual(result.outputCodec, .hevc)
        let output = try await VideoProbe().probe(url: outputURL)
        XCTAssertEqual(output.codecFourCC, kCMVideoCodecType_HEVC)
    }

    func testCancellationDuringPreparationFinishesPreparedBackend() async throws {
        let fixtures = try TemporaryFixtureDirectory()
        defer { fixtures.remove() }
        let input = fixtures.url(for: "prepare-cancel.mov")
        try await VideoProbeFixtureFactory.makeVideo(at: input, transform: .identity)
        let entered = ProcessingPhaseLatch()
        let release = ProcessingPhaseLatch()
        let prepared = LifecycleTestPreparedUpscaler()
        let backend = LifecycleTestBackend(
            descriptor: try XCTUnwrap(BackendDescriptor.descriptor(for: .vImageStandard)),
            prepared: prepared, entered: entered, release: release
        )
        let coordinator = UpscaleCoordinator(backendCatalog: UpscaleBackendCatalog(backends: [backend]))
        let output = fixtures.url(for: "prepare-cancel-output.mov")
        let task = Task {
            try await coordinator.process(UpscaleRequest(
                inputURL: input, outputURL: output, backendID: .vImageStandard,
                targetWidth: 128, targetHeight: 96, outputCodec: .h264,
                preserveAudio: false, overwriteExistingFile: false
            ), progress: { _ in })
        }
        await entered.wait()
        await coordinator.cancel()
        await release.signal()
        do {
            _ = try await task.value
            XCTFail("Cancellation must stop before processing.")
        } catch is CancellationError {
            // The coordinator has not transferred ownership to the media session.
        }
        let count = await prepared.finishCount
        XCTAssertEqual(count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testSessionSetupFailureFinishesPreparedBackendAndPreservesDestination() async throws {
        let fixtures = try TemporaryFixtureDirectory()
        defer { fixtures.remove() }
        let input = fixtures.url(for: "setup-source.mov")
        let output = fixtures.url(for: "existing-output.mov")
        try await VideoProbeFixtureFactory.makeVideo(at: input, transform: .identity)
        let sentinel = Data("existing destination".utf8)
        try sentinel.write(to: output)
        let source = try await VideoProbe().probe(url: input)
        let prepared = LifecycleTestPreparedUpscaler()
        do {
            _ = try await VideoProcessingSession().process(
                request: UpscaleRequest(
                    inputURL: input, outputURL: output, backendID: .vImageStandard,
                    targetWidth: 128, targetHeight: 96, outputCodec: .h264,
                    preserveAudio: false, overwriteExistingFile: false
                ), source: source, preparedBackend: prepared,
                cancellation: ProcessingCancellation(), progress: { _ in }
            )
            XCTFail("The existing destination must be rejected.")
        } catch let error as MirmirError {
            XCTAssertEqual(error, .outputAlreadyExists)
        }
        let count = await prepared.finishCount
        XCTAssertEqual(count, 1)
        XCTAssertEqual(try Data(contentsOf: output), sentinel)
    }

    func testCancellationRemovesPartialOutputAndCoordinatorAcceptsNextJob() async throws {
        let fixtures = try TemporaryFixtureDirectory()
        defer { fixtures.remove() }
        let inputURL = fixtures.url(for: "cancel-input.mov")
        let cancelledURL = fixtures.url(for: "cancelled-output.mov")
        let retryURL = fixtures.url(for: "retry-output.mov")
        try await VideoProbeFixtureFactory.makeVideo(at: inputURL, transform: .identity)

        let descriptor = try XCTUnwrap(
            BackendDescriptor.descriptor(for: .vImageStandard)
        )
        let coordinator = UpscaleCoordinator(
            backendCatalog: UpscaleBackendCatalog(
                backends: [SlowTestBackend(descriptor: descriptor)]
            )
        )
        let processingStarted = ProcessingPhaseLatch()
        let firstTask = Task {
            try await coordinator.process(
                UpscaleRequest(
                    inputURL: inputURL,
                    outputURL: cancelledURL,
                    backendID: .vImageStandard,
                    targetWidth: 128,
                    targetHeight: 96,
                    outputCodec: .h264,
                    preserveAudio: false,
                    overwriteExistingFile: false
                ),
                progress: { progress in
                    if progress.phase == .processingVideo {
                        Task { await processingStarted.signal() }
                    }
                }
            )
        }
        await processingStarted.wait()
        await coordinator.cancel()

        do {
            _ = try await firstTask.value
            XCTFail("Expected the active job to be cancelled.")
        } catch let error as MirmirError {
            XCTAssertEqual(error, .cancelled)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: cancelledURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: inputURL.path))
        XCTAssertFalse(try directoryContainsPartialFile(fixtures.rootURL))

        let retryResult = try await coordinator.process(
            UpscaleRequest(
                inputURL: inputURL,
                outputURL: retryURL,
                backendID: .vImageStandard,
                targetWidth: 128,
                targetHeight: 96,
                outputCodec: .h264,
                preserveAudio: false,
                overwriteExistingFile: false
            ),
            progress: { _ in }
        )
        XCTAssertEqual(retryResult.processedFrameCount, 3)
    }

    func testExistingDestinationIsNotTruncatedWithoutConfirmation() async throws {
        let fixtures = try TemporaryFixtureDirectory()
        defer { fixtures.remove() }
        let inputURL = fixtures.url(for: "input.mov")
        let outputURL = fixtures.url(for: "existing.mov")
        try await VideoProbeFixtureFactory.makeVideo(
            at: inputURL,
            transform: .identity
        )
        let original = Data("keep me".utf8)
        try original.write(to: outputURL)

        do {
            _ = try await UpscaleCoordinator().process(
                UpscaleRequest(
                    inputURL: inputURL,
                    outputURL: outputURL,
                    backendID: .vImageHighQuality,
                    targetWidth: 128,
                    targetHeight: 96,
                    outputCodec: .h264,
                    preserveAudio: false,
                    overwriteExistingFile: false
                ),
                progress: { _ in }
            )
            XCTFail("Expected an existing destination to be rejected.")
        } catch let error as MirmirError {
            XCTAssertEqual(error, .outputAlreadyExists)
        }

        XCTAssertEqual(try Data(contentsOf: outputURL), original)
        XCTAssertFalse(try directoryContainsPartialFile(fixtures.rootURL))
    }

    private func directoryContainsPartialFile(_ url: URL) throws -> Bool {
        try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil
        ).contains { $0.lastPathComponent.hasPrefix(".mirmir-") }
    }

    private func verifyProRes422Output(at url: URL) async throws {
        let contract = try VideoWriterFormatContractV4(
            codec: .proRes422,
            storage: .nv12VideoRange8Bit,
            color: .sdrBT709,
            sourceGeometry: try RationalPresentationGeometryV4(
                codedWidth: 64,
                codedHeight: 48,
                cleanAperture: .fullRaster(width: 64, height: 48)
            ),
            outputWidth: 128,
            outputHeight: 96,
            frameOperation: .spatialResampling
        )
        let asset = AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let formats = try await track.load(.formatDescriptions)
        let format = try XCTUnwrap(formats.first)
        try contract.verifyReopenedFormat(
            format,
            preferredTransform: try await track.load(.preferredTransform)
        )

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: contract.sourcePixelBufferAttributes
        )
        XCTAssertTrue(reader.canAdd(output))
        reader.add(output)
        XCTAssertTrue(
            reader.startReading(),
            reader.error?.localizedDescription ?? "reader start failed"
        )
        var decodedFrameCount = 0
        while let sample = output.copyNextSampleBuffer() {
            let pixelBuffer = try XCTUnwrap(
                CMSampleBufferGetImageBuffer(sample)
            )
            try contract.verifyDecodedPixelBuffer(pixelBuffer)
            decodedFrameCount += 1
        }
        XCTAssertEqual(reader.status, .completed)
        XCTAssertNil(reader.error)
        XCTAssertEqual(decodedFrameCount, 3)
    }

    private func deterministicCatalog() throws -> UpscaleBackendCatalog {
        let runtime = try ASHV4SemanticArtifactTestSupport
            .executableSystemMetalRuntime()
        let cpuDescriptor = try XCTUnwrap(
            BackendDescriptor.descriptor(for: .mirmirDeterministicCPU)
        )
        let metalDescriptor = try XCTUnwrap(
            BackendDescriptor.descriptor(for: .mirmirDeterministicMetal)
        )
        return UpscaleBackendCatalog(backends: [
            try XCTUnwrap(DeterministicCPUBackend(
                descriptor: cpuDescriptor,
                runtimeProvider: .fixed(runtime)
            )),
            try XCTUnwrap(DeterministicMetalBackend(
                descriptor: metalDescriptor,
                runtimeProvider: .fixed(runtime)
            ))
        ])
    }

    private func decodedPresentationTimes(at url: URL) async throws -> [CMTime] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            ]
        )
        guard reader.canAdd(output) else {
            throw VideoProbeFixtureError.failure("Could not inspect decoded output timing.")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw VideoProbeFixtureError.failure(
                reader.error?.localizedDescription ?? "Could not start timing inspection."
            )
        }
        var values: [CMTime] = []
        while let sample = output.copyNextSampleBuffer() {
            values.append(CMSampleBufferGetPresentationTimeStamp(sample))
        }
        return values
    }
}

private final class BaselineVideoTimingRecorder: @unchecked Sendable {
    struct Snapshot {
        let milliseconds: [String: Double]
        let counts: [String: Int]
    }

    private let lock = NSLock()
    private var nanoseconds: [VideoProcessingStage: UInt64] = [:]
    private var counts: [VideoProcessingStage: Int] = [:]

    func record(_ event: VideoProcessingTimingEvent) {
        lock.lock()
        nanoseconds[event.stage, default: 0] += event.durationNanoseconds
        counts[event.stage, default: 0] += 1
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        let capturedNanoseconds = nanoseconds
        let capturedCounts = counts
        lock.unlock()
        return Snapshot(
            milliseconds: Dictionary(uniqueKeysWithValues: VideoProcessingStage.allCases.map {
                ($0.rawValue, Double(capturedNanoseconds[$0, default: 0]) / 1_000_000.0)
            }),
            counts: Dictionary(uniqueKeysWithValues: VideoProcessingStage.allCases.map {
                ($0.rawValue, capturedCounts[$0, default: 0])
            })
        )
    }
}

private struct SlowTestBackend: UpscaleBackend {
    let descriptor: BackendDescriptor

    func availability(
        for source: VideoInfo,
        targetSize: CGSize,
        environment: RuntimeEnvironment
    ) async -> BackendAvailability {
        .available
    }

    func prepare(
        request: BackendPreparationRequest,
        environment: RuntimeEnvironment
    ) async throws -> any PreparedFrameUpscaler {
        SlowTestPreparedUpscaler(
            sourceWidth: Int(request.source.geometry.encodedSize?.width ?? 0),
            sourceHeight: Int(request.source.geometry.encodedSize?.height ?? 0),
            targetWidth: Int(request.targetSize.width),
            targetHeight: Int(request.targetSize.height)
        )
    }
}

private final class SlowTestPreparedUpscaler: PreparedFrameUpscaler, @unchecked Sendable {
    let actualBackendID = UpscaleBackendID.vImageStandard
    let sourcePixelBufferAttributes: PixelBufferAttributes
    let destinationPixelBufferAttributes: PixelBufferAttributes

    init(sourceWidth: Int, sourceHeight: Int, targetWidth: Int, targetHeight: Int) {
        sourcePixelBufferAttributes = PixelBufferAttributes([
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: sourceWidth,
            kCVPixelBufferHeightKey as String: sourceHeight,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary
        ])
        destinationPixelBufferAttributes = PixelBufferAttributes([
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: targetWidth,
            kCVPixelBufferHeightKey as String: targetHeight,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary
        ])
    }

    func process(
        source: FramePixelBuffer,
        destination: FramePixelBuffer,
        timing: FrameTiming
    ) async throws {
        let source = source.value
        let destination = destination.value
        try await Task.sleep(nanoseconds: 200_000_000)
        try SyntheticNV12PixelBuffer.fill(
            destination,
            luma: UInt8(64 + timing.frameIndex),
            cb: 128,
            cr: 128
        )
        NV12FrameAttachments.copy(from: source, to: destination)
    }

    func finish() async throws {}
}

private actor ProcessingPhaseLatch {
    private var didSignal = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func signal() {
        guard !didSignal else { return }
        didSignal = true
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }

    func wait() async {
        if didSignal { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }
}

// These fixture files already live in the test host's private container.
private struct ComparisonFixtureBookmarkResolver: WorkflowSecurityScopedBookmarkResolvingV4 {
    func makeBookmark(for url: URL, role: WorkflowScopedResourceRoleV4) throws -> Data {
        Data(url.path.utf8)
    }

    func resolveBookmark(_ data: Data, role: WorkflowScopedResourceRoleV4) throws -> WorkflowResolvedScopedResourceV4 {
        let path = try XCTUnwrap(String(data: data, encoding: .utf8))
        return WorkflowResolvedScopedResourceV4(
            url: URL(fileURLWithPath: path), isStale: false,
            startAccessing: { true }, stopAccessing: {}
        )
    }
}

private struct LifecycleTestBackend: UpscaleBackend {
    let descriptor: BackendDescriptor
    let prepared: LifecycleTestPreparedUpscaler
    let entered: ProcessingPhaseLatch
    let release: ProcessingPhaseLatch
    func availability(for source: VideoInfo, targetSize: CGSize, environment: RuntimeEnvironment) async -> BackendAvailability { .available }
    func prepare(request: BackendPreparationRequest, environment: RuntimeEnvironment) async throws -> any PreparedFrameUpscaler {
        await entered.signal()
        await release.wait()
        return prepared
    }
}

private actor LifecycleTestPreparedUpscaler: PreparedFrameUpscaler {
    nonisolated let actualBackendID = UpscaleBackendID.vImageStandard
    nonisolated let sourcePixelBufferAttributes = PixelBufferAttributes()
    nonisolated let destinationPixelBufferAttributes = PixelBufferAttributes()
    private(set) var finishCount = 0
    func process(source: FramePixelBuffer, destination: FramePixelBuffer, timing: FrameTiming) async throws {
        XCTFail("The early-failure test must not process a frame.")
        throw CancellationError()
    }
    func finish() async throws { finishCount += 1 }
}
