import Foundation
import SwiftUI

enum MirmirViewRegistryError: Error, Equatable, LocalizedError {
    case invalidViewID
    case duplicateViewID(String)

    var errorDescription: String? {
        switch self {
        case .invalidViewID:
            return "View ID must not be empty"
        case .duplicateViewID(let viewID):
            return "View ID is already registered: \(viewID)"
        }
    }
}

@MainActor
final class MirmirViewRegistry {
    private var factories: [String: () -> AnyView] = [:]

    var registeredViewIDs: [String] {
        factories.keys.sorted()
    }

    func register<Content: View>(
        viewID: String,
        @ViewBuilder factory: @escaping () -> Content
    ) throws {
        guard !viewID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MirmirViewRegistryError.invalidViewID
        }
        guard factories[viewID] == nil else {
            throw MirmirViewRegistryError.duplicateViewID(viewID)
        }
        factories[viewID] = { AnyView(factory()) }
    }

    func resolve(viewID: String) -> AnyView? {
        factories[viewID]?()
    }
}
