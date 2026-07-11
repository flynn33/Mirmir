import Foundation

struct ASHSpatialRuntimeConfigurationV2: Equatable, Sendable {
    static let developmentP05 = ASHSpatialRuntimeConfigurationV2(
        status: "development_only_not_release_locked",
        mappingSchemaVersion: "2.0.1-seed",
        mappingSHA256: "2ebdffa39909012e3284888fd23ede66a68a8a2e270fdfc278b287d109a60e88",
        operatorBankSchemaVersion: "2.0.0",
        operatorBankSHA256: "7909a226c80fae86a4f38a4f0e52bfb99205f47e1dcecb7c121d1eb62801b137",
        coordinatePolicy: .sourceAlignedRational,
        boundaryMode: .mirrorReflect101,
        analysisGrid: "source_site",
        chromaSitingRule: "core_video_progressive_offset_table_v1",
        selectorVersion: "p05_disposable_causal_selector_v1"
    )

    let status: String
    let mappingSchemaVersion: String
    let mappingSHA256: String
    let operatorBankSchemaVersion: String
    let operatorBankSHA256: String
    let coordinatePolicy: ASHSpatialCoordinatePolicyV2
    let boundaryMode: ASHSpatialBoundaryModeV2
    let analysisGrid: String
    let chromaSitingRule: String
    let selectorVersion: String

    var outputMetadata: [String: String] {
        [
            "com.mirmir.ash.configuration-status": status,
            "com.mirmir.ash.mapping-schema": mappingSchemaVersion,
            "com.mirmir.ash.mapping-sha256": mappingSHA256,
            "com.mirmir.ash.operator-bank-schema": operatorBankSchemaVersion,
            "com.mirmir.ash.operator-bank-sha256": operatorBankSHA256,
            "com.mirmir.ash.coordinate-policy": coordinatePolicy.rawValue,
            "com.mirmir.ash.boundary-mode": boundaryMode.rawValue,
            "com.mirmir.ash.analysis-grid": analysisGrid,
            "com.mirmir.ash.chroma-siting-rule": chromaSitingRule,
            "com.mirmir.ash.selector-version": selectorVersion
        ]
    }
}
