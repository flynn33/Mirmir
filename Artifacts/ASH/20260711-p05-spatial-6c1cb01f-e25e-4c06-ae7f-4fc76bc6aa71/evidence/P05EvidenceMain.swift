import CryptoKit
import Foundation

// swiftlint:disable file_length type_body_length function_body_length

struct P05EvidenceFileDigest {
    let path: String
    let sha256: String
    let byteCount: Int

    var json: [String: Any] {
        [
            "path": path,
            "sha256": sha256,
            "byte_count": byteCount
        ]
    }
}

enum P05EvidenceError: Error, CustomStringConvertible {
    case invalidArguments
    case failed(String)

    var description: String {
        switch self {
        case .invalidArguments:
            return "Expected one output-directory argument."
        case .failed(let message):
            return message
        }
    }
}

private struct P05DiscriminationCase {
    let identifier: String
    let plane: ASHSpatialPlaneV2
    let destinationColumn: Int
    let destinationRow: Int
    let route: ASHSpatialRouteV2
    let policy: ASHSpatialCoordinatePolicyV2
    let sidecar: ASHSpatialSidecarV2
    let boundary: ASHSpatialBoundaryModeV2
}

private enum P05PatternKind: String, CaseIterable {
    case constant
    case ramp
    case impulse
    case horizontalEdge = "horizontal_edge"
    case verticalEdge = "vertical_edge"
    case positiveDiagonal = "positive_diagonal"
    case negativeDiagonal = "negative_diagonal"
    case corner
    case thinLine = "thin_line"
    case nearNyquist = "near_nyquist"
    case asymmetric
}

private struct P05OperatorEvidence {
    let pairWitnesses: [[String: Any]]
    let behaviorSignatures: [[String: Any]]
    let fixtureCaseCount: Int
}

private struct P05CPUReferenceEvidence {
    let vectors: [[String: Any]]
    let sourceAlignedVectors: [[String: Any]]
    let signatureSHA256: String
}

private struct P05PipelineEvidence {
    let enabled: ASHSpatialReferenceOutputV2
    let disabled: ASHSpatialReferenceOutputV2
    let maximumAbsoluteDelta: Double
    let inputSignatureSHA256: String
    let enabledSignatureSHA256: String
    let disabledSignatureSHA256: String
    let perPlaneAblations: [[String: Any]]
}

private struct P05PlaneDispatchEvidence {
    let lumaRecords: [[String: Any]]
    let chromaRecords: [[String: Any]]
    let lumaDispatchCount: Int
    let chromaDispatchCount: Int
    let neutralComparisonCount: Int
    let decodedDispatchEvaluationCount: Int
    let failureCounters: [String: Int]
}

private struct P05PhaseGroupAudit {
    let record: [String: Any]
    let dispatchCount: Int
    let neutralComparisonCount: Int
    let decodedDispatchEvaluationCount: Int
    let failureCounters: [String: Int]
}

@main
enum P05EvidenceMain {
    private static let tolerance = 1.0e-10

    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw P05EvidenceError.invalidArguments
        }
        let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let configuration = try ASHVideoAnalyzerV2DevelopmentConfiguration.makeDisposableP05Reference()

        let stateFixtureData = try makeStateFixtureData(configuration: configuration)
        let developmentMappingData = try makeDevelopmentMappingData(configuration: configuration)
        let operatorEvidence = try makeOperatorEvidence()
        let planeDispatchEvidence = try makePlaneDispatchEvidence()
        let coordinateData = try makeCoordinateComparisonData(planeDispatchEvidence: planeDispatchEvidence)
        let cpuEvidence = try makeCPUReferenceEvidence()
        let pipelineEvidence = try makePipelineEvidence(configuration: configuration)
        let causalityData = try makeStateCausalityData(
            configuration: configuration,
            pipelineEvidence: pipelineEvidence,
            planeDispatchEvidence: planeDispatchEvidence
        )

        try writeArtifact(
            named: "development-mapping",
            criteria: [
                criterion("valid-state-cardinality", "512 raw states classify as 256 valid and 256 invalid"),
                criterion("development-only-parameters", "thresholds are explicit and not release locked"),
                criterion("range-normalization", "video/full luma and chroma endpoint vectors use production code")
            ],
            data: developmentMappingData,
            to: outputDirectory
        )
        try writeArtifact(
            named: "state-fixtures",
            criteria: [
                criterion("all-state-bits-controlled", "nine controlled fixtures cover eight payload coordinates and integrity"),
                criterion("normal-tangent-convention", "four synthetic edges satisfy tangent equals normal plus pi over two modulo pi")
            ],
            data: stateFixtureData,
            to: outputDirectory
        )
        try writeArtifact(
            named: "operator-discrimination",
            criteria: [
                criterion("all-descriptor-pairs", "all 120 unordered descriptor pairs have a nonconstant witness"),
                criterion("constant-equality-allowed", "constant fixtures remain in the suite without being used as a universal-equality failure")
            ],
            data: [
                "descriptor_count": 16,
                "expected_pair_count": 120,
                "passing_pair_count": operatorEvidence.pairWitnesses.count,
                "fixture_case_count": operatorEvidence.fixtureCaseCount,
                "pair_witnesses": operatorEvidence.pairWitnesses
            ],
            to: outputDirectory
        )
        try writeArtifact(
            named: "operator-distinctness",
            criteria: [
                criterion("semantic-distinctness", "all 16 descriptor records differ on stable axis fields"),
                criterion("behavioral-distinctness", "all 120 unordered pairs differ on at least one qualifying synthetic case")
            ],
            data: [
                "descriptor_count": 16,
                "semantically_unique_count": Set(ASHSpatialOperatorBankV2.descriptors).count,
                "behaviorally_distinct_pair_count": operatorEvidence.pairWitnesses.count,
                "descriptors": ASHSpatialOperatorBankV2.descriptors.map(descriptorJSON),
                "behavior_signatures": operatorEvidence.behaviorSignatures
            ],
            to: outputDirectory
        )
        try writeArtifact(
            named: "coordinate-comparison",
            criteria: [
                criterion("both-coordinate-policies", "half-pixel-center and source-aligned-rational execute through the production coordinate function"),
                criterion("route-phase-cardinality", "direct 2x exposes four phase pairs and direct 3/2 exposes nine for both policies"),
                criterion("synthetic-coordinate-tests", "identity, ramps, and explicit borders pass")
            ],
            data: coordinateData,
            to: outputDirectory
        )
        try writeArtifact(
            named: "state-causality-results",
            criteria: [
                criterion("nonconstant-valid-state-dispatch", "the same phase produces multiple primary descriptors across 256 valid states"),
                criterion("bounded-affine-dispatch", "all 3328 state-route-phase dispatches recover exactly with at most two evaluations"),
                criterion("per-plane-corrected-phase-dispatch", "luma and all progressive-siting chroma phase caches recover decoded messages exactly"),
                criterion("neutral-phase-preserving-ablation", "state-disabled dispatch uses the neutral selector state while retaining source anchor and exact plane phase"),
                criterion("first-frame-variation", "production analyzer output produces multiple first-frame primary descriptors"),
                criterion("state-disabled-delta", "the production reference pipeline changes reconstructed samples when state input is disabled")
            ],
            data: causalityData,
            to: outputDirectory
        )
        try writeArtifact(
            named: "cpu-reference-results",
            criteria: [
                criterion("direct-routes", "direct 2x and direct 3/2 production CPU sample evaluation passes"),
                criterion("all-descriptors-and-channels", "192 vectors cover both routes, both policies, Y/Cb/Cr, and all 16 descriptors"),
                criterion("source-aligned-preservation", "32 route-descriptor vectors preserve exact source samples"),
                criterion("no-nearest-substrate", "the production reference pipeline reports no nearest expansion")
            ],
            data: [
                "route_count": ASHSpatialRouteV2.allCases.count,
                "coordinate_policy_count": ASHSpatialCoordinatePolicyV2.allCases.count,
                "descriptor_count": ASHSpatialDescriptorV2.count,
                "channel_count": 3,
                "vector_count": cpuEvidence.vectors.count,
                "source_aligned_preservation_count": cpuEvidence.sourceAlignedVectors.count,
                "nearest_expansion_used": pipelineEvidence.enabled.summary.nearestExpansionUsed,
                "maximum_operator_evaluations": pipelineEvidence.enabled.summary.maxOperatorEvaluations,
                "runtime_tree_generation_count": pipelineEvidence.enabled.summary.runtimeTreeGenerationCount,
                "tests": cpuReferenceTests(pipelineEvidence: pipelineEvidence)
            ],
            to: outputDirectory
        )
        try writeArtifact(
            named: "cpu-reference-vectors",
            criteria: [
                criterion("deterministic-vectors", "vector ordering and values are serialized with a deterministic signature"),
                criterion("legal-range-limiting", "every Y/Cb/Cr vector lies inside its declared normalized legal range")
            ],
            data: [
                "vector_count": cpuEvidence.vectors.count,
                "vectors": cpuEvidence.vectors,
                "vector_signature_sha256": cpuEvidence.signatureSHA256,
                "source_aligned_vectors": cpuEvidence.sourceAlignedVectors
            ],
            to: outputDirectory
        )
    }

    private static func criterion(_ identifier: String, _ evidence: String) -> [String: Any] {
        ["id": identifier, "status": "pass", "evidence": evidence]
    }

    private static func provenance() -> [String: Any] {
        [
            "production_source_manifest_sha256": P05EvidenceInputDigests.productionSourceManifestSHA256,
            "configuration_manifest_sha256": P05EvidenceInputDigests.configurationManifestSHA256,
            "harness_manifest_sha256": P05EvidenceInputDigests.harnessManifestSHA256,
            "production_sources": P05EvidenceInputDigests.productionSources.map(\.json),
            "configuration_files": P05EvidenceInputDigests.configurationFiles.map(\.json),
            "harness_files": P05EvidenceInputDigests.harnessFiles.map(\.json),
            "reproduction_command": "python3 validation/spatial_v2/run_p05_evidence.py --output <evidence-directory>"
        ]
    }

    private static func writeArtifact(
        named name: String,
        criteria: [[String: Any]],
        data: [String: Any],
        to directory: URL
    ) throws {
        let artifact: [String: Any] = [
            "schema_version": "1.0.0",
            "artifact_type": name,
            "phase": "P05",
            "gate": "G05",
            "status": "pass",
            "parameter_status": ASHSpatialDevelopmentParametersV2.lockStatus,
            "input_scope": "synthetic_only",
            "holdout_accessed": false,
            "provenance": provenance(),
            "criteria": criteria,
            "data": data
        ]
        try require(JSONSerialization.isValidJSONObject(artifact), "Invalid JSON object for \(name)")
        var encoded = try JSONSerialization.data(
            withJSONObject: artifact,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        encoded.append(0x0a)
        try encoded.write(to: directory.appendingPathComponent("\(name).json"), options: .atomic)
    }

    private static func makeDevelopmentMappingData(
        configuration: ASHVideoAnalyzerV2DevelopmentConfiguration
    ) throws -> [String: Any] {
        var validCount = 0
        var invalidCount = 0
        for raw in UInt16(0)..<UInt16(1 << ASHState.bitCount) {
            if try ASHState(rawValue: raw).hasValidIntegrity {
                validCount += 1
            } else {
                invalidCount += 1
            }
        }
        try require(validCount == 256 && invalidCount == 256, "Unexpected raw-state parity cardinality")
        let mappingDigest = try configurationDigest(suffix: "ash_video_mapping_v2.seed.json")
        return [
            "mapping_id": "ash-video-mapping-v2",
            "mapping_schema_version": "2.0.1-seed",
            "mapping_sha256": mappingDigest.sha256,
            "canonical_core_unchanged": true,
            "valid_state_count": validCount,
            "invalid_state_count": invalidCount,
            "payload_bit_count": ASHState.payloadBitCount,
            "integrity_bit_coordinate": 9,
            "gradient_kernel": "scharr_3x3_divisor_32",
            "tensor_window": "separable_binomial_1_4_6_4_1_divisor_16",
            "orientation_domain": "edge_tangent_modulo_pi",
            "thresholds": thresholdJSON(configuration),
            "numeric_epsilon": configuration.epsilon,
            "risk_weights": [
                "laplacian": configuration.riskWeights.laplacian,
                "alternating_difference": configuration.riskWeights.alternatingDifference
            ],
            "range_vectors": try rangeVectors()
        ]
    }

    private static func thresholdJSON(
        _ configuration: ASHVideoAnalyzerV2DevelopmentConfiguration
    ) -> [String: Any] {
        func band(_ value: ASHVideoAnalyzerV2ThresholdBand) -> [String: Any] {
            ["low": value.low, "high": value.high]
        }
        return [
            "status": "development_only_not_release_locked",
            "edge_present": band(configuration.bands.edgePresent),
            "coherent_structure": band(configuration.bands.coherentStructure),
            "texture_high_frequency": band(configuration.bands.textureHighFrequency),
            "alias_or_ringing_risk": band(configuration.bands.aliasOrRingingRisk),
            "temporal_support_valid": band(configuration.bands.temporalSupportValid),
            "chroma_luma_structure_aligned": band(configuration.bands.chromaLumaStructureAligned)
        ]
    }

    private static func rangeVectors() throws -> [[String: Any]] {
        let vectors: [(String, String, Int, Double, Double)] = [
            ("video", "Y", 16, ASHVideoCodeRange8Bit.video.normalizeLuma(16), 0.0),
            ("video", "Y", 235, ASHVideoCodeRange8Bit.video.normalizeLuma(235), 1.0),
            ("video", "Y", 0, ASHVideoCodeRange8Bit.video.normalizeLuma(0), -16.0 / 219.0),
            ("video", "Y", 255, ASHVideoCodeRange8Bit.video.normalizeLuma(255), 239.0 / 219.0),
            ("video", "CbCr", 16, ASHVideoCodeRange8Bit.video.normalizeChroma(16), -0.5),
            ("video", "CbCr", 240, ASHVideoCodeRange8Bit.video.normalizeChroma(240), 0.5),
            ("full", "Y", 0, ASHVideoCodeRange8Bit.full.normalizeLuma(0), 0.0),
            ("full", "Y", 255, ASHVideoCodeRange8Bit.full.normalizeLuma(255), 1.0),
            ("full", "CbCr", 0, ASHVideoCodeRange8Bit.full.normalizeChroma(0), -0.5),
            ("full", "CbCr", 255, ASHVideoCodeRange8Bit.full.normalizeChroma(255), 0.5)
        ]
        return try vectors.map { range, channel, code, observed, expected in
            try require(abs(observed - expected) <= 1.0e-15, "Range normalization vector mismatch")
            return [
                "range": range,
                "channel": channel,
                "code": code,
                "normalized": observed,
                "expected": expected,
                "absolute_error": abs(observed - expected),
                "pass": true
            ]
        }
    }

    private static func makeStateFixtureData(
        configuration: ASHVideoAnalyzerV2DevelopmentConfiguration
    ) throws -> [String: Any] {
        let zero = try packedState(measurements: measurements(), configuration: configuration)
        var controlled: [[String: Any]] = []

        func append(
            name: String,
            coordinate: Int,
            baseline: ASHState,
            variant: ASHState,
            expectedChanges: [Int]
        ) throws {
            let changed = changedCoordinates(baseline, variant)
            try require(changed == expectedChanges, "Unexpected changed coordinates for \(name): \(changed)")
            controlled.append([
                "name": name,
                "target_coordinate": coordinate,
                "baseline_raw": Int(baseline.rawValue),
                "variant_raw": Int(variant.rawValue),
                "baseline_bits": baseline.bits,
                "variant_bits": variant.bits,
                "changed_coordinates": changed,
                "baseline_integrity_valid": baseline.hasValidIntegrity,
                "variant_integrity_valid": variant.hasValidIntegrity,
                "pass": true
            ])
        }

        let orientationBaseline = try packedState(
            measurements: measurements(gradient: 0.50, sector: 0),
            configuration: configuration
        )
        try append(
            name: "orientation_low",
            coordinate: 1,
            baseline: orientationBaseline,
            variant: try packedState(
                measurements: measurements(gradient: 0.50, sector: 1),
                configuration: configuration
            ),
            expectedChanges: [1, 9]
        )
        try append(
            name: "orientation_high",
            coordinate: 2,
            baseline: orientationBaseline,
            variant: try packedState(
                measurements: measurements(gradient: 0.50, sector: 2),
                configuration: configuration
            ),
            expectedChanges: [2, 9]
        )
        try append(
            name: "edge_present",
            coordinate: 3,
            baseline: zero,
            variant: try packedState(
                measurements: measurements(gradient: 0.50),
                configuration: configuration
            ),
            expectedChanges: [3, 9]
        )
        try append(
            name: "coherent_structure",
            coordinate: 4,
            baseline: zero,
            variant: try packedState(
                measurements: measurements(coherence: 0.50),
                configuration: configuration
            ),
            expectedChanges: [4, 9]
        )
        try append(
            name: "texture_high_frequency",
            coordinate: 5,
            baseline: zero,
            variant: try packedState(
                measurements: measurements(texture: 0.50),
                configuration: configuration
            ),
            expectedChanges: [5, 9]
        )
        try append(
            name: "alias_or_ringing_risk",
            coordinate: 6,
            baseline: zero,
            variant: try packedState(
                measurements: measurements(risk: 0.50),
                configuration: configuration
            ),
            expectedChanges: [6, 9]
        )
        let temporalEvidence = try ASHVideoAnalyzerV2ValidationTemporalEvidence(
            motionResidualPassed: true,
            forwardBackwardConsistencyPassed: true,
            occlusionPassed: true,
            sceneCutPassed: true,
            confidence: 0.50,
            motionVectorQ8_8: .zero
        )
        try append(
            name: "temporal_support_valid",
            coordinate: 7,
            baseline: zero,
            variant: try packedState(
                measurements: measurements(),
                temporalEvidence: temporalEvidence,
                configuration: configuration
            ),
            expectedChanges: [7, 9]
        )
        try append(
            name: "chroma_luma_structure_aligned",
            coordinate: 8,
            baseline: zero,
            variant: try packedState(
                measurements: measurements(chromaAlignment: 0.50),
                configuration: configuration
            ),
            expectedChanges: [8, 9]
        )
        try append(
            name: "integrity_parity",
            coordinate: 9,
            baseline: zero,
            variant: zero.toggled(coordinate: 9),
            expectedChanges: [9]
        )

        try require(controlled.count == 9, "Controlled state fixture count is not nine")
        let orientations = try orientationFixtures(configuration: configuration)
        return [
            "controlled_state_bit_count": controlled.count,
            "controlled_fixtures": controlled,
            "orientation_fixture_count": orientations.count,
            "orientation_fixtures": orientations,
            "boundary_rules": ["clamp", "reflect101"],
            "temporal_bit_phase_policy": "validation_predicates_only; production spatial phase remains false"
        ]
    }

    private static func orientationFixtures(
        configuration: ASHVideoAnalyzerV2DevelopmentConfiguration
    ) throws -> [[String: Any]] {
        let fixtures: [(String, Int)] = [
            ("horizontal_tangent", 0),
            ("positive_diagonal_tangent", 1),
            ("vertical_tangent", 2),
            ("negative_diagonal_tangent", 3)
        ]
        return try fixtures.map { name, expectedSector in
            let result = try analyzeContent(name, configuration: configuration)
            let expectedTangent = moduloPi(result.sidecar.edgeNormalRadians + (.pi / 2.0))
            let angularError = angularDistanceModuloPi(result.sidecar.edgeTangentRadians, expectedTangent)
            try require(result.state.bit(coordinate: 3) == 1, "Orientation fixture did not set edge-present: \(name)")
            try require(result.sidecar.orientationSector == expectedSector, "Unexpected tangent sector for \(name)")
            try require(angularError <= 1.0e-12, "Normal-to-tangent conversion failed for \(name)")
            return [
                "name": name,
                "expected_tangent_sector": expectedSector,
                "observed_tangent_sector": result.sidecar.orientationSector,
                "edge_normal_radians": result.sidecar.edgeNormalRadians,
                "edge_tangent_radians": result.sidecar.edgeTangentRadians,
                "normal_plus_pi_over_two_mod_pi": expectedTangent,
                "angular_error": angularError,
                "state_raw": Int(result.state.rawValue),
                "pass": true
            ]
        }
    }

    private static func packedState(
        measurements: ASHVideoAnalyzerV2Measurements,
        temporalEvidence: ASHVideoAnalyzerV2ValidationTemporalEvidence? = nil,
        configuration: ASHVideoAnalyzerV2DevelopmentConfiguration
    ) throws -> ASHState {
        try ASHVideoAnalyzerV2.packState(
            measurements: measurements,
            history: nil,
            temporalEvidence: temporalEvidence,
            configuration: configuration
        )
    }

    private static func measurements(
        gradient: Double = 0.0,
        coherence: Double = 0.0,
        sector: Int = 0,
        texture: Double = 0.0,
        risk: Double = 0.0,
        chromaAlignment: Double = 0.0
    ) -> ASHVideoAnalyzerV2Measurements {
        let tangent = Double(sector) * (.pi / 4.0)
        return ASHVideoAnalyzerV2Measurements(
            tensorXX: 0.0,
            tensorYY: 0.0,
            tensorXY: 0.0,
            normalizedGradientMagnitude: gradient,
            structureCoherence: coherence,
            edgeNormalRadians: moduloPi(tangent - (.pi / 2.0)),
            edgeTangentRadians: tangent,
            orientationSector: sector,
            textureEnergy: texture,
            riskProxy: risk,
            localNoiseEstimate: 0.0,
            chromaAlignment: chromaAlignment,
            chromaEdgeConfidence: 0.0,
            localMinimumY: 0.0,
            localMaximumY: 1.0
        )
    }

    private static func changedCoordinates(_ first: ASHState, _ second: ASHState) -> [Int] {
        (1...ASHState.bitCount).filter { first.bit(coordinate: $0) != second.bit(coordinate: $0) }
    }

    private static func makeOperatorEvidence() throws -> P05OperatorEvidence {
        let cases = try discriminationCases()
        let descriptors = ASHSpatialOperatorBankV2.descriptors
        let signatures = try descriptors.map { descriptor in
            try cases.map { testCase in
                try evaluate(testCase, descriptor: descriptor).value
            }
        }
        var witnesses: [[String: Any]] = []
        for first in 0..<(descriptors.count - 1) {
            for second in (first + 1)..<descriptors.count {
                guard let witnessIndex = signatures[first].indices.first(where: { index in
                    abs(signatures[first][index] - signatures[second][index]) > tolerance
                }) else {
                    throw P05EvidenceError.failed("Descriptors \(first) and \(second) are universally equal")
                }
                witnesses.append([
                    "first_descriptor": first,
                    "second_descriptor": second,
                    "fixture_id": cases[witnessIndex].identifier,
                    "first_value": signatures[first][witnessIndex],
                    "second_value": signatures[second][witnessIndex],
                    "absolute_delta": abs(signatures[first][witnessIndex] - signatures[second][witnessIndex]),
                    "pass": true
                ])
            }
        }
        try require(witnesses.count == 120, "Descriptor witness count is not 120")
        let behaviorSignatures = signatures.enumerated().map { index, values in
            [
                "descriptor_id": index,
                "sample_count": values.count,
                "sha256": sha256(values.map(formatDouble).joined(separator: "\n"))
            ] as [String: Any]
        }
        return P05OperatorEvidence(
            pairWitnesses: witnesses,
            behaviorSignatures: behaviorSignatures,
            fixtureCaseCount: cases.count
        )
    }

    private static func discriminationCases() throws -> [P05DiscriminationCase] {
        let sidecars = try [0.0, .pi / 4.0, .pi / 2.0, 3.0 * .pi / 4.0].map(coherentSidecar)
        let points = [(1, 2), (4, 5), (7, 8)]
        var cases: [P05DiscriminationCase] = []
        for pattern in P05PatternKind.allCases {
            let plane = try patternedPlane(pattern)
            for route in ASHSpatialRouteV2.allCases {
                for policy in ASHSpatialCoordinatePolicyV2.allCases {
                    for boundary in ASHSpatialBoundaryModeV2.allCases {
                        for (orientationIndex, sidecar) in sidecars.enumerated() {
                            for point in points {
                                let identifier = [
                                    pattern.rawValue,
                                    route.rawValue,
                                    policy.rawValue,
                                    boundary.rawValue,
                                    "orientation_\(orientationIndex)",
                                    "point_\(point.0)_\(point.1)"
                                ].joined(separator: ":")
                                cases.append(P05DiscriminationCase(
                                    identifier: identifier,
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

    private static func evaluate(
        _ testCase: P05DiscriminationCase,
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

    private static func evaluate(
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

    private static func descriptorJSON(_ descriptor: ASHSpatialDescriptorV2) -> [String: Any] {
        [
            "id": Int(descriptor.id),
            "base_kernel": baseKernelName(descriptor.baseKernel),
            "support": supportName(descriptor.supportMode),
            "detail": detailName(descriptor.detailMode),
            "limiter": limiterName(descriptor.limiterMode)
        ]
    }

    private static func makeCoordinateComparisonData(
        planeDispatchEvidence: P05PlaneDispatchEvidence
    ) throws -> [String: Any] {
        let plane = try patternedPlane(.ramp)
        var routePolicyRecords: [[String: Any]] = []
        for route in ASHSpatialRouteV2.allCases {
            for policy in ASHSpatialCoordinatePolicyV2.allCases {
                var phases = Set<ASHSpatialPhaseV2>()
                for row in 0..<route.scaleNumerator {
                    for column in 0..<route.scaleNumerator {
                        phases.insert(try ASHSpatialOperatorBankV2.phase(
                            destinationColumn: column,
                            destinationRow: row,
                            plane: plane,
                            route: route,
                            policy: policy
                        ))
                    }
                }
                try require(phases.count == route.phasePairCount, "Unexpected phase cardinality")
                routePolicyRecords.append([
                    "route": route.rawValue,
                    "policy": policy.rawValue,
                    "expected_phase_pair_count": route.phasePairCount,
                    "observed_phase_pair_count": phases.count,
                    "phases": phases.sorted { phaseSortKey($0) < phaseSortKey($1) }.map(phaseJSON),
                    "pass": true
                ])
            }
        }

        var identityVectors: [[String: Any]] = []
        for policy in ASHSpatialCoordinatePolicyV2.allCases {
            for index in 0..<8 {
                let coordinate = try ASHSpatialOperatorBankV2.coordinate(
                    destinationIndex: index,
                    sourceExtent: 8,
                    destinationExtent: 8,
                    policy: policy
                )
                try require(coordinate.value == Double(index), "Identity coordinate mismatch")
                identityVectors.append([
                    "policy": policy.rawValue,
                    "index": index,
                    "numerator": Int(coordinate.numerator),
                    "denominator": Int(coordinate.denominator),
                    "value": coordinate.value,
                    "pass": true
                ])
            }
        }

        let descriptor = try ASHSpatialDescriptorV2(id: 0)
        let sidecar = try coherentSidecar(orientation: 0.0)
        var rampVectors: [[String: Any]] = []
        for route in ASHSpatialRouteV2.allCases {
            for policy in ASHSpatialCoordinatePolicyV2.allCases {
                let point = route == .direct2x ? (7, 9) : (5, 7)
                let result = try evaluate(
                    plane: plane,
                    column: point.0,
                    row: point.1,
                    route: route,
                    policy: policy,
                    descriptor: descriptor,
                    sidecar: sidecar,
                    boundary: .clamp
                )
                let expected = 0.15 + (0.70 * ((result.sourceX.value + result.sourceY.value) / 14.0))
                let error = abs(result.value - expected)
                try require(error <= tolerance, "Ramp reproduction failed")
                rampVectors.append([
                    "route": route.rawValue,
                    "policy": policy.rawValue,
                    "source_x": result.sourceX.value,
                    "source_y": result.sourceY.value,
                    "expected": expected,
                    "observed": result.value,
                    "absolute_error": error,
                    "pass": true
                ])
            }
        }

        let borderPlane = try ASHSpatialPlaneV2(
            width: 3,
            height: 3,
            samples: (0..<9).map { Double($0) / 8.0 }
        )
        let borderDescriptor = try ASHSpatialDescriptorV2(id: 3)
        var borderVectors: [[String: Any]] = []
        for boundary in ASHSpatialBoundaryModeV2.allCases {
            let result = try evaluate(
                plane: borderPlane,
                column: 0,
                row: 0,
                route: .direct2x,
                policy: .halfPixelCenter,
                descriptor: borderDescriptor,
                sidecar: try coherentSidecar(orientation: .pi / 2.0),
                boundary: boundary
            )
            try require(result.value.isFinite && (0.0...1.0).contains(result.value), "Border result invalid")
            borderVectors.append([
                "boundary": boundary.rawValue,
                "value": result.value,
                "contributing_sample_count": result.contributingSampleCount,
                "pass": true
            ])
        }
        return [
            "coordinate_policy_count": ASHSpatialCoordinatePolicyV2.allCases.count,
            "route_count": ASHSpatialRouteV2.allCases.count,
            "progressive_chroma_siting_count": ASHChromaSitingV2.allCases.count,
            "route_policy_records": routePolicyRecords,
            "luma_route_policy_records": planeDispatchEvidence.lumaRecords,
            "siting_route_policy_records": planeDispatchEvidence.chromaRecords,
            "siting_corrected_phase_cardinality_pass": true,
            "identity_vectors": identityVectors,
            "ramp_vectors": rampVectors,
            "border_vectors": borderVectors,
            "release_policy_selected": false,
            "comparison_status": "development_evidence_only"
        ]
    }

    private static func makeCPUReferenceEvidence() throws -> P05CPUReferenceEvidence {
        let channels: [(String, ClosedRange<Double>)] = [
            ("Y", 0.10...0.90),
            ("Cb", 0.15...0.85),
            ("Cr", 0.20...0.80)
        ]
        var vectors: [[String: Any]] = []
        var signatureLines: [String] = []
        for route in ASHSpatialRouteV2.allCases {
            for policy in ASHSpatialCoordinatePolicyV2.allCases {
                for (channel, legalRange) in channels {
                    let plane = try patternedPlane(.asymmetric, legalRange: legalRange)
                    for descriptor in ASHSpatialOperatorBankV2.descriptors {
                        let result = try evaluate(
                            plane: plane,
                            column: 5,
                            row: 7,
                            route: route,
                            policy: policy,
                            descriptor: descriptor,
                            sidecar: try coherentSidecar(orientation: .pi / 4.0),
                            boundary: .mirrorReflect101
                        )
                        try require(result.value.isFinite, "Nonfinite CPU reference result")
                        try require(legalRange.contains(result.value), "CPU reference legal range failure")
                        let record: [String: Any] = [
                            "route": route.rawValue,
                            "coordinate_policy": policy.rawValue,
                            "channel": channel,
                            "descriptor_id": Int(descriptor.id),
                            "destination": ["column": 5, "row": 7],
                            "source_x": rationalJSON(result.sourceX),
                            "source_y": rationalJSON(result.sourceY),
                            "phase": phaseJSON(result.phase),
                            "value": result.value,
                            "legal_minimum": legalRange.lowerBound,
                            "legal_maximum": legalRange.upperBound,
                            "source_aligned_sample_preserved": result.sourceAlignedSamplePreserved,
                            "contributing_sample_count": result.contributingSampleCount,
                            "diagnostics": diagnosticsJSON(result.diagnostics),
                            "pass": true
                        ]
                        vectors.append(record)
                        signatureLines.append([
                            route.rawValue,
                            policy.rawValue,
                            channel,
                            String(descriptor.id),
                            formatDouble(result.value),
                            String(result.sourceX.numerator),
                            String(result.sourceX.denominator),
                            String(result.sourceY.numerator),
                            String(result.sourceY.denominator)
                        ].joined(separator: "|"))
                    }
                }
            }
        }
        try require(vectors.count == 192, "CPU reference vector count is not 192")

        let sourcePlane = try patternedPlane(.asymmetric)
        let sourceSidecar = try coherentSidecar(orientation: .pi / 4.0)
        var sourceAlignedVectors: [[String: Any]] = []
        for route in ASHSpatialRouteV2.allCases {
            let point = route == .direct2x ? (6, 10) : (6, 9)
            for descriptor in ASHSpatialOperatorBankV2.descriptors {
                let result = try evaluate(
                    plane: sourcePlane,
                    column: point.0,
                    row: point.1,
                    route: route,
                    policy: .sourceAlignedRational,
                    descriptor: descriptor,
                    sidecar: sourceSidecar,
                    boundary: .mirrorReflect101
                )
                try require(result.sourceAlignedSamplePreserved, "Source-aligned sample was not preserved")
                let expected = sourcePlane.sample(
                    column: try requiredIntegral(result.sourceX),
                    row: try requiredIntegral(result.sourceY),
                    boundary: .mirrorReflect101
                )
                try require(result.value == expected, "Source-aligned sample changed")
                sourceAlignedVectors.append([
                    "route": route.rawValue,
                    "descriptor_id": Int(descriptor.id),
                    "destination": ["column": point.0, "row": point.1],
                    "source_x": rationalJSON(result.sourceX),
                    "source_y": rationalJSON(result.sourceY),
                    "expected": expected,
                    "observed": result.value,
                    "pass": true
                ])
            }
        }
        try require(sourceAlignedVectors.count == 32, "Source-aligned vector count is not 32")
        return P05CPUReferenceEvidence(
            vectors: vectors,
            sourceAlignedVectors: sourceAlignedVectors,
            signatureSHA256: sha256(signatureLines.joined(separator: "\n"))
        )
    }

    private static func makePlaneDispatchEvidence() throws -> P05PlaneDispatchEvidence {
        var lumaRecords: [[String: Any]] = []
        var chromaRecords: [[String: Any]] = []
        var lumaCount = 0
        var chromaCount = 0
        var neutralCount = 0
        var decodedCount = 0
        var failures = dispatchFailureCounters()

        for route in ASHSpatialRouteV2.allCases {
            for policy in ASHSpatialCoordinatePolicyV2.allCases {
                let audit = try auditPhaseGroup(
                    planeName: "luma",
                    route: route,
                    policy: policy,
                    chromaSiting: nil
                )
                lumaRecords.append(audit.record)
                lumaCount += audit.dispatchCount
                neutralCount += audit.neutralComparisonCount
                decodedCount += audit.decodedDispatchEvaluationCount
                mergeFailures(audit.failureCounters, into: &failures)
            }
        }
        for siting in ASHChromaSitingV2.allCases {
            for route in ASHSpatialRouteV2.allCases {
                for policy in ASHSpatialCoordinatePolicyV2.allCases {
                    let audit = try auditPhaseGroup(
                        planeName: "chroma",
                        route: route,
                        policy: policy,
                        chromaSiting: siting
                    )
                    chromaRecords.append(audit.record)
                    chromaCount += audit.dispatchCount
                    neutralCount += audit.neutralComparisonCount
                    decodedCount += audit.decodedDispatchEvaluationCount
                    mergeFailures(audit.failureCounters, into: &failures)
                }
            }
        }

        try require(lumaRecords.count == 4, "Luma route-policy cache count is not four")
        try require(chromaRecords.count == 24, "Chroma siting-route-policy cache count is not 24")
        try require(lumaCount == 6_656, "Luma dispatch count mismatch")
        try require(chromaCount == 39_936, "Chroma dispatch count mismatch")
        try require(neutralCount == 46_592, "Neutral comparison count mismatch")
        try require(decodedCount == 93_184, "Decoded dispatch evaluation count mismatch")
        try require(failures.values.reduce(0, +) == 0, "Per-plane decoded dispatch constraint failure")
        return P05PlaneDispatchEvidence(
            lumaRecords: lumaRecords,
            chromaRecords: chromaRecords,
            lumaDispatchCount: lumaCount,
            chromaDispatchCount: chromaCount,
            neutralComparisonCount: neutralCount,
            decodedDispatchEvaluationCount: decodedCount,
            failureCounters: failures
        )
    }

    private static func auditPhaseGroup(
        planeName: String,
        route: ASHSpatialRouteV2,
        policy: ASHSpatialCoordinatePolicyV2,
        chromaSiting: ASHChromaSitingV2?
    ) throws -> P05PhaseGroupAudit {
        let phases = try exactPhaseSet(
            route: route,
            policy: policy,
            chromaSiting: chromaSiting
        )
        let neutralState = try ASHState(payloadBits: Array(repeating: 0, count: ASHState.payloadBitCount))
        var failures = dispatchFailureCounters()
        var enabledDescriptors = Set<UInt8>()
        var neutralDescriptors = Set<UInt8>()
        var dispatchCount = 0
        var neutralComparisonCount = 0

        for phase in phases {
            let neutralReference = try ASHSpatialDevelopmentSelectorV2.dispatch(
                state: neutralState,
                phase: phase,
                stateInputEnabled: true
            )
            for raw in UInt16(0)..<UInt16(1 << ASHState.bitCount) {
                let state = try ASHState(rawValue: raw)
                guard state.hasValidIntegrity else { continue }
                let enabled = try ASHSpatialDevelopmentSelectorV2.dispatch(
                    state: state,
                    phase: phase,
                    stateInputEnabled: true
                )
                let disabled = try ASHSpatialDevelopmentSelectorV2.dispatch(
                    state: state,
                    phase: phase,
                    stateInputEnabled: false
                )
                mergeFailures(
                    dispatchFailures(enabled, sourceState: state, selectorState: state),
                    into: &failures
                )
                mergeFailures(
                    dispatchFailures(disabled, sourceState: state, selectorState: neutralState),
                    into: &failures
                )
                if disabled.primaryDecodedMessage != neutralReference.primaryDecodedMessage
                    || disabled.secondaryDecodedMessage != neutralReference.secondaryDecodedMessage
                    || disabled.margin != neutralReference.margin
                    || disabled.primaryWeight != neutralReference.primaryWeight
                    || disabled.secondaryWeight != neutralReference.secondaryWeight {
                    failures["neutral_phase_dispatch_mismatch", default: 0] += 1
                }
                dispatchCount += 1
                neutralComparisonCount += 1
                enabledDescriptors.insert(enabled.primaryDecodedMessage.rawValue)
                neutralDescriptors.insert(disabled.primaryDecodedMessage.rawValue)
            }
        }
        try require(phases.count == route.phasePairCount, "Corrected phase cardinality mismatch")
        return P05PhaseGroupAudit(
            record: [
                "plane": planeName,
                "route": route.rawValue,
                "policy": policy.rawValue,
                "chroma_siting": optionalString(chromaSiting?.rawValue),
                "expected_phase_pair_count": route.phasePairCount,
                "observed_phase_pair_count": phases.count,
                "phases": phases.map(phaseJSON),
                "valid_state_count": 256,
                "enabled_dispatch_count": dispatchCount,
                "neutral_comparison_count": neutralComparisonCount,
                "unique_enabled_primary_count": enabledDescriptors.count,
                "unique_neutral_primary_count": neutralDescriptors.count,
                "failure_count": failures.values.reduce(0, +),
                "pass": failures.values.reduce(0, +) == 0
            ],
            dispatchCount: dispatchCount,
            neutralComparisonCount: neutralComparisonCount,
            decodedDispatchEvaluationCount: dispatchCount * 2,
            failureCounters: failures
        )
    }

    private static func exactPhaseSet(
        route: ASHSpatialRouteV2,
        policy: ASHSpatialCoordinatePolicyV2,
        chromaSiting: ASHChromaSitingV2?
    ) throws -> [ASHSpatialPhaseV2] {
        let sourceExtent = chromaSiting == nil ? 8 : 4
        let destinationExtent = try route.destinationExtent(for: sourceExtent)
        var phases = Set<ASHSpatialPhaseV2>()
        for row in 0..<route.scaleNumerator {
            for column in 0..<route.scaleNumerator {
                let horizontal: ASHSpatialRationalCoordinateV2
                let vertical: ASHSpatialRationalCoordinateV2
                if let chromaSiting {
                    horizontal = try chromaSiting.sourceCoordinate(
                        destinationIndex: column,
                        sourceExtent: sourceExtent,
                        destinationExtent: destinationExtent,
                        policy: policy,
                        axis: .horizontal
                    )
                    vertical = try chromaSiting.sourceCoordinate(
                        destinationIndex: row,
                        sourceExtent: sourceExtent,
                        destinationExtent: destinationExtent,
                        policy: policy,
                        axis: .vertical
                    )
                } else {
                    horizontal = try ASHSpatialOperatorBankV2.coordinate(
                        destinationIndex: column,
                        sourceExtent: sourceExtent,
                        destinationExtent: destinationExtent,
                        policy: policy
                    )
                    vertical = try ASHSpatialOperatorBankV2.coordinate(
                        destinationIndex: row,
                        sourceExtent: sourceExtent,
                        destinationExtent: destinationExtent,
                        policy: policy
                    )
                }
                phases.insert(ASHSpatialPhaseV2(
                    horizontal: ASHSpatialPhaseComponentV2(coordinate: horizontal),
                    vertical: ASHSpatialPhaseComponentV2(coordinate: vertical)
                ))
            }
        }
        return phases.sorted { phaseSortKey($0) < phaseSortKey($1) }
    }

    private static func dispatchFailureCounters() -> [String: Int] {
        [
            "source_anchor_mismatch": 0,
            "selector_state_mismatch": 0,
            "primary_affine_decode_not_exact": 0,
            "secondary_affine_decode_not_exact": 0,
            "secondary_presence_mismatch": 0,
            "candidate_bound_exceeded": 0,
            "primary_secondary_collision": 0,
            "weight_sum_mismatch": 0,
            "anisotropy_semantic_mismatch": 0,
            "detail_semantic_mismatch": 0,
            "limiter_semantic_mismatch": 0,
            "secondary_non_kernel_axis_mismatch": 0,
            "neutral_phase_dispatch_mismatch": 0
        ]
    }

    private static func dispatchFailures(
        _ dispatch: ASHSpatialDispatchV2,
        sourceState: ASHState,
        selectorState: ASHState
    ) -> [String: Int] {
        var failures = dispatchFailureCounters()
        if dispatch.sourceState != sourceState { failures["source_anchor_mismatch", default: 0] += 1 }
        if dispatch.selectorState != selectorState { failures["selector_state_mismatch", default: 0] += 1 }
        let primaryDecode = ASHCode.decodeAffine(
            received: dispatch.primaryAffineState,
            anchor: dispatch.sourceState
        )
        if primaryDecode.status != .exact
            || primaryDecode.messageBits != dispatch.primaryDecodedMessage.bits {
            failures["primary_affine_decode_not_exact", default: 0] += 1
        }
        switch (dispatch.secondaryDecodedMessage, dispatch.secondaryAffineState) {
        case let (secondary?, affine?):
            let decode = ASHCode.decodeAffine(received: affine, anchor: dispatch.sourceState)
            if decode.status != .exact || decode.messageBits != secondary.bits {
                failures["secondary_affine_decode_not_exact", default: 0] += 1
            }
        case (nil, nil):
            break
        default:
            failures["secondary_presence_mismatch", default: 0] += 1
        }
        if dispatch.operatorEvaluationCount > 2 { failures["candidate_bound_exceeded", default: 0] += 1 }
        if dispatch.secondaryDecodedMessage == dispatch.primaryDecodedMessage {
            failures["primary_secondary_collision", default: 0] += 1
        }
        if abs((dispatch.primaryWeight + dispatch.secondaryWeight) - 1.0) > 1.0e-12 {
            failures["weight_sum_mismatch", default: 0] += 1
        }
        let expectedAnisotropy = selectorState.bit(coordinate: 3) & selectorState.bit(coordinate: 4)
        let expectedDetail = selectorState.bit(coordinate: 3)
            & selectorState.bit(coordinate: 5)
            & (1 - selectorState.bit(coordinate: 6))
        let expectedLimiter = selectorState.bit(coordinate: 8)
            & (1 - selectorState.bit(coordinate: 6))
        let raw = dispatch.primaryDecodedMessage.rawValue
        if Int((raw >> 1) & 1) != expectedAnisotropy {
            failures["anisotropy_semantic_mismatch", default: 0] += 1
        }
        if Int((raw >> 2) & 1) != expectedDetail {
            failures["detail_semantic_mismatch", default: 0] += 1
        }
        if Int((raw >> 3) & 1) != expectedLimiter {
            failures["limiter_semantic_mismatch", default: 0] += 1
        }
        if let secondary = dispatch.secondaryDecodedMessage,
           (secondary.rawValue & 0b1110) != (raw & 0b1110) {
            failures["secondary_non_kernel_axis_mismatch", default: 0] += 1
        }
        return failures
    }

    private static func mergeFailures(
        _ additions: [String: Int],
        into total: inout [String: Int]
    ) {
        for (name, count) in additions {
            total[name, default: 0] += count
        }
    }

    private static func makeStateCausalityData(
        configuration: ASHVideoAnalyzerV2DevelopmentConfiguration,
        pipelineEvidence: P05PipelineEvidence,
        planeDispatchEvidence: P05PlaneDispatchEvidence
    ) throws -> [String: Any] {
        let fixedPhase = try ASHSpatialPhaseV2.sourceAlignedDevelopment(
            horizontalIndex: 1,
            verticalIndex: 0,
            route: .direct2x
        )
        var stateRecords: [[String: Any]] = []
        var fixedPrimary = Set<UInt8>()
        for payloadRaw in 0..<256 {
            let payload = (0..<ASHState.payloadBitCount).map {
                (payloadRaw >> (ASHState.payloadBitCount - 1 - $0)) & 1
            }
            let state = try ASHState(payloadBits: payload)
            let dispatch = try ASHSpatialDevelopmentSelectorV2.dispatch(state: state, phase: fixedPhase)
            let decoded = ASHCode.decodeAffine(received: dispatch.primaryAffineState, anchor: state)
            try require(decoded.status == .exact, "Primary affine dispatch did not recover exactly")
            try require(dispatch.operatorEvaluationCount <= 2, "More than two descriptor evaluations")
            let decodedMessage = try requiredDecodedMessage(decoded)
            try require(
                decodedMessage == dispatch.primaryDecodedMessage,
                "Stored primary differs from affine decode"
            )
            fixedPrimary.insert(decodedMessage.rawValue)
            stateRecords.append([
                "payload_ordinal": payloadRaw,
                "payload_bits": payload,
                "state_raw": Int(state.rawValue),
                "integrity_valid": state.hasValidIntegrity,
                "primary_descriptor": Int(decodedMessage.rawValue),
                "primary_decoded_message": Int(decodedMessage.rawValue),
                "secondary_descriptor": optionalInt(dispatch.secondaryDecodedMessage?.rawValue),
                "operator_evaluation_count": dispatch.operatorEvaluationCount,
                "margin": dispatch.margin,
                "primary_affine_raw": Int(dispatch.primaryAffineState.rawValue),
                "decode_status": decodeStatusName(decoded.status)
            ])
        }
        try require(stateRecords.count == 256, "Valid state evidence count is not 256")
        try require(fixedPrimary.count > 1, "Dispatch is constant across valid states")

        var exhaustiveDispatchCount = 0
        var exhaustiveDescriptors = Set<UInt8>()
        var maximumEvaluations = 0
        var constraintFailures = [
            "invalid_source_integrity": 0,
            "affine_decode_not_exact": 0,
            "decoded_descriptor_out_of_range": 0,
            "candidate_bound_exceeded": 0,
            "primary_secondary_collision": 0,
            "weight_sum_mismatch": 0,
            "selector_state_mismatch": 0,
            "primary_anisotropy_semantic_mismatch": 0,
            "primary_detail_semantic_mismatch": 0,
            "primary_limiter_semantic_mismatch": 0,
            "secondary_non_kernel_axis_mismatch": 0
        ]
        for route in ASHSpatialRouteV2.allCases {
            for vertical in 0..<route.scaleNumerator {
                for horizontal in 0..<route.scaleNumerator {
                    let phase = try ASHSpatialPhaseV2.sourceAlignedDevelopment(
                        horizontalIndex: horizontal,
                        verticalIndex: vertical,
                        route: route
                    )
                    for raw in UInt16(0)..<UInt16(1 << ASHState.bitCount) {
                        let state = try ASHState(rawValue: raw)
                        guard state.hasValidIntegrity else { continue }
                        let dispatch = try ASHSpatialDevelopmentSelectorV2.dispatch(state: state, phase: phase)
                        let decoded = ASHCode.decodeAffine(
                            received: dispatch.primaryAffineState,
                            anchor: dispatch.sourceState
                        )
                        if !state.hasValidIntegrity {
                            constraintFailures["invalid_source_integrity", default: 0] += 1
                        }
                        if decoded.status != .exact {
                            constraintFailures["affine_decode_not_exact", default: 0] += 1
                        }
                        let decodedMessage = try requiredDecodedMessage(decoded)
                        if decodedMessage.rawValue >= 16 {
                            constraintFailures["decoded_descriptor_out_of_range", default: 0] += 1
                        }
                        if dispatch.operatorEvaluationCount > 2 {
                            constraintFailures["candidate_bound_exceeded", default: 0] += 1
                        }
                        if dispatch.secondaryDecodedMessage == dispatch.primaryDecodedMessage {
                            constraintFailures["primary_secondary_collision", default: 0] += 1
                        }
                        if abs((dispatch.primaryWeight + dispatch.secondaryWeight) - 1.0) > 1.0e-12 {
                            constraintFailures["weight_sum_mismatch", default: 0] += 1
                        }
                        if dispatch.selectorState != state {
                            constraintFailures["selector_state_mismatch", default: 0] += 1
                        }
                        let edgePresent = state.bit(coordinate: 3)
                        let coherent = state.bit(coordinate: 4)
                        let texture = state.bit(coordinate: 5)
                        let risk = state.bit(coordinate: 6)
                        let chromaAligned = state.bit(coordinate: 8)
                        let expectedAnisotropy = edgePresent & coherent
                        let expectedDetail = edgePresent & texture & (1 - risk)
                        let expectedLimiter = chromaAligned & (1 - risk)
                        if Int((decodedMessage.rawValue >> 1) & 1) != expectedAnisotropy {
                            constraintFailures["primary_anisotropy_semantic_mismatch", default: 0] += 1
                        }
                        if Int((decodedMessage.rawValue >> 2) & 1) != expectedDetail {
                            constraintFailures["primary_detail_semantic_mismatch", default: 0] += 1
                        }
                        if Int((decodedMessage.rawValue >> 3) & 1) != expectedLimiter {
                            constraintFailures["primary_limiter_semantic_mismatch", default: 0] += 1
                        }
                        if let secondary = dispatch.secondaryDecodedMessage,
                           (secondary.rawValue & 0b1110) != (decodedMessage.rawValue & 0b1110) {
                            constraintFailures["secondary_non_kernel_axis_mismatch", default: 0] += 1
                        }
                        exhaustiveDispatchCount += 1
                        exhaustiveDescriptors.insert(decodedMessage.rawValue)
                        maximumEvaluations = max(maximumEvaluations, dispatch.operatorEvaluationCount)
                    }
                }
            }
        }
        try require(exhaustiveDispatchCount == 256 * (4 + 9), "Exhaustive dispatch count mismatch")
        try require(exhaustiveDescriptors.count == 16, "Exhaustive dispatch did not cover 16 descriptors")
        let constraintFailureCount = constraintFailures.values.reduce(0, +)
        try require(constraintFailureCount == 0, "Exhaustive semantic constraint failure")

        let firstFrame = try firstFrameRecords(configuration: configuration)
        let firstFrameUnique = Set(firstFrame.compactMap { $0["primary_decoded_message"] as? Int })
        try require(firstFrameUnique.count > 1, "First-frame primary descriptor is universal")
        try require(pipelineEvidence.maximumAbsoluteDelta > tolerance, "State-disabled reconstructed output did not change")

        return [
            "valid_state_count": stateRecords.count,
            "state_dispatch_records": stateRecords,
            "fixed_phase": phaseJSON(fixedPhase),
            "unique_primary_descriptor_count": fixedPrimary.count,
            "unique_primary_descriptors": fixedPrimary.sorted().map(Int.init),
            "exhaustive_route_phase_dispatch_count": exhaustiveDispatchCount,
            "exhaustive_primary_descriptor_count": exhaustiveDescriptors.count,
            "maximum_operator_evaluations": maximumEvaluations,
            "hard_semantic_constraint_results": [
                "checked_dispatch_count": exhaustiveDispatchCount,
                "failure_count": constraintFailureCount,
                "failures_by_constraint": constraintFailures,
                "pass": true
            ],
            "per_plane_dispatch_results": [
                "luma_cache_record_count": planeDispatchEvidence.lumaRecords.count,
                "chroma_cache_record_count": planeDispatchEvidence.chromaRecords.count,
                "progressive_chroma_siting_count": ASHChromaSitingV2.allCases.count,
                "luma_enabled_dispatch_count": planeDispatchEvidence.lumaDispatchCount,
                "chroma_enabled_dispatch_count": planeDispatchEvidence.chromaDispatchCount,
                "total_enabled_dispatch_count": planeDispatchEvidence.lumaDispatchCount
                    + planeDispatchEvidence.chromaDispatchCount,
                "decoded_dispatch_evaluation_count": planeDispatchEvidence.decodedDispatchEvaluationCount,
                "neutral_phase_comparison_count": planeDispatchEvidence.neutralComparisonCount,
                "failure_count": planeDispatchEvidence.failureCounters.values.reduce(0, +),
                "failures_by_constraint": planeDispatchEvidence.failureCounters,
                "pass": true
            ],
            "neutral_state_phase_preserving_ablation": [
                "neutral_state_raw": 0,
                "source_anchor_preserved": true,
                "selector_state_neutral": true,
                "exact_plane_phase_reused": true,
                "comparison_count": planeDispatchEvidence.neutralComparisonCount,
                "mismatch_count": planeDispatchEvidence.failureCounters["neutral_phase_dispatch_mismatch", default: 0],
                "pass": true
            ],
            "first_frame_fixture_count": firstFrame.count,
            "first_frame_unique_primary_count": firstFrameUnique.count,
            "first_frame_records": firstFrame,
            "state_disabled_control": [
                "route": pipelineEvidence.enabled.summary.route.rawValue,
                "coordinate_policy": pipelineEvidence.enabled.summary.coordinatePolicy.rawValue,
                "same_source_pixels": true,
                "same_phase_context": true,
                "input_sha256": pipelineEvidence.inputSignatureSHA256,
                "state_enabled": true,
                "state_disabled": true,
                "enabled_run_state_input_enabled": pipelineEvidence.enabled.summary.stateInputEnabled,
                "disabled_run_state_input_enabled": pipelineEvidence.disabled.summary.stateInputEnabled,
                "enabled_output_sha256": pipelineEvidence.enabledSignatureSHA256,
                "disabled_output_sha256": pipelineEvidence.disabledSignatureSHA256,
                "maximum_absolute_delta": pipelineEvidence.maximumAbsoluteDelta,
                "enabled_operator_histogram": integerKeyDictionary(pipelineEvidence.enabled.summary.operatorHistogram),
                "disabled_operator_histogram": integerKeyDictionary(pipelineEvidence.disabled.summary.operatorHistogram),
                "progressive_chroma_siting_count": ASHChromaSitingV2.allCases.count,
                "per_plane_ablation_count": pipelineEvidence.perPlaneAblations.count,
                "per_plane_ablations": pipelineEvidence.perPlaneAblations,
                "pass": true
            ]
        ]
    }

    private static func firstFrameRecords(
        configuration: ASHVideoAnalyzerV2DevelopmentConfiguration
    ) throws -> [[String: Any]] {
        let names = [
            "flat",
            "horizontal_tangent",
            "positive_diagonal_tangent",
            "vertical_tangent",
            "negative_diagonal_tangent",
            "near_nyquist",
            "impulse"
        ]
        let phase = try ASHSpatialPhaseV2.sourceAlignedDevelopment(
            horizontalIndex: 1,
            verticalIndex: 1,
            route: .direct3Over2
        )
        return try names.map { name in
            let analysis = try analyzeContent(name, configuration: configuration)
            let dispatch = try ASHSpatialDevelopmentSelectorV2.dispatch(
                state: analysis.state,
                phase: phase
            )
            let decoded = ASHCode.decodeAffine(
                received: dispatch.primaryAffineState,
                anchor: dispatch.sourceState
            )
            let decodedMessage = try requiredDecodedMessage(decoded)
            try require(
                decodedMessage == dispatch.primaryDecodedMessage,
                "First-frame stored primary differs from affine decode"
            )
            return [
                "content_class": name,
                "history_present": false,
                "state_raw": Int(analysis.state.rawValue),
                "state_bits": analysis.state.bits,
                "orientation_sector": analysis.sidecar.orientationSector,
                "normalized_gradient_magnitude": analysis.sidecar.normalizedGradientMagnitude,
                "structure_coherence": analysis.sidecar.structureCoherence,
                "texture_energy": analysis.sidecar.textureEnergy,
                "risk_proxy": analysis.sidecar.riskProxy,
                "primary_descriptor": Int(decodedMessage.rawValue),
                "primary_decoded_message": Int(decodedMessage.rawValue),
                "primary_affine_raw": Int(dispatch.primaryAffineState.rawValue),
                "decode_status": decodeStatusName(decoded.status),
                "secondary_descriptor": optionalInt(dispatch.secondaryDecodedMessage?.rawValue),
                "operator_evaluation_count": dispatch.operatorEvaluationCount
            ]
        }
    }

    private static func makePipelineEvidence(
        configuration: ASHVideoAnalyzerV2DevelopmentConfiguration
    ) throws -> P05PipelineEvidence {
        let luma = try pipelinePlane(width: 8, height: 8, channel: "Y")
        let cb = try pipelinePlane(width: 4, height: 4, channel: "Cb")
        let cr = try pipelinePlane(width: 4, height: 4, channel: "Cr")
        var referenceEnabled: ASHSpatialReferenceOutputV2?
        var referenceDisabled: ASHSpatialReferenceOutputV2?
        var ablations: [[String: Any]] = []
        for siting in ASHChromaSitingV2.allCases {
            for route in ASHSpatialRouteV2.allCases {
                for policy in ASHSpatialCoordinatePolicyV2.allCases {
                    let runtime = runtimeConfiguration(policy: policy)
                    func input(_ stateInputEnabled: Bool) -> ASHSpatialReferenceInputV2 {
                        ASHSpatialReferenceInputV2(
                            luma: luma,
                            cb: cb,
                            cr: cr,
                            chromaSiting: siting,
                            route: route,
                            runtimeConfiguration: runtime,
                            analyzerConfiguration: configuration,
                            operatorParameters: .p05DevelopmentOnly,
                            stateInputEnabled: stateInputEnabled
                        )
                    }
                    let enabled = try ASHSpatialReferencePipelineV2.process(input(true))
                    let disabled = try ASHSpatialReferencePipelineV2.process(input(false))
                    try require(!enabled.summary.nearestExpansionUsed, "Production reference reported nearest expansion")
                    try require(!disabled.summary.nearestExpansionUsed, "Disabled control reported nearest expansion")
                    try require(enabled.summary.runtimeTreeGenerationCount == 0, "Runtime tree generation was nonzero")
                    try require(enabled.summary.maxOperatorEvaluations <= 2, "Pipeline exceeded two descriptor evaluations")
                    try require(enabled.summary.stateInputEnabled, "Enabled control did not retain state input")
                    try require(!disabled.summary.stateInputEnabled, "Disabled control retained state input")
                    try require(enabled.summary.stateHistogram == disabled.summary.stateHistogram, "Ablation changed analysis state")
                    try require(enabled.summary.route == route && disabled.summary.route == route, "Ablation route mismatch")
                    try require(enabled.summary.coordinatePolicy == policy, "Ablation coordinate policy mismatch")
                    try require(enabled.summary.chromaSiting == siting, "Ablation chroma siting mismatch")

                    let lumaDelta = maximumDelta(enabled.luma.normalizedSamples, disabled.luma.normalizedSamples)
                    let cbDelta = maximumDelta(enabled.cb.normalizedSamples, disabled.cb.normalizedSamples)
                    let crDelta = maximumDelta(enabled.cr.normalizedSamples, disabled.cr.normalizedSamples)
                    let overallDelta = max(lumaDelta, max(cbDelta, crDelta))
                    try require(overallDelta > tolerance, "State ablation produced no sample delta")
                    let enabledValues = enabled.luma.normalizedSamples
                        + enabled.cb.normalizedSamples
                        + enabled.cr.normalizedSamples
                    let disabledValues = disabled.luma.normalizedSamples
                        + disabled.cb.normalizedSamples
                        + disabled.cr.normalizedSamples
                    ablations.append([
                        "route": route.rawValue,
                        "coordinate_policy": policy.rawValue,
                        "chroma_siting": siting.rawValue,
                        "luma_maximum_absolute_delta": lumaDelta,
                        "cb_maximum_absolute_delta": cbDelta,
                        "cr_maximum_absolute_delta": crDelta,
                        "overall_maximum_absolute_delta": overallDelta,
                        "analysis_state_histogram_unchanged": true,
                        "source_pixels_unchanged": true,
                        "plane_phase_context_unchanged": true,
                        "enabled_output_sha256": sha256(enabledValues.map(formatDouble).joined(separator: "\n")),
                        "disabled_output_sha256": sha256(disabledValues.map(formatDouble).joined(separator: "\n")),
                        "nearest_expansion_used": false,
                        "maximum_operator_evaluations": enabled.summary.maxOperatorEvaluations,
                        "pass": true
                    ])
                    if siting == .center,
                       route == .direct2x,
                       policy == .sourceAlignedRational {
                        referenceEnabled = enabled
                        referenceDisabled = disabled
                    }
                }
            }
        }
        guard let enabled = referenceEnabled, let disabled = referenceDisabled else {
            throw P05EvidenceError.failed("Missing reference ablation run")
        }
        try require(ablations.count == 24, "Per-plane ablation count is not 24")
        let enabledValues = enabled.luma.normalizedSamples + enabled.cb.normalizedSamples + enabled.cr.normalizedSamples
        let disabledValues = disabled.luma.normalizedSamples + disabled.cb.normalizedSamples + disabled.cr.normalizedSamples
        let maximumDelta = maximumDelta(enabledValues, disabledValues)
        return P05PipelineEvidence(
            enabled: enabled,
            disabled: disabled,
            maximumAbsoluteDelta: maximumDelta,
            inputSignatureSHA256: sha256Bytes(luma.codes + cb.codes + cr.codes),
            enabledSignatureSHA256: sha256(enabledValues.map(formatDouble).joined(separator: "\n")),
            disabledSignatureSHA256: sha256(disabledValues.map(formatDouble).joined(separator: "\n")),
            perPlaneAblations: ablations
        )
    }

    private static func runtimeConfiguration(
        policy: ASHSpatialCoordinatePolicyV2
    ) -> ASHSpatialRuntimeConfigurationV2 {
        let base = ASHSpatialRuntimeConfigurationV2.developmentP05
        return ASHSpatialRuntimeConfigurationV2(
            status: base.status,
            mappingSchemaVersion: base.mappingSchemaVersion,
            mappingSHA256: base.mappingSHA256,
            operatorBankSchemaVersion: base.operatorBankSchemaVersion,
            operatorBankSHA256: base.operatorBankSHA256,
            coordinatePolicy: policy,
            boundaryMode: base.boundaryMode,
            analysisGrid: base.analysisGrid,
            chromaSitingRule: base.chromaSitingRule,
            selectorVersion: base.selectorVersion
        )
    }

    private static func maximumDelta(_ first: [Double], _ second: [Double]) -> Double {
        precondition(first.count == second.count)
        return zip(first, second).map { abs($0 - $1) }.max() ?? 0.0
    }

    private static func cpuReferenceTests(
        pipelineEvidence: P05PipelineEvidence
    ) -> [[String: Any]] {
        [
            ["id": "identity_coordinates", "status": "pass"],
            ["id": "direct_2x_four_phase_pairs", "status": "pass", "observed": 4],
            ["id": "direct_3_over_2_nine_phase_pairs", "status": "pass", "observed": 9],
            ["id": "linear_ramps", "status": "pass"],
            ["id": "impulses", "status": "pass"],
            ["id": "explicit_borders", "status": "pass"],
            ["id": "source_aligned_samples", "status": "pass", "observed": 32],
            ["id": "all_descriptors", "status": "pass", "observed": 16],
            ["id": "normalized_y_cb_cr_legal_ranges", "status": "pass", "observed": 3],
            ["id": "nearest_not_reconstruction_substrate", "status": "pass", "observed": pipelineEvidence.enabled.summary.nearestExpansionUsed],
            ["id": "runtime_tree_generation_zero", "status": "pass", "observed": pipelineEvidence.enabled.summary.runtimeTreeGenerationCount],
            ["id": "candidate_bound", "status": "pass", "observed": pipelineEvidence.enabled.summary.maxOperatorEvaluations]
        ]
    }

    private static func patternedPlane(
        _ kind: P05PatternKind,
        legalRange: ClosedRange<Double> = 0.0...1.0
    ) throws -> ASHSpatialPlaneV2 {
        let values = (0..<8).flatMap { row in
            (0..<8).map { column -> Double in
                switch kind {
                case .constant:
                    return 0.42
                case .ramp:
                    return 0.15 + (0.70 * (Double(row + column) / 14.0))
                case .impulse:
                    return row == 4 && column == 4 ? 0.75 : 0.25
                case .horizontalEdge:
                    return row < 4 ? 0.25 : 0.75
                case .verticalEdge:
                    return column < 4 ? 0.25 : 0.75
                case .positiveDiagonal:
                    return column >= row ? 0.75 : 0.25
                case .negativeDiagonal:
                    return column + row >= 7 ? 0.75 : 0.25
                case .corner:
                    return row >= 4 && column >= 4 ? 0.75 : 0.25
                case .thinLine:
                    return column == 4 ? 0.75 : 0.25
                case .nearNyquist:
                    return (row + column).isMultiple(of: 2) ? 0.30 : 0.70
                case .asymmetric:
                    let residue = ((row * 17) + (column * 29) + (row * column * 7)) % 101
                    return 0.05 + (0.90 * (Double(residue) / 100.0))
                }
            }
        }
        return try ASHSpatialPlaneV2(
            width: 8,
            height: 8,
            samples: values,
            legalRange: legalRange
        )
    }

    private static func coherentSidecar(orientation: Double) throws -> ASHSpatialSidecarV2 {
        try ASHSpatialSidecarV2(
            orientationRadians: orientation,
            normalizedMagnitude: 0.90,
            coherence: 0.92,
            risk: 0.10,
            chromaAlignment: 0.95,
            localMinimum: 0.05,
            localMaximum: 0.95
        )
    }

    private static func analyzeContent(
        _ name: String,
        configuration: ASHVideoAnalyzerV2DevelopmentConfiguration
    ) throws -> ASHVideoAnalyzerV2Result {
        let center = 12
        let plane = try ASHVideoAnalyzerV2CodePlane(
            width: 25,
            height: 25,
            bytesPerRow: 25,
            codes: (0..<25).flatMap { y in
                (0..<25).map { x -> UInt8 in
                    switch name {
                    case "flat":
                        return 128
                    case "horizontal_tangent":
                        return y < center ? 0 : 255
                    case "positive_diagonal_tangent":
                        return y < x ? 0 : 255
                    case "vertical_tangent":
                        return x < center ? 0 : 255
                    case "negative_diagonal_tangent":
                        return x + y < center * 2 ? 0 : 255
                    case "near_nyquist":
                        return (x + y).isMultiple(of: 2) ? 64 : 192
                    case "impulse":
                        return x == center && y == center ? 255 : 64
                    default:
                        return 0
                    }
                }
            },
            range: .full
        )
        return try ASHVideoAnalyzerV2.analyze(
            ASHVideoAnalyzerV2Input(
                luma: plane,
                location: ASHVideoAnalyzerV2Location(x: center, y: center),
                chroma: nil,
                boundary: .reflect101,
                history: nil,
                validationTemporalEvidence: nil
            ),
            configuration: configuration
        )
    }

    private static func pipelinePlane(
        width: Int,
        height: Int,
        channel: String
    ) throws -> ASHVideoAnalyzerV2CodePlane {
        let codes = (0..<height).flatMap { row in
            (0..<width).map { column -> UInt8 in
                let residue: Int
                switch channel {
                case "Y":
                    residue = ((row * 41) + (column * 67) + (row * column * 13)) % 220
                    return UInt8(16 + residue)
                case "Cb":
                    residue = ((row * 59) + (column * 31) + 47) % 225
                    return UInt8(16 + residue)
                default:
                    residue = ((row * 23) + (column * 73) + 89) % 225
                    return UInt8(16 + residue)
                }
            }
        }
        return try ASHVideoAnalyzerV2CodePlane(
            width: width,
            height: height,
            bytesPerRow: width,
            codes: codes,
            range: .video
        )
    }

    private static func diagnosticsJSON(
        _ diagnostics: ASHSpatialConstraintDiagnosticsV2
    ) -> [String: Any] {
        [
            "support_minimum": diagnostics.supportMinimum,
            "support_maximum": diagnostics.supportMaximum,
            "pre_limiter_value": diagnostics.preLimiterValue,
            "limiter_lower_bound": diagnostics.limiterLowerBound,
            "limiter_upper_bound": diagnostics.limiterUpperBound,
            "post_limiter_value": diagnostics.postLimiterValue,
            "limiter_mode": limiterName(diagnostics.limiterMode),
            "anisotropy_used": diagnostics.anisotropyUsed,
            "effective_detail_gain": diagnostics.effectiveDetailGain,
            "detail_applied": diagnostics.detailApplied
        ]
    }

    private static func rationalJSON(
        _ coordinate: ASHSpatialRationalCoordinateV2
    ) -> [String: Any] {
        [
            "numerator": Int(coordinate.numerator),
            "denominator": Int(coordinate.denominator),
            "value": coordinate.value,
            "is_integral": coordinate.isIntegral
        ]
    }

    private static func phaseJSON(_ phase: ASHSpatialPhaseV2) -> [String: Any] {
        [
            "horizontal": [
                "numerator": Int(phase.horizontal.numerator),
                "denominator": Int(phase.horizontal.denominator)
            ],
            "vertical": [
                "numerator": Int(phase.vertical.numerator),
                "denominator": Int(phase.vertical.denominator)
            ]
        ]
    }

    private static func phaseSortKey(_ phase: ASHSpatialPhaseV2) -> String {
        [
            String(format: "%020lld", phase.horizontal.numerator),
            String(format: "%020lld", phase.horizontal.denominator),
            String(format: "%020lld", phase.vertical.numerator),
            String(format: "%020lld", phase.vertical.denominator)
        ].joined(separator: ":")
    }

    private static func baseKernelName(_ value: ASHSpatialBaseKernelV2) -> String {
        switch value {
        case .keysCubicAMinusHalf: "keys_cubic_a_minus_0_5"
        case .lanczos3: "lanczos3"
        }
    }

    private static func supportName(_ value: ASHSpatialSupportModeV2) -> String {
        switch value {
        case .isotropic: "isotropic"
        case .structureTensorAnisotropic: "structure_tensor_anisotropic"
        }
    }

    private static func detailName(_ value: ASHSpatialDetailModeV2) -> String {
        switch value {
        case .conservative: "conservative"
        case .controlledPositive: "controlled_positive_detail"
        }
    }

    private static func limiterName(_ value: ASHSpatialLimiterModeV2) -> String {
        switch value {
        case .strictNeighborhoodRange: "strict_neighborhood_range"
        case .calibratedRelaxedRange: "calibrated_relaxed_range"
        }
    }

    private static func decodeStatusName(_ status: ASHDecodeStatus) -> String {
        switch status {
        case .exact: "exact"
        case .corrected: "corrected"
        case .uncorrectable: "uncorrectable"
        }
    }

    private static func requiredIntegral(
        _ coordinate: ASHSpatialRationalCoordinateV2
    ) throws -> Int {
        guard let value = coordinate.integralValue else {
            throw P05EvidenceError.failed("Expected an integral source coordinate")
        }
        return value
    }

    private static func requiredDecodedMessage(_ result: ASHDecodeResult) throws -> ASHMessage {
        guard result.status == .exact,
              let bits = result.messageBits else {
            throw P05EvidenceError.failed("Expected exact affine message recovery")
        }
        return try ASHMessage(bits: bits)
    }

    private static func optionalInt<T: BinaryInteger>(_ value: T?) -> Any {
        value.map { Int($0) } ?? NSNull()
    }

    private static func optionalString(_ value: String?) -> Any {
        guard let value else { return NSNull() }
        return value
    }

    private static func configurationDigest(suffix: String) throws -> P05EvidenceFileDigest {
        guard let record = P05EvidenceInputDigests.configurationFiles.first(where: {
            $0.path.hasSuffix(suffix)
        }) else {
            throw P05EvidenceError.failed("Missing configuration digest: \(suffix)")
        }
        return record
    }

    private static func integerKeyDictionary<T: BinaryInteger>(
        _ input: [T: Int]
    ) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: input.map { (String(Int($0.key)), $0.value) })
    }

    private static func moduloPi(_ angle: Double) -> Double {
        var reduced = angle.truncatingRemainder(dividingBy: .pi)
        if reduced < 0.0 { reduced += .pi }
        return reduced
    }

    private static func angularDistanceModuloPi(_ first: Double, _ second: Double) -> Double {
        let distance = abs(moduloPi(first) - moduloPi(second))
        return min(distance, .pi - distance)
    }

    private static func formatDouble(_ value: Double) -> String {
        String(format: "%.17e", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256Bytes(_ bytes: [UInt8]) -> String {
        SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw P05EvidenceError.failed(message) }
    }
}

// swiftlint:enable file_length type_body_length function_body_length
