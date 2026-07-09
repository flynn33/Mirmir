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

        let tree = try ASHBranchTree.generate(sourceState: try ASHState(rawValue: 0), depth: 4)
        let candidates = try ASHReconstruction.generateCandidates(source: source, leaves: ASHBranchTree.leafNodes(tree), scale: 2)
        let selected = try ASHReconstruction.prune(candidates, topK: 4)

        XCTAssertEqual(candidates.count, 16)
        XCTAssertEqual(selected, Array(candidates.prefix(4)))
        XCTAssertTrue(candidates.allSatisfy { $0.sourceScore > 0.0 && $0.sourceScore <= 1.0 })
    }
}
