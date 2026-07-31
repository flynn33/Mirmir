import SwiftUI

struct ContentView: View {
    @ObservedObject var composition: MirmirAppComposition

    var body: some View {
        switch composition.state {
        case .ready(let bootstrap):
            appRoot(bootstrap: bootstrap)
        case .failed(let reason):
            MirmirStartupFailureView(
                reason: reason,
                retry: { composition.retry() }
            )
        }
    }

    @ViewBuilder
    private func appRoot(bootstrap: MirmirAppBootstrap) -> some View {
        switch MirmirDeploymentMode.current {
        case .development:
            MirmirDeveloperRootView(bootstrap: bootstrap)
        case .production:
            MirmirProductionRootView(bootstrap: bootstrap)
        }
    }
}
