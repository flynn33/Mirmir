import CryptoKit
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

    func testSHA256EncodingMatchesPublishedVectors() {
        for (input, expected) in [
            ("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
            ("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
            (String(repeating: "a", count: 1_000_000),
             "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
        ] {
            XCTAssertEqual(ASHSHA256V4(rawData: Data(input.utf8)).rawValue, expected)
        }
    }

    func testSHA256EncodingMatchesEveryTwoBytePCMPayload() {
        var combined = SHA256()
        for value in UInt32(0)...UInt32(UInt16.max) {
            let payload = Data([UInt8(value >> 8), UInt8(value & 0xff)])
            combined.update(data: Data(ASHSHA256V4(rawData: payload).rawValue.utf8))
        }
        // Independent Python hashlib reference over all 65,536 lowercase
        // payload digests, in unsigned big-endian payload order.
        XCTAssertEqual(
            combined.finalize().map { String(format: "%02x", $0) }.joined(),
            "f08b75e978ea60ad5c8b73e6d266d9d5078c6173dca8fd6d8ba9f7b3f0c476cf"
        )
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
        XCTAssertEqual(
            try first.benchmarkCorpusIdentity().routes.count,
            4
        )
        XCTAssertEqual(
            try first.qualityCorpusIdentity().caseCount,
            168
        )
        XCTAssertEqual(
            try first.metricContract().minimumQualityIndex,
            105
        )
        XCTAssertEqual(
            try first.metricContract().maximumProcessingTimeRatio,
            try ExactRationalV4(4, 5)
        )
        XCTAssertEqual(
            try first.phaseCoefficientProcedure().kernelContractID,
            FixedPointCoefficientCompilerV4.procedureID
        )
        XCTAssertTrue(
            try first.verificationContract().cpuMetalByteIdentityRequired
        )
        XCTAssertEqual(
            Set(try first.verificationContract().requiredRules.map(\.rawValue)),
            Set(ASHVerificationRuleV4.allCases.map(\.rawValue))
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
        XCTAssertEqual(
            plan.plan.reconstructionOutputRule,
            .conditionedFixedPointBlend
        )
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

    func testProRes422SubtypeIsBoundIntoVerifiedPlanIdentity() throws {
        let runtime = try ASHV4SemanticArtifactTestSupport.buildAndLoad(
            at: temporaryDirectory.appendingPathComponent("prores-plan-runtime")
        )
        let original = ASHV4SemanticArtifactTestSupport.executionRequest()
        let raster = CanonicalRasterV4(width: 1_000, height: 562)
        let proResOutput = ASHVideoOutputContractV4(
            raster: raster,
            codecID: OutputCodec.proRes422.rawValue,
            encodedFormatDescriptor: try MediaTrackFormatDescriptorV4(
                ordinal: 0,
                mediaTypeID: "fourcc_76696465",
                mediaSubtypeID: "fourcc_6170636e",
                canonicalFingerprint: ASHSHA256V4(
                    rawData: Data("semantic-prores422-format".utf8)
                ),
                completeness: .complete,
                videoRaster: raster
            ),
            pixelFormatID: PixelStorageV4.nv12VideoRange8Bit.rawValue,
            bitDepth: 8,
            range: .video,
            chromaSubsampling: .yuv420,
            chromaSiting: .left,
            alphaModel: .none,
            color: try ASHV4SemanticArtifactTestSupport.mediaState()
                .tracks[0].video!.color
        )
        let request = ASHExecutionRequestV4(
            executor: original.executor,
            measurementContractID: original.measurementContractID,
            kernelContractID: original.kernelContractID,
            directives: original.directives.map { directive in
                guard directive.trackID == "video-main" else {
                    return directive
                }
                return ASHTrackDirectiveV4(
                    trackID: directive.trackID,
                    action: .processVideo,
                    videoOutput: proResOutput,
                    outputCodecID: nil,
                    dropReasonID: nil,
                    dropApprovalSHA256: nil
                )
            }
        )

        let plan = try ASHExecutionPlannerV4.makePlan(
            media: ASHV4SemanticArtifactTestSupport.mediaState(),
            request: request,
            runtime: runtime
        )
        try plan.verify()
        let processed = try XCTUnwrap(plan.plan.tracks.first {
            $0.sourceIdentity.persistentID == "video-main"
        })
        XCTAssertEqual(processed.outputCodecID, "proRes422")
        XCTAssertEqual(
            processed.videoOutput?.encodedFormatDescriptor.mediaSubtypeID,
            "fourcc_6170636e"
        )
        XCTAssertNotEqual(
            plan.planSHA256,
            try ASHExecutionPlannerV4.makePlan(
                media: ASHV4SemanticArtifactTestSupport.mediaState(),
                request: original,
                runtime: runtime
            ).planSHA256
        )

        let mismatchedOutput = ASHVideoOutputContractV4(
            raster: raster,
            codecID: proResOutput.codecID,
            encodedFormatDescriptor: try MediaTrackFormatDescriptorV4(
                ordinal: 0,
                mediaTypeID: "fourcc_76696465",
                mediaSubtypeID: "fourcc_68766331",
                canonicalFingerprint:
                    proResOutput.encodedFormatDescriptor.canonicalFingerprint,
                completeness: .complete,
                videoRaster: raster
            ),
            pixelFormatID: proResOutput.pixelFormatID,
            bitDepth: proResOutput.bitDepth,
            range: proResOutput.range,
            chromaSubsampling: proResOutput.chromaSubsampling,
            chromaSiting: proResOutput.chromaSiting,
            alphaModel: proResOutput.alphaModel,
            color: proResOutput.color
        )
        let mismatchedRequest = ASHExecutionRequestV4(
            executor: request.executor,
            measurementContractID: request.measurementContractID,
            kernelContractID: request.kernelContractID,
            directives: request.directives.map { directive in
                guard directive.trackID == "video-main" else {
                    return directive
                }
                return ASHTrackDirectiveV4(
                    trackID: directive.trackID,
                    action: directive.action,
                    videoOutput: mismatchedOutput,
                    outputCodecID: nil,
                    dropReasonID: nil,
                    dropApprovalSHA256: nil
                )
            }
        )
        XCTAssertThrowsError(try ASHExecutionPlannerV4.makePlan(
            media: ASHV4SemanticArtifactTestSupport.mediaState(),
            request: mismatchedRequest,
            runtime: runtime
        ))
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

    func testTypedCorpusMetricKernelAndVerificationTamperFailClosed() throws {
        let cases: [(
            role: ASHRuntimeArtifactRoleV4,
            original: String,
            replacement: String,
            expected: ASHP06RuntimeBundleV4Error
        )] = [
            (
                .benchmarkCorpusIdentity,
                "\"measuredSampleCount\":10",
                "\"measuredSampleCount\":11",
                .benchmarkCorpusIdentityMismatch
            ),
            (
                .qualityCorpusIdentity,
                "\"caseCount\":168",
                "\"caseCount\":169",
                .qualityCorpusIdentityMismatch
            ),
            (
                .metricContract,
                "\"minimumQualityIndex\":105",
                "\"minimumQualityIndex\":104",
                .metricContractMismatch
            ),
            (
                .phaseCoefficientProcedure,
                "\"fractionalBits\":14",
                "\"fractionalBits\":13",
                .phaseCoefficientProcedureMismatch
            ),
            (
                .verificationContract,
                "\"visiblePixelMismatchAllowance\":0",
                "\"visiblePixelMismatchAllowance\":1",
                .verificationContractMismatch
            )
        ]
        for (index, testCase) in cases.enumerated() {
            let original = try ASHV4SemanticArtifactTestSupport
                .completeRequest()
            let artifacts = original.artifacts.map { artifact in
                guard artifact.role == testCase.role else { return artifact }
                let text = String(decoding: artifact.data, as: UTF8.self)
                let replaced = text.replacingOccurrences(
                    of: testCase.original,
                    with: testCase.replacement
                )
                XCTAssertNotEqual(text, replaced)
                return ASHP06RuntimeArtifactInputV4(
                    role: artifact.role,
                    data: Data(replaced.utf8)
                )
            }
            let request = ASHP06RuntimeBuildRequestV4(
                releaseStatus: original.releaseStatus,
                provenance: original.provenance,
                artifacts: artifacts
            )
            XCTAssertThrowsError(
                try ASHP06RuntimeBundleBuilderV4.build(
                    request,
                    at: temporaryDirectory.appendingPathComponent(
                        "typed-tamper-\(index)"
                    ),
                    metalLibraryValidator: ASHV4FixtureMetalValidator()
                )
            ) { error in
                XCTAssertEqual(
                    error as? ASHP06RuntimeBundleV4Error,
                    testCase.expected
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
