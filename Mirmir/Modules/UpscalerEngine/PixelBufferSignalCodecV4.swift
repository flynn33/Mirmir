import CoreVideo
import Foundation

enum PixelBufferSignalCodecV4Error: Error, Equatable, Sendable {
    case lockFailed(destination: Bool, status: CVReturn)
    case inaccessiblePlane(Int)
    case invalidPlaneCount(expected: Int, actual: Int)
    case invalidSignalGeometry(plane: Int)
    case invalidSampleCount(plane: Int, expected: Int, actual: Int)
    case invalidComponentBounds(plane: Int)
    case invalidWindowGeometry(width: Int, height: Int)
    case allocationFailed(CVReturn)
    case arithmeticOverflow
}

/// Reusable active-image luma storage. The workspace deliberately owns only
/// one signal-code sample per visible pixel; row padding and chroma never enter
/// the temporal boundary. `storageAllocationCount` also observes unexpected
/// copy-on-write detaches, so integrations can prove that two rotating
/// workspaces remain allocation-stable after warm-up.
struct PixelBufferLumaWorkspaceV4: Sendable {
    private(set) var storage: PixelStorageV4?
    private(set) var width = 0
    private(set) var height = 0
    private(set) var minimumCode: UInt16 = 0
    private(set) var maximumCode: UInt16 = 0
    fileprivate(set) var samples: [UInt16] = []
    private(set) var reservedSampleCapacity = 0
    private(set) var peakVisibleSampleCount = 0
    private(set) var storageAllocationCount = 0
    private(set) var storageIdentity: UInt = 0

    var visibleSampleCount: Int { samples.count }
    var retainedByteUpperBound: Int {
        reservedSampleCapacity * MemoryLayout<UInt16>.stride
    }

    func temporalPlane() throws -> ASHTemporalPlaneV4 {
        try ASHTemporalPlaneV4(
            width: width,
            height: height,
            minimumCode: minimumCode,
            maximumCode: maximumCode,
            samples: samples
        )
    }

    /// Borrows the active luma array for allocation-free in-place conditioning.
    /// Any copy-on-write detach caused by a retained value view is reflected in
    /// `storageAllocationCount` when the borrow closes.
    mutating func withMutableSamples<Result>(
        _ body: (inout [UInt16]) throws -> Result
    ) rethrows -> Result {
        let priorIdentity = storageIdentity
        let result = try body(&samples)
        let nextIdentity = samples.withUnsafeBufferPointer { buffer -> UInt in
            guard let base = buffer.baseAddress else { return 0 }
            return UInt(bitPattern: base)
        }
        if priorIdentity != 0, nextIdentity != priorIdentity {
            storageAllocationCount += 1
        }
        storageIdentity = nextIdentity
        return result
    }

    fileprivate mutating func prepare(sampleCount: Int) throws {
        guard sampleCount > 0 else {
            throw PixelBufferSignalCodecV4Error.invalidSignalGeometry(plane: 0)
        }
        let priorIdentity = storageIdentity
        let declaredAllocation = sampleCount > reservedSampleCapacity
        if declaredAllocation {
            samples = Array(repeating: 0, count: sampleCount)
            reservedSampleCapacity = sampleCount
            storageAllocationCount += 1
        } else if samples.count < sampleCount {
            samples.append(
                contentsOf: repeatElement(
                    0,
                    count: sampleCount - samples.count
                )
            )
        } else if samples.count > sampleCount {
            samples.removeLast(samples.count - sampleCount)
        }
        peakVisibleSampleCount = max(peakVisibleSampleCount, sampleCount)
        let nextIdentity = samples.withUnsafeBufferPointer { buffer -> UInt in
            guard let base = buffer.baseAddress else { return 0 }
            return UInt(bitPattern: base)
        }
        if !declaredAllocation,
           priorIdentity != 0,
           nextIdentity != priorIdentity {
            // A retained value view forced Array copy-on-write. Count it rather
            // than silently claiming workspace reuse.
            storageAllocationCount += 1
        }
        storageIdentity = nextIdentity
    }

    fileprivate mutating func configure(
        storage: PixelStorageV4,
        width: Int,
        height: Int,
        bounds: PixelCodeBoundsV4
    ) {
        self.storage = storage
        self.width = width
        self.height = height
        minimumCode = bounds.minimum
        maximumCode = bounds.maximum
    }

    fileprivate mutating func finishWrite() {
        let nextIdentity = samples.withUnsafeBufferPointer { buffer -> UInt in
            guard let base = buffer.baseAddress else { return 0 }
            return UInt(bitPattern: base)
        }
        if storageIdentity != 0, nextIdentity != storageIdentity {
            storageAllocationCount += 1
        }
        storageIdentity = nextIdentity
    }
}

/// Raw, compact evidence window. Each canonical window coordinate retains one
/// luma, Cb, and Cr code, including the reference path's edge replication for
/// images smaller than the declared window. Capacity is contract-bounded and
/// independent of source resolution.
struct PixelBufferSignalWindowWorkspaceV4: Sendable {
    static let maximumWindowSampleCount = 4_096

    private(set) var storage: PixelStorageV4?
    private(set) var sourceWidth = 0
    private(set) var sourceHeight = 0
    private(set) var windowWidth = 0
    private(set) var windowHeight = 0
    fileprivate(set) var samples: [UInt16] = []
    private(set) var reservedWindowSampleCapacity = 0
    private(set) var storageAllocationCount = 0
    private(set) var storageIdentity: UInt = 0

    var windowSampleCount: Int { windowWidth * windowHeight }
    var retainedByteUpperBound: Int {
        reservedWindowSampleCapacity * 3 * MemoryLayout<UInt16>.stride
    }

    func luma(at index: Int) -> UInt16 { samples[index] }
    func cb(at index: Int) -> UInt16 { samples[windowSampleCount + index] }
    func cr(at index: Int) -> UInt16 {
        samples[windowSampleCount * 2 + index]
    }

    fileprivate mutating func prepare(
        storage: PixelStorageV4,
        sourceWidth: Int,
        sourceHeight: Int,
        windowWidth: Int,
        windowHeight: Int
    ) throws {
        let count = try Self.checkedProduct(windowWidth, windowHeight)
        guard windowWidth > 0,
              windowHeight > 0,
              count <= Self.maximumWindowSampleCount else {
            throw PixelBufferSignalCodecV4Error.invalidWindowGeometry(
                width: windowWidth,
                height: windowHeight
            )
        }
        let retainedCount = try Self.checkedProduct(count, 3)
        let priorIdentity = storageIdentity
        let declaredAllocation = count > reservedWindowSampleCapacity
        if declaredAllocation {
            samples = Array(repeating: 0, count: retainedCount)
            reservedWindowSampleCapacity = count
            storageAllocationCount += 1
        } else if samples.count < retainedCount {
            samples.append(
                contentsOf: repeatElement(
                    0,
                    count: retainedCount - samples.count
                )
            )
        } else if samples.count > retainedCount {
            samples.removeLast(samples.count - retainedCount)
        }
        let nextIdentity = samples.withUnsafeBufferPointer { buffer -> UInt in
            guard let base = buffer.baseAddress else { return 0 }
            return UInt(bitPattern: base)
        }
        if !declaredAllocation,
           priorIdentity != 0,
           nextIdentity != priorIdentity {
            storageAllocationCount += 1
        }
        storageIdentity = nextIdentity
        self.storage = storage
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        self.windowWidth = windowWidth
        self.windowHeight = windowHeight
    }

    fileprivate mutating func finishWrite() {
        let nextIdentity = samples.withUnsafeBufferPointer { buffer -> UInt in
            guard let base = buffer.baseAddress else { return 0 }
            return UInt(bitPattern: base)
        }
        if storageIdentity != 0, nextIdentity != storageIdentity {
            storageAllocationCount += 1
        }
        storageIdentity = nextIdentity
    }

    private static func checkedProduct(_ left: Int, _ right: Int) throws -> Int {
        let result = left.multipliedReportingOverflow(by: right)
        guard !result.overflow else {
            throw PixelBufferSignalCodecV4Error.arithmeticOverflow
        }
        return result.partialValue
    }
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

    /// Decodes only the visible luma samples into reusable tight storage. The
    /// complete active luma plane is range/alignment validated before the
    /// workspace is changed, and the source buffer is never mutated.
    static func readLuma(
        _ buffer: CVPixelBuffer,
        storage: PixelStorageV4,
        into workspace: inout PixelBufferLumaWorkspaceV4
    ) throws {
        try Task.checkCancellation()
        let layout = PixelLayoutV4(storage: storage)
        try layout.validateStructure(of: buffer)
        let planeLayout = layout.planes[0]
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let sampleCount = try checkedProduct(width, height)
        let status = CVPixelBufferLockBaseAddress(buffer, .readOnly)
        guard status == kCVReturnSuccess else {
            throw PixelBufferSignalCodecV4Error.lockFailed(
                destination: false,
                status: status
            )
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else {
            throw PixelBufferSignalCodecV4Error.inaccessiblePlane(0)
        }
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)

        // Validate first so neither an invalid late pixel nor cancellation can
        // leave a caller's reusable workspace partially replaced.
        for y in 0..<height {
            let row = base.advanced(by: try checkedProduct(y, stride))
                .assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                let stored = storedCode(
                    row: row,
                    element: x,
                    bytesPerComponent: planeLayout.bytesPerComponent
                )
                _ = try layout.validateStoredCode(
                    stored,
                    plane: 0,
                    component: 0
                )
            }
        }
        try Task.checkCancellation()
        try workspace.prepare(sampleCount: sampleCount)
        workspace.configure(
            storage: storage,
            width: width,
            height: height,
            bounds: planeLayout.signalCodeBounds[0]
        )
        for y in 0..<height {
            let row = base.advanced(by: y * stride)
                .assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                workspace.samples[y * width + x] = storedCode(
                    row: row,
                    element: x,
                    bytesPerComponent: planeLayout.bytesPerComponent
                ) >> UInt16(planeLayout.storedCodeShift)
            }
        }
        workspace.finishWrite()
    }

    /// Captures luma as independently allocated retained tiles. The pixel
    /// buffer remains locked for one validation/capture pass, but no visible
    /// plane-sized Swift array is ever formed.
    static func readTiledLuma(
        _ buffer: CVPixelBuffer,
        storage: PixelStorageV4,
        frameID: String,
        streamID: String,
        formatIdentity: ASHSHA256V4,
        ordinal: Int64,
        presentationTime: ExactRationalV4,
        cadenceID: String,
        policy: ASHTemporalTilePolicyV4,
        stateForTile: (Int) throws -> ASHState
    ) throws -> ASHTemporalTiledFrameCaptureResultV4 {
        try Task.checkCancellation()
        let layout = PixelLayoutV4(storage: storage)
        try layout.validateStructure(of: buffer)
        let plane = layout.planes[0]
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        _ = try ASHTemporalTileGridV4(
            frameWidth: width,
            frameHeight: height,
            policy: policy
        )
        let status = CVPixelBufferLockBaseAddress(buffer, .readOnly)
        guard status == kCVReturnSuccess else {
            throw PixelBufferSignalCodecV4Error.lockFailed(
                destination: false,
                status: status
            )
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else {
            throw PixelBufferSignalCodecV4Error.inaccessiblePlane(0)
        }
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        for y in 0..<height {
            let row = base.advanced(by: try checkedProduct(y, stride))
                .assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                _ = try layout.validateStoredCode(
                    storedCode(
                        row: row,
                        element: x,
                        bytesPerComponent: plane.bytesPerComponent
                    ),
                    plane: 0,
                    component: 0
                )
            }
        }
        try Task.checkCancellation()
        return try ASHTemporalTiledFrameBuilderV4.capture(
            frameID: frameID,
            streamID: streamID,
            formatIdentity: formatIdentity,
            ordinal: ordinal,
            presentationTime: presentationTime,
            cadenceID: cadenceID,
            frameWidth: width,
            frameHeight: height,
            minimumCode: plane.signalCodeBounds[0].minimum,
            maximumCode: plane.signalCodeBounds[0].maximum,
            policy: policy,
            stateForTile: stateForTile,
            sampleAt: { x, y in
                let row = base.advanced(by: y * stride)
                    .assumingMemoryBound(to: UInt8.self)
                return storedCode(
                    row: row,
                    element: x,
                    bytesPerComponent: plane.bytesPerComponent
                ) >> UInt16(plane.storedCodeShift)
            }
        )
    }

    /// Commits canonical active-tile luma without materializing their union.
    /// Every tile and code is preflighted before the destination lock mutates
    /// its first visible byte.
    static func writeTiledLuma(
        _ outputs: [ASHTemporalTileOutputV4],
        grid: ASHTemporalTileGridV4,
        to buffer: CVPixelBuffer,
        storage: PixelStorageV4
    ) throws {
        try Task.checkCancellation()
        try grid.validate()
        let layout = PixelLayoutV4(storage: storage)
        try layout.validateStructure(of: buffer)
        guard grid.frameWidth == CVPixelBufferGetWidth(buffer),
              grid.frameHeight == CVPixelBufferGetHeight(buffer),
              outputs.count == grid.tileCount else {
            throw PixelBufferSignalCodecV4Error.invalidSignalGeometry(plane: 0)
        }
        let plane = layout.planes[0]
        let bounds = plane.signalCodeBounds[0]
        for (index, output) in outputs.enumerated() {
            let expected = try grid.descriptor(at: index)
            guard output.tileIndex == index,
                  output.active == expected.active,
                  output.samples.count == expected.active.sampleCount,
                  output.samples.allSatisfy({ bounds.contains($0) }) else {
                throw PixelBufferSignalCodecV4Error.invalidSampleCount(
                    plane: 0,
                    expected: expected.active.sampleCount,
                    actual: output.samples.count
                )
            }
        }
        try Task.checkCancellation()
        let status = CVPixelBufferLockBaseAddress(buffer, [])
        guard status == kCVReturnSuccess else {
            throw PixelBufferSignalCodecV4Error.lockFailed(
                destination: true,
                status: status
            )
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else {
            throw PixelBufferSignalCodecV4Error.inaccessiblePlane(0)
        }
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        for output in outputs {
            for localY in 0..<output.active.height {
                let row = base.advanced(
                    by: (output.active.y + localY) * stride
                ).assumingMemoryBound(to: UInt8.self)
                for localX in 0..<output.active.width {
                    let sample = output.samples[
                        localY * output.active.width + localX
                    ]
                    // The complete code range and fixed layout shift were
                    // preflighted above, leaving this commit loop nonthrowing.
                    let stored = sample << UInt16(plane.storedCodeShift)
                    let element = output.active.x + localX
                    if plane.bytesPerComponent == 1 {
                        row[element] = UInt8(stored)
                    } else {
                        let offset = element * 2
                        row[offset] = UInt8(truncatingIfNeeded: stored)
                        row[offset + 1] = UInt8(
                            truncatingIfNeeded: stored >> 8
                        )
                    }
                }
            }
        }
    }

    /// Writes visible luma only. Geometry, every signal code, cancellation,
    /// and the destination base address are checked before the first byte is
    /// changed. Chroma and row-padding bytes are therefore preserved exactly.
    static func writeLuma(
        from workspace: PixelBufferLumaWorkspaceV4,
        to buffer: CVPixelBuffer,
        storage: PixelStorageV4,
        copyAttachmentsFrom source: CVPixelBuffer? = nil
    ) throws {
        guard workspace.storage == storage else {
            throw PixelBufferSignalCodecV4Error.invalidSignalGeometry(plane: 0)
        }
        try writeLuma(
            samples: workspace.samples,
            width: workspace.width,
            height: workspace.height,
            minimumCode: workspace.minimumCode,
            maximumCode: workspace.maximumCode,
            to: buffer,
            storage: storage,
            copyAttachmentsFrom: source
        )
    }

    static func writeLuma(
        _ plane: ASHTemporalPlaneV4,
        to buffer: CVPixelBuffer,
        storage: PixelStorageV4,
        copyAttachmentsFrom source: CVPixelBuffer? = nil
    ) throws {
        try writeLuma(
            samples: plane.samples,
            width: plane.width,
            height: plane.height,
            minimumCode: plane.minimumCode,
            maximumCode: plane.maximumCode,
            to: buffer,
            storage: storage,
            copyAttachmentsFrom: source
        )
    }

    /// Extracts the declared evidence window without constructing full luma or
    /// chroma plane arrays. All active source samples are still validated, so
    /// malformed codes outside the window fail closed exactly like `read`.
    static func readSignalWindow(
        _ buffer: CVPixelBuffer,
        storage: PixelStorageV4,
        windowWidth: Int,
        windowHeight: Int,
        into workspace: inout PixelBufferSignalWindowWorkspaceV4
    ) throws {
        try Task.checkCancellation()
        let layout = PixelLayoutV4(storage: storage)
        try layout.validateStructure(of: buffer)
        let countResult = windowWidth.multipliedReportingOverflow(
            by: windowHeight
        )
        guard windowWidth > 0,
              windowHeight > 0,
              !countResult.overflow,
              countResult.partialValue
                <= PixelBufferSignalWindowWorkspaceV4
                    .maximumWindowSampleCount else {
            throw PixelBufferSignalCodecV4Error.invalidWindowGeometry(
                width: windowWidth,
                height: windowHeight
            )
        }
        let frameWidth = CVPixelBufferGetWidth(buffer)
        let frameHeight = CVPixelBufferGetHeight(buffer)
        let status = CVPixelBufferLockBaseAddress(buffer, .readOnly)
        guard status == kCVReturnSuccess else {
            throw PixelBufferSignalCodecV4Error.lockFailed(
                destination: false,
                status: status
            )
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        guard let lumaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)
        else {
            throw PixelBufferSignalCodecV4Error.inaccessiblePlane(0)
        }
        guard let chromaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)
        else {
            throw PixelBufferSignalCodecV4Error.inaccessiblePlane(1)
        }
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)

        // Match full-frame decoding's failure contract without retaining its
        // arrays: scan every visible sample under the same lock.
        for (planeIndex, plane) in layout.planes.enumerated() {
            let planeWidth = try plane.width(forFrameWidth: frameWidth)
            let planeHeight = try plane.height(forFrameHeight: frameHeight)
            let planeBase = planeIndex == 0 ? lumaBase : chromaBase
            let planeStride = planeIndex == 0 ? lumaStride : chromaStride
            for y in 0..<planeHeight {
                let row = planeBase
                    .advanced(by: try checkedProduct(y, planeStride))
                    .assumingMemoryBound(to: UInt8.self)
                for x in 0..<planeWidth {
                    for component in 0..<plane.componentsPerElement {
                        let element = try checkedSum(
                            try checkedProduct(x, plane.componentsPerElement),
                            component
                        )
                        _ = try layout.validateStoredCode(
                            storedCode(
                                row: row,
                                element: element,
                                bytesPerComponent: plane.bytesPerComponent
                            ),
                            plane: planeIndex,
                            component: component
                        )
                    }
                }
            }
        }
        try Task.checkCancellation()
        try workspace.prepare(
            storage: storage,
            sourceWidth: frameWidth,
            sourceHeight: frameHeight,
            windowWidth: windowWidth,
            windowHeight: windowHeight
        )
        let luma = layout.planes[0]
        let chroma = layout.planes[1]
        let chromaWidth = try chroma.width(forFrameWidth: frameWidth)
        let chromaHeight = try chroma.height(forFrameHeight: frameHeight)
        let count = countResult.partialValue
        for y in 0..<windowHeight {
            let sourceY = min(y, frameHeight - 1)
            let chromaY = min(sourceY / 2, chromaHeight - 1)
            let lumaRow = lumaBase.advanced(by: sourceY * lumaStride)
                .assumingMemoryBound(to: UInt8.self)
            let chromaRow = chromaBase.advanced(by: chromaY * chromaStride)
                .assumingMemoryBound(to: UInt8.self)
            for x in 0..<windowWidth {
                let sourceX = min(x, frameWidth - 1)
                let chromaX = min(sourceX / 2, chromaWidth - 1)
                let index = y * windowWidth + x
                workspace.samples[index] = storedCode(
                    row: lumaRow,
                    element: sourceX,
                    bytesPerComponent: luma.bytesPerComponent
                ) >> UInt16(luma.storedCodeShift)
                let chromaElement = chromaX * 2
                workspace.samples[count + index] = storedCode(
                    row: chromaRow,
                    element: chromaElement,
                    bytesPerComponent: chroma.bytesPerComponent
                ) >> UInt16(chroma.storedCodeShift)
                workspace.samples[count * 2 + index] = storedCode(
                    row: chromaRow,
                    element: chromaElement + 1,
                    bytesPerComponent: chroma.bytesPerComponent
                ) >> UInt16(chroma.storedCodeShift)
            }
        }
        workspace.finishWrite()
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

    private static func storedCode(
        row: UnsafePointer<UInt8>,
        element: Int,
        bytesPerComponent: Int
    ) -> UInt16 {
        if bytesPerComponent == 1 {
            return UInt16(row[element])
        }
        let offset = element * 2
        return UInt16(row[offset]) | UInt16(row[offset + 1]) << 8
    }

    private static func writeLuma(
        samples: [UInt16],
        width: Int,
        height: Int,
        minimumCode: UInt16,
        maximumCode: UInt16,
        to buffer: CVPixelBuffer,
        storage: PixelStorageV4,
        copyAttachmentsFrom source: CVPixelBuffer?
    ) throws {
        try Task.checkCancellation()
        let layout = PixelLayoutV4(storage: storage)
        try layout.validateStructure(of: buffer)
        let plane = layout.planes[0]
        let bounds = plane.signalCodeBounds[0]
        let expectedCount = try checkedProduct(width, height)
        guard width == CVPixelBufferGetWidth(buffer),
              height == CVPixelBufferGetHeight(buffer),
              minimumCode == bounds.minimum,
              maximumCode == bounds.maximum else {
            throw PixelBufferSignalCodecV4Error.invalidSignalGeometry(plane: 0)
        }
        guard samples.count == expectedCount else {
            throw PixelBufferSignalCodecV4Error.invalidSampleCount(
                plane: 0,
                expected: expectedCount,
                actual: samples.count
            )
        }
        for sample in samples {
            guard bounds.contains(sample) else {
                throw PixelLayoutV4Error.signalCodeOutOfRange(
                    plane: 0,
                    component: 0,
                    value: sample,
                    minimum: bounds.minimum,
                    maximum: bounds.maximum
                )
            }
        }
        let status = CVPixelBufferLockBaseAddress(buffer, [])
        guard status == kCVReturnSuccess else {
            throw PixelBufferSignalCodecV4Error.lockFailed(
                destination: true,
                status: status
            )
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else {
            throw PixelBufferSignalCodecV4Error.inaccessiblePlane(0)
        }
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        try Task.checkCancellation()

        // No fallible operation remains beyond this commit boundary.
        for y in 0..<height {
            let row = base.advanced(by: y * stride)
                .assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                let stored = samples[y * width + x]
                    << UInt16(plane.storedCodeShift)
                if plane.bytesPerComponent == 1 {
                    row[x] = UInt8(truncatingIfNeeded: stored)
                } else {
                    let offset = x * 2
                    row[offset] = UInt8(truncatingIfNeeded: stored)
                    row[offset + 1] = UInt8(truncatingIfNeeded: stored >> 8)
                }
            }
        }
        if let source {
            copyAttachments(from: source, to: buffer)
        }
    }
}
