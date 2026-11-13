import AVFoundation
import CoreMedia
import CoreVideo
import XCTest
@testable import Mirmir

final class OpenDMLJPEGNativeDecodeV4Tests: XCTestCase {
    func testOpenDMLAVIRewritesToJPEGWithoutExternalHuffmanAtom() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "legacy-mjpeg", withExtension: "avi"
        ))
        let raw = AVURLAsset(url: url)
        let rawTracks = try await raw.loadTracks(withMediaType: .video)
        let rawTrack = try XCTUnwrap(rawTracks.first)
        let rawDescriptions = try await rawTrack.load(.formatDescriptions)
        let rawDesc = try XCTUnwrap(rawDescriptions.first)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(rawDesc), kCMVideoCodecType_JPEG_OpenDML)
        let rawAtoms = (CMFormatDescriptionGetExtensions(rawDesc) as NSDictionary?)?
            .object(forKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? NSDictionary
        XCTAssertNotNil(rawAtoms?["mjht"])

        let asset = try await NativeMediaInputAssetResolverV4.asset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let descriptions = try await track.load(.formatDescriptions)
        let desc = try XCTUnwrap(descriptions.first)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(desc), kCMVideoCodecType_JPEG)
        let atoms = (CMFormatDescriptionGetExtensions(desc) as NSDictionary?)?
            .object(forKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? NSDictionary
        XCTAssertNil(atoms?["mjht"])
        XCTAssertNotNil(try JFIFVideoSamplingV4.progressiveDeclaration(from: desc))
    }

    func testOpenDMLAVIDecodedFramesMatchQualifiedMOVReference() async throws {
        let aviURL = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "legacy-mjpeg", withExtension: "avi"
        ))
        let movURL = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "legacy-mjpeg", withExtension: "mov"
        ))
        let aviHashes = try await decodedLumaHashes(
            of: try await NativeMediaInputAssetResolverV4.asset(url: aviURL)
        )
        let movHashes = try await decodedLumaHashes(
            of: try await NativeMediaInputAssetResolverV4.asset(url: movURL)
        )
        XCTAssertEqual(aviHashes.count, 72)
        XCTAssertEqual(aviHashes, movHashes)
    }

    func testOpenDMLAVIDurableCPUExportCompletesWithFrames() async throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "legacy-mjpeg", withExtension: "avi"
        ))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirmir-opendml-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let info = try await VideoProbe().probe(url: source)
        let size = try XCTUnwrap(info.geometry.encodedSize)
        let output = root.appendingPathComponent("out.mov")
        let queue = try WorkflowApplicationQueueV4(
            trustedRootURL: root.appendingPathComponent("store"),
            workerID: WorkflowWorkerIDV4("opendml-jpeg-worker"),
            resolver: OpenDMLBookmarkResolverV4()
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
        XCTAssertEqual(completion.result.processedFrameCount, 72)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        let outputAsset = AVURLAsset(url: output)
        let videoTracks = try await outputAsset.loadTracks(withMediaType: .video)
        XCTAssertEqual(videoTracks.count, 1)
    }

    private func decodedLumaHashes(of asset: AVAsset) async throws -> [UInt64] {
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ])
        guard reader.canAdd(output) else { throw CocoaError(.fileReadUnknown) }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
        var hashes: [UInt64] = []
        while let sample = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(sample) > 0,
                  let image = CMSampleBufferGetImageBuffer(sample) else { continue }
            hashes.append(Self.lumaFNV(image))
        }
        guard reader.status == .completed else {
            throw reader.error ?? CocoaError(.fileReadUnknown)
        }
        return hashes
    }

    private static func lumaFNV(_ image: CVPixelBuffer) -> UInt64 {
        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        let base = CVPixelBufferGetBaseAddressOfPlane(image, 0)!
        let height = CVPixelBufferGetHeightOfPlane(image, 0)
        let width = CVPixelBufferGetWidthOfPlane(image, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(image, 0)
        var hash: UInt64 = 14695981039346656037
        for row in 0..<height {
            let rowPtr = base.advanced(by: row * stride)
            for col in 0..<width {
                hash ^= UInt64(rowPtr.load(fromByteOffset: col, as: UInt8.self))
                hash &*= 1099511628211
            }
        }
        return hash
    }
}

private struct OpenDMLBookmarkResolverV4: WorkflowSecurityScopedBookmarkResolvingV4 {
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
