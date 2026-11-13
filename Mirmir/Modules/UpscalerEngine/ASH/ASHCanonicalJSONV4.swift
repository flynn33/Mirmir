import CryptoKit
import Foundation

enum ASHCanonicalJSONV4Error: Error, Equatable, Sendable {
    case invalidSyntax
    case duplicateObjectKey(String)
    case nonIntegerNumber
    case integerOutOfRange
    case nonCanonicalEncoding
    case invalidSHA256(String)
    case invalidHashDomain
}

struct ASHSHA256V4: Codable, Comparable, CustomStringConvertible, Hashable,
    Sendable {
    let rawValue: String

    init(_ rawValue: String) throws {
        guard rawValue.utf8.count == 64,
              rawValue.utf8.allSatisfy({ byte in
                  (0x30...0x39).contains(byte) || (0x61...0x66).contains(byte)
              }) else {
            throw ASHCanonicalJSONV4Error.invalidSHA256(rawValue)
        }
        self.rawValue = rawValue
    }

    init(rawData: Data) {
        let alphabet = Array("0123456789abcdef".utf8)
        var hexadecimal = [UInt8](repeating: 0, count: 64)
        for (index, byte) in SHA256.hash(data: rawData).enumerated() {
            hexadecimal[index * 2] = alphabet[Int(byte >> 4)]
            hexadecimal[index * 2 + 1] = alphabet[Int(byte & 0x0f)]
        }
        self.rawValue = String(decoding: hexadecimal, as: UTF8.self)
    }

    init(domain: String, canonicalData: Data) throws {
        guard !domain.isEmpty,
              domain.utf8.count <= 128,
              domain.utf8.allSatisfy({ (0x21...0x7e).contains($0) }) else {
            throw ASHCanonicalJSONV4Error.invalidHashDomain
        }
        var bytes = Data(domain.utf8)
        bytes.append(0)
        bytes.append(canonicalData)
        self.init(rawData: bytes)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        do {
            try self.init(container.decode(String.self))
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected a lowercase SHA-256 digest."
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var description: String { rawValue }
}

indirect enum ASHCanonicalJSONValueV4: Equatable, Sendable {
    case object([String: ASHCanonicalJSONValueV4])
    case array([ASHCanonicalJSONValueV4])
    case string(String)
    case integer(Int64)
    case boolean(Bool)
    case null
}

enum ASHCanonicalJSONV4 {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let intermediate = try encoder.encode(value)
        var parser = ASHCanonicalJSONParserV4(data: intermediate)
        return encode(try parser.parse())
    }

    static func decode<T: Codable>(
        _ type: T.Type,
        from data: Data
    ) throws -> T {
        var parser = ASHCanonicalJSONParserV4(data: data)
        let parsed = try parser.parse()
        guard encode(parsed) == data else {
            throw ASHCanonicalJSONV4Error.nonCanonicalEncoding
        }
        let decoded = try JSONDecoder().decode(type, from: data)
        guard try encode(decoded) == data else {
            // This also rejects unknown keys because Codable would otherwise
            // silently discard them before the second canonical encoding.
            throw ASHCanonicalJSONV4Error.nonCanonicalEncoding
        }
        return decoded
    }

    static func hash<T: Encodable>(
        _ value: T,
        domain: String
    ) throws -> ASHSHA256V4 {
        try ASHSHA256V4(domain: domain, canonicalData: encode(value))
    }

    static func parse(_ data: Data) throws -> ASHCanonicalJSONValueV4 {
        var parser = ASHCanonicalJSONParserV4(data: data)
        return try parser.parse()
    }

    static func encode(_ value: ASHCanonicalJSONValueV4) -> Data {
        var data = Data()
        append(value, to: &data)
        return data
    }

    private static func append(
        _ value: ASHCanonicalJSONValueV4,
        to data: inout Data
    ) {
        switch value {
        case .object(let object):
            data.append(0x7b)
            let keys = object.keys.sorted(by: unicodeScalarLess)
            for (index, key) in keys.enumerated() {
                if index > 0 { data.append(0x2c) }
                appendString(key, to: &data)
                data.append(0x3a)
                append(object[key]!, to: &data)
            }
            data.append(0x7d)
        case .array(let values):
            data.append(0x5b)
            for (index, element) in values.enumerated() {
                if index > 0 { data.append(0x2c) }
                append(element, to: &data)
            }
            data.append(0x5d)
        case .string(let string):
            appendString(string, to: &data)
        case .integer(let integer):
            data.append(contentsOf: String(integer).utf8)
        case .boolean(let boolean):
            data.append(contentsOf: (boolean ? "true" : "false").utf8)
        case .null:
            data.append(contentsOf: "null".utf8)
        }
    }

    private static func appendString(_ string: String, to data: inout Data) {
        data.append(0x22)
        for scalar in string.unicodeScalars {
            switch scalar.value {
            case 0x22:
                data.append(contentsOf: "\\\"".utf8)
            case 0x5c:
                data.append(contentsOf: "\\\\".utf8)
            case 0x08:
                data.append(contentsOf: "\\b".utf8)
            case 0x0c:
                data.append(contentsOf: "\\f".utf8)
            case 0x0a:
                data.append(contentsOf: "\\n".utf8)
            case 0x0d:
                data.append(contentsOf: "\\r".utf8)
            case 0x09:
                data.append(contentsOf: "\\t".utf8)
            case 0x00...0x1f:
                data.append(
                    contentsOf: String(
                        format: "\\u%04x",
                        locale: Locale(identifier: "en_US_POSIX"),
                        scalar.value
                    ).utf8
                )
            default:
                data.append(contentsOf: String(scalar).utf8)
            }
        }
        data.append(0x22)
    }

    private static func unicodeScalarLess(_ lhs: String, _ rhs: String) -> Bool {
        lhs.unicodeScalars.map(\.value).lexicographicallyPrecedes(
            rhs.unicodeScalars.map(\.value)
        )
    }
}

private struct ASHCanonicalJSONParserV4 {
    private let bytes: [UInt8]
    private var index = 0

    init(data: Data) {
        bytes = Array(data)
    }

    mutating func parse() throws -> ASHCanonicalJSONValueV4 {
        let value = try parseValue()
        guard index == bytes.count else {
            throw ASHCanonicalJSONV4Error.invalidSyntax
        }
        return value
    }

    private mutating func parseValue() throws -> ASHCanonicalJSONValueV4 {
        guard index < bytes.count else {
            throw ASHCanonicalJSONV4Error.invalidSyntax
        }
        switch bytes[index] {
        case 0x7b:
            return try parseObject()
        case 0x5b:
            return try parseArray()
        case 0x22:
            return .string(try parseString())
        case 0x74:
            try consume(Array("true".utf8))
            return .boolean(true)
        case 0x66:
            try consume(Array("false".utf8))
            return .boolean(false)
        case 0x6e:
            try consume(Array("null".utf8))
            return .null
        case 0x2d, 0x30...0x39:
            return .integer(try parseInteger())
        default:
            // Whitespace is deliberately illegal: canonical documents are
            // compact and byte identities must not depend on formatting.
            throw ASHCanonicalJSONV4Error.invalidSyntax
        }
    }

    private mutating func parseObject() throws -> ASHCanonicalJSONValueV4 {
        index += 1
        var result: [String: ASHCanonicalJSONValueV4] = [:]
        if consumeIf(0x7d) { return .object(result) }
        while true {
            guard index < bytes.count, bytes[index] == 0x22 else {
                throw ASHCanonicalJSONV4Error.invalidSyntax
            }
            let key = try parseString()
            guard result[key] == nil else {
                throw ASHCanonicalJSONV4Error.duplicateObjectKey(key)
            }
            guard consumeIf(0x3a) else {
                throw ASHCanonicalJSONV4Error.invalidSyntax
            }
            result[key] = try parseValue()
            if consumeIf(0x7d) { return .object(result) }
            guard consumeIf(0x2c) else {
                throw ASHCanonicalJSONV4Error.invalidSyntax
            }
        }
    }

    private mutating func parseArray() throws -> ASHCanonicalJSONValueV4 {
        index += 1
        var result: [ASHCanonicalJSONValueV4] = []
        if consumeIf(0x5d) { return .array(result) }
        while true {
            result.append(try parseValue())
            if consumeIf(0x5d) { return .array(result) }
            guard consumeIf(0x2c) else {
                throw ASHCanonicalJSONV4Error.invalidSyntax
            }
        }
    }

    private mutating func parseString() throws -> String {
        let start = index
        index += 1
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x22 {
                index += 1
                let fragment = Data(bytes[start..<index])
                guard let value = try? JSONSerialization.jsonObject(
                    with: fragment,
                    options: .fragmentsAllowed
                ) as? String else {
                    throw ASHCanonicalJSONV4Error.invalidSyntax
                }
                return value
            }
            guard byte >= 0x20 else {
                throw ASHCanonicalJSONV4Error.invalidSyntax
            }
            if byte == 0x5c {
                index += 1
                guard index < bytes.count else {
                    throw ASHCanonicalJSONV4Error.invalidSyntax
                }
                if bytes[index] == 0x75 {
                    guard index + 4 < bytes.count,
                          bytes[(index + 1)...(index + 4)].allSatisfy(Self.isHex)
                    else {
                        throw ASHCanonicalJSONV4Error.invalidSyntax
                    }
                    index += 5
                    continue
                }
                guard [0x22, 0x5c, 0x2f, 0x62, 0x66, 0x6e, 0x72, 0x74]
                    .contains(bytes[index]) else {
                    throw ASHCanonicalJSONV4Error.invalidSyntax
                }
            }
            index += 1
        }
        throw ASHCanonicalJSONV4Error.invalidSyntax
    }

    private mutating func parseInteger() throws -> Int64 {
        let start = index
        if consumeIf(0x2d), index == bytes.count {
            throw ASHCanonicalJSONV4Error.invalidSyntax
        }
        guard index < bytes.count else {
            throw ASHCanonicalJSONV4Error.invalidSyntax
        }
        if bytes[index] == 0x30 {
            index += 1
            if index < bytes.count, (0x30...0x39).contains(bytes[index]) {
                throw ASHCanonicalJSONV4Error.invalidSyntax
            }
        } else {
            guard (0x31...0x39).contains(bytes[index]) else {
                throw ASHCanonicalJSONV4Error.invalidSyntax
            }
            repeat {
                index += 1
            } while index < bytes.count && (0x30...0x39).contains(bytes[index])
        }
        if index < bytes.count, [0x2e, 0x45, 0x65].contains(bytes[index]) {
            throw ASHCanonicalJSONV4Error.nonIntegerNumber
        }
        guard let encoded = String(
            bytes: bytes[start..<index],
            encoding: .utf8
        ), let value = Int64(encoded) else {
            throw ASHCanonicalJSONV4Error.integerOutOfRange
        }
        return value
    }

    private mutating func consume(_ expected: [UInt8]) throws {
        guard index + expected.count <= bytes.count,
              Array(bytes[index..<(index + expected.count)]) == expected else {
            throw ASHCanonicalJSONV4Error.invalidSyntax
        }
        index += expected.count
    }

    private mutating func consumeIf(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }

    private static func isHex(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte)
            || (0x41...0x46).contains(byte)
            || (0x61...0x66).contains(byte)
    }
}
