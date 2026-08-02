import CoreVideo
import Foundation

enum VideoDynamicRange: String, Equatable, Sendable {
    case sdr = "SDR"
    case hdr = "HDR"
    case unknown = "Unknown"
}

struct VideoColorInfo: Equatable, Sendable {
    let colorPrimaries: String?
    let transferFunction: String?
    let yCbCrMatrix: String?
    let bitDepth: Int?
    let pixelFormat: OSType?
    let isFullRange: Bool?
    let fieldCount: Int?
    let fieldDetail: String?
    let hasMasteringDisplayMetadata: Bool
    let hasContentLightLevelMetadata: Bool
    let dynamicRange: VideoDynamicRange

    static let unknown = VideoColorInfo(
        colorPrimaries: nil,
        transferFunction: nil,
        yCbCrMatrix: nil,
        bitDepth: nil,
        pixelFormat: nil,
        isFullRange: nil,
        fieldCount: nil,
        fieldDetail: nil,
        hasMasteringDisplayMetadata: false,
        hasContentLightLevelMetadata: false,
        dynamicRange: .unknown
    )

    var isHDR: Bool? {
        switch dynamicRange {
        case .hdr:
            true
        case .sdr:
            false
        case .unknown:
            nil
        }
    }
}
