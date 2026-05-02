//___FILEHEADER___

import SwiftUI

#if canImport(ForsettiCore) && canImport(ForsettiHostTemplate) && canImport(ForsettiPlatform)
import ForsettiCore
import ForsettiHostTemplate
import ForsettiPlatform
#endif

struct ContentView: View {
    @StateObject private var bootstrap = ___PACKAGENAME:identifier___ForsettiBootstrap()

    var body: some View {
        #if canImport(ForsettiCore) && canImport(ForsettiHostTemplate) && canImport(ForsettiPlatform)
        Group {
            switch ___PACKAGENAME:identifier___DeploymentMode.current {
            case .development:
                ForsettiHostRootView(
                    controller: bootstrap.controller,
                    injectionRegistry: bootstrap.injectionRegistry,
                    showDeveloperControls: true,
                    launchActivationStrategy: .activateAllEligibleForDevelopment
                )
            case .production:
                ___PACKAGENAME:identifier___ProductionRootView(bootstrap: bootstrap)
            }
        }
        #else
        MissingForsettiProductsView()
        #endif
    }
}

#Preview {
    ContentView()
}

#if canImport(ForsettiCore) && canImport(ForsettiHostTemplate) && canImport(ForsettiPlatform)
private struct ___PACKAGENAME:identifier___ProductionRootView: View {
    @ObservedObject var bootstrap: ___PACKAGENAME:identifier___ForsettiBootstrap

    var body: some View {
        Group {
            switch bootstrap.productionState {
            case .idle, .booting:
                ProgressView()
            case .ready:
                ___PACKAGENAME:identifier___AppModuleView()
            case .failed:
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 32))
                        .foregroundStyle(.orange)
                    Text("Unable to start")
                        .font(.headline)
                    Text("Please try again later.")
                        .foregroundStyle(.secondary)
                }
                .padding(24)
            }
        }
        .task {
            await bootstrap.bootForProduction()
        }
    }
}
#endif

private struct MissingForsettiProductsView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "shippingbox")
                .font(.system(size: 40))
                .foregroundStyle(.blue)

            Text("Forsetti Starter Template Installed")
                .font(.title2.bold())

            Text("Add Forsetti package products to this app target to enable runtime bootstrapping.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Text("Required products: ForsettiCore, ForsettiPlatform, ForsettiHostTemplate")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(24)
    }
}
