import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import os.lock
import XCTest
@testable import Mirmir

// The media readers, fixtures, and release-path regressions are co-located.
// swiftlint:disable file_length

enum R13IntegrationMediaError: Error, Equatable {
    case interrupted
    case metadataReaderRejected
    case metadataReaderFailed
    case duplicateMetadataKey(String)
    case malformedContainerHeader
}

func readR13ISOBaseMediaMajorBrand(at url: URL) throws -> String {
    let data = try Data(contentsOf: url, options: .mappedIfSafe)
    guard data.count >= 12,
          data.subdata(in: 4..<8) == Data("ftyp".utf8) else {
        throw R13IntegrationMediaError.malformedContainerHeader
    }
    guard let majorBrand = String(
        bytes: data[8..<12],
        encoding: .ascii
    ) else {
        throw R13IntegrationMediaError.malformedContainerHeader
    }
    return majorBrand
}

final class R13IntegrationMediaPipeline:
    MediaPipelineService,
    @unchecked Sendable {
    private struct State {
        var beginSessionCount = 0
        var sessions: [R13IntegrationMediaSession] = []
    }

    private let resolution: VideoResolution
    private let frames: [FrameRecord]
    private let estimatedFrameCount: Int
    private let failureThresholds: [Int?]
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(
        resolution: VideoResolution,
        frames: [FrameRecord],
        estimatedFrameCount: Int,
        failureThresholds: [Int?] = []
    ) {
        self.resolution = resolution
        self.frames = frames
        self.estimatedFrameCount = estimatedFrameCount
        self.failureThresholds = failureThresholds
    }

    var beginSessionCount: Int {
        state.withLock { $0.beginSessionCount }
    }

    var sessions: [R13IntegrationMediaSession] {
        state.withLock { $0.sessions }
    }

    func probe(url: URL) async throws -> SourceProfile {
        SourceProfile(
            url: url,
            resolution: resolution,
            frameRate: 30,
            durationSeconds: Double(frames.count) / 30,
            estimatedFrameCount: estimatedFrameCount,
            codecHint: "r13-integration",
            hasAudio: false
        )
    }

    func beginSession(
        source: SourceProfile,
        output: OutputProfile
    ) async throws -> MediaSession {
        let attemptIndex = state.withLock { $0.beginSessionCount }
        let threshold = failureThresholds.indices.contains(attemptIndex)
            ? failureThresholds[attemptIndex]
            : nil
        let session = try R13IntegrationMediaSession(
            sourceProfile: source,
            outputProfile: output,
            frames: frames,
            failureAfterFrameCount: threshold
        )
        state.withLock { current in
            current.beginSessionCount += 1
            current.sessions.append(session)
        }
        return session
    }

    func start() {}
    func stop() {}
}

final class R13IntegrationMediaSession:
    MediaSession,
    @unchecked Sendable {
    private struct State {
        var nextFrameIndex = 0
        var appendedFrameIndices: [Int] = []
        var finalMetadata: [String: String] = [:]
        var finishCount = 0
        var cancelCount = 0
        var cancelled = false
        var published = false
        var publishedOutputIdentity: MediaOutputPublicationIdentity?
    }

    let sourceProfile: SourceProfile
    let outputProfile: OutputProfile
    let outputPixelBufferPool: CVPixelBufferPool
    let prepublicationOutputURL: URL
    var terminalCleanupError: MediaPipelineError? { nil }

    private let frames: [FrameRecord]
    private let failureAfterFrameCount: Int?
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(
        sourceProfile: SourceProfile,
        outputProfile: OutputProfile,
        frames: [FrameRecord],
        failureAfterFrameCount: Int?
    ) throws {
        self.sourceProfile = sourceProfile
        self.outputProfile = outputProfile
        self.frames = frames
        self.failureAfterFrameCount = failureAfterFrameCount
        outputPixelBufferPool = try PixelBufferBridge.makePool(
            width: outputProfile.resolution.width,
            height: outputProfile.resolution.height,
            format: R03NV12Contract.pixelFormat,
            capacity: 2
        )
        prepublicationOutputURL = outputProfile.url
            .deletingLastPathComponent()
            .appendingPathComponent(
                ".\(outputProfile.url.lastPathComponent)."
                    + "\(outputProfile.transactionIdentifier).partial"
            )
    }

    var appendedFrameIndices: [Int] {
        state.withLock { $0.appendedFrameIndices }
    }

    var finalMetadata: [String: String] {
        state.withLock { $0.finalMetadata }
    }

    var finishCount: Int {
        state.withLock { $0.finishCount }
    }

    var cancelCount: Int {
        state.withLock { $0.cancelCount }
    }

    var publishedOutputIdentity: MediaOutputPublicationIdentity? {
        state.withLock { $0.publishedOutputIdentity }
    }

    func nextSourceFrame() async throws -> FrameRecord? {
        try state.withLock { current -> FrameRecord? in
            if current.cancelled {
                throw CancellationError()
            }
            if let failureAfterFrameCount,
               current.nextFrameIndex == failureAfterFrameCount {
                throw R13IntegrationMediaError.interrupted
            }
            guard current.nextFrameIndex < frames.count else { return nil }
            defer { current.nextFrameIndex += 1 }
            return frames[current.nextFrameIndex]
        }
    }

    func appendOutput(
        pixelBuffer _: CVPixelBuffer,
        timing: FrameTiming
    ) async throws {
        try state.withLock { current in
            guard !current.cancelled else { throw CancellationError() }
            current.appendedFrameIndices.append(timing.frameIndex)
        }
    }

    func finish() async throws {
        try await finish(
            finalMetadata: outputProfile.timedMetadataTemplate
        )
    }

    func finish(finalMetadata: [String: String]) async throws {
        try await finish(
            finalMetadata: finalMetadata,
            beforeReopen: {},
            validatingBeforePublish: {}
        )
    }

    func finish(
        finalMetadata: [String: String],
        validatingBeforePublish: @escaping @Sendable () async throws -> Void
    ) async throws {
        try await finish(
            finalMetadata: finalMetadata,
            beforeReopen: {},
            validatingBeforePublish: validatingBeforePublish
        )
    }

    func finish(
        finalMetadata: [String: String],
        beforeReopen: @escaping @Sendable () async throws -> Void,
        validatingBeforePublish: @escaping @Sendable () async throws -> Void
    ) async throws {
        do {
            try checkCancellation()
            try Data("r13-integration-output\n".utf8).write(
                to: prepublicationOutputURL,
                options: .atomic
            )
            try await beforeReopen()
            try checkCancellation()
            try await validatingBeforePublish()
            try checkCancellation()
            try FileManager.default.moveItem(
                at: prepublicationOutputURL,
                to: outputProfile.url
            )
            let measuredOutput = try R13LocalRestartSourceMeasurer()
                .measureSource(at: outputProfile.url)
            state.withLock { current in
                current.finalMetadata = finalMetadata
                current.finishCount += 1
                current.published = true
                current.publishedOutputIdentity =
                    MediaOutputPublicationIdentity(
                        sha256: measuredOutput.sha256,
                        byteCount: measuredOutput.byteCount
                    )
            }
        } catch {
            try? FileManager.default.removeItem(
                at: prepublicationOutputURL
            )
            throw error
        }
    }

    func cancel() {
        let removePartial = state.withLock { current -> Bool in
            current.cancelCount += 1
            current.cancelled = true
            return !current.published
        }
        if removePartial {
            try? FileManager.default.removeItem(at: prepublicationOutputURL)
        }
    }

    private func checkCancellation() throws {
        try Task.checkCancellation()
        if state.withLock({ $0.cancelled }) {
            throw CancellationError()
        }
    }
}

func readR13ReleaseMetadata(at url: URL) async throws -> [String: String] {
    let asset = AVURLAsset(url: url)
    var observed: [String: String] = [:]
    for track in try await asset.loadTracks(withMediaType: .metadata) {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: nil
        )
        guard reader.canAdd(output) else {
            throw R13IntegrationMediaError.metadataReaderRejected
        }
        reader.add(output)
        let adaptor = AVAssetReaderOutputMetadataAdaptor(
            assetReaderTrackOutput: output
        )
        guard reader.startReading() else {
            throw R13IntegrationMediaError.metadataReaderFailed
        }
        while let group = adaptor.nextTimedMetadataGroup() {
            for item in group.items {
                let identifier = item.identifier?.rawValue
                let storedKey = item.key as? String
                    ?? (item.key as? NSString).map(String.init)
                guard let key = [identifier, storedKey]
                    .compactMap({ $0 })
                    .first(where: {
                        $0.hasPrefix(
                            R13ReleaseIdentity.metadataNamespace
                        )
                    }),
                      let value = try await item.load(.stringValue) else {
                    continue
                }
                guard observed.updateValue(value, forKey: key) == nil else {
                    throw R13IntegrationMediaError
                        .duplicateMetadataKey(key)
                }
            }
        }
        guard reader.status == .completed else {
            throw R13IntegrationMediaError.metadataReaderFailed
        }
    }
    return observed
}

extension R13ReleaseIntegrationTests {
    func testShippingServicePublishesUIExposed1440pThroughRealAdaptiveMPS()
        async throws {
        let workspace = try R13IntegrationWorkspace(
            outputFileName: "adaptive-1440-output.mp4"
        )
        defer { workspace.remove() }
        try await writeOneFrameVideo(
            to: workspace.sourceURL,
            resolution: .p720,
            duration: CMTime(value: 1, timescale: 30)
        )
        let visibleTargets = await MirmirViewModel.targets(for: .p720)
        XCTAssertTrue(visibleTargets.contains(.p1440))
        let scalePlan = try R13ReleaseJobContracts.scalePlan(
            source: .p720,
            target: .p1440
        )
        guard case .adaptiveMPSLanczos(let adaptivePlan) =
                scalePlan else {
            return XCTFail("Expected the p720-to-p1440 adaptive plan.")
        }
        XCTAssertEqual(adaptivePlan.sourceResolution, .p720)
        XCTAssertEqual(
            adaptivePlan.processingSourceResolution,
            .p720
        )
        XCTAssertEqual(adaptivePlan.targetResolution, .p1440)
        let modeBinding = R13ReleaseModePolicy.binding(
            for: .deterministic
        )
        XCTAssertEqual(
            modeBinding.scalerKind,
            .deterministicMPSLanczos
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
        let job = UpscaleJob(
            identifier: "r13-real-adaptive-p720-to-p1440",
            inputURL: workspace.sourceURL,
            outputURL: workspace.outputURL,
            targetResolution: .p1440,
            codec: .hevc,
            preserveAudio: false,
            mode: .deterministic
        )

        let result = try await service.submit(job).waitForCompletion()

        XCTAssertEqual(result, workspace.outputURL)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: result.path)
        )
        try await assertR13ReopenedOutput(
            at: result,
            resolution: .p1440
        )
        try await assertR13ReopenedCodecAndContainer(
            at: result,
            codec: .hevc,
            pathExtension: "mp4",
            majorBrand: "mp42"
        )
        let reopened = try await media.probe(url: result)
        XCTAssertEqual(reopened.resolution, .p1440)
        XCTAssertEqual(reopened.codedResolution, .p1440)
        XCTAssertEqual(reopened.scanStructure, .progressive)
        let expectedIdentity =
            try makeR13ExpectedAdaptiveIntegrationIdentity(
                job: job,
                workspace: workspace,
                harness: harness,
                scalePlan: scalePlan
            )
        let metadata = try await readR13ReleaseMetadata(at: result)
        try expectedIdentity.validateTimedMetadata(metadata)
        XCTAssertEqual(
            metadata["com.mirmir.release.route-id"],
            modeBinding.adaptiveRouteID
        )
        XCTAssertEqual(
            metadata["com.mirmir.release.backend-id"],
            modeBinding.backendID
        )
        XCTAssertEqual(
            metadata["com.mirmir.release.configuration-id"],
            modeBinding.adaptiveConfigurationIdentity(
                for: adaptivePlan
            )
        )
        XCTAssertTrue(
            try XCTUnwrap(
                metadata["com.mirmir.release.configuration-id"]
            ).contains("1280x720-to-2560x1440")
        )
        let diagnosticSnapshot = try await diagnostics.snapshot()
        XCTAssertTrue(diagnosticSnapshot.records.contains {
            $0.event.code.rawValue
                == "release_adaptive_scaler_ready"
        })
        XCTAssertTrue(diagnosticSnapshot.records.contains {
            $0.event.code.rawValue
                == "release_adaptive_media_output_published"
        })
        XCTAssertFalse(diagnosticSnapshot.records.contains {
            $0.event.code.rawValue
                == "release_backend_session_ready"
        })
        XCTAssertEqual(
            harness.capacityObservation.labels,
            try expectedR13IntegrationCapacityLabels(
                for: workspace,
                liveRecheckCountsByAttempt: [2]
            )
        )
        try await assertR13AdaptiveSuccessfulResourceClosure(
            service: service,
            harness: harness
        )
    }

    func testShippingServicePublishesProRes422HQFromRegistered422Source()
        async throws {
        try await assertShippingServicePublishesRegisteredProRes(
            label: "prores-422-hq",
            format: .sdrBT709YUV422SixteenBit,
            codec: .proRes422HQ,
            expectsAlpha: false
        )
    }

    func testShippingServicePublishesProRes4444WithPreservedAlpha()
        async throws {
        try await assertShippingServicePublishesRegisteredProRes(
            label: "prores-4444-alpha",
            format: .sdrBT709HighPrecisionAlpha(mode: .straight),
            codec: .proRes4444,
            expectsAlpha: true
        )
    }

    private func assertShippingServicePublishesRegisteredProRes(
        label: String,
        format: MediaVideoFormat,
        codec: OutputCodec,
        expectsAlpha: Bool
    ) async throws {
        let workspace = try R13IntegrationWorkspace(
            outputFileName: "\(label)-output.mov"
        )
        defer { workspace.remove() }
        let sourceURL = workspace.directory.appendingPathComponent(
            "\(label)-source.mov"
        )
        if codec == .proRes422HQ {
            try await writeUncompressedNon420VideoFixture(
                to: sourceURL,
                resolution: .p720,
                format: Non420VideoFixtureFormat(
                    videoFormat: format
                ),
                frameCount: 1,
                frameDuration: CMTime(value: 1, timescale: 30)
            )
        } else {
            try await writeCompressedRegisteredVideoFixture(
                to: sourceURL,
                resolution: .p720,
                videoFormat: format,
                codec: codec,
                frameCount: 1,
                frameDuration: CMTime(value: 1, timescale: 30)
            )
        }
        let diagnostics = MirmirDiagnosticStore()
        let media = AVFoundationMediaPipeline(
            metal: NoopMetalRenderingService(),
            diagnostics: diagnostics
        )
        let source = try await media.probe(url: sourceURL)
        XCTAssertEqual(source.resolution, .p720, label)
        XCTAssertEqual(source.videoFormat, format, label)
        XCTAssertEqual(source.scanStructure, .progressive, label)
        XCTAssertEqual(source.videoFormat.hasAlpha, expectsAlpha, label)
        let hardening = try R13IntegrationHardeningHarness.make(
            jobsRootURL: workspace.jobsRootURL,
            exactFrameCount: 1
        )
        let service = R13ReleaseUpscalerEngineService(
            media: media,
            hardeningRuntime: hardening.runtime,
            diagnostics: diagnostics
        )
        let job = UpscaleJob(
            identifier: "r13-\(label)-shipping",
            inputURL: sourceURL,
            outputURL: workspace.outputURL,
            targetResolution: .p1080,
            codec: codec,
            preserveAudio: false,
            mode: .deterministic
        )

        let result = try await waitForR13Completion(
            service.submit(job),
            timeout: .seconds(120)
        )

        XCTAssertEqual(result, workspace.outputURL, label)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: result.path),
            label
        )
        try await assertR13ReopenedOutput(
            at: result,
            resolution: .p1080
        )
        try await assertR13ReopenedCodecAndContainer(
            at: result,
            codec: codec,
            pathExtension: "mov",
            majorBrand: "qt  "
        )
        let verification = try await OutputMediaVerifier().verify(
            url: result,
            expectation: OutputMediaVerificationExpectation(
                resolution: .p1080,
                codec: codec,
                timing: try makeTimingSnapshot(
                    presentationTime: .zero,
                    duration: CMTime(value: 1, timescale: 30)
                ),
                videoColor: .preserving(format, codec: codec)
            )
        )
        XCTAssertEqual(verification.frameCount, 1, label)
        XCTAssertEqual(verification.scanStructure, .progressive, label)
        XCTAssertEqual(
            verification.alphaPayloadBytes > 0,
            expectsAlpha,
            label
        )
        if expectsAlpha {
            try await assertR13ReopenedAlphaIsNonOpaque(at: result)
        }
        let metadata = try await readR13ReleaseMetadata(at: result)
        XCTAssertFalse(metadata.isEmpty, label)
        XCTAssertTrue(
            metadata.keys.allSatisfy {
                $0.hasPrefix(R13ReleaseIdentity.metadataNamespace)
            },
            label
        )
    }

    func testShippingServiceCompletesFortyFrameHEVCMP4WithAAC()
        async throws {
        let workspace = try R13IntegrationWorkspace(
            outputFileName: "output.mp4"
        )
        defer { workspace.remove() }
        let videoOnlyURL = workspace.directory.appendingPathComponent(
            "video-only.mp4"
        )
        let audioOnlyURL = workspace.directory.appendingPathComponent(
            "audio-only.m4a"
        )
        let frameCount = 40
        let frameDuration = CMTime(value: 1_001, timescale: 30_000)
        try await writeVideoFrames(
            to: videoOnlyURL,
            resolution: .p1080,
            frameCount: frameCount,
            frameDuration: frameDuration
        )
        try writeAACFixture(
            to: audioOnlyURL,
            seed: 13,
            frameCount: 64_064
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
        XCTAssertEqual(source.resolution, .p1080)
        XCTAssertTrue(source.hasAudio)
        let hardening = try R13IntegrationHardeningHarness.make(
            jobsRootURL: workspace.jobsRootURL,
            exactFrameCount: frameCount
        )
        let service = R13ReleaseUpscalerEngineService(
            media: media,
            hardeningRuntime: hardening.runtime,
            diagnostics: diagnostics
        )
        let job = UpscaleJob(
            identifier: "r13-hevc-pool-regression",
            inputURL: workspace.sourceURL,
            outputURL: workspace.outputURL,
            targetResolution: .p2160,
            codec: .hevc,
            preserveAudio: true,
            mode: .deterministic
        )

        let handle = try service.submit(job)
        let result: URL
        do {
            result = try await waitForR13Completion(
                handle,
                timeout: .seconds(120)
            )
        } catch {
            let snapshot = try await diagnostics.snapshot()
            XCTFail(
                "HEVC regression failed with \(type(of: error)): "
                    + "\(String(describing: error)); events="
                    + snapshot.records.suffix(8).map {
                        $0.event.code.rawValue
                    }.joined(separator: ",")
            )
            return
        }

        XCTAssertEqual(result, workspace.outputURL)
        try await assertR13ReopenedOutput(
            at: result,
            resolution: .p2160
        )
        let reopened = try await media.probe(url: result)
        XCTAssertTrue(reopened.hasAudio)
        XCTAssertTrue(["hvc1", "hev1"].contains(reopened.codecHint))
        try await assertR13ReopenedCodecAndContainer(
            at: result,
            codec: .hevc,
            pathExtension: "mp4",
            majorBrand: "mp42"
        )
        let metadata = try await readR13ReleaseMetadata(at: result)
        XCTAssertFalse(metadata.isEmpty)
        XCTAssertTrue(
            metadata.keys.allSatisfy {
                $0.hasPrefix(R13ReleaseIdentity.metadataNamespace)
            }
        )
    }

    func testShippingServiceUpscalesAnamorphic1080pAtPresentationGeometry()
        async throws {
        let workspace = try R13IntegrationWorkspace()
        defer { workspace.remove() }
        let codedResolution = VideoResolution(width: 1_440, height: 1_080)
        let sourcePixelAspectRatio = try XCTUnwrap(
            VideoPixelAspectRatio(
                horizontalSpacing: 4,
                verticalSpacing: 3
            )
        )
        try await writeOneFrameVideo(
            to: workspace.sourceURL,
            resolution: codedResolution,
            duration: CMTime(value: 1, timescale: 30),
            pixelAspectRatio: sourcePixelAspectRatio
        )
        let diagnostics = MirmirDiagnosticStore()
        let media = AVFoundationMediaPipeline(
            metal: NoopMetalRenderingService(),
            diagnostics: diagnostics
        )
        let source = try await media.probe(url: workspace.sourceURL)
        XCTAssertEqual(source.resolution, .p1080)
        XCTAssertEqual(source.codedResolution, codedResolution)
        XCTAssertEqual(source.pixelAspectRatio, sourcePixelAspectRatio)
        let service = R13ReleaseUpscalerEngineService(
            media: media,
            diagnostics: diagnostics
        )
        let job = UpscaleJob(
            identifier: "r13-anamorphic-1080p",
            inputURL: workspace.sourceURL,
            outputURL: workspace.outputURL,
            targetResolution: .p2160,
            codec: .hevc,
            preserveAudio: false,
            mode: .deterministic
        )

        let result = try await service.submit(job).waitForCompletion()

        XCTAssertEqual(result, workspace.outputURL)
        try await assertR13ReopenedOutput(
            at: result,
            resolution: .p2160
        )
        let output = try await media.probe(url: result)
        XCTAssertEqual(output.resolution, .p2160)
        XCTAssertEqual(output.codedResolution, .p2160)
        if let outputPixelAspectRatio = output.pixelAspectRatio {
            XCTAssertEqual(
                outputPixelAspectRatio,
                try XCTUnwrap(
                    VideoPixelAspectRatio(
                        horizontalSpacing: 1,
                        verticalSpacing: 1
                    )
                )
            )
        }
        let snapshot = try await diagnostics.snapshot()
        XCTAssertTrue(snapshot.records.contains {
            $0.event.code.rawValue
                == "release_first_decoded_frame_observed"
        })
        XCTAssertFalse(snapshot.records.contains {
            $0.event.code.rawValue
                == "release_first_decoded_frame_geometry_mismatch"
        })
    }
}

private func makeR13ExpectedAdaptiveIntegrationIdentity(
    job: UpscaleJob,
    workspace: R13IntegrationWorkspace,
    harness: R13IntegrationHardeningHarness,
    scalePlan: R13ReleaseScalePlan
) throws -> R13ReleaseIdentity {
    let modeBinding = R13ReleaseModePolicy.binding(
        for: job.mode,
        enginePreference: job.processingConfiguration.enginePreference
    )
    let environment = try R13ReleaseEnvironment(
        application: harness.environment.application,
        framework: R13ReleaseFrameworkIdentity(
            frameworkIdentifier: modeBinding.frameworkIdentity,
            version: harness.environment.framework.version,
            buildIdentity: harness.environment.framework.buildIdentity
        ),
        runtime: harness.environment.runtime
    )
    return try R13ReleaseHardeningRuntime.makeReleaseIdentity(
        job: job,
        scalePlan: scalePlan,
        modeBinding: modeBinding,
        source: R13LocalRestartSourceMeasurer().measureSource(
            at: workspace.sourceURL
        ),
        environment: environment,
        policyResources: harness.documents.policyResources
    )
}

private func assertR13AdaptiveSuccessfulResourceClosure(
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

func assertR13ReopenedCodecAndContainer(
    at url: URL,
    codec: OutputCodec,
    pathExtension: String,
    majorBrand: String
) async throws {
    XCTAssertEqual(url.pathExtension.lowercased(), pathExtension)
    XCTAssertEqual(try readR13ISOBaseMediaMajorBrand(at: url), majorBrand)
    let asset = AVURLAsset(url: url)
    let tracks = try await asset.loadTracks(withMediaType: .video)
    let track = try XCTUnwrap(tracks.first)
    let formats = try await track.load(.formatDescriptions)
    let format = try XCTUnwrap(formats.first)
    XCTAssertEqual(
        CMFormatDescriptionGetMediaSubType(format),
        expectedR13CodecSubtype(codec)
    )
}

private func expectedR13CodecSubtype(
    _ codec: OutputCodec
) -> CMVideoCodecType {
    switch codec {
    case .h264:
        return kCMVideoCodecType_H264
    case .hevc:
        return kCMVideoCodecType_HEVC
    case .proRes422HQ:
        return kCMVideoCodecType_AppleProRes422HQ
    case .proRes4444:
        return kCMVideoCodecType_AppleProRes4444
    }
}

private func assertR13ReopenedAlphaIsNonOpaque(
    at url: URL
) async throws {
    let asset = AVURLAsset(url: url)
    let tracks = try await asset.loadTracks(withMediaType: .video)
    let track = try XCTUnwrap(tracks.first)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(
        track: track,
        outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_444YpCbCr16VideoRange_16A_TriPlanar,
            kCVPixelBufferIOSurfacePropertiesKey as String:
                [String: Any]()
        ]
    )
    guard reader.canAdd(output) else {
        throw MediaTestFailure.cannotAddReaderOutput
    }
    reader.add(output)
    guard reader.startReading() else {
        throw MediaTestFailure.cannotStartReader
    }
    let sample = try XCTUnwrap(output.copyNextSampleBuffer())
    let pixelBuffer = try XCTUnwrap(
        CMSampleBufferGetImageBuffer(sample)
    )
    XCTAssertEqual(
        CVPixelBufferGetPixelFormatType(pixelBuffer),
        kCVPixelFormatType_444YpCbCr16VideoRange_16A_TriPlanar
    )
    XCTAssertEqual(CVPixelBufferGetPlaneCount(pixelBuffer), 3)
    let lockStatus = CVPixelBufferLockBaseAddress(
        pixelBuffer,
        .readOnly
    )
    XCTAssertEqual(lockStatus, kCVReturnSuccess)
    guard lockStatus == kCVReturnSuccess else {
        throw MediaTestFailure.cannotCreatePixelBuffer(lockStatus)
    }
    defer {
        CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
    }
    let alphaPlane = 2
    let baseAddress = try XCTUnwrap(
        CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, alphaPlane)
    )
    let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, alphaPlane)
    let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, alphaPlane)
    let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(
        pixelBuffer,
        alphaPlane
    )
    var minimum = UInt16.max
    var maximum = UInt16.min
    for row in 0..<height {
        let words = baseAddress
            .advanced(by: row * bytesPerRow)
            .assumingMemoryBound(to: UInt16.self)
        for column in 0..<width {
            minimum = min(minimum, words[column])
            maximum = max(maximum, words[column])
        }
    }
    XCTAssertGreaterThan(minimum, 0)
    XCTAssertLessThan(maximum, UInt16.max)
    XCTAssertLessThan(minimum, maximum)
    XCTAssertNil(output.copyNextSampleBuffer())
    XCTAssertEqual(reader.status, .completed)
}

private func waitForR13Completion(
    _ handle: UpscalerJobHandle,
    timeout: Duration
) async throws -> URL {
    try await withThrowingTaskGroup(of: URL.self) { group in
        group.addTask {
            try await handle.waitForCompletion()
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            handle.cancel()
            throw MediaTestFailure.timeout
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else {
            handle.cancel()
            throw MediaTestFailure.timeout
        }
        return result
    }
}

// swiftlint:enable file_length
