import AVFoundation
import AudioToolbox
import CoreMedia
import CryptoKit
import Foundation
import XCTest
@testable import Mirmir

// AAC identity scenarios share compressed-sample fixture helpers.
// swiftlint:disable file_length

// Exact AAC header, packet, and corruption cases share one fixture lifecycle.
// swiftlint:disable:next type_body_length
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
            XCTAssertEqual(sample.sampleCount, 1)
            XCTAssertGreaterThan(sample.payloadByteCount, 0)
            XCTAssertEqual(sample.payloadSHA256.count, 64)
        }
    }

    func testAACIdentityReaderPropagatesCancellationDuringSampleScan()
        async throws {
        let fixture = try MediaOutputFixture()
        defer { fixture.remove() }
        let audioURL = fixture.directory.appendingPathComponent("source.m4a")
        try writeAACFixture(to: audioURL)
        let cancellation = VerificationCancellationProbe(
            cancellationCheckNumber: 10
        )

        do {
            _ = try await OutputMediaAACIdentityReader().read(
                url: audioURL,
                cancellationCheck: { @Sendable in
                    try cancellation.check()
                }
            )
            XCTFail("Expected cancellation during compressed AAC scanning.")
        } catch is CancellationError {
            XCTAssertEqual(cancellation.checkCount, 10)
        }
    }

    func testAccessUnitIdentityIsStableAcrossSampleBufferRegroupingAndTimeScales()
        throws {
        let payloads = [
            Data([0x11, 0x90, 0x01]),
            Data([0x22, 0x02, 0x03, 0x04]),
            Data([0x33, 0x05]),
            Data([0x44, 0x06, 0x07, 0x08, 0x09])
        ]
        let sourceTimings = makeAACTimings(
            count: payloads.count,
            durationValue: 1_024,
            timescale: 48_000
        )
        let regroupedTimings = makeAACTimings(
            count: payloads.count,
            durationValue: 2_048,
            timescale: 96_000
        )
        let sourceBuffer = try makeCompressedSampleBuffer(
            payloads: payloads,
            timings: sourceTimings
        )
        let firstRegroupedBuffer = try makeCompressedSampleBuffer(
            payloads: Array(payloads[0...1]),
            timings: Array(regroupedTimings[0...1])
        )
        let secondRegroupedBuffer = try makeCompressedSampleBuffer(
            payloads: Array(payloads[2...3]),
            timings: Array(regroupedTimings[2...3])
        )

        let sourceAccessUnits = try OutputMediaAACIdentityReader.accessUnits(
            from: sourceBuffer,
            startingAt: 0
        )
        let regroupedAccessUnits =
            try OutputMediaAACIdentityReader.accessUnits(
                from: firstRegroupedBuffer,
                startingAt: 0
            )
            + OutputMediaAACIdentityReader.accessUnits(
                from: secondRegroupedBuffer,
                startingAt: 2
            )
        XCTAssertEqual(
            sourceAccessUnits.map(\.identity),
            regroupedAccessUnits.map(\.identity)
        )
        XCTAssertEqual(
            sourceAccessUnits.map(\.payload),
            regroupedAccessUnits.map(\.payload)
        )
        XCTAssertTrue(sourceAccessUnits.allSatisfy { $0.identity.sampleCount == 1 })

        let sourceIdentity = makeAACIdentity(
            accessUnits: sourceAccessUnits,
            trackTimeRange: CMTimeRange(
                start: CMTime(value: 0, timescale: 1),
                duration: CMTime(value: 4_096, timescale: 48_000)
            )
        )
        let regroupedIdentity = makeAACIdentity(
            accessUnits: regroupedAccessUnits,
            trackTimeRange: CMTimeRange(
                start: CMTime(value: 0, timescale: 96_000),
                duration: CMTime(value: 8_192, timescale: 96_000)
            )
        )

        XCTAssertEqual(sourceIdentity.canonicalSHA256, regroupedIdentity.canonicalSHA256)
        XCTAssertNoThrow(
            try OutputMediaVerifier.verifyCompressedAAC(
                regroupedIdentity,
                expected: sourceIdentity
            )
        )
    }

    func testAccessUnitExtractionRejectsIncompletePayloadPartition() throws {
        let timings = makeAACTimings(
            count: 2,
            durationValue: 1_024,
            timescale: 48_000
        )
        let sampleBuffer = try makeCompressedSampleBuffer(
            payloads: [Data([0x01, 0x02]), Data([0x03, 0x04])],
            timings: timings,
            trailingPayload: Data([0xff])
        )

        XCTAssertThrowsError(
            try OutputMediaAACIdentityReader.accessUnits(
                from: sampleBuffer,
                startingAt: 0
            )
        ) { error in
            XCTAssertEqual(
                error as? OutputMediaVerificationError,
                .compressedAACMismatch(
                    reason: "compressed sample payload partition is 4 bytes; "
                        + "block buffer contains 5 bytes"
                )
            )
        }
    }

    func testVerifierRejectsSameSizeAccessUnitPayloadMutation() throws {
        let sourcePayloads = [
            Data([0x10, 0x20, 0x30]),
            Data([0x40, 0x50, 0x60])
        ]
        let mutatedPayloads = [
            sourcePayloads[0],
            Data([0x40, 0x51, 0x60])
        ]
        let timings = makeAACTimings(
            count: sourcePayloads.count,
            durationValue: 1_024,
            timescale: 48_000
        )
        let sourceBuffer = try makeCompressedSampleBuffer(
            payloads: sourcePayloads,
            timings: timings
        )
        let mutatedBuffer = try makeCompressedSampleBuffer(
            payloads: mutatedPayloads,
            timings: timings
        )
        let trackRange = CMTimeRange(
            start: .zero,
            duration: CMTime(value: 2_048, timescale: 48_000)
        )
        let sourceIdentity = makeAACIdentity(
            accessUnits: try OutputMediaAACIdentityReader.accessUnits(
                from: sourceBuffer,
                startingAt: 0
            ),
            trackTimeRange: trackRange
        )
        let mutatedIdentity = makeAACIdentity(
            accessUnits: try OutputMediaAACIdentityReader.accessUnits(
                from: mutatedBuffer,
                startingAt: 0
            ),
            trackTimeRange: trackRange
        )

        XCTAssertThrowsError(
            try OutputMediaVerifier.verifyCompressedAAC(
                mutatedIdentity,
                expected: sourceIdentity
            )
        ) { error in
            guard case .compressedAACMismatch(let reason) =
                    error as? OutputMediaVerificationError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(
                reason.hasPrefix("access unit 1 payload SHA-256:"),
                reason
            )
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
        XCTAssertEqual(
            first.codecConfigurationMagicCookie,
            second.codecConfigurationMagicCookie
        )
        XCTAssertNotEqual(
            first.samples.map(\.payloadSHA256),
            second.samples.map(\.payloadSHA256)
        )
        XCTAssertNotEqual(first.canonicalSHA256, second.canonicalSHA256)
        XCTAssertThrowsError(
            try OutputMediaVerifier.verifyCompressedAAC(
                second,
                expected: first
            )
        ) { error in
            guard case .compressedAACMismatch(let reason) =
                    error as? OutputMediaVerificationError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(reason.contains("payload"), reason)
        }
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
        XCTAssertThrowsError(
            try OutputMediaVerifier.verifyCompressedAAC(
                mutatedIdentity,
                expected: identity
            )
        ) { error in
            XCTAssertEqual(
                error as? OutputMediaVerificationError,
                .compressedAACMismatch(
                    reason: "codec configuration magic cookie: expected "
                        + dataIdentityDescriptionForTest(
                            identity.codecConfigurationMagicCookie
                        )
                        + ", observed "
                        + dataIdentityDescriptionForTest(mutatedCookie)
                )
            )
        }
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

private func makeAACTimings(
    count: Int,
    durationValue: Int64,
    timescale: CMTimeScale
) -> [CMSampleTimingInfo] {
    (0..<count).map { index in
        CMSampleTimingInfo(
            duration: CMTime(value: durationValue, timescale: timescale),
            presentationTimeStamp: CMTime(
                value: durationValue * Int64(index),
                timescale: timescale
            ),
            decodeTimeStamp: .invalid
        )
    }
}

private func makeCompressedSampleBuffer(
    payloads: [Data],
    timings: [CMSampleTimingInfo],
    trailingPayload: Data = Data()
) throws -> CMSampleBuffer {
    XCTAssertFalse(payloads.isEmpty)
    XCTAssertEqual(payloads.count, timings.count)
    var combinedPayload = payloads.reduce(into: Data()) { partialResult, payload in
        partialResult.append(payload)
    }
    combinedPayload.append(trailingPayload)
    var blockBuffer: CMBlockBuffer?
    let blockStatus = CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault,
        memoryBlock: nil,
        blockLength: combinedPayload.count,
        blockAllocator: kCFAllocatorDefault,
        customBlockSource: nil,
        offsetToData: 0,
        dataLength: combinedPayload.count,
        flags: 0,
        blockBufferOut: &blockBuffer
    )
    XCTAssertEqual(blockStatus, kCMBlockBufferNoErr)
    let resolvedBlockBuffer = try XCTUnwrap(blockBuffer)
    let copyStatus = combinedPayload.withUnsafeBytes { bytes -> OSStatus in
        guard let source = bytes.baseAddress else {
            return kCMBlockBufferBadPointerParameterErr
        }
        return CMBlockBufferReplaceDataBytes(
            with: source,
            blockBuffer: resolvedBlockBuffer,
            offsetIntoDestination: 0,
            dataLength: combinedPayload.count
        )
    }
    XCTAssertEqual(copyStatus, kCMBlockBufferNoErr)

    var mutableTimings = timings
    var sampleSizes = payloads.map(\.count)
    var sampleBuffer: CMSampleBuffer?
    let sampleStatus = CMSampleBufferCreateReady(
        allocator: kCFAllocatorDefault,
        dataBuffer: resolvedBlockBuffer,
        formatDescription: nil,
        sampleCount: payloads.count,
        sampleTimingEntryCount: mutableTimings.count,
        sampleTimingArray: &mutableTimings,
        sampleSizeEntryCount: sampleSizes.count,
        sampleSizeArray: &sampleSizes,
        sampleBufferOut: &sampleBuffer
    )
    XCTAssertEqual(sampleStatus, noErr)
    return try XCTUnwrap(sampleBuffer)
}

private func makeAACIdentity(
    accessUnits: [OutputMediaAACIdentityReader.AccessUnit],
    trackTimeRange: CMTimeRange
) -> OutputMediaAACIdentity {
    let cookie = Data([0x11, 0x90])
    let channelLayout = OutputMediaAACChannelLayoutIdentity(
        layoutTag: kAudioChannelLayoutTag_Stereo,
        channelBitmap: 0,
        channelDescriptions: []
    )
    var hasher = OutputMediaAACIdentityReader.CanonicalAACIdentityHasher(
        codec: kAudioFormatMPEG4AAC,
        sampleRate: 48_000,
        channelCount: 2,
        codecConfigurationMagicCookie: cookie,
        channelLayout: channelLayout,
        trackTimeRange: trackTimeRange
    )
    for (index, accessUnit) in accessUnits.enumerated() {
        hasher.append(
            sample: accessUnit.identity,
            payload: accessUnit.payload,
            index: index
        )
    }
    return OutputMediaAACIdentity(
        codec: kAudioFormatMPEG4AAC,
        sampleRate: 48_000,
        channelCount: 2,
        trackTimeRange: trackTimeRange,
        samples: accessUnits.map(\.identity),
        canonicalSHA256: hasher.finalize(sampleCount: accessUnits.count),
        codecConfigurationMagicCookie: cookie,
        channelLayout: channelLayout
    )
}

private func dataIdentityDescriptionForTest(_ data: Data) -> String {
    let digest = SHA256.hash(data: data).map {
        String(format: "%02x", $0)
    }.joined()
    return "bytes=\(data.count),sha256=\(digest)"
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

func writeAACFixture(
    to url: URL,
    seed: Int = 0,
    frameCount: AVAudioFrameCount = 480
) throws {
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

// swiftlint:enable file_length
