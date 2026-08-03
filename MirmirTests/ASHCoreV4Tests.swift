import XCTest
@testable import Mirmir

final class ASHCoreV4Tests: XCTestCase {
    func testProductionSourceTrustRootRejectsBothZeroRevisionWidths() {
        XCTAssertFalse(
            ASHProductionP06TrustRootV4.isConfiguredSourceRevision(
                String(repeating: "0", count: 40)
            )
        )
        XCTAssertFalse(
            ASHProductionP06TrustRootV4.isConfiguredSourceRevision(
                String(repeating: "0", count: 64)
            )
        )
        XCTAssertTrue(
            ASHProductionP06TrustRootV4.isConfiguredSourceRevision(
                String(repeating: "0", count: 63) + "1"
            )
        )
        XCTAssertFalse(
            ASHProductionP06TrustRootV4.isConfiguredSourceRevision(
                String(repeating: "A", count: 64)
            )
        )
    }

    func testExhaustiveCoreCertificateMatchesTheCurrentASHModel() {
        let certificate = ASHCoreCertificateV4.generate()

        XCTAssertTrue(certificate.isValid)
        XCTAssertEqual(certificate.stateCount, 512)
        XCTAssertEqual(certificate.integrityStateCount, 256)
        XCTAssertEqual(certificate.codewordCount, 16)
        XCTAssertEqual(certificate.minimumCodeDistance, 4)
        XCTAssertEqual(certificate.strictExactCount, 16)
        XCTAssertEqual(certificate.strictCorrectedCount, 144)
        XCTAssertEqual(certificate.strictUncorrectableCount, 352)
        XCTAssertTrue(certificate.strictDecodeMatchesRadiusOneContract)
        XCTAssertEqual(certificate.affineExactCount, 4_096)
        XCTAssertEqual(certificate.affineOneBitCorrectedCount, 36_864)
        XCTAssertEqual(certificate.affineTwoBitRejectedCount, 147_456)
        XCTAssertEqual(certificate.orbitCount, 32)
        XCTAssertEqual(certificate.integrityOrbitCount, 16)
    }

    func testCurrentModelCoordinatesCannotRegressToTheTransposedLegacyBaseline() {
        let currentFourthGenerator = ASHState(
            validatedRawValue: 0b100110001
        )
        let transposedLegacyGenerator = ASHState(
            validatedRawValue: 0b100110010
        )

        XCTAssertEqual(ASHCoreV4.canonicalGeneratorRows[3], currentFourthGenerator)
        XCTAssertTrue(ASHCoreV4.isCanonicalCodeword(currentFourthGenerator))
        XCTAssertTrue(currentFourthGenerator.hasValidIntegrity)
        XCTAssertEqual(
            currentFourthGenerator.bit(
                coordinate: ASHCoreV4.translationInvariantCoordinate
            ),
            0
        )

        XCTAssertEqual(
            ASHCoreV4.transposedLegacyFourthGenerator,
            transposedLegacyGenerator
        )
        XCTAssertFalse(ASHCoreV4.isCanonicalCodeword(transposedLegacyGenerator))
        // The legacy coordinate transposition still happens to lie in E; it
        // must be rejected because it is outside C and violates coordinate 8,
        // not because of an incorrectly weakened integrity check.
        XCTAssertTrue(transposedLegacyGenerator.hasValidIntegrity)
        XCTAssertNotEqual(
            transposedLegacyGenerator.bit(coordinate: 9),
            currentFourthGenerator.bit(coordinate: 9)
        )
        XCTAssertEqual(
            ASHCoreV4.decodeStrict(transposedLegacyGenerator).status,
            .uncorrectable
        )
        XCTAssertEqual(
            transposedLegacyGenerator.bit(
                coordinate: ASHCoreV4.translationInvariantCoordinate
            ),
            1
        )

        for codeword in ASHCoreV4.canonicalCodewordsByMessage {
            XCTAssertTrue(codeword.hasValidIntegrity)
            XCTAssertEqual(
                codeword.bit(
                    coordinate: ASHCoreV4.translationInvariantCoordinate
                ),
                0
            )
        }
    }

    func testStrictDecoderExhaustivelyMatchesRadiusOneSemantics() {
        var exactCount = 0
        var correctedCount = 0
        var uncorrectableCount = 0

        for rawState in 0..<ASHCoreV4.stateCount {
            let received = ASHState(validatedRawValue: UInt16(rawState))
            let result = ASHCoreV4.decodeStrict(received)
            let expected = bruteForceStrictDecode(received)

            XCTAssertEqual(result.status, expected.status, "state=\(received)")
            XCTAssertEqual(result.resolvedState, expected.codeword, "state=\(received)")
            XCTAssertEqual(result.message, expected.message, "state=\(received)")
            XCTAssertEqual(result.distance, expected.distance, "state=\(received)")
            XCTAssertEqual(result.nearestCount, expected.nearestCount, "state=\(received)")

            switch result.status {
            case .exact:
                exactCount += 1
            case .corrected:
                correctedCount += 1
            case .uncorrectable:
                uncorrectableCount += 1
            }
        }

        XCTAssertEqual(exactCount, 16)
        XCTAssertEqual(correctedCount, 144)
        XCTAssertEqual(uncorrectableCount, 352)
    }

    func testAffineDecoderExhaustivelyHonorsTheStrictRecoveryRadius() {
        var exactCount = 0
        var correctedCount = 0
        var rejectedCount = 0

        for rawAnchor in 0..<ASHCoreV4.stateCount {
            let anchor = ASHState(validatedRawValue: UInt16(rawAnchor))
            guard anchor.hasValidIntegrity else {
                continue
            }

            for rawMessage in 0..<ASHCoreV4.codewordCount {
                let message = ASHMessage(validatedRawValue: UInt8(rawMessage))
                let expected = ASHCoreV4.translate(anchor, by: message)
                let exact = ASHCoreV4.decodeAffine(
                    received: expected,
                    anchor: anchor
                )
                XCTAssertEqual(exact.status, .exact)
                XCTAssertEqual(exact.resolvedState, expected)
                XCTAssertEqual(exact.message, message)
                exactCount += 1

                for coordinate in 1...ASHState.bitCount {
                    let corrected = ASHCoreV4.decodeAffine(
                        received: expected.toggled(coordinate: coordinate),
                        anchor: anchor
                    )
                    XCTAssertEqual(corrected.status, .corrected)
                    XCTAssertEqual(corrected.resolvedState, expected)
                    XCTAssertEqual(corrected.message, message)
                    XCTAssertEqual(corrected.distance, 1)
                    XCTAssertEqual(corrected.nearestCount, 1)
                    correctedCount += 1
                }

                for firstCoordinate in 1..<ASHState.bitCount {
                    for secondCoordinate in (firstCoordinate + 1)...ASHState.bitCount {
                        let corrupted = expected
                            .toggled(coordinate: firstCoordinate)
                            .toggled(coordinate: secondCoordinate)
                        let rejected = ASHCoreV4.decodeAffine(
                            received: corrupted,
                            anchor: anchor
                        )
                        XCTAssertEqual(rejected.status, .uncorrectable)
                        XCTAssertNil(rejected.resolvedState)
                        XCTAssertNil(rejected.message)
                        rejectedCount += 1
                    }
                }
            }
        }

        XCTAssertEqual(exactCount, 4_096)
        XCTAssertEqual(correctedCount, 36_864)
        XCTAssertEqual(rejectedCount, 147_456)
    }

    func testCanonicalOrbitsPartitionTheStateSpaceAndProjectionIsIdempotent() {
        let allStates = (0..<ASHCoreV4.stateCount).map {
            ASHState(validatedRawValue: UInt16($0))
        }
        let representatives = Set(allStates.map(ASHCoreV4.orbitRepresentative))
        let integrityRepresentatives = Set(
            allStates
                .filter(\.hasValidIntegrity)
                .map(ASHCoreV4.orbitRepresentative)
        )

        XCTAssertEqual(representatives.count, 32)
        XCTAssertEqual(integrityRepresentatives.count, 16)

        var coveredStates = Set<ASHState>()
        for representative in representatives {
            let orbit = ASHCoreV4.orbit(of: representative)
            XCTAssertEqual(orbit.count, 16)
            XCTAssertEqual(Set(orbit).count, 16)
            for member in orbit {
                XCTAssertEqual(
                    ASHCoreV4.orbitRepresentative(of: member),
                    representative
                )
                XCTAssertEqual(ASHCoreV4.orbit(of: member), orbit)
                XCTAssertEqual(
                    member.bit(
                        coordinate: ASHCoreV4.translationInvariantCoordinate
                    ),
                    representative.bit(
                        coordinate: ASHCoreV4.translationInvariantCoordinate
                    )
                )
                coveredStates.insert(member)
            }
        }
        XCTAssertEqual(coveredStates.count, ASHCoreV4.stateCount)

        // T is represented with a common denominator of 16. Applying T twice
        // therefore yields a numerator exactly 16 times the first numerator.
        let sourceValues: [Int64] = allStates.map {
            let raw = Int64($0.rawValue)
            return raw * raw - 3 * raw + 7
        }
        let firstProjectionNumerators: [Int64] = allStates.map { state in
            ASHCoreV4.orbit(of: state).reduce(0) {
                $0 + sourceValues[Int($1.rawValue)]
            }
        }
        let secondProjectionNumerators: [Int64] = allStates.map { state in
            ASHCoreV4.orbit(of: state).reduce(0) {
                $0 + firstProjectionNumerators[Int($1.rawValue)]
            }
        }
        for index in allStates.indices {
            XCTAssertEqual(
                secondProjectionNumerators[index],
                firstProjectionNumerators[index] * Int64(ASHCoreV4.codewordCount)
            )
        }
    }

    func testCompleteTransitionTableMatchesIndependentFullStateXOR() {
        XCTAssertEqual(
            ASHCoreV4.transitionTableEntryCount,
            ASHCoreV4.stateCount * ASHCoreV4.codewordCount
        )

        for rawState in 0..<ASHCoreV4.stateCount {
            let state = ASHState(validatedRawValue: UInt16(rawState))
            for rawMessage in 0..<ASHCoreV4.codewordCount {
                let message = ASHMessage(validatedRawValue: UInt8(rawMessage))
                let expected = ASHState(
                    validatedRawValue: state.rawValue
                        ^ ASHCoreV4.canonicalCodewordsByMessage[rawMessage].rawValue
                )
                XCTAssertEqual(ASHCoreV4.translate(state, by: message), expected)
                XCTAssertEqual(
                    ASHCoreV4.translate(
                        state,
                        byCanonicalCodeword:
                            ASHCoreV4.canonicalCodewordsByMessage[rawMessage]
                    ),
                    expected
                )
            }
        }

        XCTAssertNil(
            ASHCoreV4.translate(
                ASHState(validatedRawValue: 0),
                byCanonicalCodeword: ASHCoreV4.transposedLegacyFourthGenerator
            )
        )
    }

    func testOrbitAverageRunsOnCanonicalCosetsAndFailsClosed() throws {
        let values: [Int64] = (0..<ASHCoreV4.stateCount).map(Int64.init)
        let projection = try ASHCoreV4.orbitAverageNumerators(values)
        XCTAssertEqual(projection.count, ASHCoreV4.stateCount)

        for rawState in 0..<ASHCoreV4.stateCount {
            let state = ASHState(validatedRawValue: UInt16(rawState))
            let independentNumerator = ASHCoreV4.orbit(of: state).reduce(Int64(0)) {
                $0 + values[Int($1.rawValue)]
            }
            XCTAssertEqual(projection[rawState], independentNumerator)
            for member in ASHCoreV4.orbit(of: state) {
                XCTAssertEqual(
                    projection[Int(member.rawValue)],
                    independentNumerator
                )
            }
        }

        XCTAssertThrowsError(
            try ASHCoreV4.orbitAverageNumerators([0])
        ) { error in
            XCTAssertEqual(
                error as? ASHCoreV4Error,
                .invalidOrbitFunctionCount(expected: 512, actual: 1)
            )
        }

        var overflowing = Array(repeating: Int64(0), count: ASHCoreV4.stateCount)
        for member in ASHCoreV4.orbit(of: ASHState(validatedRawValue: 0)) {
            overflowing[Int(member.rawValue)] = Int64.max
        }
        XCTAssertThrowsError(try ASHCoreV4.orbitAverageNumerators(overflowing)) {
            error in
            XCTAssertEqual(error as? ASHCoreV4Error, .orbitAverageOverflow)
        }
    }

    func testCanonicalBranchGrammarHasExactDepthFourMassCertificate() {
        let distribution = ASHCoreV4.branchDistribution(depth: 4)

        XCTAssertEqual(distribution.depth, 4)
        XCTAssertEqual(distribution.leafCount, 81)
        XCTAssertEqual(distribution.uniqueMessageCount, 16)
        XCTAssertEqual(distribution.massDenominator, 256)
        XCTAssertEqual(distribution.totalMassNumerator, 256)
        XCTAssertEqual(
            distribution.massNumeratorsByMessage,
            [
                34, 24, 24, 14,
                24, 18, 14, 8,
                24, 14, 18, 8,
                14, 8, 8, 2
            ]
        )

        for rawMessage in 0..<ASHCoreV4.codewordCount {
            let message = ASHMessage(validatedRawValue: UInt8(rawMessage))
            let codeword = ASHCoreV4.encode(message)
            XCTAssertEqual(
                codeword,
                ASHCoreV4.canonicalCodewordsByMessage[rawMessage]
            )
        }

        let zero = ASHMessage(validatedRawValue: 0)
        XCTAssertEqual(
            ASHCoreV4.branchMessage(from: zero, action: .continuation, level: 0),
            zero
        )
        XCTAssertEqual(
            ASHCoreV4.branchMessage(from: zero, action: .positive, level: 0),
            ASHMessage(validatedRawValue: 0b1000)
        )
        XCTAssertEqual(
            ASHCoreV4.branchMessage(from: zero, action: .negative, level: 0),
            ASHMessage(validatedRawValue: 0b0100)
        )
    }

    private func bruteForceStrictDecode(
        _ received: ASHState
    ) -> (
        status: ASHDecodeStatus,
        codeword: ASHState?,
        message: ASHMessage?,
        distance: Int,
        nearestCount: Int
    ) {
        var minimumDistance = ASHState.bitCount + 1
        var nearestIndices: [Int] = []

        for (index, codeword) in ASHCoreV4.canonicalCodewordsByMessage.enumerated() {
            let distance = received.hammingDistance(to: codeword)
            if distance < minimumDistance {
                minimumDistance = distance
                nearestIndices = [index]
            } else if distance == minimumDistance {
                nearestIndices.append(index)
            }
        }

        guard minimumDistance <= 1, nearestIndices.count == 1 else {
            return (
                .uncorrectable,
                nil,
                nil,
                minimumDistance,
                nearestIndices.count
            )
        }

        let index = nearestIndices[0]
        return (
            minimumDistance == 0 ? .exact : .corrected,
            ASHCoreV4.canonicalCodewordsByMessage[index],
            ASHMessage(validatedRawValue: UInt8(index)),
            minimumDistance,
            1
        )
    }
}
