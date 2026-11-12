import AVFoundation
import XCTest
@testable import Mirmir

final class SoftwareDurableExportV4Tests: XCTestCase {
    func testVP9WebMDurableCPUExportOmitsAudio() async throws {
        try await runDurableCPUExport(resource: "universal-vp9-webm", ext: "webm", codec: .hevc)
    }

    func testWMVASFDurableCPUExportOmitsAudio() async throws {
        try await runDurableCPUExport(resource: "universal-wmv-asf", ext: "asf", codec: .h264)
    }

    private func runDurableCPUExport(
        resource: String, ext: String, codec: OutputCodec
    ) async throws {
        do {
            try await performDurableCPUExport(resource: resource, ext: ext, codec: codec)
        } catch {
            NSLog("SOFTWARE_DURABLE_EXPORT_FAILURE \(resource): \(String(reflecting: error))")
            throw error
        }
    }

    private func performDurableCPUExport(
        resource: String, ext: String, codec: OutputCodec
    ) async throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: resource, withExtension: ext
        ))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirmir-sw-durable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let resolver = NativeMediaInputAssetResolverV4(cacheRoot: root.appendingPathComponent("cache"))
        let asset = try await resolver.resolvedAsset(url: source)
        let context = try XCTUnwrap(OriginalSoftwareMediaContext.associated(with: asset))
        let frameCount = try XCTUnwrap(context.timings.first { $0.kind == "video" }?.frameCount)
        XCTAssertGreaterThan(frameCount, 0)
        let info = try XCTUnwrap(context.typedProjection.videoInfo)
        let size = try XCTUnwrap(info.geometry.encodedSize)

        let output = root.appendingPathComponent("out.mov")
        let queue = try WorkflowApplicationQueueV4(
            trustedRootURL: root.appendingPathComponent("store"),
            workerID: WorkflowWorkerIDV4("software-durable-worker"),
            resolver: SoftwareDurableBookmarkResolverV4()
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
                preserveAudio: false,
                overwriteExistingFile: false
            ),
            progress: { _ in },
            snapshot: { _ in }
        )
        guard case .completed(let completion) = outcome else {
            NSLog("SOFTWARE_DURABLE_EXPORT_OUTCOME \(resource): \(String(reflecting: outcome))")
            return XCTFail("expected completed durable export, got \(outcome)")
        }
        XCTAssertEqual(completion.result.processedFrameCount, Int(frameCount))
        XCTAssertEqual(completion.result.actualBackendID, .mirmirDeterministicCPU)
        XCTAssertEqual(completion.result.audioResult, .omitted)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))

        let outputAsset = AVURLAsset(url: output)
        let videoTracks = try await outputAsset.loadTracks(withMediaType: .video)
        XCTAssertEqual(videoTracks.count, 1)
        let audioTracks = try await outputAsset.loadTracks(withMediaType: .audio)
        XCTAssertTrue(audioTracks.isEmpty)
        let snapshot = try await queue.queueSnapshot()
        XCTAssertEqual(snapshot.items.count, 1)
        XCTAssertTrue(snapshot.items.allSatisfy { $0.lifecycle == .completed })
    }
}

private struct SoftwareDurableBookmarkResolverV4: WorkflowSecurityScopedBookmarkResolvingV4 {
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
