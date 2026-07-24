import Foundation

public struct UpscaleJob: Sendable {
    public let identifier: String
    public let inputURL: URL
    public let outputURL: URL
    public let targetResolution: VideoResolution
    public let codec: OutputCodec
    public let preserveAudio: Bool
    public let mode: UpscaleMode

    public init(
        identifier: String = UUID().uuidString,
        inputURL: URL,
        outputURL: URL,
        targetResolution: VideoResolution,
        codec: OutputCodec = .hevc,
        preserveAudio: Bool = true,
        mode: UpscaleMode = .deterministic
    ) {
        self.identifier = identifier
        self.inputURL = inputURL
        self.outputURL = outputURL
        self.targetResolution = targetResolution
        self.codec = codec
        self.preserveAudio = preserveAudio
        self.mode = mode
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
        return min(1, max(0, Double(framesProcessed) / Double(totalFrames)))
    }
}

enum FileURLIdentity {
    static func refersToSameFile(
        _ lhs: URL,
        _ rhs: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        let normalizedLHS = lhs.resolvingSymlinksInPath().standardizedFileURL
        let normalizedRHS = rhs.resolvingSymlinksInPath().standardizedFileURL

        guard normalizedLHS.isFileURL, normalizedRHS.isFileURL else {
            return normalizedLHS == normalizedRHS
        }
        if normalizedLHS.path == normalizedRHS.path {
            return true
        }

        guard
            let lhsAttributes = try? fileManager.attributesOfItem(atPath: normalizedLHS.path),
            let rhsAttributes = try? fileManager.attributesOfItem(atPath: normalizedRHS.path),
            let lhsDevice = lhsAttributes[.systemNumber] as? NSNumber,
            let rhsDevice = rhsAttributes[.systemNumber] as? NSNumber,
            let lhsFile = lhsAttributes[.systemFileNumber] as? NSNumber,
            let rhsFile = rhsAttributes[.systemFileNumber] as? NSNumber
        else {
            return false
        }

        return lhsDevice == rhsDevice && lhsFile == rhsFile
    }
}
