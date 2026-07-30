import XCTest
@testable import Mirmir

final class R13ReleaseIdentityTests: XCTestCase {
    func testIdentityHashIsDeterministicAndBindsEveryReleaseDimension() throws {
        let first = try makeIdentity()
        let second = try makeIdentity()

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.identitySHA256.count, 64)
        XCTAssertEqual(first.source.sha256, hash("1"))
        XCTAssertEqual(first.source.byteCount, 9_876_543)
        XCTAssertEqual(first.requestedMode, .quality)
        XCTAssertEqual(first.effectiveMode, .deterministic)
        XCTAssertEqual(first.output.width, 3_840)
        XCTAssertEqual(first.output.height, 2_160)
        XCTAssertEqual(first.capabilityID, "A11")
        XCTAssertEqual(first.backendID, "r03.mps.lanczos")
        XCTAssertEqual(first.backendRevision, "1")
        XCTAssertEqual(first.routeID, "scale_2x")
        XCTAssertEqual(first.framework.frameworkIdentifier, "MetalPerformanceShaders")
        XCTAssertEqual(
            first.identitySHA256,
            "75a76c3abf989885c4397d965d9bd862ff3948d9cd6e1dacd1b233e55defb9c3"
        )

        let metadata = first.timedMetadata
        XCTAssertEqual(metadata.count, 22)
        XCTAssertTrue(
            metadata.keys.allSatisfy {
                $0.hasPrefix(R13ReleaseIdentity.metadataNamespace)
            }
        )
        XCTAssertEqual(
            metadata["com.mirmir.release.model-status"],
            "not_required"
        )
        XCTAssertEqual(
            metadata["com.mirmir.release.fallback-history"],
            "[]"
        )
        XCTAssertEqual(
            metadata["com.mirmir.release.identity-sha256"],
            first.identitySHA256
        )
        XCTAssertNoThrow(try first.validateTimedMetadata(metadata))
    }

    func testAdaptiveIdentityAndPolicyBindTheExactDynamicMPSPlan()
        throws {
        let plan = try R13AdaptiveScalePlan(
            sourceResolution: VideoResolution(width: 728, height: 410),
            targetResolution: VideoResolution(width: 1_278, height: 720)
        )
        let scalePlan = R13ReleaseScalePlan.adaptiveMPSLanczos(plan)
        let basePolicy = try R13ReleasePolicyResourceBinding(
            policySHA256: hash("2"),
            resourceManifestSHA256: hash("3")
        )
        let boundPolicy = try R13ReleaseHardeningRuntime.policyResources(
            for: scalePlan,
            base: basePolicy
        )
        let policyDocument = R13AdaptiveReleasePolicyDocument(plan: plan)
        let policyData = try R13RestartCanonical.data(policyDocument)
        let decodedPolicy = try JSONDecoder().decode(
            R13AdaptiveReleasePolicyDocument.self,
            from: policyData
        )

        XCTAssertEqual(decodedPolicy, policyDocument)
        XCTAssertEqual(
            boundPolicy.policySHA256,
            R13CryptoKitRestartDigest().sha256(policyData)
        )
        XCTAssertNotEqual(
            boundPolicy.policySHA256,
            basePolicy.policySHA256
        )
        XCTAssertEqual(
            boundPolicy.resourceManifestSHA256,
            basePolicy.resourceManifestSHA256
        )
        XCTAssertEqual(
            try R13ReleaseHardeningRuntime.policyResources(
                for: .productQualified(.scale2x),
                base: basePolicy
            ),
            basePolicy
        )

        let identity = try R13ReleaseIdentity(
            try makeAdaptiveInput(
                plan: plan,
                policyResources: boundPolicy
            )
        )

        XCTAssertEqual(
            identity.capabilityID,
            R13ReleaseIdentity.adaptiveCapabilityID
        )
        XCTAssertEqual(
            identity.backendID,
            R13ReleaseIdentity.adaptiveBackendID
        )
        XCTAssertEqual(
            identity.routeID,
            R13ReleaseIdentity.adaptiveRouteID
        )
        XCTAssertEqual(
            identity.configurationIdentity,
            plan.configurationIdentity
        )
        XCTAssertEqual(
            identity.policyIdentity,
            R13ReleaseIdentity.adaptivePolicyIdentity
        )
        XCTAssertEqual(
            identity.materialDecisionIdentity,
            R13ReleaseIdentity.adaptiveMaterialDecisionIdentity
        )
        XCTAssertEqual(identity.policyResources, boundPolicy)
        XCTAssertNotEqual(identity.identitySHA256, try makeIdentity().identitySHA256)

        let job = UpscaleJob(
            identifier: "r13-adaptive-identity",
            inputURL: URL(fileURLWithPath: "/tmp/adaptive-input"),
            outputURL: URL(fileURLWithPath: "/tmp/adaptive-output.mp4"),
            targetResolution: plan.targetResolution,
            codec: .hevc,
            preserveAudio: true,
            mode: .quality
        )
        let source = try R13RestartSourceIdentity(
            sha256: hash("1"),
            byteCount: 9_876_543
        )
        let core = try R13ReleaseHardeningRuntime.makeRestartCore(
            job: job,
            scalePlan: scalePlan,
            identity: identity,
            source: source,
            totalFrameCount: 17
        )
        XCTAssertEqual(
            core.processing.routeIdentity,
            "\(R13ReleaseIdentity.adaptiveRouteID):"
                + plan.configurationIdentity
        )
        XCTAssertEqual(
            core.processing.backendIdentity,
            R13ReleaseIdentity.adaptiveBackendID
        )
    }

    func testAdaptiveIdentityRejectsAnA11RouteClaim() throws {
        let plan = try R13AdaptiveScalePlan(
            sourceResolution: VideoResolution(width: 728, height: 410),
            targetResolution: VideoResolution(width: 1_278, height: 720)
        )
        let input = try makeAdaptiveInput(
            plan: plan,
            policyResources: R13ReleasePolicyResourceBinding(
                policySHA256: hash("2"),
                resourceManifestSHA256: hash("3")
            )
        )
        let invalid = replacingRoute(
            input,
            with: try R13ReleaseIdentity.makeA11Route(for: .scale2x)
        )

        XCTAssertThrowsError(try R13ReleaseIdentity(invalid)) { error in
            XCTAssertEqual(
                error as? R13ReleaseIdentityError,
                .adaptiveBindingMismatch(field: "backend_id")
            )
        }
    }

    func testChangingBoundBytesOrPolicyChangesTheIdentityHash() throws {
        let baseline = try makeIdentity()
        let changedBytes = try makeIdentity(sourceByteCount: 9_876_544)
        let changedPolicy = try makeIdentity(policySHA256: hash("9"))

        XCTAssertNotEqual(baseline.identitySHA256, changedBytes.identitySHA256)
        XCTAssertNotEqual(baseline.identitySHA256, changedPolicy.identitySHA256)
        XCTAssertNotEqual(changedBytes.identitySHA256, changedPolicy.identitySHA256)
    }

    func testInvalidIdentityOutputModelAndFallbackFailClosed() throws {
        XCTAssertThrowsError(
            try R13ReleaseSourceBinding(
                sha256: String(repeating: "A", count: 64),
                byteCount: 1
            )
        ) { error in
            XCTAssertEqual(
                error as? R13ReleaseIdentityError,
                .invalidSHA256(field: "source_sha256")
            )
        }
        XCTAssertThrowsError(
            try R13ReleaseSourceBinding(sha256: hash("1"), byteCount: 0)
        ) { error in
            XCTAssertEqual(
                error as? R13ReleaseIdentityError,
                .invalidByteCount(field: "source_byte_count")
            )
        }
        XCTAssertThrowsError(
            try application(bundleIdentifier: "/Users/operator/Mirmir")
        ) { error in
            XCTAssertEqual(
                error as? R13ReleaseIdentityError,
                .invalidIdentity(field: "app_bundle_identifier")
            )
        }

        let input = try makeInput()
        let outputMismatchInput = R13ReleaseIdentityInput(
            source: input.source,
            modeBinding: input.modeBinding,
            output: try R13ReleaseOutputBinding(
                resolution: .p1080,
                codec: .hevc,
                preserveAudio: true
            ),
            scalePlan: input.scalePlan,
            routeIdentity: input.routeIdentity,
            application: input.application,
            framework: input.framework,
            runtime: input.runtime,
            policyResources: input.policyResources,
            fallbackHistory: []
        )
        XCTAssertThrowsError(
            try R13ReleaseIdentity(outputMismatchInput)
        ) { error in
            XCTAssertEqual(
                error as? R13ReleaseIdentityError,
                .outputRouteMismatch
            )
        }

        let boundModelRoute = try AppleUpscaleRouteIdentity(
            backend: AppleUpscaleBackendIdentity(
                backendID: "r03.mps.lanczos",
                backendRevision: "1",
                modelAssetsIdentity: .bound([
                    AppleUpscaleArtifactIdentity(
                        identifier: "unexpected.model",
                        sha256: hash("8")
                    )
                ])
            ),
            configurationIdentity: input.routeIdentity.configurationIdentity,
            policyIdentity: R03A11ProductAdmission.policyIdentity,
            materialDecisionIdentity:
                R03A11ProductAdmission.materialDecisionIdentity
        )
        XCTAssertThrowsError(
            try R13ReleaseIdentity(replacingRoute(input, with: boundModelRoute))
        ) { error in
            XCTAssertEqual(
                error as? R13ReleaseIdentityError,
                .modelAssetsMustBeNotRequired
            )
        }

        let failedRoute = try R13ReleaseIdentity.makeA11Route(for: .scale3Over2)
        let fallback = try AppleUpscaleFallbackLink(
            failedRoute: failedRoute,
            selectedRoute: input.routeIdentity,
            reasonCode: .backendUnavailable,
            selectedFallbackOrdinal: 0
        )
        XCTAssertThrowsError(
            try R13ReleaseIdentity(replacingFallback(input, with: [fallback]))
        ) { error in
            XCTAssertEqual(
                error as? R13ReleaseIdentityError,
                .fallbackHistoryMustBeEmpty
            )
        }
    }

    func testMetadataRequiresTheExactControlledKeyAndValueSet() throws {
        let identity = try makeIdentity()

        var missing = identity.timedMetadata
        missing.removeValue(forKey: "com.mirmir.release.policy-sha256")
        XCTAssertThrowsError(try identity.validateTimedMetadata(missing)) { error in
            XCTAssertEqual(
                error as? R13ReleaseIdentityError,
                .metadataKeysDiffer
            )
        }

        var additional = identity.timedMetadata
        additional["com.mirmir.release.uncontrolled"] = "value"
        XCTAssertThrowsError(
            try identity.validateTimedMetadata(additional)
        ) { error in
            XCTAssertEqual(
                error as? R13ReleaseIdentityError,
                .metadataKeysDiffer
            )
        }

        var changed = identity.timedMetadata
        changed["com.mirmir.release.backend-id"] = "r03.vimage.lanczos-3"
        XCTAssertThrowsError(try identity.validateTimedMetadata(changed)) { error in
            XCTAssertEqual(
                error as? R13ReleaseIdentityError,
                .metadataValueDiffers(
                    key: "com.mirmir.release.backend-id"
                )
            )
        }
    }
}

private extension R13ReleaseIdentityTests {
    func makeIdentity(
        sourceByteCount: UInt64 = 9_876_543,
        policySHA256: String? = nil
    ) throws -> R13ReleaseIdentity {
        try R13ReleaseIdentity(
            makeInput(
                sourceByteCount: sourceByteCount,
                policySHA256: policySHA256
            )
        )
    }

    func makeInput(
        sourceByteCount: UInt64 = 9_876_543,
        policySHA256: String? = nil
    ) throws -> R13ReleaseIdentityInput {
        let scaleRoute = R03ScaleRoute.scale2x
        return R13ReleaseIdentityInput(
            source: try R13ReleaseSourceBinding(
                sha256: hash("1"),
                byteCount: sourceByteCount
            ),
            modeBinding: try R13ReleaseModePolicy.binding(for: .quality),
            output: try R13ReleaseOutputBinding(
                resolution: .p2160,
                codec: .hevc,
                preserveAudio: true
            ),
            scalePlan: .productQualified(scaleRoute),
            routeIdentity: try R13ReleaseIdentity.makeA11Route(for: scaleRoute),
            application: try application(),
            framework: try R13ReleaseFrameworkIdentity(
                frameworkIdentifier: "MetalPerformanceShaders",
                version: "15.4",
                buildIdentity: "24F74"
            ),
            runtime: try R13ReleaseRuntimeIdentity(
                runtimeIdentifier: "macOS",
                version: "15.4",
                buildIdentity: "24F74",
                architecture: "arm64"
            ),
            policyResources: try R13ReleasePolicyResourceBinding(
                policySHA256: policySHA256 ?? hash("2"),
                resourceManifestSHA256: hash("3")
            ),
            fallbackHistory: []
        )
    }

    func application(
        bundleIdentifier: String = "com.mirmir.app"
    ) throws -> R13ReleaseApplicationIdentity {
        try R13ReleaseApplicationIdentity(
            bundleIdentifier: bundleIdentifier,
            semanticVersion: "1.0.0",
            buildVersion: "1",
            executableSHA256: hash("4"),
            executableByteCount: 1_234_567
        )
    }

    func makeAdaptiveInput(
        plan: R13AdaptiveScalePlan,
        policyResources: R13ReleasePolicyResourceBinding
    ) throws -> R13ReleaseIdentityInput {
        R13ReleaseIdentityInput(
            source: try R13ReleaseSourceBinding(
                sha256: hash("1"),
                byteCount: 9_876_543
            ),
            modeBinding: try R13ReleaseModePolicy.binding(for: .quality),
            output: try R13ReleaseOutputBinding(
                resolution: plan.targetResolution,
                codec: .hevc,
                preserveAudio: true
            ),
            scalePlan: .adaptiveMPSLanczos(plan),
            routeIdentity: try R13ReleaseIdentity.makeAdaptiveRoute(
                for: plan
            ),
            application: try application(),
            framework: try R13ReleaseFrameworkIdentity(
                frameworkIdentifier: "MetalPerformanceShaders",
                version: "15.4",
                buildIdentity: "24F74"
            ),
            runtime: try R13ReleaseRuntimeIdentity(
                runtimeIdentifier: "macOS",
                version: "15.4",
                buildIdentity: "24F74",
                architecture: "arm64"
            ),
            policyResources: policyResources,
            fallbackHistory: []
        )
    }

    func replacingRoute(
        _ input: R13ReleaseIdentityInput,
        with route: AppleUpscaleRouteIdentity
    ) -> R13ReleaseIdentityInput {
        R13ReleaseIdentityInput(
            source: input.source,
            modeBinding: input.modeBinding,
            output: input.output,
            scalePlan: input.scalePlan,
            routeIdentity: route,
            application: input.application,
            framework: input.framework,
            runtime: input.runtime,
            policyResources: input.policyResources,
            fallbackHistory: input.fallbackHistory
        )
    }

    func replacingFallback(
        _ input: R13ReleaseIdentityInput,
        with fallback: [AppleUpscaleFallbackLink]
    ) -> R13ReleaseIdentityInput {
        R13ReleaseIdentityInput(
            source: input.source,
            modeBinding: input.modeBinding,
            output: input.output,
            scalePlan: input.scalePlan,
            routeIdentity: input.routeIdentity,
            application: input.application,
            framework: input.framework,
            runtime: input.runtime,
            policyResources: input.policyResources,
            fallbackHistory: fallback
        )
    }

    func hash(_ character: Character) -> String {
        String(repeating: String(character), count: 64)
    }
}
