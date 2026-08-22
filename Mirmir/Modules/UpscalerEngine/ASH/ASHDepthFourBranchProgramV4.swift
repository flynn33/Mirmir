import Foundation

enum ASHDepthFourBranchProgramV4Error: Error, Equatable, Sendable {
    case invalidIdentifier
    case invalidMessage(UInt8)
    case invalidCodeword(UInt16)
    case invalidMessageCodewordMap
    case nonCanonicalMessageCodewordMap
    case unknownMessage(UInt8)
    case unknownCodeword(UInt16)
    case invalidGrammar
    case arithmeticOverflow
    case invalidOperatorManifest
    case invalidCoalescenceDeclaration
    case invalidConditioningPolicy
    case invalidProgram
    case nonCanonicalProgram
    case invalidSourceState
    case releaseAuditFailed
    case invalidSerialization
    case trailingSerializationBytes
}

struct ASHMessageCodewordEntryV4: Equatable, Hashable, Sendable {
    let messageRawValue: UInt8
    let codewordRawValue: UInt16
}

/// A bijection whose records carry both identities. Neither array position nor
/// numeric codeword sorting is ever interpreted as a message number.
struct ASHMessageCodewordMapV4: Equatable, Sendable {
    let entries: [ASHMessageCodewordEntryV4]

    init(entries: [ASHMessageCodewordEntryV4]) throws {
        guard entries.count == 16,
              Set(entries.map(\.messageRawValue)) == Set(UInt8(0)..<UInt8(16)),
              Set(entries.map(\.codewordRawValue)).count == 16 else {
            throw ASHDepthFourBranchProgramV4Error.invalidMessageCodewordMap
        }
        for entry in entries {
            guard entry.messageRawValue < 16,
                  let state = try? ASHState(rawValue: entry.codewordRawValue),
                  state.hasValidIntegrity else {
                throw ASHDepthFourBranchProgramV4Error.invalidCodeword(
                    entry.codewordRawValue
                )
            }
        }
        self.entries = entries.sorted {
            $0.messageRawValue < $1.messageRawValue
        }
    }

    static let canonical: ASHMessageCodewordMapV4 = {
        try! ASHMessageCodewordMapV4(
            entries: (0..<16).map { rawMessage in
                let message = ASHMessage(
                    validatedRawValue: UInt8(rawMessage)
                )
                return ASHMessageCodewordEntryV4(
                    messageRawValue: UInt8(rawMessage),
                    codewordRawValue: ASHCoreV4.encode(message).rawValue
                )
            }
        )
    }()

    func codewordRawValue(forMessage rawMessage: UInt8) throws -> UInt16 {
        guard rawMessage < 16 else {
            throw ASHDepthFourBranchProgramV4Error.invalidMessage(rawMessage)
        }
        guard let entry = entries.first(where: {
            $0.messageRawValue == rawMessage
        }) else {
            throw ASHDepthFourBranchProgramV4Error.unknownMessage(rawMessage)
        }
        return entry.codewordRawValue
    }

    func messageRawValue(forCodeword rawCodeword: UInt16) throws -> UInt8 {
        guard rawCodeword <= ASHState.mask else {
            throw ASHDepthFourBranchProgramV4Error.invalidCodeword(rawCodeword)
        }
        guard let entry = entries.first(where: {
            $0.codewordRawValue == rawCodeword
        }) else {
            throw ASHDepthFourBranchProgramV4Error.unknownCodeword(rawCodeword)
        }
        return entry.messageRawValue
    }

    func validateCanonical() throws {
        for entry in entries {
            let expected = ASHCoreV4.encode(
                ASHMessage(validatedRawValue: entry.messageRawValue)
            ).rawValue
            guard entry.codewordRawValue == expected else {
                throw ASHDepthFourBranchProgramV4Error
                    .nonCanonicalMessageCodewordMap
            }
        }
    }
}

struct ASHDepthFourGrammarV4: Equatable, Sendable {
    static let actionCount = 3
    static let depth = 4

    let actionMassDenominator: UInt16
    /// Stable action order is `0`, `+`, `-`.
    let actionMassNumerators: [UInt16]
    let positiveToggleMasksByLevel: [UInt8]
    let negativeToggleMasksByLevel: [UInt8]

    init(
        actionMassDenominator: UInt16,
        actionMassNumerators: [UInt16],
        positiveToggleMasksByLevel: [UInt8],
        negativeToggleMasksByLevel: [UInt8]
    ) throws {
        guard actionMassDenominator > 0,
              actionMassNumerators.count == Self.actionCount,
              actionMassNumerators.allSatisfy({ $0 > 0 }),
              actionMassNumerators.reduce(UInt32(0), {
                $0 + UInt32($1)
              }) == UInt32(actionMassDenominator),
              positiveToggleMasksByLevel.count == Self.depth,
              negativeToggleMasksByLevel.count == Self.depth,
              (positiveToggleMasksByLevel + negativeToggleMasksByLevel)
                .allSatisfy(Self.isSingleMessageBit) else {
            throw ASHDepthFourBranchProgramV4Error.invalidGrammar
        }
        self.actionMassDenominator = actionMassDenominator
        self.actionMassNumerators = actionMassNumerators
        self.positiveToggleMasksByLevel = positiveToggleMasksByLevel
        self.negativeToggleMasksByLevel = negativeToggleMasksByLevel
    }

    static let canonical = try! ASHDepthFourGrammarV4(
        actionMassDenominator: 4,
        actionMassNumerators: [2, 1, 1],
        positiveToggleMasksByLevel: [0b1000, 0b0100, 0b0010, 0b0001],
        negativeToggleMasksByLevel: [0b0100, 0b0010, 0b0001, 0b1000]
    )

    func childMessage(
        parentRawValue: UInt8,
        actionIndex: Int,
        level: Int
    ) throws -> UInt8 {
        guard parentRawValue < 16,
              (0..<Self.actionCount).contains(actionIndex),
              (0..<Self.depth).contains(level) else {
            throw ASHDepthFourBranchProgramV4Error.invalidGrammar
        }
        switch actionIndex {
        case 0:
            return parentRawValue
        case 1:
            return parentRawValue ^ positiveToggleMasksByLevel[level]
        default:
            return parentRawValue ^ negativeToggleMasksByLevel[level]
        }
    }

    private static func isSingleMessageBit(_ value: UInt8) -> Bool {
        value > 0 && value < 16 && value.nonzeroBitCount == 1
    }
}

struct ASHOperatorEntryV4: Equatable, Hashable, Sendable {
    let messageRawValue: UInt8
    let coefficients: [Int16]
}

struct ASHOperatorCoalescenceDeclarationV4:
    Equatable, Hashable, Sendable {
    let messages: [UInt8]
    let reasonID: String

    init(messages: [UInt8], reasonID: String) throws {
        let sorted = messages.sorted()
        guard sorted.count >= 2,
              Set(sorted).count == sorted.count,
              sorted.allSatisfy({ $0 < 16 }),
              ASHMeasurementWindowV4.validID(reasonID) else {
            throw ASHDepthFourBranchProgramV4Error
                .invalidCoalescenceDeclaration
        }
        self.messages = sorted
        self.reasonID = reasonID
    }
}

/// Coefficients describe topological operator controls, not runtime filter
/// magnitudes. Keeping each basis independent lets the audit catch the ASH
/// Model v1 `m3 - m4` cancellation before pixels are executed.
struct ASHOperatorManifestV4: Equatable, Sendable {
    let manifestID: String
    let basisIDs: [String]
    let entries: [ASHOperatorEntryV4]
    let intentionalCoalescences: [ASHOperatorCoalescenceDeclarationV4]

    init(
        manifestID: String,
        basisIDs: [String],
        entries: [ASHOperatorEntryV4],
        intentionalCoalescences: [ASHOperatorCoalescenceDeclarationV4]
    ) throws {
        guard ASHMeasurementWindowV4.validID(manifestID),
              (1...8).contains(basisIDs.count),
              Set(basisIDs).count == basisIDs.count,
              basisIDs.allSatisfy(ASHMeasurementWindowV4.validID),
              entries.count == 16,
              Set(entries.map(\.messageRawValue))
                == Set(UInt8(0)..<UInt8(16)),
              entries.allSatisfy({ entry in
                entry.messageRawValue < 16
                    && entry.coefficients.count == basisIDs.count
                    && entry.coefficients.allSatisfy { (-8...8).contains($0) }
              }) else {
            throw ASHDepthFourBranchProgramV4Error.invalidOperatorManifest
        }
        let declaredMessages = intentionalCoalescences.flatMap(\.messages)
        guard Set(declaredMessages).count == declaredMessages.count else {
            throw ASHDepthFourBranchProgramV4Error
                .invalidCoalescenceDeclaration
        }
        self.manifestID = manifestID
        self.basisIDs = basisIDs
        self.entries = entries.sorted { $0.messageRawValue < $1.messageRawValue }
        self.intentionalCoalescences = intentionalCoalescences.sorted {
            $0.messages.lexicographicallyPrecedes($1.messages)
        }
    }

    static let canonicalP06: ASHOperatorManifestV4 = {
        try! ASHOperatorManifestV4(
            manifestID: "ash.p06.operator-controls.independent-four.v1",
            basisIDs: [
                "horizontal_detail",
                "vertical_detail",
                "isotropic_detail",
                "regularization"
            ],
            entries: (0..<16).map { rawMessage in
                ASHOperatorEntryV4(
                    messageRawValue: UInt8(rawMessage),
                    coefficients: (0..<4).map { bitIndex in
                        let shift = 3 - bitIndex
                        return Int16((rawMessage >> shift) & 1)
                    }
                )
            },
            intentionalCoalescences: []
        )
    }()

    /// The ASH Model v1 reference effect is retained as an auditable negative
    /// fixture: m3 and m4 cancel in four pairs, leaving 12 distinct effects.
    static func declaredASHModelV1Reference() throws -> Self {
        let declarations = try [[0, 3], [4, 7], [8, 11], [12, 15]].map {
            try ASHOperatorCoalescenceDeclarationV4(
                messages: $0.map(UInt8.init),
                reasonID: "ash-model-v1.isotropic-controls-cancel"
            )
        }
        return try Self(
            manifestID: "ash.model-v1.operator-controls.declared-cancellation",
            basisIDs: [
                "horizontal_detail",
                "vertical_detail",
                "net_isotropic_detail"
            ],
            entries: (0..<16).map { rawMessage in
                let m1 = Int16((rawMessage >> 3) & 1)
                let m2 = Int16((rawMessage >> 2) & 1)
                let m3 = Int16((rawMessage >> 1) & 1)
                let m4 = Int16(rawMessage & 1)
                return ASHOperatorEntryV4(
                    messageRawValue: UInt8(rawMessage),
                    coefficients: [m1, m2, m3 - m4]
                )
            },
            intentionalCoalescences: declarations
        )
    }

    func entry(forMessage rawMessage: UInt8) throws -> ASHOperatorEntryV4 {
        guard rawMessage < 16 else {
            throw ASHDepthFourBranchProgramV4Error.invalidMessage(rawMessage)
        }
        guard let entry = entries.first(where: {
            $0.messageRawValue == rawMessage
        }) else {
            throw ASHDepthFourBranchProgramV4Error.unknownMessage(rawMessage)
        }
        return entry
    }
}

struct ASHStateControlPairV4: Equatable, Hashable, Sendable {
    let firstCoordinate: UInt8
    let secondCoordinate: UInt8

    init(firstCoordinate: UInt8, secondCoordinate: UInt8) throws {
        guard (1...8).contains(firstCoordinate),
              (1...8).contains(secondCoordinate),
              firstCoordinate != secondCoordinate else {
            throw ASHDepthFourBranchProgramV4Error.invalidConditioningPolicy
        }
        self.firstCoordinate = firstCoordinate
        self.secondCoordinate = secondCoordinate
    }
}

/// Each payload coordinate participates exactly once. The four pair parities
/// form a target message; each matching message bit multiplies prior mass by
/// the declared integer factor. Normalization remains an exact rational.
struct ASHStateConditioningPolicyV4: Equatable, Sendable {
    let policyID: String
    let coordinatePairsByMessageBit: [ASHStateControlPairV4]
    let matchingBitMultiplier: UInt16

    init(
        policyID: String,
        coordinatePairsByMessageBit: [ASHStateControlPairV4],
        matchingBitMultiplier: UInt16
    ) throws {
        let coordinates = coordinatePairsByMessageBit.flatMap {
            [$0.firstCoordinate, $0.secondCoordinate]
        }
        guard ASHMeasurementWindowV4.validID(policyID),
              coordinatePairsByMessageBit.count == 4,
              Set(coordinates) == Set(UInt8(1)...UInt8(8)),
              coordinates.count == Set(coordinates).count,
              (2...16).contains(matchingBitMultiplier) else {
            throw ASHDepthFourBranchProgramV4Error.invalidConditioningPolicy
        }
        self.policyID = policyID
        self.coordinatePairsByMessageBit = coordinatePairsByMessageBit
        self.matchingBitMultiplier = matchingBitMultiplier
    }

    static let canonical = try! ASHStateConditioningPolicyV4(
        policyID: "ash.p06.state-xor-pair-affinity.v1",
        coordinatePairsByMessageBit: [
            try! ASHStateControlPairV4(firstCoordinate: 1, secondCoordinate: 5),
            try! ASHStateControlPairV4(firstCoordinate: 2, secondCoordinate: 6),
            try! ASHStateControlPairV4(firstCoordinate: 3, secondCoordinate: 7),
            try! ASHStateControlPairV4(firstCoordinate: 4, secondCoordinate: 8)
        ],
        matchingBitMultiplier: 2
    )

    func targetMessageRawValue(for state: ASHState) throws -> UInt8 {
        guard state.hasValidIntegrity else {
            throw ASHDepthFourBranchProgramV4Error.invalidSourceState
        }
        var result: UInt8 = 0
        for pair in coordinatePairsByMessageBit {
            result <<= 1
            result |= UInt8(
                state.bit(coordinate: Int(pair.firstCoordinate))
                    ^ state.bit(coordinate: Int(pair.secondCoordinate))
            )
        }
        return result
    }
}

struct ASHAggregatedMessageWeightV4: Equatable, Hashable, Sendable {
    let messageRawValue: UInt8
    let codewordRawValue: UInt16
    let massNumerator: UInt64
}

struct ASHConditionedMessageWeightV4: Equatable, Hashable, Sendable {
    let messageRawValue: UInt8
    let codewordRawValue: UInt16
    let operatorCoefficients: [Int16]
    let numerator: UInt64
}

struct ASHStateConditionedMessageWeightsV4: Equatable, Sendable {
    let sourceStateRawValue: UInt16
    let targetMessageRawValue: UInt8
    let denominator: UInt64
    let weightsByMessage: [ASHConditionedMessageWeightV4]

    var rankedWeights: [ASHConditionedMessageWeightV4] {
        weightsByMessage.sorted { left, right in
            if left.numerator != right.numerator {
                return left.numerator > right.numerator
            }
            return left.messageRawValue < right.messageRawValue
        }
    }
}

struct ASHGF2RankProofV4: Equatable, Sendable {
    let rowCount: Int
    let coordinateCount: Int
    let rank: Int
    let pivotCoordinates: [Int]
}

struct ASHOperatorCoalescedGroupV4: Equatable, Sendable {
    let messages: [UInt8]
    let coefficients: [Int16]
    let declaredReasonID: String?
}

struct ASHOperatorDistinctnessAuditV4: Equatable, Sendable {
    let operatorControlRank: Int
    let distinctOperatorCount: Int
    let coalescedGroups: [ASHOperatorCoalescedGroupV4]
    let accidentallyCoalescedGroups: [[UInt8]]
    let staleDeclarations: [[UInt8]]

    var allCoalescenceIsIntentional: Bool {
        accidentallyCoalescedGroups.isEmpty && staleDeclarations.isEmpty
    }
}

struct ASHDepthFourProgramAuditV4: Equatable, Sendable {
    let branchToggleRankProof: ASHGF2RankProofV4
    let codewordGeneratorRankProof: ASHGF2RankProofV4
    let codewordMapIsLinear: Bool
    let reachableMessageCount: Int
    let leafCount: UInt64
    let totalBaseMassNumerator: UInt64
    let baseMassDenominator: UInt64
    let operatorAudit: ASHOperatorDistinctnessAuditV4
    let influentialPayloadCoordinates: [UInt8]
    let operatorInfluentialPayloadCoordinates: [UInt8]

    var isReleaseValid: Bool {
        branchToggleRankProof.rank == 4
            && codewordGeneratorRankProof.rank == 4
            && codewordMapIsLinear
            && reachableMessageCount == 16
            && leafCount == 81
            && totalBaseMassNumerator == baseMassDenominator
            && operatorAudit.allCoalescenceIsIntentional
            && influentialPayloadCoordinates == Array(UInt8(1)...UInt8(8))
            && operatorInfluentialPayloadCoordinates
                == Array(UInt8(1)...UInt8(8))
    }
}

/// Runtime representation of the offline branch compilation. It contains 16
/// aggregate records and performs only a bounded O(16) state conditioning
/// pass—no branch nodes, paths, or ternary tree are allocated per tile.
struct ASHDepthFourBranchProgramV4: Equatable, Sendable {
    static let supportedSchemaVersion: UInt16 = 1
    static let canonicalProgramID = "ash.p06.depth-four.aggregate.v1"

    let schemaVersion: UInt16
    let programID: String
    let grammar: ASHDepthFourGrammarV4
    let leafCount: UInt64
    let baseMassDenominator: UInt64
    let baseWeightsByMessage: [ASHAggregatedMessageWeightV4]
    let messageCodewordMap: ASHMessageCodewordMapV4
    let operatorManifest: ASHOperatorManifestV4
    let conditioningPolicy: ASHStateConditioningPolicyV4
    private let hasCanonicalIdentity: Bool

    init(
        schemaVersion: UInt16,
        programID: String,
        grammar: ASHDepthFourGrammarV4,
        leafCount: UInt64,
        baseMassDenominator: UInt64,
        baseWeightsByMessage: [ASHAggregatedMessageWeightV4],
        messageCodewordMap: ASHMessageCodewordMapV4,
        operatorManifest: ASHOperatorManifestV4,
        conditioningPolicy: ASHStateConditioningPolicyV4
    ) throws {
        guard schemaVersion == Self.supportedSchemaVersion,
              ASHMeasurementWindowV4.validID(programID),
              leafCount == 81,
              baseMassDenominator > 0,
              baseWeightsByMessage.count == 16,
              Set(baseWeightsByMessage.map(\.messageRawValue))
                == Set(UInt8(0)..<UInt8(16)) else {
            throw ASHDepthFourBranchProgramV4Error.invalidProgram
        }
        let orderedWeights = baseWeightsByMessage.sorted {
            $0.messageRawValue < $1.messageRawValue
        }
        var total: UInt64 = 0
        for weight in orderedWeights {
            let expectedCodeword = try messageCodewordMap.codewordRawValue(
                forMessage: weight.messageRawValue
            )
            guard weight.codewordRawValue == expectedCodeword else {
                throw ASHDepthFourBranchProgramV4Error.invalidProgram
            }
            let addition = total.addingReportingOverflow(weight.massNumerator)
            guard !addition.overflow else {
                throw ASHDepthFourBranchProgramV4Error.arithmeticOverflow
            }
            total = addition.partialValue
        }
        guard total == baseMassDenominator else {
            throw ASHDepthFourBranchProgramV4Error.invalidProgram
        }
        self.schemaVersion = schemaVersion
        self.programID = programID
        self.grammar = grammar
        self.leafCount = leafCount
        self.baseMassDenominator = baseMassDenominator
        self.baseWeightsByMessage = orderedWeights
        self.messageCodewordMap = messageCodewordMap
        self.operatorManifest = operatorManifest
        self.conditioningPolicy = conditioningPolicy
        self.hasCanonicalIdentity = schemaVersion == Self.supportedSchemaVersion
            && programID == Self.canonicalProgramID
            && grammar == .canonical
            && messageCodewordMap == .canonical
            && operatorManifest == .canonicalP06
            && conditioningPolicy == .canonical
            && leafCount == 81
            && baseMassDenominator == 256
            && orderedWeights.map(\.massNumerator)
                == ASHCoreV4.expectedDepthFourBranchMassNumerators
    }

    func conditionedWeights(
        for sourceState: ASHState
    ) throws -> ASHStateConditionedMessageWeightsV4 {
        guard hasCanonicalIdentity else {
            throw ASHDepthFourBranchProgramV4Error.nonCanonicalProgram
        }
        return try makeConditionedWeights(for: sourceState)
    }

    func audit() throws -> ASHDepthFourProgramAuditV4 {
        let branchRank = Self.gf2RankProof(
            rows: grammar.positiveToggleMasksByLevel.map(UInt16.init),
            coordinateCount: 4
        )
        let generatorMessages: [UInt8] = [0b1000, 0b0100, 0b0010, 0b0001]
        let generatorCodewords = try generatorMessages.map {
            try messageCodewordMap.codewordRawValue(forMessage: $0)
        }
        let codewordRank = Self.gf2RankProof(
            rows: generatorCodewords,
            coordinateCount: 9
        )
        let linear = try codewordMapIsLinear()
        let operatorAudit = try makeOperatorAudit()
        let influence = try stateInfluenceAudit()
        return ASHDepthFourProgramAuditV4(
            branchToggleRankProof: branchRank,
            codewordGeneratorRankProof: codewordRank,
            codewordMapIsLinear: linear,
            reachableMessageCount: baseWeightsByMessage.filter {
                $0.massNumerator > 0
            }.count,
            leafCount: leafCount,
            totalBaseMassNumerator: baseWeightsByMessage.reduce(UInt64(0)) {
                $0 + $1.massNumerator
            },
            baseMassDenominator: baseMassDenominator,
            operatorAudit: operatorAudit,
            influentialPayloadCoordinates: influence.message,
            operatorInfluentialPayloadCoordinates: influence.operator
        )
    }

    func validateRelease() throws {
        guard try audit().isReleaseValid else {
            throw ASHDepthFourBranchProgramV4Error.releaseAuditFailed
        }
    }

    func validateCanonical() throws {
        guard hasCanonicalIdentity else {
            throw ASHDepthFourBranchProgramV4Error.nonCanonicalProgram
        }
        try messageCodewordMap.validateCanonical()
        try validateRelease()
    }

    private func makeConditionedWeights(
        for sourceState: ASHState
    ) throws -> ASHStateConditionedMessageWeightsV4 {
        guard sourceState.hasValidIntegrity else {
            throw ASHDepthFourBranchProgramV4Error.invalidSourceState
        }
        let target = try conditioningPolicy.targetMessageRawValue(
            for: sourceState
        )
        var denominator: UInt64 = 0
        var weights: [ASHConditionedMessageWeightV4] = []
        weights.reserveCapacity(16)
        for base in baseWeightsByMessage {
            let matchingBits = 4 - Int(
                (base.messageRawValue ^ target).nonzeroBitCount
            )
            var factor: UInt64 = 1
            for _ in 0..<matchingBits {
                let product = factor.multipliedReportingOverflow(
                    by: UInt64(conditioningPolicy.matchingBitMultiplier)
                )
                guard !product.overflow else {
                    throw ASHDepthFourBranchProgramV4Error.arithmeticOverflow
                }
                factor = product.partialValue
            }
            let product = base.massNumerator.multipliedReportingOverflow(
                by: factor
            )
            guard !product.overflow else {
                throw ASHDepthFourBranchProgramV4Error.arithmeticOverflow
            }
            let addition = denominator.addingReportingOverflow(
                product.partialValue
            )
            guard !addition.overflow else {
                throw ASHDepthFourBranchProgramV4Error.arithmeticOverflow
            }
            denominator = addition.partialValue
            let operatorEntry = try operatorManifest.entry(
                forMessage: base.messageRawValue
            )
            weights.append(
                ASHConditionedMessageWeightV4(
                    messageRawValue: base.messageRawValue,
                    codewordRawValue: base.codewordRawValue,
                    operatorCoefficients: operatorEntry.coefficients,
                    numerator: product.partialValue
                )
            )
        }
        return ASHStateConditionedMessageWeightsV4(
            sourceStateRawValue: sourceState.rawValue,
            targetMessageRawValue: target,
            denominator: denominator,
            weightsByMessage: weights
        )
    }

    private func codewordMapIsLinear() throws -> Bool {
        let zero = try messageCodewordMap.codewordRawValue(forMessage: 0)
        guard zero == 0 else { return false }
        for left in UInt8(0)..<UInt8(16) {
            let leftCodeword = try messageCodewordMap.codewordRawValue(
                forMessage: left
            )
            for right in UInt8(0)..<UInt8(16) {
                let rightCodeword = try messageCodewordMap.codewordRawValue(
                    forMessage: right
                )
                let combined = try messageCodewordMap.codewordRawValue(
                    forMessage: left ^ right
                )
                guard combined == leftCodeword ^ rightCodeword else {
                    return false
                }
            }
        }
        return true
    }

    private func makeOperatorAudit() throws -> ASHOperatorDistinctnessAuditV4 {
        var groups: [ASHOperatorSignatureKeyV4: [UInt8]] = [:]
        for entry in operatorManifest.entries {
            groups[ASHOperatorSignatureKeyV4(entry.coefficients), default: []]
                .append(entry.messageRawValue)
        }
        let duplicateGroups = groups
            .filter { $0.value.count > 1 }
            .map { key, messages in (key, messages.sorted()) }
            .sorted { $0.1.lexicographicallyPrecedes($1.1) }
        let declarations = Dictionary(
            uniqueKeysWithValues: operatorManifest.intentionalCoalescences.map {
                ($0.messages, $0.reasonID)
            }
        )
        let coalesced = duplicateGroups.map { key, messages in
            ASHOperatorCoalescedGroupV4(
                messages: messages,
                coefficients: key.coefficients,
                declaredReasonID: declarations[messages]
            )
        }
        let actualSets = Set(duplicateGroups.map(\.1))
        let declaredSets = Set(operatorManifest.intentionalCoalescences.map(\.messages))
        let accidental = actualSets.subtracting(declaredSets).sorted {
            $0.lexicographicallyPrecedes($1)
        }
        let stale = declaredSets.subtracting(actualSets).sorted {
            $0.lexicographicallyPrecedes($1)
        }

        let baseline = try operatorManifest.entry(forMessage: 0).coefficients
        let differenceRows = try operatorManifest.entries.dropFirst().map {
            entry -> [Int64] in
            guard entry.coefficients.count == baseline.count else {
                throw ASHDepthFourBranchProgramV4Error.invalidOperatorManifest
            }
            return zip(entry.coefficients, baseline).map {
                Int64($0.0) - Int64($0.1)
            }
        }
        return ASHOperatorDistinctnessAuditV4(
            operatorControlRank: try Self.exactRank(of: differenceRows),
            distinctOperatorCount: groups.count,
            coalescedGroups: coalesced,
            accidentallyCoalescedGroups: accidental,
            staleDeclarations: stale
        )
    }

    private func stateInfluenceAudit() throws -> (
        message: [UInt8],
        operator: [UInt8]
    ) {
        let baselineState = try ASHState(payloadBits: Array(repeating: 0, count: 8))
        let baseline = try makeConditionedWeights(for: baselineState)
        let baselineMessage = baseline.weightsByMessage.map(\.numerator)
        let baselineOperator = Self.operatorTotals(baseline.weightsByMessage)
        var messageInfluence: [UInt8] = []
        var operatorInfluence: [UInt8] = []
        for coordinate in UInt8(1)...UInt8(8) {
            var payload = Array(repeating: 0, count: 8)
            payload[Int(coordinate) - 1] = 1
            let state = try ASHState(payloadBits: payload)
            let changed = try makeConditionedWeights(for: state)
            if changed.weightsByMessage.map(\.numerator) != baselineMessage {
                messageInfluence.append(coordinate)
            }
            if Self.operatorTotals(changed.weightsByMessage) != baselineOperator {
                operatorInfluence.append(coordinate)
            }
        }
        return (messageInfluence, operatorInfluence)
    }

    private static func operatorTotals(
        _ weights: [ASHConditionedMessageWeightV4]
    ) -> [ASHOperatorSignatureKeyV4: UInt64] {
        var totals: [ASHOperatorSignatureKeyV4: UInt64] = [:]
        for weight in weights {
            let key = ASHOperatorSignatureKeyV4(weight.operatorCoefficients)
            totals[key, default: 0] += weight.numerator
        }
        return totals
    }

    private static func gf2RankProof(
        rows: [UInt16],
        coordinateCount: Int
    ) -> ASHGF2RankProofV4 {
        var matrix = rows
        var pivotRow = 0
        var pivots: [Int] = []
        for coordinate in 1...coordinateCount where pivotRow < matrix.count {
            let bit = UInt16(1 << (coordinateCount - coordinate))
            guard let found = (pivotRow..<matrix.count).first(where: {
                matrix[$0] & bit != 0
            }) else {
                continue
            }
            matrix.withUnsafeMutableBufferPointer { rows in
                if found != pivotRow {
                    let displaced = rows[pivotRow]
                    rows[pivotRow] = rows[found]
                    rows[found] = displaced
                }
                let pivot = rows[pivotRow]
                for row in rows.indices where row != pivotRow
                    && rows[row] & bit != 0 {
                    rows[row] ^= pivot
                }
            }
            pivots.append(coordinate)
            pivotRow += 1
        }
        return ASHGF2RankProofV4(
            rowCount: rows.count,
            coordinateCount: coordinateCount,
            rank: pivotRow,
            pivotCoordinates: pivots
        )
    }

    private static func exactRank(of integerRows: [[Int64]]) throws -> Int {
        guard let columnCount = integerRows.first?.count else { return 0 }
        guard integerRows.allSatisfy({ $0.count == columnCount }) else {
            throw ASHDepthFourBranchProgramV4Error.invalidOperatorManifest
        }
        var matrix = integerRows.map { $0.map(ASHExactFractionV4.init) }
        var pivotRow = 0
        for column in 0..<columnCount where pivotRow < matrix.count {
            guard let found = (pivotRow..<matrix.count).first(where: {
                !matrix[$0][column].isZero
            }) else {
                continue
            }
            if found != pivotRow {
                matrix.withUnsafeMutableBufferPointer { rows in
                    let displaced = rows[pivotRow]
                    rows[pivotRow] = rows[found]
                    rows[found] = displaced
                }
            }
            let pivotRowValues = matrix[pivotRow]
            let pivot = pivotRowValues[column]
            for row in matrix.indices where row != pivotRow
                && !matrix[row][column].isZero {
                let factor = try matrix[row][column].divided(by: pivot)
                for targetColumn in column..<columnCount {
                    matrix[row][targetColumn] = try matrix[row][targetColumn]
                        .subtracting(
                            factor.multiplied(
                                by: pivotRowValues[targetColumn]
                            )
                        )
                }
            }
            pivotRow += 1
        }
        return pivotRow
    }
}

enum ASHDepthFourBranchCompilerV4 {
    /// Offline dynamic programming over 16 message buckets. The 81 leaf paths
    /// are never represented as nodes.
    static func compile(
        grammar: ASHDepthFourGrammarV4,
        messageCodewordMap: ASHMessageCodewordMapV4,
        operatorManifest: ASHOperatorManifestV4,
        conditioningPolicy: ASHStateConditioningPolicyV4,
        programID: String = ASHDepthFourBranchProgramV4.canonicalProgramID
    ) throws -> ASHDepthFourBranchProgramV4 {
        var masses = Array(repeating: UInt64(0), count: 16)
        masses[0] = 1
        var denominator: UInt64 = 1
        var leafCount: UInt64 = 1
        for level in 0..<ASHDepthFourGrammarV4.depth {
            var next = Array(repeating: UInt64(0), count: 16)
            for rawMessage in 0..<16 where masses[rawMessage] != 0 {
                for actionIndex in 0..<ASHDepthFourGrammarV4.actionCount {
                    let child = try grammar.childMessage(
                        parentRawValue: UInt8(rawMessage),
                        actionIndex: actionIndex,
                        level: level
                    )
                    let product = masses[rawMessage].multipliedReportingOverflow(
                        by: UInt64(grammar.actionMassNumerators[actionIndex])
                    )
                    guard !product.overflow else {
                        throw ASHDepthFourBranchProgramV4Error.arithmeticOverflow
                    }
                    let addition = next[Int(child)].addingReportingOverflow(
                        product.partialValue
                    )
                    guard !addition.overflow else {
                        throw ASHDepthFourBranchProgramV4Error.arithmeticOverflow
                    }
                    next[Int(child)] = addition.partialValue
                }
            }
            masses = next
            let denominatorProduct = denominator.multipliedReportingOverflow(
                by: UInt64(grammar.actionMassDenominator)
            )
            let leafProduct = leafCount.multipliedReportingOverflow(by: 3)
            guard !denominatorProduct.overflow, !leafProduct.overflow else {
                throw ASHDepthFourBranchProgramV4Error.arithmeticOverflow
            }
            denominator = denominatorProduct.partialValue
            leafCount = leafProduct.partialValue
        }
        let weights = try (0..<16).map { rawMessage in
            ASHAggregatedMessageWeightV4(
                messageRawValue: UInt8(rawMessage),
                codewordRawValue: try messageCodewordMap.codewordRawValue(
                    forMessage: UInt8(rawMessage)
                ),
                massNumerator: masses[rawMessage]
            )
        }
        return try ASHDepthFourBranchProgramV4(
            schemaVersion: ASHDepthFourBranchProgramV4.supportedSchemaVersion,
            programID: programID,
            grammar: grammar,
            leafCount: leafCount,
            baseMassDenominator: denominator,
            baseWeightsByMessage: weights,
            messageCodewordMap: messageCodewordMap,
            operatorManifest: operatorManifest,
            conditioningPolicy: conditioningPolicy
        )
    }

    static func compileCanonical() throws -> ASHDepthFourBranchProgramV4 {
        let program = try compile(
            grammar: .canonical,
            messageCodewordMap: .canonical,
            operatorManifest: .canonicalP06,
            conditioningPolicy: .canonical
        )
        try program.validateCanonical()
        return program
    }
}

// MARK: - Deterministic artifact serialization

extension ASHDepthFourBranchProgramV4 {
    private static let binaryMagic: [UInt8] = [0x41, 0x53, 0x48, 0x42] // ASHB

    func serializedCanonical() throws -> Data {
        try validateCanonical()
        var writer = ASHBranchBinaryWriterV4()
        writer.append(bytes: Self.binaryMagic)
        writer.append(schemaVersion)
        try writer.append(string: programID)
        writer.append(grammar.actionMassDenominator)
        writer.append(UInt8(grammar.actionMassNumerators.count))
        grammar.actionMassNumerators.forEach { writer.append($0) }
        writer.append(UInt8(grammar.positiveToggleMasksByLevel.count))
        grammar.positiveToggleMasksByLevel.forEach { writer.append($0) }
        writer.append(UInt8(grammar.negativeToggleMasksByLevel.count))
        grammar.negativeToggleMasksByLevel.forEach { writer.append($0) }
        writer.append(leafCount)
        writer.append(baseMassDenominator)

        writer.append(UInt8(messageCodewordMap.entries.count))
        for entry in messageCodewordMap.entries {
            writer.append(entry.messageRawValue)
            writer.append(entry.codewordRawValue)
        }
        writer.append(UInt8(baseWeightsByMessage.count))
        for weight in baseWeightsByMessage {
            writer.append(weight.messageRawValue)
            writer.append(weight.codewordRawValue)
            writer.append(weight.massNumerator)
        }

        try writer.append(string: operatorManifest.manifestID)
        writer.append(UInt8(operatorManifest.basisIDs.count))
        for basisID in operatorManifest.basisIDs {
            try writer.append(string: basisID)
        }
        writer.append(UInt8(operatorManifest.entries.count))
        for entry in operatorManifest.entries {
            writer.append(entry.messageRawValue)
            writer.append(UInt8(entry.coefficients.count))
            entry.coefficients.forEach { writer.append($0) }
        }
        writer.append(UInt8(operatorManifest.intentionalCoalescences.count))
        for declaration in operatorManifest.intentionalCoalescences {
            writer.append(UInt8(declaration.messages.count))
            declaration.messages.forEach { writer.append($0) }
            try writer.append(string: declaration.reasonID)
        }

        try writer.append(string: conditioningPolicy.policyID)
        writer.append(conditioningPolicy.matchingBitMultiplier)
        writer.append(UInt8(conditioningPolicy.coordinatePairsByMessageBit.count))
        for pair in conditioningPolicy.coordinatePairsByMessageBit {
            writer.append(pair.firstCoordinate)
            writer.append(pair.secondCoordinate)
        }
        return writer.data
    }

    static func decodeCanonical(from data: Data) throws -> Self {
        var reader = ASHBranchBinaryReaderV4(data: data)
        guard try reader.readBytes(count: binaryMagic.count) == binaryMagic else {
            throw ASHDepthFourBranchProgramV4Error.invalidSerialization
        }
        let schemaVersion = try reader.readUInt16()
        let programID = try reader.readString()
        let actionDenominator = try reader.readUInt16()
        let actionCount = Int(try reader.readUInt8())
        let actionNumerators = try (0..<actionCount).map { _ in
            try reader.readUInt16()
        }
        let positiveCount = Int(try reader.readUInt8())
        let positive = try (0..<positiveCount).map { _ in
            try reader.readUInt8()
        }
        let negativeCount = Int(try reader.readUInt8())
        let negative = try (0..<negativeCount).map { _ in
            try reader.readUInt8()
        }
        let grammar = try ASHDepthFourGrammarV4(
            actionMassDenominator: actionDenominator,
            actionMassNumerators: actionNumerators,
            positiveToggleMasksByLevel: positive,
            negativeToggleMasksByLevel: negative
        )
        let leafCount = try reader.readUInt64()
        let massDenominator = try reader.readUInt64()

        let mapCount = Int(try reader.readUInt8())
        let mapEntries = try (0..<mapCount).map { _ in
            ASHMessageCodewordEntryV4(
                messageRawValue: try reader.readUInt8(),
                codewordRawValue: try reader.readUInt16()
            )
        }
        let messageMap = try ASHMessageCodewordMapV4(entries: mapEntries)
        let weightCount = Int(try reader.readUInt8())
        let weights = try (0..<weightCount).map { _ in
            ASHAggregatedMessageWeightV4(
                messageRawValue: try reader.readUInt8(),
                codewordRawValue: try reader.readUInt16(),
                massNumerator: try reader.readUInt64()
            )
        }

        let manifestID = try reader.readString()
        let basisCount = Int(try reader.readUInt8())
        let basisIDs = try (0..<basisCount).map { _ in
            try reader.readString()
        }
        let operatorCount = Int(try reader.readUInt8())
        let operatorEntries = try (0..<operatorCount).map { _ in
            let message = try reader.readUInt8()
            let coefficientCount = Int(try reader.readUInt8())
            let coefficients = try (0..<coefficientCount).map { _ in
                try reader.readInt16()
            }
            return ASHOperatorEntryV4(
                messageRawValue: message,
                coefficients: coefficients
            )
        }
        let declarationCount = Int(try reader.readUInt8())
        let declarations = try (0..<declarationCount).map { _ in
            let messageCount = Int(try reader.readUInt8())
            let messages = try (0..<messageCount).map { _ in
                try reader.readUInt8()
            }
            return try ASHOperatorCoalescenceDeclarationV4(
                messages: messages,
                reasonID: reader.readString()
            )
        }
        let manifest = try ASHOperatorManifestV4(
            manifestID: manifestID,
            basisIDs: basisIDs,
            entries: operatorEntries,
            intentionalCoalescences: declarations
        )

        let conditioningID = try reader.readString()
        let multiplier = try reader.readUInt16()
        let pairCount = Int(try reader.readUInt8())
        let pairs = try (0..<pairCount).map { _ in
            try ASHStateControlPairV4(
                firstCoordinate: reader.readUInt8(),
                secondCoordinate: reader.readUInt8()
            )
        }
        guard reader.isAtEnd else {
            throw ASHDepthFourBranchProgramV4Error.trailingSerializationBytes
        }
        let conditioning = try ASHStateConditioningPolicyV4(
            policyID: conditioningID,
            coordinatePairsByMessageBit: pairs,
            matchingBitMultiplier: multiplier
        )
        let decoded = try Self(
            schemaVersion: schemaVersion,
            programID: programID,
            grammar: grammar,
            leafCount: leafCount,
            baseMassDenominator: massDenominator,
            baseWeightsByMessage: weights,
            messageCodewordMap: messageMap,
            operatorManifest: manifest,
            conditioningPolicy: conditioning
        )
        try decoded.validateCanonical()
        return decoded
    }
}

private struct ASHOperatorSignatureKeyV4: Hashable {
    let coefficients: [Int16]

    init(_ coefficients: [Int16]) {
        self.coefficients = coefficients
    }
}

private struct ASHExactFractionV4: Equatable {
    let numerator: Int64
    let denominator: Int64

    var isZero: Bool { numerator == 0 }

    init(_ integer: Int64) {
        self.numerator = integer
        self.denominator = 1
    }

    init(numerator: Int64, denominator: Int64) throws {
        guard denominator != 0, numerator != Int64.min,
              denominator != Int64.min else {
            throw ASHDepthFourBranchProgramV4Error.arithmeticOverflow
        }
        if numerator == 0 {
            self.numerator = 0
            self.denominator = 1
            return
        }
        let sign: Int64 = denominator < 0 ? -1 : 1
        let signedNumerator = numerator.multipliedReportingOverflow(by: sign)
        let positiveDenominator = denominator.multipliedReportingOverflow(by: sign)
        guard !signedNumerator.overflow, !positiveDenominator.overflow else {
            throw ASHDepthFourBranchProgramV4Error.arithmeticOverflow
        }
        let divisor = Self.gcd(
            signedNumerator.partialValue.magnitude,
            positiveDenominator.partialValue.magnitude
        )
        self.numerator = signedNumerator.partialValue / Int64(divisor)
        self.denominator = positiveDenominator.partialValue / Int64(divisor)
    }

    func multiplied(by other: Self) throws -> Self {
        let numeratorProduct = numerator.multipliedReportingOverflow(
            by: other.numerator
        )
        let denominatorProduct = denominator.multipliedReportingOverflow(
            by: other.denominator
        )
        guard !numeratorProduct.overflow, !denominatorProduct.overflow else {
            throw ASHDepthFourBranchProgramV4Error.arithmeticOverflow
        }
        return try Self(
            numerator: numeratorProduct.partialValue,
            denominator: denominatorProduct.partialValue
        )
    }

    func divided(by other: Self) throws -> Self {
        guard !other.isZero else {
            throw ASHDepthFourBranchProgramV4Error.arithmeticOverflow
        }
        let numeratorProduct = numerator.multipliedReportingOverflow(
            by: other.denominator
        )
        let denominatorProduct = denominator.multipliedReportingOverflow(
            by: other.numerator
        )
        guard !numeratorProduct.overflow, !denominatorProduct.overflow else {
            throw ASHDepthFourBranchProgramV4Error.arithmeticOverflow
        }
        return try Self(
            numerator: numeratorProduct.partialValue,
            denominator: denominatorProduct.partialValue
        )
    }

    func subtracting(_ other: Self) throws -> Self {
        let left = numerator.multipliedReportingOverflow(by: other.denominator)
        let right = other.numerator.multipliedReportingOverflow(by: denominator)
        let common = denominator.multipliedReportingOverflow(
            by: other.denominator
        )
        guard !left.overflow, !right.overflow, !common.overflow else {
            throw ASHDepthFourBranchProgramV4Error.arithmeticOverflow
        }
        let difference = left.partialValue.subtractingReportingOverflow(
            right.partialValue
        )
        guard !difference.overflow else {
            throw ASHDepthFourBranchProgramV4Error.arithmeticOverflow
        }
        return try Self(
            numerator: difference.partialValue,
            denominator: common.partialValue
        )
    }

    private static func gcd(_ left: UInt64, _ right: UInt64) -> UInt64 {
        var a = left
        var b = right
        while b != 0 {
            (a, b) = (b, a % b)
        }
        return max(a, 1)
    }
}

private struct ASHBranchBinaryWriterV4 {
    var data = Data()

    mutating func append(_ value: UInt8) { data.append(value) }

    mutating func append(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }

    mutating func append(_ value: Int16) {
        append(UInt16(bitPattern: value))
    }

    mutating func append(_ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            append(UInt8((value >> UInt64(shift)) & 0xff))
        }
    }

    mutating func append(bytes: [UInt8]) { data.append(contentsOf: bytes) }

    mutating func append(string: String) throws {
        let bytes = Array(string.utf8)
        guard let count = UInt8(exactly: bytes.count), count > 0 else {
            throw ASHDepthFourBranchProgramV4Error.invalidSerialization
        }
        append(count)
        append(bytes: bytes)
    }
}

private struct ASHBranchBinaryReaderV4 {
    let data: Data
    private(set) var offset = 0

    var isAtEnd: Bool { offset == data.count }

    mutating func readUInt8() throws -> UInt8 {
        guard offset < data.count else {
            throw ASHDepthFourBranchProgramV4Error.invalidSerialization
        }
        defer { offset += 1 }
        return data[data.startIndex + offset]
    }

    mutating func readUInt16() throws -> UInt16 {
        (UInt16(try readUInt8()) << 8) | UInt16(try readUInt8())
    }

    mutating func readInt16() throws -> Int16 {
        Int16(bitPattern: try readUInt16())
    }

    mutating func readUInt64() throws -> UInt64 {
        var result: UInt64 = 0
        for _ in 0..<8 {
            result = (result << 8) | UInt64(try readUInt8())
        }
        return result
    }

    mutating func readBytes(count: Int) throws -> [UInt8] {
        guard count >= 0, offset <= data.count - count else {
            throw ASHDepthFourBranchProgramV4Error.invalidSerialization
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
            throw ASHDepthFourBranchProgramV4Error.invalidSerialization
        }
        return value
    }
}
