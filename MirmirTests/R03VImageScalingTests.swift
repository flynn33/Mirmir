import Accelerate
import CoreVideo
import XCTest
@testable import Mirmir

final class R03VImageScalingTests: XCTestCase {
    func testModesBindExactPreregisteredIdentitiesAndVImageFlags() {
        XCTAssertEqual(
            R03VImageScalingMode.lanczos3.subjectID,
            .vImageLanczos3
        )
        XCTAssertEqual(
            R03VImageScalingMode.lanczos3.flags,
            vImage_Flags(kvImageEdgeExtend)
        )
        XCTAssertEqual(
            R03VImageScalingMode.lanczos5.subjectID,
            .vImageLanczos5
        )
        XCTAssertEqual(
            R03VImageScalingMode.lanczos5.flags,
            vImage_Flags(kvImageEdgeExtend | kvImageHighQualityResampling)
        )
    }

    func testBothModesAreRepeatableAcrossFreshSessionsForBothExactRoutes() async throws {
        for mode in R03VImageScalingMode.allCases {
            for route in R03ScaleRoute.allCases {
                let first = try await runOnce(mode: mode, route: route, run: 1)
                let second = try await runOnce(mode: mode, route: route, run: 2)
                XCTAssertEqual(
                    first,
                    second,
                    "Non-repeatable logical NV12 output for \(mode.rawValue) \(route.rawValue)"
                )
                XCTAssertEqual(
                    first.count,
                    route.canonicalTargetResolution.width
                        * route.canonicalTargetResolution.height
                        * 3 / 2
                )
            }
        }
    }

    func testStandardVImageScalesArbitraryGreaterGeometry() throws {
        let plan = try R13AdaptiveScalePlan(
            sourceResolution: VideoResolution(width: 64, height: 36),
            targetResolution: VideoResolution(width: 160, height: 90)
        )
        let source = try R13ReleaseTestFrames.makeOutput(
            resolution: plan.processingSourceResolution
        )
        let destination = try R13ReleaseTestFrames.makeOutput(
            resolution: plan.targetResolution
        )
        let scaler = R03VImageScaler(
            mode: .lanczos3,
            adaptivePlan: plan
        )

        try scaler.scale(
            source: source,
            destination: destination,
            cancellation: AppleUpscaleOperationCancellationSignal()
        )

        XCTAssertNil(scaler.route)
        XCTAssertNoThrow(
            try R03NV12Contract.validate(
                pixelBuffer: destination,
                resolution: plan.targetResolution
            )
        )
    }

    private func runOnce(
        mode: R03VImageScalingMode,
        route: R03ScaleRoute,
        run: Int
    ) async throws -> Data {
        let outputReleaseProbe = R02FixtureReleaseProbe()
        let backend = try R03DeterministicBackend.makeVImage(
            mode: mode,
            route: route,
            outputReleaseObserver: { [outputReleaseProbe] identity in
                outputReleaseProbe.recordRelease(identity: identity)
            }
        )
        let session = try await R03DeterministicBackendTestSupport.makeSession(
            backend: backend
        )
        let fixture = try R03DeterministicBackendTestSupport.makeInputFrame(
            route: route,
            sequenceNumber: 0,
            seed: 73,
            tokenPrefix: "r03.vimage.\(mode.rawValue).\(route.rawValue).\(run)"
        )

        let outcome = await session.submit(fixture.frame)
        guard case .processed(let processed) = outcome else {
            throw R03DeterministicBackendTestSupportError.sessionNotCreated
        }
        let sessionIdentity = await session.identity
        XCTAssertEqual(sessionIdentity, backend.routeIdentity)
        XCTAssertEqual(processed.processingIdentity.route, backend.routeIdentity)
        XCTAssertTrue(processed.processingIdentity.fallbackHistory.isEmpty)
        XCTAssertEqual(
            CVPixelBufferGetWidth(processed.pixelBuffer),
            route.canonicalTargetResolution.width
        )
        XCTAssertEqual(
            CVPixelBufferGetHeight(processed.pixelBuffer),
            route.canonicalTargetResolution.height
        )
        XCTAssertEqual(CVPixelBufferGetPlaneCount(processed.pixelBuffer), 2)
        XCTAssertNoThrow(
            try R03NV12Contract.validate(
                pixelBuffer: processed.pixelBuffer,
                resolution: route.canonicalTargetResolution
            )
        )
        XCTAssertEqual(processed.colorDescription, fixture.frame.colorDescription)
        XCTAssertEqual(processed.metadataIdentity, fixture.frame.metadataIdentity)
        XCTAssertEqual(processed.presentationTimestamp, fixture.frame.presentationTimestamp)
        XCTAssertEqual(processed.duration, fixture.frame.duration)
        XCTAssertEqual(
            fixture.releaseProbe.releaseCount(for: fixture.tokenIdentity),
            1
        )

        let logicalBytes = try R02FixturePixelBuffers.logicalNV12Bytes(
            from: processed.pixelBuffer
        )
        let outputTokenIdentity = processed.resourceLifetimeToken.identity
        processed.resourceLifetimeToken.release()
        XCTAssertEqual(outputReleaseProbe.releaseCount(for: outputTokenIdentity), 1)
        let summary = await session.finish()
        XCTAssertEqual(summary.submittedFrameCount, 1)
        XCTAssertEqual(summary.processedFrameCount, 1)
        XCTAssertEqual(summary.terminalizationCount, 1)
        return logicalBytes
    }
}
