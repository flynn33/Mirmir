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
    case unsupportedColorProfile(String)
    case outputPreparationFailed(URL, Error)
    case readerStartFailed
    case writerStartFailed
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
            return "Audio preservation does not support source format \(format); AAC is required for MP4 passthrough."
        case .unsupportedColorProfile(let profile):
            return "The source uses unsupported HDR or wide-color metadata (\(profile)); this build supports 8-bit SDR Rec.709."
        case .outputPreparationFailed(let url, let error):
            return "The output file could not be prepared safely at \(url.lastPathComponent): \(error)."
        case .readerStartFailed:
            return "AVAssetReader.startReading() returned false."
        case .writerStartFailed:
            return "AVAssetWriter.startWriting() returned false."
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

    /// Pulls the next decoded source frame, or `nil` at end-of-stream.
    func nextSourceFrame() async throws -> FrameRecord?

    /// Appends an upscaled output frame at the source frame's presentation time.
    func appendOutput(pixelBuffer: CVPixelBuffer, at presentationTime: CMTime) async throws

    /// Flushes the writer and finishes the file.
    func finish() async throws

    /// Cancels the session and tears down reader/writer resources.
    func cancel()
}

/// Owns AVFoundation ingest and encode for upscale jobs. Implementations must
/// also pass audio through unchanged when `outputProfile.preserveAudio` is true.
public protocol MediaPipelineService: AnyObject, Sendable {
    func probe(url: URL) async throws -> SourceProfile
    func beginSession(source: SourceProfile, output: OutputProfile) async throws -> MediaSession
    func start()
    func stop()
}
