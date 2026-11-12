import AVFoundation
import XCTest
@testable import Mirmir

final class SoftwarePresentationThumbnailV4Tests: XCTestCase {
    func testVP9WebMPresentationThumbnail() async throws {
        try await assertSoftwarePresentationThumbnail(
            resource: "universal-vp9-webm", ext: "webm"
        )
    }

    func testWMVASFPresentationThumbnail() async throws {
        try await assertSoftwarePresentationThumbnail(
            resource: "universal-wmv-asf", ext: "asf"
        )
    }

    func testH264MatroskaRemuxPresentationThumbnail() async throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "universal-h264-mkv", withExtension: "mkv"
        ))
        // presentationAsset uses the shared resolver; keep processing on the same actor.
        let processing = try await NativeMediaInputAssetResolverV4.asset(url: source)
        let presentation = try await NativeMediaInputAssetResolverV4.presentationAsset(url: source)
        XCTAssertNil(OriginalSoftwareMediaContext.associated(with: processing))
        XCTAssertNil(SoftwareVirtualCarrier.presentationPolicy(in: presentation))
        XCTAssertEqual(presentation.url.pathExtension.lowercased(), "mov")
        XCTAssertEqual(presentation.url, processing.url)

        let generator = AVAssetImageGenerator(asset: presentation)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 360)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let result = try await generator.image(at: .zero)
        XCTAssertGreaterThan(result.image.width, 0)
        XCTAssertGreaterThan(result.image.height, 0)
        // Remuxed fixture may or may not qualify for the bounded signal-RGB converter;
        // UI falls back to the generator image either way.
        _ = try await NativeThumbnailSignalConverterV4.image(
            asset: presentation,
            at: result.actualTime,
            size: CGSize(width: result.image.width, height: result.image.height)
        )
    }

    private func assertSoftwarePresentationThumbnail(resource: String, ext: String) async throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: resource, withExtension: ext
        ))
        let processing = try await NativeMediaInputAssetResolverV4.asset(url: source)
        XCTAssertNotNil(OriginalSoftwareMediaContext.associated(with: processing))

        let presentation = try await NativeMediaInputAssetResolverV4.presentationAsset(url: source)
        XCTAssertEqual(presentation.url.scheme, "mirmir-software-presentation")
        XCTAssertNotNil(SoftwareVirtualCarrier.presentationPolicy(in: presentation))
        XCTAssertTrue(SoftwareVirtualCarrier.presentation(presentation, belongsTo: processing))

        let time = try XCTUnwrap(
            try SoftwareVirtualCarrier.presentationFrameTime(in: presentation, preferredSeconds: 0)
        )
        let generator = AVAssetImageGenerator(asset: presentation)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 360)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let result = try await generator.image(at: time)
        XCTAssertGreaterThan(result.image.width, 0)
        XCTAssertGreaterThan(result.image.height, 0)
        // Software presentation is already display BGRA; native signal converter must not claim it.
        let converted = try await NativeThumbnailSignalConverterV4.image(
            asset: presentation,
            at: result.actualTime,
            size: CGSize(width: result.image.width, height: result.image.height)
        )
        XCTAssertNil(converted)
    }
}
