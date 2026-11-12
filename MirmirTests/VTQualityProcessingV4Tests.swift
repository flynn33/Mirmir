import AVFoundation
import CoreMedia
import VideoToolbox
import XCTest
@testable import Mirmir

/// Focused physical quality-processing regressions. Historical Ready+`-19730`
/// hosts advertised availability then processed zero frames; admission now
/// probes `VTFrameProcessor.startSession` before claiming Available.
final class VTQualityProcessingV4Tests: XCTestCase {
    func testReadyQualityModelRequiresStartableSessionBeforeAvailability() async throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Quality VideoToolbox requires macOS 26+")
        }
        guard VTSuperResolutionScalerConfiguration.isSupported else {
            throw XCTSkip("VTSuperResolutionScalerConfiguration.isSupported is false on this host")
        }
        guard let configuration = VTSuperResolutionScalerConfiguration(
            frameWidth: 256,
            frameHeight: 144,
            scaleFactor: 4,
            inputType: .video,
            usePrecomputedFlow: false,
            qualityPrioritization: .normal,
            revision: VTSuperResolutionScalerConfiguration.defaultRevision
        ) else {
            throw XCTSkip("VideoToolbox rejected the representative quality configuration")
        }

        let fixtures = try TemporaryFixtureDirectory()
        defer { fixtures.remove() }
        let input = fixtures.url(for: "vt-quality-admission.mov")
        try await VideoProbeFixtureFactory.makeVideo(
            at: input, transform: .identity, width: 256, height: 144
        )
        let source = try await VideoProbe().probe(url: input)
        let availability = await UpscaleBackendCatalog.live().availability(
            for: .videoToolboxSuperResolutionQuality,
            source: source,
            targetSize: CGSize(width: 1024, height: 576),
            environment: .current()
        )

        switch configuration.configurationModelStatus {
        case .ready:
            if let reason = VTQualitySessionAdmissionV4.startSessionFailure(configuration) {
                guard case .unavailable(let reported) = availability else {
                    return XCTFail(
                        "Ready models that fail startSession must not advertise Available; observed \(availability.statusText)"
                    )
                }
                XCTAssertEqual(reported, reason)
            } else {
                XCTAssertEqual(availability, .available, availability.statusText)
            }
        case .downloadRequired, .downloading:
            XCTAssertTrue(
                availability.isSelectable,
                "Downloadable models remain selectable; observed \(availability.statusText)"
            )
        @unknown default:
            XCTFail("Unknown quality model status \(configuration.configurationModelStatus.rawValue)")
        }
    }

    func testPhysicalQualityProcessingProducesFramesWhenAvailable() async throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Quality VideoToolbox requires macOS 26+")
        }

        let fixtures = try TemporaryFixtureDirectory()
        defer { fixtures.remove() }
        let input = fixtures.url(for: "vt-quality-input.mov")
        let output = fixtures.url(for: "vt-quality-output.mov")
        try await VideoProbeFixtureFactory.makeVideo(
            at: input, transform: .identity, width: 256, height: 144
        )
        let source = try await VideoProbe().probe(url: input)
        let availability = await UpscaleBackendCatalog.live().availability(
            for: .videoToolboxSuperResolutionQuality,
            source: source,
            targetSize: CGSize(width: 1024, height: 576),
            environment: .current()
        )

        switch availability {
        case .available:
            let result = try await UpscaleCoordinator().process(
                UpscaleRequest(
                    inputURL: input,
                    outputURL: output,
                    backendID: .videoToolboxSuperResolutionQuality,
                    targetWidth: 1024,
                    targetHeight: 576,
                    outputCodec: .h264,
                    preserveAudio: false,
                    overwriteExistingFile: false
                ),
                progress: { _ in }
            )
            XCTAssertEqual(result.actualBackendID, .videoToolboxSuperResolutionQuality)
            XCTAssertEqual(result.processedFrameCount, 3)
            XCTAssertGreaterThan(result.processedFrameCount, 0)
            XCTAssertEqual(result.encodedWidth, 1024)
            XCTAssertEqual(result.encodedHeight, 576)
            let observed = try await VideoProbe().probe(url: output)
            XCTAssertEqual(observed.geometry.encodedSize, CGSize(width: 1024, height: 576))
            XCTAssertEqual(CMTimeCompare(observed.duration, source.duration), 0)
        case .modelDownloadRequired:
            throw XCTSkip(
                "Apple quality model is not Ready on this host; fresh-download gates remain opt-in."
            )
        case .unavailable(let reason):
            // Covered physical hosts with a Ready+startable model must not land here.
            // Guests that fail startSession with -19730 correctly report unavailable.
            throw XCTSkip("Quality backend unavailable: \(reason.userFacingDescription)")
        }
    }
}
