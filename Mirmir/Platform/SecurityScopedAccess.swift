import Foundation

final class SecurityScopedAccess: @unchecked Sendable {
    let url: URL
    let didStartAccessing: Bool

    private let lock = NSLock()
    private let stopAccessing: (URL) -> Void
    private var isStopped = false

    convenience init(url: URL) {
        self.init(
            url: url,
            startAccessing: { $0.startAccessingSecurityScopedResource() },
            stopAccessing: { $0.stopAccessingSecurityScopedResource() }
        )
    }

    init(
        url: URL,
        startAccessing: (URL) -> Bool,
        stopAccessing: @escaping (URL) -> Void
    ) {
        self.url = url
        self.stopAccessing = stopAccessing
        didStartAccessing = startAccessing(url)
    }

    func stop() {
        guard didStartAccessing else {
            return
        }

        lock.lock()
        let mustStop = !isStopped
        isStopped = true
        lock.unlock()

        if mustStop {
            stopAccessing(url)
        }
    }

    deinit {
        stop()
    }
}
