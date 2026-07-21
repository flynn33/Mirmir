import CoreVideo
import Foundation
import XCTest
@testable import Mirmir

final class R03A11NativeMPSProductTests: XCTestCase {
    func testStrictNativeMPSLanczosIsRepeatableAcrossThreeFreshSessionsForBothRoutes()
        async throws {
        for route in R03ScaleRoute.allCases {
            var logicalNV12Hashes: [String] = []
            for run in 1...3 {
                logicalNV12Hashes.append(
                    try await runStrictNativeSession(route: route, run: run)
                )
            }
            XCTAssertEqual(logicalNV12Hashes.count, 3)
            XCTAssertEqual(Set(logicalNV12Hashes).count, 1)
            XCTAssertEqual(logicalNV12Hashes.first?.count, 64)
        }
    }

    private func runStrictNativeSession(
        route: R03ScaleRoute,
        run: Int
    ) async throws -> String {
        let outputReleaseProbe = R02FixtureReleaseProbe()
        let backend = try R03DeterministicBackend.makeProductQualifiedMPSLanczos(
            route: route,
            outputReleaseObserver: { [outputReleaseProbe] identity in
                outputReleaseProbe.recordRelease(identity: identity)
            }
        )
        let configuration = try backend.makeConfiguration()
        assertConfiguration(configuration, backend: backend, route: route)

        let creation = await backend.makeSession(
            configuration: configuration,
            context: try R03A11ProductAdmission.makeProductSessionContext()
        )
        let session: any AppleUpscaleSession
        switch creation {
        case .created(let createdSession):
            session = createdSession
        case .unavailable(let unavailable):
            XCTFail(
                "Strict native MPS creation was unavailable: \(unavailable.reason)"
            )
            throw R03A11NativeMPSTestError.nativeSessionNotCreated
        case .rejected(let rejection):
            XCTFail("Strict native MPS creation was rejected: \(rejection.reason)")
            throw R03A11NativeMPSTestError.nativeSessionNotCreated
        case .failed(let failure):
            XCTFail("Strict native MPS creation failed: \(failure.reason)")
            throw R03A11NativeMPSTestError.nativeSessionNotCreated
        }

        let sessionIdentity = await session.identity
        XCTAssertEqual(sessionIdentity, backend.routeIdentity)
        let fixture = try R03DeterministicBackendTestSupport.makeInputFrame(
            route: route,
            sequenceNumber: 0,
            seed: 91,
            tokenPrefix: "r03.a11.native.\(route.rawValue).run-\(run)"
        )
        let outcome = await session.submit(fixture.frame)
        guard case .processed(let processed) = outcome else {
            XCTFail("Strict native MPS did not process \(route.rawValue) run \(run)")
            throw R03A11NativeMPSTestError.nativeFrameNotProcessed
        }

        assertProcessedFrame(
            processed,
            fixture: fixture,
            backend: backend,
            route: route
        )

        let logicalBytes = try R02FixturePixelBuffers.logicalNV12Bytes(
            from: processed.pixelBuffer
        )
        XCTAssertEqual(
            logicalBytes.count,
            route.canonicalTargetResolution.width
                * route.canonicalTargetResolution.height * 3 / 2
        )
        let logicalHash = R02FixtureGenerators.sha256Hex(logicalBytes)
        let outputTokenIdentity = processed.resourceLifetimeToken.identity
        processed.resourceLifetimeToken.release()
        processed.resourceLifetimeToken.release()
        XCTAssertEqual(outputReleaseProbe.releaseCount(for: outputTokenIdentity), 1)

        let summary = await session.finish()
        XCTAssertEqual(summary.submittedFrameCount, 1)
        XCTAssertEqual(summary.processedFrameCount, 1)
        XCTAssertEqual(summary.terminalizationCount, 1)
        return logicalHash
    }

    private func assertConfiguration(
        _ configuration: AppleUpscaleSessionConfiguration,
        backend: R03DeterministicBackend,
        route: R03ScaleRoute
    ) {
        XCTAssertEqual(configuration.capabilityID.rawValue, "A11")
        XCTAssertEqual(configuration.sourceResolution, route.canonicalSourceResolution)
        XCTAssertEqual(configuration.targetResolution, route.canonicalTargetResolution)
        XCTAssertEqual(configuration.pixelFormat, R03NV12Contract.pixelFormat)
        XCTAssertEqual(
            configuration.configurationIdentity,
            backend.routeIdentity.configurationIdentity
        )
    }

    private func assertProcessedFrame(
        _ processed: AppleUpscaleProcessedFrame,
        fixture: R03InputFrameFixture,
        backend: R03DeterministicBackend,
        route: R03ScaleRoute
    ) {
        XCTAssertEqual(processed.sequenceNumber, fixture.frame.sequenceNumber)
        XCTAssertEqual(processed.presentationTimestamp, fixture.frame.presentationTimestamp)
        XCTAssertEqual(processed.duration, fixture.frame.duration)
        XCTAssertEqual(processed.colorDescription, fixture.frame.colorDescription)
        XCTAssertEqual(processed.metadataIdentity, fixture.frame.metadataIdentity)
        XCTAssertEqual(processed.processingIdentity.route, backend.routeIdentity)
        XCTAssertTrue(processed.processingIdentity.fallbackHistory.isEmpty)
        XCTAssertEqual(
            processed.processingIdentity.route.policyIdentity,
            R03A11ProductAdmission.policyIdentity
        )
        XCTAssertEqual(
            processed.processingIdentity.route.materialDecisionIdentity,
            R03A11ProductAdmission.materialDecisionIdentity
        )
        XCTAssertEqual(
            CVPixelBufferGetWidth(processed.pixelBuffer),
            route.canonicalTargetResolution.width
        )
        XCTAssertEqual(
            CVPixelBufferGetHeight(processed.pixelBuffer),
            route.canonicalTargetResolution.height
        )
        XCTAssertEqual(CVPixelBufferGetPlaneCount(processed.pixelBuffer), 2)
        XCTAssertEqual(
            CVPixelBufferGetPixelFormatType(processed.pixelBuffer),
            R03NV12Contract.pixelFormat
        )
        XCTAssertNoThrow(
            try R03NV12Contract.validate(
                pixelBuffer: processed.pixelBuffer,
                resolution: route.canonicalTargetResolution
            )
        )
        XCTAssertEqual(
            fixture.releaseProbe.releaseCount(for: fixture.tokenIdentity),
            1
        )
    }
}

private enum R03A11NativeMPSTestError: Error {
    case nativeSessionNotCreated
    case nativeFrameNotProcessed
}
