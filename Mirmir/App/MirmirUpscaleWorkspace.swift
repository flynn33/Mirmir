import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

struct MirmirProductUpscaleWorkspace: View {
    let viewModel: MirmirViewModel
    let theme: MirmirThemeTokens
    let compact: Bool
    let showMethods: () -> Void
    let selectMethod: (UpscaleBackendID) -> Void

    @State private var aspectLocked = true

    var body: some View {
        ScrollView {
            VStack(spacing: theme.spacing.space4) {
                sourceStrip

                HStack(alignment: .top, spacing: theme.spacing.space4) {
                    viewerPanel
                        .frame(maxWidth: .infinity, alignment: .top)

                    if !compact {
                        inspector
                            .frame(width: 310)
                    }
                }

                if compact {
                    inspector
                }

                statusStrip
            }
            .padding(theme.spacing.space5)
        }
        .background(theme.background)
    }

    private var sourceStrip: some View {
        MirmirProductPanel(theme: theme) {
            HStack(spacing: theme.spacing.space4) {
                VStack(alignment: .leading, spacing: theme.spacing.space1) {
                    Text(sourceHeading)
                        .font(theme.typography.headline)
                    Text(sourceSummary)
                        .font(theme.typography.body)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(2)
                }
                Spacer()
                if viewModel.currentVideoInfo != nil {
                    Button {
                        viewModel.revealSourceInFinder()
                    } label: {
                        Image(systemName: "finder")
                    }
                    .buttonStyle(MirmirProductIconButtonStyle(theme: theme))
                    .help("Reveal source in Finder")
                }
                Button {
                    viewModel.openVideo()
                } label: {
                    Label("Choose Source", systemImage: "film.stack")
                }
                .buttonStyle(MirmirProductSecondaryButtonStyle(theme: theme))
                .disabled(viewModel.isProcessing)
                .accessibilityIdentifier("mirmir.openVideo")

                Button {
                    viewModel.chooseOutput()
                } label: {
                    Label("Select Destination", systemImage: "folder")
                }
                .buttonStyle(MirmirProductSecondaryButtonStyle(theme: theme))
                .disabled(
                    viewModel.currentVideoInfo == nil || viewModel.isProcessing
                )
                .accessibilityIdentifier("mirmir.chooseOutput")
            }
        }
    }

    private var viewerPanel: some View {
        MirmirProductPanel(theme: theme) {
            VStack(spacing: theme.spacing.space3) {
                HStack {
                    Label("Before / After Viewer", systemImage: "rectangle.split.2x1")
                        .font(theme.typography.captionEmphasis)
                        .foregroundStyle(theme.textSecondary)
                    Spacer()
                    Text(viewerBadge)
                        .font(theme.typography.micro)
                        .foregroundStyle(theme.textTertiary)
                        .padding(.horizontal, theme.spacing.space2)
                        .padding(.vertical, theme.spacing.space1)
                        .background(
                            Capsule().fill(theme.surfaceInset)
                        )
                }

                viewerSurface
                    .frame(minHeight: 360)

                viewerControls
            }
        }
    }

    @ViewBuilder
    private var viewerSurface: some View {
        switch viewModel.state {
        case .empty:
            MirmirSourceDropSurface(viewModel: viewModel, theme: theme)
        case .probing(let url):
            MirmirViewerMessage(
                symbol: "waveform",
                title: "Analyzing source",
                detail: url.lastPathComponent,
                showsProgress: true,
                theme: theme
            )
        case .ready(let info):
            MirmirSourceVideoPreview(info: info, theme: theme)
        case .processing(let info, let progress):
            MirmirProcessingViewer(
                info: info,
                progress: progress,
                theme: theme
            )
        case .completed(let info, let result):
            MirmirCompletionViewer(
                source: info,
                result: result,
                viewModel: viewModel,
                theme: theme
            )
        case .failed(let error):
            MirmirFailureViewer(
                error: error,
                canReturn: viewModel.currentVideoInfo != nil,
                returnToSettings: viewModel.returnToReady,
                theme: theme
            )
        }
    }

    private var viewerControls: some View {
        HStack(spacing: theme.spacing.space3) {
            Image(systemName: stateSymbol)
                .foregroundStyle(stateTone.color(theme: theme))
            Text(stateText)
                .font(theme.typography.captionEmphasis)
                .foregroundStyle(theme.textSecondary)
            Spacer()
            if let info = viewModel.currentVideoInfo {
                Text(MirmirPresentation.durationText(info.duration))
                    .font(theme.typography.caption.monospacedDigit())
                    .foregroundStyle(theme.textTertiary)
            }
        }
    }

    private var inspector: some View {
        MirmirProductPanel(theme: theme) {
            VStack(alignment: .leading, spacing: theme.spacing.space5) {
                Text("Upscale Settings")
                    .font(theme.typography.headline)

                outputSizeControls
                Divider().overlay(theme.borderSubtle)
                methodControls
                Divider().overlay(theme.borderSubtle)
                outputControls
                Divider().overlay(theme.borderSubtle)
                actionControls
            }
        }
    }

    private var outputSizeControls: some View {
        MirmirProductField("Target", theme: theme) {
            VStack(alignment: .leading, spacing: theme.spacing.space2) {
                HStack(spacing: theme.spacing.space2) {
                    TextField(
                        "Width",
                        value: Binding(
                            get: { viewModel.targetWidth },
                            set: {
                                viewModel.setTargetWidth(
                                    $0,
                                    preservingAspectRatio: aspectLocked
                                )
                            }
                        ),
                        format: .number.grouping(.never)
                    )
                    Text("×").foregroundStyle(theme.textTertiary)
                    TextField(
                        "Height",
                        value: Binding(
                            get: { viewModel.targetHeight },
                            set: {
                                viewModel.setTargetHeight(
                                    $0,
                                    preservingAspectRatio: aspectLocked
                                )
                            }
                        ),
                        format: .number.grouping(.never)
                    )
                    Button {
                        aspectLocked.toggle()
                    } label: {
                        Image(systemName: aspectLocked ? "lock" : "lock.open")
                    }
                    .buttonStyle(.borderless)
                    .help(aspectLocked ? "Unlock aspect ratio" : "Lock aspect ratio")
                }
                .disabled(
                    viewModel.currentVideoInfo == nil || viewModel.isProcessing
                )

                HStack(spacing: theme.spacing.space1) {
                    scaleButton("1.5×", numerator: 3, denominator: 2)
                    scaleButton("2×", numerator: 2, denominator: 1)
                    scaleButton("3×", numerator: 3, denominator: 1)
                    scaleButton("4×", numerator: 4, denominator: 1)
                }

                Text(targetHelp)
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.textTertiary)
            }
        }
    }

    private func scaleButton(
        _ label: String,
        numerator: Int,
        denominator: Int
    ) -> some View {
        Button(label) {
            viewModel.applyScale(
                numerator: numerator,
                denominator: denominator
            )
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(viewModel.currentVideoInfo == nil || viewModel.isProcessing)
    }

    private var methodControls: some View {
        MirmirProductField("Method", theme: theme) {
            VStack(alignment: .leading, spacing: theme.spacing.space2) {
                Menu {
                    ForEach(BackendGroup.allCases, id: \.self) { group in
                        Section(group.rawValue) {
                            ForEach(
                                BackendDescriptor.all.filter {
                                    $0.group == group
                                },
                                id: \.id
                            ) { descriptor in
                                Button {
                                    selectMethod(descriptor.id)
                                } label: {
                                    if descriptor.id == viewModel.selectedBackendID {
                                        Label(
                                            descriptor.title,
                                            systemImage: "checkmark"
                                        )
                                    } else {
                                        Text(descriptor.title)
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    HStack {
                        Text(selectedMethodTitle)
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                    }
                    .padding(.horizontal, theme.spacing.space2)
                    .frame(maxWidth: .infinity, minHeight: 30)
                    .background(
                        RoundedRectangle(cornerRadius: theme.radius.small)
                            .fill(theme.surface)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: theme.radius.small)
                            .stroke(theme.borderSubtle, lineWidth: 1)
                    }
                }
                .menuStyle(.borderlessButton)
                .disabled(viewModel.isProcessing)
                .accessibilityIdentifier("mirmir.backendPicker")

                Text(selectedMethodSummary)
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Label(methodStatus, systemImage: methodStatusSymbol)
                    .font(theme.typography.captionEmphasis)
                    .foregroundStyle(methodStatusTone.color(theme: theme))

                Button("Browse all methods", action: showMethods)
                    .buttonStyle(.link)

                if case .modelDownloadRequired =
                    viewModel.selectedBackendAvailability {
                    VStack(alignment: .leading, spacing: theme.spacing.space2) {
                        if viewModel.isDownloadingModel {
                            if let progress = viewModel.modelDownloadProgress {
                                ProgressView(value: progress)
                            } else {
                                ProgressView()
                            }
                        }
                        Button("Download Apple Model") {
                            viewModel.downloadSelectedModel()
                        }
                        .disabled(viewModel.isDownloadingModel)
                        if let message = viewModel.modelDownloadMessage {
                            Text(message)
                                .font(theme.typography.caption)
                                .foregroundStyle(theme.textSecondary)
                        }
                    }
                }
            }
        }
    }

    private var outputControls: some View {
        MirmirProductField("Output", theme: theme) {
            VStack(alignment: .leading, spacing: theme.spacing.space2) {
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
                .labelsHidden()
                .pickerStyle(.menu)
                .disabled(viewModel.isProcessing)

                Button {
                    viewModel.chooseOutput()
                } label: {
                    HStack {
                        Image(systemName: "square.and.arrow.up")
                        Text(
                            viewModel.outputURL?.lastPathComponent
                                ?? "Choose destination folder…"
                        )
                            .lineLimit(1)
                        Spacer()
                    }
                }
                .buttonStyle(MirmirProductSecondaryButtonStyle(theme: theme))
                .disabled(
                    viewModel.currentVideoInfo == nil || viewModel.isProcessing
                )
                .accessibilityIdentifier("mirmir.chooseOutputFolder")

                Toggle(
                    "Preserve audio",
                    isOn: Binding(
                        get: { viewModel.preserveAudio },
                        set: { viewModel.setPreserveAudio($0) }
                    )
                )
                .disabled(
                    viewModel.currentVideoInfo?.hasAudio != true
                        || viewModel.isProcessing
                )

                Toggle(
                    "Replace existing file",
                    isOn: Binding(
                        get: { viewModel.overwriteExistingFile },
                        set: { viewModel.setOverwriteExistingFile($0) }
                    )
                )
                .disabled(viewModel.isProcessing)
            }
        }
    }

    private var actionControls: some View {
        VStack(alignment: .leading, spacing: theme.spacing.space2) {
            if viewModel.isProcessing {
                Button(role: .destructive) {
                    viewModel.cancelProcessing()
                } label: {
                    Label("Cancel", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(MirmirProductSecondaryButtonStyle(theme: theme))
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("mirmir.cancelProcessing")
            } else {
                Button {
                    viewModel.startUpscale()
                } label: {
                    Label("Start Upscale", systemImage: "play.fill")
                }
                .buttonStyle(MirmirProductPrimaryButtonStyle(theme: theme))
                .disabled(!viewModel.canStart)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("mirmir.startUpscale")
            }

            Text(viewModel.startValidationMessage ?? "Ready to process.")
                .font(theme.typography.caption)
                .foregroundStyle(
                    viewModel.canStart ? theme.success : theme.textTertiary
                )
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusStrip: some View {
        HStack(spacing: theme.spacing.space3) {
            MirmirProductStatusCard(
                title: "Source",
                primary: MirmirPresentation.sizeText(
                    viewModel.currentVideoInfo?.geometry.encodedSize
                ),
                secondary: MirmirPresentation.frameRateText(
                    viewModel.currentVideoInfo?.nominalFrameRate
                ),
                symbolName: "film",
                tone: viewModel.currentVideoInfo == nil ? .neutral : .success,
                theme: theme
            )
            MirmirProductStatusCard(
                title: "Output",
                primary: targetSizeText,
                secondary: viewModel.outputCodec.displayName,
                symbolName: "arrow.up.left.and.arrow.down.right",
                tone: viewModel.targetWidth > 0 ? .active : .neutral,
                theme: theme
            )
            MirmirProductStatusCard(
                title: "Method",
                primary: selectedMethodShortTitle,
                secondary: methodStatus,
                symbolName: "cpu",
                tone: methodStatusTone,
                theme: theme
            )
            MirmirProductStatusCard(
                title: "Job",
                primary: stateText,
                secondary: progressText,
                symbolName: stateSymbol,
                tone: stateTone,
                theme: theme
            )
        }
    }

    private var sourceHeading: String {
        switch viewModel.state {
        case .probing: "Analyzing source"
        default: viewModel.currentVideoInfo == nil ? "Choose video" : "Source ready"
        }
    }

    private var sourceSummary: String {
        guard let info = viewModel.currentVideoInfo else {
            if case .probing(let url) = viewModel.state {
                return url.lastPathComponent
            }
            return "Drop a video into the viewer or choose a source file."
        }
        return "\(info.filename) · "
            + "\(MirmirPresentation.sizeText(info.geometry.encodedSize)) · "
            + "\(MirmirPresentation.frameRateText(info.nominalFrameRate)) · "
            + MirmirPresentation.durationText(info.duration)
    }

    private var targetHelp: String {
        guard let source = viewModel.currentVideoInfo else {
            return "Choose a source to set exact encoded dimensions."
        }
        return "Source: \(MirmirPresentation.sizeText(source.geometry.encodedSize)). "
            + "Availability refreshes whenever the target changes."
    }

    private var selectedMethodTitle: String {
        BackendDescriptor.descriptor(for: viewModel.selectedBackendID)?.title
            ?? viewModel.selectedBackendID.rawValue
    }

    private var selectedMethodShortTitle: String {
        switch viewModel.selectedBackendID {
        case .automatic: "Automatic"
        case .mirmirDeterministicCPU: "Mirmir CPU"
        case .mirmirDeterministicMetal: "Mirmir Metal"
        case .videoToolboxSuperResolutionQuality: "VT Quality"
        case .videoToolboxSuperResolutionLowLatency: "VT Low Latency"
        case .videoToolboxInterpolationWithSpatialScale: "Smooth Motion"
        case .metalFXSpatial: "MetalFX"
        case .mpsLanczos: "MPS Lanczos"
        case .mpsBilinear: "MPS Bilinear"
        case .coreImageLanczos: "CI Lanczos"
        case .coreImageBicubic: "CI Bicubic"
        case .vImageHighQuality: "vImage HQ"
        case .vImageStandard: "vImage"
        case .videoToolboxPixelTransfer: "VT Transfer"
        }
    }

    private var selectedMethodSummary: String {
        BackendDescriptor.descriptor(for: viewModel.selectedBackendID)?.summary
            ?? "Select a source to inspect available methods."
    }

    private var methodStatus: String {
        if viewModel.isCheckingBackendAvailability { return "Checking…" }
        return viewModel.selectedBackendAvailability?.statusText
            ?? "Waiting for source"
    }

    private var methodStatusSymbol: String {
        switch viewModel.selectedBackendAvailability {
        case .some(.available): "checkmark.circle"
        case .some(.modelDownloadRequired): "arrow.down.circle"
        case .some(.unavailable): "exclamationmark.triangle"
        case nil: "circle"
        }
    }

    private var methodStatusTone: MirmirProductStatusTone {
        switch viewModel.selectedBackendAvailability {
        case .some(.available): .success
        case .some(.modelDownloadRequired): .warning
        case .some(.unavailable): .warning
        case nil: .neutral
        }
    }

    private var viewerBadge: String {
        switch viewModel.state {
        case .empty: "NO SOURCE"
        case .probing: "PROBING"
        case .ready: "READY"
        case .processing: "PROCESSING"
        case .completed: "OUTPUT READY"
        case .failed: "FAILED"
        }
    }

    private var stateText: String {
        switch viewModel.state {
        case .empty: "Idle"
        case .probing: "Analyzing"
        case .ready: "Ready"
        case .processing: "Processing"
        case .completed: "Complete"
        case .failed: "Failed"
        }
    }

    private var stateSymbol: String {
        switch viewModel.state {
        case .empty: "circle"
        case .probing: "waveform"
        case .ready: "checkmark.circle"
        case .processing: "gearshape.2"
        case .completed: "checkmark.seal"
        case .failed: "exclamationmark.octagon"
        }
    }

    private var stateTone: MirmirProductStatusTone {
        switch viewModel.state {
        case .empty: .neutral
        case .probing, .processing: .active
        case .ready: .success
        case .completed: .success
        case .failed: .danger
        }
    }

    private var progressText: String {
        guard case .processing(_, let progress) = viewModel.state else {
            switch viewModel.state {
            case .completed(_, let result):
                return "\(result.processedFrameCount) frames"
            case .failed(let error):
                return error.localizedDescription
            default:
                return "One active job"
            }
        }
        if let fraction = progress.fractionCompleted {
            return "\(Int((fraction * 100).rounded()))% · "
                + "\(progress.processedFrameCount) frames"
        }
        return "\(progress.processedFrameCount) frames"
    }

    private var targetSizeText: String {
        guard viewModel.targetWidth > 0, viewModel.targetHeight > 0 else {
            return "Not set"
        }
        return "\(viewModel.targetWidth) × \(viewModel.targetHeight)"
    }
}

struct MirmirBackendCatalogView: View {
    let viewModel: MirmirViewModel
    let theme: MirmirThemeTokens
    let selectAndReturn: (UpscaleBackendID) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.spacing.space5) {
                Text(
                    "Every method remains visible and selectable. Availability is "
                        + "evaluated for the current source, exact target, OS, and "
                        + "hardware; unavailable selections retain their reason."
                )
                .font(theme.typography.body)
                .foregroundStyle(theme.textSecondary)

                ForEach(BackendGroup.allCases, id: \.self) { group in
                    VStack(alignment: .leading, spacing: theme.spacing.space2) {
                        Text(group.rawValue.uppercased())
                            .font(theme.typography.micro)
                            .foregroundStyle(theme.textTertiary)
                        ForEach(
                            BackendDescriptor.all.filter { $0.group == group },
                            id: \.id
                        ) { descriptor in
                            methodRow(descriptor)
                        }
                    }
                }
            }
            .padding(theme.spacing.space6)
        }
        .background(theme.background)
    }

    private func methodRow(_ descriptor: BackendDescriptor) -> some View {
        let availability = viewModel.backendSnapshot?
            .entry(for: descriptor.id)?.availability
        let selected = descriptor.id == viewModel.selectedBackendID
        return Button {
            selectAndReturn(descriptor.id)
        } label: {
            HStack(alignment: .top, spacing: theme.spacing.space3) {
                Image(
                    systemName: selected
                        ? "largecircle.fill.circle"
                        : availabilitySymbol(availability)
                )
                .foregroundStyle(
                    selected
                        ? theme.accentPrimary
                        : availabilityTone(availability).color(theme: theme)
                )
                .frame(width: 20)

                VStack(alignment: .leading, spacing: theme.spacing.space1) {
                    Text(descriptor.title)
                        .font(theme.typography.bodyEmphasis)
                        .foregroundStyle(theme.textPrimary)
                    Text(descriptor.summary)
                        .font(theme.typography.caption)
                        .foregroundStyle(theme.textSecondary)
                    Text(statusText(descriptor, availability: availability))
                        .font(theme.typography.captionEmphasis)
                        .foregroundStyle(
                            availabilityTone(availability).color(theme: theme)
                        )
                }
                Spacer(minLength: 8)
                Text(descriptor.operationClass.rawValue)
                    .font(theme.typography.micro)
                    .foregroundStyle(theme.textTertiary)
                    .multilineTextAlignment(.trailing)
            }
            .padding(theme.spacing.space3)
            .background(
                RoundedRectangle(cornerRadius: theme.radius.large)
                    .fill(selected ? theme.accentMuted : theme.surfaceElevated)
            )
            .overlay {
                RoundedRectangle(cornerRadius: theme.radius.large)
                    .stroke(
                        selected ? theme.accentPrimary : theme.borderSubtle,
                        lineWidth: 1
                    )
            }
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isProcessing)
        .accessibilityIdentifier("mirmir.backend.\(descriptor.id.rawValue)")
        .accessibilityValue(statusText(descriptor, availability: availability))
    }

    private func statusText(
        _ descriptor: BackendDescriptor,
        availability: BackendAvailability?
    ) -> String {
        guard let availability else {
            return viewModel.isCheckingBackendAvailability
                ? "Checking…"
                : "Choose a source to check availability"
        }
        if descriptor.id == .automatic,
           availability == .available,
           let proposal = viewModel.backendSnapshot?.automaticProposal,
           let proposed = BackendDescriptor.descriptor(for: proposal) {
            return "Available — Would use \(proposed.title)"
        }
        return availability.statusText
    }

    private func availabilitySymbol(
        _ availability: BackendAvailability?
    ) -> String {
        switch availability {
        case .some(.available): "checkmark.circle"
        case .some(.modelDownloadRequired): "arrow.down.circle"
        case .some(.unavailable): "xmark.circle"
        case nil: "circle"
        }
    }

    private func availabilityTone(
        _ availability: BackendAvailability?
    ) -> MirmirProductStatusTone {
        switch availability {
        case .some(.available): .success
        case .some(.modelDownloadRequired): .warning
        case .some(.unavailable): .neutral
        case nil: .neutral
        }
    }
}

private struct MirmirSourceDropSurface: View {
    let viewModel: MirmirViewModel
    let theme: MirmirThemeTokens
    @State private var isTargeted = false

    var body: some View {
        RoundedRectangle(cornerRadius: theme.radius.xlarge)
            .fill(isTargeted ? theme.accentMuted : theme.surfaceInset)
            .overlay {
                RoundedRectangle(cornerRadius: theme.radius.xlarge)
                    .stroke(
                        isTargeted ? theme.accentPrimary : theme.borderStrong,
                        style: StrokeStyle(lineWidth: 1, dash: [7])
                    )
            }
            .overlay {
                VStack(spacing: theme.spacing.space3) {
                    MirmirBrandLockup(
                        layout: .markOnly,
                        iconSize: 68,
                        theme: theme
                    )
                    .accessibilityHidden(true)
                    .opacity(isTargeted ? 1 : 0.72)
                    Text(isTargeted ? "Release to load" : "No video loaded")
                        .font(theme.typography.subtitle)
                    Text(
                        isTargeted
                            ? "Mirmir will inspect this source"
                            : "Drop a video here or choose a source file"
                    )
                    .font(theme.typography.body)
                    .foregroundStyle(theme.textSecondary)
                    Button("Choose Source") { viewModel.openVideo() }
                        .buttonStyle(MirmirProductSecondaryButtonStyle(theme: theme))
                }
            }
            .onDrop(of: [UTType.fileURL], isTargeted: $isTargeted) { providers in
                guard !viewModel.isProcessing,
                      let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in viewModel.selectVideo(url) }
                }
                return true
            }
            .accessibilityIdentifier("mirmir.emptyState")
            .accessibilityLabel("Source video drop target")
    }
}

private struct MirmirSourceVideoPreview: View {
    let info: VideoInfo
    let theme: MirmirThemeTokens

    var body: some View {
        MirmirBeforeAfterComparison(
            source: info,
            outputURL: nil,
            outputSizeText: nil,
            afterState: .waiting,
            theme: theme
        )
    }
}

private struct MirmirViewerMessage: View {
    let symbol: String
    let title: String
    let detail: String
    let showsProgress: Bool
    let theme: MirmirThemeTokens

    var body: some View {
        RoundedRectangle(cornerRadius: theme.radius.xlarge)
            .fill(theme.surfaceInset)
            .overlay {
                VStack(spacing: theme.spacing.space3) {
                    Image(systemName: symbol)
                        .font(.system(size: 38, weight: .light))
                        .foregroundStyle(theme.accentPrimary)
                    Text(title).font(theme.typography.subtitle)
                    Text(detail)
                        .font(theme.typography.body)
                        .foregroundStyle(theme.textSecondary)
                        .multilineTextAlignment(.center)
                    if showsProgress { ProgressView().controlSize(.small) }
                }
                .padding(theme.spacing.space6)
            }
            .overlay {
                RoundedRectangle(cornerRadius: theme.radius.xlarge)
                    .stroke(theme.borderSubtle, lineWidth: 1)
            }
    }
}

private struct MirmirProcessingViewer: View {
    let info: VideoInfo
    let progress: UpscaleProgress
    let theme: MirmirThemeTokens

    var body: some View {
        VStack(spacing: theme.spacing.space3) {
            MirmirBeforeAfterComparison(
                source: info,
                outputURL: nil,
                outputSizeText: nil,
                afterState: .processing,
                theme: theme
            )

            HStack(spacing: theme.spacing.space3) {
                ProgressView(value: progress.fractionCompleted)
                    .frame(maxWidth: 320)
                Text(progress.phase.rawValue)
                    .font(theme.typography.captionEmphasis)
                Spacer()
                Text("\(progress.processedFrameCount) frames")
                    .font(theme.typography.caption.monospacedDigit())
                    .foregroundStyle(theme.textTertiary)
                if let fraction = progress.fractionCompleted {
                    Text("\(Int((fraction * 100).rounded()))%")
                        .font(theme.typography.bodyEmphasis.monospacedDigit())
                        .foregroundStyle(theme.accentPrimary)
                }
            }
            .padding(.horizontal, theme.spacing.space2)
        }
        .accessibilityIdentifier("mirmir.processing")
    }
}

private struct MirmirCompletionViewer: View {
    let source: VideoInfo
    let result: UpscaleResult
    let viewModel: MirmirViewModel
    let theme: MirmirThemeTokens

    var body: some View {
        VStack(spacing: theme.spacing.space3) {
            MirmirBeforeAfterComparison(
                source: source,
                outputURL: result.outputURL,
                outputSizeText: "\(result.encodedWidth) × \(result.encodedHeight)",
                afterState: .complete,
                theme: theme
            )

            HStack(spacing: theme.spacing.space3) {
                ZStack(alignment: .bottomTrailing) {
                    MirmirBrandLockup(
                        layout: .markOnly,
                        iconSize: 38,
                        theme: theme
                    )
                    .accessibilityHidden(true)
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Color.white, theme.success)
                        .font(.system(size: 15, weight: .semibold))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Upscale Complete")
                        .font(theme.typography.bodyEmphasis)
                    Text(result.outputURL.lastPathComponent)
                        .font(theme.typography.caption)
                        .foregroundStyle(theme.textSecondary)
                }
                Spacer()
                Button("Open Output") { viewModel.openCompletedOutput() }
                    .buttonStyle(MirmirProductPrimaryButtonStyle(theme: theme))
                Button("Reveal in Finder") {
                    viewModel.revealCompletedOutput()
                }
                .buttonStyle(MirmirProductSecondaryButtonStyle(theme: theme))
                Button("Process Another") { viewModel.processAnother() }
                    .buttonStyle(MirmirProductSecondaryButtonStyle(theme: theme))
            }
            .padding(.horizontal, theme.spacing.space2)
        }
        .accessibilityIdentifier("mirmir.completed")
    }
}

private enum MirmirAfterPreviewState {
    case waiting
    case processing
    case complete
}

private struct MirmirBeforeAfterComparison: View {
    let source: VideoInfo
    let outputURL: URL?
    let outputSizeText: String?
    let afterState: MirmirAfterPreviewState
    let theme: MirmirThemeTokens

    @State private var sourceFrame: CGImage?
    @State private var outputFrame: CGImage?
    @State private var splitFraction = 0.5

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let splitX = width * splitFraction

            ZStack(alignment: .leading) {
                previewLayer(
                    image: outputFrame,
                    fallbackImage: sourceFrame,
                    isAfter: true
                )

                previewLayer(
                    image: sourceFrame,
                    fallbackImage: nil,
                    isAfter: false
                )
                .frame(width: width, height: proxy.size.height)
                .mask(alignment: .leading) {
                    Rectangle().frame(width: splitX)
                }

                Rectangle()
                    .fill(theme.viewerOverlayText.opacity(0.82))
                    .frame(width: 1)
                    .offset(x: splitX)
                    .allowsHitTesting(false)

                Image(systemName: "arrow.left.and.right.circle.fill")
                    .font(.system(size: 26, weight: .medium))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(theme.accentPrimary, Color.white)
                    .shadow(color: .black.opacity(0.35), radius: 5, y: 2)
                    .offset(x: splitX - 13)
                    .allowsHitTesting(false)

                comparisonLabels
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        splitFraction = min(
                            0.92,
                            max(0.08, value.location.x / width)
                        )
                    }
            )
        }
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: theme.radius.xlarge))
        .overlay {
            RoundedRectangle(cornerRadius: theme.radius.xlarge)
                .stroke(theme.borderSubtle, lineWidth: 1)
        }
        .task(id: source.url) {
            sourceFrame = await MirmirFramePreviewLoader.frame(
                at: source.url,
                preferredTime: source.duration.seconds / 2
            )
        }
        .task(id: outputURL) {
            guard let outputURL else {
                outputFrame = nil
                return
            }
            outputFrame = await MirmirFramePreviewLoader.frame(
                at: outputURL,
                preferredTime: source.duration.seconds / 2
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Before and after comparison viewer")
        .accessibilityValue("Divider at \(Int(splitFraction * 100)) percent")
    }

    @ViewBuilder
    private func previewLayer(
        image: CGImage?,
        fallbackImage: CGImage?,
        isAfter: Bool
    ) -> some View {
        ZStack {
            LinearGradient(
                colors: [Color.black, theme.surfaceInset],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            if let image = image ?? fallbackImage {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Image(systemName: "film")
                    .font(.system(size: 44, weight: .ultraLight))
                    .foregroundStyle(theme.textTertiary)
            }

            if isAfter, outputFrame == nil {
                Color.black.opacity(0.52)
                VStack(spacing: theme.spacing.space2) {
                    Image(
                        systemName: afterState == .processing
                            ? "gearshape.2"
                            : "sparkles.rectangle.stack"
                    )
                    .font(.system(size: 28, weight: .light))
                    Text(
                        afterState == .processing
                            ? "Building after view"
                            : "After preview pending"
                    )
                    .font(theme.typography.captionEmphasis)
                }
                .foregroundStyle(theme.viewerOverlayText)
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .trailing
                )
                .padding(.trailing, theme.spacing.space6)
            }
        }
    }

    private var comparisonLabels: some View {
        VStack {
            Spacer()
            HStack {
                previewLabel(
                    title: "Before",
                    detail: MirmirPresentation.sizeText(source.displaySize)
                )
                Spacer()
                previewLabel(
                    title: "After",
                    detail: outputSizeText ?? afterStatusText
                )
            }
            .padding(theme.spacing.space3)
        }
        .allowsHitTesting(false)
    }

    private func previewLabel(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title.uppercased())
                .font(theme.typography.micro)
            Text(detail)
                .font(theme.typography.caption.monospacedDigit())
        }
        .foregroundStyle(theme.viewerOverlayText)
        .padding(.horizontal, theme.spacing.space2)
        .padding(.vertical, theme.spacing.space1)
        .background(
            RoundedRectangle(cornerRadius: theme.radius.small)
                .fill(theme.viewerOverlay)
        )
    }

    private var afterStatusText: String {
        afterState == .processing ? "Processing" : "Awaiting output"
    }
}

private enum MirmirFramePreviewLoader {
    static func frame(at url: URL, preferredTime: Double) async -> CGImage? {
        await Task.detached(priority: .utility) {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 1600, height: 1000)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero

            let seconds = preferredTime.isFinite
                ? max(0, preferredTime)
                : 0
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            guard let result = try? await generator.image(at: time) else {
                return nil
            }
            return result.image
        }.value
    }
}

private struct MirmirFailureViewer: View {
    let error: MirmirError
    let canReturn: Bool
    let returnToSettings: () -> Void
    let theme: MirmirThemeTokens

    var body: some View {
        RoundedRectangle(cornerRadius: theme.radius.xlarge)
            .fill(theme.surfaceInset)
            .overlay {
                VStack(spacing: theme.spacing.space4) {
                    Image(systemName: "exclamationmark.octagon.fill")
                        .font(.system(size: 44, weight: .light))
                        .foregroundStyle(theme.danger)
                    Text("Mirmir Couldn’t Finish")
                        .font(theme.typography.title)
                    Text(error.localizedDescription)
                        .font(theme.typography.body)
                        .foregroundStyle(theme.textSecondary)
                        .multilineTextAlignment(.center)
                    if canReturn {
                        Button("Return to Settings", action: returnToSettings)
                            .buttonStyle(MirmirProductSecondaryButtonStyle(theme: theme))
                    }
                }
                .padding(theme.spacing.space6)
            }
            .overlay {
                RoundedRectangle(cornerRadius: theme.radius.xlarge)
                    .stroke(theme.danger, lineWidth: 1)
            }
            .accessibilityIdentifier("mirmir.errorState")
    }
}
