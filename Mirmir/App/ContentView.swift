import SwiftUI

struct ContentView: View {
    @StateObject private var bootstrap = MirmirAppBootstrap()

    var body: some View {
        switch MirmirDeploymentMode.current {
        case .development:
            MirmirDeveloperRootView(bootstrap: bootstrap)
        case .production:
            MirmirProductionRootView(bootstrap: bootstrap)
        }
    }
}
