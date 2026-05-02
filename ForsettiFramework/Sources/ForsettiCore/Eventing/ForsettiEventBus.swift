import Foundation

public struct ForsettiEvent: Sendable, Hashable {
    public let type: String
    public let payload: [String: String]
    public let sourceModuleID: String?
    public let timestamp: Date

    public init(
        type: String,
        payload: [String: String] = [:],
        sourceModuleID: String? = nil,
        timestamp: Date = Date()
    ) {
        self.type = type
        self.payload = payload
        self.sourceModuleID = sourceModuleID
        self.timestamp = timestamp
    }
}

public protocol ForsettiEventBus: AnyObject {
    func publish(event: ForsettiEvent)
    func subscribe(
        eventType: String,
        handler: @escaping @Sendable (ForsettiEvent) -> Void
    ) -> SubscriptionToken
}

public final class SubscriptionToken: Hashable, @unchecked Sendable {
    private let id = UUID()
    private let cancellation: @Sendable () -> Void
    private let lock = NSLock()
    private var isCancelled = false

    init(cancellation: @escaping @Sendable () -> Void) {
        self.cancellation = cancellation
    }

    public func cancel() {
        lock.lock()
        defer { lock.unlock() }

        guard !isCancelled else {
            return
        }

        isCancelled = true
        cancellation()
    }

    public static func == (lhs: SubscriptionToken, rhs: SubscriptionToken) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

public final class InMemoryEventBus: ForsettiEventBus, @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [String: [UUID: @Sendable (ForsettiEvent) -> Void]] = [:]

    public init() {}

    public func publish(event: ForsettiEvent) {
        let currentHandlers: [@Sendable (ForsettiEvent) -> Void]
        lock.lock()
        if let handlersForEvent = handlers[event.type] {
            currentHandlers = Array(handlersForEvent.values)
        } else {
            currentHandlers = []
        }
        lock.unlock()

        currentHandlers.forEach { handler in
            handler(event)
        }
    }

    public func subscribe(
        eventType: String,
        handler: @escaping @Sendable (ForsettiEvent) -> Void
    ) -> SubscriptionToken {
        let handlerID = UUID()

        lock.lock()
        var eventHandlers = handlers[eventType] ?? [:]
        eventHandlers[handlerID] = handler
        handlers[eventType] = eventHandlers
        lock.unlock()

        return SubscriptionToken { [weak self] in
            guard let self else {
                return
            }

            self.lock.lock()
            defer { self.lock.unlock() }

            self.handlers[eventType]?[handlerID] = nil
            if self.handlers[eventType]?.isEmpty == true {
                self.handlers[eventType] = nil
            }
        }
    }
}
