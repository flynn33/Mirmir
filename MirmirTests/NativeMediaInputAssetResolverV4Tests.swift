import AVFoundation
import CoreMedia
import CryptoKit
import Darwin
import XCTest
@testable import Mirmir

final class NativeMediaInputAssetResolverV4Tests: XCTestCase {
    func testH264BFramesMatchIndependentDisplayOrderAndExactPresentationClock() async throws {
        let oracleURL = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "native-avi-h264-display-order", withExtension: "json"
        ))
        let oracle = try JSONDecoder().decode(DisplayOrderOracle.self, from: Data(contentsOf: oracleURL))
        let source = try fixture("native-avi-h264")
        XCTAssertEqual(try ASHStreamingFileIdentityV4.read(url: source).contentSHA256.rawValue, oracle.sourceSHA256)
        XCTAssertEqual(oracle.frames.count, 72)
        XCTAssertEqual(Set(oracle.frames.map(\.sha256)).count, oracle.frames.count)
        let root = try temporaryRoot()
        defer { removeRoot(root) }
        let resolver = NativeMediaInputAssetResolverV4(cacheRoot: root.appendingPathComponent("cache"))
        let asset = try await resolver.resolvedAsset(url: source)
        let frames = try await decodedVideoFrames(asset, width: oracle.width, height: oracle.height)
        XCTAssertEqual(frames.map(\.hash), oracle.frames.map(\.sha256),
                       "Decoded pictures must follow the independent original-AVI display sequence")
        XCTAssertEqual(frames.count, oracle.frames.count)
        for (actual, expected) in zip(frames, oracle.frames) {
            XCTAssertTrue(actual.time.isNumeric)
            XCTAssertEqual(actual.time.epoch, 0)
            XCTAssertFalse(actual.time.flags.contains(.hasBeenRounded))
            XCTAssertEqual(CMTimeCompare(actual.time, CMTime(
                value: expected.presentationValue, timescale: oracle.timescale
            )), 0, "Each displayed picture must retain its exact position on the source track clock")
        }
    }

    func testH264ClockRejectsMissingPicturesAndIncompleteExactTrackEnd() async throws {
        let source = try await h264PacketTimeline()
        var complete = try NativeAVICompressedPresentationClockV4(strategy: .aviH264, format: source.format)
        for packet in source.packets {
            _ = try complete.presentationTime(packet: packet.bytes, timing: packet.timing)
        }
        XCTAssertNoThrow(try complete.finish(expectedEnd: source.end))

        var missing = try NativeAVICompressedPresentationClockV4(strategy: .aviH264, format: source.format)
        for packet in source.packets.dropLast() {
            _ = try missing.presentationTime(packet: packet.bytes, timing: packet.timing)
        }
        XCTAssertThrowsError(try missing.finish(expectedEnd: source.end)) { error in
            XCTAssertTrue(error.localizedDescription.contains("complete source timeline"))
        }

        var truncated = try NativeAVICompressedPresentationClockV4(strategy: .aviH264, format: source.format)
        let first = try XCTUnwrap(source.packets.first)
        _ = try truncated.presentationTime(packet: first.bytes, timing: first.timing)
        XCTAssertNoThrow(try truncated.finish())
        XCTAssertThrowsError(try truncated.finish(expectedEnd: source.end)) { error in
            XCTAssertTrue(error.localizedDescription.contains("exact source track end"))
        }
    }

    func testH264ClockRejectsPacketDurationChangesAndNonDecodeSourcePTS() async throws {
        let source = try await h264PacketTimeline()
        let first = try XCTUnwrap(source.packets.first)
        let second = try XCTUnwrap(source.packets.dropFirst().first)
        var changedDuration = try NativeAVICompressedPresentationClockV4(strategy: .aviH264, format: source.format)
        _ = try changedDuration.presentationTime(packet: first.bytes, timing: first.timing)
        var timing = second.timing
        timing.duration = CMTimeMultiply(timing.duration, multiplier: 2)
        XCTAssertThrowsError(try changedDuration.presentationTime(packet: second.bytes, timing: timing)) { error in
            XCTAssertTrue(error.localizedDescription.contains("uniform exact video packet clock"))
        }

        var changedPTS = try NativeAVICompressedPresentationClockV4(strategy: .aviH264, format: source.format)
        timing = first.timing
        timing.presentationTimeStamp = CMTimeAdd(timing.presentationTimeStamp, timing.duration)
        XCTAssertThrowsError(try changedPTS.presentationTime(packet: first.bytes, timing: timing)) { error in
            XCTAssertTrue(error.localizedDescription.contains("zero-origin decode clock"))
        }
    }

    func testBothAVICodecsDecodeAllFramesAndPreservePCMAndExactTrackEnds() async throws {
        let root = try temporaryRoot()
        defer { removeRoot(root) }
        let resolver = NativeMediaInputAssetResolverV4(cacheRoot: root.appendingPathComponent("cache"))
        for name in ["native-avi-mpeg4", "native-avi-h264"] {
            let source = try fixture(name)
            let original = AVURLAsset(url: source)
            let originallyPlayable = try await original.load(.isPlayable)
            XCTAssertFalse(originallyPlayable)
            let identity = try ASHStreamingFileIdentityV4.read(url: source)
            let asset = try await resolver.resolvedAsset(url: source)
            XCTAssertNotEqual(asset.url, source)
            let playable = try await asset.load(.isPlayable)
            XCTAssertTrue(playable)
            let decodedVideo = try await decoded(asset, type: .video)
            XCTAssertEqual(decodedVideo.count, 72)
            let audio = try await decoded(asset, type: .audio)
            let sourceAudio = try await decoded(original, type: .audio)
            XCTAssertEqual(audio.count, 144_000)
            XCTAssertEqual(audio.bytes, 288_000)
            XCTAssertEqual(audio.hash, sourceAudio.hash)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            let audioTrack = try XCTUnwrap(audioTracks.first)
            let range = try await audioTrack.load(.timeRange)
            XCTAssertEqual(CMTimeCompare(CMTimeRangeGetEnd(range), CMTime(value: 3, timescale: 1)), 0)
            XCTAssertEqual(try ASHStreamingFileIdentityV4.read(url: source).contentSHA256, identity.contentSHA256)
            XCTAssertNotEqual(try flags(asset.url) & UInt32(UF_IMMUTABLE), 0)
            let descriptor = open(asset.url.path, O_RDWR | O_NOFOLLOW)
            XCTAssertEqual(descriptor, -1, "Published decode assets must reject writable handles")
            if descriptor >= 0 { close(descriptor) }
        }
    }

    func testRepeatAssetReuseAndFreshResolverVerifyPersistentEntry() async throws {
        let root = try temporaryRoot()
        defer { removeRoot(root) }
        let cache = root.appendingPathComponent("cache")
        let first = NativeMediaInputAssetResolverV4(cacheRoot: cache)
        let source = try fixture("native-avi-h264")
        let asset = try await first.resolvedAsset(url: source)
        let repeated = try await first.resolvedAsset(url: source)
        XCTAssertTrue(asset === repeated, "Warm opens must reuse the verified asset instead of rescanning whole movies")
        let identity = try ASHStreamingFileIdentityV4.read(url: asset.url)
        let fresh = NativeMediaInputAssetResolverV4(cacheRoot: cache)
        let reopened = try await fresh.resolvedAsset(url: source)
        XCTAssertEqual(reopened.url, asset.url)
        XCTAssertEqual(try ASHStreamingFileIdentityV4.read(url: reopened.url).contentSHA256, identity.contentSHA256)
    }

    func testCoherentlyRewrittenColdCacheIsRegeneratedFromOriginalPackets() async throws {
        let root = try temporaryRoot()
        defer { removeRoot(root) }
        let cache = root.appendingPathComponent("cache")
        let first = NativeMediaInputAssetResolverV4(cacheRoot: cache)
        var asset: AVURLAsset? = try await first.resolvedAsset(url: fixture("native-avi-mpeg4"))
        let target = try XCTUnwrap(asset?.url)
        let released = WeakAsset(asset)
        asset = nil
        for _ in 0..<100 where released.value != nil { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertNil(released.value)
        try unfreeze(target)
        var forgedBytes = try Data(contentsOf: target)
        let media = try XCTUnwrap(forgedBytes.range(of: Data("mdat".utf8)))
        let changedOffset = media.upperBound + 256
        XCTAssertLessThan(changedOffset, forgedBytes.count)
        forgedBytes[changedOffset] ^= 1
        try forgedBytes.write(to: target)
        let manifestURL = target.deletingLastPathComponent().appendingPathComponent("manifest.json")
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        let forged = try ASHStreamingFileIdentityV4.read(url: target)
        manifest["derivedSHA256"] = forged.contentSHA256.rawValue
        manifest["derivedBytes"] = forged.byteCount
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        XCTAssertEqual(chflags(target.path, try flags(target) | UInt32(UF_IMMUTABLE)), 0)
        let cold = NativeMediaInputAssetResolverV4(cacheRoot: cache)
        let repaired = try await cold.resolvedAsset(url: fixture("native-avi-mpeg4"))
        let videos = try await repaired.loadTracks(withMediaType: .video)
        let video = try XCTUnwrap(videos.first)
        let format = try await video.load(.formatDescriptions)[0]
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(format), kCMVideoCodecType_MPEG4Video)
        let repairedVideo = try await decoded(repaired, type: .video)
        XCTAssertEqual(repairedVideo.count, 72)
        XCTAssertNotEqual(try ASHStreamingFileIdentityV4.read(url: repaired.url).contentSHA256, forged.contentSHA256)
    }

    func testConfigurationMutationAndMalformedPacketFramingAreRejected() async throws {
        let root = try temporaryRoot()
        defer { removeRoot(root) }
        let asset = AVURLAsset(url: try fixture("native-avi-h264"))
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let format = try await track.load(.formatDescriptions)[0]
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        defer { reader.cancelReading() }
        var packet: Data?
        while let sample = output.copyNextSampleBuffer(), packet == nil {
            if CMSampleBufferGetNumSamples(sample) > 0 { packet = try payload(sample) }
        }
        let original = try XCTUnwrap(packet)
        let canonical = try NativeMediaInputAssetResolverV4.canonicalFormat(
            description: format, firstPacket: original, strategy: .aviH264)
        let units = try NativeMediaInputAssetResolverV4.annexBNALs(original)
        var changedSPS = try XCTUnwrap(units.first { $0.first.map { $0 & 31 } == 7 })
        changedSPS[changedSPS.count - 1] ^= 1
        let mutation = Data([0, 0, 0, 1]) + changedSPS
        XCTAssertThrowsError(try NativeMediaInputAssetResolverV4.verifyStableConfiguration(
            mutation, format: canonical, strategy: .aviH264))
        XCTAssertThrowsError(try NativeMediaInputAssetResolverV4.lengthPrefixedH264(Data([1, 2, 3])))
        XCTAssertThrowsError(try NativeMediaInputAssetResolverV4.lengthPrefixedH264(Data([0, 0, 1])))
    }

    func testCancellationDuringImportRemovesAllOwnedPartials() async throws {
        let root = try temporaryRoot()
        defer { removeRoot(root) }
        let cache = root.appendingPathComponent("cache")
        let resolver = NativeMediaInputAssetResolverV4(cacheRoot: cache)
        do {
            _ = try await resolver.resolvedAsset(url: fixture("native-avi-h264"), cancellation: CheckAction(limit: 20))
            XCTFail("Expected cancellation while packets were being imported")
        } catch is CancellationError { }
        try assertOnlyNamespaceLockRemains(in: cache)
    }

    func testRetainedWritableMappingMutationAtImportBoundaryIsRejected() async throws {
        let root = try temporaryRoot()
        defer { removeRoot(root) }
        let source = root.appendingPathComponent("source.avi")
        try Data(contentsOf: fixture("native-avi-h264")).write(to: source)
        let descriptor = open(source.path, O_RDWR | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }
        let size = Int(try ASHStreamingFileIdentityV4.read(url: source).byteCount)
        let mapping = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_SHARED, descriptor, 0)
        guard let mapping, mapping != MAP_FAILED else { return XCTFail("Cannot retain a writable source mapping") }
        defer { munmap(mapping, size) }
        XCTAssertEqual(fchmod(descriptor, S_IRUSR), 0)
        let action = CheckAction(limit: nil) { index in
            if index == 20 {
                mapping.assumingMemoryBound(to: UInt8.self).advanced(by: size - 1).pointee ^= 1
            }
        }
        let resolver = NativeMediaInputAssetResolverV4(cacheRoot: root.appendingPathComponent("cache"))
        do {
            _ = try await resolver.resolvedAsset(url: source, cancellation: action)
            XCTFail("A source changed through a retained mapping must not be published")
        } catch { }
        try assertOnlyNamespaceLockRemains(in: root.appendingPathComponent("cache"))
    }

    func testFreshOriginalHashInvalidatesWarmMemoAfterSameMetadataMappingMutation() async throws {
        let root = try temporaryRoot()
        defer { removeRoot(root) }
        let source = root.appendingPathComponent("source.avi")
        let bytes = try Data(contentsOf: fixture("native-avi-h264"))
        try bytes.write(to: source)
        let position = try XCTUnwrap(bytes.range(of: Data("x264".utf8))).lowerBound
        let descriptor = open(source.path, O_RDWR | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }
        let mapping = mmap(nil, bytes.count, PROT_READ | PROT_WRITE, MAP_SHARED, descriptor, 0)
        guard let mapping, mapping != MAP_FAILED else { return XCTFail("Cannot retain a writable source mapping") }
        defer { munmap(mapping, bytes.count) }
        XCTAssertEqual(fchmod(descriptor, S_IRUSR), 0)
        let resolver = NativeMediaInputAssetResolverV4(cacheRoot: root.appendingPathComponent("cache"))
        let originalIdentity = try ASHStreamingFileIdentityV4.read(url: source)
        let first = try await resolver.resolvedAsset(url: source, sourceIdentity: originalIdentity)
        var before = stat()
        XCTAssertEqual(fstat(descriptor, &before), 0)
        mapping.assumingMemoryBound(to: UInt8.self).advanced(by: position).pointee ^= 1
        var after = stat()
        XCTAssertEqual(fstat(descriptor, &after), 0)
        XCTAssertEqual(before.st_mtimespec.tv_sec, after.st_mtimespec.tv_sec)
        XCTAssertEqual(before.st_mtimespec.tv_nsec, after.st_mtimespec.tv_nsec)
        XCTAssertEqual(before.st_ctimespec.tv_sec, after.st_ctimespec.tv_sec)
        XCTAssertEqual(before.st_ctimespec.tv_nsec, after.st_ctimespec.tv_nsec)
        // A fresh canonical-boundary hash, rather than a stat snapshot, owns
        // original-content authentication. The user-data SEI change keeps the
        // codec/geometry and every picture packet structurally valid.
        let changedIdentity = try ASHStreamingFileIdentityV4.read(url: source)
        XCTAssertNotEqual(changedIdentity.contentSHA256, originalIdentity.contentSHA256)
        let changed = try await resolver.resolvedAsset(url: source, revalidateSource: true)
        XCTAssertNotEqual(changed.url, first.url)
        XCTAssertFalse(changed === first)
        let manifestURL = changed.url.deletingLastPathComponent().appendingPathComponent("manifest.json")
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        XCTAssertEqual(manifest["sourceSHA256"] as? String, changedIdentity.contentSHA256.rawValue)
    }

    func testOversizedEntryIsAllowedWhileActiveAndEvictedAfterRelease() async throws {
        let root = try temporaryRoot()
        defer { removeRoot(root) }
        let resolver = NativeMediaInputAssetResolverV4(cacheRoot: root.appendingPathComponent("cache"), maximumCacheBytes: 1)
        var asset: AVURLAsset? = try await resolver.resolvedAsset(url: fixture("native-avi-h264"))
        let path = try XCTUnwrap(asset?.url)
        let whileActive = try await resolver.clearInactiveEntries()
        XCTAssertEqual(whileActive.entryCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
        let released = WeakAsset(asset)
        asset = nil
        for _ in 0..<100 where released.value != nil { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertNil(released.value)
        _ = try await resolver.clearInactiveEntries()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }

    func testConcurrentResolversAcceptSingleVerifiedPublication() async throws {
        let root = try temporaryRoot()
        defer { removeRoot(root) }
        let cache = root.appendingPathComponent("cache")
        let first = NativeMediaInputAssetResolverV4(cacheRoot: cache)
        let second = NativeMediaInputAssetResolverV4(cacheRoot: cache)
        let source = try fixture("native-avi-h264")
        async let a = first.resolvedAsset(url: source)
        async let b = second.resolvedAsset(url: source)
        let (one, two) = try await (a, b)
        XCTAssertEqual(one.url, two.url)
        let decodedVideo = try await decoded(one, type: .video)
        XCTAssertEqual(decodedVideo.count, 72)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.path).filter { $0.hasPrefix(".partial-") }.count, 0)
    }

    func testConcurrentClearPreservesAcquiringAndActiveImportLeases() async throws {
        let root = try temporaryRoot()
        defer { removeRoot(root) }
        let cache = root.appendingPathComponent("cache")
        let importer = NativeMediaInputAssetResolverV4(cacheRoot: cache)
        let clearer = NativeMediaInputAssetResolverV4(cacheRoot: cache)
        let source = try fixture("native-avi-h264")
        let clearing = Task { () -> [String] in
            var errors: [String] = []
            for _ in 0..<6_000 {
                do { _ = try await clearer.clearInactiveEntries() }
                catch { errors.append(String(describing: error)) }
                await Task.yield()
            }
            return errors
        }
        var importErrors: [String] = []
        for _ in 0..<70 {
            do {
                let asset = try await importer.resolvedAsset(url: source)
                let playable = try await asset.load(.isPlayable)
                XCTAssertTrue(playable)
            } catch { importErrors.append(String(describing: error)) }
            await Task.yield()
        }
        let clearErrors = await clearing.value
        XCTAssertEqual(importErrors, [], "Clearing must not retire an import while it acquires its lease")
        XCTAssertEqual(clearErrors, [], "Concurrent retirement must not race cache namespace enumeration")
    }

    func testConcurrentRootConfigurationWaitsForImportAndIsIdempotent() async throws {
        let root = try temporaryRoot()
        defer { removeRoot(root) }
        let firstRoot = root.appendingPathComponent("first")
        let selectedRoot = root.appendingPathComponent("selected")
        let resolver = NativeMediaInputAssetResolverV4(cacheRoot: firstRoot)
        let source = try fixture("native-avi-h264")
        async let imported = resolver.resolvedAsset(url: source)
        async let configured: Void = resolver.configure(selectedRoot)
        let (oldAsset, _) = try await (imported, configured)
        try await resolver.configure(selectedRoot)
        let selected = try await resolver.resolvedAsset(url: source)
        XCTAssertTrue(selected.url.path.hasPrefix(selectedRoot.path + "/"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldAsset.url.path), "Changing locations must retain leased readers")
        let usage = try await resolver.managedUsage()
        XCTAssertGreaterThan(usage, 0)
    }

    private final class WeakAsset {
        weak var value: AVURLAsset?
        init(_ value: AVURLAsset?) { self.value = value }
    }

    private final class CheckAction: NativeMediaInputCancellationV4, @unchecked Sendable {
        private let lock = NSLock()
        private var index = 0
        private let limit: Int?
        private let action: (Int) -> Void
        init(limit: Int?, action: @escaping (Int) -> Void = { _ in }) { self.limit = limit; self.action = action }
        func check() throws {
            lock.lock()
            defer { lock.unlock() }
            index += 1
            action(index)
            if let limit, index >= limit { throw CancellationError() }
        }
    }

    private func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "avi"))
    }

    private func temporaryRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("native-import-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func assertOnlyNamespaceLockRemains(
        in cache: URL, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let entries = try FileManager.default.contentsOfDirectory(atPath: cache.path)
        XCTAssertEqual(entries, ["namespace.lock"],
                       "Rejected imports must leave no partial, manifest or published movie", file: file, line: line)
        var status = stat()
        XCTAssertEqual(lstat(cache.appendingPathComponent("namespace.lock").path, &status), 0, file: file, line: line)
        XCTAssertEqual(status.st_mode & S_IFMT, S_IFREG, file: file, line: line)
        XCTAssertEqual(status.st_mode & 0o777, 0o600, file: file, line: line)
        XCTAssertEqual(status.st_uid, getuid(), file: file, line: line)
        XCTAssertEqual(status.st_nlink, 1, file: file, line: line)
        XCTAssertEqual(status.st_size, 0, file: file, line: line)
    }

    private func flags(_ url: URL) throws -> UInt32 {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return value.st_flags
    }

    private func unfreeze(_ url: URL) throws {
        guard chflags(url.path, try flags(url) & ~UInt32(UF_IMMUTABLE)) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    private func removeRoot(_ root: URL) {
        if let contents = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let url as URL in contents { try? unfreeze(url) }
        }
        try? FileManager.default.removeItem(at: root)
    }

    private func payload(_ sample: CMSampleBuffer) throws -> Data {
        let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample))
        let length = CMBlockBufferGetDataLength(block)
        var data = Data(count: length)
        let result = data.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
        }
        XCTAssertEqual(result, noErr)
        return data
    }

    private struct DisplayOrderOracle: Decodable {
        struct Frame: Decodable {
            let presentationValue: Int64
            let sha256: String
        }
        let sourceSHA256: String
        let width: Int
        let height: Int
        let timescale: Int32
        let frames: [Frame]
    }

    private func h264PacketTimeline() async throws -> (
        format: CMVideoFormatDescription,
        packets: [(bytes: Data, timing: CMSampleTimingInfo)],
        end: CMTime
    ) {
        let asset = AVURLAsset(url: try fixture("native-avi-h264"))
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let formats = try await track.load(.formatDescriptions)
        let description = try XCTUnwrap(formats.first)
        let range = try await track.load(.timeRange)
        let reader = try AVAssetReader(asset: asset)
        defer { reader.cancelReading() }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        XCTAssertTrue(reader.startReading(), String(describing: reader.error))
        var packets: [(bytes: Data, timing: CMSampleTimingInfo)] = []
        while let sample = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
            XCTAssertEqual(CMSampleBufferGetNumSamples(sample), 1)
            var timing = CMSampleTimingInfo()
            XCTAssertEqual(CMSampleBufferGetSampleTimingInfo(sample, at: 0, timingInfoOut: &timing), noErr)
            packets.append((bytes: try payload(sample), timing: timing))
        }
        XCTAssertEqual(reader.status, .completed, String(describing: reader.error))
        XCTAssertEqual(packets.count, 72)
        let first = try XCTUnwrap(packets.first)
        let format = try NativeMediaInputAssetResolverV4.canonicalFormat(
            description: description, firstPacket: first.bytes, strategy: .aviH264
        )
        return (format, packets, CMTimeRangeGetEnd(range))
    }

    private func decodedVideoFrames(
        _ asset: AVAsset, width: Int, height: Int
    ) async throws -> [(hash: String, time: CMTime)] {
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        defer { reader.cancelReading() }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ])
        reader.add(output)
        XCTAssertTrue(reader.startReading(), String(describing: reader.error))
        var frames: [(hash: String, time: CMTime)] = []
        while let sample = output.copyNextSampleBuffer() {
            XCTAssertEqual(CMSampleBufferGetNumSamples(sample), 1)
            let pixel = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
            XCTAssertEqual(CVPixelBufferGetPixelFormatType(pixel), kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
            XCTAssertEqual(CVPixelBufferGetWidth(pixel), width)
            XCTAssertEqual(CVPixelBufferGetHeight(pixel), height)
            XCTAssertEqual(CVPixelBufferGetPlaneCount(pixel), 2)
            XCTAssertEqual(CVPixelBufferLockBaseAddress(pixel, .readOnly), kCVReturnSuccess)
            let digest: String
            do {
                defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
                var hash = SHA256()
                for plane in 0..<CVPixelBufferGetPlaneCount(pixel) {
                    let rowBytes = CVPixelBufferGetWidthOfPlane(pixel, plane) * (plane == 0 ? 1 : 2)
                    let rows = CVPixelBufferGetHeightOfPlane(pixel, plane)
                    let stride = CVPixelBufferGetBytesPerRowOfPlane(pixel, plane)
                    let base = try XCTUnwrap(stride >= rowBytes ? CVPixelBufferGetBaseAddressOfPlane(pixel, plane) : nil)
                    for row in 0..<rows {
                        hash.update(data: Data(bytes: base.advanced(by: row * stride), count: rowBytes))
                    }
                }
                digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
            }
            frames.append((hash: digest, time: CMSampleBufferGetPresentationTimeStamp(sample)))
        }
        XCTAssertEqual(reader.status, .completed, String(describing: reader.error))
        return frames
    }

    private func decoded(_ asset: AVAsset, type: AVMediaType) async throws -> (count: Int, bytes: Int, hash: String) {
        let tracks = try await asset.loadTracks(withMediaType: type)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = type == .video
            ? [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
            : [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16,
               AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var count = 0, byteCount = 0
        var hasher = SHA256()
        while let sample = output.copyNextSampleBuffer() {
            count += CMSampleBufferGetNumSamples(sample)
            if CMSampleBufferGetDataBuffer(sample) != nil {
                let bytes = try payload(sample)
                byteCount += bytes.count
                hasher.update(data: bytes)
            }
        }
        XCTAssertEqual(reader.status, .completed, String(describing: reader.error))
        return (count, byteCount, hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }
}
