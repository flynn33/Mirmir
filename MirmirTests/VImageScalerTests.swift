import Accelerate
import CoreGraphics
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import Metal
import MetalPerformanceShaders
import XCTest
@testable import Mirmir

final class VImageScalerTests: XCTestCase {
    func testExplicitInterlacedAndInvalidCountsRejectBeforeNativePreparation() async throws {
        let catalog = UpscaleBackendCatalog.live()
        let backends: [UpscaleBackendID] = [
            .mpsLanczos, .mpsBilinear, .coreImageLanczos, .coreImageBicubic,
            .vImageHighQuality, .vImageStandard, .videoToolboxPixelTransfer
        ]
        for fieldCount in [2, 0, -1] {
            let source = makeVImageVideoInfo(fieldCount: fieldCount)
            for backend in backends {
                let availability = await catalog.availability(
                    for: backend, source: source,
                    targetSize: CGSize(width: 8, height: 8),
                    environment: availableVImageEnvironment
                )
                guard case .unavailable(.unsupportedPixelFormatOrBitDepth) = availability else {
                    XCTFail("Unexpected field-count admission for \(backend): \(availability)")
                    continue
                }
                do {
                    _ = try await catalog.prepare(
                        backendID: backend,
                        request: BackendPreparationRequest(
                            source: source, targetSize: CGSize(width: 8, height: 8)
                        ),
                        environment: availableVImageEnvironment
                    )
                    XCTFail("Preparation accepted field count \(fieldCount) for \(backend)")
                } catch let BackendPreparationError.unavailable(actual, reason) {
                    XCTAssertEqual(actual, backend)
                    guard case .unsupportedPixelFormatOrBitDepth = reason else {
                        XCTFail("Unexpected field-count rejection: \(reason)")
                        continue
                    }
                }
            }
            let snapshot = await catalog.snapshot(
                for: source, targetSize: CGSize(width: 8, height: 8),
                environment: availableVImageEnvironment
            )
            XCTAssertNil(snapshot.automaticProposal)
        }
    }

    func testFieldGuardPreservesAbsentMetadataAndProgressiveAdmission() async throws {
        for fieldCount: Int? in [nil, 1] {
            let source = makeVImageVideoInfo(fieldCount: fieldCount)
            guard case .valid = NV12ScalerConfiguration.validate(
                source: source, targetSize: CGSize(width: 8, height: 8),
                backendID: .mpsLanczos
            ) else {
                XCTFail("Field guard changed absent/progressive metadata admission")
                continue
            }
            let backend = try XCTUnwrap(VImageBackend(mode: .standard))
            let availability = await backend.availability(
                for: source, targetSize: CGSize(width: 8, height: 8),
                environment: availableVImageEnvironment
            )
            XCTAssertEqual(availability, .available)
        }
    }

    func testModesExposeExactIDsAndDocumentedFlags() {
        XCTAssertEqual(VImageScalingMode.standard.backendID, .vImageStandard)
        XCTAssertEqual(
            VImageScalingMode.standard.resamplingFlags,
            vImage_Flags(kvImageEdgeExtend)
        )
        XCTAssertEqual(
            VImageScalingMode.highQuality.backendID,
            .vImageHighQuality
        )
        XCTAssertEqual(
            VImageScalingMode.highQuality.resamplingFlags,
            vImage_Flags(kvImageEdgeExtend | kvImageHighQualityResampling)
        )
    }

    func testLiveCatalogRegistersBothVImageBackendsAndAutomaticUsesFixedPolicy() async {
        let source = makeVImageVideoInfo()
        let snapshot = await UpscaleBackendCatalog.live().snapshot(
            for: source,
            targetSize: CGSize(width: 8, height: 8),
            environment: availableVImageEnvironment
        )

        XCTAssertEqual(
            snapshot.entry(for: .vImageHighQuality)?.availability,
            .available
        )
        XCTAssertEqual(
            snapshot.entry(for: .vImageStandard)?.availability,
            .available
        )
        let expectedProposal = AutomaticBackendSelector.orderedBackendIDs.first {
            snapshot.entry(for: $0)?.availability == .available
        }
        XCTAssertEqual(snapshot.automaticProposal, expectedProposal)
        XCTAssertEqual(snapshot.entry(for: .automatic)?.availability, .available)
    }

    func testBothModesScalePaddedConstantNV12ToExactDimensions() async throws {
        for mode in VImageScalingMode.allCases {
            for range in [NV12Range.video, .full] {
                let backend = try XCTUnwrap(VImageBackend(mode: mode))
                let sourceInfo = makeVImageVideoInfo(range: range)
                let prepared = try await backend.prepare(
                    request: BackendPreparationRequest(
                        source: sourceInfo,
                        targetSize: CGSize(width: 8, height: 8)
                    ),
                    environment: availableVImageEnvironment
                )
                let source = try SyntheticNV12PixelBuffer.make(
                    width: 4,
                    height: 4,
                    pixelFormat: range.pixelFormat
                )
                let destination = try SyntheticNV12PixelBuffer.make(
                    width: 8,
                    height: 8,
                    pixelFormat: range.pixelFormat
                )
                try SyntheticNV12PixelBuffer.fill(
                    source,
                    luma: 64,
                    cb: 90,
                    cr: 160,
                    padding: 0xB4
                )
                try SyntheticNV12PixelBuffer.fill(
                    destination,
                    luma: 0,
                    cb: 0,
                    cr: 0,
                    padding: 0xD3
                )

                XCTAssertGreaterThan(
                    CVPixelBufferGetBytesPerRowOfPlane(source, 0),
                    CVPixelBufferGetWidthOfPlane(source, 0)
                )
                XCTAssertGreaterThan(
                    CVPixelBufferGetBytesPerRowOfPlane(source, 1),
                    CVPixelBufferGetWidthOfPlane(source, 1) * 2
                )
                XCTAssertGreaterThan(
                    CVPixelBufferGetBytesPerRowOfPlane(destination, 0),
                    CVPixelBufferGetWidthOfPlane(destination, 0)
                )
                XCTAssertGreaterThan(
                    CVPixelBufferGetBytesPerRowOfPlane(destination, 1),
                    CVPixelBufferGetWidthOfPlane(destination, 1) * 2
                )
                XCTAssertEqual(prepared.actualBackendID, mode.backendID)

                try await prepared.process(
                    source: source,
                    destination: destination,
                    timing: testFrameTiming
                )

                XCTAssertEqual(CVPixelBufferGetWidth(destination), 8)
                XCTAssertEqual(CVPixelBufferGetHeight(destination), 8)
                XCTAssertEqual(CVPixelBufferGetWidthOfPlane(destination, 0), 8)
                XCTAssertEqual(CVPixelBufferGetHeightOfPlane(destination, 0), 8)
                XCTAssertEqual(CVPixelBufferGetWidthOfPlane(destination, 1), 4)
                XCTAssertEqual(CVPixelBufferGetHeightOfPlane(destination, 1), 4)
                XCTAssertTrue(
                    try SyntheticNV12PixelBuffer.visibleBytes(
                        destination,
                        plane: 0
                    ).allSatisfy { $0 == 64 }
                )
                let chroma = try SyntheticNV12PixelBuffer.visibleBytes(
                    destination,
                    plane: 1
                )
                XCTAssertTrue(
                    chroma.enumerated().allSatisfy { index, value in
                        value == (index.isMultiple(of: 2) ? 90 : 160)
                    }
                )
                for plane in 0...1 {
                    let padding = try SyntheticNV12PixelBuffer.paddingBytes(
                        destination,
                        plane: plane
                    )
                    XCTAssertFalse(padding.isEmpty)
                    XCTAssertTrue(padding.allSatisfy { $0 == 0xD3 })
                }
                try await prepared.finish()
            }
        }
    }

    func testBothModesPreserveNonconstantVisibleBytesForPaddedIdentityScale() async throws {
        let luma: [UInt8] = [
            16, 24, 32, 40,
            48, 56, 64, 72,
            80, 88, 96, 104,
            112, 120, 128, 136
        ]
        let chroma: [UInt8] = [
            70, 150, 80, 140,
            90, 130, 100, 120
        ]

        for mode in VImageScalingMode.allCases {
            for range in [NV12Range.video, .full] {
                let backend = try XCTUnwrap(VImageBackend(mode: mode))
                let prepared = try await backend.prepare(
                    request: BackendPreparationRequest(
                        source: makeVImageVideoInfo(range: range),
                        targetSize: CGSize(width: 4, height: 4)
                    ),
                    environment: availableVImageEnvironment
                )
                let source = try SyntheticNV12PixelBuffer.make(
                    width: 4,
                    height: 4,
                    pixelFormat: range.pixelFormat
                )
                let destination = try SyntheticNV12PixelBuffer.make(
                    width: 4,
                    height: 4,
                    pixelFormat: range.pixelFormat
                )
                try SyntheticNV12PixelBuffer.fill(
                    source,
                    luma: 0,
                    cb: 0,
                    cr: 0,
                    padding: 0xA6
                )
                try SyntheticNV12PixelBuffer.fill(
                    destination,
                    luma: 0,
                    cb: 0,
                    cr: 0,
                    padding: 0xD4
                )
                try writeVisibleBytes(source, plane: 0, bytes: luma)
                try writeVisibleBytes(source, plane: 1, bytes: chroma)

                try await prepared.process(
                    source: source,
                    destination: destination,
                    timing: testFrameTiming
                )

                XCTAssertEqual(
                    try SyntheticNV12PixelBuffer.visibleBytes(
                        destination,
                        plane: 0
                    ),
                    luma
                )
                XCTAssertEqual(
                    try SyntheticNV12PixelBuffer.visibleBytes(
                        destination,
                        plane: 1
                    ),
                    chroma
                )
                for plane in 0...1 {
                    let padding = try SyntheticNV12PixelBuffer.paddingBytes(
                        destination,
                        plane: plane
                    )
                    XCTAssertFalse(padding.isEmpty)
                    XCTAssertTrue(padding.allSatisfy { $0 == 0xD4 })
                }
                try await prepared.finish()
            }
        }
    }

    func testColorAttachmentsReplaceStaleValuesAndAlwaysPropagate() async throws {
        let backend = try XCTUnwrap(VImageBackend(mode: .standard))
        let prepared = try await backend.prepare(
            request: BackendPreparationRequest(
                source: makeVImageVideoInfo(),
                targetSize: CGSize(width: 8, height: 8)
            ),
            environment: availableVImageEnvironment
        )
        let source = try SyntheticNV12PixelBuffer.make(width: 4, height: 4)
        let destination = try SyntheticNV12PixelBuffer.make(width: 8, height: 8)
        try SyntheticNV12PixelBuffer.fill(source, luma: 64, cb: 90, cr: 160)
        try SyntheticNV12PixelBuffer.fill(destination, luma: 0, cb: 0, cr: 0)

        CVBufferSetAttachment(
            source,
            kCVImageBufferColorPrimariesKey,
            kCVImageBufferColorPrimaries_ITU_R_709_2,
            .shouldNotPropagate
        )
        CVBufferSetAttachment(
            source,
            kCVImageBufferTransferFunctionKey,
            kCVImageBufferTransferFunction_ITU_R_709_2,
            .shouldPropagate
        )
        let sourceColorSpace = try XCTUnwrap(
            CGColorSpace(name: CGColorSpace.sRGB)
        )
        CVBufferSetAttachment(
            source,
            kCVImageBufferCGColorSpaceKey,
            sourceColorSpace,
            .shouldNotPropagate
        )
        let squarePixelAspectRatio = [
            kCVImageBufferPixelAspectRatioHorizontalSpacingKey as String: 1,
            kCVImageBufferPixelAspectRatioVerticalSpacingKey as String: 1
        ] as CFDictionary
        CVBufferSetAttachment(
            source,
            kCVImageBufferPixelAspectRatioKey,
            squarePixelAspectRatio,
            .shouldNotPropagate
        )
        CVBufferSetAttachment(
            destination,
            kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferYCbCrMatrix_ITU_R_601_4,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            destination,
            kCVImageBufferLogTransferFunctionKey,
            kCVImageBufferLogTransferFunction_AppleLog,
            .shouldPropagate
        )
        let staleCleanAperture = [
            kCVImageBufferCleanApertureWidthKey as String: 8,
            kCVImageBufferCleanApertureHeightKey as String: 8,
            kCVImageBufferCleanApertureHorizontalOffsetKey as String: 0,
            kCVImageBufferCleanApertureVerticalOffsetKey as String: 0
        ] as CFDictionary
        CVBufferSetAttachment(
            destination,
            kCVImageBufferCleanApertureKey,
            staleCleanAperture,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            destination,
            kCVImageBufferPreferredCleanApertureKey,
            staleCleanAperture,
            .shouldPropagate
        )

        try await prepared.process(
            source: source,
            destination: destination,
            timing: testFrameTiming
        )

        var primariesMode = CVAttachmentMode.shouldPropagate
        let primaries = CVBufferCopyAttachment(
            destination,
            kCVImageBufferColorPrimariesKey,
            &primariesMode
        ) as? String
        var transferMode = CVAttachmentMode.shouldNotPropagate
        let transfer = CVBufferCopyAttachment(
            destination,
            kCVImageBufferTransferFunctionKey,
            &transferMode
        ) as? String
        var colorSpaceMode = CVAttachmentMode.shouldNotPropagate
        let copiedColorSpace = try XCTUnwrap(
            CVBufferCopyAttachment(
                destination,
                kCVImageBufferCGColorSpaceKey,
                &colorSpaceMode
            )
        )
        var pixelAspectRatioMode = CVAttachmentMode.shouldNotPropagate
        let copiedPixelAspectRatio = try XCTUnwrap(
            CVBufferCopyAttachment(
                destination,
                kCVImageBufferPixelAspectRatioKey,
                &pixelAspectRatioMode
            )
        )

        XCTAssertEqual(
            primaries,
            kCVImageBufferColorPrimaries_ITU_R_709_2 as String
        )
        XCTAssertEqual(primariesMode, .shouldPropagate)
        XCTAssertEqual(
            transfer,
            kCVImageBufferTransferFunction_ITU_R_709_2 as String
        )
        XCTAssertEqual(transferMode, .shouldPropagate)
        XCTAssertTrue(CFEqual(copiedColorSpace, sourceColorSpace))
        XCTAssertEqual(colorSpaceMode, .shouldPropagate)
        XCTAssertTrue(
            CFEqual(copiedPixelAspectRatio, squarePixelAspectRatio)
        )
        XCTAssertEqual(pixelAspectRatioMode, .shouldPropagate)
        XCTAssertNil(
            CVBufferCopyAttachment(
                destination,
                kCVImageBufferYCbCrMatrixKey,
                nil
            )
        )
        XCTAssertNil(
            CVBufferCopyAttachment(
                destination,
                kCVImageBufferLogTransferFunctionKey,
                nil
            )
        )
        XCTAssertNil(
            CVBufferCopyAttachment(
                destination,
                kCVImageBufferCleanApertureKey,
                nil
            )
        )
        XCTAssertNil(
            CVBufferCopyAttachment(
                destination,
                kCVImageBufferPreferredCleanApertureKey,
                nil
            )
        )
    }

    func testInvalidGeometryRangeAndHDRAreUnavailable() async {
        let backend = try! XCTUnwrap(VImageBackend(mode: .standard))

        let oddTarget = await backend.availability(
            for: makeVImageVideoInfo(),
            targetSize: CGSize(width: 7, height: 8),
            environment: availableVImageEnvironment
        )
        XCTAssertEqual(
            oddTarget,
            .unavailable(
                reason: .unsupportedTargetDimensions(
                    width: 7,
                    height: 8,
                    details: "8-bit NV12 requires positive, integral, even target dimensions"
                )
            )
        )

        let unknownRange = await backend.availability(
            for: makeVImageVideoInfo(range: nil),
            targetSize: CGSize(width: 8, height: 8),
            environment: availableVImageEnvironment
        )
        guard case .unavailable(
            reason: .unsupportedPixelFormatOrBitDepth(let rangeDetails)
        ) = unknownRange else {
            return XCTFail("Expected an explicit unknown-range rejection")
        }
        XCTAssertTrue(rangeDetails.contains("range is unknown"))

        let hdr = await backend.availability(
            for: makeVImageVideoInfo(dynamicRange: .hdr),
            targetSize: CGSize(width: 8, height: 8),
            environment: availableVImageEnvironment
        )
        XCTAssertEqual(hdr, .unavailable(reason: .hdrPreservationUnavailable))

        let unknownDynamicRange = await backend.availability(
            for: makeVImageVideoInfo(dynamicRange: .unknown),
            targetSize: CGSize(width: 8, height: 8),
            environment: availableVImageEnvironment
        )
        guard case .unavailable(
            reason: .unsupportedPixelFormatOrBitDepth(let dynamicRangeDetails)
        ) = unknownDynamicRange else {
            return XCTFail("Expected unknown dynamic range to be rejected")
        }
        XCTAssertTrue(dynamicRangeDetails.contains("dynamic range is unknown"))

        let unknownBitDepth = await backend.availability(
            for: makeVImageVideoInfo(bitDepth: nil),
            targetSize: CGSize(width: 8, height: 8),
            environment: availableVImageEnvironment
        )
        XCTAssertEqual(unknownBitDepth, .available)

        let cleanAperture = await backend.availability(
            for: makeVImageVideoInfo(
                cleanAperture: CGRect(x: 0, y: 0, width: 4, height: 4)
            ),
            targetSize: CGSize(width: 8, height: 8),
            environment: availableVImageEnvironment
        )
        XCTAssertEqual(
            cleanAperture,
            .unavailable(
                reason: .unsupportedSourceDimensions(
                    width: 4,
                    height: 4,
                    details: "The initial vImage path does not yet preserve an explicit clean aperture"
                )
            )
        )

        let nonSquarePixels = await backend.availability(
            for: makeVImageVideoInfo(
                pixelAspectRatio: VideoPixelAspectRatio(
                    horizontalSpacing: 4,
                    verticalSpacing: 3
                )
            ),
            targetSize: CGSize(width: 8, height: 8),
            environment: availableVImageEnvironment
        )
        XCTAssertEqual(
            nonSquarePixels,
            .unavailable(
                reason: .unsupportedSourceDimensions(
                    width: 4,
                    height: 4,
                    details: "The initial vImage path supports only square pixels; the source reports 4:3"
                )
            )
        )

        let extremeTarget = await backend.availability(
            for: makeVImageVideoInfo(),
            targetSize: CGSize(width: CGFloat(Int.max), height: 8),
            environment: availableVImageEnvironment
        )
        XCTAssertEqual(
            extremeTarget,
            .unavailable(
                reason: .unsupportedTargetDimensions(
                    width: 0,
                    height: 8,
                    details: "8-bit NV12 requires positive, integral, even target dimensions"
                )
            )
        )
    }

    func testDestinationFormatMismatchIsRejectedBeforeScaling() async throws {
        let backend = try XCTUnwrap(VImageBackend(mode: .standard))
        let prepared = try await backend.prepare(
            request: BackendPreparationRequest(
                source: makeVImageVideoInfo(range: .video),
                targetSize: CGSize(width: 8, height: 8)
            ),
            environment: availableVImageEnvironment
        )
        let source = try SyntheticNV12PixelBuffer.make(width: 4, height: 4)
        let destination = try SyntheticNV12PixelBuffer.make(
            width: 8,
            height: 8,
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        )

        do {
            try await prepared.process(
                source: source,
                destination: destination,
                timing: testFrameTiming
            )
            XCTFail("Expected the destination range mismatch to be rejected")
        } catch let error as VImageScalerError {
            XCTAssertEqual(
                error,
                .invalidPixelFormat(
                    role: .destination,
                    expected: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                    actual: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                )
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testDestinationDimensionsMismatchIsRejectedBeforeScaling() async throws {
        let functions = RecordingVImageFunctions()
        let backend = try XCTUnwrap(
            VImageBackend(mode: .standard, functions: functions)
        )
        let prepared = try await backend.prepare(
            request: BackendPreparationRequest(
                source: makeVImageVideoInfo(),
                targetSize: CGSize(width: 8, height: 8)
            ),
            environment: availableVImageEnvironment
        )
        let source = try SyntheticNV12PixelBuffer.make(width: 4, height: 4)
        let destination = try SyntheticNV12PixelBuffer.make(width: 6, height: 8)

        do {
            try await prepared.process(
                source: source,
                destination: destination,
                timing: testFrameTiming
            )
            XCTFail("Expected the destination dimensions to be rejected")
        } catch let error as VImageScalerError {
            XCTAssertEqual(
                error,
                .invalidDimensions(
                    role: .destination,
                    expectedWidth: 8,
                    expectedHeight: 8,
                    actualWidth: 6,
                    actualHeight: 8
                )
            )
        }
        XCTAssertTrue(functions.processingCalls().isEmpty)
    }

    func testPureNV12LayoutValidationRejectsPlaneCountGeometryAndStride() {
        XCTAssertThrowsError(
            try VImagePixelBufferValidator.validatePlaneCount(
                role: .source,
                actual: 1
            )
        ) { error in
            XCTAssertEqual(
                error as? VImageScalerError,
                .invalidPlaneCount(role: .source, expected: 2, actual: 1)
            )
        }

        XCTAssertThrowsError(
            try VImagePixelBufferValidator.validatePlaneLayout(
                role: .destination,
                plane: 1,
                expectedWidth: 4,
                expectedHeight: 4,
                actualWidth: 3,
                actualHeight: 4,
                bytesPerElement: 2,
                actualBytesPerRow: 8
            )
        ) { error in
            XCTAssertEqual(
                error as? VImageScalerError,
                .invalidPlaneDimensions(
                    role: .destination,
                    plane: 1,
                    expectedWidth: 4,
                    expectedHeight: 4,
                    actualWidth: 3,
                    actualHeight: 4
                )
            )
        }

        XCTAssertThrowsError(
            try VImagePixelBufferValidator.validatePlaneLayout(
                role: .source,
                plane: 1,
                expectedWidth: 4,
                expectedHeight: 4,
                actualWidth: 4,
                actualHeight: 4,
                bytesPerElement: 2,
                actualBytesPerRow: 7
            )
        ) { error in
            XCTAssertEqual(
                error as? VImageScalerError,
                .invalidBytesPerRow(
                    role: .source,
                    plane: 1,
                    minimum: 8,
                    actual: 7
                )
            )
        }
    }

    func testInjectedVImageErrorBecomesContextualMirmirError() async throws {
        let functions = FailingPlanarVImageFunctions()
        let backend = try XCTUnwrap(
            VImageBackend(mode: .standard, functions: functions)
        )
        let prepared = try await backend.prepare(
            request: BackendPreparationRequest(
                source: makeVImageVideoInfo(),
                targetSize: CGSize(width: 8, height: 8)
            ),
            environment: availableVImageEnvironment
        )
        let source = try SyntheticNV12PixelBuffer.make(width: 4, height: 4)
        let destination = try SyntheticNV12PixelBuffer.make(width: 8, height: 8)

        do {
            try await prepared.process(
                source: source,
                destination: destination,
                timing: testFrameTiming
            )
            XCTFail("Expected the injected Planar8 error")
        } catch let error as MirmirError {
            guard case .backendProcessingFailed(
                let backendID,
                let frameIndex,
                let details
            ) = error else {
                return XCTFail("Expected contextual backend processing failure")
            }
            XCTAssertEqual(backendID, .vImageStandard)
            XCTAssertEqual(frameIndex, testFrameTiming.frameIndex)
            XCTAssertTrue(details.contains("vImageScale_Planar8"))
            XCTAssertTrue(details.contains("4 × 4 to 8 × 8"))
            XCTAssertTrue(error.localizedDescription.contains("frame 1"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testInjectedCbCrErrorBecomesContextualMirmirError() async throws {
        let backend = try XCTUnwrap(
            VImageBackend(
                mode: .highQuality,
                functions: FailingCbCrVImageFunctions()
            )
        )
        let prepared = try await backend.prepare(
            request: BackendPreparationRequest(
                source: makeVImageVideoInfo(),
                targetSize: CGSize(width: 8, height: 8)
            ),
            environment: availableVImageEnvironment
        )
        let source = try SyntheticNV12PixelBuffer.make(width: 4, height: 4)
        let destination = try SyntheticNV12PixelBuffer.make(width: 8, height: 8)

        do {
            try await prepared.process(
                source: source,
                destination: destination,
                timing: testFrameTiming
            )
            XCTFail("Expected the injected CbCr8 error")
        } catch let error as MirmirError {
            guard case .backendProcessingFailed(
                let backendID,
                let frameIndex,
                let details
            ) = error else {
                return XCTFail("Expected contextual backend processing failure")
            }
            XCTAssertEqual(backendID, .vImageHighQuality)
            XCTAssertEqual(frameIndex, testFrameTiming.frameIndex)
            XCTAssertTrue(details.contains("vImageScale_CbCr8"))
            XCTAssertTrue(details.contains("plane 1"))
        }
    }

    func testInjectedTemporaryStorageQueryErrorBecomesContextualMirmirError() async throws {
        let backend = try XCTUnwrap(
            VImageBackend(
                mode: .standard,
                functions: FailingQueryVImageFunctions()
            )
        )

        do {
            _ = try await backend.prepare(
                request: BackendPreparationRequest(
                    source: makeVImageVideoInfo(),
                    targetSize: CGSize(width: 8, height: 8)
                ),
                environment: availableVImageEnvironment
            )
            XCTFail("Expected the injected temporary-storage query error")
        } catch let error as MirmirError {
            guard case .backendProcessingFailed(
                let backendID,
                let frameIndex,
                let details
            ) = error else {
                return XCTFail("Expected contextual backend preparation failure")
            }
            XCTAssertEqual(backendID, .vImageStandard)
            XCTAssertNil(frameIndex)
            XCTAssertTrue(details.contains("vImageScale_Planar8"))
            XCTAssertTrue(details.contains("reusable storage"))
        }
    }

    func testInjectedCbCrTemporaryStorageQueryErrorBecomesContextualMirmirError() async throws {
        let backend = try XCTUnwrap(
            VImageBackend(
                mode: .highQuality,
                functions: FailingCbCrQueryVImageFunctions()
            )
        )

        do {
            _ = try await backend.prepare(
                request: BackendPreparationRequest(
                    source: makeVImageVideoInfo(),
                    targetSize: CGSize(width: 8, height: 8)
                ),
                environment: availableVImageEnvironment
            )
            XCTFail("Expected the injected CbCr temporary-storage query error")
        } catch let error as MirmirError {
            guard case .backendProcessingFailed(
                let backendID,
                let frameIndex,
                let details
            ) = error else {
                return XCTFail("Expected contextual backend preparation failure")
            }
            XCTAssertEqual(backendID, .vImageHighQuality)
            XCTAssertNil(frameIndex)
            XCTAssertTrue(details.contains("vImageScale_CbCr8"))
            XCTAssertTrue(details.contains("reusable storage"))
        }
    }

    func testRuntimePQHLGLogAndHDRMetadataAreRejectedBeforeScaling() async throws {
        let functions = RecordingVImageFunctions()
        let backend = try XCTUnwrap(
            VImageBackend(mode: .standard, functions: functions)
        )
        let prepared = try await backend.prepare(
            request: BackendPreparationRequest(
                source: makeVImageVideoInfo(),
                targetSize: CGSize(width: 8, height: 8)
            ),
            environment: availableVImageEnvironment
        )
        let signals: [(key: CFString, value: CFTypeRef, marker: String)] = [
            (
                kCVImageBufferTransferFunctionKey,
                kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,
                "transfer function"
            ),
            (
                kCVImageBufferTransferFunctionKey,
                kCVImageBufferTransferFunction_ITU_R_2100_HLG,
                "transfer function"
            ),
            (
                kCVImageBufferLogTransferFunctionKey,
                kCVImageBufferLogTransferFunction_AppleLog,
                "log transfer"
            ),
            (
                kCVImageBufferMasteringDisplayColorVolumeKey,
                Data([
                    0x84, 0xD0, 0x3E, 0x80,
                    0x33, 0xC2, 0x86, 0xC4,
                    0x1D, 0x4C, 0x0B, 0xB8,
                    0x3D, 0x13, 0x40, 0x42,
                    0x00, 0x98, 0x96, 0x80,
                    0x00, 0x00, 0x00, 0x32
                ]) as CFData,
                "mastering-display"
            ),
            (
                kCVImageBufferContentLightLevelInfoKey,
                Data([0x03, 0xE8, 0x01, 0x90]) as CFData,
                "content-light"
            )
        ]

        for signal in signals {
            let source = try SyntheticNV12PixelBuffer.make(width: 4, height: 4)
            let destination = try SyntheticNV12PixelBuffer.make(
                width: 8,
                height: 8
            )
            CVBufferSetAttachment(
                source,
                signal.key,
                signal.value,
                .shouldPropagate
            )

            do {
                try await prepared.process(
                    source: source,
                    destination: destination,
                    timing: testFrameTiming
                )
                XCTFail("Expected \(signal.marker) to be rejected")
            } catch let error as VImageScalerError {
                guard case .unsupportedHDRSignal(let details) = error else {
                    return XCTFail("Unexpected vImage error: \(error)")
                }
                XCTAssertTrue(details.contains(signal.marker))
            }
        }
        XCTAssertTrue(functions.processingCalls().isEmpty)
    }

    func testRuntimeCleanApertureAndNonSquarePixelsAreRejectedBeforeScaling() async throws {
        let functions = RecordingVImageFunctions()
        let backend = try XCTUnwrap(
            VImageBackend(mode: .standard, functions: functions)
        )
        let prepared = try await backend.prepare(
            request: BackendPreparationRequest(
                source: makeVImageVideoInfo(),
                targetSize: CGSize(width: 8, height: 8)
            ),
            environment: availableVImageEnvironment
        )
        let cleanAperture = [
            kCVImageBufferCleanApertureWidthKey as String: 4,
            kCVImageBufferCleanApertureHeightKey as String: 4,
            kCVImageBufferCleanApertureHorizontalOffsetKey as String: 0,
            kCVImageBufferCleanApertureVerticalOffsetKey as String: 0
        ] as CFDictionary
        let nonSquarePixelAspectRatio = [
            kCVImageBufferPixelAspectRatioHorizontalSpacingKey as String: 4,
            kCVImageBufferPixelAspectRatioVerticalSpacingKey as String: 3
        ] as CFDictionary
        let signals: [(key: CFString, value: CFTypeRef, marker: String)] = [
            (
                kCVImageBufferCleanApertureKey,
                cleanAperture,
                "clean aperture"
            ),
            (
                kCVImageBufferPixelAspectRatioKey,
                nonSquarePixelAspectRatio,
                "square-pixel"
            )
        ]

        for signal in signals {
            let source = try SyntheticNV12PixelBuffer.make(width: 4, height: 4)
            let destination = try SyntheticNV12PixelBuffer.make(
                width: 8,
                height: 8
            )
            CVBufferSetAttachment(
                source,
                signal.key,
                signal.value,
                .shouldPropagate
            )
            do {
                try await prepared.process(
                    source: source,
                    destination: destination,
                    timing: testFrameTiming
                )
                XCTFail("Expected \(signal.marker) to be rejected")
            } catch let error as VImageScalerError {
                guard case .unsupportedGeometrySignal(let details) = error else {
                    return XCTFail("Unexpected vImage error: \(error)")
                }
                XCTAssertTrue(details.contains(signal.marker))
            }
        }
        XCTAssertTrue(functions.processingCalls().isEmpty)
    }

    func testInPlaceBufferIsRejectedBeforeScaling() async throws {
        let functions = RecordingVImageFunctions()
        let backend = try XCTUnwrap(
            VImageBackend(mode: .standard, functions: functions)
        )
        let prepared = try await backend.prepare(
            request: BackendPreparationRequest(
                source: makeVImageVideoInfo(),
                targetSize: CGSize(width: 4, height: 4)
            ),
            environment: availableVImageEnvironment
        )
        let buffer = try SyntheticNV12PixelBuffer.make(width: 4, height: 4)

        do {
            try await prepared.process(
                source: buffer,
                destination: buffer,
                timing: testFrameTiming
            )
            XCTFail("Expected in-place scaling to be rejected")
        } catch let error as VImageScalerError {
            XCTAssertEqual(
                error,
                .inPlaceProcessingUnsupported(backendID: .vImageStandard)
            )
        }
        XCTAssertTrue(functions.processingCalls().isEmpty)
    }

    func testDistinctBuffersWithSharedBackingAreRejectedAndUnlocked() async throws {
        let functions = RecordingVImageFunctions()
        let backend = try XCTUnwrap(
            VImageBackend(mode: .highQuality, functions: functions)
        )
        let prepared = try await backend.prepare(
            request: BackendPreparationRequest(
                source: makeVImageVideoInfo(),
                targetSize: CGSize(width: 4, height: 4)
            ),
            environment: availableVImageEnvironment
        )
        let pair = try SyntheticNV12PixelBuffer.makeSharedBackingPair(
            width: 4,
            height: 4
        )
        XCTAssertFalse(pair.source === pair.destination)

        do {
            try await prepared.process(
                source: pair.source,
                destination: pair.destination,
                timing: testFrameTiming
            )
            XCTFail("Expected shared backing storage to be rejected")
        } catch let error as VImageScalerError {
            guard case .sharedStorageUnsupported(
                let backendID,
                let details
            ) = error else {
                return XCTFail("Unexpected vImage error: \(error)")
            }
            XCTAssertEqual(backendID, .vImageHighQuality)
            XCTAssertTrue(details.contains("overlaps"))
        }
        XCTAssertTrue(functions.processingCalls().isEmpty)
        assertCanRelock(pair.source, flags: .readOnly)
        assertCanRelock(pair.destination, flags: [])

        let validDestination = try SyntheticNV12PixelBuffer.make(
            width: 4,
            height: 4
        )
        try await prepared.process(
            source: pair.source,
            destination: validDestination,
            timing: testFrameTiming
        )
        XCTAssertEqual(
            functions.processingCalls().map(\.function),
            [.planar8, .cbCr8]
        )
    }

    func testCancellationBeforeProcessingSkipsBothPlanes() async throws {
        let functions = RecordingVImageFunctions()
        let backend = try XCTUnwrap(
            VImageBackend(mode: .standard, functions: functions)
        )
        let prepared = try await backend.prepare(
            request: BackendPreparationRequest(
                source: makeVImageVideoInfo(),
                targetSize: CGSize(width: 8, height: 8)
            ),
            environment: availableVImageEnvironment
        )
        let source = FramePixelBuffer(
            try SyntheticNV12PixelBuffer.make(width: 4, height: 4)
        )
        let destination = FramePixelBuffer(
            try SyntheticNV12PixelBuffer.make(width: 8, height: 8)
        )
        let gate = AsyncTestGate()
        let processTask = Task {
            await gate.wait()
            try await prepared.process(
                source: source.value,
                destination: destination.value,
                timing: testFrameTiming
            )
        }
        await gate.waitUntilEntered()
        processTask.cancel()
        await gate.open()

        do {
            try await processTask.value
            XCTFail("Expected cancellation before processing")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertTrue(functions.processingCalls().isEmpty)
    }

    func testCancellationBetweenPlanesSkipsChromaAndAttachmentCopyAndUnlocks() async throws {
        let functions = CancellingAfterPlanarVImageFunctions()
        let backend = try XCTUnwrap(
            VImageBackend(mode: .standard, functions: functions)
        )
        let prepared = try await backend.prepare(
            request: BackendPreparationRequest(
                source: makeVImageVideoInfo(),
                targetSize: CGSize(width: 8, height: 8)
            ),
            environment: availableVImageEnvironment
        )
        let source = FramePixelBuffer(
            try SyntheticNV12PixelBuffer.make(width: 4, height: 4)
        )
        let destination = FramePixelBuffer(
            try SyntheticNV12PixelBuffer.make(width: 8, height: 8)
        )
        CVBufferSetAttachment(
            source.value,
            kCVImageBufferColorPrimariesKey,
            kCVImageBufferColorPrimaries_ITU_R_709_2,
            .shouldPropagate
        )

        let processTask = Task {
            try await prepared.process(
                source: source.value,
                destination: destination.value,
                timing: testFrameTiming
            )
        }
        do {
            try await processTask.value
            XCTFail("Expected cancellation between vImage planes")
        } catch is CancellationError {
            // Expected.
        }

        XCTAssertEqual(functions.processingFunctions(), [.planar8])
        XCTAssertNil(
            CVBufferCopyAttachment(
                destination.value,
                kCVImageBufferColorPrimariesKey,
                nil
            )
        )
        assertCanRelock(source.value, flags: .readOnly)
        assertCanRelock(destination.value, flags: [])
    }

    func testTemporaryStorageIsQueriedOncePerPlaneAndReusedAcrossFrames() async throws {
        for mode in VImageScalingMode.allCases {
            let functions = RecordingVImageFunctions()
            let backend = try XCTUnwrap(
                VImageBackend(mode: mode, functions: functions)
            )
            let prepared = try await backend.prepare(
                request: BackendPreparationRequest(
                    source: makeVImageVideoInfo(),
                    targetSize: CGSize(width: 8, height: 8)
                ),
                environment: availableVImageEnvironment
            )
            let source = try SyntheticNV12PixelBuffer.make(width: 4, height: 4)
            let destination = try SyntheticNV12PixelBuffer.make(
                width: 8,
                height: 8
            )
            try SyntheticNV12PixelBuffer.fill(
                source,
                luma: 64,
                cb: 90,
                cr: 160
            )
            try SyntheticNV12PixelBuffer.fill(
                destination,
                luma: 0,
                cb: 0,
                cr: 0
            )

            try await prepared.process(
                source: source,
                destination: destination,
                timing: testFrameTiming
            )
            try await prepared.process(
                source: source,
                destination: destination,
                timing: FrameTiming(
                    frameIndex: 2,
                    presentationTime: CMTime(value: 2, timescale: 30),
                    duration: CMTime(value: 1, timescale: 30)
                )
            )

            let calls = functions.calls()
            let queryBit = vImage_Flags(kvImageGetTempBufferSize)
            let queryCalls = calls.filter { ($0.flags & queryBit) != 0 }
            let processingCalls = functions.processingCalls()
            XCTAssertEqual(queryCalls.map(\.function), [.planar8, .cbCr8])
            XCTAssertTrue(
                queryCalls.allSatisfy { $0.temporaryBufferAddress == nil }
            )
            XCTAssertEqual(processingCalls.count, 4)
            XCTAssertTrue(
                processingCalls.allSatisfy { $0.flags == mode.resamplingFlags }
            )
            let storageAddresses = Set(
                processingCalls.compactMap(\.temporaryBufferAddress)
            )
            XCTAssertEqual(storageAddresses.count, 1)
            XCTAssertFalse(storageAddresses.isEmpty)
            try await prepared.finish()
        }
    }

    func testFinishIsIdempotentAndPreventsFurtherProcessing() async throws {
        let backend = try XCTUnwrap(VImageBackend(mode: .standard))
        let prepared = try await backend.prepare(
            request: BackendPreparationRequest(
                source: makeVImageVideoInfo(),
                targetSize: CGSize(width: 8, height: 8)
            ),
            environment: availableVImageEnvironment
        )
        let source = try SyntheticNV12PixelBuffer.make(width: 4, height: 4)
        let destination = try SyntheticNV12PixelBuffer.make(width: 8, height: 8)

        try await prepared.finish()
        try await prepared.finish()
        do {
            try await prepared.process(
                source: source,
                destination: destination,
                timing: testFrameTiming
            )
            XCTFail("Expected a finished prepared scaler to reject processing")
        } catch let error as VImageScalerError {
            XCTAssertEqual(
                error,
                .preparedScalerFinished(backendID: .vImageStandard)
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

private enum NV12Range {
    case video
    case full

    var pixelFormat: OSType {
        switch self {
        case .video:
            return kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        case .full:
            return kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        }
    }

    var isFullRange: Bool {
        self == .full
    }
}

private let availableVImageEnvironment = RuntimeEnvironment(
    operatingSystem: RuntimeOperatingSystem(
        OperatingSystemVersion(
            majorVersion: 26,
            minorVersion: 0,
            patchVersion: 0
        )
    ),
    capabilityProbe: AvailableVImageCapabilityProbe()
)

private struct AvailableVImageCapabilityProbe: BackendCapabilityProbing {
    func availability(
        for backendID: UpscaleBackendID,
        source: VideoInfo,
        targetSize: CGSize
    ) async -> BackendAvailability {
        .available
    }
}

private let testFrameTiming = FrameTiming(
    frameIndex: 1,
    presentationTime: CMTime(value: 1, timescale: 30),
    duration: CMTime(value: 1, timescale: 30)
)

private func makeVImageVideoInfo(
    range: NV12Range? = .video,
    dynamicRange: VideoDynamicRange = .sdr,
    bitDepth: Int? = 8,
    fieldCount: Int? = 1,
    cleanAperture: CGRect? = nil,
    pixelAspectRatio: VideoPixelAspectRatio? = VideoPixelAspectRatio(
        horizontalSpacing: 1,
        verticalSpacing: 1
    )
) -> VideoInfo {
    VideoInfo(
        url: URL(fileURLWithPath: "/tmp/vimage-source.mov"),
        duration: CMTime(seconds: 1, preferredTimescale: 600),
        geometry: VideoGeometry(
            encodedSize: CGSize(width: 4, height: 4),
            naturalSize: CGSize(width: 4, height: 4),
            presentationSize: CGSize(width: 4, height: 4),
            displaySize: CGSize(width: 4, height: 4),
            preferredTransform: .identity,
            cleanAperture: cleanAperture,
            pixelAspectRatio: pixelAspectRatio
        ),
        nominalFrameRate: 30,
        minimumFrameDuration: CMTime(value: 1, timescale: 30),
        estimatedFrameCount: 30,
        estimatedDataRate: nil,
        codecFourCC: kCMVideoCodecType_H264,
        hasAudio: false,
        audioTrackCount: 0,
        videoTrackCount: 1,
        isReadable: true,
        isPlayable: true,
        fileSizeBytes: nil,
        color: VideoColorInfo(
            colorPrimaries: kCVImageBufferColorPrimaries_ITU_R_709_2 as String,
            transferFunction: kCVImageBufferTransferFunction_ITU_R_709_2 as String,
            yCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String,
            bitDepth: bitDepth,
            pixelFormat: range?.pixelFormat,
            isFullRange: range?.isFullRange,
            fieldCount: fieldCount,
            fieldDetail: nil,
            alphaModel: .none,
            hasMasteringDisplayMetadata: false,
            hasContentLightLevelMetadata: false,
            dynamicRange: dynamicRange
        )
    )
}

private func writeVisibleBytes(
    _ pixelBuffer: CVPixelBuffer,
    plane: Int,
    bytes: [UInt8]
) throws {
    let lockStatus = CVPixelBufferLockBaseAddress(pixelBuffer, [])
    guard lockStatus == kCVReturnSuccess else {
        throw SyntheticPixelBufferError.lockFailed(lockStatus)
    }
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

    guard let baseAddress = CVPixelBufferGetBaseAddressOfPlane(
        pixelBuffer,
        plane
    ) else {
        throw SyntheticPixelBufferError.missingBaseAddress(plane)
    }
    let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, plane)
    let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
    let visibleRowBytes = width * (plane == 0 ? 1 : 2)
    guard bytes.count == visibleRowBytes * height else {
        throw MirmirError.invalidRequest(
            "The synthetic plane byte count does not match its visible layout."
        )
    }
    let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
    bytes.withUnsafeBytes { sourceBytes in
        guard let sourceBaseAddress = sourceBytes.baseAddress else {
            return
        }
        for rowIndex in 0..<height {
            memcpy(
                baseAddress.advanced(by: rowIndex * rowBytes),
                sourceBaseAddress.advanced(by: rowIndex * visibleRowBytes),
                visibleRowBytes
            )
        }
    }
}

private func assertCanRelock(
    _ pixelBuffer: CVPixelBuffer,
    flags: CVPixelBufferLockFlags,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    let lockStatus = CVPixelBufferLockBaseAddress(pixelBuffer, flags)
    XCTAssertEqual(lockStatus, kCVReturnSuccess, file: file, line: line)
    guard lockStatus == kCVReturnSuccess else {
        return
    }
    let unlockStatus = CVPixelBufferUnlockBaseAddress(pixelBuffer, flags)
    XCTAssertEqual(unlockStatus, kCVReturnSuccess, file: file, line: line)
}

private actor AsyncTestGate {
    private var isOpen = false
    private var hasEntered = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        hasEntered = true
        guard !isOpen else {
            return
        }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilEntered() async {
        while !hasEntered {
            await Task.yield()
        }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

private struct FailingPlanarVImageFunctions: VImageScalingFunctions {
    func scalePlanar8(
        source: inout vImage_Buffer,
        destination: inout vImage_Buffer,
        temporaryBuffer: UnsafeMutableRawPointer?,
        flags: vImage_Flags
    ) -> vImage_Error {
        (flags & vImage_Flags(kvImageGetTempBufferSize)) != 0
            ? 32
            : kvImageInvalidParameter
    }

    func scaleCbCr8(
        source: inout vImage_Buffer,
        destination: inout vImage_Buffer,
        temporaryBuffer: UnsafeMutableRawPointer?,
        flags: vImage_Flags
    ) -> vImage_Error {
        (flags & vImage_Flags(kvImageGetTempBufferSize)) != 0
            ? 16
            : kvImageNoError
    }
}

private final class CancellingAfterPlanarVImageFunctions:
    VImageScalingFunctions,
    @unchecked Sendable {
    private let lock = NSLock()
    private var functions: [VImageScaleFunction] = []

    func scalePlanar8(
        source: inout vImage_Buffer,
        destination: inout vImage_Buffer,
        temporaryBuffer: UnsafeMutableRawPointer?,
        flags: vImage_Flags
    ) -> vImage_Error {
        guard (flags & vImage_Flags(kvImageGetTempBufferSize)) == 0 else {
            return 32
        }
        lock.withLock { functions.append(.planar8) }
        withUnsafeCurrentTask { task in
            task?.cancel()
        }
        return kvImageNoError
    }

    func scaleCbCr8(
        source: inout vImage_Buffer,
        destination: inout vImage_Buffer,
        temporaryBuffer: UnsafeMutableRawPointer?,
        flags: vImage_Flags
    ) -> vImage_Error {
        guard (flags & vImage_Flags(kvImageGetTempBufferSize)) == 0 else {
            return 16
        }
        lock.withLock { functions.append(.cbCr8) }
        return kvImageNoError
    }

    func processingFunctions() -> [VImageScaleFunction] {
        lock.withLock { functions }
    }
}

private struct FailingCbCrVImageFunctions: VImageScalingFunctions {
    func scalePlanar8(
        source: inout vImage_Buffer,
        destination: inout vImage_Buffer,
        temporaryBuffer: UnsafeMutableRawPointer?,
        flags: vImage_Flags
    ) -> vImage_Error {
        (flags & vImage_Flags(kvImageGetTempBufferSize)) != 0
            ? 32
            : kvImageNoError
    }

    func scaleCbCr8(
        source: inout vImage_Buffer,
        destination: inout vImage_Buffer,
        temporaryBuffer: UnsafeMutableRawPointer?,
        flags: vImage_Flags
    ) -> vImage_Error {
        (flags & vImage_Flags(kvImageGetTempBufferSize)) != 0
            ? 16
            : kvImageInvalidParameter
    }
}

private struct FailingQueryVImageFunctions: VImageScalingFunctions {
    func scalePlanar8(
        source: inout vImage_Buffer,
        destination: inout vImage_Buffer,
        temporaryBuffer: UnsafeMutableRawPointer?,
        flags: vImage_Flags
    ) -> vImage_Error {
        (flags & vImage_Flags(kvImageGetTempBufferSize)) != 0
            ? kvImageInvalidParameter
            : kvImageNoError
    }

    func scaleCbCr8(
        source: inout vImage_Buffer,
        destination: inout vImage_Buffer,
        temporaryBuffer: UnsafeMutableRawPointer?,
        flags: vImage_Flags
    ) -> vImage_Error {
        (flags & vImage_Flags(kvImageGetTempBufferSize)) != 0
            ? 16
            : kvImageNoError
    }
}

private struct FailingCbCrQueryVImageFunctions: VImageScalingFunctions {
    func scalePlanar8(
        source: inout vImage_Buffer,
        destination: inout vImage_Buffer,
        temporaryBuffer: UnsafeMutableRawPointer?,
        flags: vImage_Flags
    ) -> vImage_Error {
        (flags & vImage_Flags(kvImageGetTempBufferSize)) != 0
            ? 32
            : kvImageNoError
    }

    func scaleCbCr8(
        source: inout vImage_Buffer,
        destination: inout vImage_Buffer,
        temporaryBuffer: UnsafeMutableRawPointer?,
        flags: vImage_Flags
    ) -> vImage_Error {
        (flags & vImage_Flags(kvImageGetTempBufferSize)) != 0
            ? kvImageInvalidParameter
            : kvImageNoError
    }
}

private final class RecordingVImageFunctions: VImageScalingFunctions,
    @unchecked Sendable {
    struct Call: Equatable {
        let function: VImageScaleFunction
        let flags: vImage_Flags
        let temporaryBufferAddress: UInt?
    }

    private let lock = NSLock()
    private var recordedCalls: [Call] = []
    private let system = SystemVImageScalingFunctions()

    func scalePlanar8(
        source: inout vImage_Buffer,
        destination: inout vImage_Buffer,
        temporaryBuffer: UnsafeMutableRawPointer?,
        flags: vImage_Flags
    ) -> vImage_Error {
        record(
            .planar8,
            flags: flags,
            temporaryBuffer: temporaryBuffer
        )
        return system.scalePlanar8(
            source: &source,
            destination: &destination,
            temporaryBuffer: temporaryBuffer,
            flags: flags
        )
    }

    func scaleCbCr8(
        source: inout vImage_Buffer,
        destination: inout vImage_Buffer,
        temporaryBuffer: UnsafeMutableRawPointer?,
        flags: vImage_Flags
    ) -> vImage_Error {
        record(
            .cbCr8,
            flags: flags,
            temporaryBuffer: temporaryBuffer
        )
        return system.scaleCbCr8(
            source: &source,
            destination: &destination,
            temporaryBuffer: temporaryBuffer,
            flags: flags
        )
    }

    func calls() -> [Call] {
        lock.withLock { recordedCalls }
    }

    func processingCalls() -> [Call] {
        let queryBit = vImage_Flags(kvImageGetTempBufferSize)
        return calls().filter { ($0.flags & queryBit) == 0 }
    }

    private func record(
        _ function: VImageScaleFunction,
        flags: vImage_Flags,
        temporaryBuffer: UnsafeMutableRawPointer?
    ) {
        lock.withLock {
            recordedCalls.append(
                Call(
                    function: function,
                    flags: flags,
                    temporaryBufferAddress: temporaryBuffer.map {
                        UInt(bitPattern: $0)
                    }
                )
            )
        }
    }
}

final class FrameworkChromaPhysicalLocationTests: XCTestCase {
    func testVImagePhysicalLocationsScalesAndEdges() async throws {
        try await verifyPhysicalLocations(backends: [.vImageStandard, .vImageHighQuality])
    }

    func testMPSPhysicalLocationsScalesAndEdges() async throws {
        guard let device = MTLCreateSystemDefaultDevice(), MPSSupportsMTLDevice(device) else {
            throw XCTSkip("This host has no MPS-capable Metal device")
        }
        try await verifyPhysicalLocations(backends: [.mpsBilinear, .mpsLanczos])
    }

    func testUnsupportedAndConflictingLocationsRejectBeforeWritingAndPermitRetry() async throws {
        var backends: [UpscaleBackendID] = [.vImageStandard, .vImageHighQuality]
        if let device = MTLCreateSystemDefaultDevice(), MPSSupportsMTLDevice(device) {
            backends += [.mpsBilinear, .mpsLanczos]
        }
        let format = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        for backend in backends {
            let prepared: any PreparedFrameUpscaler
            if let mode = VImageScalingMode(backendID: backend) {
                prepared = try PreparedVImageScaler(configuration: VImagePreparationConfiguration(mode: mode,
                    pixelFormat: format, sourceWidth: 32, sourceHeight: 32, targetWidth: 64, targetHeight: 64))
            } else {
                prepared = try PreparedMPSScaler(configuration: NV12ScalerConfiguration(backendID: backend,
                    pixelFormat: format, sourceWidth: 32, sourceHeight: 32, targetWidth: 64, targetHeight: 64),
                    mode: try XCTUnwrap(MPSScalingMode(backendID: backend)))
            }
            let source = try buffer(32, 32, pixelFormat: format)
            let destination = try buffer(64, 64, pixelFormat: format)
            for image in [source, destination] {
                CVPixelBufferLockBaseAddress(image, [])
                for plane in 0..<2 {
                    memset(CVPixelBufferGetBaseAddressOfPlane(image, plane)!, 0xA7,
                        CVPixelBufferGetBytesPerRowOfPlane(image, plane) * CVPixelBufferGetHeightOfPlane(image, plane))
                }
                CVPixelBufferUnlockBaseAddress(image, [])
            }
            let sourceBefore = storage(source)
            let destinationBefore = storage(destination)
            let invalid: [(CFString?, CFString?)] = [
                (kCVImageBufferChromaLocation_DV420, nil),
                (nil, kCVImageBufferChromaLocation_Left),
                (kCVImageBufferChromaLocation_Left, kCVImageBufferChromaLocation_Center),
            ]
            for (top, bottom) in invalid {
                CVBufferRemoveAttachment(source, kCVImageBufferChromaLocationTopFieldKey)
                CVBufferRemoveAttachment(source, kCVImageBufferChromaLocationBottomFieldKey)
                if let top { CVBufferSetAttachment(source, kCVImageBufferChromaLocationTopFieldKey, top, .shouldPropagate) }
                if let bottom { CVBufferSetAttachment(source, kCVImageBufferChromaLocationBottomFieldKey, bottom, .shouldPropagate) }
                do {
                    try await prepared.process(source: source, destination: destination, timing: testFrameTiming)
                    XCTFail("\(backend.rawValue) accepted a contradictory/unknown phase")
                } catch let MirmirError.backendProcessingFailed(actual, frameIndex, _) {
                    XCTAssertEqual(actual, backend)
                    XCTAssertEqual(frameIndex, testFrameTiming.frameIndex)
                }
                XCTAssertEqual(sourceBefore, storage(source))
                XCTAssertEqual(destinationBefore, storage(destination))
                XCTAssertEqual(CVBufferCopyAttachment(source, kCVImageBufferChromaLocationTopFieldKey, nil) as? String, top as String?)
                XCTAssertEqual(CVBufferCopyAttachment(source, kCVImageBufferChromaLocationBottomFieldKey, nil) as? String, bottom as String?)
            }
            for key in [kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocationBottomFieldKey] {
                CVBufferSetAttachment(source, key, kCVImageBufferChromaLocation_Left, .shouldPropagate)
            }
            try await prepared.process(source: source, destination: destination, timing: testFrameTiming)
            XCTAssertEqual(sourceBefore, storage(source))
            XCTAssertTrue(try visible(destination).allSatisfy { $0.allSatisfy { $0 == 0xA7 } })
            try await prepared.finish()
        }
    }

    func testCoreImageCubicImpulseResponseMatchesDeclaredFamily() async throws {
        for fullRange in [false, true] {
            let format = fullRange ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            for (width, height) in [(48, 48), (64, 64), (128, 96)] {
                let prepared = PreparedCoreImageScaler(configuration: NV12ScalerConfiguration(backendID: .coreImageBicubic,
                    pixelFormat: format, sourceWidth: 32, sourceHeight: 32, targetWidth: width, targetHeight: height), mode: .bicubic)
                let source = try buffer(32, 32, pixelFormat: format)
                let destination = try buffer(width, height, pixelFormat: format)
                CVPixelBufferLockBaseAddress(source, [])
                for plane in 0..<2 {
                    let bytes = CVPixelBufferGetBaseAddressOfPlane(source, plane)!.assumingMemoryBound(to: UInt8.self)
                    let stride = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
                    for y in 0..<CVPixelBufferGetHeightOfPlane(source, plane) {
                        for x in 0..<CVPixelBufferGetWidthOfPlane(source, plane) {
                            if plane == 0 { bytes[y*stride+x] = 110 }
                            else {
                                bytes[y*stride+2*x] = x == 8 && y == 8 ? 224 : 128
                                bytes[y*stride+2*x+1] = y == 8 ? 224 : 128
                            }
                        }
                    }
                }
                CVPixelBufferUnlockBaseAddress(source, [])
                for key in [kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocationBottomFieldKey] {
                    CVBufferSetAttachment(source, key, kCVImageBufferChromaLocation_Center, .shouldPropagate)
                }
                let before = storage(source)
                try await prepared.process(source: source, destination: destination, timing: testFrameTiming)
                XCTAssertEqual(before, storage(source))
                let actual = try visible(destination)
                XCTAssertTrue(actual[0].allSatisfy { $0 == 110 })
                for y in 0..<(height/2) {
                    let py = (Double(y)+0.5)*32/Double(height)-0.5
                    let wy = cubicWeight(py-8)
                    for x in 0..<(width/2) {
                        let px = (Double(x)+0.5)*32/Double(width)-0.5
                        let wx = cubicWeight(px-8)
                        XCTAssertLessThanOrEqual(abs(Double(actual[1][y*width+2*x]) - (128+96*wx*wy)), 1)
                        XCTAssertLessThanOrEqual(abs(Double(actual[1][y*width+2*x+1]) - (128+96*wy)), 1)
                    }
                }
                try await prepared.finish()
            }
        }
    }

    private func storage(_ buffer: CVPixelBuffer) -> [Data] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        return (0..<2).map { plane in
            Data(bytes: CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!,
                count: CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane))
        }
    }

    func testCoreImagePhysicalLocationsScalesAndEdges() async throws {
        try await verifyPhysicalLocations(backends: [.coreImageLanczos, .coreImageBicubic])
    }

    // Independent two-parameter cubic reference for the backend's unchanged B=0,C=3/4.
    // This sharper cubic family is not an exact affine-ramp interpolant at every phase.
    private func cubicWeight(_ distance: Double) -> Double {
        let x = abs(distance), c = 0.75
        if x < 1 { return ((12 - 6*c)*x*x*x + (-18 + 6*c)*x*x + 6) / 6 }
        if x < 2 { return (-6*c*x*x*x + 30*c*x*x - 48*c*x + 24*c) / 6 }
        return 0
    }

    private func cubicReference(_ input: Data, sourceUVPosition: Double, component: Int) -> Double {
        let first = Int(floor(sourceUVPosition)) - 1
        return (first..<(first + 4)).reduce(0.0) { value, index in
            let clamped = min(15, max(0, index))
            let offset = component == 0 ? 8 * 32 + clamped * 2 : clamped * 32 + 17
            return value + Double(input[offset]) * cubicWeight(sourceUVPosition - Double(index))
        }
    }

    private func verifyPhysicalLocations(backends: [UpscaleBackendID]) async throws {
        let sites: [(String, CFString, Int, Int)] = [
            ("left", kCVImageBufferChromaLocation_Left, 0, 1),
            ("center", kCVImageBufferChromaLocation_Center, 1, 1),
            ("top_left", kCVImageBufferChromaLocation_TopLeft, 0, 0),
            ("top", kCVImageBufferChromaLocation_Top, 1, 0),
            ("bottom_left", kCVImageBufferChromaLocation_BottomLeft, 0, 2),
            ("bottom", kCVImageBufferChromaLocation_Bottom, 1, 2)]
        for backend in backends {
            for fullRange in [false, true] {
                for (tw, th) in [(48, 48), (64, 64), (128, 96)] {
                    let pixelFormat = fullRange ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                    let prepared: any PreparedFrameUpscaler
                    if let mode = VImageScalingMode(backendID: backend) {
                        prepared = try PreparedVImageScaler(configuration: VImagePreparationConfiguration(mode: mode, pixelFormat: pixelFormat, sourceWidth: 32, sourceHeight: 32, targetWidth: tw, targetHeight: th))
                    } else if let mode = CoreImageScalingMode(backendID: backend) {
                        prepared = PreparedCoreImageScaler(configuration: NV12ScalerConfiguration(backendID: backend,
                            pixelFormat: pixelFormat, sourceWidth: 32, sourceHeight: 32, targetWidth: tw, targetHeight: th), mode: mode)
                    } else {
                        prepared = try PreparedMPSScaler(configuration: NV12ScalerConfiguration(backendID: backend, pixelFormat: pixelFormat, sourceWidth: 32, sourceHeight: 32, targetWidth: tw, targetHeight: th), mode: try XCTUnwrap(MPSScalingMode(backendID: backend)))
                    }
                    let destination = try buffer(tw, th, pixelFormat: pixelFormat)
                    for (index, site) in sites.enumerated() {
                        let source = try buffer(32, 32, pixelFormat: pixelFormat)
                        let slope = fullRange ? 8 : 6, baseCode = fullRange ? 4 : 24
                        CVPixelBufferLockBaseAddress(source, [])
                        for plane in 0..<2 {
                            let base = CVPixelBufferGetBaseAddressOfPlane(source, plane)!.assumingMemoryBound(to: UInt8.self)
                            let stride = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
                            for y in 0..<CVPixelBufferGetHeightOfPlane(source, plane) {
                                for x in 0..<CVPixelBufferGetWidthOfPlane(source, plane) {
                                    if plane == 0 { base[y * stride + x] = 110 }
                                    else {
                                        base[y * stride + x * 2] = UInt8(baseCode + slope * (2 * x) + slope * site.2 / 2)
                                        base[y * stride + x * 2 + 1] = UInt8(baseCode + slope * (2 * y) + slope * site.3 / 2)
                                    }
                                }
                            }
                        }
                        CVPixelBufferUnlockBaseAddress(source, [])
                        for (key, value) in [(kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2), (kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2), (kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2), (kCVImageBufferChromaLocationTopFieldKey, site.1), (kCVImageBufferChromaLocationBottomFieldKey, site.1)] {
                            CVBufferSetAttachment(source, key, value, .shouldPropagate)
                        }
                        CVBufferSetAttachment(source, kCVImageBufferFieldCountKey, 1 as CFNumber, .shouldPropagate)
                        CVPixelBufferLockBaseAddress(destination, [])
                        for plane in 0..<2 { memset(CVPixelBufferGetBaseAddressOfPlane(destination, plane)!, 0xD3, CVPixelBufferGetBytesPerRowOfPlane(destination, plane) * CVPixelBufferGetHeightOfPlane(destination, plane)) }
                        CVPixelBufferUnlockBaseAddress(destination, [])
                        let before = try visible(source)
                        try await prepared.process(source: source, destination: destination, timing: FrameTiming(frameIndex: index, presentationTime: CMTime(value: Int64(index), timescale: 24), duration: CMTime(value: 1, timescale: 24)))
                        let after = try visible(source), rendered = try visible(destination)
                        XCTAssertEqual(before, after)
                        XCTAssertTrue(rendered[0].allSatisfy { $0 == 110 })
                        var paddingUntouched = true
                        CVPixelBufferLockBaseAddress(destination, .readOnly)
                        for plane in 0..<2 {
                            let stride = CVPixelBufferGetBytesPerRowOfPlane(destination, plane)
                            let active = CVPixelBufferGetWidthOfPlane(destination, plane) * (plane == 0 ? 1 : 2)
                            let bytes = CVPixelBufferGetBaseAddressOfPlane(destination, plane)!.assumingMemoryBound(to: UInt8.self)
                            for y in 0..<CVPixelBufferGetHeightOfPlane(destination, plane) { for x in active..<stride { if bytes[y * stride + x] != 0xD3 { paddingUntouched = false } } }
                        }
                        CVPixelBufferUnlockBaseAddress(destination, .readOnly)
                        XCTAssertTrue(paddingUntouched)
                        XCTAssertEqual(CVBufferCopyAttachment(destination, kCVImageBufferChromaLocationTopFieldKey, nil) as? String, site.1 as String)
                        XCTAssertEqual(CVBufferCopyAttachment(destination, kCVImageBufferChromaLocationBottomFieldKey, nil) as? String, site.1 as String)
                        // Independent physical luma coordinates. Keep the comparison
                        // rational until the final one-code Apple-filter quantization bound.
                        var compared = 0
                        for y in 0..<(th / 2) {
                            let yNumerator = (4 * y + site.3 + 1) * 32 - th
                            let yDenominator = 2 * th
                            let sourceY = (Double(yNumerator) / Double(yDenominator) - Double(site.3) / 2) / 2
                            guard (5...10).contains(sourceY) else { continue }
                            for x in 0..<(tw / 2) {
                                let xNumerator = (4 * x + site.2 + 1) * 32 - tw
                                let xDenominator = 2 * tw
                                let sourceX = (Double(xNumerator) / Double(xDenominator) - Double(site.2) / 2) / 2
                                guard (5...10).contains(sourceX) else { continue }
                                let cb = Int(rendered[1][y * tw + 2 * x])
                                let cr = Int(rendered[1][y * tw + 2 * x + 1])
                                if backend == .coreImageBicubic {
                                    XCTAssertLessThanOrEqual(abs(Double(cb) - cubicReference(before[1], sourceUVPosition: sourceX, component: 0)), 1)
                                    XCTAssertLessThanOrEqual(abs(Double(cr) - cubicReference(before[1], sourceUVPosition: sourceY, component: 1)), 1)
                                } else {
                                    XCTAssertLessThanOrEqual(abs((cb - baseCode) * xDenominator - slope * xNumerator), xDenominator,
                                        "\(backend.rawValue) \(site.0) \(tw)x\(th) Cb at \(x),\(y)")
                                    XCTAssertLessThanOrEqual(abs((cr - baseCode) * yDenominator - slope * yNumerator), yDenominator,
                                        "\(backend.rawValue) \(site.0) \(tw)x\(th) Cr at \(x),\(y)")
                                }
                                compared += 2
                            }
                        }
                        XCTAssertGreaterThan(compared, 0)
                    }
                    try await prepared.finish()
                    try await prepared.finish()
                }
            }
        }
    }
    private func buffer(_ width: Int, _ height: Int, pixelFormat: OSType) throws -> CVPixelBuffer {
        var value: CVPixelBuffer?
        let result = CVPixelBufferCreate(kCFAllocatorDefault, width, height, pixelFormat, [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &value)
        XCTAssertEqual(result, kCVReturnSuccess)
        return try XCTUnwrap(value)
    }
    private func visible(_ buffer: CVPixelBuffer) throws -> [Data] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly);defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        return (0..<2).map { plane in
            let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!, stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane), count = CVPixelBufferGetWidthOfPlane(buffer, plane) * (plane == 0 ? 1 : 2)
            var result = Data()
            for y in 0..<CVPixelBufferGetHeightOfPlane(buffer, plane) { result.append(Data(bytes: base.advanced(by:y * stride), count:count)) }
            return result
        }
    }
}
