import SwiftUI

struct MirmirDeveloperRootView: View {
    @ObservedObject var bootstrap: MirmirAppBootstrap

    var body: some View {
        NavigationSplitView {
            MirmirModuleStatusSidebar(host: bootstrap.moduleHost)
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 340)
        } detail: {
            MirmirProductionRootView(bootstrap: bootstrap)
        }
    }
}

private struct MirmirModuleStatusSidebar: View {
    @ObservedObject var host: MirmirModuleHost

    var body: some View {
        List {
            Section("Runtime") {
                LabeledContent("Host", value: host.state.displayText)
            }

            Section("Modules") {
                ForEach(host.records) { record in
                    HStack(spacing: 10) {
                        Image(systemName: record.lifecycleState.symbolName)
                            .foregroundStyle(record.lifecycleState.color)
                            .frame(width: 16)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.descriptor.displayName)
                                .lineLimit(1)
                            Text(record.lifecycleState.displayText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Developer Status")
    }
}

private extension MirmirModuleHostState {
    var displayText: String {
        switch self {
        case .idle:
            return "Idle"
        case .starting:
            return "Starting"
        case .active:
            return "Active"
        case .stopped:
            return "Stopped"
        case .failed(let moduleID, _):
            return "Failed: \(moduleID)"
        }
    }
}

private extension MirmirModuleLifecycleState {
    var displayText: String {
        switch self {
        case .registered:
            return "Registered"
        case .starting:
            return "Starting"
        case .active:
            return "Active"
        case .stopped:
            return "Stopped"
        case .failed(let reason):
            return "Failed: \(reason)"
        }
    }

    var symbolName: String {
        switch self {
        case .registered:
            return "circle"
        case .starting:
            return "clock"
        case .active:
            return "checkmark.circle.fill"
        case .stopped:
            return "stop.circle"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }

    var color: Color {
        switch self {
        case .registered, .stopped:
            return .secondary
        case .starting:
            return .blue
        case .active:
            return .green
        case .failed:
            return .red
        }
    }
}
