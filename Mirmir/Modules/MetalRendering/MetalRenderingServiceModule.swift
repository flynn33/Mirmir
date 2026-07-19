@MainActor
final class MetalRenderingServiceModule: MirmirModule {
    let descriptor = MirmirModuleCatalog.metalRendering

    private let service: MetalRenderingService
    private var didStart = false

    init(service: MetalRenderingService) {
        self.service = service
    }

    func start(context: MirmirModuleContext) throws {
        guard !didStart else { return }
        try service.start()
        didStart = true
        context.logger.info("Metal rendering ready")
    }

    func stop(context _: MirmirModuleContext) {
        guard didStart else { return }
        didStart = false
        service.stop()
    }
}
