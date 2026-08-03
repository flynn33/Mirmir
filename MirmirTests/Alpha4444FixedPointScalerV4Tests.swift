import AVFoundation
import CoreMedia
import CoreVideo
import Metal
import VideoToolbox
import XCTest
@testable import Mirmir

final class Alpha4444FixedPointScalerV4Tests: XCTestCase {
    func testCPUAndMetalHaveByteIdenticalVisibleBGRAForOddStrides() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal is unavailable on this host.")
        }
        let source = try makeBuffer(
            layout: .bgra8,
            width: 5,
            height: 3,
            rowBytes: 33,
            sentinel: 0xD3
        )
        let cpuOutput = try makeBuffer(
            layout: .bgra8,
            width: 9,
            height: 7,
            rowBytes: 47,
            sentinel: 0xA5
        )
        let metalOutput = try makeBuffer(
            layout: .bgra8,
            width: 9,
            height: 7,
            rowBytes: 53,
            sentinel: 0x5A
        )
        try fillSource(source, layout: .bgra8, association: .straight)
        installAssociation(.straight, on: source)
        CVBufferSetAttachment(
            source,
            kCVImageBufferColorPrimariesKey,
            kCVImageBufferColorPrimaries_ITU_R_709_2,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            source,
            kCVImageBufferGammaLevelKey,
            NSNumber(value: 2.2),
            .shouldNotPropagate
        )
        CVBufferSetAttachment(
            cpuOutput,
            kCVImageBufferICCProfileKey,
            Data([1, 2, 3]) as CFData,
            .shouldPropagate
        )

        let cpu = try Alpha4444FixedPointScalerV4(
            backend: .cpu,
            layout: .bgra8,
            sourceAssociation: .straight,
            destinationAssociation: .premultiplied,
            zeroAlphaPolicy: .clearColor,
            sourceWidth: 5,
            sourceHeight: 3,
            targetWidth: 9,
            targetHeight: 7,
            borderRule: .reflect101
        )
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let metal = try Alpha4444FixedPointScalerV4(
            backend: .metal,
            plan: cpu.plan,
            metalDevice: device,
            metalLibrary: try makeFixedPointMetalLibrary(device: device)
        )
        try await cpu.process(source: source, destination: cpuOutput)
        try await metal.process(source: source, destination: metalOutput)

        XCTAssertEqual(
            try visibleBytes(cpuOutput, layout: .bgra8),
            try visibleBytes(metalOutput, layout: .bgra8)
        )
        XCTAssertTrue(try paddingBytes(cpuOutput, layout: .bgra8)
            .allSatisfy { $0 == 0xA5 })
        XCTAssertTrue(try paddingBytes(metalOutput, layout: .bgra8)
            .allSatisfy { $0 == 0x5A })
        for sample in try samples(cpuOutput, layout: .bgra8) {
            XCTAssertLessThanOrEqual(sample.red, sample.alpha)
            XCTAssertLessThanOrEqual(sample.green, sample.alpha)
            XCTAssertLessThanOrEqual(sample.blue, sample.alpha)
            if sample.alpha == 0 {
                XCTAssertEqual(sample.red, 0)
                XCTAssertEqual(sample.green, 0)
                XCTAssertEqual(sample.blue, 0)
            }
        }

        var mode = CVAttachmentMode.shouldNotPropagate
        XCTAssertEqual(
            CVBufferCopyAttachment(
                cpuOutput,
                kCVImageBufferAlphaChannelModeKey,
                &mode
            ) as? String,
            kCVImageBufferAlphaChannelMode_PremultipliedAlpha as String
        )
        XCTAssertEqual(mode, .shouldPropagate)
        XCTAssertEqual(
            CVBufferCopyAttachment(
                cpuOutput,
                kCVImageBufferColorPrimariesKey,
                &mode
            ) as? String,
            kCVImageBufferColorPrimaries_ITU_R_709_2 as String
        )
        XCTAssertEqual(mode, .shouldPropagate)
        XCTAssertEqual(
            CVBufferCopyAttachment(
                cpuOutput,
                kCVImageBufferGammaLevelKey,
                &mode
            ) as? NSNumber,
            NSNumber(value: 2.2)
        )
        XCTAssertEqual(mode, .shouldNotPropagate)
        XCTAssertNil(
            CVBufferCopyAttachment(
                cpuOutput,
                kCVImageBufferICCProfileKey,
                nil
            )
        )
    }

    func test64ARGBIdentityPreservesHiddenStraightColorAndBigEndianBytes()
        async throws {
        let source = try makeBuffer(
            layout: .argb16BigEndian,
            width: 3,
            height: 5,
            rowBytes: 29,
            sentinel: 0xEC
        )
        let destination = try makeBuffer(
            layout: .argb16BigEndian,
            width: 3,
            height: 5,
            rowBytes: 35,
            sentinel: 0x7B
        )
        var values: [AlphaSampleV4] = []
        for index in 0..<15 {
            values.append(
                AlphaSampleV4(
                    red: UInt16((index * 7_919 + 61_000) % 65_536),
                    green: UInt16((index * 3_457 + 123) % 65_536),
                    blue: UInt16((index * 5_003 + 44_000) % 65_536),
                    alpha: index.isMultiple(of: 4)
                        ? 0
                        : UInt16((index * 4_111 + 1_000) % 65_536)
                )
            )
        }
        try writeSamples(values, to: source, layout: .argb16BigEndian)
        installAssociation(.straight, on: source)
        let scaler = try Alpha4444FixedPointScalerV4(
            backend: .cpu,
            layout: .argb16BigEndian,
            sourceAssociation: .straight,
            destinationAssociation: .straight,
            zeroAlphaPolicy: .preserveStraightColor,
            sourceWidth: 3,
            sourceHeight: 5,
            targetWidth: 3,
            targetHeight: 5
        )
        try await scaler.process(source: source, destination: destination)

        XCTAssertEqual(
            try samples(destination, layout: .argb16BigEndian),
            values
        )
        XCTAssertEqual(
            try visibleBytes(destination, layout: .argb16BigEndian),
            try visibleBytes(source, layout: .argb16BigEndian)
        )
        XCTAssertTrue(try paddingBytes(destination, layout: .argb16BigEndian)
            .allSatisfy { $0 == 0x7B })
    }

    func testCPUAndMetalHaveByteIdenticalVisible64ARGBForOddStrides()
        async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal is unavailable on this host.")
        }
        let source = try makeBuffer(
            layout: .argb16BigEndian,
            width: 3,
            height: 5,
            rowBytes: 29,
            sentinel: 0xD1
        )
        let cpuOutput = try makeBuffer(
            layout: .argb16BigEndian,
            width: 7,
            height: 9,
            rowBytes: 63,
            sentinel: 0x8E
        )
        let metalOutput = try makeBuffer(
            layout: .argb16BigEndian,
            width: 7,
            height: 9,
            rowBytes: 67,
            sentinel: 0x4C
        )
        try fillSource(
            source,
            layout: .argb16BigEndian,
            association: .straight
        )
        installAssociation(.straight, on: source)
        let cpu = try Alpha4444FixedPointScalerV4(
            backend: .cpu,
            layout: .argb16BigEndian,
            sourceAssociation: .straight,
            destinationAssociation: .straight,
            zeroAlphaPolicy: .clearColor,
            sourceWidth: 3,
            sourceHeight: 5,
            targetWidth: 7,
            targetHeight: 9,
            borderRule: .reflect101
        )
        let metal = try Alpha4444FixedPointScalerV4(
            backend: .metal,
            plan: cpu.plan,
            metalDevice: device,
            metalLibrary: try makeFixedPointMetalLibrary(device: device)
        )
        try await cpu.process(source: source, destination: cpuOutput)
        try await metal.process(source: source, destination: metalOutput)

        XCTAssertEqual(
            try visibleBytes(cpuOutput, layout: .argb16BigEndian),
            try visibleBytes(metalOutput, layout: .argb16BigEndian)
        )
        XCTAssertTrue(try paddingBytes(cpuOutput, layout: .argb16BigEndian)
            .allSatisfy { $0 == 0x8E })
        XCTAssertTrue(try paddingBytes(metalOutput, layout: .argb16BigEndian)
            .allSatisfy { $0 == 0x4C })
    }

    func testPremultipliedInputIsStraightenedBeforeTheSharedIR() async throws {
        let width = 3
        let height = 3
        let targetWidth = 5
        let targetHeight = 5
        let source = try makeBuffer(
            layout: .bgra8,
            width: width,
            height: height,
            rowBytes: 17,
            sentinel: 0xF1
        )
        let destination = try makeBuffer(
            layout: .bgra8,
            width: targetWidth,
            height: targetHeight,
            rowBytes: 27,
            sentinel: 0xC7
        )
        var straight: [AlphaSampleV4] = []
        for index in 0..<(width * height) {
            let red = UInt16((index * 101 + 43) % 256)
            let green = UInt16((index * 59 + 211) % 256)
            let blue = UInt16((index * 173 + 17) % 256)
            let alpha = UInt16(32 + (index * 23) % 224)
            straight.append(
                AlphaSampleV4(
                    red: red,
                    green: green,
                    blue: blue,
                    alpha: alpha
                )
            )
        }
        let premultiply = try AlphaProcessingPlanV4(
            sourceAssociation: .straight,
            destinationAssociation: .premultiplied,
            zeroAlphaPolicy: .clearColor,
            colorDomain: .fullRangeRGB,
            signalBitDepth: 8
        )
        let premultiplied = try straight.map {
            try AlphaProcessingV4.process($0, using: premultiply)
        }
        try writeSamples(premultiplied, to: source, layout: .bgra8)
        installAssociation(.premultiplied, on: source)

        let scaler = try Alpha4444FixedPointScalerV4(
            backend: .cpu,
            layout: .bgra8,
            sourceAssociation: .premultiplied,
            destinationAssociation: .straight,
            zeroAlphaPolicy: .clearColor,
            sourceWidth: width,
            sourceHeight: height,
            targetWidth: targetWidth,
            targetHeight: targetHeight,
            borderRule: .reflect101
        )
        try await scaler.process(source: source, destination: destination)

        let straighten = try AlphaProcessingPlanV4(
            sourceAssociation: .premultiplied,
            destinationAssociation: .straight,
            zeroAlphaPolicy: .clearColor,
            colorDomain: .fullRangeRGB,
            signalBitDepth: 8
        )
        let recoveredStraight = try premultiplied.map {
            try AlphaProcessingV4.process($0, using: straighten)
        }
        let expected = try scaleComponents(
            recoveredStraight,
            sourceWidth: width,
            plan: scaler.plan
        )
        XCTAssertEqual(try samples(destination, layout: .bgra8), expected)

        let naivelyScaledPremultiplied = try scaleComponents(
            premultiplied,
            sourceWidth: width,
            plan: scaler.plan
        )
        XCTAssertNotEqual(expected, naivelyScaledPremultiplied)
    }

    func testZeroAlphaAndAssociationContractsFailBeforeDestinationMutation()
        async throws {
        let source = try makeBuffer(
            layout: .bgra8,
            width: 1,
            height: 1,
            rowBytes: 9,
            sentinel: 0x11
        )
        let destination = try makeBuffer(
            layout: .bgra8,
            width: 1,
            height: 1,
            rowBytes: 13,
            sentinel: 0xCC
        )
        try writeSamples(
            [AlphaSampleV4(red: 90, green: 0, blue: 0, alpha: 0)],
            to: source,
            layout: .bgra8
        )
        installAssociation(.straight, on: source)
        let before = try allBytes(destination)
        let reject = try Alpha4444FixedPointScalerV4(
            backend: .cpu,
            layout: .bgra8,
            sourceAssociation: .straight,
            destinationAssociation: .straight,
            zeroAlphaPolicy: .rejectNonZeroColor,
            sourceWidth: 1,
            sourceHeight: 1,
            targetWidth: 1,
            targetHeight: 1
        )
        await XCTAssertThrowsAlphaError(
            try await reject.process(
                source: source,
                destination: destination
            )
        ) { error in
            XCTAssertEqual(
                error as? AlphaProcessingV4Error,
                .zeroAlphaColorRejected(red: 90, green: 0, blue: 0)
            )
        }
        XCTAssertEqual(try allBytes(destination), before)

        CVBufferRemoveAttachment(source, kCVImageBufferAlphaChannelModeKey)
        let clear = try Alpha4444FixedPointScalerV4(
            backend: .cpu,
            layout: .bgra8,
            sourceAssociation: .straight,
            destinationAssociation: .straight,
            zeroAlphaPolicy: .clearColor,
            sourceWidth: 1,
            sourceHeight: 1,
            targetWidth: 1,
            targetHeight: 1
        )
        await XCTAssertThrowsAlphaError(
            try await clear.process(source: source, destination: destination)
        ) { error in
            XCTAssertEqual(
                error as? Alpha4444FixedPointScalerV4Error,
                .missingAlphaAssociationAttachment
            )
        }
        XCTAssertEqual(try allBytes(destination), before)

        XCTAssertThrowsError(
            try Alpha4444ScalePlanV4(
                layout: .bgra8,
                sourceAssociation: .straight,
                destinationAssociation: .premultiplied,
                zeroAlphaPolicy: .preserveStraightColor,
                sourceWidth: 1,
                sourceHeight: 1,
                targetWidth: 1,
                targetHeight: 1
            )
        ) { error in
            XCTAssertEqual(
                error as? Alpha4444FixedPointScalerV4Error,
                .hiddenColorCannotBePreservedInPremultipliedOutput
            )
        }
    }

    func testGeometryAttachmentsRequireHigherLevelMigrationWhenScaling()
        async throws {
        let source = try makeBuffer(
            layout: .bgra8,
            width: 3,
            height: 3,
            rowBytes: 17,
            sentinel: 0x11
        )
        let destination = try makeBuffer(
            layout: .bgra8,
            width: 5,
            height: 5,
            rowBytes: 27,
            sentinel: 0xCC
        )
        try fillSource(source, layout: .bgra8, association: .straight)
        installAssociation(.straight, on: source)
        CVBufferSetAttachment(
            source,
            kCVImageBufferCleanApertureKey,
            [
                kCVImageBufferCleanApertureWidthKey as String: 3,
                kCVImageBufferCleanApertureHeightKey as String: 3,
                kCVImageBufferCleanApertureHorizontalOffsetKey as String: 0,
                kCVImageBufferCleanApertureVerticalOffsetKey as String: 0
            ] as CFDictionary,
            .shouldPropagate
        )
        let scaler = try Alpha4444FixedPointScalerV4(
            backend: .cpu,
            layout: .bgra8,
            sourceAssociation: .straight,
            destinationAssociation: .straight,
            zeroAlphaPolicy: .clearColor,
            sourceWidth: 3,
            sourceHeight: 3,
            targetWidth: 5,
            targetHeight: 5
        )
        let before = try allBytes(destination)
        await XCTAssertThrowsAlphaError(
            try await scaler.process(source: source, destination: destination)
        ) { error in
            XCTAssertEqual(
                error as? Alpha4444FixedPointScalerV4Error,
                .geometryAttachmentRequiresMigration(
                    key: kCVImageBufferCleanApertureKey as String
                )
            )
        }
        XCTAssertEqual(try allBytes(destination), before)
    }

    private func scaleComponents(
        _ samples: [AlphaSampleV4],
        sourceWidth: Int,
        plan: Alpha4444ScalePlanV4
    ) throws -> [AlphaSampleV4] {
        let channels: [[UInt16]] = [
            samples.map(\.red),
            samples.map(\.green),
            samples.map(\.blue),
            samples.map(\.alpha)
        ]
        let output = try channels.map {
            try FixedPointCPUExecutorV4.execute(
                source: $0,
                sourceRowStride: sourceWidth,
                scalePlan: plan.spatialPlan,
                kernelIR: plan.kernelIR,
                minimumCode: 0,
                maximumCode: plan.fullScale
            )
        }
        return output[0].indices.map { index in
            AlphaSampleV4(
                red: output[0][index],
                green: output[1][index],
                blue: output[2][index],
                alpha: output[3][index]
            )
        }
    }
}

final class AlphaVideoWriterContractV4Tests: XCTestCase {
    func testWriterAndDecoderSettingsAreAlphaSpecificAndFailClosed()
        throws {
        let proRes = try AlphaVideoWriterContractV4(
            codec: .proRes4444,
            association: .straight,
            width: 17,
            height: 19,
            inputLayout: .argb16BigEndian
        )
        XCTAssertEqual(
            proRes.outputSettings[AVVideoCodecKey] as? AVVideoCodecType,
            .proRes4444
        )
        XCTAssertNil(proRes.outputSettings[AVVideoScalingModeKey])
        XCTAssertNil(proRes.outputSettings[AVVideoColorPropertiesKey])
        let proResCompression = try XCTUnwrap(
            proRes.outputSettings[AVVideoCompressionPropertiesKey]
                as? [String: Any]
        )
        XCTAssertEqual(
            proResCompression[
                kVTCompressionPropertyKey_AlphaChannelMode as String
            ] as? String,
            kVTAlphaChannelMode_StraightAlpha as String
        )
        XCTAssertEqual(
            (proResCompression[
                kVTCompressionPropertyKey_PreserveAlphaChannel as String
            ] as? NSNumber)?.boolValue,
            true
        )
        XCTAssertNil(
            proResCompression[
                kVTCompressionPropertyKey_TargetQualityForAlpha as String
            ]
        )
        XCTAssertEqual(proRes.decoderOutputSettings.count, 1)
        XCTAssertNil(
            proRes.decoderOutputSettings[kCVPixelBufferWidthKey as String]
        )
        XCTAssertNil(
            proRes.decoderOutputSettings[kCVPixelBufferHeightKey as String]
        )

        let hevc = try AlphaVideoWriterContractV4(
            codec: .hevcWithAlpha,
            association: .premultiplied,
            width: 17,
            height: 19,
            inputLayout: .bgra8
        )
        let hevcCompression = try XCTUnwrap(
            hevc.outputSettings[AVVideoCompressionPropertiesKey]
                as? [String: Any]
        )
        XCTAssertNil(
            hevcCompression[
                kVTCompressionPropertyKey_PreserveAlphaChannel as String
            ]
        )
        XCTAssertEqual(
            (hevcCompression[
                kVTCompressionPropertyKey_TargetQualityForAlpha as String
            ] as? NSNumber)?.doubleValue,
            1.0
        )
        XCTAssertEqual(
            hevcCompression[
                kVTCompressionPropertyKey_AlphaChannelMode as String
            ] as? String,
            kVTAlphaChannelMode_PremultipliedAlpha as String
        )

        XCTAssertThrowsError(
            try AlphaVideoWriterContractV4(
                codec: .hevcWithAlpha,
                association: .straight,
                width: 16,
                height: 16,
                inputLayout: .argb16BigEndian
            )
        ) { error in
            XCTAssertEqual(
                error as? AlphaVideoWriterContractV4Error,
                .unsupportedInputLayout(
                    codec: .hevcWithAlpha,
                    layout: .argb16BigEndian
                )
            )
        }
    }

    func testFormatDescriptionValidationRequiresExactAlphaSemantics()
        throws {
        let contract = try AlphaVideoWriterContractV4(
            codec: .proRes4444,
            association: .straight,
            width: 17,
            height: 19,
            inputLayout: .bgra8
        )
        let valid = try makeFormatDescription(
            codec: kCMVideoCodecType_AppleProRes4444,
            width: 17,
            height: 19,
            containsAlpha: true,
            association: kCMFormatDescriptionAlphaChannelMode_StraightAlpha,
            depth: 32
        )
        XCTAssertNoThrow(
            try contract.validateEncodedFormatDescription(valid)
        )

        let missingMode = try makeFormatDescription(
            codec: kCMVideoCodecType_AppleProRes4444,
            width: 17,
            height: 19,
            containsAlpha: true,
            association: nil,
            depth: 32
        )
        XCTAssertThrowsError(
            try contract.validateEncodedFormatDescription(missingMode)
        ) { error in
            XCTAssertEqual(
                error as? AlphaVideoWriterContractV4Error,
                .encodedAlphaAssociationMissing
            )
        }

        let absentAlpha = try makeFormatDescription(
            codec: kCMVideoCodecType_AppleProRes4444,
            width: 17,
            height: 19,
            containsAlpha: false,
            association: kCMFormatDescriptionAlphaChannelMode_StraightAlpha,
            depth: 32
        )
        XCTAssertThrowsError(
            try contract.validateEncodedFormatDescription(absentAlpha)
        ) { error in
            XCTAssertEqual(
                error as? AlphaVideoWriterContractV4Error,
                .encodedAlphaPresenceMissingOrFalse
            )
        }
    }

    func testPublicAVFoundationAlphaRoundTrips() async throws {
        for codec in [
            AlphaVideoWriterCodecV4.proRes4444,
            .hevcWithAlpha
        ] {
            let contract = try AlphaVideoWriterContractV4(
                codec: codec,
                association: .straight,
                width: 16,
                height: 16,
                inputLayout: .bgra8
            )
            let result: (expected: [UInt16], decoded: [UInt16])
            do {
                result = try await encodeAndDecodeOneFrame(contract)
            } catch AlphaVideoWriterContractV4Error
                .writerRejectedOutputSettings {
                throw XCTSkip("\(codec.rawValue) encoder is unavailable.")
            }
            XCTAssertEqual(result.decoded.count, result.expected.count)
            if codec == .proRes4444 {
                // AVFoundation documents the ProRes 4444 alpha plane as
                // mathematically lossless.
                XCTAssertEqual(result.decoded, result.expected)
            } else {
                // HEVC alpha quality 1.0 is documented as nearly lossless,
                // not mathematically lossless. Prove that the alpha plane
                // survived without inventing a byte-exact codec guarantee.
                XCTAssertLessThan(try XCTUnwrap(result.decoded.min()), 32)
                XCTAssertGreaterThan(try XCTUnwrap(result.decoded.max()), 220)
                XCTAssertGreaterThan(Set(result.decoded).count, 16)
            }
        }
    }

    func testPublicAVFoundationHighBitDepthProResAlphaRoundTripIsLossless()
        async throws {
        let contract = try AlphaVideoWriterContractV4(
            codec: .proRes4444,
            association: .straight,
            width: 16,
            height: 16,
            inputLayout: .argb16BigEndian
        )
        let result: (expected: [UInt16], decoded: [UInt16])
        do {
            result = try await encodeAndDecodeOneFrame(contract)
        } catch AlphaVideoWriterContractV4Error
            .writerRejectedOutputSettings {
            throw XCTSkip("ProRes 4444 encoder is unavailable.")
        }
        XCTAssertEqual(result.decoded, result.expected)
    }

    private func encodeAndDecodeOneFrame(
        _ contract: AlphaVideoWriterContractV4
    ) async throws -> (expected: [UInt16], decoded: [UInt16]) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mirmir-alpha-v4-\(UUID().uuidString).mov"
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        try contract.preflight(writer: writer)
        let endpoint = try contract.makeEndpoint(writer: writer)
        guard writer.startWriting() else {
            throw Alpha4444TestError.writer(
                writer.error?.localizedDescription ?? "startWriting failed"
            )
        }
        writer.startSession(atSourceTime: .zero)
        guard let pool = endpoint.adaptor.pixelBufferPool else {
            throw Alpha4444TestError.writer("missing pixel-buffer pool")
        }
        var optionalBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(
            nil,
            pool,
            &optionalBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer = optionalBuffer else {
            throw Alpha4444TestError.coreVideo(status)
        }
        installAssociation(contract.association, on: pixelBuffer)
        let expected = try fillEncodedFixture(
            pixelBuffer,
            layout: contract.inputLayout
        )
        try contract.validateInputPixelBuffer(pixelBuffer)
        while !endpoint.input.isReadyForMoreMediaData {
            if writer.status == .failed {
                throw Alpha4444TestError.writer(
                    writer.error?.localizedDescription ?? "writer failed"
                )
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        guard endpoint.adaptor.append(pixelBuffer, withPresentationTime: .zero)
        else {
            throw Alpha4444TestError.writer(
                writer.error?.localizedDescription ?? "append failed"
            )
        }
        endpoint.input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw Alpha4444TestError.writer(
                writer.error?.localizedDescription ?? "finishWriting failed"
            )
        }

        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let descriptions = try await track.load(.formatDescriptions)
        let description = try XCTUnwrap(descriptions.first)
        try contract.validateEncodedFormatDescription(description)

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: contract.decoderOutputSettings
        )
        guard reader.canAdd(output) else {
            throw Alpha4444TestError.reader("reader rejected output")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw Alpha4444TestError.reader(
                reader.error?.localizedDescription ?? "reader start failed"
            )
        }
        let sampleBuffer = try XCTUnwrap(output.copyNextSampleBuffer())
        let decodedBuffer = try XCTUnwrap(
            CMSampleBufferGetImageBuffer(sampleBuffer)
        )
        try contract.validateInputPixelBuffer(decodedBuffer)
        return (
            expected,
            try samples(decodedBuffer, layout: contract.inputLayout).map(\.alpha)
        )
    }
}

private enum Alpha4444TestError: Error {
    case coreVideo(CVReturn)
    case coreMedia(OSStatus)
    case writer(String)
    case reader(String)
}

private func makeFixedPointMetalLibrary(device: MTLDevice) throws -> MTLLibrary {
    let testFile = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
    let repositoryRoot = testFile
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let sourceURL = repositoryRoot.appendingPathComponent(
        "Mirmir/Modules/UpscalerEngine/FixedPointMetalKernelsV4.metal"
    )
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    return try device.makeLibrary(source: source, options: nil)
}

private func makeBuffer(
    layout: Alpha4444PackedLayoutV4,
    width: Int,
    height: Int,
    rowBytes: Int,
    sentinel: UInt8
) throws -> CVPixelBuffer {
    let byteCount = rowBytes * height
    let memory = UnsafeMutableRawPointer.allocate(
        byteCount: byteCount,
        alignment: 64
    )
    memory.initializeMemory(as: UInt8.self, repeating: sentinel, count: byteCount)
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreateWithBytes(
        kCFAllocatorDefault,
        width,
        height,
        layout.pixelFormat,
        memory,
        rowBytes,
        { _, baseAddress in baseAddress?.deallocate() },
        nil,
        nil,
        &buffer
    )
    guard status == kCVReturnSuccess, let buffer else {
        memory.deallocate()
        throw Alpha4444TestError.coreVideo(status)
    }
    return buffer
}

private func fillSource(
    _ buffer: CVPixelBuffer,
    layout: Alpha4444PackedLayoutV4,
    association: AlphaAssociationV4
) throws {
    let width = CVPixelBufferGetWidth(buffer)
    let height = CVPixelBufferGetHeight(buffer)
    let maximum = layout.signalBitDepth == 8 ? 255 : 65_535
    var straight: [AlphaSampleV4] = []
    for y in 0..<height {
        for x in 0..<width {
            let alpha = (x + y).isMultiple(of: 5)
                ? 0
                : UInt16((x * 41 + y * 67 + 29) % (maximum + 1))
            straight.append(
                AlphaSampleV4(
                    red: UInt16((x * 83 + y * 19 + 211) % (maximum + 1)),
                    green: UInt16((x * 17 + y * 97 + 37) % (maximum + 1)),
                    blue: UInt16((x * 53 + y * 71 + 149) % (maximum + 1)),
                    alpha: alpha
                )
            )
        }
    }
    let values: [AlphaSampleV4]
    switch association {
    case .straight:
        values = straight
    case .premultiplied:
        let plan = try AlphaProcessingPlanV4(
            sourceAssociation: .straight,
            destinationAssociation: .premultiplied,
            zeroAlphaPolicy: .clearColor,
            colorDomain: .fullRangeRGB,
            signalBitDepth: layout.signalBitDepth
        )
        values = try straight.map {
            try AlphaProcessingV4.process($0, using: plan)
        }
    }
    try writeSamples(values, to: buffer, layout: layout)
}

private func installAssociation(
    _ association: AlphaAssociationV4,
    on buffer: CVPixelBuffer
) {
    let value: CFString = association == .straight
        ? kCVImageBufferAlphaChannelMode_StraightAlpha
        : kCVImageBufferAlphaChannelMode_PremultipliedAlpha
    CVBufferSetAttachment(
        buffer,
        kCVImageBufferAlphaChannelModeKey,
        value,
        .shouldPropagate
    )
}

private func writeSamples(
    _ values: [AlphaSampleV4],
    to buffer: CVPixelBuffer,
    layout: Alpha4444PackedLayoutV4
) throws {
    let width = CVPixelBufferGetWidth(buffer)
    let height = CVPixelBufferGetHeight(buffer)
    XCTAssertEqual(values.count, width * height)
    XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, []), kCVReturnSuccess)
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
        .assumingMemoryBound(to: UInt8.self)
    let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
    for y in 0..<height {
        for x in 0..<width {
            let sample = values[y * width + x]
            let pixel = base + y * rowBytes + x * layout.bytesPerPixel
            try writeTestComponent(sample.red, .red, to: pixel, layout: layout)
            try writeTestComponent(sample.green, .green, to: pixel, layout: layout)
            try writeTestComponent(sample.blue, .blue, to: pixel, layout: layout)
            try writeTestComponent(sample.alpha, .alpha, to: pixel, layout: layout)
        }
    }
}

private func samples(
    _ buffer: CVPixelBuffer,
    layout: Alpha4444PackedLayoutV4
) throws -> [AlphaSampleV4] {
    let width = CVPixelBufferGetWidth(buffer)
    let height = CVPixelBufferGetHeight(buffer)
    XCTAssertEqual(
        CVPixelBufferLockBaseAddress(buffer, .readOnly),
        kCVReturnSuccess
    )
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
        .assumingMemoryBound(to: UInt8.self)
    let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
    var result: [AlphaSampleV4] = []
    for y in 0..<height {
        for x in 0..<width {
            let pixel = base + y * rowBytes + x * layout.bytesPerPixel
            result.append(
                AlphaSampleV4(
                    red: try readTestComponent(.red, from: pixel, layout: layout),
                    green: try readTestComponent(
                        .green,
                        from: pixel,
                        layout: layout
                    ),
                    blue: try readTestComponent(
                        .blue,
                        from: pixel,
                        layout: layout
                    ),
                    alpha: try readTestComponent(
                        .alpha,
                        from: pixel,
                        layout: layout
                    )
                )
            )
        }
    }
    return result
}

private func visibleBytes(
    _ buffer: CVPixelBuffer,
    layout: Alpha4444PackedLayoutV4
) throws -> [UInt8] {
    try rowPartition(buffer, layout: layout).visible
}

private func paddingBytes(
    _ buffer: CVPixelBuffer,
    layout: Alpha4444PackedLayoutV4
) throws -> [UInt8] {
    try rowPartition(buffer, layout: layout).padding
}

private func allBytes(_ buffer: CVPixelBuffer) throws -> [UInt8] {
    XCTAssertEqual(
        CVPixelBufferLockBaseAddress(buffer, .readOnly),
        kCVReturnSuccess
    )
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
        .assumingMemoryBound(to: UInt8.self)
    return Array(
        UnsafeBufferPointer(
            start: base,
            count: CVPixelBufferGetBytesPerRow(buffer)
                * CVPixelBufferGetHeight(buffer)
        )
    )
}

private func rowPartition(
    _ buffer: CVPixelBuffer,
    layout: Alpha4444PackedLayoutV4
) throws -> (visible: [UInt8], padding: [UInt8]) {
    XCTAssertEqual(
        CVPixelBufferLockBaseAddress(buffer, .readOnly),
        kCVReturnSuccess
    )
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
        .assumingMemoryBound(to: UInt8.self)
    let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
    let visibleRowBytes = CVPixelBufferGetWidth(buffer) * layout.bytesPerPixel
    var visible: [UInt8] = []
    var padding: [UInt8] = []
    for y in 0..<CVPixelBufferGetHeight(buffer) {
        let row = base + y * rowBytes
        visible.append(
            contentsOf: UnsafeBufferPointer(
                start: row,
                count: visibleRowBytes
            )
        )
        padding.append(
            contentsOf: UnsafeBufferPointer(
                start: row + visibleRowBytes,
                count: rowBytes - visibleRowBytes
            )
        )
    }
    return (visible, padding)
}

private enum Alpha4444TestComponent {
    case red
    case green
    case blue
    case alpha
}

private func testComponentOffset(
    _ component: Alpha4444TestComponent,
    layout: Alpha4444PackedLayoutV4
) -> Int {
    switch layout {
    case .argb8, .argb16BigEndian:
        switch component {
        case .alpha: return 0
        case .red: return 1
        case .green: return 2
        case .blue: return 3
        }
    case .bgra8:
        switch component {
        case .blue: return 0
        case .green: return 1
        case .red: return 2
        case .alpha: return 3
        }
    case .abgr8:
        switch component {
        case .alpha: return 0
        case .blue: return 1
        case .green: return 2
        case .red: return 3
        }
    case .rgba8, .rgba16LittleEndian:
        switch component {
        case .red: return 0
        case .green: return 1
        case .blue: return 2
        case .alpha: return 3
        }
    }
}

private func writeTestComponent(
    _ value: UInt16,
    _ component: Alpha4444TestComponent,
    to pixel: UnsafeMutablePointer<UInt8>,
    layout: Alpha4444PackedLayoutV4
) throws {
    let offset = testComponentOffset(component, layout: layout)
    switch layout {
    case .argb8, .bgra8, .abgr8, .rgba8:
        pixel[offset] = UInt8(truncatingIfNeeded: value)
    case .argb16BigEndian:
        pixel[offset * 2] = UInt8(truncatingIfNeeded: value >> 8)
        pixel[offset * 2 + 1] = UInt8(truncatingIfNeeded: value)
    case .rgba16LittleEndian:
        pixel[offset * 2] = UInt8(truncatingIfNeeded: value)
        pixel[offset * 2 + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }
}

private func readTestComponent(
    _ component: Alpha4444TestComponent,
    from pixel: UnsafePointer<UInt8>,
    layout: Alpha4444PackedLayoutV4
) throws -> UInt16 {
    let offset = testComponentOffset(component, layout: layout)
    switch layout {
    case .argb8, .bgra8, .abgr8, .rgba8:
        return UInt16(pixel[offset])
    case .argb16BigEndian:
        return (UInt16(pixel[offset * 2]) << 8)
            | UInt16(pixel[offset * 2 + 1])
    case .rgba16LittleEndian:
        return UInt16(pixel[offset * 2])
            | (UInt16(pixel[offset * 2 + 1]) << 8)
    }
}

private func makeFormatDescription(
    codec: CMVideoCodecType,
    width: Int32,
    height: Int32,
    containsAlpha: Bool,
    association: CFString?,
    depth: Int?
) throws -> CMVideoFormatDescription {
    var extensions: [String: Any] = [
        kCMFormatDescriptionExtension_ContainsAlphaChannel as String:
            containsAlpha ? kCFBooleanTrue as Any : kCFBooleanFalse as Any
    ]
    if let association {
        extensions[
            kCMFormatDescriptionExtension_AlphaChannelMode as String
        ] = association
    }
    if let depth {
        extensions[kCMFormatDescriptionExtension_Depth as String] = depth
    }
    var description: CMVideoFormatDescription?
    let status = CMVideoFormatDescriptionCreate(
        allocator: kCFAllocatorDefault,
        codecType: codec,
        width: width,
        height: height,
        extensions: extensions as CFDictionary,
        formatDescriptionOut: &description
    )
    guard status == noErr, let description else {
        throw Alpha4444TestError.coreMedia(status)
    }
    return description
}

private func fillEncodedFixture(
    _ buffer: CVPixelBuffer,
    layout: Alpha4444PackedLayoutV4
) throws -> [UInt16] {
    let width = CVPixelBufferGetWidth(buffer)
    let height = CVPixelBufferGetHeight(buffer)
    let maximum = layout.signalBitDepth == 8 ? 255 : 65_535
    var values: [AlphaSampleV4] = []
    for y in 0..<height {
        for x in 0..<width {
            values.append(
                AlphaSampleV4(
                    red: UInt16((x * 8_111 + y * 5_009) % (maximum + 1)),
                    green: UInt16((x * 4_003 + y * 9_007) % (maximum + 1)),
                    blue: UInt16((x * 6_013 + y * 2_009) % (maximum + 1)),
                    alpha: UInt16((x * 7_001 + y * 11_003) % (maximum + 1))
                )
            )
        }
    }
    try writeSamples(values, to: buffer, layout: layout)
    return values.map(\.alpha)
}

private func XCTAssertThrowsAlphaError<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw.")
    } catch {
        errorHandler(error)
    }
}
