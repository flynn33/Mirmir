import CoreVideo
import Foundation

enum PixelBufferSignalCodecV4Error: Error, Equatable, Sendable {
    case lockFailed(destination: Bool, status: CVReturn)
    case inaccessiblePlane(Int)
    case invalidPlaneCount(expected: Int, actual: Int)
    case invalidSignalGeometry(plane: Int)
    case invalidSampleCount(plane: Int, expected: Int, actual: Int)
    case invalidComponentBounds(plane: Int)
    case allocationFailed(CVReturn)
    case arithmeticOverflow
}

struct PixelBufferSignalPlaneV4: Codable, Equatable, Hashable, Sendable {
    let width: Int
    let height: Int
    let componentsPerElement: Int
    let componentBounds: [PixelCodeBoundsV4]
    /// Pixel-major active samples. Padding bytes and row stride are excluded.
    let samples: [UInt16]

    init(
        width: Int,
        height: Int,
        componentsPerElement: Int,
        componentBounds: [PixelCodeBoundsV4],
        samples: [UInt16]
    ) throws {
        guard width > 0, height > 0, componentsPerElement > 0 else {
            throw PixelBufferSignalCodecV4Error.invalidSignalGeometry(plane: -1)
        }
        guard componentBounds.count == componentsPerElement else {
            throw PixelBufferSignalCodecV4Error.invalidComponentBounds(plane: -1)
        }
        let pixelCount = width.multipliedReportingOverflow(by: height)
        let sampleCount = pixelCount.partialValue.multipliedReportingOverflow(
            by: componentsPerElement
        )
        guard !pixelCount.overflow,
              !sampleCount.overflow,
              samples.count == sampleCount.partialValue else {
            throw PixelBufferSignalCodecV4Error.invalidSampleCount(
                plane: -1,
                expected: sampleCount.partialValue,
                actual: samples.count
            )
        }
        for pixelIndex in 0..<pixelCount.partialValue {
            for component in 0..<componentsPerElement {
                let value = samples[pixelIndex * componentsPerElement + component]
                guard componentBounds[component].contains(value) else {
                    throw PixelLayoutV4Error.signalCodeOutOfRange(
                        plane: -1,
                        component: component,
                        value: value,
                        minimum: componentBounds[component].minimum,
                        maximum: componentBounds[component].maximum
                    )
                }
            }
        }
        self.width = width
        self.height = height
        self.componentsPerElement = componentsPerElement
        self.componentBounds = componentBounds
        self.samples = samples
    }

    func component(_ component: Int) throws -> [UInt16] {
        guard component >= 0, component < componentsPerElement else {
            throw PixelBufferSignalCodecV4Error.invalidComponentBounds(plane: -1)
        }
        var result: [UInt16] = []
        result.reserveCapacity(width * height)
        var index = component
        while index < samples.count {
            result.append(samples[index])
            index += componentsPerElement
        }
        return result
    }

    func replacingComponent(
        _ component: Int,
        with values: [UInt16]
    ) throws -> Self {
        guard component >= 0,
              component < componentsPerElement,
              values.count == width * height else {
            throw PixelBufferSignalCodecV4Error.invalidSampleCount(
                plane: -1,
                expected: width * height,
                actual: values.count
            )
        }
        var replacement = samples
        for index in values.indices {
            replacement[index * componentsPerElement + component] = values[index]
        }
        return try Self(
            width: width,
            height: height,
            componentsPerElement: componentsPerElement,
            componentBounds: componentBounds,
            samples: replacement
        )
    }

    func validate() throws {
        _ = try Self(
            width: width,
            height: height,
            componentsPerElement: componentsPerElement,
            componentBounds: componentBounds,
            samples: samples
        )
    }
}

struct PixelBufferSignalFrameV4: Codable, Equatable, Hashable, Sendable {
    let storage: PixelStorageV4
    let width: Int
    let height: Int
    let planes: [PixelBufferSignalPlaneV4]

    func validate() throws {
        let layout = PixelLayoutV4(storage: storage)
        try layout.validateGeometry(width: width, height: height)
        guard planes.count == layout.planes.count else {
            throw PixelBufferSignalCodecV4Error.invalidPlaneCount(
                expected: layout.planes.count,
                actual: planes.count
            )
        }
        for (planeIndex, planeLayout) in layout.planes.enumerated() {
            let plane = planes[planeIndex]
            try plane.validate()
            guard plane.width == (try planeLayout.width(forFrameWidth: width)),
                  plane.height
                    == (try planeLayout.height(forFrameHeight: height)),
                  plane.componentsPerElement
                    == planeLayout.componentsPerElement,
                  plane.componentBounds == planeLayout.signalCodeBounds else {
                throw PixelBufferSignalCodecV4Error.invalidSignalGeometry(
                    plane: planeIndex
                )
            }
        }
    }
}

enum PixelBufferSignalCodecV4 {
    static func read(
        _ buffer: CVPixelBuffer,
        storage: PixelStorageV4
    ) throws -> PixelBufferSignalFrameV4 {
        let layout = PixelLayoutV4(storage: storage)
        try layout.validateStructure(of: buffer)
        let status = CVPixelBufferLockBaseAddress(buffer, .readOnly)
        guard status == kCVReturnSuccess else {
            throw PixelBufferSignalCodecV4Error.lockFailed(
                destination: false,
                status: status
            )
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        let frameWidth = CVPixelBufferGetWidth(buffer)
        let frameHeight = CVPixelBufferGetHeight(buffer)
        var planes: [PixelBufferSignalPlaneV4] = []
        planes.reserveCapacity(layout.planes.count)
        for (planeIndex, planeLayout) in layout.planes.enumerated() {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(
                buffer,
                planeIndex
            ) else {
                throw PixelBufferSignalCodecV4Error.inaccessiblePlane(planeIndex)
            }
            let width = try planeLayout.width(forFrameWidth: frameWidth)
            let height = try planeLayout.height(forFrameHeight: frameHeight)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, planeIndex)
            let count = try checkedProduct(
                try checkedProduct(width, height),
                planeLayout.componentsPerElement
            )
            var samples: [UInt16] = []
            samples.reserveCapacity(count)
            for y in 0..<height {
                let row = base.advanced(by: try checkedProduct(y, stride))
                    .assumingMemoryBound(to: UInt8.self)
                for x in 0..<width {
                    for component in 0..<planeLayout.componentsPerElement {
                        let element = try checkedSum(
                            try checkedProduct(
                                x,
                                planeLayout.componentsPerElement
                            ),
                            component
                        )
                        let stored: UInt16
                        if planeLayout.bytesPerComponent == 1 {
                            stored = UInt16(row[element])
                        } else {
                            let offset = try checkedProduct(element, 2)
                            stored = UInt16(row[offset])
                                | UInt16(row[offset + 1]) << 8
                        }
                        samples.append(
                            try layout.validateStoredCode(
                                stored,
                                plane: planeIndex,
                                component: component
                            )
                        )
                    }
                }
            }
            planes.append(try PixelBufferSignalPlaneV4(
                width: width,
                height: height,
                componentsPerElement: planeLayout.componentsPerElement,
                componentBounds: planeLayout.signalCodeBounds,
                samples: samples
            ))
        }
        return PixelBufferSignalFrameV4(
            storage: storage,
            width: frameWidth,
            height: frameHeight,
            planes: planes
        )
    }

    static func write(
        _ frame: PixelBufferSignalFrameV4,
        to buffer: CVPixelBuffer,
        copyAttachmentsFrom source: CVPixelBuffer? = nil
    ) throws {
        let layout = PixelLayoutV4(storage: frame.storage)
        try layout.validateStructure(of: buffer)
        guard CVPixelBufferGetWidth(buffer) == frame.width,
              CVPixelBufferGetHeight(buffer) == frame.height,
              frame.planes.count == layout.planes.count else {
            throw PixelBufferSignalCodecV4Error.invalidPlaneCount(
                expected: layout.planes.count,
                actual: frame.planes.count
            )
        }
        let status = CVPixelBufferLockBaseAddress(buffer, [])
        guard status == kCVReturnSuccess else {
            throw PixelBufferSignalCodecV4Error.lockFailed(
                destination: true,
                status: status
            )
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        for (planeIndex, planeLayout) in layout.planes.enumerated() {
            let plane = frame.planes[planeIndex]
            let expectedWidth = try planeLayout.width(forFrameWidth: frame.width)
            let expectedHeight = try planeLayout.height(forFrameHeight: frame.height)
            guard plane.width == expectedWidth,
                  plane.height == expectedHeight,
                  plane.componentsPerElement == planeLayout.componentsPerElement,
                  plane.componentBounds == planeLayout.signalCodeBounds else {
                throw PixelBufferSignalCodecV4Error.invalidSignalGeometry(
                    plane: planeIndex
                )
            }
            guard let base = CVPixelBufferGetBaseAddressOfPlane(
                buffer,
                planeIndex
            ) else {
                throw PixelBufferSignalCodecV4Error.inaccessiblePlane(planeIndex)
            }
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, planeIndex)
            for y in 0..<plane.height {
                let row = base.advanced(by: try checkedProduct(y, stride))
                    .assumingMemoryBound(to: UInt8.self)
                for x in 0..<plane.width {
                    for component in 0..<plane.componentsPerElement {
                        let sampleIndex = try checkedSum(
                            try checkedProduct(
                                try checkedSum(
                                    try checkedProduct(y, plane.width),
                                    x
                                ),
                                plane.componentsPerElement
                            ),
                            component
                        )
                        let stored = try layout.storedCode(
                            forSignalCode: plane.samples[sampleIndex],
                            plane: planeIndex,
                            component: component
                        )
                        let element = try checkedSum(
                            try checkedProduct(x, plane.componentsPerElement),
                            component
                        )
                        if planeLayout.bytesPerComponent == 1 {
                            row[element] = UInt8(stored)
                        } else {
                            let offset = try checkedProduct(element, 2)
                            row[offset] = UInt8(truncatingIfNeeded: stored)
                            row[offset + 1] = UInt8(truncatingIfNeeded: stored >> 8)
                        }
                    }
                }
            }
        }
        if let source {
            copyAttachments(from: source, to: buffer)
        }
    }

    static func makeBuffer(
        storage: PixelStorageV4,
        width: Int,
        height: Int,
        metalCompatible: Bool
    ) throws -> CVPixelBuffer {
        var attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary
        ]
        if metalCompatible {
            attributes[kCVPixelBufferMetalCompatibilityKey as String] = true
        }
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            storage.pixelFormat,
            attributes as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            throw PixelBufferSignalCodecV4Error.allocationFailed(status)
        }
        return buffer
    }

    static func copyAttachments(
        from source: CVPixelBuffer,
        to destination: CVPixelBuffer
    ) {
        CVBufferRemoveAllAttachments(destination)
        if let values = CVBufferCopyAttachments(source, .shouldPropagate) {
            CVBufferSetAttachments(destination, values, .shouldPropagate)
        }
        if let values = CVBufferCopyAttachments(source, .shouldNotPropagate) {
            CVBufferSetAttachments(destination, values, .shouldNotPropagate)
        }
    }

    private static func checkedProduct(_ left: Int, _ right: Int) throws -> Int {
        let result = left.multipliedReportingOverflow(by: right)
        guard !result.overflow else {
            throw PixelBufferSignalCodecV4Error.arithmeticOverflow
        }
        return result.partialValue
    }

    private static func checkedSum(_ left: Int, _ right: Int) throws -> Int {
        let result = left.addingReportingOverflow(right)
        guard !result.overflow else {
            throw PixelBufferSignalCodecV4Error.arithmeticOverflow
        }
        return result.partialValue
    }
}
