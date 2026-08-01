import CoreVideo
import XCTest
@testable import Mirmir

final class R04VideoToolboxContractsTests: XCTestCase {
    func testCatalogMatchesFrozenSevenRouteMatrixExactly() {
        let observed = R04VideoToolboxRouteCatalog.routes.map(ExpectedRoute.init)
        let expected: [ExpectedRoute] = [
            .init(
                subjectID: .quality2x,
                routeID: .quality2x,
                capabilityID: "A01",
                backendKind: .quality,
                source: .p1080,
                target: .p2160,
                scale: .two,
                gate: .runtimeSupportRequired,
                defaultEligibility: .candidateAfterObservedQualification
            ),
            .init(
                subjectID: .quality4x,
                routeID: .quality4x,
                capabilityID: "A01",
                backendKind: .quality,
                source: .p270,
                target: .p1080,
                scale: .four,
                gate: .runtimeSupportRequired,
                defaultEligibility: .candidateAfterObservedQualification
            ),
            .init(
                subjectID: .quality1p5xContract,
                routeID: .quality1p5xContract,
                capabilityID: "A01",
                backendKind: .quality,
                source: .p720,
                target: .p1080,
                scale: .oneAndOneHalf,
                gate: .publicContractUnrepresentable,
                defaultEligibility: .ineligibleContractRejection
            ),
            .init(
                subjectID: .lowLatency1p5x,
                routeID: .lowLatency1p5x,
                capabilityID: "A02",
                backendKind: .lowLatency,
                source: .p720,
                target: .p1080,
                scale: .oneAndOneHalf,
                gate: .exactDimensionQueryRequired,
                defaultEligibility: .candidateAfterObservedQualification
            ),
            .init(
                subjectID: .lowLatency2x,
                routeID: .lowLatency2x,
                capabilityID: "A02",
                backendKind: .lowLatency,
                source: .p1080,
                target: .p2160,
                scale: .two,
                gate: .exactDimensionQueryRequired,
                defaultEligibility: .candidateAfterObservedQualification
            ),
            .init(
                subjectID: .lowLatency4x,
                routeID: .lowLatency4x,
                capabilityID: "A02",
                backendKind: .lowLatency,
                source: .p270,
                target: .p1080,
                scale: .four,
                gate: .exactDimensionQueryRequired,
                defaultEligibility: .candidateAfterObservedQualification
            ),
            .init(
                subjectID: .opticalFlowSupport,
                routeID: .opticalFlow1080p,
                capabilityID: "A05",
                backendKind: .optionalFlowSupport,
                source: .p1080,
                target: .p1080,
                scale: .one,
                gate: .optionalRuntimeSupport,
                defaultEligibility: .ineligibleOptionalSupport
            )
        ]

        XCTAssertEqual(observed, expected)
        XCTAssertEqual(
            R04VideoToolboxRouteCatalog.routes.map(\.subjectID),
            R04VideoToolboxSubjectID.allCases
        )
        XCTAssertEqual(
            R04VideoToolboxRouteCatalog.routes.map(\.routeID),
            R04VideoToolboxRouteID.allCases
        )
        XCTAssertTrue(
            R04VideoToolboxRouteCatalog.routes.allSatisfy {
                $0.productQualification == .notClaimed
            }
        )
    }

    func testQualityPolicyRequiresOrderedHistoryAndEveryResetBoundary() throws {
        let quality = try XCTUnwrap(
            R04VideoToolboxRouteCatalog.route(R04VideoToolboxSubjectID.quality2x)
        )
        let lowLatency = try XCTUnwrap(
            R04VideoToolboxRouteCatalog.route(R04VideoToolboxSubjectID.lowLatency2x)
        )

        XCTAssertEqual(quality.temporalPolicy.firstFrameSubmissionMode, .random)
        XCTAssertEqual(quality.temporalPolicy.continuingSubmissionMode, .sequential)
        XCTAssertTrue(quality.temporalPolicy.suppliesPreviousSource)
        XCTAssertTrue(quality.temporalPolicy.suppliesPreviousOutput)
        XCTAssertTrue(quality.temporalPolicy.resetsOnFirstFrame)
        XCTAssertEqual(
            quality.temporalPolicy.resetReasons,
            [.sceneCut, .discontinuity, .callerRequested]
        )
        XCTAssertEqual(quality.opticalFlowRole, .optionalQualityInput)

        XCTAssertEqual(lowLatency.temporalPolicy, .statelessRandom)
        XCTAssertEqual(lowLatency.opticalFlowRole, .notApplicable)
    }

    func testA01OneAndOneHalfIsOnlyTheTypedUnrepresentableContract() throws {
        let route = try XCTUnwrap(
            R04VideoToolboxRouteCatalog.route(
                R04VideoToolboxSubjectID.quality1p5xContract
            )
        )

        XCTAssertEqual(route.capabilityID, "A01")
        XCTAssertEqual(route.scaleFactor, .oneAndOneHalf)
        XCTAssertEqual(route.gate, .publicContractUnrepresentable)
        XCTAssertEqual(
            route.productDefaultEligibility,
            .ineligibleContractRejection
        )
    }

    func testA02RoutesRemainSeparateExactDimensionQueries() throws {
        let oneAndOneHalf = try XCTUnwrap(
            R04VideoToolboxRouteCatalog.route(
                R04VideoToolboxSubjectID.lowLatency1p5x
            )
        )
        let two = try XCTUnwrap(
            R04VideoToolboxRouteCatalog.route(R04VideoToolboxSubjectID.lowLatency2x)
        )
        let four = try XCTUnwrap(
            R04VideoToolboxRouteCatalog.route(R04VideoToolboxSubjectID.lowLatency4x)
        )

        XCTAssertEqual(oneAndOneHalf.capabilityID, "A02")
        XCTAssertEqual(two.capabilityID, "A02")
        XCTAssertEqual(four.capabilityID, "A02")
        XCTAssertEqual(oneAndOneHalf.gate, .exactDimensionQueryRequired)
        XCTAssertEqual(two.gate, .exactDimensionQueryRequired)
        XCTAssertEqual(four.gate, .exactDimensionQueryRequired)
        XCTAssertNotEqual(oneAndOneHalf.configurationIdentity, two.configurationIdentity)
        XCTAssertNotEqual(two.configurationIdentity, four.configurationIdentity)
    }

    func testNativeRouteSelectorBindsOnlyRepresentableExactRoutes() throws {
        let quality = try XCTUnwrap(
            R04VideoToolboxNativeRouteSelector.exactBinding(
                sourceResolution: .p1080,
                targetResolution: .p2160,
                intent: .quality
            )
        )
        XCTAssertEqual(quality.subjectID, .quality2x)
        XCTAssertTrue(quality.requiresConfigurationModel)

        let qualityFour = try XCTUnwrap(
            R04VideoToolboxNativeRouteSelector.exactBinding(
                sourceResolution: .p270,
                targetResolution: .p1080,
                intent: .quality
            )
        )
        XCTAssertEqual(qualityFour.subjectID, .quality4x)
        XCTAssertTrue(qualityFour.requiresConfigurationModel)

        let lowLatencyOneAndOneHalf = try XCTUnwrap(
            R04VideoToolboxNativeRouteSelector.exactBinding(
                sourceResolution: .p720,
                targetResolution: .p1080,
                intent: .lowLatency
            )
        )
        XCTAssertEqual(lowLatencyOneAndOneHalf.subjectID, .lowLatency1p5x)
        XCTAssertFalse(lowLatencyOneAndOneHalf.requiresConfigurationModel)

        let lowLatencyTwo = try XCTUnwrap(
            R04VideoToolboxNativeRouteSelector.exactBinding(
                sourceResolution: .p1080,
                targetResolution: .p2160,
                intent: .lowLatency
            )
        )
        XCTAssertEqual(lowLatencyTwo.subjectID, .lowLatency2x)
        XCTAssertFalse(lowLatencyTwo.requiresConfigurationModel)

        let lowLatencyFour = try XCTUnwrap(
            R04VideoToolboxNativeRouteSelector.exactBinding(
                sourceResolution: .p270,
                targetResolution: .p1080,
                intent: .lowLatency
            )
        )
        XCTAssertEqual(lowLatencyFour.subjectID, .lowLatency4x)
        XCTAssertFalse(lowLatencyFour.requiresConfigurationModel)

        XCTAssertNil(
            R04VideoToolboxNativeRouteSelector.exactBinding(
                sourceResolution: .p720,
                targetResolution: .p1080,
                intent: .quality
            )
        )
        XCTAssertNil(
            R04VideoToolboxNativeRouteSelector.exactBinding(
                sourceResolution: .p1080,
                targetResolution: .p1080,
                intent: .lowLatency
            )
        )
    }

    func testA05IsSupportOnlyAndCannotBecomePrimary() throws {
        let route = try XCTUnwrap(
            R04VideoToolboxRouteCatalog.route(
                R04VideoToolboxSubjectID.opticalFlowSupport
            )
        )

        XCTAssertEqual(route.backendKind, .optionalFlowSupport)
        XCTAssertEqual(route.opticalFlowRole, .optionalSupportOnly)
        XCTAssertEqual(route.gate, .optionalRuntimeSupport)
        XCTAssertEqual(
            route.productDefaultEligibility,
            .ineligibleOptionalSupport
        )
    }

    func testScaleFactorsReduceAndRejectInvalidOrMismatchedRoutes() throws {
        XCTAssertEqual(
            try R04VideoToolboxScaleFactor(numerator: 6, denominator: 4),
            .oneAndOneHalf
        )
        XCTAssertEqual(
            try R04VideoToolboxScaleFactor(numerator: 8, denominator: 2),
            .four
        )
        XCTAssertThrowsError(
            try R04VideoToolboxScaleFactor(numerator: 0, denominator: 1)
        )
        XCTAssertThrowsError(
            try R04VideoToolboxRouteDescriptor(
                subjectID: .quality2x,
                routeID: .quality2x,
                capabilityID: "A01",
                backendKind: .quality,
                sourceResolution: .p720,
                targetResolution: .p1080,
                scaleFactor: .two,
                gate: .runtimeSupportRequired,
                configurationContract: R04VideoToolboxConfigurationContract(
                    frameWidth: VideoResolution.p720.width,
                    frameHeight: VideoResolution.p720.height,
                    scaleFactorIdentity: "2",
                    inputType: .video,
                    precomputedFlowChoice: .optionalPerRequest,
                    qualityPriority: .quality,
                    revision: .runtimeSelectedNotObserved,
                    supportedFormats: .notObserved,
                    modelStatus: .notObserved,
                    processingMode: .qualityTemporal,
                    exactDimensionQueryRequired: false
                ),
                temporalPolicy: .qualitySequential,
                opticalFlowRole: .optionalQualityInput,
                productDefaultEligibility: .candidateAfterObservedQualification
            )
        ) { error in
            XCTAssertEqual(
                error as? R04VideoToolboxContractError,
                .scaleDoesNotMatchRoute(.quality2x)
            )
        }
    }

    func testRouteIdentityIsCompleteWithoutInferringProductQualification() throws {
        let route = try XCTUnwrap(
            R04VideoToolboxRouteCatalog.route(
                R04VideoToolboxSubjectID.lowLatency1p5x
            )
        )
        let identity = try R04VideoToolboxRouteCatalog.makeRouteIdentity(
            for: route,
            modelAssetsIdentity: .notRequired
        )

        XCTAssertEqual(identity.backend.backendID, route.subjectID.rawValue)
        XCTAssertEqual(
            identity.backend.backendRevision,
            R04VideoToolboxRouteCatalog.backendRevision
        )
        XCTAssertEqual(identity.configurationIdentity, route.configurationIdentity)
        XCTAssertEqual(
            identity.policyIdentity,
            R04VideoToolboxRouteCatalog.policyIdentity
        )
        XCTAssertEqual(
            identity.materialDecisionIdentity,
            R04VideoToolboxRouteCatalog.materialDecisionIdentity
        )
        XCTAssertEqual(route.productQualification, .notClaimed)
    }

    func testStableConfigurationContractRecordsRequestedAndUnobservedFields() throws {
        let quality = try XCTUnwrap(
            R04VideoToolboxRouteCatalog.route(R04VideoToolboxSubjectID.quality2x)
        )
        let lowLatency = try XCTUnwrap(
            R04VideoToolboxRouteCatalog.route(
                R04VideoToolboxSubjectID.lowLatency1p5x
            )
        )

        XCTAssertEqual(quality.configurationContract.frameWidth, 1_920)
        XCTAssertEqual(quality.configurationContract.frameHeight, 1_080)
        XCTAssertEqual(quality.configurationContract.scaleFactorIdentity, "2")
        XCTAssertEqual(quality.configurationContract.inputType, .video)
        XCTAssertEqual(
            quality.configurationContract.precomputedFlowChoice,
            .optionalPerRequest
        )
        XCTAssertEqual(quality.configurationContract.qualityPriority, .quality)
        XCTAssertEqual(
            quality.configurationContract.revision,
            .runtimeSelectedNotObserved
        )
        XCTAssertEqual(
            quality.configurationContract.supportedFormats,
            .notObserved
        )
        XCTAssertEqual(quality.configurationContract.modelStatus, .notObserved)

        XCTAssertEqual(lowLatency.configurationContract.frameWidth, 1_280)
        XCTAssertEqual(lowLatency.configurationContract.frameHeight, 720)
        XCTAssertEqual(lowLatency.configurationContract.scaleFactorIdentity, "1.5")
        XCTAssertTrue(lowLatency.configurationContract.exactDimensionQueryRequired)
        XCTAssertEqual(lowLatency.configurationContract.modelStatus, .notRequired)
    }
}

private struct ExpectedRoute: Equatable {
    let subjectID: R04VideoToolboxSubjectID
    let routeID: R04VideoToolboxRouteID
    let capabilityID: String
    let backendKind: R04VideoToolboxBackendKind
    let source: VideoResolution
    let target: VideoResolution
    let scale: R04VideoToolboxScaleFactor
    let gate: R04VideoToolboxRouteGate
    let defaultEligibility: R04VideoToolboxProductDefaultEligibility

    init(
        subjectID: R04VideoToolboxSubjectID,
        routeID: R04VideoToolboxRouteID,
        capabilityID: String,
        backendKind: R04VideoToolboxBackendKind,
        source: VideoResolution,
        target: VideoResolution,
        scale: R04VideoToolboxScaleFactor,
        gate: R04VideoToolboxRouteGate,
        defaultEligibility: R04VideoToolboxProductDefaultEligibility
    ) {
        self.subjectID = subjectID
        self.routeID = routeID
        self.capabilityID = capabilityID
        self.backendKind = backendKind
        self.source = source
        self.target = target
        self.scale = scale
        self.gate = gate
        self.defaultEligibility = defaultEligibility
    }

    init(_ route: R04VideoToolboxRouteDescriptor) {
        self.init(
            subjectID: route.subjectID,
            routeID: route.routeID,
            capabilityID: route.capabilityID,
            backendKind: route.backendKind,
            source: route.sourceResolution,
            target: route.targetResolution,
            scale: route.scaleFactor,
            gate: route.gate,
            defaultEligibility: route.productDefaultEligibility
        )
    }
}
