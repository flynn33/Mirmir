import Foundation

indirect enum ASHLUTStrictJSONValueV3 {
    case object([String: ASHLUTStrictJSONValueV3])
    case array([ASHLUTStrictJSONValueV3])
    case string(String)
    case integer(Int64)
    case boolean(Bool)
    case null
}

struct ASHLUTStrictJSONParserV3 {
    private let bytes: [UInt8]
    private var index = 0

    init(data: Data) {
        bytes = Array(data)
    }

    mutating func parse() throws -> ASHLUTStrictJSONValueV3 {
        skipWhitespace()
        let value = try parseValue()
        skipWhitespace()
        guard index == bytes.count else {
            throw ASHLUTLockedConfigurationJSONErrorV3.invalidSyntax
        }
        return value
    }

    private mutating func parseValue() throws -> ASHLUTStrictJSONValueV3 {
        guard index < bytes.count else {
            throw ASHLUTLockedConfigurationJSONErrorV3.invalidSyntax
        }
        switch bytes[index] {
        case 0x7b: return try parseObject()
        case 0x5b: return try parseArray()
        case 0x22: return .string(try parseString())
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
            throw ASHLUTLockedConfigurationJSONErrorV3.invalidSyntax
        }
    }

    private mutating func parseObject() throws -> ASHLUTStrictJSONValueV3 {
        index += 1
        skipWhitespace()
        var result: [String: ASHLUTStrictJSONValueV3] = [:]
        if consumeIf(0x7d) { return .object(result) }
        while true {
            guard index < bytes.count, bytes[index] == 0x22 else {
                throw ASHLUTLockedConfigurationJSONErrorV3.invalidSyntax
            }
            let key = try parseString()
            guard result[key] == nil else {
                throw ASHLUTLockedConfigurationJSONErrorV3.duplicateKey
            }
            skipWhitespace()
            guard consumeIf(0x3a) else {
                throw ASHLUTLockedConfigurationJSONErrorV3.invalidSyntax
            }
            skipWhitespace()
            result[key] = try parseValue()
            skipWhitespace()
            if consumeIf(0x7d) { return .object(result) }
            guard consumeIf(0x2c) else {
                throw ASHLUTLockedConfigurationJSONErrorV3.invalidSyntax
            }
            skipWhitespace()
        }
    }

    private mutating func parseArray() throws -> ASHLUTStrictJSONValueV3 {
        index += 1
        skipWhitespace()
        var result: [ASHLUTStrictJSONValueV3] = []
        if consumeIf(0x5d) { return .array(result) }
        while true {
            result.append(try parseValue())
            skipWhitespace()
            if consumeIf(0x5d) { return .array(result) }
            guard consumeIf(0x2c) else {
                throw ASHLUTLockedConfigurationJSONErrorV3.invalidSyntax
            }
            skipWhitespace()
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
                guard let string = try? JSONSerialization.jsonObject(
                    with: fragment,
                    options: .fragmentsAllowed
                ) as? String else {
                    throw ASHLUTLockedConfigurationJSONErrorV3.invalidSyntax
                }
                return string
            }
            if byte < 0x20 {
                throw ASHLUTLockedConfigurationJSONErrorV3.invalidSyntax
            }
            if byte == 0x5c {
                index += 1
                guard index < bytes.count else {
                    throw ASHLUTLockedConfigurationJSONErrorV3.invalidSyntax
                }
                let escaped = bytes[index]
                if escaped == 0x75 {
                    guard index + 4 < bytes.count,
                          bytes[(index + 1)...(index + 4)].allSatisfy(Self.isHex) else {
                        throw ASHLUTLockedConfigurationJSONErrorV3.invalidSyntax
                    }
                    index += 5
                    continue
                }
                guard [0x22, 0x5c, 0x2f, 0x62, 0x66, 0x6e, 0x72, 0x74].contains(escaped) else {
                    throw ASHLUTLockedConfigurationJSONErrorV3.invalidSyntax
                }
            }
            index += 1
        }
        throw ASHLUTLockedConfigurationJSONErrorV3.invalidSyntax
    }

    private mutating func parseInteger() throws -> Int64 {
        let start = index
        if consumeIf(0x2d), index == bytes.count {
            throw ASHLUTLockedConfigurationJSONErrorV3.invalidSyntax
        }
        guard index < bytes.count else {
            throw ASHLUTLockedConfigurationJSONErrorV3.invalidSyntax
        }
        if bytes[index] == 0x30 {
            index += 1
            if index < bytes.count, (0x30...0x39).contains(bytes[index]) {
                throw ASHLUTLockedConfigurationJSONErrorV3.invalidSyntax
            }
        } else {
            guard (0x31...0x39).contains(bytes[index]) else {
                throw ASHLUTLockedConfigurationJSONErrorV3.invalidSyntax
            }
            repeat { index += 1 } while index < bytes.count
                && (0x30...0x39).contains(bytes[index])
        }
        if index < bytes.count, [0x2e, 0x45, 0x65].contains(bytes[index]) {
            throw ASHLUTLockedConfigurationJSONErrorV3.invalidValue
        }
        guard let encoded = String(bytes: bytes[start..<index], encoding: .utf8),
              let value = Int64(encoded) else {
            throw ASHLUTLockedConfigurationJSONErrorV3.invalidValue
        }
        return value
    }

    private mutating func consume(_ expected: [UInt8]) throws {
        guard index + expected.count <= bytes.count,
              Array(bytes[index..<(index + expected.count)]) == expected else {
            throw ASHLUTLockedConfigurationJSONErrorV3.invalidSyntax
        }
        index += expected.count
    }

    private mutating func consumeIf(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }

    private mutating func skipWhitespace() {
        while index < bytes.count, [0x20, 0x09, 0x0a, 0x0d].contains(bytes[index]) {
            index += 1
        }
    }

    private static func isHex(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte)
            || (0x41...0x46).contains(byte)
            || (0x61...0x66).contains(byte)
    }
}

enum ASHLUTCanonicalJSONV3 {
    static func encode(_ value: ASHLUTStrictJSONValueV3) -> Data {
        var data = Data()
        append(value, to: &data)
        return data
    }

    private static func append(_ value: ASHLUTStrictJSONValueV3, to data: inout Data) {
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
        case .array(let array):
            data.append(0x5b)
            for (index, element) in array.enumerated() {
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
            case 0x22: data.append(contentsOf: "\\\"".utf8)
            case 0x5c: data.append(contentsOf: "\\\\".utf8)
            case 0x08: data.append(contentsOf: "\\b".utf8)
            case 0x0c: data.append(contentsOf: "\\f".utf8)
            case 0x0a: data.append(contentsOf: "\\n".utf8)
            case 0x0d: data.append(contentsOf: "\\r".utf8)
            case 0x09: data.append(contentsOf: "\\t".utf8)
            case 0x00...0x1f:
                data.append(contentsOf: String(format: "\\u%04x", scalar.value).utf8)
            default:
                data.append(contentsOf: String(scalar).utf8)
            }
        }
        data.append(0x22)
    }

    private static func unicodeScalarLess(_ lhs: String, _ rhs: String) -> Bool {
        let left = lhs.unicodeScalars.map(\.value)
        let right = rhs.unicodeScalars.map(\.value)
        return left.lexicographicallyPrecedes(right)
    }
}
