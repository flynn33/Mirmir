/// The canonical, platform-independent ASH algebra used by deterministic engine v4.
///
/// This facade intentionally depends only on `ASHState` and `ASHMessage`.
/// Media, image, runtime, and artifact concerns belong outside this semantic core.
enum ASHCoreV4 {
    static let stateCount = 1 << ASHState.bitCount
    static let integrityStateCount = 1 << ASHState.payloadBitCount
    static let codewordCount = 1 << ASHMessage.bitCount
    static let orbitCount = stateCount / codewordCount
    static let integrityOrbitCount = integrityStateCount / codewordCount

    /// The current ASH Model fixes coordinate 8 under code translations and
    /// recomputes coordinate 9 as application integrity.
    static let translationInvariantCoordinate = 8
    static let integrityCoordinate = 9

    /// Rows are ordered by message bit m1...m4.
    static let canonicalGeneratorRows: [ASHState] = [
        ASHState(validatedRawValue: 0b111100000),
        ASHState(validatedRawValue: 0b110011000),
        ASHState(validatedRawValue: 0b101010100),
        ASHState(validatedRawValue: 0b100110001)
    ]

    /// Codewords are ordered by the numeric four-bit message value 0...15.
    static let canonicalCodewordsByMessage: [ASHState] = [
        ASHState(validatedRawValue: 0b000000000),
        ASHState(validatedRawValue: 0b100110001),
        ASHState(validatedRawValue: 0b101010100),
        ASHState(validatedRawValue: 0b001100101),
        ASHState(validatedRawValue: 0b110011000),
        ASHState(validatedRawValue: 0b010101001),
        ASHState(validatedRawValue: 0b011001100),
        ASHState(validatedRawValue: 0b111111101),
        ASHState(validatedRawValue: 0b111100000),
        ASHState(validatedRawValue: 0b011010001),
        ASHState(validatedRawValue: 0b010110100),
        ASHState(validatedRawValue: 0b110000101),
        ASHState(validatedRawValue: 0b001111000),
        ASHState(validatedRawValue: 0b101001001),
        ASHState(validatedRawValue: 0b100101100),
        ASHState(validatedRawValue: 0b000011101)
    ]

    /// The coordinate-transposed fourth generator used by the older Pattern
    /// System baseline. It is retained solely as a permanent negative vector.
    static let transposedLegacyFourthGenerator = ASHState(
        validatedRawValue: 0b100110010
    )

    /// Independent expected distribution for the canonical depth-four branch
    /// grammar. Values are indexed by the numeric four-bit message and have a
    /// common denominator of 256.
    static let expectedDepthFourBranchMassNumerators: [UInt64] = [
        34, 24, 24, 14,
        24, 18, 14, 8,
        24, 14, 18, 8,
        14, 8, 8, 2
    ]

    /// The complete finite action table, indexed by `(state * 16) + message`.
    /// Keeping this table immutable makes CPU planning, Metal artifact
    /// generation, checkpoint validation, and conformance tests consume the
    /// same full-state XOR action without repeating bit algebra in hot loops.
    private static let transitionTable: [ASHState] = {
        var result: [ASHState] = []
        result.reserveCapacity(stateCount * codewordCount)
        for rawState in 0..<stateCount {
            for codeword in canonicalCodewordsByMessage {
                result.append(
                    ASHState(
                        validatedRawValue: UInt16(rawState) ^ codeword.rawValue
                    )
                )
            }
        }
        return result
    }()

    /// Strict radius-one decoding is finite, so v4 owns a canonical table
    /// instead of delegating semantics to a backend or scanning at runtime.
    private static let strictDecodeTable: [ASHCoreV4DecodeResult] = {
        (0..<stateCount).map { rawState in
            let received = ASHState(validatedRawValue: UInt16(rawState))
            var minimumDistance = ASHState.bitCount + 1
            var nearestMessageRaw = 0
            var nearestCount = 0

            for (messageRaw, codeword) in canonicalCodewordsByMessage.enumerated() {
                let distance = received.hammingDistance(to: codeword)
                if distance < minimumDistance {
                    minimumDistance = distance
                    nearestMessageRaw = messageRaw
                    nearestCount = 1
                } else if distance == minimumDistance {
                    nearestCount += 1
                }
            }

            guard minimumDistance <= 1, nearestCount == 1 else {
                return ASHCoreV4DecodeResult(
                    status: .uncorrectable,
                    received: received,
                    resolvedState: nil,
                    message: nil,
                    distance: minimumDistance,
                    nearestCount: nearestCount
                )
            }

            return ASHCoreV4DecodeResult(
                status: minimumDistance == 0 ? .exact : .corrected,
                received: received,
                resolvedState: canonicalCodewordsByMessage[nearestMessageRaw],
                message: ASHMessage(validatedRawValue: UInt8(nearestMessageRaw)),
                distance: minimumDistance,
                nearestCount: 1
            )
        }
    }()

    private static let messageByRawCodeword: [Int8] = {
        var result = Array(repeating: Int8(-1), count: stateCount)
        for (messageRaw, codeword) in canonicalCodewordsByMessage.enumerated() {
            result[Int(codeword.rawValue)] = Int8(messageRaw)
        }
        return result
    }()

    private static let orbitTable: [ASHState] = {
        var result: [ASHState] = []
        result.reserveCapacity(stateCount * codewordCount)
        for rawState in 0..<stateCount {
            let offset = rawState * codewordCount
            result.append(
                contentsOf: transitionTable[offset..<(offset + codewordCount)]
                    .sorted { $0.rawValue < $1.rawValue }
            )
        }
        return result
    }()

    private static let orbitRepresentativeTable: [ASHState] = {
        (0..<stateCount).map { rawState in
            orbitTable[rawState * codewordCount]
        }
    }()

    static var transitionTableEntryCount: Int {
        transitionTable.count
    }

    static func encode(_ message: ASHMessage) -> ASHState {
        canonicalCodewordsByMessage[Int(message.rawValue)]
    }

    static func message(forCanonicalCodeword codeword: ASHState) -> ASHMessage? {
        let rawMessage = messageByRawCodeword[Int(codeword.rawValue)]
        guard rawMessage >= 0 else {
            return nil
        }
        return ASHMessage(validatedRawValue: UInt8(rawMessage))
    }

    static func isCanonicalCodeword(_ state: ASHState) -> Bool {
        message(forCanonicalCodeword: state) != nil
    }

    static func decodeStrict(_ received: ASHState) -> ASHCoreV4DecodeResult {
        strictDecodeTable[Int(received.rawValue)]
    }

    static func decodeAffine(
        received: ASHState,
        anchor: ASHState
    ) -> ASHCoreV4DecodeResult {
        let relativeResult = decodeStrict(received.xor(anchor))
        return ASHCoreV4DecodeResult(
            status: relativeResult.status,
            received: received,
            resolvedState: relativeResult.resolvedState.map(anchor.xor),
            message: relativeResult.message,
            distance: relativeResult.distance,
            nearestCount: relativeResult.nearestCount
        )
    }

    static func translate(_ state: ASHState, by message: ASHMessage) -> ASHState {
        transitionTable[
            Int(state.rawValue) * codewordCount + Int(message.rawValue)
        ]
    }

    static func translate(
        _ state: ASHState,
        byCanonicalCodeword codeword: ASHState
    ) -> ASHState? {
        guard let message = message(forCanonicalCodeword: codeword) else {
            return nil
        }
        return translate(state, by: message)
    }

    static func orbit(of state: ASHState) -> [ASHState] {
        let offset = Int(state.rawValue) * codewordCount
        return Array(orbitTable[offset..<(offset + codewordCount)])
    }

    static func orbitRepresentative(of state: ASHState) -> ASHState {
        orbitRepresentativeTable[Int(state.rawValue)]
    }

    /// Applies the orbit-averaging numerator once per canonical orbit, then
    /// broadcasts it to all 16 members. Results have the common denominator
    /// `codewordCount`; callers choose their own exact output representation.
    static func orbitAverageNumerators(
        _ valuesByState: [Int64]
    ) throws -> [Int64] {
        guard valuesByState.count == stateCount else {
            throw ASHCoreV4Error.invalidOrbitFunctionCount(
                expected: stateCount,
                actual: valuesByState.count
            )
        }

        var completedRepresentatives = Array(repeating: false, count: stateCount)
        var result = Array(repeating: Int64(0), count: stateCount)
        for rawState in 0..<stateCount {
            let state = ASHState(validatedRawValue: UInt16(rawState))
            let representative = orbitRepresentative(of: state)
            let representativeIndex = Int(representative.rawValue)
            guard !completedRepresentatives[representativeIndex] else {
                continue
            }

            var numerator: Int64 = 0
            for member in orbit(of: representative) {
                let (next, overflow) = numerator.addingReportingOverflow(
                    valuesByState[Int(member.rawValue)]
                )
                guard !overflow else {
                    throw ASHCoreV4Error.orbitAverageOverflow
                }
                numerator = next
            }
            for member in orbit(of: representative) {
                result[Int(member.rawValue)] = numerator
            }
            completedRepresentatives[representativeIndex] = true
        }
        return result
    }

    static func branchMessage(
        from message: ASHMessage,
        action: ASHCoreV4BranchAction,
        level: Int
    ) -> ASHMessage {
        precondition(level >= 0, "ASH branch levels must be nonnegative.")
        switch action {
        case .continuation:
            return message
        case .positive:
            return messageToggling(message, bitIndex: level % ASHMessage.bitCount)
        case .negative:
            return messageToggling(
                message,
                bitIndex: (level + 1) % ASHMessage.bitCount
            )
        }
    }

    /// Aggregates the ternary branch grammar without materializing its tree.
    /// Integer path mass is exact: continuation contributes 2/4 and each
    /// signed branch contributes 1/4 at every level.
    static func branchDistribution(depth: Int) -> ASHCoreV4BranchDistribution {
        precondition((0...15).contains(depth), "ASH branch depth must be in 0...15.")

        var masses = Array(repeating: UInt64(0), count: codewordCount)
        masses[0] = 1
        var denominator: UInt64 = 1
        var leafCount: UInt64 = 1

        for level in 0..<depth {
            var next = Array(repeating: UInt64(0), count: codewordCount)
            for rawMessage in 0..<codewordCount where masses[rawMessage] != 0 {
                let message = ASHMessage(validatedRawValue: UInt8(rawMessage))
                let mass = masses[rawMessage]
                for action in ASHCoreV4BranchAction.canonicalOrder {
                    let child = branchMessage(from: message, action: action, level: level)
                    next[Int(child.rawValue)] += mass * action.massNumerator
                }
            }
            masses = next
            denominator *= 4
            leafCount *= 3
        }

        return ASHCoreV4BranchDistribution(
            depth: depth,
            leafCount: leafCount,
            massDenominator: denominator,
            massNumeratorsByMessage: masses
        )
    }

    private static func messageToggling(
        _ message: ASHMessage,
        bitIndex: Int
    ) -> ASHMessage {
        precondition((0..<ASHMessage.bitCount).contains(bitIndex))
        let mask = UInt8(1 << (ASHMessage.bitCount - 1 - bitIndex))
        return ASHMessage(validatedRawValue: message.rawValue ^ mask)
    }
}

enum ASHCoreV4Error: Error, Equatable, Sendable {
    case invalidOrbitFunctionCount(expected: Int, actual: Int)
    case orbitAverageOverflow
}

struct ASHCoreV4DecodeResult: Equatable, Sendable {
    let status: ASHDecodeStatus
    let received: ASHState

    /// The canonical codeword for strict decoding or the recovered affine
    /// state for affine decoding.
    let resolvedState: ASHState?
    let message: ASHMessage?
    let distance: Int
    let nearestCount: Int
}

enum ASHCoreV4BranchAction: UInt8, Sendable {
    case continuation = 0
    case positive = 1
    case negative = 2

    static let canonicalOrder: [ASHCoreV4BranchAction] = [
        .continuation,
        .positive,
        .negative
    ]

    fileprivate var massNumerator: UInt64 {
        switch self {
        case .continuation:
            return 2
        case .positive, .negative:
            return 1
        }
    }
}

struct ASHCoreV4BranchDistribution: Equatable, Sendable {
    let depth: Int
    let leafCount: UInt64
    let massDenominator: UInt64
    let massNumeratorsByMessage: [UInt64]

    var uniqueMessageCount: Int {
        massNumeratorsByMessage.lazy.filter { $0 != 0 }.count
    }

    var totalMassNumerator: UInt64 {
        massNumeratorsByMessage.reduce(0, +)
    }
}
