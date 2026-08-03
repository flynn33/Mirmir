import Foundation
import XCTest
@testable import Mirmir

final class WorkflowApplicationQueueV4Tests: XCTestCase {
    func testCleanLaunchHasImmutableEmptyQueueAndRecoverySnapshots() async throws {
        let fixture = try makeFixture()
        let clock = WorkflowApplicationQueueTestClockV4(7_000_000_000)
        let queue = try makeQueue(fixture: fixture, clock: clock)

        let snapshot = try await queue.launchSnapshot(
            commandKey: WorkflowRecoveryCommandKeyV4("launch-clean")
        )

        XCTAssertEqual(snapshot.queue.generatedAt, clock.now())
        XCTAssertTrue(snapshot.queue.items.isEmpty)
        XCTAssertEqual(snapshot.recovery.generatedAt, clock.now())
        XCTAssertTrue(snapshot.recovery.items.isEmpty)
    }

    func testEnqueueRelaunchAndActivatedRequestRoundTrip() async throws {
        let fixture = try makeFixture()
        let resolver = WorkflowApplicationBookmarkResolverStubV4()
        let clock = WorkflowApplicationQueueTestClockV4(8_000_000_000)
        let original = request(fixture: fixture)
        let binding = try preparedBinding()
        let first = try makeQueue(
            fixture: fixture,
            resolver: resolver,
            clock: clock
        )

        let receipt = try await first.enqueue(
            request: original,
            preparedPlanBinding: binding
        )
        XCTAssertEqual(receipt.specification.source.identityID, binding.sourceIdentityID)
        XCTAssertEqual(receipt.specification.output.contractID, binding.outputContractID)
        XCTAssertEqual(receipt.specification.runtimeBinding.planID, binding.planID)
        XCTAssertEqual(
            receipt.specification.runtimeBinding.runtimeManifestID,
            binding.runtimeManifestID
        )
        XCTAssertEqual(receipt.specification.runtimeBinding.id, binding.runtimeBindingID)

        let relaunched = try makeQueue(
            fixture: fixture,
            resolver: resolver,
            clock: clock,
            workerID: "application-worker-relaunch"
        )
        let snapshot = try await relaunched.queueSnapshot()
        XCTAssertEqual(snapshot.items.count, 1)
        XCTAssertEqual(snapshot.items[0].jobID, receipt.specification.jobID)
        XCTAssertEqual(snapshot.items[0].lifecycle, .queued)
        XCTAssertEqual(snapshot.items[0].queueOrdinal, 0)
        XCTAssertEqual(snapshot.items[0].requestRecordStatus, .ready)
        XCTAssertEqual(snapshot.items[0].request?.targetWidth, original.targetWidth)
        XCTAssertEqual(snapshot.items[0].request?.targetHeight, original.targetHeight)
        XCTAssertEqual(snapshot.items[0].request?.outputCodec, original.outputCodec)

        let recovery = await relaunched.recoverAtLaunch(
            commandKey: try WorkflowRecoveryCommandKeyV4("launch-relaunch")
        )
        XCTAssertEqual(recovery.items.count, 1)
        XCTAssertEqual(recovery.items[0].jobID, receipt.specification.jobID)
        XCTAssertEqual(recovery.items[0].status, .idle)

        let activation = await relaunched.activate(
            jobID: receipt.specification.jobID
        )
        guard case .active(let activated) = activation else {
            return XCTFail("Expected all bookmark capabilities to activate")
        }
        defer { activated.close() }
        try activated.revalidateAll()
        XCTAssertEqual(
            activated.request.inputURL.standardizedFileURL,
            original.inputURL.standardizedFileURL
        )
        XCTAssertEqual(
            activated.request.outputURL.standardizedFileURL,
            original.outputURL.standardizedFileURL
        )
        XCTAssertEqual(activated.request.backendID, original.backendID)
        XCTAssertEqual(activated.request.targetWidth, original.targetWidth)
        XCTAssertEqual(activated.request.targetHeight, original.targetHeight)
        XCTAssertEqual(activated.request.outputCodec, original.outputCodec)
        XCTAssertEqual(activated.request.preserveAudio, original.preserveAudio)
        XCTAssertEqual(
            activated.request.overwriteExistingFile,
            original.overwriteExistingFile
        )
        XCTAssertEqual(
            activated.cacheDirectoryURL.standardizedFileURL,
            fixture.storeURL
                .appendingPathComponent("cache-v4", isDirectory: true)
                .standardizedFileURL
        )
        XCTAssertEqual(
            activated.bookmarkReceipts.map(\.role),
            WorkflowScopedResourceRoleV4.allCases.sorted()
        )
    }

    func testTamperedRequestIsContainedWithoutChangingJournalLifecycle() async throws {
        let fixture = try makeFixture()
        let queue = try makeQueue(fixture: fixture)
        let receipt = try await queue.enqueue(
            request: request(fixture: fixture),
            preparedPlanBinding: preparedBinding()
        )
        let documentURL = await queue.requestDocumentURL(
            jobID: receipt.specification.jobID
        )
        var bytes = try Data(contentsOf: documentURL)
        bytes.append(0x20)
        try bytes.write(to: documentURL, options: .atomic)

        let snapshot = try await queue.queueSnapshot()
        XCTAssertEqual(snapshot.items.count, 1)
        XCTAssertEqual(snapshot.items[0].lifecycle, .queued)
        XCTAssertEqual(snapshot.items[0].requestRecordStatus, .corrupt)
        XCTAssertNil(snapshot.items[0].request)

        let activation = await queue.activate(jobID: receipt.specification.jobID)
        guard case .blocked(let reason) = activation else {
            return XCTFail("A noncanonical request document must fail closed")
        }
        XCTAssertEqual(reason, .requestDocumentCorrupt)
    }

    func testBookmarkDenialAndPathReplacementAreContained() async throws {
        let fixture = try makeFixture()
        let resolver = WorkflowApplicationBookmarkResolverStubV4()
        let queue = try makeQueue(fixture: fixture, resolver: resolver)
        let receipt = try await queue.enqueue(
            request: request(fixture: fixture),
            preparedPlanBinding: preparedBinding()
        )

        resolver.deniedRole = .inputFile
        let denied = await queue.activate(jobID: receipt.specification.jobID)
        guard case .blocked(.bookmarkBlocked(let deniedFailures)) = denied else {
            return XCTFail("Denied input scope must be contained")
        }
        XCTAssertEqual(
            deniedFailures,
            [
                WorkflowBookmarkActivationFailureV4(
                    role: .inputFile,
                    reason: .accessDenied
                )
            ]
        )

        resolver.deniedRole = nil
        try FileManager.default.removeItem(at: fixture.inputURL)
        try Data("replacement".utf8).write(to: fixture.inputURL)
        let replaced = await queue.activate(jobID: receipt.specification.jobID)
        guard case .blocked(.bookmarkBlocked(let replacedFailures)) = replaced else {
            return XCTFail("A replaced source inode must be contained")
        }
        XCTAssertEqual(
            replacedFailures,
            [
                WorkflowBookmarkActivationFailureV4(
                    role: .inputFile,
                    reason: .targetReplaced
                )
            ]
        )
    }

    func testBookmarkRegistrationFailureCannotPublishAQueuedJob() async throws {
        let fixture = try makeFixture()
        let resolver = WorkflowApplicationBookmarkResolverStubV4()
        resolver.failedBookmarkCreationRole = .inputFile
        let queue = try makeQueue(fixture: fixture, resolver: resolver)

        do {
            _ = try await queue.enqueue(
                request: request(fixture: fixture),
                preparedPlanBinding: preparedBinding()
            )
            XCTFail("Expected bookmark creation to fail")
        } catch WorkflowApplicationBookmarkResolverStubErrorV4.injectedFailure {
            // Expected.
        }

        let snapshot = try await queue.queueSnapshot()
        XCTAssertTrue(snapshot.items.isEmpty)
    }

    func testPreparedBindingRejectsMismatchedCanonicalAggregateHash() throws {
        let valid = try preparedBinding()
        XCTAssertThrowsError(
            try WorkflowVerifiedPreparedPlanBindingV4(
                sourceIdentityID: valid.sourceIdentityID,
                outputContractID: valid.outputContractID,
                runtimeManifestID: valid.runtimeManifestID,
                planID: valid.planID,
                workflowBackendID: valid.workflowBackendID,
                backendRevisionID: valid.backendRevisionID,
                mediaContractID: valid.mediaContractID,
                resolvedBackendID: valid.resolvedBackendID,
                expectedRuntimeBindingID: WorkflowRuntimeBindingID(
                    workflowApplicationDigest(99)
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? WorkflowApplicationQueueErrorV4,
                .preparedBindingHashMismatch
            )
        }
    }
}

private extension WorkflowApplicationQueueV4Tests {
    struct Fixture {
        let rootURL: URL
        let storeURL: URL
        let inputURL: URL
        let outputDirectoryURL: URL
    }

    func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mirmir-workflow-application-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        let store = root.appendingPathComponent("ApplicationSupport", isDirectory: true)
        let selected = root.appendingPathComponent("Selected", isDirectory: true)
        let output = root.appendingPathComponent("Output", isDirectory: true)
        try FileManager.default.createDirectory(
            at: store,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: selected,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: output,
            withIntermediateDirectories: true
        )
        let input = selected.appendingPathComponent("source.mov")
        try Data("source-media".utf8).write(to: input)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return Fixture(
            rootURL: root,
            storeURL: store,
            inputURL: input,
            outputDirectoryURL: output
        )
    }

    func makeQueue(
        fixture: Fixture,
        resolver: WorkflowApplicationBookmarkResolverStubV4 =
            WorkflowApplicationBookmarkResolverStubV4(),
        clock: WorkflowApplicationQueueTestClockV4 =
            WorkflowApplicationQueueTestClockV4(9_000_000_000),
        workerID: String = "application-worker-test"
    ) throws -> WorkflowApplicationQueueV4 {
        try WorkflowApplicationQueueV4(
            trustedRootURL: fixture.storeURL,
            workerID: try WorkflowWorkerIDV4(workerID),
            resolver: resolver,
            clock: clock,
            tokenFactory: {
                UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
            }
        )
    }

    func request(fixture: Fixture) -> UpscaleRequest {
        UpscaleRequest(
            inputURL: fixture.inputURL,
            outputURL: fixture.outputDirectoryURL
                .appendingPathComponent("upscaled.mov"),
            backendID: .mirmirDeterministicCPU,
            targetWidth: 1_920,
            targetHeight: 1_080,
            outputCodec: .hevc,
            preserveAudio: true,
            overwriteExistingFile: true
        )
    }

    func preparedBinding() throws -> WorkflowVerifiedPreparedPlanBindingV4 {
        try WorkflowVerifiedPreparedPlanBindingV4(
            sourceIdentityID: WorkflowSourceIdentityID(
                workflowApplicationDigest(1)
            ),
            outputContractID: WorkflowOutputContractID(
                workflowApplicationDigest(2)
            ),
            runtimeManifestID: WorkflowRuntimeManifestID(
                workflowApplicationDigest(3)
            ),
            planID: WorkflowPlanID(workflowApplicationDigest(4)),
            workflowBackendID: WorkflowBackendID("ash-cpu-v4"),
            backendRevisionID: WorkflowBackendRevisionID("ash-p06-v4"),
            mediaContractID: WorkflowMediaContractID(
                workflowApplicationDigest(5)
            ),
            resolvedBackendID: .mirmirDeterministicCPU
        )
    }
}

private struct WorkflowApplicationQueueTestClockV4: WorkflowWallClockV4 {
    let value: WorkflowWallClockInstantV4

    init(_ nanoseconds: UInt64) {
        value = WorkflowWallClockInstantV4(
            nanosecondsSinceUnixEpoch: nanoseconds
        )
    }

    func now() -> WorkflowWallClockInstantV4 {
        value
    }
}

private enum WorkflowApplicationBookmarkResolverStubErrorV4: Error {
    case malformedBookmark
    case injectedFailure
}

private final class WorkflowApplicationBookmarkResolverStubV4:
    WorkflowSecurityScopedBookmarkResolvingV4,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var state = State()

    var deniedRole: WorkflowScopedResourceRoleV4? {
        get { lock.withLock { state.deniedRole } }
        set { lock.withLock { state.deniedRole = newValue } }
    }

    var failedBookmarkCreationRole: WorkflowScopedResourceRoleV4? {
        get { lock.withLock { state.failedBookmarkCreationRole } }
        set { lock.withLock { state.failedBookmarkCreationRole = newValue } }
    }

    func makeBookmark(
        for url: URL,
        role: WorkflowScopedResourceRoleV4
    ) throws -> Data {
        if lock.withLock({ state.failedBookmarkCreationRole == role }) {
            throw WorkflowApplicationBookmarkResolverStubErrorV4.injectedFailure
        }
        return Data(url.standardizedFileURL.path.utf8)
    }

    func resolveBookmark(
        _ data: Data,
        role: WorkflowScopedResourceRoleV4
    ) throws -> WorkflowResolvedScopedResourceV4 {
        guard let path = String(data: data, encoding: .utf8),
              path.hasPrefix("/") else {
            throw WorkflowApplicationBookmarkResolverStubErrorV4
                .malformedBookmark
        }
        let url = URL(fileURLWithPath: path)
        return WorkflowResolvedScopedResourceV4(
            url: url,
            isStale: false,
            startAccessing: { [self] in
                lock.withLock { state.deniedRole != role }
            },
            stopAccessing: {}
        )
    }

    private struct State {
        var deniedRole: WorkflowScopedResourceRoleV4?
        var failedBookmarkCreationRole: WorkflowScopedResourceRoleV4?
    }
}

private func workflowApplicationDigest(_ value: Int) -> String {
    String(format: "%064llx", value)
}
