import Foundation

enum AppState: Equatable, Sendable {
    case empty
    case probing(URL)
    case ready(VideoInfo)
    case processing(VideoInfo, UpscaleProgress)
    case completed(VideoInfo, UpscaleResult)
    case failed(MirmirError)
}
