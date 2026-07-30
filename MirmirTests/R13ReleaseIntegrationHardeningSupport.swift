import Foundation
import os.lock
@testable import Mirmir

struct R13IntegrationFixedFrameCounter: R13SourceFrameCountMeasuring {
    let frameCount: Int

    func exactVideoFrameCount(at _: URL) async throws -> Int {
        frameCount
    }
}

struct R13IntegrationEnvironmentCollector:
    R13ReleaseEnvironmentCollecting {
    let environment: R13ReleaseEnvironment

    func collect() throws -> R13ReleaseEnvironment {
        environment
    }
}

struct R13IntegrationBookmarkResolver:
    R13SecurityScopedBookmarkResolving {
    func makeBookmark(
        for url: URL,
        role: R13BookmarkRole
    ) throws -> Data {
        Data("\(role.rawValue)\n\(url.absoluteString)".utf8)
    }

    func resolveBookmark(
        _ data: Data,
        role: R13BookmarkRole
    ) throws -> R13ResolvedSecurityScopedBookmark {
        guard let value = String(data: data, encoding: .utf8) else {
            throw R13RestartJobError.bookmarkResolutionFailed(role: role)
        }
        let prefix = "\(role.rawValue)\n"
        guard value.hasPrefix(prefix),
              let url = URL(string: String(value.dropFirst(prefix.count))) else {
            throw R13RestartJobError.bookmarkResolutionFailed(role: role)
        }
        return R13ResolvedSecurityScopedBookmark(
            url: url,
            isStale: false,
            startAccessing: { true },
            stopAccessing: {}
        )
    }
}

final class R13IntegrationCapacityObservation: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: [String]())

    var labels: [String] {
        state.withLock { $0 }
    }

    func record(_ label: String) {
        state.withLock { $0.append(label) }
    }
}

struct R13IntegrationCapacityProbe: R13AvailableCapacityProbing {
    let label: String
    let availableBytes: UInt64
    let observation: R13IntegrationCapacityObservation

    func availableCapacityForImportantUsage(at _: URL) throws -> UInt64 {
        observation.record(label)
        return availableBytes
    }
}

struct R13IntegrationFaultInjector: R13FaultInjecting {
    let selectedPoint: R13FaultPoint?
    let injectedFault: R13InjectedFault

    func fault(at point: R13FaultPoint) async -> R13InjectedFault? {
        point == selectedPoint ? injectedFault : nil
    }
}

struct R13IntegrationHardeningHarness {
    static let ampleCapacityBytes: UInt64 = 1_099_511_627_776

    let runtime: R13ReleaseHardeningRuntime
    let governor: R13ResourceGovernor
    let diagnostics: R13ReleaseDiagnostics
    let capacityObservation: R13IntegrationCapacityObservation
    let environment: R13ReleaseEnvironment
    let documents: R13ReleaseHardeningDocuments

    static func make(
        jobsRootURL: URL,
        exactFrameCount: Int,
        faultPoint: R13FaultPoint? = nil,
        resourceDiskBytes: UInt64 = ampleCapacityBytes,
        resourceMemoryBytes: UInt64 = ampleCapacityBytes,
        thermalCondition: R13ThermalCondition = .nominal
    ) throws -> R13IntegrationHardeningHarness {
        let documents = try R13ReleaseHardeningDocuments.production()
        let diagnostics = R13ReleaseDiagnostics(
            policy: try R13ReleaseDiagnosticsPolicy(
                maximumRecords: 256,
                maximumTotalBytes: 65_536
            )
        )
        let governor = R13ResourceGovernor(
            policy: documents.resourcePolicy,
            probes: R13ResourceProbes(
                availableDiskBytes: { resourceDiskBytes },
                availableMemoryBytes: { resourceMemoryBytes },
                thermalCondition: { thermalCondition }
            )
        )
        let capacityObservation = R13IntegrationCapacityObservation()
        let environment = try makeEnvironment()
        let runtime = R13ReleaseHardeningRuntime(
            jobsRootURL: jobsRootURL,
            sourceMeasurer: R13LocalRestartSourceMeasurer(),
            frameCounter: R13IntegrationFixedFrameCounter(
                frameCount: exactFrameCount
            ),
            environmentCollector: R13IntegrationEnvironmentCollector(
                environment: environment
            ),
            documents: documents,
            bookmarkResolver: R13IntegrationBookmarkResolver(),
            storagePreflight: R13StoragePreflight(
                capacityProbe: R13IntegrationCapacityProbe(
                    label: "cache",
                    availableBytes: ampleCapacityBytes,
                    observation: capacityObservation
                )
            ),
            outputCapacityProbe: R13IntegrationCapacityProbe(
                label: "output",
                availableBytes: ampleCapacityBytes,
                observation: capacityObservation
            ),
            resourceGovernor: governor,
            faultInjector: R13IntegrationFaultInjector(
                selectedPoint: faultPoint,
                injectedFault: .diskFull
            ),
            diagnostics: diagnostics
        )
        return R13IntegrationHardeningHarness(
            runtime: runtime,
            governor: governor,
            diagnostics: diagnostics,
            capacityObservation: capacityObservation,
            environment: environment,
            documents: documents
        )
    }

    private static func makeEnvironment() throws -> R13ReleaseEnvironment {
        try R13ReleaseEnvironment(
            application: R13ReleaseApplicationIdentity(
                bundleIdentifier: "com.mirmir.integration-tests",
                semanticVersion: "1.0.0",
                buildVersion: "13",
                executableSHA256: String(repeating: "a", count: 64),
                executableByteCount: 4_096
            ),
            framework: R13ReleaseFrameworkIdentity(
                frameworkIdentifier:
                    R03A11ProductAdmission.frameworkIdentity,
                version: "integration-1",
                buildIdentity: "integration-build"
            ),
            runtime: R13ReleaseRuntimeIdentity(
                runtimeIdentifier: "macOS",
                version: "15.4",
                buildIdentity: "integration-runtime",
                architecture: "arm64"
            )
        )
    }
}

func expectedR13IntegrationCapacityLabels(
    for workspace: R13IntegrationWorkspace,
    liveRecheckCountsByAttempt: [Int]
) throws -> [String] {
    let sharesVolume = try R13FoundationVolumeTopologyProbe().sharesVolume(
        workspace.jobsRootURL,
        workspace.outputURL.deletingLastPathComponent()
    )
    let admissionLabels = sharesVolume ? ["cache"] : ["output", "cache"]
    return liveRecheckCountsByAttempt.flatMap { liveRecheckCount in
        admissionLabels
            + Array(repeating: "output", count: liveRecheckCount)
    }
}
