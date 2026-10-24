import AVFoundation
import CoreVideo
import XCTest
@testable import Mirmir

final class VideoProbeTests: XCTestCase {
    func testProbesSDRLandscapeWithAudio() async throws {
        let fixtures = try TemporaryFixtureDirectory()
        defer { fixtures.remove() }

        let silentVideoURL = fixtures.url(for: "landscape-silent.mov")
        let audioURL = fixtures.url(for: "audio.wav")
        let combinedURL = fixtures.url(for: "landscape-with-audio.mov")
        try await VideoProbeFixtureFactory.makeVideo(
            at: silentVideoURL,
            transform: .identity
        )
        try VideoProbeFixtureFactory.makeAudio(at: audioURL)
        try await VideoProbeFixtureFactory.combine(
            videoURL: silentVideoURL,
            audioURL: audioURL,
            outputURL: combinedURL
        )

        let info = try await VideoProbe().probe(url: combinedURL)

        XCTAssertEqual(info.geometry.encodedSize, CGSize(width: 64, height: 48))
        XCTAssertEqual(info.displaySize, CGSize(width: 64, height: 48))
        XCTAssertEqual(info.geometry.orientation, .landscape)
        XCTAssertTrue(info.hasAudio)
        XCTAssertEqual(info.audioTrackCount, 1)
        XCTAssertEqual(info.videoTrackCount, 1)
        XCTAssertTrue(info.isReadable)
        XCTAssertTrue(info.isPlayable)
        XCTAssertNotNil(info.codecFourCC)
        XCTAssertEqual(info.color.dynamicRange, .sdr)
        XCTAssertNil(info.color.pixelFormat)
        XCTAssertGreaterThan(info.fileSizeBytes ?? 0, 0)
    }

    func testProbesPortraitPreferredTransform() async throws {
        let fixtures = try TemporaryFixtureDirectory()
        defer { fixtures.remove() }

        let videoURL = fixtures.url(for: "portrait.mov")
        let portraitTransform = CGAffineTransform(
            a: 0,
            b: 1,
            c: -1,
            d: 0,
            tx: 48,
            ty: 0
        )
        try await VideoProbeFixtureFactory.makeVideo(
            at: videoURL,
            transform: portraitTransform
        )

        let info = try await VideoProbe().probe(url: videoURL)

        XCTAssertEqual(info.geometry.encodedSize, CGSize(width: 64, height: 48))
        XCTAssertEqual(info.displaySize, CGSize(width: 48, height: 64))
        XCTAssertEqual(info.geometry.orientation, .portrait)
        XCTAssertEqual(info.preferredTransform, portraitTransform)
    }

    func testProbesSilentVideo() async throws {
        let fixtures = try TemporaryFixtureDirectory()
        defer { fixtures.remove() }

        let videoURL = fixtures.url(for: "silent.mov")
        try await VideoProbeFixtureFactory.makeVideo(
            at: videoURL,
            transform: .identity
        )

        let info = try await VideoProbe().probe(url: videoURL)

        XCTAssertFalse(info.hasAudio)
        XCTAssertEqual(info.audioTrackCount, 0)
        XCTAssertNotNil(info.nominalFrameRate)
        XCTAssertNotNil(info.minimumFrameDuration)
        XCTAssertNotNil(info.estimatedFrameCount)
    }

    func testRejectsValidAudioOnlyAsset() async throws {
        let fixtures = try TemporaryFixtureDirectory()
        defer { fixtures.remove() }

        let audioURL = fixtures.url(for: "audio-only.wav")
        try VideoProbeFixtureFactory.makeAudio(at: audioURL)

        do {
            _ = try await VideoProbe().probe(url: audioURL)
            XCTFail("Expected an audio-only asset to be rejected.")
        } catch let error as MirmirError {
            XCTAssertEqual(error, .noVideoTrack)
        }
    }
}

struct TemporaryFixtureDirectory {
    let rootURL: URL

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "MirmirVideoProbeTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: false
        )
    }

    func url(for filename: String) -> URL {
        rootURL.appendingPathComponent(filename, isDirectory: false)
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

enum VideoProbeFixtureError: LocalizedError {
    case failure(String)

    var errorDescription: String? {
        switch self {
        case .failure(let message):
            message
        }
    }
}

enum VideoProbeFixtureFactory {
    private static let width = 64
    private static let height = 48
    private static let frameRate: CMTimeScale = 30
    private static let frameCount: CMTimeValue = 3

    static func makeVideo(
        at url: URL,
        transform: CGAffineTransform,
        presentationTimes: [CMTime]? = nil,
        includeColorProperties: Bool = true,
        codec: AVVideoCodecType = .h264
    ) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        var videoSettings: [String: Any] = [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ]
        ]
        if !includeColorProperties {
            videoSettings.removeValue(forKey: AVVideoColorPropertiesKey)
        }
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: videoSettings
        )
        input.expectsMediaDataInRealTime = false
        input.transform = transform

        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String:
                Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: pixelBufferAttributes
        )

        guard writer.canAdd(input) else {
            throw VideoProbeFixtureError.failure(
                "AVAssetWriter rejected the generated video input."
            )
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw VideoProbeFixtureError.failure(
                writer.error?.localizedDescription
                    ?? "AVAssetWriter could not start."
            )
        }
        writer.startSession(atSourceTime: .zero)

        guard let pool = adaptor.pixelBufferPool else {
            throw VideoProbeFixtureError.failure(
                "AVAssetWriter did not create a pixel-buffer pool."
            )
        }

        let times = presentationTimes ?? (0..<frameCount).map {
            CMTime(value: $0, timescale: frameRate)
        }
        guard !times.isEmpty else {
            throw VideoProbeFixtureError.failure(
                "The generated video requires at least one frame."
            )
        }
        for (frameIndex, presentationTime) in times.enumerated() {
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed {
                    throw VideoProbeFixtureError.failure(
                        writer.error?.localizedDescription
                            ?? "AVAssetWriter failed while accepting frames."
                    )
                }
                try await Task.sleep(nanoseconds: 1_000_000)
            }

            var pixelBuffer: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBuffer(
                nil,
                pool,
                &pixelBuffer
            )
            guard status == kCVReturnSuccess, let pixelBuffer else {
                throw VideoProbeFixtureError.failure(
                    "CVPixelBufferPool returned status \(status)."
                )
            }
            fill(pixelBuffer: pixelBuffer, frameIndex: frameIndex)
            if !includeColorProperties {
                CVBufferRemoveAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey)
                CVBufferRemoveAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey)
                CVBufferRemoveAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey)
            }
            guard adaptor.append(
                pixelBuffer,
                withPresentationTime: presentationTime
            ) else {
                throw VideoProbeFixtureError.failure(
                    writer.error?.localizedDescription
                        ?? "AVAssetWriter rejected a generated frame."
                )
            }
        }

        input.markAsFinished()
        let duration = CMTimeAdd(
            times[times.count - 1],
            CMTime(value: 1, timescale: frameRate)
        )
        writer.endSession(atSourceTime: duration)
        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }
        guard writer.status == .completed else {
            throw VideoProbeFixtureError.failure(
                writer.error?.localizedDescription
                    ?? "AVAssetWriter did not complete the generated video."
            )
        }
    }

    static func makeAudio(at url: URL, amplitude: Float = 0) throws {
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: 48_000,
            channels: 1
        ),
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: 12_000
        ) else {
            throw VideoProbeFixtureError.failure(
                "AVFoundation could not create the audio fixture format."
            )
        }

        buffer.frameLength = 12_000
        if let channel = buffer.floatChannelData?[0] {
            channel.initialize(
                repeating: amplitude,
                count: Int(buffer.frameLength)
            )
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    static func combine(
        videoURL: URL,
        audioURL: URL,
        outputURL: URL
    ) async throws {
        try await combine(
            videoURL: videoURL,
            audioURLs: [audioURL],
            outputURL: outputURL
        )
    }

    static func combine(
        videoURL: URL,
        audioURLs: [URL],
        outputURL: URL
    ) async throws {
        guard !audioURLs.isEmpty else {
            throw VideoProbeFixtureError.failure(
                "The combined fixture requires at least one audio source."
            )
        }
        let videoAsset = AVURLAsset(url: videoURL)
        let audioAssets = audioURLs.map(AVURLAsset.init(url:))
        let videoTracks = try await videoAsset.loadTracks(withMediaType: .video)
        var audioTracks: [(asset: AVURLAsset, track: AVAssetTrack)] = []
        for audioAsset in audioAssets {
            let tracks = try await audioAsset.loadTracks(withMediaType: .audio)
            guard let track = tracks.first else {
                throw VideoProbeFixtureError.failure(
                    "A generated audio source was not readable."
                )
            }
            audioTracks.append((audioAsset, track))
        }
        guard let videoTrack = videoTracks.first else {
            throw VideoProbeFixtureError.failure(
                "The generated source tracks were not readable."
            )
        }

        let videoDuration = try await videoAsset.load(.duration)
        let composition = AVMutableComposition()
        guard let compositionVideo = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw VideoProbeFixtureError.failure(
                "AVMutableComposition could not create fixture tracks."
            )
        }

        try compositionVideo.insertTimeRange(
            CMTimeRange(start: .zero, duration: videoDuration),
            of: videoTrack,
            at: .zero
        )
        compositionVideo.preferredTransform = try await videoTrack.load(
            .preferredTransform
        )
        for (audioAsset, audioTrack) in audioTracks {
            guard let compositionAudio = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                throw VideoProbeFixtureError.failure(
                    "AVMutableComposition could not create an audio fixture track."
                )
            }
            let audioDuration = try await audioAsset.load(.duration)
            let audioInsertDuration = CMTimeCompare(
                videoDuration,
                audioDuration
            ) <= 0 ? videoDuration : audioDuration
            try compositionAudio.insertTimeRange(
                CMTimeRange(start: .zero, duration: audioInsertDuration),
                of: audioTrack,
                at: .zero
            )
        }

        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw VideoProbeFixtureError.failure(
                "AVAssetExportSession rejected the generated composition."
            )
        }
        try await exportSession.export(to: outputURL, as: .mov)
    }

    private static func fill(
        pixelBuffer: CVPixelBuffer,
        frameIndex: Int
    ) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        if let lumaAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) {
            let byteCount = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
                * CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
            lumaAddress.initializeMemory(
                as: UInt8.self,
                repeating: UInt8(64 + frameIndex * 8),
                count: byteCount
            )
        }
        if let chromaAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) {
            let byteCount = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
                * CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
            chromaAddress.initializeMemory(
                as: UInt8.self,
                repeating: 128,
                count: byteCount
            )
        }

        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferColorPrimariesKey,
            kCVImageBufferColorPrimaries_ITU_R_709_2,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferTransferFunctionKey,
            kCVImageBufferTransferFunction_ITU_R_709_2,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferYCbCrMatrix_ITU_R_709_2,
            .shouldPropagate
        )
    }
}
