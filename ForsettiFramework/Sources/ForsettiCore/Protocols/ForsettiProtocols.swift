import Foundation

public protocol ForsettiModule: AnyObject {
    var descriptor: ModuleDescriptor { get }
    var manifest: ModuleManifest { get }

    func start(context: ForsettiContext) throws
    func stop(context: ForsettiContext)
}

public protocol ForsettiUIModule: ForsettiModule {
    var uiContributions: UIContributions { get }
}

/// A complete single-application module that includes its own UI.
/// Use `ForsettiAppModule` for simple applications where the entire app
/// (UI + logic) lives in one module. The framework runs silently in
/// the background and end users interact only with the module's UI.
///
/// For larger applications, use `ForsettiUIModule` for the UI module
/// and separate `ForsettiModule` conformances for each feature module.
public protocol ForsettiAppModule: ForsettiUIModule {}

public protocol ForsettiEntitlementProvider: Sendable {
    func isUnlocked(moduleID: String, productID: String?) async -> Bool
    func refreshEntitlements() async
    func entitlementsDidChangeStream() -> AsyncStream<Void>
    func restorePurchases() async throws
}

public extension ForsettiEntitlementProvider {
    func restorePurchases() async throws {}
}
