import Foundation
import SwiftUI

public final class ForsettiViewInjectionRegistry {
    private let lock = NSLock()
    private var builders: [String: () -> AnyView] = [:]

    public init() {}

    public func register<Content: View>(viewID: String, @ViewBuilder builder: @escaping () -> Content) {
        lock.lock()
        builders[viewID] = { AnyView(builder()) }
        lock.unlock()
    }

    public func resolve(viewID: String) -> AnyView? {
        lock.lock()
        let builder = builders[viewID]
        lock.unlock()
        return builder?()
    }
}
