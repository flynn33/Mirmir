import AVFoundation
import CoreMedia
import CoreVideo
import Metal
import VideoToolbox
import XCTest
@testable import Mirmir

final class Alpha4444FixedPointScalerV4Tests: XCTestCase {
    func testPreparedBackendEnforcesCausalLifecycleAndAlphaSemantics()
        async throws {
        let source = try makeBuffer(
            layout: .bgra8,
            width: 4,
            height: 4,
            rowBytes: 21,
            sentinel: 0xD1
        )
        let destination = try makeBuffer(
            layout: .bgra8,
            width: 8,
            height: 8,
            rowBytes: 39,
            sentinel: 0xB2
        )
        try writeSamples(
            transparentEdgeFixture(width: 4, height: 4),
            to: source,
            layout: .bgra8
        )
        installAssociation(.straight, on: source)
        let scalePlan = try Alpha4444ScalePlanV4(
            layout: .bgra8,
            sourceAssociation: .straight,
            destinationAssociation: .premultiplied,
            zeroAlphaPolicy: .clearColor,
            sourceWidth: 4,
            sourceHeight: 4,
            targetWidth: 8,
            targetHeight: 8,
            borderRule: .reflect101
        )
        let backend = try PreparedAlpha4444UpscalerV4(
            backend: .cpu,
            plan: scalePlan
        )
        XCTAssertEqual(backend.actualBackendID, .mirmirDeterministicCPU)
        XCTAssertEqual(
            backend.sourcePixelBufferAttributes.values[
                kCVPixelBufferPixelFormatTypeKey as String
            ] as? NSNumber,
            NSNumber(value: kCVPixelFormatType_32BGRA)
        )
        XCTAssertEqual(
            backend.destinationPixelBufferAttributes.values[
                kCVPixelBufferWidthKey as String
            ] as? NSNumber,
            NSNumber(value: 8)
        )

        try await backend.process(
            source: FramePixelBuffer(source),
            destination: FramePixelBuffer(destination),
            timing: FrameTiming(
                frameIndex: 7,
                presentationTime: CMTime(value: 7, timescale: 30),
                duration: CMTime(value: 1, timescale: 30)
            )
        )
        let output = try Alpha4444PixelBufferAccessV4.samples(
            destination,
            layout: .bgra8
        )
        XCTAssertTrue(output.contains { $0.alpha == 0 })
        XCTAssertTrue(output.contains { $0.alpha > 0 && $0.alpha < 255 })
        for sample in output {
            XCTAssertLessThanOrEqual(sample.red, sample.alpha)
            XCTAssertLessThanOrEqual(sample.green, sample.alpha)
            XCTAssertLessThanOrEqual(sample.blue, sample.alpha)
            if sample.alpha == 0 {
                XCTAssertEqual(sample.red, 0)
                XCTAssertEqual(sample.green, 0)
                XCTAssertEqual(sample.blue, 0)
            }
        }

        await XCTAssertThrowsAlphaError(
            try await backend.process(
                source: FramePixelBuffer(source),
                destination: FramePixelBuffer(destination),
                timing: FrameTiming(
                    frameIndex: 9,
                    presentationTime: CMTime(value: 9, timescale: 30),
                    duration: CMTime(value: 1, timescale: 30)
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? PreparedAlpha4444UpscalerV4Error,
                .nonContiguousFrameIndex(expected: 8, actual: 9)
            )
        }
        try await backend.finish()
        try await backend.finish()
        await XCTAssertThrowsAlphaError(
            try await backend.process(
                source: FramePixelBuffer(source),
                destination: FramePixelBuffer(destination),
                timing: FrameTiming(
                    frameIndex: 8,
                    presentationTime: CMTime(value: 8, timescale: 30),
                    duration: CMTime(value: 1, timescale: 30)
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? PreparedAlpha4444UpscalerV4Error,
                .alreadyFinished
            )
        }
    }

    func testAlphaCheckpointRestoresIdentityBoundCausalFrameState()
        async throws {
        let plan = try Alpha4444ScalePlanV4(
            layout: .bgra8,
            sourceAssociation: .straight,
            destinationAssociation: .premultiplied,
            zeroAlphaPolicy: .clearColor,
            sourceWidth: 3,
            sourceHeight: 3,
            targetWidth: 6,
            targetHeight: 6,
            borderRule: .reflect101
        )
        let source = try makeBuffer(
            layout: .bgra8,
            width: 3,
            height: 3,
            rowBytes: 17,
            sentinel: 0x8A
        )
        try writeSamples(
            transparentEdgeFixture(width: 3, height: 3),
            to: source,
            layout: .bgra8
        )
        installAssociation(.straight, on: source)
        func output(_ sentinel: UInt8) throws -> CVPixelBuffer {
            try makeBuffer(
                layout: .bgra8,
                width: 6,
                height: 6,
                rowBytes: 29,
                sentinel: sentinel
            )
        }
        let timing0 = FrameTiming(
            frameIndex: 0,
            presentationTime: CMTime(value: 0, timescale: 30),
            duration: CMTime(value: 1, timescale: 30)
        )
        let timing1 = FrameTiming(
            frameIndex: 1,
            presentationTime: CMTime(value: 1, timescale: 30),
            duration: CMTime(value: 1, timescale: 30)
        )
        let planSHA256 = ASHSHA256V4(
            rawData: Data("alpha-checkpoint-plan".utf8)
        )

        let baseline = try PreparedAlpha4444UpscalerV4(
            backend: .cpu,
            plan: plan
        )
        let baselineOutput = try output(0x11)
        try await baseline.process(
            source: FramePixelBuffer(source),
            destination: FramePixelBuffer(baselineOutput),
            timing: timing0
        )
        try await baseline.process(
            source: FramePixelBuffer(source),
            destination: FramePixelBuffer(baselineOutput),
            timing: timing1
        )

        let interrupted = try PreparedAlpha4444UpscalerV4(
            backend: .cpu,
            plan: plan
        )
        try await interrupted.process(
            source: FramePixelBuffer(source),
            destination: FramePixelBuffer(try output(0x22)),
            timing: timing0
        )
        let checkpoint = try await interrupted.makeTemporalCheckpoint(
            planSHA256: planSHA256,
            lastCompletedInputOrdinal: 0
        )

        let resumed = try PreparedAlpha4444UpscalerV4(
            backend: .cpu,
            plan: plan
        )
        try await resumed.restoreTemporalCheckpoint(
            checkpoint,
            planSHA256: planSHA256
        )
        let resumedOutput = try output(0x33)
        try await resumed.process(
            source: FramePixelBuffer(source),
            destination: FramePixelBuffer(resumedOutput),
            timing: timing1
        )
        XCTAssertEqual(
            try Alpha4444PixelBufferAccessV4.samples(
                resumedOutput,
                layout: .bgra8
            ),
            try Alpha4444PixelBufferAccessV4.samples(
                baselineOutput,
                layout: .bgra8
            )
        )

        let wrongPlanBinding = try PreparedAlpha4444UpscalerV4(
            backend: .cpu,
            plan: plan
        )
        await XCTAssertThrowsAlphaError(
            try await wrongPlanBinding.restoreTemporalCheckpoint(
                checkpoint,
                planSHA256: ASHSHA256V4(
                    rawData: Data("different-execution-plan".utf8)
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? PreparedAlpha4444UpscalerV4Error,
                .checkpointIdentityMismatch
            )
        }

        let differentAlphaPlan = try Alpha4444ScalePlanV4(
            layout: .bgra8,
            sourceAssociation: .straight,
            destinationAssociation: .premultiplied,
            zeroAlphaPolicy: .clearColor,
            sourceWidth: 3,
            sourceHeight: 3,
            targetWidth: 6,
            targetHeight: 6,
            borderRule: .clamp
        )
        let wrongAlphaBinding = try PreparedAlpha4444UpscalerV4(
            backend: .cpu,
            plan: differentAlphaPlan
        )
        await XCTAssertThrowsAlphaError(
            try await wrongAlphaBinding.restoreTemporalCheckpoint(
                checkpoint,
                planSHA256: planSHA256
            )
        ) { error in
            XCTAssertEqual(
                error as? PreparedAlpha4444UpscalerV4Error,
                .checkpointIdentityMismatch
            )
        }

        let advanced = try PreparedAlpha4444UpscalerV4(
            backend: .cpu,
            plan: plan
        )
        let advancedOutput = try output(0x44)
        try await advanced.process(
            source: FramePixelBuffer(source),
            destination: FramePixelBuffer(advancedOutput),
            timing: timing0
        )
        try await advanced.process(
            source: FramePixelBuffer(source),
            destination: FramePixelBuffer(advancedOutput),
            timing: timing1
        )
        await XCTAssertThrowsAlphaError(
            try await advanced.restoreTemporalCheckpoint(
                checkpoint,
                planSHA256: planSHA256
            )
        ) { error in
            XCTAssertEqual(
                error as? PreparedAlpha4444UpscalerV4Error,
                .checkpointStateMismatch
            )
        }

        var corrupted = checkpoint
        corrupted.append(0)
        let corruptionProbe = try PreparedAlpha4444UpscalerV4(
            backend: .cpu,
            plan: plan
        )
        await XCTAssertThrowsAlphaError(
            try await corruptionProbe.restoreTemporalCheckpoint(
                corrupted,
                planSHA256: planSHA256
            )
        )
    }

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
    func testWholeAssetDeterministicRoutePreservesAlphaAndExactGeometry()
        async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mirmir-alpha-whole-asset-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("source.mov")
        let outputURL = root.appendingPathComponent("output.mov")
        let runtimeURL = root.appendingPathComponent("runtime.bundle")
        let sourceGeometry = try RationalPresentationGeometryV4(
            codedWidth: 16,
            codedHeight: 16,
            cleanAperture: CleanApertureV4(
                width: ExactRationalV4(12),
                height: ExactRationalV4(12),
                horizontalOffset: .zero,
                verticalOffset: .zero
            ),
            sampleAspectRatio: SampleAspectRatioV4(
                horizontalSpacing: 4,
                verticalSpacing: 3
            ),
            preferredTransform: RationalAffineTransformV4(
                a: .zero,
                b: .one,
                c: try ExactRationalV4(-1),
                d: .zero,
                tx: try ExactRationalV4(16),
                ty: .zero
            )
        )
        let sourceContract = try AlphaVideoWriterContractV4(
            codec: .proRes4444,
            association: .straight,
            width: 16,
            height: 16,
            inputLayout: .bgra8,
            sourceGeometry: sourceGeometry
        )
        let sourceWriter: AVFoundationAlphaVideoWriterV4
        do {
            sourceWriter = try AVFoundationAlphaVideoWriterV4(
                outputURL: sourceURL,
                contract: sourceContract
            )
        } catch AlphaVideoWriterContractV4Error.writerRejectedOutputSettings {
            throw XCTSkip("ProRes 4444 encoder is unavailable.")
        }
        let sourceBuffer = try makeBuffer(
            layout: .bgra8,
            width: 16,
            height: 16,
            rowBytes: 16 * 4 + 16,
            sentinel: 0xA7
        )
        try fillSource(sourceBuffer, layout: .bgra8, association: .straight)
        installAssociation(.straight, on: sourceBuffer)
        for ordinal in 0..<3 {
            try await sourceWriter.append(
                sourceBuffer,
                presentationTime: CMTime(value: Int64(ordinal), timescale: 30)
            )
        }
        _ = try await sourceWriter.finishAndVerify()

        let source = try await VideoProbe().probe(url: sourceURL)
        XCTAssertEqual(source.color.alphaModel, .straight)
        let runtime = try ASHV4SemanticArtifactTestSupport.buildAndLoad(
            at: runtimeURL
        )
        let descriptor = try XCTUnwrap(
            BackendDescriptor.descriptor(for: .mirmirDeterministicCPU)
        )
        let backend = try XCTUnwrap(DeterministicCPUBackend(
            descriptor: descriptor,
            runtimeProvider: .fixed(runtime)
        ))
        let prepared = try await backend.prepare(
            request: BackendPreparationRequest(
                source: source,
                targetSize: CGSize(width: 24, height: 24)
            ),
            environment: .current()
        )
        XCTAssertTrue(
            prepared is PreparedDeterministicAlphaPlanningBackendV4
        )
        let result = try await VideoProcessingSession().process(
            request: UpscaleRequest(
                inputURL: sourceURL,
                outputURL: outputURL,
                backendID: .mirmirDeterministicCPU,
                targetWidth: 24,
                targetHeight: 24,
                outputCodec: .proRes4444,
                preserveAudio: false,
                overwriteExistingFile: false
            ),
            source: source,
            preparedBackend: prepared,
            cancellation: ProcessingCancellation(),
            progress: { _ in }
        )
        XCTAssertEqual(result.outputCodec, .proRes4444)
        XCTAssertEqual(result.encodedWidth, 24)
        XCTAssertEqual(result.encodedHeight, 24)
        XCTAssertEqual(result.processedFrameCount, 3)

        let outputProbe = try await AVCanonicalMediaStateAdapterV4().probe(
            .init(
                url: outputURL,
                bookmarkReference: "alpha-test",
                bookmarkDocumentSHA256: ASHSHA256V4(
                    rawData: Data("alpha-test-bookmark".utf8)
                ),
                scanDynamicHDRMetadata: true
            )
        ).requireAdmittedState()
        let video = try XCTUnwrap(
            outputProbe.tracks.first(where: { $0.kind == .video })?.video
        )
        XCTAssertEqual(video.encodedRaster, CanonicalRasterV4(
            width: 24,
            height: 24
        ))
        XCTAssertEqual(video.pixelAspectRatio, try ExactRationalV4(4, 3))
        XCTAssertEqual(video.pixel.alphaModel, .straight)
        XCTAssertEqual(
            video.cleanAperture?.size,
            CanonicalRationalSizeV4(
                width: try ExactRationalV4(18),
                height: try ExactRationalV4(18)
            )
        )
        XCTAssertEqual(
            video.preferredTransform,
            CanonicalAffineTransformV4(
                a: .zero,
                b: .one,
                c: try ExactRationalV4(-1),
                d: .zero,
                tx: try ExactRationalV4(24),
                ty: .zero
            )
        )
    }

    func testPreparedPremultipliedOutputReopensWithExactProResAlphaBytes()
        async throws {
        let width = 8
        let height = 8
        let source = try makeBuffer(
            layout: .bgra8,
            width: 4,
            height: 4,
            rowBytes: 23,
            sentinel: 0xD7
        )
        try writeSamples(
            transparentEdgeFixture(width: 4, height: 4),
            to: source,
            layout: .bgra8
        )
        installAssociation(.straight, on: source)
        let scalePlan = try Alpha4444ScalePlanV4(
            layout: .bgra8,
            sourceAssociation: .straight,
            destinationAssociation: .premultiplied,
            zeroAlphaPolicy: .clearColor,
            sourceWidth: 4,
            sourceHeight: 4,
            targetWidth: width,
            targetHeight: height,
            borderRule: .reflect101
        )
        let delivery: PreparedAlphaVideoDeliveryV4
        do {
            delivery = try await DeterministicAlphaVideoDeliveryPlannerV4()
                .prepare(
                    scalePlan: scalePlan,
                    executionContext: .cpu
                )
        } catch AlphaVideoWriterContractV4Error.writerRejectedOutputSettings {
            throw XCTSkip("ProRes 4444 encoder is unavailable.")
        }
        let hook = try delivery.makeProcessingHook(
            trackID: MediaTrackStableIDV4("alpha-video-0"),
            nominalSourceFrameDuration: ExactRationalV4(1, 30)
        )
        XCTAssertEqual(hook.trackID.rawValue, "alpha-video-0")
        XCTAssertEqual(
            hook.declaredOutputFormats,
            [delivery.encodedFormatDescriptor]
        )
        XCTAssertEqual(
            hook.writerOutputSettings[AVVideoCodecKey] as? AVVideoCodecType,
            .proRes4444
        )
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "mirmir-alpha-production-v4-\(UUID().uuidString).mov"
            )
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let writer = try delivery.makeVerifiedStandaloneWriter(
            outputURL: outputURL
        )

        for frameIndex in 0..<2 {
            let presentationTime = CMTime(
                value: Int64(frameIndex),
                timescale: 30
            )
            let input = try makeAlphaSampleBuffer(
                pixelBuffer: source,
                presentationTime: presentationTime,
                duration: CMTime(value: 1, timescale: 30)
            )
            let outputs = try await hook.processTemporal(
                AVFoundationVideoSampleV4(sampleBuffer: input)
            )
            XCTAssertEqual(outputs.count, 1)
            let destination = try XCTUnwrap(
                CMSampleBufferGetImageBuffer(outputs[0].sampleBuffer)
            )
            for sample in try Alpha4444PixelBufferAccessV4.samples(
                destination,
                layout: .bgra8
            ) {
                XCTAssertLessThanOrEqual(sample.red, sample.alpha)
                XCTAssertLessThanOrEqual(sample.green, sample.alpha)
                XCTAssertLessThanOrEqual(sample.blue, sample.alpha)
                if sample.alpha == 0 {
                    XCTAssertEqual(sample.red, 0)
                    XCTAssertEqual(sample.green, 0)
                    XCTAssertEqual(sample.blue, 0)
                }
            }
            try await writer.append(
                destination,
                presentationTime: presentationTime
            )
        }
        try await hook.finish()
        let report = try await writer.finishAndVerify()
        XCTAssertEqual(report.schemaID, AlphaVideoWriterVerificationV4.schemaID)
        XCTAssertEqual(report.codec, .proRes4444)
        XCTAssertEqual(report.association, .premultiplied)
        XCTAssertEqual(report.frames.count, 2)
        XCTAssertEqual(report.frames.map(\.ordinal), [0, 1])
        XCTAssertEqual(
            report.frames.map(\.presentationTime),
            [.zero, try ExactRationalV4(1, 30)]
        )
        XCTAssertTrue(report.frames.allSatisfy { frame in
            frame.alphaByteCount == width * height
                && frame.sourceAlphaSHA256 == frame.decodedAlphaSHA256
        })
        let repeatedReport = try await writer.finishAndVerify()
        XCTAssertEqual(repeatedReport, report)
        let migratedReport = try await delivery.verifyMigratedOutput(
            at: outputURL
        )
        XCTAssertEqual(migratedReport, report)
    }

    func testProductionCalibratorCoversAssociationAndHighBitDepth()
        async throws {
        let calibrator = AVFoundationAlphaVideoFormatCalibratorV4()
        let cases: [(AlphaAssociationV4, Alpha4444PackedLayoutV4)] = [
            (.straight, .bgra8),
            (.premultiplied, .bgra8),
            (.straight, .argb16BigEndian)
        ]
        for (association, layout) in cases {
            let contract = try AlphaVideoWriterContractV4(
                codec: .proRes4444,
                association: association,
                width: 16,
                height: 16,
                inputLayout: layout
            )
            let report: AlphaVideoWriterVerificationV4
            do {
                report = try await calibrator.calibration(for: contract)
            } catch AlphaVideoWriterContractV4Error
                .writerRejectedOutputSettings {
                throw XCTSkip("ProRes 4444 encoder is unavailable.")
            }
            XCTAssertEqual(report.association, association)
            XCTAssertEqual(report.inputLayout, layout)
            XCTAssertEqual(report.frames.count, 1)
            XCTAssertEqual(
                report.frames[0].alphaByteCount,
                16 * 16 * (layout.signalBitDepth / 8)
            )
            XCTAssertEqual(
                report.frames[0].sourceAlphaSHA256,
                report.frames[0].decodedAlphaSHA256
            )
            let cachedDescriptor = try await calibrator.formatDescriptor(
                for: contract
            )
            XCTAssertEqual(cachedDescriptor, report.encodedFormat)
            let cachedReport = try await calibrator.calibration(for: contract)
            XCTAssertEqual(cachedReport, report)
        }
    }

    func testExactAlphaWriterRejectsNearLosslessHEVCContract() throws {
        let contract = try AlphaVideoWriterContractV4(
            codec: .hevcWithAlpha,
            association: .straight,
            width: 16,
            height: 16,
            inputLayout: .bgra8
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirmir-alpha-hevc-v4-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(
            try AVFoundationAlphaVideoWriterV4(
                outputURL: url,
                contract: contract
            )
        ) { error in
            XCTAssertEqual(
                error as? AVFoundationAlphaVideoWriterV4Error,
                .exactVerificationRequiresProRes4444(.hevcWithAlpha)
            )
        }
    }

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
        XCTAssertEqual(
            proRes.outputSettings[AVVideoColorPropertiesKey]
                as? [String: String],
            AlphaVideoColorPropertiesV4.sdrBT709.outputSettings
        )
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

    func testCleanApertureValidationReportsEachInexactField() throws {
        let inexact = try ExactRationalV4(1, 3)
        let nearlyFull = try ExactRationalV4(191, 3)
        let exactExtent = try ExactRationalV4(62)
        let cases: [(
            field: String,
            value: ExactRationalV4,
            aperture: CleanApertureV4
        )] = [
            (
                "width",
                nearlyFull,
                try CleanApertureV4(
                    width: nearlyFull,
                    height: exactExtent
                )
            ),
            (
                "height",
                nearlyFull,
                try CleanApertureV4(
                    width: exactExtent,
                    height: nearlyFull
                )
            ),
            (
                "horizontal_offset",
                inexact,
                try CleanApertureV4(
                    width: exactExtent,
                    height: exactExtent,
                    horizontalOffset: inexact
                )
            ),
            (
                "vertical_offset",
                inexact,
                try CleanApertureV4(
                    width: exactExtent,
                    height: exactExtent,
                    verticalOffset: inexact
                )
            )
        ]

        for testCase in cases {
            let geometry = try RationalPresentationGeometryV4(
                codedWidth: 64,
                codedHeight: 64,
                cleanAperture: testCase.aperture
            )
            XCTAssertThrowsError(
                try AlphaVideoWriterContractV4(
                    codec: .proRes4444,
                    association: .straight,
                    width: 64,
                    height: 64,
                    inputLayout: .bgra8,
                    sourceGeometry: geometry
                )
            ) { error in
                XCTAssertEqual(
                    error as? AlphaVideoWriterContractV4Error,
                    .cleanApertureCannotBeRepresentedExactly(
                        field: testCase.field,
                        value: testCase.value
                    )
                )
            }
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
    // Exercise the shader compiled into the application without reading a
    // checkout path that may require separate removable-volume permission.
    try device.makeDefaultLibrary(bundle: Bundle.main)
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

private func makeAlphaSampleBuffer(
    pixelBuffer: CVPixelBuffer,
    presentationTime: CMTime,
    duration: CMTime
) throws -> CMSampleBuffer {
    var format: CMVideoFormatDescription?
    var status = CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: pixelBuffer,
        formatDescriptionOut: &format
    )
    guard status == noErr, let format else {
        throw Alpha4444TestError.coreMedia(status)
    }
    var timing = CMSampleTimingInfo(
        duration: duration,
        presentationTimeStamp: presentationTime,
        decodeTimeStamp: .invalid
    )
    var sample: CMSampleBuffer?
    status = CMSampleBufferCreateReadyWithImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: pixelBuffer,
        formatDescription: format,
        sampleTiming: &timing,
        sampleBufferOut: &sample
    )
    guard status == noErr, let sample else {
        throw Alpha4444TestError.coreMedia(status)
    }
    return sample
}

private func transparentEdgeFixture(
    width: Int,
    height: Int
) -> [AlphaSampleV4] {
    precondition(width >= 3 && height >= 3)
    var output: [AlphaSampleV4] = []
    output.reserveCapacity(width * height)
    for y in 0..<height {
        for x in 0..<width {
            let isTransparentEdge = x == 0 || y == 0
                || x == width - 1 || y == height - 1
            if isTransparentEdge {
                output.append(AlphaSampleV4(
                    red: UInt16((x * 71 + y * 43 + 17) % 256),
                    green: UInt16((x * 29 + y * 89 + 31) % 256),
                    blue: UInt16((x * 53 + y * 11 + 47) % 256),
                    alpha: 0
                ))
            } else {
                output.append(AlphaSampleV4(
                    red: UInt16((x * 97 + y * 37 + 59) % 256),
                    green: UInt16((x * 41 + y * 67 + 83) % 256),
                    blue: UInt16((x * 19 + y * 101 + 107) % 256),
                    alpha: UInt16(32 + ((x * 73 + y * 109) % 224))
                ))
            }
        }
    }
    return output
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
