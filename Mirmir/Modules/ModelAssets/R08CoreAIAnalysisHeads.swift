enum R08AnalysisOutputHeadID: String, CaseIterable, Hashable, Sendable {
    case faceSkinProtectionMask = "face_skin_protection_mask"
    case textLineArtProtectionMask = "text_line_art_protection_mask"
    case animationUIContentLikelihood = "animation_ui_content_likelihood"
    case noiseCompressionSeverityMap = "noise_compression_severity_map"
    case blurMotionBlurEstimate = "blur_motion_blur_estimate"
    case aliasingRingingRiskMap = "aliasing_ringing_risk_map"
    case textureDetailConfidence = "texture_detail_confidence"
    case motionReliabilityOcclusionRisk = "motion_reliability_occlusion_risk"
    case noReferenceQualityEstimate = "no_reference_quality_estimate"
}

enum R08RawAnalysisOutputPayload: Hashable, Sendable {
    case spatial(width: Int, height: Int, samplesQ15: [Int64])
    case scalar(samplesQ15: [Int64])
}

struct R08RawAnalysisOutputHead: Hashable, Sendable {
    let id: String
    let payload: R08RawAnalysisOutputPayload
}

struct R08Q15Map: Hashable, Sendable {
    static let maximumSample: Int64 = 32_767

    let width: Int
    let height: Int
    let samples: [Int64]

    init(width: Int, height: Int, samples: [Int64], role: String) throws {
        let count = try R08AnalysisValidation.sampleCount(
            width: width,
            height: height,
            role: role
        )
        guard samples.count == count else {
            throw R08AnalysisContractError.sampleCountMismatch(
                role: role,
                expected: count,
                actual: samples.count
            )
        }
        if let invalid = samples.enumerated().first(where: {
            !(0...Self.maximumSample).contains($0.element)
        }) {
            throw R08AnalysisContractError.sampleOutOfRange(
                role: role,
                index: invalid.offset,
                value: invalid.element
            )
        }
        self.width = width
        self.height = height
        self.samples = samples
    }

    var maximum: Int64 {
        samples.max() ?? 0
    }

    var minimum: Int64 {
        samples.min() ?? 0
    }

    var mean: Int64 {
        samples.reduce(0, +) / Int64(samples.count)
    }

    func q16Maximum() -> Int64 {
        (maximum * 65_536) / Self.maximumSample
    }

    func q16Minimum() -> Int64 {
        (minimum * 65_536) / Self.maximumSample
    }
}

struct R08Q15Value: Hashable, Sendable {
    let rawValue: Int64

    init(_ rawValue: Int64, role: String) throws {
        guard (0...R08Q15Map.maximumSample).contains(rawValue) else {
            throw R08AnalysisContractError.sampleOutOfRange(
                role: role,
                index: 0,
                value: rawValue
            )
        }
        self.rawValue = rawValue
    }
}

enum R08SourceClassification: String, CaseIterable, Hashable, Sendable {
    case naturalVideo = "natural_video"
    case animation
    case uiCapture = "ui_capture"
    case mixed
}

struct R08SourceClassificationResult: Hashable, Sendable {
    let classification: R08SourceClassification
    let confidenceQ15: R08Q15Value
}

struct R08ProtectionHeads: Hashable, Sendable {
    let faceSkinQ15: R08Q15Map
    let textLineArtQ15: R08Q15Map
}

struct R08ConditionHeads: Hashable, Sendable {
    let animationUILikelihoodQ15: R08Q15Map
    let noiseCompressionSeverityQ15: R08Q15Map
    let blurMotionBlurEstimateQ15: R08Q15Map
}

struct R08RiskConfidenceHeads: Hashable, Sendable {
    let aliasingRingingRiskQ15: R08Q15Map
    let textureDetailConfidenceQ15: R08Q15Map
    let motionReliabilityOcclusionRiskQ15: R08Q15Map
}

struct R08AnalysisHeads: Hashable, Sendable {
    static let width = 2
    static let height = 2

    let protection: R08ProtectionHeads
    let condition: R08ConditionHeads
    let riskConfidence: R08RiskConfidenceHeads
    let noReferenceQualityQ15: R08Q15Value
    let sourceClassification: R08SourceClassificationResult

    init(
        protection: R08ProtectionHeads,
        condition: R08ConditionHeads,
        riskConfidence: R08RiskConfidenceHeads,
        noReferenceQualityQ15: R08Q15Value,
        sourceClassification: R08SourceClassificationResult
    ) throws {
        let maps: [(String, R08Q15Map)] = [
            ("face_skin_protection", protection.faceSkinQ15),
            ("text_line_art_protection", protection.textLineArtQ15),
            ("animation_ui_likelihood", condition.animationUILikelihoodQ15),
            ("noise_compression_severity", condition.noiseCompressionSeverityQ15),
            ("blur_motion_blur_estimate", condition.blurMotionBlurEstimateQ15),
            ("aliasing_ringing_risk", riskConfidence.aliasingRingingRiskQ15),
            ("texture_detail_confidence", riskConfidence.textureDetailConfidenceQ15),
            (
                "motion_reliability_occlusion_risk",
                riskConfidence.motionReliabilityOcclusionRiskQ15
            )
        ]
        for (role, map) in maps where map.width != Self.width || map.height != Self.height {
            throw R08AnalysisContractError.headGeometryMismatch(
                role: role,
                expectedWidth: Self.width,
                expectedHeight: Self.height
            )
        }
        self.protection = protection
        self.condition = condition
        self.riskConfidence = riskConfidence
        self.noReferenceQualityQ15 = noReferenceQualityQ15
        self.sourceClassification = sourceClassification
    }
}

enum R08AnalysisOutputDecoder {
    static func decode(
        _ rawHeads: [R08RawAnalysisOutputHead],
        sourceClassification: R08SourceClassificationResult
    ) throws -> R08AnalysisHeads {
        var payloads: [R08AnalysisOutputHeadID: R08RawAnalysisOutputPayload] = [:]
        for rawHead in rawHeads {
            guard let id = R08AnalysisOutputHeadID(rawValue: rawHead.id) else {
                throw forbiddenOrUnexpectedOutputError(rawHead.id)
            }
            guard payloads[id] == nil else {
                throw R08AnalysisContractError.duplicateOutputHead(rawHead.id)
            }
            payloads[id] = rawHead.payload
        }
        for id in R08AnalysisOutputHeadID.allCases where payloads[id] == nil {
            throw R08AnalysisContractError.missingOutputHead(id.rawValue)
        }

        return try R08AnalysisHeads(
            protection: R08ProtectionHeads(
                faceSkinQ15: spatial(.faceSkinProtectionMask, payloads: payloads),
                textLineArtQ15: spatial(.textLineArtProtectionMask, payloads: payloads)
            ),
            condition: R08ConditionHeads(
                animationUILikelihoodQ15: spatial(
                    .animationUIContentLikelihood,
                    payloads: payloads
                ),
                noiseCompressionSeverityQ15: spatial(
                    .noiseCompressionSeverityMap,
                    payloads: payloads
                ),
                blurMotionBlurEstimateQ15: spatial(
                    .blurMotionBlurEstimate,
                    payloads: payloads
                )
            ),
            riskConfidence: R08RiskConfidenceHeads(
                aliasingRingingRiskQ15: spatial(
                    .aliasingRingingRiskMap,
                    payloads: payloads
                ),
                textureDetailConfidenceQ15: spatial(
                    .textureDetailConfidence,
                    payloads: payloads
                ),
                motionReliabilityOcclusionRiskQ15: spatial(
                    .motionReliabilityOcclusionRisk,
                    payloads: payloads
                )
            ),
            noReferenceQualityQ15: scalar(.noReferenceQualityEstimate, payloads: payloads),
            sourceClassification: sourceClassification
        )
    }
}

private extension R08AnalysisOutputDecoder {
    static func forbiddenOrUnexpectedOutputError(
        _ id: String
    ) -> R08AnalysisContractError {
        switch id {
        case "pixel_frame", "pixel_residual":
            return .forbiddenPixelOutput(id)
        case "selected_backend_id":
            return .forbiddenModelDecisionAuthority(id)
        default:
            return .unexpectedOutputHead(id)
        }
    }

    static func spatial(
        _ id: R08AnalysisOutputHeadID,
        payloads: [R08AnalysisOutputHeadID: R08RawAnalysisOutputPayload]
    ) throws -> R08Q15Map {
        guard case .spatial(let width, let height, let samples)? = payloads[id] else {
            throw R08AnalysisContractError.outputHeadKindMismatch(id.rawValue)
        }
        return try R08Q15Map(
            width: width,
            height: height,
            samples: samples,
            role: id.rawValue
        )
    }

    static func scalar(
        _ id: R08AnalysisOutputHeadID,
        payloads: [R08AnalysisOutputHeadID: R08RawAnalysisOutputPayload]
    ) throws -> R08Q15Value {
        guard case .scalar(let samples)? = payloads[id] else {
            throw R08AnalysisContractError.outputHeadKindMismatch(id.rawValue)
        }
        guard samples.count == 1 else {
            throw R08AnalysisContractError.sampleCountMismatch(
                role: id.rawValue,
                expected: 1,
                actual: samples.count
            )
        }
        return try R08Q15Value(samples[0], role: id.rawValue)
    }
}

struct R08AnalysisResult: Hashable, Sendable {
    let request: R08AnalysisRequest
    let executionIdentity: R08AnalysisExecutionIdentity
    let heads: R08AnalysisHeads
    let resourceUsage: R08AnalysisResourceUsage
    let stateReceipt: R08AnalysisStateReceipt
    let cacheDisposition: R08AnalysisCacheDisposition
    let pixelAuthority = R08AnalysisPixelAuthority.analysisOnlyNoPixelOutput

    init(
        request: R08AnalysisRequest,
        executionIdentity: R08AnalysisExecutionIdentity,
        heads: R08AnalysisHeads,
        resourceUsage: R08AnalysisResourceUsage,
        stateReceipt: R08AnalysisStateReceipt,
        cacheDisposition: R08AnalysisCacheDisposition
    ) throws {
        switch executionIdentity.mode {
        case .deterministicFixtureSimulation:
            guard executionIdentity.nativeExecution == .notObserved,
                  request.proxyIdentity == .frozenAnalysisProxy,
                  request.modelIdentity.artifactKind == .deterministicSimulationContract,
                  request.inputTransfer.executionMode == executionIdentity.mode,
                  request.zeroCopyDisposition == .notUsedDeterministicSimulation else {
                throw R08AnalysisContractError.invalidSimulationBinding
            }
        case .nativeCoreAI:
            let hasValidNativeTransfer = request.zeroCopyDisposition == .used
                || request.zeroCopyDisposition == .copiedDeterministicFallback
            guard executionIdentity.nativeExecution == .observed,
                  request.modelIdentity.artifactKind == .coreAIModel,
                  request.inputTransfer.executionMode == executionIdentity.mode,
                  hasValidNativeTransfer else {
                throw R08AnalysisContractError.invalidSimulationBinding
            }
        }
        guard stateReceipt.generation == request.stateGeneration,
              stateReceipt.frameOrdinal == request.frameOrdinal,
              request.scheduleTrigger != nil,
              resourceUsage.zeroCopyDisposition == request.zeroCopyDisposition,
              resourceUsage.aotCompilation == request.aotCompilation else {
            throw R08AnalysisContractError.invalidSimulationBinding
        }
        self.request = request
        self.executionIdentity = executionIdentity
        self.heads = heads
        self.resourceUsage = resourceUsage
        self.stateReceipt = stateReceipt
        self.cacheDisposition = cacheDisposition
    }
}
