import Foundation
import XCTest
@testable import Mirmir

// swiftlint:disable file_length

// swiftlint:disable:next type_body_length
final class ASHSpatialOperatorBankV2Tests: XCTestCase {
    private struct DiscriminationCase {
        let plane: ASHSpatialPlaneV2
        let destinationColumn: Int
        let destinationRow: Int
        let route: ASHSpatialRouteV2
        let policy: ASHSpatialCoordinatePolicyV2
        let sidecar: ASHSpatialSidecarV2
        let boundary: ASHSpatialBoundaryModeV2
    }

    func test_descriptorIDsUseRawLeastSignificantAxisBits() throws {
        XCTAssertEqual(ASHSpatialOperatorBankV2.descriptors.count, 16)
        XCTAssertEqual(Set(ASHSpatialOperatorBankV2.descriptors).count, 16)

        let zero = try ASHSpatialDescriptorV2(id: 0)
        XCTAssertEqual(zero.baseKernel, .keysCubicAMinusHalf)
        XCTAssertEqual(zero.supportMode, .isotropic)
        XCTAssertEqual(zero.detailMode, .conservative)
        XCTAssertEqual(zero.limiterMode, .strictNeighborhoodRange)

        XCTAssertEqual(try ASHSpatialDescriptorV2(id: 1).baseKernel, .lanczos3)
        XCTAssertEqual(try ASHSpatialDescriptorV2(id: 2).supportMode, .structureTensorAnisotropic)
        XCTAssertEqual(try ASHSpatialDescriptorV2(id: 4).detailMode, .controlledPositive)
        XCTAssertEqual(try ASHSpatialDescriptorV2(id: 8).limiterMode, .calibratedRelaxedRange)
        XCTAssertThrowsError(try ASHSpatialDescriptorV2(id: 16)) { error in
            XCTAssertEqual(error as? ASHSpatialOperatorErrorV2, .invalidDescriptorID(16))
        }
    }

    func test_p05ParametersAreExplicitAndMarkedDevelopmentOnly() {
        let parameters = ASHSpatialDevelopmentParametersV2.p05DevelopmentOnly

        XCTAssertEqual(ASHSpatialDevelopmentParametersV2.lockStatus, "development_only_not_release_locked")
        XCTAssertTrue(parameters.isValid)
        XCTAssertEqual(parameters.anisotropyStrength, 0.75)
        XCTAssertEqual(parameters.controlledDetailGain, 0.18)
        XCTAssertEqual(parameters.relaxedLimiterAlpha, 0.08)
    }

    func test_identityCoordinatesAndBothScalePoliciesAreExactRationals() throws {
        for policy in ASHSpatialCoordinatePolicyV2.allCases {
            for destinationIndex in 0..<8 {
                let identity = try ASHSpatialOperatorBankV2.coordinate(
                    destinationIndex: destinationIndex,
                    sourceExtent: 8,
                    destinationExtent: 8,
                    policy: policy
                )
                XCTAssertEqual(identity.value, Double(destinationIndex), accuracy: 0.0)
                XCTAssertTrue(identity.isIntegral)
            }
        }

        let halfPixel = try ASHSpatialOperatorBankV2.coordinate(
            destinationIndex: 0,
            sourceExtent: 4,
            destinationExtent: 8,
            policy: .halfPixelCenter
        )
        let sourceAligned = try ASHSpatialOperatorBankV2.coordinate(
            destinationIndex: 0,
            sourceExtent: 4,
            destinationExtent: 8,
            policy: .sourceAlignedRational
        )
        XCTAssertEqual(halfPixel.numerator, -4)
        XCTAssertEqual(halfPixel.denominator, 16)
        XCTAssertEqual(halfPixel.value, -0.25, accuracy: 0.0)
        XCTAssertEqual(sourceAligned.value, 0.0, accuracy: 0.0)
    }

    func test_directRoutesExposeExactlyFourAndNinePhasePairsForBothPolicies() throws {
        let plane2x = try constantPlane(width: 4, height: 4, value: 0.4)
        let plane3Over2 = try constantPlane(width: 6, height: 6, value: 0.4)

        for policy in ASHSpatialCoordinatePolicyV2.allCases {
            var direct2xPhases: Set<ASHSpatialPhaseV2> = []
            for row in 0..<2 {
                for column in 0..<2 {
                    direct2xPhases.insert(try ASHSpatialOperatorBankV2.phase(
                        destinationColumn: column,
                        destinationRow: row,
                        plane: plane2x,
                        route: .direct2x,
                        policy: policy
                    ))
                }
            }
            XCTAssertEqual(direct2xPhases.count, ASHSpatialRouteV2.direct2x.phasePairCount)

            var direct3Over2Phases: Set<ASHSpatialPhaseV2> = []
            for row in 0..<3 {
                for column in 0..<3 {
                    direct3Over2Phases.insert(try ASHSpatialOperatorBankV2.phase(
                        destinationColumn: column,
                        destinationRow: row,
                        plane: plane3Over2,
                        route: .direct3Over2,
                        policy: policy
                    ))
                }
            }
            XCTAssertEqual(direct3Over2Phases.count, ASHSpatialRouteV2.direct3Over2.phasePairCount)
        }
    }

    func test_sourceAlignedPhasesPreserveExactSamplesForEveryDescriptor() throws {
        let plane = try patternedPlane(.asymmetric)
        let sidecar = try coherentSidecar(orientation: .pi / 4.0)

        for descriptor in ASHSpatialOperatorBankV2.descriptors {
            let direct2x = try evaluate(
                plane: plane,
                column: 6,
                row: 10,
                route: .direct2x,
                policy: .sourceAlignedRational,
                descriptor: descriptor,
                sidecar: sidecar,
                boundary: .clamp
            )
            XCTAssertTrue(direct2x.sourceAlignedSamplePreserved)
            XCTAssertEqual(direct2x.value, plane.sample(column: 3, row: 5, boundary: .clamp), accuracy: 0.0)

            let direct3Over2 = try evaluate(
                plane: plane,
                column: 6,
                row: 9,
                route: .direct3Over2,
                policy: .sourceAlignedRational,
                descriptor: descriptor,
                sidecar: sidecar,
                boundary: .mirrorReflect101
            )
            XCTAssertTrue(direct3Over2.sourceAlignedSamplePreserved)
            XCTAssertEqual(direct3Over2.value, plane.sample(column: 4, row: 6, boundary: .clamp), accuracy: 0.0)
        }
    }

    func test_allDescriptorsPreserveConstantsAcrossRoutesPoliciesAndBoundaries() throws {
        let plane = try constantPlane(width: 8, height: 8, value: 0.42)
        let sidecar = try coherentSidecar(orientation: .pi / 4.0)

        for descriptor in ASHSpatialOperatorBankV2.descriptors {
            for route in ASHSpatialRouteV2.allCases {
                for policy in ASHSpatialCoordinatePolicyV2.allCases {
                    for boundary in ASHSpatialBoundaryModeV2.allCases {
                        let result = try evaluate(
                            plane: plane,
                            column: 1,
                            row: 2,
                            route: route,
                            policy: policy,
                            descriptor: descriptor,
                            sidecar: sidecar,
                            boundary: boundary
                        )
                        XCTAssertEqual(result.value, 0.42, accuracy: 1.0e-12)
                    }
                }
            }
        }
    }

    func test_keysCubicReproducesInteriorRampsForDirect2xAnd3Over2() throws {
        let plane = try patternedPlane(.ramp)
        let descriptor = try ASHSpatialDescriptorV2(id: 0)
        let sidecar = try coherentSidecar(orientation: 0.0)

        for route in ASHSpatialRouteV2.allCases {
            let result = try evaluate(
                plane: plane,
                column: route == .direct2x ? 7 : 5,
                row: route == .direct2x ? 9 : 7,
                route: route,
                policy: .halfPixelCenter,
                descriptor: descriptor,
                sidecar: sidecar,
                boundary: .clamp
            )
            let expected = 0.15 + (0.70 * ((result.sourceX.value + result.sourceY.value) / 14.0))
            XCTAssertEqual(result.value, expected, accuracy: 1.0e-12)
        }
    }

    func test_clampAndReflect101BordersAreExplicitAndEvaluable() throws {
        let plane = try ASHSpatialPlaneV2(
            width: 3,
            height: 3,
            samples: (0..<9).map { Double($0) / 8.0 }
        )
        XCTAssertEqual(plane.sample(column: -1, row: -1, boundary: .clamp), 0.0)
        XCTAssertEqual(plane.sample(column: -1, row: -1, boundary: .mirrorReflect101), 0.5)
        XCTAssertEqual(plane.sample(column: 3, row: 3, boundary: .mirrorReflect101), 0.5)

        let sidecar = try coherentSidecar(orientation: .pi / 2.0)
        let descriptor = try ASHSpatialDescriptorV2(id: 3)
        for boundary in ASHSpatialBoundaryModeV2.allCases {
            let result = try evaluate(
                plane: plane,
                column: 0,
                row: 0,
                route: .direct2x,
                policy: .halfPixelCenter,
                descriptor: descriptor,
                sidecar: sidecar,
                boundary: boundary
            )
            XCTAssertTrue(result.value.isFinite)
            XCTAssertTrue((0.0...1.0).contains(result.value))
        }
    }

    func test_normalizedYAndCbCrSamplesAlwaysClampToDeclaredLegalRange() throws {
        let values = (0..<64).map { index in index.isMultiple(of: 2) ? 0.05 : 0.95 }
        let planes = try [
            ASHSpatialPlaneV2(width: 8, height: 8, samples: values, legalRange: 0.10...0.90),
            ASHSpatialPlaneV2(width: 8, height: 8, samples: values, legalRange: 0.15...0.85),
            ASHSpatialPlaneV2(width: 8, height: 8, samples: values, legalRange: 0.20...0.80)
        ]
        let sidecar = try coherentSidecar(orientation: 3.0 * .pi / 4.0)

        for plane in planes {
            for descriptor in ASHSpatialOperatorBankV2.descriptors {
                let result = try evaluate(
                    plane: plane,
                    column: 5,
                    row: 7,
                    route: .direct3Over2,
                    policy: .halfPixelCenter,
                    descriptor: descriptor,
                    sidecar: sidecar,
                    boundary: .mirrorReflect101
                )
                XCTAssertGreaterThanOrEqual(result.value, plane.legalRange.lowerBound)
                XCTAssertLessThanOrEqual(result.value, plane.legalRange.upperBound)
            }
        }
    }

    func test_strictAndRelaxedLimitersDiscriminateOnOvershootFixtures() throws {
        let fixtures = try [patternedPlane(.impulse), patternedPlane(.verticalEdge), patternedPlane(.nearNyquist)]
        let strict = try ASHSpatialDescriptorV2(id: 1)
        let relaxed = try ASHSpatialDescriptorV2(id: 9)
        let sidecar = try coherentSidecar(orientation: 0.0)
        var foundDifference = false

        for plane in fixtures {
            for row in 0..<16 {
                for column in 0..<16 {
                    let strictValue = try evaluate(
                        plane: plane,
                        column: column,
                        row: row,
                        route: .direct2x,
                        policy: .halfPixelCenter,
                        descriptor: strict,
                        sidecar: sidecar,
                        boundary: .clamp
                    ).value
                    let relaxedValue = try evaluate(
                        plane: plane,
                        column: column,
                        row: row,
                        route: .direct2x,
                        policy: .halfPixelCenter,
                        descriptor: relaxed,
                        sidecar: sidecar,
                        boundary: .clamp
                    ).value
                    foundDifference = foundDifference || abs(strictValue - relaxedValue) > 1.0e-10
                }
            }
        }
        XCTAssertTrue(foundDifference)
    }

    func test_fourTensorOrientationsAndRequiredSyntheticFixtureClassesAreFinite() throws {
        let fixtureKinds = PatternKind.allCases
        let orientations = [0.0, .pi / 4.0, .pi / 2.0, 3.0 * .pi / 4.0]
        let descriptor = try ASHSpatialDescriptorV2(id: 15)

        for fixtureKind in fixtureKinds {
            let plane = try patternedPlane(fixtureKind)
            for orientation in orientations {
                let result = try evaluate(
                    plane: plane,
                    column: 5,
                    row: 7,
                    route: .direct3Over2,
                    policy: .halfPixelCenter,
                    descriptor: descriptor,
                    sidecar: try coherentSidecar(orientation: orientation),
                    boundary: .mirrorReflect101
                )
                XCTAssertTrue(result.value.isFinite, fixtureKind.rawValue)
                XCTAssertTrue(plane.legalRange.contains(result.value), fixtureKind.rawValue)
            }
        }
    }

    func test_resultPublishesConstraintDiagnosticsForAnisotropyDetailAndLimiter() throws {
        let plane = try patternedPlane(.asymmetric)
        let descriptor = try ASHSpatialDescriptorV2(id: 14)
        let result = try evaluate(
            plane: plane,
            column: 5,
            row: 7,
            route: .direct3Over2,
            policy: .halfPixelCenter,
            descriptor: descriptor,
            sidecar: try coherentSidecar(orientation: .pi / 4.0),
            boundary: .mirrorReflect101
        )

        XCTAssertLessThanOrEqual(result.diagnostics.supportMinimum, result.diagnostics.supportMaximum)
        XCTAssertEqual(result.diagnostics.limiterMode, .calibratedRelaxedRange)
        XCTAssertLessThan(result.diagnostics.limiterLowerBound, result.diagnostics.supportMinimum)
        XCTAssertGreaterThan(result.diagnostics.limiterUpperBound, result.diagnostics.supportMaximum)
        XCTAssertTrue(result.diagnostics.anisotropyUsed)
        XCTAssertTrue(result.diagnostics.detailApplied)
        XCTAssertGreaterThan(result.diagnostics.effectiveDetailGain, 0.0)
        XCTAssertGreaterThanOrEqual(result.diagnostics.postLimiterValue, result.diagnostics.limiterLowerBound)
        XCTAssertLessThanOrEqual(result.diagnostics.postLimiterValue, result.diagnostics.limiterUpperBound)
    }

    func test_all120DescriptorPairsAreBehaviorallyDistinctAcrossFixtureSuite() throws {
        let cases = try discriminationCases()
        let signatures = try ASHSpatialOperatorBankV2.descriptors.map { descriptor in
            try cases.map { testCase in
                try evaluate(testCase, descriptor: descriptor).value
            }
        }
        var checkedPairCount = 0

        for firstIndex in 0..<(ASHSpatialDescriptorV2.count - 1) {
            for secondIndex in (firstIndex + 1)..<ASHSpatialDescriptorV2.count {
                checkedPairCount += 1
                let differs = zip(signatures[firstIndex], signatures[secondIndex]).contains { pair in
                    abs(pair.0 - pair.1) > 1.0e-10
                }
                XCTAssertTrue(differs, "Descriptors \(firstIndex) and \(secondIndex) were universally equal")
            }
        }
        XCTAssertEqual(checkedPairCount, 120)
    }

    func test_zeroAndNonfiniteWeightFailuresAreTyped() {
        XCTAssertThrowsError(try ASHSpatialOperatorBankV2.normalize(
            weightedSum: 1.0,
            totalWeight: 0.0,
            epsilon: 1.0e-12
        )) { error in
            XCTAssertEqual(error as? ASHSpatialOperatorErrorV2, .zeroWeight)
        }
        XCTAssertThrowsError(try ASHSpatialOperatorBankV2.normalize(
            weightedSum: .nan,
            totalWeight: 1.0,
            epsilon: 1.0e-12
        )) { error in
            XCTAssertEqual(error as? ASHSpatialOperatorErrorV2, .nonFiniteWeight)
        }

        let zeroFallback = ASHSpatialOperatorBankV2.conservativeFallback(for: .zeroWeight)
        XCTAssertEqual(zeroFallback?.fault, .zeroWeight)
        XCTAssertEqual(zeroFallback?.descriptorID, 0)
        XCTAssertEqual(zeroFallback?.limiterMode, .strictNeighborhoodRange)
        XCTAssertEqual(zeroFallback?.preserveExactCoordinate, true)
        XCTAssertNil(ASHSpatialOperatorBankV2.conservativeFallback(for: .invalidLegalRange))
    }

    private enum PatternKind: String, CaseIterable {
        case constant
        case ramp
        case impulse
        case horizontalEdge
        case verticalEdge
        case positiveDiagonal
        case negativeDiagonal
        case corner
        case thinLine
        case nearNyquist
        case asymmetric
    }

    private func patternedPlane(_ kind: PatternKind) throws -> ASHSpatialPlaneV2 {
        let values = (0..<8).flatMap { row in
            (0..<8).map { column -> Double in
                switch kind {
                case .constant: return 0.42
                case .ramp: return 0.15 + (0.70 * (Double(row + column) / 14.0))
                case .impulse: return row == 4 && column == 4 ? 0.75 : 0.25
                case .horizontalEdge: return row < 4 ? 0.25 : 0.75
                case .verticalEdge: return column < 4 ? 0.25 : 0.75
                case .positiveDiagonal: return column >= row ? 0.75 : 0.25
                case .negativeDiagonal: return column + row >= 7 ? 0.75 : 0.25
                case .corner: return row >= 4 && column >= 4 ? 0.75 : 0.25
                case .thinLine: return column == 4 ? 0.75 : 0.25
                case .nearNyquist: return (row + column).isMultiple(of: 2) ? 0.30 : 0.70
                case .asymmetric:
                    let residue = ((row * 17) + (column * 29) + (row * column * 7)) % 101
                    return 0.15 + (0.70 * (Double(residue) / 100.0))
                }
            }
        }
        return try ASHSpatialPlaneV2(width: 8, height: 8, samples: values)
    }

    private func constantPlane(width: Int, height: Int, value: Double) throws -> ASHSpatialPlaneV2 {
        try ASHSpatialPlaneV2(
            width: width,
            height: height,
            samples: Array(repeating: value, count: width * height)
        )
    }

    private func coherentSidecar(orientation: Double) throws -> ASHSpatialSidecarV2 {
        try ASHSpatialSidecarV2(
            orientationRadians: orientation,
            normalizedMagnitude: 0.90,
            coherence: 0.92,
            risk: 0.10,
            chromaAlignment: 0.95,
            localMinimum: 0.15,
            localMaximum: 0.85
        )
    }

    private func evaluate(
        plane: ASHSpatialPlaneV2,
        column: Int,
        row: Int,
        route: ASHSpatialRouteV2,
        policy: ASHSpatialCoordinatePolicyV2,
        descriptor: ASHSpatialDescriptorV2,
        sidecar: ASHSpatialSidecarV2,
        boundary: ASHSpatialBoundaryModeV2
    ) throws -> ASHSpatialSampleResultV2 {
        try ASHSpatialOperatorBankV2.evaluateSample(ASHSpatialSampleRequestV2(
            plane: plane,
            destinationColumn: column,
            destinationRow: row,
            route: route,
            coordinatePolicy: policy,
            descriptor: descriptor,
            sidecar: sidecar,
            boundary: boundary,
            parameters: .p05DevelopmentOnly,
            coordinateOverride: nil
        ))
    }

    private func evaluate(
        _ testCase: DiscriminationCase,
        descriptor: ASHSpatialDescriptorV2
    ) throws -> ASHSpatialSampleResultV2 {
        try evaluate(
            plane: testCase.plane,
            column: testCase.destinationColumn,
            row: testCase.destinationRow,
            route: testCase.route,
            policy: testCase.policy,
            descriptor: descriptor,
            sidecar: testCase.sidecar,
            boundary: testCase.boundary
        )
    }

    private func discriminationCases() throws -> [DiscriminationCase] {
        let planes = try PatternKind.allCases.map(patternedPlane)
        let sidecars = try [0.0, .pi / 4.0, .pi / 2.0, 3.0 * .pi / 4.0].map(coherentSidecar)
        let points = [(1, 2), (4, 5), (7, 8)]
        var cases: [DiscriminationCase] = []

        for plane in planes {
            for route in ASHSpatialRouteV2.allCases {
                for policy in ASHSpatialCoordinatePolicyV2.allCases {
                    for boundary in ASHSpatialBoundaryModeV2.allCases {
                        for sidecar in sidecars {
                            for point in points {
                                cases.append(DiscriminationCase(
                                    plane: plane,
                                    destinationColumn: point.0,
                                    destinationRow: point.1,
                                    route: route,
                                    policy: policy,
                                    sidecar: sidecar,
                                    boundary: boundary
                                ))
                            }
                        }
                    }
                }
            }
        }
        return cases
    }
}

// swiftlint:enable file_length
