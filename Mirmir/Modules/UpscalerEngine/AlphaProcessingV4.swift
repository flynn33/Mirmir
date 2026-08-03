import Foundation

enum AlphaProcessingV4Error: Error, Equatable, Sendable {
    case invalidSignalBitDepth(Int)
    case unsupportedColorDomain(AlphaColorDomainV4)
    case componentOutOfRange(
        component: AlphaComponentV4,
        value: UInt16,
        maximum: UInt16
    )
    case invalidPremultipliedComponent(
        component: AlphaComponentV4,
        value: UInt16,
        alpha: UInt16
    )
    case zeroAlphaColorRejected(red: UInt16, green: UInt16, blue: UInt16)
    case hiddenColorCannotBePreservedInPremultipliedOutput
    case zeroAlphaDivision
    case arithmeticOverflow
}

enum AlphaAssociationV4: String, Hashable, Sendable {
    case straight
    case premultiplied
}

enum ZeroAlphaPolicyV4: String, Hashable, Sendable {
    /// Canonicalize all zero-alpha RGB components to zero.
    case clearColor

    /// Preserve hidden RGB only when the destination remains straight alpha.
    case preserveStraightColor

    /// Accept zero alpha only when all RGB components are already zero.
    case rejectNonZeroColor
}

enum AlphaColorDomainV4: String, Hashable, Sendable {
    /// Full-range fixed-point RGB codes. This is the only scalar V4 alpha domain.
    case fullRangeRGB

    /// Requires a separately planned, manifest-bound YCbCr-to-RGB transform.
    case encodedYCbCr
}

enum AlphaRoundingRuleV4: String, Hashable, Sendable {
    case nearestTiesToEven
}

enum AlphaComponentV4: String, Hashable, Sendable {
    case red
    case green
    case blue
    case alpha
}

struct AlphaSampleV4: Equatable, Hashable, Sendable {
    let red: UInt16
    let green: UInt16
    let blue: UInt16
    let alpha: UInt16
}

/// Immutable execution contract. Association and color domain are independent
/// from the physical pixel layout and must be resolved before this plan exists.
struct AlphaProcessingPlanV4: Equatable, Hashable, Sendable {
    let sourceAssociation: AlphaAssociationV4
    let destinationAssociation: AlphaAssociationV4
    let zeroAlphaPolicy: ZeroAlphaPolicyV4
    let colorDomain: AlphaColorDomainV4
    let signalBitDepth: Int
    let fullScale: UInt16
    let roundingRule: AlphaRoundingRuleV4

    init(
        sourceAssociation: AlphaAssociationV4,
        destinationAssociation: AlphaAssociationV4,
        zeroAlphaPolicy: ZeroAlphaPolicyV4,
        colorDomain: AlphaColorDomainV4,
        signalBitDepth: Int,
        roundingRule: AlphaRoundingRuleV4 = .nearestTiesToEven
    ) throws {
        guard (1...16).contains(signalBitDepth) else {
            throw AlphaProcessingV4Error.invalidSignalBitDepth(signalBitDepth)
        }
        guard colorDomain == .fullRangeRGB else {
            throw AlphaProcessingV4Error.unsupportedColorDomain(colorDomain)
        }
        self.sourceAssociation = sourceAssociation
        self.destinationAssociation = destinationAssociation
        self.zeroAlphaPolicy = zeroAlphaPolicy
        self.colorDomain = colorDomain
        self.signalBitDepth = signalBitDepth
        self.fullScale = UInt16((UInt32(1) << UInt32(signalBitDepth)) - 1)
        self.roundingRule = roundingRule
    }
}

enum AlphaSampleMathV4 {
    static func premultiply(
        straight: UInt16,
        alpha: UInt16,
        fullScale: UInt16,
        roundingRule: AlphaRoundingRuleV4 = .nearestTiesToEven
    ) throws -> UInt16 {
        guard fullScale > 0,
              straight <= fullScale,
              alpha <= fullScale else {
            throw AlphaProcessingV4Error.arithmeticOverflow
        }
        return try roundedProductQuotient(
            multiplicand: straight,
            multiplier: alpha,
            divisor: fullScale,
            roundingRule: roundingRule
        )
    }

    static func unpremultiply(
        premultiplied: UInt16,
        alpha: UInt16,
        fullScale: UInt16,
        roundingRule: AlphaRoundingRuleV4 = .nearestTiesToEven
    ) throws -> UInt16 {
        guard fullScale > 0,
              alpha <= fullScale,
              premultiplied <= alpha else {
            throw AlphaProcessingV4Error.arithmeticOverflow
        }
        guard alpha > 0 else {
            throw AlphaProcessingV4Error.zeroAlphaDivision
        }
        return try roundedProductQuotient(
            multiplicand: premultiplied,
            multiplier: fullScale,
            divisor: alpha,
            roundingRule: roundingRule
        )
    }

    private static func roundedProductQuotient(
        multiplicand: UInt16,
        multiplier: UInt16,
        divisor: UInt16,
        roundingRule: AlphaRoundingRuleV4
    ) throws -> UInt16 {
        guard divisor > 0 else {
            throw AlphaProcessingV4Error.zeroAlphaDivision
        }
        let numerator = UInt64(multiplicand) * UInt64(multiplier)
        let denominator = UInt64(divisor)
        let quotient = numerator / denominator
        let remainder = numerator % denominator

        let rounded: UInt64
        switch roundingRule {
        case .nearestTiesToEven:
            let doubledRemainder = remainder * 2
            if doubledRemainder < denominator {
                rounded = quotient
            } else if doubledRemainder > denominator {
                rounded = quotient + 1
            } else {
                rounded = quotient.isMultiple(of: 2)
                    ? quotient
                    : quotient + 1
            }
        }
        guard rounded <= UInt64(UInt16.max) else {
            throw AlphaProcessingV4Error.arithmeticOverflow
        }
        return UInt16(rounded)
    }
}

enum AlphaProcessingV4 {
    static func process(
        _ sample: AlphaSampleV4,
        using plan: AlphaProcessingPlanV4
    ) throws -> AlphaSampleV4 {
        try validateComponents(sample, maximum: plan.fullScale)
        if plan.sourceAssociation == .premultiplied {
            try validatePremultiplied(sample)
        }

        if sample.alpha == 0 {
            return try resolveZeroAlpha(sample, using: plan)
        }
        if plan.sourceAssociation == plan.destinationAssociation {
            return sample
        }

        switch (plan.sourceAssociation, plan.destinationAssociation) {
        case (.straight, .premultiplied):
            return AlphaSampleV4(
                red: try AlphaSampleMathV4.premultiply(
                    straight: sample.red,
                    alpha: sample.alpha,
                    fullScale: plan.fullScale,
                    roundingRule: plan.roundingRule
                ),
                green: try AlphaSampleMathV4.premultiply(
                    straight: sample.green,
                    alpha: sample.alpha,
                    fullScale: plan.fullScale,
                    roundingRule: plan.roundingRule
                ),
                blue: try AlphaSampleMathV4.premultiply(
                    straight: sample.blue,
                    alpha: sample.alpha,
                    fullScale: plan.fullScale,
                    roundingRule: plan.roundingRule
                ),
                alpha: sample.alpha
            )
        case (.premultiplied, .straight):
            return AlphaSampleV4(
                red: try AlphaSampleMathV4.unpremultiply(
                    premultiplied: sample.red,
                    alpha: sample.alpha,
                    fullScale: plan.fullScale,
                    roundingRule: plan.roundingRule
                ),
                green: try AlphaSampleMathV4.unpremultiply(
                    premultiplied: sample.green,
                    alpha: sample.alpha,
                    fullScale: plan.fullScale,
                    roundingRule: plan.roundingRule
                ),
                blue: try AlphaSampleMathV4.unpremultiply(
                    premultiplied: sample.blue,
                    alpha: sample.alpha,
                    fullScale: plan.fullScale,
                    roundingRule: plan.roundingRule
                ),
                alpha: sample.alpha
            )
        case (.straight, .straight), (.premultiplied, .premultiplied):
            return sample
        }
    }

    private static func validateComponents(
        _ sample: AlphaSampleV4,
        maximum: UInt16
    ) throws {
        let components: [(AlphaComponentV4, UInt16)] = [
            (.red, sample.red),
            (.green, sample.green),
            (.blue, sample.blue),
            (.alpha, sample.alpha)
        ]
        for (component, value) in components where value > maximum {
            throw AlphaProcessingV4Error.componentOutOfRange(
                component: component,
                value: value,
                maximum: maximum
            )
        }
    }

    private static func validatePremultiplied(_ sample: AlphaSampleV4) throws {
        let components: [(AlphaComponentV4, UInt16)] = [
            (.red, sample.red),
            (.green, sample.green),
            (.blue, sample.blue)
        ]
        for (component, value) in components where value > sample.alpha {
            throw AlphaProcessingV4Error.invalidPremultipliedComponent(
                component: component,
                value: value,
                alpha: sample.alpha
            )
        }
    }

    private static func resolveZeroAlpha(
        _ sample: AlphaSampleV4,
        using plan: AlphaProcessingPlanV4
    ) throws -> AlphaSampleV4 {
        switch plan.zeroAlphaPolicy {
        case .clearColor:
            return AlphaSampleV4(red: 0, green: 0, blue: 0, alpha: 0)
        case .preserveStraightColor:
            guard plan.destinationAssociation == .straight else {
                throw AlphaProcessingV4Error
                    .hiddenColorCannotBePreservedInPremultipliedOutput
            }
            return sample
        case .rejectNonZeroColor:
            guard sample.red == 0, sample.green == 0, sample.blue == 0 else {
                throw AlphaProcessingV4Error.zeroAlphaColorRejected(
                    red: sample.red,
                    green: sample.green,
                    blue: sample.blue
                )
            }
            return sample
        }
    }
}
