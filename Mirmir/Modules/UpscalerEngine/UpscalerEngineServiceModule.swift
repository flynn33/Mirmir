import Foundation
import ForsettiCore

final class UpscalerEngineServiceModule: ForsettiModule {

    let descriptor = ModuleDescriptor(
        moduleID: MirmirUpscalerEngineConstants.moduleID,
        displayName: MirmirUpscalerEngineConstants.displayName,
        moduleVersion: MirmirUpscalerEngineConstants.moduleVersion,
        moduleType: .service
    )

    let manifest = ModuleManifest(
        schemaVersion: ModuleManifest.supportedSchemaVersion,
        moduleID: MirmirUpscalerEngineConstants.moduleID,
        displayName: MirmirUpscalerEngineConstants.displayName,
        moduleVersion: MirmirUpscalerEngineConstants.moduleVersion,
        moduleType: .service,
        supportedPlatforms: [.macOS],
        minForsettiVersion: MirmirForsettiConstants.minForsettiVersion,
        maxForsettiVersion: nil,
        capabilitiesRequested: [.telemetry],
        iapProductID: nil,
        entryPoint: MirmirUpscalerEngineConstants.entryPoint
    )

    private let service: UpscalerEngineService
    private var didStart = false

    init(service: UpscalerEngineService) {
        self.service = service
    }

    func start(context: ForsettiContext) throws {
        guard !didStart else { return }
        didStart = true
        service.start()
        context.moduleLogger(moduleID: descriptor.moduleID).info("Upscaler engine started")
    }

    func stop(context: ForsettiContext) {
        guard didStart else { return }
        didStart = false
        service.stop()
    }
}
