import AppKit
import Foundation
import UniformTypeIdentifiers

extension MirmirViewModel {
    func resumeRecoverableJob(id: String) {
        guard recoverableJobResumeFailureReason(id: id) == nil,
              let recoveryEngine =
                upscalerEngine as? any R13RecoverableUpscalerEngine else {
            return
        }
        beginRecovery(
            id: id,
            recoveryEngine: recoveryEngine,
            reauthorization: nil
        )
    }

    func reauthorizeRecoverableJob(id: String) {
        guard !jobIsRunning,
              !recoveryIsProbing,
              !recoveryMutationIsInProgress,
              recoveryRequiresReauthorization(id: id),
              let summary = recoverableJobs.first(
                where: { $0.id == id }
              ),
              let recoveryEngine =
                upscalerEngine as? any R13RecoverableUpscalerEngine,
              let sourceURL = chooseRecoverySource(),
              let outputDirectoryURL = chooseRecoveryOutputDirectory(
                outputFilename: summary.outputFilename
              ) else {
            return
        }
        beginRecovery(
            id: id,
            recoveryEngine: recoveryEngine,
            reauthorization: R13RecoveryReauthorization(
                sourceURL: sourceURL,
                outputDirectoryURL: outputDirectoryURL
            )
        )
    }

    func loadRecoverableJobs() {
        guard !jobIsRunning,
              !recoveryIsProbing,
              !recoveryMutationIsInProgress,
              let recoveryEngine =
                upscalerEngine as? any R13RecoverableUpscalerEngine else {
            return
        }
        let generation = nextRecoveryGeneration()
        recoveryTask?.cancel()
        recoveryTask = Task { [weak self] in
            do {
                let catalog = try await recoveryEngine.recoverableJobs()
                try Task.checkCancellation()
                guard let self,
                      self.recoveryGeneration == generation else {
                    return
                }
                self.recoverableJobs = catalog.jobs
                self.recoveryReauthorizationRequiredIDs.formIntersection(
                    Set(catalog.jobs.map(\.id))
                )
                self.recoveryRejectedEntryCount =
                    catalog.rejectedEntryCount
                self.recoveryError = nil
                if catalog.rejectedEntryCount > 0 {
                    let countField = try? MirmirDiagnosticField(
                        key: "rejected_entry_count",
                        value: .unsignedInteger(
                            UInt64(max(catalog.rejectedEntryCount, 0))
                        )
                    )
                    self.diagnosticRecorder.enqueue(
                        severity: .warning,
                        subsystem: "recovery",
                        operation: "load_recoverable_jobs",
                        code: "recovery_catalog_entries_rejected",
                        additionalFields: countField.map { [$0] } ?? []
                    )
                }
            } catch {
                guard !Task.isCancelled,
                      let self,
                      self.recoveryGeneration == generation else {
                    return
                }
                self.recoveryError = self.userFacingJobError(error)
                self.diagnosticRecorder.enqueue(
                    severity: .error,
                    subsystem: "recovery",
                    operation: "load_recoverable_jobs",
                    code: "recovery_catalog_load_failed",
                    error: error
                )
            }
        }
    }

    func cancelRecoveryProbe() {
        if recoveryIsProbing {
            Task { [diagnosticRecorder] in
                diagnosticRecorder.enqueue(
                    severity: .notice,
                    subsystem: "recovery",
                    operation: "resolve_recoverable_job",
                    code: "recovery_probe_cancel_requested"
                )
            }
        }
        recoveryGeneration &+= 1
        recoveryTask?.cancel()
        recoveryTask = nil
        recoveryIsProbing = false
        if case .probing = state {
            state = sourceProfile == nil ? .idle : .ready
        }
    }

    func discardRecoverableJob(id: String) {
        beginDiscardingRecoverableJobs(ids: [id])
    }

    func discardAllRecoverableJobs() {
        if recoveryRejectedEntryCount > 0 {
            beginDiscardingAllRecoveryData()
        } else {
            beginDiscardingRecoverableJobs(
                ids: recoverableJobs.map(\.id)
            )
        }
    }

    private func beginDiscardingAllRecoveryData() {
        guard !recoverableJobs.isEmpty
                || recoveryRejectedEntryCount > 0,
              !jobIsRunning,
              !recoveryIsProbing,
              !recoveryMutationIsInProgress,
              let recoveryEngine =
                upscalerEngine as? any R13RecoverableUpscalerEngine else {
            return
        }

        cancelRecoveryProbe()
        recoveryMutationTask?.cancel()
        recoveryMutationIsInProgress = true
        recoveryError = nil
        let correlationID = UUID()
        recoveryMutationTask = Task { [weak self] in
            guard let self else { return }
            diagnosticRecorder.enqueue(
                severity: .notice,
                subsystem: "recovery",
                operation: "discard_all_recoverable_jobs",
                code: "recovery_all_jobs_discard_requested",
                correlationID: correlationID
            )
            do {
                try await recoveryEngine.discardAllRecoverableJobs()
                try Task.checkCancellation()
                recoverableJobs = []
                recoveryReauthorizationRequiredIDs = []
                recoveryRejectedEntryCount = 0
                recoveryError = nil
                diagnosticRecorder.enqueue(
                    severity: .notice,
                    subsystem: "recovery",
                    operation: "discard_all_recoverable_jobs",
                    code: "recovery_all_jobs_discarded",
                    correlationID: correlationID
                )
            } catch is CancellationError {
                diagnosticRecorder.enqueue(
                    severity: .notice,
                    subsystem: "recovery",
                    operation: "discard_all_recoverable_jobs",
                    code: "recovery_all_jobs_discard_cancelled",
                    correlationID: correlationID
                )
            } catch {
                recoveryError =
                    "Mirmir could not discard all interrupted jobs. "
                    + userFacingJobError(error)
                diagnosticRecorder.enqueue(
                    severity: .error,
                    subsystem: "recovery",
                    operation: "discard_all_recoverable_jobs",
                    code: "recovery_all_jobs_discard_failed",
                    correlationID: correlationID,
                    error: error
                )
            }
            recoveryMutationIsInProgress = false
            recoveryMutationTask = nil
        }
    }

    private func beginDiscardingRecoverableJobs(ids: [String]) {
        let orderedIDs = Array(Set(ids)).sorted()
        guard !orderedIDs.isEmpty,
              !jobIsRunning,
              !recoveryIsProbing,
              !recoveryMutationIsInProgress,
              let recoveryEngine =
                upscalerEngine as? any R13RecoverableUpscalerEngine else {
            return
        }

        cancelRecoveryProbe()
        recoveryMutationTask?.cancel()
        recoveryMutationIsInProgress = true
        recoveryError = nil
        recoveryMutationTask = Task { [weak self] in
            guard let self else { return }
            var failures: [(id: String, error: Error)] = []
            for id in orderedIDs {
                if Task.isCancelled { break }
                let correlationID = UUID(uuidString: id) ?? UUID()
                diagnosticRecorder.enqueue(
                    severity: .notice,
                    subsystem: "recovery",
                    operation: "discard_recoverable_job",
                    code: "recovery_job_discard_requested",
                    correlationID: correlationID
                )
                do {
                    try await recoveryEngine.discardRecoverableJob(id: id)
                    recoverableJobs.removeAll { $0.id == id }
                    recoveryReauthorizationRequiredIDs.remove(id)
                    diagnosticRecorder.enqueue(
                        severity: .notice,
                        subsystem: "recovery",
                        operation: "discard_recoverable_job",
                        code: "recovery_job_discarded",
                        correlationID: correlationID
                    )
                } catch {
                    failures.append((id, error))
                    diagnosticRecorder.enqueue(
                        severity: .error,
                        subsystem: "recovery",
                        operation: "discard_recoverable_job",
                        code: "recovery_job_discard_failed",
                        correlationID: correlationID,
                        error: error
                    )
                }
            }

            recoveryMutationIsInProgress = false
            recoveryMutationTask = nil
            if failures.isEmpty {
                recoveryError = nil
            } else {
                let count = failures.count
                recoveryError =
                    "Mirmir could not discard \(count) interrupted "
                    + "job\(count == 1 ? "" : "s"). "
                    + userFacingJobError(failures[0].error)
            }
        }
    }

    private func beginRecovery(
        id: String,
        recoveryEngine: any R13RecoverableUpscalerEngine,
        reauthorization: R13RecoveryReauthorization?
    ) {
        let diagnosticCorrelationID =
            UUID(uuidString: id) ?? UUID()
        let generation = nextRecoveryGeneration()
        let previousState = state
        recoveryTask?.cancel()
        resetPreview()
        retryableFailedJob = nil
        recoveryIsProbing = true
        recoveryError = nil
        state = .probing
        recoveryTask = Task { [weak self] in
            guard let self else { return }
            diagnosticRecorder.enqueue(
                severity: .info,
                subsystem: "recovery",
                operation: "resolve_recoverable_job",
                code: "recovery_probe_started",
                correlationID: diagnosticCorrelationID
            )
            do {
                let recovered = try await resolveRecoverableJob(
                    id: id,
                    recoveryEngine: recoveryEngine,
                    reauthorization: reauthorization
                )
                try Task.checkCancellation()
                guard recoveryGeneration == generation else { return }
                recoveryReauthorizationRequiredIDs.remove(id)

                let job = recovered.job
                let source = try await mediaPipeline.probe(
                    url: job.inputURL
                )
                try Task.checkCancellation()
                guard recoveryGeneration == generation else { return }
                guard Self.targets(for: source.resolution)
                    .contains(job.targetResolution) else {
                    throw UpscalerEngineError.unsupportedSourceResolution(
                        source.resolution
                    )
                }

                sourceProfile = source
                restoreCurrentConfiguration(from: job)
                let handle = try recoveryEngine.submitRecoveredJob(
                    recovered
                )
                guard recoveryGeneration == generation,
                      !Task.isCancelled else {
                    handle.cancel()
                    throw CancellationError()
                }
                recoveryIsProbing = false
                recoveryError = nil
                diagnosticRecorder.enqueue(
                    severity: .info,
                    subsystem: "recovery",
                    operation: "resolve_recoverable_job",
                    code: "recovery_job_resolved",
                    correlationID: diagnosticCorrelationID,
                    job: job,
                    source: source
                )
                observeSubmittedJob(
                    job: job,
                    source: source,
                    handle: handle
                )
            } catch is CancellationError {
                guard recoveryGeneration == generation else { return }
                recoveryIsProbing = false
                state = previousState
                diagnosticRecorder.enqueue(
                    severity: .notice,
                    subsystem: "recovery",
                    operation: "resolve_recoverable_job",
                    code: "recovery_probe_cancelled",
                    correlationID: diagnosticCorrelationID
                )
            } catch {
                guard recoveryGeneration == generation else { return }
                recoveryIsProbing = false
                recordRecoveryAuthorizationFailure(error, id: id)
                recoveryError = userFacingJobError(error)
                state = .failed(
                    "Mirmir could not reopen the interrupted job. "
                        + userFacingJobError(error)
                )
                diagnosticRecorder.enqueue(
                    severity: .error,
                    subsystem: "recovery",
                    operation: "resolve_recoverable_job",
                    code: "recovery_probe_failed",
                    correlationID: diagnosticCorrelationID,
                    error: error
                )
            }
        }
    }

    private func nextRecoveryGeneration() -> Int {
        recoveryGeneration &+= 1
        return recoveryGeneration
    }

    private func resolveRecoverableJob(
        id: String,
        recoveryEngine: any R13RecoverableUpscalerEngine,
        reauthorization: R13RecoveryReauthorization?
    ) async throws -> R13ResolvedRecoverableUpscaleJob {
        guard let reauthorization else {
            return try await recoveryEngine.resolveRecoverableJob(id: id)
        }
        return try await recoveryEngine.reauthorizeRecoverableJob(
            id: id,
            sourceURL: reauthorization.sourceURL,
            outputDirectoryURL: reauthorization.outputDirectoryURL
        )
    }

    private static func isRecoveryAuthorizationError(
        _ error: Error
    ) -> Bool {
        guard let restartError = error as? R13RestartJobError else {
            return false
        }
        switch restartError {
        case .reauthorizationRequired, .bookmarkResolutionFailed,
             .securityScopeDenied:
            return true
        default:
            return false
        }
    }

    private func recordRecoveryAuthorizationFailure(
        _ error: Error,
        id: String
    ) {
        guard Self.isRecoveryAuthorizationError(error) else { return }
        recoveryReauthorizationRequiredIDs.insert(id)
    }

    private func chooseRecoverySource() -> URL? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.title = "Reauthorize interrupted upscale source"
        panel.prompt = "Select Source"
        guard panel.runModal() == .OK,
              let url = panel.url,
              Self.supportsVideoFile(url) else {
            return nil
        }
        return url
    }

    private func chooseRecoveryOutputDirectory(
        outputFilename: String
    ) -> URL? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.title = "Reauthorize output folder for \(outputFilename)"
        panel.prompt = "Select Folder"
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}

private struct R13RecoveryReauthorization {
    let sourceURL: URL
    let outputDirectoryURL: URL
}
