import CoreMedia
import SwiftUI

struct MirmirWorkspaceRootView: View {
    let viewModel: MirmirViewModel

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("mirmir.appearance") private var appearanceRawValue =
        MirmirAppearanceMode.system.rawValue
    @State private var destination: MirmirProductDestination = .dashboard
    @State private var pendingMethodSelection: PendingMethodSelection?
    @State private var dashboardTelemetry = MirmirDashboardTelemetry()

    var body: some View {
        GeometryReader { proxy in
            workspace(width: proxy.size.width)
        }
        .frame(minWidth: 960, minHeight: 680)
        .preferredColorScheme(preferredColorScheme)
        .task {
            await viewModel.initializeWorkflow()
            await dashboardTelemetry.monitor()
        }
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
        .alert(item: $pendingMethodSelection) { pending in
            Alert(
                title: Text(pending.adjustment.alertTitle),
                message: Text(pending.adjustment.message),
                primaryButton: .default(
                    Text(pending.adjustment.confirmationTitle)
                ) {
                    viewModel.applyBackendSelectionAdjustment(
                        pending.adjustment
                    )
                    if pending.returnToUpscale {
                        destination = .upscale
                    }
                },
                secondaryButton: .cancel()
            )
        }
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
                telemetry: dashboardTelemetry,
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
                showMethods: { destination = .methods },
                selectMethod: { backendID in
                    requestMethodSelection(backendID)
                }
            )
        case .queue:
            MirmirProductQueue(viewModel: viewModel, theme: theme)
        case .methods:
            MirmirBackendCatalogView(
                viewModel: viewModel,
                theme: theme,
                selectAndReturn: { backendID in
                    requestMethodSelection(
                        backendID,
                        returnToUpscale: true
                    )
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

    private func requestMethodSelection(
        _ backendID: UpscaleBackendID,
        returnToUpscale: Bool = false
    ) {
        if let adjustment = viewModel.targetAdjustmentForSelecting(backendID) {
            pendingMethodSelection = PendingMethodSelection(
                adjustment: adjustment,
                returnToUpscale: returnToUpscale
            )
            return
        }
        viewModel.selectBackend(backendID)
        if returnToUpscale {
            destination = .upscale
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

private struct PendingMethodSelection: Identifiable {
    let id = UUID()
    let adjustment: BackendSelectionTargetAdjustment
    let returnToUpscale: Bool
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
            MirmirBrandLockup(
                layout: compact ? .markOnly : .horizontal,
                iconSize: compact ? 38 : 36,
                theme: theme
            )
            .frame(height: 44, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)

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
    let telemetry: MirmirDashboardTelemetry
    let theme: MirmirThemeTokens
    let openUpscale: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.spacing.space5) {
                HStack(alignment: .center, spacing: theme.spacing.space4) {
                    VStack(alignment: .leading, spacing: theme.spacing.space1) {
                        Text("Processing Overview")
                            .font(theme.typography.display)
                        Text(
                            "Live job status, media configuration, and Mirmir process telemetry."
                        )
                        .font(theme.typography.body)
                        .foregroundStyle(theme.textSecondary)
                    }
                    Spacer(minLength: theme.spacing.space4)
                    Label(telemetryStatus.title, systemImage: telemetryStatus.symbol)
                        .font(theme.typography.captionEmphasis)
                        .foregroundStyle(telemetryStatus.tone.color(theme: theme))
                        .padding(.horizontal, theme.spacing.space3)
                        .padding(.vertical, theme.spacing.space2)
                        .background(Capsule().fill(theme.surfaceElevated))
                        .overlay {
                            Capsule().stroke(theme.borderSubtle, lineWidth: 1)
                        }
                }

                sectionLabel("Job Configuration", symbol: "slider.horizontal.3")
                LazyVGrid(
                    columns: [
                        GridItem(
                            .adaptive(minimum: 190, maximum: 320),
                            spacing: theme.spacing.space3
                        )
                    ],
                    spacing: theme.spacing.space3
                ) {
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

                sectionLabel("Live Telemetry", symbol: "waveform.path.ecg")
                LazyVGrid(
                    columns: [
                        GridItem(
                            .adaptive(minimum: 165, maximum: 260),
                            spacing: theme.spacing.space3
                        )
                    ],
                    spacing: theme.spacing.space3
                ) {
                    MirmirProductMetricCard(
                        title: "Mirmir CPU",
                        primary: cpuText,
                        secondary: "Activity Monitor scale · may exceed 100%",
                        symbolName: "cpu",
                        tone: telemetry.snapshot == nil ? .neutral : .active,
                        progress: telemetry.snapshot?.processCPUPercent.map {
                            $0 / 100
                        },
                        theme: theme
                    )
                    MirmirProductMetricCard(
                        title: "Memory",
                        primary: memoryText,
                        secondary: residentMemoryText,
                        symbolName: "memorychip",
                        tone: telemetry.snapshot == nil ? .neutral : .active,
                        progress: nil,
                        theme: theme
                    )
                    MirmirProductMetricCard(
                        title: "GPU Route",
                        primary: gpuRoute.primary,
                        secondary: gpuRoute.secondary,
                        symbolName: "gauge.with.dots.needle.67percent",
                        tone: gpuRoute.tone,
                        progress: nil,
                        theme: theme
                    )
                    .help(
                        "Shows whether Mirmir is using an explicit Metal processing "
                            + "route. This is not system GPU utilization."
                    )
                    MirmirProductMetricCard(
                        title: "Disk I/O",
                        primary: diskReadText,
                        secondary: "Write \(diskWriteText)",
                        symbolName: "externaldrive",
                        tone: telemetry.snapshot == nil ? .neutral : .active,
                        progress: nil,
                        theme: theme
                    )
                }

                sectionLabel("Progress", symbol: "chart.bar.doc.horizontal")
                MirmirProductPanel(theme: theme) {
                    VStack(spacing: theme.spacing.space4) {
                        MirmirProductProgressRow(
                            title: "Queue Progress",
                            detail: queueDetail,
                            valueText: queueValueText,
                            symbolName: "list.bullet.rectangle",
                            fraction: jobProgressFraction,
                            theme: theme
                        )
                        Divider().overlay(theme.borderSubtle)
                        MirmirProductProgressRow(
                            title: "Video Progress",
                            detail: videoProgressDetail,
                            valueText: videoProgressValue,
                            symbolName: "film.stack",
                            fraction: videoProgressFraction,
                            theme: theme
                        )
                    }
                }

                MirmirProductPanel(theme: theme) {
                    HStack(spacing: theme.spacing.space5) {
                        MirmirBrandLockup(
                            layout: .markOnly,
                            iconSize: 50,
                            theme: theme
                        )
                        .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: theme.spacing.space2) {
                            Text(viewModel.currentVideoInfo == nil
                                ? "Start an upscale"
                                : "Continue in the workspace")
                                .font(theme.typography.title)
                            Text(
                                "Choose a source, inspect exact method availability, and "
                                    + "create a validated QuickTime output."
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

    private func sectionLabel(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(theme.typography.headline)
            .foregroundStyle(theme.textPrimary)
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

    private var telemetryStatus: (
        title: String,
        symbol: String,
        tone: MirmirProductStatusTone
    ) {
        if telemetry.errorDescription != nil {
            return ("Telemetry unavailable", "exclamationmark.triangle", .warning)
        }
        if telemetry.snapshot == nil {
            return ("Starting telemetry", "ellipsis.circle", .neutral)
        }
        return ("Live · 1 second", "dot.radiowaves.left.and.right", .success)
    }

    private var cpuText: String {
        if telemetry.errorDescription != nil { return "Unavailable" }
        return MirmirPresentation.percentageText(
            telemetry.snapshot?.processCPUPercent
        )
    }

    private var memoryText: String {
        if telemetry.errorDescription != nil { return "Unavailable" }
        return byteCountText(telemetry.snapshot?.physicalFootprintBytes)
    }

    private var residentMemoryText: String {
        guard telemetry.errorDescription == nil else {
            return "Process resource usage could not be sampled"
        }
        return "Resident \(byteCountText(telemetry.snapshot?.residentBytes))"
    }

    private var diskReadText: String {
        if telemetry.errorDescription != nil { return "Unavailable" }
        return "Read \(MirmirPresentation.byteRateText(telemetry.snapshot?.diskReadBytesPerSecond))"
    }

    private var diskWriteText: String {
        if telemetry.errorDescription != nil { return "unavailable" }
        return MirmirPresentation.byteRateText(
            telemetry.snapshot?.diskWrittenBytesPerSecond
        )
    }

    private func byteCountText(_ bytes: UInt64?) -> String {
        guard let bytes, bytes <= UInt64(Int64.max) else {
            return "Sampling…"
        }
        return MirmirPresentation.fileSizeText(Int64(bytes))
    }

    private var gpuRoute: (
        primary: String,
        secondary: String,
        tone: MirmirProductStatusTone
    ) {
        guard let deviceName = telemetry.metalDeviceName else {
            return ("Unavailable", "No Metal device reported", .warning)
        }
        guard case .processing(_, let progress) = viewModel.state else {
            return ("Ready", deviceName, .neutral)
        }
        let backendID = progress.actualBackendID ?? viewModel.selectedBackendID
        guard explicitMetalBackends.contains(backendID) else {
            return ("Idle", "Current method is not an explicit Metal route", .neutral)
        }
        let method = BackendDescriptor.descriptor(for: backendID)?.title
            ?? backendID.rawValue
        switch progress.phase {
        case .probing, .preparingBackend, .preparingReaderWriter:
            return ("Preparing", "\(deviceName) · \(method)", .active)
        case .processingVideo:
            return ("Active", "\(deviceName) · \(method)", .success)
        case .processingAudio:
            return ("Selected", "\(deviceName) · \(method)", .active)
        case .finalizing, .validatingOutput, .completed:
            return ("Idle", "\(deviceName) · video pass complete", .neutral)
        }
    }

    private var explicitMetalBackends: Set<UpscaleBackendID> {
        [
            .mirmirDeterministicMetal,
            .metalFXSpatial,
            .mpsLanczos,
            .mpsBilinear
        ]
    }

    private var jobProgressFraction: Double? {
        switch viewModel.state {
        case .probing:
            return nil
        case .processing(_, let progress):
            return progress.fractionCompleted
        case .completed:
            return 1
        default:
            return 0
        }
    }

    private var queueDetail: String {
        switch viewModel.state {
        case .probing:
            return "Preparing one job · 0 waiting"
        case .processing(_, let progress):
            return "\(progress.phase.rawValue) · 1 active · 0 waiting"
        case .completed:
            return "1 of 1 completed · 0 waiting"
        case .failed:
            return "Job stopped · 0 waiting"
        case .ready:
            return "Ready to start · 0 waiting"
        case .empty:
            return "No active job · 0 waiting"
        }
    }

    private var queueValueText: String {
        switch viewModel.state {
        case .processing(_, let progress):
            return progress.fractionCompleted.map(percentText) ?? "Working"
        case .probing:
            return "Working"
        case .completed:
            return "100%"
        case .failed:
            return "Stopped"
        default:
            return "Idle"
        }
    }

    private var videoProgressFraction: Double? {
        switch viewModel.state {
        case .probing:
            return nil
        case .processing(_, let progress):
            if [.finalizing, .validatingOutput, .completed].contains(
                progress.phase
            ) {
                return 1
            }
            if let fraction = progress.fractionCompleted { return fraction }
            return timeFraction(
                processed: progress.processedTime,
                duration: progress.duration
            )
        case .completed:
            return 1
        default:
            return 0
        }
    }

    private var videoProgressDetail: String {
        switch viewModel.state {
        case .processing(_, let progress):
            if [.finalizing, .validatingOutput, .completed].contains(
                progress.phase
            ) {
                let duration = progress.duration.map(
                    MirmirPresentation.durationText
                ) ?? "Unknown"
                return "\(duration) / \(duration) · "
                    + "\(progress.processedFrameCount) frames"
            }
            if progress.phase == .processingAudio {
                return "Copying audio · video progress resumes with the next frame update"
            }
            let elapsed = progress.processedTime.map(
                MirmirPresentation.durationText
            ) ?? "0:00"
            let duration = progress.duration.map(
                MirmirPresentation.durationText
            ) ?? "Unknown"
            return "\(elapsed) / \(duration) · \(progress.processedFrameCount) frames"
        case .completed(let info, let result):
            return "\(MirmirPresentation.durationText(info.duration)) · "
                + "\(result.processedFrameCount) frames"
        case .ready(let info):
            return "0:00 / \(MirmirPresentation.durationText(info.duration))"
        case .probing:
            return "Reading source timing and frame information"
        case .failed:
            return "Progress is unavailable after the stopped job"
        case .empty:
            return "Choose a source to establish the video timeline"
        }
    }

    private var videoProgressValue: String {
        switch viewModel.state {
        case .processing(_, let progress):
            if [.finalizing, .validatingOutput, .completed].contains(
                progress.phase
            ) {
                return "100%"
            }
            return progress.fractionCompleted.map(percentText) ?? "Working"
        case .probing:
            return "Working"
        case .completed:
            return "100%"
        case .failed:
            return "Stopped"
        default:
            return "0%"
        }
    }

    private func percentText(_ fraction: Double) -> String {
        "\(Int((min(max(fraction, 0), 1) * 100).rounded()))%"
    }

    private func timeFraction(processed: CMTime?, duration: CMTime?) -> Double? {
        guard let processed, let duration else { return nil }
        let elapsedSeconds = CMTimeGetSeconds(processed)
        let durationSeconds = CMTimeGetSeconds(duration)
        guard processed.isNumeric,
              duration.isNumeric,
              elapsedSeconds.isFinite,
              durationSeconds.isFinite,
              elapsedSeconds >= 0,
              durationSeconds > 0 else {
            return nil
        }
        return min(max(elapsedSeconds / durationSeconds, 0), 1)
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
        ScrollView {
            VStack(alignment: .leading, spacing: theme.spacing.space5) {
                MirmirProductPanel(theme: theme) {
                    HStack(spacing: theme.spacing.space4) {
                        Image(systemName: queueSymbol)
                            .font(.system(size: 34, weight: .light))
                            .foregroundStyle(queueTone.color(theme: theme))
                        VStack(
                            alignment: .leading,
                            spacing: theme.spacing.space2
                        ) {
                            Text(queueTitle).font(theme.typography.subtitle)
                            Text(queueDetail)
                                .font(theme.typography.body)
                                .foregroundStyle(theme.textSecondary)
                        }
                        Spacer()
                        if viewModel.canPauseWorkflow {
                            Button("Pause") { viewModel.pauseProcessing() }
                                .buttonStyle(
                                    MirmirProductSecondaryButtonStyle(
                                        theme: theme
                                    )
                                )
                        }
                        if viewModel.isProcessing {
                            Button("Cancel", role: .destructive) {
                                viewModel.cancelProcessing()
                            }
                            .buttonStyle(
                                MirmirProductSecondaryButtonStyle(theme: theme)
                            )
                        }
                    }
                }

                if let error = viewModel.workflowErrorMessage {
                    MirmirProductPanel(theme: theme) {
                        Label(error, systemImage: "exclamationmark.shield")
                            .font(theme.typography.body)
                            .foregroundStyle(theme.danger)
                    }
                }

                if let snapshot = viewModel.workflowQueueSnapshot,
                   !snapshot.items.isEmpty {
                    VStack(spacing: theme.spacing.space3) {
                        ForEach(snapshot.items, id: \.jobID) { item in
                            queueRow(item)
                        }
                    }
                } else {
                    MirmirProductPanel(theme: theme) {
                        Text(
                            viewModel.isInitializingWorkflow
                                ? "Reconciling durable jobs and partial artifacts…"
                                : "The durable queue is empty."
                        )
                        .font(theme.typography.body)
                        .foregroundStyle(theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if let recovery = viewModel.workflowRecoverySnapshot,
                   !recovery.items.isEmpty {
                    MirmirProductPanel(theme: theme) {
                        VStack(
                            alignment: .leading,
                            spacing: theme.spacing.space2
                        ) {
                            Text("Launch recovery")
                                .font(theme.typography.headline)
                            ForEach(recovery.items, id: \.jobID) { item in
                                Text(
                                    "\(item.jobID.rawValue): "
                                        + "\(item.status.rawValue) → "
                                        + item.presentedLifecycle.rawValue
                                )
                                .font(theme.typography.caption.monospaced())
                                .foregroundStyle(
                                    item.containedFailureCount > 0
                                        ? theme.danger
                                        : theme.textSecondary
                                )
                            }
                        }
                    }
                }

                Text(
                    "Jobs, bookmark authority, lifecycle transitions, checkpoint "
                        + "segments, and recovery decisions are retained across launches."
                )
                .font(theme.typography.caption)
                .foregroundStyle(theme.textTertiary)
            }
            .padding(theme.spacing.space6)
        }
        .background(theme.background)
    }

    private func queueRow(
        _ item: WorkflowApplicationQueueItemV4
    ) -> some View {
        MirmirProductPanel(theme: theme) {
            HStack(spacing: theme.spacing.space3) {
                Image(systemName: symbol(for: item.lifecycle))
                    .foregroundStyle(tone(for: item.lifecycle).color(theme: theme))
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: theme.spacing.space1) {
                    Text(item.request?.outputFileName.rawValue ?? item.jobID.rawValue)
                        .font(theme.typography.bodyEmphasis)
                    Text(
                        "\(item.lifecycle.rawValue) · "
                            + "\(item.request?.backendID.rawValue ?? "request unavailable")"
                    )
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.textSecondary)
                }
                Spacer()
                if item.lifecycle == .paused {
                    Button("Resume") {
                        viewModel.resumeWorkflowJob(item.jobID)
                    }
                    .buttonStyle(
                        MirmirProductSecondaryButtonStyle(theme: theme)
                    )
                    .disabled(viewModel.isProcessing)
                }
            }
        }
    }

    private var queueTitle: String {
        let items = viewModel.workflowQueueSnapshot?.items ?? []
        let active = items.filter {
            !$0.lifecycle.isTerminal && $0.lifecycle != .paused
        }.count
        let paused = items.filter { $0.lifecycle == .paused }.count
        return "\(items.count) durable job\(items.count == 1 ? "" : "s") · "
            + "\(active) active · \(paused) paused"
    }

    private var queueDetail: String {
        let ready = viewModel.workflowQueueSnapshot?.items.filter {
            $0.requestRecordStatus == .ready
        }.count ?? 0
        return "\(ready) request record\(ready == 1 ? "" : "s") verified"
    }

    private var queueSymbol: String {
        viewModel.workflowErrorMessage == nil
            ? "list.bullet.rectangle.portrait"
            : "exclamationmark.triangle"
    }

    private var queueTone: MirmirProductStatusTone {
        if viewModel.workflowErrorMessage != nil { return .danger }
        return viewModel.isWorkflowProcessing ? .active : .neutral
    }

    private func symbol(for lifecycle: WorkflowJobLifecycle) -> String {
        switch lifecycle {
        case .queued: "clock"
        case .probing, .planned: "waveform"
        case .running, .pausing: "gearshape.2"
        case .paused: "pause.circle"
        case .verifying, .committing: "checkmark.shield"
        case .recovering: "arrow.clockwise"
        case .completed: "checkmark.circle"
        case .cancelled: "stop.circle"
        case .contained, .failed, .safeHalt: "exclamationmark.triangle"
        }
    }

    private func tone(
        for lifecycle: WorkflowJobLifecycle
    ) -> MirmirProductStatusTone {
        switch lifecycle {
        case .running, .pausing, .probing, .planned, .verifying, .committing,
             .recovering:
            .active
        case .completed:
            .success
        case .paused, .queued, .cancelled:
            .neutral
        case .contained, .failed, .safeHalt:
            .danger
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
                    "Durable jobs retain security-scoped bookmarks in Application "
                        + "Support. Backend selection remains explicit and never "
                        + "silently falls back."
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
        GeometryReader { proxy in
            ScrollView {
                Group {
                    if proxy.size.width >= 800 {
                        HStack(alignment: .top, spacing: theme.spacing.space5) {
                            identityPanel.frame(width: 260)
                            storyPanel.frame(maxWidth: .infinity)
                        }
                    } else {
                        VStack(spacing: theme.spacing.space5) {
                            identityPanel
                            storyPanel
                        }
                    }
                }
                .padding(theme.spacing.space6)
            }
        }
        .background(theme.background)
    }

    private var identityPanel: some View {
        MirmirProductPanel(theme: theme) {
            VStack(spacing: theme.spacing.space3) {
                MirmirBrandLockup(
                    layout: .vertical,
                    iconSize: 108,
                    theme: theme,
                    showsTagline: true
                )

                Text(versionText)
                    .font(theme.typography.captionEmphasis.monospacedDigit())
                    .foregroundStyle(theme.textSecondary)
                    .padding(.horizontal, theme.spacing.space3)
                    .padding(.vertical, theme.spacing.space1)
                    .background(Capsule().fill(theme.surfaceInset))

                Divider().overlay(theme.borderSubtle)

                VStack(spacing: theme.spacing.space1) {
                    Text("RAVEN FORGE SOFTWARE")
                        .font(theme.typography.micro)
                        .tracking(1.4)
                        .foregroundStyle(theme.textTertiary)
                    Text("Developed by James Daley")
                        .font(theme.typography.captionEmphasis)
                        .foregroundStyle(theme.textSecondary)
                }

                Text("macOS 15.4 or later · Sandboxed")
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.textTertiary)

                if let licenseURL = Bundle.main.url(
                    forResource: "ASH-Model-LICENSE",
                    withExtension: "txt"
                ) {
                    Link("ASH Model Acknowledgments", destination: licenseURL)
                        .font(theme.typography.captionEmphasis)
                }

                Text("© 2026 Raven Forge Software")
                    .font(theme.typography.micro)
                    .foregroundStyle(theme.textTertiary)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var storyPanel: some View {
        MirmirProductPanel(theme: theme) {
            VStack(alignment: .leading, spacing: theme.spacing.space4) {
                Text("About Mirmir")
                    .font(theme.typography.display)

                Text(
                    "Mirmir is the first video upscaler to implement James Daley’s "
                        + "ASH Model as a deterministic upscaling engine."
                )
                .font(theme.typography.subtitle)
                .foregroundStyle(theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

                Divider().overlay(theme.borderSubtle)

                aboutParagraph(
                    Text("The ASH Model — the ")
                        + Text("Adinkra-Stabilized Hypercube Model").bold()
                        + Text(" — is a finite-state mathematical and computational ")
                        + Text("framework developed by ")
                        + Text("James Daley").bold()
                        + Text(". Mirmir applies this research to video enhancement by ")
                        + Text("using deterministic state logic, temporal persistence, ")
                        + Text("branching, and artifact-aware decision making to guide the ")
                        + Text("upscaling process.")
                )

                aboutParagraph(
                    Text(
                        "Unlike conventional upscalers that treat enhancement as a "
                            + "single opaque reconstruction pass, Mirmir analyzes how "
                            + "visual structure changes over time. Its ASH-based engine "
                            + "is designed to make upscaling decisions repeatable, stable, "
                            + "and explainable from frame to frame."
                    )
                )

                aboutParagraph(
                    Text(
                        "Mirmir can also use Apple-native enhancement technologies, "
                            + "including VideoToolbox Super Resolution and MetalFX, as "
                            + "explicit processing choices alongside its ASH-based "
                            + "deterministic routes. Apple provides powerful native "
                            + "processing capabilities; Mirmir keeps each method’s "
                            + "availability and selection explicit, while its ASH CPU and "
                            + "Metal routes provide deterministic state-guided enhancement."
                    )
                )

                HStack(spacing: theme.spacing.space3) {
                    Link(destination: URL(string: "https://ashcosmology.net/")!) {
                        Label("ASH Model Website", systemImage: "safari")
                    }
                    .buttonStyle(MirmirProductSecondaryButtonStyle(theme: theme))

                    Link(
                        destination: URL(
                            string: "https://github.com/flynn33/ASH-Model"
                        )!
                    ) {
                        Label("Reference Repository", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    .buttonStyle(MirmirProductSecondaryButtonStyle(theme: theme))
                }

                Text(
                    "Mirmir is published under the Raven Forge Software brand and "
                        + "developed by James Daley."
                )
                .font(theme.typography.captionEmphasis)
                .foregroundStyle(theme.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .textSelection(.enabled)
    }

    private func aboutParagraph(_ text: Text) -> some View {
        text
            .font(theme.typography.body)
            .foregroundStyle(theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var versionText: String {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String
        let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String
        switch (version, build) {
        case let (.some(version), .some(build)):
            return "Version \(version) · Build \(build)"
        case let (.some(version), .none):
            return "Version \(version)"
        default:
            return "Development Build"
        }
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
