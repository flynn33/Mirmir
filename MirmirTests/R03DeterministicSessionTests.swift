import CoreVideo
import XCTest
@testable import Mirmir

final class R03DeterministicSessionTests: XCTestCase {
    func testFixtureSessionPreservesFrameIdentityAndExactlyOnceLifetime() async throws {
        let outputReleaseProbe = R02FixtureReleaseProbe()
        let backend = try R03DeterministicBackend.makeVImage(
            mode: .lanczos3,
            route: .scale3Over2,
            outputReleaseObserver: { [outputReleaseProbe] identity in
                outputReleaseProbe.recordRelease(identity: identity)
            }
        )
        let session = try await R03DeterministicBackendTestSupport.makeSession(
            backend: backend
        )
        let fixture = try R03DeterministicBackendTestSupport.makeInputFrame(
            route: .scale3Over2,
            sequenceNumber: 7
        )

        let outcome = await session.submit(fixture.frame)
        guard case .processed(let processed) = outcome else {
            return XCTFail("Expected the fixture-only vImage session to process the frame")
        }

        XCTAssertEqual(processed.sequenceNumber, fixture.frame.sequenceNumber)
        XCTAssertEqual(processed.presentationTimestamp, fixture.frame.presentationTimestamp)
        XCTAssertEqual(processed.duration, fixture.frame.duration)
        XCTAssertEqual(processed.colorDescription, fixture.frame.colorDescription)
        XCTAssertEqual(processed.metadataIdentity, fixture.frame.metadataIdentity)
        XCTAssertEqual(processed.processingIdentity.route, backend.routeIdentity)
        XCTAssertTrue(processed.processingIdentity.fallbackHistory.isEmpty)
        XCTAssertEqual(CVPixelBufferGetWidth(processed.pixelBuffer), 1_920)
        XCTAssertEqual(CVPixelBufferGetHeight(processed.pixelBuffer), 1_080)
        XCTAssertEqual(
            CVPixelBufferGetPixelFormatType(processed.pixelBuffer),
            R03NV12Contract.pixelFormat
        )
        XCTAssertNoThrow(
            try R03NV12Contract.validate(
                pixelBuffer: processed.pixelBuffer,
                resolution: .p1080
            )
        )
        XCTAssertEqual(
            fixture.releaseProbe.releaseCount(for: fixture.tokenIdentity),
            1
        )

        let outputTokenIdentity = processed.resourceLifetimeToken.identity
        processed.resourceLifetimeToken.release()
        processed.resourceLifetimeToken.release()
        XCTAssertEqual(outputReleaseProbe.releaseCount(for: outputTokenIdentity), 1)

        let summary = await session.finish()
        XCTAssertEqual(summary.submittedFrameCount, 1)
        XCTAssertEqual(summary.processedFrameCount, 1)
        XCTAssertEqual(summary.terminalizationCount, 1)
    }

    func testSessionCreationUsesTypedRejectionAndUnavailabilityWithoutFallback() async throws {
        let backend = try R03DeterministicBackend.makeVImage(
            mode: .lanczos5,
            route: .scale2x
        )
        let validConfiguration = try backend.makeConfiguration()
        let validCapability = try R03DeterministicBackendCatalog.makeFixtureCapability(
            for: .vImageLanczos3
        )
        let fixtureContext = try R03DeterministicBackendTestSupport.makeContext(
            subjectID: .vImageLanczos5,
            capability: validCapability
        )

        let wrongRouteConfiguration = try AppleUpscaleSessionConfiguration(
            capabilityID: backend.capabilityID,
            sourceResolution: VideoResolution(width: 16, height: 8),
            targetResolution: VideoResolution(width: 32, height: 16),
            pixelFormat: R03NV12Contract.pixelFormat,
            configurationIdentity: backend.routeIdentity.configurationIdentity
        )
        assertCreationRejected(
            await backend.makeSession(
                configuration: wrongRouteConfiguration,
                context: fixtureContext
            ),
            route: backend.routeIdentity
        )

        let productContext = try R03DeterministicBackendTestSupport.makeContext(
            subjectID: .vImageLanczos5,
            admissionScope: .product,
            capability: validCapability
        )
        assertCreationRejected(
            await backend.makeSession(
                configuration: validConfiguration,
                context: productContext
            ),
            route: backend.routeIdentity
        )

        let notObservedCapability = try R03DeterministicBackendCatalog
            .makeNotObservedCapability(for: .vImageLanczos5)
        let notObservedContext = try R03DeterministicBackendTestSupport.makeContext(
            subjectID: .vImageLanczos5,
            capability: notObservedCapability
        )
        assertCreationUnavailable(
            await backend.makeSession(
                configuration: validConfiguration,
                context: notObservedContext
            ),
            route: backend.routeIdentity
        )

        let productQualifiedCapability = try AppleUpscaleCapability(
            id: backend.capabilityID,
            role: .primaryScaler,
            frameworkIdentity: "Accelerate",
            observationStatus: .observed,
            runtimeDisposition: .runnable,
            backendEligibility: .productQualified
        )
        let productQualifiedContext = try R03DeterministicBackendTestSupport.makeContext(
            subjectID: .vImageLanczos5,
            capability: productQualifiedCapability
        )
        assertCreationRejected(
            await backend.makeSession(
                configuration: validConfiguration,
                context: productQualifiedContext
            ),
            route: backend.routeIdentity
        )
    }

    func testInvalidFrameIsRejectedAndInputTokenReleasesExactlyOnce() async throws {
        let backend = try R03DeterministicBackend.makeVImage(
            mode: .lanczos3,
            route: .scale3Over2
        )
        let session = try await R03DeterministicBackendTestSupport.makeSession(
            backend: backend
        )
        let fixture = try R03DeterministicBackendTestSupport.makeInputFrame(
            route: .scale3Over2,
            sequenceNumber: 0
        )
        CVBufferRemoveAttachment(
            fixture.frame.pixelBuffer,
            kCVImageBufferChromaLocationBottomFieldKey
        )

        let outcome = await session.submit(fixture.frame)
        guard case .rejected(let rejection) = outcome else {
            return XCTFail("Expected an exact NV12 contract rejection")
        }
        XCTAssertEqual(rejection.reason, "r03_frame_contract_mismatch")
        XCTAssertEqual(rejection.processingIdentity.route, backend.routeIdentity)
        XCTAssertTrue(rejection.processingIdentity.fallbackHistory.isEmpty)
        XCTAssertEqual(
            fixture.releaseProbe.releaseCount(for: fixture.tokenIdentity),
            1
        )
        _ = await session.finish()
    }

    func testScalerFailureIsTypedAndInputTokenReleasesExactlyOnce() async throws {
        let backend = try R03DeterministicBackend(
            subjectID: .vImageLanczos3,
            route: .scale3Over2,
            scalerFactory: { _, _ in R03AlwaysFailingScaler() }
        )
        let session = try await R03DeterministicBackendTestSupport.makeSession(
            backend: backend
        )
        let fixture = try R03DeterministicBackendTestSupport.makeInputFrame(
            route: .scale3Over2,
            sequenceNumber: 0
        )

        let outcome = await session.submit(fixture.frame)
        guard case .failed(let failure) = outcome else {
            return XCTFail("Expected a typed scaling failure")
        }
        XCTAssertEqual(failure.reason, "r03_scaling_failed")
        XCTAssertEqual(failure.processingIdentity.route, backend.routeIdentity)
        XCTAssertTrue(failure.processingIdentity.fallbackHistory.isEmpty)
        XCTAssertEqual(
            fixture.releaseProbe.releaseCount(for: fixture.tokenIdentity),
            1
        )
        _ = await session.finish()
    }

    private func assertCreationRejected(
        _ outcome: AppleUpscaleSessionCreationOutcome,
        route: AppleUpscaleRouteIdentity,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .rejected(let rejection) = outcome else {
            return XCTFail("Expected session rejection", file: file, line: line)
        }
        XCTAssertEqual(rejection.processingIdentity.route, route, file: file, line: line)
        XCTAssertTrue(rejection.processingIdentity.fallbackHistory.isEmpty)
    }

    private func assertCreationUnavailable(
        _ outcome: AppleUpscaleSessionCreationOutcome,
        route: AppleUpscaleRouteIdentity,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .unavailable(let unavailable) = outcome else {
            return XCTFail("Expected session unavailability", file: file, line: line)
        }
        XCTAssertEqual(unavailable.processingIdentity.route, route, file: file, line: line)
        XCTAssertTrue(unavailable.processingIdentity.fallbackHistory.isEmpty)
    }
}

private final class R03AlwaysFailingScaler: R03NV12Scaling, @unchecked Sendable {
    func scale(
        source _: CVPixelBuffer,
        destination _: CVPixelBuffer,
        cancellation _: AppleUpscaleOperationCancellationSignal
    ) throws {
        throw R03NV12ScalingError.scalingFailed(plane: 0, status: -1)
    }
}
