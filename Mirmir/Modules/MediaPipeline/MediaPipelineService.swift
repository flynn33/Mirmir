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
    case unsupportedColorProfile(String)
    case outputPreparationFailed(URL, Error)
    case outputVerificationFailed(URL, String)
    case invalidFrameTiming(String)
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
            return "Audio preservation currently supports exactly one audio track; the source contains \(count)."
        case .unsupportedAudioFormat(let format):
            return "Audio preservation does not support source format \(format); AAC is required for passthrough."
        case .unsupportedOutputContainer(let pathExtension):
            return "Unsupported output container extension .\(pathExtension); Mirmir writes MP4 or QuickTime Movie output."
        case .unsupportedColorProfile(let profile):
            return "The source uses unsupported HDR or wide-color metadata (\(profile)); this build supports 8-bit SDR Rec.709."
        case .outputPreparationFailed(let url, let error):
            return "The output file could not be prepared safely at \(url.lastPathComponent): \(error)."
        case .outputVerificationFailed(let url, let reason):
            return "The output file failed reopen verification at \(url.lastPathComponent): \(reason)."
        case .invalidFrameTiming(let reason):
            return "The output frame timing ledger rejected a frame: \(reason)"
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
            return "Unsupported source resolution \(res). Mirmir supports 720p and 1080p sources."
        case .audioBridgeFailed(let error):
            return "Audio passthrough mux failed: \(error)"
        case .readerFailed(let error):
            return "AVAssetReader failed: \(error.map { String(describing: $0) } ?? "unknown")."
        case .writerFailed(let error):
            return "AVAssetWriter terminal error: \(error.map { String(describing: $0) } ?? "unknown")."
        }
    }
}

/// Encapsulates an active read+write session for an upscale job. Returned by
/// `MediaPipelineService.beginSession(...)`. The pipeline owns the reader,
/// writer, pixel-buffer pool, and audio bridge; the upscaler engine consumes
/// frames via `nextSourceFrame()` and submits results via `appendOutput(...)`.
public protocol MediaSession: AnyObject, Sendable {
    var sourceProfile: SourceProfile { get }
    var outputProfile: OutputProfile { get }
    var outputPixelBufferPool: CVPixelBufferPool { get }
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
