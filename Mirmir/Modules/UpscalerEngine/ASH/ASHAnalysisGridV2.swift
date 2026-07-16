import Foundation

enum ASHAnalysisGridV2Error: Error, Equatable, Sendable {
    case invalidStep(Int)
    case mismatchedChromaGeometry
    case mismatchedPlaneRange
    case unsupportedChromaSubsampling
    case invalidCell(column: Int, row: Int)
    case coordinateOverflow
}

struct ASHAnalysisGridCellV2: Equatable, Sendable {
    let column: Int
    let row: Int
    let originX: Int
    let originY: Int
    let actualWidth: Int
    let actualHeight: Int
    let centerX: Double
    let centerY: Double
    let analysis: ASHVideoAnalyzerV2Result
}

struct ASHAnalysisGridV2: Equatable, Sendable {
    let sourceWidth: Int
    let sourceHeight: Int
    let step: Int
    let columnCount: Int
    let rowCount: Int
    let cells: [ASHAnalysisGridCellV2]

    var count: Int { cells.count }

    func cell(column: Int, row: Int) throws -> ASHAnalysisGridCellV2 {
        guard (0..<columnCount).contains(column),
              (0..<rowCount).contains(row) else {
            throw ASHAnalysisGridV2Error.invalidCell(column: column, row: row)
        }
        return cells[(row * columnCount) + column]
    }

    func cell(
        lumaSourceX: ASHSpatialRationalCoordinateV2,
        lumaSourceY: ASHSpatialRationalCoordinateV2
    ) throws -> ASHAnalysisGridCellV2 {
        try cell(
            column: Self.cellIndex(
                coordinate: lumaSourceX,
                step: step,
                lastCell: columnCount - 1
            ),
            row: Self.cellIndex(
                coordinate: lumaSourceY,
                step: step,
                lastCell: rowCount - 1
            )
        )
    }

    func cell(
        chromaSourceX: ASHSpatialRationalCoordinateV2,
        chromaSourceY: ASHSpatialRationalCoordinateV2,
        siting: ASHChromaSitingV2
    ) throws -> ASHAnalysisGridCellV2 {
        let lumaX = try Self.lumaCoordinate(
            fromChroma: chromaSourceX,
            offsetNumerator: siting.horizontalLumaOffsetNumerator
        )
        let lumaY = try Self.lumaCoordinate(
            fromChroma: chromaSourceY,
            offsetNumerator: siting.verticalLumaOffsetNumerator
        )
        return try cell(lumaSourceX: lumaX, lumaSourceY: lumaY)
    }

    private static func lumaCoordinate(
        fromChroma coordinate: ASHSpatialRationalCoordinateV2,
        offsetNumerator: Int64
    ) throws -> ASHSpatialRationalCoordinateV2 {
        let scaled = coordinate.numerator.multipliedReportingOverflow(by: 4)
        let offset = offsetNumerator.multipliedReportingOverflow(by: coordinate.denominator)
        let numerator = scaled.partialValue.addingReportingOverflow(offset.partialValue)
        let denominator = coordinate.denominator.multipliedReportingOverflow(by: 2)
        guard coordinate.denominator > 0,
              !scaled.overflow,
              !offset.overflow,
              !numerator.overflow,
              !denominator.overflow else {
            throw ASHAnalysisGridV2Error.coordinateOverflow
        }
        return ASHSpatialRationalCoordinateV2(
            numerator: numerator.partialValue,
            denominator: denominator.partialValue
        )
    }

    private static func cellIndex(
        coordinate: ASHSpatialRationalCoordinateV2,
        step: Int,
        lastCell: Int
    ) throws -> Int {
        guard coordinate.denominator > 0,
              let step64 = Int64(exactly: step) else {
            throw ASHAnalysisGridV2Error.coordinateOverflow
        }
        let doubledNumerator = coordinate.numerator.multipliedReportingOverflow(by: 2)
        let shiftedNumerator = doubledNumerator.partialValue.addingReportingOverflow(
            coordinate.denominator
        )
        let doubledDenominator = coordinate.denominator.multipliedReportingOverflow(by: 2)
        let divisor = doubledDenominator.partialValue.multipliedReportingOverflow(by: step64)
        guard !doubledNumerator.overflow,
              !shiftedNumerator.overflow,
              !doubledDenominator.overflow,
              !divisor.overflow,
              divisor.partialValue > 0 else {
            throw ASHAnalysisGridV2Error.coordinateOverflow
        }
        let quotient = floorDivision(shiftedNumerator.partialValue, by: divisor.partialValue)
        if quotient <= 0 { return 0 }
        guard let exact = Int(exactly: quotient) else { return lastCell }
        return min(lastCell, exact)
    }

    private static func floorDivision(_ numerator: Int64, by denominator: Int64) -> Int64 {
        let quotient = numerator / denominator
        let remainder = numerator % denominator
        return numerator < 0 && remainder != 0 ? quotient - 1 : quotient
    }
}

enum ASHAnalysisGridBuilderV2 {
    static func build(
        luma: ASHVideoAnalyzerV2CodePlane,
        cb: ASHVideoAnalyzerV2CodePlane,
        cr: ASHVideoAnalyzerV2CodePlane,
        chromaSiting: ASHChromaSitingV2,
        step: Int,
        boundary: ASHSpatialBoundaryModeV2,
        configuration: ASHVideoAnalyzerV2DevelopmentConfiguration
    ) throws -> ASHAnalysisGridV2 {
        guard [1, 2, 4].contains(step) else {
            throw ASHAnalysisGridV2Error.invalidStep(step)
        }
        guard cb.width == cr.width, cb.height == cr.height else {
            throw ASHAnalysisGridV2Error.mismatchedChromaGeometry
        }
        guard luma.range == cb.range, cb.range == cr.range else {
            throw ASHAnalysisGridV2Error.mismatchedPlaneRange
        }
        guard luma.width == cb.width * 2, luma.height == cb.height * 2 else {
            throw ASHAnalysisGridV2Error.unsupportedChromaSubsampling
        }

        let columnCount = (luma.width + step - 1) / step
        let rowCount = (luma.height + step - 1) / step
        var cells: [ASHAnalysisGridCellV2] = []
        cells.reserveCapacity(columnCount * rowCount)
        let analyzerBoundary = analyzerBoundary(boundary)
        for row in 0..<rowCount {
            let originY = row * step
            let actualHeight = min(step, luma.height - originY)
            let centerY = Double(originY) + (Double(actualHeight - 1) / 2.0)
            for column in 0..<columnCount {
                let originX = column * step
                let actualWidth = min(step, luma.width - originX)
                let centerX = Double(originX) + (Double(actualWidth - 1) / 2.0)
                let lumaMeasurements = try ASHVideoAnalyzerV2.analyzeLuma(
                    plane: luma,
                    location: ASHVideoAnalyzerV2ContinuousLocation(x: centerX, y: centerY),
                    boundary: analyzerBoundary,
                    configuration: configuration
                )
                let chromaLocation = chromaSiting.sourceChromaLocation(
                    lumaX: centerX,
                    lumaY: centerY
                )
                let chroma = try ASHVideoAnalyzerV2ChromaInput(
                    cb: cb,
                    cr: cr,
                    location: chromaLocation
                )
                let measurements = ASHVideoAnalyzerV2.analyzeChroma(
                    lumaMeasurements,
                    chroma: chroma,
                    boundary: analyzerBoundary,
                    configuration: configuration
                )
                let analysis = try ASHVideoAnalyzerV2.makeResult(
                    measurements: measurements,
                    inputRange: luma.range,
                    history: nil,
                    temporalEvidence: nil,
                    configuration: configuration
                )
                cells.append(ASHAnalysisGridCellV2(
                    column: column,
                    row: row,
                    originX: originX,
                    originY: originY,
                    actualWidth: actualWidth,
                    actualHeight: actualHeight,
                    centerX: centerX,
                    centerY: centerY,
                    analysis: analysis
                ))
            }
        }
        return ASHAnalysisGridV2(
            sourceWidth: luma.width,
            sourceHeight: luma.height,
            step: step,
            columnCount: columnCount,
            rowCount: rowCount,
            cells: cells
        )
    }

    private static func analyzerBoundary(
        _ boundary: ASHSpatialBoundaryModeV2
    ) -> ASHVideoAnalyzerV2BoundaryRule {
        switch boundary {
        case .clamp: .clamp
        case .mirrorReflect101: .reflect101
        }
    }
}
