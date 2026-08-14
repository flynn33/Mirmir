import XCTest
@testable import Mirmir

final class ASHMeasurementContractV4Tests: XCTestCase {
    func testCanonicalContractFreezesEveryMeasurementAndExtractionPolicy() {
        let contract = ASHMeasurementContractV4.canonicalP06

        XCTAssertEqual(contract.schemaVersion, 1)
        XCTAssertEqual(contract.contractID, "ash.p06.measurement.q16.v1")
        XCTAssertEqual(contract.fractionalBits, 16)
        XCTAssertEqual(contract.roundingRule, .nearestTiesToEven)
        XCTAssertEqual(
            contract.rules.map { $0.coordinate.stableName },
            [
                "mean_luminance",
                "rms_contrast",
                "edge_energy",
                "texture_energy",
                "chroma_energy",
                "horizontal_gradient_energy",
                "vertical_gradient_energy",
                "temporal_change"
            ]
        )
        XCTAssertEqual(
            contract.rules.map { $0.threshold.rawValue },
            [32_768, 13_107, 7_864, 5_243, 6_554, 6_554, 6_554, 5_243]
        )
        XCTAssertEqual(
            contract.rules.map { $0.hysteresis.rawValue },
            [1_311, 1_311, 983, 983, 983, 983, 983, 1_311]
        )
        XCTAssertEqual(contract.window.width, 32)
        XCTAssertEqual(contract.window.height, 32)
        XCTAssertEqual(contract.window.horizontalStride, 1)
        XCTAssertEqual(contract.window.verticalStride, 1)
        XCTAssertEqual(contract.window.anchor, .sourceTileOrigin)
        XCTAssertEqual(
            contract.window.aggregation,
            .arithmeticMeanOverEverySample
        )
        XCTAssertEqual(contract.borderPolicy.spatialExtension, .clampToEdge)
        XCTAssertEqual(
            contract.borderPolicy.forwardDifferenceBoundary,
            .zeroAtPositiveExtent
        )
        XCTAssertEqual(
            contract.borderPolicy.temporalWindowMismatch,
            .resetRequired
        )
        XCTAssertEqual(contract.borderPolicy.boxBlurRadius, 1)
        XCTAssertEqual(
            contract.colorDomain.colorSpace,
            .normalizedEncodedRGBBT709Reference
        )
        XCTAssertEqual(
            [
                contract.colorDomain.redLumaCoefficient.rawValue,
                contract.colorDomain.greenLumaCoefficient.rawValue,
                contract.colorDomain.blueLumaCoefficient.rawValue
            ],
            [13_933, 46_871, 4_732]
        )
        XCTAssertEqual(contract.resetPolicy.rules.count, 10)
        XCTAssertEqual(
            contract.resetPolicy.rule(for: .sceneCut)?.temporalEvidence,
            .preserveCurrentEvidence
        )
        XCTAssertEqual(
            contract.resetPolicy.rule(for: .streamStart)?.temporalEvidence,
            .mustBeZero
        )
        XCTAssertNoThrow(try contract.validateCanonical())
    }

    func testQ16RationalQuantizationUsesTiesToEvenAndRejectsInvalidValues() throws {
        XCTAssertEqual(
            try ASHNormalizedQ16V4(numerator: 1, denominator: 2).rawValue,
            32_768
        )
        XCTAssertEqual(
            try ASHNormalizedQ16V4(numerator: 1, denominator: 5).rawValue,
            13_107
        )
        XCTAssertEqual(
            try ASHNormalizedQ16V4(numerator: 1, denominator: 131_072)
                .rawValue,
            0,
            "0.5 LSB ties to even zero"
        )
        XCTAssertEqual(
            try ASHNormalizedQ16V4(numerator: 3, denominator: 131_072)
                .rawValue,
            2,
            "1.5 LSB ties to even two"
        )
        XCTAssertThrowsError(
            try ASHNormalizedQ16V4(rawValue: ASHNormalizedQ16V4.scale + 1)
        )
        XCTAssertThrowsError(
            try ASHNormalizedQ16V4(numerator: 2, denominator: 1)
        )
        XCTAssertThrowsError(
            try ASHNormalizedQ16V4(numerator: 0, denominator: 0)
        )

        let encoded = try JSONEncoder().encode(ASHNormalizedQ16V4.one)
        XCTAssertEqual(
            try JSONDecoder().decode(ASHNormalizedQ16V4.self, from: encoded),
            .one
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                ASHNormalizedQ16V4.self,
                from: Data("65537".utf8)
            )
        )
    }

    func testInitialThresholdTiesMapToOneAndIntegrityIsDerived() throws {
        let contract = ASHMeasurementContractV4.canonicalP06
        let evidence = makeEvidence(
            contract: contract,
            rawValues: contract.rules.map { $0.threshold.rawValue }
        )
        let projection = try contract.project(
            evidence,
            history: .reset(.sceneCut)
        )

        XCTAssertEqual(projection.payloadBitsByCoordinate, Array(repeating: 1, count: 8))
        XCTAssertEqual(projection.integrityBit, 0)
        XCTAssertTrue(projection.state.hasValidIntegrity)
        XCTAssertEqual(projection.state.bits, Array(repeating: 1, count: 8) + [0])
        for coordinate in ASHMeasurementCoordinateV4.allCases {
            XCTAssertEqual(projection.bit(for: coordinate), 1)
        }
    }

    func testHysteresisBoundariesAreExactForEveryCoordinate() throws {
        let contract = ASHMeasurementContractV4.canonicalP06
        let zeroState = try ASHState(payloadBits: Array(repeating: 0, count: 8))
        let oneState = try ASHState(payloadBits: Array(repeating: 1, count: 8))

        for (index, rule) in contract.rules.enumerated() {
            var belowOn = Array(repeating: UInt32(0), count: 8)
            belowOn[index] = rule.threshold.rawValue
                + rule.hysteresis.rawValue - 1
            let heldZero = try contract.project(
                makeEvidence(contract: contract, rawValues: belowOn),
                history: .continuous(previousState: zeroState)
            )
            XCTAssertEqual(heldZero.payloadBitsByCoordinate[index], 0)

            belowOn[index] += 1
            let switchedOn = try contract.project(
                makeEvidence(contract: contract, rawValues: belowOn),
                history: .continuous(previousState: zeroState)
            )
            XCTAssertEqual(switchedOn.payloadBitsByCoordinate[index], 1)

            var atOffBoundary = contract.rules.map {
                $0.threshold.rawValue - $0.hysteresis.rawValue
            }
            let heldOne = try contract.project(
                makeEvidence(contract: contract, rawValues: atOffBoundary),
                history: .continuous(previousState: oneState)
            )
            XCTAssertEqual(heldOne.payloadBitsByCoordinate[index], 1)

            atOffBoundary[index] -= 1
            let switchedOff = try contract.project(
                makeEvidence(contract: contract, rawValues: atOffBoundary),
                history: .continuous(previousState: oneState)
            )
            XCTAssertEqual(switchedOff.payloadBitsByCoordinate[index], 0)
        }
    }

    func testAll256PayloadsProjectExactlyAndRecomputeIntegrity() throws {
        let contract = ASHMeasurementContractV4.canonicalP06
        for rawPayload in 0..<256 {
            let bits = (0..<8).map { index in
                (rawPayload >> (7 - index)) & 1
            }
            let values = zip(bits, contract.rules).map { bit, rule in
                bit == 1
                    ? rule.threshold.rawValue
                    : rule.threshold.rawValue - 1
            }
            let projection = try contract.project(
                makeEvidence(contract: contract, rawValues: values),
                history: .reset(.sceneCut)
            )
            XCTAssertEqual(projection.payloadBitsByCoordinate, bits.map(UInt8.init))
            XCTAssertEqual(
                projection.integrityBit,
                bits.reduce(UInt8(0)) { $0 ^ UInt8($1) }
            )
            XCTAssertEqual(
                projection.state,
                try ASHState(payloadBits: bits)
            )
        }
    }

    func testResetAndEvidenceProvenanceContradictionsFailClosed() throws {
        let contract = ASHMeasurementContractV4.canonicalP06
        var values = Array(repeating: UInt32(0), count: 8)
        values[7] = 1
        XCTAssertThrowsError(
            try contract.project(
                makeEvidence(contract: contract, rawValues: values),
                history: .reset(.streamStart)
            )
        ) { error in
            XCTAssertEqual(
                error as? ASHMeasurementContractV4Error,
                .temporalEvidenceMustBeZero(.streamStart)
            )
        }

        let sceneCut = try contract.project(
            makeEvidence(contract: contract, rawValues: values),
            history: .reset(.sceneCut)
        )
        XCTAssertEqual(sceneCut.bit(for: .temporalChange), 0)

        let invalidPrior = try ASHState(rawValue: 1)
        XCTAssertFalse(invalidPrior.hasValidIntegrity)
        XCTAssertThrowsError(
            try contract.project(
                makeEvidence(
                    contract: contract,
                    rawValues: Array(repeating: 0, count: 8)
                ),
                history: .continuous(previousState: invalidPrior)
            )
        )

        let wrongProvenance = ASHMeasurementEvidenceProvenanceV4(
            contractID: contract.contractID,
            schemaVersion: contract.schemaVersion,
            windowPolicyID: contract.window.policyID + ".wrong",
            borderPolicyID: contract.borderPolicy.policyID,
            colorDomainPolicyID: contract.colorDomain.policyID
        )
        let mismatched = makeEvidence(
            provenance: wrongProvenance,
            rawValues: Array(repeating: 0, count: 8)
        )
        XCTAssertThrowsError(
            try contract.project(mismatched, history: .reset(.streamStart))
        ) { error in
            XCTAssertEqual(
                error as? ASHMeasurementContractV4Error,
                .evidenceProvenanceMismatch
            )
        }
    }

    func testCanonicalBinaryRoundTripRejectsEveryTruncationAndMutation() throws {
        let contract = ASHMeasurementContractV4.canonicalP06
        let data = try contract.serializedCanonical()
        XCTAssertEqual(
            try ASHMeasurementContractV4.decodeCanonical(from: data),
            contract
        )
        XCTAssertEqual(try contract.serializedCanonical(), data)

        for count in 0..<data.count {
            XCTAssertThrowsError(
                try ASHMeasurementContractV4.decodeCanonical(
                    from: Data(data.prefix(count))
                ),
                "accepted prefix length \(count)"
            )
        }
        var trailing = data
        trailing.append(0)
        XCTAssertThrowsError(
            try ASHMeasurementContractV4.decodeCanonical(from: trailing)
        )
        var corrupted = data
        corrupted[corrupted.startIndex] ^= 0xff
        XCTAssertThrowsError(
            try ASHMeasurementContractV4.decodeCanonical(from: corrupted)
        )

        var changedRules = contract.rules
        let first = changedRules[0]
        changedRules[0] = try ASHMeasurementRuleV4(
            coordinate: first.coordinate,
            threshold: ASHNormalizedQ16V4(
                rawValue: first.threshold.rawValue + 1
            ),
            hysteresis: first.hysteresis
        )
        let nonCanonical = try ASHMeasurementContractV4(
            schemaVersion: contract.schemaVersion,
            contractID: contract.contractID,
            fractionalBits: contract.fractionalBits,
            roundingRule: contract.roundingRule,
            rules: changedRules,
            window: contract.window,
            borderPolicy: contract.borderPolicy,
            colorDomain: contract.colorDomain,
            resetPolicy: contract.resetPolicy
        )
        XCTAssertThrowsError(try nonCanonical.serializedCanonical())
        XCTAssertThrowsError(
            try nonCanonical.project(
                makeEvidence(
                    contract: nonCanonical,
                    rawValues: Array(repeating: 0, count: 8)
                ),
                history: .reset(.streamStart)
            )
        )
    }

    private func makeEvidence(
        contract: ASHMeasurementContractV4,
        rawValues: [UInt32]
    ) -> ASHMeasurementEvidenceV4 {
        makeEvidence(
            provenance: contract.evidenceProvenance,
            rawValues: rawValues
        )
    }

    private func makeEvidence(
        provenance: ASHMeasurementEvidenceProvenanceV4,
        rawValues: [UInt32]
    ) -> ASHMeasurementEvidenceV4 {
        precondition(rawValues.count == 8)
        let values = rawValues.map { try! ASHNormalizedQ16V4(rawValue: $0) }
        return ASHMeasurementEvidenceV4(
            provenance: provenance,
            meanLuminance: values[0],
            rmsContrast: values[1],
            edgeEnergy: values[2],
            textureEnergy: values[3],
            chromaEnergy: values[4],
            horizontalGradientEnergy: values[5],
            verticalGradientEnergy: values[6],
            temporalChange: values[7]
        )
    }
}
