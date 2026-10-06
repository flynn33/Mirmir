import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import Mirmir

@Suite("Processing activity ownership")
struct MirmirProcessingActivityTests {
    @Test
    func testProcessingOptionsPreventIdleSystemSleepAndAllowDisplaySleep() {
        let recorder = MirmirProcessingActivityTestRecorder()
        let activity = recorder.begin("Processing")
        defer { activity.end() }

        let options = recorder.snapshot.options
        #expect(options == [.userInitiated])
        #expect(options[0].contains(.idleSystemSleepDisabled))
        #expect(!options[0].contains(.idleDisplaySleepDisabled))
        #expect(!options[0].contains(.latencyCritical))
    }

    @Test
    func testExplicitEndAndDeinitReleaseOnlyOnce() {
        let recorder = MirmirProcessingActivityTestRecorder()
        var activity: MirmirProcessingActivity? = recorder.begin("Processing")
        activity?.end()
        activity?.end()
        activity = nil

        #expect(recorder.snapshot.beginCount == 1)
        #expect(recorder.snapshot.endCount == 1)
        #expect(recorder.snapshot.activeCount == 0)
    }

    @Test
    func testDeinitReleasesUnclosedActivity() {
        let recorder = MirmirProcessingActivityTestRecorder()
        var activity: MirmirProcessingActivity? = recorder.begin("Processing")
        weak let retainedActivity = activity
        #expect(retainedActivity != nil)
        activity = nil

        #expect(retainedActivity == nil)
        #expect(recorder.snapshot.endCount == 1)
        #expect(recorder.snapshot.activeCount == 0)
    }

    @Test
    func testOverlappingActivitiesEndIndependently() {
        let recorder = MirmirProcessingActivityTestRecorder()
        let planning = recorder.begin("Planning")
        let processing = recorder.begin("Processing")
        defer { processing.end() }
        #expect(recorder.snapshot.activeCount == 2)

        planning.end()
        #expect(recorder.snapshot.endCount == 1)
        #expect(recorder.snapshot.activeCount == 1)
        processing.end()
        #expect(recorder.snapshot.activeCount == 0)
        #expect(recorder.snapshot.endCount == 2)
    }

    @Test
    func testConcurrentEndReleasesOnlyOnce() async {
        let recorder = MirmirProcessingActivityTestRecorder()
        let activity = recorder.begin("Processing")
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask { activity.end() }
            }
        }

        #expect(recorder.snapshot.endCount == 1)
        #expect(recorder.snapshot.activeCount == 0)
    }

    @Test
    func testActivitySurvivesSuspensionUntilSuccessfulScopeEnds() async {
        let recorder = MirmirProcessingActivityTestRecorder()
        do {
            let activity = recorder.begin("Processing")
            defer { activity.end() }
            await Task.yield()
            #expect(recorder.snapshot.activeCount == 1)
            #expect(recorder.snapshot.endCount == 0)
        }

        #expect(recorder.snapshot.endCount == 1)
        #expect(recorder.snapshot.activeCount == 0)
    }

    @Test
    func testThrowingScopeReleasesActivityAfterSuspension() async {
        let recorder = MirmirProcessingActivityTestRecorder()
        do {
            let activity = recorder.begin("Processing")
            defer { activity.end() }
            await Task.yield()
            #expect(recorder.snapshot.activeCount == 1)
            throw ActivityTestError.failed
        } catch {
            #expect(error as? ActivityTestError == .failed)
        }

        #expect(recorder.snapshot.endCount == 1)
        #expect(recorder.snapshot.activeCount == 0)
    }

    @Test
    func testCancellationReleasesActivityAfterSuspendedWorkReturns() async {
        let recorder = MirmirProcessingActivityTestRecorder()
        let suspension = ActivitySuspension()
        let task = Task {
            let activity = recorder.begin("Processing")
            defer { activity.end() }
            await suspension.suspend()
            try Task.checkCancellation()
        }
        await suspension.waitUntilSuspended()
        #expect(recorder.snapshot.activeCount == 1)
        task.cancel()
        await suspension.resume()
        do {
            try await task.value
            Issue.record("Cancelled work completed without cancellation")
        } catch {
            #expect(error is CancellationError)
        }

        #expect(recorder.snapshot.endCount == 1)
        #expect(recorder.snapshot.activeCount == 0)
    }

    @Test
    func testNewScopeReacquiresActivityAfterPreviousScopeEnds() {
        let recorder = MirmirProcessingActivityTestRecorder()
        let processing = recorder.begin("Processing")
        processing.end()
        #expect(recorder.snapshot.activeCount == 0)

        let resumed = recorder.begin("Resuming")
        #expect(recorder.snapshot.beginCount == 2)
        #expect(recorder.snapshot.activeCount == 1)
        resumed.end()
        #expect(recorder.snapshot.endCount == 2)
        #expect(recorder.snapshot.activeCount == 0)
    }

    @Test
    func testDirectCoordinatorRetainsActivityDuringSuspendedProbeAndReleasesFailure()
        async throws {
        let recorder = MirmirProcessingActivityTestRecorder()
        let suspension = ActivitySuspension()
        let coordinator = UpscaleCoordinator(
            videoProbe: ActivityProbe(suspension: suspension, fails: true),
            backendCatalog: UpscaleBackendCatalog(backends: []),
            processingActivityFactory: { recorder.begin($0) }
        )
        let request = activityRequest()
        let processing = Task {
            try await coordinator.process(request, progress: { _ in })
        }
        await suspension.waitUntilSuspended()
        #expect(recorder.snapshot.activeCount == 1)
        #expect(recorder.snapshot.endCount == 0)
        await suspension.resume()
        do {
            _ = try await processing.value
            Issue.record("The injected probe failure was swallowed")
        } catch {
            #expect(error as? ActivityTestError == .failed)
        }
        #expect(recorder.snapshot.beginCount == 1)
        #expect(recorder.snapshot.endCount == 1)
        #expect(recorder.snapshot.activeCount == 0)
    }

    @Test
    func testDirectCoordinatorCancellationRetainsActivityUntilProbeReturns()
        async throws {
        let recorder = MirmirProcessingActivityTestRecorder()
        let suspension = ActivitySuspension()
        let coordinator = UpscaleCoordinator(
            videoProbe: ActivityProbe(suspension: suspension, fails: false),
            backendCatalog: UpscaleBackendCatalog(backends: []),
            processingActivityFactory: { recorder.begin($0) }
        )
        let processing = Task {
            try await coordinator.process(activityRequest(), progress: { _ in })
        }
        await suspension.waitUntilSuspended()
        await coordinator.cancel()
        #expect(recorder.snapshot.activeCount == 1)
        #expect(recorder.snapshot.endCount == 0)
        await suspension.resume()
        do {
            _ = try await processing.value
            Issue.record("The coordinator accepted a cancelled probe")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(recorder.snapshot.beginCount == 1)
        #expect(recorder.snapshot.endCount == 1)
        #expect(recorder.snapshot.activeCount == 0)
    }

    @Test
    func testDirectCoordinatorRejectsSecondJobWithoutEndingActiveLease()
        async throws {
        let recorder = MirmirProcessingActivityTestRecorder()
        let suspension = ActivitySuspension()
        let coordinator = UpscaleCoordinator(
            videoProbe: ActivityProbe(suspension: suspension, fails: true),
            backendCatalog: UpscaleBackendCatalog(backends: []),
            processingActivityFactory: { recorder.begin($0) }
        )
        let first = Task {
            try await coordinator.process(activityRequest(), progress: { _ in })
        }
        await suspension.waitUntilSuspended()
        do {
            _ = try await coordinator.process(activityRequest(), progress: { _ in })
            Issue.record("The occupied coordinator admitted another job")
        } catch let error as MirmirError {
            if case .invalidRequest = error {} else {
                Issue.record("The second job failed with an unrelated error")
            }
        } catch {
            Issue.record("The second job failed with an unrelated error")
        }
        #expect(recorder.snapshot.beginCount == 1)
        #expect(recorder.snapshot.activeCount == 1)
        #expect(recorder.snapshot.endCount == 0)
        await suspension.resume()
        do { _ = try await first.value } catch {
            #expect(error as? ActivityTestError == .failed)
        }
        #expect(recorder.snapshot.endCount == 1)
        #expect(recorder.snapshot.activeCount == 0)
    }

    @Test
    func testDirectCoordinatorInvalidRequestDoesNotBeginActivity() async {
        let recorder = MirmirProcessingActivityTestRecorder()
        let coordinator = UpscaleCoordinator(
            backendCatalog: UpscaleBackendCatalog(backends: []),
            processingActivityFactory: { recorder.begin($0) }
        )
        let url = URL(fileURLWithPath: "/invalid-same-input-and-output.mov")
        do {
            _ = try await coordinator.process(
                activityRequest(inputURL: url, outputURL: url),
                progress: { _ in }
            )
            Issue.record("An invalid request was accepted")
        } catch let error as MirmirError {
            if case .invalidRequest = error {} else {
                Issue.record("Invalid admission failed with an unrelated error")
            }
        } catch {
            Issue.record("Invalid admission failed with an unrelated error")
        }
        #expect(recorder.snapshot.beginCount == 0)
        #expect(recorder.snapshot.endCount == 0)
    }

    @Test
    func testDurableCoordinatorRetainsPlanningActivityAndReleasesPreparationFailure()
        async throws {
        let recorder = MirmirProcessingActivityTestRecorder()
        let suspension = ActivitySuspension()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mirmir-activity-planning-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = try WorkflowApplicationQueueV4(
            trustedRootURL: root,
            workerID: WorkflowWorkerIDV4("activity-planning-worker")
        )
        let coordinator = WorkflowApplicationCoordinatorV4(
            queue: queue,
            engine: ActivityPreparationFailingEngine(suspension: suspension),
            processingActivityFactory: { recorder.begin($0) }
        )
        let planning = Task {
            try await coordinator.enqueue(request: activityRequest(), priority: 0)
        }
        await suspension.waitUntilSuspended()
        #expect(recorder.snapshot.activeCount == 1)
        #expect(recorder.snapshot.reasons == ["Preparing an upscale job"])
        await suspension.resume()
        do {
            _ = try await planning.value
            Issue.record("Preparation failure did not stop admission")
        } catch {
            #expect(error as? ActivityTestError == .failed)
        }
        let snapshot = try await coordinator.queueSnapshot()
        #expect(snapshot.items.isEmpty)
        #expect(recorder.snapshot.endCount == 1)
        #expect(recorder.snapshot.activeCount == 0)
    }

    @Test
    func testDurableCoordinatorIdleLaunchAndInvalidResumeDoNotLeakActivity()
        async throws {
        let recorder = MirmirProcessingActivityTestRecorder()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mirmir-activity-idle-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = try WorkflowApplicationQueueV4(
            trustedRootURL: root.appendingPathComponent("idle", isDirectory: true),
            workerID: WorkflowWorkerIDV4("activity-idle-worker")
        )
        let coordinator = WorkflowApplicationCoordinatorV4(
            queue: queue,
            engine: ActivityPreparationFailingEngine(suspension: ActivitySuspension()),
            processingActivityFactory: { recorder.begin($0) }
        )
        _ = try await coordinator.launch()
        let snapshot = try await coordinator.queueSnapshot()
        #expect(snapshot.items.isEmpty)
        #expect(recorder.snapshot.beginCount == 0)
        #expect(recorder.snapshot.endCount == 0)
        #expect(recorder.snapshot.activeCount == 0)
        // Launch schedules an empty asynchronous drain. Resume uses another
        // store so that drain cannot briefly occupy its dispatch slot.
        let resumeQueue = try WorkflowApplicationQueueV4(
            trustedRootURL: root.appendingPathComponent("resume", isDirectory: true),
            workerID: WorkflowWorkerIDV4("activity-invalid-resume-worker")
        )
        let resumeCoordinator = WorkflowApplicationCoordinatorV4(
            queue: resumeQueue,
            engine: ActivityPreparationFailingEngine(suspension: ActivitySuspension()),
            processingActivityFactory: { recorder.begin($0) }
        )
        let nonexistentID = try WorkflowJobID("activity-nonexistent-job")
        do {
            _ = try await resumeCoordinator.resume(
                jobID: nonexistentID,
                progress: { _ in },
                snapshot: { _ in }
            )
            Issue.record("Resume admitted a nonexistent job")
        } catch {
            #expect(
                error as? WorkflowDurableCoordinatorErrorV4
                    == .noClaimableJob(nonexistentID)
            )
        }
        let afterResume = try await resumeCoordinator.queueSnapshot()
        #expect(afterResume.items.isEmpty)
        #expect(recorder.snapshot.beginCount == 1)
        #expect(recorder.snapshot.endCount == 1)
        #expect(recorder.snapshot.activeCount == 0)
    }
}

private enum ActivityTestError: Error, Equatable {
    case failed
}

final class MirmirProcessingActivityTestRecorder: @unchecked Sendable {
    struct Snapshot: Sendable {
        let options: [ProcessInfo.ActivityOptions]
        let reasons: [String]
        let beginCount: Int
        let endCount: Int
        let activeCount: Int
        let progressPhases: [UpscalePhase]
        let progressActivityCounts: [Int]
    }

    private let lock = NSLock()
    private var options: [ProcessInfo.ActivityOptions] = []
    private var reasons: [String] = []
    private var active: Set<ObjectIdentifier> = []
    private var endCount = 0
    private var progressPhases: [UpscalePhase] = []
    private var progressActivityCounts: [Int] = []

    var snapshot: Snapshot {
        lock.withLock {
            Snapshot(
                options: options,
                reasons: reasons,
                beginCount: options.count,
                endCount: endCount,
                activeCount: active.count,
                progressPhases: progressPhases,
                progressActivityCounts: progressActivityCounts
            )
        }
    }

    func recordProtectedProgress(_ progress: UpscaleProgress) {
        lock.withLock {
            progressPhases.append(progress.phase)
            progressActivityCounts.append(active.count)
        }
    }

    func begin(_ reason: String) -> MirmirProcessingActivity {
        MirmirProcessingActivity(
            reason: reason,
            beginActivity: { [self] options, reason in
                let token = NSObject()
                lock.withLock {
                    self.options.append(options)
                    reasons.append(reason)
                    active.insert(ObjectIdentifier(token))
                }
                return token
            },
            endActivity: { [self] token in
                lock.withLock {
                    endCount += 1
                    active.remove(ObjectIdentifier(token))
                }
            }
        )
    }
}

private actor ActivitySuspension {
    private var suspended = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        suspended = true
        enteredWaiters.forEach { $0.resume() }
        enteredWaiters.removeAll()
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilSuspended() async {
        guard !suspended else { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private func activityRequest(
    inputURL: URL = URL(fileURLWithPath: "/activity-input.mov"),
    outputURL: URL = URL(fileURLWithPath: "/activity-output.mov")
) -> UpscaleRequest {
    UpscaleRequest(
        inputURL: inputURL,
        outputURL: outputURL,
        backendID: .mirmirDeterministicCPU,
        targetWidth: 32,
        targetHeight: 32,
        outputCodec: .h264,
        preserveAudio: false,
        overwriteExistingFile: false
    )
}

private struct ActivityProbe: VideoProbing {
    let suspension: ActivitySuspension
    let fails: Bool

    func probe(url: URL) async throws -> VideoInfo {
        await suspension.suspend()
        if fails { throw ActivityTestError.failed }
        let size = CGSize(width: 16, height: 16)
        return VideoInfo(
            url: url,
            duration: CMTime(value: 1, timescale: 30),
            geometry: VideoGeometry(
                encodedSize: size,
                naturalSize: size,
                presentationSize: size,
                displaySize: size,
                preferredTransform: .identity,
                cleanAperture: nil,
                pixelAspectRatio: VideoPixelAspectRatio(
                    horizontalSpacing: 1,
                    verticalSpacing: 1
                )
            ),
            nominalFrameRate: 30,
            minimumFrameDuration: CMTime(value: 1, timescale: 30),
            estimatedFrameCount: 1,
            estimatedDataRate: nil,
            codecFourCC: kCMVideoCodecType_H264,
            hasAudio: false,
            audioTrackCount: 0,
            videoTrackCount: 1,
            isReadable: true,
            isPlayable: true,
            fileSizeBytes: nil,
            color: .unknown
        )
    }
}

private struct ActivityPreparationFailingEngine:
    WorkflowApplicationDeterministicExecutingV4
{
    let suspension: ActivitySuspension

    func prepareSubmission(
        request: UpscaleRequest
    ) async throws -> WorkflowApplicationPreparedSubmissionV4 {
        await suspension.suspend()
        throw ActivityTestError.failed
    }

    func revalidateAndPrepare(
        jobID: WorkflowJobID,
        request: UpscaleRequest,
        expectedBinding: WorkflowVerifiedPreparedPlanBindingV4,
        cancellation: ProcessingCancellation
    ) async throws -> VideoInfo {
        throw ActivityTestError.failed
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
        throw ActivityTestError.failed
    }

    func restorePrepared(
        jobID: WorkflowJobID,
        temporalCheckpoint: Data,
        lastCompletedInputOrdinal: Int64
    ) async throws {
        throw ActivityTestError.failed
    }

    func validateTerminalSourceCompleteness(
        jobID: WorkflowJobID,
        lastCompletedInputOrdinal: Int64
    ) async throws {
        throw ActivityTestError.failed
    }

    func preparedAssemblyTimeline(
        jobID: WorkflowJobID
    ) async throws -> WorkflowApplicationAssemblyTimelineDescriptorV4 {
        throw ActivityTestError.failed
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
        throw ActivityTestError.failed
    }

    func inspectCompletion(
        request: UpscaleRequest,
        checkpoint: WorkflowCheckpointDocumentV4,
        segmentResult: UpscaleResult?,
        processingDurationSeconds: TimeInterval
    ) async throws -> WorkflowApplicationCompletionV4 {
        throw ActivityTestError.failed
    }

    func abandonPrepared(jobID: WorkflowJobID) async {}
}
