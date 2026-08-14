import XCTest
@testable import Mirmir

final class ASHDepthFourBranchProgramV4Tests: XCTestCase {
    func testOfflineCompilerAggregatesAll81LeavesIntoExactSixteenMessageMasses() throws {
        let program = try ASHDepthFourBranchCompilerV4.compileCanonical()

        XCTAssertEqual(program.leafCount, 81)
        XCTAssertEqual(program.baseMassDenominator, 256)
        XCTAssertEqual(program.baseWeightsByMessage.count, 16)
        XCTAssertEqual(
            program.baseWeightsByMessage.map(\.massNumerator),
            [
                34, 24, 24, 14,
                24, 18, 14, 8,
                24, 14, 18, 8,
                14, 8, 8, 2
            ]
        )
        XCTAssertEqual(
            program.baseWeightsByMessage.map(\.massNumerator),
            exhaustiveLeafOracle()
        )
        XCTAssertEqual(
            program.baseWeightsByMessage.reduce(UInt64(0)) {
                $0 + $1.massNumerator
            },
            256
        )
        XCTAssertNoThrow(try program.validateCanonical())
    }

    func testMessageCodewordBijectionUsesExplicitFieldsInBothDirections() throws {
        let canonical = ASHMessageCodewordMapV4.canonical
        let codewordSortedInput = canonical.entries.sorted {
            $0.codewordRawValue < $1.codewordRawValue
        }
        XCTAssertNotEqual(
            codewordSortedInput.map(\.messageRawValue),
            Array(UInt8(0)..<UInt8(16)),
            "numeric codeword order must not be mistaken for message order"
        )
        let rebuilt = try ASHMessageCodewordMapV4(
            entries: Array(codewordSortedInput.reversed())
        )
        for explicit in codewordSortedInput {
            XCTAssertEqual(
                try rebuilt.codewordRawValue(
                    forMessage: explicit.messageRawValue
                ),
                explicit.codewordRawValue
            )
            XCTAssertEqual(
                try rebuilt.messageRawValue(
                    forCodeword: explicit.codewordRawValue
                ),
                explicit.messageRawValue
            )
        }
        XCTAssertThrowsError(try rebuilt.codewordRawValue(forMessage: 16))
        XCTAssertThrowsError(try rebuilt.messageRawValue(forCodeword: 1))
        XCTAssertThrowsError(try rebuilt.messageRawValue(forCodeword: 512))

        var duplicate = canonical.entries
        duplicate[1] = ASHMessageCodewordEntryV4(
            messageRawValue: duplicate[1].messageRawValue,
            codewordRawValue: duplicate[0].codewordRawValue
        )
        XCTAssertThrowsError(try ASHMessageCodewordMapV4(entries: duplicate))
    }

    func testCanonicalRankDistinctnessAndStateInfluenceProofsPass() throws {
        let program = try ASHDepthFourBranchCompilerV4.compileCanonical()
        let audit = try program.audit()

        XCTAssertEqual(audit.branchToggleRankProof.rank, 4)
        XCTAssertEqual(audit.branchToggleRankProof.pivotCoordinates, [1, 2, 3, 4])
        XCTAssertEqual(audit.codewordGeneratorRankProof.rank, 4)
        XCTAssertEqual(
            audit.codewordGeneratorRankProof.pivotCoordinates,
            [1, 2, 3, 5]
        )
        XCTAssertTrue(audit.codewordMapIsLinear)
        XCTAssertEqual(audit.reachableMessageCount, 16)
        XCTAssertEqual(audit.operatorAudit.operatorControlRank, 4)
        XCTAssertEqual(audit.operatorAudit.distinctOperatorCount, 16)
        XCTAssertTrue(audit.operatorAudit.coalescedGroups.isEmpty)
        XCTAssertTrue(audit.operatorAudit.accidentallyCoalescedGroups.isEmpty)
        XCTAssertTrue(audit.operatorAudit.staleDeclarations.isEmpty)
        XCTAssertEqual(
            audit.influentialPayloadCoordinates,
            Array(UInt8(1)...UInt8(8))
        )
        XCTAssertEqual(
            audit.operatorInfluentialPayloadCoordinates,
            Array(UInt8(1)...UInt8(8))
        )
        XCTAssertTrue(audit.isReleaseValid)
    }

    func testPermutedToggleLevelsPreserveAuditWhileForcingLaterPivotSwap()
        throws {
        let canonical = try ASHDepthFourBranchCompilerV4.compileCanonical()
        let permutedGrammar = try ASHDepthFourGrammarV4(
            actionMassDenominator: 4,
            actionMassNumerators: [2, 1, 1],
            positiveToggleMasksByLevel: [
                0b0100, 0b1000, 0b0010, 0b0001
            ],
            negativeToggleMasksByLevel: [
                0b0010, 0b0100, 0b0001, 0b1000
            ]
        )
        let permuted = try ASHDepthFourBranchCompilerV4.compile(
            grammar: permutedGrammar,
            messageCodewordMap: .canonical,
            operatorManifest: .canonicalP06,
            conditioningPolicy: .canonical,
            programID: "ash.audit.permuted-toggle-levels"
        )

        let canonicalAudit = try canonical.audit()
        let permutedAudit = try permuted.audit()
        XCTAssertEqual(
            permutedAudit.branchToggleRankProof,
            ASHGF2RankProofV4(
                rowCount: 4,
                coordinateCount: 4,
                rank: 4,
                pivotCoordinates: [1, 2, 3, 4]
            )
        )
        XCTAssertEqual(permutedAudit, canonicalAudit)
        XCTAssertEqual(
            permuted.baseWeightsByMessage,
            canonical.baseWeightsByMessage
        )
        XCTAssertTrue(permutedAudit.isReleaseValid)
        XCTAssertNoThrow(try permuted.validateRelease())
    }

    func testDeclaredASHModelCancellationAndAccidentalCoalescenceAreSeparated() throws {
        let declaredManifest = try ASHOperatorManifestV4
            .declaredASHModelV1Reference()
        let declaredProgram = try ASHDepthFourBranchCompilerV4.compile(
            grammar: .canonical,
            messageCodewordMap: .canonical,
            operatorManifest: declaredManifest,
            conditioningPolicy: .canonical,
            programID: "ash.audit.declared-model-v1"
        )
        let declaredAudit = try declaredProgram.audit()
        XCTAssertEqual(declaredAudit.operatorAudit.operatorControlRank, 3)
        XCTAssertEqual(declaredAudit.operatorAudit.distinctOperatorCount, 12)
        XCTAssertEqual(
            declaredAudit.operatorAudit.coalescedGroups.map(\.messages),
            [[0, 3], [4, 7], [8, 11], [12, 15]]
        )
        XCTAssertTrue(
            declaredAudit.operatorAudit.coalescedGroups.allSatisfy {
                $0.declaredReasonID
                    == "ash-model-v1.isotropic-controls-cancel"
            }
        )
        XCTAssertTrue(declaredAudit.operatorAudit.allCoalescenceIsIntentional)
        XCTAssertTrue(declaredAudit.isReleaseValid)
        XCTAssertNoThrow(try declaredProgram.validateRelease())

        let accidentalManifest = try ASHOperatorManifestV4(
            manifestID: "ash.audit.accidental-model-v1",
            basisIDs: declaredManifest.basisIDs,
            entries: declaredManifest.entries,
            intentionalCoalescences: []
        )
        let accidentalProgram = try ASHDepthFourBranchCompilerV4.compile(
            grammar: .canonical,
            messageCodewordMap: .canonical,
            operatorManifest: accidentalManifest,
            conditioningPolicy: .canonical,
            programID: "ash.audit.accidental-model-v1"
        )
        let accidentalAudit = try accidentalProgram.audit()
        XCTAssertEqual(
            accidentalAudit.operatorAudit.accidentallyCoalescedGroups,
            [[0, 3], [4, 7], [8, 11], [12, 15]]
        )
        XCTAssertFalse(accidentalAudit.isReleaseValid)
        XCTAssertThrowsError(try accidentalProgram.validateRelease())

        let staleDeclaration = try ASHOperatorCoalescenceDeclarationV4(
            messages: [0, 1],
            reasonID: "ash.audit.stale-declaration"
        )
        let staleManifest = try ASHOperatorManifestV4(
            manifestID: "ash.audit.stale",
            basisIDs: ASHOperatorManifestV4.canonicalP06.basisIDs,
            entries: ASHOperatorManifestV4.canonicalP06.entries,
            intentionalCoalescences: [staleDeclaration]
        )
        let staleProgram = try ASHDepthFourBranchCompilerV4.compile(
            grammar: .canonical,
            messageCodewordMap: .canonical,
            operatorManifest: staleManifest,
            conditioningPolicy: .canonical,
            programID: "ash.audit.stale"
        )
        XCTAssertEqual(
            try staleProgram.audit().operatorAudit.staleDeclarations,
            [[0, 1]]
        )
        XCTAssertThrowsError(try staleProgram.validateRelease())
    }

    func testRankDeficientGrammarAndNonlinearCodeMapFailReleaseAudit() throws {
        let deficientGrammar = try ASHDepthFourGrammarV4(
            actionMassDenominator: 4,
            actionMassNumerators: [2, 1, 1],
            positiveToggleMasksByLevel: [8, 8, 8, 8],
            negativeToggleMasksByLevel: [4, 4, 4, 4]
        )
        let deficientProgram = try ASHDepthFourBranchCompilerV4.compile(
            grammar: deficientGrammar,
            messageCodewordMap: .canonical,
            operatorManifest: .canonicalP06,
            conditioningPolicy: .canonical,
            programID: "ash.audit.rank-deficient"
        )
        let deficientAudit = try deficientProgram.audit()
        XCTAssertEqual(deficientAudit.branchToggleRankProof.rank, 1)
        XCTAssertEqual(deficientAudit.reachableMessageCount, 4)
        XCTAssertFalse(deficientAudit.isReleaseValid)
        XCTAssertThrowsError(try deficientProgram.validateRelease())

        var swappedEntries = ASHMessageCodewordMapV4.canonical.entries
        let firstCodeword = swappedEntries[0].codewordRawValue
        swappedEntries[0] = ASHMessageCodewordEntryV4(
            messageRawValue: swappedEntries[0].messageRawValue,
            codewordRawValue: swappedEntries[1].codewordRawValue
        )
        swappedEntries[1] = ASHMessageCodewordEntryV4(
            messageRawValue: swappedEntries[1].messageRawValue,
            codewordRawValue: firstCodeword
        )
        let nonlinearMap = try ASHMessageCodewordMapV4(entries: swappedEntries)
        XCTAssertThrowsError(try nonlinearMap.validateCanonical())
        let nonlinearProgram = try ASHDepthFourBranchCompilerV4.compile(
            grammar: .canonical,
            messageCodewordMap: nonlinearMap,
            operatorManifest: .canonicalP06,
            conditioningPolicy: .canonical,
            programID: "ash.audit.nonlinear-code-map"
        )
        XCTAssertFalse(try nonlinearProgram.audit().codewordMapIsLinear)
        XCTAssertThrowsError(try nonlinearProgram.validateRelease())
    }

    func testEveryIntegrityStateProducesExactPositiveDeterministicWeights() throws {
        let program = try ASHDepthFourBranchCompilerV4.compileCanonical()
        for rawPayload in 0..<256 {
            let payload = (0..<8).map { index in
                (rawPayload >> (7 - index)) & 1
            }
            let state = try ASHState(payloadBits: payload)
            let first = try program.conditionedWeights(for: state)
            let second = try program.conditionedWeights(for: state)
            XCTAssertEqual(first, second)
            XCTAssertEqual(first.weightsByMessage.count, 16)
            XCTAssertTrue(first.weightsByMessage.allSatisfy { $0.numerator > 0 })
            XCTAssertEqual(
                first.denominator,
                first.weightsByMessage.reduce(UInt64(0)) {
                    $0 + $1.numerator
                }
            )
            let firstTargetBit = payload[0] ^ payload[4]
            let secondTargetBit = payload[1] ^ payload[5]
            let thirdTargetBit = payload[2] ^ payload[6]
            let fourthTargetBit = payload[3] ^ payload[7]
            let expectedTarget = UInt8(
                (firstTargetBit << 3)
                    | (secondTargetBit << 2)
                    | (thirdTargetBit << 1)
                    | fourthTargetBit
            )
            XCTAssertEqual(first.targetMessageRawValue, expectedTarget)
            for weight in first.weightsByMessage {
                XCTAssertEqual(
                    weight.codewordRawValue,
                    try program.messageCodewordMap.codewordRawValue(
                        forMessage: weight.messageRawValue
                    )
                )
                XCTAssertEqual(weight.operatorCoefficients.count, 4)
            }
        }
    }

    func testEachPayloadCoordinateMateriallyChangesMessageAndOperatorWeights() throws {
        let program = try ASHDepthFourBranchCompilerV4.compileCanonical()
        let zero = try ASHState(payloadBits: Array(repeating: 0, count: 8))
        let baseline = try program.conditionedWeights(for: zero)
        let baselineNumerators = baseline.weightsByMessage.map(\.numerator)

        for coordinate in 0..<8 {
            var payload = Array(repeating: 0, count: 8)
            payload[coordinate] = 1
            let changed = try program.conditionedWeights(
                for: ASHState(payloadBits: payload)
            )
            XCTAssertNotEqual(changed.weightsByMessage.map(\.numerator), baselineNumerators)
            XCTAssertNotEqual(changed.targetMessageRawValue, baseline.targetMessageRawValue)
        }

        let targetFifteen = try ASHState(
            payloadBits: [1, 1, 1, 1, 0, 0, 0, 0]
        )
        let changedRanking = try program.conditionedWeights(for: targetFifteen)
        XCTAssertNotEqual(
            changedRanking.rankedWeights.map(\.messageRawValue),
            baseline.rankedWeights.map(\.messageRawValue)
        )

        let invalidState = try ASHState(rawValue: 1)
        XCTAssertThrowsError(try program.conditionedWeights(for: invalidState))
    }

    func testCanonicalProgramSerializationRejectsTruncationTrailingAndCorruption() throws {
        let program = try ASHDepthFourBranchCompilerV4.compileCanonical()
        let data = try program.serializedCanonical()
        XCTAssertEqual(
            try ASHDepthFourBranchProgramV4.decodeCanonical(from: data),
            program
        )
        XCTAssertEqual(try program.serializedCanonical(), data)

        for count in 0..<data.count {
            XCTAssertThrowsError(
                try ASHDepthFourBranchProgramV4.decodeCanonical(
                    from: Data(data.prefix(count))
                ),
                "accepted prefix length \(count)"
            )
        }
        var trailing = data
        trailing.append(0)
        XCTAssertThrowsError(
            try ASHDepthFourBranchProgramV4.decodeCanonical(from: trailing)
        )
        var badMagic = data
        badMagic[badMagic.startIndex] ^= 0xff
        XCTAssertThrowsError(
            try ASHDepthFourBranchProgramV4.decodeCanonical(from: badMagic)
        )
        var badFinalPair = data
        badFinalPair[badFinalPair.index(before: badFinalPair.endIndex)] = 9
        XCTAssertThrowsError(
            try ASHDepthFourBranchProgramV4.decodeCanonical(from: badFinalPair)
        )

        let nonCanonical = try ASHDepthFourBranchCompilerV4.compile(
            grammar: .canonical,
            messageCodewordMap: .canonical,
            operatorManifest: try .declaredASHModelV1Reference(),
            conditioningPolicy: .canonical,
            programID: "ash.audit.not-canonical"
        )
        XCTAssertThrowsError(try nonCanonical.serializedCanonical())
    }

    private func exhaustiveLeafOracle() -> [UInt64] {
        let positive: [UInt8] = [8, 4, 2, 1]
        let negative: [UInt8] = [4, 2, 1, 8]
        let actionMass: [UInt64] = [2, 1, 1]
        var totals = Array(repeating: UInt64(0), count: 16)
        for ordinal in 0..<81 {
            var remaining = ordinal
            var message: UInt8 = 0
            var mass: UInt64 = 1
            for (level, divisor) in [27, 9, 3, 1].enumerated() {
                let action = remaining / divisor
                remaining %= divisor
                if action == 1 {
                    message ^= positive[level]
                } else if action == 2 {
                    message ^= negative[level]
                }
                mass *= actionMass[action]
            }
            totals[Int(message)] += mass
        }
        return totals
    }
}
