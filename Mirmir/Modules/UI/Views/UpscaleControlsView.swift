import SwiftUI

struct UpscaleControlsView: View {

    @ObservedObject var viewModel: MirmirViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Settings")
                .font(.headline)

            if viewModel.availableTargets.isEmpty {
                Text(
                    "Select a source below 2160p with a valid "
                        + "upscale target."
                )
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Picker(
                    "Target resolution",
                    selection: targetSelection
                ) {
                    ForEach(viewModel.availableTargets, id: \.self) { resolution in
                        Text(String(describing: resolution)).tag(resolution)
                    }
                }
                .pickerStyle(.menu)
                .disabled(!viewModel.jobConfigurationIsEditable)
            }

            Picker("Codec", selection: codecSelection) {
                ForEach(OutputCodec.allCases) { codec in
                    Text(codec.displayName).tag(codec)
                }
            }
            .pickerStyle(.segmented)
            .disabled(!viewModel.jobConfigurationIsEditable)

            Picker("Mode", selection: modeSelection) {
                ForEach(UpscaleMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(!viewModel.jobConfigurationIsEditable)
            Text(viewModel.selectedModeSummary)
                .font(.caption)
                .foregroundStyle(
                    viewModel.engineAvailabilityReason == nil
                        ? Color.secondary
                        : Color.orange
                )

            if viewModel.selectedMode == .smoothMotion {
                Picker(
                    "Output Cadence",
                    selection: smoothMotionCadenceSelection
                ) {
                    ForEach(SmoothMotionCadence.allCases) { cadence in
                        Text(cadence.title).tag(cadence)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!viewModel.jobConfigurationIsEditable)

                Picker(
                    "Scene Cut Protection",
                    selection: smoothMotionSceneCutSelection
                ) {
                    ForEach(
                        SmoothMotionSceneCutSensitivity.allCases
                    ) { sensitivity in
                        Text(sensitivity.title).tag(sensitivity)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!viewModel.jobConfigurationIsEditable)

                Text(
                    "Output duration and audio timing remain unchanged."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if viewModel.modelAssetsShowsPreparationControl {
                VStack(alignment: .leading, spacing: 6) {
                    Text(viewModel.modelAssetsStatusText)
                        .font(.callout.weight(.semibold))
                    Text(viewModel.modelAssetsDetailText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if case .downloading(let progress) =
                        viewModel.modelStatus {
                        ProgressView(
                            value: min(max(progress, 0), 1)
                        )
                        .accessibilityLabel("Model download progress")
                    }
                    if viewModel.modelAssetsCanPrepare {
                        Button(
                            viewModel.modelAssetsPreparationActionTitle,
                            action: viewModel.ensureModelsReady
                        )
                        .disabled(viewModel.jobIsRunning)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Output").foregroundStyle(.secondary)
                    Spacer()
                    Button("Choose…") { _ = viewModel.chooseOutputFile() }
                        .controlSize(.small)
                }
                if let url = viewModel.outputURL {
                    Text(url.path)
                        .font(.caption)
                        .lineLimit(2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Choose a destination before starting the upscale.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            HStack {
                Button(action: viewModel.startUpscale) {
                    Label("Upscale Video", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!viewModel.canStart)
                .help(viewModel.canStartFailureReason ?? "Upscale Video")

                Button(action: viewModel.cancelUpscale) {
                    Image(systemName: "stop.fill")
                }
                .controlSize(.large)
                .disabled({
                    if case .running = viewModel.state { return false } else { return true }
                }())
            }

            Text(viewModel.canStartFailureReason ?? "Ready to start processing.")
                .font(.caption)
                .foregroundStyle(viewModel.canStart ? Color.secondary : Color.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
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

    private var targetSelection: Binding<VideoResolution> {
        Binding(
            get: { viewModel.targetResolution },
            set: { viewModel.selectTargetForPendingJob($0) }
        )
    }

    private var codecSelection: Binding<OutputCodec> {
        Binding(
            get: { viewModel.codec },
            set: { viewModel.selectCodecForPendingJob($0) }
        )
    }

    private var modeSelection: Binding<UpscaleMode> {
        Binding(
            get: { viewModel.selectedMode },
            set: { viewModel.selectModeForPendingJob($0) }
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
}
