import Foundation

struct ASHReconstructionCandidate: Equatable, Sendable {
    let message: ASHMessage
    let priorWeight: Double
    let sourceScore: Double
    let totalScore: Double
    let reconstruction: ASHImage
}

struct ASHMappingResult: Equatable, Sendable {
    let features: ASHFeatureVector
    let sourceState: ASHState
    let branchNodes: [ASHBranchNode]
    let candidates: [ASHReconstructionCandidate]
    let selected: [ASHReconstructionCandidate]
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
        if source.channels == 1 {
            return try ASHLumaSpatialOperator.applyCPU(
                source: source,
                message: message,
                scale: scale,
                strength: strength
            )
        }

        let baseline = try nearestUpsample(source, scale: scale)
        let horizontalBlur = blurAxis(baseline, axis: 1)
        let verticalBlur = blurAxis(baseline, axis: 0)
        let isotropicBlur = blurAxis(try baseline.replacing(values: verticalBlur), axis: 1)

        var result = baseline.values
        for index in result.indices {
            let horizontalDetail = baseline.values[index] - horizontalBlur[index]
            let verticalDetail = baseline.values[index] - verticalBlur[index]
            let isotropicDetail = baseline.values[index] - isotropicBlur[index]
            if message.bits[0] == 1 {
                result[index] += strength * horizontalDetail
            }
            if message.bits[1] == 1 {
                result[index] += strength * verticalDetail
            }
            if message.bits[2] == 1 {
                result[index] += strength * isotropicDetail
            }
            if message.bits[3] == 1 {
                result[index] -= strength * isotropicDetail
            }
            result[index] = min(1.0, max(0.0, result[index]))
        }

        return try baseline.replacing(values: result)
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
        scale: Int = defaultScale,
        previousCandidate: ASHImage? = nil,
        features: ASHFeatureVector? = nil
    ) throws -> [ASHReconstructionCandidate] {
        guard !leaves.isEmpty else { throw ASHCoreError.missingBranchLeaves }

        let priors = ASHBranchTree.aggregateLeafWeights(leaves)
        var candidates: [ASHReconstructionCandidate] = []
        for message in priors.keys.sorted() {
            let reconstruction = try applyOperator(source: source, message: message, scale: scale)
            let sourceScore = try sourceConsistencyScore(
                source: source,
                candidate: reconstruction,
                scale: scale,
                previousCandidate: previousCandidate
            )
            let priorWeight = priors[message] ?? 0.0
            let totalScore = log(max(priorWeight, 1e-300))
                + log(max(sourceScore, 1e-300))
                + featurePreferenceScore(features: features, message: message)
            candidates.append(ASHReconstructionCandidate(
                message: message,
                priorWeight: priorWeight,
                sourceScore: sourceScore,
                totalScore: totalScore,
                reconstruction: reconstruction
            ))
        }
        return candidates.sorted { lhs, rhs in
            if lhs.totalScore != rhs.totalScore {
                return lhs.totalScore > rhs.totalScore
            }
            return lhs.message.rawValue < rhs.message.rawValue
        }
    }

    static func prune(_ candidates: [ASHReconstructionCandidate], topK: Int = defaultTopK) throws -> [ASHReconstructionCandidate] {
        guard topK > 0 else { throw ASHCoreError.invalidTopK(topK) }
        return Array(candidates.sorted { lhs, rhs in
            if lhs.totalScore != rhs.totalScore {
                return lhs.totalScore > rhs.totalScore
            }
            return lhs.message.rawValue < rhs.message.rawValue
        }.prefix(topK))
    }

    private static func featurePreferenceScore(features: ASHFeatureVector?, message: ASHMessage) -> Double {
        guard let features else { return 0.0 }
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
            score += message.bits[index] == 1 ? signal : max(0.0, 0.15 - signal)
        }
        return score * 4.5
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
        topK: Int = ASHReconstruction.defaultTopK
    ) throws -> ASHMappingResult {
        let features = try ASHFeatureExtractor.extract(
            current: current,
            previous: previous,
            chromaEnergy: chromaEnergy
        )
        let sourceState = try ASHFeatureBinarizer.binarize(features, previousState: previousState)
        let tree = try ASHBranchTree.generate(sourceState: sourceState, depth: branchDepth)
        let candidates = try ASHReconstruction.generateCandidates(
            source: current,
            leaves: ASHBranchTree.leafNodes(tree),
            scale: scale,
            previousCandidate: previousReconstruction,
            features: features
        )
        let selected = try ASHReconstruction.prune(candidates, topK: topK)
        return ASHMappingResult(
            features: features,
            sourceState: sourceState,
            branchNodes: tree,
            candidates: candidates,
            selected: selected
        )
    }
}
