import Foundation

struct AppleUpscaleStageID: Hashable, Sendable {
    let rawValue: String

    init(_ rawValue: String) throws {
        self.rawValue = try requireAppleUpscaleIdentity(
            rawValue,
            field: "stage_id"
        )
    }
}

enum AppleUpscaleStageRole: String, Hashable, Sendable {
    case preprocessing
    case primaryScaling = "primary_scaling"
    case postprocessing
    case temporal
    case analysis
}

protocol AppleUpscalePreprocessingStage: AnyObject, Sendable {
    var stageID: AppleUpscaleStageID { get }

    func preprocess(
        _ frame: AppleUpscaleFrame
    ) async -> AppleUpscaleBackendOutcome<AppleUpscaleFrame>
}

protocol AppleUpscalePrimaryScalingStage: AnyObject, Sendable {
    var planningBinding: EnhancementPipelinePrimaryBinding { get }

    func scale(
        _ frame: AppleUpscaleFrame
    ) async -> AppleUpscaleBackendOutcome<AppleUpscaleProcessedFrame>
}

extension AppleUpscalePrimaryScalingStage {
    var stageID: AppleUpscaleStageID {
        planningBinding.stageID
    }

    var routeIdentity: AppleUpscaleRouteIdentity {
        planningBinding.routeIdentity
    }
}

protocol AppleUpscalePostprocessingStage: AnyObject, Sendable {
    var stageID: AppleUpscaleStageID { get }

    func postprocess(
        _ frame: AppleUpscaleProcessedFrame
    ) async -> AppleUpscaleBackendOutcome<AppleUpscaleProcessedFrame>
}

protocol AppleUpscaleTemporalStage: AnyObject, Sendable {
    var stageID: AppleUpscaleStageID { get }

    func processTemporal(
        _ frame: AppleUpscaleProcessedFrame
    ) async -> AppleUpscaleBackendOutcome<AppleUpscaleProcessedFrame>
}

protocol AppleUpscaleAnalysisStage: AnyObject, Sendable {
    var stageID: AppleUpscaleStageID { get }

    func analyze(
        _ frame: AppleUpscaleFrame
    ) async -> AppleUpscaleBackendOutcome<AppleUpscaleFrame>
}

enum EnhancementPipelineStage: Sendable {
    case preprocessing(any AppleUpscalePreprocessingStage)
    case primaryScaling(any AppleUpscalePrimaryScalingStage)
    case postprocessing(any AppleUpscalePostprocessingStage)
    case temporal(any AppleUpscaleTemporalStage)
    case analysis(any AppleUpscaleAnalysisStage)

    var stageID: AppleUpscaleStageID {
        switch self {
        case .preprocessing(let stage):
            return stage.stageID
        case .primaryScaling(let stage):
            return stage.stageID
        case .postprocessing(let stage):
            return stage.stageID
        case .temporal(let stage):
            return stage.stageID
        case .analysis(let stage):
            return stage.stageID
        }
    }

    var role: AppleUpscaleStageRole {
        switch self {
        case .preprocessing:
            return .preprocessing
        case .primaryScaling:
            return .primaryScaling
        case .postprocessing:
            return .postprocessing
        case .temporal:
            return .temporal
        case .analysis:
            return .analysis
        }
    }
}

enum EnhancementPipelinePlanningError: Error, Equatable, Sendable {
    case missingPrimaryStage
    case multiplePrimaryStages(Int)
    case duplicateStageID(String)
    case primaryRouteRepeatedAsFallback(String)
    case duplicateFallbackRoute(String)
    case fallbackOrdinalOutOfRange(Int)
    case fallbackChainDiscontinuity(
        expectedBackendID: String,
        actualBackendID: String
    )
}

struct EnhancementPipelineStageBinding: Hashable, Sendable {
    let stageID: AppleUpscaleStageID
    let role: AppleUpscaleStageRole
    let routeIdentity: AppleUpscaleRouteIdentity?

    fileprivate init(
        stageID: AppleUpscaleStageID,
        role: AppleUpscaleStageRole,
        routeIdentity: AppleUpscaleRouteIdentity? = nil
    ) {
        self.stageID = stageID
        self.role = role
        self.routeIdentity = routeIdentity
    }
}

struct EnhancementPipelinePrimaryBinding: Hashable, Sendable {
    let stageID: AppleUpscaleStageID
    let routeIdentity: AppleUpscaleRouteIdentity

    init(
        stageID: AppleUpscaleStageID,
        routeIdentity: AppleUpscaleRouteIdentity
    ) {
        self.stageID = stageID
        self.routeIdentity = routeIdentity
    }
}

struct EnhancementPipelinePlan: Sendable {
    let orderedStageBindings: [EnhancementPipelineStageBinding]
    let primaryBinding: EnhancementPipelinePrimaryBinding
    let orderedFallbackPrimaryBindings: [EnhancementPipelinePrimaryBinding]

    private let orderedStages: [EnhancementPipelineStage]
    private let primaryScalingStage: any AppleUpscalePrimaryScalingStage
    private let orderedFallbackPrimaryStages: [any AppleUpscalePrimaryScalingStage]

    fileprivate init(
        orderedStages: [EnhancementPipelineStage],
        primaryScalingStage: any AppleUpscalePrimaryScalingStage,
        orderedFallbackPrimaryStages: [any AppleUpscalePrimaryScalingStage],
        orderedStageBindings: [EnhancementPipelineStageBinding],
        primaryBinding: EnhancementPipelinePrimaryBinding,
        orderedFallbackPrimaryBindings: [EnhancementPipelinePrimaryBinding]
    ) {
        self.orderedStages = orderedStages
        self.primaryScalingStage = primaryScalingStage
        self.orderedFallbackPrimaryStages = orderedFallbackPrimaryStages
        self.orderedStageBindings = orderedStageBindings
        self.primaryBinding = primaryBinding
        self.orderedFallbackPrimaryBindings = orderedFallbackPrimaryBindings
    }

    func fallbackLink(
        after failedRoute: AppleUpscaleRouteIdentity,
        reasonCode: AppleUpscaleFallbackReasonCode,
        selectedFallbackOrdinal: Int
    ) throws -> AppleUpscaleFallbackLink {
        guard orderedFallbackPrimaryBindings.indices.contains(selectedFallbackOrdinal) else {
            throw EnhancementPipelinePlanningError.fallbackOrdinalOutOfRange(
                selectedFallbackOrdinal
            )
        }

        let expectedFailedRoute: AppleUpscaleRouteIdentity
        if selectedFallbackOrdinal == 0 {
            expectedFailedRoute = primaryBinding.routeIdentity
        } else {
            expectedFailedRoute = orderedFallbackPrimaryBindings[
                selectedFallbackOrdinal - 1
            ].routeIdentity
        }
        guard failedRoute == expectedFailedRoute else {
            throw EnhancementPipelinePlanningError.fallbackChainDiscontinuity(
                expectedBackendID: expectedFailedRoute.backend.backendID,
                actualBackendID: failedRoute.backend.backendID
            )
        }

        return try AppleUpscaleFallbackLink(
            failedRoute: failedRoute,
            selectedRoute: orderedFallbackPrimaryBindings[
                selectedFallbackOrdinal
            ].routeIdentity,
            reasonCode: reasonCode,
            selectedFallbackOrdinal: selectedFallbackOrdinal
        )
    }
}

struct EnhancementPipelinePlanner: Sendable {
    func makePlan(
        orderedStages: [EnhancementPipelineStage],
        orderedFallbackPrimaryStages: [any AppleUpscalePrimaryScalingStage]
    ) throws -> EnhancementPipelinePlan {
        var orderedStageBindings: [EnhancementPipelineStageBinding] = []
        var primaryStage: (any AppleUpscalePrimaryScalingStage)?
        var primaryBinding: EnhancementPipelinePrimaryBinding?
        var primaryStageCount = 0
        for stage in orderedStages {
            let binding: EnhancementPipelineStageBinding
            switch stage {
            case .preprocessing(let implementation):
                binding = EnhancementPipelineStageBinding(
                    stageID: implementation.stageID,
                    role: .preprocessing
                )
            case .primaryScaling(let implementation):
                let capturedBinding = implementation.planningBinding
                binding = EnhancementPipelineStageBinding(
                    stageID: capturedBinding.stageID,
                    role: .primaryScaling,
                    routeIdentity: capturedBinding.routeIdentity
                )
                primaryStageCount += 1
                if primaryStage == nil {
                    primaryStage = implementation
                    primaryBinding = capturedBinding
                }
            case .postprocessing(let implementation):
                binding = EnhancementPipelineStageBinding(
                    stageID: implementation.stageID,
                    role: .postprocessing
                )
            case .temporal(let implementation):
                binding = EnhancementPipelineStageBinding(
                    stageID: implementation.stageID,
                    role: .temporal
                )
            case .analysis(let implementation):
                binding = EnhancementPipelineStageBinding(
                    stageID: implementation.stageID,
                    role: .analysis
                )
            }
            orderedStageBindings.append(binding)
        }
        guard primaryStageCount > 0 else {
            throw EnhancementPipelinePlanningError.missingPrimaryStage
        }
        guard primaryStageCount == 1,
              let primaryStage,
              let primaryBinding else {
            throw EnhancementPipelinePlanningError.multiplePrimaryStages(
                primaryStageCount
            )
        }

        var stageIDs: Set<AppleUpscaleStageID> = []
        for binding in orderedStageBindings {
            guard stageIDs.insert(binding.stageID).inserted else {
                throw EnhancementPipelinePlanningError.duplicateStageID(
                    binding.stageID.rawValue
                )
            }
        }

        var fallbackRoutes: Set<AppleUpscaleRouteIdentity> = []
        var orderedFallbackPrimaryBindings: [EnhancementPipelinePrimaryBinding] = []
        for fallbackStage in orderedFallbackPrimaryStages {
            let fallbackBinding = fallbackStage.planningBinding
            guard stageIDs.insert(fallbackBinding.stageID).inserted else {
                throw EnhancementPipelinePlanningError.duplicateStageID(
                    fallbackBinding.stageID.rawValue
                )
            }
            guard fallbackBinding.routeIdentity != primaryBinding.routeIdentity else {
                throw EnhancementPipelinePlanningError.primaryRouteRepeatedAsFallback(
                    fallbackBinding.routeIdentity.backend.backendID
                )
            }
            guard fallbackRoutes.insert(fallbackBinding.routeIdentity).inserted else {
                throw EnhancementPipelinePlanningError.duplicateFallbackRoute(
                    fallbackBinding.routeIdentity.backend.backendID
                )
            }
            orderedFallbackPrimaryBindings.append(fallbackBinding)
        }

        return EnhancementPipelinePlan(
            orderedStages: orderedStages,
            primaryScalingStage: primaryStage,
            orderedFallbackPrimaryStages: orderedFallbackPrimaryStages,
            orderedStageBindings: orderedStageBindings,
            primaryBinding: primaryBinding,
            orderedFallbackPrimaryBindings: orderedFallbackPrimaryBindings
        )
    }
}
