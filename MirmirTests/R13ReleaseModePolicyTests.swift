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
