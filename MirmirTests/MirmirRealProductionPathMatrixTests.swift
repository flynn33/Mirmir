import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import XCTest
@testable import Mirmir

// The test keeps its fixture, production execution matrix, and independent
// media verifier together so the acceptance cannot silently lose one layer.
// swiftlint:disable file_length

final class MirmirRealProductionPathMatrixTests: XCTestCase {
    // This acceptance uses the shipping service's default production session
    // and scaler factories. The compact fixture keeps all ten native paths in
    // one routinely reproducible test without replacing any backend with a
    // test double.
    func testAllTenSelectablePathsProcessCompactRealMediaWithoutDefect()
        async throws {
        try await runRealProductionPathMatrix(
            targetResolution: .p1080,
            strategyPreference: .direct,
            continueAfterPathFailure: false
        )
    }

    // Every selectable path must also execute outside the catalog's fixed
    // scale factors. This exercises the shipping adaptive route rather than
    // substituting a test scaler or reducing the requested output geometry.
    // The runner records each thrown path failure and continues so a broken
    // native route cannot hide the outcomes of the remaining paths.
    func testAllTenSelectablePathsProcessArbitraryRealMediaWithoutDefect()
        async throws {
        try await runRealProductionPathMatrix(
            targetResolution: .p720,
            strategyPreference: .adaptive,
            continueAfterPathFailure: true
        )
    }

    // swiftlint:disable:next function_body_length
    private func runRealProductionPathMatrix(
        targetResolution: VideoResolution,
        strategyPreference: UpscaleStrategyPreference,
        continueAfterPathFailure: Bool
    ) async throws {
        let workspace = try MirmirRealProductionPathMatrixWorkspace()
        defer { workspace.remove() }

        let frameCount = 3
        let frameDuration = CMTime(value: 1, timescale: 30)
        try await writeVideoFrames(
            to: workspace.videoOnlyURL,
            resolution: .p270,
            frameCount: frameCount,
            frameDuration: frameDuration,
            framePixelBufferFiller: fillMirmirMatrixVideoFrame
        )
        try writeAACFixture(
            to: workspace.audioOnlyURL,
            seed: 61,
            frameCount: 4_800
        )
        try await muxVideoAndAAC(
            videoURL: workspace.videoOnlyURL,
            audioURL: workspace.audioOnlyURL,
            destinationURL: workspace.sourceURL
        )

        XCTAssertEqual(
            MirmirRealProductionPathScenario.all.map(\.path),
            UpscaleEnginePreference.concreteProcessingPaths,
            "The real-media matrix must cover every selectable path exactly once."
        )
        try await requireEveryNativeMatrixRouteToBeRunnable()

        let sourceTimeline = try await readMirmirMatrixVideoTimeline(
            at: workspace.sourceURL,
            expectedResolution: .p270
        )
        assertMirmirMatrixDecodedContent(
            sourceTimeline,
            label: "source"
        )
        assertMirmirMatrixTimeline(
            sourceTimeline,
            hasFrameCount: frameCount,
            frameDuration: frameDuration,
            label: "source"
        )
        let sourceAACIdentity = try await OutputMediaAACIdentityReader().read(
            url: workspace.sourceURL
        )
        XCTAssertEqual(sourceAACIdentity.codec, kAudioFormatMPEG4AAC)
        XCTAssertEqual(sourceAACIdentity.sampleRate, 48_000)
        XCTAssertEqual(sourceAACIdentity.channelCount, 2)

        let diagnostics = MirmirDiagnosticStore()
        let metal = try DefaultMetalRenderingService()
        try metal.start()
        defer { metal.stop() }
        let media = AVFoundationMediaPipeline(
            metal: metal,
            diagnostics: diagnostics
        )
        let hardening = try R13ReleaseHardeningRuntime.production(
            cacheLocation: R13CacheLocationConfiguration(
                trustedRootURL: workspace.directoryURL,
                jobsRootURL: workspace.jobsRootURL,
                access: nil
            ),
            diagnostics: diagnostics
        )
        let service = R13ReleaseUpscalerEngineService(
            media: media,
            hardeningRuntime: hardening,
            diagnostics: diagnostics
        )

        let sourceProfile = try await media.probe(url: workspace.sourceURL)
        XCTAssertEqual(sourceProfile.resolution, .p270)
        XCTAssertEqual(sourceProfile.codedResolution, .p270)
        XCTAssertEqual(sourceProfile.audioTrackCount, 1)

        let scalePlan = try R13ReleaseJobContracts.scalePlan(
            source: .p270,
            target: targetResolution,
            strategyPreference: strategyPreference
        )
        var pathFailures: [String] = []
        for scenario in MirmirRealProductionPathScenario.all {
            let outputURL = workspace.outputURL(for: scenario.path)
            let processingConfiguration = UpscaleProcessingConfiguration(
                enginePreference: scenario.path,
                strategyPreference: strategyPreference
            )
            let job = UpscaleJob(
                identifier: "real-production-"
                    + scenario.path.outputFilenameSuffix,
                inputURL: workspace.sourceURL,
                outputURL: outputURL,
                targetResolution: targetResolution,
                codec: .h264,
                preserveAudio: true,
                mode: scenario.mode,
                processingConfiguration: processingConfiguration
            )

            do {
                let result = try await service.submit(job).waitForCompletion()

                XCTAssertEqual(result, outputURL, scenario.path.rawValue)
                XCTAssertTrue(
                    FileManager.default.fileExists(atPath: result.path),
                    scenario.path.rawValue
                )
                let profile = try await media.probe(url: result)
                XCTAssertEqual(
                    profile.resolution,
                    targetResolution,
                    scenario.path.rawValue
                )
                XCTAssertEqual(
                    profile.codedResolution,
                    targetResolution,
                    scenario.path.rawValue
                )
                XCTAssertEqual(
                    profile.estimatedFrameCount,
                    frameCount,
                    scenario.path.rawValue
                )
                XCTAssertEqual(
                    profile.audioTrackCount,
                    1,
                    scenario.path.rawValue
                )
                XCTAssertEqual(
                    profile.codecHint,
                    "avc1",
                    scenario.path.rawValue
                )

                try await assertMirmirMatrixOutput(
                    at: result,
                    scenario: scenario,
                    scalePlan: scalePlan,
                    processingConfiguration: processingConfiguration,
                    sourceTimeline: sourceTimeline,
                    sourceAACIdentity: sourceAACIdentity,
                    expectedFrameDuration: frameDuration
                )
            } catch {
                guard continueAfterPathFailure else { throw error }
                pathFailures.append(
                    "\(scenario.path.rawValue): \(String(reflecting: error))"
                )
            }
        }

        let recoverableJobs = try await service.recoverableJobs()
        XCTAssertTrue(recoverableJobs.jobs.isEmpty)
        if !pathFailures.isEmpty {
            XCTFail(
                "The real adaptive production-path matrix failed: "
                    + pathFailures.joined(separator: "; ")
            )
        }
    }
}

private struct MirmirRealProductionPathScenario {
    let path: UpscaleEnginePreference
    let mode: UpscaleMode
    let selectedBackendID: String

    var adaptiveSelectedBackendID: String {
        switch path {
        case .videoToolboxLowLatency:
            return "r04.videotoolbox.low-latency.adaptive"
        case .metalFXSpatial:
            return "r05.metalfx.spatial.adaptive"
        case .automatic,
             .accelerateVImageStandard,
             .accelerateVImageHighQuality,
             .mpsBilinear,
             .mpsLanczos,
             .coreImageLanczos,
             .coreImageBicubic,
             .videoToolboxPixelTransfer,
             .videoToolboxQuality:
            return selectedBackendID
        }
    }

    static let all: [Self] = [
        Self(
            path: .accelerateVImageStandard,
            mode: .quality,
            selectedBackendID: R03BaselineSubjectID.vImageLanczos3.rawValue
        ),
        Self(
            path: .accelerateVImageHighQuality,
            mode: .quality,
            selectedBackendID: R03BaselineSubjectID.vImageLanczos5.rawValue
        ),
        Self(
            path: .mpsBilinear,
            mode: .fast,
            selectedBackendID: R03BaselineSubjectID.mpsBilinear.rawValue
        ),
        Self(
            path: .mpsLanczos,
            mode: .deterministic,
            selectedBackendID: R03A11ProductAdmission.subjectID.rawValue
        ),
        Self(
            path: .coreImageLanczos,
            mode: .quality,
            selectedBackendID: R03BaselineSubjectID.coreImageLanczos.rawValue
        ),
        Self(
            path: .coreImageBicubic,
            mode: .quality,
            selectedBackendID: R03BaselineSubjectID.coreImageBicubic.rawValue
        ),
        Self(
            path: .videoToolboxPixelTransfer,
            mode: .fast,
            selectedBackendID: R03BaselineSubjectID.vtPixelTransfer.rawValue
        ),
        Self(
            path: .videoToolboxQuality,
            mode: .quality,
            selectedBackendID: R04VideoToolboxSubjectID.quality4x.rawValue
        ),
        Self(
            path: .videoToolboxLowLatency,
            mode: .fast,
            selectedBackendID: R04VideoToolboxSubjectID.lowLatency4x.rawValue
        ),
        Self(
            path: .metalFXSpatial,
            mode: .fast,
            selectedBackendID: R05MetalFXSubjectID.spatial4x.rawValue
        )
    ]
}

private struct MirmirRealProductionPathMatrixWorkspace {
    let directoryURL: URL
    let videoOnlyURL: URL
    let audioOnlyURL: URL
    let sourceURL: URL
    let jobsRootURL: URL
    private let outputsURL: URL

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "mirmir-real-production-path-matrix-\(UUID().uuidString)",
                isDirectory: true
            )
        videoOnlyURL = directoryURL.appendingPathComponent("video-only.mp4")
        audioOnlyURL = directoryURL.appendingPathComponent("audio-only.m4a")
        sourceURL = directoryURL.appendingPathComponent("source.mp4")
        jobsRootURL = directoryURL.appendingPathComponent(
            "Jobs",
            isDirectory: true
        )
        outputsURL = directoryURL.appendingPathComponent(
            "Outputs",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outputsURL,
            withIntermediateDirectories: true
        )
    }

    func outputURL(for path: UpscaleEnginePreference) -> URL {
        outputsURL.appendingPathComponent(
            "output-\(path.outputFilenameSuffix).mp4"
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

private struct MirmirMatrixVideoFrameTiming {
    let presentationTime: CMTime
    let duration: CMTime
    let decodedContent: MirmirMatrixDecodedContent
}

private struct MirmirMatrixDecodedContent {
    let minimumLuma: UInt8
    let maximumLuma: UInt8
    let lumaSum: UInt64
    let pixelCount: Int
    let expectedLightCellLumaSum: UInt64
    let expectedLightCellCount: Int
    let expectedDarkCellLumaSum: UInt64
    let expectedDarkCellCount: Int
}

private enum MirmirMatrixFixturePattern {
    static let sourceResolution = VideoResolution.p270
    static let cellSize = 16
}

private struct MirmirMatrixVideoTimeline {
    let trackTimeRange: CMTimeRange
    let frames: [MirmirMatrixVideoFrameTiming]
}

private enum MirmirRealProductionPathMatrixError:
    Error,
    CustomStringConvertible {
    case nativeRoutesUnavailable([String])
    case videoReaderRejected(String)
    case videoReaderDidNotStart(String, Error?)
    case videoReaderFailed(String, AVAssetReader.Status, Error?)
    case decodedSampleCount(String, Int)
    case missingDecodedImage(String, Int)
    case invalidFixturePixelLayout(CVReturn?)
    case invalidDecodedPixelLayout(String, Int)
    case decodedPixelBufferLockFailed(String, Int, CVReturn)
    case invalidEffectiveFrameDuration(String, Int, CMTime)

    var description: String {
        switch self {
        case .nativeRoutesUnavailable(let failures):
            return "Required native production routes are unavailable: "
                + failures.joined(separator: "; ")
        case .videoReaderRejected(let label):
            return "The decoded-video reader rejected \(label)."
        case .videoReaderDidNotStart(let label, let error):
            return "The decoded-video reader did not start for \(label): "
                + String(describing: error)
        case .videoReaderFailed(let label, let status, let error):
            return "The decoded-video reader failed for \(label) with status "
                + "\(status.rawValue): \(String(describing: error))."
        case .decodedSampleCount(let label, let count):
            return "A decoded sample buffer for \(label) contained \(count) "
                + "samples instead of one."
        case .missingDecodedImage(let label, let index):
            return "Decoded frame \(index) for \(label) has no image buffer."
        case .invalidFixturePixelLayout(let status):
            return "The real production-path matrix fixture has an invalid "
                + "NV12 layout or lock status \(String(describing: status))."
        case .invalidDecodedPixelLayout(let label, let index):
            return "Decoded frame \(index) for \(label) has an invalid NV12 "
                + "luma layout."
        case .decodedPixelBufferLockFailed(
            let label,
            let index,
            let status
        ):
            return "Decoded frame \(index) for \(label) could not be locked "
                + "for content verification (\(status))."
        case .invalidEffectiveFrameDuration(
            let label,
            let index,
            let duration
        ):
            return "Decoded frame \(index) for \(label) has invalid effective "
                + "duration \(duration)."
        }
    }
}

private func fillMirmirMatrixVideoFrame(
    _ pixelBuffer: CVPixelBuffer,
    frameIndex: Int
) throws {
    guard frameIndex >= 0,
          CVPixelBufferGetPixelFormatType(pixelBuffer)
            == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
          CVPixelBufferGetPlaneCount(pixelBuffer) == 2 else {
        throw MirmirRealProductionPathMatrixError
            .invalidFixturePixelLayout(nil)
    }
    let lockStatus = CVPixelBufferLockBaseAddress(pixelBuffer, [])
    guard lockStatus == kCVReturnSuccess else {
        throw MirmirRealProductionPathMatrixError
            .invalidFixturePixelLayout(lockStatus)
    }
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

    guard let lumaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
          let chromaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)
    else {
        throw MirmirRealProductionPathMatrixError
            .invalidFixturePixelLayout(nil)
    }
    let lumaWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
    let lumaHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
    let lumaRowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
    let chromaHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
    let chromaRowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
    guard lumaWidth > 0,
          lumaHeight > 0,
          lumaRowBytes >= lumaWidth,
          chromaHeight > 0,
          chromaRowBytes > 0 else {
        throw MirmirRealProductionPathMatrixError
            .invalidFixturePixelLayout(nil)
    }

    let temporalOffset = (frameIndex % 4) * 16
    for row in 0..<lumaHeight {
        let luma = lumaBase.advanced(by: row * lumaRowBytes)
            .assumingMemoryBound(to: UInt8.self)
        luma.update(repeating: 64, count: lumaRowBytes)
        for column in 0..<lumaWidth {
            let isLight = ((column / 16) + (row / 16)).isMultiple(of: 2)
            luma[column] = UInt8(
                (isLight ? 160 : 64) + temporalOffset
            )
        }
    }
    for row in 0..<chromaHeight {
        chromaBase.advanced(by: row * chromaRowBytes)
            .assumingMemoryBound(to: UInt8.self)
            .update(repeating: 128, count: chromaRowBytes)
    }
}

private func requireEveryNativeMatrixRouteToBeRunnable() async throws {
    var failures: [String] = []
    let quality = try await R04VideoToolboxBackend.observeNativeCapability(
        subjectID: .quality4x
    )
    if case .runnable = quality.status {
        // Required route is available.
    } else {
        failures.append(
            "\(UpscaleEnginePreference.videoToolboxQuality.rawValue)="
                + String(describing: quality.status)
        )
    }
    let lowLatency = try await R04VideoToolboxBackend
        .observeNativeCapability(subjectID: .lowLatency4x)
    if case .runnable = lowLatency.status {
        // Required route is available.
    } else {
        failures.append(
            "\(UpscaleEnginePreference.videoToolboxLowLatency.rawValue)="
                + String(describing: lowLatency.status)
        )
    }
    let metalFX = try R05MetalFXSpatialBackend.observeNativeCapability(
        subjectID: .spatial4x
    )
    if case .runnable = metalFX.status {
        // Required route is available.
    } else {
        failures.append(
            "\(UpscaleEnginePreference.metalFXSpatial.rawValue)="
                + String(describing: metalFX.status)
        )
    }
    guard failures.isEmpty else {
        throw MirmirRealProductionPathMatrixError
            .nativeRoutesUnavailable(failures)
    }
}

// swiftlint:disable:next function_body_length
private func assertMirmirMatrixOutput(
    at url: URL,
    scenario: MirmirRealProductionPathScenario,
    scalePlan: R13ReleaseScalePlan,
    processingConfiguration: UpscaleProcessingConfiguration,
    sourceTimeline: MirmirMatrixVideoTimeline,
    sourceAACIdentity: OutputMediaAACIdentity,
    expectedFrameDuration: CMTime
) async throws {
    let label = scenario.path.rawValue
    let binding = R13ReleaseModePolicy.binding(
        for: scenario.mode,
        enginePreference: scenario.path
    )
    let expectedResolution: VideoResolution
    let expectedRouteID: String
    let expectedBackendID: String
    let expectedConfigurationID: String?
    let isAdaptive: Bool
    switch scalePlan {
    case .productQualified(let route):
        expectedResolution = route.canonicalTargetResolution
        expectedRouteID = route.rawValue
        expectedBackendID = binding.backendID
        expectedConfigurationID = nil
        isAdaptive = false
    case .adaptiveMPSLanczos(let plan):
        expectedResolution = plan.targetResolution
        expectedRouteID = binding.adaptiveRouteID
        expectedBackendID = binding.backendID
        expectedConfigurationID =
            binding.adaptiveConfigurationIdentity(for: plan)
        isAdaptive = true
    }
    let asset = AVURLAsset(
        url: url,
        options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
    )
    let isPlayable = try await asset.load(.isPlayable)
    XCTAssertTrue(isPlayable, label)
    let videoTracks = try await asset.loadTracks(withMediaType: .video)
    XCTAssertEqual(videoTracks.count, 1, label)
    let videoTrack = try XCTUnwrap(videoTracks.first, label)
    let formats = try await videoTrack.load(.formatDescriptions)
    let format = try XCTUnwrap(formats.first, label)
    XCTAssertEqual(
        CMFormatDescriptionGetMediaSubType(format),
        kCMVideoCodecType_H264,
        label
    )
    let dimensions = CMVideoFormatDescriptionGetDimensions(format)
    XCTAssertEqual(Int(dimensions.width), expectedResolution.width, label)
    XCTAssertEqual(Int(dimensions.height), expectedResolution.height, label)

    let audioTracks = try await asset.loadTracks(withMediaType: .audio)
    XCTAssertEqual(audioTracks.count, 1, label)
    let outputAACIdentity = try await OutputMediaAACIdentityReader().read(
        url: url
    )
    XCTAssertEqual(outputAACIdentity, sourceAACIdentity, label)

    let metadataTracks = try await asset.loadTracks(withMediaType: .metadata)
    XCTAssertEqual(metadataTracks.count, 1, label)
    let metadataTrack = try XCTUnwrap(metadataTracks.first, label)
    let metadataFormats = try await metadataTrack.load(.formatDescriptions)
    XCTAssertTrue(
        metadataFormats.contains {
            CMFormatDescriptionGetMediaSubType($0)
                == kCMMetadataFormatType_Boxed
        },
        label
    )
    let metadataTimeRange = try await metadataTrack.load(.timeRange)
    assertMirmirMatrixTime(
        metadataTimeRange.start,
        equals: sourceTimeline.trackTimeRange.start,
        label: "\(label) metadata start"
    )
    assertMirmirMatrixTime(
        metadataTimeRange.duration,
        equals: sourceTimeline.trackTimeRange.duration,
        label: "\(label) metadata duration"
    )

    let outputTimeline = try await readMirmirMatrixVideoTimeline(
        at: url,
        expectedResolution: expectedResolution
    )
    assertMirmirMatrixDecodedContent(
        outputTimeline,
        label: label
    )
    assertMirmirMatrixTimeline(
        outputTimeline,
        hasFrameCount: sourceTimeline.frames.count,
        frameDuration: expectedFrameDuration,
        label: "\(label) output"
    )
    assertMirmirMatrixTimeline(
        outputTimeline,
        equals: sourceTimeline,
        label: label
    )

    let metadata = try await readR13ReleaseMetadata(at: url)
    XCTAssertEqual(
        metadata["com.mirmir.release.engine-preference"],
        scenario.path.rawValue,
        label
    )
    XCTAssertEqual(
        metadata["com.mirmir.release.requested-mode"],
        scenario.mode.rawValue,
        label
    )
    XCTAssertEqual(
        metadata["com.mirmir.release.effective-mode"],
        binding.effectiveMode.rawValue,
        label
    )
    XCTAssertEqual(
        metadata["com.mirmir.release.route-id"],
        expectedRouteID,
        label
    )
    XCTAssertEqual(
        metadata["com.mirmir.release.backend-id"],
        expectedBackendID,
        label
    )
    if let expectedConfigurationID {
        XCTAssertEqual(
            metadata["com.mirmir.release.configuration-id"],
            expectedConfigurationID,
            label
        )
        XCTAssertEqual(
            metadata["com.mirmir.release.processing-configuration"],
            processingConfiguration.identity,
            label
        )
    }
    let orchestrationKeys = [
        R13ProductASHDecisionMetadata.selectedBackendsKey,
        R13ProductASHDecisionMetadata.statusKey,
        R13ProductASHDecisionMetadata.decisionCountKey,
        R13ProductASHDecisionMetadata.transitionCountKey,
        R13ProductASHDecisionMetadata.fallbackCountKey,
        R13ProductASHDecisionMetadata.candidateExclusionCountKey,
        R13ProductASHDecisionMetadata.journalSHA256Key
    ]
    if binding.usesProductOrchestration {
        if isAdaptive && scenario.path.requiresNativeUpscaleSession {
            try assertMirmirAdaptiveNativeRoutingMetadata(
                metadata,
                expectedBackendID:
                    scenario.adaptiveSelectedBackendID,
                expectedDecisionCount: sourceTimeline.frames.count,
                label: label
            )
        } else {
            XCTAssertEqual(
                metadata[R13ProductASHDecisionMetadata.selectedBackendsKey],
                scenario.selectedBackendID,
                label
            )
            XCTAssertEqual(
                metadata[R13ProductASHDecisionMetadata.statusKey],
                "complete",
                label
            )
            XCTAssertEqual(
                metadata[R13ProductASHDecisionMetadata.decisionCountKey],
                String(sourceTimeline.frames.count),
                label
            )
            XCTAssertEqual(
                metadata[R13ProductASHDecisionMetadata.transitionCountKey],
                "0",
                label
            )
            XCTAssertEqual(
                metadata[R13ProductASHDecisionMetadata.fallbackCountKey],
                "0",
                label
            )
            XCTAssertEqual(
                metadata[
                    R13ProductASHDecisionMetadata.candidateExclusionCountKey
                ],
                "0",
                label
            )
            let journalSHA256 = try XCTUnwrap(
                metadata[R13ProductASHDecisionMetadata.journalSHA256Key],
                label
            )
            XCTAssertNotEqual(
                journalSHA256,
                String(repeating: "0", count: 64),
                label
            )
        }
    } else {
        for key in orchestrationKeys {
            XCTAssertNil(metadata[key], "\(label) \(key)")
        }
    }
}

private func assertMirmirAdaptiveNativeRoutingMetadata(
    _ metadata: [String: String],
    expectedBackendID: String,
    expectedDecisionCount: Int,
    label: String
) throws {
    let status = try XCTUnwrap(
        metadata[R13ProductASHDecisionMetadata.statusKey],
        "\(label) has no native adaptive routing status."
    )
    XCTAssertNotEqual(
        status,
        "pending",
        "\(label) completed native adaptive processing but retained pending "
            + "routing status."
    )
    XCTAssertEqual(status, "complete", label)

    let selectedValue = try XCTUnwrap(
        metadata[R13ProductASHDecisionMetadata.selectedBackendsKey],
        "\(label) has no selected native adaptive backend evidence."
    )
    XCTAssertNotEqual(
        selectedValue,
        "pending",
        "\(label) completed native adaptive processing without recording "
            + "the selected native backend."
    )
    let selectedBackendIDs = selectedValue.split(separator: ",").map(String.init)
    XCTAssertEqual(selectedBackendIDs, [expectedBackendID], label)

    let decisionCountValue = try XCTUnwrap(
        metadata[R13ProductASHDecisionMetadata.decisionCountKey],
        "\(label) has no native adaptive decision count."
    )
    let decisionCount = try XCTUnwrap(
        Int(decisionCountValue),
        "\(label) has a non-numeric native adaptive decision count."
    )
    XCTAssertEqual(decisionCount, expectedDecisionCount, label)
    XCTAssertEqual(
        metadata[R13ProductASHDecisionMetadata.transitionCountKey],
        "0",
        label
    )
    XCTAssertEqual(
        metadata[R13ProductASHDecisionMetadata.fallbackCountKey],
        "0",
        label
    )
    XCTAssertEqual(
        metadata[R13ProductASHDecisionMetadata.candidateExclusionCountKey],
        "0",
        label
    )

    let journalSHA256 = try XCTUnwrap(
        metadata[R13ProductASHDecisionMetadata.journalSHA256Key],
        "\(label) has no native adaptive routing journal."
    )
    XCTAssertNotEqual(
        journalSHA256,
        String(repeating: "0", count: 64),
        "\(label) completed native adaptive processing without a finalized "
            + "routing journal."
    )
}

private func readMirmirMatrixDecodedContent(
    from pixelBuffer: CVPixelBuffer,
    label: String,
    frameIndex: Int
) throws -> MirmirMatrixDecodedContent {
    let lockStatus = CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    guard lockStatus == kCVReturnSuccess else {
        throw MirmirRealProductionPathMatrixError
            .decodedPixelBufferLockFailed(label, frameIndex, lockStatus)
    }
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

    let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
    let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
    let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
    guard width > 0,
          height > 0,
          rowBytes >= width,
          let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else {
        throw MirmirRealProductionPathMatrixError
            .invalidDecodedPixelLayout(label, frameIndex)
    }

    var minimum = UInt8.max
    var maximum = UInt8.min
    var sum = UInt64(0)
    for row in 0..<height {
        let luma = base.advanced(by: row * rowBytes)
            .assumingMemoryBound(to: UInt8.self)
        for column in 0..<width {
            let value = luma[column]
            minimum = min(minimum, value)
            maximum = max(maximum, value)
            sum += UInt64(value)
        }
    }

    let pattern = MirmirMatrixFixturePattern.self
    let sourceWidth = pattern.sourceResolution.width
    let sourceHeight = pattern.sourceResolution.height
    let patternColumnCount = sourceWidth / pattern.cellSize
    let patternRowCount = sourceHeight / pattern.cellSize
    var expectedLightCellLumaSum = UInt64(0)
    var expectedLightCellCount = 0
    var expectedDarkCellLumaSum = UInt64(0)
    var expectedDarkCellCount = 0
    for patternRow in 0..<patternRowCount {
        let sourceRow = patternRow * pattern.cellSize
            + pattern.cellSize / 2
        let decodedRow = min(
            height - 1,
            sourceRow * height / sourceHeight
        )
        let luma = base.advanced(by: decodedRow * rowBytes)
            .assumingMemoryBound(to: UInt8.self)
        for patternColumn in 0..<patternColumnCount {
            let sourceColumn = patternColumn * pattern.cellSize
                + pattern.cellSize / 2
            let decodedColumn = min(
                width - 1,
                sourceColumn * width / sourceWidth
            )
            let value = UInt64(luma[decodedColumn])
            if (patternColumn + patternRow).isMultiple(of: 2) {
                expectedLightCellLumaSum += value
                expectedLightCellCount += 1
            } else {
                expectedDarkCellLumaSum += value
                expectedDarkCellCount += 1
            }
        }
    }
    return MirmirMatrixDecodedContent(
        minimumLuma: minimum,
        maximumLuma: maximum,
        lumaSum: sum,
        pixelCount: width * height,
        expectedLightCellLumaSum: expectedLightCellLumaSum,
        expectedLightCellCount: expectedLightCellCount,
        expectedDarkCellLumaSum: expectedDarkCellLumaSum,
        expectedDarkCellCount: expectedDarkCellCount
    )
}

private func readMirmirMatrixVideoTimeline(
    at url: URL,
    expectedResolution: VideoResolution
) async throws -> MirmirMatrixVideoTimeline {
    let label = url.lastPathComponent
    let asset = AVURLAsset(
        url: url,
        options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
    )
    let tracks = try await asset.loadTracks(withMediaType: .video)
    let track = try XCTUnwrap(tracks.first, label)
    let trackTimeRange = try await track.load(.timeRange)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(
        track: track,
        outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
    )
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else {
        throw MirmirRealProductionPathMatrixError
            .videoReaderRejected(label)
    }
    reader.add(output)
    guard reader.startReading() else {
        throw MirmirRealProductionPathMatrixError
            .videoReaderDidNotStart(label, reader.error)
    }

    var frames: [MirmirMatrixVideoFrameTiming] = []
    while let sample = output.copyNextSampleBuffer() {
        let sampleCount = CMSampleBufferGetNumSamples(sample)
        guard sampleCount == 1 else {
            reader.cancelReading()
            throw MirmirRealProductionPathMatrixError
                .decodedSampleCount(label, sampleCount)
        }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else {
            reader.cancelReading()
            throw MirmirRealProductionPathMatrixError
                .missingDecodedImage(label, frames.count)
        }
        XCTAssertEqual(
            CVPixelBufferGetWidth(pixelBuffer),
            expectedResolution.width,
            label
        )
        XCTAssertEqual(
            CVPixelBufferGetHeight(pixelBuffer),
            expectedResolution.height,
            label
        )
        XCTAssertEqual(CVPixelBufferGetPlaneCount(pixelBuffer), 2, label)
        let decodedContent = try readMirmirMatrixDecodedContent(
            from: pixelBuffer,
            label: label,
            frameIndex: frames.count
        )
        frames.append(
            MirmirMatrixVideoFrameTiming(
                presentationTime:
                    CMSampleBufferGetPresentationTimeStamp(sample),
                duration: CMSampleBufferGetDuration(sample),
                decodedContent: decodedContent
            )
        )
    }
    guard reader.status == .completed else {
        throw MirmirRealProductionPathMatrixError.videoReaderFailed(
            label,
            reader.status,
            reader.error
        )
    }
    let timelineEnd = CMTimeRangeGetEnd(trackTimeRange)
    let effectiveFrames = try frames.enumerated().map { index, frame in
        let nextPresentationTime = index + 1 < frames.count
            ? frames[index + 1].presentationTime
            : nil
        return MirmirMatrixVideoFrameTiming(
            presentationTime: frame.presentationTime,
            duration: try effectiveMirmirMatrixFrameDuration(
                sampleDuration: frame.duration,
                presentationTime: frame.presentationTime,
                nextPresentationTime: nextPresentationTime,
                timelineEnd: timelineEnd,
                label: label,
                frameIndex: index
            ),
            decodedContent: frame.decodedContent
        )
    }
    return MirmirMatrixVideoTimeline(
        trackTimeRange: trackTimeRange,
        frames: effectiveFrames
    )
}

private func effectiveMirmirMatrixFrameDuration(
    sampleDuration: CMTime,
    presentationTime: CMTime,
    nextPresentationTime: CMTime?,
    timelineEnd: CMTime,
    label: String,
    frameIndex: Int
) throws -> CMTime {
    let effectiveDuration: CMTime
    if sampleDuration.isValid, sampleDuration.isNumeric {
        effectiveDuration = sampleDuration
    } else {
        effectiveDuration = CMTimeSubtract(
            nextPresentationTime ?? timelineEnd,
            presentationTime
        )
    }
    guard effectiveDuration.isValid,
          effectiveDuration.isNumeric,
          CMTimeCompare(effectiveDuration, .zero) > 0 else {
        throw MirmirRealProductionPathMatrixError
            .invalidEffectiveFrameDuration(
                label,
                frameIndex,
                effectiveDuration
            )
    }
    return effectiveDuration
}

private func assertMirmirMatrixDecodedContent(
    _ timeline: MirmirMatrixVideoTimeline,
    label: String
) {
    XCTAssertFalse(
        timeline.frames.isEmpty,
        "\(label) has no decoded frames for content verification."
    )
    for (index, frame) in timeline.frames.enumerated() {
        let content = frame.decodedContent
        XCTAssertGreaterThan(
            content.maximumLuma,
            content.minimumLuma,
            "\(label) frame \(index) is spatially constant."
        )
        XCTAssertGreaterThan(
            content.lumaSum,
            UInt64(16) * UInt64(content.pixelCount),
            "\(label) frame \(index) is at or below video-range black."
        )
        XCTAssertGreaterThan(
            content.expectedLightCellLumaSum
                * UInt64(content.expectedDarkCellCount),
            content.expectedDarkCellLumaSum
                * UInt64(content.expectedLightCellCount),
            "\(label) frame \(index) lost the fixture's checkerboard polarity."
        )
    }
    XCTAssertGreaterThan(
        Set(timeline.frames.map(\.decodedContent.lumaSum)).count,
        1,
        "\(label) lost the fixture's temporal image variation."
    )
    for (index, pair) in zip(
        timeline.frames,
        timeline.frames.dropFirst()
    ).enumerated() {
        XCTAssertGreaterThan(
            pair.1.decodedContent.lumaSum
                * UInt64(pair.0.decodedContent.pixelCount),
            pair.0.decodedContent.lumaSum
                * UInt64(pair.1.decodedContent.pixelCount),
            "\(label) frames \(index) and \(index + 1) lost the fixture's "
                + "increasing temporal luma sequence."
        )
    }
}

private func assertMirmirMatrixTimeline(
    _ timeline: MirmirMatrixVideoTimeline,
    hasFrameCount frameCount: Int,
    frameDuration: CMTime,
    label: String
) {
    XCTAssertEqual(timeline.frames.count, frameCount, label)
    assertMirmirMatrixTime(
        timeline.trackTimeRange.start,
        equals: .zero,
        label: "\(label) track start"
    )
    assertMirmirMatrixTime(
        timeline.trackTimeRange.duration,
        equals: CMTimeMultiply(
            frameDuration,
            multiplier: Int32(frameCount)
        ),
        label: "\(label) track duration"
    )
    for (index, frame) in timeline.frames.enumerated() {
        assertMirmirMatrixTime(
            frame.presentationTime,
            equals: CMTimeMultiply(
                frameDuration,
                multiplier: Int32(index)
            ),
            label: "\(label) frame \(index) presentation time"
        )
        assertMirmirMatrixTime(
            frame.duration,
            equals: frameDuration,
            label: "\(label) frame \(index) duration"
        )
    }
}

private func assertMirmirMatrixTimeline(
    _ actual: MirmirMatrixVideoTimeline,
    equals expected: MirmirMatrixVideoTimeline,
    label: String
) {
    XCTAssertEqual(actual.frames.count, expected.frames.count, label)
    assertMirmirMatrixTime(
        actual.trackTimeRange.start,
        equals: expected.trackTimeRange.start,
        label: "\(label) track start"
    )
    assertMirmirMatrixTime(
        actual.trackTimeRange.duration,
        equals: expected.trackTimeRange.duration,
        label: "\(label) track duration"
    )
    for (index, pair) in zip(actual.frames, expected.frames).enumerated() {
        assertMirmirMatrixTime(
            pair.0.presentationTime,
            equals: pair.1.presentationTime,
            label: "\(label) frame \(index) presentation time"
        )
        assertMirmirMatrixTime(
            pair.0.duration,
            equals: pair.1.duration,
            label: "\(label) frame \(index) duration"
        )
    }
}

private func assertMirmirMatrixTime(
    _ actual: CMTime,
    equals expected: CMTime,
    label: String
) {
    XCTAssertEqual(
        CMTimeCompare(actual, expected),
        0,
        "\(label): expected \(expected), observed \(actual)"
    )
}
