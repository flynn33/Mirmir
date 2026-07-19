import Foundation
@testable import Mirmir

@MainActor
final class MirmirModuleEventRecorder {
    private(set) var events: [String] = []

    func append(_ event: String) {
        events.append(event)
    }
}

struct MirmirInjectedModuleStartError: Error, LocalizedError {
    let moduleID: String

    var errorDescription: String? {
        "Injected startup failure for \(moduleID)"
    }
}

@MainActor
final class MirmirRecordingModule: MirmirModule {
    let descriptor: MirmirModuleDescriptor

    private let recorder: MirmirModuleEventRecorder
    private let failsOnStart: Bool
    private var didStart = false

    init(
        descriptor: MirmirModuleDescriptor,
        recorder: MirmirModuleEventRecorder,
        failsOnStart: Bool = false
    ) {
        self.descriptor = descriptor
        self.recorder = recorder
        self.failsOnStart = failsOnStart
    }

    func start(context: MirmirModuleContext) throws {
        guard !didStart else { return }
        precondition(context.moduleID == descriptor.moduleID)
        didStart = true
        recorder.append("start:\(descriptor.moduleID)")
        if failsOnStart {
            throw MirmirInjectedModuleStartError(moduleID: descriptor.moduleID)
        }
    }

    func stop(context: MirmirModuleContext) {
        guard didStart else { return }
        precondition(context.moduleID == descriptor.moduleID)
        didStart = false
        recorder.append("stop:\(descriptor.moduleID)")
    }
}
