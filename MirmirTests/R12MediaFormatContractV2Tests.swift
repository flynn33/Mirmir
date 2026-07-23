import CryptoKit
import XCTest
@testable import Mirmir

// swiftlint:disable file_length

final class R12MediaFormatContractV2Tests: XCTestCase {
    func testFixtureCatalogCoversDeclaredExpansionWithoutNativeAuthority() {
        let fixtures = R12MediaFormatFixtureCatalogV2.all

        XCTAssertEqual(fixtures.count, 7)
        XCTAssertEqual(
            Set(fixtures.map(\.format.sampling.storage)),
            Set(R12PixelStorageV2.allCases)
        )
        XCTAssertEqual(
            Set(fixtures.map(\.format.color.transferFunction)),
            Set(R12TransferFunctionV2.allCases)
        )
        XCTAssertTrue(fixtures.contains { $0.format.scan.scanStructure.isInterlaced })
        XCTAssertTrue(fixtures.contains { $0.format.alphaSemantics == .straight })
        XCTAssertTrue(fixtures.allSatisfy {
            $0.evidence.basis == .deterministicContract
                && $0.evidence.fixtureID != nil
                && $0.evidence.nativeObservationSHA256 == nil
        })
        XCTAssertTrue(fixtures.allSatisfy {
            $0.authority == .formatExpansionOnly
        })
    }

    func testMetadataAndStructuralQualityContractsAreExplicit() {
        let sdr = R12MediaFormatFixtureCatalogV2.nv12SDR
        let hdr = R12MediaFormatFixtureCatalogV2.p010PQ
        let alpha = R12MediaFormatFixtureCatalogV2.planar444Alpha

        XCTAssertEqual(sdr.metadata.audioMetadata, .preserveIfPresent)
        XCTAssertEqual(sdr.metadata.orientation, .preserveIfPresent)
        XCTAssertEqual(sdr.metadata.cleanAperture, .preserveIfPresent)
        XCTAssertEqual(sdr.metadata.pixelAspectRatio, .preserveIfPresent)
        XCTAssertEqual(sdr.metadata.displayMetadata, .notApplicable)
        XCTAssertEqual(sdr.metadata.contentLightLevel, .notApplicable)
        XCTAssertEqual(hdr.metadata.displayMetadata, .preserveIfPresent)
        XCTAssertEqual(hdr.metadata.contentLightLevel, .preserveIfPresent)
        XCTAssertEqual(alpha.quality.alpha, .exact)
        XCTAssertEqual(sdr.quality.scope, .structuralIntegrityOnly)
        XCTAssertEqual(sdr.quality.exactDimensions, .required)
        XCTAssertEqual(sdr.quality.exactPlaneGeometry, .required)
        XCTAssertEqual(sdr.quality.deterministicDigest, .required)
        XCTAssertEqual(sdr.quality.visibleFallback, .required)
        XCTAssertEqual(sdr.quality.resumeEquivalence, .required)
    }

    func testStorageDepthAndSubsamplingCrossProductsAreRejectedExactly() {
        XCTAssertThrowsError(
            try R12MediaSamplingV2(
                storage: .p010,
                bitDepth: .eight,
                chromaSubsampling: .yuv420,
                codeRange: .video,
                chromaSiting: .left
            )
        ) {
            XCTAssertEqual(
                $0 as? R12MediaFormatContractErrorV2,
                .incompatibleStorage(
                    storage: .p010,
                    bitDepth: .eight,
                    subsampling: .yuv420
                )
            )
        }
        XCTAssertThrowsError(
            try R12MediaSamplingV2(
                storage: .planar422,
                bitDepth: .ten,
                chromaSubsampling: .yuv444,
                codeRange: .full,
                chromaSiting: .notApplicable
            )
        ) {
            XCTAssertEqual(
                $0 as? R12MediaFormatContractErrorV2,
                .incompatibleStorage(
                    storage: .planar422,
                    bitDepth: .ten,
                    subsampling: .yuv444
                )
            )
        }
    }

    func testColorMatrixAndHDRBitDepthAreValidated() throws {
        XCTAssertThrowsError(
            try R12ColorContractV2(
                colorPrimaries: .bt709,
                transferFunction: .bt709,
                yCbCrMatrix: .bt2020NCL
            )
        ) {
            XCTAssertEqual(
                $0 as? R12MediaFormatContractErrorV2,
                .invalidColorMatrix(primaries: .bt709, matrix: .bt2020NCL)
            )
        }

        let eightBit422 = try R12MediaSamplingV2(
            storage: .planar422,
            bitDepth: .eight,
            chromaSubsampling: .yuv422,
            codeRange: .video,
            chromaSiting: .left
        )
        XCTAssertThrowsError(
            try R12MediaFormatDescriptorV2(
                sampling: eightBit422,
                color: .hdrBT2020(transferFunction: .pq),
                scan: .progressive,
                alphaSemantics: .none
            )
        ) {
            XCTAssertEqual(
                $0 as? R12MediaFormatContractErrorV2,
                .hdrRequiresTenBit(.pq)
            )
        }
    }

    func testChromaSitingAndSubsampledDimensionsAreExact() throws {
        XCTAssertThrowsError(
            try R12MediaSamplingV2(
                storage: .planar444,
                bitDepth: .eight,
                chromaSubsampling: .yuv444,
                codeRange: .full,
                chromaSiting: .left
            )
        ) {
            XCTAssertEqual(
                $0 as? R12MediaFormatContractErrorV2,
                .invalidChromaSiting(subsampling: .yuv444, siting: .left)
            )
        }

        let odd = try R12ResolutionV2(width: 1_919, height: 1_079)
        XCTAssertThrowsError(
            try R12MediaFormatFixtureCatalogV2.nv12SDR.format.validate(
                resolution: odd
            )
        ) {
            XCTAssertEqual(
                $0 as? R12MediaFormatContractErrorV2,
                .invalidSubsampledDimensions(
                    subsampling: .yuv420,
                    width: 1_919,
                    height: 1_079
                )
            )
        }

        let evenWidth = try R12ResolutionV2(width: 1_920, height: 1_079)
        XCTAssertNoThrow(
            try R12MediaFormatFixtureCatalogV2.planar422SDR.format.validate(
                resolution: evenWidth
            )
        )
        XCTAssertNoThrow(
            try R12MediaFormatFixtureCatalogV2.planar444HDR.format.validate(
                resolution: odd
            )
        )
    }

    func testScanAndDeinterlacePolicyCannotContradictOneAnother() {
        XCTAssertThrowsError(
            try R12ScanContractV2(
                scanStructure: .progressive,
                deinterlacePolicy: .requiredBeforeUpscale
            )
        ) {
            XCTAssertEqual(
                $0 as? R12MediaFormatContractErrorV2,
                .invalidScanPolicy(
                    scan: .progressive,
                    policy: .requiredBeforeUpscale
                )
            )
        }
        XCTAssertThrowsError(
            try R12ScanContractV2(
                scanStructure: .interlacedBottomFieldFirst,
                deinterlacePolicy: .notRequired
            )
        ) {
            XCTAssertEqual(
                $0 as? R12MediaFormatContractErrorV2,
                .invalidScanPolicy(
                    scan: .interlacedBottomFieldFirst,
                    policy: .notRequired
                )
            )
        }
    }
}

extension R12MediaFormatContractV2Tests {
    func testAlphaRequiresExplicitPlanar444StorageAndQualityPreservation() throws {
        let nv12 = R12MediaFormatFixtureCatalogV2.nv12SDR
        XCTAssertThrowsError(
            try R12MediaFormatDescriptorV2(
                sampling: nv12.format.sampling,
                color: nv12.format.color,
                scan: nv12.format.scan,
                alphaSemantics: .premultiplied
            )
        ) {
            XCTAssertEqual(
                $0 as? R12MediaFormatContractErrorV2,
                .alphaRequiresPlanar444(.premultiplied)
            )
        }

        let alpha = R12MediaFormatFixtureCatalogV2.planar444Alpha
        XCTAssertThrowsError(
            try R12MediaFormatContractV2(
                format: alpha.format,
                metadata: alpha.metadata,
                quality: .preserving(alpha: false),
                evidence: alpha.evidence
            )
        ) {
            XCTAssertEqual(
                $0 as? R12MediaFormatContractErrorV2,
                .structuralQualityMismatch(.alpha)
            )
        }
    }

    func testMetadataRulesRejectSilentHDRAndSubtitleLoss() throws {
        let sdr = R12MediaFormatFixtureCatalogV2.nv12SDR
        XCTAssertThrowsError(
            try R12MediaFormatContractV2(
                format: sdr.format,
                metadata: .hdrPreserving,
                quality: sdr.quality,
                evidence: sdr.evidence
            )
        ) {
            XCTAssertEqual(
                $0 as? R12MediaFormatContractErrorV2,
                .metadataRuleMismatch(.hdrStaticMetadata)
            )
        }

        let invalid = R12MetadataPreservationContractV2(
            colorMetadata: .exact,
            hdrStaticMetadata: .notApplicable,
            hdrDynamicMetadata: .notApplicable,
            audioMetadata: .preserveIfPresent,
            orientation: .preserveIfPresent,
            cleanAperture: .preserveIfPresent,
            pixelAspectRatio: .preserveIfPresent,
            displayMetadata: .notApplicable,
            contentLightLevel: .notApplicable,
            subtitles: .notApplicable,
            timecode: .preserveIfPresent,
            containerMetadata: .preserveIfPresent
        )
        XCTAssertThrowsError(
            try R12MediaFormatContractV2(
                format: sdr.format,
                metadata: invalid,
                quality: sdr.quality,
                evidence: sdr.evidence
            )
        ) {
            XCTAssertEqual(
                $0 as? R12MediaFormatContractErrorV2,
                .metadataRuleMismatch(.subtitles)
            )
        }
    }

    func testEveryMetadataInvariantRejectsAContradictoryRule() throws {
        let fixture = R12MediaFormatFixtureCatalogV2.nv12SDR

        for field in R12MetadataFieldV2.allCases {
            let current = metadataRule(field, in: fixture.metadata)
            let contradictory: R12PreservationRuleV2
            switch current {
            case .exact:
                contradictory = .notApplicable
            case .preserveIfPresent:
                contradictory = .exact
            case .notApplicable:
                contradictory = .preserveIfPresent
            }
            let metadata = replacing(
                field,
                with: contradictory,
                in: fixture.metadata
            )

            XCTAssertThrowsError(
                try R12MediaFormatContractV2(
                    format: fixture.format,
                    metadata: metadata,
                    quality: fixture.quality,
                    evidence: fixture.evidence
                ),
                "Expected \(field.rawValue) to fail closed"
            ) {
                XCTAssertEqual(
                    $0 as? R12MediaFormatContractErrorV2,
                    .metadataRuleMismatch(field)
                )
            }
        }
    }

    func testEveryConstructibleStructuralWeakeningIsRejected() throws {
        typealias Quality = R12StructuralQualityContractV2
        let weakened: [(
            field: R12StructuralQualityFieldV2,
            construct: () throws -> Quality
        )] = [
            (.frameCount, {
                try Quality(frameCount: .preserveIfPresent, alpha: .notApplicable)
            }),
            (.presentationTimeline, {
                try Quality(
                    presentationTimeline: .preserveIfPresent,
                    alpha: .notApplicable
                )
            }),
            (.audioTracks, {
                try Quality(audioTracks: .notApplicable, alpha: .notApplicable)
            }),
            (.subtitleTracks, {
                try Quality(subtitleTracks: .notApplicable, alpha: .notApplicable)
            }),
            (.metadata, {
                try Quality(metadata: .preserveIfPresent, alpha: .notApplicable)
            }),
            (.alpha, {
                try Quality(alpha: .preserveIfPresent)
            }),
            (.outputReopen, {
                try Quality(alpha: .notApplicable, outputReopen: .notApplicable)
            }),
            (.exactDimensions, {
                try Quality(
                    alpha: .notApplicable,
                    exactDimensions: .notApplicable
                )
            }),
            (.exactPlaneGeometry, {
                try Quality(
                    alpha: .notApplicable,
                    exactPlaneGeometry: .notApplicable
                )
            }),
            (.deterministicDigest, {
                try Quality(
                    alpha: .notApplicable,
                    deterministicDigest: .notApplicable
                )
            }),
            (.visibleFallback, {
                try Quality(
                    alpha: .notApplicable,
                    visibleFallback: .notApplicable
                )
            }),
            (.resumeEquivalence, {
                try Quality(
                    alpha: .notApplicable,
                    resumeEquivalence: .notApplicable
                )
            })
        ]

        XCTAssertEqual(
            Set(weakened.map(\.field)),
            Set(R12StructuralQualityFieldV2.allCases).subtracting([.scope])
        )
        for entry in weakened {
            XCTAssertThrowsError(try entry.construct()) {
                XCTAssertEqual(
                    $0 as? R12MediaFormatContractErrorV2,
                    .structuralQualityMismatch(entry.field)
                )
            }
        }
        XCTAssertEqual(
            Quality.preserving(alpha: false).scope,
            .structuralIntegrityOnly
        )
    }

    func testEvidenceFactoriesPreventFixturePromotionToNativeObservation() throws {
        let fixture = try R12FormatEvidenceV2.deterministicContract(
            fixtureID: "fixture-p010"
        )
        XCTAssertEqual(fixture.basis, .deterministicContract)
        XCTAssertEqual(fixture.fixtureID, "fixture-p010")
        XCTAssertNil(fixture.nativeObservationSHA256)

        for invalid in [
            String(repeating: "0", count: 64),
            String(repeating: "AB", count: 32),
            "abc"
        ] {
            XCTAssertThrowsError(
                try R12FormatEvidenceV2.nativeObserved(
                    observationSHA256: invalid
                )
            ) {
                XCTAssertEqual(
                    ($0 as? R12MediaFormatContractErrorV2)?.machineCode,
                    "invalid_sha256_native_observation"
                )
            }
        }

        let digest = String(repeating: "ab", count: 32)
        let native = try R12FormatEvidenceV2.nativeObserved(
            observationSHA256: digest
        )
        XCTAssertEqual(native.basis, .nativeObserved)
        XCTAssertNil(native.fixtureID)
        XCTAssertEqual(native.nativeObservationSHA256, digest)
    }

    func testBackendCapabilityIsExactSortedAndEvidenceBound() throws {
        let fixtures = R12MediaFormatFixtureCatalogV2.all
        let evidence = try R12FormatEvidenceV2.deterministicContract(
            fixtureID: "backend-contract"
        )
        let forward = try R12BackendFormatCapabilityV2(
            backendID: "r12.fixture-backend",
            supportedFormats: fixtures,
            evidence: evidence
        )
        let reverse = try R12BackendFormatCapabilityV2(
            backendID: "r12.fixture-backend",
            supportedFormats: fixtures.reversed(),
            evidence: evidence
        )

        XCTAssertEqual(forward, reverse)
        XCTAssertEqual(forward.canonicalData, reverse.canonicalData)
        XCTAssertEqual(forward.canonicalSHA256, reverse.canonicalSHA256)
        XCTAssertEqual(
            forward.canonicalSHA256,
            "a2b540c86290ad1e74c185f625001302e81b134f3a729670197b37aedba26b1c"
        )
        XCTAssertEqual(
            forward.supportedFormats.map(\.canonicalSHA256),
            forward.supportedFormats.map(\.canonicalSHA256).sorted()
        )
        XCTAssertTrue(forward.supports(R12MediaFormatFixtureCatalogV2.p010PQ))
        XCTAssertTrue(
            forward.supports(R12MediaFormatFixtureCatalogV2.p010PQ.format)
        )

        XCTAssertThrowsError(
            try R12BackendFormatCapabilityV2(
                backendID: "r12.empty",
                supportedFormats: [],
                evidence: evidence
            )
        ) {
            XCTAssertEqual(
                $0 as? R12MediaFormatContractErrorV2,
                .noSupportedFormats
            )
        }
        XCTAssertThrowsError(
            try R12BackendFormatCapabilityV2(
                backendID: "r12.duplicate",
                supportedFormats: [fixtures[0], fixtures[0]],
                evidence: evidence
            )
        ) {
            XCTAssertEqual(
                ($0 as? R12MediaFormatContractErrorV2)?.machineCode,
                "duplicate_supported_format"
            )
        }
    }

    func testBackendCapabilityRejectsEvidencePromotionAndUnsupportedFormat() throws {
        let deterministic = R12MediaFormatFixtureCatalogV2.nv12SDR
        let nativeEvidence = try R12FormatEvidenceV2.nativeObserved(
            observationSHA256: String(repeating: "cd", count: 32)
        )
        let nativeContract = try R12MediaFormatContractV2(
            format: deterministic.format,
            metadata: deterministic.metadata,
            quality: deterministic.quality,
            evidence: nativeEvidence
        )
        let deterministicEvidence = try R12FormatEvidenceV2.deterministicContract(
            fixtureID: "backend-deterministic"
        )
        XCTAssertThrowsError(
            try R12BackendFormatCapabilityV2(
                backendID: "r12.invalid-promotion",
                supportedFormats: [nativeContract],
                evidence: deterministicEvidence
            )
        ) {
            XCTAssertEqual(
                $0 as? R12MediaFormatContractErrorV2,
                .evidenceBasisMismatch
            )
        }

        let capability = try R12BackendFormatCapabilityV2(
            backendID: "r12.nv12-only",
            supportedFormats: [deterministic],
            evidence: deterministicEvidence
        )
        let unsupported = R12MediaFormatFixtureCatalogV2.p010PQ
        XCTAssertFalse(capability.supports(unsupported))
        XCTAssertThrowsError(try capability.requireSupport(for: unsupported)) {
            XCTAssertEqual(
                $0 as? R12MediaFormatContractErrorV2,
                .unsupportedFormat(unsupported.canonicalSHA256)
            )
        }
    }

    func testCanonicalContractCarriesOnlyNonAuthorizingBoundaries() throws {
        let contract = R12MediaFormatFixtureCatalogV2.p010PQ
        let text = try XCTUnwrap(String(data: contract.canonicalData, encoding: .utf8))

        XCTAssertTrue(text.contains(#""product_admission":"not_authorized""#))
        XCTAssertTrue(text.contains(#""production_auto_mode":"not_authorized""#))
        XCTAssertTrue(text.contains(#""release_publication":"not_authorized""#))
        XCTAssertTrue(text.contains(#""market_claim":"no_market_claim""#))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("comparison"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("a/b"))
        XCTAssertEqual(
            contract.canonicalSHA256,
            "f34bdb490f79292d9b0081c3da3c17598f8346161164475ae04d1b2c3dc521dc"
        )
    }

    func testV2IsAdditiveAndHistoricalV1BytesStillReopenExactly() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: repositoryRoot.appendingPathComponent(
            "validation/calibration_v2/contracts/video-profile-contract-v1.json"
        ))
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()

        XCTAssertEqual(
            digest,
            "8c61d53cab158838e559b81a1d0c6b65ecc734a61ade76f84d41c92187214ef3"
        )
        let expected = try ASHLUTHashV2(hex: digest)
        let contract = try ASHVideoProfileContractV1.load(
            data,
            expectedSHA256: expected
        )
        XCTAssertEqual(contract.immutableBytes, data)
        XCTAssertEqual(contract.canonicalInstances.count, 12)
    }
}

private extension R12MediaFormatContractV2Tests {
    func metadataRule(
        _ field: R12MetadataFieldV2,
        in contract: R12MetadataPreservationContractV2
    ) -> R12PreservationRuleV2 {
        switch field {
        case .colorMetadata: contract.colorMetadata
        case .hdrStaticMetadata: contract.hdrStaticMetadata
        case .hdrDynamicMetadata: contract.hdrDynamicMetadata
        case .audioMetadata: contract.audioMetadata
        case .orientation: contract.orientation
        case .cleanAperture: contract.cleanAperture
        case .pixelAspectRatio: contract.pixelAspectRatio
        case .displayMetadata: contract.displayMetadata
        case .contentLightLevel: contract.contentLightLevel
        case .subtitles: contract.subtitles
        case .timecode: contract.timecode
        case .containerMetadata: contract.containerMetadata
        }
    }

    func replacing(
        _ field: R12MetadataFieldV2,
        with rule: R12PreservationRuleV2,
        in contract: R12MetadataPreservationContractV2
    ) -> R12MetadataPreservationContractV2 {
        R12MetadataPreservationContractV2(
            colorMetadata: field == .colorMetadata
                ? rule : contract.colorMetadata,
            hdrStaticMetadata: field == .hdrStaticMetadata
                ? rule : contract.hdrStaticMetadata,
            hdrDynamicMetadata: field == .hdrDynamicMetadata
                ? rule : contract.hdrDynamicMetadata,
            audioMetadata: field == .audioMetadata
                ? rule : contract.audioMetadata,
            orientation: field == .orientation
                ? rule : contract.orientation,
            cleanAperture: field == .cleanAperture
                ? rule : contract.cleanAperture,
            pixelAspectRatio: field == .pixelAspectRatio
                ? rule : contract.pixelAspectRatio,
            displayMetadata: field == .displayMetadata
                ? rule : contract.displayMetadata,
            contentLightLevel: field == .contentLightLevel
                ? rule : contract.contentLightLevel,
            subtitles: field == .subtitles
                ? rule : contract.subtitles,
            timecode: field == .timecode
                ? rule : contract.timecode,
            containerMetadata: field == .containerMetadata
                ? rule : contract.containerMetadata
        )
    }
}
