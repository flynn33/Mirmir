import CoreVideo
import Foundation

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

/// Prepared native NV12/P010 scaler that applies one canonical fixed-point IR
/// to every visible component. Pixel-buffer layout, phase, coefficient, range,
/// border, and attachment decisions are fixed before the first frame.
final class FixedPointPixelBufferScalerV4: @unchecked Sendable {
    private struct PreparedPlane: Sendable {
        let layout: PixelPlaneLayoutV4
        let plan: SpatialScalePlanV4
        let kernelIR: FixedPointKernelIRV4
    }

    let backend: FixedPointExecutionBackendV4
    let storage: PixelStorageV4
    let sourceWidth: Int
    let sourceHeight: Int
    let targetWidth: Int
    let targetHeight: Int

    private let layout: PixelLayoutV4
    private let planes: [PreparedPlane]
    private let metalExecutor: FixedPointMetalExecutorV4?

    init(
        backend: FixedPointExecutionBackendV4,
        storage: PixelStorageV4,
        sourceWidth: Int,
        sourceHeight: Int,
        targetWidth: Int,
        targetHeight: Int,
        borderRule: SpatialBorderRuleV4 = .clamp
    ) throws {
        let layout = PixelLayoutV4(storage: storage)
        try layout.validateGeometry(width: sourceWidth, height: sourceHeight)
        try layout.validateGeometry(width: targetWidth, height: targetHeight)

        var prepared: [PreparedPlane] = []
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
            prepared.append(
                PreparedPlane(
                    layout: plane,
                    plan: plan,
                    kernelIR: try FixedPointKernelIRV4(scalePlan: plan)
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
        self.metalExecutor = backend == .metal
            ? try FixedPointMetalExecutorV4()
            : nil
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

        let dynamicMetadata = try AVFoundationHDRMetadataAdapterV4
            .probeDynamicMetadata(from: source)
        if dynamicMetadata != nil,
           (sourceWidth != targetWidth || sourceHeight != targetHeight) {
            throw HDRMetadataV4Error.dynamicMetadataRequiresRegeneration
        }

        let sourceComponents = try extractComponents(from: source)
        var outputComponents: [[[UInt16]]] = []
        outputComponents.reserveCapacity(planes.count)
        for planeIndex in planes.indices {
            let prepared = planes[planeIndex]
            let bounds = prepared.layout.signalCodeBounds
            guard bounds.count == sourceComponents[planeIndex].count else {
                throw FixedPointPixelBufferScalerV4Error.invalidComponentCount(
                    plane: planeIndex,
                    count: sourceComponents[planeIndex].count
                )
            }
            var components: [[UInt16]] = []
            components.reserveCapacity(bounds.count)
            for componentIndex in bounds.indices {
                try Task.checkCancellation()
                components.append(
                    try await execute(
                        source: sourceComponents[planeIndex][componentIndex],
                        plan: prepared.plan,
                        kernelIR: prepared.kernelIR,
                        bounds: bounds[componentIndex]
                    )
                )
            }
            outputComponents.append(components)
        }
        try Task.checkCancellation()
        try writeComponents(outputComponents, to: destination)
        try migrateAttachments(
            from: source,
            to: destination,
            dynamicMetadata: dynamicMetadata
        )
    }

    private func execute(
        source: [UInt16],
        plan: SpatialScalePlanV4,
        kernelIR: FixedPointKernelIRV4,
        bounds: PixelCodeBoundsV4
    ) async throws -> [UInt16] {
        switch backend {
        case .cpu:
            return try FixedPointCPUExecutorV4.execute(
                source: source,
                sourceRowStride: plan.sourceWidth,
                scalePlan: plan,
                kernelIR: kernelIR,
                minimumCode: bounds.minimum,
                maximumCode: bounds.maximum
            )
        case .metal:
            guard let metalExecutor else {
                throw FixedPointMetalExecutorV4Error.metalUnavailable
            }
            return try await metalExecutor.execute(
                source: source,
                sourceRowStride: plan.sourceWidth,
                scalePlan: plan,
                kernelIR: kernelIR,
                minimumCode: bounds.minimum,
                maximumCode: bounds.maximum
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

    private func extractComponents(
        from source: CVPixelBuffer
    ) throws -> [[[UInt16]]] {
        let status = CVPixelBufferLockBaseAddress(source, .readOnly)
        guard status == kCVReturnSuccess else {
            throw FixedPointPixelBufferScalerV4Error.lockFailed(
                destination: false,
                status: status
            )
        }
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }

        var result: [[[UInt16]]] = []
        result.reserveCapacity(planes.count)
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
            let width = prepared.plan.sourceWidth
            let height = prepared.plan.sourceHeight
            let stride = CVPixelBufferGetBytesPerRowOfPlane(source, planeIndex)
            let count = try checkedProduct(width, height)
            var components = Array(
                repeating: [UInt16](),
                count: prepared.layout.componentsPerElement
            )
            for index in components.indices {
                components[index].reserveCapacity(count)
            }
            for y in 0..<height {
                let rowOffset = try checkedProduct(y, stride)
                let row = base.advanced(by: rowOffset)
                    .assumingMemoryBound(to: UInt8.self)
                for x in 0..<width {
                    let element = try checkedProduct(
                        x,
                        prepared.layout.componentsPerElement
                    )
                    for componentIndex in components.indices {
                        let sampleIndex = try checkedSum(element, componentIndex)
                        let stored: UInt16
                        if prepared.layout.bytesPerComponent == 1 {
                            stored = UInt16(row[sampleIndex])
                        } else {
                            let byteOffset = try checkedProduct(sampleIndex, 2)
                            stored = UInt16(row[byteOffset])
                                | (UInt16(row[byteOffset + 1]) << 8)
                        }
                        components[componentIndex].append(
                            try layout.validateStoredCode(
                                stored,
                                plane: planeIndex,
                                component: componentIndex
                            )
                        )
                    }
                }
            }
            result.append(components)
        }
        return result
    }

    private func writeComponents(
        _ componentsByPlane: [[[UInt16]]],
        to destination: CVPixelBuffer
    ) throws {
        let status = CVPixelBufferLockBaseAddress(destination, [])
        guard status == kCVReturnSuccess else {
            throw FixedPointPixelBufferScalerV4Error.lockFailed(
                destination: true,
                status: status
            )
        }
        defer { CVPixelBufferUnlockBaseAddress(destination, []) }

        guard componentsByPlane.count == planes.count else {
            throw FixedPointPixelBufferScalerV4Error.invalidComponentCount(
                plane: -1,
                count: componentsByPlane.count
            )
        }
        for planeIndex in planes.indices {
            let prepared = planes[planeIndex]
            let components = componentsByPlane[planeIndex]
            guard components.count == prepared.layout.componentsPerElement,
                  let sampleCount = components.first?.count,
                  components.allSatisfy({ $0.count == sampleCount }) else {
                throw FixedPointPixelBufferScalerV4Error.invalidComponentCount(
                    plane: planeIndex,
                    count: components.count
                )
            }
            guard let base = CVPixelBufferGetBaseAddressOfPlane(
                destination,
                planeIndex
            ) else {
                throw FixedPointPixelBufferScalerV4Error.inaccessiblePlane(
                    planeIndex
                )
            }
            let width = prepared.plan.targetWidth
            let height = prepared.plan.targetHeight
            guard sampleCount == (try checkedProduct(width, height)) else {
                throw FixedPointPixelBufferScalerV4Error.invalidComponentCount(
                    plane: planeIndex,
                    count: sampleCount
                )
            }
            let stride = CVPixelBufferGetBytesPerRowOfPlane(
                destination,
                planeIndex
            )
            for y in 0..<height {
                let rowOffset = try checkedProduct(y, stride)
                let row = base.advanced(by: rowOffset)
                    .assumingMemoryBound(to: UInt8.self)
                for x in 0..<width {
                    let pixelIndex = try checkedSum(
                        try checkedProduct(y, width),
                        x
                    )
                    let element = try checkedProduct(
                        x,
                        prepared.layout.componentsPerElement
                    )
                    for componentIndex in components.indices {
                        let stored = try layout.storedCode(
                            forSignalCode: components[componentIndex][pixelIndex],
                            plane: planeIndex,
                            component: componentIndex
                        )
                        let sampleIndex = try checkedSum(element, componentIndex)
                        if prepared.layout.bytesPerComponent == 1 {
                            row[sampleIndex] = UInt8(stored)
                        } else {
                            let byteOffset = try checkedProduct(sampleIndex, 2)
                            row[byteOffset] = UInt8(truncatingIfNeeded: stored)
                            row[byteOffset + 1] = UInt8(
                                truncatingIfNeeded: stored >> 8
                            )
                        }
                    }
                }
            }
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
        if sourceWidth == targetWidth,
           sourceHeight == targetHeight,
           let dynamicMetadata {
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
