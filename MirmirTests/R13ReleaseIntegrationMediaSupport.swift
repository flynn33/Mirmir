import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import os.lock
@testable import Mirmir

enum R13IntegrationMediaError: Error, Equatable {
    case interrupted
    case metadataReaderRejected
    case metadataReaderFailed
    case duplicateMetadataKey(String)
    case malformedContainerHeader
}

func readR13ISOBaseMediaMajorBrand(at url: URL) throws -> String {
    let data = try Data(contentsOf: url, options: .mappedIfSafe)
    guard data.count >= 12,
          data.subdata(in: 4..<8) == Data("ftyp".utf8) else {
        throw R13IntegrationMediaError.malformedContainerHeader
    }
    guard let majorBrand = String(
        bytes: data[8..<12],
        encoding: .ascii
    ) else {
        throw R13IntegrationMediaError.malformedContainerHeader
    }
    return majorBrand
}

final class R13IntegrationMediaPipeline:
    MediaPipelineService,
    @unchecked Sendable {
    private struct State {
        var beginSessionCount = 0
        var sessions: [R13IntegrationMediaSession] = []
    }

    private let resolution: VideoResolution
    private let frames: [FrameRecord]
    private let estimatedFrameCount: Int
    private let failureThresholds: [Int?]
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(
        resolution: VideoResolution,
        frames: [FrameRecord],
        estimatedFrameCount: Int,
        failureThresholds: [Int?] = []
    ) {
        self.resolution = resolution
        self.frames = frames
        self.estimatedFrameCount = estimatedFrameCount
        self.failureThresholds = failureThresholds
    }

    var beginSessionCount: Int {
        state.withLock { $0.beginSessionCount }
    }

    var sessions: [R13IntegrationMediaSession] {
        state.withLock { $0.sessions }
    }

    func probe(url: URL) async throws -> SourceProfile {
        SourceProfile(
            url: url,
            resolution: resolution,
            frameRate: 30,
            durationSeconds: Double(frames.count) / 30,
            estimatedFrameCount: estimatedFrameCount,
            codecHint: "r13-integration",
            hasAudio: false
        )
    }

    func beginSession(
        source: SourceProfile,
        output: OutputProfile
    ) async throws -> MediaSession {
        let attemptIndex = state.withLock { $0.beginSessionCount }
        let threshold = failureThresholds.indices.contains(attemptIndex)
            ? failureThresholds[attemptIndex]
            : nil
        let session = try R13IntegrationMediaSession(
            sourceProfile: source,
            outputProfile: output,
            frames: frames,
            failureAfterFrameCount: threshold
        )
        state.withLock { current in
            current.beginSessionCount += 1
            current.sessions.append(session)
        }
        return session
    }

    func start() {}
    func stop() {}
}

final class R13IntegrationMediaSession:
    MediaSession,
    @unchecked Sendable {
    private struct State {
        var nextFrameIndex = 0
        var appendedFrameIndices: [Int] = []
        var finalMetadata: [String: String] = [:]
        var finishCount = 0
        var cancelCount = 0
        var cancelled = false
        var published = false
        var publishedOutputIdentity: MediaOutputPublicationIdentity?
    }

    let sourceProfile: SourceProfile
    let outputProfile: OutputProfile
    let outputPixelBufferPool: CVPixelBufferPool
    let prepublicationOutputURL: URL
    var terminalCleanupError: MediaPipelineError? { nil }

    private let frames: [FrameRecord]
    private let failureAfterFrameCount: Int?
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(
        sourceProfile: SourceProfile,
        outputProfile: OutputProfile,
        frames: [FrameRecord],
        failureAfterFrameCount: Int?
    ) throws {
        self.sourceProfile = sourceProfile
        self.outputProfile = outputProfile
        self.frames = frames
        self.failureAfterFrameCount = failureAfterFrameCount
        outputPixelBufferPool = try PixelBufferBridge.makePool(
            width: outputProfile.resolution.width,
            height: outputProfile.resolution.height,
            format: R03NV12Contract.pixelFormat,
            capacity: 2
        )
        prepublicationOutputURL = outputProfile.url
            .deletingLastPathComponent()
            .appendingPathComponent(
                ".\(outputProfile.url.lastPathComponent)."
                    + "\(outputProfile.transactionIdentifier).partial"
            )
    }

    var appendedFrameIndices: [Int] {
        state.withLock { $0.appendedFrameIndices }
    }

    var finalMetadata: [String: String] {
        state.withLock { $0.finalMetadata }
    }

    var finishCount: Int {
        state.withLock { $0.finishCount }
    }

    var cancelCount: Int {
        state.withLock { $0.cancelCount }
    }

    var publishedOutputIdentity: MediaOutputPublicationIdentity? {
        state.withLock { $0.publishedOutputIdentity }
    }

    func nextSourceFrame() async throws -> FrameRecord? {
        try state.withLock { current -> FrameRecord? in
            if current.cancelled {
                throw CancellationError()
            }
            if let failureAfterFrameCount,
               current.nextFrameIndex == failureAfterFrameCount {
                throw R13IntegrationMediaError.interrupted
            }
            guard current.nextFrameIndex < frames.count else { return nil }
            defer { current.nextFrameIndex += 1 }
            return frames[current.nextFrameIndex]
        }
    }

    func appendOutput(
        pixelBuffer _: CVPixelBuffer,
        timing: FrameTiming
    ) async throws {
        try state.withLock { current in
            guard !current.cancelled else { throw CancellationError() }
            current.appendedFrameIndices.append(timing.frameIndex)
        }
    }

    func finish() async throws {
        try await finish(
            finalMetadata: outputProfile.timedMetadataTemplate
        )
    }

    func finish(finalMetadata: [String: String]) async throws {
        try await finish(
            finalMetadata: finalMetadata,
            beforeReopen: {},
            validatingBeforePublish: {}
        )
    }

    func finish(
        finalMetadata: [String: String],
        validatingBeforePublish: @escaping @Sendable () async throws -> Void
    ) async throws {
        try await finish(
            finalMetadata: finalMetadata,
            beforeReopen: {},
            validatingBeforePublish: validatingBeforePublish
        )
    }

    func finish(
        finalMetadata: [String: String],
        beforeReopen: @escaping @Sendable () async throws -> Void,
        validatingBeforePublish: @escaping @Sendable () async throws -> Void
    ) async throws {
        do {
            try checkCancellation()
            try Data("r13-integration-output\n".utf8).write(
                to: prepublicationOutputURL,
                options: .atomic
            )
            try await beforeReopen()
            try checkCancellation()
            try await validatingBeforePublish()
            try checkCancellation()
            try FileManager.default.moveItem(
                at: prepublicationOutputURL,
                to: outputProfile.url
            )
            let measuredOutput = try R13LocalRestartSourceMeasurer()
                .measureSource(at: outputProfile.url)
            state.withLock { current in
                current.finalMetadata = finalMetadata
                current.finishCount += 1
                current.published = true
                current.publishedOutputIdentity =
                    MediaOutputPublicationIdentity(
                        sha256: measuredOutput.sha256,
                        byteCount: measuredOutput.byteCount
                    )
            }
        } catch {
            try? FileManager.default.removeItem(
                at: prepublicationOutputURL
            )
            throw error
        }
    }

    func cancel() {
        let removePartial = state.withLock { current -> Bool in
            current.cancelCount += 1
            current.cancelled = true
            return !current.published
        }
        if removePartial {
            try? FileManager.default.removeItem(at: prepublicationOutputURL)
        }
    }

    private func checkCancellation() throws {
        try Task.checkCancellation()
        if state.withLock({ $0.cancelled }) {
            throw CancellationError()
        }
    }
}

func readR13ReleaseMetadata(at url: URL) async throws -> [String: String] {
    let asset = AVURLAsset(url: url)
    var observed: [String: String] = [:]
    for track in try await asset.loadTracks(withMediaType: .metadata) {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: nil
        )
        guard reader.canAdd(output) else {
            throw R13IntegrationMediaError.metadataReaderRejected
        }
        reader.add(output)
        let adaptor = AVAssetReaderOutputMetadataAdaptor(
            assetReaderTrackOutput: output
        )
        guard reader.startReading() else {
            throw R13IntegrationMediaError.metadataReaderFailed
        }
        while let group = adaptor.nextTimedMetadataGroup() {
            for item in group.items {
                let identifier = item.identifier?.rawValue
                let storedKey = item.key as? String
                    ?? (item.key as? NSString).map(String.init)
                guard let key = [identifier, storedKey]
                    .compactMap({ $0 })
                    .first(where: {
                        $0.hasPrefix(
                            R13ReleaseIdentity.metadataNamespace
                        )
                    }),
                      let value = try await item.load(.stringValue) else {
                    continue
                }
                guard observed.updateValue(value, forKey: key) == nil else {
                    throw R13IntegrationMediaError
                        .duplicateMetadataKey(key)
                }
            }
        }
        guard reader.status == .completed else {
            throw R13IntegrationMediaError.metadataReaderFailed
        }
    }
    return observed
}
