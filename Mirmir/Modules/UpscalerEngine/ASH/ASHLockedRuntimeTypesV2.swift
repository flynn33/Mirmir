import Foundation

enum ASHLockedRuntimeV2Error: Error, Equatable, Sendable {
    case configurationMismatch
    case parameterIndexOutOfBounds(UInt32)
    case invalidDestination(column: Int, row: Int)
    case invalidAnalysisGrid
    case invalidPhase
    case invalidRuntimeParameter
    case numericalFallbackFailed
}

struct ASHLockedAffineDecodeResultV2: Equatable, Sendable {
    let status: ASHDecodeStatus
    let message: ASHMessage?
    let correctedCoordinate: UInt8?
    let distance: UInt8
    let nearestCount: UInt8
}

enum ASHLockedAffineDecoderV2 {
    private struct TableEntry: Sendable {
        let status: ASHDecodeStatus
        let messageRawValue: UInt8
        let correctedCoordinate: UInt8
        let distance: UInt8
        let nearestCount: UInt8
    }

    private static let rejectedMessage = UInt8.max
    private static let noCorrectedCoordinate = UInt8.max

    private static let table: [TableEntry] = {
        (0..<(1 << ASHState.bitCount)).map { receivedRawValue in
            var minimumDistance = ASHState.bitCount + 1
            var nearestCount = 0
            var nearestMessage = rejectedMessage
            var nearestCodeword: UInt16 = 0
            for messageRawValue in UInt8(0)..<UInt8(1 << ASHMessage.bitCount) {
                let message = ASHMessage(validatedRawValue: messageRawValue)
                let codeword = ASHCode.encode(message).rawValue
                let distance = (UInt16(receivedRawValue) ^ codeword).nonzeroBitCount
                if distance < minimumDistance {
                    minimumDistance = distance
                    nearestCount = 1
                    nearestMessage = messageRawValue
                    nearestCodeword = codeword
                } else if distance == minimumDistance {
                    nearestCount += 1
                }
            }
            guard minimumDistance <= 1, nearestCount == 1 else {
                return TableEntry(
                    status: .uncorrectable,
                    messageRawValue: rejectedMessage,
                    correctedCoordinate: noCorrectedCoordinate,
                    distance: UInt8(minimumDistance),
                    nearestCount: UInt8(nearestCount)
                )
            }
            let correctedCoordinate: UInt8
            if minimumDistance == 0 {
                correctedCoordinate = noCorrectedCoordinate
            } else {
                let changedBit = (UInt16(receivedRawValue) ^ nearestCodeword).trailingZeroBitCount
                correctedCoordinate = UInt8(ASHState.bitCount - changedBit)
            }
            return TableEntry(
                status: minimumDistance == 0 ? .exact : .corrected,
                messageRawValue: nearestMessage,
                correctedCoordinate: correctedCoordinate,
                distance: UInt8(minimumDistance),
                nearestCount: 1
            )
        }
    }()

    static func decode(
        received: ASHState,
        anchor: ASHState
    ) -> ASHLockedAffineDecodeResultV2 {
        let relativeRawValue = Int(received.rawValue ^ anchor.rawValue)
        let entry = table[relativeRawValue]
        return ASHLockedAffineDecodeResultV2(
            status: entry.status,
            message: entry.messageRawValue == rejectedMessage
                ? nil
                : ASHMessage(validatedRawValue: entry.messageRawValue),
            correctedCoordinate: entry.correctedCoordinate == noCorrectedCoordinate
                ? nil
                : entry.correctedCoordinate,
            distance: entry.distance,
            nearestCount: entry.nearestCount
        )
    }
}

struct ASHLockedRuntimeCountersV2: Equatable, Sendable {
    let runtimeTreeGenerationCount: Int
    let runtimePathAllocationCount: Int

    static let zero = ASHLockedRuntimeCountersV2(
        runtimeTreeGenerationCount: 0,
        runtimePathAllocationCount: 0
    )
}

struct ASHLockedRuntimeCandidateV2: Equatable, Sendable {
    let decodedMessage: ASHMessage
    let descriptor: ASHSpatialDescriptorV2
    let affineDecode: ASHLockedAffineDecodeResultV2
    let sidecar: ASHSpatialSidecarV2
    let orientationSector: Int
    let parameters: ASHSpatialDevelopmentParametersV2
}

struct ASHLockedRuntimeDispatchV2: Equatable, Sendable {
    let sourceState: ASHState
    let parityWasRecomputed: Bool
    let primary: ASHLockedRuntimeCandidateV2
    let secondary: ASHLockedRuntimeCandidateV2?
    let primaryWeightUNorm16: UInt16
    let secondaryWeightUNorm16: UInt16
    let marginUNorm16: UInt16
    let affineFallbackUsed: Bool
    let sourceAlignedEntryFlag: Bool
    let counters: ASHLockedRuntimeCountersV2

    var operatorEvaluationCount: Int { secondary == nil ? 1 : 2 }
}

struct ASHLockedDispatchGridV2: Equatable, Sendable {
    let route: ASHSpatialRouteV2
    let configuration: ASHLUTLockedConfigurationV2
    let context: ASHLUTContextV2
    let analysisColumnCount: Int
    let analysisRowCount: Int
    let dispatches: [ASHLockedRuntimeDispatchV2]
    let counters: ASHLockedRuntimeCountersV2

    func dispatch(
        cellColumn: Int,
        cellRow: Int,
        phaseOrdinal: Int
    ) throws -> ASHLockedRuntimeDispatchV2 {
        guard (0..<analysisColumnCount).contains(cellColumn),
              (0..<analysisRowCount).contains(cellRow),
              (0..<route.phasePairCount).contains(phaseOrdinal) else {
            throw ASHLockedRuntimeV2Error.invalidPhase
        }
        let cellIndex = (cellRow * analysisColumnCount) + cellColumn
        return dispatches[(cellIndex * route.phasePairCount) + phaseOrdinal]
    }
}

struct ASHLockedRuntimeSampleResultV2: Equatable, Sendable {
    let value: Double
    let sourceCoordinates: ASHSpatialSourceCoordinatesV2
    let phaseOrdinal: Int
    let analysisCellColumn: Int
    let analysisCellRow: Int
    let dispatch: ASHLockedRuntimeDispatchV2
    let primaryResult: ASHSpatialSampleResultV2
    let secondaryResult: ASHSpatialSampleResultV2?
    let sourceAlignedSamplePreserved: Bool
    let numericalFallbackUsed: Bool
}

enum ASHLockedRuntimeV2 {}
