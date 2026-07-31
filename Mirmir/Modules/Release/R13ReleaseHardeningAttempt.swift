import Foundation

actor R13ReleaseHardeningAttempt {
    nonisolated let identity: R13ReleaseIdentity
    nonisolated let processingSourceURL: URL

    private let sourceIdentity: R13RestartSourceIdentity
    private var sourceSnapshot: R13RetainedSourceSnapshot?
    private let sourceSnapshotter: any R13SourceSnapshotting
    private var plan: R13RestartAttemptPlan
    private let store: R13RestartJobStore
    private let sourceMeasurer: any R13RestartSourceMeasuring
    private let resourceGovernor: R13ResourceGovernor
    private let outputCapacityProbe: any R13AvailableCapacityProbing
    private let outputCapacityPlan: R13OutputVolumeCapacityPlan
    private let cacheReservationBytesPerFrame: UInt64
    private var resourceLease: R13ResourceLease?
    private var prepublicationReceipt: R13PrepublicationReceipt?
    private let faultGate: R13ReleaseFaultGate
    private let recorder: R13ReleaseHardeningDiagnosticRecorder

    init(
        identity: R13ReleaseIdentity,
        sourceIdentity: R13RestartSourceIdentity,
        sourceSnapshot: R13RetainedSourceSnapshot,
        sourceSnapshotter: any R13SourceSnapshotting,
        plan: R13RestartAttemptPlan,
        store: R13RestartJobStore,
        sourceMeasurer: any R13RestartSourceMeasuring,
        resourceGovernor: R13ResourceGovernor,
        outputCapacityProbe: any R13AvailableCapacityProbing,
        outputCapacityPlan: R13OutputVolumeCapacityPlan,
        cacheReservationBytesPerFrame: UInt64,
        resourceLease: R13ResourceLease,
        faultGate: R13ReleaseFaultGate,
        recorder: R13ReleaseHardeningDiagnosticRecorder
    ) {
        self.identity = identity
        processingSourceURL = sourceSnapshot.processingURL
        self.sourceIdentity = sourceIdentity
        self.sourceSnapshot = sourceSnapshot
        self.sourceSnapshotter = sourceSnapshotter
        self.plan = plan
        self.store = store
        self.sourceMeasurer = sourceMeasurer
        self.resourceGovernor = resourceGovernor
        self.outputCapacityProbe = outputCapacityProbe
        self.outputCapacityPlan = outputCapacityPlan
        self.cacheReservationBytesPerFrame = cacheReservationBytesPerFrame
        self.resourceLease = resourceLease
        self.faultGate = faultGate
        self.recorder = recorder
    }

    func beforeBackendStart() async throws {
        try await faultGate.check(.beforeBackendStart)
    }

    func disposition(
        forFrameAt index: Int
    ) throws -> R13RestartFrameDisposition {
        try plan.disposition(forFrameAt: index)
    }

    func recheckResources() async throws {
        guard let lease = resourceLease else {
            throw R13ReleaseHardeningError.resourceLeaseUnavailable(
                "released"
            )
        }
        let outcome = await resourceGovernor.recheck(lease)
        switch outcome {
        case .accepted:
            try outputCapacityPlan.verifyLiveRecheck(
                using: outputCapacityProbe
            )
            return
        case .rejected(let rejection):
            try await recorder.recordAdmission(.rejected(rejection))
            throw R13ReleaseHardeningError.resourceRejected(rejection)
        case .probeFailed(let probe):
            try await recorder.recordAdmission(.probeFailed(probe))
            throw R13ReleaseHardeningError.resourceProbeFailed(probe)
        case .leaseUnavailable(let identity):
            throw R13ReleaseHardeningError.resourceLeaseUnavailable(
                identity
            )
        }
    }

    func replayFrame(
        at frameIndex: Int
    ) async throws -> R13NV12Frame {
        try await replayFrameWithRoutingDecision(
            at: frameIndex
        ).frame
    }

    func replayFrameWithRoutingDecision(
        at frameIndex: Int
    ) async throws -> R13RestartCachedFrameReplay {
        let replay = try await store.loadCachedFrameReplay(
            at: frameIndex,
            using: plan
        )
        try await recorder.recordCacheReplay()
        return replay
    }

    func commit(
        frame: R13NV12Frame,
        routingDecision:
            R13ProductASHDecisionEvent? = nil,
        at frameIndex: Int
    ) async throws {
        plan = try await store.commitProcessedFrame(
            frame,
            routingDecision: routingDecision,
            at: frameIndex,
            using: plan
        )
        guard let lease = resourceLease else {
            throw R13ReleaseHardeningError.resourceLeaseUnavailable(
                "released"
            )
        }
        let consumption = await resourceGovernor.consumeDiskReservation(
            lease,
            bytes: cacheReservationBytesPerFrame
        )
        switch consumption {
        case .consumed:
            break
        case .exceedsReservation(let requestedBytes, let remainingBytes):
            throw R13ReleaseHardeningError.diskReservationExceeded(
                requestedBytes: requestedBytes,
                remainingBytes: remainingBytes
            )
        case .leaseUnavailable(let identity):
            throw R13ReleaseHardeningError.resourceLeaseUnavailable(
                identity
            )
        }
        try await recorder.recordCacheCommit()
    }

    func validateFrameCount(_ actual: Int) throws {
        guard actual == plan.totalFrameCount else {
            throw R13ReleaseHardeningError.outputFrameCountMismatch(
                expected: plan.totalFrameCount,
                actual: actual
            )
        }
    }

    func beforeOutputFinalize() async throws {
        try await faultGate.check(.beforeOutputFinalize)
        try outputCapacityPlan.verifyLiveRecheck(
            using: outputCapacityProbe
        )
    }

    func beforeMetadataReopen() async throws {
        try await faultGate.check(.beforeMetadataReopen)
    }

    func validateBeforePublish(
        outputURL: URL,
        metadata: [String: String]
    ) async throws {
        try identity.validateTimedMetadata(metadata)
        let observedSource = try sourceMeasurer.measureSource(
            at: processingSourceURL
        )
        guard observedSource == sourceIdentity else {
            throw R13RestartJobError.sourceDrift(
                expected: sourceIdentity,
                observed: observedSource
            )
        }
        let output = try sourceMeasurer.measureSource(at: outputURL)
        prepublicationReceipt = try await store.preparePrepublicationReceipt(
            using: plan,
            observedSource: observedSource,
            outputMediaSHA256: output.sha256,
            outputMediaByteCount: output.byteCount
        )
        try await recorder.recordOutputReopened(identity: identity)
    }

    func completePublishedOutput(
        at _: URL,
        publicationIdentity: MediaOutputPublicationIdentity?,
        mediaCleanupFailed: Bool = false
    ) async throws {
        guard let receipt = prepublicationReceipt,
              let publicationIdentity,
              publicationIdentity.sha256 == receipt.outputMediaSHA256,
              publicationIdentity.byteCount
                == receipt.outputMediaByteCount else {
            try? await recordPostpublicationDeferral(
                prepublicationReceipt == nil
                    ? .prepublicationReceiptUnavailable
                    : .publishedOutputIdentityMismatch
            )
            throw R13RestartJobError.prepublicationReceiptConflict
        }
        do {
            try await store.discard(jobID: plan.jobID)
            prepublicationReceipt = nil
        } catch {
            try? await recordPostpublicationDeferral(
                .cacheCleanupFailed
            )
        }
        try? await recordMediaCleanupDeferralIfNeeded(mediaCleanupFailed)
        try? await recorder.recordJobCompleted()
    }

    @discardableResult
    func releaseResources() async -> R13SourceSnapshotCleanupResult? {
        if let lease = resourceLease {
            resourceLease = nil
            let outcome = await resourceGovernor.release(lease)
            try? await recorder.recordRelease(outcome)
        }
        guard let snapshot = sourceSnapshot else { return nil }
        let cleanup = R13SourceSnapshotCleanup.discard(
            snapshot,
            using: sourceSnapshotter
        )
        if cleanup.snapshotRemoved {
            sourceSnapshot = nil
        } else {
            try? await recorder.recordSourceSnapshotCleanupFailed()
        }
        return cleanup
    }

    private func recordPostpublicationDeferral(
        _ reason: R13ReleaseDiagnosticReason
    ) async throws {
        try await recorder.recordPostpublicationMaintenanceDeferred(
            reason: reason
        )
    }

    private func recordMediaCleanupDeferralIfNeeded(
        _ failed: Bool
    ) async throws {
        guard failed else { return }
        try await recordPostpublicationDeferral(.mediaCleanupFailed)
    }
}

struct R13ReleaseFaultGate: Sendable {
    let injector: any R13FaultInjecting
    let recorder: R13ReleaseHardeningDiagnosticRecorder

    func check(_ point: R13FaultPoint) async throws {
        guard let fault = await injector.fault(at: point) else { return }
        try await recorder.recordFault(point: point)
        if fault == .cancellation {
            throw CancellationError()
        }
        throw R13ReleaseHardeningError.injectedFault(
            point: point,
            fault: fault
        )
    }
}
