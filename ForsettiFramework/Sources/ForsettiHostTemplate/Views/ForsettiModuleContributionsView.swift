import SwiftUI
import ForsettiCore

struct ForsettiModuleContributionsView: View {
    @ObservedObject var controller: ForsettiHostController
    let injectionRegistry: ForsettiViewInjectionRegistry
    let moduleID: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Module Controls")
                    .font(.title3.bold())
                GuideInfoButton(
                    text: "All module controls are executed through Forsetti routing/event APIs."
                )
            }

            if let contributions = controller.uiContributions(for: moduleID) {
                toolbarSection(contributions: contributions)
                routesSection(contributions: contributions)
                injectedViewsSection(contributions: contributions)
            } else {
                Text("No active module UI contributions are available.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func toolbarSection(contributions: UIContributions) -> some View {
        if !contributions.toolbarItems.isEmpty {
            Text("Module Actions")
                .font(.headline)
                .foregroundStyle(.secondary)

            ForEach(contributions.toolbarItems, id: \.itemID) { item in
                HStack(spacing: 8) {
                    Button {
                        controller.handleToolbarAction(item.action)
                    } label: {
                        HStack {
                            if let systemImageName = item.systemImageName {
                                Image(systemName: systemImageName)
                            }
                            Text(item.title)
                            Spacer()
                            Text(toolbarActionText(item.action))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    GuideInfoButton(
                        text: "Runs a module-provided command through Forsetti, not direct module networking."
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func routesSection(contributions: UIContributions) -> some View {
        if let schema = contributions.overlaySchema {
            Text("Module Routes")
                .font(.headline)
                .foregroundStyle(.secondary)

            ForEach(schema.pointers, id: \.pointerID) { pointer in
                HStack(spacing: 8) {
                    Button("Open Pointer: \(pointer.label)") {
                        controller.handleToolbarAction(.navigate(pointerID: pointer.pointerID))
                    }
                    GuideInfoButton(
                        text: "Resolves pointer navigation inside Forsetti routing policy."
                    )
                }
            }

            ForEach(schema.routes, id: \.routeID) { route in
                HStack(spacing: 8) {
                    Button("Open Route: \(route.path)") {
                        controller.handleToolbarAction(.openOverlay(routeID: route.routeID))
                    }
                    GuideInfoButton(
                        text: "Opens route through Forsetti routing controls."
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func injectedViewsSection(contributions: UIContributions) -> some View {
        let moduleWorkspaceInjections = contributions.viewInjections.filter { descriptor in
            descriptor.slot == SlotCatalog.moduleWorkspace || descriptor.slot == SlotCatalog.overlayMain
        }

        if !moduleWorkspaceInjections.isEmpty {
            Text("Module Views")
                .font(.headline)
                .foregroundStyle(.secondary)

            ForEach(sortedInjections(moduleWorkspaceInjections), id: \.injectionID) { injection in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Slot: \(injection.slot)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("Priority \(injection.priority)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    if let injectedView = injectionRegistry.resolve(viewID: injection.viewID) {
                        injectedView
                    } else {
                        Text("No host view registered for \(injection.viewID)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    private func sortedInjections(_ injections: [ViewInjectionDescriptor]) -> [ViewInjectionDescriptor] {
        injections.sorted { lhs, rhs in
            if lhs.slot == rhs.slot {
                return lhs.priority > rhs.priority
            }
            return lhs.slot < rhs.slot
        }
    }

    private func toolbarActionText(_ action: ToolbarAction) -> String {
        switch action {
        case let .navigate(pointerID):
            return "Navigate \(pointerID)"
        case let .openOverlay(routeID):
            return "Overlay \(routeID)"
        case let .publishEvent(type, _):
            return "Event \(type)"
        }
    }
}
