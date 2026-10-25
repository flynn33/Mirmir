import CoreMedia
import CoreVideo
import Foundation

struct PixelBufferAttributes: @unchecked Sendable {
    // Core Video publishes immutable attribute dictionaries containing
    // property-list values and immutable Core Foundation objects. Keeping the
    // unchecked boundary in this wrapper prevents `[String: Any]` from being
    // declared Sendable throughout the processing API.
    let values: [String: Any]

    init(_ values: [String: Any] = [:]) {
        self.values = values
    }
}

struct FramePixelBuffer: @unchecked Sendable {
    // CVPixelBuffer is reference-counted but is not imported as Sendable. The
    // coordinator transfers exclusive frame access to one prepared backend
    // call at a time. This wrapper retains the buffer across that actor hop and
    // keeps the unchecked boundary local to the frame-processing protocol.
    let value: CVPixelBuffer

    init(_ value: CVPixelBuffer) {
        self.value = value
    }
}

struct FrameTiming: Equatable, Sendable {
    let frameIndex: Int
    let presentationTime: CMTime
    let duration: CMTime
    /// A caller-observed semantic boundary that must clear temporal evidence
    /// before this frame. PTS gaps are also detected by the deterministic v4
    /// adapter; this field carries boundaries such as seeks and edit changes
    /// that cannot be inferred from a pixel buffer alone.
    let temporalResetReason: ASHTemporalResetReasonV4?

    init(
        frameIndex: Int,
        presentationTime: CMTime,
        duration: CMTime,
        temporalResetReason: ASHTemporalResetReasonV4? = nil
    ) {
        self.frameIndex = frameIndex
        self.presentationTime = presentationTime
        self.duration = duration
        self.temporalResetReason = temporalResetReason
    }
}

struct BackendPreparationRequest: Equatable, Sendable {
    let source: VideoInfo
    let targetSize: CGSize
}

protocol UpscaleBackend: Sendable {
    var descriptor: BackendDescriptor { get }

    func availability(
        for source: VideoInfo,
        targetSize: CGSize,
        environment: RuntimeEnvironment
    ) async -> BackendAvailability

    func prepare(
        request: BackendPreparationRequest,
        environment: RuntimeEnvironment
    ) async throws -> any PreparedFrameUpscaler
}

protocol ModelDownloadableBackend: UpscaleBackend {
    func downloadModel(
        request: BackendPreparationRequest,
        environment: RuntimeEnvironment,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws
}

protocol PreparedFrameUpscaler: Sendable {
    var sourcePixelBufferAttributes: PixelBufferAttributes { get }
    var destinationPixelBufferAttributes: PixelBufferAttributes { get }
    var actualBackendID: UpscaleBackendID { get }

    func process(
        source: FramePixelBuffer,
        destination: FramePixelBuffer,
        timing: FrameTiming
    ) async throws

    func finish() async throws
}

extension PreparedFrameUpscaler {
    func process(
        source: CVPixelBuffer,
        destination: CVPixelBuffer,
        timing: FrameTiming
    ) async throws {
        try await process(
            source: FramePixelBuffer(source),
            destination: FramePixelBuffer(destination),
            timing: timing
        )
    }
}

enum TemporalOutputSourceFieldV4: String, Codable, Equatable, Sendable {
    case progressive
    case top
    case bottom
}

struct TemporalOutputFrame: Sendable {
    let pixelBuffer: FramePixelBuffer
    let presentationTime: CMTime
    let duration: CMTime
    let sourceField: TemporalOutputSourceFieldV4
    let cadenceID: String
    let temporalGeneration: UInt64
    let temporalResetReason: ASHTemporalResetReasonV4?

    init(
        pixelBuffer: FramePixelBuffer,
        presentationTime: CMTime,
        duration: CMTime = .invalid,
        sourceField: TemporalOutputSourceFieldV4 = .progressive,
        cadenceID: String = "unspecified",
        temporalGeneration: UInt64 = 0,
        temporalResetReason: ASHTemporalResetReasonV4? = nil
    ) {
        self.pixelBuffer = pixelBuffer
        self.presentationTime = presentationTime
        self.duration = duration
        self.sourceField = sourceField
        self.cadenceID = cadenceID
        self.temporalGeneration = temporalGeneration
        self.temporalResetReason = temporalResetReason
    }
}

protocol PreparedTemporalFrameUpscaler: PreparedFrameUpscaler {
    var maximumOutputFramesPerInput: Int { get }

    func processTemporal(
        source: FramePixelBuffer,
        destinations: [FramePixelBuffer],
        timing: FrameTiming
    ) async throws -> [TemporalOutputFrame]
}

/// A temporal backend whose complete deterministic state can be persisted at
/// an independently committed media-segment boundary. The payload is opaque to
/// the workflow layer and is identity-bound by the backend itself.
protocol PreparedCheckpointableTemporalFrameUpscaler:
    PreparedTemporalFrameUpscaler {
    func makeTemporalCheckpoint(
        planSHA256: ASHSHA256V4,
        lastCompletedInputOrdinal: Int64
    ) async throws -> Data

    func restoreTemporalCheckpoint(
        _ data: Data,
        planSHA256: ASHSHA256V4
    ) async throws
}

/// Planning surface implemented only by a prepared deterministic v4 engine.
/// It exposes immutable execution facts needed by the whole-asset planner and
/// keeps the verified runtime bundle actor-isolated inside the backend.
protocol PreparedDeterministicV4RuntimePlanningBackend: PreparedFrameUpscaler {
    var deterministicExecutor: ASHExecutorV4 { get }
    var deterministicSourceDeliveryIdentity: String? { get }
    var deterministicChromaGeometry: SpatialChromaGeometryV4? { get }
    var deterministicInterlacedChromaGeometry: SpatialInterlacedChromaGeometryV4? { get }

    func makeASHExecutionPlan(
        media: CanonicalMediaStateV4,
        request: ASHExecutionRequestV4
    ) async throws -> ASHIdentifiedExecutionPlanV4
}

extension PreparedDeterministicV4RuntimePlanningBackend {
    var deterministicSourceDeliveryIdentity: String? { nil }
    var deterministicChromaGeometry: SpatialChromaGeometryV4? { nil }
    var deterministicInterlacedChromaGeometry: SpatialInterlacedChromaGeometryV4? { nil }
}

protocol PreparedDeterministicV4PlanningBackend:
    PreparedDeterministicV4RuntimePlanningBackend {
    var deterministicStorage: PixelStorageV4 { get }
}

enum BackendPreparationError: LocalizedError, Equatable, Sendable {
    case unavailable(UpscaleBackendID, BackendUnavailableReason)

    var errorDescription: String? {
        switch self {
        case .unavailable(let backendID, let reason):
            let title = BackendDescriptor.descriptor(for: backendID)?.title
                ?? backendID.rawValue
            return "\(title) is unavailable. \(reason.userFacingDescription)"
        }
    }
}
