import Foundation
import ForsettiCore

#if canImport(StoreKit)
import StoreKit
#endif

public enum ForsettiEntitlementProviderFactory {
    public static func makeDefault(
        macOSUnlockedModuleIDs: Set<String> = [],
        macOSUnlockedProductIDs: Set<String> = []
    ) -> any ForsettiEntitlementProvider {
        #if os(iOS)
        return StoreKit2EntitlementProvider()
        #elseif os(macOS)
        return StaticEntitlementProvider(
            unlockedModuleIDs: macOSUnlockedModuleIDs,
            unlockedProductIDs: macOSUnlockedProductIDs
        )
        #else
        return AllowAllEntitlementProvider()
        #endif
    }

    /// Returns a debug/test entitlement provider that bypasses StoreKit entirely.
    ///
    /// - With no parameters: unlocks all modules (returns ``AllowAllEntitlementProvider``).
    /// - With specific IDs: unlocks only those modules/products (returns ``StaticEntitlementProvider``).
    ///
    /// Use this in debug builds or unit tests to avoid App Store Connect sandbox setup:
    /// ```swift
    /// let provider = ForsettiEntitlementProviderFactory.makeDebug(
    ///     unlockedProductIDs: ["com.yourapp.iap.premium"]
    /// )
    /// ```
    ///
    /// To change unlock state at runtime, cast to ``StaticEntitlementProvider`` and call
    /// `setUnlockedModules(_:)` or `setUnlockedProducts(_:)`.
    public static func makeDebug(
        unlockedModuleIDs: Set<String> = [],
        unlockedProductIDs: Set<String> = []
    ) -> any ForsettiEntitlementProvider {
        if unlockedModuleIDs.isEmpty && unlockedProductIDs.isEmpty {
            return AllowAllEntitlementProvider()
        }
        return StaticEntitlementProvider(
            unlockedModuleIDs: unlockedModuleIDs,
            unlockedProductIDs: unlockedProductIDs
        )
    }
}

#if canImport(StoreKit)
public final class StoreKit2EntitlementProvider: ForsettiEntitlementProvider, @unchecked Sendable {
    public typealias EntitlementProductFetcher = @Sendable () async -> Set<String>
    public typealias PurchaseSyncAction = @Sendable () async throws -> Void

    private let queue = DispatchQueue(label: "forsetti.entitlements.storekit2-provider")
    private let fetchCurrentEntitlements: EntitlementProductFetcher
    private let syncAction: PurchaseSyncAction

    private var unlockedProductIDs: Set<String> = []
    private var manualUnlockedModuleIDs: Set<String>
    private var continuations: [UUID: AsyncStream<Void>.Continuation] = [:]
    private var transactionUpdateTask: Task<Void, Never>?

    public convenience init(
        manualUnlockedModuleIDs: Set<String> = [],
        observeTransactionUpdates: Bool = true
    ) {
        self.init(
            manualUnlockedModuleIDs: manualUnlockedModuleIDs,
            fetchCurrentEntitlements: { await Self.loadCurrentEntitlementProductIDs() },
            syncAction: { try await Self.syncAppStorePurchases() },
            observeTransactionUpdates: observeTransactionUpdates
        )
    }

    public init(
        manualUnlockedModuleIDs: Set<String> = [],
        fetchCurrentEntitlements: @escaping EntitlementProductFetcher,
        syncAction: @escaping PurchaseSyncAction,
        observeTransactionUpdates: Bool = true
    ) {
        self.manualUnlockedModuleIDs = manualUnlockedModuleIDs
        self.fetchCurrentEntitlements = fetchCurrentEntitlements
        self.syncAction = syncAction

        if observeTransactionUpdates {
            startTransactionUpdatesListener()
        }

        Task {
            await refreshEntitlements()
        }
    }

    deinit {
        transactionUpdateTask?.cancel()
    }

    public func isUnlocked(moduleID: String, productID: String?) async -> Bool {
        guard let productID else {
            return true
        }

        return queue.sync {
            manualUnlockedModuleIDs.contains(moduleID) || unlockedProductIDs.contains(productID)
        }
    }

    public func refreshEntitlements() async {
        let latestUnlockedProductIDs = await fetchCurrentEntitlements()

        let hasChanged = queue.sync {
            let hasChanged = latestUnlockedProductIDs != unlockedProductIDs
            unlockedProductIDs = latestUnlockedProductIDs
            return hasChanged
        }

        if hasChanged {
            broadcastChange()
        }
    }

    public func restorePurchases() async throws {
        try await syncAction()
        await refreshEntitlements()
    }

    public func setManualUnlockedModuleIDs(_ moduleIDs: Set<String>) {
        queue.sync {
            manualUnlockedModuleIDs = moduleIDs
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

    private func startTransactionUpdatesListener() {
        transactionUpdateTask?.cancel()

        transactionUpdateTask = Task.detached(priority: .background) { [weak self] in
            guard let self else {
                return
            }

            for await _ in Transaction.updates {
                await self.refreshEntitlements()
            }
        }
    }

    private func broadcastChange() {
        let currentContinuations = queue.sync {
            Array(continuations.values)
        }

        currentContinuations.forEach { $0.yield(()) }
    }

    private static func loadCurrentEntitlementProductIDs() async -> Set<String> {
        var productIDs: Set<String> = []

        for await result in Transaction.currentEntitlements {
            guard case let .verified(transaction) = result else {
                continue
            }

            if transaction.revocationDate != nil {
                continue
            }

            if let expirationDate = transaction.expirationDate, expirationDate < Date() {
                continue
            }

            productIDs.insert(transaction.productID)
        }

        return productIDs
    }

    private static func syncAppStorePurchases() async throws {
        try await AppStore.sync()
    }
}
#else
public final class StoreKit2EntitlementProvider: ForsettiEntitlementProvider, @unchecked Sendable {
    private let fallbackProvider: StaticEntitlementProvider

    public init(manualUnlockedModuleIDs: Set<String> = []) {
        fallbackProvider = StaticEntitlementProvider(unlockedModuleIDs: manualUnlockedModuleIDs)
    }

    public func isUnlocked(moduleID: String, productID: String?) async -> Bool {
        await fallbackProvider.isUnlocked(moduleID: moduleID, productID: productID)
    }

    public func refreshEntitlements() async {
        await fallbackProvider.refreshEntitlements()
    }

    public func restorePurchases() async throws {
        try await fallbackProvider.restorePurchases()
    }

    public func entitlementsDidChangeStream() -> AsyncStream<Void> {
        fallbackProvider.entitlementsDidChangeStream()
    }
}
#endif
