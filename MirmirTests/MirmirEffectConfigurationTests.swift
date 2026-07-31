import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import XCTest
@testable import Mirmir

final class MirmirEffectConfigurationTests: XCTestCase {
    func testDefaultEffectsPreserveExistingProcessingIdentity() {
        let configuration = UpscaleProcessingConfiguration(
            enginePreference: .mpsLanczos,
            strategyPreference: .adaptive,
            temporalConsistencyEnabled: false,
            edgeFidelityLevel: .high,
            detailRecoveryLevel: .low
        )

        XCTAssertEqual(
            configuration.identity,
            "r13.processing.v1.engine-mps_lanczos.strategy-adaptive."
                + "temporal-off.edge-high.detail-low"
        )
        XCTAssertEqual(configuration.effects, .default)
    }

    func testEveryEnabledEffectParticipatesInVersionedIdentity() {
        let effects = UpscaleEffectConfiguration(
            edgePreservationEnabled: true,
            compressionCleanupEnabled: true,
            textureGrainProtectionEnabled: true,
            temporalStabilityEnabled: true
        )
        let configuration = UpscaleProcessingConfiguration(
            effects: effects
        )

        XCTAssertTrue(
            configuration.identity.hasPrefix("r13.processing.v2.")
        )
        for component in effects.identityComponents {
            XCTAssertTrue(
                configuration.identity.contains(component),
                "Missing identity component: \(component)"
            )
        }

        let individualConfigurations = [
            UpscaleEffectConfiguration(
                edgePreservationEnabled: true
            ),
            UpscaleEffectConfiguration(
                compressionCleanupEnabled: true
            ),
            UpscaleEffectConfiguration(
                textureGrainProtectionEnabled: true
            ),
            UpscaleEffectConfiguration(
                temporalStabilityEnabled: true
            )
        ].map {
            UpscaleProcessingConfiguration(effects: $0).identity
        }
        XCTAssertEqual(Set(individualConfigurations).count, 4)
    }

    func testProcessingConfigurationCodableRoundTripAndLegacyDecode()
        throws {
        let expected = UpscaleProcessingConfiguration(
            enginePreference: .mpsBilinear,
            strategyPreference: .direct,
            temporalConsistencyEnabled: false,
            edgeFidelityLevel: .low,
            detailRecoveryLevel: .high,
            effects: UpscaleEffectConfiguration(
                edgePreservationEnabled: true,
                compressionCleanupEnabled: false,
                textureGrainProtectionEnabled: true,
                temporalStabilityEnabled: false
            )
        )
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        XCTAssertEqual(
            try decoder.decode(
                UpscaleProcessingConfiguration.self,
                from: encoder.encode(expected)
            ),
            expected
        )

        let legacy = try JSONSerialization.data(withJSONObject: [
            "enginePreference": "automatic",
            "strategyPreference": "automatic",
            "temporalConsistencyEnabled": true,
            "edgeFidelityLevel": "medium",
            "detailRecoveryLevel": "medium"
        ])
        XCTAssertEqual(
            try decoder.decode(
                UpscaleProcessingConfiguration.self,
                from: legacy
            ).effects,
            .default
        )
    }

    func testRecoveryDescriptorPersistsEffectsAndAcceptsV2WithoutThem()
        throws {
        let effects = UpscaleEffectConfiguration(
            edgePreservationEnabled: true,
            compressionCleanupEnabled: true,
            textureGrainProtectionEnabled: true,
            temporalStabilityEnabled: true
        )
        let job = UpscaleJob(
            identifier: "effects-job",
            inputURL: URL(fileURLWithPath: "/tmp/input.mov"),
            outputURL: URL(fileURLWithPath: "/tmp/output.mov"),
            targetResolution: .p1080,
            processingConfiguration: UpscaleProcessingConfiguration(
                effects: effects
            )
        )
        let current = try R13RecoveryDescriptor(job: job)

        XCTAssertEqual(
            current.schemaVersion,
            R13RecoveryDescriptor.currentSchemaVersion
        )
        XCTAssertEqual(current.edgePreservationEnabled, true)
        XCTAssertEqual(current.compressionCleanupEnabled, true)
        XCTAssertEqual(current.textureGrainProtectionEnabled, true)
        XCTAssertEqual(current.temporalStabilityEnabled, true)
        try current.validate()

        let legacyData = try JSONSerialization.data(withJSONObject: [
            "schema_version": 2,
            "job_id": "legacy-effects-job",
            "output_filename": "output.mov",
            "target_width": 1920,
            "target_height": 1080,
            "codec": "hevc",
            "preserve_audio": true,
            "mode": "deterministic",
            "engine_preference": "automatic",
            "strategy_preference": "automatic",
            "temporal_consistency_enabled": true,
            "edge_fidelity_level": "medium",
            "detail_recovery_level": "medium"
        ])
        let legacy = try JSONDecoder().decode(
            R13RecoveryDescriptor.self,
            from: legacyData
        )

        try legacy.validate()
        XCTAssertNil(legacy.edgePreservationEnabled)
        XCTAssertNil(legacy.compressionCleanupEnabled)
        XCTAssertNil(legacy.textureGrainProtectionEnabled)
        XCTAssertNil(legacy.temporalStabilityEnabled)
    }
}

final class R13FidelityControlShippingAcceptanceTests: XCTestCase {
    func testShippingServiceMateriallyAppliesEveryVisibleFidelityControl()
        async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "mirmir-fidelity-acceptance-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer {
            try? fileManager.removeItem(at: root)
        }

        let sourceURL = root.appendingPathComponent("controlled-source.mp4")
        let frameDuration = CMTime(value: 1, timescale: 30)
        let frameCount = 2
        try await writeR13FidelityControlFixture(
            to: sourceURL,
            resolution: .p720,
            frameCount: frameCount,
            frameDuration: frameDuration
        )

        let baselineConfiguration = UpscaleProcessingConfiguration(
            temporalConsistencyEnabled: false,
            edgeFidelityLevel: .low,
            detailRecoveryLevel: .low,
            effects: .default
        )
        XCTAssertEqual(
            baselineConfiguration.effects,
            .default,
            "The acceptance baseline must disable all four product effects."
        )

        let baseline = try await renderR13FidelityAcceptanceOutput(
            label: "baseline",
            sourceURL: sourceURL,
            root: root,
            frameCount: frameCount,
            frameDuration: frameDuration,
            configuration: baselineConfiguration
        )
        let repeatedBaseline = try await renderR13FidelityAcceptanceOutput(
            label: "baseline-repeat",
            sourceURL: sourceURL,
            root: root,
            frameCount: frameCount,
            frameDuration: frameDuration,
            configuration: baselineConfiguration
        )
        XCTAssertEqual(
            repeatedBaseline.frames.map(\.luma),
            baseline.frames.map(\.luma),
            "An unchanged configuration must decode to identical pixels."
        )
        XCTAssertEqual(
            repeatedBaseline.identitySHA256,
            baseline.identitySHA256,
            "An unchanged configuration must retain its release identity."
        )

        let variants: [(String, UpscaleProcessingConfiguration)] = [
            (
                "temporal-consistency",
                fidelityConfiguration(
                    temporalConsistencyEnabled: true
                )
            ),
            (
                "edge-fidelity-high",
                fidelityConfiguration(edgeFidelityLevel: .high)
            ),
            (
                "detail-recovery-high",
                fidelityConfiguration(detailRecoveryLevel: .high)
            ),
            (
                "edge-preservation",
                fidelityConfiguration(
                    effects: UpscaleEffectConfiguration(
                        edgePreservationEnabled: true
                    )
                )
            ),
            (
                "compression-cleanup",
                fidelityConfiguration(
                    effects: UpscaleEffectConfiguration(
                        compressionCleanupEnabled: true
                    )
                )
            ),
            (
                "texture-grain-protection",
                fidelityConfiguration(
                    effects: UpscaleEffectConfiguration(
                        textureGrainProtectionEnabled: true
                    )
                )
            ),
            (
                "temporal-stability",
                fidelityConfiguration(
                    effects: UpscaleEffectConfiguration(
                        temporalStabilityEnabled: true
                    )
                )
            )
        ]

        for (label, configuration) in variants {
            let rendered = try await renderR13FidelityAcceptanceOutput(
                label: label,
                sourceURL: sourceURL,
                root: root,
                frameCount: frameCount,
                frameDuration: frameDuration,
                configuration: configuration
            )
            XCTAssertEqual(
                rendered.frames.count,
                baseline.frames.count,
                label
            )
            let differingLumaBytes = zip(
                baseline.frames,
                rendered.frames
            ).reduce(into: 0) { count, pair in
                count += zip(pair.0.luma, pair.1.luma)
                    .reduce(into: 0) { byteCount, bytes in
                        if bytes.0 != bytes.1 {
                            byteCount += 1
                        }
                    }
            }
            XCTAssertGreaterThan(
                differingLumaBytes,
                0,
                "\(label) was recorded in metadata but did not alter "
                    + "the published, reopened video."
            )
            XCTAssertNotEqual(
                rendered.identitySHA256,
                baseline.identitySHA256,
                "\(label) must participate in the exact release identity."
            )
        }
    }
}

private struct R13FidelityAcceptanceFrame {
    let luma: Data
    let presentationTime: CMTime
}

private struct R13FidelityAcceptanceOutput {
    let frames: [R13FidelityAcceptanceFrame]
    let identitySHA256: String
}

private enum R13FidelityAcceptanceFailure: Error {
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
}

private func fidelityConfiguration(
    temporalConsistencyEnabled: Bool = false,
    edgeFidelityLevel: MirmirAdjustmentLevel = .low,
    detailRecoveryLevel: MirmirAdjustmentLevel = .low,
    effects: UpscaleEffectConfiguration = .default
) -> UpscaleProcessingConfiguration {
    UpscaleProcessingConfiguration(
        temporalConsistencyEnabled: temporalConsistencyEnabled,
        edgeFidelityLevel: edgeFidelityLevel,
        detailRecoveryLevel: detailRecoveryLevel,
        effects: effects
    )
}

private func renderR13FidelityAcceptanceOutput(
    label: String,
    sourceURL: URL,
    root: URL,
    frameCount: Int,
    frameDuration: CMTime,
    configuration: UpscaleProcessingConfiguration
) async throws -> R13FidelityAcceptanceOutput {
    let fileManager = FileManager.default
    let directory = root.appendingPathComponent(label, isDirectory: true)
    let inputURL = directory.appendingPathComponent("source.mp4")
    let outputURL = directory.appendingPathComponent("output.mov")
    let jobsRootURL = directory.appendingPathComponent(
        "Jobs",
        isDirectory: true
    )
    try fileManager.createDirectory(
        at: jobsRootURL,
        withIntermediateDirectories: true
    )
    try fileManager.copyItem(at: sourceURL, to: inputURL)

    let hardening = try R13IntegrationHardeningHarness.make(
        jobsRootURL: jobsRootURL,
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
    let job = UpscaleJob(
        identifier: "fidelity-\(label)",
        inputURL: inputURL,
        outputURL: outputURL,
        targetResolution: .p1080,
        codec: .h264,
        preserveAudio: false,
        mode: .deterministic,
        processingConfiguration: configuration
    )

    let result = try await service.submit(job).waitForCompletion()

    XCTAssertEqual(result, outputURL, label)
    try await assertR13ReopenedOutput(at: result, resolution: .p1080)
    try await assertR13ReopenedCodecAndContainer(
        at: result,
        codec: .h264,
        pathExtension: "mov",
        majorBrand: "qt  "
    )
    let frames = try await readR13FidelityAcceptanceFrames(at: result)
    XCTAssertEqual(frames.count, frameCount, label)
    let assetDuration = try await AVURLAsset(url: result).load(.duration)
    for (index, frame) in frames.enumerated() {
        XCTAssertEqual(
            CMTimeCompare(
                frame.presentationTime,
                CMTimeMultiply(
                    frameDuration,
                    multiplier: Int32(index)
                )
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
            CMTimeMultiply(
                frameDuration,
                multiplier: Int32(frameCount)
            )
        ),
        0,
        "\(label) asset duration"
    )

    let metadata = try await readR13ReleaseMetadata(at: result)
    let expectedIdentity = try makeR13FidelityExpectedIdentity(
        job: job,
        hardening: hardening
    )
    try expectedIdentity.validateTimedMetadata(metadata)
    for (key, expectedValue) in expectedIdentity.timedMetadata
    where R13ProductASHDecisionMetadata.pendingValues[key] == nil {
        XCTAssertEqual(metadata[key], expectedValue, "\(label): \(key)")
    }
    XCTAssertEqual(
        metadata["com.mirmir.release.processing-configuration"],
        configuration.identity,
        label
    )
    let identitySHA256 = try XCTUnwrap(
        metadata["com.mirmir.release.identity-sha256"],
        label
    )
    return R13FidelityAcceptanceOutput(
        frames: frames,
        identitySHA256: identitySHA256
    )
}

private func makeR13FidelityExpectedIdentity(
    job: UpscaleJob,
    hardening: R13IntegrationHardeningHarness
) throws -> R13ReleaseIdentity {
    let modeBinding = R13ReleaseModePolicy.binding(
        for: job.mode,
        enginePreference:
            job.processingConfiguration.enginePreference
    )
    let environment = try R13ReleaseEnvironment(
        application: hardening.environment.application,
        framework: R13ReleaseFrameworkIdentity(
            frameworkIdentifier: modeBinding.frameworkIdentity,
            version: hardening.environment.framework.version,
            buildIdentity: hardening.environment.framework.buildIdentity
        ),
        runtime: hardening.environment.runtime
    )
    return try R13ReleaseHardeningRuntime.makeReleaseIdentity(
        job: job,
        route: .scale3Over2,
        modeBinding: modeBinding,
        source: R13LocalRestartSourceMeasurer().measureSource(
            at: job.inputURL
        ),
        environment: environment,
        policyResources: hardening.documents.policyResources
    )
}

private func writeR13FidelityControlFixture(
    to url: URL,
    resolution: VideoResolution,
    frameCount: Int,
    frameDuration: CMTime
) async throws {
    let writer: AVAssetWriter
    do {
        writer = try AVAssetWriter(url: url, fileType: .mp4)
    } catch {
        throw R13FidelityAcceptanceFailure.writerSetup
    }
    let input = AVAssetWriterInput(
        mediaType: .video,
        outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: resolution.width,
            AVVideoHeightKey: resolution.height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey:
                    AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey:
                    AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey:
                    AVVideoYCbCrMatrix_ITU_R_709_2
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 18_000_000,
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
        throw R13FidelityAcceptanceFailure.writerRejectedInput
    }
    writer.add(input)
    guard writer.startWriting() else {
        throw R13FidelityAcceptanceFailure.writerStart
    }
    writer.startSession(atSourceTime: .zero)
    guard let pool = adaptor.pixelBufferPool else {
        throw R13FidelityAcceptanceFailure.writerPool
    }

    for frameIndex in 0..<frameCount {
        while !input.isReadyForMoreMediaData {
            guard writer.status == .writing else {
                throw R13FidelityAcceptanceFailure.writerFinish(
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
            throw R13FidelityAcceptanceFailure
                .writerPixelBuffer(status)
        }
        try fillR13FidelityControlFrame(
            buffer,
            frameIndex: frameIndex
        )
        guard adaptor.append(
            buffer,
            withPresentationTime: CMTimeMultiply(
                frameDuration,
                multiplier: Int32(frameIndex)
            )
        ) else {
            throw R13FidelityAcceptanceFailure.writerAppend
        }
    }
    input.markAsFinished()
    writer.endSession(
        atSourceTime: CMTimeMultiply(
            frameDuration,
            multiplier: Int32(frameCount)
        )
    )
    await writer.finishWriting()
    guard writer.status == .completed else {
        throw R13FidelityAcceptanceFailure.writerFinish(
            writer.error?.localizedDescription ?? "unknown"
        )
    }
}

private func fillR13FidelityControlFrame(
    _ pixelBuffer: CVPixelBuffer,
    frameIndex: Int
) throws {
    guard CVPixelBufferLockBaseAddress(pixelBuffer, []) ==
            kCVReturnSuccess else {
        throw R13FidelityAcceptanceFailure.invalidPixelLayout
    }
    defer {
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
    }
    guard CVPixelBufferGetPlaneCount(pixelBuffer) == 2,
          let lumaBase = CVPixelBufferGetBaseAddressOfPlane(
            pixelBuffer,
            0
          ),
          let chromaBase = CVPixelBufferGetBaseAddressOfPlane(
            pixelBuffer,
            1
          ) else {
        throw R13FidelityAcceptanceFailure.invalidPixelLayout
    }
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
    let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)

    for row in 0..<height {
        let luma = lumaBase
            .advanced(by: row * lumaStride)
            .assumingMemoryBound(to: UInt8.self)
        for column in 0..<width {
            let value: Int
            switch column {
            case 0..<(width / 4):
                value = ((column / 4 + row / 4).isMultiple(of: 2))
                    ? 96 : 136
            case (width / 4)..<(width / 2):
                let edge = column < (3 * width / 8) ? 42 : 214
                value = edge + ((row / 18).isMultiple(of: 2) ? 0 : 3)
            case (width / 2)..<(3 * width / 4):
                value = 108
                    + ((column / 8 + row / 8).isMultiple(of: 2) ? 0 : 8)
            default:
                let temporalDelta = frameIndex * 4
                value = 72
                    + ((column + 2 * row) % 112)
                    + temporalDelta
            }
            luma[column] = UInt8(min(235, max(16, value)))
        }
    }

    for row in 0..<(height / 2) {
        let chroma = chromaBase
            .advanced(by: row * chromaStride)
            .assumingMemoryBound(to: UInt8.self)
        for column in stride(from: 0, to: width, by: 2) {
            let blockOffset =
                ((column / 16 + row / 8).isMultiple(of: 2)) ? -4 : 4
            chroma[column] = UInt8(128 + blockOffset + frameIndex * 2)
            chroma[column + 1] = UInt8(128 - blockOffset + frameIndex * 2)
        }
    }
}

private func readR13FidelityAcceptanceFrames(
    at url: URL
) async throws -> [R13FidelityAcceptanceFrame] {
    let asset = AVURLAsset(
        url: url,
        options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: true
        ]
    )
    let tracks = try await asset.loadTracks(withMediaType: .video)
    let track = try XCTUnwrap(tracks.first)
    let reader: AVAssetReader
    do {
        reader = try AVAssetReader(asset: asset)
    } catch {
        throw R13FidelityAcceptanceFailure.readerSetup
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
        throw R13FidelityAcceptanceFailure.readerSetup
    }
    reader.add(output)
    guard reader.startReading() else {
        throw R13FidelityAcceptanceFailure.readerStart
    }

    var frames: [R13FidelityAcceptanceFrame] = []
    while let sample = output.copyNextSampleBuffer() {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample),
              CVPixelBufferGetPlaneCount(pixelBuffer) == 2,
              CVPixelBufferLockBaseAddress(
                pixelBuffer,
                .readOnly
              ) == kCVReturnSuccess else {
            throw R13FidelityAcceptanceFailure.readerPixelBuffer
        }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        guard let base = CVPixelBufferGetBaseAddressOfPlane(
            pixelBuffer,
            0
        ) else {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
            throw R13FidelityAcceptanceFailure.readerPixelBuffer
        }
        var luma = Data(capacity: width * height)
        for row in 0..<height {
            luma.append(
                base.advanced(by: row * stride)
                    .assumingMemoryBound(to: UInt8.self),
                count: width
            )
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        frames.append(
            R13FidelityAcceptanceFrame(
                luma: luma,
                presentationTime:
                    CMSampleBufferGetPresentationTimeStamp(sample)
            )
        )
    }
    guard reader.status == .completed else {
        throw R13FidelityAcceptanceFailure.readerFinish(
            reader.error?.localizedDescription ?? "unknown"
        )
    }
    return frames
}
