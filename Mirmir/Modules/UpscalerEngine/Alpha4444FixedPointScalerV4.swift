import CoreVideo
import Foundation
import Metal

enum Alpha4444FixedPointScalerV4Error: Error, Equatable, Sendable {
    case sourceAndDestinationAlias
    case pixelFormatMismatch(
        destination: Bool,
        expected: OSType,
        actual: OSType
    )
    case dimensionMismatch(
        destination: Bool,
        expectedWidth: Int,
        expectedHeight: Int,
        actualWidth: Int,
        actualHeight: Int
    )
    case planarBufferUnsupported(destination: Bool)
    case inaccessibleBaseAddress(destination: Bool)
    case invalidRowStride(destination: Bool, minimum: Int, actual: Int)
    case lockFailed(destination: Bool, status: CVReturn)
    case missingAlphaAssociationAttachment
    case alphaAssociationAttachmentMismatch(
        expected: AlphaAssociationV4,
        actual: String
    )
    case geometryAttachmentRequiresMigration(key: String)
    case hiddenColorCannotBePreservedInPremultipliedOutput
    case malformedComponentOutput(expected: Int, actual: Int)
    case arithmeticOverflow
}

enum Alpha4444ExecutionBackendV4: String, Codable, Hashable, Sendable {
    case cpu
    case metal
}

/// Packed, full-range RGB 4:4:4:4 layouts whose channel order and byte order
/// are completely specified by Core Video. Encoded Y'CbCr-alpha layouts are
/// intentionally excluded: they require a separately planned, manifest-bound
/// Y'CbCr-to-RGB transform before `AlphaProcessingV4` is semantically valid.
enum Alpha4444PackedLayoutV4: String, CaseIterable, Codable, Hashable,
    Sendable {
    case argb8
    case bgra8
    case abgr8
    case rgba8
    case argb16BigEndian
    case rgba16LittleEndian

    var pixelFormat: OSType {
        switch self {
        case .argb8:
            return kCVPixelFormatType_32ARGB
        case .bgra8:
            return kCVPixelFormatType_32BGRA
        case .abgr8:
            return kCVPixelFormatType_32ABGR
        case .rgba8:
            return kCVPixelFormatType_32RGBA
        case .argb16BigEndian:
            return kCVPixelFormatType_64ARGB
        case .rgba16LittleEndian:
            return kCVPixelFormatType_64RGBALE
        }
    }

    var signalBitDepth: Int {
        switch self {
        case .argb8, .bgra8, .abgr8, .rgba8:
            return 8
        case .argb16BigEndian, .rgba16LittleEndian:
            return 16
        }
    }

    var bytesPerPixel: Int {
        signalBitDepth == 8 ? 4 : 8
    }

    var componentOffsets: ComponentOffsets {
        switch self {
        case .argb8, .argb16BigEndian:
            return ComponentOffsets(red: 1, green: 2, blue: 3, alpha: 0)
        case .bgra8:
            return ComponentOffsets(red: 2, green: 1, blue: 0, alpha: 3)
        case .abgr8:
            return ComponentOffsets(red: 3, green: 2, blue: 1, alpha: 0)
        case .rgba8, .rgba16LittleEndian:
            return ComponentOffsets(red: 0, green: 1, blue: 2, alpha: 3)
        }
    }

    var byteOrder: ComponentByteOrder {
        switch self {
        case .argb8, .bgra8, .abgr8, .rgba8:
            return .singleByte
        case .argb16BigEndian:
            return .bigEndian16
        case .rgba16LittleEndian:
            return .littleEndian16
        }
    }

    struct ComponentOffsets: Sendable {
        let red: Int
        let green: Int
        let blue: Int
        let alpha: Int
    }

    enum ComponentByteOrder: Sendable {
        case singleByte
        case bigEndian16
        case littleEndian16
    }
}

enum Alpha4444PixelBufferAccessV4Error: Error, Equatable, Sendable {
    case pixelFormatMismatch(expected: OSType, actual: OSType)
    case planarBufferUnsupported
    case invalidRowStride(minimum: Int, actual: Int)
    case inaccessibleBaseAddress
    case lockFailed(CVReturn)
    case sampleCountMismatch(expected: Int, actual: Int)
    case componentOutOfRange(
        component: AlphaComponentV4,
        value: UInt16,
        maximum: UInt16
    )
    case arithmeticOverflow
}

/// Row-padding-independent packed 4:4:4:4 access used at deterministic media
/// boundaries. Alpha-plane fingerprints retain the layout's declared byte
/// order, so an encode/decode verifier detects even a single changed alpha
/// byte without conflating row allocator padding with visible samples.
enum Alpha4444PixelBufferAccessV4 {
    static func alphaPlaneBytes(
        _ buffer: CVPixelBuffer,
        layout: Alpha4444PackedLayoutV4
    ) throws -> Data {
        try validate(buffer, layout: layout)
        let status = CVPixelBufferLockBaseAddress(buffer, .readOnly)
        guard status == kCVReturnSuccess else {
            throw Alpha4444PixelBufferAccessV4Error.lockFailed(status)
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?
            .assumingMemoryBound(to: UInt8.self) else {
            throw Alpha4444PixelBufferAccessV4Error.inaccessibleBaseAddress
        }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let bytesPerComponent = layout.signalBitDepth == 8 ? 1 : 2
        let sampleCount = try checkedProduct(width, height)
        var output = Data()
        output.reserveCapacity(try checkedProduct(sampleCount, bytesPerComponent))
        let alphaOffset = layout.componentOffsets.alpha * bytesPerComponent
        for y in 0..<height {
            let row = base.advanced(by: try checkedProduct(y, rowBytes))
            for x in 0..<width {
                let pixel = row.advanced(
                    by: try checkedProduct(x, layout.bytesPerPixel)
                )
                output.append(pixel[alphaOffset])
                if bytesPerComponent == 2 {
                    output.append(pixel[alphaOffset + 1])
                }
            }
        }
        return output
    }

    static func samples(
        _ buffer: CVPixelBuffer,
        layout: Alpha4444PackedLayoutV4
    ) throws -> [AlphaSampleV4] {
        try validate(buffer, layout: layout)
        let status = CVPixelBufferLockBaseAddress(buffer, .readOnly)
        guard status == kCVReturnSuccess else {
            throw Alpha4444PixelBufferAccessV4Error.lockFailed(status)
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?
            .assumingMemoryBound(to: UInt8.self) else {
            throw Alpha4444PixelBufferAccessV4Error.inaccessibleBaseAddress
        }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        var output: [AlphaSampleV4] = []
        output.reserveCapacity(try checkedProduct(width, height))
        for y in 0..<height {
            let row = base.advanced(by: try checkedProduct(y, rowBytes))
            for x in 0..<width {
                let pixel = row.advanced(
                    by: try checkedProduct(x, layout.bytesPerPixel)
                )
                output.append(AlphaSampleV4(
                    red: read(
                        pixel,
                        component: layout.componentOffsets.red,
                        layout: layout
                    ),
                    green: read(
                        pixel,
                        component: layout.componentOffsets.green,
                        layout: layout
                    ),
                    blue: read(
                        pixel,
                        component: layout.componentOffsets.blue,
                        layout: layout
                    ),
                    alpha: read(
                        pixel,
                        component: layout.componentOffsets.alpha,
                        layout: layout
                    )
                ))
            }
        }
        return output
    }

    static func write(
        _ samples: [AlphaSampleV4],
        to buffer: CVPixelBuffer,
        layout: Alpha4444PackedLayoutV4
    ) throws {
        try validate(buffer, layout: layout)
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let expectedCount = try checkedProduct(width, height)
        guard samples.count == expectedCount else {
            throw Alpha4444PixelBufferAccessV4Error.sampleCountMismatch(
                expected: expectedCount,
                actual: samples.count
            )
        }
        let maximum = layout.signalBitDepth == 8
            ? UInt16(UInt8.max)
            : UInt16.max
        for sample in samples {
            for (component, value) in [
                (AlphaComponentV4.red, sample.red),
                (.green, sample.green),
                (.blue, sample.blue),
                (.alpha, sample.alpha)
            ] where value > maximum {
                throw Alpha4444PixelBufferAccessV4Error.componentOutOfRange(
                    component: component,
                    value: value,
                    maximum: maximum
                )
            }
        }

        let status = CVPixelBufferLockBaseAddress(buffer, [])
        guard status == kCVReturnSuccess else {
            throw Alpha4444PixelBufferAccessV4Error.lockFailed(status)
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?
            .assumingMemoryBound(to: UInt8.self) else {
            throw Alpha4444PixelBufferAccessV4Error.inaccessibleBaseAddress
        }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            let row = base.advanced(by: try checkedProduct(y, rowBytes))
            for x in 0..<width {
                let sample = samples[try checkedSum(
                    try checkedProduct(y, width),
                    x
                )]
                let pixel = row.advanced(
                    by: try checkedProduct(x, layout.bytesPerPixel)
                )
                write(
                    sample.red,
                    to: pixel,
                    component: layout.componentOffsets.red,
                    layout: layout
                )
                write(
                    sample.green,
                    to: pixel,
                    component: layout.componentOffsets.green,
                    layout: layout
                )
                write(
                    sample.blue,
                    to: pixel,
                    component: layout.componentOffsets.blue,
                    layout: layout
                )
                write(
                    sample.alpha,
                    to: pixel,
                    component: layout.componentOffsets.alpha,
                    layout: layout
                )
            }
        }
    }

    private static func validate(
        _ buffer: CVPixelBuffer,
        layout: Alpha4444PackedLayoutV4
    ) throws {
        let actual = CVPixelBufferGetPixelFormatType(buffer)
        guard actual == layout.pixelFormat else {
            throw Alpha4444PixelBufferAccessV4Error.pixelFormatMismatch(
                expected: layout.pixelFormat,
                actual: actual
            )
        }
        guard !CVPixelBufferIsPlanar(buffer) else {
            throw Alpha4444PixelBufferAccessV4Error.planarBufferUnsupported
        }
        let minimum = try checkedProduct(
            CVPixelBufferGetWidth(buffer),
            layout.bytesPerPixel
        )
        let actualStride = CVPixelBufferGetBytesPerRow(buffer)
        guard actualStride >= minimum else {
            throw Alpha4444PixelBufferAccessV4Error.invalidRowStride(
                minimum: minimum,
                actual: actualStride
            )
        }
    }

    private static func read(
        _ pixel: UnsafePointer<UInt8>,
        component: Int,
        layout: Alpha4444PackedLayoutV4
    ) -> UInt16 {
        switch layout.byteOrder {
        case .singleByte:
            return UInt16(pixel[component])
        case .bigEndian16:
            let offset = component * 2
            return (UInt16(pixel[offset]) << 8) | UInt16(pixel[offset + 1])
        case .littleEndian16:
            let offset = component * 2
            return UInt16(pixel[offset]) | (UInt16(pixel[offset + 1]) << 8)
        }
    }

    private static func write(
        _ value: UInt16,
        to pixel: UnsafeMutablePointer<UInt8>,
        component: Int,
        layout: Alpha4444PackedLayoutV4
    ) {
        switch layout.byteOrder {
        case .singleByte:
            pixel[component] = UInt8(truncatingIfNeeded: value)
        case .bigEndian16:
            let offset = component * 2
            pixel[offset] = UInt8(truncatingIfNeeded: value >> 8)
            pixel[offset + 1] = UInt8(truncatingIfNeeded: value)
        case .littleEndian16:
            let offset = component * 2
            pixel[offset] = UInt8(truncatingIfNeeded: value)
            pixel[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        }
    }

    private static func checkedProduct(_ left: Int, _ right: Int) throws -> Int {
        let (value, overflow) = left.multipliedReportingOverflow(by: right)
        guard !overflow else {
            throw Alpha4444PixelBufferAccessV4Error.arithmeticOverflow
        }
        return value
    }

    private static func checkedSum(_ left: Int, _ right: Int) throws -> Int {
        let (value, overflow) = left.addingReportingOverflow(right)
        guard !overflow else {
            throw Alpha4444PixelBufferAccessV4Error.arithmeticOverflow
        }
        return value
    }
}

/// Immutable alpha-aware scale contract. All four straight-domain components
/// consume this one spatial plan and this one canonical fixed-point kernel IR.
struct Alpha4444ScalePlanV4: Equatable, Hashable, Sendable {
    let layout: Alpha4444PackedLayoutV4
    let sourceAssociation: AlphaAssociationV4
    let destinationAssociation: AlphaAssociationV4
    let zeroAlphaPolicy: ZeroAlphaPolicyV4
    let spatialPlan: SpatialScalePlanV4
    let kernelIR: FixedPointKernelIRV4
    let straighteningPlan: AlphaProcessingPlanV4
    let outputAssociationPlan: AlphaProcessingPlanV4

    init(
        layout: Alpha4444PackedLayoutV4,
        sourceAssociation: AlphaAssociationV4,
        destinationAssociation: AlphaAssociationV4,
        zeroAlphaPolicy: ZeroAlphaPolicyV4,
        sourceWidth: Int,
        sourceHeight: Int,
        targetWidth: Int,
        targetHeight: Int,
        borderRule: SpatialBorderRuleV4 = .clamp
    ) throws {
        guard zeroAlphaPolicy != .preserveStraightColor
                || destinationAssociation == .straight else {
            throw Alpha4444FixedPointScalerV4Error
                .hiddenColorCannotBePreservedInPremultipliedOutput
        }
        let spatialPlan = try SpatialScalePlanV4(
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            targetWidth: targetWidth,
            targetHeight: targetHeight,
            borderRule: borderRule
        )
        self.layout = layout
        self.sourceAssociation = sourceAssociation
        self.destinationAssociation = destinationAssociation
        self.zeroAlphaPolicy = zeroAlphaPolicy
        self.spatialPlan = spatialPlan
        self.kernelIR = try FixedPointKernelIRV4(scalePlan: spatialPlan)
        self.straighteningPlan = try AlphaProcessingPlanV4(
            sourceAssociation: sourceAssociation,
            destinationAssociation: .straight,
            zeroAlphaPolicy: zeroAlphaPolicy,
            colorDomain: .fullRangeRGB,
            signalBitDepth: layout.signalBitDepth
        )
        self.outputAssociationPlan = try AlphaProcessingPlanV4(
            sourceAssociation: .straight,
            destinationAssociation: destinationAssociation,
            zeroAlphaPolicy: zeroAlphaPolicy,
            colorDomain: .fullRangeRGB,
            signalBitDepth: layout.signalBitDepth
        )
    }

    var sourceWidth: Int { spatialPlan.sourceWidth }
    var sourceHeight: Int { spatialPlan.sourceHeight }
    var targetWidth: Int { spatialPlan.targetWidth }
    var targetHeight: Int { spatialPlan.targetHeight }
    var fullScale: UInt16 { straighteningPlan.fullScale }
}

/// Exact integer packed-RGBA pixel-buffer scaler.
///
/// Source samples are first resolved into a canonical straight-alpha domain.
/// R, G, B, and A then pass independently through the same Q14/Q28 IR. Only
/// after scaling are output RGB samples associated with the scaled alpha. This
/// ordering prevents premultiplied-edge contamination and makes CPU/Metal
/// output packing byte-identical.
final class Alpha4444FixedPointScalerV4: @unchecked Sendable {
    let backend: Alpha4444ExecutionBackendV4
    let plan: Alpha4444ScalePlanV4

    private let metalExecutor: FixedPointMetalExecutorV4?

    init(
        backend: Alpha4444ExecutionBackendV4,
        plan: Alpha4444ScalePlanV4,
        metalDevice: MTLDevice? = nil,
        metalLibrary: MTLLibrary? = nil
    ) throws {
        self.backend = backend
        self.plan = plan
        switch backend {
        case .cpu:
            self.metalExecutor = nil
        case .metal:
            let device: MTLDevice
            if let metalDevice {
                device = metalDevice
            } else if let systemDevice = MTLCreateSystemDefaultDevice() {
                device = systemDevice
            } else {
                throw FixedPointMetalExecutorV4Error.metalUnavailable
            }
            self.metalExecutor = try FixedPointMetalExecutorV4(
                device: device,
                library: metalLibrary
            )
        }
    }

    convenience init(
        backend: Alpha4444ExecutionBackendV4,
        layout: Alpha4444PackedLayoutV4,
        sourceAssociation: AlphaAssociationV4,
        destinationAssociation: AlphaAssociationV4,
        zeroAlphaPolicy: ZeroAlphaPolicyV4,
        sourceWidth: Int,
        sourceHeight: Int,
        targetWidth: Int,
        targetHeight: Int,
        borderRule: SpatialBorderRuleV4 = .clamp,
        metalDevice: MTLDevice? = nil,
        metalLibrary: MTLLibrary? = nil
    ) throws {
        try self.init(
            backend: backend,
            plan: Alpha4444ScalePlanV4(
                layout: layout,
                sourceAssociation: sourceAssociation,
                destinationAssociation: destinationAssociation,
                zeroAlphaPolicy: zeroAlphaPolicy,
                sourceWidth: sourceWidth,
                sourceHeight: sourceHeight,
                targetWidth: targetWidth,
                targetHeight: targetHeight,
                borderRule: borderRule
            ),
            metalDevice: metalDevice,
            metalLibrary: metalLibrary
        )
    }

    func process(
        source: CVPixelBuffer,
        destination: CVPixelBuffer
    ) async throws {
        guard source !== destination else {
            throw Alpha4444FixedPointScalerV4Error.sourceAndDestinationAlias
        }
        try validate(
            source,
            destination: false,
            width: plan.sourceWidth,
            height: plan.sourceHeight
        )
        try validate(
            destination,
            destination: true,
            width: plan.targetWidth,
            height: plan.targetHeight
        )
        try validateSourceAssociation(source)
        try validateDimensionSensitiveAttachments(source)
        let attachmentSnapshot = AttachmentSnapshot(source: source)
        let straightSource = try extractStraightComponents(from: source)

        async let red = execute(straightSource.red)
        async let green = execute(straightSource.green)
        async let blue = execute(straightSource.blue)
        async let alpha = execute(straightSource.alpha)
        let scaled = Components(
            red: try await red,
            green: try await green,
            blue: try await blue,
            alpha: try await alpha
        )

        try Task.checkCancellation()
        let associated = try associateOutput(scaled)
        try Task.checkCancellation()
        try write(associated, to: destination)
        migrateAttachments(
            attachmentSnapshot,
            to: destination,
            outputIsOpaque: associated.alpha.allSatisfy {
                $0 == plan.fullScale
            }
        )
    }

    private func execute(_ source: [UInt16]) async throws -> [UInt16] {
        switch backend {
        case .cpu:
            return try FixedPointCPUExecutorV4.execute(
                source: source,
                sourceRowStride: plan.sourceWidth,
                scalePlan: plan.spatialPlan,
                kernelIR: plan.kernelIR,
                minimumCode: 0,
                maximumCode: plan.fullScale
            )
        case .metal:
            guard let metalExecutor else {
                throw FixedPointMetalExecutorV4Error.metalUnavailable
            }
            return try await metalExecutor.execute(
                source: source,
                sourceRowStride: plan.sourceWidth,
                scalePlan: plan.spatialPlan,
                kernelIR: plan.kernelIR,
                minimumCode: 0,
                maximumCode: plan.fullScale
            )
        }
    }

    private func validate(
        _ buffer: CVPixelBuffer,
        destination: Bool,
        width: Int,
        height: Int
    ) throws {
        let actualFormat = CVPixelBufferGetPixelFormatType(buffer)
        guard actualFormat == plan.layout.pixelFormat else {
            throw Alpha4444FixedPointScalerV4Error.pixelFormatMismatch(
                destination: destination,
                expected: plan.layout.pixelFormat,
                actual: actualFormat
            )
        }
        let actualWidth = CVPixelBufferGetWidth(buffer)
        let actualHeight = CVPixelBufferGetHeight(buffer)
        guard actualWidth == width, actualHeight == height else {
            throw Alpha4444FixedPointScalerV4Error.dimensionMismatch(
                destination: destination,
                expectedWidth: width,
                expectedHeight: height,
                actualWidth: actualWidth,
                actualHeight: actualHeight
            )
        }
        guard !CVPixelBufferIsPlanar(buffer) else {
            throw Alpha4444FixedPointScalerV4Error
                .planarBufferUnsupported(destination: destination)
        }
        let minimumStride = try checkedProduct(width, plan.layout.bytesPerPixel)
        let actualStride = CVPixelBufferGetBytesPerRow(buffer)
        guard actualStride >= minimumStride else {
            throw Alpha4444FixedPointScalerV4Error.invalidRowStride(
                destination: destination,
                minimum: minimumStride,
                actual: actualStride
            )
        }
    }

    private func validateSourceAssociation(_ source: CVPixelBuffer) throws {
        guard let actual = CVBufferCopyAttachment(
            source,
            kCVImageBufferAlphaChannelModeKey,
            nil
        ) as? String else {
            throw Alpha4444FixedPointScalerV4Error
                .missingAlphaAssociationAttachment
        }
        let expected = alphaAttachmentValue(plan.sourceAssociation) as String
        guard actual == expected else {
            throw Alpha4444FixedPointScalerV4Error
                .alphaAssociationAttachmentMismatch(
                    expected: plan.sourceAssociation,
                    actual: actual
                )
        }
    }

    /// Geometry-bearing attachments cannot be copied byte-for-byte across a
    /// raster-size change. A higher-level exact presentation-geometry planner
    /// must resolve and install them before this alpha-only kernel is used.
    private func validateDimensionSensitiveAttachments(
        _ source: CVPixelBuffer
    ) throws {
        guard plan.sourceWidth != plan.targetWidth
                || plan.sourceHeight != plan.targetHeight else {
            return
        }
        let keys: [CFString] = [
            kCVImageBufferCleanApertureKey,
            kCVImageBufferPreferredCleanApertureKey,
            kCVImageBufferPixelAspectRatioKey,
            kCVImageBufferDisplayDimensionsKey
        ]
        for key in keys where CVBufferCopyAttachment(source, key, nil) != nil {
            throw Alpha4444FixedPointScalerV4Error
                .geometryAttachmentRequiresMigration(key: key as String)
        }
    }

    private func extractStraightComponents(
        from source: CVPixelBuffer
    ) throws -> Components {
        let status = CVPixelBufferLockBaseAddress(source, .readOnly)
        guard status == kCVReturnSuccess else {
            throw Alpha4444FixedPointScalerV4Error.lockFailed(
                destination: false,
                status: status
            )
        }
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(source) else {
            throw Alpha4444FixedPointScalerV4Error
                .inaccessibleBaseAddress(destination: false)
        }

        let count = try checkedProduct(plan.sourceWidth, plan.sourceHeight)
        var components = Components(reservingCapacity: count)
        let rowStride = CVPixelBufferGetBytesPerRow(source)
        let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
        for y in 0..<plan.sourceHeight {
            let row = bytes.advanced(by: try checkedProduct(y, rowStride))
            for x in 0..<plan.sourceWidth {
                let pixel = row.advanced(
                    by: try checkedProduct(x, plan.layout.bytesPerPixel)
                )
                let raw = AlphaSampleV4(
                    red: readComponent(
                        pixel,
                        component: plan.layout.componentOffsets.red
                    ),
                    green: readComponent(
                        pixel,
                        component: plan.layout.componentOffsets.green
                    ),
                    blue: readComponent(
                        pixel,
                        component: plan.layout.componentOffsets.blue
                    ),
                    alpha: readComponent(
                        pixel,
                        component: plan.layout.componentOffsets.alpha
                    )
                )
                components.append(
                    try AlphaProcessingV4.process(
                        raw,
                        using: plan.straighteningPlan
                    )
                )
            }
        }
        return components
    }

    private func associateOutput(_ components: Components) throws -> Components {
        let expected = try checkedProduct(plan.targetWidth, plan.targetHeight)
        try components.validateCount(expected)
        var output = Components(reservingCapacity: expected)
        for index in 0..<expected {
            output.append(
                try AlphaProcessingV4.process(
                    AlphaSampleV4(
                        red: components.red[index],
                        green: components.green[index],
                        blue: components.blue[index],
                        alpha: components.alpha[index]
                    ),
                    using: plan.outputAssociationPlan
                )
            )
        }
        return output
    }

    private func write(
        _ components: Components,
        to destination: CVPixelBuffer
    ) throws {
        let expected = try checkedProduct(plan.targetWidth, plan.targetHeight)
        try components.validateCount(expected)
        let status = CVPixelBufferLockBaseAddress(destination, [])
        guard status == kCVReturnSuccess else {
            throw Alpha4444FixedPointScalerV4Error.lockFailed(
                destination: true,
                status: status
            )
        }
        defer { CVPixelBufferUnlockBaseAddress(destination, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(destination) else {
            throw Alpha4444FixedPointScalerV4Error
                .inaccessibleBaseAddress(destination: true)
        }

        let rowStride = CVPixelBufferGetBytesPerRow(destination)
        let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
        for y in 0..<plan.targetHeight {
            let row = bytes.advanced(by: try checkedProduct(y, rowStride))
            for x in 0..<plan.targetWidth {
                let index = try checkedSum(
                    try checkedProduct(y, plan.targetWidth),
                    x
                )
                let pixel = row.advanced(
                    by: try checkedProduct(x, plan.layout.bytesPerPixel)
                )
                writeComponent(
                    components.red[index],
                    to: pixel,
                    component: plan.layout.componentOffsets.red
                )
                writeComponent(
                    components.green[index],
                    to: pixel,
                    component: plan.layout.componentOffsets.green
                )
                writeComponent(
                    components.blue[index],
                    to: pixel,
                    component: plan.layout.componentOffsets.blue
                )
                writeComponent(
                    components.alpha[index],
                    to: pixel,
                    component: plan.layout.componentOffsets.alpha
                )
            }
        }
    }

    private func readComponent(
        _ pixel: UnsafePointer<UInt8>,
        component: Int
    ) -> UInt16 {
        switch plan.layout.byteOrder {
        case .singleByte:
            return UInt16(pixel[component])
        case .bigEndian16:
            let offset = component * 2
            return (UInt16(pixel[offset]) << 8) | UInt16(pixel[offset + 1])
        case .littleEndian16:
            let offset = component * 2
            return UInt16(pixel[offset]) | (UInt16(pixel[offset + 1]) << 8)
        }
    }

    private func writeComponent(
        _ value: UInt16,
        to pixel: UnsafeMutablePointer<UInt8>,
        component: Int
    ) {
        switch plan.layout.byteOrder {
        case .singleByte:
            pixel[component] = UInt8(truncatingIfNeeded: value)
        case .bigEndian16:
            let offset = component * 2
            pixel[offset] = UInt8(truncatingIfNeeded: value >> 8)
            pixel[offset + 1] = UInt8(truncatingIfNeeded: value)
        case .littleEndian16:
            let offset = component * 2
            pixel[offset] = UInt8(truncatingIfNeeded: value)
            pixel[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        }
    }

    private func migrateAttachments(
        _ snapshot: AttachmentSnapshot,
        to destination: CVPixelBuffer,
        outputIsOpaque: Bool
    ) {
        CVBufferRemoveAllAttachments(destination)
        if let propagated = snapshot.propagated {
            CVBufferSetAttachments(
                destination,
                propagated,
                .shouldPropagate
            )
        }
        if let local = snapshot.local {
            CVBufferSetAttachments(
                destination,
                local,
                .shouldNotPropagate
            )
        }
        CVBufferRemoveAttachment(
            destination,
            kCVImageBufferAlphaChannelModeKey
        )
        CVBufferSetAttachment(
            destination,
            kCVImageBufferAlphaChannelModeKey,
            alphaAttachmentValue(plan.destinationAssociation),
            .shouldPropagate
        )
        CVBufferRemoveAttachment(
            destination,
            kCVImageBufferAlphaChannelIsOpaque
        )
        if outputIsOpaque {
            CVBufferSetAttachment(
                destination,
                kCVImageBufferAlphaChannelIsOpaque,
                kCFBooleanTrue,
                .shouldPropagate
            )
        }
    }

    private func alphaAttachmentValue(
        _ association: AlphaAssociationV4
    ) -> CFString {
        switch association {
        case .straight:
            return kCVImageBufferAlphaChannelMode_StraightAlpha
        case .premultiplied:
            return kCVImageBufferAlphaChannelMode_PremultipliedAlpha
        }
    }

    private func checkedProduct(_ left: Int, _ right: Int) throws -> Int {
        let (result, overflow) = left.multipliedReportingOverflow(by: right)
        guard !overflow else {
            throw Alpha4444FixedPointScalerV4Error.arithmeticOverflow
        }
        return result
    }

    private func checkedSum(_ left: Int, _ right: Int) throws -> Int {
        let (result, overflow) = left.addingReportingOverflow(right)
        guard !overflow else {
            throw Alpha4444FixedPointScalerV4Error.arithmeticOverflow
        }
        return result
    }
}

enum PreparedAlpha4444UpscalerV4Error: Error, Equatable, Sendable {
    case alreadyFinished
    case negativeFrameIndex(Int)
    case nonContiguousFrameIndex(expected: Int, actual: Int)
    case invalidPresentationTime(frameIndex: Int)
    case invalidDuration(frameIndex: Int)
    case frameIndexOverflow
    case invalidDestinationCount(expected: Int, actual: Int)
    case checkpointStateUnavailable
    case checkpointIdentityMismatch
    case checkpointStateMismatch
}

private struct PreparedAlpha4444PlanIdentityV4: Codable, Sendable {
    let layout: Alpha4444PackedLayoutV4
    let sourceAssociation: AlphaAssociationV4
    let destinationAssociation: AlphaAssociationV4
    let zeroAlphaPolicy: ZeroAlphaPolicyV4
    let spatialPlan: SpatialScalePlanV4
}

private struct PreparedAlpha4444CheckpointV4: Codable, Sendable {
    static let currentSchemaID = "ash.alpha4444-temporal-checkpoint.v4.1"

    let schemaID: String
    let planSHA256: ASHSHA256V4
    let alphaPlanSHA256: ASHSHA256V4
    let backendID: UpscaleBackendID
    let lastCompletedInputOrdinal: Int64
    let nextFrameIndex: Int
}

/// Stateful `PreparedFrameUpscaler` boundary for packed alpha media.
///
/// The actor serializes access to the shared fixed-point executor, enforces a
/// contiguous causal frame order, and advertises only the source/destination
/// layouts accepted by the alpha kernel. This lets the whole-asset migrator
/// use the same bounded pixel-buffer-pool path as NV12/P010 without an
/// unconditional Core Image or RGB bridge.
actor PreparedAlpha4444UpscalerV4:
    PreparedCheckpointableTemporalFrameUpscaler {
    nonisolated let sourcePixelBufferAttributes: PixelBufferAttributes
    nonisolated let destinationPixelBufferAttributes: PixelBufferAttributes
    nonisolated let actualBackendID: UpscaleBackendID
    nonisolated let plan: Alpha4444ScalePlanV4
    nonisolated let maximumOutputFramesPerInput = 1

    private let scaler: Alpha4444FixedPointScalerV4
    private let alphaPlanSHA256: ASHSHA256V4
    private var nextFrameIndex: Int?
    private var finished = false

    init(
        backend: Alpha4444ExecutionBackendV4,
        plan: Alpha4444ScalePlanV4,
        metalDevice: MTLDevice? = nil,
        metalLibrary: MTLLibrary? = nil
    ) throws {
        self.plan = plan
        self.sourcePixelBufferAttributes = Self.attributes(
            layout: plan.layout,
            width: plan.sourceWidth,
            height: plan.sourceHeight
        )
        self.destinationPixelBufferAttributes = Self.attributes(
            layout: plan.layout,
            width: plan.targetWidth,
            height: plan.targetHeight
        )
        self.actualBackendID = backend == .cpu
            ? .mirmirDeterministicCPU
            : .mirmirDeterministicMetal
        self.alphaPlanSHA256 = try Self.planIdentitySHA256(plan)
        self.scaler = try Alpha4444FixedPointScalerV4(
            backend: backend,
            plan: plan,
            metalDevice: metalDevice,
            metalLibrary: metalLibrary
        )
    }

    init(
        backend: Alpha4444ExecutionBackendV4,
        layout: Alpha4444PackedLayoutV4,
        sourceAssociation: AlphaAssociationV4,
        destinationAssociation: AlphaAssociationV4,
        zeroAlphaPolicy: ZeroAlphaPolicyV4,
        sourceWidth: Int,
        sourceHeight: Int,
        targetWidth: Int,
        targetHeight: Int,
        borderRule: SpatialBorderRuleV4 = .clamp,
        metalDevice: MTLDevice? = nil,
        metalLibrary: MTLLibrary? = nil
    ) throws {
        let plan = try Alpha4444ScalePlanV4(
            layout: layout,
            sourceAssociation: sourceAssociation,
            destinationAssociation: destinationAssociation,
            zeroAlphaPolicy: zeroAlphaPolicy,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            targetWidth: targetWidth,
            targetHeight: targetHeight,
            borderRule: borderRule
        )
        self.plan = plan
        self.sourcePixelBufferAttributes = Self.attributes(
            layout: plan.layout,
            width: plan.sourceWidth,
            height: plan.sourceHeight
        )
        self.destinationPixelBufferAttributes = Self.attributes(
            layout: plan.layout,
            width: plan.targetWidth,
            height: plan.targetHeight
        )
        self.actualBackendID = backend == .cpu
            ? .mirmirDeterministicCPU
            : .mirmirDeterministicMetal
        self.alphaPlanSHA256 = try Self.planIdentitySHA256(plan)
        self.scaler = try Alpha4444FixedPointScalerV4(
            backend: backend,
            plan: plan,
            metalDevice: metalDevice,
            metalLibrary: metalLibrary
        )
    }

    func process(
        source: FramePixelBuffer,
        destination: FramePixelBuffer,
        timing: FrameTiming
    ) async throws {
        guard !finished else {
            throw PreparedAlpha4444UpscalerV4Error.alreadyFinished
        }
        guard timing.frameIndex >= 0 else {
            throw PreparedAlpha4444UpscalerV4Error.negativeFrameIndex(
                timing.frameIndex
            )
        }
        if let nextFrameIndex, timing.frameIndex != nextFrameIndex {
            throw PreparedAlpha4444UpscalerV4Error.nonContiguousFrameIndex(
                expected: nextFrameIndex,
                actual: timing.frameIndex
            )
        }
        guard timing.presentationTime.isNumeric,
              timing.presentationTime.epoch == 0 else {
            throw PreparedAlpha4444UpscalerV4Error.invalidPresentationTime(
                frameIndex: timing.frameIndex
            )
        }
        guard timing.duration.isNumeric,
              timing.duration.value > 0,
              timing.duration.epoch == 0 else {
            throw PreparedAlpha4444UpscalerV4Error.invalidDuration(
                frameIndex: timing.frameIndex
            )
        }
        try Task.checkCancellation()
        try await scaler.process(
            source: source.value,
            destination: destination.value
        )
        try Task.checkCancellation()
        let (following, overflow) = timing.frameIndex.addingReportingOverflow(1)
        guard !overflow else {
            throw PreparedAlpha4444UpscalerV4Error.frameIndexOverflow
        }
        nextFrameIndex = following
    }

    func finish() async throws {
        guard !finished else { return }
        try Task.checkCancellation()
        finished = true
    }

    func processTemporal(
        source: FramePixelBuffer,
        destinations: [FramePixelBuffer],
        timing: FrameTiming
    ) async throws -> [TemporalOutputFrame] {
        guard destinations.count == maximumOutputFramesPerInput else {
            throw PreparedAlpha4444UpscalerV4Error.invalidDestinationCount(
                expected: maximumOutputFramesPerInput,
                actual: destinations.count
            )
        }
        try await process(
            source: source,
            destination: destinations[0],
            timing: timing
        )
        return [TemporalOutputFrame(
            pixelBuffer: destinations[0],
            presentationTime: timing.presentationTime
        )]
    }

    func makeTemporalCheckpoint(
        planSHA256: ASHSHA256V4,
        lastCompletedInputOrdinal: Int64
    ) async throws -> Data {
        guard !finished, let nextFrameIndex else {
            throw PreparedAlpha4444UpscalerV4Error
                .checkpointStateUnavailable
        }
        guard lastCompletedInputOrdinal >= 0,
              Int64(nextFrameIndex) == lastCompletedInputOrdinal + 1 else {
            throw PreparedAlpha4444UpscalerV4Error.checkpointStateMismatch
        }
        return try ASHCanonicalJSONV4.encode(
            PreparedAlpha4444CheckpointV4(
                schemaID: PreparedAlpha4444CheckpointV4.currentSchemaID,
                planSHA256: planSHA256,
                alphaPlanSHA256: alphaPlanSHA256,
                backendID: actualBackendID,
                lastCompletedInputOrdinal: lastCompletedInputOrdinal,
                nextFrameIndex: nextFrameIndex
            )
        )
    }

    func restoreTemporalCheckpoint(
        _ data: Data,
        planSHA256: ASHSHA256V4
    ) async throws {
        guard !finished else {
            throw PreparedAlpha4444UpscalerV4Error.alreadyFinished
        }
        let checkpoint = try ASHCanonicalJSONV4.decode(
            PreparedAlpha4444CheckpointV4.self,
            from: data
        )
        guard checkpoint.schemaID
                == PreparedAlpha4444CheckpointV4.currentSchemaID,
              checkpoint.planSHA256 == planSHA256,
              checkpoint.alphaPlanSHA256 == alphaPlanSHA256,
              checkpoint.backendID == actualBackendID else {
            throw PreparedAlpha4444UpscalerV4Error
                .checkpointIdentityMismatch
        }
        guard checkpoint.lastCompletedInputOrdinal >= 0,
              checkpoint.nextFrameIndex > 0,
              Int64(checkpoint.nextFrameIndex)
                == checkpoint.lastCompletedInputOrdinal + 1 else {
            throw PreparedAlpha4444UpscalerV4Error.checkpointStateMismatch
        }
        nextFrameIndex = checkpoint.nextFrameIndex
    }

    private nonisolated static func attributes(
        layout: Alpha4444PackedLayoutV4,
        width: Int,
        height: Int
    ) -> PixelBufferAttributes {
        PixelBufferAttributes([
            kCVPixelBufferPixelFormatTypeKey as String:
                NSNumber(value: layout.pixelFormat),
            kCVPixelBufferWidthKey as String: NSNumber(value: width),
            kCVPixelBufferHeightKey as String: NSNumber(value: height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ])
    }

    private nonisolated static func planIdentitySHA256(
        _ plan: Alpha4444ScalePlanV4
    ) throws -> ASHSHA256V4 {
        try ASHCanonicalJSONV4.hash(
            PreparedAlpha4444PlanIdentityV4(
                layout: plan.layout,
                sourceAssociation: plan.sourceAssociation,
                destinationAssociation: plan.destinationAssociation,
                zeroAlphaPolicy: plan.zeroAlphaPolicy,
                spatialPlan: plan.spatialPlan
            ),
            domain: "ash-alpha4444-plan-identity-v4"
        )
    }
}

private struct Alpha4444ComponentsV4: Sendable {
    var red: [UInt16]
    var green: [UInt16]
    var blue: [UInt16]
    var alpha: [UInt16]

    init(
        red: [UInt16],
        green: [UInt16],
        blue: [UInt16],
        alpha: [UInt16]
    ) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(reservingCapacity count: Int) {
        red = []
        green = []
        blue = []
        alpha = []
        red.reserveCapacity(count)
        green.reserveCapacity(count)
        blue.reserveCapacity(count)
        alpha.reserveCapacity(count)
    }

    mutating func append(_ sample: AlphaSampleV4) {
        red.append(sample.red)
        green.append(sample.green)
        blue.append(sample.blue)
        alpha.append(sample.alpha)
    }

    func validateCount(_ expected: Int) throws {
        for values in [red, green, blue, alpha] where values.count != expected {
            throw Alpha4444FixedPointScalerV4Error.malformedComponentOutput(
                expected: expected,
                actual: values.count
            )
        }
    }
}

private extension Alpha4444FixedPointScalerV4 {
    typealias Components = Alpha4444ComponentsV4

    struct AttachmentSnapshot: @unchecked Sendable {
        let propagated: CFDictionary?
        let local: CFDictionary?

        init(source: CVPixelBuffer) {
            propagated = CVBufferCopyAttachments(source, .shouldPropagate)
            local = CVBufferCopyAttachments(source, .shouldNotPropagate)
        }
    }
}
