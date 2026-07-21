import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation
import XCTest
@testable import Mirmir

final class OutputMediaAACIdentityReaderTests: XCTestCase {
    func testAACIdentityReaderRecordsRepeatableCompressedSamples() async throws {
        let fixture = try MediaOutputFixture()
        defer { fixture.remove() }
        let audioURL = fixture.directory.appendingPathComponent("source.m4a")
        try writeAACFixture(to: audioURL)

        let first = try await OutputMediaAACIdentityReader().read(url: audioURL)
        let second = try await OutputMediaAACIdentityReader().read(url: audioURL)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.codec, kAudioFormatMPEG4AAC)
        XCTAssertEqual(first.sampleRate, 48_000)
        XCTAssertEqual(first.channelCount, 2)
        XCTAssertFalse(first.codecConfigurationMagicCookie.isEmpty)
        XCTAssertFalse(first.samples.isEmpty)
        XCTAssertEqual(first.canonicalSHA256.count, 64)
        for sample in first.samples {
            XCTAssertGreaterThan(sample.sampleCount, 0)
            XCTAssertGreaterThan(sample.payloadByteCount, 0)
            XCTAssertEqual(sample.payloadSHA256.count, 64)
        }
    }

    func testAACIdentityCanonicalSHAChangesWithCompressedPayload() async throws {
        let fixture = try MediaOutputFixture()
        defer { fixture.remove() }
        let firstURL = fixture.directory.appendingPathComponent("first.m4a")
        let secondURL = fixture.directory.appendingPathComponent("second.m4a")
        try writeAACFixture(to: firstURL, seed: 0)
        try writeAACFixture(to: secondURL, seed: 11)

        let first = try await OutputMediaAACIdentityReader().read(url: firstURL)
        let second = try await OutputMediaAACIdentityReader().read(url: secondURL)

        XCTAssertEqual(first.codec, second.codec)
        XCTAssertEqual(first.sampleRate, second.sampleRate)
        XCTAssertEqual(first.channelCount, second.channelCount)
        XCTAssertNotEqual(
            first.samples.map(\.payloadSHA256),
            second.samples.map(\.payloadSHA256)
        )
        XCTAssertNotEqual(first.canonicalSHA256, second.canonicalSHA256)
    }

    func testAACIdentityDetectsCodecConfigurationMagicCookieMutation() async throws {
        let fixture = try MediaOutputFixture()
        defer { fixture.remove() }
        let audioURL = fixture.directory.appendingPathComponent("source.m4a")
        try writeAACFixture(to: audioURL)
        let identity = try await OutputMediaAACIdentityReader().read(url: audioURL)
        var mutatedCookie = identity.codecConfigurationMagicCookie
        XCTAssertFalse(mutatedCookie.isEmpty)
        mutatedCookie[mutatedCookie.startIndex] ^= 0x01

        let mutatedIdentity = OutputMediaAACIdentity(
            codec: identity.codec,
            sampleRate: identity.sampleRate,
            channelCount: identity.channelCount,
            trackTimeRange: identity.trackTimeRange,
            samples: identity.samples,
            canonicalSHA256: identity.canonicalSHA256,
            codecConfigurationMagicCookie: mutatedCookie,
            channelLayout: identity.channelLayout
        )

        XCTAssertNotEqual(identity, mutatedIdentity)
        XCTAssertNotEqual(
            canonicalAACHeaderSHA256(
                identity: identity,
                codecConfigurationMagicCookie: identity.codecConfigurationMagicCookie,
                channelLayout: identity.channelLayout
            ),
            canonicalAACHeaderSHA256(
                identity: identity,
                codecConfigurationMagicCookie: mutatedCookie,
                channelLayout: identity.channelLayout
            )
        )
    }

    func testAACIdentityDetectsChannelLayoutMutation() async throws {
        let fixture = try MediaOutputFixture()
        defer { fixture.remove() }
        let audioURL = fixture.directory.appendingPathComponent("source.m4a")
        try writeAACFixture(to: audioURL)
        let identity = try await OutputMediaAACIdentityReader().read(url: audioURL)
        let mutatedLayout: OutputMediaAACChannelLayoutIdentity
        if let channelLayout = identity.channelLayout {
            mutatedLayout = OutputMediaAACChannelLayoutIdentity(
                layoutTag: channelLayout.layoutTag ^ 0x0001_0000,
                channelBitmap: channelLayout.channelBitmap,
                channelDescriptions: channelLayout.channelDescriptions
            )
        } else {
            mutatedLayout = OutputMediaAACChannelLayoutIdentity(
                layoutTag: kAudioChannelLayoutTag_Stereo,
                channelBitmap: 0,
                channelDescriptions: []
            )
        }
        let mutatedIdentity = OutputMediaAACIdentity(
            codec: identity.codec,
            sampleRate: identity.sampleRate,
            channelCount: identity.channelCount,
            trackTimeRange: identity.trackTimeRange,
            samples: identity.samples,
            canonicalSHA256: identity.canonicalSHA256,
            codecConfigurationMagicCookie: identity.codecConfigurationMagicCookie,
            channelLayout: mutatedLayout
        )

        XCTAssertNotEqual(identity, mutatedIdentity)
        XCTAssertNotEqual(
            canonicalAACHeaderSHA256(
                identity: identity,
                codecConfigurationMagicCookie: identity.codecConfigurationMagicCookie,
                channelLayout: identity.channelLayout
            ),
            canonicalAACHeaderSHA256(
                identity: identity,
                codecConfigurationMagicCookie: identity.codecConfigurationMagicCookie,
                channelLayout: mutatedLayout
            )
        )
    }

    func testVerifierRequiresExpectedCompressedAACTrack() async throws {
        let fixture = try MediaOutputFixture()
        defer { fixture.remove() }
        let duration = CMTime(value: 1, timescale: 30)
        let audioURL = fixture.directory.appendingPathComponent("source.m4a")
        try writeAACFixture(to: audioURL)
        let expectedAAC = try await OutputMediaAACIdentityReader().read(url: audioURL)
        try await writeOneFrameVideo(
            to: fixture.source,
            resolution: VideoResolution(width: 64, height: 64),
            duration: duration
        )

        do {
            _ = try await OutputMediaVerifier().verify(
                url: fixture.source,
                expectation: OutputMediaVerificationExpectation(
                    resolution: VideoResolution(width: 64, height: 64),
                    codec: .h264,
                    timing: try makeTimingSnapshot(
                        presentationTime: .zero,
                        duration: duration
                    ),
                    compressedAACIdentity: expectedAAC
                )
            )
            XCTFail("Expected missing compressed AAC rejection.")
        } catch let error as OutputMediaVerificationError {
            guard case .compressedAACMismatch(let reason) = error else {
                return XCTFail("Unexpected verification error: \(error)")
            }
            XCTAssertEqual(reason, "expected one audio track, observed 0")
        }
    }
}

private func canonicalAACHeaderSHA256(
    identity: OutputMediaAACIdentity,
    codecConfigurationMagicCookie: Data,
    channelLayout: OutputMediaAACChannelLayoutIdentity?
) -> String {
    var hasher = OutputMediaAACIdentityReader.CanonicalAACIdentityHasher(
        codec: identity.codec,
        sampleRate: identity.sampleRate,
        channelCount: identity.channelCount,
        codecConfigurationMagicCookie: codecConfigurationMagicCookie,
        channelLayout: channelLayout,
        trackTimeRange: identity.trackTimeRange
    )
    return hasher.finalize(sampleCount: 0)
}

private func writeAACFixture(to url: URL, seed: Int = 0) throws {
    let processingFormat = try XCTUnwrap(
        AVAudioFormat(
            standardFormatWithSampleRate: 48_000,
            channels: 2
        )
    )
    let file = try AVAudioFile(
        forWriting: url,
        settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000
        ],
        commonFormat: .pcmFormatFloat32,
        interleaved: false
    )
    let frameCount: AVAudioFrameCount = 480
    let buffer = try XCTUnwrap(
        AVAudioPCMBuffer(
            pcmFormat: processingFormat,
            frameCapacity: frameCount
        )
    )
    buffer.frameLength = frameCount
    let channels = try XCTUnwrap(buffer.floatChannelData)
    for channelIndex in 0..<Int(processingFormat.channelCount) {
        for frameIndex in 0..<Int(frameCount) {
            let signedValue = (
                (seed + frameIndex * (channelIndex + 3)) % 97
            ) - 48
            channels[channelIndex][frameIndex] = Float(signedValue) / 64
        }
    }
    try file.write(from: buffer)
}
