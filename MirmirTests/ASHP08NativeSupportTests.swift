import Foundation
import XCTest
@testable import Mirmir

@available(macOS 15.4, *)
final class ASHP08NativeSupportTests: XCTestCase {
    private struct TypedArtifactFixture {
        let root: URL
        let file: URL
        let binding: [String: Any]
        let internalSelfHash: String
        let fileSHA256: String
    }

    func testTypedBindingSeparatesInternalSelfHashFromCompleteFileDigest() throws {
        let fixture = try makeTypedArtifactFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        XCTAssertNotEqual(fixture.internalSelfHash, fixture.fileSHA256)
        let reopened = try ASHP08NativeSupport.verifiedTypedArtifact(
            binding: fixture.binding,
            artifactRoot: fixture.root,
            expectedURL: fixture.file,
            expectedKind: "p06_fixed_control_selection_v2",
            expectedSchemaSHA256:
                ASHP08NativeSupport.fixedControlSelectionSchemaSHA256
        )

        XCTAssertEqual(
            reopened["artifact_sha256"] as? String,
            fixture.internalSelfHash
        )
    }

    func testCorrectSelfHashWithWrongCompleteFileBindingIsRejected() throws {
        let fixture = try makeTypedArtifactFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var wrongBinding = fixture.binding
        wrongBinding["sha256"] = fixture.internalSelfHash

        XCTAssertThrowsError(try ASHP08NativeSupport.verifiedTypedArtifact(
            binding: wrongBinding,
            artifactRoot: fixture.root,
            expectedURL: fixture.file,
            expectedKind: "p06_fixed_control_selection_v2",
            expectedSchemaSHA256:
                ASHP08NativeSupport.fixedControlSelectionSchemaSHA256
        ))
    }

    func testWrongTypedArtifactSchemaBindingIsRejected() throws {
        let fixture = try makeTypedArtifactFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var wrongBinding = fixture.binding
        wrongBinding["schema_sha256"] =
            "1111111111111111111111111111111111111111111111111111111111111111"

        XCTAssertThrowsError(try ASHP08NativeSupport.verifiedTypedArtifact(
            binding: wrongBinding,
            artifactRoot: fixture.root,
            expectedURL: fixture.file,
            expectedKind: "p06_fixed_control_selection_v2",
            expectedSchemaSHA256:
                ASHP08NativeSupport.fixedControlSelectionSchemaSHA256
        ))
    }

    func testProfileOutputCountsIncludeBothChromaComponents() throws {
        let counts = try ASHP08PerformanceRuntime.expectedProfileOutputCounts(
            destinationWidth: 16,
            destinationHeight: 8
        )

        XCTAssertEqual(counts.luma, 128)
        XCTAssertEqual(counts.chroma, 64)
    }

    func testProfileOutputCountsRejectInvalidAndOverflowingDimensions() {
        XCTAssertThrowsError(
            try ASHP08PerformanceRuntime.expectedProfileOutputCounts(
                destinationWidth: 0,
                destinationHeight: 8
            )
        )
        XCTAssertThrowsError(
            try ASHP08PerformanceRuntime.expectedProfileOutputCounts(
                destinationWidth: Int.max,
                destinationHeight: 2
            )
        )
        XCTAssertThrowsError(
            try ASHP08PerformanceRuntime.expectedProfileOutputCounts(
                destinationWidth: 65_536,
                destinationHeight: 65_536
            )
        )
    }

    private func makeTypedArtifactFixture() throws -> TypedArtifactFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirmir-p08-binding-\(UUID().uuidString)")
        let controls = root.appendingPathComponent("controls")
        try FileManager.default.createDirectory(
            at: controls,
            withIntermediateDirectories: true
        )
        let document = try ASHP08NativeSupport.finalizedDocument([
            "schema_version": "2.0.0",
            "artifact_kind": "p06_fixed_control_selection_v2",
            "selection_stage": "validation_final",
            "split": "validation",
            "chosen_descriptor_id": 7
        ])
        let internalSelfHash = try XCTUnwrap(
            document["artifact_sha256"] as? String
        )
        var bytes = try ASHP08NativeSupport.canonicalData(document)
        bytes.append(0x0a)
        let file = controls.appendingPathComponent("fixed.json")
        try bytes.write(to: file, options: .withoutOverwriting)
        let fileSHA256 = ASHP08NativeSupport.sha256(bytes)
        let binding: [String: Any] = [
            "artifact_kind": "p06_fixed_control_selection_v2",
            "schema_sha256":
                ASHP08NativeSupport.fixedControlSelectionSchemaSHA256,
            "path": "controls/fixed.json",
            "sha256": fileSHA256,
            "size_bytes": bytes.count
        ]
        return TypedArtifactFixture(
            root: root,
            file: file,
            binding: binding,
            internalSelfHash: internalSelfHash,
            fileSHA256: fileSHA256
        )
    }
}
