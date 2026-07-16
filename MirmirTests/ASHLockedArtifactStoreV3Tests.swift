import XCTest
@testable import Mirmir

final class ASHLockedArtifactStoreV3Tests: XCTestCase {
    func testPublishesCompleteImmutableSetOnceAndReturnsCachedIdentity() async throws {
        let fixture = try ASHLockedReleaseTestSupportV3.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = ASHLockedArtifactStoreV3(resourceRoot: fixture.root)

        let first = try await store.artifacts()
        let second = try await store.artifacts()

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.direct2xLUT.route, .direct2x)
        XCTAssertEqual(first.direct3Over2LUT.route, .direct3Over2)
        XCTAssertEqual(first.direct2xLUT.immutableBytes, fixture.direct2x.artifact.data)
        XCTAssertEqual(first.direct3Over2LUT.immutableBytes, fixture.direct3Over2.artifact.data)
        let diagnostics = await store.diagnostics()
        XCTAssertEqual(
            diagnostics,
            ASHLockedArtifactStoreDiagnosticsV3(loadAttemptCount: 1, publicationCount: 1)
        )
    }

    func testMissingOrUnknownResourceRejectsBeforePublication() async throws {
        let missing = try ASHLockedReleaseTestSupportV3.makeFixture()
        defer { try? FileManager.default.removeItem(at: missing.root) }
        try FileManager.default.removeItem(
            at: missing.root.appendingPathComponent("direct2x.ashlut")
        )
        let missingStore = ASHLockedArtifactStoreV3(resourceRoot: missing.root)
        await assertRejected(missingStore, expectedPublicationCount: 0)

        let unknown = try ASHLockedReleaseTestSupportV3.makeFixture()
        defer { try? FileManager.default.removeItem(at: unknown.root) }
        try Data([0]).write(to: unknown.root.appendingPathComponent("unknown.bin"))
        let unknownStore = ASHLockedArtifactStoreV3(resourceRoot: unknown.root)
        await assertRejected(unknownStore, expectedPublicationCount: 0)
    }

    func testRouteSwapAndByteMutationRejectWithoutPartialCache() async throws {
        let swapped = try ASHLockedReleaseTestSupportV3.makeFixture()
        defer { try? FileManager.default.removeItem(at: swapped.root) }
        try swapped.direct3Over2.artifact.data.write(
            to: swapped.root.appendingPathComponent("direct2x.ashlut"),
            options: .atomic
        )
        let swappedStore = ASHLockedArtifactStoreV3(resourceRoot: swapped.root)
        await assertRejected(swappedStore, expectedPublicationCount: 0)

        let mutated = try ASHLockedReleaseTestSupportV3.makeFixture()
        defer { try? FileManager.default.removeItem(at: mutated.root) }
        let path = mutated.root.appendingPathComponent("direct3over2.ashlut")
        var bytes = try Data(contentsOf: path)
        bytes[ASHLUTBinaryContractV3.headerSize] ^= 1
        try bytes.write(to: path, options: .atomic)
        let mutatedStore = ASHLockedArtifactStoreV3(resourceRoot: mutated.root)
        await assertRejected(mutatedStore, expectedPublicationCount: 0)
    }

    func testManifestRequiresCanonicalBytesAndValidSelfHash() async throws {
        let noncanonical = try ASHLockedReleaseTestSupportV3.makeFixture()
        defer { try? FileManager.default.removeItem(at: noncanonical.root) }
        let manifestPath = noncanonical.root.appendingPathComponent(
            ASHLockedReleaseLUTManifestV3.filename
        )
        var manifest = try Data(contentsOf: manifestPath)
        manifest.insert(0x20, at: 0)
        try manifest.write(to: manifestPath, options: .atomic)
        let noncanonicalStore = ASHLockedArtifactStoreV3(resourceRoot: noncanonical.root)
        await assertRejected(noncanonicalStore, expectedPublicationCount: 0)

        let rehashed = try ASHLockedReleaseTestSupportV3.makeFixture()
        defer { try? FileManager.default.removeItem(at: rehashed.root) }
        let rehashedPath = rehashed.root.appendingPathComponent(
            ASHLockedReleaseLUTManifestV3.filename
        )
        var rehashedBytes = try Data(contentsOf: rehashedPath)
        let marker = Data("\"manifest_sha256\":\"".utf8)
        guard let range = rehashedBytes.range(of: marker) else {
            return XCTFail("manifest fixture lacks self hash")
        }
        let hashStart = range.upperBound
        rehashedBytes[hashStart] = rehashedBytes[hashStart] == 0x30 ? 0x31 : 0x30
        try rehashedBytes.write(to: rehashedPath, options: .atomic)
        let rehashedStore = ASHLockedArtifactStoreV3(resourceRoot: rehashed.root)
        await assertRejected(rehashedStore, expectedPublicationCount: 0)
    }

    private func assertRejected(
        _ store: ASHLockedArtifactStoreV3,
        expectedPublicationCount: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await store.artifacts()
            XCTFail("artifact store unexpectedly published", file: file, line: line)
        } catch {
            let diagnostics = await store.diagnostics()
            XCTAssertEqual(diagnostics.loadAttemptCount, 1, file: file, line: line)
            XCTAssertEqual(
                diagnostics.publicationCount,
                expectedPublicationCount,
                file: file,
                line: line
            )
        }
    }

}
