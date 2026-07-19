@MainActor
final class ModelAssetsServiceModule: MirmirModule {
    let descriptor = MirmirModuleCatalog.modelAssets

    private let service: ModelAssetsService
    private var didStart = false

    init(service: ModelAssetsService) {
        self.service = service
    }

    func start(context: MirmirModuleContext) throws {
        guard !didStart else { return }
        service.start()
        didStart = true
        context.logger.info("Model assets service started")
    }

    func stop(context _: MirmirModuleContext) {
        guard didStart else { return }
        didStart = false
        service.stop()
    }
}
