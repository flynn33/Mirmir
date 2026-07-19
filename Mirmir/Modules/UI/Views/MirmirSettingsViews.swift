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

            Picker("Default Quality", selection: Binding.constant(MirmirQualityMode.balanced)) {
                ForEach(MirmirQualityMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .disabled(true)
            .help("Additional processing profiles are not implemented yet.")
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

            Text("Runtime: Mirmir module runtime")
            Text("Upscaling: \(viewModel.engineSelectionText)")
            Text("Processing status: \(viewModel.engineReadinessText)")
            if let reason = viewModel.engineAvailabilityReason {
                Text(reason)
            }
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
            Text("Mirmir is preparing a roadmap-qualified video-enhancement pipeline for supported media.")
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
