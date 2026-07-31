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

enum R13CachedPixelFormat {
    static let supported =
        R13PixelLayoutRegistry.supportedPixelFormats

    static func fourCC(_ pixelFormat: OSType) throws -> String {
        guard supported.contains(pixelFormat) else {
            throw R13NV12FrameCacheError.unsupportedPixelFormat(
                pixelFormat
            )
        }
        let bytes = [
            UInt8(truncatingIfNeeded: pixelFormat >> 24),
            UInt8(truncatingIfNeeded: pixelFormat >> 16),
            UInt8(truncatingIfNeeded: pixelFormat >> 8),
            UInt8(truncatingIfNeeded: pixelFormat)
        ]
        guard let value = String(
            bytes: bytes,
            encoding: .macOSRoman
        ) else {
            throw R13NV12FrameCacheError.unsupportedPixelFormat(
                pixelFormat
            )
        }
        return value
    }

    static func pixelFormat(
        _ fourCC: String?
    ) throws -> OSType {
        let value = fourCC
            ?? R13RestartOutputIdentity.nv12VideoRangePixelFormat
        let bytes = Array(value.utf8)
        guard bytes.count == 4 else {
            throw R13RestartJobError.invalidPixelFormat(value)
        }
        let pixelFormat =
            OSType(bytes[0]) << 24
            | OSType(bytes[1]) << 16
            | OSType(bytes[2]) << 8
            | OSType(bytes[3])
        guard supported.contains(pixelFormat) else {
            throw R13RestartJobError.invalidPixelFormat(value)
        }
        return pixelFormat
    }
}

struct R13NV12PlaneByteCounts: Equatable, Sendable {
    let luma: Int
    let chroma: Int
    let auxiliary: [Int]
    let total: Int

    var all: [Int] {
        [luma, chroma] + auxiliary
    }
}

struct R13NV12Frame: Equatable, Sendable {
    static let maximumRawByteCount = 512 * 1_024 * 1_024

    let width: Int
    let height: Int
    let pixelFormat: OSType
    let luma: Data
    let chroma: Data
    let auxiliaryPlanes: [Data]

    init(
        width: Int,
        height: Int,
        pixelFormat: OSType =
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        luma: Data,
        chroma: Data,
        auxiliaryPlanes: [Data] = []
    ) throws {
        let counts = try Self.expectedPlaneByteCounts(
            width: width,
            height: height,
            pixelFormat: pixelFormat
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
        guard auxiliaryPlanes.count == counts.auxiliary.count else {
            throw R13NV12FrameCacheError.invalidPlaneByteCount(
                plane: "auxiliary_plane_count",
                expected: counts.auxiliary.count,
                actual: auxiliaryPlanes.count
            )
        }
        for index in auxiliaryPlanes.indices
        where auxiliaryPlanes[index].count != counts.auxiliary[index] {
            throw R13NV12FrameCacheError.invalidPlaneByteCount(
                plane: "auxiliary_\(index)",
                expected: counts.auxiliary[index],
                actual: auxiliaryPlanes[index].count
            )
        }
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat
        self.luma = luma
        self.chroma = chroma
        self.auxiliaryPlanes = auxiliaryPlanes
    }

    static func expectedPlaneByteCounts(
        width: Int,
        height: Int,
        pixelFormat: OSType =
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    ) throws -> R13NV12PlaneByteCounts {
        guard width > 0, height > 0 else {
            throw R13NV12FrameCacheError.invalidGeometry(
                width: width,
                height: height
            )
        }
        let layout: R13PixelLayout
        let planeCounts: [Int]
        do {
            layout = try R13PixelLayoutRegistry.layout(
                for: pixelFormat
            )
            planeCounts = try layout.activePlaneByteCounts(
                width: width,
                height: height
            )
        } catch R13PixelLayoutError.unsupportedPixelFormat {
            throw R13NV12FrameCacheError.unsupportedPixelFormat(
                pixelFormat
            )
        } catch R13PixelLayoutError.invalidGeometry {
            throw R13NV12FrameCacheError.invalidGeometry(
                width: width,
                height: height
            )
        } catch {
            throw R13NV12FrameCacheError.arithmeticOverflow
        }
        guard let luma = planeCounts.first else {
            throw R13NV12FrameCacheError.unsupportedPixelFormat(
                pixelFormat
            )
        }
        let chroma = planeCounts.count > 1 ? planeCounts[1] : 0
        let auxiliary =
            planeCounts.count > 2
            ? Array(planeCounts.dropFirst(2))
            : []
        var total = 0
        for count in [luma, chroma] + auxiliary {
            let (nextTotal, overflow) =
                total.addingReportingOverflow(count)
            guard !overflow else {
                throw R13NV12FrameCacheError.arithmeticOverflow
            }
            total = nextTotal
        }
        guard
              total <= maximumRawByteCount else {
            throw R13NV12FrameCacheError.arithmeticOverflow
        }
        return R13NV12PlaneByteCounts(
            luma: luma,
            chroma: chroma,
            auxiliary: auxiliary,
            total: total
        )
    }

    var tightRawData: Data {
        var data = Data(capacity: luma.count + chroma.count)
        data.append(luma)
        data.append(chroma)
        for plane in auxiliaryPlanes {
            data.append(plane)
        }
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
            pixelFormat: frame.pixelFormat,
            lumaByteCount: frame.luma.count,
            chromaByteCount: frame.chroma.count,
            auxiliaryPlaneByteCounts:
                frame.auxiliaryPlanes.map(\.count),
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
        guard (1...R13NV12FrameCacheHeader.currentSchemaVersion)
            .contains(header.schemaVersion) else {
            throw R13NV12FrameCacheError.unsupportedSchemaVersion(
                header.schemaVersion
            )
        }
        let pixelFormat = header.pixelFormat
            ?? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let counts = try R13NV12Frame.expectedPlaneByteCounts(
            width: header.width,
            height: header.height,
            pixelFormat: pixelFormat
        )
        guard header.lumaByteCount == counts.luma,
              header.chromaByteCount == counts.chroma,
              (header.auxiliaryPlaneByteCounts ?? [])
                == counts.auxiliary else {
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
        var rawOffset = 0
        let luma = raw.subdata(
            in: rawOffset..<(rawOffset + counts.luma)
        )
        rawOffset += counts.luma
        let chroma = raw.subdata(
            in: rawOffset..<(rawOffset + counts.chroma)
        )
        rawOffset += counts.chroma
        var auxiliaryPlanes: [Data] = []
        auxiliaryPlanes.reserveCapacity(counts.auxiliary.count)
        for byteCount in counts.auxiliary {
            auxiliaryPlanes.append(
                raw.subdata(
                    in: rawOffset..<(rawOffset + byteCount)
                )
            )
            rawOffset += byteCount
        }
        guard rawOffset == raw.count else {
            throw R13NV12FrameCacheError.malformedArtifact
        }
        return try R13NV12Frame(
            width: header.width,
            height: header.height,
            pixelFormat: pixelFormat,
            luma: luma,
            chroma: chroma,
            auxiliaryPlanes: auxiliaryPlanes
        )
    }

    static func maximumArtifactByteCount(
        width: Int,
        height: Int,
        pixelFormat: OSType =
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    ) throws -> UInt64 {
        let counts = try R13NV12Frame.expectedPlaneByteCounts(
            width: width,
            height: height,
            pixelFormat: pixelFormat
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
    static let currentSchemaVersion = 3

    let schemaVersion: Int
    let encoding: R13FrameCacheEncoding
    let width: Int
    let height: Int
    let pixelFormat: OSType?
    let lumaByteCount: Int
    let chromaByteCount: Int
    let auxiliaryPlaneByteCounts: [Int]?
    let rawSHA256: String
    let payloadByteCount: Int
}
