import Compression
import CoreVideo
import Foundation

enum R13NV12FrameCacheError: Error, Equatable, Sendable {
    case invalidGeometry(width: Int, height: Int)
    case invalidPlaneByteCount(
        plane: String,
        expected: Int,
        actual: Int
    )
    case unsupportedPixelFormat(OSType)
    case pixelBufferCreationFailed(CVReturn)
    case inaccessiblePlane(String)
    case malformedArtifact
    case unsupportedSchemaVersion(Int)
    case decompressionFailed
    case rawPayloadHashMismatch
    case artifactTooLarge(Int)
    case arithmeticOverflow
}

struct R13NV12PlaneByteCounts: Equatable, Sendable {
    let luma: Int
    let chroma: Int
    let total: Int
}

struct R13NV12Frame: Equatable, Sendable {
    static let maximumRawByteCount = 512 * 1_024 * 1_024

    let width: Int
    let height: Int
    let luma: Data
    let chroma: Data

    init(width: Int, height: Int, luma: Data, chroma: Data) throws {
        let counts = try Self.expectedPlaneByteCounts(
            width: width,
            height: height
        )
        guard luma.count == counts.luma else {
            throw R13NV12FrameCacheError.invalidPlaneByteCount(
                plane: "luma",
                expected: counts.luma,
                actual: luma.count
            )
        }
        guard chroma.count == counts.chroma else {
            throw R13NV12FrameCacheError.invalidPlaneByteCount(
                plane: "chroma",
                expected: counts.chroma,
                actual: chroma.count
            )
        }
        self.width = width
        self.height = height
        self.luma = luma
        self.chroma = chroma
    }

    static func expectedPlaneByteCounts(
        width: Int,
        height: Int
    ) throws -> R13NV12PlaneByteCounts {
        guard width > 0,
              height > 0,
              width.isMultiple(of: 2),
              height.isMultiple(of: 2) else {
            throw R13NV12FrameCacheError.invalidGeometry(
                width: width,
                height: height
            )
        }
        let (luma, lumaOverflow) = width.multipliedReportingOverflow(
            by: height
        )
        let chroma = luma / 2
        let (total, totalOverflow) = luma.addingReportingOverflow(chroma)
        guard !lumaOverflow,
              !totalOverflow,
              total <= maximumRawByteCount else {
            throw R13NV12FrameCacheError.arithmeticOverflow
        }
        return R13NV12PlaneByteCounts(
            luma: luma,
            chroma: chroma,
            total: total
        )
    }

    var tightRawData: Data {
        var data = Data(capacity: luma.count + chroma.count)
        data.append(luma)
        data.append(chroma)
        return data
    }

}

enum R13FrameCacheEncoding: String, Codable, Hashable, Sendable {
    case lzfse
    case raw
}

struct R13EncodedNV12Frame: Equatable, Sendable {
    let data: Data
    let encoding: R13FrameCacheEncoding
    let rawSHA256: String
}

protocol R13NV12FrameCacheCoding: Sendable {
    func encode(_ frame: R13NV12Frame) throws -> R13EncodedNV12Frame
    func decode(_ artifact: Data) throws -> R13NV12Frame
}

struct R13LZFSEFrameCacheCodec: R13NV12FrameCacheCoding {
    static let maximumEnvelopeOverheadBytes = 4_096

    private static let magic = Data("MIR13NV1".utf8)
    private static let maximumHeaderBytes = 2_048
    private let digest: any R13RestartDigesting

    init(
        digest: any R13RestartDigesting = R13CryptoKitRestartDigest()
    ) {
        self.digest = digest
    }

    func encode(_ frame: R13NV12Frame) throws -> R13EncodedNV12Frame {
        let raw = frame.tightRawData
        let compressed = encodeLZFSE(raw)
        let encoding: R13FrameCacheEncoding
        let payload: Data
        if let compressed, compressed.count < raw.count {
            encoding = .lzfse
            payload = compressed
        } else {
            encoding = .raw
            payload = raw
        }
        let rawSHA256 = digest.sha256(raw)
        let header = R13NV12FrameCacheHeader(
            schemaVersion: R13NV12FrameCacheHeader.currentSchemaVersion,
            encoding: encoding,
            width: frame.width,
            height: frame.height,
            lumaByteCount: frame.luma.count,
            chromaByteCount: frame.chroma.count,
            rawSHA256: rawSHA256,
            payloadByteCount: payload.count
        )
        let headerData = try R13RestartCanonical.data(header)
        guard headerData.count <= Self.maximumHeaderBytes,
              let headerByteCount = UInt32(exactly: headerData.count) else {
            throw R13NV12FrameCacheError.malformedArtifact
        }
        var artifact = Data(
            capacity: Self.magic.count
                + MemoryLayout<UInt32>.size
                + headerData.count
                + payload.count
        )
        artifact.append(Self.magic)
        appendBigEndian(headerByteCount, to: &artifact)
        artifact.append(headerData)
        artifact.append(payload)
        return R13EncodedNV12Frame(
            data: artifact,
            encoding: encoding,
            rawSHA256: rawSHA256
        )
    }

    func decode(_ artifact: Data) throws -> R13NV12Frame {
        let prefixByteCount = Self.magic.count + MemoryLayout<UInt32>.size
        guard artifact.count >= prefixByteCount,
              artifact.prefix(Self.magic.count) == Self.magic else {
            throw R13NV12FrameCacheError.malformedArtifact
        }
        let headerByteCount = Int(
            readBigEndianUInt32(
                artifact,
                offset: Self.magic.count
            )
        )
        guard headerByteCount > 0,
              headerByteCount <= Self.maximumHeaderBytes,
              prefixByteCount + headerByteCount <= artifact.count else {
            throw R13NV12FrameCacheError.malformedArtifact
        }
        let headerRange =
            prefixByteCount..<(prefixByteCount + headerByteCount)
        let headerData = artifact.subdata(in: headerRange)
        let header: R13NV12FrameCacheHeader
        do {
            header = try JSONDecoder().decode(
                R13NV12FrameCacheHeader.self,
                from: headerData
            )
        } catch {
            throw R13NV12FrameCacheError.malformedArtifact
        }
        guard try R13RestartCanonical.data(header) == headerData else {
            throw R13NV12FrameCacheError.malformedArtifact
        }
        guard header.schemaVersion
                == R13NV12FrameCacheHeader.currentSchemaVersion else {
            throw R13NV12FrameCacheError.unsupportedSchemaVersion(
                header.schemaVersion
            )
        }
        let counts = try R13NV12Frame.expectedPlaneByteCounts(
            width: header.width,
            height: header.height
        )
        guard header.lumaByteCount == counts.luma,
              header.chromaByteCount == counts.chroma else {
            throw R13NV12FrameCacheError.malformedArtifact
        }
        let payload = artifact.suffix(from: headerRange.upperBound)
        guard payload.count == header.payloadByteCount else {
            throw R13NV12FrameCacheError.malformedArtifact
        }
        let raw: Data
        switch header.encoding {
        case .raw:
            raw = Data(payload)
        case .lzfse:
            raw = try decodeLZFSE(Data(payload), outputByteCount: counts.total)
        }
        guard raw.count == counts.total,
              digest.sha256(raw) == header.rawSHA256 else {
            throw R13NV12FrameCacheError.rawPayloadHashMismatch
        }
        return try R13NV12Frame(
            width: header.width,
            height: header.height,
            luma: raw.prefix(counts.luma),
            chroma: raw.suffix(counts.chroma)
        )
    }

    static func maximumArtifactByteCount(
        width: Int,
        height: Int
    ) throws -> UInt64 {
        let counts = try R13NV12Frame.expectedPlaneByteCounts(
            width: width,
            height: height
        )
        let (maximum, overflow) = UInt64(counts.total).addingReportingOverflow(
            UInt64(maximumEnvelopeOverheadBytes)
        )
        guard !overflow else {
            throw R13NV12FrameCacheError.arithmeticOverflow
        }
        return maximum
    }

    private func encodeLZFSE(_ source: Data) -> Data? {
        let extraCapacity = max(65_536, source.count / 8)
        let (capacity, overflow) = source.count.addingReportingOverflow(
            extraCapacity
        )
        guard !overflow else { return nil }
        var destination = Data(count: capacity)
        let encodedByteCount = destination.withUnsafeMutableBytes { destinationBytes in
            source.withUnsafeBytes { sourceBytes in
                guard let destinationBase = destinationBytes.bindMemory(
                    to: UInt8.self
                ).baseAddress,
                let sourceBase = sourceBytes.bindMemory(
                    to: UInt8.self
                ).baseAddress else {
                    return 0
                }
                return compression_encode_buffer(
                    destinationBase,
                    capacity,
                    sourceBase,
                    source.count,
                    nil,
                    COMPRESSION_LZFSE
                )
            }
        }
        guard encodedByteCount > 0 else { return nil }
        destination.removeSubrange(encodedByteCount..<destination.count)
        return destination
    }

    private func decodeLZFSE(
        _ source: Data,
        outputByteCount: Int
    ) throws -> Data {
        var destination = Data(count: outputByteCount)
        let decodedByteCount = destination.withUnsafeMutableBytes { destinationBytes in
            source.withUnsafeBytes { sourceBytes in
                guard let destinationBase = destinationBytes.bindMemory(
                    to: UInt8.self
                ).baseAddress,
                let sourceBase = sourceBytes.bindMemory(
                    to: UInt8.self
                ).baseAddress else {
                    return 0
                }
                return compression_decode_buffer(
                    destinationBase,
                    outputByteCount,
                    sourceBase,
                    source.count,
                    nil,
                    COMPRESSION_LZFSE
                )
            }
        }
        guard decodedByteCount == outputByteCount else {
            throw R13NV12FrameCacheError.decompressionFailed
        }
        return destination
    }

    private func appendBigEndian(_ value: UInt32, to data: inout Data) {
        let bytes = [
            UInt8(truncatingIfNeeded: value >> 24),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value)
        ]
        data.append(contentsOf: bytes)
    }

    private func readBigEndianUInt32(
        _ data: Data,
        offset: Int
    ) -> UInt32 {
        data[offset..<(offset + 4)].reduce(UInt32(0)) {
            ($0 << 8) | UInt32($1)
        }
    }
}

private struct R13NV12FrameCacheHeader: Codable, Hashable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let encoding: R13FrameCacheEncoding
    let width: Int
    let height: Int
    let lumaByteCount: Int
    let chromaByteCount: Int
    let rawSHA256: String
    let payloadByteCount: Int
}
