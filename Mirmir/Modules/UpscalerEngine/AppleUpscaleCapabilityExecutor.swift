import Darwin
import Dispatch
import Foundation

// The closed R01 executor keeps the full record construction and validation
// contract together so its failure and measurement paths remain auditable.
// swiftlint:disable file_length

struct R01RuntimeUnitResult: Equatable, Sendable {
    let outputSHA256: String
    let classMetrics: [R01MetricName: R01MetricValue]
    let primaryScalerObservations: [R01PrimaryScalerObservation]

    init(
        outputSHA256: String,
        classMetrics: [R01MetricName: R01MetricValue],
        primaryScalerObservations: [R01PrimaryScalerObservation] = []
    ) {
        self.outputSHA256 = outputSHA256
        self.classMetrics = classMetrics
        self.primaryScalerObservations = primaryScalerObservations
    }
}

protocol R01CapabilityRuntimeSession: AnyObject {
    func runUnit(deadline: ContinuousClock.Instant) throws -> R01RuntimeUnitResult
}

enum R01AcquisitionObservation: Equatable, Sendable {
    case notAttempted
    case measured(seconds: Double)

    var seconds: Double {
        switch self {
        case .notAttempted: return 0
        case .measured(let seconds): return seconds
        }
    }
}

struct R01RuntimeAdapterDescriptor {
    let publicAPIStatus: R01PublicAPIStatus
    let hardwareEligibility: R01HardwareEligibility
    let platformRequirements: R01PlatformRequirements
    let supportQuery: R01SupportQuery
    let stateHistory: R01StateHistory
    let modelReadiness: R01ModelReadiness
    let offlineSuitability: R01OfflineSuitability
    let acquisitionObservation: R01AcquisitionObservation = .notAttempted
    let limitations: [String]
    let unavailableDisposition: R01RuntimeDisposition?
    let unavailableReason: R01ReasonCode?
    let sessionFactory: (() throws -> any R01CapabilityRuntimeSession)?

    // Every field is explicit because unavailable evidence must not inherit
    // runnable defaults.
    // swiftlint:disable:next function_parameter_count
    static func unavailable(
        publicAPIStatus: R01PublicAPIStatus,
        hardwareEligibility: R01HardwareEligibility,
        platformRequirements: R01PlatformRequirements,
        supportQuery: R01SupportQuery,
        stateHistory: R01StateHistory,
        modelReadiness: R01ModelReadiness,
        offlineSuitability: R01OfflineSuitability,
        disposition: R01RuntimeDisposition,
        reason: R01ReasonCode,
        limitations: [String]
    ) -> R01RuntimeAdapterDescriptor {
        .init(
            publicAPIStatus: publicAPIStatus,
            hardwareEligibility: hardwareEligibility,
            platformRequirements: platformRequirements,
            supportQuery: supportQuery,
            stateHistory: stateHistory,
            modelReadiness: modelReadiness,
            offlineSuitability: offlineSuitability,
            limitations: limitations,
            unavailableDisposition: disposition,
            unavailableReason: reason,
            sessionFactory: nil
        )
    }
}

struct R01BoundedOperationResult<Value> {
    let result: Result<Value, Error>?
    let timedOut: Bool
    let peakResidentMemoryBytes: Int
}

final class R01OperationResultBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedResult: Result<Value, Error>?

    func store(_ result: Result<Value, Error>) {
        lock.lock()
        storedResult = result
        lock.unlock()
    }

    func load() -> Result<Value, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return storedResult
    }
}

final class R01UncheckedOperation<Value>: @unchecked Sendable {
    private let operation: () throws -> Value

    init(_ operation: @escaping () throws -> Value) {
        self.operation = operation
    }

    func call() throws -> Value { try operation() }
}

struct R01BoundedOperationRunner {
    let memorySampler: () throws -> Int
    let pollingInterval: TimeInterval

    func run<Value>(
        deadline: ContinuousClock.Instant,
        now: () -> ContinuousClock.Instant,
        operation: @escaping () throws -> Value
    ) throws -> R01BoundedOperationResult<Value> {
        let semaphore = DispatchSemaphore(value: 0)
        let box = R01OperationResultBox<Value>()
        let uncheckedOperation = R01UncheckedOperation(operation)
        DispatchQueue.global(qos: .userInitiated).async {
            box.store(Result { try uncheckedOperation.call() })
            semaphore.signal()
        }
        var peakMemory = try sampledResidentMemory()
        while true {
            let current = now()
            guard current < deadline else { break }
            let remaining = Self.seconds(current.duration(to: deadline))
            let wait = min(max(remaining, 0), pollingInterval)
            if semaphore.wait(timeout: .now() + wait) == .success {
                peakMemory = max(peakMemory, try sampledResidentMemory())
                return .init(
                    result: box.load(),
                    timedOut: false,
                    peakResidentMemoryBytes: peakMemory
                )
            }
            peakMemory = max(peakMemory, try sampledResidentMemory())
        }
        return .init(result: nil, timedOut: true, peakResidentMemoryBytes: peakMemory)
    }

    private func sampledResidentMemory() throws -> Int {
        do {
            return try memorySampler()
        } catch {
            throw R01ExecutionFailure.resource
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

struct R01CapabilityExecutor {
    private let sessionTimeout: Duration
    private let memorySampler: () throws -> Int
    private let pollingInterval: TimeInterval
    private let now: () -> ContinuousClock.Instant

    init(
        sessionTimeout: Duration = .seconds(120),
        memorySampler: @escaping () throws -> Int = R01CapabilityExecutor.residentMemoryBytes,
        pollingInterval: TimeInterval = 0.005,
        now: @escaping () -> ContinuousClock.Instant = { ContinuousClock().now }
    ) {
        self.sessionTimeout = sessionTimeout
        self.memorySampler = memorySampler
        self.pollingInterval = pollingInterval
        self.now = now
    }

    func execute(
        definition: R01CapabilityDefinition,
        compileObservation: R01CompileProbeObservation,
        descriptor: R01RuntimeAdapterDescriptor,
        modelIdentity: String?,
        modelSHA256: String?
    ) throws -> R01CapabilityRecord {
        guard compileObservation.id == definition.id else {
            throw R01LiveReportError.capabilityRecordNotClosed(definition.id.rawValue)
        }
        if let failureClass = compileObservation.probeFailureClass {
            return try makeNonRunnable(
                definition: definition,
                compileState: compileObservation.state,
                descriptor: descriptor,
                disposition: .rejected,
                reason: compileObservation.reason ?? .runtimeProbeFailed,
                failureClassOverride: failureClass,
                modelIdentity: modelIdentity,
                modelSHA256: modelSHA256,
                additionalLimitation: compileObservation.sanitizedDiagnostic
            )
        }
        if compileObservation.state == .unavailable {
            let reason = compileObservation.reason ?? .apiAbsent
            return try makeNonRunnable(
                definition: definition,
                compileState: .unavailable,
                descriptor: descriptor,
                disposition: .unavailable,
                reason: reason,
                modelIdentity: modelIdentity,
                modelSHA256: modelSHA256,
                additionalLimitation: compileObservation.sanitizedDiagnostic
            )
        }
        guard let factory = descriptor.sessionFactory else {
            return try makeNonRunnable(
                definition: definition,
                compileState: compileObservation.state,
                descriptor: descriptor,
                disposition: descriptor.unavailableDisposition ?? .restricted,
                reason: descriptor.unavailableReason ?? .inputContractUnsatisfied,
                modelIdentity: modelIdentity,
                modelSHA256: modelSHA256,
                additionalLimitation: compileObservation.sanitizedDiagnostic
            )
        }
        return try executeSessions(
            definition: definition,
            compileState: compileObservation.state,
            descriptor: descriptor,
            factory: factory,
            modelIdentity: modelIdentity,
            modelSHA256: modelSHA256,
            compileDiagnostic: compileObservation.sanitizedDiagnostic
        )
    }
}

private extension R01CapabilityExecutor {
    // Session orchestration is intentionally linear: each exit constructs and
    // validates the exact partial evidence collected before that exit.
    // swiftlint:disable:next function_body_length
    func executeSessions(
        definition: R01CapabilityDefinition,
        compileState: R01CompileState,
        descriptor: R01RuntimeAdapterDescriptor,
        factory: @escaping () throws -> any R01CapabilityRuntimeSession,
        modelIdentity: String?,
        modelSHA256: String?,
        compileDiagnostic: String
    ) throws -> R01CapabilityRecord {
        let memoryBefore: Int
        do {
            memoryBefore = try memorySampler()
        } catch {
            let failure = R01ExecutionFailure.resource
            return try failedRecord(
                definition: definition,
                compileState: compileState,
                descriptor: descriptor,
                sessions: [failure.session(index: 1, warmups: 0, measurements: 0, elapsed: 0)],
                failure: failure,
                modelIdentity: modelIdentity,
                modelSHA256: modelSHA256,
                compileDiagnostic: compileDiagnostic
            )
        }
        var sessions: [R01MeasurementSession] = []
        var initializationDurations: [Double] = []
        var invocationDurations: [Double] = []
        var repeatHashes: [R01RepeatabilityValue] = []
        var classMetrics: [R01MetricName: R01MetricValue]?
        var primaryScalerObservations: [R01PrimaryScalerObservation]?
        var peakResidentMemory = memoryBefore
        let operationRunner = R01BoundedOperationRunner(
            memorySampler: memorySampler,
            pollingInterval: max(0.000_1, pollingInterval)
        )
        var activeSessionStart: ContinuousClock.Instant?

        do {
            for sessionIndex in 1...3 {
                let sessionStart = now()
                activeSessionStart = sessionStart
                let deadline = sessionStart.advanced(by: sessionTimeout)
                let initializationStart = now()
                let factoryResult = try operationRunner.run(
                    deadline: deadline,
                    now: now,
                    operation: factory
                )
                peakResidentMemory = max(
                    peakResidentMemory,
                    factoryResult.peakResidentMemoryBytes
                )
                guard !factoryResult.timedOut else { throw R01ExecutionFailure.timeout }
                let session: any R01CapabilityRuntimeSession
                switch factoryResult.result {
                case .success(let value):
                    session = value
                case .failure(let error):
                    throw (error as? R01ExecutionFailure) ?? .setup
                case nil:
                    throw R01ExecutionFailure.setup
                }
                initializationDurations.append(seconds(initializationStart.duration(to: now())))
                var completedWarmups = 0
                var completedMeasurements = 0
                var outputHashes: [String] = []
                do {
                    for _ in 0..<5 {
                        _ = try executeUnit(
                            session,
                            deadline: deadline,
                            operationRunner: operationRunner,
                            peakResidentMemory: &peakResidentMemory
                        )
                        completedWarmups += 1
                    }
                    for _ in 0..<30 {
                        let start = now()
                        let result = try executeUnit(
                            session,
                            deadline: deadline,
                            operationRunner: operationRunner,
                            peakResidentMemory: &peakResidentMemory
                        )
                        invocationDurations.append(seconds(start.duration(to: now())))
                        completedMeasurements += 1
                        outputHashes.append(result.outputSHA256)
                        if let prior = classMetrics, prior != result.classMetrics {
                            throw R01ExecutionFailure.processing
                        }
                        if let prior = primaryScalerObservations,
                           prior != result.primaryScalerObservations {
                            throw R01ExecutionFailure.processing
                        }
                        classMetrics = result.classMetrics
                        primaryScalerObservations = result.primaryScalerObservations
                    }
                    sessions.append(.init(
                        sessionIndex: sessionIndex,
                        completedWarmupUnits: completedWarmups,
                        completedMeasuredUnits: completedMeasurements,
                        elapsedSeconds: min(120, seconds(sessionStart.duration(to: now()))),
                        timedOut: false,
                        outcome: .completed,
                        failureDetail: nil
                    ))
                    repeatHashes.append(.hash(R01SHA256.hexDigest(Data(
                        outputHashes.joined(separator: "\n").utf8
                    ))))
                } catch let failure as R01ExecutionFailure {
                    sessions.append(failure.session(
                        index: sessionIndex,
                        warmups: completedWarmups,
                        measurements: completedMeasurements,
                        elapsed: seconds(sessionStart.duration(to: now()))
                    ))
                    return try failedRecord(
                        definition: definition,
                        compileState: compileState,
                        descriptor: descriptor,
                        sessions: sessions,
                        failure: failure,
                        modelIdentity: modelIdentity,
                        modelSHA256: modelSHA256,
                        compileDiagnostic: compileDiagnostic
                    )
                }
                activeSessionStart = nil
            }
        } catch let caught as R01ExecutionFailure {
            let failure = caught
            sessions.append(failure.session(
                index: sessions.count + 1,
                warmups: 0,
                measurements: 0,
                elapsed: activeSessionStart.map { seconds($0.duration(to: now())) } ?? 0
            ))
            return try failedRecord(
                definition: definition,
                compileState: compileState,
                descriptor: descriptor,
                sessions: sessions,
                failure: failure,
                modelIdentity: modelIdentity,
                modelSHA256: modelSHA256,
                compileDiagnostic: compileDiagnostic
            )
        } catch {
            let failure = R01ExecutionFailure.setup
            sessions.append(failure.session(
                index: sessions.count + 1,
                warmups: 0,
                measurements: 0,
                elapsed: activeSessionStart.map { seconds($0.duration(to: now())) } ?? 0
            ))
            return try failedRecord(
                definition: definition,
                compileState: compileState,
                descriptor: descriptor,
                sessions: sessions,
                failure: failure,
                modelIdentity: modelIdentity,
                modelSHA256: modelSHA256,
                compileDiagnostic: compileDiagnostic
            )
        }

        guard let classMetrics, let primaryScalerObservations,
              definition.probeClass == .primaryScaler
                  ? primaryScalerObservations == R01PrimaryScalerObservation.frozen
                  : primaryScalerObservations.isEmpty else {
            throw R01LiveReportError.measurementsNotClosed
        }
        let metrics = try measuredMetrics(
            probeClass: definition.probeClass,
            initializationDurations: initializationDurations,
            invocationDurations: invocationDurations,
            residentMemoryDelta: max(0, peakResidentMemory - memoryBefore),
            acquisitionSeconds: descriptor.acquisitionObservation.seconds,
            primaryScalerObservationCount: primaryScalerObservations.count,
            classMetrics: classMetrics
        )
        let measurements = R01Measurements(
            sessionCount: sessions.count,
            warmupUnitsPerSession: 5,
            measuredUnitsPerSession: 30,
            timeoutSecondsPerSession: 120,
            sessions: sessions,
            metrics: metrics,
            repeatability: .init(
                status: .measured,
                mode: .hash,
                observations: repeatHashes,
                tolerance: nil,
                reason: nil
            )
        )
        let record = baseRecord(
            definition: definition,
            compileState: compileState,
            descriptor: descriptor,
            disposition: .runnable,
            reason: .none,
            failureClass: .none,
            primaryScalerObservations: primaryScalerObservations,
            measurements: measurements,
            modelIdentity: modelIdentity,
            modelSHA256: modelSHA256,
            limitations: descriptor.limitations + [compileDiagnostic]
        )
        try record.validate(
            definition: definition,
            modelIdentity: modelIdentity,
            modelSHA256: modelSHA256
        )
        return record
    }

    func executeUnit(
        _ session: any R01CapabilityRuntimeSession,
        deadline: ContinuousClock.Instant,
        operationRunner: R01BoundedOperationRunner,
        peakResidentMemory: inout Int
    ) throws -> R01RuntimeUnitResult {
        guard now() < deadline else { throw R01ExecutionFailure.timeout }
        do {
            let bounded = try operationRunner.run(
                deadline: deadline,
                now: now,
                operation: { try session.runUnit(deadline: deadline) }
            )
            peakResidentMemory = max(
                peakResidentMemory,
                bounded.peakResidentMemoryBytes
            )
            guard !bounded.timedOut else { throw R01ExecutionFailure.timeout }
            let result: R01RuntimeUnitResult
            switch bounded.result {
            case .success(let value):
                result = value
            case .failure(let error):
                throw (error as? R01ExecutionFailure) ?? .processing
            case nil:
                throw R01ExecutionFailure.processing
            }
            guard now() < deadline else { throw R01ExecutionFailure.timeout }
            guard R01Validation.isSHA256(result.outputSHA256) else {
                throw R01ExecutionFailure.processing
            }
            return result
        } catch let failure as R01ExecutionFailure {
            throw failure
        } catch {
            throw R01ExecutionFailure.processing
        }
    }

    func makeNonRunnable(
        definition: R01CapabilityDefinition,
        compileState: R01CompileState,
        descriptor: R01RuntimeAdapterDescriptor,
        disposition: R01RuntimeDisposition,
        reason: R01ReasonCode,
        failureClassOverride: R01FailureClass? = nil,
        modelIdentity: String?,
        modelSHA256: String?,
        additionalLimitation: String
    ) throws -> R01CapabilityRecord {
        let failureClass = try failureClassOverride ?? nonRunnableFailureClass(for: reason)
        let measurements = try R01Measurements.nonRunnable(
            probeClass: definition.probeClass,
            reason: reason
        )
        let record = baseRecord(
            definition: definition,
            compileState: compileState,
            descriptor: descriptor,
            disposition: disposition,
            reason: reason,
            failureClass: failureClass,
            primaryScalerObservations: [],
            measurements: measurements,
            modelIdentity: modelIdentity,
            modelSHA256: modelSHA256,
            limitations: descriptor.limitations + [additionalLimitation]
        )
        try record.validate(
            definition: definition,
            modelIdentity: modelIdentity,
            modelSHA256: modelSHA256
        )
        return record
    }

    func failedRecord(
        definition: R01CapabilityDefinition,
        compileState: R01CompileState,
        descriptor: R01RuntimeAdapterDescriptor,
        sessions: [R01MeasurementSession],
        failure: R01ExecutionFailure,
        modelIdentity: String?,
        modelSHA256: String?,
        compileDiagnostic: String
    ) throws -> R01CapabilityRecord {
        let measurements = try R01Measurements.nonRunnable(
            probeClass: definition.probeClass,
            reason: failure.reason,
            sessions: sessions
        )
        let record = baseRecord(
            definition: definition,
            compileState: compileState,
            descriptor: descriptor,
            disposition: .rejected,
            reason: failure.reason,
            failureClass: failure.failureClass,
            primaryScalerObservations: [],
            measurements: measurements,
            modelIdentity: modelIdentity,
            modelSHA256: modelSHA256,
            limitations: descriptor.limitations + [compileDiagnostic, failure.detail]
        )
        try record.validate(
            definition: definition,
            modelIdentity: modelIdentity,
            modelSHA256: modelSHA256
        )
        return record
    }

    // This builder mirrors the closed schema's required capability fields.
    // swiftlint:disable:next function_parameter_count
    func baseRecord(
        definition: R01CapabilityDefinition,
        compileState: R01CompileState,
        descriptor: R01RuntimeAdapterDescriptor,
        disposition: R01RuntimeDisposition,
        reason: R01ReasonCode,
        failureClass: R01FailureClass,
        primaryScalerObservations: [R01PrimaryScalerObservation],
        measurements: R01Measurements,
        modelIdentity: String?,
        modelSHA256: String?,
        limitations: [String]
    ) -> R01CapabilityRecord {
        .init(
            id: definition.id,
            family: definition.family,
            method: definition.method,
            probeClass: definition.probeClass,
            compileState: compileState,
            runtimeDisposition: disposition,
            reasonCode: reason,
            failureClass: failureClass,
            publicAPIStatus: reason == .apiAbsent ? .absent : descriptor.publicAPIStatus,
            hardwareEligibility: descriptor.hardwareEligibility,
            platformRequirements: descriptor.platformRequirements,
            supportQuery: compileState == .unavailable
                ? .init(
                    apiOrEquivalentName: descriptor.supportQuery.apiOrEquivalentName,
                    observed: .notAvailable,
                    reasonCode: reason
                )
                : descriptor.supportQuery,
            inputContract: .frozen(
                capabilityID: definition.id,
                for: definition.probeClass,
                modelIdentity: modelIdentity,
                modelSHA256: modelSHA256
            ),
            stateHistory: descriptor.stateHistory,
            modelReadiness: descriptor.modelReadiness,
            offlineSuitability: descriptor.offlineSuitability,
            primaryScalerObservations: primaryScalerObservations,
            measurements: measurements,
            productQualification: R01CapabilityRecord.notEvaluated,
            backendEligibility: R01CapabilityRecord.notEvaluated,
            qualityEvaluation: R01CapabilityRecord.notEvaluated,
            limitations: Array(Set(limitations)).sorted()
        )
    }

    func measuredMetrics(
        probeClass: R01ProbeClass,
        initializationDurations: [Double],
        invocationDurations: [Double],
        residentMemoryDelta: Int,
        acquisitionSeconds: Double,
        primaryScalerObservationCount: Int,
        classMetrics: [R01MetricName: R01MetricValue]
    ) throws -> R01Metrics {
        var derivedMetrics: Set<R01MetricName> = [
            .initializationSeconds, .acquisitionSeconds, .medianWallSeconds,
            .p95WallSeconds, .throughputUnitsPerSecond,
            .peakResidentMemoryDeltaBytes
        ]
        if probeClass == .primaryScaler { derivedMetrics.insert(.frameRate) }
        guard initializationDurations.count == 3, invocationDurations.count == 90,
              probeClass == .primaryScaler
                  ? primaryScalerObservationCount == R01PrimaryScalerObservation.frozen.count
                  : primaryScalerObservationCount == 0,
              Set(classMetrics.keys) == R01MetricName.applicable(to: probeClass)
                .subtracting(derivedMetrics) else {
            throw R01LiveReportError.metricsNotClosed
        }
        let total = invocationDurations.reduce(0, +)
        guard total > 0, acquisitionSeconds.isFinite, acquisitionSeconds >= 0 else {
            throw R01LiveReportError.metricsNotClosed
        }
        let throughput = Double(invocationDurations.count) / total
        var values = try R01Measurements.nonApplicableMetricMap(probeClass: probeClass)
        var common: [R01MetricName: R01MetricValue] = [
            .initializationSeconds: .double(median(initializationDurations)),
            .acquisitionSeconds: .double(acquisitionSeconds),
            .medianWallSeconds: .double(median(invocationDurations)),
            .p95WallSeconds: .double(percentile95(invocationDurations)),
            .throughputUnitsPerSecond: .double(throughput),
            .peakResidentMemoryDeltaBytes: .integer(residentMemoryDelta)
        ]
        if probeClass == .primaryScaler {
            common[.frameRate] = .double(throughput * Double(primaryScalerObservationCount))
        }
        for (metric, value) in common.merging(classMetrics, uniquingKeysWith: { first, _ in first }) {
            values[metric] = .init(status: .measured, value: value, unit: metric.unit, reason: nil)
        }
        return try R01Metrics(values: values)
    }

    func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }

    func percentile95(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let index = max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)
        return sorted[index]
    }

    func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    static func residentMemoryBytes() throws -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    rebound,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else { throw R01ExecutionFailure.resource }
        return Int(info.resident_size)
    }

    func nonRunnableFailureClass(for reason: R01ReasonCode) throws -> R01FailureClass {
        switch reason {
        case .apiAbsent, .osTooOld, .sdkTooOld, .hardwareUnsupported,
             .modelUnavailable, .inputContractUnsatisfied, .notPublicAPI, .notApplicable:
            return .unsupportedContract
        case .modelAcquisitionFailed:
            return .setupFailure
        case .resourceLimit:
            return .resourceFailure
        case .none, .runtimeProbeFailed:
            throw R01LiveReportError.capabilityRecordNotClosed(reason.rawValue)
        }
    }
}

enum R01ExecutionFailure: Error, Equatable {
    case timeout
    case setup
    case processing
    case resource

    var failureClass: R01FailureClass {
        switch self {
        case .timeout: return .timeout
        case .setup: return .setupFailure
        case .processing: return .processingFailure
        case .resource: return .resourceFailure
        }
    }

    var reason: R01ReasonCode {
        self == .resource ? .resourceLimit : .runtimeProbeFailed
    }

    var detail: String { failureClass.rawValue }

    func session(
        index: Int,
        warmups: Int,
        measurements: Int,
        elapsed: Double
    ) -> R01MeasurementSession {
        .init(
            sessionIndex: index,
            completedWarmupUnits: warmups,
            completedMeasuredUnits: measurements,
            elapsedSeconds: self == .timeout ? 120 : min(120, max(0, elapsed)),
            timedOut: self == .timeout,
            outcome: R01SessionOutcome(rawValue: failureClass.rawValue) ?? .processingFailure,
            failureDetail: detail
        )
    }
}

private extension R01Measurements {
    static func nonRunnable(
        probeClass: R01ProbeClass,
        reason: R01ReasonCode,
        sessions: [R01MeasurementSession] = []
    ) throws -> R01Measurements {
        var metrics = try nonApplicableMetricMap(probeClass: probeClass)
        for metric in R01MetricName.applicable(to: probeClass) {
            metrics[metric] = .init(
                status: .notMeasured,
                value: nil,
                unit: metric.unit,
                reason: reason.rawValue
            )
        }
        return .init(
            sessionCount: sessions.count,
            warmupUnitsPerSession: 5,
            measuredUnitsPerSession: 30,
            timeoutSecondsPerSession: 120,
            sessions: sessions,
            metrics: try R01Metrics(values: metrics),
            repeatability: .init(
                status: .notMeasured,
                mode: .notApplicable,
                observations: [],
                tolerance: nil,
                reason: reason.rawValue
            )
        )
    }

    static func nonApplicableMetricMap(
        probeClass: R01ProbeClass
    ) throws -> [R01MetricName: R01MetricObservation] {
        Dictionary(uniqueKeysWithValues: R01MetricName.allCases.map { metric in
            (
                metric,
                .init(
                    status: .notApplicable,
                    value: nil,
                    unit: metric.unit,
                    reason: "not_applicable_for_\(probeClass.rawValue)"
                )
            )
        })
    }
}
