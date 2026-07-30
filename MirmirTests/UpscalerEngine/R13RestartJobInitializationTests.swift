import Foundation
import XCTest
@testable import Mirmir

// Trust-boundary scenarios share one descriptor-pinned filesystem fixture.
// swiftlint:disable file_length
// swiftlint:disable:next type_body_length
final class R13RestartJobInitializationTests: XCTestCase {
    func testTrustedRootTraversalAcceptsRegisteredAlias() throws {
        let fixture = try R13RestartInitializationFixture()
        defer { fixture.cleanup() }
        let alias = try fixture.makeTrustedRootAlias()
        let fileSystem = try R13LocalRestartFileSystem(
            trustedRootURL: alias.presented
        )
        let nested = alias.presented.appendingPathComponent(
            "nested",
            isDirectory: true
        )

        try fileSystem.ensureDirectory(nested)

        XCTAssertNoThrow(try fileSystem.validateDirectory(nested))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: alias.canonical.appendingPathComponent("nested").path
            )
        )
    }

    func testTrustedRootTraversalAcceptsCanonicalPathForRegisteredAlias()
        throws {
        let fixture = try R13RestartInitializationFixture()
        defer { fixture.cleanup() }
        let alias = try fixture.makeTrustedRootAlias()
        let fileSystem = try R13LocalRestartFileSystem(
            trustedRootURL: alias.presented
        )
        let resolvedRoot = R13RestartPath.resolvingExistingAncestor(
            of: alias.presented
        )
        let nested = resolvedRoot.appendingPathComponent(
            "canonical-nested",
            isDirectory: true
        )

        try fileSystem.ensureDirectory(nested)

        XCTAssertNoThrow(try fileSystem.validateDirectory(nested))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: alias.canonical
                    .appendingPathComponent("canonical-nested")
                    .path
            )
        )
    }

    func testTrustedRootTraversalRejectsUnregisteredAlias() throws {
        let fixture = try R13RestartInitializationFixture()
        defer { fixture.cleanup() }
        let alias = try fixture.makeTrustedRootAlias()
        let unregisteredAlias = fixture.root.appendingPathComponent(
            "unregistered-alias",
            isDirectory: true
        )
        try FileManager.default.createSymbolicLink(
            at: unregisteredAlias,
            withDestinationURL: alias.canonical
        )
        let fileSystem = try R13LocalRestartFileSystem(
            trustedRootURL: alias.presented
        )
        let nested = unregisteredAlias.appendingPathComponent(
            "nested",
            isDirectory: true
        )

        XCTAssertThrowsError(try fileSystem.ensureDirectory(nested)) {
            XCTAssertEqual(
                $0 as? R13RestartJobError,
                .unsafeFilesystemEntry(nested.path)
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: alias.canonical.appendingPathComponent("nested").path
            )
        )
    }

    func testTrustedRootTraversalStaysPinnedWhenRegisteredAliasIsRetargeted()
        throws {
        let fixture = try R13RestartInitializationFixture()
        defer { fixture.cleanup() }
        let alias = try fixture.makeTrustedRootAlias()
        let fileSystem = try R13LocalRestartFileSystem(
            trustedRootURL: alias.presented
        )
        let retargetedDirectory = fixture.root.appendingPathComponent(
            "retargeted-root",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: retargetedDirectory,
            withIntermediateDirectories: false
        )
        try FileManager.default.removeItem(at: alias.presented)
        try FileManager.default.createSymbolicLink(
            at: alias.presented,
            withDestinationURL: retargetedDirectory
        )
        let nested = alias.presented.appendingPathComponent(
            "nested",
            isDirectory: true
        )

        try fileSystem.ensureDirectory(nested)

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: alias.canonical.appendingPathComponent("nested").path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: retargetedDirectory
                    .appendingPathComponent("nested")
                    .path
            )
        )
    }

    func testTrustedRootTraversalCreatesNestedDirectory() throws {
        let fixture = try R13RestartInitializationFixture()
        defer { fixture.cleanup() }
        let fileSystem = try R13LocalRestartFileSystem(
            trustedRootURL: fixture.root
        )
        let nested = fixture.jobsRoot
            .appendingPathComponent("nested", isDirectory: true)

        try fileSystem.ensureDirectory(nested)

        XCTAssertNoThrow(try fileSystem.validateDirectory(nested))
    }

    func testTrustedRootTraversalRejectsPathOutsideRoot() throws {
        let fixture = try R13RestartInitializationFixture()
        defer { fixture.cleanup() }
        let fileSystem = try R13LocalRestartFileSystem(
            trustedRootURL: fixture.root
        )
        let outside = fixture.root.deletingLastPathComponent()

        XCTAssertThrowsError(try fileSystem.validateDirectory(outside)) {
            XCTAssertEqual(
                $0 as? R13RestartJobError,
                .unsafeFilesystemEntry(outside.path)
            )
        }
    }

    func testTrustedRootTraversalRejectsSymlinkedDescendant() throws {
        let fixture = try R13RestartInitializationFixture()
        defer { fixture.cleanup() }
        let fileSystem = try R13LocalRestartFileSystem(
            trustedRootURL: fixture.root
        )
        let linkedDirectory = fixture.root.appendingPathComponent(
            "linked",
            isDirectory: true
        )
        try FileManager.default.createSymbolicLink(
            at: linkedDirectory,
            withDestinationURL: fixture.root.deletingLastPathComponent()
        )
        let nested = linkedDirectory.appendingPathComponent(
            "nested",
            isDirectory: true
        )

        XCTAssertThrowsError(try fileSystem.ensureDirectory(nested)) {
            XCTAssertEqual(
                $0 as? R13RestartJobError,
                .unsafeFilesystemEntry(nested.path)
            )
        }
    }

    func testTrustedRootTraversalRejectsSymlinkedDescendantInsideRoot()
        throws {
        let fixture = try R13RestartInitializationFixture()
        defer { fixture.cleanup() }
        let fileSystem = try R13LocalRestartFileSystem(
            trustedRootURL: fixture.root
        )
        let targetDirectory = fixture.root.appendingPathComponent(
            "inside-target",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: targetDirectory,
            withIntermediateDirectories: false
        )
        let linkedDirectory = fixture.root.appendingPathComponent(
            "inside-link",
            isDirectory: true
        )
        try FileManager.default.createSymbolicLink(
            at: linkedDirectory,
            withDestinationURL: targetDirectory
        )
        let nested = linkedDirectory.appendingPathComponent(
            "nested",
            isDirectory: true
        )

        XCTAssertThrowsError(try fileSystem.ensureDirectory(nested)) {
            XCTAssertEqual(
                $0 as? R13RestartJobError,
                .unsafeFilesystemEntry(nested.path)
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: targetDirectory.appendingPathComponent("nested").path
            )
        )
    }

    func testDirectoryRemovalStaysPinnedWhenParentPathIsReplaced()
        throws {
        let fixture = try R13RestartInitializationFixture()
        defer { fixture.cleanup() }
        let fileManager = FileManager.default
        let fileSystem = try R13LocalRestartFileSystem(
            trustedRootURL: fixture.root
        )
        let originalParent = fixture.root.appendingPathComponent(
            "Original",
            isDirectory: true
        )
        let parkedParent = fixture.root.appendingPathComponent(
            "Parked",
            isDirectory: true
        )
        let outsideParent = fixture.root.deletingLastPathComponent()
            .appendingPathComponent(
                "mirmir-r13-removal-outside-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? fileManager.removeItem(at: outsideParent) }
        let directoryToRemove = originalParent.appendingPathComponent(
            "Jobs",
            isDirectory: true
        )
        let nestedDirectory = directoryToRemove.appendingPathComponent(
            "Nested",
            isDirectory: true
        )
        let outsideJobs = outsideParent.appendingPathComponent(
            "Jobs",
            isDirectory: true
        )
        let outsideMarker = outsideJobs.appendingPathComponent("keep.txt")
        try fileManager.createDirectory(
            at: nestedDirectory,
            withIntermediateDirectories: true
        )
        try Data("remove-me".utf8).write(
            to: nestedDirectory.appendingPathComponent("payload.bin")
        )
        try fileManager.createDirectory(
            at: outsideJobs,
            withIntermediateDirectories: true
        )
        try Data("keep-me".utf8).write(to: outsideMarker)

        try fileSystem.removeDirectory(
            directoryToRemove,
            afterPinningParent: {
                try fileManager.moveItem(
                    at: originalParent,
                    to: parkedParent
                )
                try fileManager.createSymbolicLink(
                    at: originalParent,
                    withDestinationURL: outsideParent
                )
            }
        )

        XCTAssertFalse(
            fileManager.fileExists(
                atPath: parkedParent.appendingPathComponent("Jobs").path
            )
        )
        XCTAssertEqual(
            try Data(contentsOf: outsideMarker),
            Data("keep-me".utf8)
        )
        XCTAssertTrue(
            fileManager.fileExists(atPath: directoryToRemove.path)
        )
    }

    func testInitializationFailureLeavesFinalIDRetryable()
        async throws {
        let fixture = try R13RestartInitializationFixture()
        defer { fixture.cleanup() }
        let core = try fixture.makeCore()
        let store = R13RestartJobStore(
            jobsRootURL: fixture.jobsRoot,
            fileSystem: R13InitializationFaultFileSystem(
                fault: .initialization
            )
        )

        do {
            _ = try await store.create(core)
            XCTFail("The injected initialization failure must surface.")
        } catch {
            XCTAssertEqual(
                error as? R13RestartJobError,
                .ioFailure(operation: "injected_initialization")
            )
        }

        XCTAssertFalse(fixture.finalJobExists(core.jobID))
        XCTAssertTrue(try fixture.stagingDirectories().isEmpty)
        _ = try await R13RestartJobStore(
            jobsRootURL: fixture.jobsRoot
        ).create(core)
        XCTAssertTrue(fixture.finalJobExists(core.jobID))
    }

    func testPublicationFailureLeavesFinalIDRetryable()
        async throws {
        let fixture = try R13RestartInitializationFixture()
        defer { fixture.cleanup() }
        let core = try fixture.makeCore()
        let store = R13RestartJobStore(
            jobsRootURL: fixture.jobsRoot,
            fileSystem: R13InitializationFaultFileSystem(
                fault: .publication
            )
        )

        do {
            _ = try await store.create(core)
            XCTFail("The injected publication failure must surface.")
        } catch {
            XCTAssertEqual(
                error as? R13RestartJobError,
                .ioFailure(operation: "injected_publication")
            )
        }

        XCTAssertFalse(fixture.finalJobExists(core.jobID))
        XCTAssertTrue(try fixture.stagingDirectories().isEmpty)
        _ = try await R13RestartJobStore(
            jobsRootURL: fixture.jobsRoot
        ).create(core)
        XCTAssertTrue(fixture.finalJobExists(core.jobID))
    }

    func testCleanupFailureLeavesOnlyNonAuthoritativeStage()
        async throws {
        let fixture = try R13RestartInitializationFixture()
        defer { fixture.cleanup() }
        let core = try fixture.makeCore()
        let store = R13RestartJobStore(
            jobsRootURL: fixture.jobsRoot,
            fileSystem: R13InitializationFaultFileSystem(
                fault: .initializationAndCleanup
            )
        )

        do {
            _ = try await store.create(core)
            XCTFail("The injected cleanup failure must surface.")
        } catch {
            guard case .initializationCleanupFailed(
                let jobID,
                let trigger,
                let cleanup
            )? = error as? R13RestartJobError else {
                return XCTFail(
                    "Expected typed initialization cleanup failure."
                )
            }
            XCTAssertEqual(jobID, core.jobID)
            XCTAssertTrue(trigger.contains("injected_initialization"))
            XCTAssertTrue(cleanup.contains("injected_cleanup"))
        }

        XCTAssertFalse(fixture.finalJobExists(core.jobID))
        XCTAssertEqual(try fixture.stagingDirectories().count, 1)
        _ = try await R13RestartJobStore(
            jobsRootURL: fixture.jobsRoot
        ).create(core)
        XCTAssertTrue(fixture.finalJobExists(core.jobID))
    }

    func testCrashShapedStagingOrphanCannotBlockFinalID()
        async throws {
        let fixture = try R13RestartInitializationFixture()
        defer { fixture.cleanup() }
        let core = try fixture.makeCore()
        let orphan = fixture.jobsRoot.appendingPathComponent(
            ".r13-init-crash-shape",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: orphan,
            withIntermediateDirectories: true
        )
        try Data("incomplete".utf8).write(
            to: orphan.appendingPathComponent("job-core-v1.json")
        )

        _ = try await R13RestartJobStore(
            jobsRootURL: fixture.jobsRoot
        ).create(core)

        XCTAssertTrue(fixture.finalJobExists(core.jobID))
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path))
        _ = try await R13RestartJobStore(
            jobsRootURL: fixture.jobsRoot
        ).reopen(
            jobID: core.jobID,
            expecting: core,
            observedSource: core.source
        )
    }

    func testPublicationRaceNeverClobbersWinningDirectory()
        async throws {
        let fixture = try R13RestartInitializationFixture()
        defer { fixture.cleanup() }
        let core = try fixture.makeCore()
        let store = R13RestartJobStore(
            jobsRootURL: fixture.jobsRoot,
            fileSystem: R13InitializationFaultFileSystem(
                fault: .publicationRace
            )
        )

        do {
            _ = try await store.create(core)
            XCTFail("The publication race winner must retain the final ID.")
        } catch {
            XCTAssertEqual(
                error as? R13RestartJobError,
                .jobAlreadyExists(core.jobID)
            )
        }

        XCTAssertEqual(
            try Data(contentsOf: fixture.raceMarker(core.jobID)),
            Data("race-winner".utf8)
        )
        XCTAssertTrue(try fixture.stagingDirectories().isEmpty)
    }
}

private struct R13RestartInitializationFixture {
    struct TrustedRootAlias {
        let presented: URL
        let canonical: URL
    }

    let root: URL
    let jobsRoot: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "mirmir-r13-initialization-\(UUID().uuidString)",
                isDirectory: true
            )
        jobsRoot = root.appendingPathComponent("Jobs", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
    }

    func makeTrustedRootAlias() throws -> TrustedRootAlias {
        let canonical = root.appendingPathComponent(
            "canonical-root",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: canonical,
            withIntermediateDirectories: false
        )
        let presented = root.appendingPathComponent(
            "registered-alias",
            isDirectory: true
        )
        try FileManager.default.createSymbolicLink(
            at: presented,
            withDestinationURL: canonical
        )
        return TrustedRootAlias(
            presented: presented,
            canonical: canonical
        )
    }

    func makeCore() throws -> R13RestartJobCore {
        try R13RestartJobCore(
            jobID: "r13-transactional-initialization",
            source: R13RestartSourceIdentity(
                sha256: String(repeating: "1", count: 64),
                byteCount: 123
            ),
            processing: R13RestartProcessingIdentity(
                requestedMode: "deterministic",
                effectiveMode: "deterministic",
                routeIdentity: "scale_3_over_2",
                backendIdentity: "r03.mps.lanczos",
                backendRevision: "1"
            ),
            output: R13RestartOutputIdentity(
                width: 4,
                height: 2,
                codec: "h264",
                audioPolicy: "preserve"
            ),
            totalFrameCount: 1
        )
    }

    func finalJobExists(_ jobID: String) -> Bool {
        FileManager.default.fileExists(
            atPath: jobsRoot.appendingPathComponent(jobID).path
        )
    }

    func raceMarker(_ jobID: String) -> URL {
        jobsRoot.appendingPathComponent(jobID, isDirectory: true)
            .appendingPathComponent("race-winner")
    }

    func stagingDirectories() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: jobsRoot.path) else {
            return []
        }
        return try FileManager.default.contentsOfDirectory(
            at: jobsRoot,
            includingPropertiesForKeys: [.isDirectoryKey]
        ).filter {
            $0.lastPathComponent.hasPrefix(".r13-init-")
        }
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private final class R13InitializationFaultFileSystem:
    R13RestartFileSystem,
    @unchecked Sendable {
    enum Fault: Equatable {
        case initialization
        case initializationAndCleanup
        case publication
        case publicationRace
    }

    private let base = R13LocalRestartFileSystem()
    private let fault: Fault

    init(fault: Fault) {
        self.fault = fault
    }

    func ensureDirectory(_ url: URL) throws {
        try base.ensureDirectory(url)
    }

    func createDirectoryExclusively(_ url: URL) throws {
        try base.createDirectoryExclusively(url)
    }

    func validateDirectory(_ url: URL) throws {
        try base.validateDirectory(url)
    }

    func exists(_ url: URL) -> Bool {
        base.exists(url)
    }

    func readRegularFile(_ url: URL, maximumBytes: Int) throws -> Data {
        try base.readRegularFile(url, maximumBytes: maximumBytes)
    }

    func writeNewAtomically(_ data: Data, to url: URL) throws {
        if url.lastPathComponent == "head-v1.json",
           fault == .initialization
            || fault == .initializationAndCleanup {
            throw R13RestartJobError.ioFailure(
                operation: "injected_initialization"
            )
        }
        try base.writeNewAtomically(data, to: url)
    }

    func replaceAtomically(_ data: Data, at url: URL) throws {
        try base.replaceAtomically(data, at: url)
    }

    func publishDirectoryAtomically(
        from sourceURL: URL,
        to destinationURL: URL
    ) throws {
        switch fault {
        case .publication:
            throw R13RestartJobError.ioFailure(
                operation: "injected_publication"
            )
        case .publicationRace:
            try base.createDirectoryExclusively(destinationURL)
            try Data("race-winner".utf8).write(
                to: destinationURL.appendingPathComponent("race-winner")
            )
        case .initialization, .initializationAndCleanup:
            break
        }
        try base.publishDirectoryAtomically(
            from: sourceURL,
            to: destinationURL
        )
    }

    func removeFile(_ url: URL) throws {
        try base.removeFile(url)
    }

    func removeDirectory(_ url: URL) throws {
        if fault == .initializationAndCleanup,
           url.lastPathComponent.hasPrefix(".r13-init-") {
            throw R13RestartJobError.ioFailure(
                operation: "injected_cleanup"
            )
        }
        try base.removeDirectory(url)
    }
}

// swiftlint:enable file_length
