import AVFoundation
import AudioToolbox
import CoreMedia
import CoreVideo
import Foundation
import os.lock
@testable import Mirmir

enum R03ProductQualificationMediaTestError: Error, Equatable {
    case invalidFixture(String)
    case mediaFailure(String)
    case nativeMPSUnavailable(String)
    case sessionCreationFailed(String)
    case frameProcessingFailed(sequenceNumber: Int, reason: String)
}

struct R03ProductQualificationMediaFrameSpec: Equatable {
    let sequenceNumber: Int
    let presentationTime: CMTime
    let duration: CMTime
    let metadataIdentity: String
    let generatedContentSHA256: String

    var inputTokenIdentity: String {
        "r03-v2-media-transaction.token-\(sequenceNumber)"
    }
}

enum R03ProductQualificationMediaFixture {
    static let id = "r03-v2-media-transaction-2x"
    static let sourceResolution = VideoResolution(width: 1_920, height: 1_080)
    static let targetResolution = VideoResolution(width: 3_840, height: 2_160)
    static let seed = 303
    static let audioSampleRate = 48_000
    static let audioChannelCount = 2
    static let audioSampleFrames = 480
    static let audioPCMSHA256 =
        "d9c0cdd3c0a79ff8fce1ae71b1e00ee8047de3243d6403b73d3d53cf6094b06a"
    private static let framePayloadSHA256 = [
        "5eb9ebee68ffa7332ead8ed91af4223ab1ecd14eca9d4accde36d06fdfc9af4c",
        "559a50c0d3c8b0d4dd615b55a6c8ea7a2da99a48e1fbfb3487de9f8f7ad50647",
        "8b93136825170d78f9ece191703ed79bfa54ebfceebce748e903cf41df7da152"
    ]
    static let frames = (0..<3).map { sequenceNumber in
        R03ProductQualificationMediaFrameSpec(
            sequenceNumber: sequenceNumber,
            presentationTime: CMTime(
                value: Int64(sequenceNumber * 1_001),
                timescale: 30_000
            ),
            duration: CMTime(value: 1_001, timescale: 30_000),
            metadataIdentity: "r03-v2-media-transaction.frame-\(sequenceNumber)",
            generatedContentSHA256: framePayloadSHA256[sequenceNumber]
        )
    }
}

struct R03ProductQualificationMediaFiles {
    let directory: URL
    let source: URL
    let audioScratch: URL
    let destination: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mirmir-r03-product-media-\(UUID().uuidString)",
            isDirectory: true
        )
        source = directory.appendingPathComponent("source-1080p.mp4")
        audioScratch = directory.appendingPathComponent("source-aac.m4a")
        destination = directory.appendingPathComponent("mps-lanczos-2160p.mp4")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    func partialFiles() -> [URL] {
        let baseName = destination.deletingPathExtension().lastPathComponent
        return ((try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []).filter {
            $0.lastPathComponent.hasPrefix(".\(baseName).mirmir-")
                && $0.lastPathComponent.contains(".partial")
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

enum R03PQMediaFixtureWriter {
    private static let readinessTimeout: Duration = .seconds(10)
    private static let readinessPollInterval: Duration = .milliseconds(2)

    static func write(sourceURL: URL, audioScratchURL: URL) async throws {
        guard R03ProductQualificationMediaFixture.sourceResolution == .p1080,
              R03ProductQualificationMediaFixture.targetResolution == .p2160,
              R03ProductQualificationMediaFixture.frames.count == 3 else {
            throw R03ProductQualificationMediaTestError.invalidFixture(
                "canonical dimensions or frame count"
            )
        }
        let pcm = try R02FixtureGenerators.pcmS16LEBytes(
            sampleFrames: R03ProductQualificationMediaFixture.audioSampleFrames,
            channelCount: R03ProductQualificationMediaFixture.audioChannelCount,
            seed: R03ProductQualificationMediaFixture.seed
        )
        guard R02FixtureGenerators.sha256Hex(pcm)
                == R03ProductQualificationMediaFixture.audioPCMSHA256 else {
            throw R03ProductQualificationMediaTestError.invalidFixture(
                "deterministic PCM identity"
            )
        }
        try writeAAC(pcm: pcm, to: audioScratchURL)
        try await muxVideoAndAAC(
            audioURL: audioScratchURL,
            destinationURL: sourceURL
        )
    }

    private static func writeAAC(pcm: Data, to url: URL) throws {
        let sampleFrames = R03ProductQualificationMediaFixture.audioSampleFrames
        let channelCount = R03ProductQualificationMediaFixture.audioChannelCount
        guard let processingFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(R03ProductQualificationMediaFixture.audioSampleRate),
            channels: AVAudioChannelCount(channelCount),
            interleaved: true
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: processingFormat,
            frameCapacity: AVAudioFrameCount(sampleFrames)
        ), let channels = buffer.int16ChannelData else {
            throw R03ProductQualificationMediaTestError.mediaFailure(
                "unable to allocate deterministic PCM"
            )
        }
        let expectedByteCount = sampleFrames * channelCount * MemoryLayout<Int16>.size
        guard pcm.count == expectedByteCount else {
            throw R03ProductQualificationMediaTestError.invalidFixture(
                "PCM byte count \(pcm.count), expected \(expectedByteCount)"
            )
        }
        buffer.frameLength = AVAudioFrameCount(sampleFrames)
        pcm.withUnsafeBytes { bytes in
            if let source = bytes.baseAddress {
                memcpy(channels[0], source, pcm.count)
            }
        }
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: R03ProductQualificationMediaFixture.audioSampleRate,
                AVNumberOfChannelsKey: channelCount,
                AVEncoderBitRateKey: 128_000
            ],
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )
        try file.write(from: buffer)
    }

    // The source materializer is kept contiguous so compressed-audio passthrough
    // and writer cleanup remain auditable in exact execution order.
    // swiftlint:disable cyclomatic_complexity function_body_length
    private static func muxVideoAndAAC(
        audioURL: URL,
        destinationURL: URL
    ) async throws {
        let audioAsset = AVURLAsset(
            url: audioURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let audioTracks = try await audioAsset.loadTracks(withMediaType: .audio)
        guard audioTracks.count == 1, let audioTrack = audioTracks.first else {
            throw R03ProductQualificationMediaTestError.mediaFailure(
                "deterministic AAC source did not contain exactly one track"
            )
        }
        let audioFormats = try await audioTrack.load(.formatDescriptions)
        guard let audioFormat = audioFormats.first,
              CMFormatDescriptionGetMediaSubType(audioFormat) == kAudioFormatMPEG4AAC else {
            throw R03ProductQualificationMediaTestError.mediaFailure(
                "deterministic AAC source had no AAC format description"
            )
        }
        let reader = try AVAssetReader(asset: audioAsset)
        let audioOutput = AVAssetReaderTrackOutput(
            track: audioTrack,
            outputSettings: nil
        )
        audioOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(audioOutput) else {
            throw R03ProductQualificationMediaTestError.mediaFailure(
                "reader rejected compressed AAC"
            )
        }
        reader.add(audioOutput)

        let writer = try AVAssetWriter(url: destinationURL, fileType: .mp4)
        writer.movieTimeScale = 30_000
        let videoInput = makeVideoInput()
        let adaptor = makeVideoAdaptor(videoInput: videoInput)
        let audioInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: nil,
            sourceFormatHint: audioFormat
        )
        audioInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput), writer.canAdd(audioInput) else {
            throw R03ProductQualificationMediaTestError.mediaFailure(
                "writer rejected deterministic video or AAC input"
            )
        }
        writer.add(videoInput)
        writer.add(audioInput)

        var completedWriting = false
        defer {
            if !completedWriting {
                if reader.status == .reading {
                    reader.cancelReading()
                }
                if writer.status == .writing {
                    writer.cancelWriting()
                }
            }
        }
        guard reader.startReading() else {
            throw mediaFailure(reader.error, fallback: "compressed AAC reader did not start")
        }
        guard writer.startWriting() else {
            throw mediaFailure(writer.error, fallback: "1080p source writer did not start")
        }
        writer.startSession(atSourceTime: .zero)

        for frame in R03ProductQualificationMediaFixture.frames {
            try await waitUntilReady(videoInput, writer: writer, name: "video")
            let payload = try R02FixtureGenerators.nv12FrameBytes(
                width: R03ProductQualificationMediaFixture.sourceResolution.width,
                height: R03ProductQualificationMediaFixture.sourceResolution.height,
                seed: R03ProductQualificationMediaFixture.seed,
                sequenceNumber: frame.sequenceNumber
            )
            guard R02FixtureGenerators.sha256Hex(payload)
                    == frame.generatedContentSHA256 else {
                throw R03ProductQualificationMediaTestError.invalidFixture(
                    "frame \(frame.sequenceNumber) payload identity"
                )
            }
            let pixelBuffer = try R02FixturePixelBuffers.makeNV12(
                width: R03ProductQualificationMediaFixture.sourceResolution.width,
                height: R03ProductQualificationMediaFixture.sourceResolution.height,
                logicalBytes: payload
            )
            guard adaptor.append(
                pixelBuffer,
                withPresentationTime: frame.presentationTime
            ) else {
                throw mediaFailure(writer.error, fallback: "1080p frame append failed")
            }
        }
        videoInput.markAsFinished()

        while let sample = audioOutput.copyNextSampleBuffer() {
            try await waitUntilReady(audioInput, writer: writer, name: "AAC")
            guard audioInput.append(sample) else {
                throw mediaFailure(writer.error, fallback: "compressed AAC append failed")
            }
        }
        guard reader.status == .completed else {
            throw mediaFailure(reader.error, fallback: "compressed AAC reader did not complete")
        }
        audioInput.markAsFinished()
        guard let lastFrame = R03ProductQualificationMediaFixture.frames.last else {
            throw R03ProductQualificationMediaTestError.invalidFixture("empty frame sequence")
        }
        writer.endSession(
            atSourceTime: CMTimeAdd(lastFrame.presentationTime, lastFrame.duration)
        )
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw mediaFailure(writer.error, fallback: "1080p source writer did not complete")
        }
        completedWriting = true
    }
    // swiftlint:enable cyclomatic_complexity function_body_length

    private static func makeVideoInput() -> AVAssetWriterInput {
        let resolution = R03ProductQualificationMediaFixture.sourceResolution
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: resolution.width,
                AVVideoHeightKey: resolution.height,
                AVVideoColorPropertiesKey: [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
                ]
            ]
        )
        input.mediaTimeScale = 30_000
        input.expectsMediaDataInRealTime = false
        return input
    }

    private static func makeVideoAdaptor(
        videoInput: AVAssetWriterInput
    ) -> AVAssetWriterInputPixelBufferAdaptor {
        let resolution = R03ProductQualificationMediaFixture.sourceResolution
        return AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey as String: resolution.width,
                kCVPixelBufferHeightKey as String: resolution.height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
            ]
        )
    }

    private static func waitUntilReady(
        _ input: AVAssetWriterInput,
        writer: AVAssetWriter,
        name: String
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: readinessTimeout)
        while true {
            try Task.checkCancellation()
            guard writer.status == .writing else {
                throw mediaFailure(
                    writer.error,
                    fallback: "\(name) writer status \(writer.status.rawValue)"
                )
            }
            if input.isReadyForMoreMediaData {
                return
            }
            let now = clock.now
            guard now < deadline else {
                throw R03ProductQualificationMediaTestError.mediaFailure(
                    "\(name) readiness timed out"
                )
            }
            try await clock.sleep(
                until: min(deadline, now.advanced(by: readinessPollInterval))
            )
        }
    }

    private static func mediaFailure(
        _ error: Error?,
        fallback: String
    ) -> R03ProductQualificationMediaTestError {
        .mediaFailure(error.map(String.init(describing:)) ?? fallback)
    }
}

struct R03PQMediaVerificationSnapshot: Equatable, Sendable {
    let invocationCount: Int
    let successfulVerificationCount: Int
    let destinationWasAbsent: Bool
    let temporaryInputWasPresent: Bool
    let verifiedURL: URL?
    let result: OutputMediaVerificationResult?
}

final class R03PQMediaPrepublicationVerifier:
    OutputMediaVerifying,
    @unchecked Sendable {
    private struct State {
        var invocationCount = 0
        var successfulVerificationCount = 0
        var destinationWasAbsent = false
        var temporaryInputWasPresent = false
        var verifiedURL: URL?
        var result: OutputMediaVerificationResult?
    }

    private let destinationURL: URL
    private let expectedAACIdentity: OutputMediaAACIdentity
    private let expectedTimedMetadata: [String: String]
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(
        destinationURL: URL,
        expectedAACIdentity: OutputMediaAACIdentity,
        expectedTimedMetadata: [String: String]
    ) {
        self.destinationURL = destinationURL
        self.expectedAACIdentity = expectedAACIdentity
        self.expectedTimedMetadata = expectedTimedMetadata
    }

    var snapshot: R03PQMediaVerificationSnapshot {
        state.withLock { state in
            R03PQMediaVerificationSnapshot(
                invocationCount: state.invocationCount,
                successfulVerificationCount: state.successfulVerificationCount,
                destinationWasAbsent: state.destinationWasAbsent,
                temporaryInputWasPresent: state.temporaryInputWasPresent,
                verifiedURL: state.verifiedURL,
                result: state.result
            )
        }
    }

    func verify(
        url: URL,
        expectation: OutputMediaVerificationExpectation
    ) async throws -> OutputMediaVerificationResult {
        let destinationAbsent = !FileManager.default.fileExists(
            atPath: destinationURL.path
        )
        let temporaryPresent = FileManager.default.fileExists(atPath: url.path)
        state.withLock { state in
            state.invocationCount += 1
            state.destinationWasAbsent = destinationAbsent
            state.temporaryInputWasPresent = temporaryPresent
            state.verifiedURL = url
        }
        guard url != destinationURL, destinationAbsent, temporaryPresent else {
            throw R03ProductQualificationMediaTestError.mediaFailure(
                "verification did not precede atomic publication"
            )
        }
        guard expectation.resolution
                == R03ProductQualificationMediaFixture.targetResolution,
              expectation.codec == .h264,
              expectation.timing.frameCount
                == R03ProductQualificationMediaFixture.frames.count,
              expectation.timedMetadata == expectedTimedMetadata,
              expectation.videoColor == .sdrBT709VideoRangeLeft,
              expectation.compressedAACIdentity == expectedAACIdentity else {
            throw R03ProductQualificationMediaTestError.mediaFailure(
                "verification expectation omitted an exact media identity"
            )
        }
        let result = try await OutputMediaVerifier().verify(
            url: url,
            expectation: expectation
        )
        state.withLock { state in
            state.successfulVerificationCount += 1
            state.result = result
        }
        return result
    }
}
