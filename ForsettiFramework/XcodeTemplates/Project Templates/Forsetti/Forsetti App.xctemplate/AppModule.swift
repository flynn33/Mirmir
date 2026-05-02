//___FILEHEADER___

#if canImport(ForsettiCore)
import Foundation
import ForsettiCore

final class ___PACKAGENAME:identifier___AppModule: ForsettiAppModule {
    enum Constants {
        static let moduleID = "com.yourcompany.___PACKAGENAME:identifier___.app-module"
        static let entryPoint = "___PACKAGENAME:identifier___AppModule"
        static let primaryViewID = "___PACKAGENAME:identifier___.app-module.workspace-root"
    }

    let descriptor = ModuleDescriptor(
        moduleID: Constants.moduleID,
        displayName: "___PACKAGENAME___ App Module",
        moduleVersion: SemVer(major: 1, minor: 0, patch: 0),
        moduleType: .app
    )

    let manifest = ModuleManifest(
        schemaVersion: ModuleManifest.supportedSchemaVersion,
        moduleID: Constants.moduleID,
        displayName: "___PACKAGENAME___ App Module",
        moduleVersion: SemVer(major: 1, minor: 0, patch: 0),
        moduleType: .app,
        supportedPlatforms: [.iOS, .macOS],
        minForsettiVersion: SemVer(major: 0, minor: 1, patch: 0),
        capabilitiesRequested: [.telemetry, .viewInjection],
        iapProductID: nil,
        entryPoint: Constants.entryPoint
    )

    let uiContributions = UIContributions(
        viewInjections: [
            ViewInjectionDescriptor(
                injectionID: "___PACKAGENAME:identifier___.app-module.workspace-root",
                slot: "module.workspace",
                viewID: Constants.primaryViewID,
                priority: 100
            )
        ]
    )

    private var isStarted = false

    init() {}

    func start(context: ForsettiContext) throws {
        guard !isStarted else {
            return
        }

        isStarted = true
        context.moduleLogger(moduleID: descriptor.moduleID).info("Starter app module started")

        if let telemetry = context.services.resolve(TelemetryService.self) {
            telemetry.track(
                event: "app_module_started",
                properties: ["moduleID": descriptor.moduleID]
            )
        }
    }

    func stop(context: ForsettiContext) {
        guard isStarted else {
            return
        }

        isStarted = false
        context.moduleLogger(moduleID: descriptor.moduleID).info("Starter app module stopped")
    }
}
#endif
