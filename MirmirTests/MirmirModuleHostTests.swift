import XCTest
@testable import Mirmir

@MainActor
final class MirmirModuleHostTests: XCTestCase {
    func test_hostStartsInRequiredOrderAndStopsInReverseOrderIdempotently() throws {
        let recorder = MirmirModuleEventRecorder()
        let registry = try makeRegistry(recorder: recorder)
        let host = try MirmirModuleHost(registry: registry, loggingSubsystem: "com.mirmir.tests")

        try host.start()
        try host.start()

        let startEvents = MirmirModuleCatalog.activationOrder.map { "start:\($0.moduleID)" }
        XCTAssertEqual(recorder.events, startEvents)
        XCTAssertEqual(host.state, .active)
        XCTAssertEqual(host.records.map(\.lifecycleState), Array(repeating: .active, count: 5))

        host.stop()
        host.stop()

        let stopEvents = MirmirModuleCatalog.activationOrder.reversed().map { "stop:\($0.moduleID)" }
        XCTAssertEqual(recorder.events, startEvents + stopEvents)
        XCTAssertEqual(host.state, .stopped)
        XCTAssertEqual(host.records.map(\.lifecycleState), Array(repeating: .stopped, count: 5))
    }

    func test_hostRollsBackAfterEveryPossibleStartupFailure() throws {
        for failingIndex in MirmirModuleCatalog.activationOrder.indices {
            let recorder = MirmirModuleEventRecorder()
            let registry = try makeRegistry(recorder: recorder, failingIndex: failingIndex)
            let host = try MirmirModuleHost(
                registry: registry,
                loggingSubsystem: "com.mirmir.tests"
            )
            let attempted = Array(MirmirModuleCatalog.activationOrder[...failingIndex])

            XCTAssertThrowsError(try host.start()) { error in
                guard let hostError = error as? MirmirModuleHostError,
                      case .moduleStartFailed(let moduleID, _) = hostError else {
                    return XCTFail("Expected module startup failure, got \(error)")
                }
                XCTAssertEqual(moduleID, attempted.last?.moduleID)
            }

            let starts = attempted.map { "start:\($0.moduleID)" }
            let stops = attempted.reversed().map { "stop:\($0.moduleID)" }
            XCTAssertEqual(recorder.events, starts + stops, "failure index \(failingIndex)")
            guard case .failed(let moduleID, _) = host.state else {
                return XCTFail("Host did not record failure at index \(failingIndex)")
            }
            XCTAssertEqual(moduleID, attempted.last?.moduleID)
        }
    }

    func test_hostRejectsMissingAndUnexpectedRegistrations() throws {
        let recorder = MirmirModuleEventRecorder()
        let missingRegistry = MirmirModuleFactoryRegistry()
        for descriptor in MirmirModuleCatalog.activationOrder.dropLast() {
            try missingRegistry.register(descriptor: descriptor) {
                MirmirRecordingModule(descriptor: descriptor, recorder: recorder)
            }
        }
        XCTAssertThrowsError(try MirmirModuleHost(registry: missingRegistry)) { error in
            XCTAssertEqual(
                error as? MirmirModuleHostError,
                .missingRegistrations([MirmirModuleCatalog.ui.moduleID])
            )
        }

        let extraRegistry = try makeRegistry(recorder: recorder)
        let extra = MirmirModuleDescriptor(
            moduleID: "com.mirmir.test.extra",
            displayName: "Extra",
            versionString: "1.0.0",
            entryPoint: "ExtraModule",
            kind: .service
        )
        try extraRegistry.register(descriptor: extra) {
            MirmirRecordingModule(descriptor: extra, recorder: recorder)
        }
        XCTAssertThrowsError(try MirmirModuleHost(registry: extraRegistry)) { error in
            XCTAssertEqual(
                error as? MirmirModuleHostError,
                .unexpectedRegistrations([extra.moduleID])
            )
        }
    }

    func test_hostRequiresExactlyOneFinalUIModule() throws {
        let uiFirst = [
            MirmirModuleCatalog.ui,
            MirmirModuleCatalog.metalRendering
        ]
        XCTAssertThrowsError(
            try MirmirModuleHost(
                registry: makeRegistry(descriptors: uiFirst),
                activationOrder: uiFirst
            )
        ) { error in
            XCTAssertEqual(
                error as? MirmirModuleHostError,
                .invalidActivationOrder("the UI module must be last")
            )
        }

        let secondUI = MirmirModuleDescriptor(
            moduleID: "com.mirmir.test.second-ui",
            displayName: "Second UI",
            versionString: "1.0.0",
            entryPoint: "SecondUIModule",
            kind: .ui
        )
        let multipleUI = [MirmirModuleCatalog.metalRendering, MirmirModuleCatalog.ui, secondUI]
        XCTAssertThrowsError(
            try MirmirModuleHost(
                registry: makeRegistry(descriptors: multipleUI),
                activationOrder: multipleUI
            )
        ) { error in
            XCTAssertEqual(
                error as? MirmirModuleHostError,
                .invalidActivationOrder("exactly one UI module is required")
            )
        }
    }

    func test_hostRejectsServiceReordering() throws {
        var reordered = MirmirModuleCatalog.activationOrder
        reordered.swapAt(0, 1)

        XCTAssertThrowsError(
            try MirmirModuleHost(
                registry: makeRegistry(descriptors: reordered),
                activationOrder: reordered
            )
        ) { error in
            XCTAssertEqual(
                error as? MirmirModuleHostError,
                .invalidActivationOrder("modules must match the fixed Mirmir activation order")
            )
        }
    }

    private func makeRegistry(
        recorder: MirmirModuleEventRecorder,
        failingIndex: Int? = nil
    ) throws -> MirmirModuleFactoryRegistry {
        let registry = MirmirModuleFactoryRegistry()
        for (index, descriptor) in MirmirModuleCatalog.activationOrder.enumerated() {
            try registry.register(descriptor: descriptor) {
                MirmirRecordingModule(
                    descriptor: descriptor,
                    recorder: recorder,
                    failsOnStart: index == failingIndex
                )
            }
        }
        return registry
    }

    private func makeRegistry(
        descriptors: [MirmirModuleDescriptor]
    ) throws -> MirmirModuleFactoryRegistry {
        let recorder = MirmirModuleEventRecorder()
        let registry = MirmirModuleFactoryRegistry()
        for descriptor in descriptors {
            try registry.register(descriptor: descriptor) {
                MirmirRecordingModule(descriptor: descriptor, recorder: recorder)
            }
        }
        return registry
    }
}
