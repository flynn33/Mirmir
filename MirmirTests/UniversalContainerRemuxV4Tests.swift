import AVFoundation
import XCTest
@testable import Mirmir

final class UniversalContainerRemuxV4Tests: XCTestCase {
    func testH264MatroskaRemuxBecomesNativeDecodable() async throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "universal-h264-mkv", withExtension: "mkv"
        ))
        let native = AVURLAsset(url: source, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        do {
            _ = try await native.load(.isReadable, .isPlayable, .tracks)
            XCTFail("H.264 MKV should not be natively openable before remux routing")
        } catch {
            let ns = error as NSError
            XCTAssertEqual(ns.domain, AVFoundationErrorDomain)
            XCTAssertEqual(ns.code, -11828) // Cannot Open
        }

        let probe = try UniversalContainerRemuxV4.probe(url: source)
        XCTAssertTrue(probe.admissible)
        XCTAssertEqual(probe.videoCodecName, "h264")
        XCTAssertEqual(probe.audioCodecName, "aac")

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirmir-universal-remux-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let resolver = NativeMediaInputAssetResolverV4(cacheRoot: root.appendingPathComponent("cache"))
        let asset = try await resolver.resolvedAsset(url: source)
        XCTAssertNotEqual(asset.url, source)
        XCTAssertEqual(asset.url.pathExtension.lowercased(), "mov")
        let readable = try await asset.load(.isReadable)
        let playable = try await asset.load(.isPlayable)
        XCTAssertTrue(readable)
        XCTAssertTrue(playable)

        let tracks = try await asset.load(.tracks)
        XCTAssertEqual(tracks.filter { $0.mediaType == .video }.count, 1)
        XCTAssertEqual(tracks.filter { $0.mediaType == .audio }.count, 1)

        let reader = try AVAssetReader(asset: asset)
        let video = try XCTUnwrap(tracks.first { $0.mediaType == .video })
        let output = AVAssetReaderTrackOutput(track: video, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        output.alwaysCopiesSampleData = false
        XCTAssertTrue(reader.canAdd(output))
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var frames = 0
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sample) > 0 { frames += 1 }
        }
        XCTAssertEqual(reader.status, .completed)
        XCTAssertEqual(frames, 72)
    }

    func testVP9AndWMVRemainInadmissibleForRemuxOnlyRouting() throws {
        let vp9 = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "universal-vp9-webm", withExtension: "webm"
        ))
        let wmv = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "universal-wmv-asf", withExtension: "asf"
        ))
        XCTAssertFalse(try UniversalContainerRemuxV4.probe(url: vp9).admissible)
        XCTAssertFalse(try UniversalContainerRemuxV4.probe(url: wmv).admissible)
    }
}
