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
                MirmirStartupFailureView(
                    reason: reason,
                    retry: { bootstrap.retryProductionBoot() }
                )
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

    private var readyView: some View {
        Group {
            if let view = bootstrap.viewRegistry.resolve(viewID: MirmirUIConstants.primaryViewID) {
                view
            } else {
                MirmirStartupFailureView(
                    reason:
                        "UI view \(MirmirUIConstants.primaryViewID) "
                        + "is not registered",
                    retry: { bootstrap.retryProductionBoot() }
                )
            }
        }
    }
}

struct MirmirStartupFailureView: View {
    let reason: String
    let retry: () -> Void

    var body: some View {
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

            HStack(spacing: 12) {
                Button(action: retry) {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)

                SettingsLink {
                    Label(
                        "Open Diagnostic Log Settings",
                        systemImage: "doc.text.magnifyingglass"
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
