import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

func productReaderDecodeRun(
    url: URL,
    runIndex: Int,
    expectedCount: Int
) async throws -> DecodeRunEvidence {
    let descriptor = try await loadAssetDescriptor(url: url)
    let outputSettings: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: expectedPixelFormat),
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        kCVPixelBufferMetalCompatibilityKey as String: true
    ]
    let samples = try copySamples(descriptor: descriptor, outputSettings: outputSettings)
    guard samples.count == expectedCount else {
        throw FixtureError.invalidFixture("product reader decoded sample count is not \(expectedCount)")
    }
    let frames = try samples.enumerated().map { index, sample -> DecodedFrameEvidence in
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else {
            throw FixtureError.invalidFixture("product reader sample image buffer is absent")
        }
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sample)
        let duration = try resolvedDuration(
            sample: sample,
            nextSample: index + 1 < samples.count ? samples[index + 1] : nil,
            trackEnd: descriptor.trackEnd
        )
        return try decodedFrameEvidence(
            pixelBuffer: pixelBuffer,
            index: index,
            presentationTime: presentationTime,
            duration: duration
        )
    }
    return DecodeRunEvidence(runIndex: runIndex, frames: frames)
}

private func resolvedDuration(
    sample: CMSampleBuffer,
    nextSample: CMSampleBuffer?,
    trackEnd: CMTime
) throws -> CMTime {
    let presentationTime = CMSampleBufferGetPresentationTimeStamp(sample)
    let sampleDuration = CMSampleBufferGetDuration(sample)
    let duration: CMTime
    if sampleDuration.isNumeric, CMTimeCompare(sampleDuration, .zero) > 0 {
        duration = sampleDuration
    } else if let nextSample {
        duration = CMTimeSubtract(
            CMSampleBufferGetPresentationTimeStamp(nextSample),
            presentationTime
        )
    } else {
        duration = CMTimeSubtract(trackEnd, presentationTime)
    }
    guard duration.isNumeric, CMTimeCompare(duration, .zero) > 0 else {
        throw FixtureError.invalidFixture("product reader frame duration cannot be resolved")
    }
    return duration
}

func commandOutput(_ executable: String, _ arguments: [String]) -> String {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = pipe
    do {
        try process.run()
        process.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unavailable"
    } catch {
        return "unavailable"
    }
}

func environmentEvidence() -> EnvironmentEvidence {
    EnvironmentEvidence(
        macos: commandOutput("/usr/bin/sw_vers", []),
        xcode: commandOutput("/usr/bin/xcodebuild", ["-version"]),
        swift: commandOutput("/usr/bin/xcrun", ["swift", "--version"]),
        architecture: commandOutput("/usr/bin/uname", ["-m"]),
        hardwareModel: commandOutput("/usr/sbin/sysctl", ["-n", "hw.model"]),
        processor: commandOutput("/usr/sbin/sysctl", ["-n", "machdep.cpu.brand_string"])
    )
}

func encoderEvidence(_ outcome: CompressionOutcome) -> EncoderEvidence {
    EncoderEvidence(
        framework: "VideoToolbox",
        sessionType: "VTCompressionSession",
        encoderId: outcome.encoder.id,
        encoderName: outcome.encoder.name,
        displayName: outcome.encoder.displayName,
        hardwareAccelerated: outcome.hardwareAccelerated,
        hardwareAccelerationPropertyAvailable: outcome.hardwareAccelerationPropertyAvailable,
        hardwareAccelerationVerification: outcome.hardwareAccelerationPropertyAvailable
            ? "explicit hardware disable, exact encoder ID, and acceleration property"
            : "explicit hardware disable and exact software encoder ID; acceleration property unsupported",
        realTime: false,
        allowFrameReordering: false,
        allowTemporalCompression: false,
        maxKeyFrameInterval: 1,
        allFramesSync: outcome.allFramesSync,
        profileLevel: String(kVTProfileLevel_H264_Baseline_3_0),
        averageBitRate: averageBitRate,
        dataRateLimitBytes: dataRateLimitBytes,
        dataRateLimitSeconds: dataRateLimitSeconds,
        expectedFrameRate: expectedFrameRate,
        pixelFormat: fourCC(expectedPixelFormat),
        colorPrimaries: String(kCVImageBufferColorPrimaries_ITU_R_709_2),
        transferFunction: String(kCVImageBufferTransferFunction_ITU_R_709_2),
        yCbCrMatrix: String(kCVImageBufferYCbCrMatrix_ITU_R_709_2),
        chromaLocation: String(kCVImageBufferChromaLocation_Left)
    )
}
