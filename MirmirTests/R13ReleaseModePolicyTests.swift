import Foundation
import XCTest
@testable import Mirmir

final class R13ReleaseModePolicyTests: XCTestCase {
    func testPublicModeCatalogKeepsAutoVisible() {
        XCTAssertEqual(
            UpscaleMode.allCases,
            [.auto, .quality, .fast, .deterministic]
        )
        XCTAssertEqual(UpscaleMode.allCases.map(\.id), [
            "auto",
            "quality",
            "fast",
            "deterministic"
        ])
    }

    func testUpscaleJobDefaultsToDeterministicWithoutChangingExistingCallers() {
        let job = UpscaleJob(
            inputURL: URL(fileURLWithPath: "/tmp/r13-input.mp4"),
            outputURL: URL(fileURLWithPath: "/tmp/r13-output.mp4"),
            targetResolution: .p2160
        )

        XCTAssertEqual(job.mode, .deterministic)
        XCTAssertTrue(
            AtomicMediaOutput.isValidTemporaryIdentifier(job.identifier)
        )
    }

    func testEnabledModesAliasOneExactProductA11Identity() throws {
        for mode in [UpscaleMode.quality, .fast, .deterministic] {
            let binding = try R13ReleaseModePolicy.binding(for: mode)
            XCTAssertEqual(binding.requestedMode, mode)
            XCTAssertEqual(binding.effectiveMode, .deterministic)
            XCTAssertEqual(
                binding.capabilityID,
                R03A11ProductAdmission.capabilityID
            )
            XCTAssertEqual(
                binding.backendID,
                R03A11ProductAdmission.subjectID.rawValue
            )
            XCTAssertEqual(
                binding.backendRevision,
                R03DeterministicBackendCatalog.backendRevision
            )
            XCTAssertEqual(
                binding.policyIdentity,
                R03A11ProductAdmission.policyIdentity
            )
            XCTAssertEqual(
                binding.materialDecisionIdentity,
                R03A11ProductAdmission.materialDecisionIdentity
            )
        }
    }

    func testAutoHasTypedUnavailableContract() {
        let expectedReason = R13ReleaseModePolicy.autoUnavailableReason

        XCTAssertEqual(
            R13ReleaseModePolicy.availability(for: .auto),
            .unavailable(reason: expectedReason)
        )
        XCTAssertThrowsError(
            try R13ReleaseModePolicy.binding(for: .auto)
        ) { error in
            guard case .modeUnavailable(let mode, let reason)
                = error as? UpscalerEngineError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(mode, .auto)
            XCTAssertEqual(reason, expectedReason)
            XCTAssertEqual(String(describing: error), expectedReason)
        }
    }
}
