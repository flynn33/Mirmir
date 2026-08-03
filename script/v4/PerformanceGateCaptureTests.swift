import AVFoundation
import CoreMedia
import CoreVideo
import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import Mirmir

/// Injected into an ephemeral P05 or v4 Release test target by the performance
/// runner. Keeping this source outside the project prevents measurement code
/// from entering the shipping binary while its SHA-256 remains contract-locked.
@available(macOS 15.4, *)
final class DeterministicEngineV4PerformanceCaptureTests: XCTestCase {
    // The runner replaces these sentinels only in each ephemeral source copy.
    // Environment lookup remains as a direct-development fallback.
    private static let injectedEnvironment = [
        "MIRMIR_V4_PERFORMANCE_CAPTURE_DIR":
            "__MIRMIR_V4_PERFORMANCE_CAPTURE_DIR__",
        "MIRMIR_V4_PERFORMANCE_INPUT":
            "__MIRMIR_V4_PERFORMANCE_INPUT__",
        "MIRMIR_V4_PERFORMANCE_VARIANT":
            "__MIRMIR_V4_PERFORMANCE_VARIANT__",
        "MIRMIR_V4_PERFORMANCE_CONTRACT_SHA256":
            "__MIRMIR_V4_PERFORMANCE_CONTRACT_SHA256__",
        "MIRMIR_V4_PERFORMANCE_CAPTURE_SOURCE_SHA256":
            "__MIRMIR_V4_PERFORMANCE_CAPTURE_SOURCE_SHA256__",
        "MIRMIR_V4_PERFORMANCE_SOURCE_IDENTITY_SHA256":
            "__MIRMIR_V4_PERFORMANCE_SOURCE_IDENTITY_SHA256__",
        "MIRMIR_V4_PERFORMANCE_SOURCE_REVISION":
            "__MIRMIR_V4_PERFORMANCE_SOURCE_REVISION__",
        "MIRMIR_V4_PERFORMANCE_SOURCE_TREE_SHA256":
            "__MIRMIR_V4_PERFORMANCE_SOURCE_TREE_SHA256__",
        "MIRMIR_V4_PERFORMANCE_WARMUPS":
            "__MIRMIR_V4_PERFORMANCE_WARMUPS__",
        "MIRMIR_V4_PERFORMANCE_SAMPLES":
            "__MIRMIR_V4_PERFORMANCE_SAMPLES__"
    ]

    private struct BenchmarkCase: Codable, Sendable {
        let id: String
        let backendID: String
        let targetWidth: Int
        let targetHeight: Int

        var backend: UpscaleBackendID {
            switch backendID {
            case UpscaleBackendID.mirmirDeterministicCPU.rawValue:
                .mirmirDeterministicCPU
            case UpscaleBackendID.mirmirDeterministicMetal.rawValue:
                .mirmirDeterministicMetal
            default:
                preconditionFailure("unrecognized locked backend \(backendID)")
            }
        }
    }

    private struct InputIdentity: Codable {
        let sha256: String
        let byteCount: Int
        let width: Int
        let height: Int
        let codecFourCC: String
        let frameCount: Int
        let trackCount: Int
        let enabledVideoTrackCount: Int
        let durationNumerator: Int
        let durationTimescale: Int
        let allRequiredChecksPassed: Bool
    }

    private struct RequestIdentity: Codable {
        let codec: String
        let fileType: String
        let preserveAudio: Bool
        let overwriteExistingFile: Bool
    }

    private struct EngineRun: Codable {
        let sampleIndex: Int
        let frameMilliseconds: [Double]
        let processedFrameCount: Int
    }

    private struct Verification: Codable {
        let requestedBackendExecutedWithoutFallback: Bool
        let allInputTracksAccounted: Bool
        let exactEnabledVideoTrackCount: Bool
        let exactEncodedDimensions: Bool
        let exactCodec: Bool
        let exactFrameCount: Bool
        let exactPresentationTimestamps: Bool
        let exactDuration: Bool
        let bt709ColorContract: Bool
        let decodedVisiblePixelSHA256: String
        let semanticTrackManifestSHA256: String
        let allRequiredChecksPassed: Bool
    }

    private struct EndToEndRun: Codable {
        let sampleIndex: Int
        let wallMilliseconds: Double
        let peakResidentBytes: UInt64
        let processedFrameCount: Int
        let verification: Verification
    }

    private struct CaseCapture: Codable {
        let id: String
        let backendID: String
        let targetWidth: Int
        let targetHeight: Int
        let request: RequestIdentity
        let engineRuns: [EngineRun]
        let endToEndRuns: [EndToEndRun]
    }

    private struct Capture: Codable {
        let schemaVersion: String
        let variant: String
        let contractSHA256: String
        let captureSourceSHA256: String
        let sourceIdentitySHA256: String
        let sourceRevision: String
        let sourceTreeSHA256: String
        let buildConfiguration: String
        let warmupCount: Int
        let sampleCount: Int
        let input: InputIdentity
        let cases: [CaseCapture]
    }

    private struct TrackManifest: Codable {
        let trackCount: Int
        let enabledVideoTrackCount: Int
        let codecFourCC: String
        let encodedWidth: Int
        let encodedHeight: Int
        let frameCount: Int
        let presentationTimes: [String]
        let duration: String
        let colorPrimaries: String
        let transferFunction: String
        let yCbCrMatrix: String
    }

    private struct AssetInspection {
        let trackCount: Int
        let enabledVideoTrackCount: Int
        let codecFourCC: String
        let width: Int
        let height: Int
        let frameCount: Int
        let presentationTimes: [CMTime]
        let duration: CMTime
        let colorPrimaries: String
        let transferFunction: String
        let yCbCrMatrix: String
        let decodedVisiblePixelSHA256: String
        let semanticTrackManifestSHA256: String
    }

    private struct DecodedInspection {
        let presentationTimes: [CMTime]
        let visiblePixelSHA256: String
    }

    private static let cases = [
        BenchmarkCase(
            id: "nv12-video-range-2x-cpu",
            backendID: UpscaleBackendID.mirmirDeterministicCPU.rawValue,
            targetWidth: 128,
            targetHeight: 96
        ),
        BenchmarkCase(
            id: "nv12-video-range-2x-metal",
            backendID: UpscaleBackendID.mirmirDeterministicMetal.rawValue,
            targetWidth: 128,
            targetHeight: 96
        ),
        BenchmarkCase(
            id: "nv12-video-range-3-over-2-cpu",
            backendID: UpscaleBackendID.mirmirDeterministicCPU.rawValue,
            targetWidth: 96,
            targetHeight: 72
        ),
        BenchmarkCase(
            id: "nv12-video-range-3-over-2-metal",
            backendID: UpscaleBackendID.mirmirDeterministicMetal.rawValue,
            targetWidth: 96,
            targetHeight: 72
        )
    ]

    func testCaptureSameScopePerformanceWhenRequested() async throws {
        guard let captureDirectory = environment("MIRMIR_V4_PERFORMANCE_CAPTURE_DIR") else {
            throw XCTSkip("The locked performance runner did not request a capture.")
        }
        let inputURL = URL(fileURLWithPath: try requiredEnvironment(
            "MIRMIR_V4_PERFORMANCE_INPUT"
        ))
        let outputDirectory = URL(
            fileURLWithPath: captureDirectory,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        let warmupCount = try positiveIntegerEnvironment(
            "MIRMIR_V4_PERFORMANCE_WARMUPS",
            minimum: 5
        )
        let sampleCount = try positiveIntegerEnvironment(
            "MIRMIR_V4_PERFORMANCE_SAMPLES",
            minimum: 10
        )
        XCTAssertEqual(
            sha256(try Data(contentsOf: inputURL)),
            "1e2d65c2702dc3e47768293cf566ecd105282cb7d4ae58874dc313a77b53182d"
        )

        let source = try await VideoProbe().probe(url: inputURL)
        let inputInspection = try await inspectAsset(inputURL, decodePixels: false)
        let expectedDuration = CMTime(value: 1, timescale: 10)
        let inputChecks = inputInspection.trackCount == 1
            && inputInspection.enabledVideoTrackCount == 1
            && inputInspection.codecFourCC == "avc1"
            && inputInspection.width == 64
            && inputInspection.height == 48
            && inputInspection.frameCount == 3
            && CMTimeCompare(inputInspection.duration, expectedDuration) == 0
            && isBT709(inputInspection)
        XCTAssertTrue(inputChecks, "the locked input semantic identity changed")
        let inputIdentity = InputIdentity(
            sha256: sha256(try Data(contentsOf: inputURL)),
            byteCount: try inputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1,
            width: inputInspection.width,
            height: inputInspection.height,
            codecFourCC: inputInspection.codecFourCC,
            frameCount: inputInspection.frameCount,
            trackCount: inputInspection.trackCount,
            enabledVideoTrackCount: inputInspection.enabledVideoTrackCount,
            durationNumerator: 1,
            durationTimescale: 10,
            allRequiredChecksPassed: inputChecks
        )

        var captures: [CaseCapture] = []
        for benchmark in Self.cases {
            let engineRuns = try await captureEngineRuns(
                benchmark,
                source: source,
                inputURL: inputURL,
                warmupCount: warmupCount,
                sampleCount: sampleCount
            )
            let endToEndRuns = try await captureEndToEndRuns(
                benchmark,
                inputURL: inputURL,
                expectedInput: inputInspection,
                warmupCount: warmupCount,
                sampleCount: sampleCount
            )
            captures.append(CaseCapture(
                id: benchmark.id,
                backendID: benchmark.backendID,
                targetWidth: benchmark.targetWidth,
                targetHeight: benchmark.targetHeight,
                request: RequestIdentity(
                    codec: OutputCodec.h264.rawValue,
                    fileType: "mov",
                    preserveAudio: false,
                    overwriteExistingFile: false
                ),
                engineRuns: engineRuns,
                endToEndRuns: endToEndRuns
            ))
        }

        let capture = Capture(
            schemaVersion: "mirmir-v4-performance-capture-v1",
            variant: try requiredEnvironment("MIRMIR_V4_PERFORMANCE_VARIANT"),
            contractSHA256: try requiredEnvironment(
                "MIRMIR_V4_PERFORMANCE_CONTRACT_SHA256"
            ),
            captureSourceSHA256: try requiredEnvironment(
                "MIRMIR_V4_PERFORMANCE_CAPTURE_SOURCE_SHA256"
            ),
            sourceIdentitySHA256: try requiredEnvironment(
                "MIRMIR_V4_PERFORMANCE_SOURCE_IDENTITY_SHA256"
            ),
            sourceRevision: try requiredEnvironment(
                "MIRMIR_V4_PERFORMANCE_SOURCE_REVISION"
            ),
            sourceTreeSHA256: try requiredEnvironment(
                "MIRMIR_V4_PERFORMANCE_SOURCE_TREE_SHA256"
            ),
            buildConfiguration: "Release",
            warmupCount: warmupCount,
            sampleCount: sampleCount,
            input: inputIdentity,
            cases: captures
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(capture).write(
            to: outputDirectory.appendingPathComponent("capture.json"),
            options: .atomic
        )
    }

    private func captureEngineRuns(
        _ benchmark: BenchmarkCase,
        source: VideoInfo,
        inputURL: URL,
        warmupCount: Int,
        sampleCount: Int
    ) async throws -> [EngineRun] {
        let catalog = UpscaleBackendCatalog.live()
        let environment = RuntimeEnvironment.current()
        let request = BackendPreparationRequest(
            source: source,
            targetSize: CGSize(
                width: benchmark.targetWidth,
                height: benchmark.targetHeight
            )
        )
        let decoderProbe = try await catalog.prepare(
            backendID: benchmark.backend,
            request: request,
            environment: environment
        )
        let decoded = try await decodedSamples(
            at: inputURL,
            outputSettings: decoderProbe.sourcePixelBufferAttributes.values
        )
        try await decoderProbe.finish()
        XCTAssertEqual(decoded.count, 3)

        var measured: [EngineRun] = []
        for iteration in 0..<(warmupCount + sampleCount) {
            let prepared = try await catalog.prepare(
                backendID: benchmark.backend,
                request: request,
                environment: environment
            )
            XCTAssertEqual(prepared.actualBackendID, benchmark.backend)
            let pool = try makePool(prepared.destinationPixelBufferAttributes)
            var frameMilliseconds: [Double] = []
            for (frameIndex, sample) in decoded.enumerated() {
                let destination = try makeBuffer(pool)
                let presentationTime = CMSampleBufferGetPresentationTimeStamp(sample)
                let sampleDuration = CMSampleBufferGetDuration(sample)
                let duration = sampleDuration.isValid && sampleDuration.isNumeric
                    ? sampleDuration
                    : CMTime(value: 1, timescale: 30)
                let sourceBuffer = try XCTUnwrap(
                    CMSampleBufferGetImageBuffer(sample)
                )
                let started = DispatchTime.now().uptimeNanoseconds
                try await prepared.process(
                    source: sourceBuffer,
                    destination: destination,
                    timing: FrameTiming(
                        frameIndex: frameIndex,
                        presentationTime: presentationTime,
                        duration: duration
                    )
                )
                let finished = DispatchTime.now().uptimeNanoseconds
                if iteration >= warmupCount {
                    frameMilliseconds.append(
                        Double(finished - started) / 1_000_000.0
                    )
                }
            }
            try await prepared.finish()
            if iteration >= warmupCount {
                measured.append(EngineRun(
                    sampleIndex: iteration - warmupCount,
                    frameMilliseconds: frameMilliseconds,
                    processedFrameCount: frameMilliseconds.count
                ))
            }
        }
        return measured
    }

    private func captureEndToEndRuns(
        _ benchmark: BenchmarkCase,
        inputURL: URL,
        expectedInput: AssetInspection,
        warmupCount: Int,
        sampleCount: Int
    ) async throws -> [EndToEndRun] {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "mirmir-v4-performance-\(benchmark.id)-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        var measured: [EndToEndRun] = []
        for iteration in 0..<(warmupCount + sampleCount) {
            let outputURL = temporaryRoot.appendingPathComponent(
                "run-\(iteration).mov"
            )
            let sampler = PeakResidentSampler()
            let samplingTask = sampler.start()
            let started = DispatchTime.now().uptimeNanoseconds
            let result = try await UpscaleCoordinator().process(
                UpscaleRequest(
                    inputURL: inputURL,
                    outputURL: outputURL,
                    backendID: benchmark.backend,
                    targetWidth: benchmark.targetWidth,
                    targetHeight: benchmark.targetHeight,
                    outputCodec: .h264,
                    preserveAudio: false,
                    overwriteExistingFile: false
                ),
                progress: { _ in }
            )
            let inspection = try await inspectAsset(outputURL, decodePixels: true)
            let verification = makeVerification(
                benchmark: benchmark,
                actualBackendID: result.actualBackendID,
                processedFrameCount: result.processedFrameCount,
                expectedInput: expectedInput,
                output: inspection
            )
            XCTAssertTrue(
                verification.allRequiredChecksPassed,
                "semantic output verification failed for \(benchmark.id)"
            )
            let finished = DispatchTime.now().uptimeNanoseconds
            sampler.stop()
            await samplingTask.value
            if iteration >= warmupCount {
                measured.append(EndToEndRun(
                    sampleIndex: iteration - warmupCount,
                    wallMilliseconds: Double(finished - started) / 1_000_000.0,
                    peakResidentBytes: sampler.peakResidentBytes,
                    processedFrameCount: result.processedFrameCount,
                    verification: verification
                ))
            }
            try FileManager.default.removeItem(at: outputURL)
        }
        return measured
    }

    private func makeVerification(
        benchmark: BenchmarkCase,
        actualBackendID: UpscaleBackendID,
        processedFrameCount: Int,
        expectedInput: AssetInspection,
        output: AssetInspection
    ) -> Verification {
        let requestedBackend = actualBackendID == benchmark.backend
        let tracksAccounted = expectedInput.trackCount == 1
            && output.trackCount == expectedInput.trackCount
        let exactVideoTracks = output.enabledVideoTrackCount
            == expectedInput.enabledVideoTrackCount
        let dimensions = output.width == benchmark.targetWidth
            && output.height == benchmark.targetHeight
        let codec = output.codecFourCC == "avc1"
        let frameCount = processedFrameCount == expectedInput.frameCount
            && output.frameCount == expectedInput.frameCount
        let timestamps = timesEqual(
            output.presentationTimes,
            expectedInput.presentationTimes
        )
        let duration = CMTimeCompare(output.duration, expectedInput.duration) == 0
        let color = isBT709(output)
        let all = requestedBackend && tracksAccounted && exactVideoTracks
            && dimensions && codec && frameCount && timestamps && duration
            && color
        return Verification(
            requestedBackendExecutedWithoutFallback: requestedBackend,
            allInputTracksAccounted: tracksAccounted,
            exactEnabledVideoTrackCount: exactVideoTracks,
            exactEncodedDimensions: dimensions,
            exactCodec: codec,
            exactFrameCount: frameCount,
            exactPresentationTimestamps: timestamps,
            exactDuration: duration,
            bt709ColorContract: color,
            decodedVisiblePixelSHA256: output.decodedVisiblePixelSHA256,
            semanticTrackManifestSHA256: output.semanticTrackManifestSHA256,
            allRequiredChecksPassed: all
        )
    }

    private func inspectAsset(
        _ url: URL,
        decodePixels: Bool
    ) async throws -> AssetInspection {
        let asset = AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let tracks = try await asset.load(.tracks)
        let videoTracks = tracks.filter { $0.mediaType == .video }
        let enabled = try await withThrowingTaskGroup(of: Bool.self) { group in
            for track in videoTracks {
                group.addTask { try await track.load(.isEnabled) }
            }
            var count = 0
            for try await value in group where value { count += 1 }
            return count
        }
        let videoTrack = try XCTUnwrap(videoTracks.first)
        let formats = try await videoTrack.load(.formatDescriptions)
        let format = try XCTUnwrap(formats.first)
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        let duration = try await asset.load(.duration)
        let decoded = try await decodedInspection(asset: asset, track: videoTrack)
        let presentationTimes = decoded.presentationTimes
        let extensions = try XCTUnwrap(
            CMFormatDescriptionGetExtensions(format)
        ) as NSDictionary
        let primaries = String(describing:
            extensions[kCMFormatDescriptionExtension_ColorPrimaries] ?? ""
        )
        let transfer = String(describing:
            extensions[kCMFormatDescriptionExtension_TransferFunction] ?? ""
        )
        let matrix = String(describing:
            extensions[kCMFormatDescriptionExtension_YCbCrMatrix] ?? ""
        )
        let codec = fourCC(CMFormatDescriptionGetMediaSubType(format))
        let manifest = TrackManifest(
            trackCount: tracks.count,
            enabledVideoTrackCount: enabled,
            codecFourCC: codec,
            encodedWidth: Int(dimensions.width),
            encodedHeight: Int(dimensions.height),
            frameCount: presentationTimes.count,
            presentationTimes: presentationTimes.map(timeIdentity),
            duration: timeIdentity(duration),
            colorPrimaries: primaries,
            transferFunction: transfer,
            yCbCrMatrix: matrix
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let trackHash = sha256(try encoder.encode(manifest))
        let pixelHash = decodePixels
            ? decoded.visiblePixelSHA256
            : String(repeating: "0", count: 64)
        return AssetInspection(
            trackCount: tracks.count,
            enabledVideoTrackCount: enabled,
            codecFourCC: codec,
            width: Int(dimensions.width),
            height: Int(dimensions.height),
            frameCount: presentationTimes.count,
            presentationTimes: presentationTimes,
            duration: duration,
            colorPrimaries: primaries,
            transferFunction: transfer,
            yCbCrMatrix: matrix,
            decodedVisiblePixelSHA256: pixelHash,
            semanticTrackManifestSHA256: trackHash
        )
    }

    private func decodedSamples(
        at url: URL,
        outputSettings: [String: Any]
    ) async throws -> [CMSampleBuffer] {
        let asset = AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let tracks = try await asset.load(.tracks)
        let track = try XCTUnwrap(tracks.first { $0.mediaType == .video })
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: outputSettings
        )
        output.alwaysCopiesSampleData = true
        XCTAssertTrue(reader.canAdd(output))
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var samples: [CMSampleBuffer] = []
        while let sample = output.copyNextSampleBuffer() { samples.append(sample) }
        XCTAssertEqual(reader.status, .completed)
        return samples
    }

    private func decodedInspection(
        asset: AVAsset,
        track: AVAssetTrack
    ) async throws -> DecodedInspection {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            ]
        )
        output.alwaysCopiesSampleData = true
        XCTAssertTrue(reader.canAdd(output))
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var digest = SHA256()
        var presentationTimes: [CMTime] = []
        while let sample = output.copyNextSampleBuffer() {
            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sample)
            presentationTimes.append(presentationTime)
            let time = timeIdentity(presentationTime)
            digest.update(data: Data(time.utf8))
            let buffer = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            let planeCount = CVPixelBufferGetPlaneCount(buffer)
            for plane in 0..<planeCount {
                let width = CVPixelBufferGetWidthOfPlane(buffer, plane)
                let height = CVPixelBufferGetHeightOfPlane(buffer, plane)
                let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
                let visibleBytes = width * (plane == 0 ? 1 : 2)
                let base = try XCTUnwrap(
                    CVPixelBufferGetBaseAddressOfPlane(buffer, plane)
                ).assumingMemoryBound(to: UInt8.self)
                for row in 0..<height {
                    digest.update(data: Data(
                        bytes: base.advanced(by: row * stride),
                        count: visibleBytes
                    ))
                }
            }
        }
        XCTAssertEqual(reader.status, .completed)
        XCTAssertEqual(presentationTimes.count, 3)
        return DecodedInspection(
            presentationTimes: presentationTimes,
            visiblePixelSHA256: digest.finalize().map {
                String(format: "%02x", $0)
            }.joined()
        )
    }

    private func makePool(_ attributes: PixelBufferAttributes) throws
        -> CVPixelBufferPool {
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            [kCVPixelBufferPoolMinimumBufferCountKey as String: 3] as CFDictionary,
            attributes.values as CFDictionary,
            &pool
        )
        guard status == kCVReturnSuccess, let pool else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return pool
    }

    private func makeBuffer(_ pool: CVPixelBufferPool) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(
            kCFAllocatorDefault,
            pool,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return buffer
    }

    private func isBT709(_ inspection: AssetInspection) -> Bool {
        inspection.colorPrimaries.contains("709")
            && inspection.transferFunction.contains("709")
            && inspection.yCbCrMatrix.contains("709")
    }

    private func timesEqual(_ lhs: [CMTime], _ rhs: [CMTime]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy {
            CMTimeCompare($0, $1) == 0
        }
    }

    private func timeIdentity(_ time: CMTime) -> String {
        guard time.isValid && time.isNumeric else { return "invalid" }
        let normalized = time.convertScale(600_000, method: .default)
        return "\(normalized.value)/\(normalized.timescale)"
    }

    private func fourCC(_ value: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "????????"
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func environment(_ name: String) -> String? {
        if let injected = Self.injectedEnvironment[name],
           !injected.hasPrefix("__MIRMIR_V4_PERFORMANCE_") {
            return injected
        }
        let value = ProcessInfo.processInfo.environment[name]
        return value?.isEmpty == false ? value : nil
    }

    private func requiredEnvironment(_ name: String) throws -> String {
        guard let value = environment(name) else {
            throw NSError(
                domain: "MirmirPerformanceCapture",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "missing environment \(name)"]
            )
        }
        return value
    }

    private func positiveIntegerEnvironment(
        _ name: String,
        minimum: Int
    ) throws -> Int {
        let text = try requiredEnvironment(name)
        guard let value = Int(text), value >= minimum else {
            throw NSError(
                domain: "MirmirPerformanceCapture",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey:
                    "\(name) must be at least \(minimum)"]
            )
        }
        return value
    }
}

@available(macOS 15.4, *)
private final class PeakResidentSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var peak: UInt64 = 0

    var peakResidentBytes: UInt64 {
        lock.withLock { peak }
    }

    func start() -> Task<Void, Never> {
        lock.withLock {
            stopped = false
            peak = max(peak, currentResidentBytes())
        }
        return Task.detached { [self] in
            while !lock.withLock({ stopped }) {
                let resident = currentResidentBytes()
                lock.withLock { peak = max(peak, resident) }
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            let resident = currentResidentBytes()
            lock.withLock { peak = max(peak, resident) }
        }
    }

    func stop() {
        lock.withLock { stopped = true }
    }

    private func currentResidentBytes() -> UInt64 {
        var usage = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V2, $0)
            }
        }
        return result == 0 ? usage.ri_resident_size : 0
    }
}
