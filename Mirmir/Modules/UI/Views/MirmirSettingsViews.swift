import SwiftUI

struct MirmirSettingsView: View {
    @ObservedObject var viewModel: MirmirViewModel

    var body: some View {
        TabView {
            generalSettings
                .tabItem { Text("General") }

            MirmirAboutView(viewModel: viewModel, showsTechnicalDetails: false)
                .tabItem { Text("About Mirmir") }

            technicalDetails
                .tabItem { Text("Technical Details") }
        }
        .padding(20)
    }

    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("General")
                .font(.title3.weight(.semibold))

            Picker("Default Mode", selection: $viewModel.selectedMode) {
                ForEach(UpscaleMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .help(viewModel.selectedModeSummary)
            .pickerStyle(.segmented)

            Picker("Default Codec", selection: $viewModel.codec) {
                ForEach(OutputCodec.allCases) { codec in
                    Text(codec.rawValue.uppercased()).tag(codec)
                }
            }
            .pickerStyle(.segmented)

            MirmirCacheLocationSettings(viewModel: viewModel)

            Text(viewModel.engineReadinessText)
                .font(.callout)
                .foregroundStyle(.secondary)

            Spacer()
        }
    }

    private var technicalDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Technical Details")
                .font(.title3.weight(.semibold))

            Text("Runtime: Mirmir module runtime")
            Text("Upscaling: \(viewModel.engineSelectionText)")
            Text("Processing status: \(viewModel.engineReadinessText)")
            if let reason = viewModel.engineAvailabilityReason {
                Text(reason)
            }
            Text("Model assets: \(viewModel.modelAssetsStatusText)")
            Text(viewModel.modelAssetsDetailText)
            Text(viewModel.modelSpecializationText)

            Spacer()
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

struct MirmirCacheLocationSettings: View {
    @ObservedObject var viewModel: MirmirViewModel
    var showsTitle = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsTitle {
                Text("Cache Location")
                    .font(.headline)
            }
            Text(viewModel.cacheLocationPath)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)

            if viewModel.cacheLocationIsConfigurable {
                HStack {
                    Button("Choose…") {
                        viewModel.chooseCacheLocation()
                    }
                    if viewModel.cacheLocationIsCustom {
                        Button("Use Internal Storage") {
                            viewModel.useDefaultCacheLocation()
                        }
                    }
                }
                .disabled(!viewModel.canChangeCacheLocation)
            }

            if let message = viewModel.cacheLocationStatusMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(
                "Choose any writable folder on an internal disk, "
                    + "external drive, or mounted network share."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

struct MirmirAboutView: View {
    @ObservedObject var viewModel: MirmirViewModel
    let showsTechnicalDetails: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Mirmir")
                .font(.title2.weight(.semibold))
            Text("Mirmir upscales supported 720p and 1080p SDR video with its qualified Apple MPS Lanczos path and verifies completed output before publication.")
                .fixedSize(horizontal: false, vertical: true)

            if let reason = viewModel.engineAvailabilityReason {
                Text(reason)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if showsTechnicalDetails {
                Divider()
                Text("Technical Details")
                    .font(.headline)
                Text("The Mirmir module runtime owns application composition.")
                Text("ASH remains a directly testable reference and research implementation.")
                Text(viewModel.engineReadinessText)
            }

            Spacer()
        }
        .padding(20)
    }
}
