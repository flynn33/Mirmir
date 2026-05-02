import Foundation

@MainActor
public final class ForsettiRuntime {
    public let platform: Platform
    public let forsettiVersion: SemVer

    public let eventBus: ForsettiEventBus
    public let uiSurfaceManager: UISurfaceManager
    public let moduleManager: ModuleManager
    public let router: any OverlayRouting

    private let entitlementProvider: any ForsettiEntitlementProvider
    private let logger: any ForsettiLogger
    private var entitlementObservationTask: Task<Void, Never>?

    public init(
        platform: Platform = .current,
        forsettiVersion: SemVer = ForsettiVersion.current,
        eventBus: ForsettiEventBus = InMemoryEventBus(),
        services: any ForsettiServiceProviding = ForsettiServiceContainer(),
        entitlementProvider: any ForsettiEntitlementProvider = AllowAllEntitlementProvider(),
        capabilityPolicy: any CapabilityPolicy = AllowAllCapabilityPolicy(),
        activationStore: any ActivationStore = UserDefaultsActivationStore(),
        logger: any ForsettiLogger = ConsoleForsettiLogger(),
        router: (any OverlayRouting)? = nil,
        moduleRegistry: ModuleRegistry = ModuleRegistry(),
        manifestLoader: ManifestLoader = ManifestLoader(),
        uiSurfaceManager: UISurfaceManager? = nil
    ) {
        self.platform = platform
        self.forsettiVersion = forsettiVersion
        self.eventBus = eventBus
        self.uiSurfaceManager = uiSurfaceManager ?? UISurfaceManager()
        self.entitlementProvider = entitlementProvider
        self.logger = logger
        self.router = router ?? NoopOverlayRouter()

        let compatibilityChecker = CompatibilityChecker(
            runtimePlatform: platform,
            forsettiVersion: forsettiVersion,
            capabilityPolicy: capabilityPolicy
        )

        let context = ForsettiContext(
            eventBus: eventBus,
            services: services,
            logger: logger,
            router: self.router
        )

        self.moduleManager = ModuleManager(
            manifestLoader: manifestLoader,
            moduleRegistry: moduleRegistry,
            compatibilityChecker: compatibilityChecker,
            activationStore: activationStore,
            entitlementProvider: entitlementProvider,
            uiSurfaceManager: self.uiSurfaceManager,
            context: context
        )
    }

    @discardableResult
    public func boot(
        bundle: Bundle,
        manifestsSubdirectory: String = "ForsettiManifests",
        restoreActivationState: Bool = true
    ) async throws -> [ModuleManifest] {
        let manifests = try moduleManager.discoverModules(bundle: bundle, subdirectory: manifestsSubdirectory)
        logger.log(.info, message: "Discovered \(manifests.count) module manifests")

        await entitlementProvider.refreshEntitlements()
        startEntitlementObservation()

        if restoreActivationState {
            await moduleManager.restorePersistedActivation()
        }

        return manifests
    }

    public func shutdown() {
        entitlementObservationTask?.cancel()
        entitlementObservationTask = nil
        moduleManager.deactivateAllModules(persistState: false)
    }

    public func openPointer(_ pointerID: String) {
        router.openPointer(pointerID)
    }

    public func openRoute(_ routeID: String) {
        router.openRoute(routeID)
    }

    private func startEntitlementObservation() {
        entitlementObservationTask?.cancel()
        let stream = entitlementProvider.entitlementsDidChangeStream()

        entitlementObservationTask = Task { [weak self] in
            guard let self else {
                return
            }

            for await _ in stream {
                await self.reconcileActiveModulesWithEntitlements()
            }
        }
    }

    private func reconcileActiveModulesWithEntitlements() async {
        let activeServiceIDs = moduleManager.enabledServiceModuleIDs
        let activeUIModuleIDs = moduleManager.enabledUIModuleIDs

        for moduleID in activeServiceIDs {
            guard let manifest = moduleManager.manifestsByID[moduleID] else {
                continue
            }
            let unlocked = await entitlementProvider.isUnlocked(moduleID: moduleID, productID: manifest.iapProductID)
            if !unlocked {
                do {
                    try moduleManager.deactivateModule(moduleID: moduleID)
                    logger.log(.warning, message: "Deactivated service module \(moduleID) after entitlement change")
                } catch {
                    logger.log(.error, message: "Failed to deactivate service module \(moduleID): \(error.localizedDescription)")
                }
            }
        }

        for moduleID in activeUIModuleIDs {
            guard let manifest = moduleManager.manifestsByID[moduleID] else {
                continue
            }

            let unlocked = await entitlementProvider.isUnlocked(moduleID: moduleID, productID: manifest.iapProductID)
            if !unlocked {
                do {
                    try moduleManager.deactivateModule(moduleID: moduleID)
                    logger.log(.warning, message: "Deactivated UI module \(moduleID) after entitlement change")
                } catch {
                    logger.log(.error, message: "Failed to deactivate UI module \(moduleID): \(error.localizedDescription)")
                }
            }
        }
    }
}
