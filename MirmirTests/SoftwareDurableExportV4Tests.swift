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

    func testVP9WebMDurableCPUExportPreservesAudio() async throws {
        try await runDurableCPUExport(
            resource: "universal-vp9-webm", ext: "webm", codec: .hevc, preserveAudio: true
        )
    }

    func testWMVASFDurableCPUExportPreservesAudio() async throws {
        try await runDurableCPUExport(
            resource: "universal-wmv-asf", ext: "asf", codec: .h264, preserveAudio: true
        )
    }

    private func runDurableCPUExport(
        resource: String, ext: String, codec: OutputCodec, preserveAudio: Bool = false
    ) async throws {
        do {
            try await performDurableCPUExport(
                resource: resource, ext: ext, codec: codec, preserveAudio: preserveAudio
            )
        } catch {
            NSLog("SOFTWARE_DURABLE_EXPORT_FAILURE \(resource): \(String(reflecting: error))")
            throw error
        }
    }

    private func performDurableCPUExport(
        resource: String, ext: String, codec: OutputCodec, preserveAudio: Bool
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
                preserveAudio: preserveAudio,
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
        if preserveAudio {
            XCTAssertNotEqual(completion.result.audioResult, .omitted)
        } else {
            XCTAssertEqual(completion.result.audioResult, .omitted)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))

        let outputAsset = AVURLAsset(url: output)
        let videoTracks = try await outputAsset.loadTracks(withMediaType: .video)
        XCTAssertEqual(videoTracks.count, 1)
        let audioTracks = try await outputAsset.loadTracks(withMediaType: .audio)
        if preserveAudio {
            XCTAssertEqual(audioTracks.count, 1)
        } else {
            XCTAssertTrue(audioTracks.isEmpty)
        }
        if let audio = audioTracks.first {
            let descs = try await audio.load(.formatDescriptions)
            let range = try await audio.load(.timeRange)
            let asbd = descs.first.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
            let stats = try Self.decodedAudioStatistics(of: outputAsset, track: audio)
            NSLog("SOFTWARE_PRESERVE_AUDIO \(resource): result=\(completion.result.audioResult) fmt=\(asbd?.mFormatID ?? 0) sr=\(asbd?.mSampleRate ?? 0) ch=\(asbd?.mChannelsPerFrame ?? 0) start=\(range.start.seconds) dur=\(range.duration.seconds) frames=\(stats.frames) rms=\(stats.rms)")
            XCTAssertEqual(asbd?.mFormatID, kAudioFormatMPEG4AAC)
            XCTAssertGreaterThan(stats.frames, 0)
            XCTAssertGreaterThan(stats.rms, 0.001, "preserved audio must not be silent")
        }
        let snapshot = try await queue.queueSnapshot()
        XCTAssertEqual(snapshot.items.count, 1)
        XCTAssertTrue(snapshot.items.allSatisfy { $0.lifecycle == .completed })
    }
}

extension SoftwareDurableExportV4Tests {
    static func decodedAudioStatistics(
        of asset: AVAsset, track: AVAssetTrack
    ) throws -> (frames: Int, rms: Double) {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
        var frames = 0
        var sumSquares = 0.0
        var count = 0
        while let buffer = output.copyNextSampleBuffer() {
            frames += CMSampleBufferGetNumSamples(buffer)
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var data = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            data.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            for v in data { sumSquares += Double(v) * Double(v) }
            count += data.count
        }
        return (frames, count > 0 ? (sumSquares / Double(count)).squareRoot() : 0)
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
