@MainActor
final class MediaPipelineServiceModule: MirmirModule {
    let descriptor = MirmirModuleCatalog.mediaPipeline

    private let service: MediaPipelineService
    private var didStart = false

    init(service: MediaPipelineService) {
        self.service = service
    }

    func start(context: MirmirModuleContext) throws {
        guard !didStart else { return }
        service.start()
        didStart = true
        context.logger.info("Media pipeline started")
    }

    func stop(context _: MirmirModuleContext) {
        guard didStart else { return }
        didStart = false
        service.stop()
    }
}
