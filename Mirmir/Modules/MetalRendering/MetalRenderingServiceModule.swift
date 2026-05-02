import Foundation
import ForsettiCore

/// Lifecycle wrapper around `MetalRenderingService`.
///
/// The Forsetti `CapabilityScopedServiceProvider` only resolves the standard
/// service types (Networking, Storage, etc.); custom service contracts cannot
/// be resolved through `context.services`. So the service is captured via
/// constructor injection from the host bootstrap and the module merely owns
/// its lifecycle.
final class MetalRenderingServiceModule: ForsettiModule {

    let descriptor = ModuleDescriptor(
        moduleID: MirmirMetalConstants.moduleID,
        displayName: MirmirMetalConstants.displayName,
        moduleVersion: MirmirMetalConstants.moduleVersion,
        moduleType: .service
    )

    let manifest = ModuleManifest(
        schemaVersion: ModuleManifest.supportedSchemaVersion,
        moduleID: MirmirMetalConstants.moduleID,
        displayName: MirmirMetalConstants.displayName,
        moduleVersion: MirmirMetalConstants.moduleVersion,
        moduleType: .service,
        supportedPlatforms: [.macOS],
        minForsettiVersion: MirmirForsettiConstants.minForsettiVersion,
        maxForsettiVersion: nil,
        capabilitiesRequested: [],
        iapProductID: nil,
        entryPoint: MirmirMetalConstants.entryPoint
    )

    private let service: MetalRenderingService
    private var didStart = false

    init(service: MetalRenderingService) {
        self.service = service
    }

    func start(context: ForsettiContext) throws {
        guard !didStart else { return }
        didStart = true
        try service.start()
        context.moduleLogger(moduleID: descriptor.moduleID).info("Metal rendering ready")
    }

    func stop(context: ForsettiContext) {
        guard didStart else { return }
        didStart = false
        service.stop()
    }
}
