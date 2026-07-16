import CoreVideo

@available(macOS 15.4, *)
protocol ASHUpscaleBackend: AnyObject, Sendable {
    func reset()
    func process(source: CVPixelBuffer, into destination: CVPixelBuffer) async throws
}
