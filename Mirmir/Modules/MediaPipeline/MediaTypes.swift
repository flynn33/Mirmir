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

public struct FrameRecord: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    public let presentationTime: CMTime
    public let frameIndex: Int

    public init(pixelBuffer: CVPixelBuffer, presentationTime: CMTime, frameIndex: Int) {
        self.pixelBuffer = pixelBuffer
        self.presentationTime = presentationTime
        self.frameIndex = frameIndex
    }
}
