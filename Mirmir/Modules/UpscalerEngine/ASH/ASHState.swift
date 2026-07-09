import Foundation

enum ASHCoreError: Error, CustomStringConvertible, Equatable {
    case invalidBitLength(expected: Int, actual: Int)
    case invalidBitValue(Int)
    case rawStateOutOfRange(UInt16)
    case invalidCoordinate(Int)
    case invalidMessageValue(UInt8)
    case invalidFeatureVector
    case invalidImageShape
    case invalidImageValue(Double)
    case previousImageShapeMismatch
    case invalidPreviousState
    case invalidBranchDepth(Int)
    case invalidScale(Int)
    case invalidTopK(Int)
    case missingBranchLeaves
    case invalidCandidateShape

    var description: String {
        switch self {
        case .invalidBitLength(let expected, let actual):
            return "Expected \(expected) bits, received \(actual)."
        case .invalidBitValue(let value):
            return "Bit vectors may contain only 0 and 1; received \(value)."
        case .rawStateOutOfRange(let value):
            return "ASH state raw value must fit in the low 9 bits; received \(value)."
        case .invalidCoordinate(let coordinate):
            return "ASH coordinate must be in 1...9; received \(coordinate)."
        case .invalidMessageValue(let value):
            return "ASH message value must fit in four bits; received \(value)."
        case .invalidFeatureVector:
            return "ASH feature vectors require eight finite values in [0, 1]."
        case .invalidImageShape:
            return "ASH images require nonzero dimensions and 1, 3, or 4 channels."
        case .invalidImageValue(let value):
            return "ASH image values must be finite and lie in [0, 1]; received \(value)."
        case .previousImageShapeMismatch:
            return "Current and previous ASH images must have identical spatial shape."
        case .invalidPreviousState:
            return "Previous ASH state fails the coordinate-9 integrity relation."
        case .invalidBranchDepth(let depth):
            return "ASH branch depth must be nonnegative; received \(depth)."
        case .invalidScale(let scale):
            return "ASH reconstruction scale must be a positive integer; received \(scale)."
        case .invalidTopK(let topK):
            return "ASH candidate topK must be positive; received \(topK)."
        case .missingBranchLeaves:
            return "ASH reconstruction requires at least one branch leaf."
        case .invalidCandidateShape:
            return "ASH candidate dimensions must be divisible by the reconstruction scale."
        }
    }
}

struct ASHState: Hashable, Sendable, CustomStringConvertible {
    static let bitCount = 9
    static let payloadBitCount = 8
    static let mask: UInt16 = 0x01ff

    let rawValue: UInt16

    init(rawValue: UInt16) throws {
        guard rawValue & ~Self.mask == 0 else {
            throw ASHCoreError.rawStateOutOfRange(rawValue)
        }
        self.rawValue = rawValue
    }

    init(validatedRawValue: UInt16) {
        precondition(validatedRawValue & ~Self.mask == 0)
        self.rawValue = validatedRawValue
    }

    init(bits: [Int]) throws {
        let normalized = try Self.normalize(bits, expectedLength: Self.bitCount)
        var raw: UInt16 = 0
        for (index, bit) in normalized.enumerated() where bit == 1 {
            raw |= UInt16(1 << (Self.bitCount - 1 - index))
        }
        self.rawValue = raw
    }

    init(payloadBits: [Int]) throws {
        let payload = try Self.normalize(payloadBits, expectedLength: Self.payloadBitCount)
        try self.init(bits: payload + [Self.integrityBit(forPayload: payload)])
    }

    var bits: [Int] {
        (0..<Self.bitCount).map { index in
            Int((rawValue >> UInt16(Self.bitCount - 1 - index)) & 1)
        }
    }

    var description: String {
        bits.map(String.init).joined()
    }

    var hasValidIntegrity: Bool {
        bit(coordinate: 9) == Self.integrityBit(forPayload: Array(bits.prefix(Self.payloadBitCount)))
    }

    func bit(coordinate: Int) -> Int {
        precondition((1...Self.bitCount).contains(coordinate), ASHCoreError.invalidCoordinate(coordinate).description)
        return Int((rawValue >> UInt16(Self.bitCount - coordinate)) & 1)
    }

    func toggled(coordinate: Int) -> ASHState {
        precondition((1...Self.bitCount).contains(coordinate), ASHCoreError.invalidCoordinate(coordinate).description)
        let mask = UInt16(1 << (Self.bitCount - coordinate))
        return ASHState(validatedRawValue: rawValue ^ mask)
    }

    func xor(_ other: ASHState) -> ASHState {
        ASHState(validatedRawValue: rawValue ^ other.rawValue)
    }

    func hammingDistance(to other: ASHState) -> Int {
        Int((rawValue ^ other.rawValue).nonzeroBitCount)
    }

    static func integrityBit(forPayload payloadBits: [Int]) -> Int {
        precondition(payloadBits.count == payloadBitCount)
        return payloadBits.reduce(0) { $0 ^ $1 }
    }

    static func normalize(_ bits: [Int], expectedLength: Int) throws -> [Int] {
        guard bits.count == expectedLength else {
            throw ASHCoreError.invalidBitLength(expected: expectedLength, actual: bits.count)
        }
        for bit in bits where bit != 0 && bit != 1 {
            throw ASHCoreError.invalidBitValue(bit)
        }
        return bits
    }
}

struct ASHMessage: Hashable, Comparable, Sendable {
    static let bitCount = 4

    let rawValue: UInt8

    init(rawValue: UInt8) throws {
        guard rawValue < 16 else {
            throw ASHCoreError.invalidMessageValue(rawValue)
        }
        self.rawValue = rawValue
    }

    init(validatedRawValue: UInt8) {
        precondition(validatedRawValue < 16)
        self.rawValue = validatedRawValue
    }

    init(bits: [Int]) throws {
        let normalized = try ASHState.normalize(bits, expectedLength: Self.bitCount)
        var raw: UInt8 = 0
        for bit in normalized {
            raw = (raw << 1) | UInt8(bit)
        }
        try self.init(rawValue: raw)
    }

    var bits: [Int] {
        (0..<Self.bitCount).map { index in
            Int((rawValue >> UInt8(Self.bitCount - 1 - index)) & 1)
        }
    }

    func toggled(bitIndex: Int) throws -> ASHMessage {
        guard (0..<Self.bitCount).contains(bitIndex) else {
            throw ASHCoreError.invalidBitLength(expected: Self.bitCount, actual: bitIndex)
        }
        let mask = UInt8(1 << (Self.bitCount - 1 - bitIndex))
        return ASHMessage(validatedRawValue: rawValue ^ mask)
    }

    static func < (lhs: ASHMessage, rhs: ASHMessage) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
