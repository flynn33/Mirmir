import Foundation
import ForsettiCore

final class ModelAssetsServiceModule: ForsettiModule {

    let descriptor = ModuleDescriptor(
        moduleID: MirmirModelAssetsConstants.moduleID,
        displayName: MirmirModelAssetsConstants.displayName,
        moduleVersion: MirmirModelAssetsConstants.moduleVersion,
        moduleType: .service
    )

    let manifest = ModuleManifest(
        schemaVersion: ModuleManifest.supportedSchemaVersion,
        moduleID: MirmirModelAssetsConstants.moduleID,
        displayName: MirmirModelAssetsConstants.displayName,
        moduleVersion: MirmirModelAssetsConstants.moduleVersion,
        moduleType: .service,
        supportedPlatforms: [.macOS],
        minForsettiVersion: MirmirForsettiConstants.minForsettiVersion,
        maxForsettiVersion: nil,
        capabilitiesRequested: [.storage, .telemetry],
        iapProductID: nil,
        entryPoint: MirmirModelAssetsConstants.entryPoint
    )

    private let service: ModelAssetsService
    private var didStart = false

    init(service: ModelAssetsService) {
        self.service = service
    }

    func start(context: ForsettiContext) throws {
        guard !didStart else { return }
        didStart = true
        service.start()
        context.moduleLogger(moduleID: descriptor.moduleID).info("Model assets service started")
    }

    func stop(context: ForsettiContext) {
        guard didStart else { return }
        didStart = false
        service.stop()
    }
}
