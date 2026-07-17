import CoreVideo

@available(macOS 15.4, *)
struct ASHUpscaleFrameContext: Equatable, Sendable {
    let frameIndex: Int
    let presentationTimestampValue: Int64?
    let presentationTimestampTimescale: Int32?

    init(
        frameIndex: Int,
        presentationTimestampValue: Int64? = nil,
        presentationTimestampTimescale: Int32? = nil
    ) {
        self.frameIndex = frameIndex
        self.presentationTimestampValue = presentationTimestampValue
        self.presentationTimestampTimescale = presentationTimestampTimescale
    }
}

@available(macOS 15.4, *)
protocol ASHUpscaleFrameCompletion: AnyObject, Sendable {
    func finishAfterAppend()
}

@available(macOS 15.4, *)
final class ASHImmediateFrameCompletion: ASHUpscaleFrameCompletion, @unchecked Sendable {
    static let shared = ASHImmediateFrameCompletion()

    private init() {}

    func finishAfterAppend() {}
}

@available(macOS 15.4, *)
protocol ASHUpscaleBackend: AnyObject, Sendable {
    var outputMetadata: [String: String] { get }
    var finalOutputMetadata: [String: String] { get }
    func reset()
    func process(
        source: CVPixelBuffer,
        into destination: CVPixelBuffer,
        context: ASHUpscaleFrameContext
    ) async throws -> any ASHUpscaleFrameCompletion
}

extension ASHUpscaleBackend {
    var outputMetadata: [String: String] { [:] }
    var finalOutputMetadata: [String: String] { outputMetadata }

    func process(source: CVPixelBuffer, into destination: CVPixelBuffer) async throws {
        let completion = try await process(
            source: source,
            into: destination,
            context: ASHUpscaleFrameContext(frameIndex: 0)
        )
        completion.finishAfterAppend()
    }
}
