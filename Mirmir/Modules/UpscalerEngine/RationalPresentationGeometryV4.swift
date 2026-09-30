import CoreMedia
import Foundation

enum RationalPresentationGeometryV4Error: Error, Equatable, Sendable {
    case zeroDenominator
    case divisionByZero
    case arithmeticOverflow
    case nonPositiveCodedRaster(width: Int64, height: Int64)
    case nonPositiveCleanAperture
    case cleanApertureOutsideCodedRaster
    case invalidSampleAspectRatio(
        horizontalSpacing: Int64,
        verticalSpacing: Int64
    )
    case nonPositiveOutputScale
    case unsupportedPreferredLinearTransform
    case fractionalPreferredTranslation
}

enum ExactRationalOrderingV4: Equatable, Sendable {
    case ascending
    case same
    case descending
}

/// Reduced signed rational backed only by Int64 arithmetic. Every operation
/// reports overflow instead of approximating through floating point.
struct ExactRationalV4: Hashable, Comparable, Codable, Sendable,
    CustomStringConvertible {
    let numerator: Int64
    let denominator: Int64

    static let zero = ExactRationalV4(
        normalizedNumerator: 0,
        denominator: 1
    )
    static let one = ExactRationalV4(
        normalizedNumerator: 1,
        denominator: 1
    )
    static let negativeOne = ExactRationalV4(
        normalizedNumerator: -1,
        denominator: 1
    )

    init(_ numerator: Int64, _ denominator: Int64 = 1) throws {
        guard denominator != 0 else {
            throw RationalPresentationGeometryV4Error.zeroDenominator
        }
        guard numerator != 0 else {
            self = .zero
            return
        }

        let divisor = Self.greatestCommonDivisor(
            numerator.magnitude,
            denominator.magnitude
        )
        let reducedNumeratorMagnitude = numerator.magnitude / divisor
        let reducedDenominatorMagnitude = denominator.magnitude / divisor
        guard reducedDenominatorMagnitude <= UInt64(Int64.max) else {
            throw RationalPresentationGeometryV4Error.arithmeticOverflow
        }

        let isNegative = (numerator < 0) != (denominator < 0)
        self.numerator = try Self.signedValue(
            magnitude: reducedNumeratorMagnitude,
            isNegative: isNegative
        )
        self.denominator = Int64(reducedDenominatorMagnitude)
    }

    private enum CodingKeys: String, CodingKey {
        case numerator
        case denominator
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let numerator = try container.decode(Int64.self, forKey: .numerator)
        let denominator = try container.decode(Int64.self, forKey: .denominator)
        do {
            try self.init(numerator, denominator)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .denominator,
                in: container,
                debugDescription: "Invalid exact rational: \(error)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(numerator, forKey: .numerator)
        try container.encode(denominator, forKey: .denominator)
    }

    var isZero: Bool {
        numerator == 0
    }

    var isPositive: Bool {
        numerator > 0
    }

    var isInteger: Bool {
        denominator == 1
    }

    var integerValue: Int64? {
        isInteger ? numerator : nil
    }

    var description: String {
        denominator == 1 ? "\(numerator)" : "\(numerator)/\(denominator)"
    }

    func negated() throws -> ExactRationalV4 {
        let (value, overflow) = numerator.multipliedReportingOverflow(by: -1)
        guard !overflow else {
            throw RationalPresentationGeometryV4Error.arithmeticOverflow
        }
        return ExactRationalV4(
            normalizedNumerator: value,
            denominator: denominator
        )
    }

    func adding(_ other: ExactRationalV4) throws -> ExactRationalV4 {
        let commonDivisor = Self.greatestCommonDivisor(
            UInt64(denominator),
            UInt64(other.denominator)
        )
        let leftMultiplier = other.denominator / Int64(commonDivisor)
        let rightMultiplier = denominator / Int64(commonDivisor)
        let (leftNumerator, leftOverflow) = numerator
            .multipliedReportingOverflow(by: leftMultiplier)
        let (rightNumerator, rightOverflow) = other.numerator
            .multipliedReportingOverflow(by: rightMultiplier)
        let (resultNumerator, additionOverflow) = leftNumerator
            .addingReportingOverflow(rightNumerator)
        let (resultDenominator, denominatorOverflow) = denominator
            .multipliedReportingOverflow(by: leftMultiplier)
        guard !leftOverflow,
              !rightOverflow,
              !additionOverflow,
              !denominatorOverflow else {
            throw RationalPresentationGeometryV4Error.arithmeticOverflow
        }
        return try ExactRationalV4(resultNumerator, resultDenominator)
    }

    func subtracting(_ other: ExactRationalV4) throws -> ExactRationalV4 {
        try adding(other.negated())
    }

    func multiplied(by other: ExactRationalV4) throws -> ExactRationalV4 {
        let leftCancellation = Self.greatestCommonDivisor(
            numerator.magnitude,
            UInt64(other.denominator)
        )
        let rightCancellation = Self.greatestCommonDivisor(
            other.numerator.magnitude,
            UInt64(denominator)
        )

        let reducedLeftNumerator = numerator / Int64(leftCancellation)
        let reducedRightNumerator = other.numerator / Int64(rightCancellation)
        let reducedLeftDenominator = denominator / Int64(rightCancellation)
        let reducedRightDenominator = other.denominator / Int64(leftCancellation)
        let (resultNumerator, numeratorOverflow) = reducedLeftNumerator
            .multipliedReportingOverflow(by: reducedRightNumerator)
        let (resultDenominator, denominatorOverflow) = reducedLeftDenominator
            .multipliedReportingOverflow(by: reducedRightDenominator)
        guard !numeratorOverflow, !denominatorOverflow else {
            throw RationalPresentationGeometryV4Error.arithmeticOverflow
        }
        return try ExactRationalV4(resultNumerator, resultDenominator)
    }

    func divided(by other: ExactRationalV4) throws -> ExactRationalV4 {
        guard !other.isZero else {
            throw RationalPresentationGeometryV4Error.divisionByZero
        }
        let reciprocal = try ExactRationalV4(
            other.denominator,
            other.numerator
        )
        return try multiplied(by: reciprocal)
    }

    func compared(to other: ExactRationalV4) throws -> ExactRationalOrderingV4 {
        if self < other {
            return .ascending
        }
        if self > other {
            return .descending
        }
        return .same
    }

    /// Exact ordering compares the full-width cross products, avoiding both
    /// floating-point drift and Int64 overflow at canonicalization boundaries.
    static func < (lhs: ExactRationalV4, rhs: ExactRationalV4) -> Bool {
        if lhs.numerator < 0, rhs.numerator >= 0 {
            return true
        }
        if lhs.numerator >= 0, rhs.numerator < 0 {
            return false
        }

        let leftProduct = lhs.numerator.magnitude.multipliedFullWidth(
            by: UInt64(rhs.denominator)
        )
        let rightProduct = rhs.numerator.magnitude.multipliedFullWidth(
            by: UInt64(lhs.denominator)
        )
        let magnitudeIsLess: Bool
        let magnitudesAreEqual: Bool
        if leftProduct.high != rightProduct.high {
            magnitudeIsLess = leftProduct.high < rightProduct.high
            magnitudesAreEqual = false
        } else {
            magnitudeIsLess = leftProduct.low < rightProduct.low
            magnitudesAreEqual = leftProduct.low == rightProduct.low
        }
        guard !magnitudesAreEqual else {
            return false
        }
        return lhs.numerator < 0 ? !magnitudeIsLess : magnitudeIsLess
    }

    fileprivate init(normalizedNumerator: Int64, denominator: Int64) {
        self.numerator = normalizedNumerator
        self.denominator = denominator
    }

    private static func greatestCommonDivisor(
        _ first: UInt64,
        _ second: UInt64
    ) -> UInt64 {
        var left = first
        var right = second
        while right != 0 {
            let remainder = left % right
            left = right
            right = remainder
        }
        return left
    }

    private static func signedValue(
        magnitude: UInt64,
        isNegative: Bool
    ) throws -> Int64 {
        if isNegative {
            let minimumMagnitude = Int64.min.magnitude
            if magnitude == minimumMagnitude {
                return Int64.min
            }
            guard magnitude <= UInt64(Int64.max) else {
                throw RationalPresentationGeometryV4Error.arithmeticOverflow
            }
            return -Int64(magnitude)
        }
        guard magnitude <= UInt64(Int64.max) else {
            throw RationalPresentationGeometryV4Error.arithmeticOverflow
        }
        return Int64(magnitude)
    }
}

enum MediaClockConversionV4Error: Error, Equatable, Sendable {
    case nonNumericTime
    case roundedTime
    case nonzeroEpoch
    case invalidTimescale(Int32)
    case arithmeticOverflow
    case exactValueNotRepresentable
    case admittedBoundaryNotExactlyRepresentable
    case admittedBoundaryNotAdjacent
}

enum MediaClockQuantizationV4: Equatable, Sendable {
    case exact
    case admittedFloor
    case admittedCeiling
}

struct MediaClockConversionV4: Equatable, Sendable {
    let time: CMTime
    let quantization: MediaClockQuantizationV4
}

/// One fail-closed policy for projecting exact media rationals onto a declared
/// source, writer, or encoder clock. Exact values stay exact. An
/// incommensurate value may use only an explicitly admitted boundary that is
/// the immediately adjacent floor or ceiling tick on that clock.
enum MediaClockConversionPolicyV4 {
    static func exactRational(_ time: CMTime) throws -> ExactRationalV4 {
        guard time.isNumeric else {
            throw MediaClockConversionV4Error.nonNumericTime
        }
        guard !time.flags.contains(.hasBeenRounded) else {
            throw MediaClockConversionV4Error.roundedTime
        }
        guard time.epoch == 0 else {
            throw MediaClockConversionV4Error.nonzeroEpoch
        }
        guard time.timescale > 0 else {
            throw MediaClockConversionV4Error.invalidTimescale(
                time.timescale
            )
        }
        return try ExactRationalV4(
            time.value,
            Int64(time.timescale)
        )
    }

    static func exact(
        _ value: ExactRationalV4,
        timescale: CMTimeScale
    ) throws -> MediaClockConversionV4 {
        guard timescale > 0 else {
            throw MediaClockConversionV4Error.invalidTimescale(timescale)
        }
        let scale = Int64(timescale)
        guard scale.isMultiple(of: value.denominator) else {
            throw MediaClockConversionV4Error.exactValueNotRepresentable
        }
        let multiplier = scale / value.denominator
        let scaled = value.numerator.multipliedReportingOverflow(
            by: multiplier
        )
        guard !scaled.overflow else {
            throw MediaClockConversionV4Error.arithmeticOverflow
        }
        return MediaClockConversionV4(
            time: CMTime(
                value: scaled.partialValue,
                timescale: timescale
            ),
            quantization: .exact
        )
    }

    static func exact(
        _ time: CMTime,
        timescale: CMTimeScale
    ) throws -> MediaClockConversionV4 {
        try exact(exactRational(time), timescale: timescale)
    }

    static func exactOrAdmittedAdjacent(
        _ value: ExactRationalV4,
        admittedBoundary: CMTime,
        timescale: CMTimeScale
    ) throws -> MediaClockConversionV4 {
        let admittedRational: ExactRationalV4
        do {
            admittedRational = try exactRational(admittedBoundary)
        } catch {
            throw MediaClockConversionV4Error
                .admittedBoundaryNotExactlyRepresentable
        }
        let admitted: MediaClockConversionV4
        do {
            admitted = try exact(
                admittedRational,
                timescale: timescale
            )
        } catch {
            throw MediaClockConversionV4Error
                .admittedBoundaryNotExactlyRepresentable
        }

        if let exactConversion = try? exact(
            value,
            timescale: timescale
        ) {
            guard admitted.time.value == exactConversion.time.value else {
                throw MediaClockConversionV4Error
                    .admittedBoundaryNotAdjacent
            }
            return exactConversion
        }

        let adjacent = try adjacentTicks(for: value, timescale: timescale)
        if admitted.time.value == adjacent.floor {
            return MediaClockConversionV4(
                time: admitted.time,
                quantization: .admittedFloor
            )
        }
        if admitted.time.value == adjacent.ceiling {
            return MediaClockConversionV4(
                time: admitted.time,
                quantization: .admittedCeiling
            )
        }
        throw MediaClockConversionV4Error.admittedBoundaryNotAdjacent
    }

    static func exactOrAdmittedAdjacent(
        _ time: CMTime,
        admittedBoundary: CMTime,
        timescale: CMTimeScale
    ) throws -> MediaClockConversionV4 {
        try exactOrAdmittedAdjacent(
            exactRational(time),
            admittedBoundary: admittedBoundary,
            timescale: timescale
        )
    }

    static func isExactOrAdjacentClockQuantization(
        _ observed: CMTime,
        of exact: CMTime
    ) -> Bool {
        guard observed.isNumeric,
              exact.isNumeric,
              observed.timescale > 0,
              observed.epoch == exact.epoch,
              !exact.flags.contains(.hasBeenRounded),
              let exactRational = try? self.exactRational(exact),
              let observedRational = try? ExactRationalV4(
                  observed.value,
                  Int64(observed.timescale)
              ),
              let observedOnClock = try? self.exact(
                  observedRational,
                  timescale: observed.timescale
              ) else {
            return false
        }
        if let exactOnClock = try? self.exact(
            exactRational,
            timescale: observed.timescale
        ) {
            return observedOnClock.time.value == exactOnClock.time.value
        }
        guard let adjacent = try? adjacentTicks(
            for: exactRational,
            timescale: observed.timescale
        ) else {
            return false
        }
        return observedOnClock.time.value == adjacent.floor
            || observedOnClock.time.value == adjacent.ceiling
    }

    private static func adjacentTicks(
        for value: ExactRationalV4,
        timescale: CMTimeScale
    ) throws -> (floor: Int64, ceiling: Int64) {
        guard timescale > 0 else {
            throw MediaClockConversionV4Error.invalidTimescale(timescale)
        }
        let scaled = value.numerator.multipliedReportingOverflow(
            by: Int64(timescale)
        )
        guard !scaled.overflow else {
            throw MediaClockConversionV4Error.arithmeticOverflow
        }
        let division = scaled.partialValue.quotientAndRemainder(
            dividingBy: value.denominator
        )
        guard division.remainder != 0 else {
            return (division.quotient, division.quotient)
        }
        if division.remainder > 0 {
            let ceiling = division.quotient.addingReportingOverflow(1)
            guard !ceiling.overflow else {
                throw MediaClockConversionV4Error.arithmeticOverflow
            }
            return (division.quotient, ceiling.partialValue)
        }
        let floor = division.quotient.subtractingReportingOverflow(1)
        guard !floor.overflow else {
            throw MediaClockConversionV4Error.arithmeticOverflow
        }
        return (floor.partialValue, division.quotient)
    }
}

struct RationalPointV4: Equatable, Hashable, Sendable {
    let x: ExactRationalV4
    let y: ExactRationalV4
}

struct RationalSizeV4: Equatable, Hashable, Sendable {
    let width: ExactRationalV4
    let height: ExactRationalV4

    init(width: ExactRationalV4, height: ExactRationalV4) throws {
        guard width.isPositive, height.isPositive else {
            throw RationalPresentationGeometryV4Error.nonPositiveCleanAperture
        }
        self.width = width
        self.height = height
    }
}

struct RationalRectV4: Equatable, Hashable, Sendable {
    let origin: RationalPointV4
    let size: RationalSizeV4

    var minX: ExactRationalV4 { origin.x }
    var minY: ExactRationalV4 { origin.y }

    func maxX() throws -> ExactRationalV4 {
        try origin.x.adding(size.width)
    }

    func maxY() throws -> ExactRationalV4 {
        try origin.y.adding(size.height)
    }
}

/// Exact form of the clean-aperture width, height, and center offsets stored by
/// Core Media. Positive center offsets move right/down in coded-pixel space.
struct CleanApertureV4: Equatable, Hashable, Sendable {
    let width: ExactRationalV4
    let height: ExactRationalV4
    let horizontalOffset: ExactRationalV4
    let verticalOffset: ExactRationalV4

    init(
        width: ExactRationalV4,
        height: ExactRationalV4,
        horizontalOffset: ExactRationalV4 = .zero,
        verticalOffset: ExactRationalV4 = .zero
    ) throws {
        guard width.isPositive, height.isPositive else {
            throw RationalPresentationGeometryV4Error.nonPositiveCleanAperture
        }
        self.width = width
        self.height = height
        self.horizontalOffset = horizontalOffset
        self.verticalOffset = verticalOffset
    }

    static func fullRaster(width: Int64, height: Int64) throws -> CleanApertureV4 {
        try CleanApertureV4(
            width: ExactRationalV4(width),
            height: ExactRationalV4(height)
        )
    }

    func rect(codedWidth: Int64, codedHeight: Int64) throws -> RationalRectV4 {
        guard codedWidth > 0, codedHeight > 0 else {
            throw RationalPresentationGeometryV4Error.nonPositiveCodedRaster(
                width: codedWidth,
                height: codedHeight
            )
        }
        let codedWidthRational = try ExactRationalV4(codedWidth)
        let codedHeightRational = try ExactRationalV4(codedHeight)
        let two = try ExactRationalV4(2)
        let horizontalMargin = try codedWidthRational
            .subtracting(width)
            .divided(by: two)
        let verticalMargin = try codedHeightRational
            .subtracting(height)
            .divided(by: two)
        let origin = RationalPointV4(
            x: try horizontalMargin.adding(horizontalOffset),
            y: try verticalMargin.adding(verticalOffset)
        )
        return RationalRectV4(
            origin: origin,
            size: try RationalSizeV4(width: width, height: height)
        )
    }
}

struct SampleAspectRatioV4: Equatable, Hashable, Sendable {
    let horizontalSpacing: Int64
    let verticalSpacing: Int64
    let horizontalScale: ExactRationalV4

    init(horizontalSpacing: Int64, verticalSpacing: Int64) throws {
        guard horizontalSpacing > 0, verticalSpacing > 0 else {
            throw RationalPresentationGeometryV4Error.invalidSampleAspectRatio(
                horizontalSpacing: horizontalSpacing,
                verticalSpacing: verticalSpacing
            )
        }
        let scale = try ExactRationalV4(horizontalSpacing, verticalSpacing)
        self.horizontalSpacing = scale.numerator
        self.verticalSpacing = scale.denominator
        self.horizontalScale = scale
    }

    static let square = SampleAspectRatioV4(
        normalizedHorizontalSpacing: 1,
        verticalSpacing: 1
    )

    private init(
        normalizedHorizontalSpacing: Int64,
        verticalSpacing: Int64
    ) {
        self.horizontalSpacing = normalizedHorizontalSpacing
        self.verticalSpacing = verticalSpacing
        self.horizontalScale = .one
    }
}

/// Exact affine transform using the Core Graphics coefficient convention:
/// x' = a*x + c*y + tx and y' = b*x + d*y + ty.
struct RationalAffineTransformV4: Equatable, Hashable, Sendable {
    let a: ExactRationalV4
    let b: ExactRationalV4
    let c: ExactRationalV4
    let d: ExactRationalV4
    let tx: ExactRationalV4
    let ty: ExactRationalV4

    static let identity = RationalAffineTransformV4(
        a: .one,
        b: .zero,
        c: .zero,
        d: .one,
        tx: .zero,
        ty: .zero
    )

    static func translation(
        x: ExactRationalV4,
        y: ExactRationalV4
    ) -> RationalAffineTransformV4 {
        RationalAffineTransformV4(
            a: .one,
            b: .zero,
            c: .zero,
            d: .one,
            tx: x,
            ty: y
        )
    }

    static func scale(
        x: ExactRationalV4,
        y: ExactRationalV4
    ) -> RationalAffineTransformV4 {
        RationalAffineTransformV4(
            a: x,
            b: .zero,
            c: .zero,
            d: y,
            tx: .zero,
            ty: .zero
        )
    }

    static func quarterTurn(
        _ turnsClockwise: Int,
        translationX: Int64 = 0,
        translationY: Int64 = 0
    ) -> RationalAffineTransformV4 {
        let normalizedTurns = ((turnsClockwise % 4) + 4) % 4
        let linear: (
            ExactRationalV4,
            ExactRationalV4,
            ExactRationalV4,
            ExactRationalV4
        )
        switch normalizedTurns {
        case 0:
            linear = (.one, .zero, .zero, .one)
        case 1:
            linear = (.zero, .one, .negativeOne, .zero)
        case 2:
            linear = (.negativeOne, .zero, .zero, .negativeOne)
        default:
            linear = (.zero, .negativeOne, .one, .zero)
        }
        return RationalAffineTransformV4(
            a: linear.0,
            b: linear.1,
            c: linear.2,
            d: linear.3,
            tx: ExactRationalV4(
                normalizedNumerator: translationX,
                denominator: 1
            ),
            ty: ExactRationalV4(
                normalizedNumerator: translationY,
                denominator: 1
            )
        )
    }

    /// Returns `next ∘ self`: points are transformed by `self`, then `next`.
    func followed(
        by next: RationalAffineTransformV4
    ) throws -> RationalAffineTransformV4 {
        RationalAffineTransformV4(
            a: try next.a.multiplied(by: a).adding(
                next.c.multiplied(by: b)
            ),
            b: try next.b.multiplied(by: a).adding(
                next.d.multiplied(by: b)
            ),
            c: try next.a.multiplied(by: c).adding(
                next.c.multiplied(by: d)
            ),
            d: try next.b.multiplied(by: c).adding(
                next.d.multiplied(by: d)
            ),
            tx: try next.a.multiplied(by: tx)
                .adding(next.c.multiplied(by: ty))
                .adding(next.tx),
            ty: try next.b.multiplied(by: tx)
                .adding(next.d.multiplied(by: ty))
                .adding(next.ty)
        )
    }

    func applying(to point: RationalPointV4) throws -> RationalPointV4 {
        RationalPointV4(
            x: try a.multiplied(by: point.x)
                .adding(c.multiplied(by: point.y))
                .adding(tx),
            y: try b.multiplied(by: point.x)
                .adding(d.multiplied(by: point.y))
                .adding(ty)
        )
    }

    fileprivate var hasIntegralTranslation: Bool {
        tx.isInteger && ty.isInteger
    }

    fileprivate var hasSignedAxisLinearPart: Bool {
        let values = [a, b, c, d]
        guard values.allSatisfy({
            $0 == .zero || $0 == .one || $0 == .negativeOne
        }) else {
            return false
        }
        let firstRowCount = [a, c].filter { $0 != .zero }.count
        let secondRowCount = [b, d].filter { $0 != .zero }.count
        let firstColumnCount = [a, b].filter { $0 != .zero }.count
        let secondColumnCount = [c, d].filter { $0 != .zero }.count
        return firstRowCount == 1
            && secondRowCount == 1
            && firstColumnCount == 1
            && secondColumnCount == 1
    }
}

/// Canonical coded-pixel geometry. The composed transform order is fixed as
/// clean-aperture crop, horizontal SAR correction, preferred display transform,
/// then requested output scale.
struct RationalPresentationGeometryV4: Equatable, Hashable, Sendable {
    let codedWidth: Int64
    let codedHeight: Int64
    let cleanAperture: CleanApertureV4
    let sampleAspectRatio: SampleAspectRatioV4
    let preferredTransform: RationalAffineTransformV4

    init(
        codedWidth: Int64,
        codedHeight: Int64,
        cleanAperture: CleanApertureV4,
        sampleAspectRatio: SampleAspectRatioV4 = .square,
        preferredTransform: RationalAffineTransformV4 = .identity
    ) throws {
        guard codedWidth > 0, codedHeight > 0 else {
            throw RationalPresentationGeometryV4Error.nonPositiveCodedRaster(
                width: codedWidth,
                height: codedHeight
            )
        }
        guard preferredTransform.hasSignedAxisLinearPart else {
            throw RationalPresentationGeometryV4Error
                .unsupportedPreferredLinearTransform
        }
        guard preferredTransform.hasIntegralTranslation else {
            throw RationalPresentationGeometryV4Error
                .fractionalPreferredTranslation
        }

        let cleanRect = try cleanAperture.rect(
            codedWidth: codedWidth,
            codedHeight: codedHeight
        )
        let codedWidthRational = try ExactRationalV4(codedWidth)
        let codedHeightRational = try ExactRationalV4(codedHeight)
        guard try cleanRect.minX.compared(to: .zero) != .ascending,
              try cleanRect.minY.compared(to: .zero) != .ascending,
              try cleanRect.maxX().compared(to: codedWidthRational)
                != .descending,
              try cleanRect.maxY().compared(to: codedHeightRational)
                != .descending else {
            throw RationalPresentationGeometryV4Error
                .cleanApertureOutsideCodedRaster
        }

        self.codedWidth = codedWidth
        self.codedHeight = codedHeight
        self.cleanAperture = cleanAperture
        self.sampleAspectRatio = sampleAspectRatio
        self.preferredTransform = preferredTransform
    }

    func cleanApertureRect() throws -> RationalRectV4 {
        try cleanAperture.rect(
            codedWidth: codedWidth,
            codedHeight: codedHeight
        )
    }

    func composedTransform(
        outputScaleX: ExactRationalV4 = .one,
        outputScaleY: ExactRationalV4 = .one
    ) throws -> RationalAffineTransformV4 {
        guard outputScaleX.isPositive, outputScaleY.isPositive else {
            throw RationalPresentationGeometryV4Error.nonPositiveOutputScale
        }
        let apertureRect = try cleanApertureRect()
        let crop = RationalAffineTransformV4.translation(
            x: try apertureRect.origin.x.negated(),
            y: try apertureRect.origin.y.negated()
        )
        let sar = RationalAffineTransformV4.scale(
            x: sampleAspectRatio.horizontalScale,
            y: .one
        )
        let outputScale = RationalAffineTransformV4.scale(
            x: outputScaleX,
            y: outputScaleY
        )
        return try crop
            .followed(by: sar)
            .followed(by: preferredTransform)
            .followed(by: outputScale)
    }

    func presentationBounds(
        outputScaleX: ExactRationalV4 = .one,
        outputScaleY: ExactRationalV4 = .one
    ) throws -> RationalRectV4 {
        let apertureRect = try cleanApertureRect()
        let transform = try composedTransform(
            outputScaleX: outputScaleX,
            outputScaleY: outputScaleY
        )
        let maxX = try apertureRect.maxX()
        let maxY = try apertureRect.maxY()
        let transformedCorners = try [
            RationalPointV4(x: apertureRect.minX, y: apertureRect.minY),
            RationalPointV4(x: maxX, y: apertureRect.minY),
            RationalPointV4(x: apertureRect.minX, y: maxY),
            RationalPointV4(x: maxX, y: maxY)
        ].map(transform.applying)

        let xBounds = try Self.extrema(transformedCorners.map(\.x))
        let yBounds = try Self.extrema(transformedCorners.map(\.y))
        return RationalRectV4(
            origin: RationalPointV4(x: xBounds.minimum, y: yBounds.minimum),
            size: try RationalSizeV4(
                width: xBounds.maximum.subtracting(xBounds.minimum),
                height: yBounds.maximum.subtracting(yBounds.minimum)
            )
        )
    }

    private static func extrema(
        _ values: [ExactRationalV4]
    ) throws -> (minimum: ExactRationalV4, maximum: ExactRationalV4) {
        guard var minimum = values.first, var maximum = values.first else {
            throw RationalPresentationGeometryV4Error.arithmeticOverflow
        }
        for value in values.dropFirst() {
            if try value.compared(to: minimum) == .ascending {
                minimum = value
            }
            if try value.compared(to: maximum) == .descending {
                maximum = value
            }
        }
        return (minimum, maximum)
    }
}
