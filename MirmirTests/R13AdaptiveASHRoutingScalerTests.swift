import CoreMedia
import CoreVideo
import Foundation
import os.lock
import XCTest
@testable import Mirmir

private enum R13AdaptiveTestError: Error {
    case unsupportedFixtureFormat(String)
}

final class R13AdaptiveASHRoutingScalerTests: XCTestCase {
    func testVideoToolboxQualityPreparesOversizedLandscapeInputAtNativeLimit()
        throws {
        let admitted =
            try R13VideoToolboxAdaptiveNativeSourceAdmission
                .qualityResolution(
                    requestedSourceResolution: .p1440
                )

        XCTAssertEqual(admitted, .p1080)
        XCTAssertTrue(
            R13AspectRatioContract.preservesWithinOneOutputPixel(
                source: .p1440,
                target: admitted
            )
        )
    }

    func testVideoToolboxQualityPreparesOversizedPortraitInputProportionally()
        throws {
        let source = VideoResolution(width: 1_440, height: 2_560)
        let admitted =
            try R13VideoToolboxAdaptiveNativeSourceAdmission
                .qualityResolution(
                    requestedSourceResolution: source
                )

        XCTAssertEqual(
            admitted,
            VideoResolution(width: 608, height: 1_080)
        )
        XCTAssertTrue(
            R13AspectRatioContract.preservesWithinOneOutputPixel(
                source: source,
                target: admitted
            )
        )
    }

    func testVideoToolboxLowLatencyFitsInputWithinNativeRuntimeRange() throws {
        let source = VideoResolution(width: 2_560, height: 1_440)

        let admitted =
            try R13VideoToolboxAdaptiveNativeSourceAdmission
                .lowLatencyResolution(
                    requestedSourceResolution: source,
                    minimumResolution: VideoResolution(
                        width: 96,
                        height: 96
                    ),
                    maximumResolution: VideoResolution(
                        width: 960,
                        height: 960
                    )
                )

        XCTAssertEqual(
            admitted,
            VideoResolution(width: 960, height: 540)
        )
    }

    @available(macOS 26.0, *)
    func testLiveVideoToolboxLowLatencyAdaptiveScalerPreparesAndRunsNative()
        async throws {
        let source = try Self.makeNV12Buffer(
            resolution: .p720,
            seed: 17
        )
        let destination = try Self.makeNV12Buffer(
            resolution: .p1080,
            seed: 0
        )
        let originalDestination =
            try R13NV12Frame.captureTightActivePlanes(
                from: destination
            )
        let scaler = try R13VideoToolboxAdaptiveNativeScaler(
            path: .lowLatency,
            videoFormat: .sdrBT709,
            presentationSourceResolution: .p720,
            requestedSourceResolution: .p720,
            requestedTargetResolution: .p1080
        )

        do {
            try await scaler.scale(
                source: source,
                destination: destination,
                frameIndex: 0,
                presentationTimestamp: .zero,
                frameDuration: CMTime(value: 1, timescale: 30),
                cancellation:
                    AppleUpscaleOperationCancellationSignal()
            )
            try await scaler.finish()
        } catch {
            await scaler.cancel()
            throw error
        }

        try R03NV12Contract.validate(
            pixelBuffer: destination,
            resolution: .p1080
        )
        XCTAssertNotEqual(
            try R13NV12Frame.captureTightActivePlanes(
                from: destination
            ),
            originalDestination
        )
    }

    @available(macOS 26.0, *)
    func testLiveVideoToolboxQualityAdaptiveScalerFinishesExactGeometry()
        async throws {
        let source = try Self.makeNV12Buffer(
            resolution: .p270,
            seed: 23
        )
        let destination = try Self.makeNV12Buffer(
            resolution: .p720,
            seed: 0
        )
        let originalDestination =
            try R13NV12Frame.captureTightActivePlanes(
                from: destination
            )
        let scaler = try R13VideoToolboxAdaptiveNativeScaler(
            path: .quality,
            videoFormat: .sdrBT709,
            presentationSourceResolution: .p270,
            requestedSourceResolution: .p270,
            requestedTargetResolution: .p720
        )

        do {
            try await scaler.scale(
                source: source,
                destination: destination,
                frameIndex: 0,
                presentationTimestamp: .zero,
                frameDuration: CMTime(value: 1, timescale: 30),
                cancellation:
                    AppleUpscaleOperationCancellationSignal()
            )
            try await scaler.finish()
        } catch {
            await scaler.cancel()
            throw error
        }

        try R03NV12Contract.validate(
            pixelBuffer: destination,
            resolution: .p720
        )
        XCTAssertNotEqual(
            try R13NV12Frame.captureTightActivePlanes(
                from: destination
            ),
            originalDestination
        )
    }

    @available(macOS 26.0, *)
    func testLiveVideoToolboxQuality720pRunsAdmittedScaleThenFinishes1080p()
        async throws {
        let source = try Self.makeNV12Buffer(
            resolution: .p720,
            seed: 29
        )
        let destination = try Self.makeNV12Buffer(
            resolution: .p1080,
            seed: 0
        )
        let originalDestination =
            try R13NV12Frame.captureTightActivePlanes(
                from: destination
            )
        let scaler = try R13VideoToolboxAdaptiveNativeScaler(
            path: .quality,
            videoFormat: .sdrBT709,
            presentationSourceResolution: .p720,
            requestedSourceResolution: .p720,
            requestedTargetResolution: .p1080
        )

        do {
            try await scaler.scale(
                source: source,
                destination: destination,
                frameIndex: 0,
                presentationTimestamp: .zero,
                frameDuration: CMTime(value: 1, timescale: 30),
                cancellation:
                    AppleUpscaleOperationCancellationSignal()
            )
            try await scaler.finish()
        } catch {
            await scaler.cancel()
            throw error
        }

        try R03NV12Contract.validate(
            pixelBuffer: destination,
            resolution: .p1080
        )
        XCTAssertNotEqual(
            try R13NV12Frame.captureTightActivePlanes(
                from: destination
            ),
            originalDestination
        )
    }

    func testRouterDispatchesEveryFrameAndUsesOrderedRuntimeFailover()
        async throws {
        let sourceResolution = VideoResolution(
            width: 64,
            height: 36
        )
        let targetResolution = VideoResolution(
            width: 160,
            height: 90
        )
        let plan = try R13AdaptiveScalePlan(
            sourceResolution: sourceResolution,
            targetResolution: targetResolution
        )
        let probe = R13AdaptiveRouterScalerProbe(
            failFirstAttempt: true
        )
        let candidateSet =
            try R13ProductASHScalingCandidateFactory
                .makeCandidates(
                    scalePlan: .adaptiveMPSLanczos(plan),
                    videoFormat: .sdrBT709,
                    orchestrationKind: .automatic,
                    makeScaler: { kind in
                        R13AdaptiveRouterTestScaler(
                            plan: plan,
                            kind: kind,
                            probe: probe
                        )
                    }
                )
        let router = try R13ProductASHScalingRouter(
            scaleContext: R13ProductASHScaleContext(
                adaptivePlan: plan,
                routeID: "adaptive_ash_auto"
            ),
            orchestrationKind: .automatic,
            processingConfiguration: .default,
            streamIdentifier: "router-unit",
            candidates: candidateSet.candidates,
            candidateExclusions: candidateSet.exclusions,
            declaredRouteIdentities:
                candidateSet.declaredRouteIdentities
        )
        let source = try Self.makeNV12Buffer(
            resolution: sourceResolution,
            seed: 19
        )
        let destination = try Self.makeNV12Buffer(
            resolution: targetResolution,
            seed: 0
        )
        let cancellation =
            AppleUpscaleOperationCancellationSignal()

        _ = try await router.scale(
            source: R13ProductASHPixelBuffer(value: source),
            destination:
                R13ProductASHPixelBuffer(value: destination),
            frameIndex: 0,
            frameDuration: CMTime(value: 1, timescale: 30),
            cancellation: cancellation
        )
        _ = try await router.scale(
            source: R13ProductASHPixelBuffer(value: source),
            destination:
                R13ProductASHPixelBuffer(value: destination),
            frameIndex: 1,
            frameDuration: CMTime(value: 1, timescale: 30),
            cancellation: cancellation
        )

        let summary = await router.finish()
        let metadata = try summary.outputMetadata()
        let snapshot = probe.snapshot
        XCTAssertEqual(summary.events.map(\.sequenceNumber), [0, 1])
        XCTAssertEqual(summary.events.first?.failedBackendIDs.count, 1)
        XCTAssertTrue(
            summary.events.dropFirst()
                .allSatisfy { $0.failedBackendIDs.isEmpty }
        )
        XCTAssertEqual(metadata.decisionCount, 2)
        XCTAssertEqual(metadata.fallbackCount, 1)
        XCTAssertEqual(metadata.modelStatus, "not_required")
        XCTAssertEqual(Set(snapshot.constructedKinds).count, 3)
        XCTAssertGreaterThanOrEqual(
            Set(snapshot.attemptedKinds).count,
            2
        )
        XCTAssertEqual(snapshot.finishedKinds.count, 3)
        XCTAssertEqual(
            snapshot.finishedKinds
                .reduce(into: [:]) { counts, kind in
                    counts[kind, default: 0] += 1
                },
            Dictionary(
                uniqueKeysWithValues:
                    Set(snapshot.constructedKinds)
                        .map { ($0, 1) }
            )
        )
    }

    func testEveryOrchestratedModeBuildsAndDispatchesDeclaredPool()
        async throws {
        let cases: [(
            mode: UpscaleMode,
            expectedKinds: [R13ReleaseScalerKind]
        )] = [
            (
                .auto,
                [
                    .highQualityVImage,
                    .deterministicMPSLanczos,
                    .fastMPSBilinear
                ]
            ),
            (
                .quality,
                [
                    .highQualityVImage,
                    .deterministicMPSLanczos
                ]
            ),
            (
                .fast,
                [
                    .fastMPSBilinear,
                    .deterministicMPSLanczos,
                    .highQualityVImage
                ]
            )
        ]
        for testCase in cases {
            let source = VideoResolution(width: 64, height: 36)
            let target = VideoResolution(width: 160, height: 90)
            let frames = try (0..<2).map {
                try R13ReleaseTestFrames.make(
                    resolution: source,
                    index: $0
                )
            }
            let eventLog = R13ReleaseTestEventLog()
            let media = R13ReleaseTestMediaPipeline(
                resolution: source,
                frames: frames,
                eventLog: eventLog
            )
            let probe = R13AdaptiveRouterScalerProbe(
                failFirstAttempt: true
            )
            let service = R13ReleaseUpscalerEngineService(
                media: media,
                modeAwareAdaptiveScalerFactory: {
                    plan,
                    binding in
                    R13AdaptiveRouterTestScaler(
                        plan: plan,
                        kind: binding.scalerKind,
                        probe: probe
                    )
                }
            )
            let identifier =
                "adaptive-router-\(testCase.mode.rawValue)-"
                + UUID().uuidString
            let job = UpscaleJob(
                identifier: identifier,
                inputURL: try makeInputFixtureURL(
                    identifier: identifier
                ),
                outputURL: makeOutputURL(
                    identifier: identifier
                ),
                targetResolution: target,
                preserveAudio: false,
                mode: testCase.mode,
                processingConfiguration:
                    UpscaleProcessingConfiguration(
                        strategyPreference: .adaptive,
                        temporalConsistencyEnabled: false
                    )
            )

            _ = try await service.submit(job).waitForCompletion()

            let snapshot = probe.snapshot
            let session = try XCTUnwrap(media.lastSession)
            let metadata = session.finalMetadata
            XCTAssertEqual(
                snapshot.constructedKinds,
                testCase.expectedKinds,
                "Unexpected declared pool for \(testCase.mode)."
            )
            XCTAssertGreaterThanOrEqual(
                Set(snapshot.attemptedKinds).count,
                2,
                "Runtime failure did not dispatch a different "
                    + "qualified candidate for \(testCase.mode)."
            )
            XCTAssertEqual(
                Set(snapshot.finishedKinds),
                Set(testCase.expectedKinds)
            )
            XCTAssertEqual(
                session.appendedFrameIndices,
                [0, 1]
            )
            XCTAssertEqual(
                metadata[
                    R13ProductASHDecisionMetadata.statusKey
                ],
                "complete"
            )
            XCTAssertEqual(
                metadata[
                    R13ProductASHDecisionMetadata
                        .decisionCountKey
                ],
                "2"
            )
            XCTAssertEqual(
                metadata[
                    R13ProductASHDecisionMetadata
                        .fallbackCountKey
                ],
                "1"
            )
            XCTAssertNotEqual(
                metadata[
                    R13ProductASHDecisionMetadata
                        .selectedBackendsKey
                ],
                "pending"
            )
            XCTAssertEqual(
                metadata[
                    R13ProductASHDecisionMetadata.modelStatusKey
                ],
                "not_required"
            )
            XCTAssertNotEqual(
                metadata[
                    R13ProductASHDecisionMetadata
                        .journalSHA256Key
                ],
                String(repeating: "0", count: 64)
            )
        }
    }

    func testCandidateConstructionFailureIsTypedAndBoundToFinalMetadata()
        async throws {
        let sourceResolution = VideoResolution(
            width: 64,
            height: 36
        )
        let targetResolution = VideoResolution(
            width: 160,
            height: 90
        )
        let plan = try R13AdaptiveScalePlan(
            sourceResolution: sourceResolution,
            targetResolution: targetResolution
        )
        let probe = R13AdaptiveRouterScalerProbe(
            failFirstAttempt: false
        )
        let candidateSet =
            try R13ProductASHScalingCandidateFactory
                .makeCandidates(
                    scalePlan: .adaptiveMPSLanczos(plan),
                    videoFormat: .sdrBT709,
                    orchestrationKind: .automatic,
                    makeScaler: { kind in
                        if kind == .fastMPSBilinear {
                            throw R03NV12ScalingError
                                .runtimeUnavailable(
                                    "r13_test_mps_bilinear_unavailable"
                                )
                        }
                        return R13AdaptiveRouterTestScaler(
                            plan: plan,
                            kind: kind,
                            probe: probe
                        )
                    }
                )
        let exclusion = try XCTUnwrap(
            candidateSet.exclusions.first
        )
        XCTAssertEqual(candidateSet.candidates.count, 2)
        XCTAssertEqual(candidateSet.exclusions.count, 1)
        XCTAssertEqual(
            exclusion.declaredKind,
            .fastMPSBilinear
        )
        XCTAssertEqual(
            exclusion.phase,
            .scalerConstruction
        )
        XCTAssertEqual(
            exclusion.failure.reasonCode,
            "runtime_unavailable"
        )
        XCTAssertEqual(exclusion.failure.detailSHA256.count, 64)

        let router = try R13ProductASHScalingRouter(
            scaleContext: R13ProductASHScaleContext(
                adaptivePlan: plan,
                routeID: "adaptive_ash_auto"
            ),
            orchestrationKind: .automatic,
            processingConfiguration: .default,
            streamIdentifier: "candidate-exclusion",
            candidates: candidateSet.candidates,
            candidateExclusions: candidateSet.exclusions,
            declaredRouteIdentities:
                candidateSet.declaredRouteIdentities
        )
        _ = try await router.scale(
            source: R13ProductASHPixelBuffer(
                value: try Self.makeNV12Buffer(
                    resolution: sourceResolution,
                    seed: 23
                )
            ),
            destination: R13ProductASHPixelBuffer(
                value: try Self.makeNV12Buffer(
                    resolution: targetResolution,
                    seed: 0
                )
            ),
            frameIndex: 0,
            frameDuration: CMTime(value: 1, timescale: 30),
            cancellation:
                AppleUpscaleOperationCancellationSignal()
        )
        let metadata = try await router.finish()
            .outputMetadata()

        XCTAssertEqual(metadata.candidateExclusionCount, 1)
        XCTAssertTrue(
            metadata.candidateExclusionsJSON.contains(
                R13ReleaseScalerKind.fastMPSBilinear.rawValue
            )
        )
        XCTAssertTrue(
            metadata.candidateExclusionsJSON.contains(
                "runtime_unavailable"
            )
        )
        XCTAssertEqual(
            metadata.values[
                R13ProductASHDecisionMetadata
                    .candidateExclusionCountKey
            ],
            "1"
        )
        XCTAssertNotEqual(
            metadata.journalSHA256,
            String(repeating: "0", count: 64)
        )
    }

    func testCachedPrefixRestoresExactRouterStateWithoutScalingReplay()
        async throws {
        let sourceResolution = VideoResolution(
            width: 64,
            height: 36
        )
        let targetResolution = VideoResolution(
            width: 160,
            height: 90
        )
        let plan = try R13AdaptiveScalePlan(
            sourceResolution: sourceResolution,
            targetResolution: targetResolution
        )
        let originalProbe = R13AdaptiveRouterScalerProbe(
            failFirstAttempt: false
        )
        let originalSet =
            try R13ProductASHScalingCandidateFactory
                .makeCandidates(
                    scalePlan: .adaptiveMPSLanczos(plan),
                    videoFormat: .sdrBT709,
                    orchestrationKind: .automatic,
                    makeScaler: { kind in
                        R13AdaptiveRouterTestScaler(
                            plan: plan,
                            kind: kind,
                            probe: originalProbe
                        )
                    }
                )
        let originalRouter = try R13ProductASHScalingRouter(
            scaleContext: R13ProductASHScaleContext(
                adaptivePlan: plan,
                routeID: "adaptive_ash_auto"
            ),
            orchestrationKind: .automatic,
            processingConfiguration: .default,
            streamIdentifier: "resume-router",
            candidates: originalSet.candidates,
            candidateExclusions: originalSet.exclusions,
            declaredRouteIdentities:
                originalSet.declaredRouteIdentities
        )
        let sourceFrames = try (0..<3).map {
            try Self.makeNV12Buffer(
                resolution: sourceResolution,
                seed: UInt8(31 + $0)
            )
        }
        let destination = try Self.makeNV12Buffer(
            resolution: targetResolution,
            seed: 0
        )
        for frameIndex in 0..<2 {
            _ = try await originalRouter.scale(
                source: R13ProductASHPixelBuffer(
                    value: sourceFrames[frameIndex]
                ),
                destination: R13ProductASHPixelBuffer(
                    value: destination
                ),
                frameIndex: frameIndex,
                frameDuration:
                    CMTime(value: 1, timescale: 30),
                cancellation:
                    AppleUpscaleOperationCancellationSignal()
            )
        }
        let originalSummary = await originalRouter.finish()
        XCTAssertEqual(originalSummary.events.count, 2)
        let replayEvents = originalSummary.events.enumerated()
            .map { index, event in
                R13ProductASHDecisionEvent(
                    sequenceNumber: event.sequenceNumber,
                    selectedRouteIdentity:
                        event.selectedRouteIdentity,
                    reason: event.reason,
                    fallbackHistory:
                        event.fallbackHistory,
                    processingPressureQ16:
                        Int64((index + 1) * 1_024)
                )
            }

        let resumedProbe = R13AdaptiveRouterScalerProbe(
            failFirstAttempt: false
        )
        let resumedSet =
            try R13ProductASHScalingCandidateFactory
                .makeCandidates(
                    scalePlan: .adaptiveMPSLanczos(plan),
                    videoFormat: .sdrBT709,
                    orchestrationKind: .automatic,
                    makeScaler: { kind in
                        R13AdaptiveRouterTestScaler(
                            plan: plan,
                            kind: kind,
                            probe: resumedProbe
                        )
                    }
                )
        let resumedRouter = try R13ProductASHScalingRouter(
            scaleContext: R13ProductASHScaleContext(
                adaptivePlan: plan,
                routeID: "adaptive_ash_auto"
            ),
            orchestrationKind: .automatic,
            processingConfiguration: .default,
            streamIdentifier: "resume-router",
            candidates: resumedSet.candidates,
            candidateExclusions: resumedSet.exclusions,
            declaredRouteIdentities:
                resumedSet.declaredRouteIdentities
        )
        for frameIndex in 0..<2 {
            try await resumedRouter.replayCachedDecision(
                source: R13ProductASHPixelBuffer(
                    value: sourceFrames[frameIndex]
                ),
                frameIndex: frameIndex,
                decision: replayEvents[frameIndex],
                isFinalCachedPrefixFrame: frameIndex == 1
            )
        }
        XCTAssertTrue(
            resumedProbe.snapshot.attemptedKinds.isEmpty,
            "Stateless cached replay must not rerun a scaler."
        )
        _ = try await resumedRouter.scale(
            source: R13ProductASHPixelBuffer(
                value: sourceFrames[2]
            ),
            destination: R13ProductASHPixelBuffer(
                value: destination
            ),
            frameIndex: 2,
            frameDuration: CMTime(value: 1, timescale: 30),
            cancellation:
                AppleUpscaleOperationCancellationSignal()
        )
        let resumedSummary = await resumedRouter.finish()
        let metadata = try resumedSummary.outputMetadata()

        XCTAssertEqual(
            Array(resumedSummary.events.prefix(2)),
            replayEvents
        )
        XCTAssertEqual(
            resumedSummary.events.map(\.sequenceNumber),
            [0, 1, 2]
        )
        XCTAssertEqual(
            resumedSummary.resumeBoundaries,
            [
                R13ProductASHResumeBoundary(
                    sequenceNumber: 1,
                    kind: .statelessScalerStateRestored
                )
            ]
        )
        XCTAssertEqual(metadata.decisionCount, 3)
        XCTAssertEqual(metadata.resumeBoundaryCount, 1)
        XCTAssertTrue(
            metadata.resumeBoundariesJSON.contains(
                "stateless_scaler_state_restored"
            )
        )
        XCTAssertEqual(
            resumedProbe.snapshot.attemptedKinds.count,
            1,
            "Only the uncached suffix frame may execute a scaler."
        )
    }

    func testAllCandidateConstructionFailuresPreserveEveryExclusion()
        throws {
        let plan = try R13AdaptiveScalePlan(
            sourceResolution:
                VideoResolution(width: 64, height: 36),
            targetResolution:
                VideoResolution(width: 160, height: 90)
        )

        XCTAssertThrowsError(
            try R13ProductASHScalingCandidateFactory
                .makeCandidates(
                    scalePlan: .adaptiveMPSLanczos(plan),
                    videoFormat: .sdrBT709,
                    orchestrationKind: .automatic,
                    makeScaler: { kind in
                        throw R03NV12ScalingError
                            .runtimeUnavailable(
                                "r13_test_"
                                    + "\(kind.rawValue)_unavailable"
                            )
                    }
                )
        ) { error in
            guard case R13ProductASHScalingRouterError
                .noAdmittedCandidates(let exclusions) = error
            else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(exclusions.count, 3)
            XCTAssertEqual(
                Set(exclusions.map(\.declaredKind)),
                Set(
                    R13A11ProductSessionFactory
                        .fallbackProfiles(for: .automatic)
                        .map {
                        R13ProductASHCandidateKind(
                            scalerKind: $0.kind
                        )
                    }
                )
            )
            XCTAssertTrue(
                exclusions.allSatisfy {
                    $0.phase == .scalerConstruction
                        && $0.failure.reasonCode
                            == "runtime_unavailable"
                }
            )
        }
    }

    func testExplicitEnginePreferencesRemainDirectAndExact()
        async throws {
        let cases: [(
            preference: UpscaleEnginePreference,
            expectedKind: R13ReleaseScalerKind
        )] = [
            (
                .accelerateVImageHighQuality,
                .highQualityVImage
            ),
            (.mpsBilinear, .fastMPSBilinear),
            (.mpsLanczos, .deterministicMPSLanczos)
        ]
        for testCase in cases {
            let source = VideoResolution(width: 64, height: 36)
            let target = VideoResolution(width: 160, height: 90)
            let eventLog = R13ReleaseTestEventLog()
            let media = R13ReleaseTestMediaPipeline(
                resolution: source,
                frames: [
                    try R13ReleaseTestFrames.make(
                        resolution: source,
                        index: 0
                    )
                ],
                eventLog: eventLog
            )
            let probe = R13AdaptiveRouterScalerProbe(
                failFirstAttempt: false
            )
            let service = R13ReleaseUpscalerEngineService(
                media: media,
                modeAwareAdaptiveScalerFactory: {
                    plan,
                    binding in
                    R13AdaptiveRouterTestScaler(
                        plan: plan,
                        kind: binding.scalerKind,
                        probe: probe
                    )
                }
            )
            let identifier =
                "adaptive-direct-"
                + "\(testCase.preference.rawValue)-"
                + UUID().uuidString
            let job = UpscaleJob(
                identifier: identifier,
                inputURL: try makeInputFixtureURL(
                    identifier: identifier
                ),
                outputURL: makeOutputURL(
                    identifier: identifier
                ),
                targetResolution: target,
                preserveAudio: false,
                mode: .auto,
                processingConfiguration:
                    UpscaleProcessingConfiguration(
                        enginePreference:
                            testCase.preference,
                        strategyPreference: .adaptive,
                        temporalConsistencyEnabled: false
                    )
            )

            _ = try await service.submit(job).waitForCompletion()

            let snapshot = probe.snapshot
            XCTAssertEqual(
                snapshot.constructedKinds,
                [testCase.expectedKind]
            )
            XCTAssertEqual(
                snapshot.attemptedKinds,
                [testCase.expectedKind]
            )
            XCTAssertEqual(
                snapshot.finishedKinds,
                [testCase.expectedKind]
            )
            XCTAssertNil(
                media.lastSession?.finalMetadata[
                    R13ProductASHDecisionMetadata.statusKey
                ]
            )
        }
    }

    func testFormatPreservingAdaptiveRouterProcessesP010HDRAndBGRAAlpha()
        async throws {
        let source = VideoResolution(width: 4, height: 4)
        let target = VideoResolution(width: 10, height: 10)
        let formats: [MediaVideoFormat] = [
            .hdrBT2020PQ(
                masteringDisplayColorVolume:
                    Data((0x20..<(0x20 + 24)).map(UInt8.init)),
                contentLightLevelInfo:
                    Data([0x11, 0x22, 0x33, 0x44])
            ),
            .sdrBT709WithAlpha(mode: .straight)
        ]
        for (ordinal, format) in formats.enumerated() {
            let record = try Self.makeExtendedFrameRecord(
                resolution: source,
                format: format,
                frameIndex: 0
            )
            let eventLog = R13ReleaseTestEventLog()
            let media = R13ReleaseTestMediaPipeline(
                resolution: source,
                frames: [record],
                eventLog: eventLog,
                videoFormat: format,
                captureAppendedFrames: true
            )
            let service = R13ReleaseUpscalerEngineService(
                media: media
            )
            let identifier =
                "adaptive-extended-\(ordinal)-"
                + UUID().uuidString
            let job = UpscaleJob(
                identifier: identifier,
                inputURL: try makeInputFixtureURL(
                    identifier: identifier
                ),
                outputURL: makeOutputURL(
                    identifier: identifier
                ),
                targetResolution: target,
                codec: .hevc,
                preserveAudio: false,
                mode: .auto,
                processingConfiguration:
                    UpscaleProcessingConfiguration(
                        strategyPreference: .adaptive,
                        temporalConsistencyEnabled: false
                    )
            )

            _ = try await service.submit(job).waitForCompletion()

            let session = try XCTUnwrap(media.lastSession)
            let captured = try XCTUnwrap(
                session.appendedFrames.first
            )
            let output = try captured.makePixelBuffer(
                videoFormat: format
            )
            try R13MediaVideoFormatContract.validate(
                output,
                resolution: target,
                format: format
            )
            XCTAssertEqual(
                session.finalMetadata[
                    R13ProductASHDecisionMetadata.statusKey
                ],
                "complete"
            )
            XCTAssertEqual(
                session.finalMetadata[
                    R13ProductASHDecisionMetadata
                        .decisionCountKey
                ],
                "1"
            )
            XCTAssertEqual(
                session.finalMetadata[
                    R13ProductASHDecisionMetadata.modelStatusKey
                ],
                "not_required"
            )
            switch format.pixelStorage {
            case .p010VideoRange10Bit:
                try Self.assertCanonicalP010(output)
            case .bgra8WithAlpha:
                let alpha = try Self.alphaBytes(output)
                XCTAssertTrue(
                    alpha.contains { $0 > 0 && $0 < 255 }
                )
            case .nv12VideoRange8Bit:
                XCTFail("The test matrix contains only extended formats.")
            default:
                throw R13AdaptiveTestError.unsupportedFixtureFormat(
                    format.pixelStorage.rawValue
                )
            }
        }
    }

    func testFormatPreservingAdaptiveServiceEnhancesBeforeVImageScaling()
        async throws {
        let source = VideoResolution(width: 4, height: 4)
        let target = VideoResolution(width: 10, height: 10)
        let format = MediaVideoFormat.sdrBT709WithAlpha(
            mode: .straight
        )
        let record = try Self.makeExtendedFrameRecord(
            resolution: source,
            format: format,
            frameIndex: 0
        )
        let eventLog = R13ReleaseTestEventLog()
        let media = R13ReleaseTestMediaPipeline(
            resolution: source,
            frames: [record],
            eventLog: eventLog,
            videoFormat: format,
            captureAppendedFrames: true
        )
        let service = R13ReleaseUpscalerEngineService(media: media)
        let identifier =
            "adaptive-format-order-" + UUID().uuidString
        let configuration = UpscaleProcessingConfiguration(
            enginePreference: .accelerateVImageStandard,
            strategyPreference: .adaptive,
            temporalConsistencyEnabled: false,
            edgeFidelityLevel: .high,
            detailRecoveryLevel: .high
        )
        let job = UpscaleJob(
            identifier: identifier,
            inputURL: try makeInputFixtureURL(identifier: identifier),
            outputURL: makeOutputURL(identifier: identifier),
            targetResolution: target,
            codec: .hevc,
            preserveAudio: false,
            mode: .auto,
            processingConfiguration: configuration
        )

        _ = try await service.submit(job).waitForCompletion()

        let actual = try XCTUnwrap(
            media.lastSession?.appendedFrames.first
        )
        let plan = try R13AdaptiveScalePlan(
            sourceResolution: source,
            targetResolution: target
        )
        let normalized = try R13ReleaseVideoFrameNormalizer(
            nv12: R13NV12FrameNormalizer()
        ).normalizeForAdaptiveScaling(
            record.pixelBuffer,
            codedResolution: source,
            presentationResolution: source,
            processingResolution: plan.processingSourceResolution,
            pixelAspectRatio: nil,
            videoFormat: format
        )
        let forwardEnhancer = try R13ReleaseFormatEnhancementProcessor(
            targetResolution: plan.processingSourceResolution,
            videoFormat: format,
            temporalConsistencyEnabled: false,
            edgeFidelityLevel: configuration.edgeFidelityLevel,
            detailRecoveryLevel: configuration.detailRecoveryLevel,
            edgePreservationEnabled: false,
            compressionCleanupEnabled: false,
            textureGrainProtectionEnabled: false,
            temporalStabilityEnabled: false
        )
        let enhancedSource = try forwardEnhancer.process(normalized)
        try forwardEnhancer.finish()

        func makeTargetBuffer() throws -> CVPixelBuffer {
            let pool = try PixelBufferBridge.makePool(
                width: target.width,
                height: target.height,
                format: format.pixelStorage.pixelFormat,
                capacity: 1
            )
            let buffer = try PixelBufferBridge.dequeue(from: pool)
            R13MediaVideoFormatContract.install(
                format,
                on: buffer,
                resolution: target
            )
            return buffer
        }

        let scaler = R13FormatPreservingVImageScaler(
            sourceResolution: plan.processingSourceResolution,
            targetResolution: target,
            videoFormat: format,
            quality: .fast
        )
        let forwardOutput = try makeTargetBuffer()
        try scaler.scale(
            source: enhancedSource,
            destination: forwardOutput,
            cancellation: AppleUpscaleOperationCancellationSignal()
        )
        let forward = try R13NV12Frame.captureTightActivePlanes(
            from: forwardOutput
        )

        let scaledFirst = try makeTargetBuffer()
        try scaler.scale(
            source: normalized,
            destination: scaledFirst,
            cancellation: AppleUpscaleOperationCancellationSignal()
        )
        let reverseEnhancer = try R13ReleaseFormatEnhancementProcessor(
            targetResolution: target,
            videoFormat: format,
            temporalConsistencyEnabled: false,
            edgeFidelityLevel: configuration.edgeFidelityLevel,
            detailRecoveryLevel: configuration.detailRecoveryLevel,
            edgePreservationEnabled: false,
            compressionCleanupEnabled: false,
            textureGrainProtectionEnabled: false,
            temporalStabilityEnabled: false
        )
        let reverseOutput = try reverseEnhancer.process(scaledFirst)
        try reverseEnhancer.finish()
        let reverse = try R13NV12Frame.captureTightActivePlanes(
            from: reverseOutput
        )

        XCTAssertEqual(
            actual,
            forward,
            "Production must normalize, enhance at source size, then scale."
        )
        XCTAssertNotEqual(
            actual,
            reverse,
            "The fixture must distinguish enhancement-before-scaling from "
                + "the rejected scale-before-enhancement order."
        )
    }

    func testInterruptedRoutedAdaptiveJobRestoresCachedJournalAndRunsOnlySuffix()
        async throws {
        for cachedPrefixCount in [2, 3] {
        let workspace = try R13IntegrationWorkspace(
            outputFileName:
                "adaptive-routed-resume-"
                + "\(cachedPrefixCount).mov"
        )
        defer { workspace.remove() }
        try workspace.writeOpaqueSource(
            Data(
                "adaptive-routed-resume-source-\(cachedPrefixCount)"
                    .utf8
            )
        )
        let source = VideoResolution(width: 64, height: 36)
        let target = VideoResolution(width: 160, height: 90)
        let frames = try (0..<3).map {
            try R13ReleaseTestFrames.make(
                resolution: source,
                index: $0
            )
        }
        let media = R13IntegrationMediaPipeline(
            resolution: source,
            frames: frames,
            estimatedFrameCount: frames.count,
            failureThresholds: [cachedPrefixCount, nil]
        )
        let harness = try R13IntegrationHardeningHarness.make(
            jobsRootURL: workspace.jobsRootURL,
            exactFrameCount: frames.count
        )
        let probe = R13AdaptiveRouterScalerProbe(
            failFirstAttempt: false
        )
        let service = R13ReleaseUpscalerEngineService(
            media: media,
            modeAwareAdaptiveScalerFactory: {
                plan,
                binding in
                R13AdaptiveRouterTestScaler(
                    plan: plan,
                    kind: binding.scalerKind,
                    probe: probe
                )
            },
            hardeningRuntime: harness.runtime
        )
        let job = UpscaleJob(
            identifier:
                "adaptive-routed-resume-"
                + "\(cachedPrefixCount)",
            inputURL: workspace.sourceURL,
            outputURL: workspace.outputURL,
            targetResolution: target,
            codec: .h264,
            preserveAudio: false,
            mode: .auto,
            processingConfiguration:
                UpscaleProcessingConfiguration(
                    strategyPreference: .adaptive,
                    temporalConsistencyEnabled: false
                )
        )

        do {
            _ = try await service.submit(job)
                .waitForCompletion()
            XCTFail("The first media attempt must be interrupted.")
        } catch {
            XCTAssertEqual(
                error as? R13IntegrationMediaError,
                .interrupted
            )
        }
        XCTAssertEqual(media.beginSessionCount, 1)
        XCTAssertEqual(
            media.sessions.first?.appendedFrameIndices,
            Array(0..<cachedPrefixCount)
        )
        XCTAssertEqual(
            probe.snapshot.attemptedKinds.count,
            cachedPrefixCount
        )

        let result = try await service.submit(job)
            .waitForCompletion()

        XCTAssertEqual(result, workspace.outputURL)
        XCTAssertEqual(media.beginSessionCount, 2)
        let resumedSession = try XCTUnwrap(
            media.sessions.last
        )
        XCTAssertEqual(
            resumedSession.appendedFrameIndices,
            [0, 1, 2]
        )
        XCTAssertEqual(
            probe.snapshot.attemptedKinds.count,
            3,
            "Cached frames must restore logical router state "
                + "without scaling; only an uncached suffix "
                + "may execute after resume."
        )
        XCTAssertEqual(
            resumedSession.finalMetadata[
                R13ProductASHDecisionMetadata.statusKey
            ],
            "complete"
        )
        XCTAssertEqual(
            resumedSession.finalMetadata[
                R13ProductASHDecisionMetadata.decisionCountKey
            ],
            "3"
        )
        XCTAssertEqual(
            resumedSession.finalMetadata[
                R13ProductASHDecisionMetadata
                    .resumeBoundaryCountKey
            ],
            "1"
        )
        XCTAssertTrue(
            resumedSession.finalMetadata[
                R13ProductASHDecisionMetadata
                    .resumeBoundariesKey
            ]?.contains(
                "stateless_scaler_state_restored"
            ) == true
        )
        XCTAssertNotEqual(
            resumedSession.finalMetadata[
                R13ProductASHDecisionMetadata
                    .journalSHA256Key
            ],
            String(repeating: "0", count: 64)
        )
        let recoverableJobs = try await service
            .recoverableJobs()
        XCTAssertTrue(recoverableJobs.jobs.isEmpty)
        }
    }
}

private extension R13AdaptiveASHRoutingScalerTests {
    func makeInputFixtureURL(
        identifier: String
    ) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "mirmir-adaptive-routing-\(UUID().uuidString)",
                isDirectory: true
            )
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false
            )
            let sourceURL = directory.appendingPathComponent(
                "source.mp4",
                isDirectory: false
            )
            try Data(
                "mirmir-adaptive-routing-source:\(identifier)".utf8
            ).write(to: sourceURL, options: .atomic)
            addTeardownBlock {
                try? FileManager.default.removeItem(at: directory)
            }
            return sourceURL
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func makeOutputURL(identifier: String) -> URL {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "\(identifier).mp4",
                isDirectory: false
            )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: output)
        }
        return output
    }

    static func makeNV12Buffer(
        resolution: VideoResolution,
        seed: UInt8
    ) throws -> CVPixelBuffer {
        let pool = try PixelBufferBridge.makePool(
            width: resolution.width,
            height: resolution.height,
            format: R03NV12Contract.pixelFormat,
            capacity: 1
        )
        let buffer = try PixelBufferBridge.dequeue(from: pool)
        R13NV12GeometryTransfer.installCanonicalAttachments(
            on: buffer,
            resolution: resolution
        )
        R03NV12Contract.installColorAttachments(on: buffer)
        let lockStatus = CVPixelBufferLockBaseAddress(buffer, [])
        guard lockStatus == kCVReturnSuccess else {
            throw R03NV12ScalingError.pixelBufferLockFailed(
                destination: false,
                status: lockStatus
            )
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let luma = try XCTUnwrap(
            CVPixelBufferGetBaseAddressOfPlane(buffer, 0)
        ).assumingMemoryBound(to: UInt8.self)
        let chroma = try XCTUnwrap(
            CVPixelBufferGetBaseAddressOfPlane(buffer, 1)
        ).assumingMemoryBound(to: UInt8.self)
        let lumaStride =
            CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let chromaStride =
            CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        for row in 0..<resolution.height {
            for column in 0..<resolution.width {
                luma[row * lumaStride + column] =
                    16
                    + UInt8(
                        (
                            Int(seed)
                                + row * resolution.width
                                + column
                        ) % 220
                    )
            }
        }
        for row in 0..<(resolution.height / 2) {
            for column in 0..<resolution.width {
                chroma[row * chromaStride + column] =
                    UInt8(96 + (column + Int(seed)) % 64)
            }
        }
        return buffer
    }

    static func makeExtendedFrameRecord(
        resolution: VideoResolution,
        format: MediaVideoFormat,
        frameIndex: Int
    ) throws -> FrameRecord {
        let pool = try PixelBufferBridge.makePool(
            width: resolution.width,
            height: resolution.height,
            format: format.pixelStorage.pixelFormat,
            capacity: 1
        )
        let buffer = try PixelBufferBridge.dequeue(from: pool)
        R13MediaVideoFormatContract.install(
            format,
            on: buffer,
            resolution: resolution
        )
        let lockStatus = CVPixelBufferLockBaseAddress(buffer, [])
        guard lockStatus == kCVReturnSuccess else {
            throw R03NV12ScalingError.pixelBufferLockFailed(
                destination: false,
                status: lockStatus
            )
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        switch format.pixelStorage {
        case .nv12VideoRange8Bit:
            XCTFail("This helper is limited to extended formats.")
        case .p010VideoRange10Bit:
            let luma = try XCTUnwrap(
                CVPixelBufferGetBaseAddressOfPlane(buffer, 0)
            ).assumingMemoryBound(to: UInt16.self)
            let chroma = try XCTUnwrap(
                CVPixelBufferGetBaseAddressOfPlane(buffer, 1)
            ).assumingMemoryBound(to: UInt16.self)
            let lumaStride =
                CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) / 2
            let chromaStride =
                CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) / 2
            for row in 0..<resolution.height {
                for column in 0..<resolution.width {
                    let code =
                        64
                        + (row * resolution.width + column)
                            % 877
                    luma[row * lumaStride + column] =
                        UInt16(code << 6)
                }
            }
            for row in 0..<(resolution.height / 2) {
                for column in 0..<resolution.width {
                    let code = 384 + column % 256
                    chroma[row * chromaStride + column] =
                        UInt16(code << 6)
                }
            }
        case .bgra8WithAlpha:
            let base = try XCTUnwrap(
                CVPixelBufferGetBaseAddress(buffer)
            ).assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            for row in 0..<resolution.height {
                for column in 0..<resolution.width {
                    let offset = row * stride + column * 4
                    base[offset] = UInt8((column * 41) % 256)
                    base[offset + 1] = UInt8((row * 53) % 256)
                    base[offset + 2] =
                        UInt8(((row + column) * 29) % 256)
                    base[offset + 3] =
                        UInt8(
                            32
                                + (
                                    row * resolution.width
                                        + column
                                ) % 192
                        )
                }
            }
        default:
            throw R13AdaptiveTestError.unsupportedFixtureFormat(
                format.pixelStorage.rawValue
            )
        }
        return FrameRecord(
            pixelBuffer: buffer,
            timing: FrameTiming(
                frameIndex: frameIndex,
                presentationTime:
                    CMTime(value: Int64(frameIndex), timescale: 30),
                duration: CMTime(value: 1, timescale: 30)
            )
        )
    }

    static func assertCanonicalP010(
        _ pixelBuffer: CVPixelBuffer
    ) throws {
        let lockStatus = CVPixelBufferLockBaseAddress(
            pixelBuffer,
            .readOnly
        )
        guard lockStatus == kCVReturnSuccess else {
            throw R03NV12ScalingError.pixelBufferLockFailed(
                destination: false,
                status: lockStatus
            )
        }
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        }
        for plane in 0..<2 {
            let base = try XCTUnwrap(
                CVPixelBufferGetBaseAddressOfPlane(
                    pixelBuffer,
                    plane
                )
            ).assumingMemoryBound(to: UInt16.self)
            let stride =
                CVPixelBufferGetBytesPerRowOfPlane(
                    pixelBuffer,
                    plane
                ) / 2
            let width =
                CVPixelBufferGetWidthOfPlane(pixelBuffer, plane)
                * (plane == 1 ? 2 : 1)
            let height =
                CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
            for row in 0..<height {
                for column in 0..<width {
                    let word = base[row * stride + column]
                    XCTAssertEqual(word & 0x003f, 0)
                    let code = Int(word >> 6)
                    XCTAssertTrue(
                        plane == 0
                            ? (64...940).contains(code)
                            : (64...960).contains(code)
                    )
                }
            }
        }
    }

    static func alphaBytes(
        _ pixelBuffer: CVPixelBuffer
    ) throws -> [UInt8] {
        let lockStatus = CVPixelBufferLockBaseAddress(
            pixelBuffer,
            .readOnly
        )
        guard lockStatus == kCVReturnSuccess else {
            throw R03NV12ScalingError.pixelBufferLockFailed(
                destination: false,
                status: lockStatus
            )
        }
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        }
        let base = try XCTUnwrap(
            CVPixelBufferGetBaseAddress(pixelBuffer)
        ).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        return (0..<height).flatMap { row in
            (0..<width).map { column in
                base[row * stride + column * 4 + 3]
            }
        }
    }
}

private final class R13AdaptiveRouterTestScaler:
    R03NV12Scaling,
    @unchecked Sendable {
    private let plan: R13AdaptiveScalePlan
    private let kind: R13ReleaseScalerKind
    private let probe: R13AdaptiveRouterScalerProbe

    init(
        plan: R13AdaptiveScalePlan,
        kind: R13ReleaseScalerKind,
        probe: R13AdaptiveRouterScalerProbe
    ) {
        self.plan = plan
        self.kind = kind
        self.probe = probe
        probe.recordConstruction(kind)
    }

    func scale(
        source: CVPixelBuffer,
        destination: CVPixelBuffer,
        cancellation:
            AppleUpscaleOperationCancellationSignal
    ) throws {
        guard !cancellation.isCancelled else {
            throw R03NV12ScalingError.operationCancelled
        }
        guard probe.beginAttempt(kind) else {
            throw R03NV12ScalingError.runtimeUnavailable(
                "r13_test_forced_candidate_failure"
            )
        }
        try R03NV12Contract.validate(
            pixelBuffer: source,
            resolution: plan.processingSourceResolution
        )
        try R03NV12Contract.validate(
            pixelBuffer: destination,
            resolution: plan.targetResolution
        )
        let lockStatus =
            CVPixelBufferLockBaseAddress(destination, [])
        guard lockStatus == kCVReturnSuccess else {
            throw R03NV12ScalingError.pixelBufferLockFailed(
                destination: true,
                status: lockStatus
            )
        }
        defer {
            CVPixelBufferUnlockBaseAddress(destination, [])
        }
        guard let lumaAddress =
                CVPixelBufferGetBaseAddressOfPlane(
                    destination,
                    0
                ),
              let chromaAddress =
                CVPixelBufferGetBaseAddressOfPlane(
                    destination,
                    1
                ) else {
            throw R03NV12ScalingError.missingPlaneBaseAddress(
                plane: 0
            )
        }
        let luma = lumaAddress.assumingMemoryBound(
            to: UInt8.self
        )
        let chroma = chromaAddress.assumingMemoryBound(
            to: UInt8.self
        )
        let lumaStride =
            CVPixelBufferGetBytesPerRowOfPlane(destination, 0)
        let chromaStride =
            CVPixelBufferGetBytesPerRowOfPlane(destination, 1)
        let lumaValue: UInt8
        switch kind {
        case .standardVImage:
            lumaValue = 64
        case .highQualityVImage:
            lumaValue = 72
        case .deterministicMPSLanczos:
            lumaValue = 104
        case .fastMPSBilinear:
            lumaValue = 136
        case .coreImageLanczos:
            lumaValue = 80
        case .coreImageBicubic:
            lumaValue = 88
        case .videoToolboxPixelTransfer:
            lumaValue = 96
        }
        for row in 0..<plan.targetResolution.height {
            luma.advanced(by: row * lumaStride)
                .initialize(
                    repeating: lumaValue,
                    count: plan.targetResolution.width
                )
        }
        for row in 0..<(plan.targetResolution.height / 2) {
            chroma.advanced(by: row * chromaStride)
                .initialize(
                    repeating: 128,
                    count: plan.targetResolution.width
                )
        }
        probe.recordSuccess(kind)
    }

    func reset() {
        probe.recordReset(kind)
    }

    func finish() {
        probe.recordFinish(kind)
    }

    func cancel() {
        probe.recordCancel(kind)
    }
}

private final class R13AdaptiveRouterScalerProbe:
    @unchecked Sendable {
    struct Snapshot: Sendable {
        let constructedKinds: [R13ReleaseScalerKind]
        let attemptedKinds: [R13ReleaseScalerKind]
        let successfulKinds: [R13ReleaseScalerKind]
        let resetKinds: [R13ReleaseScalerKind]
        let finishedKinds: [R13ReleaseScalerKind]
        let cancelledKinds: [R13ReleaseScalerKind]
    }

    private struct State {
        var constructedKinds: [R13ReleaseScalerKind] = []
        var attemptedKinds: [R13ReleaseScalerKind] = []
        var successfulKinds: [R13ReleaseScalerKind] = []
        var resetKinds: [R13ReleaseScalerKind] = []
        var finishedKinds: [R13ReleaseScalerKind] = []
        var cancelledKinds: [R13ReleaseScalerKind] = []
        var failNextAttempt: Bool
    }

    private let state: OSAllocatedUnfairLock<State>

    init(failFirstAttempt: Bool) {
        state = OSAllocatedUnfairLock(
            initialState: State(
                failNextAttempt: failFirstAttempt
            )
        )
    }

    var snapshot: Snapshot {
        state.withLock {
            Snapshot(
                constructedKinds: $0.constructedKinds,
                attemptedKinds: $0.attemptedKinds,
                successfulKinds: $0.successfulKinds,
                resetKinds: $0.resetKinds,
                finishedKinds: $0.finishedKinds,
                cancelledKinds: $0.cancelledKinds
            )
        }
    }

    func recordConstruction(_ kind: R13ReleaseScalerKind) {
        state.withLock { $0.constructedKinds.append(kind) }
    }

    func beginAttempt(_ kind: R13ReleaseScalerKind) -> Bool {
        state.withLock {
            $0.attemptedKinds.append(kind)
            if $0.failNextAttempt {
                $0.failNextAttempt = false
                return false
            }
            return true
        }
    }

    func recordSuccess(_ kind: R13ReleaseScalerKind) {
        state.withLock { $0.successfulKinds.append(kind) }
    }

    func recordReset(_ kind: R13ReleaseScalerKind) {
        state.withLock { $0.resetKinds.append(kind) }
    }

    func recordFinish(_ kind: R13ReleaseScalerKind) {
        state.withLock { $0.finishedKinds.append(kind) }
    }

    func recordCancel(_ kind: R13ReleaseScalerKind) {
        state.withLock { $0.cancelledKinds.append(kind) }
    }
}
