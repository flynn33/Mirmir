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

    func testAdaptiveCoreImageModesScaleArbitraryGreaterGeometry()
        throws {
        let plan = try R13AdaptiveScalePlan(
            sourceResolution: VideoResolution(width: 64, height: 36),
            targetResolution: VideoResolution(width: 160, height: 90)
        )
        let source = try R13ReleaseTestFrames.makeOutput(
            resolution: plan.processingSourceResolution
        )

        for mode in R03CoreImageScalingMode.allCases {
            let destination = try R13ReleaseTestFrames.makeOutput(
                resolution: plan.targetResolution
            )
            let scaler = R03CoreImageScaler(
                mode: mode,
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
    }

    func testCoreImageModesPreserveEveryRegisteredVideoFormat()
        throws {
        let sourceResolution = VideoResolution(width: 8, height: 8)
        let targetResolution = VideoResolution(width: 16, height: 16)
        let formats = coreImageRegisteredVideoFormats
        XCTAssertEqual(
            Set(formats.map(\.pixelStorage)),
            Set(MediaVideoPixelStorage.allCases)
        )

        for mode in R03CoreImageScalingMode.allCases {
            for format in formats {
                let source = try makeCoreImageBuffer(
                    resolution: sourceResolution,
                    format: format,
                    initialize: true
                )
                let destination = try makeCoreImageBuffer(
                    resolution: targetResolution,
                    format: format,
                    initialize: false
                )
                let propagatingKey =
                    "com.mirmir.r03.core-image.propagating"
                        as CFString
                let localKey =
                    "com.mirmir.r03.core-image.local" as CFString
                CVBufferSetAttachment(
                    source,
                    propagatingKey,
                    mode.rawValue as CFString,
                    .shouldPropagate
                )
                CVBufferSetAttachment(
                    source,
                    localKey,
                    format.description as CFString,
                    .shouldNotPropagate
                )
                let scaler = try R03CoreImageScaler(
                    mode: mode,
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

                XCTAssertEqual(scaler.mode, mode)
                XCTAssertNil(scaler.route)
                XCTAssertEqual(scaler.videoFormat, format)
                try R13MediaVideoFormatContract.validate(
                    destination,
                    resolution: targetResolution,
                    format: format
                )
                try R13PixelLayoutProcessor.validateStoredCodes(
                    destination
                )
                XCTAssertEqual(
                    CVPixelBufferGetPixelFormatType(destination),
                    format.pixelStorage.pixelFormat
                )
                XCTAssertEqual(
                    CVPixelBufferGetPlaneCount(destination),
                    format.pixelStorage.expectedPlaneCount
                )
                assertCoreImageAttachment(
                    destination,
                    key: propagatingKey,
                    expectedValue: mode.rawValue,
                    expectedMode: .shouldPropagate
                )
                assertCoreImageAttachment(
                    destination,
                    key: localKey,
                    expectedValue: format.description,
                    expectedMode: .shouldNotPropagate
                )
                let luma = try R13PixelLayoutTestFixtures
                    .lumaCodes(destination)
                XCTAssertFalse(luma.isEmpty, format.description)
                XCTAssertGreaterThan(
                    Set(luma).count,
                    1,
                    "Core Image output lost stored-code variation: "
                        + "\(mode.rawValue) \(format.description)"
                )
                if format.hasAlpha {
                    let alpha = try R13PixelLayoutTestFixtures
                        .alphaCodes(destination)
                    XCTAssertFalse(alpha.isEmpty, format.description)
                    XCTAssertGreaterThan(
                        Set(alpha).count,
                        1,
                        "Core Image output lost alpha variation: "
                            + "\(mode.rawValue) \(format.description)"
                    )
                }
                scaler.finish()
            }
        }
    }

    func testFormatPreservingCoreImageHonorsCancellationBeforeRender()
        throws {
        let sourceResolution = VideoResolution(width: 8, height: 8)
        let targetResolution = VideoResolution(width: 16, height: 16)
        let format = MediaVideoFormat.sdrBT709HighPrecisionAlpha(
            mode: .straight
        )
        let source = try makeCoreImageBuffer(
            resolution: sourceResolution,
            format: format,
            initialize: true
        )
        let destination = try makeCoreImageBuffer(
            resolution: targetResolution,
            format: format,
            initialize: false
        )
        let scaler = try R03CoreImageScaler(
            mode: .bicubic,
            sourceResolution: sourceResolution,
            targetResolution: targetResolution,
            videoFormat: format
        )
        let cancellation = AppleUpscaleOperationCancellationSignal()
        cancellation.cancel()

        XCTAssertThrowsError(
            try scaler.scale(
                source: source,
                destination: destination,
                cancellation: cancellation
            )
        ) { error in
            XCTAssertEqual(
                error as? R03NV12ScalingError,
                .operationCancelled
            )
        }
        scaler.cancel()
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

    private func makeCoreImageBuffer(
        resolution: VideoResolution,
        format: MediaVideoFormat,
        initialize: Bool
    ) throws -> CVPixelBuffer {
        let pool = try PixelBufferBridge.makePool(
            width: resolution.width,
            height: resolution.height,
            format: format.pixelStorage.pixelFormat,
            capacity: 1
        )
        let buffer = try PixelBufferBridge.dequeue(from: pool)
        if initialize {
            let fixture = try R13PixelLayoutTestFixtures
                .makeGradientBuffer(
                    pixelFormat: format.pixelStorage.pixelFormat,
                    width: resolution.width,
                    height: resolution.height
                )
            try R13PixelLayoutProcessor.copy(
                source: fixture,
                destination: buffer
            )
        }
        R13MediaVideoFormatContract.install(
            format,
            on: buffer,
            resolution: resolution
        )
        return buffer
    }

    private func assertCoreImageAttachment(
        _ pixelBuffer: CVPixelBuffer,
        key: CFString,
        expectedValue: String,
        expectedMode: CVAttachmentMode,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var actualMode = CVAttachmentMode.shouldPropagate
        let value = CVBufferCopyAttachment(
            pixelBuffer,
            key,
            &actualMode
        )
        XCTAssertEqual(
            value as? String,
            expectedValue,
            file: file,
            line: line
        )
        XCTAssertEqual(
            actualMode,
            expectedMode,
            file: file,
            line: line
        )
    }
}

private var coreImageRegisteredVideoFormats: [MediaVideoFormat] {
    let masteringDisplay = Data((0..<24).map(UInt8.init))
    let contentLight = Data([0x03, 0xE8, 0x01, 0x90])
    return [
        .sdrBT709,
        .sdrBT709FullRange,
        .sdrBT709TenBit,
        .sdrBT709TenBitFullRange,
        .sdrBT2020TenBit,
        .sdrBT709YUV422,
        .sdrBT709YUV422FullRange,
        .sdrBT709YUV422TenBit,
        .sdrBT709YUV422TenBitFullRange,
        .sdrBT709YUV422SixteenBit,
        .sdrBT709YUV444,
        .sdrBT709YUV444FullRange,
        .sdrBT709YUV444TenBit,
        .sdrBT709YUV444TenBitFullRange,
        .sdrBT709YUV444SixteenBit,
        .sdrBT709YUV444WithAlpha(mode: .straight),
        .sdrBT709HighPrecisionPackedAlpha(mode: .premultiplied),
        .sdrBT709HighPrecisionAlpha(mode: .straight),
        .sdrBT709WithAlpha(mode: .premultiplied),
        .hdrBT2020PQ(
            masteringDisplayColorVolume: masteringDisplay,
            contentLightLevelInfo: contentLight
        ),
        .hdrBT2020HLG(),
        .hdrBT2020PQYUV444FullRange(
            masteringDisplayColorVolume: masteringDisplay,
            contentLightLevelInfo: contentLight
        ),
        .hdrBT2020HLGYUV444FullRange()
    ]
}
