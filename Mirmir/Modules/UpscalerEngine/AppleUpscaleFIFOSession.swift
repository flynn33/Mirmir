import CoreMedia
import Foundation

protocol AppleUpscaleSessionDriver: AnyObject, Sendable {
    func process(
        _ frame: AppleUpscaleFrame,
        historyGeneration: UInt64,
        cancellation: AppleUpscaleOperationCancellationSignal
    ) async -> AppleUpscaleBackendOutcome<AppleUpscaleProcessedFrame>

    func reset(
        reason: AppleUpscaleResetReason,
        nextHistoryGeneration: UInt64,
        cancellation: AppleUpscaleOperationCancellationSignal
    ) async

    func finish() async
    func cancel() async
}

final class AppleUpscaleOperationCancellationSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

enum AppleUpscaleFIFOSessionOperationKind: String, Hashable, Sendable {
    case submit
    case reset
    case finish
    case cancel
}

struct AppleUpscaleFIFOSessionAdmission: Hashable, Sendable {
    let ticket: UInt64
    let operation: AppleUpscaleFIFOSessionOperationKind
}

typealias AppleUpscaleFIFOSessionAdmissionObserver = @Sendable (
    AppleUpscaleFIFOSessionAdmission
) -> Void

enum AppleUpscaleFIFOSubmitRejectionReason: String, CaseIterable, Hashable, Sendable {
    case admissionClosed = "admission_closed"
    case duplicateOrNonIncreasingSequence = "duplicate_or_non_increasing_sequence"
    case nonIncreasingPresentationTimestamp = "non_increasing_presentation_timestamp"
    case invalidDuration = "invalid_duration"
    case operationCancelled = "operation_cancelled"
}

actor AppleUpscaleFIFOSession<Driver: AppleUpscaleSessionDriver>: AppleUpscaleSession {
    nonisolated let identity: AppleUpscaleRouteIdentity

    private enum TerminalCause: Sendable {
        case finished
        case cancelled
    }

    private enum Lifecycle {
        case open
        case finishing(fenceTicket: UInt64)
        case cancelling(fenceTicket: UInt64)
        case terminal(cause: TerminalCause, summary: AppleUpscaleSessionSummary)
    }

    private enum QueuedOperation {
        case submit(
            ticket: UInt64,
            frame: AppleUpscaleFrame,
            continuation: CheckedContinuation<
                AppleUpscaleBackendOutcome<AppleUpscaleProcessedFrame>,
                Never
            >
        )
        case reset(
            ticket: UInt64,
            reason: AppleUpscaleResetReason,
            continuation: CheckedContinuation<Void, Never>
        )
        case finish(ticket: UInt64)
        case cancel(
            ticket: UInt64,
            driverCancellation: Task<Void, Never>
        )
    }

    private let driver: Driver
    private let directProcessingIdentity: AppleUpscaleProcessingIdentity
    private let submitRejections: [
        AppleUpscaleFIFOSubmitRejectionReason: AppleUpscaleBackendRejected
    ]
    private let driverIdentityMismatchFailure: AppleUpscaleBackendFailed
    private let admissionObserver: AppleUpscaleFIFOSessionAdmissionObserver

    private var lifecycle: Lifecycle = .open
    private var nextTicket: UInt64 = 0
    private var queue: [QueuedOperation] = []
    private var isDraining = false
    private var activeCancellationSignal: AppleUpscaleOperationCancellationSignal?
    private var cancellationGeneration: UInt64 = 0
    private var historyGeneration: UInt64 = 0
    private var lastSequenceNumber: Int?
    private var lastPresentationTimestamp: CMTime?
    private var submittedFrameCount = 0
    private var processedFrameCount = 0
    private var terminalizationCount = 0
    private var finishWaiters: [CheckedContinuation<AppleUpscaleSessionSummary, Never>] = []
    private var cancelWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        identity: AppleUpscaleRouteIdentity,
        driver: Driver,
        admissionObserver: @escaping AppleUpscaleFIFOSessionAdmissionObserver = { _ in }
    ) throws {
        self.identity = identity
        self.driver = driver
        let directProcessingIdentity = try AppleUpscaleProcessingIdentity(
            route: identity,
            fallbackHistory: []
        )
        self.directProcessingIdentity = directProcessingIdentity
        submitRejections = try Dictionary(
            uniqueKeysWithValues: AppleUpscaleFIFOSubmitRejectionReason.allCases.map { reason in
                (
                    reason,
                    try AppleUpscaleBackendRejected(
                        processingIdentity: directProcessingIdentity,
                        reason: reason.rawValue
                    )
                )
            }
        )
        driverIdentityMismatchFailure = try AppleUpscaleBackendFailed(
            processingIdentity: directProcessingIdentity,
            reason: "driver_identity_mismatch"
        )
        self.admissionObserver = admissionObserver
    }

    func submit(
        _ frame: AppleUpscaleFrame
    ) async -> AppleUpscaleBackendOutcome<AppleUpscaleProcessedFrame> {
        let ticket = admit(.submit)
        guard case .open = lifecycle else {
            frame.resourceLifetimeToken.release()
            return rejected(.admissionClosed)
        }

        return await withCheckedContinuation { continuation in
            queue.append(
                .submit(
                    ticket: ticket,
                    frame: frame,
                    continuation: continuation
                )
            )
            startDrainingIfNeeded()
        }
    }

    func reset(reason: AppleUpscaleResetReason) async {
        let ticket = admit(.reset)
        guard case .open = lifecycle else { return }

        await withCheckedContinuation { continuation in
            queue.append(
                .reset(
                    ticket: ticket,
                    reason: reason,
                    continuation: continuation
                )
            )
            startDrainingIfNeeded()
        }
    }

    func finish() async -> AppleUpscaleSessionSummary {
        let ticket = admit(.finish)
        return await withCheckedContinuation { continuation in
            switch lifecycle {
            case .open:
                lifecycle = .finishing(fenceTicket: ticket)
                finishWaiters.append(continuation)
                queue.append(.finish(ticket: ticket))
                startDrainingIfNeeded()
            case .finishing, .cancelling:
                finishWaiters.append(continuation)
            case .terminal(_, let summary):
                continuation.resume(returning: summary)
            }
        }
    }

    func cancel() async {
        let ticket = admit(.cancel)
        await withCheckedContinuation { continuation in
            switch lifecycle {
            case .open:
                lifecycle = .cancelling(fenceTicket: ticket)
                cancellationGeneration += 1
                activeCancellationSignal?.cancel()
                cancelWaiters.append(continuation)
                rejectQueuedOperationsForCancellation()
                let driverCancellation = Task { [driver] in
                    await driver.cancel()
                }
                queue.append(.cancel(
                    ticket: ticket,
                    driverCancellation: driverCancellation
                ))
                startDrainingIfNeeded()
            case .finishing, .cancelling:
                cancelWaiters.append(continuation)
            case .terminal:
                continuation.resume()
            }
        }
    }

    private func admit(
        _ operation: AppleUpscaleFIFOSessionOperationKind
    ) -> UInt64 {
        let ticket = nextTicket
        nextTicket += 1
        admissionObserver(
            AppleUpscaleFIFOSessionAdmission(ticket: ticket, operation: operation)
        )
        return ticket
    }

    private func startDrainingIfNeeded() {
        guard !isDraining else { return }
        isDraining = true
        Task { await drainQueue() }
    }

    private func drainQueue() async {
        while !queue.isEmpty {
            let operation = queue.removeFirst()
            switch operation {
            case .submit(_, let frame, let continuation):
                await performSubmit(frame, continuation: continuation)
            case .reset(_, let reason, let continuation):
                await performReset(reason: reason, continuation: continuation)
            case .finish:
                await driver.finish()
                completeTerminal(cause: .finished)
            case .cancel(_, let driverCancellation):
                await driverCancellation.value
                completeTerminal(cause: .cancelled)
            }
        }
        isDraining = false
    }

    private func performSubmit(
        _ frame: AppleUpscaleFrame,
        continuation: CheckedContinuation<
            AppleUpscaleBackendOutcome<AppleUpscaleProcessedFrame>,
            Never
        >
    ) async {
        if let reason = validationRejection(for: frame) {
            frame.resourceLifetimeToken.release()
            continuation.resume(returning: rejected(reason))
            return
        }

        lastSequenceNumber = frame.sequenceNumber
        lastPresentationTimestamp = frame.presentationTimestamp
        submittedFrameCount += 1

        let operationGeneration = cancellationGeneration
        let signal = AppleUpscaleOperationCancellationSignal()
        activeCancellationSignal = signal
        let outcome = await driver.process(
            frame,
            historyGeneration: historyGeneration,
            cancellation: signal
        )
        activeCancellationSignal = nil

        guard operationGeneration == cancellationGeneration, !signal.isCancelled else {
            releaseOwnedResources(frame: frame, lateOutcome: outcome)
            continuation.resume(returning: rejected(.operationCancelled))
            return
        }

        guard processingIdentity(for: outcome) == directProcessingIdentity else {
            releaseOwnedResources(frame: frame, lateOutcome: outcome)
            continuation.resume(returning: .failed(driverIdentityMismatchFailure))
            return
        }

        switch outcome {
        case .processed(let processedFrame):
            if frame.resourceLifetimeToken !== processedFrame.resourceLifetimeToken {
                frame.resourceLifetimeToken.release()
            }
            processedFrameCount += 1
        case .unavailable, .rejected, .failed:
            frame.resourceLifetimeToken.release()
        }
        continuation.resume(returning: outcome)
    }

    private func performReset(
        reason: AppleUpscaleResetReason,
        continuation: CheckedContinuation<Void, Never>
    ) async {
        let operationGeneration = cancellationGeneration
        let nextHistoryGeneration = historyGeneration + 1
        let signal = AppleUpscaleOperationCancellationSignal()
        activeCancellationSignal = signal
        await driver.reset(
            reason: reason,
            nextHistoryGeneration: nextHistoryGeneration,
            cancellation: signal
        )
        activeCancellationSignal = nil

        if operationGeneration == cancellationGeneration, !signal.isCancelled {
            historyGeneration = nextHistoryGeneration
        }
        continuation.resume()
    }

    private func validationRejection(
        for frame: AppleUpscaleFrame
    ) -> AppleUpscaleFIFOSubmitRejectionReason? {
        if let lastSequenceNumber, frame.sequenceNumber <= lastSequenceNumber {
            return .duplicateOrNonIncreasingSequence
        }
        if let lastPresentationTimestamp,
           CMTimeCompare(frame.presentationTimestamp, lastPresentationTimestamp) <= 0 {
            return .nonIncreasingPresentationTimestamp
        }
        guard frame.duration.isValid,
              frame.duration.isNumeric,
              CMTimeCompare(frame.duration, .zero) > 0 else {
            return .invalidDuration
        }
        return nil
    }

    private func rejected(
        _ reason: AppleUpscaleFIFOSubmitRejectionReason
    ) -> AppleUpscaleBackendOutcome<AppleUpscaleProcessedFrame> {
        guard let rejection = submitRejections[reason] else {
            preconditionFailure("Every submit rejection reason is constructed at initialization")
        }
        return .rejected(rejection)
    }

    private func processingIdentity(
        for outcome: AppleUpscaleBackendOutcome<AppleUpscaleProcessedFrame>
    ) -> AppleUpscaleProcessingIdentity {
        switch outcome {
        case .processed(let frame):
            return frame.processingIdentity
        case .unavailable(let unavailable):
            return unavailable.processingIdentity
        case .rejected(let rejected):
            return rejected.processingIdentity
        case .failed(let failed):
            return failed.processingIdentity
        }
    }

    private func rejectQueuedOperationsForCancellation() {
        let queuedOperations = queue
        queue.removeAll(keepingCapacity: true)
        for operation in queuedOperations {
            switch operation {
            case .submit(_, let frame, let continuation):
                frame.resourceLifetimeToken.release()
                continuation.resume(returning: rejected(.operationCancelled))
            case .reset(_, _, let continuation):
                continuation.resume()
            case .finish, .cancel:
                assertionFailure("A terminal fence must be unique")
            }
        }
    }

    private func releaseOwnedResources(
        frame: AppleUpscaleFrame,
        lateOutcome: AppleUpscaleBackendOutcome<AppleUpscaleProcessedFrame>
    ) {
        frame.resourceLifetimeToken.release()
        if case .processed(let processedFrame) = lateOutcome,
           processedFrame.resourceLifetimeToken !== frame.resourceLifetimeToken {
            processedFrame.resourceLifetimeToken.release()
        }
    }

    private func completeTerminal(cause: TerminalCause) {
        guard case .terminal = lifecycle else {
            terminalizationCount += 1
            let summary = AppleUpscaleSessionSummary(
                submittedFrameCount: submittedFrameCount,
                processedFrameCount: processedFrameCount,
                terminalizationCount: terminalizationCount
            )
            lifecycle = .terminal(cause: cause, summary: summary)

            let pendingFinishWaiters = finishWaiters
            finishWaiters.removeAll(keepingCapacity: false)
            for waiter in pendingFinishWaiters {
                waiter.resume(returning: summary)
            }

            let pendingCancelWaiters = cancelWaiters
            cancelWaiters.removeAll(keepingCapacity: false)
            for waiter in pendingCancelWaiters {
                waiter.resume()
            }
            return
        }
    }
}
