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

    func testDeterministicCPUReferenceProcessesShortClipWithoutAppleFallback() async throws {
        let fixtures = try TemporaryFixtureDirectory()
        defer { fixtures.remove() }
        let inputURL = fixtures.url(for: "deterministic-input.mov")
        let outputURL = fixtures.url(for: "deterministic-output.mov")
        try await VideoProbeFixtureFactory.makeVideo(at: inputURL, transform: .identity)

        let result = try await UpscaleCoordinator().process(
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
            progress: { _ in }
        )

        XCTAssertEqual(result.actualBackendID, .mirmirDeterministicCPU)
        XCTAssertEqual(result.encodedWidth, 128)
        XCTAssertEqual(result.encodedHeight, 96)
        XCTAssertEqual(result.processedFrameCount, 3)
        XCTAssertFalse(try directoryContainsPartialFile(fixtures.rootURL))
    }

    func testDeterministicMetalProcessesShortClipWithoutBackendFallback() async throws {
        let fixtures = try TemporaryFixtureDirectory()
        defer { fixtures.remove() }
        let inputURL = fixtures.url(for: "deterministic-metal-input.mov")
        let outputURL = fixtures.url(for: "deterministic-metal-output.mov")
        try await VideoProbeFixtureFactory.makeVideo(at: inputURL, transform: .identity)

        let result = try await UpscaleCoordinator().process(
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
            progress: { _ in }
        )

        XCTAssertEqual(result.actualBackendID, .mirmirDeterministicMetal)
        XCTAssertEqual(result.encodedWidth, 128)
        XCTAssertEqual(result.encodedHeight, 96)
        XCTAssertEqual(result.processedFrameCount, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
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
