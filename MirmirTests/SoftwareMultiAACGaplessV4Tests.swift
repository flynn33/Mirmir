import AVFoundation
import XCTest
@testable import Mirmir

/// File-global iTunSMPB can own exactly one packet-AAC clock. Multiple original
/// packet-AAC tracks open as packet pass-through without inventing a shared hint.
final class SoftwareMultiAACGaplessV4Tests: XCTestCase {
    func testDualPacketAACOpensWithoutFileGlobalGaplessHint() async throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "universal-vp9-dual-aac-mkv", withExtension: "mkv"
        ))
        let asset = try await NativeMediaInputAssetResolverV4.asset(url: source)
        let context = try XCTUnwrap(OriginalSoftwareMediaContext.associated(with: asset))
        let audio = context.sourceFacts.streams.filter { $0.mediaType == 1 }
        XCTAssertEqual(audio.map(\.codecName), ["aac", "aac"])

        let execution = try await makeExecution(context: context, asset: asset)
        let packetAAC = execution.policy.tracks.filter {
            $0.audioSampleRate != nil && !$0.requiresAudioTranscode
        }
        XCTAssertEqual(packetAAC.count, 2)
        XCTAssertNil(execution.policy.derivedAACPacketTableMetadata)
    }

    func testSinglePacketAACWithSiblingStillBindsGaplessHint() async throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "universal-vp9-aac-opus-mkv", withExtension: "mkv"
        ))
        let asset = try await NativeMediaInputAssetResolverV4.asset(url: source)
        let context = try XCTUnwrap(OriginalSoftwareMediaContext.associated(with: asset))
        let execution = try await makeExecution(context: context, asset: asset)
        let packetAAC = execution.policy.tracks.filter {
            $0.audioSampleRate != nil && !$0.requiresAudioTranscode
                && context.sourceFacts.streams[Int($0.originalOrdinal)].codecName == "aac"
        }
        XCTAssertEqual(packetAAC.count, 1)
        let hint = try XCTUnwrap(execution.policy.derivedAACPacketTableMetadata)
        XCTAssertEqual(hint.sourceOrdinal, packetAAC[0].originalOrdinal)
        XCTAssertGreaterThan(hint.packetCount, 0)
        XCTAssertEqual(hint.validSamples, packetAAC[0].audibleAudioSamples)
    }

    func testDualPacketAACDurableCPUExportKeepsBothTracksWithoutiTunSMPB() async throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "universal-vp9-dual-aac-mkv", withExtension: "mkv"
        ))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirmir-dual-aac-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let asset = try await NativeMediaInputAssetResolverV4.asset(url: source)
        let context = try XCTUnwrap(OriginalSoftwareMediaContext.associated(with: asset))
        let execution = try await makeExecution(context: context, asset: asset)
        XCTAssertNil(execution.policy.derivedAACPacketTableMetadata)

        let frameCount = try XCTUnwrap(context.timings.first { $0.kind == "video" }?.frameCount)
        let info = try XCTUnwrap(context.typedProjection.videoInfo)
        let size = try XCTUnwrap(info.geometry.encodedSize)
        let output = root.appendingPathComponent("out.mov")

        let queue = try WorkflowApplicationQueueV4(
            trustedRootURL: root.appendingPathComponent("store"),
            workerID: WorkflowWorkerIDV4("dual-aac-worker"),
            resolver: SoftwareMultiAACGaplessBookmarkResolverV4()
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
                outputCodec: .hevc,
                preserveAudio: true,
                overwriteExistingFile: false
            ),
            progress: { _ in },
            snapshot: { _ in }
        )
        guard case .completed(let completion) = outcome else {
            NSLog("DUAL_AAC_OUTCOME \(String(reflecting: outcome))")
            return XCTFail("expected completed durable export, got \(outcome)")
        }
        XCTAssertEqual(completion.result.processedFrameCount, Int(frameCount))

        let outputAsset = AVURLAsset(url: output)
        let audioTracks = try await outputAsset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audioTracks.count, 2)
        for audio in audioTracks {
            let descs = try await audio.load(.formatDescriptions)
            let asbd = descs.first.flatMap {
                CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee
            }
            XCTAssertEqual(asbd?.mFormatID, kAudioFormatMPEG4AAC)
        }

        let itunes = try await outputAsset.loadMetadata(for: .iTunesMetadata)
        let smpb = itunes.filter { $0.identifier?.rawValue == "itlk/com.apple.iTunes.iTunSMPB" }
        XCTAssertTrue(smpb.isEmpty, "dual packet-AAC must not invent file-global iTunSMPB")
    }

    private func makeExecution(
        context: OriginalSoftwareMediaContext,
        asset: AVURLAsset
    ) async throws -> SoftwareSourceExecutionContext {
        let state = try XCTUnwrap(context.typedProjection.state)
        let graph = try XCTUnwrap(context.typedProjection.graph)
        return try await SoftwareSourceExecutionContext.make(
            originalCanonicalMedia: state,
            originalGraph: graph,
            context: context,
            asset: asset
        )
    }
}

private struct SoftwareMultiAACGaplessBookmarkResolverV4: WorkflowSecurityScopedBookmarkResolvingV4 {
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
