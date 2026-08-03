import CoreMedia
import CoreVideo
import Metal
import XCTest
@testable import Mirmir

final class FixedPointPixelBufferScalerV4Tests: XCTestCase {
    func testEveryExecutionScheduleMatchesProductionForOddNV12AndP010()
        async throws {
        var backends = [FixedPointExecutionBackendV4.cpu]
        if MTLCreateSystemDefaultDevice() != nil {
            backends.append(.metal)
        }
        for storage in [
            PixelStorageV4.nv12VideoRange8Bit,
            .nv12FullRange8Bit,
            .p010VideoRange10Bit,
            .p010FullRange10Bit
        ] {
            let source = try makeBuffer(storage: storage, width: 7, height: 5)
            try fill(source, storage: storage)
            let reference = try makeBuffer(
                storage: storage,
                width: 13,
                height: 9
            )
            let production = try FixedPointPixelBufferScalerV4(
                backend: .cpu,
                storage: storage,
                sourceWidth: 7,
                sourceHeight: 5,
                targetWidth: 13,
                targetHeight: 9,
                borderRule: .reflect101
            )
            try await production.process(source: source, destination: reference)
            let expected = try visibleSignalCodes(reference, storage: storage)

            for backend in backends {
                for schedule in [
                    FixedPointExecutionScheduleV4.qualificationRowMajor3x2,
                    .qualificationReverse3x2,
                    .qualificationEvenOdd3x2
                ] {
                    let destination = try makeBuffer(
                        storage: storage,
                        width: 13,
                        height: 9
                    )
                    let scaler = try FixedPointPixelBufferScalerV4(
                        backend: backend,
                        storage: storage,
                        sourceWidth: 7,
                        sourceHeight: 5,
                        targetWidth: 13,
                        targetHeight: 9,
                        borderRule: .reflect101,
                        executionSchedule: schedule
                    )
                    try await scaler.process(
                        source: source,
                        destination: destination
                    )
                    XCTAssertEqual(
                        try visibleSignalCodes(destination, storage: storage),
                        expected,
                        "\(storage.rawValue)/\(backend.rawValue)/\(schedule.rawValue)"
                    )
                }
            }
        }
    }

    func testCancelledQualificationScheduleLeavesDestinationUnchanged()
        async throws {
        let storage = PixelStorageV4.p010FullRange10Bit
        let source = try makeBuffer(storage: storage, width: 7, height: 5)
        let destination = try makeBuffer(storage: storage, width: 13, height: 9)
        try fill(source, storage: storage)
        try fillAllPlaneBytes(destination, value: 0xA5)
        let before = try allPlaneBytes(destination)
        let scaler = try FixedPointPixelBufferScalerV4(
            backend: .cpu,
            storage: storage,
            sourceWidth: 7,
            sourceHeight: 5,
            targetWidth: 13,
            targetHeight: 9,
            executionSchedule: .qualificationReverse3x2
        )
        let task = Task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            try await scaler.process(source: source, destination: destination)
        }
        task.cancel()
        do {
            try await task.value
            XCTFail("Expected cancellation.")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertEqual(try allPlaneBytes(destination), before)
        XCTAssertEqual(scaler.hotPathDiagnostics().completedFrameCount, 0)
    }

    func testCPUHotPathPreparesOnceAndReusesBoundedWorkspacesAcrossFrames()
        async throws {
        let storage = PixelStorageV4.p010FullRange10Bit
        let scaler = try FixedPointPixelBufferScalerV4(
            backend: .cpu,
            storage: storage,
            sourceWidth: 17,
            sourceHeight: 11,
            targetWidth: 29,
            targetHeight: 19,
            borderRule: .reflect101
        )
        let before = scaler.hotPathDiagnostics()
        XCTAssertEqual(before.completedFrameCount, 0)
        XCTAssertEqual(before.scalePreparationCount, 2)
        XCTAssertEqual(before.coefficientCompilationCount, 2)
        XCTAssertEqual(before.cpuWorkspaceAllocationCount, 2)
        XCTAssertEqual(
            before.cpuReusableHorizontalSampleCount,
            4 * 29 + 4 * 15
        )
        XCTAssertEqual(before.cpuWorkspaceStorageIdentities.count, 2)
        XCTAssertEqual(Set(before.cpuWorkspaceStorageIdentities).count, 2)
        XCTAssertEqual(before.metalPreparedExecutionCount, 0)
        XCTAssertEqual(before.metalRetainedPlanarSampleCount, 0)
        XCTAssertEqual(before.fullPlaneSwiftArrayStagingSampleCount, 0)
        XCTAssertTrue(before.usesDirectPixelBufferIO)

        var outputs: [[UInt16]] = []
        for _ in 0..<2 {
            let source = try makeBuffer(
                storage: storage,
                width: 17,
                height: 11
            )
            let destination = try makeBuffer(
                storage: storage,
                width: 29,
                height: 19
            )
            try fill(source, storage: storage)
            try await scaler.process(source: source, destination: destination)
            outputs.append(try visibleSignalCodes(destination, storage: storage))
        }

        let after = scaler.hotPathDiagnostics()
        XCTAssertEqual(after.completedFrameCount, 2)
        XCTAssertEqual(after.scalePreparationCount, before.scalePreparationCount)
        XCTAssertEqual(
            after.coefficientCompilationCount,
            before.coefficientCompilationCount
        )
        XCTAssertEqual(
            after.cpuWorkspaceAllocationCount,
            before.cpuWorkspaceAllocationCount
        )
        XCTAssertEqual(
            after.cpuWorkspaceStorageIdentities,
            before.cpuWorkspaceStorageIdentities
        )
        XCTAssertEqual(after.fullPlaneSwiftArrayStagingSampleCount, 0)
        XCTAssertEqual(outputs[0], outputs[1])
    }

    func testMetalHotPathPreparesOnceAndReusesEveryBufferAcrossFrames()
        async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal is unavailable on this host.")
        }
        let storage = PixelStorageV4.nv12VideoRange8Bit
        let scaler = try FixedPointPixelBufferScalerV4(
            backend: .metal,
            storage: storage,
            sourceWidth: 17,
            sourceHeight: 11,
            targetWidth: 29,
            targetHeight: 19,
            borderRule: .reflect101
        )
        let before = scaler.hotPathDiagnostics()
        XCTAssertEqual(before.completedFrameCount, 0)
        XCTAssertEqual(before.scalePreparationCount, 2)
        XCTAssertEqual(before.coefficientCompilationCount, 2)
        XCTAssertEqual(before.cpuWorkspaceAllocationCount, 0)
        XCTAssertEqual(before.metalPreparedExecutionCount, 3)
        XCTAssertEqual(before.metalReusableBufferCount, 21)
        XCTAssertEqual(before.metalReusableBufferIdentities.count, 21)
        XCTAssertEqual(Set(before.metalReusableBufferIdentities).count, 21)
        XCTAssertEqual(before.metalPipelineIdentityCount, 1)
        XCTAssertEqual(before.metalRetainedPlanarSampleCount, 1_146)
        XCTAssertEqual(before.fullPlaneSwiftArrayStagingSampleCount, 0)
        XCTAssertTrue(before.usesDirectPixelBufferIO)

        for _ in 0..<2 {
            let source = try makeBuffer(
                storage: storage,
                width: 17,
                height: 11
            )
            let destination = try makeBuffer(
                storage: storage,
                width: 29,
                height: 19
            )
            try fill(source, storage: storage)
            try await scaler.process(source: source, destination: destination)
        }

        let after = scaler.hotPathDiagnostics()
        XCTAssertEqual(after.completedFrameCount, 2)
        XCTAssertEqual(
            after.metalReusableBufferIdentities,
            before.metalReusableBufferIdentities
        )
        XCTAssertEqual(
            after.metalPreparedExecutionCount,
            before.metalPreparedExecutionCount
        )
        XCTAssertEqual(after.metalPipelineIdentityCount, 1)
        XCTAssertEqual(
            after.metalRetainedPlanarSampleCount,
            before.metalRetainedPlanarSampleCount
        )
        XCTAssertEqual(after.fullPlaneSwiftArrayStagingSampleCount, 0)
    }

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

        let invalidSource = try makeBuffer(
            storage: .p010VideoRange10Bit,
            width: 4,
            height: 4
        )
        let untouchedDestination = try makeBuffer(
            storage: .p010VideoRange10Bit,
            width: 8,
            height: 8
        )
        try fill(invalidSource, storage: .p010VideoRange10Bit)
        try fillAllPlaneBytes(untouchedDestination, value: 0xA5)
        try mutateFirstStoredCode(invalidSource) { $0 | 1 }
        let destinationBefore = try allPlaneBytes(untouchedDestination)
        let p010Scaler = try FixedPointPixelBufferScalerV4(
            backend: .cpu,
            storage: .p010VideoRange10Bit,
            sourceWidth: 4,
            sourceHeight: 4,
            targetWidth: 8,
            targetHeight: 8
        )
        await XCTAssertThrowsErrorAsync(
            try await p010Scaler.process(
                source: invalidSource,
                destination: untouchedDestination
            )
        ) { error in
            guard case PixelLayoutV4Error.invalidStoredCodeAlignment = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(
            try allPlaneBytes(untouchedDestination),
            destinationBefore
        )
    }

    func testDirectCPUAndMetalWritesLeaveEveryPaddingByteUntouched()
        async throws {
        var backends = [FixedPointExecutionBackendV4.cpu]
        if MTLCreateSystemDefaultDevice() != nil {
            backends.append(.metal)
        }
        for backend in backends {
            let storage = PixelStorageV4.p010FullRange10Bit
            let source = try makeBuffer(storage: storage, width: 7, height: 5)
            let destination = try makeBuffer(
                storage: storage,
                width: 13,
                height: 9
            )
            try fill(source, storage: storage)
            try fillAllPlaneBytes(destination, value: 0xA5)
            let scaler = try FixedPointPixelBufferScalerV4(
                backend: backend,
                storage: storage,
                sourceWidth: 7,
                sourceHeight: 5,
                targetWidth: 13,
                targetHeight: 9,
                borderRule: .reflect101
            )
            try await scaler.process(source: source, destination: destination)
            try assertPaddingBytes(
                destination,
                storage: storage,
                expected: 0xA5,
                backend: backend
            )
        }
    }

    func testDistinctBuffersWithCrossPlaneSharedBackingFailBeforeMutation()
        async throws {
        var backends = [FixedPointExecutionBackendV4.cpu]
        if MTLCreateSystemDefaultDevice() != nil {
            backends.append(.metal)
        }
        for backend in backends {
            let fixture = try CrossPlaneAliasedNV12Fixture()
            try fill(fixture.source, storage: .nv12FullRange8Bit)
            let bytesBefore = fixture.bytes
            let scaler = try FixedPointPixelBufferScalerV4(
                backend: backend,
                storage: .nv12FullRange8Bit,
                sourceWidth: 4,
                sourceHeight: 4,
                targetWidth: 4,
                targetHeight: 4
            )

            await XCTAssertThrowsErrorAsync(
                try await scaler.process(
                    source: fixture.source,
                    destination: fixture.destination
                )
            ) { error in
                XCTAssertEqual(
                    error as? FixedPointKernelV4Error,
                    .overlappingSourceAndDestination,
                    "backend=\(backend.rawValue)"
                )
            }
            XCTAssertEqual(fixture.bytes, bytesBefore)
            XCTAssertEqual(
                scaler.hotPathDiagnostics().completedFrameCount,
                0
            )
        }
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

    private func fillAllPlaneBytes(
        _ buffer: CVPixelBuffer,
        value: UInt8
    ) throws {
        XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, []), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
            let base = try XCTUnwrap(
                CVPixelBufferGetBaseAddressOfPlane(buffer, plane)
            )
            let count = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
                * CVPixelBufferGetHeightOfPlane(buffer, plane)
            memset(base, Int32(value), count)
        }
    }

    private func mutateFirstStoredCode(
        _ buffer: CVPixelBuffer,
        transform: (UInt16) -> UInt16
    ) throws {
        XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, []), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 0))
            .assumingMemoryBound(to: UInt8.self)
        let stored = UInt16(base[0]) | (UInt16(base[1]) << 8)
        let changed = transform(stored)
        base[0] = UInt8(truncatingIfNeeded: changed)
        base[1] = UInt8(truncatingIfNeeded: changed >> 8)
    }

    private func allPlaneBytes(_ buffer: CVPixelBuffer) throws -> Data {
        XCTAssertEqual(
            CVPixelBufferLockBaseAddress(buffer, .readOnly),
            kCVReturnSuccess
        )
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        var result = Data()
        for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
            let base = try XCTUnwrap(
                CVPixelBufferGetBaseAddressOfPlane(buffer, plane)
            )
            let count = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
                * CVPixelBufferGetHeightOfPlane(buffer, plane)
            result.append(base.assumingMemoryBound(to: UInt8.self), count: count)
        }
        return result
    }

    private func assertPaddingBytes(
        _ buffer: CVPixelBuffer,
        storage: PixelStorageV4,
        expected: UInt8,
        backend: FixedPointExecutionBackendV4
    ) throws {
        let layout = PixelLayoutV4(storage: storage)
        XCTAssertEqual(
            CVPixelBufferLockBaseAddress(buffer, .readOnly),
            kCVReturnSuccess
        )
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        var observedPadding = false
        for (planeIndex, plane) in layout.planes.enumerated() {
            let activeBytes = try plane.activeBytesPerRow(
                frameWidth: CVPixelBufferGetWidth(buffer)
            )
            let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(
                buffer,
                planeIndex
            )
            let height = CVPixelBufferGetHeightOfPlane(buffer, planeIndex)
            let base = try XCTUnwrap(
                CVPixelBufferGetBaseAddressOfPlane(buffer, planeIndex)
            ).assumingMemoryBound(to: UInt8.self)
            for y in 0..<height where rowBytes > activeBytes {
                observedPadding = true
                let row = base.advanced(by: y * rowBytes)
                XCTAssertTrue(
                    (activeBytes..<rowBytes).allSatisfy { row[$0] == expected },
                    "backend=\(backend.rawValue), plane=\(planeIndex), row=\(y)"
                )
            }
        }
        XCTAssertTrue(observedPadding, "fixture must exercise padded rows")
    }
}

private final class CrossPlaneAliasedNV12Fixture {
    let source: CVPixelBuffer
    let destination: CVPixelBuffer

    private let storage: CrossPlaneAliasedNV12Storage

    var bytes: Data {
        Data(bytes: storage.baseAddress, count: storage.byteCount)
    }

    init() throws {
        let storage = try CrossPlaneAliasedNV12Storage(byteCount: 64)
        self.storage = storage
        self.source = try Self.makeBuffer(
            storage: storage,
            lumaOffset: 0,
            chromaOffset: 16
        )
        self.destination = try Self.makeBuffer(
            storage: storage,
            lumaOffset: 16,
            chromaOffset: 40
        )
    }

    private static func makeBuffer(
        storage: CrossPlaneAliasedNV12Storage,
        lumaOffset: Int,
        chromaOffset: Int
    ) throws -> CVPixelBuffer {
        var planeBaseAddresses: [UnsafeMutableRawPointer?] = [
            storage.baseAddress.advanced(by: lumaOffset),
            storage.baseAddress.advanced(by: chromaOffset)
        ]
        var planeWidths = [4, 2]
        var planeHeights = [4, 2]
        var planeBytesPerRow = [4, 4]
        var pixelBuffer: CVPixelBuffer?
        let retainedStorage = Unmanaged.passRetained(storage)
        let status = CVPixelBufferCreateWithPlanarBytes(
            kCFAllocatorDefault,
            4,
            4,
            PixelStorageV4.nv12FullRange8Bit.pixelFormat,
            nil,
            0,
            planeBaseAddresses.count,
            &planeBaseAddresses,
            &planeWidths,
            &planeHeights,
            &planeBytesPerRow,
            releaseCrossPlaneAliasedNV12Storage,
            retainedStorage.toOpaque(),
            nil,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            retainedStorage.release()
            throw NSError(
                domain: "CrossPlaneAliasedNV12Fixture",
                code: Int(status)
            )
        }
        return pixelBuffer
    }
}

private final class CrossPlaneAliasedNV12Storage {
    let baseAddress: UnsafeMutableRawPointer
    let byteCount: Int

    init(byteCount: Int) throws {
        guard let baseAddress = malloc(byteCount) else {
            throw NSError(
                domain: "CrossPlaneAliasedNV12Fixture",
                code: -1
            )
        }
        self.baseAddress = baseAddress
        self.byteCount = byteCount
        memset(baseAddress, 0xA5, byteCount)
    }

    deinit {
        free(baseAddress)
    }
}

private func releaseCrossPlaneAliasedNV12Storage(
    releaseRefCon: UnsafeMutableRawPointer?,
    dataPtr _: UnsafeRawPointer?,
    dataSize _: Int,
    numberOfPlanes _: Int,
    planeAddresses _: UnsafeMutablePointer<UnsafeRawPointer?>?
) {
    guard let releaseRefCon else { return }
    Unmanaged<CrossPlaneAliasedNV12Storage>
        .fromOpaque(releaseRefCon)
        .release()
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
