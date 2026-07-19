import SwiftUI

struct MirmirDashboardScreen: View {
    @ObservedObject var viewModel: MirmirViewModel
    let theme: MirmirThemeTokens

    var body: some View {
        MirmirScreenScaffold(theme: theme) {
            MirmirPanel(theme: theme) {
                VStack(alignment: .leading, spacing: theme.spacing.space4) {
                    screenHeader("Dashboard", "Recent work, active processing, and system readiness.", theme: theme)

                    HStack(spacing: theme.spacing.space3) {
                        dashboardMetric("Active queue", viewModel.state.isRunning ? "1 running" : "None", "Queue")
                        dashboardMetric("Readiness", viewModel.engineReadinessText, "Status")
                        dashboardMetric("Current source", sourceName, "Source")
                    }
                }
            }

            MirmirPanel(theme: theme) {
                VStack(alignment: .leading, spacing: theme.spacing.space3) {
                    screenHeader("Upscale workflow", "Prepare source and output selections while roadmap capability work continues.", theme: theme)
                    Text(viewModel.canStartFailureReason ?? "Use the Upscale workspace to configure and start processing.")
                        .font(theme.typography.body)
                        .foregroundStyle(theme.textSecondary)
                }
            }
        }
    }

    private var sourceName: String {
        viewModel.sourceProfile?.url.lastPathComponent ?? "Not selected"
    }

    private func dashboardMetric(_ title: String, _ value: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: theme.spacing.space2) {
            Text(caption)
                .font(theme.typography.captionEmphasis)
                .foregroundStyle(theme.textTertiary)
            Text(value)
                .font(theme.typography.subtitle)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
            Text(title)
                .font(theme.typography.caption)
                .foregroundStyle(theme.textSecondary)
        }
        .padding(theme.spacing.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: theme.radius.large)
                .fill(theme.surface)
        )
        .overlay {
            RoundedRectangle(cornerRadius: theme.radius.large)
                .stroke(theme.borderSubtle, lineWidth: 1)
        }
    }
}

struct MirmirLibraryScreen: View {
    @ObservedObject var viewModel: MirmirViewModel
    let theme: MirmirThemeTokens

    var body: some View {
        MirmirScreenScaffold(theme: theme) {
            MirmirPanel(theme: theme) {
                VStack(alignment: .leading, spacing: theme.spacing.space4) {
                    screenHeader("Library", "Imported sources and completed outputs will appear here.", theme: theme)

                    if let profile = viewModel.sourceProfile {
                        libraryRow(
                            title: profile.url.lastPathComponent,
                            detail: MirmirViewModel.fileLabel(for: profile.resolution),
                            symbol: "film"
                        )
                    } else {
                        emptyMessage("No source videos are loaded. Use Choose Source in the Upscale workspace.", theme: theme)
                    }
                }
            }
        }
    }

    private func libraryRow(title: String, detail: String, symbol: String) -> some View {
        HStack(spacing: theme.spacing.space3) {
            Image(systemName: symbol)
                .foregroundStyle(theme.accentPrimary)
            VStack(alignment: .leading, spacing: theme.spacing.space1) {
                Text(title)
                    .font(theme.typography.bodyEmphasis)
                Text(detail)
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.textSecondary)
            }
            Spacer()
            Button("Reveal Output") {
                viewModel.revealOutputInFinder()
            }
            .buttonStyle(MirmirSecondaryButtonStyle(theme: theme))
            .disabled({
                if case .finished = viewModel.state { return false }
                return true
            }())
        }
        .padding(theme.spacing.space3)
        .background(
            RoundedRectangle(cornerRadius: theme.radius.medium)
                .fill(theme.surface)
        )
    }
}

struct MirmirQueueScreen: View {
    @ObservedObject var viewModel: MirmirViewModel
    let theme: MirmirThemeTokens

    var body: some View {
        MirmirScreenScaffold(theme: theme) {
            MirmirPanel(theme: theme) {
                VStack(alignment: .leading, spacing: theme.spacing.space4) {
                    HStack {
                        screenHeader("Queue", "Active, pending, completed, and failed upscale work.", theme: theme)
                        Spacer()
                        Button("Clear Completed") {}
                            .buttonStyle(MirmirSecondaryButtonStyle(theme: theme))
                            .disabled(true)
                    }

                    queueContent
                }
            }
        }
    }

    @ViewBuilder
    private var queueContent: some View {
        switch viewModel.state {
        case .running:
            queueRow("Active", detail: sourceDetail, tone: .active)
        case .finished:
            queueRow("Completed", detail: sourceDetail, tone: .success)
        case .failed(let reason):
            queueRow("Failed", detail: reason, tone: .danger)
            Button("Retry") {}
                .buttonStyle(MirmirSecondaryButtonStyle(theme: theme))
                .disabled(true)
        default:
            emptyMessage("No queued work. Start an upscale from the Upscale workspace.", theme: theme)
            queueRow("Pending", detail: "No pending items", tone: .neutral)
            queueRow("Completed", detail: "No completed items", tone: .neutral)
            queueRow("Failed", detail: "No failed items", tone: .neutral)
        }
    }

    private var sourceDetail: String {
        viewModel.sourceProfile?.url.lastPathComponent ?? "Current source"
    }

    private func queueRow(_ title: String, detail: String, tone: MirmirStatusTone) -> some View {
        HStack(spacing: theme.spacing.space3) {
            Image(systemName: "list.bullet.rectangle")
                .foregroundStyle(tone.color(theme: theme))
            VStack(alignment: .leading, spacing: theme.spacing.space1) {
                Text(title)
                    .font(theme.typography.bodyEmphasis)
                Text(detail)
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(theme.spacing.space3)
        .background(
            RoundedRectangle(cornerRadius: theme.radius.medium)
                .fill(theme.surface)
        )
        .overlay {
            RoundedRectangle(cornerRadius: theme.radius.medium)
                .stroke(tone.borderColor(theme: theme), lineWidth: 1)
        }
    }
}

struct MirmirPresetsScreen: View {
    @ObservedObject var viewModel: MirmirViewModel
    let theme: MirmirThemeTokens

    private let presets = [
        ("Balanced", "Prepared balanced processing profile", "Controls remain inactive"),
        ("Detail Max", "Prepared detail recovery profile", "High detail, medium edge"),
        ("Edge Max", "Prepared edge fidelity profile", "High edge, medium detail"),
        ("Smooth", "Prepared low-edge profile", "Temporal on, low edge"),
        ("Custom", "Current inspector settings", "Editable after preset storage is available")
    ]

    var body: some View {
        MirmirScreenScaffold(theme: theme) {
            MirmirPanel(theme: theme) {
                VStack(alignment: .leading, spacing: theme.spacing.space4) {
                    HStack {
                        screenHeader("Presets", "Repeatable upscale configurations.", theme: theme)
                        Spacer()
                        Button("Save Preset") {}
                            .buttonStyle(MirmirSecondaryButtonStyle(theme: theme))
                            .disabled(true)
                    }

                    ForEach(presets, id: \.0) { preset in
                        presetRow(name: preset.0, description: preset.1, summary: preset.2)
                    }
                }
            }
        }
    }

    private func presetRow(name: String, description: String, summary: String) -> some View {
        HStack(spacing: theme.spacing.space3) {
            Image(systemName: name == viewModel.qualityMode.title ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(name == viewModel.qualityMode.title ? theme.success : theme.textTertiary)
            VStack(alignment: .leading, spacing: theme.spacing.space1) {
                Text(name)
                    .font(theme.typography.bodyEmphasis)
                Text(description)
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.textSecondary)
                Text(summary)
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.textTertiary)
            }
            Spacer()
        }
        .padding(theme.spacing.space3)
        .background(
            RoundedRectangle(cornerRadius: theme.radius.medium)
                .fill(theme.surface)
        )
    }
}

struct MirmirSettingsScreen: View {
    @ObservedObject var viewModel: MirmirViewModel
    let theme: MirmirThemeTokens
    @Binding var appearanceMode: MirmirAppearanceMode

    var body: some View {
        MirmirScreenScaffold(theme: theme) {
            MirmirPanel(theme: theme) {
                VStack(alignment: .leading, spacing: theme.spacing.space5) {
                    screenHeader("Settings", "Appearance, defaults, processing, output, diagnostics, and advanced options.", theme: theme)

                    MirmirFieldRow("Appearance", theme: theme) {
                        Picker("Appearance", selection: $appearanceMode) {
                            ForEach(MirmirAppearanceMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    MirmirFieldRow("Default Profile", theme: theme) {
                        Picker("Default Profile", selection: Binding.constant(MirmirQualityMode.balanced)) {
                            ForEach(MirmirQualityMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .disabled(true)
                        .help("Additional processing profiles are not implemented yet.")
                    }

                    MirmirFieldRow("Default Output Format", theme: theme) {
                        Picker("Default Output Format", selection: $viewModel.codec) {
                            ForEach(OutputCodec.allCases) { codec in
                                Text(codec.inspectorTitle).tag(codec)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    settingsNote("Processing", viewModel.canStartFailureReason ?? "Processing is available.")
                    settingsNote("Diagnostics", viewModel.engineReadinessText)
                    settingsNote("Advanced", "Advanced controls remain inactive until additional processing options are available.")
                }
            }
        }
    }

    private func settingsNote(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: theme.spacing.space1) {
            Text(title)
                .font(theme.typography.captionEmphasis)
                .foregroundStyle(theme.textSecondary)
            Text(detail)
                .font(theme.typography.body)
                .foregroundStyle(theme.textTertiary)
        }
    }
}

struct MirmirAboutWorkspaceScreen: View {
    @ObservedObject var viewModel: MirmirViewModel
    let theme: MirmirThemeTokens

    var body: some View {
        MirmirScreenScaffold(theme: theme) {
            MirmirPanel(theme: theme) {
                MirmirAboutView(viewModel: viewModel, showsTechnicalDetails: true)
            }
        }
    }
}

struct MirmirDiagnosticsScreen: View {
    @ObservedObject var viewModel: MirmirViewModel
    let theme: MirmirThemeTokens

    var body: some View {
        MirmirScreenScaffold(theme: theme) {
            MirmirPanel(theme: theme) {
                VStack(alignment: .leading, spacing: theme.spacing.space4) {
                    screenHeader("Diagnostics", "Local processing readiness and recent state.", theme: theme)
                    diagnosticRow("Processing status", viewModel.engineReadinessText)
                    if let reason = viewModel.engineAvailabilityReason {
                        diagnosticRow("Availability", reason)
                    }
                    diagnosticRow("Model assets", String(describing: viewModel.modelStatus))
                    diagnosticRow("Workflow state", viewModel.state.statusTitle)
                }
            }
        }
    }

    private func diagnosticRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(theme.textSecondary)
            Spacer()
            Text(value)
                .font(theme.typography.bodyEmphasis.monospacedDigit())
                .foregroundStyle(theme.textPrimary)
        }
        .font(theme.typography.body)
    }
}

struct MirmirScreenScaffold<Content: View>: View {
    let theme: MirmirThemeTokens
    let content: Content

    init(theme: MirmirThemeTokens, @ViewBuilder content: () -> Content) {
        self.theme = theme
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.spacing.space4) {
                content
            }
            .padding(theme.spacing.space5)
            .frame(maxWidth: 960, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(theme.background)
    }
}

@ViewBuilder
func screenHeader(_ title: String, _ subtitle: String, theme: MirmirThemeTokens) -> some View {
    VStack(alignment: .leading, spacing: theme.spacing.space1) {
        Text(title)
            .font(theme.typography.subtitle)
            .foregroundStyle(theme.textPrimary)
        Text(subtitle)
            .font(theme.typography.body)
            .foregroundStyle(theme.textSecondary)
    }
}

@ViewBuilder
func emptyMessage(_ message: String, theme: MirmirThemeTokens) -> some View {
    Text(message)
        .font(theme.typography.body)
        .foregroundStyle(theme.textSecondary)
        .padding(.vertical, theme.spacing.space2)
}
