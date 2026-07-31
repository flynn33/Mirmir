import AVFoundation
import Foundation
@testable import Mirmir
import XCTest

@MainActor
final class MirmirUIWorkflowTests: XCTestCase {

    func test_debugDeploymentDefaultsToProductShellWithoutDeveloperEnvironment() {
        XCTAssertEqual(MirmirDeploymentMode.resolve(environment: [:]), .production)
        XCTAssertEqual(MirmirDeploymentMode.resolve(environment: ["MIRMIR_DEVELOPER_WORKSPACE": "0"]), .production)
    }

    func test_developerWorkspaceRequiresExplicitEnvironmentOptIn() {
        #if DEBUG
        XCTAssertEqual(MirmirDeploymentMode.resolve(environment: ["MIRMIR_DEVELOPER_WORKSPACE": "1"]), .development)
        #else
        XCTAssertEqual(MirmirDeploymentMode.resolve(environment: ["MIRMIR_DEVELOPER_WORKSPACE": "1"]), .production)
        #endif
    }

    func test_sourceDropProviderFailureSurfacesRecoveryAndBoundsDetail() {
        let viewModel = makeViewModel()
        let providerDetail = String(repeating: "x", count: 400)

        viewModel.handleSourceDropProviderResult(
            url: nil,
            errorDescription: "  \(providerDetail)  "
        )

        guard case .failed(let message) = viewModel.state else {
            return XCTFail("Expected a visible source-drop failure.")
        }
        XCTAssertTrue(message.contains("Drop it again"))
        XCTAssertTrue(message.contains("Choose Source"))
        XCTAssertTrue(message.contains(String(repeating: "x", count: 300)))
        XCTAssertFalse(message.contains(String(repeating: "x", count: 301)))
    }

    func test_sourceDropProviderSuccessUsesSourceProbeFlow() async {
        let viewModel = makeViewModel()
        let sourceURL = URL(
            fileURLWithPath:
                "/tmp/dropped-source-\(UUID().uuidString).mov"
        )

        viewModel.handleSourceDropProviderResult(
            url: sourceURL,
            errorDescription: "ignored because the URL resolved"
        )
        for _ in 0..<100 where viewModel.state == .probing {
            await Task.yield()
        }

        XCTAssertEqual(viewModel.state, .ready)
        XCTAssertEqual(viewModel.sourceProfile?.url, sourceURL)
    }

    func test_staleSourceDropFailureDoesNotReplaceNewerProbeOrRunningJob() {
        let viewModel = makeViewModel()
        viewModel.state = .probing

        viewModel.handleSourceDropProviderResult(
            url: nil,
            errorDescription: "stale provider failure"
        )

        XCTAssertEqual(viewModel.state, .probing)

        viewModel.state = .running
        viewModel.handleSourceDropProviderResult(
            url: nil,
            errorDescription: "late provider failure"
        )

        XCTAssertEqual(viewModel.state, .running)
    }

    func test_canStartRequiresValidReadyWorkflowState() {
        let viewModel = makeViewModel()
        let sourceProfile = makeSourceProfile()
        viewModel.sourceProfile = sourceProfile
        viewModel.targetResolution = .p2160
        viewModel.state = .ready

        XCTAssertFalse(viewModel.canStart)
        XCTAssertTrue(viewModel.acceptOutputURLSelectedByUser(
            viewModel.defaultOutputURL(for: sourceProfile, target: .p2160)
        ))
        XCTAssertTrue(viewModel.canStart)

        viewModel.targetResolution = .p1080
        XCTAssertFalse(viewModel.canStart)

        viewModel.targetResolution = .p2160
        viewModel.state = .running
        XCTAssertFalse(viewModel.canStart)
    }

    func test_canStartExplainsUnsupportedAudioRepresentationBeforeSubmission()
        throws {
        let reason = "Audio track 1 uses a non-interleaved Linear PCM "
            + "representation that cannot be sample-copied exactly. "
            + "Convert it to interleaved Linear PCM, or turn off Preserve "
            + "Source Audio Tracks for this job."
        let capability = SourceMediaPreservationCapability(
            verificationLevel: .exactProbe,
            tracks: [
                SourceMediaTrackCapability(
                    mediaType: AVMediaType.audio.rawValue,
                    ordinal: 0,
                    formatSubtypes: ["lpcm"],
                    isEnabled: true,
                    languageCode: nil,
                    extendedLanguageTag: nil,
                    sampleRate: 48_000,
                    channelCount: 2,
                    compressedAudioIdentitySHA256: nil,
                    linearPCMAudioIdentitySHA256: nil,
                    exactTrackIdentitySHA256:
                        String(repeating: "a", count: 64),
                    support: .unavailable(
                        gap: .unsupportedLinearPCMVariant,
                        reason: reason,
                        missingCapability:
                            "this non-interleaved Linear PCM "
                                + "representation's exact passthrough"
                    )
                )
            ],
            associations: [],
            hasContainerMetadata: false,
            containerMetadataIdentitySHA256:
                String(repeating: "b", count: 64),
            support: .exact
        )
        let source = try SourceProfile(
            url: URL(
                fileURLWithPath:
                    "/tmp/source-\(UUID().uuidString).mov"
            ),
            resolution: .p1080,
            frameRate: 30,
            durationSeconds: 1,
            estimatedFrameCount: 30,
            codecHint: "avc1",
            audioTrackCount: 1,
            mediaPreservationCapability: capability
        )
        let viewModel = makeViewModel()
        viewModel.sourceProfile = source
        viewModel.targetResolution = .p2160
        viewModel.preserveAudio = true
        viewModel.state = .ready
        XCTAssertTrue(
            viewModel.acceptOutputURLSelectedByUser(
                viewModel.defaultOutputURL(
                    for: source,
                    target: .p2160
                )
            )
        )

        XCTAssertEqual(viewModel.canStartFailureReason, reason)
        XCTAssertFalse(viewModel.canStart)

        viewModel.preserveAudio = false
        XCTAssertNil(viewModel.canStartFailureReason)
        XCTAssertTrue(viewModel.canStart)
    }

    func test_canStartExplainsUnsupportedTrackAssociation()
        throws {
        let reason = "Video track 1 association auxl targets an "
            + "auxiliary track whose media representation cannot be "
            + "sample-copied exactly. Convert that auxiliary track to a "
            + "supported video representation before processing."
        let capability = SourceMediaPreservationCapability(
            verificationLevel: .exactProbe,
            tracks: [],
            associations: [
                SourceMediaTrackAssociationCapability(
                    sourceMediaType:
                        AVMediaType.video.rawValue,
                    sourceOrdinal: 0,
                    targetMediaType: "auxl",
                    targetOrdinal: nil,
                    associationType: "auxl",
                    support: .unavailable(
                        gap: .unsupportedAssociation,
                        reason: reason,
                        missingCapability:
                            "auxiliary track passthrough"
                    )
                )
            ],
            hasContainerMetadata: false,
            containerMetadataIdentitySHA256:
                String(repeating: "c", count: 64),
            support: .exact
        )
        let source = SourceProfile(
            url: URL(
                fileURLWithPath:
                    "/tmp/source-\(UUID().uuidString).mov"
            ),
            resolution: .p1080,
            frameRate: 30,
            durationSeconds: 1,
            estimatedFrameCount: 30,
            codecHint: "avc1",
            hasAudio: false,
            mediaPreservationCapability: capability
        )
        let viewModel = makeViewModel()
        viewModel.sourceProfile = source
        viewModel.targetResolution = .p2160
        viewModel.state = .ready
        XCTAssertTrue(
            viewModel.acceptOutputURLSelectedByUser(
                viewModel.defaultOutputURL(
                    for: source,
                    target: .p2160
                )
            )
        )

        XCTAssertEqual(viewModel.canStartFailureReason, reason)
        XCTAssertFalse(viewModel.canStart)
    }

    func test_outputSelectionRejectsContainersThePipelineCannotPublish() {
        let viewModel = makeViewModel()
        let sourceProfile = makeSourceProfile()
        viewModel.sourceProfile = sourceProfile
        viewModel.targetResolution = .p2160
        viewModel.state = .ready
        let unsupported = URL(
            fileURLWithPath:
                "/tmp/output-\(UUID().uuidString).avi"
        )

        XCTAssertFalse(
            viewModel.acceptOutputURLSelectedByUser(unsupported)
        )
        XCTAssertNil(viewModel.outputURL)
        XCTAssertEqual(
            viewModel.outputSelectionError,
            MediaPipelineError.unsupportedOutputContainer("avi")
                .description
        )
        XCTAssertEqual(
            viewModel.canStartFailureReason,
            MediaPipelineError.unsupportedOutputContainer("avi")
                .description
        )

        let supported = URL(
            fileURLWithPath:
                "/tmp/output-\(UUID().uuidString).mov"
        )
        XCTAssertTrue(
            viewModel.acceptOutputURLSelectedByUser(supported)
        )
        XCTAssertEqual(viewModel.outputURL, supported)
        XCTAssertTrue(viewModel.canStart)
    }

    func test_canStartExplainsCodecThatCannotPreserveSourceFormat() {
        let viewModel = makeViewModel()
        let format = MediaVideoFormat.hdrBT2020PQ(
            masteringDisplayColorVolume:
                Data(repeating: 0x42, count: 24),
            contentLightLevelInfo:
                Data([0x01, 0x02, 0x03, 0x04])
        )
        let source = SourceProfile(
            url: URL(
                fileURLWithPath:
                    "/tmp/source-\(UUID().uuidString).mov"
            ),
            resolution: .p1080,
            frameRate: 30,
            durationSeconds: 1,
            estimatedFrameCount: 30,
            codecHint: "hevc-main10",
            hasAudio: false,
            videoFormat: format
        )
        viewModel.sourceProfile = source
        viewModel.targetResolution = .p2160
        viewModel.codec = .h264
        viewModel.state = .ready
        XCTAssertTrue(
            viewModel.acceptOutputURLSelectedByUser(
                URL(
                    fileURLWithPath:
                        "/tmp/output-\(UUID().uuidString).mp4"
                )
            )
        )

        XCTAssertFalse(viewModel.canStart)
        XCTAssertEqual(
            viewModel.canStartFailureReason,
            MediaPipelineError.outputCodecCannotPreserveVideoFormat(
                codec: .h264,
                format: format
            ).description
        )

        viewModel.codec = .hevc
        XCTAssertTrue(viewModel.canStart)

        viewModel.enginePreference = .mpsLanczos
        XCTAssertEqual(
            viewModel.engineSelectionText,
            "Apple MPS Lanczos"
        )
        viewModel.enginePreference = .automatic
        viewModel.selectedMode = .auto
        XCTAssertEqual(
            viewModel.engineSelectionText,
            "ASH Multi-Engine Routing"
        )
    }

    func test_runningStateReportsProgressWithoutClaimingDuplicateSubmission() {
        let viewModel = makeViewModel()

        viewModel.state = .running

        XCTAssertEqual(
            viewModel.canStartFailureReason,
            "Upscale in progress."
        )
        XCTAssertFalse(viewModel.canStart)
    }

    func test_unavailableEngineDisablesStartAndExplainsRoadmapTransition() {
        let engine = RecordingUnavailableEngineService()
        let viewModel = MirmirViewModel(
            mediaPipeline: NoopMediaPipelineService(),
            upscalerEngine: engine,
            modelAssets: NoopModelAssetsService()
        )
        let sourceProfile = makeSourceProfile()

        XCTAssertFalse(viewModel.canStart)
        XCTAssertEqual(
            viewModel.canStartFailureReason,
            UnavailableUpscalerEngineService.roadmapTransitionReason
        )
        XCTAssertEqual(
            viewModel.engineReadinessText,
            "Selected Configuration Unavailable"
        )
        XCTAssertEqual(viewModel.engineSelectionText, "No available release mode")

        viewModel.sourceProfile = sourceProfile
        viewModel.targetResolution = .p2160
        viewModel.state = .ready
        XCTAssertTrue(viewModel.acceptOutputURLSelectedByUser(
            viewModel.defaultOutputURL(for: sourceProfile, target: .p2160)
        ))

        viewModel.startUpscale()

        XCTAssertEqual(engine.submitCount, 0)
        XCTAssertEqual(viewModel.state, .ready)
        XCTAssertEqual(
            viewModel.canStartFailureReason,
            UnavailableUpscalerEngineService.roadmapTransitionReason
        )
    }

    func test_defaultOutputFilenameUsesTargetResolution() {
        let viewModel = makeViewModel()
        let sourceProfile = makeSourceProfile(url: URL(fileURLWithPath: "/tmp/clip.mov"))

        let outputURL = viewModel.defaultOutputURL(for: sourceProfile, target: .p2160)

        XCTAssertEqual(outputURL.lastPathComponent, "clip_mirmir_2160p.mp4")
    }

    func test_defaultOutputFilenameUsesQuickTimeContainerForProRes() {
        let viewModel = makeViewModel()
        let sourceProfile = makeSourceProfile(
            url: URL(fileURLWithPath: "/tmp/clip.mov")
        )
        viewModel.codec = .proRes422HQ

        let outputURL = viewModel.defaultOutputURL(
            for: sourceProfile,
            target: .p2160
        )

        XCTAssertEqual(
            outputURL.lastPathComponent,
            "clip_mirmir_2160p.mov"
        )
    }

    func test_proResRejectsMP4DestinationBeforeSubmission() {
        let viewModel = makeViewModel()
        viewModel.sourceProfile = makeSourceProfile(
            videoFormat: .sdrBT709YUV422SixteenBit
        )
        viewModel.targetResolution = .p2160
        viewModel.codec = .proRes422HQ
        viewModel.state = .ready
        let outputURL = URL(
            fileURLWithPath:
                "/tmp/prores-output-\(UUID().uuidString).mp4"
        )

        XCTAssertFalse(
            viewModel.acceptOutputURLSelectedByUser(outputURL)
        )
        XCTAssertNil(viewModel.outputURL)
        XCTAssertEqual(
            viewModel.outputSelectionError,
            "The .mp4 output container cannot carry ProRes 422 HQ. "
                + "Select a QuickTime Movie (.mov) destination."
        )
    }

    func test_selectingProResCorrectsIncompatibleDestination() {
        let viewModel = makeViewModel()
        let source = makeSourceProfile(
            videoFormat: .sdrBT709YUV422SixteenBit
        )
        viewModel.sourceProfile = source
        viewModel.targetResolution = .p2160
        viewModel.codec = .hevc
        viewModel.state = .ready
        let outputURL = URL(
            fileURLWithPath:
                "/tmp/prores-selection-\(UUID().uuidString).mp4"
        )
        viewModel.outputURL = outputURL

        XCTAssertTrue(
            viewModel.selectCodecForPendingJob(.proRes422HQ)
        )

        XCTAssertEqual(viewModel.outputURL?.pathExtension, "mov")
        XCTAssertNil(viewModel.outputSelectionError)
        XCTAssertTrue(viewModel.canStart)
    }

    func test_linearPCMPreservationRequiresMOVAcrossDefaultSelectionAndStart()
        throws {
        let source = try makeLinearPCMSourceProfile()
        let viewModel = makeViewModel()
        viewModel.sourceProfile = source
        viewModel.targetResolution = .p2160
        viewModel.codec = .h264
        viewModel.preserveAudio = true
        viewModel.state = .ready

        XCTAssertEqual(
            viewModel.defaultOutputURL(
                for: source,
                target: .p2160
            ).pathExtension,
            "mov"
        )

        let mp4URL = URL(
            fileURLWithPath:
                "/tmp/pcm-output-\(UUID().uuidString).mp4"
        )
        XCTAssertFalse(
            viewModel.acceptOutputURLSelectedByUser(mp4URL)
        )
        XCTAssertEqual(
            viewModel.outputSelectionError,
            MediaPipelineError
                .outputContainerCannotPreserveLinearPCM(
                    pathExtension: "mp4"
                )
                .description
        )

        let movURL = mp4URL
            .deletingPathExtension()
            .appendingPathExtension("mov")
        XCTAssertTrue(
            viewModel.acceptOutputURLSelectedByUser(movURL)
        )
        XCTAssertNil(viewModel.outputSelectionError)
        XCTAssertTrue(viewModel.canStart)
    }

    func test_disablingLinearPCMPreservationRestoresMP4Default()
        throws {
        let source = try makeLinearPCMSourceProfile()
        let viewModel = makeViewModel()
        viewModel.sourceProfile = source
        viewModel.codec = .hevc
        viewModel.preserveAudio = true

        XCTAssertEqual(
            viewModel.defaultOutputURL(
                for: source,
                target: .p2160
            ).pathExtension,
            "mov"
        )
        XCTAssertTrue(
            viewModel.setPreserveAudioForPendingJob(false)
        )
        XCTAssertEqual(
            viewModel.defaultOutputURL(
                for: source,
                target: .p2160
            ).pathExtension,
            "mp4"
        )
        XCTAssertNil(
            MediaOutputContainerPolicy.validationError(
                pathExtension: "mp4",
                codec: .hevc,
                videoFormat: source.videoFormat,
                preservationCapability:
                    source.mediaPreservationCapability,
                preserveAudio: false
            )
        )
    }

    func test_alphaHEVCAndAuxiliaryAssociationsRequireMOV()
        throws {
        let standardCapability =
            SourceMediaPreservationCapability.sourceCompatible(
                audioTrackCount: 0,
                subtitleTrackCount: 0,
                metadataTrackCount: 0,
                hasContainerMetadata: false
            )
        let alphaFormat = MediaVideoFormat.sdrBT709WithAlpha(
            mode: .straight
        )
        XCTAssertNotNil(
            MediaOutputContainerPolicy.validationError(
                pathExtension: "mp4",
                codec: .hevc,
                videoFormat: alphaFormat,
                preservationCapability: standardCapability,
                preserveAudio: false
            )
        )
        XCTAssertNil(
            MediaOutputContainerPolicy.validationError(
                pathExtension: "mov",
                codec: .hevc,
                videoFormat: alphaFormat,
                preservationCapability: standardCapability,
                preserveAudio: false
            )
        )

        let associatedCapability =
            makeAuxiliaryAssociationCapability()
        XCTAssertEqual(
            MediaOutputContainerPolicy.preferredPathExtension(
                codec: .h264,
                videoFormat: .sdrBT709,
                preservationCapability: associatedCapability,
                preserveAudio: false
            ),
            "mov"
        )
        XCTAssertEqual(
            MediaOutputContainerPolicy.validationError(
                pathExtension: "mp4",
                codec: .h264,
                videoFormat: .sdrBT709,
                preservationCapability: associatedCapability,
                preserveAudio: false
            )?.description,
            MediaPipelineError
                .outputContainerCannotPreserveTrackAssociations(
                    pathExtension: "mp4"
                )
                .description
        )
    }

    func test_standardH264AndHEVCAcceptMP4AndMOV() {
        let capability =
            SourceMediaPreservationCapability.sourceCompatible(
                audioTrackCount: 0,
                subtitleTrackCount: 0,
                metadataTrackCount: 0,
                hasContainerMetadata: false
            )

        for codec in [OutputCodec.h264, .hevc] {
            for pathExtension in ["mp4", "mov"] {
                XCTAssertNil(
                    MediaOutputContainerPolicy.validationError(
                        pathExtension: pathExtension,
                        codec: codec,
                        videoFormat: .sdrBT709,
                        preservationCapability: capability,
                        preserveAudio: false
                    ),
                    "\(codec.displayName) must remain valid in "
                        + ".\(pathExtension)."
                )
            }
        }
    }

    func test_defaultOutputFilenameAvoidsExistingVideos() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("clip.mov")
        try Data("source".utf8).write(to: sourceURL)
        let viewModel = makeViewModel()
        let source = makeSourceProfile(url: sourceURL)
        let preferred = viewModel.defaultOutputURL(
            for: source,
            target: .p2160,
            in: directory
        )
        let second = directory.appendingPathComponent(
            "clip_mirmir_2160p_2.mp4"
        )
        try Data("existing".utf8).write(to: preferred)
        try Data("existing".utf8).write(to: second)

        let available = viewModel.availableDefaultOutputURL(
            for: source,
            target: .p2160,
            in: directory
        )

        XCTAssertEqual(
            available.lastPathComponent,
            "clip_mirmir_2160p_3.mp4"
        )
    }

    func test_existingOutputIsRejectedBeforeSubmission() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("source.mov")
        let outputURL = directory.appendingPathComponent("output.mp4")
        try Data("source".utf8).write(to: sourceURL)
        try Data("existing output".utf8).write(to: outputURL)
        let viewModel = makeViewModel()
        viewModel.sourceProfile = makeSourceProfile(url: sourceURL)
        viewModel.targetResolution = .p2160
        viewModel.state = .ready

        XCTAssertFalse(
            viewModel.acceptOutputURLSelectedByUser(outputURL)
        )
        XCTAssertNil(viewModel.outputURL)
        XCTAssertEqual(
            viewModel.canStartFailureReason,
            MirmirViewModel.existingOutputConflictMessage
        )
    }

    func test_sourceAndOutputMustBeDifferentFiles() {
        let source = URL(fileURLWithPath: "/tmp/source.mov")

        XCTAssertTrue(MirmirViewModel.urlsReferToSameFile(source, source))
        XCTAssertFalse(
            MirmirViewModel.urlsReferToSameFile(
                source,
                URL(fileURLWithPath: "/tmp/source_mirmir_2160p.mp4")
            )
        )
    }

    func test_fileIdentityDetectsSymlinkAndHardLinkAliases() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let source = directory.appendingPathComponent("source.mov")
        let symlink = directory.appendingPathComponent("source-symlink.mov")
        let hardLink = directory.appendingPathComponent("source-hardlink.mov")
        try Data("source".utf8).write(to: source)
        try fileManager.createSymbolicLink(at: symlink, withDestinationURL: source)
        try fileManager.linkItem(at: source, to: hardLink)

        XCTAssertTrue(MirmirViewModel.urlsReferToSameFile(source, symlink))
        XCTAssertTrue(MirmirViewModel.urlsReferToSameFile(source, hardLink))
    }

    func test_sourceCannotBeAcceptedAsOutput() {
        let sourceURL = URL(fileURLWithPath: "/tmp/source.mov")
        let viewModel = makeViewModel()
        viewModel.sourceProfile = makeSourceProfile(url: sourceURL)
        viewModel.targetResolution = .p2160
        viewModel.state = .ready

        XCTAssertFalse(viewModel.acceptOutputURLSelectedByUser(sourceURL))
        XCTAssertNil(viewModel.outputURL)
        XCTAssertEqual(
            viewModel.canStartFailureReason,
            MirmirViewModel.sourceOutputConflictMessage
        )
    }

    func test_loadingSourceRequiresExplicitOutputSelection() async {
        let viewModel = makeViewModel()

        viewModel.loadSource(url: URL(fileURLWithPath: "/tmp/source.mov"))
        for _ in 0..<100 where viewModel.state == .probing {
            await Task.yield()
        }

        XCTAssertEqual(viewModel.state, .ready)
        XCTAssertNil(viewModel.outputURL)
        XCTAssertFalse(viewModel.canStart)
        XCTAssertEqual(viewModel.canStartFailureReason, "Choose an output location.")
    }

    func test_loadingSourceSelectsAFormatPreservingCodec() async {
        let media = CountingMediaPipelineService(
            videoFormat: .sdrBT709YUV422SixteenBit
        )
        let viewModel = MirmirViewModel(
            mediaPipeline: media,
            upscalerEngine: NoopUpscalerEngineService(),
            modelAssets: NoopModelAssetsService()
        )

        viewModel.loadSource(
            url: URL(fileURLWithPath: "/tmp/prores-source.mov")
        )
        for _ in 0..<100 where viewModel.state == .probing {
            await Task.yield()
        }

        XCTAssertEqual(viewModel.state, .ready)
        XCTAssertEqual(viewModel.codec, .proRes422HQ)
        XCTAssertNil(viewModel.outputURL)
    }

    func test_newerSourceProbeCannotBeOverwrittenByOlderCompletion()
        async throws {
        let media = OutOfOrderProbeMediaPipelineService()
        let viewModel = MirmirViewModel(
            mediaPipeline: media,
            upscalerEngine: NoopUpscalerEngineService(),
            modelAssets: NoopModelAssetsService()
        )
        let firstURL = URL(fileURLWithPath: "/tmp/first.mov")
        let secondURL = URL(fileURLWithPath: "/tmp/second.mov")

        viewModel.loadSource(url: firstURL)
        for _ in 0..<200 where await media.pendingProbeCount() < 1 {
            await Task.yield()
        }
        viewModel.loadSource(url: secondURL)
        for _ in 0..<200 where await media.pendingProbeCount() < 2 {
            await Task.yield()
        }

        await media.completeProbe(
            url: secondURL,
            resolution: .p1080
        )
        for _ in 0..<200
            where viewModel.sourceProfile?.url != secondURL {
            await Task.yield()
        }
        XCTAssertEqual(viewModel.sourceProfile?.url, secondURL)
        XCTAssertEqual(viewModel.targetResolution, .p1440)
        XCTAssertEqual(viewModel.state, .ready)

        await media.completeProbe(
            url: firstURL,
            resolution: .p720
        )
        for _ in 0..<20 {
            await Task.yield()
        }

        XCTAssertEqual(viewModel.sourceProfile?.url, secondURL)
        XCTAssertEqual(viewModel.targetResolution, .p1440)
        XCTAssertEqual(viewModel.state, .ready)
    }

    func test_loadingSourceIsIgnoredWhileAJobIsRunning() async {
        let media = CountingMediaPipelineService()
        let viewModel = MirmirViewModel(
            mediaPipeline: media,
            upscalerEngine: NoopUpscalerEngineService(),
            modelAssets: NoopModelAssetsService()
        )
        viewModel.state = .running

        viewModel.loadSource(url: URL(fileURLWithPath: "/tmp/replacement.mov"))
        await Task.yield()

        XCTAssertEqual(media.probeCount, 0)
        XCTAssertEqual(viewModel.state, .running)
    }

    func test_rawCancellationKeepsWorkflowRunningUntilHandleTerminates() async throws {
        let engine = DelayedCancellationEngineService()
        let viewModel = MirmirViewModel(
            mediaPipeline: NoopMediaPipelineService(),
            upscalerEngine: engine,
            modelAssets: NoopModelAssetsService()
        )
        let source = makeSourceProfile()
        viewModel.sourceProfile = source
        viewModel.targetResolution = .p2160
        viewModel.state = .ready
        let initialOutputURL = viewModel.defaultOutputURL(
            for: source,
            target: .p2160
        )
        XCTAssertTrue(viewModel.acceptOutputURLSelectedByUser(
            initialOutputURL
        ))

        viewModel.startUpscale()
        let handle = try XCTUnwrap(engine.latestHandle)
        XCTAssertEqual(viewModel.state, .running)
        XCTAssertFalse(viewModel.jobConfigurationIsEditable)

        viewModel.cancelUpscale()
        XCTAssertTrue(handle.cancelRequested)
        XCTAssertEqual(viewModel.state, .running)
        XCTAssertFalse(viewModel.canStart)

        let replacementOutputURL = URL(
            fileURLWithPath: "/tmp/replacement-output.mp4"
        )
        XCTAssertFalse(
            viewModel.acceptOutputURLSelectedByUser(replacementOutputURL)
        )
        XCTAssertFalse(viewModel.selectModeForPendingJob(.quality))
        XCTAssertFalse(viewModel.selectCodecForPendingJob(.h264))
        XCTAssertEqual(viewModel.outputURL, initialOutputURL)
        XCTAssertEqual(viewModel.selectedMode, .deterministic)
        XCTAssertEqual(viewModel.codec, .hevc)

        handle.completeCancellation()
        for _ in 0..<100 where viewModel.state == .running {
            await Task.yield()
        }
        XCTAssertEqual(viewModel.state, .ready)
        XCTAssertTrue(viewModel.jobConfigurationIsEditable)
        XCTAssertTrue(
            viewModel.acceptOutputURLSelectedByUser(replacementOutputURL)
        )
        XCTAssertTrue(viewModel.selectModeForPendingJob(.quality))
        XCTAssertTrue(viewModel.selectCodecForPendingJob(.h264))
        XCTAssertEqual(viewModel.outputURL, replacementOutputURL)
        XCTAssertEqual(viewModel.selectedMode, .quality)
        XCTAssertEqual(viewModel.codec, .h264)
    }

    func test_completedHandleURLBecomesCanonicalOutputAndRevealIdentity()
        async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "MirmirCompletedReveal-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let selectedURL = directory.appendingPathComponent(
            "selected-output.mp4"
        )
        let completedURL = directory.appendingPathComponent(
            "completed-output.mp4"
        )
        try Data("completed".utf8).write(to: completedURL)
        let engine = CanonicalCompletionEngineService(
            completedURL: completedURL
        )
        var revealedURL: URL?
        let viewModel = MirmirViewModel(
            mediaPipeline: NoopMediaPipelineService(),
            upscalerEngine: engine,
            modelAssets: NoopModelAssetsService(),
            revealFileInFinder: { revealedURL = $0 }
        )
        let source = makeSourceProfile()
        viewModel.sourceProfile = source
        viewModel.targetResolution = .p2160
        viewModel.state = .ready
        XCTAssertTrue(
            viewModel.acceptOutputURLSelectedByUser(selectedURL)
        )

        viewModel.startUpscale()
        for _ in 0..<200 where viewModel.state != .finished(completedURL) {
            await Task.yield()
        }

        XCTAssertEqual(viewModel.state, .finished(completedURL))
        XCTAssertEqual(viewModel.outputURL, completedURL)
        XCTAssertEqual(viewModel.completedOutputURL, completedURL)

        viewModel.revealOutputInFinder()

        XCTAssertEqual(revealedURL, completedURL)
        XCTAssertNil(viewModel.completedOutputRevealError)
    }

    func test_revealCompletedOutputReportsMissingFileAndRecoversWhenRestored()
        throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "MirmirMissingCompletedReveal-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let completedURL = directory.appendingPathComponent(
            "restorable-output.mp4"
        )
        var revealedURL: URL?
        let viewModel = MirmirViewModel(
            mediaPipeline: NoopMediaPipelineService(),
            upscalerEngine: NoopUpscalerEngineService(),
            modelAssets: NoopModelAssetsService(),
            revealFileInFinder: { revealedURL = $0 }
        )
        viewModel.state = .finished(completedURL)

        viewModel.revealOutputInFinder()

        XCTAssertNil(revealedURL)
        let error = try XCTUnwrap(
            viewModel.completedOutputRevealError
        )
        XCTAssertTrue(error.contains("restorable-output.mp4"))
        XCTAssertTrue(error.contains("Restore it"))
        XCTAssertTrue(error.contains("Library"))

        try Data("restored".utf8).write(to: completedURL)
        viewModel.revealOutputInFinder()

        XCTAssertEqual(revealedURL, completedURL)
        XCTAssertNil(viewModel.completedOutputRevealError)
    }

    func test_dismissTerminalJobClearsFailedAndFinishedWorkflowState() {
        for terminalState in [
            MirmirViewModel.JobState.failed("injected failure"),
            .finished(URL(fileURLWithPath: "/tmp/finished.mp4"))
        ] {
            let viewModel = makeViewModel()
            let source = makeSourceProfile()
            viewModel.sourceProfile = source
            viewModel.outputURL = viewModel.defaultOutputURL(
                for: source,
                target: .p2160
            )
            viewModel.progress = UpscaleProgress(
                framesProcessed: 1,
                totalFrames: 2,
                throughputFPS: 1,
                etaSeconds: 1
            )
            viewModel.state = terminalState

            viewModel.dismissTerminalJob()

            XCTAssertEqual(viewModel.state, .idle)
            XCTAssertNil(viewModel.sourceProfile)
            XCTAssertNil(viewModel.outputURL)
            XCTAssertNil(viewModel.progress)
        }
    }

    func test_inputAdmissionDefersFormatSupportToMediaProbe() {
        for fileExtension in [
            "mp4", "mov", "mkv", "webm", "mxf", "unknown"
        ] {
            let url = URL(
                fileURLWithPath: "/tmp/source.\(fileExtension)"
            )
            XCTAssertTrue(
                MirmirViewModel.supportsVideoFile(url),
                fileExtension
            )
        }
        XCTAssertFalse(
            MirmirViewModel.supportsVideoFile(
                URL(string: "https://example.com/source.mp4")!
            )
        )
    }

    func test_targetPolicyPreservesQualifiedRoutesAndAdaptsOddGeometry() {
        XCTAssertEqual(
            MirmirViewModel.targets(for: .p720),
            [.p1080, .p1440, .p2160]
        )
        XCTAssertEqual(
            MirmirViewModel.targets(for: .p1080),
            [.p1440, .p2160]
        )
        XCTAssertEqual(
            MirmirViewModel.targets(
                for: VideoResolution(width: 728, height: 410)
            ),
            [
                VideoResolution(width: 1_278, height: 720),
                VideoResolution(width: 1_918, height: 1_080),
                VideoResolution(width: 2_556, height: 1_440),
                VideoResolution(width: 3_836, height: 2_160)
            ]
        )
        XCTAssertEqual(
            MirmirViewModel.targets(
                for: VideoResolution(width: 854, height: 480)
            ),
            [
                VideoResolution(width: 1_282, height: 720),
                VideoResolution(width: 1_922, height: 1_080),
                VideoResolution(width: 2_562, height: 1_440),
                VideoResolution(width: 3_844, height: 2_160)
            ]
        )
        XCTAssertEqual(
            MirmirViewModel.targets(for: .p1440),
            [.p2160]
        )
        XCTAssertTrue(
            MirmirViewModel.targets(for: .p2160).isEmpty
        )
    }

    func test_targetAndAudioControlsAreAppliedToSubmittedJob() throws {
        let engine = RecordingRejectingEngineService()
        let viewModel = MirmirViewModel(
            mediaPipeline: NoopMediaPipelineService(),
            upscalerEngine: engine,
            modelAssets: NoopModelAssetsService()
        )
        let source = SourceProfile(
            url: URL(fileURLWithPath: "/tmp/source-with-audio.mov"),
            resolution: .p720,
            frameRate: 30,
            durationSeconds: 1,
            estimatedFrameCount: 30,
            codecHint: nil,
            hasAudio: true
        )
        viewModel.sourceProfile = source
        viewModel.targetResolution = .p1080
        viewModel.preserveAudio = true
        viewModel.state = .ready
        XCTAssertTrue(
            viewModel.acceptOutputURLSelectedByUser(
                viewModel.defaultOutputURL(
                    for: source,
                    target: .p1080
                )
            )
        )

        XCTAssertTrue(viewModel.selectTargetForPendingJob(.p2160))
        XCTAssertEqual(
            viewModel.outputURL?.lastPathComponent,
            "source-with-audio_mirmir_2160p.mp4"
        )
        XCTAssertTrue(viewModel.setPreserveAudioForPendingJob(false))
        viewModel.startUpscale()

        let submitted = try XCTUnwrap(engine.submittedJob)
        XCTAssertEqual(submitted.targetResolution, .p2160)
        XCTAssertFalse(submitted.preserveAudio)
    }

    func test_nonFileSourceReportsVisibleError() {
        let viewModel = makeViewModel()

        viewModel.loadSource(
            url: URL(string: "https://example.com/source.mp4")!
        )

        XCTAssertEqual(
            viewModel.state,
            .failed(MirmirViewModel.unsupportedFileMessage)
        )
    }

    func test_probeFailureIsPersistedInInjectedDiagnosticStore() async throws {
        let store = MirmirDiagnosticStore(inMemoryWith: .production)
        let privateSourceURL = URL(
            fileURLWithPath:
                "/Users/alice/Secret Client/"
                + "token-sk_test_SENTINEL/source.mov"
        )
        let viewModel = MirmirViewModel(
            mediaPipeline: FailingProbeMediaPipelineService(),
            upscalerEngine: NoopUpscalerEngineService(),
            modelAssets: NoopModelAssetsService(),
            diagnostics: store
        )

        viewModel.loadSource(url: privateSourceURL)

        var failureRecord: MirmirDiagnosticRecord?
        for _ in 0..<200 where failureRecord == nil {
            let snapshot = try await store.snapshot()
            failureRecord = snapshot.records.first {
                $0.event.code.rawValue == "source_probe_failed"
            }
            if failureRecord == nil {
                try await Task.sleep(for: .milliseconds(5))
            }
        }

        let persistedFailure = try XCTUnwrap(failureRecord)
        let fields = Dictionary(
            uniqueKeysWithValues: persistedFailure.event.fields.map {
                ($0.key.rawValue, $0.value.displayValue)
            }
        )
        XCTAssertEqual(persistedFailure.event.severity, .error)
        XCTAssertEqual(
            persistedFailure.event.operation.rawValue,
            "source_probe"
        )
        XCTAssertNotNil(persistedFailure.event.error)
        XCTAssertTrue(
            persistedFailure.event.error?.frames.contains {
                $0.domain == "NSPOSIXErrorDomain" && $0.code == 5
            } == true
        )
        XCTAssertEqual(fields["failure_category"], "reader_creation_failed")
        XCTAssertEqual(
            fields["source_video"],
            "source_video:"
                + (persistedFailure.event.correlationID?.rawValue ?? "")
                + ":mov:user_selected"
        )
        guard case .failed = viewModel.state else {
            return XCTFail("Expected the ViewModel to expose probe failure.")
        }
        let json = try await store.exportJSON()
        let jsonText = try XCTUnwrap(String(data: json, encoding: .utf8))
        XCTAssertFalse(jsonText.contains("alice"))
        XCTAssertFalse(jsonText.contains("Secret Client"))
        XCTAssertFalse(jsonText.contains("token-sk_test_SENTINEL"))
        XCTAssertFalse(jsonText.contains("/Users/"))
    }

    func test_mainWorkflowSourceDoesNotExposeArchitectureTerms() throws {
        let mainWorkflowSource = try mainWorkspaceSource()
        let forbiddenTerms = ["Forsetti", "Host Template", "Pattern B", "Model Assets"]

        for term in forbiddenTerms {
            XCTAssertFalse(containsWholeTerm(term, in: mainWorkflowSource), "\(term) leaked into main workflow UI")
        }
    }

    func test_settingsAndAboutDescribeShippingTechnicalBehavior() throws {
        let source = try settingsViewSource()

        XCTAssertTrue(source.contains("Technical Details"))
        XCTAssertTrue(
            MirmirAboutView.routingTechnicalSummary
                .contains("ASH content and resource")
        )
        XCTAssertTrue(
            MirmirAboutView.routingTechnicalSummary
                .contains("MPS Lanczos")
        )
        XCTAssertTrue(
            MirmirAboutView.productSummary.contains("10-bit SDR")
        )
        XCTAssertTrue(
            MirmirAboutView.productSummary.contains("closed captions")
        )
        XCTAssertTrue(
            MirmirAboutView.productSummary.contains("Linear PCM")
        )
        XCTAssertTrue(
            MirmirAboutView.productSummary.contains("Apple Lossless")
        )
        XCTAssertTrue(
            MirmirAboutView.productSummary.contains("atomic publication")
        )
        XCTAssertTrue(source.contains("Acknowledgements & Licenses"))
        XCTAssertTrue(
            MirmirAboutView.ashAcknowledgement
                .contains("ASH-Model-LICENSE.txt")
        )
        XCTAssertTrue(
            source.contains(
                ".accessibilityAddTraits(.isHeader)"
            )
        )
        XCTAssertTrue(
            source.contains(
                "DisclosureGroup(\"Bundled ASH Model License\")"
            )
        )
        XCTAssertTrue(
            MirmirAboutView.bundledASHLicenseText
                .hasPrefix("ASH Model License")
        )
        XCTAssertEqual(
            MirmirAboutView.ashSourceRevision,
            "8782886a8cca9fa63f7d44b529add6eac80a50f8"
        )
        XCTAssertEqual(
            MirmirAboutView.ashCitation,
            "Daley, J. (2026). \"Adinkra-Stabilized Hypercube Model "
                + "(ASH Model): Canonical Computational Specification and "
                + "Reference Implementation,\" version 1.1.0."
        )
        XCTAssertEqual(
            MirmirAboutView.ashLicenseURL?.absoluteString,
            "https://github.com/flynn33/ASH-Model/blob/"
                + "8782886a8cca9fa63f7d44b529add6eac80a50f8/LICENSE"
        )
        XCTAssertEqual(
            MirmirAboutView.ashSourceURL?.absoluteString,
            "https://github.com/flynn33/ASH-Model/tree/"
                + "8782886a8cca9fa63f7d44b529add6eac80a50f8"
        )
        XCTAssertFalse(source.contains("reference and research"))
        XCTAssertFalse(source.contains("Forsetti"))
    }

    func test_bothSettingsSurfacesEditPersistedDefaultsWithoutJobGate()
        throws {
        let nativeSettings = try settingsViewSource()
        let workflowSource = try workflowViewSource()
        let workspaceSource = try sourceText(
            for: [
                "Mirmir/Modules/UI/Views/"
                    + "MirmirWorkspaceScreens.swift"
            ]
        )
        let workspaceSettings = try XCTUnwrap(
            workspaceSource
                .components(
                    separatedBy: "struct MirmirSettingsScreen: View"
                )
                .last?
                .components(
                    separatedBy: "struct MirmirAboutWorkspaceScreen"
                )
                .first
        )
        let requiredBindings = [
            "selectDefaultMode(",
            "selectDefaultOutputCodec(",
            "selectDefaultEngine(",
            "selectDefaultStrategy(",
            "setDefaultTemporalConsistency(",
            "selectDefaultEdgeFidelity(",
            "selectDefaultDetailRecovery("
        ]

        for binding in requiredBindings {
            XCTAssertTrue(
                nativeSettings.contains(binding),
                "Native Settings is missing \(binding)"
            )
            XCTAssertTrue(
                workspaceSettings.contains(binding),
                "Workspace Settings is missing \(binding)"
            )
        }
        XCTAssertTrue(nativeSettings.contains("selectAppearanceMode("))
        XCTAssertTrue(
            workspaceSettings.contains("selection: $appearanceMode")
        )
        XCTAssertTrue(
            workflowSource.contains(
                "set: { viewModel.selectAppearanceMode($0) }"
            )
        )
        XCTAssertFalse(
            nativeSettings.contains("$viewModel.selectedMode")
        )
        XCTAssertFalse(
            nativeSettings.contains("$viewModel.codec")
        )
        XCTAssertFalse(
            workspaceSettings.contains(
                ".disabled(!viewModel.jobConfigurationIsEditable)"
            )
        )
    }

    func test_liveSettingsExposePersistentDiagnosticViewerAndBothExports() throws {
        let appSource = try sourceText(for: ["Mirmir/App/MirmirApp.swift"])
        let settingsSource = try settingsViewSource()
        let workspaceSource = try sourceText(
            for: ["Mirmir/Modules/UI/Views/MirmirWorkspaceScreens.swift"]
        )

        XCTAssertTrue(appSource.contains("Settings {"))
        XCTAssertTrue(
            appSource.contains("MirmirNativeSettingsRoot(")
        )
        XCTAssertTrue(
            appSource.contains(
                "MirmirSettingsView(viewModel: bootstrap.viewModel)"
            )
        )
        XCTAssertTrue(
            settingsSource.contains(
                "struct MirmirDiagnosticSettingsView: View"
            )
        )
        XCTAssertTrue(
            settingsSource.contains(
                "MirmirDiagnosticSettingsView("
            )
        )
        XCTAssertTrue(
            settingsSource.contains(
                "store: viewModel.diagnosticStore"
            )
        )
        XCTAssertTrue(
            settingsSource.contains(
                ".tabItem { Text(\"Diagnostics\") }"
            )
        )
        XCTAssertTrue(settingsSource.contains("try await store.snapshot()"))
        XCTAssertTrue(settingsSource.contains("try await store.exportJSON()"))
        XCTAssertTrue(
            settingsSource.contains("try await store.exportMarkdown()")
        )
        XCTAssertTrue(settingsSource.contains("Button(\"JSON…\")"))
        XCTAssertTrue(settingsSource.contains("Button(\"Markdown…\")"))
        XCTAssertTrue(settingsSource.contains(".fileExporter("))
        XCTAssertTrue(workspaceSource.contains("SettingsLink {"))
        XCTAssertTrue(
            workspaceSource.contains("Open Diagnostic Log Settings…")
        )
    }

    func test_failedCompositionSettingsExposeDiagnosticsWithoutFailureLoop()
        throws {
        let appSource = try sourceText(
            for: ["Mirmir/App/MirmirApp.swift"]
        )
        let startupFailureSource = try sourceText(
            for: ["Mirmir/App/MirmirProductionRootView.swift"]
        )
        let settingsSource = try settingsViewSource()
        let nativeSettingsRoot = try XCTUnwrap(
            appSource
                .components(
                    separatedBy: "private struct MirmirNativeSettingsRoot"
                )
                .last
        )

        XCTAssertTrue(startupFailureSource.contains("SettingsLink {"))
        XCTAssertTrue(
            startupFailureSource.contains(
                "Open Diagnostic Log Settings"
            )
        )
        XCTAssertTrue(nativeSettingsRoot.contains("case .failed(let reason):"))
        XCTAssertTrue(
            nativeSettingsRoot.contains(
                "MirmirStartupDiagnosticSettingsView("
            )
        )
        XCTAssertTrue(
            nativeSettingsRoot.contains(
                "store: composition.diagnosticStore"
            )
        )
        XCTAssertTrue(
            nativeSettingsRoot.contains(
                "reason: reason"
            )
        )
        XCTAssertFalse(
            nativeSettingsRoot.contains("MirmirStartupFailureView(")
        )
        XCTAssertTrue(
            settingsSource.contains(
                "Diagnostic logging remains available."
            )
        )
        XCTAssertTrue(
            settingsSource.contains(
                "MirmirDiagnosticSettingsView(store: store)"
            )
        )
        XCTAssertTrue(
            settingsSource.contains(
                "Text(reason)"
            )
        )
    }

    func test_diagnosticSettingsSurfacesPersistenceHealthAndRetainsExports()
        throws {
        let settingsSource = try settingsViewSource()
        let requiredSourceFragments = [
            "persistenceHealth = await store.persistenceHealth()",
            "persistenceHealth.failedOperationCount > 0",
            #"\(persistenceHealth.failedOperationCount) failed "#,
            #"\(persistenceHealth.lastFailedOperation ?? "unknown")."#,
            "try await store.exportJSON()",
            "try await store.exportMarkdown()",
            "Button(\"JSON…\")",
            "Button(\"Markdown…\")",
            ".fileExporter("
        ]

        for fragment in requiredSourceFragments {
            XCTAssertTrue(
                settingsSource.contains(fragment),
                "Missing Diagnostic Settings source wiring: \(fragment)"
            )
        }
    }

    func test_mainWorkflowContainsDetailedWorkspaceShell() throws {
        let source = try detailedWorkspaceSource()
        let requiredTerms = [
            "Dashboard",
            "Library",
            "Upscale",
            "Queue",
            "Modes",
            "Settings",
            "Before",
            "After",
            "Choose Source",
            "Start Upscale",
            "Source",
            "Output",
            "Processing State",
            "Readiness",
            "Frames"
        ]

        for term in requiredTerms {
            XCTAssertTrue(source.contains(term), "\(term) is missing from the detailed workspace shell")
        }
    }

    func test_mainWorkflowContainsRequiredInspectorControls() throws {
        let source = try detailedWorkspaceSource()
        let requiredControls = [
            "engineSelectionText",
            "Strategy",
            "Mode",
            "Temporal Consistency",
            "Edge Fidelity",
            "Detail Recovery",
            "Output Format",
            "Destination"
        ]

        for control in requiredControls {
            XCTAssertTrue(source.contains(control), "\(control) is missing from the upscale inspector")
        }
        XCTAssertTrue(
            source.contains(
                "viewModel.handleSourceDropProviderResult("
            ),
            "The shipping source drop target must surface provider results."
        )
    }

    func test_sampledPreviewUsesProductionPairOnOneCommonCanvas() throws {
        let source = try sourceText(
            for: [
                "Mirmir/Modules/UI/Views/"
                    + "MirmirUpscaleWorkspaceView.swift"
            ]
        )
        let requiredWiring = [
            "MirmirPreviewRaster(image: frame.processed)",
            "MirmirPreviewRaster(image: frame.source)",
            ".mask(alignment: .leading)",
            ".frame(width: size.width, height: size.height)",
            "Live sampled preview",
            "Both sides show the same sampled production frame.",
            "Sampled frames update during processing; continuous playback follows completion.",
            ".accessibilityHidden(true)",
            "Upscale failed: \\(reason)"
        ]

        for fragment in requiredWiring {
            XCTAssertTrue(
                source.contains(fragment),
                "Missing truthful sampled-preview wiring: \(fragment)"
            )
        }
        XCTAssertFalse(
            source.contains(
                "Continuous playback and scrubbing are not included."
            )
        )
        XCTAssertFalse(source.contains("previewHalf("))
        XCTAssertFalse(
            source.contains("Live frame playback is not available.")
        )
        XCTAssertFalse(
            source.contains("The current source cannot be prepared.")
        )
        XCTAssertFalse(
            source.contains(
                ".accessibilityLabel(\"Before after split handle\")"
            )
        )
    }

    func test_finishedComparisonUsesOnlyVerifiedCompletedOutput()
        throws {
        let workspaceSource = try sourceText(
            for: [
                "Mirmir/Modules/UI/Views/"
                    + "MirmirUpscaleWorkspaceView.swift"
            ]
        )
        let playbackSource = try sourceText(
            for: [
                "Mirmir/Modules/UI/"
                    + "MirmirSynchronizedPlaybackController.swift",
                "Mirmir/Modules/UI/"
                    + "MirmirCompletedPlaybackTypes.swift",
                "Mirmir/Modules/UI/Views/"
                    + "MirmirCompletedComparisonPlaybackView.swift"
            ]
        )
        let requiredWorkspaceWiring = [
            "let completedOutputURL =",
            "viewModel.completedOutputURL",
            "MirmirCompletedComparisonPlaybackView(",
            "showLibrary: showLibrary",
            "Slider(value: $splitPosition, in: 0.2...0.8)",
            "Play, pause, or scrub the verified output in sync with the source.",
            "Both videos stay synchronized while you adjust the split."
        ]
        let requiredPlaybackWiring = [
            "let sourcePlayer = AVPlayer()",
            "let outputPlayer = AVPlayer()",
            "sourcePlayer.isMuted = true",
            "setRate(1, time: time, atHostTime: hostTime)",
            "addPeriodicTimeObserver(",
            "addBoundaryTimeObserver(",
            "sourceURL: sourceURL",
            "completedOutputURL: completedOutputURL",
            "Slider(",
            "proxy.size.width * splitPosition",
            "Retry Playback",
            "Open Library",
            "recoveryGuidance",
            "stopAccessingSecurityScopedResource()",
            "playerView.controlsStyle = .none"
        ]

        for fragment in requiredWorkspaceWiring {
            XCTAssertTrue(
                workspaceSource.contains(fragment),
                "Missing completed comparison wiring: \(fragment)"
            )
        }
        for fragment in requiredPlaybackWiring {
            XCTAssertTrue(
                playbackSource.contains(fragment),
                "Missing synchronized playback wiring: \(fragment)"
            )
        }
    }

    func test_previewTimestampFloorsWithoutSyntheticFrameComponent() {
        XCTAssertEqual(
            MirmirPreviewPresentation.timestamp(seconds: 0),
            "00:00:00"
        )
        XCTAssertEqual(
            MirmirPreviewPresentation.timestamp(seconds: 59.999),
            "00:00:59"
        )
        XCTAssertEqual(
            MirmirPreviewPresentation.timestamp(seconds: 3_661.999),
            "01:01:01"
        )
        XCTAssertEqual(
            MirmirPreviewPresentation.timestamp(seconds: -1),
            "00:00:00"
        )
        XCTAssertEqual(
            MirmirPreviewPresentation.timestamp(seconds: .nan),
            "00:00:00"
        )
    }

    func test_lastPreviewPairSurvivesTerminalFailureAndExposesReason()
        async throws {
        let preview = try makePreviewFrame()
        let engine = PreviewFailingEngineService(preview: preview)
        let viewModel = MirmirViewModel(
            mediaPipeline: NoopMediaPipelineService(),
            upscalerEngine: engine,
            modelAssets: NoopModelAssetsService()
        )
        let source = makeSourceProfile()
        viewModel.sourceProfile = source
        viewModel.targetResolution = .p2160
        viewModel.state = .ready
        XCTAssertTrue(
            viewModel.acceptOutputURLSelectedByUser(
                viewModel.defaultOutputURL(for: source, target: .p2160)
            )
        )

        viewModel.startUpscale()

        for _ in 0..<200 {
            if case .failed = viewModel.state,
               viewModel.latestPreviewFrame != nil {
                break
            }
            await Task.yield()
        }

        let retained = try XCTUnwrap(viewModel.latestPreviewFrame)
        XCTAssertEqual(retained, preview)
        guard case .failed(let reason) = viewModel.state else {
            return XCTFail("Expected the injected terminal failure.")
        }
        XCTAssertEqual(
            reason,
            "Upscale strategy failed: writer finalization rejected the output"
        )
        XCTAssertEqual(
            MirmirPreviewPresentation.message(for: viewModel.state),
            "Upscale failed: \(reason)"
        )

        viewModel.upscaleAnotherVideo()
        XCTAssertNil(viewModel.latestPreviewFrame)
    }

    func test_retryRejectionClearsPreviewFromPriorAttempt()
        async throws {
        let preview = try makePreviewFrame()
        let engine = PreviewFailingEngineService(preview: preview)
        let viewModel = MirmirViewModel(
            mediaPipeline: NoopMediaPipelineService(),
            upscalerEngine: engine,
            modelAssets: NoopModelAssetsService()
        )
        let source = makeSourceProfile()
        viewModel.sourceProfile = source
        viewModel.targetResolution = .p2160
        viewModel.state = .ready
        XCTAssertTrue(
            viewModel.acceptOutputURLSelectedByUser(
                viewModel.defaultOutputURL(for: source, target: .p2160)
            )
        )

        viewModel.startUpscale()
        for _ in 0..<200 {
            if case .failed = viewModel.state,
               viewModel.latestPreviewFrame != nil {
                break
            }
            await Task.yield()
        }
        XCTAssertEqual(viewModel.latestPreviewFrame, preview)

        viewModel.retryFailedUpscale()

        XCTAssertNil(viewModel.latestPreviewFrame)
        XCTAssertEqual(
            viewModel.state,
            .failed("An upscale job is already running.")
        )
    }

    func test_queueAndRecoveryControlsAreWiredToFunctionalActions()
        throws {
        let source = try detailedWorkspaceSource()
        let requiredWiring = [
            "viewModel.discardRecoverableJob(",
            "viewModel.discardAllRecoverableJobs()",
            "viewModel.retryFailedUpscale()",
            "viewModel.dismissTerminalJob()",
            "if viewModel.recoveryRequiresReauthorization(",
            "viewModel.retrySameSettingsFailureReason",
            "viewModel.retryWithCurrentSettingsFailureReason",
            "viewModel.retryCorrectiveActionText",
            "viewModel.recoverableJobResumeFailureReason(",
            "viewModel.workHistoryReprocessFailureReason(",
            "viewModel.workHistoryLocationStatusText(",
            "viewModel.workHistoryRevealFailureReason(",
            ".disabled(revealFailureReason != nil)",
            "viewModel.completedOutputRevealError",
            "confirmationDialog(",
            "cachedFrameCount",
            "Discard All Interrupted"
        ]

        for fragment in requiredWiring {
            XCTAssertTrue(
                source.contains(fragment),
                "Missing queue/recovery wiring: \(fragment)"
            )
        }
        XCTAssertFalse(source.contains("Button(\"Clear Completed\") {}"))
        XCTAssertFalse(source.contains("Button(\"Retry\") {}"))
    }

    func test_themeTokensAreCentralizedForDetailedSpec() throws {
        let source = try themeTokenSource()
        let requiredTokens = [
            "Midnight Nordic",
            "Arctic Indigo",
            "background",
            "surfaceElevated",
            "surfaceInset",
            "borderSubtle",
            "accentPrimary",
            "viewerOverlay",
            "focusRing",
            "space4",
            "radiusLarge"
        ]

        for token in requiredTokens {
            XCTAssertTrue(source.contains(token), "\(token) is missing from the Mirmir theme token system")
        }
    }

    private func makeViewModel() -> MirmirViewModel {
        MirmirViewModel(
            mediaPipeline: NoopMediaPipelineService(),
            upscalerEngine: NoopUpscalerEngineService(),
            modelAssets: NoopModelAssetsService()
        )
    }

    private func makeSourceProfile(
        url: URL = URL(fileURLWithPath: "/tmp/source.mov"),
        videoFormat: MediaVideoFormat = .sdrBT709
    ) -> SourceProfile {
        SourceProfile(
            url: url,
            resolution: .p1080,
            frameRate: 30,
            durationSeconds: 1,
            estimatedFrameCount: 30,
            codecHint: nil,
            hasAudio: false,
            videoFormat: videoFormat
        )
    }

    private func makeLinearPCMSourceProfile() throws -> SourceProfile {
        let identity = String(repeating: "d", count: 64)
        let capability = SourceMediaPreservationCapability(
            verificationLevel: .exactProbe,
            tracks: [
                SourceMediaTrackCapability(
                    mediaType: AVMediaType.audio.rawValue,
                    ordinal: 0,
                    formatSubtypes: ["lpcm"],
                    isEnabled: true,
                    languageCode: nil,
                    extendedLanguageTag: nil,
                    sampleRate: 48_000,
                    channelCount: 2,
                    compressedAudioIdentitySHA256: nil,
                    linearPCMAudioIdentitySHA256: identity,
                    exactTrackIdentitySHA256: identity,
                    support: .exact
                )
            ],
            associations: [],
            hasContainerMetadata: false,
            containerMetadataIdentitySHA256: nil,
            support: .exact
        )
        return try SourceProfile(
            url: URL(
                fileURLWithPath:
                    "/tmp/pcm-source-\(UUID().uuidString).mov"
            ),
            resolution: .p1080,
            frameRate: 30,
            durationSeconds: 1,
            estimatedFrameCount: 30,
            codecHint: "avc1",
            audioTrackCount: 1,
            mediaPreservationCapability: capability
        )
    }

    private func makeAuxiliaryAssociationCapability()
        -> SourceMediaPreservationCapability {
        SourceMediaPreservationCapability(
            verificationLevel: .exactProbe,
            tracks: [],
            associations: [
                SourceMediaTrackAssociationCapability(
                    sourceMediaType:
                        AVMediaType.video.rawValue,
                    sourceOrdinal: 0,
                    targetMediaType:
                        AVMediaType.video.rawValue,
                    targetOrdinal: 1,
                    associationType: "auxl",
                    support: .exact
                )
            ],
            hasContainerMetadata: false,
            containerMetadataIdentitySHA256: nil,
            support: .exact
        )
    }

    private func makePreviewFrame() throws -> UpscalePreviewFrame {
        let source = try XCTUnwrap(
            UpscalePreviewImage(
                width: 1,
                height: 1,
                rgba8: Data([16, 16, 16, 255])
            )
        )
        let processed = try XCTUnwrap(
            UpscalePreviewImage(
                width: 1,
                height: 1,
                rgba8: Data([224, 224, 224, 255])
            )
        )
        return try XCTUnwrap(
            UpscalePreviewFrame(
                frameIndex: 17,
                presentationSeconds: 0.5,
                source: source,
                processed: processed
            )
        )
    }

    private func workflowViewSource() throws -> String {
        let url = repoRootURL().appendingPathComponent("Mirmir/Modules/UI/Views/MirmirWorkflowViews.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func mainWorkspaceSource() throws -> String {
        try sourceText(for: [
            "Mirmir/Modules/UI/Views/MirmirWorkflowViews.swift",
            "Mirmir/Modules/UI/Views/MirmirUpscaleWorkspaceView.swift",
            "Mirmir/Modules/UI/Views/MirmirStatusStripView.swift",
            "Mirmir/Modules/UI/Views/MirmirWorkspaceComponents.swift"
        ])
    }

    private func detailedWorkspaceSource() throws -> String {
        try sourceText(for: [
            "Mirmir/Modules/UI/Views/MirmirWorkflowViews.swift",
            "Mirmir/Modules/UI/Views/MirmirUpscaleWorkspaceView.swift",
            "Mirmir/Modules/UI/Views/MirmirStatusStripView.swift",
            "Mirmir/Modules/UI/Views/MirmirWorkspaceComponents.swift",
            "Mirmir/Modules/UI/Views/MirmirWorkspaceScreens.swift",
            "Mirmir/Modules/UI/Views/R13UpscaleActionPanel.swift"
        ])
    }

    private func settingsViewSource() throws -> String {
        let url = repoRootURL().appendingPathComponent("Mirmir/Modules/UI/Views/MirmirSettingsViews.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func themeTokenSource() throws -> String {
        let url = repoRootURL().appendingPathComponent("Mirmir/Modules/UI/Theme/MirmirTheme.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func sourceText(for paths: [String]) throws -> String {
        try paths.map { path in
            let url = repoRootURL().appendingPathComponent(path)
            return try String(contentsOf: url, encoding: .utf8)
        }
        .joined(separator: "\n")
    }

    private func containsWholeTerm(_ term: String, in source: String) -> Bool {
        let escapedTerm = NSRegularExpression.escapedPattern(for: term)
        let pattern = #"(?i)(?<![A-Za-z0-9])"# + escapedTerm + #"(?![A-Za-z0-9])"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            XCTFail("Invalid scan expression for \(term)")
            return true
        }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return expression.firstMatch(in: source, range: range) != nil
    }

    private func repoRootURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private final class CountingMediaPipelineService: MediaPipelineService, @unchecked Sendable {
    private let count = NSLock()
    private let videoFormat: MediaVideoFormat
    private var storedProbeCount = 0

    init(videoFormat: MediaVideoFormat = .sdrBT709) {
        self.videoFormat = videoFormat
    }

    var probeCount: Int {
        count.withLock { storedProbeCount }
    }

    func probe(url: URL) async throws -> SourceProfile {
        count.withLock { storedProbeCount += 1 }
        return SourceProfile(
            url: url,
            resolution: .p1080,
            frameRate: 30,
            durationSeconds: 1,
            estimatedFrameCount: 30,
            codecHint: "test",
            hasAudio: false,
            videoFormat: videoFormat
        )
    }

    func beginSession(source: SourceProfile, output: OutputProfile) async throws -> MediaSession {
        let pool = try PixelBufferBridge.makePool(width: 16, height: 16)
        return StubMediaSession(
            sourceProfile: source,
            outputProfile: output,
            outputPixelBufferPool: pool
        )
    }

    func start() {}
    func stop() {}
}

private actor OutOfOrderProbeMediaPipelineService:
    MediaPipelineService {
    private var continuations:
        [URL: CheckedContinuation<SourceProfile, any Error>] = [:]

    func probe(url: URL) async throws -> SourceProfile {
        try await withCheckedThrowingContinuation { continuation in
            continuations[url] = continuation
        }
    }

    func pendingProbeCount() -> Int {
        continuations.count
    }

    func completeProbe(
        url: URL,
        resolution: VideoResolution
    ) {
        guard let continuation = continuations.removeValue(forKey: url)
        else {
            return
        }
        continuation.resume(
            returning: SourceProfile(
                url: url,
                resolution: resolution,
                frameRate: 30,
                durationSeconds: 1,
                estimatedFrameCount: 30,
                codecHint: "test",
                hasAudio: false
            )
        )
    }

    func beginSession(
        source _: SourceProfile,
        output _: OutputProfile
    ) async throws -> MediaSession {
        throw MediaPipelineError.readerStartFailed
    }

    nonisolated func start() {}
    nonisolated func stop() {}
}

private final class FailingProbeMediaPipelineService:
    MediaPipelineService,
    @unchecked Sendable {
    func probe(url: URL) async throws -> SourceProfile {
        let underlying = NSError(
            domain: "NSPOSIXErrorDomain",
            code: 5,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Private source failure at \(url.path)"
            ]
        )
        throw MediaPipelineError.readerCreationFailed(url, underlying)
    }

    func beginSession(
        source: SourceProfile,
        output _: OutputProfile
    ) async throws -> MediaSession {
        throw MediaPipelineError.readerCreationFailed(source.url, nil)
    }

    func start() {}
    func stop() {}
}

private final class RecordingUnavailableEngineService: UpscalerEngineService, @unchecked Sendable {
    let availability: UpscalerEngineAvailability = .unavailable(
        reason: UnavailableUpscalerEngineService.roadmapTransitionReason
    )

    private let count = NSLock()
    private var storedSubmitCount = 0

    var submitCount: Int {
        count.withLock { storedSubmitCount }
    }

    func submit(_: UpscaleJob) throws -> UpscalerJobHandle {
        count.withLock { storedSubmitCount += 1 }
        throw UpscalerEngineError.backendUnavailable(
            reason: UnavailableUpscalerEngineService.roadmapTransitionReason
        )
    }

    func start() {}
    func stop() {}
}

private final class RecordingRejectingEngineService:
    UpscalerEngineService,
    @unchecked Sendable {
    let availability: UpscalerEngineAvailability = .available

    private let lock = NSLock()
    private var storedSubmittedJob: UpscaleJob?

    var submittedJob: UpscaleJob? {
        lock.withLock { storedSubmittedJob }
    }

    func submit(_ job: UpscaleJob) throws -> UpscalerJobHandle {
        lock.withLock { storedSubmittedJob = job }
        throw UpscalerEngineError.strategyFailed("injected rejection")
    }

    func start() {}
    func stop() {}
}

private final class DelayedCancellationEngineService: UpscalerEngineService, @unchecked Sendable {
    let availability: UpscalerEngineAvailability = .available

    private let handleLock = NSLock()
    private var storedHandle: DelayedCancellationJobHandle?

    var latestHandle: DelayedCancellationJobHandle? {
        handleLock.withLock { storedHandle }
    }

    func submit(_: UpscaleJob) throws -> UpscalerJobHandle {
        let handle = DelayedCancellationJobHandle()
        handleLock.withLock { storedHandle = handle }
        return handle
    }

    func start() {}
    func stop() {}
}

private final class DelayedCancellationJobHandle: UpscalerJobHandle, @unchecked Sendable {
    private struct State {
        var cancelRequested = false
        var completed = false
        var waiter: CheckedContinuation<URL, Error>?
    }

    let progressStream: AsyncStream<UpscaleProgress>
    private let state = NSLock()
    private var storedState = State()

    init() {
        self.progressStream = AsyncStream { $0.finish() }
    }

    var cancelRequested: Bool {
        state.withLock { storedState.cancelRequested }
    }

    func cancel() {
        state.withLock { storedState.cancelRequested = true }
    }

    func waitForCompletion() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let completeNow = state.withLock {
                if storedState.completed {
                    return true
                }
                storedState.waiter = continuation
                return false
            }
            if completeNow {
                continuation.resume(throwing: CancellationError())
            }
        }
    }

    func completeCancellation() {
        let waiter = state.withLock { () -> CheckedContinuation<URL, Error>? in
            storedState.completed = true
            defer { storedState.waiter = nil }
            return storedState.waiter
        }
        waiter?.resume(throwing: CancellationError())
    }
}

private final class CanonicalCompletionEngineService:
    UpscalerEngineService,
    @unchecked Sendable {
    let availability: UpscalerEngineAvailability = .available
    private let completedURL: URL

    init(completedURL: URL) {
        self.completedURL = completedURL
    }

    func submit(_: UpscaleJob) throws -> UpscalerJobHandle {
        CanonicalCompletionJobHandle(completedURL: completedURL)
    }

    func start() {}
    func stop() {}
}

private final class CanonicalCompletionJobHandle:
    UpscalerJobHandle,
    @unchecked Sendable {
    let progressStream: AsyncStream<UpscaleProgress>
    private let completedURL: URL

    init(completedURL: URL) {
        self.completedURL = completedURL
        self.progressStream = AsyncStream { $0.finish() }
    }

    func cancel() {}

    func waitForCompletion() async throws -> URL {
        await Task.yield()
        return completedURL
    }
}

private final class PreviewFailingEngineService:
    UpscalerEngineService,
    @unchecked Sendable {
    let availability: UpscalerEngineAvailability = .available
    private let preview: UpscalePreviewFrame
    private let lock = NSLock()
    private var submissionCount = 0

    init(preview: UpscalePreviewFrame) {
        self.preview = preview
    }

    func submit(_: UpscaleJob) throws -> UpscalerJobHandle {
        let isRetry = lock.withLock {
            submissionCount += 1
            return submissionCount > 1
        }
        if isRetry {
            throw UpscalerEngineError.jobAlreadyRunning
        }
        return PreviewFailingJobHandle(preview: preview)
    }

    func start() {}
    func stop() {}
}

private final class PreviewFailingJobHandle:
    UpscalerJobHandle,
    @unchecked Sendable {
    let progressStream: AsyncStream<UpscaleProgress>
    let previewStream: AsyncStream<UpscalePreviewFrame>

    init(preview: UpscalePreviewFrame) {
        progressStream = AsyncStream { continuation in
            continuation.finish()
        }
        previewStream = AsyncStream(
            bufferingPolicy: .bufferingNewest(1)
        ) { continuation in
            continuation.yield(preview)
            continuation.finish()
        }
    }

    func cancel() {}

    func waitForCompletion() async throws -> URL {
        await Task.yield()
        throw UpscalerEngineError.strategyFailed(
            "writer finalization rejected the output"
        )
    }
}
