import Foundation

enum MirmirDeploymentMode: String, Sendable {
    case development
    case production

    static let current: MirmirDeploymentMode = {
        #if DEBUG
        return .development
        #else
        return .production
        #endif
    }()
}
