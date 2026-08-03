import XCTest
@testable import Mirmir

final class ASHMeasurementExtractorV4Tests: XCTestCase {
    func testConstantNeutralNV12ProducesExactDeclaredEvidenceAndState() throws {
        let frame = try makeFrame(
            storage: .nv12VideoRange8Bit,
            width: 7,
            height: 5,
            luma: { _, _ in 126 },
            cb: { _, _ in 128 },
            cr: { _, _ in 128 }
        )
        let result = try ASHMeasurementExtractorV4.extract(
            frame: frame,
            previousFrame: nil,
            contract: .canonicalP06,
            history: .reset(.streamStart)
        )
        let evidence = result.projection.evidence
        XCTAssertEqual(result.normalizedLumaWindowQ16.count, 32 * 32)
        XCTAssertEqual(Set(result.normalizedLumaWindowQ16).count, 1)
        XCTAssertEqual(evidence.rmsContrast, .zero)
        XCTAssertEqual(evidence.edgeEnergy, .zero)
        XCTAssertEqual(evidence.textureEnergy, .zero)
        XCTAssertEqual(evidence.chromaEnergy, .zero)
        XCTAssertEqual(evidence.horizontalGradientEnergy, .zero)
        XCTAssertEqual(evidence.verticalGradientEnergy, .zero)
        XCTAssertEqual(evidence.temporalChange, .zero)
        XCTAssertEqual(
            result.projection.payloadBitsByCoordinate,
            [1, 0, 0, 0, 0, 0, 0, 0]
        )
        XCTAssertTrue(result.projection.state.hasValidIntegrity)
    }

    func testEquivalentNV12AndP010CodesProjectToTheSameState() throws {
        let nv12 = try makeFrame(
            storage: .nv12VideoRange8Bit,
            width: 32,
            height: 32,
            luma: { x, y in UInt16(16 + ((x * 7 + y * 3) % 220)) },
            cb: { x, _ in UInt16(96 + x % 64) },
            cr: { _, y in UInt16(96 + y % 64) }
        )
        let p010 = try makeFrame(
            storage: .p010VideoRange10Bit,
            width: 32,
            height: 32,
            luma: { x, y in
                let code = UInt16(16 + ((x * 7 + y * 3) % 220))
                return 64 + (code - 16) * 4
            },
            cb: { x, _ in UInt16(384 + (x % 64) * 4) },
            cr: { _, y in UInt16(384 + (y % 64) * 4) }
        )
        let first = try ASHMeasurementExtractorV4.extract(
            frame: nv12,
            previousFrame: nil,
            contract: .canonicalP06,
            history: .reset(.streamStart)
        )
        let second = try ASHMeasurementExtractorV4.extract(
            frame: p010,
            previousFrame: nil,
            contract: .canonicalP06,
            history: .reset(.streamStart)
        )
        XCTAssertEqual(first.normalizedLumaWindowQ16, second.normalizedLumaWindowQ16)
        XCTAssertEqual(first.projection.evidence, second.projection.evidence)
        XCTAssertEqual(first.projection.state, second.projection.state)
    }

    func testTemporalEvidenceAndHysteresisUseOnlyPastFrame() throws {
        let dark = try makeFrame(
            storage: .nv12FullRange8Bit,
            width: 4,
            height: 4,
            luma: { _, _ in 0 },
            cb: { _, _ in 128 },
            cr: { _, _ in 128 }
        )
        let bright = try makeFrame(
            storage: .nv12FullRange8Bit,
            width: 4,
            height: 4,
            luma: { _, _ in 255 },
            cb: { _, _ in 128 },
            cr: { _, _ in 128 }
        )
        let initial = try ASHMeasurementExtractorV4.extract(
            frame: dark,
            previousFrame: nil,
            contract: .canonicalP06,
            history: .reset(.streamStart)
        )
        let changed = try ASHMeasurementExtractorV4.extract(
            frame: bright,
            previousFrame: dark,
            contract: .canonicalP06,
            history: .continuous(previousState: initial.projection.state)
        )
        XCTAssertEqual(changed.projection.evidence.temporalChange, .one)
        XCTAssertEqual(changed.projection.bit(for: .temporalChange), 1)
        XCTAssertEqual(changed.projection.bit(for: .meanLuminance), 1)
        XCTAssertTrue(changed.projection.state.hasValidIntegrity)
    }

    func testHistoryGeometryMismatchFailsClosed() throws {
        let first = try makeFrame(
            storage: .nv12VideoRange8Bit,
            width: 4,
            height: 4,
            luma: { _, _ in 64 },
            cb: { _, _ in 128 },
            cr: { _, _ in 128 }
        )
        let other = try makeFrame(
            storage: .nv12VideoRange8Bit,
            width: 5,
            height: 4,
            luma: { _, _ in 64 },
            cb: { _, _ in 128 },
            cr: { _, _ in 128 }
        )
        XCTAssertThrowsError(
            try ASHMeasurementExtractorV4.extract(
                frame: first,
                previousFrame: other,
                contract: .canonicalP06,
                history: .continuous(
                    previousState: try ASHState(
                        payloadBits: Array(repeating: 0, count: 8)
                    )
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? ASHMeasurementExtractorV4Error,
                .incompatibleHistory
            )
        }
    }

    private func makeFrame(
        storage: PixelStorageV4,
        width: Int,
        height: Int,
        luma: (Int, Int) -> UInt16,
        cb: (Int, Int) -> UInt16,
        cr: (Int, Int) -> UInt16
    ) throws -> PixelBufferSignalFrameV4 {
        let layout = PixelLayoutV4(storage: storage)
        let lumaLayout = layout.planes[0]
        let chromaLayout = layout.planes[1]
        var lumaSamples: [UInt16] = []
        for y in 0..<height {
            for x in 0..<width {
                lumaSamples.append(luma(x, y))
            }
        }
        let chromaWidth = try chromaLayout.width(forFrameWidth: width)
        let chromaHeight = try chromaLayout.height(forFrameHeight: height)
        var chromaSamples: [UInt16] = []
        for y in 0..<chromaHeight {
            for x in 0..<chromaWidth {
                chromaSamples.append(cb(x, y))
                chromaSamples.append(cr(x, y))
            }
        }
        return PixelBufferSignalFrameV4(
            storage: storage,
            width: width,
            height: height,
            planes: [
                try PixelBufferSignalPlaneV4(
                    width: width,
                    height: height,
                    componentsPerElement: 1,
                    componentBounds: lumaLayout.signalCodeBounds,
                    samples: lumaSamples
                ),
                try PixelBufferSignalPlaneV4(
                    width: chromaWidth,
                    height: chromaHeight,
                    componentsPerElement: 2,
                    componentBounds: chromaLayout.signalCodeBounds,
                    samples: chromaSamples
                )
            ]
        )
    }
}
