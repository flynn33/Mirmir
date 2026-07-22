import XCTest
@testable import Mirmir

final class R07FunctionalCoordinatorBoundaryTests: XCTestCase {
    func testMeasuredSceneCutSuppressesMotionAndOcclusionAndResetsState() throws {
        let current = R07FunctionalTestFixtures.constant(60_000)
        let previous = R07FunctionalTestFixtures.constant(0)
        var occlusion = R07FunctionalTestFixtures.constant(0)
        for index in 0..<1_024 {
            occlusion[index] = 1
        }
        var contextOptions = R07FunctionalContextOptions()
        contextOptions.fatalBackendID = R07FunctionalTestFixtures.currentBackendID
        var options = R07FunctionalInputOptions()
        options.currentLumaQ16 = current
        options.previousLumaQ16 = previous
        options.alignedPreviousLumaQ16 = current
        options.occlusionMask = occlusion
        options.nextBaseContext = try R07FunctionalTestFixtures.makeContext(
            contextOptions
        )
        options.artifactAnalysis = R07FunctionalTestFixtures.artifactInput(
            current: current,
            previous: previous
        )
        var coordinator = R07FunctionalCoordinator(
            supportExecutor: R07DeterministicFixtureSupportExecutor(),
            history: R07FunctionalTestFixtures.history()
        )

        let result = try R07FunctionalTestFixtures.result(
            coordinator.process(R07FunctionalTestFixtures.input(options))
        )

        XCTAssertEqual(result.boundaryReason, .sceneCut)
        XCTAssertEqual(result.temporalDisposition, .analyzed)
        XCTAssertEqual(result.temporalAnalysis?.sceneCutRawQ16.rawValue, 60_000)
        XCTAssertEqual(result.temporalAnalysis?.motionConfidenceQ16, .one)
        XCTAssertEqual(result.temporalAnalysis?.occlusionQ16.rawValue, 16_384)
        XCTAssertEqual(result.nextDecisionContext.sceneCutConfidenceQ16.rawValue, 60_000)
        XCTAssertEqual(result.nextDecisionContext.motionConfidenceQ16, .zero)
        XCTAssertEqual(result.nextDecisionContext.occlusionConfidenceQ16, .zero)
        XCTAssertEqual(result.denoisedLumaQ16, current)
        XCTAssertTrue(result.notApplicableArtifactKinds.contains(.ghosting))
        XCTAssertTrue(result.notApplicableArtifactKinds.contains(.flicker))
        XCTAssertNil(result.nextDecisionContext.currentBackendID)
        XCTAssertNil(result.nextDecisionContext.previousBackendID)
        XCTAssertNil(result.nextDecisionContext.fallbackReason)
        XCTAssertEqual(result.nextDecisionContext.dwellFrames, 0)
        XCTAssertEqual(result.nextDecisionRecord.reason, .sceneCutReset)
        XCTAssertEqual(result.history.generation, 1)
        XCTAssertEqual(result.history.entries.map(\.frameOrdinal), [101])
    }

    func testExplicitDiscontinuityBypassesAnalyzerAndAllOccludedHistory() throws {
        let current = R07FunctionalTestFixtures.constant(40_000)
        var contextOptions = R07FunctionalContextOptions()
        contextOptions.fatalBackendID = R07FunctionalTestFixtures.currentBackendID
        let executor = R07RecordingSupportExecutor()
        var options = R07FunctionalInputOptions()
        options.currentLumaQ16 = current
        options.previousLumaQ16 = R07FunctionalTestFixtures.constant(0)
        options.alignedPreviousLumaQ16 = R07FunctionalTestFixtures.constant(0)
        options.occlusionMask = R07FunctionalTestFixtures.constant(1)
        options.discontinuity = true
        options.nextBaseContext = try R07FunctionalTestFixtures.makeContext(
            contextOptions
        )
        options.artifactAnalysis = R07FunctionalTestFixtures.artifactInput(
            current: current,
            previous: R07FunctionalTestFixtures.constant(0)
        )
        var coordinator = R07FunctionalCoordinator(
            supportExecutor: executor,
            history: R07FunctionalTestFixtures.history()
        )

        let result = try R07FunctionalTestFixtures.result(
            coordinator.process(R07FunctionalTestFixtures.input(options))
        )

        XCTAssertNil(result.temporalAnalysis)
        XCTAssertEqual(result.temporalDisposition, .notApplicableDiscontinuity)
        XCTAssertEqual(result.boundaryReason, .discontinuity)
        XCTAssertEqual(result.denoisedLumaQ16, current)
        XCTAssertEqual(result.nextDecisionContext.sceneCutConfidenceQ16, .zero)
        XCTAssertEqual(result.nextDecisionContext.motionConfidenceQ16, .zero)
        XCTAssertEqual(result.nextDecisionContext.occlusionConfidenceQ16, .zero)
        XCTAssertNil(result.nextDecisionContext.currentBackendID)
        XCTAssertNil(result.nextDecisionContext.previousBackendID)
        XCTAssertNil(result.nextDecisionContext.fallbackReason)
        XCTAssertEqual(result.nextDecisionContext.dwellFrames, 0)
        XCTAssertEqual(result.nextDecisionRecord.reason, .initialSelection)
        XCTAssertTrue(result.notApplicableArtifactKinds.contains(.ghosting))
        XCTAssertTrue(result.notApplicableArtifactKinds.contains(.flicker))
        XCTAssertEqual(result.history.generation, 1)
        guard case .a04(_, _, _, let state) = executor.requests.first else {
            return XCTFail("A04 was not the first support execution")
        }
        XCTAssertEqual(state, .discontinuity)
    }

    func testInvalidMotionUsesCurrentOnlyWithoutResettingHistory() throws {
        let current = R07FunctionalTestFixtures.constant(30_000)
        let executor = R07RecordingSupportExecutor()
        var options = R07FunctionalInputOptions()
        options.currentLumaQ16 = current
        options.previousLumaQ16 = current
        options.alignedPreviousLumaQ16 = R07FunctionalTestFixtures.constant(0)
        options.artifactAnalysis = R07FunctionalTestFixtures.artifactInput(
            current: current,
            previous: current
        )
        var coordinator = R07FunctionalCoordinator(supportExecutor: executor)

        let result = try R07FunctionalTestFixtures.result(
            coordinator.process(R07FunctionalTestFixtures.input(options))
        )

        XCTAssertEqual(result.temporalAnalysis?.motionValid, false)
        XCTAssertNil(result.boundaryReason)
        XCTAssertEqual(result.denoisedLumaQ16, current)
        XCTAssertTrue(result.notApplicableArtifactKinds.contains(.ghosting))
        XCTAssertFalse(result.notApplicableArtifactKinds.contains(.flicker))
        XCTAssertEqual(result.history.generation, 0)
        XCTAssertEqual(
            result.nextDecisionContext.currentBackendID,
            R07FunctionalTestFixtures.currentBackendID
        )
        guard case .a04(_, _, _, let state) = executor.requests.first else {
            return XCTFail("A04 was not the first support execution")
        }
        XCTAssertEqual(state, .currentOnlyInvalidMotion)
    }

    func testAllFalseHaloSupportIsNotApplicableInsteadOfFailure() throws {
        let flat = R07FunctionalTestFixtures.constant(30_000)
        var options = R07FunctionalInputOptions()
        options.currentLumaQ16 = flat
        options.previousLumaQ16 = flat
        options.alignedPreviousLumaQ16 = flat
        options.sourceChromaCbQ16 = flat
        options.sourceChromaCrQ16 = flat
        options.artifactAnalysis = R07FunctionalTestFixtures.artifactInput(
            current: flat,
            previous: flat,
            haloSupport: false
        )
        var coordinator = R07FunctionalCoordinator(
            supportExecutor: R07DeterministicFixtureSupportExecutor()
        )

        let result = try R07FunctionalTestFixtures.result(
            coordinator.process(R07FunctionalTestFixtures.input(options))
        )

        XCTAssertTrue(result.notApplicableArtifactKinds.contains(.halo))
        let halo = result.artifactAggregate.orderedMeasurements.first {
            $0.kind == .halo
        }
        XCTAssertEqual(halo?.rawValue, 0)
        XCTAssertEqual(halo?.contributingSampleCount, 0)
    }
}
