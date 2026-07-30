import CoreMedia
import Foundation
import XCTest
@testable import Mirmir

final class OutputMediaMetadataVerificationTests: XCTestCase {
    func testSessionEmbedsAndReopensExactFinalMirmirIdentity() async throws {
        let fixture = try MediaOutputFixture()
        defer { fixture.remove() }
        let duration = CMTime(value: 1, timescale: 30)
        try await writeOneFrameVideo(
            to: fixture.source,
            resolution: VideoResolution(width: 64, height: 64),
            duration: duration
        )
        let staticMetadata = [
            "com.mirmir.ash.configuration-id": "fixture-configuration",
            "com.mirmir.ash.release-manifest-sha256": String(repeating: "a", count: 64),
            "com.mirmir.release.backend-id": "mps-lanczos",
            "com.mirmir.release.model-assets": "not_required"
        ]
        let template = staticMetadata.merging([
            "com.mirmir.ash.numerical-fallback-count": "0"
        ]) { _, final in final }
        let finalMetadata = staticMetadata.merging([
            "com.mirmir.ash.numerical-fallback-count": "7"
        ]) { _, final in final }
        let pipeline = AVFoundationMediaPipeline(metal: NoopMetalRenderingService())
        let source = try await pipeline.probe(url: fixture.source)
        let session = try await pipeline.beginSession(
            source: source,
            output: OutputProfile(
                url: fixture.destination,
                resolution: VideoResolution(width: 128, height: 128),
                codec: .h264,
                preserveAudio: false,
                timedMetadataTemplate: template
            )
        )
        let nextRecord = try await session.nextSourceFrame()
        let record = try XCTUnwrap(nextRecord)
        let output = try PixelBufferBridge.dequeue(from: session.outputPixelBufferPool)
        try fillNV12(output)
        try await session.appendOutput(pixelBuffer: output, timing: record.timing)
        let endOfStream = try await session.nextSourceFrame()
        XCTAssertNil(endOfStream)

        try await session.finish(finalMetadata: finalMetadata)

        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.destination.path))
        _ = try await OutputMediaVerifier().verify(
            url: fixture.destination,
            expectation: OutputMediaVerificationExpectation(
                resolution: VideoResolution(width: 128, height: 128),
                codec: .h264,
                timing: try makeTimingSnapshot(
                    presentationTime: record.presentationTime,
                    duration: record.duration
                ),
                timedMetadata: finalMetadata
            )
        )
        XCTAssertTrue(fixture.recognizedStagingFiles().isEmpty)
    }

    func testControlledMetadataPolicyRejectsForeignBareAndWhitespaceKeys() throws {
        try MirmirTimedMetadataPolicy.validate([
            "com.mirmir.release.backend-id": "mps-lanczos",
            "com.mirmir.ash.configuration-id": "fixture"
        ])

        for key in [
            "com.mirmir",
            "com.mirmir.",
            "com.mirmirx.release.backend-id",
            "org.example.backend-id",
            "com.mirmir.release.bad key",
            "com.mirmir.release.bad\nkey"
        ] {
            XCTAssertThrowsError(
                try MirmirTimedMetadataPolicy.validate([key: "value"]),
                "Expected controlled metadata-key rejection for \(String(reflecting: key))."
            )
        }
        XCTAssertThrowsError(
            try MirmirTimedMetadataPolicy.validate([
                "com.mirmir.release.backend-id": ""
            ])
        )
    }

    func testSessionRejectsFinalASHIdentityKeyDriftWithoutPublishing() async throws {
        let fixture = try MediaOutputFixture()
        defer { fixture.remove() }
        let duration = CMTime(value: 1, timescale: 30)
        try await writeOneFrameVideo(
            to: fixture.source,
            resolution: VideoResolution(width: 64, height: 64),
            duration: duration
        )
        let pipeline = AVFoundationMediaPipeline(metal: NoopMetalRenderingService())
        let source = try await pipeline.probe(url: fixture.source)
        let session = try await pipeline.beginSession(
            source: source,
            output: OutputProfile(
                url: fixture.destination,
                resolution: VideoResolution(width: 128, height: 128),
                codec: .h264,
                preserveAudio: false,
                timedMetadataTemplate: [
                    "com.mirmir.ash.numerical-fallback-count": "0"
                ]
            )
        )
        let nextRecord = try await session.nextSourceFrame()
        let record = try XCTUnwrap(nextRecord)
        let output = try PixelBufferBridge.dequeue(from: session.outputPixelBufferPool)
        try fillNV12(output)
        try await session.appendOutput(pixelBuffer: output, timing: record.timing)
        let endOfStream = try await session.nextSourceFrame()
        XCTAssertNil(endOfStream)

        do {
            try await session.finish(finalMetadata: [
                "com.mirmir.ash.unexpected": "1"
            ])
            XCTFail("Expected final ASH identity key-closure rejection.")
        } catch let error as MediaPipelineError {
            guard case .outputMetadataMismatch = error else {
                return XCTFail("Unexpected media pipeline error: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        XCTAssertTrue(fixture.recognizedTemporaryFiles().isEmpty)
    }
}
