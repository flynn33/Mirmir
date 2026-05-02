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
        schemaVersion: ModuleManifest.supportedSchemaVersion,
        moduleID: MirmirMediaPipelineConstants.moduleID,
        displayName: MirmirMediaPipelineConstants.displayName,
        moduleVersion: MirmirMediaPipelineConstants.moduleVersion,
        moduleType: .service,
        supportedPlatforms: [.macOS],
        minForsettiVersion: MirmirForsettiConstants.minForsettiVersion,
        maxForsettiVersion: nil,
        capabilitiesRequested: [.fileExport],
        iapProductID: nil,
        entryPoint: MirmirMediaPipelineConstants.entryPoint
    )

    private let service: MediaPipelineService
    private var didStart = false

    init(service: MediaPipelineService) {
        self.service = service
    }

    func start(context: ForsettiContext) throws {
        guard !didStart else { return }
        didStart = true
        service.start()
        context.moduleLogger(moduleID: descriptor.moduleID).info("Media pipeline started")
    }

    func stop(context: ForsettiContext) {
        guard didStart else { return }
        didStart = false
        service.stop()
    }
}
