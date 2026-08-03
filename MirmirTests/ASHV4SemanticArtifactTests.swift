import Foundation
import XCTest
@testable import Mirmir

final class ASHV4SemanticArtifactTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirmir-v4-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: false
        )
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testCanonicalJSONIsStrictAndHashDomainSeparated() throws {
        struct Value: Codable, Equatable {
            let z: Int
            let a: String
        }
        let value = Value(z: 7, a: "slash/value")
        let bytes = try ASHCanonicalJSONV4.encode(value)
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "{\"a\":\"slash/value\",\"z\":7}")
        XCTAssertEqual(
            try ASHCanonicalJSONV4.decode(Value.self, from: bytes),
            value
        )
        XCTAssertThrowsError(
            try ASHCanonicalJSONV4.decode(
                Value.self,
                from: Data("{\"z\":7,\"a\":\"slash/value\"}".utf8)
            )
        )
        XCTAssertThrowsError(
            try ASHCanonicalJSONV4.parse(Data("{\"a\":1,\"a\":2}".utf8))
        )
        XCTAssertThrowsError(
            try ASHCanonicalJSONV4.parse(Data("{\"a\":1.0}".utf8))
        )
        XCTAssertNotEqual(
            try ASHCanonicalJSONV4.hash(value, domain: "domain-a"),
            try ASHCanonicalJSONV4.hash(value, domain: "domain-b")
        )
    }

    func testBundleBuildIsByteReproducibleAndPlanIdentityIsStable() throws {
        let firstURL = temporaryDirectory.appendingPathComponent("first")
        let secondURL = temporaryDirectory.appendingPathComponent("second")
        let first = try ASHV4SemanticArtifactTestSupport.buildAndLoad(at: firstURL)
        let second = try ASHV4SemanticArtifactTestSupport.buildAndLoad(at: secondURL)

        XCTAssertEqual(
            try ASHV4SemanticArtifactTestSupport.bundleFiles(at: firstURL),
            try ASHV4SemanticArtifactTestSupport.bundleFiles(at: secondURL)
        )
        XCTAssertEqual(first.manifestSHA256, second.manifestSHA256)
        XCTAssertEqual(
            try first.measurementContract(),
            ASHMeasurementContractV4.canonicalP06
        )
        XCTAssertEqual(
            try first.branchProgram(),
            try ASHDepthFourBranchCompilerV4.compileCanonical()
        )
        let firstPlanHash = try ASHV4SemanticArtifactTestSupport.planHash(runtime: first)
        let secondPlanHash = try ASHV4SemanticArtifactTestSupport.planHash(runtime: second)
        XCTAssertEqual(firstPlanHash, secondPlanHash)
        XCTAssertEqual(
            firstPlanHash,
            ASHV4SemanticArtifactTestSupport.expectedPlanSHA256
        )

        let plan = try ASHExecutionPlannerV4.makePlan(
            media: ASHV4SemanticArtifactTestSupport.mediaState(),
            request: ASHV4SemanticArtifactTestSupport.executionRequest(),
            runtime: first
        )
        try plan.verify()
        XCTAssertEqual(plan.plan.tracks.count, 4)
        XCTAssertEqual(
            plan.plan.tracks.map(\.sourceIdentity.persistentID),
            ["video-main", "video-angle-b", "audio-en", "captions-en"]
        )
        XCTAssertEqual(
            plan.plan.tracks[0].videoScale?.horizontalScale,
            try ExactRationalV4(1_001, 640)
        )
        XCTAssertEqual(
            plan.plan.tracks[0].videoScale?.verticalScale,
            try ExactRationalV4(563, 360)
        )
    }

    func testIncompleteBuildAndUnplannedTrackFailClosed() throws {
        var request = try ASHV4SemanticArtifactTestSupport.completeRequest()
        request = ASHP06RuntimeBuildRequestV4(
            releaseStatus: request.releaseStatus,
            provenance: request.provenance,
            artifacts: request.artifacts.filter { $0.role != .metricContract }
        )
        XCTAssertThrowsError(
            try ASHP06RuntimeBundleBuilderV4.build(
                request,
                at: temporaryDirectory.appendingPathComponent("incomplete"),
                metalLibraryValidator: ASHV4FixtureMetalValidator()
            )
        ) { error in
            guard case ASHP06RuntimeBundleV4Error.incompleteBuildInput(let missing) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(missing, [.metricContract])
        }

        let runtime = try ASHV4SemanticArtifactTestSupport.buildAndLoad(
            at: temporaryDirectory.appendingPathComponent("complete")
        )
        let original = ASHV4SemanticArtifactTestSupport.executionRequest()
        let missingTrack = ASHExecutionRequestV4(
            executor: original.executor,
            measurementContractID: original.measurementContractID,
            kernelContractID: original.kernelContractID,
            directives: original.directives.filter { $0.trackID != "captions-en" }
        )
        XCTAssertThrowsError(
            try ASHExecutionPlannerV4.makePlan(
                media: ASHV4SemanticArtifactTestSupport.mediaState(),
                request: missingTrack,
                runtime: runtime
            )
        ) { error in
            XCTAssertEqual(
                error as? ASHExecutionPlanV4Error,
                .missingTrackDirective("captions-en")
            )
        }
    }

    func testSemanticArtifactsAndContractIdentitiesFailClosed() throws {
        let canonical = try ASHP06MeasurementContractArtifactV4.canonical()
        let replacement = String(
            canonical.canonicalBinaryHex.dropLast(2)
        ) + "00"
        let tampered = ASHP06MeasurementContractArtifactV4(
            schemaID: canonical.schemaID,
            artifactRole: canonical.artifactRole,
            contractID: canonical.contractID,
            canonicalBinarySHA256: canonical.canonicalBinarySHA256,
            canonicalBinaryHex: replacement
        )
        let original = try ASHV4SemanticArtifactTestSupport.completeRequest()
        let request = ASHP06RuntimeBuildRequestV4(
            releaseStatus: original.releaseStatus,
            provenance: original.provenance,
            artifacts: try original.artifacts.map { artifact in
                guard artifact.role == .measurementContract else {
                    return artifact
                }
                return ASHP06RuntimeArtifactInputV4(
                    role: artifact.role,
                    data: try ASHCanonicalJSONV4.encode(tampered)
                )
            }
        )
        XCTAssertThrowsError(
            try ASHP06RuntimeBundleBuilderV4.build(
                request,
                at: temporaryDirectory.appendingPathComponent("semantic-tamper"),
                metalLibraryValidator: ASHV4FixtureMetalValidator()
            )
        ) { error in
            XCTAssertEqual(
                error as? ASHP06RuntimeBundleV4Error,
                .measurementContractMismatch
            )
        }

        let runtime = try ASHV4SemanticArtifactTestSupport.buildAndLoad(
            at: temporaryDirectory.appendingPathComponent("identity-runtime")
        )
        let valid = ASHV4SemanticArtifactTestSupport.executionRequest()
        for invalid in [
            ASHExecutionRequestV4(
                executor: valid.executor,
                measurementContractID: valid.measurementContractID + ".wrong",
                kernelContractID: valid.kernelContractID,
                directives: valid.directives
            ),
            ASHExecutionRequestV4(
                executor: valid.executor,
                measurementContractID: valid.measurementContractID,
                kernelContractID: valid.kernelContractID + ".wrong",
                directives: valid.directives
            )
        ] {
            XCTAssertThrowsError(
                try ASHExecutionPlannerV4.makePlan(
                    media: ASHV4SemanticArtifactTestSupport.mediaState(),
                    request: invalid,
                    runtime: runtime
                )
            ) { error in
                XCTAssertEqual(
                    error as? ASHExecutionPlanV4Error,
                    .runtimeIdentityMismatch
                )
            }
        }
    }

    func testTamperUnexpectedEntryAndProvenanceTrustFailClosed() throws {
        let bundle = temporaryDirectory.appendingPathComponent("runtime")
        let verified = try ASHV4SemanticArtifactTestSupport.buildAndLoad(at: bundle)
        let trusted = try ASHRuntimeTrustPolicyV4(
            expectedManifestSHA256: verified.manifestSHA256,
            allowedSourceRevisions: [ASHV4SemanticArtifactTestSupport.sourceRevision],
            allowedBuilderSourceSHA256: [ASHV4SemanticArtifactTestSupport.builderHash]
        )

        let unexpected = bundle.appendingPathComponent("artifacts/unowned.bin")
        try Data("unowned".utf8).write(to: unexpected)
        XCTAssertThrowsError(
            try ASHP06RuntimeBundleLoaderV4.load(
                at: bundle,
                trustPolicy: trusted,
                metalLibraryValidator: ASHV4FixtureMetalValidator()
            )
        )
        try FileManager.default.removeItem(at: unexpected)

        let operatorURL = bundle.appendingPathComponent(
            ASHRuntimeArtifactRoleV4.operatorBank.canonicalRelativePath
        )
        var altered = try Data(contentsOf: operatorURL)
        altered[altered.startIndex] ^= 1
        try altered.write(to: operatorURL)
        XCTAssertThrowsError(
            try ASHP06RuntimeBundleLoaderV4.load(
                at: bundle,
                trustPolicy: trusted,
                metalLibraryValidator: ASHV4FixtureMetalValidator()
            )
        )

        let cleanBundle = temporaryDirectory.appendingPathComponent("clean")
        let clean = try ASHV4SemanticArtifactTestSupport.buildAndLoad(at: cleanBundle)
        let wrongProvenance = try ASHRuntimeTrustPolicyV4(
            expectedManifestSHA256: clean.manifestSHA256,
            allowedSourceRevisions: [String(repeating: "b", count: 40)],
            allowedBuilderSourceSHA256: [ASHV4SemanticArtifactTestSupport.builderHash]
        )
        XCTAssertThrowsError(
            try ASHP06RuntimeBundleLoaderV4.load(
                at: cleanBundle,
                trustPolicy: wrongProvenance,
                metalLibraryValidator: ASHV4FixtureMetalValidator()
            )
        ) { error in
            XCTAssertEqual(
                error as? ASHP06RuntimeBundleV4Error,
                .untrustedSourceRevision(
                    ASHV4SemanticArtifactTestSupport.sourceRevision
                )
            )
        }
    }

    func testCanonicalEventEnvelopeRejectsUnstableOrdering() throws {
        let first = ASHSHA256V4(rawData: Data("first".utf8))
        let second = ASHSHA256V4(rawData: Data("second".utf8))
        XCTAssertThrowsError(
            try ASHRuntimeEventEnvelopeV4(
                attemptID: "attempt-1",
                ordinal: 7,
                kind: .verification,
                severity: .error,
                code: "pixel-mismatch",
                recoveryDisposition: .failJob,
                parentEventSHA256: Array([second, first].sorted().reversed()),
                planSHA256: first,
                runtimeManifestSHA256: second,
                trackID: "video-main",
                frameIndex: 42,
                presentationTime: try ExactRationalV4(7, 5),
                fields: []
            )
        )
    }
}
