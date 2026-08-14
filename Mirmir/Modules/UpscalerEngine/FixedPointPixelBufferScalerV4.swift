import CoreVideo
import Foundation
import Metal

enum FixedPointPixelBufferScalerV4Error: Error, Equatable, Sendable {
    case sourceAndDestinationAlias
    case storageMismatch(expected: PixelStorageV4, actual: OSType)
    case inaccessiblePlane(Int)
    case lockFailed(destination: Bool, status: CVReturn)
    case arithmeticOverflow
    case invalidComponentCount(plane: Int, count: Int)
}

enum FixedPointExecutionBackendV4: String, Codable, Hashable, Sendable {
    case cpu
    case metal
}

struct FixedPointPixelBufferScalerHotPathDiagnosticsV4: Equatable, Sendable {
    /// These counters describe prepared storage and the selected I/O topology.
    /// They are not a process-wide malloc trace: command objects, attachment
    /// dictionaries, and the small transfer descriptor set remain outside this
    /// diagnostic contract.
    let completedFrameCount: UInt64
    let scalePreparationCount: Int
    let coefficientCompilationCount: Int
    let cpuWorkspaceAllocationCount: Int
    let cpuReusableHorizontalSampleCount: Int
    let cpuWorkspaceStorageIdentities: [UInt]
    let metalPreparedExecutionCount: Int
    let metalReusableBufferCount: Int
    let metalReusableBufferIdentities: [ObjectIdentifier]
    let metalPipelineIdentityCount: Int
    let metalRetainedPlanarSampleCount: Int
    let fullPlaneSwiftArrayStagingSampleCount: Int
    let usesDirectPixelBufferIO: Bool
}

/// Prepared native NV12/P010 scaler that applies one canonical fixed-point IR
/// to every visible component. Pixel-buffer layout, phase, coefficient, range,
/// border, and attachment decisions are fixed before the first frame.
final class FixedPointPixelBufferScalerV4: @unchecked Sendable {
    private final class PreparedPlane: @unchecked Sendable {
        let layout: PixelPlaneLayoutV4
        let preparedScale: FixedPointPreparedScaleV4
        var cpuWorkspace: FixedPointCPUWorkspaceV4
        let executionRegions: [FixedPointOutputRegionV4]
        let metalExecutions: [FixedPointMetalPreparedExecutionV4]

        init(
            layout: PixelPlaneLayoutV4,
            preparedScale: FixedPointPreparedScaleV4,
            cpuWorkspace: FixedPointCPUWorkspaceV4,
            executionRegions: [FixedPointOutputRegionV4],
            metalExecutions: [FixedPointMetalPreparedExecutionV4]
        ) {
            self.layout = layout
            self.preparedScale = preparedScale
            self.cpuWorkspace = cpuWorkspace
            self.executionRegions = executionRegions
            self.metalExecutions = metalExecutions
        }
    }

    let backend: FixedPointExecutionBackendV4
    let storage: PixelStorageV4
    let sourceWidth: Int
    let sourceHeight: Int
    let targetWidth: Int
    let targetHeight: Int

    private let layout: PixelLayoutV4
    private let planes: [PreparedPlane]
    private let metalBatch: FixedPointMetalPreparedBatchV4?
    private let componentExecutionCount: Int
    private let executionLock = NSLock()
    private var completedFrameCount: UInt64 = 0

    init(
        backend: FixedPointExecutionBackendV4,
        storage: PixelStorageV4,
        sourceWidth: Int,
        sourceHeight: Int,
        targetWidth: Int,
        targetHeight: Int,
        borderRule: SpatialBorderRuleV4 = .clamp,
        executionSchedule: FixedPointExecutionScheduleV4 = .productionFullFrame,
        metalDevice: MTLDevice? = nil,
        metalLibrary: MTLLibrary? = nil
    ) throws {
        let layout = PixelLayoutV4(storage: storage)
        try layout.validateGeometry(width: sourceWidth, height: sourceHeight)
        try layout.validateGeometry(width: targetWidth, height: targetHeight)

        let metalExecutor: FixedPointMetalExecutorV4?
        if backend == .metal {
            let device: MTLDevice
            if let metalDevice {
                device = metalDevice
            } else if let systemDevice = MTLCreateSystemDefaultDevice() {
                device = systemDevice
            } else {
                throw FixedPointMetalExecutorV4Error.metalUnavailable
            }
            metalExecutor = try FixedPointMetalExecutorV4(
                device: device,
                library: metalLibrary
            )
        } else {
            metalExecutor = nil
        }

        var prepared: [PreparedPlane] = []
        var allMetalExecutions: [FixedPointMetalPreparedExecutionV4] = []
        prepared.reserveCapacity(layout.planes.count)
        for plane in layout.planes {
            let sourcePlaneWidth = try plane.width(forFrameWidth: sourceWidth)
            let sourcePlaneHeight = try plane.height(forFrameHeight: sourceHeight)
            let targetPlaneWidth = try plane.width(forFrameWidth: targetWidth)
            let targetPlaneHeight = try plane.height(forFrameHeight: targetHeight)
            let plan = try SpatialScalePlanV4(
                sourceWidth: sourcePlaneWidth,
                sourceHeight: sourcePlaneHeight,
                targetWidth: targetPlaneWidth,
                targetHeight: targetPlaneHeight,
                borderRule: borderRule
            )
            let kernelIR = try FixedPointKernelIRV4(scalePlan: plan)
            let preparedScale = try FixedPointPreparedScaleV4(
                scalePlan: plan,
                kernelIR: kernelIR
            )
            let executionRegions = try executionSchedule.regions(
                targetWidth: targetPlaneWidth,
                targetHeight: targetPlaneHeight
            )
            var workspace = FixedPointCPUWorkspaceV4()
            if backend == .cpu {
                try workspace.prepare(targetWidth: plan.targetWidth)
            }
            var planeMetalExecutions: [FixedPointMetalPreparedExecutionV4] = []
            if let metalExecutor {
                planeMetalExecutions.reserveCapacity(
                    plane.signalCodeBounds.count
                )
                for bounds in plane.signalCodeBounds {
                    planeMetalExecutions.append(
                        try metalExecutor.prepare(
                            sourceRowStride: plan.sourceWidth,
                            scalePlan: plan,
                            kernelIR: kernelIR,
                            minimumCode: bounds.minimum,
                            maximumCode: bounds.maximum,
                            executionRegions: executionRegions
                        )
                    )
                }
                allMetalExecutions.append(contentsOf: planeMetalExecutions)
            }
            prepared.append(
                PreparedPlane(
                    layout: plane,
                    preparedScale: preparedScale,
                    cpuWorkspace: workspace,
                    executionRegions: executionRegions,
                    metalExecutions: planeMetalExecutions
                )
            )
        }

        self.backend = backend
        self.storage = storage
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        self.targetWidth = targetWidth
        self.targetHeight = targetHeight
        self.layout = layout
        self.planes = prepared
        self.componentExecutionCount = layout.planes.reduce(0) {
            $0 + $1.componentsPerElement
        }
        if allMetalExecutions.isEmpty {
            self.metalBatch = nil
        } else {
            self.metalBatch = try FixedPointMetalPreparedBatchV4(
                executions: allMetalExecutions
            )
        }
    }

    func process(
        source: CVPixelBuffer,
        destination: CVPixelBuffer
    ) async throws {
        guard source !== destination else {
            throw FixedPointPixelBufferScalerV4Error.sourceAndDestinationAlias
        }
        try validate(
            source,
            expectedWidth: sourceWidth,
            expectedHeight: sourceHeight
        )
        try validate(
            destination,
            expectedWidth: targetWidth,
            expectedHeight: targetHeight
        )

        try Task.checkCancellation()
        try executionLock.withLock {
            // Cancellation is observed again after waiting for reusable state.
            // Once visible-plane mutation begins, the frame is completed as
            // one boundary so cancellation can never expose a half-written
            // deterministic frame; the next frame observes cancellation.
            try Task.checkCancellation()
            let dynamicMetadata = try AVFoundationHDRMetadataAdapterV4
                .probeDynamicMetadata(from: source)
            try withLockedPlanes(source: source, destination: destination) {
                try preflightNonoverlappingPlaneStorage(
                    source: source,
                    destination: destination
                )
                try validateVisibleSourceCodes(source)
                switch backend {
                case .cpu:
                    try executeCPU(source: source, destination: destination)
                case .metal:
                    try executeMetal(source: source, destination: destination)
                }
            }
            try migrateAttachments(
                from: source,
                to: destination,
                dynamicMetadata: dynamicMetadata
            )
            completedFrameCount &+= 1
        }
    }

    func hotPathDiagnostics()
        -> FixedPointPixelBufferScalerHotPathDiagnosticsV4 {
        executionLock.withLock {
            let metalExecutions = planes.flatMap(\.metalExecutions)
            return FixedPointPixelBufferScalerHotPathDiagnosticsV4(
                completedFrameCount: completedFrameCount,
                scalePreparationCount: planes.count,
                coefficientCompilationCount: planes.count,
                cpuWorkspaceAllocationCount: planes.reduce(0) {
                    $0 + $1.cpuWorkspace.allocationCount
                },
                cpuReusableHorizontalSampleCount: planes.reduce(0) {
                    $0 + $1.cpuWorkspace.reusableHorizontalSampleCount
                },
                cpuWorkspaceStorageIdentities: planes.compactMap {
                    let identity = $0.cpuWorkspace.reusableStorageIdentity
                    return identity == 0 ? nil : identity
                },
                metalPreparedExecutionCount: metalExecutions.count,
                metalReusableBufferCount: metalExecutions.reduce(0) {
                    $0 + $1.reusableBufferCount
                },
                metalReusableBufferIdentities: metalExecutions.flatMap(
                    \.reusableBufferIdentities
                ),
                metalPipelineIdentityCount: Set(
                    metalExecutions.map(\.pipelineIdentity)
                ).count,
                metalRetainedPlanarSampleCount: metalExecutions.reduce(0) {
                    $0 + $1.sourceSampleCount + $1.outputSampleCount
                },
                fullPlaneSwiftArrayStagingSampleCount: 0,
                usesDirectPixelBufferIO: true
            )
        }
    }

    private func validate(
        _ buffer: CVPixelBuffer,
        expectedWidth: Int,
        expectedHeight: Int
    ) throws {
        let actualFormat = CVPixelBufferGetPixelFormatType(buffer)
        guard actualFormat == storage.pixelFormat else {
            throw FixedPointPixelBufferScalerV4Error.storageMismatch(
                expected: storage,
                actual: actualFormat
            )
        }
        try layout.validateStructure(of: buffer)
        guard CVPixelBufferGetWidth(buffer) == expectedWidth,
              CVPixelBufferGetHeight(buffer) == expectedHeight else {
            throw PixelLayoutV4Error.invalidGeometry(
                width: CVPixelBufferGetWidth(buffer),
                height: CVPixelBufferGetHeight(buffer),
                requiredWidthMultiple: layout.requiredWidthMultiple,
                requiredHeightMultiple: layout.requiredHeightMultiple
            )
        }
    }

    private func withLockedPlanes<T>(
        source: CVPixelBuffer,
        destination: CVPixelBuffer,
        _ operation: () throws -> T
    ) throws -> T {
        let status = CVPixelBufferLockBaseAddress(source, .readOnly)
        guard status == kCVReturnSuccess else {
            throw FixedPointPixelBufferScalerV4Error.lockFailed(
                destination: false,
                status: status
            )
        }
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        let destinationStatus = CVPixelBufferLockBaseAddress(destination, [])
        guard destinationStatus == kCVReturnSuccess else {
            throw FixedPointPixelBufferScalerV4Error.lockFailed(
                destination: true,
                status: destinationStatus
            )
        }
        defer { CVPixelBufferUnlockBaseAddress(destination, []) }
        return try operation()
    }

    private func validateVisibleSourceCodes(
        _ source: CVPixelBuffer
    ) throws {
        for planeIndex in planes.indices {
            let prepared = planes[planeIndex]
            guard let base = CVPixelBufferGetBaseAddressOfPlane(
                source,
                planeIndex
            ) else {
                throw FixedPointPixelBufferScalerV4Error.inaccessiblePlane(
                    planeIndex
                )
            }
            let width = prepared.preparedScale.sourceWidth
            let height = prepared.preparedScale.sourceHeight
            let stride = CVPixelBufferGetBytesPerRowOfPlane(source, planeIndex)
            let shift = prepared.layout.storedCodeShift
            let alignmentMask = shift == 0 ? UInt16(0) : UInt16((1 << shift) - 1)
            for y in 0..<height {
                let rowOffset = try checkedProduct(y, stride)
                let row = base.advanced(by: rowOffset)
                    .assumingMemoryBound(to: UInt8.self)
                for x in 0..<width {
                    let element = try checkedProduct(
                        x,
                        prepared.layout.componentsPerElement
                    )
                    for componentIndex in 0..<prepared.layout.componentsPerElement {
                        let sampleIndex = try checkedSum(element, componentIndex)
                        let stored: UInt16
                        if prepared.layout.bytesPerComponent == 1 {
                            stored = UInt16(row[sampleIndex])
                        } else {
                            let byteOffset = try checkedProduct(sampleIndex, 2)
                            stored = UInt16(row[byteOffset])
                                | (UInt16(row[byteOffset + 1]) << 8)
                        }
                        if stored & alignmentMask != 0 {
                            throw PixelLayoutV4Error.invalidStoredCodeAlignment(
                                plane: planeIndex,
                                component: componentIndex,
                                value: stored,
                                requiredZeroLowBits: shift
                            )
                        }
                        let signalCode = stored >> UInt16(shift)
                        let bounds = prepared.layout.signalCodeBounds[
                            componentIndex
                        ]
                        guard bounds.contains(signalCode) else {
                            throw PixelLayoutV4Error.signalCodeOutOfRange(
                                plane: planeIndex,
                                component: componentIndex,
                                value: signalCode,
                                minimum: bounds.minimum,
                                maximum: bounds.maximum
                            )
                        }
                    }
                }
            }
        }
    }

    /// Rejects every source-plane/destination-plane alias before the first
    /// destination write or Metal upload. Object identity is insufficient:
    /// distinct CVPixelBuffer wrappers may legally expose shared planar bytes,
    /// including a destination plane that overlaps a different source plane.
    private func preflightNonoverlappingPlaneStorage(
        source: CVPixelBuffer,
        destination: CVPixelBuffer
    ) throws {
        for sourcePlane in planes.indices {
            guard let sourceBase = CVPixelBufferGetBaseAddressOfPlane(
                source,
                sourcePlane
            ) else {
                throw FixedPointPixelBufferScalerV4Error.inaccessiblePlane(
                    sourcePlane
                )
            }
            let sourceSpan = try Self.memorySpan(
                baseAddress: UnsafeRawPointer(sourceBase),
                rowBytes: CVPixelBufferGetBytesPerRowOfPlane(
                    source,
                    sourcePlane
                ),
                height: CVPixelBufferGetHeightOfPlane(source, sourcePlane)
            )
            for destinationPlane in planes.indices {
                guard let destinationBase = CVPixelBufferGetBaseAddressOfPlane(
                    destination,
                    destinationPlane
                ) else {
                    throw FixedPointPixelBufferScalerV4Error.inaccessiblePlane(
                        destinationPlane
                    )
                }
                let destinationSpan = try Self.memorySpan(
                    baseAddress: UnsafeRawPointer(destinationBase),
                    rowBytes: CVPixelBufferGetBytesPerRowOfPlane(
                        destination,
                        destinationPlane
                    ),
                    height: CVPixelBufferGetHeightOfPlane(
                        destination,
                        destinationPlane
                    )
                )
                if sourceSpan.start < destinationSpan.end,
                   destinationSpan.start < sourceSpan.end {
                    throw FixedPointKernelV4Error
                        .overlappingSourceAndDestination
                }
            }
        }
    }

    private static func memorySpan(
        baseAddress: UnsafeRawPointer,
        rowBytes: Int,
        height: Int
    ) throws -> (start: UInt, end: UInt) {
        let byteCount = rowBytes.multipliedReportingOverflow(by: height)
        guard !byteCount.overflow,
              let length = UInt(exactly: byteCount.partialValue) else {
            throw FixedPointKernelV4Error.executionArithmeticOverflow
        }
        let start = UInt(bitPattern: baseAddress)
        let end = start.addingReportingOverflow(length)
        guard !end.overflow else {
            throw FixedPointKernelV4Error.executionArithmeticOverflow
        }
        return (start, end.partialValue)
    }

    private func executeCPU(
        source: CVPixelBuffer,
        destination: CVPixelBuffer
    ) throws {
        for planeIndex in planes.indices {
            let prepared = planes[planeIndex]
            guard let sourceBase = CVPixelBufferGetBaseAddressOfPlane(
                source,
                planeIndex
            ) else {
                throw FixedPointPixelBufferScalerV4Error.inaccessiblePlane(
                    planeIndex
                )
            }
            guard let destinationBase = CVPixelBufferGetBaseAddressOfPlane(
                destination,
                planeIndex
            ) else {
                throw FixedPointPixelBufferScalerV4Error.inaccessiblePlane(
                    planeIndex
                )
            }
            let sourceStride = CVPixelBufferGetBytesPerRowOfPlane(
                source,
                planeIndex
            )
            let destinationStride = CVPixelBufferGetBytesPerRowOfPlane(
                destination,
                planeIndex
            )
            for componentIndex in prepared.layout.signalCodeBounds.indices {
                let bounds = prepared.layout.signalCodeBounds[componentIndex]
                try FixedPointCPUExecutorV4.executeInterleavedComponent(
                    sourceBaseAddress: UnsafeRawPointer(sourceBase),
                    sourceRowBytes: sourceStride,
                    destinationBaseAddress: destinationBase,
                    destinationRowBytes: destinationStride,
                    bytesPerComponent: prepared.layout.bytesPerComponent,
                    componentsPerElement: prepared.layout.componentsPerElement,
                    componentIndex: componentIndex,
                    storedCodeShift: prepared.layout.storedCodeShift,
                    preparedScale: prepared.preparedScale,
                    minimumCode: bounds.minimum,
                    maximumCode: bounds.maximum,
                    executionRegions: prepared.executionRegions,
                    workspace: &prepared.cpuWorkspace
                )
            }
        }
    }

    private func executeMetal(
        source: CVPixelBuffer,
        destination: CVPixelBuffer
    ) throws {
        guard let metalBatch else {
            throw FixedPointMetalExecutorV4Error.metalUnavailable
        }
        try withUnsafeTemporaryAllocation(
            of: FixedPointMetalComponentTransferV4.self,
            capacity: componentExecutionCount
        ) { transfers in
            var routeIndex = 0
            defer { transfers.baseAddress?.deinitialize(count: routeIndex) }
            for planeIndex in planes.indices {
                let prepared = planes[planeIndex]
                guard let sourceBase = CVPixelBufferGetBaseAddressOfPlane(
                    source,
                    planeIndex
                ), let destinationBase = CVPixelBufferGetBaseAddressOfPlane(
                    destination,
                    planeIndex
                ) else {
                    throw FixedPointPixelBufferScalerV4Error.inaccessiblePlane(
                        planeIndex
                    )
                }
                let sourceStride = CVPixelBufferGetBytesPerRowOfPlane(
                    source,
                    planeIndex
                )
                let destinationStride = CVPixelBufferGetBytesPerRowOfPlane(
                    destination,
                    planeIndex
                )
                for componentIndex in 0..<prepared.layout.componentsPerElement {
                    transfers.initializeElement(
                        at: routeIndex,
                        to: FixedPointMetalComponentTransferV4(
                            sourceBaseAddress: UnsafeRawPointer(sourceBase),
                            sourceRowBytes: sourceStride,
                            destinationBaseAddress: destinationBase,
                            destinationRowBytes: destinationStride,
                            bytesPerComponent: prepared.layout.bytesPerComponent,
                            componentsPerElement:
                                prepared.layout.componentsPerElement,
                            componentIndex: componentIndex,
                            storedCodeShift: prepared.layout.storedCodeShift
                        )
                    )
                    routeIndex += 1
                }
            }
            guard routeIndex == componentExecutionCount else {
                throw FixedPointMetalExecutorV4Error.invalidBatchLayout(
                    expected: componentExecutionCount,
                    actual: routeIndex
                )
            }
            try metalBatch.execute(
                transfers: UnsafeBufferPointer(
                    start: transfers.baseAddress,
                    count: routeIndex
                )
            )
        }
    }

    private func migrateAttachments(
        from source: CVPixelBuffer,
        to destination: CVPixelBuffer,
        dynamicMetadata: HDRDynamicMetadataV4?
    ) throws {
        CVBufferRemoveAllAttachments(destination)
        if let values = CVBufferCopyAttachments(source, .shouldPropagate) {
            CVBufferSetAttachments(destination, values, .shouldPropagate)
        }
        if let values = CVBufferCopyAttachments(source, .shouldNotPropagate) {
            CVBufferSetAttachments(destination, values, .shouldNotPropagate)
        }
        if storage == .p010VideoRange10Bit
            || storage == .p010FullRange10Bit,
           let metadata = try AVFoundationHDRMetadataAdapterV4.probe(
                pixelBuffer: source,
                storage: storage
           ) {
            try AVFoundationHDRMetadataAdapterV4.migrate(
                metadata,
                to: destination
            )
        }
        if let dynamicMetadata {
            try AVFoundationHDRMetadataAdapterV4.migrate(
                dynamicMetadata,
                to: destination
            )
        }
    }

    private func checkedProduct(_ left: Int, _ right: Int) throws -> Int {
        let (result, overflow) = left.multipliedReportingOverflow(by: right)
        guard !overflow else {
            throw FixedPointPixelBufferScalerV4Error.arithmeticOverflow
        }
        return result
    }

    private func checkedSum(_ left: Int, _ right: Int) throws -> Int {
        let (result, overflow) = left.addingReportingOverflow(right)
        guard !overflow else {
            throw FixedPointPixelBufferScalerV4Error.arithmeticOverflow
        }
        return result
    }
}
