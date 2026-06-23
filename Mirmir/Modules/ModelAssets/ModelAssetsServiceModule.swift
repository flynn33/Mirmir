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
        schemaVersion: ModuleManifest.currentSchemaVersion,
        manifestTemplateVersion: .current,
        moduleID: MirmirModelAssetsConstants.moduleID,
        displayName: MirmirModelAssetsConstants.displayName,
        moduleVersion: MirmirModelAssetsConstants.moduleVersion,
        moduleType: .service,
        supportedPlatforms: [.macOS],
        minForsettiVersion: MirmirForsettiConstants.minForsettiVersion,
        maxForsettiVersion: nil,
        capabilitiesRequested: [.storage, .telemetry],
        iapProductID: nil,
        entryPoint: MirmirModelAssetsConstants.entryPoint,
        runtimeRequirements: ModuleRuntimeRequirements(
            io: [
                ModuleIORequirement(
                    requirementID: "\(MirmirModelAssetsConstants.moduleID).storage.status",
                    kind: .storage,
                    access: .readWrite,
                    required: false
                ),
                ModuleIORequirement(
                    requirementID: "\(MirmirModelAssetsConstants.moduleID).telemetry.lifecycle",
                    kind: .telemetry,
                    access: .emit,
                    required: false
                )
            ],
            dataIsolation: ModuleDataIsolation(
                mode: .privateToModule,
                ownedStoreIDs: [MirmirModelAssetsConstants.moduleID]
            )
        )
    )

    private let service: ModelAssetsService
    private var didStart = false

    init(service: ModelAssetsService) {
        self.service = service
    }

    func start(context: any ForsettiModuleContext) throws {
        guard !didStart else { return }
        didStart = true
        service.start()
        context.logger.info("Model assets service started")
    }

    func stop(context _: any ForsettiModuleContext) {
        guard didStart else { return }
        didStart = false
        service.stop()
    }
}
