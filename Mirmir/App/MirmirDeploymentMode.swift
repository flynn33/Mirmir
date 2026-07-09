import Foundation

enum MirmirDeploymentMode: String, Sendable {
    case development
    case production

    static let current: MirmirDeploymentMode = resolve()

    static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> MirmirDeploymentMode {
        #if DEBUG
        if environment["MIRMIR_DEVELOPER_WORKSPACE"] == "1" {
            return .development
        }
        #endif

        return .production
    }
}
