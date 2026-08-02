import Foundation

struct UpscaleRequest: Equatable, Sendable {
    let inputURL: URL
    let outputURL: URL
    let backendID: UpscaleBackendID
    let targetWidth: Int
    let targetHeight: Int
    let outputCodec: OutputCodec
    let preserveAudio: Bool
    let overwriteExistingFile: Bool

    var targetSize: CGSize {
        CGSize(width: targetWidth, height: targetHeight)
    }
}
