import Darwin
import Foundation

// R01 keeps worker IPC, lifecycle, and executable validation in one bound source file.
// swiftlint:disable file_length

struct R01CapabilityWorkerInput: Codable, Equatable, Sendable {
    let capabilityID: R01CapabilityID
    let compileObservation: R01CompileProbeObservation
    let sourceCommit: String
    let sourceTree: String
}

struct R01ChildProcessResult: Equatable, Sendable {
    let processIdentifier: Int32
    let terminationStatus: Int32
    let timedOut: Bool
}

protocol R01ChildProcessRunning {
    func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectoryURL: URL,
        standardOutputURL: URL?,
        standardErrorURL: URL?,
        timeout: TimeInterval
    ) throws -> R01ChildProcessResult
}

extension R01ChildProcessRunning {
    func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectoryURL: URL,
        timeout: TimeInterval
    ) throws -> R01ChildProcessResult {
        try run(
            executableURL: executableURL,
            arguments: arguments,
            environment: environment,
            currentDirectoryURL: currentDirectoryURL,
            standardOutputURL: nil,
            standardErrorURL: nil,
            timeout: timeout
        )
    }
}

struct R01FailClosedChildProcessRunner: R01ChildProcessRunning {
    private let pollInterval: TimeInterval
    private let terminationGrace: TimeInterval
    private let monotonicNow: () -> ContinuousClock.Instant

    init(
        pollInterval: TimeInterval = 0.005,
        terminationGrace: TimeInterval = 0.25,
        monotonicNow: @escaping () -> ContinuousClock.Instant = { ContinuousClock().now }
    ) {
        self.pollInterval = max(0.000_1, pollInterval)
        self.terminationGrace = max(0, terminationGrace)
        self.monotonicNow = monotonicNow
    }

    func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectoryURL: URL,
        standardOutputURL: URL?,
        standardErrorURL: URL?,
        timeout: TimeInterval
    ) throws -> R01ChildProcessResult {
        guard let timeoutDuration = Self.duration(seconds: timeout),
              let graceDuration = Self.duration(seconds: terminationGrace, allowsZero: true) else {
            throw R01LiveReportError.workerProcessFailed("invalid-timeout")
        }
        let processIdentifier = try Self.spawn(
            executableURL: executableURL,
            arguments: arguments,
            environment: environment,
            currentDirectoryURL: currentDirectoryURL,
            standardOutputURL: standardOutputURL,
            standardErrorURL: standardErrorURL
        )
        let deadline = monotonicNow().advanced(by: timeoutDuration)
        if let status = try waitForExit(processIdentifier, until: deadline) {
            try closeRemainingProcessGroup(
                processIdentifier,
                graceDuration: graceDuration
            )
            return .init(
                processIdentifier: processIdentifier,
                terminationStatus: Self.terminationStatus(from: status),
                timedOut: false
            )
        }

        try signalProcessGroup(processIdentifier, signal: SIGTERM)
        let graceDeadline = monotonicNow().advanced(by: graceDuration)
        var status = try waitForExit(processIdentifier, until: graceDeadline)
        if processGroupExists(processIdentifier) {
            try signalProcessGroup(processIdentifier, signal: SIGKILL)
        }
        if status == nil {
            status = try reap(processIdentifier)
        }
        guard try waitForProcessGroupExit(
            processIdentifier,
            until: monotonicNow().advanced(by: graceDuration)
        ), let status else {
            throw R01LiveReportError.workerProcessFailed("reap")
        }
        return .init(
            processIdentifier: processIdentifier,
            terminationStatus: Self.terminationStatus(from: status),
            timedOut: true
        )
    }

    private func waitForExit(
        _ processIdentifier: pid_t,
        until deadline: ContinuousClock.Instant
    ) throws -> Int32? {
        while true {
            var status: Int32 = 0
            let result = Darwin.waitpid(processIdentifier, &status, WNOHANG)
            if result == processIdentifier { return status }
            if result == -1 {
                if errno == EINTR { continue }
                throw R01LiveReportError.workerProcessFailed("reap")
            }
            guard monotonicNow() < deadline else { return nil }
            Thread.sleep(forTimeInterval: pollInterval)
        }
    }

    private func reap(_ processIdentifier: pid_t) throws -> Int32 {
        while true {
            var status: Int32 = 0
            let result = Darwin.waitpid(processIdentifier, &status, 0)
            if result == processIdentifier { return status }
            if result == -1 && errno == EINTR { continue }
            throw R01LiveReportError.workerProcessFailed("reap")
        }
    }

    private func closeRemainingProcessGroup(
        _ processIdentifier: pid_t,
        graceDuration: Duration
    ) throws {
        guard processGroupExists(processIdentifier) else { return }
        try signalProcessGroup(processIdentifier, signal: SIGTERM)
        let deadline = monotonicNow().advanced(by: graceDuration)
        if try waitForProcessGroupExit(processIdentifier, until: deadline) { return }
        try signalProcessGroup(processIdentifier, signal: SIGKILL)
        guard try waitForProcessGroupExit(
            processIdentifier,
            until: monotonicNow().advanced(by: graceDuration)
        ) else {
            throw R01LiveReportError.workerProcessFailed("process-group")
        }
    }

    private func waitForProcessGroupExit(
        _ processIdentifier: pid_t,
        until deadline: ContinuousClock.Instant
    ) throws -> Bool {
        while processGroupExists(processIdentifier) {
            guard monotonicNow() < deadline else { return false }
            Thread.sleep(forTimeInterval: pollInterval)
        }
        return true
    }

    private func processGroupExists(_ processIdentifier: pid_t) -> Bool {
        errno = 0
        if Darwin.kill(-processIdentifier, 0) == 0 { return true }
        return errno != ESRCH
    }

    private func signalProcessGroup(
        _ processIdentifier: pid_t,
        signal: Int32
    ) throws {
        errno = 0
        let result = Darwin.kill(-processIdentifier, signal)
        guard result == 0 || errno == ESRCH else {
            throw R01LiveReportError.workerProcessFailed("termination")
        }
    }

    private static func spawn(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectoryURL: URL,
        standardOutputURL: URL?,
        standardErrorURL: URL?
    ) throws -> pid_t {
        let argumentValues = [executableURL.path] + arguments
        let environmentValues = environment.keys.sorted().map { key in
            "\(key)=\(environment[key]!)"
        }
        guard executableURL.path.hasPrefix("/"),
              currentDirectoryURL.path.hasPrefix("/"),
              argumentValues.allSatisfy({ !$0.contains("\0") }),
              environment.allSatisfy({ key, value in
                  !key.isEmpty && !key.contains("=") && !key.contains("\0")
                    && !value.contains("\0")
              }) else {
            throw R01LiveReportError.workerProcessFailed("arguments")
        }

        let inputDescriptor = Darwin.open("/dev/null", O_RDONLY | O_CLOEXEC)
        guard inputDescriptor >= 0 else {
            throw R01LiveReportError.workerProcessFailed("standard-input")
        }
        let outputDescriptor: Int32
        do {
            outputDescriptor = try openOutput(standardOutputURL)
        } catch {
            Darwin.close(inputDescriptor)
            throw error
        }
        let errorDescriptor: Int32
        do {
            errorDescriptor = try openOutput(standardErrorURL)
        } catch {
            Darwin.close(inputDescriptor)
            Darwin.close(outputDescriptor)
            throw error
        }
        defer {
            Darwin.close(inputDescriptor)
            Darwin.close(outputDescriptor)
            Darwin.close(errorDescriptor)
        }

        var fileActions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            throw R01LiveReportError.workerProcessFailed("spawn-actions")
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        guard posix_spawn_file_actions_adddup2(
            &fileActions, inputDescriptor, STDIN_FILENO
        ) == 0,
        posix_spawn_file_actions_adddup2(
            &fileActions, outputDescriptor, STDOUT_FILENO
        ) == 0,
        posix_spawn_file_actions_adddup2(
            &fileActions, errorDescriptor, STDERR_FILENO
        ) == 0,
        currentDirectoryURL.path.withCString({ path in
            posix_spawn_file_actions_addchdir_np(&fileActions, path)
        }) == 0 else {
            throw R01LiveReportError.workerProcessFailed("spawn-actions")
        }

        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else {
            throw R01LiveReportError.workerProcessFailed("spawn-attributes")
        }
        defer { posix_spawnattr_destroy(&attributes) }
        let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
        guard posix_spawnattr_setflags(&attributes, flags) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0 else {
            throw R01LiveReportError.workerProcessFailed("spawn-attributes")
        }

        let argumentStorage = argumentValues.map { strdup($0) }
        let environmentStorage = environmentValues.map { strdup($0) }
        guard argumentStorage.allSatisfy({ $0 != nil }),
              environmentStorage.allSatisfy({ $0 != nil }) else {
            argumentStorage.forEach { free($0) }
            environmentStorage.forEach { free($0) }
            throw R01LiveReportError.workerProcessFailed("arguments")
        }
        defer {
            argumentStorage.forEach { free($0) }
            environmentStorage.forEach { free($0) }
        }
        var argumentPointers = argumentStorage + [nil]
        var environmentPointers = environmentStorage + [nil]
        var processIdentifier: pid_t = 0
        let spawnResult = executableURL.path.withCString { executablePath in
            argumentPointers.withUnsafeMutableBufferPointer { argumentBuffer in
                environmentPointers.withUnsafeMutableBufferPointer { environmentBuffer in
                    Darwin.posix_spawn(
                        &processIdentifier,
                        executablePath,
                        &fileActions,
                        &attributes,
                        argumentBuffer.baseAddress,
                        environmentBuffer.baseAddress
                    )
                }
            }
        }
        guard spawnResult == 0, processIdentifier > 0 else {
            throw R01LiveReportError.workerProcessFailed("launch")
        }
        return processIdentifier
    }

    private static func openOutput(_ url: URL?) throws -> Int32 {
        guard let url else {
            let descriptor = Darwin.open("/dev/null", O_WRONLY | O_CLOEXEC)
            guard descriptor >= 0 else {
                throw R01LiveReportError.workerProcessFailed("output")
            }
            return descriptor
        }
        let descriptor = Darwin.open(
            url.path,
            O_WRONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK | O_TRUNC
        )
        guard descriptor >= 0 else {
            throw R01LiveReportError.workerProcessFailed("output")
        }
        var fileStatus = stat()
        guard Darwin.fstat(descriptor, &fileStatus) == 0,
              fileStatus.st_mode & S_IFMT == S_IFREG else {
            Darwin.close(descriptor)
            throw R01LiveReportError.workerProcessFailed("output")
        }
        return descriptor
    }

    private static func terminationStatus(from waitStatus: Int32) -> Int32 {
        let signal = waitStatus & 0x7f
        return signal == 0 ? (waitStatus >> 8) & 0xff : signal
    }

    private static func duration(
        seconds: TimeInterval,
        allowsZero: Bool = false
    ) -> Duration? {
        let nanoseconds = seconds * 1_000_000_000
        let validLowerBound = allowsZero ? nanoseconds >= 0 : nanoseconds > 0
        guard nanoseconds.isFinite,
              validLowerBound,
              nanoseconds <= Double(Int64.max) else {
            return nil
        }
        return .nanoseconds(Int64(nanoseconds.rounded(.up)))
    }
}

protocol R01CapabilityWorkerRunning {
    func execute(
        definition: R01CapabilityDefinition,
        compileObservation: R01CompileProbeObservation,
        context: R01LiveProbeContext,
        modelIdentity: String,
        modelSHA256: String
    ) throws -> R01CapabilityRecord
}

struct R01CapabilityWorkerProcessRunner: R01CapabilityWorkerRunning {
    static let executableEnvironmentVariable = "MIRMIR_R01_WORKER_EXECUTABLE"
    static let executableSHA256EnvironmentVariable = "MIRMIR_R01_WORKER_SHA256"
    static let contractEnvironmentVariables: Set<String> = [
        R01LiveProbeRequest.liveFlag,
        R01LiveProbeRequest.anchorVariable,
        R01LiveProbeRequest.outputVariable,
        "MIRMIR_R01_SOURCE_COMMIT",
        "MIRMIR_R01_SOURCE_TREE",
        executableEnvironmentVariable,
        executableSHA256EnvironmentVariable
    ]
    static let allowedEnvironmentVariables = contractEnvironmentVariables.union(
        R01ClosedSubprocessEnvironment.values.keys
    )
    static let outerTimeoutSeconds: TimeInterval = 390
    static let maximumResponseBytes = 1_048_576

    private let executableURL: URL
    private let expectedExecutableSHA256: String
    private let environment: [String: String]
    private let processRunner: any R01ChildProcessRunning
    private let timeout: TimeInterval
    private let fileManager: FileManager

    init(
        executableURL: URL,
        expectedExecutableSHA256: String,
        environment: [String: String],
        processRunner: any R01ChildProcessRunning = R01FailClosedChildProcessRunner(),
        timeout: TimeInterval = R01CapabilityWorkerProcessRunner.outerTimeoutSeconds,
        fileManager: FileManager = .default
    ) throws {
        let values = try executableURL.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey
        ])
        guard executableURL.path.hasPrefix("/"),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              fileManager.isExecutableFile(atPath: executableURL.path),
              R01Validation.isSHA256(expectedExecutableSHA256),
              try Self.sha256(of: executableURL) == expectedExecutableSHA256 else {
            throw R01LiveReportError.workerExecutableUnavailable
        }
        let standardizedExecutableURL = executableURL.standardizedFileURL
        let closedEnvironment = try Self.closedEnvironment(from: environment)
        guard let configuredExecutable = closedEnvironment[Self.executableEnvironmentVariable],
              URL(fileURLWithPath: configuredExecutable).standardizedFileURL
                == standardizedExecutableURL,
              closedEnvironment[Self.executableSHA256EnvironmentVariable]
                == expectedExecutableSHA256 else {
            throw R01LiveReportError.workerExecutableUnavailable
        }
        self.executableURL = standardizedExecutableURL
        self.expectedExecutableSHA256 = expectedExecutableSHA256
        self.environment = closedEnvironment
        self.processRunner = processRunner
        self.timeout = timeout
        self.fileManager = fileManager
    }

    static func resolve(
        environment: [String: String],
        fileManager: FileManager = .default
    ) throws -> R01CapabilityWorkerProcessRunner {
        guard let path = environment[executableEnvironmentVariable], !path.isEmpty,
              let sha256 = environment[executableSHA256EnvironmentVariable] else {
            throw R01LiveReportError.workerExecutableUnavailable
        }
        return try .init(
            executableURL: URL(fileURLWithPath: path),
            expectedExecutableSHA256: sha256,
            environment: environment,
            fileManager: fileManager
        )
    }

    static func closedEnvironment(
        from environment: [String: String]
    ) throws -> [String: String] {
        guard environment[R01LiveProbeRequest.liveFlag] == "1",
              environment[R01LiveProbeRequest.acquisitionFlag] == nil,
              let anchorValue = environment[R01LiveProbeRequest.anchorVariable],
              R01Anchor(rawValue: anchorValue) != nil,
              let output = environment[R01LiveProbeRequest.outputVariable],
              Self.isClosedAbsolutePath(output),
              let sourceCommit = environment["MIRMIR_R01_SOURCE_COMMIT"],
              R01Validation.isGitObjectID(sourceCommit),
              let sourceTree = environment["MIRMIR_R01_SOURCE_TREE"],
              R01Validation.isGitObjectID(sourceTree),
              let executable = environment[executableEnvironmentVariable],
              Self.isClosedAbsolutePath(executable),
              let executableSHA256 = environment[executableSHA256EnvironmentVariable],
              R01Validation.isSHA256(executableSHA256) else {
            throw R01LiveReportError.reportNotClosed
        }
        let contract = Dictionary(uniqueKeysWithValues: contractEnvironmentVariables.map { key in
            (key, environment[key]!)
        })
        return R01ClosedSubprocessEnvironment.values.merging(contract) { _, contractValue in
            contractValue
        }
    }

    func execute(
        definition: R01CapabilityDefinition,
        compileObservation: R01CompileProbeObservation,
        context: R01LiveProbeContext,
        modelIdentity: String,
        modelSHA256: String
    ) throws -> R01CapabilityRecord {
        guard definition.id == compileObservation.id else {
            throw R01LiveReportError.capabilityRecordNotClosed(definition.id.rawValue)
        }
        let directory = fileManager.temporaryDirectory.appendingPathComponent(
            "mirmir-r01-worker-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: directory) }
        guard try Self.sha256(of: executableURL) == expectedExecutableSHA256 else {
            throw R01LiveReportError.workerExecutableUnavailable
        }
        let requestURL = directory.appendingPathComponent("request.json")
        let responseURL = directory.appendingPathComponent("response.json")
        let input = R01CapabilityWorkerInput(
            capabilityID: definition.id,
            compileObservation: compileObservation,
            sourceCommit: context.source.commit,
            sourceTree: context.source.tree
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(input).write(to: requestURL, options: .withoutOverwriting)

        let result = try processRunner.run(
            executableURL: executableURL,
            arguments: [
                "--repository-root", context.repositoryRoot.path,
                "--request", requestURL.path,
                "--response", responseURL.path
            ],
            environment: environment,
            currentDirectoryURL: context.repositoryRoot,
            timeout: timeout
        )
        guard !result.timedOut else {
            throw R01LiveReportError.workerProcessTimedOut(definition.id.rawValue)
        }
        guard result.terminationStatus == 0 else {
            throw R01LiveReportError.workerProcessFailed(definition.id.rawValue)
        }
        let responseData = try Self.readClosedFile(
            at: responseURL,
            maximumBytes: Self.maximumResponseBytes,
            failure: .workerResponseNotClosed(definition.id.rawValue)
        )
        let record = try JSONDecoder().decode(R01CapabilityRecord.self, from: responseData)
        try record.validate(
            definition: definition,
            modelIdentity: modelIdentity,
            modelSHA256: modelSHA256
        )
        try Self.validateCompileBinding(
            record: record,
            observation: compileObservation,
            definition: definition
        )
        return record
    }

    static func validateCompileBinding(
        record: R01CapabilityRecord,
        observation: R01CompileProbeObservation,
        definition: R01CapabilityDefinition
    ) throws {
        guard observation.id == definition.id,
              record.compileState == observation.state,
              record.limitations.contains(observation.sanitizedDiagnostic) else {
            throw R01LiveReportError.capabilityRecordNotClosed(definition.id.rawValue)
        }
        if let failureClass = observation.probeFailureClass {
            guard record.runtimeDisposition == .rejected,
                  record.reasonCode == observation.reason ?? .runtimeProbeFailed,
                  record.failureClass == failureClass else {
                throw R01LiveReportError.capabilityRecordNotClosed(definition.id.rawValue)
            }
        } else if observation.state == .unavailable {
            guard record.runtimeDisposition == .unavailable,
                  record.reasonCode == observation.reason ?? .apiAbsent else {
                throw R01LiveReportError.capabilityRecordNotClosed(definition.id.rawValue)
            }
        }
    }

    static func readClosedFile(
        at url: URL,
        maximumBytes: Int,
        failure: R01LiveReportError
    ) throws -> Data {
        guard maximumBytes > 0 else { throw failure }
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard descriptor >= 0 else { throw failure }
        defer { Darwin.close(descriptor) }

        var fileStatus = stat()
        guard Darwin.fstat(descriptor, &fileStatus) == 0,
              fileStatus.st_mode & S_IFMT == S_IFREG,
              fileStatus.st_size > 0,
              fileStatus.st_size <= off_t(maximumBytes) else { throw failure }
        let expectedByteCount = Int(fileStatus.st_size)
        var data = Data()
        data.reserveCapacity(expectedByteCount)
        var buffer = [UInt8](repeating: 0, count: min(65_536, maximumBytes + 1))
        while data.count <= maximumBytes {
            let remaining = maximumBytes + 1 - data.count
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, min(bytes.count, remaining))
            }
            if count == -1 && errno == EINTR { continue }
            guard count >= 0 else { throw failure }
            if count == 0 { break }
            data.append(contentsOf: buffer[..<count])
        }
        guard data.count == expectedByteCount, data.count <= maximumBytes else { throw failure }
        return data
    }

    private static func isClosedAbsolutePath(_ value: String) -> Bool {
        value.hasPrefix("/") && !value.contains("\n") && !value.contains("\r")
    }

    private static func sha256(of url: URL) throws -> String {
        R01SHA256.hexDigest(try Data(contentsOf: url, options: .mappedIfSafe))
    }
}

struct R01CapabilityWorkerCommand {
    private struct Arguments {
        let repositoryRoot: String
        let request: String
        let response: String
    }

    func run(
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        let parsed = try parse(arguments: arguments)
        let repositoryRoot = URL(fileURLWithPath: parsed.repositoryRoot).standardizedFileURL
        guard let liveRequest = try R01LiveProbeRequest.resolve(
            environment: environment,
            repositoryRoot: repositoryRoot
        ), !liveRequest.allowsModelAcquisition else {
            throw R01LiveReportError.reportNotClosed
        }
        try validateRunningExecutable(environment: environment)
        let requestURL = URL(fileURLWithPath: parsed.request)
        let responseURL = URL(fileURLWithPath: parsed.response)
        guard !FileManager.default.fileExists(atPath: responseURL.path),
              R01Validation.isGitObjectID(environment["MIRMIR_R01_SOURCE_COMMIT"] ?? ""),
              R01Validation.isGitObjectID(environment["MIRMIR_R01_SOURCE_TREE"] ?? "") else {
            throw R01LiveReportError.reportNotClosed
        }
        let requestData = try R01CapabilityWorkerProcessRunner.readClosedFile(
            at: requestURL,
            maximumBytes: R01CapabilityWorkerProcessRunner.maximumResponseBytes,
            failure: .reportNotClosed
        )
        let input = try JSONDecoder().decode(
            R01CapabilityWorkerInput.self,
            from: requestData
        )
        guard input.capabilityID == input.compileObservation.id,
              input.sourceCommit == environment["MIRMIR_R01_SOURCE_COMMIT"],
              input.sourceTree == environment["MIRMIR_R01_SOURCE_TREE"],
              let definition = R01CapabilityInventory.definitions.first(where: {
                  $0.id == input.capabilityID
              }) else {
            throw R01LiveReportError.reportNotClosed
        }
        let context = try R01LiveProbeContext.prepare(
            request: liveRequest,
            repositoryRoot: repositoryRoot,
            expectedSource: .init(commit: input.sourceCommit, tree: input.sourceTree)
        )
        guard let modelIdentity = context.modelRecord.modelIdentity,
              let modelSHA256 = context.modelRecord.contentSHA256 else {
            throw R01LiveReportError.fixtureCatalogNotClosed
        }
        let descriptor = R01NativeAdapterRegistry().descriptor(
            for: definition,
            compileObservation: input.compileObservation,
            context: context
        )
        let record = try R01CapabilityExecutor().execute(
            definition: definition,
            compileObservation: input.compileObservation,
            descriptor: descriptor,
            modelIdentity: modelIdentity,
            modelSHA256: modelSHA256
        )
        try record.validate(
            definition: definition,
            modelIdentity: modelIdentity,
            modelSHA256: modelSHA256
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(record).write(to: responseURL, options: .withoutOverwriting)
    }

    private func parse(arguments: [String]) throws -> Arguments {
        guard arguments.count == 6,
              arguments[0] == "--repository-root",
              arguments[2] == "--request",
              arguments[4] == "--response",
              arguments[1].hasPrefix("/"),
              arguments[3].hasPrefix("/"),
              arguments[5].hasPrefix("/") else {
            throw R01LiveReportError.reportNotClosed
        }
        return .init(
            repositoryRoot: arguments[1],
            request: arguments[3],
            response: arguments[5]
        )
    }

    private func validateRunningExecutable(environment: [String: String]) throws {
        guard let configuredPath = environment[
            R01CapabilityWorkerProcessRunner.executableEnvironmentVariable
        ], let expectedSHA256 = environment[
            R01CapabilityWorkerProcessRunner.executableSHA256EnvironmentVariable
        ], R01Validation.isSHA256(expectedSHA256) else {
            throw R01LiveReportError.workerExecutableUnavailable
        }
        let configuredURL = URL(fileURLWithPath: configuredPath).resolvingSymlinksInPath()
        let runningURL = URL(
            fileURLWithPath: CommandLine.arguments[0]
        ).resolvingSymlinksInPath()
        guard configuredURL == runningURL,
              R01SHA256.hexDigest(
                try Data(contentsOf: runningURL, options: .mappedIfSafe)
              ) == expectedSHA256 else {
            throw R01LiveReportError.workerExecutableUnavailable
        }
    }
}
