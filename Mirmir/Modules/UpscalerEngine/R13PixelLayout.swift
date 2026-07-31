import CoreVideo
import Foundation

enum R13PixelLayoutError: Error, Equatable, Sendable {
    case unsupportedPixelFormat(OSType)
    case invalidGeometry(width: Int, height: Int)
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
    case inaccessiblePlane(Int)
    case lockFailed(destination: Bool, status: CVReturn)
    case scalingFailed(plane: Int, status: Int)
    case invalidPhase(Float)
    case planePayloadCountMismatch(expected: Int, actual: Int)
    case planePayloadByteCountMismatch(
        plane: Int,
        expected: Int,
        actual: Int
    )
    case pixelBufferCreationFailed(CVReturn)
    case codeOutOfRange(
        plane: Int,
        component: Int,
        value: UInt16,
        minimum: UInt16,
        maximum: UInt16
    )
    case invalidCodeAlignment(
        plane: Int,
        component: Int,
        value: UInt16,
        requiredZeroLowBits: Int
    )
    case arithmeticOverflow
}

enum R13PixelPlaneRole: String, Equatable, Hashable, Sendable {
    case luma
    case interleavedChroma
    case alpha
    case packedBGRA
    case packedAYCbCr
}

struct R13PixelCodeBounds: Equatable, Hashable, Sendable {
    let minimum: UInt16
    let maximum: UInt16

    init(minimum: UInt16, maximum: UInt16) {
        precondition(minimum <= maximum)
        self.minimum = minimum
        self.maximum = maximum
    }
}

struct R13PixelPlaneLayout: Equatable, Hashable, Sendable {
    let role: R13PixelPlaneRole
    let widthDivisor: Int
    let heightDivisor: Int
    let componentsPerElement: Int
    let bytesPerComponent: Int
    let storedCodeShift: Int
    let componentBounds: [R13PixelCodeBounds]

    init(
        role: R13PixelPlaneRole,
        widthDivisor: Int,
        heightDivisor: Int,
        componentsPerElement: Int,
        bytesPerComponent: Int,
        storedCodeShift: Int,
        componentBounds: [R13PixelCodeBounds]
    ) {
        precondition(widthDivisor > 0)
        precondition(heightDivisor > 0)
        precondition(componentsPerElement > 0)
        precondition(bytesPerComponent == 1 || bytesPerComponent == 2)
        precondition((0...15).contains(storedCodeShift))
        precondition(componentBounds.count == componentsPerElement)
        self.role = role
        self.widthDivisor = widthDivisor
        self.heightDivisor = heightDivisor
        self.componentsPerElement = componentsPerElement
        self.bytesPerComponent = bytesPerComponent
        self.storedCodeShift = storedCodeShift
        self.componentBounds = componentBounds
    }

    func width(for frameWidth: Int) -> Int {
        frameWidth / widthDivisor
    }

    func height(for frameHeight: Int) -> Int {
        frameHeight / heightDivisor
    }

    func activeBytesPerRow(frameWidth: Int) throws -> Int {
        let (componentCount, componentOverflow) =
            width(for: frameWidth).multipliedReportingOverflow(
                by: componentsPerElement
            )
        let (byteCount, byteOverflow) =
            componentCount.multipliedReportingOverflow(
                by: bytesPerComponent
            )
        guard !componentOverflow, !byteOverflow else {
            throw R13PixelLayoutError.arithmeticOverflow
        }
        return byteCount
    }

    func activeByteCount(
        frameWidth: Int,
        frameHeight: Int
    ) throws -> Int {
        let rowBytes = try activeBytesPerRow(frameWidth: frameWidth)
        let (byteCount, overflow) =
            rowBytes.multipliedReportingOverflow(
                by: height(for: frameHeight)
            )
        guard !overflow else {
            throw R13PixelLayoutError.arithmeticOverflow
        }
        return byteCount
    }
}

struct R13PixelLayout: Equatable, Hashable, Sendable {
    let pixelFormat: OSType
    let isPlanar: Bool
    let requiredWidthMultiple: Int
    let requiredHeightMultiple: Int
    let planes: [R13PixelPlaneLayout]

    var expectedCoreVideoPlaneCount: Int {
        isPlanar ? planes.count : 0
    }

    var hasAlpha: Bool {
        planes.contains {
            $0.role == .alpha
                || $0.role == .packedBGRA
                || $0.role == .packedAYCbCr
        }
    }

    func validateGeometry(width: Int, height: Int) throws {
        guard width > 0,
              height > 0,
              width.isMultiple(of: requiredWidthMultiple),
              height.isMultiple(of: requiredHeightMultiple) else {
            throw R13PixelLayoutError.invalidGeometry(
                width: width,
                height: height
            )
        }
    }

    func validate(_ pixelBuffer: CVPixelBuffer) throws {
        let actualFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard actualFormat == pixelFormat else {
            throw R13PixelLayoutError.pixelFormatMismatch(
                expected: pixelFormat,
                actual: actualFormat
            )
        }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        try validateGeometry(width: width, height: height)
        let actualPlaneCount = CVPixelBufferGetPlaneCount(pixelBuffer)
        guard actualPlaneCount == expectedCoreVideoPlaneCount else {
            throw R13PixelLayoutError.planeCountMismatch(
                expected: expectedCoreVideoPlaneCount,
                actual: actualPlaneCount
            )
        }
        for (index, plane) in planes.enumerated() {
            let expectedWidth = plane.width(for: width)
            let expectedHeight = plane.height(for: height)
            let actualWidth = isPlanar
                ? CVPixelBufferGetWidthOfPlane(pixelBuffer, index)
                : width
            let actualHeight = isPlanar
                ? CVPixelBufferGetHeightOfPlane(pixelBuffer, index)
                : height
            guard actualWidth == expectedWidth,
                  actualHeight == expectedHeight else {
                throw R13PixelLayoutError.planeGeometryMismatch(
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
            let actualRowBytes = isPlanar
                ? CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, index)
                : CVPixelBufferGetBytesPerRow(pixelBuffer)
            guard actualRowBytes >= expectedRowBytes else {
                throw R13PixelLayoutError.rowBytesTooSmall(
                    plane: index,
                    expected: expectedRowBytes,
                    actual: actualRowBytes
                )
            }
        }
    }

    func activePlaneByteCounts(
        width: Int,
        height: Int
    ) throws -> [Int] {
        try validateGeometry(width: width, height: height)
        return try planes.map {
            try $0.activeByteCount(
                frameWidth: width,
                frameHeight: height
            )
        }
    }
}

enum R13PixelLayoutProcessor {}
