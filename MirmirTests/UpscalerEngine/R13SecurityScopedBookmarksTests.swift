import Foundation
import XCTest
@testable import Mirmir

// Bookmark lifecycle scenarios share resolver and filesystem test doubles.
// swiftlint:disable file_length type_body_length

final class R13SecurityScopedBookmarksTests: XCTestCase {
    func testStaleBookmarkRefreshesWhileScopesAreActiveAndPersists()
        async throws {
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
        let originalDocument = try fixture.loadAccessDocument()
        let originalSourceData = try XCTUnwrap(
            originalDocument.entries.first {
                $0.role == .source
            }?.bookmarkData
        )

        var access: R13SecurityScopedAccessSet? =
            try await store.resolveAccess(
                jobID: fixture.jobID,
                resolver: resolver
            )

        XCTAssertEqual(access?.url(for: .source), fixture.sourceURL)
        XCTAssertTrue(
            resolver.allRolesWereActiveWhenRefreshing(role: .source)
        )
        XCTAssertEqual(resolver.makeCount(for: .source), 2)
        XCTAssertEqual(resolver.makeCount(for: .outputDirectory), 1)
        let refreshedDocument = try fixture.loadAccessDocument()
        let refreshedSourceData = try XCTUnwrap(
            refreshedDocument.entries.first {
                $0.role == .source
            }?.bookmarkData
        )
        XCTAssertNotEqual(refreshedSourceData, originalSourceData)

        access = nil
        for role in R13BookmarkRole.allCases {
            XCTAssertEqual(resolver.startCount(for: role), 1)
            XCTAssertEqual(resolver.stopCount(for: role), 1)
        }

        var secondAccess: R13SecurityScopedAccessSet? =
            try await store.resolveAccess(
                jobID: fixture.jobID,
                resolver: resolver
            )
        XCTAssertEqual(
            secondAccess?.url(for: .outputDirectory),
            fixture.outputURL
        )
        XCTAssertEqual(resolver.makeCount(for: .source), 2)
        secondAccess = nil
        for role in R13BookmarkRole.allCases {
            XCTAssertEqual(resolver.startCount(for: role), 2)
            XCTAssertEqual(resolver.stopCount(for: role), 2)
        }
    }

    func testTwoStaleBookmarksUseOneAtomicDocumentReplacement()
        async throws {
        let fixture = try BookmarkFixture()
        defer { fixture.cleanup() }
        let resolver = R13FakeBookmarkResolver(
            staleRoles: Set(R13BookmarkRole.allCases)
        )
        let fileSystem = R13BookmarkReplacementFileSystem()
        let store = R13SecurityScopedBookmarkStore(
            jobsRootURL: fixture.jobsRoot,
            fileSystem: fileSystem
        )
        try await store.save(
            jobID: fixture.jobID,
            sourceURL: fixture.sourceURL,
            outputDirectoryURL: fixture.outputURL,
            resolver: resolver
        )

        var access: R13SecurityScopedAccessSet? =
            try await store.resolveAccess(
                jobID: fixture.jobID,
                resolver: resolver
            )

        XCTAssertEqual(access?.url(for: .source), fixture.sourceURL)
        XCTAssertEqual(fileSystem.replacementAttemptCount, 1)
        for role in R13BookmarkRole.allCases {
            XCTAssertEqual(resolver.makeCount(for: role), 2)
            XCTAssertTrue(
                resolver.allRolesWereActiveWhenRefreshing(role: role)
            )
        }
        access = nil
        for role in R13BookmarkRole.allCases {
            XCTAssertEqual(resolver.startCount(for: role), 1)
            XCTAssertEqual(resolver.stopCount(for: role), 1)
        }
    }

    func testRefreshPersistenceFailureReleasesScopesAndPreservesDocument()
        async throws {
        let fixture = try BookmarkFixture()
        defer { fixture.cleanup() }
        let resolver = R13FakeBookmarkResolver(
            staleRoles: Set(R13BookmarkRole.allCases)
        )
        let fileSystem = R13BookmarkReplacementFileSystem(
            failReplacement: true
        )
        let store = R13SecurityScopedBookmarkStore(
            jobsRootURL: fixture.jobsRoot,
            fileSystem: fileSystem
        )
        try await store.save(
            jobID: fixture.jobID,
            sourceURL: fixture.sourceURL,
            outputDirectoryURL: fixture.outputURL,
            resolver: resolver
        )
        let originalDocument = try Data(
            contentsOf: fixture.accessDocumentURL
        )

        do {
            _ = try await store.resolveAccess(
                jobID: fixture.jobID,
                resolver: resolver
            )
            XCTFail("Injected atomic replacement failure must be reported.")
        } catch {
            XCTAssertEqual(
                error as? R13RestartJobError,
                .ioFailure(operation: "injected_bookmark_replace")
            )
        }

        XCTAssertEqual(fileSystem.replacementAttemptCount, 1)
        XCTAssertEqual(
            try Data(contentsOf: fixture.accessDocumentURL),
            originalDocument
        )
        for role in R13BookmarkRole.allCases {
            XCTAssertEqual(resolver.startCount(for: role), 1)
            XCTAssertEqual(resolver.stopCount(for: role), 1)
            XCTAssertTrue(
                resolver.allRolesWereActiveWhenRefreshing(role: role)
            )
        }
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
            "recovery-v2.json"
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
                "recovery-v2.json"
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

    var accessDocumentURL: URL {
        jobDirectory
            .appendingPathComponent("access", isDirectory: true)
            .appendingPathComponent("access-v1.json")
    }

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

    func loadAccessDocument() throws -> R13SecurityScopedAccessDocument {
        try JSONDecoder().decode(
            R13SecurityScopedAccessDocument.self,
            from: Data(contentsOf: accessDocumentURL)
        )
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
    private var bookmarkMakes: [R13BookmarkRole: Int] = [:]
    private var refreshesWithAllRolesActive: Set<R13BookmarkRole> = []

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
        let isStale = lock.withLock {
            bookmarkMakes[role, default: 0] += 1
            let makeCount = bookmarkMakes[role, default: 0]
            if makeCount > 1,
               R13BookmarkRole.allCases.allSatisfy({
                   starts[$0, default: 0] > stops[$0, default: 0]
               }) {
                refreshesWithAllRolesActive.insert(role)
            }
            return staleRoles.contains(role) && makeCount == 1
        }
        let state = isStale ? "stale" : "fresh"
        return Data(
            "\(state)\u{0}\(role.rawValue)\u{0}\(url.path)".utf8
        )
    }

    func resolveBookmark(
        _ data: Data,
        role: R13BookmarkRole
    ) throws -> R13ResolvedSecurityScopedBookmark {
        guard let value = String(data: data, encoding: .utf8) else {
            throw R13RestartJobError.bookmarkResolutionFailed(role: role)
        }
        let components = value.split(
            separator: "\u{0}",
            maxSplits: 2,
            omittingEmptySubsequences: false
        )
        guard components.count == 3,
              String(components[1]) == role.rawValue else {
            throw R13RestartJobError.bookmarkResolutionFailed(role: role)
        }
        let path = String(components[2])
        let url = URL(fileURLWithPath: path)
        return R13ResolvedSecurityScopedBookmark(
            url: url,
            isStale: components[0] == "stale",
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

    func makeCount(for role: R13BookmarkRole) -> Int {
        lock.withLock { bookmarkMakes[role, default: 0] }
    }

    func allRolesWereActiveWhenRefreshing(
        role: R13BookmarkRole
    ) -> Bool {
        lock.withLock {
            refreshesWithAllRolesActive.contains(role)
        }
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

private final class R13BookmarkReplacementFileSystem:
    R13RestartFileSystem,
    @unchecked Sendable {
    private let local = R13LocalRestartFileSystem()
    private let failReplacement: Bool
    private let lock = NSLock()
    private var replacementAttempts = 0

    init(failReplacement: Bool = false) {
        self.failReplacement = failReplacement
    }

    var replacementAttemptCount: Int {
        lock.withLock { replacementAttempts }
    }

    func ensureDirectory(_ url: URL) throws {
        try local.ensureDirectory(url)
    }

    func createDirectoryExclusively(_ url: URL) throws {
        try local.createDirectoryExclusively(url)
    }

    func validateDirectory(_ url: URL) throws {
        try local.validateDirectory(url)
    }

    func exists(_ url: URL) -> Bool {
        local.exists(url)
    }

    func readRegularFile(
        _ url: URL,
        maximumBytes: Int
    ) throws -> Data {
        try local.readRegularFile(url, maximumBytes: maximumBytes)
    }

    func writeNewAtomically(_ data: Data, to url: URL) throws {
        try local.writeNewAtomically(data, to: url)
    }

    func replaceAtomically(_ data: Data, at url: URL) throws {
        let shouldFail = lock.withLock {
            replacementAttempts += 1
            return failReplacement
        }
        guard !shouldFail else {
            throw R13RestartJobError.ioFailure(
                operation: "injected_bookmark_replace"
            )
        }
        try local.replaceAtomically(data, at: url)
    }

    func publishDirectoryAtomically(
        from sourceURL: URL,
        to destinationURL: URL
    ) throws {
        try local.publishDirectoryAtomically(
            from: sourceURL,
            to: destinationURL
        )
    }

    func removeFile(_ url: URL) throws {
        try local.removeFile(url)
    }

    func removeDirectory(_ url: URL) throws {
        try local.removeDirectory(url)
    }
}

// swiftlint:enable file_length type_body_length
