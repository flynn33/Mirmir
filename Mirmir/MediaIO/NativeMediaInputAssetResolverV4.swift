import AVFoundation
import CoreMedia
import CryptoKit
import Darwin
import Foundation
import ObjectiveC

protocol NativeMediaInputCancellationV4: Sendable {
    func check() throws
}

enum NativeMediaInputAssetErrorV4: LocalizedError {
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let details): return "Native AVI import: \(details)"
        }
    }
}

/// Keeps the selected file authoritative while providing native readers with
/// a verified, packet-preserving sample-entry normalization when required.
actor NativeMediaInputAssetResolverV4 {
    static let shared = NativeMediaInputAssetResolverV4()

    enum Strategy: String, Codable, Sendable {
        case aviMPEG4 = "avi-mpeg4-presentation-v2"
        case aviH264 = "avi-h264-poc-presentation-v2"
        case containerRemux = "container-bitstream-remux-v1"

        static let allValues: [Self] = [.aviMPEG4, .aviH264, .containerRemux]
        static var managedVersions: [String] {
            allValues.map(\.rawValue) + ["avi-mpeg4-sample-entry-v1", "avi-h264-annex-b-v1"]
        }
    }

    private struct Manifest: Codable, Equatable {
        let strategy: Strategy
        let sourceSHA256: String
        let sourceBytes: Int64
        let derivedSHA256: String
        let derivedBytes: Int64
    }

    private struct CachedEntry {
        let url: URL
        let lease: FileHandle
    }

    private struct Stream {
        let output: AVAssetReaderTrackOutput
        let input: AVAssetWriterInput
        let isVideo: Bool
    }

    private var cacheRoot: URL
    private var managedRoots: Set<URL>
    private var activePartials: Set<URL> = []
    private let maximumCacheBytes: Int64
    private static var leaseAssociationKey: UInt8 = 0
    private final class Lease: NSObject {
        let handle: FileHandle
        let released: @Sendable () -> Void
        init(_ handle: FileHandle, released: @escaping @Sendable () -> Void) {
            self.handle = handle
            self.released = released
        }
        deinit { try? handle.close(); released() }
    }
    private final class SoftwareAsset { weak var asset: AVURLAsset?; init(_ asset: AVURLAsset) { self.asset = asset } }
    private var softwareAssets: [URL: SoftwareAsset] = [:]
    private var softwarePresentationAssets: [URL: SoftwareAsset] = [:]
    private var softwareExpectedIdentity: ASHStreamingFileIdentityV4?
    private var reservedBytes: Int64 = 0
    private var activeResolutions = 0
    private final class VerifiedAsset {
        let source: ASHStreamingFileIdentityV4
        let derived: ASHStreamingFileIdentityV4
        let derivedURL: URL
        weak var asset: AVURLAsset?
        init(source: ASHStreamingFileIdentityV4, derived: ASHStreamingFileIdentityV4, asset: AVURLAsset) {
            self.source = source
            self.derived = derived
            self.derivedURL = asset.url
            self.asset = asset
        }
    }
    private var verifiedAssets: [URL: VerifiedAsset] = [:]
    private var verifiedDerived: [URL: ASHStreamingFileIdentityV4] = [:]
    private static let maximumPacketBytes = 64 * 1024 * 1024

    init(cacheRoot: URL? = nil, maximumCacheBytes: Int64 = 16 * 1024 * 1024 * 1024) {
        self.maximumCacheBytes = maximumCacheBytes
        let selected = cacheRoot ?? FileManager.default.urls(
            for: .cachesDirectory, in: .userDomainMask
        )[0].appendingPathComponent("Mirmir/NativeMediaInputsV1", isDirectory: true)
        self.cacheRoot = selected
        self.managedRoots = [selected]
    }

    static func configureCacheRoot(_ root: URL) async throws {
        try await shared.configure(root)
    }

    static func clearInactiveCache() async throws -> (entryCount: Int, byteCount: Int64) {
        try await shared.clearInactiveEntries()
    }

    static func cacheUsage() async throws -> Int64 {
        try await shared.managedUsage()
    }

    func configure(_ root: URL) async throws {
        if root.standardizedFileURL == cacheRoot.standardizedFileURL { return }
        while activeResolutions > 0 || reservedBytes > 0 {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let previous = cacheRoot
        cacheRoot = root
        do { try prepareCacheRoot() }
        catch { cacheRoot = previous; throw error }
        managedRoots.insert(root)
        // Existing assets keep their own leases, while future opens honor the
        // newly selected cache location rather than a weak memo of the old root.
        verifiedAssets.removeAll()
    }

    func clearInactiveEntries() throws -> (entryCount: Int, byteCount: Int64) {
        var entries = 0
        var bytes: Int64 = 0
        for root in managedRoots where Self.isOwnedDirectory(root) {
            try withNamespaceLock(root) {
                for directory in try managedEntries(in: root) where !activePartials.contains(directory) {
                    let size = try entryBytes(directory)
                    if try discardInactiveEntryUnderLock(directory) { entries += 1; bytes += size }
                }
            }
        }
        return (entries, bytes)
    }

    func managedUsage() throws -> Int64 {
        var bytes: Int64 = 0
        for root in managedRoots where Self.isOwnedDirectory(root) {
            try withNamespaceLock(root) {
                for entry in try managedEntries(in: root) { bytes += try entryBytes(entry) }
            }
        }
        return bytes
    }

    private func managedEntries(in root: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter {
            let name = $0.lastPathComponent
            return Self.isOwnedDirectory($0) && (name.hasPrefix(".partial-")
                || (name.count > 64 && name.prefix(64).allSatisfy({ $0.isHexDigit })
                    && Strategy.managedVersions.contains(where: { name == String(name.prefix(64)) + "-" + $0 })))
        }
    }

    private func entryBytes(_ directory: URL) throws -> Int64 {
        var total: Int64 = 0
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            var status = stat()
            if lstat(url.path, &status) == 0, status.st_mode & S_IFMT == S_IFREG { total += status.st_size }
        }
        return total
    }

    static func asset(
        url: URL,
        cancellation: (any NativeMediaInputCancellationV4)? = nil,
        sourceIdentity: ASHStreamingFileIdentityV4? = nil,
        revalidateSource: Bool = false
    ) async throws -> AVURLAsset {
        try await shared.resolvedAsset(url: url, cancellation: cancellation,
                                       sourceIdentity: sourceIdentity, revalidateSource: revalidateSource)
    }

    static func presentationAsset(url: URL) async throws -> AVURLAsset {
        try await shared.resolvedPresentationAsset(url: url)
    }

    private func resolvedPresentationAsset(url: URL) async throws -> AVURLAsset {
        let processing = try await resolvedAsset(url: url)
        guard OriginalSoftwareMediaContext.associated(with: processing) != nil else { return processing }
        if let asset = softwarePresentationAssets[url]?.asset,
           SoftwareVirtualCarrier.presentation(asset, belongsTo: processing),
           try SoftwareVirtualCarrier.reuse(asset, cancellation: nil) {
            return asset
        }
        let asset = try SoftwareVirtualCarrier.makePresentation(from: processing)
        softwarePresentationAssets[url] = SoftwareAsset(asset)
        return asset
    }

    func resolvedAsset(
        url: URL,
        cancellation: (any NativeMediaInputCancellationV4)? = nil,
        sourceIdentity: ASHStreamingFileIdentityV4? = nil,
        revalidateSource: Bool = false
    ) async throws -> AVURLAsset {
        try check(cancellation)
        if let configured = ProcessInfo.processInfo.environment["MIRMIR_SOFTWARE_SOURCE_PATH"]
            .map({ URL(fileURLWithPath: $0).standardizedFileURL }),
           configured == url.standardizedFileURL
            || (url.lastPathComponent == configured.lastPathComponent
                && url.pathComponents.contains("source-snapshot-v4")) {
            let expected = try softwareExpectedIdentity ?? ASHStreamingFileIdentityV4.read(url: configured)
            softwareExpectedIdentity = expected
            let selectedIdentity = try sourceIdentity ?? ASHStreamingFileIdentityV4.read(url: url)
            guard expected.contentSHA256 == selectedIdentity.contentSHA256,
                  expected.byteCount == selectedIdentity.byteCount else {
                throw ProbeFailure("private software source snapshot differs from configured original")
            }
            if let asset = softwareAssets[url]?.asset,
               let context = OriginalSoftwareMediaContext.associated(with: asset),
               try SoftwareVirtualCarrier.reuse(asset, cancellation: cancellation) {
                try context.originalProbe.file.verifyUnchanged(url: url)
                if let sourceIdentity, sourceIdentity.contentSHA256 != context.sourceFacts.sourceHash {
                    throw ProbeFailure("private software source identity changed")
                }
                return asset
            }
            let asset = try await SoftwareVirtualCarrier.make(
                url: url, cancellation: cancellation, sourceIdentity: selectedIdentity
            )
            softwareAssets[url] = SoftwareAsset(asset)
            return asset
        }
        activeResolutions += 1
        defer { activeResolutions -= 1 }
        let operationRoot = cacheRoot
        let admittedIdentity: ASHStreamingFileIdentityV4?
        if revalidateSource, sourceIdentity == nil,
           try (verifiedAssets[url] != nil
                || Self.aviStrategyHint(url) != nil
                || UniversalContainerRemuxV4.containerFamily(url: url) != nil
                || softwareAssets[url] != nil) {
            admittedIdentity = try ASHStreamingFileIdentityV4.read(url: url)
        } else { admittedIdentity = sourceIdentity }
        if let admittedIdentity, let verified = verifiedAssets[url],
           admittedIdentity.contentSHA256 != verified.source.contentSHA256 {
            verifiedAssets.removeValue(forKey: url)
        }
        if let verified = verifiedAssets[url] {
            do {
                try verified.source.verifyUnchanged(url: url)
                try verified.derived.verifyUnchanged(url: verified.derivedURL)
                guard Self.isImmutableFile(verified.derivedURL) else { throw Self.failure("The derived input lost its immutable binding.") }
                if let asset = verified.asset { return asset }
                return try remember(sourceURL: url, identity: verified.source, derivedURL: verified.derivedURL)
            } catch {
                verifiedAssets.removeValue(forKey: url)
                verifiedDerived.removeValue(forKey: verified.derivedURL)
            }
        }
        if try await Self.shouldContainerRemux(url) {
            return try await resolveContainerRemux(
                url: url,
                cancellation: cancellation,
                sourceIdentity: admittedIdentity,
                operationRoot: operationRoot
            )
        }
        if try await Self.shouldSoftwareDecode(url) {
            return try await resolveSoftwareDecode(
                url: url,
                cancellation: cancellation,
                sourceIdentity: admittedIdentity
            )
        }
        // MPEG-4 ASP B/S-VOP AVI is outside the verified native VT presentation
        // contract on Apple Silicon (-8969). Route those AVI sources through the
        // software importer; Simple/ASP I/P AVI remains on aviMPEG4 remux.
        if try await Self.aviMPEG4RequiresSoftwareDecode(url) {
            return try await resolveSoftwareDecode(
                url: url,
                cancellation: cancellation,
                sourceIdentity: admittedIdentity
            )
        }
        guard let hint = try Self.aviStrategyHint(url) else { return Self.nativeAsset(url) }
        // Authenticate before AVFoundation can retain/copy container facts.
        let identity = try admittedIdentity ?? ASHStreamingFileIdentityV4.read(url: url)
        try identity.verifyUnchanged(url: url)
        let original = Self.nativeAsset(url)
        let tracks = try await original.load(.tracks)
        let video = tracks.filter { $0.mediaType == .video }
        guard video.count == 1,
              let description = try await video[0].load(.formatDescriptions).first else {
            return original
        }
        let strategy: Strategy
        switch CMFormatDescriptionGetMediaSubType(description) {
        case 0x464d5034: strategy = .aviMPEG4 // FMP4
        case 0x48323634: strategy = .aviH264 // H264
        default: return original
        }
        guard strategy == hint else { throw Self.failure("The AVI codec identity changed while opening the source.") }
        try identity.verifyUnchanged(url: url)
        try check(cancellation)
        try prepareCacheRoot(operationRoot)
        let key = identity.contentSHA256.rawValue + "-" + strategy.rawValue
        let directory = operationRoot.appendingPathComponent(key, isDirectory: true)
        do {
            if let cached = try await cachedURL(directory, identity: identity, strategy: strategy, original: original, tracks: tracks, description: description, sourceURL: url, cancellation: cancellation) {
                try identity.verifyUnchanged(url: url)
                return try remember(sourceURL: url, identity: identity, derivedURL: cached.url, lease: cached.lease)
            }
        } catch {
            if error is CancellationError { throw error }
            // Only an inactive entry in this private derived cache may be
            // regenerated. An entry held by a reader is never evicted.
            guard try discardInactiveEntry(directory) else { throw error }
        }
        let reservation = identity.byteCount.multipliedReportingOverflow(by: 2)
        guard !reservation.overflow else { throw Self.failure("Source size exceeds the import byte budget.") }
        let budget = reservation.partialValue.addingReportingOverflow(1_048_576)
        guard !budget.overflow else { throw Self.failure("Source size exceeds the import byte budget.") }
        try reserveCacheSpace(budget.partialValue, at: operationRoot)
        reservedBytes += budget.partialValue
        defer { reservedBytes -= budget.partialValue }
        // Each attempt owns only its unique partial directory. A concurrent
        // attempt may publish the same identity while this actor is awaiting IO.
        let partial = operationRoot.appendingPathComponent(".partial-\(UUID().uuidString)", isDirectory: true)
        let partialLease = try withNamespaceLock(operationRoot) {
            guard mkdir(partial.path, 0o700) == 0 else {
                throw Self.failure("Cannot create the private import staging directory.")
            }
            do {
                let lease = try leaseFile(partial)
                guard flock(lease.fileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
                    try? lease.close()
                    throw Self.failure("Cannot reserve the private import staging directory.")
                }
                return lease
            } catch {
                try? Self.removeOwnedDirectory(partial)
                throw error
            }
        }
        activePartials.insert(partial)
        defer {
            activePartials.remove(partial)
            try? withNamespaceLock(operationRoot) {
                try Self.removeOwnedDirectory(partial)
                try? partialLease.close()
            }
            try? partialLease.close()
        }
        let output = partial.appendingPathComponent("input.mov")
        try await normalize(original, tracks: tracks, description: description,
                            strategy: strategy, output: output,
                            sourceBytes: identity.byteCount, cancellation: cancellation)
        try check(cancellation)
        try Self.clearContainerDates(output)
        let canonical = try canonicalFormat(original, track: video[0], description: description,
                                            strategy: strategy, cancellation: cancellation)
        try await NativeMediaInputVerificationV4.verify(original: original, derived: Self.nativeAsset(output),
            canonicalFormat: canonical, strategy: strategy, cancellation: cancellation)
        try Self.verifySourceContent(identity, url: url)
        try Self.makeImmutable(output)
        let derived = try ASHStreamingFileIdentityV4.read(url: output)
        let manifest = Manifest(strategy: strategy,
                                sourceSHA256: identity.contentSHA256.rawValue,
                                sourceBytes: identity.byteCount,
                                derivedSHA256: derived.contentSHA256.rawValue,
                                derivedBytes: derived.byteCount)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(manifest).write(to: partial.appendingPathComponent("manifest.json"), options: .atomic)
        try check(cancellation)
        guard flock(partialLease.fileDescriptor, LOCK_SH | LOCK_NB) == 0 else {
            throw Self.failure("Cannot publish the native import staging lease.")
        }
        var publishedOwnEntry = false
        for _ in 0..<4 {
            publishedOwnEntry = try withNamespaceLock(operationRoot) {
                if FileManager.default.fileExists(atPath: directory.path) { return false }
                try FileManager.default.moveItem(at: partial, to: directory)
                return true
            }
            if publishedOwnEntry { break }
            if let cached = try await cachedURL(directory, identity: identity, strategy: strategy,
                original: original, tracks: tracks, description: description,
                sourceURL: url, cancellation: cancellation) {
                return try remember(sourceURL: url, identity: identity, derivedURL: cached.url, lease: cached.lease)
            }
            // An inactive winner may be cleared before its shared lease is
            // acquired. Our own leased staging copy remains ready to publish.
            try check(cancellation)
        }
        guard publishedOwnEntry else { throw Self.failure("The derived cache kept changing during publication; retry import.") }
        let published = directory.appendingPathComponent("input.mov")
        verifiedDerived[published] = try ASHStreamingFileIdentityV4.read(url: published)
        return try remember(sourceURL: url, identity: identity, derivedURL: published)
    }

    private func remember(sourceURL: URL, identity: ASHStreamingFileIdentityV4, derivedURL: URL, lease: FileHandle? = nil) throws -> AVURLAsset {
        let derived = try verifiedDerived[derivedURL] ?? ASHStreamingFileIdentityV4.read(url: derivedURL)
        try identity.verifyUnchanged(url: sourceURL)
        try derived.verifyUnchanged(url: derivedURL)
        let asset = Self.nativeAsset(derivedURL)
        try retainLease(derivedURL.deletingLastPathComponent(), asset: asset, existing: lease)
        verifiedAssets[sourceURL] = VerifiedAsset(source: identity, derived: derived, asset: asset)
        return asset
    }

    private static func nativeAsset(_ url: URL) -> AVURLAsset {
        var options: [String: Any] = [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        // AVFoundation otherwise chooses the parser from the filename extension.
        // Only a verified RIFF/AVI header may override that hint.
        if let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            if let header = try? handle.read(upToCount: 12), header.count == 12,
               header.prefix(4) == Data("RIFF".utf8), header.suffix(4) == Data("AVI ".utf8) {
                options[AVURLAssetOverrideMIMETypeKey] = "video/avi"
            }
        }
        return AVURLAsset(url: url, options: options)
    }

    private static func shouldContainerRemux(_ url: URL) async throws -> Bool {
        guard let family = try UniversalContainerRemuxV4.containerFamily(url: url) else { return false }
        let probe = try UniversalContainerRemuxV4.probe(url: url)
        // MPEG-2 Transport Stream must not remux: product remux yields inflated
        // AVFoundation decode (73 vs 72) and a stretched duration on this fixture.
        if family == "mpegts", probe.videoCodecName == "mpeg2video" {
            return false
        }
        if try await nativeOpensAuthoritatively(url) { return false }
        return probe.admissible
    }

    /// Remux-inadmissible containers that AVFoundation cannot open (VP9/WebM, WMV/ASF, …),
    /// plus MPEG-2 Transport Stream (native opens on some hosts but fails durable cadence).
    private static func shouldSoftwareDecode(_ url: URL) async throws -> Bool {
        guard let family = try UniversalContainerRemuxV4.containerFamily(url: url) else { return false }
        let probe = try UniversalContainerRemuxV4.probe(url: url)
        // Prefer software for mpeg2video-in-mpegts: native PTS offsets fail the
        // durable nominal cadence lattice; remux is unsafe (see remux gate above).
        if family == "mpegts", probe.videoCodecName == "mpeg2video" {
            return true
        }
        if try await nativeOpensAuthoritatively(url) { return false }
        return !probe.admissible
    }

    /// True when an FMP4 AVI carries B-VOP or S-VOP pictures that the native
    /// MPEG-4 AVI remux/presentation contract cannot qualify for VT decode.
    static func aviMPEG4RequiresSoftwareDecode(_ url: URL) async throws -> Bool {
        guard try aviStrategyHint(url) == .aviMPEG4 else { return false }
        let asset = nativeAsset(url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard tracks.count == 1, let track = tracks.first else { return false }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else { return false }
        reader.add(output)
        defer { reader.cancelReading() }
        guard reader.startReading() else { return false }
        var inspected = 0
        while let sample = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(sample) > 0,
                  let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            guard length > 0, length <= 64 * 1024 * 1024 else { return false }
            var bytes = Data(count: length)
            let status = bytes.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(
                    block, atOffset: 0, dataLength: length, destination: $0.baseAddress!
                )
            }
            guard status == noErr else { return false }
            if NativeAVIMPEG4PresentationOrderV4.containsBSVOP(bytes) {
                return true
            }
            inspected += 1
            // A full IPBB group is enough to decide; keep the probe bounded.
            if inspected >= 24 { break }
        }
        return false
    }

    private static func nativeOpensAuthoritatively(_ url: URL) async throws -> Bool {
        let native = nativeAsset(url)
        do {
            let readable = try await native.load(.isReadable)
            let playable = try await native.load(.isPlayable)
            if readable && playable {
                let tracks = try await native.load(.tracks)
                let video = tracks.filter { $0.mediaType == .video }
                if video.count == 1,
                   let description = try await video[0].load(.formatDescriptions).first {
                    _ = description
                    return true
                }
            }
        } catch {
            return false
        }
        return false
    }

    private func resolveSoftwareDecode(
        url: URL,
        cancellation: (any NativeMediaInputCancellationV4)?,
        sourceIdentity: ASHStreamingFileIdentityV4?
    ) async throws -> AVURLAsset {
        let identity = try sourceIdentity ?? ASHStreamingFileIdentityV4.read(url: url)
        try identity.verifyUnchanged(url: url)
        if let asset = softwareAssets[url]?.asset,
           let context = OriginalSoftwareMediaContext.associated(with: asset),
           try SoftwareVirtualCarrier.reuse(asset, cancellation: cancellation) {
            try context.originalProbe.file.verifyUnchanged(url: url)
            if identity.contentSHA256 != context.sourceFacts.sourceHash {
                throw ProbeFailure("private software source identity changed")
            }
            return asset
        }
        let asset = try await SoftwareVirtualCarrier.make(
            url: url, cancellation: cancellation, sourceIdentity: identity
        )
        softwareAssets[url] = SoftwareAsset(asset)
        return asset
    }

    private func resolveContainerRemux(
        url: URL,
        cancellation: (any NativeMediaInputCancellationV4)?,
        sourceIdentity: ASHStreamingFileIdentityV4?,
        operationRoot: URL
    ) async throws -> AVURLAsset {
        let identity = try sourceIdentity ?? ASHStreamingFileIdentityV4.read(url: url)
        try identity.verifyUnchanged(url: url)
        let probe = try UniversalContainerRemuxV4.probe(url: url)
        guard probe.admissible else {
            throw Self.failure("The source codecs require software decode; remux alone cannot admit them.")
        }
        let strategy = Strategy.containerRemux
        try check(cancellation)
        try prepareCacheRoot(operationRoot)
        let key = identity.contentSHA256.rawValue + "-" + strategy.rawValue
        let directory = operationRoot.appendingPathComponent(key, isDirectory: true)
        do {
            if let cached = try await cachedRemuxURL(directory, identity: identity, strategy: strategy, sourceURL: url) {
                try identity.verifyUnchanged(url: url)
                return try remember(sourceURL: url, identity: identity, derivedURL: cached.url, lease: cached.lease)
            }
        } catch {
            if error is CancellationError { throw error }
            guard try discardInactiveEntry(directory) else { throw error }
        }
        let reservation = identity.byteCount.multipliedReportingOverflow(by: 2)
        guard !reservation.overflow else { throw Self.failure("Source size exceeds the import byte budget.") }
        let budget = reservation.partialValue.addingReportingOverflow(1_048_576)
        guard !budget.overflow else { throw Self.failure("Source size exceeds the import byte budget.") }
        try reserveCacheSpace(budget.partialValue, at: operationRoot)
        reservedBytes += budget.partialValue
        defer { reservedBytes -= budget.partialValue }
        let partial = operationRoot.appendingPathComponent(".partial-\(UUID().uuidString)", isDirectory: true)
        let partialLease = try withNamespaceLock(operationRoot) {
            guard mkdir(partial.path, 0o700) == 0 else {
                throw Self.failure("Cannot create the private import staging directory.")
            }
            do {
                let lease = try leaseFile(partial)
                guard flock(lease.fileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
                    try? lease.close()
                    throw Self.failure("Cannot reserve the private import staging directory.")
                }
                return lease
            } catch {
                try? Self.removeOwnedDirectory(partial)
                throw error
            }
        }
        activePartials.insert(partial)
        defer {
            activePartials.remove(partial)
            try? withNamespaceLock(operationRoot) {
                try Self.removeOwnedDirectory(partial)
                try? partialLease.close()
            }
            try? partialLease.close()
        }
        let output = partial.appendingPathComponent("input.mov")
        try UniversalContainerRemuxV4.remuxToMOV(input: url, output: output)
        try check(cancellation)
        try Self.clearContainerDates(output)
        try await Self.verifyRemuxedAsset(Self.nativeAsset(output), expected: probe, cancellation: cancellation)
        try Self.verifySourceContent(identity, url: url)
        try Self.makeImmutable(output)
        let derived = try ASHStreamingFileIdentityV4.read(url: output)
        let manifest = Manifest(strategy: strategy,
                                sourceSHA256: identity.contentSHA256.rawValue,
                                sourceBytes: identity.byteCount,
                                derivedSHA256: derived.contentSHA256.rawValue,
                                derivedBytes: derived.byteCount)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(manifest).write(to: partial.appendingPathComponent("manifest.json"), options: .atomic)
        try check(cancellation)
        guard flock(partialLease.fileDescriptor, LOCK_SH | LOCK_NB) == 0 else {
            throw Self.failure("Cannot publish the native import staging lease.")
        }
        var publishedOwnEntry = false
        for _ in 0..<4 {
            publishedOwnEntry = try withNamespaceLock(operationRoot) {
                if FileManager.default.fileExists(atPath: directory.path) { return false }
                try FileManager.default.moveItem(at: partial, to: directory)
                return true
            }
            if publishedOwnEntry { break }
            if let cached = try await cachedRemuxURL(directory, identity: identity, strategy: strategy, sourceURL: url) {
                return try remember(sourceURL: url, identity: identity, derivedURL: cached.url, lease: cached.lease)
            }
            try check(cancellation)
        }
        guard publishedOwnEntry else { throw Self.failure("The derived cache kept changing during publication; retry import.") }
        let published = directory.appendingPathComponent("input.mov")
        verifiedDerived[published] = try ASHStreamingFileIdentityV4.read(url: published)
        return try remember(sourceURL: url, identity: identity, derivedURL: published)
    }

    private func cachedRemuxURL(
        _ directory: URL, identity: ASHStreamingFileIdentityV4, strategy: Strategy, sourceURL: URL
    ) async throws -> CachedEntry? {
        let acquired: FileHandle? = try withNamespaceLock(directory.deletingLastPathComponent()) {
            guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
            guard Self.isOwnedDirectory(directory) else { throw Self.failure("The derived cache entry is unsafe.") }
            let lease = try leaseFile(directory)
            guard flock(lease.fileDescriptor, LOCK_SH | LOCK_NB) == 0 else {
                try? lease.close()
                throw Self.failure("The derived cache entry is being retired.")
            }
            return lease
        }
        guard let lease = acquired else { return nil }
        var transferred = false
        defer { if !transferred { try? lease.close() } }
        let output = directory.appendingPathComponent("input.mov")
        let manifestURL = directory.appendingPathComponent("manifest.json")
        guard Self.isImmutableFile(output), Self.isOwnedRegularFile(manifestURL),
              let size = try manifestURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 4096,
              let manifest = try? JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL)),
              manifest.strategy == strategy,
              manifest.sourceSHA256 == identity.contentSHA256.rawValue,
              manifest.sourceBytes == identity.byteCount else {
            throw Self.failure("The derived input cache identity is invalid; remove this cache entry and retry.")
        }
        let derived: ASHStreamingFileIdentityV4
        if let verified = verifiedDerived[output] {
            try verified.verifyUnchanged(url: output)
            derived = verified
        } else {
            derived = try ASHStreamingFileIdentityV4.read(url: output)
        }
        guard derived.contentSHA256.rawValue == manifest.derivedSHA256,
              derived.byteCount == manifest.derivedBytes else {
            throw Self.failure("The derived input cache content changed; remove this cache entry and retry.")
        }
        if verifiedDerived[output] == nil {
            let probe = try UniversalContainerRemuxV4.probe(url: sourceURL)
            try await Self.verifyRemuxedAsset(Self.nativeAsset(output), expected: probe, cancellation: nil)
            try Self.verifySourceContent(identity, url: sourceURL)
            try derived.verifyUnchanged(url: output)
            guard Self.isImmutableFile(output) else { throw Self.failure("The derived input lost its immutable binding.") }
        }
        verifiedDerived[output] = derived
        transferred = true
        return CachedEntry(url: output, lease: lease)
    }

    private static func verifyRemuxedAsset(
        _ asset: AVURLAsset,
        expected: UniversalContainerRemuxV4.Probe,
        cancellation: (any NativeMediaInputCancellationV4)?
    ) async throws {
        try cancellation?.check()
        try Task.checkCancellation()
        guard try await asset.load(.isReadable), try await asset.load(.isPlayable) else {
            throw failure("The remuxed MOV is not readable/playable by AVFoundation.")
        }
        let tracks = try await asset.load(.tracks)
        let video = tracks.filter { $0.mediaType == .video }
        let audio = tracks.filter { $0.mediaType == .audio }
        guard video.count == 1 else {
            throw failure("The remuxed MOV must expose exactly one video track.")
        }
        if expected.hasAudio {
            guard audio.count >= 1 else {
                throw failure("The remuxed MOV dropped the source audio track.")
            }
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: video[0], outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw failure("The remuxed MOV cannot decode video samples.")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw failure(reader.error?.localizedDescription ?? "The remuxed MOV failed to start decoding.")
        }
        var frames = 0
        while let sample = output.copyNextSampleBuffer() {
            try cancellation?.check()
            try Task.checkCancellation()
            if CMSampleBufferGetNumSamples(sample) > 0 { frames += 1 }
            if frames >= 1 { break }
        }
        guard frames >= 1 else {
            throw failure("The remuxed MOV produced no decodable video frames.")
        }
        reader.cancelReading()
    }

    private static func aviStrategyHint(_ url: URL) throws -> Strategy? {
        guard url.isFileURL else { return nil }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 12) ?? Data()
        guard header.count == 12, header.prefix(4) == Data("RIFF".utf8),
              header.suffix(4) == Data("AVI ".utf8) else { return nil }
        let prefix = header + (try handle.read(upToCount: 1_048_564) ?? Data())
        let bytes = [UInt8](prefix)
        func scan(_ start: Int, _ end: Int, _ depth: Int) -> Strategy? {
            guard depth <= 4 else { return nil }
            var cursor = start
            while cursor <= end - 8 {
                let size = (0..<4).reduce(UInt32(0)) { $0 | (UInt32(bytes[cursor + 4 + $1]) << (8 * $1)) }
                let tag = String(bytes: bytes[cursor..<(cursor + 4)], encoding: .ascii)
                let payload = cursor + 8
                guard Int(size) <= end - payload else { return nil }
                if tag == "strh", size >= 8, Data(bytes[payload..<(payload + 4)]) == Data("vids".utf8) {
                    let codec = Data(bytes[(payload + 4)..<(payload + 8)])
                    if codec == Data("FMP4".utf8) { return .aviMPEG4 }
                    if codec == Data("H264".utf8) { return .aviH264 }
                }
                if tag == "LIST", size >= 4,
                   let result = scan(payload + 4, payload + Int(size), depth + 1) { return result }
                cursor = payload + Int(size) + Int(size & 1)
            }
            return nil
        }
        return scan(12, bytes.count, 0)
    }

    private func prepareCacheRoot(_ selected: URL? = nil) throws {
        let root = selected ?? cacheRoot
        try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard mkdir(root.path, 0o700) == 0 || errno == EEXIST else {
            throw Self.failure("Cannot create the private derived input cache directory.")
        }
        var status = stat()
        guard lstat(root.path, &status) == 0,
              status.st_mode & S_IFMT == S_IFDIR, status.st_uid == getuid(),
              status.st_mode & 0o077 == 0 else {
            throw Self.failure("The derived input cache is not a private owned directory.")
        }
    }

    private func cachedURL(
        _ directory: URL, identity: ASHStreamingFileIdentityV4, strategy: Strategy,
        original: AVAsset, tracks: [AVAssetTrack], description: CMFormatDescription,
        sourceURL: URL, cancellation: (any NativeMediaInputCancellationV4)?
    ) async throws -> CachedEntry? {
        let acquired: FileHandle? = try withNamespaceLock(directory.deletingLastPathComponent()) {
            guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
            guard Self.isOwnedDirectory(directory) else { throw Self.failure("The derived cache entry is unsafe.") }
            let lease = try leaseFile(directory)
            guard flock(lease.fileDescriptor, LOCK_SH | LOCK_NB) == 0 else {
                try? lease.close()
                throw Self.failure("The derived cache entry is being retired.")
            }
            return lease
        }
        guard let lease = acquired else { return nil }
        var transferred = false
        defer { if !transferred { try? lease.close() } }
        let output = directory.appendingPathComponent("input.mov")
        let manifestURL = directory.appendingPathComponent("manifest.json")
        guard Self.isImmutableFile(output), Self.isOwnedRegularFile(manifestURL),
              let size = try manifestURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 4096,
              let manifest = try? JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL)),
              manifest.strategy == strategy,
              manifest.sourceSHA256 == identity.contentSHA256.rawValue,
              manifest.sourceBytes == identity.byteCount else {
            throw Self.failure("The derived input cache identity is invalid; remove this cache entry and retry.")
        }
        let derived: ASHStreamingFileIdentityV4
        if let verified = verifiedDerived[output] {
            try verified.verifyUnchanged(url: output)
            derived = verified
        } else {
            derived = try ASHStreamingFileIdentityV4.read(url: output)
        }
        guard derived.contentSHA256.rawValue == manifest.derivedSHA256,
              derived.byteCount == manifest.derivedBytes else {
            throw Self.failure("The derived input cache content changed; remove this cache entry and retry.")
        }
        if verifiedDerived[output] == nil {
            _ = try await validatePreservation(original, tracks: tracks)
            let video = tracks.first { $0.mediaType == .video }!
            let canonical = try canonicalFormat(original, track: video, description: description,
                                                 strategy: strategy, cancellation: cancellation)
            try await NativeMediaInputVerificationV4.verify(original: original, derived: Self.nativeAsset(output),
                canonicalFormat: canonical, strategy: strategy, cancellation: cancellation)
            try Self.verifySourceContent(identity, url: sourceURL)
            try derived.verifyUnchanged(url: output)
            guard Self.isImmutableFile(output) else { throw Self.failure("The derived input lost its immutable binding.") }
        }
        verifiedDerived[output] = derived
        transferred = true
        return CachedEntry(url: output, lease: lease)
    }

    private static func verifySourceContent(_ expected: ASHStreamingFileIdentityV4, url: URL) throws {
        let observed = try ASHStreamingFileIdentityV4.read(url: url)
        guard observed.contentSHA256 == expected.contentSHA256, observed.byteCount == expected.byteCount else {
            throw failure("The original AVI changed while its native decode asset was being verified.")
        }
        try expected.verifyUnchanged(url: url)
    }

    private static func isImmutableFile(_ url: URL) -> Bool {
        var status = stat()
        return isOwnedRegularFile(url) && lstat(url.path, &status) == 0
            && status.st_flags & UInt32(UF_IMMUTABLE) != 0
    }

    private static func makeImmutable(_ url: URL) throws {
        guard isOwnedRegularFile(url) else { throw failure("The derived input file is unsafe.") }
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        var status = stat()
        guard fstat(handle.fileDescriptor, &status) == 0,
              fchflags(handle.fileDescriptor, status.st_flags | UInt32(UF_IMMUTABLE)) == 0 else {
            throw failure("The derived input cannot be made immutable on this cache volume.")
        }
    }

    private static func removeOwnedDirectory(_ directory: URL) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        guard isOwnedDirectory(directory) else { throw failure("The derived input directory is unsafe.") }
        let output = directory.appendingPathComponent("input.mov")
        if isOwnedRegularFile(output) {
            var status = stat()
            guard lstat(output.path, &status) == 0,
                  chflags(output.path, status.st_flags & ~UInt32(UF_IMMUTABLE)) == 0 else {
                throw failure("Cannot retire the owned derived input.")
            }
        }
        try FileManager.default.removeItem(at: directory)
    }

    private static func isOwnedDirectory(_ url: URL) -> Bool {
        var status = stat()
        return lstat(url.path, &status) == 0 && status.st_mode & S_IFMT == S_IFDIR
            && status.st_uid == getuid() && status.st_mode & 0o077 == 0
    }

    private func retainLease(_ directory: URL, asset: AVURLAsset, existing: FileHandle? = nil) throws {
        let handle: FileHandle
        if let existing { handle = existing }
        else {
            handle = try withNamespaceLock(directory.deletingLastPathComponent()) {
                let lease = try leaseFile(directory)
                guard flock(lease.fileDescriptor, LOCK_SH | LOCK_NB) == 0 else {
                    try? lease.close()
                    throw Self.failure("The derived input is being evicted; retry import.")
                }
                return lease
            }
        }
        guard flock(handle.fileDescriptor, LOCK_SH | LOCK_NB) == 0 else {
            throw Self.failure("The derived input is being evicted; retry import.")
        }
        let root = directory.deletingLastPathComponent()
        let lease = Lease(handle) { [weak self] in
            Task { await self?.evictReleasedEntries(in: root) }
        }
        objc_setAssociatedObject(asset, &Self.leaseAssociationKey, lease, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: directory.path)
    }

    private func evictReleasedEntries(in root: URL) {
        guard reservedBytes == 0 else { return }
        try? reserveCacheSpace(0, at: root)
    }

    /// Serializes only namespace changes and lease acquisition. Hashing,
    /// media IO and all suspension points run after this lock is released.
    private func withNamespaceLock<T>(_ root: URL, _ action: () throws -> T) throws -> T {
        try prepareCacheRoot(root)
        let descriptor = open(root.appendingPathComponent("namespace.lock").path,
                              O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Self.failure("Cannot open the derived cache namespace lock.") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == getuid(), status.st_nlink == 1, status.st_mode & 0o077 == 0,
              flock(descriptor, LOCK_EX) == 0 else {
            throw Self.failure("Cannot acquire the private derived cache namespace lock.")
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try action()
    }

    private func leaseFile(_ directory: URL) throws -> FileHandle {
        guard Self.isOwnedDirectory(directory) else { throw Self.failure("The derived input directory is unsafe.") }
        let path = directory.appendingPathComponent("lease").path
        let descriptor = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Self.failure("Cannot acquire the derived input lease.") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == getuid(), status.st_nlink == 1 else {
            throw Self.failure("The derived input lease is unsafe.")
        }
        return handle
    }

    private func discardInactiveEntry(_ directory: URL) throws -> Bool {
        try withNamespaceLock(directory.deletingLastPathComponent()) {
            try discardInactiveEntryUnderLock(directory)
        }
    }

    private func discardInactiveEntryUnderLock(_ directory: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: directory.path) else { return true }
        guard Self.isOwnedDirectory(directory) else { return false }
        let lease = try leaseFile(directory)
        guard flock(lease.fileDescriptor, LOCK_EX | LOCK_NB) == 0 else { return false }
        defer { try? lease.close() }
        try Self.removeOwnedDirectory(directory)
        verifiedDerived.removeValue(forKey: directory.appendingPathComponent("input.mov"))
        return true
    }

    private func reserveCacheSpace(_ requested: Int64, at root: URL) throws {
        guard requested >= 0, maximumCacheBytes >= 0 else { throw Self.failure("Native input cache limits are invalid.") }
        if requested > 0 {
            let values = try root.resourceValues(forKeys: [
                .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey
            ])
            let available = values.volumeAvailableCapacityForImportantUsage
                ?? values.volumeAvailableCapacity.map(Int64.init) ?? 0
            let headroom: Int64 = 64 * 1024 * 1024
            guard available >= headroom, reservedBytes <= available - headroom,
                  requested <= available - headroom - reservedBytes else {
                throw Self.failure("The selected cache volume lacks space for a packet-preserving input copy.")
            }
        }
        let children = try FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.contentModificationDateKey])
        var entries: [(URL, Int64, Date)] = []
        var used: Int64 = 0
        for child in children {
            let name = child.lastPathComponent
            guard name.count > 64, name.prefix(64).allSatisfy({ $0.isHexDigit }),
                  Strategy.managedVersions.contains(where: { name == String(name.prefix(64)) + "-" + $0 }),
                  Self.isOwnedDirectory(child) else { continue }
            let file = child.appendingPathComponent("input.mov")
            var status = stat()
            guard lstat(file.path, &status) == 0, status.st_mode & S_IFMT == S_IFREG else { continue }
            let bytes = status.st_size
            guard bytes >= 0, used <= Int64.max - bytes else { throw Self.failure("Derived cache usage overflowed.") }
            used += bytes
            entries.append((child, bytes, (try? child.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast))
        }
        for (directory, bytes, _) in entries.sorted(by: { $0.2 < $1.2 }) {
            let target = maximumCacheBytes - min(requested, maximumCacheBytes)
            if used <= target { break }
            if try discardInactiveEntry(directory) { used -= bytes }
        }
        // Retention pressure never invalidates an active asset. A single input
        // may exceed the retention budget when actual disk capacity permits;
        // its lease release makes that entry eligible for immediate eviction.
    }

    private static func isOwnedRegularFile(_ url: URL) -> Bool {
        var status = stat()
        return lstat(url.path, &status) == 0 && status.st_mode & S_IFMT == S_IFREG
            && status.st_uid == getuid() && status.st_nlink == 1
    }

    private func normalize(
        _ asset: AVURLAsset, tracks: [AVAssetTrack], description: CMFormatDescription,
        strategy: Strategy, output: URL, sourceBytes: Int64,
        cancellation: (any NativeMediaInputCancellationV4)?
    ) async throws {
        let end = try await validatePreservation(asset, tracks: tracks)
        let video = tracks.first { $0.mediaType == .video }!
        let format = try canonicalFormat(asset, track: video, description: description,
                                         strategy: strategy, cancellation: cancellation)
        var presentationClock = try NativeAVICompressedPresentationClockV4(strategy: strategy, format: format)
        let videoEnd = CMTimeRangeGetEnd(try await video.load(.timeRange))
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        var completed = false
        defer {
            reader.cancelReading()
            if !completed { writer.cancelWriting() }
        }
        // The admitted AVI clocks are 600 and/or the exact PCM sample clock.
        var scale: Int64 = 600
        for track in tracks {
            let value = Int64(try await track.load(.naturalTimeScale))
            guard value > 0 else { throw Self.failure("A source clock is not positive.") }
            var a = scale, b = value
            while b != 0 { (a, b) = (b, a % b) }
            let next = (scale / a).multipliedReportingOverflow(by: value)
            guard !next.overflow, next.partialValue <= Int64(Int32.max) else {
                throw Self.failure("The source clocks cannot be represented exactly in MOV.")
            }
            scale = next.partialValue
        }
        writer.movieTimeScale = Int32(scale)
        var streams: [Stream] = []
        for track in tracks {
            let isVideo = track.mediaType == .video
            let hint = isVideo ? format : try await track.load(.formatDescriptions)[0]
            let input = AVAssetWriterInput(mediaType: track.mediaType, outputSettings: nil, sourceFormatHint: hint)
            input.expectsMediaDataInRealTime = false
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            guard reader.canAdd(output), writer.canAdd(input) else {
                throw Self.failure("Native readers/writers cannot preserve every source track.")
            }
            reader.add(output)
            writer.add(input)
            streams.append(Stream(output: output, input: input, isVideo: isVideo))
        }
        guard reader.startReading(), writer.startWriting() else {
            throw writer.error ?? reader.error ?? Self.failure("Native input normalization could not start.")
        }
        writer.startSession(atSourceTime: .zero)
        var active = Array(repeating: true, count: streams.count)
        var lastProgress = Date()
        let allowance = sourceBytes.multipliedReportingOverflow(by: 2)
        guard !allowance.overflow else { throw Self.failure("Source size exceeds the import byte budget.") }
        var appendedBytes: Int64 = 0
        while active.contains(true) {
            try check(cancellation)
            var progressed = false
            for index in streams.indices where active[index] {
                let stream = streams[index]
                guard stream.input.isReadyForMoreMediaData else { continue }
                guard let source = stream.output.copyNextSampleBuffer() else {
                    stream.input.markAsFinished()
                    active[index] = false
                    progressed = true
                    continue
                }
                guard CMSampleBufferGetNumSamples(source) > 0 else { progressed = true; continue }
                let sample: CMSampleBuffer
                if stream.isVideo {
                    sample = try Self.rebound(source, format: format, strategy: strategy,
                                              presentationClock: &presentationClock)
                } else {
                    sample = try UniformPCMSampleBufferV4.compactingSizes(in: source)
                }
                let bytes = CMSampleBufferGetDataBuffer(sample).map(CMBlockBufferGetDataLength) ?? 0
                guard bytes <= Self.maximumPacketBytes,
                      Int64(bytes) <= allowance.partialValue - appendedBytes else {
                    throw Self.failure("The normalized input exceeded its bounded source byte budget.")
                }
                appendedBytes += Int64(bytes)
                guard stream.input.append(sample) else {
                    throw writer.error ?? Self.failure("Native input packet append failed.")
                }
                progressed = true
            }
            guard writer.status == .writing else { throw writer.error ?? Self.failure("Native input writer stopped.") }
            if progressed { lastProgress = Date() }
            else {
                guard Date().timeIntervalSince(lastProgress) < 30 else {
                    throw Self.failure("Native input normalization stopped making progress.")
                }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        }
        guard reader.status == .completed else { throw reader.error ?? Self.failure("Native input reader did not finish.") }
        try presentationClock.finish(expectedEnd: videoEnd)
        writer.endSession(atSourceTime: end)
        await writer.finishWriting()
        try check(cancellation)
        guard writer.status == .completed else { throw writer.error ?? Self.failure("Native input writer did not finish.") }
        completed = true
    }

    private func validatePreservation(_ asset: AVAsset, tracks: [AVAssetTrack]) async throws -> CMTime {
        guard (1...2).contains(tracks.count), tracks.filter({ $0.mediaType == .video }).count == 1,
              tracks.allSatisfy({ $0.mediaType == .video || $0.mediaType == .audio }),
              try await asset.load(.metadata).isEmpty,
              try await asset.load(.trackGroups).isEmpty,
              try await asset.load(.availableChapterLocales).isEmpty else {
            throw Self.failure("AVI normalization cannot yet preserve this metadata, chapter, group, or track inventory.")
        }
        var end = CMTime.zero
        for track in tracks {
            let range = try await track.load(.timeRange)
            let segments = try await track.load(.segments)
            guard try await track.load(.isEnabled),
                  try await track.load(.metadata).isEmpty,
                  try await track.load(.availableTrackAssociationTypes).isEmpty,
                  try await track.load(.languageCode) == nil,
                  try await track.load(.extendedLanguageTag) == nil,
                  try await track.load(.preferredTransform) == .identity,
                  CMTimeCompare(range.start, .zero) == 0,
                  range.duration.isNumeric, range.duration.epoch == 0,
                  !range.duration.flags.contains(.hasBeenRounded),
                  segments.count == 1, !segments[0].isEmpty,
                  CMTimeCompare(segments[0].timeMapping.source.start, .zero) == 0,
                  CMTimeCompare(segments[0].timeMapping.target.start, .zero) == 0,
                  CMTimeCompare(segments[0].timeMapping.source.duration, range.duration) == 0,
                  CMTimeCompare(segments[0].timeMapping.target.duration, range.duration) == 0 else {
                throw Self.failure("AVI normalization cannot yet preserve this track's metadata, language, transform, associations, or edits.")
            }
            let formats = try await track.load(.formatDescriptions)
            guard formats.count == 1 else { throw Self.failure("AVI format changes cannot be normalized.") }
            if track.mediaType == .video {
                let extensions = CMFormatDescriptionGetExtensions(formats[0]) as NSDictionary?
                guard extensions == nil || extensions?.count == 0,
                      try await track.load(.preferredVolume) == 1 else {
                    throw Self.failure("AVI container format metadata or video volume is outside the verified import contract.")
                }
            }
            if track.mediaType == .audio {
                guard try await track.load(.preferredVolume) == 1,
                      let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formats[0]),
                      asbd.pointee.mFormatID == kAudioFormatLinearPCM else {
                    throw Self.failure("AVI normalization currently preserves only PCM audio.")
                }
            }
            let candidate = CMTimeRangeGetEnd(range)
            if CMTimeCompare(candidate, end) > 0 { end = candidate }
        }
        guard CMTimeCompare(end, .zero) > 0 else { throw Self.failure("AVI has no positive exact track timeline.") }
        return end
    }

    private func canonicalFormat(
        _ asset: AVAsset, track: AVAssetTrack, description: CMFormatDescription,
        strategy: Strategy, cancellation: (any NativeMediaInputCancellationV4)?
    ) throws -> CMVideoFormatDescription {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        defer { reader.cancelReading() }
        guard reader.startReading() else { throw reader.error ?? Self.failure("Cannot read AVI codec headers.") }
        var first: CMSampleBuffer?
        while let sample = output.copyNextSampleBuffer() {
            try check(cancellation)
            if CMSampleBufferGetNumSamples(sample) > 0 { first = sample; break }
        }
        guard let first else { throw Self.failure("AVI has no compressed video packets.") }
        return try Self.canonicalFormat(description: description, firstPacket: Self.payload(first), strategy: strategy)
    }

    static func canonicalFormat(
        description: CMFormatDescription, firstPacket: Data, strategy: Strategy
    ) throws -> CMVideoFormatDescription {
        var result: CMVideoFormatDescription?
        if strategy == .aviH264 {
            let nals = try annexBNALs(firstPacket)
            guard let sps = nals.first(where: { $0.first.map { $0 & 31 } == 7 }),
                  let pps = nals.first(where: { $0.first.map { $0 & 31 } == 8 }) else {
                throw failure("AVI H.264 has no initial SPS/PPS configuration.")
            }
            let code = sps.withUnsafeBytes { s in pps.withUnsafeBytes { p in
                let pointers = [s.bindMemory(to: UInt8.self).baseAddress!, p.bindMemory(to: UInt8.self).baseAddress!]
                let sizes = [sps.count, pps.count]
                return pointers.withUnsafeBufferPointer { pointers in sizes.withUnsafeBufferPointer { sizes in
                    CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault,
                        parameterSetCount: 2, parameterSetPointers: pointers.baseAddress!,
                        parameterSetSizes: sizes.baseAddress!, nalUnitHeaderLength: 4, formatDescriptionOut: &result)
                } }
            } }
            guard code == noErr, let result else { throw failure("H.264 configuration is invalid (\(code)).") }
            return result
        }
        let bytes = [UInt8](firstPacket)
        guard bytes.count >= 8 else { throw failure("MPEG-4 configuration is truncated.") }
        var end: Int?
        for i in 0..<(bytes.count - 3) where bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 1 {
            if bytes[i + 3] == 0xb3 || bytes[i + 3] == 0xb6 { end = i; break }
        }
        guard let end, end > 0, end < maximumPacketBytes else { throw failure("MPEG-4 VOL configuration is missing.") }
        let configuration = Data(bytes.prefix(end))
        guard LegacyVideoSamplingFacts.mpeg4(configuration) != nil else {
            throw failure("MPEG-4 configuration is outside the verified native sampling contract.")
        }
        let decoder = descriptor(4, Data([0x20, 0x11, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]) + descriptor(5, configuration))
        let esds = Data([0, 0, 0, 0]) + descriptor(3, Data([0, 1, 0]) + decoder + descriptor(6, Data([2])))
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        let extensions = [kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: ["esds": esds]] as CFDictionary
        let code = CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_MPEG4Video, width: dimensions.width, height: dimensions.height,
            extensions: extensions, formatDescriptionOut: &result)
        guard code == noErr, let result else { throw failure("MPEG-4 configuration is invalid (\(code)).") }
        return result
    }

    private static func descriptor(_ tag: UInt8, _ data: Data) -> Data {
        var value = data.count
        var length = [UInt8(value & 0x7f)]
        value >>= 7
        while value > 0 { length.insert(UInt8(value & 0x7f) | 0x80, at: 0); value >>= 7 }
        return Data([tag] + length) + data
    }

    static func annexBNALs(_ data: Data) throws -> [Data] {
        guard !data.isEmpty, data.count <= maximumPacketBytes else { throw failure("H.264 packet exceeds the bounded packet size.") }
        let bytes = [UInt8](data)
        var starts: [(Int, Int)] = []
        var index = 0
        while index + 3 <= bytes.count {
            if bytes[index] == 0 && bytes[index + 1] == 0 && bytes[index + 2] == 1 {
                starts.append((index, index + 3)); index += 3
            } else if index + 4 <= bytes.count && bytes[index] == 0 && bytes[index + 1] == 0
                        && bytes[index + 2] == 0 && bytes[index + 3] == 1 {
                starts.append((index, index + 4)); index += 4
            } else { index += 1 }
        }
        guard let first = starts.first, bytes.prefix(first.0).allSatisfy({ $0 == 0 }), starts.count <= 65_536 else {
            throw failure("H.264 AVI packet is not valid bounded Annex-B framing.")
        }
        return try starts.enumerated().map { ordinal, start in
            var end = ordinal + 1 < starts.count ? starts[ordinal + 1].0 : bytes.count
            while end > start.1 && bytes[end - 1] == 0 { end -= 1 }
            guard end > start.1 else { throw failure("H.264 packet has an empty NAL unit.") }
            return Data(bytes[start.1..<end])
        }
    }

    static func lengthPrefixedH264(_ data: Data) throws -> Data {
        var result = Data()
        for nal in try annexBNALs(data) {
            var length = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
            result.append(nal)
        }
        return result
    }

    private static func payload(_ sample: CMSampleBuffer) throws -> Data {
        guard CMSampleBufferGetNumSamples(sample) == 1,
              let block = CMSampleBufferGetDataBuffer(sample) else { throw failure("AVI packet sample grouping is unsupported.") }
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0, length <= maximumPacketBytes else { throw failure("AVI packet size is outside the bounded import contract.") }
        var data = Data(count: length)
        let code = data.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
        }
        guard code == noErr else { throw failure("Cannot copy AVI packet (\(code)).") }
        return data
    }

    static func verifyStableConfiguration(
        _ packet: Data, format: CMVideoFormatDescription, strategy: Strategy
    ) throws {
        if strategy == .aviH264 {
            for nal in try annexBNALs(packet) {
                guard let first = nal.first else { continue }
                let kind = first & 31
                guard kind == 7 || kind == 8 else { continue }
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                let code = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format,
                    parameterSetIndex: kind == 7 ? 0 : 1, parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                guard code == noErr, let pointer, Data(bytes: pointer, count: size) == nal else {
                    throw failure("H.264 parameter sets change within the AVI track.")
                }
            }
        } else {
            let bytes = [UInt8](packet)
            guard bytes.count >= 4 else { throw failure("MPEG-4 packet is truncated.") }
            let hasVOL = (0..<(bytes.count - 3)).contains { index in
                bytes[index] == 0 && bytes[index + 1] == 0 && bytes[index + 2] == 1
                    && ((0x20...0x2f).contains(bytes[index + 3]) || bytes[index + 3] == 0xb0 || bytes[index + 3] == 0xb5)
            }
            if hasVOL {
                let observed = try canonicalFormat(description: format, firstPacket: packet, strategy: strategy)
                guard CFEqual(CMFormatDescriptionGetExtensions(observed), CMFormatDescriptionGetExtensions(format)) else {
                    throw failure("MPEG-4 configuration changes within the AVI track.")
                }
            }
        }
    }

    private static func rebound(
        _ source: CMSampleBuffer, format: CMVideoFormatDescription, strategy: Strategy,
        presentationClock: inout NativeAVICompressedPresentationClockV4
    ) throws -> CMSampleBuffer {
        let original = try payload(source)
        try verifyStableConfiguration(original, format: format, strategy: strategy)
        let data = strategy == .aviH264 ? try lengthPrefixedH264(original) : original
        var block: CMBlockBuffer?
        var code = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
            memoryBlock: nil, blockLength: data.count, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: data.count, flags: 0, blockBufferOut: &block)
        guard code == noErr, let block else { throw failure("Cannot allocate native packet buffer (\(code)).") }
        code = data.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count)
        }
        guard code == noErr else { throw failure("Cannot fill native packet buffer (\(code)).") }
        var timing = CMSampleTimingInfo()
        code = CMSampleBufferGetSampleTimingInfo(source, at: 0, timingInfoOut: &timing)
        guard code == noErr else { throw failure("Cannot retain AVI packet timing (\(code)).") }
        timing.presentationTimeStamp = try presentationClock.presentationTime(packet: original, timing: timing)
        var size = data.count
        var sample: CMSampleBuffer?
        code = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
            formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        guard code == noErr, let sample else { throw failure("Cannot construct native packet (\(code)).") }
        if let sourceAttachments = CMSampleBufferGetSampleAttachmentsArray(source, createIfNecessary: false) as? [[String: Any]],
           let target = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary],
           sourceAttachments.count == 1, let destination = target.first {
            for (key, value) in sourceAttachments[0] { destination[key] = value }
        }
        return sample
    }

    /// Only structural creation/modification fields are normalized. Media,
    /// decode timing, codec configuration and user metadata bytes are retained;
    /// composition timing is reconstructed separately from the video bitstream.
    private static func clearContainerDates(_ url: URL) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let length = try handle.seekToEnd()
        func walk(_ start: UInt64, _ end: UInt64, _ depth: Int) throws {
            guard depth <= 8 else { throw failure("Normalized MOV atom nesting is invalid.") }
            var cursor = start
            while cursor < end {
                guard end - cursor >= 8 else { throw failure("Normalized MOV atom header is truncated.") }
                try handle.seek(toOffset: cursor)
                guard let header = try handle.read(upToCount: 8), header.count == 8 else { throw failure("Cannot read normalized MOV atom.") }
                let bytes = [UInt8](header)
                var size = bytes.prefix(4).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                let tag = String(bytes: bytes[4..<8], encoding: .ascii) ?? ""
                var headerBytes: UInt64 = 8
                if size == 1 {
                    guard let extended = try handle.read(upToCount: 8), extended.count == 8 else { throw failure("Extended MOV atom is truncated.") }
                    size = extended.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }; headerBytes = 16
                } else if size == 0 { size = end - cursor }
                guard size >= headerBytes, size <= end - cursor else { throw failure("Normalized MOV atom size is invalid.") }
                let payload = cursor + headerBytes
                if ["moov", "trak", "mdia"].contains(tag) {
                    try walk(payload, cursor + size, depth + 1)
                } else if ["mvhd", "tkhd", "mdhd"].contains(tag) {
                    try handle.seek(toOffset: payload)
                    guard let version = try handle.read(upToCount: 1)?.first, version <= 1 else { throw failure("Normalized MOV header version is unsupported.") }
                    let count = version == 0 ? 8 : 16
                    guard size - headerBytes >= UInt64(4 + count) else { throw failure("Normalized MOV clock header is truncated.") }
                    try handle.seek(toOffset: payload + 4)
                    try handle.write(contentsOf: Data(repeating: 0, count: count))
                    if tag == "tkhd" {
                        let volumeOffset: UInt64 = version == 0 ? 36 : 48
                        guard size - headerBytes >= volumeOffset + 2 else { throw failure("Normalized MOV track volume is truncated.") }
                        // AVI reports unity volume even for video tracks;
                        // retain that observed value instead of MOV's zero default.
                        try handle.seek(toOffset: payload + volumeOffset)
                        try handle.write(contentsOf: Data([1, 0]))
                    }
                }
                cursor += size
            }
        }
        try walk(0, length, 0)
        try handle.synchronize()
    }

    private func check(_ cancellation: (any NativeMediaInputCancellationV4)?) throws {
        try cancellation?.check()
        try Task.checkCancellation()
    }

    private static func failure(_ details: String) -> NativeMediaInputAssetErrorV4 {
        .unsupported(details)
    }
}
