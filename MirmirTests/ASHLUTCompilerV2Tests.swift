import XCTest
@testable import Mirmir

final class ASHLUTCompilerV2Tests: XCTestCase {
    func testCanonicalPathsAndValidStateOrdinalsAreExact() throws {
        let paths = try ASHLUTLeafCompilerV2.canonicalPaths()
        XCTAssertEqual(paths.count, 81)
        XCTAssertEqual(paths.map(\.ordinal), (0..<81).map(UInt8.init))
        XCTAssertEqual(paths.reduce(0) { $0 + Int($1.branchMassNumerator) }, 256)
        XCTAssertEqual(Set(paths.map(\.actions)).count, 81)

        for (ordinal, path) in paths.enumerated() {
            var remainder = ordinal
            var expectedActions: [ASHLUTCanonicalActionV2] = []
            for divisor in [27, 9, 3, 1] {
                let digit = remainder / divisor
                remainder %= divisor
                expectedActions.append(try XCTUnwrap(ASHLUTCanonicalActionV2(rawValue: UInt8(digit))))
            }
            XCTAssertEqual(path.actions, expectedActions)
            XCTAssertEqual(
                path.semanticDelta,
                ASHLUTSemanticDeltaV2(
                    orientation: expectedActions[0].semanticStep,
                    support: expectedActions[1].semanticStep,
                    detail: expectedActions[2].semanticStep,
                    regularization: expectedActions[3].semanticStep
                )
            )
            var expectedMessage = ASHMessage(validatedRawValue: 0)
            var expectedMass: UInt16 = 1
            for (level, action) in expectedActions.enumerated() {
                expectedMass *= action.massNumeratorOverFour
                switch action {
                case .zero:
                    break
                case .plus:
                    expectedMessage = try expectedMessage.toggled(bitIndex: level)
                case .minus:
                    expectedMessage = try expectedMessage.toggled(
                        bitIndex: (level + 1) % ASHMessage.bitCount
                    )
                }
            }
            XCTAssertEqual(path.message, expectedMessage)
            XCTAssertEqual(path.branchMassNumerator, expectedMass)
        }

        XCTAssertEqual(ASHLUTStateOrdinalTableV2.validStates.count, 256)
        XCTAssertEqual(ASHLUTStateOrdinalTableV2.rawToOrdinal.count, 512)
        var nextOrdinal: UInt16 = 0
        for raw in UInt16(0)..<UInt16(512) {
            let state = ASHState(validatedRawValue: raw)
            if state.hasValidIntegrity {
                XCTAssertEqual(ASHLUTStateOrdinalTableV2.ordinal(for: state), nextOrdinal)
                XCTAssertEqual(ASHLUTStateOrdinalTableV2.validStates[Int(nextOrdinal)], state)
                nextOrdinal += 1
            } else {
                XCTAssertNil(ASHLUTStateOrdinalTableV2.ordinal(for: state))
            }
        }
        XCTAssertEqual(nextOrdinal, 256)
    }

    func testBothRoutesExhaustivelyHonorCompilerAndRuntimeInvariants() throws {
        let direct2x = try ASHLUTTestSupportV2.mixedDirect2x()
        let direct3Over2 = try ASHLUTTestSupportV2.mixedDirect3Over2()
        var descriptorIDs = Set<UInt8>()
        var observedGainAndAlpha = false
        var observedSecondary = false
        var observedOrdinaryPruning = false

        for fixture in [direct2x, direct3Over2] {
            let observations = try assertCompilation(
                fixture.compilation,
                configuration: fixture.configuration
            )
            descriptorIDs.formUnion(observations.descriptorIDs)
            observedGainAndAlpha = observedGainAndAlpha || observations.gainAndAlpha
            observedSecondary = observedSecondary || observations.secondary
            observedOrdinaryPruning = observedOrdinaryPruning || observations.ordinaryPruning
        }

        XCTAssertEqual(direct2x.compilation.entries.count, 4_096)
        XCTAssertEqual(direct3Over2.compilation.entries.count, 9_216)
        XCTAssertFalse(direct2x.compilation.entries.contains(where: \.sourceAlignedExact))
        XCTAssertFalse(direct3Over2.compilation.entries.contains(where: \.sourceAlignedExact))
        XCTAssertEqual(descriptorIDs, Set(UInt8(0)..<UInt8(16)))
        XCTAssertTrue(observedGainAndAlpha)
        XCTAssertTrue(observedSecondary)
        XCTAssertTrue(observedOrdinaryPruning)
    }

    func testCompilationAndSerializationAreDeterministic() throws {
        let fixture = try ASHLUTTestSupportV2.mixedDirect2x()
        let repeated = try ASHLUTLeafCompilerV2.compile(
            route: .direct2x,
            configuration: fixture.configuration
        )
        let repeatedArtifact = try ASHLUTBinaryCodecV2.serialize(repeated)

        XCTAssertEqual(repeated, fixture.compilation)
        XCTAssertEqual(repeatedArtifact.data, fixture.artifact.data)
        XCTAssertEqual(repeatedArtifact.payloadSHA256, fixture.artifact.payloadSHA256)
        XCTAssertEqual(repeatedArtifact.wholeFileSHA256, fixture.artifact.wholeFileSHA256)
    }

    func testSourceAlignedExactRequiresBothPlanePoliciesForBothRoutes() throws {
        let policies = ASHSpatialCoordinatePolicyV2.allCases
        for route in ASHSpatialRouteV2.allCases {
            for lumaPolicy in policies {
                for chromaPolicy in policies {
                    let configuration = try ASHLUTTestSupportV2.configuration(
                        lumaPolicy: lumaPolicy,
                        chromaPolicy: chromaPolicy
                    )
                    let compilation = try ASHLUTLeafCompilerV2.compile(
                        route: route,
                        configuration: configuration
                    )
                    let expectedCount = lumaPolicy == .sourceAlignedRational
                        && chromaPolicy == .sourceAlignedRational
                        ? 4 * 256
                        : 0
                    XCTAssertEqual(
                        compilation.entries.filter(\.sourceAlignedExact).count,
                        expectedCount,
                        "\(route.rawValue) \(lumaPolicy.rawValue)/\(chromaPolicy.rawValue)"
                    )
                }
            }
        }
    }

    func testLockedConfigurationRejectsNonCanonicalInputs() throws {
        XCTAssertThrowsError(try ASHLUTHashV2(hex: String(repeating: "0", count: 64))) {
            XCTAssertEqual($0 as? ASHLUTCompilerErrorV2, .invalidHash)
        }
        XCTAssertThrowsError(try ASHLUTHashV2(hex: String(repeating: "AB", count: 32))) {
            XCTAssertEqual($0 as? ASHLUTCompilerErrorV2, .invalidHash)
        }
        var table = ASHLUTTestSupportV2.exactPenaltyTable(denominator: 64)
        table[127] &-= 1
        XCTAssertThrowsError(try ASHLUTTestSupportV2.compilerPolicy(penaltyTable: table)) {
            XCTAssertEqual($0 as? ASHLUTCompilerErrorV2, .invalidPenaltyTable)
        }
        XCTAssertThrowsError(try ASHLUTLockedRouteSelectionV2(
            lumaCoordinatePolicy: .halfPixelCenter,
            chromaCoordinatePolicy: .halfPixelCenter,
            analysisGridSourceStep: 3
        )) {
            XCTAssertEqual($0 as? ASHLUTCompilerErrorV2, .invalidLockedConfiguration)
        }

        let valid = try ASHLUTTestSupportV2.configuration(policy: .halfPixelCenter)
        XCTAssertThrowsError(try ASHLUTLockedConfigurationV2(
            configurationID: "Invalid-ID",
            mappingSHA256: valid.mappingSHA256,
            operatorBankSHA256: valid.operatorBankSHA256,
            metricPolicySHA256: valid.metricPolicySHA256,
            compilerInputsSHA256: valid.compilerInputsSHA256,
            calibrationPlanSHA256: valid.calibrationPlanSHA256,
            corpusLockBundleSHA256: valid.corpusLockBundleSHA256,
            boundaryMode: valid.boundaryMode,
            operatorParameters: valid.operatorParameters,
            semanticSteps: valid.semanticSteps,
            compilerPolicy: valid.compilerPolicy,
            routes: valid.routes
        )) {
            XCTAssertEqual($0 as? ASHLUTCompilerErrorV2, .invalidLockedConfiguration)
        }
    }

}
