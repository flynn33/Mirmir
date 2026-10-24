import AVFoundation
import CoreVideo
import XCTest
@testable import Mirmir

final class VideoProbeTests: XCTestCase {
    func testReadableLegacyMoviesReachBothDeterministicBackends() async throws {
        for (name, fullRange) in [("legacy-mpeg4", false), ("legacy-mjpeg", true)] {
            let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "mov"))
            let info = try await VideoProbe().probe(url: url)
            XCTAssertEqual(info.color.bitDepth, 8, name)
            XCTAssertEqual(info.color.isFullRange, fullRange, name)
            XCTAssertEqual(info.color.dynamicRange, .sdr, name)
            let catalog = UpscaleBackendCatalog.live()
            for backend: UpscaleBackendID in [.mirmirDeterministicCPU, .mirmirDeterministicMetal] {
                let availability = await catalog.availability(
                    for: backend, source: info,
                    targetSize: CGSize(width: 320, height: 192), environment: .current()
                )
                XCTAssertEqual(availability, .available, "\(name): \(backend)")
            }
        }
    }

    func testLegacyHeaderParsersRejectTruncationAndMissingSamplingEvidence() throws {
        for length in 0..<16 {
            XCTAssertNil(LegacyVideoSamplingFacts.jpeg(Data(repeating: 0xff, count: length)))
            XCTAssertNil(LegacyVideoSamplingFacts.mpeg4(Data(repeating: 0, count: length)))
        }
        // A valid JPEG SOF without its JFIF color/range declaration is insufficient.
        let sof: [UInt8] = [0xff, 0xd8, 0xff, 0xc0, 0, 17, 8, 0, 96, 0, 160, 3, 1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1]
        XCTAssertNil(LegacyVideoSamplingFacts.jpeg(Data(sof)))
        let jfif: [UInt8] = [0xff, 0xd8, 0xff, 0xe0, 0, 16, 74, 70, 73, 70, 0, 1, 2, 0, 0, 1, 0, 1, 0, 0]
        let valid = Data(jfif + sof.dropFirst(2))
        XCTAssertEqual(LegacyVideoSamplingFacts.jpeg(valid), .init(bitDepth: 8, fullRange: true, subsampling: .yuv420))
        for length in 0..<valid.count {
            XCTAssertNil(LegacyVideoSamplingFacts.jpeg(valid.prefix(length)), "truncated at \(length)")
        }
        var highPrecision = valid
        highPrecision[24] = 12
        XCTAssertNil(LegacyVideoSamplingFacts.jpeg(highPrecision))
    }

    func testMPEG4HeaderAdmissionRetainsRangeAndRejectsUnsupportedVOLFields() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "legacy-mpeg4", withExtension: "mov"))
        let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .video)
        let description = try await XCTUnwrap(tracks.first).load(.formatDescriptions)[0]
        let extensions = try XCTUnwrap(CMFormatDescriptionGetExtensions(description) as NSDictionary?)
        let atoms = try XCTUnwrap(extensions["SampleDescriptionExtensionAtoms"] as? NSDictionary)
        let esds = try XCTUnwrap(atoms["esds"] as? Data)
        let vol = try XCTUnwrap(esds.range(of: Data([0, 0, 1, 0x20]))).upperBound
        // Bind these bit mutations to the actual fixture header, including its
        // progressive, eight-bit 4:2:0 VOL and 24 fps clock.
        XCTAssertEqual(Array(esds[vol..<(vol + 10)]), [0, 0xc4, 0x8d, 0x88, 0, 0xc5, 5, 4, 0x0c, 0x14])
        XCTAssertEqual(LegacyVideoSamplingFacts.mpeg4(esds), .init(bitDepth: 8, fullRange: false, subsampling: .yuv420))
        for length in 0..<(vol + 10) {
            XCTAssertNil(LegacyVideoSamplingFacts.mpeg4(esds.prefix(length)), "truncated at \(length)")
        }
        for bit in [8, 22, 76, 78, 79] {
            var unsupported = esds
            unsupported[vol + bit / 8] ^= 1 << (7 - bit % 8)
            XCTAssertNil(LegacyVideoSamplingFacts.mpeg4(unsupported), "unsupported VOL bit \(bit)")
        }
        let visualObject = try XCTUnwrap(esds.range(of: Data([0, 0, 1, 0xb5]))).upperBound
        var explicitFullRange = esds
        explicitFullRange.replaceSubrange(visualObject..<(visualObject + 2), with: [0x89, 0x1d, 0x80])
        XCTAssertEqual(LegacyVideoSamplingFacts.mpeg4(explicitFullRange), .init(bitDepth: 8, fullRange: true, subsampling: .yuv420))
    }

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

    func testUnreadableUntaggedFrameRetainsDecoderFailureReason() async throws {
        let fixtures = try TemporaryFixtureDirectory()
        defer { fixtures.remove() }
        let url = fixtures.url(for: "damaged-untagged.mov")
        try await VideoProbeFixtureFactory.makeVideo(
            at: url, transform: .identity, includeColorProperties: false
        )
        var bytes = try Data(contentsOf: url)
        func integer(_ offset: Int, _ length: Int) -> UInt64 {
            bytes[offset..<(offset + length)].reduce(0) { ($0 << 8) | UInt64($1) }
        }
        var offset = 0
        var corrupted = false
        while offset + 8 <= bytes.count {
            let size32 = integer(offset, 4)
            let header = size32 == 1 ? 16 : 8
            let size = size32 == 1 ? Int(integer(offset + 8, 8))
                : size32 == 0 ? bytes.count - offset : Int(size32)
            guard size >= header, offset + size <= bytes.count else {
                throw VideoProbeFixtureError.failure("Invalid generated movie atom.")
            }
            if bytes[(offset + 4)..<(offset + 8)] == Data("mdat".utf8) {
                bytes.replaceSubrange((offset + header)..<(offset + size), with: repeatElement(UInt8(0), count: size - header))
                corrupted = true
                break
            }
            offset += size
        }
        XCTAssertTrue(corrupted)
        try bytes.write(to: url)
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let descriptions = try await track.load(.formatDescriptions)
        let reason: String
        do {
            _ = try VideoDecodedColorResolver.resolve(asset: asset, track: track, descriptions: descriptions)
            return XCTFail("The damaged frame must fail decoder color resolution.")
        } catch AVCanonicalMediaStateAdapterV4Error.avFoundationLoadFailed(let path, let detail) {
            XCTAssertEqual(path, "video.decoded_color")
            reason = detail
        }
        do {
            _ = try await VideoProbe().probe(url: url)
            XCTFail("The damaged source must fail probing.")
        } catch MirmirError.probeFailed(let detail) {
            XCTAssertEqual(detail, reason)
        }
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
    private static let frameRate: CMTimeScale = 30
    private static let frameCount: CMTimeValue = 3

    static func makeVideo(
        at url: URL,
        transform: CGAffineTransform,
        presentationTimes: [CMTime]? = nil,
        includeColorProperties: Bool = true,
        codec: AVVideoCodecType = .h264,
        width: Int = 64,
        height: Int = 48
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
