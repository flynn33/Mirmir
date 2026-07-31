import CoreVideo
import XCTest
@testable import Mirmir

final class R13ProductASHAnalyzerTests: XCTestCase {
    func testAnalyzerBuildsExactProductDecisionContextFromNV12()
        async throws {
        let analyzer = R13ProductASHAnalyzer()
        let frame = try makeNV12Frame(luma: 96, cb: 112, cr: 144)

        let result = try await analyzer.analyze(
            pixelBuffer: R13ProductASHPixelBuffer(value: frame),
            frameIdentifier: "job.frame.0",
            streamIdentifier: "job",
            route: .scale2x,
            dwellFrames: 0,
            currentBackendID: nil,
            previousBackendID: nil,
            processingConfiguration: .default,
            resources: .nominal
        )

        XCTAssertTrue(result.featureState.hasValidIntegrity)
        XCTAssertEqual(
            result.decisionContext.continuousFeatureValuesQ16.count,
            ASHState.payloadBitCount
        )
        XCTAssertEqual(result.decisionContext.frameID, "job.frame.0")
        XCTAssertEqual(result.decisionContext.shotID, "job.shot.0")
        XCTAssertEqual(result.decisionContext.routeID, "scale_2x")
        XCTAssertEqual(result.decisionContext.scaleNumerator, 2)
        XCTAssertEqual(result.decisionContext.scaleDenominator, 1)
        XCTAssertEqual(
            result.decisionContext.sceneCutConfidenceQ16,
            .zero
        )
        XCTAssertEqual(
            result.decisionContext.motionConfidenceQ16,
            .zero
        )
        XCTAssertNoThrow(
            try R06ASHStateTransition(
                previousState:
                    result.decisionContext.previousState,
                currentState:
                    result.decisionContext.currentState
            )
        )
    }

    func testLargeTemporalChangeCreatesSceneBoundaryAndNewShot()
        async throws {
        let analyzer = R13ProductASHAnalyzer()
        _ = try await analyzer.analyze(
            pixelBuffer: R13ProductASHPixelBuffer(
                value: try makeNV12Frame(luma: 16)
            ),
            frameIdentifier: "job.frame.0",
            streamIdentifier: "job",
            route: .scale3Over2,
            dwellFrames: 0,
            currentBackendID: nil,
            previousBackendID: nil,
            processingConfiguration: .default,
            resources: .nominal
        )

        let changed = try await analyzer.analyze(
            pixelBuffer: R13ProductASHPixelBuffer(
                value: try makeNV12Frame(luma: 235)
            ),
            frameIdentifier: "job.frame.1",
            streamIdentifier: "job",
            route: .scale3Over2,
            dwellFrames: 1,
            currentBackendID: "product.apple.first",
            previousBackendID: nil,
            processingConfiguration: .default,
            resources: .nominal
        )

        XCTAssertGreaterThanOrEqual(
            changed.decisionContext.sceneCutConfidenceQ16.rawValue,
            R06ASHParameters.frozen.thresholds
                .sceneCutConfidenceQ16
        )
        XCTAssertEqual(changed.decisionContext.shotID, "job.shot.1")
        XCTAssertEqual(
            changed.decisionContext.currentBackendID,
            "product.apple.first"
        )
    }

    func testResetClearsTemporalHistoryAndShotOrdinal() async throws {
        let analyzer = R13ProductASHAnalyzer()
        _ = try await analyzer.analyze(
            pixelBuffer: R13ProductASHPixelBuffer(
                value: try makeNV12Frame(luma: 16)
            ),
            frameIdentifier: "job.frame.0",
            streamIdentifier: "job",
            route: .scale2x,
            dwellFrames: 0,
            currentBackendID: nil,
            previousBackendID: nil,
            processingConfiguration: .default,
            resources: .nominal
        )
        _ = try await analyzer.analyze(
            pixelBuffer: R13ProductASHPixelBuffer(
                value: try makeNV12Frame(luma: 235)
            ),
            frameIdentifier: "job.frame.1",
            streamIdentifier: "job",
            route: .scale2x,
            dwellFrames: 1,
            currentBackendID: nil,
            previousBackendID: nil,
            processingConfiguration: .default,
            resources: .nominal
        )

        await analyzer.reset()
        let reset = try await analyzer.analyze(
            pixelBuffer: R13ProductASHPixelBuffer(
                value: try makeNV12Frame(luma: 235)
            ),
            frameIdentifier: "job.frame.0",
            streamIdentifier: "job",
            route: .scale2x,
            dwellFrames: 0,
            currentBackendID: nil,
            previousBackendID: nil,
            processingConfiguration: .default,
            resources: .nominal
        )

        XCTAssertEqual(reset.decisionContext.shotID, "job.shot.0")
        XCTAssertEqual(
            reset.decisionContext.sceneCutConfidenceQ16,
            .zero
        )
    }

    func testAnalyzerAcceptsFullRange420AndUsesNV12PlaneLayout()
        async throws {
        let analyzer = R13ProductASHAnalyzer()
        let frame = try makeNV12Frame(
            luma: 96,
            pixelFormat:
                kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        )

        let result = try await analyzer.analyze(
            pixelBuffer: R13ProductASHPixelBuffer(value: frame),
            frameIdentifier: "job.frame.0",
            streamIdentifier: "job",
            route: .scale2x,
            dwellFrames: 0,
            currentBackendID: nil,
            previousBackendID: nil,
            processingConfiguration: .default,
            resources: .nominal
        )

        XCTAssertTrue(result.featureState.hasValidIntegrity)
        XCTAssertEqual(result.decisionContext.planeLayout, .nv12)
    }

    func testAnalyzerAcceptsEveryRegisteredPixelLayout()
        async throws {
        for storage in MediaVideoPixelStorage.allCases {
            let pixelFormat = storage.pixelFormat
            let layout = try R13PixelLayoutRegistry.layout(
                for: pixelFormat
            )
            let width = max(8, layout.requiredWidthMultiple * 4)
            let height = max(8, layout.requiredHeightMultiple * 4)
            let frame =
                try R13PixelLayoutTestFixtures.makeGradientBuffer(
                    pixelFormat: pixelFormat,
                    width: width,
                    height: height
                )
            let analyzer = R13ProductASHAnalyzer()
            let result = try await analyzer.analyze(
                pixelBuffer: R13ProductASHPixelBuffer(
                    value: frame
                ),
                frameIdentifier: "registry.frame",
                streamIdentifier: "registry",
                route: .scale2x,
                dwellFrames: 0,
                currentBackendID: nil,
                previousBackendID: nil,
                processingConfiguration: .default,
                resources: .nominal
            )

            XCTAssertTrue(
                result.featureState.hasValidIntegrity,
                "format \(pixelFormat)"
            )
            XCTAssertNotEqual(
                result.decisionContext.continuousFeatureValuesQ16,
                [],
                "format \(pixelFormat)"
            )
            XCTAssertEqual(
                result.decisionContext.planeLayout,
                expectedPlaneLayout(storage),
                "format \(storage.rawValue)"
            )
        }
    }

    func testAnalyzerBuildsExactAdaptiveContextsForP010AndBGRA()
        async throws {
        let source = VideoResolution(width: 64, height: 36)
        let target = VideoResolution(width: 160, height: 90)
        let plan = try R13AdaptiveScalePlan(
            sourceResolution: source,
            targetResolution: target
        )
        let cases: [(
            format: MediaVideoFormat,
            expectedLayout: R06ASHPlaneLayout
        )] = [
            (
                .hdrBT2020PQ(
                    masteringDisplayColorVolume:
                        Data((0..<24).map(UInt8.init)),
                    contentLightLevelInfo:
                        Data([0x01, 0x02, 0x03, 0x04])
                ),
                .p010
            ),
            (
                .sdrBT709WithAlpha(mode: .straight),
                .bgra
            )
        ]

        for (ordinal, testCase) in cases.enumerated() {
            let analyzer = R13ProductASHAnalyzer()
            let frame = try makeExtendedFrame(
                resolution: source,
                format: testCase.format
            )
            let result = try await analyzer.analyze(
                pixelBuffer: R13ProductASHPixelBuffer(
                    value: frame
                ),
                frameIdentifier:
                    "adaptive.frame.\(ordinal)",
                streamIdentifier: "adaptive",
                scale: R13ProductASHScaleContext(
                    adaptivePlan: plan,
                    routeID: "adaptive_test"
                ),
                dwellFrames: 0,
                currentBackendID: nil,
                previousBackendID: nil,
                processingConfiguration: .default,
                resources: .nominal
            )

            XCTAssertTrue(result.featureState.hasValidIntegrity)
            XCTAssertEqual(
                result.decisionContext.planeLayout,
                testCase.expectedLayout
            )
            XCTAssertEqual(
                result.decisionContext.routeID,
                "adaptive_test"
            )
            XCTAssertEqual(
                result.decisionContext.scaleNumerator,
                5
            )
            XCTAssertEqual(
                result.decisionContext.scaleDenominator,
                2
            )
            XCTAssertEqual(
                result.decisionContext
                    .continuousFeatureValuesQ16.count,
                ASHState.payloadBitCount
            )
        }
    }

    private func makeNV12Frame(
        luma: UInt8,
        cb: UInt8 = 128,
        cr: UInt8 = 128,
        pixelFormat: OSType =
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    ) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ] as CFDictionary
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            64,
            36,
            pixelFormat,
            attributes,
            &buffer
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        let pixelBuffer = try XCTUnwrap(buffer)
        XCTAssertEqual(
            CVPixelBufferLockBaseAddress(pixelBuffer, []),
            kCVReturnSuccess
        )
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        }

        let lumaWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let lumaHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(
            pixelBuffer,
            0
        )
        let lumaBase = try XCTUnwrap(
            CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)
        ).assumingMemoryBound(to: UInt8.self)
        for row in 0..<lumaHeight {
            lumaBase.advanced(by: row * lumaStride)
                .initialize(repeating: luma, count: lumaWidth)
        }

        let chromaWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
        let chromaHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(
            pixelBuffer,
            1
        )
        let chromaBase = try XCTUnwrap(
            CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)
        ).assumingMemoryBound(to: UInt8.self)
        for row in 0..<chromaHeight {
            let rowBase = chromaBase.advanced(by: row * chromaStride)
            for column in 0..<chromaWidth {
                rowBase[column * 2] = cb
                rowBase[column * 2 + 1] = cr
            }
        }
        return pixelBuffer
    }

    private func makeExtendedFrame(
        resolution: VideoResolution,
        format: MediaVideoFormat
    ) throws -> CVPixelBuffer {
        let pixelBuffer =
            try R13PixelLayoutTestFixtures.makeGradientBuffer(
                pixelFormat: format.pixelStorage.pixelFormat,
                width: resolution.width,
                height: resolution.height
            )
        R13MediaVideoFormatContract.install(
            format,
            on: pixelBuffer,
            resolution: resolution
        )
        return pixelBuffer
    }

    func expectedPlaneLayout(
        _ storage: MediaVideoPixelStorage
    ) -> R06ASHPlaneLayout {
        switch storage {
        case .nv12VideoRange8Bit, .nv12FullRange8Bit:
            return .nv12
        case .p010VideoRange10Bit, .p010FullRange10Bit:
            return .p010
        case .yuv422VideoRange8Bit, .yuv422FullRange8Bit:
            return .yuv422BiPlanar8
        case .yuv422VideoRange10Bit, .yuv422FullRange10Bit:
            return .yuv422BiPlanar10
        case .yuv422VideoRange16Bit:
            return .yuv422BiPlanar16
        case .yuv444VideoRange8Bit, .yuv444FullRange8Bit:
            return .yuv444BiPlanar8
        case .yuv444VideoRange10Bit, .yuv444FullRange10Bit:
            return .yuv444BiPlanar10
        case .yuv444VideoRange16Bit:
            return .yuv444BiPlanar16
        case .yuv444VideoRange8BitWithAlpha:
            return .aycbcrPacked8Alpha
        case .yuv444VideoRange16BitWithAlpha:
            return .aycbcrPacked16Alpha
        case .yuv444VideoRange16BitWithAlphaTriPlanar:
            return .yuv444TriPlanar16Alpha
        case .bgra8WithAlpha:
            return .bgra
        }
    }
}
