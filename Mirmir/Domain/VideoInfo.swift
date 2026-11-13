import CoreMedia
import CoreVideo
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
    var proRes422SourceFacts: ProRes422SourceFactsV4? = nil
    var softwareWorkingVideoPolicy: OriginalSoftwareWorkingVideoPolicy? = nil

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

extension VideoInfo {
    var proRes422WorkingFormat: ProRes422WorkingFormatV4? {
        get throws {
            guard let facts = proRes422SourceFacts else { return nil }
            guard let primaries = color.colorPrimaries, let transfer = color.transferFunction,
                  let matrix = color.yCbCrMatrix, color.isFullRange == false else {
                throw ProRes422WorkingFormatV4Error.invalidPolicy
            }
            return try ProRes422WorkingFormatV4(width: facts.width, height: facts.height,
                scan: facts.scan, primaries: primaries, transfer: transfer, matrix: matrix)
        }
    }

    func processingColor(proRes delivery: ProRes422WorkingFormatV4?) -> VideoColorInfo {
        guard let delivery else { return color }
        return VideoColorInfo(colorPrimaries: delivery.primaries,
            transferFunction: delivery.transfer, yCbCrMatrix: delivery.matrix,
            bitDepth: 10, pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            isFullRange: false, fieldCount: delivery.scan.fieldCount,
            fieldDetail: delivery.scan.fieldDetail, alphaModel: color.alphaModel,
            hasMasteringDisplayMetadata: color.hasMasteringDisplayMetadata,
            hasContentLightLevelMetadata: color.hasContentLightLevelMetadata,
            dynamicRange: color.dynamicRange, chromaSiting: .left,
            chromaSitingBottomField: delivery.scan == .progressive ? nil : .left)
    }
}
