import XCTest
@testable import Mirmir

final class R06ASHMasksAndAblationsTests: XCTestCase {
    func testMaskIDsMatchFrozenDeclarationOrderExactly() {
        XCTAssertEqual(
            R06ASHMaskID.allCases.map(\.rawValue),
            [
                "luma_protection",
                "chroma_protection",
                "postprocess_suppression"
            ]
        )
    }

    func testMasksAcceptExactDimensionAndQ15SampleBoundaries() throws {
        let minimum = try R06ASHMask(
            id: .lumaProtection,
            width: 1,
            height: 1,
            samplesQ15: [0]
        )
        XCTAssertEqual(minimum.samplesQ15, [R06ASHMask.minimumSampleQ15])

        let maximumSampleCount = 64 * 64
        let maximum = try R06ASHMask(
            id: .postprocessSuppression,
            width: 64,
            height: 64,
            samplesQ15: Array(
                repeating: R06ASHMask.maximumSampleQ15,
                count: maximumSampleCount
            )
        )
        XCTAssertEqual(maximum.width, R06ASHMask.maximumDimension)
        XCTAssertEqual(maximum.height, R06ASHMask.maximumDimension)
        XCTAssertEqual(maximum.samplesQ15.count, maximumSampleCount)
        XCTAssertEqual(maximum.samplesQ15.first, 32_767)
        XCTAssertEqual(maximum.samplesQ15.last, 32_767)
    }

    func testMasksRejectEveryDimensionBoundaryOutsideOneThrough64() {
        for width in [Int.min, -1, 0, 65, Int.max] {
            XCTAssertThrowsError(
                try R06ASHMask(
                    id: .lumaProtection,
                    width: width,
                    height: 1,
                    samplesQ15: []
                )
            ) { error in
                XCTAssertEqual(
                    error as? R06ASHMaskError,
                    .invalidWidth(width)
                )
            }
        }

        for height in [Int.min, -1, 0, 65, Int.max] {
            XCTAssertThrowsError(
                try R06ASHMask(
                    id: .lumaProtection,
                    width: 1,
                    height: height,
                    samplesQ15: []
                )
            ) { error in
                XCTAssertEqual(
                    error as? R06ASHMaskError,
                    .invalidHeight(height)
                )
            }
        }
    }

    func testMaskSampleCountMultiplicationFailsClosedOnOverflow() {
        XCTAssertThrowsError(
            try R06ASHMask(
                id: .lumaProtection,
                width: Int.max,
                height: 2,
                samplesQ15: []
            )
        ) { error in
            XCTAssertEqual(
                error as? R06ASHMaskError,
                .sampleCountOverflow(width: Int.max, height: 2)
            )
        }
    }

    func testMasksRejectSampleCountMismatch() {
        for samples in [
            [UInt16](repeating: 0, count: 3),
            [UInt16](repeating: 0, count: 5)
        ] {
            XCTAssertThrowsError(
                try R06ASHMask(
                    id: .chromaProtection,
                    width: 2,
                    height: 2,
                    samplesQ15: samples
                )
            ) { error in
                XCTAssertEqual(
                    error as? R06ASHMaskError,
                    .sampleCountMismatch(expected: 4, actual: samples.count)
                )
            }
        }
    }

    func testMasksRejectOutOfRangeSamplesWithoutClamping() {
        for value in [UInt16(32_768), UInt16.max] {
            XCTAssertThrowsError(
                try R06ASHMask(
                    id: .postprocessSuppression,
                    width: 2,
                    height: 2,
                    samplesQ15: [0, 8_192, 32_767, value]
                )
            ) { error in
                XCTAssertEqual(
                    error as? R06ASHMaskError,
                    .sampleOutOfRange(index: 3, value: value)
                )
            }
        }
    }

    func testTypedMaskSetMatchesExactFrozenFixtures() throws {
        let fixtures = try makeFrozenMaskFixtures()
        let set = try R06ASHMaskSet(
            masks: [
                fixtures.postprocessSuppression,
                fixtures.lumaProtection,
                fixtures.chromaProtection
            ]
        )

        XCTAssertEqual(
            set.orderedMasks,
            [
                fixtures.lumaProtection,
                fixtures.chromaProtection,
                fixtures.postprocessSuppression
            ]
        )
        XCTAssertEqual(set[.lumaProtection].samplesQ15, [0, 8_192, 16_384, 32_767])
        XCTAssertEqual(set[.chromaProtection].samplesQ15, [32_767, 16_384, 8_192, 0])
        XCTAssertEqual(set[.postprocessSuppression].samplesQ15, [0, 32_767, 32_767, 0])
    }

    func testTypedMaskSetRejectsCountDuplicatesAndWrongSlotIdentity() throws {
        let fixtures = try makeFrozenMaskFixtures()

        XCTAssertThrowsError(
            try R06ASHMaskSet(
                masks: [fixtures.lumaProtection, fixtures.chromaProtection]
            )
        ) { error in
            XCTAssertEqual(
                error as? R06ASHMaskError,
                .maskCountMismatch(expected: 3, actual: 2)
            )
        }
        XCTAssertThrowsError(
            try R06ASHMaskSet(
                masks: [
                    fixtures.lumaProtection,
                    fixtures.chromaProtection,
                    fixtures.postprocessSuppression,
                    fixtures.lumaProtection
                ]
            )
        ) { error in
            XCTAssertEqual(
                error as? R06ASHMaskError,
                .maskCountMismatch(expected: 3, actual: 4)
            )
        }
        XCTAssertThrowsError(
            try R06ASHMaskSet(
                masks: [
                    fixtures.lumaProtection,
                    fixtures.lumaProtection,
                    fixtures.postprocessSuppression
                ]
            )
        ) { error in
            XCTAssertEqual(
                error as? R06ASHMaskError,
                .duplicateMaskID(.lumaProtection)
            )
        }
        XCTAssertThrowsError(
            try R06ASHMaskSet(
                lumaProtection: fixtures.chromaProtection,
                chromaProtection: fixtures.lumaProtection,
                postprocessSuppression: fixtures.postprocessSuppression
            )
        ) { error in
            XCTAssertEqual(
                error as? R06ASHMaskError,
                .maskIdentityMismatch(
                    expected: .lumaProtection,
                    actual: .chromaProtection
                )
            )
        }
    }

    func testMasksAndSetsHaveImmutableValueIdentity() throws {
        let firstFixtures = try makeFrozenMaskFixtures()
        let secondFixtures = try makeFrozenMaskFixtures()
        let first = try R06ASHMaskSet(
            lumaProtection: firstFixtures.lumaProtection,
            chromaProtection: firstFixtures.chromaProtection,
            postprocessSuppression: firstFixtures.postprocessSuppression
        )
        let second = try R06ASHMaskSet(
            lumaProtection: secondFixtures.lumaProtection,
            chromaProtection: secondFixtures.chromaProtection,
            postprocessSuppression: secondFixtures.postprocessSuppression
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(Set([first, second]).count, 1)
        requireSendable(first)
        requireHashable(first)
    }

    func testAblationModesMatchFrozenIDsAndOrderExactly() {
        XCTAssertEqual(
            R06ASHAblationMode.allCases.map(\.rawValue),
            [
                "best_fixed_eligible_apple_backend",
                "simple_continuous_router_without_ash",
                "ash_state_only_router",
                "ash_plus_continuous_sidecar",
                "ash_without_hysteresis",
                "ash_without_postflight_feedback"
            ]
        )
        XCTAssertEqual(Set(R06ASHAblationMode.allCases).count, 6)
    }

    func testAblationMetadataMatchesPreregistrationAndFixtureCatalogExactly() {
        let modes = R06ASHAblationMode.allCases

        XCTAssertEqual(
            modes.map(\.roadmapLabel),
            [
                "best fixed eligible Apple backend",
                "simple continuous router without ASH",
                "ASH state-only router",
                "ASH plus continuous sidecar",
                "ASH without hysteresis",
                "ASH without postflight feedback"
            ]
        )
        XCTAssertTrue(modes.allSatisfy { $0.productExecutionStatus == .notObserved })
        XCTAssertTrue(modes.allSatisfy { $0.preregistrationStatus == .preregistered })
        XCTAssertTrue(
            modes.allSatisfy { $0.fixtureContractStatus == .deterministicFixtureOnly }
        )
        XCTAssertEqual(
            modes.map(\.requiredContextFixtureIDs),
            [
                ["initial", "steady_state"],
                ["initial", "postflight_risk"],
                ["initial", "minimum_dwell"],
                [
                    "initial",
                    "minimum_dwell",
                    "scene_cut",
                    "fatal_failure",
                    "postflight_risk"
                ],
                ["steady_state", "minimum_dwell"],
                ["steady_state", "postflight_risk"]
            ]
        )
        for mode in modes {
            requireSendable(mode)
            requireHashable(mode)
        }
    }

    private func makeFrozenMaskFixtures() throws -> R06ASHMaskSet {
        try R06ASHMaskSet(
            lumaProtection: R06ASHMask(
                id: .lumaProtection,
                width: 2,
                height: 2,
                samplesQ15: [0, 8_192, 16_384, 32_767]
            ),
            chromaProtection: R06ASHMask(
                id: .chromaProtection,
                width: 2,
                height: 2,
                samplesQ15: [32_767, 16_384, 8_192, 0]
            ),
            postprocessSuppression: R06ASHMask(
                id: .postprocessSuppression,
                width: 2,
                height: 2,
                samplesQ15: [0, 32_767, 32_767, 0]
            )
        )
    }

    private func requireSendable<T: Sendable>(_: T) {}

    private func requireHashable<T: Hashable>(_: T) {}
}
