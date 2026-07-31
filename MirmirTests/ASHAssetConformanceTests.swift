import CryptoKit
import Foundation
import XCTest
@testable import Mirmir

final class ASHAssetConformanceTests: XCTestCase {

    func test_requiredASHAssetsMatchSourceHashes() throws {
        let expectedHashes = [
            "ash_mapping_v1.json": "aef24e8eba2441025e1e440e2791215d32d163e0b7b91d25bb7e9b7018260c79",
            "codewords.csv": "cccb4077ec79e52d428f4fc41dabb6e91e565c95b7f8cca2d53356e7cd408fe4",
            "ash-state-reference.csv": "20e885ce6f83ca584ec13b53161dd25f5ed2e42baeeb60633b0ce19d2975c310",
            "branch-topology.json": "e114168b20ce2842126b949399b07750160fb0acbdf3971a028f5fcc15d3748c",
            "computational-certificate.json": "b0ea48e16ede4d09d8361fcb374c7f3072d9c498685623b9bc747103efb9febf",
            "ash_video_mapping_v2.seed.json": "2ebdffa39909012e3284888fd23ede66a68a8a2e270fdfc278b287d109a60e88",
            "operator_bank_v2.seed.json": "7909a226c80fae86a4f38a4f0e52bfb99205f47e1dcecb7c121d1eb62801b137"
        ]

        let assetRoot = repoRootURL().appendingPathComponent("Mirmir/Resources/ASH")
        for (fileName, expectedHash) in expectedHashes {
            let fileURL = assetRoot.appendingPathComponent(fileName)
            let data = try Data(contentsOf: fileURL)
            XCTAssertEqual(sha256Hex(data), expectedHash, "\(fileName) hash mismatch")
        }
    }

    func test_assetManifestListsEveryRequiredASHAsset() throws {
        let manifestURL = repoRootURL().appendingPathComponent("Mirmir/Resources/ASH/ash-asset-manifest.json")
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(ASHAssetManifest.self, from: data)
        let noticeIdentity = MirmirASHPinnedNoticeIdentity.current

        XCTAssertEqual(manifest.schemaVersion, "1.1")
        XCTAssertEqual(
            manifest.sourceRevision,
            noticeIdentity.sourceRevision
        )
        XCTAssertEqual(Set(manifest.assets.map(\.path)), [
            "ash_mapping_v1.json",
            "ash_video_mapping_v2.seed.json",
            "operator_bank_v2.seed.json",
            "codewords.csv",
            "ash-state-reference.csv",
            "branch-topology.json",
            "computational-certificate.json"
        ])
        XCTAssertTrue(manifest.assets.allSatisfy { !$0.sha256.isEmpty && !$0.sourcePath.isEmpty })

        let certificateURL = repoRootURL().appendingPathComponent(
            "Mirmir/Resources/ASH/computational-certificate.json"
        )
        let certificateData = try Data(contentsOf: certificateURL)
        let certificate = try XCTUnwrap(
            JSONSerialization.jsonObject(with: certificateData)
                as? [String: Any]
        )
        let sourceHashes = try XCTUnwrap(
            certificate["source_sha256"] as? [String: String]
        )
        XCTAssertEqual(
            sourceHashes["LICENSE"],
            noticeIdentity.licenseSHA256
        )
    }

    func test_runtimeAssetResolverAcceptsFlattenedResourceLayout() throws {
        let flattenedRoot = repoRootURL().appendingPathComponent("Mirmir/Resources/ASH")

        let resolved = try ASHAssetCatalog.resolveResourceRoot(candidates: [nil, flattenedRoot])

        XCTAssertEqual(resolved.standardizedFileURL, flattenedRoot.standardizedFileURL)
        XCTAssertTrue(try ASHAssetCatalog.load(from: resolved).validateRuntime().isValid)
    }

    @MainActor
    func test_bundledASHLicenseMatchesPinnedSource() throws {
        let noticeIdentity = MirmirASHPinnedNoticeIdentity.current
        let sourceURL = repoRootURL()
            .appendingPathComponent("Mirmir/Resources/Legal/ASH-Model-LICENSE.txt")
        let bundleURL = try XCTUnwrap(
            Bundle.main.url(
                forResource: noticeIdentity.licenseResourceName,
                withExtension: noticeIdentity.licenseResourceExtension
            )
        )
        let sourceData = try Data(contentsOf: sourceURL)
        let bundleData = try Data(contentsOf: bundleURL)

        XCTAssertEqual(
            sha256Hex(sourceData),
            noticeIdentity.licenseSHA256
        )
        XCTAssertEqual(bundleData, sourceData)

        let license = try XCTUnwrap(
            String(data: bundleData, encoding: .utf8)
        )
        XCTAssertEqual(
            MirmirAboutView.bundledASHLicenseText,
            license
        )
        XCTAssertTrue(
            license.contains(
                "Copyright (c) 2025-2026 James Daley. All rights reserved."
            )
        )
        XCTAssertTrue(
            license.contains(
                "Canonical Computational Specification and "
                    + "Reference Implementation,\" version 1.1.0."
            )
        )
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func repoRootURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private struct ASHAssetManifest: Decodable {
    let schemaVersion: String
    let sourcePackage: String
    let sourceRevision: String
    let assets: [ASHAsset]
}

private struct ASHAsset: Decodable {
    let path: String
    let sourcePath: String
    let sha256: String
}
