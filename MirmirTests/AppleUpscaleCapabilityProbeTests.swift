import Foundation
@testable import Mirmir
import XCTest

final class AppleUpscaleCapabilityProbeTests: XCTestCase {
    func testInventoryContainsA01ThroughA18ExactlyOnceAndInOrder() throws {
        try R01CapabilityInventory.validate()
        XCTAssertEqual(
            R01CapabilityInventory.definitions.map(\.id),
            R01CapabilityID.allCases
        )
        XCTAssertEqual(Set(R01CapabilityInventory.definitions.map(\.id)).count, 18)
    }

    func testInventoryUsesClosedProbeClassAssignments() {
        let actual = Dictionary(
            uniqueKeysWithValues: R01CapabilityInventory.definitions.map { ($0.id, $0.probeClass) }
        )
        let expected: [R01CapabilityID: R01ProbeClass] = [
            .a01: .primaryScaler,
            .a02: .primaryScaler,
            .a03: .cadenceTransform,
            .a04: .supportFilter,
            .a05: .temporalAnalyzer,
            .a06: .primaryScaler,
            .a07: .primaryScaler,
            .a08: .primaryScaler,
            .a09: .primaryScaler,
            .a10: .cadenceTransform,
            .a11: .primaryScaler,
            .a12: .primaryScaler,
            .a13: .supportFilter,
            .a14: .primaryScaler,
            .a15: .supportFilter,
            .a16: .primaryScaler,
            .a17: .supportFilter,
            .a18: .analysisRuntime
        ]

        XCTAssertEqual(actual, expected)
    }

    func testInventoryRejectsReorderingAndDuplicates() {
        var reordered = R01CapabilityInventory.definitions
        reordered.swapAt(0, 1)
        XCTAssertThrowsError(try R01CapabilityInventory.validate(reordered)) { error in
            XCTAssertEqual(error as? R01ProbeContractError, .capabilityInventoryNotClosed)
        }

        var duplicated = R01CapabilityInventory.definitions
        duplicated[1] = duplicated[0]
        XCTAssertThrowsError(try R01CapabilityInventory.validate(duplicated)) { error in
            XCTAssertEqual(error as? R01ProbeContractError, .capabilityInventoryNotClosed)
        }
    }

    func testDeterministicDoubleProducesClosedOrderedObservations() async throws {
        let coordinator = R01CapabilityProbeCoordinator(
            probeImplementation: DeterministicProbe()
        )
        let observations = try await coordinator.run(request: testRequest())

        XCTAssertEqual(observations.map(\.id), R01CapabilityID.allCases)
        XCTAssertTrue(observations.allSatisfy { $0.compileState == .available })
        XCTAssertTrue(observations.allSatisfy { $0.runtimeDisposition == .diagnosticOnly })
        XCTAssertTrue(observations.allSatisfy { $0.reasonCode == .inputContractUnsatisfied })
    }

    func testCoordinatorRejectsAnObservationForTheWrongCapability() async {
        let coordinator = R01CapabilityProbeCoordinator(
            probeImplementation: DeterministicProbe(overriddenID: .a18)
        )

        do {
            _ = try await coordinator.run(request: testRequest())
            XCTFail("Expected the coordinator to reject the mismatched observation.")
        } catch let error as R01ProbeContractError {
            XCTAssertEqual(
                error,
                .observationIdentityMismatch(expected: .a01, actual: .a18)
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testObservationRequiresClosedDispositionReasonPair() throws {
        let definition = try XCTUnwrap(R01CapabilityInventory.definitions.first)
        let runnableWithFailureReason = R01CapabilityProbeObservation(
            id: definition.id,
            compileState: .available,
            runtimeDisposition: .runnable,
            reasonCode: .runtimeProbeFailed,
            limitations: []
        )
        let unavailableWithoutReason = R01CapabilityProbeObservation(
            id: definition.id,
            compileState: .unavailable,
            runtimeDisposition: .unavailable,
            reasonCode: .none,
            limitations: []
        )

        XCTAssertThrowsError(try runnableWithFailureReason.validate(for: definition))
        XCTAssertThrowsError(try unavailableWithoutReason.validate(for: definition))
    }

    func testDeterministicDoubleEncodingMatchesFrozenJSON() async throws {
        let coordinator = R01CapabilityProbeCoordinator(
            probeImplementation: DeterministicProbe()
        )
        let observations = try await coordinator.run(request: testRequest())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let first = try XCTUnwrap(observations.first)
        let encoded = try encoder.encode(first)

        XCTAssertEqual(
            try XCTUnwrap(String(data: encoded, encoding: .utf8)),
            #"{"compileState":"available","id":"A01","limitations":["deterministic double"],"reasonCode":"input_contract_unsatisfied","runtimeDisposition":"diagnostic_only"}"#
        )
    }

    func testOrdinaryEnvironmentDoesNotAuthorizeLiveProbes() throws {
        let request = try R01LiveProbeRequest.resolve(
            environment: [:],
            repositoryRoot: URL(fileURLWithPath: "/tmp/mirmir-r01-root")
        )

        XCTAssertNil(request)
    }

    func testLiveRequestRequiresExactBooleanFlagValues() {
        XCTAssertThrowsError(try resolve(environment: [R01LiveProbeRequest.liveFlag: "true"]))
        XCTAssertThrowsError(try resolve(environment: [R01LiveProbeRequest.acquisitionFlag: "0"]))
    }

    func testAcquisitionAnchorOrOutputWithoutLiveFlagIsRejected() {
        let partialEnvironments: [[String: String]] = [
            [R01LiveProbeRequest.acquisitionFlag: "1"],
            [R01LiveProbeRequest.anchorVariable: R01Anchor.proMax.rawValue],
            [R01LiveProbeRequest.outputVariable: R01Anchor.proMax.canonicalOutputPath]
        ]

        for environment in partialEnvironments {
            XCTAssertThrowsError(try resolve(environment: environment)) { error in
                XCTAssertEqual(
                    error as? R01ProbeContractError,
                    .liveConfigurationWithoutAuthorization
                )
            }
        }
    }

    func testEachAnchorResolvesOnlyItsCanonicalOutput() throws {
        for anchor in R01Anchor.allCases {
            let request = try XCTUnwrap(resolve(environment: liveEnvironment(for: anchor)))
            XCTAssertEqual(request.anchor, anchor)
            XCTAssertEqual(
                request.outputURL.path,
                "/tmp/mirmir-r01-root/\(anchor.canonicalOutputPath)"
            )
            XCTAssertFalse(request.allowsModelAcquisition)
        }
    }

    func testAcquisitionRequiresIndependentExplicitAuthorization() throws {
        var environment = liveEnvironment(for: .proMax)
        environment[R01LiveProbeRequest.acquisitionFlag] = "1"

        let request = try XCTUnwrap(resolve(environment: environment))
        XCTAssertTrue(request.allowsModelAcquisition)
    }

    func testOutputPathTraversalIsRejected() {
        var environment = liveEnvironment(for: .proMax)
        environment[R01LiveProbeRequest.outputVariable] =
            "project-notes/evidence/r01/hosts/../../outside.json"

        XCTAssertThrowsError(try resolve(environment: environment))
    }

    func testSymbolicLinkOutputParentIsRejected() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("mirmir-r01-symlink-parent-\(UUID().uuidString)")
        let outside = fileManager.temporaryDirectory
            .appendingPathComponent("mirmir-r01-symlink-target-\(UUID().uuidString)")
        try fileManager.createDirectory(
            at: root.appendingPathComponent("project-notes/evidence/r01"),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(
            at: root.appendingPathComponent("project-notes/evidence/r01/hosts"),
            withDestinationURL: outside
        )
        defer {
            try? fileManager.removeItem(at: root)
            try? fileManager.removeItem(at: outside)
        }

        XCTAssertThrowsError(
            try R01LiveProbeRequest.resolve(
                environment: liveEnvironment(for: .proMax),
                repositoryRoot: root
            )
        ) { error in
            guard case .symbolicLinkInOutputPath = error as? R01ProbeContractError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testSymbolicLinkOutputFileIsRejected() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("mirmir-r01-symlink-output-\(UUID().uuidString)")
        let hosts = root.appendingPathComponent("project-notes/evidence/r01/hosts")
        let outside = fileManager.temporaryDirectory
            .appendingPathComponent("mirmir-r01-symlink-file-\(UUID().uuidString)")
        try fileManager.createDirectory(at: hosts, withIntermediateDirectories: true)
        XCTAssertTrue(fileManager.createFile(atPath: outside.path, contents: Data()))
        try fileManager.createSymbolicLink(
            at: hosts.appendingPathComponent("anchor-pro-max.json"),
            withDestinationURL: outside
        )
        defer {
            try? fileManager.removeItem(at: root)
            try? fileManager.removeItem(at: outside)
        }

        XCTAssertThrowsError(
            try R01LiveProbeRequest.resolve(
                environment: liveEnvironment(for: .proMax),
                repositoryRoot: root
            )
        )
    }

    func testHostRecordRejectsStableIdentifiersAndPersonalOrPathKeys() {
        let forbiddenKeys = [
            "serial_number",
            "hardware_uuid",
            "udid",
            "account",
            "account_name",
            "user",
            "user_name",
            "path",
            "home_path",
            "provisioning",
            "provisioning_profile"
        ]

        for key in forbiddenKeys {
            var object = validHostJSONObject()
            object[key] = "forbidden"
            XCTAssertThrowsError(try R01HostRecord.validateClosedJSONObject(object)) { error in
                guard case .hostRecordKeysNotClosed(_, let extra) =
                    error as? R01ProbeContractError else {
                    return XCTFail("Unexpected error: \(error)")
                }
                XCTAssertEqual(extra, [key])
            }
        }
    }

    func testRunnerPreflightsPreregistrationBeforeAuthoritativeProducer() throws {
        let source = try String(
            contentsOf: repositoryRootURL()
                .appendingPathComponent("Scripts/run-r01-capability-probe.sh"),
            encoding: .utf8
        )
        let preregistration = try XCTUnwrap(
            source.range(of: "run_python_tool \"$preregistration_tool\" --check-live-readiness")
        )
        let producerGate = try XCTUnwrap(
            source.range(of: "[[ -f \"$live_test_source\" && ! -L \"$live_test_source\" ]]")
        )
        let xcodebuild = try XCTUnwrap(source.range(of: "run_closed /usr/bin/xcodebuild \\"))

        XCTAssertLessThan(preregistration.lowerBound, producerGate.lowerBound)
        XCTAssertLessThan(producerGate.lowerBound, xcodebuild.lowerBound)
        XCTAssertTrue(source.contains("AppleUpscaleCapabilityLiveProbeTests"))
        XCTAssertFalse(
            source.contains("-only-testing:MirmirTests/AppleUpscaleCapabilityProbeTests")
        )
    }

    func testRunnerRejectsAcquisitionBeforePreregistrationOrXcodebuild() throws {
        let source = try String(
            contentsOf: repositoryRootURL()
                .appendingPathComponent("Scripts/run-r01-capability-probe.sh"),
            encoding: .utf8
        )
        let acquisitionFailure = try XCTUnwrap(
            source.range(
                of: "model acquisition is not implemented or authorized by a closed consent-receipt contract"
            )
        )
        let preregistration = try XCTUnwrap(
            source.range(of: "run_python_tool \"$preregistration_tool\" --check-live-readiness")
        )
        let xcodebuild = try XCTUnwrap(source.range(of: "run_closed /usr/bin/xcodebuild \\"))

        XCTAssertLessThan(acquisitionFailure.lowerBound, preregistration.lowerBound)
        XCTAssertLessThan(acquisitionFailure.lowerBound, xcodebuild.lowerBound)
    }

    func testSupportWitnessWhenExplicitlyEnabled() async throws {
        let request = try R01LiveProbeRequest.resolve(
            environment: ProcessInfo.processInfo.environment,
            repositoryRoot: repositoryRootURL()
        )
        guard let request else {
            throw XCTSkip("Live R01 probes require MIRMIR_R01_LIVE_PROBES=1.")
        }

        let coordinator = R01CapabilityProbeCoordinator(
            probeImplementation: R01CurrentHostSupportProbe()
        )
        let observations = try await coordinator.run(request: request)
        XCTAssertEqual(observations.map(\.id), R01CapabilityID.allCases)
        XCTAssertFalse(observations.contains { $0.runtimeDisposition == .runnable })
    }

    private func resolve(environment: [String: String]) throws -> R01LiveProbeRequest? {
        try R01LiveProbeRequest.resolve(
            environment: environment,
            repositoryRoot: URL(fileURLWithPath: "/tmp/mirmir-r01-root")
        )
    }

    private func liveEnvironment(for anchor: R01Anchor) -> [String: String] {
        [
            R01LiveProbeRequest.liveFlag: "1",
            R01LiveProbeRequest.anchorVariable: anchor.rawValue,
            R01LiveProbeRequest.outputVariable: anchor.canonicalOutputPath
        ]
    }

    private func testRequest() -> R01LiveProbeRequest {
        R01LiveProbeRequest(
            anchor: .proMax,
            outputURL: URL(fileURLWithPath: "/tmp/anchor-pro-max.json"),
            allowsModelAcquisition: false
        )
    }

    private func validHostJSONObject() -> [String: Any] {
        [
            "host_id": "host-pro-max-01",
            "model_identifier": "Mac16,7",
            "chip": "Apple M4 Pro",
            "memory_bytes": 51_539_607_552,
            "os_version": "26.5.2",
            "os_build": "25F84",
            "xcode_version": "26.2",
            "xcode_build": "17C52",
            "sdk_version": "26.2",
            "sdk_build": "25C57",
            "hardware_classes": ["apple_silicon", "pro_max_tier"]
        ]
    }

    private func repositoryRootURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private struct DeterministicProbe: R01CapabilityProbing {
    let overriddenID: R01CapabilityID?

    init(overriddenID: R01CapabilityID? = nil) {
        self.overriddenID = overriddenID
    }

    func probe(
        _ definition: R01CapabilityDefinition,
        request _: R01LiveProbeRequest
    ) async throws -> R01CapabilityProbeObservation {
        R01CapabilityProbeObservation(
            id: overriddenID ?? definition.id,
            compileState: .available,
            runtimeDisposition: .diagnosticOnly,
            reasonCode: .inputContractUnsatisfied,
            limitations: ["deterministic double"]
        )
    }
}
