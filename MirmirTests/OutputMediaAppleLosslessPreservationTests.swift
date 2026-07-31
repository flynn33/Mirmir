import AudioToolbox
import AVFoundation
import CoreMedia
import Foundation
import XCTest
@testable import Mirmir

final class OutputMediaAppleLosslessPreservationTests:
    XCTestCase {
    func testReaderBuildsStableExactIdentityForRealALAC()
        async throws {
        let directory = try makeAppleLosslessTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("source.m4a")
        let changedURL = directory.appendingPathComponent("changed.m4a")
        try writeAppleLosslessAudio(
            to: sourceURL,
            seed: 11
        )
        try writeAppleLosslessAudio(
            to: changedURL,
            seed: 29
        )

        let first = try await OutputMediaAppleLosslessIdentityReader
            .read(url: sourceURL)
        let repeated = try await OutputMediaAppleLosslessIdentityReader
            .read(url: sourceURL)
        let changed = try await OutputMediaAppleLosslessIdentityReader
            .read(url: changedURL)

        XCTAssertEqual(first, repeated)
        XCTAssertNotEqual(
            first.canonicalSHA256,
            changed.canonicalSHA256
        )
        XCTAssertEqual(first.formats.count, 1)
        let format = try XCTUnwrap(first.formats.first)
        XCTAssertEqual(
            format.mediaSubtype,
            kAudioFormatAppleLossless
        )
        XCTAssertEqual(
            format.formatID,
            kAudioFormatAppleLossless
        )
        XCTAssertEqual(format.sampleRate, 48_000)
        XCTAssertEqual(format.channelsPerFrame, 2)
        XCTAssertEqual(
            format.formatFlags,
            kAppleLosslessFormatFlag_16BitSourceData
        )
        XCTAssertGreaterThan(format.framesPerPacket, 0)
        XCTAssertFalse(
            format.codecConfigurationMagicCookie.isEmpty
        )
        XCTAssertGreaterThan(first.sampleIdentity.sampleCount, 0)
        XCTAssertGreaterThan(
            first.sampleIdentity.totalPayloadByteCount,
            0
        )
        XCTAssertEqual(first.canonicalSHA256.count, 64)
    }

    func testReaderAcceptsEveryAppleLosslessSourceBitDepth()
        async throws {
        let directory = try makeAppleLosslessTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for representation in AppleLosslessFixtureRepresentation.all {
            let sourceURL = directory.appendingPathComponent(
                "source-\(representation.bitDepth)-bit.m4a"
            )
            try writeAppleLosslessAudio(
                to: sourceURL,
                seed: representation.bitDepth,
                bitDepth: representation.bitDepth
            )

            let identity =
                try await OutputMediaAppleLosslessIdentityReader.read(
                    url: sourceURL
                )
            let format = try XCTUnwrap(identity.formats.first)
            XCTAssertEqual(
                format.formatFlags,
                representation.formatFlag,
                "\(representation.context): source flag"
            )
            XCTAssertGreaterThan(
                identity.sampleIdentity.sampleCount,
                0,
                representation.context
            )
            XCTAssertEqual(
                identity.canonicalSHA256.count,
                64,
                representation.context
            )
        }
    }

    func testShippingServicePreservesALACExactlyInMP4()
        async {
        for representation in AppleLosslessFixtureRepresentation.all {
            do {
                try await assertShippingServicePreservesALACExactly(
                    representation
                )
            } catch {
                XCTFail(
                    "\(representation.context) production workflow "
                        + "threw \(String(reflecting: error))"
                )
            }
        }
    }
}

private struct AppleLosslessFixtureRepresentation {
    let bitDepth: Int
    let formatFlag: AudioFormatFlags

    var context: String {
        "\(bitDepth)-bit Apple Lossless"
    }

    static let all = [
        AppleLosslessFixtureRepresentation(
            bitDepth: 16,
            formatFlag: kAppleLosslessFormatFlag_16BitSourceData
        ),
        AppleLosslessFixtureRepresentation(
            bitDepth: 20,
            formatFlag: kAppleLosslessFormatFlag_20BitSourceData
        ),
        AppleLosslessFixtureRepresentation(
            bitDepth: 24,
            formatFlag: kAppleLosslessFormatFlag_24BitSourceData
        ),
        AppleLosslessFixtureRepresentation(
            bitDepth: 32,
            formatFlag: kAppleLosslessFormatFlag_32BitSourceData
        )
    ]
}

private func assertShippingServicePreservesALACExactly(
    _ representation: AppleLosslessFixtureRepresentation
) async throws {
    let context = representation.context
    let workspace = try R13IntegrationWorkspace(
        outputFileName:
            "apple-lossless-\(representation.bitDepth)-bit-output.mp4"
    )
    defer { workspace.remove() }
    let videoURL = workspace.directory
        .appendingPathComponent("video.mp4")
    let audioURL = workspace.directory
        .appendingPathComponent("audio.m4a")
    try await writeVideoFrames(
        to: videoURL,
        resolution: .p720,
        frameCount: 3,
        frameDuration: CMTime(value: 1, timescale: 30),
        codec: .h264
    )
    try writeAppleLosslessAudio(
        to: audioURL,
        seed: 41 + representation.bitDepth,
        bitDepth: representation.bitDepth
    )
    try await muxVideoAndAAC(
        videoURL: videoURL,
        audioURL: audioURL,
        destinationURL: workspace.sourceURL
    )

    let media = AVFoundationMediaPipeline(
        metal: NoopMetalRenderingService()
    )
    let sourceProfile = try await media.probe(
        url: workspace.sourceURL
    )
    let sourceAudio = try XCTUnwrap(
        sourceProfile.mediaPreservationCapability
            .audioTracks.first,
        context
    )
    XCTAssertEqual(
        sourceProfile.mediaPreservationCapability.audioTracks.count,
        1,
        context
    )
    XCTAssertEqual(
        sourceAudio.formatSubtypes,
        ["alac"],
        context
    )
    XCTAssertEqual(
        sourceAudio.sampleRate,
        48_000,
        context
    )
    XCTAssertEqual(
        sourceAudio.channelCount,
        2,
        context
    )
    XCTAssertEqual(
        sourceAudio.compressedAudioIdentitySHA256?.count,
        64,
        context
    )
    XCTAssertEqual(
        sourceAudio.exactTrackIdentitySHA256?.count,
        64,
        context
    )
    XCTAssertEqual(
        sourceAudio.support,
        .exact,
        context
    )
    XCTAssertNil(
        sourceProfile.mediaPreservationCapability.failureReason(
            preserveAudio: true,
            preserveSubtitles: true,
            preserveMetadata: true
        ),
        context
    )
    let sourceIdentity =
        try await OutputMediaAppleLosslessIdentityReader.read(
            url: workspace.sourceURL
        )
    XCTAssertEqual(
        sourceIdentity.formats.count,
        1,
        context
    )
    XCTAssertEqual(
        try XCTUnwrap(sourceIdentity.formats.first, context)
            .formatFlags,
        representation.formatFlag,
        "\(context): muxed source flag"
    )

    let harness = try R13IntegrationHardeningHarness.make(
        jobsRootURL: workspace.jobsRootURL,
        exactFrameCount: 3
    )
    let service = R13ReleaseUpscalerEngineService(
        media: media,
        hardeningRuntime: harness.runtime
    )
    let job = UpscaleJob(
        identifier:
            "r13-apple-lossless-\(representation.bitDepth)-bit",
        inputURL: workspace.sourceURL,
        outputURL: workspace.outputURL,
        targetResolution: .p1080,
        codec: .h264,
        preserveAudio: true,
        mode: .quality
    )
    let expectedReleaseIdentity =
        try makeAppleLosslessExpectedReleaseIdentity(
            job: job,
            harness: harness
        )

    let result = try await service.submit(job)
        .waitForCompletion()

    XCTAssertEqual(result, workspace.outputURL, context)
    XCTAssertTrue(
        FileManager.default.fileExists(
            atPath: workspace.outputURL.path
        ),
        context
    )
    XCTAssertEqual(
        workspace.outputURL.pathExtension.lowercased(),
        "mp4",
        context
    )
    XCTAssertEqual(
        try readR13ISOBaseMediaMajorBrand(
            at: workspace.outputURL
        ),
        "mp42",
        context
    )
    try await assertR13ReopenedOutput(
        at: workspace.outputURL,
        resolution: .p1080
    )
    let outputAsset = AVURLAsset(url: workspace.outputURL)
    let reopenedVideo = try await outputAsset.loadTracks(
        withMediaType: .video
    )
    XCTAssertEqual(reopenedVideo.count, 1, context)
    let videoFormats = try await XCTUnwrap(
        reopenedVideo.first,
        context
    ).load(.formatDescriptions)
    XCTAssertEqual(
        videoFormats.map {
            CMFormatDescriptionGetMediaSubType($0)
        },
        [kCMVideoCodecType_H264],
        context
    )
    let reopenedAudio = try await outputAsset.loadTracks(
        withMediaType: .audio
    )
    XCTAssertEqual(reopenedAudio.count, 1, context)
    let outputFormats = try await XCTUnwrap(
        reopenedAudio.first,
        context
    ).load(.formatDescriptions)
    XCTAssertEqual(
        outputFormats.map {
            CMFormatDescriptionGetMediaSubType($0)
        },
        [kAudioFormatAppleLossless],
        context
    )

    let outputIdentity =
        try await OutputMediaAppleLosslessIdentityReader.read(
            url: workspace.outputURL
        )
    XCTAssertEqual(outputIdentity, sourceIdentity, context)
    XCTAssertEqual(
        try XCTUnwrap(outputIdentity.formats.first, context)
            .formatFlags,
        representation.formatFlag,
        "\(context): reopened output flag"
    )
    let outputProfile = try await media.probe(
        url: workspace.outputURL
    )
    let outputAudio = try XCTUnwrap(
        outputProfile.mediaPreservationCapability
            .audioTracks.first,
        context
    )
    XCTAssertEqual(
        outputAudio.formatSubtypes,
        ["alac"],
        context
    )
    XCTAssertEqual(
        outputAudio.support,
        .exact,
        context
    )
    XCTAssertEqual(
        outputAudio.compressedAudioIdentitySHA256,
        sourceAudio.compressedAudioIdentitySHA256,
        context
    )
    XCTAssertEqual(
        outputAudio.exactTrackIdentitySHA256,
        sourceAudio.exactTrackIdentitySHA256,
        context
    )

    let releaseMetadata = try await readR13ReleaseMetadata(
        at: workspace.outputURL
    )
    try expectedReleaseIdentity.validateTimedMetadata(
        releaseMetadata
    )
    XCTAssertEqual(
        releaseMetadata[
            "com.mirmir.release.identity-sha256"
        ],
        expectedReleaseIdentity.identitySHA256,
        context
    )

    let governor = await harness.governor.snapshot()
    XCTAssertTrue(
        governor.activeLeaseIdentities.isEmpty,
        context
    )
    XCTAssertEqual(governor.reservedDiskBytes, 0, context)
    XCTAssertEqual(governor.reservedMemoryBytes, 0, context)
    XCTAssertEqual(governor.nextAdmissionOrdinal, 1, context)
    let diagnostics = await harness.diagnostics.snapshot()
    XCTAssertEqual(
        diagnostics.records.filter {
            $0.event.code == .outputReopened
        }.count,
        1,
        context
    )
    XCTAssertEqual(
        diagnostics.records.filter {
            $0.event.code == .resourceReleased
        }.count,
        1,
        context
    )
    let releaseIdentityRecords = diagnostics.records.filter {
        $0.event.code == .releaseIdentityCreated
    }
    XCTAssertEqual(releaseIdentityRecords.count, 1, context)
    XCTAssertEqual(
        releaseIdentityRecords.first?.event.fields.first {
            $0.key == .releaseIdentitySHA256
        }?.value,
        expectedReleaseIdentity.identitySHA256,
        context
    )
    let recoverableJobs = try await service.recoverableJobs()
    XCTAssertTrue(recoverableJobs.jobs.isEmpty, context)
}

private func makeAppleLosslessExpectedReleaseIdentity(
    job: UpscaleJob,
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
            at: job.inputURL
        ),
        environment: environment,
        policyResources: harness.documents.policyResources
    )
}

private enum AppleLosslessFixtureError: Error {
    case audioFormatUnavailable
    case audioBufferUnavailable
    case interleavedSamplesUnavailable
    case unsupportedBitDepth(Int)
}

private func makeAppleLosslessTestDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "mirmir-alac-tests-\(UUID().uuidString)",
            isDirectory: true
        )
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    return directory
}

private func writeAppleLosslessAudio(
    to url: URL,
    seed: Int,
    bitDepth: Int = 16
) throws {
    let commonFormat: AVAudioCommonFormat
    switch bitDepth {
    case 16:
        commonFormat = .pcmFormatInt16
    case 20, 24, 32:
        commonFormat = .pcmFormatInt32
    default:
        throw AppleLosslessFixtureError.unsupportedBitDepth(bitDepth)
    }
    guard let pcmFormat = AVAudioFormat(
        commonFormat: commonFormat,
        sampleRate: 48_000,
        channels: 2,
        interleaved: true
    ) else {
        throw AppleLosslessFixtureError.audioFormatUnavailable
    }
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatAppleLossless,
        AVSampleRateKey: 48_000.0,
        AVNumberOfChannelsKey: 2,
        AVEncoderBitDepthHintKey: bitDepth
    ]
    var file: AVAudioFile? = try AVAudioFile(
        forWriting: url,
        settings: settings,
        commonFormat: commonFormat,
        interleaved: true
    )
    guard let buffer = AVAudioPCMBuffer(
        pcmFormat: pcmFormat,
        frameCapacity: 4_800
    ) else {
        throw AppleLosslessFixtureError.audioBufferUnavailable
    }
    buffer.frameLength = 4_800
    if bitDepth == 16 {
        guard let samples = buffer.int16ChannelData?.pointee else {
            throw AppleLosslessFixtureError
                .interleavedSamplesUnavailable
        }
        for frame in 0..<4_800 {
            samples[frame * 2] = Int16(
                ((frame * 37) + seed * 101) % 20_000 - 10_000
            )
            samples[frame * 2 + 1] = Int16(
                ((frame * 53) + seed * 211) % 20_000 - 10_000
            )
        }
    } else {
        guard let samples = buffer.int32ChannelData?.pointee else {
            throw AppleLosslessFixtureError
                .interleavedSamplesUnavailable
        }
        for frame in 0..<4_800 {
            let left = Int32(
                ((frame * 37) + seed * 101) % 20_000 - 10_000
            )
            let right = Int32(
                ((frame * 53) + seed * 211) % 20_000 - 10_000
            )
            samples[frame * 2] = left * 65_536
            samples[frame * 2 + 1] = right * 65_536
        }
    }
    try file?.write(from: buffer)
    file = nil
}
