import Foundation
import ForsettiCore

final class MediaPipelineServiceModule: ForsettiModule {

    let descriptor = ModuleDescriptor(
        moduleID: MirmirMediaPipelineConstants.moduleID,
        displayName: MirmirMediaPipelineConstants.displayName,
        moduleVersion: MirmirMediaPipelineConstants.moduleVersion,
        moduleType: .service
    )

    let manifest = ModuleManifest(
        schemaVersion: ModuleManifest.currentSchemaVersion,
        manifestTemplateVersion: .current,
        moduleID: MirmirMediaPipelineConstants.moduleID,
        displayName: MirmirMediaPipelineConstants.displayName,
        moduleVersion: MirmirMediaPipelineConstants.moduleVersion,
        moduleType: .service,
        supportedPlatforms: [.macOS],
        minForsettiVersion: MirmirForsettiConstants.minForsettiVersion,
        maxForsettiVersion: nil,
        capabilitiesRequested: [.fileExport],
        iapProductID: nil,
        entryPoint: MirmirMediaPipelineConstants.entryPoint,
        runtimeRequirements: ModuleRuntimeRequirements(
            io: [
                ModuleIORequirement(
                    requirementID: "\(MirmirMediaPipelineConstants.moduleID).file-export.output",
                    kind: .fileExport,
                    access: .write,
                    required: true
                )
            ],
            dataIsolation: ModuleDataIsolation(
                mode: .privateToModule,
                ownedStoreIDs: [MirmirMediaPipelineConstants.moduleID]
            )
        )
    )

    private let service: MediaPipelineService
    private var didStart = false

    init(service: MediaPipelineService) {
        self.service = service
    }

    func start(context: any ForsettiModuleContext) throws {
        guard !didStart else { return }
        didStart = true
        service.start()
        context.logger.info("Media pipeline started")
    }

    func stop(context _: any ForsettiModuleContext) {
        guard didStart else { return }
        didStart = false
        service.stop()
    }
}
