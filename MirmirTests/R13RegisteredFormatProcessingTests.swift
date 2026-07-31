import CoreVideo
import XCTest
@testable import Mirmir

final class R13RegisteredFormatProcessingTests: XCTestCase {
    private let sourceResolution =
        VideoResolution(width: 8, height: 8)
    private let targetResolution =
        VideoResolution(width: 12, height: 12)

    func testVImageAndNoScaleNormalizationProcessEveryFormat()
        throws {
        let normalizer = R13ReleaseVideoFrameNormalizer(
            nv12: R13NV12FrameNormalizer()
        )
        for format in R13PixelLayoutTestFixtures
            .allMediaVideoFormats {
            let source = try makeSource(format: format)
            let sourceFrame = try R13TightPixelFrame(
                capturing: source
            )
            let normalized = try normalizer.normalize(
                source,
                codedResolution: sourceResolution,
                presentationResolution: sourceResolution,
                pixelAspectRatio: nil,
                videoFormat: format
            )

            XCTAssertEqual(
                try R13TightPixelFrame(capturing: normalized),
                sourceFrame,
                format.description
            )
            let destination = try makeDestination(
                format: format,
                resolution: targetResolution
            )
            try R13FormatPreservingVImageScaler(
                sourceResolution: sourceResolution,
                targetResolution: targetResolution,
                videoFormat: format,
                quality: .highQuality
            ).scale(
                source: source,
                destination: destination,
                cancellation:
                    AppleUpscaleOperationCancellationSignal()
            )

            try assertValid(
                destination,
                format: format,
                resolution: targetResolution
            )
            if format.hasAlpha {
                XCTAssertGreaterThan(
                    Set(
                        try R13PixelLayoutTestFixtures.alphaCodes(
                            destination
                        )
                    ).count,
                    1,
                    format.description
                )
            }
        }
    }

    func testMPSLanczosProcessesEveryRegisteredFormat() throws {
        for format in R13PixelLayoutTestFixtures
            .allMediaVideoFormats {
            let source = try makeSource(format: format)
            let destination = try makeDestination(
                format: format,
                resolution: targetResolution
            )
            let scaler = try R13FormatPreservingMPSScaler(
                mode: .lanczos,
                sourceResolution: sourceResolution,
                targetResolution: targetResolution,
                videoFormat: format
            )
            try scaler.scale(
                source: source,
                destination: destination,
                cancellation:
                    AppleUpscaleOperationCancellationSignal()
            )
            scaler.finish()

            try assertValid(
                destination,
                format: format,
                resolution: targetResolution
            )
        }
    }

    func testEnhancementChangesBoundedLumaAndPreservesAlpha()
        throws {
        let configuration = R13PixelLayoutEnhancementConfiguration(
            edgeFidelityLevel: .high,
            detailRecoveryLevel: .high,
            edgePreservationEnabled: true,
            compressionCleanupEnabled: true,
            textureGrainProtectionEnabled: true,
            temporalConsistencyEnabled: false,
            temporalStabilityEnabled: false
        )
        for format in R13PixelLayoutTestFixtures
            .allMediaVideoFormats {
            let source = try makeSource(format: format)
            let output = try process(
                source,
                format: format,
                configuration: configuration
            )

            XCTAssertNotEqual(
                try R13PixelLayoutTestFixtures.lumaCodes(output),
                try R13PixelLayoutTestFixtures.lumaCodes(source),
                format.description
            )
            try assertValid(
                output,
                format: format,
                resolution: sourceResolution
            )
            if format.hasAlpha {
                XCTAssertEqual(
                    try R13PixelLayoutTestFixtures.alphaCodes(output),
                    try R13PixelLayoutTestFixtures.alphaCodes(source),
                    format.description
                )
            }
        }
    }

    func testEveryEnhancementControlIsMaterialForEveryFormat()
        throws {
        for format in R13PixelLayoutTestFixtures
            .allMediaVideoFormats {
            let source = try makeSource(format: format)
            let baseline = try enhancedLuma(
                source,
                format: format,
                configuration: configuration()
            )
            let variants = [
                configuration(edge: .high),
                configuration(detail: .high),
                configuration(edgePreservation: true),
                configuration(compressionCleanup: true),
                configuration(textureProtection: true)
            ]
            for variant in variants {
                XCTAssertNotEqual(
                    try enhancedLuma(
                        source,
                        format: format,
                        configuration: variant
                    ),
                    baseline,
                    "\(format.description) \(variant)"
                )
            }
        }
    }

    func testTemporalHistoryRestoreAndCancellationCoverEveryFormat()
        throws {
        let temporalConfiguration = configuration(
            temporalConsistency: true,
            temporalStability: true
        )
        for format in R13PixelLayoutTestFixtures
            .allMediaVideoFormats {
            let first = try makeSource(
                format: format,
                offset: 0
            )
            let second = try makeSource(
                format: format,
                offset: 1
            )
            let uninterrupted = try makeProcessor(
                format: format,
                configuration: temporalConfiguration
            )
            let cached = try uninterrupted.process(first)
            let expected = try uninterrupted.process(second)
            let restored = try makeProcessor(
                format: format,
                configuration: temporalConfiguration
            )
            try restored.restoreTemporalHistory(from: cached)
            let actual = try restored.process(second)

            XCTAssertEqual(
                try R13TightPixelFrame(capturing: actual),
                try R13TightPixelFrame(capturing: expected),
                format.description
            )
            let cancelled = try makeProcessor(
                format: format,
                configuration: temporalConfiguration
            )
            cancelled.cancel()
            XCTAssertThrowsError(
                try cancelled.process(second),
                format.description
            )
        }
    }
}

private extension R13RegisteredFormatProcessingTests {
    func makeSource(
        format: MediaVideoFormat,
        offset: Int = 0
    ) throws -> CVPixelBuffer {
        let fixture =
            try R13PixelLayoutTestFixtures.makeEffectBuffer(
                pixelFormat: format.pixelStorage.pixelFormat,
                width: sourceResolution.width,
                height: sourceResolution.height,
                offset: offset
            )
        let source = try makeDestination(
            format: format,
            resolution: sourceResolution
        )
        try R13PixelLayoutProcessor.copy(
            source: fixture,
            destination: source
        )
        R13MediaVideoFormatContract.install(
            format,
            on: source,
            resolution: sourceResolution
        )
        return source
    }

    func makeDestination(
        format: MediaVideoFormat,
        resolution: VideoResolution
    ) throws -> CVPixelBuffer {
        let pool = try PixelBufferBridge.makePool(
            width: resolution.width,
            height: resolution.height,
            format: format.pixelStorage.pixelFormat,
            capacity: 1
        )
        let destination = try PixelBufferBridge.dequeue(from: pool)
        R13MediaVideoFormatContract.install(
            format,
            on: destination,
            resolution: resolution
        )
        return destination
    }

    func assertValid(
        _ pixelBuffer: CVPixelBuffer,
        format: MediaVideoFormat,
        resolution: VideoResolution
    ) throws {
        try R13MediaVideoFormatContract.validate(
            pixelBuffer,
            resolution: resolution,
            format: format
        )
        try R13PixelLayoutProcessor.validateStoredCodes(
            pixelBuffer
        )
        XCTAssertEqual(
            CVPixelBufferGetPixelFormatType(pixelBuffer),
            format.pixelStorage.pixelFormat
        )
    }

    func process(
        _ source: CVPixelBuffer,
        format: MediaVideoFormat,
        configuration: R13PixelLayoutEnhancementConfiguration
    ) throws -> CVPixelBuffer {
        try makeProcessor(
            format: format,
            configuration: configuration
        ).process(source)
    }

    func enhancedLuma(
        _ source: CVPixelBuffer,
        format: MediaVideoFormat,
        configuration: R13PixelLayoutEnhancementConfiguration
    ) throws -> [UInt16] {
        try R13PixelLayoutTestFixtures.lumaCodes(
            process(
                source,
                format: format,
                configuration: configuration
            )
        )
    }

    func makeProcessor(
        format: MediaVideoFormat,
        configuration: R13PixelLayoutEnhancementConfiguration
    ) throws -> R13ReleaseFormatEnhancementProcessor {
        try R13ReleaseFormatEnhancementProcessor(
            targetResolution: sourceResolution,
            videoFormat: format,
            temporalConsistencyEnabled:
                configuration.temporalConsistencyEnabled,
            edgeFidelityLevel:
                configuration.edgeFidelityLevel,
            detailRecoveryLevel:
                configuration.detailRecoveryLevel,
            edgePreservationEnabled:
                configuration.edgePreservationEnabled,
            compressionCleanupEnabled:
                configuration.compressionCleanupEnabled,
            textureGrainProtectionEnabled:
                configuration.textureGrainProtectionEnabled,
            temporalStabilityEnabled:
                configuration.temporalStabilityEnabled
        )
    }

    func configuration(
        edge: MirmirAdjustmentLevel = .low,
        detail: MirmirAdjustmentLevel = .low,
        edgePreservation: Bool = false,
        compressionCleanup: Bool = false,
        textureProtection: Bool = false,
        temporalConsistency: Bool = false,
        temporalStability: Bool = false
    ) -> R13PixelLayoutEnhancementConfiguration {
        R13PixelLayoutEnhancementConfiguration(
            edgeFidelityLevel: edge,
            detailRecoveryLevel: detail,
            edgePreservationEnabled: edgePreservation,
            compressionCleanupEnabled: compressionCleanup,
            textureGrainProtectionEnabled: textureProtection,
            temporalConsistencyEnabled: temporalConsistency,
            temporalStabilityEnabled: temporalStability
        )
    }
}
