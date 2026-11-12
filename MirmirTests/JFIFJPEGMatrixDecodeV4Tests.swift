import AVFoundation
import CoreMedia
import CoreVideo
import XCTest
@testable import Mirmir

final class JFIFJPEGMatrixDecodeV4Tests: XCTestCase {
    func testProgressiveJPEG422RewritesToDecodableJFIF420() async throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "mjpeg422", withExtension: "mov"
        ))
        try await assertRawCannotDecode(source)
        let asset = try await NativeMediaInputAssetResolverV4.asset(url: source)
        try await assertDecodableProgressive420(asset, expectedFrames: 24)
        let info = try await VideoProbe().probe(url: source)
        XCTAssertEqual(info.geometry.encodedSize?.width, 160)
        XCTAssertEqual(info.geometry.encodedSize?.height, 90)
    }

    func testProgressiveJPEG444RewritesToDecodableJFIF420() async throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "mjpeg444", withExtension: "mov"
        ))
        try await assertRawCannotDecode(source)
        let asset = try await NativeMediaInputAssetResolverV4.asset(url: source)
        try await assertDecodableProgressive420(asset, expectedFrames: 24)
    }

    func testFFmpegStyleJPEG422MCUFactorsRewriteAndDecode() async throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "mjpeg422-ffmpeg", withExtension: "mov"
        ))
        try await assertRawCannotDecode(source)
        let asset = try await NativeMediaInputAssetResolverV4.asset(url: source)
        try await assertDecodableProgressive420(asset, expectedFrames: 24)
    }

    func testInterlacedMJPEGFieldCount2RewritesToProgressiveJFIF420() async throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "mjpeg-interlaced", withExtension: "mov"
        ))
        let raw = AVURLAsset(url: source)
        let rawTracks = try await raw.loadTracks(withMediaType: .video)
        let rawTrack = try XCTUnwrap(rawTracks.first)
        let rawDescriptions = try await rawTrack.load(.formatDescriptions)
        let rawDescription = try XCTUnwrap(rawDescriptions.first)
        let rawExtensions = CMFormatDescriptionGetExtensions(rawDescription) as NSDictionary? ?? [:]
        XCTAssertEqual(
            (rawExtensions[kCMFormatDescriptionExtension_FieldCount as String] as? NSNumber)?.intValue,
            2
        )
        XCTAssertEqual(
            rawExtensions[kCMFormatDescriptionExtension_FieldDetail as String] as? String,
            kCMFormatDescriptionFieldDetail_TemporalTopFirst as String
        )
        XCTAssertThrowsError(try JFIFVideoSamplingV4.progressiveDeclaration(from: rawDescription))
        let rawFrames = try await decodedFrameCount(of: raw)
        XCTAssertEqual(rawFrames, 12)
        let needsRewrite = try await JFIFImageIOWorkingRewriteV4.needsRewrite(asset: raw)
        XCTAssertTrue(needsRewrite)

        let asset = try await NativeMediaInputAssetResolverV4.asset(url: source)
        try await assertDecodableProgressive420(asset, expectedFrames: 12, width: 160, height: 120)
        let info = try await VideoProbe().probe(url: source)
        XCTAssertEqual(info.geometry.encodedSize?.width, 160)
        XCTAssertEqual(info.geometry.encodedSize?.height, 120)
        XCTAssertEqual(info.color.fieldCount, 1)
    }

    func testInterlacedMJPEGDurableCPUExportCompletesWithFrames() async throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "mjpeg-interlaced", withExtension: "mov"
        ))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirmir-jpeg-ilace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let info = try await VideoProbe().probe(url: source)
        let size = try XCTUnwrap(info.geometry.encodedSize)
        let output = root.appendingPathComponent("out.mov")
        let queue = try WorkflowApplicationQueueV4(
            trustedRootURL: root.appendingPathComponent("store"),
            workerID: WorkflowWorkerIDV4("jpeg-ilace-worker"),
            resolver: JPEGMatrixBookmarkResolverV4()
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
                preserveAudio: false,
                overwriteExistingFile: false
            ),
            progress: { _ in },
            snapshot: { _ in }
        )
        guard case .completed(let completion) = outcome else {
            return XCTFail("expected completed durable export, got \(outcome)")
        }
        XCTAssertEqual(completion.result.processedFrameCount, 12)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
    }

    func testOddRasterProgressiveJPEG420OpensAndDecodesNatively() async throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "mjpeg420-odd", withExtension: "mov"
        ))
        let raw = AVURLAsset(url: source)
        let rawFrames = try await decodedFrameCount(of: raw)
        XCTAssertEqual(rawFrames, 24)
        let needsRewrite = try await JFIFImageIOWorkingRewriteV4.needsRewrite(asset: raw)
        XCTAssertFalse(needsRewrite)

        let asset = try await NativeMediaInputAssetResolverV4.asset(url: source)
        try await assertDecodableProgressive420(asset, expectedFrames: 24, width: 161, height: 91)
        let info = try await VideoProbe().probe(url: source)
        XCTAssertEqual(info.geometry.encodedSize?.width, 161)
        XCTAssertEqual(info.geometry.encodedSize?.height, 91)
    }

    func testProgressiveJPEG422DurableCPUExportCompletesWithFrames() async throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "mjpeg422", withExtension: "mov"
        ))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirmir-jpeg422-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let info = try await VideoProbe().probe(url: source)
        let size = try XCTUnwrap(info.geometry.encodedSize)
        let output = root.appendingPathComponent("out.mov")
        let queue = try WorkflowApplicationQueueV4(
            trustedRootURL: root.appendingPathComponent("store"),
            workerID: WorkflowWorkerIDV4("jpeg422-worker"),
            resolver: JPEGMatrixBookmarkResolverV4()
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
                preserveAudio: false,
                overwriteExistingFile: false
            ),
            progress: { _ in },
            snapshot: { _ in }
        )
        guard case .completed(let completion) = outcome else {
            return XCTFail("expected completed durable export, got \(outcome)")
        }
        XCTAssertEqual(completion.result.processedFrameCount, 24)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
    }

    private func assertRawCannotDecode(_ url: URL) async throws {
        let asset = AVURLAsset(url: url)
        let needsRewrite = try await JFIFImageIOWorkingRewriteV4.needsRewrite(asset: asset)
        XCTAssertTrue(needsRewrite)
        let frames = try await decodedFrameCount(of: asset)
        XCTAssertEqual(frames, 0)
    }

    private func assertDecodableProgressive420(
        _ asset: AVAsset,
        expectedFrames: Int,
        width: Int32? = nil,
        height: Int32? = nil
    ) async throws {
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let descriptions = try await track.load(.formatDescriptions)
        let description = try XCTUnwrap(descriptions.first)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(description), kCMVideoCodecType_JPEG)
        let proof = try XCTUnwrap(try JFIFVideoSamplingV4.progressiveDeclaration(from: description))
        if let width { XCTAssertEqual(proof.width, width) }
        if let height { XCTAssertEqual(proof.height, height) }
        let frames = try await decodedFrameCount(of: asset)
        XCTAssertEqual(frames, expectedFrames)
    }

    private func decodedFrameCount(of asset: AVAsset) async throws -> Int {
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        guard reader.canAdd(output) else { return 0 }
        reader.add(output)
        guard reader.startReading() else { return 0 }
        var count = 0
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetImageBuffer(sample) != nil { count += 1 }
        }
        return count
    }
}

private struct JPEGMatrixBookmarkResolverV4: WorkflowSecurityScopedBookmarkResolvingV4 {
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
