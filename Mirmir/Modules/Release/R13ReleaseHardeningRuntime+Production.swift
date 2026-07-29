import Foundation

extension R13ReleaseHardeningRuntime {
    static func production(
        diagnostics: MirmirDiagnosticStore? = nil
    ) throws -> R13ReleaseHardeningRuntime {
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let jobsRootURL = applicationSupport
            .appendingPathComponent("Mirmir", isDirectory: true)
            .appendingPathComponent("Jobs", isDirectory: true)
        return try production(
            cacheLocation: R13CacheLocationConfiguration(
                trustedRootURL: applicationSupport,
                jobsRootURL: jobsRootURL,
                access: nil
            ),
            diagnostics: diagnostics
        )
    }

    static func production(
        cacheLocation: R13CacheLocationConfiguration,
        diagnostics persistentStore: MirmirDiagnosticStore? = nil
    ) throws -> R13ReleaseHardeningRuntime {
        let restartFileSystem = try R13LocalRestartFileSystem(
            trustedRootURL: cacheLocation.trustedRootURL
        )
        try restartFileSystem.ensureDirectory(
            cacheLocation.jobsRootURL
        )
        let documents = try R13ReleaseHardeningDocuments.production()
        let diagnostics = R13ReleaseDiagnostics(
            policy: try R13ReleaseDiagnosticsPolicy(
                maximumRecords: 256,
                maximumTotalBytes: 65_536
            )
        )
        let governor = R13ResourceGovernor(
            policy: documents.resourcePolicy,
            probes: R13ProductionResourceProbe.make(
                storageURL: cacheLocation.jobsRootURL
            )
        )
        return R13ReleaseHardeningRuntime(
            jobsRootURL: cacheLocation.jobsRootURL,
            sourceMeasurer: R13LocalRestartSourceMeasurer(),
            frameCounter: R13AVFoundationSourceFrameCounter(),
            environmentCollector:
                R13ProductionReleaseEnvironmentCollector(),
            documents: documents,
            bookmarkResolver: R13FoundationBookmarkResolver(),
            storagePreflight: R13StoragePreflight(),
            outputCapacityProbe: R13FoundationAvailableCapacityProbe(),
            resourceGovernor: governor,
            faultInjector: R13FaultInjectorFactory.production(),
            diagnostics: diagnostics,
            cacheLocationAccess: cacheLocation.access,
            restartFileSystem: restartFileSystem,
            persistentDiagnostics: MirmirDiagnosticRecorder(
                store: persistentStore
            )
        )
    }
}
