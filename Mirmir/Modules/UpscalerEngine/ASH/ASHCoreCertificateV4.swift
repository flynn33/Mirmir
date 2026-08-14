/// Exhaustive, deterministic evidence for the finite ASHCoreV4 domain.
///
/// Generation performs no I/O and reads no runtime configuration. A release
/// artifact loader can compare its declared core identity with this certificate
/// before exposing pixel-processing functionality.
struct ASHCoreCertificateV4: Equatable, Sendable {
    let stateCount: Int
    let integrityStateCount: Int
    let codewordCount: Int
    let minimumCodeDistance: Int

    let strictExactCount: Int
    let strictCorrectedCount: Int
    let strictUncorrectableCount: Int
    let strictDecodeMatchesRadiusOneContract: Bool

    let affineExactCount: Int
    let affineOneBitCorrectedCount: Int
    let affineTwoBitRejectedCount: Int

    let orbitCount: Int
    let integrityOrbitCount: Int
    let orbitPartitionIsValid: Bool
    let orbitProjectionIsIdempotent: Bool

    let branchLeafCount: UInt64
    let branchUniqueMessageCount: Int
    let branchMassDenominator: UInt64
    let branchMassNumeratorsByMessage: [UInt64]

    let generatorRowsMatchCurrentModel: Bool
    let codewordsMatchCurrentModel: Bool
    let translationPreservesCoordinateEight: Bool
    let codewordsSatisfyCoordinateNineIntegrity: Bool
    let currentFourthGeneratorIsCanonical: Bool
    let transposedLegacyFourthGeneratorIsRejected: Bool

    var isValid: Bool {
        stateCount == 512
            && integrityStateCount == 256
            && codewordCount == 16
            && minimumCodeDistance == 4
            && strictExactCount == 16
            && strictCorrectedCount == 144
            && strictUncorrectableCount == 352
            && strictDecodeMatchesRadiusOneContract
            && affineExactCount == 4_096
            && affineOneBitCorrectedCount == 36_864
            && affineTwoBitRejectedCount == 147_456
            && orbitCount == 32
            && integrityOrbitCount == 16
            && orbitPartitionIsValid
            && orbitProjectionIsIdempotent
            && branchLeafCount == 81
            && branchUniqueMessageCount == 16
            && branchMassDenominator == 256
            && branchMassNumeratorsByMessage
                == ASHCoreV4.expectedDepthFourBranchMassNumerators
            && branchMassNumeratorsByMessage.reduce(0, +) == branchMassDenominator
            && generatorRowsMatchCurrentModel
            && codewordsMatchCurrentModel
            && translationPreservesCoordinateEight
            && codewordsSatisfyCoordinateNineIntegrity
            && currentFourthGeneratorIsCanonical
            && transposedLegacyFourthGeneratorIsRejected
    }

    static func generate() -> ASHCoreCertificateV4 {
        let allStates = (0..<ASHCoreV4.stateCount).map {
            ASHState(validatedRawValue: UInt16($0))
        }
        let integrityStates = allStates.filter(\.hasValidIntegrity)
        let codewords = ASHCoreV4.canonicalCodewordsByMessage

        let minimumCodeDistance = minimumDistance(in: codewords)
        let strictEvidence = strictDecodeEvidence(
            in: allStates,
            codewords: codewords
        )
        let affineCounts = affineDecodeCounts(
            anchors: integrityStates,
            codewords: codewords
        )
        let orbitEvidence = orbitEvidence(
            allStates: allStates,
            integrityStates: integrityStates
        )
        let branch = ASHCoreV4.branchDistribution(depth: 4)

        let encodedCodewords = (0..<ASHCoreV4.codewordCount).map {
            ASHCoreV4.encode(ASHMessage(validatedRawValue: UInt8($0)))
        }

        return ASHCoreCertificateV4(
            stateCount: allStates.count,
            integrityStateCount: integrityStates.count,
            codewordCount: codewords.count,
            minimumCodeDistance: minimumCodeDistance,
            strictExactCount: strictEvidence.exact,
            strictCorrectedCount: strictEvidence.corrected,
            strictUncorrectableCount: strictEvidence.uncorrectable,
            strictDecodeMatchesRadiusOneContract: strictEvidence.matchesContract,
            affineExactCount: affineCounts.exact,
            affineOneBitCorrectedCount: affineCounts.oneBitCorrected,
            affineTwoBitRejectedCount: affineCounts.twoBitRejected,
            orbitCount: orbitEvidence.orbitCount,
            integrityOrbitCount: orbitEvidence.integrityOrbitCount,
            orbitPartitionIsValid: orbitEvidence.partitionIsValid,
            orbitProjectionIsIdempotent: orbitEvidence.projectionIsIdempotent,
            branchLeafCount: branch.leafCount,
            branchUniqueMessageCount: branch.uniqueMessageCount,
            branchMassDenominator: branch.massDenominator,
            branchMassNumeratorsByMessage: branch.massNumeratorsByMessage,
            generatorRowsMatchCurrentModel: ASHCode.generatorRows
                == ASHCoreV4.canonicalGeneratorRows,
            codewordsMatchCurrentModel: encodedCodewords
                == ASHCoreV4.canonicalCodewordsByMessage,
            translationPreservesCoordinateEight: codewords.allSatisfy {
                $0.bit(coordinate: ASHCoreV4.translationInvariantCoordinate) == 0
            },
            codewordsSatisfyCoordinateNineIntegrity: codewords.allSatisfy(
                \.hasValidIntegrity
            ),
            currentFourthGeneratorIsCanonical: ASHCoreV4.isCanonicalCodeword(
                ASHCoreV4.canonicalGeneratorRows[3]
            ),
            transposedLegacyFourthGeneratorIsRejected:
                !ASHCoreV4.isCanonicalCodeword(ASHCoreV4.transposedLegacyFourthGenerator)
                && ASHCoreV4.decodeStrict(ASHCoreV4.transposedLegacyFourthGenerator).status
                    == .uncorrectable
        )
    }

    private static func minimumDistance(in codewords: [ASHState]) -> Int {
        var minimum = ASHState.bitCount + 1
        for leftIndex in codewords.indices {
            for rightIndex in codewords.indices where rightIndex > leftIndex {
                minimum = min(
                    minimum,
                    codewords[leftIndex].hammingDistance(to: codewords[rightIndex])
                )
            }
        }
        return minimum
    }

    private static func strictDecodeEvidence(
        in states: [ASHState],
        codewords: [ASHState]
    ) -> (
        exact: Int,
        corrected: Int,
        uncorrectable: Int,
        matchesContract: Bool
    ) {
        var exact = 0
        var corrected = 0
        var uncorrectable = 0
        var matchesContract = true

        for state in states {
            let result = ASHCoreV4.decodeStrict(state)
            switch result.status {
            case .exact:
                exact += 1
            case .corrected:
                corrected += 1
            case .uncorrectable:
                uncorrectable += 1
            }

            var minimumDistance = ASHState.bitCount + 1
            var nearestIndices: [Int] = []
            for (index, codeword) in codewords.enumerated() {
                let distance = state.hammingDistance(to: codeword)
                if distance < minimumDistance {
                    minimumDistance = distance
                    nearestIndices = [index]
                } else if distance == minimumDistance {
                    nearestIndices.append(index)
                }
            }

            let hasUniqueRecoverableNeighbor = minimumDistance <= 1
                && nearestIndices.count == 1
            let expectedStatus: ASHDecodeStatus
            let expectedState: ASHState?
            let expectedMessage: ASHMessage?
            if hasUniqueRecoverableNeighbor {
                let index = nearestIndices[0]
                expectedStatus = minimumDistance == 0 ? .exact : .corrected
                expectedState = codewords[index]
                expectedMessage = ASHMessage(validatedRawValue: UInt8(index))
            } else {
                expectedStatus = .uncorrectable
                expectedState = nil
                expectedMessage = nil
            }

            if result.status != expectedStatus
                || result.resolvedState != expectedState
                || result.message != expectedMessage
                || result.distance != minimumDistance
                || result.nearestCount != nearestIndices.count {
                matchesContract = false
            }
        }
        return (exact, corrected, uncorrectable, matchesContract)
    }

    private static func affineDecodeCounts(
        anchors: [ASHState],
        codewords: [ASHState]
    ) -> (exact: Int, oneBitCorrected: Int, twoBitRejected: Int) {
        var exact = 0
        var oneBitCorrected = 0
        var twoBitRejected = 0

        for anchor in anchors {
            for (rawMessage, codeword) in codewords.enumerated() {
                let message = ASHMessage(validatedRawValue: UInt8(rawMessage))
                let expected = anchor.xor(codeword)
                let exactResult = ASHCoreV4.decodeAffine(
                    received: expected,
                    anchor: anchor
                )
                if exactResult.status == .exact,
                   exactResult.resolvedState == expected,
                   exactResult.message == message {
                    exact += 1
                }

                for coordinate in 1...ASHState.bitCount {
                    let correctedResult = ASHCoreV4.decodeAffine(
                        received: expected.toggled(coordinate: coordinate),
                        anchor: anchor
                    )
                    if correctedResult.status == .corrected,
                       correctedResult.resolvedState == expected,
                       correctedResult.message == message,
                       correctedResult.distance == 1,
                       correctedResult.nearestCount == 1 {
                        oneBitCorrected += 1
                    }
                }

                for firstCoordinate in 1..<ASHState.bitCount {
                    for secondCoordinate in (firstCoordinate + 1)...ASHState.bitCount {
                        let corrupted = expected
                            .toggled(coordinate: firstCoordinate)
                            .toggled(coordinate: secondCoordinate)
                        let rejectedResult = ASHCoreV4.decodeAffine(
                            received: corrupted,
                            anchor: anchor
                        )
                        if rejectedResult.status == .uncorrectable,
                           rejectedResult.resolvedState == nil,
                           rejectedResult.message == nil {
                            twoBitRejected += 1
                        }
                    }
                }
            }
        }

        return (exact, oneBitCorrected, twoBitRejected)
    }

    private static func orbitEvidence(
        allStates: [ASHState],
        integrityStates: [ASHState]
    ) -> (
        orbitCount: Int,
        integrityOrbitCount: Int,
        partitionIsValid: Bool,
        projectionIsIdempotent: Bool
    ) {
        let representatives = Set(allStates.map(ASHCoreV4.orbitRepresentative))
        let integrityRepresentatives = Set(
            integrityStates.map(ASHCoreV4.orbitRepresentative)
        )
        var partitionIsValid = true
        var projectionIsIdempotent = true

        for state in allStates {
            let orbit = ASHCoreV4.orbit(of: state)
            let orbitSet = Set(orbit)
            if orbit.count != ASHCoreV4.codewordCount
                || orbitSet.count != ASHCoreV4.codewordCount
                || !orbitSet.contains(state) {
                partitionIsValid = false
            }

            let representative = ASHCoreV4.orbitRepresentative(of: state)
            for member in orbit {
                if ASHCoreV4.orbitRepresentative(of: member) != representative {
                    partitionIsValid = false
                }
                if ASHCoreV4.orbit(of: member) != orbit {
                    projectionIsIdempotent = false
                }
            }
        }

        return (
            representatives.count,
            integrityRepresentatives.count,
            partitionIsValid,
            projectionIsIdempotent
        )
    }
}
