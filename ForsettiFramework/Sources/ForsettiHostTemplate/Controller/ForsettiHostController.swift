import Combine
import Foundation
import ForsettiCore

public enum ForsettiLaunchActivationStrategy: Sendable, Equatable {
    case restoreOnly
    case activateAllEligibleForDevelopment
    case activate(moduleIDs: Set<String>)
}

@MainActor
public final class ForsettiHostController: ObservableObject {
    @Published public private(set) var serviceModules: [ForsettiHostModuleItem] = []
    @Published public private(set) var uiModules: [ForsettiHostModuleItem] = []
    @Published public private(set) var enabledServiceModuleIDs: Set<String> = []
    @Published public private(set) var enabledUIModuleIDs: Set<String> = []
    @Published public private(set) var activeUIModuleID: String?
    @Published public var selectedModuleID: String?
    @Published public private(set) var isBooted = false
    @Published public private(set) var isBusy = false
    @Published public private(set) var lastToolbarActionDescription: String?
    @Published public var errorMessage: String?

    public let runtime: ForsettiRuntime
    public let manifestsBundle: Bundle
    public let manifestsSubdirectory: String
    public let slotCatalog: [String]

    private let entitlementProvider: any ForsettiEntitlementProvider
    private var entitlementObservationTask: Task<Void, Never>?

    public init(
        runtime: ForsettiRuntime,
        entitlementProvider: any ForsettiEntitlementProvider,
        manifestsBundle: Bundle,
        manifestsSubdirectory: String = "ForsettiManifests",
        slotCatalog: [String] = SlotCatalog.all
    ) {
        self.runtime = runtime
        self.entitlementProvider = entitlementProvider
        self.manifestsBundle = manifestsBundle
        self.manifestsSubdirectory = manifestsSubdirectory
        self.slotCatalog = slotCatalog
    }

    public func bootIfNeeded(
        restoreActivationState: Bool = true,
        activationStrategy: ForsettiLaunchActivationStrategy = .restoreOnly
    ) async {
        guard !isBooted else {
            await refreshModuleState()
            return
        }

        await boot(
            restoreActivationState: restoreActivationState,
            activationStrategy: activationStrategy
        )
    }

    public func boot(
        restoreActivationState: Bool = true,
        activationStrategy: ForsettiLaunchActivationStrategy = .restoreOnly
    ) async {
        isBusy = true
        defer { isBusy = false }

        do {
            _ = try await runtime.boot(
                bundle: manifestsBundle,
                manifestsSubdirectory: manifestsSubdirectory,
                restoreActivationState: restoreActivationState
            )

            await applyLaunchActivationStrategy(activationStrategy)

            isBooted = true
            startEntitlementObservation()
            await refreshModuleState()
        } catch {
            present(error: error)
        }
    }

    @available(*, deprecated, message: "Use boot(restoreActivationState:activationStrategy:) with an explicit launch activation strategy.")
    public func boot(
        restoreActivationState: Bool,
        activateAllEligibleModules: Bool
    ) async {
        await boot(
            restoreActivationState: restoreActivationState,
            activationStrategy: activateAllEligibleModules ? .activateAllEligibleForDevelopment : .restoreOnly
        )
    }

    public func shutdown() {
        entitlementObservationTask?.cancel()
        entitlementObservationTask = nil
        runtime.shutdown()

        serviceModules = []
        uiModules = []
        enabledServiceModuleIDs = []
        enabledUIModuleIDs = []
        activeUIModuleID = nil
        selectedModuleID = nil
        isBooted = false
    }

    public func refreshModuleState() async {
        let discovered = runtime.moduleManager.discoveredManifests
        var nextItems: [ForsettiHostModuleItem] = []
        nextItems.reserveCapacity(discovered.count)

        for manifest in discovered {
            let compatibility = runtime.moduleManager.compatibilityReport(for: manifest.moduleID)
                ?? CompatibilityReport(
                    moduleID: manifest.moduleID,
                    issues: [
                        CompatibilityIssue(
                            code: .invalidSchemaVersion,
                            severity: .error,
                            message: "Module was discovered but no compatibility report is available."
                        )
                    ]
                )

            let isUnlocked = await entitlementProvider.isUnlocked(
                moduleID: manifest.moduleID,
                productID: manifest.iapProductID
            )

            let item = ForsettiHostModuleItem(
                manifest: manifest,
                compatibilityReport: compatibility,
                isUnlocked: isUnlocked,
                isActive: runtime.moduleManager.isActive(moduleID: manifest.moduleID)
            )
            nextItems.append(item)
        }

        nextItems.sort { lhs, rhs in
            lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }

        serviceModules = nextItems.filter { $0.moduleType == .service }
        uiModules = nextItems.filter { $0.moduleType == .ui || $0.moduleType == .app }
        enabledServiceModuleIDs = runtime.moduleManager.enabledServiceModuleIDs
        enabledUIModuleIDs = runtime.moduleManager.enabledUIModuleIDs
        activeUIModuleID = runtime.moduleManager.activeUIModuleID

        if let selectedModuleID,
           !nextItems.contains(where: { $0.moduleID == selectedModuleID }) {
            self.selectedModuleID = nil
        }

        if let selectedModuleID,
           !runtime.moduleManager.isActive(moduleID: selectedModuleID) {
            self.selectedModuleID = nil
        }
    }

    public func setServiceModuleEnabled(moduleID: String, isEnabled: Bool) async {
        isBusy = true
        defer { isBusy = false }

        do {
            if isEnabled {
                try await runtime.moduleManager.activateModule(moduleID: moduleID)
            } else {
                try runtime.moduleManager.deactivateModule(moduleID: moduleID)
                if selectedModuleID == moduleID {
                    selectedModuleID = nil
                }
            }
        } catch {
            present(error: error)
        }

        await refreshModuleState()
    }

    public func setUIModuleEnabled(moduleID: String, isEnabled: Bool) async {
        isBusy = true
        defer { isBusy = false }

        do {
            if isEnabled {
                try await runtime.moduleManager.activateModule(moduleID: moduleID)
                try runtime.moduleManager.setSelectedUIModule(moduleID: moduleID)
            } else {
                try runtime.moduleManager.deactivateModule(moduleID: moduleID)
                if selectedModuleID == moduleID {
                    selectedModuleID = nil
                }
            }
        } catch {
            present(error: error)
        }

        await refreshModuleState()
    }

    public func selectUIModule(moduleID: String?) async {
        if let moduleID {
            await setUIModuleEnabled(moduleID: moduleID, isEnabled: true)
            selectedModuleID = moduleID
            return
        }

        goHome()

        do {
            try runtime.moduleManager.setSelectedUIModule(moduleID: nil)
            await refreshModuleState()
        } catch {
            present(error: error)
        }
    }

    public func openModule(moduleID: String) async {
        isBusy = true
        defer { isBusy = false }

        do {
            if !runtime.moduleManager.isActive(moduleID: moduleID) {
                try await runtime.moduleManager.activateModule(moduleID: moduleID)
            }

            if let manifest = runtime.moduleManager.manifestsByID[moduleID],
               manifest.moduleType == .ui || manifest.moduleType == .app {
                try runtime.moduleManager.setSelectedUIModule(moduleID: moduleID)
            }

            selectedModuleID = moduleID
        } catch {
            present(error: error)
        }

        await refreshModuleState()
    }

    public func goHome() {
        selectedModuleID = nil
    }

    public func refreshEntitlements() async {
        await entitlementProvider.refreshEntitlements()
        await refreshModuleState()
    }

    public func restorePurchases() async {
        isBusy = true
        defer { isBusy = false }

        do {
            try await entitlementProvider.restorePurchases()
            await refreshModuleState()
        } catch {
            present(error: error)
        }
    }

    public func uiContributions(for moduleID: String) -> UIContributions? {
        runtime.moduleManager.uiContributions(for: moduleID)
    }

    public func selectedModuleItem() -> ForsettiHostModuleItem? {
        guard let selectedModuleID else {
            return nil
        }
        return (serviceModules + uiModules).first(where: { $0.moduleID == selectedModuleID })
    }

    public func handleToolbarAction(_ action: ToolbarAction) {
        switch action {
        case let .navigate(pointerID):
            runtime.openPointer(pointerID)
            if let hostRouter = runtime.router as? ForsettiHostOverlayRouter,
               let outcome = hostRouter.lastOutcome {
                lastToolbarActionDescription = outcome.message
            } else {
                lastToolbarActionDescription = "Navigate pointer: \(pointerID)"
            }
        case let .openOverlay(routeID):
            runtime.openRoute(routeID)
            if let hostRouter = runtime.router as? ForsettiHostOverlayRouter,
               let outcome = hostRouter.lastOutcome {
                lastToolbarActionDescription = outcome.message
            } else {
                lastToolbarActionDescription = "Open overlay route: \(routeID)"
            }
        case let .publishEvent(type, payload):
            runtime.eventBus.publish(
                event: ForsettiEvent(
                    type: type,
                    payload: payload ?? [:],
                    sourceModuleID: selectedModuleID ?? activeUIModuleID
                )
            )
            lastToolbarActionDescription = "Published event: \(type)"
        }
    }

    public func clearError() {
        errorMessage = nil
    }

    private func startEntitlementObservation() {
        entitlementObservationTask?.cancel()
        let stream = entitlementProvider.entitlementsDidChangeStream()

        entitlementObservationTask = Task { [weak self] in
            guard let self else {
                return
            }

            for await _ in stream {
                await self.refreshModuleState()
            }
        }
    }

    private func activateEligibleModulesOnLaunch() async {
        let manifests = runtime.moduleManager.discoveredManifests

        for manifest in manifests {
            guard runtime.moduleManager.compatibilityReport(for: manifest.moduleID)?.isCompatible == true else {
                continue
            }

            let unlocked = await entitlementProvider.isUnlocked(
                moduleID: manifest.moduleID,
                productID: manifest.iapProductID
            )
            guard unlocked else {
                continue
            }

            guard !runtime.moduleManager.isActive(moduleID: manifest.moduleID) else {
                continue
            }

            do {
                try await runtime.moduleManager.activateModule(moduleID: manifest.moduleID)
            } catch {
                present(error: error)
            }
        }
    }

    private func applyLaunchActivationStrategy(_ strategy: ForsettiLaunchActivationStrategy) async {
        switch strategy {
        case .restoreOnly:
            return
        case .activateAllEligibleForDevelopment:
            await activateEligibleModulesOnLaunch()
        case let .activate(moduleIDs):
            for moduleID in moduleIDs.sorted() {
                do {
                    try await runtime.moduleManager.activateModule(moduleID: moduleID)
                    if let manifest = runtime.moduleManager.manifestsByID[moduleID],
                       manifest.moduleType == .ui || manifest.moduleType == .app {
                        try runtime.moduleManager.setSelectedUIModule(moduleID: moduleID)
                    }
                } catch {
                    present(error: error)
                }
            }
        }
    }

    private func present(error: Error) {
        errorMessage = error.localizedDescription
    }
}
