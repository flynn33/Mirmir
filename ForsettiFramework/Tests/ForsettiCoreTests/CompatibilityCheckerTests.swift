import XCTest
@testable import ForsettiCore

final class CompatibilityCheckerTests: XCTestCase {
    func testRejectsUnsupportedSchemaVersion() {
        let checker = CompatibilityChecker(
            runtimePlatform: .macOS,
            forsettiVersion: ForsettiVersion.current,
            capabilityPolicy: AllowAllCapabilityPolicy()
        )

        let report = checker.evaluate(
            manifest: makeManifest(
                schemaVersion: "2.0",
                moduleType: .service,
                capabilities: []
            )
        )

        XCTAssertFalse(report.isCompatible)
        XCTAssertTrue(report.issues.contains {
            $0.code == .invalidSchemaVersion && $0.severity == .error
        })
    }

    func testRejectsUnsupportedPlatform() {
        let checker = CompatibilityChecker(
            runtimePlatform: .macOS,
            forsettiVersion: ForsettiVersion.current,
            capabilityPolicy: AllowAllCapabilityPolicy()
        )

        let report = checker.evaluate(
            manifest: makeManifest(
                moduleType: .service,
                supportedPlatforms: [.iOS],
                capabilities: []
            )
        )

        XCTAssertFalse(report.isCompatible)
        XCTAssertTrue(report.issues.contains {
            $0.code == .unsupportedPlatform && $0.severity == .error
        })
    }

    func testRejectsVersionRangeMismatch() {
        let checker = CompatibilityChecker(
            runtimePlatform: .iOS,
            forsettiVersion: SemVer(major: 0, minor: 1, patch: 0),
            capabilityPolicy: AllowAllCapabilityPolicy()
        )

        let tooNew = checker.evaluate(
            manifest: makeManifest(
                moduleType: .service,
                minVersion: SemVer(major: 0, minor: 2, patch: 0),
                maxVersion: nil,
                capabilities: []
            )
        )

        XCTAssertFalse(tooNew.isCompatible)
        XCTAssertTrue(tooNew.issues.contains { $0.code == .unsupportedForsettiVersion })

        let tooOld = checker.evaluate(
            manifest: makeManifest(
                moduleType: .service,
                minVersion: SemVer(major: 0, minor: 1, patch: 0),
                maxVersion: SemVer(major: 0, minor: 0, patch: 9),
                capabilities: []
            )
        )

        XCTAssertFalse(tooOld.isCompatible)
        XCTAssertTrue(tooOld.issues.contains { $0.code == .unsupportedForsettiVersion })
    }

    func testRejectsDeniedCapability() {
        let checker = CompatibilityChecker(
            runtimePlatform: .macOS,
            forsettiVersion: ForsettiVersion.current,
            capabilityPolicy: FixedCapabilityPolicy(allowedCapabilities: [.storage])
        )

        let report = checker.evaluate(
            manifest: makeManifest(
                moduleType: .service,
                capabilities: [.storage, .networking]
            )
        )

        XCTAssertFalse(report.isCompatible)
        XCTAssertTrue(report.issues.contains {
            $0.code == .capabilityDenied && $0.severity == .error
        })
    }

    func testRejectsReservedFrameworkShellCapability() {
        let checker = CompatibilityChecker(
            runtimePlatform: .macOS,
            forsettiVersion: ForsettiVersion.current,
            capabilityPolicy: AllowAllCapabilityPolicy()
        )

        let report = checker.evaluate(
            manifest: makeManifest(
                moduleType: .ui,
                capabilities: [.uiThemeMask]
            )
        )

        XCTAssertFalse(report.isCompatible)
        XCTAssertTrue(report.issues.contains {
            $0.code == .capabilityDenied && $0.severity == .error
        })
    }

    func testAllowsUIModuleCompatibilityCheckWithoutSingleSelectionConstraint() {
        let checker = CompatibilityChecker(
            runtimePlatform: .macOS,
            forsettiVersion: ForsettiVersion.current,
            capabilityPolicy: AllowAllCapabilityPolicy()
        )

        let report = checker.evaluate(
            manifest: makeManifest(
                moduleID: "com.forsetti.module.ui.secondary",
                moduleType: .ui,
                capabilities: [.toolbarItems]
            )
        )

        XCTAssertTrue(report.isCompatible)
        XCTAssertFalse(report.issues.contains { $0.severity == .warning })
    }

    private func makeManifest(
        schemaVersion: String = ModuleManifest.supportedSchemaVersion,
        moduleID: String = "com.forsetti.module.test",
        moduleType: ModuleType,
        supportedPlatforms: [Platform] = [.iOS, .macOS],
        minVersion: SemVer = ForsettiVersion.current,
        maxVersion: SemVer? = nil,
        capabilities: [Capability]
    ) -> ModuleManifest {
        ModuleManifest(
            schemaVersion: schemaVersion,
            moduleID: moduleID,
            displayName: "Test Module",
            moduleVersion: SemVer(major: 1, minor: 0, patch: 0),
            moduleType: moduleType,
            supportedPlatforms: supportedPlatforms,
            minForsettiVersion: minVersion,
            maxForsettiVersion: maxVersion,
            capabilitiesRequested: capabilities,
            iapProductID: nil,
            entryPoint: "TestModule"
        )
    }
}
