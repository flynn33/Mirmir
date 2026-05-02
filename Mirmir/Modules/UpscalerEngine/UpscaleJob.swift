import Foundation

public struct UpscaleJob: Sendable {
    public let inputURL: URL
    public let outputURL: URL
    public let targetResolution: VideoResolution
    public let codec: OutputCodec
    public let preserveAudio: Bool

    public init(
        inputURL: URL,
        outputURL: URL,
        targetResolution: VideoResolution,
        codec: OutputCodec = .hevc,
        preserveAudio: Bool = true
    ) {
        self.inputURL = inputURL
        self.outputURL = outputURL
        self.targetResolution = targetResolution
        self.codec = codec
        self.preserveAudio = preserveAudio
    }
}

public struct UpscaleProgress: Sendable, Equatable {
    public let framesProcessed: Int
    public let totalFrames: Int
    public let throughputFPS: Double
    public let etaSeconds: Double?

    public init(framesProcessed: Int, totalFrames: Int, throughputFPS: Double, etaSeconds: Double?) {
        self.framesProcessed = framesProcessed
        self.totalFrames = totalFrames
        self.throughputFPS = throughputFPS
        self.etaSeconds = etaSeconds
    }

    public var fraction: Double {
        guard totalFrames > 0 else { return 0 }
        return Double(framesProcessed) / Double(totalFrames)
    }
}
