import CryptoKit
import Foundation
import XCTest

final class ASHAssetConformanceTests: XCTestCase {

    func test_requiredASHAssetsMatchSourceHashes() throws {
        let expectedHashes = [
            "ash_mapping_v1.json": "aef24e8eba2441025e1e440e2791215d32d163e0b7b91d25bb7e9b7018260c79",
            "codewords.csv": "cccb4077ec79e52d428f4fc41dabb6e91e565c95b7f8cca2d53356e7cd408fe4",
            "ash-state-reference.csv": "20e885ce6f83ca584ec13b53161dd25f5ed2e42baeeb60633b0ce19d2975c310",
            "branch-topology.json": "e114168b20ce2842126b949399b07750160fb0acbdf3971a028f5fcc15d3748c",
            "computational-certificate.json": "b0ea48e16ede4d09d8361fcb374c7f3072d9c498685623b9bc747103efb9febf"
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

        XCTAssertEqual(manifest.schemaVersion, "1.0")
        XCTAssertEqual(Set(manifest.assets.map(\.path)), [
            "ash_mapping_v1.json",
            "codewords.csv",
            "ash-state-reference.csv",
            "branch-topology.json",
            "computational-certificate.json"
        ])
        XCTAssertTrue(manifest.assets.allSatisfy { !$0.sha256.isEmpty && !$0.sourcePath.isEmpty })
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
    let assets: [ASHAsset]
}

private struct ASHAsset: Decodable {
    let path: String
    let sourcePath: String
    let sha256: String
}
