import CoreMedia
import CoreVideo
import XCTest
@testable import Mirmir

final class EnhancementPipelineContractsTests: XCTestCase {
    func testFiveStageProtocolsInvokeDistinctTypedOperations() async throws {
        let route = try makeRoute(backendID: "r02.fixture.copy-a")
        let frame = try makeFrame()
        let processedFrame = try makeProcessedFrame(frame: frame, route: route)
        let preprocessing: any AppleUpscalePreprocessingStage = try PipelinePreprocessingStage(
            stageID: "pre"
        )
        let primary: any AppleUpscalePrimaryScalingStage = try PipelinePrimaryStage(
            stageID: "primary",
            routeIdentity: route
        )
        let postprocessing: any AppleUpscalePostprocessingStage = try PipelinePostprocessingStage(
            stageID: "post"
        )
        let temporal: any AppleUpscaleTemporalStage = try PipelineTemporalStage(
            stageID: "temporal"
        )
        let analysis: any AppleUpscaleAnalysisStage = try PipelineAnalysisStage(
            stageID: "analysis"
        )

        guard case .processed = await preprocessing.preprocess(frame) else {
            return XCTFail("preprocessing did not return its typed processed outcome")
        }
        guard case .unavailable(let unavailable) = await primary.scale(frame) else {
            return XCTFail("primary scaling did not return its typed unavailable outcome")
        }
        XCTAssertEqual(unavailable.processingIdentity.route, route)
        guard case .processed = await postprocessing.postprocess(processedFrame) else {
            return XCTFail("postprocessing did not return its typed processed outcome")
        }
        guard case .processed = await temporal.processTemporal(processedFrame) else {
            return XCTFail("temporal processing did not return its typed processed outcome")
        }
        guard case .processed = await analysis.analyze(frame) else {
            return XCTFail("analysis did not return its typed processed outcome")
        }
    }

    func testPlannerRejectsMissingAndMultiplePrimaryStages() throws {
        let analysis = try PipelineAnalysisStage(stageID: "analysis")
        let firstPrimary = try PipelinePrimaryStage(
            stageID: "primary-a",
            routeIdentity: makeRoute(backendID: "r02.fixture.copy-a")
        )
        let secondPrimary = try PipelinePrimaryStage(
            stageID: "primary-b",
            routeIdentity: makeRoute(backendID: "r02.fixture.copy-b")
        )
        let planner = EnhancementPipelinePlanner()

        XCTAssertThrowsError(
            try planner.makePlan(
                orderedStages: [.analysis(analysis)],
                orderedFallbackPrimaryStages: []
            )
        ) { error in
            XCTAssertEqual(
                error as? EnhancementPipelinePlanningError,
                .missingPrimaryStage
            )
        }
        XCTAssertThrowsError(
            try planner.makePlan(
                orderedStages: [
                    .primaryScaling(firstPrimary),
                    .primaryScaling(secondPrimary)
                ],
                orderedFallbackPrimaryStages: []
            )
        ) { error in
            XCTAssertEqual(
                error as? EnhancementPipelinePlanningError,
                .multiplePrimaryStages(2)
            )
        }
    }

    func testPlannerPreservesSuppliedNonalphabeticOrderAndExactlyOnePrimary() throws {
        let analysis = try PipelineAnalysisStage(stageID: "z-analysis")
        let preprocessing = try PipelinePreprocessingStage(stageID: "y-pre")
        let primary = try PipelinePrimaryStage(
            stageID: "x-primary",
            routeIdentity: makeRoute(backendID: "r02.fixture.copy-a")
        )
        let temporal = try PipelineTemporalStage(stageID: "w-temporal")
        let postprocessing = try PipelinePostprocessingStage(stageID: "v-post")
        let suppliedStages: [EnhancementPipelineStage] = [
            .analysis(analysis),
            .preprocessing(preprocessing),
            .primaryScaling(primary),
            .temporal(temporal),
            .postprocessing(postprocessing)
        ]
        let planner = EnhancementPipelinePlanner()

        let firstPlan = try planner.makePlan(
            orderedStages: suppliedStages,
            orderedFallbackPrimaryStages: []
        )
        let secondPlan = try planner.makePlan(
            orderedStages: suppliedStages,
            orderedFallbackPrimaryStages: []
        )

        let expectedIDs = [
            "z-analysis",
            "y-pre",
            "x-primary",
            "w-temporal",
            "v-post"
        ]
        XCTAssertEqual(
            firstPlan.orderedStageBindings.map(\.stageID.rawValue),
            expectedIDs
        )
        XCTAssertEqual(
            secondPlan.orderedStageBindings.map(\.stageID.rawValue),
            expectedIDs
        )
        XCTAssertEqual(
            firstPlan.orderedStageBindings.map(\.role),
            [.analysis, .preprocessing, .primaryScaling, .temporal, .postprocessing]
        )
        XCTAssertEqual(firstPlan.primaryBinding.stageID.rawValue, "x-primary")
        XCTAssertTrue(firstPlan.orderedFallbackPrimaryBindings.isEmpty)
    }

    func testPlanSnapshotsIdentityBeforeMutableStageConformersChange() throws {
        let originalPrimaryRoute = try makeRoute(backendID: "r02.fixture.copy-a")
        let originalFallbackRoute = try makeRoute(backendID: "r02.fixture.copy-b")
        let changedPrimaryRoute = try makeRoute(backendID: "r02.fixture.copy-c")
        let changedFallbackRoute = try makeRoute(backendID: "r02.fixture.copy-d")
        let primary = try MutablePipelinePrimaryStage(
            stageID: "primary-original",
            routeIdentity: originalPrimaryRoute
        )
        let fallback = try MutablePipelinePrimaryStage(
            stageID: "fallback-original",
            routeIdentity: originalFallbackRoute
        )
        let plan = try EnhancementPipelinePlanner().makePlan(
            orderedStages: [.primaryScaling(primary)],
            orderedFallbackPrimaryStages: [fallback]
        )
        XCTAssertEqual(primary.snapshotReadCount, 1)
        XCTAssertEqual(fallback.snapshotReadCount, 1)

        try primary.replaceIdentity(
            stageID: "primary-changed",
            routeIdentity: changedPrimaryRoute
        )
        try fallback.replaceIdentity(
            stageID: "fallback-changed",
            routeIdentity: changedFallbackRoute
        )

        XCTAssertEqual(plan.primaryBinding.stageID.rawValue, "primary-original")
        XCTAssertEqual(plan.primaryBinding.routeIdentity, originalPrimaryRoute)
        XCTAssertEqual(
            plan.orderedFallbackPrimaryBindings.map(\.stageID.rawValue),
            ["fallback-original"]
        )
        XCTAssertEqual(
            plan.orderedFallbackPrimaryBindings.map(\.routeIdentity),
            [originalFallbackRoute]
        )
        let link = try plan.fallbackLink(
            after: originalPrimaryRoute,
            reasonCode: .backendUnavailable,
            selectedFallbackOrdinal: 0
        )
        XCTAssertEqual(link.failedRoute, originalPrimaryRoute)
        XCTAssertEqual(link.selectedRoute, originalFallbackRoute)
        XCTAssertEqual(primary.snapshotReadCount, 1)
        XCTAssertEqual(fallback.snapshotReadCount, 1)
    }

    func testPlannerRejectsDuplicateStageIDsAcrossPrimaryAndFallbackRoles() throws {
        let primary = try PipelinePrimaryStage(
            stageID: "duplicate",
            routeIdentity: makeRoute(backendID: "r02.fixture.copy-a")
        )
        let analysis = try PipelineAnalysisStage(stageID: "duplicate")
        let fallback = try PipelinePrimaryStage(
            stageID: "duplicate",
            routeIdentity: makeRoute(backendID: "r02.fixture.copy-b")
        )
        let planner = EnhancementPipelinePlanner()

        XCTAssertThrowsError(
            try planner.makePlan(
                orderedStages: [
                    .primaryScaling(primary),
                    .analysis(analysis)
                ],
                orderedFallbackPrimaryStages: []
            )
        ) { error in
            XCTAssertEqual(
                error as? EnhancementPipelinePlanningError,
                .duplicateStageID("duplicate")
            )
        }
        XCTAssertThrowsError(
            try planner.makePlan(
                orderedStages: [.primaryScaling(primary)],
                orderedFallbackPrimaryStages: [fallback]
            )
        ) { error in
            XCTAssertEqual(
                error as? EnhancementPipelinePlanningError,
                .duplicateStageID("duplicate")
            )
        }
    }

    func testPlannerRejectsPrimaryAndDuplicateFallbackRoutes() throws {
        let primaryRoute = try makeRoute(backendID: "r02.fixture.copy-a")
        let fallbackRoute = try makeRoute(backendID: "r02.fixture.copy-b")
        let primary = try PipelinePrimaryStage(
            stageID: "primary",
            routeIdentity: primaryRoute
        )
        let repeatedPrimary = try PipelinePrimaryStage(
            stageID: "fallback-primary-route",
            routeIdentity: primaryRoute
        )
        let firstFallback = try PipelinePrimaryStage(
            stageID: "fallback-a",
            routeIdentity: fallbackRoute
        )
        let secondFallback = try PipelinePrimaryStage(
            stageID: "fallback-b",
            routeIdentity: fallbackRoute
        )
        let planner = EnhancementPipelinePlanner()

        XCTAssertThrowsError(
            try planner.makePlan(
                orderedStages: [.primaryScaling(primary)],
                orderedFallbackPrimaryStages: [repeatedPrimary]
            )
        ) { error in
            XCTAssertEqual(
                error as? EnhancementPipelinePlanningError,
                .primaryRouteRepeatedAsFallback("r02.fixture.copy-a")
            )
        }
        XCTAssertThrowsError(
            try planner.makePlan(
                orderedStages: [.primaryScaling(primary)],
                orderedFallbackPrimaryStages: [firstFallback, secondFallback]
            )
        ) { error in
            XCTAssertEqual(
                error as? EnhancementPipelinePlanningError,
                .duplicateFallbackRoute("r02.fixture.copy-b")
            )
        }
    }

    func testPlanCreatesOnlyContiguousVisibleFallbackLinks() throws {
        let primaryRoute = try makeRoute(backendID: "r02.fixture.copy-a")
        let firstFallbackRoute = try makeRoute(backendID: "r02.fixture.copy-b")
        let secondFallbackRoute = try makeRoute(backendID: "r02.fixture.copy-c")
        let primary = try PipelinePrimaryStage(
            stageID: "primary",
            routeIdentity: primaryRoute
        )
        let firstFallback = try PipelinePrimaryStage(
            stageID: "fallback-0",
            routeIdentity: firstFallbackRoute
        )
        let secondFallback = try PipelinePrimaryStage(
            stageID: "fallback-1",
            routeIdentity: secondFallbackRoute
        )
        let plan = try EnhancementPipelinePlanner().makePlan(
            orderedStages: [.primaryScaling(primary)],
            orderedFallbackPrimaryStages: [firstFallback, secondFallback]
        )

        let firstLink = try plan.fallbackLink(
            after: primaryRoute,
            reasonCode: .backendUnavailable,
            selectedFallbackOrdinal: 0
        )
        let secondLink = try plan.fallbackLink(
            after: firstFallbackRoute,
            reasonCode: .backendFailed,
            selectedFallbackOrdinal: 1
        )

        XCTAssertEqual(firstLink.failedRoute, primaryRoute)
        XCTAssertEqual(firstLink.selectedRoute, firstFallbackRoute)
        XCTAssertEqual(firstLink.selectedFallbackOrdinal, 0)
        XCTAssertEqual(secondLink.failedRoute, firstFallbackRoute)
        XCTAssertEqual(secondLink.selectedRoute, secondFallbackRoute)
        XCTAssertEqual(secondLink.selectedFallbackOrdinal, 1)
        XCTAssertNoThrow(
            try AppleUpscaleProcessingIdentity(
                route: secondFallbackRoute,
                fallbackHistory: [firstLink, secondLink]
            )
        )

        XCTAssertThrowsError(
            try plan.fallbackLink(
                after: primaryRoute,
                reasonCode: .backendFailed,
                selectedFallbackOrdinal: 1
            )
        ) { error in
            XCTAssertEqual(
                error as? EnhancementPipelinePlanningError,
                .fallbackChainDiscontinuity(
                    expectedBackendID: "r02.fixture.copy-b",
                    actualBackendID: "r02.fixture.copy-a"
                )
            )
        }
        XCTAssertThrowsError(
            try plan.fallbackLink(
                after: secondFallbackRoute,
                reasonCode: .backendFailed,
                selectedFallbackOrdinal: 2
            )
        ) { error in
            XCTAssertEqual(
                error as? EnhancementPipelinePlanningError,
                .fallbackOrdinalOutOfRange(2)
            )
        }
    }

    private func makeFrame() throws -> AppleUpscaleFrame {
        try AppleUpscaleFrame(
            sequenceNumber: 0,
            pixelBuffer: makePixelBuffer(),
            presentationTimestamp: .zero,
            duration: CMTime(value: 1, timescale: 30),
            colorDescription: makeColorDescription(),
            metadataIdentity: AppleUpscaleMetadataIdentity("fixture.frame-0"),
            resourceLifetimeToken: AppleUpscaleResourceLifetimeToken(
                identity: "fixture.token-0",
                releaseAction: {}
            )
        )
    }

    private func makeProcessedFrame(
        frame: AppleUpscaleFrame,
        route: AppleUpscaleRouteIdentity
    ) throws -> AppleUpscaleProcessedFrame {
        try AppleUpscaleProcessedFrame(
            sequenceNumber: frame.sequenceNumber,
            pixelBuffer: frame.pixelBuffer,
            presentationTimestamp: frame.presentationTimestamp,
            duration: frame.duration,
            colorDescription: frame.colorDescription,
            metadataIdentity: frame.metadataIdentity,
            resourceLifetimeToken: frame.resourceLifetimeToken,
            processingIdentity: AppleUpscaleProcessingIdentity(
                route: route,
                fallbackHistory: []
            )
        )
    }

    private func makeRoute(backendID: String) throws -> AppleUpscaleRouteIdentity {
        try AppleUpscaleRouteIdentity(
            backend: AppleUpscaleBackendIdentity(
                backendID: backendID,
                backendRevision: "1",
                modelAssetsIdentity: .notRequired
            ),
            configurationIdentity: "r02-fixture-copy-v1",
            policyIdentity: "r02-fixture-only-v1",
            materialDecisionIdentity: "r02-fixture-copy-decision-v1"
        )
    }

    private func makeColorDescription() throws -> AppleUpscaleColorDescription {
        try AppleUpscaleColorDescription(
            colorPrimaries: "ITU_R_709_2",
            transferFunction: "ITU_R_709_2",
            matrix: "ITU_R_709_2",
            chromaSiting: "left",
            range: .video
        )
    }

    private func makePixelBuffer() throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            16,
            8,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            nil,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return pixelBuffer
    }
}

private final class PipelinePreprocessingStage: AppleUpscalePreprocessingStage,
    @unchecked Sendable {
    let stageID: AppleUpscaleStageID

    init(stageID: String) throws {
        self.stageID = try AppleUpscaleStageID(stageID)
    }

    func preprocess(
        _ frame: AppleUpscaleFrame
    ) async -> AppleUpscaleBackendOutcome<AppleUpscaleFrame> {
        .processed(frame)
    }
}

private final class PipelinePrimaryStage: AppleUpscalePrimaryScalingStage,
    @unchecked Sendable {
    let planningBinding: EnhancementPipelinePrimaryBinding

    private let unavailable: AppleUpscaleBackendUnavailable

    init(stageID: String, routeIdentity: AppleUpscaleRouteIdentity) throws {
        self.planningBinding = EnhancementPipelinePrimaryBinding(
            stageID: try AppleUpscaleStageID(stageID),
            routeIdentity: routeIdentity
        )
        self.unavailable = try AppleUpscaleBackendUnavailable(
            processingIdentity: AppleUpscaleProcessingIdentity(
                route: routeIdentity,
                fallbackHistory: []
            ),
            reason: "fixture unavailable"
        )
    }

    func scale(
        _: AppleUpscaleFrame
    ) async -> AppleUpscaleBackendOutcome<AppleUpscaleProcessedFrame> {
        .unavailable(unavailable)
    }
}

private final class MutablePipelinePrimaryStage: AppleUpscalePrimaryScalingStage,
    @unchecked Sendable {
    private let lock = NSLock()
    private var storedStageID: AppleUpscaleStageID
    private var storedRouteIdentity: AppleUpscaleRouteIdentity
    private var storedSnapshotReadCount = 0
    private let unavailable: AppleUpscaleBackendUnavailable

    var planningBinding: EnhancementPipelinePrimaryBinding {
        lock.lock()
        defer { lock.unlock() }
        storedSnapshotReadCount += 1
        return EnhancementPipelinePrimaryBinding(
            stageID: storedStageID,
            routeIdentity: storedRouteIdentity
        )
    }

    var snapshotReadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedSnapshotReadCount
    }

    init(stageID: String, routeIdentity: AppleUpscaleRouteIdentity) throws {
        self.storedStageID = try AppleUpscaleStageID(stageID)
        self.storedRouteIdentity = routeIdentity
        self.unavailable = try AppleUpscaleBackendUnavailable(
            processingIdentity: AppleUpscaleProcessingIdentity(
                route: routeIdentity,
                fallbackHistory: []
            ),
            reason: "fixture unavailable"
        )
    }

    func replaceIdentity(
        stageID: String,
        routeIdentity: AppleUpscaleRouteIdentity
    ) throws {
        let stageID = try AppleUpscaleStageID(stageID)
        lock.lock()
        storedStageID = stageID
        storedRouteIdentity = routeIdentity
        lock.unlock()
    }

    func scale(
        _: AppleUpscaleFrame
    ) async -> AppleUpscaleBackendOutcome<AppleUpscaleProcessedFrame> {
        .unavailable(unavailable)
    }
}

private final class PipelinePostprocessingStage: AppleUpscalePostprocessingStage,
    @unchecked Sendable {
    let stageID: AppleUpscaleStageID

    init(stageID: String) throws {
        self.stageID = try AppleUpscaleStageID(stageID)
    }

    func postprocess(
        _ frame: AppleUpscaleProcessedFrame
    ) async -> AppleUpscaleBackendOutcome<AppleUpscaleProcessedFrame> {
        .processed(frame)
    }
}

private final class PipelineTemporalStage: AppleUpscaleTemporalStage,
    @unchecked Sendable {
    let stageID: AppleUpscaleStageID

    init(stageID: String) throws {
        self.stageID = try AppleUpscaleStageID(stageID)
    }

    func processTemporal(
        _ frame: AppleUpscaleProcessedFrame
    ) async -> AppleUpscaleBackendOutcome<AppleUpscaleProcessedFrame> {
        .processed(frame)
    }
}

private final class PipelineAnalysisStage: AppleUpscaleAnalysisStage,
    @unchecked Sendable {
    let stageID: AppleUpscaleStageID

    init(stageID: String) throws {
        self.stageID = try AppleUpscaleStageID(stageID)
    }

    func analyze(
        _ frame: AppleUpscaleFrame
    ) async -> AppleUpscaleBackendOutcome<AppleUpscaleFrame> {
        .processed(frame)
    }
}
