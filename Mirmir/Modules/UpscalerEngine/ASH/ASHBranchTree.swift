import Foundation

struct ASHBranchNode: Equatable, Sendable {
    let path: String
    let parentPath: String?
    let depth: Int
    let action: String
    let message: ASHMessage
    let codeword: ASHState
    let state: ASHState
    let weight: Double
}

enum ASHBranchTree {
    static let actionOrder = ["0", "+", "-"]
    static let actionWeights = ["0": 0.5, "+": 0.25, "-": 0.25]
    static let defaultDepth = 4

    static func generate(
        sourceState: ASHState,
        depth: Int = defaultDepth,
        telemetry: any ASHTelemetryRecording = ASHNoopTelemetryRecorder.shared
    ) throws -> [ASHBranchNode] {
        guard depth >= 0 else {
            throw ASHCoreError.invalidBranchDepth(depth)
        }
        guard sourceState.hasValidIntegrity else {
            throw ASHCoreError.invalidPreviousState
        }
        telemetry.increment(.runtimeTreeGenerations)

        let rootMessage = try ASHMessage(rawValue: 0)
        let rootCodeword = ASHCode.encode(rootMessage)
        let root = ASHBranchNode(
            path: "",
            parentPath: nil,
            depth: 0,
            action: "root",
            message: rootMessage,
            codeword: rootCodeword,
            state: sourceState,
            weight: 1.0
        )

        var nodes = [root]
        var frontier = [root]
        for level in 0..<depth {
            var nextFrontier: [ASHBranchNode] = []
            for parent in frontier {
                for action in actionOrder {
                    let message = try nextMessage(parent.message, action: action, level: level)
                    let codeword = ASHCode.encode(message)
                    let node = ASHBranchNode(
                        path: parent.path + action,
                        parentPath: parent.path,
                        depth: level + 1,
                        action: action,
                        message: message,
                        codeword: codeword,
                        state: sourceState.xor(codeword),
                        weight: parent.weight * (actionWeights[action] ?? 0.0)
                    )
                    nodes.append(node)
                    nextFrontier.append(node)
                }
            }
            frontier = nextFrontier
        }
        return nodes
    }

    static func leafNodes(_ nodes: [ASHBranchNode]) -> [ASHBranchNode] {
        guard let maximumDepth = nodes.map(\.depth).max() else { return [] }
        return nodes.filter { $0.depth == maximumDepth }
    }

    static func aggregateLeafWeights(_ nodes: [ASHBranchNode]) -> [ASHMessage: Double] {
        var totals: [ASHMessage: Double] = [:]
        for node in leafNodes(nodes) {
            totals[node.message, default: 0.0] += node.weight
        }
        return totals
    }

    static func recover(received: ASHState, sourceState: ASHState) -> ASHDecodeResult {
        ASHCode.decodeAffine(received: received, anchor: sourceState)
    }

    private static func nextMessage(_ message: ASHMessage, action: String, level: Int) throws -> ASHMessage {
        switch action {
        case "+":
            return try message.toggled(bitIndex: level % ASHMessage.bitCount)
        case "-":
            return try message.toggled(bitIndex: (level + 1) % ASHMessage.bitCount)
        case "0":
            return message
        default:
            throw ASHCoreError.invalidImageShape
        }
    }
}
