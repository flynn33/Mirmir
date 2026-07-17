import CryptoKit
import Darwin
import Foundation

#if canImport(Mirmir)
@testable import Mirmir
#endif

enum ASHCalibrationCLIError: Error, CustomStringConvertible {
    case invalidArguments
    case unsafePath(String)
    case missingFile(String)
    case unexpectedFile(String)
    case fileType(String)
    case fileRead(String)
    case fileWrite(String)
    case hashMismatch(String)
    case invalidRequest(String)
    case unsupported(String)
    case outputValidation(String)

    var description: String {
        switch self {
        case .invalidArguments: "invalid command arguments"
        case .unsafePath(let value): "unsafe path: \(value)"
        case .missingFile(let value): "missing file: \(value)"
        case .unexpectedFile(let value): "unexpected existing file: \(value)"
        case .fileType(let value): "symbolic or wrong file type: \(value)"
        case .fileRead(let value): "file read failed: \(value)"
        case .fileWrite(let value): "file write failed: \(value)"
        case .hashMismatch(let value): "SHA-256 mismatch: \(value)"
        case .invalidRequest(let value): "invalid request: \(value)"
        case .unsupported(let value): "unsupported input: \(value)"
        case .outputValidation(let value): "output validation failed: \(value)"
        }
    }
}

#if !canImport(Mirmir)
protocol ASHTelemetryRecording: AnyObject, Sendable {
    func recordState(rawValue: UInt16)
    func recordMessage(_ rawValue: UInt8)
    func recordOperator(_ rawValue: UInt8)
    func recordDecode(_ status: ASHDecodeStatus)
    func recordCandidateCount(_ count: Int)
}

final class ASHNoopTelemetryRecorder: ASHTelemetryRecording, @unchecked Sendable {
    static let shared = ASHNoopTelemetryRecorder()

    private init() {}

    func recordState(rawValue _: UInt16) {}
    func recordMessage(_: UInt8) {}
    func recordOperator(_: UInt8) {}
    func recordDecode(_: ASHDecodeStatus) {}
    func recordCandidateCount(_: Int) {}
}

/// Standalone CLI equivalents of the app's CoreVideo-backed frame envelope.
/// The command-line target operates on exact planar bytes and therefore needs
/// only the pure normalized-plane portion of `ASHNV12FrameCodec`.
struct ASHNV12CodeFrame: Equatable, Sendable {
    let luma: ASHVideoAnalyzerV2CodePlane
    let cb: ASHVideoAnalyzerV2CodePlane
    let cr: ASHVideoAnalyzerV2CodePlane
    let chromaSiting: ASHChromaSitingV2
}

struct ASHNV12FrameGeometry: Equatable, Sendable {
    let lumaWidth: Int
    let lumaHeight: Int
    let chromaWidth: Int
    let chromaHeight: Int
}

struct ASHSpatialReferencePlaneOutputV2: Equatable, Sendable {
    let width: Int
    let height: Int
    let normalizedSamples: [Double]
}

enum ASHNormalizedChannel: Equatable, Sendable {
    case luma
    case chroma
}

enum ASHNV12FrameCodec {
    static func normalizedPlane(
        _ plane: ASHVideoAnalyzerV2CodePlane,
        channel: ASHNormalizedChannel
    ) throws -> ASHSpatialPlaneV2 {
        var samples: [Double] = []
        samples.reserveCapacity(plane.width * plane.height)
        for row in 0..<plane.height {
            let rowOffset = row * plane.bytesPerRow
            for column in 0..<plane.width {
                let code = plane.codes[rowOffset + column]
                let value: Double
                switch channel {
                case .luma:
                    value = plane.range.normalizeLuma(code)
                case .chroma:
                    value = plane.range.normalizeChroma(code) + 0.5
                }
                samples.append(min(1.0, max(0.0, value)))
            }
        }
        return try ASHSpatialPlaneV2(
            width: plane.width,
            height: plane.height,
            samples: samples,
            legalRange: 0.0...1.0
        )
    }
}
#endif

enum ASHCalibrationCLIHash {
    static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func value(_ data: Data) -> ASHLUTHashV2 {
        ASHLUTHashV2(validatedBytes: Array(SHA256.hash(data: data)))
    }
}

enum ASHCalibrationCLIFileIO {
    static func readRegularFile(_ path: String) throws -> Data {
        try validateComponents(path, finalMayBeMissing: false)
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw ASHCalibrationCLIError.fileRead(path)
        }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size >= 0,
              let size = Int(exactly: metadata.st_size) else {
            throw ASHCalibrationCLIError.fileType(path)
        }
        var data = Data(count: size)
        var offset = 0
        try data.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            while offset < size {
                let count = Darwin.read(descriptor, base.advanced(by: offset), size - offset)
                guard count > 0 else {
                    throw ASHCalibrationCLIError.fileRead(path)
                }
                offset += count
            }
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              after.st_dev == metadata.st_dev,
              after.st_ino == metadata.st_ino,
              after.st_size == metadata.st_size,
              after.st_mtimespec.tv_sec == metadata.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == metadata.st_mtimespec.tv_nsec else {
            throw ASHCalibrationCLIError.fileRead("changed while reading \(path)")
        }
        return data
    }

    static func writeNewRegularFile(_ data: Data, path: String) throws {
        try writeNewRegularFile(data, path: path, synchronize: true)
    }

    static func writeNewEphemeralRegularFile(_ data: Data, path: String) throws {
        try writeNewRegularFile(data, path: path, synchronize: false)
    }

    private static func writeNewRegularFile(
        _ data: Data,
        path: String,
        synchronize: Bool
    ) throws {
        try validateComponents(path, finalMayBeMissing: true)
        guard !FileManager.default.fileExists(atPath: path) else {
            throw ASHCalibrationCLIError.unexpectedFile(path)
        }
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            throw ASHCalibrationCLIError.fileWrite(path)
        }
        var completed = false
        defer {
            close(descriptor)
            if !completed { unlink(path) }
        }
        var offset = 0
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            while offset < data.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    data.count - offset
                )
                guard count > 0 else {
                    throw ASHCalibrationCLIError.fileWrite(path)
                }
                offset += count
            }
        }
        guard !synchronize || fsync(descriptor) == 0 else {
            throw ASHCalibrationCLIError.fileWrite(path)
        }
        completed = true
    }

    static func validateDirectory(_ path: String) throws {
        try validateComponents(path, finalMayBeMissing: false, finalMustBeDirectory: true)
    }

    static func removeIfPresent(_ path: String) {
        unlink(path)
    }

    private static func validateComponents(
        _ path: String,
        finalMayBeMissing: Bool,
        finalMustBeDirectory: Bool = false
    ) throws {
        guard path.hasPrefix("/"),
              !path.contains("\0"),
              !path.contains("//"),
              !((path as NSString).pathComponents.contains(".")),
              !((path as NSString).pathComponents.contains("..")) else {
            throw ASHCalibrationCLIError.unsafePath(path)
        }
        let components = (path as NSString).pathComponents
        var cursor = "/"
        for (index, component) in components.dropFirst().enumerated() {
            cursor = (cursor as NSString).appendingPathComponent(component)
            var metadata = stat()
            let result = lstat(cursor, &metadata)
            let final = index == components.count - 2
            if result != 0 {
                if final && finalMayBeMissing { return }
                throw ASHCalibrationCLIError.missingFile(cursor)
            }
            guard metadata.st_mode & S_IFMT != S_IFLNK else {
                throw ASHCalibrationCLIError.fileType(cursor)
            }
            if !final || finalMustBeDirectory {
                guard metadata.st_mode & S_IFMT == S_IFDIR else {
                    throw ASHCalibrationCLIError.fileType(cursor)
                }
            } else {
                guard metadata.st_mode & S_IFMT == S_IFREG else {
                    throw ASHCalibrationCLIError.fileType(cursor)
                }
            }
        }
    }
}

struct ASHCalibrationCLIOptions {
    private let values: [String: String]

    init(_ arguments: ArraySlice<String>) throws {
        guard arguments.count.isMultiple(of: 2) else {
            throw ASHCalibrationCLIError.invalidArguments
        }
        var result: [String: String] = [:]
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let name = arguments[index]
            let valueIndex = arguments.index(after: index)
            guard name.hasPrefix("--"), result[name] == nil else {
                throw ASHCalibrationCLIError.invalidArguments
            }
            result[name] = arguments[valueIndex]
            index = arguments.index(after: valueIndex)
        }
        values = result
    }

    func require(_ names: Set<String>) throws -> [String: String] {
        guard Set(values.keys) == names else {
            throw ASHCalibrationCLIError.invalidArguments
        }
        return values
    }
}

enum ASHCalibrationCLIJSON {
    static func canonicalData(_ object: Any) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw ASHCalibrationCLIError.outputValidation("invalid canonical JSON object")
        }
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    static func strictCanonicalValue(_ data: Data) throws -> ASHLUTStrictJSONValueV2 {
        var parser = ASHLUTStrictJSONParserV2(data: data)
        let value = try parser.parse()
        guard ASHLUTCanonicalJSONV2.encode(value) == data else {
            throw ASHCalibrationCLIError.invalidRequest("JSON is not canonical")
        }
        return value
    }

    static func object(
        _ value: ASHLUTStrictJSONValueV2?,
        keys: Set<String>
    ) throws -> [String: ASHLUTStrictJSONValueV2] {
        guard case .object(let object)? = value, Set(object.keys) == keys else {
            throw ASHCalibrationCLIError.invalidRequest("object field set mismatch")
        }
        return object
    }

    static func object(
        _ value: ASHLUTStrictJSONValueV2,
        keys: Set<String>
    ) throws -> [String: ASHLUTStrictJSONValueV2] {
        try object(Optional(value), keys: keys)
    }

    static func array(
        _ value: ASHLUTStrictJSONValueV2?
    ) throws -> [ASHLUTStrictJSONValueV2] {
        guard case .array(let result)? = value else {
            throw ASHCalibrationCLIError.invalidRequest("array expected")
        }
        return result
    }

    static func string(_ value: ASHLUTStrictJSONValueV2?) throws -> String {
        guard case .string(let result)? = value else {
            throw ASHCalibrationCLIError.invalidRequest("string expected")
        }
        return result
    }

    static func integer(_ value: ASHLUTStrictJSONValueV2?) throws -> Int {
        guard case .integer(let result)? = value,
              let exact = Int(exactly: result) else {
            throw ASHCalibrationCLIError.invalidRequest("integer expected")
        }
        return exact
    }

    static func writeLine(_ object: Any) throws {
        var data = try canonicalData(object)
        data.append(0x0a)
        FileHandle.standardOutput.write(data)
    }
}
