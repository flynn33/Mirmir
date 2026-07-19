@MainActor
protocol MirmirModule: AnyObject {
    var descriptor: MirmirModuleDescriptor { get }

    func start(context: MirmirModuleContext) throws
    func stop(context: MirmirModuleContext)
}
