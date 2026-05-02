import Combine
import Foundation

@MainActor
public final class UISurfaceManager: ObservableObject {
    @Published public private(set) var themeMask: ThemeMask?
    @Published public private(set) var toolbarItems: [ToolbarItemDescriptor] = []
    @Published public private(set) var viewInjectionsBySlot: [String: [ViewInjectionDescriptor]] = [:]
    @Published public private(set) var overlaySchema: OverlaySchema?

    private var contributionsByModule: [String: UIContributions] = [:]

    public init() {}

    public func apply(moduleID: String, contributions: UIContributions) {
        contributionsByModule[moduleID] = contributions
        rebuildSurfaceState()
    }

    public func remove(moduleID: String) {
        contributionsByModule[moduleID] = nil
        rebuildSurfaceState()
    }

    public func clear() {
        contributionsByModule.removeAll()
        rebuildSurfaceState()
    }

    private func rebuildSurfaceState() {
        let orderedContributions = contributionsByModule
            .sorted(by: { $0.key < $1.key })
            .map(\.value)

        themeMask = orderedContributions.compactMap(\.themeMask).last
        toolbarItems = orderedContributions.flatMap(\.toolbarItems)

        let injections = orderedContributions
            .flatMap(\.viewInjections)
            .sorted { lhs, rhs in
                if lhs.slot == rhs.slot {
                    return lhs.priority > rhs.priority
                }
                return lhs.slot < rhs.slot
            }

        viewInjectionsBySlot = Dictionary(grouping: injections, by: \.slot)

        let schemas = orderedContributions.compactMap(\.overlaySchema)
        guard !schemas.isEmpty else {
            overlaySchema = nil
            return
        }

        var pointersByID: [String: NavigationPointer] = [:]
        var routesByID: [String: OverlayRoute] = [:]

        for schema in schemas {
            for pointer in schema.pointers {
                pointersByID[pointer.pointerID] = pointer
            }
            for route in schema.routes {
                routesByID[route.routeID] = route
            }
        }

        overlaySchema = OverlaySchema(
            schemaID: "forsetti.overlay.composite",
            pointers: pointersByID.values.sorted(by: { $0.pointerID < $1.pointerID }),
            routes: routesByID.values.sorted(by: { $0.routeID < $1.routeID })
        )
    }
}
