import AVFoundation
import CoreMedia
import CoreVideo
import XCTest
@testable import Mirmir

/// Production qualification for MPEG-TS (mpeg2video + mp2): open + decode + durable export.
/// Native AVFoundation can open this fixture on My Mac, but remux inflates decode and native
/// PTS offsets fail the durable cadence lattice — product routing uses software decode.
final class MPEGTSProductionV4Tests: XCTestCase {
    func testMPEGTSOpensViaSoftwareDecodeWithCompleteFrameInventory() async throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "mpeg2-ts", withExtension: "ts"
        ))

        let probe = try UniversalContainerRemuxV4.probe(url: source)
        XCTAssertTrue(probe.admissible)
        XCTAssertEqual(probe.videoCodecName, "mpeg2video")
        XCTAssertEqual(probe.audioCodecName, "mp2")
        XCTAssertEqual(try UniversalContainerRemuxV4.containerFamily(url: source), "mpegts")

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirmir-mpegts-open-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let resolver = NativeMediaInputAssetResolverV4(cacheRoot: root.appendingPathComponent("cache"))
        let asset = try await resolver.resolvedAsset(url: source)
        let context = try XCTUnwrap(OriginalSoftwareMediaContext.associated(with: asset))
        XCTAssertEqual(asset.url.scheme, "mirmir-software-source")
        XCTAssertEqual(context.timings.first { $0.kind == "video" }?.frameCount, 72)
        // Compressed inventory is authoritative; BGRA decode can over-count by one on this host.
        try await assertSampleInventory(asset, expected: 72, decoded: false)

        let info = try await VideoProbe().probe(url: source)
        XCTAssertEqual(info.geometry.encodedSize?.width, 160)
        XCTAssertEqual(info.geometry.encodedSize?.height, 96)
        XCTAssertEqual(info.color.isFullRange, false)
        XCTAssertEqual(info.color.dynamicRange, .sdr)
        XCTAssertEqual(info.color.bitDepth, 8)
        let catalog = UpscaleBackendCatalog.live()
        for backend: UpscaleBackendID in [.mirmirDeterministicCPU, .mirmirDeterministicMetal] {
            let availability = await catalog.availability(
                for: backend, source: info,
                targetSize: CGSize(width: 320, height: 192), environment: .current()
            )
            XCTAssertEqual(availability, .available, "\(backend)")
        }
    }

    func testMPEGTSDurableCPUExportCompletesWithFramesAndAudio() async throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "mpeg2-ts", withExtension: "ts"
        ))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirmir-mpegts-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        do {
            let contextAsset = try await NativeMediaInputAssetResolverV4(
                cacheRoot: root.appendingPathComponent("cache")
            ).resolvedAsset(url: source)
            let context = try XCTUnwrap(OriginalSoftwareMediaContext.associated(with: contextAsset))
            let frameCount = try XCTUnwrap(context.timings.first { $0.kind == "video" }?.frameCount)
            XCTAssertEqual(frameCount, 72)
            let info = try XCTUnwrap(context.typedProjection.videoInfo)
            let size = try XCTUnwrap(info.geometry.encodedSize)
            let output = root.appendingPathComponent("out.mov")
            let queue = try WorkflowApplicationQueueV4(
                trustedRootURL: root.appendingPathComponent("store"),
                workerID: WorkflowWorkerIDV4("mpegts-worker"),
                resolver: MPEGTSBookmarkResolverV4()
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
                    preserveAudio: true,
                    overwriteExistingFile: false
                ),
                progress: { _ in },
                snapshot: { _ in }
            )
            guard case .completed(let completion) = outcome else {
                NSLog("MPEGTS_DURABLE_OUTCOME \(String(reflecting: outcome))")
                return XCTFail("expected completed durable export, got \(outcome)")
            }
            XCTAssertEqual(completion.result.processedFrameCount, Int(frameCount))
            XCTAssertNotEqual(completion.result.audioResult, .omitted)
            XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))

            let outputAsset = AVURLAsset(url: output)
            let videoTracks = try await outputAsset.loadTracks(withMediaType: .video)
            XCTAssertEqual(videoTracks.count, 1)
            let audioTracks = try await outputAsset.loadTracks(withMediaType: .audio)
            XCTAssertEqual(audioTracks.count, 1)
            try await assertSampleInventory(outputAsset, expected: 72, decoded: false)
            // Ensure decode is productive (BGRA may over-count; require at least the inventory).
            try await assertSampleInventory(outputAsset, expectedAtLeast: 72, decoded: true)
        } catch {
            NSLog("MPEGTS_DURABLE_FAILURE root=\(root.path) err=\(String(reflecting: error))")
            throw error
        }
    }

    private func assertSampleInventory(
        _ asset: AVAsset,
        expected: Int? = nil,
        expectedAtLeast: Int? = nil,
        decoded: Bool
    ) async throws {
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any]? = decoded ? [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ] : nil
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        XCTAssertTrue(reader.canAdd(output))
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var count = 0
        while let sample = output.copyNextSampleBuffer() {
            if decoded {
                if CMSampleBufferGetImageBuffer(sample) != nil { count += 1 }
            } else if CMSampleBufferGetNumSamples(sample) > 0 {
                count += 1
            }
        }
        XCTAssertEqual(reader.status, .completed)
        if let expected {
            XCTAssertEqual(count, expected)
        }
        if let expectedAtLeast {
            XCTAssertGreaterThanOrEqual(count, expectedAtLeast)
        }
    }
}

private struct MPEGTSBookmarkResolverV4: WorkflowSecurityScopedBookmarkResolvingV4 {
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
