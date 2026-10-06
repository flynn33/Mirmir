import Foundation

typealias MirmirProcessingActivityFactory = @Sendable (
    _ reason: String
) -> MirmirProcessingActivity

/// Retains processing protection across suspension until its owner finishes.
final class MirmirProcessingActivity: @unchecked Sendable {
    static let begin: MirmirProcessingActivityFactory = {
        MirmirProcessingActivity(reason: $0)
    }

    private let lock = NSLock()
    private let endActivity: @Sendable (NSObjectProtocol) -> Void
    private var token: NSObjectProtocol?

    init(
        reason: String,
        beginActivity: @Sendable (
            ProcessInfo.ActivityOptions,
            String
        ) -> NSObjectProtocol = {
            ProcessInfo.processInfo.beginActivity(options: $0, reason: $1)
        },
        endActivity: @escaping @Sendable (NSObjectProtocol) -> Void = {
            ProcessInfo.processInfo.endActivity($0)
        }
    ) {
        self.endActivity = endActivity
        // User-initiated work prevents App Nap and idle system sleep while
        // allowing the display to sleep.
        token = beginActivity(.userInitiated, reason)
    }

    deinit {
        end()
    }

    func end() {
        let activity = lock.withLock {
            let activity = token
            token = nil
            return activity
        }
        if let activity {
            endActivity(activity)
        }
    }
}
