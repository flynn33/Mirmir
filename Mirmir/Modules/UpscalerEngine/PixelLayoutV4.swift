import CoreVideo
import Foundation

enum PixelLayoutV4Error: Error, Equatable, Sendable {
    case unsupportedPixelFormat(OSType)
    case invalidGeometry(
        width: Int,
        height: Int,
        requiredWidthMultiple: Int,
        requiredHeightMultiple: Int
    )
    case pixelFormatMismatch(expected: OSType, actual: OSType)
    case planeCountMismatch(expected: Int, actual: Int)
    case planeGeometryMismatch(
        plane: Int,
        expectedWidth: Int,
        expectedHeight: Int,
        actualWidth: Int,
        actualHeight: Int
    )
    case rowBytesTooSmall(plane: Int, expected: Int, actual: Int)
    case invalidPlaneIndex(Int)
    case invalidComponentIndex(plane: Int, component: Int)
    case invalidStoredCodeAlignment(
        plane: Int,
        component: Int,
        value: UInt16,
        requiredZeroLowBits: Int
    )
    case signalCodeOutOfRange(
        plane: Int,
        component: Int,
        value: UInt16,
        minimum: UInt16,
        maximum: UInt16
    )
    case arithmeticOverflow
}

enum PixelStorageV4: String, CaseIterable, Hashable, Sendable {
    case nv12VideoRange8Bit = "nv12_video_range_8_bit"
    case nv12FullRange8Bit = "nv12_full_range_8_bit"
    case p010VideoRange10Bit = "p010_video_range_10_bit"
    case p010FullRange10Bit = "p010_full_range_10_bit"

    var pixelFormat: OSType {
        switch self {
        case .nv12VideoRange8Bit:
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        case .nv12FullRange8Bit:
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        case .p010VideoRange10Bit:
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        case .p010FullRange10Bit:
            kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        }
    }

    var codeRange: PixelCodeRangeV4 {
        switch self {
        case .nv12VideoRange8Bit, .p010VideoRange10Bit:
            .video
        case .nv12FullRange8Bit, .p010FullRange10Bit:
            .full
        }
    }

    var signalBitDepth: Int {
        switch self {
        case .nv12VideoRange8Bit, .nv12FullRange8Bit:
            8
        case .p010VideoRange10Bit, .p010FullRange10Bit:
            10
        }
    }

    var storageBitDepth: Int {
        switch self {
        case .nv12VideoRange8Bit, .nv12FullRange8Bit:
            8
        case .p010VideoRange10Bit, .p010FullRange10Bit:
            16
        }
    }

    var storedCodeShift: Int {
        switch self {
        case .nv12VideoRange8Bit, .nv12FullRange8Bit:
            0
        case .p010VideoRange10Bit, .p010FullRange10Bit:
            6
        }
    }

    var bytesPerComponent: Int {
        storageBitDepth / 8
    }
}

enum PixelCodeRangeV4: String, Hashable, Sendable {
    case video
    case full
}

enum PixelPlaneRoleV4: String, Hashable, Sendable {
    case luma
    case interleavedChroma
}

enum PixelComponentRoleV4: String, Hashable, Sendable {
    case luma
    case cb
    case cr
}

enum PixelElementByteOrderV4: String, Hashable, Sendable {
    case scalar8
    case littleEndianUInt16
}

struct PixelCodeBoundsV4: Equatable, Hashable, Sendable {
    let minimum: UInt16
    let maximum: UInt16

    fileprivate init(minimum: UInt16, maximum: UInt16) {
        self.minimum = minimum
        self.maximum = maximum
    }

    func contains(_ value: UInt16) -> Bool {
        (minimum...maximum).contains(value)
    }
}

struct PixelPlaneLayoutV4: Equatable, Hashable, Sendable {
    let role: PixelPlaneRoleV4
    let widthDivisor: Int
    let heightDivisor: Int
    let componentsPerElement: Int
    let bytesPerComponent: Int
    let storedCodeShift: Int
    let componentRoles: [PixelComponentRoleV4]
    let signalCodeBounds: [PixelCodeBoundsV4]
    let elementByteOrder: PixelElementByteOrderV4

    func width(forFrameWidth width: Int) throws -> Int {
        try ceilDivide(width, by: widthDivisor)
    }

    func height(forFrameHeight height: Int) throws -> Int {
        try ceilDivide(height, by: heightDivisor)
    }

    func activeBytesPerRow(frameWidth: Int) throws -> Int {
        let planeWidth = try width(
            forFrameWidth: frameWidth
        )
        let (componentCount, componentOverflow) = planeWidth
            .multipliedReportingOverflow(by: componentsPerElement)
        let (byteCount, byteOverflow) = componentCount
            .multipliedReportingOverflow(by: bytesPerComponent)
        guard !componentOverflow, !byteOverflow else {
            throw PixelLayoutV4Error.arithmeticOverflow
        }
        return byteCount
    }

    func activeByteCount(frameWidth: Int, frameHeight: Int) throws -> Int {
        let rowBytes = try activeBytesPerRow(frameWidth: frameWidth)
        let planeHeight = try height(forFrameHeight: frameHeight)
        let (byteCount, overflow) = rowBytes.multipliedReportingOverflow(
            by: planeHeight
        )
        guard !overflow else {
            throw PixelLayoutV4Error.arithmeticOverflow
        }
        return byteCount
    }

    private func ceilDivide(_ value: Int, by divisor: Int) throws -> Int {
        guard value >= 0, divisor > 0 else {
            throw PixelLayoutV4Error.arithmeticOverflow
        }
        let quotient = value / divisor
        guard !value.isMultiple(of: divisor) else {
            return quotient
        }
        let (result, overflow) = quotient.addingReportingOverflow(1)
        guard !overflow else {
            throw PixelLayoutV4Error.arithmeticOverflow
        }
        return result
    }
}

/// Closed, deterministic layout contract for the two native 4:2:0 storage
/// families supported by the first V4 media milestone.
struct PixelLayoutV4: Equatable, Hashable, Sendable {
    let storage: PixelStorageV4
    let pixelFormat: OSType
    let codeRange: PixelCodeRangeV4
    let signalBitDepth: Int
    let storageBitDepth: Int
    let storedCodeShift: Int
    let requiredWidthMultiple: Int
    let requiredHeightMultiple: Int
    let planes: [PixelPlaneLayoutV4]

    var expectedCoreVideoPlaneCount: Int {
        planes.count
    }

    static let canonicalSupportedPixelFormats: [OSType] =
        PixelStorageV4.allCases.map(\.pixelFormat)

    static let supportedPixelFormats: Set<OSType> = Set(
        canonicalSupportedPixelFormats
    )

    init(storage: PixelStorageV4) {
        let lumaBounds: PixelCodeBoundsV4
        let chromaBounds: PixelCodeBoundsV4
        switch storage {
        case .nv12VideoRange8Bit:
            lumaBounds = PixelCodeBoundsV4(minimum: 16, maximum: 235)
            chromaBounds = PixelCodeBoundsV4(minimum: 16, maximum: 240)
        case .nv12FullRange8Bit:
            lumaBounds = PixelCodeBoundsV4(minimum: 0, maximum: 255)
            chromaBounds = PixelCodeBoundsV4(minimum: 1, maximum: 255)
        case .p010VideoRange10Bit:
            lumaBounds = PixelCodeBoundsV4(minimum: 64, maximum: 940)
            chromaBounds = PixelCodeBoundsV4(minimum: 64, maximum: 960)
        case .p010FullRange10Bit:
            lumaBounds = PixelCodeBoundsV4(minimum: 0, maximum: 1_023)
            chromaBounds = PixelCodeBoundsV4(minimum: 0, maximum: 1_023)
        }

        let componentBytes = storage.bytesPerComponent
        let shift = storage.storedCodeShift
        self.storage = storage
        self.pixelFormat = storage.pixelFormat
        self.codeRange = storage.codeRange
        self.signalBitDepth = storage.signalBitDepth
        self.storageBitDepth = storage.storageBitDepth
        self.storedCodeShift = shift
        self.requiredWidthMultiple = 1
        self.requiredHeightMultiple = 1
        self.planes = [
            PixelPlaneLayoutV4(
                role: .luma,
                widthDivisor: 1,
                heightDivisor: 1,
                componentsPerElement: 1,
                bytesPerComponent: componentBytes,
                storedCodeShift: shift,
                componentRoles: [.luma],
                signalCodeBounds: [lumaBounds],
                elementByteOrder: componentBytes == 1
                    ? .scalar8
                    : .littleEndianUInt16
            ),
            PixelPlaneLayoutV4(
                role: .interleavedChroma,
                widthDivisor: 2,
                heightDivisor: 2,
                componentsPerElement: 2,
                bytesPerComponent: componentBytes,
                storedCodeShift: shift,
                componentRoles: [.cb, .cr],
                signalCodeBounds: [chromaBounds, chromaBounds],
                elementByteOrder: componentBytes == 1
                    ? .scalar8
                    : .littleEndianUInt16
            )
        ]
    }

    init(pixelFormat: OSType) throws {
        let storage: PixelStorageV4
        switch pixelFormat {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            storage = .nv12VideoRange8Bit
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            storage = .nv12FullRange8Bit
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
            storage = .p010VideoRange10Bit
        case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
            storage = .p010FullRange10Bit
        default:
            throw PixelLayoutV4Error.unsupportedPixelFormat(pixelFormat)
        }
        self.init(storage: storage)
    }

    func validateGeometry(width: Int, height: Int) throws {
        guard width > 0,
              height > 0,
              width.isMultiple(of: requiredWidthMultiple),
              height.isMultiple(of: requiredHeightMultiple) else {
            throw PixelLayoutV4Error.invalidGeometry(
                width: width,
                height: height,
                requiredWidthMultiple: requiredWidthMultiple,
                requiredHeightMultiple: requiredHeightMultiple
            )
        }
    }

    func plane(at index: Int) throws -> PixelPlaneLayoutV4 {
        guard planes.indices.contains(index) else {
            throw PixelLayoutV4Error.invalidPlaneIndex(index)
        }
        return planes[index]
    }

    func signalBounds(
        plane planeIndex: Int,
        component componentIndex: Int
    ) throws -> PixelCodeBoundsV4 {
        let plane = try plane(at: planeIndex)
        guard plane.signalCodeBounds.indices.contains(componentIndex) else {
            throw PixelLayoutV4Error.invalidComponentIndex(
                plane: planeIndex,
                component: componentIndex
            )
        }
        return plane.signalCodeBounds[componentIndex]
    }

    func storedBounds(
        plane planeIndex: Int,
        component componentIndex: Int
    ) throws -> PixelCodeBoundsV4 {
        let bounds = try signalBounds(
            plane: planeIndex,
            component: componentIndex
        )
        let plane = try plane(at: planeIndex)
        return PixelCodeBoundsV4(
            minimum: try shifted(bounds.minimum, by: plane.storedCodeShift),
            maximum: try shifted(bounds.maximum, by: plane.storedCodeShift)
        )
    }

    @discardableResult
    func validateStoredCode(
        _ value: UInt16,
        plane planeIndex: Int,
        component componentIndex: Int
    ) throws -> UInt16 {
        let plane = try plane(at: planeIndex)
        let bounds = try signalBounds(
            plane: planeIndex,
            component: componentIndex
        )
        if plane.storedCodeShift > 0 {
            let alignmentMask = UInt16((1 << plane.storedCodeShift) - 1)
            guard value & alignmentMask == 0 else {
                throw PixelLayoutV4Error.invalidStoredCodeAlignment(
                    plane: planeIndex,
                    component: componentIndex,
                    value: value,
                    requiredZeroLowBits: plane.storedCodeShift
                )
            }
        }
        let signalCode = value >> UInt16(plane.storedCodeShift)
        guard bounds.contains(signalCode) else {
            throw PixelLayoutV4Error.signalCodeOutOfRange(
                plane: planeIndex,
                component: componentIndex,
                value: signalCode,
                minimum: bounds.minimum,
                maximum: bounds.maximum
            )
        }
        return signalCode
    }

    func storedCode(
        forSignalCode value: UInt16,
        plane planeIndex: Int,
        component componentIndex: Int
    ) throws -> UInt16 {
        let plane = try plane(at: planeIndex)
        let bounds = try signalBounds(
            plane: planeIndex,
            component: componentIndex
        )
        guard bounds.contains(value) else {
            throw PixelLayoutV4Error.signalCodeOutOfRange(
                plane: planeIndex,
                component: componentIndex,
                value: value,
                minimum: bounds.minimum,
                maximum: bounds.maximum
            )
        }
        return try shifted(value, by: plane.storedCodeShift)
    }

    func activePlaneByteCounts(width: Int, height: Int) throws -> [Int] {
        try validateGeometry(width: width, height: height)
        return try planes.map {
            try $0.activeByteCount(frameWidth: width, frameHeight: height)
        }
    }

    func validateStructure(of pixelBuffer: CVPixelBuffer) throws {
        let actualFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard actualFormat == pixelFormat else {
            throw PixelLayoutV4Error.pixelFormatMismatch(
                expected: pixelFormat,
                actual: actualFormat
            )
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        try validateGeometry(width: width, height: height)

        let actualPlaneCount = CVPixelBufferGetPlaneCount(pixelBuffer)
        guard actualPlaneCount == expectedCoreVideoPlaneCount else {
            throw PixelLayoutV4Error.planeCountMismatch(
                expected: expectedCoreVideoPlaneCount,
                actual: actualPlaneCount
            )
        }

        for (index, plane) in planes.enumerated() {
            let expectedWidth = try plane.width(forFrameWidth: width)
            let expectedHeight = try plane.height(forFrameHeight: height)
            let actualWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, index)
            let actualHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, index)
            guard expectedWidth == actualWidth,
                  expectedHeight == actualHeight else {
                throw PixelLayoutV4Error.planeGeometryMismatch(
                    plane: index,
                    expectedWidth: expectedWidth,
                    expectedHeight: expectedHeight,
                    actualWidth: actualWidth,
                    actualHeight: actualHeight
                )
            }

            let expectedRowBytes = try plane.activeBytesPerRow(
                frameWidth: width
            )
            let actualRowBytes = CVPixelBufferGetBytesPerRowOfPlane(
                pixelBuffer,
                index
            )
            guard actualRowBytes >= expectedRowBytes else {
                throw PixelLayoutV4Error.rowBytesTooSmall(
                    plane: index,
                    expected: expectedRowBytes,
                    actual: actualRowBytes
                )
            }
        }
    }

    private func shifted(_ value: UInt16, by shift: Int) throws -> UInt16 {
        let result = UInt32(value) << UInt32(shift)
        guard result <= UInt32(UInt16.max) else {
            throw PixelLayoutV4Error.arithmeticOverflow
        }
        return UInt16(result)
    }
}
