@MainActor
final class UpscalerEngineServiceModule: MirmirModule {
    let descriptor = MirmirModuleCatalog.upscalerEngine

    private let service: UpscalerEngineService
    private var didStart = false

    init(service: UpscalerEngineService) {
        self.service = service
    }

    func start(context: MirmirModuleContext) throws {
        guard !didStart else { return }
        service.start()
        didStart = true
        context.logger.info("Upscaler engine started")
    }

    func stop(context _: MirmirModuleContext) {
        guard didStart else { return }
        didStart = false
        service.stop()
    }
}
