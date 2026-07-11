import Foundation

enum ASHReconstructionError: Error, CustomStringConvertible, Equatable, Sendable {
    case invalidAffineAnchor
    case inconsistentRuntimeConfiguration
    case missingAdaptiveFeatures
    case uncorrectableBranchState(String)

    var description: String {
        switch self {
        case .invalidAffineAnchor:
            return "ASH affine decoding requires a parity-valid source-state anchor."
        case .inconsistentRuntimeConfiguration:
            return "ASH runtime provenance does not match the configured scoring policy."
        case .missingAdaptiveFeatures:
            return "Mirmir adaptive scoring requires the normalized ASH feature vector."
        case .uncorrectableBranchState(let path):
            return "ASH branch state at path '\(path)' is outside the strict one-bit affine decoding radius."
        }
    }
}

struct ASHReconstructionCandidate: Equatable, Sendable {
    let message: ASHMessage
    let priorWeight: Double
    let sourceScore: Double
    let policyScore: Double
    let totalScore: Double
    let reconstruction: ASHImage
}

struct ASHMappingResult: Equatable, Sendable {
    let features: ASHFeatureVector
    let sourceState: ASHState
    let branchNodes: [ASHBranchNode]
    let candidates: [ASHReconstructionCandidate]
    let selected: [ASHReconstructionCandidate]
    let evaluatedCandidateCount: Int
    let provenance: ASHRuntimeProvenance
}

enum ASHCandidateRetention: Equatable, Sendable {
    case all
    case selectedOnly
}

enum ASHScoringPolicy: Equatable, Sendable {
    static let adaptiveFeaturePriorWeight = 4.5
    static let adaptiveInactiveFloor = 0.15

    /// Bit-for-bit scoring semantics from ASH-Model's reconstruction reference.
    case referenceV1
    /// Mirmir's explicitly versioned feature prior; not canonical ASH scoring.
    case mirmirAdaptiveV1

    var specificationVersion: String {
        switch self {
        case .referenceV1:
            return "ash-reference-score-v1"
        case .mirmirAdaptiveV1:
            return "mirmir-adaptive-score-v1"
        }
    }
}

enum ASHReconstruction {
    static let defaultScale = 2
    static let defaultTopK = 4
    static let defaultOperatorStrength = 0.125
    static let defaultDataWeight = 4.0
    static let defaultEdgeWeight = 1.0
    static let defaultTemporalWeight = 0.5

    static func nearestUpsample(_ source: ASHImage, scale: Int = defaultScale) throws -> ASHImage {
        guard scale > 0 else { throw ASHCoreError.invalidScale(scale) }

        let outputWidth = source.width * scale
        let outputHeight = source.height * scale
        var output = Array(repeating: 0.0, count: outputWidth * outputHeight * source.channels)

        for row in 0..<outputHeight {
            for column in 0..<outputWidth {
                let sourceRow = row / scale
                let sourceColumn = column / scale
                for channel in 0..<source.channels {
                    output[index(row: row, column: column, channel: channel, width: outputWidth, channels: source.channels)] =
                        source.value(row: sourceRow, column: sourceColumn, channel: channel)
                }
            }
        }

        return try ASHImage(width: outputWidth, height: outputHeight, channels: source.channels, values: output)
    }

    static func blockMeanDownsample(_ candidate: ASHImage, scale: Int = defaultScale) throws -> ASHImage {
        guard scale > 0 else { throw ASHCoreError.invalidScale(scale) }
        guard candidate.width % scale == 0, candidate.height % scale == 0 else {
            throw ASHCoreError.invalidCandidateShape
        }

        let outputWidth = candidate.width / scale
        let outputHeight = candidate.height / scale
        var output = Array(repeating: 0.0, count: outputWidth * outputHeight * candidate.channels)

        for row in 0..<outputHeight {
            for column in 0..<outputWidth {
                for channel in 0..<candidate.channels {
                    var total = 0.0
                    for rowOffset in 0..<scale {
                        for columnOffset in 0..<scale {
                            total += candidate.value(
                                row: (row * scale) + rowOffset,
                                column: (column * scale) + columnOffset,
                                channel: channel
                            )
                        }
                    }
                    output[index(row: row, column: column, channel: channel, width: outputWidth, channels: candidate.channels)] =
                        total / Double(scale * scale)
                }
            }
        }

        return try ASHImage(width: outputWidth, height: outputHeight, channels: candidate.channels, values: output)
    }

    static func applyOperator(
        source: ASHImage,
        message: ASHMessage,
        scale: Int = defaultScale,
        strength: Double = defaultOperatorStrength
    ) throws -> ASHImage {
        guard scale > 0 else { throw ASHCoreError.invalidScale(scale) }
        let basis = try makeOperatorBasis(source: source, scale: scale)
        return try applyOperator(basis: basis, message: message, strength: strength)
    }

    static func sourceConsistencyScore(
        source: ASHImage,
        candidate: ASHImage,
        scale: Int = defaultScale,
        previousCandidate: ASHImage? = nil,
        dataWeight: Double = defaultDataWeight,
        edgeWeight: Double = defaultEdgeWeight,
        temporalWeight: Double = defaultTemporalWeight
    ) throws -> Double {
        let reduced = try blockMeanDownsample(candidate, scale: scale)
        guard reduced.width == source.width, reduced.height == source.height, reduced.channels == source.channels else {
            throw ASHCoreError.invalidCandidateShape
        }

        let dataLoss = mean(zip(reduced.values, source.values).map { pow($0 - $1, 2.0) })
        let sourceGradients = gradientEnergy(source)
        let reducedGradients = gradientEnergy(reduced)
        let edgeLoss = mean(zip(zip(sourceGradients.dx, reducedGradients.dx), zip(sourceGradients.dy, reducedGradients.dy)).map { pair in
            let dxPair = pair.0
            let dyPair = pair.1
            return pow(dxPair.0 - dxPair.1, 2.0) + pow(dyPair.0 - dyPair.1, 2.0)
        }) / 2.0

        let temporalLoss: Double
        if let previousCandidate {
            guard previousCandidate.width == candidate.width,
                  previousCandidate.height == candidate.height,
                  previousCandidate.channels == candidate.channels else {
                throw ASHCoreError.invalidCandidateShape
            }
            temporalLoss = mean(zip(candidate.values, previousCandidate.values).map { pow($0 - $1, 2.0) })
        } else {
            temporalLoss = 0.0
        }

        let loss = (dataWeight * dataLoss) + (edgeWeight * edgeLoss) + (temporalWeight * temporalLoss)
        return exp(-loss)
    }

    static func generateCandidates(
        source: ASHImage,
        leaves: [ASHBranchNode],
        sourceState: ASHState,
        scale: Int = defaultScale,
        previousCandidate: ASHImage? = nil,
        features: ASHFeatureVector? = nil,
        scoringPolicy: ASHScoringPolicy = .referenceV1,
        telemetry: any ASHTelemetryRecording = ASHNoopTelemetryRecorder.shared
    ) throws -> [ASHReconstructionCandidate] {
        guard !leaves.isEmpty else { throw ASHCoreError.missingBranchLeaves }
        guard scoringPolicy == .referenceV1 || features != nil else {
            throw ASHReconstructionError.missingAdaptiveFeatures
        }
        let priors = try telemetry.measure(.dispatchDecode) {
            try decodedLeafWeights(
                leaves: leaves,
                sourceState: sourceState,
                telemetry: telemetry
            )
        }
        telemetry.recordCandidateCount(priors.count)
        return try telemetry.measure(.reconstructLuma) {
            let basis = try makeOperatorBasis(source: source, scale: scale)
            var candidates: [ASHReconstructionCandidate] = []
            for message in priors.keys.sorted() {
                try Task.checkCancellation()
                candidates.append(try makeCandidate(
                    source: source,
                    basis: basis,
                    message: message,
                    priorWeight: priors[message] ?? 0.0,
                    scale: scale,
                    previousCandidate: previousCandidate,
                    features: features,
                    scoringPolicy: scoringPolicy
                ))
            }
            return candidates.sorted { isPreferred($0, $1) }
        }
    }

    /// Scores the complete decoded message set while retaining only top-k
    /// reconstructions. The result is identical to `generateCandidates` plus
    /// `prune`, but peak candidate-image retention is bounded by top-k.
    static func generateTopCandidates(
        source: ASHImage,
        leaves: [ASHBranchNode],
        sourceState: ASHState,
        scale: Int = defaultScale,
        previousCandidate: ASHImage? = nil,
        topK: Int = defaultTopK,
        features: ASHFeatureVector? = nil,
        scoringPolicy: ASHScoringPolicy = .referenceV1,
        telemetry: any ASHTelemetryRecording = ASHNoopTelemetryRecorder.shared
    ) throws -> (selected: [ASHReconstructionCandidate], evaluatedCount: Int) {
        guard !leaves.isEmpty else { throw ASHCoreError.missingBranchLeaves }
        guard topK > 0 else { throw ASHCoreError.invalidTopK(topK) }
        guard scoringPolicy == .referenceV1 || features != nil else {
            throw ASHReconstructionError.missingAdaptiveFeatures
        }

        let priors = try telemetry.measure(.dispatchDecode) {
            try decodedLeafWeights(
                leaves: leaves,
                sourceState: sourceState,
                telemetry: telemetry
            )
        }
        telemetry.recordCandidateCount(priors.count)
        return try telemetry.measure(.reconstructLuma) {
            let basis = try makeOperatorBasis(source: source, scale: scale)
            var selected: [ASHReconstructionCandidate] = []
            selected.reserveCapacity(min(topK, priors.count))

            for message in priors.keys.sorted() {
                try Task.checkCancellation()
                selected.append(try makeCandidate(
                    source: source,
                    basis: basis,
                    message: message,
                    priorWeight: priors[message] ?? 0.0,
                    scale: scale,
                    previousCandidate: previousCandidate,
                    features: features,
                    scoringPolicy: scoringPolicy
                ))
                selected.sort { isPreferred($0, $1) }
                if selected.count > topK {
                    selected.removeLast()
                }
            }
            return (selected, priors.count)
        }
    }

    static func prune(_ candidates: [ASHReconstructionCandidate], topK: Int = defaultTopK) throws -> [ASHReconstructionCandidate] {
        guard topK > 0 else { throw ASHCoreError.invalidTopK(topK) }
        return Array(candidates.sorted { isPreferred($0, $1) }.prefix(topK))
    }

    private static func decodedLeafWeights(
        leaves: [ASHBranchNode],
        sourceState: ASHState,
        telemetry: any ASHTelemetryRecording
    ) throws -> [ASHMessage: Double] {
        guard sourceState.hasValidIntegrity else {
            throw ASHReconstructionError.invalidAffineAnchor
        }
        var priors: [ASHMessage: Double] = [:]
        for leaf in ASHBranchTree.leafNodes(leaves) {
            let decoded = ASHBranchTree.recover(received: leaf.state, sourceState: sourceState)
            telemetry.recordDecode(decoded.status)
            guard decoded.status != .uncorrectable,
                  let messageBits = decoded.messageBits else {
                throw ASHReconstructionError.uncorrectableBranchState(leaf.path)
            }
            let decodedMessage = try ASHMessage(bits: messageBits)
            priors[decodedMessage, default: 0.0] += leaf.weight
        }
        guard !priors.isEmpty else { throw ASHCoreError.missingBranchLeaves }
        return priors
    }

    private static func makeCandidate(
        source: ASHImage,
        basis: OperatorBasis,
        message: ASHMessage,
        priorWeight: Double,
        scale: Int,
        previousCandidate: ASHImage?,
        features: ASHFeatureVector?,
        scoringPolicy: ASHScoringPolicy
    ) throws -> ASHReconstructionCandidate {
        let reconstruction = try applyOperator(
            basis: basis,
            message: message,
            strength: defaultOperatorStrength
        )
        let sourceScore = try sourceConsistencyScore(
            source: source,
            candidate: reconstruction,
            scale: scale,
            previousCandidate: previousCandidate
        )
        let policyScore = policyAdjustment(
            features: features,
            message: message,
            policy: scoringPolicy
        )
        let totalScore = log(max(priorWeight, 1e-300))
            + log(max(sourceScore, 1e-300))
            + policyScore
        return ASHReconstructionCandidate(
            message: message,
            priorWeight: priorWeight,
            sourceScore: sourceScore,
            policyScore: policyScore,
            totalScore: totalScore,
            reconstruction: reconstruction
        )
    }

}
