import Foundation
import XCTest
@testable import Mirmir

final class R13FaultInjectionTests: XCTestCase {
    func testProductionFactoryIsAlwaysNoOpAtEveryFaultPoint() async {
        let injector = R13FaultInjectorFactory.production()

        for point in R13FaultPoint.allCases {
            for _ in 0..<3 {
                let fault = await injector.fault(at: point)
                XCTAssertNil(fault, point.rawValue)
            }
        }
    }

    func testTestOwnedInjectorConsumesItsClosedScheduleDeterministically() async {
        let injector = R13TestFaultInjector(
            schedule: [
                .beforeResourceAdmission: [.diskFull, .lowMemory],
                .beforeMetadataReopen: [.metadataReopenFailure]
            ]
        )

        let first = await injector.fault(at: .beforeResourceAdmission)
        let second = await injector.fault(at: .beforeResourceAdmission)
        let exhausted = await injector.fault(at: .beforeResourceAdmission)
        let reopen = await injector.fault(at: .beforeMetadataReopen)
        let unrelated = await injector.fault(at: .beforeBackendStart)

        XCTAssertEqual(first, .diskFull)
        XCTAssertEqual(second, .lowMemory)
        XCTAssertNil(exhausted)
        XCTAssertEqual(reopen, .metadataReopenFailure)
        XCTAssertNil(unrelated)
        let observations = await injector.observations()
        XCTAssertEqual(
            observations,
            [
                .beforeResourceAdmission,
                .beforeResourceAdmission,
                .beforeResourceAdmission,
                .beforeMetadataReopen,
                .beforeBackendStart
            ]
        )
    }

    func testProductionFaultSourceHasNoEnvironmentPreferencesOrUIControlPath() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Mirmir")
            .appendingPathComponent("Modules")
            .appendingPathComponent("Release")
            .appendingPathComponent("R13FaultInjection.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("static func production()"))
        for forbidden in [
            "ProcessInfo",
            "environment[",
            "getenv(",
            "CommandLine",
            "UserDefaults",
            "NSApp",
            "import AppKit",
            "import SwiftUI",
            "static func testing"
        ] {
            XCTAssertFalse(source.contains(forbidden), forbidden)
        }
    }
}

private actor R13TestFaultInjector: R13FaultInjecting {
    private var schedule: [R13FaultPoint: [R13InjectedFault]]
    private var observedPoints: [R13FaultPoint] = []

    init(schedule: [R13FaultPoint: [R13InjectedFault]]) {
        self.schedule = schedule
    }

    func fault(at point: R13FaultPoint) -> R13InjectedFault? {
        observedPoints.append(point)
        guard var faults = schedule[point], !faults.isEmpty else {
            return nil
        }
        let fault = faults.removeFirst()
        schedule[point] = faults
        return fault
    }

    func observations() -> [R13FaultPoint] {
        observedPoints
    }
}
