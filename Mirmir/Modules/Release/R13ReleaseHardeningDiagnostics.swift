import Foundation

enum R13SourceSnapshotCleanupError: Error, Equatable, Sendable,
    CustomStringConvertible {
    case cleanupFailed(
        directoryURL: URL,
        attempts: Int,
        triggerReason: String?,
        lastFailure: String
    )

    var description: String {
        switch self {
        case .cleanupFailed(
            let directoryURL,
            let attempts,
            let triggerReason,
            let lastFailure
        ):
            let trigger = triggerReason.map {
                " after the triggering failure \($0)"
            } ?? ""
            return "R13 source snapshot cleanup failed for "
                + "\(directoryURL.lastPathComponent) after \(attempts) "
                + "attempts\(trigger): \(lastFailure)"
        }
    }
}

struct R13SourceSnapshotCleanupResult: Equatable, Sendable {
    let directoryURL: URL
    let attempts: Int
    let snapshotRemoved: Bool
    let error: R13SourceSnapshotCleanupError?
}

enum R13SourceSnapshotCleanup {
    static let attemptLimit = 3

    static func discard(
        _ snapshot: R13RetainedSourceSnapshot,
        using snapshotter: any R13SourceSnapshotting
    ) -> R13SourceSnapshotCleanupResult {
        run(directoryURL: snapshot.directoryURL) {
            try snapshotter.discard(snapshot)
        }
    }

    static func run(
        directoryURL: URL,
        triggerReason: String? = nil,
        operation: () throws -> Void
    ) -> R13SourceSnapshotCleanupResult {
        var attempts = 0
        var lastFailureDescription = "unknown_cleanup_failure"
        while attempts < attemptLimit {
            attempts += 1
            do {
                try operation()
                return R13SourceSnapshotCleanupResult(
                    directoryURL: directoryURL,
                    attempts: attempts,
                    snapshotRemoved: true,
                    error: nil
                )
            } catch {
                lastFailureDescription = String(describing: error)
            }
        }
        let cleanupError = R13SourceSnapshotCleanupError.cleanupFailed(
            directoryURL: directoryURL,
            attempts: attempts,
            triggerReason: triggerReason,
            lastFailure: lastFailureDescription
        )
        return R13SourceSnapshotCleanupResult(
            directoryURL: directoryURL,
            attempts: attempts,
            snapshotRemoved: false,
            error: cleanupError
        )
    }
}

struct R13ReleaseHardeningDiagnosticRecorder: Sendable {
    let diagnostics: R13ReleaseDiagnostics
    let jobIdentitySHA256: String
    let policyResources: R13ReleasePolicyResourceBinding

    func recordIdentity(
        _ identity: R13ReleaseIdentity,
        route: R03ScaleRoute
    ) async throws {
        try await record(
            code: .releaseIdentityCreated,
            severity: .info,
            fields: [
                .releaseIdentitySHA256(identity.identitySHA256),
                .jobIdentitySHA256(jobIdentitySHA256),
                .policySHA256(policyResources.policySHA256),
                .resourceManifestSHA256(
                    policyResources.resourceManifestSHA256
                ),
                .mode(identity.requestedMode),
                .a11Backend,
                .route(route),
                .outcome(.accepted)
            ]
        )
    }

    func recordAdmission(
        _ outcome: R13ResourceAdmissionOutcome
    ) async throws {
        switch outcome {
        case .admitted:
            try await record(
                code: .resourceAdmitted,
                severity: .info,
                fields: [
                    .jobIdentitySHA256(jobIdentitySHA256),
                    .resourceManifestSHA256(
                        policyResources.resourceManifestSHA256
                    ),
                    .outcome(.accepted)
                ]
            )
        case .rejected(let rejection):
            try await record(
                code: .resourceRejected,
                severity: .warning,
                fields: [
                    .jobIdentitySHA256(jobIdentitySHA256),
                    .resourceManifestSHA256(
                        policyResources.resourceManifestSHA256
                    ),
                    .outcome(.rejected),
                    .reason(Self.reason(for: rejection))
                ]
            )
        case .probeFailed:
            try await record(
                code: .resourceRejected,
                severity: .error,
                fields: [
                    .jobIdentitySHA256(jobIdentitySHA256),
                    .resourceManifestSHA256(
                        policyResources.resourceManifestSHA256
                    ),
                    .outcome(.rejected),
                    .reason(.probeFailed)
                ]
            )
        }
    }

    func recordFault(
        point: R13FaultPoint
    ) async throws {
        try await record(
            code: .faultObserved,
            severity: .warning,
            fields: [
                .jobIdentitySHA256(jobIdentitySHA256),
                .faultPoint(point),
                .outcome(.rejected),
                .reason(.injectedFault)
            ]
        )
    }

    func recordOutputReopened(
        identity: R13ReleaseIdentity
    ) async throws {
        try await record(
            code: .outputReopened,
            severity: .info,
            fields: [
                .releaseIdentitySHA256(identity.identitySHA256),
                .jobIdentitySHA256(jobIdentitySHA256),
                .outcome(.reopened)
            ]
        )
    }

    func recordBookmarkReopened() async throws {
        try await record(
            code: .bookmarkReopened,
            severity: .info,
            fields: [
                .jobIdentitySHA256(jobIdentitySHA256),
                .outcome(.reopened)
            ]
        )
    }

    func recordRecoveryDiscovered(
        hasCachedPrefix: Bool
    ) async throws {
        try await record(
            code: .recoveryDiscovered,
            severity: .info,
            fields: [
                .jobIdentitySHA256(jobIdentitySHA256),
                .outcome(hasCachedPrefix ? .reopened : .accepted)
            ]
        )
    }

    func recordRecoveryRejected() async throws {
        try await record(
            code: .recoveryDiscovered,
            severity: .warning,
            fields: [
                .jobIdentitySHA256(jobIdentitySHA256),
                .outcome(.rejected)
            ]
        )
    }

    func recordCacheReplay() async throws {
        try await record(
            code: .cacheFrameReplayed,
            severity: .info,
            fields: [
                .jobIdentitySHA256(jobIdentitySHA256),
                .outcome(.reopened)
            ]
        )
    }

    func recordCacheCommit() async throws {
        try await record(
            code: .cacheFrameCommitted,
            severity: .info,
            fields: [
                .jobIdentitySHA256(jobIdentitySHA256),
                .outcome(.accepted)
            ]
        )
    }

    func recordJobCompleted() async throws {
        try await record(
            code: .jobCompleted,
            severity: .info,
            fields: [
                .jobIdentitySHA256(jobIdentitySHA256),
                .outcome(.released)
            ]
        )
    }

    func recordSourceSnapshotCleanupFailed() async throws {
        try await record(
            code: .sourceSnapshotCleanupFailed,
            severity: .error,
            fields: [
                .jobIdentitySHA256(jobIdentitySHA256),
                .outcome(.notObserved),
                .reason(.sourceSnapshotCleanupFailed)
            ]
        )
    }

    func recordPostpublicationMaintenanceDeferred(
        reason: R13ReleaseDiagnosticReason
    ) async throws {
        try await record(
            code: .postpublicationMaintenanceDeferred,
            severity: .warning,
            fields: [
                .jobIdentitySHA256(jobIdentitySHA256),
                .outcome(.notObserved),
                .reason(reason)
            ]
        )
    }

    func recordRelease(
        _ outcome: R13ResourceReleaseOutcome
    ) async throws {
        let diagnosticOutcome: R13ReleaseDiagnosticOutcome
        switch outcome {
        case .released:
            diagnosticOutcome = .released
        case .alreadyReleased, .unknownLease:
            diagnosticOutcome = .alreadyReleased
        }
        try await record(
            code: .resourceReleased,
            severity: .info,
            fields: [
                .jobIdentitySHA256(jobIdentitySHA256),
                .outcome(diagnosticOutcome)
            ]
        )
    }

    private func record(
        code: R13ReleaseDiagnosticCode,
        severity: R13ReleaseDiagnosticSeverity,
        fields: [
            R13ReleaseDiagnosticField
        ]
    ) async throws {
        let event = try R13ReleaseDiagnosticEvent(
            code: code,
            severity: severity,
            fields: fields
        )
        _ = await diagnostics.record(event)
    }

    private static func reason(
        for rejection: R13ResourceRejection
    ) -> R13ReleaseDiagnosticReason {
        switch rejection {
        case .duplicateActiveJob, .concurrencyLimitReached:
            return .concurrencyLimit
        case .insufficientDisk:
            return .diskInsufficient
        case .insufficientMemory:
            return .memoryInsufficient
        case .thermalLimitExceeded:
            return .thermalLimited
        case .resourceArithmeticOverflow:
            return .probeFailed
        }
    }
}
