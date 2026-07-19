import SwiftUI

struct MirmirProductionRootView: View {
    @ObservedObject var bootstrap: MirmirAppBootstrap

    var body: some View {
        Group {
            switch bootstrap.productionState {
            case .idle, .booting:
                bootingView
                    .task { bootstrap.bootForProduction() }
            case .ready:
                readyView
            case .failed(let reason):
                failureView(reason)
            }
        }
    }

    private var bootingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Starting Mirmir…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failureView(_ reason: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.octagon.fill")
                .font(.system(size: 48))
                .foregroundStyle(.red)
            Text("Mirmir failed to start")
                .font(.title3)
                .bold()
            Text(reason)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var readyView: some View {
        Group {
            if let view = bootstrap.viewRegistry.resolve(viewID: MirmirUIConstants.primaryViewID) {
                view
            } else {
                failureView("UI view \(MirmirUIConstants.primaryViewID) is not registered")
            }
        }
    }
}
