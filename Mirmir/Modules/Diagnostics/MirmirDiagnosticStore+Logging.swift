import Foundation

extension MirmirDiagnosticStore {
    static func persistenceBoundary<T>(
        operation: String,
        _ body: () throws -> T
    ) throws -> T {
        do {
            return try body()
        } catch let error as MirmirDiagnosticStoreError {
            throw error
        } catch {
            reportPersistenceFailure(error, operation: operation)
            throw MirmirDiagnosticStoreError.persistenceFailure(
                operation: operation
            )
        }
    }

    static func reportPersistenceFailure(
        _ error: Error,
        operation: String
    ) {
        let nsError = error as NSError
        let errorCode = persistenceErrorCode(error)
        logger.error(
            "Diagnostic \(operation, privacy: .public) failed: \(errorCode, privacy: .public); domain=\(nsError.domain, privacy: .private) code=\(nsError.code, privacy: .public)"
        )
    }

    static func persistenceErrorCode(_ error: Error) -> String {
        switch error {
        case R12ChunkCheckpointError.unsafeFilesystemEntry:
            return "unsafe_filesystem_entry"
        case R12ChunkCheckpointError.atomicWriteFailed:
            return "atomic_write_failed"
        case R12ChunkCheckpointError.durabilityRollbackFailed:
            return "durability_rollback_failed"
        case R12ChunkCheckpointError.ledgerAlreadyExists:
            return "destination_already_exists"
        case R12ChunkCheckpointError.ledgerMissing:
            return "destination_missing"
        case R12ChunkCheckpointError.ledgerSizeLimitExceeded:
            return "size_limit_exceeded"
        case is R12ChunkCheckpointError:
            return "checkpoint_filesystem_failure"
        case MirmirDiagnosticFileSystemError.unsafeEntry:
            return "unsafe_filesystem_entry"
        case MirmirDiagnosticFileSystemError.ioFailure:
            return "io_failure"
        default:
            return "unknown_persistence_failure"
        }
    }
}
