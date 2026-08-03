import AVFoundation
import XCTest
@testable import Mirmir

final class AVFoundationVideoFormatCalibratorV4Tests: XCTestCase {
    func testCalibrationUsesRealStableEncodedDescriptorAndCache() async throws {
        let contract = try VideoWriterFormatContractV4(
            codec: .h264,
            storage: .nv12VideoRange8Bit,
            color: .sdrBT709,
            sourceGeometry: try geometry(),
            outputWidth: 64,
            outputHeight: 48,
            frameOperation: .spatialResampling
        )
        let calibrator = AVFoundationVideoFormatCalibratorV4()
        let first = try await calibrator.formatDescriptor(for: contract)
        let second = try await calibrator.formatDescriptor(for: contract)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.ordinal, 0)
        XCTAssertEqual(first.mediaTypeID, "fourcc_76696465")
        XCTAssertEqual(first.mediaSubtypeID, "fourcc_61766331")
        XCTAssertEqual(first.completeness, .complete)
    }

    func testCalibrationQualifiesP010PQDescriptorThroughDecode() async throws {
        let contract = try VideoWriterFormatContractV4(
            codec: .hevc,
            storage: .p010VideoRange10Bit,
            color: .hdr(try hdrMetadata()),
            sourceGeometry: try geometry(),
            outputWidth: 64,
            outputHeight: 48,
            frameOperation: .spatialResampling
        )
        let descriptor = try await AVFoundationVideoFormatCalibratorV4()
            .formatDescriptor(for: contract)

        XCTAssertEqual(descriptor.mediaSubtypeID, "fourcc_68766331")
        XCTAssertEqual(descriptor.completeness, .complete)
    }

    private func geometry() throws -> RationalPresentationGeometryV4 {
        try RationalPresentationGeometryV4(
            codedWidth: 32,
            codedHeight: 24,
            cleanAperture: .fullRaster(width: 32, height: 24),
            sampleAspectRatio: SampleAspectRatioV4(
                horizontalSpacing: 4,
                verticalSpacing: 3
            )
        )
    }

    private func hdrMetadata() throws -> HDRFormatMetadataV4 {
        HDRFormatMetadataV4(
            signal: try HDRSignalV4(
                storage: .p010VideoRange10Bit,
                transferFunction: .pq
            ),
            staticMetadata: HDRStaticMetadataV4(
                masteringDisplayColorVolume:
                    try MasteringDisplayColorVolumeV4(
                        displayPrimaries: [
                            try HDRChromaticityV4(
                                x: 8_500,
                                y: 39_850,
                                label: "green"
                            ),
                            try HDRChromaticityV4(
                                x: 6_550,
                                y: 2_300,
                                label: "blue"
                            ),
                            try HDRChromaticityV4(
                                x: 35_400,
                                y: 14_600,
                                label: "red"
                            )
                        ],
                        whitePoint: try HDRChromaticityV4(
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
                ambientViewingEnvironment: nil
            )
        )
    }
}
