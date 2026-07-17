import Foundation
@preconcurrency import Metal
import os.lock

enum ASHMetalFrameResourceRingErrorV3: Error, Equatable, Sendable {
    case invalidCapacity(Int)
    case invalidBufferLength(Int)
    case bufferAllocationFailed(label: String, length: Int)
}

enum ASHMetalFrameBufferKindV3: String, CaseIterable, Sendable {
    case stateSamples = "state_samples"
    case dispatches
    case telemetryReduction = "telemetry_reduction"
    case telemetrySummary = "telemetry_summary"
    case uniforms
}

struct ASHMetalFrameResourceRingSnapshotV3: Equatable, Sendable {
    let capacity: Int
    let availableSlotCount: Int
    let inFlightSlotCount: Int
    let waitingTaskCount: Int
    let peakInFlightSlotCount: Int
    let acquisitionCount: UInt64
    let releaseCount: UInt64
}

struct ASHMetalFrameResourceLeaseV3: Sendable {
    let slot: ASHMetalFrameResourceSlotV3
    fileprivate let generation: UUID
}

final class ASHMetalFrameResourceSlotV3: @unchecked Sendable {
    let index: Int

    private final class RetainedResource: @unchecked Sendable {
        let value: AnyObject

        init(_ value: AnyObject) {
            self.value = value
        }
    }

    private struct State: @unchecked Sendable {
        var buffers: [ASHMetalFrameBufferKindV3: MTLBuffer] = [:]
        var retainedResources: [RetainedResource] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    fileprivate init(index: Int) {
        self.index = index
    }

    func reusableBuffer(
        kind: ASHMetalFrameBufferKindV3,
        minimumLength: Int,
        device: MTLDevice
    ) throws -> MTLBuffer {
        guard minimumLength > 0 else {
            throw ASHMetalFrameResourceRingErrorV3.invalidBufferLength(minimumLength)
        }
        if let existing = state.withLock({ $0.buffers[kind] }),
           existing.length >= minimumLength {
            return existing
        }
        guard let buffer = device.makeBuffer(
            length: minimumLength,
            options: .storageModeShared
        ) else {
            throw ASHMetalFrameResourceRingErrorV3.bufferAllocationFailed(
                label: kind.rawValue,
                length: minimumLength
            )
        }
        buffer.label = "com.mirmir.ash.v3.slot.\(index).\(kind.rawValue)"
        state.withLock { $0.buffers[kind] = buffer }
        return buffer
    }

    func retainFrameResources(_ resources: [AnyObject]) {
        let retained = resources.map(RetainedResource.init)
        state.withLock { state in
            state.retainedResources.append(contentsOf: retained)
        }
    }

    var retainedFrameResourceCount: Int {
        state.withLock { $0.retainedResources.count }
    }

    fileprivate func recycleAfterAppend() {
        state.withLock { $0.retainedResources.removeAll(keepingCapacity: true) }
    }
}

final class ASHMetalFrameResourceRingV3: @unchecked Sendable {
    static let defaultCapacity = 3
    static let maximumCapacity = 3

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<ASHMetalFrameResourceLeaseV3, Error>
    }

    private struct State {
        var availableSlots: [ASHMetalFrameResourceSlotV3]
        var leasedSlotGenerations: [Int: UUID] = [:]
        var waiters: [Waiter] = []
        var cancelledRequestIDs: Set<UUID> = []
        var deliveredRequestIDs: Set<UUID> = []
        var peakInFlightSlotCount = 0
        var acquisitionCount: UInt64 = 0
        var releaseCount: UInt64 = 0
    }

    private enum RegistrationAction {
        case none
        case resume(
            CheckedContinuation<ASHMetalFrameResourceLeaseV3, Error>,
            Result<ASHMetalFrameResourceLeaseV3, Error>
        )
    }

    let capacity: Int
    private let state: OSAllocatedUnfairLock<State>

    init(capacity: Int = defaultCapacity) throws {
        guard (1...Self.maximumCapacity).contains(capacity) else {
            throw ASHMetalFrameResourceRingErrorV3.invalidCapacity(capacity)
        }
        self.capacity = capacity
        self.state = OSAllocatedUnfairLock(initialState: State(
            availableSlots: (0..<capacity).map(ASHMetalFrameResourceSlotV3.init(index:))
        ))
    }

    func acquire() async throws -> ASHMetalFrameResourceLeaseV3 {
        let requestID = UUID()
        let slot = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let action = state.withLock { state -> RegistrationAction in
                    if state.cancelledRequestIDs.remove(requestID) != nil {
                        return .resume(continuation, .failure(CancellationError()))
                    }
                    guard !state.availableSlots.isEmpty else {
                        state.waiters.append(Waiter(
                            id: requestID,
                            continuation: continuation
                        ))
                        return .none
                    }
                    let slot = state.availableSlots.removeFirst()
                    state.leasedSlotGenerations[slot.index] = requestID
                    state.deliveredRequestIDs.insert(requestID)
                    state.acquisitionCount = Self.saturatingIncrement(
                        state.acquisitionCount
                    )
                    state.peakInFlightSlotCount = max(
                        state.peakInFlightSlotCount,
                        state.leasedSlotGenerations.count
                    )
                    return .resume(
                        continuation,
                        .success(ASHMetalFrameResourceLeaseV3(
                            slot: slot,
                            generation: requestID
                        ))
                    )
                }
                Self.perform(action)
            }
        } onCancel: { [weak self] in
            self?.cancel(requestID: requestID)
        }

        let wasCancelled = state.withLock { state in
            state.deliveredRequestIDs.remove(requestID)
            return state.cancelledRequestIDs.remove(requestID) != nil
        }
        if wasCancelled || Task.isCancelled {
            release(slot)
            throw CancellationError()
        }
        return slot
    }

    func release(_ lease: ASHMetalFrameResourceLeaseV3) {
        let action = state.withLock { state -> RegistrationAction in
            let slot = lease.slot
            guard state.leasedSlotGenerations[slot.index] == lease.generation else {
                return .none
            }
            state.leasedSlotGenerations.removeValue(forKey: slot.index)
            slot.recycleAfterAppend()
            state.releaseCount = Self.saturatingIncrement(state.releaseCount)
            guard !state.waiters.isEmpty else {
                state.availableSlots.append(slot)
                state.availableSlots.sort { $0.index < $1.index }
                return .none
            }
            let waiter = state.waiters.removeFirst()
            state.leasedSlotGenerations[slot.index] = waiter.id
            state.deliveredRequestIDs.insert(waiter.id)
            state.acquisitionCount = Self.saturatingIncrement(state.acquisitionCount)
            state.peakInFlightSlotCount = max(
                state.peakInFlightSlotCount,
                state.leasedSlotGenerations.count
            )
            return .resume(
                waiter.continuation,
                .success(ASHMetalFrameResourceLeaseV3(
                    slot: slot,
                    generation: waiter.id
                ))
            )
        }
        Self.perform(action)
    }

    func snapshot() -> ASHMetalFrameResourceRingSnapshotV3 {
        state.withLock { state in
            ASHMetalFrameResourceRingSnapshotV3(
                capacity: capacity,
                availableSlotCount: state.availableSlots.count,
                inFlightSlotCount: state.leasedSlotGenerations.count,
                waitingTaskCount: state.waiters.count,
                peakInFlightSlotCount: state.peakInFlightSlotCount,
                acquisitionCount: state.acquisitionCount,
                releaseCount: state.releaseCount
            )
        }
    }

    private func cancel(requestID: UUID) {
        let action = state.withLock { state -> RegistrationAction in
            if let index = state.waiters.firstIndex(where: { $0.id == requestID }) {
                let waiter = state.waiters.remove(at: index)
                return .resume(waiter.continuation, .failure(CancellationError()))
            }
            state.cancelledRequestIDs.insert(requestID)
            return .none
        }
        Self.perform(action)
    }

    private static func perform(_ action: RegistrationAction) {
        switch action {
        case .none:
            break
        case .resume(let continuation, let result):
            continuation.resume(with: result)
        }
    }

    private static func saturatingIncrement(_ value: UInt64) -> UInt64 {
        let result = value.addingReportingOverflow(1)
        return result.overflow ? .max : result.partialValue
    }
}
