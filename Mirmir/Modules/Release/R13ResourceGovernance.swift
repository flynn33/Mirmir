import CryptoKit
import Foundation

enum R13ResourceGovernanceError: Error, Equatable, Sendable {
    case invalidIdentity(field: String)
    case invalidSHA256(field: String)
    case invalidPolicy(reason: String)
    case invalidRequest(reason: String)
}

enum R13ThermalCondition: Int, Codable, CaseIterable, Comparable, Sendable {
    case nominal
    case fair
    case serious
    case critical

    static func < (lhs: R13ThermalCondition, rhs: R13ThermalCondition) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct R13ResourcePolicy: Equatable, Sendable {
    let policySHA256: String
    let minimumFreeDiskBytes: UInt64
    let minimumFreeMemoryBytes: UInt64
    let maximumThermalCondition: R13ThermalCondition
    let maximumConcurrentJobs: Int

    init(
        policySHA256: String,
        minimumFreeDiskBytes: UInt64,
        minimumFreeMemoryBytes: UInt64,
        maximumThermalCondition: R13ThermalCondition,
        maximumConcurrentJobs: Int
    ) throws {
        guard minimumFreeDiskBytes > 0 else {
            throw R13ResourceGovernanceError.invalidPolicy(
                reason: "minimum_free_disk_bytes_must_be_positive"
            )
        }
        guard minimumFreeMemoryBytes > 0 else {
            throw R13ResourceGovernanceError.invalidPolicy(
                reason: "minimum_free_memory_bytes_must_be_positive"
            )
        }
        guard maximumConcurrentJobs > 0, maximumConcurrentJobs <= 64 else {
            throw R13ResourceGovernanceError.invalidPolicy(
                reason: "maximum_concurrent_jobs_out_of_range"
            )
        }
        self.policySHA256 = try R13ResourceGovernanceValidation.sha256(
            policySHA256,
            field: "resource_policy_sha256"
        )
        self.minimumFreeDiskBytes = minimumFreeDiskBytes
        self.minimumFreeMemoryBytes = minimumFreeMemoryBytes
        self.maximumThermalCondition = maximumThermalCondition
        self.maximumConcurrentJobs = maximumConcurrentJobs
    }
}

enum R13ResourceProbeKind: String, Equatable, Sendable {
    case disk
    case memory
    case thermal
}

struct R13ResourceProbes: Sendable {
    let availableDiskBytes: @Sendable () throws -> UInt64
    let availableMemoryBytes: @Sendable () throws -> UInt64
    let thermalCondition: @Sendable () throws -> R13ThermalCondition

    init(
        availableDiskBytes: @escaping @Sendable () throws -> UInt64,
        availableMemoryBytes: @escaping @Sendable () throws -> UInt64,
        thermalCondition: @escaping @Sendable () throws -> R13ThermalCondition
    ) {
        self.availableDiskBytes = availableDiskBytes
        self.availableMemoryBytes = availableMemoryBytes
        self.thermalCondition = thermalCondition
    }
}

struct R13ResourceObservation: Equatable, Sendable {
    let availableDiskBytes: UInt64
    let availableMemoryBytes: UInt64
    let thermalCondition: R13ThermalCondition
}

enum R13ResourceRejection: Equatable, Sendable {
    case duplicateActiveJob(String)
    case concurrencyLimitReached(limit: Int)
    case insufficientDisk(
        requiredBytes: UInt64,
        availableBytes: UInt64,
        reservedBytes: UInt64,
        minimumFreeBytes: UInt64
    )
    case insufficientMemory(
        requiredBytes: UInt64,
        availableBytes: UInt64,
        reservedBytes: UInt64,
        minimumFreeBytes: UInt64
    )
    case thermalLimitExceeded(
        observed: R13ThermalCondition,
        maximum: R13ThermalCondition
    )
    case resourceArithmeticOverflow
}

final class R13ResourceLease: @unchecked Sendable {
    let leaseIdentity: String
    let jobIdentity: String
    let admissionOrdinal: UInt64
    let reservedDiskBytes: UInt64
    let reservedMemoryBytes: UInt64
    let observation: R13ResourceObservation

    private let lock = NSLock()
    private var released = false

    fileprivate init(
        leaseIdentity: String,
        request: R13ResourceRequest,
        admissionOrdinal: UInt64,
        observation: R13ResourceObservation
    ) {
        self.leaseIdentity = leaseIdentity
        jobIdentity = request.jobIdentity
        self.admissionOrdinal = admissionOrdinal
        reservedDiskBytes = request.requiredDiskBytes
        reservedMemoryBytes = request.requiredMemoryBytes
        self.observation = observation
    }

    var isReleased: Bool {
        lock.lock()
        defer { lock.unlock() }
        return released
    }

    fileprivate func claimRelease() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !released else { return false }
        released = true
        return true
    }
}

enum R13ResourceAdmissionOutcome: Sendable {
    case admitted(R13ResourceLease)
    case rejected(R13ResourceRejection)
    case probeFailed(R13ResourceProbeKind)
}

enum R13ResourceReleaseOutcome: Equatable, Sendable {
    case released(leaseIdentity: String)
    case alreadyReleased(leaseIdentity: String)
    case unknownLease(leaseIdentity: String)
}

enum R13ResourceRecheckOutcome: Sendable {
    case accepted(R13ResourceObservation)
    case rejected(R13ResourceRejection)
    case probeFailed(R13ResourceProbeKind)
    case leaseUnavailable(String)
}

struct R13ResourceGovernorSnapshot: Equatable, Sendable {
    let activeLeaseIdentities: [String]
    let reservedDiskBytes: UInt64
    let reservedMemoryBytes: UInt64
    let nextAdmissionOrdinal: UInt64
}

actor R13ResourceGovernor {
    private struct Reservation {
        let lease: R13ResourceLease
        var remainingDiskBytes: UInt64
        let liveDiskGrowthAllowanceBytes: UInt64
    }

    private let policy: R13ResourcePolicy
    private let probes: R13ResourceProbes
    private var reservations: [String: Reservation] = [:]
    private var leaseIdentityByJob: [String: String] = [:]
    private var reservedDiskBytes: UInt64 = 0
    private var reservedMemoryBytes: UInt64 = 0
    private var nextAdmissionOrdinal: UInt64 = 0

    init(policy: R13ResourcePolicy, probes: R13ResourceProbes) {
        self.policy = policy
        self.probes = probes
    }

    func admit(_ request: R13ResourceRequest) -> R13ResourceAdmissionOutcome {
        if leaseIdentityByJob[request.jobIdentity] != nil {
            return .rejected(.duplicateActiveJob(request.jobIdentity))
        }
        guard reservations.count < policy.maximumConcurrentJobs else {
            return .rejected(
                .concurrencyLimitReached(limit: policy.maximumConcurrentJobs)
            )
        }

        let availableDiskBytes: UInt64
        do {
            availableDiskBytes = try probes.availableDiskBytes()
        } catch {
            return .probeFailed(.disk)
        }
        let availableMemoryBytes: UInt64
        do {
            availableMemoryBytes = try probes.availableMemoryBytes()
        } catch {
            return .probeFailed(.memory)
        }
        let thermalCondition: R13ThermalCondition
        do {
            thermalCondition = try probes.thermalCondition()
        } catch {
            return .probeFailed(.thermal)
        }
        let observation = R13ResourceObservation(
            availableDiskBytes: availableDiskBytes,
            availableMemoryBytes: availableMemoryBytes,
            thermalCondition: thermalCondition
        )

        guard observation.thermalCondition <= policy.maximumThermalCondition else {
            return .rejected(
                .thermalLimitExceeded(
                    observed: observation.thermalCondition,
                    maximum: policy.maximumThermalCondition
                )
            )
        }

        guard let diskRequirement = Self.totalRequirement(
            reserved: reservedDiskBytes,
            requested: request.requiredDiskBytes,
            minimumFree: policy.minimumFreeDiskBytes
        ),
        let memoryRequirement = Self.totalRequirement(
            reserved: reservedMemoryBytes,
            requested: request.requiredMemoryBytes,
            minimumFree: policy.minimumFreeMemoryBytes
        ) else {
            return .rejected(.resourceArithmeticOverflow)
        }
        guard diskRequirement <= observation.availableDiskBytes else {
            return .rejected(
                .insufficientDisk(
                    requiredBytes: request.requiredDiskBytes,
                    availableBytes: observation.availableDiskBytes,
                    reservedBytes: reservedDiskBytes,
                    minimumFreeBytes: policy.minimumFreeDiskBytes
                )
            )
        }
        guard memoryRequirement <= observation.availableMemoryBytes else {
            return .rejected(
                .insufficientMemory(
                    requiredBytes: request.requiredMemoryBytes,
                    availableBytes: observation.availableMemoryBytes,
                    reservedBytes: reservedMemoryBytes,
                    minimumFreeBytes: policy.minimumFreeMemoryBytes
                )
            )
        }

        let ordinal = nextAdmissionOrdinal
        guard ordinal < UInt64.max else {
            return .rejected(.resourceArithmeticOverflow)
        }
        nextAdmissionOrdinal += 1
        let leaseIdentity = Self.leaseIdentity(
            request: request,
            ordinal: ordinal,
            observation: observation,
            policy: policy
        )
        let lease = R13ResourceLease(
            leaseIdentity: leaseIdentity,
            request: request,
            admissionOrdinal: ordinal,
            observation: observation
        )
        reservations[leaseIdentity] = Reservation(
            lease: lease,
            remainingDiskBytes: request.requiredDiskBytes,
            liveDiskGrowthAllowanceBytes:
                request.liveDiskGrowthAllowanceBytes
        )
        leaseIdentityByJob[request.jobIdentity] = leaseIdentity
        reservedDiskBytes += request.requiredDiskBytes
        reservedMemoryBytes += request.requiredMemoryBytes
        return .admitted(lease)
    }

    func release(_ lease: R13ResourceLease) -> R13ResourceReleaseOutcome {
        guard let reservation = reservations[lease.leaseIdentity],
              reservation.lease === lease else {
            return lease.isReleased
                ? .alreadyReleased(leaseIdentity: lease.leaseIdentity)
                : .unknownLease(leaseIdentity: lease.leaseIdentity)
        }
        guard lease.claimRelease() else {
            return .alreadyReleased(leaseIdentity: lease.leaseIdentity)
        }

        reservations.removeValue(forKey: lease.leaseIdentity)
        leaseIdentityByJob.removeValue(forKey: lease.jobIdentity)
        precondition(reservedDiskBytes >= reservation.remainingDiskBytes)
        precondition(reservedMemoryBytes >= lease.reservedMemoryBytes)
        reservedDiskBytes -= reservation.remainingDiskBytes
        reservedMemoryBytes -= lease.reservedMemoryBytes
        return .released(leaseIdentity: lease.leaseIdentity)
    }

    func consumeDiskReservation(
        _ lease: R13ResourceLease,
        bytes: UInt64
    ) -> R13ResourceDiskConsumptionOutcome {
        guard var reservation = reservations[lease.leaseIdentity],
              reservation.lease === lease,
              !lease.isReleased else {
            return .leaseUnavailable(lease.leaseIdentity)
        }
        precondition(
            reservation.remainingDiskBytes
                >= reservation.liveDiskGrowthAllowanceBytes
        )
        let consumableBytes = reservation.remainingDiskBytes
            - reservation.liveDiskGrowthAllowanceBytes
        guard bytes <= consumableBytes else {
            return .exceedsReservation(
                requestedBytes: bytes,
                remainingBytes: consumableBytes
            )
        }
        precondition(reservedDiskBytes >= bytes)
        reservation.remainingDiskBytes -= bytes
        reservedDiskBytes -= bytes
        reservations[lease.leaseIdentity] = reservation
        return .consumed(
            remainingDiskBytes: reservation.remainingDiskBytes
        )
    }

    func recheck(
        _ lease: R13ResourceLease
    ) -> R13ResourceRecheckOutcome {
        guard let reservation = reservations[lease.leaseIdentity],
              reservation.lease === lease,
              !lease.isReleased else {
            return .leaseUnavailable(lease.leaseIdentity)
        }
        let availableDiskBytes: UInt64
        do {
            availableDiskBytes = try probes.availableDiskBytes()
        } catch {
            return .probeFailed(.disk)
        }
        let availableMemoryBytes: UInt64
        do {
            availableMemoryBytes = try probes.availableMemoryBytes()
        } catch {
            return .probeFailed(.memory)
        }
        let thermalCondition: R13ThermalCondition
        do {
            thermalCondition = try probes.thermalCondition()
        } catch {
            return .probeFailed(.thermal)
        }
        let observation = R13ResourceObservation(
            availableDiskBytes: availableDiskBytes,
            availableMemoryBytes: availableMemoryBytes,
            thermalCondition: thermalCondition
        )
        guard thermalCondition <= policy.maximumThermalCondition else {
            return .rejected(
                .thermalLimitExceeded(
                    observed: thermalCondition,
                    maximum: policy.maximumThermalCondition
                )
            )
        }
        precondition(
            reservedDiskBytes
                >= reservation.liveDiskGrowthAllowanceBytes
        )
        let diskReservationsForRecheck = reservedDiskBytes
            - reservation.liveDiskGrowthAllowanceBytes
        precondition(reservedMemoryBytes >= lease.reservedMemoryBytes)
        let otherMemoryReservations = reservedMemoryBytes - lease.reservedMemoryBytes
        guard let diskRequirement = Self.totalRequirement(
            reserved: diskReservationsForRecheck,
            requested: 0,
            minimumFree: policy.minimumFreeDiskBytes
        ),
        let memoryRequirement = Self.totalRequirement(
            reserved: otherMemoryReservations,
            requested: 0,
            minimumFree: policy.minimumFreeMemoryBytes
        ) else {
            return .rejected(.resourceArithmeticOverflow)
        }
        guard diskRequirement <= availableDiskBytes else {
            let currentDiskRequirement = reservation.remainingDiskBytes
                - reservation.liveDiskGrowthAllowanceBytes
            return .rejected(
                .insufficientDisk(
                    requiredBytes: currentDiskRequirement,
                    availableBytes: availableDiskBytes,
                    reservedBytes:
                        reservedDiskBytes - reservation.remainingDiskBytes,
                    minimumFreeBytes: policy.minimumFreeDiskBytes
                )
            )
        }
        guard memoryRequirement <= availableMemoryBytes else {
            return .rejected(
                .insufficientMemory(
                    requiredBytes: lease.reservedMemoryBytes,
                    availableBytes: availableMemoryBytes,
                    reservedBytes:
                        reservedMemoryBytes - lease.reservedMemoryBytes,
                    minimumFreeBytes: policy.minimumFreeMemoryBytes
                )
            )
        }
        return .accepted(observation)
    }
    func snapshot() -> R13ResourceGovernorSnapshot {
        R13ResourceGovernorSnapshot(
            activeLeaseIdentities: reservations.keys.sorted(),
            reservedDiskBytes: reservedDiskBytes,
            reservedMemoryBytes: reservedMemoryBytes,
            nextAdmissionOrdinal: nextAdmissionOrdinal
        )
    }
}

private extension R13ResourceGovernor {
    static func totalRequirement(
        reserved: UInt64,
        requested: UInt64,
        minimumFree: UInt64
    ) -> UInt64? {
        let (activeAndRequested, firstOverflow) = reserved.addingReportingOverflow(
            requested
        )
        let (total, secondOverflow) = activeAndRequested.addingReportingOverflow(
            minimumFree
        )
        return firstOverflow || secondOverflow ? nil : total
    }

    static func leaseIdentity(
        request: R13ResourceRequest,
        ordinal: UInt64,
        observation: R13ResourceObservation,
        policy: R13ResourcePolicy
    ) -> String {
        let input = [
            request.jobIdentity,
            String(request.requiredDiskBytes),
            String(request.liveDiskGrowthAllowanceBytes),
            String(request.requiredMemoryBytes),
            String(ordinal),
            String(observation.availableDiskBytes),
            String(observation.availableMemoryBytes),
            String(observation.thermalCondition.rawValue),
            policy.policySHA256,
            String(policy.minimumFreeDiskBytes),
            String(policy.minimumFreeMemoryBytes),
            String(policy.maximumThermalCondition.rawValue),
            String(policy.maximumConcurrentJobs)
        ].joined(separator: "\u{1f}")
        let digest = SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "r13.lease.\(digest)"
    }
}
