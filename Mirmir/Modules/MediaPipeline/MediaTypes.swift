import Foundation
import CoreMedia
import AVFoundation

public struct VideoResolution: Hashable, Sendable, CustomStringConvertible {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public static let p720 = VideoResolution(width: 1280, height: 720)
    public static let p1080 = VideoResolution(width: 1920, height: 1080)
    public static let p1440 = VideoResolution(width: 2560, height: 1440)
    public static let p2160 = VideoResolution(width: 3840, height: 2160)

    public var description: String { "\(width)x\(height)" }

    public var isP720: Bool { self == .p720 }
    public var isP1080: Bool { self == .p1080 }
    public var isP2160: Bool { self == .p2160 }

    public func scaled(by factor: Int) -> VideoResolution {
        VideoResolution(width: width * factor, height: height * factor)
    }
}

public struct SourceProfile: Sendable {
    public let url: URL
    public let resolution: VideoResolution
    public let frameRate: Double
    public let durationSeconds: Double
    public let estimatedFrameCount: Int
    public let codecHint: String?
    public let hasAudio: Bool

    public init(
        url: URL,
        resolution: VideoResolution,
        frameRate: Double,
        durationSeconds: Double,
        estimatedFrameCount: Int,
        codecHint: String?,
        hasAudio: Bool
    ) {
        self.url = url
        self.resolution = resolution
        self.frameRate = frameRate
        self.durationSeconds = durationSeconds
        self.estimatedFrameCount = estimatedFrameCount
        self.codecHint = codecHint
        self.hasAudio = hasAudio
    }
}

public enum OutputCodec: String, Sendable, CaseIterable, Identifiable {
    case hevc
    case h264

    public var id: String { rawValue }

    public var avCodecKey: AVVideoCodecType {
        switch self {
        case .hevc: return .hevc
        case .h264: return .h264
        }
    }
}

public struct OutputProfile: Sendable {
    public let url: URL
    public let resolution: VideoResolution
    public let codec: OutputCodec
    public let preserveAudio: Bool

    public init(url: URL, resolution: VideoResolution, codec: OutputCodec, preserveAudio: Bool) {
        self.url = url
        self.resolution = resolution
        self.codec = codec
        self.preserveAudio = preserveAudio
    }
}

public struct FrameTiming: @unchecked Sendable, Equatable {
    public let frameIndex: Int
    public let presentationTime: CMTime
    public let duration: CMTime

    public init(frameIndex: Int, presentationTime: CMTime, duration: CMTime) {
        self.frameIndex = frameIndex
        self.presentationTime = presentationTime
        self.duration = duration
    }

    static func resolveDuration(
        sampleDuration: CMTime,
        presentationTime: CMTime,
        nextPresentationTime: CMTime?,
        timelineEnd: CMTime
    ) -> CMTime {
        if sampleDuration.isValid,
           sampleDuration.isNumeric,
           CMTimeCompare(sampleDuration, .zero) > 0 {
            return sampleDuration
        }
        if let nextPresentationTime {
            let inferred = CMTimeSubtract(nextPresentationTime, presentationTime)
            if inferred.isValid,
               inferred.isNumeric,
               CMTimeCompare(inferred, .zero) > 0 {
                return inferred
            }
        }
        let trailing = CMTimeSubtract(timelineEnd, presentationTime)
        guard trailing.isValid,
              trailing.isNumeric,
              CMTimeCompare(trailing, .zero) > 0 else {
            return .invalid
        }
        return trailing
    }
}

enum FrameTimingLedgerError: Error, Equatable, Sendable, CustomStringConvertible {
    case unexpectedFrameIndex(expected: Int, actual: Int)
    case invalidPresentationTime(frameIndex: Int)
    case nonMonotonicPresentationTime(previousFrameIndex: Int, frameIndex: Int)
    case invalidDuration(frameIndex: Int)
    case empty

    var description: String {
        switch self {
        case .unexpectedFrameIndex(let expected, let actual):
            return "Expected output frame index \(expected), received \(actual)."
        case .invalidPresentationTime(let frameIndex):
            return "Frame \(frameIndex) has an invalid presentation timestamp."
        case .nonMonotonicPresentationTime(let previousFrameIndex, let frameIndex):
            return "Frame \(frameIndex) does not follow frame \(previousFrameIndex) in presentation order."
        case .invalidDuration(let frameIndex):
            return "Frame \(frameIndex) has a nonpositive or invalid duration."
        case .empty:
            return "The output timing ledger contains no video frames."
        }
    }
}

struct FrameTimingLedgerSnapshot: @unchecked Sendable, Equatable {
    let frames: [FrameTiming]

    var frameCount: Int { frames.count }

    var sessionEndTime: CMTime? {
        guard let last = frames.last else { return nil }
        return CMTimeAdd(last.presentationTime, last.duration)
    }

    var duration: CMTime? {
        guard let first = frames.first,
              let sessionEndTime else { return nil }
        return CMTimeSubtract(sessionEndTime, first.presentationTime)
    }
}

struct FrameTimingLedger: @unchecked Sendable {
    private(set) var frames: [FrameTiming] = []

    var snapshot: FrameTimingLedgerSnapshot {
        FrameTimingLedgerSnapshot(frames: frames)
    }

    mutating func append(_ timing: FrameTiming) throws {
        let expectedIndex = frames.count
        guard timing.frameIndex == expectedIndex else {
            throw FrameTimingLedgerError.unexpectedFrameIndex(
                expected: expectedIndex,
                actual: timing.frameIndex
            )
        }
        guard timing.presentationTime.isValid,
              timing.presentationTime.isNumeric else {
            throw FrameTimingLedgerError.invalidPresentationTime(frameIndex: timing.frameIndex)
        }
        guard timing.duration.isValid,
              timing.duration.isNumeric,
              CMTimeCompare(timing.duration, .zero) > 0 else {
            throw FrameTimingLedgerError.invalidDuration(frameIndex: timing.frameIndex)
        }
        if let previous = frames.last,
           CMTimeCompare(timing.presentationTime, previous.presentationTime) <= 0 {
            throw FrameTimingLedgerError.nonMonotonicPresentationTime(
                previousFrameIndex: previous.frameIndex,
                frameIndex: timing.frameIndex
            )
        }
        frames.append(timing)
    }
}

public struct FrameRecord: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    public let timing: FrameTiming

    public var presentationTime: CMTime { timing.presentationTime }
    public var duration: CMTime { timing.duration }
    public var frameIndex: Int { timing.frameIndex }

    public init(pixelBuffer: CVPixelBuffer, timing: FrameTiming) {
        self.pixelBuffer = pixelBuffer
        self.timing = timing
    }
}
