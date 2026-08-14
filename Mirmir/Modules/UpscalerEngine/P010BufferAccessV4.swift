import CoreVideo
import Foundation

enum P010BufferAccessV4Error: Error, Equatable, Sendable {
    case unsupportedStorage(PixelStorageV4)
    case geometryMismatch(
        sourceWidth: Int,
        sourceHeight: Int,
        destinationWidth: Int,
        destinationHeight: Int
    )
    case lockFailed(destination: Bool, status: CVReturn)
    case inaccessiblePlane(Int)
    case coordinateOutOfRange(
        component: P010ComponentV4,
        x: Int,
        y: Int,
        width: Int,
        height: Int
    )
    case arithmeticOverflow
}

enum P010ComponentV4: String, Hashable, Sendable {
    case luma
    case cb
    case cr
}

enum P010AttachmentCopyPolicyV4: String, Hashable, Sendable {
    case none
    case preserveAll
}

/// Native P010 access. Samples remain ten-bit signal codes stored in the most
/// significant bits of little-endian UInt16 words; no 8-bit bridge is used.
enum P010BufferAccessV4 {
    static func validateCodeValues(
        in pixelBuffer: CVPixelBuffer,
        storage: PixelStorageV4
    ) throws {
        let layout = try p010Layout(storage: storage)
        try layout.validateStructure(of: pixelBuffer)
        try lockReadOnly(pixelBuffer)
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        }
        try validateCodeValuesLocked(in: pixelBuffer, layout: layout)
    }

    /// Coordinates are expressed in the selected component's own sample grid.
    /// Luma uses the coded raster; Cb and Cr use the ceil-divided 4:2:0 grid.
    static func signalCode(
        in pixelBuffer: CVPixelBuffer,
        storage: PixelStorageV4,
        component: P010ComponentV4,
        x: Int,
        y: Int
    ) throws -> UInt16 {
        let layout = try p010Layout(storage: storage)
        try layout.validateStructure(of: pixelBuffer)
        try lockReadOnly(pixelBuffer)
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        }
        let location = try componentLocation(
            component,
            x: x,
            y: y,
            pixelBuffer: pixelBuffer,
            layout: layout
        )
        let stored = try readStoredCodeLocked(
            from: pixelBuffer,
            location: location
        )
        return try layout.validateStoredCode(
            stored,
            plane: location.plane,
            component: location.componentIndex
        )
    }

    static func writeSignalCode(
        _ signalCode: UInt16,
        to pixelBuffer: CVPixelBuffer,
        storage: PixelStorageV4,
        component: P010ComponentV4,
        x: Int,
        y: Int
    ) throws {
        let layout = try p010Layout(storage: storage)
        try layout.validateStructure(of: pixelBuffer)
        let location = try componentLocation(
            component,
            x: x,
            y: y,
            pixelBuffer: pixelBuffer,
            layout: layout
        )
        let stored = try layout.storedCode(
            forSignalCode: signalCode,
            plane: location.plane,
            component: location.componentIndex
        )
        try lockWritable(pixelBuffer)
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        }
        try writeStoredCodeLocked(
            stored,
            to: pixelBuffer,
            location: location
        )
    }

    static func copyActiveImage(
        from source: CVPixelBuffer,
        to destination: CVPixelBuffer,
        storage: PixelStorageV4,
        attachmentPolicy: P010AttachmentCopyPolicyV4 = .preserveAll
    ) throws {
        let layout = try p010Layout(storage: storage)
        try layout.validateStructure(of: source)
        try layout.validateStructure(of: destination)

        let sourceWidth = CVPixelBufferGetWidth(source)
        let sourceHeight = CVPixelBufferGetHeight(source)
        let destinationWidth = CVPixelBufferGetWidth(destination)
        let destinationHeight = CVPixelBufferGetHeight(destination)
        guard sourceWidth == destinationWidth,
              sourceHeight == destinationHeight else {
            throw P010BufferAccessV4Error.geometryMismatch(
                sourceWidth: sourceWidth,
                sourceHeight: sourceHeight,
                destinationWidth: destinationWidth,
                destinationHeight: destinationHeight
            )
        }

        if source === destination {
            try validateCodeValues(in: source, storage: storage)
            return
        }

        do {
            try lockReadOnly(source)
            defer {
                CVPixelBufferUnlockBaseAddress(source, .readOnly)
            }
            try lockWritable(destination)
            defer {
                CVPixelBufferUnlockBaseAddress(destination, [])
            }

            try validateCodeValuesLocked(in: source, layout: layout)
            for (planeIndex, plane) in layout.planes.enumerated() {
                guard let sourceBase = CVPixelBufferGetBaseAddressOfPlane(
                    source,
                    planeIndex
                ) else {
                    throw P010BufferAccessV4Error.inaccessiblePlane(planeIndex)
                }
                guard let destinationBase = CVPixelBufferGetBaseAddressOfPlane(
                    destination,
                    planeIndex
                ) else {
                    throw P010BufferAccessV4Error.inaccessiblePlane(planeIndex)
                }
                let activeRowBytes = try plane.activeBytesPerRow(
                    frameWidth: sourceWidth
                )
                let rowCount = try plane.height(forFrameHeight: sourceHeight)
                let sourceStride = CVPixelBufferGetBytesPerRowOfPlane(
                    source,
                    planeIndex
                )
                let destinationStride = CVPixelBufferGetBytesPerRowOfPlane(
                    destination,
                    planeIndex
                )
                for row in 0..<rowCount {
                    let sourceOffset = try checkedProduct(row, sourceStride)
                    let destinationOffset = try checkedProduct(
                        row,
                        destinationStride
                    )
                    destinationBase.advanced(by: destinationOffset).copyMemory(
                        from: sourceBase.advanced(by: sourceOffset),
                        byteCount: activeRowBytes
                    )
                }
            }
            try validateCodeValuesLocked(in: destination, layout: layout)
        }

        if attachmentPolicy == .preserveAll {
            copyAllAttachments(from: source, to: destination)
        }
    }

    private struct ComponentLocation {
        let plane: Int
        let componentIndex: Int
        let x: Int
        let y: Int
        let componentCount: Int
    }

    private static func p010Layout(
        storage: PixelStorageV4
    ) throws -> PixelLayoutV4 {
        guard storage == .p010VideoRange10Bit
                || storage == .p010FullRange10Bit else {
            throw P010BufferAccessV4Error.unsupportedStorage(storage)
        }
        return PixelLayoutV4(storage: storage)
    }

    private static func componentLocation(
        _ component: P010ComponentV4,
        x: Int,
        y: Int,
        pixelBuffer: CVPixelBuffer,
        layout: PixelLayoutV4
    ) throws -> ComponentLocation {
        let plane: Int
        let componentIndex: Int
        switch component {
        case .luma:
            plane = 0
            componentIndex = 0
        case .cb:
            plane = 1
            componentIndex = 0
        case .cr:
            plane = 1
            componentIndex = 1
        }
        let planeLayout = try layout.plane(at: plane)
        let width = try planeLayout.width(
            forFrameWidth: CVPixelBufferGetWidth(pixelBuffer)
        )
        let height = try planeLayout.height(
            forFrameHeight: CVPixelBufferGetHeight(pixelBuffer)
        )
        guard x >= 0, y >= 0, x < width, y < height else {
            throw P010BufferAccessV4Error.coordinateOutOfRange(
                component: component,
                x: x,
                y: y,
                width: width,
                height: height
            )
        }
        return ComponentLocation(
            plane: plane,
            componentIndex: componentIndex,
            x: x,
            y: y,
            componentCount: planeLayout.componentsPerElement
        )
    }

    private static func validateCodeValuesLocked(
        in pixelBuffer: CVPixelBuffer,
        layout: PixelLayoutV4
    ) throws {
        let frameWidth = CVPixelBufferGetWidth(pixelBuffer)
        let frameHeight = CVPixelBufferGetHeight(pixelBuffer)
        for (planeIndex, plane) in layout.planes.enumerated() {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(
                pixelBuffer,
                planeIndex
            ) else {
                throw P010BufferAccessV4Error.inaccessiblePlane(planeIndex)
            }
            let width = try plane.width(forFrameWidth: frameWidth)
            let height = try plane.height(forFrameHeight: frameHeight)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(
                pixelBuffer,
                planeIndex
            )
            for row in 0..<height {
                let rowOffset = try checkedProduct(row, stride)
                let rowBytes = base.advanced(by: rowOffset)
                    .assumingMemoryBound(to: UInt8.self)
                for x in 0..<width {
                    for component in 0..<plane.componentsPerElement {
                        let elementIndex = try checkedProduct(
                            x,
                            plane.componentsPerElement
                        )
                        let componentIndex = try checkedSum(
                            elementIndex,
                            component
                        )
                        let byteOffset = try checkedProduct(componentIndex, 2)
                        let stored = readLittleEndianUInt16(
                            from: rowBytes,
                            byteOffset: byteOffset
                        )
                        try layout.validateStoredCode(
                            stored,
                            plane: planeIndex,
                            component: component
                        )
                    }
                }
            }
        }
    }

    private static func readStoredCodeLocked(
        from pixelBuffer: CVPixelBuffer,
        location: ComponentLocation
    ) throws -> UInt16 {
        guard let base = CVPixelBufferGetBaseAddressOfPlane(
            pixelBuffer,
            location.plane
        ) else {
            throw P010BufferAccessV4Error.inaccessiblePlane(location.plane)
        }
        let stride = CVPixelBufferGetBytesPerRowOfPlane(
            pixelBuffer,
            location.plane
        )
        let rowOffset = try checkedProduct(location.y, stride)
        let elementIndex = try checkedProduct(
            location.x,
            location.componentCount
        )
        let componentIndex = try checkedSum(
            elementIndex,
            location.componentIndex
        )
        let byteOffset = try checkedProduct(componentIndex, 2)
        let row = base.advanced(by: rowOffset).assumingMemoryBound(to: UInt8.self)
        return readLittleEndianUInt16(from: row, byteOffset: byteOffset)
    }

    private static func writeStoredCodeLocked(
        _ value: UInt16,
        to pixelBuffer: CVPixelBuffer,
        location: ComponentLocation
    ) throws {
        guard let base = CVPixelBufferGetBaseAddressOfPlane(
            pixelBuffer,
            location.plane
        ) else {
            throw P010BufferAccessV4Error.inaccessiblePlane(location.plane)
        }
        let stride = CVPixelBufferGetBytesPerRowOfPlane(
            pixelBuffer,
            location.plane
        )
        let rowOffset = try checkedProduct(location.y, stride)
        let elementIndex = try checkedProduct(
            location.x,
            location.componentCount
        )
        let componentIndex = try checkedSum(
            elementIndex,
            location.componentIndex
        )
        let byteOffset = try checkedProduct(componentIndex, 2)
        let row = base.advanced(by: rowOffset).assumingMemoryBound(to: UInt8.self)
        row[byteOffset] = UInt8(truncatingIfNeeded: value)
        row[byteOffset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }

    private static func readLittleEndianUInt16(
        from bytes: UnsafePointer<UInt8>,
        byteOffset: Int
    ) -> UInt16 {
        UInt16(bytes[byteOffset]) | (UInt16(bytes[byteOffset + 1]) << 8)
    }

    private static func lockReadOnly(_ pixelBuffer: CVPixelBuffer) throws {
        let status = CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        guard status == kCVReturnSuccess else {
            throw P010BufferAccessV4Error.lockFailed(
                destination: false,
                status: status
            )
        }
    }

    private static func lockWritable(_ pixelBuffer: CVPixelBuffer) throws {
        let status = CVPixelBufferLockBaseAddress(pixelBuffer, [])
        guard status == kCVReturnSuccess else {
            throw P010BufferAccessV4Error.lockFailed(
                destination: true,
                status: status
            )
        }
    }

    private static func copyAllAttachments(
        from source: CVPixelBuffer,
        to destination: CVPixelBuffer
    ) {
        CVBufferRemoveAllAttachments(destination)
        if let propagated = CVBufferCopyAttachments(source, .shouldPropagate) {
            CVBufferSetAttachments(
                destination,
                propagated,
                .shouldPropagate
            )
        }
        if let local = CVBufferCopyAttachments(source, .shouldNotPropagate) {
            CVBufferSetAttachments(
                destination,
                local,
                .shouldNotPropagate
            )
        }
    }

    private static func checkedProduct(_ left: Int, _ right: Int) throws -> Int {
        let (result, overflow) = left.multipliedReportingOverflow(by: right)
        guard !overflow else {
            throw P010BufferAccessV4Error.arithmeticOverflow
        }
        return result
    }

    private static func checkedSum(_ left: Int, _ right: Int) throws -> Int {
        let (result, overflow) = left.addingReportingOverflow(right)
        guard !overflow else {
            throw P010BufferAccessV4Error.arithmeticOverflow
        }
        return result
    }
}
