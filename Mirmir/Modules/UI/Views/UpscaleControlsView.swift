import SwiftUI

struct UpscaleControlsView: View {

    @ObservedObject var viewModel: MirmirViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Settings")
                .font(.headline)

            if viewModel.availableTargets.isEmpty {
                Text("Select a 720p or 1080p source first.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Target resolution", selection: $viewModel.targetResolution) {
                    ForEach(viewModel.availableTargets, id: \.self) { resolution in
                        Text(String(describing: resolution)).tag(resolution)
                    }
                }
                .pickerStyle(.menu)
            }

            Picker("Codec", selection: $viewModel.codec) {
                ForEach(OutputCodec.allCases) { codec in
                    Text(codec.rawValue.uppercased()).tag(codec)
                }
            }
            .pickerStyle(.segmented)

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

                Button(action: viewModel.cancelUpscale) {
                    Image(systemName: "stop.fill")
                }
                .controlSize(.large)
                .disabled({
                    if case .running = viewModel.state { return false } else { return true }
                }())
            }
        }
    }
}
