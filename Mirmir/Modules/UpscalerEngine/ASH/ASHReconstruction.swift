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

/// Version identifiers for every policy that can affect a reconstructed pixel.
///
/// ASH's mapping and project versions match `ash_mapping_v1.json`. Canonical
/// ASH scoring and Mirmir's adaptive scoring are identified separately.
/// Scene-cut detection is likewise a versioned Mirmir runtime policy.
struct ASHRuntimeProvenance: Equatable, Sendable {
    static let referenceV1 = ASHRuntimeProvenance(
        mappingSchemaVersion: "1.0.0",
        ashProjectVersion: "1.1.0",
        ashSourceRevision: "8782886a8cca9fa63f7d44b529add6eac80a50f8",
        mappingArtifactSHA256: "aef24e8eba2441025e1e440e2791215d32d163e0b7b91d25bb7e9b7018260c79",
        operatorSpecificationVersion: "ash-reference-operator-v1",
        scoringSpecificationVersion: ASHScoringPolicy.referenceV1.specificationVersion,
        historyPolicyVersion: "mirmir-tile-history-v1",
        coordinateConvention: "coordinate_1_is_most_significant"
    )
    static let mirmirAdaptiveV1 = ASHRuntimeProvenance(
        mappingSchemaVersion: "1.0.0",
        ashProjectVersion: "1.1.0",
        ashSourceRevision: "8782886a8cca9fa63f7d44b529add6eac80a50f8",
        mappingArtifactSHA256: "aef24e8eba2441025e1e440e2791215d32d163e0b7b91d25bb7e9b7018260c79",
        operatorSpecificationVersion: "ash-reference-operator-v1",
        scoringSpecificationVersion: ASHScoringPolicy.mirmirAdaptiveV1.specificationVersion,
        historyPolicyVersion: "mirmir-tile-history-v1",
        coordinateConvention: "coordinate_1_is_most_significant"
    )
    static let current = mirmirAdaptiveV1

    let mappingSchemaVersion: String
    let ashProjectVersion: String
    let ashSourceRevision: String
    let mappingArtifactSHA256: String
    let operatorSpecificationVersion: String
    let scoringSpecificationVersion: String
    let historyPolicyVersion: String
    let coordinateConvention: String

    var outputMetadata: [String: String] {
        [
            "com.mirmir.ash.mapping-schema": mappingSchemaVersion,
            "com.mirmir.ash.project-version": ashProjectVersion,
            "com.mirmir.ash.source-revision": ashSourceRevision,
            "com.mirmir.ash.mapping-sha256": mappingArtifactSHA256,
            "com.mirmir.ash.operator-specification": operatorSpecificationVersion,
            "com.mirmir.ash.scoring-specification": scoringSpecificationVersion,
            "com.mirmir.ash.history-policy": historyPolicyVersion,
            "com.mirmir.ash.coordinate-convention": coordinateConvention
        ]
    }
}

struct ASHRuntimeConfiguration: Equatable, Sendable {
    static let referenceV1 = ASHRuntimeConfiguration(
        provenance: .referenceV1,
        scoringPolicy: .referenceV1,
        sceneCutMeanAbsoluteLumaThreshold: 0.35
    )
    static let current = ASHRuntimeConfiguration(
        provenance: .mirmirAdaptiveV1,
        scoringPolicy: .mirmirAdaptiveV1,
        sceneCutMeanAbsoluteLumaThreshold: 0.35
    )

    let provenance: ASHRuntimeProvenance
    let scoringPolicy: ASHScoringPolicy
    let sceneCutMeanAbsoluteLumaThreshold: Double

    var outputMetadata: [String: String] {
        var metadata = provenance.outputMetadata.merging([
            "com.mirmir.ash.scene-cut-metric": "mean-absolute-luma-difference",
            "com.mirmir.ash.scene-cut-threshold": String(sceneCutMeanAbsoluteLumaThreshold)
        ]) { _, current in current }
        if scoringPolicy == .mirmirAdaptiveV1 {
            metadata["com.mirmir.ash.adaptive-feature-prior-weight"] = String(ASHScoringPolicy.adaptiveFeaturePriorWeight)
            metadata["com.mirmir.ash.adaptive-inactive-floor"] = String(ASHScoringPolicy.adaptiveInactiveFloor)
        }
        return metadata
    }
}

enum ASHReconstruction {
    static let defaultScale = 2
    static let defaultTopK = 4
    static let defaultOperatorStrength = 0.125
    static let defaultDataWeight = 4.0
    static let defaultEdgeWeight = 1.0
    static let defaultTemporalWeight = 0.5

    private struct OperatorBasis {
        let baseline: ASHImage
        let horizontalDetail: [Double]
        let verticalDetail: [Double]
        let isotropicDetail: [Double]
    }

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

    private static func makeOperatorBasis(source: ASHImage, scale: Int) throws -> OperatorBasis {
        let baseline = try nearestUpsample(source, scale: scale)
        let horizontalBlur = blurAxis(baseline, axis: 1)
        let verticalBlur = blurAxis(baseline, axis: 0)
        let isotropicBlur = blurAxis(try baseline.replacing(values: verticalBlur), axis: 1)
        return OperatorBasis(
            baseline: baseline,
            horizontalDetail: zip(baseline.values, horizontalBlur).map { baselineValue, blurValue in
                baselineValue - blurValue
            },
            verticalDetail: zip(baseline.values, verticalBlur).map { baselineValue, blurValue in
                baselineValue - blurValue
            },
            isotropicDetail: zip(baseline.values, isotropicBlur).map { baselineValue, blurValue in
                baselineValue - blurValue
            }
        )
    }

    private static func applyOperator(
        basis: OperatorBasis,
        message: ASHMessage,
        strength: Double
    ) throws -> ASHImage {
        var result = basis.baseline.values
        for index in result.indices {
            if index.isMultiple(of: 4_096) {
                try Task.checkCancellation()
            }
            if message.bits[0] == 1 {
                result[index] += strength * basis.horizontalDetail[index]
            }
            if message.bits[1] == 1 {
                result[index] += strength * basis.verticalDetail[index]
            }
            if message.bits[2] == 1 {
                result[index] += strength * basis.isotropicDetail[index]
            }
            if message.bits[3] == 1 {
                result[index] -= strength * basis.isotropicDetail[index]
            }
            result[index] = min(1.0, max(0.0, result[index]))
        }
        return try basis.baseline.replacing(values: result)
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
        scoringPolicy: ASHScoringPolicy = .referenceV1
    ) throws -> [ASHReconstructionCandidate] {
        guard !leaves.isEmpty else { throw ASHCoreError.missingBranchLeaves }
        guard scoringPolicy == .referenceV1 || features != nil else {
            throw ASHReconstructionError.missingAdaptiveFeatures
        }
        let priors = try decodedLeafWeights(leaves: leaves, sourceState: sourceState)
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
        scoringPolicy: ASHScoringPolicy = .referenceV1
    ) throws -> (selected: [ASHReconstructionCandidate], evaluatedCount: Int) {
        guard !leaves.isEmpty else { throw ASHCoreError.missingBranchLeaves }
        guard topK > 0 else { throw ASHCoreError.invalidTopK(topK) }
        guard scoringPolicy == .referenceV1 || features != nil else {
            throw ASHReconstructionError.missingAdaptiveFeatures
        }

        let priors = try decodedLeafWeights(leaves: leaves, sourceState: sourceState)
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

    static func prune(_ candidates: [ASHReconstructionCandidate], topK: Int = defaultTopK) throws -> [ASHReconstructionCandidate] {
        guard topK > 0 else { throw ASHCoreError.invalidTopK(topK) }
        return Array(candidates.sorted { isPreferred($0, $1) }.prefix(topK))
    }

    private static func decodedLeafWeights(
        leaves: [ASHBranchNode],
        sourceState: ASHState
    ) throws -> [ASHMessage: Double] {
        guard sourceState.hasValidIntegrity else {
            throw ASHReconstructionError.invalidAffineAnchor
        }
        var priors: [ASHMessage: Double] = [:]
        for leaf in ASHBranchTree.leafNodes(leaves) {
            let decoded = ASHBranchTree.recover(received: leaf.state, sourceState: sourceState)
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

    private static func policyAdjustment(
        features: ASHFeatureVector?,
        message: ASHMessage,
        policy: ASHScoringPolicy
    ) -> Double {
        guard policy == .mirmirAdaptiveV1, let features else { return 0.0 }
        let values = features.values
        let signals = [
            values[5],
            values[6],
            max(values[2], values[3], values[4]),
            max(values[0], values[1], values[4], values[7])
        ]
        var score = 0.0
        for index in 0..<ASHMessage.bitCount {
            let signal = signals[index]
            score += message.bits[index] == 1
                ? signal
                : max(0.0, ASHScoringPolicy.adaptiveInactiveFloor - signal)
        }
        return score * ASHScoringPolicy.adaptiveFeaturePriorWeight
    }

    private static func isPreferred(
        _ lhs: ASHReconstructionCandidate,
        _ rhs: ASHReconstructionCandidate
    ) -> Bool {
        if lhs.totalScore != rhs.totalScore {
            return lhs.totalScore > rhs.totalScore
        }
        return lhs.message.rawValue < rhs.message.rawValue
    }

    private static func blurAxis(_ image: ASHImage, axis: Int) -> [Double] {
        var output = Array(repeating: 0.0, count: image.values.count)

        for row in 0..<image.height {
            for column in 0..<image.width {
                for channel in 0..<image.channels {
                    let previousRow = axis == 0 ? max(row - 1, 0) : row
                    let nextRow = axis == 0 ? min(row + 1, image.height - 1) : row
                    let previousColumn = axis == 1 ? max(column - 1, 0) : column
                    let nextColumn = axis == 1 ? min(column + 1, image.width - 1) : column
                    let center = image.value(row: row, column: column, channel: channel)
                    let before = image.value(row: previousRow, column: previousColumn, channel: channel)
                    let after = image.value(row: nextRow, column: nextColumn, channel: channel)
                    output[index(row: row, column: column, channel: channel, width: image.width, channels: image.channels)] =
                        (before + (2.0 * center) + after) / 4.0
                }
            }
        }

        return output
    }

    private static func gradientEnergy(_ image: ASHImage) -> (dx: [Double], dy: [Double]) {
        var dx = Array(repeating: 0.0, count: image.values.count)
        var dy = Array(repeating: 0.0, count: image.values.count)

        if image.width > 1 {
            for row in 0..<image.height {
                for column in 0..<(image.width - 1) {
                    for channel in 0..<image.channels {
                        let current = index(row: row, column: column, channel: channel, width: image.width, channels: image.channels)
                        let next = index(row: row, column: column + 1, channel: channel, width: image.width, channels: image.channels)
                        dx[current] = image.values[next] - image.values[current]
                    }
                }
            }
        }

        if image.height > 1 {
            for row in 0..<(image.height - 1) {
                for column in 0..<image.width {
                    for channel in 0..<image.channels {
                        let current = index(row: row, column: column, channel: channel, width: image.width, channels: image.channels)
                        let next = index(row: row + 1, column: column, channel: channel, width: image.width, channels: image.channels)
                        dy[current] = image.values[next] - image.values[current]
                    }
                }
            }
        }

        return (dx, dy)
    }

    private static func mean(_ values: [Double]) -> Double {
        values.reduce(0.0, +) / Double(values.count)
    }

    private static func index(row: Int, column: Int, channel: Int, width: Int, channels: Int) -> Int {
        ((row * width) + column) * channels + channel
    }
}

enum ASHReferencePipeline {
    static func mapPatch(
        current: ASHImage,
        previous: ASHImage? = nil,
        previousState: ASHState? = nil,
        previousReconstruction: ASHImage? = nil,
        chromaEnergy: Double? = nil,
        branchDepth: Int = ASHBranchTree.defaultDepth,
        scale: Int = ASHReconstruction.defaultScale,
        topK: Int = ASHReconstruction.defaultTopK,
        candidateRetention: ASHCandidateRetention = .all,
        scoringPolicy: ASHScoringPolicy = .referenceV1
    ) throws -> ASHMappingResult {
        let previousStateIsInvalid = previousState.map { !$0.hasValidIntegrity } ?? false
        let effectivePrevious = previousStateIsInvalid ? nil : previous
        let effectivePreviousState = previousStateIsInvalid ? nil : previousState
        let effectivePreviousReconstruction = previousStateIsInvalid ? nil : previousReconstruction
        let features = try ASHFeatureExtractor.extract(
            current: current,
            previous: effectivePrevious,
            chromaEnergy: chromaEnergy
        )
        let sourceState = try ASHFeatureBinarizer.binarize(features, previousState: effectivePreviousState)
        let tree = try ASHBranchTree.generate(sourceState: sourceState, depth: branchDepth)
        let leaves = ASHBranchTree.leafNodes(tree)
        let candidates: [ASHReconstructionCandidate]
        let selected: [ASHReconstructionCandidate]
        let evaluatedCandidateCount: Int
        switch candidateRetention {
        case .all:
            candidates = try ASHReconstruction.generateCandidates(
                source: current,
                leaves: leaves,
                sourceState: sourceState,
                scale: scale,
                previousCandidate: effectivePreviousReconstruction,
                features: features,
                scoringPolicy: scoringPolicy
            )
            selected = try ASHReconstruction.prune(candidates, topK: topK)
            evaluatedCandidateCount = candidates.count
        case .selectedOnly:
            let result = try ASHReconstruction.generateTopCandidates(
                source: current,
                leaves: leaves,
                sourceState: sourceState,
                scale: scale,
                previousCandidate: effectivePreviousReconstruction,
                topK: topK,
                features: features,
                scoringPolicy: scoringPolicy
            )
            candidates = result.selected
            selected = result.selected
            evaluatedCandidateCount = result.evaluatedCount
        }
        return ASHMappingResult(
            features: features,
            sourceState: sourceState,
            branchNodes: tree,
            candidates: candidates,
            selected: selected,
            evaluatedCandidateCount: evaluatedCandidateCount,
            provenance: scoringPolicy == .referenceV1 ? .referenceV1 : .mirmirAdaptiveV1
        )
    }
}
