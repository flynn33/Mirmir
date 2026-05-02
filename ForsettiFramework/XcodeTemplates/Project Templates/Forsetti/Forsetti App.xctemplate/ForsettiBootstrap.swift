//___FILEHEADER___

#if canImport(ForsettiCore) && canImport(ForsettiHostTemplate) && canImport(ForsettiPlatform)
import Foundation
import SwiftUI
import ForsettiCore
import ForsettiHostTemplate
import ForsettiPlatform

enum ___PACKAGENAME:identifier___ProductionBootState: Equatable {
    case idle
    case booting
    case ready
    case failed(String)
}

@MainActor
final class ___PACKAGENAME:identifier___ForsettiBootstrap: ObservableObject {
    let controller: ForsettiHostController
    let injectionRegistry: ForsettiViewInjectionRegistry
    @Published private(set) var productionState: ___PACKAGENAME:identifier___ProductionBootState = .idle

    init() {
        // Previous template behavior used ExampleModuleRegistry from ForsettiModulesExample.
        // New template behavior registers an app-owned starter module by default.
        let registry = ModuleRegistry()
        ___PACKAGENAME:identifier___ModuleRegistry.registerAll(into: registry)

        controller = ForsettiHostTemplateBootstrap.makeController(
            manifestsBundle: .main,
            moduleRegistry: registry,
            entitlementProvider: ForsettiEntitlementProviderFactory.makeDefault(),
            manifestsSubdirectory: "ForsettiManifests"
        )

        // View injection maps the starter module's workspace view ID to the app-owned SwiftUI view.
        injectionRegistry = ForsettiViewInjectionRegistry()
        injectionRegistry.register(viewID: ___PACKAGENAME:identifier___AppModule.Constants.primaryViewID) {
            ___PACKAGENAME:identifier___AppModuleView()
        }
    }

    func bootForProduction() async {
        guard productionState != .ready, productionState != .booting else {
            return
        }

        productionState = .booting
        await controller.bootIfNeeded(
            activationStrategy: .activate(moduleIDs: [___PACKAGENAME:identifier___AppModule.Constants.moduleID])
        )

        if controller.activeUIModuleID == ___PACKAGENAME:identifier___AppModule.Constants.moduleID {
            productionState = .ready
            return
        }

        productionState = .failed(controller.errorMessage ?? "Activation failed.")
    }
}
#else
import Foundation
import SwiftUI

@MainActor
final class ___PACKAGENAME:identifier___ForsettiBootstrap: ObservableObject {
    enum ProductionBootState {
        case idle
    }

    let productionState = ProductionBootState.idle

    func bootForProduction() async {}
}
#endif
