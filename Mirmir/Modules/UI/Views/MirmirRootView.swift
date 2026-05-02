import SwiftUI

struct MirmirRootView: View {

    @ObservedObject var viewModel: MirmirViewModel

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(modelStatus: viewModel.modelStatus, onStage: viewModel.ensureModelsReady)

            Divider()

            HStack(spacing: 0) {
                VideoSelectionView(viewModel: viewModel)
                    .frame(minWidth: 280, idealWidth: 320, maxWidth: 380)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)

                Divider()

                UpscaleControlsView(viewModel: viewModel)
                    .frame(minWidth: 280, idealWidth: 320, maxWidth: 380)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)

                Divider()

                PreviewView(viewModel: viewModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()

            ProgressPanelView(viewModel: viewModel)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
    }
}

private struct HeaderBar: View {
    let modelStatus: ModelAssetsStatus
    let onStage: () -> Void

    var body: some View {
        HStack {
            Text("Mirmir")
                .font(.title2).bold()
            Spacer()
            HStack(spacing: 6) {
                statusDot
                Text(statusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if needsStaging {
                    Button("Stage Models", action: onStage)
                        .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var needsStaging: Bool {
        switch modelStatus {
        case .downloadRequired, .unknown, .failed: return true
        default: return false
        }
    }

    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 8, height: 8)
    }

    private var statusColor: Color {
        switch modelStatus {
        case .ready: return .green
        case .downloading: return .yellow
        case .failed: return .red
        case .downloadRequired, .unknown: return .secondary
        }
    }

    private var statusText: String {
        switch modelStatus {
        case .ready: return "Models: Ready"
        case .downloading(let progress): return "Models: Downloading \(Int(progress * 100))%"
        case .downloadRequired: return "Models: Required"
        case .unknown: return "Models: Unknown"
        case .failed(let reason): return "Models: Failed (\(reason))"
        }
    }
}
