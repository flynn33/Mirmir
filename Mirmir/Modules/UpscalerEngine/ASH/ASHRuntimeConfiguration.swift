struct ASHRuntimeProvenance: Equatable, Sendable {
    static let referenceV1 = ASHRuntimeProvenance(
        mappingSchemaVersion: "1.0.0",
        ashProjectVersion: "1.1.0",
        ashSourceRevision: "8782886a8cca9fa63f7d44b529add6eac80a50f8",
        mappingArtifactSHA256: "aef24e8eba2441025e1e440e2791215d32d163e0b7b91d25bb7e9b7018260c79",
        operatorSpecificationVersion: "ash-reference-operator-v1",
        scoringSpecificationVersion: ASHScoringPolicy.referenceV1.specificationVersion,
        historyPolicyVersion: "mirmir-tile-history-v1",
        coordinateConvention: "coordinate_1_is_most_significant"
    )
    static let mirmirAdaptiveV1 = ASHRuntimeProvenance(
        mappingSchemaVersion: "1.0.0",
        ashProjectVersion: "1.1.0",
        ashSourceRevision: "8782886a8cca9fa63f7d44b529add6eac80a50f8",
        mappingArtifactSHA256: "aef24e8eba2441025e1e440e2791215d32d163e0b7b91d25bb7e9b7018260c79",
        operatorSpecificationVersion: "ash-reference-operator-v1",
        scoringSpecificationVersion: ASHScoringPolicy.mirmirAdaptiveV1.specificationVersion,
        historyPolicyVersion: "mirmir-tile-history-v1",
        coordinateConvention: "coordinate_1_is_most_significant"
    )
    static let current = mirmirAdaptiveV1

    let mappingSchemaVersion: String
    let ashProjectVersion: String
    let ashSourceRevision: String
    let mappingArtifactSHA256: String
    let operatorSpecificationVersion: String
    let scoringSpecificationVersion: String
    let historyPolicyVersion: String
    let coordinateConvention: String

    var outputMetadata: [String: String] {
        [
            "com.mirmir.ash.mapping-schema": mappingSchemaVersion,
            "com.mirmir.ash.project-version": ashProjectVersion,
            "com.mirmir.ash.source-revision": ashSourceRevision,
            "com.mirmir.ash.mapping-sha256": mappingArtifactSHA256,
            "com.mirmir.ash.operator-specification": operatorSpecificationVersion,
            "com.mirmir.ash.scoring-specification": scoringSpecificationVersion,
            "com.mirmir.ash.history-policy": historyPolicyVersion,
            "com.mirmir.ash.coordinate-convention": coordinateConvention
        ]
    }
}

struct ASHRuntimeConfiguration: Equatable, Sendable {
    static let referenceV1 = ASHRuntimeConfiguration(
        provenance: .referenceV1,
        scoringPolicy: .referenceV1,
        sceneCutMeanAbsoluteLumaThreshold: 0.35
    )
    static let current = ASHRuntimeConfiguration(
        provenance: .mirmirAdaptiveV1,
        scoringPolicy: .mirmirAdaptiveV1,
        sceneCutMeanAbsoluteLumaThreshold: 0.35
    )

    let provenance: ASHRuntimeProvenance
    let scoringPolicy: ASHScoringPolicy
    let sceneCutMeanAbsoluteLumaThreshold: Double

    var outputMetadata: [String: String] {
        var metadata = provenance.outputMetadata.merging([
            "com.mirmir.ash.scene-cut-metric": "mean-absolute-luma-difference",
            "com.mirmir.ash.scene-cut-threshold": String(sceneCutMeanAbsoluteLumaThreshold)
        ]) { _, current in current }
        if scoringPolicy == .mirmirAdaptiveV1 {
            metadata["com.mirmir.ash.adaptive-feature-prior-weight"] = String(ASHScoringPolicy.adaptiveFeaturePriorWeight)
            metadata["com.mirmir.ash.adaptive-inactive-floor"] = String(ASHScoringPolicy.adaptiveInactiveFloor)
        }
        return metadata
    }
}
