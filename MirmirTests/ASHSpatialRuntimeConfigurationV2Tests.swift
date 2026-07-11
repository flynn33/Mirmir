import XCTest
@testable import Mirmir

final class ASHSpatialRuntimeConfigurationV2Tests: XCTestCase {
    func test_p05ConfigurationIsExplicitlyDevelopmentOnlyAndHashBound() {
        let configuration = ASHSpatialRuntimeConfigurationV2.developmentP05
        let metadata = configuration.outputMetadata

        XCTAssertEqual(configuration.status, "development_only_not_release_locked")
        XCTAssertEqual(
            metadata["com.mirmir.ash.mapping-sha256"],
            "2ebdffa39909012e3284888fd23ede66a68a8a2e270fdfc278b287d109a60e88"
        )
        XCTAssertEqual(
            metadata["com.mirmir.ash.operator-bank-sha256"],
            "7909a226c80fae86a4f38a4f0e52bfb99205f47e1dcecb7c121d1eb62801b137"
        )
        XCTAssertEqual(configuration.coordinatePolicy, .sourceAlignedRational)
        XCTAssertEqual(configuration.analysisGrid, "source_site")
    }

    func test_v2MetadataDoesNotClaimLegacyMappingOrOperator() {
        let metadata = ASHSpatialRuntimeConfigurationV2.developmentP05.outputMetadata

        XCTAssertEqual(metadata["com.mirmir.ash.mapping-schema"], "2.0.1-seed")
        XCTAssertEqual(metadata["com.mirmir.ash.operator-bank-schema"], "2.0.0")
        XCTAssertNil(metadata["com.mirmir.ash.scoring-specification"])
        XCTAssertNil(metadata["com.mirmir.ash.history-policy"])
    }

    func test_writerPublishesTheConfigurationExecutedByTheV2Backend() async throws {
        var entries: [(String, String)] = []
        for item in AVFoundationMediaSession.makeASHMetadataItems() {
            let rawValue = try await item.load(.value)
            let key = try XCTUnwrap(item.key as? String)
            let value = try XCTUnwrap(rawValue as? String)
            entries.append((key, value))
        }
        let metadata = try Dictionary(uniqueKeysWithValues: entries)

        XCTAssertEqual(metadata, ASHSpatialRuntimeConfigurationV2.developmentP05.outputMetadata)
        XCTAssertNil(metadata["com.mirmir.ash.operator-specification"])
        XCTAssertNil(metadata["com.mirmir.ash.source-revision"])
    }
}
