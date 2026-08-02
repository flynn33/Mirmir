import CoreMedia

enum UpscalePhase: String, Equatable, Sendable {
    case probing = "Probing"
    case preparingBackend = "Preparing backend"
    case preparingReaderWriter = "Preparing media"
    case processingVideo = "Processing video"
    case processingAudio = "Processing audio"
    case finalizing = "Finalizing"
    case validatingOutput = "Validating output"
    case completed = "Completed"
}

struct UpscaleProgress: Equatable, Sendable {
    let phase: UpscalePhase
    let fractionCompleted: Double?
    let processedFrameCount: Int
    let processedTime: CMTime?
    let duration: CMTime?
    let actualBackendID: UpscaleBackendID?
}
