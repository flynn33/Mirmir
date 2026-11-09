import AVFoundation
import XCTest
@testable import Mirmir

final class SoftwareDecodeImporterV4Tests: XCTestCase {
    func testVP9WebMOpensViaSoftwareDecode() async throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "universal-vp9-webm", withExtension: "webm"
        ))
        try await assertSoftwareDecodeOpens(source, expectedCodec: "vp9")
    }

    func testWMVASFOpensViaSoftwareDecode() async throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "universal-wmv-asf", withExtension: "asf"
        ))
        try await assertSoftwareDecodeOpens(source, expectedCodec: "wmv")
    }

    func testH264MatroskaStillUsesRemuxNotSoftware() async throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "universal-h264-mkv", withExtension: "mkv"
        ))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirmir-software-routing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let resolver = NativeMediaInputAssetResolverV4(cacheRoot: root.appendingPathComponent("cache"))
        let asset = try await resolver.resolvedAsset(url: source)
        XCTAssertEqual(asset.url.pathExtension.lowercased(), "mov")
        XCTAssertNil(OriginalSoftwareMediaContext.associated(with: asset))
        let playable = try await asset.load(.isPlayable)
        XCTAssertTrue(playable)
    }

    private func assertSoftwareDecodeOpens(_ source: URL, expectedCodec: String) async throws {
        let probe = try UniversalContainerRemuxV4.probe(url: source)
        XCTAssertFalse(probe.admissible)
        XCTAssertTrue(probe.videoCodecName.lowercased().contains(expectedCodec))

        let native = AVURLAsset(url: source, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        do {
            _ = try await native.load(.isReadable, .isPlayable, .tracks)
            XCTFail("\(expectedCodec) source should not be natively openable before software routing")
        } catch {
            let ns = error as NSError
            XCTAssertEqual(ns.domain, AVFoundationErrorDomain)
            XCTAssertEqual(ns.code, -11828) // Cannot Open
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirmir-software-decode-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let resolver = NativeMediaInputAssetResolverV4(cacheRoot: root.appendingPathComponent("cache"))
        let asset = try await resolver.resolvedAsset(url: source)
        XCTAssertNotNil(OriginalSoftwareMediaContext.associated(with: asset))
        XCTAssertEqual(asset.url.scheme, "mirmir-software-source")

        let readable = try await asset.load(.isReadable)
        let playable = try await asset.load(.isPlayable)
        XCTAssertTrue(readable)
        XCTAssertTrue(playable)

        let tracks = try await asset.load(.tracks)
        XCTAssertEqual(tracks.filter { $0.mediaType == .video }.count, 1)

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
            if frames >= 8 { break }
        }
        XCTAssertGreaterThanOrEqual(frames, 1)
        if reader.status == .failed {
            XCTFail(String(describing: reader.error))
        }
    }
}
