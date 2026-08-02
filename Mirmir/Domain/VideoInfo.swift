import CoreMedia
import Foundation

struct VideoInfo: Equatable, Sendable {
    let url: URL
    let duration: CMTime
    let geometry: VideoGeometry
    let nominalFrameRate: Float?
    let minimumFrameDuration: CMTime?
    let estimatedFrameCount: Int?
    let estimatedDataRate: Float?
    let codecFourCC: FourCharCode?
    let hasAudio: Bool
    let audioTrackCount: Int
    let videoTrackCount: Int
    let isReadable: Bool
    let isPlayable: Bool
    let fileSizeBytes: Int64?
    let color: VideoColorInfo

    var filename: String {
        url.lastPathComponent
    }

    var naturalSize: CGSize {
        geometry.naturalSize
    }

    var displaySize: CGSize {
        geometry.displaySize
    }

    var preferredTransform: CGAffineTransform {
        geometry.preferredTransform
    }

    var cleanAperture: CGRect? {
        geometry.cleanAperture
    }
}
