import CoreVideo
import XCTest
@testable import Mirmir

final class R03MPSCoreImageScalingTests: XCTestCase {
    func testModesBindExactPreregisteredSubjectsAndBackendIdentities() throws {
        XCTAssertEqual(
            R03MPSScalingMode.allCases.map(\.rawValue),
            ["r03.mps.lanczos", "r03.mps.bilinear"]
        )
        XCTAssertEqual(R03MPSScalingMode.lanczos.subjectID, .mpsLanczos)
        XCTAssertEqual(R03MPSScalingMode.bilinear.subjectID, .mpsBilinear)
        XCTAssertEqual(
            R03CoreImageScalingMode.allCases.map(\.rawValue),
            ["r03.core-image.lanczos", "r03.core-image.bicubic"]
        )
        XCTAssertEqual(R03CoreImageScalingMode.lanczos.subjectID, .coreImageLanczos)
        XCTAssertEqual(R03CoreImageScalingMode.bicubic.subjectID, .coreImageBicubic)

        for mode in R03MPSScalingMode.allCases {
            let backend = try R03DeterministicBackend.makeMPS(
                mode: mode,
                route: .scale3Over2
            )
            assertBackendIdentity(backend, subjectID: mode.subjectID)
        }
        for mode in R03CoreImageScalingMode.allCases {
            let backend = try R03DeterministicBackend.makeCoreImage(
                mode: mode,
                route: .scale3Over2
            )
            assertBackendIdentity(backend, subjectID: mode.subjectID)
        }
    }

    func testMPSModesExecuteOneFrameRepeatablyOrReportTypedRuntimeUnavailability() async throws {
        for mode in R03MPSScalingMode.allCases {
            let first = try await runMPSOnce(mode: mode, run: 1)
            let second = try await runMPSOnce(mode: mode, run: 2)
            switch (first, second) {
            case (.processed(let firstBytes), .processed(let secondBytes)):
                XCTAssertEqual(firstBytes, secondBytes, mode.rawValue)
            case (.runtimeUnavailable, .runtimeUnavailable):
                break
            default:
                XCTFail("MPS runtime disposition changed between identical runs: \(mode.rawValue)")
            }
        }
    }

    func testAdaptiveMPSLanczosExecutesDimensionBoundGeometryOrReportsTypedRuntimeUnavailability()
        throws {
        let plan = try R13AdaptiveScalePlan(
            sourceResolution: VideoResolution(width: 64, height: 36),
            targetResolution: VideoResolution(width: 128, height: 72)
        )
        let scaler: R03MPSScaler
        do {
            scaler = try R03MPSScaler(
                mode: .lanczos,
                adaptivePlan: plan
            )
        } catch R03NV12ScalingError.runtimeUnavailable {
            return
        }
        let source = try R13ReleaseTestFrames.makeOutput(
            resolution: plan.processingSourceResolution
        )
        let destination = try R13ReleaseTestFrames.makeOutput(
            resolution: plan.targetResolution
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

    func testAdaptiveMPSPreflightReportsHardwareTextureLimitAndGeometry()
        throws {
        let source = VideoResolution(width: 4_096, height: 2_304)
        let target = VideoResolution(width: 8_192, height: 4_608)

        XCTAssertThrowsError(
            try R03MPSScaler.validateTextureDimensions(
                sourceResolution: source,
                targetResolution: target,
                maximumTextureDimension2D: 4_096
            )
        ) { error in
            XCTAssertEqual(
                error as? R03MPSTextureDimensionLimitError,
                R03MPSTextureDimensionLimitError(
                    maximumTextureDimension2D: 4_096,
                    sourceResolution: source,
                    targetResolution: target
                )
            )
        }
        XCTAssertNoThrow(
            try R03MPSScaler.validateTextureDimensions(
                sourceResolution: source,
                targetResolution: target,
                maximumTextureDimension2D: 8_192
            )
        )
    }

    func testCoreImageModesExecuteOneFrameRepeatably() async throws {
        for mode in R03CoreImageScalingMode.allCases {
            let first = try await runCoreImageOnce(mode: mode, run: 1)
            let second = try await runCoreImageOnce(mode: mode, run: 2)
            XCTAssertEqual(first, second, mode.rawValue)
        }
    }

    func testInvalidInputIsRejectedBeforeMPSOrCoreImageScaling() async throws {
        let mpsBackend = try R03DeterministicBackend.makeMPS(
            mode: .lanczos,
            route: .scale3Over2
        )
        try await assertInvalidInputRejected(
            by: mpsBackend,
            runtimeUnavailablePermitted: true
        )

        let coreImageBackend = try R03DeterministicBackend.makeCoreImage(
            mode: .lanczos,
            route: .scale3Over2
        )
        try await assertInvalidInputRejected(
            by: coreImageBackend,
            runtimeUnavailablePermitted: false
        )
    }

    private enum MPSExecutionResult {
        case processed(Data)
        case runtimeUnavailable
    }

    private enum TestError: Error {
        case unexpectedCreationOutcome
        case unexpectedFrameOutcome
    }

    private func runMPSOnce(
        mode: R03MPSScalingMode,
        run: Int
    ) async throws -> MPSExecutionResult {
        let backend = try R03DeterministicBackend.makeMPS(
            mode: mode,
            route: .scale3Over2
        )
        let creation = await backend.makeSession(
            configuration: try backend.makeConfiguration(),
            context: try R03DeterministicBackendTestSupport.makeContext(
                subjectID: mode.subjectID
            )
        )
        switch creation {
        case .created(let session):
            return .processed(
                try await runOneFrame(
                    session: session,
                    backend: backend,
                    tokenPrefix: "r03.mps.\(mode.rawValue).\(run)"
                )
            )
        case .unavailable(let unavailable):
            XCTAssertEqual(unavailable.reason, "r03_capability_unavailable")
            XCTAssertEqual(unavailable.processingIdentity.route, backend.routeIdentity)
            XCTAssertTrue(unavailable.processingIdentity.fallbackHistory.isEmpty)
            return .runtimeUnavailable
        case .rejected, .failed:
            XCTFail("Exact fixture-only MPS session did not create or report unavailability")
            throw TestError.unexpectedCreationOutcome
        }
    }

    private func runCoreImageOnce(
        mode: R03CoreImageScalingMode,
        run: Int
    ) async throws -> Data {
        let backend = try R03DeterministicBackend.makeCoreImage(
            mode: mode,
            route: .scale3Over2
        )
        let session = try await R03DeterministicBackendTestSupport.makeSession(
            backend: backend
        )
        return try await runOneFrame(
            session: session,
            backend: backend,
            tokenPrefix: "r03.core-image.\(mode.rawValue).\(run)"
        )
    }

    private func runOneFrame(
        session: any AppleUpscaleSession,
        backend: R03DeterministicBackend,
        tokenPrefix: String
    ) async throws -> Data {
        let fixture = try R03DeterministicBackendTestSupport.makeInputFrame(
            route: .scale3Over2,
            sequenceNumber: 0,
            seed: 91,
            tokenPrefix: tokenPrefix
        )
        let outcome = await session.submit(fixture.frame)
        guard case .processed(let processed) = outcome else {
            XCTFail("Expected one processed frame for \(backend.subject.id.rawValue)")
            throw TestError.unexpectedFrameOutcome
        }

        let sessionIdentity = await session.identity
        XCTAssertEqual(sessionIdentity, backend.routeIdentity)
        XCTAssertEqual(processed.processingIdentity.route, backend.routeIdentity)
        XCTAssertTrue(processed.processingIdentity.fallbackHistory.isEmpty)
        XCTAssertEqual(processed.sequenceNumber, fixture.frame.sequenceNumber)
        XCTAssertEqual(processed.presentationTimestamp, fixture.frame.presentationTimestamp)
        XCTAssertEqual(processed.duration, fixture.frame.duration)
        XCTAssertEqual(processed.colorDescription, fixture.frame.colorDescription)
        XCTAssertEqual(processed.metadataIdentity, fixture.frame.metadataIdentity)
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

        let logicalBytes = try R02FixturePixelBuffers.logicalNV12Bytes(
            from: processed.pixelBuffer
        )
        processed.resourceLifetimeToken.release()
        let summary = await session.finish()
        XCTAssertEqual(summary.submittedFrameCount, 1)
        XCTAssertEqual(summary.processedFrameCount, 1)
        XCTAssertEqual(summary.terminalizationCount, 1)
        return logicalBytes
    }

    private func assertInvalidInputRejected(
        by backend: R03DeterministicBackend,
        runtimeUnavailablePermitted: Bool
    ) async throws {
        let creation = await backend.makeSession(
            configuration: try backend.makeConfiguration(),
            context: try R03DeterministicBackendTestSupport.makeContext(
                subjectID: backend.subject.id
            )
        )
        let session: any AppleUpscaleSession
        switch creation {
        case .created(let createdSession):
            session = createdSession
        case .unavailable(let unavailable):
            XCTAssertTrue(runtimeUnavailablePermitted)
            XCTAssertEqual(unavailable.reason, "r03_capability_unavailable")
            XCTAssertEqual(unavailable.processingIdentity.route, backend.routeIdentity)
            XCTAssertTrue(unavailable.processingIdentity.fallbackHistory.isEmpty)
            return
        case .rejected, .failed:
            XCTFail("Exact fixture-only session did not create")
            throw TestError.unexpectedCreationOutcome
        }

        let fixture = try R03DeterministicBackendTestSupport.makeInputFrame(
            route: .scale3Over2,
            sequenceNumber: 0,
            tokenPrefix: "r03.invalid.\(backend.subject.id.rawValue)"
        )
        CVBufferRemoveAttachment(
            fixture.frame.pixelBuffer,
            kCVImageBufferChromaLocationBottomFieldKey
        )
        let outcome = await session.submit(fixture.frame)
        guard case .rejected(let rejection) = outcome else {
            XCTFail("Expected exact NV12 input rejection")
            throw TestError.unexpectedFrameOutcome
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

    private func assertBackendIdentity(
        _ backend: R03DeterministicBackend,
        subjectID: R03BaselineSubjectID,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let descriptor = R03DeterministicBackendCatalog.subject(subjectID) else {
            return XCTFail("Missing frozen R03 subject", file: file, line: line)
        }
        XCTAssertEqual(backend.subject, descriptor, file: file, line: line)
        XCTAssertEqual(backend.identity.backendID, subjectID.rawValue, file: file, line: line)
        XCTAssertEqual(backend.capabilityID.rawValue, descriptor.capabilityID, file: file, line: line)
        XCTAssertEqual(
            backend.routeIdentity.configurationIdentity,
            descriptor.configurationIdentity(for: .scale3Over2),
            file: file,
            line: line
        )
        XCTAssertEqual(
            backend.routeIdentity.policyIdentity,
            R03DeterministicBackendCatalog.policyIdentity,
            file: file,
            line: line
        )
    }
}
