import Foundation

extension ASHSpatialPhaseV2 {
    static func sourceAlignedDevelopment(
        horizontalIndex: Int,
        verticalIndex: Int,
        route: ASHSpatialRouteV2
    ) throws -> ASHSpatialPhaseV2 {
        guard (0..<route.scaleNumerator).contains(horizontalIndex),
              (0..<route.scaleNumerator).contains(verticalIndex) else {
            throw ASHSpatialDispatchV2Error.invalidPhase(
                route: route,
                horizontal: horizontalIndex,
                vertical: verticalIndex
            )
        }
        let horizontalCoordinate = ASHSpatialRationalCoordinateV2(
            numerator: Int64(horizontalIndex * route.scaleDenominator),
            denominator: Int64(route.scaleNumerator)
        )
        let verticalCoordinate = ASHSpatialRationalCoordinateV2(
            numerator: Int64(verticalIndex * route.scaleDenominator),
            denominator: Int64(route.scaleNumerator)
        )
        return ASHSpatialPhaseV2(
            horizontal: ASHSpatialPhaseComponentV2(coordinate: horizontalCoordinate),
            vertical: ASHSpatialPhaseComponentV2(coordinate: verticalCoordinate)
        )
    }
}

enum ASHSpatialDispatchV2Error: Error, Equatable, Sendable {
    case invalidPhase(route: ASHSpatialRouteV2, horizontal: Int, vertical: Int)
    case unsupportedPhaseComponent(numerator: Int64, denominator: Int64)
    case affineRecoveryFailed
}

struct ASHSpatialDispatchV2: Equatable, Sendable {
    let sourceState: ASHState
    let selectorState: ASHState
    let parityWasRecomputed: Bool
    let primaryDecodedMessage: ASHMessage
    let secondaryDecodedMessage: ASHMessage?
    let primaryAffineState: ASHState
    let secondaryAffineState: ASHState?
    let primaryWeight: Double
    let secondaryWeight: Double
    let margin: Double

    var operatorEvaluationCount: Int { secondaryDecodedMessage == nil ? 1 : 2 }
}

/// Disposable P05 selector used to prove state causality before the calibrated
/// state/phase LUT is compiled and hash-locked in P06.
enum ASHSpatialDevelopmentSelectorV2 {
    static let confidenceThreshold = 0.55

    static func dispatch(
        state: ASHState,
        phase: ASHSpatialPhaseV2,
        stateInputEnabled: Bool = true
    ) throws -> ASHSpatialDispatchV2 {
        let normalized = try normalizedState(state)
        let selectorState = stateInputEnabled
            ? normalized.state
            : try ASHState(payloadBits: Array(repeating: 0, count: ASHState.payloadBitCount))
        let message = try descriptorMessage(state: selectorState, phase: phase)
        let margin = confidenceMargin(state: selectorState)
        let secondary: ASHMessage?
        if margin >= confidenceThreshold {
            secondary = nil
        } else {
            secondary = messageWithToggledKernel(message)
        }
        return try makeDispatch(
            anchor: normalized.state,
            selectorState: selectorState,
            parityWasRecomputed: normalized.recomputed,
            primary: message,
            secondary: secondary,
            margin: margin
        )
    }

    private static func normalizedState(_ state: ASHState) throws -> (state: ASHState, recomputed: Bool) {
        guard !state.hasValidIntegrity else { return (state, false) }
        return (try ASHState(payloadBits: Array(state.bits.prefix(ASHState.payloadBitCount))), true)
    }

    private static func descriptorMessage(
        state: ASHState,
        phase: ASHSpatialPhaseV2
    ) throws -> ASHMessage {
        let orientationLow = state.bit(coordinate: 1)
        let orientationHigh = state.bit(coordinate: 2)
        let edgePresent = state.bit(coordinate: 3)
        let coherent = state.bit(coordinate: 4)
        let texture = state.bit(coordinate: 5)
        let risk = state.bit(coordinate: 6)
        let chromaAligned = state.bit(coordinate: 8)
        let orientationPhase = orientationLow ^ orientationHigh

        let kernel = texture
            ^ (edgePresent & orientationPhase)
            ^ (try phaseInfluence(phase))
        let anisotropic = edgePresent & coherent
        let detail = edgePresent & (1 - risk) & texture
        let relaxed = chromaAligned & (1 - risk)
        let raw = UInt8(kernel | (anisotropic << 1) | (detail << 2) | (relaxed << 3))
        return ASHMessage(validatedRawValue: raw)
    }

    private static func phaseInfluence(_ phase: ASHSpatialPhaseV2) throws -> Int {
        func halfCycle(_ component: ASHSpatialPhaseComponentV2) throws -> Int {
            let doubledNumerator = component.numerator.multipliedReportingOverflow(by: 2)
            guard component.denominator > 0,
                  component.numerator >= 0,
                  component.numerator < component.denominator,
                  !doubledNumerator.overflow else {
                throw ASHSpatialDispatchV2Error.unsupportedPhaseComponent(
                    numerator: component.numerator,
                    denominator: component.denominator
                )
            }
            return doubledNumerator.partialValue < component.denominator ? 0 : 1
        }
        return try halfCycle(phase.horizontal) ^ halfCycle(phase.vertical)
    }

    private static func confidenceMargin(state: ASHState) -> Double {
        let edgePresent = state.bit(coordinate: 3)
        let coherent = state.bit(coordinate: 4)
        let risk = state.bit(coordinate: 6)
        let chromaAligned = state.bit(coordinate: 8)
        if edgePresent == 1, coherent == 1, risk == 0, chromaAligned == 1 {
            return 0.75
        }
        return 0.35
    }

    private static func messageWithToggledKernel(_ message: ASHMessage) -> ASHMessage {
        ASHMessage(validatedRawValue: message.rawValue ^ 0b0001)
    }

    private static func makeDispatch(
        anchor: ASHState,
        selectorState: ASHState,
        parityWasRecomputed: Bool,
        primary: ASHMessage,
        secondary: ASHMessage?,
        margin: Double
    ) throws -> ASHSpatialDispatchV2 {
        let primaryAffine = anchor.xor(ASHCode.encode(primary))
        let primaryDecoded = try recoverExactMessage(
            from: primaryAffine,
            anchor: anchor,
            expected: primary
        )
        let secondaryAffine = secondary.map { anchor.xor(ASHCode.encode($0)) }
        let secondaryDecoded: ASHMessage?
        if let secondary, let secondaryAffine {
            secondaryDecoded = try recoverExactMessage(
                from: secondaryAffine,
                anchor: anchor,
                expected: secondary
            )
        } else {
            secondaryDecoded = nil
        }

        let primaryWeight = secondary == nil ? 1.0 : 0.675
        return ASHSpatialDispatchV2(
            sourceState: anchor,
            selectorState: selectorState,
            parityWasRecomputed: parityWasRecomputed,
            primaryDecodedMessage: primaryDecoded,
            secondaryDecodedMessage: secondaryDecoded,
            primaryAffineState: primaryAffine,
            secondaryAffineState: secondaryAffine,
            primaryWeight: primaryWeight,
            secondaryWeight: 1.0 - primaryWeight,
            margin: margin
        )
    }

    private static func recoverExactMessage(
        from affine: ASHState,
        anchor: ASHState,
        expected: ASHMessage
    ) throws -> ASHMessage {
        let decoded = ASHCode.decodeAffine(received: affine, anchor: anchor)
        guard decoded.status == .exact,
              let messageBits = decoded.messageBits,
              let recovered = try? ASHMessage(bits: messageBits),
              recovered == expected else {
            throw ASHSpatialDispatchV2Error.affineRecoveryFailed
        }
        return recovered
    }
}
