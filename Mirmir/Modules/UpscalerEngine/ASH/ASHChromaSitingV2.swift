import Foundation

enum ASHChromaSitingAxisV2: Sendable {
    case horizontal
    case vertical
}

struct ASHChromaContinuousLocationV2: Equatable, Sendable {
    let horizontal: Double
    let vertical: Double
}

/// Progressive 4:2:0 chroma sample centers expressed in luma-index space.
/// Offset numerators use a denominator of two: 0 = co-sited, 1 = centered,
/// and 2 = co-sited with the bottom luma row.
enum ASHChromaSitingV2: String, CaseIterable, Equatable, Sendable {
    case center
    case left
    case topLeft = "top_left"
    case top
    case bottomLeft = "bottom_left"
    case bottom

    var horizontalLumaOffsetNumerator: Int64 {
        switch self {
        case .center, .top, .bottom:
            return 1
        case .left, .topLeft, .bottomLeft:
            return 0
        }
    }

    var verticalLumaOffsetNumerator: Int64 {
        switch self {
        case .center, .left:
            return 1
        case .topLeft, .top:
            return 0
        case .bottomLeft, .bottom:
            return 2
        }
    }

    func sourceChromaLocation(lumaX: Int, lumaY: Int) -> ASHChromaContinuousLocationV2 {
        ASHChromaContinuousLocationV2(
            horizontal: (Double(lumaX) - (Double(horizontalLumaOffsetNumerator) / 2.0)) / 2.0,
            vertical: (Double(lumaY) - (Double(verticalLumaOffsetNumerator) / 2.0)) / 2.0
        )
    }

    func sourceCoordinate(
        destinationIndex: Int,
        sourceExtent: Int,
        destinationExtent: Int,
        policy: ASHSpatialCoordinatePolicyV2,
        axis: ASHChromaSitingAxisV2
    ) throws -> ASHSpatialRationalCoordinateV2 {
        let base = try ASHSpatialOperatorBankV2.coordinate(
            destinationIndex: destinationIndex,
            sourceExtent: sourceExtent,
            destinationExtent: destinationExtent,
            policy: policy
        )
        let offsetNumerator = axis == .horizontal
            ? horizontalLumaOffsetNumerator
            : verticalLumaOffsetNumerator
        return try addingSitingCorrection(
            to: base,
            offsetNumerator: offsetNumerator,
            referenceOffsetNumerator: policy == .halfPixelCenter ? 1 : 0,
            sourceExtent: sourceExtent,
            destinationExtent: destinationExtent
        )
    }

    private func addingSitingCorrection(
        to base: ASHSpatialRationalCoordinateV2,
        offsetNumerator: Int64,
        referenceOffsetNumerator: Int64,
        sourceExtent: Int,
        destinationExtent: Int
    ) throws -> ASHSpatialRationalCoordinateV2 {
        let source = Int64(sourceExtent)
        let destination = Int64(destinationExtent)
        let extentDelta = source.subtractingReportingOverflow(destination)
        let relativeOffset = offsetNumerator.subtractingReportingOverflow(referenceOffsetNumerator)
        let correctionNumerator = relativeOffset.partialValue.multipliedReportingOverflow(
            by: extentDelta.partialValue
        )
        let correctionDenominator = destination.multipliedReportingOverflow(by: 4)
        let firstNumerator = base.numerator.multipliedReportingOverflow(
            by: correctionDenominator.partialValue
        )
        let secondNumerator = correctionNumerator.partialValue.multipliedReportingOverflow(
            by: base.denominator
        )
        let numerator = firstNumerator.partialValue.addingReportingOverflow(secondNumerator.partialValue)
        let denominator = base.denominator.multipliedReportingOverflow(
            by: correctionDenominator.partialValue
        )
        guard !extentDelta.overflow,
              !relativeOffset.overflow,
              !correctionNumerator.overflow,
              !correctionDenominator.overflow,
              !firstNumerator.overflow,
              !secondNumerator.overflow,
              !numerator.overflow,
              !denominator.overflow else {
            throw ASHSpatialOperatorErrorV2.coordinateOverflow
        }
        return ASHSpatialRationalCoordinateV2(
            numerator: numerator.partialValue,
            denominator: denominator.partialValue
        )
    }
}
