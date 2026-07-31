import AVFoundation
import AudioToolbox
import CoreMedia
import CoreVideo
import CryptoKit
import Foundation
import XCTest
import os.lock
@testable import Mirmir

// swiftlint:disable file_length
enum R03ProductQualificationMediaTestError: Error, Equatable {
    case invalidFixture(String)
    case mediaFailure(String)
    case nativeMPSUnavailable(String)
    case invalidObservation(String)
    case invalidObservationConfiguration(String)
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
              expectation.compressedAACIdentity == nil,
              let expectedAACTracks =
                expectation.compressedAACTrackIdentities,
              expectedAACTracks.count == 1,
              expectedAACTracks[0].reference
                == OutputMediaTrackReference(
                    mediaType: AVMediaType.audio.rawValue,
                    ordinal: 0
                ),
              expectedAACTracks[0].compressedIdentity
                == expectedAACIdentity else {
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

struct R03PQMediaObservationDimensions: Codable, Equatable {
    let width: Int
    let height: Int
}

struct R03PQMediaFrameObservation: Codable, Equatable {
    let sequenceNumber: Int
    let ptsValue: Int64
    let ptsTimescale: Int32
    let durationValue: Int64
    let durationTimescale: Int32
    let metadataIdentity: String
    let resourceReleaseCount: Int

    private enum CodingKeys: String, CodingKey {
        case sequenceNumber = "sequence_number"
        case ptsValue = "pts_value"
        case ptsTimescale = "pts_timescale"
        case durationValue = "duration_value"
        case durationTimescale = "duration_timescale"
        case metadataIdentity = "metadata_identity"
        case resourceReleaseCount = "resource_release_count"
    }
}

struct R03PQMediaRunObservation: Codable, Equatable {
    let runOrdinal: Int
    let outputDimensions: R03PQMediaObservationDimensions
    let videoCodec: String
    let audioCodec: String
    let logicalFrameSHA256s: [String]
    let frameObservations: [R03PQMediaFrameObservation]
    let audioSemanticSHA256: String
    let reopenSucceeded: Bool
    let atomicPublicationSucceeded: Bool
    let fallbackHistory: [String]

    private enum CodingKeys: String, CodingKey {
        case runOrdinal = "run_ordinal"
        case outputDimensions = "output_dimensions"
        case videoCodec = "video_codec"
        case audioCodec = "audio_codec"
        case logicalFrameSHA256s = "logical_frame_sha256s"
        case frameObservations = "frame_observations"
        case audioSemanticSHA256 = "audio_semantic_sha256"
        case reopenSucceeded = "reopen_succeeded"
        case atomicPublicationSucceeded = "atomic_publication_succeeded"
        case fallbackHistory = "fallback_history"
    }
}

struct R03QualificationInvocation: Codable, Equatable {
    static let contractID = "r03.a11.product-qualification-invocation.v1"
    static let batchIDEnvironmentKey = "R03_QUALIFICATION_BATCH_ID"
    static let sourceCommitEnvironmentKey = "R03_QUALIFICATION_SOURCE_COMMIT"
    static let sourceTreeEnvironmentKey = "R03_QUALIFICATION_SOURCE_TREE"
    private static let compiledSourceCommitKey =
        "R03QualificationSourceCommit"
    private static let compiledSourceTreeKey = "R03QualificationSourceTree"

    let contractID: String
    let batchID: String
    let sourceCommit: String
    let sourceTree: String
    let bindingSHA256: String

    static func readRequired(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = Bundle(for: R03QualificationBundleSentinel.self)
    ) throws -> R03QualificationInvocation {
        guard let batchID = nonempty(environment[batchIDEnvironmentKey]),
              let runtimeSourceCommit = nonempty(
                  environment[sourceCommitEnvironmentKey]
              ),
              let runtimeSourceTree = nonempty(environment[sourceTreeEnvironmentKey]),
              let sourceCommit = nonempty(
                  bundle.object(forInfoDictionaryKey: compiledSourceCommitKey)
                      as? String
              ),
              let sourceTree = nonempty(
                  bundle.object(forInfoDictionaryKey: compiledSourceTreeKey)
                      as? String
              ),
              isLowercaseHex(batchID, count: 64),
              batchID != String(repeating: "0", count: 64),
              isLowercaseHex(sourceCommit, count: 40),
              isLowercaseHex(sourceTree, count: 40),
              runtimeSourceCommit == sourceCommit,
              runtimeSourceTree == sourceTree else {
            throw R03ProductQualificationMediaTestError
                .invalidObservationConfiguration(
                    "runtime invocation differs from compiled source identity"
                )
        }
        let bindingSHA256 = SHA256.hash(
            data: Data(
                [contractID, batchID, sourceCommit, sourceTree]
                    .joined(separator: "\0")
                    .utf8
            )
        ).map { String(format: "%02x", $0) }.joined()
        return R03QualificationInvocation(
            contractID: contractID,
            batchID: batchID,
            sourceCommit: sourceCommit,
            sourceTree: sourceTree,
            bindingSHA256: bindingSHA256
        )
    }

    private static func nonempty(_ value: String?) -> String? {
        value.flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func isLowercaseHex(_ value: String, count: Int) -> Bool {
        value.count == count && value.unicodeScalars.allSatisfy {
            (48...57).contains($0.value) || (97...102).contains($0.value)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case contractID = "contract_id"
        case batchID = "batch_id"
        case sourceCommit = "source_commit"
        case sourceTree = "source_tree"
        case bindingSHA256 = "binding_sha256"
    }
}

final class R03QualificationBundleSentinel {}

struct R03PQMediaObservationDocument: Codable, Equatable {
    let schemaVersion: String
    let evidenceKind: String
    let fixtureID: String
    let qualificationInvocation: R03QualificationInvocation
    let run: R03PQMediaRunObservation

    init(
        qualificationInvocation: R03QualificationInvocation,
        run: R03PQMediaRunObservation
    ) {
        schemaVersion = "1.0.0"
        evidenceKind = "r03_a11_media_transaction_observation_v1"
        fixtureID = R03ProductQualificationMediaFixture.id
        self.qualificationInvocation = qualificationInvocation
        self.run = run
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case evidenceKind = "evidence_kind"
        case fixtureID = "fixture_id"
        case qualificationInvocation = "qualification_invocation"
        case run
    }
}

struct R03PQMediaObservationRequest: Equatable {
    fileprivate let outputURL: URL
    fileprivate let runOrdinal: Int
    fileprivate let qualificationInvocation: R03QualificationInvocation
}

enum R03AtomicEvidenceFileWriter {
    static func writeWithoutOverwriting(
        _ data: Data,
        to outputURL: URL
    ) throws {
        guard !pathEntryExists(at: outputURL) else {
            throw R03ProductQualificationMediaTestError
                .invalidObservationConfiguration(
                    "observation target is no longer fresh"
                )
        }

        let transaction = try AtomicMediaOutput(destinationURL: outputURL)
        defer { transaction.fail() }
        try transaction.beginWriting()
        try data.write(to: transaction.temporaryURL, options: .withoutOverwriting)
        try transaction.beginFinishing()
        try transaction.beginVerifying()
        try transaction.publish()
    }

    static func pathEntryExists(
        at url: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        fileManager.fileExists(atPath: url.path)
            || (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }
}

enum R03PQMediaObservationWriter {
    static let directoryEnvironmentKey =
        "R03_QUALIFICATION_MEDIA_OBSERVATIONS_DIRECTORY"

    static func preflightIfRequested(
        runOrdinal: Int,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws -> R03PQMediaObservationRequest? {
        let requestedDirectory = environment[directoryEnvironmentKey].flatMap {
            $0.isEmpty ? nil : $0
        }
        guard let requestedDirectory else {
            return nil
        }
        guard (1...3).contains(runOrdinal) else {
            throw R03ProductQualificationMediaTestError
                .invalidObservationConfiguration("run ordinal must be in 1...3")
        }
        guard NSString(string: requestedDirectory).isAbsolutePath else {
            throw R03ProductQualificationMediaTestError
                .invalidObservationConfiguration(
                    "observation directory must be absolute"
                )
        }

        let directoryURL = URL(fileURLWithPath: requestedDirectory)
            .standardizedFileURL
        let outputURL = directoryURL.appendingPathComponent(
            "media-run-\(runOrdinal).json",
            isDirectory: false
        )
        guard !R03AtomicEvidenceFileWriter.pathEntryExists(
            at: outputURL,
            fileManager: fileManager
        ) else {
            throw R03ProductQualificationMediaTestError
                .invalidObservationConfiguration(
                    "observation target must not exist before the test starts"
                )
        }
        var parentIsDirectory = ObjCBool(false)
        guard fileManager.fileExists(
            atPath: directoryURL.path,
            isDirectory: &parentIsDirectory
        ), parentIsDirectory.boolValue else {
            throw R03ProductQualificationMediaTestError
                .invalidObservationConfiguration(
                    "observation target parent must be an existing directory"
                )
        }
        return R03PQMediaObservationRequest(
            outputURL: outputURL,
            runOrdinal: runOrdinal,
            qualificationInvocation: try R03QualificationInvocation.readRequired(
                environment: environment
            )
        )
    }

    static func emitIfRequested(
        request: R03PQMediaObservationRequest?,
        testFailureCount: Int?,
        makeObservation: (Int) -> R03PQMediaRunObservation
    ) throws {
        guard let request else {
            return
        }
        guard let testFailureCount else {
            throw R03ProductQualificationMediaTestError
                .invalidObservationConfiguration("XCTest failure count unavailable")
        }
        guard testFailureCount == 0 else {
            return
        }
        guard !R03AtomicEvidenceFileWriter.pathEntryExists(
            at: request.outputURL
        ) else {
            throw R03ProductQualificationMediaTestError
                .invalidObservationConfiguration(
                    "observation target is no longer fresh"
                )
        }

        let observation = makeObservation(request.runOrdinal)
        try validate(observation, requestedOrdinal: request.runOrdinal)
        let document = R03PQMediaObservationDocument(
            qualificationInvocation: request.qualificationInvocation,
            run: observation
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(document)
        try R03AtomicEvidenceFileWriter.writeWithoutOverwriting(
            data,
            to: request.outputURL
        )
    }

    private static func validate(
        _ observation: R03PQMediaRunObservation,
        requestedOrdinal: Int
    ) throws {
        let fixture = R03ProductQualificationMediaFixture.self
        let expectedFrames = fixture.frames.map {
            R03PQMediaFrameObservation(
                sequenceNumber: $0.sequenceNumber,
                ptsValue: $0.presentationTime.value,
                ptsTimescale: $0.presentationTime.timescale,
                durationValue: $0.duration.value,
                durationTimescale: $0.duration.timescale,
                metadataIdentity: $0.metadataIdentity,
                resourceReleaseCount: 1
            )
        }
        let exactDimensions = R03PQMediaObservationDimensions(
            width: fixture.targetResolution.width,
            height: fixture.targetResolution.height
        )
        guard observation.runOrdinal == requestedOrdinal,
              observation.outputDimensions == exactDimensions,
              observation.videoCodec == "h264",
              observation.audioCodec == "aac",
              observation.logicalFrameSHA256s.count == fixture.frames.count,
              observation.logicalFrameSHA256s.allSatisfy(isSHA256),
              observation.frameObservations == expectedFrames,
              isSHA256(observation.audioSemanticSHA256),
              observation.reopenSucceeded,
              observation.atomicPublicationSucceeded,
              observation.fallbackHistory.isEmpty else {
            throw R03ProductQualificationMediaTestError.invalidObservation(
                "media observation differs from the frozen transaction"
            )
        }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64
            && value != String(repeating: "0", count: 64)
            && value.unicodeScalars.allSatisfy {
                (48...57).contains($0.value) || (97...102).contains($0.value)
            }
    }
}

final class R03AtomicEvidenceFileWriterTests: XCTestCase {
    func testPublishesCompleteBytesAndPreservesExistingEvidence() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent(
            "mirmir-r03-evidence-writer-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer { try? fileManager.removeItem(at: directory) }

        let destination = directory.appendingPathComponent("evidence.json")
        let first = Data("first-evidence".utf8)
        try R03AtomicEvidenceFileWriter.writeWithoutOverwriting(
            first,
            to: destination
        )
        XCTAssertEqual(try Data(contentsOf: destination), first)

        XCTAssertThrowsError(
            try R03AtomicEvidenceFileWriter.writeWithoutOverwriting(
                Data("replacement".utf8),
                to: destination
            )
        )
        XCTAssertEqual(try Data(contentsOf: destination), first)
        XCTAssertEqual(
            try fileManager.contentsOfDirectory(atPath: directory.path),
            ["evidence.json"]
        )
    }
}
// swiftlint:enable file_length
