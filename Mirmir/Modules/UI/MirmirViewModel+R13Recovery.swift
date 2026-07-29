import AppKit
import Foundation
import UniformTypeIdentifiers

extension MirmirViewModel {
    func resumeRecoverableJob(id: String) {
        guard !jobIsRunning,
              !recoveryIsProbing,
              recoverableJobs.contains(where: { $0.id == id }),
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
                let recovered: R13ResolvedRecoverableUpscaleJob
                if let reauthorization {
                    recovered = try await recoveryEngine
                        .reauthorizeRecoverableJob(
                            id: id,
                            sourceURL: reauthorization.sourceURL,
                            outputDirectoryURL:
                                reauthorization.outputDirectoryURL
                        )
                } else {
                    recovered = try await recoveryEngine
                        .resolveRecoverableJob(id: id)
                }
                try Task.checkCancellation()
                guard recoveryGeneration == generation else { return }

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
                targetResolution = job.targetResolution
                codec = job.codec
                selectedMode = job.mode
                outputURL = job.outputURL
                outputSelectionError = nil
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

    private func chooseRecoverySource() -> URL? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.movie]
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
