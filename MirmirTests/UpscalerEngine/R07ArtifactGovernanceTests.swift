import XCTest
@testable import Mirmir

// swiftlint:disable file_length

final class R07ArtifactGovernanceTests: XCTestCase {
    func testArtifactDeclarationMatchesFrozenOrderThresholdsAndUnits() {
        XCTAssertEqual(
            R07ArtifactKind.allCases.map(\.rawValue),
            [
                "ringing",
                "halo",
                "ghosting",
                "flicker",
                "false_texture",
                "chroma_displacement"
            ]
        )
        XCTAssertEqual(
            R07ArtifactKind.allCases.map(\.threshold),
            [3_277, 3_277, 4_096, 4_096, 4_096, 64]
        )
        XCTAssertEqual(
            R07ArtifactKind.allCases.map(\.unit.rawValue),
            ["q16", "q16", "q16", "q16", "q16", "q8_pixels"]
        )
    }

    func testRingingStepFixtureUsesSignedCandidateAndSuppliedBounds() throws {
        let result = try R07ArtifactGovernance.ringing(
            candidateQ16: [-4_096, 0, 65_536, 69_632],
            lowerBoundsQ16: [0, 0, 0, 0],
            upperBoundsQ16: [65_536, 65_536, 65_536, 65_536]
        )
        assertMeasurement(result, kind: .ringing, raw: 4_096, risk: 65_536, detected: true)
        XCTAssertNil(result.contributingSampleCount)
    }

    func testRingingRejectsEveryFrozenDomainAndBoundRelationViolation() {
        XCTAssertThrowsError(
            try R07ArtifactGovernance.ringing(
                candidateQ16: [-65_537],
                lowerBoundsQ16: [0],
                upperBoundsQ16: [65_536]
            )
        ) { error in
            XCTAssertEqual(
                error as? R07ArtifactGovernanceError,
                .sampleOutOfDomain(
                    role: "candidate",
                    index: 0,
                    value: -65_537,
                    minimum: -65_536,
                    maximum: 131_072
                )
            )
        }
        XCTAssertThrowsError(
            try R07ArtifactGovernance.ringing(
                candidateQ16: [0],
                lowerBoundsQ16: [1],
                upperBoundsQ16: [0]
            )
        ) { error in
            XCTAssertEqual(
                error as? R07ArtifactGovernanceError,
                .invalidRingingBounds(index: 0, lower: 1, upper: 0)
            )
        }
        XCTAssertThrowsError(
            try R07ArtifactGovernance.ringing(
                candidateQ16: [0],
                lowerBoundsQ16: [0],
                upperBoundsQ16: [65_537]
            )
        )
    }

    func testHaloImpulseThinLineAndZeroSupportFixturesAreExact() throws {
        let impulse = try R07ArtifactGovernance.halo(
            candidateQ16: [0, 4_096, 0, 0],
            referenceQ16: [0, 0, 0, 0],
            support: [false, true, false, false]
        )
        assertMeasurement(impulse, kind: .halo, raw: 4_096, risk: 65_536, detected: true)
        XCTAssertEqual(impulse.contributingSampleCount, 1)

        let thinLine = try R07ArtifactGovernance.halo(
            candidateQ16: [0, 65_536, 0],
            referenceQ16: [0, 65_536, 0],
            support: [true, true, true]
        )
        assertMeasurement(thinLine, kind: .halo, raw: 0, risk: 0, detected: false)

        XCTAssertThrowsError(
            try R07ArtifactGovernance.halo(
                candidateQ16: [0, 0],
                referenceQ16: [0, 0],
                support: [false, false]
            )
        ) { error in
            XCTAssertEqual(error as? R07ArtifactGovernanceError, .zeroSupportRejected)
        }
    }

    func testFalseTextureCheckerAndInsufficientSampleFixturesAreExact() throws {
        let checker = try R07ArtifactGovernance.falseTexture(
            candidateQ16: [0, 8_192, 0, 8_192],
            sourceQ16: [0, 0, 0, 0]
        )
        assertMeasurement(
            checker,
            kind: .falseTexture,
            raw: 8_192,
            risk: 65_536,
            detected: true
        )
        XCTAssertThrowsError(
            try R07ArtifactGovernance.falseTexture(candidateQ16: [0], sourceQ16: [0])
        ) { error in
            XCTAssertEqual(
                error as? R07ArtifactGovernanceError,
                .insufficientSamplesRejected(
                    role: "candidate_and_source",
                    actual: 1,
                    minimum: 2
                )
            )
        }
    }

    func testChromaEdgeFixtureUsesQ8Displacement() throws {
        let result = try R07ArtifactGovernance.chromaDisplacement(
            lumaEdgePositionQ8: 256,
            chromaEdgePositionQ8: 321
        )
        assertMeasurement(
            result,
            kind: .chromaDisplacement,
            raw: 65,
            risk: 65_536,
            detected: true
        )
    }

    func testABABFlickerFixtureComputesMeanSecondDifference() throws {
        let result = try R07ArtifactGovernance.flicker(
            currentQ16: [0, 8_192],
            previousQ16: [8_192, 0],
            beforePreviousQ16: [0, 8_192]
        )
        assertMeasurement(result, kind: .flicker, raw: 8_192, risk: 65_536, detected: true)
    }

    func testTrailingGhostAndAllOccludedFixturesAreExact() throws {
        let result = try R07ArtifactGovernance.ghosting(
            currentQ16: [8_192, 0, 8_192, 0],
            alignedPreviousQ16: [0, 0, 0, 0],
            occlusionMask: [false, true, false, true]
        )
        assertMeasurement(result, kind: .ghosting, raw: 8_192, risk: 65_536, detected: true)
        XCTAssertEqual(result.contributingSampleCount, 2)
        XCTAssertThrowsError(
            try R07ArtifactGovernance.ghosting(
                currentQ16: [0, 0],
                alignedPreviousQ16: [0, 0],
                occlusionMask: [true, true]
            )
        ) { error in
            XCTAssertEqual(
                error as? R07ArtifactGovernanceError,
                .noValidGhostingSamplesRejected
            )
        }
    }

    func testArtifactThresholdEqualityNormalizesToOneButDoesNotDetect() throws {
        let measurements = try zip(
            R07ArtifactKind.allCases,
            [3_277, 3_277, 4_096, 4_096, 4_096, 64]
        ).map { kind, rawValue in
            try R07ArtifactGovernance.measurement(kind: kind, rawValue: rawValue)
        }
        XCTAssertEqual(measurements.map(\.normalizedRiskQ16.rawValue), [Int64](repeating: 65_536, count: 6))
        XCTAssertEqual(measurements.map(\.detected), [Bool](repeating: false, count: 6))
    }

    func testArtifactAggregateRequiresExactUniqueOrderAndUsesMaximum() throws {
        let rawValues: [Int64] = [0, 0, 0, 0, 0, 32]
        let measurements = try zip(R07ArtifactKind.allCases, rawValues).map {
            try R07ArtifactGovernance.measurement(kind: $0.0, rawValue: $0.1)
        }
        let aggregate = try R07ArtifactGovernance.aggregate(measurements)
        XCTAssertEqual(
            aggregate.orderedMeasurements.map(\.normalizedRiskQ16.rawValue),
            [0, 0, 0, 0, 0, 32_768]
        )
        XCTAssertEqual(aggregate.maximumNormalizedRiskQ16.rawValue, 32_768)

        let wrongOrder = Array(measurements.reversed())
        XCTAssertThrowsError(try R07ArtifactGovernance.aggregate(wrongOrder)) { error in
            XCTAssertEqual(
                error as? R07ArtifactGovernanceError,
                .incompleteArtifactOrder(
                    expected: R07ArtifactKind.allCases,
                    actual: wrongOrder.map(\.kind)
                )
            )
        }
    }

    func testVectorBoundaryAccepts4096AndRejects4097WithoutClamping() throws {
        XCTAssertNoThrow(
            try R07ArtifactGovernance.validateDeclaredSampleCount(4_096, role: "candidate")
        )
        XCTAssertThrowsError(
            try R07ArtifactGovernance.validateDeclaredSampleCount(4_097, role: "candidate")
        ) { error in
            XCTAssertEqual(
                error as? R07ArtifactGovernanceError,
                .vectorAboveMaximum(role: "candidate", actual: 4_097, maximum: 4_096)
            )
        }
        XCTAssertThrowsError(
            try R07ArtifactGovernance.validateDeclaredSampleCount(0, role: "candidate")
        ) { error in
            XCTAssertEqual(
                error as? R07ArtifactGovernanceError,
                .emptyVector(role: "candidate")
            )
        }
    }

    func testNormalLumaDomainsAndEqualLengthVectorsFailClosed() {
        XCTAssertThrowsError(
            try R07ArtifactGovernance.halo(
                candidateQ16: [-1],
                referenceQ16: [0],
                support: [true]
            )
        )
        XCTAssertThrowsError(
            try R07ArtifactGovernance.halo(
                candidateQ16: [0, 0],
                referenceQ16: [0],
                support: [true, true]
            )
        ) { error in
            XCTAssertEqual(
                error as? R07ArtifactGovernanceError,
                .sampleCountMismatch(role: "reference_or_previous", expected: 2, actual: 1)
            )
        }
    }

    func testCheckedArithmeticAndInt64MinimumFailClosed() {
        XCTAssertThrowsError(
            try R07ArtifactGovernance.measurement(
                kind: .chromaDisplacement,
                rawValue: .max
            )
        ) { error in
            XCTAssertEqual(
                error as? R07ArtifactGovernanceError,
                .arithmeticOverflow(operation: "chroma_displacement_normalize_multiply")
            )
        }
        XCTAssertThrowsError(
            try R07ArtifactGovernance.chromaDisplacement(
                lumaEdgePositionQ8: .min,
                chromaEdgePositionQ8: 0
            )
        )
    }
}

extension R07ArtifactGovernanceTests {
    func testComparatorMetadataAndBlockedProductMatrixAreExact() {
        XCTAssertEqual(
            R07ComparatorDimension.allCases.map(\.rawValue),
            [
                "temporal_artifact",
                "chroma_displacement",
                "spatial_ms_ssim",
                "protected_integrity"
            ]
        )
        XCTAssertEqual(
            R07ComparatorDimension.allCases.map(\.equation),
            [
                "baseline_temporal_risk_q16-auto_temporal_risk_q16",
                "baseline_chroma_displacement_q8_pixels-auto_chroma_displacement_q8_pixels",
                "auto_ms_ssim_ppm-baseline_ms_ssim_ppm",
                "auto_weighted_mae_q16-baseline_weighted_mae_q16"
            ]
        )
        XCTAssertEqual(
            R07ComparatorDimension.allCases.map(\.metric),
            [
                "maximum_normalized_risk_q16_over_ringing_halo_ghosting_flicker_false_texture",
                "raw_chroma_displacement_q8_pixels",
                "delta_ppm",
                "weighted_mae_q16"
            ]
        )
        XCTAssertEqual(
            R07ComparatorDimension.allCases.map(\.unit.rawValue),
            ["q16", "q8_pixels", "ppm", "q16"]
        )
        XCTAssertEqual(
            R07ComparatorDimension.allCases.map(\.passThreshold),
            [1, 1, -5_000, 0]
        )

        for dimension in R07ComparatorDimension.allCases {
            let blocked = R07BlockedProductComparison(dimension: dimension)
            XCTAssertEqual(blocked.usedBackendIDs, [])
            XCTAssertEqual(blocked.status, .notObserved)
            XCTAssertEqual(blocked.reason, "upstream_no_product_qualified_primary_backend")
            XCTAssertFalse(blocked.nonvacuousRequirementSatisfied)
            XCTAssertFalse(blocked.fixtureComparisonExecuted)
            XCTAssertEqual(blocked.productComparisonExecution, .notObserved)
            XCTAssertEqual(blocked.productQualification, .notClaimed)
            XCTAssertEqual(blocked.claim, .forbidden)
        }
    }

    func testSyntheticComparatorEqualityAndOneUnitFailureMatrixIsExact() throws {
        let fixtures = [
            ComparatorFixture(.temporalArtifact, 1_001, 1_000, 1, true),
            ComparatorFixture(.temporalArtifact, 1_000, 1_000, 0, false),
            ComparatorFixture(.chromaDisplacement, 101, 100, 1, true),
            ComparatorFixture(.chromaDisplacement, 100, 100, 0, false),
            ComparatorFixture(.spatialMSSSIM, 900_000, 895_000, -5_000, true),
            ComparatorFixture(.spatialMSSSIM, 900_000, 894_999, -5_001, false),
            ComparatorFixture(.protectedIntegrity, 100, 100, 0, true),
            ComparatorFixture(.protectedIntegrity, 100, 101, 1, false)
        ]
        for (index, fixture) in fixtures.enumerated() {
            let backendID = "fixture.synthetic.r07.\(fixture.dimension.rawValue).\(index)"
            let result = try evaluate(
                fixture.dimension,
                backendID: backendID,
                baseline: fixture.baseline,
                auto: fixture.auto
            )
            XCTAssertEqual(result.computedDelta, fixture.expectedDelta)
            XCTAssertEqual(result.passed, fixture.expectedPassed)
            XCTAssertEqual(result.backendScope, .syntheticFixtureOnly)
            XCTAssertTrue(result.nonvacuousRequirementSatisfied)
            XCTAssertTrue(result.fixtureComparisonExecuted)
            XCTAssertEqual(result.productComparisonExecution, .notObserved)
            XCTAssertEqual(result.productQualification, .notClaimed)
            XCTAssertEqual(result.claim, .forbidden)
        }
    }

    func testSyntheticComparatorPreservesDeclaredBackendOrder() throws {
        let identifiers = ["fixture.backend.a", "fixture.backend.b"]
        let records = [
            makeRecord(.temporalArtifact, backendID: identifiers[1], baseline: 12, auto: 10),
            makeRecord(.temporalArtifact, backendID: identifiers[0], baseline: 11, auto: 10)
        ]
        let results = try R07SyntheticComparator.evaluate(
            dimension: .temporalArtifact,
            fixtureBackendIDs: identifiers,
            records: records
        )
        XCTAssertEqual(results.map(\.fixtureBackendID), identifiers)
        XCTAssertEqual(results.map(\.computedDelta), [1, 2])
    }

    func testSyntheticComparatorRejectsVacuityIdentityAndCompletenessFailures() {
        XCTAssertThrowsError(
            try R07SyntheticComparator.evaluate(
                dimension: .temporalArtifact,
                fixtureBackendIDs: [],
                records: []
            )
        ) { error in
            XCTAssertEqual(error as? R07ArtifactGovernanceError, .emptyComparatorBackendSet)
        }
        XCTAssertThrowsError(
            try R07SyntheticComparator.evaluate(
                dimension: .temporalArtifact,
                fixtureBackendIDs: [""],
                records: []
            )
        ) { error in
            XCTAssertEqual(
                error as? R07ArtifactGovernanceError,
                .emptyComparatorBackendID(index: 0)
            )
        }
        XCTAssertThrowsError(
            try R07SyntheticComparator.evaluate(
                dimension: .temporalArtifact,
                fixtureBackendIDs: ["fixture.a", "fixture.a"],
                records: []
            )
        ) { error in
            XCTAssertEqual(
                error as? R07ArtifactGovernanceError,
                .duplicateComparatorBackendID("fixture.a")
            )
        }
        XCTAssertThrowsError(
            try R07SyntheticComparator.evaluate(
                dimension: .temporalArtifact,
                fixtureBackendIDs: ["fixture.a"],
                records: []
            )
        ) { error in
            XCTAssertEqual(
                error as? R07ArtifactGovernanceError,
                .comparatorRecordCountMismatch(expected: 1, actual: 0)
            )
        }

        let incomplete = R07SyntheticComparatorRecord(
            fixtureBackendID: "fixture.a",
            dimension: .temporalArtifact,
            baselineValue: 1,
            autoValue: 0,
            complete: false
        )
        XCTAssertThrowsError(
            try R07SyntheticComparator.evaluate(
                dimension: .temporalArtifact,
                fixtureBackendIDs: ["fixture.a"],
                records: [incomplete]
            )
        ) { error in
            XCTAssertEqual(
                error as? R07ArtifactGovernanceError,
                .incompleteComparatorRecord("fixture.a")
            )
        }
    }

    func testSyntheticComparatorRejectsDimensionUnknownAndDuplicateRecords() {
        let wrongDimension = makeRecord(
            .chromaDisplacement,
            backendID: "fixture.a",
            baseline: 1,
            auto: 0
        )
        XCTAssertThrowsError(
            try R07SyntheticComparator.evaluate(
                dimension: .temporalArtifact,
                fixtureBackendIDs: ["fixture.a"],
                records: [wrongDimension]
            )
        )

        let unknown = makeRecord(
            .temporalArtifact,
            backendID: "fixture.b",
            baseline: 1,
            auto: 0
        )
        XCTAssertThrowsError(
            try R07SyntheticComparator.evaluate(
                dimension: .temporalArtifact,
                fixtureBackendIDs: ["fixture.a"],
                records: [unknown]
            )
        ) { error in
            XCTAssertEqual(
                error as? R07ArtifactGovernanceError,
                .unknownComparatorBackendID("fixture.b")
            )
        }

        let duplicate = makeRecord(
            .temporalArtifact,
            backendID: "fixture.a",
            baseline: 1,
            auto: 0
        )
        XCTAssertThrowsError(
            try R07SyntheticComparator.evaluate(
                dimension: .temporalArtifact,
                fixtureBackendIDs: ["fixture.a", "fixture.b"],
                records: [duplicate, duplicate]
            )
        ) { error in
            XCTAssertEqual(
                error as? R07ArtifactGovernanceError,
                .duplicateComparatorRecord("fixture.a")
            )
        }
    }

    func testSyntheticComparatorCheckedSubtractionRejectsOverflow() {
        let record = makeRecord(
            .temporalArtifact,
            backendID: "fixture.overflow",
            baseline: .max,
            auto: -1
        )
        XCTAssertThrowsError(
            try R07SyntheticComparator.evaluate(
                dimension: .temporalArtifact,
                fixtureBackendIDs: [record.fixtureBackendID],
                records: [record]
            )
        ) { error in
            XCTAssertEqual(
                error as? R07ArtifactGovernanceError,
                .arithmeticOverflow(operation: "temporal_artifact_comparator_subtract")
            )
        }
    }

    func testArtifactAndComparatorValuesAreSendableAndHashable() throws {
        let measurement = try R07ArtifactGovernance.measurement(kind: .ringing, rawValue: 0)
        let blocked = R07BlockedProductComparison(dimension: .temporalArtifact)
        requireSendable(measurement)
        requireSendable(blocked)
        XCTAssertEqual(Set([measurement, measurement]).count, 1)
        XCTAssertEqual(Set([blocked, blocked]).count, 1)
    }
}

private extension R07ArtifactGovernanceTests {
    func assertMeasurement(
        _ measurement: R07ArtifactMeasurement,
        kind: R07ArtifactKind,
        raw: Int64,
        risk: Int64,
        detected: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(measurement.kind, kind, file: file, line: line)
        XCTAssertEqual(measurement.rawValue, raw, file: file, line: line)
        XCTAssertEqual(measurement.normalizedRiskQ16.rawValue, risk, file: file, line: line)
        XCTAssertEqual(measurement.detected, detected, file: file, line: line)
    }

    func evaluate(
        _ dimension: R07ComparatorDimension,
        backendID: String,
        baseline: Int64,
        auto: Int64
    ) throws -> R07SyntheticComparatorResult {
        let results = try R07SyntheticComparator.evaluate(
            dimension: dimension,
            fixtureBackendIDs: [backendID],
            records: [makeRecord(dimension, backendID: backendID, baseline: baseline, auto: auto)]
        )
        return try XCTUnwrap(results.first)
    }

    func makeRecord(
        _ dimension: R07ComparatorDimension,
        backendID: String,
        baseline: Int64,
        auto: Int64
    ) -> R07SyntheticComparatorRecord {
        R07SyntheticComparatorRecord(
            fixtureBackendID: backendID,
            dimension: dimension,
            baselineValue: baseline,
            autoValue: auto,
            complete: true
        )
    }

    func requireSendable<Value: Sendable>(_ value: Value) {
        _ = value
    }
}

private struct ComparatorFixture {
    let dimension: R07ComparatorDimension
    let baseline: Int64
    let auto: Int64
    let expectedDelta: Int64
    let expectedPassed: Bool

    init(
        _ dimension: R07ComparatorDimension,
        _ baseline: Int64,
        _ auto: Int64,
        _ expectedDelta: Int64,
        _ expectedPassed: Bool
    ) {
        self.dimension = dimension
        self.baseline = baseline
        self.auto = auto
        self.expectedDelta = expectedDelta
        self.expectedPassed = expectedPassed
    }
}
