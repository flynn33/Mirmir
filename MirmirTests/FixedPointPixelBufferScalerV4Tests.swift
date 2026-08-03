import CoreMedia
import CoreVideo
import Metal
import XCTest
@testable import Mirmir

final class FixedPointPixelBufferScalerV4Tests: XCTestCase {
    func testCPUAndMetalMatchForNV12AndP010ArbitraryOddScale() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal is unavailable on this host.")
        }
        for storage in [
            PixelStorageV4.nv12VideoRange8Bit,
            .nv12FullRange8Bit,
            .p010VideoRange10Bit,
            .p010FullRange10Bit
        ] {
            let source = try makeBuffer(
                storage: storage,
                width: 5,
                height: 3
            )
            try fill(source, storage: storage)
            let cpuOutput = try makeBuffer(
                storage: storage,
                width: 9,
                height: 7
            )
            let metalOutput = try makeBuffer(
                storage: storage,
                width: 9,
                height: 7
            )
            let cpu = try FixedPointPixelBufferScalerV4(
                backend: .cpu,
                storage: storage,
                sourceWidth: 5,
                sourceHeight: 3,
                targetWidth: 9,
                targetHeight: 7,
                borderRule: .reflect101
            )
            let metal = try FixedPointPixelBufferScalerV4(
                backend: .metal,
                storage: storage,
                sourceWidth: 5,
                sourceHeight: 3,
                targetWidth: 9,
                targetHeight: 7,
                borderRule: .reflect101
            )
            try await cpu.process(source: source, destination: cpuOutput)
            try await metal.process(source: source, destination: metalOutput)
            XCTAssertEqual(
                try visibleSignalCodes(cpuOutput, storage: storage),
                try visibleSignalCodes(metalOutput, storage: storage),
                "storage=\(storage.rawValue)"
            )
        }
    }

    func testIdentityIsExactAndPreservesBothAttachmentModes() async throws {
        let storage = PixelStorageV4.p010VideoRange10Bit
        let source = try makeBuffer(storage: storage, width: 5, height: 3)
        let destination = try makeBuffer(storage: storage, width: 5, height: 3)
        try fill(source, storage: storage)
        CVBufferSetAttachment(
            source,
            kCVImageBufferColorPrimariesKey,
            kCVImageBufferColorPrimaries_ITU_R_2020,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            source,
            kCVImageBufferTransferFunctionKey,
            kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            source,
            kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferYCbCrMatrix_ITU_R_2020,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            source,
            kCVImageBufferGammaLevelKey,
            NSNumber(value: 2.4),
            .shouldNotPropagate
        )
        let scaler = try FixedPointPixelBufferScalerV4(
            backend: .cpu,
            storage: storage,
            sourceWidth: 5,
            sourceHeight: 3,
            targetWidth: 5,
            targetHeight: 3
        )
        try await scaler.process(source: source, destination: destination)
        XCTAssertEqual(
            try visibleSignalCodes(source, storage: storage),
            try visibleSignalCodes(destination, storage: storage)
        )
        var mode = CVAttachmentMode.shouldNotPropagate
        XCTAssertEqual(
            CVBufferCopyAttachment(
                destination,
                kCVImageBufferColorPrimariesKey,
                &mode
            ) as? String,
            kCVImageBufferColorPrimaries_ITU_R_2020 as String
        )
        XCTAssertEqual(mode, .shouldPropagate)
        XCTAssertEqual(
            CVBufferCopyAttachment(
                destination,
                kCVImageBufferGammaLevelKey,
                &mode
            ) as? NSNumber,
            NSNumber(value: 2.4)
        )
        XCTAssertEqual(mode, .shouldNotPropagate)
    }

    func testSpatialResamplingPreservesFrameBoundDynamicHDRMetadata() async throws {
        let storage = PixelStorageV4.p010VideoRange10Bit
        let source = try makeBuffer(storage: storage, width: 4, height: 4)
        let destination = try makeBuffer(storage: storage, width: 8, height: 8)
        try fill(source, storage: storage)
        CVBufferSetAttachment(
            source,
            kCMSampleAttachmentKey_HDR10PlusPerFrameData,
            Data([0xB5, 0x00, 0x3C, 0x00, 0x01]) as CFData,
            .shouldPropagate
        )
        let scaler = try FixedPointPixelBufferScalerV4(
            backend: .cpu,
            storage: storage,
            sourceWidth: 4,
            sourceHeight: 4,
            targetWidth: 8,
            targetHeight: 8
        )
        try await scaler.process(source: source, destination: destination)
        XCTAssertEqual(
            try AVFoundationHDRMetadataAdapterV4.probeDynamicMetadata(
                from: destination
            ),
            try AVFoundationHDRMetadataAdapterV4.probeDynamicMetadata(
                from: source
            )
        )
    }

    func testAliasingFormatAndOutOfRangeInputFailClosed() async throws {
        let source = try makeBuffer(
            storage: .nv12VideoRange8Bit,
            width: 4,
            height: 4
        )
        try fill(source, storage: .nv12VideoRange8Bit)
        let scaler = try FixedPointPixelBufferScalerV4(
            backend: .cpu,
            storage: .nv12VideoRange8Bit,
            sourceWidth: 4,
            sourceHeight: 4,
            targetWidth: 4,
            targetHeight: 4
        )
        await XCTAssertThrowsErrorAsync(
            try await scaler.process(source: source, destination: source)
        )

        let wrongFormat = try makeBuffer(
            storage: .nv12FullRange8Bit,
            width: 4,
            height: 4
        )
        await XCTAssertThrowsErrorAsync(
            try await scaler.process(
                source: source,
                destination: wrongFormat
            )
        )
    }

    private func makeBuffer(
        storage: PixelStorageV4,
        width: Int,
        height: Int
    ) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            storage.pixelFormat,
            [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
                as CFDictionary,
            &buffer
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        return try XCTUnwrap(buffer)
    }

    private func fill(
        _ buffer: CVPixelBuffer,
        storage: PixelStorageV4
    ) throws {
        let layout = PixelLayoutV4(storage: storage)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, []), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        for (planeIndex, plane) in layout.planes.enumerated() {
            let width = try plane.width(
                forFrameWidth: CVPixelBufferGetWidth(buffer)
            )
            let height = try plane.height(
                forFrameHeight: CVPixelBufferGetHeight(buffer)
            )
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, planeIndex)
            let base = try XCTUnwrap(
                CVPixelBufferGetBaseAddressOfPlane(buffer, planeIndex)
            ).assumingMemoryBound(to: UInt8.self)
            for y in 0..<height {
                let row = base.advanced(by: y * stride)
                for x in 0..<width {
                    for component in 0..<plane.componentsPerElement {
                        let bounds = plane.signalCodeBounds[component]
                        let span = Int(bounds.maximum - bounds.minimum) + 1
                        let signal = bounds.minimum + UInt16(
                            (x * 37 + y * 71 + component * 113) % span
                        )
                        let stored = signal << UInt16(plane.storedCodeShift)
                        let index = x * plane.componentsPerElement + component
                        if plane.bytesPerComponent == 1 {
                            row[index] = UInt8(stored)
                        } else {
                            row[index * 2] = UInt8(truncatingIfNeeded: stored)
                            row[index * 2 + 1] = UInt8(
                                truncatingIfNeeded: stored >> 8
                            )
                        }
                    }
                }
            }
        }
    }

    private func visibleSignalCodes(
        _ buffer: CVPixelBuffer,
        storage: PixelStorageV4
    ) throws -> [UInt16] {
        let layout = PixelLayoutV4(storage: storage)
        XCTAssertEqual(
            CVPixelBufferLockBaseAddress(buffer, .readOnly),
            kCVReturnSuccess
        )
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        var result: [UInt16] = []
        for (planeIndex, plane) in layout.planes.enumerated() {
            let width = try plane.width(
                forFrameWidth: CVPixelBufferGetWidth(buffer)
            )
            let height = try plane.height(
                forFrameHeight: CVPixelBufferGetHeight(buffer)
            )
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, planeIndex)
            let base = try XCTUnwrap(
                CVPixelBufferGetBaseAddressOfPlane(buffer, planeIndex)
            ).assumingMemoryBound(to: UInt8.self)
            for y in 0..<height {
                let row = base.advanced(by: y * stride)
                for x in 0..<width {
                    for component in 0..<plane.componentsPerElement {
                        let index = x * plane.componentsPerElement + component
                        let stored: UInt16
                        if plane.bytesPerComponent == 1 {
                            stored = UInt16(row[index])
                        } else {
                            stored = UInt16(row[index * 2])
                                | (UInt16(row[index * 2 + 1]) << 8)
                        }
                        result.append(
                            try layout.validateStoredCode(
                                stored,
                                plane: planeIndex,
                                component: component
                            )
                        )
                    }
                }
            }
        }
        return result
    }
}

private func XCTAssertThrowsErrorAsync<T>(
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
