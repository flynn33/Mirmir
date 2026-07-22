import XCTest
@testable import Mirmir

final class R07FunctionalSupportExecutorTests: XCTestCase {
    private let executor = R07DeterministicFixtureSupportExecutor()

    func testA04GoldenBlendOcclusionAndBypassStates() throws {
        var occlusion = R07FunctionalTestFixtures.constant(0)
        occlusion[1] = 1
        let identity = R07FunctionalTestFixtures.identity(.temporalNoiseFilter)
        let continuous = try executor.execute(
            .a04(
                identity: identity,
                currentLumaQ16: R07FunctionalTestFixtures.constant(40_000),
                strengthQ16: R07SupportStagePolicy.a04StrengthQ16,
                temporalState: .continuous(
                    alignedHistoryLumaQ16:
                        R07FunctionalTestFixtures.constant(20_000),
                    occlusionMask: occlusion
                )
            )
        )
        guard case .denoisedLumaQ16(let blended) = continuous.payload else {
            return XCTFail("A04 returned the wrong payload")
        }

        XCTAssertEqual(blended[0], 32_500)
        XCTAssertEqual(blended[1], 40_000)
        for state in [
            R07FunctionalA04TemporalState.currentOnlyInvalidMotion,
            .discontinuity
        ] {
            let execution = try executor.execute(
                .a04(
                    identity: identity,
                    currentLumaQ16: R07FunctionalTestFixtures.constant(40_000),
                    strengthQ16: R07SupportStagePolicy.a04StrengthQ16,
                    temporalState: state
                )
            )
            XCTAssertEqual(
                execution.payload,
                .denoisedLumaQ16(R07FunctionalTestFixtures.constant(40_000))
            )
        }
    }

    func testA13GoldenDistinctPlanesAndProtectionBlend() throws {
        let center = 32 * R07FunctionalSupportGeometry.fullWidth + 32
        var cb = R07FunctionalTestFixtures.constant(20_000)
        var cr = R07FunctionalTestFixtures.constant(30_000)
        cb[center] = 10_000
        cr[center] = 50_000
        let identity = R07FunctionalTestFixtures.identity(.mpsGuidedFilter)
        let unprotected = try executor.execute(
            .a13(
                identity: identity,
                sourceChromaCbQ16: cb,
                sourceChromaCrQ16: cr,
                sameFrameLumaQ16: R07FunctionalTestFixtures.constant(30_000),
                protectionMaskQ15: R07FunctionalTestFixtures.constant(0)
            )
        )
        guard case .reconstructedChromaQ16(let filteredCb, let filteredCr) =
            unprotected.payload else {
            return XCTFail("A13 returned the wrong payload")
        }

        XCTAssertEqual(filteredCb[center], 19_600)
        XCTAssertEqual(filteredCr[center], 30_800)
        XCTAssertNotEqual(filteredCb, filteredCr)
        var protection = R07FunctionalTestFixtures.constant(0)
        protection[center] = R06ASHQ15.maximum
        let protected = try executor.execute(
            .a13(
                identity: identity,
                sourceChromaCbQ16: cb,
                sourceChromaCrQ16: cr,
                sameFrameLumaQ16: R07FunctionalTestFixtures.constant(30_000),
                protectionMaskQ15: protection
            )
        )
        guard case .reconstructedChromaQ16(let protectedCb, let protectedCr) =
            protected.payload else {
            return XCTFail("A13 returned the wrong protected payload")
        }
        XCTAssertEqual(protectedCb[center], 10_000)
        XCTAssertEqual(protectedCr[center], 50_000)
    }

    func testA13LumaGuidanceDoesNotBlurAcrossStrongEdge() throws {
        let cb = R07FunctionalTestFixtures.edgePlane(low: 10_000, high: 50_000)
        let cr = R07FunctionalTestFixtures.edgePlane(low: 15_000, high: 45_000)
        let luma = R07FunctionalTestFixtures.edgePlane(low: 0, high: 65_536)
        let execution = try executor.execute(
            .a13(
                identity: R07FunctionalTestFixtures.identity(.mpsGuidedFilter),
                sourceChromaCbQ16: cb,
                sourceChromaCrQ16: cr,
                sameFrameLumaQ16: luma,
                protectionMaskQ15: R07FunctionalTestFixtures.constant(0)
            )
        )
        guard case .reconstructedChromaQ16(let outputCb, let outputCr) =
            execution.payload else {
            return XCTFail("A13 returned the wrong payload")
        }
        let left = 32 * R07FunctionalSupportGeometry.fullWidth + 31
        let right = left + 1

        XCTAssertEqual(outputCb[left], 10_000)
        XCTAssertEqual(outputCb[right], 50_000)
        XCTAssertEqual(outputCr[left], 15_000)
        XCTAssertEqual(outputCr[right], 45_000)
    }

    func testA15GoldenWeightedUpsampleAndLumaEdgeGate() throws {
        let center = 32 * R07FunctionalSupportGeometry.fullWidth + 32
        var lowMask = R07FunctionalTestFixtures.lowConstant(0)
        lowMask[16 * R07FunctionalSupportGeometry.lowWidth + 16] = R06ASHQ15.maximum
        let identity = R07FunctionalTestFixtures.identity(.coreImageEdgePreserve)
        let smoothed = try executor.execute(
            .a15(
                identity: identity,
                lowResolutionMaskQ15: lowMask,
                sameFrameLumaQ16: R07FunctionalTestFixtures.constant(0)
            )
        )
        guard case .upsampledProtectionMaskQ15(let smoothedMask) = smoothed.payload else {
            return XCTFail("A15 returned the wrong payload")
        }
        XCTAssertEqual(smoothedMask[center], 5_071)

        var edgeLuma = R07FunctionalTestFixtures.constant(0)
        for row in 32...33 {
            for column in 32...33 {
                edgeLuma[row * R07FunctionalSupportGeometry.fullWidth + column] = 65_536
            }
        }
        let edgePreserved = try executor.execute(
            .a15(
                identity: identity,
                lowResolutionMaskQ15: lowMask,
                sameFrameLumaQ16: edgeLuma
            )
        )
        guard case .upsampledProtectionMaskQ15(let preservedMask) =
            edgePreserved.payload else {
            return XCTFail("A15 returned the wrong edge-preserved payload")
        }
        XCTAssertEqual(preservedMask[center], R06ASHQ15.maximum)
    }

    func testEverySimulationAndNativeIdentityMutationFailsClosed() {
        let capabilities: [R07SupportCapabilityID] = [
            .temporalNoiseFilter,
            .mpsGuidedFilter,
            .coreImageEdgePreserve
        ]
        for capability in capabilities {
            let valid = R07FunctionalTestFixtures.identity(capability)
            let simulationMutation = R07FunctionalSupportIdentity(
                simulationIdentity: valid.simulationIdentity + ".forged",
                referencedNativeIdentity: valid.referencedNativeIdentity
            )
            assertIdentityRejected(simulationMutation, capability: capability)
            let nativeMutation = R07FunctionalSupportIdentity(
                simulationIdentity: valid.simulationIdentity,
                referencedNativeIdentity: wrongNativeIdentity(capability)
            )
            assertIdentityRejected(nativeMutation, capability: capability)
        }
    }

    func testA13IncludesLumaDeltaTwoAndExcludesDeltaThree() throws {
        let center = 32 * R07FunctionalSupportGeometry.fullWidth + 32
        let neighbor = center + 1
        var source = R07FunctionalTestFixtures.constant(0)
        source[neighbor] = 25_000

        let included = try a13Output(source: source, neighborLumaQ16: 515)
        let excluded = try a13Output(source: source, neighborLumaQ16: 772)

        XCTAssertEqual(included[center], 1_000)
        XCTAssertEqual(excluded[center], 0)
    }

    func testA15IncludesLumaDeltaThirtyEightAndExcludesThirtyNine() throws {
        let center = 32 * R07FunctionalSupportGeometry.fullWidth + 32
        var lowMask = R07FunctionalTestFixtures.lowConstant(0)
        lowMask[16 * R07FunctionalSupportGeometry.lowWidth + 16] = R06ASHQ15.maximum

        let included = try a15Output(lowMask: lowMask, neighborLumaQ16: 9_767)
        let excluded = try a15Output(lowMask: lowMask, neighborLumaQ16: 10_024)

        XCTAssertEqual(included[center], 5_071)
        XCTAssertEqual(excluded[center], 1_747)
    }

    func testInvalidStrengthCountsDomainsAndOcclusionFailClosed() throws {
        let a04Identity = R07FunctionalTestFixtures.identity(.temporalNoiseFilter)
        XCTAssertThrowsError(
            try executor.execute(
                .a04(
                    identity: a04Identity,
                    currentLumaQ16: R07FunctionalTestFixtures.constant(10_000),
                    strengthQ16: R06ASHQ16(1),
                    temporalState: .currentOnlyInvalidMotion
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? R07FunctionalSupportExecutionError,
                .sampleOutOfRange(role: "a04.strength_q16", index: 0, value: 1)
            )
        }
        XCTAssertThrowsError(
            try executor.execute(
                .a04(
                    identity: a04Identity,
                    currentLumaQ16: [],
                    strengthQ16: R07SupportStagePolicy.a04StrengthQ16,
                    temporalState: .currentOnlyInvalidMotion
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? R07FunctionalSupportExecutionError,
                .sampleCountMismatch(
                    role: "a04.current_luma_q16",
                    expected: R07FunctionalSupportGeometry.fullSampleCount,
                    actual: 0
                )
            )
        }
        var invalidOcclusion = R07FunctionalTestFixtures.constant(0)
        invalidOcclusion[0] = 2
        XCTAssertThrowsError(
            try executor.execute(
                .a04(
                    identity: a04Identity,
                    currentLumaQ16: R07FunctionalTestFixtures.constant(10_000),
                    strengthQ16: R07SupportStagePolicy.a04StrengthQ16,
                    temporalState: .continuous(
                        alignedHistoryLumaQ16:
                            R07FunctionalTestFixtures.constant(10_000),
                        occlusionMask: invalidOcclusion
                    )
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? R07FunctionalSupportExecutionError,
                .sampleOutOfRange(role: "a04.occlusion_mask", index: 0, value: 2)
            )
        }
        try assertA13DomainRejected()
        try assertA15CountRejected()
    }
}

private extension R07FunctionalSupportExecutorTests {
    func a13Output(
        source: [Int64],
        neighborLumaQ16: Int64
    ) throws -> [Int64] {
        let center = 32 * R07FunctionalSupportGeometry.fullWidth + 32
        var luma = R07FunctionalTestFixtures.constant(0)
        luma[center + 1] = neighborLumaQ16
        let execution = try executor.execute(
            .a13(
                identity: R07FunctionalTestFixtures.identity(.mpsGuidedFilter),
                sourceChromaCbQ16: source,
                sourceChromaCrQ16: source,
                sameFrameLumaQ16: luma,
                protectionMaskQ15: R07FunctionalTestFixtures.constant(0)
            )
        )
        guard case .reconstructedChromaQ16(let cb, _) = execution.payload else {
            throw R07FunctionalTestError.unexpectedCoordinatorOutcome
        }
        return cb
    }

    func a15Output(
        lowMask: [Int64],
        neighborLumaQ16: Int64
    ) throws -> [Int64] {
        var luma = R07FunctionalTestFixtures.constant(0)
        for row in 32...33 {
            for column in 32...33 where row != 32 || column != 32 {
                luma[row * R07FunctionalSupportGeometry.fullWidth + column] =
                    neighborLumaQ16
            }
        }
        let execution = try executor.execute(
            .a15(
                identity: R07FunctionalTestFixtures.identity(.coreImageEdgePreserve),
                lowResolutionMaskQ15: lowMask,
                sameFrameLumaQ16: luma
            )
        )
        guard case .upsampledProtectionMaskQ15(let mask) = execution.payload else {
            throw R07FunctionalTestError.unexpectedCoordinatorOutcome
        }
        return mask
    }

    func assertA13DomainRejected() throws {
        var invalidSource = R07FunctionalTestFixtures.constant(0)
        invalidSource[0] = R06ASHQ16.scale + 1
        XCTAssertThrowsError(
            try executor.execute(
                .a13(
                    identity: R07FunctionalTestFixtures.identity(.mpsGuidedFilter),
                    sourceChromaCbQ16: invalidSource,
                    sourceChromaCrQ16: R07FunctionalTestFixtures.constant(0),
                    sameFrameLumaQ16: R07FunctionalTestFixtures.constant(0),
                    protectionMaskQ15: R07FunctionalTestFixtures.constant(0)
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? R07FunctionalSupportExecutionError,
                .sampleOutOfRange(
                    role: "a13.source_chroma_q16",
                    index: 0,
                    value: R06ASHQ16.scale + 1
                )
            )
        }
    }

    func assertA15CountRejected() throws {
        XCTAssertThrowsError(
            try executor.execute(
                .a15(
                    identity: R07FunctionalTestFixtures.identity(
                        .coreImageEdgePreserve
                    ),
                    lowResolutionMaskQ15: [],
                    sameFrameLumaQ16: R07FunctionalTestFixtures.constant(0)
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? R07FunctionalSupportExecutionError,
                .sampleCountMismatch(
                    role: "a15.low_resolution_mask_q15",
                    expected: R07FunctionalSupportGeometry.lowSampleCount,
                    actual: 0
                )
            )
        }
    }

    func assertIdentityRejected(
        _ identity: R07FunctionalSupportIdentity,
        capability: R07SupportCapabilityID
    ) {
        XCTAssertThrowsError(
            try executor.execute(
                R07FunctionalTestFixtures.request(capability, identity: identity)
            )
        ) { error in
            XCTAssertEqual(
                error as? R07FunctionalSupportExecutionError,
                .simulationIdentityMismatch(capability)
            )
        }
    }

    func wrongNativeIdentity(
        _ capability: R07SupportCapabilityID
    ) -> R07FunctionalReferencedNativeIdentity {
        switch capability {
        case .temporalNoiseFilter:
            .a04Configuration("forged.configuration")
        case .mpsGuidedFilter:
            .inheritedProcessing(R07SupportStagePolicy.a15Descriptor.processingIdentity)
        case .coreImageEdgePreserve:
            .inheritedProcessing(R07SupportStagePolicy.a13Descriptor.processingIdentity)
        case .temporalAnalyzer:
            preconditionFailure("A05 has no functional execution identity")
        }
    }
}
