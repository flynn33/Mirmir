import Foundation

enum AudioOutputResult: String, Equatable, Sendable {
    case preserved = "Preserved"
    case transcoded = "Transcoded"
    case absent = "Absent"
    case omitted = "Not requested"
}

struct UpscaleResult: Equatable, Sendable {
    let outputURL: URL
    let actualBackendID: UpscaleBackendID
    let encodedWidth: Int
    let encodedHeight: Int
    let durationSeconds: Double
    let outputCodec: OutputCodec
    let audioResult: AudioOutputResult
    let processedFrameCount: Int
    let processingDurationSeconds: Double
}
