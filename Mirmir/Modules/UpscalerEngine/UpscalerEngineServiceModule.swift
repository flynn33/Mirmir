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
        schemaVersion: ModuleManifest.currentSchemaVersion,
        manifestTemplateVersion: .current,
        moduleID: MirmirUpscalerEngineConstants.moduleID,
        displayName: MirmirUpscalerEngineConstants.displayName,
        moduleVersion: MirmirUpscalerEngineConstants.moduleVersion,
        moduleType: .service,
        supportedPlatforms: [.macOS],
        minForsettiVersion: MirmirForsettiConstants.minForsettiVersion,
        maxForsettiVersion: nil,
        capabilitiesRequested: [.telemetry],
        iapProductID: nil,
        entryPoint: MirmirUpscalerEngineConstants.entryPoint,
        runtimeRequirements: ModuleRuntimeRequirements(
            io: [
                ModuleIORequirement(
                    requirementID: "\(MirmirUpscalerEngineConstants.moduleID).telemetry.lifecycle",
                    kind: .telemetry,
                    access: .emit,
                    required: false
                )
            ],
            dataIsolation: ModuleDataIsolation(
                mode: .privateToModule,
                ownedStoreIDs: [MirmirUpscalerEngineConstants.moduleID]
            )
        )
    )

    private let service: UpscalerEngineService
    private var didStart = false

    init(service: UpscalerEngineService) {
        self.service = service
    }

    func start(context: any ForsettiModuleContext) throws {
        guard !didStart else { return }
        didStart = true
        service.start()
        context.logger.info("Upscaler engine started")
    }

    func stop(context _: any ForsettiModuleContext) {
        guard didStart else { return }
        didStart = false
        service.stop()
    }
}
