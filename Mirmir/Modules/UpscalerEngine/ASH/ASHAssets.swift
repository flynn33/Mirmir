import Foundation

struct ASHAssetCatalog: Sendable {
    var mapping: ASHMappingAsset
    var codewords: [ASHCodewordAssetRow]
    var stateReference: [ASHStateReferenceAssetRow]
    var branchTopology: ASHBranchTopologyAsset
    var certificate: ASHComputationalCertificateAsset

    static func load(from resourceRoot: URL) throws -> ASHAssetCatalog {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        return try ASHAssetCatalog(
            mapping: decoder.decode(
                ASHMappingAsset.self,
                from: Data(contentsOf: resourceRoot.appendingPathComponent("ash_mapping_v1.json"))
            ),
            codewords: parseCodewords(
                Data(contentsOf: resourceRoot.appendingPathComponent("codewords.csv"))
            ),
            stateReference: parseStateReference(
                Data(contentsOf: resourceRoot.appendingPathComponent("ash-state-reference.csv"))
            ),
            branchTopology: decoder.decode(
                ASHBranchTopologyAsset.self,
                from: Data(contentsOf: resourceRoot.appendingPathComponent("branch-topology.json"))
            ),
            certificate: decoder.decode(
                ASHComputationalCertificateAsset.self,
                from: Data(contentsOf: resourceRoot.appendingPathComponent("computational-certificate.json"))
            )
        )
    }

    static func loadBundled(bundle: Bundle = .main) throws -> ASHAssetCatalog {
        if let folderURL = bundle.url(forResource: "ASH", withExtension: nil) {
            return try load(from: folderURL)
        }
        if let resourceURL = bundle.resourceURL?.appendingPathComponent("ASH"),
           FileManager.default.fileExists(atPath: resourceURL.path) {
            return try load(from: resourceURL)
        }
        throw ASHAssetValidationError.missingResourceFolder
    }

    func validateRuntime() throws -> ASHAssetValidationReport {
        let mappingMatchesRuntime = validateMapping()
        let codewordsMatchRuntime = try validateCodewords()
        let stateReferenceMatchesRuntime = try validateStateReference()
        let branchTopologyMatchesRuntime = try validateBranchTopology()
        let certificateChecksPassed = certificate.allChecksPass && certificate.checks.values.allSatisfy { $0 }

        return ASHAssetValidationReport(
            mappingMatchesRuntime: mappingMatchesRuntime,
            codewordsMatchRuntime: codewordsMatchRuntime,
            stateReferenceMatchesRuntime: stateReferenceMatchesRuntime,
            branchTopologyMatchesRuntime: branchTopologyMatchesRuntime,
            certificateChecksPassed: certificateChecksPassed,
            validatedCodewordCount: codewords.count,
            validatedStateCount: stateReference.count,
            validatedBranchLeafCount: branchTopology.leafCount,
            validatedFeatureCoordinateCount: mapping.coordinates.count
        )
    }

    private func validateMapping() -> Bool {
        let runtimeNames = ASHFeatureExtractor.featureNames
        let runtimeThresholds = ASHFeatureBinarizer.defaultThresholds
        let runtimeHysteresis = ASHFeatureBinarizer.defaultHysteresis
        let featureCoordinates = Array(mapping.coordinates.prefix(runtimeNames.count))

        guard mapping.coordinates.count == ASHState.bitCount,
              featureCoordinates.map(\.name) == runtimeNames,
              featureCoordinates.map(\.index) == Array(1...runtimeNames.count),
              equal(featureCoordinates.compactMap(\.threshold), runtimeThresholds),
              equal(featureCoordinates.compactMap(\.hysteresis), runtimeHysteresis),
              mapping.coordinates.last?.name == "parity_integrity",
              mapping.code.generatorMatrix == ASHCode.generatorRows.map(\.description),
              mapping.branching.actions == ASHBranchTree.actionOrder,
              mapping.branching.defaultDepth == ASHBranchTree.defaultDepth,
              mapping.reconstruction.defaultScale == ASHReconstruction.defaultScale,
              mapping.reconstruction.defaultTopK == ASHReconstruction.defaultTopK,
              equal(mapping.reconstruction.operatorStrength, ASHReconstruction.defaultOperatorStrength),
              equal(mapping.reconstruction.scoringWeights.data, ASHReconstruction.defaultDataWeight),
              equal(mapping.reconstruction.scoringWeights.edge, ASHReconstruction.defaultEdgeWeight),
              equal(mapping.reconstruction.scoringWeights.temporal, ASHReconstruction.defaultTemporalWeight) else {
            return false
        }

        for action in ASHBranchTree.actionOrder {
            guard equal(mapping.branching.weights[action] ?? -1.0, ASHBranchTree.actionWeights[action] ?? -2.0) else {
                return false
            }
        }
        return true
    }

    private func validateCodewords() throws -> Bool {
        guard codewords.count == ASHCode.messageCodewordPairs.count else { return false }
        let expected = ASHCode.messageCodewordPairs.map { pair in
            (message: binaryString(pair.message.bits), codeword: pair.codeword.description)
        }
        let actual = codewords.map { row in
            (message: row.message, codeword: row.codeword)
        }
        return expected.elementsEqual(actual) { lhs, rhs in
            lhs.message == rhs.message && lhs.codeword == rhs.codeword
        }
    }

    private func validateStateReference() throws -> Bool {
        guard stateReference.count == 1 << ASHState.bitCount else { return false }

        for row in stateReference {
            let state = try ASHState(bits: bits(from: row.bits))
            let decoded = ASHCode.decode(state)
            guard row.index == Int(state.rawValue),
                  row.hammingWeight == state.rawValue.nonzeroBitCount,
                  row.integrityValid == (state.hasValidIntegrity ? 1 : 0),
                  row.nearestCodeDistance == decoded.distance,
                  row.nearestCodewordCount == decoded.nearestCount,
                  row.decoderStatus == statusName(decoded.status) else {
                return false
            }
        }
        return true
    }

    private func validateBranchTopology() throws -> Bool {
        let sourceState = try ASHState(bits: bits(from: branchTopology.sourceState))
        let nodes = try ASHBranchTree.generate(sourceState: sourceState, depth: ASHBranchTree.defaultDepth)
        let generatedByPath = Dictionary(uniqueKeysWithValues: nodes.map { ($0.path, $0) })

        guard branchTopology.nodeCount == nodes.count,
              branchTopology.leafCount == ASHBranchTree.leafNodes(nodes).count,
              branchTopology.nodes.count == nodes.count else {
            return false
        }

        for assetNode in branchTopology.nodes {
            guard let node = generatedByPath[assetNode.path],
                  node.depth == assetNode.depth,
                  node.action == assetNode.action,
                  node.parentPath == assetNode.parentPath,
                  binaryString(node.message.bits) == assetNode.message,
                  node.codeword.description == assetNode.codeword,
                  node.state.description == assetNode.state,
                  equal(node.weight, assetNode.weight) else {
                return false
            }
        }
        return true
    }

    private static func parseCodewords(_ data: Data) throws -> [ASHCodewordAssetRow] {
        try parseCSV(data).map { fields in
            guard let weight = Int(fields["weight"] ?? "") else {
                throw ASHAssetValidationError.invalidCSV("codewords.csv")
            }
            return ASHCodewordAssetRow(
                message: fields["message"] ?? "",
                codeword: fields["codeword"] ?? "",
                weight: weight,
                syndrome: fields["syndrome"] ?? ""
            )
        }
    }

    private static func parseStateReference(_ data: Data) throws -> [ASHStateReferenceAssetRow] {
        try parseCSV(data).map { fields in
            guard let index = Int(fields["index"] ?? ""),
                  let hammingWeight = Int(fields["hamming_weight"] ?? ""),
                  let integrityValid = Int(fields["integrity_valid"] ?? ""),
                  let cosetID = Int(fields["coset_id"] ?? ""),
                  let nearestCodeDistance = Int(fields["nearest_code_distance"] ?? ""),
                  let nearestCodewordCount = Int(fields["nearest_codeword_count"] ?? "") else {
                throw ASHAssetValidationError.invalidCSV("ash-state-reference.csv")
            }
            return ASHStateReferenceAssetRow(
                index: index,
                bits: fields["bits"] ?? "",
                hammingWeight: hammingWeight,
                integrityValid: integrityValid,
                cosetID: cosetID,
                cosetRepresentative: fields["coset_representative"] ?? "",
                nearestCodeDistance: nearestCodeDistance,
                nearestCodewordCount: nearestCodewordCount,
                decoderStatus: fields["decoder_status"] ?? ""
            )
        }
    }

    private static func parseCSV(_ data: Data) throws -> [[String: String]] {
        guard let string = String(data: data, encoding: .utf8) else {
            throw ASHAssetValidationError.invalidUTF8
        }
        let lines = string.split(whereSeparator: \.isNewline).map(String.init)
        guard let headerLine = lines.first else {
            throw ASHAssetValidationError.invalidCSV("empty")
        }
        let headers = headerLine.split(separator: ",", omittingEmptySubsequences: false).map(String.init)

        return try lines.dropFirst().map { line in
            let columns = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard columns.count == headers.count else {
                throw ASHAssetValidationError.invalidCSV(line)
            }
            return Dictionary(uniqueKeysWithValues: zip(headers, columns))
        }
    }
}

struct ASHAssetValidationReport: Sendable {
    let mappingMatchesRuntime: Bool
    let codewordsMatchRuntime: Bool
    let stateReferenceMatchesRuntime: Bool
    let branchTopologyMatchesRuntime: Bool
    let certificateChecksPassed: Bool
    let validatedCodewordCount: Int
    let validatedStateCount: Int
    let validatedBranchLeafCount: Int
    let validatedFeatureCoordinateCount: Int

    var isValid: Bool {
        mappingMatchesRuntime
            && codewordsMatchRuntime
            && stateReferenceMatchesRuntime
            && branchTopologyMatchesRuntime
            && certificateChecksPassed
    }
}

struct ASHMappingAsset: Decodable, Sendable {
    var coordinates: [ASHMappingCoordinateAsset]
    let code: ASHMappingCodeAsset
    let branching: ASHMappingBranchingAsset
    let reconstruction: ASHMappingReconstructionAsset
}

struct ASHMappingCoordinateAsset: Decodable, Sendable {
    let index: Int
    let name: String
    var threshold: Double?
    var hysteresis: Double?
    let rule: String?
}

struct ASHMappingCodeAsset: Decodable, Sendable {
    let generatorMatrix: [String]
}

struct ASHMappingBranchingAsset: Decodable, Sendable {
    let actions: [String]
    let weights: [String: Double]
    let defaultDepth: Int
}

struct ASHMappingReconstructionAsset: Decodable, Sendable {
    let defaultScale: Int
    let defaultTopK: Int
    let operatorStrength: Double
    let scoringWeights: ASHMappingScoringWeightsAsset
}

struct ASHMappingScoringWeightsAsset: Decodable, Sendable {
    let data: Double
    let edge: Double
    let temporal: Double
}

struct ASHCodewordAssetRow: Equatable, Sendable {
    let message: String
    let codeword: String
    let weight: Int
    let syndrome: String
}

struct ASHStateReferenceAssetRow: Equatable, Sendable {
    let index: Int
    let bits: String
    let hammingWeight: Int
    let integrityValid: Int
    let cosetID: Int
    let cosetRepresentative: String
    let nearestCodeDistance: Int
    let nearestCodewordCount: Int
    let decoderStatus: String
}

struct ASHBranchTopologyAsset: Decodable, Sendable {
    let nodeCount: Int
    let leafCount: Int
    let sourceState: String
    let nodes: [ASHBranchTopologyNodeAsset]
}

struct ASHBranchTopologyNodeAsset: Decodable, Sendable {
    let path: String
    let parentPath: String?
    let depth: Int
    let action: String
    let message: String
    let codeword: String
    let state: String
    let weight: Double
}

struct ASHComputationalCertificateAsset: Decodable, Sendable {
    let allChecksPass: Bool
    let checks: [String: Bool]
}

enum ASHBackendStatus: Equatable, Sendable {
    case validating
    case available
    case unavailable

    var displayText: String {
        switch self {
        case .validating:
            return "ASH Backend: Validating"
        case .available:
            return "ASH Backend: Available"
        case .unavailable:
            return "ASH Backend: Unavailable"
        }
    }
}

enum ASHBackendStartupValidator {
    static func validate(bundle: Bundle = .main) -> ASHBackendStatus {
        do {
            let catalog = try ASHAssetCatalog.loadBundled(bundle: bundle)
            return try catalog.validateRuntime().isValid ? .available : .unavailable
        } catch {
            return .unavailable
        }
    }
}

enum ASHAssetValidationError: Error, Equatable {
    case missingResourceFolder
    case invalidUTF8
    case invalidCSV(String)
}

private func bits(from string: String) throws -> [Int] {
    try string.map { character in
        switch character {
        case "0":
            return 0
        case "1":
            return 1
        default:
            throw ASHCoreError.invalidBitValue(-1)
        }
    }
}

private func binaryString(_ bits: [Int]) -> String {
    bits.map(String.init).joined()
}

private func statusName(_ status: ASHDecodeStatus) -> String {
    switch status {
    case .exact:
        return "exact"
    case .corrected:
        return "corrected"
    case .uncorrectable:
        return "uncorrectable"
    }
}

private func equal(_ lhs: [Double], _ rhs: [Double]) -> Bool {
    guard lhs.count == rhs.count else { return false }
    return zip(lhs, rhs).allSatisfy { equal($0, $1) }
}

private func equal(_ lhs: Double, _ rhs: Double) -> Bool {
    abs(lhs - rhs) <= 1e-12
}
