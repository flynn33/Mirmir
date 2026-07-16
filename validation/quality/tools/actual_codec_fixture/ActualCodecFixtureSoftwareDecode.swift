import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

func softwareDecodeRun(
    url: URL,
    runIndex: Int,
    expectedCount: Int
) async throws -> (DecodeRunEvidence, Bool?) {
    let descriptor = try await loadAssetDescriptor(url: url)
    let samples = try copySamples(descriptor: descriptor, outputSettings: nil)
    guard samples.count == expectedCount else {
        throw FixtureError.invalidFixture("compressed sample count is not \(expectedCount)")
    }
    let collector = DecodedFrameCollector()
    let decoderSpecification: [String: Any] = [
        kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder as String: false
    ]
    let outputAttributes: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: expectedPixelFormat),
        kCVPixelBufferWidthKey as String: NSNumber(value: descriptor.width),
        kCVPixelBufferHeightKey as String: NSNumber(value: descriptor.height),
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
    ]
    var session: VTDecompressionSession?
    let createStatus = VTDecompressionSessionCreate(
        allocator: kCFAllocatorDefault,
        formatDescription: descriptor.format,
        decoderSpecification: decoderSpecification as CFDictionary,
        imageBufferAttributes: outputAttributes as CFDictionary,
        outputCallback: nil,
        decompressionSessionOut: &session
    )
    guard createStatus == noErr, let session else {
        throw FixtureError.operation("VTDecompressionSessionCreate", createStatus)
    }
    defer { VTDecompressionSessionInvalidate(session) }
    let realTimeStatus = VTSessionSetProperty(
        session,
        key: kVTDecompressionPropertyKey_RealTime,
        value: kCFBooleanFalse
    )
    guard realTimeStatus == noErr else {
        throw FixtureError.operation("VTSessionSetProperty(decompression real-time)", realTimeStatus)
    }
    let hardwareAccelerated = try optionalBoolProperty(
        session,
        key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
        operation: "VTSessionCopyProperty(decoder acceleration)"
    )
    guard hardwareAccelerated != true else {
        throw FixtureError.failed("software decoder requirement was not honored")
    }
    for sample in samples {
        var infoFlags = VTDecodeInfoFlags()
        let status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sample,
            flags: [._EnableAsynchronousDecompression],
            infoFlagsOut: &infoFlags
        ) { status, flags, imageBuffer, _, presentationTime, duration in
            collector.record(
                status: status,
                flags: flags,
                imageBuffer: imageBuffer,
                presentationTime: presentationTime,
                duration: duration
            )
        }
        guard status == noErr, !infoFlags.contains(.frameDropped) else {
            throw FixtureError.operation("VTDecompressionSessionDecodeFrame", status)
        }
    }
    let finishStatus = VTDecompressionSessionFinishDelayedFrames(session)
    guard finishStatus == noErr else {
        throw FixtureError.operation("VTDecompressionSessionFinishDelayedFrames", finishStatus)
    }
    let waitStatus = VTDecompressionSessionWaitForAsynchronousFrames(session)
    guard waitStatus == noErr else {
        throw FixtureError.operation("VTDecompressionSessionWaitForAsynchronousFrames", waitStatus)
    }
    let frames = try collector.finish(expectedCount: expectedCount)
    return (DecodeRunEvidence(runIndex: runIndex, frames: frames), hardwareAccelerated)
}
