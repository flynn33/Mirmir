import AVFoundation
import CoreMedia
import CoreVideo
import VideoToolbox
import XCTest
@testable import Mirmir

final class VideoWriterFormatContractV4Tests: XCTestCase {
    func testRotatedNonSquareSARAndCleanApertureTransformExactly() throws {
        let source = try RationalPresentationGeometryV4(
            codedWidth: 720,
            codedHeight: 480,
            cleanAperture: CleanApertureV4(
                width: ExactRationalV4(704),
                height: ExactRationalV4(464),
                horizontalOffset: ExactRationalV4(1, 2),
                verticalOffset: ExactRationalV4(-1, 2)
            ),
            sampleAspectRatio: SampleAspectRatioV4(
                horizontalSpacing: 40,
                verticalSpacing: 33
            ),
            preferredTransform: .quarterTurn(1, translationX: 480)
        )
        let contract = try VideoWriterFormatContractV4(
            codec: .h264,
            storage: .nv12VideoRange8Bit,
            color: .sdrBT709,
            sourceGeometry: source,
            outputWidth: 1_440,
            outputHeight: 960,
            frameOperation: .spatialResampling
        )

        XCTAssertEqual(contract.geometry.outputScaleX, try ExactRationalV4(2))
        XCTAssertEqual(contract.geometry.outputScaleY, try ExactRationalV4(2))
        XCTAssertEqual(
            contract.geometry.cleanAperture.width,
            try ExactRationalV4(1_408)
        )
        XCTAssertEqual(
            contract.geometry.cleanAperture.height,
            try ExactRationalV4(928)
        )
        XCTAssertEqual(
            contract.geometry.cleanAperture.horizontalOffset,
            .one
        )
        XCTAssertEqual(
            contract.geometry.cleanAperture.verticalOffset,
            .negativeOne
        )
        XCTAssertEqual(
            contract.geometry.sampleAspectRatio,
            try SampleAspectRatioV4(horizontalSpacing: 40, verticalSpacing: 33)
        )
        XCTAssertEqual(
            contract.geometry.preferredTransform,
            .quarterTurn(1, translationX: 960)
        )
        XCTAssertEqual(
            contract.geometry.avPreferredTransform,
            CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 960, ty: 0)
        )

        let settings = try contract.outputSettings
        XCTAssertNil(settings[AVVideoScalingModeKey])
        let sar = try XCTUnwrap(
            settings[AVVideoPixelAspectRatioKey] as? [String: Any]
        )
        XCTAssertEqual(
            (sar[AVVideoPixelAspectRatioHorizontalSpacingKey] as? NSNumber)?
                .int64Value,
            40
        )
        XCTAssertEqual(
            (sar[AVVideoPixelAspectRatioVerticalSpacingKey] as? NSNumber)?
                .int64Value,
            33
        )
        let aperture = try XCTUnwrap(
            settings[AVVideoCleanApertureKey] as? [String: Any]
        )
        XCTAssertEqual(
            (aperture[AVVideoCleanApertureWidthKey] as? NSNumber)?.doubleValue,
            1_408
        )
        XCTAssertEqual(
            (aperture[AVVideoCleanApertureHeightKey] as? NSNumber)?.doubleValue,
            928
        )
        XCTAssertEqual(
            (aperture[AVVideoCleanApertureHorizontalOffsetKey] as? NSNumber)?
                .doubleValue,
            1
        )
        XCTAssertEqual(
            (aperture[AVVideoCleanApertureVerticalOffsetKey] as? NSNumber)?
                .doubleValue,
            -1
        )

        let formatDescription = try contract.makeExpectedFormatDescription()
        try contract.verifyReopenedFormat(
            formatDescription,
            preferredTransform: contract.geometry.avPreferredTransform
        )
    }

    func testUnequalAxisScaleDerivesCompensatingSAR() throws {
        let source = try sourceGeometry(width: 640, height: 480, sar: (4, 3))
        let contract = try VideoWriterFormatContractV4(
            codec: .hevc,
            storage: .nv12FullRange8Bit,
            color: .sdrBT709,
            sourceGeometry: source,
            outputWidth: 960,
            outputHeight: 960,
            frameOperation: .spatialResampling
        )

        XCTAssertEqual(contract.geometry.outputScaleX, try ExactRationalV4(3, 2))
        XCTAssertEqual(contract.geometry.outputScaleY, try ExactRationalV4(2))
        XCTAssertEqual(
            contract.geometry.sampleAspectRatio,
            try SampleAspectRatioV4(horizontalSpacing: 16, verticalSpacing: 9)
        )
        let bounds = try contract.geometry.rationalGeometry.presentationBounds()
        XCTAssertEqual(bounds.size.width, try ExactRationalV4(5_120, 3))
        XCTAssertEqual(bounds.size.height, try ExactRationalV4(960))

        let mirroredSource = try RationalPresentationGeometryV4(
            codedWidth: 640,
            codedHeight: 480,
            cleanAperture: .fullRaster(width: 640, height: 480),
            preferredTransform: RationalAffineTransformV4(
                a: .negativeOne,
                b: .zero,
                c: .zero,
                d: .one,
                tx: try ExactRationalV4(640),
                ty: .zero
            )
        )
        let mirrored = try VideoWriterFormatContractV4(
            codec: .hevc,
            storage: .nv12VideoRange8Bit,
            color: .sdrBT709,
            sourceGeometry: mirroredSource,
            outputWidth: 960,
            outputHeight: 960,
            frameOperation: .spatialResampling
        )
        XCTAssertEqual(
            mirrored.geometry.preferredTransform.tx,
            try ExactRationalV4(1_280)
        )
        let mirroredBounds = try mirrored.geometry.rationalGeometry
            .presentationBounds()
        XCTAssertEqual(mirroredBounds.origin.x, .zero)
        XCTAssertEqual(mirroredBounds.size.width, try ExactRationalV4(1_280))
    }

    func testNV12AndP010SettingsLockCodecProfilePrecisionAndRange() throws {
        let geometry = try sourceGeometry(width: 64, height: 48)
        let nv12 = try VideoWriterFormatContractV4(
            codec: .h264,
            storage: .nv12VideoRange8Bit,
            color: .sdrBT709,
            sourceGeometry: geometry,
            outputWidth: 128,
            outputHeight: 96,
            frameOperation: .spatialResampling
        )
        let nv12Settings = try nv12.outputSettings
        XCTAssertEqual(
            nv12Settings[AVVideoCodecKey] as? AVVideoCodecType,
            .h264
        )
        let nv12Compression = try XCTUnwrap(
            nv12Settings[AVVideoCompressionPropertiesKey] as? [String: Any]
        )
        XCTAssertEqual(nv12Compression[AVVideoAllowFrameReorderingKey] as? Bool, false)
        XCTAssertEqual(
            nv12Compression[AVVideoProfileLevelKey] as? String,
            kVTProfileLevel_H264_High_AutoLevel as String
        )
        XCTAssertEqual(
            (nv12.sourcePixelBufferAttributes[
                kCVPixelBufferPixelFormatTypeKey as String
            ] as? NSNumber)?.uint32Value,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )

        let p010 = try VideoWriterFormatContractV4(
            codec: .hevc,
            storage: .p010FullRange10Bit,
            color: .sdrBT709,
            sourceGeometry: geometry,
            outputWidth: 128,
            outputHeight: 96,
            frameOperation: .spatialResampling
        )
        let p010Settings = try p010.outputSettings
        let p010Compression = try XCTUnwrap(
            p010Settings[AVVideoCompressionPropertiesKey] as? [String: Any]
        )
        XCTAssertEqual(
            p010Compression[AVVideoProfileLevelKey] as? String,
            kVTProfileLevel_HEVC_Main10_AutoLevel as String
        )
        XCTAssertEqual(
            (p010.sourcePixelBufferAttributes[
                kCVPixelBufferPixelFormatTypeKey as String
            ] as? NSNumber)?.uint32Value,
            kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        )
        try p010.verifyReopenedFormat(
            p010.makeExpectedFormatDescription(),
            preferredTransform: .identity
        )

        XCTAssertThrowsError(
            try VideoWriterFormatContractV4(
                codec: .h264,
                storage: .p010VideoRange10Bit,
                color: .sdrBT709,
                sourceGeometry: geometry,
                outputWidth: 128,
                outputHeight: 96,
                frameOperation: .spatialResampling
            )
        ) { error in
            XCTAssertEqual(
                error as? VideoWriterFormatContractV4Error,
                .incompatibleCodecAndStorage(
                    codec: .h264,
                    storage: .p010VideoRange10Bit
                )
            )
        }
    }

    func testProRes422ContractUsesAPCNWithoutInterframeProfileSettings()
        async throws {
        let contract = try VideoWriterFormatContractV4(
            codec: .proRes422,
            storage: .nv12VideoRange8Bit,
            color: .sdrBT709,
            sourceGeometry: try sourceGeometry(width: 64, height: 48),
            outputWidth: 128,
            outputHeight: 96,
            frameOperation: .spatialResampling
        )

        XCTAssertEqual(contract.codec.avVideoCodecType, .proRes422)
        XCTAssertEqual(
            contract.codec.encodedMediaSubtype,
            kCMVideoCodecType_AppleProRes422
        )
        let settings = try contract.outputSettings
        XCTAssertEqual(
            settings[AVVideoCodecKey] as? AVVideoCodecType,
            .proRes422
        )
        let compression = try XCTUnwrap(
            settings[AVVideoCompressionPropertiesKey] as? [String: Any]
        )
        XCTAssertNil(compression[AVVideoProfileLevelKey])
        XCTAssertEqual(
            (compression[
                kVTCompressionPropertyKey_FieldCount as String
            ] as? NSNumber)?.intValue,
            1
        )
        let expectedExtensions = try contract
            .expectedFormatDescriptionExtensions
        XCTAssertEqual(
            (expectedExtensions[
                kCMFormatDescriptionExtension_BitsPerComponent
            ] as? NSNumber)?.intValue,
            12
        )

        let descriptor = try await AVFoundationVideoFormatCalibratorV4()
            .formatDescriptor(for: contract)
        XCTAssertEqual(descriptor.mediaTypeID, "fourcc_76696465")
        XCTAssertEqual(descriptor.mediaSubtypeID, "fourcc_6170636e")
        XCTAssertEqual(
            descriptor.videoRaster,
            CanonicalRasterV4(width: 128, height: 96)
        )

        let p010Contract = try VideoWriterFormatContractV4(
            codec: .proRes422,
            storage: .p010VideoRange10Bit,
            color: .sdrBT709,
            sourceGeometry: try sourceGeometry(width: 64, height: 48),
            outputWidth: 128,
            outputHeight: 96,
            frameOperation: .spatialResampling
        )
        let p010Descriptor = try await AVFoundationVideoFormatCalibratorV4()
            .formatDescriptor(for: p010Contract)
        XCTAssertEqual(p010Descriptor.mediaSubtypeID, "fourcc_6170636e")
        XCTAssertEqual(
            p010Descriptor.videoRaster,
            CanonicalRasterV4(width: 128, height: 96)
        )
    }

    func testProRes422KeepsEven420RasterPolicyAndRejectsUnqualifiedStorage()
        throws {
        let geometry = try sourceGeometry(width: 64, height: 48)
        XCTAssertNoThrow(try VideoWriterFormatContractV4(
            codec: .proRes422,
            storage: .nv12VideoRange8Bit,
            color: .sdrBT709,
            sourceGeometry: geometry,
            outputWidth: 128,
            outputHeight: 96,
            frameOperation: .spatialResampling
        ))

        for dimensions in [(127, 96), (128, 95)] {
            XCTAssertThrowsError(try VideoWriterFormatContractV4(
                codec: .proRes422,
                storage: .nv12VideoRange8Bit,
                color: .sdrBT709,
                sourceGeometry: geometry,
                outputWidth: dimensions.0,
                outputHeight: dimensions.1,
                frameOperation: .spatialResampling
            )) { error in
                XCTAssertEqual(
                    error as? VideoWriterFormatContractV4Error,
                    .subsampledDimensionsMustBeEven(
                        width: dimensions.0,
                        height: dimensions.1
                    )
                )
            }
        }

        for storage in [
            PixelStorageV4.nv12FullRange8Bit,
            .p010FullRange10Bit
        ] {
            XCTAssertThrowsError(try VideoWriterFormatContractV4(
                codec: .proRes422,
                storage: storage,
                color: .sdrBT709,
                sourceGeometry: geometry,
                outputWidth: 128,
                outputHeight: 96,
                frameOperation: .spatialResampling
            )) { error in
                XCTAssertEqual(
                    error as? VideoWriterFormatContractV4Error,
                    .incompatibleCodecAndStorage(
                        codec: .proRes422,
                        storage: storage
                    )
                )
            }
        }

        XCTAssertThrowsError(try VideoWriterFormatContractV4(
            codec: .proRes422,
            storage: .p010VideoRange10Bit,
            color: .hdr(try hdrMetadata(transfer: .pq)),
            sourceGeometry: geometry,
            outputWidth: 128,
            outputHeight: 96,
            frameOperation: .spatialResampling
        )) { error in
            XCTAssertEqual(
                error as? VideoWriterFormatContractV4Error,
                .hdrRequiresHEVC(codec: .proRes422)
            )
        }
    }

    func testWholeAssetPlannerCreatesOpaqueProRes422Delivery() async throws {
        let video = CanonicalVideoStateV4(
            encodedRaster: CanonicalRasterV4(width: 64, height: 48),
            presentationRaster: CanonicalRasterV4(width: 64, height: 48),
            preferredTransform: .identity,
            cleanAperture: nil,
            pixelAspectRatio: .one,
            pixel: CanonicalPixelStateV4(
                formatID: "nv12_video_range",
                bitDepth: 8,
                range: .video,
                chromaSubsampling: .yuv420,
                chromaSiting: .left,
                alphaModel: .none
            ),
            color: CanonicalColorStateV4(
                primaries:
                    kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String,
                transferFunction:
                    kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String,
                matrix:
                    kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String,
                masteringDisplay: nil,
                contentLightLevel: nil,
                dynamicHDRMetadata: []
            ),
            scan: CanonicalScanStateV4(
                fieldCount: 1,
                dominance: .none,
                cadence: .progressive
            )
        )
        let request = UpscaleRequest(
            inputURL: temporaryMovieURL(),
            outputURL: temporaryMovieURL(),
            backendID: .mirmirDeterministicCPU,
            targetWidth: 128,
            targetHeight: 96,
            outputCodec: .proRes422,
            preserveAudio: false,
            overwriteExistingFile: false
        )

        let delivery = try await DeterministicV4WholeAssetPlanner()
            .prepareVideoDelivery(
                request: request,
                video: video,
                backend: NV12PlanningBackendStub(),
                outputFrameCount: 1
            )
        guard case .opaque(let contract) = delivery else {
            return XCTFail("Expected opaque ProRes 422 delivery")
        }
        XCTAssertEqual(contract.codec, .proRes422)
        XCTAssertEqual(contract.storage, .nv12VideoRange8Bit)
        XCTAssertEqual(contract.frameOperation, .spatialResampling)
    }

    func testPQAndHLGEmitMain10StaticAndDynamicHDRContracts() throws {
        let geometry = try sourceGeometry(width: 64, height: 48)
        for transfer in [HDRTransferFunctionV4.pq, .hlg] {
            let metadata = try hdrMetadata(transfer: transfer)
            let contract = try VideoWriterFormatContractV4(
                codec: .hevc,
                storage: .p010VideoRange10Bit,
                color: .hdr(metadata),
                sourceGeometry: geometry,
                outputWidth: 128,
                outputHeight: 96,
                frameOperation: .spatialResampling,
                sourceContainsDynamicHDRMetadata: true,
                dynamicEncodingPolicy:
                    .preserveSourceSceneMetadataAcrossSpatialResampling
            )
            let settings = try contract.outputSettings
            // Explicit color properties select the wide-color route. Combining
            // them with AVVideoAllowWideColorKey is rejected by AVAssetWriter.
            XCTAssertNil(settings[AVVideoAllowWideColorKey])
            let color = try XCTUnwrap(
                settings[AVVideoColorPropertiesKey] as? [String: String]
            )
            XCTAssertEqual(
                color[AVVideoColorPrimariesKey],
                AVVideoColorPrimaries_ITU_R_2020
            )
            XCTAssertEqual(
                color[AVVideoYCbCrMatrixKey],
                AVVideoYCbCrMatrix_ITU_R_2020
            )
            XCTAssertEqual(
                color[AVVideoTransferFunctionKey],
                transfer == .pq
                    ? AVVideoTransferFunction_SMPTE_ST_2084_PQ
                    : AVVideoTransferFunction_ITU_R_2100_HLG
            )
            let compression = try XCTUnwrap(
                settings[AVVideoCompressionPropertiesKey] as? [String: Any]
            )
            XCTAssertEqual(
                compression[AVVideoProfileLevelKey] as? String,
                kVTProfileLevel_HEVC_Main10_AutoLevel as String
            )
            XCTAssertEqual(
                compression[
                    kVTCompressionPropertyKey_HDRMetadataInsertionMode as String
                ] as? String,
                kVTHDRMetadataInsertionMode_Auto as String
            )
            XCTAssertEqual(
                compression[
                    kVTCompressionPropertyKey_PreserveDynamicHDRMetadata as String
                ] as? Bool,
                true
            )
            XCTAssertEqual(
                compression[
                    kVTCompressionPropertyKey_MasteringDisplayColorVolume
                        as String
                ] as? Data,
                metadata.staticMetadata.masteringDisplayColorVolume?.payload
            )
            XCTAssertEqual(
                compression[
                    kVTCompressionPropertyKey_ContentLightLevelInfo as String
                ] as? Data,
                metadata.staticMetadata.contentLightLevelInfo?.payload
            )

            let description = try contract.makeExpectedFormatDescription()
            try contract.verifyReopenedFormat(
                description,
                preferredTransform: .identity
            )
        }
    }

    func testFieldNormalizationReplicatesSceneMetadataWithoutToneMapping()
        throws {
        let geometry = try sourceGeometry(width: 64, height: 48)
        let metadata = try hdrMetadata(transfer: .pq)
        let contract = try VideoWriterFormatContractV4(
            codec: .hevc,
            storage: .p010VideoRange10Bit,
            color: .hdr(metadata),
            sourceGeometry: geometry,
            outputWidth: 128,
            outputHeight: 96,
            frameOperation: .fieldNormalization,
            sourceContainsDynamicHDRMetadata: true,
            dynamicEncodingPolicy:
                .replicateSourceSceneMetadataAcrossFieldNormalization
        )
        let settings = try contract.outputSettings
        let compression = try XCTUnwrap(
            settings[AVVideoCompressionPropertiesKey] as? [String: Any]
        )
        XCTAssertEqual(
            compression[
                kVTCompressionPropertyKey_PreserveDynamicHDRMetadata as String
            ] as? Bool,
            true
        )
        XCTAssertEqual(contract.frameOperation, .fieldNormalization)

        XCTAssertThrowsError(
            try VideoWriterFormatContractV4(
                codec: .hevc,
                storage: .p010VideoRange10Bit,
                color: .hdr(metadata),
                sourceGeometry: geometry,
                outputWidth: 128,
                outputHeight: 96,
                frameOperation: .frameRateConversion,
                sourceContainsDynamicHDRMetadata: true,
                dynamicEncodingPolicy:
                    .replicateSourceSceneMetadataAcrossFieldNormalization
            )
        ) { error in
            XCTAssertEqual(
                error as? VideoWriterFormatContractV4Error,
                .dynamicHDRIncompatibleOperation(.frameRateConversion)
            )
        }
    }

    func testWholeAssetPlannerAdmitsInterlacedP010HDRFieldNormalization()
        async throws {
        let dynamicMetadata = CanonicalDynamicHDRMetadataV4(
            ordinal: 0,
            formatID: "hdr10_plus",
            payloadSHA256: ASHSHA256V4(
                rawData: Data("field-normalization-scene-0".utf8)
            )
        )
        let ambientViewingEnvironment = CanonicalAmbientViewingEnvironmentV4(
            ambientIlluminance: try ExactRationalV4(123_456, 10_000),
            ambientLightX: try ExactRationalV4(15_635, 50_000),
            ambientLightY: try ExactRationalV4(16_450, 50_000)
        )
        let video = CanonicalVideoStateV4(
            encodedRaster: CanonicalRasterV4(width: 64, height: 48),
            presentationRaster: CanonicalRasterV4(width: 64, height: 48),
            preferredTransform: .identity,
            cleanAperture: nil,
            pixelAspectRatio: .one,
            pixel: CanonicalPixelStateV4(
                formatID: "p010_video_range",
                bitDepth: 10,
                range: .video,
                chromaSubsampling: .yuv420,
                chromaSiting: .left,
                alphaModel: .none
            ),
            color: CanonicalColorStateV4(
                primaries:
                    kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String,
                transferFunction:
                    kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
                        as String,
                matrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_2020 as String,
                masteringDisplay: nil,
                contentLightLevel: nil,
                ambientViewingEnvironment: ambientViewingEnvironment,
                dynamicHDRMetadata: [dynamicMetadata]
            ),
            scan: CanonicalScanStateV4(
                fieldCount: 2,
                dominance: .topFieldFirst,
                cadence: .interlaced
            )
        )
        let request = UpscaleRequest(
            inputURL: temporaryMovieURL(),
            outputURL: temporaryMovieURL(),
            backendID: .mirmirDeterministicCPU,
            targetWidth: 128,
            targetHeight: 96,
            outputCodec: .hevc,
            preserveAudio: true,
            overwriteExistingFile: false
        )

        let delivery = try await DeterministicV4WholeAssetPlanner()
            .prepareVideoDelivery(
                request: request,
                video: video,
                backend: P010PlanningBackendStub(),
                outputFrameCount: 2
            )
        guard case .opaque(let contract) = delivery else {
            return XCTFail("Expected the opaque P010 writer route")
        }
        XCTAssertEqual(contract.codec, .hevc)
        XCTAssertEqual(contract.storage, .p010VideoRange10Bit)
        XCTAssertEqual(contract.frameOperation, .fieldNormalization)
        XCTAssertEqual(
            contract.dynamicEncodingPolicy,
            .replicateSourceSceneMetadataAcrossFieldNormalization
        )
        XCTAssertTrue(contract.sourceContainsDynamicHDRMetadata)
        guard case .hdr(let metadata) = contract.color else {
            return XCTFail("Expected an HDR writer color contract")
        }
        XCTAssertEqual(metadata.signal.storage, .p010VideoRange10Bit)
        XCTAssertEqual(metadata.signal.transferFunction, .pq)
        XCTAssertEqual(
            metadata.staticMetadata.ambientViewingEnvironment,
            try AmbientViewingEnvironmentV4(
                ambientIlluminance: 123_456,
                ambientLight: try HDRChromaticityV4(
                    x: 15_635,
                    y: 16_450,
                    label: "ambient"
                )
            )
        )

        let compression = try XCTUnwrap(
            contract.outputSettings[AVVideoCompressionPropertiesKey]
                as? [String: Any]
        )
        XCTAssertEqual(
            compression[
                kVTCompressionPropertyKey_PreserveDynamicHDRMetadata as String
            ] as? Bool,
            true
        )
    }

    func testSilentToneMapPrecisionLossAndDynamicMetadataLossFailClosed() throws {
        let geometry = try sourceGeometry(width: 64, height: 48)
        let hdr = try hdrMetadata(transfer: .pq)

        XCTAssertThrowsError(
            try VideoWriterFormatContractV4(
                codec: .hevc,
                storage: .nv12VideoRange8Bit,
                color: .hdr(hdr),
                sourceGeometry: geometry,
                outputWidth: 128,
                outputHeight: 96,
                frameOperation: .spatialResampling
            )
        )
        XCTAssertThrowsError(
            try VideoWriterFormatContractV4(
                codec: .hevc,
                storage: .p010VideoRange10Bit,
                color: .hdr(hdr),
                sourceGeometry: geometry,
                outputWidth: 128,
                outputHeight: 96,
                frameOperation: .toneMapping
            )
        ) { error in
            XCTAssertEqual(
                error as? VideoWriterFormatContractV4Error,
                .hdrOperationWouldChangeTransfer(.toneMapping)
            )
        }
        XCTAssertThrowsError(
            try VideoWriterFormatContractV4(
                codec: .hevc,
                storage: .p010VideoRange10Bit,
                color: .hdr(hdr),
                sourceGeometry: geometry,
                outputWidth: 128,
                outputHeight: 96,
                frameOperation: .spatialResampling,
                sourceContainsDynamicHDRMetadata: true,
                dynamicEncodingPolicy: .absent
            )
        )
        XCTAssertThrowsError(
            try VideoWriterFormatContractV4(
                codec: .hevc,
                storage: .p010VideoRange10Bit,
                color: .hdr(hdr),
                sourceGeometry: geometry,
                outputWidth: 128,
                outputHeight: 96,
                frameOperation: .temporalSynthesis,
                sourceContainsDynamicHDRMetadata: true,
                dynamicEncodingPolicy:
                    .preserveSourceSceneMetadataAcrossSpatialResampling
            )
        ) { error in
            XCTAssertEqual(
                error as? VideoWriterFormatContractV4Error,
                .dynamicHDRIncompatibleOperation(.temporalSynthesis)
            )
        }
    }

    func testNonBinaryCleanApertureAndFractionalRotatedTranslationFailClosed()
        throws {
        let thirds = try RationalPresentationGeometryV4(
            codedWidth: 640,
            codedHeight: 480,
            cleanAperture: CleanApertureV4(
                width: ExactRationalV4(1_919, 3),
                height: ExactRationalV4(479),
                horizontalOffset: .zero,
                verticalOffset: .zero
            )
        )
        XCTAssertThrowsError(
            try VideoWriterFormatContractV4(
                codec: .h264,
                storage: .nv12VideoRange8Bit,
                color: .sdrBT709,
                sourceGeometry: thirds,
                outputWidth: 640,
                outputHeight: 480,
                frameOperation: .unmodified
            )
        ) { error in
            guard case .cleanApertureCannotBeRepresentedExactly =
                    error as? VideoWriterFormatContractV4Error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let rotated = try RationalPresentationGeometryV4(
            codedWidth: 720,
            codedHeight: 480,
            cleanAperture: try .fullRaster(width: 720, height: 480),
            preferredTransform: .quarterTurn(1, translationX: 1)
        )
        XCTAssertThrowsError(
            try VideoWriterFormatContractV4(
                codec: .h264,
                storage: .nv12VideoRange8Bit,
                color: .sdrBT709,
                sourceGeometry: rotated,
                outputWidth: 1_080,
                outputHeight: 720,
                frameOperation: .spatialResampling
            )
        ) { error in
            guard case .nonIntegralOutputTransformTranslation =
                    error as? VideoWriterFormatContractV4Error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testFormatDescriptionAndDecodedPixelVerificationRejectDrift() throws {
        let geometry = try sourceGeometry(width: 64, height: 48)
        let metadata = try hdrMetadata(transfer: .hlg)
        let contract = try VideoWriterFormatContractV4(
            codec: .hevc,
            storage: .p010VideoRange10Bit,
            color: .hdr(metadata),
            sourceGeometry: geometry,
            outputWidth: 64,
            outputHeight: 48,
            frameOperation: .unmodified
        )
        let expectedDescription = try contract.makeExpectedFormatDescription()
        XCTAssertNoThrow(
            try contract.verifyReopenedFormat(
                expectedDescription,
                preferredTransform: .identity
            )
        )
        XCTAssertThrowsError(
            try contract.verifyReopenedFormat(
                expectedDescription,
                preferredTransform: CGAffineTransform(
                    translationX: 1,
                    y: 0
                )
            )
        )

        var badExtensions = try contract.expectedFormatDescriptionExtensions
        badExtensions[kCMFormatDescriptionExtension_BitsPerComponent] = 8
        let badDescription = try makeFormatDescription(
            codec: kCMVideoCodecType_HEVC,
            width: 64,
            height: 48,
            extensions: badExtensions
        )
        XCTAssertThrowsError(
            try contract.verifyReopenedFormat(
                badDescription,
                preferredTransform: .identity
            )
        )

        let pixelBuffer = try makePixelBuffer(
            storage: .p010VideoRange10Bit,
            width: 64,
            height: 48
        )
        try AVFoundationHDRMetadataAdapterV4.migrate(metadata, to: pixelBuffer)
        XCTAssertNoThrow(try contract.verifyDecodedPixelBuffer(pixelBuffer))
        let wrongRange = try makePixelBuffer(
            storage: .p010FullRange10Bit,
            width: 64,
            height: 48
        )
        XCTAssertThrowsError(try contract.verifyDecodedPixelBuffer(wrongRange))
    }

    func testFrameBoundDynamicHDRVerifierComparesExactSamplePayload() throws {
        let geometry = try sourceGeometry(width: 64, height: 48)
        let metadata = try hdrMetadata(transfer: .pq)
        let contract = try VideoWriterFormatContractV4(
            codec: .hevc,
            storage: .p010VideoRange10Bit,
            color: .hdr(metadata),
            sourceGeometry: geometry,
            outputWidth: 64,
            outputHeight: 48,
            frameOperation: .unmodified,
            sourceContainsDynamicHDRMetadata: true,
            dynamicEncodingPolicy: .preserveSourceWhenPixelsAreUnmodified
        )
        let pixelBuffer = try makePixelBuffer(
            storage: .p010VideoRange10Bit,
            width: 64,
            height: 48
        )
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        var imageFormatDescription: CMVideoFormatDescription?
        XCTAssertEqual(
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &imageFormatDescription
            ),
            noErr
        )
        var sample: CMSampleBuffer?
        XCTAssertEqual(
            CMSampleBufferCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                dataReady: true,
                makeDataReadyCallback: nil,
                refcon: nil,
                formatDescription: try XCTUnwrap(imageFormatDescription),
                sampleTiming: &timing,
                sampleBufferOut: &sample
            ),
            noErr
        )
        let expected = try dynamicHDRMetadata(seed: 0x11)
        let sampleBuffer = try XCTUnwrap(sample)
        try AVFoundationHDRMetadataAdapterV4.migrate(
            expected,
            to: sampleBuffer
        )
        XCTAssertNoThrow(
            try contract.verifyDynamicHDRMetadata(
                in: sampleBuffer,
                expectedSourceMetadata: expected
            )
        )
        XCTAssertThrowsError(
            try contract.verifyDynamicHDRMetadata(
                in: sampleBuffer,
                expectedSourceMetadata: try dynamicHDRMetadata(seed: 0x22)
            )
        )
    }

    func testRealAVFoundationPreflightAcceptsNV12AndP010HDR() throws {
        let source = try sourceGeometry(width: 64, height: 48)
        let contracts = [
            try VideoWriterFormatContractV4(
                codec: .h264,
                storage: .nv12VideoRange8Bit,
                color: .sdrBT709,
                sourceGeometry: source,
                outputWidth: 64,
                outputHeight: 48,
                frameOperation: .unmodified
            ),
            try VideoWriterFormatContractV4(
                codec: .hevc,
                storage: .p010VideoRange10Bit,
                color: .hdr(try hdrMetadata(transfer: .pq)),
                sourceGeometry: source,
                outputWidth: 64,
                outputHeight: 48,
                frameOperation: .spatialResampling,
                sourceContainsDynamicHDRMetadata: true,
                dynamicEncodingPolicy:
                    .preserveSourceSceneMetadataAcrossSpatialResampling
            )
        ]

        for contract in contracts {
            let url = temporaryMovieURL()
            defer { try? FileManager.default.removeItem(at: url) }
            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            XCTAssertNoThrow(try contract.preflight(writer: writer))
        }
    }

    func testRealAVFoundationWritesReopensAndDecodesP010PQAndHLG() async throws {
        let source = try RationalPresentationGeometryV4(
            codedWidth: 64,
            codedHeight: 48,
            cleanAperture: CleanApertureV4(
                width: ExactRationalV4(62),
                height: ExactRationalV4(46)
            ),
            sampleAspectRatio: SampleAspectRatioV4(
                horizontalSpacing: 4,
                verticalSpacing: 3
            ),
            preferredTransform: .quarterTurn(1, translationX: 48)
        )
        var temporaryURLs: [URL] = []
        defer {
            for url in temporaryURLs {
                try? FileManager.default.removeItem(at: url)
            }
        }

        for transfer in [HDRTransferFunctionV4.pq, .hlg] {
            let metadata = try hdrMetadata(transfer: transfer)
            let contract = try VideoWriterFormatContractV4(
                codec: .hevc,
                storage: .p010VideoRange10Bit,
                color: .hdr(metadata),
                sourceGeometry: source,
                outputWidth: 64,
                outputHeight: 48,
                frameOperation: .unmodified
            )
            let url = temporaryMovieURL()
            temporaryURLs.append(url)
            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            let endpoint = try contract.makeEndpoint(writer: writer)
            XCTAssertTrue(writer.startWriting(), writer.error?.localizedDescription ?? "")
            writer.startSession(atSourceTime: .zero)

            let pixelBuffer = try makePixelBuffer(
                storage: .p010VideoRange10Bit,
                width: 64,
                height: 48
            )
            try fillP010VideoRange(pixelBuffer)
            try AVFoundationHDRMetadataAdapterV4.migrate(
                metadata,
                to: pixelBuffer
            )
            XCTAssertTrue(endpoint.input.isReadyForMoreMediaData)
            XCTAssertTrue(
                endpoint.adaptor.append(
                    pixelBuffer,
                    withPresentationTime: .zero
                ),
                writer.error?.localizedDescription ?? ""
            )
            endpoint.input.markAsFinished()
            await writer.finishWriting()
            XCTAssertEqual(writer.status, .completed)
            XCTAssertNil(writer.error)

            let asset = AVURLAsset(url: url)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            let track = try XCTUnwrap(tracks.first)
            let descriptions = try await track.load(.formatDescriptions)
            let preferredTransform = try await track.load(.preferredTransform)
            try contract.verifyReopenedFormat(
                try XCTUnwrap(descriptions.first),
                preferredTransform: preferredTransform
            )

            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(
                track: track,
                outputSettings: [
                    kCVPixelBufferPixelFormatTypeKey as String:
                        kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                ]
            )
            XCTAssertTrue(reader.canAdd(output))
            reader.add(output)
            XCTAssertTrue(reader.startReading(), reader.error?.localizedDescription ?? "")
            let decodedSample = try XCTUnwrap(output.copyNextSampleBuffer())
            let decodedPixelBuffer = try XCTUnwrap(
                CMSampleBufferGetImageBuffer(decodedSample)
            )
            try contract.verifyDecodedPixelBuffer(decodedPixelBuffer)
            while output.copyNextSampleBuffer() != nil {}
            XCTAssertEqual(reader.status, .completed)
            XCTAssertNil(reader.error)
        }
    }

    private func sourceGeometry(
        width: Int64,
        height: Int64,
        sar: (Int64, Int64) = (1, 1)
    ) throws -> RationalPresentationGeometryV4 {
        try RationalPresentationGeometryV4(
            codedWidth: width,
            codedHeight: height,
            cleanAperture: .fullRaster(width: width, height: height),
            sampleAspectRatio: SampleAspectRatioV4(
                horizontalSpacing: sar.0,
                verticalSpacing: sar.1
            )
        )
    }

    private func hdrMetadata(
        transfer: HDRTransferFunctionV4
    ) throws -> HDRFormatMetadataV4 {
        let primaries = [
            try HDRChromaticityV4(x: 8_500, y: 39_850, label: "green"),
            try HDRChromaticityV4(x: 6_550, y: 2_300, label: "blue"),
            try HDRChromaticityV4(x: 35_400, y: 14_600, label: "red")
        ]
        return HDRFormatMetadataV4(
            signal: try HDRSignalV4(
                storage: .p010VideoRange10Bit,
                transferFunction: transfer
            ),
            staticMetadata: HDRStaticMetadataV4(
                masteringDisplayColorVolume:
                    try MasteringDisplayColorVolumeV4(
                        displayPrimaries: primaries,
                        whitePoint: HDRChromaticityV4(
                            x: 15_635,
                            y: 16_450,
                            label: "white"
                        ),
                        maximumDisplayMasteringLuminance: 10_000_000,
                        minimumDisplayMasteringLuminance: 50
                    ),
                contentLightLevelInfo: try ContentLightLevelInfoV4(
                    maximumContentLightLevel: 1_000,
                    maximumFrameAverageLightLevel: 400
                ),
                ambientViewingEnvironment: try AmbientViewingEnvironmentV4(
                    ambientIlluminance: 1_000,
                    ambientLight: try HDRChromaticityV4(
                        x: 15_635,
                        y: 16_450,
                        label: "ambient"
                    )
                )
            )
        )
    }

    private func dynamicHDRMetadata(
        seed: UInt8
    ) throws -> HDRDynamicMetadataV4 {
        try HDRDynamicMetadataV4(
            hdr10Plus: HDR10PlusMetadataV4(
                ituTT35Payload: Data([
                    0xB5, 0x00, 0x3C, 0x00, 0x01, 0x04, 0x01,
                    seed, seed &+ 1
                ])
            ),
            postDecodeProcessing: PostDecodeProcessingMetadataV4(
                propertyList: ["seed": NSNumber(value: seed)] as NSDictionary
            )
        )
    }

    private func makePixelBuffer(
        storage: PixelStorageV4,
        width: Int,
        height: Int
    ) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            storage.pixelFormat,
            [
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ] as CFDictionary,
            &pixelBuffer
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        return try XCTUnwrap(pixelBuffer)
    }

    private func fillP010VideoRange(_ pixelBuffer: CVPixelBuffer) throws {
        try PixelLayoutV4(storage: .p010VideoRange10Bit)
            .validateStructure(of: pixelBuffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        for plane in 0..<2 {
            let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
            let rowStride = CVPixelBufferGetBytesPerRowOfPlane(
                pixelBuffer,
                plane
            ) / MemoryLayout<UInt16>.stride
            let activeComponents = CVPixelBufferGetWidthOfPlane(
                pixelBuffer,
                plane
            ) * (plane == 0 ? 1 : 2)
            let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane)!
                .assumingMemoryBound(to: UInt16.self)
            for y in 0..<height {
                for x in 0..<activeComponents {
                    base[y * rowStride + x] = UInt16(512 << 6)
                }
            }
        }
    }

    private func makeFormatDescription(
        codec: CMVideoCodecType,
        width: Int32,
        height: Int32,
        extensions: [CFString: Any]
    ) throws -> CMVideoFormatDescription {
        var description: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: codec,
            width: width,
            height: height,
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &description
        )
        XCTAssertEqual(status, noErr)
        return try XCTUnwrap(description)
    }

    private func temporaryMovieURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mirmir-writer-v4-\(UUID().uuidString)")
            .appendingPathExtension("mov")
    }
}

private enum P010PlanningBackendStubError: Error {
    case ashPlanningMustNotRun
}

private struct P010PlanningBackendStub:
    PreparedDeterministicV4PlanningBackend {
    let sourcePixelBufferAttributes = PixelBufferAttributes()
    let destinationPixelBufferAttributes = PixelBufferAttributes()
    let actualBackendID = UpscaleBackendID.mirmirDeterministicCPU
    let deterministicExecutor = ASHExecutorV4.cpuFixedPoint
    let deterministicStorage = PixelStorageV4.p010VideoRange10Bit

    func process(
        source: FramePixelBuffer,
        destination: FramePixelBuffer,
        timing: FrameTiming
    ) async throws {}

    func finish() async throws {}

    func makeASHExecutionPlan(
        media: CanonicalMediaStateV4,
        request: ASHExecutionRequestV4
    ) async throws -> ASHIdentifiedExecutionPlanV4 {
        throw P010PlanningBackendStubError.ashPlanningMustNotRun
    }
}

private struct NV12PlanningBackendStub:
    PreparedDeterministicV4PlanningBackend {
    let sourcePixelBufferAttributes = PixelBufferAttributes()
    let destinationPixelBufferAttributes = PixelBufferAttributes()
    let actualBackendID = UpscaleBackendID.mirmirDeterministicCPU
    let deterministicExecutor = ASHExecutorV4.cpuFixedPoint
    let deterministicStorage = PixelStorageV4.nv12VideoRange8Bit

    func process(
        source: FramePixelBuffer,
        destination: FramePixelBuffer,
        timing: FrameTiming
    ) async throws {}

    func finish() async throws {}

    func makeASHExecutionPlan(
        media: CanonicalMediaStateV4,
        request: ASHExecutionRequestV4
    ) async throws -> ASHIdentifiedExecutionPlanV4 {
        throw P010PlanningBackendStubError.ashPlanningMustNotRun
    }
}
