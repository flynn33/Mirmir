enum R06ASHMaskID: String, CaseIterable, Hashable, Sendable {
    case lumaProtection = "luma_protection"
    case chromaProtection = "chroma_protection"
    case postprocessSuppression = "postprocess_suppression"
}

enum R06ASHMaskError: Error, Hashable, Sendable {
    case invalidWidth(Int)
    case invalidHeight(Int)
    case sampleCountOverflow(width: Int, height: Int)
    case sampleCountMismatch(expected: Int, actual: Int)
    case sampleOutOfRange(index: Int, value: UInt16)
    case maskCountMismatch(expected: Int, actual: Int)
    case duplicateMaskID(R06ASHMaskID)
    case missingMaskID(R06ASHMaskID)
    case maskIdentityMismatch(expected: R06ASHMaskID, actual: R06ASHMaskID)
}

struct R06ASHMask: Hashable, Sendable {
    static let minimumDimension = 1
    static let maximumDimension = 64
    static let minimumSampleQ15: UInt16 = 0
    static let maximumSampleQ15: UInt16 = 32_767

    let id: R06ASHMaskID
    let width: Int
    let height: Int
    let samplesQ15: [UInt16]

    init(
        id: R06ASHMaskID,
        width: Int,
        height: Int,
        samplesQ15: [UInt16]
    ) throws {
        guard width >= Self.minimumDimension else {
            throw R06ASHMaskError.invalidWidth(width)
        }
        guard height >= Self.minimumDimension else {
            throw R06ASHMaskError.invalidHeight(height)
        }

        let sampleCount = width.multipliedReportingOverflow(by: height)
        guard !sampleCount.overflow else {
            throw R06ASHMaskError.sampleCountOverflow(
                width: width,
                height: height
            )
        }
        guard width <= Self.maximumDimension else {
            throw R06ASHMaskError.invalidWidth(width)
        }
        guard height <= Self.maximumDimension else {
            throw R06ASHMaskError.invalidHeight(height)
        }
        guard samplesQ15.count == sampleCount.partialValue else {
            throw R06ASHMaskError.sampleCountMismatch(
                expected: sampleCount.partialValue,
                actual: samplesQ15.count
            )
        }
        if let invalid = samplesQ15.enumerated().first(where: {
            $0.element > Self.maximumSampleQ15
        }) {
            throw R06ASHMaskError.sampleOutOfRange(
                index: invalid.offset,
                value: invalid.element
            )
        }

        self.id = id
        self.width = width
        self.height = height
        self.samplesQ15 = samplesQ15
    }
}

struct R06ASHMaskSet: Hashable, Sendable {
    let lumaProtection: R06ASHMask
    let chromaProtection: R06ASHMask
    let postprocessSuppression: R06ASHMask

    init(
        lumaProtection: R06ASHMask,
        chromaProtection: R06ASHMask,
        postprocessSuppression: R06ASHMask
    ) throws {
        try Self.requireIdentity(
            .lumaProtection,
            for: lumaProtection
        )
        try Self.requireIdentity(
            .chromaProtection,
            for: chromaProtection
        )
        try Self.requireIdentity(
            .postprocessSuppression,
            for: postprocessSuppression
        )
        self.lumaProtection = lumaProtection
        self.chromaProtection = chromaProtection
        self.postprocessSuppression = postprocessSuppression
    }

    init(masks: [R06ASHMask]) throws {
        let expectedCount = R06ASHMaskID.allCases.count
        guard masks.count == expectedCount else {
            throw R06ASHMaskError.maskCountMismatch(
                expected: expectedCount,
                actual: masks.count
            )
        }

        var masksByID: [R06ASHMaskID: R06ASHMask] = [:]
        for mask in masks {
            guard masksByID.updateValue(mask, forKey: mask.id) == nil else {
                throw R06ASHMaskError.duplicateMaskID(mask.id)
            }
        }

        func require(_ id: R06ASHMaskID) throws -> R06ASHMask {
            guard let mask = masksByID[id] else {
                throw R06ASHMaskError.missingMaskID(id)
            }
            return mask
        }

        try self.init(
            lumaProtection: require(.lumaProtection),
            chromaProtection: require(.chromaProtection),
            postprocessSuppression: require(.postprocessSuppression)
        )
    }

    var orderedMasks: [R06ASHMask] {
        [lumaProtection, chromaProtection, postprocessSuppression]
    }

    subscript(id: R06ASHMaskID) -> R06ASHMask {
        switch id {
        case .lumaProtection:
            return lumaProtection
        case .chromaProtection:
            return chromaProtection
        case .postprocessSuppression:
            return postprocessSuppression
        }
    }

    private static func requireIdentity(
        _ expected: R06ASHMaskID,
        for mask: R06ASHMask
    ) throws {
        guard mask.id == expected else {
            throw R06ASHMaskError.maskIdentityMismatch(
                expected: expected,
                actual: mask.id
            )
        }
    }
}

enum R06ASHAblationProductExecutionStatus: String, Hashable, Sendable {
    case notObserved = "not_observed"
}

enum R06ASHAblationPreregistrationStatus: String, Hashable, Sendable {
    case preregistered
}

enum R06ASHAblationFixtureContractStatus: String, Hashable, Sendable {
    case deterministicFixtureOnly = "deterministic_fixture_only"
}

enum R06ASHAblationMode: String, CaseIterable, Hashable, Sendable {
    case bestFixedEligibleAppleBackend = "best_fixed_eligible_apple_backend"
    case simpleContinuousRouterWithoutASH = "simple_continuous_router_without_ash"
    case ashStateOnlyRouter = "ash_state_only_router"
    case ashPlusContinuousSidecar = "ash_plus_continuous_sidecar"
    case ashWithoutHysteresis = "ash_without_hysteresis"
    case ashWithoutPostflightFeedback = "ash_without_postflight_feedback"

    var roadmapLabel: String {
        switch self {
        case .bestFixedEligibleAppleBackend:
            return "best fixed eligible Apple backend"
        case .simpleContinuousRouterWithoutASH:
            return "simple continuous router without ASH"
        case .ashStateOnlyRouter:
            return "ASH state-only router"
        case .ashPlusContinuousSidecar:
            return "ASH plus continuous sidecar"
        case .ashWithoutHysteresis:
            return "ASH without hysteresis"
        case .ashWithoutPostflightFeedback:
            return "ASH without postflight feedback"
        }
    }

    var productExecutionStatus: R06ASHAblationProductExecutionStatus {
        .notObserved
    }

    var preregistrationStatus: R06ASHAblationPreregistrationStatus {
        .preregistered
    }

    var fixtureContractStatus: R06ASHAblationFixtureContractStatus {
        .deterministicFixtureOnly
    }

    var requiredContextFixtureIDs: [String] {
        switch self {
        case .bestFixedEligibleAppleBackend:
            return ["initial", "steady_state"]
        case .simpleContinuousRouterWithoutASH:
            return ["initial", "postflight_risk"]
        case .ashStateOnlyRouter:
            return ["initial", "minimum_dwell"]
        case .ashPlusContinuousSidecar:
            return [
                "initial",
                "minimum_dwell",
                "scene_cut",
                "fatal_failure",
                "postflight_risk"
            ]
        case .ashWithoutHysteresis:
            return ["steady_state", "minimum_dwell"]
        case .ashWithoutPostflightFeedback:
            return ["steady_state", "postflight_risk"]
        }
    }
}
