import Foundation

enum R01ClosedSubprocessEnvironment {
    static let values = [
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_NO_REPLACE_OBJECTS": "1",
        "LANG": "C",
        "LC_ALL": "C",
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "TMPDIR": "/private/tmp"
    ]
}

struct R01CompileProbeDefinition: Equatable, Sendable {
    let id: R01CapabilityID
    let snippet: String
    let unavailableReason: R01ReasonCode
}

struct R01CompileProbeObservation: Codable, Equatable, Sendable {
    let id: R01CapabilityID
    let state: R01CompileState
    let reason: R01ReasonCode?
    let probeFailureClass: R01FailureClass?
    let sanitizedDiagnostic: String
}

enum R01TypecheckResult: Equatable, Sendable {
    case available
    case surfaceUnavailable
    case infrastructureFailure
    case timedOut
}

protocol R01SwiftTypechecking {
    func typecheck(
        snippet: String,
        temporaryDirectory: URL
    ) -> R01TypecheckResult
}

struct R01ProcessSwiftTypechecker: R01SwiftTypechecking {
    static let timeoutSeconds: TimeInterval = 30
    static let maximumDiagnosticBytes = 1_048_576

    private let processRunner: any R01ChildProcessRunning
    private let timeout: TimeInterval

    init(
        processRunner: any R01ChildProcessRunning = R01FailClosedChildProcessRunner(),
        timeout: TimeInterval = R01ProcessSwiftTypechecker.timeoutSeconds
    ) {
        self.processRunner = processRunner
        self.timeout = timeout
    }

    func typecheck(snippet: String, temporaryDirectory: URL) -> R01TypecheckResult {
        let unit = UUID().uuidString
        let unitDirectory = temporaryDirectory.appendingPathComponent(unit, isDirectory: true)
        let sourceURL = unitDirectory.appendingPathComponent("probe.swift")
        let diagnosticsURL = unitDirectory.appendingPathComponent("probe.stderr")
        defer { try? FileManager.default.removeItem(at: unitDirectory) }
        do {
            try FileManager.default.createDirectory(
                at: unitDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            try Data(snippet.utf8).write(to: sourceURL, options: .withoutOverwriting)
            guard FileManager.default.createFile(
                atPath: diagnosticsURL.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            ) else {
                return .infrastructureFailure
            }
        } catch {
            return .infrastructureFailure
        }
        let arguments = [
            "swiftc", "-typecheck", "-parse-as-library",
            "-module-cache-path", unitDirectory.appendingPathComponent("ModuleCache").path,
            "-Xcc", "-fmodules-cache-path=\(unitDirectory.appendingPathComponent("ClangCache").path)",
            sourceURL.path
        ]
        do {
            let result = try processRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
                arguments: arguments,
                environment: R01ClosedSubprocessEnvironment.values,
                currentDirectoryURL: unitDirectory,
                standardOutputURL: nil,
                standardErrorURL: diagnosticsURL,
                timeout: timeout
            )
            guard !result.timedOut else { return .timedOut }
            if result.terminationStatus == 0 { return .available }
            let handle = try FileHandle(forReadingFrom: diagnosticsURL)
            defer { try? handle.close() }
            let diagnosticData = try handle.read(
                upToCount: Self.maximumDiagnosticBytes + 1
            ) ?? Data()
            guard diagnosticData.count <= Self.maximumDiagnosticBytes else {
                return .infrastructureFailure
            }
            guard let text = String(data: diagnosticData, encoding: .utf8) else {
                return .infrastructureFailure
            }
            let normalized = text.lowercased()
            let missingSymbol = normalized.contains("cannot find")
                && normalized.contains("in scope")
            if normalized.contains("no such module") || normalized.contains("has no member")
                || normalized.contains("is unavailable")
                || normalized.contains("could not find module") || missingSymbol {
                return .surfaceUnavailable
            }
            return .infrastructureFailure
        } catch {
            return .infrastructureFailure
        }
    }
}

enum R01CompileProbeCatalog {
    static let definitions: [R01CompileProbeDefinition] = [
        .init(
            id: .a01,
            snippet: witness(module: "VideoToolbox", symbol: "VTSuperResolutionScalerConfiguration"),
            unavailableReason: .sdkTooOld
        ),
        .init(
            id: .a02,
            snippet: witness(
                module: "VideoToolbox",
                symbol: "VTLowLatencySuperResolutionScalerConfiguration"
            ),
            unavailableReason: .sdkTooOld
        ),
        .init(
            id: .a03,
            snippet: witness(
                module: "VideoToolbox",
                symbol: "VTLowLatencyFrameInterpolationConfiguration"
            ),
            unavailableReason: .sdkTooOld
        ),
        .init(
            id: .a04,
            snippet: witness(module: "VideoToolbox", symbol: "VTTemporalNoiseFilterConfiguration"),
            unavailableReason: .sdkTooOld
        ),
        .init(
            id: .a05,
            snippet: witness(module: "VideoToolbox", symbol: "VTOpticalFlowConfiguration"),
            unavailableReason: .apiAbsent
        ),
        .init(
            id: .a06,
            snippet: witness(module: "VideoToolbox", symbol: "VTPixelTransferSessionCreate"),
            unavailableReason: .apiAbsent
        ),
        .init(
            id: .a07,
            snippet: witness(module: "MetalFX", symbol: "MTLFXSpatialScalerDescriptor"),
            unavailableReason: .apiAbsent
        ),
        .init(
            id: .a08,
            snippet: witness(module: "MetalFX", symbol: "MTLFXTemporalScalerDescriptor"),
            unavailableReason: .apiAbsent
        ),
        .init(
            id: .a09,
            snippet: witness(module: "MetalFX", symbol: "MTLFXTemporalDenoisedScalerDescriptor"),
            unavailableReason: .sdkTooOld
        ),
        .init(
            id: .a10,
            snippet: witness(module: "MetalFX", symbol: "MTLFXFrameInterpolatorDescriptor"),
            unavailableReason: .sdkTooOld
        ),
        .init(
            id: .a11,
            snippet: witness(
                module: "MetalPerformanceShaders",
                symbol: "MPSImageLanczosScale"
            ),
            unavailableReason: .apiAbsent
        ),
        .init(
            id: .a12,
            snippet: witness(
                module: "MetalPerformanceShaders",
                symbol: "MPSImageBilinearScale"
            ),
            unavailableReason: .apiAbsent
        ),
        .init(
            id: .a13,
            snippet: witnesses(
                module: "MetalPerformanceShaders",
                symbols: ["MPSImageGuidedFilter", "MPSImageLaplacian", "MPSImageSobel"]
            ),
            unavailableReason: .apiAbsent
        ),
        .init(
            id: .a14,
            snippet: coreImageWitnesses(symbols: [
                "lanczosScaleTransform", "bicubicScaleTransform"
            ]),
            unavailableReason: .apiAbsent
        ),
        .init(
            id: .a15,
            snippet: coreImageWitness(symbol: "edgePreserveUpsample"),
            unavailableReason: .apiAbsent
        ),
        .init(
            id: .a16,
            snippet: witnesses(
                module: "Accelerate",
                symbols: [
                    "vImageNewResamplingFilter", "kvImageHighQualityResampling",
                    "vImageNewResamplingFilterForFunctionUsingBuffer"
                ]
            ),
            unavailableReason: .apiAbsent
        ),
        .init(
            id: .a17,
            snippet: witness(module: "Metal", symbol: "MTLComputePipelineDescriptor"),
            unavailableReason: .apiAbsent
        ),
        .init(
            id: .a18,
            snippet: coreAIWitness,
            unavailableReason: .apiAbsent
        )
    ]

    static func validate() throws {
        guard definitions.map(\.id) == R01CapabilityID.allCases,
              Set(definitions.map(\.id)).count == R01CapabilityID.allCases.count,
              definitions.allSatisfy({ !$0.snippet.isEmpty }) else {
            throw R01ProbeContractError.capabilityInventoryNotClosed
        }
    }

    private static func witness(module: String, symbol: String) -> String {
        "import \(module)\nfunc r01CompileWitness() { _ = \(symbol).self }\n"
    }

    private static func witnesses(module: String, symbols: [String]) -> String {
        let body = symbols.map { "_ = \($0).self" }.joined(separator: "; ")
        return "import \(module)\nfunc r01CompileWitness() { \(body) }\n"
    }

    private static func coreImageWitness(symbol: String) -> String {
        coreImageWitnesses(symbols: [symbol])
    }

    private static func coreImageWitnesses(symbols: [String]) -> String {
        let body = symbols.map { "_ = CIFilter.\($0)()" }.joined(separator: "; ")
        return "import CoreImage\nimport CoreImage.CIFilterBuiltins\n"
            + "func r01CompileWitness() { \(body) }\n"
    }

    private static let coreAIWitness = """
    import CoreAI
    import Foundation
    func r01CompileWitness(
        modelURL: URL,
        function: InferenceFunction,
        inputs: [String: InferenceValue]
    ) async throws {
        _ = try await AIModel(contentsOf: modelURL, options: .default)
        _ = try await AIModel.specialize(contentsOf: modelURL)
        _ = try await function.run(inputs: inputs)
    }
    """
}

struct R01IsolatedCompileProbeRunner {
    private let typechecker: any R01SwiftTypechecking

    init(typechecker: any R01SwiftTypechecking = R01ProcessSwiftTypechecker()) {
        self.typechecker = typechecker
    }

    func run() throws -> [R01CompileProbeObservation] {
        try R01CompileProbeCatalog.validate()
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirmir-r01-compile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        return R01CompileProbeCatalog.definitions.map { definition in
            let result = typechecker.typecheck(
                snippet: definition.snippet,
                temporaryDirectory: temporaryDirectory
            )
            if result == .available {
                return .init(
                    id: definition.id,
                    state: .available,
                    reason: nil,
                    probeFailureClass: nil,
                    sanitizedDiagnostic: "isolated_swiftc_exit_0"
                )
            }
            if result == .infrastructureFailure {
                return .init(
                    id: definition.id,
                    state: .conditional,
                    reason: .runtimeProbeFailed,
                    probeFailureClass: .setupFailure,
                    sanitizedDiagnostic: "isolated_swiftc_infrastructure_failure"
                )
            }
            if result == .timedOut {
                return .init(
                    id: definition.id,
                    state: .conditional,
                    reason: .runtimeProbeFailed,
                    probeFailureClass: .timeout,
                    sanitizedDiagnostic: "isolated_swiftc_timeout"
                )
            }
            return .init(
                id: definition.id,
                state: .unavailable,
                reason: definition.unavailableReason,
                probeFailureClass: nil,
                sanitizedDiagnostic: "isolated_swiftc_nonzero_exit"
            )
        }
    }
}
