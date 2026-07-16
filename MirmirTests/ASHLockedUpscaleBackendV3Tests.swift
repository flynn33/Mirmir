import CoreVideo
import XCTest
@testable import Mirmir

final class ASHLockedUpscaleBackendV3Tests: XCTestCase {
    @available(macOS 15.4, *)
    func testBothRoutesProduceDeterministicLockedOutputAndResetDiagnostics() async throws {
        let artifacts = try await ASHLockedReleaseTestSupportV3.artifacts()

        for route in [ASHSpatialRouteV2.direct2x, .direct3Over2] {
            let source = try makePixelBuffer(width: 8, height: 4)
            fill(source)
            let destinationWidth = try route.destinationExtent(for: 8)
            let destinationHeight = try route.destinationExtent(for: 4)
            let firstDestination = try makePixelBuffer(
                width: destinationWidth,
                height: destinationHeight
            )
            let secondDestination = try makePixelBuffer(
                width: destinationWidth,
                height: destinationHeight
            )
            let backend = try ASHLockedUpscaleBackendV3(
                route: route,
                artifacts: artifacts
            )

            try await backend.process(source: source, into: firstDestination)
            let firstSummary = try XCTUnwrap(backend.lastDebugSummary)
            try await backend.process(source: source, into: secondDestination)
            let secondSummary = try XCTUnwrap(backend.lastDebugSummary)

            XCTAssertEqual(
                try ASHNV12FrameCodec.extract(from: firstDestination),
                try ASHNV12FrameCodec.extract(from: secondDestination)
            )
            XCTAssertEqual(firstSummary, secondSummary)
            XCTAssertEqual(firstSummary.route, route)
            XCTAssertEqual(firstSummary.constructionCounters.analyzerTraversalCount, 1)
            XCTAssertEqual(firstSummary.constructionCounters.dispatchGridConstructionCount, 2)
            XCTAssertLessThanOrEqual(firstSummary.maximumOperatorEvaluations, 2)
            XCTAssertEqual(firstSummary.temporalStateCount, 0)

            backend.reset()
            XCTAssertNil(backend.lastDebugSummary)
        }
    }

    @available(macOS 15.4, *)
    func testFactoryLoadsArtifactSetOnceAndNeverDuringFrameProcessing() async throws {
        let fixture = try ASHLockedReleaseTestSupportV3.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = ASHLockedArtifactStoreV3(resourceRoot: fixture.root)
        let factory = ASHLockedUpscaleBackendFactoryV3(artifactStore: store)
        let first = try await factory.makeBackend(
            route: .direct2x,
            telemetry: ASHNoopTelemetryRecorder.shared
        )
        let second = try await factory.makeBackend(
            route: .direct3Over2,
            telemetry: ASHNoopTelemetryRecorder.shared
        )

        let source = try makePixelBuffer(width: 8, height: 4)
        fill(source)
        try await first.process(
            source: source,
            into: makePixelBuffer(width: 16, height: 8)
        )
        try await second.process(
            source: source,
            into: makePixelBuffer(width: 12, height: 6)
        )

        let diagnostics = await store.diagnostics()
        XCTAssertEqual(
            diagnostics,
            ASHLockedArtifactStoreDiagnosticsV3(
                loadAttemptCount: 1,
                publicationCount: 1
            )
        )
    }

    @available(macOS 15.4, *)
    func testMappingRangeAndSitingMismatchRejectBeforeDestinationMutation() async throws {
        let artifacts = try await ASHLockedReleaseTestSupportV3.artifacts()
        let backend = try ASHLockedUpscaleBackendV3(
            route: .direct2x,
            artifacts: artifacts
        )

        let fullRangeSource = try makePixelBuffer(
            width: 8,
            height: 4,
            format: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        )
        fill(fullRangeSource)
        let rangeDestination = try makePixelBuffer(width: 16, height: 8)
        fill(rangeDestination)
        let rangeBefore = try ASHNV12FrameCodec.extract(from: rangeDestination)

        await XCTAssertThrowsErrorAsync {
            try await backend.process(
                source: fullRangeSource,
                into: rangeDestination
            )
        }
        XCTAssertEqual(
            try ASHNV12FrameCodec.extract(from: rangeDestination),
            rangeBefore
        )
        XCTAssertNil(backend.lastDebugSummary)

        let centerSource = try makePixelBuffer(
            width: 8,
            height: 4,
            chromaLocation: kCVImageBufferChromaLocation_Center
        )
        fill(centerSource)
        let sitingDestination = try makePixelBuffer(width: 16, height: 8)
        fill(sitingDestination)
        let sitingBefore = try ASHNV12FrameCodec.extract(from: sitingDestination)

        await XCTAssertThrowsErrorAsync {
            try await backend.process(source: centerSource, into: sitingDestination)
        }
        XCTAssertEqual(
            try ASHNV12FrameCodec.extract(from: sitingDestination),
            sitingBefore
        )
        XCTAssertNil(backend.lastDebugSummary)
    }

    private func makePixelBuffer(
        width: Int,
        height: Int,
        format: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        chromaLocation: CFString = kCVImageBufferChromaLocation_Left
    ) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            format,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw UpscalerEngineError.strategyFailed(
                "test pixel-buffer allocation failed with status \(status)"
            )
        }
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferChromaLocationTopFieldKey,
            chromaLocation,
            .shouldPropagate
        )
        return pixelBuffer
    }

    private func fill(_ pixelBuffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        for plane in 0..<CVPixelBufferGetPlaneCount(pixelBuffer) {
            let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
            guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane) else {
                continue
            }
            let pointer = base.assumingMemoryBound(to: UInt8.self)
            for row in 0..<height {
                for column in 0..<stride {
                    pointer[(row * stride) + column] = UInt8(
                        (plane * 67 + row * 23 + column * 11 + 16) % 220
                    )
                }
            }
        }
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        // Expected.
    }
}
