import Foundation
import os.lock
import XCTest
@testable import Mirmir

final class AtomicMediaOutputTests: XCTestCase {
    func testStateMachinePublishesOnlyAfterVerificationAndTerminalCallsAreIdempotent() throws {
        let fixture = try TemporaryOutputFixture()
        defer { fixture.remove() }
        let transaction = try AtomicMediaOutput(
            destinationURL: fixture.destination,
            temporaryIdentifier: "success"
        )
        try Data("completed".utf8).write(to: transaction.temporaryURL)

        XCTAssertEqual(transaction.snapshot.state, .created)
        try transaction.beginWriting()
        XCTAssertEqual(transaction.snapshot.state, .writing)
        try transaction.beginFinishing()
        XCTAssertEqual(transaction.snapshot.state, .finishing)
        try transaction.beginVerifying()
        XCTAssertEqual(transaction.snapshot.state, .verifying)
        try transaction.publish()

        XCTAssertEqual(transaction.snapshot.state, .published)
        XCTAssertEqual(try Data(contentsOf: fixture.destination), Data("completed".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: transaction.temporaryURL.path))
        XCTAssertTrue(transaction.cancel().temporaryFileRemoved)
        XCTAssertTrue(transaction.fail().temporaryFileRemoved)
        XCTAssertEqual(transaction.snapshot.state, .published)
        XCTAssertEqual(try Data(contentsOf: fixture.destination), Data("completed".utf8))
    }

    func testCancellationPreventsPublicationAndRemovesRecognizedTemporary() throws {
        let fixture = try TemporaryOutputFixture()
        defer { fixture.remove() }
        let transaction = try AtomicMediaOutput(
            destinationURL: fixture.destination,
            temporaryIdentifier: "cancel"
        )
        try Data("partial".utf8).write(to: transaction.temporaryURL)
        try transaction.beginWriting()
        try transaction.beginFinishing()
        try transaction.beginVerifying()

        let firstCleanup = transaction.cancel()
        let repeatedCleanup = transaction.cancel()

        XCTAssertEqual(firstCleanup, repeatedCleanup)
        XCTAssertTrue(firstCleanup.temporaryFileRemoved)
        XCTAssertEqual(transaction.snapshot.state, .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: transaction.temporaryURL.path))
        XCTAssertThrowsError(try transaction.publish()) { error in
            XCTAssertEqual(
                error as? AtomicMediaOutputError,
                .invalidTransition(from: .cancelled, to: .published)
            )
        }
    }

    func testCleanupRetriesUnderBoundAndRetainsSuccessfulPostcondition() throws {
        let fixture = try TemporaryOutputFixture()
        defer { fixture.remove() }
        let fileSystem = InjectedAtomicMediaFileSystem(removalFailures: 2)
        let transaction = try AtomicMediaOutput(
            destinationURL: fixture.destination,
            fileSystem: fileSystem,
            cleanupAttemptLimit: 3,
            temporaryIdentifier: "retry"
        )
        try Data("partial".utf8).write(to: transaction.temporaryURL)
        try transaction.beginWriting()

        let cleanup = transaction.fail()

        XCTAssertEqual(cleanup.attempts, 3)
        XCTAssertTrue(cleanup.temporaryFileRemoved)
        XCTAssertNil(cleanup.error)
        XCTAssertEqual(fileSystem.removalCallCount, 3)
        XCTAssertEqual(transaction.fail(), cleanup)
        XCTAssertEqual(fileSystem.removalCallCount, 3)
    }

    func testCleanupFailureIsTypedBoundedRetainedAndIdempotent() throws {
        let fixture = try TemporaryOutputFixture()
        defer { fixture.remove() }
        let fileSystem = InjectedAtomicMediaFileSystem(removalFailures: 10)
        let transaction = try AtomicMediaOutput(
            destinationURL: fixture.destination,
            fileSystem: fileSystem,
            cleanupAttemptLimit: 2,
            temporaryIdentifier: "cleanup-failure"
        )
        try Data("partial".utf8).write(to: transaction.temporaryURL)
        try transaction.beginWriting()

        let cleanup = transaction.cancel()

        XCTAssertEqual(cleanup.attempts, 2)
        XCTAssertFalse(cleanup.temporaryFileRemoved)
        guard case .cleanupFailed(let url, let attempts, _)? = cleanup.error else {
            return XCTFail("Expected typed cleanup failure, received \(String(describing: cleanup.error)).")
        }
        XCTAssertEqual(url, transaction.temporaryURL)
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(transaction.snapshot.state, .cancelled)
        XCTAssertEqual(transaction.cancel(), cleanup)
        XCTAssertEqual(fileSystem.removalCallCount, 2)
    }

    func testExistingDestinationIsRejectedWithoutChangingItsBytes() throws {
        let fixture = try TemporaryOutputFixture()
        defer { fixture.remove() }
        let original = Data("untouched destination".utf8)
        try original.write(to: fixture.destination)

        XCTAssertThrowsError(try AtomicMediaOutput(destinationURL: fixture.destination)) { error in
            XCTAssertEqual(
                error as? AtomicMediaOutputError,
                .destinationAlreadyExists(fixture.destination)
            )
        }
        XCTAssertEqual(try Data(contentsOf: fixture.destination), original)
        XCTAssertTrue(fixture.recognizedTemporaryFiles().isEmpty)
    }

    func testDestinationCreatedDuringWritingWinsRaceAndRemainsUntouched() throws {
        let fixture = try TemporaryOutputFixture()
        defer { fixture.remove() }
        let transaction = try AtomicMediaOutput(
            destinationURL: fixture.destination,
            temporaryIdentifier: "destination-race"
        )
        try Data("candidate".utf8).write(to: transaction.temporaryURL)
        try transaction.beginWriting()
        try transaction.beginFinishing()
        try transaction.beginVerifying()
        let original = Data("race winner".utf8)
        try original.write(to: fixture.destination)

        XCTAssertThrowsError(try transaction.publish()) { error in
            XCTAssertEqual(
                error as? AtomicMediaOutputError,
                .destinationAlreadyExists(fixture.destination)
            )
        }
        XCTAssertEqual(try Data(contentsOf: fixture.destination), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: transaction.temporaryURL.path))
        XCTAssertEqual(transaction.snapshot.state, .failed)
    }

    func testAtomicNoClobberProtectsDestinationCreatedAtPublicationBoundary() throws {
        let fixture = try TemporaryOutputFixture()
        defer { fixture.remove() }
        let winningData = Data("publication boundary winner".utf8)
        let fileSystem = InjectedAtomicMediaFileSystem(
            publicationRacePayload: winningData
        )
        let transaction = try AtomicMediaOutput(
            destinationURL: fixture.destination,
            fileSystem: fileSystem,
            temporaryIdentifier: "atomic-race"
        )
        try Data("candidate".utf8).write(to: transaction.temporaryURL)
        try transaction.beginWriting()
        try transaction.beginFinishing()
        try transaction.beginVerifying()

        XCTAssertThrowsError(try transaction.publish()) { error in
            XCTAssertEqual(
                error as? AtomicMediaOutputError,
                .destinationAlreadyExists(fixture.destination)
            )
        }
        XCTAssertEqual(try Data(contentsOf: fixture.destination), winningData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: transaction.temporaryURL.path))
        XCTAssertEqual(transaction.snapshot.state, .failed)
    }

    func testAtomicRenameFailureDoesNotPublishAndCleansTemporary() throws {
        let fixture = try TemporaryOutputFixture()
        defer { fixture.remove() }
        let fileSystem = InjectedAtomicMediaFileSystem(publicationFails: true)
        let transaction = try AtomicMediaOutput(
            destinationURL: fixture.destination,
            fileSystem: fileSystem,
            temporaryIdentifier: "rename-failure"
        )
        try Data("candidate".utf8).write(to: transaction.temporaryURL)
        try transaction.beginWriting()
        try transaction.beginFinishing()
        try transaction.beginVerifying()

        XCTAssertThrowsError(try transaction.publish()) { error in
            guard let transactionError = error as? AtomicMediaOutputError,
                  case .publishFailed = transactionError else {
                return XCTFail("Expected typed publication failure, received \(error).")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: transaction.temporaryURL.path))
        XCTAssertEqual(transaction.snapshot.state, .failed)
    }
}

private struct TemporaryOutputFixture {
    let directory: URL
    let destination: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        destination = directory.appendingPathComponent("output.mp4")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    func recognizedTemporaryFiles() -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        return contents.filter {
            $0.lastPathComponent.hasPrefix(".output.mirmir-")
                && $0.lastPathComponent.contains(".partial")
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class InjectedAtomicMediaFileSystem: AtomicMediaFileSystem, @unchecked Sendable {
    struct InjectedFailure: Error {}

    private struct State {
        var removalFailuresRemaining: Int
        var removalCallCount = 0
    }

    private let local = LocalAtomicMediaFileSystem()
    private let publicationFails: Bool
    private let publicationRacePayload: Data?
    private let state: OSAllocatedUnfairLock<State>

    init(
        removalFailures: Int = 0,
        publicationFails: Bool = false,
        publicationRacePayload: Data? = nil
    ) {
        self.publicationFails = publicationFails
        self.publicationRacePayload = publicationRacePayload
        self.state = OSAllocatedUnfairLock(initialState: State(
            removalFailuresRemaining: removalFailures
        ))
    }

    var removalCallCount: Int {
        state.withLock { $0.removalCallCount }
    }

    func directoryExists(at url: URL) -> Bool {
        local.directoryExists(at: url)
    }

    func fileExists(at url: URL) -> Bool {
        local.fileExists(at: url)
    }

    func removeItem(at url: URL) throws {
        let fails = state.withLock { state in
            state.removalCallCount += 1
            if state.removalFailuresRemaining > 0 {
                state.removalFailuresRemaining -= 1
                return true
            }
            return false
        }
        if fails { throw InjectedFailure() }
        try local.removeItem(at: url)
    }

    func publishAtomically(from temporaryURL: URL, to destinationURL: URL) throws {
        if publicationFails { throw InjectedFailure() }
        if let publicationRacePayload {
            try publicationRacePayload.write(to: destinationURL)
        }
        try local.publishAtomically(from: temporaryURL, to: destinationURL)
    }
}
