import AVFoundation
import CoreMedia
import CoreVideo
import XCTest
@testable import Mirmir

final class MPEG4ASPAVIDecodeV4Tests: XCTestCase {
    func testASPIOnlyAVIOpensViaNativeMPEG4Remux() async throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "native-avi-mpeg4-asp", withExtension: "avi"
        ))
        let requiresSoftware = try await NativeMediaInputAssetResolverV4.aviMPEG4RequiresSoftwareDecode(source)
        XCTAssertFalse(requiresSoftware)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirmir-asp-ip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let resolver = NativeMediaInputAssetResolverV4(cacheRoot: root.appendingPathComponent("cache"))
        let asset = try await resolver.resolvedAsset(url: source)
        XCTAssertNil(OriginalSoftwareMediaContext.associated(with: asset))
        XCTAssertEqual(asset.url.pathExtension.lowercased(), "mov")
        try await assertDecodableFrames(asset, expected: 72)

        let info = try await VideoProbe().probe(url: source)
        XCTAssertEqual(info.geometry.encodedSize?.width, 160)
        XCTAssertEqual(info.geometry.encodedSize?.height, 96)
    }

    func testASPWithBFramesAVIOpensViaSoftwareDecode() async throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "native-avi-mpeg4-asp-b", withExtension: "avi"
        ))
        let requiresSoftware = try await NativeMediaInputAssetResolverV4.aviMPEG4RequiresSoftwareDecode(source)
        XCTAssertTrue(requiresSoftware)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirmir-asp-b-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let resolver = NativeMediaInputAssetResolverV4(cacheRoot: root.appendingPathComponent("cache"))
        let asset = try await resolver.resolvedAsset(url: source)
        XCTAssertNotNil(OriginalSoftwareMediaContext.associated(with: asset))
        XCTAssertEqual(asset.url.scheme, "mirmir-software-source")
        try await assertDecodableFrames(asset, expected: 72)

        let info = try await VideoProbe().probe(url: source)
        XCTAssertEqual(info.geometry.encodedSize?.width, 160)
        XCTAssertEqual(info.geometry.encodedSize?.height, 96)
    }

    func testASPWithBFramesDurableCPUExportCompletesWithFrames() async throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "native-avi-mpeg4-asp-b", withExtension: "avi"
        ))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirmir-asp-b-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let info = try await VideoProbe().probe(url: source)
        let size = try XCTUnwrap(info.geometry.encodedSize)
        let output = root.appendingPathComponent("out.mov")
        let queue = try WorkflowApplicationQueueV4(
            trustedRootURL: root.appendingPathComponent("store"),
            workerID: WorkflowWorkerIDV4("asp-b-worker"),
            resolver: MPEG4ASPBookmarkResolverV4()
        )
        let coordinator = WorkflowApplicationCoordinatorV4(
            queue: queue,
            engine: WorkflowDeterministicApplicationEngineV4(
                videoProbe: VideoProbe(),
                backendCatalog: .live(),
                runtimeEnvironment: .current()
            ),
            maximumInputFramesPerBoundary: 96
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
                preserveAudio: false,
                overwriteExistingFile: false
            ),
            progress: { _ in },
            snapshot: { _ in }
        )
        guard case .completed(let completion) = outcome else {
            return XCTFail("expected completed durable export, got \(outcome)")
        }
        XCTAssertEqual(completion.result.processedFrameCount, 72)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
    }

    func testSimpleProfileAVIRemainsOnNativeMPEG4Remux() async throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "native-avi-mpeg4", withExtension: "avi"
        ))
        let requiresSoftware = try await NativeMediaInputAssetResolverV4.aviMPEG4RequiresSoftwareDecode(source)
        XCTAssertFalse(requiresSoftware)
    }

    private func assertDecodableFrames(_ asset: AVAsset, expected: Int) async throws {
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        XCTAssertTrue(reader.canAdd(output))
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var count = 0
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetImageBuffer(sample) != nil { count += 1 }
        }
        XCTAssertEqual(reader.status, .completed)
        XCTAssertEqual(count, expected)
    }
}

private struct MPEG4ASPBookmarkResolverV4: WorkflowSecurityScopedBookmarkResolvingV4 {
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
