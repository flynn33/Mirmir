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
