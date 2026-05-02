//___FILEHEADER___

#if canImport(ForsettiCore)
import Foundation
import ForsettiCore

final class ___PACKAGENAME:identifier___ServiceModule: ForsettiModule {
    enum Constants {
        static let moduleID = "com.yourcompany.___PACKAGENAME:identifier___.service-module"
        static let entryPoint = "___PACKAGENAME:identifier___ServiceModule"
        static let heartbeatStorageKey = "___PACKAGENAME:identifier___.service-module.last-heartbeat"
    }

    let descriptor = ModuleDescriptor(
        moduleID: Constants.moduleID,
        displayName: "___PACKAGENAME___ Service Module",
        moduleVersion: SemVer(major: 1, minor: 0, patch: 0),
        moduleType: .service
    )

    let manifest = ModuleManifest(
        schemaVersion: ModuleManifest.supportedSchemaVersion,
        moduleID: Constants.moduleID,
        displayName: "___PACKAGENAME___ Service Module",
        moduleVersion: SemVer(major: 1, minor: 0, patch: 0),
        moduleType: .service,
        supportedPlatforms: [.iOS, .macOS],
        minForsettiVersion: SemVer(major: 0, minor: 1, patch: 0),
        capabilitiesRequested: [.storage, .telemetry],
        iapProductID: nil,
        entryPoint: Constants.entryPoint
    )

    private var isStarted = false

    init() {}

    func start(context: ForsettiContext) throws {
        guard !isStarted else {
            return
        }

        isStarted = true
        context.moduleLogger(moduleID: descriptor.moduleID).info("Service module started")

        let startedAt = Date().ISO8601Format()
        if let storage = context.services.resolve(StorageService.self) {
            storage.set(startedAt, forKey: Constants.heartbeatStorageKey)
        }

        if let telemetry = context.services.resolve(TelemetryService.self) {
            telemetry.track(
                event: "service_module_started",
                properties: ["moduleID": descriptor.moduleID, "startedAt": startedAt]
            )
        }
    }

    func stop(context: ForsettiContext) {
        guard isStarted else {
            return
        }

        isStarted = false
        context.moduleLogger(moduleID: descriptor.moduleID).info("Service module stopped")

        if let storage = context.services.resolve(StorageService.self) {
            storage.removeValue(forKey: Constants.heartbeatStorageKey)
        }
    }
}
#endif
