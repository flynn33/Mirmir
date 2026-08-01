import CoreMedia
import CoreVideo
import XCTest
@testable import Mirmir

final class R03VTPixelTransferScalingTests: XCTestCase {
    func testFactoryBindsExactPreregisteredReferenceIdentity() throws {
        for route in R03ScaleRoute.allCases {
            let backend = try R03DeterministicBackend.makeVTPixelTransfer(
                route: route
            )

            XCTAssertEqual(backend.subject.id, .vtPixelTransfer)
            XCTAssertEqual(backend.subject.frameworkIdentity, "VideoToolbox")
            XCTAssertEqual(
                backend.subject.qualificationRole,
                .scalingConversionReference
            )
            XCTAssertEqual(
                backend.subject.productDefaultEligibility,
                .ineligibleReferenceRole
            )
            XCTAssertEqual(backend.route, route)
            XCTAssertTrue(backend.routeIdentity.configurationIdentity.contains(route.rawValue))
            XCTAssertEqual(
                backend.routeIdentity.policyIdentity,
                R03DeterministicBackendCatalog.policyIdentity
            )
        }
    }

    func testAdmissionIsFixtureOnlyAndNotObservedIsTypedUnavailable() async throws {
        let backend = try R03DeterministicBackend.makeVTPixelTransfer(
            route: .scale3Over2
        )
        let configuration = try backend.makeConfiguration()
        let productContext = try makeContext(
            subjectID: .vtPixelTransfer,
            admissionScope: .product
        )
        guard case .rejected(let rejection) = await backend.makeSession(
            configuration: configuration,
            context: productContext
        ) else {
            return XCTFail("Product admission must reject the reference-only R03 route")
        }
        XCTAssertEqual(rejection.processingIdentity.route, backend.routeIdentity)
        XCTAssertTrue(rejection.processingIdentity.fallbackHistory.isEmpty)

        let notObserved = try R03DeterministicBackendCatalog
            .makeNotObservedCapability(for: .vtPixelTransfer)
        let unavailableContext = try makeContext(
            subjectID: .vtPixelTransfer,
            capability: notObserved
        )
        guard case .unavailable(let unavailable) = await backend.makeSession(
            configuration: configuration,
            context: unavailableContext
        ) else {
            return XCTFail("A not-observed VideoToolbox capability must be unavailable")
        }
        XCTAssertEqual(unavailable.processingIdentity.route, backend.routeIdentity)
        XCTAssertTrue(unavailable.processingIdentity.fallbackHistory.isEmpty)
    }

    func testGenuineTransferIsRepeatableWhenRuntimeIsAvailable() async throws {
        let first = try await runOnce(run: 1)
        let second = try await runOnce(run: 2)

        switch (first, second) {
        case (.processed(let firstBytes), .processed(let secondBytes)):
            XCTAssertEqual(firstBytes, secondBytes)
            XCTAssertEqual(firstBytes.count, 1_920 * 1_080 * 3 / 2)
        case (.unavailable, .unavailable):
            break
        default:
            XCTFail("VideoToolbox runtime availability changed between fresh runs")
        }
    }

    func testInvalidNV12InputIsTypedRejectedWhenRuntimeIsAvailable() async throws {
        let backend = try R03DeterministicBackend.makeVTPixelTransfer(
            route: .scale3Over2
        )
        let context = try makeContext(
            subjectID: .vtPixelTransfer
        )
        let creation = await backend.makeSession(
            configuration: try backend.makeConfiguration(),
            context: context
        )
        guard case .created(let session) = creation else {
            if case .unavailable = creation { return }
            return XCTFail("Expected a created or typed-unavailable VideoToolbox session")
        }
        let frame = try makeInputFrame(
            route: .scale3Over2,
            sequenceNumber: 0
        )
        CVBufferRemoveAttachment(
            frame.pixelBuffer,
            kCVImageBufferChromaLocationBottomFieldKey
        )

        guard case .rejected(let rejection) = await session.submit(frame) else {
            return XCTFail("An input outside the exact R03 NV12 contract must reject")
        }
        XCTAssertEqual(rejection.reason, "r03_frame_contract_mismatch")
        XCTAssertEqual(rejection.processingIdentity.route, backend.routeIdentity)
        XCTAssertTrue(rejection.processingIdentity.fallbackHistory.isEmpty)
        _ = await session.finish()
    }

    func testAdaptivePixelTransferScalesArbitraryGreaterGeometryOrIsUnavailable()
        throws {
        let plan = try R13AdaptiveScalePlan(
            sourceResolution: VideoResolution(width: 64, height: 36),
            targetResolution: VideoResolution(width: 160, height: 90)
        )
        let scaler: R03VTPixelTransferScaler
        do {
            scaler = try R03VTPixelTransferScaler(
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

    private enum RunResult {
        case processed(Data)
        case unavailable
    }

    private func runOnce(run: Int) async throws -> RunResult {
        let backend = try R03DeterministicBackend.makeVTPixelTransfer(
            route: .scale3Over2
        )
        let context = try makeContext(
            subjectID: .vtPixelTransfer
        )
        let creation = await backend.makeSession(
            configuration: try backend.makeConfiguration(),
            context: context
        )
        guard case .created(let session) = creation else {
            if case .unavailable(let unavailable) = creation {
                XCTAssertEqual(unavailable.processingIdentity.route, backend.routeIdentity)
                XCTAssertTrue(unavailable.processingIdentity.fallbackHistory.isEmpty)
                return .unavailable
            }
            throw TestError.unexpectedOutcome
        }
        let frame = try makeInputFrame(
            route: .scale3Over2,
            sequenceNumber: 0,
            seed: 83,
            tokenIdentity: "r03.vt-pixel-transfer.\(run)"
        )
        guard case .processed(let output) = await session.submit(frame) else {
            throw TestError.unexpectedOutcome
        }
        XCTAssertEqual(output.processingIdentity.route, backend.routeIdentity)
        XCTAssertTrue(output.processingIdentity.fallbackHistory.isEmpty)
        XCTAssertEqual(CVPixelBufferGetWidth(output.pixelBuffer), 1_920)
        XCTAssertEqual(CVPixelBufferGetHeight(output.pixelBuffer), 1_080)
        XCTAssertNoThrow(
            try R03NV12Contract.validate(
                pixelBuffer: output.pixelBuffer,
                resolution: .p1080
            )
        )
        let bytes = try logicalNV12Bytes(from: output.pixelBuffer)
        output.resourceLifetimeToken.release()
        _ = await session.finish()
        return .processed(bytes)
    }

    private enum TestError: Error {
        case pixelBufferCreationFailed
        case pixelBufferLayoutInvalid
        case unexpectedOutcome
    }

    private func makeContext(
        subjectID: R03BaselineSubjectID,
        admissionScope: AppleUpscaleAdmissionScope = .fixtureOnly,
        capability: AppleUpscaleCapability? = nil
    ) throws -> AppleUpscaleSessionContext {
        let capability = try capability
            ?? R03DeterministicBackendCatalog.makeFixtureCapability(for: subjectID)
        return try AppleUpscaleSessionContext(
            capabilityRegistry: AppleUpscaleCapabilityRegistry(
                capabilities: [capability]
            ),
            admissionScope: admissionScope,
            policyIdentity: R03DeterministicBackendCatalog.policyIdentity
        )
    }

    private func makeInputFrame(
        route: R03ScaleRoute,
        sequenceNumber: Int,
        seed: Int = 37,
        tokenIdentity: String = "r03.vt-pixel-transfer.input"
    ) throws -> AppleUpscaleFrame {
        let resolution = route.canonicalSourceResolution
        let pixelBuffer = try makeNV12(
            width: resolution.width,
            height: resolution.height,
            seed: seed
        )
        return try AppleUpscaleFrame(
            sequenceNumber: sequenceNumber,
            pixelBuffer: pixelBuffer,
            presentationTimestamp: CMTime(value: 1, timescale: 30),
            duration: CMTime(value: 1, timescale: 30),
            colorDescription: R03NV12Contract.makeColorDescription(),
            metadataIdentity: AppleUpscaleMetadataIdentity(
                "r03.vt-pixel-transfer.metadata"
            ),
            resourceLifetimeToken: AppleUpscaleResourceLifetimeToken(
                identity: tokenIdentity,
                releaseAction: {}
            )
        )
    }

    private func makeNV12(
        width: Int,
        height: Int,
        seed: Int
    ) throws -> CVPixelBuffer {
        var optionalBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            R03NV12Contract.pixelFormat,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,
            &optionalBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer = optionalBuffer else {
            throw TestError.pixelBufferCreationFailed
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        for plane in 0..<2 {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane) else {
                throw TestError.pixelBufferLayoutInvalid
            }
            let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, plane)
                * (plane == 0 ? 1 : 2)
            let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
            let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
            for row in 0..<height {
                let destination = base.assumingMemoryBound(to: UInt8.self)
                    .advanced(by: row * rowBytes)
                for column in 0..<width {
                    destination[column] = UInt8(
                        16 + ((seed + plane * 31 + row * 7 + column * 13) % 220)
                    )
                }
            }
        }
        R03NV12Contract.installColorAttachments(on: pixelBuffer)
        return pixelBuffer
    }

    private func logicalNV12Bytes(
        from pixelBuffer: CVPixelBuffer
    ) throws -> Data {
        guard CVPixelBufferGetPlaneCount(pixelBuffer) == 2 else {
            throw TestError.pixelBufferLayoutInvalid
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        var data = Data()
        for plane in 0..<2 {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane) else {
                throw TestError.pixelBufferLayoutInvalid
            }
            let activeBytes = CVPixelBufferGetWidthOfPlane(pixelBuffer, plane)
                * (plane == 0 ? 1 : 2)
            let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
            let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
            for row in 0..<height {
                data.append(
                    base.assumingMemoryBound(to: UInt8.self)
                        .advanced(by: row * rowBytes),
                    count: activeBytes
                )
            }
        }
        return data
    }
}
