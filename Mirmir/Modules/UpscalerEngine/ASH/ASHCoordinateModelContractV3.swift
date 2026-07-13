import CryptoKit
import Foundation

enum ASHCoordinateModelRouteV3: String, CaseIterable, Equatable, Sendable {
    case direct2x = "direct_2x"
    case direct3Over2 = "direct_3_over_2"
}

enum ASHCoordinateModelPolicyV3: String, CaseIterable, Equatable, Sendable {
    case halfPixelCenter = "half_pixel_center"
    case sourceAlignedRational = "source_aligned_rational"
}

enum ASHCoordinateModelContractV3Error: Error, Equatable, Sendable {
    case hashMismatch
    case nonCanonicalEncoding
    case fieldSetMismatch
    case invalidContract

    var machineCode: String {
        switch self {
        case .hashMismatch: "coordinate_model_contract_hash_mismatch"
        case .nonCanonicalEncoding: "coordinate_model_contract_noncanonical_encoding"
        case .fieldSetMismatch: "coordinate_model_contract_field_set_mismatch"
        case .invalidContract: "coordinate_model_contract_invalid"
        }
    }
}

struct ASHCoordinateModelRationalV3: Equatable, Sendable {
    let numerator: Int64
    let denominator: Int64

    fileprivate var canonicalValue: ASHLUTStrictJSONValueV2 {
        .object([
            "denominator": .integer(denominator),
            "numerator": .integer(numerator)
        ])
    }
}

struct ASHCoordinateModelAxisOracleV3: Equatable, Sendable {
    let horizontal: [ASHCoordinateModelRationalV3]
    let vertical: [ASHCoordinateModelRationalV3]

    fileprivate var canonicalValue: ASHLUTStrictJSONValueV2 {
        .object([
            "horizontal": .array(horizontal.map(\.canonicalValue)),
            "vertical": .array(vertical.map(\.canonicalValue))
        ])
    }
}

struct ASHCoordinateModelPolicyOracleV3: Equatable, Sendable {
    let policy: ASHCoordinateModelPolicyV3
    let luma: ASHCoordinateModelAxisOracleV3
    let chroma: ASHCoordinateModelAxisOracleV3

    fileprivate var canonicalValue: ASHLUTStrictJSONValueV2 {
        .object([
            "chroma": chroma.canonicalValue,
            "luma": luma.canonicalValue,
            "policy": .string(policy.rawValue)
        ])
    }
}

struct ASHCoordinateModelExtentV3: Equatable, Sendable {
    let width: Int
    let height: Int

    fileprivate var canonicalValue: ASHLUTStrictJSONValueV2 {
        .object([
            "height": .integer(Int64(height)),
            "width": .integer(Int64(width))
        ])
    }
}

struct ASHCoordinateModelGeometryV3: Equatable, Sendable {
    let luma: ASHCoordinateModelExtentV3
    let cb: ASHCoordinateModelExtentV3
    let cr: ASHCoordinateModelExtentV3

    fileprivate var canonicalValue: ASHLUTStrictJSONValueV2 {
        .object([
            "cb": cb.canonicalValue,
            "cr": cr.canonicalValue,
            "y": luma.canonicalValue
        ])
    }
}

struct ASHCoordinateModelRouteOracleV3: Equatable, Sendable {
    let route: ASHCoordinateModelRouteV3
    let scaleNumerator: Int
    let scaleDenominator: Int
    let lowResolutionGeometry: ASHCoordinateModelGeometryV3
    let targetGeometry: ASHCoordinateModelGeometryV3
    let phaseOrdinalGrid: [[Int]]
    let policyOracles: [ASHCoordinateModelPolicyOracleV3]

    fileprivate var canonicalValue: ASHLUTStrictJSONValueV2 {
        .object([
            "chroma_siting": .string("left"),
            "left_siting_offsets": .object([
                "denominator": .integer(2),
                "horizontal_numerator": .integer(0),
                "vertical_numerator": .integer(1)
            ]),
            "low_resolution_geometry": lowResolutionGeometry.canonicalValue,
            "phase_ordinal_grid": .array(phaseOrdinalGrid.map { row in
                .array(row.map { .integer(Int64($0)) })
            }),
            "policy_oracles": .array(policyOracles.map(\.canonicalValue)),
            "route": .string(route.rawValue),
            "scale": .object([
                "denominator": .integer(Int64(scaleDenominator)),
                "numerator": .integer(Int64(scaleNumerator))
            ]),
            "target_geometry": targetGeometry.canonicalValue
        ])
    }
}

struct ASHCoordinateModelRouteDimensionsV3: Equatable, Sendable {
    let route: ASHCoordinateModelRouteV3
    let lumaCoordinatePolicyValues: [ASHCoordinateModelPolicyV3]
    let chromaCoordinatePolicyValues: [ASHCoordinateModelPolicyV3]

    fileprivate var canonicalValue: ASHLUTStrictJSONValueV2 {
        .object([
            "chroma_coordinate_policy_values": .array(
                chromaCoordinatePolicyValues.map { .string($0.rawValue) }
            ),
            "luma_coordinate_policy_values": .array(
                lumaCoordinatePolicyValues.map { .string($0.rawValue) }
            ),
            "route": .string(route.rawValue)
        ])
    }
}

struct ASHCoordinateModelContractV3: Equatable, Sendable {
    static let schemaVersion = "3.0.0"
    static let artifactKind = "ash_coordinate_model_contract"
    static let contractID = "ash-plane-coordinate-model-v3"
    static let selectionStatus = "unselected_experiment_dimensions"
    static let phaseZeroCompilationSemantics = "generic_state_phase_v1"
    static let integralPreservationSemantics = "actual_rational_integrality_v1"
    static let coordinatePolicyValues: [ASHCoordinateModelPolicyV3] = [
        .halfPixelCenter, .sourceAlignedRational
    ]

    let sha256: ASHLUTHashV2
    let immutableBytes: Data

    private init(sha256: ASHLUTHashV2, immutableBytes: Data) {
        self.sha256 = sha256
        self.immutableBytes = immutableBytes
    }

    var canonicalBytes: Data { immutableBytes }

    var routeDimensions: [ASHCoordinateModelRouteDimensionsV3] {
        Self.frozenRouteDimensions
    }

    var coordinateOracles: [ASHCoordinateModelRouteOracleV3] {
        Self.frozenCoordinateOracles
    }

    var coordinateOracleMatrixSHA256: ASHLUTHashV2 {
        Self.sha256(.array(Self.frozenCoordinateOracles.map(\.canonicalValue)))
    }

    var experimentDimensionsSHA256: ASHLUTHashV2 {
        Self.sha256(Self.experimentDimensionsValue)
    }

    static func load(
        _ data: Data,
        expectedSHA256: ASHLUTHashV2? = nil
    ) throws -> ASHCoordinateModelContractV3 {
        let observed = ASHLUTHashV2(validatedBytes: Array(SHA256.hash(data: data)))
        if let expectedSHA256, observed != expectedSHA256 {
            throw ASHCoordinateModelContractV3Error.hashMismatch
        }
        let parsed: ASHLUTStrictJSONValueV2
        do {
            var parser = ASHLUTStrictJSONParserV2(data: data)
            parsed = try parser.parse()
        } catch {
            throw ASHCoordinateModelContractV3Error.invalidContract
        }
        var canonicalText = ASHLUTCanonicalJSONV2.encode(parsed)
        canonicalText.append(0x0a)
        guard canonicalText == data else {
            throw ASHCoordinateModelContractV3Error.nonCanonicalEncoding
        }
        guard case .object(let root) = parsed else {
            throw ASHCoordinateModelContractV3Error.invalidContract
        }
        guard Set(root.keys) == expectedRootKeys else {
            throw ASHCoordinateModelContractV3Error.fieldSetMismatch
        }
        guard data == expectedCanonicalBytes else {
            throw ASHCoordinateModelContractV3Error.invalidContract
        }
        return ASHCoordinateModelContractV3(sha256: observed, immutableBytes: data)
    }

    private static let expectedRootKeys: Set<String> = [
        "artifact_kind", "contract_id", "coordinate_oracles", "experiment_dimensions",
        "integral_preservation_semantics", "phase_zero_compilation_semantics", "schema_version"
    ]

    private static let frozenRouteDimensions: [ASHCoordinateModelRouteDimensionsV3] =
        ASHCoordinateModelRouteV3.allCases.map { route in
            ASHCoordinateModelRouteDimensionsV3(
                route: route,
                lumaCoordinatePolicyValues: coordinatePolicyValues,
                chromaCoordinatePolicyValues: coordinatePolicyValues
            )
        }

    private static let frozenCoordinateOracles: [ASHCoordinateModelRouteOracleV3] = [
        direct2xOracle(), direct3Over2Oracle()
    ]

    private static var experimentDimensionsValue: ASHLUTStrictJSONValueV2 {
        .object([
            "coordinate_policy_values": .array(
                coordinatePolicyValues.map { .string($0.rawValue) }
            ),
            "routes": .array(frozenRouteDimensions.map(\.canonicalValue)),
            "selection_status": .string(selectionStatus)
        ])
    }

    private static var expectedCanonicalValue: ASHLUTStrictJSONValueV2 {
        .object([
            "artifact_kind": .string(artifactKind),
            "contract_id": .string(contractID),
            "coordinate_oracles": .array(frozenCoordinateOracles.map(\.canonicalValue)),
            "experiment_dimensions": experimentDimensionsValue,
            "integral_preservation_semantics": .string(integralPreservationSemantics),
            "phase_zero_compilation_semantics": .string(phaseZeroCompilationSemantics),
            "schema_version": .string(schemaVersion)
        ])
    }

    private static var expectedCanonicalBytes: Data {
        var data = ASHLUTCanonicalJSONV2.encode(expectedCanonicalValue)
        data.append(0x0a)
        return data
    }

    private static func sha256(_ value: ASHLUTStrictJSONValueV2) -> ASHLUTHashV2 {
        let bytes = ASHLUTCanonicalJSONV2.encode(value)
        return ASHLUTHashV2(validatedBytes: Array(SHA256.hash(data: bytes)))
    }

    private static func rationalCoordinates(
        _ pairs: [(Int64, Int64)]
    ) -> [ASHCoordinateModelRationalV3] {
        pairs.map { numerator, denominator in
            ASHCoordinateModelRationalV3(
                numerator: numerator,
                denominator: denominator
            )
        }
    }

    private static func squareGeometry(
        lumaExtent: Int,
        chromaExtent: Int
    ) -> ASHCoordinateModelGeometryV3 {
        ASHCoordinateModelGeometryV3(
            luma: ASHCoordinateModelExtentV3(width: lumaExtent, height: lumaExtent),
            cb: ASHCoordinateModelExtentV3(width: chromaExtent, height: chromaExtent),
            cr: ASHCoordinateModelExtentV3(width: chromaExtent, height: chromaExtent)
        )
    }

    private static func direct2xOracle() -> ASHCoordinateModelRouteOracleV3 {
        let lumaHalfPixel = rationalCoordinates([
            (-1, 4), (1, 4), (3, 4), (5, 4), (7, 4), (9, 4), (11, 4), (13, 4)
        ])
        let lumaSourceAligned = rationalCoordinates([
            (0, 1), (1, 2), (1, 1), (3, 2), (2, 1), (5, 2), (3, 1), (7, 2)
        ])
        let chromaHalfPixelHorizontal = rationalCoordinates([
            (-1, 8), (3, 8), (7, 8), (11, 8)
        ])
        let chromaHalfPixelVertical = rationalCoordinates([
            (-1, 4), (1, 4), (3, 4), (5, 4)
        ])
        let chromaSourceAlignedHorizontal = rationalCoordinates([
            (0, 1), (1, 2), (1, 1), (3, 2)
        ])
        let chromaSourceAlignedVertical = rationalCoordinates([
            (-1, 8), (3, 8), (7, 8), (11, 8)
        ])
        return ASHCoordinateModelRouteOracleV3(
            route: .direct2x,
            scaleNumerator: 2,
            scaleDenominator: 1,
            lowResolutionGeometry: squareGeometry(lumaExtent: 4, chromaExtent: 2),
            targetGeometry: squareGeometry(lumaExtent: 8, chromaExtent: 4),
            phaseOrdinalGrid: [[0, 1], [2, 3]],
            policyOracles: [
                ASHCoordinateModelPolicyOracleV3(
                    policy: .halfPixelCenter,
                    luma: ASHCoordinateModelAxisOracleV3(
                        horizontal: lumaHalfPixel,
                        vertical: lumaHalfPixel
                    ),
                    chroma: ASHCoordinateModelAxisOracleV3(
                        horizontal: chromaHalfPixelHorizontal,
                        vertical: chromaHalfPixelVertical
                    )
                ),
                ASHCoordinateModelPolicyOracleV3(
                    policy: .sourceAlignedRational,
                    luma: ASHCoordinateModelAxisOracleV3(
                        horizontal: lumaSourceAligned,
                        vertical: lumaSourceAligned
                    ),
                    chroma: ASHCoordinateModelAxisOracleV3(
                        horizontal: chromaSourceAlignedHorizontal,
                        vertical: chromaSourceAlignedVertical
                    )
                )
            ]
        )
    }

    private static func direct3Over2Oracle() -> ASHCoordinateModelRouteOracleV3 {
        let lumaHalfPixel = rationalCoordinates([
            (-1, 6), (1, 2), (7, 6), (11, 6), (5, 2), (19, 6)
        ])
        let lumaSourceAligned = rationalCoordinates([
            (0, 1), (2, 3), (4, 3), (2, 1), (8, 3), (10, 3)
        ])
        let chromaHalfPixelHorizontal = rationalCoordinates([
            (-1, 12), (7, 12), (5, 4)
        ])
        let chromaHalfPixelVertical = rationalCoordinates([
            (-1, 6), (1, 2), (7, 6)
        ])
        let chromaSourceAlignedHorizontal = rationalCoordinates([
            (0, 1), (2, 3), (4, 3)
        ])
        let chromaSourceAlignedVertical = rationalCoordinates([
            (-1, 12), (7, 12), (5, 4)
        ])
        return ASHCoordinateModelRouteOracleV3(
            route: .direct3Over2,
            scaleNumerator: 3,
            scaleDenominator: 2,
            lowResolutionGeometry: squareGeometry(lumaExtent: 4, chromaExtent: 2),
            targetGeometry: squareGeometry(lumaExtent: 6, chromaExtent: 3),
            phaseOrdinalGrid: [[0, 1, 2], [3, 4, 5], [6, 7, 8]],
            policyOracles: [
                ASHCoordinateModelPolicyOracleV3(
                    policy: .halfPixelCenter,
                    luma: ASHCoordinateModelAxisOracleV3(
                        horizontal: lumaHalfPixel,
                        vertical: lumaHalfPixel
                    ),
                    chroma: ASHCoordinateModelAxisOracleV3(
                        horizontal: chromaHalfPixelHorizontal,
                        vertical: chromaHalfPixelVertical
                    )
                ),
                ASHCoordinateModelPolicyOracleV3(
                    policy: .sourceAlignedRational,
                    luma: ASHCoordinateModelAxisOracleV3(
                        horizontal: lumaSourceAligned,
                        vertical: lumaSourceAligned
                    ),
                    chroma: ASHCoordinateModelAxisOracleV3(
                        horizontal: chromaSourceAlignedHorizontal,
                        vertical: chromaSourceAlignedVertical
                    )
                )
            ]
        )
    }
}
