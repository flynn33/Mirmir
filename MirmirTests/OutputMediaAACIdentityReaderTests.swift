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

    func testMultiTrackReaderBindsOrderedDistinctAACAndTrackProperties()
        async throws {
        let fixture = try MediaOutputFixture()
        defer { fixture.remove() }
        let audioURL = fixture.directory.appendingPathComponent(
            "two-track-audio.mov"
        )
        try await writeTwoTrackAACFixture(to: audioURL)

        let first = try await OutputMediaAACIdentityReader()
            .readAll(url: audioURL)
        let second = try await OutputMediaAACIdentityReader()
            .readAll(url: audioURL)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 2)
        XCTAssertEqual(
            first.map(\.reference),
            [
                OutputMediaTrackReference(
                    mediaType: AVMediaType.audio.rawValue,
                    ordinal: 0
                ),
                OutputMediaTrackReference(
                    mediaType: AVMediaType.audio.rawValue,
                    ordinal: 1
                )
            ]
        )
        XCTAssertEqual(first.map(\.isEnabled), [true, false])
        XCTAssertEqual(first.map(\.languageCode), ["eng", "spa"])
        XCTAssertEqual(
            first.map(\.extendedLanguageTag),
            ["en-US", "es-MX"]
        )
        XCTAssertEqual(
            first.map { $0.metadata.canonicalItems.count },
            [1, 1]
        )
        XCTAssertNotEqual(
            first[0].metadata,
            first[1].metadata
        )
        let compressed = first.map(\.compressedIdentity)
        XCTAssertTrue(
            compressed.allSatisfy {
                $0.codec == kAudioFormatMPEG4AAC
                    && $0.sampleRate == 48_000
                    && $0.channelCount == 2
                    && !$0.samples.isEmpty
                    && !$0.codecConfigurationMagicCookie.isEmpty
            }
        )
        XCTAssertNotEqual(
            compressed[0].samples.map(\.payloadSHA256),
            compressed[1].samples.map(\.payloadSHA256)
        )
        XCTAssertNotEqual(
            compressed[0].canonicalSHA256,
            compressed[1].canonicalSHA256
        )
        XCTAssertNotEqual(
            compressed[0].trackTimeRange,
            compressed[1].trackTimeRange
        )
        XCTAssertNoThrow(
            try OutputMediaVerifier.verifyCompressedAACTracks(
                second,
                expected: first
            )
        )

        do {
            _ = try await OutputMediaAACIdentityReader()
                .read(url: audioURL)
            XCTFail("The compatibility API must remain single-track exact.")
        } catch {
            XCTAssertEqual(
                error as? OutputMediaVerificationError,
                .compressedAACMismatch(
                    reason: "expected one audio track, observed 2"
                )
            )
        }
    }

    func testMultiTrackVerifierRejectsOrderAndTrackPropertyMismatch()
        async throws {
        let fixture = try MediaOutputFixture()
        defer { fixture.remove() }
        let audioURL = fixture.directory.appendingPathComponent(
            "two-track-audio.mov"
        )
        try await writeTwoTrackAACFixture(to: audioURL)
        let expected = try await OutputMediaAACIdentityReader()
            .readAll(url: audioURL)

        XCTAssertThrowsError(
            try OutputMediaVerifier.verifyCompressedAACTracks(
                [expected[1], expected[0]],
                expected: expected
            )
        ) { error in
            guard case .compressedAACMismatch(let reason) =
                    error as? OutputMediaVerificationError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(
                reason.hasPrefix(
                    "audio track 0 ordered reference:"
                ),
                reason
            )
        }

        var changed = expected
        changed[1] = OutputMediaAACTrackIdentity(
            reference: expected[1].reference,
            compressedIdentity:
                expected[1].compressedIdentity,
            isEnabled: true,
            languageCode: expected[1].languageCode,
            extendedLanguageTag:
                expected[1].extendedLanguageTag,
            metadata: expected[1].metadata
        )
        XCTAssertThrowsError(
            try OutputMediaVerifier.verifyCompressedAACTracks(
                changed,
                expected: expected
            )
        ) { error in
            XCTAssertEqual(
                error as? OutputMediaVerificationError,
                .compressedAACMismatch(
                    reason: "audio track 1 enabled state: expected "
                        + "false, observed true"
                )
            )
        }
    }

    func testMultiTrackReaderRepresentsZeroAudioTracksExactly()
        async throws {
        let fixture = try MediaOutputFixture()
        defer { fixture.remove() }
        try await writeOneFrameVideo(
            to: fixture.source,
            resolution: VideoResolution(width: 64, height: 64),
            duration: CMTime(value: 1, timescale: 30)
        )

        let identities = try await OutputMediaAACIdentityReader()
            .readAll(url: fixture.source)

        XCTAssertTrue(identities.isEmpty)
        XCTAssertNoThrow(
            try OutputMediaVerifier.verifyCompressedAACTracks(
                identities,
                expected: []
            )
        )
    }

    func testPipelineProbeInventoriesTwoAACTracksAsExactPassthrough()
        async throws {
        let fixture = try MediaOutputFixture(
            sourceExtension: "mov",
            destinationExtension: "mov"
        )
        defer { fixture.remove() }
        try await writeVideoWithTwoTrackAACFixture(
            to: fixture.source,
            resolution: VideoResolution(width: 64, height: 64)
        )

        let profile = try await AVFoundationMediaPipeline(
            metal: NoopMetalRenderingService()
        ).probe(url: fixture.source)
        let capability = profile.mediaPreservationCapability

        XCTAssertEqual(
            capability.verificationLevel,
            .exactProbe
        )
        XCTAssertEqual(capability.audioTracks.count, 2)
        XCTAssertTrue(capability.auxiliaryTracks.isEmpty)
        XCTAssertTrue(
            capability.audioTracks.allSatisfy {
                $0.formatSubtypes == ["aac "]
                    && $0.sampleRate == 48_000
                    && $0.channelCount == 2
                    && $0.compressedAudioIdentitySHA256?.count == 64
                    && $0.exactTrackIdentitySHA256?.count == 64
                    && $0.support == .exact
            }
        )
        XCTAssertEqual(
            Set(
                capability.audioTracks.compactMap(
                    \.compressedAudioIdentitySHA256
                )
            ).count,
            2
        )
        XCTAssertNil(
            capability.failureReason(
                preserveAudio: true,
                preserveSubtitles: true,
                preserveMetadata: true
            )
        )
    }

    func testPipelineProbeAcceptsVerifiedInterleavedLinearPCM()
        async throws {
        let fixture = try MediaOutputFixture(
            sourceExtension: "mov",
            destinationExtension: "mov"
        )
        defer { fixture.remove() }
        try await writeVideoWithLinearPCMFixture(
            to: fixture.source,
            resolution: VideoResolution(width: 64, height: 64)
        )

        let profile = try await AVFoundationMediaPipeline(
            metal: NoopMetalRenderingService()
        ).probe(url: fixture.source)
        let capability = profile.mediaPreservationCapability
        let audio = try XCTUnwrap(capability.audioTracks.first)

        XCTAssertEqual(capability.audioTracks.count, 1)
        XCTAssertEqual(audio.formatSubtypes, ["lpcm"])
        XCTAssertEqual(audio.sampleRate, 48_000)
        XCTAssertEqual(audio.channelCount, 2)
        XCTAssertNil(audio.compressedAudioIdentitySHA256)
        XCTAssertEqual(
            audio.linearPCMAudioIdentitySHA256?.count,
            64
        )
        XCTAssertEqual(audio.exactTrackIdentitySHA256?.count, 64)
        XCTAssertEqual(audio.support, .exact)
        XCTAssertNil(
            capability.failureReason(
                preserveAudio: true,
                preserveSubtitles: true,
                preserveMetadata: true
            )
        )
    }

    func testLinearPCMValidatorExplainsUnsupportedNonInterleavedVariant()
        throws {
        let stream = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags:
                kAudioFormatFlagIsSignedInteger
                | kAudioFormatFlagIsPacked
                | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 16,
            mReserved: 0
        )

        XCTAssertThrowsError(
            try OutputMediaLinearPCMIdentityReader.validate(
                stream,
                mediaSubtype: kAudioFormatLinearPCM,
                trackOrdinal: 1,
                formatOrdinal: 0
            )
        ) { error in
            guard let pcmError =
                    error as? OutputMediaLinearPCMIdentityError,
                  case .unsupportedRepresentation(
                      let trackOrdinal,
                      let formatOrdinal,
                      let reason,
                      let remediation
                  ) = pcmError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(trackOrdinal, 1)
            XCTAssertEqual(formatOrdinal, 0)
            XCTAssertTrue(reason.contains("non-interleaved"))
            XCTAssertTrue(
                remediation.contains(
                    "Rewrite the track as interleaved Linear PCM"
                )
            )
            XCTAssertTrue(
                pcmError.description.contains("Audio track 2 format 1")
            )
        }
    }

    func testSourceProfileDerivesAudioPresenceFromValidatedExactCount()
        throws {
        let profile = try SourceProfile(
            url: URL(fileURLWithPath: "/tmp/two-audio.mov"),
            resolution: VideoResolution(width: 64, height: 64),
            frameRate: 30,
            durationSeconds: 1,
            estimatedFrameCount: 30,
            codecHint: "avc1",
            audioTrackCount: 2
        )
        XCTAssertEqual(profile.audioTrackCount, 2)
        XCTAssertTrue(profile.hasAudio)
        XCTAssertEqual(profile.audioTrackDescription, "2 audio tracks")

        let legacy = SourceProfile(
            url: URL(fileURLWithPath: "/tmp/legacy-audio.mov"),
            resolution: VideoResolution(width: 64, height: 64),
            frameRate: 30,
            durationSeconds: 1,
            estimatedFrameCount: 30,
            codecHint: "avc1",
            hasAudio: true
        )
        XCTAssertEqual(legacy.audioTrackCount, 1)
        XCTAssertTrue(legacy.hasAudio)
        XCTAssertEqual(legacy.audioTrackDescription, "1 audio track")

        XCTAssertThrowsError(
            try SourceProfile(
                url: URL(fileURLWithPath: "/tmp/invalid-audio.mov"),
                resolution: VideoResolution(width: 64, height: 64),
                frameRate: 30,
                durationSeconds: 1,
                estimatedFrameCount: 30,
                codecHint: "avc1",
                audioTrackCount: -1
            )
        ) { error in
            XCTAssertEqual(
                error as? SourceProfileValidationError,
                .invalidAudioTrackCount(-1)
            )
        }
        XCTAssertEqual(
            MediaPipelineError.unsupportedAudioTrackCount(-1)
                .description,
            "The source reports an invalid audio-track count of -1; "
                + "the count must be zero or greater."
        )
    }

    func testPipelinePreservesLinearPCMASBDTimingAndPayloadEndToEnd()
        async throws {
        let fixture = try MediaOutputFixture(
            sourceExtension: "mov",
            destinationExtension: "mov"
        )
        defer { fixture.remove() }
        try await writeVideoWithLinearPCMFixture(
            to: fixture.source,
            resolution: VideoResolution(width: 64, height: 64)
        )
        let sourceAsset = AVURLAsset(
            url: fixture.source,
            options: [
                AVURLAssetPreferPreciseDurationAndTimingKey: true
            ]
        )
        let sourceAudioTracks = try await sourceAsset.loadTracks(
            withMediaType: .audio
        )
        let sourceAudioTrack = try XCTUnwrap(
            sourceAudioTracks.first
        )
        let expectedIdentity =
            try await OutputMediaLinearPCMIdentityReader.readTrack(
                asset: sourceAsset,
                track: sourceAudioTrack,
                ordinal: 0,
                cancellationCheck: {
                    try Task.checkCancellation()
                }
            )
        XCTAssertEqual(expectedIdentity.formats.count, 1)
        XCTAssertEqual(
            expectedIdentity.formats[0].mediaSubtype,
            kAudioFormatLinearPCM
        )
        XCTAssertEqual(
            expectedIdentity.formats[0].sampleRate,
            48_000
        )
        XCTAssertEqual(
            expectedIdentity.formats[0].channelsPerFrame,
            2
        )
        XCTAssertEqual(expectedIdentity.audioFrameCount, 2_400)
        XCTAssertEqual(
            expectedIdentity.totalPayloadByteCount,
            9_600
        )
        XCTAssertEqual(expectedIdentity.payloadSHA256.count, 64)
        XCTAssertFalse(expectedIdentity.timingRuns.isEmpty)

        let pipeline = AVFoundationMediaPipeline(
            metal: NoopMetalRenderingService()
        )
        let source = try await pipeline.probe(url: fixture.source)
        let session = try await pipeline.beginSession(
            source: source,
            output: OutputProfile(
                url: fixture.destination,
                resolution: VideoResolution(width: 128, height: 128),
                codec: .h264,
                preserveAudio: true,
                preserveMetadata: true
            )
        )
        defer { session.cancel() }
        let renderedFrameCount =
            try await renderAllFrames(session)
        XCTAssertEqual(renderedFrameCount, 1)
        try await session.finish()

        let outputAsset = AVURLAsset(
            url: fixture.destination,
            options: [
                AVURLAssetPreferPreciseDurationAndTimingKey: true
            ]
        )
        let outputAudioTracks = try await outputAsset.loadTracks(
            withMediaType: .audio
        )
        let outputAudioTrack = try XCTUnwrap(
            outputAudioTracks.first
        )
        let actualIdentity =
            try await OutputMediaLinearPCMIdentityReader.readTrack(
                asset: outputAsset,
                track: outputAudioTrack,
                ordinal: 0,
                cancellationCheck: {
                    try Task.checkCancellation()
                }
            )
        XCTAssertEqual(outputAudioTracks.count, 1)
        XCTAssertEqual(actualIdentity, expectedIdentity)
        XCTAssertEqual(actualIdentity.canonicalSHA256.count, 64)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.destination.path
            )
        )
        XCTAssertTrue(fixture.recognizedTemporaryFiles().isEmpty)
    }

    func testPipelineRejectsMP4ForLinearPCMBeforeWriterStarts()
        async throws {
        let fixture = try MediaOutputFixture(
            sourceExtension: "mov",
            destinationExtension: "mp4"
        )
        defer { fixture.remove() }
        try await writeVideoWithLinearPCMFixture(
            to: fixture.source,
            resolution: VideoResolution(width: 64, height: 64)
        )
        let pipeline = AVFoundationMediaPipeline(
            metal: NoopMetalRenderingService()
        )
        let source = try await pipeline.probe(url: fixture.source)
        do {
            _ = try await pipeline.beginSession(
                source: source,
                output: OutputProfile(
                    url: fixture.destination,
                    resolution:
                        VideoResolution(width: 128, height: 128),
                    codec: .h264,
                    preserveAudio: true,
                    preserveMetadata: true
                )
            )
            XCTFail(
                "Linear PCM preservation must reject MP4 before "
                    + "starting the writer."
            )
        } catch let error as MediaPipelineError {
            guard case
                    .outputContainerCannotPreserveLinearPCM(
                        let pathExtension
                    ) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(pathExtension, "mp4")
            XCTAssertTrue(
                error.description.contains(
                    "Select a QuickTime Movie (.mov) destination"
                )
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.destination.path
            )
        )
        XCTAssertTrue(fixture.recognizedTemporaryFiles().isEmpty)
    }

    func testSelectedAACReaderKeepsExactOrdinalWithPCMCapableVerifier()
        async throws {
        let fixture = try MediaOutputFixture(
            sourceExtension: "mov",
            destinationExtension: "mov"
        )
        defer { fixture.remove() }
        try await writeTwoTrackAACFixture(to: fixture.source)
        let asset = AVURLAsset(
            url: fixture.source,
            options: [
                AVURLAssetPreferPreciseDurationAndTimingKey: true
            ]
        )
        let selected =
            try await OutputMediaAACIdentityReader.readTracks(
                asset: asset,
                references: [
                    OutputMediaTrackReference(
                        mediaType: AVMediaType.audio.rawValue,
                        ordinal: 1
                    )
                ],
                cancellationCheck: {
                    try Task.checkCancellation()
                }
            )
        let all = try await OutputMediaAACIdentityReader.readAll(
            asset: asset
        )

        XCTAssertEqual(selected.count, 1)
        XCTAssertEqual(selected[0], all[1])
        XCTAssertEqual(selected[0].reference.ordinal, 1)
    }

    func testPipelinePreservesMixedAACAndLinearPCMTracksEndToEnd()
        async throws {
        let fixture = try MediaOutputFixture(
            sourceExtension: "mov",
            destinationExtension: "mov"
        )
        defer { fixture.remove() }
        try await writeVideoWithAACAndLinearPCMFixture(
            to: fixture.source,
            resolution: VideoResolution(width: 64, height: 64)
        )
        let sourceAsset = AVURLAsset(
            url: fixture.source,
            options: [
                AVURLAssetPreferPreciseDurationAndTimingKey: true
            ]
        )
        let sourceAudioTracks = try await sourceAsset.loadTracks(
            withMediaType: .audio
        )
        XCTAssertEqual(sourceAudioTracks.count, 2)
        let expectedAAC =
            try await OutputMediaAACIdentityReader.readTrack(
                asset: sourceAsset,
                track: sourceAudioTracks[0],
                ordinal: 0,
                cancellationCheck: {
                    try Task.checkCancellation()
                }
            )
        let expectedPCM =
            try await OutputMediaLinearPCMIdentityReader.readTrack(
                asset: sourceAsset,
                track: sourceAudioTracks[1],
                ordinal: 1,
                cancellationCheck: {
                    try Task.checkCancellation()
                }
            )
        let pipeline = AVFoundationMediaPipeline(
            metal: NoopMetalRenderingService()
        )
        let source = try await pipeline.probe(url: fixture.source)
        XCTAssertEqual(source.audioTrackCount, 2)
        XCTAssertTrue(
            source.mediaPreservationCapability.audioTracks
                .allSatisfy { $0.support == .exact }
        )
        let session = try await pipeline.beginSession(
            source: source,
            output: OutputProfile(
                url: fixture.destination,
                resolution: VideoResolution(width: 128, height: 128),
                codec: .h264,
                preserveAudio: true,
                preserveMetadata: true
            )
        )
        defer { session.cancel() }
        let renderedFrameCount =
            try await renderAllFrames(session)
        XCTAssertEqual(renderedFrameCount, 1)
        try await session.finish()

        let outputAsset = AVURLAsset(
            url: fixture.destination,
            options: [
                AVURLAssetPreferPreciseDurationAndTimingKey: true
            ]
        )
        let outputAudioTracks = try await outputAsset.loadTracks(
            withMediaType: .audio
        )
        XCTAssertEqual(outputAudioTracks.count, 2)
        let actualAAC =
            try await OutputMediaAACIdentityReader.readTrack(
                asset: outputAsset,
                track: outputAudioTracks[0],
                ordinal: 0,
                cancellationCheck: {
                    try Task.checkCancellation()
                }
            )
        let actualPCM =
            try await OutputMediaLinearPCMIdentityReader.readTrack(
                asset: outputAsset,
                track: outputAudioTracks[1],
                ordinal: 1,
                cancellationCheck: {
                    try Task.checkCancellation()
                }
            )
        XCTAssertEqual(actualAAC, expectedAAC)
        XCTAssertEqual(actualPCM, expectedPCM)
        XCTAssertTrue(fixture.recognizedTemporaryFiles().isEmpty)
    }

    func testPipelinePreservesTwoOrderedAACTracksEndToEnd()
        async throws {
        let fixture = try MediaOutputFixture(
            sourceExtension: "mov",
            destinationExtension: "mov"
        )
        defer { fixture.remove() }
        let sourceResolution = VideoResolution(
            width: 64,
            height: 64
        )
        let outputResolution = VideoResolution(
            width: 128,
            height: 128
        )
        try await writeVideoWithTwoTrackAACFixture(
            to: fixture.source,
            resolution: sourceResolution
        )
        let expectedTracks = try await OutputMediaAACIdentityReader()
            .readAll(url: fixture.source)
        XCTAssertEqual(expectedTracks.count, 2)
        XCTAssertEqual(
            expectedTracks.map {
                $0.metadata.canonicalItems.count
            },
            [1, 1]
        )

        let telemetry = DefaultASHTelemetryRecorder(
            emitsSignposts: false
        )
        let pipeline = AVFoundationMediaPipeline(
            metal: NoopMetalRenderingService(),
            telemetry: telemetry
        )
        let source = try await pipeline.probe(url: fixture.source)
        XCTAssertTrue(source.hasAudio)
        XCTAssertEqual(source.audioTrackCount, 2)
        let session = try await pipeline.beginSession(
            source: source,
            output: OutputProfile(
                url: fixture.destination,
                resolution: outputResolution,
                codec: .h264,
                preserveAudio: true,
                preserveMetadata: true
            )
        )
        defer { session.cancel() }
        let processedFrameCount =
            try await renderAllFrames(session)
        XCTAssertEqual(
            processedFrameCount,
            1
        )

        try await session.finish()

        let actualTracks = try await OutputMediaAACIdentityReader()
            .readAll(url: fixture.destination)
        XCTAssertNoThrow(
            try OutputMediaVerifier.verifyCompressedAACTracks(
                actualTracks,
                expected: expectedTracks
            )
        )
        XCTAssertEqual(
            actualTracks.map(\.reference),
            expectedTracks.map(\.reference)
        )
        XCTAssertEqual(
            actualTracks.map(\.isEnabled),
            [true, false]
        )
        XCTAssertEqual(
            actualTracks.map(\.languageCode),
            ["eng", "spa"]
        )
        XCTAssertEqual(
            actualTracks.map(\.extendedLanguageTag),
            ["en-US", "es-MX"]
        )
        XCTAssertEqual(
            actualTracks.map(\.metadata),
            expectedTracks.map(\.metadata)
        )
        XCTAssertEqual(
            actualTracks.map {
                $0.compressedIdentity.channelLayout
            },
            expectedTracks.map {
                $0.compressedIdentity.channelLayout
            }
        )
        let expectedAudioEnd = try XCTUnwrap(
            expectedTracks
            .map {
                CMTimeRangeGetEnd(
                    $0.compressedIdentity.trackTimeRange
                )
            }
            .max { CMTimeCompare($0, $1) < 0 }
        )
        let sourceAsset = AVURLAsset(
            url: fixture.source,
            options: [
                AVURLAssetPreferPreciseDurationAndTimingKey: true
            ]
        )
        let sourceVideoTracks = try await sourceAsset.loadTracks(
            withMediaType: .video
        )
        let sourceVideoTrack = try XCTUnwrap(sourceVideoTracks.first)
        let expectedVideoEnd = CMTimeRangeGetEnd(
            try await sourceVideoTrack.load(.timeRange)
        )
        let expectedMediaEnd =
            CMTimeCompare(expectedAudioEnd, expectedVideoEnd) > 0
            ? expectedAudioEnd
            : expectedVideoEnd
        let outputAsset = AVURLAsset(
            url: fixture.destination,
            options: [
                AVURLAssetPreferPreciseDurationAndTimingKey: true
            ]
        )
        let outputDuration = try await outputAsset.load(.duration)
        XCTAssertEqual(
            CMTimeCompare(
                outputDuration,
                expectedMediaEnd
            ),
            0,
            "output duration \(String(describing: outputDuration)) "
                + "did not equal expected media end "
                + "\(String(describing: expectedMediaEnd))"
        )
        let outputVideoTracks = try await outputAsset.loadTracks(
            withMediaType: .video
        )
        let outputVideoTrack = try XCTUnwrap(outputVideoTracks.first)
        let outputVideoEnd = CMTimeRangeGetEnd(
            try await outputVideoTrack.load(.timeRange)
        )
        XCTAssertEqual(
            CMTimeCompare(outputVideoEnd, expectedVideoEnd),
            0,
            "the video endpoint changed while preserving multiple AAC tracks"
        )
        let audioCountObservations = telemetry.snapshot().media.filter {
            [
                "media_probe",
                "reader_writer_started",
                "final_sample_copy_mux_started",
                "final_sample_copy_mux_completed"
            ].contains($0.kind)
        }
        XCTAssertEqual(
            audioCountObservations.map(\.kind),
            [
                "media_probe",
                "reader_writer_started",
                "final_sample_copy_mux_started",
                "final_sample_copy_mux_completed"
            ]
        )
        XCTAssertTrue(
            audioCountObservations.allSatisfy {
                $0.details["audio_track_count"] == "2"
                    || $0.details["preserved_audio_track_count"] == "2"
            }
        )
        XCTAssertTrue(fixture.recognizedTemporaryFiles().isEmpty)
    }

    func testMultiTrackAACMismatchPreventsPublication()
        async throws {
        let fixture = try MediaOutputFixture(
            sourceExtension: "mov",
            destinationExtension: "mov"
        )
        defer { fixture.remove() }
        let sourceResolution = VideoResolution(
            width: 64,
            height: 64
        )
        try await writeVideoWithTwoTrackAACFixture(
            to: fixture.source,
            resolution: sourceResolution
        )
        let pipeline = AVFoundationMediaPipeline(
            metal: NoopMetalRenderingService(),
            outputVerifier: MultiTrackAACMismatchOutputMediaVerifier()
        )
        let source = try await pipeline.probe(url: fixture.source)
        let session = try await pipeline.beginSession(
            source: source,
            output: OutputProfile(
                url: fixture.destination,
                resolution: VideoResolution(width: 128, height: 128),
                codec: .h264,
                preserveAudio: true,
                preserveMetadata: true
            )
        )
        let processedFrameCount =
            try await renderAllFrames(session)
        XCTAssertEqual(
            processedFrameCount,
            1
        )

        do {
            try await session.finish()
            XCTFail("A reopened multi-track mismatch must not publish.")
        } catch let error as MediaPipelineError {
            guard case .outputVerificationFailed(
                _,
                let underlying
            ) = error,
            let verificationError =
                underlying as? OutputMediaVerificationError,
            case .compressedAACMismatch(let reason) =
                verificationError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(
                reason.hasPrefix(
                    "audio track 1 enabled state:"
                ),
                reason
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.destination.path
            )
        )
        XCTAssertTrue(fixture.recognizedTemporaryFiles().isEmpty)
    }
}

private struct MultiTrackAACMismatchOutputMediaVerifier:
    OutputMediaVerifying {
    func verify(
        url: URL,
        expectation: OutputMediaVerificationExpectation
    ) async throws -> OutputMediaVerificationResult {
        guard var expectedTracks =
                expectation.compressedAACTrackIdentities,
              expectedTracks.count == 2 else {
            throw OutputMediaVerificationError.compressedAACMismatch(
                reason: "test verifier expected exactly two ordered "
                    + "AAC track identities"
            )
        }
        let actualTracks = try await OutputMediaAACIdentityReader()
            .readAll(url: url)
        let original = expectedTracks[1]
        expectedTracks[1] = OutputMediaAACTrackIdentity(
            reference: original.reference,
            compressedIdentity: original.compressedIdentity,
            isEnabled: !original.isEnabled,
            languageCode: original.languageCode,
            extendedLanguageTag: original.extendedLanguageTag,
            metadata: original.metadata
        )
        try OutputMediaVerifier.verifyCompressedAACTracks(
            actualTracks,
            expected: expectedTracks
        )
        throw OutputMediaVerificationError.compressedAACMismatch(
            reason: "injected enabled-state mismatch was not detected"
        )
    }
}

private func renderAllFrames(
    _ session: any MediaSession
) async throws -> Int {
    var frameCount = 0
    while let record = try await session.nextSourceFrame() {
        let output = try PixelBufferBridge.dequeue(
            from: session.outputPixelBufferPool
        )
        try fillNV12(output)
        try await session.appendOutput(
            pixelBuffer: output,
            timing: record.timing
        )
        frameCount += 1
    }
    return frameCount
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

private func writeTwoTrackAACFixture(
    to destinationURL: URL
) async throws {
    let directory = destinationURL.deletingLastPathComponent()
    let firstURL = directory.appendingPathComponent(
        "first-\(UUID().uuidString).m4a"
    )
    let secondURL = directory.appendingPathComponent(
        "second-\(UUID().uuidString).m4a"
    )
    defer {
        try? FileManager.default.removeItem(at: firstURL)
        try? FileManager.default.removeItem(at: secondURL)
    }
    try writeAACFixture(
        to: firstURL,
        seed: 7,
        frameCount: 2_400
    )
    try writeAACFixture(
        to: secondURL,
        seed: 43,
        frameCount: 4_800
    )

    let sourceAssets = [firstURL, secondURL].map { url in
        AVURLAsset(
            url: url,
            options: [
                AVURLAssetPreferPreciseDurationAndTimingKey: true
            ]
        )
    }
    var sourceTracks: [AVAssetTrack] = []
    sourceTracks.reserveCapacity(sourceAssets.count)
    for asset in sourceAssets {
        let tracks = try await asset.loadTracks(
            withMediaType: .audio
        )
        let track = try XCTUnwrap(tracks.first)
        sourceTracks.append(track)
    }
    try await writeCompressedTrackFixture(
        assets: sourceAssets,
        tracks: sourceTracks,
        destinationURL: destinationURL
    ) { index, input in
        input.marksOutputTrackAsEnabled = index == 0
        input.languageCode =
            index == 0 ? "eng" : "spa"
        input.extendedLanguageTag =
            index == 0 ? "en-US" : "es-MX"
        input.metadata = [
            multiTrackAACMetadataItem(
                value: index == 0
                    ? "English main"
                    : "Spanish alternate"
            )
        ]
    }
}

private func writeVideoWithTwoTrackAACFixture(
    to destinationURL: URL,
    resolution: VideoResolution
) async throws {
    let directory = destinationURL.deletingLastPathComponent()
    let videoURL = directory.appendingPathComponent(
        "video-\(UUID().uuidString).mov"
    )
    let audioURL = directory.appendingPathComponent(
        "audio-\(UUID().uuidString).mov"
    )
    defer {
        try? FileManager.default.removeItem(at: videoURL)
        try? FileManager.default.removeItem(at: audioURL)
    }
    try await writeOneFrameVideo(
        to: videoURL,
        resolution: resolution,
        duration: CMTime(value: 1, timescale: 30)
    )
    try await writeTwoTrackAACFixture(to: audioURL)

    let videoAsset = AVURLAsset(
        url: videoURL,
        options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: true
        ]
    )
    let audioAsset = AVURLAsset(
        url: audioURL,
        options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: true
        ]
    )
    let videoTracks = try await videoAsset.loadTracks(
        withMediaType: .video
    )
    let audioTracks = try await audioAsset.loadTracks(
        withMediaType: .audio
    )
    let videoTrack = try XCTUnwrap(videoTracks.first)
    XCTAssertEqual(audioTracks.count, 2)
    let tracks = [videoTrack] + audioTracks
    let assets = [videoAsset, audioAsset, audioAsset]

    try await writeCompressedTrackFixture(
        assets: assets,
        tracks: tracks,
        destinationURL: destinationURL
    ) { index, input in
        let sourceTrack = tracks[index]
        if sourceTrack.mediaType == .video {
            input.transform = try await sourceTrack.load(
                .preferredTransform
            )
        } else {
            input.marksOutputTrackAsEnabled =
                try await sourceTrack.load(.isEnabled)
            input.languageCode =
                try await sourceTrack.load(.languageCode)
            input.extendedLanguageTag =
                try await sourceTrack.load(.extendedLanguageTag)
            input.metadata = try await sourceTrack.load(.metadata)
        }
    }
}

private func writeVideoWithLinearPCMFixture(
    to destinationURL: URL,
    resolution: VideoResolution
) async throws {
    let directory = destinationURL.deletingLastPathComponent()
    let videoURL = directory.appendingPathComponent(
        "video-\(UUID().uuidString).mov"
    )
    let audioURL = directory.appendingPathComponent(
        "audio-\(UUID().uuidString).caf"
    )
    defer {
        try? FileManager.default.removeItem(at: videoURL)
        try? FileManager.default.removeItem(at: audioURL)
    }
    try await writeOneFrameVideo(
        to: videoURL,
        resolution: resolution,
        duration: CMTime(value: 1, timescale: 30)
    )
    try writeLinearPCMFixture(to: audioURL)

    let videoAsset = AVURLAsset(
        url: videoURL,
        options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: true
        ]
    )
    let audioAsset = AVURLAsset(
        url: audioURL,
        options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: true
        ]
    )
    let videoTracks = try await videoAsset.loadTracks(
        withMediaType: .video
    )
    let audioTracks = try await audioAsset.loadTracks(
        withMediaType: .audio
    )
    let videoTrack = try XCTUnwrap(videoTracks.first)
    let audioTrack = try XCTUnwrap(audioTracks.first)
    let tracks = [videoTrack, audioTrack]

    try await writeCompressedTrackFixture(
        assets: [videoAsset, audioAsset],
        tracks: tracks,
        destinationURL: destinationURL
    ) { index, input in
        if index == 0 {
            input.transform = try await videoTrack.load(
                .preferredTransform
            )
        }
    }
}

private func writeVideoWithAACAndLinearPCMFixture(
    to destinationURL: URL,
    resolution: VideoResolution
) async throws {
    let directory = destinationURL.deletingLastPathComponent()
    let videoURL = directory.appendingPathComponent(
        "video-\(UUID().uuidString).mov"
    )
    let aacURL = directory.appendingPathComponent(
        "aac-\(UUID().uuidString).m4a"
    )
    let pcmURL = directory.appendingPathComponent(
        "pcm-\(UUID().uuidString).caf"
    )
    defer {
        try? FileManager.default.removeItem(at: videoURL)
        try? FileManager.default.removeItem(at: aacURL)
        try? FileManager.default.removeItem(at: pcmURL)
    }
    try await writeOneFrameVideo(
        to: videoURL,
        resolution: resolution,
        duration: CMTime(value: 1, timescale: 30)
    )
    try writeAACFixture(
        to: aacURL,
        seed: 19,
        frameCount: 2_400
    )
    try writeLinearPCMFixture(
        to: pcmURL,
        frameCount: 2_400
    )

    let assets = [videoURL, aacURL, pcmURL].map {
        AVURLAsset(
            url: $0,
            options: [
                AVURLAssetPreferPreciseDurationAndTimingKey: true
            ]
        )
    }
    let videoTracks = try await assets[0].loadTracks(
        withMediaType: .video
    )
    let aacTracks = try await assets[1].loadTracks(
        withMediaType: .audio
    )
    let pcmTracks = try await assets[2].loadTracks(
        withMediaType: .audio
    )
    let videoTrack = try XCTUnwrap(videoTracks.first)
    let aacTrack = try XCTUnwrap(aacTracks.first)
    let pcmTrack = try XCTUnwrap(pcmTracks.first)
    let tracks = [videoTrack, aacTrack, pcmTrack]

    try await writeCompressedTrackFixture(
        assets: assets,
        tracks: tracks,
        destinationURL: destinationURL
    ) { index, input in
        if index == 0 {
            input.transform = try await videoTrack.load(
                .preferredTransform
            )
        } else {
            input.marksOutputTrackAsEnabled = index == 1
            input.languageCode = index == 1 ? "eng" : "und"
            input.extendedLanguageTag =
                index == 1 ? "en-US" : "und"
        }
    }
}

private func writeLinearPCMFixture(
    to url: URL,
    frameCount: AVAudioFrameCount = 2_400
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
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
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
            let value =
                ((frameIndex * (channelIndex + 5)) % 101) - 50
            channels[channelIndex][frameIndex] =
                Float(value) / 64
        }
    }
    try file.write(from: buffer)
}

private func writeCompressedTrackFixture(
    assets: [AVURLAsset],
    tracks: [AVAssetTrack],
    destinationURL: URL,
    configureInput:
        (Int, AVAssetWriterInput) async throws -> Void
) async throws {
    guard !tracks.isEmpty, assets.count == tracks.count else {
        throw MediaTestFailure.invalidFrameCount
    }
    var formats: [CMFormatDescription] = []
    var timeRanges: [CMTimeRange] = []
    formats.reserveCapacity(tracks.count)
    timeRanges.reserveCapacity(tracks.count)
    for track in tracks {
        let trackFormats = try await track.load(.formatDescriptions)
        formats.append(try XCTUnwrap(trackFormats.first))
        timeRanges.append(try await track.load(.timeRange))
    }

    var readers: [AVAssetReader] = []
    var outputs: [AVAssetReaderTrackOutput] = []
    readers.reserveCapacity(tracks.count)
    outputs.reserveCapacity(tracks.count)
    for index in tracks.indices {
        let reader = try AVAssetReader(asset: assets[index])
        let output = AVAssetReaderTrackOutput(
            track: tracks[index],
            outputSettings: nil
        )
        guard reader.canAdd(output) else {
            throw MediaTestFailure.cannotAddReaderOutput
        }
        reader.add(output)
        readers.append(reader)
        outputs.append(output)
    }

    let writer = try AVAssetWriter(
        url: destinationURL,
        fileType: .mov
    )
    var inputs: [AVAssetWriterInput] = []
    inputs.reserveCapacity(tracks.count)
    for index in tracks.indices {
        let input = AVAssetWriterInput(
            mediaType: tracks[index].mediaType,
            outputSettings: nil,
            sourceFormatHint: formats[index]
        )
        input.expectsMediaDataInRealTime = false
        try await configureInput(index, input)
        guard writer.canAdd(input) else {
            throw MediaTestFailure.cannotAddWriterInput
        }
        writer.add(input)
        inputs.append(input)
    }
    guard readers.allSatisfy({ $0.startReading() }) else {
        throw MediaTestFailure.cannotStartReader
    }
    guard writer.startWriting() else {
        throw MediaTestFailure.cannotStartWriter
    }
    writer.startSession(atSourceTime: .zero)

    var finished = Array(
        repeating: false,
        count: inputs.count
    )
    while finished.contains(false) {
        var madeProgress = false
        for index in inputs.indices
        where !finished[index] && inputs[index].isReadyForMoreMediaData {
            if let sample = outputs[index].copyNextSampleBuffer() {
                guard inputs[index].append(sample) else {
                    throw MediaTestFailure.appendFailed
                }
            } else {
                inputs[index].markAsFinished()
                finished[index] = true
                guard readers[index].status == .completed else {
                    throw MediaTestFailure.readerFailed
                }
            }
            madeProgress = true
        }
        if !madeProgress {
            try await Task.sleep(for: .milliseconds(1))
        }
    }
    let sessionEnd = timeRanges
        .map(CMTimeRangeGetEnd)
        .max { CMTimeCompare($0, $1) < 0 }
        ?? .zero
    writer.endSession(atSourceTime: sessionEnd)
    await writer.finishWriting()
    guard writer.status == .completed else {
        throw MediaTestFailure.writerFailed
    }
}

private func multiTrackAACMetadataItem(
    value: String
) -> AVMetadataItem {
    let item = AVMutableMetadataItem()
    item.identifier = .commonIdentifierDescription
    item.value = value as NSString
    item.dataType = kCMMetadataBaseDataType_UTF8 as String
    return item
}

// swiftlint:enable file_length
