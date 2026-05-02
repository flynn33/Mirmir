import Foundation

public final class AllowAllEntitlementProvider: ForsettiEntitlementProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Void>.Continuation] = [:]

    public init() {}

    public func isUnlocked(moduleID _: String, productID _: String?) async -> Bool {
        true
    }

    public func refreshEntitlements() async {
        broadcastChange()
    }

    public func restorePurchases() async throws {
        broadcastChange()
    }

    public func entitlementsDidChangeStream() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let id = UUID()

            lock.lock()
            continuations[id] = continuation
            lock.unlock()

            continuation.onTermination = { [weak self] _ in
                guard let self else {
                    return
                }
                self.lock.lock()
                self.continuations[id] = nil
                self.lock.unlock()
            }
        }
    }

    private func broadcastChange() {
        let currentContinuations: [AsyncStream<Void>.Continuation]
        lock.lock()
        currentContinuations = Array(continuations.values)
        lock.unlock()

        currentContinuations.forEach { $0.yield(()) }
    }
}

public final class StaticEntitlementProvider: ForsettiEntitlementProvider, @unchecked Sendable {
    private let queue = DispatchQueue(label: "forsetti.entitlements.static-provider")
    private var unlockedModuleIDs: Set<String>
    private var unlockedProductIDs: Set<String>
    private var continuations: [UUID: AsyncStream<Void>.Continuation] = [:]

    public init(
        unlockedModuleIDs: Set<String> = [],
        unlockedProductIDs: Set<String> = []
    ) {
        self.unlockedModuleIDs = unlockedModuleIDs
        self.unlockedProductIDs = unlockedProductIDs
    }

    public func isUnlocked(moduleID: String, productID: String?) async -> Bool {
        guard let productID else {
            return true
        }

        return queue.sync {
            unlockedModuleIDs.contains(moduleID) || unlockedProductIDs.contains(productID)
        }
    }

    public func refreshEntitlements() async {
        broadcastChange()
    }

    public func restorePurchases() async throws {
        broadcastChange()
    }

    public func setUnlockedModules(_ moduleIDs: Set<String>) {
        queue.sync {
            unlockedModuleIDs = moduleIDs
        }
        broadcastChange()
    }

    public func setUnlockedProducts(_ productIDs: Set<String>) {
        queue.sync {
            unlockedProductIDs = productIDs
        }
        broadcastChange()
    }

    public func entitlementsDidChangeStream() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let id = UUID()

            queue.sync {
                continuations[id] = continuation
            }

            continuation.onTermination = { [weak self] _ in
                guard let self else {
                    return
                }

                self.queue.sync {
                    self.continuations[id] = nil
                }
            }
        }
    }

    private func broadcastChange() {
        let currentContinuations = queue.sync {
            Array(continuations.values)
        }

        currentContinuations.forEach { $0.yield(()) }
    }
}
