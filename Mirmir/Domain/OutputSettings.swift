import AVFoundation

enum OutputCodec: String, CaseIterable, Codable, Sendable {
    case hevc
    case h264
    case proRes422

    var displayName: String {
        switch self {
        case .hevc: "HEVC"
        case .h264: "H.264"
        case .proRes422: "Apple ProRes 422"
        }
    }

    var avVideoCodecType: AVVideoCodecType {
        switch self {
        case .hevc: .hevc
        case .h264: .h264
        case .proRes422: .proRes422
        }
    }
}
