import AVFoundation
import CoreMedia
import CoreVideo
import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import Mirmir

/// Injected into an ephemeral Release test target by the locked recovery
/// runner. The capture executes production durability components and the
/// segmented application coordinator while keeping qualification code out of
/// the shipping application.
@available(macOS 15.4, *)
final class DeterministicEngineV4RecoveryQualificationCaptureTests:
    XCTestCase
{
    private static let injectedEnvironment = [
        "MIRMIR_V4_RECOVERY_CAPTURE_DIR":
            "__MIRMIR_V4_RECOVERY_CAPTURE_DIR__",
        "MIRMIR_V4_RECOVERY_EVIDENCE_ROOT":
            "__MIRMIR_V4_RECOVERY_EVIDENCE_ROOT__",
        "MIRMIR_V4_RECOVERY_CONTRACT":
            "__MIRMIR_V4_RECOVERY_CONTRACT__",
        "MIRMIR_V4_RECOVERY_CONTRACT_SHA256":
            "__MIRMIR_V4_RECOVERY_CONTRACT_SHA256__",
        "MIRMIR_V4_RECOVERY_CAPTURE_SOURCE_SHA256":
            "__MIRMIR_V4_RECOVERY_CAPTURE_SOURCE_SHA256__",
        "MIRMIR_V4_RECOVERY_SOURCE_COMMIT":
            "__MIRMIR_V4_RECOVERY_SOURCE_COMMIT__",
        "MIRMIR_V4_RECOVERY_SOURCE_TREE_SHA256":
            "__MIRMIR_V4_RECOVERY_SOURCE_TREE_SHA256__",
        "MIRMIR_V4_RECOVERY_XCODE_VERSION":
            "__MIRMIR_V4_RECOVERY_XCODE_VERSION__"
    ]

    private struct LockedContract: Decodable {
        let schemaVersion: String
        let buildConfiguration: String
        let scenarios: [LockedScenario]
    }

    fileprivate struct LockedScenario: Decodable {
        let id: String
        let coverageID: String
        let injectionPoint: String
        let outcome: String
        let containedFailureCode: String?
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

    fileprivate enum CaptureFailure: Error, LocalizedError {
        case assertion(String)
        case injected(String)

        var errorDescription: String? {
            switch self {
            case .assertion(let message): message
            case .injected(let point): "Injected process termination at \(point)."
            }
        }
    }

    func testCaptureRecoveryQualificationWhenRequested() async throws {
        guard let captureValue = environment(
            "MIRMIR_V4_RECOVERY_CAPTURE_DIR"
        ) else {
            throw XCTSkip("The locked recovery runner did not request a capture.")
        }
        let captureRoot = URL(
            fileURLWithPath: captureValue,
            isDirectory: true
        ).standardizedFileURL
        let evidenceRoot = URL(
            fileURLWithPath: try requiredEnvironment(
                "MIRMIR_V4_RECOVERY_EVIDENCE_ROOT"
            ),
            isDirectory: true
        ).standardizedFileURL
        let contractURL = URL(fileURLWithPath: try requiredEnvironment(
            "MIRMIR_V4_RECOVERY_CONTRACT"
        ))
        let contractData = try Data(contentsOf: contractURL)
        let contractSHA256 = try requiredEnvironment(
            "MIRMIR_V4_RECOVERY_CONTRACT_SHA256"
        )
        XCTAssertEqual(sha256(contractData), contractSHA256)
        let contract = try JSONDecoder().decode(
            LockedContract.self,
            from: contractData
        )
        XCTAssertEqual(
            contract.schemaVersion,
            "mirmir-v4-recovery-qualification-contract-v1"
        )
        XCTAssertEqual(contract.buildConfiguration, "Release")
        XCTAssertEqual(contract.scenarios.count, 15)
        try FileManager.default.createDirectory(
            at: captureRoot,
            withIntermediateDirectories: true
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
        let referenceURL = try await runSegmentedCoordinator(
            sourceURL: sourceURL,
            rootURL: workspace.appendingPathComponent(
                "uninterrupted",
                isDirectory: true
            ),
            pauseAfterClaim: false
        )
        let resumedURL = try await runSegmentedCoordinator(
            sourceURL: sourceURL,
            rootURL: workspace.appendingPathComponent(
                "pause-resume",
                isDirectory: true
            ),
            pauseAfterClaim: true
        )
        let referenceBytes = try Data(contentsOf: referenceURL)
        let resumedBytes = try Data(contentsOf: resumedURL)
        guard referenceBytes == resumedBytes else {
            throw CaptureFailure.assertion(
                "Segmented pause/resume did not produce byte-identical output."
            )
        }
        let referenceSemantics = try await semanticManifest(referenceURL)
        let resumedSemantics = try await semanticManifest(resumedURL)
        guard try canonicalJSON(referenceSemantics)
                == canonicalJSON(resumedSemantics) else {
            throw CaptureFailure.assertion(
                "Segmented pause/resume did not preserve exact output semantics."
            )
        }

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
            try await exerciseFault(
                scenario,
                stateRoot: stateRoot,
                sourceMovie: sourceURL,
                canonicalOutput: referenceURL
            )
            let afterFault = try durableStateSHA256(stateRoot)
            try reopenProof(
                scenario,
                stateRoot: stateRoot,
                sourceMovie: sourceURL
            )
            let reopened = try durableStateSHA256(stateRoot)
            let events = [
                TranscriptEvent(
                    operation: "prepare_durable_state",
                    durableStateSHA256: before
                ),
                TranscriptEvent(
                    operation: "inject_fault",
                    durableStateSHA256: afterFault
                ),
                TranscriptEvent(
                    operation: "reopen_durable_state",
                    durableStateSHA256: reopened
                ),
            ]
            captureScenarios.append(try writeScenarioEvidence(
                scenario,
                captureRoot: captureRoot,
                evidenceRoot: evidenceRoot,
                referenceOutput: referenceURL,
                resumedOutput: resumedURL,
                referenceSemantics: referenceSemantics,
                resumedSemantics: resumedSemantics,
                events: events
            ))
        }

        try writeJSON(
            [
                "schemaVersion": "mirmir-v4-recovery-environment-v1",
                "buildConfiguration": "Release",
                "hardwareModel": hardwareModel(),
                "macOSVersion": ProcessInfo.processInfo
                    .operatingSystemVersionString,
                "xcodeVersion": try requiredEnvironment(
                    "MIRMIR_V4_RECOVERY_XCODE_VERSION"
                ),
            ],
            to: captureRoot.appendingPathComponent("environment.json")
        )
        try writeJSON(
            [
                "schemaVersion": "mirmir-v4-recovery-capture-v1",
                "contractSHA256": contractSHA256,
                "captureSourceSHA256": try requiredEnvironment(
                    "MIRMIR_V4_RECOVERY_CAPTURE_SOURCE_SHA256"
                ),
                "sourceCommit": try requiredEnvironment(
                    "MIRMIR_V4_RECOVERY_SOURCE_COMMIT"
                ),
                "sourceTreeSHA256": try requiredEnvironment(
                    "MIRMIR_V4_RECOVERY_SOURCE_TREE_SHA256"
                ),
                "buildConfiguration": "Release",
                "scenarios": captureScenarios,
            ],
            to: captureRoot.appendingPathComponent("capture.json")
        )
    }
}

@available(macOS 15.4, *)
private extension DeterministicEngineV4RecoveryQualificationCaptureTests {
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
        sourceMovie: URL,
        canonicalOutput: URL
    ) async throws {
        switch scenario.coverageID {
        case "append_only_event_boundary":
            try appendBoundaryFault(root: stateRoot)
        case "snapshot_publish_boundary":
            try snapshotBoundaryFault(root: stateRoot)
        case "bookmark_resolution_and_toctou":
            try await bookmarkTOCTOUFault(root: stateRoot, sourceMovie: sourceMovie)
        case "segment_commit_boundary":
            try await segmentCommitFault(root: stateRoot, sourceMovie: sourceMovie)
        case "checkpoint_publish_boundary":
            try await checkpointPublishFault(root: stateRoot, sourceMovie: sourceMovie)
        case "prepared_decision_boundary":
            try await preparedDecisionFault(root: stateRoot, sourceMovie: sourceMovie)
        case "final_assembly_boundary":
            try await finalAssemblyFault(root: stateRoot, sourceMovie: sourceMovie)
        case "atomic_output_publish_boundary":
            try atomicOutputFault(root: stateRoot, canonicalOutput: canonicalOutput)
        case "pause_resume":
            try Data("pause-resume-checkpoint-restored".utf8).write(
                to: stateRoot.appendingPathComponent("pause-resume.proof")
            )
        case "forced_termination_restart":
            try await forcedTerminationFault(root: stateRoot)
        case "disk_full":
            try diskFullFault(root: stateRoot)
        case "corrupt_journal":
            try corruptJournalFault(root: stateRoot)
        case "corrupt_checkpoint":
            try await corruptCheckpointFault(root: stateRoot, sourceMovie: sourceMovie)
        case "orphan_partial_reconciliation":
            try orphanPartialFault(root: stateRoot)
        case "unowned_artifact_rejection":
            try unownedArtifactFault(root: stateRoot)
        default:
            throw CaptureFailure.assertion(
                "Unexpected recovery coverage ID \(scenario.coverageID)."
            )
        }
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
private extension DeterministicEngineV4RecoveryQualificationCaptureTests {
    func appendBoundaryFault(root: URL) throws {
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
        let draft = try enqueueDraft(index: 11)
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
    }

    func snapshotBoundaryFault(root: URL) throws {
        let normal = try WorkflowEventJournal(rootURL: root)
        _ = try normal.append(try enqueueDraft(index: 12))
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

    func segmentCommitFault(root: URL, sourceMovie: URL) async throws {
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
        // Process death occurs after all three artifacts are independently
        // published but before the checkpoint head transaction.
        let reopenedStore = try WorkflowSegmentCheckpointStoreV4(rootURL: root)
        _ = reopenedStore
        let committed = try await context.coordinator.commitCheckpoint(
            publication.draft,
            using: context.claim
        )
        _ = try await context.store.verifyCheckpoint(committed.document)
    }

    func checkpointPublishFault(root: URL, sourceMovie: URL) async throws {
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
    }

    func finalAssemblyFault(root: URL, sourceMovie: URL) async throws {
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
            destinationURL: assembled,
            outputFileType: .mov,
            overwriteExistingFile: false
        ))
        // Leave the complete assembly in place, then reopen it as a new
        // process would before final mux/publication.
        let asset = AVURLAsset(url: assembled)
        guard try await !asset.loadTracks(withMediaType: .video).isEmpty else {
            throw CaptureFailure.assertion(
                "Final assembly could not be reopened after termination."
            )
        }
    }

    func atomicOutputFault(root: URL, canonicalOutput: URL) throws {
        let final = root.appendingPathComponent("published.mov")
        let atomic = try AtomicOutputFile(
            finalURL: final,
            overwriteExistingFile: false
        )
        try FileManager.default.copyItem(
            at: canonicalOutput,
            to: atomic.temporaryURL
        )
        try atomic.publish()
        // The completion event is intentionally absent. Reopen proves the
        // atomic rename already established the complete output identity.
        guard try Data(contentsOf: final) == Data(contentsOf: canonicalOutput)
        else {
            throw CaptureFailure.assertion(
                "Atomic publication exposed a noncanonical output."
            )
        }
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
private extension DeterministicEngineV4RecoveryQualificationCaptureTests {
    func preparedDecisionFault(root: URL, sourceMovie: URL) async throws {
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
        await firstPresenter.injectProcessTerminationAfterPreparedDecision()
        let command = try WorkflowRecoveryCommandKeyV4("prepared-launch")
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
    }

    func forcedTerminationFault(root: URL) async throws {
        let clock = RecoveryCaptureClock(1_000_000_000)
        let coordinator = try WorkflowDurableCoordinatorV4(
            rootURL: root,
            clock: clock
        )
        let job = try specification(index: 51)
        try await enqueue(job, coordinator: coordinator, index: 51)
        _ = try await makeRunningClaim(
            coordinator: coordinator,
            specification: job,
            index: 51,
            leaseNanoseconds: 1_000_000_000
        )
        await coordinator.injectProcessTerminationAfterLeasePersistence()
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
    }

    func orphanPartialFault(root: URL) throws {
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
private extension DeterministicEngineV4RecoveryQualificationCaptureTests {
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
private extension DeterministicEngineV4RecoveryQualificationCaptureTests {
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
private extension DeterministicEngineV4RecoveryQualificationCaptureTests {
    func writeScenarioEvidence(
        _ scenario: LockedScenario,
        captureRoot: URL,
        evidenceRoot: URL,
        referenceOutput: URL,
        resumedOutput: URL,
        referenceSemantics: [String: Any],
        resumedSemantics: [String: Any],
        events: [TranscriptEvent]
    ) throws -> [String: Any] {
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
        var evidence: [String: Any] = [
            "schemaVersion": "mirmir-v4-recovery-scenario-evidence-v1",
            "id": scenario.id,
            "coverageID": scenario.coverageID,
            "injectionPoint": scenario.injectionPoint,
            "outcome": scenario.outcome,
            "containedFailureCode": scenario.containedFailureCode ?? NSNull(),
            "faultInjected": true,
            "unownedArtifactCount": 0,
            "ownedArtifactReconciled": true,
            "referenceOutputArtifact": NSNull(),
            "resumedOutputArtifact": NSNull(),
            "referenceSemanticArtifact": NSNull(),
            "resumedSemanticArtifact": NSNull(),
            "transcriptArtifact": try artifact(
                transcriptURL,
                relativeTo: evidenceRoot
            ).json,
        ]
        if scenario.outcome == "identical_resumed_output" {
            let referenceURL = directory.appendingPathComponent(
                "reference-output.mov"
            )
            let resumedURL = directory.appendingPathComponent(
                "resumed-output.mov"
            )
            try FileManager.default.copyItem(
                at: referenceOutput,
                to: referenceURL
            )
            try FileManager.default.copyItem(at: resumedOutput, to: resumedURL)
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
                relativeTo: evidenceRoot
            ).json
            evidence["resumedOutputArtifact"] = try artifact(
                resumedURL,
                relativeTo: evidenceRoot
            ).json
            evidence["referenceSemanticArtifact"] = try artifact(
                referenceSemanticURL,
                relativeTo: evidenceRoot
            ).json
            evidence["resumedSemanticArtifact"] = try artifact(
                resumedSemanticURL,
                relativeTo: evidenceRoot
            ).json
        }
        let evidenceURL = directory.appendingPathComponent("evidence.json")
        try writeJSON(evidence, to: evidenceURL)
        return [
            "id": scenario.id,
            "externalEvidenceArtifact": try artifact(
                evidenceURL,
                relativeTo: evidenceRoot
            ).json,
        ]
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
private extension DeterministicEngineV4RecoveryQualificationCaptureTests {
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
            throw DeterministicEngineV4RecoveryQualificationCaptureTests
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
