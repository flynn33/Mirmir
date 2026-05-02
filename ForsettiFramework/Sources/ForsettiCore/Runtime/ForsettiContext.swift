import Foundation

@MainActor
public protocol OverlayRouting: Sendable {
    func openPointer(_ pointerID: String)
    func openRoute(_ routeID: String)
}

public enum ModuleCommunicationDecision: Sendable {
    case allowed
    case denied(reason: String)
}

public protocol ModuleCommunicationGuard: Sendable {
    func evaluate(
        sourceModuleID: String,
        targetModuleID: String,
        eventType: String,
        payload: [String: String]
    ) -> ModuleCommunicationDecision
}

public struct DefaultModuleCommunicationGuard: ModuleCommunicationGuard {
    public init() {}

    public func evaluate(
        sourceModuleID: String,
        targetModuleID: String,
        eventType: String,
        payload _: [String: String]
    ) -> ModuleCommunicationDecision {
        if sourceModuleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .denied(reason: "Source module ID cannot be empty.")
        }

        if targetModuleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .denied(reason: "Target module ID cannot be empty.")
        }

        if sourceModuleID == targetModuleID {
            return .denied(reason: "Module relay to self is not required.")
        }

        if eventType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .denied(reason: "Event type cannot be empty.")
        }

        if eventType.hasPrefix("forsetti.internal.") {
            return .denied(reason: "Reserved event namespace cannot be used by modules.")
        }

        return .allowed
    }
}

public enum ForsettiContextError: Error, LocalizedError {
    case moduleCommunicationDenied(reason: String)
    case moduleIdentitySpoofingDenied(expectedModuleID: String, requestedModuleID: String)

    public var errorDescription: String? {
        switch self {
        case let .moduleCommunicationDenied(reason):
            return "Module communication denied. \(reason)"
        case let .moduleIdentitySpoofingDenied(expectedModuleID, requestedModuleID):
            return "Module identity spoofing denied. Expected '\(expectedModuleID)', received '\(requestedModuleID)'."
        }
    }
}

public struct ForsettiModuleLogger: Sendable {
    public let moduleID: String
    private let logger: any ForsettiLogger

    public init(moduleID: String, logger: any ForsettiLogger) {
        self.moduleID = moduleID
        self.logger = logger
    }

    public func debug(_ message: String, metadata: [String: String] = [:]) {
        logger.log(.debug, message: message, sourceModuleID: moduleID, metadata: metadata)
    }

    public func info(_ message: String, metadata: [String: String] = [:]) {
        logger.log(.info, message: message, sourceModuleID: moduleID, metadata: metadata)
    }

    public func warning(_ message: String, metadata: [String: String] = [:]) {
        logger.log(.warning, message: message, sourceModuleID: moduleID, metadata: metadata)
    }

    public func error(
        _ message: String,
        error: (any Error)? = nil,
        metadata: [String: String] = [:]
    ) {
        if let error {
            logger.logError(
                error,
                message: message,
                sourceModuleID: moduleID,
                metadata: metadata
            )
            return
        }

        logger.log(
            .error,
            message: message,
            sourceModuleID: moduleID,
            metadata: metadata
        )
    }
}

public final class ForsettiContext: @unchecked Sendable {
    public let services: any ForsettiServiceProviding
    public let logger: any ForsettiLogger
    public let router: any OverlayRouting
    private let eventBus: ForsettiEventBus
    private let moduleCommunicationGuard: any ModuleCommunicationGuard
    private let boundModuleID: String?
    private static let targetModuleIDPayloadKey = "_forsetti.targetModuleID"

    public init(
        eventBus: ForsettiEventBus,
        services: any ForsettiServiceProviding,
        logger: any ForsettiLogger,
        router: any OverlayRouting,
        moduleCommunicationGuard: any ModuleCommunicationGuard = DefaultModuleCommunicationGuard(),
        boundModuleID: String? = nil
    ) {
        self.eventBus = eventBus
        self.services = services
        self.logger = logger
        self.router = router
        self.moduleCommunicationGuard = moduleCommunicationGuard
        self.boundModuleID = boundModuleID
    }

    public var moduleID: String? {
        boundModuleID
    }

    public func scopedToModule(moduleID: String, grantedCapabilities: Set<Capability>) -> ForsettiContext {
        ForsettiContext(
            eventBus: eventBus,
            services: CapabilityScopedServiceProvider(
                baseProvider: services,
                moduleID: moduleID,
                grantedCapabilities: grantedCapabilities,
                logger: logger
            ),
            logger: logger,
            router: router,
            moduleCommunicationGuard: moduleCommunicationGuard,
            boundModuleID: moduleID
        )
    }

    public func publishFrameworkEvent(
        type: String,
        payload: [String: String] = [:],
        sourceModuleID: String? = nil
    ) {
        let effectiveSourceModuleID = effectiveSourceModuleID(
            requestedModuleID: sourceModuleID,
            operation: "publish framework event"
        )

        eventBus.publish(
            event: ForsettiEvent(
                type: type,
                payload: payload,
                sourceModuleID: effectiveSourceModuleID
            )
        )
    }

    @discardableResult
    public func sendModuleMessage(
        to targetModuleID: String,
        type eventType: String,
        payload: [String: String] = [:]
    ) throws -> ForsettiEvent {
        guard let boundModuleID else {
            throw ForsettiContextError.moduleCommunicationDenied(
                reason: "A module-scoped context is required to send without an explicit source."
            )
        }

        return try sendModuleMessage(
            from: boundModuleID,
            to: targetModuleID,
            type: eventType,
            payload: payload
        )
    }

    @discardableResult
    public func sendModuleMessage(
        from sourceModuleID: String,
        to targetModuleID: String,
        type eventType: String,
        payload: [String: String] = [:]
    ) throws -> ForsettiEvent {
        if let boundModuleID, sourceModuleID != boundModuleID {
            let error = ForsettiContextError.moduleIdentitySpoofingDenied(
                expectedModuleID: boundModuleID,
                requestedModuleID: sourceModuleID
            )
            logger.logError(
                error,
                message: "Blocked module source identity spoofing",
                sourceModuleID: boundModuleID,
                metadata: [
                    "requestedSourceModuleID": sourceModuleID,
                    "targetModuleID": targetModuleID,
                    "eventType": eventType
                ]
            )
            throw error
        }

        let decision = moduleCommunicationGuard.evaluate(
            sourceModuleID: sourceModuleID,
            targetModuleID: targetModuleID,
            eventType: eventType,
            payload: payload
        )

        if case let .denied(reason) = decision {
            reportModuleError(
                moduleID: sourceModuleID,
                message: "Blocked module-to-module communication",
                error: ForsettiContextError.moduleCommunicationDenied(reason: reason),
                metadata: [
                    "eventType": eventType,
                    "targetModuleID": targetModuleID
                ]
            )
            throw ForsettiContextError.moduleCommunicationDenied(reason: reason)
        }

        var enrichedPayload = payload
        enrichedPayload[Self.targetModuleIDPayloadKey] = targetModuleID

        let event = ForsettiEvent(
            type: eventType,
            payload: enrichedPayload,
            sourceModuleID: sourceModuleID
        )
        eventBus.publish(event: event)
        return event
    }

    public func subscribeToModuleMessages(
        moduleID: String,
        eventType: String,
        handler: @escaping @Sendable (ForsettiEvent) -> Void
    ) -> SubscriptionToken {
        eventBus.subscribe(eventType: eventType) { event in
            guard event.payload[Self.targetModuleIDPayloadKey] == moduleID else {
                return
            }
            handler(event)
        }
    }

    public func subscribeToFrameworkEvents(
        eventType: String,
        handler: @escaping @Sendable (ForsettiEvent) -> Void
    ) -> SubscriptionToken {
        eventBus.subscribe(eventType: eventType, handler: handler)
    }

    public func moduleLogger(moduleID: String) -> ForsettiModuleLogger {
        let effectiveModuleID = effectiveSourceModuleID(
            requestedModuleID: moduleID,
            operation: "create module logger"
        ) ?? moduleID
        return ForsettiModuleLogger(moduleID: effectiveModuleID, logger: logger)
    }

    public func logModule(
        _ level: LogLevel,
        moduleID: String,
        message: String,
        metadata: [String: String] = [:]
    ) {
        let effectiveModuleID = effectiveSourceModuleID(
            requestedModuleID: moduleID,
            operation: "log module message"
        ) ?? moduleID
        logger.log(level, message: message, sourceModuleID: effectiveModuleID, metadata: metadata)
    }

    public func reportModuleError(
        moduleID: String,
        message: String,
        error: (any Error)? = nil,
        metadata: [String: String] = [:]
    ) {
        moduleLogger(moduleID: moduleID).error(message, error: error, metadata: metadata)
    }

    private func effectiveSourceModuleID(requestedModuleID: String?, operation: String) -> String? {
        guard let boundModuleID else {
            return requestedModuleID
        }

        guard let requestedModuleID, requestedModuleID != boundModuleID else {
            return boundModuleID
        }

        logger.log(
            .warning,
            message: "Ignored source module ID override during \(operation).",
            sourceModuleID: boundModuleID,
            metadata: ["requestedSourceModuleID": requestedModuleID]
        )
        return boundModuleID
    }
}

@MainActor
public struct NoopOverlayRouter: OverlayRouting {
    public init() {}

    public func openPointer(_ pointerID: String) {}
    public func openRoute(_ routeID: String) {}
}
