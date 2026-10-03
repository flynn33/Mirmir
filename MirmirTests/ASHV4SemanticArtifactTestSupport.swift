import Foundation
import Metal
@testable import Mirmir

struct ASHV4FixtureMetalValidator: ASHMetalLibraryValidatingV4 {
    func validateExecutableMetalLibrary(_ data: Data) throws {
        guard data.starts(with: Data("MTLB-fixture-executable".utf8)) else {
            throw ASHP06RuntimeBundleV4Error.invalidMetalLibrary
        }
    }
}

enum ASHV4SemanticArtifactTestSupport {
    static let sourceRevision = String(repeating: "a", count: 40)
    static let expectedPlanSHA256 =
        "96fc21570bd6adcb2f3a4856449e035537d80bd5d556b58e6f2db6efe9b26fb3"
    static let builderHash = ASHSHA256V4(
        rawData: Data("ash-p06-builder-source-v1".utf8)
    )

    static func completeRequest(
        releaseStatus: ASHRuntimeReleaseStatusV4 = .releaseQualified,
        metalLibrary: Data = Data("MTLB-fixture-executable-v1".utf8)
    ) throws -> ASHP06RuntimeBuildRequestV4 {
        let toolchain = ASHRuntimeToolchainV4(
            swiftCompilerIdentity: "apple-swift-6.2.0",
            metalCompilerIdentity: "apple-metal-32023.98",
            metalLanguageVersion: "metal3.2",
            sdkBuildIdentity: "macosx26.2-25C52",
            deploymentTarget: "macos-15.4",
            targetTriple: "arm64-apple-macos15.4"
        )

        var artifacts = try ASHP06CanonicalRuntimeArtifactsV4.make(
            metalLibrary: metalLibrary,
            toolchain: toolchain
        )
        // Deliberately reverse input order. Bundle order comes only from the
        // locked role order, never caller or filesystem enumeration order.
        artifacts.reverse()
        return ASHP06RuntimeBuildRequestV4(
            releaseStatus: releaseStatus,
            provenance: ASHP06RuntimeBuildProvenanceV4(
                sourceRevision: sourceRevision,
                builderID: "ash-p06-runtime-builder-v4-1",
                builderSourceSHA256: builderHash,
                buildParametersSHA256: ASHSHA256V4(
                    rawData: Data("p06-build-parameters-v1".utf8)
                ),
                toolchain: toolchain
            ),
            artifacts: artifacts
        )
    }

    static func buildAndLoad(at url: URL) throws -> ASHVerifiedRuntimeBundleV4 {
        let result = try ASHP06RuntimeBundleBuilderV4.build(
            completeRequest(),
            at: url,
            metalLibraryValidator: ASHV4FixtureMetalValidator()
        )
        return try ASHP06RuntimeBundleLoaderV4.load(
            at: url,
            trustPolicy: ASHRuntimeTrustPolicyV4(
                expectedManifestSHA256: result.manifestSHA256,
                allowedSourceRevisions: [sourceRevision],
                allowedBuilderSourceSHA256: [builderHash]
            ),
            metalLibraryValidator: ASHV4FixtureMetalValidator()
        )
    }

    /// Builds a release-status fixture around the exact metallib produced by
    /// the current app target. This exercises the same byte loader used in
    /// production while keeping test trust roots explicit and ephemeral.
    static func executableSystemMetalRuntime() throws
        -> ASHVerifiedRuntimeBundleV4 {
        guard let libraryURL = Bundle.main.url(
            forResource: "default",
            withExtension: "metallib"
        ) else {
            throw ASHP06RuntimeBundleV4Error.missingBundleEntry(
                "default.metallib"
            )
        }
        let metalLibrary = try Data(contentsOf: libraryURL)
        let validator = try ASHSystemMetalLibraryValidatorV4()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ash-p06-system-metal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = try completeRequest(metalLibrary: metalLibrary)
        let result = try ASHP06RuntimeBundleBuilderV4.build(
            request,
            at: directory,
            metalLibraryValidator: validator
        )
        return try ASHP06RuntimeBundleLoaderV4.load(
            at: directory,
            trustPolicy: ASHRuntimeTrustPolicyV4(
                expectedManifestSHA256: result.manifestSHA256,
                allowedSourceRevisions: [sourceRevision],
                allowedBuilderSourceSHA256: [builderHash]
            ),
            metalLibraryValidator: validator
        )
    }

    static func mediaState() throws -> CanonicalMediaStateV4 {
        let video = CanonicalVideoStateV4(
            encodedRaster: CanonicalRasterV4(width: 640, height: 360),
            presentationRaster: CanonicalRasterV4(width: 640, height: 360),
            preferredTransform: .identity,
            cleanAperture: nil,
            pixelAspectRatio: .one,
            pixel: CanonicalPixelStateV4(
                formatID: "nv12-video-range-8",
                bitDepth: 8,
                range: .video,
                chromaSubsampling: .yuv420,
                chromaSiting: .left,
                alphaModel: .none
            ),
            color: colorState(),
            scan: CanonicalScanStateV4(
                fieldCount: 1,
                dominance: .none,
                cadence: .progressive
            )
        )
        let duration = try ExactRationalV4(10)
        let timebase = try ExactRationalV4(1, 30_000)
        let tracks = [
            CanonicalMediaTrackV4(
                identity: CanonicalTrackIdentityV4(
                    ordinal: 0,
                    persistentID: "video-main"
                ),
                enabled: true,
                kind: .video,
                languageTag: nil,
                roleIDs: ["main"],
                codecID: "avc1",
                timebase: timebase,
                duration: duration,
                edits: [],
                metadata: [],
                video: video
            ),
            CanonicalMediaTrackV4(
                identity: CanonicalTrackIdentityV4(
                    ordinal: 1,
                    persistentID: "video-angle-b"
                ),
                enabled: true,
                kind: .video,
                languageTag: nil,
                roleIDs: ["alternate"],
                codecID: "avc1",
                timebase: timebase,
                duration: duration,
                edits: [],
                metadata: [],
                video: video
            ),
            CanonicalMediaTrackV4(
                identity: CanonicalTrackIdentityV4(
                    ordinal: 2,
                    persistentID: "audio-en"
                ),
                enabled: true,
                kind: .audio,
                languageTag: "en-US",
                roleIDs: ["main"],
                codecID: "aac-lc",
                timebase: try ExactRationalV4(1, 48_000),
                duration: duration,
                edits: [],
                metadata: [],
                video: nil
            ),
            CanonicalMediaTrackV4(
                identity: CanonicalTrackIdentityV4(
                    ordinal: 3,
                    persistentID: "captions-en"
                ),
                enabled: true,
                kind: .caption,
                languageTag: "en-US",
                roleIDs: ["accessibility"],
                codecID: "cea-608",
                timebase: timebase,
                duration: duration,
                edits: [],
                metadata: [],
                video: nil
            )
        ]
        return try CanonicalMediaStateV4(
            input: CanonicalInputIdentityV4(
                contentSHA256: ASHSHA256V4(rawData: Data("input-media".utf8)),
                byteCount: 1_234_567,
                fileName: "fixture.mov",
                bookmarkReference: "bookmark-fixture-v1",
                bookmarkDocumentSHA256: ASHSHA256V4(
                    rawData: Data("bookmark-document".utf8)
                )
            ),
            tracks: tracks,
            observations: []
        )
    }

    static func executionRequest() -> ASHExecutionRequestV4 {
        ASHExecutionRequestV4(
            executor: .metalFixedPoint,
            measurementContractID:
                ASHExecutionRequestV4.canonicalMeasurementContractID,
            kernelContractID: ASHExecutionRequestV4.canonicalKernelContractID,
            directives: [
                ASHTrackDirectiveV4(
                    trackID: "audio-en",
                    action: .passThrough,
                    videoOutput: nil,
                    outputCodecID: nil,
                    dropReasonID: nil,
                    dropApprovalSHA256: nil
                ),
                ASHTrackDirectiveV4(
                    trackID: "captions-en",
                    action: .passThrough,
                    videoOutput: nil,
                    outputCodecID: nil,
                    dropReasonID: nil,
                    dropApprovalSHA256: nil
                ),
                ASHTrackDirectiveV4(
                    trackID: "video-angle-b",
                    action: .passThrough,
                    videoOutput: nil,
                    outputCodecID: nil,
                    dropReasonID: nil,
                    dropApprovalSHA256: nil
                ),
                ASHTrackDirectiveV4(
                    trackID: "video-main",
                    action: .processVideo,
                    videoOutput: ASHVideoOutputContractV4(
                        raster: CanonicalRasterV4(width: 1_001, height: 563),
                        codecID: "hevc",
                        encodedFormatDescriptor: try! MediaTrackFormatDescriptorV4(
                            ordinal: 0,
                            mediaTypeID: "fourcc_76696465",
                            mediaSubtypeID: "fourcc_68766331",
                            canonicalFingerprint: ASHSHA256V4(
                                rawData: Data("semantic-hevc-format".utf8)
                            ),
                            completeness: .complete,
                            videoRaster: CanonicalRasterV4(
                                width: 1_001,
                                height: 563
                            )
                        ),
                        pixelFormatID: "nv12-video-range-8",
                        bitDepth: 8,
                        range: .video,
                        chromaSubsampling: .yuv420,
                        chromaSiting: .left,
                        alphaModel: .none,
                        color: colorState()
                    ),
                    outputCodecID: nil,
                    dropReasonID: nil,
                    dropApprovalSHA256: nil
                )
            ]
        )
    }

    static func planHash(runtime: ASHVerifiedRuntimeBundleV4) throws -> String {
        try ASHExecutionPlannerV4.makePlan(
            media: mediaState(),
            request: executionRequest(),
            runtime: runtime
        ).planSHA256.rawValue
    }

    static func bundleFiles(at bundle: URL) throws -> [String: Data] {
        let enumerator = FileManager.default.enumerator(atPath: bundle.path)!
        var result: [String: Data] = [:]
        for case let relative as String in enumerator {
            let url = bundle.appendingPathComponent(relative)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
               !isDirectory.boolValue {
                result[relative] = try Data(contentsOf: url)
            }
        }
        return result
    }

    private static func colorState() -> CanonicalColorStateV4 {
        CanonicalColorStateV4(
            primaries: "itu-r-bt709-2",
            transferFunction: "itu-r-bt709-2",
            matrix: "itu-r-bt709-2",
            masteringDisplay: nil,
            contentLightLevel: nil,
            dynamicHDRMetadata: []
        )
    }
}
