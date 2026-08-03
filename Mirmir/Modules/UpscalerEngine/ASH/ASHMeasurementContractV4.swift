import Foundation

enum ASHMeasurementContractV4Error: Error, Equatable, Sendable {
    case normalizedValueOutOfRange(UInt32)
    case invalidRational
    case unsupportedSchemaVersion(UInt16)
    case invalidIdentifier
    case invalidMeasurementRules
    case invalidMeasurementRule(ASHMeasurementCoordinateV4)
    case invalidWindow
    case invalidBorderPolicy
    case invalidColorDomain
    case invalidResetPolicy
    case nonCanonicalContract
    case evidenceProvenanceMismatch
    case invalidPreviousState
    case undeclaredResetTrigger(ASHMeasurementResetTriggerV4)
    case temporalEvidenceMustBeZero(ASHMeasurementResetTriggerV4)
    case invalidSerialization
    case trailingSerializationBytes
}

/// A normalized unsigned Q16 value. Unlike a `UInt16` UNORM, `1.0` is the
/// exact integer 65,536, so threshold arithmetic never needs a floating-point
/// special case.
struct ASHNormalizedQ16V4: Codable, Comparable, Hashable, Sendable {
    static let fractionalBits = 16
    static let scale: UInt32 = 1 << fractionalBits
    static let zero = ASHNormalizedQ16V4(validatedRawValue: 0)
    static let one = ASHNormalizedQ16V4(validatedRawValue: scale)

    let rawValue: UInt32

    init(rawValue: UInt32) throws {
        guard rawValue <= Self.scale else {
            throw ASHMeasurementContractV4Error.normalizedValueOutOfRange(
                rawValue
            )
        }
        self.rawValue = rawValue
    }

    /// Quantizes a nonnegative unit rational using round-to-nearest,
    /// ties-to-even. The full-width product prevents overflow at the API edge.
    init(numerator: UInt64, denominator: UInt64) throws {
        guard denominator != 0, numerator <= denominator else {
            throw ASHMeasurementContractV4Error.invalidRational
        }
        let product = numerator.multipliedFullWidth(by: UInt64(Self.scale))
        guard product.high < denominator else {
            throw ASHMeasurementContractV4Error.invalidRational
        }
        let division = denominator.dividingFullWidth(product)
        var rounded = division.quotient
        let complement = denominator - division.remainder
        if division.remainder > complement
            || (division.remainder == complement && rounded & 1 == 1) {
            rounded += 1
        }
        guard rounded <= UInt64(Self.scale) else {
            throw ASHMeasurementContractV4Error.invalidRational
        }
        self.rawValue = UInt32(rounded)
    }

    fileprivate init(validatedRawValue: UInt32) {
        precondition(validatedRawValue <= Self.scale)
        self.rawValue = validatedRawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(rawValue: container.decode(UInt32.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum ASHMeasurementCoordinateV4: UInt8, CaseIterable, Codable, Sendable {
    case meanLuminance = 1
    case rmsContrast = 2
    case edgeEnergy = 3
    case textureEnergy = 4
    case chromaEnergy = 5
    case horizontalGradientEnergy = 6
    case verticalGradientEnergy = 7
    case temporalChange = 8

    var stableName: String {
        switch self {
        case .meanLuminance: "mean_luminance"
        case .rmsContrast: "rms_contrast"
        case .edgeEnergy: "edge_energy"
        case .textureEnergy: "texture_energy"
        case .chromaEnergy: "chroma_energy"
        case .horizontalGradientEnergy: "horizontal_gradient_energy"
        case .verticalGradientEnergy: "vertical_gradient_energy"
        case .temporalChange: "temporal_change"
        }
    }
}

enum ASHMeasurementRoundingRuleV4: UInt8, Codable, Sendable {
    case nearestTiesToEven = 1
}

struct ASHMeasurementRuleV4: Equatable, Hashable, Sendable {
    let coordinate: ASHMeasurementCoordinateV4
    let threshold: ASHNormalizedQ16V4
    let hysteresis: ASHNormalizedQ16V4

    init(
        coordinate: ASHMeasurementCoordinateV4,
        threshold: ASHNormalizedQ16V4,
        hysteresis: ASHNormalizedQ16V4
    ) throws {
        guard hysteresis.rawValue <= threshold.rawValue,
              threshold.rawValue <= ASHNormalizedQ16V4.scale
                - hysteresis.rawValue else {
            throw ASHMeasurementContractV4Error.invalidMeasurementRule(
                coordinate
            )
        }
        self.coordinate = coordinate
        self.threshold = threshold
        self.hysteresis = hysteresis
    }
}

enum ASHMeasurementWindowAnchorV4: UInt8, Codable, Sendable {
    case sourceTileOrigin = 1
}

enum ASHMeasurementWindowAggregationV4: UInt8, Codable, Sendable {
    case arithmeticMeanOverEverySample = 1
}

struct ASHMeasurementWindowV4: Equatable, Hashable, Sendable {
    let policyID: String
    let width: UInt16
    let height: UInt16
    let horizontalStride: UInt8
    let verticalStride: UInt8
    let anchor: ASHMeasurementWindowAnchorV4
    let aggregation: ASHMeasurementWindowAggregationV4

    init(
        policyID: String,
        width: UInt16,
        height: UInt16,
        horizontalStride: UInt8,
        verticalStride: UInt8,
        anchor: ASHMeasurementWindowAnchorV4,
        aggregation: ASHMeasurementWindowAggregationV4
    ) throws {
        guard Self.validID(policyID),
              width > 0,
              height > 0,
              horizontalStride > 0,
              verticalStride > 0,
              width % UInt16(horizontalStride) == 0,
              height % UInt16(verticalStride) == 0 else {
            throw ASHMeasurementContractV4Error.invalidWindow
        }
        self.policyID = policyID
        self.width = width
        self.height = height
        self.horizontalStride = horizontalStride
        self.verticalStride = verticalStride
        self.anchor = anchor
        self.aggregation = aggregation
    }

    static func validID(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 127
            && value.utf8.allSatisfy { (0x21...0x7e).contains($0) }
    }
}

enum ASHSpatialBorderExtensionV4: UInt8, Codable, Sendable {
    case clampToEdge = 1
}

enum ASHForwardDifferenceBoundaryV4: UInt8, Codable, Sendable {
    case zeroAtPositiveExtent = 1
}

enum ASHTemporalWindowMismatchV4: UInt8, Codable, Sendable {
    case resetRequired = 1
}

struct ASHMeasurementBorderPolicyV4: Equatable, Hashable, Sendable {
    let policyID: String
    let spatialExtension: ASHSpatialBorderExtensionV4
    let forwardDifferenceBoundary: ASHForwardDifferenceBoundaryV4
    let temporalWindowMismatch: ASHTemporalWindowMismatchV4
    let boxBlurRadius: UInt8

    init(
        policyID: String,
        spatialExtension: ASHSpatialBorderExtensionV4,
        forwardDifferenceBoundary: ASHForwardDifferenceBoundaryV4,
        temporalWindowMismatch: ASHTemporalWindowMismatchV4,
        boxBlurRadius: UInt8
    ) throws {
        guard ASHMeasurementWindowV4.validID(policyID), boxBlurRadius == 1 else {
            throw ASHMeasurementContractV4Error.invalidBorderPolicy
        }
        self.policyID = policyID
        self.spatialExtension = spatialExtension
        self.forwardDifferenceBoundary = forwardDifferenceBoundary
        self.temporalWindowMismatch = temporalWindowMismatch
        self.boxBlurRadius = boxBlurRadius
    }
}

enum ASHMeasurementColorSpaceV4: UInt8, Codable, Sendable {
    /// Matches the ASH Model reference formulas: normalized encoded RGB with
    /// BT.709 luma coefficients. Transfer conversion occurs before this
    /// contract and must identify itself as this exact working domain.
    case normalizedEncodedRGBBT709Reference = 1
}

enum ASHMeasurementAlphaHandlingV4: UInt8, Codable, Sendable {
    case ignored = 1
}

enum ASHMeasurementIntegerNormalizationV4: UInt8, Codable, Sendable {
    case declaredSignalMaximum = 1
}

struct ASHMeasurementColorDomainV4: Equatable, Hashable, Sendable {
    let policyID: String
    let colorSpace: ASHMeasurementColorSpaceV4
    let redLumaCoefficient: ASHNormalizedQ16V4
    let greenLumaCoefficient: ASHNormalizedQ16V4
    let blueLumaCoefficient: ASHNormalizedQ16V4
    let alphaHandling: ASHMeasurementAlphaHandlingV4
    let integerNormalization: ASHMeasurementIntegerNormalizationV4

    init(
        policyID: String,
        colorSpace: ASHMeasurementColorSpaceV4,
        redLumaCoefficient: ASHNormalizedQ16V4,
        greenLumaCoefficient: ASHNormalizedQ16V4,
        blueLumaCoefficient: ASHNormalizedQ16V4,
        alphaHandling: ASHMeasurementAlphaHandlingV4,
        integerNormalization: ASHMeasurementIntegerNormalizationV4
    ) throws {
        let sum = UInt64(redLumaCoefficient.rawValue)
            + UInt64(greenLumaCoefficient.rawValue)
            + UInt64(blueLumaCoefficient.rawValue)
        guard ASHMeasurementWindowV4.validID(policyID),
              sum == UInt64(ASHNormalizedQ16V4.scale) else {
            throw ASHMeasurementContractV4Error.invalidColorDomain
        }
        self.policyID = policyID
        self.colorSpace = colorSpace
        self.redLumaCoefficient = redLumaCoefficient
        self.greenLumaCoefficient = greenLumaCoefficient
        self.blueLumaCoefficient = blueLumaCoefficient
        self.alphaHandling = alphaHandling
        self.integerNormalization = integerNormalization
    }
}

enum ASHMeasurementResetTriggerV4: UInt8, CaseIterable, Codable, Sendable {
    case streamStart = 1
    case discontinuity = 2
    case seek = 3
    case sceneCut = 4
    case geometryChange = 5
    case pixelFormatChange = 6
    case colorDomainChange = 7
    case fieldCadenceChange = 8
    case contractChange = 9
    case explicitReset = 10
}

enum ASHTemporalEvidenceOnResetV4: UInt8, Codable, Sendable {
    case mustBeZero = 1
    case preserveCurrentEvidence = 2
}

struct ASHMeasurementResetRuleV4: Equatable, Hashable, Sendable {
    let trigger: ASHMeasurementResetTriggerV4
    let temporalEvidence: ASHTemporalEvidenceOnResetV4
}

struct ASHMeasurementResetPolicyV4: Equatable, Hashable, Sendable {
    let policyID: String
    let rules: [ASHMeasurementResetRuleV4]

    init(policyID: String, rules: [ASHMeasurementResetRuleV4]) throws {
        let triggers = rules.map(\.trigger)
        guard ASHMeasurementWindowV4.validID(policyID),
              rules.count == ASHMeasurementResetTriggerV4.allCases.count,
              Set(triggers).count == rules.count,
              Set(triggers) == Set(ASHMeasurementResetTriggerV4.allCases) else {
            throw ASHMeasurementContractV4Error.invalidResetPolicy
        }
        self.policyID = policyID
        self.rules = rules.sorted { $0.trigger.rawValue < $1.trigger.rawValue }
    }

    func rule(
        for trigger: ASHMeasurementResetTriggerV4
    ) -> ASHMeasurementResetRuleV4? {
        rules.first { $0.trigger == trigger }
    }
}

struct ASHMeasurementEvidenceProvenanceV4: Equatable, Hashable, Sendable {
    let contractID: String
    let schemaVersion: UInt16
    let windowPolicyID: String
    let borderPolicyID: String
    let colorDomainPolicyID: String
}

/// All evidence fields are named and fixed point. There is no array position,
/// floating-point value, or untyped dictionary key for a caller to reinterpret.
struct ASHMeasurementEvidenceV4: Equatable, Hashable, Sendable {
    let provenance: ASHMeasurementEvidenceProvenanceV4
    let meanLuminance: ASHNormalizedQ16V4
    let rmsContrast: ASHNormalizedQ16V4
    let edgeEnergy: ASHNormalizedQ16V4
    let textureEnergy: ASHNormalizedQ16V4
    let chromaEnergy: ASHNormalizedQ16V4
    let horizontalGradientEnergy: ASHNormalizedQ16V4
    let verticalGradientEnergy: ASHNormalizedQ16V4
    let temporalChange: ASHNormalizedQ16V4

    init(
        contract: ASHMeasurementContractV4,
        meanLuminance: ASHNormalizedQ16V4,
        rmsContrast: ASHNormalizedQ16V4,
        edgeEnergy: ASHNormalizedQ16V4,
        textureEnergy: ASHNormalizedQ16V4,
        chromaEnergy: ASHNormalizedQ16V4,
        horizontalGradientEnergy: ASHNormalizedQ16V4,
        verticalGradientEnergy: ASHNormalizedQ16V4,
        temporalChange: ASHNormalizedQ16V4
    ) {
        self.init(
            provenance: contract.evidenceProvenance,
            meanLuminance: meanLuminance,
            rmsContrast: rmsContrast,
            edgeEnergy: edgeEnergy,
            textureEnergy: textureEnergy,
            chromaEnergy: chromaEnergy,
            horizontalGradientEnergy: horizontalGradientEnergy,
            verticalGradientEnergy: verticalGradientEnergy,
            temporalChange: temporalChange
        )
    }

    init(
        provenance: ASHMeasurementEvidenceProvenanceV4,
        meanLuminance: ASHNormalizedQ16V4,
        rmsContrast: ASHNormalizedQ16V4,
        edgeEnergy: ASHNormalizedQ16V4,
        textureEnergy: ASHNormalizedQ16V4,
        chromaEnergy: ASHNormalizedQ16V4,
        horizontalGradientEnergy: ASHNormalizedQ16V4,
        verticalGradientEnergy: ASHNormalizedQ16V4,
        temporalChange: ASHNormalizedQ16V4
    ) {
        self.provenance = provenance
        self.meanLuminance = meanLuminance
        self.rmsContrast = rmsContrast
        self.edgeEnergy = edgeEnergy
        self.textureEnergy = textureEnergy
        self.chromaEnergy = chromaEnergy
        self.horizontalGradientEnergy = horizontalGradientEnergy
        self.verticalGradientEnergy = verticalGradientEnergy
        self.temporalChange = temporalChange
    }

    func value(
        for coordinate: ASHMeasurementCoordinateV4
    ) -> ASHNormalizedQ16V4 {
        switch coordinate {
        case .meanLuminance: meanLuminance
        case .rmsContrast: rmsContrast
        case .edgeEnergy: edgeEnergy
        case .textureEnergy: textureEnergy
        case .chromaEnergy: chromaEnergy
        case .horizontalGradientEnergy: horizontalGradientEnergy
        case .verticalGradientEnergy: verticalGradientEnergy
        case .temporalChange: temporalChange
        }
    }
}

enum ASHMeasurementHistoryV4: Equatable, Sendable {
    case continuous(previousState: ASHState)
    case reset(ASHMeasurementResetTriggerV4)
}

struct ASHMeasurementProjectionV4: Equatable, Sendable {
    let evidence: ASHMeasurementEvidenceV4
    let payloadBitsByCoordinate: [UInt8]
    let integrityBit: UInt8
    let state: ASHState

    func bit(for coordinate: ASHMeasurementCoordinateV4) -> UInt8 {
        payloadBitsByCoordinate[Int(coordinate.rawValue) - 1]
    }
}

/// The complete versioned boundary between image analysis and the ASH finite
/// state. Executors consume its projected state; they do not own thresholds.
struct ASHMeasurementContractV4: Equatable, Sendable {
    static let supportedSchemaVersion: UInt16 = 1
    static let canonicalContractID = "ash.p06.measurement.q16.v1"

    let schemaVersion: UInt16
    let contractID: String
    let fractionalBits: UInt8
    let roundingRule: ASHMeasurementRoundingRuleV4
    let rules: [ASHMeasurementRuleV4]
    let window: ASHMeasurementWindowV4
    let borderPolicy: ASHMeasurementBorderPolicyV4
    let colorDomain: ASHMeasurementColorDomainV4
    let resetPolicy: ASHMeasurementResetPolicyV4

    init(
        schemaVersion: UInt16,
        contractID: String,
        fractionalBits: UInt8,
        roundingRule: ASHMeasurementRoundingRuleV4,
        rules: [ASHMeasurementRuleV4],
        window: ASHMeasurementWindowV4,
        borderPolicy: ASHMeasurementBorderPolicyV4,
        colorDomain: ASHMeasurementColorDomainV4,
        resetPolicy: ASHMeasurementResetPolicyV4
    ) throws {
        guard schemaVersion == Self.supportedSchemaVersion else {
            throw ASHMeasurementContractV4Error.unsupportedSchemaVersion(
                schemaVersion
            )
        }
        guard ASHMeasurementWindowV4.validID(contractID) else {
            throw ASHMeasurementContractV4Error.invalidIdentifier
        }
        let coordinates = rules.map(\.coordinate)
        guard rules.count == ASHMeasurementCoordinateV4.allCases.count,
              Set(coordinates).count == rules.count,
              Set(coordinates) == Set(ASHMeasurementCoordinateV4.allCases) else {
            throw ASHMeasurementContractV4Error.invalidMeasurementRules
        }
        guard fractionalBits == UInt8(ASHNormalizedQ16V4.fractionalBits) else {
            throw ASHMeasurementContractV4Error.nonCanonicalContract
        }
        self.schemaVersion = schemaVersion
        self.contractID = contractID
        self.fractionalBits = fractionalBits
        self.roundingRule = roundingRule
        self.rules = rules.sorted { $0.coordinate.rawValue < $1.coordinate.rawValue }
        self.window = window
        self.borderPolicy = borderPolicy
        self.colorDomain = colorDomain
        self.resetPolicy = resetPolicy
    }

    static let canonicalP06: ASHMeasurementContractV4 = {
        let q: (UInt32) -> ASHNormalizedQ16V4 = {
            ASHNormalizedQ16V4(validatedRawValue: $0)
        }
        let thresholds: [UInt32] = [
            32_768, 13_107, 7_864, 5_243,
            6_554, 6_554, 6_554, 5_243
        ]
        let hysteresis: [UInt32] = [
            1_311, 1_311, 983, 983,
            983, 983, 983, 1_311
        ]
        let rules = zip(
            ASHMeasurementCoordinateV4.allCases,
            zip(thresholds, hysteresis)
        ).map { coordinate, values in
            try! ASHMeasurementRuleV4(
                coordinate: coordinate,
                threshold: q(values.0),
                hysteresis: q(values.1)
            )
        }
        let window = try! ASHMeasurementWindowV4(
            policyID: "ash.measure.window.source-32x32.v1",
            width: 32,
            height: 32,
            horizontalStride: 1,
            verticalStride: 1,
            anchor: .sourceTileOrigin,
            aggregation: .arithmeticMeanOverEverySample
        )
        let border = try! ASHMeasurementBorderPolicyV4(
            policyID: "ash.measure.border.edge-clamp-terminal-zero.v1",
            spatialExtension: .clampToEdge,
            forwardDifferenceBoundary: .zeroAtPositiveExtent,
            temporalWindowMismatch: .resetRequired,
            boxBlurRadius: 1
        )
        let color = try! ASHMeasurementColorDomainV4(
            policyID: "ash.measure.color.encoded-rgb-bt709.v1",
            colorSpace: .normalizedEncodedRGBBT709Reference,
            redLumaCoefficient: q(13_933),
            greenLumaCoefficient: q(46_871),
            blueLumaCoefficient: q(4_732),
            alphaHandling: .ignored,
            integerNormalization: .declaredSignalMaximum
        )
        let zeroTemporal: Set<ASHMeasurementResetTriggerV4> = [
            .streamStart, .discontinuity, .seek, .geometryChange,
            .pixelFormatChange, .colorDomainChange, .fieldCadenceChange,
            .contractChange, .explicitReset
        ]
        let reset = try! ASHMeasurementResetPolicyV4(
            policyID: "ash.measure.reset.complete-v1",
            rules: ASHMeasurementResetTriggerV4.allCases.map { trigger in
                ASHMeasurementResetRuleV4(
                    trigger: trigger,
                    temporalEvidence: zeroTemporal.contains(trigger)
                        ? .mustBeZero
                        : .preserveCurrentEvidence
                )
            }
        )
        return try! ASHMeasurementContractV4(
            schemaVersion: supportedSchemaVersion,
            contractID: canonicalContractID,
            fractionalBits: UInt8(ASHNormalizedQ16V4.fractionalBits),
            roundingRule: .nearestTiesToEven,
            rules: rules,
            window: window,
            borderPolicy: border,
            colorDomain: color,
            resetPolicy: reset
        )
    }()

    var evidenceProvenance: ASHMeasurementEvidenceProvenanceV4 {
        ASHMeasurementEvidenceProvenanceV4(
            contractID: contractID,
            schemaVersion: schemaVersion,
            windowPolicyID: window.policyID,
            borderPolicyID: borderPolicy.policyID,
            colorDomainPolicyID: colorDomain.policyID
        )
    }

    func validateCanonical() throws {
        guard self == Self.canonicalP06 else {
            throw ASHMeasurementContractV4Error.nonCanonicalContract
        }
    }

    func project(
        _ evidence: ASHMeasurementEvidenceV4,
        history: ASHMeasurementHistoryV4
    ) throws -> ASHMeasurementProjectionV4 {
        try validateCanonical()
        guard evidence.provenance == evidenceProvenance else {
            throw ASHMeasurementContractV4Error.evidenceProvenanceMismatch
        }

        let previousPayload: [UInt8]?
        switch history {
        case .continuous(let previousState):
            guard previousState.hasValidIntegrity else {
                throw ASHMeasurementContractV4Error.invalidPreviousState
            }
            previousPayload = previousState.bits.prefix(8).map(UInt8.init)
        case .reset(let trigger):
            guard let resetRule = resetPolicy.rule(for: trigger) else {
                throw ASHMeasurementContractV4Error.undeclaredResetTrigger(
                    trigger
                )
            }
            if resetRule.temporalEvidence == .mustBeZero,
               evidence.temporalChange != .zero {
                throw ASHMeasurementContractV4Error.temporalEvidenceMustBeZero(
                    trigger
                )
            }
            previousPayload = nil
        }

        var payload: [UInt8] = []
        payload.reserveCapacity(8)
        for rule in rules {
            let value = evidence.value(for: rule.coordinate).rawValue
            let bit: UInt8
            if let previousPayload {
                let previousBit = previousPayload[
                    Int(rule.coordinate.rawValue) - 1
                ]
                if previousBit == 0 {
                    bit = value >= rule.threshold.rawValue
                        + rule.hysteresis.rawValue ? 1 : 0
                } else {
                    bit = value < rule.threshold.rawValue
                        - rule.hysteresis.rawValue ? 0 : 1
                }
            } else {
                bit = value >= rule.threshold.rawValue ? 1 : 0
            }
            payload.append(bit)
        }
        let integrity = payload.reduce(UInt8(0), ^)
        let state = try ASHState(payloadBits: payload.map(Int.init))
        return ASHMeasurementProjectionV4(
            evidence: evidence,
            payloadBitsByCoordinate: payload,
            integrityBit: integrity,
            state: state
        )
    }
}

// MARK: - Deterministic artifact serialization

extension ASHMeasurementContractV4 {
    private static let binaryMagic: [UInt8] = [0x41, 0x53, 0x48, 0x4d] // ASHM

    func serializedCanonical() throws -> Data {
        try validateCanonical()
        var writer = ASHMeasurementBinaryWriterV4()
        writer.append(bytes: Self.binaryMagic)
        writer.append(schemaVersion)
        try writer.append(string: contractID)
        writer.append(fractionalBits)
        writer.append(roundingRule.rawValue)
        try writer.append(string: window.policyID)
        writer.append(window.width)
        writer.append(window.height)
        writer.append(window.horizontalStride)
        writer.append(window.verticalStride)
        writer.append(window.anchor.rawValue)
        writer.append(window.aggregation.rawValue)
        try writer.append(string: borderPolicy.policyID)
        writer.append(borderPolicy.spatialExtension.rawValue)
        writer.append(borderPolicy.forwardDifferenceBoundary.rawValue)
        writer.append(borderPolicy.temporalWindowMismatch.rawValue)
        writer.append(borderPolicy.boxBlurRadius)
        try writer.append(string: colorDomain.policyID)
        writer.append(colorDomain.colorSpace.rawValue)
        writer.append(colorDomain.redLumaCoefficient.rawValue)
        writer.append(colorDomain.greenLumaCoefficient.rawValue)
        writer.append(colorDomain.blueLumaCoefficient.rawValue)
        writer.append(colorDomain.alphaHandling.rawValue)
        writer.append(colorDomain.integerNormalization.rawValue)
        try writer.append(string: resetPolicy.policyID)
        writer.append(UInt8(resetPolicy.rules.count))
        for rule in resetPolicy.rules {
            writer.append(rule.trigger.rawValue)
            writer.append(rule.temporalEvidence.rawValue)
        }
        writer.append(UInt8(rules.count))
        for rule in rules {
            writer.append(rule.coordinate.rawValue)
            writer.append(rule.threshold.rawValue)
            writer.append(rule.hysteresis.rawValue)
        }
        return writer.data
    }

    static func decodeCanonical(from data: Data) throws -> Self {
        var reader = ASHMeasurementBinaryReaderV4(data: data)
        guard try reader.readBytes(count: binaryMagic.count) == binaryMagic else {
            throw ASHMeasurementContractV4Error.invalidSerialization
        }
        let schemaVersion = try reader.readUInt16()
        let contractID = try reader.readString()
        let fractionalBits = try reader.readUInt8()
        guard let rounding = ASHMeasurementRoundingRuleV4(
            rawValue: try reader.readUInt8()
        ) else {
            throw ASHMeasurementContractV4Error.invalidSerialization
        }
        let windowID = try reader.readString()
        let windowWidth = try reader.readUInt16()
        let windowHeight = try reader.readUInt16()
        let horizontalStride = try reader.readUInt8()
        let verticalStride = try reader.readUInt8()
        guard let anchor = ASHMeasurementWindowAnchorV4(
            rawValue: try reader.readUInt8()
        ), let aggregation = ASHMeasurementWindowAggregationV4(
            rawValue: try reader.readUInt8()
        ) else {
            throw ASHMeasurementContractV4Error.invalidSerialization
        }
        let window = try ASHMeasurementWindowV4(
            policyID: windowID,
            width: windowWidth,
            height: windowHeight,
            horizontalStride: horizontalStride,
            verticalStride: verticalStride,
            anchor: anchor,
            aggregation: aggregation
        )

        let borderID = try reader.readString()
        guard let spatial = ASHSpatialBorderExtensionV4(
            rawValue: try reader.readUInt8()
        ), let forward = ASHForwardDifferenceBoundaryV4(
            rawValue: try reader.readUInt8()
        ), let temporal = ASHTemporalWindowMismatchV4(
            rawValue: try reader.readUInt8()
        ) else {
            throw ASHMeasurementContractV4Error.invalidSerialization
        }
        let border = try ASHMeasurementBorderPolicyV4(
            policyID: borderID,
            spatialExtension: spatial,
            forwardDifferenceBoundary: forward,
            temporalWindowMismatch: temporal,
            boxBlurRadius: try reader.readUInt8()
        )

        let colorID = try reader.readString()
        guard let colorSpace = ASHMeasurementColorSpaceV4(
            rawValue: try reader.readUInt8()
        ) else {
            throw ASHMeasurementContractV4Error.invalidSerialization
        }
        let red = try ASHNormalizedQ16V4(rawValue: reader.readUInt32())
        let green = try ASHNormalizedQ16V4(rawValue: reader.readUInt32())
        let blue = try ASHNormalizedQ16V4(rawValue: reader.readUInt32())
        guard let alpha = ASHMeasurementAlphaHandlingV4(
            rawValue: try reader.readUInt8()
        ), let normalization = ASHMeasurementIntegerNormalizationV4(
            rawValue: try reader.readUInt8()
        ) else {
            throw ASHMeasurementContractV4Error.invalidSerialization
        }
        let color = try ASHMeasurementColorDomainV4(
            policyID: colorID,
            colorSpace: colorSpace,
            redLumaCoefficient: red,
            greenLumaCoefficient: green,
            blueLumaCoefficient: blue,
            alphaHandling: alpha,
            integerNormalization: normalization
        )

        let resetID = try reader.readString()
        let resetCount = Int(try reader.readUInt8())
        var resetRules: [ASHMeasurementResetRuleV4] = []
        resetRules.reserveCapacity(resetCount)
        for _ in 0..<resetCount {
            guard let trigger = ASHMeasurementResetTriggerV4(
                rawValue: try reader.readUInt8()
            ), let resetTemporal = ASHTemporalEvidenceOnResetV4(
                rawValue: try reader.readUInt8()
            ) else {
                throw ASHMeasurementContractV4Error.invalidSerialization
            }
            resetRules.append(
                ASHMeasurementResetRuleV4(
                    trigger: trigger,
                    temporalEvidence: resetTemporal
                )
            )
        }
        let reset = try ASHMeasurementResetPolicyV4(
            policyID: resetID,
            rules: resetRules
        )

        let measurementCount = Int(try reader.readUInt8())
        var measurementRules: [ASHMeasurementRuleV4] = []
        measurementRules.reserveCapacity(measurementCount)
        for _ in 0..<measurementCount {
            guard let coordinate = ASHMeasurementCoordinateV4(
                rawValue: try reader.readUInt8()
            ) else {
                throw ASHMeasurementContractV4Error.invalidSerialization
            }
            measurementRules.append(
                try ASHMeasurementRuleV4(
                    coordinate: coordinate,
                    threshold: ASHNormalizedQ16V4(
                        rawValue: reader.readUInt32()
                    ),
                    hysteresis: ASHNormalizedQ16V4(
                        rawValue: reader.readUInt32()
                    )
                )
            )
        }
        guard reader.isAtEnd else {
            throw ASHMeasurementContractV4Error.trailingSerializationBytes
        }
        let decoded = try Self(
            schemaVersion: schemaVersion,
            contractID: contractID,
            fractionalBits: fractionalBits,
            roundingRule: rounding,
            rules: measurementRules,
            window: window,
            borderPolicy: border,
            colorDomain: color,
            resetPolicy: reset
        )
        try decoded.validateCanonical()
        return decoded
    }
}

private struct ASHMeasurementBinaryWriterV4 {
    var data = Data()

    mutating func append(_ value: UInt8) {
        data.append(value)
    }

    mutating func append(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }

    mutating func append(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }

    mutating func append(bytes: [UInt8]) {
        data.append(contentsOf: bytes)
    }

    mutating func append(string: String) throws {
        let bytes = Array(string.utf8)
        guard let count = UInt8(exactly: bytes.count), count > 0 else {
            throw ASHMeasurementContractV4Error.invalidSerialization
        }
        append(count)
        append(bytes: bytes)
    }
}

private struct ASHMeasurementBinaryReaderV4 {
    let data: Data
    private(set) var offset = 0

    var isAtEnd: Bool { offset == data.count }

    mutating func readUInt8() throws -> UInt8 {
        guard offset < data.count else {
            throw ASHMeasurementContractV4Error.invalidSerialization
        }
        defer { offset += 1 }
        return data[data.startIndex + offset]
    }

    mutating func readUInt16() throws -> UInt16 {
        let high = UInt16(try readUInt8())
        return (high << 8) | UInt16(try readUInt8())
    }

    mutating func readUInt32() throws -> UInt32 {
        var result: UInt32 = 0
        for _ in 0..<4 {
            result = (result << 8) | UInt32(try readUInt8())
        }
        return result
    }

    mutating func readBytes(count: Int) throws -> [UInt8] {
        guard count >= 0, offset <= data.count - count else {
            throw ASHMeasurementContractV4Error.invalidSerialization
        }
        let range = (data.startIndex + offset)..<(data.startIndex + offset + count)
        offset += count
        return Array(data[range])
    }

    mutating func readString() throws -> String {
        let count = Int(try readUInt8())
        guard count > 0,
              let value = String(
                bytes: try readBytes(count: count),
                encoding: .utf8
              ), ASHMeasurementWindowV4.validID(value) else {
            throw ASHMeasurementContractV4Error.invalidSerialization
        }
        return value
    }
}
