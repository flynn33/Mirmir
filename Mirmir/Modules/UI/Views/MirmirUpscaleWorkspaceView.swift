import SwiftUI
import UniformTypeIdentifiers

struct MirmirUpscaleWorkspaceView: View {
    @ObservedObject var viewModel: MirmirViewModel
    let theme: MirmirThemeTokens
    let isCompact: Bool
    let showLibrary: () -> Void
    var body: some View {
        ScrollView {
            VStack(spacing: theme.spacing.space4) {
                HStack(alignment: .top, spacing: theme.spacing.space4) {
                    VStack(spacing: theme.spacing.space4) {
                        MirmirSourceStrip(viewModel: viewModel, theme: theme)
                        MirmirViewerPanel(
                            viewModel: viewModel,
                            theme: theme,
                            showLibrary: showLibrary
                        )
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
                        .lineLimit(2)
                }

                Spacer()

                Button {
                    viewModel.chooseSourceFile()
                } label: {
                    Label("Choose Source", systemImage: "film.stack")
                }
                .buttonStyle(MirmirSecondaryButtonStyle(theme: theme))
                .disabled(!viewModel.jobConfigurationIsEditable)
                .accessibilityLabel("Choose Source")

                Button {
                    _ = viewModel.chooseOutputFile()
                } label: {
                    Label("Select Destination", systemImage: "folder")
                }
                .buttonStyle(MirmirSecondaryButtonStyle(theme: theme))
                .disabled(
                    viewModel.sourceProfile == nil
                        || !viewModel.jobConfigurationIsEditable
                )
                .help(viewModel.sourceProfile == nil ? "Choose a source video before selecting a destination." : "Select Destination")
                .accessibilityLabel("Select Destination")
            }
        }
    }

    private var sourceSummary: String {
        guard let profile = viewModel.sourceProfile else {
            return "Drop a video here or choose a source file."
        }
        let codec = profile.codecHint.flatMap {
            $0.isEmpty ? nil : $0
        } ?? "Codec unavailable"
        let audio = profile.audioTrackDescription
        return profile.url.lastPathComponent
            + " · \(MirmirViewModel.fileLabel(for: profile.resolution))"
            + " · \(Self.frameRate(profile.frameRate)) fps"
            + " · \(Self.duration(profile.durationSeconds))"
            + " · \(profile.scanStructure.displayName)"
            + " · \(codec) · \(audio)"
    }

    private static func frameRate(_ value: Double) -> String {
        value.formatted(
            .number.precision(.fractionLength(0...3))
        )
    }

    private static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else {
            return "Duration unavailable"
        }
        let wholeSeconds = Int(seconds.rounded())
        let hours = wholeSeconds / 3_600
        let minutes = (wholeSeconds % 3_600) / 60
        let remainingSeconds = wholeSeconds % 60
        if hours > 0 {
            return String(
                format: "%d:%02d:%02d",
                hours,
                minutes,
                remainingSeconds
            )
        }
        return String(
            format: "%d:%02d",
            minutes,
            remainingSeconds
        )
    }
}

private struct MirmirPreservationInventoryView: View {
    let capability: SourceMediaPreservationCapability
    let preserveAudio: Bool
    let theme: MirmirThemeTokens

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.space2) {
            Text("Source Media Inventory")
                .font(theme.typography.captionEmphasis)
                .foregroundStyle(theme.textPrimary)
            Text(capability.inventorySummary)
                .font(theme.typography.caption)
                .foregroundStyle(theme.textSecondary)

            ForEach(capability.tracks) { track in
                inventoryRow(
                    title: track.displayName,
                    detail: track.displaySummary,
                    isCompatible: track.support.isCompatible
                )
            }
            ForEach(capability.associations) { association in
                inventoryRow(
                    title: "Track association",
                    detail: association.displaySummary,
                    isCompatible:
                        association.support.isCompatible
                )
            }
            inventoryRow(
                title: "Container metadata",
                detail: capability.hasContainerMetadata
                    ? "Present · \(capability.support.displayName)"
                    : "None · \(capability.support.displayName)",
                isCompatible: capability.support.isCompatible
            )

            if let failureReason {
                Label(failureReason, systemImage: "exclamationmark.triangle")
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(
                        "Media preservation unavailable. "
                            + failureReason
                    )
            } else {
                Label(
                    "Selected source media can be preserved exactly.",
                    systemImage: "checkmark.circle"
                )
                .font(theme.typography.caption)
                .foregroundStyle(theme.success)
            }
        }
        .padding(theme.spacing.space2)
        .background(theme.surfaceInset)
        .clipShape(
            RoundedRectangle(
                cornerRadius: theme.radius.radiusSmall,
                style: .continuous
            )
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: theme.radius.radiusSmall,
                style: .continuous
            )
            .stroke(theme.borderSubtle, lineWidth: 1)
        }
    }

    private var failureReason: String? {
        capability.failureReason(
            preserveAudio: preserveAudio,
            preserveSubtitles: true,
            preserveMetadata: true
        )
    }

    private func inventoryRow(
        title: String,
        detail: String,
        isCompatible: Bool
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.spacing.space2) {
            Image(
                systemName: isCompatible
                    ? "checkmark.circle.fill"
                    : "exclamationmark.triangle.fill"
            )
            .foregroundStyle(
                isCompatible ? theme.success : theme.warning
            )
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: theme.spacing.space1) {
                Text(title)
                    .font(theme.typography.captionEmphasis)
                    .foregroundStyle(theme.textPrimary)
                Text(detail)
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct MirmirViewerPanel: View {
    @ObservedObject var viewModel: MirmirViewModel
    let theme: MirmirThemeTokens
    let showLibrary: () -> Void

    @State private var splitPosition = 0.5

    var body: some View {
        MirmirPanel(theme: theme) {
            VStack(spacing: theme.spacing.space3) {
                if let sourceURL = viewModel.sourceProfile?.url,
                   let completedOutputURL =
                    viewModel.completedOutputURL {
                    MirmirCompletedComparisonPlaybackView(
                        sourceURL: sourceURL,
                        completedOutputURL: completedOutputURL,
                        sourceResolutionText: sourceResolutionText,
                        outputResolutionText: targetResolutionText,
                        theme: theme,
                        splitPosition: $splitPosition,
                        showLibrary: showLibrary
                    )
                } else {
                    comparisonSurface
                        .frame(minHeight: 360)
                }

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
            return "The verified completed output is ready for comparison playback."
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
                    .disabled(!viewModel.jobConfigurationIsEditable)
                    .accessibilityLabel("Choose Source")
                    Text(
                        "Choose Auto, Quality, Fast, Deterministic, or "
                            + "Smooth Motion; "
                            + "the resolved scaler is recorded with the output."
                    )
                        .font(theme.typography.caption)
                        .foregroundStyle(theme.textTertiary)
                }
                .padding(theme.spacing.space6)
            }
            .onDrop(of: [UTType.fileURL], isTargeted: $isTargeted) { providers in
                guard viewModel.jobConfigurationIsEditable else {
                    return false
                }
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(
                    ofClass: URL.self
                ) { url, error in
                    let errorDescription = error?.localizedDescription
                    Task { @MainActor in
                        viewModel.handleSourceDropProviderResult(
                            url: url,
                            errorDescription: errorDescription
                        )
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
                    comparisonHeading,
                    systemImage: "rectangle.split.2x1"
                )
                .font(theme.typography.captionEmphasis)
                .foregroundStyle(theme.textSecondary)
                Text(sampleText)
                    .font(theme.typography.caption.monospacedDigit())
                    .foregroundStyle(theme.textSecondary)
                Spacer()
                Text(comparisonHelp)
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.textTertiary)
            }

            HStack(spacing: theme.spacing.space2) {
                Text("Split")
                    .font(theme.typography.captionEmphasis)
                    .foregroundStyle(theme.textSecondary)
                Slider(value: $splitPosition, in: 0.2...0.8)
                    .disabled(!splitIsAvailable)
                    .accessibilityLabel("Before after split")
                Text(splitHelp)
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.textTertiary)
            }
        }
    }

    private var comparisonHeading: String {
        viewModel.completedOutputURL == nil
            ? "Live sampled preview"
            : "Completed comparison"
    }

    private var comparisonHelp: String {
        switch viewModel.state {
        case .idle, .probing, .ready:
            return "Continuous comparison becomes available after a verified output completes."
        case .running:
            return "Sampled frames update during processing; continuous playback follows completion."
        case .finished:
            return "Play, pause, or scrub the verified output in sync with the source."
        case .failed:
            return "The retained sample remains available; continuous playback requires a completed output."
        }
    }

    private var splitHelp: String {
        if viewModel.completedOutputURL != nil {
            return "Both videos stay synchronized while you adjust the split."
        }
        return "Both sides show the same sampled production frame."
    }

    private var splitIsAvailable: Bool {
        viewModel.completedOutputURL != nil
            || viewModel.latestPreviewFrame != nil
    }

    private var sampleText: String {
        if let completedOutputURL = viewModel.completedOutputURL {
            return completedOutputURL.lastPathComponent
        }
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
                    MirmirFieldRow("Processing Paths", theme: theme) {
                        Menu {
                            processingPathButton(.automatic)

                            Divider()

                            Button {
                                viewModel
                                    .selectAllProcessingPathsForPendingJob()
                            } label: {
                                if viewModel.allProcessingPathsAreSelected {
                                    Label(
                                        "All Paths",
                                        systemImage: "checkmark"
                                    )
                                } else {
                                    Text("All Paths")
                                }
                            }

                            Divider()

                            ForEach(
                                UpscaleEnginePreference
                                    .concreteProcessingPaths
                            ) { path in
                                processingPathButton(path)
                            }
                        } label: {
                            Text(viewModel.processingPathMenuTitle)
                                .lineLimit(1)
                        }
                        .disabled(!viewModel.jobConfigurationIsEditable)
                        .help(
                            "Resolved processing: "
                                + viewModel.engineSelectionText
                        )
                    }

                    Label(
                        "Deterministic enhancement runs before every "
                            + "selected path.",
                        systemImage: "checkmark.seal"
                    )
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.textTertiary)

                    if let batchStatus =
                            viewModel.processingPathBatchStatusText,
                       let summary =
                            viewModel.processingPathBatchSummary {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(batchStatus)
                                .font(theme.typography.caption)
                                .foregroundStyle(
                                    summary.allSucceeded
                                        ? theme.success
                                        : theme.textSecondary
                                )
                            ForEach(summary.results, id: \.jobID) { result in
                                Label(
                                    result.batch.path.title
                                        + " · "
                                        + result.status.title,
                                    systemImage:
                                        result.status.systemImage
                                )
                                .font(theme.typography.caption)
                                .foregroundStyle(
                                    result.status == .completed
                                        ? theme.success
                                        : theme.warning
                                )
                            }
                        }
                    }

                    Label(
                        "AVFoundation media I/O — always used",
                        systemImage: "film.stack"
                    )
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.textTertiary)

                    MirmirFieldRow("Strategy", theme: theme) {
                        Picker("Strategy", selection: strategySelection) {
                            ForEach(
                                UpscaleStrategyPreference.allCases
                            ) { preference in
                                Text(preference.title).tag(preference)
                            }
                        }
                        .pickerStyle(.menu)
                        .disabled(!viewModel.jobConfigurationIsEditable)
                        .help(
                            "Resolved strategy: \(strategyText)"
                        )
                    }

                    MirmirFieldRow("Mode", theme: theme) {
                        Picker("Mode", selection: modeSelection) {
                            ForEach(UpscaleMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .disabled(!viewModel.jobConfigurationIsEditable)
                        .help(viewModel.selectedModeSummary)
                    }
                    Text(viewModel.selectedModeSummary)
                        .font(theme.typography.caption)
                        .foregroundStyle(
                            viewModel.engineAvailabilityReason == nil
                                ? theme.textTertiary
                                : theme.warning
                        )

                    if viewModel.selectedMode == .smoothMotion {
                        MirmirFieldRow(
                            "Output Cadence",
                            theme: theme
                        ) {
                            Picker(
                                "Output Cadence",
                                selection: smoothMotionCadenceSelection
                            ) {
                                ForEach(
                                    SmoothMotionCadence.allCases
                                ) { cadence in
                                    Text(cadence.title).tag(cadence)
                                }
                            }
                            .pickerStyle(.segmented)
                            .disabled(
                                !viewModel.jobConfigurationIsEditable
                            )
                            .help(
                                viewModel.smoothMotionCadence.summary
                            )
                        }

                        MirmirFieldRow(
                            "Scene Cut Protection",
                            theme: theme
                        ) {
                            Picker(
                                "Scene Cut Protection",
                                selection:
                                    smoothMotionSceneCutSelection
                            ) {
                                ForEach(
                                    SmoothMotionSceneCutSensitivity
                                        .allCases
                                ) { sensitivity in
                                    Text(sensitivity.title)
                                        .tag(sensitivity)
                                }
                            }
                            .pickerStyle(.segmented)
                            .disabled(
                                !viewModel.jobConfigurationIsEditable
                            )
                            .help(
                                viewModel
                                    .smoothMotionSceneCutSensitivity
                                    .summary
                            )
                        }

                        Text(
                            "Mirmir preserves the source duration and "
                                + "audio timing. It prefers Apple "
                                + "VideoToolbox interpolation and uses "
                                + "deterministic motion blending when "
                                + "the native route is unavailable."
                        )
                        .font(theme.typography.caption)
                        .foregroundStyle(theme.textTertiary)
                    }

                    MirmirFieldRow("Target", theme: theme) {
                        Picker(
                            "Target Resolution",
                            selection: targetSelection
                        ) {
                            ForEach(
                                viewModel.availableTargets,
                                id: \.self
                            ) { resolution in
                                Text(
                                    MirmirViewModel.fileLabel(
                                        for: resolution
                                    )
                                )
                                .tag(resolution)
                            }
                        }
                        .pickerStyle(.menu)
                        .disabled(
                            viewModel.availableTargets.isEmpty
                                || !viewModel
                                    .jobConfigurationIsEditable
                        )
                    }
                }

                inspectorSection("Quality Controls") {
                    Toggle(
                        "Temporal Consistency",
                        isOn: temporalConsistencySelection
                    )
                        .font(theme.typography.body)
                        .disabled(!viewModel.jobConfigurationIsEditable)
                        .help(
                            "Motion-gated stabilization uses the previous "
                                + "verified output frame."
                        )

                    segmentedLevel(
                        "Edge Fidelity",
                        selection: edgeFidelitySelection
                    )
                    segmentedLevel(
                        "Detail Recovery",
                        selection: detailRecoverySelection
                    )

                    Toggle(
                        "Edge Preservation",
                        isOn: edgePreservationSelection
                    )
                    .font(theme.typography.body)
                    .disabled(!viewModel.jobConfigurationIsEditable)
                    .help(MirmirEffectOption.allOptions[0].summary)

                    Toggle(
                        "Compression Cleanup",
                        isOn: compressionCleanupSelection
                    )
                    .font(theme.typography.body)
                    .disabled(!viewModel.jobConfigurationIsEditable)
                    .help(MirmirEffectOption.allOptions[1].summary)

                    Toggle(
                        "Texture / Grain Protection",
                        isOn: textureGrainProtectionSelection
                    )
                    .font(theme.typography.body)
                    .disabled(!viewModel.jobConfigurationIsEditable)
                    .help(MirmirEffectOption.allOptions[2].summary)

                    Toggle(
                        "Temporal Stability",
                        isOn: temporalStabilitySelection
                    )
                    .font(theme.typography.body)
                    .disabled(!viewModel.jobConfigurationIsEditable)
                    .help(MirmirEffectOption.allOptions[3].summary)
                }

                inspectorSection("Output") {
                    MirmirFieldRow("Output Format", theme: theme) {
                        Picker("Output Format", selection: codecSelection) {
                            ForEach(OutputCodec.allCases) { codec in
                                Text(codec.inspectorTitle).tag(codec)
                            }
                        }
                        .pickerStyle(.segmented)
                        .disabled(!viewModel.jobConfigurationIsEditable)
                    }

                    Toggle(
                        "Preserve Source Audio Tracks",
                        isOn: preserveAudioSelection
                    )
                    .font(theme.typography.body)
                    .disabled(
                        viewModel.sourceProfile?.hasAudio != true
                            || !viewModel.jobConfigurationIsEditable
                    )
                    .help(preserveAudioHelp)

                    if let capability = viewModel.sourceProfile?
                        .mediaPreservationCapability {
                        MirmirPreservationInventoryView(
                            capability: capability,
                            preserveAudio: viewModel.preserveAudio,
                            theme: theme
                        )
                    }

                    MirmirFieldRow("Destination", theme: theme) {
                        Button {
                            _ = viewModel.chooseOutputFile()
                        } label: {
                            Label(destinationLabel, systemImage: "folder")
                                .lineLimit(1)
                        }
                        .buttonStyle(MirmirSecondaryButtonStyle(theme: theme))
                        .disabled(
                            viewModel.sourceProfile == nil
                                || !viewModel.jobConfigurationIsEditable
                        )
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

    private var modeSelection: Binding<UpscaleMode> {
        Binding(
            get: { viewModel.selectedMode },
            set: { viewModel.selectModeForPendingJob($0) }
        )
    }

    private var targetSelection: Binding<VideoResolution> {
        Binding(
            get: { viewModel.targetResolution },
            set: { viewModel.selectTargetForPendingJob($0) }
        )
    }

    private var smoothMotionCadenceSelection:
        Binding<SmoothMotionCadence> {
        Binding(
            get: { viewModel.smoothMotionCadence },
            set: {
                viewModel.selectSmoothMotionCadenceForPendingJob($0)
            }
        )
    }

    private var smoothMotionSceneCutSelection:
        Binding<SmoothMotionSceneCutSensitivity> {
        Binding(
            get: { viewModel.smoothMotionSceneCutSensitivity },
            set: {
                viewModel
                    .selectSmoothMotionSceneCutSensitivityForPendingJob(
                        $0
                    )
            }
        )
    }

    private var codecSelection: Binding<OutputCodec> {
        Binding(
            get: { viewModel.codec },
            set: { viewModel.selectCodecForPendingJob($0) }
        )
    }

    private var strategySelection:
        Binding<UpscaleStrategyPreference> {
        Binding(
            get: { viewModel.strategyPreference },
            set: { viewModel.selectStrategyForPendingJob($0) }
        )
    }

    private var temporalConsistencySelection: Binding<Bool> {
        Binding(
            get: { viewModel.temporalConsistencyEnabled },
            set: {
                viewModel.setTemporalConsistencyForPendingJob($0)
            }
        )
    }

    private var preserveAudioSelection: Binding<Bool> {
        Binding(
            get: { viewModel.preserveAudio },
            set: { viewModel.setPreserveAudioForPendingJob($0) }
        )
    }

    private var preserveAudioHelp: String {
        guard let profile = viewModel.sourceProfile,
              profile.audioTrackCount > 0 else {
            return "The selected source has no audio tracks."
        }
        if profile.audioTrackCount == 1 {
            return "Copy the source audio track into the completed video."
        }
        return "Copy all \(profile.audioTrackCount) source audio tracks "
            + "into the completed video in their original order."
    }

    private var edgeFidelitySelection:
        Binding<MirmirAdjustmentLevel> {
        Binding(
            get: { viewModel.edgeFidelityLevel },
            set: {
                viewModel.selectEdgeFidelityForPendingJob($0)
            }
        )
    }

    private var detailRecoverySelection:
        Binding<MirmirAdjustmentLevel> {
        Binding(
            get: { viewModel.detailRecoveryLevel },
            set: {
                viewModel.selectDetailRecoveryForPendingJob($0)
            }
        )
    }

    private var edgePreservationSelection: Binding<Bool> {
        Binding(
            get: { viewModel.edgePreservationEnabled },
            set: {
                viewModel.setEdgePreservationForPendingJob($0)
            }
        )
    }

    private var compressionCleanupSelection: Binding<Bool> {
        Binding(
            get: { viewModel.compressionCleanupEnabled },
            set: {
                viewModel.setCompressionCleanupForPendingJob($0)
            }
        )
    }

    private var textureGrainProtectionSelection: Binding<Bool> {
        Binding(
            get: { viewModel.textureGrainProtectionEnabled },
            set: {
                viewModel.setTextureGrainProtectionForPendingJob($0)
            }
        )
    }

    private var temporalStabilitySelection: Binding<Bool> {
        Binding(
            get: { viewModel.temporalStabilityEnabled },
            set: {
                viewModel.setTemporalStabilityForPendingJob($0)
            }
        )
    }

    private var strategyText: String {
        if viewModel.engineAvailabilityReason != nil {
            return "Not available"
        }
        let engine = viewModel.engineSelectionText
        guard let profile = viewModel.sourceProfile else {
            return "\(engine) route"
        }
        let source = MirmirViewModel.fileLabel(for: profile.resolution)
        let target = MirmirViewModel.fileLabel(for: viewModel.targetResolution)
        guard let plan = try? R13ReleaseJobContracts.scalePlan(
            source: profile.resolution,
            target: viewModel.targetResolution,
            strategyPreference: viewModel.strategyPreference
        ) else {
            return "No compatible scaling route"
        }
        switch plan {
        case .productQualified:
            return "Direct \(engine) (\(source) to \(target))"
        case .adaptiveMPSLanczos:
            return "Adaptive \(engine) (\(source) to \(target))"
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
            .disabled(!viewModel.jobConfigurationIsEditable)
        }
    }

    @ViewBuilder
    private func processingPathButton(
        _ path: UpscaleEnginePreference
    ) -> some View {
        Button {
            if path == .automatic {
                viewModel.selectAutomaticRoutingForPendingJob()
            } else {
                viewModel.toggleProcessingPathForPendingJob(path)
            }
        } label: {
            if viewModel.processingPathIsSelected(path) {
                Label(path.title, systemImage: "checkmark")
            } else {
                Text(path.title)
            }
        }
    }
}

// The workspace and its private, screen-specific subviews remain co-located.
// swiftlint:disable:this file_length
