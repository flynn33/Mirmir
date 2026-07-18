import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

@available(macOS 15.4, *)
final class ASHP08WriterSession: @unchecked Sendable {
    private let output: URL
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var finished = false

    init(output: URL, fixture: ASHP08Fixture) throws {
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw ASHP08NativeError.outputExists(output.path)
        }
        self.output = output
        self.writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        self.input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: ProductVideoOutputSettings.make(
                resolution: VideoResolution(
                    width: fixture.destinationWidth,
                    height: fixture.destinationHeight
                ),
                codec: .hevc
            )
        )
        input.expectsMediaDataInRealTime = false
        self.adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey as String: fixture.destinationWidth,
                kCVPixelBufferHeightKey as String: fixture.destinationHeight,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                kCVPixelBufferMetalCompatibilityKey as String: true
            ]
        )
        guard writer.canAdd(input) else {
            throw ASHP08NativeError.mediaFailure("writer rejected the video input")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw ASHP08NativeError.mediaFailure(
                "writer start failed: \(String(describing: writer.error))"
            )
        }
        writer.startSession(atSourceTime: .zero)
    }

    func makePixelBuffer() throws -> CVPixelBuffer {
        guard let pool = adaptor.pixelBufferPool else {
            throw ASHP08NativeError.mediaFailure("writer pixel-buffer pool is absent")
        }
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard status == kCVReturnSuccess, let buffer else {
            throw ASHP08NativeError.mediaFailure(
                "writer pixel-buffer allocation failed: \(status)"
            )
        }
        CVBufferSetAttachment(
            buffer,
            kCVImageBufferChromaLocationTopFieldKey,
            kCVImageBufferChromaLocation_Left,
            .shouldPropagate
        )
        return buffer
    }

    func append(_ buffer: CVPixelBuffer, at timestamp: CMTime) async throws {
        while !input.isReadyForMoreMediaData {
            guard writer.status == .writing else {
                throw ASHP08NativeError.mediaFailure(
                    "writer left writing state: \(String(describing: writer.error))"
                )
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        guard adaptor.append(buffer, withPresentationTime: timestamp) else {
            throw ASHP08NativeError.mediaFailure(
                "writer append failed: \(String(describing: writer.error))"
            )
        }
    }

    func finish() async throws {
        guard !finished else {
            throw ASHP08NativeError.mediaFailure("writer was finalized twice")
        }
        finished = true
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw ASHP08NativeError.mediaFailure(
                "writer finalization failed: \(String(describing: writer.error))"
            )
        }
    }

    func removeOutput() {
        guard FileManager.default.fileExists(atPath: output.path) else { return }
        try? FileManager.default.removeItem(at: output)
    }
}
