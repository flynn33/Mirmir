import AVFoundation

enum OutputCodec: String, CaseIterable, Codable, Sendable {
    case hevc
    case h264
    case proRes422
    case proRes4444

    var displayName: String {
        switch self {
        case .hevc: "HEVC"
        case .h264: "H.264"
        case .proRes422: "Apple ProRes 422"
        case .proRes4444: "Apple ProRes 4444"
        }
    }

    var avVideoCodecType: AVVideoCodecType {
        switch self {
        case .hevc: .hevc
        case .h264: .h264
        case .proRes422: .proRes422
        case .proRes4444: .proRes4444
        }
    }

    /// Chroma-subsampled delivery formats require an even encoded raster.
    /// ProRes 4444 carries full-resolution color and alpha components, so the
    /// deterministic alpha route may preserve any positive integral geometry.
    var requiresEvenEncodedDimensions: Bool {
        self != .proRes4444
    }
}
