import CoreVideo
import Darwin
import Dispatch
import Foundation
import XCTest
@testable import Mirmir

// R01 keeps the live entrypoint, its closed contracts, and isolation tests in
// one evidence-bound source file.
// swiftlint:disable file_length

final class AppleUpscaleCapabilityLiveProbeTests: XCTestCase {
    func testProduceAuthoritativeRawReport() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .standardizedFileURL
        guard let request = try R01LiveProbeRequest.resolve(
            environment: ProcessInfo.processInfo.environment,
            repositoryRoot: repositoryRoot
        ) else {
            throw XCTSkip("R01 live probes require the explicit live environment contract.")
        }
        XCTAssertFalse(request.allowsModelAcquisition)
        let report = try R01AuthoritativeLiveReportProducer().produceAndWrite(
            request: request,
            repositoryRoot: repositoryRoot
        )
        XCTAssertEqual(report.anchor, request.anchor)
        XCTAssertEqual(report.capabilities.map(\.id), R01CapabilityID.allCases)
        let values = try request.outputURL.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey
        ])
        XCTAssertEqual(values.isRegularFile, true)
        XCTAssertNotEqual(values.isSymbolicLink, true)
    }
}

// swiftlint:disable type_body_length
final class AppleUpscaleCapabilityLiveContractTests: XCTestCase {
    func testCompileCatalogUsesEighteenIndependentClosedUnits() throws {
        try R01CompileProbeCatalog.validate()
        XCTAssertEqual(R01CompileProbeCatalog.definitions.map(\.id), R01CapabilityID.allCases)
        XCTAssertEqual(Set(R01CompileProbeCatalog.definitions.map(\.snippet)).count, 18)
        let byID = Dictionary(
            uniqueKeysWithValues: R01CompileProbeCatalog.definitions.map { ($0.id, $0.snippet) }
        )
        XCTAssertTrue(try XCTUnwrap(byID[.a13]).contains("MPSImageGuidedFilter"))
        XCTAssertTrue(try XCTUnwrap(byID[.a13]).contains("MPSImageLaplacian"))
        XCTAssertTrue(try XCTUnwrap(byID[.a13]).contains("MPSImageSobel"))
        XCTAssertTrue(try XCTUnwrap(byID[.a14]).contains("bicubicScaleTransform"))
        XCTAssertTrue(try XCTUnwrap(byID[.a16]).contains("kvImageHighQualityResampling"))
        XCTAssertTrue(try XCTUnwrap(byID[.a16]).contains(
            "vImageNewResamplingFilterForFunctionUsingBuffer"
        ))
        XCTAssertTrue(try XCTUnwrap(byID[.a18]).contains("AIModel.specialize"))
        XCTAssertTrue(try XCTUnwrap(byID[.a18]).contains("function.run"))
    }

    func testCompileRunnerDoesNotSuppressOtherUnitsAndClassifiesInfrastructure() throws {
        let typechecker = R01FakeTypechecker(
            results: Dictionary(uniqueKeysWithValues: [
                (R01CapabilityID.a05, .surfaceUnavailable),
                (R01CapabilityID.a10, .infrastructureFailure),
                (R01CapabilityID.a11, .timedOut)
            ])
        )
        let observations = try R01IsolatedCompileProbeRunner(typechecker: typechecker).run()

        XCTAssertEqual(typechecker.invocationCount, 18)
        XCTAssertEqual(observations.map(\.id), R01CapabilityID.allCases)
        XCTAssertEqual(observations[4].state, .unavailable)
        XCTAssertEqual(observations[4].reason, .apiAbsent)
        XCTAssertNil(observations[4].probeFailureClass)
        XCTAssertEqual(observations[9].state, .conditional)
        XCTAssertEqual(observations[9].reason, .runtimeProbeFailed)
        XCTAssertEqual(observations[9].probeFailureClass, .setupFailure)
        XCTAssertEqual(observations[10].state, .conditional)
        XCTAssertEqual(observations[10].reason, .runtimeProbeFailed)
        XCTAssertEqual(observations[10].probeFailureClass, .timeout)
        XCTAssertEqual(observations[10].sanitizedDiagnostic, "isolated_swiftc_timeout")
        XCTAssertEqual(observations.filter { $0.state == .available }.count, 15)
    }

    func testFrozenSupportInputContractsAreCapabilitySpecific() {
        let a04 = supportContract(.a04)
        XCTAssertEqual(a04.fixtureIDs, ["support-frame", "support-history"])
        XCTAssertEqual(a04.formats, ["420v"])
        XCTAssertEqual(a04.guidanceInputs, [])
        XCTAssertEqual(a04.historyInputs, ["support-history"])

        let a13 = supportContract(.a13)
        XCTAssertEqual(
            a13.fixtureIDs,
            ["support-frame", "support-guidance", "support-history"]
        )
        XCTAssertEqual(a13.guidanceInputs, ["support-guidance"])
        XCTAssertEqual(a13.historyInputs, ["support-history"])

        let a15 = supportContract(.a15)
        XCTAssertEqual(a15.fixtureIDs, ["support-frame", "support-guidance"])
        XCTAssertEqual(a15.historyInputs, [])
        XCTAssertEqual(supportContract(.a17), a13)
    }

    func testDeterministicFixtureGeneratorMatchesFrozenCatalogHashes() throws {
        let data = try Data(contentsOf: repositoryRoot().appendingPathComponent(
            "docs/roadmaps/evidence/r01/records/fixtures/fixture-catalog.json"
        ))
        let catalog = try JSONDecoder().decode(R01FixtureCatalog.self, from: data).validated()
        for fixture in catalog.fixtures where fixture.id != "analysis-probe-model" {
            let generated = try R01DeterministicFixtureGenerator.materialize(fixture)
            XCTAssertEqual(generated.count, fixture.byteCount, fixture.id)
            XCTAssertEqual(R01SHA256.hexDigest(generated), fixture.contentSHA256, fixture.id)
        }
    }

    func testNV12BuffersCarryFrozenLeftChromaSiting() throws {
        let buffer = try R01NV12PixelBufferFactory.make(
            dimensions: .init(width: 4, height: 4)
        )
        var mode = CVAttachmentMode.shouldNotPropagate
        let attachment = CVBufferCopyAttachment(
            buffer,
            kCVImageBufferChromaLocationTopFieldKey,
            &mode
        )

        XCTAssertEqual(attachment as? String, kCVImageBufferChromaLocation_Left as String)
        XCTAssertEqual(mode.rawValue, CVAttachmentMode.shouldPropagate.rawValue)
    }

    func testExecutorRunsThreeSessionsAndClosedWarmupMeasurementCounts() throws {
        let counters = R01ExecutionCounters()
        let memory = R01MonotonicMemorySampler()
        let record = try R01CapabilityExecutor(
            sessionTimeout: .seconds(5),
            memorySampler: memory.sample,
            pollingInterval: 0.000_1
        ).execute(
            definition: definition(.a06),
            compileObservation: availableObservation(.a06),
            descriptor: runnableDescriptor {
                counters.incrementFactories()
                return R01DeterministicRuntimeSession(counters: counters)
            },
            modelIdentity: "analysis-model-v1",
            modelSHA256: String(repeating: "b", count: 64)
        )

        XCTAssertEqual(record.runtimeDisposition, .runnable)
        XCTAssertEqual(record.primaryScalerObservations, R01PrimaryScalerObservation.frozen)
        XCTAssertEqual(record.measurements.sessions.count, 3)
        XCTAssertTrue(record.measurements.sessions.allSatisfy {
            $0.completedWarmupUnits == 5 && $0.completedMeasuredUnits == 30
        })
        XCTAssertEqual(counters.factoryCount, 3)
        XCTAssertEqual(counters.unitCount, 105)
        XCTAssertEqual(record.measurements.repeatability.observations.count, 3)
        guard let throughputMetric = record.measurements.metrics.values[.throughputUnitsPerSecond],
              case .double(let throughput)? = throughputMetric.value,
              let frameRateMetric = record.measurements.metrics.values[.frameRate],
              case .double(let frameRate)? = frameRateMetric.value else {
            return XCTFail("Missing primary scaler throughput metrics.")
        }
        XCTAssertNotEqual(frameRate, throughput)
        XCTAssertEqual(
            frameRate,
            throughput * Double(R01PrimaryScalerObservation.frozen.count),
            accuracy: 0.000_001
        )
        guard let memoryMetric = record.measurements.metrics.values[.peakResidentMemoryDeltaBytes],
              case .integer(let delta)? = memoryMetric.value else {
            return XCTFail("Missing sampled peak RSS delta.")
        }
        XCTAssertGreaterThan(delta, 0)
        guard let acquisition = record.measurements.metrics.values[.acquisitionSeconds],
              case .double(let seconds)? = acquisition.value else {
            return XCTFail("Missing explicit acquisition observation.")
        }
        XCTAssertEqual(seconds, 0)
    }

    func testExecutorDeadlineIncludesFactoryInitialization() throws {
        let instantSource = R01AdvancingInstantSource()
        let record = try R01CapabilityExecutor(
            sessionTimeout: .milliseconds(4),
            memorySampler: { 1_000 },
            pollingInterval: 0.000_1,
            now: instantSource.now
        ).execute(
            definition: definition(.a06),
            compileObservation: availableObservation(.a06),
            descriptor: runnableDescriptor {
                Thread.sleep(forTimeInterval: 0.01)
                return R01DeterministicRuntimeSession(counters: R01ExecutionCounters())
            },
            modelIdentity: "analysis-model-v1",
            modelSHA256: String(repeating: "b", count: 64)
        )

        XCTAssertEqual(record.runtimeDisposition, .rejected)
        XCTAssertEqual(record.reasonCode, .runtimeProbeFailed)
        XCTAssertEqual(record.failureClass, .timeout)
        XCTAssertEqual(record.measurements.sessions.first?.outcome, .timeout)
        XCTAssertEqual(record.measurements.sessions.first?.elapsedSeconds, 120)
    }

    func testOuterWorkerTimeoutKillsAndReapsChildBeforeReturning() throws {
        let runner = R01FailClosedChildProcessRunner(
            pollInterval: 0.001,
            terminationGrace: 0.001
        )
        let result = try runner.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap '' TERM; while :; do :; done"],
            environment: ProcessInfo.processInfo.environment,
            currentDirectoryURL: FileManager.default.temporaryDirectory,
            timeout: 0.05
        )

        XCTAssertTrue(result.timedOut)
        XCTAssertEqual(result.terminationStatus, SIGKILL)
        errno = 0
        XCTAssertEqual(Darwin.kill(result.processIdentifier, 0), -1)
        XCTAssertEqual(errno, ESRCH, "Timed-out worker must be killed and reaped before return.")
    }

    func testOuterWorkerDeadlineUsesInjectedMonotonicClock() throws {
        let instantSource = R01AdvancingInstantSource()
        let runner = R01FailClosedChildProcessRunner(
            pollInterval: 0.001,
            terminationGrace: 0,
            monotonicNow: instantSource.now
        )
        let result = try runner.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap '' TERM; while :; do :; done"],
            environment: ProcessInfo.processInfo.environment,
            currentDirectoryURL: FileManager.default.temporaryDirectory,
            timeout: 0.001
        )

        XCTAssertTrue(result.timedOut)
        errno = 0
        XCTAssertEqual(Darwin.kill(result.processIdentifier, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testOuterWorkerTimeoutKillsProcessGroupDescendantBeforeReturning() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mirmir-r01-process-group-test-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let descendantPIDURL = directory.appendingPathComponent("descendant.pid")
        let runner = R01FailClosedChildProcessRunner(
            pollInterval: 0.001,
            terminationGrace: 0.05
        )
        let result = try runner.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                "(trap '' TERM; while :; do :; done) & echo $! > \"$1\"; while :; do :; done",
                "r01-process-group",
                descendantPIDURL.path
            ],
            environment: R01ClosedSubprocessEnvironment.values,
            currentDirectoryURL: directory,
            timeout: 0.2
        )

        let descendantText = try String(contentsOf: descendantPIDURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let descendantPID = try XCTUnwrap(Int32(descendantText))
        XCTAssertTrue(result.timedOut)
        errno = 0
        XCTAssertEqual(Darwin.kill(result.processIdentifier, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        errno = 0
        XCTAssertEqual(Darwin.kill(descendantPID, 0), -1)
        XCTAssertEqual(errno, ESRCH, "Timed-out descendants must be gone before return.")
    }

    func testWorkerCommandRejectsMissingLiveAuthorization() {
        XCTAssertThrowsError(try R01CapabilityWorkerCommand().run(
            arguments: [
                "--repository-root", repositoryRoot().path,
                "--request", "/tmp/r01-worker-request.json",
                "--response", "/tmp/r01-worker-response.json"
            ],
            environment: [:]
        ))
    }

    func testWorkerRunnerRejectsExecutableDigestMismatch() {
        XCTAssertThrowsError(try R01CapabilityWorkerProcessRunner(
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            expectedExecutableSHA256: String(repeating: "0", count: 64),
            environment: [:]
        ))
    }

    func testWorkerEnvironmentDropsAmbientInjectionVariables() throws {
        var environment = closedWorkerEnvironment()
        environment["API_TOKEN"] = "private-value"
        environment["DYLD_INSERT_LIBRARIES"] = "/private/tmp/injected.dylib"
        environment["GIT_DIR"] = "/private/tmp/alternate-git-dir"
        environment["SWIFT_EXEC"] = "/private/tmp/alternate-swift"
        let closed = try R01CapabilityWorkerProcessRunner.closedEnvironment(
            from: environment
        )

        XCTAssertEqual(
            Set(closed.keys),
            R01CapabilityWorkerProcessRunner.allowedEnvironmentVariables
        )
        XCTAssertNil(closed["API_TOKEN"])
        XCTAssertNil(closed["DYLD_INSERT_LIBRARIES"])
        XCTAssertNil(closed["GIT_DIR"])
        XCTAssertNil(closed["SWIFT_EXEC"])
        XCTAssertEqual(closed["GIT_NO_REPLACE_OBJECTS"], "1")
        XCTAssertEqual(closed["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
    }

    func testSwiftTypecheckerUsesClosedEnvironmentAndBoundedLifecycle() throws {
        let child = R01RecordingChildProcessRunner(
            result: .init(processIdentifier: 1, terminationStatus: SIGKILL, timedOut: true)
        )
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mirmir-r01-typecheck-test-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = R01ProcessSwiftTypechecker(processRunner: child).typecheck(
            snippet: "import Foundation",
            temporaryDirectory: directory
        )

        XCTAssertEqual(result, .timedOut)
        XCTAssertEqual(child.environment, R01ClosedSubprocessEnvironment.values)
        XCTAssertEqual(child.timeout, R01ProcessSwiftTypechecker.timeoutSeconds)
        XCTAssertEqual(child.executableURL?.path, "/usr/bin/xcrun")
        XCTAssertNotNil(child.standardErrorURL)
        XCTAssertTrue(child.arguments?.contains("-typecheck") == true)
    }

    func testContextCommandRunnerUsesClosedEnvironmentAndBoundedLifecycle() throws {
        let child = R01RecordingChildProcessRunner(
            result: .init(processIdentifier: 1, terminationStatus: 0, timedOut: false)
        )
        let result = try R01ProcessCommandRunner(processRunner: child).run(
            executable: "/usr/bin/sw_vers",
            arguments: ["-productVersion"],
            currentDirectory: repositoryRoot()
        )

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.standardOutput, Data())
        XCTAssertEqual(child.environment, R01ClosedSubprocessEnvironment.values)
        XCTAssertEqual(child.timeout, R01ProcessCommandRunner.timeoutSeconds)
        XCTAssertNotNil(child.standardOutputURL)
    }

    func testWorkerRejectsCompileObservationMismatch() throws {
        let capability = try definition(.a06)
        let staleObservation = R01CompileProbeObservation(
            id: .a06,
            state: .unavailable,
            reason: .apiAbsent,
            probeFailureClass: nil,
            sanitizedDiagnostic: "isolated_swiftc_nonzero_exit"
        )
        let record = try R01CapabilityExecutor().execute(
            definition: capability,
            compileObservation: staleObservation,
            descriptor: runnableDescriptor {
                R01DeterministicRuntimeSession(counters: R01ExecutionCounters())
            },
            modelIdentity: "analysis-model-v1",
            modelSHA256: String(repeating: "b", count: 64)
        )

        XCTAssertThrowsError(try R01CapabilityWorkerProcessRunner.validateCompileBinding(
            record: record,
            observation: availableObservation(.a06),
            definition: capability
        ))
    }

    func testWorkerClosedFileReaderRejectsFIFOWithoutBlocking() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mirmir-r01-fifo-test-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fifoURL = directory.appendingPathComponent("response.json")
        XCTAssertEqual(Darwin.mkfifo(fifoURL.path, 0o600), 0)
        let started = ContinuousClock().now

        XCTAssertThrowsError(try R01CapabilityWorkerProcessRunner.readClosedFile(
            at: fifoURL,
            maximumBytes: 1_024,
            failure: .workerResponseNotClosed("A01")
        ))
        XCTAssertLessThan(started.duration(to: ContinuousClock().now), .seconds(1))
    }

    func testProjectDefinesDedicatedCapabilityWorkerTool() throws {
        let source = try String(
            contentsOf: repositoryRoot().appendingPathComponent("project.yml"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("  R01CapabilityWorker:"))
        XCTAssertTrue(source.contains("    type: tool"))
        XCTAssertTrue(source.contains("      - path: R01CapabilityWorker"))
    }

    func testFactoryMemorySamplingFailureIsResourceFailure() throws {
        let sampler = R01FailingMemorySampler(failingOnCall: 2)
        let record = try R01CapabilityExecutor(
            sessionTimeout: .seconds(1),
            memorySampler: sampler.sample,
            pollingInterval: 0.000_1
        ).execute(
            definition: definition(.a06),
            compileObservation: availableObservation(.a06),
            descriptor: runnableDescriptor {
                R01DeterministicRuntimeSession(counters: R01ExecutionCounters())
            },
            modelIdentity: "analysis-model-v1",
            modelSHA256: String(repeating: "b", count: 64)
        )

        XCTAssertEqual(record.reasonCode, .resourceLimit)
        XCTAssertEqual(record.failureClass, .resourceFailure)
        XCTAssertEqual(record.measurements.sessions.first?.outcome, .resourceFailure)
    }

    func testUnitMemorySamplingFailureIsResourceFailure() throws {
        let harness = R01UnitSamplingFailureHarness()
        let record = try R01CapabilityExecutor(
            sessionTimeout: .seconds(1),
            memorySampler: harness.sample,
            pollingInterval: 0.000_1
        ).execute(
            definition: definition(.a06),
            compileObservation: availableObservation(.a06),
            descriptor: runnableDescriptor {
                R01UnitSamplingFailureSession(harness: harness)
            },
            modelIdentity: "analysis-model-v1",
            modelSHA256: String(repeating: "b", count: 64)
        )

        XCTAssertEqual(record.reasonCode, .resourceLimit)
        XCTAssertEqual(record.failureClass, .resourceFailure)
        XCTAssertEqual(record.measurements.sessions.first?.outcome, .resourceFailure)
    }

    func testPrivacyValidatorRejectsClosedPrivatePatterns() throws {
        let prohibited: [Any] = [
            ["hostname": "machine"],
            ["value": "file:///private/location"],
            ["value": "/Users/person/output"],
            ["value": "person@example.com"],
            ["value": "serial number: hidden"]
        ]
        for value in prohibited {
            XCTAssertThrowsError(try R01PrivacyValidator.validate(value))
        }
        XCTAssertNoThrow(try R01PrivacyValidator.validate([
            "host_id": "host-pro-max-01",
            "model_identifier": "Mac16,7"
        ]))
    }

    func testPreregisteredHostProfileRequiresSDKBuild() {
        let json = #"""
        {"host_id":"host","model_identifier":"Mac15,12","hardware_class":"macbook_air","chip":"Apple M3",
        "memory_bytes":1,"os_version":"26.0","os_build":"25A1","xcode_version":"26.0","xcode_build":"17A1",
        "sdk_version":"26.0"}
        """#
        XCTAssertThrowsError(
            try JSONDecoder().decode(R01FrozenHostProfile.self, from: Data(json.utf8))
        )
    }

    func testRunnerClosesFixtureAndPublishedSourcePreflight() throws {
        let source = try String(
            contentsOf: repositoryRoot().appendingPathComponent(
                "Scripts/run-r01-capability-probe.sh"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("--check-fixtures"))
        XCTAssertTrue(source.contains("diff-index --quiet HEAD --"))
        XCTAssertTrue(source.contains("for-each-ref"))
        XCTAssertTrue(source.contains("refs/remotes/origin"))
        XCTAssertTrue(source.contains("ls-files --error-unmatch"))
        XCTAssertTrue(source.contains("MIRMIR_R01_SOURCE_COMMIT"))
        XCTAssertTrue(source.contains("MIRMIR_R01_SOURCE_TREE"))
        XCTAssertTrue(source.contains("MIRMIR_R01_WORKER_EXECUTABLE"))
        XCTAssertTrue(source.contains("MIRMIR_R01_WORKER_SHA256"))
        XCTAssertTrue(source.contains("-scheme R01CapabilityWorker"))
        XCTAssertTrue(source.contains("/usr/bin/env -i"))
        XCTAssertTrue(source.contains("/usr/bin/python3 -I"))
        XCTAssertTrue(source.contains("/usr/bin/git"))
        XCTAssertTrue(source.contains("/usr/bin/xcodebuild"))
        XCTAssertTrue(source.contains(
            #"worker_executable="$derived_data/Build/Products/Debug/R01CapabilityWorker""#
        ))
        for path in R01LiveProbeContext.implementationSourcePaths {
            XCTAssertTrue(source.contains(path), path)
        }
    }

    private func supportContract(_ id: R01CapabilityID) -> R01InputContract {
        .frozen(
            capabilityID: id,
            for: .supportFilter,
            modelIdentity: "analysis-model-v1",
            modelSHA256: String(repeating: "b", count: 64)
        )
    }

    private func definition(_ id: R01CapabilityID) throws -> R01CapabilityDefinition {
        try XCTUnwrap(R01CapabilityInventory.definitions.first { $0.id == id })
    }

    private func availableObservation(_ id: R01CapabilityID) -> R01CompileProbeObservation {
        .init(
            id: id,
            state: .available,
            reason: nil,
            probeFailureClass: nil,
            sanitizedDiagnostic: "isolated_swiftc_exit_0"
        )
    }

    private func closedWorkerEnvironment() -> [String: String] {
        [
            R01LiveProbeRequest.liveFlag: "1",
            R01LiveProbeRequest.anchorVariable: R01Anchor.proMax.rawValue,
            R01LiveProbeRequest.outputVariable: "/private/tmp/r01-report.json",
            "MIRMIR_R01_SOURCE_COMMIT": String(repeating: "a", count: 40),
            "MIRMIR_R01_SOURCE_TREE": String(repeating: "b", count: 40),
            R01CapabilityWorkerProcessRunner.executableEnvironmentVariable: "/bin/echo",
            R01CapabilityWorkerProcessRunner.executableSHA256EnvironmentVariable:
                String(repeating: "c", count: 64)
        ]
    }

    private func runnableDescriptor(
        factory: @escaping () throws -> any R01CapabilityRuntimeSession
    ) -> R01RuntimeAdapterDescriptor {
        .init(
            publicAPIStatus: .public,
            hardwareEligibility: .eligible,
            platformRequirements: .init(
                minimumOSVersion: "15.4",
                minimumSDKVersion: "15.4",
                unavailableReason: nil
            ),
            supportQuery: .init(
                apiOrEquivalentName: "test-support-query",
                observed: .supported,
                reasonCode: nil
            ),
            stateHistory: .stateless,
            modelReadiness: .notRequired,
            offlineSuitability: .suitable,
            limitations: ["offline deterministic executor test"],
            unavailableDisposition: nil,
            unavailableReason: nil,
            sessionFactory: factory
        )
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
// swiftlint:enable type_body_length

private final class R01FakeTypechecker: R01SwiftTypechecking {
    private let results: [R01CapabilityID: R01TypecheckResult]
    private(set) var invocationCount = 0

    init(results: [R01CapabilityID: R01TypecheckResult]) {
        self.results = results
    }

    func typecheck(
        snippet _: String,
        temporaryDirectory _: URL
    ) -> R01TypecheckResult {
        let id = R01CapabilityID.allCases[invocationCount]
        invocationCount += 1
        return results[id] ?? .available
    }
}

private final class R01RecordingChildProcessRunner: R01ChildProcessRunning {
    private let result: R01ChildProcessResult
    private(set) var executableURL: URL?
    private(set) var arguments: [String]?
    private(set) var environment: [String: String]?
    private(set) var standardOutputURL: URL?
    private(set) var standardErrorURL: URL?
    private(set) var timeout: TimeInterval?

    init(result: R01ChildProcessResult) {
        self.result = result
    }

    func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectoryURL _: URL,
        standardOutputURL: URL?,
        standardErrorURL: URL?,
        timeout: TimeInterval
    ) throws -> R01ChildProcessResult {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.standardOutputURL = standardOutputURL
        self.standardErrorURL = standardErrorURL
        self.timeout = timeout
        return result
    }
}

private final class R01ExecutionCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var factories = 0
    private var units = 0

    var factoryCount: Int { locked { factories } }
    var unitCount: Int { locked { units } }

    func incrementFactories() { locked { factories += 1 } }
    func incrementUnits() { locked { units += 1 } }

    @discardableResult
    private func locked<Value>(_ operation: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}

private final class R01MonotonicMemorySampler: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 1_000

    func sample() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 10
        return value
    }
}

private final class R01AdvancingInstantSource: @unchecked Sendable {
    private let lock = NSLock()
    private let origin = ContinuousClock().now
    private var tick: Int64 = 0

    func now() -> ContinuousClock.Instant {
        lock.lock()
        defer {
            tick += 1
            lock.unlock()
        }
        return origin.advanced(by: .milliseconds(tick))
    }
}

private enum R01TestMemoryError: Error {
    case expected
}

private final class R01FailingMemorySampler: @unchecked Sendable {
    private let lock = NSLock()
    private let failingOnCall: Int
    private var callCount = 0

    init(failingOnCall: Int) {
        self.failingOnCall = failingOnCall
    }

    func sample() throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        callCount += 1
        guard callCount != failingOnCall else { throw R01TestMemoryError.expected }
        return 1_000
    }
}

private final class R01UnitSamplingFailureHarness: @unchecked Sendable {
    private let lock = NSLock()
    private let samplerObservedUnit = DispatchSemaphore(value: 0)
    private var unitStarted = false

    func sample() throws -> Int {
        lock.lock()
        let mustFail = unitStarted
        lock.unlock()
        guard !mustFail else {
            samplerObservedUnit.signal()
            throw R01TestMemoryError.expected
        }
        return 1_000
    }

    func beginUnit() {
        lock.lock()
        unitStarted = true
        lock.unlock()
    }

    func waitForSampler() -> Bool {
        samplerObservedUnit.wait(timeout: .now() + 1) == .success
    }
}

private final class R01UnitSamplingFailureSession: R01CapabilityRuntimeSession {
    private let harness: R01UnitSamplingFailureHarness

    init(harness: R01UnitSamplingFailureHarness) {
        self.harness = harness
    }

    func runUnit(deadline _: ContinuousClock.Instant) throws -> R01RuntimeUnitResult {
        harness.beginUnit()
        guard harness.waitForSampler() else { throw R01ExecutionFailure.setup }
        return .init(
            outputSHA256: String(repeating: "a", count: 64),
            classMetrics: [:],
            primaryScalerObservations: R01PrimaryScalerObservation.frozen
        )
    }
}

private final class R01DeterministicRuntimeSession: R01CapabilityRuntimeSession {
    private let counters: R01ExecutionCounters

    init(counters: R01ExecutionCounters) {
        self.counters = counters
    }

    func runUnit(deadline _: ContinuousClock.Instant) throws -> R01RuntimeUnitResult {
        counters.incrementUnits()
        return .init(
            outputSHA256: String(repeating: "a", count: 64),
            classMetrics: [:],
            primaryScalerObservations: R01PrimaryScalerObservation.frozen
        )
    }
}
