import SwiftUI
import ForsettiHostTemplate

struct ContentView: View {
    @StateObject private var bootstrap = MirmirForsettiBootstrap()

    var body: some View {
        Group {
            switch MirmirDeploymentMode.current {
            case .development:
                ForsettiHostRootView(
                    controller: bootstrap.controller,
                    injectionRegistry: bootstrap.injectionRegistry,
                    showDeveloperControls: true,
                    launchActivationStrategy: .activateAllEligibleForDevelopment
                )
            case .production:
                MirmirProductionRootView(bootstrap: bootstrap)
            }
        }
    }
}
