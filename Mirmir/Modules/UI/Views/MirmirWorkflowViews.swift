import SwiftUI

struct MirmirWorkflowRootView: View {
    @ObservedObject var viewModel: MirmirViewModel

    @Environment(\.colorScheme) private var colorScheme
    @State private var destination: MirmirWorkspaceDestination = .upscale
    @State private var appearanceMode: MirmirAppearanceMode = .system

    var body: some View {
        GeometryReader { proxy in
            content(width: proxy.size.width)
        }
        .frame(minWidth: 960, minHeight: 680)
    }

    private func content(width: CGFloat) -> some View {
        let theme = appearanceMode.tokens(for: colorScheme)
        let isCompact = width < 1120

        return HStack(spacing: 0) {
            MirmirSidebar(
                selection: $destination,
                theme: theme,
                isCompact: isCompact
            )

            VStack(spacing: 0) {
                MirmirWorkspaceHeader(
                    destination: destination,
                    viewModel: viewModel,
                    theme: theme,
                    showSettings: { destination = .settings },
                    showAbout: { destination = .about }
                )

                Rectangle()
                    .fill(theme.borderSubtle)
                    .frame(height: 1)

                workspaceContent(theme: theme, isCompact: isCompact)
            }
        }
        .background(theme.background)
        .foregroundStyle(theme.textPrimary)
        .tint(theme.accentPrimary)
    }

    @ViewBuilder
    private func workspaceContent(theme: MirmirThemeTokens, isCompact: Bool) -> some View {
        switch destination {
        case .dashboard:
            MirmirDashboardScreen(viewModel: viewModel, theme: theme)
        case .library:
            MirmirLibraryScreen(viewModel: viewModel, theme: theme)
        case .upscale:
            MirmirUpscaleWorkspaceView(
                viewModel: viewModel,
                theme: theme,
                isCompact: isCompact
            )
        case .queue:
            MirmirQueueScreen(viewModel: viewModel, theme: theme)
        case .presets:
            MirmirPresetsScreen(viewModel: viewModel, theme: theme)
        case .settings:
            MirmirSettingsScreen(
                viewModel: viewModel,
                theme: theme,
                appearanceMode: $appearanceMode
            )
        case .about:
            MirmirAboutWorkspaceScreen(viewModel: viewModel, theme: theme)
        case .diagnostics:
            MirmirDiagnosticsScreen(viewModel: viewModel, theme: theme)
        }
    }
}

enum MirmirWorkspaceDestination: String, CaseIterable, Identifiable {
    case dashboard
    case library
    case upscale
    case queue
    case presets
    case settings
    case about
    case diagnostics

    var id: String { rawValue }

    static let primary: [MirmirWorkspaceDestination] = [
        .dashboard,
        .library,
        .upscale,
        .queue,
        .presets,
        .settings
    ]

    static let utilities: [MirmirWorkspaceDestination] = [
        .about,
        .diagnostics
    ]

    var title: String {
        switch self {
        case .dashboard:
            return "Dashboard"
        case .library:
            return "Library"
        case .upscale:
            return "Upscale"
        case .queue:
            return "Queue"
        case .presets:
            return "Presets"
        case .settings:
            return "Settings"
        case .about:
            return "About Mirmir"
        case .diagnostics:
            return "Diagnostics"
        }
    }

    var symbolName: String {
        switch self {
        case .dashboard:
            return "gauge.with.dots.needle.33percent"
        case .library:
            return "folder"
        case .upscale:
            return "arrow.up.left.and.arrow.down.right"
        case .queue:
            return "list.bullet.rectangle"
        case .presets:
            return "slider.horizontal.3"
        case .settings:
            return "gearshape"
        case .about:
            return "info.circle"
        case .diagnostics:
            return "waveform.path.ecg.rectangle"
        }
    }
}

private struct MirmirSidebar: View {
    @Binding var selection: MirmirWorkspaceDestination
    let theme: MirmirThemeTokens
    let isCompact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.space4) {
            VStack(alignment: .leading, spacing: theme.spacing.space1) {
                Text("Mirmir")
                    .font(theme.typography.subtitle)
                    .foregroundStyle(theme.textPrimary)
                    .opacity(isCompact ? 0 : 1)
                Text("Deterministic Video Upscaler")
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.textTertiary)
                    .opacity(isCompact ? 0 : 1)
            }
            .frame(height: 44, alignment: .leading)

            VStack(spacing: theme.spacing.space1) {
                ForEach(MirmirWorkspaceDestination.primary) { item in
                    sidebarButton(for: item)
                }
            }

            Spacer(minLength: theme.spacing.space6)

            VStack(spacing: theme.spacing.space1) {
                ForEach(MirmirWorkspaceDestination.utilities) { item in
                    sidebarButton(for: item)
                }
            }
        }
        .padding(.horizontal, isCompact ? theme.spacing.space2 : theme.spacing.space3)
        .padding(.vertical, theme.spacing.space5)
        .frame(width: isCompact ? 68 : 204)
        .background(theme.backgroundAlt)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(theme.borderSubtle)
                .frame(width: 1)
        }
    }

    private func sidebarButton(for item: MirmirWorkspaceDestination) -> some View {
        let isSelected = item == selection

        return Button {
            selection = item
        } label: {
            HStack(spacing: theme.spacing.space2) {
                Image(systemName: item.symbolName)
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 22)

                if !isCompact {
                    Text(item.title)
                        .font(theme.typography.bodyEmphasis)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 38)
            .frame(maxWidth: .infinity, alignment: isCompact ? .center : .leading)
            .padding(.horizontal, isCompact ? theme.spacing.space1 : theme.spacing.space2)
            .foregroundStyle(isSelected ? theme.accentPrimary : theme.textSecondary)
            .background(
                RoundedRectangle(cornerRadius: theme.radius.medium)
                    .fill(isSelected ? theme.accentMuted : theme.backgroundAlt)
            )
        }
        .buttonStyle(.plain)
        .help(item.title)
        .accessibilityLabel(item.title)
    }
}

private struct MirmirWorkspaceHeader: View {
    let destination: MirmirWorkspaceDestination
    @ObservedObject var viewModel: MirmirViewModel
    let theme: MirmirThemeTokens
    let showSettings: () -> Void
    let showAbout: () -> Void

    var body: some View {
        HStack(spacing: theme.spacing.space4) {
            VStack(alignment: .leading, spacing: theme.spacing.space1) {
                Text(destination.title)
                    .font(theme.typography.title)
                    .foregroundStyle(theme.textPrimary)

                Text(subtitle)
                    .font(theme.typography.body)
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            Label(viewModel.engineReadinessText, systemImage: engineStatusIcon)
                .font(theme.typography.bodyEmphasis)
                .foregroundStyle(engineStatusColor)
                .accessibilityLabel("Processing status: \(viewModel.engineReadinessText)")

            Button(action: showSettings) {
                Image(systemName: "gearshape")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(MirmirIconButtonStyle(theme: theme))
            .help("Settings")
            .accessibilityLabel("Settings")

            Button(action: showAbout) {
                Image(systemName: "info.circle")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(MirmirIconButtonStyle(theme: theme))
            .help("About Mirmir")
            .accessibilityLabel("About Mirmir")
        }
        .padding(.horizontal, theme.spacing.space6)
        .padding(.vertical, theme.spacing.space4)
        .background(theme.surface)
    }

    private var subtitle: String {
        guard destination == .upscale else {
            return "Deterministic upscaling workspace"
        }
        guard let profile = viewModel.sourceProfile else {
            return "Choose video, configure output, and start upscale"
        }
        return profile.url.lastPathComponent + " to " + MirmirViewModel.fileLabel(for: viewModel.targetResolution)
    }

    private var engineStatusIcon: String {
        viewModel.ashBackendStatus == .available ? "checkmark.circle" : "exclamationmark.triangle"
    }

    private var engineStatusColor: Color {
        viewModel.ashBackendStatus == .available ? theme.success : theme.warning
    }
}
