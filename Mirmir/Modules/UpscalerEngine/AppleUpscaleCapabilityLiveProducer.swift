import Foundation

struct R01AuthoritativeLiveReportProducer {
    private let contextRunner: any R01CommandRunning
    private let typechecker: any R01SwiftTypechecking
    private let workerRunner: (any R01CapabilityWorkerRunning)?
    private let now: () -> Date
    private let environment: [String: String]

    init(
        contextRunner: any R01CommandRunning = R01ProcessCommandRunner(),
        typechecker: any R01SwiftTypechecking = R01ProcessSwiftTypechecker(),
        workerRunner: (any R01CapabilityWorkerRunning)? = nil,
        now: @escaping () -> Date = Date.init,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.contextRunner = contextRunner
        self.typechecker = typechecker
        self.workerRunner = workerRunner
        self.now = now
        self.environment = environment
    }

    @discardableResult
    func produceAndWrite(
        request: R01LiveProbeRequest,
        repositoryRoot: URL
    ) throws -> R01RawHostReport {
        guard !request.allowsModelAcquisition else {
            throw R01LiveReportError.reportNotClosed
        }
        guard let expectedCommit = environment["MIRMIR_R01_SOURCE_COMMIT"],
              let expectedTree = environment["MIRMIR_R01_SOURCE_TREE"],
              R01Validation.isGitObjectID(expectedCommit),
              R01Validation.isGitObjectID(expectedTree) else {
            throw R01LiveReportError.sourceTreeDirty
        }
        let context = try R01LiveProbeContext.prepare(
            request: request,
            repositoryRoot: repositoryRoot,
            runner: contextRunner,
            expectedSource: .init(commit: expectedCommit, tree: expectedTree)
        )
        let observations = try R01IsolatedCompileProbeRunner(typechecker: typechecker).run()
        guard observations.map(\.id) == R01CapabilityID.allCases else {
            throw R01LiveReportError.reportNotClosed
        }
        guard let modelIdentity = context.modelRecord.modelIdentity,
              let modelSHA256 = context.modelRecord.contentSHA256 else {
            throw R01LiveReportError.fixtureCatalogNotClosed
        }
        let capabilityWorker = try workerRunner
            ?? R01CapabilityWorkerProcessRunner.resolve(environment: environment)
        var capabilities: [R01CapabilityRecord] = []
        capabilities.reserveCapacity(R01CapabilityID.allCases.count)
        for (definition, observation) in zip(
            R01CapabilityInventory.definitions,
            observations
        ) {
            capabilities.append(try capabilityWorker.execute(
                definition: definition,
                compileObservation: observation,
                context: context,
                modelIdentity: modelIdentity,
                modelSHA256: modelSHA256
            ))
        }
        try context.reverify(runner: contextRunner)
        let report = R01RawHostReport(
            schemaVersion: "1.0",
            roadmapVersion: "1.0.1",
            phaseID: "R01",
            sourceCommit: context.source.commit,
            sourceTree: context.source.tree,
            generatedAt: Self.timestamp(now()),
            anchor: request.anchor,
            host: context.host,
            implementationBindings: context.implementationBindings,
            preregistrationBinding: context.preregistrationBinding,
            fixtureBindings: context.fixtureBindings,
            capabilities: capabilities,
            limitations: [
                "R01 records capability, compatibility, performance, and repeatability only.",
                "R01 does not qualify product backends or evaluate perceptual quality.",
                "No model acquisition was attempted."
            ]
        )
        try report.validate(modelIdentity: modelIdentity, modelSHA256: modelSHA256)
        try R01RawReportWriter().write(
            report,
            modelIdentity: modelIdentity,
            modelSHA256: modelSHA256,
            to: request.outputURL
        )
        return report
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}
