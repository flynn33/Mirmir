import Foundation

public enum ModuleManagerError: Error, LocalizedError {
    case moduleNotDiscovered(String)
    case moduleNotActive(String)
    case moduleLocked(String)
    case incompatible(report: CompatibilityReport)
    case notUIModule(String)
    case moduleIdentityMismatch(moduleID: String, field: String, expected: String, actual: String)
    case missingCapability(moduleID: String, capability: Capability, usage: String)

    public var errorDescription: String? {
        switch self {
        case let .moduleNotDiscovered(moduleID):
            return "Module '\(moduleID)' has not been discovered."
        case let .moduleNotActive(moduleID):
            return "Module '\(moduleID)' is not active."
        case let .moduleLocked(moduleID):
            return "Module '\(moduleID)' is locked by entitlement rules."
        case let .incompatible(report):
            let details = report.issues.map(\.message).joined(separator: " | ")
            return "Module '\(report.moduleID)' is incompatible. \(details)"
        case let .notUIModule(moduleID):
            return "Module '\(moduleID)' is not a UI module."
        case let .moduleIdentityMismatch(moduleID, field, expected, actual):
            return "Module '\(moduleID)' identity mismatch for \(field). Expected '\(expected)', received '\(actual)'."
        case let .missingCapability(moduleID, capability, usage):
            return "Module '\(moduleID)' cannot use \(usage) without capability '\(capability.rawValue)'."
        }
    }
}

@MainActor
public final class ModuleManager {
    public private(set) var enabledServiceModuleIDs: Set<String>
    public private(set) var enabledUIModuleIDs: Set<String>
    // Represents the UI module currently selected for foreground presentation.
    public private(set) var activeUIModuleID: String?
    public private(set) var loadedModules: [String: ForsettiModule]
    public private(set) var manifestsByID: [String: ModuleManifest]

    private let manifestLoader: ManifestLoader
    private let moduleRegistry: ModuleRegistry
    private let compatibilityChecker: CompatibilityChecker
    private let activationStore: any ActivationStore
    private let entitlementProvider: any ForsettiEntitlementProvider
    private let uiSurfaceManager: UISurfaceManager
    private let context: ForsettiContext

    public init(
        manifestLoader: ManifestLoader,
        moduleRegistry: ModuleRegistry,
        compatibilityChecker: CompatibilityChecker,
        activationStore: any ActivationStore,
        entitlementProvider: any ForsettiEntitlementProvider,
        uiSurfaceManager: UISurfaceManager,
        context: ForsettiContext
    ) {
        self.manifestLoader = manifestLoader
        self.moduleRegistry = moduleRegistry
        self.compatibilityChecker = compatibilityChecker
        self.activationStore = activationStore
        self.entitlementProvider = entitlementProvider
        self.uiSurfaceManager = uiSurfaceManager
        self.context = context

        enabledServiceModuleIDs = []
        enabledUIModuleIDs = []
        activeUIModuleID = nil
        loadedModules = [:]
        manifestsByID = [:]
    }

    @discardableResult
    public func discoverModules(
        bundle: Bundle,
        subdirectory: String = "ForsettiManifests"
    ) throws -> [ModuleManifest] {
        manifestsByID = try manifestLoader.loadManifests(bundle: bundle, subdirectory: subdirectory)
        return manifestsByID.values.sorted { $0.moduleID < $1.moduleID }
    }

    public var discoveredManifests: [ModuleManifest] {
        manifestsByID.values.sorted { $0.moduleID < $1.moduleID }
    }

    public func uiContributions(for moduleID: String) -> UIContributions? {
        guard activeUIModuleID == moduleID,
              enabledUIModuleIDs.contains(moduleID),
              let uiModule = loadedModules[moduleID] as? ForsettiUIModule else {
            return nil
        }
        return sanitizedUIContributions(for: uiModule.uiContributions)
    }

    public func isActive(moduleID: String) -> Bool {
        enabledServiceModuleIDs.contains(moduleID) || enabledUIModuleIDs.contains(moduleID)
    }

    public func compatibilityReport(for moduleID: String) -> CompatibilityReport? {
        guard let manifest = manifestsByID[moduleID] else {
            return nil
        }
        return compatibilityChecker.evaluate(manifest: manifest)
    }

    public func activateModule(moduleID: String) async throws {
        guard let manifest = manifestsByID[moduleID] else {
            throw ModuleManagerError.moduleNotDiscovered(moduleID)
        }

        let report = compatibilityChecker.evaluate(manifest: manifest)
        if !report.isCompatible {
            throw ModuleManagerError.incompatible(report: report)
        }

        let unlocked = await entitlementProvider.isUnlocked(moduleID: moduleID, productID: manifest.iapProductID)
        guard unlocked else {
            throw ModuleManagerError.moduleLocked(moduleID)
        }

        switch manifest.moduleType {
        case .service:
            try activateServiceModule(manifest: manifest, moduleID: moduleID)
        case .ui, .app:
            try activateUIModule(manifest: manifest, moduleID: moduleID)
        }

        try persistState()
        context.logModule(.info, moduleID: moduleID, message: "Activated module")
    }

    public func deactivateModule(moduleID: String) throws {
        try deactivateModule(moduleID: moduleID, persistState: true)
    }

    public func setSelectedUIModule(moduleID: String?) throws {
        guard let moduleID else {
            if let activeUIModuleID {
                try deactivateModule(moduleID: activeUIModuleID, persistState: false)
            }
            try persistState()
            return
        }

        guard manifestsByID[moduleID] != nil else {
            throw ModuleManagerError.moduleNotDiscovered(moduleID)
        }
        guard enabledUIModuleIDs.contains(moduleID) else {
            throw ModuleManagerError.moduleNotActive(moduleID)
        }

        activeUIModuleID = moduleID
        try persistState()
    }

    private func deactivateModule(moduleID: String, persistState: Bool) throws {
        guard let manifest = manifestsByID[moduleID] else {
            throw ModuleManagerError.moduleNotDiscovered(moduleID)
        }

        if let module = loadedModules[moduleID] {
            module.stop(context: contextFor(manifest: manifest))
        }

        switch manifest.moduleType {
        case .service:
            enabledServiceModuleIDs.remove(moduleID)
        case .ui, .app:
            enabledUIModuleIDs.remove(moduleID)
            if activeUIModuleID == moduleID {
                activeUIModuleID = nil
            }
            uiSurfaceManager.remove(moduleID: moduleID)
        }

        loadedModules[moduleID] = nil

        if persistState {
            try self.persistState()
        }

        context.logModule(.info, moduleID: moduleID, message: "Deactivated module")
    }

    public func restorePersistedActivation() async {
        let storedState = activationStore.loadState()

        for moduleID in storedState.enabledServiceModuleIDs.sorted() {
            do {
                try await activateModule(moduleID: moduleID)
            } catch {
                context.logModule(
                    .warning,
                    moduleID: moduleID,
                    message: "Failed to restore service module",
                    metadata: ["reason": error.localizedDescription]
                )
            }
        }

        let desiredUIModuleID = storedState.selectedUIModuleID
            ?? storedState.enabledUIModuleIDs.sorted().first

        if let uiModuleID = desiredUIModuleID {
            do {
                try await activateModule(moduleID: uiModuleID)
            } catch {
                context.logModule(
                    .warning,
                    moduleID: uiModuleID,
                    message: "Failed to restore UI module",
                    metadata: ["reason": error.localizedDescription]
                )
            }
        }

        do {
            try persistState()
        } catch {
            context.reportModuleError(
                moduleID: "forsetti.runtime",
                message: "Failed to persist reconciled activation state",
                error: error
            )
        }
    }

    public func deactivateAllModules(persistState: Bool = true) {
        let activeModuleIDs = Set(loadedModules.keys)
        for moduleID in activeModuleIDs {
            do {
                try deactivateModule(moduleID: moduleID, persistState: false)
            } catch {
                context.reportModuleError(
                    moduleID: moduleID,
                    message: "Failed to deactivate module during bulk deactivation",
                    error: error
                )
            }
        }

        if persistState {
            try? self.persistState()
        }
    }

    private func resolveModule(for manifest: ModuleManifest) throws -> ForsettiModule {
        if let loadedModule = loadedModules[manifest.moduleID] {
            try validateResolvedModule(loadedModule, against: manifest)
            return loadedModule
        }

        let module = try moduleRegistry.makeModule(entryPoint: manifest.entryPoint)
        try validateResolvedModule(module, against: manifest)
        loadedModules[manifest.moduleID] = module
        return module
    }

    private func activateServiceModule(manifest: ModuleManifest, moduleID: String) throws {
        guard !enabledServiceModuleIDs.contains(moduleID) else {
            return
        }

        let module = try resolveModule(for: manifest)
        let moduleContext = contextFor(manifest: manifest)
        do {
            try module.start(context: moduleContext)
        } catch {
            loadedModules[moduleID] = nil
            context.reportModuleError(
                moduleID: moduleID,
                message: "Module failed to start",
                error: error,
                metadata: ["moduleType": manifest.moduleType.rawValue]
            )
            throw error
        }

        enabledServiceModuleIDs.insert(moduleID)
    }

    private func activateUIModule(manifest: ModuleManifest, moduleID: String) throws {
        if activeUIModuleID == moduleID, enabledUIModuleIDs.contains(moduleID) {
            return
        }

        let module = try resolveModule(for: manifest)
        guard let uiModule = module as? ForsettiUIModule else {
            loadedModules[moduleID] = nil
            throw ModuleManagerError.notUIModule(moduleID)
        }

        try validateUIContributions(uiModule.uiContributions, manifest: manifest)

        if let activeUIModuleID, activeUIModuleID != moduleID {
            try deactivateModule(moduleID: activeUIModuleID, persistState: false)
        }

        let moduleContext = contextFor(manifest: manifest)
        do {
            try module.start(context: moduleContext)
        } catch {
            loadedModules[moduleID] = nil
            context.reportModuleError(
                moduleID: moduleID,
                message: "Module failed to start",
                error: error,
                metadata: ["moduleType": manifest.moduleType.rawValue]
            )
            throw error
        }

        enabledUIModuleIDs.removeAll()
        enabledUIModuleIDs.insert(moduleID)
        activeUIModuleID = moduleID
        uiSurfaceManager.clear()
        uiSurfaceManager.apply(
            moduleID: moduleID,
            contributions: sanitizedUIContributions(for: uiModule.uiContributions)
        )
    }

    private func persistState() throws {
        let state = ActivationState(
            enabledServiceModuleIDs: enabledServiceModuleIDs,
            enabledUIModuleIDs: enabledUIModuleIDs,
            selectedUIModuleID: activeUIModuleID
        )
        try activationStore.saveState(state)
    }

    private func sanitizedUIContributions(for source: UIContributions) -> UIContributions {
        UIContributions(
            themeMask: nil,
            toolbarItems: source.toolbarItems,
            viewInjections: source.viewInjections,
            overlaySchema: source.overlaySchema
        )
    }

    private func contextFor(manifest: ModuleManifest) -> ForsettiContext {
        context.scopedToModule(
            moduleID: manifest.moduleID,
            grantedCapabilities: Set(manifest.capabilitiesRequested)
        )
    }

    private func validateResolvedModule(_ module: ForsettiModule, against manifest: ModuleManifest) throws {
        try validateIdentity(
            moduleID: manifest.moduleID,
            field: "descriptor.moduleID",
            expected: manifest.moduleID,
            actual: module.descriptor.moduleID
        )
        try validateIdentity(
            moduleID: manifest.moduleID,
            field: "descriptor.moduleType",
            expected: manifest.moduleType.rawValue,
            actual: module.descriptor.moduleType.rawValue
        )
        try validateIdentity(
            moduleID: manifest.moduleID,
            field: "descriptor.moduleVersion",
            expected: manifest.moduleVersion.description,
            actual: module.descriptor.moduleVersion.description
        )
        try validateIdentity(
            moduleID: manifest.moduleID,
            field: "manifest.moduleID",
            expected: manifest.moduleID,
            actual: module.manifest.moduleID
        )
        try validateIdentity(
            moduleID: manifest.moduleID,
            field: "manifest.moduleType",
            expected: manifest.moduleType.rawValue,
            actual: module.manifest.moduleType.rawValue
        )
        try validateIdentity(
            moduleID: manifest.moduleID,
            field: "manifest.entryPoint",
            expected: manifest.entryPoint,
            actual: module.manifest.entryPoint
        )
        try validateIdentity(
            moduleID: manifest.moduleID,
            field: "manifest.moduleVersion",
            expected: manifest.moduleVersion.description,
            actual: module.manifest.moduleVersion.description
        )
    }

    private func validateIdentity(moduleID: String, field: String, expected: String, actual: String) throws {
        guard expected == actual else {
            throw ModuleManagerError.moduleIdentityMismatch(
                moduleID: moduleID,
                field: field,
                expected: expected,
                actual: actual
            )
        }
    }

    private func validateUIContributions(_ contributions: UIContributions, manifest: ModuleManifest) throws {
        let capabilities = Set(manifest.capabilitiesRequested)

        try requireCapability(
            .toolbarItems,
            for: manifest,
            usage: "toolbar item contributions",
            when: !contributions.toolbarItems.isEmpty,
            grantedCapabilities: capabilities
        )
        try requireCapability(
            .viewInjection,
            for: manifest,
            usage: "view injection contributions",
            when: !contributions.viewInjections.isEmpty,
            grantedCapabilities: capabilities
        )
        try requireCapability(
            .routingOverlay,
            for: manifest,
            usage: "routing overlay contributions",
            when: contributions.overlaySchema != nil,
            grantedCapabilities: capabilities
        )
        try requireCapability(
            .uiThemeMask,
            for: manifest,
            usage: "theme mask contributions",
            when: contributions.themeMask != nil,
            grantedCapabilities: capabilities
        )
    }

    private func requireCapability(
        _ capability: Capability,
        for manifest: ModuleManifest,
        usage: String,
        when condition: Bool,
        grantedCapabilities: Set<Capability>
    ) throws {
        guard condition, !grantedCapabilities.contains(capability) else {
            return
        }

        throw ModuleManagerError.missingCapability(
            moduleID: manifest.moduleID,
            capability: capability,
            usage: usage
        )
    }
}
