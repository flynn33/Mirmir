import XCTest
@testable import Mirmir

final class ASHAnalysisGridV2Tests: XCTestCase {
    private struct Planes {
        let luma: ASHVideoAnalyzerV2CodePlane
        let cb: ASHVideoAnalyzerV2CodePlane
        let cr: ASHVideoAnalyzerV2CodePlane
    }

    func test_cellGeometryUsesSymmetricContinuousCentersForEveryLockedStep() throws {
        let planes = try makePlanes(width: 10, height: 6)
        let configuration = try ASHVideoAnalyzerV2DevelopmentConfiguration.makeDisposableP05Reference()

        for step in [1, 2, 4] {
            let grid = try ASHAnalysisGridBuilderV2.build(
                luma: planes.luma,
                cb: planes.cb,
                cr: planes.cr,
                chromaSiting: .center,
                step: step,
                boundary: .mirrorReflect101,
                configuration: configuration
            )
            XCTAssertEqual(grid.columnCount, (10 + step - 1) / step)
            XCTAssertEqual(grid.rowCount, (6 + step - 1) / step)
            XCTAssertEqual(grid.count, grid.columnCount * grid.rowCount)
        }

        let partial = try ASHAnalysisGridBuilderV2.build(
            luma: planes.luma,
            cb: planes.cb,
            cr: planes.cr,
            chromaSiting: .center,
            step: 4,
            boundary: .mirrorReflect101,
            configuration: configuration
        )
        let highEdge = try partial.cell(column: 2, row: 1)
        XCTAssertEqual(highEdge.originX, 8)
        XCTAssertEqual(highEdge.originY, 4)
        XCTAssertEqual(highEdge.actualWidth, 2)
        XCTAssertEqual(highEdge.actualHeight, 2)
        XCTAssertEqual(highEdge.centerX, 8.5, accuracy: 0.0)
        XCTAssertEqual(highEdge.centerY, 4.5, accuracy: 0.0)
    }

    func test_stepOneReducesExactlyToP05IntegerSiteAnalysisForEverySiting() throws {
        let planes = try makePlanes(width: 8, height: 8)
        let configuration = try ASHVideoAnalyzerV2DevelopmentConfiguration.makeDisposableP05Reference()
        for siting in ASHChromaSitingV2.allCases {
            let grid = try ASHAnalysisGridBuilderV2.build(
                luma: planes.luma,
                cb: planes.cb,
                cr: planes.cr,
                chromaSiting: siting,
                step: 1,
                boundary: .mirrorReflect101,
                configuration: configuration
            )
            for row in 0..<planes.luma.height {
                for column in 0..<planes.luma.width {
                    let chroma = try ASHVideoAnalyzerV2ChromaInput(
                        cb: planes.cb,
                        cr: planes.cr,
                        location: siting.sourceChromaLocation(lumaX: column, lumaY: row)
                    )
                    let direct = try ASHVideoAnalyzerV2.analyze(
                        ASHVideoAnalyzerV2Input(
                            luma: planes.luma,
                            location: ASHVideoAnalyzerV2Location(x: column, y: row),
                            chroma: chroma,
                            boundary: .reflect101,
                            history: nil,
                            validationTemporalEvidence: nil
                        ),
                        configuration: configuration
                    )
                    XCTAssertEqual(try grid.cell(column: column, row: row).analysis, direct)
                }
            }
        }
    }

    func test_exactRationalAssignmentClampsAndKeepsOneCellStateAndSidecar() throws {
        let planes = try makePlanes(width: 8, height: 8)
        let grid = try ASHAnalysisGridBuilderV2.build(
            luma: planes.luma,
            cb: planes.cb,
            cr: planes.cr,
            chromaSiting: .center,
            step: 2,
            boundary: .clamp,
            configuration: try .makeDisposableP05Reference()
        )
        let first = try grid.cell(
            lumaSourceX: rational(0, 1),
            lumaSourceY: rational(1, 1)
        )
        let same = try grid.cell(
            lumaSourceX: rational(1, 1),
            lumaSourceY: rational(0, 1)
        )
        XCTAssertEqual(first.column, 0)
        XCTAssertEqual(first.row, 0)
        XCTAssertEqual(first.analysis.state, same.analysis.state)
        XCTAssertEqual(first.analysis.sidecar, same.analysis.sidecar)

        XCTAssertEqual(
            try grid.cell(lumaSourceX: rational(3, 2), lumaSourceY: rational(0, 1)).column,
            1
        )
        XCTAssertEqual(
            try grid.cell(lumaSourceX: rational(7, 2), lumaSourceY: rational(0, 1)).column,
            2
        )
        XCTAssertEqual(
            try grid.cell(lumaSourceX: rational(-3, 4), lumaSourceY: rational(99, 1)).row,
            grid.rowCount - 1
        )
    }

    func test_chromaCoordinatesMapBackToTheExactLumaCellForEverySiting() throws {
        let planes = try makePlanes(width: 8, height: 8)
        let grid = try ASHAnalysisGridBuilderV2.build(
            luma: planes.luma,
            cb: planes.cb,
            cr: planes.cr,
            chromaSiting: .center,
            step: 2,
            boundary: .mirrorReflect101,
            configuration: try .makeDisposableP05Reference()
        )
        let lumaX = rational(5, 2)
        let lumaY = rational(7, 2)
        let expected = try grid.cell(lumaSourceX: lumaX, lumaSourceY: lumaY)
        for siting in ASHChromaSitingV2.allCases {
            let chromaX = chromaCoordinate(
                fromLuma: lumaX,
                offsetNumerator: siting.horizontalLumaOffsetNumerator
            )
            let chromaY = chromaCoordinate(
                fromLuma: lumaY,
                offsetNumerator: siting.verticalLumaOffsetNumerator
            )
            let observed = try grid.cell(
                chromaSourceX: chromaX,
                chromaSourceY: chromaY,
                siting: siting
            )
            XCTAssertEqual(observed.column, expected.column, siting.rawValue)
            XCTAssertEqual(observed.row, expected.row, siting.rawValue)
        }
    }

    func test_invalidStepAndGeometryFailBeforeAnalysis() throws {
        let planes = try makePlanes(width: 8, height: 8)
        XCTAssertThrowsError(try ASHAnalysisGridBuilderV2.build(
            luma: planes.luma,
            cb: planes.cb,
            cr: planes.cr,
            chromaSiting: .center,
            step: 3,
            boundary: .clamp,
            configuration: try .makeDisposableP05Reference()
        )) { error in
            XCTAssertEqual(error as? ASHAnalysisGridV2Error, .invalidStep(3))
        }
    }

    private func rational(_ numerator: Int64, _ denominator: Int64) -> ASHSpatialRationalCoordinateV2 {
        ASHSpatialRationalCoordinateV2(numerator: numerator, denominator: denominator)
    }

    private func chromaCoordinate(
        fromLuma coordinate: ASHSpatialRationalCoordinateV2,
        offsetNumerator: Int64
    ) -> ASHSpatialRationalCoordinateV2 {
        ASHSpatialRationalCoordinateV2(
            numerator: (2 * coordinate.numerator) - (offsetNumerator * coordinate.denominator),
            denominator: 4 * coordinate.denominator
        )
    }

    private func makePlanes(
        width: Int,
        height: Int
    ) throws -> Planes {
        let luma = try plane(width: width, height: height) { column, row in
            let horizontal = column * 29
            let vertical = row * 41
            let interaction = column * row * 3
            let code = 16 + ((horizontal + vertical + interaction) % 220)
            return UInt8(code)
        }
        let cb = try plane(width: width / 2, height: height / 2) { column, row in
            UInt8(16 + ((column * 47 + row * 19) % 225))
        }
        let cr = try plane(width: width / 2, height: height / 2) { column, row in
            UInt8(240 - ((column * 31 + row * 43) % 225))
        }
        return Planes(luma: luma, cb: cb, cr: cr)
    }

    private func plane(
        width: Int,
        height: Int,
        generator: (Int, Int) -> UInt8
    ) throws -> ASHVideoAnalyzerV2CodePlane {
        var codes: [UInt8] = []
        for row in 0..<height {
            for column in 0..<width {
                codes.append(generator(column, row))
            }
        }
        return try ASHVideoAnalyzerV2CodePlane(
            width: width,
            height: height,
            bytesPerRow: width,
            codes: codes,
            range: .video
        )
    }
}
