import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MirmirWorkflowRootView: View {
    @ObservedObject var viewModel: MirmirViewModel
    @State private var showsSettings = false
    @State private var showsAbout = false

    var body: some View {
        VStack(spacing: 0) {
            MirmirHeaderView(
                engineStatus: viewModel.engineReadinessText,
                showSettings: { showsSettings = true },
                showAbout: { showsAbout = true }
            )

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    SourceVideoStepView(viewModel: viewModel)
                    Divider()
                    QualityEffectsStepView(viewModel: viewModel)
                    Divider()
                    TargetOutputStepView(viewModel: viewModel)
                    Divider()
                    JobProgressView(viewModel: viewModel)
                    CompletionActionsView(viewModel: viewModel)
                }
                .padding(24)
                .frame(maxWidth: 980, alignment: .leading)
                .frame(maxWidth: .infinity)
            }

            Divider()

            UpscaleActionBar(viewModel: viewModel)
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
        }
        .sheet(isPresented: $showsSettings) {
            MirmirSettingsView(viewModel: viewModel)
                .frame(width: 560, height: 440)
        }
        .sheet(isPresented: $showsAbout) {
            MirmirAboutView(viewModel: viewModel, showsTechnicalDetails: true)
                .frame(width: 520, height: 360)
        }
    }
}

struct MirmirHeaderView: View {
    let engineStatus: String
    let showSettings: () -> Void
    let showAbout: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Mirmir")
                    .font(.title2.weight(.semibold))
                Text("Video upscaling workflow")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Label(engineStatus, systemImage: "checkmark.circle")
                .font(.callout)
                .foregroundStyle(.secondary)

            Button(action: showSettings) {
                Image(systemName: "gearshape")
            }
            .help("Settings")

            Button(action: showAbout) {
                Image(systemName: "info.circle")
            }
            .help("About Mirmir")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }
}

struct SourceVideoStepView: View {
    @ObservedObject var viewModel: MirmirViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            stepHeader(number: "1", title: "Select video")

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    Button {
                        viewModel.chooseSourceFile()
                    } label: {
                        Label("Choose Video", systemImage: "film.stack")
                            .frame(minWidth: 160)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    WorkflowDropZone(viewModel: viewModel)
                        .frame(maxWidth: .infinity, minHeight: 96)
                }
                .frame(minWidth: 280, maxWidth: 340)

                SourceSummaryView(viewModel: viewModel)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct SourceSummaryView: View {
    @ObservedObject var viewModel: MirmirViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let profile = viewModel.sourceProfile {
                summaryRow("File", profile.url.lastPathComponent)
                summaryRow("Resolution", String(describing: profile.resolution))
                summaryRow("Frame rate", String(format: "%.2f fps", profile.frameRate))
                summaryRow("Duration", String(format: "%.1f s", profile.durationSeconds))
                if let codec = profile.codecHint {
                    summaryRow("Codec", codec)
                }
                summaryRow("Audio", profile.hasAudio ? "Yes" : "No")
            } else {
                Text("Choose an MP4, MOV, M4V, QT, AVI, MPG, or MPEG video.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if case .failed(let reason) = viewModel.state {
                    Label(reason, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func summaryRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            Text(value)
                .fontDesign(.monospaced)
                .lineLimit(2)
        }
        .font(.callout)
    }
}

struct QualityEffectsStepView: View {
    @ObservedObject var viewModel: MirmirViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            stepHeader(number: "2", title: "Choose quality and effects")

            Picker("Quality", selection: $viewModel.qualityMode) {
                ForEach(MirmirQualityMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 520)

            Text(viewModel.qualityMode.summary)
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(viewModel.effectOptions) { effect in
                    Toggle(isOn: .constant(effect.isEnabled)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(effect.title)
                            Text(effect.disabledReason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(true)
                }
            }
        }
    }
}

struct TargetOutputStepView: View {
    @ObservedObject var viewModel: MirmirViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            stepHeader(number: "3", title: "Choose target and output")

            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 10) {
                    if viewModel.availableTargets.isEmpty {
                        Text("Select a 720p or 1080p source first.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Target Resolution", selection: $viewModel.targetResolution) {
                            ForEach(viewModel.availableTargets, id: \.self) { resolution in
                                Text(MirmirViewModel.fileLabel(for: resolution)).tag(resolution)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 260)
                    }

                    Picker("Codec", selection: $viewModel.codec) {
                        ForEach(OutputCodec.allCases) { codec in
                            Text(codec.rawValue.uppercased()).tag(codec)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 260)
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Output")
                            .font(.headline)
                        Spacer()
                        Button {
                            _ = viewModel.chooseOutputFile()
                        } label: {
                            Label("Change Output", systemImage: "folder")
                        }
                    }

                    if let outputURL = viewModel.outputURL {
                        Text(outputURL.path)
                            .font(.callout)
                            .fontDesign(.monospaced)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .textSelection(.enabled)
                    } else {
                        Text("Mirmir will save next to the source after a supported target is available.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct UpscaleActionBar: View {
    @ObservedObject var viewModel: MirmirViewModel

    var body: some View {
        HStack(spacing: 14) {
            statusLabel

            Spacer()

            Button {
                viewModel.cancelUpscale()
            } label: {
                Image(systemName: "stop.fill")
            }
            .disabled(!isRunning)
            .help("Cancel upscale")

            Button {
                viewModel.startUpscale()
            } label: {
                Label("Upscale Video", systemImage: "play.fill")
                    .frame(minWidth: 160)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!viewModel.canStart)
        }
    }

    private var isRunning: Bool {
        if case .running = viewModel.state {
            return true
        }
        return false
    }

    @ViewBuilder
    private var statusLabel: some View {
        if let reason = viewModel.canStartFailureReason {
            Text(reason)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        } else {
            Text("Ready to upscale.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

struct JobProgressView: View {
    @ObservedObject var viewModel: MirmirViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepHeader(number: "4", title: "Upscale and review")

            switch viewModel.state {
            case .idle:
                Text("Choose a source video to begin.")
                    .foregroundStyle(.secondary)
            case .probing:
                ProgressView("Reading source video...")
                    .progressViewStyle(.linear)
            case .ready:
                readyText
            case .running:
                runningProgress
            case .finished(let url):
                Label("Upscale complete: \(url.lastPathComponent)", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            case .failed(let reason):
                Label(reason, systemImage: "exclamationmark.octagon.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var readyText: some View {
        if let profile = viewModel.sourceProfile {
            let sourceResolution = String(describing: profile.resolution)
            Text(sourceResolution + " to " + MirmirViewModel.fileLabel(for: viewModel.targetResolution))
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            Text("Ready.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var runningProgress: some View {
        if let progress = viewModel.progress {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: progress.fraction)
                    .progressViewStyle(.linear)
                HStack {
                    Text("\(progress.framesProcessed) / \(progress.totalFrames) frames")
                    Spacer()
                    Text(String(format: "%.1f fps", progress.throughputFPS))
                    if let eta = progress.etaSeconds, eta.isFinite {
                        Text("ETA \(format(eta: eta))")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.callout.monospacedDigit())
            }
        } else {
            ProgressView("Starting upscale...")
        }
    }

    private func format(eta: Double) -> String {
        guard eta > 0 else { return "0s" }
        let totalSeconds = Int(eta.rounded())
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return minutes > 0 ? "\(minutes)m \(seconds)s" : "\(seconds)s"
    }
}

struct CompletionActionsView: View {
    @ObservedObject var viewModel: MirmirViewModel

    var body: some View {
        if case .finished = viewModel.state {
            HStack(spacing: 12) {
                Button {
                    viewModel.revealOutputInFinder()
                } label: {
                    Label("Reveal in Finder", systemImage: "finder")
                }

                Button {
                    viewModel.upscaleAnotherVideo()
                } label: {
                    Label("Upscale Another", systemImage: "arrow.counterclockwise")
                }
            }
        }
    }
}

private struct WorkflowDropZone: View {
    @ObservedObject var viewModel: MirmirViewModel
    @State private var isTargeted = false

    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [6]))
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isTargeted ? Color.accentColor.opacity(0.15) : Color.clear)
            )
            .overlay(
                Label(isTargeted ? "Release to Load" : "Drag Video Here", systemImage: "arrow.down.doc")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            )
            .onDrop(of: [UTType.fileURL], isTargeted: $isTargeted) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url {
                        Task { @MainActor in viewModel.loadSource(url: url) }
                    }
                }
                return true
            }
    }
}

@ViewBuilder
private func stepHeader(number: String, title: String) -> some View {
    HStack(spacing: 10) {
        Text(number)
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(Circle().fill(Color.accentColor))
        Text(title)
            .font(.title3.weight(.semibold))
    }
}
