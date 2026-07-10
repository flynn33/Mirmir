import Foundation
import XCTest
@testable import Mirmir

final class ASHFeatureBranchReconstructionTests: XCTestCase {

    func test_blackAndWhitePatchesHaveExpectedLuminanceFeatures() throws {
        let black = try ASHImage(grayscaleRows: Array(repeating: Array(repeating: 0.0, count: 3), count: 3))
        let white = try ASHImage(grayscaleRows: Array(repeating: Array(repeating: 1.0, count: 3), count: 3))

        let blackFeatures = try ASHFeatureExtractor.extract(current: black)
        let whiteFeatures = try ASHFeatureExtractor.extract(current: white)

        XCTAssertEqual(blackFeatures.values, Array(repeating: 0.0, count: 8))
        XCTAssertEqual(whiteFeatures.values[0], 1.0)
        XCTAssertEqual(Array(whiteFeatures.values.dropFirst()), Array(repeating: 0.0, count: 7))
    }

    func test_featureBinarizationUsesTieRuleHysteresisAndParity() throws {
        let thresholdFeatures = try ASHFeatureVector(values: ASHFeatureBinarizer.defaultThresholds)
        let thresholdState = try ASHFeatureBinarizer.binarize(thresholdFeatures)
        XCTAssertEqual(Array(thresholdState.bits.prefix(8)), Array(repeating: 1, count: 8))
        XCTAssertEqual(thresholdState.bit(coordinate: 9), 0)

        let zeroPrevious = try ASHState(rawValue: 0)
        let heldZero = try ASHFeatureBinarizer.binarize(thresholdFeatures, previousState: zeroPrevious)
        XCTAssertEqual(Array(heldZero.bits.prefix(8)), Array(repeating: 0, count: 8))

        let onValues = zip(ASHFeatureBinarizer.defaultThresholds, ASHFeatureBinarizer.defaultHysteresis)
            .map { min(1.0, $0 + $1) }
        let switchedOn = try ASHFeatureBinarizer.binarize(try ASHFeatureVector(values: onValues), previousState: zeroPrevious)
        XCTAssertEqual(Array(switchedOn.bits.prefix(8)), Array(repeating: 1, count: 8))
        XCTAssertTrue(switchedOn.hasValidIntegrity)
    }

    func test_branchTreeCountsWeightsAndStateSemantics() throws {
        let source = try ASHState(bits: [1, 0, 1, 0, 1, 0, 1, 0, 0])
        let tree = try ASHBranchTree.generate(sourceState: source, depth: 4)
        let leaves = ASHBranchTree.leafNodes(tree)
        let aggregate = ASHBranchTree.aggregateLeafWeights(tree)

        XCTAssertEqual(tree.count, 121)
        XCTAssertEqual(leaves.count, 81)
        XCTAssertEqual(aggregate.count, 16)
        XCTAssertEqual(leaves.reduce(0.0) { $0 + $1.weight }, 1.0, accuracy: 1e-12)
        XCTAssertTrue(leaves.allSatisfy { $0.state.hasValidIntegrity })
        XCTAssertTrue(leaves.allSatisfy { $0.state.bit(coordinate: 8) == source.bit(coordinate: 8) })
    }

    func test_reconstructionBaselineAndCandidatePruningAreDeterministic() throws {
        let source = try ASHImage(grayscaleRows: [
            [0.0, 0.25],
            [0.75, 1.0]
        ])

        let baseline = try ASHReconstruction.nearestUpsample(source, scale: 2)
        XCTAssertEqual(baseline.width, 4)
        XCTAssertEqual(baseline.height, 4)
        XCTAssertEqual(try ASHReconstruction.blockMeanDownsample(baseline, scale: 2), source)
        XCTAssertEqual(try ASHReconstruction.sourceConsistencyScore(source: source, candidate: baseline, scale: 2), 1.0)

        let sourceState = try ASHState(rawValue: 0)
        let tree = try ASHBranchTree.generate(sourceState: sourceState, depth: 4)
        let candidates = try ASHReconstruction.generateCandidates(
            source: source,
            leaves: ASHBranchTree.leafNodes(tree),
            sourceState: sourceState,
            scale: 2
        )
        let selected = try ASHReconstruction.prune(candidates, topK: 4)

        XCTAssertEqual(candidates.count, 16)
        XCTAssertEqual(selected, Array(candidates.prefix(4)))
        XCTAssertTrue(candidates.allSatisfy { $0.sourceScore > 0.0 && $0.sourceScore <= 1.0 })
    }

    func test_affineLeafStatesAreDecodedBeforeOperatorsAreChosen() throws {
        let source = try ASHImage(grayscaleRows: [
            [0.0, 0.25],
            [0.75, 1.0]
        ])
        let sourceState = try ASHState(rawValue: 0)
        let leaves = ASHBranchTree.leafNodes(
            try ASHBranchTree.generate(sourceState: sourceState, depth: 4)
        )
        let deliberatelyWrongMessage = try ASHMessage(rawValue: 0)
        let deliberatelyWrongCodeword = ASHCode.encode(deliberatelyWrongMessage)
        let metadataCorruptedLeaves = leaves.map { node in
            replacing(
                node,
                message: deliberatelyWrongMessage,
                codeword: deliberatelyWrongCodeword,
                state: node.state
            )
        }

        let candidates = try ASHReconstruction.generateCandidates(
            source: source,
            leaves: metadataCorruptedLeaves,
            sourceState: sourceState,
            scale: 2
        )

        XCTAssertEqual(candidates.count, 16)
        XCTAssertEqual(Set(candidates.map { Int($0.message.rawValue) }), Set(0..<16))
    }

    func test_affineDecoderCorrectsOneBitAndRejectsTwoBitBranchDamage() throws {
        let source = try ASHImage(grayscaleRows: [
            [0.0, 0.25],
            [0.75, 1.0]
        ])
        let sourceState = try ASHState(rawValue: 0)
        let leaves = ASHBranchTree.leafNodes(
            try ASHBranchTree.generate(sourceState: sourceState, depth: 4)
        )
        let reference = try ASHReconstruction.generateCandidates(
            source: source,
            leaves: leaves,
            sourceState: sourceState,
            scale: 2
        )

        var oneBitLeaves = leaves
        let oneBitLeaf = oneBitLeaves[4]
        oneBitLeaves[4] = replacing(
            oneBitLeaf,
            state: oneBitLeaf.state.toggled(coordinate: 3)
        )
        let corrected = try ASHReconstruction.generateCandidates(
            source: source,
            leaves: oneBitLeaves,
            sourceState: sourceState,
            scale: 2
        )
        XCTAssertEqual(corrected, reference)

        var twoBitLeaves = leaves
        let twoBitLeaf = twoBitLeaves[4]
        twoBitLeaves[4] = replacing(
            twoBitLeaf,
            state: twoBitLeaf.state.toggled(coordinate: 2).toggled(coordinate: 7)
        )
        XCTAssertThrowsError(try ASHReconstruction.generateCandidates(
            source: source,
            leaves: twoBitLeaves,
            sourceState: sourceState,
            scale: 2
        )) { error in
            XCTAssertEqual(
                error as? ASHReconstructionError,
                .uncorrectableBranchState(twoBitLeaf.path)
            )
        }
    }

    func test_scoringMatchesASHModelGoldenVectorWithoutFeaturePrior() throws {
        let ramp = try ASHImage(grayscaleRows: [
            [0.0, 0.25],
            [0.75, 1.0]
        ])
        let mapping = try ASHReferencePipeline.mapPatch(
            current: ramp,
            branchDepth: 4,
            scale: 2,
            topK: 4
        )

        XCTAssertEqual(mapping.sourceState.description, "111101100")
        XCTAssertEqual(mapping.provenance, .referenceV1)
        XCTAssertEqual(mapping.selected.map { $0.message.rawValue }, [UInt8(0), 8, 2, 4])
        XCTAssertEqual(mapping.selected[0].totalScore, -2.018816919863401, accuracy: 1e-12)
        XCTAssertEqual(mapping.selected[1].totalScore, -2.3671617611042732, accuracy: 1e-12)
        XCTAssertEqual(mapping.selected[2].totalScore, -2.367276202022242, accuracy: 1e-12)
        XCTAssertEqual(mapping.selected[3].totalScore, -2.3674669368855232, accuracy: 1e-12)
        for candidate in mapping.candidates {
            XCTAssertEqual(candidate.policyScore, 0.0, accuracy: 0.0)
            XCTAssertEqual(
                candidate.totalScore,
                log(max(candidate.priorWeight, 1e-300)) + log(max(candidate.sourceScore, 1e-300)),
                accuracy: 1e-14
            )
        }
    }

    func test_boundedCandidateRetentionMatchesFullSelectionForBothScoringPolicies() throws {
        let source = try ASHImage(grayscaleRows: [
            [0.0, 1.0, 0.0, 1.0],
            [1.0, 0.0, 1.0, 0.0],
            [0.0, 1.0, 0.0, 1.0],
            [1.0, 0.0, 1.0, 0.0]
        ])
        for policy in [ASHScoringPolicy.referenceV1, .mirmirAdaptiveV1] {
            let full = try ASHReferencePipeline.mapPatch(
                current: source,
                topK: 4,
                candidateRetention: .all,
                scoringPolicy: policy
            )
            let bounded = try ASHReferencePipeline.mapPatch(
                current: source,
                topK: 4,
                candidateRetention: .selectedOnly,
                scoringPolicy: policy
            )

            XCTAssertEqual(full.evaluatedCandidateCount, 16)
            XCTAssertEqual(full.candidates.count, 16)
            XCTAssertEqual(bounded.evaluatedCandidateCount, 16)
            XCTAssertEqual(bounded.candidates.count, 4)
            XCTAssertEqual(bounded.selected, full.selected)
        }
    }

    func test_sceneCutAndInvalidStateResetTileHistory() throws {
        let black = try ASHImage(
            grayscaleRows: Array(repeating: Array(repeating: 0.0, count: 4), count: 4)
        )
        let nearBlack = try ASHImage(
            grayscaleRows: Array(repeating: Array(repeating: 0.1, count: 4), count: 4)
        )
        let white = try ASHImage(
            grayscaleRows: Array(repeating: Array(repeating: 1.0, count: 4), count: 4)
        )
        let processor = ASHTileProcessor(tileSize: 4, scale: 2, topK: 1)

        let first = try processor.process(luma: black)
        XCTAssertEqual(first.decisions.first?.historyResetReason, .noPriorFrame)

        let continuous = try processor.process(luma: nearBlack, previous: first.temporalState)
        XCTAssertNil(continuous.decisions.first?.historyResetReason)
        XCTAssertEqual(continuous.decisions.first?.features.values[7] ?? -1.0, 0.1, accuracy: 1e-12)

        let sceneCut = try processor.process(luma: white, previous: first.temporalState)
        XCTAssertEqual(sceneCut.decisions.first?.historyResetReason, .sceneCut)
        XCTAssertEqual(sceneCut.decisions.first?.features.values[7] ?? -1.0, 0.0, accuracy: 1e-12)
        XCTAssertEqual(sceneCut.summary.sceneCutResetCount, 1)

        var invalidStates = first.temporalState.sourceStates
        invalidStates[0] = try ASHState(rawValue: 1)
        let invalidHistory = ASHTileTemporalState(
            sourceTiles: first.temporalState.sourceTiles,
            sourceStates: invalidStates,
            reconstructions: first.temporalState.reconstructions
        )
        let invalidReset = try processor.process(luma: black, previous: invalidHistory)
        XCTAssertEqual(invalidReset.decisions.first?.historyResetReason, .invalidPriorState)
        XCTAssertEqual(invalidReset.decisions.first?.features.values[7] ?? -1.0, 0.0, accuracy: 1e-12)

        let directReset = try ASHReferencePipeline.mapPatch(
            current: nearBlack,
            previous: black,
            previousState: try ASHState(rawValue: 1),
            previousReconstruction: first.reconstruction,
            topK: 1
        )
        XCTAssertEqual(directReset.features.values[7], 0.0, accuracy: 1e-12)
    }

    func test_tileProcessorPublishesVersionedConfigurationAndBoundedCost() throws {
        let source = try ASHImage(
            grayscaleRows: Array(repeating: Array(repeating: 0.25, count: 4), count: 4)
        )
        let result = try ASHTileProcessor(tileSize: 4, scale: 2, topK: 1).process(luma: source)
        let metadata = result.summary.configuration.outputMetadata

        XCTAssertEqual(result.summary.maxCandidatesPerTile, 16)
        XCTAssertEqual(result.summary.configuration.provenance, .mirmirAdaptiveV1)
        XCTAssertEqual(metadata["com.mirmir.ash.mapping-schema"], "1.0.0")
        XCTAssertEqual(metadata["com.mirmir.ash.source-revision"], "8782886a8cca9fa63f7d44b529add6eac80a50f8")
        XCTAssertEqual(metadata["com.mirmir.ash.mapping-sha256"], "aef24e8eba2441025e1e440e2791215d32d163e0b7b91d25bb7e9b7018260c79")
        XCTAssertEqual(metadata["com.mirmir.ash.operator-specification"], "ash-reference-operator-v1")
        XCTAssertEqual(metadata["com.mirmir.ash.scoring-specification"], "mirmir-adaptive-score-v1")
        XCTAssertEqual(metadata["com.mirmir.ash.history-policy"], "mirmir-tile-history-v1")
        XCTAssertEqual(metadata["com.mirmir.ash.scene-cut-threshold"], "0.35")
        XCTAssertEqual(metadata["com.mirmir.ash.adaptive-feature-prior-weight"], "4.5")
        XCTAssertEqual(metadata["com.mirmir.ash.adaptive-inactive-floor"], "0.15")
        let previousCandidateEstimate = 16 * result.reconstruction.values.count * MemoryLayout<Double>.stride
        XCTAssertLessThan(result.summary.estimatedPeakTemporaryBytes, previousCandidateEstimate)
    }

    private func replacing(
        _ node: ASHBranchNode,
        message: ASHMessage? = nil,
        codeword: ASHState? = nil,
        state: ASHState? = nil
    ) -> ASHBranchNode {
        ASHBranchNode(
            path: node.path,
            parentPath: node.parentPath,
            depth: node.depth,
            action: node.action,
            message: message ?? node.message,
            codeword: codeword ?? node.codeword,
            state: state ?? node.state,
            weight: node.weight
        )
    }
}
