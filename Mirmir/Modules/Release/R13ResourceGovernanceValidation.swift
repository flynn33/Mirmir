import Foundation

enum R13ResourceDiskConsumptionOutcome: Equatable, Sendable {
    case consumed(remainingDiskBytes: UInt64)
    case exceedsReservation(requestedBytes: UInt64, remainingBytes: UInt64)
    case leaseUnavailable(String)
}

struct R13ResourceRequest: Equatable, Sendable {
    let jobIdentity: String
    let requiredDiskBytes: UInt64
    /// Reserved globally, but excluded from the owning lease's live recheck.
    let liveDiskGrowthAllowanceBytes: UInt64
    let requiredMemoryBytes: UInt64

    init(
        jobIdentity: String,
        requiredDiskBytes: UInt64,
        liveDiskGrowthAllowanceBytes: UInt64 = 0,
        requiredMemoryBytes: UInt64
    ) throws {
        guard requiredDiskBytes > 0 else {
            throw R13ResourceGovernanceError.invalidRequest(
                reason: "required_disk_bytes_must_be_positive"
            )
        }
        guard liveDiskGrowthAllowanceBytes <= requiredDiskBytes else {
            throw R13ResourceGovernanceError.invalidRequest(
                reason: "live_disk_growth_allowance_exceeds_required_disk"
            )
        }
        guard requiredMemoryBytes > 0 else {
            throw R13ResourceGovernanceError.invalidRequest(
                reason: "required_memory_bytes_must_be_positive"
            )
        }
        self.jobIdentity = try R13ResourceGovernanceValidation.identity(
            jobIdentity,
            field: "resource_job_identity"
        )
        self.requiredDiskBytes = requiredDiskBytes
        self.liveDiskGrowthAllowanceBytes =
            liveDiskGrowthAllowanceBytes
        self.requiredMemoryBytes = requiredMemoryBytes
    }
}

enum R13ResourceGovernanceValidation {
    static func identity(_ value: String, field: String) throws -> String {
        do {
            return try R13ReleaseIdentityValidation.identity(
                value,
                field: field
            )
        } catch {
            throw R13ResourceGovernanceError.invalidIdentity(field: field)
        }
    }

    static func sha256(_ value: String, field: String) throws -> String {
        do {
            return try R13ReleaseIdentityValidation.sha256(
                value,
                field: field
            )
        } catch {
            throw R13ResourceGovernanceError.invalidSHA256(field: field)
        }
    }
}
