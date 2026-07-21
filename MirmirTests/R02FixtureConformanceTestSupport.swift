import AVFoundation
import AudioToolbox
import CoreMedia
import CoreVideo
import CryptoKit
import Foundation
import os.lock
@testable import Mirmir

// This support file keeps the frozen fixture catalog, generators, backend, and media
// transaction helpers together so their deterministic contract remains auditable.
// swiftlint:disable file_length

enum R02FixtureTestSupportError: Error, Equatable {
    case invalidCatalogIdentity
    case invalidFixtureIdentity(String)
    case invalidGeneratorInput
    case invalidNV12PayloadSize(expected: Int, actual: Int)
    case pixelBufferCreationFailed(OSStatus)
    case pixelBufferLockFailed(CVReturn)
    case invalidPixelBufferLayout
    case invalidFixtureDimensions
    case unsupportedBackendID(String)
    case mediaFixtureFailure(String)
}

// CodingKeys remain beside each frozen catalog value to preserve the JSON mapping.
// swiftlint:disable nesting
struct R02FixtureCatalog: Decodable, Sendable {
    let schemaVersion: String
    let phaseID: String
    let generatorContract: String
    let fixtures: [Fixture]
    let scenarios: [Scenario]

    struct Dimensions: Decodable, Equatable, Sendable {
        let width: Int
        let height: Int

        var videoResolution: VideoResolution {
            VideoResolution(width: width, height: height)
        }
    }

    struct Time: Decodable, Equatable, Sendable {
        let value: Int64
        let timescale: Int32

        var cmTime: CMTime {
            CMTime(value: value, timescale: timescale)
        }
    }

    struct ColorContract: Decodable, Equatable, Sendable {
        let colorPrimaries: String
        let transferFunction: String
        let matrix: String
        let chromaSiting: String
        let range: String

        func value() throws -> AppleUpscaleColorDescription {
            guard range == "video" else {
                throw R02FixtureTestSupportError.invalidFixtureIdentity(
                    "color_contract.range"
                )
            }
            return try AppleUpscaleColorDescription(
                colorPrimaries: colorPrimaries,
                transferFunction: transferFunction,
                matrix: matrix,
                chromaSiting: chromaSiting,
                range: .video
            )
        }

        private enum CodingKeys: String, CodingKey {
            case colorPrimaries = "color_primaries"
            case transferFunction = "transfer_function"
            case matrix
            case chromaSiting = "chroma_siting"
            case range
        }
    }

    struct Frame: Decodable, Equatable, Sendable {
        let sequenceNumber: Int
        let pts: Time
        let duration: Time
        let generatedContentSHA256: String
        let metadataIdentity: String
        let resourceTokenID: String

        private enum CodingKeys: String, CodingKey {
            case sequenceNumber = "sequence_number"
            case pts
            case duration
            case generatedContentSHA256 = "generated_content_sha256"
            case metadataIdentity = "metadata_identity"
            case resourceTokenID = "resource_token_id"
        }
    }

    struct AudioContract: Decodable, Equatable, Sendable {
        let trackCount: Int
        let codec: String
        let sampleRate: Int
        let channelCount: Int
        let sourceGeneratorID: String
        let sourceSampleFrames: Int
        let sourcePCMSHA256: String
        let semanticSHA256: String

        private enum CodingKeys: String, CodingKey {
            case trackCount = "track_count"
            case codec
            case sampleRate = "sample_rate"
            case channelCount = "channel_count"
            case sourceGeneratorID = "source_generator_id"
            case sourceSampleFrames = "source_sample_frames"
            case sourcePCMSHA256 = "source_pcm_sha256"
            case semanticSHA256 = "semantic_sha256"
        }
    }

    struct ContainerContract: Decodable, Equatable, Sendable {
        let fileType: String
        let videoCodec: String
        let reopenRequired: Bool
        let atomicPublicationRequired: Bool

        private enum CodingKeys: String, CodingKey {
            case fileType = "file_type"
            case videoCodec = "video_codec"
            case reopenRequired = "reopen_required"
            case atomicPublicationRequired = "atomic_publication_required"
        }
    }

    struct Fixture: Decodable, Equatable, Sendable {
        let id: String
        let kind: String
        let generatorID: String
        let seed: Int
        let sourceDimensions: Dimensions
        let targetDimensions: Dimensions
        let pixelFormat: String
        let colorContract: ColorContract
        let audioContract: AudioContract?
        let containerContract: ContainerContract?
        let frames: [Frame]
        let materialization: String
        let semanticSHA256: String

        private enum CodingKeys: String, CodingKey {
            case id
            case kind
            case generatorID = "generator_id"
            case seed
            case sourceDimensions = "source_dimensions"
            case targetDimensions = "target_dimensions"
            case pixelFormat = "pixel_format"
            case colorContract = "color_contract"
            case audioContract = "audio_contract"
            case containerContract = "container_contract"
            case frames
            case materialization
            case semanticSHA256 = "semantic_sha256"
        }
    }

    struct Scenario: Decodable, Equatable, Sendable {
        let id: String
        let fixtureIDs: [String]
        let backendIDs: [String]
        let requiredChecks: [String]

        private enum CodingKeys: String, CodingKey {
            case id
            case fixtureIDs = "fixture_ids"
            case backendIDs = "backend_ids"
            case requiredChecks = "required_checks"
        }
    }

    static func load() throws -> R02FixtureCatalog {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repositoryRoot.appendingPathComponent(
            "docs/roadmaps/evidence/r02/records/fixtures/fixture-catalog.json"
        )
        let catalog = try JSONDecoder().decode(
            R02FixtureCatalog.self,
            from: Data(contentsOf: url)
        )
        guard catalog.schemaVersion == "1.0.0",
              catalog.phaseID == "R02",
              catalog.generatorContract == "r02-deterministic-contract-fixtures-v1",
              catalog.fixtures.map(\.id) == [
                  "fixture-sequence-a",
                  "fixture-sequence-b",
                  "fixture-media-transaction"
              ] else {
            throw R02FixtureTestSupportError.invalidCatalogIdentity
        }
        return catalog
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case phaseID = "phase_id"
        case generatorContract = "generator_contract"
        case fixtures
        case scenarios
    }
}
// swiftlint:enable nesting

enum R02FixtureGenerators {
    static let generatorContract = "r02-deterministic-contract-fixtures-v1"
    static let nv12GeneratorID = "r02-deterministic-nv12-v1"
    static let pcmGeneratorID = "r02-deterministic-pcm-s16le-v1"

    static func nv12FrameBytes(
        width: Int,
        height: Int,
        seed: Int,
        sequenceNumber: Int
    ) throws -> Data {
        guard width >= 2,
              height >= 2,
              width.isMultiple(of: 2),
              height.isMultiple(of: 2),
              seed >= 1,
              sequenceNumber >= 0 else {
            throw R02FixtureTestSupportError.invalidGeneratorInput
        }
        let lumaCount = width * height
        let chromaCount = lumaCount / 2
        var payload = Data()
        payload.reserveCapacity(lumaCount + chromaCount)
        for index in 0..<lumaCount {
            payload.append(
                UInt8(16 + ((seed + sequenceNumber * 17 + index * 13) % 220))
            )
        }
        for index in 0..<chromaCount {
            payload.append(
                UInt8(16 + ((seed * 3 + sequenceNumber * 19 + index * 7) % 225))
            )
        }
        return payload
    }

    static func pcmS16LEBytes(
        sampleFrames: Int,
        channelCount: Int,
        seed: Int
    ) throws -> Data {
        guard sampleFrames >= 1, channelCount >= 1, seed >= 1 else {
            throw R02FixtureTestSupportError.invalidGeneratorInput
        }
        var payload = Data()
        payload.reserveCapacity(sampleFrames * channelCount * MemoryLayout<Int16>.size)
        for sampleIndex in 0..<sampleFrames {
            for channelIndex in 0..<channelCount {
                let unsigned = (seed + sampleIndex * 97 + channelIndex * 31) % 65_536
                let signed = Int16(unsigned - 32_768)
                let bits = UInt16(bitPattern: signed)
                payload.append(UInt8(truncatingIfNeeded: bits))
                payload.append(UInt8(truncatingIfNeeded: bits >> 8))
            }
        }
        return payload
    }

    static func sha256Hex(_ payload: Data) -> String {
        SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    }
}

enum R02FixturePixelBuffers {
    static func makeNV12(
        width: Int,
        height: Int,
        logicalBytes: Data
    ) throws -> CVPixelBuffer {
        let expectedSize = width * height * 3 / 2
        guard logicalBytes.count == expectedSize else {
            throw R02FixtureTestSupportError.invalidNV12PayloadSize(
                expected: expectedSize,
                actual: logicalBytes.count
            )
        }
        var optionalBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,
            &optionalBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer = optionalBuffer else {
            throw R02FixtureTestSupportError.pixelBufferCreationFailed(status)
        }
        guard CVPixelBufferGetPlaneCount(pixelBuffer) == 2 else {
            throw R02FixtureTestSupportError.invalidPixelBufferLayout
        }

        let lockStatus = CVPixelBufferLockBaseAddress(pixelBuffer, [])
        guard lockStatus == kCVReturnSuccess else {
            throw R02FixtureTestSupportError.pixelBufferLockFailed(lockStatus)
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        try copyRows(
            from: logicalBytes,
            sourceOffset: 0,
            logicalRowBytes: width,
            rowCount: height,
            to: pixelBuffer,
            plane: 0
        )
        try copyRows(
            from: logicalBytes,
            sourceOffset: width * height,
            logicalRowBytes: width,
            rowCount: height / 2,
            to: pixelBuffer,
            plane: 1
        )
        attachFrozenColorIdentity(to: pixelBuffer)
        return pixelBuffer
    }

    static func logicalNV12Bytes(from pixelBuffer: CVPixelBuffer) throws -> Data {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard CVPixelBufferGetPixelFormatType(pixelBuffer)
                == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
              CVPixelBufferGetPlaneCount(pixelBuffer) == 2 else {
            throw R02FixtureTestSupportError.invalidPixelBufferLayout
        }
        let lockStatus = CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        guard lockStatus == kCVReturnSuccess else {
            throw R02FixtureTestSupportError.pixelBufferLockFailed(lockStatus)
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        var payload = Data()
        payload.reserveCapacity(width * height * 3 / 2)
        try appendRows(
            from: pixelBuffer,
            plane: 0,
            logicalRowBytes: width,
            rowCount: height,
            to: &payload
        )
        try appendRows(
            from: pixelBuffer,
            plane: 1,
            logicalRowBytes: width,
            rowCount: height / 2,
            to: &payload
        )
        return payload
    }

    static func hasFrozenColorAttachments(_ pixelBuffer: CVPixelBuffer) -> Bool {
        attachment(pixelBuffer, key: kCVImageBufferColorPrimariesKey)
            == kCVImageBufferColorPrimaries_ITU_R_709_2 as String
            && attachment(pixelBuffer, key: kCVImageBufferTransferFunctionKey)
                == kCVImageBufferTransferFunction_ITU_R_709_2 as String
            && attachment(pixelBuffer, key: kCVImageBufferYCbCrMatrixKey)
                == kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String
            && attachment(pixelBuffer, key: kCVImageBufferChromaLocationTopFieldKey)
                == kCVImageBufferChromaLocation_Left as String
            && attachment(pixelBuffer, key: kCVImageBufferChromaLocationBottomFieldKey)
                == kCVImageBufferChromaLocation_Left as String
    }

    private static func copyRows(
        from payload: Data,
        sourceOffset: Int,
        logicalRowBytes: Int,
        rowCount: Int,
        to pixelBuffer: CVPixelBuffer,
        plane: Int
    ) throws {
        guard let baseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane),
              CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane) >= logicalRowBytes,
              sourceOffset + logicalRowBytes * rowCount <= payload.count else {
            throw R02FixtureTestSupportError.invalidPixelBufferLayout
        }
        let destination = baseAddress.assumingMemoryBound(to: UInt8.self)
        let destinationRowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
        for row in 0..<rowCount {
            for column in 0..<logicalRowBytes {
                destination[row * destinationRowBytes + column]
                    = payload[sourceOffset + row * logicalRowBytes + column]
            }
        }
    }

    private static func appendRows(
        from pixelBuffer: CVPixelBuffer,
        plane: Int,
        logicalRowBytes: Int,
        rowCount: Int,
        to payload: inout Data
    ) throws {
        guard let baseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane),
              CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane) >= logicalRowBytes else {
            throw R02FixtureTestSupportError.invalidPixelBufferLayout
        }
        let source = baseAddress.assumingMemoryBound(to: UInt8.self)
        let sourceRowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
        for row in 0..<rowCount {
            payload.append(source.advanced(by: row * sourceRowBytes), count: logicalRowBytes)
        }
    }

    private static func attachFrozenColorIdentity(to pixelBuffer: CVPixelBuffer) {
        let attachments: [(CFString, CFString)] = [
            (kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2),
            (kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2),
            (kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2),
            (kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_Left),
            (kCVImageBufferChromaLocationBottomFieldKey, kCVImageBufferChromaLocation_Left)
        ]
        for (key, value) in attachments {
            CVBufferSetAttachment(pixelBuffer, key, value, .shouldPropagate)
        }
    }

    private static func attachment(_ pixelBuffer: CVPixelBuffer, key: CFString) -> String? {
        CVBufferCopyAttachment(pixelBuffer, key, nil) as? String
    }
}

final class R02FixtureReleaseProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var releases: [String: Int] = [:]

    func recordRelease(identity: String) {
        lock.lock()
        releases[identity, default: 0] += 1
        lock.unlock()
    }

    func releaseCount(for identity: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return releases[identity, default: 0]
    }
}

final class R02FixtureDriverProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var finishCalls = 0
    private var cancelCalls = 0
    private var activeProcessCalls = 0
    private var maximumActiveProcessCalls = 0
    private var processSequenceNumbers: [Int] = []

    var finishCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return finishCalls
    }

    var cancelCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cancelCalls
    }

    var maximumConcurrentProcessCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return maximumActiveProcessCalls
    }

    var processedSequenceNumbers: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return processSequenceNumbers
    }

    func recordProcessBegin(sequenceNumber: Int) {
        lock.lock()
        activeProcessCalls += 1
        maximumActiveProcessCalls = max(
            maximumActiveProcessCalls,
            activeProcessCalls
        )
        processSequenceNumbers.append(sequenceNumber)
        lock.unlock()
    }

    func recordProcessEnd() {
        lock.lock()
        activeProcessCalls -= 1
        lock.unlock()
    }

    func recordFinish() {
        lock.lock()
        finishCalls += 1
        lock.unlock()
    }

    func recordCancel() {
        lock.lock()
        cancelCalls += 1
        lock.unlock()
    }
}

final class R02FixtureCopyDriver: AppleUpscaleSessionDriver, @unchecked Sendable {
    private let processingIdentity: AppleUpscaleProcessingIdentity
    private let cancellationRejection: AppleUpscaleBackendRejected
    private let frameContractRejection: AppleUpscaleBackendRejected
    private let copyFailure: AppleUpscaleBackendFailed
    private let sourceResolution: VideoResolution
    private let outputReleaseProbe: R02FixtureReleaseProbe
    private let driverProbe: R02FixtureDriverProbe

    init(
        route: AppleUpscaleRouteIdentity,
        sourceResolution: VideoResolution,
        outputReleaseProbe: R02FixtureReleaseProbe,
        driverProbe: R02FixtureDriverProbe
    ) throws {
        let processingIdentity = try AppleUpscaleProcessingIdentity(
            route: route,
            fallbackHistory: []
        )
        self.processingIdentity = processingIdentity
        cancellationRejection = try AppleUpscaleBackendRejected(
            processingIdentity: processingIdentity,
            reason: "operation_cancelled"
        )
        frameContractRejection = try AppleUpscaleBackendRejected(
            processingIdentity: processingIdentity,
            reason: "fixture_frame_contract_mismatch"
        )
        copyFailure = try AppleUpscaleBackendFailed(
            processingIdentity: processingIdentity,
            reason: "fixture_copy_failed"
        )
        self.sourceResolution = sourceResolution
        self.outputReleaseProbe = outputReleaseProbe
        self.driverProbe = driverProbe
    }

    func process(
        _ frame: AppleUpscaleFrame,
        historyGeneration _: UInt64,
        cancellation: AppleUpscaleOperationCancellationSignal
    ) async -> AppleUpscaleBackendOutcome<AppleUpscaleProcessedFrame> {
        driverProbe.recordProcessBegin(sequenceNumber: frame.sequenceNumber)
        defer { driverProbe.recordProcessEnd() }
        if cancellation.isCancelled {
            return .rejected(cancellationRejection)
        }
        guard CVPixelBufferGetWidth(frame.pixelBuffer) == sourceResolution.width,
              CVPixelBufferGetHeight(frame.pixelBuffer) == sourceResolution.height,
              CVPixelBufferGetPixelFormatType(frame.pixelBuffer)
                == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
              R02FixturePixelBuffers.hasFrozenColorAttachments(frame.pixelBuffer) else {
            return .rejected(frameContractRejection)
        }
        do {
            let bytes = try R02FixturePixelBuffers.logicalNV12Bytes(from: frame.pixelBuffer)
            let output = try R02FixturePixelBuffers.makeNV12(
                width: sourceResolution.width,
                height: sourceResolution.height,
                logicalBytes: bytes
            )
            let tokenIdentity = frame.resourceLifetimeToken.identity
            let outputToken = try AppleUpscaleResourceLifetimeToken(
                identity: tokenIdentity,
                releaseAction: { [outputReleaseProbe] in
                    outputReleaseProbe.recordRelease(identity: tokenIdentity)
                }
            )
            return .processed(
                try AppleUpscaleProcessedFrame(
                    sequenceNumber: frame.sequenceNumber,
                    pixelBuffer: output,
                    presentationTimestamp: frame.presentationTimestamp,
                    duration: frame.duration,
                    colorDescription: frame.colorDescription,
                    metadataIdentity: frame.metadataIdentity,
                    resourceLifetimeToken: outputToken,
                    processingIdentity: processingIdentity
                )
            )
        } catch {
            return .failed(copyFailure)
        }
    }

    func reset(
        reason _: AppleUpscaleResetReason,
        nextHistoryGeneration _: UInt64,
        cancellation _: AppleUpscaleOperationCancellationSignal
    ) async {}

    func finish() async {
        driverProbe.recordFinish()
    }

    func cancel() async {
        driverProbe.recordCancel()
    }
}

final class R02FixtureCopyBackend: AppleUpscaleBackend, @unchecked Sendable {
    static let supportedBackendIDs = [
        "r02.fixture.copy-a",
        "r02.fixture.copy-b"
    ]
    static let capabilityRawValue = "R02-FIXTURE"
    static let configurationIdentity = "r02-fixture-copy-v1"
    static let policyIdentity = "r02-fixture-only-v1"
    static let materialDecisionIdentity = "r02-fixture-copy-decision-v1"

    let identity: AppleUpscaleBackendIdentity
    let capabilityID: AppleUpscaleCapabilityID
    let routeIdentity: AppleUpscaleRouteIdentity

    private let sessionContractRejection: AppleUpscaleBackendRejected
    private let sessionCreationFailure: AppleUpscaleBackendFailed
    private let sourceResolution: VideoResolution
    private let targetResolution: VideoResolution
    private let outputReleaseProbe: R02FixtureReleaseProbe
    private let driverProbe: R02FixtureDriverProbe

    init(
        backendID: String,
        sourceResolution: VideoResolution,
        targetResolution: VideoResolution,
        outputReleaseProbe: R02FixtureReleaseProbe,
        driverProbe: R02FixtureDriverProbe
    ) throws {
        guard Self.supportedBackendIDs.contains(backendID) else {
            throw R02FixtureTestSupportError.unsupportedBackendID(backendID)
        }
        guard sourceResolution == VideoResolution(width: 16, height: 8),
              targetResolution == VideoResolution(width: 16, height: 8) else {
            throw R02FixtureTestSupportError.invalidFixtureDimensions
        }
        let identity = try AppleUpscaleBackendIdentity(
            backendID: backendID,
            backendRevision: "1",
            modelAssetsIdentity: .notRequired
        )
        let capabilityID = try AppleUpscaleCapabilityID(Self.capabilityRawValue)
        let routeIdentity = try AppleUpscaleRouteIdentity(
            backend: identity,
            configurationIdentity: Self.configurationIdentity,
            policyIdentity: Self.policyIdentity,
            materialDecisionIdentity: Self.materialDecisionIdentity
        )
        let processingIdentity = try AppleUpscaleProcessingIdentity(
            route: routeIdentity,
            fallbackHistory: []
        )
        self.identity = identity
        self.capabilityID = capabilityID
        self.routeIdentity = routeIdentity
        sessionContractRejection = try AppleUpscaleBackendRejected(
            processingIdentity: processingIdentity,
            reason: "fixture_session_contract_mismatch"
        )
        sessionCreationFailure = try AppleUpscaleBackendFailed(
            processingIdentity: processingIdentity,
            reason: "fixture_session_creation_failed"
        )
        self.sourceResolution = sourceResolution
        self.targetResolution = targetResolution
        self.outputReleaseProbe = outputReleaseProbe
        self.driverProbe = driverProbe
    }

    func makeSession(
        configuration: AppleUpscaleSessionConfiguration,
        context: AppleUpscaleSessionContext
    ) async -> AppleUpscaleSessionCreationOutcome {
        guard configuration.capabilityID == capabilityID,
              configuration.sourceResolution == sourceResolution,
              configuration.targetResolution == targetResolution,
              configuration.pixelFormat
                == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
              configuration.configurationIdentity == Self.configurationIdentity,
              context.admissionScope == .fixtureOnly,
              context.policyIdentity == Self.policyIdentity,
              let capability = context.capabilityRegistry.capability(for: capabilityID),
              capability.role == .primaryScaler,
              capability.frameworkIdentity == "MirmirFixture",
              capability.observationStatus == .observed,
              capability.runtimeDisposition == .runnable,
              capability.backendEligibility == .fixtureOnly,
              capability.isEligible(for: .fixtureOnly) else {
            return .rejected(sessionContractRejection)
        }
        do {
            let driver = try R02FixtureCopyDriver(
                route: routeIdentity,
                sourceResolution: sourceResolution,
                outputReleaseProbe: outputReleaseProbe,
                driverProbe: driverProbe
            )
            return .created(
                try AppleUpscaleFIFOSession(identity: routeIdentity, driver: driver)
            )
        } catch {
            return .failed(sessionCreationFailure)
        }
    }

    static func makeCapability() throws -> AppleUpscaleCapability {
        try AppleUpscaleCapability(
            id: AppleUpscaleCapabilityID(capabilityRawValue),
            role: .primaryScaler,
            frameworkIdentity: "MirmirFixture",
            observationStatus: .observed,
            runtimeDisposition: .runnable,
            backendEligibility: .fixtureOnly
        )
    }

}

struct R02MediaTransactionFiles {
    let directory: URL
    let source: URL
    let audioScratch: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mirmir-r02-\(UUID().uuidString)",
            isDirectory: true
        )
        source = directory.appendingPathComponent("frozen-source.mp4")
        audioScratch = directory.appendingPathComponent("frozen-audio.m4a")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    func destination(backendID: String) -> URL {
        directory.appendingPathComponent("\(backendID).mp4")
    }

    func temporaryFiles(for destination: URL) -> [URL] {
        let baseName = destination.deletingPathExtension().lastPathComponent
        return ((try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []).filter {
            $0.lastPathComponent.hasPrefix(".\(baseName).mirmir-")
                && $0.lastPathComponent.contains(".partial")
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

enum R02FrozenMediaFixtureWriter {
    private static let inputReadinessTimeout: Duration = .seconds(5)
    private static let inputReadinessPollInterval: Duration = .milliseconds(2)

    static func write(
        fixture: R02FixtureCatalog.Fixture,
        sourceURL: URL,
        audioScratchURL: URL
    ) async throws {
        guard fixture.id == "fixture-media-transaction",
              fixture.kind == "media_transaction",
              fixture.sourceDimensions == R02FixtureCatalog.Dimensions(
                  width: 16,
                  height: 8
              ),
              fixture.sourceDimensions == fixture.targetDimensions,
              let audio = fixture.audioContract,
              audio.codec == "aac",
              audio.sampleRate == 48_000,
              audio.channelCount == 2,
              audio.trackCount == 1,
              let container = fixture.containerContract,
              container.fileType == "mp4",
              container.videoCodec == "h264",
              container.reopenRequired,
              container.atomicPublicationRequired else {
            throw R02FixtureTestSupportError.invalidFixtureIdentity(fixture.id)
        }

        let pcm = try R02FixtureGenerators.pcmS16LEBytes(
            sampleFrames: audio.sourceSampleFrames,
            channelCount: audio.channelCount,
            seed: fixture.seed
        )
        guard R02FixtureGenerators.sha256Hex(pcm) == audio.sourcePCMSHA256 else {
            throw R02FixtureTestSupportError.invalidFixtureIdentity(
                "audio_contract.source_pcm_sha256"
            )
        }
        try writeAAC(
            pcm: pcm,
            sampleFrames: audio.sourceSampleFrames,
            sampleRate: audio.sampleRate,
            channelCount: audio.channelCount,
            to: audioScratchURL
        )
        try await muxVideoAndAAC(
            fixture: fixture,
            audioURL: audioScratchURL,
            destinationURL: sourceURL
        )
    }

    private static func writeAAC(
        pcm: Data,
        sampleFrames: Int,
        sampleRate: Int,
        channelCount: Int,
        to url: URL
    ) throws {
        guard let processingFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(sampleRate),
            channels: AVAudioChannelCount(channelCount),
            interleaved: true
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: processingFormat,
            frameCapacity: AVAudioFrameCount(sampleFrames)
        ), let channels = buffer.int16ChannelData else {
            throw R02FixtureTestSupportError.mediaFixtureFailure(
                "unable to allocate the frozen PCM buffer"
            )
        }
        buffer.frameLength = AVAudioFrameCount(sampleFrames)
        guard pcm.count == sampleFrames * channelCount * MemoryLayout<Int16>.size else {
            throw R02FixtureTestSupportError.invalidNV12PayloadSize(
                expected: sampleFrames * channelCount * MemoryLayout<Int16>.size,
                actual: pcm.count
            )
        }
        pcm.withUnsafeBytes { bytes in
            if let source = bytes.baseAddress {
                memcpy(channels[0], source, pcm.count)
            }
        }
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channelCount,
                AVEncoderBitRateKey: 128_000
            ],
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )
        try file.write(from: buffer)
    }

    // The mux state machine is intentionally contiguous so cleanup and terminal-state
    // transitions can be audited in execution order against the frozen transaction.
    // swiftlint:disable cyclomatic_complexity function_body_length
    private static func muxVideoAndAAC(
        fixture: R02FixtureCatalog.Fixture,
        audioURL: URL,
        destinationURL: URL
    ) async throws {
        let audioAsset = AVURLAsset(
            url: audioURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let audioTracks = try await audioAsset.loadTracks(withMediaType: .audio)
        guard audioTracks.count == 1, let audioTrack = audioTracks.first else {
            throw R02FixtureTestSupportError.mediaFixtureFailure(
                "frozen AAC source did not contain exactly one track"
            )
        }
        let audioFormats = try await audioTrack.load(.formatDescriptions)
        guard let audioFormat = audioFormats.first else {
            throw R02FixtureTestSupportError.mediaFixtureFailure(
                "frozen AAC source had no format description"
            )
        }
        let reader = try AVAssetReader(asset: audioAsset)
        let audioOutput = AVAssetReaderTrackOutput(
            track: audioTrack,
            outputSettings: nil
        )
        audioOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(audioOutput) else {
            throw R02FixtureTestSupportError.mediaFixtureFailure(
                "reader rejected the compressed AAC track"
            )
        }
        reader.add(audioOutput)

        let writer = try AVAssetWriter(url: destinationURL, fileType: .mp4)
        writer.movieTimeScale = 30_000
        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: fixture.sourceDimensions.width,
                AVVideoHeightKey: fixture.sourceDimensions.height,
                AVVideoColorPropertiesKey: [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
                ]
            ]
        )
        videoInput.mediaTimeScale = 30_000
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey as String: fixture.sourceDimensions.width,
                kCVPixelBufferHeightKey as String: fixture.sourceDimensions.height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
            ]
        )
        let audioInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: nil,
            sourceFormatHint: audioFormat
        )
        audioInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput), writer.canAdd(audioInput) else {
            throw R02FixtureTestSupportError.mediaFixtureFailure(
                "writer rejected a frozen media input"
            )
        }
        writer.add(videoInput)
        writer.add(audioInput)

        var completedWriting = false
        defer {
            if !completedWriting {
                if reader.status == .reading {
                    reader.cancelReading()
                }
                if writer.status == .writing {
                    writer.cancelWriting()
                }
            }
        }

        guard reader.startReading() else {
            throw R02FixtureTestSupportError.mediaFixtureFailure(
                reader.error.map(String.init(describing:))
                    ?? "compressed AAC reader did not start"
            )
        }
        guard writer.startWriting() else {
            throw R02FixtureTestSupportError.mediaFixtureFailure(
                writer.error.map(String.init(describing:))
                    ?? "frozen MP4 writer did not start"
            )
        }
        writer.startSession(atSourceTime: .zero)

        for frame in fixture.frames {
            try await waitForWriterInputReadiness(
                videoInput,
                writer: writer,
                inputName: "video"
            )
            let bytes = try R02FixtureGenerators.nv12FrameBytes(
                width: fixture.sourceDimensions.width,
                height: fixture.sourceDimensions.height,
                seed: fixture.seed,
                sequenceNumber: frame.sequenceNumber
            )
            let pixelBuffer = try R02FixturePixelBuffers.makeNV12(
                width: fixture.sourceDimensions.width,
                height: fixture.sourceDimensions.height,
                logicalBytes: bytes
            )
            guard adaptor.append(pixelBuffer, withPresentationTime: frame.pts.cmTime) else {
                throw R02FixtureTestSupportError.mediaFixtureFailure(
                    writer.error.map(String.init(describing:))
                        ?? "frozen video frame append failed"
                )
            }
        }
        videoInput.markAsFinished()

        while let sample = audioOutput.copyNextSampleBuffer() {
            try await waitForWriterInputReadiness(
                audioInput,
                writer: writer,
                inputName: "AAC"
            )
            guard audioInput.append(sample) else {
                throw R02FixtureTestSupportError.mediaFixtureFailure(
                    writer.error.map(String.init(describing:))
                        ?? "frozen AAC append failed"
                )
            }
        }
        guard reader.status == .completed else {
            throw R02FixtureTestSupportError.mediaFixtureFailure(
                reader.error.map(String.init(describing:))
                    ?? "frozen AAC reader did not complete"
            )
        }
        audioInput.markAsFinished()
        guard let lastFrame = fixture.frames.last else {
            throw R02FixtureTestSupportError.invalidFixtureIdentity(
                "fixture-media-transaction.frames"
            )
        }
        writer.endSession(
            atSourceTime: CMTimeAdd(lastFrame.pts.cmTime, lastFrame.duration.cmTime)
        )
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw R02FixtureTestSupportError.mediaFixtureFailure(
                writer.error.map(String.init(describing:))
                    ?? "frozen MP4 writer did not complete"
            )
        }
        completedWriting = true
    }
    // swiftlint:enable cyclomatic_complexity function_body_length

    private static func waitForWriterInputReadiness(
        _ input: AVAssetWriterInput,
        writer: AVAssetWriter,
        inputName: String
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: inputReadinessTimeout)

        while true {
            if Task.isCancelled {
                throw R02FixtureTestSupportError.mediaFixtureFailure(
                    "\(inputName) input readiness wait was cancelled"
                )
            }
            switch writer.status {
            case .writing:
                break
            case .failed:
                throw R02FixtureTestSupportError.mediaFixtureFailure(
                    writer.error.map(String.init(describing:))
                        ?? "\(inputName) input writer failed while awaiting readiness"
                )
            case .cancelled:
                throw R02FixtureTestSupportError.mediaFixtureFailure(
                    "\(inputName) input writer was cancelled while awaiting readiness"
                )
            case .completed:
                throw R02FixtureTestSupportError.mediaFixtureFailure(
                    "\(inputName) input writer completed before becoming ready"
                )
            case .unknown:
                throw R02FixtureTestSupportError.mediaFixtureFailure(
                    "\(inputName) input writer was not started while awaiting readiness"
                )
            @unknown default:
                throw R02FixtureTestSupportError.mediaFixtureFailure(
                    "\(inputName) input writer entered an unknown status"
                )
            }

            if input.isReadyForMoreMediaData {
                return
            }
            let now = clock.now
            guard now < deadline else {
                throw R02FixtureTestSupportError.mediaFixtureFailure(
                    "\(inputName) input readiness timed out after five seconds"
                )
            }
            do {
                try await clock.sleep(
                    until: min(
                        deadline,
                        now.advanced(by: inputReadinessPollInterval)
                    )
                )
            } catch {
                throw R02FixtureTestSupportError.mediaFixtureFailure(
                    "\(inputName) input readiness wait was cancelled"
                )
            }
        }
    }
}

struct R02PrepublicationVerificationSnapshot: Equatable, Sendable {
    let invocationCount: Int
    let successfulVerificationCount: Int
    let destinationWasAbsent: Bool
    let temporaryInputWasPresent: Bool
    let verifiedURL: URL?
}

final class R02PrepublicationVerifier: OutputMediaVerifying, @unchecked Sendable {
    private struct State {
        var invocationCount = 0
        var successfulVerificationCount = 0
        var destinationWasAbsent = false
        var temporaryInputWasPresent = false
        var verifiedURL: URL?
    }

    private let destinationURL: URL
    private let expectedAACIdentity: OutputMediaAACIdentity
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(
        destinationURL: URL,
        expectedAACIdentity: OutputMediaAACIdentity
    ) {
        self.destinationURL = destinationURL
        self.expectedAACIdentity = expectedAACIdentity
    }

    var snapshot: R02PrepublicationVerificationSnapshot {
        state.withLock { state in
            R02PrepublicationVerificationSnapshot(
                invocationCount: state.invocationCount,
                successfulVerificationCount: state.successfulVerificationCount,
                destinationWasAbsent: state.destinationWasAbsent,
                temporaryInputWasPresent: state.temporaryInputWasPresent,
                verifiedURL: state.verifiedURL
            )
        }
    }

    func verify(
        url: URL,
        expectation: OutputMediaVerificationExpectation
    ) async throws -> OutputMediaVerificationResult {
        let destinationAbsent = !FileManager.default.fileExists(
            atPath: destinationURL.path
        )
        let temporaryPresent = FileManager.default.fileExists(atPath: url.path)
        state.withLock { state in
            state.invocationCount += 1
            state.destinationWasAbsent = destinationAbsent
            state.temporaryInputWasPresent = temporaryPresent
            state.verifiedURL = url
        }
        guard url != destinationURL, destinationAbsent, temporaryPresent else {
            throw R02FixtureTestSupportError.mediaFixtureFailure(
                "verification did not run against an unpublished temporary file"
            )
        }
        guard expectation.videoColor == .sdrBT709VideoRangeLeft,
              expectation.compressedAACIdentity == expectedAACIdentity else {
            throw R02FixtureTestSupportError.mediaFixtureFailure(
                "production verification omitted frozen color or compressed AAC identity"
            )
        }

        let result = try await OutputMediaVerifier().verify(
            url: url,
            expectation: expectation
        )
        state.withLock { state in
            state.successfulVerificationCount += 1
        }
        return result
    }
}
// swiftlint:enable file_length
