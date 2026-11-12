import AVFoundation
import CoreMedia
import CoreVideo
import CryptoKit
import Darwin
import Foundation

enum WorkflowApplicationControllerErrorV4: Error, LocalizedError, Sendable {
    case noDispatchableJob
    case dispatchCapacityExhausted
    case deterministicBackendRequired(UpscaleBackendID)
    case backendUnavailable(UpscaleBackendID, String)
    case preparedBackendMismatch(UpscaleBackendID)
    case activationBlocked(WorkflowApplicationActivationFailureV4)
    case preparedPlanChanged(WorkflowJobID)
    case noActiveJob
    case pauseNotAllowed(WorkflowJobLifecycle)
    case cancellationNotAllowed(WorkflowJobLifecycle)
    case heartbeatFailed(String)
    case workingSegmentConflict(String)
    case checkpointMissing(WorkflowJobID)
    case invalidAssembledOutput(String)

    var errorDescription: String? {
        switch self {
        case .noDispatchableJob:
            "The durable queue has no dispatchable job."
        case .dispatchCapacityExhausted:
            "The durable processing slot is already owned by another worker."
        case .deterministicBackendRequired(let backendID):
            "Durable v4 execution requires a prepared deterministic backend; got \(backendID.rawValue)."
        case .backendUnavailable(let backendID, let reason):
            "The durable job cannot use \(backendID.rawValue): \(reason)"
        case .preparedBackendMismatch(let backendID):
            "The prepared backend changed identity from \(backendID.rawValue)."
        case .activationBlocked(let failure):
            "The durable job was contained because its bookmarks or request record could not be activated: \(String(describing: failure))."
        case .preparedPlanChanged(let jobID):
            "The source, runtime, output, or plan binding changed before \(jobID) could run."
        case .noActiveJob:
            "There is no active durable job."
        case .pauseNotAllowed(let lifecycle):
            "A pause request is not valid while the durable job is \(lifecycle.rawValue)."
        case .cancellationNotAllowed(let lifecycle):
            "Cancellation is no longer safe while the durable job is \(lifecycle.rawValue)."
        case .heartbeatFailed(let reason):
            "The durable worker lease could not be renewed: \(reason)"
        case .workingSegmentConflict(let path):
            "A pre-existing checkpoint segment must be reconciled before processing: \(path)"
        case .checkpointMissing(let jobID):
            "The paused durable job \(jobID) has no compatible checkpoint."
        case .invalidAssembledOutput(let reason):
            "The assembled durable output is invalid: \(reason)"
        }
    }
}


@available(macOS 15.4, *)
struct RecoveryQualificationCodeDirectoryV4: Sendable {
    let architecture: String
    let sha256: String

    fileprivate var json: [String: Any] {
        ["architecture": architecture, "sha256": sha256]
    }
}

@available(macOS 15.4, *)
struct RecoveryQualificationPackageIdentityV4: Sendable {
    let schemaVersion: String
    let buildConfiguration: String
    let applicationArchiveSHA256: String
    let applicationPayloadIdentitySHA256: String
    let applicationInfoPlistSHA256: String
    let applicationExecutableSHA256: String
    let codeDirectories: [RecoveryQualificationCodeDirectoryV4]
    let codeDirectorySetSHA256: String
    let designatedRequirementSHA256: String
    let releaseConfigurationSHA256: String
    let attestationSHA256: String
    let sourceCommit: String
    let sourceTreeIdentitySHA256: String
    let runtimeManifestSHA256: String
    let runtimeManifestFileSHA256: String
    let runtimeArtifactSetSHA256: String
    let runtimeSourceRevision: String
    let bundleIdentifier: String
    let productVersion: String
    let productBuild: String

    fileprivate func validate() throws {
        guard schemaVersion
                == "mirmir-v4-packaged-candidate-identity-v1",
              buildConfiguration == "Release",
              codeDirectories.map(\.architecture) == ["arm64", "x86_64"]
        else {
            throw RecoveryQualificationProducerV4.CaptureFailure.assertion(
                "Packaged recovery identity header or architectures differ."
            )
        }
        for row in codeDirectories {
            guard !row.architecture.isEmpty else {
                throw RecoveryQualificationProducerV4.CaptureFailure.assertion(
                    "Packaged recovery CodeDirectory architecture is empty."
                )
            }
            try validateHex(
                row.sha256,
                lengths: [64],
                label: "CodeDirectory"
            )
        }
        for (label, value, lengths) in [
            ("applicationArchiveSHA256", applicationArchiveSHA256, [64]),
            (
                "applicationPayloadIdentitySHA256",
                applicationPayloadIdentitySHA256,
                [64]
            ),
            ("applicationInfoPlistSHA256", applicationInfoPlistSHA256, [64]),
            ("applicationExecutableSHA256", applicationExecutableSHA256, [64]),
            ("codeDirectorySetSHA256", codeDirectorySetSHA256, [64]),
            ("designatedRequirementSHA256", designatedRequirementSHA256, [64]),
            ("releaseConfigurationSHA256", releaseConfigurationSHA256, [64]),
            ("attestationSHA256", attestationSHA256, [64]),
            ("sourceCommit", sourceCommit, [40]),
            ("sourceTreeIdentitySHA256", sourceTreeIdentitySHA256, [64]),
            ("runtimeManifestSHA256", runtimeManifestSHA256, [64]),
            ("runtimeManifestFileSHA256", runtimeManifestFileSHA256, [64]),
            ("runtimeArtifactSetSHA256", runtimeArtifactSetSHA256, [64]),
            ("runtimeSourceRevision", runtimeSourceRevision, [40, 64]),
        ] {
            try validateHex(value, lengths: Set(lengths), label: label)
        }
        guard !bundleIdentifier.isEmpty,
              !productVersion.isEmpty,
              !productBuild.isEmpty else {
            throw RecoveryQualificationProducerV4.CaptureFailure.assertion(
                "Packaged recovery bundle identity is empty."
            )
        }
    }

    fileprivate var json: [String: Any] {
        [
            "schemaVersion": schemaVersion,
            "buildConfiguration": buildConfiguration,
            "applicationArchiveSHA256": applicationArchiveSHA256,
            "applicationPayloadIdentitySHA256":
                applicationPayloadIdentitySHA256,
            "applicationInfoPlistSHA256": applicationInfoPlistSHA256,
            "applicationExecutableSHA256": applicationExecutableSHA256,
            "codeDirectories": codeDirectories.map(\.json),
            "codeDirectorySetSHA256": codeDirectorySetSHA256,
            "designatedRequirementSHA256": designatedRequirementSHA256,
            "releaseConfigurationSHA256": releaseConfigurationSHA256,
            "attestationSHA256": attestationSHA256,
            "sourceCommit": sourceCommit,
            "sourceTreeIdentitySHA256": sourceTreeIdentitySHA256,
            "runtimeManifestSHA256": runtimeManifestSHA256,
            "runtimeManifestFileSHA256": runtimeManifestFileSHA256,
            "runtimeArtifactSetSHA256": runtimeArtifactSetSHA256,
            "runtimeSourceRevision": runtimeSourceRevision,
            "bundleIdentifier": bundleIdentifier,
            "productVersion": productVersion,
            "productBuild": productBuild,
        ]
    }

    private func validateHex(
        _ value: String,
        lengths: Set<Int>,
        label: String
    ) throws {
        guard lengths.contains(value.utf8.count),
              value == value.lowercased(),
              value.allSatisfy({ $0.isHexDigit }) else {
            throw RecoveryQualificationProducerV4.CaptureFailure.assertion(
                "Packaged recovery \(label) is not lowercase hexadecimal."
            )
        }
    }
}

@available(macOS 15.4, *)
struct RecoveryQualificationPackagedExecutionV4: Sendable {
    let requestID: String
    let requestSHA256: String
    let nonceSHA256: String
    let observerSourceSHA256: String
    let packageIdentity: RecoveryQualificationPackageIdentityV4

    fileprivate func validate(producerSourceSHA256: String) throws {
        guard let requestUUID = UUID(uuidString: requestID),
              requestUUID.uuidString.lowercased() == requestID else {
            throw RecoveryQualificationProducerV4.CaptureFailure.assertion(
                "Packaged recovery request ID is not a canonical UUID."
            )
        }
        for (label, value, lengths) in [
            ("requestSHA256", requestSHA256, [64]),
            ("nonceSHA256", nonceSHA256, [64]),
            ("observerSourceSHA256", observerSourceSHA256, [64]),
            ("producerSourceSHA256", producerSourceSHA256, [64]),
        ] {
            guard lengths.contains(value.utf8.count),
                  value == value.lowercased(),
                  value.allSatisfy({ $0.isHexDigit }) else {
                throw RecoveryQualificationProducerV4.CaptureFailure.assertion(
                    "Packaged recovery \(label) is not lowercase hexadecimal."
                )
            }
        }
        try packageIdentity.validate()
    }

    fileprivate func json(producerSourceSHA256: String) -> [String: Any] {
        [
            "schemaVersion":
                "mirmir-v4-recovery-archived-execution-v1",
            "kind": "archived_application_executable",
            "applicationArchiveExecuted": true,
            "requestID": requestID,
            "requestSHA256": requestSHA256,
            "nonceSHA256": nonceSHA256,
            "observerSourceSHA256": observerSourceSHA256,
            "producerSourceSHA256": producerSourceSHA256,
            "applicationArchiveSHA256":
                packageIdentity.applicationArchiveSHA256,
            "applicationPayloadIdentitySHA256":
                packageIdentity.applicationPayloadIdentitySHA256,
            "applicationExecutableSHA256":
                packageIdentity.applicationExecutableSHA256,
            "sourceCommit": packageIdentity.sourceCommit,
            "sourceTreeIdentitySHA256":
                packageIdentity.sourceTreeIdentitySHA256,
            "runtimeManifestSHA256":
                packageIdentity.runtimeManifestSHA256,
            "runtimeManifestFileSHA256":
                packageIdentity.runtimeManifestFileSHA256,
            "runtimeArtifactSetSHA256":
                packageIdentity.runtimeArtifactSetSHA256,
            "runtimeSourceRevision": packageIdentity.runtimeSourceRevision,
        ]
    }
}

@available(macOS 15.4, *)
struct RecoveryQualificationCaptureRequestV4: Sendable {
    let captureRootURL: URL
    let contractURL: URL
    let contractSHA256: String
    let producerSourceSHA256: String
    let execution: RecoveryQualificationPackagedExecutionV4
}

@available(macOS 15.4, *)
final class RecoveryQualificationProducerV4 {
    private static let injectedEnvironment: [String: String] = [:]

    private struct LockedContract: Decodable {
        let schemaVersion: String
        let buildConfiguration: String
        let capture: LockedCaptureTools
        let crossProcessCaptureCount: Int
        let scenarios: [LockedScenario]
    }

    private struct LockedCaptureTools: Decodable {
        let producerSourceSHA256: String
    }

    fileprivate struct LockedScenario: Decodable, Equatable {
        let id: String
        let coverageID: String
        let injectionPoint: String
        let outcome: String
        let containedFailureCode: String?
        let evidenceKind: String
    }

    fileprivate struct ArtifactDescriptor {
        let path: String
        let byteCount: Int
        let sha256: String

        var json: [String: Any] {
            ["path": path, "byteCount": byteCount, "sha256": sha256]
        }
    }

    fileprivate struct TranscriptEvent {
        let operation: String
        let durableStateSHA256: String

        func json(sequence: Int) -> [String: Any] {
            [
                "sequence": sequence,
                "operation": operation,
                "durableStateSHA256": durableStateSHA256
            ]
        }
    }

    fileprivate enum ScenarioCausalOutput {
        case derivation(
            referenceState: URL,
            recoveredState: URL,
            reference: Data,
            resumed: Data
        )
        case media(
            referenceState: URL,
            recoveredState: URL,
            reference: URL,
            resumed: URL
        )
        case contained(recoveredState: URL)

        var recoveredState: URL {
            switch self {
            case .derivation(_, let recoveredState, _, _),
                 .media(_, let recoveredState, _, _),
                 .contained(let recoveredState):
                recoveredState
            }
        }

        var referenceState: URL? {
            switch self {
            case .derivation(let referenceState, _, _, _),
                 .media(let referenceState, _, _, _):
                referenceState
            case .contained:
                nil
            }
        }
    }

    fileprivate struct ScenarioExecution {
        let causalOutput: ScenarioCausalOutput
        let afterFaultStateSHA256: String
        let reopenedStateSHA256: String
    }

    fileprivate enum CaptureFailure: Error, LocalizedError {
        case assertion(String)
        case injected(String)

        var errorDescription: String? {
            switch self {
            case .assertion(let message): message
            case .injected(let point):
                "Injected process termination at \(point)."
            }
        }
    }

    private static let expectedScenarios = [
        LockedScenario(
            id: "append-only-event-boundary",
            coverageID: "append_only_event_boundary",
            injectionPoint: "after_append_file_sync_before_return",
            outcome: "identical_resumed_output",
            containedFailureCode: nil,
            evidenceKind: "durable_state_derivation"
        ),
        LockedScenario(
            id: "snapshot-publish-boundary",
            coverageID: "snapshot_publish_boundary",
            injectionPoint: "after_snapshot_rename_before_parent_sync",
            outcome: "identical_resumed_output",
            containedFailureCode: nil,
            evidenceKind: "durable_state_derivation"
        ),
        LockedScenario(
            id: "bookmark-resolution-and-toctou",
            coverageID: "bookmark_resolution_and_toctou",
            injectionPoint: "after_bookmark_resolution_before_revalidation",
            outcome: "explicit_contained_failure",
            containedFailureCode: "bookmark_toctou_contained",
            evidenceKind: "contained_state_derivation"
        ),
        LockedScenario(
            id: "segment-commit-boundary",
            coverageID: "segment_commit_boundary",
            injectionPoint:
                "after_segment_artifact_publish_before_checkpoint_commit",
            outcome: "identical_resumed_output",
            containedFailureCode: nil,
            evidenceKind: "durable_state_derivation"
        ),
        LockedScenario(
            id: "checkpoint-publish-boundary",
            coverageID: "checkpoint_publish_boundary",
            injectionPoint:
                "after_checkpoint_archive_publish_before_head_publish",
            outcome: "identical_resumed_output",
            containedFailureCode: nil,
            evidenceKind: "durable_state_derivation"
        ),
        LockedScenario(
            id: "prepared-decision-boundary",
            coverageID: "prepared_decision_boundary",
            injectionPoint:
                "after_prepared_recovery_decision_before_lifecycle_transition",
            outcome: "identical_resumed_output",
            containedFailureCode: nil,
            evidenceKind: "durable_state_derivation"
        ),
        LockedScenario(
            id: "final-assembly-boundary",
            coverageID: "final_assembly_boundary",
            injectionPoint: "after_segment_assembly_before_final_mux",
            outcome: "identical_resumed_output",
            containedFailureCode: nil,
            evidenceKind: "scenario_media_output"
        ),
        LockedScenario(
            id: "atomic-output-publish-boundary",
            coverageID: "atomic_output_publish_boundary",
            injectionPoint:
                "after_atomic_output_rename_before_completion_event",
            outcome: "identical_resumed_output",
            containedFailureCode: nil,
            evidenceKind: "scenario_media_output"
        ),
        LockedScenario(
            id: "pause-resume",
            coverageID: "pause_resume",
            injectionPoint: "after_committed_pause_boundary",
            outcome: "identical_resumed_output",
            containedFailureCode: nil,
            evidenceKind: "scenario_media_output"
        ),
        LockedScenario(
            id: "forced-termination-restart",
            coverageID: "forced_termination_restart",
            injectionPoint: "after_lease_persistence_before_process_death",
            outcome: "identical_resumed_output",
            containedFailureCode: nil,
            evidenceKind: "durable_state_derivation"
        ),
        LockedScenario(
            id: "disk-full",
            coverageID: "disk_full",
            injectionPoint: "journal_append_enospc_before_write",
            outcome: "explicit_contained_failure",
            containedFailureCode: "disk_full_contained",
            evidenceKind: "contained_state_derivation"
        ),
        LockedScenario(
            id: "corrupt-journal",
            coverageID: "corrupt_journal",
            injectionPoint: "journal_frame_payload_bit_flip",
            outcome: "explicit_contained_failure",
            containedFailureCode: "corrupt_journal_contained",
            evidenceKind: "contained_state_derivation"
        ),
        LockedScenario(
            id: "corrupt-checkpoint",
            coverageID: "corrupt_checkpoint",
            injectionPoint: "temporal_checkpoint_payload_bit_flip",
            outcome: "explicit_contained_failure",
            containedFailureCode: "corrupt_checkpoint_contained",
            evidenceKind: "contained_state_derivation"
        ),
        LockedScenario(
            id: "orphan-partial-reconciliation",
            coverageID: "orphan_partial_reconciliation",
            injectionPoint: "owned_partial_present_at_launch",
            outcome: "identical_resumed_output",
            containedFailureCode: nil,
            evidenceKind: "durable_state_derivation"
        ),
        LockedScenario(
            id: "unowned-artifact-rejection",
            coverageID: "unowned_artifact_rejection",
            injectionPoint: "unowned_partial_present_at_launch",
            outcome: "explicit_contained_failure",
            containedFailureCode: "unowned_artifact_rejected",
            evidenceKind: "contained_state_derivation"
        ),
    ]

    func capture(
        _ request: RecoveryQualificationCaptureRequestV4
    ) async throws -> URL {
        let captureRoot = request.captureRootURL.standardizedFileURL
        let contractURL = request.contractURL.standardizedFileURL
        let contractData = try Data(contentsOf: contractURL)
        guard sha256(contractData) == request.contractSHA256 else {
            throw CaptureFailure.assertion(
                "Recovery contract identity differs."
            )
        }
        let contract = try JSONDecoder().decode(
            LockedContract.self,
            from: contractData
        )
        guard contract.schemaVersion
                == "mirmir-v4-recovery-qualification-contract-v2",
              contract.buildConfiguration == "Release",
              contract.crossProcessCaptureCount == 2,
              contract.capture.producerSourceSHA256
                == request.producerSourceSHA256,
              contract.scenarios == Self.expectedScenarios else {
            throw CaptureFailure.assertion(
                "Recovery contract is not the exact locked scenario matrix."
            )
        }
        try request.execution.validate(
            producerSourceSHA256: request.producerSourceSHA256
        )
        guard !FileManager.default.fileExists(atPath: captureRoot.path),
              FileManager.default.fileExists(
                atPath: captureRoot.deletingLastPathComponent().path
              ) else {
            throw CaptureFailure.assertion(
                "Recovery capture output must be a new child directory."
            )
        }
        try FileManager.default.createDirectory(
            at: captureRoot,
            withIntermediateDirectories: false
        )

        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "mirmir-v4-recovery-capture-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: workspace) }

        let sourceURL = workspace.appendingPathComponent("source.mov")
        try await writeMovie(
            to: sourceURL,
            colors: [
                (12, 36, 84),
                (48, 96, 144),
                (180, 72, 24),
                (32, 180, 96),
            ]
        )
        var captureScenarios: [[String: Any]] = []
        for scenario in contract.scenarios {
            let stateRoot = workspace.appendingPathComponent(
                "state-\(scenario.id)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: stateRoot,
                withIntermediateDirectories: true
            )
            let before = try durableStateSHA256(stateRoot)
            let execution = try await exerciseFault(
                scenario,
                stateRoot: stateRoot,
                sourceMovie: sourceURL
            )
            let events = [
                TranscriptEvent(
                    operation: "prepare_durable_state",
                    durableStateSHA256: before
                ),
                TranscriptEvent(
                    operation: "inject_fault",
                    durableStateSHA256: execution.afterFaultStateSHA256
                ),
                TranscriptEvent(
                    operation: "reopen_durable_state",
                    durableStateSHA256: execution.reopenedStateSHA256
                ),
            ]
            captureScenarios.append(try await writeScenarioEvidence(
                scenario,
                captureRoot: captureRoot,
                reopenedStateSHA256: execution.reopenedStateSHA256,
                causalOutput: execution.causalOutput,
                events: events
            ))
        }

        try writeJSON(
            [
                "schemaVersion": "mirmir-v4-recovery-environment-v2",
                "buildConfiguration": "Release",
                "executionMode": "archived_application_executable",
                "hardwareModel": hardwareModel(),
                "macOSVersion":
                    ProcessInfo.processInfo.operatingSystemVersionString,
            ],
            to: captureRoot.appendingPathComponent("environment.json")
        )
        try writeJSON(
            [
                "schemaVersion": "mirmir-v4-recovery-capture-v2",
                "contractSHA256": request.contractSHA256,
                "producerSourceSHA256": request.producerSourceSHA256,
                "evidenceRequestSHA256":
                    request.execution.requestSHA256,
                "evidenceNonceSHA256": request.execution.nonceSHA256,
                "observerSourceSHA256":
                    request.execution.observerSourceSHA256,
                "packagedCandidateIdentity":
                    request.execution.packageIdentity.json,
                "sourceCommit":
                    request.execution.packageIdentity.sourceCommit,
                "sourceTreeIdentitySHA256":
                    request.execution.packageIdentity
                        .sourceTreeIdentitySHA256,
                "buildConfiguration": "Release",
                "execution": request.execution.json(
                    producerSourceSHA256: request.producerSourceSHA256
                ),
                "scenarios": captureScenarios,
            ],
            to: captureRoot.appendingPathComponent("capture.json")
        )
        return captureRoot.appendingPathComponent("capture.json")
    }
}

private extension RecoveryQualificationProducerV4 {
    func runSegmentedCoordinator(
        sourceURL: URL,
        rootURL: URL,
        pauseAfterClaim: Bool
    ) async throws -> URL {
        let storeURL = rootURL.appendingPathComponent("store", isDirectory: true)
        let outputURL = rootURL.appendingPathComponent("output.mov")
        try FileManager.default.createDirectory(
            at: storeURL,
            withIntermediateDirectories: true
        )
        let resolver = RecoveryCaptureBookmarkResolver()
        let queue = try WorkflowApplicationQueueV4(
            trustedRootURL: storeURL,
            workerID: try WorkflowWorkerIDV4(
                "recovery-capture-worker-\(UUID().uuidString.lowercased())"
            ),
            resolver: resolver
        )
        let coordinator = WorkflowApplicationCoordinatorV4(
            queue: queue,
            engine: WorkflowDeterministicApplicationEngineV4(
                videoProbe: VideoProbe(),
                backendCatalog: .live(),
                runtimeEnvironment: .current()
            ),
            maximumInputFramesPerBoundary: 1
        )
        _ = try await coordinator.launch()
        let request = UpscaleRequest(
            inputURL: sourceURL,
            outputURL: outputURL,
            backendID: .mirmirDeterministicCPU,
            targetWidth: 32,
            targetHeight: 32,
            outputCodec: .h264,
            preserveAudio: false,
            overwriteExistingFile: false
        )
        if !pauseAfterClaim {
            let outcome = try await coordinator.submit(
                request: request,
                progress: { _ in },
                snapshot: { _ in }
            )
            guard case .completed = outcome else {
                throw CaptureFailure.assertion(
                    "Uninterrupted segmented execution did not complete."
                )
            }
            return outputURL
        }

        let latch = RecoveryCaptureLifecycleLatch()
        let task = Task {
            try await coordinator.submit(
                request: request,
                progress: { _ in },
                snapshot: { snapshot in
                    if snapshot.items.contains(where: {
                        $0.lifecycle == .probing || $0.lifecycle == .planned
                    }) {
                        Task { await latch.signal() }
                    }
                }
            )
        }
        await latch.wait()
        try await coordinator.requestPause()
        let paused = try await task.value
        guard case .paused(let jobID, _) = paused else {
            throw CaptureFailure.assertion(
                "Segmented execution did not stop at a committed pause boundary."
            )
        }
        let resumed = try await coordinator.resume(
            jobID: jobID,
            progress: { _ in },
            snapshot: { _ in }
        )
        guard case .completed = resumed else {
            throw CaptureFailure.assertion(
                "Segmented execution did not complete after checkpoint restore."
            )
        }
        return outputURL
    }

    func exerciseFault(
        _ scenario: LockedScenario,
        stateRoot: URL,
        sourceMovie: URL
    ) async throws -> ScenarioExecution {
        let referenceRoot = stateRoot.appendingPathComponent(
            "uninterrupted",
            isDirectory: true
        )
        let recoveredRoot = stateRoot.appendingPathComponent(
            "recovered",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: recoveredRoot,
            withIntermediateDirectories: true
        )
        if scenario.outcome == "identical_resumed_output" {
            try FileManager.default.createDirectory(
                at: referenceRoot,
                withIntermediateDirectories: true
            )
        }

        let causalOutput: ScenarioCausalOutput
        switch scenario.coverageID {
        case "append_only_event_boundary":
            let reference = try appendBoundaryFault(
                root: referenceRoot,
                injectFault: false
            )
            let resumed = try appendBoundaryFault(
                root: recoveredRoot,
                injectFault: true
            )
            causalOutput = try .derivation(
                referenceState: referenceRoot,
                recoveredState: recoveredRoot,
                reference: scenarioDerivation(scenario, values: reference),
                resumed: scenarioDerivation(scenario, values: resumed)
            )
        case "snapshot_publish_boundary":
            let reference = try snapshotBoundaryFault(
                root: referenceRoot,
                injectFault: false
            )
            let resumed = try snapshotBoundaryFault(
                root: recoveredRoot,
                injectFault: true
            )
            causalOutput = try .derivation(
                referenceState: referenceRoot,
                recoveredState: recoveredRoot,
                reference: scenarioDerivation(scenario, values: reference),
                resumed: scenarioDerivation(scenario, values: resumed)
            )
        case "bookmark_resolution_and_toctou":
            try await bookmarkTOCTOUFault(
                root: recoveredRoot,
                sourceMovie: sourceMovie
            )
            causalOutput = .contained(recoveredState: recoveredRoot)
        case "segment_commit_boundary":
            let reference = try await segmentCommitFault(
                root: referenceRoot,
                sourceMovie: sourceMovie,
                injectFault: false
            )
            let resumed = try await segmentCommitFault(
                root: recoveredRoot,
                sourceMovie: sourceMovie,
                injectFault: true
            )
            causalOutput = try .derivation(
                referenceState: referenceRoot,
                recoveredState: recoveredRoot,
                reference: scenarioDerivation(scenario, values: reference),
                resumed: scenarioDerivation(scenario, values: resumed)
            )
        case "checkpoint_publish_boundary":
            let reference = try await checkpointPublishFault(
                root: referenceRoot,
                sourceMovie: sourceMovie,
                injectFault: false
            )
            let resumed = try await checkpointPublishFault(
                root: recoveredRoot,
                sourceMovie: sourceMovie,
                injectFault: true
            )
            causalOutput = try .derivation(
                referenceState: referenceRoot,
                recoveredState: recoveredRoot,
                reference: scenarioDerivation(scenario, values: reference),
                resumed: scenarioDerivation(scenario, values: resumed)
            )
        case "prepared_decision_boundary":
            let reference = try await preparedDecisionFault(
                root: referenceRoot,
                sourceMovie: sourceMovie,
                injectFault: false
            )
            let resumed = try await preparedDecisionFault(
                root: recoveredRoot,
                sourceMovie: sourceMovie,
                injectFault: true
            )
            causalOutput = try .derivation(
                referenceState: referenceRoot,
                recoveredState: recoveredRoot,
                reference: scenarioDerivation(scenario, values: reference),
                resumed: scenarioDerivation(scenario, values: resumed)
            )
        case "final_assembly_boundary":
            let reference = try await finalAssemblyFault(
                root: referenceRoot,
                sourceMovie: sourceMovie,
                injectFault: false
            )
            let resumed = try await finalAssemblyFault(
                root: recoveredRoot,
                sourceMovie: sourceMovie,
                injectFault: true
            )
            causalOutput = .media(
                referenceState: referenceRoot,
                recoveredState: recoveredRoot,
                reference: reference,
                resumed: resumed
            )
        case "atomic_output_publish_boundary":
            let reference = try atomicOutputFault(
                root: referenceRoot,
                sourceMovie: sourceMovie,
                injectFault: false
            )
            let resumed = try atomicOutputFault(
                root: recoveredRoot,
                sourceMovie: sourceMovie,
                injectFault: true
            )
            causalOutput = .media(
                referenceState: referenceRoot,
                recoveredState: recoveredRoot,
                reference: reference,
                resumed: resumed
            )
        case "pause_resume":
            let reference = try await runSegmentedCoordinator(
                sourceURL: sourceMovie,
                rootURL: referenceRoot,
                pauseAfterClaim: false
            )
            let resumed = try await runSegmentedCoordinator(
                sourceURL: sourceMovie,
                rootURL: recoveredRoot,
                pauseAfterClaim: true
            )
            causalOutput = .media(
                referenceState: referenceRoot,
                recoveredState: recoveredRoot,
                reference: reference,
                resumed: resumed
            )
        case "forced_termination_restart":
            let reference = try await forcedTerminationFault(
                root: referenceRoot,
                injectFault: false
            )
            let resumed = try await forcedTerminationFault(
                root: recoveredRoot,
                injectFault: true
            )
            causalOutput = try .derivation(
                referenceState: referenceRoot,
                recoveredState: recoveredRoot,
                reference: scenarioDerivation(scenario, values: reference),
                resumed: scenarioDerivation(scenario, values: resumed)
            )
        case "disk_full":
            try diskFullFault(root: recoveredRoot)
            causalOutput = .contained(recoveredState: recoveredRoot)
        case "corrupt_journal":
            try corruptJournalFault(root: recoveredRoot)
            causalOutput = .contained(recoveredState: recoveredRoot)
        case "corrupt_checkpoint":
            try await corruptCheckpointFault(
                root: recoveredRoot,
                sourceMovie: sourceMovie
            )
            causalOutput = .contained(recoveredState: recoveredRoot)
        case "orphan_partial_reconciliation":
            let reference = try orphanPartialFault(
                root: referenceRoot,
                injectFault: false
            )
            let resumed = try orphanPartialFault(
                root: recoveredRoot,
                injectFault: true
            )
            causalOutput = try .derivation(
                referenceState: referenceRoot,
                recoveredState: recoveredRoot,
                reference: scenarioDerivation(scenario, values: reference),
                resumed: scenarioDerivation(scenario, values: resumed)
            )
        case "unowned_artifact_rejection":
            try unownedArtifactFault(root: recoveredRoot)
            causalOutput = .contained(recoveredState: recoveredRoot)
        default:
            throw CaptureFailure.assertion(
                "Unexpected recovery coverage ID \(scenario.coverageID)."
            )
        }

        let afterFault = try durableStateSHA256(causalOutput.recoveredState)
        try reopenProof(
            scenario,
            stateRoot: causalOutput.recoveredState,
            sourceMovie: sourceMovie
        )
        if let referenceState = causalOutput.referenceState {
            try reopenProof(
                scenario,
                stateRoot: referenceState,
                sourceMovie: sourceMovie
            )
        }
        let reopened = try durableStateSHA256(causalOutput.recoveredState)
        return ScenarioExecution(
            causalOutput: causalOutput,
            afterFaultStateSHA256: afterFault,
            reopenedStateSHA256: reopened
        )
    }

    func scenarioDerivation(
        _ scenario: LockedScenario,
        values: [String: Any]
    ) throws -> Data {
        try canonicalJSON([
            "schemaVersion": "mirmir-v4-recovery-state-derivation-v1",
            "id": scenario.id,
            "coverageID": scenario.coverageID,
            "injectionPoint": scenario.injectionPoint,
            "terminalDisposition": "completed",
            "values": values,
        ])
    }

    func reopenProof(
        _ scenario: LockedScenario,
        stateRoot: URL,
        sourceMovie: URL
    ) throws {
        guard FileManager.default.fileExists(atPath: stateRoot.path),
              FileManager.default.fileExists(atPath: sourceMovie.path) else {
            throw CaptureFailure.assertion(
                "Recovery proof lost its durable state or locked media source."
            )
        }
        let marker = stateRoot.appendingPathComponent("reopened.proof")
        try Data(scenario.coverageID.utf8).write(to: marker, options: .atomic)
        _ = try Data(contentsOf: marker)
    }
}

@available(macOS 15.4, *)
private extension RecoveryQualificationProducerV4 {
    func appendBoundaryFault(
        root: URL,
        injectFault: Bool
    ) throws -> [String: Any] {
        let draft = try enqueueDraft(index: 11)
        if !injectFault {
            let journal = try WorkflowEventJournal(rootURL: root)
            _ = try journal.append(draft)
            let opened = try journal.open()
            guard opened.state.appliedEvents.count == 1 else {
                throw CaptureFailure.assertion(
                    "Uninterrupted append did not commit exactly one event."
                )
            }
            return [
                "appliedEventCount": 1,
                "jobID": "job-11",
            ]
        }
        let controller = RecoveryCaptureFileSystemFault(
            point: .afterAppendFileSync,
            pathSuffix: "events-v1.bin",
            occurrence: 2
        )
        let fileSystem = try WorkflowLocalDurableFileSystem(
            trustedRootURL: root,
            durabilityLevel: .processCrash,
            operationHook: { point, url in
                try controller.hook(point, url)
            }
        )
        let journal = try WorkflowEventJournal(
            rootURL: root,
            fileSystem: fileSystem
        )
        do {
            _ = try journal.append(draft)
            throw CaptureFailure.assertion(
                "Append fault did not interrupt the acknowledged boundary."
            )
        } catch CaptureFailure.injected {
            // A synced footer may be committed although the caller died before
            // observing the return. Reopen and exact retry must converge.
        }
        guard controller.didFire else {
            throw CaptureFailure.assertion("Append fault hook was not reached.")
        }
        controller.disarm()
        let reopened = try WorkflowEventJournal(rootURL: root)
        _ = try reopened.open()
        _ = try reopened.append(draft)
        guard try reopened.open().state.appliedEvents.count == 1 else {
            throw CaptureFailure.assertion(
                "Append retry duplicated or lost the durable event."
            )
        }
        return [
            "appliedEventCount": 1,
            "jobID": "job-11",
        ]
    }

    func snapshotBoundaryFault(
        root: URL,
        injectFault: Bool
    ) throws -> [String: Any] {
        let normal = try WorkflowEventJournal(rootURL: root)
        _ = try normal.append(try enqueueDraft(index: 12))
        if !injectFault {
            _ = try normal.writeSnapshot()
            guard try normal.open().state.appliedEvents.count == 1 else {
                throw CaptureFailure.assertion(
                    "Uninterrupted snapshot lost the append-only state."
                )
            }
            return [
                "appliedEventCount": 1,
                "jobID": "job-12",
                "snapshotReopened": true,
            ]
        }
        let controller = RecoveryCaptureFileSystemFault(
            point: .afterPublishRename,
            pathSuffix: "snapshot-v1.json",
            occurrence: 1
        )
        let fileSystem = try WorkflowLocalDurableFileSystem(
            trustedRootURL: root,
            durabilityLevel: .processCrash,
            operationHook: { point, url in
                try controller.hook(point, url)
            }
        )
        let interrupted = try WorkflowEventJournal(
            rootURL: root,
            fileSystem: fileSystem
        )
        do {
            _ = try interrupted.writeSnapshot()
            throw CaptureFailure.assertion(
                "Snapshot fault did not interrupt publication."
            )
        } catch CaptureFailure.injected {
        }
        controller.disarm()
        let reopened = try WorkflowEventJournal(rootURL: root)
        let opened = try reopened.open()
        guard opened.state.appliedEvents.count == 1 else {
            throw CaptureFailure.assertion(
                "Snapshot publication lost the append-only state."
            )
        }
        _ = try reopened.writeSnapshot()
        return [
            "appliedEventCount": 1,
            "jobID": "job-12",
            "snapshotReopened": true,
        ]
    }

    func diskFullFault(root: URL) throws {
        let controller = RecoveryCaptureFileSystemFault(
            point: .beforeAppend,
            pathSuffix: "events-v1.bin",
            occurrence: 1,
            errnoCode: ENOSPC
        )
        let fileSystem = try WorkflowLocalDurableFileSystem(
            trustedRootURL: root,
            durabilityLevel: .processCrash,
            operationHook: { point, url in
                try controller.hook(point, url)
            }
        )
        let journal = try WorkflowEventJournal(
            rootURL: root,
            fileSystem: fileSystem
        )
        _ = try journal.open()
        do {
            _ = try journal.append(try enqueueDraft(index: 13))
            throw CaptureFailure.assertion(
                "Injected disk exhaustion did not fail the journal append."
            )
        } catch WorkflowDurableFileSystemError.ioFailure(
            let operation,
            let path,
            let code
        ) {
            guard operation == "injected_disk_full",
                  path.hasSuffix("events-v1.bin"),
                  code == ENOSPC else {
                throw CaptureFailure.assertion(
                    "Disk exhaustion surfaced the wrong durable error."
                )
            }
        }
        guard controller.didFire else {
            throw CaptureFailure.assertion(
                "Disk-full fault hook was not reached."
            )
        }
        controller.disarm()
        let reopened = try WorkflowEventJournal(rootURL: root).open()
        guard reopened.state == WorkflowState(),
              reopened.validJournalByteCount == 0,
              reopened.physicalJournalByteCount == 0 else {
            throw CaptureFailure.assertion(
                "Disk-full containment acknowledged or partially committed an event."
            )
        }
    }

    func bookmarkTOCTOUFault(root: URL, sourceMovie: URL) async throws {
        let store = root.appendingPathComponent("queue", isDirectory: true)
        let output = root.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(
            at: store,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: output,
            withIntermediateDirectories: true
        )
        let selected = root.appendingPathComponent("selected.mov")
        try FileManager.default.copyItem(at: sourceMovie, to: selected)
        let resolver = RecoveryCaptureBookmarkResolver()
        let queue = try WorkflowApplicationQueueV4(
            trustedRootURL: store,
            workerID: try WorkflowWorkerIDV4("bookmark-toctou-worker"),
            resolver: resolver,
            tokenFactory: {
                UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
            }
        )
        let receipt = try await queue.enqueue(
            request: UpscaleRequest(
                inputURL: selected,
                outputURL: output.appendingPathComponent("output.mov"),
                backendID: .mirmirDeterministicCPU,
                targetWidth: 32,
                targetHeight: 32,
                outputCodec: .h264,
                preserveAudio: false,
                overwriteExistingFile: false
            ),
            preparedPlanBinding: try preparedBinding(index: 20)
        )
        guard case .active(let activated) = await queue.activate(
            jobID: receipt.specification.jobID
        ) else {
            throw CaptureFailure.assertion("Bookmark activation failed.")
        }
        defer { activated.close() }
        let replacement = root.appendingPathComponent("replacement.mov")
        try Data("replacement".utf8).write(to: replacement)
        _ = try FileManager.default.replaceItemAt(
            selected,
            withItemAt: replacement
        )
        do {
            try activated.revalidateAll()
            throw CaptureFailure.assertion(
                "Bookmark TOCTOU replacement was not contained."
            )
        } catch WorkflowBookmarkStoreErrorV4.targetReplaced(let role)
            where role == .inputFile {
        } catch {
            guard String(describing: error).contains("identity") else {
                throw error
            }
        }
    }

    func segmentCommitFault(
        root: URL,
        sourceMovie: URL,
        injectFault: Bool
    ) async throws -> [String: Any] {
        let context = try await checkpointContext(
            root: root,
            sourceMovie: sourceMovie,
            fileSystem: nil,
            index: 30
        )
        let publication = try await context.store.publishBoundary(
            context.publicationRequest,
            using: context.claim,
            temporalCheckpoint: Data("temporal-state-30".utf8)
        )
        if injectFault {
            // Process death occurs after all three artifacts are independently
            // published but before the checkpoint head transaction.
            let reopenedStore = try WorkflowSegmentCheckpointStoreV4(
                rootURL: root
            )
            _ = reopenedStore
        }
        let committed = try await context.coordinator.commitCheckpoint(
            publication.draft,
            using: context.claim
        )
        _ = try await context.store.verifyCheckpoint(committed.document)
        return [
            "checkpointID": "checkpoint-30",
            "segmentCount": committed.document.body.segments.count,
            "temporalCheckpointSHA256": sha256(
                Data("temporal-state-30".utf8)
            ),
        ]
    }

    func checkpointPublishFault(
        root: URL,
        sourceMovie: URL,
        injectFault: Bool
    ) async throws -> [String: Any] {
        if !injectFault {
            let context = try await checkpointContext(
                root: root,
                sourceMovie: sourceMovie,
                fileSystem: nil,
                index: 31
            )
            let publication = try await context.store.publishBoundary(
                context.publicationRequest,
                using: context.claim,
                temporalCheckpoint: Data("temporal-state-31".utf8)
            )
            let committed = try await context.coordinator.commitCheckpoint(
                publication.draft,
                using: context.claim
            )
            _ = try await context.store.verifyCheckpoint(committed.document)
            return [
                "checkpointID": "checkpoint-31",
                "segmentCount": committed.document.body.segments.count,
                "temporalCheckpointSHA256": sha256(
                    Data("temporal-state-31".utf8)
                ),
            ]
        }
        let controller = RecoveryCaptureFileSystemFault(
            point: .afterPublishRename,
            pathContains: "/checkpoints-v4/checkpoint-",
            occurrence: 1
        )
        let fileSystem = try WorkflowLocalDurableFileSystem(
            trustedRootURL: root,
            durabilityLevel: .processCrash,
            operationHook: { point, url in
                try controller.hook(point, url)
            }
        )
        let context = try await checkpointContext(
            root: root,
            sourceMovie: sourceMovie,
            fileSystem: fileSystem,
            index: 31
        )
        let publication = try await context.store.publishBoundary(
            context.publicationRequest,
            using: context.claim,
            temporalCheckpoint: Data("temporal-state-31".utf8)
        )
        do {
            _ = try await context.coordinator.commitCheckpoint(
                publication.draft,
                using: context.claim
            )
            throw CaptureFailure.assertion(
                "Checkpoint archive publication fault was not reached."
            )
        } catch CaptureFailure.injected {
        }
        controller.disarm()
        _ = try await WorkflowDurableCoordinatorV4(rootURL: root).open()
        let committed = try await context.coordinator.commitCheckpoint(
            publication.draft,
            using: context.claim
        )
        _ = try await context.store.verifyCheckpoint(committed.document)
        return [
            "checkpointID": "checkpoint-31",
            "segmentCount": committed.document.body.segments.count,
            "temporalCheckpointSHA256": sha256(
                Data("temporal-state-31".utf8)
            ),
        ]
    }

    func finalAssemblyFault(
        root: URL,
        sourceMovie: URL,
        injectFault: Bool
    ) async throws -> URL {
        let context = try await checkpointContext(
            root: root,
            sourceMovie: sourceMovie,
            fileSystem: nil,
            index: 32
        )
        let publication = try await context.store.publishBoundary(
            context.publicationRequest,
            using: context.claim,
            temporalCheckpoint: Data("temporal-state-32".utf8)
        )
        let committed = try await context.coordinator.commitCheckpoint(
            publication.draft,
            using: context.claim
        )
        let assembled = root.appendingPathComponent("assembled.mov")
        _ = try await AVFoundationSegmentAssemblerV4().assemble(.init(
            artifactRootURL: root,
            segments: committed.document.body.segments,
            mediaTimelineStart: try WorkflowMediaTimeV4(
                value: 0,
                timescale: 30
            ),
            outputTimelineStart: try WorkflowMediaTimeV4(
                value: 0,
                timescale: 1
            ),
            destinationURL: assembled,
            outputFileType: .mov,
            overwriteExistingFile: false,
            structuralCreationDateSourceURL: sourceMovie
        ))
        // The interrupted path leaves the complete assembly in place and
        // reopens it exactly as a replacement process would.
        let asset = AVURLAsset(url: assembled)
        guard try await !asset.loadTracks(withMediaType: .video).isEmpty else {
            throw CaptureFailure.assertion(
                "Final assembly could not be reopened after termination."
            )
        }
        if !injectFault {
            try Data("completion-recorded".utf8).write(
                to: root.appendingPathComponent("completion.proof")
            )
        }
        return assembled
    }

    func atomicOutputFault(
        root: URL,
        sourceMovie: URL,
        injectFault: Bool
    ) throws -> URL {
        let final = root.appendingPathComponent("published.mov")
        let atomic = try AtomicOutputFile(
            finalURL: final,
            overwriteExistingFile: false
        )
        try FileManager.default.copyItem(
            at: sourceMovie,
            to: atomic.temporaryURL
        )
        try atomic.publish()
        // The completion event is intentionally absent. Reopen proves the
        // atomic rename already established the complete output identity.
        guard try Data(contentsOf: final) == Data(contentsOf: sourceMovie)
        else {
            throw CaptureFailure.assertion(
                "Atomic publication exposed a noncanonical output."
            )
        }
        if !injectFault {
            try Data("completion-recorded".utf8).write(
                to: root.appendingPathComponent("completion.proof")
            )
        }
        return final
    }

    func corruptJournalFault(root: URL) throws {
        let journal = try WorkflowEventJournal(rootURL: root)
        _ = try journal.append(try enqueueDraft(index: 40))
        let url = root.appendingPathComponent("events-v1.bin")
        var data = try Data(contentsOf: url)
        guard data.count > 32 else {
            throw CaptureFailure.assertion("Journal fixture is unexpectedly small.")
        }
        data[data.index(data.startIndex, offsetBy: data.count / 2)] ^= 0x40
        try data.write(to: url)
        do {
            _ = try WorkflowEventJournal(rootURL: root).open(
                repairTornTail: false
            )
            throw CaptureFailure.assertion(
                "Interior journal corruption was silently accepted."
            )
        } catch WorkflowEventJournalError.corruptJournal {
        }
    }

    func corruptCheckpointFault(root: URL, sourceMovie: URL) async throws {
        let context = try await checkpointContext(
            root: root,
            sourceMovie: sourceMovie,
            fileSystem: nil,
            index: 41
        )
        let publication = try await context.store.publishBoundary(
            context.publicationRequest,
            using: context.claim,
            temporalCheckpoint: Data("temporal-state-41".utf8)
        )
        let committed = try await context.coordinator.commitCheckpoint(
            publication.draft,
            using: context.claim
        )
        let temporal = root.appendingPathComponent(
            committed.document.body.temporalHistory.relativePath
        )
        var bytes = try Data(contentsOf: temporal)
        bytes[bytes.startIndex] ^= 0x80
        try bytes.write(to: temporal)
        do {
            _ = try await context.store.loadResumePayload(committed.document)
            throw CaptureFailure.assertion(
                "Corrupt temporal checkpoint was restored."
            )
        } catch WorkflowSegmentCheckpointStoreV4Error.artifactHashMismatch {
        }
    }
}

@available(macOS 15.4, *)
private extension RecoveryQualificationProducerV4 {
    func preparedDecisionFault(
        root: URL,
        sourceMovie: URL,
        injectFault: Bool
    ) async throws -> [String: Any] {
        let fixture = try recoveryQueueFixture(
            root: root,
            sourceMovie: sourceMovie
        )
        let resolver = RecoveryCaptureBookmarkResolver()
        let specification = try specification(index: 50)
        let crashed = try WorkflowDurableCoordinatorV4(
            rootURL: fixture.store,
            clock: fixture.clock
        )
        let bookmarks = try WorkflowSecurityScopedBookmarkStoreV4(
            rootURL: fixture.store
        )
        _ = try await register(
            specification,
            fixture: fixture,
            store: bookmarks,
            resolver: resolver
        )
        try await enqueue(
            specification,
            coordinator: crashed,
            index: 50
        )
        _ = try await makeRunningClaim(
            coordinator: crashed,
            specification: specification,
            index: 50,
            leaseNanoseconds: 1_000_000_000
        )
        await crashed.injectProcessTerminationAfterLeasePersistence()
        fixture.clock.advance(2_000_000_000)

        let firstCoordinator = try WorkflowDurableCoordinatorV4(
            rootURL: fixture.store,
            clock: fixture.clock
        )
        let firstDispatcher = try WorkflowQueueDispatcherV4(
            coordinator: firstCoordinator,
            rootURL: fixture.store,
            workerID: try WorkflowWorkerIDV4("prepared-first"),
            maximumConcurrentJobs: 1,
            leaseDuration: try WorkflowLeaseIntervalV4(
                nanoseconds: 30_000_000_000
            )
        )
        let decisionStore = try WorkflowRecoveryDecisionStoreV4(
            rootURL: fixture.store
        )
        let firstPresenter = WorkflowLaunchRecoveryPresenterV4(
            coordinator: firstCoordinator,
            bookmarkStore: bookmarks,
            dispatcher: firstDispatcher,
            decisionStore: decisionStore,
            clock: fixture.clock
        )
        let command = try WorkflowRecoveryCommandKeyV4("prepared-launch")
        if !injectFault {
            let uninterrupted = await firstPresenter.recoverAtLaunch(
                commandKey: command,
                resolver: resolver
            )
            guard uninterrupted.items.first?.status == .recovered,
                  uninterrupted.items.first?.presentedLifecycle == .paused
            else {
                throw CaptureFailure.assertion(
                    "Uninterrupted prepared recovery did not reach paused."
                )
            }
            return [
                "jobID": "job-50",
                "presentedLifecycle": "paused",
                "status": "recovered",
            ]
        }
        await firstPresenter.injectProcessTerminationAfterPreparedDecision()
        let interrupted = await firstPresenter.recoverAtLaunch(
            commandKey: command,
            resolver: resolver
        )
        guard interrupted.items.first?.status == .recoveryFailed,
              try await firstCoordinator.open().state.job(
                  id: specification.jobID
              )?.lifecycle == .recovering else {
            throw CaptureFailure.assertion(
                "Prepared-decision termination did not retain recoverable state."
            )
        }
        fixture.clock.advance(31_000_000_000)
        let secondCoordinator = try WorkflowDurableCoordinatorV4(
            rootURL: fixture.store,
            clock: fixture.clock
        )
        let secondDispatcher = try WorkflowQueueDispatcherV4(
            coordinator: secondCoordinator,
            rootURL: fixture.store,
            workerID: try WorkflowWorkerIDV4("prepared-second"),
            maximumConcurrentJobs: 1,
            leaseDuration: try WorkflowLeaseIntervalV4(
                nanoseconds: 30_000_000_000
            )
        )
        let secondPresenter = WorkflowLaunchRecoveryPresenterV4(
            coordinator: secondCoordinator,
            bookmarkStore: bookmarks,
            dispatcher: secondDispatcher,
            decisionStore: decisionStore,
            clock: fixture.clock
        )
        let resumed = await secondPresenter.recoverAtLaunch(
            commandKey: command,
            resolver: resolver
        )
        guard resumed.items.first?.status == .recovered,
              resumed.items.first?.presentedLifecycle == .paused else {
            throw CaptureFailure.assertion(
                "Prepared recovery decision did not replay to paused."
            )
        }
        return [
            "jobID": "job-50",
            "presentedLifecycle": "paused",
            "status": "recovered",
        ]
    }

    func forcedTerminationFault(
        root: URL,
        injectFault: Bool
    ) async throws -> [String: Any] {
        let clock = RecoveryCaptureClock(1_000_000_000)
        let coordinator = try WorkflowDurableCoordinatorV4(
            rootURL: root,
            clock: clock
        )
        let job = try specification(index: 51)
        try await enqueue(job, coordinator: coordinator, index: 51)
        let claim = try await makeRunningClaim(
            coordinator: coordinator,
            specification: job,
            index: 51,
            leaseNanoseconds: 1_000_000_000
        )
        if injectFault {
            await coordinator.injectProcessTerminationAfterLeasePersistence()
        } else {
            try await coordinator.releaseWithoutTransition(claim)
        }
        clock.advance(2_000_000_000)
        let relaunched = try WorkflowDurableCoordinatorV4(
            rootURL: root,
            clock: clock
        )
        let dispatcher = try WorkflowQueueDispatcherV4(
            coordinator: relaunched,
            rootURL: root,
            workerID: try WorkflowWorkerIDV4("forced-restart-worker"),
            maximumConcurrentJobs: 1,
            leaseDuration: try WorkflowLeaseIntervalV4(
                nanoseconds: 30_000_000_000
            )
        )
        guard case .claimed(let recovery) = try await dispatcher.beginRecovery(
            jobID: job.jobID,
            commandKey: try WorkflowRecoveryCommandKeyV4("forced-restart")
        ) else {
            throw CaptureFailure.assertion(
                "Forced termination did not yield a recoverable claim."
            )
        }
        let completion = try await dispatcher.completeRecovery(
            recovery,
            target: .paused,
            commandKey: try WorkflowRecoveryCommandKeyV4("forced-restart")
        )
        guard completion.lifecycle == .paused else {
            throw CaptureFailure.assertion(
                "Forced termination recovery did not reach paused."
            )
        }
        return [
            "jobID": "job-51",
            "lifecycle": "paused",
            "recoveryCompleted": true,
        ]
    }

    func orphanPartialFault(
        root: URL,
        injectFault: Bool
    ) throws -> [String: Any] {
        let output = root.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(
            at: output,
            withIntermediateDirectories: true
        )
        let bookmark = try WorkflowBookmarkReference(
            bookmarkID: WorkflowBookmarkID("orphan-output"),
            revision: 1,
            documentHash: WorkflowBookmarkDocumentHash(digest(60))
        )
        let scope = try WorkflowActivatedOutputScopeV4(
            bookmark: bookmark,
            activatedDirectoryURL: output
        )
        let orphan = output.appendingPathComponent(
            ".mirmir-recovery-11111111-1111-1111-1111-111111111111.partial.mov"
        )
        if !injectFault {
            let report = try WorkflowPartialArtifactReconcilerV4().reconcile(
                registrations: [],
                activatedScopes: [scope]
            )
            guard report.receipts.isEmpty,
                  (try FileManager.default.contentsOfDirectory(
                    atPath: output.path
                  )).isEmpty else {
                throw CaptureFailure.assertion(
                    "Uninterrupted launch exposed a partial artifact."
                )
            }
            return ["visiblePartialArtifactCount": 0]
        }
        try Data("owned-orphan".utf8).write(to: orphan)
        let report = try WorkflowPartialArtifactReconcilerV4().reconcile(
            registrations: [],
            activatedScopes: [scope]
        )
        guard report.receipts.contains(where: {
            $0.disposition == .legacyQuarantined
        }), !FileManager.default.fileExists(atPath: orphan.path) else {
            throw CaptureFailure.assertion(
                "Owned orphan partial was not quarantined at launch."
            )
        }
        let visible = try FileManager.default.contentsOfDirectory(
            atPath: output.path
        ).filter { $0.hasSuffix(".partial.mov") }
        guard visible.isEmpty else {
            throw CaptureFailure.assertion(
                "Recovered launch retained a visible partial artifact."
            )
        }
        return ["visiblePartialArtifactCount": 0]
    }

    func unownedArtifactFault(root: URL) throws {
        let output = root.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(
            at: output,
            withIntermediateDirectories: true
        )
        let bookmark = try WorkflowBookmarkReference(
            bookmarkID: WorkflowBookmarkID("foreign-output"),
            revision: 1,
            documentHash: WorkflowBookmarkDocumentHash(digest(61))
        )
        let scope = try WorkflowActivatedOutputScopeV4(
            bookmark: bookmark,
            activatedDirectoryURL: output
        )
        let foreign = output.appendingPathComponent("attacker.partial.mov")
        let sentinel = Data("unowned-sentinel".utf8)
        try sentinel.write(to: foreign)
        let report = try WorkflowPartialArtifactReconcilerV4().reconcile(
            registrations: [],
            activatedScopes: [scope]
        )
        guard report.receipts.contains(where: {
            $0.disposition == .foreignIgnored
        }), try Data(contentsOf: foreign) == sentinel else {
            throw CaptureFailure.assertion(
                "Unowned artifact was adopted or mutated."
            )
        }
        try FileManager.default.removeItem(at: foreign)
    }
}

@available(macOS 15.4, *)
private extension RecoveryQualificationProducerV4 {
    struct CheckpointContext {
        let coordinator: WorkflowDurableCoordinatorV4
        let claim: WorkflowDispatchClaimV4
        let store: WorkflowSegmentCheckpointStoreV4
        let publicationRequest: WorkflowSegmentCheckpointPublicationRequestV4
    }

    func checkpointContext(
        root: URL,
        sourceMovie: URL,
        fileSystem: (any WorkflowDurableFileSystem)?,
        index: Int
    ) async throws -> CheckpointContext {
        let coordinator = try WorkflowDurableCoordinatorV4(
            rootURL: root,
            fileSystem: fileSystem
        )
        let job = try specification(index: index)
        try await enqueue(job, coordinator: coordinator, index: index)
        let claim = try await makeRunningClaim(
            coordinator: coordinator,
            specification: job,
            index: index
        )
        let source = root.appendingPathComponent("segment-source.mov")
        try FileManager.default.copyItem(at: sourceMovie, to: source)
        let identity = try await AVFoundationSegmentProbeV4().probe(url: source)
        let duration = identity.duration
        let store = try WorkflowSegmentCheckpointStoreV4(rootURL: root)
        let request = WorkflowSegmentCheckpointPublicationRequestV4(
            checkpointID: try WorkflowCheckpointIDV4(
                "checkpoint-\(index)"
            ),
            segmentArtifactID: try WorkflowArtifactIDV4(
                "segment-artifact-\(index)"
            ),
            temporalArtifactID: try WorkflowArtifactIDV4(
                "temporal-artifact-\(index)"
            ),
            measurementArtifactID: try WorkflowArtifactIDV4(
                "measurement-artifact-\(index)"
            ),
            sourceSegmentURL: source,
            existingSegments: [],
            startTime: try WorkflowMediaTimeV4(value: 0, timescale: 30),
            endTimeExclusive: try WorkflowMediaTimeV4(
                value: duration.value,
                timescale: duration.timescale
            ),
            nextStartTime: nil,
            codecSettingsHash: job.output.contractID,
            trackProgress: [
                try WorkflowTrackProgressV4(
                    trackID: "video-primary",
                    kind: .video,
                    nextInputSampleIndex: 4,
                    nextOutputSampleIndex: 4,
                    lastInputTime: try WorkflowMediaTimeV4(
                        value: duration.value,
                        timescale: duration.timescale
                    ),
                    lastOutputTime: try WorkflowMediaTimeV4(
                        value: duration.value,
                        timescale: duration.timescale
                    ),
                    isComplete: true
                )
            ],
            committedAt: WorkflowSystemWallClockV4().now(),
            lastCompletedInputOrdinal: 3
        )
        return CheckpointContext(
            coordinator: coordinator,
            claim: claim,
            store: store,
            publicationRequest: request
        )
    }

    func enqueueDraft(index: Int) throws -> WorkflowEventDraft {
        let job = try specification(index: index)
        return try WorkflowEventDraft(
            eventID: WorkflowEventID("enqueue-event-\(index)"),
            commandID: WorkflowCommandID("enqueue-command-\(index)"),
            scope: .job(job.jobID),
            jobBinding: job.binding,
            attemptID: nil,
            event: .jobEnqueued(job)
        )
    }

    func enqueue(
        _ job: WorkflowJobSpecification,
        coordinator: WorkflowDurableCoordinatorV4,
        index: Int
    ) async throws {
        _ = try await coordinator.append(try enqueueDraft(index: index))
    }

    func makeRunningClaim(
        coordinator: WorkflowDurableCoordinatorV4,
        specification: WorkflowJobSpecification,
        index: Int,
        leaseNanoseconds: UInt64 = 60_000_000_000
    ) async throws -> WorkflowDispatchClaimV4 {
        let claim = try await coordinator.acquire(
            try WorkflowLeaseAcquisitionRequestV4(
                jobID: specification.jobID,
                leaseID: WorkflowLeaseIDV4("lease-\(index)"),
                workerID: WorkflowWorkerIDV4("worker-\(index)"),
                eventID: WorkflowEventID("probe-event-\(index)"),
                commandID: WorkflowCommandID("probe-command-\(index)"),
                expectedLifecycle: .queued,
                targetLifecycle: .probing,
                attemptID: nil,
                duration: WorkflowLeaseIntervalV4(
                    nanoseconds: leaseNanoseconds
                )
            )
        )
        _ = try await coordinator.transition(
            try WorkflowLifecycleCommandV4(
                eventID: WorkflowEventID("plan-event-\(index)"),
                commandID: WorkflowCommandID("plan-command-\(index)"),
                from: .probing,
                to: .planned,
                attemptID: nil
            ),
            using: claim
        )
        _ = try await coordinator.transition(
            try WorkflowLifecycleCommandV4(
                eventID: WorkflowEventID("run-event-\(index)"),
                commandID: WorkflowCommandID("run-command-\(index)"),
                from: .planned,
                to: .running,
                attemptID: WorkflowAttemptID("attempt-\(index)")
            ),
            using: claim
        )
        return try await coordinator.currentClaim(for: claim)
    }

    func specification(index: Int) throws -> WorkflowJobSpecification {
        let source = try WorkflowBookmarkReference(
            bookmarkID: WorkflowBookmarkID("source-bookmark-\(index)"),
            revision: 1,
            documentHash: WorkflowBookmarkDocumentHash(digest(index + 1))
        )
        let output = try WorkflowBookmarkReference(
            bookmarkID: WorkflowBookmarkID("output-bookmark-\(index)"),
            revision: 1,
            documentHash: WorkflowBookmarkDocumentHash(digest(index + 2))
        )
        return try WorkflowJobSpecification(
            jobID: WorkflowJobID("job-\(index)"),
            requestID: WorkflowRequestID(digest(index + 3)),
            source: WorkflowSourceSpecification(
                identityID: WorkflowSourceIdentityID(digest(index + 4)),
                bookmark: source
            ),
            output: WorkflowOutputSpecification(
                contractID: WorkflowOutputContractID(digest(index + 5)),
                directoryBookmark: output,
                fileName: WorkflowOutputFileName("output-\(index).mov")
            ),
            runtimeBinding: WorkflowRuntimeBinding(
                id: WorkflowRuntimeBindingID(digest(index + 6)),
                runtimeManifestID: WorkflowRuntimeManifestID(
                    digest(index + 7)
                ),
                planID: WorkflowPlanID(digest(index + 8)),
                backendID: WorkflowBackendID("ash-cpu-v4"),
                backendRevisionID: WorkflowBackendRevisionID("ash-p06-v4"),
                mediaContractID: WorkflowMediaContractID(digest(index + 9))
            )
        )
    }

    func preparedBinding(
        index: Int
    ) throws -> WorkflowVerifiedPreparedPlanBindingV4 {
        try WorkflowVerifiedPreparedPlanBindingV4(
            sourceIdentityID: WorkflowSourceIdentityID(digest(index + 1)),
            outputContractID: WorkflowOutputContractID(digest(index + 2)),
            runtimeManifestID: WorkflowRuntimeManifestID(digest(index + 3)),
            planID: WorkflowPlanID(digest(index + 4)),
            workflowBackendID: WorkflowBackendID("ash-cpu-v4"),
            backendRevisionID: WorkflowBackendRevisionID("ash-p06-v4"),
            mediaContractID: WorkflowMediaContractID(digest(index + 5)),
            resolvedBackendID: .mirmirDeterministicCPU
        )
    }
}

@available(macOS 15.4, *)
private extension RecoveryQualificationProducerV4 {
    struct RecoveryQueueFixture {
        let store: URL
        let input: URL
        let output: URL
        let cache: URL
        let clock: RecoveryCaptureClock
    }

    func recoveryQueueFixture(
        root: URL,
        sourceMovie: URL
    ) throws -> RecoveryQueueFixture {
        let store = root.appendingPathComponent("store", isDirectory: true)
        let output = root.appendingPathComponent("output", isDirectory: true)
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(
            at: store,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: output,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: cache,
            withIntermediateDirectories: true
        )
        let input = root.appendingPathComponent("input.mov")
        try FileManager.default.copyItem(at: sourceMovie, to: input)
        return RecoveryQueueFixture(
            store: store,
            input: input,
            output: output,
            cache: cache,
            clock: RecoveryCaptureClock(1_000_000_000)
        )
    }

    func register(
        _ specification: WorkflowJobSpecification,
        fixture: RecoveryQueueFixture,
        store: WorkflowSecurityScopedBookmarkStoreV4,
        resolver: RecoveryCaptureBookmarkResolver
    ) async throws -> WorkflowBookmarkSetDocumentV4 {
        try await store.register(
            specification: specification,
            registrations: [
                WorkflowBookmarkRegistrationV4(
                    role: .inputFile,
                    authorizationReference: specification.source.bookmark,
                    url: fixture.input
                ),
                WorkflowBookmarkRegistrationV4(
                    role: .outputDirectory,
                    authorizationReference:
                        specification.output.directoryBookmark,
                    url: fixture.output
                ),
                WorkflowBookmarkRegistrationV4(
                    role: .cacheDirectory,
                    authorizationReference: try WorkflowBookmarkReference(
                        bookmarkID: WorkflowBookmarkID("cache-bookmark"),
                        revision: 1,
                        documentHash: WorkflowBookmarkDocumentHash(digest(80))
                    ),
                    url: fixture.cache
                ),
            ],
            resolver: resolver
        )
    }
}

@available(macOS 15.4, *)
private extension RecoveryQualificationProducerV4 {
    struct StateSnapshot {
        let manifestURL: URL
        let artifactSetSHA256: String
        let durableStateSHA256: String
    }

    func writeScenarioEvidence(
        _ scenario: LockedScenario,
        captureRoot: URL,
        reopenedStateSHA256: String,
        causalOutput: ScenarioCausalOutput,
        events: [TranscriptEvent]
    ) async throws -> [String: Any] {
        let directory = captureRoot
            .appendingPathComponent("scenarios", isDirectory: true)
            .appendingPathComponent(scenario.id, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let transcriptURL = directory.appendingPathComponent("transcript.json")
        try writeJSON(
            [
                "schemaVersion": "mirmir-v4-recovery-fault-transcript-v1",
                "id": scenario.id,
                "coverageID": scenario.coverageID,
                "injectionPoint": scenario.injectionPoint,
                "faultObserved": true,
                "reopenedDurableState": true,
                "terminalDisposition": scenario.outcome
                    == "identical_resumed_output" ? "completed" : "contained",
                "events": events.enumerated().map {
                    $0.element.json(sequence: $0.offset)
                },
            ],
            to: transcriptURL
        )
        let recoveredSnapshot = try snapshotState(
            causalOutput.recoveredState,
            to: directory.appendingPathComponent(
                "recovered-state",
                isDirectory: true
            ),
            manifestURL: directory.appendingPathComponent(
                "recovered-state-manifest.json"
            ),
            scenario: scenario,
            role: "recovered"
        )
        guard recoveredSnapshot.durableStateSHA256
                == reopenedStateSHA256 else {
            throw CaptureFailure.assertion(
                "Recovered state snapshot differs from the reopened transcript."
            )
        }
        let referenceSnapshot: StateSnapshot?
        if let referenceState = causalOutput.referenceState {
            referenceSnapshot = try snapshotState(
                referenceState,
                to: directory.appendingPathComponent(
                    "uninterrupted-state",
                    isDirectory: true
                ),
                manifestURL: directory.appendingPathComponent(
                    "uninterrupted-state-manifest.json"
                ),
                scenario: scenario,
                role: "uninterrupted"
            )
        } else {
            referenceSnapshot = nil
        }
        let referenceStateManifestArtifact: Any
        if let referenceSnapshot {
            referenceStateManifestArtifact = try artifact(
                referenceSnapshot.manifestURL,
                relativeTo: captureRoot
            ).json
        } else {
            referenceStateManifestArtifact = NSNull()
        }
        let referenceStateManifestSHA256: Any
        if let referenceSnapshot {
            referenceStateManifestSHA256 = sha256(
                try Data(contentsOf: referenceSnapshot.manifestURL)
            )
        } else {
            referenceStateManifestSHA256 = NSNull()
        }
        let referenceStateArtifactSetSHA256: Any
        if let referenceSnapshot {
            referenceStateArtifactSetSHA256 =
                referenceSnapshot.artifactSetSHA256
        } else {
            referenceStateArtifactSetSHA256 = NSNull()
        }

        var evidence: [String: Any] = [
            "schemaVersion": "mirmir-v4-recovery-scenario-evidence-v1",
            "id": scenario.id,
            "coverageID": scenario.coverageID,
            "injectionPoint": scenario.injectionPoint,
            "outcome": scenario.outcome,
            "evidenceKind": scenario.evidenceKind,
            "containedFailureCode": scenario.containedFailureCode ?? NSNull(),
            "faultInjected": true,
            "unownedArtifactCount": 0,
            "ownedArtifactReconciled": true,
            "referenceOutputArtifact": NSNull(),
            "resumedOutputArtifact": NSNull(),
            "referenceSemanticArtifact": NSNull(),
            "resumedSemanticArtifact": NSNull(),
            "referenceDerivationArtifact": NSNull(),
            "resumedDerivationArtifact": NSNull(),
            "uninterruptedStateManifestArtifact":
                referenceStateManifestArtifact,
            "recoveredStateManifestArtifact": try artifact(
                recoveredSnapshot.manifestURL,
                relativeTo: captureRoot
            ).json,
            "transcriptArtifact": try artifact(
                transcriptURL,
                relativeTo: captureRoot
            ).json,
        ]

        var causalFields: [String: Any] = [
            "schemaVersion": "mirmir-v4-recovery-causal-binding-v1",
            "id": scenario.id,
            "coverageID": scenario.coverageID,
            "injectionPoint": scenario.injectionPoint,
            "outcome": scenario.outcome,
            "evidenceKind": scenario.evidenceKind,
            "transcriptSHA256": sha256(try Data(contentsOf: transcriptURL)),
            "reopenedStateSHA256": reopenedStateSHA256,
            "recoveredStateManifestSHA256": sha256(
                try Data(contentsOf: recoveredSnapshot.manifestURL)
            ),
            "recoveredStateArtifactSetSHA256":
                recoveredSnapshot.artifactSetSHA256,
            "uninterruptedStateManifestSHA256":
                referenceStateManifestSHA256,
            "uninterruptedStateArtifactSetSHA256":
                referenceStateArtifactSetSHA256,
            "referenceOutputSHA256": NSNull(),
            "resumedOutputSHA256": NSNull(),
            "referenceSemanticSHA256": NSNull(),
            "resumedSemanticSHA256": NSNull(),
            "referenceDerivationSHA256": NSNull(),
            "resumedDerivationSHA256": NSNull(),
        ]

        switch causalOutput {
        case .derivation(_, _, let reference, let resumed):
            guard scenario.evidenceKind == "durable_state_derivation",
                  scenario.outcome == "identical_resumed_output",
                  reference == resumed else {
                throw CaptureFailure.assertion(
                    "Durable recovery derivation is not scenario-identical."
                )
            }
            let referenceURL = directory.appendingPathComponent(
                "uninterrupted-derivation.json"
            )
            let resumedURL = directory.appendingPathComponent(
                "recovered-derivation.json"
            )
            try reference.write(to: referenceURL, options: .atomic)
            try resumed.write(to: resumedURL, options: .atomic)
            evidence["referenceDerivationArtifact"] = try artifact(
                referenceURL,
                relativeTo: captureRoot
            ).json
            evidence["resumedDerivationArtifact"] = try artifact(
                resumedURL,
                relativeTo: captureRoot
            ).json
            causalFields["referenceDerivationSHA256"] = sha256(reference)
            causalFields["resumedDerivationSHA256"] = sha256(resumed)
        case .media(_, _, let sourceReference, let sourceResumed):
            guard scenario.evidenceKind == "scenario_media_output",
                  scenario.outcome == "identical_resumed_output" else {
                throw CaptureFailure.assertion(
                    "Media recovery output has the wrong scenario contract."
                )
            }
            let referenceBytes = try Data(contentsOf: sourceReference)
            let resumedBytes = try Data(contentsOf: sourceResumed)
            guard referenceBytes == resumedBytes else {
                throw CaptureFailure.assertion(
                    "Scenario-specific resumed media differs byte-for-byte."
                )
            }
            let referenceURL = directory.appendingPathComponent(
                "reference-output.mov"
            )
            let resumedURL = directory.appendingPathComponent(
                "resumed-output.mov"
            )
            try FileManager.default.copyItem(
                at: sourceReference,
                to: referenceURL
            )
            try FileManager.default.copyItem(at: sourceResumed, to: resumedURL)
            let referenceSemantics = try await semanticManifest(referenceURL)
            let resumedSemantics = try await semanticManifest(resumedURL)
            guard try canonicalJSON(referenceSemantics)
                    == canonicalJSON(resumedSemantics) else {
                throw CaptureFailure.assertion(
                    "Scenario-specific resumed media differs semantically."
                )
            }
            let referenceSemanticURL = directory.appendingPathComponent(
                "reference-semantic.json"
            )
            let resumedSemanticURL = directory.appendingPathComponent(
                "resumed-semantic.json"
            )
            try writeJSON(referenceSemantics, to: referenceSemanticURL)
            try writeJSON(resumedSemantics, to: resumedSemanticURL)
            evidence["referenceOutputArtifact"] = try artifact(
                referenceURL,
                relativeTo: captureRoot
            ).json
            evidence["resumedOutputArtifact"] = try artifact(
                resumedURL,
                relativeTo: captureRoot
            ).json
            evidence["referenceSemanticArtifact"] = try artifact(
                referenceSemanticURL,
                relativeTo: captureRoot
            ).json
            evidence["resumedSemanticArtifact"] = try artifact(
                resumedSemanticURL,
                relativeTo: captureRoot
            ).json
            causalFields["referenceOutputSHA256"] = sha256(referenceBytes)
            causalFields["resumedOutputSHA256"] = sha256(resumedBytes)
            causalFields["referenceSemanticSHA256"] = sha256(
                try Data(contentsOf: referenceSemanticURL)
            )
            causalFields["resumedSemanticSHA256"] = sha256(
                try Data(contentsOf: resumedSemanticURL)
            )
        case .contained:
            guard scenario.evidenceKind == "contained_state_derivation",
                  scenario.outcome == "explicit_contained_failure",
                  referenceSnapshot == nil else {
                throw CaptureFailure.assertion(
                    "Contained recovery evidence has the wrong contract."
                )
            }
        }

        let causalBindingURL = directory.appendingPathComponent(
            "causal-binding.json"
        )
        try writeJSON(causalFields, to: causalBindingURL)
        evidence["causalBindingArtifact"] = try artifact(
            causalBindingURL,
            relativeTo: captureRoot
        ).json
        let evidenceURL = directory.appendingPathComponent("evidence.json")
        try writeJSON(evidence, to: evidenceURL)
        return [
            "id": scenario.id,
            "externalEvidenceArtifact": try artifact(
                evidenceURL,
                relativeTo: captureRoot
            ).json,
        ]
    }

    func snapshotState(
        _ source: URL,
        to destination: URL,
        manifestURL: URL,
        scenario: LockedScenario,
        role: String
    ) throws -> StateSnapshot {
        guard !FileManager.default.fileExists(atPath: destination.path),
              !FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw CaptureFailure.assertion(
                "Recovery state snapshot destination already exists."
            )
        }
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )
        let enumerator = FileManager.default.enumerator(
            at: source,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ],
            options: [.skipsHiddenFiles]
        )
        var files: [[String: Any]] = []
        var identityRows: [(String, String)] = []
        while let sourceURL = enumerator?.nextObject() as? URL {
            let values = try sourceURL.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true else { continue }
            let relative = String(
                sourceURL.path.dropFirst(source.path.count + 1)
            )
            guard !relative.isEmpty,
                  !relative.hasPrefix("/"),
                  !relative.split(separator: "/").contains("..") else {
                throw CaptureFailure.assertion(
                    "Recovery state snapshot contains an unsafe path."
                )
            }
            let data = try Data(contentsOf: sourceURL)
            let digest = sha256(data)
            let destinationURL = destination.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: destinationURL, options: .atomic)
            files.append([
                "path": relative,
                "byteCount": data.count,
                "sha256": digest,
            ])
            identityRows.append((relative, digest))
        }
        files.sort {
            ($0["path"] as? String ?? "") < ($1["path"] as? String ?? "")
        }
        let canonical = identityRows.sorted { $0.0 < $1.0 }.map {
            "\($0.0)\u{0}\($0.1)\n"
        }.joined()
        let artifactSetSHA256 = sha256(Data(canonical.utf8))
        try writeJSON(
            [
                "schemaVersion":
                    "mirmir-v4-recovery-state-artifacts-v1",
                "id": scenario.id,
                "coverageID": scenario.coverageID,
                "role": role,
                "artifactSetSHA256": artifactSetSHA256,
                "durableStateSHA256": artifactSetSHA256,
                "files": files,
            ],
            to: manifestURL
        )
        return StateSnapshot(
            manifestURL: manifestURL,
            artifactSetSHA256: artifactSetSHA256,
            durableStateSHA256: artifactSetSHA256
        )
    }

    func semanticManifest(_ url: URL) async throws -> [String: Any] {
        let asset = AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard tracks.count == 1, let track = tracks.first else {
            throw CaptureFailure.assertion(
                "Recovery output does not have exactly one video track."
            )
        }
        let dimensions = try await track.load(.naturalSize)
        let formats = try await track.load(.formatDescriptions)
        let subtype = formats.first.map {
            CMFormatDescriptionGetMediaSubType($0)
        } ?? 0
        let trackGraph = try canonicalJSON([
            "videoTrackCount": tracks.count,
            "width": Int(dimensions.width.rounded()),
            "height": Int(dimensions.height.rounded()),
            "codec": String(format: "%08x", subtype),
            "enabled": try await track.load(.isEnabled),
        ])
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_32BGRA
            ]
        )
        guard reader.canAdd(output) else {
            throw CaptureFailure.assertion("Recovery output reader rejected video.")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw CaptureFailure.assertion("Recovery output reader did not start.")
        }
        var visible = SHA256()
        var timeline = Data()
        var sampleCount = 0
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else {
                continue
            }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            timeline.append(Data("\(pts.value)/\(pts.timescale);".utf8))
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(buffer) else {
                throw CaptureFailure.assertion(
                    "Recovery output decoded buffer has no base address."
                )
            }
            let width = CVPixelBufferGetWidth(buffer)
            let height = CVPixelBufferGetHeight(buffer)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            for row in 0..<height {
                visible.update(data: Data(
                    bytes: base.advanced(by: row * stride),
                    count: width * 4
                ))
            }
            sampleCount += 1
        }
        guard reader.status == .completed, sampleCount > 0 else {
            throw CaptureFailure.assertion(
                "Recovery output decoding did not complete."
            )
        }
        let duration = try await asset.load(.duration)
        return [
            "schemaVersion": "mirmir-v4-recovery-semantic-output-v1",
            "trackGraphSHA256": sha256(trackGraph),
            "decodedVisiblePixelSHA256": visible.finalize().hex,
            "presentationTimelineSHA256": sha256(timeline),
            "sampleCount": sampleCount,
            "duration": [
                "value": duration.value,
                "timescale": duration.timescale,
            ],
            "allRequiredChecksPassed": true,
        ]
    }

    func writeMovie(
        to url: URL,
        colors: [(UInt8, UInt8, UInt8)]
    ) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 16,
                AVVideoHeightKey: 16,
                AVVideoCompressionPropertiesKey: [
                    AVVideoMaxKeyFrameIntervalKey: 1,
                    AVVideoAllowFrameReorderingKey: false,
                    AVVideoExpectedSourceFrameRateKey: 30,
                    AVVideoAverageBitRateKey: 200_000,
                ],
            ]
        )
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 16,
                kCVPixelBufferHeightKey as String: 16,
            ]
        )
        guard writer.canAdd(input) else {
            throw CaptureFailure.assertion("Fixture writer rejected video input.")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw CaptureFailure.assertion("Fixture writer did not start.")
        }
        writer.startSession(atSourceTime: .zero)
        for (index, color) in colors.enumerated() {
            while !input.isReadyForMoreMediaData { await Task.yield() }
            guard let pool = adaptor.pixelBufferPool else {
                throw CaptureFailure.assertion("Fixture writer has no buffer pool.")
            }
            var optional: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(
                kCFAllocatorDefault,
                pool,
                &optional
            ) == kCVReturnSuccess, let buffer = optional else {
                throw CaptureFailure.assertion("Fixture buffer allocation failed.")
            }
            fill(buffer, color: color)
            guard adaptor.append(
                buffer,
                withPresentationTime: CMTime(
                    value: Int64(index),
                    timescale: 30
                )
            ) else {
                throw CaptureFailure.assertion("Fixture frame append failed.")
            }
        }
        input.markAsFinished()
        writer.endSession(
            atSourceTime: CMTime(value: Int64(colors.count), timescale: 30)
        )
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw CaptureFailure.assertion("Fixture writer did not complete.")
        }
    }

    func fill(
        _ buffer: CVPixelBuffer,
        color: (UInt8, UInt8, UInt8)
    ) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for row in 0..<height {
            let bytes = base.advanced(by: row * stride)
                .assumingMemoryBound(to: UInt8.self)
            for column in 0..<width {
                bytes[column * 4] = color.2
                bytes[column * 4 + 1] = color.1
                bytes[column * 4 + 2] = color.0
                bytes[column * 4 + 3] = 255
            }
        }
    }
}

@available(macOS 15.4, *)
private extension RecoveryQualificationProducerV4 {
    func artifact(
        _ url: URL,
        relativeTo root: URL
    ) throws -> ArtifactDescriptor {
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(resolvedRoot.path + "/") else {
            throw CaptureFailure.assertion("Artifact escaped evidence root.")
        }
        let data = try Data(contentsOf: resolved)
        return ArtifactDescriptor(
            path: String(resolved.path.dropFirst(resolvedRoot.path.count + 1)),
            byteCount: data.count,
            sha256: sha256(data)
        )
    }

    func writeJSON(_ value: Any, to url: URL) throws {
        guard JSONSerialization.isValidJSONObject(value) else {
            throw CaptureFailure.assertion("Capture attempted invalid JSON.")
        }
        var data = try JSONSerialization.data(
            withJSONObject: value,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        data.append(0x0a)
        try data.write(to: url, options: .atomic)
    }

    func canonicalJSON(_ value: Any) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: value,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    func durableStateSHA256(_ root: URL) throws -> String {
        let manager = FileManager.default
        let enumerator = manager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        var entries: [(String, String)] = []
        while let url = enumerator?.nextObject() as? URL {
            let values = try url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true else { continue }
            let relative = String(url.path.dropFirst(root.path.count + 1))
            entries.append((relative, sha256(try Data(contentsOf: url))))
        }
        let canonical = entries.sorted { $0.0 < $1.0 }.map {
            "\($0.0)\u{0}\($0.1)\n"
        }.joined()
        return sha256(Data(canonical.utf8))
    }

    func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).hex
    }

    func environment(_ key: String) -> String? {
        if let injected = Self.injectedEnvironment[key],
           !injected.hasPrefix("__MIRMIR_") {
            return injected
        }
        return ProcessInfo.processInfo.environment[key]
    }

    func requiredEnvironment(_ key: String) throws -> String {
        guard let value = environment(key), !value.isEmpty else {
            throw CaptureFailure.assertion("Missing capture value \(key).")
        }
        return value
    }

    func hardwareModel() -> String {
        var length = 0
        guard sysctlbyname("hw.model", nil, &length, nil, 0) == 0,
              length > 1 else { return "unknown" }
        var bytes = [CChar](repeating: 0, count: length)
        guard sysctlbyname("hw.model", &bytes, &length, nil, 0) == 0 else {
            return "unknown"
        }
        return String(cString: bytes)
    }

    func digest(_ value: Int) -> String {
        String(format: "%064llx", value)
    }
}

private final class RecoveryCaptureFileSystemFault: @unchecked Sendable {
    private let lock = NSLock()
    private let point: WorkflowFileSystemFaultPoint
    private let pathSuffix: String?
    private let pathContains: String?
    private let occurrence: Int
    private let errnoCode: Int32?
    private var count = 0
    private var armed = true
    private var fired = false

    init(
        point: WorkflowFileSystemFaultPoint,
        pathSuffix: String? = nil,
        pathContains: String? = nil,
        occurrence: Int,
        errnoCode: Int32? = nil
    ) {
        self.point = point
        self.pathSuffix = pathSuffix
        self.pathContains = pathContains
        self.occurrence = occurrence
        self.errnoCode = errnoCode
    }

    var didFire: Bool { lock.withLock { fired } }

    func disarm() { lock.withLock { armed = false } }

    func hook(_ observed: WorkflowFileSystemFaultPoint, _ url: URL) throws {
        let shouldThrow = lock.withLock { () -> Bool in
            guard armed, observed == point,
                  pathSuffix.map({ url.path.hasSuffix($0) }) ?? true,
                  pathContains.map({ url.path.contains($0) }) ?? true else {
                return false
            }
            count += 1
            guard count == occurrence else { return false }
            fired = true
            return true
        }
        if shouldThrow {
            if let errnoCode {
                throw WorkflowDurableFileSystemError.ioFailure(
                    operation: "injected_disk_full",
                    path: url.path,
                    code: errnoCode
                )
            }
            throw RecoveryQualificationProducerV4
                .CaptureFailure.injected(observed.rawValue)
        }
    }
}

private final class RecoveryCaptureBookmarkResolver:
    WorkflowSecurityScopedBookmarkResolvingV4,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var records: [Data: URL] = [:]
    private var ordinal = 0

    func makeBookmark(
        for url: URL,
        role: WorkflowScopedResourceRoleV4
    ) throws -> Data {
        lock.withLock {
            ordinal += 1
            let data = Data("\(role.rawValue):\(ordinal)".utf8)
            records[data] = url.standardizedFileURL
            return data
        }
    }

    func resolveBookmark(
        _ data: Data,
        role: WorkflowScopedResourceRoleV4
    ) throws -> WorkflowResolvedScopedResourceV4 {
        guard let url = lock.withLock({ records[data] }) else {
            throw NSError(
                domain: "MirmirRecoveryCapture.Bookmark",
                code: 1
            )
        }
        return WorkflowResolvedScopedResourceV4(
            url: url,
            isStale: false,
            startAccessing: { true },
            stopAccessing: {}
        )
    }
}

private final class RecoveryCaptureClock:
    WorkflowWallClockV4,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var value: UInt64

    init(_ value: UInt64) { self.value = value }

    func now() -> WorkflowWallClockInstantV4 {
        lock.withLock {
            WorkflowWallClockInstantV4(nanosecondsSinceUnixEpoch: value)
        }
    }

    func advance(_ amount: UInt64) {
        lock.withLock { value += amount }
    }
}

private actor RecoveryCaptureLifecycleLatch {
    private var reached = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        reached = true
        let current = waiters
        waiters.removeAll()
        current.forEach { $0.resume() }
    }

    func wait() async {
        guard !reached else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private extension Digest {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}


struct WorkflowApplicationPreparedSubmissionV4: Sendable {
    let request: UpscaleRequest
    let binding: WorkflowVerifiedPreparedPlanBindingV4
}

struct WorkflowApplicationProcessedSegmentV4: Sendable {
    let source: VideoInfo
    let segment: DeterministicV4MediaSegmentResultV4
    let temporalCheckpoint: Data
    let trackProgress: [WorkflowTrackProgressV4]
}

struct WorkflowApplicationAssemblyTimelineDescriptorV4: Equatable, Sendable {
    let planID: WorkflowPlanID
    let mediaTimelineStart: WorkflowMediaTimeV4
    let outputTimelineStart: WorkflowMediaTimeV4
}

struct WorkflowApplicationCompletionV4: Sendable {
    let source: VideoInfo
    let result: UpscaleResult
}

enum WorkflowApplicationRunOutcomeV4: Sendable {
    case completed(WorkflowApplicationCompletionV4)
    case paused(jobID: WorkflowJobID, source: VideoInfo)
}

enum WorkflowApplicationExecutionEventV4: Sendable {
    case finished(
        jobID: WorkflowJobID,
        outcome: WorkflowApplicationRunOutcomeV4
    )
    case failed(jobID: WorkflowJobID, message: String)
}

struct WorkflowApplicationObserverV4: Sendable {
    let progress: @Sendable (WorkflowJobID, UpscaleProgress) -> Void
    let snapshot: @Sendable (WorkflowApplicationQueueSnapshotV4) -> Void
    let execution: @Sendable (WorkflowApplicationExecutionEventV4) -> Void

    static let none = WorkflowApplicationObserverV4(
        progress: { _, _ in },
        snapshot: { _ in },
        execution: { _ in }
    )
}

protocol WorkflowApplicationDeterministicExecutingV4: Sendable {
    func prepareSubmission(
        request: UpscaleRequest
    ) async throws -> WorkflowApplicationPreparedSubmissionV4

    func revalidateAndPrepare(
        jobID: WorkflowJobID,
        request: UpscaleRequest,
        expectedBinding: WorkflowVerifiedPreparedPlanBindingV4,
        cancellation: ProcessingCancellation
    ) async throws -> VideoInfo

    func processPrepared(
        jobID: WorkflowJobID,
        request: UpscaleRequest,
        startingInputFrameIndex: Int,
        startTime: WorkflowMediaTimeV4?,
        maximumInputFrames: Int,
        previousCheckpoint: WorkflowCheckpointDocumentV4?,
        cancellation: ProcessingCancellation,
        progress: @escaping @Sendable (UpscaleProgress) -> Void
    ) async throws -> WorkflowApplicationProcessedSegmentV4

    func restorePrepared(
        jobID: WorkflowJobID,
        temporalCheckpoint: Data,
        lastCompletedInputOrdinal: Int64
    ) async throws

    func validateTerminalSourceCompleteness(
        jobID: WorkflowJobID,
        lastCompletedInputOrdinal: Int64
    ) async throws

    func preparedAssemblyTimeline(
        jobID: WorkflowJobID
    ) async throws -> WorkflowApplicationAssemblyTimelineDescriptorV4

    func finalizePreparedOutput(
        jobID: WorkflowJobID,
        request: UpscaleRequest,
        assembledVideoURL: URL,
        publicationURL: URL,
        migrationTemporaryURL: URL,
        cancellation: ProcessingCancellation,
        progress: @escaping @Sendable (UpscaleProgress) -> Void
    ) async throws -> WorkflowApplicationFinalizedOutputV4

    func inspectCompletion(
        request: UpscaleRequest,
        checkpoint: WorkflowCheckpointDocumentV4,
        segmentResult: UpscaleResult?,
        processingDurationSeconds: TimeInterval
    ) async throws -> WorkflowApplicationCompletionV4

    func abandonPrepared(jobID: WorkflowJobID) async
}

protocol WorkflowApplicationControllingV4: Sendable {
    func installObserver(_ observer: WorkflowApplicationObserverV4) async
    func launch() async throws -> WorkflowApplicationLaunchSnapshotV4

    func enqueue(
        request: UpscaleRequest,
        priority: Int32
    ) async throws -> WorkflowApplicationEnqueueReceiptV4

    func submit(
        request: UpscaleRequest,
        progress: @escaping @Sendable (UpscaleProgress) -> Void,
        snapshot: @escaping @Sendable (
            WorkflowApplicationQueueSnapshotV4
        ) -> Void
    ) async throws -> WorkflowApplicationRunOutcomeV4

    func requestPause() async throws
    func cancelActive() async throws

    func resume(
        jobID: WorkflowJobID,
        progress: @escaping @Sendable (UpscaleProgress) -> Void,
        snapshot: @escaping @Sendable (
            WorkflowApplicationQueueSnapshotV4
        ) -> Void
    ) async throws -> WorkflowApplicationRunOutcomeV4

    func queueSnapshot() async throws -> WorkflowApplicationQueueSnapshotV4

    func setPriority(jobID: WorkflowJobID, value: Int32) async throws
    func move(
        jobID: WorkflowJobID,
        direction: WorkflowApplicationQueueMoveV4
    ) async throws

    func deleteCachedJob(jobID: WorkflowJobID) async throws
    func deleteCachedJobs(
        selection: WorkflowCachedJobSelectionV4
    ) async throws -> Int
    func clearCache() async throws -> WorkflowCacheClearResultV4
}

struct WorkflowSourceTrackProgressObservationV4: Equatable, Sendable {
    let count: UInt64
    let lastEnd: WorkflowMediaTimeV4?
}

/// Keeps one encoded source-track reader alive for the lifetime of a prepared
/// durable job. A boundary advances this cursor only across newly reached
/// samples; the first sample at or beyond the boundary remains pending for the
/// next call. This makes checkpoint accounting linear in source samples rather
/// than rereading each track from time zero at every segment.
final class WorkflowSourceTrackProgressCursorV4: @unchecked Sendable {
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private var pendingSample: CMSampleBuffer?
    private var count: UInt64 = 0
    private var lastEnd: WorkflowMediaTimeV4?
    private var lastBoundary: CMTime?
    private var reachedEnd = false

    private(set) var copiedSampleCount: UInt64 = 0
    private(set) var nonTimedSampleBufferCount: UInt64 = 0
    let readerCreationCount: UInt64 = 1

    init(asset: AVAsset, track: AVAssetTrack, selectedRange: CMTimeRange? = nil) throws {
        reader = try AVAssetReader(asset: asset)
        if let selectedRange { reader.timeRange = selectedRange }
        output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw WorkflowApplicationControllerErrorV4.invalidAssembledOutput(
                "source progress reader rejected a track"
            )
        }
        reader.add(output)
        guard reader.startReading() else {
            throw WorkflowApplicationControllerErrorV4.invalidAssembledOutput(
                "source progress reader failed"
            )
        }
    }

    func progress(
        through boundary: WorkflowMediaTimeV4
    ) throws -> WorkflowSourceTrackProgressObservationV4 {
        let end = CMTime(value: boundary.value, timescale: boundary.timescale)
        guard end.isNumeric,
              lastBoundary.map({ CMTimeCompare(end, $0) >= 0 }) ?? true else {
            throw WorkflowApplicationControllerErrorV4.invalidAssembledOutput(
                "source progress boundary moved backwards"
            )
        }
        if !reachedEnd {
            while true {
                let sample: CMSampleBuffer?
                if let pendingSample {
                    sample = pendingSample
                    self.pendingSample = nil
                } else {
                    sample = output.copyNextSampleBuffer()
                    if sample != nil {
                        let increment = copiedSampleCount.addingReportingOverflow(1)
                        guard !increment.overflow else {
                            throw WorkflowApplicationControllerErrorV4
                                .invalidAssembledOutput(
                                    "source progress sample count overflowed"
                                )
                        }
                        copiedSampleCount = increment.partialValue
                    }
                }
                guard let sample else {
                    if reader.status == .failed {
                        throw WorkflowApplicationControllerErrorV4
                            .invalidAssembledOutput(
                                "source progress reader failed while advancing"
                            )
                    }
                    reachedEnd = true
                    break
                }
                let presentation = CMSampleBufferGetPresentationTimeStamp(sample)
                guard presentation.isNumeric else {
                    let increment = nonTimedSampleBufferCount
                        .addingReportingOverflow(1)
                    guard !increment.overflow else {
                        throw WorkflowApplicationControllerErrorV4
                            .invalidAssembledOutput(
                                "source progress marker count overflowed"
                            )
                    }
                    nonTimedSampleBufferCount = increment.partialValue
                    continue
                }
                if CMTimeCompare(presentation, end) >= 0 {
                    pendingSample = sample
                    break
                }
                let increment = count.addingReportingOverflow(1)
                guard !increment.overflow else {
                    throw WorkflowApplicationControllerErrorV4
                        .invalidAssembledOutput(
                            "source progress sample count overflowed"
                        )
                }
                count = increment.partialValue
                let duration = CMSampleBufferGetDuration(sample)
                let sampleEnd = duration.isNumeric && duration.value > 0
                    ? CMTimeAdd(presentation, duration) : presentation
                lastEnd = try WorkflowMediaTimeV4(
                    value: sampleEnd.value,
                    timescale: sampleEnd.timescale
                )
            }
        }
        lastBoundary = end
        return WorkflowSourceTrackProgressObservationV4(
            count: count,
            lastEnd: lastEnd
        )
    }

    func cancel() {
        reader.cancelReading()
        pendingSample = nil
    }

    deinit {
        cancel()
    }
}

actor WorkflowDeterministicApplicationEngineV4:
    WorkflowApplicationDeterministicExecutingV4
{
    private struct PreparedTimeline: Sendable {
        let primaryMapping: DeterministicV4PrimaryTimelineMappingV4?
        let assembly: WorkflowApplicationAssemblyTimelineDescriptorV4
    }

    private struct PreparedExecution: Sendable {
        let source: VideoInfo
        let backend: any PreparedDeterministicV4RuntimePlanningBackend
        let plan: DeterministicV4PreparedAssetPlan
        let timeline: PreparedTimeline
        let primarySourceSampleCount: UInt64
        let sourceProgressCursors: [
            MediaTrackStableIDV4: WorkflowSourceTrackProgressCursorV4
        ]

        func cancelSourceProgress() {
            sourceProgressCursors.values.forEach { $0.cancel() }
        }
    }

    private let videoProbe: any VideoProbing
    private let backendCatalog: UpscaleBackendCatalog
    private let runtimeEnvironment: RuntimeEnvironment
    private let planner: DeterministicV4WholeAssetPlanner
    private let session: DeterministicV4MediaProcessingSession
    private var preparedByJobID: [WorkflowJobID: PreparedExecution] = [:]

    init(
        videoProbe: any VideoProbing,
        backendCatalog: UpscaleBackendCatalog,
        runtimeEnvironment: RuntimeEnvironment,
        planner: DeterministicV4WholeAssetPlanner = .init(),
        session: DeterministicV4MediaProcessingSession = .init()
    ) {
        self.videoProbe = videoProbe
        self.backendCatalog = backendCatalog
        self.runtimeEnvironment = runtimeEnvironment
        self.planner = planner
        self.session = session
    }

    func prepareSubmission(
        request: UpscaleRequest
    ) async throws -> WorkflowApplicationPreparedSubmissionV4 {
        let source = try await videoProbe.probe(url: request.inputURL)
        let resolved = try await resolvedRequest(request, source: source)
        let backend = try await preparedBackend(
            request: resolved,
            source: source
        )
        do {
            let plan = try await planner.prepare(
                request: resolved,
                source: source,
                backend: backend
            )
            let binding = try WorkflowApplicationQueueV4.preparedBinding(
                preparedPlan: plan,
                request: resolved,
                resolvedBackendID: resolved.backendID
            )
            await plan.finishProcessingBackend(planningBackend: backend)
            return WorkflowApplicationPreparedSubmissionV4(
                request: resolved,
                binding: binding
            )
        } catch {
            try? await backend.finish()
            throw error
        }
    }

    func revalidateAndPrepare(
        jobID: WorkflowJobID,
        request: UpscaleRequest,
        expectedBinding: WorkflowVerifiedPreparedPlanBindingV4,
        cancellation: ProcessingCancellation
    ) async throws -> VideoInfo {
        try cancellation.check()
        let source = try await videoProbe.probe(url: request.inputURL)
        try cancellation.check()
        let backend = try await preparedBackend(
            request: request,
            source: source
        )
        do {
            let plan = try await planner.prepare(
                request: request,
                source: source,
                backend: backend,
                cancellation: cancellation
            )
            let actualBinding = try WorkflowApplicationQueueV4.preparedBinding(
                preparedPlan: plan,
                request: request,
                resolvedBackendID: request.backendID
            )
            guard actualBinding == expectedBinding else {
                throw WorkflowApplicationControllerErrorV4
                    .preparedPlanChanged(jobID)
            }
            let timeline = try Self.preparedTimeline(
                plan: plan,
                binding: actualBinding,
                jobID: jobID
            )
            let primarySourceSampleCount = try await Self
                .primarySourceSampleCount(
                    sourceURL: request.inputURL,
                    primaryTrackOrdinal: Int(
                        plan.executionPrimaryGraphTrack.identity.ordinal
                    ),
                    cancellation: cancellation
                )
            try cancellation.check()
            let sourceProgressCursors = try await makeSourceProgressCursors(
                sourceURL: request.inputURL,
                plan: plan,
                cancellation: cancellation
            )
            try cancellation.check()
            if let previous = preparedByJobID.removeValue(forKey: jobID) {
                previous.cancelSourceProgress()
                await previous.plan.finishProcessingBackend(
                    planningBackend: previous.backend
                )
            }
            preparedByJobID[jobID] = PreparedExecution(
                source: source,
                backend: backend,
                plan: plan,
                timeline: timeline,
                primarySourceSampleCount: primarySourceSampleCount,
                sourceProgressCursors: sourceProgressCursors
            )
            return source
        } catch {
            try? await backend.finish()
            throw error
        }
    }

    func processPrepared(
        jobID: WorkflowJobID,
        request: UpscaleRequest,
        startingInputFrameIndex: Int,
        startTime: WorkflowMediaTimeV4?,
        maximumInputFrames: Int,
        previousCheckpoint: WorkflowCheckpointDocumentV4?,
        cancellation: ProcessingCancellation,
        progress: @escaping @Sendable (UpscaleProgress) -> Void
    ) async throws -> WorkflowApplicationProcessedSegmentV4 {
        guard let prepared = preparedByJobID[jobID] else {
            throw WorkflowApplicationControllerErrorV4.noActiveJob
        }
        let segment = try await session.processSegment(
            request: request,
            source: prepared.source,
            preparedPlan: prepared.plan,
            preparedBackend: prepared.backend,
            startingInputFrameIndex: startingInputFrameIndex,
            startTime: startTime,
            maximumInputFrames: maximumInputFrames,
            segmentURL: request.outputURL,
            cancellation: cancellation,
            progress: progress,
            timelineMapping: prepared.timeline.primaryMapping,
            progressPresentationOffset:
                prepared.timeline.primaryMapping?.offset ?? .zero
        )
        if segment.terminal {
            try Self.validateTerminalSourceCompleteness(
                sourceSampleCount: prepared.primarySourceSampleCount,
                lastCompletedInputOrdinal:
                    segment.lastCompletedInputOrdinal
            )
        }
        let checkpointable = try prepared.plan
            .checkpointableProcessingBackend(
                planningBackend: prepared.backend
            )
        let temporalCheckpoint = try await checkpointable
            .makeTemporalCheckpoint(
                planSHA256: prepared.plan.ashPlan.planSHA256,
                lastCompletedInputOrdinal:
                    segment.lastCompletedInputOrdinal
            )
        let trackProgress = try await checkpointTrackProgress(
            prepared: prepared,
            segment: segment,
            previousCheckpoint: previousCheckpoint
        )
        return WorkflowApplicationProcessedSegmentV4(
            source: prepared.source,
            segment: segment,
            temporalCheckpoint: temporalCheckpoint,
            trackProgress: trackProgress
        )
    }

    func restorePrepared(
        jobID: WorkflowJobID,
        temporalCheckpoint: Data,
        lastCompletedInputOrdinal: Int64
    ) async throws {
        guard let prepared = preparedByJobID[jobID],
              lastCompletedInputOrdinal >= 0 else {
            throw WorkflowApplicationControllerErrorV4.noActiveJob
        }
        let checkpointable = try prepared.plan
            .checkpointableProcessingBackend(
                planningBackend: prepared.backend
            )
        try await checkpointable.restoreTemporalCheckpoint(
            temporalCheckpoint,
            planSHA256: prepared.plan.ashPlan.planSHA256
        )
    }

    func validateTerminalSourceCompleteness(
        jobID: WorkflowJobID,
        lastCompletedInputOrdinal: Int64
    ) throws {
        guard let prepared = preparedByJobID[jobID] else {
            throw WorkflowApplicationControllerErrorV4.noActiveJob
        }
        try Self.validateTerminalSourceCompleteness(
            sourceSampleCount: prepared.primarySourceSampleCount,
            lastCompletedInputOrdinal: lastCompletedInputOrdinal
        )
    }

    func preparedAssemblyTimeline(
        jobID: WorkflowJobID
    ) async throws -> WorkflowApplicationAssemblyTimelineDescriptorV4 {
        guard let prepared = preparedByJobID[jobID] else {
            throw WorkflowApplicationControllerErrorV4.noActiveJob
        }
        let planID = try WorkflowPlanID(
            prepared.plan.ashPlan.planSHA256.rawValue
        )
        guard prepared.timeline.assembly.planID == planID else {
            throw WorkflowApplicationControllerErrorV4
                .preparedPlanChanged(jobID)
        }
        return prepared.timeline.assembly
    }

    func finalizePreparedOutput(
        jobID: WorkflowJobID,
        request: UpscaleRequest,
        assembledVideoURL: URL,
        publicationURL: URL,
        migrationTemporaryURL: URL,
        cancellation: ProcessingCancellation,
        progress: @escaping @Sendable (UpscaleProgress) -> Void
    ) async throws -> WorkflowApplicationFinalizedOutputV4 {
        guard let prepared = preparedByJobID[jobID] else {
            throw WorkflowApplicationControllerErrorV4.noActiveJob
        }
        let migrationCancellation = AVFoundationTrackMigrationCancellationV4()
        let monitor = Task {
            while !Task.isCancelled {
                do {
                    try cancellation.check()
                } catch {
                    migrationCancellation.cancel()
                    return
                }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        defer { monitor.cancel() }
        do {
            let result = try await AVFoundationTrackMigrationExecutorV4().execute(
                .init(
                    sourceURL: request.inputURL,
                    destinationURL: publicationURL,
                    temporaryURL: migrationTemporaryURL,
                    outputFileType: .mov,
                    overwriteExistingFile: false,
                    sourceGraph: prepared.plan.sourceGraph,
                    identifiedPlan: prepared.plan.trackPlan,
                    blueprint: prepared.plan.migrationBlueprint,
                    nonVideoTranscodeHooks:
                        prepared.plan.nonVideoTranscodeHooks,
                    processedVideoReplacement: .init(
                        trackID: prepared.plan.executionPrimaryGraphTrack.identity.stableID,
                        sourceURL: assembledVideoURL
                    ),
                    softwareExecution: prepared.plan.softwareExecution
                ),
                cancellation: migrationCancellation,
                progress: { state in
                    progress(UpscaleProgress(
                        phase: state.stage == .completed
                            ? .validatingOutput : .finalizing,
                        fractionCompleted: state.stage == .completed ? 1 : nil,
                        processedFrameCount: Int(
                            clamping: state.migratedSampleCount
                        ),
                        processedTime: nil,
                        duration: prepared.source.duration,
                        actualBackendID: prepared.backend.actualBackendID
                    ))
                }
            )
            return WorkflowApplicationFinalizedOutputV4(
                destinationURL: result.destinationURL,
                verification: try WorkflowApplicationMigrationVerificationV4(
                    result
                )
            )
        } catch AVFoundationTrackMigrationExecutorV4Error.cancelled {
            throw MirmirError.cancelled
        }
    }

    func inspectCompletion(
        request: UpscaleRequest,
        checkpoint: WorkflowCheckpointDocumentV4,
        segmentResult: UpscaleResult?,
        processingDurationSeconds: TimeInterval
    ) async throws -> WorkflowApplicationCompletionV4 {
        let jobID = checkpoint.body.compatibility.jobBinding.jobID
        guard let prepared = preparedByJobID[jobID] else {
            throw WorkflowApplicationControllerErrorV4.noActiveJob
        }
        let source = try await videoProbe.probe(url: request.inputURL)
        let output = try await videoProbe.probe(url: request.outputURL)
        guard let encodedSize = output.geometry.encodedSize,
              encodedSize.width.isFinite,
              encodedSize.height.isFinite,
              let width = Int(exactly: encodedSize.width.rounded()),
              let height = Int(exactly: encodedSize.height.rounded()),
              width == request.targetWidth,
              height == request.targetHeight else {
            throw WorkflowApplicationControllerErrorV4.invalidAssembledOutput(
                "the encoded raster does not match the durable request"
            )
        }
        let videoFrames = checkpoint.body.trackProgress
            .filter { $0.kind == .video }
            .reduce(UInt64(0)) { partial, track in
                partial.addingReportingOverflow(
                    track.nextOutputSampleIndex
                ).partialValue
            }
        let plannedAudio = prepared.plan.trackPlan.plan.tracks.filter {
            $0.source.kind == .audio && $0.expectedOutput != nil
        }
        let audioResult: AudioOutputResult
        if !request.preserveAudio {
            audioResult = .omitted
        } else if plannedAudio.isEmpty {
            audioResult = .absent
        } else if plannedAudio.contains(where: { $0.action == .transcode }) {
            audioResult = .transcoded
        } else {
            audioResult = .preserved
        }
        let result = UpscaleResult(
            outputURL: request.outputURL,
            actualBackendID: request.backendID,
            encodedWidth: width,
            encodedHeight: height,
            durationSeconds: CMTimeGetSeconds(output.duration),
            outputCodec: request.outputCodec,
            audioResult: audioResult,
            processedFrameCount: segmentResult?.processedFrameCount
                ?? Int(clamping: videoFrames),
            processingDurationSeconds: max(
                segmentResult?.processingDurationSeconds ?? 0,
                processingDurationSeconds
            )
        )
        return WorkflowApplicationCompletionV4(
            source: source,
            result: result
        )
    }

    func abandonPrepared(jobID: WorkflowJobID) async {
        guard let prepared = preparedByJobID.removeValue(forKey: jobID) else {
            return
        }
        prepared.cancelSourceProgress()
        await prepared.plan.finishProcessingBackend(
            planningBackend: prepared.backend
        )
    }
}

extension WorkflowDeterministicApplicationEngineV4 {
    nonisolated static func primarySourceSampleCount(
        sourceURL: URL,
        primaryTrackOrdinal: Int,
        cancellation: ProcessingCancellation,
        afterReadingSample: (@Sendable () -> Void)? = nil
    ) async throws -> UInt64 {
        try cancellation.check()
        let asset = try await NativeMediaInputAssetResolverV4.asset(
            url: sourceURL,
            cancellation: cancellation
        )
        let tracks = try await asset.load(.tracks)
        try cancellation.check()
        guard tracks.indices.contains(primaryTrackOrdinal),
              tracks[primaryTrackOrdinal].mediaType == .video else {
            throw WorkflowApplicationControllerErrorV4
                .invalidAssembledOutput(
                    "the primary source video track is unavailable"
                )
        }
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw WorkflowApplicationControllerErrorV4
                .invalidAssembledOutput(
                    "the primary source sample inventory could not be opened"
                )
        }
        let output = AVAssetReaderTrackOutput(
            track: tracks[primaryTrackOrdinal],
            outputSettings: nil
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw WorkflowApplicationControllerErrorV4
                .invalidAssembledOutput(
                    "the primary source sample inventory was rejected"
                )
        }
        reader.add(output)
        if let context = OriginalSoftwareMediaContext.associated(with: asset),
           context.timings.indices.contains(primaryTrackOrdinal),
           let first = context.timings[primaryTrackOrdinal].selectedStart,
           let end = context.timings[primaryTrackOrdinal].selectedEnd {
            let selectedStart = try context.sharedOrigin.normalize(first).adding(SoftwareVirtualCarrier.sharedWorkingOffset(context))
            reader.timeRange = CMTimeRange(start: try cm(selectedStart), duration: try cm(end.subtracting(first)))
        }
        guard reader.startReading() else {
            throw WorkflowApplicationControllerErrorV4
                .invalidAssembledOutput(
                    "the primary source sample inventory could not start"
                )
        }
        defer {
            if reader.status == .reading {
                reader.cancelReading()
            }
        }

        var sampleCount: UInt64 = 0
        while true {
            try cancellation.check()
            guard let sample = output.copyNextSampleBuffer() else { break }
            afterReadingSample?()
            try cancellation.check()
            let containedSampleCount = CMSampleBufferGetNumSamples(sample)
            guard containedSampleCount >= 0,
                  let containedSampleCount = UInt64(
                    exactly: containedSampleCount
                  ) else {
                reader.cancelReading()
                throw WorkflowApplicationControllerErrorV4
                    .invalidAssembledOutput(
                        "the primary source sample count is invalid"
                    )
            }
            if containedSampleCount == 0 { continue }
            let addition = sampleCount.addingReportingOverflow(
                containedSampleCount
            )
            guard !addition.overflow else {
                reader.cancelReading()
                throw WorkflowApplicationControllerErrorV4
                    .invalidAssembledOutput(
                        "the primary source sample count overflowed"
                    )
            }
            sampleCount = addition.partialValue
        }
        try cancellation.check()
        guard reader.status == .completed, sampleCount > 0 else {
            throw WorkflowApplicationControllerErrorV4
                .invalidAssembledOutput(
                    "the primary source sample inventory is incomplete"
                )
        }
        return sampleCount
    }

    nonisolated static func validateTerminalSourceCompleteness(
        sourceSampleCount: UInt64,
        lastCompletedInputOrdinal: Int64
    ) throws {
        guard sourceSampleCount > 0,
              lastCompletedInputOrdinal >= 0 else {
            throw WorkflowApplicationControllerErrorV4
                .invalidAssembledOutput(
                    "the terminal primary source sample inventory is invalid"
                )
        }
        let processedSampleCount = UInt64(lastCompletedInputOrdinal) + 1
        guard processedSampleCount == sourceSampleCount else {
            throw WorkflowApplicationControllerErrorV4
                .invalidAssembledOutput(
                    "the terminal primary video decoded "
                        + "\(processedSampleCount) of \(sourceSampleCount) "
                        + "source samples"
                )
        }
    }
}

private extension WorkflowDeterministicApplicationEngineV4 {
    private nonisolated static func preparedTimeline(
        plan: DeterministicV4PreparedAssetPlan,
        binding: WorkflowVerifiedPreparedPlanBindingV4,
        jobID: WorkflowJobID
    ) throws -> PreparedTimeline {
        let plannedPrimary = plan.trackPlan.plan.tracks.filter {
            $0.source.identity.stableID
                == plan.executionPrimaryGraphTrack.identity.stableID
        }
        guard let primaryVideo = plan.executionPrimaryCanonicalTrack.video,
              plannedPrimary.count == 1,
              let planned = plannedPrimary.first,
              planned.action == .process,
              planned.source.timeRange.start >= .zero else {
            throw WorkflowApplicationControllerErrorV4
                .preparedPlanChanged(jobID)
        }

        if !primaryVideo.color.dynamicHDRMetadata.isEmpty {
            let mapping: DeterministicV4PrimaryTimelineMappingV4
            do {
                mapping = try DeterministicV4PrimaryTimelineMappingV4(
                    plannedPrimary: planned
                )
            } catch {
                throw WorkflowApplicationControllerErrorV4
                    .preparedPlanChanged(jobID)
            }
            return PreparedTimeline(
                primaryMapping: mapping,
                assembly: WorkflowApplicationAssemblyTimelineDescriptorV4(
                    planID: binding.planID,
                    mediaTimelineStart: try workflowTime(
                        mapping.mediaRange.start,
                        jobID: jobID
                    ),
                    outputTimelineStart: try workflowTime(
                        mapping.targetRange.start,
                        jobID: jobID
                    )
                )
            )
        }

        return PreparedTimeline(
            primaryMapping: nil,
            assembly: WorkflowApplicationAssemblyTimelineDescriptorV4(
                planID: binding.planID,
                mediaTimelineStart: try workflowTime(
                    plan.executionPrimaryPresentationStart,
                    jobID: jobID
                ),
                outputTimelineStart: try WorkflowMediaTimeV4(
                    value: 0,
                    timescale: 1
                )
            )
        )
    }

    nonisolated static func workflowTime(
        _ time: ExactRationalV4,
        jobID: WorkflowJobID
    ) throws -> WorkflowMediaTimeV4 {
        guard time.denominator <= Int64(Int32.max),
              let timescale = Int32(exactly: time.denominator) else {
            throw WorkflowApplicationControllerErrorV4
                .preparedPlanChanged(jobID)
        }
        return try WorkflowMediaTimeV4(
            value: time.numerator,
            timescale: timescale
        )
    }

    private func checkpointTrackProgress(
        prepared: PreparedExecution,
        segment: DeterministicV4MediaSegmentResultV4,
        previousCheckpoint: WorkflowCheckpointDocumentV4?
    ) async throws -> [WorkflowTrackProgressV4] {
        let previous = Dictionary(
            uniqueKeysWithValues: (previousCheckpoint?.body.trackProgress ?? [])
                .map { ($0.trackID, $0) }
        )
        let plannedByID = Dictionary(
            uniqueKeysWithValues: prepared.plan.trackPlan.plan.tracks.map {
                ($0.source.identity.stableID, $0)
            }
        )
        var result: [WorkflowTrackProgressV4] = []
        for node in prepared.plan.executionGraph.tracks {
            let id = node.identity.stableID.rawValue
            let kind = checkpointKind(node.kind)
            if node.identity.stableID
                == prepared.plan.executionPrimaryGraphTrack.identity.stableID {
                let priorOutput = previous[id]?.nextOutputSampleIndex ?? 0
                result.append(try WorkflowTrackProgressV4(
                    trackID: id,
                    kind: kind,
                    nextInputSampleIndex: UInt64(
                        segment.lastCompletedInputOrdinal + 1
                    ),
                    nextOutputSampleIndex: priorOutput + UInt64(
                        segment.outputSampleCount
                    ),
                    lastInputTime: segment.endTimeExclusive,
                    lastOutputTime: segment.endTimeExclusive,
                    isComplete: segment.terminal
                ))
                continue
            }
            guard let cursor = prepared.sourceProgressCursors[
                node.identity.stableID
            ] else {
                throw WorkflowApplicationControllerErrorV4
                    .invalidAssembledOutput(
                        "source progress cursor inventory changed"
                    )
            }
            let observed = try cursor.progress(
                through: segment.endTimeExclusive
            )
            let action = plannedByID[node.identity.stableID]?.action
            result.append(try WorkflowTrackProgressV4(
                trackID: id,
                kind: kind,
                nextInputSampleIndex: observed.count,
                nextOutputSampleIndex: 0,
                lastInputTime: observed.lastEnd,
                lastOutputTime: nil,
                isComplete: segment.terminal && action == .dropWithConsent
            ))
        }
        return result
    }

    func makeSourceProgressCursors(
        sourceURL: URL,
        plan: DeterministicV4PreparedAssetPlan,
        cancellation: ProcessingCancellation
    ) async throws -> [
        MediaTrackStableIDV4: WorkflowSourceTrackProgressCursorV4
    ] {
        let asset = try await NativeMediaInputAssetResolverV4.asset(
            url: sourceURL,
            cancellation: cancellation
        )
        let assetTracks = try await asset.load(.tracks)
        guard assetTracks.count == plan.executionGraph.tracks.count else {
            throw WorkflowApplicationControllerErrorV4
                .invalidAssembledOutput("source track inventory changed")
        }
        var cursors: [
            MediaTrackStableIDV4: WorkflowSourceTrackProgressCursorV4
        ] = [:]
        do {
            for (node, track) in zip(plan.executionGraph.tracks, assetTracks) {
                guard node.identity.stableID
                        != plan.executionPrimaryGraphTrack.identity.stableID else {
                    continue
                }
                guard cursors[node.identity.stableID] == nil else {
                    throw WorkflowApplicationControllerErrorV4
                        .invalidAssembledOutput(
                            "source progress track identity was duplicated"
                        )
                }
                let selectedRange: CMTimeRange?
                if let row = plan.softwareExecution?.policy.tracks.first(where: { $0.originalTrackID == node.identity.stableID }) {
                    selectedRange = CMTimeRange(start: try cm(row.executionStart), duration: try cm(row.executionEnd.subtracting(row.executionStart)))
                } else { selectedRange = nil }
                cursors[node.identity.stableID] = try
                    WorkflowSourceTrackProgressCursorV4(
                        asset: asset,
                        track: track,
                        selectedRange: selectedRange
                    )
            }
            return cursors
        } catch {
            cursors.values.forEach { $0.cancel() }
            throw error
        }
    }

    nonisolated func checkpointKind(
        _ kind: MediaTrackKindV4
    ) -> WorkflowCheckpointTrackKindV4 {
        switch kind {
        case .video: .video
        case .audio: .audio
        case .subtitle: .subtitle
        case .caption: .caption
        case .timecode: .timecode
        case .timedMetadata: .timedMetadata
        case .chapter: .chapter
        case .auxiliary, .unknown: .auxiliary
        }
    }

    func resolvedRequest(
        _ request: UpscaleRequest,
        source: VideoInfo
    ) async throws -> UpscaleRequest {
        let snapshot = await backendCatalog.snapshot(
            for: source,
            targetSize: request.targetSize,
            environment: runtimeEnvironment
        )
        let resolution = snapshot.resolution(for: request.backendID)
        guard resolution.availability == .available,
              let actualBackendID = resolution.actualBackendID else {
            throw WorkflowApplicationControllerErrorV4.backendUnavailable(
                request.backendID,
                resolution.availability.statusText
            )
        }
        return UpscaleRequest(
            inputURL: request.inputURL,
            outputURL: request.outputURL,
            backendID: actualBackendID,
            targetWidth: request.targetWidth,
            targetHeight: request.targetHeight,
            outputCodec: request.outputCodec,
            preserveAudio: request.preserveAudio,
            overwriteExistingFile: request.overwriteExistingFile
        )
    }

    func preparedBackend(
        request: UpscaleRequest,
        source: VideoInfo
    ) async throws -> any PreparedDeterministicV4RuntimePlanningBackend {
        guard request.backendID == .mirmirDeterministicCPU
                || request.backendID == .mirmirDeterministicMetal else {
            throw WorkflowApplicationControllerErrorV4
                .deterministicBackendRequired(request.backendID)
        }
        let prepared = try await backendCatalog.prepare(
            backendID: request.backendID,
            request: BackendPreparationRequest(
                source: source,
                targetSize: request.targetSize
            ),
            environment: runtimeEnvironment
        )
        guard prepared.actualBackendID == request.backendID,
              let deterministic = prepared
                as? any PreparedDeterministicV4RuntimePlanningBackend else {
            try? await prepared.finish()
            throw WorkflowApplicationControllerErrorV4
                .preparedBackendMismatch(request.backendID)
        }
        return deterministic
    }
}

actor WorkflowApplicationCoordinatorV4: WorkflowApplicationControllingV4 {
    private struct ActiveExecution: Sendable {
        let dispatch: WorkflowQueueDispatchReceiptV4
        let cancellation: ProcessingCancellation
        let attemptID: WorkflowAttemptID
        let snapshotHandler: @Sendable (
            WorkflowApplicationQueueSnapshotV4
        ) -> Void
        var lifecycle: WorkflowJobLifecycle
        var pauseRequested: Bool
        var cancelRequested: Bool
        var heartbeatFailure: String?
    }

    private let queue: WorkflowApplicationQueueV4
    private let engine: any WorkflowApplicationDeterministicExecutingV4
    private let cacheLocationAccess: WorkflowCacheLocationAccessV4?
    private let derivedInputCacheRootURL: URL?
    private let maximumInputFramesPerBoundary: Int
    private let processingActivityFactory: MirmirProcessingActivityFactory
    private var active: ActiveExecution?
    private var heartbeatTask: Task<Void, Never>?
    private var drainTask: Task<Void, Never>?
    private var publicationRecoveryTask: Task<Void, Never>?
    private var publicationRecoveryRetryFailureReported = false
    private var observer = WorkflowApplicationObserverV4.none
    private var currentDrainJobID: WorkflowJobID?
    private var completionWaiters: [
        WorkflowJobID:
            [CheckedContinuation<WorkflowApplicationRunOutcomeV4, Error>]
    ] = [:]
    private var waiterProgressHandlers: [
        WorkflowJobID: @Sendable (UpscaleProgress) -> Void
    ] = [:]
    private var waiterSnapshotHandlers: [
        WorkflowJobID:
            @Sendable (WorkflowApplicationQueueSnapshotV4) -> Void
    ] = [:]
    private var drainRescheduleRequested = false

    private static let dispatchCapacityRetryNanoseconds: UInt64 =
        1_000_000_000

    init(
        queue: WorkflowApplicationQueueV4,
        engine: any WorkflowApplicationDeterministicExecutingV4,
        maximumInputFramesPerBoundary: Int = 60,
        cacheLocationAccess: WorkflowCacheLocationAccessV4? = nil,
        derivedInputCacheRootURL: URL? = nil,
        processingActivityFactory: @escaping MirmirProcessingActivityFactory =
            MirmirProcessingActivity.begin
    ) {
        precondition(maximumInputFramesPerBoundary > 0)
        self.queue = queue
        self.engine = engine
        self.maximumInputFramesPerBoundary = maximumInputFramesPerBoundary
        self.cacheLocationAccess = cacheLocationAccess
        self.derivedInputCacheRootURL = derivedInputCacheRootURL
        self.processingActivityFactory = processingActivityFactory
    }

    static func live(
        applicationIdentifier: String,
        videoProbe: any VideoProbing,
        backendCatalog: UpscaleBackendCatalog,
        runtimeEnvironment: RuntimeEnvironment
    ) throws -> WorkflowApplicationCoordinatorV4 {
        let store = try WorkflowCacheLocationStoreV4(
            applicationIdentifier: applicationIdentifier
        )
        return try live(
            configuration: store.configuration(),
            videoProbe: videoProbe,
            backendCatalog: backendCatalog,
            runtimeEnvironment: runtimeEnvironment
        )
    }

    static func live(
        configuration: WorkflowCacheLocationConfigurationV4,
        videoProbe: any VideoProbing,
        backendCatalog: UpscaleBackendCatalog,
        runtimeEnvironment: RuntimeEnvironment
    ) throws -> WorkflowApplicationCoordinatorV4 {
        let queue = try WorkflowApplicationQueueV4(
            trustedRootURL: configuration.workflowRootURL,
            workerID: try WorkflowWorkerIDV4(
                "application-worker-\(UUID().uuidString.lowercased())"
            )
        )
        return WorkflowApplicationCoordinatorV4(
            queue: queue,
            engine: WorkflowDeterministicApplicationEngineV4(
                videoProbe: videoProbe,
                backendCatalog: backendCatalog,
                runtimeEnvironment: runtimeEnvironment
            ),
            cacheLocationAccess: configuration.access,
            derivedInputCacheRootURL: configuration.workflowRootURL
                .appendingPathComponent("cache-v4/native-inputs-v1", isDirectory: true)
        )
    }

    func launch() async throws -> WorkflowApplicationLaunchSnapshotV4 {
        if let derivedInputCacheRootURL {
            try await NativeMediaInputAssetResolverV4.configureCacheRoot(
                derivedInputCacheRootURL
            )
        }
        let publicationRecoveryDeferred = try await
            recoverInterruptedPublications()
        let snapshot = try await queue.launchSnapshot(
            commandKey: try Self.commandKey(stage: "launch-recovery")
        )
        try await queue.cleanupCompletedApplicationPublications()
        try await queue.cleanupTerminalApplicationSourceSnapshots()
        observer.snapshot(snapshot.queue)
        if publicationRecoveryDeferred {
            schedulePublicationRecoveryRetry()
        }
        scheduleDrain()
        return snapshot
    }

    func installObserver(_ observer: WorkflowApplicationObserverV4) async {
        self.observer = observer
    }

    func queueSnapshot() async throws -> WorkflowApplicationQueueSnapshotV4 {
        try await queue.queueSnapshot()
    }

    func enqueue(
        request: UpscaleRequest,
        priority: Int32
    ) async throws -> WorkflowApplicationEnqueueReceiptV4 {
        let receipt = try await enqueuePrepared(
            request: request,
            priority: priority
        )
        scheduleDrain()
        return receipt
    }

    func setPriority(jobID: WorkflowJobID, value: Int32) async throws {
        try await queue.setApplicationJobPriority(jobID: jobID, value: value)
        await emitSnapshot(to: observer.snapshot)
    }

    func move(
        jobID: WorkflowJobID,
        direction: WorkflowApplicationQueueMoveV4
    ) async throws {
        try await queue.moveApplicationJob(
            jobID: jobID,
            direction: direction
        )
        await emitSnapshot(to: observer.snapshot)
    }

    func deleteCachedJob(jobID: WorkflowJobID) async throws {
        if active?.dispatch.claim.jobID == jobID {
            throw WorkflowApplicationQueueErrorV4.jobDeletionNotAllowed(
                jobID: jobID,
                lifecycle: active?.lifecycle ?? .running
            )
        }
        try await queue.deleteCachedJob(jobID: jobID)
        await emitSnapshot(to: observer.snapshot)
    }

    func deleteCachedJobs(
        selection: WorkflowCachedJobSelectionV4
    ) async throws -> Int {
        if selection != .finished, let active {
            throw WorkflowApplicationQueueErrorV4.cacheClearBlocked([
                active.dispatch.claim.jobID
            ])
        }
        let deleted = try await queue.deleteCachedJobs(selection: selection)
        await emitSnapshot(to: observer.snapshot)
        return deleted
    }

    func clearCache() async throws -> WorkflowCacheClearResultV4 {
        if let active {
            throw WorkflowApplicationQueueErrorV4.cacheClearBlocked([
                active.dispatch.claim.jobID
            ])
        }
        let result = try await queue.clearApplicationCache()
        let imports = derivedInputCacheRootURL == nil
            ? 0 : try await NativeMediaInputAssetResolverV4.clearInactiveCache().entryCount
        await emitSnapshot(to: observer.snapshot)
        return WorkflowCacheClearResultV4(
            deletedJobCount: result.deletedJobCount,
            deletedArtifactCount: result.deletedArtifactCount + imports
        )
    }

    func submit(
        request: UpscaleRequest,
        progress: @escaping @Sendable (UpscaleProgress) -> Void,
        snapshot: @escaping @Sendable (
            WorkflowApplicationQueueSnapshotV4
        ) -> Void
    ) async throws -> WorkflowApplicationRunOutcomeV4 {
        let receipt = try await enqueuePrepared(
            request: request,
            priority: 0
        )
        let jobID = receipt.specification.jobID
        waiterProgressHandlers[jobID] = progress
        waiterSnapshotHandlers[jobID] = snapshot
        return try await withCheckedThrowingContinuation { continuation in
            completionWaiters[jobID, default: []].append(continuation)
            scheduleDrain()
        }
    }

    func requestPause() async throws {
        guard var current = active else {
            throw WorkflowApplicationControllerErrorV4.noActiveJob
        }
        switch current.lifecycle {
        case .probing, .planned:
            current.pauseRequested = true
            active = current
        case .running:
            _ = try await queue.requestApplicationPause(
                current.dispatch,
                commandKey: try Self.commandKey(
                    stage: "pause-request",
                    jobID: current.dispatch.claim.jobID
                )
            )
            current.lifecycle = .pausing
            current.pauseRequested = true
            active = current
            await emitSnapshot(to: current.snapshotHandler)
        case .pausing:
            current.pauseRequested = true
            active = current
        default:
            throw WorkflowApplicationControllerErrorV4.pauseNotAllowed(
                current.lifecycle
            )
        }
    }

    func cancelActive() async throws {
        guard var current = active else {
            throw WorkflowApplicationControllerErrorV4.noActiveJob
        }
        guard current.lifecycle != .committing,
              !current.lifecycle.isTerminal else {
            throw WorkflowApplicationControllerErrorV4
                .cancellationNotAllowed(current.lifecycle)
        }
        current.cancelRequested = true
        current.cancellation.cancel()
        active = current
    }

    func resume(
        jobID: WorkflowJobID,
        progress: @escaping @Sendable (UpscaleProgress) -> Void,
        snapshot: @escaping @Sendable (
            WorkflowApplicationQueueSnapshotV4
        ) -> Void
    ) async throws -> WorkflowApplicationRunOutcomeV4 {
        guard active == nil else {
            throw WorkflowApplicationControllerErrorV4
                .dispatchCapacityExhausted
        }
        let processingActivity = processingActivityFactory(
            "Resuming an upscale job"
        )
        defer { processingActivity.end() }
        let attemptID = try Self.attemptID(jobID: jobID)
        let dispatch = try await queue.resumeApplicationJob(
            jobID: jobID,
            commandKey: try Self.commandKey(
                stage: "resume",
                jobID: jobID
            ),
            attemptID: attemptID
        )
        let cancellation = ProcessingCancellation()
        active = ActiveExecution(
            dispatch: dispatch,
            cancellation: cancellation,
            attemptID: attemptID,
            snapshotHandler: snapshot,
            lifecycle: .running,
            pauseRequested: false,
            cancelRequested: false,
            heartbeatFailure: nil
        )
        startHeartbeat(jobID: jobID)
        await emitSnapshot(to: snapshot)

        let activation = await queue.activate(jobID: jobID)
        guard case .active(let activated) = activation else {
            let failure: WorkflowApplicationActivationFailureV4
            if case .blocked(let blocked) = activation {
                failure = blocked
            } else {
                failure = .jobNotFound
            }
            let error = WorkflowApplicationControllerErrorV4
                .activationBlocked(failure)
            await terminateActive(error: error, containmentRequired: true)
            throw error
        }
        defer { activated.close() }
        do {
            try activated.revalidateAll()
            guard let checkpoint = try await queue
                .compatibleApplicationCheckpoint(
                    jobID: jobID,
                    outputContractID:
                        activated.preparedPlanBinding.outputContractID,
                    sourceSnapshotIdentityID:
                        activated.sourceSnapshot.identityID
                ) else {
                throw WorkflowApplicationControllerErrorV4
                    .checkpointMissing(jobID)
            }
            let source = try await engine.revalidateAndPrepare(
                jobID: jobID,
                request: activated.request,
                expectedBinding: activated.preparedPlanBinding,
                cancellation: cancellation
            )
            let payload = try await queue
                .applicationCheckpointResumePayload(checkpoint)
            try await engine.restorePrepared(
                jobID: jobID,
                temporalCheckpoint: payload.temporalCheckpoint,
                lastCompletedInputOrdinal:
                    payload.verification.lastCompletedInputOrdinal
            )
            let outcome = try await continueProcessing(
                dispatch: dispatch,
                attemptID: attemptID,
                activated: activated,
                source: source,
                checkpoint: checkpoint,
                startingInputFrameIndex: Int(
                    payload.verification.lastCompletedInputOrdinal + 1
                ),
                processingDurationSeconds: 0,
                progress: progress,
                snapshot: snapshot
            )
            stopHeartbeat()
            active = nil
            await emitSnapshot(to: snapshot)
            scheduleDrain()
            return outcome
        } catch {
            await terminateActive(
                error: error,
                containmentRequired: Self.requiresContainment(error)
            )
            scheduleDrain()
            throw error
        }
    }
}

extension WorkflowApplicationCoordinatorV4 {
    static func recordFinalizeDiagnostic(
        executionContext: MirmirDiagnosticExecutionContext,
        nextInputSampleIndex: Int64?,
        segmentOrdinal: Int,
        segmentCount: Int,
        isComplete: Bool,
        checkpointURL: URL,
        destinationURL: URL,
        error: Error?
    ) {
        MirmirDiagnosticScope.recorder.recordCheckpoint(
            subsystem: "durable_publication",
            operation: "finalize",
            executionContext: executionContext,
            durable: .init(
                nextInputSampleIndex: nextInputSampleIndex,
                segmentOrdinal: segmentOrdinal,
                segmentCount: segmentCount,
                isComplete: isComplete,
                checkpointSchema: "workflow-checkpoint-v4-v3",
                publishAttempted: true,
                atomicPublicationFailed: error.map {
                    MirmirDiagnosticRecorder.failureCode($0)
                        == "atomic_publication_failed"
                        || MirmirDiagnosticRecorder.posixErrno($0) == ENOSPC
                } ?? false,
                checkpointURL: checkpointURL
            ),
            destinationURL: destinationURL,
            error: error
        )
    }

    func recordPublicationRecoveryRetryFailureIfNeeded(
        _ error: Error,
        recorder: MirmirDiagnosticRecorder
    ) {
        guard !publicationRecoveryRetryFailureReported else { return }
        publicationRecoveryRetryFailureReported = true
        recorder.enqueue(
            severity: .error,
            subsystem: "workflow_application_coordinator",
            operation: "retry_publication_recovery",
            code: "publication_recovery_retry_failed",
            error: error
        )
    }

    func recordPublicationRecoveryRetryRecoveredIfNeeded(
        recorder: MirmirDiagnosticRecorder
    ) {
        guard publicationRecoveryRetryFailureReported else { return }
        publicationRecoveryRetryFailureReported = false
        recorder.enqueue(
            severity: .notice,
            subsystem: "workflow_application_coordinator",
            operation: "retry_publication_recovery",
            code: "publication_recovery_retry_recovered"
        )
    }
}

private extension WorkflowApplicationCoordinatorV4 {
    struct ClaimedOutcome: Sendable {
        let jobID: WorkflowJobID
        let outcome: WorkflowApplicationRunOutcomeV4
    }

    func recoverInterruptedPublications() async throws -> Bool {
        let candidates = try await queue
            .applicationPublicationRecoveryCandidates()
        var deferred = false
        for candidate in candidates {
            guard active == nil else {
                deferred = true
                continue
            }
            let commandKey = try Self.commandKey(
                stage: "publication-recovery",
                jobID: candidate.jobID
            )
            let claim = try await queue.beginApplicationPublicationRecovery(
                jobID: candidate.jobID,
                commandKey: commandKey
            )
            let dispatch: WorkflowQueueDispatchReceiptV4
            switch claim {
            case .claimed(let receipt):
                dispatch = receipt
            case .deferred:
                deferred = true
                continue
            case .terminal, .contained:
                continue
            }

            let processingActivity = processingActivityFactory(
                "Recovering an upscale publication"
            )
            defer { processingActivity.end() }
            let cancellation = ProcessingCancellation()
            active = ActiveExecution(
                dispatch: dispatch,
                cancellation: cancellation,
                attemptID: try Self.attemptID(jobID: candidate.jobID),
                snapshotHandler: observer.snapshot,
                lifecycle: .recovering,
                pauseRequested: false,
                cancelRequested: false,
                heartbeatFailure: nil
            )
            startHeartbeat(jobID: candidate.jobID)
            await emitSnapshot(to: observer.snapshot)
            do {
                let completion = try await recoverInterruptedPublication(
                    dispatch: dispatch,
                    cancellation: cancellation
                )
                try throwIfActiveControlFailed()
                _ = try await queue.completeApplicationPublicationRecovery(
                    dispatch,
                    target: .completed,
                    commandKey: commandKey
                )
                stopHeartbeat()
                active = nil
                await engine.abandonPrepared(jobID: candidate.jobID)
                try? await queue.cleanupTerminalApplicationSourceSnapshots()
                observer.execution(
                    .finished(
                        jobID: candidate.jobID,
                        outcome: .completed(completion)
                    )
                )
                await emitSnapshot(to: observer.snapshot)
            } catch is CancellationError {
                await terminateActive(
                    error: CancellationError(),
                    containmentRequired: false
                )
            } catch let error as MirmirError where error == .cancelled {
                await terminateActive(
                    error: error,
                    containmentRequired: false
                )
            } catch {
                MirmirDiagnosticScope.recorder.enqueue(
                    severity: .error,
                    subsystem: "workflow_application_coordinator",
                    operation: "recover_interrupted_publication",
                    code: "publication_recovery_failed",
                    fields: (try? [
                        MirmirDiagnosticRecorder.textField(
                            "job_id_context",
                            candidate.jobID.rawValue
                        )
                    ]) ?? [],
                    error: error
                )
                await terminateActive(
                    error: error,
                    containmentRequired: true
                )
                observer.execution(
                    .failed(
                        jobID: candidate.jobID,
                        message: error.localizedDescription
                    )
                )
            }
        }
        return deferred
    }

    func recoverInterruptedPublication(
        dispatch: WorkflowQueueDispatchReceiptV4,
        cancellation: ProcessingCancellation
    ) async throws -> WorkflowApplicationCompletionV4 {
        let jobID = dispatch.claim.jobID
        let activation = await queue.activate(jobID: jobID)
        guard case .active(let activated) = activation else {
            let failure: WorkflowApplicationActivationFailureV4
            if case .blocked(let blocked) = activation {
                failure = blocked
            } else {
                failure = .jobNotFound
            }
            throw WorkflowApplicationControllerErrorV4
                .activationBlocked(failure)
        }
        defer { activated.close() }
        try activated.revalidateAll()
        guard let checkpoint = try await queue
            .compatibleApplicationCheckpoint(
                jobID: jobID,
                outputContractID:
                    activated.preparedPlanBinding.outputContractID,
                sourceSnapshotIdentityID:
                    activated.sourceSnapshot.identityID
            ), checkpointIsTerminal(checkpoint) else {
            throw WorkflowApplicationControllerErrorV4
                .checkpointMissing(jobID)
        }
        let verification = try await queue.verifyApplicationCheckpoint(
            checkpoint
        )
        _ = try await engine.revalidateAndPrepare(
            jobID: jobID,
            request: activated.request,
            expectedBinding: activated.preparedPlanBinding,
            cancellation: cancellation
        )
        try await engine.validateTerminalSourceCompleteness(
            jobID: jobID,
            lastCompletedInputOrdinal:
                verification.lastCompletedInputOrdinal
        )
        try throwIfActiveControlFailed()

        let intent = try await queue.prepareApplicationPublication(
            activated: activated,
            checkpoint: checkpoint
        )
        var state = try await queue.applicationPublicationState(jobID: jobID)
        if state?.stageIsVerified != true {
            try await queue.discardApplicationUnverifiedPublicationArtifacts(
                intent,
                activated: activated
            )
            let assembledVideoURL = try await queue
                .applicationAssembledVideoURL(
                    jobID: jobID,
                    checkpointID: checkpoint.body.checkpointID
                )
            do {
                let assemblyTimeline = try await engine
                    .preparedAssemblyTimeline(jobID: jobID)
                _ = try await queue.assembleApplicationCheckpoint(
                    checkpoint,
                    timeline: assemblyTimeline,
                    destinationURL: assembledVideoURL,
                    overwriteExistingFile: false,
                    structuralCreationDateSourceURL: activated.request.inputURL
                )
                try throwIfActiveControlFailed()
                let finalized = try await engine.finalizePreparedOutput(
                    jobID: jobID,
                    request: activated.request,
                    assembledVideoURL: assembledVideoURL,
                    publicationURL: try await queue
                        .applicationPublicationStagingURL(
                            intent,
                            activated: activated
                        ),
                    migrationTemporaryURL: try await queue
                        .applicationPublicationMigrationTemporaryURL(
                            intent,
                            activated: activated
                        ),
                    cancellation: cancellation,
                    progress: { [weak self] progress in
                        Task {
                            await self?.forwardProgress(
                                jobID: jobID,
                                progress: progress
                            )
                        }
                    }
                )
                _ = try await queue.recordApplicationStagedPublication(
                    intent,
                    finalized: finalized,
                    activated: activated
                )
                try await queue.removeApplicationWorkingArtifact(
                    assembledVideoURL
                )
            } catch {
                try? await queue.removeApplicationWorkingArtifact(
                    assembledVideoURL
                )
                throw error
            }
            state = try await queue.applicationPublicationState(jobID: jobID)
        }
        guard state?.stageIsVerified == true else {
            throw WorkflowApplicationControllerErrorV4
                .invalidAssembledOutput("publication stage was not verified")
        }
        try throwIfActiveControlFailed()
        _ = try await queue.publishApplicationStagedOutput(
            intent,
            activated: activated
        )
        let completion = try await engine.inspectCompletion(
            request: activated.request,
            checkpoint: checkpoint,
            segmentResult: nil,
            processingDurationSeconds: 0
        )
        return completion
    }

    func schedulePublicationRecoveryRetry() {
        guard publicationRecoveryTask == nil else { return }
        let diagnosticRecorder = MirmirDiagnosticScope.recorder
        publicationRecoveryTask = Task { [weak self, diagnosticRecorder] in
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                let deferred = try await self.recoverInterruptedPublications()
                try await self.queue.cleanupCompletedApplicationPublications()
                try await self.queue.cleanupTerminalApplicationSourceSnapshots()
                let snapshot = try await self.queue.queueSnapshot()
                await self.forwardSnapshotForLaunch(snapshot)
                await self.recordPublicationRecoveryRetryRecoveredIfNeeded(
                    recorder: diagnosticRecorder
                )
                await self.clearPublicationRecoveryTask()
                if deferred {
                    await self.schedulePublicationRecoveryRetry()
                } else {
                    await self.scheduleDrain()
                }
            } catch is CancellationError {
                guard let self else { return }
                await self.clearPublicationRecoveryTask()
            } catch let error as MirmirError where error == .cancelled {
                guard let self else { return }
                await self.clearPublicationRecoveryTask()
            } catch {
                guard let self else { return }
                await self.recordPublicationRecoveryRetryFailureIfNeeded(
                    error,
                    recorder: diagnosticRecorder
                )
                await self.clearPublicationRecoveryTask()
                await self.schedulePublicationRecoveryRetry()
            }
        }
    }

    func clearPublicationRecoveryTask() {
        publicationRecoveryTask = nil
    }

    func forwardSnapshotForLaunch(
        _ snapshot: WorkflowApplicationQueueSnapshotV4
    ) {
        observer.snapshot(snapshot)
    }

    func enqueuePrepared(
        request: UpscaleRequest,
        priority: Int32
    ) async throws -> WorkflowApplicationEnqueueReceiptV4 {
        let processingActivity = processingActivityFactory(
            "Preparing an upscale job"
        )
        defer { processingActivity.end() }
        let prepared = try await engine.prepareSubmission(request: request)
        let receipt = try await queue.enqueue(
            request: prepared.request,
            preparedPlanBinding: prepared.binding,
            priority: priority
        )
        await emitSnapshot(to: observer.snapshot)
        return receipt
    }

    func scheduleDrain() {
        if drainTask != nil {
            drainRescheduleRequested = true
            return
        }
        drainRescheduleRequested = false
        drainTask = Task { [weak self] in
            await self?.drainQueue()
        }
    }

    func drainQueue() async {
        while !Task.isCancelled {
            guard active == nil else { break }
            currentDrainJobID = nil
            do {
                let outcome = try await runNext(
                    progress: { [weak self] jobID, progress in
                        Task {
                            await self?.forwardProgress(
                                jobID: jobID,
                                progress: progress
                            )
                        }
                    },
                    snapshot: { [weak self] jobID, snapshot in
                        Task {
                            await self?.forwardSnapshot(
                                jobID: jobID,
                                snapshot: snapshot
                            )
                        }
                    }
                )
                currentDrainJobID = outcome.jobID
                finish(
                    jobID: outcome.jobID,
                    result: .success(outcome.outcome)
                )
            } catch WorkflowApplicationControllerErrorV4.noDispatchableJob {
                break
            } catch WorkflowApplicationControllerErrorV4
                .dispatchCapacityExhausted {
                do {
                    try await Task.sleep(
                        nanoseconds: Self.dispatchCapacityRetryNanoseconds
                    )
                } catch {
                    break
                }
                continue
            } catch {
                guard let jobID = currentDrainJobID else { break }
                finish(jobID: jobID, result: .failure(error))
            }
        }
        currentDrainJobID = nil
        drainTask = nil
        if drainRescheduleRequested {
            drainRescheduleRequested = false
            scheduleDrain()
        }
    }

    func forwardProgress(
        jobID: WorkflowJobID,
        progress: UpscaleProgress
    ) {
        observer.progress(jobID, progress)
        waiterProgressHandlers[jobID]?(progress)
    }

    func forwardSnapshot(
        jobID: WorkflowJobID,
        snapshot: WorkflowApplicationQueueSnapshotV4
    ) {
        observer.snapshot(snapshot)
        waiterSnapshotHandlers[jobID]?(snapshot)
    }

    func finish(
        jobID: WorkflowJobID,
        result: Result<WorkflowApplicationRunOutcomeV4, Error>
    ) {
        let waiters = completionWaiters.removeValue(forKey: jobID) ?? []
        waiterProgressHandlers.removeValue(forKey: jobID)
        waiterSnapshotHandlers.removeValue(forKey: jobID)
        switch result {
        case .success(let outcome):
            observer.execution(.finished(jobID: jobID, outcome: outcome))
            waiters.forEach { $0.resume(returning: outcome) }
        case .failure(let error):
            observer.execution(
                .failed(jobID: jobID, message: error.localizedDescription)
            )
            waiters.forEach { $0.resume(throwing: error) }
        }
    }

    func runNext(
        progress: @escaping @Sendable (
            WorkflowJobID,
            UpscaleProgress
        ) -> Void,
        snapshot: @escaping @Sendable (
            WorkflowJobID,
            WorkflowApplicationQueueSnapshotV4
        ) -> Void
    ) async throws -> ClaimedOutcome {
        guard active == nil else {
            throw WorkflowApplicationControllerErrorV4
                .dispatchCapacityExhausted
        }
        let result = try await queue.claimNextApplicationJob(
            cycleID: try Self.cycleID()
        )
        let dispatch: WorkflowQueueDispatchReceiptV4
        switch result {
        case .claimed(let claimed):
            dispatch = claimed
        case .noEligibleJob:
            throw WorkflowApplicationControllerErrorV4.noDispatchableJob
        case .capacityExhausted:
            throw WorkflowApplicationControllerErrorV4
                .dispatchCapacityExhausted
        }
        let jobID = dispatch.claim.jobID
        let processingActivity = processingActivityFactory(
            "Processing an upscale job"
        )
        defer { processingActivity.end() }
        currentDrainJobID = jobID
        let jobProgress: @Sendable (UpscaleProgress) -> Void = {
            progress(jobID, $0)
        }
        let jobSnapshot: @Sendable (
            WorkflowApplicationQueueSnapshotV4
        ) -> Void = {
            snapshot(jobID, $0)
        }
        let attemptID = try Self.attemptID(jobID: jobID)
        let cancellation = ProcessingCancellation()
        active = ActiveExecution(
            dispatch: dispatch,
            cancellation: cancellation,
            attemptID: attemptID,
            snapshotHandler: jobSnapshot,
            lifecycle: .probing,
            pauseRequested: false,
            cancelRequested: false,
            heartbeatFailure: nil
        )
        startHeartbeat(jobID: jobID)
        await emitSnapshot(to: jobSnapshot)

        let activation = await queue.activate(jobID: jobID)
        guard case .active(let activated) = activation else {
            let failure: WorkflowApplicationActivationFailureV4
            if case .blocked(let blocked) = activation {
                failure = blocked
            } else {
                failure = .jobNotFound
            }
            let error = WorkflowApplicationControllerErrorV4
                .activationBlocked(failure)
            await terminateActive(error: error, containmentRequired: true)
            throw error
        }
        defer { activated.close() }

        let diagnosticContext = MirmirDiagnosticExecutionContext(
            jobID: jobID.rawValue,
            workflowID: dispatch.claim.jobBinding.requestID.rawValue,
            queueItemID: jobID.rawValue
        )
        var diagnosticSource: VideoInfo?
        do {
            try activated.revalidateAll()
            let source = try await engine.revalidateAndPrepare(
                jobID: jobID,
                request: activated.request,
                expectedBinding: activated.preparedPlanBinding,
                cancellation: cancellation
            )
            diagnosticSource = source
            try await transitionActive(
                expected: .probing,
                target: .planned,
                attemptID: nil,
                stage: "planning-complete"
            )
            try await transitionActive(
                expected: .planned,
                target: .running,
                attemptID: attemptID,
                stage: "processing-started"
            )
            if active?.pauseRequested == true {
                _ = try await queue.requestApplicationPause(
                    dispatch,
                    commandKey: try Self.commandKey(
                        stage: "pause-request",
                        jobID: jobID
                    )
                )
                active?.lifecycle = .pausing
                await emitSnapshot(to: jobSnapshot)
            }
            try throwIfActiveControlFailed()

            let outcome = try await MirmirDiagnosticScope
                .$executionContext.withValue(diagnosticContext) {
                    try await continueProcessing(
                        dispatch: dispatch,
                        attemptID: attemptID,
                        activated: activated,
                        source: source,
                        checkpoint: nil,
                        startingInputFrameIndex: 0,
                        processingDurationSeconds: 0,
                        progress: jobProgress,
                        snapshot: jobSnapshot
                    )
                }
            stopHeartbeat()
            active = nil
            await emitSnapshot(to: jobSnapshot)
            return ClaimedOutcome(
                jobID: jobID,
                outcome: outcome
            )
        } catch {
            if let source = diagnosticSource {
                MirmirDiagnosticScope.recorder
                    .recordProcessingFailure(
                        subsystem: "workflow_application_coordinator",
                        operation: "run_next",
                        request: activated.request,
                        source: source,
                        actualBackendID: activated.preparedPlanBinding
                            .resolvedBackendID,
                        fallbackOccurred: activated.request.backendID
                            .isConcreteBackend
                            && activated.request.backendID
                                != activated.preparedPlanBinding
                                    .resolvedBackendID,
                        timing: .init(
                            nominalFrameDuration:
                                source.minimumFrameDuration,
                            siteID: Self.diagnosticTimingSiteID(error)
                        ),
                        error: error
                    )
            } else {
                MirmirDiagnosticScope.recorder.enqueue(
                    severity: .error,
                    subsystem: "workflow_application_coordinator",
                    operation: "run_next",
                    code: MirmirDiagnosticRecorder.failureCode(error),
                    fields: (try? [
                        MirmirDiagnosticRecorder.textField(
                            "job_id_context",
                            jobID.rawValue
                        )
                    ]) ?? [],
                    error: error
                )
            }
            await engine.abandonPrepared(jobID: jobID)
            await terminateActive(
                error: error,
                containmentRequired: Self.requiresContainment(error)
            )
            throw error
        }
    }

    func continueProcessing(
        dispatch: WorkflowQueueDispatchReceiptV4,
        attemptID: WorkflowAttemptID,
        activated: WorkflowActivatedUpscaleRequestV4,
        source: VideoInfo,
        checkpoint initialCheckpoint: WorkflowCheckpointDocumentV4?,
        startingInputFrameIndex initialFrameIndex: Int,
        processingDurationSeconds initialDuration: TimeInterval,
        progress: @escaping @Sendable (UpscaleProgress) -> Void,
        snapshot: @escaping @Sendable (
            WorkflowApplicationQueueSnapshotV4
        ) -> Void
    ) async throws -> WorkflowApplicationRunOutcomeV4 {
        let jobID = dispatch.claim.jobID
        var checkpoint = initialCheckpoint
        var nextFrameIndex = initialFrameIndex
        var processingDuration = initialDuration
        let diagnosticContext = MirmirDiagnosticExecutionContext(
            jobID: jobID.rawValue,
            workflowID: dispatch.claim.jobBinding.requestID.rawValue,
            queueItemID: jobID.rawValue
        )
        let diagnosticStartedUptime = DispatchTime.now().uptimeNanoseconds
        var lastDiagnosticUptime: UInt64?
        var sourceAuthenticationNanoseconds: UInt64 = 0
        var segmentProcessingNanoseconds: UInt64 = 0
        var checkpointCommitNanoseconds: UInt64 = 0
        MirmirDiagnosticScope.recorder.recordJobStarted(
            executionContext: diagnosticContext,
            request: activated.request,
            source: source,
            actualBackendID: activated.preparedPlanBinding.resolvedBackendID,
            maximumInputFramesPerBoundary: maximumInputFramesPerBoundary,
            startingInputFrameIndex: initialFrameIndex
        )
        if checkpointIsTerminal(checkpoint) {
            guard let checkpoint else {
                throw WorkflowApplicationControllerErrorV4
                    .invalidAssembledOutput(
                        "the terminal checkpoint is unavailable"
                    )
            }
            let verification = try await queue.verifyApplicationCheckpoint(
                checkpoint
            )
            try await engine.validateTerminalSourceCompleteness(
                jobID: jobID,
                lastCompletedInputOrdinal:
                    verification.lastCompletedInputOrdinal
            )
            let completion = try await finalize(
                dispatch: dispatch,
                attemptID: attemptID,
                activated: activated,
                checkpoint: checkpoint,
                processingDurationSeconds: processingDuration,
                progress: progress
            )
            return .completed(completion)
        }

        while true {
            try throwIfActiveControlFailed()
            let authoritativeStartTime: WorkflowMediaTimeV4?
            if let checkpoint {
                guard let nextStartTime = checkpoint.body.segments.last?
                    .nextStartTime else {
                    throw WorkflowApplicationControllerErrorV4
                        .invalidAssembledOutput(
                            "a nonterminal checkpoint has no authenticated next boundary"
                        )
                }
                authoritativeStartTime = nextStartTime
            } else {
                authoritativeStartTime = nil
            }
            // Reopen and fence the queue-owned source before every segment.
            // Auxiliary finalization receives this same private snapshot.
            let sourceAuthenticationStarted = DispatchTime.now().uptimeNanoseconds
            try activated.revalidateAll()
            sourceAuthenticationNanoseconds += DispatchTime.now().uptimeNanoseconds
                - sourceAuthenticationStarted
            guard let cancellation = active?.cancellation else {
                throw WorkflowApplicationControllerErrorV4.noActiveJob
            }
            let ordinal = UInt64(checkpoint?.body.segments.count ?? 0)
            let workingURL = try await queue.applicationWorkingSegmentURL(
                jobID: jobID,
                boundaryOrdinal: ordinal
            )
            let workingRequest = Self.request(
                activated.request,
                outputURL: workingURL,
                overwriteExistingFile: false
            )
            let segment: WorkflowApplicationProcessedSegmentV4
            let segmentProcessingStarted = DispatchTime.now().uptimeNanoseconds
            do {
                segment = try await engine.processPrepared(
                    jobID: jobID,
                    request: workingRequest,
                    startingInputFrameIndex: nextFrameIndex,
                    startTime: authoritativeStartTime,
                    maximumInputFrames: maximumInputFramesPerBoundary,
                    previousCheckpoint: checkpoint,
                    cancellation: cancellation,
                    progress: progress
                )
            } catch {
                try? await queue.removeApplicationWorkingArtifact(workingURL)
                throw error
            }
            segmentProcessingNanoseconds += DispatchTime.now().uptimeNanoseconds
                - segmentProcessingStarted
            processingDuration += segment.segment.processingDurationSeconds
            try throwIfActiveControlFailed()
            if active?.pauseRequested == true,
               active?.lifecycle == .running {
                _ = try await queue.requestApplicationPause(
                    dispatch,
                    commandKey: try Self.commandKey(
                        stage: "pause-request",
                        jobID: jobID
                    )
                )
                active?.lifecycle = .pausing
                await emitSnapshot(to: snapshot)
            }
            let checkpointCommitStarted = DispatchTime.now().uptimeNanoseconds
            let committed = try await queue
                .commitApplicationCheckpointBoundary(
                    dispatch: dispatch,
                    specification: activated.specification,
                    segment: segment.segment,
                    outputContractID:
                        activated.preparedPlanBinding.outputContractID,
                    previousCheckpoint: checkpoint,
                    trackProgress: segment.trackProgress,
                    temporalCheckpoint: segment.temporalCheckpoint,
                    sourceSnapshotIdentityID:
                        activated.sourceSnapshot.identityID
                )
            try await queue.removeApplicationWorkingArtifact(workingURL)
            checkpoint = committed.checkpoint
            nextFrameIndex = Int(
                segment.segment.lastCompletedInputOrdinal + 1
            )
            let diagnosticUptime = DispatchTime.now().uptimeNanoseconds
            checkpointCommitNanoseconds += diagnosticUptime - checkpointCommitStarted
            if segment.segment.terminal || active?.lifecycle == .pausing
                || (lastDiagnosticUptime.map({
                    diagnosticUptime >= $0
                        && diagnosticUptime - $0 >= 60_000_000_000
                }) ?? true) {
                lastDiagnosticUptime = diagnosticUptime
                MirmirDiagnosticScope.recorder.recordProgress(
                    executionContext: diagnosticContext,
                    durable: .init(
                        nextInputSampleIndex: Int64(nextFrameIndex),
                        segmentOrdinal: Int(clamping:
                            committed.checkpoint.body.ordinal
                        ),
                        segmentCount: committed.checkpoint.body.segments.count,
                        isComplete: checkpointIsTerminal(
                            committed.checkpoint
                        ),
                        checkpointSchema: "workflow-checkpoint-v4-v3",
                        checkpointURL: nil
                    ),
                    elapsedNanoseconds: diagnosticUptime
                        - diagnosticStartedUptime,
                    processingDurationSeconds: processingDuration - initialDuration,
                    completedInputFrames: nextFrameIndex - initialFrameIndex,
                    sourceAuthenticationNanoseconds: sourceAuthenticationNanoseconds,
                    segmentProcessingNanoseconds: segmentProcessingNanoseconds,
                    checkpointCommitNanoseconds: checkpointCommitNanoseconds
                )
            }

            if active?.lifecycle == .pausing {
                _ = try await queue.completeApplicationPause(
                    dispatch,
                    commandKey: try Self.commandKey(
                        stage: "pause-commit",
                        jobID: jobID
                    )
                )
                await engine.abandonPrepared(jobID: jobID)
                return .paused(jobID: jobID, source: source)
            }
            if segment.segment.terminal {
                try await engine.validateTerminalSourceCompleteness(
                    jobID: jobID,
                    lastCompletedInputOrdinal:
                        segment.segment.lastCompletedInputOrdinal
                )
                let completion = try await finalize(
                    dispatch: dispatch,
                    attemptID: attemptID,
                    activated: activated,
                    checkpoint: committed.checkpoint,
                    processingDurationSeconds: processingDuration,
                    progress: progress
                )
                return .completed(completion)
            }
        }
    }

    func checkpointIsTerminal(
        _ checkpoint: WorkflowCheckpointDocumentV4?
    ) -> Bool {
        checkpoint?.body.trackProgress.contains(where: {
            $0.kind == .video
                && $0.nextOutputSampleIndex > 0
                && $0.isComplete
        }) == true
    }

    static func diagnosticTimingSiteID(_ error: Error) -> String? {
        guard case let DeterministicV4MediaSegmentError
            .invalidSampleTiming(site) = error else {
            return nil
        }
        return site.rawValue
    }

    func finalize(
        dispatch: WorkflowQueueDispatchReceiptV4,
        attemptID: WorkflowAttemptID,
        activated: WorkflowActivatedUpscaleRequestV4,
        checkpoint: WorkflowCheckpointDocumentV4,
        processingDurationSeconds: TimeInterval = 0,
        progress: @escaping @Sendable (UpscaleProgress) -> Void
    ) async throws -> WorkflowApplicationCompletionV4 {
        let context = MirmirDiagnosticExecutionContext(
            jobID: dispatch.claim.jobID.rawValue,
            workflowID: dispatch.claim.jobBinding.requestID.rawValue,
            queueItemID: dispatch.claim.jobID.rawValue
        )
        let video = checkpoint.body.trackProgress.first {
            $0.kind == .video
        }
        let checkpointURL = await queue.applicationCheckpointURL(
            jobID: dispatch.claim.jobID
        )
        do {
            let completion = try await finalizeUninstrumented(
                dispatch: dispatch,
                attemptID: attemptID,
                activated: activated,
                checkpoint: checkpoint,
                processingDurationSeconds: processingDurationSeconds,
                progress: progress
            )
            Self.recordFinalizeDiagnostic(
                executionContext: context,
                nextInputSampleIndex: video.map {
                    Int64(clamping: $0.nextInputSampleIndex)
                },
                segmentOrdinal: Int(clamping: checkpoint.body.ordinal),
                segmentCount: checkpoint.body.segments.count,
                isComplete: true,
                checkpointURL: checkpointURL,
                destinationURL: activated.request.outputURL,
                error: nil
            )
            return completion
        } catch {
            Self.recordFinalizeDiagnostic(
                executionContext: context,
                nextInputSampleIndex: video.map {
                    Int64(clamping: $0.nextInputSampleIndex)
                },
                segmentOrdinal: Int(clamping: checkpoint.body.ordinal),
                segmentCount: checkpoint.body.segments.count,
                isComplete: video?.isComplete ?? false,
                checkpointURL: checkpointURL,
                destinationURL: activated.request.outputURL,
                error: error
            )
            throw error
        }
    }

    private func finalizeUninstrumented(
        dispatch: WorkflowQueueDispatchReceiptV4,
        attemptID: WorkflowAttemptID,
        activated: WorkflowActivatedUpscaleRequestV4,
        checkpoint: WorkflowCheckpointDocumentV4,
        processingDurationSeconds: TimeInterval = 0,
        progress: @escaping @Sendable (UpscaleProgress) -> Void
    ) async throws -> WorkflowApplicationCompletionV4 {
        try throwIfActiveControlFailed()
        try await transitionActive(
            expected: .running,
            target: .verifying,
            attemptID: attemptID,
            stage: "checkpoint-verification"
        )
        _ = try await queue.verifyApplicationCheckpoint(checkpoint)
        try await transitionActive(
            expected: .verifying,
            target: .committing,
            attemptID: nil,
            stage: "output-commit"
        )
        progress(Self.resumeProgress(
            request: activated.request,
            phase: .finalizing
        ))
        let intent = try await queue.prepareApplicationPublication(
            activated: activated,
            checkpoint: checkpoint
        )
        var publication = try await queue.applicationPublicationState(
            jobID: dispatch.claim.jobID
        )
        if publication?.stageIsVerified != true {
            try await queue.discardApplicationUnverifiedPublicationArtifacts(
                intent,
                activated: activated
            )
            let assembledVideoURL = try await queue
                .applicationAssembledVideoURL(
                    jobID: dispatch.claim.jobID,
                    checkpointID: checkpoint.body.checkpointID
                )
            do {
                let assemblyTimeline = try await engine
                    .preparedAssemblyTimeline(
                        jobID: dispatch.claim.jobID
                    )
                _ = try await queue.assembleApplicationCheckpoint(
                    checkpoint,
                    timeline: assemblyTimeline,
                    destinationURL: assembledVideoURL,
                    overwriteExistingFile: false,
                    structuralCreationDateSourceURL: activated.request.inputURL
                )
                guard let cancellation = active?.cancellation else {
                    throw WorkflowApplicationControllerErrorV4.noActiveJob
                }
                let finalized = try await engine.finalizePreparedOutput(
                    jobID: dispatch.claim.jobID,
                    request: activated.request,
                    assembledVideoURL: assembledVideoURL,
                    publicationURL: try await queue
                        .applicationPublicationStagingURL(
                            intent,
                            activated: activated
                        ),
                    migrationTemporaryURL: try await queue
                        .applicationPublicationMigrationTemporaryURL(
                            intent,
                            activated: activated
                        ),
                    cancellation: cancellation,
                    progress: progress
                )
                _ = try await queue.recordApplicationStagedPublication(
                    intent,
                    finalized: finalized,
                    activated: activated
                )
                try await queue.removeApplicationWorkingArtifact(
                    assembledVideoURL
                )
            } catch {
                try? await queue.removeApplicationWorkingArtifact(
                    assembledVideoURL
                )
                throw error
            }
            publication = try await queue.applicationPublicationState(
                jobID: dispatch.claim.jobID
            )
        }
        guard publication?.stageIsVerified == true else {
            throw WorkflowApplicationControllerErrorV4
                .invalidAssembledOutput("publication stage was not verified")
        }
        _ = try await queue.publishApplicationStagedOutput(
            intent,
            activated: activated
        )
        let completion = try await engine.inspectCompletion(
            request: activated.request,
            checkpoint: checkpoint,
            segmentResult: nil,
            processingDurationSeconds: processingDurationSeconds
        )
        try await transitionActive(
            expected: .committing,
            target: .completed,
            attemptID: nil,
            stage: "output-committed",
            releaseAfterTransition: true
        )
        progress(Self.resumeProgress(
            request: activated.request,
            phase: .completed,
            result: completion.result
        ))
        await engine.abandonPrepared(jobID: dispatch.claim.jobID)
        try? await queue.cleanupTerminalApplicationSourceSnapshots()
        return completion
    }

    func transitionActive(
        expected: WorkflowJobLifecycle,
        target: WorkflowJobLifecycle,
        attemptID: WorkflowAttemptID?,
        stage: String,
        releaseAfterTransition: Bool = false
    ) async throws {
        guard var current = active else {
            throw WorkflowApplicationControllerErrorV4.noActiveJob
        }
        _ = try await queue.transitionApplicationJob(
            current.dispatch,
            expected: expected,
            target: target,
            commandKey: try Self.commandKey(
                stage: stage,
                jobID: current.dispatch.claim.jobID
            ),
            stage: stage,
            attemptID: attemptID,
            releaseAfterTransition: releaseAfterTransition
        )
        current.lifecycle = target
        active = current
        await emitSnapshot(to: current.snapshotHandler)
    }

    func terminateActive(
        error: Error,
        containmentRequired: Bool
    ) async {
        guard let current = active else { return }
        stopHeartbeat()
        current.cancellation.cancel()
        await engine.abandonPrepared(jobID: current.dispatch.claim.jobID)

        let target: WorkflowJobLifecycle
        if current.lifecycle == .committing {
            let publicationExists = (try? await queue
                .applicationPublicationState(
                    jobID: current.dispatch.claim.jobID
                )) != nil
            // Once an immutable publication intent exists, a commit failure
            // must remain recoverable. The recovery pass either completes the
            // verified publication or contains a permanent conflict.
            target = publicationExists ? .recovering : .contained
        } else if current.cancelRequested || error is CancellationError
            || (error as? MirmirError) == .cancelled {
            target = .cancelled
        } else {
            target = containmentRequired ? .contained : .failed
        }
        if current.lifecycle.allowsTransition(to: target) {
            let transition = try? await queue.transitionApplicationJob(
                current.dispatch,
                expected: current.lifecycle,
                target: target,
                commandKey: try Self.commandKey(
                    stage: "terminal-\(target.rawValue)",
                    jobID: current.dispatch.claim.jobID
                ),
                stage: "terminal-\(target.rawValue)",
                attemptID: current.lifecycle == .running
                    || current.lifecycle == .pausing
                    ? current.attemptID
                    : nil,
                releaseAfterTransition: true
            )
            if transition != nil, target == .cancelled {
                try? await queue.cleanupTerminalApplicationSourceSnapshots()
            }
        }
        let handler = current.snapshotHandler
        active = nil
        await emitSnapshot(to: handler)
        if target == .recovering {
            schedulePublicationRecoveryRetry()
        }
    }

    func throwIfActiveControlFailed() throws {
        guard let current = active else {
            throw WorkflowApplicationControllerErrorV4.noActiveJob
        }
        if let heartbeatFailure = current.heartbeatFailure {
            throw WorkflowApplicationControllerErrorV4
                .heartbeatFailed(heartbeatFailure)
        }
        if current.cancelRequested {
            throw CancellationError()
        }
    }

    func startHeartbeat(jobID: WorkflowJobID) {
        stopHeartbeat()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 10_000_000_000)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await self?.performHeartbeat(jobID: jobID)
            }
        }
    }

    func performHeartbeat(jobID: WorkflowJobID) async {
        guard var current = active,
              current.dispatch.claim.jobID == jobID else { return }
        do {
            _ = try await queue.heartbeatApplicationJob(current.dispatch)
        } catch {
            current.heartbeatFailure = error.localizedDescription
            current.cancellation.cancel()
            active = current
        }
    }

    func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    func emitSnapshot(
        to handler: @escaping @Sendable (
            WorkflowApplicationQueueSnapshotV4
        ) -> Void
    ) async {
        guard let value = try? await queue.queueSnapshot() else { return }
        handler(value)
    }

    nonisolated static func request(
        _ request: UpscaleRequest,
        outputURL: URL,
        overwriteExistingFile: Bool
    ) -> UpscaleRequest {
        UpscaleRequest(
            inputURL: request.inputURL,
            outputURL: outputURL,
            backendID: request.backendID,
            targetWidth: request.targetWidth,
            targetHeight: request.targetHeight,
            outputCodec: request.outputCodec,
            preserveAudio: request.preserveAudio,
            overwriteExistingFile: overwriteExistingFile
        )
    }

    nonisolated static func cycleID() throws -> WorkflowDispatchCycleIDV4 {
        try WorkflowDispatchCycleIDV4(
            "application-cycle-\(UUID().uuidString.lowercased())"
        )
    }

    nonisolated static func attemptID(
        jobID: WorkflowJobID
    ) throws -> WorkflowAttemptID {
        try WorkflowAttemptID(
            "attempt-\(jobID.rawValue)-\(UUID().uuidString.lowercased())"
        )
    }

    nonisolated static func commandKey(
        stage: String,
        jobID: WorkflowJobID? = nil
    ) throws -> WorkflowRecoveryCommandKeyV4 {
        let suffix = jobID.map { "-\($0.rawValue)" } ?? ""
        return try WorkflowRecoveryCommandKeyV4(
            "application-\(stage)\(suffix)-\(UUID().uuidString.lowercased())"
        )
    }

    nonisolated static func requiresContainment(_ error: Error) -> Bool {
        switch error {
        case WorkflowApplicationControllerErrorV4.activationBlocked,
             WorkflowApplicationControllerErrorV4.preparedPlanChanged,
             WorkflowApplicationControllerErrorV4.checkpointMissing,
             WorkflowApplicationQueueErrorV4.preparedPlanChanged,
             WorkflowApplicationQueueErrorV4.requestDocumentMissing,
             WorkflowApplicationQueueErrorV4.requestDocumentCorrupt,
             WorkflowApplicationQueueErrorV4.requestDocumentBindingMismatch,
             WorkflowDurableCoordinatorErrorV4.checkpointIncompatible:
            true
        default:
            false
        }
    }

    nonisolated static func resumeProgress(
        request: UpscaleRequest,
        phase: UpscalePhase,
        result: UpscaleResult? = nil
    ) -> UpscaleProgress {
        UpscaleProgress(
            phase: phase,
            fractionCompleted: phase == .completed ? 1 : nil,
            processedFrameCount: result?.processedFrameCount ?? 0,
            processedTime: nil,
            duration: nil,
            actualBackendID: request.backendID
        )
    }

}
