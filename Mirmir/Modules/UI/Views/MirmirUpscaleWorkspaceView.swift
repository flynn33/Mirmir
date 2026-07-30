import SwiftUI
import UniformTypeIdentifiers

struct MirmirUpscaleWorkspaceView: View {
    @ObservedObject var viewModel: MirmirViewModel
    let theme: MirmirThemeTokens
    let isCompact: Bool
    var body: some View {
        ScrollView {
            VStack(spacing: theme.spacing.space4) {
                HStack(alignment: .top, spacing: theme.spacing.space4) {
                    VStack(spacing: theme.spacing.space4) {
                        MirmirSourceStrip(viewModel: viewModel, theme: theme)
                        MirmirViewerPanel(viewModel: viewModel, theme: theme)
                    }
                    .frame(maxWidth: .infinity, alignment: .top)

                    if !isCompact {
                        MirmirUpscaleInspector(viewModel: viewModel, theme: theme)
                            .frame(width: 304)
                    }
                }

                if isCompact {
                    MirmirUpscaleInspector(viewModel: viewModel, theme: theme)
                }

                MirmirStatusStrip(viewModel: viewModel, theme: theme)
            }
            .padding(theme.spacing.space5)
        }
        .background(theme.background)
    }
}

private struct MirmirSourceStrip: View {
    @ObservedObject var viewModel: MirmirViewModel
    let theme: MirmirThemeTokens

    var body: some View {
        MirmirPanel(theme: theme) {
            HStack(alignment: .center, spacing: theme.spacing.space4) {
                VStack(alignment: .leading, spacing: theme.spacing.space1) {
                    Text("Choose video")
                        .font(theme.typography.headline)
                    Text(sourceSummary)
                        .font(theme.typography.body)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                }

                Spacer()

                Button {
                    viewModel.chooseSourceFile()
                } label: {
                    Label("Choose Source", systemImage: "film.stack")
                }
                .buttonStyle(MirmirSecondaryButtonStyle(theme: theme))
                .accessibilityLabel("Choose Source")

                Button {
                    _ = viewModel.chooseOutputFile()
                } label: {
                    Label("Select Destination", systemImage: "folder")
                }
                .buttonStyle(MirmirSecondaryButtonStyle(theme: theme))
                .disabled(viewModel.sourceProfile == nil)
                .help(viewModel.sourceProfile == nil ? "Choose a source video before selecting a destination." : "Select Destination")
                .accessibilityLabel("Select Destination")
            }
        }
    }

    private var sourceSummary: String {
        guard let profile = viewModel.sourceProfile else {
            return "Drop a video here or choose a source file."
        }
        return profile.url.lastPathComponent + " - " + MirmirViewModel.fileLabel(for: profile.resolution)
    }
}

private struct MirmirViewerPanel: View {
    @ObservedObject var viewModel: MirmirViewModel
    let theme: MirmirThemeTokens

    @State private var splitPosition = 0.5

    var body: some View {
        MirmirPanel(theme: theme) {
            VStack(spacing: theme.spacing.space3) {
                comparisonSurface
                    .frame(minHeight: 360)

                MirmirSampledPreviewControls(
                    viewModel: viewModel,
                    theme: theme,
                    splitPosition: $splitPosition
                )
            }
        }
    }

    private var comparisonSurface: some View {
        GeometryReader { proxy in
            ZStack {
                RoundedRectangle(cornerRadius: theme.radius.xlarge)
                    .fill(theme.surfaceInset)

                if viewModel.sourceProfile == nil {
                    MirmirSourceDropTarget(viewModel: viewModel, theme: theme)
                        .padding(theme.spacing.space8)
                } else {
                    beforeAfterSurface(size: proxy.size)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: theme.radius.xlarge)
                    .stroke(theme.borderSubtle, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: theme.radius.xlarge))
        }
    }

    private func beforeAfterSurface(size: CGSize) -> some View {
        let splitX = max(0, min(size.width, size.width * splitPosition))

        return ZStack(alignment: .leading) {
            if let frame = viewModel.latestPreviewFrame {
                MirmirPreviewRaster(image: frame.processed)
                    .frame(width: size.width, height: size.height)

                MirmirPreviewRaster(image: frame.source)
                    .frame(width: size.width, height: size.height)
                    .mask(alignment: .leading) {
                        Rectangle()
                            .frame(width: splitX)
                    }
            } else {
                previewPlaceholder
                    .frame(width: size.width, height: size.height)
            }

            Rectangle()
                .fill(theme.accentSecondary)
                .frame(width: 1)
                .offset(x: splitX)

            Circle()
                .fill(theme.viewerOverlay)
                .frame(width: 34, height: 34)
                .overlay {
                    Image(systemName: "arrow.left.and.right")
                        .font(theme.typography.captionEmphasis)
                        .foregroundStyle(theme.viewerOverlayText)
                }
                .overlay {
                    Circle()
                        .stroke(theme.accentSecondary, lineWidth: 1)
                }
                .offset(x: splitX - 17)
                .accessibilityHidden(true)

            previewLabels
                .frame(width: size.width, height: size.height)

            if viewModel.latestPreviewFrame != nil,
               case .failed(let reason) = viewModel.state {
                previewFailure(reason)
                    .frame(width: size.width, height: size.height)
            }
        }
        .clipped()
    }

    private var previewPlaceholder: some View {
        ZStack {
            Rectangle()
                .fill(theme.surfaceInset)
            VStack(spacing: theme.spacing.space2) {
                Image(systemName: "rectangle.split.2x1")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(theme.textTertiary)
                Text(MirmirPreviewPresentation.message(for: viewModel.state))
                    .font(theme.typography.body)
                    .foregroundStyle(theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, theme.spacing.space6)
            }
        }
    }

    private var previewLabels: some View {
        HStack(alignment: .top) {
            previewLabel("Before", subtitle: sourceResolutionText)
            Spacer()
            previewLabel("After", subtitle: targetResolutionText)
        }
        .padding(theme.spacing.space3)
    }

    private func previewLabel(
        _ title: String,
        subtitle: String
    ) -> some View {
        VStack(alignment: .leading, spacing: theme.spacing.space1) {
            Text(title)
                .font(theme.typography.captionEmphasis)
            Text(subtitle)
                .font(theme.typography.micro.monospacedDigit())
        }
        .foregroundStyle(theme.viewerOverlayText)
        .padding(.horizontal, theme.spacing.space2)
        .padding(.vertical, theme.spacing.space1)
        .background(
            RoundedRectangle(cornerRadius: theme.radius.small)
                .fill(theme.viewerOverlay)
        )
    }

    private func previewFailure(_ reason: String) -> some View {
        VStack {
            Spacer()
            Text("Upscale failed: \(reason)")
                .font(theme.typography.captionEmphasis)
                .foregroundStyle(theme.viewerOverlayText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, theme.spacing.space3)
                .padding(.vertical, theme.spacing.space2)
                .background(
                    RoundedRectangle(cornerRadius: theme.radius.medium)
                        .fill(theme.viewerOverlay)
                )
                .padding(theme.spacing.space3)
        }
    }

    private var sourceResolutionText: String {
        guard let profile = viewModel.sourceProfile else { return "No source" }
        return MirmirViewModel.fileLabel(for: profile.resolution)
    }

    private var targetResolutionText: String {
        MirmirViewModel.fileLabel(for: viewModel.targetResolution)
    }

}

struct MirmirPreviewPresentation {
    static func message(for state: MirmirViewModel.JobState) -> String {
        switch state {
        case .idle:
            return "Drop a video here or choose a source file."
        case .probing:
            return "Analyzing source metadata."
        case .ready:
            return "Start upscaling to see sampled production frames."
        case .running:
            return "Waiting for the first processed preview sample."
        case .finished:
            return "No processed preview sample was produced."
        case .failed(let reason):
            return "Upscale failed: \(reason)"
        }
    }

    static func timestamp(seconds: Double) -> String {
        guard seconds.isFinite else { return "00:00:00" }
        let maximumSafeSeconds = Double(Int.max / 2)
        let totalSeconds = Int(
            min(max(seconds, 0).rounded(.down), maximumSafeSeconds)
        )
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let remainingSeconds = totalSeconds % 60
        return String(
            format: "%02d:%02d:%02d",
            hours,
            minutes,
            remainingSeconds
        )
    }
}

private struct MirmirPreviewRaster: View {
    let image: UpscalePreviewImage

    var body: some View {
        ZStack {
            Color.black
            if let cgImage = image.makeCGImage() {
                Image(
                    decorative: cgImage,
                    scale: 1,
                    orientation: .up
                )
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
            }
        }
    }
}

private struct MirmirSourceDropTarget: View {
    @ObservedObject var viewModel: MirmirViewModel
    let theme: MirmirThemeTokens

    @State private var isTargeted = false

    var body: some View {
        RoundedRectangle(cornerRadius: theme.radius.large)
            .fill(isTargeted ? theme.accentMuted : theme.surface)
            .overlay {
                RoundedRectangle(cornerRadius: theme.radius.large)
                    .stroke(isTargeted ? theme.borderStrong : theme.borderSubtle, style: StrokeStyle(lineWidth: 1, dash: [6]))
            }
            .overlay {
                VStack(spacing: theme.spacing.space3) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(theme.accentPrimary)
                    Text("Drop a video here")
                        .font(theme.typography.subtitle)
                        .foregroundStyle(theme.textPrimary)
                    Text("or choose a source file")
                        .font(theme.typography.body)
                        .foregroundStyle(theme.textSecondary)
                    Button {
                        viewModel.chooseSourceFile()
                    } label: {
                        Label("Choose Source", systemImage: "film.stack")
                    }
                    .buttonStyle(MirmirSecondaryButtonStyle(theme: theme))
                    .accessibilityLabel("Choose Source")
                    Text(
                        "Quality, Fast, and Deterministic use Apple MPS "
                            + "Lanczos with a geometry-qualified route."
                    )
                        .font(theme.typography.caption)
                        .foregroundStyle(theme.textTertiary)
                }
                .padding(theme.spacing.space6)
            }
            .onDrop(of: [UTType.fileURL], isTargeted: $isTargeted) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url {
                        Task { @MainActor in viewModel.loadSource(url: url) }
                    }
                }
                return true
            }
            .accessibilityLabel("Source video drop target")
    }
}

private struct MirmirSampledPreviewControls: View {
    @ObservedObject var viewModel: MirmirViewModel
    let theme: MirmirThemeTokens
    @Binding var splitPosition: Double

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.space2) {
            HStack(spacing: theme.spacing.space2) {
                Label(
                    "Live sampled preview",
                    systemImage: "rectangle.split.2x1"
                )
                .font(theme.typography.captionEmphasis)
                .foregroundStyle(theme.textSecondary)
                Text(sampleText)
                    .font(theme.typography.caption.monospacedDigit())
                    .foregroundStyle(theme.textSecondary)
                Spacer()
                Text("Continuous playback and scrubbing are not included.")
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.textTertiary)
            }

            HStack(spacing: theme.spacing.space2) {
                Text("Split")
                    .font(theme.typography.captionEmphasis)
                    .foregroundStyle(theme.textSecondary)
                Slider(value: $splitPosition, in: 0.2...0.8)
                    .disabled(viewModel.latestPreviewFrame == nil)
                    .accessibilityLabel("Before after split")
                Text("Both sides show the same sampled production frame.")
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.textTertiary)
            }
        }
    }

    private var sampleText: String {
        guard let frame = viewModel.latestPreviewFrame else {
            return "No processed sample yet"
        }
        return "Frame \(frame.frameIndex + 1) · "
            + MirmirPreviewPresentation.timestamp(
                seconds: frame.presentationSeconds
            )
    }
}

private struct MirmirUpscaleInspector: View {
    @ObservedObject var viewModel: MirmirViewModel
    let theme: MirmirThemeTokens

    var body: some View {
        MirmirPanel(theme: theme) {
            VStack(alignment: .leading, spacing: theme.spacing.space5) {
                inspectorSection("Upscale Settings") {
                    MirmirFieldRow("Engine", theme: theme) {
                        Picker("Engine", selection: Binding.constant(viewModel.engineSelectionText)) {
                            Text(viewModel.engineSelectionText).tag(viewModel.engineSelectionText)
                        }
                        .pickerStyle(.menu)
                        .disabled(true)
                        .help(viewModel.engineAvailabilityReason ?? "Direct reference processing is available.")
                    }

                    MirmirFieldRow("Strategy", theme: theme) {
                        Picker("Strategy", selection: Binding.constant(strategyText)) {
                            Text(strategyText).tag(strategyText)
                        }
                        .pickerStyle(.menu)
                        .disabled(true)
                        .help(
                            "Mirmir selects the qualified A11 route for "
                                + "canonical pairs or a dimension-bound "
                                + "adaptive route for other eligible geometry."
                        )
                    }

                    MirmirFieldRow("Mode", theme: theme) {
                        Picker("Mode", selection: $viewModel.selectedMode) {
                            ForEach(UpscaleMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .help(viewModel.selectedModeSummary)
                    }
                    Text(viewModel.selectedModeSummary)
                        .font(theme.typography.caption)
                        .foregroundStyle(
                            viewModel.engineAvailabilityReason == nil
                                ? theme.textTertiary
                                : theme.warning
                        )
                }

                inspectorSection("Quality Controls") {
                    Toggle(
                        "Temporal Consistency",
                        isOn: Binding.constant(viewModel.engineAvailabilityReason == nil)
                    )
                        .font(theme.typography.body)
                        .disabled(true)
                        .help("This control is fixed and does not change the selected A11 release mode.")

                    segmentedLevel("Edge Fidelity", selection: .constant(.medium))
                    segmentedLevel("Detail Recovery", selection: .constant(.medium))
                }

                inspectorSection("Output") {
                    MirmirFieldRow("Output Format", theme: theme) {
                        Picker("Output Format", selection: $viewModel.codec) {
                            ForEach(OutputCodec.allCases) { codec in
                                Text(codec.inspectorTitle).tag(codec)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    MirmirFieldRow("Destination", theme: theme) {
                        Button {
                            _ = viewModel.chooseOutputFile()
                        } label: {
                            Label(destinationLabel, systemImage: "folder")
                                .lineLimit(1)
                        }
                        .buttonStyle(MirmirSecondaryButtonStyle(theme: theme))
                        .disabled(viewModel.sourceProfile == nil)
                        .help(viewModel.sourceProfile == nil ? "Choose a source video before selecting a destination." : destinationHelp)
                    }
                }

                inspectorSection("Action") {
                    R13UpscaleActionPanel(
                        viewModel: viewModel,
                        theme: theme
                    )
                }
            }
        }
    }

    private var strategyText: String {
        if viewModel.engineAvailabilityReason != nil {
            return "Not available"
        }
        guard let profile = viewModel.sourceProfile else {
            return "MPS Lanczos route"
        }
        let source = MirmirViewModel.fileLabel(for: profile.resolution)
        let target = MirmirViewModel.fileLabel(for: viewModel.targetResolution)
        guard let plan = try? R13ReleaseJobContracts.scalePlan(
            source: profile.resolution,
            target: viewModel.targetResolution
        ) else {
            return "No compatible MPS route"
        }
        switch plan {
        case .productQualified:
            return "Qualified A11 MPS Lanczos (\(source) to \(target))"
        case .adaptiveMPSLanczos:
            return "Adaptive MPS Lanczos (\(source) to \(target))"
        }
    }

    private var destinationLabel: String {
        guard let outputURL = viewModel.outputURL else { return "Select Destination" }
        return outputURL.lastPathComponent
    }

    private var destinationHelp: String {
        viewModel.outputURL?.path ?? "Select Destination"
    }

    private func inspectorSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: theme.spacing.space3) {
            Text(title)
                .font(theme.typography.headline)
                .foregroundStyle(theme.textPrimary)
            content()
        }
    }

    private func segmentedLevel(
        _ title: String,
        selection: Binding<MirmirAdjustmentLevel>
    ) -> some View {
        MirmirFieldRow(title, theme: theme) {
            Picker(title, selection: selection) {
                ForEach(MirmirAdjustmentLevel.allCases) { level in
                    Text(level.title).tag(level)
                }
            }
            .pickerStyle(.segmented)
            .disabled(true)
            .help("This adjustment is not implemented yet.")
        }
    }
}

// The workspace and its private, screen-specific subviews remain co-located.
// swiftlint:disable:this file_length
