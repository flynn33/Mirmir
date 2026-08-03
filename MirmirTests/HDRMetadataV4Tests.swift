import AVFoundation
import CoreMedia
import CoreVideo
import VideoToolbox
import XCTest
@testable import Mirmir

final class HDRMetadataV4Tests: XCTestCase {
    func testMasteringCLLAndAmbientPayloadsRoundTripBigEndianExactly() throws {
        let staticMetadata = try makeStaticMetadata()
        let mastering = try XCTUnwrap(
            staticMetadata.masteringDisplayColorVolume
        )
        let contentLight = try XCTUnwrap(staticMetadata.contentLightLevelInfo)
        let ambient = try XCTUnwrap(
            staticMetadata.ambientViewingEnvironment
        )

        XCTAssertEqual(mastering.payload.count, 24)
        XCTAssertEqual(
            try MasteringDisplayColorVolumeV4(payload: mastering.payload),
            mastering
        )
        XCTAssertEqual(contentLight.payload, Data([0x03, 0xE8, 0x01, 0x90]))
        XCTAssertEqual(
            try ContentLightLevelInfoV4(payload: contentLight.payload),
            contentLight
        )
        XCTAssertEqual(ambient.payload.count, 8)
        XCTAssertEqual(
            try AmbientViewingEnvironmentV4(payload: ambient.payload),
            ambient
        )
    }

    func testInvalidStaticAndDynamicPayloadsFailClosed() throws {
        XCTAssertThrowsError(
            try MasteringDisplayColorVolumeV4(payload: Data(repeating: 0, count: 23))
        )
        XCTAssertThrowsError(
            try ContentLightLevelInfoV4(
                maximumContentLightLevel: 400,
                maximumFrameAverageLightLevel: 401
            )
        )
        XCTAssertThrowsError(
            try HDRChromaticityV4(x: 40_000, y: 20_000, label: "invalid")
        )
        XCTAssertThrowsError(
            try HDR10PlusMetadataV4(ituTT35Payload: Data([0x00, 0x01]))
        )
        XCTAssertThrowsError(
            try PostDecodeProcessingMetadataV4(propertyList: ["not", "a", "dict"])
        )
        XCTAssertThrowsError(
            try HDRSignalV4(
                storage: .nv12VideoRange8Bit,
                transferFunction: .pq
            )
        )
    }

    func testPQAndHLGFormatDescriptionProbeRequiresBT2020Tags() throws {
        for transfer in [HDRTransferFunctionV4.pq, .hlg] {
            let expected = try makeFormatMetadata(transfer: transfer)
            let description = try makeFormatDescription(metadata: expected)
            XCTAssertEqual(
                try AVFoundationHDRMetadataAdapterV4.probe(
                    formatDescription: description,
                    decodedStorage: .p010VideoRange10Bit
                ),
                expected
            )
        }

        var contradictory = AVFoundationHDRMetadataAdapterV4
            .formatDescriptionExtensions(
                for: try makeFormatMetadata(transfer: .pq)
            )
        contradictory[kCMFormatDescriptionExtension_YCbCrMatrix] =
            kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2
        let description = try makeFormatDescription(extensions: contradictory)
        XCTAssertThrowsError(
            try AVFoundationHDRMetadataAdapterV4.probe(
                formatDescription: description,
                decodedStorage: .p010VideoRange10Bit
            )
        )

        var alternativeConflict = AVFoundationHDRMetadataAdapterV4
            .formatDescriptionExtensions(
                for: try makeFormatMetadata(transfer: .pq)
            )
        alternativeConflict[
            kCMFormatDescriptionExtension_AlternativeTransferCharacteristics
        ] = kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG
        XCTAssertThrowsError(
            try AVFoundationHDRMetadataAdapterV4.probe(
                formatDescription: makeFormatDescription(
                    extensions: alternativeConflict
                ),
                decodedStorage: .p010VideoRange10Bit
            )
        )

        var bitDepthConflict = AVFoundationHDRMetadataAdapterV4
            .formatDescriptionExtensions(
                for: try makeFormatMetadata(transfer: .hlg)
            )
        bitDepthConflict[kCMFormatDescriptionExtension_BitsPerComponent] = 8
        XCTAssertThrowsError(
            try AVFoundationHDRMetadataAdapterV4.probe(
                formatDescription: makeFormatDescription(
                    extensions: bitDepthConflict
                ),
                decodedStorage: .p010VideoRange10Bit
            )
        )
    }

    func testStaticMetadataWithoutPQOrHLGFailsClosed() throws {
        let staticMetadata = try makeStaticMetadata()
        let extensions: [CFString: Any] = [
            kCMFormatDescriptionExtension_ColorPrimaries:
                kCMFormatDescriptionColorPrimaries_ITU_R_709_2,
            kCMFormatDescriptionExtension_TransferFunction:
                kCMFormatDescriptionTransferFunction_ITU_R_709_2,
            kCMFormatDescriptionExtension_YCbCrMatrix:
                kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2,
            kCMFormatDescriptionExtension_MasteringDisplayColorVolume:
                try XCTUnwrap(
                    staticMetadata.masteringDisplayColorVolume
                ).payload as CFData
        ]
        XCTAssertThrowsError(
            try AVFoundationHDRMetadataAdapterV4.probe(
                formatDescription: makeFormatDescription(extensions: extensions),
                decodedStorage: .p010VideoRange10Bit
            )
        ) { error in
            XCTAssertEqual(
                error as? HDRMetadataV4Error,
                .staticMetadataWithoutHDRTransfer
            )
        }
    }

    func testPixelBufferStaticMetadataMigrationRoundTripsAndRejectsConflict() throws {
        for transfer in [HDRTransferFunctionV4.pq, .hlg] {
            let metadata = try makeFormatMetadata(transfer: transfer)
            let buffer = try makePixelBuffer()
            try AVFoundationHDRMetadataAdapterV4.migrate(metadata, to: buffer)
            XCTAssertEqual(
                try AVFoundationHDRMetadataAdapterV4.probe(
                    pixelBuffer: buffer,
                    storage: .p010VideoRange10Bit
                ),
                metadata
            )
            XCTAssertFalse(metadata.signal.permitsToneMapping)
        }

        let conflicting = try makePixelBuffer()
        CVBufferSetAttachment(
            conflicting,
            kCVImageBufferTransferFunctionKey,
            kCVImageBufferTransferFunction_ITU_R_2100_HLG,
            .shouldPropagate
        )
        XCTAssertThrowsError(
            try AVFoundationHDRMetadataAdapterV4.migrate(
                makeFormatMetadata(transfer: .pq),
                to: conflicting
            )
        )
    }

    func testHDR10PlusAndPostDecodeAttachmentsRoundTripOnSampleAndPixelBuffer() throws {
        let dynamic = try makeDynamicMetadata(version: 1)
        let pixelBuffer = try makePixelBuffer()
        let sampleBuffer = try makeSampleBuffer(imageBuffer: pixelBuffer)

        try AVFoundationHDRMetadataAdapterV4.migrate(
            dynamic,
            to: sampleBuffer
        )
        XCTAssertEqual(
            try AVFoundationHDRMetadataAdapterV4.probeDynamicMetadata(
                from: sampleBuffer
            ),
            dynamic
        )

        try AVFoundationHDRMetadataAdapterV4.migrate(
            dynamic,
            to: pixelBuffer
        )
        XCTAssertEqual(
            try AVFoundationHDRMetadataAdapterV4.probeDynamicMetadata(
                from: pixelBuffer
            ),
            dynamic
        )

        XCTAssertThrowsError(
            try AVFoundationHDRMetadataAdapterV4.migrate(
                makeDynamicMetadata(version: 2),
                to: sampleBuffer
            )
        )
    }

    func testWriterPropertiesPreserveDynamicOnlyForUnmodifiedPixels() throws {
        let metadata = try makeFormatMetadata(transfer: .pq)
        XCTAssertThrowsError(
            try AVFoundationHDRMetadataAdapterV4
                .videoToolboxCompressionProperties(
                    for: metadata,
                    dynamicPolicy: .preserveSourceWhenPixelsAreUnmodified,
                    pixelsWereModified: true
                )
        ) { error in
            XCTAssertEqual(
                error as? HDRMetadataV4Error,
                .dynamicMetadataRequiresRegeneration
            )
        }

        let properties = try AVFoundationHDRMetadataAdapterV4
            .videoToolboxCompressionProperties(
                for: metadata,
                dynamicPolicy: .preserveSourceWhenPixelsAreUnmodified,
                pixelsWereModified: false
            )
        XCTAssertEqual(
            properties[
                kVTCompressionPropertyKey_PreserveDynamicHDRMetadata as String
            ] as? Bool,
            true
        )
        XCTAssertEqual(
            properties[
                kVTCompressionPropertyKey_MasteringDisplayColorVolume as String
            ] as? Data,
            metadata.staticMetadata.masteringDisplayColorVolume?.payload
        )
        XCTAssertEqual(
            AVFoundationHDRMetadataAdapterV4.avFoundationColorProperties(
                for: metadata.signal
            ),
            [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey:
                    AVVideoTransferFunction_SMPTE_ST_2084_PQ,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020
            ]
        )
    }

    private func makeFormatMetadata(
        transfer: HDRTransferFunctionV4
    ) throws -> HDRFormatMetadataV4 {
        HDRFormatMetadataV4(
            signal: try HDRSignalV4(
                storage: .p010VideoRange10Bit,
                transferFunction: transfer
            ),
            staticMetadata: try makeStaticMetadata()
        )
    }

    private func makeStaticMetadata() throws -> HDRStaticMetadataV4 {
        let primaries = [
            try HDRChromaticityV4(x: 8_500, y: 39_850, label: "green"),
            try HDRChromaticityV4(x: 6_550, y: 2_300, label: "blue"),
            try HDRChromaticityV4(x: 35_400, y: 14_600, label: "red")
        ]
        return HDRStaticMetadataV4(
            masteringDisplayColorVolume: try MasteringDisplayColorVolumeV4(
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
            ambientViewingEnvironment: AmbientViewingEnvironmentV4(
                ambientIlluminance: 123_456,
                ambientLight: try HDRChromaticityV4(
                    x: 15_635,
                    y: 16_450,
                    label: "ambient"
                )
            )
        )
    }

    private func makeDynamicMetadata(
        version: Int
    ) throws -> HDRDynamicMetadataV4 {
        HDRDynamicMetadataV4(
            hdr10Plus: try HDR10PlusMetadataV4(
                ituTT35Payload: Data([0xB5, 0x00, UInt8(version)])
            ),
            postDecodeProcessing: try PostDecodeProcessingMetadataV4(
                propertyList: NSDictionary(dictionary: [
                    "Profile": "Test",
                    "Version": version,
                    "Flags": [true, false]
                ])
            )
        )
    }

    private func makeFormatDescription(
        metadata: HDRFormatMetadataV4
    ) throws -> CMVideoFormatDescription {
        try makeFormatDescription(
            extensions: AVFoundationHDRMetadataAdapterV4
                .formatDescriptionExtensions(for: metadata)
        )
    }

    private func makeFormatDescription(
        extensions: [CFString: Any]
    ) throws -> CMVideoFormatDescription {
        var description: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            width: 4,
            height: 4,
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &description
        )
        XCTAssertEqual(status, noErr)
        return try XCTUnwrap(description)
    }

    private func makePixelBuffer() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ] as CFDictionary
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            4,
            4,
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            attributes,
            &buffer
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        return try XCTUnwrap(buffer)
    }

    private func makeSampleBuffer(
        imageBuffer: CVPixelBuffer
    ) throws -> CMSampleBuffer {
        var formatDescription: CMVideoFormatDescription?
        XCTAssertEqual(
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: imageBuffer,
                formatDescriptionOut: &formatDescription
            ),
            noErr
        )
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        XCTAssertEqual(
            CMSampleBufferCreateReadyWithImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: imageBuffer,
                formatDescription: try XCTUnwrap(formatDescription),
                sampleTiming: &timing,
                sampleBufferOut: &sampleBuffer
            ),
            noErr
        )
        return try XCTUnwrap(sampleBuffer)
    }
}
