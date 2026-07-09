import Foundation

enum ASHDecodeStatus: Equatable, Sendable {
    case exact
    case corrected
    case uncorrectable
}

struct ASHDecodeResult: Equatable, Sendable {
    let status: ASHDecodeStatus
    let received: ASHState
    let codeword: ASHState?
    let messageBits: [Int]?
    let distance: Int
    let nearestCount: Int
}

enum ASHCode {
    static let generatorRows: [ASHState] = [
        ASHState(validatedRawValue: 0b111100000),
        ASHState(validatedRawValue: 0b110011000),
        ASHState(validatedRawValue: 0b101010100),
        ASHState(validatedRawValue: 0b100110001)
    ]

    static let messageCodewordPairs: [(message: ASHMessage, codeword: ASHState)] = {
        let pairs = (0..<16).map { value -> (message: ASHMessage, codeword: ASHState) in
            let message = ASHMessage(validatedRawValue: UInt8(value))
            return (message, encode(message))
        }
        return pairs.sorted { $0.codeword.rawValue < $1.codeword.rawValue }
    }()

    static let codewords: [ASHState] = messageCodewordPairs.map(\.codeword)

    private static let messageByCodeword: [ASHState: ASHMessage] = {
        Dictionary(uniqueKeysWithValues: messageCodewordPairs.map { ($0.codeword, $0.message) })
    }()

    static func encode(messageBits: [Int]) throws -> ASHState {
        encode(try ASHMessage(bits: messageBits))
    }

    static func encode(_ message: ASHMessage) -> ASHState {
        var raw: UInt16 = 0
        for (index, bit) in message.bits.enumerated() where bit == 1 {
            raw ^= generatorRows[index].rawValue
        }
        return ASHState(validatedRawValue: raw)
    }

    static func messageBits(for codeword: ASHState) -> [Int]? {
        messageByCodeword[codeword]?.bits
    }

    static func isCodeword(_ state: ASHState) -> Bool {
        messageByCodeword[state] != nil
    }

    static func decode(_ received: ASHState) -> ASHDecodeResult {
        let distances = codewords.map { codeword in
            (distance: received.hammingDistance(to: codeword), codeword: codeword)
        }
        let minimum = distances.map(\.distance).min() ?? ASHState.bitCount
        let nearest = distances.filter { $0.distance == minimum }.map(\.codeword)

        guard minimum <= 1, nearest.count == 1, let codeword = nearest.first else {
            return ASHDecodeResult(
                status: .uncorrectable,
                received: received,
                codeword: nil,
                messageBits: nil,
                distance: minimum,
                nearestCount: nearest.count
            )
        }

        return ASHDecodeResult(
            status: minimum == 0 ? .exact : .corrected,
            received: received,
            codeword: codeword,
            messageBits: messageByCodeword[codeword]?.bits,
            distance: minimum,
            nearestCount: 1
        )
    }

    static func decodeAffine(received: ASHState, anchor: ASHState) -> ASHDecodeResult {
        let relative = received.xor(anchor)
        let decoded = decode(relative)
        let recovered = decoded.codeword.map { anchor.xor($0) }
        return ASHDecodeResult(
            status: decoded.status,
            received: received,
            codeword: recovered,
            messageBits: decoded.messageBits,
            distance: decoded.distance,
            nearestCount: decoded.nearestCount
        )
    }
}
