import SwiftUI

struct MirmirRootView: View {

    @ObservedObject var viewModel: MirmirViewModel

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar()

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
    var body: some View {
        HStack {
            Text("Mirmir")
                .font(.title2).bold()
            Spacer()
            HStack(spacing: 6) {
                statusDot
                Text("ASH Backend: Ready")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var statusDot: some View {
        Circle()
            .fill(.green)
            .frame(width: 8, height: 8)
    }
}
