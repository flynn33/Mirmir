import Foundation
import os.lock

final class R13ReleaseTaskStartGate: @unchecked Sendable {
    private struct State {
        var isOpen = false
        var waiter: CheckedContinuation<Void, Never>?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func waitUntilOpen() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = state.withLock { current in
                if current.isOpen {
                    return true
                }
                precondition(
                    current.waiter == nil,
                    "The R13 task start gate supports one waiter."
                )
                current.waiter = continuation
                return false
            }
            if resumeImmediately {
                continuation.resume()
            }
        }
    }

    func open() {
        let waiter: CheckedContinuation<Void, Never>? =
            state.withLock { current in
            guard !current.isOpen else { return nil }
            current.isOpen = true
            defer { current.waiter = nil }
            return current.waiter
        }
        waiter?.resume()
    }
}
