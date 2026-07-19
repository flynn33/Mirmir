@MainActor
final class MirmirUIModule: MirmirModule {
    let descriptor = MirmirModuleCatalog.ui

    private var didStart = false

    func start(context: MirmirModuleContext) throws {
        guard !didStart else { return }
        didStart = true
        context.logger.info("Mirmir UI module activated")
    }

    func stop(context _: MirmirModuleContext) {
        guard didStart else { return }
        didStart = false
    }
}
