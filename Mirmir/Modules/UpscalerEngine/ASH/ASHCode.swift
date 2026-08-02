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
    private struct StrictDecodeEntry: Sendable {
        let status: ASHDecodeStatus
        let codeword: ASHState?
        let message: ASHMessage?
        let distance: Int
        let nearestCount: Int
    }

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

    /// The strict ASH decoder has a finite nine-bit domain. Building its 512
    /// entries once preserves the canonical radius-one semantics while avoiding
    /// a 16-codeword nearest-neighbor search at every runtime decode site.
    private static let strictDecodeTable: [StrictDecodeEntry] = {
        (0..<(1 << ASHState.bitCount)).map { rawValue in
            let received = ASHState(validatedRawValue: UInt16(rawValue))
            var minimum = ASHState.bitCount
            var nearestCodeword: ASHState?
            var nearestCount = 0

            for codeword in codewords {
                let distance = received.hammingDistance(to: codeword)
                if distance < minimum {
                    minimum = distance
                    nearestCodeword = codeword
                    nearestCount = 1
                } else if distance == minimum {
                    nearestCount += 1
                }
            }

            guard minimum <= 1,
                  nearestCount == 1,
                  let codeword = nearestCodeword else {
                return StrictDecodeEntry(
                    status: .uncorrectable,
                    codeword: nil,
                    message: nil,
                    distance: minimum,
                    nearestCount: nearestCount
                )
            }

            return StrictDecodeEntry(
                status: minimum == 0 ? .exact : .corrected,
                codeword: codeword,
                message: messageByCodeword[codeword],
                distance: minimum,
                nearestCount: 1
            )
        }
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
        let entry = strictDecodeTable[Int(received.rawValue)]
        return ASHDecodeResult(
            status: entry.status,
            received: received,
            codeword: entry.codeword,
            messageBits: entry.message?.bits,
            distance: entry.distance,
            nearestCount: entry.nearestCount
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
