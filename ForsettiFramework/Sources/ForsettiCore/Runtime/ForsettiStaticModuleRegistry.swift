import Foundation

public enum ForsettiStaticModuleRegistry {
    /// v1 static registration hook. Host apps call this and register each bundled module factory.
    public static func buildRegistry(configure: (ModuleRegistry) -> Void) -> ModuleRegistry {
        let registry = ModuleRegistry()
        configure(registry)
        return registry
    }
}
