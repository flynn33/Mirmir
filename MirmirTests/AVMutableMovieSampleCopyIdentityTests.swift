import AVFoundation
import CoreMedia
import CryptoKit
import Foundation
import XCTest
@testable import Mirmir

final class AVMutableMovieSampleCopyIdentityTests: XCTestCase {
    func testCopySampleDataPreservesCompressedVideoAccessUnitsByteForByte()
        async throws {
        let fixture = try MediaOutputFixture()
        defer { fixture.remove() }
        let videoURL = fixture.directory.appendingPathComponent("video.mp4")
        let audioURL = fixture.directory.appendingPathComponent("audio.m4a")

        try await writeMixedTimeScaleEditBoundaryVideo(
            to: videoURL,
            resolution: VideoResolution(width: 64, height: 64)
        )
        try writeAACFixture(to: audioURL, frameCount: 4_800)

        let sourceIdentity = try await CompressedVideoIdentityReader.read(
            url: videoURL
        )
        XCTAssertEqual(
            sourceIdentity.accessUnits.count,
            3,
            "The deterministic fixture must contain exactly three video access units."
        )
        XCTAssertGreaterThan(sourceIdentity.totalPayloadByteCount, 0)

        try await copyMuxWithExactTrackScales(
            videoURL: videoURL,
            audioURL: audioURL,
            destinationURL: fixture.destination
        )

        let muxedIdentity = try await CompressedVideoIdentityReader.read(
            url: fixture.destination
        )
        assertSameCompressedVideoIdentity(
            sourceIdentity,
            muxedIdentity
        )
    }
}

private func copyMuxWithExactTrackScales(
    videoURL: URL,
    audioURL: URL,
    destinationURL: URL
) async throws {
    let videoAsset = AVURLAsset(
        url: videoURL,
        options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
    )
    let audioAsset = AVURLAsset(
        url: audioURL,
        options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
    )
    let videoTracks = try await videoAsset.loadTracks(withMediaType: .video)
    let audioTracks = try await audioAsset.loadTracks(withMediaType: .audio)
    let videoTrack = try XCTUnwrap(videoTracks.first)
    let audioTrack = try XCTUnwrap(audioTracks.first)
    let videoTimeRange = try await videoTrack.load(.timeRange)
    let audioTimeRange = try await audioTrack.load(.timeRange)
    let videoTimeScale = try ExactVideoWriterTimeScale.resolve(
        naturalTimeScale: try await videoTrack.load(.naturalTimeScale),
        trackTimeRange: videoTimeRange
    )
    let audioTimeScale = try ExactVideoWriterTimeScale.resolve(
        naturalTimeScale: try await audioTrack.load(.naturalTimeScale),
        trackTimeRange: audioTimeRange
    )

    let movie = AVMutableMovie()
    movie.timescale = try ExactVideoWriterTimeScale.commonScale([
        videoTimeScale,
        audioTimeScale
    ])
    movie.defaultMediaDataStorage = AVMediaDataStorage(
        url: destinationURL,
        options: nil
    )
    let destinationVideoTrack = try XCTUnwrap(
        movie.addMutableTrack(
            withMediaType: .video,
            copySettingsFrom: videoTrack,
            options: nil
        )
    )
    let destinationAudioTrack = try XCTUnwrap(
        movie.addMutableTrack(
            withMediaType: .audio,
            copySettingsFrom: audioTrack,
            options: nil
        )
    )
    destinationVideoTrack.timescale = videoTimeScale
    destinationAudioTrack.timescale = audioTimeScale
    try destinationVideoTrack.insertTimeRange(
        videoTimeRange,
        of: videoTrack,
        at: videoTimeRange.start,
        copySampleData: true
    )
    try destinationAudioTrack.insertTimeRange(
        audioTimeRange,
        of: audioTrack,
        at: audioTimeRange.start,
        copySampleData: true
    )
    try movie.writeHeader(
        to: destinationURL,
        fileType: .mp4,
        options: .addMovieHeaderToDestination
    )
}

private struct CompressedVideoAccessUnit {
    let presentationTime: CMTime
    let decodeTime: CMTime
    let duration: CMTime
    let payload: Data

    var payloadSHA256: String {
        SHA256.hash(data: payload)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

private struct CompressedVideoIdentity {
    let trackTimeRange: CMTimeRange
    let accessUnits: [CompressedVideoAccessUnit]

    var totalPayloadByteCount: Int {
        accessUnits.reduce(0) { $0 + $1.payload.count }
    }

    var orderedPayloadSHA256: String {
        var hasher = SHA256()
        for accessUnit in accessUnits {
            var payloadSize = UInt64(accessUnit.payload.count).bigEndian
            withUnsafeBytes(of: &payloadSize) { bytes in
                hasher.update(bufferPointer: bytes)
            }
            hasher.update(data: accessUnit.payload)
        }
        return hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

private enum CompressedVideoIdentityFailure: Error {
    case expectedOneVideoTrack(Int)
    case cannotCreateReader(Error)
    case cannotAddReaderOutput
    case cannotStartReader(Error?)
    case readerFailed(AVAssetReader.Status, Error?)
    case emptyAccessUnit(Int)
    case missingPayload(Int)
    case invalidPayloadPartition(
        accessUnitIndex: Int,
        partitionBytes: Int,
        bufferBytes: Int
    )
    case timingReadFailed(Int, OSStatus)
    case payloadCopyFailed(Int, OSStatus)
    case noAccessUnits
}

private enum CompressedVideoIdentityReader {
    static func read(url: URL) async throws -> CompressedVideoIdentity {
        let asset = AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard tracks.count == 1, let track = tracks.first else {
            throw CompressedVideoIdentityFailure.expectedOneVideoTrack(
                tracks.count
            )
        }
        let trackTimeRange = try await track.load(.timeRange)
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw CompressedVideoIdentityFailure.cannotCreateReader(error)
        }
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: nil
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw CompressedVideoIdentityFailure.cannotAddReaderOutput
        }
        reader.add(output)
        guard reader.startReading() else {
            throw CompressedVideoIdentityFailure.cannotStartReader(
                reader.error
            )
        }

        var observedAccessUnits: [CompressedVideoAccessUnit] = []
        while let sampleBuffer = output.copyNextSampleBuffer() {
            observedAccessUnits.append(
                contentsOf: try accessUnits(
                    from: sampleBuffer,
                    startingAt: observedAccessUnits.count
                )
            )
        }
        guard reader.status == .completed else {
            throw CompressedVideoIdentityFailure.readerFailed(
                reader.status,
                reader.error
            )
        }
        guard !observedAccessUnits.isEmpty else {
            throw CompressedVideoIdentityFailure.noAccessUnits
        }
        return CompressedVideoIdentity(
            trackTimeRange: trackTimeRange,
            accessUnits: observedAccessUnits
        )
    }

    private static func accessUnits(
        from sampleBuffer: CMSampleBuffer,
        startingAt firstAccessUnitIndex: Int
    ) throws -> [CompressedVideoAccessUnit] {
        let sampleCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard sampleCount > 0 else {
            return []
        }
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            throw CompressedVideoIdentityFailure.missingPayload(
                firstAccessUnitIndex
            )
        }
        let bufferByteCount = CMBlockBufferGetDataLength(blockBuffer)
        var sampleByteCounts: [Int] = []
        sampleByteCounts.reserveCapacity(sampleCount)
        var partitionByteCount = 0
        for sampleIndex in 0..<sampleCount {
            let accessUnitIndex = firstAccessUnitIndex + sampleIndex
            let sampleByteCount = CMSampleBufferGetSampleSize(
                sampleBuffer,
                at: sampleIndex
            )
            guard sampleByteCount > 0 else {
                throw CompressedVideoIdentityFailure.emptyAccessUnit(
                    accessUnitIndex
                )
            }
            let (nextPartitionByteCount, overflowed) =
                partitionByteCount.addingReportingOverflow(sampleByteCount)
            guard !overflowed else {
                throw CompressedVideoIdentityFailure.invalidPayloadPartition(
                    accessUnitIndex: accessUnitIndex,
                    partitionBytes: partitionByteCount,
                    bufferBytes: bufferByteCount
                )
            }
            partitionByteCount = nextPartitionByteCount
            sampleByteCounts.append(sampleByteCount)
        }
        guard partitionByteCount == bufferByteCount else {
            throw CompressedVideoIdentityFailure.invalidPayloadPartition(
                accessUnitIndex: firstAccessUnitIndex,
                partitionBytes: partitionByteCount,
                bufferBytes: bufferByteCount
            )
        }

        var accessUnits: [CompressedVideoAccessUnit] = []
        accessUnits.reserveCapacity(sampleCount)
        var payloadOffset = 0
        for sampleIndex in 0..<sampleCount {
            let accessUnitIndex = firstAccessUnitIndex + sampleIndex
            var timing = CMSampleTimingInfo()
            let timingStatus = CMSampleBufferGetSampleTimingInfo(
                sampleBuffer,
                at: sampleIndex,
                timingInfoOut: &timing
            )
            guard timingStatus == noErr else {
                throw CompressedVideoIdentityFailure.timingReadFailed(
                    accessUnitIndex,
                    timingStatus
                )
            }

            let sampleByteCount = sampleByteCounts[sampleIndex]
            var payload = Data(count: sampleByteCount)
            let payloadStatus: OSStatus = payload.withUnsafeMutableBytes { bytes in
                guard let destination = bytes.baseAddress else {
                    return kCMBlockBufferBadPointerParameterErr
                }
                return CMBlockBufferCopyDataBytes(
                    blockBuffer,
                    atOffset: payloadOffset,
                    dataLength: sampleByteCount,
                    destination: destination
                )
            }
            guard payloadStatus == kCMBlockBufferNoErr else {
                throw CompressedVideoIdentityFailure.payloadCopyFailed(
                    accessUnitIndex,
                    payloadStatus
                )
            }
            accessUnits.append(
                CompressedVideoAccessUnit(
                    presentationTime: timing.presentationTimeStamp,
                    decodeTime: timing.decodeTimeStamp,
                    duration: timing.duration,
                    payload: payload
                )
            )
            payloadOffset += sampleByteCount
        }
        return accessUnits
    }
}

private func assertSameCompressedVideoIdentity(
    _ expected: CompressedVideoIdentity,
    _ actual: CompressedVideoIdentity,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    assertSameMediaTime(
        expected.trackTimeRange.start,
        actual.trackTimeRange.start,
        label: "track start",
        file: file,
        line: line
    )
    assertSameMediaTime(
        expected.trackTimeRange.duration,
        actual.trackTimeRange.duration,
        label: "track duration",
        file: file,
        line: line
    )
    XCTAssertEqual(
        actual.accessUnits.count,
        expected.accessUnits.count,
        "Compressed video access-unit count changed.",
        file: file,
        line: line
    )
    XCTAssertEqual(
        actual.totalPayloadByteCount,
        expected.totalPayloadByteCount,
        "Compressed video payload byte count changed.",
        file: file,
        line: line
    )
    XCTAssertEqual(
        actual.orderedPayloadSHA256,
        expected.orderedPayloadSHA256,
        "Ordered compressed video payload SHA-256 changed.",
        file: file,
        line: line
    )
    guard actual.accessUnits.count == expected.accessUnits.count else {
        return
    }
    for (index, pair) in zip(
        expected.accessUnits,
        actual.accessUnits
    ).enumerated() {
        let expectedAccessUnit = pair.0
        let actualAccessUnit = pair.1
        assertSameMediaTime(
            expectedAccessUnit.presentationTime,
            actualAccessUnit.presentationTime,
            label: "access unit \(index) presentation time",
            file: file,
            line: line
        )
        assertSameMediaTime(
            expectedAccessUnit.decodeTime,
            actualAccessUnit.decodeTime,
            label: "access unit \(index) decode time",
            file: file,
            line: line
        )
        assertSameMediaTime(
            expectedAccessUnit.duration,
            actualAccessUnit.duration,
            label: "access unit \(index) duration",
            file: file,
            line: line
        )
        XCTAssertEqual(
            actualAccessUnit.payload.count,
            expectedAccessUnit.payload.count,
            "Access unit \(index) payload byte count changed.",
            file: file,
            line: line
        )
        XCTAssertEqual(
            actualAccessUnit.payloadSHA256,
            expectedAccessUnit.payloadSHA256,
            "Access unit \(index) payload SHA-256 changed.",
            file: file,
            line: line
        )
        XCTAssertEqual(
            actualAccessUnit.payload,
            expectedAccessUnit.payload,
            "Access unit \(index) payload bytes changed.",
            file: file,
            line: line
        )
    }
}

private func assertSameMediaTime(
    _ expected: CMTime,
    _ actual: CMTime,
    label: String,
    file: StaticString,
    line: UInt
) {
    XCTAssertEqual(
        actual.isValid,
        expected.isValid,
        "\(label) validity changed.",
        file: file,
        line: line
    )
    guard expected.isValid, actual.isValid else {
        return
    }
    XCTAssertEqual(
        actual.isNumeric,
        expected.isNumeric,
        "\(label) numeric state changed.",
        file: file,
        line: line
    )
    XCTAssertEqual(
        actual.isIndefinite,
        expected.isIndefinite,
        "\(label) indefinite state changed.",
        file: file,
        line: line
    )
    XCTAssertEqual(
        actual.isPositiveInfinity,
        expected.isPositiveInfinity,
        "\(label) positive-infinity state changed.",
        file: file,
        line: line
    )
    XCTAssertEqual(
        actual.isNegativeInfinity,
        expected.isNegativeInfinity,
        "\(label) negative-infinity state changed.",
        file: file,
        line: line
    )
    XCTAssertEqual(
        actual.epoch,
        expected.epoch,
        "\(label) epoch changed.",
        file: file,
        line: line
    )
    if expected.isNumeric, actual.isNumeric {
        XCTAssertEqual(
            CMTimeCompare(actual, expected),
            0,
            "\(label) changed from \(expected) to \(actual).",
            file: file,
            line: line
        )
    }
}
