import Foundation
import AVFoundation
import CoreVideo

public enum MediaPipelineError: Error, CustomStringConvertible {
    case noVideoTrack(URL)
    case readerCreationFailed(URL, Error?)
    case writerCreationFailed(URL, Error?)
    case inputOutputCollision(URL)
    case cannotAddReaderOutput(String)
    case cannotAddWriterInput(String)
    case unsupportedAudioTrackCount(Int)
    case unsupportedAudioFormat(String)
    case unsupportedOutputContainer(String)
    case outputContainerCannotPreserveVideoFormat(
        pathExtension: String,
        format: MediaVideoFormat
    )
    case outputContainerCannotPreserveCodec(
        pathExtension: String,
        codec: OutputCodec
    )
    case outputContainerCannotPreserveLinearPCM(
        pathExtension: String
    )
    case outputContainerCannotPreserveTrackAssociations(
        pathExtension: String
    )
    case unsupportedColorProfile(String)
    case unsupportedVideoFormat(String)
    case unsupportedVideoFormatConversion(
        source: MediaVideoFormat,
        requested: MediaVideoFormat
    )
    case outputCodecCannotPreserveVideoFormat(
        codec: OutputCodec,
        format: MediaVideoFormat
    )
    case outputEncoderUnavailable(
        codec: OutputCodec,
        format: MediaVideoFormat
    )
    case outputPixelFormatMismatch(expected: OSType, actual: OSType)
    case unsupportedTrackAssociation(
        associationType: String,
        sourceMediaType: String,
        targetMediaType: String
    )
    case mediaPreservationPreflightFailed(String)
    case mediaPreservationCapabilityChanged
    case metadataPreservationFailed(String)
    case unsupportedNegativeSourceTimeline(
        mediaType: String,
        start: CMTime,
        end: CMTime
    )
    case unrepresentableVideoTimeline(
        naturalTimeScale: CMTimeScale,
        start: CMTime,
        end: CMTime
    )
    case outputPreparationFailed(URL, Error)
    case finalMuxFailed(URL, Error)
    case outputVerificationFailed(URL, Error)
    case invalidFrameTiming(String)
    case deinterlacingFailed(String)
    case partialCleanupFailed(URL, String)
    case readerStartFailed
    case writerStartFailed
    case outputMetadataMismatch(String)
    case invalidAssetDimensions
    case unsupportedAssetDimensions(VideoResolution)
    case audioBridgeFailed(Error)
    case readerFailed(Error?)
    case writerFailed(Error?)

    public var description: String {
        switch self {
        case .noVideoTrack(let url):
            return "No video track in \(url.lastPathComponent)."
        case .readerCreationFailed(let url, let error):
            return "AVAssetReader could not be created for \(url.lastPathComponent): \(error.map { String(describing: $0) } ?? "unknown")."
        case .writerCreationFailed(let url, let error):
            return "AVAssetWriter could not be created at \(url.lastPathComponent): \(error.map { String(describing: $0) } ?? "unknown")."
        case .inputOutputCollision(let url):
            return "The source and output resolve to the same file: \(url.lastPathComponent)."
        case .cannotAddReaderOutput(let mediaType):
            return "AVAssetReader rejected the \(mediaType) output."
        case .cannotAddWriterInput(let mediaType):
            return "AVAssetWriter rejected the \(mediaType) input."
        case .unsupportedAudioTrackCount(let count):
            return "The source reports an invalid audio-track count of \(count); the count must be zero or greater."
        case .unsupportedAudioFormat(let format):
            return "Audio preservation does not support source format "
                + "\(format); exact passthrough accepts AAC, Apple Lossless, "
                + "and supported interleaved Linear PCM."
        case .unsupportedOutputContainer(let pathExtension):
            return "Unsupported output container extension .\(pathExtension); Mirmir writes MP4 or QuickTime Movie output."
        case .outputContainerCannotPreserveVideoFormat(
            let pathExtension,
            let format
        ):
            return "The .\(pathExtension) output container cannot preserve "
                + "\(format). Select a .mov destination."
        case .outputContainerCannotPreserveCodec(
            let pathExtension,
            let codec
        ):
            return "The .\(pathExtension) output container cannot carry "
                + "\(codec.displayName). Select a QuickTime Movie (.mov) "
                + "destination."
        case .outputContainerCannotPreserveLinearPCM(
            let pathExtension
        ):
            return "The .\(pathExtension) output container cannot "
                + "preserve Linear PCM audio. Select a QuickTime Movie "
                + "(.mov) destination, or turn off Preserve Source Audio "
                + "Tracks."
        case .outputContainerCannotPreserveTrackAssociations(
            let pathExtension
        ):
            return "The .\(pathExtension) output container cannot "
                + "preserve the source auxiliary-video track association. "
                + "Select a QuickTime Movie (.mov) destination."
        case .unsupportedColorProfile(let profile):
            return "The source color metadata is incomplete or inconsistent (\(profile)). Mirmir preserves Rec.709 SDR and 10-bit BT.2020 PQ/HLG without silent color conversion."
        case .unsupportedVideoFormat(let reason):
            return "The source video format cannot be preserved: \(reason)"
        case .unsupportedVideoFormatConversion(let source, let requested):
            return "The requested output format \(requested) differs from source "
                + "\(source). Explicit tone or gamut conversion is not enabled."
        case .outputCodecCannotPreserveVideoFormat(let codec, let format):
            return "The selected \(codec.rawValue.uppercased()) codec cannot "
                + "preserve \(format). Select "
                + format.supportedOutputCodecs
                    .map(\.displayName)
                    .joined(separator: " or ")
                + "."
        case .outputEncoderUnavailable(let codec, let format):
            return "AVFoundation cannot encode \(format) with "
                + "\(codec.rawValue.uppercased()) on this Mac or in the "
                + "selected output container."
        case .outputPixelFormatMismatch(let expected, let actual):
            return "The processed frame uses Core Video pixel format \(actual); "
                + "the source-preserving output requires \(expected)."
        case .unsupportedTrackAssociation(
            let associationType,
            let sourceMediaType,
            let targetMediaType
        ):
            return "The source \(sourceMediaType) track association "
                + "\(associationType) targets an unpreserved "
                + "\(targetMediaType) track."
        case .mediaPreservationPreflightFailed(let reason):
            return reason
        case .mediaPreservationCapabilityChanged:
            return "The source audio, auxiliary tracks, metadata, or "
                + "association graph changed after probing. Reload the "
                + "source before starting so Mirmir can verify the "
                + "current preservation requirements."
        case .metadataPreservationFailed(let reason):
            return "Source metadata could not be preserved and verified: \(reason)"
        case .unsupportedNegativeSourceTimeline(
            let mediaType,
            let start,
            let end
        ):
            return "The source \(mediaType) timeline starts before zero "
                + "(start \(start), end \(end)); exact negative-timeline "
                + "preservation is unavailable."
        case .unrepresentableVideoTimeline(
            let naturalTimeScale,
            let start,
            let end
        ):
            return "The source video timeline cannot be represented exactly by AVFoundation (natural timescale \(naturalTimeScale), start \(start), end \(end))."
        case .outputPreparationFailed(let url, let error):
            return "The output file could not be prepared safely at \(url.lastPathComponent): \(error)."
        case .finalMuxFailed(let url, let error):
            return "The encoded video and source audio could not be assembled at "
                + "\(url.lastPathComponent): \(error)."
        case .outputVerificationFailed(let url, let error):
            return "The output file failed reopen verification at \(url.lastPathComponent): \(error)."
        case .invalidFrameTiming(let reason):
            return "The output frame timing ledger rejected a frame: \(reason)"
        case .deinterlacingFailed(let reason):
            return "The source frame could not be converted from interlaced "
                + "to progressive scan: \(reason)"
        case .partialCleanupFailed(let url, let reason):
            return "Temporary output cleanup failed for \(url.lastPathComponent): \(reason)"
        case .readerStartFailed:
            return "AVAssetReader.startReading() returned false."
        case .writerStartFailed:
            return "AVAssetWriter.startWriting() returned false."
        case .outputMetadataMismatch(let reason):
            return "Mirmir output identity metadata is invalid: \(reason)"
        case .invalidAssetDimensions:
            return "The source reports invalid or unrepresentable video dimensions."
        case .unsupportedAssetDimensions(let res):
            return "Source geometry \(res) cannot be represented by the selected output route."
        case .audioBridgeFailed(let error):
            return "Audio passthrough mux failed: \(error)"
        case .readerFailed(let error):
            return "AVAssetReader failed: \(error.map { String(describing: $0) } ?? "unknown")."
        case .writerFailed(let error):
            return "AVAssetWriter terminal error: \(error.map { String(describing: $0) } ?? "unknown")."
        }
    }
}

enum FinalMuxGuardError: Error, CustomNSError, CustomStringConvertible {
    enum Phase: String {
        case stagingInspection = "staging_inspection"
        case destinationPreparation = "destination_preparation"
        case destinationTrackCreation = "destination_track_creation"
    }

    enum CountKind: String {
        case videoTrack = "video_track"
        case metadataTrack = "metadata_track"
        case temporaryOutput = "temporary_output"
        case destinationTrack = "destination_track"
    }

    struct CountEvidence {
        let kind: CountKind
        let expected: Int
        let actual: Int
    }

    enum TrackKind: String {
        case video
        case audio
        case metadata
        case subtitle
        case text
        case closedCaption = "closed_caption"
        case timecode
        case unknown

        init(mediaType: AVMediaType) {
            switch mediaType {
            case .video:
                self = .video
            case .audio:
                self = .audio
            case .metadata:
                self = .metadata
            case .subtitle:
                self = .subtitle
            case .text:
                self = .text
            case .closedCaption:
                self = .closedCaption
            case .timecode:
                self = .timecode
            default:
                self = .unknown
            }
        }
    }

    case stagingVideoTrackCount(expected: Int, actual: Int)
    case stagingMetadataTrackCount(expected: Int, actual: Int)
    case temporaryOutputAlreadyExists
    case destinationTrackCreationFailed(trackKind: TrackKind)

    static let errorDomain = "Mirmir.FinalSampleCopyMux"

    var errorCode: Int {
        switch self {
        case .stagingVideoTrackCount:
            return 1_001
        case .stagingMetadataTrackCount:
            return 1_002
        case .temporaryOutputAlreadyExists:
            return 1_003
        case .destinationTrackCreationFailed:
            return 1_004
        }
    }

    var errorUserInfo: [String: Any] {
        [:]
    }

    var phase: Phase {
        switch self {
        case .stagingVideoTrackCount, .stagingMetadataTrackCount:
            return .stagingInspection
        case .temporaryOutputAlreadyExists:
            return .destinationPreparation
        case .destinationTrackCreationFailed:
            return .destinationTrackCreation
        }
    }

    var reason: String {
        switch self {
        case .stagingVideoTrackCount:
            return "staging_video_track_count_mismatch"
        case .stagingMetadataTrackCount:
            return "staging_metadata_track_count_mismatch"
        case .temporaryOutputAlreadyExists:
            return "temporary_output_already_exists"
        case .destinationTrackCreationFailed:
            return "destination_track_creation_failed"
        }
    }

    var countEvidence: CountEvidence {
        switch self {
        case .stagingVideoTrackCount(let expected, let actual):
            return CountEvidence(
                kind: .videoTrack,
                expected: expected,
                actual: actual
            )
        case .stagingMetadataTrackCount(let expected, let actual):
            return CountEvidence(
                kind: .metadataTrack,
                expected: expected,
                actual: actual
            )
        case .temporaryOutputAlreadyExists:
            return CountEvidence(
                kind: .temporaryOutput,
                expected: 0,
                actual: 1
            )
        case .destinationTrackCreationFailed:
            return CountEvidence(
                kind: .destinationTrack,
                expected: 1,
                actual: 0
            )
        }
    }

    var trackKind: TrackKind? {
        guard case .destinationTrackCreationFailed(let trackKind) = self else {
            return nil
        }
        return trackKind
    }

    var description: String {
        let count = countEvidence
        return "\(reason) during \(phase.rawValue) "
            + "(expected \(count.expected) \(count.kind.rawValue), "
            + "actual \(count.actual))."
    }
}

/// Encapsulates an active read+write session for an upscale job. Returned by
/// `MediaPipelineService.beginSession(...)`. The pipeline owns the reader,
/// writer, pixel-buffer pool, and audio bridge; the upscaler engine consumes
/// frames via `nextSourceFrame()` and submits results via `appendOutput(...)`.
public protocol MediaSession: AnyObject, Sendable {
    var sourceProfile: SourceProfile { get }
    var outputProfile: OutputProfile { get }
    var videoFormat: MediaVideoFormat { get }
    var outputPixelBufferPool: CVPixelBufferPool { get }
    var presentationTransform: CGAffineTransform { get }
    var prepublicationOutputURL: URL { get }
    var publishedOutputIdentity: MediaOutputPublicationIdentity? { get }
    var terminalCleanupError: MediaPipelineError? { get }

    /// Pulls the next decoded source frame, or `nil` at end-of-stream.
    func nextSourceFrame() async throws -> FrameRecord?

    /// Appends an upscaled output frame with its exact source timing record.
    func appendOutput(pixelBuffer: CVPixelBuffer, timing: FrameTiming) async throws

    /// Flushes the writer and finishes the file.
    func finish() async throws

    /// Flushes the writer with the exact aggregate identity known after the
    /// final reconstructed frame.
    func finish(finalMetadata: [String: String]) async throws

    /// Flushes and reopens the completed output, then runs the caller's final
    /// identity/checkpoint validation before the destination can be published.
    func finish(
        finalMetadata: [String: String],
        validatingBeforePublish: @escaping @Sendable () async throws -> Void
    ) async throws

    /// Flushes the completed writer, invokes the first hook immediately before
    /// reopening the temporary media, and invokes the second hook after the
    /// reopen verification but before publishing the destination.
    func finish(
        finalMetadata: [String: String],
        beforeReopen: @escaping @Sendable () async throws -> Void,
        validatingBeforePublish: @escaping @Sendable () async throws -> Void
    ) async throws

    /// Cancels the session and tears down reader/writer resources.
    func cancel()
}

public extension MediaSession {
    var videoFormat: MediaVideoFormat {
        sourceProfile.videoFormat
    }

    var presentationTransform: CGAffineTransform {
        .identity
    }

    var prepublicationOutputURL: URL {
        outputProfile.url
    }

    var publishedOutputIdentity: MediaOutputPublicationIdentity? {
        nil
    }

    func finish(finalMetadata _: [String: String]) async throws {
        try await finish()
    }

    func finish(
        finalMetadata: [String: String],
        validatingBeforePublish: @escaping @Sendable () async throws -> Void
    ) async throws {
        try await finish(
            finalMetadata: finalMetadata,
            beforeReopen: {},
            validatingBeforePublish: validatingBeforePublish
        )
    }

    func finish(
        finalMetadata: [String: String],
        beforeReopen: @escaping @Sendable () async throws -> Void,
        validatingBeforePublish: @escaping @Sendable () async throws -> Void
    ) async throws {
        try await beforeReopen()
        try await validatingBeforePublish()
        try await finish(finalMetadata: finalMetadata)
    }
}

/// Owns AVFoundation ingest and encode for upscale jobs. Implementations must
/// also pass audio through unchanged when `outputProfile.preserveAudio` is true.
public protocol MediaPipelineService: AnyObject, Sendable {
    func probe(url: URL) async throws -> SourceProfile
    func beginSession(source: SourceProfile, output: OutputProfile) async throws -> MediaSession
    func start()
    func stop()
}
