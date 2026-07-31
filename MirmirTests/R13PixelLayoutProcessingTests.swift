import Accelerate
import CoreVideo
import XCTest
@testable import Mirmir

final class R13PixelLayoutProcessingTests: XCTestCase {
    func testDeclaredLayoutsMatchCoreVideoPlaneGeometry() throws {
        let cases: [LayoutCase] = [
            LayoutCase(
                pixelFormat:
                    kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange,
                width: 8,
                height: 5,
                planeGeometry: [Geometry(8, 5), Geometry(4, 5)]
            ),
            LayoutCase(
                pixelFormat:
                    kCVPixelFormatType_444YpCbCr10BiPlanarFullRange,
                width: 7,
                height: 5,
                planeGeometry: [Geometry(7, 5), Geometry(7, 5)]
            ),
            LayoutCase(
                pixelFormat:
                    kCVPixelFormatType_444YpCbCr16VideoRange_16A_TriPlanar,
                width: 7,
                height: 5,
                planeGeometry: [
                    Geometry(7, 5),
                    Geometry(7, 5),
                    Geometry(7, 5)
                ]
            ),
            LayoutCase(
                pixelFormat:
                    kCVPixelFormatType_422YpCbCr16BiPlanarVideoRange,
                width: 8,
                height: 5,
                planeGeometry: [Geometry(8, 5), Geometry(4, 5)]
            ),
            LayoutCase(
                pixelFormat:
                    kCVPixelFormatType_444YpCbCr16BiPlanarVideoRange,
                width: 7,
                height: 5,
                planeGeometry: [Geometry(7, 5), Geometry(7, 5)]
            ),
            LayoutCase(
                pixelFormat: kCVPixelFormatType_4444AYpCbCr8,
                width: 7,
                height: 5,
                planeGeometry: [Geometry(7, 5)]
            )
        ]

        for item in cases {
            let buffer = try makeGradientBuffer(
                pixelFormat: item.pixelFormat,
                width: item.width,
                height: item.height
            )
            let layout = try R13PixelLayoutRegistry.layout(
                for: item.pixelFormat
            )
            try layout.validate(buffer)
            XCTAssertEqual(
                layout.planes.map {
                    (
                        $0.width(for: item.width),
                        $0.height(for: item.height)
                    )
                }.map(Geometry.init),
                item.planeGeometry
            )
        }
    }

    func testVerticalFilterProcessesEveryS4ASComponent() throws {
        let source = try makeRowPatternS4AS(
            luma: [4_096, 20_000, 60_160],
            cb: [4_096, 30_000, 61_440],
            cr: [61_440, 30_000, 4_096],
            alpha: [1_001, 20_003, 60_007]
        )
        let destination = try makeGradientBuffer(
            pixelFormat:
                kCVPixelFormatType_444YpCbCr16VideoRange_16A_TriPlanar,
            width: 3,
            height: 3
        )
        CVBufferSetAttachment(
            source,
            kCVImageBufferColorPrimariesKey,
            kCVImageBufferColorPrimaries_P3_D65,
            .shouldPropagate
        )

        try R13PixelLayoutProcessor.verticalFilter(
            source: source,
            destination: destination
        )
        try R13PixelLayoutProcessor.validateStoredCodes(destination)

        let captured = try R13TightPixelFrame(
            capturing: destination
        )
        XCTAssertEqual(
            try wordCode(captured, plane: 0, row: 1, component: 0),
            weighted(4_096, 20_000, 60_160)
        )
        XCTAssertEqual(
            try wordCode(captured, plane: 1, row: 1, component: 0),
            weighted(4_096, 30_000, 61_440)
        )
        XCTAssertEqual(
            try wordCode(captured, plane: 1, row: 1, component: 1),
            weighted(61_440, 30_000, 4_096)
        )
        XCTAssertEqual(
            try wordCode(captured, plane: 2, row: 1, component: 0),
            weighted(1_001, 20_003, 60_007)
        )
        XCTAssertTrue(
            CFEqual(
                CVBufferCopyAttachment(
                    destination,
                    kCVImageBufferColorPrimariesKey,
                    nil
                ),
                kCVImageBufferColorPrimaries_P3_D65
            )
        )
    }

    func testVImageScalingPreservesNonuniform422Chroma() throws {
        let source = try makeGradientBuffer(
            pixelFormat:
                kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange,
            width: 4,
            height: 3
        )
        let destination = try makeGradientBuffer(
            pixelFormat:
                kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange,
            width: 8,
            height: 5
        )

        try R13PixelLayoutProcessor.scaleVImage(
            source: source,
            destination: destination,
            flags: vImage_Flags(
                kvImageEdgeExtend | kvImageHighQualityResampling
            )
        )
        try R13PixelLayoutProcessor.validateStoredCodes(destination)

        let frame = try R13TightPixelFrame(capturing: destination)
        let chroma = [UInt8](frame.planes[1])
        let cbValues = stride(from: 0, to: chroma.count, by: 2)
            .map { chroma[$0] }
        let crValues = stride(from: 1, to: chroma.count, by: 2)
            .map { chroma[$0] }
        XCTAssertGreaterThan(Set(cbValues).count, 2)
        XCTAssertGreaterThan(Set(crValues).count, 2)
        XCTAssertEqual(frame.planes[1].count, 8 * 5)
    }

    func testVImageScalingPreservesS4ASFractionalAlpha() throws {
        let source = try makeRowPatternS4AS(
            width: 2,
            luma: [4_096, 60_160],
            cb: [4_096, 61_440],
            cr: [61_440, 4_096],
            alpha: [1_001, 60_007]
        )
        let destination = try makeGradientBuffer(
            pixelFormat:
                kCVPixelFormatType_444YpCbCr16VideoRange_16A_TriPlanar,
            width: 3,
            height: 3
        )

        try R13PixelLayoutProcessor.scaleVImage(
            source: source,
            destination: destination,
            flags: vImage_Flags(
                kvImageEdgeExtend | kvImageHighQualityResampling
            )
        )
        try R13PixelLayoutProcessor.validateStoredCodes(destination)

        let frame = try R13TightPixelFrame(capturing: destination)
        let centerAlpha = try wordCode(
            frame,
            plane: 2,
            row: 1,
            component: 1
        )
        XCTAssertGreaterThan(centerAlpha, 1_001)
        XCTAssertLessThan(centerAlpha, 60_007)
        XCTAssertNotEqual(centerAlpha, 0)
        XCTAssertNotEqual(centerAlpha, 65_535)
        XCTAssertEqual(frame.planes[2].count, 3 * 3 * 2)
    }

    func testDeterministicBlendInterpolatesFractionalS4ASAlpha()
        throws {
        let previous = try makeConstantS4AS(
            luma: 10_001,
            cb: 11_003,
            cr: 50_007,
            alpha: 1_001
        )
        let current = try makeConstantS4AS(
            luma: 50_003,
            cb: 51_007,
            cr: 10_009,
            alpha: 60_007
        )
        let destination = try makeGradientBuffer(
            pixelFormat:
                kCVPixelFormatType_444YpCbCr16VideoRange_16A_TriPlanar,
            width: 2,
            height: 2
        )

        try R13PixelLayoutProcessor.blend(
            previous: previous,
            current: current,
            destination: destination,
            phase: 0.25
        )
        let frame = try R13TightPixelFrame(capturing: destination)
        XCTAssertEqual(
            try wordCode(frame, plane: 0, row: 0, component: 0),
            phaseQuarter(previous: 10_001, current: 50_003)
        )
        XCTAssertEqual(
            try wordCode(frame, plane: 1, row: 0, component: 0),
            phaseQuarter(previous: 11_003, current: 51_007)
        )
        XCTAssertEqual(
            try wordCode(frame, plane: 1, row: 0, component: 1),
            phaseQuarter(previous: 50_007, current: 10_009)
        )
        XCTAssertEqual(
            try wordCode(frame, plane: 2, row: 0, component: 0),
            phaseQuarter(previous: 1_001, current: 60_007)
        )
    }

    func testCacheRoundTripPreservesEveryS4ASPlaneExactly() throws {
        let pixelBuffer = try makeGradientBuffer(
            pixelFormat:
                kCVPixelFormatType_444YpCbCr16VideoRange_16A_TriPlanar,
            width: 5,
            height: 3
        )
        let original = try R13NV12Frame.captureTightActivePlanes(
            from: pixelBuffer
        )
        let codec = R13LZFSEFrameCacheCodec()

        let decoded = try codec.decode(
            codec.encode(original).data
        )
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.auxiliaryPlanes.count, 1)

        let restored = try R13TightPixelFrame(
            width: decoded.width,
            height: decoded.height,
            pixelFormat: decoded.pixelFormat,
            planes: [
                decoded.luma,
                decoded.chroma
            ] + decoded.auxiliaryPlanes
        ).makePixelBuffer()
        let recaptured = try R13NV12Frame.captureTightActivePlanes(
            from: restored
        )
        XCTAssertEqual(recaptured, original)
    }

    func testEveryRegisteredLayoutFiltersWithinCodeBounds() throws {
        for pixelFormat in R13PixelLayoutRegistry
            .supportedPixelFormats {
            let layout = try R13PixelLayoutRegistry.layout(
                for: pixelFormat
            )
            let width = max(4, layout.requiredWidthMultiple * 2)
            let height = max(4, layout.requiredHeightMultiple * 2)
            let source = try makeGradientBuffer(
                pixelFormat: pixelFormat,
                width: width,
                height: height
            )
            let destination = try makeGradientBuffer(
                pixelFormat: pixelFormat,
                width: width,
                height: height
            )
            try R13PixelLayoutProcessor.verticalFilter(
                source: source,
                destination: destination
            )
            try R13PixelLayoutProcessor.validateStoredCodes(
                destination
            )
        }
    }

    func testChromaNormalizationUsesExactNeutralAndExtremeCodes()
        throws {
        for pixelFormat in R13PixelLayoutRegistry
            .supportedPixelFormats {
            let layout = try R13PixelLayoutRegistry.layout(
                for: pixelFormat
            )
            guard layout.planes.contains(where: {
                $0.role == .interleavedChroma
                    || $0.role == .packedAYCbCr
            }) else {
                continue
            }
            let width = max(4, layout.requiredWidthMultiple * 2)
            let height = max(4, layout.requiredHeightMultiple * 2)
            let neutral =
                try R13PixelLayoutTestFixtures.makeUniformBuffer(
                    pixelFormat: pixelFormat,
                    width: width,
                    height: height,
                    maximumLuma: false
                )
            let extreme =
                try R13PixelLayoutTestFixtures.makeUniformBuffer(
                    pixelFormat: pixelFormat,
                    width: width,
                    height: height,
                    maximumLuma: false,
                    extremeChroma: true
                )

            XCTAssertEqual(
                try chromaEnergy(neutral),
                0,
                accuracy: 0.000_001,
                "neutral format \(pixelFormat)"
            )
            XCTAssertEqual(
                try chromaEnergy(extreme),
                1,
                accuracy: 0.000_001,
                "extreme format \(pixelFormat)"
            )
        }
    }
}

extension R13PixelLayoutProcessingTests {
    struct LayoutCase {
        let pixelFormat: OSType
        let width: Int
        let height: Int
        let planeGeometry: [Geometry]
    }

    struct Geometry: Equatable {
        let width: Int
        let height: Int

        init(_ width: Int, _ height: Int) {
            self.width = width
            self.height = height
        }

        init(_ value: (Int, Int)) {
            width = value.0
            height = value.1
        }
    }

    func makeGradientBuffer(
        pixelFormat: OSType,
        width: Int,
        height: Int
    ) throws -> CVPixelBuffer {
        try R13PixelLayoutTestFixtures.makeGradientBuffer(
            pixelFormat: pixelFormat,
            width: width,
            height: height
        )
    }

    func makeRowPatternS4AS(
        width: Int = 3,
        luma: [UInt16],
        cb: [UInt16],
        cr: [UInt16],
        alpha: [UInt16]
    ) throws -> CVPixelBuffer {
        let height = luma.count
        XCTAssertEqual(cb.count, height)
        XCTAssertEqual(cr.count, height)
        XCTAssertEqual(alpha.count, height)
        var lumaWords: [UInt16] = []
        var chromaWords: [UInt16] = []
        var alphaWords: [UInt16] = []
        for row in 0..<height {
            lumaWords.append(
                contentsOf: repeatElement(luma[row], count: width)
            )
            for _ in 0..<width {
                chromaWords.append(cb[row])
                chromaWords.append(cr[row])
            }
            alphaWords.append(
                contentsOf: repeatElement(alpha[row], count: width)
            )
        }
        return try R13TightPixelFrame(
            width: width,
            height: height,
            pixelFormat:
                kCVPixelFormatType_444YpCbCr16VideoRange_16A_TriPlanar,
            planes: [
                data(lumaWords),
                data(chromaWords),
                data(alphaWords)
            ]
        ).makePixelBuffer()
    }

    func makeConstantS4AS(
        luma: UInt16,
        cb: UInt16,
        cr: UInt16,
        alpha: UInt16
    ) throws -> CVPixelBuffer {
        try makeRowPatternS4AS(
            width: 2,
            luma: [luma, luma],
            cb: [cb, cb],
            cr: [cr, cr],
            alpha: [alpha, alpha]
        )
    }
}
