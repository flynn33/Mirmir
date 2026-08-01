import Foundation
import CoreVideo
@preconcurrency import Metal
import XCTest
@testable import Mirmir

// The doubles intentionally cover every asynchronous terminal path in one file.
// swiftlint:disable file_length

// Driver terminal-path and live native evidence share one fixture/harness scope.
// swiftlint:disable:next type_body_length
final class R05MetalFXSpatialDriverTests: XCTestCase {
    func testBothRoutesConfigureLinearRGBA16FloatAndOrderedPipeline() async throws {
        for route in R05MetalFXSpatialDriverRoute.allCases {
            let harness = R05SpatialHarness()
            let publishCount = R05SpatialCounter()
            let extraResource = R05SpatialResource()
            let outcome = await harness.driver.process(
                request(
                    route: route,
                    retainedResources: [extraResource],
                    publish: {
                        harness.recorder.append("publish")
                        publishCount.increment()
                    }
                )
            )

            guard case .processed(let processed) = outcome else {
                return XCTFail("Expected route \(route.rawValue) to process")
            }
            XCTAssertEqual(processed.route, route)
            XCTAssertEqual(processed.destination.dimensions, route.targetDimensions)
            XCTAssertEqual(publishCount.value, 1)

            XCTAssertEqual(
                harness.factory.configurations,
                [
                    R05MetalFXSpatialScalerConfiguration(
                        inputDimensions: route.sourceDimensions,
                        outputDimensions: route.targetDimensions,
                        colorTextureFormat: .rgba16Float,
                        outputTextureFormat: .rgba16Float,
                        colorMode: .linear
                    )
                ]
            )
            let descriptors = harness.allocator.descriptors
            XCTAssertEqual(descriptors.count, 2)
            XCTAssertEqual(descriptors[0].dimensions, route.sourceDimensions)
            XCTAssertEqual(descriptors[0].pixelFormat, .rgba16Float)
            XCTAssertEqual(descriptors[0].storageMode, .private)
            assertUsage(
                descriptors[0].usage,
                contains: harness.scaler.colorTextureUsage.union(.shaderWrite)
            )
            XCTAssertEqual(descriptors[1].dimensions, route.targetDimensions)
            XCTAssertEqual(descriptors[1].pixelFormat, .rgba16Float)
            XCTAssertEqual(descriptors[1].storageMode, .private)
            assertUsage(
                descriptors[1].usage,
                contains: harness.scaler.outputTextureUsage.union(.shaderRead)
            )
            XCTAssertEqual(harness.scaler.inputContentDimensions, [route.sourceDimensions])
            XCTAssertEqual(
                harness.recorder.events,
                [
                    "supports",
                    "make-scaler",
                    "allocate-input",
                    "allocate-output",
                    "make-command-buffer",
                    "decode-upload",
                    "scale",
                    "encode-readback",
                    "commit",
                    "complete",
                    "finalize",
                    "publish"
                ]
            )
            XCTAssertEqual(harness.completer.retainedCounts, [9])
            XCTAssertTrue(
                harness.completer.retainedObjectIdentifiers[0].contains(
                    ObjectIdentifier(extraResource)
                )
            )
        }
    }

    func testDeviceSupportGuardPrecedesDescriptorFactoryAndEncoding() async {
        let harness = R05SpatialHarness(supported: false)

        let outcome = await harness.driver.process(request(route: .two))

        assertUnsupported(outcome, .deviceUnsupported)
        XCTAssertEqual(harness.recorder.events, ["supports"])
        XCTAssertEqual(harness.factory.configurations, [])
        XCTAssertEqual(harness.allocator.descriptors, [])
    }

    func testNilScalerFactoryIsTypedUnavailableWithoutSilentFallback() async {
        let harness = R05SpatialHarness(scalerFactoryReturnsNil: true)

        let outcome = await harness.driver.process(request(route: .oneAndOneHalf))

        assertUnavailable(outcome, .spatialScalerCreationReturnedNil)
        XCTAssertEqual(harness.recorder.events, ["supports", "make-scaler"])
        XCTAssertEqual(harness.allocator.descriptors, [])
    }

    func testGeometryMismatchRejectsBeforeSupportQuery() async {
        let harness = R05SpatialHarness()
        let source = R05SpatialSurface(
            dimensions: R05MetalFXSpatialDriverDimensions(width: 12, height: 8)
        )
        let request = R05MetalFXSpatialDriverRequest(
            route: .two,
            source: source,
            destination: R05SpatialSurface(dimensions: .init(width: 3840, height: 2160)),
            publish: {}
        )

        let outcome = await harness.driver.process(request)

        guard case .rejected(.sourceGeometryMismatch) = outcome else {
            return XCTFail("Expected a typed source-geometry rejection")
        }
        XCTAssertEqual(harness.recorder.events, [])
    }

    func testCommandFailureDoesNotFinalizeOrPublish() async {
        let harness = R05SpatialHarness(completionMode: .immediateFailure)
        let publishCount = R05SpatialCounter()

        let outcome = await harness.driver.process(
            request(route: .two, publish: { publishCount.increment() })
        )

        assertFailed(outcome, .commandExecutionFailed)
        XCTAssertEqual(publishCount.value, 0)
        XCTAssertFalse(harness.recorder.events.contains("finalize"))
        XCTAssertFalse(harness.recorder.events.contains("publish"))
    }

    func testPostCommitCancellationSuppressesFinalizationAndPublication() async {
        let harness = R05SpatialHarness(completionMode: .manual)
        let cancellation = R05SpatialCancellationProbe()
        let publishCount = R05SpatialCounter()
        let extraResource = R05SpatialResource()
        let processRequest = request(
            route: .two,
            retainedResources: [extraResource],
            cancellation: cancellation.contract,
            publish: { publishCount.increment() }
        )
        let task = Task {
            await harness.driver.process(processRequest)
        }
        let reachedCommit = await waitUntil { harness.completer.pendingCount == 1 }
        XCTAssertTrue(reachedCommit)
        XCTAssertEqual(harness.completer.retainedCounts, [9])
        XCTAssertTrue(
            harness.completer.retainedObjectIdentifiers[0].contains(
                ObjectIdentifier(extraResource)
            )
        )

        cancellation.cancel()
        harness.completer.completeNext(.success(()))
        let outcome = await task.value

        assertCancelled(outcome, .afterCommit)
        XCTAssertFalse(harness.recorder.events.contains("finalize"))
        XCTAssertEqual(publishCount.value, 0)
    }

    func testPrecommitCancellationDoesNotQuerySupportOrPublish() async {
        let harness = R05SpatialHarness()
        let cancellation = R05SpatialCancellationProbe(cancelled: true)
        let publishCount = R05SpatialCounter()

        let outcome = await harness.driver.process(
            request(
                route: .two,
                cancellation: cancellation.contract,
                publish: { publishCount.increment() }
            )
        )

        assertCancelled(outcome, .beforeCommit)
        XCTAssertEqual(harness.recorder.events, [])
        XCTAssertEqual(publishCount.value, 0)
    }

    func testFinalizationFailureIsTypedAndPublicationIsSuppressed() async {
        let harness = R05SpatialHarness(finalizationFails: true)
        let publishCount = R05SpatialCounter()

        let outcome = await harness.driver.process(
            request(route: .oneAndOneHalf, publish: { publishCount.increment() })
        )

        assertFailed(outcome, .outputFinalizationFailed)
        XCTAssertEqual(publishCount.value, 0)
        XCTAssertEqual(
            Array(harness.recorder.events.suffix(3)),
            ["commit", "complete", "finalize"]
        )
    }

    func testMutableScalerUseRemainsSerializedAcrossCommandCompletion() async {
        let harness = R05SpatialHarness(completionMode: .manual)
        let firstRequest = request(route: .oneAndOneHalf)
        let first = Task {
            await harness.driver.process(firstRequest)
        }
        let firstReachedCommit = await waitUntil { harness.completer.pendingCount == 1 }
        XCTAssertTrue(firstReachedCommit)

        let secondRequest = request(route: .two)
        let second = Task {
            await harness.driver.process(secondRequest)
        }
        for _ in 0..<20 {
            await Task.yield()
        }
        XCTAssertEqual(harness.factory.configurations.count, 1)

        harness.completer.completeNext(.success(()))
        let secondStarted = await waitUntil { harness.factory.configurations.count == 2 }
        XCTAssertTrue(secondStarted)
        let secondReachedCommit = await waitUntil { harness.completer.pendingCount == 1 }
        XCTAssertTrue(secondReachedCommit)
        harness.completer.completeNext(.success(()))

        guard case .processed = await first.value else {
            return XCTFail("Expected first serialized request to process")
        }
        guard case .processed = await second.value else {
            return XCTFail("Expected second serialized request to process")
        }
        XCTAssertEqual(harness.scaler.peakConcurrentEncodes, 1)
    }

    func testAdaptiveRequestExecutesSameNativePipelineAtArbitraryEvenGeometry()
        async {
        let sourceDimensions = R05MetalFXSpatialDriverDimensions(
            width: 640,
            height: 360
        )
        let targetDimensions = R05MetalFXSpatialDriverDimensions(
            width: 960,
            height: 540
        )
        let source = R05SpatialSurface(dimensions: sourceDimensions)
        let destination = R05SpatialSurface(dimensions: targetDimensions)
        let harness = R05SpatialHarness()
        let outcome = await harness.driver.process(
            R05MetalFXAdaptiveSpatialDriverRequest(
                sourceDimensions: sourceDimensions,
                targetDimensions: targetDimensions,
                source: source,
                destination: destination,
                publish: { harness.recorder.append("publish") }
            )
        )

        guard case .processed(let processed) = outcome else {
            return XCTFail("Expected adaptive MetalFX processing")
        }
        XCTAssertEqual(processed.sourceDimensions, sourceDimensions)
        XCTAssertEqual(processed.targetDimensions, targetDimensions)
        XCTAssertTrue((processed.destination as? R05SpatialSurface) === destination)
        XCTAssertEqual(
            harness.factory.configurations,
            [
                R05MetalFXSpatialScalerConfiguration(
                    inputDimensions: sourceDimensions,
                    outputDimensions: targetDimensions,
                    colorTextureFormat: .rgba16Float,
                    outputTextureFormat: .rgba16Float,
                    colorMode: .linear
                )
            ]
        )
        XCTAssertEqual(
            harness.recorder.events,
            [
                "supports",
                "make-scaler",
                "allocate-input",
                "allocate-output",
                "make-command-buffer",
                "decode-upload",
                "scale",
                "encode-readback",
                "commit",
                "complete",
                "finalize",
                "publish"
            ]
        )
    }

    func testAdaptiveRequestNilNativeScalerIsUnavailableWithoutFallback() async {
        let harness = R05SpatialHarness(scalerFactoryReturnsNil: true)
        let sourceDimensions = R05MetalFXSpatialDriverDimensions(
            width: 640,
            height: 360
        )
        let targetDimensions = R05MetalFXSpatialDriverDimensions(
            width: 960,
            height: 540
        )

        let outcome = await harness.driver.process(
            R05MetalFXAdaptiveSpatialDriverRequest(
                sourceDimensions: sourceDimensions,
                targetDimensions: targetDimensions,
                source: R05SpatialSurface(dimensions: sourceDimensions),
                destination: R05SpatialSurface(dimensions: targetDimensions),
                publish: {}
            )
        )

        guard case .unavailable(.spatialScalerCreationReturnedNil) = outcome else {
            return XCTFail("Expected typed nil-native-scaler unavailability")
        }
        XCTAssertEqual(harness.recorder.events, ["supports", "make-scaler"])
    }

    func testAdaptiveCVPixelBufferFacadeMapsEveryNativeFailureCategory() async throws {
        let sourceResolution = VideoResolution(width: 64, height: 36)
        let targetResolution = VideoResolution(width: 96, height: 54)
        let source = try makeCanonicalNV12(resolution: sourceResolution)
        let destination = try makeNV12(resolution: targetResolution)
        let cases: [(
            R05MetalFXAdaptiveSpatialDriverOutcome,
            R05MetalFXAdaptiveSpatialScalerError
        )] = [
            (
                .rejected(.sourceGeometryMismatch),
                .rejected(.sourceGeometryMismatch)
            ),
            (
                .unsupported(.deviceUnsupported),
                .unsupported(.deviceUnsupported)
            ),
            (
                .unavailable(.spatialScalerCreationReturnedNil),
                .unavailable(.spatialScalerCreationReturnedNil)
            ),
            (
                .failed(.commandExecutionFailed),
                .failed(.commandExecutionFailed)
            )
        ]

        for (outcome, expected) in cases {
            let scaler = try R05MetalFXAdaptiveSpatialScaler(
                sourceResolution: sourceResolution,
                targetResolution: targetResolution,
                driver: R05AdaptiveSpatialDriverStub(outcome: outcome)
            )
            do {
                try await scaler.scale(
                    source: source,
                    destination: destination,
                    cancellation: AppleUpscaleOperationCancellationSignal()
                )
                XCTFail("Expected native adaptive failure \(expected)")
            } catch let error as R05MetalFXAdaptiveSpatialScalerError {
                XCTAssertEqual(error, expected)
            }
        }
    }

    func testAdaptiveCVPixelBufferFacadeRejectsCancellationBeforeDriver() async throws {
        let sourceResolution = VideoResolution(width: 64, height: 36)
        let targetResolution = VideoResolution(width: 96, height: 54)
        let source = try makeCanonicalNV12(resolution: sourceResolution)
        let destination = try makeNV12(resolution: targetResolution)
        let driver = R05AdaptiveSpatialDriverStub(
            outcome: .failed(.commandExecutionFailed)
        )
        let scaler = try R05MetalFXAdaptiveSpatialScaler(
            sourceResolution: sourceResolution,
            targetResolution: targetResolution,
            driver: driver
        )
        let cancellation = AppleUpscaleOperationCancellationSignal()
        cancellation.cancel()

        do {
            try await scaler.scale(
                source: source,
                destination: destination,
                cancellation: cancellation
            )
            XCTFail("Expected cancellation")
        } catch let error as R03NV12ScalingError {
            XCTAssertEqual(error, .operationCancelled)
        }
        XCTAssertEqual(driver.processCount, 0)
    }

    func testAdaptiveCVPixelBufferFacadeMapsNativePostCommitCancellation()
        async throws {
        let sourceResolution = VideoResolution(width: 64, height: 36)
        let targetResolution = VideoResolution(width: 96, height: 54)
        let scaler = try R05MetalFXAdaptiveSpatialScaler(
            sourceResolution: sourceResolution,
            targetResolution: targetResolution,
            driver: R05AdaptiveSpatialDriverStub(
                outcome: .cancelled(.afterCommit)
            )
        )

        do {
            try await scaler.scale(
                source: makeCanonicalNV12(resolution: sourceResolution),
                destination: makeNV12(resolution: targetResolution),
                cancellation: AppleUpscaleOperationCancellationSignal()
            )
            XCTFail("Expected native post-commit cancellation")
        } catch let error as R03NV12ScalingError {
            XCTAssertEqual(error, .operationCancelled)
        }
    }

    func testLiveAdaptiveFacadeExecutesMetalFXAtNonCatalogGeometryAndPreservesAttachments()
        async throws {
        let sourceResolution = VideoResolution(width: 320, height: 180)
        let targetResolution = VideoResolution(width: 480, height: 270)
        let source = try makeCanonicalNV12(resolution: sourceResolution)
        try fillNeutralNV12(source, luma: 128)
        let propagatedKey = "com.mirmir.tests.metalfx-adaptive" as CFString
        let propagatedValue = "retained" as CFString
        CVBufferSetAttachment(
            source,
            propagatedKey,
            propagatedValue,
            .shouldPropagate
        )
        let destination = try makeNV12(resolution: targetResolution)
        let scaler = try R05MetalFXAdaptiveSpatialScaler(
            sourceResolution: sourceResolution,
            targetResolution: targetResolution
        )

        try await scaler.scale(
            source: source,
            destination: destination,
            cancellation: AppleUpscaleOperationCancellationSignal()
        )

        try R03NV12Contract.validate(
            pixelBuffer: destination,
            resolution: targetResolution
        )
        XCTAssertEqual(
            CVBufferCopyAttachment(destination, propagatedKey, nil) as? String,
            propagatedValue as String
        )
        let cleanAperture = try XCTUnwrap(
            CVBufferCopyAttachment(
                destination,
                kCVImageBufferCleanApertureKey,
                nil
            ) as? NSDictionary
        )
        XCTAssertEqual(
            cleanAperture[
                kCVImageBufferCleanApertureWidthKey
            ] as? NSNumber,
            NSNumber(value: targetResolution.width)
        )
        XCTAssertEqual(
            cleanAperture[
                kCVImageBufferCleanApertureHeightKey
            ] as? NSNumber,
            NSNumber(value: targetResolution.height)
        )
        let pixelAspectRatio = try XCTUnwrap(
            CVBufferCopyAttachment(
                destination,
                kCVImageBufferPixelAspectRatioKey,
                nil
            ) as? NSDictionary
        )
        XCTAssertEqual(
            pixelAspectRatio[
                kCVImageBufferPixelAspectRatioHorizontalSpacingKey
            ] as? NSNumber,
            NSNumber(value: 1)
        )
        XCTAssertEqual(
            pixelAspectRatio[
                kCVImageBufferPixelAspectRatioVerticalSpacingKey
            ] as? NSNumber,
            NSNumber(value: 1)
        )
    }

    func testFormatBridgeRoundTripsEveryRegisteredStorageAndColorContract()
        throws {
        let resolution = VideoResolution(width: 32, height: 32)
        for format in r05RegisteredFormatMatrix {
            let source = try makeRegisteredFormatBuffer(
                resolution: resolution,
                format: format,
                gradient: true
            )
            let destination = try makeRegisteredFormatBuffer(
                resolution: resolution,
                format: format,
                gradient: false
            )
            let before = try R13TightPixelFrame(
                capturing: destination
            )

            let linear = try R05MetalFXFormatColorBridge.decode(
                pixelBuffer: source,
                format: format
            )
            try R05MetalFXFormatColorBridge.encodeClippingFiniteRGB(
                linear,
                into: destination,
                format: format
            )

            try R13MediaVideoFormatContract.validate(
                destination,
                resolution: resolution,
                format: format
            )
            try R13PixelLayoutProcessor.validateStoredCodes(destination)
            let after = try R13TightPixelFrame(
                capturing: destination
            )
            XCTAssertNotEqual(
                after.tightRawData,
                before.tightRawData,
                "Format bridge ignored source samples for \(format)."
            )
            XCTAssertGreaterThan(
                Set(try R13PixelLayoutTestFixtures.lumaCodes(destination)).count,
                1,
                "Format bridge flattened luma for \(format)."
            )
            if format.hasAlpha {
                XCTAssertGreaterThan(
                    Set(
                        try R13PixelLayoutTestFixtures.alphaCodes(destination)
                    ).count,
                    1,
                    "Format bridge flattened alpha for \(format)."
                )
            }
        }
    }

    func testLiveMetalFXMateriallyDrivesEveryRegisteredFormatDestination()
        async throws {
        let sourceResolution = VideoResolution(width: 64, height: 64)
        let targetResolution = VideoResolution(width: 96, height: 96)

        for format in r05RegisteredFormatMatrix {
            let source = try makeRegisteredFormatBuffer(
                resolution: sourceResolution,
                format: format,
                gradient: true
            )
            let destination = try makeRegisteredFormatBuffer(
                resolution: targetResolution,
                format: format,
                gradient: false
            )
            let destinationBefore = try R13TightPixelFrame(
                capturing: destination
            )
            let scaler = try R05MetalFXAdaptiveSpatialScaler(
                sourceResolution: sourceResolution,
                targetResolution: targetResolution,
                videoFormat: format
            )

            try await scaler.scale(
                source: source,
                destination: destination,
                cancellation: AppleUpscaleOperationCancellationSignal()
            )

            try R13MediaVideoFormatContract.validate(
                destination,
                resolution: targetResolution,
                format: format
            )
            try R13PixelLayoutProcessor.validateStoredCodes(destination)
            let destinationAfter = try R13TightPixelFrame(
                capturing: destination
            )
            XCTAssertNotEqual(
                destinationAfter.tightRawData,
                destinationBefore.tightRawData,
                "Native MetalFX output did not reach \(format)."
            )
            XCTAssertGreaterThan(
                Set(try R13PixelLayoutTestFixtures.lumaCodes(destination)).count,
                1,
                "Native MetalFX flattened luma for \(format)."
            )
            try assertHighPrecisionWasNotReducedToEightBit(
                destination,
                format: format
            )
            if format.hasAlpha {
                XCTAssertGreaterThan(
                    Set(
                        try R13PixelLayoutTestFixtures.alphaCodes(destination)
                    ).count,
                    1,
                    "Native MetalFX flattened alpha for \(format)."
                )
            }
        }
    }

    func testAdaptiveFacadeSelectsAppleHDRModeForPQAndHLG() async throws {
        let resolution = VideoResolution(width: 64, height: 64)
        let target = VideoResolution(width: 96, height: 96)
        for format in [
            MediaVideoFormat.hdrBT2020PQ(),
            MediaVideoFormat.hdrBT2020HLG()
        ] {
            let driver = R05AdaptiveSpatialDriverStub(
                outcome: .failed(.commandExecutionFailed)
            )
            let scaler = try R05MetalFXAdaptiveSpatialScaler(
                sourceResolution: resolution,
                targetResolution: target,
                videoFormat: format,
                driver: driver
            )
            do {
                try await scaler.scale(
                    source: makeRegisteredFormatBuffer(
                        resolution: resolution,
                        format: format,
                        gradient: true
                    ),
                    destination: makeRegisteredFormatBuffer(
                        resolution: target,
                        format: format,
                        gradient: false
                    ),
                    cancellation: AppleUpscaleOperationCancellationSignal()
                )
                XCTFail("Expected injected native failure for \(format).")
            } catch let error as R05MetalFXAdaptiveSpatialScalerError {
                XCTAssertEqual(error, .failed(.commandExecutionFailed))
            }
            XCTAssertEqual(driver.colorModes, [.hdr])
        }
    }

    func testLiveMetalFXKeepsRGBBoundedByAlphaForAllFourStorages()
        async throws {
        let sourceResolution = VideoResolution(width: 64, height: 64)
        let targetResolution = VideoResolution(width: 96, height: 96)
        let formats: [MediaVideoFormat] = [
            .sdrBT709YUV444WithAlpha(mode: .premultiplied),
            .sdrBT709HighPrecisionPackedAlpha(mode: .premultiplied),
            .sdrBT709HighPrecisionAlpha(mode: .premultiplied),
            .sdrBT709WithAlpha(mode: .premultiplied)
        ]
        for format in formats {
            let source = try makeRegisteredFormatBuffer(
                resolution: sourceResolution,
                format: format,
                gradient: false
            )
            try fillPremultipliedAlpha(source, format: format)
            let destination = try makeRegisteredFormatBuffer(
                resolution: targetResolution,
                format: format,
                gradient: false
            )
            let scaler = try R05MetalFXAdaptiveSpatialScaler(
                sourceResolution: sourceResolution,
                targetResolution: targetResolution,
                videoFormat: format
            )

            try await scaler.scale(
                source: source,
                destination: destination,
                cancellation: AppleUpscaleOperationCancellationSignal()
            )

            try assertPremultipliedRGBDomain(
                destination,
                format: format
            )
            try R13MediaVideoFormatContract.validate(
                destination,
                resolution: targetResolution,
                format: format
            )
        }
    }

    func testLivePremultipliedBGRAKeepsTransparentColorZero()
        async throws {
        let sourceResolution = VideoResolution(width: 64, height: 64)
        let targetResolution = VideoResolution(width: 96, height: 96)
        let format = MediaVideoFormat.sdrBT709WithAlpha(
            mode: .premultiplied
        )
        let source = try makeRegisteredFormatBuffer(
            resolution: sourceResolution,
            format: format,
            gradient: false
        )
        try fillPremultipliedBGRA(source)
        let destination = try makeRegisteredFormatBuffer(
            resolution: targetResolution,
            format: format,
            gradient: false
        )
        let scaler = try R05MetalFXAdaptiveSpatialScaler(
            sourceResolution: sourceResolution,
            targetResolution: targetResolution,
            videoFormat: format
        )

        try await scaler.scale(
            source: source,
            destination: destination,
            cancellation: AppleUpscaleOperationCancellationSignal()
        )

        try assertPremultipliedBGRA(destination)
        try R13MediaVideoFormatContract.validate(
            destination,
            resolution: targetResolution,
            format: format
        )
    }

    func testAdaptiveFacadeRejectsOddOrNonIncreasingConfigurations() {
        XCTAssertThrowsError(
            try R05MetalFXAdaptiveSpatialScaler(
                sourceResolution: VideoResolution(width: 641, height: 360),
                targetResolution: VideoResolution(width: 960, height: 540),
                driver: R05AdaptiveSpatialDriverStub(
                    outcome: .failed(.commandExecutionFailed)
                )
            )
        )
        XCTAssertThrowsError(
            try R05MetalFXAdaptiveSpatialScaler(
                sourceResolution: VideoResolution(width: 640, height: 360),
                targetResolution: VideoResolution(width: 640, height: 360),
                driver: R05AdaptiveSpatialDriverStub(
                    outcome: .failed(.commandExecutionFailed)
                )
            )
        )
    }

    private func request(
        route: R05MetalFXSpatialDriverRoute,
        retainedResources: [AnyObject] = [],
        cancellation: R05MetalFXSpatialDriverCancellation = .never,
        publish: @escaping @Sendable () throws -> Void = {}
    ) -> R05MetalFXSpatialDriverRequest {
        R05MetalFXSpatialDriverRequest(
            route: route,
            source: R05SpatialSurface(dimensions: route.sourceDimensions),
            destination: R05SpatialSurface(dimensions: route.targetDimensions),
            retainedResources: retainedResources,
            cancellation: cancellation,
            publish: publish
        )
    }

    private func makeCanonicalNV12(
        resolution: VideoResolution
    ) throws -> CVPixelBuffer {
        let pixelBuffer = try makeNV12(resolution: resolution)
        try fillNeutralNV12(pixelBuffer, luma: 16)
        R13NV12GeometryTransfer.installCanonicalAttachments(
            on: pixelBuffer,
            resolution: resolution
        )
        R05MetalFXColorBridge.installRequiredAttachments(on: pixelBuffer)
        return pixelBuffer
    }

    private func makeNV12(
        resolution: VideoResolution
    ) throws -> CVPixelBuffer {
        try PixelBufferBridge.dequeue(
            from: PixelBufferBridge.makePool(
                width: resolution.width,
                height: resolution.height,
                format: R05MetalFXColorBridge.pixelFormat,
                capacity: 1
            )
        )
    }

    private func fillNeutralNV12(
        _ pixelBuffer: CVPixelBuffer,
        luma: UInt8
    ) throws {
        let status = CVPixelBufferLockBaseAddress(pixelBuffer, [])
        guard status == kCVReturnSuccess else {
            throw R05SpatialTestError.pixelBufferLock(status)
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let cbcrBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else {
            throw R05SpatialTestError.missingPlane
        }
        for row in 0..<CVPixelBufferGetHeightOfPlane(pixelBuffer, 0) {
            memset(
                yBase.advanced(
                    by: row * CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
                ),
                Int32(luma),
                CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
            )
        }
        for row in 0..<CVPixelBufferGetHeightOfPlane(pixelBuffer, 1) {
            memset(
                cbcrBase.advanced(
                    by: row * CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
                ),
                128,
                CVPixelBufferGetWidthOfPlane(pixelBuffer, 1) * 2
            )
        }
    }

    private func makeRegisteredFormatBuffer(
        resolution: VideoResolution,
        format: MediaVideoFormat,
        gradient: Bool
    ) throws -> CVPixelBuffer {
        let pixelBuffer = try gradient
            ? R13PixelLayoutTestFixtures.makeGradientBuffer(
                pixelFormat: format.pixelStorage.pixelFormat,
                width: resolution.width,
                height: resolution.height
            )
            : R13PixelLayoutTestFixtures.makeUniformBuffer(
                pixelFormat: format.pixelStorage.pixelFormat,
                width: resolution.width,
                height: resolution.height,
                maximumLuma: false
            )
        R13MediaVideoFormatContract.install(
            format,
            on: pixelBuffer,
            resolution: resolution
        )
        return pixelBuffer
    }

    private func fillPremultipliedBGRA(
        _ pixelBuffer: CVPixelBuffer
    ) throws {
        let status = CVPixelBufferLockBaseAddress(pixelBuffer, [])
        guard status == kCVReturnSuccess else {
            throw R05SpatialTestError.pixelBufferLock(status)
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw R05SpatialTestError.missingPlane
        }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        for row in 0..<height {
            let bytes = base.advanced(by: row * rowBytes)
                .assumingMemoryBound(to: UInt8.self)
            for column in 0..<width {
                let offset = column * 4
                let alpha: UInt8
                if column < width / 3 {
                    alpha = 0
                } else if column < width * 2 / 3 {
                    alpha = UInt8(80 + (row % 16) * 4)
                } else {
                    alpha = UInt8(176 + (row % 16) * 4)
                }
                bytes[offset] = alpha / 4
                bytes[offset + 1] = alpha / 2
                bytes[offset + 2] = alpha
                bytes[offset + 3] = alpha
            }
        }
    }

    private func assertPremultipliedBGRA(
        _ pixelBuffer: CVPixelBuffer
    ) throws {
        let status = CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        guard status == kCVReturnSuccess else {
            throw R05SpatialTestError.pixelBufferLock(status)
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw R05SpatialTestError.missingPlane
        }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        var foundTranslucentColor = false
        for row in 0..<height {
            let bytes = base.advanced(by: row * rowBytes)
                .assumingMemoryBound(to: UInt8.self)
            for column in 0..<width {
                let offset = column * 4
                let alpha = bytes[offset + 3]
                XCTAssertLessThanOrEqual(bytes[offset], alpha)
                XCTAssertLessThanOrEqual(bytes[offset + 1], alpha)
                XCTAssertLessThanOrEqual(bytes[offset + 2], alpha)
                if alpha == 0 {
                    XCTAssertEqual(bytes[offset], 0)
                    XCTAssertEqual(bytes[offset + 1], 0)
                    XCTAssertEqual(bytes[offset + 2], 0)
                }
                if alpha > 0,
                   alpha < 255,
                   bytes[offset + 2] > 0 {
                    foundTranslucentColor = true
                }
            }
        }
        XCTAssertTrue(foundTranslucentColor)
    }

    private func fillPremultipliedAlpha(
        _ pixelBuffer: CVPixelBuffer,
        format: MediaVideoFormat
    ) throws {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var components: [Float16] = []
        components.reserveCapacity(width * height * 4)
        for row in 0..<height {
            for column in 0..<width {
                let phase = Double((row * width + column) % 17) / 16
                let alpha = 0.24 + 0.52 * phase
                components.append(Float16(0.008 + 0.012 * phase))
                components.append(Float16(0.012 + 0.016 * phase))
                components.append(Float16(0.016 + 0.020 * phase))
                components.append(Float16(alpha))
            }
        }
        try R05MetalFXFormatColorBridge.encodeClippingFiniteRGB(
            R05LinearRGBA16FloatFrame(
                width: width,
                height: height,
                components: components
            ),
            into: pixelBuffer,
            format: format
        )
    }

    private func assertPremultipliedRGBDomain(
        _ pixelBuffer: CVPixelBuffer,
        format: MediaVideoFormat
    ) throws {
        let frame = try R05MetalFXFormatColorBridge.decode(
            pixelBuffer: pixelBuffer,
            format: format
        )
        let tolerance = format.pixelStorage.bitDepth == 8
            ? 0.01
            : 0.001
        var foundTranslucentColor = false
        for row in 0..<frame.height {
            for column in 0..<frame.width {
                let offset = row * frame.componentsPerRow + column * 4
                let alpha = Double(frame.components[offset + 3])
                XCTAssertGreaterThan(alpha, 0, format.description)
                XCTAssertLessThan(alpha, 1, format.description)
                for component in 0..<3 {
                    let color = Double(frame.components[offset + component])
                    XCTAssertLessThanOrEqual(
                        color,
                        alpha + tolerance,
                        "RGB exceeds alpha for \(format)."
                    )
                    if color > 0 {
                        foundTranslucentColor = true
                    }
                }
            }
        }
        XCTAssertTrue(
            foundTranslucentColor,
            "MetalFX flattened translucent color for \(format)."
        )
    }

    private func assertHighPrecisionWasNotReducedToEightBit(
        _ pixelBuffer: CVPixelBuffer,
        format: MediaVideoFormat
    ) throws {
        let step: UInt16
        switch format.pixelStorage.bitDepth {
        case 10:
            step = 4
        case 16:
            step = 256
        default:
            return
        }
        let luma = try R13PixelLayoutTestFixtures.lumaCodes(pixelBuffer)
        XCTAssertTrue(
            luma.contains { !$0.isMultiple(of: step) },
            "MetalFX reduced \(format) luma to an eight-bit code grid."
        )
        if format.pixelStorage.alphaBitDepth == 16 {
            let alpha = try R13PixelLayoutTestFixtures.alphaCodes(pixelBuffer)
            XCTAssertTrue(
                alpha.contains { !$0.isMultiple(of: step) },
                "MetalFX reduced \(format) alpha to an eight-bit code grid."
            )
        }
    }

    private func waitUntil(
        _ predicate: () -> Bool
    ) async -> Bool {
        for _ in 0..<2_000 {
            if predicate() { return true }
            await Task.yield()
        }
        return false
    }

    private func assertUsage(
        _ observed: MTLTextureUsage,
        contains expected: MTLTextureUsage,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            observed.intersection(expected),
            expected,
            file: file,
            line: line
        )
    }

    private func assertUnsupported(
        _ outcome: R05MetalFXSpatialDriverOutcome,
        _ expected: R05MetalFXSpatialDriverUnsupportedReason,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .unsupported(let reason) = outcome else {
            return XCTFail("Expected unsupported outcome", file: file, line: line)
        }
        XCTAssertEqual(reason, expected, file: file, line: line)
    }

    private func assertUnavailable(
        _ outcome: R05MetalFXSpatialDriverOutcome,
        _ expected: R05MetalFXSpatialDriverUnavailableReason,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .unavailable(let reason) = outcome else {
            return XCTFail("Expected unavailable outcome", file: file, line: line)
        }
        XCTAssertEqual(reason, expected, file: file, line: line)
    }

    private func assertFailed(
        _ outcome: R05MetalFXSpatialDriverOutcome,
        _ expected: R05MetalFXSpatialDriverFailureReason,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .failed(let reason) = outcome else {
            return XCTFail("Expected failed outcome", file: file, line: line)
        }
        XCTAssertEqual(reason, expected, file: file, line: line)
    }

    private func assertCancelled(
        _ outcome: R05MetalFXSpatialDriverOutcome,
        _ expected: R05MetalFXSpatialCancellationReason,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .cancelled(let reason) = outcome else {
            return XCTFail("Expected cancelled outcome", file: file, line: line)
        }
        XCTAssertEqual(reason, expected, file: file, line: line)
    }
}

private enum R05SpatialTestError: Error {
    case injected
    case pixelBufferLock(CVReturn)
    case missingPlane
}

private final class R05SpatialRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var events: [String] {
        lock.withLock { storage }
    }

    func append(_ event: String) {
        lock.withLock { storage.append(event) }
    }
}

private final class R05SpatialCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int { lock.withLock { storage } }

    func increment() {
        lock.withLock { storage += 1 }
    }
}

private final class R05AdaptiveSpatialDriverStub:
    R05MetalFXAdaptiveSpatialDriving, @unchecked Sendable {
    private let outcome: R05MetalFXAdaptiveSpatialDriverOutcome
    private let lock = NSLock()
    private var processCountStorage = 0
    private var colorModeStorage: [R05MetalFXSpatialDriverColorMode] = []

    init(outcome: R05MetalFXAdaptiveSpatialDriverOutcome) {
        self.outcome = outcome
    }

    var processCount: Int { lock.withLock { processCountStorage } }
    var colorModes: [R05MetalFXSpatialDriverColorMode] {
        lock.withLock { colorModeStorage }
    }

    func process(
        _ request: R05MetalFXAdaptiveSpatialDriverRequest
    ) async -> R05MetalFXAdaptiveSpatialDriverOutcome {
        lock.withLock {
            processCountStorage += 1
            colorModeStorage.append(request.colorMode)
        }
        return outcome
    }
}

private var r05RegisteredFormatMatrix: [MediaVideoFormat] {
    let displayVolume = Data((0..<24).map(UInt8.init))
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
        .sdrBT709WithAlpha(mode: .straight),
        .sdrBT709WithAlpha(mode: .premultiplied),
        .hdrBT2020PQ(
            masteringDisplayColorVolume: displayVolume,
            contentLightLevelInfo: contentLight
        ),
        .hdrBT2020HLG(
            masteringDisplayColorVolume: displayVolume,
            contentLightLevelInfo: contentLight
        ),
        .hdrBT2020PQYUV444FullRange(
            masteringDisplayColorVolume: displayVolume,
            contentLightLevelInfo: contentLight
        ),
        .hdrBT2020HLGYUV444FullRange(
            masteringDisplayColorVolume: displayVolume,
            contentLightLevelInfo: contentLight
        )
    ]
}

private final class R05SpatialCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Bool

    init(cancelled: Bool = false) {
        storage = cancelled
    }

    var contract: R05MetalFXSpatialDriverCancellation {
        R05MetalFXSpatialDriverCancellation(
            isCancelled: { [weak self] in self?.isCancelled ?? true }
        )
    }

    func cancel() {
        lock.withLock { storage = true }
    }

    private var isCancelled: Bool { lock.withLock { storage } }
}

private final class R05SpatialResource: @unchecked Sendable {}

private final class R05SpatialSurface: R05MetalFXSpatialNV12Surface,
    @unchecked Sendable {
    let dimensions: R05MetalFXSpatialDriverDimensions

    init(dimensions: R05MetalFXSpatialDriverDimensions) {
        self.dimensions = dimensions
    }
}

private final class R05SpatialTexture: R05MetalFXSpatialTexture,
    @unchecked Sendable {
    let descriptor: R05MetalFXSpatialTextureDescriptor

    init(descriptor: R05MetalFXSpatialTextureDescriptor) {
        self.descriptor = descriptor
    }
}

private final class R05SpatialCommandBuffer: R05MetalFXSpatialCommandBuffer,
    @unchecked Sendable {}

private final class R05SpatialScaler: R05MetalFXSpatialScaler,
    @unchecked Sendable {
    let colorTextureUsage: MTLTextureUsage = [.shaderRead, .pixelFormatView]
    let outputTextureUsage: MTLTextureUsage = [.shaderWrite, .renderTarget]

    private let recorder: R05SpatialRecorder
    private let fails: Bool
    private let lock = NSLock()
    private var dimensionsStorage: [R05MetalFXSpatialDriverDimensions] = []
    private var concurrentEncodes = 0
    private var peakStorage = 0

    init(recorder: R05SpatialRecorder, fails: Bool = false) {
        self.recorder = recorder
        self.fails = fails
    }

    var inputContentDimensions: [R05MetalFXSpatialDriverDimensions] {
        lock.withLock { dimensionsStorage }
    }

    var peakConcurrentEncodes: Int { lock.withLock { peakStorage } }

    func encode(
        colorTexture _: any R05MetalFXSpatialTexture,
        outputTexture _: any R05MetalFXSpatialTexture,
        inputContentDimensions: R05MetalFXSpatialDriverDimensions,
        commandBuffer _: any R05MetalFXSpatialCommandBuffer
    ) throws {
        lock.withLock {
            concurrentEncodes += 1
            peakStorage = max(peakStorage, concurrentEncodes)
            dimensionsStorage.append(inputContentDimensions)
        }
        defer { lock.withLock { concurrentEncodes -= 1 } }
        recorder.append("scale")
        if fails { throw R05SpatialTestError.injected }
    }
}

private final class R05SpatialScalerFactory: R05MetalFXSpatialScalerCreating,
    @unchecked Sendable {
    private let recorder: R05SpatialRecorder
    private let supported: Bool
    private let returnsNil: Bool
    private let scaler: R05SpatialScaler
    private let lock = NSLock()
    private var configurationStorage: [R05MetalFXSpatialScalerConfiguration] = []

    init(
        recorder: R05SpatialRecorder,
        supported: Bool,
        returnsNil: Bool,
        scaler: R05SpatialScaler
    ) {
        self.recorder = recorder
        self.supported = supported
        self.returnsNil = returnsNil
        self.scaler = scaler
    }

    var configurations: [R05MetalFXSpatialScalerConfiguration] {
        lock.withLock { configurationStorage }
    }

    func supportsDevice() -> Bool {
        recorder.append("supports")
        return supported
    }

    func makeScaler(
        configuration: R05MetalFXSpatialScalerConfiguration
    ) -> (any R05MetalFXSpatialScaler)? {
        recorder.append("make-scaler")
        lock.withLock { configurationStorage.append(configuration) }
        return returnsNil ? nil : scaler
    }
}

private final class R05SpatialTextureAllocator: R05MetalFXSpatialTextureAllocating,
    @unchecked Sendable {
    private let recorder: R05SpatialRecorder
    private let lock = NSLock()
    private var descriptorStorage: [R05MetalFXSpatialTextureDescriptor] = []

    init(recorder: R05SpatialRecorder) {
        self.recorder = recorder
    }

    var descriptors: [R05MetalFXSpatialTextureDescriptor] {
        lock.withLock { descriptorStorage }
    }

    func makeTexture(
        descriptor: R05MetalFXSpatialTextureDescriptor
    ) -> (any R05MetalFXSpatialTexture)? {
        let ordinal = lock.withLock { () -> Int in
            descriptorStorage.append(descriptor)
            return descriptorStorage.count
        }
        recorder.append(ordinal == 1 ? "allocate-input" : "allocate-output")
        return R05SpatialTexture(descriptor: descriptor)
    }
}

private final class R05SpatialCommandBufferFactory:
    R05MetalFXSpatialCommandBufferCreating, @unchecked Sendable {
    private let recorder: R05SpatialRecorder

    init(recorder: R05SpatialRecorder) {
        self.recorder = recorder
    }

    func makeCommandBuffer(
        label _: String
    ) -> (any R05MetalFXSpatialCommandBuffer)? {
        recorder.append("make-command-buffer")
        return R05SpatialCommandBuffer()
    }
}

private final class R05SpatialColorConverter: R05MetalFXSpatialColorConverting,
    @unchecked Sendable {
    private let recorder: R05SpatialRecorder
    private let finalizationFails: Bool
    private let decodeResource = R05SpatialResource()
    private let encodeResource = R05SpatialResource()

    init(recorder: R05SpatialRecorder, finalizationFails: Bool) {
        self.recorder = recorder
        self.finalizationFails = finalizationFails
    }

    func encodeNV12ToLinear(
        source _: any R05MetalFXSpatialNV12Surface,
        destination _: any R05MetalFXSpatialTexture,
        commandBuffer _: any R05MetalFXSpatialCommandBuffer
    ) throws -> [AnyObject] {
        recorder.append("decode-upload")
        return [decodeResource]
    }

    func encodeLinearToNV12(
        source _: any R05MetalFXSpatialTexture,
        destination _: any R05MetalFXSpatialNV12Surface,
        commandBuffer _: any R05MetalFXSpatialCommandBuffer
    ) throws -> R05MetalFXSpatialPendingOutputConversion {
        recorder.append("encode-readback")
        return R05MetalFXSpatialPendingOutputConversion(
            retainedResources: [encodeResource],
            finalize: { [recorder, finalizationFails] in
                recorder.append("finalize")
                if finalizationFails { throw R05SpatialTestError.injected }
            }
        )
    }
}

private enum R05SpatialCompletionMode {
    case immediateSuccess
    case immediateFailure
    case manual
}

private final class R05SpatialCommandCompleter: R05MetalFXSpatialCommandCompleting,
    @unchecked Sendable {
    private struct State {
        var continuations: [CheckedContinuation<Void, Error>] = []
        var retainedCounts: [Int] = []
        var retainedObjectIdentifiers: [Set<ObjectIdentifier>] = []
    }

    private let recorder: R05SpatialRecorder
    private let mode: R05SpatialCompletionMode
    private let lock = NSLock()
    private var state = State()

    init(recorder: R05SpatialRecorder, mode: R05SpatialCompletionMode) {
        self.recorder = recorder
        self.mode = mode
    }

    var pendingCount: Int { lock.withLock { state.continuations.count } }
    var retainedCounts: [Int] { lock.withLock { state.retainedCounts } }
    var retainedObjectIdentifiers: [Set<ObjectIdentifier>] {
        lock.withLock { state.retainedObjectIdentifiers }
    }

    func commitAndWait(
        commandBuffer _: any R05MetalFXSpatialCommandBuffer,
        retaining resources: R05MetalFXSpatialRetainedResources
    ) async throws {
        recorder.append("commit")
        lock.withLock {
            state.retainedCounts.append(resources.count)
            state.retainedObjectIdentifiers.append(
                Set(resources.objects.map(ObjectIdentifier.init))
            )
        }
        switch mode {
        case .immediateSuccess:
            recorder.append("complete")
        case .immediateFailure:
            throw R05SpatialTestError.injected
        case .manual:
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock { state.continuations.append(continuation) }
            }
            recorder.append("complete")
        }
    }

    func completeNext(_ result: Result<Void, Error>) {
        let continuation = lock.withLock { state.continuations.removeFirst() }
        continuation.resume(with: result)
    }
}

private final class R05SpatialHarness: @unchecked Sendable {
    let recorder: R05SpatialRecorder
    let scaler: R05SpatialScaler
    let factory: R05SpatialScalerFactory
    let allocator: R05SpatialTextureAllocator
    let completer: R05SpatialCommandCompleter
    let driver: R05MetalFXSpatialDriver

    init(
        supported: Bool = true,
        scalerFactoryReturnsNil: Bool = false,
        scalerFails: Bool = false,
        finalizationFails: Bool = false,
        completionMode: R05SpatialCompletionMode = .immediateSuccess
    ) {
        let recorder = R05SpatialRecorder()
        let scaler = R05SpatialScaler(recorder: recorder, fails: scalerFails)
        let factory = R05SpatialScalerFactory(
            recorder: recorder,
            supported: supported,
            returnsNil: scalerFactoryReturnsNil,
            scaler: scaler
        )
        let allocator = R05SpatialTextureAllocator(recorder: recorder)
        let completer = R05SpatialCommandCompleter(
            recorder: recorder,
            mode: completionMode
        )
        self.recorder = recorder
        self.scaler = scaler
        self.factory = factory
        self.allocator = allocator
        self.completer = completer
        self.driver = R05MetalFXSpatialDriver(
            scalerFactory: factory,
            textureAllocator: allocator,
            commandBufferFactory: R05SpatialCommandBufferFactory(recorder: recorder),
            colorConverter: R05SpatialColorConverter(
                recorder: recorder,
                finalizationFails: finalizationFails
            ),
            commandCompleter: completer
        )
    }
}
