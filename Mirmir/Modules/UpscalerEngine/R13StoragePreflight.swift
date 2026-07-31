import CoreVideo
import Foundation

struct R13CanonicalCacheDisclosure: Equatable, Sendable {
    let width: Int
    let height: Int
    let framesPerSecond: Int
    let durationSeconds: Int
    let rawNV12ByteCount: UInt64

    var binaryGiB: Double {
        Double(rawNV12ByteCount) / 1_073_741_824
    }
}

enum R13StorageDisclosures {
    static let p1080At30FPSForOneMinute = R13CanonicalCacheDisclosure(
        width: 1_920,
        height: 1_080,
        framesPerSecond: 30,
        durationSeconds: 60,
        rawNV12ByteCount: 5_598_720_000
    )
    static let p2160At30FPSForOneMinute = R13CanonicalCacheDisclosure(
        width: 3_840,
        height: 2_160,
        framesPerSecond: 30,
        durationSeconds: 60,
        rawNV12ByteCount: 22_394_880_000
    )

    static func canonicalOneMinute(
        width: Int,
        height: Int
    ) throws -> R13CanonicalCacheDisclosure {
        let framesPerSecond = 30
        let durationSeconds = 60
        let counts = try R13NV12Frame.expectedPlaneByteCounts(
            width: width,
            height: height
        )
        let frameCount = framesPerSecond * durationSeconds
        let (rawNV12ByteCount, overflow) = UInt64(counts.total)
            .multipliedReportingOverflow(by: UInt64(frameCount))
        guard !overflow else {
            throw R13RestartJobError.arithmeticOverflow(
                field: "canonical_cache_disclosure"
            )
        }
        return R13CanonicalCacheDisclosure(
            width: width,
            height: height,
            framesPerSecond: framesPerSecond,
            durationSeconds: durationSeconds,
            rawNV12ByteCount: rawNV12ByteCount
        )
    }
}

struct R13StoragePreflightRequest: Equatable, Sendable {
    let outputWidth: Int
    let outputHeight: Int
    let pixelFormat: OSType
    let totalFrameCount: Int
    let expectedFinalOutputBytes: UInt64
    let additionalReserveBytes: UInt64

    init(
        outputWidth: Int,
        outputHeight: Int,
        pixelFormat: OSType =
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        totalFrameCount: Int,
        expectedFinalOutputBytes: UInt64,
        additionalReserveBytes: UInt64
    ) throws {
        _ = try R13NV12Frame.expectedPlaneByteCounts(
            width: outputWidth,
            height: outputHeight,
            pixelFormat: pixelFormat
        )
        guard totalFrameCount > 0 else {
            throw R13RestartJobError.invalidFrameCount(totalFrameCount)
        }
        guard expectedFinalOutputBytes > 0 else {
            throw R13RestartJobError.invalidByteCount(
                field: "expected_final_output_bytes"
            )
        }
        self.outputWidth = outputWidth
        self.outputHeight = outputHeight
        self.pixelFormat = pixelFormat
        self.totalFrameCount = totalFrameCount
        self.expectedFinalOutputBytes = expectedFinalOutputBytes
        self.additionalReserveBytes = additionalReserveBytes
    }
}

struct R13StoragePreflightReceipt: Equatable, Sendable {
    let availableBytes: UInt64
    let rawCacheBytes: UInt64
    let cacheReservationBytesPerFrame: UInt64
    let worstCaseCacheArtifactBytes: UInt64
    let recordAndManifestBytes: UInt64
    let expectedFinalOutputBytes: UInt64
    let additionalReserveBytes: UInt64
    let requiredBytes: UInt64
}

protocol R13AvailableCapacityProbing: Sendable {
    func availableCapacityForImportantUsage(at url: URL) throws -> UInt64
}

protocol R13VolumeTopologyProbing: Sendable {
    func sharesVolume(_ lhs: URL, _ rhs: URL) throws -> Bool
}

struct R13FoundationVolumeTopologyProbe: R13VolumeTopologyProbing {
    func sharesVolume(_ lhs: URL, _ rhs: URL) throws -> Bool {
        let lhsIdentifier = try volumeIdentifier(at: lhs)
        return lhsIdentifier.isEqual(try volumeIdentifier(at: rhs))
    }

    private func volumeIdentifier(
        at url: URL
    ) throws -> any NSObjectProtocol {
        let resolved = R13RestartPath.resolvingExistingAncestor(of: url)
        let values: URLResourceValues
        do {
            values = try resolved.resourceValues(
                forKeys: [.volumeIdentifierKey]
            )
        } catch {
            throw R13RestartJobError.ioFailure(
                operation: "volume_topology"
            )
        }
        guard let identifier = values.volumeIdentifier else {
            throw R13RestartJobError.ioFailure(
                operation: "volume_topology"
            )
        }
        return identifier
    }
}

struct R13FoundationAvailableCapacityProbe: R13AvailableCapacityProbing {
    func availableCapacityForImportantUsage(at url: URL) throws -> UInt64 {
        let values: URLResourceValues
        do {
            values = try url.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey]
            )
        } catch {
            throw R13RestartJobError.ioFailure(
                operation: "available_capacity"
            )
        }
        guard let capacity = values.volumeAvailableCapacityForImportantUsage,
              capacity >= 0 else {
            throw R13RestartJobError.ioFailure(
                operation: "available_capacity"
            )
        }
        return UInt64(capacity)
    }
}

struct R13StoragePreflight: Sendable {
    private static let maximumRecordBytesPerFrame: UInt64 = 4_096
    private static let fixedManifestBytes: UInt64 = 256 * 1_024

    private let capacityProbe: any R13AvailableCapacityProbing
    private let volumeTopologyProbe: any R13VolumeTopologyProbing

    init(
        capacityProbe: any R13AvailableCapacityProbing =
            R13FoundationAvailableCapacityProbe(),
        volumeTopologyProbe: any R13VolumeTopologyProbing =
            R13FoundationVolumeTopologyProbe()
    ) {
        self.capacityProbe = capacityProbe
        self.volumeTopologyProbe = volumeTopologyProbe
    }

    func sharesVolume(_ lhs: URL, _ rhs: URL) throws -> Bool {
        try volumeTopologyProbe.sharesVolume(lhs, rhs)
    }

    func evaluate(
        _ request: R13StoragePreflightRequest,
        at jobStorageURL: URL
    ) throws -> R13StoragePreflightReceipt {
        let counts = try R13NV12Frame.expectedPlaneByteCounts(
            width: request.outputWidth,
            height: request.outputHeight,
            pixelFormat: request.pixelFormat
        )
        let frameCount = UInt64(request.totalFrameCount)
        let rawCacheBytes = try checkedMultiply(
            UInt64(counts.total),
            frameCount,
            field: "raw_cache_bytes"
        )
        let maximumArtifactBytes =
            try R13LZFSEFrameCacheCodec.maximumArtifactByteCount(
                width: request.outputWidth,
                height: request.outputHeight,
                pixelFormat: request.pixelFormat
            )
        let cacheReservationBytesPerFrame = try checkedAdd(
            maximumArtifactBytes,
            Self.maximumRecordBytesPerFrame,
            field: "cache_reservation_bytes_per_frame"
        )
        let worstCaseCacheArtifactBytes = try checkedMultiply(
            maximumArtifactBytes,
            frameCount,
            field: "worst_case_cache_artifact_bytes"
        )
        let records = try checkedMultiply(
            Self.maximumRecordBytesPerFrame,
            frameCount,
            field: "record_bytes"
        )
        let recordAndManifestBytes = try checkedAdd(
            records,
            Self.fixedManifestBytes,
            field: "record_and_manifest_bytes"
        )
        var requiredBytes = try checkedAdd(
            worstCaseCacheArtifactBytes,
            recordAndManifestBytes,
            field: "required_bytes"
        )
        requiredBytes = try checkedAdd(
            requiredBytes,
            request.expectedFinalOutputBytes,
            field: "required_bytes"
        )
        requiredBytes = try checkedAdd(
            requiredBytes,
            request.additionalReserveBytes,
            field: "required_bytes"
        )
        let availableBytes = try capacityProbe
            .availableCapacityForImportantUsage(at: jobStorageURL)
        guard availableBytes >= requiredBytes else {
            throw R13RestartJobError.insufficientDiskSpace(
                requiredBytes: requiredBytes,
                availableBytes: availableBytes
            )
        }
        return R13StoragePreflightReceipt(
            availableBytes: availableBytes,
            rawCacheBytes: rawCacheBytes,
            cacheReservationBytesPerFrame: cacheReservationBytesPerFrame,
            worstCaseCacheArtifactBytes: worstCaseCacheArtifactBytes,
            recordAndManifestBytes: recordAndManifestBytes,
            expectedFinalOutputBytes: request.expectedFinalOutputBytes,
            additionalReserveBytes: request.additionalReserveBytes,
            requiredBytes: requiredBytes
        )
    }

    private func checkedMultiply(
        _ lhs: UInt64,
        _ rhs: UInt64,
        field: String
    ) throws -> UInt64 {
        let (result, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        guard !overflow else {
            throw R13RestartJobError.arithmeticOverflow(field: field)
        }
        return result
    }

    private func checkedAdd(
        _ lhs: UInt64,
        _ rhs: UInt64,
        field: String
    ) throws -> UInt64 {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else {
            throw R13RestartJobError.arithmeticOverflow(field: field)
        }
        return result
    }
}
