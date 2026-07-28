import Foundation
import os.lock
import XCTest
@testable import Mirmir

final class AtomicMediaOutputPublicationCleanupTests: XCTestCase {
    func testPublicationBoundaryCleanupFailureIsTypedAndRetained() throws {
        let fixture = try TemporaryOutputFixture()
        defer { fixture.remove() }
        let fileSystem = InjectedAtomicMediaFileSystem(
            temporaryMutationPayload: Data("corrupted".utf8),
            verifiedRemovalFails: true
        )
        let transaction = try AtomicMediaOutput(
            destinationURL: fixture.destination,
            fileSystem: fileSystem,
            temporaryIdentifier: "cleanup-failure-at-rename"
        )
        try Data("candidate".utf8).write(to: transaction.temporaryURL)
        try transaction.beginWriting()
        try transaction.beginFinishing()
        try transaction.beginVerifying()

        XCTAssertThrowsError(try transaction.publish()) { error in
            guard let outputError = error as? AtomicMediaOutputError,
                  case .publishFailed(_, _, let cleanupFailure) =
                    outputError else {
                return XCTFail("Expected typed publication cleanup failure.")
            }
            XCTAssertNotNil(cleanupFailure)
        }
        guard case .publishedDestinationCleanupFailed? =
                transaction.snapshot.cleanup?.error else {
            return XCTFail("Expected retained destination cleanup failure.")
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fixture.destination.path)
        )
        XCTAssertEqual(transaction.fail(), transaction.snapshot.cleanup)
    }

    func testPublicationCleanupDoesNotDeleteSubstitutedDestination() throws {
        let fixture = try TemporaryOutputFixture()
        defer { fixture.remove() }
        let replacement = Data("replacement-winner".utf8)
        let observer = RecordingAtomicMediaQuarantineObserver()
        let fileSystem = InjectedAtomicMediaFileSystem(
            temporaryMutationPayload: Data("corrupted".utf8),
            cleanupSubstitutionPayload: replacement,
            localFileSystem: LocalAtomicMediaFileSystem(
                cleanupObserver: observer
            )
        )
        let transaction = try AtomicMediaOutput(
            destinationURL: fixture.destination,
            fileSystem: fileSystem,
            temporaryIdentifier: "cleanup-substitution-at-rename"
        )
        try Data("candidate".utf8).write(to: transaction.temporaryURL)
        try transaction.beginWriting()
        try transaction.beginFinishing()
        try transaction.beginVerifying()

        XCTAssertThrowsError(try transaction.publish()) { error in
            guard let outputError = error as? AtomicMediaOutputError,
                  case .publishFailed(_, _, let cleanupFailure) =
                    outputError else {
                return XCTFail("Expected typed publication cleanup failure.")
            }
            XCTAssertNotNil(cleanupFailure)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.destination), replacement)
        guard case .publishedDestinationCleanupFailed? =
                transaction.snapshot.cleanup?.error else {
            return XCTFail("Expected retained identity mismatch.")
        }
        guard let quarantineURL = observer.quarantineURL else {
            return XCTFail("Expected the replacement to be quarantined.")
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: quarantineURL.path),
            "The mismatched replacement must be restored without clobbering."
        )
    }

    func testPublicationCleanupNeverDeletesReplacementCreatedAfterQuarantine()
        throws {
        let fixture = try TemporaryOutputFixture()
        defer { fixture.remove() }
        let replacement = Data("replacement-after-quarantine".utf8)
        let observer = RecordingAtomicMediaQuarantineObserver(
            replacementPayload: replacement
        )
        let fileSystem = InjectedAtomicMediaFileSystem(
            temporaryMutationPayload: Data("corrupted".utf8),
            localFileSystem: LocalAtomicMediaFileSystem(
                cleanupObserver: observer
            )
        )
        let transaction = try AtomicMediaOutput(
            destinationURL: fixture.destination,
            fileSystem: fileSystem,
            temporaryIdentifier: "replacement-after-quarantine"
        )
        try Data("candidate".utf8).write(to: transaction.temporaryURL)
        try transaction.beginWriting()
        try transaction.beginFinishing()
        try transaction.beginVerifying()

        XCTAssertThrowsError(try transaction.publish()) { error in
            XCTAssertEqual(
                error as? AtomicMediaOutputError,
                .verifiedTemporaryFileChanged(transaction.temporaryURL)
            )
        }
        XCTAssertEqual(
            try Data(contentsOf: fixture.destination),
            replacement
        )
        guard let quarantineURL = observer.quarantineURL else {
            return XCTFail("Expected the failed output to be quarantined.")
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: quarantineURL.path)
        )
        XCTAssertEqual(transaction.snapshot.state, .failed)
        XCTAssertNil(transaction.snapshot.cleanup?.error)
        XCTAssertNil(transaction.publishedOutputIdentity)
    }
}

private final class RecordingAtomicMediaQuarantineObserver:
    AtomicMediaQuarantineCleanupObserving,
    @unchecked Sendable {
    private struct State {
        var quarantineURL: URL?
    }

    private let replacementPayload: Data?
    private let state = OSAllocatedUnfairLock(
        initialState: State()
    )

    init(replacementPayload: Data? = nil) {
        self.replacementPayload = replacementPayload
    }

    var quarantineURL: URL? {
        state.withLock { $0.quarantineURL }
    }

    func didQuarantine(
        destinationURL: URL,
        quarantineURL: URL
    ) throws {
        state.withLock {
            $0.quarantineURL = quarantineURL
        }
        if let replacementPayload {
            try replacementPayload.write(
                to: destinationURL,
                options: .withoutOverwriting
            )
        }
    }
}
