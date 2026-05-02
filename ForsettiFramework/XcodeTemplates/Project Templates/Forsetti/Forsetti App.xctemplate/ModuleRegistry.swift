//___FILEHEADER___

#if canImport(ForsettiCore)
import ForsettiCore

enum ___PACKAGENAME:identifier___ModuleRegistry {
    static func registerAll(into registry: ModuleRegistry) {
        registry.register(entryPoint: ___PACKAGENAME:identifier___AppModule.Constants.entryPoint) {
            ___PACKAGENAME:identifier___AppModule()
        }
    }
}
#else
enum ___PACKAGENAME:identifier___ModuleRegistry {}
#endif
