import Foundation

// The extracted ASH CPU reference only needs local, no-op instrumentation.
// Keeping this narrow avoids importing the legacy evidence, persistence, and
// release-admission telemetry system into the product target.
enum ASHTelemetryStage: Sendable {
    case canonicalize
    case analyzeLuma
    case analyzeChroma
    case statePack
    case telemetryReduce
    case dispatchDecode
    case reconstructLuma
    case reconstructChroma
    case frameTotal
}

enum ASHTelemetryCounter: Sendable {
    case fullFrameCopies
    case fullFrameCPULoops
    case fullFrameGPUReadbacks
    case inFlightFrames
    case commandBufferErrors
    case decodeExact
    case decodeCorrected
    case decodeRejected
    case candidateOne
    case candidateTwo
    case declaredPrimaryCandidates
    case declaredSecondaryCandidates
    case actualOperatorInvocations
    case affineCorrections
    case affineFallbacks
    case parityRecomputations
    case numericalFallbacks
    case sourceAlignedPreservations
}

struct ASHMediaObservation: Sendable {
    let kind: String
    let frameIndex: Int?
    let presentationTimestampValue: Int64?
    let presentationTimestampTimescale: Int32?
    let details: [String: String]

    init(
        kind: String,
        frameIndex: Int? = nil,
        presentationTimestampValue: Int64? = nil,
        presentationTimestampTimescale: Int32? = nil,
        details: [String: String] = [:]
    ) {
        self.kind = kind
        self.frameIndex = frameIndex
        self.presentationTimestampValue = presentationTimestampValue
        self.presentationTimestampTimescale = presentationTimestampTimescale
        self.details = details
    }
}

struct ASHCommandBufferObservation: Sendable {
    let label: String
    let status: String
    let frameIndex: Int?
    let presentationTimestampValue: Int64?
    let presentationTimestampTimescale: Int32?
    let errorDomain: String?
    let errorCode: Int?
    let gpuStartSeconds: Double?
    let gpuEndSeconds: Double?

    init(
        label: String,
        status: String,
        frameIndex: Int? = nil,
        presentationTimestampValue: Int64? = nil,
        presentationTimestampTimescale: Int32? = nil,
        errorDomain: String? = nil,
        errorCode: Int? = nil,
        gpuStartSeconds: Double? = nil,
        gpuEndSeconds: Double? = nil
    ) {
        self.label = label
        self.status = status
        self.frameIndex = frameIndex
        self.presentationTimestampValue = presentationTimestampValue
        self.presentationTimestampTimescale = presentationTimestampTimescale
        self.errorDomain = errorDomain
        self.errorCode = errorCode
        self.gpuStartSeconds = gpuStartSeconds
        self.gpuEndSeconds = gpuEndSeconds
    }
}

protocol ASHTelemetryRecording: AnyObject, Sendable {
    func increment(_ counter: ASHTelemetryCounter, by amount: UInt64)
    func recordState(rawValue: UInt16)
    func recordMessage(_ rawValue: UInt8)
    func recordOperator(_ rawValue: UInt8)
    func recordDecode(_ status: ASHDecodeStatus)
    func recordCandidateCount(_ count: Int)
    func recordMedia(_ observation: ASHMediaObservation)
    func recordError(_ error: Error, frameIndex: Int?)
    func recordCommandBuffer(_ observation: ASHCommandBufferObservation)
    func recordGPUTime(_ milliseconds: Double, for stage: ASHTelemetryStage)
}

extension ASHTelemetryRecording {
    func increment(_ counter: ASHTelemetryCounter) {
        increment(counter, by: 1)
    }

    func measure<T>(
        _ stage: ASHTelemetryStage,
        operation: () throws -> T
    ) rethrows -> T {
        _ = stage
        return try operation()
    }

    func recordError(_: Error, frameIndex _: Int?) {}
    func recordCommandBuffer(_: ASHCommandBufferObservation) {}
    func recordGPUTime(_: Double, for _: ASHTelemetryStage) {}
}

final class ASHNoopTelemetryRecorder: ASHTelemetryRecording, @unchecked Sendable {
    static let shared = ASHNoopTelemetryRecorder()

    private init() {}

    func increment(_: ASHTelemetryCounter, by _: UInt64) {}
    func recordState(rawValue _: UInt16) {}
    func recordMessage(_: UInt8) {}
    func recordOperator(_: UInt8) {}
    func recordDecode(_: ASHDecodeStatus) {}
    func recordCandidateCount(_: Int) {}
    func recordMedia(_: ASHMediaObservation) {}
}

// ASHNV12FrameCodec uses only this local failure shape from the former engine
// service. The product adapter converts it to a backend-specific MirmirError.
enum UpscalerEngineError: Error, Sendable {
    case strategyFailed(String)
}
