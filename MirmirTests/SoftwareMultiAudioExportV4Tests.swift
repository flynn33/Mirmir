import AVFoundation
import XCTest
@testable import Mirmir

final class SoftwareMultiAudioExportV4Tests: XCTestCase {
    func testVP9AACOpusMatroskaOpensWithTwoAudioTracks() async throws {
        try await assertSoftwareOpens(
            resource: "universal-vp9-aac-opus-mkv",
            ext: "mkv",
            expectedAudioCodecs: ["aac", "opus"]
        )
    }

    func testVP9DualOpusWebMOpensWithTwoAudioTracks() async throws {
        try await assertSoftwareOpens(
            resource: "universal-vp9-dual-opus-webm",
            ext: "webm",
            expectedAudioCodecs: ["opus", "opus"]
        )
    }

    func testWMVWMAAACASFOpensWithTwoAudioTracks() async throws {
        try await assertSoftwareOpens(
            resource: "universal-wmv-wma-aac-asf",
            ext: "asf",
            expectedAudioCodecs: ["wmav2", "aac"]
        )
    }

    func testVP9AACOpusMatroskaDurableCPUExportKeepsBothAudioTracks() async throws {
        try await assertDurableMultiAudioExport(
            resource: "universal-vp9-aac-opus-mkv",
            ext: "mkv",
            codec: .hevc,
            expectedAudioResult: .transcoded,
            expectedOutputAudioCount: 2
        )
    }

    func testVP9DualOpusWebMDurableCPUExportKeepsBothAudioTracks() async throws {
        try await assertDurableMultiAudioExport(
            resource: "universal-vp9-dual-opus-webm",
            ext: "webm",
            codec: .hevc,
            expectedAudioResult: .transcoded,
            expectedOutputAudioCount: 2
        )
    }

    func testWMVWMAAACASFDurableCPUExportKeepsBothAudioTracks() async throws {
        try await assertDurableMultiAudioExport(
            resource: "universal-wmv-wma-aac-asf",
            ext: "asf",
            codec: .h264,
            expectedAudioResult: .transcoded,
            expectedOutputAudioCount: 2
        )
    }

    private func assertSoftwareOpens(
        resource: String,
        ext: String,
        expectedAudioCodecs: [String]
    ) async throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: resource, withExtension: ext
        ))
        let asset = try await NativeMediaInputAssetResolverV4.asset(url: source)
        let context = try XCTUnwrap(OriginalSoftwareMediaContext.associated(with: asset))
        XCTAssertEqual(asset.url.scheme, "mirmir-software-source")
        let audio = context.sourceFacts.streams.filter { $0.mediaType == 1 }
        XCTAssertEqual(audio.map(\.codecName), expectedAudioCodecs)
        XCTAssertEqual(context.sourceFacts.streams.filter { $0.mediaType == 0 }.count, 1)
        let readable = try await asset.load(.isReadable)
        let playable = try await asset.load(.isPlayable)
        XCTAssertTrue(readable)
        XCTAssertTrue(playable)
    }

    private func assertDurableMultiAudioExport(
        resource: String,
        ext: String,
        codec: OutputCodec,
        expectedAudioResult: AudioOutputResult,
        expectedOutputAudioCount: Int
    ) async throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: resource, withExtension: ext
        ))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirmir-sw-multi-audio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let asset = try await NativeMediaInputAssetResolverV4.asset(url: source)
        let context = try XCTUnwrap(OriginalSoftwareMediaContext.associated(with: asset))
        let frameCount = try XCTUnwrap(context.timings.first { $0.kind == "video" }?.frameCount)
        let info = try XCTUnwrap(context.typedProjection.videoInfo)
        let size = try XCTUnwrap(info.geometry.encodedSize)
        let sourceAudioCount = context.sourceFacts.streams.filter { $0.mediaType == 1 }.count
        XCTAssertEqual(sourceAudioCount, expectedOutputAudioCount)

        let output = root.appendingPathComponent("out.mov")
        let queue = try WorkflowApplicationQueueV4(
            trustedRootURL: root.appendingPathComponent("store"),
            workerID: WorkflowWorkerIDV4("software-multi-audio-worker"),
            resolver: SoftwareMultiAudioBookmarkResolverV4()
        )
        let coordinator = WorkflowApplicationCoordinatorV4(
            queue: queue,
            engine: WorkflowDeterministicApplicationEngineV4(
                videoProbe: VideoProbe(),
                backendCatalog: .live(),
                runtimeEnvironment: .current()
            ),
            maximumInputFramesPerBoundary: 60
        )
        _ = try await coordinator.launch()
        let outcome = try await coordinator.submit(
            request: UpscaleRequest(
                inputURL: source,
                outputURL: output,
                backendID: .mirmirDeterministicCPU,
                targetWidth: Int(size.width) * 2,
                targetHeight: Int(size.height) * 2,
                outputCodec: codec,
                preserveAudio: true,
                overwriteExistingFile: false
            ),
            progress: { _ in },
            snapshot: { _ in }
        )
        guard case .completed(let completion) = outcome else {
            NSLog("SOFTWARE_MULTI_AUDIO_OUTCOME \(resource): \(String(reflecting: outcome))")
            return XCTFail("expected completed durable export, got \(outcome)")
        }
        XCTAssertEqual(completion.result.processedFrameCount, Int(frameCount))
        XCTAssertEqual(completion.result.audioResult, expectedAudioResult)

        let outputAsset = AVURLAsset(url: output)
        let videoTracks = try await outputAsset.loadTracks(withMediaType: .video)
        let audioTracks = try await outputAsset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(videoTracks.count, 1)
        XCTAssertEqual(audioTracks.count, expectedOutputAudioCount)
        for audio in audioTracks {
            let descs = try await audio.load(.formatDescriptions)
            let asbd = descs.first.flatMap {
                CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee
            }
            let stats = try SoftwareDurableExportV4Tests.decodedAudioStatistics(
                of: outputAsset, track: audio
            )
            XCTAssertEqual(asbd?.mFormatID, kAudioFormatMPEG4AAC)
            XCTAssertGreaterThan(stats.frames, 0)
            XCTAssertGreaterThan(stats.rms, 0.001, "multi-audio output must not be silent")
        }
    }
}

private struct SoftwareMultiAudioBookmarkResolverV4: WorkflowSecurityScopedBookmarkResolvingV4 {
    func makeBookmark(for url: URL, role _: WorkflowScopedResourceRoleV4) throws -> Data {
        Data(url.standardizedFileURL.path.utf8)
    }

    func resolveBookmark(
        _ data: Data, role _: WorkflowScopedResourceRoleV4
    ) throws -> WorkflowResolvedScopedResourceV4 {
        let path = try XCTUnwrap(String(data: data, encoding: .utf8))
        return WorkflowResolvedScopedResourceV4(
            url: URL(fileURLWithPath: path),
            isStale: false,
            startAccessing: { true },
            stopAccessing: {}
        )
    }
}
