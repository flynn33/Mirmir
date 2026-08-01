import Darwin
import Foundation
import CoreMedia
import XCTest
@testable import Mirmir

final class R13ReleaseModePolicyTests: XCTestCase {
    func testPublicModeCatalogKeepsAutoVisible() {
        XCTAssertEqual(
            UpscaleMode.allCases,
            [.auto, .quality, .fast, .deterministic, .smoothMotion]
        )
        XCTAssertEqual(UpscaleMode.allCases.map(\.id), [
            "auto",
            "quality",
            "fast",
            "deterministic",
            "smooth_motion"
        ])
    }

    func testUpscaleJobDefaultsToDeterministicWithoutChangingExistingCallers() {
        let job = UpscaleJob(
            inputURL: URL(fileURLWithPath: "/tmp/r13-input.mp4"),
            outputURL: URL(fileURLWithPath: "/tmp/r13-output.mp4"),
            targetResolution: .p2160
        )

        XCTAssertEqual(job.mode, .deterministic)
        XCTAssertTrue(
            AtomicMediaOutput.isValidTemporaryIdentifier(job.identifier)
        )
    }

    func testAutoIsAvailableAndRetainsItsOwnASHOrchestrationIdentity() {
        XCTAssertEqual(
            R13ReleaseModePolicy.availability(for: .auto),
            .available
        )

        let auto = R13ReleaseModePolicy.binding(for: .auto)
        let quality = R13ReleaseModePolicy.binding(for: .quality)

        XCTAssertEqual(auto.requestedMode, .auto)
        XCTAssertEqual(auto.effectiveMode, .auto)
        XCTAssertEqual(auto.scalerKind, .highQualityVImage)
        XCTAssertEqual(auto.orchestrationKind, .automatic)
        XCTAssertTrue(auto.usesProductOrchestration)
        XCTAssertEqual(auto.capabilityID, "R13-ASH-AUTO")
        XCTAssertEqual(auto.backendID, "r13.ash.auto")
        XCTAssertEqual(auto.backendRevision, quality.backendRevision)
        XCTAssertNotEqual(auto.capabilityID, quality.capabilityID)
        XCTAssertNotEqual(auto.backendID, quality.backendID)
        XCTAssertNotEqual(auto.policyIdentity, quality.policyIdentity)
        XCTAssertNotEqual(
            auto.materialDecisionIdentity,
            quality.materialDecisionIdentity
        )
    }

    func testQualityFastAndDeterministicMapToDistinctScalerIdentities() {
        struct Expected {
            let mode: UpscaleMode
            let scalerKind: R13ReleaseScalerKind
            let orchestrationKind: R13ReleaseOrchestrationKind
            let capabilityID: String
            let backendID: String
            let backendRevision: String
            let frameworkIdentity: String
            let policyIdentity: String
            let materialDecisionIdentity: String
        }

        let expectations = [
            Expected(
                mode: .quality,
                scalerKind: .highQualityVImage,
                orchestrationKind: .quality,
                capabilityID: "R13-QUALITY-ROUTER",
                backendID: "r13.quality.router",
                backendRevision: "r13.product-router.v1",
                frameworkIdentity: "AppleNativeMultiEngine",
                policyIdentity:
                    "r13.quality.native-preferred-fallback.v1",
                materialDecisionIdentity:
                    "r13.quality.multi-engine-whole-frame.v1"
            ),
            Expected(
                mode: .fast,
                scalerKind: .fastMPSBilinear,
                orchestrationKind: .fast,
                capabilityID: "R13-FAST-ROUTER",
                backendID: "r13.fast.router",
                backendRevision: "r13.product-router.v1",
                frameworkIdentity: "AppleNativeMultiEngine",
                policyIdentity:
                    "r13.fast.latency-preferred-fallback.v1",
                materialDecisionIdentity:
                    "r13.fast.multi-engine-whole-frame.v1"
            ),
            Expected(
                mode: .deterministic,
                scalerKind: .deterministicMPSLanczos,
                orchestrationKind: .none,
                capabilityID: "A11",
                backendID: "r03.mps.lanczos",
                backendRevision: "1",
                frameworkIdentity: "MetalPerformanceShaders",
                policyIdentity:
                    "r03.a11.product-qualified.no-fallback.v1",
                materialDecisionIdentity:
                    "r03.a11.genuine-mps-lanczos-product-admission.v1"
            )
        ]

        let bindings = expectations.map { expected in
            let binding = R13ReleaseModePolicy.binding(
                for: expected.mode
            )
            XCTAssertEqual(binding.requestedMode, expected.mode)
            XCTAssertEqual(binding.effectiveMode, expected.mode)
            XCTAssertEqual(binding.scalerKind, expected.scalerKind)
            XCTAssertEqual(
                binding.orchestrationKind,
                expected.orchestrationKind
            )
            XCTAssertEqual(binding.capabilityID, expected.capabilityID)
            XCTAssertEqual(binding.backendID, expected.backendID)
            XCTAssertEqual(
                binding.backendRevision,
                expected.backendRevision
            )
            XCTAssertEqual(
                binding.frameworkIdentity,
                expected.frameworkIdentity
            )
            XCTAssertEqual(
                binding.policyIdentity,
                expected.policyIdentity
            )
            XCTAssertEqual(
                binding.materialDecisionIdentity,
                expected.materialDecisionIdentity
            )
            XCTAssertEqual(
                R13ReleaseModePolicy.availability(for: expected.mode),
                .available
            )
            return binding
        }

        XCTAssertEqual(Set(bindings.map(\.scalerKind)).count, 3)
        XCTAssertEqual(Set(bindings.map(\.capabilityID)).count, 3)
        XCTAssertEqual(Set(bindings.map(\.backendID)).count, 3)
        XCTAssertEqual(Set(bindings.map(\.policyIdentity)).count, 3)
        XCTAssertEqual(
            Set(bindings.map(\.materialDecisionIdentity)).count,
            3
        )
    }

    func testExtendedFormatsRetainRequestedEngineAndRouterScope() {
        let format = MediaVideoFormat.hdrBT2020PQ(
            masteringDisplayColorVolume: Data(repeating: 0x31, count: 24),
            contentLightLevelInfo: Data([0x01, 0x02, 0x03, 0x04])
        )
        let explicitExpectations: [(
            preference: UpscaleEnginePreference,
            scaler: R13ReleaseScalerKind
        )] = [
            (.accelerateVImageHighQuality, .highQualityVImage),
            (.mpsBilinear, .fastMPSBilinear),
            (.mpsLanczos, .deterministicMPSLanczos)
        ]

        for expected in explicitExpectations {
            let canonical = R13ReleaseModePolicy.binding(
                for: .auto,
                enginePreference: expected.preference
            )
            let extended = canonical.resolving(
                videoFormat: format
            )

            XCTAssertTrue(extended.usesFormatPreservingFallback)
            XCTAssertFalse(extended.usesProductOrchestration)
            XCTAssertEqual(extended.scalerKind, expected.scaler)
            XCTAssertEqual(
                extended.orchestrationKind,
                .none
            )
            XCTAssertEqual(
                extended.backendID,
                canonical.backendID
            )
            XCTAssertEqual(
                extended.frameworkIdentity,
                canonical.frameworkIdentity
            )
            XCTAssertTrue(
                extended.policyIdentity.contains(
                    format.pixelStorage.rawValue
                )
            )
            XCTAssertTrue(
                extended.materialDecisionIdentity.contains(
                    format.pixelStorage.rawValue
                )
            )
        }

        for mode in [
            UpscaleMode.auto,
            .quality,
            .fast,
            .smoothMotion
        ] {
            let canonical =
                R13ReleaseModePolicy.binding(for: mode)
            let extended = canonical.resolving(
                videoFormat: format
            )

            XCTAssertTrue(extended.usesFormatPreservingFallback)
            XCTAssertTrue(extended.usesProductOrchestration)
            XCTAssertEqual(
                extended.orchestrationKind,
                canonical.orchestrationKind
            )
            XCTAssertEqual(
                extended.backendID,
                canonical.backendID
            )
            XCTAssertEqual(
                extended.frameworkIdentity,
                "AppleNativeMultiEngine"
            )
        }

        let deterministic = R13ReleaseModePolicy
            .binding(for: .deterministic)
            .resolving(videoFormat: format)
        XCTAssertEqual(
            deterministic.scalerKind,
            .deterministicMPSLanczos
        )
        XCTAssertEqual(
            deterministic.frameworkIdentity,
            "MetalPerformanceShaders"
        )
    }

    func testProductFactoryConstructsExpectedCanonicalSessionsForEveryMode()
        async throws {
        for mode in UpscaleMode.allCases {
            let modeBinding = R13ReleaseModePolicy.binding(for: mode)

            for route in R03ScaleRoute.allCases {
                let binding = try await R13A11ProductSessionFactory
                    .makeSession(
                        route: route,
                        modeBinding: modeBinding
                    )
                guard let expectedConfigurationIdentity =
                    modeBinding.configurationIdentity(for: route)
                else {
                    await binding.session.cancel()
                    return XCTFail(
                        "Missing canonical route \(route.rawValue) "
                            + "for \(mode.rawValue)."
                    )
                }

                XCTAssertEqual(binding.route, route)
                XCTAssertEqual(
                    binding.routeIdentity.backend.backendID,
                    modeBinding.backendID
                )
                XCTAssertEqual(
                    binding.routeIdentity.backend.backendRevision,
                    modeBinding.backendRevision
                )
                XCTAssertEqual(
                    binding.routeIdentity.backend.modelAssetsIdentity,
                    .notRequired
                )
                XCTAssertEqual(
                    binding.routeIdentity.configurationIdentity,
                    expectedConfigurationIdentity
                )
                XCTAssertEqual(
                    binding.routeIdentity.policyIdentity,
                    modeBinding.policyIdentity
                )
                XCTAssertEqual(
                    binding.routeIdentity.materialDecisionIdentity,
                    modeBinding.materialDecisionIdentity
                )
                let sessionIdentity = await binding.session.identity
                let expectedProcessingIdentity =
                    try AppleUpscaleProcessingIdentity(
                        route: binding.routeIdentity,
                        fallbackHistory: []
                    )
                XCTAssertEqual(
                    sessionIdentity,
                    binding.routeIdentity
                )
                XCTAssertEqual(
                    try binding.processingIdentity,
                    expectedProcessingIdentity
                )
                if modeBinding.usesProductOrchestration {
                    XCTAssertFalse(
                        binding
                            .admittedFrameRouteIdentities
                            .isEmpty
                    )
                    XCTAssertNotNil(
                        binding.session
                            as? any R13ProductASHDecisionReporting
                    )
                } else {
                    XCTAssertTrue(
                        binding
                            .admittedFrameRouteIdentities
                            .isEmpty
                    )
                    XCTAssertNil(
                        binding.session
                            as? any R13ProductASHDecisionReporting
                    )
                }

                await binding.session.cancel()
            }
        }
    }

    func testReleaseModesProduceStablePixelsAndDirectModesRemainDistinct()
        async throws {
        let quality = try await processPatternedFrame(mode: .quality)
        let fast = try await processPatternedFrame(mode: .fast)
        let deterministic = try await processPatternedFrame(
            mode: .deterministic
        )
        let auto = try await processPatternedFrame(mode: .auto)

        XCTAssertNotEqual(quality, fast)
        XCTAssertNotEqual(quality, deterministic)
        XCTAssertNotEqual(fast, deterministic)

        let repeatedQuality = try await processPatternedFrame(
            mode: .quality
        )
        let repeatedFast = try await processPatternedFrame(mode: .fast)
        let repeatedDeterministic = try await processPatternedFrame(
            mode: .deterministic
        )
        let repeatedAuto = try await processPatternedFrame(mode: .auto)
        XCTAssertEqual(repeatedQuality, quality)
        XCTAssertEqual(repeatedFast, fast)
        XCTAssertEqual(repeatedDeterministic, deterministic)
        XCTAssertEqual(repeatedAuto, auto)
    }

    func testExplicitApplePathCatalogBindsEveryConcreteSelection() {
        XCTAssertEqual(
            UpscaleEnginePreference.allCases.map(\.rawValue),
            [
                "automatic",
                "accelerate_vimage_standard",
                "accelerate_vimage_high_quality",
                "mps_bilinear",
                "mps_lanczos",
                "core_image_lanczos",
                "core_image_bicubic",
                "videotoolbox_pixel_transfer",
                "videotoolbox_quality",
                "videotoolbox_low_latency",
                "metalfx_spatial"
            ]
        )

        let directCases: [(
            preference: UpscaleEnginePreference,
            scaler: R13ReleaseScalerKind,
            framework: String
        )] = [
            (.accelerateVImageStandard, .standardVImage, "Accelerate"),
            (
                .accelerateVImageHighQuality,
                .highQualityVImage,
                "Accelerate"
            ),
            (.mpsBilinear, .fastMPSBilinear, "MetalPerformanceShaders"),
            (
                .mpsLanczos,
                .deterministicMPSLanczos,
                "MetalPerformanceShaders"
            ),
            (.coreImageLanczos, .coreImageLanczos, "CoreImage"),
            (.coreImageBicubic, .coreImageBicubic, "CoreImage"),
            (
                .videoToolboxPixelTransfer,
                .videoToolboxPixelTransfer,
                "VideoToolbox"
            )
        ]
        for testCase in directCases {
            let binding = R13ReleaseModePolicy.binding(
                for: .auto,
                enginePreference: testCase.preference
            )
            XCTAssertEqual(binding.enginePreference, testCase.preference)
            XCTAssertEqual(binding.scalerKind, testCase.scaler)
            XCTAssertEqual(binding.orchestrationKind, .none)
            XCTAssertFalse(binding.usesProductOrchestration)
            XCTAssertEqual(binding.frameworkIdentity, testCase.framework)
            XCTAssertEqual(
                binding.backendID,
                testCase.scaler.subjectID.rawValue
            )
            XCTAssertTrue(binding.policyIdentity.contains("no-fallback"))
        }
    }

    func testExplicitNativeSelectionsDeclareExactlyOneCandidate() {
        let cases: [(
            preference: UpscaleEnginePreference,
            declaredKind: R13ProductASHCandidateKind,
            framework: String
        )] = [
            (.videoToolboxQuality, .videoToolboxQuality, "VideoToolbox"),
            (
                .videoToolboxLowLatency,
                .videoToolboxLowLatency,
                "VideoToolbox"
            ),
            (.metalFXSpatial, .metalFXSpatial, "MetalFX")
        ]

        for route in R03ScaleRoute.allCases {
            for testCase in cases {
                let binding = R13ReleaseModePolicy.binding(
                    for: .auto,
                    enginePreference: testCase.preference
                )
                let declarations = R13A11ProductSessionFactory
                    .candidateDeclarations(
                        route: route,
                        orchestrationKind: binding.orchestrationKind,
                        enginePreference: testCase.preference
                    )

                XCTAssertEqual(declarations.count, 1)
                XCTAssertEqual(
                    declarations.first?.declaredKind,
                    testCase.declaredKind
                )
                XCTAssertEqual(binding.frameworkIdentity, testCase.framework)
                XCTAssertTrue(binding.policyIdentity.contains("exact"))
                XCTAssertTrue(binding.policyIdentity.contains("no-fallback"))
                XCTAssertTrue(
                    binding.configurationIdentity(for: route)?
                        .contains(testCase.preference.rawValue) == true
                )
            }
        }
    }

    func testNewDirectApplePathsCreateExactProductSessions()
        async throws {
        let cases: [(
            preference: UpscaleEnginePreference,
            backendID: String
        )] = [
            (
                .accelerateVImageStandard,
                R03BaselineSubjectID.vImageLanczos3.rawValue
            ),
            (
                .coreImageLanczos,
                R03BaselineSubjectID.coreImageLanczos.rawValue
            ),
            (
                .coreImageBicubic,
                R03BaselineSubjectID.coreImageBicubic.rawValue
            ),
            (
                .videoToolboxPixelTransfer,
                R03BaselineSubjectID.vtPixelTransfer.rawValue
            )
        ]

        for route in R03ScaleRoute.allCases {
            for testCase in cases {
                let modeBinding = R13ReleaseModePolicy.binding(
                    for: .auto,
                    enginePreference: testCase.preference
                )
                let sessionBinding = try await
                    R13A11ProductSessionFactory.makeSession(
                        route: route,
                        modeBinding: modeBinding
                    )
                XCTAssertEqual(
                    sessionBinding.routeIdentity.backend.backendID,
                    testCase.backendID
                )
                XCTAssertEqual(
                    sessionBinding.routeIdentity.policyIdentity,
                    modeBinding.policyIdentity
                )
                XCTAssertTrue(
                    sessionBinding.admittedFrameRouteIdentities.isEmpty
                )
                await sessionBinding.session.cancel()
            }
        }
    }

    func testExplicitNativeSelectionRejectsAdaptiveSubstitution() throws {
        let plan = try R13AdaptiveScalePlan(
            sourceResolution: VideoResolution(width: 64, height: 36),
            targetResolution: VideoResolution(width: 160, height: 90)
        )

        for preference in [
            UpscaleEnginePreference.videoToolboxQuality,
            .videoToolboxLowLatency,
            .metalFXSpatial
        ] {
            XCTAssertThrowsError(
                try R13ProductASHScalingCandidateFactory.makeCandidates(
                    scalePlan: .adaptiveMPSLanczos(plan),
                    videoFormat: .sdrBT709,
                    orchestrationKind: .quality,
                    enginePreference: preference,
                    makeScaler: { _ in
                        XCTFail(
                            "An exact native selection must not construct a fallback."
                        )
                        throw R03NV12ScalingError.runtimeUnavailable(
                            "unexpected_fallback"
                        )
                    }
                )
            ) { error in
                guard case R03NV12ScalingError.runtimeUnavailable(
                    let reason
                ) = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
                XCTAssertTrue(reason.contains(preference.rawValue))
            }
        }
    }

    private func processPatternedFrame(
        mode: UpscaleMode
    ) async throws -> R13NV12Frame {
        let route = R03ScaleRoute.scale3Over2
        let sessionBinding = try await R13A11ProductSessionFactory
            .makeSession(
                route: route,
                modeBinding: R13ReleaseModePolicy.binding(for: mode)
            )
        let fixture = try R03DeterministicBackendTestSupport.makeInputFrame(
            route: route,
            sequenceNumber: 0,
            seed: 137,
            tokenPrefix: "r13.mode.\(mode.rawValue)"
        )
        let outcome = await sessionBinding.session.submit(fixture.frame)
        switch outcome {
        case .processed(let processed):
            defer { processed.resourceLifetimeToken.release() }
            let output = try R13NV12Frame.captureTightActivePlanes(
                from: processed.pixelBuffer
            )
            let summary = await sessionBinding.session.finish()
            XCTAssertEqual(summary.submittedFrameCount, 1)
            XCTAssertEqual(summary.processedFrameCount, 1)
            return output
        case .unavailable(let unavailable):
            throw UpscalerEngineError.backendUnavailable(
                reason: unavailable.reason
            )
        case .rejected(let rejected):
            throw UpscalerEngineError.strategyFailed(
                "Mode \(mode.rawValue) rejected the patterned frame: "
                    + rejected.reason
            )
        case .failed(let failure):
            throw UpscalerEngineError.strategyFailed(
                "Mode \(mode.rawValue) failed the patterned frame: "
                    + failure.reason
            )
        }
    }

}

final class R13ProductionEnvironmentTests: XCTestCase {
    func testCollectorSupportsEveryExposedModeFrameworkIdentity() throws {
        let expectedFrameworks: [UpscaleMode: String] = [
            .auto: "AppleNativeMultiEngine",
            .quality: "AppleNativeMultiEngine",
            .fast: "AppleNativeMultiEngine",
            .deterministic: "MetalPerformanceShaders",
            .smoothMotion: "AppleNativeMultiEngine"
        ]
        let collector = R13ProductionReleaseEnvironmentCollector()

        for mode in UpscaleMode.allCases {
            let binding = R13ReleaseModePolicy.binding(for: mode)
            let expectedFramework = try XCTUnwrap(
                expectedFrameworks[mode]
            )
            XCTAssertEqual(
                binding.frameworkIdentity,
                expectedFramework,
                "Unexpected framework binding for \(mode.rawValue)."
            )

            let environment = try collector.collect(
                frameworkIdentity: binding.frameworkIdentity
            )
            XCTAssertEqual(
                environment.framework.frameworkIdentifier,
                expectedFramework,
                "Production collection failed for \(mode.rawValue)."
            )
            if expectedFramework == "AppleNativeMultiEngine" {
                XCTAssertEqual(
                    environment.framework.version,
                    environment.runtime.version
                )
                XCTAssertEqual(
                    environment.framework.buildIdentity,
                    environment.runtime.buildIdentity
                )
            }
        }
    }

    func testCompositeFrameworkUsesObservedOperatingSystemIdentity() throws {
        let environment = try R13ProductionReleaseEnvironmentCollector()
            .collect(frameworkIdentity: "AppleNativeMultiEngine")
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let expectedVersion =
            "\(version.majorVersion)."
            + "\(version.minorVersion)."
            + "\(version.patchVersion)"

        XCTAssertEqual(
            environment.framework.frameworkIdentifier,
            "AppleNativeMultiEngine"
        )
        XCTAssertEqual(environment.framework.version, expectedVersion)
        XCTAssertEqual(
            environment.framework.buildIdentity,
            try observedOperatingSystemBuildIdentity()
        )
    }

    func testCollectorRetainsDirectFrameworkBundleIdentities() throws {
        let expectations = [
            (
                identity: "MetalPerformanceShaders",
                path:
                    "/System/Library/Frameworks/MetalPerformanceShaders.framework"
            ),
            (
                identity: "Accelerate",
                path: "/System/Library/Frameworks/Accelerate.framework"
            ),
            (
                identity: "CoreImage",
                path: "/System/Library/Frameworks/CoreImage.framework"
            ),
            (
                identity: "VideoToolbox",
                path: "/System/Library/Frameworks/VideoToolbox.framework"
            ),
            (
                identity: "MetalFX",
                path: "/System/Library/Frameworks/MetalFX.framework"
            )
        ]
        let collector = R13ProductionReleaseEnvironmentCollector()

        for expected in expectations {
            let bundle = try XCTUnwrap(Bundle(path: expected.path))
            let version = try XCTUnwrap(
                bundle.object(
                    forInfoDictionaryKey: "CFBundleShortVersionString"
                ) as? String
            )
            let build = try XCTUnwrap(
                bundle.object(
                    forInfoDictionaryKey: "CFBundleVersion"
                ) as? String
            )
            let expectedVersion = try R13FrameworkBundleIdentityCanonicalizer
                .version(version)
            let expectedBuild = try R13FrameworkBundleIdentityCanonicalizer
                .build(build)
            let environment = try collector.collect(
                frameworkIdentity: expected.identity
            )
            let repeatedEnvironment = try collector.collect(
                frameworkIdentity: expected.identity
            )

            XCTAssertEqual(
                environment.framework.frameworkIdentifier,
                expected.identity
            )
            XCTAssertEqual(
                environment.framework.version,
                expectedVersion
            )
            XCTAssertEqual(
                environment.framework.buildIdentity,
                expectedBuild
            )
            XCTAssertEqual(
                environment.framework,
                repeatedEnvironment.framework
            )
            try assertRoundTripWhenEncoded(
                canonical: environment.framework.version,
                raw: version
            )
            try assertRoundTripWhenEncoded(
                canonical: environment.framework.buildIdentity,
                raw: build
            )
        }
    }

    func testCanonicalizationRejectsUnsafeFrameworkBundleValues() throws {
        XCTAssertEqual(
            try R13FrameworkBundleIdentityCanonicalizer.version("1.0"),
            "1.0"
        )
        XCTAssertEqual(
            try R13FrameworkBundleIdentityCanonicalizer.build("Build_1"),
            "Build_1"
        )

        let printableUnicode = "版本 1"
        XCTAssertEqual(
            try decodedFrameworkBundleIdentity(
                R13FrameworkBundleIdentityCanonicalizer.build(
                    printableUnicode
                )
            ),
            printableUnicode
        )

        let encodedSpace = try R13FrameworkBundleIdentityCanonicalizer
            .build(" ")
        let reservedPrefixLiteral = "utf8-hex-20"
        let encodedLiteral = try R13FrameworkBundleIdentityCanonicalizer
            .build(reservedPrefixLiteral)
        XCTAssertNotEqual(encodedSpace, encodedLiteral)
        XCTAssertEqual(
            try decodedFrameworkBundleIdentity(encodedSpace),
            " "
        )
        XCTAssertEqual(
            try decodedFrameworkBundleIdentity(encodedLiteral),
            reservedPrefixLiteral
        )

        for value in [
            "",
            "line\nbreak",
            String(repeating: " ", count: 76)
        ] {
            XCTAssertThrowsError(
                try R13FrameworkBundleIdentityCanonicalizer.build(value)
            ) { error in
                XCTAssertEqual(
                    error as? R13ReleaseEnvironmentError,
                    .frameworkIdentityUnavailable(field: "build")
                )
            }
        }
    }

    func testCompositeIdentityRejectsRuntimeVersionAndBuildMismatch()
        throws {
        let matching = try compositeReleaseIdentityInput(
            frameworkVersion: "26.0.1",
            frameworkBuild: "25A100",
            runtimeVersion: "26.0.1",
            runtimeBuild: "25A100"
        )
        XCTAssertNoThrow(try R13ReleaseIdentity(matching))

        let versionMismatch = try compositeReleaseIdentityInput(
            frameworkVersion: "26.0.0",
            frameworkBuild: "25A100",
            runtimeVersion: "26.0.1",
            runtimeBuild: "25A100"
        )
        XCTAssertThrowsError(
            try R13ReleaseIdentity(versionMismatch)
        ) { error in
            XCTAssertEqual(
                error as? R13ReleaseIdentityError,
                .frameworkRuntimeIdentityMismatch(
                    field: "framework_version"
                )
            )
        }

        let buildMismatch = try compositeReleaseIdentityInput(
            frameworkVersion: "26.0.1",
            frameworkBuild: "25A99",
            runtimeVersion: "26.0.1",
            runtimeBuild: "25A100"
        )
        XCTAssertThrowsError(
            try R13ReleaseIdentity(buildMismatch)
        ) { error in
            XCTAssertEqual(
                error as? R13ReleaseIdentityError,
                .frameworkRuntimeIdentityMismatch(
                    field: "framework_build_identity"
                )
            )
        }
    }

    func testCollectorRejectsUnknownFrameworkIdentity() {
        XCTAssertThrowsError(
            try R13ProductionReleaseEnvironmentCollector().collect(
                frameworkIdentity: "UnrecognizedFramework"
            )
        ) { error in
            XCTAssertEqual(
                error as? R13ReleaseEnvironmentError,
                .frameworkIdentityUnavailable(
                    field: "requested_framework"
                )
            )
        }
    }

    private func observedOperatingSystemBuildIdentity() throws -> String {
        var byteCount = 0
        guard sysctlbyname(
            "kern.osversion",
            nil,
            &byteCount,
            nil,
            0
        ) == 0,
        byteCount > 1 else {
            throw OperatingSystemBuildProbeError.failed
        }
        var bytes = [CChar](repeating: 0, count: byteCount)
        let result = bytes.withUnsafeMutableBytes {
            sysctlbyname(
                "kern.osversion",
                $0.baseAddress,
                &byteCount,
                nil,
                0
            )
        }
        guard result == 0 else {
            throw OperatingSystemBuildProbeError.failed
        }
        let value = String(cString: bytes)
        guard !value.isEmpty else {
            throw OperatingSystemBuildProbeError.failed
        }
        return value
    }

    private func compositeReleaseIdentityInput(
        frameworkVersion: String,
        frameworkBuild: String,
        runtimeVersion: String,
        runtimeBuild: String
    ) throws -> R13ReleaseIdentityInput {
        let modeBinding = R13ReleaseModePolicy.binding(for: .quality)
        let route = R03ScaleRoute.scale2x
        return R13ReleaseIdentityInput(
            source: try R13ReleaseSourceBinding(
                sha256: String(repeating: "a", count: 64),
                byteCount: 1_024
            ),
            modeBinding: modeBinding,
            output: try R13ReleaseOutputBinding(
                resolution: .p2160,
                codec: .hevc,
                preserveAudio: true
            ),
            scalePlan: .productQualified(route),
            routeIdentity: try R13ReleaseIdentity.makeProductRoute(
                for: route,
                modeBinding: modeBinding
            ),
            application: try R13ReleaseApplicationIdentity(
                bundleIdentifier: "com.mirmir.environment-tests",
                semanticVersion: "1.0.0",
                buildVersion: "2",
                executableSHA256: String(repeating: "b", count: 64),
                executableByteCount: 2_048
            ),
            framework: try R13ReleaseFrameworkIdentity(
                frameworkIdentifier: "AppleNativeMultiEngine",
                version: frameworkVersion,
                buildIdentity: frameworkBuild
            ),
            runtime: try R13ReleaseRuntimeIdentity(
                runtimeIdentifier: "macOS",
                version: runtimeVersion,
                buildIdentity: runtimeBuild,
                architecture: "arm64"
            ),
            policyResources: try R13ReleasePolicyResourceBinding(
                policySHA256: String(repeating: "c", count: 64),
                resourceManifestSHA256:
                    String(repeating: "d", count: 64)
            ),
            fallbackHistory: []
        )
    }

    private func decodedFrameworkBundleIdentity(
        _ value: String
    ) throws -> String {
        let prefix = "utf8-hex-"
        guard value.hasPrefix(prefix) else {
            throw FrameworkIdentityDecodingError.invalidPrefix
        }
        let hex = value.dropFirst(prefix.count)
        guard !hex.isEmpty, hex.count.isMultiple(of: 2) else {
            throw FrameworkIdentityDecodingError.invalidHex
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else {
                throw FrameworkIdentityDecodingError.invalidHex
            }
            bytes.append(byte)
            index = next
        }
        guard let decoded = String(bytes: bytes, encoding: .utf8) else {
            throw FrameworkIdentityDecodingError.invalidUTF8
        }
        return decoded
    }

    private func assertRoundTripWhenEncoded(
        canonical: String,
        raw: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        guard canonical != raw else { return }
        XCTAssertEqual(
            try decodedFrameworkBundleIdentity(canonical),
            raw,
            file: file,
            line: line
        )
    }

    private enum OperatingSystemBuildProbeError: Error {
        case failed
    }

    private enum FrameworkIdentityDecodingError: Error {
        case invalidPrefix
        case invalidHex
        case invalidUTF8
    }
}
