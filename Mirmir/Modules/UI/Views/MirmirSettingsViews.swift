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

            Picker("Default Quality", selection: $viewModel.qualityMode) {
                ForEach(MirmirQualityMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Picker("Default Codec", selection: $viewModel.codec) {
                ForEach(OutputCodec.allCases) { codec in
                    Text(codec.rawValue.uppercased()).tag(codec)
                }
            }
            .pickerStyle(.segmented)

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

            Text("Runtime: Forsetti module host")
            Text("Upscaling: ASH deterministic backend")
            Text("Backend status: \(viewModel.ashBackendStatus.displayText)")
            Text("Model assets: \(String(describing: viewModel.modelStatus))")

            Spacer()
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

struct MirmirAboutView: View {
    @ObservedObject var viewModel: MirmirViewModel
    let showsTechnicalDetails: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Mirmir")
                .font(.title2.weight(.semibold))
            Text("Mirmir upscales supported video files from 720p to 1080p and 1080p to 4K.")
                .fixedSize(horizontal: false, vertical: true)

            if showsTechnicalDetails {
                Divider()
                Text("Technical Details")
                    .font(.headline)
                Text("Forsetti hosts the module runtime. ASH provides the deterministic upscaling backend.")
                Text(viewModel.ashBackendStatus.displayText)
            }

            Spacer()
        }
        .padding(20)
    }
}
