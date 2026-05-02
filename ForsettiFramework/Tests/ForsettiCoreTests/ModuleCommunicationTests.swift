import Foundation
import XCTest
@testable import ForsettiCore

@MainActor
final class ModuleCommunicationTests: XCTestCase {
    func testSendModuleMessagePublishesTargetedEventWhenAllowed() throws {
        let context = ForsettiContext(
            eventBus: InMemoryEventBus(),
            services: ForsettiServiceContainer(),
            logger: CommunicationRecordingLogger(),
            router: NoopOverlayRouter()
        )

        let expectation = expectation(description: "Targeted module message received")
        let receivedEventBox = EventBox()

        let token = context.subscribeToModuleMessages(moduleID: "com.forsetti.module.b", eventType: "module.message") { event in
            receivedEventBox.event = event
            expectation.fulfill()
        }
        defer { token.cancel() }

        let sentEvent = try context.sendModuleMessage(
            from: "com.forsetti.module.a",
            to: "com.forsetti.module.b",
            type: "module.message",
            payload: ["purpose": "sync"]
        )

        wait(for: [expectation], timeout: 1)

        XCTAssertEqual(sentEvent.sourceModuleID, "com.forsetti.module.a")
        XCTAssertEqual(receivedEventBox.event?.type, "module.message")
        XCTAssertEqual(receivedEventBox.event?.sourceModuleID, "com.forsetti.module.a")
        XCTAssertEqual(receivedEventBox.event?.payload["purpose"], "sync")
    }

    func testSendModuleMessageRejectsReservedNamespaceAndLogsError() {
        let logger = CommunicationRecordingLogger()
        let context = ForsettiContext(
            eventBus: InMemoryEventBus(),
            services: ForsettiServiceContainer(),
            logger: logger,
            router: NoopOverlayRouter()
        )

        XCTAssertThrowsError(
            try context.sendModuleMessage(
                from: "com.forsetti.module.a",
                to: "com.forsetti.module.b",
                type: "forsetti.internal.override",
                payload: [:]
            )
        ) { error in
            guard case ForsettiContextError.moduleCommunicationDenied = error else {
                return XCTFail("Expected moduleCommunicationDenied, received \(error).")
            }
        }

        XCTAssertTrue(logger.entries.contains {
            $0.level == .error &&
                $0.message.contains("Blocked module-to-module communication")
        })
    }
}

private final class CommunicationRecordingLogger: ForsettiLogger, @unchecked Sendable {
    struct Entry: Equatable {
        let level: LogLevel
        let message: String
    }

    private let lock = NSLock()
    private var storedEntries: [Entry] = []

    var entries: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return storedEntries
    }

    func log(_ level: LogLevel, message: String) {
        lock.lock()
        storedEntries.append(.init(level: level, message: message))
        lock.unlock()
    }
}

private final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedEvent: ForsettiEvent?

    var event: ForsettiEvent? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedEvent
        }
        set {
            lock.lock()
            storedEvent = newValue
            lock.unlock()
        }
    }
}
