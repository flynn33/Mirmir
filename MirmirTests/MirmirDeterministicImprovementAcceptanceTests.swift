import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import XCTest
@testable import Mirmir

// The real AVFoundation writer/reader fixture is intentionally colocated with
// the acceptance so its controlled experiment remains independently auditable.
// swiftlint:disable file_length
final class MirmirImprovementAcceptanceTests: XCTestCase {
    // swiftlint:disable:next function_body_length
    func testCompressionCleanupStrictlyReducesReferenceErrorAfterVImageUpscale()
        async throws {
        let workspace = try R13ImprovementWorkspace()
        defer { workspace.remove() }
        let frameCount = 3
        let frameDuration = CMTime(value: 1, timescale: 30)
        try await writeR13ImprovementFixture(
            to: workspace.cleanSourceURL,
            kind: .clean,
            frameCount: frameCount,
            frameDuration: frameDuration
        )
        try await writeR13ImprovementFixture(
            to: workspace.degradedSourceURL,
            kind: .blockQuantized,
            frameCount: frameCount,
            frameDuration: frameDuration
        )

        let baselineConfiguration = r13ImprovementConfiguration(
            compressionCleanupEnabled: false
        )
        let enhancedConfiguration = r13ImprovementConfiguration(
            compressionCleanupEnabled: true
        )
        XCTAssertEqual(
            baselineConfiguration.enginePreference,
            enhancedConfiguration.enginePreference
        )
        XCTAssertEqual(
            baselineConfiguration.strategyPreference,
            enhancedConfiguration.strategyPreference
        )
        XCTAssertEqual(
            baselineConfiguration.temporalConsistencyEnabled,
            enhancedConfiguration.temporalConsistencyEnabled
        )
        XCTAssertEqual(
            baselineConfiguration.edgeFidelityLevel,
            enhancedConfiguration.edgeFidelityLevel
        )
        XCTAssertEqual(
            baselineConfiguration.detailRecoveryLevel,
            enhancedConfiguration.detailRecoveryLevel
        )
        XCTAssertEqual(
            baselineConfiguration.smoothMotion,
            enhancedConfiguration.smoothMotion
        )
        XCTAssertEqual(baselineConfiguration.effects, .default)
        XCTAssertEqual(
            enhancedConfiguration.effects,
            UpscaleEffectConfiguration(compressionCleanupEnabled: true)
        )

        let hardening = try R13IntegrationHardeningHarness.make(
            jobsRootURL: workspace.jobsRootURL,
            exactFrameCount: frameCount
        )
        let diagnostics = MirmirDiagnosticStore()
        let media = AVFoundationMediaPipeline(
            metal: NoopMetalRenderingService(),
            diagnostics: diagnostics
        )
        let service = R13ReleaseUpscalerEngineService(
            media: media,
            hardeningRuntime: hardening.runtime,
            diagnostics: diagnostics
        )
        let cleanReference = try await renderR13ImprovementOutput(
            label: "clean-reference",
            sourceURL: workspace.cleanSourceURL,
            outputURL: workspace.cleanReferenceOutputURL,
            service: service,
            configuration: baselineConfiguration,
            frameCount: frameCount,
            frameDuration: frameDuration
        )
        let degradedBaseline = try await renderR13ImprovementOutput(
            label: "degraded-baseline",
            sourceURL: workspace.degradedSourceURL,
            outputURL: workspace.degradedBaselineOutputURL,
            service: service,
            configuration: baselineConfiguration,
            frameCount: frameCount,
            frameDuration: frameDuration
        )
        let degradedEnhanced = try await renderR13ImprovementOutput(
            label: "degraded-enhanced",
            sourceURL: workspace.degradedSourceURL,
            outputURL: workspace.degradedEnhancedOutputURL,
            service: service,
            configuration: enhancedConfiguration,
            frameCount: frameCount,
            frameDuration: frameDuration
        )

        let baselineError = try aggregateR13ImprovementLumaError(
            degradedBaseline.frames,
            reference: cleanReference.frames
        )
        let enhancedError = try aggregateR13ImprovementLumaError(
            degradedEnhanced.frames,
            reference: cleanReference.frames
        )
        XCTAssertGreaterThan(
            baselineError,
            0,
            "The controlled degradation must survive the media workflow."
        )
        XCTAssertLessThan(
            enhancedError,
            baselineError,
            "Compression cleanup must strictly reduce aggregate decoded-luma "
                + "error against the clean, identically scaled reference."
        )
    }
}

private struct R13ImprovementWorkspace {
    let rootURL: URL
    let cleanSourceURL: URL
    let degradedSourceURL: URL
    let cleanReferenceOutputURL: URL
    let degradedBaselineOutputURL: URL
    let degradedEnhancedOutputURL: URL
    let jobsRootURL: URL

    init(fileManager: FileManager = .default) throws {
        rootURL = fileManager.temporaryDirectory.appendingPathComponent(
            "mirmir-deterministic-improvement-\(UUID().uuidString)",
            isDirectory: true
        )
        cleanSourceURL = rootURL.appendingPathComponent("clean.mp4")
        degradedSourceURL = rootURL.appendingPathComponent("degraded.mp4")
        cleanReferenceOutputURL = rootURL.appendingPathComponent(
            "clean-reference.mov"
        )
        degradedBaselineOutputURL = rootURL.appendingPathComponent(
            "degraded-baseline.mov"
        )
        degradedEnhancedOutputURL = rootURL.appendingPathComponent(
            "degraded-enhanced.mov"
        )
        jobsRootURL = rootURL.appendingPathComponent(
            "Jobs",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: jobsRootURL,
            withIntermediateDirectories: true
        )
    }

    func remove(fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: rootURL)
    }
}

private struct R13ImprovementFrame {
    let luma: Data
    let presentationTime: CMTime
}

private struct R13ImprovementOutput {
    let frames: [R13ImprovementFrame]
}

private enum R13ImprovementFixtureKind {
    case clean
    case blockQuantized
}

private enum R13ImprovementFailure: Error {
    case writerSetup
    case writerRejectedInput
    case writerStart
    case writerPool
    case writerPixelBuffer(CVReturn)
    case writerAppend
    case writerFinish(String)
    case readerSetup
    case readerStart
    case readerPixelBuffer
    case readerFinish(String)
    case invalidPixelLayout
    case frameShapeMismatch
}

private func r13ImprovementConfiguration(
    compressionCleanupEnabled: Bool
) -> UpscaleProcessingConfiguration {
    UpscaleProcessingConfiguration(
        enginePreference: .accelerateVImageHighQuality,
        strategyPreference: .direct,
        temporalConsistencyEnabled: false,
        edgeFidelityLevel: .low,
        detailRecoveryLevel: .low,
        effects: UpscaleEffectConfiguration(
            compressionCleanupEnabled: compressionCleanupEnabled
        )
    )
}

private func renderR13ImprovementOutput(
    label: String,
    sourceURL: URL,
    outputURL: URL,
    service: R13ReleaseUpscalerEngineService,
    configuration: UpscaleProcessingConfiguration,
    frameCount: Int,
    frameDuration: CMTime
) async throws -> R13ImprovementOutput {
    let job = UpscaleJob(
        identifier: "measurable-improvement-\(label)",
        inputURL: sourceURL,
        outputURL: outputURL,
        targetResolution: .p1080,
        codec: .h264,
        preserveAudio: false,
        mode: .deterministic,
        processingConfiguration: configuration
    )
    let result = try await service.submit(job).waitForCompletion()

    XCTAssertEqual(result, outputURL, label)
    XCTAssertTrue(FileManager.default.fileExists(atPath: result.path), label)
    try await assertR13ReopenedOutput(at: result, resolution: .p1080)
    try await assertR13ReopenedCodecAndContainer(
        at: result,
        codec: .h264,
        pathExtension: "mov",
        majorBrand: "qt  "
    )
    let asset = AVURLAsset(
        url: result,
        options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
    )
    let isPlayable = try await asset.load(.isPlayable)
    XCTAssertTrue(isPlayable, label)
    let frames = try await readR13ImprovementFrames(from: asset)
    XCTAssertEqual(frames.count, frameCount, label)
    let duration = try await asset.load(.duration)
    assertR13ImprovementTimeline(
        frames,
        assetDuration: duration,
        frameCount: frameCount,
        frameDuration: frameDuration,
        label: label
    )
    let metadata = try await readR13ReleaseMetadata(at: result)
    XCTAssertEqual(
        metadata["com.mirmir.release.backend-id"],
        R03BaselineSubjectID.vImageLanczos5.rawValue,
        label
    )
    XCTAssertEqual(
        metadata["com.mirmir.release.processing-configuration"],
        configuration.identity,
        label
    )
    return R13ImprovementOutput(frames: frames)
}

private func assertR13ImprovementTimeline(
    _ frames: [R13ImprovementFrame],
    assetDuration: CMTime,
    frameCount: Int,
    frameDuration: CMTime,
    label: String
) {
    for (index, frame) in frames.enumerated() {
        XCTAssertEqual(
            CMTimeCompare(
                frame.presentationTime,
                CMTimeMultiply(frameDuration, multiplier: Int32(index))
            ),
            0,
            "\(label) frame \(index) presentation time"
        )
        let frameEnd = index + 1 < frames.count
            ? frames[index + 1].presentationTime
            : assetDuration
        XCTAssertEqual(
            CMTimeCompare(
                CMTimeSubtract(frameEnd, frame.presentationTime),
                frameDuration
            ),
            0,
            "\(label) frame \(index) effective duration"
        )
    }
    XCTAssertEqual(
        CMTimeCompare(
            assetDuration,
            CMTimeMultiply(frameDuration, multiplier: Int32(frameCount))
        ),
        0,
        "\(label) asset duration"
    )
}

private func writeR13ImprovementFixture(
    to url: URL,
    kind: R13ImprovementFixtureKind,
    frameCount: Int,
    frameDuration: CMTime
) async throws {
    let resolution = VideoResolution.p270
    let writer: AVAssetWriter
    do {
        writer = try AVAssetWriter(url: url, fileType: .mp4)
    } catch {
        throw R13ImprovementFailure.writerSetup
    }
    let input = AVAssetWriterInput(
        mediaType: .video,
        outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: resolution.width,
            AVVideoHeightKey: resolution.height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey:
                    AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 20_000_000,
                AVVideoMaxKeyFrameIntervalKey: 1
            ]
        ]
    )
    input.expectsMediaDataInRealTime = false
    input.mediaTimeScale = 600
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: resolution.width,
            kCVPixelBufferHeightKey as String: resolution.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ]
    )
    guard writer.canAdd(input) else {
        throw R13ImprovementFailure.writerRejectedInput
    }
    writer.add(input)
    guard writer.startWriting() else {
        throw R13ImprovementFailure.writerStart
    }
    writer.startSession(atSourceTime: .zero)
    guard let pool = adaptor.pixelBufferPool else {
        throw R13ImprovementFailure.writerPool
    }
    try await appendR13ImprovementFrames(
        to: adaptor,
        input: input,
        writer: writer,
        pool: pool,
        kind: kind,
        frameCount: frameCount,
        frameDuration: frameDuration
    )
    input.markAsFinished()
    writer.endSession(
        atSourceTime: CMTimeMultiply(
            frameDuration,
            multiplier: Int32(frameCount)
        )
    )
    await writer.finishWriting()
    guard writer.status == .completed else {
        throw R13ImprovementFailure.writerFinish(
            writer.error?.localizedDescription ?? "unknown"
        )
    }
}

private func appendR13ImprovementFrames(
    to adaptor: AVAssetWriterInputPixelBufferAdaptor,
    input: AVAssetWriterInput,
    writer: AVAssetWriter,
    pool: CVPixelBufferPool,
    kind: R13ImprovementFixtureKind,
    frameCount: Int,
    frameDuration: CMTime
) async throws {
    for frameIndex in 0..<frameCount {
        while !input.isReadyForMoreMediaData {
            guard writer.status == .writing else {
                throw R13ImprovementFailure.writerFinish(
                    writer.error?.localizedDescription ?? "unknown"
                )
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(
            kCFAllocatorDefault,
            pool,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            throw R13ImprovementFailure.writerPixelBuffer(status)
        }
        try fillR13ImprovementFrame(
            buffer,
            kind: kind,
            frameIndex: frameIndex
        )
        guard adaptor.append(
            buffer,
            withPresentationTime: CMTimeMultiply(
                frameDuration,
                multiplier: Int32(frameIndex)
            )
        ) else {
            throw R13ImprovementFailure.writerAppend
        }
    }
}

private func fillR13ImprovementFrame(
    _ pixelBuffer: CVPixelBuffer,
    kind: R13ImprovementFixtureKind,
    frameIndex: Int
) throws {
    guard CVPixelBufferLockBaseAddress(pixelBuffer, []) ==
            kCVReturnSuccess else {
        throw R13ImprovementFailure.invalidPixelLayout
    }
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    guard CVPixelBufferGetPlaneCount(pixelBuffer) == 2,
          let lumaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
          let chromaBase = CVPixelBufferGetBaseAddressOfPlane(
              pixelBuffer,
              1
          ) else {
        throw R13ImprovementFailure.invalidPixelLayout
    }
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
    let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
    for row in 0..<height {
        let luma = lumaBase.advanced(by: row * lumaStride)
            .assumingMemoryBound(to: UInt8.self)
        for column in 0..<width {
            let cleanValue = column < width / 2
                ? 92 + frameIndex * 3
                : 164 + frameIndex * 3
            let degradation: Int
            switch kind {
            case .clean:
                degradation = 0
            case .blockQuantized:
                degradation = (
                    column / 8 + row / 8 + frameIndex
                ).isMultiple(of: 2) ? -6 : 6
            }
            luma[column] = UInt8(cleanValue + degradation)
        }
    }
    for row in 0..<(height / 2) {
        let chroma = chromaBase.advanced(by: row * chromaStride)
            .assumingMemoryBound(to: UInt8.self)
        for column in stride(from: 0, to: width, by: 2) {
            chroma[column] = 128
            chroma[column + 1] = 128
        }
    }
}

private func readR13ImprovementFrames(
    from asset: AVURLAsset
) async throws -> [R13ImprovementFrame] {
    let videoTracks = try await asset.loadTracks(withMediaType: .video)
    let track = try XCTUnwrap(videoTracks.first)
    let reader: AVAssetReader
    do {
        reader = try AVAssetReader(asset: asset)
    } catch {
        throw R13ImprovementFailure.readerSetup
    }
    let output = AVAssetReaderTrackOutput(
        track: track,
        outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ]
    )
    output.alwaysCopiesSampleData = true
    guard reader.canAdd(output) else {
        throw R13ImprovementFailure.readerSetup
    }
    reader.add(output)
    guard reader.startReading() else {
        throw R13ImprovementFailure.readerStart
    }

    var frames: [R13ImprovementFrame] = []
    while let sample = output.copyNextSampleBuffer() {
        frames.append(try readR13ImprovementFrame(from: sample))
    }
    guard reader.status == .completed else {
        throw R13ImprovementFailure.readerFinish(
            reader.error?.localizedDescription ?? "unknown"
        )
    }
    return frames
}

private func readR13ImprovementFrame(
    from sample: CMSampleBuffer
) throws -> R13ImprovementFrame {
    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample),
          CVPixelBufferGetPlaneCount(pixelBuffer) == 2,
          CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) ==
            kCVReturnSuccess else {
        throw R13ImprovementFailure.readerPixelBuffer
    }
    defer {
        CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
    }
    let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
    let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
    let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
    guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else {
        throw R13ImprovementFailure.readerPixelBuffer
    }
    var luma = Data(capacity: width * height)
    for row in 0..<height {
        luma.append(
            base.advanced(by: row * stride)
                .assumingMemoryBound(to: UInt8.self),
            count: width
        )
    }
    return R13ImprovementFrame(
        luma: luma,
        presentationTime: CMSampleBufferGetPresentationTimeStamp(sample)
    )
}

private func aggregateR13ImprovementLumaError(
    _ actual: [R13ImprovementFrame],
    reference: [R13ImprovementFrame]
) throws -> UInt64 {
    guard actual.count == reference.count else {
        throw R13ImprovementFailure.frameShapeMismatch
    }
    return try zip(actual, reference).reduce(into: UInt64(0)) { total, pair in
        guard pair.0.luma.count == pair.1.luma.count else {
            throw R13ImprovementFailure.frameShapeMismatch
        }
        total += pair.0.luma.withUnsafeBytes { actualBytes in
            pair.1.luma.withUnsafeBytes { referenceBytes in
                let actualBase = actualBytes.bindMemory(to: UInt8.self)
                let referenceBase = referenceBytes.bindMemory(to: UInt8.self)
                return actualBase.indices.reduce(
                    into: UInt64(0)
                ) { frameError, index in
                    frameError += UInt64(
                        abs(
                            Int(actualBase[index])
                                - Int(referenceBase[index])
                        )
                    )
                }
            }
        }
    }
}
