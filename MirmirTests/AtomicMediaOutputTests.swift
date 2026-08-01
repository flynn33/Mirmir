import Foundation
import os.lock
import XCTest
@testable import Mirmir

// Transaction state, ownership, and adversarial path cases share one fixture.
// swiftlint:disable:next type_body_length
final class AtomicMediaOutputTests: XCTestCase {
    func testPublicationIdentityExposesItsValueContract() {
        let sha256 = String(repeating: "a", count: 64)
        let identity = MediaOutputPublicationIdentity(
            sha256: sha256,
            byteCount: 42
        )

        XCTAssertEqual(identity.sha256, sha256)
        XCTAssertEqual(identity.byteCount, 42)
    }

    func testStableIdentifierDerivesStableIsolatedTemporaryPath() throws {
        let fixture = try TemporaryOutputFixture()
        defer { fixture.remove() }

        let first = try AtomicMediaOutput(
            destinationURL: fixture.destination,
            temporaryIdentifier: "r13-job-001"
        )
        let firstTemporaryURL = first.temporaryURL
        _ = first.fail()
        let reconstructed = try AtomicMediaOutput(
            destinationURL: fixture.destination,
            temporaryIdentifier: "r13-job-001"
        )
        let reconstructedTemporaryURL = reconstructed.temporaryURL
        _ = reconstructed.fail()
        let other = try AtomicMediaOutput(
            destinationURL: fixture.destination,
            temporaryIdentifier: "r13-job-002"
        )

        XCTAssertEqual(firstTemporaryURL, reconstructedTemporaryURL)
        XCTAssertNotEqual(firstTemporaryURL, other.temporaryURL)
    }

    func testOwnedCrashRemnantIsReclaimedBeforeWritingBegins()
        throws {
        let fixture = try TemporaryOutputFixture()
        defer { fixture.remove() }
        let identifier = "stable-retry"
        let temporaryURL = fixture.directory.appendingPathComponent(
            ".output.mirmir-\(identifier).partial.mp4"
        )
        let fileSystem = LocalAtomicMediaFileSystem()
        XCTAssertFalse(
            try fileSystem.reclaimTransactionTemporaryFile(
                at: temporaryURL
            )
        )
        try Data("stale-partial".utf8).write(to: temporaryURL)

        let retry = try AtomicMediaOutput(
            destinationURL: fixture.destination,
            temporaryIdentifier: identifier
        )

        XCTAssertTrue(retry.reclaimedStaleTemporaryFile)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: temporaryURL.path
            )
        )
        XCTAssertEqual(retry.snapshot.state, .created)
    }

    func testReclaimSubstitutionInvalidatesMarkerAndPreservesReplacement()
        throws {
        let fixture = try TemporaryOutputFixture()
        defer { fixture.remove() }
        let identifier = "reclaim-substitution"
        let temporaryURL = fixture.directory.appendingPathComponent(
            ".output.mirmir-\(identifier).partial.mp4"
        )
        let reservingFileSystem = LocalAtomicMediaFileSystem()
        XCTAssertFalse(
            try reservingFileSystem.reclaimTransactionTemporaryFile(
                at: temporaryURL
            )
        )
        try Data("owned-crash-remnant".utf8).write(
            to: temporaryURL
        )
        let replacement = Data("replacement-during-reclaim".utf8)
        let observer = QuarantineReplacingAtomicMediaObserver(
            targetURL: temporaryURL,
            replacementPayload: replacement
        )
        let reclaimingFileSystem = LocalAtomicMediaFileSystem(
            cleanupObserver: observer
        )

        XCTAssertThrowsError(
            try reclaimingFileSystem
                .reclaimTransactionTemporaryFile(at: temporaryURL)
        ) { error in
            XCTAssertEqual(
                error as? AtomicMediaOutputError,
                .unownedTemporaryFilePreserved(temporaryURL)
            )
        }
        XCTAssertEqual(
            try Data(contentsOf: temporaryURL),
            replacement
        )
        XCTAssertTrue(
            fixture.transactionOwnershipMarkers().isEmpty
        )

        XCTAssertThrowsError(
            try LocalAtomicMediaFileSystem()
                .reclaimTransactionTemporaryFile(at: temporaryURL)
        ) { error in
            XCTAssertEqual(
                error as? AtomicMediaOutputError,
                .unownedTemporaryFilePreserved(temporaryURL)
            )
        }
        XCTAssertEqual(
            try Data(contentsOf: temporaryURL),
            replacement
        )
    }

    func testUnmarkedRegularCollisionIsPreserved()
        throws {
        let fixture = try TemporaryOutputFixture()
        defer { fixture.remove() }
        let identifier = "unmarked-collision"
        let temporaryURL = fixture.directory.appendingPathComponent(
            ".output.mirmir-\(identifier).partial.mp4"
        )
        let unrelatedBytes = Data("operator-owned".utf8)
        try unrelatedBytes.write(
            to: temporaryURL,
            options: .withoutOverwriting
        )

        XCTAssertThrowsError(
            try AtomicMediaOutput(
                destinationURL: fixture.destination,
                temporaryIdentifier: identifier
            )
        ) { error in
            XCTAssertEqual(
                error as? AtomicMediaOutputError,
                .unownedTemporaryFilePreserved(temporaryURL)
            )
        }
        XCTAssertEqual(
            try Data(contentsOf: temporaryURL),
            unrelatedBytes
        )
    }

    func testInvalidOwnershipMarkerPreservesRegularCollision()
        throws {
        let fixture = try TemporaryOutputFixture()
        defer { fixture.remove() }
        let identifier = "invalid-marker"
        let temporaryURL = fixture.directory.appendingPathComponent(
            ".output.mirmir-\(identifier).partial.mp4"
        )
        let fileSystem = LocalAtomicMediaFileSystem()
        _ = try fileSystem.reclaimTransactionTemporaryFile(
            at: temporaryURL
        )
        let markerURL = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: fixture.directory,
                includingPropertiesForKeys: nil
            ).first {
                $0.lastPathComponent.hasPrefix(
                    ".mirmir-temporary-owner-"
                )
            }
        )
        try FileManager.default.removeItem(at: markerURL)
        let invalidMarker = Data("not-mirmir-evidence".utf8)
        try invalidMarker.write(
            to: markerURL,
            options: .withoutOverwriting
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: markerURL.path
        )
        let unrelatedBytes = Data("operator-owned".utf8)
        try unrelatedBytes.write(
            to: temporaryURL,
            options: .withoutOverwriting
        )

        XCTAssertThrowsError(
            try AtomicMediaOutput(
                destinationURL: fixture.destination,
                temporaryIdentifier: identifier
            )
        ) { error in
            guard case .unsafeTemporaryFile(let actualURL) =
                error as? AtomicMediaOutputError else {
                return XCTFail(
                    "Expected unsafe ownership marker; received \(error)"
                )
            }
            XCTAssertEqual(
                actualURL.standardizedFileURL.path,
                markerURL.standardizedFileURL.path
            )
        }
        XCTAssertEqual(
            try Data(contentsOf: temporaryURL),
            unrelatedBytes
        )
        XCTAssertEqual(
            try Data(contentsOf: markerURL),
            invalidMarker
        )
    }

    func testActiveTransactionLeaseRejectsSecondLiveWriter()
        throws {
        let fixture = try TemporaryOutputFixture()
        defer { fixture.remove() }
        let first = try AtomicMediaOutput(
            destinationURL: fixture.destination,
            temporaryIdentifier: "first-live-writer"
        )

        XCTAssertThrowsError(
            try AtomicMediaOutput(
                destinationURL: fixture.destination,
                temporaryIdentifier: "second-live-writer"
            )
        ) { error in
            XCTAssertEqual(
                error as? AtomicMediaOutputError,
                .transactionDirectoryBusy(
                    fixture.destination.deletingLastPathComponent()
                )
            )
        }
        _ = first.fail()
    }

    func testCancellationRemovesTransactionLeaseSidecar() throws {
        let fixture = try TemporaryOutputFixture()
        defer { fixture.remove() }
        let transaction = try AtomicMediaOutput(
            destinationURL: fixture.destination,
            temporaryIdentifier: "lease-cleanup"
        )
        let leaseURL = fixture.directory.appendingPathComponent(
            ".output.mirmir-output.lock"
        )

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: leaseURL.path)
        )
        XCTAssertEqual(
            fixture.transactionOwnershipMarkers().count,
            1
        )
        _ = transaction.cancel()
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: leaseURL.path)
        )
        XCTAssertTrue(
            fixture.transactionOwnershipMarkers().isEmpty
        )
    }

    func testCancellationPreservesPreExistingTransactionLeaseSidecar()
        throws {
        let fixture = try TemporaryOutputFixture()
        defer { fixture.remove() }
        let leaseURL = fixture.directory.appendingPathComponent(
            ".output.mirmir-output.lock"
        )
        try Data().write(to: leaseURL, options: .withoutOverwriting)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: leaseURL.path
        )
        let attributesBefore = try FileManager.default
            .attributesOfItem(atPath: leaseURL.path)

        let transaction = try AtomicMediaOutput(
            destinationURL: fixture.destination,
            temporaryIdentifier: "pre-existing-lease"
        )
        _ = transaction.cancel()

        let attributesAfter = try FileManager.default
            .attributesOfItem(atPath: leaseURL.path)
        XCTAssertEqual(
            attributesAfter[.systemNumber] as? NSNumber,
            attributesBefore[.systemNumber] as? NSNumber
        )
        XCTAssertEqual(
            attributesAfter[.systemFileNumber] as? NSNumber,
            attributesBefore[.systemFileNumber] as? NSNumber
        )
    }

    func testLeasePathReplacementFailsClosedAndPreservesReplacement()
        throws {
        let fixture = try TemporaryOutputFixture()
        defer { fixture.remove() }
        let transaction = try AtomicMediaOutput(
            destinationURL: fixture.destination,
            temporaryIdentifier: "replaced-lease"
        )
        let leaseURL = fixture.directory.appendingPathComponent(
            ".output.mirmir-output.lock"
        )
        try FileManager.default.removeItem(at: leaseURL)
        try Data().write(to: leaseURL, options: .withoutOverwriting)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: leaseURL.path
        )
        let replacementAttributes = try FileManager.default
            .attributesOfItem(atPath: leaseURL.path)

        XCTAssertThrowsError(try transaction.beginWriting()) { error in
            guard case .transactionDirectoryUnavailable =
                error as? AtomicMediaOutputError else {
                return XCTFail(
                    "Expected a failed-closed lease validation, got \(error)."
                )
            }
        }
        _ = transaction.cancel()

        let attributesAfter = try FileManager.default
            .attributesOfItem(atPath: leaseURL.path)
        XCTAssertEqual(
            attributesAfter[.systemNumber] as? NSNumber,
            replacementAttributes[.systemNumber] as? NSNumber
        )
        XCTAssertEqual(
            attributesAfter[.systemFileNumber] as? NSNumber,
            replacementAttributes[.systemFileNumber] as? NSNumber
        )
    }

    func testUnsafeCrashRemnantsAreRejectedAndPreserved()
        throws {
        let fixture = try TemporaryOutputFixture()
        defer { fixture.remove() }
        let identifier = "unsafe-remnant"
        let seed = try AtomicMediaOutput(
            destinationURL: fixture.destination,
            temporaryIdentifier: identifier
        )
        let temporaryURL = seed.temporaryURL
        _ = seed.fail()

        try FileManager.default.createDirectory(
            at: temporaryURL,
            withIntermediateDirectories: false
        )
        XCTAssertThrowsError(
            try AtomicMediaOutput(
                destinationURL: fixture.destination,
                temporaryIdentifier: identifier
            )
        ) { error in
            XCTAssertEqual(
                error as? AtomicMediaOutputError,
                .unsafeTemporaryFile(temporaryURL)
            )
        }
        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: temporaryURL.path,
                isDirectory: &isDirectory
            )
        )
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testSymlinkCrashRemnantDoesNotMutateItsTarget()
        throws {
        let fixture = try TemporaryOutputFixture()
        defer { fixture.remove() }
        let identifier = "symlink-remnant"
        let seed = try AtomicMediaOutput(
            destinationURL: fixture.destination,
            temporaryIdentifier: identifier
        )
        let temporaryURL = seed.temporaryURL
        _ = seed.fail()
        let targetURL = fixture.destination
            .deletingLastPathComponent()
            .appendingPathComponent("symlink-target")
        let targetBytes = Data("target-must-survive".utf8)
        try targetBytes.write(to: targetURL)
        try FileManager.default.createSymbolicLink(
            at: temporaryURL,
            withDestinationURL: targetURL
        )

        XCTAssertThrowsError(
            try AtomicMediaOutput(
                destinationURL: fixture.destination,
                temporaryIdentifier: identifier
            )
        ) { error in
            XCTAssertEqual(
                error as? AtomicMediaOutputError,
                .unsafeTemporaryFile(temporaryURL)
            )
        }
        XCTAssertEqual(try Data(contentsOf: targetURL), targetBytes)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: temporaryURL.path
            ),
            targetURL.path
        )
    }

    func testHardLinkedCrashRemnantIsRejectedAndPreserved()
        throws {
        let fixture = try TemporaryOutputFixture()
        defer { fixture.remove() }
        let identifier = "hardlink-remnant"
        let seed = try AtomicMediaOutput(
            destinationURL: fixture.destination,
            temporaryIdentifier: identifier
        )
        let temporaryURL = seed.temporaryURL
        _ = seed.fail()
        let originalURL = fixture.destination
            .deletingLastPathComponent()
            .appendingPathComponent("hardlink-original")
        let originalBytes = Data("linked-data".utf8)
        try originalBytes.write(to: originalURL)
        try FileManager.default.linkItem(
            at: originalURL,
            to: temporaryURL
        )

        XCTAssertThrowsError(
            try AtomicMediaOutput(
                destinationURL: fixture.destination,
                temporaryIdentifier: identifier
            )
        ) { error in
            XCTAssertEqual(
                error as? AtomicMediaOutputError,
                .unsafeTemporaryFile(temporaryURL)
            )
        }
        XCTAssertEqual(try Data(contentsOf: originalURL), originalBytes)
        XCTAssertEqual(try Data(contentsOf: temporaryURL), originalBytes)
    }

    func testUnownedCollisionIsPreservedWithoutRecursiveCleanup()
        throws {
        let fixture = try TemporaryOutputFixture()
        defer { fixture.remove() }
        let transaction = try AtomicMediaOutput(
            destinationURL: fixture.destination,
            temporaryIdentifier: "unowned-collision"
        )
        try transaction.beginWriting()
        try transaction.beginFinishing()
        try FileManager.default.createDirectory(
            at: transaction.temporaryURL,
            withIntermediateDirectories: false
        )
        let nestedURL = transaction.temporaryURL
            .appendingPathComponent("operator-data")
        let nestedBytes = Data("preserve-me".utf8)
        try nestedBytes.write(to: nestedURL)

        let cleanup = transaction.fail()

        XCTAssertFalse(cleanup.temporaryFileRemoved)
        XCTAssertEqual(
            cleanup.error,
            .unownedTemporaryFilePreserved(
                transaction.temporaryURL
            )
        )
        XCTAssertEqual(try Data(contentsOf: nestedURL), nestedBytes)
        XCTAssertTrue(
            fixture.transactionOwnershipMarkers().isEmpty
        )
    }

    func testCleanupPreservesReplacementAtClaimedPath()
        throws {
        let fixture = try TemporaryOutputFixture()
        defer { fixture.remove() }
        let transaction = try AtomicMediaOutput(
            destinationURL: fixture.destination,
            temporaryIdentifier: "claimed-replacement"
        )
        try Data("owned".utf8).write(
            to: transaction.temporaryURL
        )
        try transaction.beginWriting()
        try transaction.beginFinishing()
        try transaction.claimTemporaryFileForVerification()
        try FileManager.default.removeItem(
            at: transaction.temporaryURL
        )
        let replacement = Data("replacement".utf8)
        try replacement.write(to: transaction.temporaryURL)

        let cleanup = transaction.cancel()

        XCTAssertFalse(cleanup.temporaryFileRemoved)
        XCTAssertEqual(
            cleanup.error,
            .unownedTemporaryFilePreserved(
                transaction.temporaryURL
            )
        )
        XCTAssertEqual(
            try Data(contentsOf: transaction.temporaryURL),
            replacement
        )
        XCTAssertTrue(
            fixture.transactionOwnershipMarkers().isEmpty
        )
        XCTAssertThrowsError(
            try AtomicMediaOutput(
                destinationURL: fixture.destination,
                temporaryIdentifier: "claimed-replacement"
            )
        ) { error in
            XCTAssertEqual(
                error as? AtomicMediaOutputError,
                .unownedTemporaryFilePreserved(
                    transaction.temporaryURL
                )
            )
        }
        XCTAssertEqual(
            try Data(contentsOf: transaction.temporaryURL),
            replacement
        )
    }

    func testCleanupSubstitutionDuringMatchingRemovalPreservesReplacement()
        throws {
        let fixture = try TemporaryOutputFixture()
        defer { fixture.remove() }
        let replacement = Data("replacement-during-removal".utf8)
        let fileSystem = InjectedAtomicMediaFileSystem(
            pinnedRemovalSubstitutionPayload: replacement
        )
        let transaction = try AtomicMediaOutput(
            destinationURL: fixture.destination,
            fileSystem: fileSystem,
            cleanupAttemptLimit: 3,
            temporaryIdentifier: "matching-removal-substitution"
        )
        try Data("owned".utf8).write(
            to: transaction.temporaryURL
        )
        try transaction.beginWriting()
        try transaction.beginFinishing()
        try transaction.claimTemporaryFileForVerification()

        let cleanup = transaction.cancel()

        XCTAssertEqual(cleanup.attempts, 1)
        XCTAssertFalse(cleanup.temporaryFileRemoved)
        XCTAssertEqual(
            cleanup.error,
            .unownedTemporaryFilePreserved(
                transaction.temporaryURL
            )
        )
        XCTAssertEqual(fileSystem.removalCallCount, 1)
        XCTAssertEqual(
            try Data(contentsOf: transaction.temporaryURL),
            replacement
        )
        XCTAssertTrue(
            fixture.transactionOwnershipMarkers().isEmpty
        )
        XCTAssertThrowsError(
            try AtomicMediaOutput(
                destinationURL: fixture.destination,
                temporaryIdentifier:
                    "matching-removal-substitution"
            )
        ) { error in
            XCTAssertEqual(
                error as? AtomicMediaOutputError,
                .unownedTemporaryFilePreserved(
                    transaction.temporaryURL
                )
            )
        }
        XCTAssertEqual(
            try Data(contentsOf: transaction.temporaryURL),
            replacement
        )
    }

    func testInvalidStableIdentifiersAreRejectedBeforePathConstruction() throws {
        let fixture = try TemporaryOutputFixture()
        defer { fixture.remove() }
        let invalidIdentifiers = [
            "",
            ".",
            "..",
            "../escape",
            "nested/path",
            "windows\\path",
            "line\nbreak",
            "unicode-\u{00E9}",
            String(repeating: "a", count: 161)
        ]

        for identifier in invalidIdentifiers {
            XCTAssertThrowsError(
                try AtomicMediaOutput(
                    destinationURL: fixture.destination,
                    temporaryIdentifier: identifier
                ),
                "Expected rejection for \(String(reflecting: identifier))."
            ) { error in
                XCTAssertEqual(
                    error as? AtomicMediaOutputError,
                    .invalidTemporaryIdentifier(identifier)
                )
            }
        }
    }

    func testCleanupRemovesOnlyTheIdentityBoundPartial() throws {
        let fixture = try TemporaryOutputFixture()
        defer { fixture.remove() }
        let first = try AtomicMediaOutput(
            destinationURL: fixture.destination,
            temporaryIdentifier: "r13-job-first"
        )
        let secondDestination = fixture.destination
            .deletingLastPathComponent()
            .appendingPathComponent("second.mp4")
        let second = try AtomicMediaOutput(
            destinationURL: secondDestination,
            temporaryIdentifier: "r13-job-second"
        )
        try Data("first".utf8).write(to: first.temporaryURL)
        try Data("second".utf8).write(to: second.temporaryURL)
        try first.beginWriting()
        try second.beginWriting()
        try first.beginFinishing()
        try second.beginFinishing()
        try first.claimTemporaryFileForVerification()
        try second.claimTemporaryFileForVerification()

        let cleanup = first.cancel()

        XCTAssertTrue(cleanup.temporaryFileRemoved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.temporaryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.temporaryURL.path))
        XCTAssertEqual(try Data(contentsOf: second.temporaryURL), Data("second".utf8))
    }

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
        XCTAssertEqual(transaction.publishedOutputIdentity?.byteCount, 9)
        XCTAssertEqual(transaction.publishedOutputIdentity?.sha256.count, 64)
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
        try transaction.beginFinishing()
        try transaction.claimTemporaryFileForVerification()

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
        try transaction.beginFinishing()
        try transaction.claimTemporaryFileForVerification()

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
        XCTAssertEqual(
            fixture.transactionOwnershipMarkers().count,
            1
        )

        let retry = try AtomicMediaOutput(
            destinationURL: fixture.destination,
            temporaryIdentifier: "cleanup-failure"
        )
        XCTAssertTrue(retry.reclaimedStaleTemporaryFile)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: retry.temporaryURL.path
            )
        )
        XCTAssertEqual(
            fixture.transactionOwnershipMarkers().count,
            1
        )
        let retryCleanup = retry.cancel()
        XCTAssertTrue(retryCleanup.temporaryFileRemoved)
        XCTAssertNil(retryCleanup.error)
        XCTAssertTrue(
            fixture.transactionOwnershipMarkers().isEmpty
        )
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

    func testMutationAfterVerificationFailsClosedBeforeRename() throws {
        let fixture = try TemporaryOutputFixture()
        defer { fixture.remove() }
        let transaction = try AtomicMediaOutput(
            destinationURL: fixture.destination,
            temporaryIdentifier: "mutated-before-publish"
        )
        try Data("verified".utf8).write(to: transaction.temporaryURL)
        try transaction.beginWriting()
        try transaction.beginFinishing()
        try transaction.beginVerifying()
        try Data("tampered".utf8).write(to: transaction.temporaryURL)

        XCTAssertThrowsError(try transaction.publish()) { error in
            XCTAssertEqual(
                error as? AtomicMediaOutputError,
                .verifiedTemporaryFileChanged(transaction.temporaryURL)
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: transaction.temporaryURL.path))
        XCTAssertEqual(transaction.snapshot.state, .failed)
        XCTAssertNil(transaction.publishedOutputIdentity)
    }

    func testPathSubstitutionAfterVerificationFailsClosedBeforeRename() throws {
        let fixture = try TemporaryOutputFixture()
        defer { fixture.remove() }
        let transaction = try AtomicMediaOutput(
            destinationURL: fixture.destination,
            temporaryIdentifier: "substituted-before-publish"
        )
        try Data("verified".utf8).write(to: transaction.temporaryURL)
        try transaction.beginWriting()
        try transaction.beginFinishing()
        try transaction.beginVerifying()
        try FileManager.default.removeItem(at: transaction.temporaryURL)
        try Data("replacement".utf8).write(to: transaction.temporaryURL)

        XCTAssertThrowsError(try transaction.publish()) { error in
            XCTAssertEqual(
                error as? AtomicMediaOutputError,
                .verifiedTemporaryFileChanged(transaction.temporaryURL)
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        XCTAssertEqual(transaction.snapshot.state, .failed)
    }

    func testMutationAtPublicationBoundaryRemovesRenamedOutputAndFails() throws {
        let fixture = try TemporaryOutputFixture()
        defer { fixture.remove() }
        let fileSystem = InjectedAtomicMediaFileSystem(
            temporaryMutationPayload: Data("corrupted".utf8)
        )
        let transaction = try AtomicMediaOutput(
            destinationURL: fixture.destination,
            fileSystem: fileSystem,
            temporaryIdentifier: "mutation-at-rename"
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
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: transaction.temporaryURL.path))
        XCTAssertEqual(transaction.snapshot.state, .failed)
        XCTAssertNil(transaction.publishedOutputIdentity)
    }

    func testBrokenSymlinkAtPublishIsPreservedAndReported()
        throws {
        let fixture = try TemporaryOutputFixture()
        defer { fixture.remove() }
        let transaction = try AtomicMediaOutput(
            destinationURL: fixture.destination,
            temporaryIdentifier: "broken-symlink-at-publish"
        )
        try Data("candidate".utf8).write(
            to: transaction.temporaryURL
        )
        try transaction.beginWriting()
        try transaction.beginFinishing()
        try transaction.beginVerifying()
        try FileManager.default.removeItem(
            at: transaction.temporaryURL
        )
        let missingTarget = fixture.directory
            .appendingPathComponent("missing-target")
        try FileManager.default.createSymbolicLink(
            at: transaction.temporaryURL,
            withDestinationURL: missingTarget
        )

        XCTAssertThrowsError(try transaction.publish()) { error in
            XCTAssertEqual(
                error as? AtomicMediaOutputError,
                .temporaryFileMissing(transaction.temporaryURL)
            )
        }
        XCTAssertEqual(transaction.snapshot.state, .failed)
        XCTAssertEqual(
            transaction.snapshot.cleanup?.error,
            .unownedTemporaryFilePreserved(
                transaction.temporaryURL
            )
        )
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: transaction.temporaryURL.path
            ),
            missingTarget.path
        )
    }

}

struct TemporaryOutputFixture {
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

    func transactionOwnershipMarkers() -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        return contents.filter {
            $0.lastPathComponent.hasPrefix(
                ".mirmir-temporary-owner-"
            )
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

final class InjectedAtomicMediaFileSystem: AtomicMediaFileSystem, @unchecked Sendable {
    struct InjectedFailure: Error {}

    private struct State {
        var removalFailuresRemaining: Int
        var removalCallCount = 0
    }

    private let local: LocalAtomicMediaFileSystem
    private let publicationFails: Bool
    private let publicationRacePayload: Data?
    private let temporaryMutationPayload: Data?
    private let verifiedRemovalFails: Bool
    private let cleanupSubstitutionPayload: Data?
    private let pinnedRemovalSubstitutionPayload: Data?
    private let state: OSAllocatedUnfairLock<State>

    init(
        removalFailures: Int = 0,
        publicationFails: Bool = false,
        publicationRacePayload: Data? = nil,
        temporaryMutationPayload: Data? = nil,
        verifiedRemovalFails: Bool = false,
        cleanupSubstitutionPayload: Data? = nil,
        pinnedRemovalSubstitutionPayload: Data? = nil,
        localFileSystem: LocalAtomicMediaFileSystem =
            LocalAtomicMediaFileSystem()
    ) {
        self.local = localFileSystem
        self.publicationFails = publicationFails
        self.publicationRacePayload = publicationRacePayload
        self.temporaryMutationPayload = temporaryMutationPayload
        self.verifiedRemovalFails = verifiedRemovalFails
        self.cleanupSubstitutionPayload = cleanupSubstitutionPayload
        self.pinnedRemovalSubstitutionPayload =
            pinnedRemovalSubstitutionPayload
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

    func pathEntryExists(at url: URL) -> Bool {
        local.pathEntryExists(at: url)
    }

    func acquireTransactionLease(
        for destinationURL: URL
    ) throws -> AtomicMediaTransactionLease {
        try local.acquireTransactionLease(
            for: destinationURL
        )
    }

    func reclaimTransactionTemporaryFile(
        at url: URL
    ) throws -> Bool {
        if local.pathEntryExists(at: url) {
            let fails = recordRemovalAttempt()
            if fails { throw InjectedFailure() }
        }
        return try local.reclaimTransactionTemporaryFile(at: url)
    }

    func discardTransactionTemporaryFileReservation(
        at url: URL
    ) throws {
        try local.discardTransactionTemporaryFileReservation(
            at: url
        )
    }

    func removeItem(at url: URL) throws {
        let fails = recordRemovalAttempt()
        if fails { throw InjectedFailure() }
        try local.removeItem(at: url)
    }

    func removeItem(
        at url: URL,
        ifMatchingFile identity: AtomicMediaPinnedFileIdentity
    ) throws {
        let fails = recordRemovalAttempt()
        if fails { throw InjectedFailure() }
        if let pinnedRemovalSubstitutionPayload {
            try local.removeItem(at: url)
            try pinnedRemovalSubstitutionPayload.write(to: url)
        }
        try local.removeItem(
            at: url,
            ifMatchingFile: identity
        )
    }

    func removeItem(
        at url: URL,
        ifMatching identity: AtomicMediaCleanupFileIdentity
    ) throws {
        if let cleanupSubstitutionPayload {
            try? local.removeItem(at: url)
            try cleanupSubstitutionPayload.write(to: url)
        }
        if verifiedRemovalFails { throw InjectedFailure() }
        try local.removeItem(at: url, ifMatching: identity)
    }

    func publishAtomically(from temporaryURL: URL, to destinationURL: URL) throws {
        if publicationFails { throw InjectedFailure() }
        if let publicationRacePayload {
            try publicationRacePayload.write(to: destinationURL)
        }
        if let temporaryMutationPayload {
            let handle = try FileHandle(forWritingTo: temporaryURL)
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: temporaryMutationPayload)
            try handle.close()
        }
        try local.publishAtomically(from: temporaryURL, to: destinationURL)
    }

    private func recordRemovalAttempt() -> Bool {
        state.withLock { state in
            state.removalCallCount += 1
            if state.removalFailuresRemaining > 0 {
                state.removalFailuresRemaining -= 1
                return true
            }
            return false
        }
    }
}

private final class QuarantineReplacingAtomicMediaObserver:
    AtomicMediaQuarantineCleanupObserving,
    @unchecked Sendable {
    private let targetURL: URL
    private let replacementPayload: Data

    init(
        targetURL: URL,
        replacementPayload: Data
    ) {
        self.targetURL = targetURL
        self.replacementPayload = replacementPayload
    }

    func didQuarantine(
        destinationURL: URL,
        quarantineURL: URL
    ) throws {
        guard destinationURL == targetURL else { return }
        try FileManager.default.removeItem(at: quarantineURL)
        try replacementPayload.write(
            to: quarantineURL,
            options: .withoutOverwriting
        )
    }
}

// Atomic output fixtures intentionally remain adjacent to the state-machine tests.
// swiftlint:disable:this file_length
