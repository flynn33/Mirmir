import AVFoundation
import XCTest
@testable import Mirmir

final class WMVAACMatroskaImporterV4Tests: XCTestCase {
    func testWMV2AACMatroskaOpensViaSoftwareDecode() async throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "universal-wmv-aac-mkv", withExtension: "mkv"
        ))
        let probe = try UniversalContainerRemuxV4.probe(url: source)
        XCTAssertFalse(probe.admissible)
        XCTAssertEqual(probe.videoCodecName, "wmv2")
        XCTAssertEqual(probe.audioCodecName, "aac")

        let asset = try await NativeMediaInputAssetResolverV4.asset(url: source)
        let context = try XCTUnwrap(OriginalSoftwareMediaContext.associated(with: asset))
        XCTAssertEqual(asset.url.scheme, "mirmir-software-source")

        let video = try XCTUnwrap(context.sourceFacts.streams.first { $0.mediaType == 0 })
        let audio = try XCTUnwrap(context.sourceFacts.streams.first { $0.mediaType == 1 })
        XCTAssertEqual(video.codecName, "wmv2")
        XCTAssertEqual(audio.codecName, "aac")
        XCTAssertEqual(video.matroska?.codecID, "V_MS/VFW/FOURCC")
        XCTAssertEqual(audio.matroska?.codecID, "A_AAC")

        let readable = try await asset.load(.isReadable)
        let playable = try await asset.load(.isPlayable)
        XCTAssertTrue(readable)
        XCTAssertTrue(playable)
    }

    func testWMV2AACMatroskaDurableCPUExportPreservesAAC() async throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "universal-wmv-aac-mkv", withExtension: "mkv"
        ))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirmir-wmv-aac-mkv-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let asset = try await NativeMediaInputAssetResolverV4.asset(url: source)
        let context = try XCTUnwrap(OriginalSoftwareMediaContext.associated(with: asset))
        let frameCount = try XCTUnwrap(context.timings.first { $0.kind == "video" }?.frameCount)
        let info = try XCTUnwrap(context.typedProjection.videoInfo)
        let size = try XCTUnwrap(info.geometry.encodedSize)

        let output = root.appendingPathComponent("out.mov")
        let queue = try WorkflowApplicationQueueV4(
            trustedRootURL: root.appendingPathComponent("store"),
            workerID: WorkflowWorkerIDV4("wmv-aac-mkv-worker"),
            resolver: WMVAACMatroskaBookmarkResolverV4()
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
                outputCodec: .h264,
                preserveAudio: true,
                overwriteExistingFile: false
            ),
            progress: { _ in },
            snapshot: { _ in }
        )
        guard case .completed(let completion) = outcome else {
            return XCTFail("expected completed durable export, got \(outcome)")
        }
        XCTAssertEqual(completion.result.processedFrameCount, Int(frameCount))
        XCTAssertEqual(completion.result.audioResult, .preserved)

        let outputAsset = AVURLAsset(url: output)
        let audioTracks = try await outputAsset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audioTracks.count, 1)
    }
}

private struct WMVAACMatroskaBookmarkResolverV4: WorkflowSecurityScopedBookmarkResolvingV4 {
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
