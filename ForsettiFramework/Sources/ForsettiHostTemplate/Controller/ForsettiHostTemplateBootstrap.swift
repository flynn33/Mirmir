import Foundation
import ForsettiCore
import ForsettiPlatform

@MainActor
public enum ForsettiHostTemplateBootstrap {
    public static func makeController(
        manifestsBundle: Bundle,
        moduleRegistry: ModuleRegistry,
        entitlementProvider: any ForsettiEntitlementProvider = ForsettiEntitlementProviderFactory.makeDefault(),
        capabilityPolicy: any CapabilityPolicy = AllowAllCapabilityPolicy(),
        activationStore: any ActivationStore = UserDefaultsActivationStore(),
        logger: any ForsettiLogger = OSLogForsettiLogger(),
        router: (any OverlayRouting)? = nil,
        manifestsSubdirectory: String = "ForsettiManifests",
        slotCatalog: [String] = SlotCatalog.all
    ) -> ForsettiHostController {
        let platformServices = DefaultForsettiPlatformServices()
        let uiSurfaceManager = UISurfaceManager()
        let resolvedRouter = router ?? ForsettiHostOverlayRouter(
            uiSurfaceManager: uiSurfaceManager,
            baseDestinationIDs: BaseDestinationCatalog.all,
            slotIDs: slotCatalog
        )

        let runtime = ForsettiRuntime(
            services: platformServices.container,
            entitlementProvider: entitlementProvider,
            capabilityPolicy: capabilityPolicy,
            activationStore: activationStore,
            logger: logger,
            router: resolvedRouter,
            moduleRegistry: moduleRegistry,
            uiSurfaceManager: uiSurfaceManager
        )

        return ForsettiHostController(
            runtime: runtime,
            entitlementProvider: entitlementProvider,
            manifestsBundle: manifestsBundle,
            manifestsSubdirectory: manifestsSubdirectory,
            slotCatalog: slotCatalog
        )
    }
}
