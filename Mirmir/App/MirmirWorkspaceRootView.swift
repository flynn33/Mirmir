import SwiftUI

struct MirmirWorkspaceRootView: View {
    let viewModel: MirmirViewModel

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("mirmir.appearance") private var appearanceRawValue =
        MirmirAppearanceMode.system.rawValue
    @State private var destination: MirmirProductDestination = .upscale

    var body: some View {
        GeometryReader { proxy in
            workspace(width: proxy.size.width)
        }
        .frame(minWidth: 960, minHeight: 680)
        .preferredColorScheme(preferredColorScheme)
    }

    private func workspace(width: CGFloat) -> some View {
        let theme = appearanceMode.tokens(for: colorScheme)
        let compactSidebar = width < 1_120

        return HStack(spacing: 0) {
            MirmirProductSidebar(
                selection: $destination,
                theme: theme,
                compact: compactSidebar
            )

            VStack(spacing: 0) {
                MirmirProductHeader(
                    destination: destination,
                    viewModel: viewModel,
                    theme: theme,
                    showSettings: { destination = .settings },
                    showAbout: { destination = .about }
                )

                Rectangle()
                    .fill(theme.borderSubtle)
                    .frame(height: 1)

                screen(theme: theme, compact: compactSidebar)
            }
        }
        .background(theme.background)
        .foregroundStyle(theme.textPrimary)
        .tint(theme.accentPrimary)
    }

    @ViewBuilder
    private func screen(
        theme: MirmirThemeTokens,
        compact: Bool
    ) -> some View {
        switch destination {
        case .dashboard:
            MirmirProductDashboard(
                viewModel: viewModel,
                theme: theme,
                openUpscale: { destination = .upscale }
            )
        case .library:
            MirmirProductLibrary(
                viewModel: viewModel,
                theme: theme,
                openUpscale: { destination = .upscale }
            )
        case .upscale:
            MirmirProductUpscaleWorkspace(
                viewModel: viewModel,
                theme: theme,
                compact: compact,
                showMethods: { destination = .methods }
            )
        case .queue:
            MirmirProductQueue(viewModel: viewModel, theme: theme)
        case .methods:
            MirmirBackendCatalogView(
                viewModel: viewModel,
                theme: theme,
                selectAndReturn: { backendID in
                    viewModel.selectBackend(backendID)
                    destination = .upscale
                }
            )
        case .settings:
            MirmirProductSettings(
                viewModel: viewModel,
                theme: theme,
                appearance: appearanceBinding
            )
        case .about:
            MirmirProductAbout(theme: theme)
        case .diagnostics:
            MirmirProductDiagnostics(viewModel: viewModel, theme: theme)
        }
    }

    private var appearanceMode: MirmirAppearanceMode {
        MirmirAppearanceMode(rawValue: appearanceRawValue) ?? .system
    }

    private var appearanceBinding: Binding<MirmirAppearanceMode> {
        Binding(
            get: { appearanceMode },
            set: { appearanceRawValue = $0.rawValue }
        )
    }

    private var preferredColorScheme: ColorScheme? {
        switch appearanceMode {
        case .system: nil
        case .midnightNordic: .dark
        case .arcticIndigo: .light
        }
    }
}

enum MirmirProductDestination: String, CaseIterable, Identifiable {
    case dashboard
    case library
    case upscale
    case queue
    case methods
    case settings
    case about
    case diagnostics

    var id: String { rawValue }

    static let primary: [Self] = [
        .dashboard,
        .library,
        .upscale,
        .queue,
        .methods,
        .settings
    ]
    static let utilities: [Self] = [.about, .diagnostics]

    var title: String {
        switch self {
        case .dashboard: "Dashboard"
        case .library: "Library"
        case .upscale: "Upscale"
        case .queue: "Queue"
        case .methods: "Methods"
        case .settings: "Settings"
        case .about: "About Mirmir"
        case .diagnostics: "Diagnostics"
        }
    }

    var symbolName: String {
        switch self {
        case .dashboard: "gauge.with.dots.needle.33percent"
        case .library: "folder"
        case .upscale: "arrow.up.left.and.arrow.down.right"
        case .queue: "list.bullet.rectangle"
        case .methods: "slider.horizontal.3"
        case .settings: "gearshape"
        case .about: "info.circle"
        case .diagnostics: "waveform.path.ecg.rectangle"
        }
    }
}

private struct MirmirProductSidebar: View {
    @Binding var selection: MirmirProductDestination
    let theme: MirmirThemeTokens
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.space4) {
            HStack(spacing: theme.spacing.space2) {
                Image(systemName: "mountain.2.fill")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(theme.accentSecondary)
                    .frame(width: 32)
                if !compact {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("MIRMIR")
                            .font(.system(size: 17, weight: .bold))
                            .tracking(3)
                        Text("Deterministic Video Upscaler")
                            .font(theme.typography.micro)
                            .foregroundStyle(theme.textTertiary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                    }
                }
            }
            .frame(height: 44, alignment: .leading)

            VStack(spacing: theme.spacing.space1) {
                ForEach(MirmirProductDestination.primary) { item in
                    sidebarButton(item)
                }
            }

            Spacer(minLength: theme.spacing.space6)

            VStack(spacing: theme.spacing.space1) {
                ForEach(MirmirProductDestination.utilities) { item in
                    sidebarButton(item)
                }
            }
        }
        .padding(.horizontal, compact ? theme.spacing.space2 : theme.spacing.space3)
        .padding(.vertical, theme.spacing.space5)
        .frame(width: compact ? 68 : 204)
        .background(theme.backgroundAlt)
        .overlay(alignment: .trailing) {
            Rectangle().fill(theme.borderSubtle).frame(width: 1)
        }
    }

    private func sidebarButton(_ item: MirmirProductDestination) -> some View {
        let selected = item == selection
        return Button {
            selection = item
        } label: {
            HStack(spacing: theme.spacing.space2) {
                Image(systemName: item.symbolName)
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 22)
                if !compact {
                    Text(item.title)
                        .font(theme.typography.bodyEmphasis)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 38)
            .frame(
                maxWidth: .infinity,
                alignment: compact ? .center : .leading
            )
            .padding(.horizontal, compact ? theme.spacing.space1 : theme.spacing.space2)
            .foregroundStyle(
                selected ? theme.accentPrimary : theme.textSecondary
            )
            .background(
                RoundedRectangle(cornerRadius: theme.radius.medium)
                    .fill(selected ? theme.accentMuted : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .help(item.title)
        .accessibilityLabel(item.title)
    }
}

private struct MirmirProductHeader: View {
    let destination: MirmirProductDestination
    let viewModel: MirmirViewModel
    let theme: MirmirThemeTokens
    let showSettings: () -> Void
    let showAbout: () -> Void

    var body: some View {
        HStack(spacing: theme.spacing.space4) {
            VStack(alignment: .leading, spacing: theme.spacing.space1) {
                Text(destination.title)
                    .font(theme.typography.title)
                Text(subtitle)
                    .font(theme.typography.body)
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            Label(readiness.text, systemImage: readiness.symbol)
                .font(theme.typography.bodyEmphasis)
                .foregroundStyle(readiness.tone.color(theme: theme))
                .accessibilityLabel("Processing status: \(readiness.text)")
            Button(action: showSettings) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(MirmirProductIconButtonStyle(theme: theme))
            .help("Settings")
            Button(action: showAbout) {
                Image(systemName: "info.circle")
            }
            .buttonStyle(MirmirProductIconButtonStyle(theme: theme))
            .help("About Mirmir")
        }
        .padding(.horizontal, theme.spacing.space6)
        .padding(.vertical, theme.spacing.space4)
        .background(theme.surface)
    }

    private var subtitle: String {
        if let info = viewModel.currentVideoInfo {
            let output = viewModel.targetWidth > 0
                ? "\(viewModel.targetWidth) × \(viewModel.targetHeight)"
                : "target pending"
            return "\(info.filename) · \(output)"
        }
        return "Choose video, configure output, and start upscale"
    }

    private var readiness: (
        text: String,
        symbol: String,
        tone: MirmirProductStatusTone
    ) {
        switch viewModel.state {
        case .empty:
            return ("Waiting for source", "circle", .neutral)
        case .probing:
            return ("Analyzing source", "waveform", .active)
        case .processing:
            return ("Processing", "gearshape.2", .active)
        case .completed:
            return ("Complete", "checkmark.circle", .success)
        case .failed:
            return ("Needs attention", "exclamationmark.triangle", .danger)
        case .ready:
            if viewModel.isCheckingBackendAvailability {
                return ("Checking methods", "ellipsis.circle", .active)
            }
            switch viewModel.selectedBackendAvailability {
            case .available:
                return ("Ready", "checkmark.circle", .success)
            case .modelDownloadRequired:
                return ("Model required", "arrow.down.circle", .warning)
            case .unavailable:
                return ("Method unavailable", "exclamationmark.triangle", .warning)
            case nil:
                return ("Select a method", "circle", .neutral)
            }
        }
    }
}

private struct MirmirProductDashboard: View {
    let viewModel: MirmirViewModel
    let theme: MirmirThemeTokens
    let openUpscale: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.spacing.space5) {
                Text("A focused workspace for one source and one verified output.")
                    .font(theme.typography.subtitle)
                    .foregroundStyle(theme.textSecondary)

                HStack(spacing: theme.spacing.space3) {
                    MirmirProductStatusCard(
                        title: "Source",
                        primary: viewModel.currentVideoInfo?.filename ?? "No source",
                        secondary: MirmirPresentation.sizeText(
                            viewModel.currentVideoInfo?.geometry.encodedSize
                        ),
                        symbolName: "film",
                        tone: viewModel.currentVideoInfo == nil ? .neutral : .success,
                        theme: theme
                    )
                    MirmirProductStatusCard(
                        title: "Output",
                        primary: targetText,
                        secondary: viewModel.outputCodec.displayName,
                        symbolName: "rectangle.inset.filled.and.person.filled",
                        tone: viewModel.targetWidth > 0 ? .active : .neutral,
                        theme: theme
                    )
                    MirmirProductStatusCard(
                        title: "Method",
                        primary: selectedMethodTitle,
                        secondary: viewModel.selectedBackendAvailability?.statusText
                            ?? "Waiting for source",
                        symbolName: "cpu",
                        tone: viewModel.selectedBackendAvailability == .available
                            ? .success : .neutral,
                        theme: theme
                    )
                }

                MirmirProductPanel(theme: theme) {
                    HStack(spacing: theme.spacing.space5) {
                        Image(systemName: "mountain.2")
                            .font(.system(size: 46, weight: .light))
                            .foregroundStyle(theme.accentPrimary)
                        VStack(alignment: .leading, spacing: theme.spacing.space2) {
                            Text("Start an upscale")
                                .font(theme.typography.title)
                            Text(
                                "Choose a source, inspect exact method availability, "
                                    + "and create an atomic QuickTime output."
                            )
                            .font(theme.typography.body)
                            .foregroundStyle(theme.textSecondary)
                        }
                        Spacer()
                        Button(action: openUpscale) {
                            Label("Open Workspace", systemImage: "arrow.right")
                        }
                        .buttonStyle(MirmirProductSecondaryButtonStyle(theme: theme))
                    }
                }
            }
            .padding(theme.spacing.space6)
        }
        .background(theme.background)
    }

    private var targetText: String {
        guard viewModel.targetWidth > 0, viewModel.targetHeight > 0 else {
            return "Not configured"
        }
        return "\(viewModel.targetWidth) × \(viewModel.targetHeight)"
    }

    private var selectedMethodTitle: String {
        BackendDescriptor.descriptor(for: viewModel.selectedBackendID)?.title
            ?? viewModel.selectedBackendID.rawValue
    }
}

private struct MirmirProductLibrary: View {
    let viewModel: MirmirViewModel
    let theme: MirmirThemeTokens
    let openUpscale: () -> Void

    var body: some View {
        VStack(spacing: theme.spacing.space5) {
            MirmirProductPanel(theme: theme) {
                VStack(spacing: theme.spacing.space4) {
                    Image(systemName: "film.stack")
                        .font(.system(size: 42, weight: .light))
                        .foregroundStyle(theme.accentPrimary)
                    Text(viewModel.currentVideoInfo?.filename ?? "No video selected")
                        .font(theme.typography.subtitle)
                    Text(
                        "This remediated build keeps one active source and does not "
                            + "persist a media-history database."
                    )
                    .font(theme.typography.body)
                    .foregroundStyle(theme.textSecondary)
                    .multilineTextAlignment(.center)
                    HStack {
                        Button("Choose Video…") { viewModel.openVideo() }
                            .buttonStyle(MirmirProductSecondaryButtonStyle(theme: theme))
                        if viewModel.currentVideoInfo != nil {
                            Button("Open in Upscale", action: openUpscale)
                                .buttonStyle(MirmirProductSecondaryButtonStyle(theme: theme))
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
            Spacer()
        }
        .padding(theme.spacing.space6)
        .background(theme.background)
    }
}

private struct MirmirProductQueue: View {
    let viewModel: MirmirViewModel
    let theme: MirmirThemeTokens

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.space5) {
            MirmirProductPanel(theme: theme) {
                HStack(spacing: theme.spacing.space4) {
                    Image(systemName: queueSymbol)
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(queueTone.color(theme: theme))
                    VStack(alignment: .leading, spacing: theme.spacing.space2) {
                        Text(queueTitle).font(theme.typography.subtitle)
                        Text(queueDetail)
                            .font(theme.typography.body)
                            .foregroundStyle(theme.textSecondary)
                    }
                    Spacer()
                    if viewModel.isProcessing {
                        Button("Cancel", role: .destructive) {
                            viewModel.cancelProcessing()
                        }
                        .buttonStyle(MirmirProductSecondaryButtonStyle(theme: theme))
                    }
                }
            }
            Text(
                "Mirmir intentionally runs one bounded job at a time; this screen "
                    + "shows the live job and does not imply a persistent queue."
            )
            .font(theme.typography.caption)
            .foregroundStyle(theme.textTertiary)
            Spacer()
        }
        .padding(theme.spacing.space6)
        .background(theme.background)
    }

    private var queueTitle: String {
        switch viewModel.state {
        case .processing: "One job is processing"
        case .completed: "The last job completed"
        case .failed: "The last job needs attention"
        default: "No active job"
        }
    }

    private var queueDetail: String {
        switch viewModel.state {
        case .processing(let source, let progress):
            return "\(source.filename) · \(progress.processedFrameCount) frames"
        case .completed(_, let result):
            return result.outputURL.lastPathComponent
        case .failed(let error):
            return error.localizedDescription
        default:
            return "Configure a job in the Upscale workspace."
        }
    }

    private var queueSymbol: String {
        switch viewModel.state {
        case .processing: "gearshape.2"
        case .completed: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        default: "tray"
        }
    }

    private var queueTone: MirmirProductStatusTone {
        switch viewModel.state {
        case .processing: .active
        case .completed: .success
        case .failed: .danger
        default: .neutral
        }
    }
}

private struct MirmirProductSettings: View {
    let viewModel: MirmirViewModel
    let theme: MirmirThemeTokens
    @Binding var appearance: MirmirAppearanceMode

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.spacing.space5) {
                MirmirProductPanel(theme: theme) {
                    VStack(alignment: .leading, spacing: theme.spacing.space4) {
                        Text("Appearance").font(theme.typography.subtitle)
                        Picker("Appearance", selection: $appearance) {
                            ForEach(MirmirAppearanceMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }

                MirmirProductPanel(theme: theme) {
                    VStack(alignment: .leading, spacing: theme.spacing.space4) {
                        Text("Current output preferences")
                            .font(theme.typography.subtitle)
                        Picker(
                            "Codec",
                            selection: Binding(
                                get: { viewModel.outputCodec },
                                set: { viewModel.setOutputCodec($0) }
                            )
                        ) {
                            ForEach(OutputCodec.allCases, id: \.self) { codec in
                                Text(codec.displayName).tag(codec)
                            }
                        }
                        .pickerStyle(.segmented)
                        Toggle(
                            "Preserve the source audio track when present",
                            isOn: Binding(
                                get: { viewModel.preserveAudio },
                                set: { viewModel.setPreserveAudio($0) }
                            )
                        )
                    }
                }

                Text(
                    "Source URLs are not persisted without security-scoped bookmarks. "
                        + "Backend selection remains explicit and never silently falls back."
                )
                .font(theme.typography.caption)
                .foregroundStyle(theme.textTertiary)
            }
            .padding(theme.spacing.space6)
        }
        .background(theme.background)
    }
}

private struct MirmirProductAbout: View {
    let theme: MirmirThemeTokens

    var body: some View {
        VStack(spacing: theme.spacing.space5) {
            MirmirProductPanel(theme: theme) {
                VStack(spacing: theme.spacing.space3) {
                    Image(systemName: "mountain.2.fill")
                        .font(.system(size: 56, weight: .light))
                        .foregroundStyle(theme.accentPrimary)
                    Text("MIRMIR")
                        .font(.system(size: 25, weight: .bold))
                        .tracking(5)
                    Text("Deterministic Video Upscaler")
                        .font(theme.typography.subtitle)
                        .foregroundStyle(theme.textSecondary)
                    Text("macOS 15.4 or later · Sandboxed · One active job")
                        .font(theme.typography.caption)
                        .foregroundStyle(theme.textTertiary)
                    if let licenseURL = Bundle.main.url(
                        forResource: "ASH-Model-LICENSE",
                        withExtension: "txt"
                    ) {
                        Link("ASH Model Acknowledgments", destination: licenseURL)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            Spacer()
        }
        .padding(theme.spacing.space6)
        .background(theme.background)
    }
}

private struct MirmirProductDiagnostics: View {
    let viewModel: MirmirViewModel
    let theme: MirmirThemeTokens

    var body: some View {
        ScrollView {
            MirmirProductPanel(theme: theme) {
                VStack(alignment: .leading, spacing: theme.spacing.space3) {
                    Text("Current product state").font(theme.typography.subtitle)
                    diagnostic("Source", viewModel.currentVideoInfo?.filename ?? "None")
                    diagnostic(
                        "Target",
                        viewModel.targetWidth > 0
                            ? "\(viewModel.targetWidth) × \(viewModel.targetHeight)"
                            : "None"
                    )
                    diagnostic(
                        "Selected method",
                        BackendDescriptor.descriptor(
                            for: viewModel.selectedBackendID
                        )?.title ?? viewModel.selectedBackendID.rawValue
                    )
                    diagnostic(
                        "Availability",
                        viewModel.selectedBackendAvailability?.statusText
                            ?? "Waiting for source"
                    )
                    Divider().overlay(theme.borderSubtle)
                    Text(
                        "The deterministic Metal preview creates its P05 runtime ABI "
                            + "in memory, compiles with precise FP32 functions, and never "
                            + "substitutes the CPU backend. It is not represented as a "
                            + "release-locked artifact."
                    )
                    .font(theme.typography.body)
                    .foregroundStyle(theme.textSecondary)
                }
            }
            .padding(theme.spacing.space6)
        }
        .background(theme.background)
    }

    private func diagnostic(_ label: String, _ value: String) -> some View {
        LabeledContent(label) {
            Text(value)
                .font(theme.typography.body.monospaced())
                .foregroundStyle(theme.textSecondary)
                .textSelection(.enabled)
        }
    }
}
