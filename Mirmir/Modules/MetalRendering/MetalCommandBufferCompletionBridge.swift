import Foundation
import Metal
import os.lock

struct MetalCommandBufferExecutionContext: Equatable, Sendable {
    let label: String
    let frameIndex: Int?
    let presentationTimestampValue: Int64?
    let presentationTimestampTimescale: Int32?

    init(
        label: String,
        frameIndex: Int? = nil,
        presentationTimestampValue: Int64? = nil,
        presentationTimestampTimescale: Int32? = nil
    ) {
        self.label = label
        self.frameIndex = frameIndex
        self.presentationTimestampValue = presentationTimestampValue
        self.presentationTimestampTimescale = presentationTimestampTimescale
    }
}

struct MetalCommandBufferStatusSnapshot: Equatable, Sendable {
    let rawValue: UInt
    let name: String

    static let completed = MetalCommandBufferStatusSnapshot(
        rawValue: UInt(MTLCommandBufferStatus.completed.rawValue),
        name: "completed"
    )
    static let error = MetalCommandBufferStatusSnapshot(
        rawValue: UInt(MTLCommandBufferStatus.error.rawValue),
        name: "error"
    )

    init(_ status: MTLCommandBufferStatus) {
        self.rawValue = UInt(status.rawValue)
        switch status {
        case .notEnqueued:
            self.name = "not_enqueued"
        case .enqueued:
            self.name = "enqueued"
        case .committed:
            self.name = "committed"
        case .scheduled:
            self.name = "scheduled"
        case .completed:
            self.name = "completed"
        case .error:
            self.name = "error"
        @unknown default:
            self.name = "unknown_\(status.rawValue)"
        }
    }

    init(rawValue: UInt, name: String) {
        self.rawValue = rawValue
        self.name = name
    }

    var isCompleted: Bool {
        rawValue == Self.completed.rawValue
    }
}

struct MetalCommandBufferErrorSnapshot: Equatable, Sendable {
    let domain: String
    let code: Int
    let message: String

    init(_ error: Error) {
        let nsError = error as NSError
        self.domain = nsError.domain
        self.code = nsError.code
        self.message = nsError.localizedDescription
    }

    init(domain: String, code: Int, message: String) {
        self.domain = domain
        self.code = code
        self.message = message
    }
}

struct MetalCommandBufferCompletion: Equatable, Sendable {
    let context: MetalCommandBufferExecutionContext
    let status: MetalCommandBufferStatusSnapshot
    let error: MetalCommandBufferErrorSnapshot?
    let gpuStartSeconds: Double?
    let gpuEndSeconds: Double?

    init(
        context: MetalCommandBufferExecutionContext,
        status: MetalCommandBufferStatusSnapshot,
        error: MetalCommandBufferErrorSnapshot? = nil,
        gpuStartSeconds: Double? = nil,
        gpuEndSeconds: Double? = nil
    ) {
        self.context = context
        self.status = status
        self.error = error
        self.gpuStartSeconds = gpuStartSeconds
        self.gpuEndSeconds = gpuEndSeconds
    }

    init(commandBuffer: MTLCommandBuffer, context: MetalCommandBufferExecutionContext) {
        self.context = MetalCommandBufferExecutionContext(
            label: commandBuffer.label ?? context.label,
            frameIndex: context.frameIndex,
            presentationTimestampValue: context.presentationTimestampValue,
            presentationTimestampTimescale: context.presentationTimestampTimescale
        )
        self.status = MetalCommandBufferStatusSnapshot(commandBuffer.status)
        self.error = commandBuffer.error.map(MetalCommandBufferErrorSnapshot.init)
        let gpuStart = commandBuffer.gpuStartTime
        let gpuEnd = commandBuffer.gpuEndTime
        self.gpuStartSeconds = gpuStart > 0 ? gpuStart : nil
        self.gpuEndSeconds = gpuEnd > 0 ? gpuEnd : nil
    }
}

enum MetalCommandBufferExecutionError: Error, Equatable, Sendable, CustomStringConvertible {
    case creationFailed(context: MetalCommandBufferExecutionContext)
    case executionFailed(MetalCommandBufferCompletion)

    var description: String {
        switch self {
        case .creationFailed(let context):
            let frameText = context.frameIndex.map { " frame \($0)" } ?? ""
            let ptsText: String
            if let value = context.presentationTimestampValue,
               let timescale = context.presentationTimestampTimescale {
                ptsText = " PTS \(value)/\(timescale)"
            } else {
                ptsText = ""
            }
            return "Metal command-buffer creation failed for \(context.label)\(frameText)\(ptsText)."
        case .executionFailed(let completion):
            let errorText = completion.error.map {
                "\($0.domain)(\($0.code)): \($0.message)"
            } ?? "no underlying error"
            let frameText = completion.context.frameIndex.map { " frame \($0)" } ?? ""
            let ptsText: String
            if let value = completion.context.presentationTimestampValue,
               let timescale = completion.context.presentationTimestampTimescale {
                ptsText = " PTS \(value)/\(timescale)"
            } else {
                ptsText = ""
            }
            return "Metal command buffer \(completion.context.label)\(frameText)\(ptsText) finished with status "
                + "\(completion.status.name): \(errorText)."
        }
    }
}

protocol MetalCommandBufferSubmitting: AnyObject, Sendable {
    var context: MetalCommandBufferExecutionContext { get }
    func addCompletedHandler(
        _ handler: @escaping @Sendable (MetalCommandBufferCompletion) -> Void
    )
    func commit()
}

final class DefaultMetalCommandBufferSubmission: MetalCommandBufferSubmitting, @unchecked Sendable {
    let commandBuffer: MTLCommandBuffer
    let context: MetalCommandBufferExecutionContext

    init(commandBuffer: MTLCommandBuffer, context: MetalCommandBufferExecutionContext) {
        self.commandBuffer = commandBuffer
        self.context = context
        commandBuffer.label = context.label
    }

    func addCompletedHandler(
        _ handler: @escaping @Sendable (MetalCommandBufferCompletion) -> Void
    ) {
        let context = context
        commandBuffer.addCompletedHandler { buffer in
            handler(MetalCommandBufferCompletion(
                commandBuffer: buffer,
                context: context
            ))
        }
    }

    func commit() {
        commandBuffer.commit()
    }
}

final class MetalCommandBufferRetainedResources: @unchecked Sendable {
    private let resources: [AnyObject]

    init(_ resources: [AnyObject]) {
        self.resources = resources
    }

    var count: Int { resources.count }
}

struct MetalCommandBufferCompletionBridge: Sendable {
    func commitAndWait(
        _ submission: any MetalCommandBufferSubmitting,
        retaining resources: MetalCommandBufferRetainedResources,
        onCommit: @escaping @Sendable () -> Void = {}
    ) async throws -> MetalCommandBufferCompletion {
        let completion = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<MetalCommandBufferCompletion, Error>) in
            let gate = MetalCommandBufferContinuationGate(continuation: continuation)
            submission.addCompletedHandler { completion in
                _ = resources.count
                guard completion.status.isCompleted, completion.error == nil else {
                    gate.resume(.failure(
                        MetalCommandBufferExecutionError.executionFailed(completion)
                    ))
                    return
                }
                gate.resume(.success(completion))
            }
            submission.commit()
            onCommit()
        }
        try Task.checkCancellation()
        return completion
    }
}

private final class MetalCommandBufferContinuationGate: @unchecked Sendable {
    private let continuation = OSAllocatedUnfairLock<
        CheckedContinuation<MetalCommandBufferCompletion, Error>?
    >(initialState: nil)

    init(continuation: CheckedContinuation<MetalCommandBufferCompletion, Error>) {
        self.continuation.withLock { $0 = continuation }
    }

    @discardableResult
    func resume(_ result: Result<MetalCommandBufferCompletion, Error>) -> Bool {
        let continuation = continuation.withLock { stored -> CheckedContinuation<
            MetalCommandBufferCompletion,
            Error
        >? in
            defer { stored = nil }
            return stored
        }
        guard let continuation else { return false }
        continuation.resume(with: result)
        return true
    }
}
