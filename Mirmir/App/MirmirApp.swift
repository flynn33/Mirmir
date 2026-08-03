import AVFoundation
import AppKit
import CoreMedia
import CoreVideo
import CryptoKit
import Darwin
import Foundation
import SwiftUI

@main
@MainActor
struct MirmirApp: App {
    @NSApplicationDelegateAdaptor(MirmirApplicationDelegate.self)
    private var applicationDelegate
    @State private var viewModel: MirmirViewModel?

    init() {
        // Qualification is an isolated process mode. In particular, it must
        // not instantiate the normal UI composition, whose production queue
        // belongs to the user rather than the release observer.
        _viewModel = State(initialValue:
            MirmirNotarizedSmokeInvocationV4.wasRequested
                ? nil
                : MirmirViewModel()
        )
    }

    var body: some Scene {
        WindowGroup("Mirmir", id: "main") {
            if let viewModel {
                RootView(viewModel: viewModel)
                    .frame(minWidth: 960, minHeight: 680)
            } else {
                EmptyView()
            }
        }
        .defaultSize(width: 1_180, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Video…") {
                    viewModel?.openVideo()
                }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(viewModel?.isProcessing ?? true)
            }
        }
    }
}

// MARK: - Notarized release qualification observer

/// The release observer is reachable only through one exact command-line
/// envelope. Normal launches never instantiate it. Keeping this entry point in
/// the shipping target lets the release harness prove behavior of the exact
/// archived executable instead of a test bundle or helper process.
enum MirmirNotarizedSmokeInvocationV4 {
    static let flag = "--mirmir-v4-notarized-smoke"

    static var wasRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(flag)
    }

    fileprivate static func parse() throws -> MirmirNotarizedSmokeRequestV4 {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.count == 3,
              arguments[1] == flag,
              let bytes = Data(base64Encoded: arguments[2]),
              !bytes.isEmpty else {
            throw MirmirNotarizedSmokeErrorV4.invalidInvocation
        }
        let request: MirmirNotarizedSmokeRequestV4
        do {
            request = try JSONDecoder().decode(
                MirmirNotarizedSmokeRequestV4.self,
                from: bytes
            )
        } catch {
            throw MirmirNotarizedSmokeErrorV4.invalidRequest(
                "the command envelope is not canonical request JSON"
            )
        }
        let canonical = try MirmirNotarizedSmokeFilesV4.canonicalData(request)
        guard canonical == bytes else {
            throw MirmirNotarizedSmokeErrorV4.invalidRequest(
                "the command envelope contains unknown, duplicate, or noncanonical fields"
            )
        }
        try request.validate()
        return request
    }
}

@MainActor
final class MirmirApplicationDelegate: NSObject, NSApplicationDelegate {
    private var qualificationTask: Task<Void, Never>?

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard MirmirNotarizedSmokeInvocationV4.wasRequested else { return }
        NSApplication.shared.setActivationPolicy(.prohibited)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard MirmirNotarizedSmokeInvocationV4.wasRequested else { return }
        qualificationTask = Task.detached(priority: .userInitiated) {
            do {
                let request = try MirmirNotarizedSmokeInvocationV4.parse()
                let result = try await MirmirNotarizedSmokeObserverV4.run(
                    request
                )
                MirmirNotarizedSmokeObserverV4.emit(
                    prefix: "MIRMIR_V4_NOTARIZED_SMOKE_RESULT ",
                    data: result
                )
                Darwin.exit(EXIT_SUCCESS)
            } catch {
                let result = MirmirNotarizedSmokeObserverV4.errorEnvelope(error)
                MirmirNotarizedSmokeObserverV4.emit(
                    prefix: "MIRMIR_V4_NOTARIZED_SMOKE_ERROR ",
                    data: result
                )
                Darwin.exit(70)
            }
        }
    }
}

private enum MirmirNotarizedSmokePhaseV4: String, Codable, Sendable {
    case prepare
    case recover
}

private struct MirmirNotarizedSmokeRequestV4: Codable, Sendable {
    static let schema = "mirmir-ash-v4-notarized-smoke-request-v1"

    let schemaVersion: String
    let phase: MirmirNotarizedSmokePhaseV4
    let requestID: String
    let nonce: String
    let generatedAtUTC: String
    let laneContractSHA256: String
    let releaseContractSHA256: String
    let applicationArchiveSHA256: String
    let sourceCommit: String
    let bundleIdentifier: String
    let productVersion: String
    let productBuild: String
    let runtimeManifestSHA256: String
    let runtimeManifestFileSHA256: String
    let expectedExecutableSHA256: String
    let phaseOneResultSHA256: String?

    func validate() throws {
        guard schemaVersion == Self.schema else {
            throw MirmirNotarizedSmokeErrorV4.invalidRequest(
                "unsupported request schema"
            )
        }
        guard let uuid = UUID(uuidString: requestID),
              uuid.uuidString.lowercased() == requestID else {
            throw MirmirNotarizedSmokeErrorV4.invalidRequest(
                "requestID must be a canonical lowercase UUID"
            )
        }
        for (label, value, lengths) in [
            ("nonce", nonce, [64]),
            ("laneContractSHA256", laneContractSHA256, [64]),
            ("releaseContractSHA256", releaseContractSHA256, [64]),
            ("applicationArchiveSHA256", applicationArchiveSHA256, [64]),
            ("sourceCommit", sourceCommit, [40]),
            ("runtimeManifestSHA256", runtimeManifestSHA256, [64]),
            ("runtimeManifestFileSHA256", runtimeManifestFileSHA256, [64]),
            ("expectedExecutableSHA256", expectedExecutableSHA256, [64])
        ] {
            guard lengths.contains(value.utf8.count),
                  MirmirNotarizedSmokeFilesV4.isLowercaseHex(value) else {
                throw MirmirNotarizedSmokeErrorV4.invalidRequest(
                    "\(label) is not a lowercase hexadecimal identity"
                )
            }
        }
        guard !bundleIdentifier.isEmpty,
              !productVersion.isEmpty,
              !productBuild.isEmpty,
              bundleIdentifier.utf8.count <= 255,
              productVersion.utf8.count <= 255,
              productBuild.utf8.count <= 255 else {
            throw MirmirNotarizedSmokeErrorV4.invalidRequest(
                "bundle identity is missing or oversized"
            )
        }
        switch phase {
        case .prepare:
            guard phaseOneResultSHA256 == nil else {
                throw MirmirNotarizedSmokeErrorV4.invalidRequest(
                    "prepare cannot bind a phase-one result"
                )
            }
        case .recover:
            guard let phaseOneResultSHA256,
                  phaseOneResultSHA256.utf8.count == 64,
                  MirmirNotarizedSmokeFilesV4.isLowercaseHex(
                    phaseOneResultSHA256
                  ) else {
                throw MirmirNotarizedSmokeErrorV4.invalidRequest(
                    "recover requires the exact phase-one result identity"
                )
            }
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let generated = formatter.date(from: generatedAtUTC) else {
            throw MirmirNotarizedSmokeErrorV4.invalidRequest(
                "generatedAtUTC is not canonical UTC"
            )
        }
        let age = Date().timeIntervalSince(generated)
        guard age >= -30, age <= 300 else {
            throw MirmirNotarizedSmokeErrorV4.staleRequest
        }
    }
}

private enum MirmirNotarizedSmokeErrorV4: Error, LocalizedError {
    case invalidInvocation
    case invalidRequest(String)
    case staleRequest
    case identityMismatch(String)
    case unsafeQualificationRoot(String)
    case invariant(String)

    var errorDescription: String? {
        switch self {
        case .invalidInvocation:
            "The notarized qualification invocation is malformed."
        case .invalidRequest(let reason):
            "The notarized qualification request is invalid: \(reason)"
        case .staleRequest:
            "The notarized qualification request is stale or future-dated."
        case .identityMismatch(let reason):
            "The notarized candidate identity does not match: \(reason)"
        case .unsafeQualificationRoot(let path):
            "The qualification sandbox root is unsafe: \(path)"
        case .invariant(let reason):
            "The notarized qualification invariant failed: \(reason)"
        }
    }
}

private struct MirmirSmokeArtifactV4: Codable, Equatable, Sendable {
    let path: String
    let byteCount: Int
    let sha256: String
}

private struct MirmirSmokeProcessIdentityV4: Codable, Equatable, Sendable {
    let bundleIdentifier: String
    let productVersion: String
    let productBuild: String
    let bundlePath: String
    let executablePath: String
    let executableSHA256: String
    let processID: Int32
    let parentProcessID: Int32
    let sandboxDataPath: String
    let applicationSupportPath: String
    let qualificationRootPath: String
}

private struct MirmirSmokeRuntimeIdentityV4: Codable, Equatable, Sendable {
    let runtimeID: String
    let releaseStatus: String
    let manifestSHA256: String
    let manifestFileSHA256: String
    let sourceRevision: String
    let builderSourceSHA256: String
    let artifactCount: Int
    let runtimeBundlePath: String
    let trustRootConfigured: Bool
}

private struct MirmirSmokeProbeIdentityV4: Codable, Equatable, Sendable {
    let encodedWidth: Int
    let encodedHeight: Int
    let codecFourCC: String
    let durationValue: Int64
    let durationTimescale: Int32
    let estimatedFrameCount: Int
    let videoTrackCount: Int
    let audioTrackCount: Int
    let bitDepth: Int
    let bitDepthEvidence: String
    let isFullRange: Bool
    let rangeEvidence: String
    let dynamicRange: String
    let fieldCount: Int
    let fieldCountEvidence: String
    let readable: Bool
    let playable: Bool
}

private struct MirmirSmokeSemanticIdentityV4: Codable, Equatable, Sendable {
    let encodedWidth: Int
    let encodedHeight: Int
    let frameCount: Int
    let enabledVideoTrackCount: Int
    let durationValue: Int64
    let durationTimescale: Int32
    let timingSHA256: String
    let visiblePixelSHA256: String
}

private struct MirmirSmokeProcessingIdentityV4: Codable, Equatable, Sendable {
    let actualBackendID: String
    let processedFrameCount: Int
    let encodedWidth: Int
    let encodedHeight: Int
    let outputCodec: String
    let processingDurationSeconds: Double
}

private struct MirmirSmokePhaseOneStateV4: Codable, Equatable, Sendable {
    static let schema = "mirmir-ash-v4-notarized-smoke-phase-one-state-v1"

    let schemaVersion: String
    let requestID: String
    let nonceSHA256: String
    let requestSHA256: String
    let applicationArchiveSHA256: String
    let sourceCommit: String
    let executableSHA256: String
    let runtimeManifestSHA256: String
    let runtimeManifestFileSHA256: String
    let jobID: String
    let inputArtifact: MirmirSmokeArtifactV4
    let inputSemantic: MirmirSmokeSemanticIdentityV4
    let directOutputArtifact: MirmirSmokeArtifactV4
    let directOutputSemantic: MirmirSmokeSemanticIdentityV4
    let queueTreeSHA256: String
}

private enum MirmirNotarizedSmokeFilesV4 {
    static let namespace = "MirmirQualificationV4/notarized-smoke"
    static let maximumTreeBytes = 512 * 1_024 * 1_024

    static func canonicalData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func canonicalData(_ value: Any) throws -> Data {
        guard JSONSerialization.isValidJSONObject(value) else {
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "attempted to publish invalid JSON"
            )
        }
        return try JSONSerialization.data(
            withJSONObject: value,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    static func object<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(
            with: canonicalData(value),
            options: [.fragmentsAllowed]
        )
    }

    static func isLowercaseHex(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy {
            (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
        }
    }

    static func hex<D: Sequence>(_ digest: D) -> String
    where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(_ data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while true {
            let bytes = try handle.read(upToCount: 1_048_576) ?? Data()
            guard !bytes.isEmpty else { break }
            digest.update(data: bytes)
        }
        return hex(digest.finalize())
    }

    static func writeNew(_ data: Data, to url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "refusing to overwrite \(url.lastPathComponent)"
            )
        }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString.lowercased()).partial"
        )
        var descriptor = Darwin.open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "cannot create atomic evidence temporary: \(posixError())"
            )
        }
        var removeTemporary = true
        defer {
            if descriptor >= 0 { _ = Darwin.close(descriptor) }
            if removeTemporary { _ = Darwin.unlink(temporary.path) }
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                guard let address = bytes.baseAddress else {
                    throw MirmirNotarizedSmokeErrorV4.invariant(
                        "atomic evidence bytes have no base address"
                    )
                }
                let written = Darwin.write(
                    descriptor,
                    address.advanced(by: offset),
                    bytes.count - offset
                )
                if written < 0, errno == EINTR { continue }
                guard written > 0 else {
                    throw MirmirNotarizedSmokeErrorV4.invariant(
                        "cannot write atomic evidence: \(posixError())"
                    )
                }
                offset += written
            }
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "cannot synchronize atomic evidence: \(posixError())"
            )
        }
        guard Darwin.close(descriptor) == 0 else {
            descriptor = -1
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "cannot close atomic evidence: \(posixError())"
            )
        }
        descriptor = -1
        // link(2) publishes the fully synchronized bytes atomically and fails
        // rather than replacing a concurrently created destination.
        guard Darwin.link(temporary.path, url.path) == 0 else {
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "cannot publish atomic evidence: \(posixError())"
            )
        }
        guard Darwin.unlink(temporary.path) == 0 else {
            _ = Darwin.unlink(url.path)
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "cannot retire atomic evidence temporary: \(posixError())"
            )
        }
        removeTemporary = false
        let directory = url.deletingLastPathComponent()
        let directoryDescriptor = Darwin.open(directory.path, O_RDONLY)
        guard directoryDescriptor >= 0 else {
            _ = Darwin.unlink(url.path)
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "cannot open evidence directory for synchronization: "
                    + posixError()
            )
        }
        defer { _ = Darwin.close(directoryDescriptor) }
        guard Darwin.fsync(directoryDescriptor) == 0 else {
            _ = Darwin.unlink(url.path)
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "cannot synchronize evidence directory: \(posixError())"
            )
        }
    }

    static func posixError() -> String {
        String(cString: strerror(errno))
    }

    static func writeNew<T: Encodable>(_ value: T, to url: URL) throws {
        try writeNew(canonicalData(value), to: url)
    }

    static func decodeCanonical<T: Codable>(
        _ type: T.Type,
        from url: URL
    ) throws -> T {
        let data = try Data(contentsOf: url)
        let value = try JSONDecoder().decode(type, from: data)
        guard try canonicalData(value) == data else {
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "\(url.lastPathComponent) is noncanonical"
            )
        }
        return value
    }

    static func artifact(root: URL, url: URL) throws -> MirmirSmokeArtifactV4 {
        let root = root.standardizedFileURL
        let file = url.standardizedFileURL
        guard file.path.hasPrefix(root.path + "/") else {
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "artifact escapes qualification root"
            )
        }
        var metadata = stat()
        guard lstat(file.path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_nlink == 1,
              metadata.st_size >= 0,
              metadata.st_size <= maximumTreeBytes else {
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "artifact is not a bounded regular file"
            )
        }
        let relative = String(file.path.dropFirst(root.path.count + 1))
        return MirmirSmokeArtifactV4(
            path: relative,
            byteCount: Int(metadata.st_size),
            sha256: try sha256(file)
        )
    }

    static func treeSHA256(_ root: URL) throws -> String {
        let root = root.standardizedFileURL
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "tree root is missing"
            )
        }
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "cannot enumerate qualification tree"
            )
        }
        let urls = (enumerator.allObjects as? [URL] ?? []).sorted {
            $0.path < $1.path
        }
        if let enumerationError {
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "qualification tree enumeration failed: "
                    + enumerationError.localizedDescription
            )
        }
        var totalBytes = 0
        var digest = SHA256()
        digest.update(data: Data("mirmir-notarized-smoke-tree-v1\0".utf8))
        for url in urls {
            let relative = String(url.path.dropFirst(root.path.count + 1))
            var metadata = stat()
            guard lstat(url.path, &metadata) == 0 else {
                throw MirmirNotarizedSmokeErrorV4.invariant(
                    "tree entry vanished during sealing"
                )
            }
            digest.update(data: Data(relative.utf8))
            digest.update(data: Data([0]))
            switch metadata.st_mode & S_IFMT {
            case S_IFDIR:
                digest.update(data: Data("directory\n".utf8))
            case S_IFREG:
                guard metadata.st_nlink == 1, metadata.st_size >= 0 else {
                    throw MirmirNotarizedSmokeErrorV4.invariant(
                        "tree contains an unsafe regular file"
                    )
                }
                totalBytes += Int(metadata.st_size)
                guard totalBytes <= maximumTreeBytes else {
                    throw MirmirNotarizedSmokeErrorV4.invariant(
                        "qualification tree exceeds its byte bound"
                    )
                }
                digest.update(data: Data("file\0".utf8))
                digest.update(data: Data(try sha256(url).utf8))
                digest.update(data: Data("\n".utf8))
            default:
                throw MirmirNotarizedSmokeErrorV4.invariant(
                    "qualification tree contains a link or special file"
                )
            }
        }
        return hex(digest.finalize())
    }
}

private enum MirmirNotarizedSmokeObserverV4 {
    static let resultSchema =
        "mirmir-ash-v4-notarized-smoke-observer-result-v1"

    struct QualificationContext: Sendable {
        let root: URL
        let applicationSupport: URL
        let sandboxData: URL
    }

    static func run(_ request: MirmirNotarizedSmokeRequestV4) async throws
        -> Data {
        switch request.phase {
        case .prepare:
            try await prepare(request)
        case .recover:
            try await recover(request)
        }
    }

    static func emit(prefix: String, data: Data) {
        let line = prefix + data.base64EncodedString() + "\n"
        FileHandle.standardOutput.write(Data(line.utf8))
        try? FileHandle.standardOutput.synchronize()
    }

    static func errorEnvelope(_ error: Error) -> Data {
        let description: String
        if let localized = error as? LocalizedError,
           let value = localized.errorDescription {
            description = value
        } else {
            description = String(describing: error)
        }
        let envelope: [String: Any] = [
            "schemaVersion":
                "mirmir-ash-v4-notarized-smoke-observer-error-v1",
            "errorType": String(reflecting: type(of: error)),
            "message": description,
            "observedAtUTC": utcNow()
        ]
        return (try? MirmirNotarizedSmokeFilesV4.canonicalData(envelope))
            ?? Data("{\"schemaVersion\":\"mirmir-ash-v4-notarized-smoke-observer-error-v1\"}".utf8)
    }

    private static func prepare(
        _ request: MirmirNotarizedSmokeRequestV4
    ) async throws -> Data {
        let context = try qualificationContext(request: request, create: true)
        let requestData = try MirmirNotarizedSmokeFilesV4.canonicalData(request)
        try MirmirNotarizedSmokeFilesV4.writeNew(
            requestData,
            to: context.root.appendingPathComponent("prepare-request.json")
        )
        let process = try processIdentity(request: request, context: context)
        let runtime = try runtimeIdentity(request: request)

        let mediaDirectory = context.root.appendingPathComponent(
            "media",
            isDirectory: true
        )
        try makeSecureDirectory(mediaDirectory)
        let inputURL = mediaDirectory.appendingPathComponent("source.mov")
        try await makeSourceMovie(at: inputURL)
        let source = try await VideoProbe().probe(url: inputURL)
        let inputProbe = try probeIdentity(source)
        let inputSemantic = try await semanticIdentity(at: inputURL)
        try validateLockedInput(probe: inputProbe, semantic: inputSemantic)

        let directURL = mediaDirectory.appendingPathComponent(
            "uninterrupted.mov"
        )
        let directRequest = processingRequest(
            input: inputURL,
            output: directURL
        )
        let referenceQueueRoot = context.root.appendingPathComponent(
            "reference-workflow-queue-v4",
            isDirectory: true
        )
        let referenceCoordinator = try workflowCoordinator(
            queueRoot: referenceQueueRoot,
            worker: "reference-\(request.requestID.prefix(12))"
        )
        let referenceLaunch = try await referenceCoordinator.launch()
        guard referenceLaunch.queue.items.isEmpty,
              referenceLaunch.recovery.items.isEmpty else {
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "the unique uninterrupted reference queue was not empty"
            )
        }
        let referenceOutcome = try await referenceCoordinator.submit(
            request: directRequest,
            progress: { _ in },
            snapshot: { _ in }
        )
        let directResult: UpscaleResult
        switch referenceOutcome {
        case .completed(let completion):
            directResult = completion.result
        case .paused:
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "the uninterrupted reference queue unexpectedly paused"
            )
        }
        let referenceSnapshot = try await referenceCoordinator.queueSnapshot()
        guard referenceSnapshot.items.count == 1,
              referenceSnapshot.items[0].lifecycle == .completed else {
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "the uninterrupted reference queue did not complete"
            )
        }
        let directProcessing = try processingIdentity(directResult)
        let directSemantic = try await semanticIdentity(at: directURL)
        guard directProcessing.actualBackendID
                == UpscaleBackendID.mirmirDeterministicCPU.rawValue,
              directProcessing.encodedWidth == 96,
              directProcessing.encodedHeight == 72,
              directSemantic.frameCount > 0 else {
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "the uninterrupted deterministic CPU route did not produce the locked raster"
            )
        }

        let queueRoot = context.root.appendingPathComponent(
            "workflow-queue-v4",
            isDirectory: true
        )
        let coordinator = try workflowCoordinator(
            queueRoot: queueRoot,
            worker: "prepare-\(request.requestID.prefix(12))"
        )
        let initialLaunch = try await coordinator.launch()
        guard initialLaunch.queue.items.isEmpty,
              initialLaunch.recovery.items.isEmpty else {
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "the unique qualification queue was not empty"
            )
        }
        let queueOutputURL = mediaDirectory.appendingPathComponent(
            "recovered.mov"
        )
        let queuedRequest = processingRequest(
            input: inputURL,
            output: queueOutputURL
        )
        let submitTask = Task {
            try await coordinator.submit(
                request: queuedRequest,
                progress: { _ in },
                snapshot: { _ in }
            )
        }
        var pauseRequestAccepted = false
        for _ in 0..<12_000 {
            do {
                try await coordinator.requestPause()
                pauseRequestAccepted = true
                break
            } catch WorkflowApplicationControllerErrorV4.noActiveJob {
                // Submission performs a production probe and plan before its
                // coordinator publishes the active execution. Poll that
                // actor-owned boundary rather than racing a queued snapshot.
                try await Task.sleep(nanoseconds: 1_000_000)
            } catch {
                submitTask.cancel()
                _ = await submitTask.result
                throw error
            }
        }
        guard pauseRequestAccepted else {
            submitTask.cancel()
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "the production queue did not accept pause before timeout"
            )
        }
        let outcome = try await submitTask.value
        let pausedJobID: WorkflowJobID
        switch outcome {
        case .paused(let jobID, _):
            pausedJobID = jobID
        case .completed:
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "the job completed without publishing a resumable boundary"
            )
        }
        let pausedSnapshot = try await coordinator.queueSnapshot()
        guard pausedSnapshot.items.count == 1,
              pausedSnapshot.items[0].jobID == pausedJobID,
              pausedSnapshot.items[0].lifecycle == .paused,
              !FileManager.default.fileExists(atPath: queueOutputURL.path)
        else {
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "the queue did not retain one paused unpublished job"
            )
        }
        let checkpointRelatedFiles = try regularFileCount(
            root: queueRoot,
            pathContains: "checkpoint"
        )
        guard checkpointRelatedFiles > 0 else {
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "the paused job has no durable checkpoint artifacts"
            )
        }
        let queueTreeSHA256 = try MirmirNotarizedSmokeFilesV4.treeSHA256(
            queueRoot
        )
        let inputArtifact = try MirmirNotarizedSmokeFilesV4.artifact(
            root: context.root,
            url: inputURL
        )
        let directArtifact = try MirmirNotarizedSmokeFilesV4.artifact(
            root: context.root,
            url: directURL
        )
        let state = MirmirSmokePhaseOneStateV4(
            schemaVersion: MirmirSmokePhaseOneStateV4.schema,
            requestID: request.requestID,
            nonceSHA256: MirmirNotarizedSmokeFilesV4.sha256(
                Data(request.nonce.utf8)
            ),
            requestSHA256: MirmirNotarizedSmokeFilesV4.sha256(requestData),
            applicationArchiveSHA256: request.applicationArchiveSHA256,
            sourceCommit: request.sourceCommit,
            executableSHA256: process.executableSHA256,
            runtimeManifestSHA256: runtime.manifestSHA256,
            runtimeManifestFileSHA256: runtime.manifestFileSHA256,
            jobID: pausedJobID.rawValue,
            inputArtifact: inputArtifact,
            inputSemantic: inputSemantic,
            directOutputArtifact: directArtifact,
            directOutputSemantic: directSemantic,
            queueTreeSHA256: queueTreeSHA256
        )
        let stateURL = context.root.appendingPathComponent(
            "phase-one-state.json"
        )
        try MirmirNotarizedSmokeFilesV4.writeNew(state, to: stateURL)
        let stateArtifact = try MirmirNotarizedSmokeFilesV4.artifact(
            root: context.root,
            url: stateURL
        )
        let result: [String: Any] = [
            "schemaVersion": resultSchema,
            "phase": request.phase.rawValue,
            "requestID": request.requestID,
            "requestSHA256": MirmirNotarizedSmokeFilesV4.sha256(requestData),
            "applicationArchiveSHA256": request.applicationArchiveSHA256,
            "sourceCommit": request.sourceCommit,
            "observedAtUTC": utcNow(),
            "resultFileName": "prepare-result.json",
            "process": try MirmirNotarizedSmokeFilesV4.object(process),
            "runtime": try MirmirNotarizedSmokeFilesV4.object(runtime),
            "mediaProbe": try MirmirNotarizedSmokeFilesV4.object(inputProbe),
            "inputSemantic": try MirmirNotarizedSmokeFilesV4.object(
                inputSemantic
            ),
            "deterministicProcess": try MirmirNotarizedSmokeFilesV4.object(
                directProcessing
            ),
            "directOutputSemantic": try MirmirNotarizedSmokeFilesV4.object(
                directSemantic
            ),
            "queue": [
                "jobID": pausedJobID.rawValue,
                "lifecycle": WorkflowJobLifecycle.paused.rawValue,
                "checkpointRelatedFileCount": checkpointRelatedFiles,
                "queueTreeSHA256": queueTreeSHA256
            ],
            "artifacts": [
                "input": try MirmirNotarizedSmokeFilesV4.object(inputArtifact),
                "directOutput": try MirmirNotarizedSmokeFilesV4.object(
                    directArtifact
                ),
                "phaseOneState": try MirmirNotarizedSmokeFilesV4.object(
                    stateArtifact
                )
            ],
            "checks": [
                "shippingExecutableIdentity": true,
                "sandboxIsolation": true,
                "productionP06Load": true,
                "realMediaProbe": true,
                "deterministicCPUProcess": true,
                "durableCheckpointPause": true,
                "userQueueUntouched": true
            ]
        ]
        let resultData = try MirmirNotarizedSmokeFilesV4.canonicalData(result)
        try MirmirNotarizedSmokeFilesV4.writeNew(
            resultData,
            to: context.root.appendingPathComponent("prepare-result.json")
        )
        return resultData
    }

    private static func recover(
        _ request: MirmirNotarizedSmokeRequestV4
    ) async throws -> Data {
        let context = try qualificationContext(request: request, create: false)
        let requestData = try MirmirNotarizedSmokeFilesV4.canonicalData(request)
        try MirmirNotarizedSmokeFilesV4.writeNew(
            requestData,
            to: context.root.appendingPathComponent("recover-request.json")
        )
        let process = try processIdentity(request: request, context: context)
        let runtime = try runtimeIdentity(request: request)
        let stateURL = context.root.appendingPathComponent(
            "phase-one-state.json"
        )
        let state = try MirmirNotarizedSmokeFilesV4.decodeCanonical(
            MirmirSmokePhaseOneStateV4.self,
            from: stateURL
        )
        guard state.schemaVersion == MirmirSmokePhaseOneStateV4.schema,
              state.requestID == request.requestID,
              state.nonceSHA256 == MirmirNotarizedSmokeFilesV4.sha256(
                Data(request.nonce.utf8)
              ),
              state.applicationArchiveSHA256
                == request.applicationArchiveSHA256,
              state.sourceCommit == request.sourceCommit,
              state.executableSHA256 == process.executableSHA256,
              state.runtimeManifestSHA256 == runtime.manifestSHA256,
              state.runtimeManifestFileSHA256 == runtime.manifestFileSHA256
        else {
            throw MirmirNotarizedSmokeErrorV4.identityMismatch(
                "phase-one state belongs to another request, app, or runtime"
            )
        }
        let phaseOneResultURL = context.root.appendingPathComponent(
            "prepare-result.json"
        )
        guard let requiredPhaseOneHash = request.phaseOneResultSHA256,
              try MirmirNotarizedSmokeFilesV4.sha256(phaseOneResultURL)
                == requiredPhaseOneHash else {
            throw MirmirNotarizedSmokeErrorV4.identityMismatch(
                "phase-one result seal"
            )
        }
        let mediaDirectory = context.root.appendingPathComponent(
            "media",
            isDirectory: true
        )
        let inputURL = mediaDirectory.appendingPathComponent("source.mov")
        let directURL = mediaDirectory.appendingPathComponent(
            "uninterrupted.mov"
        )
        let queueOutputURL = mediaDirectory.appendingPathComponent(
            "recovered.mov"
        )
        guard try MirmirNotarizedSmokeFilesV4.artifact(
            root: context.root,
            url: inputURL
        ) == state.inputArtifact,
              try MirmirNotarizedSmokeFilesV4.artifact(
                root: context.root,
                url: directURL
              ) == state.directOutputArtifact,
              try await semanticIdentity(at: inputURL) == state.inputSemantic,
              try await semanticIdentity(at: directURL)
                == state.directOutputSemantic else {
            throw MirmirNotarizedSmokeErrorV4.identityMismatch(
                "phase-one media artifacts changed before relaunch"
            )
        }
        let queueRoot = context.root.appendingPathComponent(
            "workflow-queue-v4",
            isDirectory: true
        )
        guard try MirmirNotarizedSmokeFilesV4.treeSHA256(queueRoot)
                == state.queueTreeSHA256 else {
            throw MirmirNotarizedSmokeErrorV4.identityMismatch(
                "durable queue changed between app processes"
            )
        }
        let coordinator = try workflowCoordinator(
            queueRoot: queueRoot,
            worker: "recover-\(request.requestID.prefix(12))"
        )
        let launch = try await coordinator.launch()
        let recoveryItem = launch.recovery.items.first
        guard launch.queue.items.count == 1,
              launch.queue.items[0].jobID.rawValue == state.jobID,
              launch.queue.items[0].lifecycle == .paused,
              launch.queue.items[0].requestRecordStatus == .ready,
              launch.recovery.items.count == 1,
              recoveryItem?.jobID.rawValue == state.jobID,
              recoveryItem?.observedLifecycle == .paused,
              recoveryItem?.presentedLifecycle == .paused,
              recoveryItem?.status == .idle,
              recoveryItem?.resumable == true,
              recoveryItem?.containedFailureCount == 0 else {
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "relaunch did not reopen exactly one resumable paused job"
            )
        }
        let jobID = try WorkflowJobID(state.jobID)
        let outcome = try await coordinator.resume(
            jobID: jobID,
            progress: { _ in },
            snapshot: { _ in }
        )
        let completion: WorkflowApplicationCompletionV4
        switch outcome {
        case .completed(let value):
            completion = value
        case .paused:
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "the relaunched queue paused again instead of completing"
            )
        }
        let resumedProcessing = try processingIdentity(completion.result)
        guard completion.result.outputURL.standardizedFileURL
                == queueOutputURL.standardizedFileURL,
              resumedProcessing.actualBackendID
                == UpscaleBackendID.mirmirDeterministicCPU.rawValue else {
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "relaunch completed through another output or backend"
            )
        }
        let finalSnapshot = try await coordinator.queueSnapshot()
        guard finalSnapshot.items.count == 1,
              finalSnapshot.items[0].jobID == jobID,
              finalSnapshot.items[0].lifecycle == .completed else {
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "the resumed queue job did not reach completed"
            )
        }
        let recoveredSemantic = try await semanticIdentity(at: queueOutputURL)
        guard recoveredSemantic == state.directOutputSemantic else {
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "decoded pixels or timing differ after checkpoint relaunch"
            )
        }
        let recoveredArtifact = try MirmirNotarizedSmokeFilesV4.artifact(
            root: context.root,
            url: queueOutputURL
        )
        let finalQueueTreeSHA256 = try MirmirNotarizedSmokeFilesV4.treeSHA256(
            queueRoot
        )
        let result: [String: Any] = [
            "schemaVersion": resultSchema,
            "phase": request.phase.rawValue,
            "requestID": request.requestID,
            "requestSHA256": MirmirNotarizedSmokeFilesV4.sha256(requestData),
            "phaseOneResultSHA256": requiredPhaseOneHash,
            "applicationArchiveSHA256": request.applicationArchiveSHA256,
            "sourceCommit": request.sourceCommit,
            "observedAtUTC": utcNow(),
            "resultFileName": "recover-result.json",
            "process": try MirmirNotarizedSmokeFilesV4.object(process),
            "runtime": try MirmirNotarizedSmokeFilesV4.object(runtime),
            "resumedProcess": try MirmirNotarizedSmokeFilesV4.object(
                resumedProcessing
            ),
            "referenceSemantic": try MirmirNotarizedSmokeFilesV4.object(
                state.directOutputSemantic
            ),
            "recoveredSemantic": try MirmirNotarizedSmokeFilesV4.object(
                recoveredSemantic
            ),
            "queue": [
                "jobID": state.jobID,
                "launchLifecycle": WorkflowJobLifecycle.paused.rawValue,
                "finalLifecycle": WorkflowJobLifecycle.completed.rawValue,
                "launchRecoveryItemCount": launch.recovery.items.count,
                "launchRecoveryStatus": recoveryItem!.status.rawValue,
                "launchRecoveryObservedLifecycle": recoveryItem!
                    .observedLifecycle.rawValue,
                "launchRecoveryPresentedLifecycle": recoveryItem!
                    .presentedLifecycle.rawValue,
                "launchRecoveryResumable": recoveryItem!.resumable,
                "launchRecoveryContainedFailureCount": recoveryItem!
                    .containedFailureCount,
                "phaseOneQueueTreeSHA256": state.queueTreeSHA256,
                "finalQueueTreeSHA256": finalQueueTreeSHA256
            ],
            "artifacts": [
                "directOutput": try MirmirNotarizedSmokeFilesV4.object(
                    state.directOutputArtifact
                ),
                "recoveredOutput": try MirmirNotarizedSmokeFilesV4.object(
                    recoveredArtifact
                ),
                "phaseOneState": try MirmirNotarizedSmokeFilesV4.object(
                    try MirmirNotarizedSmokeFilesV4.artifact(
                        root: context.root,
                        url: stateURL
                    )
                )
            ],
            "checks": [
                "shippingExecutableIdentity": true,
                "sandboxIsolation": true,
                "productionP06Load": true,
                "phaseOneSealReplayVerified": true,
                "durableQueueReopened": true,
                "checkpointResumeCompleted": true,
                "decodedSemanticEquality": true,
                "userQueueUntouched": true
            ]
        ]
        let resultData = try MirmirNotarizedSmokeFilesV4.canonicalData(result)
        try MirmirNotarizedSmokeFilesV4.writeNew(
            resultData,
            to: context.root.appendingPathComponent("recover-result.json")
        )
        return resultData
    }
}

private extension MirmirNotarizedSmokeObserverV4 {
    static func utcNow() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }

    static func qualificationContext(
        request: MirmirNotarizedSmokeRequestV4,
        create: Bool
    ) throws -> QualificationContext {
        let fileManager = FileManager.default
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).standardizedFileURL.resolvingSymlinksInPath()
        let marker = "/Library/Containers/\(request.bundleIdentifier)/Data"
        guard let markerRange = support.path.range(of: marker),
              markerRange.upperBound < support.path.endIndex,
              support.path[markerRange.upperBound...] == "/Library/Application Support"
        else {
            throw MirmirNotarizedSmokeErrorV4.unsafeQualificationRoot(
                support.path
            )
        }
        let sandboxPath = String(support.path[..<markerRange.upperBound])
        let sandboxData = URL(fileURLWithPath: sandboxPath, isDirectory: true)
            .standardizedFileURL
        let qualificationDirectory = support.appendingPathComponent(
            "MirmirQualificationV4",
            isDirectory: true
        )
        try makeSecureDirectory(qualificationDirectory)
        let namespace = qualificationDirectory.appendingPathComponent(
            "notarized-smoke",
            isDirectory: true
        )
        try makeSecureDirectory(namespace)
        try validateOwnedDirectory(namespace)
        let root = namespace.appendingPathComponent(
            request.requestID,
            isDirectory: true
        ).standardizedFileURL
        guard root.deletingLastPathComponent() == namespace else {
            throw MirmirNotarizedSmokeErrorV4.unsafeQualificationRoot(root.path)
        }
        if create {
            guard !fileManager.fileExists(atPath: root.path) else {
                throw MirmirNotarizedSmokeErrorV4.unsafeQualificationRoot(
                    "request root already exists: \(root.path)"
                )
            }
            try fileManager.createDirectory(
                at: root,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try validateOwnedDirectory(root)
        return QualificationContext(
            root: root,
            applicationSupport: support,
            sandboxData: sandboxData
        )
    }

    static func validateOwnedDirectory(_ url: URL) throws {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR,
              metadata.st_uid == getuid(),
              metadata.st_nlink >= 1,
              metadata.st_mode & 0o022 == 0 else {
            throw MirmirNotarizedSmokeErrorV4.unsafeQualificationRoot(url.path)
        }
    }

    static func makeSecureDirectory(_ url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else {
            try validateOwnedDirectory(url)
            return
        }
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try validateOwnedDirectory(url)
    }

    static func processIdentity(
        request: MirmirNotarizedSmokeRequestV4,
        context: QualificationContext
    ) throws -> MirmirSmokeProcessIdentityV4 {
        guard let bundleID = Bundle.main.bundleIdentifier,
              let version = Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
              ) as? String,
              let build = Bundle.main.object(
                forInfoDictionaryKey: "CFBundleVersion"
              ) as? String,
              let executable = Bundle.main.executableURL else {
            throw MirmirNotarizedSmokeErrorV4.identityMismatch(
                "the shipping bundle omits executable metadata"
            )
        }
        let bundle = Bundle.main.bundleURL.standardizedFileURL
            .resolvingSymlinksInPath()
        let executableURL = executable.standardizedFileURL
            .resolvingSymlinksInPath()
        let executableSHA256 = try MirmirNotarizedSmokeFilesV4.sha256(
            executableURL
        )
        guard bundleID == request.bundleIdentifier,
              version == request.productVersion,
              build == request.productBuild,
              executableSHA256 == request.expectedExecutableSHA256,
              executableURL.path.hasPrefix(bundle.path + "/Contents/MacOS/")
        else {
            throw MirmirNotarizedSmokeErrorV4.identityMismatch(
                "bundle ID, version, build, or executable SHA-256"
            )
        }
        return MirmirSmokeProcessIdentityV4(
            bundleIdentifier: bundleID,
            productVersion: version,
            productBuild: build,
            bundlePath: bundle.path,
            executablePath: executableURL.path,
            executableSHA256: executableSHA256,
            processID: ProcessInfo.processInfo.processIdentifier,
            parentProcessID: getppid(),
            sandboxDataPath: context.sandboxData.path,
            applicationSupportPath: context.applicationSupport.path,
            qualificationRootPath: context.root.path
        )
    }

    static func runtimeIdentity(
        request: MirmirNotarizedSmokeRequestV4
    ) throws -> MirmirSmokeRuntimeIdentityV4 {
        guard ASHProductionP06TrustRootV4.isConfigured,
              ASHProductionP06TrustRootV4.manifestSHA256.rawValue
                == request.runtimeManifestSHA256 else {
            throw MirmirNotarizedSmokeErrorV4.identityMismatch(
                "the code-owned P06 trust root"
            )
        }
        let runtime = try ASHP06RuntimeProviderV4.production().load()
        try runtime.verifyBinding()
        try runtime.manifest.validate(requiring: .releaseQualified)
        _ = try runtime.measurementContract()
        _ = try runtime.branchProgram()
        _ = try runtime.verificationContract()
        let manifestURL = runtime.bundleURL.appendingPathComponent(
            ASHRuntimeManifestV4.fileName
        )
        let manifestFileSHA256 = try MirmirNotarizedSmokeFilesV4.sha256(
            manifestURL
        )
        guard runtime.manifestSHA256.rawValue
                == request.runtimeManifestSHA256,
              manifestFileSHA256 == request.runtimeManifestFileSHA256,
              runtime.manifest.runtimeID == ASHRuntimeManifestV4.runtimeIdentity,
              runtime.manifest.releaseStatus == .releaseQualified,
              runtime.manifest.provenance.sourceRevision
                == ASHProductionP06TrustRootV4.sourceRevision,
              runtime.manifest.provenance.builderSourceSHA256
                == ASHProductionP06TrustRootV4.builderSourceSHA256,
              runtime.manifest.artifacts.count
                == ASHRuntimeArtifactRoleV4.allCases.count else {
            throw MirmirNotarizedSmokeErrorV4.identityMismatch(
                "the loaded P06 release bundle"
            )
        }
        return MirmirSmokeRuntimeIdentityV4(
            runtimeID: runtime.manifest.runtimeID,
            releaseStatus: runtime.manifest.releaseStatus.rawValue,
            manifestSHA256: runtime.manifestSHA256.rawValue,
            manifestFileSHA256: manifestFileSHA256,
            sourceRevision: runtime.manifest.provenance.sourceRevision,
            builderSourceSHA256:
                runtime.manifest.provenance.builderSourceSHA256.rawValue,
            artifactCount: runtime.manifest.artifacts.count,
            runtimeBundlePath: runtime.bundleURL.standardizedFileURL.path,
            trustRootConfigured: ASHProductionP06TrustRootV4.isConfigured
        )
    }

    static func processingRequest(input: URL, output: URL) -> UpscaleRequest {
        UpscaleRequest(
            inputURL: input,
            outputURL: output,
            backendID: .mirmirDeterministicCPU,
            targetWidth: 96,
            targetHeight: 72,
            outputCodec: .h264,
            preserveAudio: false,
            overwriteExistingFile: false
        )
    }

    static func processingIdentity(
        _ result: UpscaleResult
    ) throws -> MirmirSmokeProcessingIdentityV4 {
        guard result.processingDurationSeconds.isFinite,
              result.processingDurationSeconds > 0,
              result.processedFrameCount > 0 else {
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "processing returned non-finite or empty measurements"
            )
        }
        return MirmirSmokeProcessingIdentityV4(
            actualBackendID: result.actualBackendID.rawValue,
            processedFrameCount: result.processedFrameCount,
            encodedWidth: result.encodedWidth,
            encodedHeight: result.encodedHeight,
            outputCodec: result.outputCodec.rawValue,
            processingDurationSeconds: result.processingDurationSeconds
        )
    }

    static func workflowCoordinator(
        queueRoot: URL,
        worker: String
    ) throws -> WorkflowApplicationCoordinatorV4 {
        let queue = try WorkflowApplicationQueueV4(
            trustedRootURL: queueRoot,
            workerID: WorkflowWorkerIDV4("notarized-smoke-\(worker)"),
            maximumConcurrentJobs: 1
        )
        let engine = WorkflowDeterministicApplicationEngineV4(
            videoProbe: VideoProbe(),
            backendCatalog: .live(),
            runtimeEnvironment: .current()
        )
        return WorkflowApplicationCoordinatorV4(
            queue: queue,
            engine: engine,
            maximumInputFramesPerBoundary: 1
        )
    }

    static func regularFileCount(root: URL, pathContains token: String) throws
        -> Int {
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "cannot enumerate durable queue"
            )
        }
        var count = 0
        for case let url as URL in enumerator where url.path.contains(token) {
            var metadata = stat()
            guard lstat(url.path, &metadata) == 0 else {
                throw MirmirNotarizedSmokeErrorV4.invariant(
                    "durable queue entry disappeared"
                )
            }
            if metadata.st_mode & S_IFMT == S_IFREG { count += 1 }
        }
        if let enumerationError {
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "durable queue enumeration failed: "
                    + enumerationError.localizedDescription
            )
        }
        return count
    }
}

private extension MirmirNotarizedSmokeObserverV4 {
    static func makeSourceMovie(at url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 64,
            AVVideoHeightKey: 48,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey:
                    AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoProfileLevelKey:
                    AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoMaxKeyFrameIntervalKey: 1
            ]
        ]
        guard writer.canApply(
            outputSettings: settings,
            forMediaType: .video
        ) else {
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "AVAssetWriter rejected the locked H.264 fixture"
            )
        }
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: settings
        )
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else {
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "AVAssetWriter rejected the fixture video input"
            )
        }
        writer.add(input)
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: 64,
            kCVPixelBufferHeightKey as String: 48,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: attributes
        )
        guard writer.startWriting() else {
            throw MirmirNotarizedSmokeErrorV4.invariant(
                writer.error?.localizedDescription
                    ?? "AVAssetWriter did not start"
            )
        }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<12 {
            var buffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(
                kCFAllocatorDefault,
                64,
                48,
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                attributes as CFDictionary,
                &buffer
            )
            guard status == kCVReturnSuccess, let buffer else {
                throw MirmirNotarizedSmokeErrorV4.invariant(
                    "CoreVideo could not allocate fixture frame \(status)"
                )
            }
            try fillSourceFrame(buffer, frame: frame)
            CVBufferSetAttachment(
                buffer,
                kCVImageBufferColorPrimariesKey,
                kCVImageBufferColorPrimaries_ITU_R_709_2,
                .shouldPropagate
            )
            CVBufferSetAttachment(
                buffer,
                kCVImageBufferTransferFunctionKey,
                kCVImageBufferTransferFunction_ITU_R_709_2,
                .shouldPropagate
            )
            CVBufferSetAttachment(
                buffer,
                kCVImageBufferYCbCrMatrixKey,
                kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                .shouldPropagate
            )
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing else {
                    throw MirmirNotarizedSmokeErrorV4.invariant(
                        writer.error?.localizedDescription
                            ?? "fixture writer stopped before append"
                    )
                }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            guard adaptor.append(
                buffer,
                withPresentationTime: CMTime(
                    value: Int64(frame),
                    timescale: 30
                )
            ) else {
                throw MirmirNotarizedSmokeErrorV4.invariant(
                    writer.error?.localizedDescription
                        ?? "fixture writer rejected a frame"
                )
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw MirmirNotarizedSmokeErrorV4.invariant(
                writer.error?.localizedDescription
                    ?? "fixture writer did not finish"
            )
        }
    }

    static func fillSourceFrame(_ buffer: CVPixelBuffer, frame: Int) throws {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard CVPixelBufferGetPlaneCount(buffer) == 2,
              let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)?
                .assumingMemoryBound(to: UInt8.self),
              let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)?
                .assumingMemoryBound(to: UInt8.self) else {
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "fixture buffer is not writable NV12"
            )
        }
        let lumaWidth = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let lumaHeight = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        for y in 0..<lumaHeight {
            let row = luma.advanced(by: y * lumaStride)
            for x in 0..<lumaWidth {
                // Keep the encoded fixture comfortably inside studio-swing
                // bounds. Lossy H.264 reconstruction may overshoot a source
                // code by one or more values; touching 16/235 here can turn a
                // valid writer input into an out-of-contract decoded frame.
                row[x] = UInt8(40 + ((x * 3 + y * 5 + frame * 11) % 176))
            }
        }
        let chromaWidth = CVPixelBufferGetWidthOfPlane(buffer, 1)
        let chromaHeight = CVPixelBufferGetHeightOfPlane(buffer, 1)
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        for y in 0..<chromaHeight {
            let row = chroma.advanced(by: y * chromaStride)
            for x in 0..<chromaWidth {
                row[x * 2] = UInt8(80 + ((x * 7 + frame * 13) % 96))
                row[x * 2 + 1] = UInt8(80 + ((y * 9 + frame * 17) % 96))
            }
        }
    }

    static func probeIdentity(
        _ source: VideoInfo
    ) throws -> MirmirSmokeProbeIdentityV4 {
        guard let encoded = source.geometry.encodedSize,
              let width = Int(exactly: encoded.width),
              let height = Int(exactly: encoded.height),
              let codec = source.codecFourCC,
              let estimatedFrameCount = source.estimatedFrameCount else {
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "VideoProbe omitted locked fixture facts"
            )
        }
        let codecFourCC = fourCC(codec)
        guard codecFourCC == "avc1" else {
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "the locked fixture writer produced another codec"
            )
        }
        // Some OS releases omit default H.264 format-description extensions.
        // The fallback facts are not guesses: makeSourceMovie locks an 8-bit
        // video-range NV12 input and progressive H.264 High profile. The
        // evidence-source fields make this normalization explicit.
        let bitDepth = source.color.bitDepth ?? 8
        let bitDepthEvidence = source.color.bitDepth == nil
            ? "locked_h264_writer_contract"
            : "format_description"
        let isFullRange = source.color.isFullRange ?? false
        let rangeEvidence = source.color.isFullRange == nil
            ? "locked_h264_writer_contract"
            : "format_description"
        let fieldCount = source.color.fieldCount ?? 1
        let fieldCountEvidence = source.color.fieldCount == nil
            ? "locked_h264_writer_contract"
            : "format_description"
        let duration = normalizedTime(source.duration)
        return MirmirSmokeProbeIdentityV4(
            encodedWidth: width,
            encodedHeight: height,
            codecFourCC: codecFourCC,
            durationValue: duration.value,
            durationTimescale: duration.timescale,
            estimatedFrameCount: estimatedFrameCount,
            videoTrackCount: source.videoTrackCount,
            audioTrackCount: source.audioTrackCount,
            bitDepth: bitDepth,
            bitDepthEvidence: bitDepthEvidence,
            isFullRange: isFullRange,
            rangeEvidence: rangeEvidence,
            dynamicRange: source.color.dynamicRange.rawValue,
            fieldCount: fieldCount,
            fieldCountEvidence: fieldCountEvidence,
            readable: source.isReadable,
            playable: source.isPlayable
        )
    }

    static func validateLockedInput(
        probe: MirmirSmokeProbeIdentityV4,
        semantic: MirmirSmokeSemanticIdentityV4
    ) throws {
        guard probe.encodedWidth == 64,
              probe.encodedHeight == 48,
              probe.codecFourCC == "avc1",
              probe.videoTrackCount == 1,
              probe.audioTrackCount == 0,
              probe.bitDepth == 8,
              !probe.isFullRange,
              probe.dynamicRange == VideoDynamicRange.sdr.rawValue,
              probe.fieldCount == 1,
              probe.readable,
              probe.playable,
              semantic.encodedWidth == 64,
              semantic.encodedHeight == 48,
              semantic.frameCount == 12,
              semantic.enabledVideoTrackCount == 1 else {
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "the generated source does not satisfy the locked real-media contract"
            )
        }
    }

    static func semanticIdentity(at url: URL) async throws
        -> MirmirSmokeSemanticIdentityV4 {
        let asset = AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let (duration, tracks) = try await asset.load(.duration, .tracks)
        var enabled: [AVAssetTrack] = []
        for track in tracks where track.mediaType == .video {
            if try await track.load(.isEnabled) { enabled.append(track) }
        }
        guard enabled.count == 1, let track = enabled.first else {
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "semantic verification requires one enabled video track"
            )
        }
        let descriptions = try await track.load(.formatDescriptions)
        guard let description = descriptions.first else {
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "semantic verification found no video format"
            )
        }
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        guard dimensions.width > 0, dimensions.height > 0 else {
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "semantic verification found invalid dimensions"
            )
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
        )
        output.alwaysCopiesSampleData = true
        guard reader.canAdd(output) else {
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "AVFoundation rejected the semantic decoder"
            )
        }
        reader.add(output)
        guard reader.startReading() else {
            throw MirmirNotarizedSmokeErrorV4.invariant(
                reader.error?.localizedDescription
                    ?? "semantic decoder did not start"
            )
        }
        var timingDigest = SHA256()
        timingDigest.update(data: Data("mirmir-smoke-timing-v1\0".utf8))
        var pixelDigest = SHA256()
        pixelDigest.update(data: Data("mirmir-smoke-visible-pixels-v1\0".utf8))
        var frameCount = 0
        while let sample = output.copyNextSampleBuffer() {
            let presentation = normalizedTime(
                CMSampleBufferGetPresentationTimeStamp(sample)
            )
            let rawDuration = CMSampleBufferGetDuration(sample)
            let sampleDuration = rawDuration.isValid && rawDuration.isNumeric
                ? normalizedTime(rawDuration)
                : CMTime(value: 0, timescale: 600_000)
            let timing = "\(frameCount):\(presentation.value)/"
                + "\(presentation.timescale):\(sampleDuration.value)/"
                + "\(sampleDuration.timescale)\n"
            timingDigest.update(data: Data(timing.utf8))
            guard let buffer = CMSampleBufferGetImageBuffer(sample),
                  CVPixelBufferGetPlaneCount(buffer) == 2 else {
                throw MirmirNotarizedSmokeErrorV4.invariant(
                    "semantic decoder did not return planar NV12"
                )
            }
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            for plane in 0..<2 {
                let width = CVPixelBufferGetWidthOfPlane(buffer, plane)
                let height = CVPixelBufferGetHeightOfPlane(buffer, plane)
                let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
                let visibleBytes = width * (plane == 0 ? 1 : 2)
                guard visibleBytes > 0,
                      height > 0,
                      stride >= visibleBytes,
                      let base = CVPixelBufferGetBaseAddressOfPlane(
                        buffer,
                        plane
                      )?.assumingMemoryBound(to: UInt8.self) else {
                    throw MirmirNotarizedSmokeErrorV4.invariant(
                        "semantic decoder returned unsafe plane geometry"
                    )
                }
                for row in 0..<height {
                    pixelDigest.update(data: Data(
                        bytes: base.advanced(by: row * stride),
                        count: visibleBytes
                    ))
                }
            }
            frameCount += 1
        }
        guard reader.status == .completed, frameCount > 0 else {
            throw MirmirNotarizedSmokeErrorV4.invariant(
                reader.error?.localizedDescription
                    ?? "semantic decoder did not complete"
            )
        }
        let normalizedDuration = normalizedTime(duration)
        return MirmirSmokeSemanticIdentityV4(
            encodedWidth: Int(dimensions.width),
            encodedHeight: Int(dimensions.height),
            frameCount: frameCount,
            enabledVideoTrackCount: enabled.count,
            durationValue: normalizedDuration.value,
            durationTimescale: normalizedDuration.timescale,
            timingSHA256: MirmirNotarizedSmokeFilesV4.hex(
                timingDigest.finalize()
            ),
            visiblePixelSHA256: MirmirNotarizedSmokeFilesV4.hex(
                pixelDigest.finalize()
            )
        )
    }

    static func normalizedTime(_ value: CMTime) -> CMTime {
        guard value.isValid && value.isNumeric else {
            return CMTime(value: 0, timescale: 600_000)
        }
        return CMTimeConvertScale(
            value,
            timescale: 600_000,
            method: .default
        )
    }

    static func fourCC(_ value: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "????????"
    }
}
