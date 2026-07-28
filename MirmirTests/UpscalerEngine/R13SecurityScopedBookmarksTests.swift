import Foundation
import XCTest
@testable import Mirmir

final class R13SecurityScopedBookmarksTests: XCTestCase {
    func testStaleBookmarkRequiresReauthorizationBeforeAccess() async throws {
        let fixture = try BookmarkFixture()
        defer { fixture.cleanup() }
        let resolver = R13FakeBookmarkResolver(staleRoles: [.source])
        let store = R13SecurityScopedBookmarkStore(
            jobsRootURL: fixture.jobsRoot
        )
        try await store.save(
            jobID: fixture.jobID,
            sourceURL: fixture.sourceURL,
            outputDirectoryURL: fixture.outputURL,
            resolver: resolver
        )

        do {
            _ = try await store.resolveAccess(
                jobID: fixture.jobID,
                resolver: resolver
            )
            XCTFail("A stale source bookmark must fail before use.")
        } catch {
            XCTAssertEqual(
                error as? R13RestartJobError,
                .reauthorizationRequired(role: .source)
            )
        }
        XCTAssertEqual(resolver.startCount(for: .source), 0)
        XCTAssertEqual(
            resolver.startCount(for: .outputDirectory),
            resolver.stopCount(for: .outputDirectory)
        )
    }

    func testSuccessfulAccessOwnsAndThenReleasesBothSecurityScopes() async throws {
        let fixture = try BookmarkFixture()
        defer { fixture.cleanup() }
        let resolver = R13FakeBookmarkResolver()
        let store = R13SecurityScopedBookmarkStore(
            jobsRootURL: fixture.jobsRoot
        )
        try await store.save(
            jobID: fixture.jobID,
            sourceURL: fixture.sourceURL,
            outputDirectoryURL: fixture.outputURL,
            resolver: resolver
        )

        var access: R13SecurityScopedAccessSet? = try await store.resolveAccess(
            jobID: fixture.jobID,
            resolver: resolver
        )
        XCTAssertEqual(access?.url(for: .source), fixture.sourceURL)
        XCTAssertEqual(
            access?.url(for: .outputDirectory),
            fixture.outputURL
        )
        XCTAssertEqual(resolver.startCount(for: .source), 1)
        XCTAssertEqual(resolver.startCount(for: .outputDirectory), 1)
        access = nil
        XCTAssertEqual(resolver.stopCount(for: .source), 1)
        XCTAssertEqual(resolver.stopCount(for: .outputDirectory), 1)
    }

    func testAccessDocumentIsSeparateFromImmutableJobCore() async throws {
        let fixture = try BookmarkFixture()
        defer { fixture.cleanup() }
        let coreURL = fixture.jobDirectory.appendingPathComponent(
            "job-core-v1.json"
        )
        let immutableCore = Data("immutable-core".utf8)
        try immutableCore.write(to: coreURL)
        let store = R13SecurityScopedBookmarkStore(
            jobsRootURL: fixture.jobsRoot
        )

        try await store.save(
            jobID: fixture.jobID,
            sourceURL: fixture.sourceURL,
            outputDirectoryURL: fixture.outputURL,
            resolver: R13FakeBookmarkResolver()
        )

        XCTAssertEqual(try Data(contentsOf: coreURL), immutableCore)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.jobDirectory
                    .appendingPathComponent("access/access-v1.json")
                    .path
            )
        )
    }

    func testCanonicalRecoveryDescriptorAndBookmarksRecreateExactJobAfterRelaunch()
        async throws {
        let fixture = try BookmarkFixture()
        defer { fixture.cleanup() }
        let job = UpscaleJob(
            identifier: fixture.jobID,
            inputURL: fixture.sourceURL,
            outputURL: fixture.outputURL.appendingPathComponent(
                "recovered-output.mp4"
            ),
            targetResolution: .p2160,
            codec: .h264,
            preserveAudio: false,
            mode: .quality
        )
        let resolver = R13FakeBookmarkResolver()
        let bookmarkStore = R13SecurityScopedBookmarkStore(
            jobsRootURL: fixture.jobsRoot
        )
        let recoveryStore = R13RecoveryDescriptorStore(
            jobsRootURL: fixture.jobsRoot
        )
        try await bookmarkStore.save(
            jobID: job.identifier,
            sourceURL: job.inputURL,
            outputDirectoryURL: job.outputURL.deletingLastPathComponent(),
            resolver: resolver
        )
        try await recoveryStore.save(job: job)
        let descriptorURL = fixture.jobDirectory.appendingPathComponent(
            "recovery-v1.json"
        )
        let persistedData = try Data(contentsOf: descriptorURL)
        let persistedDescriptor = try JSONDecoder().decode(
            R13RecoveryDescriptor.self,
            from: persistedData
        )

        XCTAssertEqual(
            persistedData,
            try R13RestartCanonical.data(persistedDescriptor)
        )

        let relaunchedBookmarkStore = R13SecurityScopedBookmarkStore(
            jobsRootURL: fixture.jobsRoot
        )
        let relaunchedRecoveryStore = R13RecoveryDescriptorStore(
            jobsRootURL: fixture.jobsRoot
        )
        let access = try await relaunchedBookmarkStore.resolveAccess(
            jobID: job.identifier,
            resolver: R13FakeBookmarkResolver()
        )
        let listing = try await relaunchedRecoveryStore.list()
        let recovered = try XCTUnwrap(listing.descriptors.first).makeJob(
            access: access
        )

        XCTAssertEqual(listing.descriptors.count, 1)
        XCTAssertEqual(listing.rejectedEntryCount, 0)
        XCTAssertEqual(recovered.identifier, job.identifier)
        XCTAssertEqual(recovered.inputURL, job.inputURL)
        XCTAssertEqual(recovered.outputURL, job.outputURL)
        XCTAssertEqual(recovered.targetResolution, job.targetResolution)
        XCTAssertEqual(recovered.codec, job.codec)
        XCTAssertEqual(recovered.preserveAudio, job.preserveAudio)
        XCTAssertEqual(recovered.mode, job.mode)
    }

    func testDescriptorListingKeepsValidJobWhenOtherEntriesAreRejected()
        async throws {
        let fixture = try BookmarkFixture()
        defer { fixture.cleanup() }
        let store = R13RecoveryDescriptorStore(
            jobsRootURL: fixture.jobsRoot
        )
        let validJob = UpscaleJob(
            identifier: fixture.jobID,
            inputURL: fixture.sourceURL,
            outputURL: fixture.outputURL.appendingPathComponent(
                "valid.mp4"
            ),
            targetResolution: .p2160,
            preserveAudio: false,
            mode: .deterministic
        )
        try await store.save(job: validJob)

        let malformedDirectory = fixture.jobsRoot.appendingPathComponent(
            "malformed-job",
            isDirectory: true
        )
        let orphanDirectory = fixture.jobsRoot.appendingPathComponent(
            "orphan-job",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: malformedDirectory,
            withIntermediateDirectories: false
        )
        try FileManager.default.createDirectory(
            at: orphanDirectory,
            withIntermediateDirectories: false
        )
        try Data("{\"invalid\":true}".utf8).write(
            to: malformedDirectory.appendingPathComponent(
                "recovery-v1.json"
            )
        )

        let listing = try await store.list()

        XCTAssertEqual(listing.descriptors.map(\.jobID), [fixture.jobID])
        XCTAssertEqual(listing.rejectedEntryCount, 2)
    }

    func testCanonicalAccessValidationDoesNotStartSecurityScopes()
        async throws {
        let fixture = try BookmarkFixture()
        defer { fixture.cleanup() }
        let resolver = R13FakeBookmarkResolver()
        let store = R13SecurityScopedBookmarkStore(
            jobsRootURL: fixture.jobsRoot
        )
        try await store.save(
            jobID: fixture.jobID,
            sourceURL: fixture.sourceURL,
            outputDirectoryURL: fixture.outputURL,
            resolver: resolver
        )

        try await store.validateAccessDocument(jobID: fixture.jobID)

        for role in R13BookmarkRole.allCases {
            XCTAssertEqual(resolver.startCount(for: role), 0)
            XCTAssertEqual(resolver.stopCount(for: role), 0)
        }
    }

    func testOnlySelectedJobStartsScopesAndReauthorizationRebindsURLs()
        async throws {
        let fixture = try BookmarkFixture()
        defer { fixture.cleanup() }
        let secondJobID = "job-bookmarks-second"
        try FileManager.default.createDirectory(
            at: fixture.jobsRoot.appendingPathComponent(
                secondJobID,
                isDirectory: true
            ),
            withIntermediateDirectories: false
        )
        let resolver = R13FakeBookmarkResolver()
        let store = R13SecurityScopedBookmarkStore(
            jobsRootURL: fixture.jobsRoot
        )
        try await store.save(
            jobID: fixture.jobID,
            sourceURL: fixture.sourceURL,
            outputDirectoryURL: fixture.outputURL,
            resolver: resolver
        )
        try await store.save(
            jobID: secondJobID,
            sourceURL: fixture.root.appendingPathComponent(
                "unused-source.mov"
            ),
            outputDirectoryURL: fixture.root.appendingPathComponent(
                "UnusedOutput",
                isDirectory: true
            ),
            resolver: resolver
        )
        try await store.validateAccessDocument(jobID: fixture.jobID)
        try await store.validateAccessDocument(jobID: secondJobID)
        for role in R13BookmarkRole.allCases {
            XCTAssertEqual(resolver.startCount(for: role), 0)
        }

        var access: R13SecurityScopedAccessSet? =
            try await store.resolveAccess(
                jobID: fixture.jobID,
                resolver: resolver
            )
        XCTAssertEqual(access?.url(for: .source), fixture.sourceURL)
        for role in R13BookmarkRole.allCases {
            XCTAssertEqual(resolver.startCount(for: role), 1)
        }
        access = nil

        let reboundSource = fixture.root.appendingPathComponent(
            "rebound-source.mov"
        )
        let reboundOutput = fixture.root.appendingPathComponent(
            "ReboundOutput",
            isDirectory: true
        )
        try await store.save(
            jobID: fixture.jobID,
            sourceURL: reboundSource,
            outputDirectoryURL: reboundOutput,
            resolver: resolver
        )
        access = try await store.resolveAccess(
            jobID: fixture.jobID,
            resolver: resolver
        )

        XCTAssertEqual(access?.url(for: .source), reboundSource)
        XCTAssertEqual(
            access?.url(for: .outputDirectory).path,
            reboundOutput.path
        )
    }
}

private struct BookmarkFixture {
    let root: URL
    let jobsRoot: URL
    let jobID = "job-bookmarks"
    let jobDirectory: URL
    let sourceURL: URL
    let outputURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        jobsRoot = root.appendingPathComponent("Jobs", isDirectory: true)
        jobDirectory = jobsRoot.appendingPathComponent(
            jobID,
            isDirectory: true
        )
        sourceURL = root.appendingPathComponent("source.mov")
        outputURL = root.appendingPathComponent("Output", isDirectory: true)
        try FileManager.default.createDirectory(
            at: jobDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: outputURL,
            withIntermediateDirectories: true
        )
        try Data("source".utf8).write(to: sourceURL)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private final class R13FakeBookmarkResolver:
    R13SecurityScopedBookmarkResolving,
    @unchecked Sendable {
    private let staleRoles: Set<R13BookmarkRole>
    private let deniedRoles: Set<R13BookmarkRole>
    private let lock = NSLock()
    private var starts: [R13BookmarkRole: Int] = [:]
    private var stops: [R13BookmarkRole: Int] = [:]

    init(
        staleRoles: Set<R13BookmarkRole> = [],
        deniedRoles: Set<R13BookmarkRole> = []
    ) {
        self.staleRoles = staleRoles
        self.deniedRoles = deniedRoles
    }

    func makeBookmark(
        for url: URL,
        role: R13BookmarkRole
    ) throws -> Data {
        Data("\(role.rawValue)\u{0}\(url.path)".utf8)
    }

    func resolveBookmark(
        _ data: Data,
        role: R13BookmarkRole
    ) throws -> R13ResolvedSecurityScopedBookmark {
        guard let value = String(data: data, encoding: .utf8),
              let separator = value.firstIndex(of: "\u{0}") else {
            throw R13RestartJobError.bookmarkResolutionFailed(role: role)
        }
        let path = String(value[value.index(after: separator)...])
        let url = URL(fileURLWithPath: path)
        return R13ResolvedSecurityScopedBookmark(
            url: url,
            isStale: staleRoles.contains(role),
            startAccessing: { [weak self] in
                guard let self else { return false }
                self.incrementStart(role)
                return !self.deniedRoles.contains(role)
            },
            stopAccessing: { [weak self] in
                self?.incrementStop(role)
            }
        )
    }

    func startCount(for role: R13BookmarkRole) -> Int {
        lock.withLock { starts[role, default: 0] }
    }

    func stopCount(for role: R13BookmarkRole) -> Int {
        lock.withLock { stops[role, default: 0] }
    }

    private func incrementStart(_ role: R13BookmarkRole) {
        lock.withLock {
            starts[role, default: 0] += 1
        }
    }

    private func incrementStop(_ role: R13BookmarkRole) {
        lock.withLock {
            stops[role, default: 0] += 1
        }
    }
}
