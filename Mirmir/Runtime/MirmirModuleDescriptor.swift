import Foundation

enum MirmirModuleKind: String, CaseIterable, Codable, Sendable {
    case service
    case ui
}

struct MirmirModuleDescriptor: Hashable, Identifiable, Sendable {
    let moduleID: String
    let displayName: String
    let versionString: String
    let entryPoint: String
    let kind: MirmirModuleKind

    var id: String { moduleID }
}
