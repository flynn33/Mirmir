import AVFoundation
import CoreMedia
import CoreVideo
import CryptoKit
import Darwin
import Foundation

private enum AdapterSelfTestFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): message
        }
    }
}

@main
enum AVCanonicalMediaStateAdapterV4SelfTestMain {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AVCanonicalMediaStateAdapterV4-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: root) }

        try exactValueChecks(root: root)
        let assetURL = root.appendingPathComponent("adversarial.mov")
        try await makeAdversarialAsset(at: assetURL)

        let bookmarkHash = try ASHSHA256V4(
            String(repeating: "7", count: 64)
        )
        let request = AVCanonicalMediaStateProbeRequestV4(
            url: assetURL,
            bookmarkReference: "adapter-self-test",
            bookmarkDocumentSHA256: bookmarkHash
        )
        let adapter = AVCanonicalMediaStateAdapterV4()
        let first = try await adapter.probe(request)
        let second = try await adapter.probe(request)
        try require(
            first.state == second.state,
            "repeated probes produced different canonical states"
        )
        try require(
            try first.state.canonicalSHA256 == second.state.canonicalSHA256,
            "repeated probes produced different canonical hashes"
        )

        let physicalTracks = first.state.tracks.filter {
            $0.identity.persistentID.hasPrefix("asset-track-")
        }
        try require(physicalTracks.count == 2, "expected two physical tracks")
        try require(
            physicalTracks.map(\.identity.ordinal) == [0, 1],
            "AVFoundation source order was not preserved"
        )
        try require(
            physicalTracks.map(\.kind) == [.video, .video],
            "video track classification changed"
        )
        try require(
            physicalTracks.map(\.enabled) == [true, false],
            "enabled and disabled track states were not preserved"
        )
        for track in physicalTracks {
            guard let video = track.video else {
                throw AdapterSelfTestFailure.failed("video state was absent")
            }
            try require(
                video.encodedRaster == CanonicalRasterV4(width: 64, height: 48),
                "coded raster changed"
            )
            try require(
                video.presentationRaster
                    == CanonicalRasterV4(width: 40, height: 64),
                "clean-aperture/SAR/transform composition was not exact"
            )
            try require(
                video.pixelAspectRatio == ExactRationalV4(4, 3),
                "sample aspect ratio changed"
            )
            try require(
                video.cleanAperture?.size.width == ExactRationalV4(48),
                "clean-aperture width changed"
            )
            try require(
                video.cleanAperture?.size.height == ExactRationalV4(40),
                "clean-aperture height changed"
            )
            try require(
                track.metadata.contains {
                    $0.key.hasPrefix("format-description-")
                },
                "format-description identity was not captured"
            )
            try require(
                track.metadata.contains { $0.key.hasPrefix("segment-mapping-") },
                "edit-list identity was not captured"
            )
        }

        let digest = try first.state.canonicalSHA256
        print(
            "AV canonical media state v4 self-test passed: "
                + "hash=\(digest.rawValue) admission=\(first.admission.rawValue) "
                + "observations=\(first.state.observations.count)"
        )
    }

    private static func exactValueChecks(root: URL) throws {
        try require(
            ASHExactBinaryRationalV4.convert(0.5, path: "half")
                == ExactRationalV4(1, 2),
            "binary rational conversion rounded 0.5"
        )
        do {
            _ = try ASHExactBinaryRationalV4.convert(Double.nan, path: "nan")
            throw AdapterSelfTestFailure.failed("NaN geometry was accepted")
        } catch is AVCanonicalMediaStateAdapterV4Error {}

        let inputURL = root.appendingPathComponent("streaming-hash.bin")
        let bytes = Data((0..<131_071).map { UInt8(truncatingIfNeeded: $0) })
        try bytes.write(to: inputURL)
        let one = try ASHStreamingFileIdentityV4.read(
            url: inputURL,
            chunkByteCount: 1
        )
        let blocked = try ASHStreamingFileIdentityV4.read(
            url: inputURL,
            chunkByteCount: 4_093
        )
        try require(one == blocked, "streaming hash depends on chunk boundaries")
        try require(
            one.contentSHA256 == ASHSHA256V4(rawData: bytes),
            "streaming SHA-256 differs from the reference digest"
        )

        let symlinkURL = root.appendingPathComponent("streaming-hash-link.bin")
        try FileManager.default.createSymbolicLink(
            at: symlinkURL,
            withDestinationURL: inputURL
        )
        try require(
            try ASHStreamingFileIdentityV4.read(url: symlinkURL).contentSHA256
                == one.contentSHA256,
            "a stable symlink did not resolve to the same content identity"
        )

        let firstProperty: NSDictionary = [
            "z": Data([1, 2, 3]),
            "a": [NSNumber(value: 1), NSNumber(value: 0.5)]
        ]
        let secondProperty = NSMutableDictionary()
        secondProperty["a"] = [NSNumber(value: 1), NSNumber(value: 0.5)]
        secondProperty["z"] = Data([1, 2, 3])
        try require(
            ASHCanonicalPropertyListV4.data(firstProperty, path: "first")
                == ASHCanonicalPropertyListV4.data(
                    secondProperty,
                    path: "second"
                ),
            "dictionary insertion order changed canonical property identity"
        )
    }

    private static func makeAdversarialAsset(at url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 64,
            AVVideoHeightKey: 48,
            AVVideoPixelAspectRatioKey: [
                AVVideoPixelAspectRatioHorizontalSpacingKey: 4,
                AVVideoPixelAspectRatioVerticalSpacingKey: 3
            ],
            AVVideoCleanApertureKey: [
                AVVideoCleanApertureWidthKey: 48,
                AVVideoCleanApertureHeightKey: 40,
                AVVideoCleanApertureHorizontalOffsetKey: 0,
                AVVideoCleanApertureVerticalOffsetKey: 0
            ],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ]
        ]
        let transform = CGAffineTransform(
            a: 0,
            b: 1,
            c: -1,
            d: 0,
            tx: 40,
            ty: 0
        )
        var inputs: [AVAssetWriterInput] = []
        var adaptors: [AVAssetWriterInputPixelBufferAdaptor] = []
        for ordinal in 0..<2 {
            let input = AVAssetWriterInput(
                mediaType: .video,
                outputSettings: settings
            )
            input.expectsMediaDataInRealTime = false
            input.transform = transform
            input.marksOutputTrackAsEnabled = ordinal == 0
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String:
                        Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
                    kCVPixelBufferWidthKey as String: 64,
                    kCVPixelBufferHeightKey as String: 48,
                    kCVPixelBufferIOSurfacePropertiesKey as String: [:]
                ]
            )
            guard writer.canAdd(input) else {
                throw AdapterSelfTestFailure.failed(
                    "writer rejected video input \(ordinal)"
                )
            }
            writer.add(input)
            inputs.append(input)
            adaptors.append(adaptor)
        }
        guard writer.startWriting() else {
            throw AdapterSelfTestFailure.failed(
                writer.error.map(String.init(describing:))
                    ?? "writer failed to start"
            )
        }
        writer.startSession(atSourceTime: .zero)
        let times = [
            CMTime(value: 0, timescale: 30_000),
            CMTime(value: 1_001, timescale: 30_000)
        ]
        for (frameOrdinal, time) in times.enumerated() {
            for trackOrdinal in inputs.indices {
                try await waitUntilReady(inputs[trackOrdinal], writer: writer)
                guard let pool = adaptors[trackOrdinal].pixelBufferPool else {
                    throw AdapterSelfTestFailure.failed("pixel-buffer pool absent")
                }
                var pixelBuffer: CVPixelBuffer?
                let status = CVPixelBufferPoolCreatePixelBuffer(
                    nil,
                    pool,
                    &pixelBuffer
                )
                guard status == kCVReturnSuccess, let pixelBuffer else {
                    throw AdapterSelfTestFailure.failed(
                        "pixel-buffer allocation failed: \(status)"
                    )
                }
                fill(
                    pixelBuffer,
                    luma: UInt8(32 + frameOrdinal * 16 + trackOrdinal)
                )
                guard adaptors[trackOrdinal].append(
                    pixelBuffer,
                    withPresentationTime: time
                ) else {
                    throw AdapterSelfTestFailure.failed(
                        writer.error.map(String.init(describing:))
                            ?? "writer rejected frame"
                    )
                }
            }
        }
        inputs.forEach { $0.markAsFinished() }
        writer.endSession(atSourceTime: CMTime(value: 2_002, timescale: 30_000))
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else {
            throw AdapterSelfTestFailure.failed(
                writer.error.map(String.init(describing:))
                    ?? "writer did not complete"
            )
        }
    }

    private static func waitUntilReady(
        _ input: AVAssetWriterInput,
        writer: AVAssetWriter
    ) async throws {
        while !input.isReadyForMoreMediaData {
            guard writer.status != .failed else {
                throw AdapterSelfTestFailure.failed(
                    writer.error.map(String.init(describing:))
                        ?? "writer failed while waiting for readiness"
                )
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private static func fill(_ buffer: CVPixelBuffer, luma: UInt8) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)
            else { continue }
            let value = plane == 0 ? luma : 128
            memset(
                base,
                Int32(value),
                CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
                    * CVPixelBufferGetHeightOfPlane(buffer, plane)
            )
        }
    }

    private static func require(
        _ condition: @autoclosure () throws -> Bool,
        _ message: String
    ) throws {
        guard try condition() else {
            throw AdapterSelfTestFailure.failed(message)
        }
    }
}
